defmodule GtfsPlanner.Alerts.Listing do
  @moduledoc """
  The list page's read model: which tab an alert belongs to, and the two badges a
  row carries (AC-9, R8).

  A tab is derived, never stored. An alert that has not answered every question
  is In progress, and a complete one is Current while it covers the agency's
  current date, Upcoming while its first date is later, and Past once its last
  date is earlier. An open-ended alert has no last date at all, so it can never
  fall into Past on its own: it stays Current until an operator ends it (R8).

  `needs_attention?` is also derived at read time and never blocks or narrows the
  alert. A route, stop or trip the alert names is an exact GTFS feed ID, so
  deleting that entity from the schedule must not silently rewrite who the alert
  is about; the scope keeps the feed ID and the list row is flagged instead (R8).
  A row is flagged when `Alerts.Targets.resolve/2` reports any diagnostic for it:
  a target the organization's active schedule lacks, or one it has that the
  alert's pair, stretch or dated trip does not fit. The diagnostics come from one
  batch against that single schedule, so the alert's original source version
  neither clears nor causes attention and one alert's missing target never flags
  another.

  `check_in_due?` compares the stored `check_in_at` with the alert's own local
  time. An organization holds alerts written against several versions, and each
  alert carries the zone its source version declared, so the caller passes one
  UTC instant and this module localizes it once per retained zone through
  `Gtfs.DisplayClock.localize_many/2`. Every row is therefore classified against
  its own civil date, which is what keeps a New York alert and a Tokyo alert in
  the same organization from being grouped on the navbar version's day (CR-7).

  An alert with no retained zone falls back to the organization's stated zone and
  then to UTC. That fallback is a presentation answer only: it is what an absent
  zone already disclosed on the timing answer, and publication still requires an
  explicit valid zone (CR-5).
  """

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Gtfs.DisplayClock

  @tabs [:current, :upcoming, :in_progress, :past]

  @type tab :: :current | :upcoming | :in_progress | :past

  @type row :: %{
          alert: Alert.t(),
          needs_attention?: boolean(),
          check_in_due?: boolean()
        }

  @type tabs :: %{current: [row()], upcoming: [row()], in_progress: [row()], past: [row()]}

  @doc """
  Builds the four tabs for a set of organization-owned alerts, as of `now_utc`.

  `now_utc` is one instant rather than a civil time, because the rows do not
  share a zone: each alert is grouped on the date its own retained zone is on at
  that instant. `organization_timezone` is the organization's explicit zone, used
  for an alert whose source version declared none; when that is absent too the
  row is read in UTC, which is the disclosed display fallback and never a
  publication consent (CR-5).

  `diagnostics_by_alert` is what `Alerts.Targets.resolve/2` reported for these
  alerts against the active schedule; an alert with none is not flagged. It
  defaults to no diagnostics because classification and attention are separate
  questions and only the workspace read has a schedule to ask.

  Every tab is always present in the result, empty or not, so the list page can
  show counts without special-casing a missing key.
  """
  @spec rows([Alert.t()], DateTime.t(), String.t() | nil, %{optional(Ecto.UUID.t()) => list()}) ::
          tabs()
  def rows(
        alerts,
        %DateTime{} = now_utc,
        organization_timezone \\ nil,
        diagnostics_by_alert \\ %{}
      ) do
    local = local_times(alerts, now_utc, organization_timezone)

    grouped =
      Map.new(
        alerts |> Enum.group_by(&tab(&1, NaiveDateTime.to_date(Map.fetch!(local, &1.id)))),
        fn {tab, tab_alerts} ->
          {tab,
           tab_alerts
           |> order(tab)
           |> Enum.map(
             &row(&1, Map.fetch!(local, &1.id), Map.get(diagnostics_by_alert, &1.id, []))
           )}
        end
      )

    # Every tab is present even when it holds nothing, so the list page can read
    # a count without special-casing an absent key.
    Map.new(@tabs, fn tab -> {tab, Map.get(grouped, tab, [])} end)
  end

  @doc """
  Returns the zone an alert's civil dates and check-in time are read in.

  The alert's own retained zone is the answer, because it is the zone the
  answers were written in. An organization with alerts from several versions
  therefore reads each row in its own day rather than in the version the editor
  happens to have selected.
  """
  @spec zone(Alert.t(), String.t() | nil) :: String.t()
  def zone(%Alert{timezone: timezone}, _organization_timezone)
      when is_binary(timezone) and timezone != "",
      do: timezone

  def zone(%Alert{}, organization_timezone) when is_binary(organization_timezone),
    do: organization_timezone

  def zone(%Alert{}, _organization_timezone), do: "UTC"

  @doc """
  Localizes one instant for every alert, one query per retained zone.

  Rows that share a zone are converted together, so an organization with one
  zone still costs a single query and a mixed organization costs one per distinct
  zone rather than one per alert.
  """
  @spec local_times([Alert.t()], DateTime.t(), String.t() | nil) :: %{
          optional(Ecto.UUID.t()) => NaiveDateTime.t()
        }
  def local_times(alerts, %DateTime{} = now_utc, organization_timezone \\ nil) do
    alerts
    |> Enum.group_by(&zone(&1, organization_timezone))
    |> Enum.flat_map(fn {timezone, zone_alerts} ->
      [now_utc]
      |> DisplayClock.localize_many(%{timezone: timezone})
      |> List.first()
      |> then(&Enum.map(zone_alerts, fn alert -> {alert.id, &1} end))
    end)
    |> Map.new()
  end

  @doc """
  Returns the tab an alert belongs to on the agency's civil date `today`.
  """
  @spec tab(Alert.t(), Date.t()) :: tab()
  def tab(%Alert{complete: false}, _today), do: :in_progress

  # A complete alert with no derived first date covers today by definition: it
  # has nothing dated later to wait for and nothing dated earlier to be past.
  def tab(%Alert{first_date: nil}, _today), do: :current

  def tab(%Alert{first_date: first_date, last_date: last_date}, today) do
    cond do
      Date.compare(first_date, today) == :gt -> :upcoming
      ended_before?(last_date, today) -> :past
      true -> :current
    end
  end

  # -- Rows ----------------------------------------------------------------

  defp row(%Alert{} = alert, local_now, diagnostics) do
    %{
      alert: alert,
      needs_attention?: diagnostics != [],
      check_in_due?: check_in_due?(alert, local_now)
    }
  end

  # A nil `check_in_at` is an alert with nothing to check back on. Otherwise the
  # stored civil time is compared with the agency-local time the caller passed,
  # with no zone conversion on either side (CR-7).
  defp check_in_due?(%Alert{timing: %TimingAnswer{check_in_at: nil}}, _local_now), do: false

  defp check_in_due?(%Alert{timing: %TimingAnswer{check_in_at: check_in_at}}, local_now),
    do: NaiveDateTime.compare(check_in_at, local_now) != :gt

  defp check_in_due?(%Alert{}, _local_now), do: false

  # -- Ordering ------------------------------------------------------------

  # Current and Upcoming read forward in time, In progress and Past read most
  # recently changed first. Every order falls back to the row UUID so two alerts
  # with the same date or timestamp keep a stable order across reads. `Date` and
  # `DateTime` structs compare by field order under the default term sorter, so
  # each is sorted by an integer that grows with time instead.
  defp order(alerts, tab) when tab in [:current, :upcoming] do
    Enum.sort_by(alerts, &{&1.first_date == nil, date_key(&1.first_date), &1.id})
  end

  defp order(alerts, :in_progress),
    do: sort_descending(alerts, &instant_key(&1.updated_at))

  defp order(alerts, :past), do: sort_descending(alerts, &date_key(&1.last_date))

  defp date_key(nil), do: nil
  defp date_key(%Date{} = date), do: Date.to_gregorian_days(date)

  defp instant_key(nil), do: nil
  defp instant_key(%DateTime{} = instant), do: DateTime.to_unix(instant, :microsecond)

  # Descending with absent values last, so a row without the value it is ordered
  # by never leads its tab.
  defp sort_descending(alerts, value) do
    {present, absent} = Enum.split_with(alerts, &(not is_nil(value.(&1))))

    Enum.sort_by(present, &{value.(&1), &1.id}, :desc) ++ Enum.sort_by(absent, & &1.id)
  end

  defp ended_before?(nil, _today), do: false
  defp ended_before?(last_date, today), do: Date.compare(last_date, today) == :lt

  # -- Referenced target identities ---------------------------------------

  @doc """
  Returns every route, stop and trip feed ID the alert's scope names.

  The identities are wherever the operator entered them: a single value, a
  stretch end, a boarding alternative, a route and stop pair and a cancelled
  departure are all targets a version edit could remove. `Alerts.Targets`
  labels exactly these identities, so a list row and the alert's own labels
  read from one reading of the stored scope.
  """
  @spec referenced_ids(Alert.t()) :: %{
          routes: [String.t()],
          stops: [String.t()],
          trips: [String.t()]
        }
  def referenced_ids(%Alert{scope: scope}) do
    %{
      routes: [
        scope && scope.route_ids,
        Enum.map(scope_pairs(scope), & &1.route_id)
      ],
      stops: [
        scope && scope.stop_ids,
        Enum.map(scope_pairs(scope), & &1.stop_id),
        [scope && scope.stretch_from_stop_id, scope && scope.stretch_to_stop_id],
        scope && scope.alternative_stop_id
      ],
      trips: [Enum.map(scope_trips(scope), & &1.trip_id)]
    }
    |> Map.new(fn {table, ids} ->
      {table, ids |> Enum.flat_map(&List.wrap/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()}
    end)
  end

  defp scope_pairs(nil), do: []

  defp scope_pairs(%{route_stop_pairs: pairs}) when is_list(pairs),
    do: Enum.reject(pairs, &is_nil/1)

  defp scope_pairs(_scope), do: []

  defp scope_trips(nil), do: []

  defp scope_trips(%{trips: trips}) when is_list(trips),
    do: Enum.reject(trips, &is_nil/1)

  defp scope_trips(_scope), do: []
end

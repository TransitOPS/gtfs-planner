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
  alert. A route, stop or trip the alert names is a row UUID of the version being
  edited, so deleting that row from the version must not silently rewrite who the
  alert is about; the scope keeps the UUID and the list row is flagged instead
  (R8). Existence is checked with one `id in` query per table for every listed
  alert at once, so the cost does not grow with the number of rows.

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

  import Ecto.Query, warn: false

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

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

  Every tab is always present in the result, empty or not, so the list page can
  show counts without special-casing a missing key.
  """
  @spec rows([Alert.t()], DateTime.t(), String.t() | nil) :: tabs()
  def rows(alerts, %DateTime{} = now_utc, organization_timezone \\ nil) do
    missing = missing_target_ids(alerts)
    local = local_times(alerts, now_utc, organization_timezone)

    grouped =
      Map.new(
        alerts |> Enum.group_by(&tab(&1, NaiveDateTime.to_date(Map.fetch!(local, &1.id)))),
        fn {tab, tab_alerts} ->
          {tab, tab_alerts |> order(tab) |> Enum.map(&row(&1, Map.fetch!(local, &1.id), missing))}
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
  Returns the target identities that no longer resolve, per table.

  Each alert is checked against the version it was written against, so an alert
  of a sibling version is never satisfied by a row that happens to carry the same
  GTFS identifier. An alert whose source version has been deleted has no version
  that could still resolve an identity, so every identity it names is reported:
  the alert is about rows that no longer exist anywhere, which is exactly what
  Needs attention means. Its stored `target_reference` still carries the wire IDs
  and labels it was accepted with, so nothing is guessed and the message keeps
  naming what it named (CR-5).

  A UUID that cannot be parsed can never name a row, so it is reported as
  missing rather than left to reach a query.
  """
  @spec missing_target_ids([Alert.t()]) :: %{
          routes: MapSet.t(String.t()),
          stops: MapSet.t(String.t()),
          trips: MapSet.t(String.t())
        }
  def missing_target_ids(alerts) do
    by_version =
      alerts
      |> Enum.group_by(& &1.source_gtfs_version_id)

    # A version that no longer exists cannot resolve anything, so an alert left
    # without one reports every identity it names.
    {referenced, orphaned} =
      Enum.reduce(by_version, {empty_referenced(), empty_referenced()}, fn
        {nil, version_alerts}, {referenced, orphaned} ->
          ids =
            Enum.reduce(
              version_alerts,
              empty_referenced(),
              &merge_referenced(&2, referenced_ids(&1))
            )

          {referenced, merge_referenced(orphaned, ids)}

        {_version_id, version_alerts}, {referenced, orphaned} ->
          ids =
            Enum.reduce(
              version_alerts,
              empty_referenced(),
              &merge_referenced(&2, referenced_ids(&1))
            )

          {merge_referenced(referenced, ids), orphaned}
      end)

    missing =
      by_version
      |> Enum.filter(fn {version_id, _alerts} -> not is_nil(version_id) end)
      |> Enum.reduce(empty_sets(), fn {version_id, _alerts}, acc ->
        merge_sets(acc, %{
          routes: missing_ids(Route, version_id, referenced.routes),
          stops: missing_ids(Stop, version_id, referenced.stops),
          trips: missing_ids(Trip, version_id, referenced.trips)
        })
      end)

    %{
      routes: MapSet.union(missing.routes, MapSet.new(orphaned.routes)),
      stops: MapSet.union(missing.stops, MapSet.new(orphaned.stops)),
      trips: MapSet.union(missing.trips, MapSet.new(orphaned.trips))
    }
  end

  defp empty_referenced, do: %{routes: [], stops: [], trips: []}

  defp empty_sets, do: %{routes: MapSet.new(), stops: MapSet.new(), trips: MapSet.new()}

  defp merge_sets(left, right) do
    Map.new(left, fn {table, ids} -> {table, MapSet.union(ids, Map.fetch!(right, table))} end)
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

  defp row(%Alert{} = alert, local_now, missing) do
    %{
      alert: alert,
      needs_attention?: needs_attention?(alert, missing),
      check_in_due?: check_in_due?(alert, local_now)
    }
  end

  defp needs_attention?(%Alert{} = alert, missing) do
    Enum.any?(referenced_ids(alert), fn {table, ids} ->
      Enum.any?(ids, &MapSet.member?(missing[table], &1))
    end)
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
  Returns every route, stop and trip row UUID the alert's scope names.

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

  defp merge_referenced(left, right) do
    Map.new(left, fn {table, ids} -> {table, ids ++ Map.fetch!(right, table)} end)
  end

  defp scope_pairs(nil), do: []

  defp scope_pairs(%{route_stop_pairs: pairs}) when is_list(pairs),
    do: Enum.reject(pairs, &is_nil/1)

  defp scope_pairs(_scope), do: []

  defp scope_trips(nil), do: []

  defp scope_trips(%{trips: trips}) when is_list(trips),
    do: Enum.reject(trips, &is_nil/1)

  defp scope_trips(_scope), do: []

  # One existence query per table for every referenced identity at once. An
  # unparseable identity is simply absent from the result, which is exactly what
  # it is.
  defp missing_ids(schema, gtfs_version_id, referenced) do
    referenced = MapSet.new(referenced)

    case Enum.filter(referenced, &match?({:ok, _uuid}, Ecto.UUID.cast(&1))) do
      [] ->
        referenced

      candidates ->
        present =
          from(t in schema,
            where: t.gtfs_version_id == ^gtfs_version_id and t.id in ^candidates,
            select: t.id
          )
          |> Repo.all()
          |> MapSet.new()

        MapSet.difference(referenced, present)
    end
  end
end

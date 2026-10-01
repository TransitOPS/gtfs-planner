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

  `check_in_due?` compares the stored `check_in_at` with the agency-local time
  the caller passes in. Both are civil values in the agency's own zone, so this
  module converts nothing between zones (CR-7); `Alerts.agency_now/1` supplies
  that time.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.TimingAnswer
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
  Builds the four tabs for the alerts of one version, as of `local_now`.

  `local_now` is the agency's own civil time, so `today` is that value's date
  rather than a UTC date. Every tab is always present in the result, empty or
  not, so the list page can show counts without special-casing a missing key.
  """
  @spec rows([Alert.t()], Ecto.UUID.t(), NaiveDateTime.t()) :: tabs()
  def rows(alerts, gtfs_version_id, %NaiveDateTime{} = local_now) do
    today = NaiveDateTime.to_date(local_now)
    missing = missing_target_ids(alerts, gtfs_version_id)

    grouped =
      Map.new(alerts |> Enum.group_by(&tab(&1, today)), fn {tab, tab_alerts} ->
        {tab, tab_alerts |> order(tab) |> Enum.map(&row(&1, local_now, missing))}
      end)

    # Every tab is present even when it holds nothing, so the list page can read
    # a count without special-casing an absent key.
    Map.new(@tabs, fn tab -> {tab, Map.get(grouped, tab, [])} end)
  end

  @doc """
  Returns the target identities no longer present in the version, per table.

  A UUID that cannot be parsed can never name a row, so it is reported as
  missing rather than left to reach a query.
  """
  @spec missing_target_ids([Alert.t()], Ecto.UUID.t()) :: %{
          routes: MapSet.t(String.t()),
          stops: MapSet.t(String.t()),
          trips: MapSet.t(String.t())
        }
  def missing_target_ids(alerts, gtfs_version_id) do
    referenced =
      Enum.reduce(alerts, %{routes: [], stops: [], trips: []}, fn alert, acc ->
        merge_referenced(acc, referenced_ids(alert))
      end)

    %{
      routes: missing_ids(Route, gtfs_version_id, referenced.routes),
      stops: missing_ids(Stop, gtfs_version_id, referenced.stops),
      trips: missing_ids(Trip, gtfs_version_id, referenced.trips)
    }
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
  # with the same date or timestamp keep a stable order across reads.
  defp order(alerts, tab) when tab in [:current, :upcoming] do
    Enum.sort_by(alerts, &{&1.first_date == nil, &1.first_date, &1.id})
  end

  defp order(alerts, :in_progress), do: sort_descending(alerts, & &1.updated_at)

  defp order(alerts, :past), do: sort_descending(alerts, & &1.last_date)

  # Descending with absent values last, so a row without the value it is ordered
  # by never leads its tab.
  defp sort_descending(alerts, value) do
    {present, absent} = Enum.split_with(alerts, &(not is_nil(value.(&1))))

    Enum.sort_by(present, &{value.(&1), &1.id}, :desc) ++ Enum.sort_by(absent, & &1.id)
  end

  defp ended_before?(nil, _today), do: false
  defp ended_before?(last_date, today), do: Date.compare(last_date, today) == :lt

  # -- Referenced target identities ---------------------------------------

  # Every identity the scope names, wherever the operator entered it. A single
  # value, a stretch end, a boarding alternative, a route and stop pair and a
  # cancelled departure are all targets a version edit could remove.
  defp referenced_ids(%Alert{scope: scope}) do
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
      {table, ids |> Enum.flat_map(&List.wrap/1) |> Enum.reject(&is_nil/1)}
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

defmodule GtfsPlanner.Gtfs.ServiceQueries do
  @moduledoc """
  Bounded, scoped, read-only service-date answers over one database snapshot.

  `departures/2` answers "what leaves this boarding occurrence after this
  service-day boundary", `coverage/2` answers "which of these routes keep
  recorded service on these dates", and `compare_dates/2` applies the same
  per-date result rules across an explicit date set. All three read every row
  they report inside one PostgreSQL `REPEATABLE READ READ ONLY` transaction
  (`ServiceQueries.Snapshot`), derive one content digest from that snapshot,
  write no GTFS row, and release the transaction before any caller makes a model
  request (INV-3, AC-12).

  ## Contracts and domain rules

    * Organization and version come from `scope`; every route is resolved inside
      them, so a foreign, deleted or malformed route is `{:error, :not_found}`
      rather than another tenant's metadata.
    * `scope.route_id` is the route the server already bound to the conversation.
      `departures/2` requires it. `coverage/2` and `compare_dates/2` take 1-20
      explicit GTFS route IDs and resolve each one in scope, because the Calendar
      page asks about several routes at once.
    * Service is evaluated with `Calendars.ServiceDates.active_dates_between/4`
      over the scoped weekly rows and exceptions, so a date exception overrides
      the weekly baseline and an exception-only calendar with no weekly row is
      still service. A calendar name is never consulted. A malformed weekly
      range or a contradictory exception is unreadable source: a departures
      answer refuses with the service named, and a coverage record becomes
      undetermined (`recorded_service? == nil`) with `:unreadable_calendar`.
      Neither asserts a complete total.
    * An occurrence is a stop plus its `stop_sequence` in one trip. A loop visit
      is a different occurrence of the same stop. `departures/2` never guesses:
      a selection without a `stop_sequence` resolves only when exactly one
      occurrence of that stop runs on the date, and otherwise returns
      `{:error, {:ambiguous_occurrence, candidates}}` or
      `{:error, :occurrence_not_found}` so the caller asks again with one of the
      candidates.
    * "After" is strictly greater than the boundary. Ordering uses integer
      service-day seconds, so `24:30` follows `23:50`. A departure at or past
      `24:00` on the same service day is included only when the caller asks for
      after-midnight service.
    * A `frequencies.txt` row's start and end are at the trip's first stop, so
      the window is translated by the selected occurrence's departure offset
      from that first stop. The end stays exclusive, `exact_times` is carried
      through, both kinds stay typed windows, neither is expanded here, and
      neither contributes to the exact departure `total`.
    * A row with no usable departure time at the occurrence is an
      `unknown_time` disclosure. It is never a match to a time predicate and
      never appears in `total`.
    * The route agency's IANA zone is resolved inside the same snapshot: the
      route's own agency when it names one, otherwise the sole scoped agency. A
      missing, invalid or conflicting zone refuses the local-clock answer instead
      of falling back to UTC.
    * Bounds are checked before any completeness claim: at most 31 dates, 20
      routes and 10,000 examined stop-time occurrences per query. An over-limit
      request is refused with a narrowing path; within the bound `total` is the
      complete server-computed count even when a returned row list is shortened
      for transport. No total is silently truncated.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Schedules.FrequencyWindows
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # Conservative engineering ceilings, not measured workloads. Each is checked
  # through the query's own limit, so an over-limit request never loads an
  # unbounded row set before it is refused.
  @max_dates 31
  @max_routes 20
  @max_examined_occurrences 10_000
  @service_day_seconds 86_400

  @typedoc "Server-owned organization and version, plus the route bound to the conversation."
  @type scope :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:route_id) => Ecto.UUID.t() | nil
        }

  @typedoc "One resolved boarding occurrence of a stop inside a trip."
  @type occurrence :: %{stop_id: String.t(), stop_sequence: non_neg_integer()}

  @typedoc """
  A listed departure with a usable time at the selected occurrence.

  `secs` is the integer service-day value the ordering and the boundary
  comparison use; `time` is its formatted GTFS string.
  """
  @type listed_departure :: %{
          kind: :listed,
          trip_id: String.t(),
          service_id: String.t(),
          stop_id: String.t(),
          stop_sequence: non_neg_integer(),
          secs: pos_integer(),
          time: String.t()
        }

  @typedoc """
  One frequency window translated to the boarding occurrence.

  `start_secs`/`end_secs` are service-day seconds at the occurrence and
  `end_secs` is exclusive. `exact_times` keeps the two frequency kinds distinct,
  `expanded?` is false in this slice, and neither kind contributes to the exact
  departure `total`.
  """
  @type frequency_window :: %{
          kind: :frequency_window,
          trip_id: String.t(),
          service_id: String.t(),
          stop_id: String.t(),
          stop_sequence: non_neg_integer(),
          start_secs: non_neg_integer(),
          end_secs: non_neg_integer(),
          start_time: String.t(),
          end_time: String.t(),
          headway_secs: pos_integer(),
          exact_times: 0 | 1,
          expanded?: false,
          offset_secs: integer(),
          matching_departures: pos_integer()
        }

  @typedoc "An active trip with no usable departure time at the selected occurrence."
  @type unknown_time :: %{
          kind: :unknown_time,
          trip_id: String.t(),
          service_id: String.t(),
          stop_id: String.t(),
          stop_sequence: non_neg_integer()
        }

  @typedoc "Why a row did not become a listed departure, and how many rows it covered."
  @type exclusion :: %{reason: atom(), count: non_neg_integer(), detail: String.t() | nil}

  @typedoc "An undetermined or refused fact; completeness is never `:complete` beside one."
  @type disclosure :: %{reason: atom(), detail: String.t()}

  @typedoc "The answer of `departures/2`."
  @type departures_result :: %{
          scope: scope(),
          route: %{
            id: Ecto.UUID.t(),
            route_id: String.t(),
            state: :active | :inactive,
            agency_id: String.t() | nil
          },
          service_date: Date.t(),
          direction_id: 0 | 1 | nil,
          occurrence: occurrence() | nil,
          stop_name: String.t() | nil,
          after_secs: non_neg_integer(),
          include_after_midnight?: boolean(),
          departures: [listed_departure()],
          frequency_windows: [frequency_window()],
          unknown_times: [unknown_time()],
          exclusions: [exclusion()],
          active_service_ids: [String.t()],
          timezone: String.t(),
          total: non_neg_integer() | nil,
          completeness: :complete | :incomplete,
          disclosures: [disclosure()],
          digest: String.t()
        }

  @typedoc "Why a route/date pair has no undetermined-or-active recorded service."
  @type absence_reason ::
          :inactive_route | :no_recorded_trips | :no_active_trip | :unreadable_calendar

  @typedoc """
  One route/date coverage record. `recorded_service?` is `nil` when a relevant
  calendar could not be read, so an undetermined date is never reported as zero
  service.
  """
  @type coverage_record :: %{
          route_id: String.t(),
          date: Date.t(),
          recorded_service?: boolean() | nil,
          listed_trip_templates: non_neg_integer(),
          frequency_templates: non_neg_integer(),
          missing_time_templates: non_neg_integer(),
          service_ids: [String.t()],
          alternate_service_ids: [String.t()],
          route_state: :active | :inactive,
          absence_reason: absence_reason() | nil,
          unreadable_service_ids: [String.t()]
        }

  @typedoc "The answer of `coverage/2`."
  @type coverage_result :: %{
          scope: scope(),
          records: [coverage_record()],
          total: non_neg_integer() | nil,
          completeness: :complete | :incomplete,
          disclosures: [disclosure()],
          digest: String.t()
        }

  @typedoc "How one route's recorded service differs across the requested dates."
  @type route_comparison :: %{
          route_id: String.t(),
          dates_with_service: [Date.t()],
          dates_without_service: [Date.t()],
          undetermined_dates: [Date.t()],
          first_service_date: Date.t() | nil,
          last_service_date: Date.t() | nil,
          service_ids: [String.t()]
        }

  @typedoc "The answer of `compare_dates/2`."
  @type comparison_result :: %{
          scope: scope(),
          dates: [Date.t()],
          records: [coverage_record()],
          comparisons: [route_comparison()],
          total: non_neg_integer() | nil,
          completeness: :complete | :incomplete,
          disclosures: [disclosure()],
          digest: String.t()
        }

  @type error ::
          :not_found
          | :invalid_selection
          | :too_many_dates
          | :too_many_routes
          | :too_large
          | :occurrence_not_found
          | {:ambiguous_occurrence, [occurrence()]}
          | {:unreadable_calendar, String.t()}
          | {:timezone_unavailable, DisplayClock.fallback_reason()}

  @doc """
  Returns the bound this module refuses to exceed: the most stop-time
  occurrences one query may examine before it is refused with `:too_large`.

  The limit is enforced by the queries' own `LIMIT`, so an over-limit
  route/date never materializes an unbounded row set. It is public so the bound
  a caller is told about and the bound the query enforces cannot drift apart.
  """
  @spec examined_occurrence_limit() :: pos_integer()
  def examined_occurrence_limit, do: @max_examined_occurrences

  @doc """
  Returns the coverage ceilings: the most dates and the most routes one coverage
  or comparison request may name.
  """
  @spec coverage_limits() :: %{dates: pos_integer(), routes: pos_integer()}
  def coverage_limits, do: %{dates: @max_dates, routes: @max_routes}

  @doc """
  Returns the listed departures, translated frequency windows and unknown-time
  disclosures after `selection.after_secs` at one resolved boarding occurrence.

  `selection` is

      %{service_date: Date.t(),
        after_secs: non_neg_integer(),
        include_after_midnight?: boolean(),
        direction_id: 0 | 1 | nil,
        occurrence: %{stop_id: String.t(), stop_sequence: non_neg_integer() | nil}}

  The route is `scope.route_id`. A missing route in the scope, a malformed
  selection, an unresolved occurrence, an unreadable calendar, an ambiguous or
  unusable agency zone and more than 10,000 examined stop-time occurrences are
  each a distinct refusal, and none of them reports a total.

  `total` counts the exact listed departures only: a translated frequency window
  and an unknown time are typed disclosures, never matches. It is `nil` whenever
  `completeness` is `:incomplete`.
  """
  @spec departures(scope(), map()) :: {:ok, departures_result()} | {:error, error()}
  def departures(scope, selection) when is_map(scope) and is_map(selection) do
    with {:ok, organization_id, gtfs_version_id} <- scoped_ids(scope),
         {:ok, route_id} <- bound_route_id(scope),
         {:ok, departure_selection} <- departure_selection(selection) do
      in_snapshot(fn ->
        departure_answer(organization_id, gtfs_version_id, route_id, departure_selection)
      end)
    end
  end

  def departures(_scope, _selection), do: {:error, :invalid_selection}

  @doc """
  Returns one coverage record per requested route and date.

  `selection` is `%{dates: [Date.t()], route_ids: [String.t()], service_id:
  String.t() | nil}`. `service_id` names the calendar under review; the
  `alternate_service_ids` of each record are then the other services that still
  run that route on that date, which is how a route keeps service after the
  reviewed calendar ends. Without a named calendar every active service is
  listed, so nothing is hidden.

  At most 31 dates and 20 routes are accepted (`{:error, :too_many_dates}` and
  `{:error, :too_many_routes}`); a route outside the scope is
  `{:error, :not_found}`. A frequency template is evidence of service, not a
  known number of departures, and a trip with a missing departure time still
  counts as service.
  """
  @spec coverage(scope(), map()) :: {:ok, coverage_result()} | {:error, error()}
  def coverage(scope, selection) when is_map(scope) and is_map(selection) do
    with {:ok, organization_id, gtfs_version_id} <- scoped_ids(scope),
         {:ok, coverage_selection} <- coverage_selection(selection) do
      in_snapshot(fn -> coverage_answer(organization_id, gtfs_version_id, coverage_selection) end)
    end
  end

  def coverage(_scope, _selection), do: {:error, :invalid_selection}

  @doc """
  Applies the same per-date coverage rules across an explicit date set and
  reports, per route, the dates that keep recorded service and the dates that do
  not.

  `selection` is the `coverage/2` selection. A route with identical service on
  every date is still listed, so a comparison never hides a route that did not
  change. An undetermined date appears in neither date list and keeps the answer
  `:incomplete`.
  """
  @spec compare_dates(scope(), map()) :: {:ok, comparison_result()} | {:error, error()}
  def compare_dates(scope, selection) when is_map(scope) and is_map(selection) do
    with {:ok, organization_id, gtfs_version_id} <- scoped_ids(scope),
         {:ok, coverage_selection} <- coverage_selection(selection),
         {:ok, answer} <-
           in_snapshot(fn ->
             coverage_answer(organization_id, gtfs_version_id, coverage_selection)
           end) do
      {:ok,
       Map.merge(answer, %{
         dates: coverage_selection.dates,
         comparisons: comparisons(answer.records, coverage_selection.route_ids)
       })}
    end
  end

  def compare_dates(_scope, _selection), do: {:error, :invalid_selection}

  # -- snapshot boundary ------------------------------------------------------

  # Every source read of one answer happens inside this transaction, and the
  # digest is derived from the rows it returned. The transaction is closed
  # before the caller builds a model request, so no provider call is ever made
  # while the snapshot is held.
  defp in_snapshot(fun) when is_function(fun, 0) do
    Repo.transaction(
      fn ->
        snapshot_module().begin_read()
        fun.()
      end,
      timeout: :infinity
    )
    |> case do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp snapshot_module do
    Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot, Snapshot.Repo)
  end

  # -- scope and selection ---------------------------------------------------

  defp scoped_ids(scope) do
    with {:ok, organization_id} <- Ecto.UUID.cast(Map.get(scope, :organization_id)),
         {:ok, gtfs_version_id} <- Ecto.UUID.cast(Map.get(scope, :gtfs_version_id)) do
      {:ok, organization_id, gtfs_version_id}
    else
      _other -> {:error, :not_found}
    end
  end

  defp bound_route_id(scope) do
    case Ecto.UUID.cast(Map.get(scope, :route_id)) do
      {:ok, route_id} -> {:ok, route_id}
      _other -> {:error, :invalid_selection}
    end
  end

  defp departure_answer(organization_id, gtfs_version_id, route_id, selection) do
    with {:ok, route} <- scoped_route(organization_id, gtfs_version_id, route_id),
         {:ok, timezone} <- service_timezone(organization_id, gtfs_version_id, route),
         {:ok, active_trips, active_service_ids} <-
           active_trips(organization_id, gtfs_version_id, route, selection),
         {:ok, stop_times, frequencies} <-
           scoped_occurrence_rows(organization_id, gtfs_version_id, active_trips) do
      evaluate_departures(
        %{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          route: route,
          timezone: timezone,
          active_trips: active_trips,
          active_service_ids: active_service_ids,
          stop_times: stop_times,
          frequencies: frequencies
        },
        selection
      )
    end
  end

  defp departure_selection(selection) do
    occurrence = Map.get(selection, :occurrence)
    stop_id = if is_map(occurrence), do: Map.get(occurrence, :stop_id), else: nil

    if valid_departure_selection?(selection, occurrence, stop_id) do
      {:ok,
       %{
         service_date: Map.get(selection, :service_date),
         after_secs: Map.get(selection, :after_secs),
         include_after_midnight?: Map.get(selection, :include_after_midnight?),
         direction_id: Map.get(selection, :direction_id),
         stop_id: stop_id,
         stop_sequence: occurrence_stop_sequence(occurrence)
       }}
    else
      {:error, :invalid_selection}
    end
  end

  defp valid_departure_selection?(selection, occurrence, stop_id) do
    after_secs = Map.get(selection, :after_secs)

    match?(%Date{}, Map.get(selection, :service_date)) and is_integer(after_secs) and
      after_secs >= 0 and is_boolean(Map.get(selection, :include_after_midnight?)) and
      valid_direction?(Map.get(selection, :direction_id)) and is_binary(stop_id) and
      stop_id != "" and valid_stop_sequence?(occurrence)
  end

  defp valid_direction?(direction_id), do: is_nil(direction_id) or direction_id in [0, 1]

  # A missing `stop_sequence` is a request for the unambiguous occurrence, not
  # a malformed value.
  defp valid_stop_sequence?(occurrence) when is_map(occurrence) do
    case Map.get(occurrence, :stop_sequence) do
      sequence when is_integer(sequence) and sequence >= 0 -> true
      nil -> Map.keys(occurrence) |> Enum.sort() == [:stop_id, :stop_sequence]
      _other -> false
    end
  end

  defp valid_stop_sequence?(_occurrence), do: false

  defp occurrence_stop_sequence(occurrence) do
    case Map.get(occurrence, :stop_sequence) do
      sequence when is_integer(sequence) and sequence >= 0 -> sequence
      _other -> nil
    end
  end

  defp coverage_selection(selection) do
    requested_dates = Map.get(selection, :dates)
    requested_routes = Map.get(selection, :route_ids)
    service_id = Map.get(selection, :service_id)

    if is_list(requested_dates) and is_list(requested_routes) do
      bounded_coverage_selection(requested_dates, requested_routes, service_id)
    else
      {:error, :invalid_selection}
    end
  end

  defp bounded_coverage_selection(requested_dates, requested_routes, service_id) do
    dates = Enum.filter(requested_dates, &match?(%Date{}, &1))
    route_ids = Enum.filter(requested_routes, &valid_route_id?/1)

    with true <- dates != [] and dates == requested_dates,
         true <- route_ids != [] and route_ids == requested_routes,
         true <- length(Enum.uniq(dates)) == length(dates),
         true <- length(Enum.uniq(route_ids)) == length(route_ids),
         true <- valid_reviewed_service?(service_id),
         {:ok, _sorted} <- within_coverage_limits(dates, route_ids) do
      {:ok,
       %{
         dates: Enum.sort(dates, Date),
         route_ids: Enum.sort(route_ids),
         service_id: service_id
       }}
    else
      {:error, :too_many_dates} -> {:error, :too_many_dates}
      {:error, :too_many_routes} -> {:error, :too_many_routes}
      _other -> {:error, :invalid_selection}
    end
  end

  defp valid_reviewed_service?(service_id),
    do: is_nil(service_id) or (is_binary(service_id) and service_id != "")

  defp within_coverage_limits(dates, route_ids) do
    cond do
      length(dates) > @max_dates -> {:error, :too_many_dates}
      length(route_ids) > @max_routes -> {:error, :too_many_routes}
      true -> {:ok, :ok}
    end
  end

  defp valid_route_id?(route_id), do: is_binary(route_id) and route_id != ""

  # -- scoped reads ----------------------------------------------------------

  defp scoped_route(organization_id, gtfs_version_id, route_uuid) do
    query =
      from(r in Route,
        join: v in GtfsVersion,
        on: v.id == r.gtfs_version_id and v.organization_id == r.organization_id,
        where:
          r.id == ^route_uuid and r.organization_id == ^organization_id and
            r.gtfs_version_id == ^gtfs_version_id
      )

    case Repo.one(query) do
      %Route{} = route -> {:ok, route}
      nil -> {:error, :not_found}
    end
  end

  defp scoped_route_by_gtfs_id(organization_id, gtfs_version_id, gtfs_route_id) do
    query =
      from(r in Route,
        where:
          r.organization_id == ^organization_id and r.gtfs_version_id == ^gtfs_version_id and
            r.route_id == ^gtfs_route_id
      )

    case Repo.all(query, limit: 2) do
      [%Route{} = route] -> {:ok, route}
      _other -> {:error, :not_found}
    end
  end

  defp scoped_trips(organization_id, gtfs_version_id, gtfs_route_id, direction_id) do
    query =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and t.gtfs_version_id == ^gtfs_version_id and
            t.route_id == ^gtfs_route_id
      )

    query =
      if is_nil(direction_id) do
        query
      else
        from(t in query, where: t.direction_id == ^direction_id)
      end

    query
    |> order_by([t], asc: t.trip_id, asc: t.id)
    |> Repo.all()
  end

  # `%{service_id => {Calendar.t() | nil, [CalendarDate.t()]}}` for exactly the
  # services the scoped trips reference. A service with no weekly row maps to
  # `{nil, []}`, which `ServiceDates` reads as dates-only service rather than as
  # a second calendar rule.
  defp scoped_calendars(organization_id, gtfs_version_id, service_ids) do
    service_ids = Enum.uniq(service_ids)

    calendars =
      from(c in Calendar,
        where:
          c.organization_id == ^organization_id and c.gtfs_version_id == ^gtfs_version_id and
            c.service_id in ^service_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.service_id, &1})

    exceptions =
      from(d in CalendarDate,
        where:
          d.organization_id == ^organization_id and d.gtfs_version_id == ^gtfs_version_id and
            d.service_id in ^service_ids,
        order_by: [asc: d.service_id, asc: d.date]
      )
      |> Repo.all()

    grouped = Enum.group_by(exceptions, & &1.service_id)

    Map.new(service_ids, fn service_id ->
      {service_id, {Map.get(calendars, service_id), Map.get(grouped, service_id, [])}}
    end)
  end

  # The date evaluator is pure but raises for unreadable retained calendar
  # source; an unreadable service is a disclosed fact here, never a zero.
  defp active_on?(calendars, service_id, %Date{} = date) do
    {calendar, exceptions} = Map.fetch!(calendars, service_id)

    try do
      {:ok, date in ServiceDates.active_dates_between(calendar, exceptions, date, date)}
    rescue
      ArgumentError -> {:error, {:unreadable_calendar, service_id}}
    end
  end

  defp active_trips(organization_id, gtfs_version_id, %Route{} = route, selection) do
    trips = scoped_trips(organization_id, gtfs_version_id, route.route_id, selection.direction_id)

    calendars =
      scoped_calendars(organization_id, gtfs_version_id, Enum.map(trips, & &1.service_id))

    active =
      Enum.reduce_while(trips, {:ok, []}, fn trip, {:ok, active} ->
        case active_on?(calendars, trip.service_id, selection.service_date) do
          {:ok, true} -> {:cont, {:ok, [trip | active]}}
          {:ok, false} -> {:cont, {:ok, active}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case active do
      {:error, reason} ->
        {:error, reason}

      {:ok, active_trips} ->
        service_ids = active_trips |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort()
        {:ok, Enum.reverse(active_trips), service_ids}
    end
  end

  # Both row sets are bounded by the query's own limit, so an over-limit
  # route/date never materializes an unbounded result before it is refused.
  defp scoped_occurrence_rows(organization_id, gtfs_version_id, active_trips) do
    trip_ids = Enum.map(active_trips, & &1.trip_id)

    if trip_ids == [] do
      {:ok, [], []}
    else
      stop_times =
        from(s in StopTime,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
              s.trip_id in ^trip_ids,
          order_by: [asc: s.trip_id, asc: s.stop_sequence, asc: s.id],
          limit: @max_examined_occurrences + 1
        )
        |> Repo.all()

      if length(stop_times) > @max_examined_occurrences do
        {:error, :too_large}
      else
        frequencies =
          from(f in Frequency,
            where:
              f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
                f.trip_id in ^trip_ids,
            order_by: [asc: f.trip_id, asc: f.start_time, asc: f.id],
            limit: @max_examined_occurrences + 1
          )
          |> Repo.all()

        {:ok, stop_times, frequencies}
      end
    end
  end

  defp scoped_stop_name(organization_id, gtfs_version_id, stop_id) do
    query =
      from(s in Stop,
        where:
          s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
            s.stop_id == ^stop_id,
        limit: 1
      )

    case Repo.one(query) do
      %Stop{stop_name: name} -> name
      nil -> nil
    end
  end

  # The local-clock claim needs the route agency's own zone, resolved inside the
  # same snapshot. `DisplayClock`'s UTC fallback is a presentation fallback and
  # is refused here, so an ambiguous, invalid or missing zone never becomes a
  # service time claim.
  defp service_timezone(organization_id, gtfs_version_id, %Route{agency_id: nil}) do
    case DisplayClock.resolve_zone(organization_id, gtfs_version_id) do
      %{fallback?: false, timezone: timezone} -> {:ok, timezone}
      %{fallback_reason: reason} -> {:error, {:timezone_unavailable, reason}}
    end
  end

  defp service_timezone(organization_id, gtfs_version_id, %Route{agency_id: agency_id}) do
    query =
      from(a in Agency,
        where:
          a.organization_id == ^organization_id and a.gtfs_version_id == ^gtfs_version_id and
            a.agency_id == ^agency_id
      )

    case Repo.one(query) do
      nil -> {:error, {:timezone_unavailable, :missing}}
      %Agency{agency_timezone: timezone} -> usable_agency_zone(timezone)
    end
  end

  defp usable_agency_zone(timezone) do
    case timezone && String.trim(timezone) do
      "" -> {:error, {:timezone_unavailable, :missing}}
      trimmed -> validated_agency_zone(trimmed)
    end
  end

  defp validated_agency_zone(trimmed) do
    if DisplayClock.valid_zone?(trimmed),
      do: {:ok, trimmed},
      else: {:error, {:timezone_unavailable, :invalid}}
  end

  # -- departures ------------------------------------------------------------

  defp evaluate_departures(inputs, selection) do
    scope = %{
      organization_id: inputs.organization_id,
      gtfs_version_id: inputs.gtfs_version_id,
      route_id: inputs.route.id
    }

    cond do
      inputs.route.active == false ->
        {:ok,
         empty_answer(
           inputs,
           scope,
           selection,
           nil,
           :inactive_route,
           "The route is inactive in this version."
         )}

      # No calendar makes the route run on this date: that is an empty answer
      # with a named cause, never a refused occurrence and never an error.
      inputs.active_trips == [] ->
        {:ok,
         empty_answer(
           inputs,
           scope,
           selection,
           nil,
           :no_active_trip,
           "No calendar runs this route on that date."
         )}

      true ->
        with {:ok, occurrence} <- resolve_occurrence(inputs, selection) do
          answer_departures(inputs, selection, scope, occurrence)
        end
    end
  end

  # An answer with no listed departure is still a complete answer when the query
  # could read every relevant row; the cause is named so zero is never mistaken
  # for "no service at all".
  defp empty_answer(inputs, scope, selection, occurrence, reason, detail) do
    digest_value = %{
      scope: scope,
      route: inputs.route.route_id,
      state: inputs.route.active,
      selection: selection,
      absence: reason
    }

    {:ok,
     %{
       scope: scope,
       route: route_summary(inputs.route),
       service_date: selection.service_date,
       direction_id: selection.direction_id,
       occurrence: occurrence,
       stop_name: nil,
       after_secs: selection.after_secs,
       include_after_midnight?: selection.include_after_midnight?,
       departures: [],
       frequency_windows: [],
       unknown_times: [],
       exclusions: [exclusion(reason, 0, detail)],
       active_service_ids: inputs.active_service_ids,
       timezone: inputs.timezone,
       total: 0,
       completeness: :complete,
       disclosures: [],
       digest: digest(digest_value)
     }}
  end

  defp answer_departures(inputs, selection, scope, occurrence) do
    frequency_trip_ids = inputs.frequencies |> Enum.map(& &1.trip_id) |> MapSet.new()

    rows =
      Enum.map(
        inputs.active_trips,
        &occurrence_row(inputs, selection, &1, occurrence, frequency_trip_ids)
      )

    {listed, unknown, before_boundary, after_midnight, unvisited, templates} =
      Enum.reduce(rows, {[], [], 0, 0, 0, 0}, fn
        {:unvisited, nil, nil}, {listed, unknown, before, late, unvisited, templates} ->
          {listed, unknown, before, late, unvisited + 1, templates}

        {:frequency_template, nil, nil}, {listed, unknown, before, late, unvisited, templates} ->
          {listed, unknown, before, late, unvisited, templates + 1}

        {:listed, row, _secs}, {listed, unknown, before, late, unvisited, templates} ->
          {listed ++ [row], unknown, before, late, unvisited, templates}

        {:unknown, row, nil}, {listed, unknown, before, late, unvisited, templates} ->
          {listed, unknown ++ [row], before, late, unvisited, templates}

        {:excluded_before, nil, nil}, {listed, unknown, before, late, unvisited, templates} ->
          {listed, unknown, before + 1, late, unvisited, templates}

        {:excluded_after_midnight, nil, nil},
        {listed, unknown, before, late, unvisited, templates} ->
          {listed, unknown, before, late + 1, unvisited, templates}
      end)

    windows = frequency_windows(inputs, selection, occurrence)

    exclusions =
      [
        exclusion(:no_boarding_occurrence, unvisited, nil),
        exclusion(:frequency_template, templates, nil),
        exclusion(:before_boundary, before_boundary, nil),
        exclusion(:after_midnight_excluded, after_midnight, nil)
      ]
      |> Enum.reject(&(&1.count == 0))

    result = %{
      scope: scope,
      route: route_summary(inputs.route),
      service_date: selection.service_date,
      direction_id: selection.direction_id,
      occurrence: occurrence,
      stop_name:
        scoped_stop_name(inputs.organization_id, inputs.gtfs_version_id, occurrence.stop_id),
      after_secs: selection.after_secs,
      include_after_midnight?: selection.include_after_midnight?,
      departures: Enum.sort_by(listed, &{&1.secs, &1.trip_id}),
      frequency_windows: Enum.sort_by(windows, &{&1.start_secs, &1.trip_id}),
      unknown_times: Enum.sort_by(unknown, & &1.trip_id),
      exclusions: exclusions,
      active_service_ids: inputs.active_service_ids,
      timezone: inputs.timezone,
      total: length(listed),
      completeness: :complete,
      disclosures: [],
      digest:
        digest(%{scope: scope, inputs: input_digest(inputs), selection: selection, rows: rows})
    }

    {:ok, result}
  end

  defp route_summary(%Route{} = route) do
    %{
      id: route.id,
      route_id: route.route_id,
      state: if(route.active, do: :active, else: :inactive),
      agency_id: route.agency_id
    }
  end

  defp exclusion(reason, count, detail), do: %{reason: reason, count: count, detail: detail}

  # An occurrence is a `(stop, stop_sequence)` pair, so a loop's second visit is
  # a different occurrence of the same stop, and several trips sharing one
  # sequence are one occurrence rather than a choice. Nothing here picks a
  # `stop_sequence` for the caller.
  defp resolve_occurrence(inputs, selection) do
    sequences =
      inputs.active_trips
      |> Enum.flat_map(fn trip ->
        inputs.stop_times
        |> Enum.filter(&(&1.trip_id == trip.trip_id and &1.stop_id == selection.stop_id))
        |> Enum.map(& &1.stop_sequence)
      end)
      |> Enum.uniq()
      |> Enum.sort()

    resolved =
      case selection.stop_sequence do
        nil -> single_sequence(sequences)
        sequence -> if sequence in sequences, do: [sequence], else: []
      end

    case resolved do
      [] ->
        {:error, :occurrence_not_found}

      [sequence] ->
        {:ok, %{stop_id: selection.stop_id, stop_sequence: sequence}}

      many ->
        {:error,
         {:ambiguous_occurrence,
          Enum.map(many, &%{stop_id: selection.stop_id, stop_sequence: &1})}}
    end
  end

  # Without a `stop_sequence` the answer is one occurrence only when every
  # candidate agrees on the sequence; otherwise the caller must choose, and the
  # candidates are the exact sequences that answer this stop.
  defp single_sequence([sequence]), do: [sequence]
  defp single_sequence([]), do: []
  defp single_sequence(many), do: many

  defp occurrence_row(inputs, selection, trip, occurrence, frequency_trip_ids) do
    rows =
      Enum.filter(inputs.stop_times, fn row ->
        row.trip_id == trip.trip_id and row.stop_id == occurrence.stop_id and
          row.stop_sequence == occurrence.stop_sequence
      end)

    case rows do
      [] ->
        {:unvisited, nil, nil}

      [row | _rest] ->
        # A trip with a `frequencies.txt` row is a frequency template, not a
        # listed departure: its stop times anchor the window, so reporting them
        # as listed departures would double-count and invent departures. With no
        # usable occurrence time the window cannot be anchored, so the row is
        # disclosed as an unknown time instead.
        if MapSet.member?(frequency_trip_ids, trip.trip_id) and is_integer(row_seconds(row)) do
          {:frequency_template, nil, nil}
        else
          classify_row(selection, trip, occurrence, row)
        end
    end
  end

  defp classify_row(selection, trip, occurrence, row) do
    case row_seconds(row) do
      nil -> {:unknown, unknown_time(trip, occurrence), nil}
      secs -> classify_time(selection, trip, occurrence, secs)
    end
  end

  # "After" is strictly greater, and an after-midnight departure is only a match
  # when the caller asked for that part of the service day. Every clause returns
  # the same three-part shape so the counts can be folded in one reduce.
  defp classify_time(selection, trip, occurrence, secs) do
    cond do
      secs <= selection.after_secs ->
        {:excluded_before, nil, nil}

      secs >= @service_day_seconds and not selection.include_after_midnight? ->
        {:excluded_after_midnight, nil, nil}

      true ->
        {:listed, listed_departure(trip, occurrence, secs), secs}
    end
  end

  defp listed_departure(trip, occurrence, secs) do
    %{
      kind: :listed,
      trip_id: trip.trip_id,
      service_id: trip.service_id,
      stop_id: occurrence.stop_id,
      stop_sequence: occurrence.stop_sequence,
      secs: secs,
      time: GtfsTime.format(secs)
    }
  end

  defp unknown_time(trip, occurrence) do
    %{
      kind: :unknown_time,
      trip_id: trip.trip_id,
      service_id: trip.service_id,
      stop_id: occurrence.stop_id,
      stop_sequence: occurrence.stop_sequence
    }
  end

  # A `departure_time` is the boarding time; a trip that records only an
  # `arrival_time` still boards then. Both are absent or unparsable for the
  # unknown-time disclosure, which is never a match.
  defp row_seconds(%StopTime{} = row) do
    case GtfsTime.parse(row.departure_time || "") do
      {:ok, secs} -> secs
      {:error, :invalid_time} -> arrival_seconds(row)
    end
  end

  defp arrival_seconds(%StopTime{} = row) do
    case GtfsTime.parse(row.arrival_time || "") do
      {:ok, secs} -> secs
      {:error, :invalid_time} -> nil
    end
  end

  # A frequency window is anchored at the trip's first stop, so the boarding
  # window is that window translated by the selected occurrence's offset. The
  # end stays exclusive and an unusable frequency row is disclosed, not dropped.
  defp frequency_windows(inputs, selection, occurrence) do
    inputs.active_trips
    |> Enum.flat_map(fn trip ->
      inputs.frequencies
      |> Enum.filter(&(&1.trip_id == trip.trip_id))
      |> Enum.map(&translate_window(inputs, selection, trip, occurrence, &1))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp translate_window(inputs, selection, trip, occurrence, frequency) do
    with {:ok, first_secs} <- first_stop_seconds(inputs, trip.trip_id),
         occurrence_secs when is_integer(occurrence_secs) <-
           occurrence_row_seconds(inputs, trip, occurrence),
         {:ok, start_secs} <- GtfsTime.parse(frequency.start_time || ""),
         {:ok, end_secs} <- GtfsTime.parse(frequency.end_time || ""),
         true <- is_integer(frequency.headway_secs) and frequency.headway_secs > 0 do
      offset = occurrence_secs - first_secs
      boarding_start = start_secs + offset
      boarding_end = end_secs + offset

      matching =
        matching_window_departures(
          selection,
          boarding_start,
          boarding_end,
          frequency.headway_secs
        )

      if matching > 0 do
        %{
          kind: :frequency_window,
          trip_id: trip.trip_id,
          service_id: trip.service_id,
          stop_id: occurrence.stop_id,
          stop_sequence: occurrence.stop_sequence,
          start_secs: boarding_start,
          end_secs: boarding_end,
          start_time: GtfsTime.format(boarding_start),
          end_time: GtfsTime.format(boarding_end),
          headway_secs: frequency.headway_secs,
          exact_times: normalize_exact_times(frequency.exact_times),
          expanded?: false,
          offset_secs: offset,
          matching_departures: matching
        }
      end
    else
      _other -> nil
    end
  end

  defp normalize_exact_times(exact_times) when exact_times == 1, do: 1
  defp normalize_exact_times(_exact_times), do: 0

  # The window's own departure list is the ground truth for "does this window
  # answer the boundary": a window whose departures all precede the boundary is
  # not reported at all. An occurrence whose time cannot be read cannot anchor a
  # window, so that window is disclosed as unreadable rather than invented.
  defp matching_window_departures(selection, start_secs, end_secs, headway_secs) do
    %{start_secs: start_secs, end_secs: end_secs, headway_secs: headway_secs}
    |> FrequencyWindows.departures()
    |> Enum.count(&matches?(selection, &1))
  end

  defp matches?(selection, secs) do
    secs > selection.after_secs and
      (selection.include_after_midnight? or secs < @service_day_seconds)
  end

  defp occurrence_row_seconds(inputs, trip, occurrence) do
    inputs.stop_times
    |> Enum.filter(fn row ->
      row.trip_id == trip.trip_id and row.stop_id == occurrence.stop_id and
        row.stop_sequence == occurrence.stop_sequence
    end)
    |> Enum.find_value(fn row -> row_seconds(row) end)
  end

  defp first_stop_seconds(inputs, trip_id) do
    inputs.stop_times
    |> Enum.filter(&(&1.trip_id == trip_id))
    |> Enum.sort_by(&{&1.stop_sequence, &1.id})
    |> Enum.find_value({:error, :unusable_frequency_row}, fn row ->
      case row_seconds(row) do
        nil -> nil
        secs -> {:ok, secs}
      end
    end)
  end

  # -- coverage --------------------------------------------------------------

  defp coverage_answer(organization_id, gtfs_version_id, selection) do
    with {:ok, routes} <- load_routes(organization_id, gtfs_version_id, selection.route_ids) do
      records = coverage_records(organization_id, gtfs_version_id, routes, selection)
      incomplete = Enum.any?(records, &(&1.recorded_service? == nil))

      scope = %{
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        route_id: nil
      }

      {:ok,
       %{
         scope: scope,
         records: records,
         total: if(incomplete, do: nil, else: length(records)),
         completeness: if(incomplete, do: :incomplete, else: :complete),
         disclosures:
           if(incomplete,
             do: [
               disclosure(
                 :unreadable_calendar,
                 "At least one relevant calendar could not be read."
               )
             ],
             else: []
           ),
         digest: digest(%{scope: scope, selection: selection, records: records})
       }}
    end
  end

  # One record per requested route and date, each route's inputs read once.
  defp coverage_records(organization_id, gtfs_version_id, routes, selection) do
    routes
    |> Enum.flat_map(fn route ->
      input = route_inputs(organization_id, gtfs_version_id, route)

      Enum.flat_map(selection.dates, fn date ->
        coverage_record(input, date, selection)
      end)
    end)
    |> Enum.uniq_by(&{&1.route_id, &1.date})
  end

  defp load_routes(organization_id, gtfs_version_id, route_ids) do
    Enum.reduce_while(route_ids, {:ok, []}, fn route_id, {:ok, loaded} ->
      case scoped_route_by_gtfs_id(organization_id, gtfs_version_id, route_id) do
        {:ok, route} -> {:cont, {:ok, loaded ++ [route]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp route_inputs(organization_id, gtfs_version_id, %Route{} = route) do
    trips = scoped_trips(organization_id, gtfs_version_id, route.route_id, nil)

    calendars =
      scoped_calendars(organization_id, gtfs_version_id, Enum.map(trips, & &1.service_id))

    trip_ids = Enum.map(trips, & &1.trip_id)

    stop_times =
      if trip_ids == [] do
        %{}
      else
        from(s in StopTime,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^gtfs_version_id and
              s.trip_id in ^trip_ids,
          order_by: [asc: s.trip_id, asc: s.stop_sequence, asc: s.id],
          limit: @max_examined_occurrences + 1
        )
        |> Repo.all()
        |> Enum.group_by(& &1.trip_id)
      end

    frequency_trip_ids =
      if trip_ids == [] do
        MapSet.new()
      else
        from(f in Frequency,
          where:
            f.organization_id == ^organization_id and f.gtfs_version_id == ^gtfs_version_id and
              f.trip_id in ^trip_ids,
          select: f.trip_id,
          distinct: true
        )
        |> Repo.all()
        |> MapSet.new()
      end

    %{
      route: route,
      trips: trips,
      calendars: calendars,
      stop_times: stop_times,
      frequency_trip_ids: frequency_trip_ids
    }
  end

  defp coverage_record(input, date, selection) do
    case active_trip_ids(input, date) do
      {:error, reason} -> [unreadable_record(input.route, date, reason)]
      active_trips -> [service_record(input, date, selection, active_trips)]
    end
  end

  defp active_trip_ids(%{trips: trips, calendars: calendars}, date) do
    Enum.reduce_while(trips, {:ok, []}, fn trip, {:ok, active} ->
      case active_on?(calendars, trip.service_id, date) do
        {:ok, true} -> {:cont, {:ok, [trip | active]}}
        {:ok, false} -> {:cont, {:ok, active}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, active} -> Enum.reverse(active)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unreadable_record(route, date, {:unreadable_calendar, service_id}) do
    %{
      route_id: route.route_id,
      date: date,
      recorded_service?: nil,
      listed_trip_templates: 0,
      frequency_templates: 0,
      missing_time_templates: 0,
      service_ids: [],
      alternate_service_ids: [],
      route_state: route_state(route),
      absence_reason: :unreadable_calendar,
      unreadable_service_ids: [service_id]
    }
  end

  defp service_record(%{route: route} = input, date, selection, active_trips) do
    trip_ids = Enum.map(active_trips, & &1.trip_id)
    service_ids = active_trips |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort()
    frequency_ids = trip_ids |> Enum.filter(&MapSet.member?(input.frequency_trip_ids, &1))
    listed_ids = trip_ids -- frequency_ids
    missing_ids = Enum.filter(listed_ids, &missing_time?(input, &1))

    %{
      route_id: route.route_id,
      date: date,
      recorded_service?: service_ids != [],
      listed_trip_templates: length(listed_ids),
      frequency_templates: length(frequency_ids),
      missing_time_templates: length(missing_ids),
      service_ids: service_ids,
      alternate_service_ids: alternate_service_ids(service_ids, selection.service_id),
      route_state: route_state(route),
      absence_reason: absence_reason(route, trips_count(input), service_ids),
      unreadable_service_ids: []
    }
  end

  defp trips_count(%{trips: trips}), do: length(trips)

  defp route_state(%Route{active: active}), do: if(active, do: :active, else: :inactive)

  defp absence_reason(%Route{active: false}, _recorded, _service_ids), do: :inactive_route
  defp absence_reason(_route, 0, _service_ids), do: :no_recorded_trips
  defp absence_reason(_route, _recorded, []), do: :no_active_trip
  defp absence_reason(_route, _recorded, _service_ids), do: nil

  # The named calendar under review is one service; the rest are the alternates
  # that keep a route running. Without a named calendar every service is listed,
  # so a caller cannot lose the alternative by omitting the argument.
  defp alternate_service_ids(service_ids, nil), do: service_ids
  defp alternate_service_ids(service_ids, service_id), do: service_ids -- [service_id]

  # A trip whose recorded stop times carry no usable clock value is still service
  # on that date; the count is disclosed, the route/date answer is unchanged.
  defp missing_time?(%{stop_times: stop_times}, trip_id) do
    case Map.get(stop_times, trip_id, []) do
      [] ->
        true

      rows ->
        Enum.all?(rows, fn row -> is_nil(row_seconds(row)) end)
    end
  end

  defp disclosure(reason, detail), do: %{reason: reason, detail: detail}

  defp comparisons(records, route_ids) do
    route_ids
    |> Enum.map(fn route_id ->
      route_comparison(Enum.filter(records, &(&1.route_id == route_id)))
    end)
  end

  defp route_comparison([]), do: nil

  defp route_comparison(records) do
    with_service = Enum.filter(records, &(&1.recorded_service? == true)) |> Enum.map(& &1.date)
    without = Enum.filter(records, &(&1.recorded_service? == false)) |> Enum.map(& &1.date)
    undetermined = Enum.filter(records, &(&1.recorded_service? == nil)) |> Enum.map(& &1.date)

    %{
      route_id: hd(records).route_id,
      dates_with_service: with_service,
      dates_without_service: without,
      undetermined_dates: undetermined,
      first_service_date: List.first(with_service),
      last_service_date: List.last(with_service),
      service_ids: records |> Enum.flat_map(& &1.service_ids) |> Enum.uniq() |> Enum.sort()
    }
  end

  # -- digest ----------------------------------------------------------------

  # The digest identifies the content this answer was computed from, not a
  # chronological revision. It covers the normalized rows the snapshot returned,
  # the server-owned scope and the selection, so two reads of two different
  # states cannot produce the same digest.
  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp input_digest(%{route: route, stop_times: stop_times, frequencies: frequencies}) do
    %{
      route: route.route_id,
      trips: Enum.map(frequencies, &{&1.trip_id, &1.start_time, &1.end_time}),
      stop_times:
        Enum.map(
          stop_times,
          &{&1.trip_id, &1.stop_id, &1.stop_sequence, &1.departure_time, &1.arrival_time}
        )
    }
  end
end

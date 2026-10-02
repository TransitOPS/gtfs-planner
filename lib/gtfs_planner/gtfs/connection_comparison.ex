defmodule GtfsPlanner.Gtfs.ConnectionComparison do
  @moduledoc """
  Loads the exact native evidence an A37 connection comparison is allowed to
  claim, for one approved pair set, inside one read-only snapshot.

  `load/3` is a read. It takes the server-owned organization and version, an
  explicit civil service date and the pairs a host expressly approved, and
  returns `%{scope:, service_date:, approved_route_ids:, rows:, totals:, digest:}`.
  Every row carries the two endpoints' resolved identities, the exact occurrence
  clocks, each endpoint's own civil date, its agency zone, and the stored
  minimum that applies with its row provenance (CR-4). The numbers here are
  server-owned; nothing in this module reads model text.

  ## Contracts

    * Organization and version come from `scope` only. A route, trip or stop
      named by a pair is resolved inside them, so a foreign or other-version
      reference is `{:error, :not_found}` rather than another tenant's rows.
    * `pairs` are `%{id: String.t(), from: endpoint, to: endpoint, minimum: ...}`
      where an `endpoint` is
      `%{route_id: uuid, trip_id: uuid, stop_id: String.t(), stop_sequence:
      non_neg_integer, service_date_offset: non_neg_integer}`. The ids are this
      application's route and trip rows; the stop is the natural GTFS stop id.
      An occurrence is the exact `(stop, stop_sequence)` pair inside the named
      trip, so a loop's second visit is a different occurrence and is never
      substituted for the requested one.
    * The refusal set is `:invalid_input` (a value that is not the documented
      shape, a duplicate pair id, a negative offset), `:not_found` (a reference
      outside the scope, or a trip that is not on its named route), `:too_many`
      (more than #{500} pairs, more than two approved endpoint routes, or more
      examined stop-time occurrences than
      `ServiceQueries.examined_occurrence_limit/0`) and `:unavailable` (the
      read itself could not be completed). Every refusal happens before a
      complete answer is returned, and none of them writes a row.
    * Only the routes the pairs themselves name are read, and a request naming
      more than two of them is refused. A route added to the request is not an
      approved comparison: the endpoint route set is the approved set.
    * Service is evaluated per endpoint with `Calendars.ServiceDates` over the
      scoped weekly row and exceptions, against that endpoint's own civil date
      (`service_date` + its own `service_date_offset`). An unreadable calendar
      is reported as `:unreadable_calendar` beside the row, never as absent
      service, and each endpoint keeps its offset so a later comparison can
      refuse to subtract two different date bases.
    * The agency zone comes from the native rule `ServiceQueries` uses: the
      route's own agency when it names one, otherwise the sole scoped agency. An
      ambiguous, invalid or missing zone is reported as
      `:timezone_unavailable` beside the row rather than falling back to UTC.
    * The minimum is the stored general (types 0-3) rule with the best
      `Transfers.Overlaps` rank whose coverage contains each endpoint stop and
      whose route/trip selectors match that endpoint. Coverage is the native R2
      expansion: a station covers itself and its direct children with a location
      type of nil or 0. A best-ranked type 3 prohibits, equal-best rules with
      differing effects are reported as `:conflicting`, and a best-ranked type 2
      supplies `min_transfer_time` with its row id, rank and revision. Type 0/1
      leaves the minimum absent unless the pair carried an explicit supplied
      minimum. A supplied minimum is used only when the stored policy leaves it
      undetermined, and it never erases a prohibition or a conflict.

  Every source read of one answer happens in the configured
  `ServiceQueries.Snapshot` transaction (`ServiceQueries.Snapshot.Repo` in
  production), so a controlled writer that commits between two of these reads
  cannot make the rows, the minimum and the digest describe different database
  states. The transaction closes before the snapshot is returned, so a caller
  that then waits on a provider holds no lock.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.ServiceQueries
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers.Overlaps
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # Engineering ceilings, not measured workloads: the number of approved pairs
  # one request may carry, the number of endpoint routes it may name, and the
  # shared occurrence cap.
  @max_pairs 500
  @max_approved_routes 2
  @general_types 0..3

  @pair_keys [:from, :id, :minimum, :to]
  @endpoint_keys [:route_id, :service_date_offset, :stop_id, :stop_sequence, :trip_id]
  @stored_minimum_keys [:origin]
  @supplied_minimum_keys [:approval, :origin, :seconds]

  @typedoc "Server-owned organization and version, plus the route bound to the conversation."
  @type scope :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          optional(:route_id) => Ecto.UUID.t() | nil
        }

  @typedoc "One approved endpoint: this application's route/trip rows and a natural GTFS stop."
  @type endpoint :: %{
          route_id: Ecto.UUID.t(),
          trip_id: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_sequence: non_neg_integer(),
          service_date_offset: non_neg_integer()
        }

  @typedoc "The minimum the caller asked about, either the stored one or an explicit supplied value."
  @type requested_minimum ::
          %{origin: :stored}
          | %{origin: :supplied, seconds: non_neg_integer(), approval: String.t()}

  @typedoc "One approved pair of endpoints and the minimum that applies to it."
  @type pair :: %{
          id: String.t(),
          from: endpoint(),
          to: endpoint(),
          minimum: requested_minimum()
        }

  @typedoc "Why one requested pair could not be resolved; `nil` when every part resolved."
  @type row_reason ::
          nil
          | :inactive_route
          | :occurrence_not_found
          | :no_recorded_service
          | :unreadable_calendar
          | :unknown_arrival_time
          | :unknown_departure_time
          | :timezone_unavailable

  @typedoc "The loaded evidence of one approved pair."
  @type row :: %{id: String.t(), from: map(), to: map(), minimum: map(), reason: row_reason()}

  @typedoc "The evidence one comparison is computed from."
  @type snapshot :: %{
          scope: map(),
          service_date: Date.t(),
          approved_route_ids: [String.t()],
          rows: [row()],
          totals: map(),
          digest: String.t()
        }

  @typedoc "Why a read could not produce an answer."
  @type error :: :invalid_input | :not_found | :too_many | :unavailable

  @doc """
  Returns the bound this module refuses to exceed: the most approved pairs one
  load may carry. It is public so the ceiling a caller is told about and the one
  this function enforces cannot drift apart.
  """
  @spec pair_limit() :: pos_integer()
  def pair_limit, do: @max_pairs

  @doc """
  Loads the exact endpoint occurrences and the native service/minimum evidence
  for `pairs` on `service_date`, in one read-only snapshot.

  The refusals are `:invalid_input` for a value that is not the documented
  shape, a duplicate pair id, a malformed clock-independent value or a negative
  offset; `:not_found` for a route, trip or trip/route pairing outside the
  scope; `:too_many` for more than #{@max_pairs} pairs, more than
  #{@max_approved_routes} approved endpoint routes, or more examined occurrences
  than `ServiceQueries.examined_occurrence_limit/0`; and `:unavailable` when the
  read itself could not be completed. They are all decided before any query
  except the ones that must resolve the request against the scoped rows.

  An accepted pair is never dropped: each requested id produces one row, with
  `reason` naming the part that could not be read, and with the minimum that
  applies to it even when the occurrences did not resolve.
  """
  @spec load(scope(), [pair()], Date.t()) :: {:ok, snapshot()} | {:error, error()}
  def load(scope, pairs, service_date) do
    with {:ok, request} <- request(scope, pairs, service_date) do
      read(request)
    end
  end

  # -- request validation ----------------------------------------------------

  # Everything that can be refused without reading is refused here, so an
  # over-limit or malformed request never reaches the database.
  defp request(scope, pairs, service_date) do
    cond do
      not is_list(pairs) -> {:error, :invalid_input}
      length(pairs) > @max_pairs -> {:error, :too_many}
      true -> validated_request(scope, pairs, service_date)
    end
  end

  defp validated_request(scope, pairs, service_date) do
    with {:ok, organization_id, gtfs_version_id} <- scoped_ids(scope),
         true <- match?(%Date{}, service_date) do
      approved_request(organization_id, gtfs_version_id, service_date, pairs)
    else
      false -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
    end
  end

  # The pair ceiling is a narrowing path of its own, so an over-limit request is
  # refused before a single pair of it is read.
  defp approved_request(organization_id, gtfs_version_id, service_date, pairs) do
    with {:ok, validated} <- validate_pairs(pairs) do
      route_uuids =
        validated
        |> Enum.flat_map(&[&1.from.route_id, &1.to.route_id])
        |> Enum.uniq()

      if length(route_uuids) <= @max_approved_routes do
        {:ok,
         %{
           organization_id: organization_id,
           gtfs_version_id: gtfs_version_id,
           service_date: service_date,
           pairs: validated,
           route_uuids: route_uuids
         }}
      else
        {:error, :too_many}
      end
    end
  end

  defp scoped_ids(scope) do
    with {:ok, organization_id} <- cast_uuid(Map.get(scope, :organization_id)),
         {:ok, gtfs_version_id} <- cast_uuid(Map.get(scope, :gtfs_version_id)) do
      {:ok, organization_id, gtfs_version_id}
    end
  end

  defp validate_pairs(pairs) do
    ids = Enum.map(pairs, &pair_id/1)

    if Enum.all?(ids, &label?/1) and length(Enum.uniq(ids)) == length(ids) do
      reduce_valid_pairs(pairs)
    else
      {:error, :invalid_input}
    end
  end

  defp reduce_valid_pairs(pairs) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn pair, {:ok, acc} ->
      case validate_pair(pair) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pair_id(pair) when is_map(pair), do: Map.get(pair, :id)
  defp pair_id(_pair), do: nil

  defp validate_pair(pair) do
    with true <- exact_keys?(pair, @pair_keys),
         {:ok, id} <- label(Map.get(pair, :id)),
         {:ok, from} <- validate_endpoint(Map.get(pair, :from)),
         {:ok, to} <- validate_endpoint(Map.get(pair, :to)),
         {:ok, minimum} <- validate_minimum(Map.get(pair, :minimum)) do
      {:ok, %{id: id, from: from, to: to, minimum: minimum}}
    else
      false -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_endpoint(endpoint) do
    with true <- exact_keys?(endpoint, @endpoint_keys),
         {:ok, route_id} <- cast_uuid(Map.get(endpoint, :route_id)),
         {:ok, trip_id} <- cast_uuid(Map.get(endpoint, :trip_id)),
         {:ok, stop_id} <- label(Map.get(endpoint, :stop_id)),
         true <- non_neg_integer?(Map.get(endpoint, :stop_sequence)),
         true <- non_neg_integer?(Map.get(endpoint, :service_date_offset)) do
      {:ok,
       %{
         route_id: route_id,
         trip_id: trip_id,
         stop_id: stop_id,
         stop_sequence: Map.fetch!(endpoint, :stop_sequence),
         service_date_offset: Map.fetch!(endpoint, :service_date_offset)
       }}
    else
      false -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_minimum(%{origin: :stored} = minimum) do
    if exact_keys?(minimum, @stored_minimum_keys) do
      {:ok, minimum}
    else
      {:error, :invalid_input}
    end
  end

  defp validate_minimum(%{origin: :supplied} = minimum) do
    with true <- exact_keys?(minimum, @supplied_minimum_keys),
         true <- label?(Map.get(minimum, :approval)),
         true <- non_neg_integer?(Map.get(minimum, :seconds)) do
      {:ok, minimum}
    else
      _other -> {:error, :invalid_input}
    end
  end

  defp validate_minimum(_minimum), do: {:error, :invalid_input}

  # -- one read-only snapshot ------------------------------------------------

  # Wraps query execution only. `DBConnection.ConnectionError` is the single
  # recoverable operational failure, as it is for the other read adapters; every
  # other exception propagates so a code defect can never be reported as
  # downtime.
  defp read(request) do
    Snapshot.read_snapshot(fn -> load_snapshot(request) end)
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp load_snapshot(request) do
    with {:ok, routes} <- scoped_routes(request),
         {:ok, trips} <- scoped_trips(request),
         :ok <- trips_run_on_their_routes(request, routes, trips),
         {:ok, occurrences} <- scoped_occurrences(request, trips),
         {:ok, policy} <- scoped_policy(request, pairs_stop_ids(request.pairs)) do
      data = %{
        request: request,
        routes: routes,
        trips: trips,
        occurrences: occurrences,
        policy: policy,
        calendars: scoped_calendars(request, trips),
        zones: scoped_zones(request, routes)
      }

      rows = Enum.map(request.pairs, &row(&1, data))

      {:ok, snapshot(request, data, rows)}
    end
  end

  defp snapshot(request, data, rows) do
    value = %{
      scope: %{
        organization_id: request.organization_id,
        gtfs_version_id: request.gtfs_version_id
      },
      service_date: request.service_date,
      approved_route_ids: approved_route_ids(data),
      rows: rows
    }

    Map.put(value, :totals, totals(rows)) |> Map.put(:digest, digest(value))
  end

  # -- scoped reads ----------------------------------------------------------

  defp scoped_routes(request) do
    loaded =
      from(r in Route,
        where:
          r.organization_id == ^request.organization_id and
            r.gtfs_version_id == ^request.gtfs_version_id and r.id in ^request.route_uuids,
        order_by: [asc: r.id]
      )
      |> Repo.all()

    if length(loaded) == length(request.route_uuids) do
      {:ok, Map.new(loaded, &{&1.id, &1})}
    else
      {:error, :not_found}
    end
  end

  defp scoped_trips(request) do
    trip_uuids =
      request.pairs
      |> Enum.flat_map(&[&1.from.trip_id, &1.to.trip_id])
      |> Enum.uniq()

    loaded =
      from(t in Trip,
        where:
          t.organization_id == ^request.organization_id and
            t.gtfs_version_id == ^request.gtfs_version_id and t.id in ^trip_uuids,
        order_by: [asc: t.id]
      )
      |> Repo.all()

    if length(loaded) == length(trip_uuids) do
      {:ok, Map.new(loaded, &{&1.id, &1})}
    else
      {:error, :not_found}
    end
  end

  # A trip that exists in the scope but does not run on the route its own
  # endpoint names is a reference this request may not make: it is refused with
  # the same `:not_found` as a reference from outside the scope, rather than
  # becoming a row whose occurrence merely failed to resolve.
  defp trips_run_on_their_routes(request, routes, trips) do
    endpoints = Enum.flat_map(request.pairs, &[&1.from, &1.to])

    mismatch? =
      Enum.any?(endpoints, fn endpoint ->
        trip = Map.fetch!(trips, endpoint.trip_id)
        route = Map.fetch!(routes, endpoint.route_id)

        trip.route_id != route.route_id
      end)

    if mismatch?, do: {:error, :not_found}, else: :ok
  end

  # The requested occurrence is the exact `(stop, stop_sequence)` pair inside the
  # named trip, so a loop's second visit can never be substituted for it. The
  # query's own limit is the shared occurrence cap, so an over-cap request is
  # refused instead of materializing an unbounded row set.
  defp scoped_occurrences(request, trips) do
    occurrences =
      request.pairs
      |> Enum.flat_map(&[&1.from, &1.to])
      |> Enum.uniq_by(&{&1.trip_id, &1.stop_id, &1.stop_sequence})
      |> Enum.map(&occurrence_key(&1, trips))
      |> Enum.reject(&is_nil/1)

    trip_ids = Enum.map(occurrences, &elem(&1, 0))
    stop_ids = occurrences |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    limit = ServiceQueries.examined_occurrence_limit()

    rows =
      if trip_ids == [] do
        []
      else
        from(s in StopTime,
          where:
            s.organization_id == ^request.organization_id and
              s.gtfs_version_id == ^request.gtfs_version_id and s.trip_id in ^trip_ids and
              s.stop_id in ^stop_ids,
          order_by: [asc: s.trip_id, asc: s.stop_id, asc: s.stop_sequence, asc: s.id],
          limit: ^limit + 1
        )
        |> Repo.all()
      end

    if length(rows) > limit do
      {:error, :too_many}
    else
      # `put_new` keeps the first row of an occurrence, which is the lowest
      # `id` of the ordered query.
      {:ok,
       Enum.reduce(rows, %{}, fn row, index ->
         Map.put_new(index, {row.trip_id, row.stop_id, row.stop_sequence}, row)
       end)}
    end
  end

  defp occurrence_key(endpoint, trips) do
    case Map.fetch(trips, endpoint.trip_id) do
      {:ok, trip} -> {trip.trip_id, endpoint.stop_id, endpoint.stop_sequence}
      :error -> nil
    end
  end

  # The stored general policy this version holds, with the stop index the R2
  # coverage expansion needs: every endpoint stop a rule names plus its direct
  # children.
  defp scoped_policy(request, extra_stop_ids) do
    transfers =
      from(t in Transfer,
        where:
          t.organization_id == ^request.organization_id and
            t.gtfs_version_id == ^request.gtfs_version_id and
            t.transfer_type in ^Enum.to_list(@general_types),
        order_by: [asc: t.id]
      )
      |> Repo.all()

    stop_ids = Enum.uniq(transfer_stop_ids(transfers) ++ extra_stop_ids)

    stops =
      if stop_ids == [] do
        %{}
      else
        from(s in Stop,
          where:
            s.organization_id == ^request.organization_id and
              s.gtfs_version_id == ^request.gtfs_version_id and
              (s.stop_id in ^stop_ids or s.parent_station in ^stop_ids)
        )
        |> Repo.all()
        |> Map.new(&{&1.stop_id, &1})
      end

    {:ok, %{transfers: transfers, stops: stops}}
  end

  defp transfer_stop_ids(transfers) do
    transfers
    |> Enum.flat_map(&[&1.from_stop_id, &1.to_stop_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp pairs_stop_ids(pairs) do
    pairs
    |> Enum.flat_map(&[&1.from.stop_id, &1.to.stop_id])
    |> Enum.uniq()
  end

  # A service with no weekly row maps to `{nil, []}`, which `ServiceDates` reads
  # as dates-only service rather than as a second calendar rule.
  defp scoped_calendars(request, trips) do
    service_ids =
      trips
      |> Map.values()
      |> Enum.map(& &1.service_id)
      |> Enum.uniq()

    calendars =
      from(c in Calendar,
        where:
          c.organization_id == ^request.organization_id and
            c.gtfs_version_id == ^request.gtfs_version_id and c.service_id in ^service_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.service_id, &1})

    exceptions =
      from(d in CalendarDate,
        where:
          d.organization_id == ^request.organization_id and
            d.gtfs_version_id == ^request.gtfs_version_id and d.service_id in ^service_ids,
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
      ArgumentError -> {:error, :unreadable_calendar}
    end
  end

  # The native agency rule `ServiceQueries` uses: the route's own agency when it
  # names one, otherwise the sole scoped agency. A presentation fallback is
  # refused here, so a missing zone never becomes a local-clock claim.
  defp scoped_zones(request, routes) do
    Map.new(routes, fn {route_uuid, route} ->
      {route_uuid, route_zone(request, route)}
    end)
  end

  defp route_zone(request, %Route{agency_id: nil}) do
    case DisplayClock.resolve_zone(request.organization_id, request.gtfs_version_id) do
      %{fallback?: false, timezone: timezone} -> {:ok, timezone}
      %{fallback_reason: reason} -> {:error, reason}
    end
  end

  defp route_zone(request, %Route{agency_id: agency_id}) do
    query =
      from(a in Agency,
        where:
          a.organization_id == ^request.organization_id and
            a.gtfs_version_id == ^request.gtfs_version_id and a.agency_id == ^agency_id
      )

    case Repo.one(query) do
      nil -> {:error, :missing}
      %Agency{agency_timezone: timezone} -> usable_zone(timezone)
    end
  end

  defp usable_zone(timezone) do
    case timezone && String.trim(timezone) do
      "" ->
        {:error, :missing}

      trimmed ->
        if DisplayClock.valid_zone?(trimmed), do: {:ok, trimmed}, else: {:error, :invalid}
    end
  end

  # -- one row ---------------------------------------------------------------

  defp row(pair, data) do
    from = endpoint_row(pair.from, :from, data)
    to = endpoint_row(pair.to, :to, data)

    %{
      id: pair.id,
      from: from,
      to: to,
      minimum: minimum(pair, from, to, data),
      reason: row_reason(from, to)
    }
  end

  defp endpoint_row(endpoint, side, data) do
    route = Map.fetch!(data.routes, endpoint.route_id)
    trip = Map.fetch!(data.trips, endpoint.trip_id)
    civil_date = Date.add(data.request.service_date, endpoint.service_date_offset)

    occurrence =
      if trip.route_id == route.route_id do
        Map.get(data.occurrences, {trip.trip_id, endpoint.stop_id, endpoint.stop_sequence})
      end

    {service_active?, service_reason} =
      case active_on?(data.calendars, trip.service_id, civil_date) do
        {:ok, active} -> {active, nil}
        {:error, reason} -> {nil, reason}
      end

    {timezone, zone_reason} =
      case Map.fetch!(data.zones, endpoint.route_id) do
        {:ok, timezone} -> {timezone, nil}
        {:error, reason} -> {nil, reason}
      end

    %{
      side: side,
      route_id: route.id,
      route: route.route_id,
      route_active?: route.active,
      trip_id: trip.id,
      trip: trip.trip_id,
      trip_on_route?: trip.route_id == route.route_id,
      service_id: trip.service_id,
      stop_id: endpoint.stop_id,
      stop_sequence: endpoint.stop_sequence,
      service_date_offset: endpoint.service_date_offset,
      civil_date: civil_date,
      service_active?: service_active?,
      service_reason: service_reason,
      occurrence_found?: occurrence != nil,
      arrival_secs: arrival_secs(occurrence),
      arrival_time: arrival_time(occurrence),
      departure_secs: departure_secs(occurrence),
      departure_time: departure_time(occurrence),
      timezone: if(zone_reason, do: nil, else: timezone),
      zone_reason: zone_reason
    }
  end

  # The first blocker either endpoint names, from the `from` side first, so the
  # same incomplete pair always reports the same reason.
  defp row_reason(from, to) do
    case {endpoint_blocker(from), endpoint_blocker(to)} do
      {nil, nil} -> nil
      {nil, reason} -> reason
      {reason, _other} -> reason
    end
  end

  defp endpoint_blocker(endpoint) do
    case source_blocker(endpoint) do
      nil -> clock_blocker(endpoint)
      reason -> reason
    end
  end

  defp source_blocker(endpoint) do
    cond do
      not endpoint.trip_on_route? -> :occurrence_not_found
      endpoint.route_active? == false -> :inactive_route
      not endpoint.occurrence_found? -> :occurrence_not_found
      endpoint.service_reason == :unreadable_calendar -> :unreadable_calendar
      endpoint.service_active? == false -> :no_recorded_service
      endpoint.zone_reason != nil -> :timezone_unavailable
      true -> nil
    end
  end

  defp clock_blocker(%{side: :from} = endpoint) do
    if is_nil(endpoint.arrival_secs), do: :unknown_arrival_time
  end

  defp clock_blocker(%{side: :to} = endpoint) do
    if is_nil(endpoint.departure_secs), do: :unknown_departure_time
  end

  # A `departure_time` is the boarding time and a trip that records only an
  # `arrival_time` still boards then, which is the rule `ServiceQueries` reads.
  # An absent or unparsable clock is `nil`, never zero, and neither side is read
  # through the other.
  defp arrival_secs(nil), do: nil
  defp arrival_secs(%StopTime{} = row), do: clock_secs(row.arrival_time)

  defp departure_secs(nil), do: nil
  defp departure_secs(%StopTime{} = row), do: clock_secs(row.departure_time)

  defp arrival_time(nil), do: nil
  defp arrival_time(%StopTime{arrival_time: time}), do: time

  defp departure_time(nil), do: nil
  defp departure_time(%StopTime{departure_time: time}), do: time

  defp clock_secs(nil), do: nil

  defp clock_secs(value) do
    case GtfsTime.parse(value || "") do
      {:ok, secs} -> secs
      {:error, :invalid_time} -> nil
    end
  end

  # -- the stored minimum ----------------------------------------------------

  defp minimum(pair, from, to, data) do
    applicable =
      data.policy.transfers
      |> Enum.filter(&applies?(&1, from, to, data.policy.stops))
      |> Enum.map(&rule(&1, data.policy.stops))

    applicable
    |> best_rules()
    |> decided(pair.minimum.origin, supplied_minimum(pair.minimum))
  end

  # A rule applies to one endpoint when its coverage contains that endpoint's
  # stop and its selectors match that endpoint's trip and route. This is the
  # selector half of the R6 rule `Transfers.Overlaps` ranks.
  defp applies?(transfer, from, to, stops) do
    covers?(coverage(transfer.from_stop_id, stops), from) and
      covers?(coverage(transfer.to_stop_id, stops), to) and
      selects?(transfer.from_trip_id, transfer.from_route_id, from) and
      selects?(transfer.to_trip_id, transfer.to_route_id, to)
  end

  defp covers?(leaves, endpoint), do: endpoint.stop_id in leaves

  defp selects?(trip_selector, route_selector, endpoint) do
    (is_nil(trip_selector) or trip_selector == endpoint.trip) and
      (is_nil(route_selector) or route_selector == endpoint.route)
  end

  # A general rule for the R6 ranker, carrying the R2 coverage of its endpoints
  # and the revision a stored minimum's provenance names.
  defp rule(transfer, stops) do
    %{
      id: transfer.id,
      from_coverage: coverage(transfer.from_stop_id, stops),
      to_coverage: coverage(transfer.to_stop_id, stops),
      from_route_id: transfer.from_route_id,
      to_route_id: transfer.to_route_id,
      from_trip_id: transfer.from_trip_id,
      to_trip_id: transfer.to_trip_id,
      transfer_type: transfer.transfer_type,
      min_transfer_time: transfer.min_transfer_time,
      revision: transfer.updated_at
    }
  end

  # R2: only a station expands to its direct children, and only the children
  # that are stops or platforms. A stop that is not in the version covers
  # nothing, so a rule naming it cannot apply.
  defp coverage(nil, _stops), do: []

  defp coverage(stop_id, stops) do
    case Map.get(stops, stop_id) do
      nil ->
        []

      %Stop{location_type: 1} = station ->
        [station.stop_id | child_stop_ids(station, stops)]

      %Stop{} = stop ->
        [stop.stop_id]
    end
  end

  defp child_stop_ids(station, stops) do
    stops
    |> Map.values()
    |> Enum.filter(&(&1.parent_station == station.stop_id and &1.location_type in [nil, 0]))
    |> Enum.map(& &1.stop_id)
    |> Enum.sort()
  end

  # The best-ranked applicable rule decides. Type 3 prohibits, equal-best rules
  # with differing effects stay unresolved instead of picking one, a best-ranked
  # type 2 states the minimum, and type 0/1 leaves it undetermined unless the
  # pair carried an explicit supplied minimum.
  defp best_rules([]), do: {:none, []}

  defp best_rules(rules) do
    rank = rules |> Enum.map(&Overlaps.rank/1) |> Enum.min()
    {rank, Enum.filter(rules, &(Overlaps.rank(&1) == rank))}
  end

  defp decided({:none, _rules}, origin, supplied),
    do: undetermined(origin, supplied, :no_applicable_rule, nil, [])

  defp decided({rank, rules}, origin, supplied) do
    cond do
      Enum.any?(rules, &(&1.transfer_type == 3)) ->
        unresolved(
          origin,
          supplied,
          :prohibited,
          :prohibited_by_best_rule,
          %{kind: :stored_best, rank: rank, transfer_type: 3, rule_ids: rule_ids(rules)}
        )

      length(Enum.uniq(Enum.map(rules, &effect/1))) > 1 ->
        unresolved(
          origin,
          supplied,
          :conflicting,
          :conflicting_best_rules,
          %{
            kind: :stored_best,
            rank: rank,
            rule_ids: rule_ids(rules),
            effects: Enum.map(rules, &effect_entry(&1))
          }
        )

      true ->
        stated_minimum(rules, rank, origin, supplied)
    end
  end

  # Equal-best rules that agree are one effect, so the first of them names the
  # stored row its provenance carries.
  defp stated_minimum([%{transfer_type: 2} = best | _rules], rank, origin, supplied) do
    if is_integer(best.min_transfer_time) do
      %{
        origin: :stored,
        seconds: best.min_transfer_time,
        status: :resolved,
        provenance: %{
          kind: :stored_best,
          rank: rank,
          transfer_id: best.id,
          transfer_type: best.transfer_type,
          min_transfer_time: best.min_transfer_time,
          revision: best.revision,
          rule_ids: [best.id]
        },
        supplied: supplied_entry(supplied)
      }
    else
      undetermined(origin, supplied, :stored_best_without_minimum, rank, [best.id])
    end
  end

  defp stated_minimum(rules, rank, origin, supplied) do
    undetermined(origin, supplied, :stored_best_without_minimum, rank, rule_ids(rules))
  end

  # Type 0/1, and a type 2 whose retained minimum is unreadable, leave the
  # minimum undetermined. An explicit supplied minimum answers it with its own
  # provenance, and a type 2 that states one keeps its stored value: a supplied
  # number never replaces the stored policy's own.
  defp undetermined(origin, nil, kind, rank, ids) do
    %{
      origin: origin,
      seconds: nil,
      status: :absent,
      provenance: provenance(kind, rank, ids),
      supplied: nil
    }
  end

  defp undetermined(_origin, supplied, kind, rank, ids) do
    %{
      origin: :supplied,
      seconds: supplied.seconds,
      status: :resolved,
      provenance: provenance(kind, rank, ids),
      supplied: supplied_entry(supplied)
    }
  end

  defp unresolved(origin, supplied, status, reason, provenance) do
    %{
      origin: origin,
      seconds: nil,
      status: status,
      provenance: Map.put(provenance, :reason, reason),
      supplied: supplied_entry(supplied)
    }
  end

  defp provenance(kind, rank, ids) do
    %{kind: kind, rank: rank, rule_ids: ids}
  end

  defp rule_ids(rules), do: Enum.map(rules, & &1.id)

  defp supplied_entry(nil), do: nil
  defp supplied_entry(supplied), do: %{seconds: supplied.seconds, approval: supplied.approval}

  defp supplied_minimum(%{origin: :supplied} = minimum), do: minimum
  defp supplied_minimum(%{origin: :stored}), do: nil

  defp effect(%{transfer_type: 2} = rule), do: {2, Map.get(rule, :min_transfer_time)}
  defp effect(rule), do: {Map.get(rule, :transfer_type), nil}

  defp effect_entry(rule) do
    %{
      id: rule.id,
      transfer_type: rule.transfer_type,
      min_transfer_time: Map.get(rule, :min_transfer_time)
    }
  end

  # -- totals and digest -----------------------------------------------------

  defp totals(rows) do
    minimums = Enum.map(rows, & &1.minimum.status)

    %{
      requested: length(rows),
      endpoints: length(rows) * 2,
      resolved_rows: Enum.count(rows, &is_nil(&1.reason)),
      unresolved_rows: Enum.count(rows, &(not is_nil(&1.reason))),
      resolved_minimum: Enum.count(minimums, &(&1 == :resolved)),
      prohibited_minimum: Enum.count(minimums, &(&1 == :prohibited)),
      conflicting_minimum: Enum.count(minimums, &(&1 == :conflicting)),
      absent_minimum: Enum.count(minimums, &(&1 == :absent))
    }
  end

  # The digest identifies the content this snapshot was read from, not a
  # chronological revision, so a comparison can bind its approval to exactly
  # these rows and this stored policy.
  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp approved_route_ids(data) do
    data.routes
    |> Map.values()
    |> Enum.map(& &1.route_id)
    |> Enum.sort()
  end

  # -- guards ----------------------------------------------------------------

  defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == keys

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_input}
    end
  end

  defp label(value) when is_binary(value) and value != "", do: {:ok, value}
  defp label(_value), do: {:error, :invalid_input}

  defp label?(value), do: is_binary(value) and value != ""

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0
end

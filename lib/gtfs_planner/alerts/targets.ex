defmodule GtfsPlanner.Alerts.Targets do
  @moduledoc """
  The target lookups the alert editor and the alerts pack read, all scoped to one
  version (AC-10, R1).

  Every query here is constrained by the context's `organization_id` *and*
  `gtfs_version_id`, and every id that arrives from stored answers or from a
  caller is a row UUID of that version. A stop, route or trip of a sibling
  version that happens to carry the same GTFS identifier is therefore a
  different row and cannot satisfy a lookup: an alert is about the schedule in
  the version it was written against, never about the version the editor happens
  to be looking at now.

  Options carry a row `id` and a rider-facing `label`; the LiveView builds the
  `%{label:, value:}` pair LiveSelect needs. Searches match a case-insensitive
  substring of the operator's text and return at most 25 options: a transit
  agency has far more rows than one pick list can show, and narrowing the query
  beats paging, so the caller says that the list is the first 25 matches.

  `capture_reference/2` builds the trusted wire IDs, labels and zone an alert
  keeps when its source version disappears, from the same scoped reads the
  editor's options come from (CR-5).

  `departures_on/4` decides whether a trip runs on the date with
  `Gtfs.Calendars.ServiceDates.active_dates_between/4`, which is the same
  evaluation the Calendar helper shows, so a cancelled departure is never
  offered for a day the trip does not run. A GTFS clock value may continue past
  midnight, so the label of a time beyond 24:00 says which day it belongs to
  rather than silently reading as an earlier one.

  All times here are the schedule's own civil clock. Nothing converts between
  zones (CR-7).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @search_limit 25
  # The scope answer allows at most this many route or stop ids, so a larger
  # list from a caller names nothing the editor could have stored.
  @max_ids 200
  @day_seconds 86_400
  @label_origin ~D[2000-01-01]
  @midnight ~T[00:00:00]

  @typedoc "A selectable stop, shaped for a pick list."
  @type stop_option :: %{
          id: Ecto.UUID.t(),
          label: String.t(),
          stop_id: String.t(),
          stop_name: String.t() | nil,
          platform_code: String.t() | nil
        }

  @typedoc "A selectable route, shaped for a pick list."
  @type route_option :: %{
          id: Ecto.UUID.t(),
          label: String.t(),
          route_id: String.t(),
          short_name: String.t() | nil,
          long_name: String.t() | nil,
          route_type: integer() | nil
        }

  @typedoc "A dated departure the operator may cancel."
  @type departure :: %{
          trip_id: Ecto.UUID.t(),
          label: String.t(),
          first_departure_seconds: non_neg_integer()
        }

  @doc """
  Matches one version's routes on short name, long name or `route_id`.

  A blank query matches nothing rather than everything, so an editor's first
  keystroke is the only thing that opens the list.
  """
  @spec search_routes(AuditContext.t(), term()) :: [route_option()]
  def search_routes(%AuditContext{organization_id: o, gtfs_version_id: v}, query) do
    case search_pattern(query) do
      nil ->
        []

      pattern ->
        from(r in Route,
          where: r.organization_id == ^o and r.gtfs_version_id == ^v,
          where:
            ilike(r.route_short_name, ^pattern) or ilike(r.route_long_name, ^pattern) or
              ilike(r.route_id, ^pattern),
          order_by: [asc: r.route_short_name, asc: r.route_id],
          limit: @search_limit
        )
        |> Repo.all()
        |> Enum.map(&route_option/1)
    end
  end

  @doc """
  Matches one version's selectable stops on name, `stop_id` or platform code.

  The matching rules are `Gtfs.Transfers.search_stops/3`'s, so the alerts
  editor offers the same stops the transfer editor does: a case-insensitive
  substring, `%`, `_` and `\\` treated literally, and only `location_type` nil, 0
  or 1, so a station is a choice and an entrance is not.

  `:prefer_route_ids` lists the stops serving those routes first, which is what
  makes "which stops does Route 12 serve" read top down. `:exclude_stop_ids`
  drops the stops the alert is already about, so the affected stop does not stay
  offered to itself.
  """
  @spec search_stops(AuditContext.t(), term(), keyword()) :: [stop_option()]
  def search_stops(%AuditContext{} = audit_context, query, opts \\ []) do
    case search_pattern(query) do
      nil ->
        []

      pattern ->
        excluded = opts |> Keyword.get(:exclude_stop_ids, []) |> uuids() |> Enum.take(@max_ids)
        prefer = opts |> Keyword.get(:prefer_route_ids, []) |> uuids() |> Enum.take(@max_ids)
        preferred = preferred_stop_ids(audit_context, prefer)

        # The preference is part of the ordering rather than a re-sort of the
        # first matches, so a broad query still lists the preferred routes' stops
        # ahead of every other match.
        from(s in Stop,
          where: s.organization_id == ^audit_context.organization_id,
          where: s.gtfs_version_id == ^audit_context.gtfs_version_id,
          where: is_nil(s.location_type) or s.location_type in [0, 1],
          where: s.id not in ^excluded,
          where:
            ilike(s.stop_name, ^pattern) or ilike(s.stop_id, ^pattern) or
              ilike(s.platform_code, ^pattern),
          order_by: [desc: s.stop_id in ^preferred, asc: s.stop_name, asc: s.stop_id],
          limit: @search_limit
        )
        |> Repo.all()
        |> Enum.map(&stop_option/1)
    end
  end

  @doc """
  Lists the stops one version's route serves, in the order its trips serve them.

  The order is one trip's own `stop_sequence`, the order riders meet the stops
  in: a `stop_sequence` is a position within its trip, so positions from trips of
  both directions are never merged. The stops the other trips add follow the
  one trip's, each at the earliest position any trip gives it.
  """
  @spec route_stops(AuditContext.t(), term()) :: [stop_option()]
  def route_stops(%AuditContext{} = audit_context, route_id) do
    case scoped_route(audit_context, route_id) do
      nil ->
        []

      route ->
        stop_ids = served_stop_ids(audit_context, route.route_id)

        stops =
          from(s in Stop,
            where: s.organization_id == ^audit_context.organization_id,
            where: s.gtfs_version_id == ^audit_context.gtfs_version_id,
            where: is_nil(s.location_type) or s.location_type in [0, 1],
            where: s.stop_id in ^stop_ids
          )
          |> Repo.all()
          |> Map.new(&{&1.stop_id, &1})

        stop_ids
        |> Enum.map(&Map.get(stops, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&stop_option/1)
    end
  end

  @doc """
  Lists the version's routes that serve any of the given stops.

  This is the shared-stop question: a stop on two routes is the point at which
  the editor asks whether both are affected. Stops of another version cannot
  appear, and a stop no trip of the version serves yields no routes.
  """
  @spec routes_at_stops(AuditContext.t(), [term()]) :: [route_option()]
  def routes_at_stops(%AuditContext{} = audit_context, stop_ids) when is_list(stop_ids) do
    gtfs_stop_ids =
      from(s in Stop,
        where: s.organization_id == ^audit_context.organization_id,
        where: s.gtfs_version_id == ^audit_context.gtfs_version_id,
        where: s.id in ^uuids(stop_ids),
        select: s.stop_id
      )
      |> Repo.all()

    route_ids =
      from(st in StopTime,
        join: t in Trip,
        on: t.trip_id == st.trip_id,
        where: st.organization_id == ^audit_context.organization_id,
        where: st.gtfs_version_id == ^audit_context.gtfs_version_id,
        where: t.organization_id == ^audit_context.organization_id,
        where: t.gtfs_version_id == ^audit_context.gtfs_version_id,
        where: st.stop_id in ^gtfs_stop_ids,
        select: t.route_id,
        distinct: true
      )
      |> Repo.all()

    from(r in Route,
      where: r.organization_id == ^audit_context.organization_id,
      where: r.gtfs_version_id == ^audit_context.gtfs_version_id,
      where: r.route_id in ^route_ids,
      order_by: [asc: r.route_short_name, asc: r.route_id]
    )
    |> Repo.all()
    |> Enum.map(&route_option/1)
  end

  @doc """
  Lists the version's route's departures on one date, earliest first.

  A trip is offered only when its service is active on `date`: the trip's
  calendar supplies the weekly service days and the `calendar_dates` exceptions
  for the same version add and remove them, exactly as
  `Gtfs.Calendars.ServiceDates.active_dates_between/4` evaluates them. A trip
  with no calendar row and no added date is not running and is not offered.
  `direction_id` narrows to one direction; `nil` offers both.

  The label is the trip's first departure and its headsign, the way a rider names
  a departure. A time past 24:00 belongs to the next day and says so.
  """
  @spec departures_on(AuditContext.t(), term(), 0 | 1 | nil, Date.t()) :: [departure()]
  def departures_on(
        %AuditContext{} = audit_context,
        route_id,
        direction_id,
        %Date{} = date
      ) do
    case scoped_route(audit_context, route_id) do
      nil ->
        []

      route ->
        trips = route_trips(audit_context, route.route_id, direction_id)
        services = service_exceptions(audit_context, trips)

        trips
        |> Enum.filter(&running_on?(&1, services, date))
        |> Enum.map(&departure(audit_context, &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&{&1.first_departure_seconds, &1.trip_id})
    end
  end

  @doc """
  Lists the distinct route types present in the version, ascending.

  An alert about a whole mode names a route type, so the option list is what the
  version actually contains rather than the whole GTFS table.
  """
  @spec route_types(AuditContext.t()) :: [integer()]
  def route_types(%AuditContext{organization_id: o, gtfs_version_id: v}) do
    Gtfs.list_distinct_route_types(o, v)
  end

  @doc """
  Lists the directions the given routes run, in the reader's words.

  A GTFS direction is the number `0` or `1`, which names nothing to a rider; the
  pattern headsign does ("To Lincoln City"), so that is the label when the
  version carries one and the number is the fallback when it does not. Only
  directions the version's own patterns run are offered, so the question can
  never ask for a direction nothing serves.
  """
  @type direction_option :: %{direction_id: 0 | 1, label: String.t()}

  @spec route_directions(AuditContext.t(), [term()]) :: [direction_option()]
  def route_directions(%AuditContext{} = audit_context, route_ids) when is_list(route_ids) do
    gtfs_route_ids =
      from(r in Route,
        where: r.organization_id == ^audit_context.organization_id,
        where: r.gtfs_version_id == ^audit_context.gtfs_version_id,
        where: r.id in ^uuids(route_ids),
        select: r.route_id
      )
      |> Repo.all()

    # One label per direction: the first active pattern that has a headsign, in
    # the version's own pattern order, so the card reads the same on every render.
    from(p in RoutePattern,
      where: p.organization_id == ^audit_context.organization_id,
      where: p.gtfs_version_id == ^audit_context.gtfs_version_id,
      where: p.route_id in ^gtfs_route_ids,
      where: p.direction_id in [0, 1] and p.active,
      order_by: [asc_nulls_last: p.route_pattern_sort_order, asc: p.route_pattern_id],
      select: {p.direction_id, p.headsign}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {direction_id, headsigns} ->
      label = Enum.find_value(headsigns, &present_name(List.wrap(&1)))
      %{direction_id: direction_id, label: label || "Direction #{direction_id}"}
    end)
    |> Enum.sort_by(& &1.direction_id)
  end

  @doc """
  Builds the server-owned capture of what a scope answer resolves to.

  The capture is what an alert publishes and what it keeps when its source
  version disappears: the trusted GTFS wire IDs and labels of the routes, stops,
  pairs and trips the answer names, the agency identities a system-wide alert is
  about, and the source version's own zone. Every read here is scoped to the
  context's organization *and* its version, so an identity of another tenant or
  of a sibling version is recorded as unresolved instead of being adopted
  (R1, CR-5).

  An identity that does not resolve is recorded as such and never replaced by a
  guess, and `Alerts.Listing.missing_target_ids/1` reads exactly these entries
  once the source version is gone. `scope_digest` is
  `Alerts.ScopeAnswer.digest/1` of the answer the capture was taken from, so a
  later save can tell whether the selection it carries still describes the
  answer.
  """
  @spec capture_reference(ScopeAnswer.t() | nil, AuditContext.t()) :: map()
  def capture_reference(nil, %AuditContext{} = audit_context) do
    empty_reference(audit_context)
  end

  # No source version means nothing can resolve: an organization with no usable
  # schedule still authors a private draft, so the capture names the version it
  # does not have and records no identity rather than refusing the write (AC-10).
  def capture_reference(%ScopeAnswer{} = scope, %AuditContext{gtfs_version_id: nil}) do
    empty_selectors = %{
      "shape" => shape_string(scope.shape),
      "mode_route_type" => scope.mode_route_type,
      "direction_id" => scope.direction_id,
      "routes" => [],
      "unresolved_routes" => [],
      "stops" => [],
      "unresolved_stops" => [],
      "route_stops" => [],
      "trips" => [],
      "agencies" => []
    }

    %{
      "source_gtfs_version_id" => nil,
      "scope_digest" => ScopeAnswer.digest(scope),
      "timezone" => nil,
      "selectors" => empty_selectors
    }
  end

  def capture_reference(%ScopeAnswer{} = scope, %AuditContext{} = audit_context) do
    %{
      "source_gtfs_version_id" => audit_context.gtfs_version_id,
      "scope_digest" => ScopeAnswer.digest(scope),
      "timezone" => source_timezone(audit_context),
      "selectors" => %{
        "shape" => shape_string(scope.shape),
        "mode_route_type" => scope.mode_route_type,
        "direction_id" => scope.direction_id,
        "routes" => resolved_routes(audit_context, scope.route_ids),
        "unresolved_routes" => unresolved_routes(audit_context, scope.route_ids),
        "stops" => resolved_stops(audit_context, scope.stop_ids),
        "unresolved_stops" => unresolved_stops(audit_context, scope.stop_ids),
        "route_stops" => route_stop_entries(audit_context, scope.route_stop_pairs),
        "trips" => trip_entries(audit_context, scope.trips),
        "agencies" => agency_entries(audit_context, scope)
      }
    }
  end

  defp empty_reference(audit_context) do
    capture_reference(%ScopeAnswer{}, audit_context)
  end

  defp shape_string(nil), do: nil
  defp shape_string(shape) when is_atom(shape), do: Atom.to_string(shape)

  # The source version's own zone, and only when it declared exactly one usable
  # zone. A version with no zone or conflicting zones captures none, so the alert
  # reads as needing an explicit organization zone instead of inheriting a
  # display fallback (CR-5).
  defp source_timezone(%AuditContext{
         organization_id: organization_id,
         gtfs_version_id: version_id
       })
       when not is_nil(version_id) do
    case DisplayClock.resolve_zone(organization_id, version_id) do
      %{timezone: timezone, fallback?: false} -> timezone
      _fallback -> nil
    end
  end

  defp source_timezone(%AuditContext{}), do: nil

  defp resolved_routes(_audit_context, nil), do: []

  defp resolved_routes(audit_context, ids) do
    present =
      route_rows(audit_context, ids)
      |> Map.new(&{&1.id, &1})

    ids
    |> uuids()
    |> Enum.filter(&Map.has_key?(present, &1))
    |> Enum.map(fn id ->
      route = Map.fetch!(present, id)

      %{"id" => route.id, "gtfs_id" => route.route_id, "label" => route_label(route)}
    end)
  end

  defp unresolved_routes(audit_context, ids), do: unresolved_reference(audit_context, Route, ids)

  defp resolved_stops(_audit_context, nil), do: []

  defp resolved_stops(audit_context, ids) do
    present =
      from(s in Stop,
        where: s.organization_id == ^audit_context.organization_id,
        where: s.gtfs_version_id == ^audit_context.gtfs_version_id,
        where: s.id in ^uuids(ids),
        select: s
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    ids
    |> uuids()
    |> Enum.filter(&Map.has_key?(present, &1))
    |> Enum.map(fn id ->
      stop = Map.fetch!(present, id)

      %{"id" => stop.id, "gtfs_id" => stop.stop_id, "label" => stop_label(stop)}
    end)
  end

  defp unresolved_stops(audit_context, ids), do: unresolved_reference(audit_context, Stop, ids)

  # One existence query for every identity of one table at once, so a capture
  # costs three queries rather than one per identity.
  defp unresolved_reference(_audit_context, _schema, nil), do: []

  defp unresolved_reference(audit_context, schema, ids) do
    candidates = uuids(ids)

    present =
      from(row in schema,
        where: row.organization_id == ^audit_context.organization_id,
        where: row.gtfs_version_id == ^audit_context.gtfs_version_id,
        where: row.id in ^candidates,
        select: row.id
      )
      |> Repo.all()
      |> MapSet.new()

    # The answer's own spelling is what is recorded, so a Needs attention row
    # names the identity the operator stored rather than a re-cast form of it.
    Enum.reject(ids, &(canonical_uuid(&1) in present))
  end

  defp route_rows(audit_context, ids) do
    from(r in Route,
      where: r.organization_id == ^audit_context.organization_id,
      where: r.gtfs_version_id == ^audit_context.gtfs_version_id,
      where: r.id in ^uuids(ids),
      select: r
    )
    |> Repo.all()
  end

  # A pair keeps both of its row UUIDs whatever resolved, because the alert
  # still names that pair; `resolved` says whether both ends still name rows.
  defp route_stop_entries(_audit_context, nil), do: []

  defp route_stop_entries(audit_context, pairs) do
    routes = route_rows(audit_context, Enum.map(pairs, & &1.route_id)) |> Map.new(&{&1.id, &1})
    stops = stop_rows(audit_context, Enum.map(pairs, & &1.stop_id)) |> Map.new(&{&1.id, &1})

    Enum.map(pairs, fn pair ->
      route = Map.get(routes, canonical_uuid(pair.route_id))
      stop = Map.get(stops, canonical_uuid(pair.stop_id))

      %{
        "route_id" => pair.route_id,
        "route_gtfs_id" => route && route.route_id,
        "route_label" => route && route_label(route),
        "stop_id" => pair.stop_id,
        "stop_gtfs_id" => stop && stop.stop_id,
        "stop_label" => stop && stop_label(stop),
        "resolved" => not is_nil(route) and not is_nil(stop)
      }
    end)
  end

  defp stop_rows(audit_context, ids) do
    from(s in Stop,
      where: s.organization_id == ^audit_context.organization_id,
      where: s.gtfs_version_id == ^audit_context.gtfs_version_id,
      where: s.id in ^uuids(ids),
      select: s
    )
    |> Repo.all()
  end

  # A trip entry keeps the row UUID the answer named even when the trip no longer
  # resolves, so a deleted source row stays identifiable as the thing that
  # disappeared rather than becoming an absent entry.
  defp trip_entries(_audit_context, nil), do: []

  defp trip_entries(audit_context, trips) do
    present =
      from(t in Trip,
        where: t.organization_id == ^audit_context.organization_id,
        where: t.gtfs_version_id == ^audit_context.gtfs_version_id,
        where: t.id in ^uuids(Enum.map(trips, & &1.trip_id)),
        select: t
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(trips, fn target ->
      trip = Map.get(present, canonical_uuid(target.trip_id))

      %{
        "id" => target.trip_id,
        "gtfs_id" => trip && trip.trip_id,
        "service_id" => trip && trip.service_id,
        "service_date" => target.service_date && Date.to_iso8601(target.service_date),
        "label" =>
          (trip && present_name(List.wrap(trip.trip_headsign))) || (trip && trip.trip_id),
        "resolved" => not is_nil(trip)
      }
    end)
  end

  # A system-wide alert publishes against real agency identities from its own
  # source version. Every other shape captures none: an organization alias is
  # never a GTFS `agency_id` (AC-10).
  defp agency_entries(%AuditContext{gtfs_version_id: nil}, _scope), do: []

  defp agency_entries(audit_context, %ScopeAnswer{shape: :system})
       when not is_nil(audit_context.gtfs_version_id) do
    from(a in Agency,
      where: a.organization_id == ^audit_context.organization_id,
      where: a.gtfs_version_id == ^audit_context.gtfs_version_id,
      order_by: [asc: a.agency_id],
      select: {a.id, a.agency_id, a.agency_name}
    )
    |> Repo.all()
    |> Enum.map(fn {id, agency_id, agency_name} ->
      %{
        "id" => id,
        "gtfs_id" => agency_id,
        "label" => present_name(List.wrap(agency_name)) || agency_id
      }
    end)
  end

  defp agency_entries(_audit_context, _scope), do: []

  @doc """
  Returns the rider-facing labels of the routes, stops and trips an alert names.

  The keys are the row UUIDs the alert's stored scope holds - the same
  identities `Alerts.Listing` reports as missing - so a list row and a review
  text read from one source and cannot disagree about which row an identity is.

  An identity that no longer resolves has no label, because the label is the
  row's own name and inventing one would let a message appear to name a stop
  that was deleted. `Alerts.Listing.missing_target_ids/2` reports exactly those
  identities, and the caller shows the flagged row beside them.
  """
  @spec labels_for(AuditContext.t(), Alert.t()) :: %{
          routes: %{optional(Ecto.UUID.t()) => String.t()},
          stops: %{optional(Ecto.UUID.t()) => String.t()},
          trips: %{optional(Ecto.UUID.t()) => String.t()}
        }
  def labels_for(%AuditContext{} = audit_context, %Alert{} = alert) do
    referenced = Listing.referenced_ids(alert)

    %{
      routes: route_labels(audit_context, referenced.routes),
      stops: stop_labels(audit_context, referenced.stops),
      trips: trip_labels(audit_context, referenced.trips)
    }
  end

  @doc """
  Returns the route rows the given row UUIDs name, keyed by that UUID.

  A list row shows each affected route as its own identity badge, and
  `GtfsPlannerWeb.Components.RouteIdentity.route_badge/1` reads a route's own
  short name and colors, so the list needs the rows rather than the labels
  `labels_for/2` returns. An identity that is absent from the version is absent
  from the result, which is exactly what `Alerts.Listing` flags as needing
  attention (R8).
  """
  @spec routes_by_id(AuditContext.t(), [String.t()]) :: %{optional(Ecto.UUID.t()) => Route.t()}
  def routes_by_id(%AuditContext{organization_id: o, gtfs_version_id: v}, ids) do
    case uuids(ids) do
      [] ->
        %{}

      route_uuids ->
        from(r in Route,
          where: r.organization_id == ^o and r.gtfs_version_id == ^v,
          where: r.id in ^route_uuids
        )
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  Returns the stop rows the given row UUIDs name, keyed by that UUID.

  An editor's stop pick is an identity that arrived from a combobox, so it is
  re-read here before anything is stored: a UUID of another version, another
  organization or a stop this version no longer holds is simply absent from the
  result, and the caller saves nothing for it. This is the same scoped read
  `routes_by_id/2` performs for a route, and it is why a stop the editor could
  not have chosen cannot be stored by naming its UUID (R1, CR-4).
  """
  @spec stops_by_id(AuditContext.t(), [String.t()]) :: %{optional(Ecto.UUID.t()) => stop_option()}
  def stops_by_id(%AuditContext{organization_id: o, gtfs_version_id: v}, ids) do
    case uuids(ids) do
      [] ->
        %{}

      stop_uuids ->
        from(s in Stop,
          where: s.organization_id == ^o and s.gtfs_version_id == ^v,
          where: s.id in ^stop_uuids,
          where: is_nil(s.location_type) or s.location_type in [0, 1]
        )
        |> Repo.all()
        |> Map.new(&{&1.id, stop_option(&1)})
    end
  end

  @doc """
  Returns the identities that name no row of the context's organization and
  version, per table.

  `ids` maps `:routes`, `:stops` and `:trips` to the row UUIDs a write is about
  to store. An identity that is not a UUID, or that names a row of another
  version or organization, comes back in the same table's list; an empty list
  reads nothing. This is the check `Alerts` applies before an answer is saved, so
  an identity the editor could not have chosen cannot be stored by naming it
  (R1, CR-4).
  """
  @spec unresolved_ids(AuditContext.t(), %{
          routes: [term()],
          stops: [term()],
          trips: [term()]
        }) :: %{routes: [term()], stops: [term()], trips: [term()]}
  def unresolved_ids(%AuditContext{} = audit_context, %{
        routes: routes,
        stops: stops,
        trips: trips
      }) do
    %{
      routes: unresolved(Route, audit_context, routes),
      stops: unresolved(Stop, audit_context, stops),
      trips: unresolved(Trip, audit_context, trips)
    }
  end

  defp unresolved(_schema, _audit_context, []), do: []

  defp unresolved(schema, %AuditContext{organization_id: o, gtfs_version_id: v}, ids) do
    present =
      from(row in schema,
        where: row.organization_id == ^o and row.gtfs_version_id == ^v,
        where: row.id in ^uuids(ids),
        select: row.id
      )
      |> Repo.all()
      |> MapSet.new()

    Enum.reject(ids, &(canonical_uuid(&1) in present))
  end

  # The form a row's `id` is read back in, or nil for an identity no row can have.
  defp canonical_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  # -- Options -------------------------------------------------------------

  defp route_option(route) do
    %{
      id: route.id,
      label: route_label(route),
      route_id: route.route_id,
      short_name: route.route_short_name,
      long_name: route.route_long_name,
      route_type: route.route_type
    }
  end

  defp stop_option(stop) do
    %{
      id: stop.id,
      label: stop_label(stop),
      stop_id: stop.stop_id,
      stop_name: stop.stop_name,
      platform_code: stop.platform_code
    }
  end

  # Riders name a route by its number, and a route with no number by its name.
  defp route_label(route) do
    present_name([route.route_short_name, route.route_long_name]) || route.route_id
  end

  defp stop_label(stop), do: present_name([stop.stop_name]) || stop.stop_id

  defp present_name([value | _rest]) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp present_name(_values), do: nil

  # -- Scoped reads --------------------------------------------------------

  defp scoped_route(%AuditContext{organization_id: o, gtfs_version_id: v}, route_id) do
    case Gtfs.get_route_in_version(o, v, route_id) do
      {:ok, route} -> route
      {:error, :not_found} -> nil
    end
  end

  # The stops the route serves, in the order of one representative trip. A
  # `stop_sequence` is a position within its own trip, so sequences from different
  # trips (above all the two directions) cannot be merged into one order. The
  # spine is the lowest direction's trip with the most stop times; the stops it
  # lacks follow, each at the earliest position any trip of the route gives it.
  defp served_stop_ids(%AuditContext{} = audit_context, route_id) do
    spine = spine_stop_ids(audit_context, route_id)
    extra = stops_beyond_spine(audit_context, route_id, spine)

    spine ++ extra
  end

  defp spine_stop_ids(%AuditContext{} = audit_context, route_id) do
    case spine_trip_id(audit_context, route_id) do
      nil -> []
      trip_id -> trip_stop_ids(audit_context, trip_id)
    end
  end

  defp spine_trip_id(%AuditContext{organization_id: o, gtfs_version_id: v}, route_id) do
    from(t in Trip,
      left_join: st in StopTime,
      on:
        st.trip_id == t.trip_id and st.organization_id == t.organization_id and
          st.gtfs_version_id == t.gtfs_version_id,
      where: t.organization_id == ^o and t.gtfs_version_id == ^v and t.route_id == ^route_id,
      group_by: [t.trip_id, t.direction_id],
      order_by: [asc_nulls_last: t.direction_id, desc: count(st.id), asc: t.trip_id],
      select: t.trip_id,
      limit: 1
    )
    |> Repo.one()
  end

  defp trip_stop_ids(%AuditContext{organization_id: o, gtfs_version_id: v}, trip_id) do
    from(st in StopTime,
      where: st.organization_id == ^o and st.gtfs_version_id == ^v,
      where: st.trip_id == ^trip_id,
      order_by: [asc_nulls_last: st.stop_sequence],
      select: st.stop_id
    )
    |> Repo.all()
    |> Enum.uniq()
  end

  defp stops_beyond_spine(%AuditContext{organization_id: o, gtfs_version_id: v}, route_id, spine) do
    from(st in StopTime,
      join: t in Trip,
      on: t.trip_id == st.trip_id,
      where: st.organization_id == ^o and st.gtfs_version_id == ^v,
      where: t.organization_id == ^o and t.gtfs_version_id == ^v,
      where: t.route_id == ^route_id and st.stop_id not in ^spine,
      group_by: st.stop_id,
      select: {st.stop_id, min(st.stop_sequence)}
    )
    |> Repo.all()
    # A stop whose only recorded position is absent sorts last rather than first.
    |> Enum.sort_by(fn {stop_id, position} -> {is_nil(position), position || 0, stop_id} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp route_trips(%AuditContext{organization_id: o, gtfs_version_id: v}, route_id, direction_id) do
    Trip
    |> where([t], t.organization_id == ^o and t.gtfs_version_id == ^v)
    |> where([t], t.route_id == ^route_id)
    |> where_direction(direction_id)
    |> order_by([t], asc_nulls_last: t.trip_id)
    |> Repo.all()
  end

  defp where_direction(query, nil), do: query

  defp where_direction(query, direction_id),
    do: where(query, [t], t.direction_id == ^direction_id)

  # The weekly rows and the exceptions of the version, grouped by the service
  # the trips name, so `ServiceDates` evaluates the same data the Calendar helper
  # does instead of a second rule for "runs on that day".
  defp service_exceptions(%AuditContext{organization_id: o, gtfs_version_id: v}, trips) do
    service_ids = trips |> Enum.map(& &1.service_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    calendars =
      from(c in Calendar,
        where: c.organization_id == ^o and c.gtfs_version_id == ^v,
        where: c.service_id in ^service_ids,
        select: c
      )
      |> Repo.all()
      |> Map.new(&{&1.service_id, &1})

    exceptions =
      from(cd in CalendarDate,
        where: cd.organization_id == ^o and cd.gtfs_version_id == ^v,
        where: cd.service_id in ^service_ids,
        order_by: [asc: cd.date],
        select: cd
      )
      |> Repo.all()
      |> Enum.group_by(& &1.service_id)

    %{calendars: calendars, exceptions: exceptions}
  end

  # The evaluator raises for a retained calendar whose source cannot be read, such
  # as an imported range that ends before it starts. That service's trips are not
  # offered, so one bad calendar does not stop the route's other departures from
  # being listed (`ServiceQueries.active_on?/3` guards the same call).
  defp running_on?(%Trip{service_id: service_id}, services, date) do
    active =
      ServiceDates.active_dates_between(
        Map.get(services.calendars, service_id),
        Map.get(services.exceptions, service_id, []),
        date,
        date
      )

    date in active
  rescue
    ArgumentError -> false
  end

  # A trip with no readable first stop time has no departure the operator could
  # recognize, so it is not offered as one.
  defp departure(%AuditContext{} = audit_context, %Trip{} = trip) do
    case first_departure_seconds(audit_context, trip) do
      {:ok, seconds} ->
        %{
          trip_id: trip.id,
          label: departure_label(seconds, trip.trip_headsign),
          first_departure_seconds: seconds
        }

      :error ->
        nil
    end
  end

  defp first_departure_seconds(
         %AuditContext{organization_id: o, gtfs_version_id: v},
         %Trip{} = trip
       ) do
    from(st in StopTime,
      where: st.organization_id == ^o and st.gtfs_version_id == ^v,
      where: st.trip_id == ^trip.trip_id,
      order_by: [asc_nulls_last: st.stop_sequence],
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> :error
      stop_time -> parse_seconds(stop_time.departure_time || stop_time.arrival_time)
    end
  end

  defp parse_seconds(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> {:ok, seconds}
      {:error, :invalid_time} -> :error
    end
  end

  # The schedule's own clock, read as a civil time. A value beyond 24:00 is the
  # next day's departure and says so, rather than reading as an earlier one.
  defp departure_label(seconds, headsign) do
    time = Time.add(@midnight, rem(seconds, @day_seconds), :second)
    clock = @label_origin |> NaiveDateTime.new!(time) |> DisplayClock.format_time()

    clock = if seconds >= @day_seconds, do: clock <> " (next day)", else: clock

    case present_name(List.wrap(headsign)) do
      nil -> clock
      headsign -> clock <> " to " <> headsign
    end
  end

  # -- Labels for a stored alert -------------------------------------------

  # An identity that cannot be parsed can never name a row, so it is simply
  # absent from the labels - the same reading `Alerts.Listing` gives it. Each
  # table is read once for every identity at once, so labelling an alert does
  # not grow with the number of rows it names.
  defp route_labels(_audit_context, []), do: %{}

  defp route_labels(%AuditContext{organization_id: o, gtfs_version_id: v}, ids) do
    from(r in Route,
      where: r.organization_id == ^o and r.gtfs_version_id == ^v,
      where: r.id in ^uuids(ids)
    )
    |> Repo.all()
    |> Map.new(&{&1.id, route_label(&1)})
  end

  defp stop_labels(_audit_context, []), do: %{}

  defp stop_labels(%AuditContext{organization_id: o, gtfs_version_id: v}, ids) do
    from(s in Stop,
      where: s.organization_id == ^o and s.gtfs_version_id == ^v,
      where: s.id in ^uuids(ids)
    )
    |> Repo.all()
    |> Map.new(&{&1.id, stop_label(&1)})
  end

  defp trip_labels(_audit_context, []), do: %{}

  defp trip_labels(%AuditContext{} = audit_context, ids) do
    from(t in Trip,
      where: t.organization_id == ^audit_context.organization_id,
      where: t.gtfs_version_id == ^audit_context.gtfs_version_id,
      where: t.id in ^uuids(ids)
    )
    |> Repo.all()
    |> Map.new(fn trip ->
      label =
        case first_departure_seconds(audit_context, trip) do
          {:ok, seconds} -> departure_label(seconds, trip.trip_headsign)
          :error -> present_name(List.wrap(trip.trip_headsign)) || trip.trip_id
        end

      {trip.id, label}
    end)
  end

  # -- Shared helpers ------------------------------------------------------

  # A blank query is not a query. The wildcard characters are escaped so an
  # operator's literal text cannot widen the match, as in the transfer editor.
  defp search_pattern(query) when is_binary(query) do
    case String.trim(query) do
      "" ->
        nil

      trimmed ->
        "%" <> Gtfs.escape_like_pattern(trimmed) <> "%"
    end
  end

  defp search_pattern(_query), do: nil

  # The GTFS stop ids the preferred routes serve, or none when no route is
  # preferred.
  defp preferred_stop_ids(_audit_context, []), do: []

  defp preferred_stop_ids(%AuditContext{organization_id: o, gtfs_version_id: v}, route_uuids) do
    route_ids =
      from(r in Route,
        where: r.organization_id == ^o and r.gtfs_version_id == ^v,
        where: r.id in ^route_uuids,
        select: r.route_id
      )
      |> Repo.all()

    from(st in StopTime,
      join: t in Trip,
      on: t.trip_id == st.trip_id,
      where: st.organization_id == ^o and st.gtfs_version_id == ^v,
      where: t.organization_id == ^o and t.gtfs_version_id == ^v,
      where: t.route_id in ^route_ids,
      select: st.stop_id,
      distinct: true
    )
    |> Repo.all()
  end

  # An identity that is not a row UUID is dropped before it can reach a query,
  # which is what keeps a forged or malformed id from becoming a database error.
  defp uuids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
  end

  defp uuids(_ids), do: []
end

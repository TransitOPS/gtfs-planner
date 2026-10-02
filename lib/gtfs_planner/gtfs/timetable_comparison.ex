defmodule GtfsPlanner.Gtfs.TimetableComparison do
  @moduledoc """
  The bounded, authorized feed snapshot one approved-timetable comparison is
  computed from.

  `load/2` is a library precursor: it reads the route's complete applicable feed
  rows inside one PostgreSQL `REPEATABLE READ READ ONLY` transaction and returns
  them as one digest-identified value. It classifies nothing. `compare/2` (step 7)
  owns the mapping, date expansion, witnesses and report; `page/3` and the
  freshness re-check belong to steps 7 and 8. Nothing here writes, and nothing
  here calls a provider: the transaction is closed before the caller does
  anything else (CR-3, CL-5, INV-1, INV-3).

  ## Contracts

    * `scope` is server-owned: `%{organization_id:, gtfs_version_id:, actor_id:,
      route_id:}`, all UUIDs, built from a host's own assigns and never from a
      tool argument. The actor's current editor membership and the scoped
      `published` version and route are re-read **inside** the transaction, so a
      membership withdrawn between two reads cannot expose a row.
    * `selection` is the reviewed comparison scope: the inclusive
      `{first_date, last_date}` interval plus optional reviewed `direction_ids`,
      `pattern_ids` and `service_ids`. `nil` for a selector means every value the
      route actually has for it, so a narrowing is always explicit. An interval
      longer than 366 inclusive dates is refused whole.
    * Work is bounded: at most 10,000 scoped trips and 75,000 scoped stop-time
      rows. Each is read with its own `LIMIT cap + 1` and refused as
      `{:error, {:incomplete, reason}}` when it is exceeded. Rows are never
      truncated, and no refusal ever carries a partial answer that could read as
      a clean comparison.
    * Effective service dates come from the shared
      `Calendars.ServiceDates.active_dates_between/4` with the calendar's weekly
      row and its additions and removals, so an exception-only calendar is still
      service and a removal wins over the weekly baseline. `GtfsTime.parse/1`
      reads `arrival_time` and `departure_time` separately and keeps values past
      24:00; the `ServiceQueries` departure-fallback helper is deliberately not
      used, because an arrival is not a departure.
    * The digest is the server's hash of the exact normalized rows this answer
      was computed from, so two reads of two different states cannot produce the
      same digest and a stale report can be detected by reloading (CL-5, FH-5).
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # Conservative engineering ceilings, not measured workloads. Each is enforced
  # by its own query's `LIMIT`, so an over-limit scope never materializes an
  # unbounded row set before it is refused.
  @max_dates 366
  @max_trips 10_000
  @max_stop_times 75_000

  # Frequency rows hang off scoped trips, so a per-trip ceiling derived from the
  # trip ceiling bounds them without inventing a scale promise.
  @max_frequencies @max_trips

  @published_status "published"

  @typedoc "Server-owned organization, version, actor and route identity."
  @type scope :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          required(:actor_id) => Ecto.UUID.t(),
          required(:route_id) => Ecto.UUID.t()
        }

  @typedoc """
  The reviewed comparison scope. `interval` is `{first_date, last_date}`
  inclusive; each selector is `nil` (every value the route has) or a list of
  distinct reviewed values.
  """
  @type selection :: %{
          required(:interval) => {Date.t(), Date.t()},
          optional(:direction_ids) => [0 | 1] | nil,
          optional(:pattern_ids) => [String.t()] | nil,
          optional(:service_ids) => [String.t()] | nil
        }

  @typedoc "One stop occurrence of a route pattern, in the pattern's own order."
  @type pattern_occurrence :: %{stop_id: String.t(), position: non_neg_integer()}

  @typedoc "One scoped route pattern and every occurrence it boards at."
  @type pattern :: %{
          route_pattern_id: String.t(),
          name: String.t() | nil,
          direction_id: 0 | 1 | nil,
          headsign: String.t() | nil,
          occurrences: [pattern_occurrence()]
        }

  @typedoc "One scoped trip, with the service dates it actually runs."
  @type trip :: %{
          trip_id: String.t(),
          service_id: String.t(),
          direction_id: 0 | 1 | nil,
          headsign: String.t() | nil,
          short_name: String.t() | nil,
          pattern_id: String.t() | nil,
          service_dates: [Date.t()]
        }

  @typedoc """
  One scoped stop time. `arrival_secs` and `departure_secs` are read separately
  and are independently `nil` when the retained value cannot be parsed, so an
  unreadable arrival is never filled in from the departure.
  """
  @type stop_time :: %{
          trip_id: String.t(),
          stop_id: String.t(),
          stop_sequence: integer(),
          arrival_time: String.t() | nil,
          departure_time: String.t() | nil,
          arrival_secs: non_neg_integer() | nil,
          departure_secs: non_neg_integer() | nil,
          timepoint: integer() | nil,
          pickup_type: integer() | nil,
          drop_off_type: integer() | nil
        }

  @typedoc "One `frequencies.txt` row, kept as a window and never expanded here."
  @type frequency :: %{
          trip_id: String.t(),
          start_secs: non_neg_integer() | nil,
          end_secs: non_neg_integer() | nil,
          headway_secs: pos_integer() | nil,
          exact_times: 0 | 1
        }

  @typedoc "The weekly row, exceptions and effective dates of one scoped service."
  @type service :: %{
          service_id: String.t(),
          weekly:
            %{
              monday: integer(),
              tuesday: integer(),
              wednesday: integer(),
              thursday: integer(),
              friday: integer(),
              saturday: integer(),
              sunday: integer(),
              start_date: Date.t(),
              end_date: Date.t()
            }
            | nil,
          exceptions: [%{date: Date.t(), exception_type: 1 | 2}],
          active_dates: [Date.t()]
        }

  @typedoc """
  Everything one comparison is computed from, plus the digest that identifies it.

  `completeness` is `:incomplete` when a scoped calendar could not be read, so a
  caller can never derive a clean verdict from it.
  """
  @type inputs :: %{
          scope: %{
            organization_id: Ecto.UUID.t(),
            gtfs_version_id: Ecto.UUID.t(),
            route_id: Ecto.UUID.t()
          },
          route: %{
            id: Ecto.UUID.t(),
            route_id: String.t(),
            state: :active | :inactive,
            agency_id: String.t() | nil
          },
          selection: selection(),
          interval: {Date.t(), Date.t()},
          services: %{optional(String.t()) => service()},
          service_ids: [String.t()],
          trips: [trip()],
          stop_times: [stop_time()],
          frequencies: [frequency()],
          patterns: [pattern()],
          unreadable_service_ids: [String.t()],
          totals: %{
            trips: non_neg_integer(),
            stop_times: non_neg_integer(),
            frequencies: non_neg_integer()
          },
          completeness: :complete | :incomplete,
          feed_digest: String.t()
        }

  @type error ::
          :forbidden
          | :not_found
          | :invalid_selection
          | {:incomplete, {:too_many_dates, pos_integer()}}
          | {:incomplete, {:too_many_trips, pos_integer()}}
          | {:incomplete, {:too_many_stop_times, pos_integer()}}
          | {:incomplete, {:too_many_frequencies, pos_integer()}}

  @doc """
  Returns the loader's work ceilings, so the bound a caller is told about and the
  bound the queries enforce cannot drift apart.

  At most 366 inclusive dates, 10,000 scoped trips and 75,000 scoped stop-time
  rows. A larger scope is refused as `{:error, {:incomplete, reason}}` and is
  never truncated into a partial answer.
  """
  @spec limits() :: %{dates: pos_integer(), trips: pos_integer(), stop_times: pos_integer()}
  def limits, do: %{dates: @max_dates, trips: @max_trips, stop_times: @max_stop_times}

  @doc """
  Loads the route's complete applicable feed rows for one reviewed comparison
  scope.

  `scope` is the server-owned organization, version, actor and route; `selection`
  is `%{interval: {first_date, last_date}}` plus optional reviewed
  `direction_ids`, `pattern_ids` and `service_ids`. The actor's current editor
  membership, the scoped `published` version and the route are all checked
  inside the one read transaction, before any row is returned.

  Returns `{:ok, inputs}`, or one of:

    * `{:error, :forbidden}` — the actor has no current editor membership.
    * `{:error, :not_found}` — the version is not a published version of that
      organization, or the route is not in it.
    * `{:error, :invalid_selection}` — a malformed interval or selector.
    * `{:error, {:incomplete, reason}}` — the scope exceeds a work ceiling, so
      nothing was computed and nothing may read as a clean comparison.

  No model request is ever made while the snapshot is held.
  """
  @spec load(scope(), selection()) :: {:ok, inputs()} | {:error, error()}
  def load(scope, selection) when is_map(scope) and is_map(selection) do
    with {:ok, scoped} <- scoped(scope),
         {:ok, bounded} <- comparison_selection(selection) do
      in_snapshot(fn -> comparison_answer(scoped, bounded) end)
    end
  end

  def load(_scope, _selection), do: {:error, :invalid_selection}

  # -- snapshot boundary ------------------------------------------------------

  # Every read of one answer, including the membership and scope checks that
  # authorize it, happens inside this transaction, and the digest is derived
  # from the rows it returned. The transaction is closed before the caller
  # builds a model request, so no provider call is ever made while it is held.
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

  defp scoped(scope) do
    with {:ok, organization_id} <- uuid(Map.get(scope, :organization_id)),
         {:ok, gtfs_version_id} <- uuid(Map.get(scope, :gtfs_version_id)),
         {:ok, actor_id} <- uuid(Map.get(scope, :actor_id)),
         {:ok, route_id} <- uuid(Map.get(scope, :route_id)) do
      {:ok,
       %{
         organization_id: organization_id,
         gtfs_version_id: gtfs_version_id,
         actor_id: actor_id,
         route_id: route_id
       }}
    else
      _other -> {:error, :not_found}
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp comparison_selection(selection) do
    interval = Map.get(selection, :interval)

    with {:ok, bounded_interval} <- bounded_interval(interval),
         {:ok, direction_ids} <- directions(Map.get(selection, :direction_ids)),
         {:ok, pattern_ids} <- ids(Map.get(selection, :pattern_ids)),
         {:ok, service_ids} <- ids(Map.get(selection, :service_ids)) do
      {:ok,
       %{
         interval: bounded_interval,
         direction_ids: direction_ids,
         pattern_ids: pattern_ids,
         service_ids: service_ids
       }}
    end
  end

  defp bounded_interval({%Date{} = first, %Date{} = last}) do
    case Date.compare(first, last) do
      :gt ->
        {:error, :invalid_selection}

      _other ->
        count = Date.diff(last, first) + 1

        if count > @max_dates do
          {:error, {:incomplete, {:too_many_dates, count}}}
        else
          {:ok, {first, last}}
        end
    end
  end

  defp bounded_interval(_interval), do: {:error, :invalid_selection}

  defp directions(nil), do: {:ok, nil}

  defp directions(direction_ids) when is_list(direction_ids) do
    if direction_ids != [] and Enum.all?(direction_ids, &(&1 in [0, 1])) and
         length(Enum.uniq(direction_ids)) == length(direction_ids) do
      {:ok, Enum.sort(direction_ids)}
    else
      {:error, :invalid_selection}
    end
  end

  defp directions(_direction_ids), do: {:error, :invalid_selection}

  defp ids(nil), do: {:ok, nil}

  defp ids(values) when is_list(values) do
    if values != [] and Enum.all?(values, &nonblank?/1) and
         length(Enum.uniq(values)) == length(values) do
      {:ok, Enum.sort(values)}
    else
      {:error, :invalid_selection}
    end
  end

  defp ids(_values), do: {:error, :invalid_selection}

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  # -- the answer -------------------------------------------------------------

  defp comparison_answer(scoped, selection) do
    with :ok <- authorize(scoped),
         {:ok, route} <- published_route(scoped),
         {:ok, trip_rows, service_ids} <- scoped_trips(scoped, route, selection),
         {:ok, stop_time_rows} <- scoped_stop_times(scoped, trip_rows),
         {:ok, frequency_rows} <- scoped_frequencies(scoped, trip_rows),
         {:ok, patterns} <- scoped_patterns(scoped, route, selection, trip_rows) do
      {:ok,
       inputs(
         scoped,
         route,
         selection,
         trip_rows,
         service_ids,
         stop_time_rows,
         frequency_rows,
         patterns
       )}
    end
  end

  # The membership is re-read here, inside the snapshot transaction, so an access
  # withdrawn after the conversation started stops this read too (INV-1).
  defp authorize(scoped) do
    case Authorization.authorize_editor(%{
           actor_id: scoped.actor_id,
           organization_id: scoped.organization_id
         }) do
      :ok -> :ok
      {:error, :forbidden} -> {:error, :forbidden}
    end
  end

  # An unpublished version and a foreign or absent route are the same refusal, so
  # no other tenant's metadata is disclosed.
  defp published_route(scoped) do
    version =
      from(v in GtfsVersion,
        where:
          v.id == ^scoped.gtfs_version_id and v.organization_id == ^scoped.organization_id and
            v.publication_status == ^@published_status
      )

    case Repo.one(version) do
      nil ->
        {:error, :not_found}

      %GtfsVersion{} ->
        route =
          from(r in Route,
            where:
              r.id == ^scoped.route_id and r.organization_id == ^scoped.organization_id and
                r.gtfs_version_id == ^scoped.gtfs_version_id
          )

        case Repo.one(route) do
          %Route{} = found -> {:ok, found}
          nil -> {:error, :not_found}
        end
    end
  end

  defp scoped_trips(scoped, %Route{} = route, selection) do
    trips =
      Trip
      |> scoped_to_route(scoped, route)
      |> narrowed(:direction_id, selection.direction_ids)
      |> narrowed(:route_pattern_id, selection.pattern_ids)
      |> narrowed(:service_id, selection.service_ids)
      |> order_by([t], asc: t.trip_id, asc: t.id)
      |> Repo.all(limit: @max_trips + 1)

    case trips do
      [_ | _] = loaded when length(loaded) > @max_trips ->
        {:error, {:incomplete, {:too_many_trips, length(loaded)}}}

      _loaded ->
        {:ok, trips, trips |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp scoped_to_route(query, scoped, %Route{route_id: route_id}) do
    from(t in query,
      where:
        t.organization_id == ^scoped.organization_id and
          t.gtfs_version_id == ^scoped.gtfs_version_id and t.route_id == ^route_id
    )
  end

  # A reviewed selector narrows the scoped route; an absent one keeps every value
  # the route has, so the widened scope is never a guess about which trips matter.
  defp narrowed(query, _field, nil), do: query
  defp narrowed(query, field, values), do: from(t in query, where: field(t, ^field) in ^values)

  defp scoped_stop_times(scoped, trips) do
    case trip_ids(trips) do
      [] ->
        {:ok, []}

      trip_ids ->
        rows =
          from(s in StopTime,
            where:
              s.organization_id == ^scoped.organization_id and
                s.gtfs_version_id == ^scoped.gtfs_version_id and s.trip_id in ^trip_ids,
            order_by: [asc: s.trip_id, asc: s.stop_sequence, asc: s.id],
            limit: @max_stop_times + 1
          )
          |> Repo.all()

        case rows do
          [_ | _] = loaded when length(loaded) > @max_stop_times ->
            {:error, {:incomplete, {:too_many_stop_times, length(loaded)}}}

          _loaded ->
            {:ok, rows}
        end
    end
  end

  defp scoped_frequencies(scoped, trips) do
    case trip_ids(trips) do
      [] ->
        {:ok, []}

      trip_ids ->
        rows =
          from(f in Frequency,
            where:
              f.organization_id == ^scoped.organization_id and
                f.gtfs_version_id == ^scoped.gtfs_version_id and f.trip_id in ^trip_ids,
            order_by: [asc: f.trip_id, asc: f.start_time, asc: f.id],
            limit: @max_frequencies + 1
          )
          |> Repo.all()

        case rows do
          [_ | _] = loaded when length(loaded) > @max_frequencies ->
            {:error, {:incomplete, {:too_many_frequencies, length(loaded)}}}

          _loaded ->
            {:ok, rows}
        end
    end
  end

  defp trip_ids([]), do: []
  defp trip_ids(trips), do: trips |> Enum.map(& &1.trip_id) |> Enum.uniq()

  # Patterns are the reviewed scope's own vocabulary: with reviewed pattern ids
  # the route must actually have every one of them, and with none every pattern
  # the scoped trips use is loaded. A narrowing is never silently widened and a
  # pattern the route does not run is refused rather than read from another
  # scope.
  defp scoped_patterns(scoped, %Route{} = route, selection, trips) do
    route_patterns =
      from(p in RoutePattern,
        where:
          p.organization_id == ^scoped.organization_id and
            p.gtfs_version_id == ^scoped.gtfs_version_id and p.route_id == ^route.route_id,
        order_by: [asc: p.route_pattern_id, asc: p.id]
      )
      |> Repo.all()

    requested =
      case selection.pattern_ids do
        nil -> trip_pattern_ids(trips)
        ids -> ids
      end

    case requested do
      [] ->
        {:ok, []}

      requested ->
        known = route_patterns |> Enum.map(& &1.route_pattern_id) |> Enum.uniq()

        if selection.pattern_ids != nil and not Enum.all?(requested, &(&1 in known)) do
          {:error, :not_found}
        else
          selected = Enum.filter(route_patterns, &(&1.route_pattern_id in requested))
          {:ok, attach_occurrences(scoped, selected, known)}
        end
    end
  end

  defp trip_pattern_ids([]), do: []

  defp trip_pattern_ids(trips),
    do: trips |> Enum.map(& &1.route_pattern_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp attach_occurrences(_scoped, [], _pattern_ids), do: []

  # `RoutePatternStop.route_pattern_id` is the pattern row's own UUID, so the
  # occurrences are read by that identity and reported under the GTFS pattern id
  # the reviewed selection named.
  defp attach_occurrences(scoped, patterns, _pattern_ids) do
    occurrences =
      from(o in RoutePatternStop,
        where:
          o.organization_id == ^scoped.organization_id and
            o.gtfs_version_id == ^scoped.gtfs_version_id and
            o.route_pattern_id in ^Enum.map(patterns, & &1.id),
        order_by: [asc: o.route_pattern_id, asc: o.position, asc: o.id],
        select: %{route_pattern_id: o.route_pattern_id, stop_id: o.stop_id, position: o.position}
      )
      |> Repo.all()
      |> Enum.group_by(& &1.route_pattern_id)

    Enum.map(patterns, fn %RoutePattern{} = pattern ->
      %{
        route_pattern_id: pattern.route_pattern_id,
        name: pattern.route_pattern_name,
        direction_id: pattern.direction_id,
        headsign: pattern.headsign,
        occurrences:
          occurrences
          |> Map.get(pattern.id, [])
          |> Enum.map(&%{stop_id: &1.stop_id, position: &1.position})
      }
    end)
  end

  # -- normalization ----------------------------------------------------------

  defp inputs(
         scoped,
         route,
         selection,
         trip_rows,
         service_ids,
         stop_time_rows,
         frequency_rows,
         patterns
       ) do
    {services, unreadable} = services(scoped, service_ids, selection.interval)
    active_by_service = Map.new(services, &{&1.service_id, &1.active_dates})
    stop_times = Enum.map(stop_time_rows, &normalize_stop_time/1)
    frequencies = Enum.map(frequency_rows, &normalize_frequency/1)

    scope = %{
      organization_id: scoped.organization_id,
      gtfs_version_id: scoped.gtfs_version_id,
      route_id: route.id
    }

    %{
      scope: scope,
      route: route_summary(route),
      selection: selection,
      interval: selection.interval,
      services: Map.new(services, &{&1.service_id, &1}),
      service_ids: service_ids,
      trips: Enum.map(trip_rows, &normalize_trip(&1, active_by_service)),
      stop_times: stop_times,
      frequencies: frequencies,
      patterns: patterns,
      unreadable_service_ids: unreadable,
      totals: %{
        trips: length(trip_rows),
        stop_times: length(stop_times),
        frequencies: length(frequencies)
      },
      completeness: if(unreadable == [], do: :complete, else: :incomplete),
      feed_digest:
        digest(%{
          scope: scope,
          route: route.route_id,
          selection: selection,
          services: services,
          unreadable: unreadable,
          trips: Enum.map(trip_rows, &trip_digest_row/1),
          stop_times: stop_times,
          frequencies: frequencies,
          patterns: patterns
        })
    }
  end

  defp route_summary(%Route{} = route) do
    %{
      id: route.id,
      route_id: route.route_id,
      state: if(route.active, do: :active, else: :inactive),
      agency_id: route.agency_id
    }
  end

  defp normalize_trip(%Trip{} = trip, active_by_service) do
    %{
      trip_id: trip.trip_id,
      service_id: trip.service_id,
      direction_id: trip.direction_id,
      headsign: trip.trip_headsign,
      short_name: trip.trip_short_name,
      pattern_id: trip.route_pattern_id,
      service_dates: Map.get(active_by_service, trip.service_id, [])
    }
  end

  defp trip_digest_row(%Trip{} = trip) do
    {trip.trip_id, trip.service_id, trip.direction_id, trip.route_pattern_id}
  end

  defp normalize_stop_time(%StopTime{} = row) do
    %{
      trip_id: row.trip_id,
      stop_id: row.stop_id,
      stop_sequence: row.stop_sequence,
      arrival_time: row.arrival_time,
      departure_time: row.departure_time,
      arrival_secs: clock(row.arrival_time),
      departure_secs: clock(row.departure_time),
      timepoint: row.timepoint,
      pickup_type: row.pickup_type,
      drop_off_type: row.drop_off_type
    }
  end

  # Arrival and departure are parsed independently: an unreadable arrival stays
  # unknown rather than borrowing the departure, and both keep their service-day
  # seconds past 24:00.
  defp clock(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> nil
    end
  end

  defp normalize_frequency(%Frequency{} = row) do
    %{
      trip_id: row.trip_id,
      start_secs: clock(row.start_time),
      end_secs: clock(row.end_time),
      headway_secs: row.headway_secs,
      exact_times: if(row.exact_times == 1, do: 1, else: 0)
    }
  end

  # The weekly row and every exception of each scoped service are read whole, and
  # the effective dates come from the shared date evaluator. An unreadable
  # retained weekly range or a contradictory exception cannot be computed, so the
  # service is disclosed as unreadable and the answer is incomplete rather than
  # reporting no service.
  defp services(scoped, service_ids, {first, last}) do
    Enum.reduce(service_ids, {[], []}, fn service_id, {services, unreadable} ->
      case service_dates(scoped, service_id, first, last) do
        {:ok, service} -> {services ++ [service], unreadable}
        :unreadable -> {services, unreadable ++ [service_id]}
      end
    end)
    |> case do
      {services, unreadable} -> {Enum.sort_by(services, & &1.service_id), Enum.sort(unreadable)}
    end
  end

  defp service_dates(scoped, service_id, first, last) do
    calendar =
      Repo.one(
        from(c in Calendar,
          where:
            c.organization_id == ^scoped.organization_id and
              c.gtfs_version_id == ^scoped.gtfs_version_id and c.service_id == ^service_id
        )
      )

    exceptions =
      from(d in CalendarDate,
        where:
          d.organization_id == ^scoped.organization_id and
            d.gtfs_version_id == ^scoped.gtfs_version_id and d.service_id == ^service_id,
        order_by: [asc: d.date, asc: d.id]
      )
      |> Repo.all()

    try do
      {:ok,
       %{
         service_id: service_id,
         weekly: weekly_row(calendar),
         exceptions: Enum.map(exceptions, &%{date: &1.date, exception_type: exception_type(&1)}),
         active_dates: ServiceDates.active_dates_between(calendar, exceptions, first, last)
       }}
    rescue
      ArgumentError -> :unreadable
    end
  end

  defp weekly_row(nil), do: nil

  defp weekly_row(%Calendar{} = calendar) do
    %{
      monday: calendar.monday,
      tuesday: calendar.tuesday,
      wednesday: calendar.wednesday,
      thursday: calendar.thursday,
      friday: calendar.friday,
      saturday: calendar.saturday,
      sunday: calendar.sunday,
      start_date: calendar.start_date,
      end_date: calendar.end_date
    }
  end

  defp exception_type(%CalendarDate{exception_type: 2}), do: 2
  defp exception_type(%CalendarDate{}), do: 1

  # -- digest ----------------------------------------------------------------

  # The digest identifies the exact content this answer was computed from, not a
  # chronological revision: it covers the normalized rows the snapshot returned
  # and the server-owned scope and selection.
  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

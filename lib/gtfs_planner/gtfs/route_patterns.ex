defmodule GtfsPlanner.Gtfs.RoutePatterns do
  @moduledoc "Scoped reads and audited lifecycle writes for editable route patterns."

  import Ecto.Query

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Headsigns
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.RoutePatterns.TimingRules
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @pattern_fields ~w(route_pattern_name route_pattern_time_desc route_pattern_typicality direction_id headsign canonical_route_pattern route_pattern_sort_order)
  @stop_search_limit 20
  @timing_fields ~w(name headsign)
  @forbidden_linkage_fields ~w(timed_pattern_id pattern_derivation_state pattern_derivation_reason trip_id trip_ids derivation_key)

  def list_patterns(organization_id, version_id, route_id) do
    with {:ok, _route} <- published_route(organization_id, version_id, route_id) do
      patterns =
        from(pattern in RoutePattern,
          where:
            pattern.organization_id == ^organization_id and
              pattern.gtfs_version_id == ^version_id and pattern.route_id == ^route_id,
          order_by: [
            asc: pattern.direction_id,
            asc: pattern.route_pattern_sort_order,
            asc: pattern.route_pattern_id
          ]
        )
        |> Repo.all()

      {:ok, %{patterns: patterns}}
    end
  end

  @doc """
  Counts the trips left outside patterns in one organization and version, grouped
  by route and reason.

  `route_id` narrows the read to a single published route; `nil` covers the whole
  version. Rows are ordered by `route_id` and then by descending count, with the
  reason breaking ties so the order is stable for equal counts.
  """
  def left_out(organization_id, version_id, route_id \\ nil) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and
          t.gtfs_version_id == ^version_id and t.pattern_derivation_state == "custom",
      group_by: [t.route_id, t.pattern_derivation_reason],
      order_by: [asc: t.route_id],
      select: %{
        route_id: t.route_id,
        reason: t.pattern_derivation_reason,
        trip_count: count(t.id)
      }
    )
    |> maybe_left_out_route(route_id)
    |> order_by([t], desc: count(t.id), asc: t.pattern_derivation_reason)
    |> Repo.all()
  end

  defp maybe_left_out_route(query, nil), do: query

  defp maybe_left_out_route(query, route_id),
    do: where(query, [t], t.route_id == ^route_id)

  def get_pattern(organization_id, version_id, route_id, pattern_id, timing_id \\ nil) do
    with {:ok, _route} <- published_route(organization_id, version_id, route_id),
         %RoutePattern{} = pattern <-
           scoped_pattern(organization_id, version_id, route_id, pattern_id),
         {:ok, timing} <- selected_timing(pattern, timing_id) do
      occurrences =
        from(occurrence in RoutePatternStop,
          where: occurrence.route_pattern_id == ^pattern.id,
          order_by: [asc: occurrence.position]
        )
        |> Repo.all()

      timings =
        from(row in TimedPattern,
          where: row.route_pattern_id == ^pattern.id,
          order_by: [asc: row.name, asc: row.id]
        )
        |> Repo.all()

      {:ok,
       %{
         pattern: pattern,
         occurrences: occurrences,
         timings: timings,
         selected_timing: timing,
         source_fingerprint: source_fingerprint(pattern)
       }}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @type scope :: :pattern | {:timing, Ecto.UUID.t()}

  @type usage_trip :: %{
          id: Ecto.UUID.t(),
          trip_id: String.t(),
          headsign: String.t() | nil,
          service_id: String.t(),
          departure_secs: integer() | nil,
          timing_name: String.t() | nil,
          custom?: boolean(),
          next_block:
            nil
            | %{
                route_short_name: String.t() | nil,
                departure_secs: integer(),
                headsign: String.t() | nil
              },
          mid_trip_change: String.t() | nil
        }

  @type usage_group :: %{
          value: String.t() | nil,
          kind: Headsigns.kind() | :follows,
          likely_typo: boolean(),
          trips: [usage_trip()]
        }

  @type usage_timing :: %{
          timing_id: Ecto.UUID.t(),
          name: String.t(),
          headsign: String.t(),
          trip_count: non_neg_integer()
        }

  @type usage :: %{
          scope: scope(),
          default: String.t() | nil,
          total: non_neg_integer(),
          same: non_neg_integer(),
          differ: non_neg_integer(),
          shielded: [usage_timing()],
          timings_carry: [usage_timing()],
          groups: [usage_group()]
        }

  @doc """
  Scoped headsign usage read model for one pattern (scope `:pattern`) or one of
  its timings (scope `{:timing, timing_id}`).

  The pattern scope covers the pattern's organization and version-scoped trips
  whose timing is absent or has no own headsign; trips on a timing with its own
  headsign are shielded and reported in `shielded` with their trip counts. The
  timing scope covers only that timing's trips. `default` is the normalized
  effective default: the scope's own timing headsign, else the pattern headsign.

  When the pattern headsign is nil, `timings_carry` lists every timing that
  carries a headsign of its own, so an imported dataset can still show where
  the headsign lives.

  `opts` requires `:organization_id` and `:gtfs_version_id`. `opts[:from]`
  (change mode) splits the trips that still follow `from` into a first
  `:follows` group. Groups otherwise hold only trips that differ from the
  default, ordered likely typo first, then by trip count descending, then by
  value. Trips in differing groups also carry their block and mid-trip facts:
  `next_block` names the earliest later trip in the same organization,
  version, service and block on another route (nil when the next block trip
  runs this route), and `mid_trip_change` names the first stop where the
  trip's timing carries its own stop headsign. Trips in the `:follows` group
  keep both facts nil.

  An unknown pattern id, a timing outside the pattern, or an unrecognized scope
  returns `{:error, :not_found}` so a crafted scope cannot read foreign data.
  """
  @spec headsign_usage(Ecto.UUID.t(), scope(), keyword()) :: {:ok, usage()} | {:error, :not_found}
  def headsign_usage(pattern_id, scope, opts) when is_binary(pattern_id) and is_list(opts) do
    organization_id = Keyword.fetch!(opts, :organization_id)
    gtfs_version_id = Keyword.fetch!(opts, :gtfs_version_id)

    case scoped_pattern_by_id(organization_id, gtfs_version_id, pattern_id) do
      nil -> {:error, :not_found}
      %RoutePattern{} = pattern -> headsign_usage_for_pattern(pattern, scope, opts)
    end
  end

  defp headsign_usage_for_pattern(pattern, :pattern, opts) do
    timings = pattern_timings(pattern.id)
    counts = timing_trip_counts(pattern)
    default = Headsigns.normalize(pattern.headsign)

    # A timing with its own headsign shields its trips from the pattern scope.
    # When the pattern headsign is nil, those timings carry the headsign
    # instead, so the editor can offer to adopt one of their values.
    carrying = Enum.filter(timings, &(Headsigns.normalize(&1.headsign) != nil))
    carrying_ids = MapSet.new(carrying, & &1.id)

    carrying_rows =
      Enum.map(carrying, fn timing ->
        %{
          timing_id: timing.id,
          name: timing.name,
          headsign: Headsigns.normalize(timing.headsign),
          trip_count: Map.get(counts, timing.id, 0)
        }
      end)

    {trips, rows_by_id} =
      usage_trips(pattern, pattern_scope_query(pattern, carrying_ids), timings)

    counts_and_groups = usage_counts_and_groups(trips, default, opts)
    groups = trip_facts(pattern, counts_and_groups.groups, default, rows_by_id)

    {:ok,
     %{
       scope: :pattern,
       default: default,
       total: counts_and_groups.total,
       same: counts_and_groups.same,
       differ: counts_and_groups.differ,
       shielded: Enum.filter(carrying_rows, &(&1.trip_count > 0)),
       timings_carry: if(default == nil, do: carrying_rows, else: []),
       groups: groups
     }}
  end

  defp headsign_usage_for_pattern(pattern, {:timing, timing_id}, opts) do
    timings = pattern_timings(pattern.id)

    case Enum.find(timings, &(&1.id == timing_id)) do
      nil ->
        {:error, :not_found}

      %TimedPattern{} = timing ->
        default = Headsigns.effective_default(timing.headsign, pattern.headsign)

        {trips, rows_by_id} =
          usage_trips(pattern, timing_scope_query(pattern, timing.id), timings)

        counts_and_groups = usage_counts_and_groups(trips, default, opts)
        groups = trip_facts(pattern, counts_and_groups.groups, default, rows_by_id)

        {:ok,
         %{
           scope: {:timing, timing.id},
           default: default,
           total: counts_and_groups.total,
           same: counts_and_groups.same,
           differ: counts_and_groups.differ,
           shielded: [],
           timings_carry: [],
           groups: groups
         }}
    end
  end

  defp headsign_usage_for_pattern(_pattern, _scope, _opts), do: {:error, :not_found}

  defp scoped_pattern_by_id(org_id, version_id, pattern_id) do
    Repo.one(
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^org_id and pattern.gtfs_version_id == ^version_id and
            pattern.id == ^pattern_id
      )
    )
  end

  # Pattern scope: trips of this pattern whose timing is absent or carries no
  # own headsign. A trip naming a timing outside this pattern has no timing
  # default, so it stays in the scope under the pattern headsign.
  defp pattern_scope_query(pattern, carrying_ids) do
    base =
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_pattern_id == ^pattern.route_pattern_id
      )

    case MapSet.size(carrying_ids) do
      0 ->
        base

      _ ->
        where(
          base,
          [trip],
          is_nil(trip.timed_pattern_id) or
            trip.timed_pattern_id not in ^MapSet.to_list(carrying_ids)
        )
    end
  end

  defp timing_scope_query(pattern, timing_id) do
    from(trip in Trip,
      where:
        trip.organization_id == ^pattern.organization_id and
          trip.gtfs_version_id == ^pattern.gtfs_version_id and
          trip.timed_pattern_id == ^timing_id
    )
  end

  # Returns the public usage trips plus the internal rows keyed by trip id;
  # the rows carry block_id and timed_pattern_id, which the facts reader needs
  # but the public usage_trip contract shape does not expose.
  defp usage_trips(pattern, query, timings) do
    rows =
      from(trip in query,
        as: :usage_trip,
        select: %{
          id: trip.id,
          trip_id: trip.trip_id,
          headsign: trip.trip_headsign,
          service_id: trip.service_id,
          timed_pattern_id: trip.timed_pattern_id,
          pattern_derivation_state: trip.pattern_derivation_state,
          block_id: trip.block_id,
          route_id: trip.route_id,
          first_departure:
            subquery(
              from(stop_time in StopTime,
                where:
                  stop_time.organization_id == ^pattern.organization_id and
                    stop_time.gtfs_version_id == ^pattern.gtfs_version_id and
                    stop_time.trip_id == parent_as(:usage_trip).trip_id,
                select: min(stop_time.departure_time)
              )
            )
        },
        order_by: [asc: trip.id]
      )
      |> Repo.all()

    timings_by_id = Map.new(timings, &{&1.id, &1})

    # Rows read chronologically, like the prototype's drawers: first departure
    # ascending with trip_id as the stable tiebreaker, no-stop-time trips last.
    # Grouping and the from-split below preserve this order.
    trips =
      rows
      |> Enum.map(fn row ->
        %{
          id: row.id,
          trip_id: row.trip_id,
          headsign: Headsigns.normalize(row.headsign),
          service_id: row.service_id,
          departure_secs: gtfs_secs(row.first_departure),
          timing_name: timing_name(timings_by_id, row.timed_pattern_id),
          custom?: row.pattern_derivation_state == "custom",
          # Block and mid-trip facts default to nil; the facts reader fills them
          # for differing groups after the counts and groups are computed.
          next_block: nil,
          mid_trip_change: nil
        }
      end)
      |> Enum.sort_by(&{&1.departure_secs == nil, &1.departure_secs || 0, &1.trip_id})

    {trips, Map.new(rows, &{&1.id, &1})}
  end

  # GTFS clock strings from the SQL min/max aggregates parse through the
  # shared clock parser; absent or unparsable values stay nil.
  defp gtfs_secs(nil), do: nil

  defp gtfs_secs(value) do
    case GtfsTime.parse(value) do
      {:ok, seconds} -> seconds
      {:error, :invalid_time} -> nil
    end
  end

  defp timing_name(timings_by_id, timed_pattern_id) do
    case Map.get(timings_by_id, timed_pattern_id) do
      %TimedPattern{name: name} -> name
      nil -> nil
    end
  end

  # An explicit `from` always splits followers — including `from: nil`, so a
  # nil default's blank trips form the change-mode follows group the update
  # box counts (AC-5's "give N trips with no headsign this headsign"). Without
  # the opt, differing keeps its usage-line meaning: trips that miss the
  # scope's effective default.
  defp usage_counts_and_groups(trips, default, opts) do
    total = length(trips)

    {followers, differing, follows_value} =
      case Keyword.fetch(opts, :from) do
        {:ok, from} ->
          from_value = Headsigns.normalize(from)

          Enum.split_with(trips, &Headsigns.follows?(&1.headsign, from_value))
          |> then(fn {followers, differing} -> {followers, differing, from_value} end)

        :error ->
          differing = Enum.reject(trips, &Headsigns.follows?(&1.headsign, default))
          {[], differing, nil}
      end

    groups = value_groups(differing, default)

    groups =
      case followers do
        [] ->
          groups

        followers ->
          [%{value: follows_value, kind: :follows, likely_typo: false, trips: followers} | groups]
      end

    %{total: total, same: total - length(differing), differ: length(differing), groups: groups}
  end

  # Trips are grouped by their normalized value, and a group's kind and typo
  # flag come from the shared Headsigns rule. Order: likely typo first, then
  # group size descending, then value (term order puts a blank group first).
  # Rows keep the chronological order usage_trips established.
  defp value_groups(trips, default) do
    trips
    |> Enum.group_by(& &1.headsign)
    |> Enum.map(fn {value, value_trips} ->
      %{kind: kind, likely_typo: likely_typo} = Headsigns.difference(value, default, nil)

      %{
        value: value,
        kind: kind,
        likely_typo: likely_typo,
        trips: value_trips
      }
    end)
    |> Enum.sort_by(&{not &1.likely_typo, -length(&1.trips), &1.value})
  end

  # Fills the block and mid-trip facts for differing groups only: trips in the
  # :follows group already follow the default, so the drawer never shows them
  # next-block or mid-trip lines and their facts stay nil (no lookups run for
  # them). The group kind is re-run through the shared Headsigns rule with the
  # facts: a group is :interline only when every trip in it continues on another
  # route, so a mixed group never explains a continuation its other trips lack.
  defp trip_facts(pattern, groups, default, rows_by_id) do
    differing_trips =
      Enum.flat_map(groups, fn
        %{kind: :follows} -> []
        group -> group.trips
      end)

    next_blocks = next_blocks_by_trip(pattern, differing_trips, rows_by_id)
    mid_trip_changes = mid_trip_changes_by_timing(pattern, differing_trips, rows_by_id)

    Enum.map(groups, fn
      %{kind: :follows} = group ->
        group

      group ->
        trips =
          Enum.map(group.trips, &put_trip_facts(&1, next_blocks, mid_trip_changes, rows_by_id))

        differences = Enum.map(trips, &Headsigns.difference(group.value, default, &1.next_block))

        %{kind: kind, likely_typo: likely_typo} =
          Enum.find(differences, hd(differences), &(&1.kind != :interline))

        %{group | trips: trips, kind: kind, likely_typo: likely_typo}
    end)
  end

  defp put_trip_facts(trip, next_blocks, mid_trip_changes, rows_by_id) do
    timed_pattern_id = Map.fetch!(rows_by_id, trip.id).timed_pattern_id

    %{
      trip
      | next_block: Map.get(next_blocks, trip.id),
        mid_trip_change: Map.get(mid_trip_changes, timed_pattern_id)
    }
  end

  # One block query per call: the differing trips join their block-mates on
  # service and block, scoped to the pattern's organization and version, on
  # another route; the differing subquery only admits trips with a non-nil
  # block id. The earliest eligible successor per differing trip is selected
  # in Elixir because first departure and last arrival are GTFS clock strings
  # compared through the shared parser, not SQL strings.
  defp next_blocks_by_trip(pattern, differing_trips, rows_by_id) do
    differing_trip_ids =
      differing_trips
      |> Enum.filter(&is_binary(Map.fetch!(rows_by_id, &1.id).block_id))
      |> Enum.map(& &1.id)

    case differing_trip_ids do
      [] ->
        %{}

      ids ->
        ids |> block_successor_rows(pattern) |> earliest_next_blocks()
    end
  end

  defp block_successor_rows(differing_trip_ids, pattern) do
    differing = differing_block_query(differing_trip_ids, pattern)

    from(successor in Trip,
      as: :block_successor,
      join: differs in subquery(differing),
      on:
        successor.service_id == differs.service_id and
          successor.block_id == differs.block_id and
          successor.route_id != differs.route_id,
      where:
        successor.organization_id == ^pattern.organization_id and
          successor.gtfs_version_id == ^pattern.gtfs_version_id,
      join: route in Route,
      on:
        route.organization_id == successor.organization_id and
          route.gtfs_version_id == successor.gtfs_version_id and
          route.route_id == successor.route_id,
      select: %{
        differing_id: differs.id,
        trip_id: successor.trip_id,
        headsign: successor.trip_headsign,
        route_short_name: route.route_short_name,
        last_arrival: differs.last_arrival,
        first_departure:
          subquery(
            from(stop_time in StopTime,
              where:
                stop_time.organization_id == ^pattern.organization_id and
                  stop_time.gtfs_version_id == ^pattern.gtfs_version_id and
                  stop_time.trip_id == parent_as(:block_successor).trip_id,
              select: min(stop_time.departure_time)
            )
          )
      }
    )
    |> Repo.all()
  end

  # The differing trips' block facts in one derived table: one row per
  # differing trip with a non-nil block id, carrying its service, block,
  # route and last arrival. The last arrival is a grouped max over the trip's
  # stop times because a nested scalar subquery is not allowed inside a
  # join's derived table.
  defp differing_block_query(differing_trip_ids, pattern) do
    from(trip in Trip,
      left_join: stop_time in StopTime,
      on:
        stop_time.organization_id == trip.organization_id and
          stop_time.gtfs_version_id == trip.gtfs_version_id and
          stop_time.trip_id == trip.trip_id,
      where:
        trip.organization_id == ^pattern.organization_id and
          trip.gtfs_version_id == ^pattern.gtfs_version_id and
          trip.id in ^differing_trip_ids and
          not is_nil(trip.block_id),
      group_by: [trip.id, trip.service_id, trip.block_id, trip.route_id],
      select: %{
        id: trip.id,
        service_id: trip.service_id,
        block_id: trip.block_id,
        route_id: trip.route_id,
        last_arrival: max(stop_time.arrival_time)
      }
    )
  end

  # A successor qualifies when its parsed first departure is at or after the
  # differing trip's parsed last arrival; absent or unparsable clock values
  # never qualify. The earliest qualifying successor wins, with the trip id
  # breaking ties deterministically.
  defp earliest_next_blocks(rows) do
    rows
    |> Enum.map(fn row ->
      departure_secs = gtfs_secs(row.first_departure)
      arrival_secs = gtfs_secs(row.last_arrival)

      %{
        differing_id: row.differing_id,
        trip_id: row.trip_id,
        headsign: Headsigns.normalize(row.headsign),
        route_short_name: row.route_short_name,
        departure_secs: departure_secs,
        eligible?:
          departure_secs != nil and arrival_secs != nil and departure_secs >= arrival_secs
      }
    end)
    |> Enum.filter(& &1.eligible?)
    |> Enum.group_by(& &1.differing_id)
    |> Map.new(fn {differing_id, candidates} ->
      earliest = Enum.min_by(candidates, &{&1.departure_secs, &1.trip_id})

      {differing_id,
       %{
         route_short_name: earliest.route_short_name,
         departure_secs: earliest.departure_secs,
         headsign: earliest.headsign
       }}
    end)
  end

  # One timed_pattern_stops query per distinct timing of the differing trips:
  # the lowest-position occurrence whose timing row carries a non-blank stop
  # headsign names the stop where riders see the headsign change.
  defp mid_trip_changes_by_timing(pattern, differing_trips, rows_by_id) do
    differing_trips
    |> Enum.map(&Map.fetch!(rows_by_id, &1.id).timed_pattern_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Map.new(fn timing_id -> {timing_id, mid_trip_change(pattern, timing_id)} end)
  end

  defp mid_trip_change(pattern, timing_id) do
    from(timed_stop in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on:
        occurrence.id == timed_stop.route_pattern_stop_id and
          occurrence.organization_id == ^pattern.organization_id and
          occurrence.gtfs_version_id == ^pattern.gtfs_version_id,
      join: stop in Stop,
      on:
        stop.stop_id == occurrence.stop_id and
          stop.organization_id == ^pattern.organization_id and
          stop.gtfs_version_id == ^pattern.gtfs_version_id,
      where: timed_stop.timed_pattern_id == ^timing_id,
      order_by: [asc: occurrence.position],
      select: %{stop_headsign: timed_stop.stop_headsign, stop_name: stop.stop_name}
    )
    |> Repo.all()
    |> Enum.find(&(Headsigns.normalize(&1.stop_headsign) != nil))
    |> case do
      nil -> nil
      row -> row.stop_name
    end
  end

  @doc """
  Scoped read model for the pattern editor.

  Returns the route's pattern summaries with their stop, trip and timing counts,
  their differing-headsign counts (`headsign_differ_count`: trips that do not
  follow their effective default; `headsign_typo_count`: the likely-typo share
  of them), the route's pending/custom trip counts and bounded derivation error,
  the version's eligible stop choices (only when `include_stop_choices: true`),
  and optionally one pattern's detail: its ordered occurrences, every timing
  summary and only the selected timing's rows. Nothing else is loaded, so the
  editor never accumulates the feed's stop-time vectors (AC-18).

  A missing route, or a pattern outside the loaded route/version scope, returns
  `{:error, :not_found}`; a timing that belongs to another pattern returns
  `{:error, :timing_not_found}`.
  """
  def pattern_screen(organization_id, version_id, route_id, opts \\ []) do
    with {:ok, route} <- published_route(organization_id, version_id, route_id),
         {:ok, detail} <- pattern_detail(route, organization_id, version_id, route_id, opts) do
      patterns = route_patterns_in_order(route)

      stop_counts = route_row_counts(RoutePatternStop, route)
      trip_counts = route_row_counts(Trip, route)
      timing_counts = route_row_counts(TimedPattern, route)
      trip_states = trip_state_counts(route)
      headsign_counts = headsign_counts(route, patterns)

      summaries =
        Enum.map(patterns, fn pattern ->
          counts = Map.get(headsign_counts, pattern.route_pattern_id, %{differ: 0, typo: 0})

          %{
            id: pattern.route_pattern_id,
            pattern: pattern,
            stop_count: Map.get(stop_counts, pattern.id, 0),
            trip_count: Map.get(trip_counts, pattern.route_pattern_id, 0),
            timing_count: Map.get(timing_counts, pattern.id, 0),
            headsign_differ_count: counts.differ,
            headsign_typo_count: counts.typo
          }
        end)

      {:ok,
       %{
         route: route,
         patterns: summaries,
         pending_trip_count: Map.get(trip_states, "pending", 0),
         custom_trip_count: Map.get(trip_states, "custom", 0),
         linked_trip_count: Map.get(trip_states, "linked", 0),
         derivation_error: route.pattern_derivation_error,
         detail: detail,
         stop_choices:
           if(Keyword.get(opts, :include_stop_choices, false), do: stop_choices(route), else: [])
       }}
    end
  end

  defp route_patterns_in_order(route) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^route.organization_id and
          pattern.gtfs_version_id == ^route.gtfs_version_id and
          pattern.route_id == ^route.route_id,
      order_by: [
        asc: pattern.direction_id,
        asc: pattern.route_pattern_sort_order,
        asc: pattern.route_pattern_id
      ]
    )
    |> Repo.all()
  end

  defp route_row_counts(schema, route) do
    from(row in schema,
      where:
        row.organization_id == ^route.organization_id and
          row.gtfs_version_id == ^route.gtfs_version_id,
      group_by: row.route_pattern_id,
      select: {row.route_pattern_id, count(row.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp trip_state_counts(route) do
    from(trip in Trip,
      where:
        trip.organization_id == ^route.organization_id and
          trip.gtfs_version_id == ^route.gtfs_version_id and trip.route_id == ^route.route_id,
      group_by: trip.pattern_derivation_state,
      select: {trip.pattern_derivation_state, count(trip.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Differing-headsign tallies per route_pattern_id for the pattern summaries.
  # One select for the route's trips and one for the route's timings; every trip
  # is counted once against its effective default (the headsign of the pattern's
  # timing named by timed_pattern_id when it carries one, else the pattern's).
  # The comparison runs in Elixir through the shared Headsigns rule — no SQL
  # expression compares headsigns.
  defp headsign_counts(route, patterns) do
    patterns_by_route_pattern_id = Map.new(patterns, &{&1.route_pattern_id, &1})
    timings_by_id = route_timings_by_id(route)

    from(trip in Trip,
      where:
        trip.organization_id == ^route.organization_id and
          trip.gtfs_version_id == ^route.gtfs_version_id and trip.route_id == ^route.route_id,
      select: %{
        route_pattern_id: trip.route_pattern_id,
        timed_pattern_id: trip.timed_pattern_id,
        trip_headsign: trip.trip_headsign
      }
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn trip, counts ->
      case Map.get(patterns_by_route_pattern_id, trip.route_pattern_id) do
        nil -> counts
        pattern -> add_headsign_count(counts, trip, pattern, timings_by_id)
      end
    end)
  end

  # The route's timings carry the pattern's primary key, not a route id, so the
  # route scoping joins through the pattern row.
  defp route_timings_by_id(route) do
    from(timing in TimedPattern,
      join: pattern in RoutePattern,
      on: pattern.id == timing.route_pattern_id,
      where:
        timing.organization_id == ^route.organization_id and
          timing.gtfs_version_id == ^route.gtfs_version_id and
          pattern.route_id == ^route.route_id,
      select: %{
        id: timing.id,
        route_pattern_id: timing.route_pattern_id,
        headsign: timing.headsign
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp add_headsign_count(counts, trip, pattern, timings_by_id) do
    default = trip_effective_default(trip, pattern, timings_by_id)

    if Headsigns.follows?(trip.trip_headsign, default) do
      counts
    else
      %{likely_typo: typo?} = Headsigns.difference(trip.trip_headsign, default, nil)
      typo_count = if(typo?, do: 1, else: 0)

      Map.update(counts, trip.route_pattern_id, %{differ: 1, typo: typo_count}, fn tallies ->
        %{differ: tallies.differ + 1, typo: tallies.typo + typo_count}
      end)
    end
  end

  # The trip's own timing is the timing of its pattern whose id equals
  # timed_pattern_id; a trip naming a timing outside its pattern (or none at
  # all) has no timing default and falls to the pattern headsign, like the
  # pattern scope query.
  defp trip_effective_default(trip, pattern, timings_by_id) do
    case Map.get(timings_by_id, trip.timed_pattern_id) do
      %{route_pattern_id: pattern_id, headsign: headsign} when pattern_id == pattern.id ->
        Headsigns.effective_default(headsign, pattern.headsign)

      _ ->
        Headsigns.effective_default(nil, pattern.headsign)
    end
  end

  defp pattern_detail(_route, organization_id, version_id, route_id, opts) do
    case Keyword.get(opts, :pattern_id) do
      nil -> {:ok, nil}
      pattern_id -> load_pattern_detail(organization_id, version_id, route_id, opts, pattern_id)
    end
  end

  defp load_pattern_detail(organization_id, version_id, route_id, opts, pattern_id) do
    case scoped_pattern_by_natural_id(organization_id, version_id, route_id, pattern_id) do
      %RoutePattern{} = pattern ->
        build_pattern_detail(pattern, Keyword.get(opts, :timing_id))

      nil ->
        {:error, :not_found}
    end
  end

  defp build_pattern_detail(pattern, timing_id) do
    occurrences = pattern_occurrences(pattern.id)
    timings = pattern_timings(pattern.id)
    timing_trip_counts = timing_trip_counts(pattern)
    stops = stops_by_ids(pattern, Enum.map(occurrences, & &1.stop_id))

    with {:ok, selected} <- select_detail_timing(timings, timing_id) do
      {:ok,
       %{
         pattern: pattern,
         occurrences: occurrences,
         stops: stops,
         timings:
           Enum.map(timings, fn timing ->
             %{timing: timing, trip_count: Map.get(timing_trip_counts, timing.id, 0)}
           end),
         selected_timing: selected,
         selected_timing_rows: detail_timing_rows(pattern, selected, stops),
         stop_count: length(occurrences),
         trip_count: pattern_trip_count(pattern),
         custom_trip_count: pattern_state_count(pattern, "custom"),
         linked_trip_count: pattern_state_count(pattern, "linked"),
         source_fingerprint: source_fingerprint(pattern)
       }}
    end
  end

  defp detail_timing_rows(_pattern, nil, _stops), do: []

  defp detail_timing_rows(pattern, selected, stops),
    do: selected_timing_rows(pattern.id, selected.id, stops)

  # Selecting no timing resolves to the pattern's first timing; a timing that
  # belongs to another pattern is a distinct not-found outcome so the editor can
  # refuse it without leaking the other pattern's data.
  defp select_detail_timing(timings, nil), do: {:ok, List.first(timings)}

  defp select_detail_timing(timings, timing_id) do
    case Enum.find(timings, &(&1.id == timing_id)) do
      %TimedPattern{} = timing -> {:ok, timing}
      nil -> {:error, :timing_not_found}
    end
  end

  @doc """
  Returns one pattern of the organization and version when its route is published.

  `route_pattern_id` is unique per organization and version, so this is the
  route-free lookup pattern B uses. A pattern outside the scope, or one whose
  route is missing from the version or sits on an unpublished version, is
  `{:error, :not_found}` so foreign and unpublished patterns can never leak.
  """
  @spec get_scoped_pattern(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) ::
          {:ok, RoutePattern.t()} | {:error, :not_found}
  def get_scoped_pattern(organization_id, version_id, route_pattern_id) do
    query =
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^organization_id and
            pattern.gtfs_version_id == ^version_id and
            pattern.route_pattern_id == ^route_pattern_id
      )

    with %RoutePattern{} = pattern <- Repo.one(query),
         {:ok, _route} <- published_route(organization_id, version_id, pattern.route_id) do
      {:ok, pattern}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp scoped_pattern_by_natural_id(org_id, version_id, route_id, route_pattern_id) do
    Repo.one(
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^org_id and pattern.gtfs_version_id == ^version_id and
            pattern.route_id == ^route_id and pattern.route_pattern_id == ^route_pattern_id
      )
    )
  end

  defp pattern_trip_count(pattern) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_pattern_id == ^pattern.route_pattern_id
      ),
      :count
    )
  end

  # The pattern's own custom (and linked) trip counts, so the editor explains a
  # blocked stop list with this pattern's figures rather than the route's.
  defp pattern_state_count(pattern, state) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_pattern_id == ^pattern.route_pattern_id and
            trip.pattern_derivation_state == ^state
      ),
      :count
    )
  end

  @doc """
  Reads one timing's rows for a pattern, ordered by occurrence position.

  Rows carry the occurrence identity, position and stop ID, the relative
  arrival/departure offsets (nil when the timing has no scheduled time there),
  timepoint, pickup/drop-off values and the stop headsign. Each row is joined
  to its occurrence and filtered on that occurrence's pattern, so a timing that
  belongs to another pattern returns `[]` instead of leaking its rows. `:stop`
  is not attached; callers that need the stop struct attach it from the stops
  they loaded.
  """
  @spec timing_rows(Ecto.UUID.t(), Ecto.UUID.t()) :: [
          %{
            route_pattern_stop_id: Ecto.UUID.t(),
            position: pos_integer(),
            stop_id: String.t(),
            arrival_offset: integer() | nil,
            departure_offset: integer() | nil,
            timepoint: integer() | nil,
            pickup_type: integer() | nil,
            drop_off_type: integer() | nil,
            stop_headsign: String.t() | nil
          }
        ]
  def timing_rows(pattern_id, timing_id) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id and occurrence.route_pattern_id == ^pattern_id,
      order_by: [asc: occurrence.position],
      select: %{
        route_pattern_stop_id: occurrence.id,
        position: occurrence.position,
        stop_id: occurrence.stop_id,
        arrival_offset: row.arrival_offset,
        departure_offset: row.departure_offset,
        timepoint: row.timepoint,
        pickup_type: row.pickup_type,
        drop_off_type: row.drop_off_type,
        stop_headsign: row.stop_headsign
      }
    )
    |> Repo.all()
  end

  # Only the selected timing's rows are read, and each row is bounded to its
  # occurrence position and offset values; no full stop-time vector list is
  # retained for any other timing. The editor's rows keep the attached stop
  # struct; the comparison read calls `timing_rows/2` without it.
  defp selected_timing_rows(pattern_id, timing_id, stops) do
    pattern_id
    |> timing_rows(timing_id)
    |> Enum.map(&Map.put(&1, :stop, Map.get(stops, &1.stop_id)))
  end

  defp timing_trip_counts(pattern) do
    from(trip in Trip,
      where:
        trip.organization_id == ^pattern.organization_id and
          trip.gtfs_version_id == ^pattern.gtfs_version_id and
          trip.route_pattern_id == ^pattern.route_pattern_id and
          not is_nil(trip.timed_pattern_id),
      group_by: trip.timed_pattern_id,
      select: {trip.timed_pattern_id, count(trip.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp stops_by_ids(_pattern, []), do: %{}

  defp stops_by_ids(pattern, stop_ids) do
    from(stop in Stop,
      where:
        stop.organization_id == ^pattern.organization_id and
          stop.gtfs_version_id == ^pattern.gtfs_version_id and
          stop.stop_id in ^Enum.uniq(stop_ids),
      order_by: [asc: stop.stop_name, asc: stop.stop_id]
    )
    |> Repo.all()
    |> Map.new(&{&1.stop_id, &1})
  end

  # Eligible stops are those GTFS allows in a stop sequence. The list is a
  # bounded, name-ordered choice set; targeted search remains the editor's
  # scoped query path.
  @stop_choice_limit 300

  defp stop_choices(route) do
    from(stop in Stop,
      where:
        stop.organization_id == ^route.organization_id and
          stop.gtfs_version_id == ^route.gtfs_version_id and
          (is_nil(stop.location_type) or stop.location_type == 0),
      order_by: [asc: stop.stop_name, asc: stop.stop_id],
      limit: @stop_choice_limit
    )
    |> Repo.all()
  end

  @doc """
  Scoped stop search for the pattern editor.

  Returns at most `@stop_search_limit` GTFS stops or platforms (`location_type`
  nil or 0) in the loaded organization/version scope, ordered by name then ID,
  and a `truncated?` flag when more matches exist. A blank or non-binary query
  returns no matches, so a blank field never scans the feed.
  """
  def search_stops(organization_id, version_id, query) when is_binary(query) do
    case query |> String.trim() |> search_pattern() do
      nil ->
        {:ok, %{stops: [], truncated?: false}}

      pattern ->
        rows =
          from(stop in Stop,
            where:
              stop.organization_id == ^organization_id and
                stop.gtfs_version_id == ^version_id and
                (is_nil(stop.location_type) or stop.location_type == 0) and
                (ilike(stop.stop_name, ^pattern) or ilike(stop.stop_id, ^pattern)),
            order_by: [asc: stop.stop_name, asc: stop.stop_id],
            limit: @stop_search_limit + 1
          )
          |> Repo.all()

        {matches, extra} = Enum.split(rows, @stop_search_limit)
        {:ok, %{stops: matches, truncated?: extra != []}}
    end
  end

  def search_stops(_organization_id, _version_id, _query),
    do: {:ok, %{stops: [], truncated?: false}}

  # Wraps a trimmed query as a substring pattern and neutralizes the LIKE
  # wildcards a user could otherwise type to scan the version's stops.
  defp search_pattern(""), do: nil

  defp search_pattern(query) do
    "%" <> String.replace(query, ~r/[\\%_]/, fn match -> "\\" <> match end) <> "%"
  end

  @doc """
  Read-only preview of a staged stop edit.

  Returns the proposed timing rows, estimates, start shifts and affected trip
  count for the editor to display before staff acknowledge them. It writes
  nothing and does not require acknowledgement, so the acknowledgements bound by
  `review/4` always describe values the editor actually showed.
  """
  def preview_stop_edit(pattern_id, operation, %AuditContext{} = audit_context)
      when is_binary(pattern_id) do
    Repo.transaction(fn ->
      with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context),
           {:ok, %{pattern: pattern} = loaded} <-
             get_pattern(
               audit_context.organization_id,
               audit_context.gtfs_version_id,
               route_id,
               pattern_id
             ),
           :ok <-
             validate_lifecycle_operation(pattern, operation, loaded,
               require_acknowledgements: false
             ),
           {:ok, proposal} <-
             review_proposal(pattern, operation, loaded, require_acknowledgements: false) do
        {:ok, %{proposed: proposal, impact: operation_impact(operation, loaded)}}
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_read_transaction()
  end

  def preview_stop_edit(_, _, _), do: {:error, :invalid_input}

  def create_pattern(route_id, attrs, %AuditContext{} = audit_context) when is_map(attrs) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_pattern_attrs(attrs),
         {:ok, stops} <- normalize_stop_ids(attrs),
         :ok <- validate_occurrence_list(stops) do
      run_serializable_write(fn ->
        Authorization.lock_editor!(audit_context)
        route = lock_published_route!(audit_context, route_id)
        eligible_stops = load_eligible_stops!(route, stops)

        pattern =
          %RoutePattern{}
          |> RoutePattern.changeset(
            Map.merge(values, %{
              route_pattern_id: natural_pattern_id(),
              route_id: route.route_id,
              organization_id: route.organization_id,
              gtfs_version_id: route.gtfs_version_id
            })
          )
          |> insert_or_rollback!()

        occurrences = insert_occurrences!(pattern, eligible_stops)
        timing = insert_timing!(pattern, "Timing A", nil)
        insert_timing_rows!(timing, occurrences, zero_timing_rows(length(occurrences)))

        audited_pattern = load_pattern_for_audit!(pattern.id)

        audit!(audit_context, :route_pattern, audited_pattern, "created", %{
          after: pattern_snapshot(audited_pattern)
        })

        audited_pattern
      end)
    end
  end

  def create_pattern(_, _, _), do: {:error, :invalid_input}

  def review(pattern_id, operation, source_fingerprint, %AuditContext{} = audit_context)
      when is_binary(pattern_id) do
    Repo.transaction(fn ->
      unless Keyword.get(Repo.config(), :pool) == Ecto.Adapters.SQL.Sandbox do
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
      end

      with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context),
           {:ok, %{pattern: pattern} = loaded} <-
             get_pattern(
               audit_context.organization_id,
               audit_context.gtfs_version_id,
               route_id,
               pattern_id
             ),
           true <- is_nil(source_fingerprint) or source_fingerprint == loaded.source_fingerprint,
           :ok <- validate_lifecycle_operation(pattern, operation, loaded),
           {:ok, proposal} <- review_proposal(pattern, operation, loaded) do
        impact = operation_impact(operation, loaded)

        {:ok,
         %{
           fingerprint:
             review_fingerprint(loaded.source_fingerprint, {operation, impact, proposal}),
           impact: impact,
           proposed: proposal
         }}
      else
        false -> Repo.rollback(:stale_review)
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_read_transaction()
  end

  def review(_, _, _, _), do: {:error, :invalid_input}

  defp unwrap_read_transaction({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_read_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_read_transaction({:error, reason}), do: {:error, reason}

  def apply_review(pattern_id, operation, review_fingerprint, %AuditContext{} = audit_context)
      when is_binary(pattern_id) and is_binary(review_fingerprint) do
    with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context) do
      run_serializable_write(fn ->
        Authorization.lock_editor!(audit_context)

        apply_review_transaction(
          pattern_id,
          operation,
          route_id,
          review_fingerprint,
          audit_context
        )
      end)
    end
  end

  def apply_review(_, _, _, _), do: {:error, :invalid_input}

  @type change :: %{
          id: Ecto.UUID.t(),
          trip_id: String.t(),
          from: String.t() | nil,
          to: String.t() | nil
        }

  @type undo :: %{
          default: nil | %{scope: scope(), from: String.t() | nil, to: String.t() | nil},
          trips: [change()]
        }

  @doc """
  Resets the selected trips to their current effective defaults, fenced per trip.

  `scope` is the pattern scope (`:pattern`) or one timing's scope
  (`{:timing, timing_id}`); `selections` carry the reviewed `%{id, from}` pairs
  the drawer showed, where `from` is the normalized value each trip must still
  carry. One serializable transaction locks the published route through
  `lock_published_route!/2` and the pattern through `lock_pattern!/2`, then
  validates every id against the scope (Domain rule 3): a shielded,
  foreign-pattern or cross-organization trip rolls back `:invalid_selection`
  and writes nothing. Each selected trip's target is its current effective
  default, written through `Schedules.write_trip_headsigns!/3`, whose per-trip
  fence rolls back `{:stale, [%{id, trip_id, reviewed, current}]}` when any
  trip changed since the list was loaded — unrelated stop-time edits do not
  block the reset. The returned `undo` covers exactly the written trips and
  has no default, because a reset never moves the pattern or timing headsign.
  """
  @spec reset_trip_headsigns(
          Ecto.UUID.t(),
          scope(),
          [%{id: Ecto.UUID.t(), from: String.t() | nil}],
          AuditContext.t()
        ) ::
          {:ok, %{applied: [change()], undo: undo()}}
          | {:error, {:stale, [map()]} | :invalid_selection | :not_found}
  def reset_trip_headsigns(pattern_id, scope, selections, %AuditContext{} = audit_context)
      when is_binary(pattern_id) and is_list(selections) do
    with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context) do
      run_serializable_write(fn ->
        Authorization.lock_editor!(audit_context)
        route = lock_published_route!(audit_context, route_id)
        pattern = lock_pattern!(route, pattern_id)
        reset_scope_trips!(pattern, scope, selections, audit_context)
      end)
    end
  end

  def reset_trip_headsigns(_, _, _, _), do: {:error, :invalid_input}

  @doc """
  Reverses a headsign save or reset under the recorded fences.

  `undo` is the value a successful default save returned as `headsign_undo` or
  a reset returned as `undo`. When `undo.default` is present (a default save),
  the scope's current stored default must still normalize to the recorded `to`
  — for `:pattern` the pattern row's headsign, for a timing scope the timing's
  effective default — otherwise the transaction rolls back
  `{:stale, [%{default: current}]}` and writes nothing. The recorded `from` is
  then restored on the row that owns the default, and the recorded trip values
  are swapped and rewritten through `Schedules.write_trip_headsigns!/3`, whose
  per-trip fence rolls back `{:stale, ...}` when any trip changed since the
  save. The pattern or timing audit row and every rewritten trip row share one
  new operation id; a deleted timing or unknown pattern rolls back
  `:not_found`.
  """
  @spec undo_headsign_update(Ecto.UUID.t(), undo(), AuditContext.t()) ::
          {:ok, %{applied: [change()]}} | {:error, {:stale, [map()]} | :not_found}
  def undo_headsign_update(pattern_id, undo, %AuditContext{} = audit_context)
      when is_binary(pattern_id) and is_map(undo) do
    with {:ok, route_id} <- route_id_for_pattern(pattern_id, audit_context) do
      run_serializable_write(fn ->
        Authorization.lock_editor!(audit_context)
        route = lock_published_route!(audit_context, route_id)
        pattern = lock_pattern!(route, pattern_id)
        undo_headsign_write!(pattern, undo, audit_context)
      end)
    end
  end

  def undo_headsign_update(_, _, _), do: {:error, :invalid_input}

  @doc """
  Removes one pattern's label owner, leaving the pattern itself in place.

  A label ID is never edited: the only transition a labelled pattern has is
  losing its owner, so this clears `label_pattern_id` and nothing else. The
  pattern and its route are locked the same way a reviewed apply locks them, and
  the write is serializable, so two concurrent removals cannot both observe the
  same owner. A pattern with no label is refused with `:not_labelled` rather
  than audited as a no-op, and a pattern outside the audit context's published
  route rolls back with `:not_found`.

  The owner itself is never touched: it stays a first-class pattern, and it may
  still be referenced by other children.
  """
  @spec remove_label(String.t(), Ecto.UUID.t(), AuditContext.t()) ::
          {:ok, RoutePattern.t()} | {:error, :not_found | :not_labelled}
  def remove_label(route_id, pattern_id, %AuditContext{} = audit_context)
      when is_binary(route_id) do
    run_serializable_write(fn ->
      route = lock_published_route!(audit_context, route_id)
      pattern = lock_pattern!(route, pattern_id)

      if is_nil(pattern.label_pattern_id) do
        Repo.rollback(:not_labelled)
      else
        # The column is not cast, so the clear is written directly. The
        # constraint still holds the pair: the pattern keeps its own row and
        # loses only the pointer.
        {1, nil} =
          Repo.update_all(
            from(existing in RoutePattern, where: existing.id == ^pattern.id),
            set: [label_pattern_id: nil, updated_at: DateTime.utc_now()]
          )

        updated = load_pattern_for_audit!(pattern.id)

        audit!(audit_context, :route_pattern, updated, "updated", %{
          before: %{label_pattern_id: pattern.label_pattern_id},
          after: %{label_pattern_id: nil}
        })

        updated
      end
    end)
  end

  @doc """
  Selects every route pattern of one organization and version with the natural
  ID it is exported under.

  This is the single source of the exported `trips.route_pattern_id` (rule 9):
  a pattern labelled by an owner exports the owner's `route_pattern_id`, and any
  other pattern exports its own. The join is scoped to the pattern's own
  organization and version, so a label can never resolve across a tenant, and a
  pattern with no owner keeps its stored value through `coalesce/2`.

  Each row is `%{id: uuid, route_id: String.t(), route_pattern_id: String.t(),
  exported_id: String.t()}`. The trip export joins this on
  `(route_id, route_pattern_id)`, which is unique per version, so no trip is
  ever duplicated by the join.
  """
  @spec exported_pattern_ids(Ecto.UUID.t(), Ecto.UUID.t()) :: Ecto.Query.t()
  def exported_pattern_ids(organization_id, gtfs_version_id) do
    from(pattern in RoutePattern,
      left_join: owner in RoutePattern,
      on:
        owner.id == pattern.label_pattern_id and
          owner.organization_id == pattern.organization_id and
          owner.gtfs_version_id == pattern.gtfs_version_id,
      where:
        pattern.organization_id == ^organization_id and
          pattern.gtfs_version_id == ^gtfs_version_id,
      select_merge: %{
        id: pattern.id,
        route_id: pattern.route_id,
        route_pattern_id: pattern.route_pattern_id,
        exported_id: coalesce(owner.route_pattern_id, pattern.route_pattern_id)
      }
    )
  end

  @doc false
  def audit_snapshot(%RoutePattern{} = pattern), do: pattern_snapshot(pattern)

  @doc false
  def audit_timing_snapshot(%TimedPattern{} = timing) do
    %{
      id: timing.id,
      route_pattern_id: timing.route_pattern_id,
      name: timing.name,
      headsign: timing.headsign,
      derivation_key: timing.derivation_key,
      rows:
        Enum.map(timing_rows(timing.id), fn row ->
          occurrence = Repo.get!(RoutePatternStop, row.route_pattern_stop_id)

          Map.merge(timing_row_attrs(row), %{
            occurrence_id: occurrence.id,
            position: occurrence.position
          })
        end)
    }
  end

  defp apply_lifecycle_operation!(_route, pattern, {:details, attrs, selection}, audit_context) do
    apply_details_operation!(pattern, attrs, selection, audit_context)
  end

  defp apply_lifecycle_operation!(_route, pattern, {:details, attrs}, audit_context) do
    apply_details_operation!(pattern, attrs, empty_selection(), audit_context)
  end

  defp apply_lifecycle_operation!(
         _route,
         pattern,
         {:stops, entries, reviewed_values},
         audit_context
       ) do
    case prepare_stop_edit(pattern, entries, reviewed_values) do
      {:ok, edit} -> apply_stop_edit!(pattern, edit, audit_context)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(
         _route,
         pattern,
         {:timing, timing_id, attrs, selection},
         audit_context
       ) do
    apply_timing_operation!(pattern, timing_id, attrs, selection, audit_context)
  end

  defp apply_lifecycle_operation!(_route, pattern, {:timing, timing_id, attrs}, audit_context) do
    apply_timing_operation!(pattern, timing_id, attrs, empty_selection(), audit_context)
  end

  defp apply_lifecycle_operation!(_route, pattern, {:add_timing, attrs}, audit_context) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values),
         {:ok, source} <- copy_source_timing(pattern, attrs) do
      name = Map.get(values, :name) || next_timing_name(pattern.id)
      timing = insert_timing!(pattern, name, Map.get(values, :headsign))
      occurrences = pattern_occurrences(pattern.id)

      if source,
        do: copy_timing_rows!(timing, occurrences, timing_rows(source.id)),
        else: insert_timing_rows!(timing, occurrences, zero_timing_rows(length(occurrences)))

      audit!(
        audit_context,
        :timed_pattern,
        timing,
        "created",
        timing_audit_attrs(pattern, timing, %{after: audit_timing_snapshot(timing)})
      )

      %{pattern: pattern, trips_updated: 0}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_lifecycle_operation!(route, pattern, {:delete_timing, timing_id}, audit_context) do
    timing = scoped_timing(pattern, timing_id)

    cond do
      is_nil(timing) ->
        Repo.rollback(:not_found)

      timing_count(pattern.id) <= 1 ->
        Repo.rollback(:last_timing)

      timing_used?(route, timing) ->
        Repo.rollback(:timing_in_use)

      true ->
        audit_pattern = pattern

        audit!(
          audit_context,
          :timed_pattern,
          timing,
          "deleted",
          timing_audit_attrs(audit_pattern, timing, %{})
        )

        Repo.delete!(timing)
        %{pattern: pattern, trips_updated: 0}
    end
  end

  defp apply_lifecycle_operation!(_route, pattern, :copy, audit_context) do
    copied =
      %RoutePattern{
        organization_id: pattern.organization_id,
        gtfs_version_id: pattern.gtfs_version_id,
        route_id: pattern.route_id,
        direction_id: pattern.direction_id
      }
      |> RoutePattern.changeset(%{
        route_pattern_id: natural_pattern_id(),
        route_pattern_name: copy_name(pattern.route_pattern_name),
        route_pattern_time_desc: pattern.route_pattern_time_desc,
        route_pattern_typicality: pattern.route_pattern_typicality,
        headsign: pattern.headsign,
        direction_id: pattern.direction_id,
        representative_trip_id: nil,
        derivation_key: nil,
        active: true
      })
      |> insert_or_rollback!()

    copied_occurrences =
      pattern
      |> pattern_occurrences()
      |> Enum.map(fn occurrence ->
        insert_occurrence!(copied, occurrence.stop_id, occurrence.position)
      end)

    pattern
    |> pattern_timings()
    |> Enum.each(fn timing ->
      copied_timing = insert_timing!(copied, timing.name, timing.headsign)
      rows = timing_rows(timing.id)
      copy_timing_rows!(copied_timing, copied_occurrences, rows)
    end)

    Alignments.copy_pattern_alignment!(
      pattern,
      copied,
      pattern_occurrences(pattern),
      copied_occurrences,
      audit_context
    )

    copied = load_pattern_for_audit!(copied.id)
    audit!(audit_context, :route_pattern, copied, "created", %{after: pattern_snapshot(copied)})
    %{pattern: copied, trips_updated: 0}
  end

  defp apply_lifecycle_operation!(route, pattern, :delete, audit_context) do
    cond do
      # A label owner is still a live label: deleting it would leave its children
      # pointing at a row that no longer exists, so the children are unlabelled
      # before it can go.
      pattern_labelled?(pattern) ->
        Repo.rollback(:label_in_use)

      pattern_used?(route, pattern) ->
        Repo.rollback(:pattern_in_use)

      true ->
        snapshot = pattern_snapshot(load_pattern_for_audit!(pattern.id))
        audit!(audit_context, :route_pattern, pattern, "deleted", %{before: snapshot})
        _children = delete_pattern_children!([pattern.id])
        Alignments.delete_owned_shape!(pattern)
        Repo.delete!(pattern)
        %{pattern: nil, trips_updated: 0}
    end
  end

  defp apply_lifecycle_operation!(_route, _pattern, _operation, _audit_context),
    do: Repo.rollback(:invalid_operation)

  # The pattern update keeps its existing shape; a non-empty selection writes
  # the selected trips through the fenced writer after the pattern row, and the
  # audit row then carries the shared operation id and the total affected trips.
  defp apply_details_operation!(pattern, attrs, selection, audit_context) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, attrs} <- normalize_allowed_attrs(attrs, @pattern_fields),
         :ok <- reject_labelled_direction_change(pattern, attrs),
         :ok <- validate_noop_or_pattern(pattern, attrs) do
      attrs = RoutePattern.changeset(pattern, attrs).changes
      old_default = Headsigns.normalize(pattern.headsign)
      new_default = details_new_default(pattern, attrs)
      changes = headsign_changes(pattern, :pattern, selection, new_default)

      if same_values?(pattern, attrs) do
        {written, _operation_id} = write_selection!(changes, audit_context)

        %{
          pattern: pattern,
          trips_updated: 0,
          headsign_undo: headsign_undo(:pattern, old_default, new_default, written)
        }
      else
        trips_updated = update_direction_trips(pattern, attrs)

        updated = pattern |> RoutePattern.changeset(attrs) |> update_or_rollback!()
        maybe_clear_pattern_signature!(pattern, attrs)

        {written, operation_id} = write_selection!(changes, audit_context)

        audit_attrs =
          attrs
          |> Map.put(:affected_trips, trips_updated + length(written))
          |> put_operation_id(operation_id)

        audit!(audit_context, :route_pattern, pattern, "updated", audit_attrs)

        %{
          pattern: load_pattern_for_audit!(updated.id),
          trips_updated: trips_updated,
          headsign_undo: headsign_undo(:pattern, old_default, new_default, written)
        }
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp apply_timing_operation!(pattern, timing_id, attrs, selection, audit_context) do
    rows_input = Map.get(attrs, :rows, Map.get(attrs, "rows"))

    with {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         %TimedPattern{} = timing <- scoped_timing(pattern, timing_id),
         :ok <- validate_timing_attrs(values),
         {:ok, rows} <- validate_timing_rows(pattern, timing, rows_input) do
      values = TimedPattern.changeset(timing, values).changes
      before = audit_timing_snapshot(timing)
      old_default = timing_effective_default(pattern, timing, %{})
      new_default = timing_effective_default(pattern, timing, values)
      changes = headsign_changes(pattern, {:timing, timing.id}, selection, new_default)

      if same_values?(timing, values) and timing_rows_unchanged?(timing, rows) do
        {written, _operation_id} = write_selection!(changes, audit_context)

        %{
          pattern: pattern,
          trips_updated: 0,
          headsign_undo: headsign_undo({:timing, timing.id}, old_default, new_default, written)
        }
      else
        apply_timing_edit!(pattern, timing, values, rows, before, changes, audit_context)
      end
    else
      nil -> Repo.rollback(:not_found)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A new timing either starts blank or copies another timing of the same
  # pattern; the source is resolved from the loaded pattern, never trusted as a
  # browser-supplied identity.
  defp copy_source_timing(pattern, attrs) do
    case map_value(attrs, :source_timing_id) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      source_id ->
        case scoped_timing(pattern, source_id) do
          %TimedPattern{} = source -> {:ok, source}
          nil -> {:error, :not_found}
        end
    end
  end

  defp update_direction_trips(pattern, attrs) do
    case Map.fetch(attrs, :direction_id) do
      {:ok, direction_id} -> update_trip_direction!(pattern, direction_id)
      :error -> 0
    end
  end

  defp apply_stop_edit!(pattern, %{noop?: true}, _audit_context),
    do: %{pattern: pattern, trips_updated: 0}

  defp apply_stop_edit!(pattern, edit, audit_context) do
    # The before snapshot has to be read before any occurrence/timing row is
    # written; querying it after persistence would record the post-mutation
    # structure as its own predecessor.
    before = pattern_snapshot(pattern)
    trips_updated = persist_stop_edit!(pattern, edit)
    clear_structure_signatures!(pattern)
    after_pattern = load_pattern_for_audit!(pattern.id)

    audit!(audit_context, :route_pattern, after_pattern, "updated", %{
      before: before,
      after: pattern_snapshot(after_pattern),
      affected_trips: trips_updated
    })

    %{pattern: after_pattern, trips_updated: trips_updated}
  end

  defp apply_timing_edit!(pattern, timing, values, rows, before, changes, audit_context) do
    trips_updated = if rows, do: persist_timing_edit!(pattern, timing, rows), else: 0
    if rows, do: clear_timing_signature!(timing)
    if values != %{}, do: timing |> TimedPattern.changeset(values) |> update_or_rollback!()
    after_snapshot = audit_timing_snapshot(Repo.get!(TimedPattern, timing.id))

    {written, operation_id} = write_selection!(changes, audit_context)

    audit_attrs =
      timing_audit_attrs(
        pattern,
        timing,
        Map.merge(values, %{
          before: before,
          after: after_snapshot,
          affected_trips: trips_updated + length(written)
        })
      )
      |> put_operation_id(operation_id)

    audit!(audit_context, :timed_pattern, timing, "updated", audit_attrs)

    undo =
      headsign_undo(
        {:timing, timing.id},
        timing_effective_default(pattern, timing, %{}),
        timing_effective_default(pattern, timing, values),
        written
      )

    %{pattern: pattern, trips_updated: trips_updated, headsign_undo: undo}
  end

  # FK-safe order: timing rows reference both timings and occurrences, so they
  # leave first. The set-based list form is shared by single pattern delete and
  # the reviewed route cascade (R5); callers own the pattern row deletion.
  defp delete_pattern_children!(pattern_ids) when is_list(pattern_ids) do
    timing_ids =
      from(timing in TimedPattern,
        where: timing.route_pattern_id in ^pattern_ids,
        select: timing.id
      )
      |> Repo.all()

    {timing_rows, nil} =
      Repo.delete_all(from(row in TimedPatternStop, where: row.timed_pattern_id in ^timing_ids))

    {timings, nil} =
      Repo.delete_all(from(timing in TimedPattern, where: timing.id in ^timing_ids))

    {occurrences, nil} =
      Repo.delete_all(
        from(occurrence in RoutePatternStop, where: occurrence.route_pattern_id in ^pattern_ids)
      )

    %{
      timed_pattern_stops: timing_rows,
      timed_patterns: timings,
      pattern_stops: occurrences
    }
  end

  # R5 M1's bounded retry convention: a serialization failure (40001) or
  # deadlock (40P01) reruns the whole transaction closure, at most three times,
  # then returns `:busy`. Every other failure is returned unchanged.
  defp run_serializable_write(transaction, attempts \\ 3) do
    case run_apply_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_conflict, _error} ->
        retry_serializable_write(transaction, attempts)

      {:error, reason} ->
        retry_serializable_write_error(reason, transaction, attempts)
    end
  end

  defp retry_serializable_write(transaction, attempts) when attempts > 1,
    do: run_serializable_write(transaction, attempts - 1)

  defp retry_serializable_write(_transaction, _attempts), do: {:error, :busy}

  defp retry_serializable_write_error(reason, transaction, attempts) do
    if retryable_conflict?(reason),
      do: retry_serializable_write(transaction, attempts),
      else: {:error, reason}
  end

  defp run_apply_transaction(transaction) do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    ).run(transaction)
  rescue
    error in Postgrex.Error ->
      if retryable_conflict?(error),
        do: {:retryable_conflict, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp retryable_conflict?(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :serialization_failure,
              "40001",
              :deadlock_detected,
              "40P01"
            ],
       do: true

  defp retryable_conflict?(_), do: false

  defp apply_review_transaction(pattern_id, operation, route_id, fingerprint, audit_context) do
    route = lock_published_route!(audit_context, route_id)
    pattern = lock_pattern!(route, pattern_id)
    lock_trips_for_operation!(route, pattern, operation)
    loaded_view = load_locked_pattern!(route, pattern, audit_context)
    verify_review_fingerprint!(loaded_view, operation, fingerprint)
    apply_lifecycle_operation!(route, loaded_view.pattern, operation, audit_context)
  end

  defp lock_trips_for_operation!(route, pattern, operation) do
    if trips_lock_required?(operation) do
      lock_pattern_trips!(route, pattern)

      # A details direction change on an owner also writes the children's
      # trips, so they are locked with the owner's.
      if direction_change?(operation) do
        Enum.each(label_children(pattern), &lock_pattern_trips!(route, &1))
      end
    end
  end

  defp direction_change?({:details, attrs}) when is_map(attrs),
    do: Map.has_key?(attrs, :direction_id) or Map.has_key?(attrs, "direction_id")

  defp direction_change?(_operation), do: false

  defp load_locked_pattern!(route, pattern, audit_context) do
    case get_pattern(
           audit_context.organization_id,
           audit_context.gtfs_version_id,
           route.route_id,
           pattern.id
         ) do
      {:ok, loaded_view} -> loaded_view
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp verify_review_fingerprint!(loaded_view, operation, fingerprint) do
    reviewed_source = fingerprint |> String.split(":", parts: 2) |> hd()

    unless secure_equal?(reviewed_source, loaded_view.source_fingerprint),
      do: Repo.rollback(:stale_review)

    pattern = loaded_view.pattern
    impact = operation_impact(operation, %{pattern: pattern})

    with :ok <- validate_lifecycle_operation(pattern, operation, loaded_view),
         {:ok, proposal} <- review_proposal(pattern, operation, loaded_view) do
      current = review_fingerprint(loaded_view.source_fingerprint, {operation, impact, proposal})
      if secure_equal?(fingerprint, current), do: :ok, else: Repo.rollback(:stale_review)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The 2/3-tuple operations mean an empty headsign selection; the 3/4-tuple
  # forms carry `%{headsign_trip_ids: ids}` and every id is validated against
  # the new value's scope before anything is proposed or written.
  defp validate_lifecycle_operation(pattern, operation, loaded, opts \\ []) do
    {base_operation, selection} = split_operation(operation)

    with :ok <- validate_lifecycle_base_operation(pattern, base_operation, loaded, opts) do
      validate_headsign_selection(pattern, base_operation, selection)
    end
  end

  defp validate_lifecycle_base_operation(
         pattern,
         {:stops, entries, reviewed_values},
         loaded,
         opts
       ) do
    case prepare_stop_edit(pattern, entries, reviewed_values, loaded, opts) do
      {:ok, _edit} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_lifecycle_base_operation(pattern, {:details, attrs}, _loaded, _opts) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @pattern_fields),
         :ok <- reject_labelled_direction_change(pattern, values) do
      validate_noop_or_pattern(pattern, values)
    end
  end

  defp validate_lifecycle_base_operation(pattern, {:timing, timing_id, attrs}, _loaded, _opts) do
    with %TimedPattern{} <- scoped_timing(pattern, timing_id),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values),
         {:ok, _rows} <-
           validate_timing_rows(pattern, scoped_timing(pattern, timing_id), Map.get(attrs, :rows)) do
      :ok
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp validate_lifecycle_base_operation(pattern, {:add_timing, attrs}, _loaded, _opts) do
    with :ok <- reject_forged_linkage(attrs),
         {:ok, values} <- normalize_allowed_attrs(attrs, @timing_fields),
         :ok <- validate_timing_attrs(values) do
      case copy_source_timing(pattern, attrs) do
        {:ok, _source} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_lifecycle_base_operation(pattern, {:delete_timing, timing_id}, _loaded, _opts) do
    timing = scoped_timing(pattern, timing_id)

    cond do
      is_nil(timing) -> {:error, :not_found}
      timing_count(pattern.id) <= 1 -> {:error, :last_timing}
      timing_used?(nil, timing) -> {:error, :timing_in_use}
      true -> :ok
    end
  end

  defp validate_lifecycle_base_operation(pattern, :copy, _loaded, _opts) do
    if is_nil(pattern), do: {:error, :not_found}, else: :ok
  end

  defp validate_lifecycle_base_operation(pattern, :delete, _loaded, _opts) do
    if pattern_used?(nil, pattern), do: {:error, :pattern_in_use}, else: :ok
  end

  defp validate_lifecycle_base_operation(_pattern, _, _, _), do: {:error, :invalid_operation}

  # A labelled child always shares its owner's direction (rule 8), so the
  # direction is the owner's to move: the owner cascades the change to its
  # children and their trips, and a child refuses it outright. Only a real
  # change is refused, so saving a child without touching its direction still
  # behaves as before.
  defp reject_labelled_direction_change(pattern, attrs) do
    changes = RoutePattern.changeset(pattern, attrs).changes

    if is_nil(pattern.label_pattern_id) or not Map.has_key?(changes, :direction_id) do
      :ok
    else
      {:error, :labelled_direction}
    end
  end

  defp operation_impact({:delete_timing, timing_id}, %{pattern: pattern}) do
    %{trips_affected: count_timing_trips(pattern, timing_id)}
  end

  defp operation_impact(:delete, %{pattern: pattern}),
    do: %{trips_affected: count_pattern_trips(pattern)}

  defp operation_impact({:stops, _entries, _values}, %{pattern: pattern}),
    do: %{trips_affected: count_pattern_trips(pattern)}

  defp operation_impact({:timing, timing_id, attrs, selection}, %{pattern: pattern}),
    do: timing_impact(pattern, timing_id, attrs, selection)

  defp operation_impact({:timing, timing_id, attrs}, %{pattern: pattern}),
    do: timing_impact(pattern, timing_id, attrs, empty_selection())

  defp operation_impact({:details, attrs, selection}, %{pattern: pattern}) when is_map(attrs),
    do: details_impact(pattern, attrs, selection)

  defp operation_impact({:details, attrs}, %{pattern: pattern}) when is_map(attrs),
    do: details_impact(pattern, attrs, empty_selection())

  defp operation_impact(_, _), do: %{trips_affected: 0}

  # A timing edit only touches trips through its rows; a headsign-only save has
  # no rows and re-materializes nothing, so it affects no existing trips.
  defp timing_impact(pattern, timing_id, attrs, selection) do
    %{
      trips_affected:
        if(map_value(attrs, :rows), do: count_timing_trips(pattern, timing_id), else: 0),
      headsign_trips: length(selected_scope_trips(pattern, {:timing, timing_id}, selection))
    }
  end

  # `trips_affected` keeps its existing meaning (the direction dialog opens for
  # it alone); headsign trip changes are reported only in `headsign_trips`.
  defp details_impact(pattern, attrs, selection) do
    changes = RoutePattern.changeset(pattern, attrs).changes

    direction_change? = Map.has_key?(changes, :direction_id)

    # A direction change on a label owner moves the children with it, so the
    # review names them and counts the trips that follow them.
    children = if direction_change?, do: label_children(pattern), else: []

    trips_affected =
      if direction_change? do
        count_pattern_trips(pattern) + Enum.sum(Enum.map(children, &count_pattern_trips/1))
      else
        0
      end

    %{
      trips_affected: trips_affected,
      children:
        Enum.map(children, fn child ->
          %{
            route_pattern_id: child.route_pattern_id,
            route_pattern_name: child.route_pattern_name,
            trips_affected: count_pattern_trips(child)
          }
        end),
      headsign_trips: length(selected_scope_trips(pattern, :pattern, selection))
    }
  end

  defp operation_proposal({:details, attrs}, _pattern), do: attrs
  defp operation_proposal({:timing, _id, attrs}, _pattern), do: attrs
  defp operation_proposal({:add_timing, attrs}, _pattern), do: attrs

  defp operation_proposal({:stops, entries, values}, pattern),
    do: %{occurrences: entries, timings: values, pattern_id: pattern.id}

  defp operation_proposal(operation, _pattern), do: operation

  defp review_proposal(pattern, operation, loaded, opts \\ [])

  defp review_proposal(pattern, {:stops, entries, reviewed_values}, loaded, opts) do
    with {:ok, edit} <- prepare_stop_edit(pattern, entries, reviewed_values, loaded, opts) do
      {:ok,
       %{
         occurrences: Enum.map(edit.new_occurrences, &occurrence_proposal/1),
         removed: edit.removed,
         added: edit.added,
         timing_rows: edit.timing_rows,
         start_shifts: edit.start_shifts,
         estimates: edit.estimates
       }}
    end
  end

  defp review_proposal(pattern, {:timing, _id, _attrs, _selection} = operation, _loaded, _opts) do
    {{:timing, timing_id, attrs}, selection} = split_operation(operation)
    {:ok, timing_proposal(pattern, timing_id, attrs, selection)}
  end

  defp review_proposal(pattern, {:timing, timing_id, attrs}, _loaded, _opts) do
    {:ok, timing_proposal(pattern, timing_id, attrs, empty_selection())}
  end

  defp review_proposal(pattern, {:details, _attrs, _selection} = operation, _loaded, _opts) do
    {{:details, attrs}, selection} = split_operation(operation)
    {:ok, details_proposal(pattern, attrs, selection)}
  end

  defp review_proposal(pattern, {:details, attrs}, _loaded, _opts) do
    {:ok, details_proposal(pattern, attrs, empty_selection())}
  end

  defp review_proposal(_pattern, operation, _loaded, _opts),
    do: {:ok, operation_proposal(operation, nil)}

  defp timing_proposal(pattern, timing_id, attrs, selection) do
    timing = scoped_timing(pattern, timing_id)

    with {:ok, rows} <- validate_timing_rows(pattern, timing, map_value(attrs, :rows)) do
      to = timing_new_default(pattern, timing, attrs)
      changes = headsign_changes(pattern, {:timing, timing_id}, selection, to)

      if rows do
        {:ok, %{attrs: Map.drop(attrs, [:rows, "rows"]), rows: rows, headsign_changes: changes}}
      else
        {:ok, Map.put(attrs, :headsign_changes, changes)}
      end
    end
  end

  defp details_proposal(pattern, attrs, selection) do
    to = details_new_default(pattern, attrs)
    Map.put(attrs, :headsign_changes, headsign_changes(pattern, :pattern, selection, to))
  end

  # Existing 2/3-tuple operations mean an empty headsign selection; the
  # 3/4-tuple forms carry `%{headsign_trip_ids: ids}` (the review/apply
  # contract for selection-aware details and timing saves).
  defp split_operation({:details, attrs}), do: {{:details, attrs}, empty_selection()}
  defp split_operation({:details, attrs, selection}), do: {{:details, attrs}, selection}

  defp split_operation({:timing, timing_id, attrs}),
    do: {{:timing, timing_id, attrs}, empty_selection()}

  defp split_operation({:timing, timing_id, attrs, selection}),
    do: {{:timing, timing_id, attrs}, selection}

  defp split_operation(operation), do: {operation, empty_selection()}

  defp empty_selection, do: %{headsign_trip_ids: []}

  defp selection_trip_ids(%{} = selection) do
    case map_value(selection, :headsign_trip_ids) do
      ids when is_list(ids) -> {:ok, ids}
      _ -> :error
    end
  end

  defp selection_trip_ids(_), do: :error

  # Client-supplied ids are cast to UUIDs before any query touches them, so a
  # malformed or non-UUID id fails closed as `:invalid_selection` instead of
  # reaching the database driver. Unreachable after `validate_headsign_selection/3`;
  # kept as defense in depth for the impact/proposal/apply call sites.
  defp headsign_selection_ids(selection) do
    case selection_trip_ids(selection) do
      {:ok, ids} -> cast_selection_ids(ids)
      :error -> Repo.rollback(:invalid_selection)
    end
  end

  defp cast_selection_ids(ids) do
    casts = Enum.map(ids, &Ecto.UUID.cast/1)

    if Enum.all?(casts, &match?({:ok, _}, &1)) do
      Enum.map(casts, fn {:ok, id} -> id end)
    else
      Repo.rollback(:invalid_selection)
    end
  end

  # Every id must name a trip in the scope of the *new* value (Domain rule 3):
  # pattern scope for details saves (shielded trips are out of scope), timing
  # scope for timing saves. One out-of-scope id rejects the whole operation.
  defp validate_headsign_selection(pattern, base_operation, selection) do
    case selection_trip_ids(selection) do
      {:ok, []} -> :ok
      {:ok, ids} -> selection_in_scope?(pattern, base_operation, ids)
      :error -> {:error, :invalid_selection}
    end
  end

  defp selection_in_scope?(pattern, {:details, _attrs}, ids) do
    selection_in_scope?(pattern, pattern_scope_query(pattern, carrying_timing_ids(pattern)), ids)
  end

  defp selection_in_scope?(pattern, {:timing, timing_id, _attrs}, ids) do
    selection_in_scope?(pattern, timing_scope_query(pattern, timing_id), ids)
  end

  # `split_operation/1` only pairs non-empty selections with details and timing
  # operations, so the scope query clause covers every reachable call.
  defp selection_in_scope?(_pattern, scope_query, ids) do
    ids = Enum.uniq(ids)

    with true <- Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))),
         found = from(trip in scope_query, where: trip.id in ^ids, select: trip.id) |> Repo.all(),
         true <- length(found) == length(ids) do
      :ok
    else
      _ -> {:error, :invalid_selection}
    end
  end

  # Timings with their own headsign shield their trips from the pattern scope,
  # the same carrying rule the headsign usage read model applies.
  defp carrying_timing_ids(pattern) do
    pattern.id
    |> pattern_timings()
    |> Enum.filter(&(Headsigns.normalize(&1.headsign) != nil))
    |> MapSet.new(& &1.id)
  end

  defp scope_query_for(pattern, :pattern),
    do: pattern_scope_query(pattern, carrying_timing_ids(pattern))

  defp scope_query_for(pattern, {:timing, timing_id}), do: timing_scope_query(pattern, timing_id)

  defp selected_scope_trips(_pattern, _scope, %{headsign_trip_ids: []}), do: []

  defp selected_scope_trips(pattern, scope, selection) do
    case headsign_selection_ids(selection) do
      [] ->
        []

      ids ->
        from(trip in scope_query_for(pattern, scope),
          where: trip.id in ^ids,
          select: %{id: trip.id, trip_id: trip.trip_id, trip_headsign: trip.trip_headsign},
          order_by: [asc: trip.id]
        )
        |> Repo.all()
    end
  end

  # One reviewed change per selected in-scope trip: `from` the normalized
  # stored value the writer fences on, `to` the new effective default.
  defp headsign_changes(pattern, scope, selection, to) do
    selected_scope_trips(pattern, scope, selection)
    |> Enum.map(fn trip ->
      %{id: trip.id, trip_id: trip.trip_id, from: Headsigns.normalize(trip.trip_headsign), to: to}
    end)
  end

  # The effective default the pattern-scope selection receives: the new pattern
  # headsign (in-scope trips carry no own timing headsign).
  defp details_new_default(pattern, attrs) do
    values = RoutePattern.changeset(pattern, attrs).changes
    Headsigns.normalize(Map.get(values, :headsign, pattern.headsign))
  end

  defp timing_new_default(_pattern, nil, attrs),
    do: Headsigns.normalize(map_value(attrs, :headsign))

  defp timing_new_default(pattern, %TimedPattern{} = timing, attrs) do
    values = TimedPattern.changeset(timing, attrs).changes
    Headsigns.effective_default(Map.get(values, :headsign, timing.headsign), pattern.headsign)
  end

  # The scope's effective default after the save, for a timing whose headsign
  # would become `values[:headsign]` (absent means unchanged).
  defp timing_effective_default(pattern, timing, values) do
    Headsigns.effective_default(Map.get(values, :headsign, timing.headsign), pattern.headsign)
  end

  # An empty selection writes nothing and needs no operation id; a non-empty
  # one writes through the fenced writer under a fresh shared operation id.
  defp write_selection!([], _audit_context), do: {[], nil}

  defp write_selection!(changes, audit_context) do
    operation_id = Ecto.UUID.generate()
    {Schedules.write_trip_headsigns!(changes, operation_id, audit_context), operation_id}
  end

  # Undo covers exactly what the save changed headsign-wise: the default when
  # it moved, and the trips the writer actually wrote. Nothing moved means no undo.
  defp headsign_undo(scope, old_default, new_default, written) do
    default =
      if old_default == new_default,
        do: nil,
        else: %{scope: scope, from: old_default, to: new_default}

    if default == nil and written == [] do
      nil
    else
      %{default: default, trips: written}
    end
  end

  # -- Fenced reset and undo (Domain rules 6 and 9) ---------------------------

  # The reset's scope read re-applies Domain rule 3 through the shared scope
  # queries, so a shielded pattern-scope trip is as absent as a foreign one and
  # a missing id fails closed as `:invalid_selection`.
  defp reset_scope_trips!(pattern, scope, selections, audit_context) do
    case reset_scope_query(pattern, scope) do
      {:ok, scope_query} ->
        reset_selected_trips!(pattern, scope_query, selections, audit_context)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp reset_selected_trips!(pattern, scope_query, selections, audit_context) do
    ids = selections |> Enum.map(&map_value(&1, :id)) |> cast_selection_ids() |> Enum.uniq()
    trips_by_id = reset_scope_trips(scope_query, ids)

    if Enum.all?(ids, &Map.has_key?(trips_by_id, &1)) do
      timing_headsigns = timing_headsigns_by_id(pattern)
      changes = Enum.map(selections, &reset_change(&1, trips_by_id, pattern, timing_headsigns))
      {written, _operation_id} = write_selection!(changes, audit_context)

      %{applied: written, undo: %{default: nil, trips: written}}
    else
      Repo.rollback(:invalid_selection)
    end
  end

  defp reset_scope_query(pattern, :pattern), do: {:ok, scope_query_for(pattern, :pattern)}

  defp reset_scope_query(pattern, {:timing, timing_id}) do
    if Enum.any?(pattern_timings(pattern.id), &(&1.id == timing_id)),
      do: {:ok, timing_scope_query(pattern, timing_id)},
      else: {:error, :not_found}
  end

  defp reset_scope_query(_pattern, _scope), do: {:error, :not_found}

  defp reset_scope_trips(scope_query, ids) do
    from(trip in scope_query,
      where: trip.id in ^ids,
      select: %{
        id: trip.id,
        trip_id: trip.trip_id,
        trip_headsign: trip.trip_headsign,
        timed_pattern_id: trip.timed_pattern_id
      }
    )
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # One timings read per reset; a trip whose `timed_pattern_id` names no timing
  # of this pattern has no timing default (Domain rule 2), so it targets the
  # pattern headsign.
  defp timing_headsigns_by_id(pattern) do
    pattern.id
    |> pattern_timings()
    |> Map.new(&{&1.id, &1.headsign})
  end

  # Every selected trip returns to its current effective default; `from` is the
  # reviewed value the writer fences on.
  defp reset_change(selection, trips_by_id, pattern, timing_headsigns) do
    trip = Map.fetch!(trips_by_id, map_value(selection, :id))

    %{
      id: trip.id,
      trip_id: trip.trip_id,
      from: Headsigns.normalize(map_value(selection, :from)),
      to:
        Headsigns.effective_default(
          Map.get(timing_headsigns, trip.timed_pattern_id),
          pattern.headsign
        )
    }
  end

  # Fences and restores the recorded default first (when present), then swaps
  # and rewrites the recorded trip values under one fresh operation id. The
  # default's audit row is written after the trip rewrite like every other
  # audited pattern/timing save, so `affected_trips` is the exact count under
  # the shared operation id.
  defp undo_headsign_write!(pattern, undo, audit_context) do
    operation_id = Ecto.UUID.generate()
    default = map_value(undo, :default)
    swapped = swapped_trip_changes(map_value(undo, :trips))

    audited_default = if default, do: undo_default_headsign!(pattern, default)

    written = Schedules.write_trip_headsigns!(swapped, operation_id, audit_context)

    if audited_default do
      audit_undo_default!(
        audited_default.entity,
        audited_default.type,
        audited_default.restored,
        length(written),
        operation_id,
        audit_context
      )
    end

    %{applied: written}
  end

  # The default fence (Domain rule 9): the scope's current stored default must
  # still normalize to the recorded `to`, or nothing is written and the stale
  # entry names the current default. Restoring the recorded `from` writes the
  # row that owns the default — the pattern itself, or the timing cleared back
  # to the pattern's value when `from` is what the pattern still carries. Every
  # comparison goes through `Headsigns` (INV-2).
  defp undo_default_headsign!(pattern, default) do
    to = Headsigns.normalize(map_value(default, :to))
    from = Headsigns.normalize(map_value(default, :from))

    case map_value(default, :scope) do
      :pattern -> undo_pattern_default!(pattern, from, to)
      {:timing, timing_id} -> undo_timing_default!(pattern, timing_id, from, to)
      _ -> Repo.rollback(:invalid_input)
    end
  end

  defp undo_pattern_default!(pattern, from, to) do
    current = Headsigns.normalize(pattern.headsign)

    if current == to do
      pattern
      |> RoutePattern.changeset(%{headsign: from})
      |> update_or_rollback!()

      %{type: :route_pattern, entity: pattern, restored: from}
    else
      Repo.rollback({:stale, [%{default: current}]})
    end
  end

  defp undo_timing_default!(pattern, timing_id, from, to) do
    timing = undo_timing!(pattern, timing_id)
    current = Headsigns.effective_default(timing.headsign, pattern.headsign)

    if current == to do
      # The timing owns the default only when `from` is not what the pattern
      # still carries; restoring the pattern's value means clearing the timing's
      # own headsign so the scope follows the pattern again.
      restored = if Headsigns.normalize(pattern.headsign) == from, do: nil, else: from

      timing
      |> TimedPattern.changeset(%{headsign: restored})
      |> update_or_rollback!()

      %{type: :timed_pattern, entity: timing, restored: restored}
    else
      Repo.rollback({:stale, [%{default: current}]})
    end
  end

  defp undo_timing!(pattern, timing_id) do
    # The preload matches `scoped_timing/2`: restoring the timing's own
    # headsign runs its changeset, whose scope validation reads the loaded
    # parent pattern.
    case Repo.one(
           from(timing in TimedPattern,
             where: timing.route_pattern_id == ^pattern.id and timing.id == ^timing_id,
             preload: [:route_pattern]
           )
         ) do
      %TimedPattern{} = timing -> timing
      nil -> Repo.rollback(:not_found)
    end
  end

  # The restored row keeps the exact shape of the save it reverses: the
  # operation id top-level and the affected trip count (Domain rule 8).
  defp audit_undo_default!(entity, type, restored, affected, operation_id, audit_context) do
    audit!(audit_context, type, entity, "updated", %{
      headsign: restored,
      affected_trips: affected,
      operation_id: operation_id
    })
  end

  # The recorded values swap sides; both were normalized when the save wrote
  # them, and re-normalizing keeps a tampered assign from reaching the writer's
  # fence as a non-normalized value.
  defp swapped_trip_changes(trips) when is_list(trips) do
    Enum.map(trips, fn trip ->
      %{
        id: map_value(trip, :id),
        trip_id: map_value(trip, :trip_id),
        from: Headsigns.normalize(map_value(trip, :to)),
        to: Headsigns.normalize(map_value(trip, :from))
      }
    end)
  end

  defp swapped_trip_changes(_), do: Repo.rollback(:invalid_input)

  defp put_operation_id(attrs, nil), do: attrs
  defp put_operation_id(attrs, operation_id), do: Map.put(attrs, :operation_id, operation_id)

  defp prepare_stop_edit(pattern, entries, reviewed_values, loaded \\ nil, opts \\ []) do
    old_occurrences = if loaded, do: loaded.occurrences, else: pattern_occurrences(pattern)
    timings = if loaded, do: loaded.timings, else: pattern_timings(pattern)
    trips = pattern_trips(pattern)

    with {:ok, new_occurrences} <- normalize_occurrence_entries(entries, pattern),
         :ok <- validate_retained_stop_ids(old_occurrences, new_occurrences),
         :ok <- validate_structural_trips(trips, old_occurrences, new_occurrences),
         :ok <- ensure_eligible_occurrences!(pattern, new_occurrences),
         {:ok, timing_groups} <- load_timing_groups(timings),
         {:ok, reviewed} <-
           Materializer.review_stops(
             old_occurrences,
             new_occurrences,
             timing_groups,
             reviewed_values
           ),
         :ok <-
           require_timing_acknowledgements(
             new_occurrences,
             reviewed.estimates,
             reviewed_values,
             trips,
             timings,
             opts
           ),
         true <- timing_ids_match?(timings, reviewed.timing_rows) do
      new_ids = MapSet.new(Enum.map(new_occurrences, &Map.get(&1, :id)))
      removed = Enum.reject(old_occurrences, &MapSet.member?(new_ids, &1.id))
      added = Enum.reject(new_occurrences, &Map.get(&1, :id))

      {:ok,
       %{
         old_occurrences: old_occurrences,
         new_occurrences: new_occurrences,
         timings: timings,
         timing_rows: reviewed.timing_rows,
         start_shifts: Map.get(reviewed, :shifts, [%{start_shift: reviewed.start_shift}]),
         estimates: reviewed.estimates,
         removed: Enum.map(removed, &occurrence_proposal/1),
         added: Enum.map(added, &occurrence_proposal/1),
         noop?:
           Enum.map(old_occurrences, &{&1.id, &1.stop_id}) ==
             Enum.map(new_occurrences, &{Map.get(&1, :id), &1.stop_id})
       }}
    else
      false -> {:error, :invalid_timing_review}
      {:error, _} = error -> error
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp normalize_occurrence_entries(entries, _pattern) when is_list(entries) do
    normalized =
      Enum.map(entries, fn entry ->
        id = map_value(entry, :id)
        stop_id = map_value(entry, :stop_id)
        key = map_value(entry, :key)

        cond do
          is_binary(id) and is_binary(stop_id) -> %{id: id, stop_id: stop_id}
          is_nil(id) and is_binary(stop_id) and is_binary(key) -> %{key: key, stop_id: stop_id}
          true -> nil
        end
      end)

    if Enum.any?(normalized, &is_nil/1), do: {:error, :invalid_input}, else: {:ok, normalized}
  end

  defp normalize_occurrence_entries(_, _), do: {:error, :invalid_input}

  defp validate_structural_trips(trips, old_occurrences, new_occurrences) do
    linked? = Enum.any?(trips, &(&1.pattern_derivation_state == "linked"))
    custom? = Enum.any?(trips, &(&1.pattern_derivation_state == "custom"))
    retained = Enum.filter(new_occurrences, &Map.has_key?(&1, :id))

    cond do
      custom? ->
        {:error, :custom_trips_block_stop_edit}

      length(new_occurrences) < 2 ->
        {:error, :at_least_two_stops}

      linked? and retained == [] ->
        {:error, :retained_occurrence_required}

      linked? ->
        old_ids = Enum.map(old_occurrences, & &1.id)
        new_ids = Enum.map(retained, & &1.id)

        if new_ids == Enum.filter(old_ids, &(&1 in new_ids)),
          do: :ok,
          else: {:error, :invalid_occurrence_order}

      true ->
        :ok
    end
  end

  defp ensure_eligible_occurrences!(pattern, occurrences) do
    stop_ids = Enum.map(occurrences, & &1.stop_id)

    cond do
      length(stop_ids) < 2 ->
        {:error, :at_least_two_stops}

      Enum.any?(Enum.chunk_every(stop_ids, 2, 1, :discard), fn [a, b] -> a == b end) ->
        {:error, :adjacent_duplicate_stops}

      true ->
        ensure_stops_exist(pattern, stop_ids)
    end
  end

  defp ensure_stops_exist(pattern, stop_ids) do
    eligible =
      from(stop in Stop,
        where:
          stop.organization_id == ^pattern.organization_id and
            stop.gtfs_version_id == ^pattern.gtfs_version_id and
            stop.stop_id in ^stop_ids and (is_nil(stop.location_type) or stop.location_type == 0),
        select: stop.stop_id
      )
      |> Repo.all()
      |> MapSet.new()

    if MapSet.size(eligible) == length(Enum.uniq(stop_ids)),
      do: :ok,
      else: {:error, :not_found}
  end

  defp validate_retained_stop_ids(old_occurrences, new_occurrences) do
    old_by_id = Map.new(old_occurrences, &{&1.id, &1.stop_id})

    if Enum.all?(new_occurrences, &retained_identity_valid?(&1, old_by_id)) do
      :ok
    else
      {:error, :invalid_occurrence_identity}
    end
  end

  defp retained_identity_valid?(occurrence, old_by_id) do
    case Map.fetch(occurrence, :id) do
      {:ok, id} -> Map.get(old_by_id, id) == occurrence.stop_id
      :error -> true
    end
  end

  defp load_timing_groups(timings) do
    {:ok,
     Enum.map(timings, fn timing -> %{timing_id: timing.id, rows: timing_rows(timing.id)} end)}
  end

  # An unseen added-stop value can never be silently acknowledged: when an
  # addition affects trips, every timing in the edit must carry an explicit
  # acknowledgement, not only the timings a caller happened to supply. Times
  # re-sequenced by a reorder are estimates as well and are written to the
  # timing rows whether or not any trip uses the pattern.
  defp require_timing_acknowledgements(new, estimates, values, trips, timings, opts) do
    added? = Enum.any?(new, &(not Map.has_key?(&1, :id)))
    affected? = trips != []
    resequenced? = Enum.any?(estimates, & &1[:resequenced])

    if ((added? and affected?) or resequenced?) and
         Keyword.get(opts, :require_acknowledgements, true) do
      acknowledged =
        for {timing_id, entry} <- values,
            map_value(entry, :acknowledged) == true,
            do: to_string(timing_id)

      required = Enum.map(timings, &to_string(&1.id))

      if Enum.sort(acknowledged) == Enum.sort(required),
        do: :ok,
        else: {:error, :timing_acknowledgement_required}
    else
      :ok
    end
  end

  defp timing_ids_match?(timings, result_rows),
    do:
      Enum.sort(Enum.map(timings, & &1.id)) ==
        Enum.sort(Enum.map(result_rows, &Map.get(&1, :timing_id)))

  defp occurrence_proposal(occurrence),
    do: %{
      id: Map.get(occurrence, :id),
      key: Map.get(occurrence, :key),
      stop_id: Map.get(occurrence, :stop_id)
    }

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp map_value(_, _), do: nil

  defp validate_timing_rows(_pattern, _timing, nil), do: {:ok, nil}

  defp validate_timing_rows(pattern, _timing, rows) when is_list(rows) do
    occurrences = pattern_occurrences(pattern)

    normalized =
      Enum.map(rows, fn row ->
        %{
          route_pattern_stop_id: map_value(row, :route_pattern_stop_id),
          arrival_offset: blank_to_nil(map_value(row, :arrival_offset)),
          departure_offset: blank_to_nil(map_value(row, :departure_offset)),
          timepoint: map_value(row, :timepoint),
          pickup_type: map_value(row, :pickup_type),
          drop_off_type: map_value(row, :drop_off_type),
          stop_headsign: map_value(row, :stop_headsign)
        }
      end)

    with true <- length(normalized) == length(occurrences),
         true <-
           Enum.map(normalized, & &1.route_pattern_stop_id) == Enum.map(occurrences, & &1.id),
         true <- Enum.all?(normalized, &valid_service_row?/1),
         :ok <- validate_rows(normalized) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_input}
      {:error, _} = error -> error
    end
  end

  defp validate_timing_rows(_pattern, _timing, _rows), do: {:error, :invalid_input}

  # A blank cell is the absence of a time, not a parse failure, so the editor's
  # empty inputs reach the rows as nil and `TimingRules` decides where a nil pair
  # is allowed: between the ends, at a stop that is not a timepoint, and only as
  # a pair. A half pair or an out-of-order row is still refused.
  defp validate_rows(rows) do
    case TimingRules.validate(rows) do
      :ok -> first_departure_is_base(rows)
      {:error, violations} -> {:error, timing_violation(violations)}
    end
  end

  # The offsets are measured from the first departure, so that row is the base
  # every other row is read against. The rule above does not state it, so it is
  # checked here rather than dropped.
  defp first_departure_is_base([first | _]) do
    if is_integer(first.departure_offset) and first.departure_offset != 0,
      do: {:error, :first_departure_must_be_zero},
      else: :ok
  end

  defp first_departure_is_base([]), do: :ok

  defp timing_violation(violations) do
    cond do
      Enum.any?(violations, &match?({_index, :terminal_blank}, &1)) ->
        :explicit_terminal_values_required

      Enum.any?(violations, &match?({_index, :half_timed}, &1)) ->
        :invalid_time

      true ->
        :invalid_chronology
    end
  end

  # A blank input is the absence of a time. Anything else is left alone so the
  # shape check below still refuses a string, a float or an out-of-range value.
  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp blank_to_nil(value), do: value

  defp valid_service_row?(row) do
    row.timepoint in [nil, 0, 1] and row.pickup_type in [nil, 0, 1, 2, 3] and
      row.drop_off_type in [nil, 0, 1, 2, 3] and offset_in_range?(row.arrival_offset) and
      departure_in_range?(row.departure_offset)
  end

  defp offset_in_range?(nil), do: true

  defp offset_in_range?(offset),
    do: is_integer(offset) and offset in -2_147_483_647..2_147_483_647

  defp departure_in_range?(nil), do: true

  defp departure_in_range?(offset), do: is_integer(offset) and offset in 0..2_147_483_647

  # A submitted vector that matches the stored timing row-for-row is a no-op: it
  # must not write rows, clear a derivation signature or record an audit entry.
  defp timing_rows_unchanged?(_timing, nil), do: true

  defp timing_rows_unchanged?(timing, rows) do
    stored =
      Enum.map(timing_rows(timing.id), fn row ->
        Map.merge(timing_row_attrs(row), %{route_pattern_stop_id: row.route_pattern_stop_id})
      end)

    stored == rows
  end

  defp persist_timing_edit!(pattern, timing, rows) do
    trips = linked_timing_trips(pattern, timing.id)
    occurrences = pattern_occurrences(pattern)

    Enum.each(trips, fn trip ->
      rematerialize_trip!(trip, occurrences, rows, current_trip_start!(trip, occurrences))
    end)

    update_trip_timestamps!(trips)

    Enum.zip(occurrences, rows)
    |> Enum.each(fn {occurrence, attrs} -> update_timing_row!(timing, occurrence, attrs) end)

    if rows != [] do
      Repo.update_all(from(t in TimedPattern, where: t.id == ^timing.id),
        set: [updated_at: DateTime.utc_now()]
      )
    end

    length(trips)
  end

  defp persist_stop_edit!(pattern, edit) do
    old = edit.old_occurrences
    new = persist_occurrences!(pattern, old, edit.new_occurrences)
    timing_rows_by_id = Map.new(edit.timing_rows, &{&1.timing_id, &1.rows})

    Enum.each(edit.timings, fn timing ->
      persist_pattern_timing_rows!(timing, old, new, Map.fetch!(timing_rows_by_id, timing.id))
    end)

    trips = linked_pattern_trips(pattern)

    shifts =
      Map.new(edit.start_shifts, fn item -> {Map.get(item, :timing_id), item.start_shift} end)

    Enum.each(trips, fn trip ->
      rows = Map.fetch!(timing_rows_by_id, trip.timed_pattern_id)
      shift = Map.get(shifts, trip.timed_pattern_id, Map.get(edit, :start_shift, 0))
      persist_structural_trip!(trip, old, new, rows, shift)
    end)

    update_trip_timestamps!(trips)

    if not is_nil(pattern.shape_id) and
         retained_structure_changed?(edit.old_occurrences, edit.new_occurrences) do
      Alignments.clear_visit_distances!(pattern)
    end

    if trips != [] or edit.added != [] or edit.removed != [] do
      Repo.update_all(from(p in RoutePattern, where: p.id == ^pattern.id),
        set: [updated_at: DateTime.utc_now()]
      )
    end

    length(trips)
  end

  # R14: a structural edit that changes the relative order of retained visits,
  # or a retained visit's stop, invalidates derived distances on a drawn pattern
  # (stale values would export decreasing distances). Inserts and removals keep
  # the remaining distances. `old_occurrences` are structs; `new_occurrences`
  # are `%{id | key, stop_id}` entries in position order, where `:id` marks a
  # retained visit.
  defp retained_structure_changed?(old_occurrences, new_occurrences) do
    old_by_id = Map.new(old_occurrences, &{&1.id, &1.stop_id})

    new_retained_ids =
      new_occurrences
      |> Enum.filter(&Map.get(&1, :id))
      |> Enum.map(&Map.get(&1, :id))

    new_retained_set = MapSet.new(new_retained_ids)

    old_retained_order =
      old_occurrences
      |> Enum.sort_by(& &1.position)
      |> Enum.map(& &1.id)
      |> Enum.filter(&MapSet.member?(new_retained_set, &1))

    order_changed? = new_retained_ids != old_retained_order

    stop_changed? =
      Enum.any?(new_occurrences, fn entry ->
        case Map.get(entry, :id) do
          nil -> false
          id -> Map.get(old_by_id, id) != Map.get(entry, :stop_id)
        end
      end)

    order_changed? or stop_changed?
  end

  defp persist_occurrences!(pattern, old, new) do
    new_ids = new |> Enum.map(&Map.get(&1, :id)) |> Enum.reject(&is_nil/1) |> MapSet.new()
    removed = Enum.reject(old, &MapSet.member?(new_ids, &1.id))

    if removed != [] do
      removed_ids = Enum.map(removed, & &1.id)

      Repo.delete_all(
        from(row in TimedPatternStop, where: row.route_pattern_stop_id in ^removed_ids)
      )
    end

    Enum.each(removed, &Repo.delete!/1)

    retained = Enum.filter(new, &Map.get(&1, :id))

    temp_positions =
      unused_positive_values(Enum.map(old, & &1.position), length(retained), length(new))

    Enum.zip(retained, temp_positions)
    |> Enum.each(fn {occurrence, position} ->
      Repo.update_all(from(o in RoutePatternStop, where: o.id == ^occurrence.id),
        set: [position: position]
      )
    end)

    Enum.with_index(new, 1)
    |> Enum.map(fn {entry, position} ->
      case Map.get(entry, :id) do
        nil ->
          insert_occurrence!(pattern, entry.stop_id, position)

        id ->
          Repo.update_all(from(o in RoutePatternStop, where: o.id == ^id),
            set: [position: position, stop_id: entry.stop_id]
          )

          Repo.get!(RoutePatternStop, id)
      end
    end)
  end

  defp persist_pattern_timing_rows!(timing, old, new, rows) do
    new_ids = MapSet.new(Enum.map(new, & &1.id))
    removed_ids = old |> Enum.reject(&MapSet.member?(new_ids, &1.id)) |> Enum.map(& &1.id)

    Repo.delete_all(
      from(r in TimedPatternStop,
        where: r.timed_pattern_id == ^timing.id and r.route_pattern_stop_id in ^removed_ids
      )
    )

    existing = Map.new(timing_rows(timing.id), &{&1.route_pattern_stop_id, &1})

    Enum.zip(new, rows)
    |> Enum.each(fn {occurrence, attrs} ->
      case Map.get(existing, occurrence.id) do
        nil ->
          insert_timing_rows!(timing, [occurrence], [attrs])

        row ->
          row
          |> Ecto.Changeset.change(
            Map.take(attrs, [
              :arrival_offset,
              :departure_offset,
              :timepoint,
              :pickup_type,
              :drop_off_type,
              :stop_headsign
            ])
          )
          |> update_or_rollback!()
      end
    end)
  end

  defp persist_structural_trip!(trip, old_occurrences, new_occurrences, timing_rows, shift) do
    rows = trip_stop_times(trip)

    if length(rows) != length(old_occurrences), do: Repo.rollback(:trip_stop_times_mismatch)

    with {:ok, start_seconds} <- trip_start_seconds(rows),
         {:ok, materialized} <-
           Materializer.materialize(start_seconds + shift, new_occurrences, timing_rows) do
      persist_structural_rows!(
        trip,
        rows,
        old_occurrences,
        new_occurrences,
        timing_rows,
        materialized
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp trip_start_seconds([first | _]), do: GtfsTime.parse(first.departure_time)

  # The single caller of `rematerialize_trip!/4` resolves each trip's current
  # first departure itself and passes it in, so the shared seam takes the start
  # as an argument instead of reading it from the trip's first stop time.
  defp current_trip_start!(trip, occurrences) do
    stop_times = trip_stop_times(trip)

    if length(stop_times) != length(occurrences),
      do: Repo.rollback(:trip_stop_times_mismatch)

    case trip_start_seconds(stop_times) do
      {:ok, start_seconds} -> start_seconds
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp persist_structural_rows!(
         trip,
         rows,
         old_occurrences,
         new_occurrences,
         timing_rows,
         materialized
       ) do
    old_by_occurrence = old_rows_by_occurrence(old_occurrences, new_occurrences, rows)
    retained_times = old_by_occurrence |> Map.values() |> Enum.reject(&is_nil/1)
    delete_removed_stop_times!(rows, retained_times)
    move_retained_sequences!(rows, retained_times, length(new_occurrences))

    persist_final_occurrence_rows!(
      trip,
      new_occurrences,
      timing_rows,
      materialized,
      old_by_occurrence
    )
  end

  defp old_rows_by_occurrence(old_occurrences, new_occurrences, rows) do
    occurrence_indexes =
      Map.new(Enum.with_index(old_occurrences), fn {item, index} -> {item.id, index} end)

    Map.new(new_occurrences, fn occurrence ->
      old_index = Map.get(occurrence_indexes, occurrence.id)
      {occurrence.id, if(old_index, do: Enum.at(rows, old_index))}
    end)
  end

  defp delete_removed_stop_times!(rows, retained_times) do
    rows
    |> Enum.reject(&(&1 in retained_times))
    |> Enum.each(&Repo.delete!/1)
  end

  defp move_retained_sequences!(rows, retained_times, final_count) do
    temporary_values =
      unused_positive_values(
        Enum.map(rows, & &1.stop_sequence),
        length(retained_times),
        final_count
      )

    Enum.zip(retained_times, temporary_values)
    |> Enum.each(fn {row, sequence} ->
      Repo.update_all(from(st in StopTime, where: st.id == ^row.id),
        set: [stop_sequence: sequence]
      )
    end)
  end

  defp persist_final_occurrence_rows!(trip, occurrences, timing_rows, materialized, old_rows) do
    Enum.zip([occurrences, materialized, timing_rows])
    |> Enum.with_index(1)
    |> Enum.each(fn {{occurrence, materialized_row, timing_row}, sequence} ->
      persist_occurrence_row!(trip, occurrence, materialized_row, timing_row, sequence, old_rows)
    end)
  end

  defp persist_occurrence_row!(trip, occurrence, materialized, timing_row, sequence, old_rows) do
    case Map.get(old_rows, occurrence.id) do
      nil ->
        %StopTime{}
        |> StopTime.changeset(
          stop_time_attrs(trip, occurrence, materialized, timing_row, sequence)
        )
        |> insert_or_rollback!()

      old_row ->
        attrs =
          Map.merge(
            preserved_clocks(old_row, materialized),
            Map.take(timing_row, [:stop_headsign, :pickup_type, :drop_off_type, :timepoint])
          )
          |> Map.merge(%{stop_id: occurrence.stop_id, stop_sequence: sequence})

        # The retained row was moved to a temporary sequence before this final
        # assignment, so the sequence has to be written even when every other
        # value is unchanged; otherwise the temporary value would survive.
        old_row
        |> Ecto.Changeset.change(attrs)
        |> Ecto.Changeset.force_change(:stop_sequence, sequence)
        |> update_or_rollback!()
    end
  end

  @doc """
  Re-materializes one linked trip's stop times from a timing's offsets.

  Rewrites each existing `StopTime` row of `trip` positionally against
  `occurrences` (the pattern's stops ordered by position) using `timing_rows`,
  starting from `start_seconds`. Only `arrival_time`, `departure_time`,
  `stop_headsign`, `pickup_type`, `drop_off_type` and `timepoint` change: row
  IDs, `stop_sequence` labels, `shape_dist_traveled`, the continuous fields and
  `inserted_at` are preserved.

  Call only inside `Repo.transaction/1`, after the route and pattern locks. It
  takes the trip's stop times with `FOR UPDATE` and rolls back
  `:trip_stop_times_mismatch` when their number differs from `occurrences`.
  """
  def rematerialize_trip!(trip, occurrences, timing_rows, start_seconds) do
    stop_times = trip_stop_times(trip)

    if length(stop_times) != length(occurrences),
      do: Repo.rollback(:trip_stop_times_mismatch)

    case Materializer.materialize(start_seconds, occurrences, timing_rows) do
      {:ok, materialized} ->
        Enum.zip([stop_times, materialized, timing_rows])
        |> Enum.each(fn {old, value, timing_row} ->
          attrs =
            Map.merge(
              preserved_clocks(old, value),
              Map.take(timing_row, [:stop_headsign, :pickup_type, :drop_off_type, :timepoint])
            )

          old |> Ecto.Changeset.change(attrs) |> update_or_rollback!()
        end)

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp preserved_clocks(old, values) do
    Map.new([:arrival_time, :departure_time], fn field ->
      existing = Map.get(old, field)
      proposed = Map.fetch!(values, field)

      value =
        if GtfsTime.parse(existing) == GtfsTime.parse(proposed), do: existing, else: proposed

      {field, value}
    end)
  end

  defp stop_time_attrs(trip, occurrence, materialized, timing_row, sequence) do
    Map.merge(
      Map.take(materialized, [:arrival_time, :departure_time]),
      Map.take(timing_row, [:stop_headsign, :pickup_type, :drop_off_type, :timepoint])
    )
    |> Map.merge(%{
      trip_id: trip.trip_id,
      stop_id: occurrence.stop_id,
      stop_sequence: sequence,
      organization_id: trip.organization_id,
      gtfs_version_id: trip.gtfs_version_id,
      continuous_pickup: nil,
      continuous_drop_off: nil,
      shape_dist_traveled: nil
    })
  end

  defp update_timing_row!(timing, occurrence, attrs) do
    case Repo.one(
           from(r in TimedPatternStop,
             where: r.timed_pattern_id == ^timing.id and r.route_pattern_stop_id == ^occurrence.id
           )
         ) do
      nil ->
        insert_timing_rows!(timing, [occurrence], [attrs])

      row ->
        row
        |> Ecto.Changeset.change(
          Map.take(attrs, [
            :arrival_offset,
            :departure_offset,
            :timepoint,
            :pickup_type,
            :drop_off_type,
            :stop_headsign
          ])
        )
        |> update_or_rollback!()
    end
  end

  defp linked_pattern_trips(pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id and
          t.pattern_derivation_state == "linked",
      order_by: [asc: t.id]
    )
    |> Repo.all()
  end

  defp linked_timing_trips(pattern, timing_id) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id and t.timed_pattern_id == ^timing_id and
          t.pattern_derivation_state == "linked",
      order_by: [asc: t.id]
    )
    |> Repo.all()
  end

  defp pattern_trips(pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id,
      order_by: [asc: t.id]
    )
    |> Repo.all()
  end

  defp trip_stop_times(trip) do
    from(st in StopTime,
      where:
        st.organization_id == ^trip.organization_id and
          st.gtfs_version_id == ^trip.gtfs_version_id and st.trip_id == ^trip.trip_id,
      order_by: [asc: st.stop_sequence, asc: st.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  # The owner and its labelled children always carry the same direction, so
  # moving the owner moves the children's patterns and the trips linked to
  # either. The whole family is written in the caller's transaction.
  defp update_trip_direction!(pattern, direction_id) do
    children = label_children(pattern)
    trips = Enum.flat_map([pattern | children], &pattern_trips/1)

    Repo.update_all(from(t in Trip, where: t.id in ^Enum.map(trips, & &1.id)),
      set: [direction_id: direction_id, updated_at: DateTime.utc_now()]
    )

    update_label_children_direction!(children, direction_id)

    length(trips)
  end

  defp update_label_children_direction!([], _direction_id), do: :ok

  defp update_label_children_direction!(children, direction_id) do
    # A child's `derivation_key` embeds the direction it was derived for, so it
    # goes the same way the owner's signature does on a direction change.
    Repo.update_all(
      from(child in RoutePattern, where: child.id in ^Enum.map(children, & &1.id)),
      set: [
        direction_id: direction_id,
        derivation_key: nil,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  defp update_trip_timestamps!([]), do: :ok

  defp update_trip_timestamps!(trips) do
    now = DateTime.utc_now()

    Repo.update_all(from(t in Trip, where: t.id in ^Enum.map(trips, & &1.id)),
      set: [updated_at: now]
    )

    :ok
  end

  defp unused_positive_values(occupied, count, final_count) do
    used = MapSet.new(occupied ++ Enum.to_list(1..max(final_count, 0)))
    take_unused(count, used, 1, [])
  end

  defp take_unused(0, _used, _candidate, acc), do: Enum.reverse(acc)

  defp take_unused(count, used, candidate, acc) do
    if MapSet.member?(used, candidate),
      do: take_unused(count, used, candidate + 1, acc),
      else: take_unused(count - 1, MapSet.put(used, candidate), candidate + 1, [candidate | acc])
  end

  @doc """
  Returns the scoped route when its version is published.

  A route outside the organization/version scope, or a route whose version is
  not published, is `{:error, :not_found}` so foreign and unpublished reads can
  never leak scoped data.
  """
  def published_route(organization_id, version_id, route_id) do
    query =
      from route in Route,
        join: version in GtfsVersion,
        on:
          version.id == route.gtfs_version_id and
            version.organization_id == route.organization_id,
        where:
          route.organization_id == ^organization_id and route.gtfs_version_id == ^version_id and
            route.route_id == ^route_id and version.publication_status == "published"

    case Repo.one(query) do
      %Route{} = route -> {:ok, route}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Locks one published route of the audit context's organization and version with `FOR UPDATE`.

  Call only inside `Repo.transaction/1`. This is a lock, not a transaction. It takes the
  organization-scoped version row `FOR SHARE` first, so a calendar mutation or a calendar
  combination that owns that version cannot commit fresh pattern input between a review and its
  apply, then the route `FOR UPDATE`, keeping the rule-table lock order. It rolls back
  `:not_found` when the version is outside the organization, the route does not exist, or the
  version is not published.
  """
  def lock_published_route!(%AuditContext{} = audit, route_id) do
    # The shared lock is a scope, not an authorization: callers that took it earlier in the same
    # transaction (the schedule writers) re-lock the row here without upgrading or reordering it.
    version = Versions.lock_for_input_write!(audit.organization_id, audit.gtfs_version_id)

    route =
      from(route in Route,
        where:
          route.organization_id == ^audit.organization_id and
            route.gtfs_version_id == ^audit.gtfs_version_id and route.route_id == ^route_id,
        lock: "FOR UPDATE"
      )
      |> Repo.one()

    case route do
      %Route{} = row ->
        # The published requirement is applied after the shared lock, exactly as `Calendars` does,
        # because the shared lock itself takes no publication stance.
        if version.publication_status == "published" do
          row
        else
          Repo.rollback(:not_found)
        end

      nil ->
        Repo.rollback(:not_found)
    end
  end

  @doc """
  Locks every pattern of a locked route `FOR UPDATE` in stable UUID order.

  Call only inside `Repo.transaction/1`, after `lock_published_route!/2`. The
  R5 route-cascade lock order is version, route, sorted patterns, sorted trips;
  taking the whole set in one ordered statement keeps opposing lifecycle
  writers deadlock-free.
  """
  def lock_route_patterns!(%Route{} = route) do
    from(pattern in RoutePattern,
      where:
        pattern.organization_id == ^route.organization_id and
          pattern.gtfs_version_id == ^route.gtfs_version_id and
          pattern.route_id == ^route.route_id,
      order_by: [asc: pattern.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  @doc """
  Removes one route's owned patterns and descendants for the reviewed route
  cascade (R5), auditing each pattern with the existing single-delete
  semantics under one shared operation id.

  Call only inside the reviewed route-deletion transaction, after the route
  and its sorted patterns are locked and the deletion review has been
  recomputed and accepted. The patterns are removed in FK-safe set-based
  order (timing rows, timings, occurrences, patterns) and never through the
  public per-pattern delete. Returns the removed row counts keyed like the
  review categories so the caller can check them against the review.
  """
  def cascade_delete_patterns!(patterns, operation_id, %AuditContext{} = audit_context)
      when is_list(patterns) and is_binary(operation_id) do
    Enum.each(patterns, fn pattern ->
      snapshot = pattern_snapshot(load_pattern_for_audit!(pattern.id))

      audit!(audit_context, :route_pattern, pattern, "deleted", %{
        before: snapshot,
        operation_id: operation_id
      })
    end)

    pattern_ids = Enum.map(patterns, & &1.id)
    children = delete_pattern_children!(pattern_ids)
    {removed, nil} = Repo.delete_all(from(p in RoutePattern, where: p.id in ^pattern_ids))

    %{
      patterns: removed,
      pattern_stops: children.pattern_stops,
      timed_patterns: children.timed_patterns,
      timed_pattern_stops: children.timed_pattern_stops
    }
  end

  @doc """
  Locks one scoped pattern of a locked route with `FOR UPDATE`.

  Call only inside `Repo.transaction/1`, after `lock_published_route!/2`. This is a lock, not a
  transaction: it takes the row lock and rolls back `:not_found` when the pattern is out of scope.
  """
  def lock_pattern!(route, pattern_id) do
    case from(pattern in RoutePattern,
           where:
             pattern.organization_id == ^route.organization_id and
               pattern.gtfs_version_id == ^route.gtfs_version_id and
               pattern.route_id == ^route.route_id and pattern.id == ^pattern_id,
           lock: "FOR UPDATE"
         )
         |> Repo.one() do
      %RoutePattern{} = pattern -> pattern
      nil -> Repo.rollback(:not_found)
    end
  end

  defp lock_pattern_trips!(route, pattern) do
    from(trip in Trip,
      where:
        trip.organization_id == ^route.organization_id and
          trip.gtfs_version_id == ^route.gtfs_version_id and trip.route_id == ^route.route_id and
          trip.route_pattern_id == ^pattern.route_pattern_id,
      order_by: [asc: trip.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  defp trips_lock_required?(:delete), do: true
  defp trips_lock_required?({:delete_timing, _timing_id}), do: true
  defp trips_lock_required?({:stops, _, _}), do: true
  defp trips_lock_required?({:timing, _, _, _}), do: true
  defp trips_lock_required?({:timing, _, _}), do: true

  # A direction change moves every trip of the pattern; a headsign selection
  # writes exactly its trips, so both lock the pattern's trips up front.
  defp trips_lock_required?({:details, attrs, selection}) when is_map(attrs) do
    trips_lock_required?({:details, attrs}) or selection_nonempty?(selection)
  end

  defp trips_lock_required?({:details, attrs}) when is_map(attrs),
    do: direction_change?({:details, attrs})

  defp trips_lock_required?(_operation), do: false

  defp selection_nonempty?(selection), do: match?({:ok, [_ | _]}, selection_trip_ids(selection))

  defp scoped_pattern(org_id, version_id, route_id, pattern_id) do
    Repo.one(
      from(pattern in RoutePattern,
        where:
          pattern.organization_id == ^org_id and pattern.gtfs_version_id == ^version_id and
            pattern.route_id == ^route_id and pattern.id == ^pattern_id
      )
    )
  end

  defp selected_timing(_pattern, nil), do: {:ok, nil}

  defp selected_timing(pattern, timing_id) do
    case scoped_timing(pattern, timing_id) do
      %TimedPattern{} = timing -> {:ok, timing}
      nil -> {:error, :not_found}
    end
  end

  defp scoped_timing(pattern, timing_id) do
    Repo.one(
      from(timing in TimedPattern,
        where: timing.route_pattern_id == ^pattern.id and timing.id == ^timing_id,
        preload: [:route_pattern]
      )
    )
  end

  defp route_id_for_pattern(pattern_id, audit) do
    case Repo.one(
           from(pattern in RoutePattern,
             where:
               pattern.organization_id == ^audit.organization_id and
                 pattern.gtfs_version_id == ^audit.gtfs_version_id and pattern.id == ^pattern_id,
             select: pattern.route_id
           )
         ) do
      nil -> {:error, :not_found}
      route_id -> {:ok, route_id}
    end
  end

  defp load_eligible_stops!(route, stop_ids) do
    eligible =
      from(stop in Stop,
        where:
          stop.organization_id == ^route.organization_id and
            stop.gtfs_version_id == ^route.gtfs_version_id and stop.stop_id in ^stop_ids and
            (is_nil(stop.location_type) or stop.location_type == 0),
        select: stop.stop_id
      )
      |> Repo.all()
      |> MapSet.new()

    if MapSet.size(eligible) != length(Enum.uniq(stop_ids)) do
      Repo.rollback(:not_found)
    end

    Enum.map(stop_ids, & &1)
  end

  defp insert_occurrences!(pattern, stop_ids) do
    stop_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {stop_id, position} -> insert_occurrence!(pattern, stop_id, position) end)
  end

  defp insert_occurrence!(pattern, stop_id, position) do
    %RoutePatternStop{}
    |> RoutePatternStop.changeset(%{
      route_pattern_id: pattern.id,
      organization_id: pattern.organization_id,
      gtfs_version_id: pattern.gtfs_version_id,
      stop_id: stop_id,
      position: position,
      route_pattern: pattern
    })
    |> insert_or_rollback!()
  end

  defp insert_timing!(pattern, name, headsign) do
    %TimedPattern{}
    |> TimedPattern.changeset(%{
      route_pattern_id: pattern.id,
      organization_id: pattern.organization_id,
      gtfs_version_id: pattern.gtfs_version_id,
      route_pattern: pattern,
      name: name,
      headsign: headsign,
      derivation_key: nil
    })
    |> insert_or_rollback!()
  end

  defp insert_timing_rows!(timing, occurrences, rows) do
    occurrences
    |> Enum.zip(rows)
    |> Enum.each(fn {occurrence, attrs} ->
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        Map.merge(attrs, %{
          timed_pattern_id: timing.id,
          route_pattern_stop_id: occurrence.id,
          timed_pattern: timing,
          route_pattern_stop: occurrence
        })
      )
      |> insert_or_rollback!()
    end)
  end

  defp copy_timing_rows!(timing, occurrences, source_rows) do
    Enum.each(occurrences, fn occurrence ->
      source = Enum.at(source_rows, occurrence.position - 1)

      attrs =
        case source do
          nil -> %{arrival_offset: 0, departure_offset: 0}
          row -> timing_row_attrs(row)
        end

      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        Map.merge(attrs, %{
          timed_pattern_id: timing.id,
          route_pattern_stop_id: occurrence.id,
          timed_pattern: timing,
          route_pattern_stop: occurrence
        })
      )
      |> insert_or_rollback!()
    end)
  end

  defp zero_timing_rows(count),
    do: List.duplicate(%{arrival_offset: 0, departure_offset: 0}, count)

  defp pattern_occurrences(%RoutePattern{id: pattern_id}), do: pattern_occurrences(pattern_id)

  defp pattern_occurrences(pattern_id) do
    from(occurrence in RoutePatternStop,
      where: occurrence.route_pattern_id == ^pattern_id,
      order_by: [asc: occurrence.position]
    )
    |> Repo.all()
  end

  defp pattern_timings(%RoutePattern{id: pattern_id}), do: pattern_timings(pattern_id)

  defp pattern_timings(pattern_id) do
    from(timing in TimedPattern,
      where: timing.route_pattern_id == ^pattern_id,
      order_by: [asc: timing.name, asc: timing.id]
    )
    |> Repo.all()
  end

  defp timing_rows(timing_id) do
    from(row in TimedPatternStop,
      join: occurrence in RoutePatternStop,
      on: occurrence.id == row.route_pattern_stop_id,
      where: row.timed_pattern_id == ^timing_id,
      order_by: [asc: occurrence.position]
    )
    |> Repo.all()
  end

  defp timing_count(pattern_id),
    do:
      Repo.aggregate(
        from(timing in TimedPattern, where: timing.route_pattern_id == ^pattern_id),
        :count
      )

  defp timing_used?(_route, timing) do
    query =
      from(trip in Trip,
        where:
          trip.timed_pattern_id == ^timing.id and trip.organization_id == ^timing.organization_id and
            trip.gtfs_version_id == ^timing.gtfs_version_id
      )

    Repo.exists?(query)
  end

  defp pattern_used?(_route, pattern) do
    query =
      from(trip in Trip,
        where:
          trip.route_pattern_id == ^pattern.route_pattern_id and
            trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id
      )

    Repo.exists?(query)
  end

  # A pattern that still names a label owner cannot be deleted: the reference
  # restricts the deletion and the child would be left without a label at all.
  defp pattern_labelled?(pattern), do: Repo.exists?(label_children_query(pattern))

  defp label_children(pattern) do
    label_children_query(pattern) |> order_by(asc: :id) |> Repo.all()
  end

  defp label_children_query(pattern) do
    from(child in RoutePattern,
      where:
        child.organization_id == ^pattern.organization_id and
          child.gtfs_version_id == ^pattern.gtfs_version_id and
          child.label_pattern_id == ^pattern.id
    )
  end

  defp count_timing_trips(pattern, timing_id) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.timed_pattern_id == ^timing_id
      ),
      :count
    )
  end

  defp count_pattern_trips(pattern) do
    Repo.aggregate(
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_pattern_id == ^pattern.route_pattern_id
      ),
      :count
    )
  end

  defp load_pattern_for_audit!(pattern_id) do
    Repo.get!(RoutePattern, pattern_id)
    |> Repo.preload([:organization, :gtfs_version])
  end

  defp pattern_snapshot(pattern) do
    occurrences = pattern_occurrences(pattern)

    %{
      route_pattern_id: pattern.route_pattern_id,
      route_id: pattern.route_id,
      direction_id: pattern.direction_id,
      route_pattern_name: pattern.route_pattern_name,
      route_pattern_time_desc: pattern.route_pattern_time_desc,
      route_pattern_typicality: pattern.route_pattern_typicality,
      headsign: pattern.headsign,
      canonical_route_pattern: pattern.canonical_route_pattern,
      route_pattern_sort_order: pattern.route_pattern_sort_order,
      representative_trip_id: pattern.representative_trip_id,
      derivation_key: pattern.derivation_key,
      occurrences:
        Enum.map(occurrences, fn occurrence ->
          %{id: occurrence.id, stop_id: occurrence.stop_id, position: occurrence.position}
        end),
      timings:
        Enum.map(pattern_timings(pattern), fn timing ->
          %{
            id: timing.id,
            name: timing.name,
            headsign: timing.headsign,
            rows: Enum.map(timing_rows(timing.id), &timing_row_attrs/1)
          }
        end)
    }
  end

  defp timing_row_attrs(row) do
    Map.take(row, [
      :arrival_offset,
      :departure_offset,
      :timepoint,
      :pickup_type,
      :drop_off_type,
      :stop_headsign
    ])
  end

  defp timing_audit_attrs(pattern, timing, attrs) do
    Map.merge(attrs, %{
      pattern_route_pattern_id: pattern.route_pattern_id,
      timing_id: timing.id,
      timing_name: timing.name
    })
  end

  defp audit!(audit_context, type, entity, action, attrs) do
    context = %{audit_context | station_stop_id: nil}

    case Audit.record_change_in_transaction(context, type, entity, action, attrs) do
      {:ok, log} -> log
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp source_fingerprint(pattern) do
    if pattern && not Repo.in_transaction?() do
      Repo.transaction(fn -> source_fingerprint_in_transaction(pattern) end) |> elem(1)
    else
      source_fingerprint_in_transaction(pattern)
    end
  end

  defp source_fingerprint_in_transaction(pattern) do
    base = source_fingerprint_base(pattern)
    hash = :crypto.hash_update(:crypto.hash_init(:sha256), canonical_binary(base))

    hash
    |> stream_stop_time_fingerprint(pattern)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp source_fingerprint_base(nil), do: nil

  defp source_fingerprint_base(pattern) do
    trips =
      from(trip in Trip,
        where:
          trip.organization_id == ^pattern.organization_id and
            trip.gtfs_version_id == ^pattern.gtfs_version_id and
            trip.route_id == ^pattern.route_id and
            trip.route_pattern_id == ^pattern.route_pattern_id,
        order_by: [asc: trip.id]
      )
      |> Repo.all()

    %{
      scope: {pattern.organization_id, pattern.gtfs_version_id, pattern.route_id},
      pattern: pattern_snapshot(pattern),
      trips: trips
    }
  end

  defp stream_stop_time_fingerprint(hash, nil), do: hash

  defp stream_stop_time_fingerprint(hash, pattern) do
    from(trip in Trip,
      join: stop_time in StopTime,
      on:
        stop_time.organization_id == trip.organization_id and
          stop_time.gtfs_version_id == trip.gtfs_version_id and
          stop_time.trip_id == trip.trip_id,
      where:
        trip.organization_id == ^pattern.organization_id and
          trip.gtfs_version_id == ^pattern.gtfs_version_id and
          trip.route_id == ^pattern.route_id and
          trip.route_pattern_id == ^pattern.route_pattern_id,
      order_by: [asc: trip.id, asc: stop_time.stop_sequence, asc: stop_time.id],
      select: {trip.id, stop_time}
    )
    |> Repo.stream()
    |> Enum.reduce(hash, fn record, acc ->
      :crypto.hash_update(acc, canonical_binary(record))
    end)
  end

  defp review_fingerprint(source, operation),
    do: source <> ":" <> digest({source, canonical(operation)})

  defp digest(value),
    do: :crypto.hash(:sha256, canonical_binary(value)) |> Base.encode16(case: :lower)

  defp canonical_binary(value),
    do: value |> canonical() |> :erlang.term_to_binary([:deterministic])

  defp canonical(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}
  defp canonical(%_{} = value), do: value |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value) and not is_struct(value),
    do:
      value
      |> Enum.map(fn {key, val} -> {to_string(key), canonical(val)} end)
      |> Enum.sort_by(&elem(&1, 0))

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()

  defp canonical(value), do: value

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  defp normalize_pattern_attrs(attrs), do: normalize_allowed_attrs(attrs, @pattern_fields)

  defp normalize_allowed_attrs(attrs, allowed) when is_map(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key = to_string(key)
      if key in allowed, do: Map.put(acc, String.to_existing_atom(key), value), else: acc
    end)
    |> then(&{:ok, &1})
  rescue
    ArgumentError -> {:error, :invalid_input}
  end

  defp normalize_allowed_attrs(_, _), do: {:error, :invalid_input}

  defp normalize_stop_ids(attrs) do
    case Map.get(attrs, :stops, Map.get(attrs, "stops")) do
      stops when is_list(stops) ->
        if Enum.all?(stops, &is_binary/1), do: {:ok, stops}, else: {:error, :invalid_input}

      _ ->
        {:error, :invalid_input}
    end
  end

  defp validate_occurrence_list(stops) do
    cond do
      length(stops) < 2 ->
        {:error, :at_least_two_stops}

      Enum.any?(Enum.chunk_every(stops, 2, 1, :discard), fn [a, b] -> a == b end) ->
        {:error, :adjacent_duplicate_stops}

      true ->
        :ok
    end
  end

  defp reject_forged_linkage(attrs) when is_map(attrs) do
    keys = Enum.map(Map.keys(attrs), &to_string/1)

    if Enum.any?(keys, &(&1 in @forbidden_linkage_fields)),
      do: {:error, :invalid_input},
      else: :ok
  end

  defp reject_forged_linkage(_), do: {:error, :invalid_input}

  defp validate_noop_or_pattern(pattern, attrs) do
    changeset = RoutePattern.changeset(pattern, attrs)
    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp validate_timing_attrs(attrs) do
    if Map.has_key?(attrs, :name) and (not is_binary(attrs.name) or String.trim(attrs.name) == "") do
      {:error, :invalid_input}
    else
      :ok
    end
  end

  defp same_values?(struct, attrs) do
    Enum.all?(attrs, fn {key, value} -> Map.get(struct, key) == value end)
  end

  @doc false
  def next_timing_name(pattern_id) do
    names = MapSet.new(Enum.map(pattern_timings(pattern_id), &String.downcase(&1.name)))

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = "Timing #{alpha_name(index)}"
      if MapSet.member?(names, String.downcase(name)), do: nil, else: name
    end)
  end

  @doc """
  Returns the first free pasted timing name for a pattern.

  `prefix` is the `"Pasted <Mon D>"` head (for example `"Pasted Sep 28"`);
  candidates are `"<prefix> · <suffix>"` with the suffix sequence reusing
  `alpha_name/1` (`A … Z, AA …`). Candidates compare case-insensitively
  against the pattern's existing timings plus `pending`, the names already
  assigned to this pattern in the current paste, so a second paste the same
  day with an existing `"Pasted Sep 28 · A"` names `"Pasted Sep 28 · B"`
  (R10, AC-12).

  Read-only; call any time.
  """
  @spec next_free_timing_name(Ecto.UUID.t(), String.t(), [String.t()]) :: String.t()
  def next_free_timing_name(pattern_id, prefix, pending) do
    taken =
      MapSet.new(
        Enum.map(
          Enum.map(pattern_timings(pattern_id), & &1.name) ++ List.wrap(pending),
          &String.downcase(to_string(&1))
        )
      )

    Stream.iterate(0, &(&1 + 1))
    |> Enum.find_value(fn index ->
      name = "#{prefix} · #{alpha_name(index)}"
      unless MapSet.member?(taken, String.downcase(name)), do: name
    end)
  end

  @doc """
  Inserts a pasted timing with authored offsets inside the caller's transaction.

  Inserts one `TimedPattern` named `name` with `headsign` via `insert_timing!/3`,
  one row per pattern occurrence via `insert_timing_rows!/3` (`rows` zipped to
  `pattern_occurrences/1`; each row carries `arrival_offset`, `departure_offset`,
  `timepoint` and the service fields the paste resolved), and audits the
  `:timed_pattern` `"created"` entry with the timing `after` snapshot, sharing
  the caller's `operation_id` when one is set on the audit context (AC-22).

  Call only inside an early-authorized editor transaction, after
  `lock_published_route!/2` and `lock_pattern!/2`. The production caller is
  `Schedules.create_paste_timings!/4`, reached from `Schedules.apply_paste/5`.
  The transaction guard and audit scope check do not grant permission. A
  rows/occurrences count mismatch rolls the transaction
  back, as does any changeset failure, which is why this is a bang function:
  errors abort the enclosing transaction instead of returning tuples.
  """
  @spec create_pasted_timing!(
          RoutePattern.t(),
          String.t(),
          [map()],
          String.t() | nil,
          AuditContext.t(),
          String.t() | nil
        ) :: TimedPattern.t()
  def create_pasted_timing!(
        %RoutePattern{} = pattern,
        name,
        rows,
        headsign,
        %AuditContext{} = audit_context,
        operation_id \\ nil
      ) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "create_pasted_timing! requires an authorized transaction")

    unless pattern.organization_id == audit_context.organization_id and
             pattern.gtfs_version_id == audit_context.gtfs_version_id,
           do: Repo.rollback(:not_found)

    occurrences = pattern_occurrences(pattern)

    if length(rows) != length(occurrences), do: Repo.rollback(:timing_rows_mismatch)

    timing = insert_timing!(pattern, name, headsign)
    insert_timing_rows!(timing, occurrences, rows)

    audit!(
      audit_context,
      :timed_pattern,
      timing,
      "created",
      timing_audit_attrs(pattern, timing, %{
        after: audit_timing_snapshot(timing),
        operation_id: operation_id
      })
    )

    timing
  end

  # Derivation persists a signature key on each derived pattern/timing so a retry
  # can reuse them. A staff edit that changes the pattern structure, the pattern
  # direction or a timing vector clears the affected keys so a retry can never
  # match obsolete content.
  defp clear_structure_signatures!(pattern) do
    from(timing in TimedPattern, where: timing.route_pattern_id == ^pattern.id)
    |> Repo.update_all(set: [derivation_key: nil])

    clear_pattern_signature!(pattern)
  end

  defp clear_pattern_signature!(pattern) do
    from(row in RoutePattern, where: row.id == ^pattern.id and not is_nil(row.derivation_key))
    |> Repo.update_all(set: [derivation_key: nil])
  end

  defp clear_timing_signature!(timing) do
    from(row in TimedPattern, where: row.id == ^timing.id and not is_nil(row.derivation_key))
    |> Repo.update_all(set: [derivation_key: nil])
  end

  defp maybe_clear_pattern_signature!(pattern, attrs) do
    direction = Map.get(attrs, :direction_id, Map.get(attrs, "direction_id"))

    if not is_nil(direction) and direction != pattern.direction_id do
      clear_pattern_signature!(pattern)
    end
  end

  defp alpha_name(index) when index < 26, do: <<?A + index>>
  defp alpha_name(index), do: alpha_name(div(index, 26) - 1) <> alpha_name(rem(index, 26))

  defp copy_name(nil), do: "Copy"
  defp copy_name(name), do: String.slice("#{name} copy", 0, 255)

  defp natural_pattern_id, do: "app-" <> Ecto.UUID.generate()

  defp insert_or_rollback!(%Ecto.Changeset{} = changeset) do
    case Repo.insert(changeset) do
      {:ok, struct} -> struct
      {:error, error} -> Repo.rollback(error)
    end
  end

  defp update_or_rollback!(%Ecto.Changeset{} = changeset) do
    case Repo.update(changeset) do
      {:ok, struct} -> struct
      {:error, error} -> Repo.rollback(error)
    end
  end
end

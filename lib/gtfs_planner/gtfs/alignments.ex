defmodule GtfsPlanner.Gtfs.Alignments do
  @moduledoc """
  Resolves a pattern's visit-pair sections and export status, and lists the
  patterns that use a stop pair for save scoping.

  A section is the consecutive visit pair (visit *i*, visit *i+1*), addressed
  by `position = i` and identified by `(from_occurrence_id, to_stop_id)`
  (INV-6, R2). Resolution order is override → shared → missing (R3); a row
  with `points = []` is a straight saved path, not missing (R4). Blocked
  reasons come from `Materializer.build/2` (R5) and the export status follows
  R9. Only this context (and its submodules) reads `alignment_segments`
  (CR-1); every read filters by the pattern's organization and version
  (INV-2).

  Saves apply through `apply_save/5` in a SERIALIZABLE
  `ReviewedApplyTransaction` transaction (R7): the snapshot is taken at the
  first statement, the review is recomputed and its fingerprint compared in
  constant time (`:stale_review` on mismatch), a differing base returns
  `{:conflict, current_sections}` and a changed identity `:stale_stops`, all
  with no writes. Route `FOR UPDATE` locks are taken in `route_id` order,
  then patterns in id order, then linked trips in id order. Serialization
  failures (`40001`), deadlocks (`40P01`) and unique violations (`23505`)
  on the alignment and shape indexes retry up to three times with a fresh
  snapshot, then return `:busy`. There is no advisory lock (CR-3).
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments.Draft
  alias GtfsPlanner.Gtfs.Alignments.Materializer
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @type visit :: %{
          occurrence_id: Ecto.UUID.t(),
          position: pos_integer(),
          stop_id: String.t(),
          name: String.t(),
          lat: float() | nil,
          lon: float() | nil,
          label: String.t()
        }

  @type section :: %{
          optional(:shared_points) => [[float()]] | nil,
          optional(:shared_users) => non_neg_integer() | nil,
          position: pos_integer(),
          from_occurrence_id: Ecto.UUID.t(),
          to_occurrence_id: Ecto.UUID.t(),
          from_stop_id: String.t(),
          to_stop_id: String.t(),
          kind: :override | :shared | :missing | :blocked,
          blocked_reason: nil | :no_coordinates | :zero_length,
          points: [[float()]],
          revision: %{segment_id: Ecto.UUID.t() | nil, lock_version: pos_integer() | nil}
        }

  @type status :: %{
          missing: non_neg_integer(),
          blocked: non_neg_integer(),
          export: :current | :stale | :imported | :none
        }

  @type resolved :: %{
          pattern: RoutePattern.t(),
          visits: [visit()],
          sections: [section()],
          status: status(),
          digest: String.t() | nil
        }

  @type pair_user :: %{
          pattern_id: Ecto.UUID.t(),
          route_pattern_id: String.t(),
          route_id: String.t(),
          route_label: String.t(),
          pattern_label: String.t(),
          visit_positions: [pos_integer()],
          custom_positions: [pos_integer()],
          owns_shape?: boolean(),
          linked_trip_count: non_neg_integer()
        }

  @doc """
  Returns the pattern's visits, R3-resolved sections, R9 status and digest.

  The single resolver every reader uses (R3 owner).
  """
  @spec resolve(RoutePattern.t()) :: resolved()
  def resolve(%RoutePattern{} = pattern) do
    visits = load_visits(pattern)
    occurrence_ids = Enum.map(visits, & &1.occurrence_id)

    from_stop_ids =
      visits
      |> Enum.drop(-1)
      |> Enum.map(& &1.stop_id)
      |> Enum.uniq()

    overrides = load_overrides(pattern, occurrence_ids)
    shared = load_shared(pattern, from_stop_ids)

    overrides_by_key =
      Map.new(overrides, fn seg -> {{seg.from_occurrence_id, seg.to_stop_id}, seg} end)

    shared_by_pair =
      Map.new(shared, fn seg -> {{seg.from_stop_id, seg.to_stop_id}, seg} end)

    initial = initial_sections(visits, overrides_by_key, shared_by_pair)

    materializer_visits = Enum.map(visits, fn v -> %{lat: v.lat, lon: v.lon} end)
    interiors = Enum.map(initial, & &1.points)

    case Materializer.build(materializer_visits, interiors) do
      {:ok, %{digest: digest}} ->
        missing = Enum.count(initial, &(&1.kind == :missing))

        resolved_digest = if missing == 0, do: digest, else: nil

        sections = initial
        status = build_status(pattern, sections, resolved_digest)

        %{pattern: pattern, visits: visits, sections: sections, status: status, digest: resolved_digest}

      {:error, {:blocked, blockers}} ->
        blocker_by_position = Map.new(blockers, fn %{position: pos, reason: reason} -> {pos, reason} end)

        sections =
          Enum.map(initial, fn section ->
            case Map.get(blocker_by_position, section.position) do
              nil -> section
              reason -> %{section | kind: :blocked, blocked_reason: reason}
            end
          end)

        status = build_status(pattern, sections, nil)

        %{pattern: pattern, visits: visits, sections: sections, status: status, digest: nil}
    end
  end

  @doc """
  Lists every pattern in the version that visits `from_stop_id` immediately
  followed by `to_stop_id`.

  A visit position lands in `custom_positions` when an applicable override
  covers it (INV-6 identity: the override's stored `from_stop_id` still equals
  the visit's stop); otherwise it lands in `visit_positions`. Sorted by
  `route_id`, then `route_pattern_id`. Scoped to one organization and version
  (INV-2). The R6 save-scope reader consumed by `review_save/3`.
  """
  @spec pair_users(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t()) :: [pair_user()]
  def pair_users(organization_id, gtfs_version_id, from_stop_id, to_stop_id) do
    stops_with_next =
      from(rs in RoutePatternStop,
        where:
          rs.organization_id == ^organization_id and
            rs.gtfs_version_id == ^gtfs_version_id,
        select: %{
          id: rs.id,
          route_pattern_id: rs.route_pattern_id,
          position: rs.position,
          stop_id: rs.stop_id,
          next_stop_id:
            type(
              fragment(
                "LEAD(?) OVER (PARTITION BY ? ORDER BY ?)",
                rs.stop_id,
                rs.route_pattern_id,
                rs.position
              ),
              :string
            )
        }
      )

    rows =
      from(q in subquery(stops_with_next),
        join: rp in RoutePattern,
        on:
          rp.id == q.route_pattern_id and
            rp.organization_id == ^organization_id and
            rp.gtfs_version_id == ^gtfs_version_id,
        left_join: r in Route,
        on:
          r.organization_id == ^organization_id and
            r.gtfs_version_id == ^gtfs_version_id and
            r.route_id == rp.route_id,
        left_join: seg in AlignmentSegment,
        on:
          seg.organization_id == ^organization_id and
            seg.gtfs_version_id == ^gtfs_version_id and
            seg.from_occurrence_id == q.id and
            seg.from_stop_id == ^from_stop_id and
            seg.to_stop_id == ^to_stop_id,
        where: q.stop_id == ^from_stop_id and q.next_stop_id == ^to_stop_id,
        order_by: [asc: rp.route_id, asc: rp.route_pattern_id, asc: q.position],
        select: %{
          pattern_id: rp.id,
          route_pattern_id: rp.route_pattern_id,
          route_id: rp.route_id,
          route_short_name: r.route_short_name,
          pattern_name: rp.route_pattern_name,
          shape_id: rp.shape_id,
          position: q.position,
          segment_id: seg.id
        }
      )
      |> Repo.all()

    trip_counts =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id and
            t.pattern_derivation_state == "linked",
        group_by: [t.route_id, t.route_pattern_id],
        select: {t.route_id, t.route_pattern_id, count(t.id)}
      )
      |> Repo.all()
      |> Map.new(fn {route_id, route_pattern_id, count} ->
        {{route_id, route_pattern_id}, count}
      end)

    rows
    |> Enum.group_by(fn row -> row.pattern_id end)
    |> Enum.map(fn {_pattern_id, grouped} ->
      first = hd(grouped)

      {plain, custom} = Enum.split_with(grouped, fn row -> is_nil(row.segment_id) end)

      %{
        pattern_id: first.pattern_id,
        route_pattern_id: first.route_pattern_id,
        route_id: first.route_id,
        route_label: first.route_short_name || first.route_id,
        pattern_label: first.pattern_name || first.route_pattern_id,
        visit_positions: Enum.map(plain, fn row -> row.position end),
        custom_positions: Enum.map(custom, fn row -> row.position end),
        owns_shape?: present?(first.shape_id),
        linked_trip_count: Map.get(trip_counts, {first.route_id, first.route_pattern_id}, 0)
      }
    end)
    |> Enum.sort_by(fn user -> {user.route_id, user.route_pattern_id} end)
  end

  @type blocker :: %{
          route_pattern_id: String.t(),
          pattern_label: String.t(),
          trip_id: String.t(),
          stop_time_count: non_neg_integer(),
          visit_count: pos_integer()
        }

  @type shape_plan :: %{
          shape_id: String.t(),
          mode: :existing | :adopt | :allocate,
          replaced: [
            %{
              shape_id: String.t(),
              trip_count: pos_integer(),
              action: :adopted | :deleted,
              points: [[term()]]
            }
          ],
          previous: [
            %{
              shape_id: String.t() | nil,
              trip_count: pos_integer(),
              visit_distances: [Decimal.t() | nil]
            }
          ],
          blockers: [blocker()]
        }

  @doc """
  Plans the pattern's shape ID, replaced shapes and materialization blockers.

  R10 owner: a pattern with `shape_id` keeps it (`:existing`); otherwise the
  plan adopts the single imported shape used only by this pattern's linked
  trips (`:adopt`), or allocates the first unused `route_pattern_id`,
  `route_pattern_id-2`, ... ID (`:allocate`). An ID is unused when no `shapes`
  row has it and no `route_pattern.shape_id` owns it. Adoption needs every
  linked trip on the same non-nil shape; a nil or mixed set allocates. R11:
  `replaced` lists each linked shape no trip outside this pattern's linked set
  references (adopted, or deleted after the move), with its prior points as
  `[lat, lon, sequence, dist]` rows by sequence for the `pattern_shape` audit
  entry. R13: `blockers` names linked trips whose stop-time count differs
  from `visit_count`. Read-only; writes are step 11's (INV-5: adoption or
  deletion happens only in an apply with `confirm_replacements: true`). Every
  query filters by the pattern's organization and version (INV-2). Consumed by
  `review_save/3` and `materialize_pattern!/4` (steps 10, 11, 12, 15).
  """
  @spec shape_plan(RoutePattern.t(), pos_integer()) :: shape_plan()
  def shape_plan(%RoutePattern{} = pattern, visit_count) do
    linked = linked_trips(pattern)
    outside_counts = outside_shape_counts(pattern)
    {stop_counts, visit_vectors} = stop_time_observations(pattern, linked)
    shape_points = replaced_shape_points(pattern, linked, outside_counts)

    previous = previous_vectors(linked, visit_vectors)
    blockers = materialization_blockers(pattern, visit_count, linked, stop_counts)

    if present?(pattern.shape_id) do
      %{shape_id: pattern.shape_id, mode: :existing, replaced: [], previous: previous, blockers: blockers}
    else
      distinct_shapes = linked |> Enum.map(& &1.shape_id) |> Enum.uniq()

      case distinct_shapes do
        [shape_id] when is_binary(shape_id) and shape_id != "" ->
          if Map.get(outside_counts, shape_id, 0) == 0 do
            %{
              shape_id: shape_id,
              mode: :adopt,
              replaced: [
                %{
                  shape_id: shape_id,
                  trip_count: length(linked),
                  action: :adopted,
                  points: Map.get(shape_points, shape_id, [])
                }
              ],
              previous: previous,
              blockers: blockers
            }
          else
            allocate_plan(pattern, linked, outside_counts, shape_points, previous, blockers)
          end

        _ ->
          allocate_plan(pattern, linked, outside_counts, shape_points, previous, blockers)
      end
    end
  end

  defp allocate_plan(pattern, linked, outside_counts, shape_points, previous, blockers) do
    replaced =
      linked
      |> Enum.map(& &1.shape_id)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.reject(&(Map.get(outside_counts, &1, 0) > 0))
      |> Enum.map(fn shape_id ->
        %{
          shape_id: shape_id,
          trip_count: Enum.count(linked, &(&1.shape_id == shape_id)),
          action: :deleted,
          points: Map.get(shape_points, shape_id, [])
        }
      end)

    %{
      shape_id: first_unused_shape_id(pattern),
      mode: :allocate,
      replaced: replaced,
      previous: previous,
      blockers: blockers
    }
  end

  defp linked_trips(%RoutePattern{} = pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and
          t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id and
          t.pattern_derivation_state == "linked",
      order_by: [asc: t.trip_id],
      select: %{trip_id: t.trip_id, shape_id: t.shape_id}
    )
    |> Repo.all()
  end

  defp outside_shape_counts(%RoutePattern{} = pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and not is_nil(t.shape_id) and
          t.shape_id != "" and
          not (t.route_id == ^pattern.route_id and
                 t.route_pattern_id == ^pattern.route_pattern_id and
                 t.pattern_derivation_state == "linked"),
      group_by: t.shape_id,
      select: {t.shape_id, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp stop_time_observations(_pattern, []), do: {%{}, %{}}

  defp stop_time_observations(%RoutePattern{} = pattern, linked) do
    trip_ids = Enum.map(linked, & &1.trip_id)

    rows =
      from(st in StopTime,
        where:
          st.organization_id == ^pattern.organization_id and
            st.gtfs_version_id == ^pattern.gtfs_version_id and st.trip_id in ^trip_ids,
        order_by: [asc: st.trip_id, asc: st.stop_sequence],
        select: {st.trip_id, st.shape_dist_traveled}
      )
      |> Repo.all()

    grouped = Enum.group_by(rows, &elem(&1, 0), &elem(&1, 1))

    counts = Map.new(trip_ids, fn trip_id -> {trip_id, length(Map.get(grouped, trip_id, []))} end)
    vectors = Map.new(trip_ids, fn trip_id -> {trip_id, Map.get(grouped, trip_id, [])} end)

    {counts, vectors}
  end

  defp replaced_shape_points(_pattern, [], _outside_counts), do: %{}

  defp replaced_shape_points(%RoutePattern{} = pattern, linked, outside_counts) do
    shape_ids =
      linked
      |> Enum.map(& &1.shape_id)
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.uniq()
      |> Enum.reject(&(Map.get(outside_counts, &1, 0) > 0))

    if shape_ids == [] do
      %{}
    else
      from(s in Shape,
        where:
          s.organization_id == ^pattern.organization_id and
            s.gtfs_version_id == ^pattern.gtfs_version_id and s.shape_id in ^shape_ids,
        order_by: [asc: s.shape_id, asc: s.shape_pt_sequence],
        select: %{
          shape_id: s.shape_id,
          lat: s.shape_pt_lat,
          lon: s.shape_pt_lon,
          sequence: s.shape_pt_sequence,
          dist: s.shape_dist_traveled
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.shape_id, fn row ->
        [decimal_to_float(row.lat), decimal_to_float(row.lon), row.sequence, row.dist]
      end)
    end
  end

  defp first_unused_shape_id(%RoutePattern{} = pattern) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn
      1 -> unless shape_id_taken?(pattern, pattern.route_pattern_id), do: pattern.route_pattern_id
      n -> unless shape_id_taken?(pattern, "#{pattern.route_pattern_id}-#{n}"), do: "#{pattern.route_pattern_id}-#{n}"
    end)
  end

  defp shape_id_taken?(%RoutePattern{} = pattern, candidate) do
    Repo.exists?(
      from(s in Shape,
        where:
          s.organization_id == ^pattern.organization_id and
            s.gtfs_version_id == ^pattern.gtfs_version_id and s.shape_id == ^candidate
      )
    ) or
      Repo.exists?(
        from(p in RoutePattern,
          where:
            p.organization_id == ^pattern.organization_id and
              p.gtfs_version_id == ^pattern.gtfs_version_id and p.shape_id == ^candidate
        )
      )
  end

  defp previous_vectors(linked, visit_vectors) do
    linked
    |> Enum.group_by(fn %{trip_id: trip_id, shape_id: shape_id} ->
      {shape_id, Map.get(visit_vectors, trip_id, [])}
    end)
    |> Enum.map(fn {{shape_id, distances}, entries} ->
      %{shape_id: shape_id, trip_count: length(entries), visit_distances: distances}
    end)
    |> Enum.sort_by(fn %{shape_id: shape_id, visit_distances: distances} ->
      {shape_id || "", Enum.map(distances, &distance_key/1)}
    end)
  end

  defp distance_key(nil), do: ""
  defp distance_key(%Decimal{} = dist), do: Decimal.to_string(dist, :normal)

  defp materialization_blockers(pattern, visit_count, linked, stop_counts) do
    label = pattern_label(pattern)

    linked
    |> Enum.filter(fn %{trip_id: trip_id} -> Map.get(stop_counts, trip_id, 0) != visit_count end)
    |> Enum.sort_by(& &1.trip_id)
    |> Enum.map(fn %{trip_id: trip_id} ->
      %{
        route_pattern_id: pattern.route_pattern_id,
        pattern_label: label,
        trip_id: trip_id,
        stop_time_count: Map.get(stop_counts, trip_id, 0),
        visit_count: visit_count
      }
    end)
  end

  defp pattern_label(%RoutePattern{route_pattern_name: name})
       when is_binary(name) and name != "",
       do: name

  defp pattern_label(%RoutePattern{route_pattern_id: natural_id}), do: natural_id

  @doc """
  Materializes a complete pattern into its GTFS rows, in the current transaction.

  Call inside the apply transaction after the route, pattern and linked-trip
  locks are held (step 12 owns those locks). Rolls back with
  `{:blocked, blockers}` when the plan carries R13 trip blockers or the
  geometry rebuilds as blocked (INV-3); otherwise writes in order: the
  pattern's `shapes` rows under `plan.shape_id` (deleted, then chunked
  inserts of 1,000), per-visit `route_pattern_stops.shape_dist_traveled`,
  the pattern's `shape_id` and `alignment_digest`, linked trips' `shape_id`
  and `updated_at` (INV-4), and linked trips' stop-time distances by
  stop-sequence position. The positional update's affected-row count is
  rechecked against `visit_count * linked_trip_count` and rolls back with
  freshly derived blockers on mismatch. Replaced shapes with action
  `:deleted` lose their rows only when no trip in the version still
  references them (R11); the `pattern_shape` audit entry records the
  replaced shapes' prior points and the prior per-trip distance vectors
  (INV-5). Every read and write filters by the pattern's organization and
  version (INV-2); interiors stay `[lon, lat]` until `Materializer.build/2`
  writes the `shape_pt_lat` / `shape_pt_lon` columns (INV-1).
  """
  @spec materialize_pattern!(RoutePattern.t(), resolved(), shape_plan(), AuditContext.t()) :: %{
          shape_id: String.t(),
          trips_updated: non_neg_integer(),
          shapes_deleted: [String.t()]
        }
  def materialize_pattern!(
        %RoutePattern{} = pattern,
        %{visits: visits, sections: sections},
        %{shape_id: shape_id, blockers: plan_blockers, replaced: replaced, previous: previous},
        %AuditContext{} = audit_context
      ) do
    if plan_blockers != [] do
      Repo.rollback({:blocked, plan_blockers})
    end

    materializer_visits = Enum.map(visits, fn visit -> %{lat: visit.lat, lon: visit.lon} end)
    interiors = Enum.map(sections, & &1.points)

    built =
      case Materializer.build(materializer_visits, interiors) do
        {:ok, built} -> built
        {:error, {:blocked, _}} -> Repo.rollback({:blocked, plan_blockers})
      end

    %{points: points, visit_distances: visit_distances, digest: digest} = built

    now = DateTime.utc_now()
    visit_count = length(visits)

    rewrite_shape_rows!(pattern, shape_id, points, now)
    write_visit_distances!(pattern, visits, visit_distances, now)
    update_pattern_shape!(pattern, shape_id, digest, now)
    trips_updated = update_linked_trips!(pattern, shape_id, now)
    update_stop_time_distances!(pattern, visit_count, trips_updated, visit_distances)
    shapes_deleted = delete_replaced_shapes!(pattern, replaced)

    pattern_after = Repo.reload!(pattern)

    audit!(audit_context, :pattern_shape, pattern_after, "updated", %{
      before: %{
        shape_id: pattern.shape_id,
        alignment_digest: pattern.alignment_digest,
        replaced_shapes: audit_shapes(replaced),
        previous: audit_previous(previous)
      },
      after: %{
        shape_id: shape_id,
        alignment_digest: digest,
        visit_distances: Enum.map(visit_distances, &Decimal.to_string/1),
        point_count: length(points)
      }
    })

    %{shape_id: shape_id, trips_updated: trips_updated, shapes_deleted: shapes_deleted}
  end

  defp rewrite_shape_rows!(pattern, shape_id, points, now) do
    Repo.delete_all(
      from(s in Shape,
        where:
          s.organization_id == ^pattern.organization_id and
            s.gtfs_version_id == ^pattern.gtfs_version_id and
            s.shape_id == ^shape_id
      )
    )

    points
    |> Enum.map(fn %{sequence: sequence, lat: lat, lon: lon, dist: dist} ->
      %{
        organization_id: pattern.organization_id,
        gtfs_version_id: pattern.gtfs_version_id,
        shape_id: shape_id,
        shape_pt_lat: lat,
        shape_pt_lon: lon,
        shape_pt_sequence: sequence,
        shape_dist_traveled: dist,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(1_000)
    |> Enum.each(&Repo.insert_all(Shape, &1))

    :ok
  end

  defp write_visit_distances!(pattern, visits, visit_distances, now) do
    visits
    |> Enum.zip(visit_distances)
    |> Enum.each(fn {visit, dist} ->
      Repo.update_all(
        from(o in RoutePatternStop,
          where:
            o.id == ^visit.occurrence_id and
              o.organization_id == ^pattern.organization_id and
              o.gtfs_version_id == ^pattern.gtfs_version_id
        ),
        set: [shape_dist_traveled: dist, updated_at: now]
      )
    end)

    :ok
  end

  defp update_pattern_shape!(pattern, shape_id, digest, now) do
    Repo.update_all(
      from(p in RoutePattern,
        where:
          p.id == ^pattern.id and
            p.organization_id == ^pattern.organization_id and
            p.gtfs_version_id == ^pattern.gtfs_version_id
      ),
      set: [shape_id: shape_id, alignment_digest: digest, updated_at: now]
    )

    :ok
  end

  defp update_linked_trips!(pattern, shape_id, now) do
    {count, _} =
      Repo.update_all(
        from(t in Trip,
          where:
            t.organization_id == ^pattern.organization_id and
              t.gtfs_version_id == ^pattern.gtfs_version_id and
              t.route_id == ^pattern.route_id and
              t.route_pattern_id == ^pattern.route_pattern_id and
              t.pattern_derivation_state == "linked"
        ),
        set: [shape_id: shape_id, updated_at: now]
      )

    count
  end

  defp update_stop_time_distances!(pattern, visit_count, trips_updated, visit_distances) do
    positions = if visit_count > 0, do: Enum.to_list(1..visit_count), else: []

    %{num_rows: updated} =
      Repo.query!(
        """
        UPDATE stop_times AS st
        SET shape_dist_traveled = dists.dist, updated_at = NOW()
        FROM (
          SELECT s.id AS sid,
                 row_number() OVER (PARTITION BY s.trip_id ORDER BY s.stop_sequence) AS rn
          FROM stop_times AS s
          JOIN trips AS t
            ON t.organization_id = s.organization_id
           AND t.gtfs_version_id = s.gtfs_version_id
           AND t.trip_id = s.trip_id
          WHERE s.organization_id = $1
            AND s.gtfs_version_id = $2
            AND t.route_id = $3
            AND t.route_pattern_id = $4
            AND t.pattern_derivation_state = 'linked'
        ) AS ordered
        JOIN unnest($5::int[], $6::numeric[]) AS dists(rn, dist)
          ON dists.rn = ordered.rn
        WHERE st.id = ordered.sid
        """,
        [
          Ecto.UUID.dump!(pattern.organization_id),
          Ecto.UUID.dump!(pattern.gtfs_version_id),
          pattern.route_id,
          pattern.route_pattern_id,
          positions,
          visit_distances
        ]
      )

    if updated != visit_count * trips_updated do
      Repo.rollback({:blocked, stop_count_blockers!(pattern, visit_count)})
    end

    :ok
  end

  defp stop_count_blockers!(pattern, visit_count) do
    linked_ids =
      from(t in Trip,
        where:
          t.organization_id == ^pattern.organization_id and
            t.gtfs_version_id == ^pattern.gtfs_version_id and
            t.route_id == ^pattern.route_id and
            t.route_pattern_id == ^pattern.route_pattern_id and
            t.pattern_derivation_state == "linked",
        order_by: [asc: t.trip_id],
        select: t.trip_id
      )
      |> Repo.all()

    counts =
      if linked_ids == [] do
        %{}
      else
        from(st in StopTime,
          where:
            st.organization_id == ^pattern.organization_id and
              st.gtfs_version_id == ^pattern.gtfs_version_id and
              st.trip_id in ^linked_ids,
          group_by: st.trip_id,
          select: {st.trip_id, count(st.id)}
        )
        |> Repo.all()
        |> Map.new()
      end

    label = pattern_label(pattern)

    linked_ids
    |> Enum.filter(fn trip_id -> Map.get(counts, trip_id, 0) != visit_count end)
    |> Enum.map(fn trip_id ->
      %{
        route_pattern_id: pattern.route_pattern_id,
        pattern_label: label,
        trip_id: trip_id,
        stop_time_count: Map.get(counts, trip_id, 0),
        visit_count: visit_count
      }
    end)
  end

  defp delete_replaced_shapes!(pattern, replaced) do
    replaced
    |> Enum.filter(&(&1.action == :deleted))
    |> Enum.filter(fn %{shape_id: shape_id} ->
      not Repo.exists?(
        from(t in Trip,
          where:
            t.organization_id == ^pattern.organization_id and
              t.gtfs_version_id == ^pattern.gtfs_version_id and
              t.shape_id == ^shape_id
        )
      )
    end)
    |> Enum.map(fn %{shape_id: shape_id} ->
      Repo.delete_all(
        from(s in Shape,
          where:
            s.organization_id == ^pattern.organization_id and
              s.gtfs_version_id == ^pattern.gtfs_version_id and
              s.shape_id == ^shape_id
        )
      )

      shape_id
    end)
  end

  defp audit_shapes(replaced) do
    Enum.map(replaced, fn entry ->
      %{
        shape_id: entry.shape_id,
        trip_count: entry.trip_count,
        action: entry.action,
        points: Enum.map(entry.points, &audit_point/1)
      }
    end)
  end

  defp audit_point([lat, lon, sequence, dist]), do: [lat, lon, sequence, audit_decimal(dist)]
  defp audit_point(other), do: other

  defp audit_previous(previous) do
    Enum.map(previous, fn entry ->
      %{
        shape_id: entry.shape_id,
        trip_count: entry.trip_count,
        visit_distances: Enum.map(entry.visit_distances, &audit_decimal/1)
      }
    end)
  end

  defp audit_decimal(nil), do: nil
  defp audit_decimal(%Decimal{} = dist), do: Decimal.to_string(dist)
  defp audit_decimal(other), do: other

  defp audit!(audit_context, type, entity, action, attrs) do
    case Gtfs.record_change_in_transaction(audit_context, type, entity, action, attrs) do
      {:ok, log} -> log
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @type imported_shape :: %{
          shape_id: String.t(),
          trip_count: non_neg_integer(),
          points: [[float() | nil]],
          length_m: float(),
          visit_distances: [float() | nil] | nil
        }

  @type editor_model :: %{
          pattern: RoutePattern.t(),
          route_pattern_id: String.t(),
          route_id: String.t(),
          route_color: String.t(),
          visits: [visit()],
          sections: [section()],
          status: status(),
          digest: String.t() | nil,
          imported_shapes: [imported_shape()],
          export_summary: %{
            shape_id: String.t() | nil,
            linked_trip_count: non_neg_integer(),
            visit_count: non_neg_integer()
          }
        }

  @fallback_route_color "#334155"

  @doc """
  Loads the alignment editor read model for one pattern in its published route scope.

  Scopes through `RoutePatterns.published_route/3` and a scoped pattern query by
  natural `route_pattern_id`, without 01's stop-time fingerprint. Sections carry
  `shared_points` on overrides whose stop pair also has a shared path and
  `shared_users` (the distinct pattern count from `pair_users/4`) on shared
  sections. Consumed by `RoutePatternLive.handle_params/3` (step 20).
  """
  @spec editor(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, editor_model()} | {:error, :not_found}
  def editor(organization_id, gtfs_version_id, route_id, route_pattern_id) do
    with {:ok, route} <-
           RoutePatterns.published_route(organization_id, gtfs_version_id, route_id),
         %RoutePattern{} = pattern <-
           scoped_pattern(organization_id, gtfs_version_id, route_id, route_pattern_id) do
      resolved = resolve(pattern)
      sections = enrich_sections(organization_id, gtfs_version_id, resolved.sections)

      imported =
        imported_shapes(organization_id, gtfs_version_id, pattern, length(resolved.visits))

      linked_count = linked_trip_count(organization_id, gtfs_version_id, pattern)

      {:ok,
       %{
         pattern: pattern,
         route_pattern_id: pattern.route_pattern_id,
         route_id: pattern.route_id,
         route_color: route_color(route.route_color),
         visits: resolved.visits,
         sections: sections,
         status: resolved.status,
         digest: resolved.digest,
         imported_shapes: imported,
         export_summary: %{
           shape_id: pattern.shape_id,
           linked_trip_count: linked_count,
           visit_count: length(resolved.visits)
         }
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Returns the JSON-ready hook model for an `editor/4` result.

  Converts Decimals to floats and atoms to strings, keeps `[lon, lat]` axis
  order (INV-1), and takes `editable:` and `suggestions:` from opts.
  """
  @spec hook_model(editor_model(), keyword()) :: map()
  def hook_model(%{} = model, opts \\ []) do
    %{
      pattern_id: model.pattern.id,
      route_pattern_id: model.route_pattern_id,
      route_id: model.route_id,
      route_color: model.route_color,
      editable: Keyword.get(opts, :editable, false),
      export: to_string(model.status.export),
      visits: Enum.map(model.visits, &hook_visit/1),
      sections: Enum.map(model.sections, &hook_section/1),
      imported_shapes: Enum.map(model.imported_shapes, &hook_shape/1),
      export_summary: %{
        shape_id: model.export_summary.shape_id,
        linked_trip_count: model.export_summary.linked_trip_count,
        visit_count: model.export_summary.visit_count
      },
      suggestions: Keyword.get(opts, :suggestions, [])
    }
  end

  defp hook_visit(visit) do
    %{
      occurrence_id: visit.occurrence_id,
      position: visit.position,
      stop_id: visit.stop_id,
      name: visit.name,
      lat: visit.lat,
      lon: visit.lon,
      label: visit.label
    }
  end

  defp hook_section(section) do
    %{
      position: section.position,
      from_occurrence_id: section.from_occurrence_id,
      to_occurrence_id: section.to_occurrence_id,
      from_stop_id: section.from_stop_id,
      to_stop_id: section.to_stop_id,
      kind: to_string(section.kind),
      blocked_reason: hook_atom(section.blocked_reason),
      points: section.points,
      shared_points: section.shared_points,
      shared_users: section.shared_users,
      revision: %{
        segment_id: section.revision.segment_id,
        lock_version: section.revision.lock_version
      }
    }
  end

  defp hook_shape(shape) do
    %{
      shape_id: shape.shape_id,
      trip_count: shape.trip_count,
      points: Enum.map(shape.points, &Enum.map(&1, fn value -> hook_float(value) end)),
      length_m: shape.length_m,
      visit_distances: hook_float_list(shape.visit_distances)
    }
  end

  defp hook_atom(nil), do: nil
  defp hook_atom(atom) when is_atom(atom), do: to_string(atom)

  defp hook_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)
  defp hook_float(value), do: value

  defp hook_float_list(nil), do: nil
  defp hook_float_list(list), do: Enum.map(list, &hook_float/1)

  defp scoped_pattern(organization_id, gtfs_version_id, route_id, route_pattern_id) do
    from(p in RoutePattern,
      where:
        p.organization_id == ^organization_id and
          p.gtfs_version_id == ^gtfs_version_id and p.route_id == ^route_id and
          p.route_pattern_id == ^route_pattern_id
    )
    |> Repo.one()
  end

  defp enrich_sections(organization_id, gtfs_version_id, sections) do
    pairs =
      sections
      |> Enum.flat_map(fn
        %{kind: :override, from_stop_id: from, to_stop_id: to} -> [{from, to}]
        %{kind: :shared, from_stop_id: from, to_stop_id: to} -> [{from, to}]
        _ -> []
      end)
      |> Enum.uniq()

    shared_by_pair = load_shared_pairs(organization_id, gtfs_version_id, pairs)

    users_by_pair =
      Map.new(pairs, fn {from, to} = pair ->
        {pair, length(pair_users(organization_id, gtfs_version_id, from, to))}
      end)

    Enum.map(sections, fn section ->
      section = Map.put_new(section, :shared_points, nil)
      section = Map.put_new(section, :shared_users, nil)

      case section.kind do
        :override ->
          %{section | shared_points: Map.get(shared_by_pair, {section.from_stop_id, section.to_stop_id})}

        :shared ->
          %{section | shared_users: Map.get(users_by_pair, {section.from_stop_id, section.to_stop_id}, 0)}

        _ ->
          section
      end
    end)
  end

  defp load_shared_pairs(_organization_id, _gtfs_version_id, []), do: %{}

  defp load_shared_pairs(organization_id, gtfs_version_id, pairs) do
    froms = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    tos = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(pairs)

    from(seg in AlignmentSegment,
      where:
        seg.organization_id == ^organization_id and
          seg.gtfs_version_id == ^gtfs_version_id and is_nil(seg.from_occurrence_id) and
          seg.from_stop_id in ^froms and seg.to_stop_id in ^tos
    )
    |> Repo.all()
    |> Enum.filter(fn seg -> MapSet.member?(wanted, {seg.from_stop_id, seg.to_stop_id}) end)
    |> Map.new(fn seg -> {{seg.from_stop_id, seg.to_stop_id}, seg.points || []} end)
  end

  defp linked_trip_count(organization_id, gtfs_version_id, pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and
          t.gtfs_version_id == ^gtfs_version_id and t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id and
          t.pattern_derivation_state == "linked",
      select: count(t.id)
    )
    |> Repo.one()
  end

  defp imported_shapes(organization_id, gtfs_version_id, pattern, visit_count) do
    linked =
      from(t in Trip,
        where:
          t.organization_id == ^organization_id and
            t.gtfs_version_id == ^gtfs_version_id and t.route_id == ^pattern.route_id and
            t.route_pattern_id == ^pattern.route_pattern_id and
            t.pattern_derivation_state == "linked" and not is_nil(t.shape_id) and
            t.shape_id != "",
        order_by: [asc: t.shape_id, asc: t.trip_id]
      )
      |> Repo.all()

    linked
    |> Enum.group_by(& &1.shape_id)
    |> Enum.sort_by(fn {shape_id, _} -> shape_id end)
    |> Enum.map(fn {shape_id, trips} ->
      build_imported_shape(organization_id, gtfs_version_id, shape_id, trips, visit_count)
    end)
  end

  defp build_imported_shape(organization_id, gtfs_version_id, shape_id, trips, visit_count) do
    rows =
      from(s in Shape,
        where:
          s.organization_id == ^organization_id and
            s.gtfs_version_id == ^gtfs_version_id and s.shape_id == ^shape_id,
        order_by: [asc: s.shape_pt_sequence]
      )
      |> Repo.all()

    points =
      Enum.map(rows, fn row ->
        [decimal_to_float(row.shape_pt_lon), decimal_to_float(row.shape_pt_lat), row.shape_dist_traveled]
      end)

    lon_lat = Enum.map(points, fn [lon, lat, _] -> [lon, lat] end)

    representative = hd(trips)

    stop_times =
      from(st in StopTime,
        where:
          st.organization_id == ^organization_id and
            st.gtfs_version_id == ^gtfs_version_id and st.trip_id == ^representative.trip_id,
        order_by: [asc: st.stop_sequence]
      )
      |> Repo.all()

    visit_distances =
      if length(stop_times) == visit_count do
        Enum.map(stop_times, & &1.shape_dist_traveled)
      else
        nil
      end

    %{
      shape_id: shape_id,
      trip_count: length(trips),
      points: points,
      length_m: Materializer.length_m(lon_lat),
      visit_distances: visit_distances
    }
  end

  defp route_color(color) when is_binary(color) do
    if Regex.match?(~r/\A[0-9a-fA-F]{6}\z/, color) and relative_luminance(color) <= 0.85 do
      "#" <> color
    else
      @fallback_route_color
    end
  end

  defp route_color(_), do: @fallback_route_color

  defp relative_luminance(<<r::binary-2, g::binary-2, b::binary-2>>) do
    0.2126 * linear_channel(r) + 0.7152 * linear_channel(g) + 0.0722 * linear_channel(b)
  end

  defp linear_channel(hex) do
    channel = String.to_integer(hex, 16) / 255

    if channel <= 0.03928 do
      channel / 12.92
    else
      :math.pow((channel + 0.055) / 1.055, 2.4)
    end
  end

  defp load_visits(%RoutePattern{} = pattern) do
    rows =
      from(o in RoutePatternStop,
        where: o.route_pattern_id == ^pattern.id,
        order_by: [asc: o.position],
        left_join: s in Stop,
        on:
          s.organization_id == ^pattern.organization_id and
            s.gtfs_version_id == ^pattern.gtfs_version_id and s.stop_id == o.stop_id,
        select: %{
          occurrence_id: o.id,
          position: o.position,
          stop_id: o.stop_id,
          stop_name: s.stop_name,
          stop_lat: s.stop_lat,
          stop_lon: s.stop_lon
        }
      )
      |> Repo.all()

    positions_by_stop =
      rows
      |> Enum.group_by(& &1.stop_id, & &1.position)
      |> Map.new(fn {stop_id, positions} -> {stop_id, Enum.sort(positions)} end)

    Enum.map(rows, fn row ->
      label =
        positions_by_stop
        |> Map.fetch!(row.stop_id)
        |> Enum.map_join(" / ", &Integer.to_string/1)

      name =
        case row.stop_name do
          name when is_binary(name) and name != "" -> name
          _ -> row.stop_id
        end

      %{
        occurrence_id: row.occurrence_id,
        position: row.position,
        stop_id: row.stop_id,
        name: name,
        lat: decimal_to_float(row.stop_lat),
        lon: decimal_to_float(row.stop_lon),
        label: label
      }
    end)
  end

  defp decimal_to_float(nil), do: nil
  defp decimal_to_float(%Decimal{} = decimal), do: Decimal.to_float(decimal)

  defp load_overrides(_pattern, []), do: []

  defp load_overrides(%RoutePattern{} = pattern, occurrence_ids) do
    from(seg in AlignmentSegment,
      where:
        seg.organization_id == ^pattern.organization_id and
          seg.gtfs_version_id == ^pattern.gtfs_version_id and
          seg.from_occurrence_id in ^occurrence_ids
    )
    |> Repo.all()
  end

  defp load_shared(_pattern, []), do: []

  defp load_shared(%RoutePattern{} = pattern, from_stop_ids) do
    from(seg in AlignmentSegment,
      where:
        seg.organization_id == ^pattern.organization_id and
          seg.gtfs_version_id == ^pattern.gtfs_version_id and
          is_nil(seg.from_occurrence_id) and seg.from_stop_id in ^from_stop_ids
    )
    |> Repo.all()
  end

  defp initial_sections(visits, overrides_by_key, shared_by_pair) do
    visits
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index(1)
    |> Enum.map(fn {[from, to], position} ->
      base = %{
        position: position,
        from_occurrence_id: from.occurrence_id,
        to_occurrence_id: to.occurrence_id,
        from_stop_id: from.stop_id,
        to_stop_id: to.stop_id
      }

      case Map.get(overrides_by_key, {from.occurrence_id, to.stop_id}) do
        %AlignmentSegment{from_stop_id: stored_from} = segment
        when stored_from == from.stop_id ->
          Map.merge(base, %{
            kind: :override,
            blocked_reason: nil,
            points: segment.points || [],
            revision: %{segment_id: segment.id, lock_version: segment.lock_version}
          })

        _ ->
          case Map.get(shared_by_pair, {from.stop_id, to.stop_id}) do
            %AlignmentSegment{} = segment ->
              Map.merge(base, %{
                kind: :shared,
                blocked_reason: nil,
                points: segment.points || [],
                revision: %{segment_id: segment.id, lock_version: segment.lock_version}
              })

            nil ->
              Map.merge(base, %{
                kind: :missing,
                blocked_reason: nil,
                points: [],
                revision: %{segment_id: nil, lock_version: nil}
              })
          end
      end
    end)
  end

  defp build_status(%RoutePattern{} = pattern, sections, digest) do
    missing = Enum.count(sections, &(&1.kind == :missing))
    blocked = Enum.count(sections, &(&1.kind == :blocked))

    export =
      cond do
        present?(pattern.shape_id) ->
          if missing == 0 and blocked == 0 and not is_nil(digest) and
               digest == pattern.alignment_digest do
            :current
          else
            :stale
          end

        has_imported_shape?(pattern) ->
          :imported

        true ->
          :none
      end

    %{missing: missing, blocked: blocked, export: export}
  end

  defp present?(value) when is_binary(value) and value != "", do: true
  defp present?(_), do: false

  defp has_imported_shape?(%RoutePattern{} = pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and
          t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id and
          t.pattern_derivation_state == "linked" and not is_nil(t.shape_id),
      group_by: t.shape_id,
      select: t.shape_id
    )
    |> Repo.all()
    |> Enum.any?(fn shape_id -> is_binary(shape_id) and shape_id != "" end)
  end

  @type review_section :: %{
          position: pos_integer(),
          op: :set | :delete | :use_shared,
          action:
            :write_override | :write_shared | :choose_scope | :delete_override | :delete_shared,
          from_name: String.t(),
          to_name: String.t(),
          affected: [pair_user()],
          custom_unchanged: [pair_user()],
          shared_rematerialize: [
            %{
              route_pattern_id: String.t(),
              pattern_label: String.t(),
              route_label: String.t(),
              trips: non_neg_integer()
            }
          ],
          shared_blockers: [blocker()]
        }

  @type review :: %{
          fingerprint: String.t(),
          sections: [review_section()],
          origin: %{complete?: boolean(), plan: shape_plan() | nil},
          replaced_shapes: [
            %{shape_id: String.t(), trip_count: pos_integer(), action: :adopted | :deleted}
          ],
          requires_confirmation?: boolean(),
          blockers: [blocker()]
        }

  @doc """
  Reviews an alignment save without writing.

  Loads the pattern in its published route scope (INV-2), resolves it,
  normalizes the browser draft (`Draft.normalize/2`), rejects stale bases
  with `{:conflict, current_sections}` and stale identities with
  `:stale_stops` (R7), derives per-section R6 scope actions via
  `pair_users/4`, plans the origin shape when the save completes the pattern
  (R10/R11/R13), lists shared rematerializations with their blockers (R8),
  and fingerprints the whole review for step 12's `:stale_review` check.
  Read-only; step 12 owns the apply. Consumed by
  `RoutePatternAlignmentEvents` (step 28) through `Gtfs.review_alignment_save/3`.
  """
  @spec review_save(Ecto.UUID.t(), [map()], AuditContext.t()) ::
          {:ok, review()}
          | {:error,
             :not_found
             | :stale_stops
             | :invalid_input
             | {:conflict, [section()]}
             | {:invalid_draft, atom()}}
  def review_save(pattern_id, draft_params, %AuditContext{} = audit_context)
      when is_binary(pattern_id) do
    Repo.transaction(fn ->
      unless Keyword.get(Repo.config(), :pool) == Ecto.Adapters.SQL.Sandbox do
        Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
      end

      case compute_review(pattern_id, draft_params, audit_context) do
        {:ok, review, _ops, _resolved} -> {:ok, review}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> unwrap_review_transaction()
  end

  def review_save(_, _, _), do: {:error, :invalid_input}

  defp compute_review(pattern_id, draft_params, %AuditContext{} = audit_context) do
    with {:ok, route_id} <- review_route_id(pattern_id, audit_context),
         {:ok, _route} <-
           RoutePatterns.published_route(
             audit_context.organization_id,
             audit_context.gtfs_version_id,
             route_id
           ),
         %RoutePattern{} = pattern <- scoped_review_pattern(pattern_id, audit_context) do
      resolved = resolve(pattern)

      case Draft.normalize(draft_params, resolved) do
        {:error, reason} -> {:error, reason}
        # The ops carry the validated points step 12 writes, and the
        # resolved sections carry the stop-pair identity; the review shape
        # itself stays the step-10 contract.
        {:ok, ops} ->
          case build_review(pattern, resolved, ops, audit_context) do
            {:ok, review} -> {:ok, review, ops, resolved}
            {:error, _} = error -> error
          end
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_route_id(pattern_id, audit_context) do
    case Repo.one(
           from(p in RoutePattern,
             where:
               p.organization_id == ^audit_context.organization_id and
                 p.gtfs_version_id == ^audit_context.gtfs_version_id and
                 p.id == ^pattern_id,
             select: p.route_id
           )
         ) do
      nil -> {:error, :not_found}
      route_id -> {:ok, route_id}
    end
  end

  defp scoped_review_pattern(pattern_id, audit_context) do
    Repo.one(
      from(p in RoutePattern,
        where:
          p.organization_id == ^audit_context.organization_id and
            p.gtfs_version_id == ^audit_context.gtfs_version_id and
            p.id == ^pattern_id
      )
    )
  end

  defp unwrap_review_transaction({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap_review_transaction({:ok, {:error, reason}}), do: {:error, reason}
  defp unwrap_review_transaction({:error, reason}), do: {:error, reason}

  defp build_review(pattern, resolved, ops, audit_context) do
    sections_by_position = Map.new(resolved.sections, &{&1.position, &1})

    case check_review_bases(ops, sections_by_position) do
      {:error, _} = error ->
        error

      :ok ->
        org = audit_context.organization_id
        ver = audit_context.gtfs_version_id
        visits_by_position = Map.new(resolved.visits, &{&1.position, &1})
        users_by_pair = review_users_by_pair(org, ver, ops, sections_by_position)
        fallbacks = review_override_fallbacks(org, ver, ops, sections_by_position)

        review_sections =
          Enum.map(ops, fn op ->
            section = Map.fetch!(sections_by_position, op.position)

            build_review_section(
              op,
              section,
              visits_by_position,
              users_by_pair,
              pattern,
              audit_context
            )
          end)

        after_sections = apply_review_ops(resolved.sections, ops, fallbacks)
        complete? = Enum.all?(after_sections, &(&1.kind not in [:missing, :blocked]))
        plan = if complete?, do: shape_plan(pattern, length(resolved.visits)), else: nil
        blockers = if plan, do: plan.blockers, else: []

        replaced =
          if plan do
            Enum.map(plan.replaced, fn entry ->
              %{shape_id: entry.shape_id, trip_count: entry.trip_count, action: entry.action}
            end)
          else
            []
          end

        {:ok,
         %{
           fingerprint:
             review_fingerprint(pattern, resolved, ops, sections_by_position, review_sections, plan),
           sections: review_sections,
           origin: %{complete?: complete?, plan: plan},
           replaced_shapes: replaced,
           requires_confirmation?: replaced != [],
           blockers: blockers
         }}
    end
  end

  defp check_review_bases(ops, sections_by_position) do
    conflicted =
      Enum.filter(ops, fn op ->
        op.base != Map.fetch!(sections_by_position, op.position).revision
      end)

    if conflicted == [] do
      :ok
    else
      {:error,
       {:conflict, Enum.map(conflicted, &Map.fetch!(sections_by_position, &1.position))}}
    end
  end

  # "Other users" for a shared write is every pair_user plain visit except
  # this pattern's own position, including this pattern's other visits of the
  # same pair (R6). Patterns holding an override at the pair never change.
  defp split_review_users(users, origin_pattern_id, position) do
    affected =
      users
      |> Enum.map(fn user ->
        if user.pattern_id == origin_pattern_id do
          %{user | visit_positions: Enum.reject(user.visit_positions, &(&1 == position))}
        else
          user
        end
      end)
      |> Enum.filter(&(&1.visit_positions != []))

    {affected, Enum.filter(users, &(&1.custom_positions != []))}
  end

  defp review_users_by_pair(org, ver, ops, sections_by_position) do
    ops
    |> Enum.filter(fn op ->
      section = Map.fetch!(sections_by_position, op.position)
      (op.op == :set and section.kind in [:missing, :shared]) or
        (op.op == :delete and section.kind == :shared)
    end)
    |> Enum.map(fn op ->
      section = Map.fetch!(sections_by_position, op.position)
      {section.from_stop_id, section.to_stop_id}
    end)
    |> Enum.uniq()
    |> Map.new(fn {from, to} = pair -> {pair, pair_users(org, ver, from, to)} end)
  end

  defp review_override_fallbacks(org, ver, ops, sections_by_position) do
    pairs =
      ops
      |> Enum.filter(fn op ->
        section = Map.fetch!(sections_by_position, op.position)
        op.op in [:delete, :use_shared] and section.kind == :override
      end)
      |> Enum.map(fn op ->
        section = Map.fetch!(sections_by_position, op.position)
        {section.from_stop_id, section.to_stop_id}
      end)
      |> Enum.uniq()

    review_shared_points(org, ver, pairs)
  end

  defp review_shared_points(_org, _ver, []), do: %{}

  defp review_shared_points(org, ver, pairs) do
    froms = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    tos = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(pairs)

    from(seg in AlignmentSegment,
      where:
        seg.organization_id == ^org and
          seg.gtfs_version_id == ^ver and is_nil(seg.from_occurrence_id) and
          seg.from_stop_id in ^froms and seg.to_stop_id in ^tos
    )
    |> Repo.all()
    |> Enum.filter(fn seg -> MapSet.member?(wanted, {seg.from_stop_id, seg.to_stop_id}) end)
    |> Map.new(fn seg -> {{seg.from_stop_id, seg.to_stop_id}, seg.points || []} end)
  end

  defp build_review_section(op, section, visits_by_position, users_by_pair, pattern, audit_context) do
    base = %{
      position: op.position,
      op: op.op,
      from_name: Map.fetch!(visits_by_position, op.position).name,
      to_name: Map.fetch!(visits_by_position, op.position + 1).name,
      affected: [],
      custom_unchanged: [],
      shared_rematerialize: [],
      shared_blockers: []
    }

    case {op.op, section.kind} do
      {:set, :override} ->
        Map.put(base, :action, :write_override)

      {:delete, :override} ->
        Map.put(base, :action, :delete_override)

      {:use_shared, :override} ->
        Map.put(base, :action, :delete_override)

      {:set, kind} when kind in [:missing, :shared] ->
        users = Map.get(users_by_pair, {section.from_stop_id, section.to_stop_id}, [])
        {affected, custom} = split_review_users(users, pattern.id, op.position)
        action = if affected == [], do: :write_shared, else: :choose_scope
        {rematerialize, shared_blockers} = shared_review_effects(op, section, affected, pattern, audit_context)

        base
        |> Map.put(:action, action)
        |> Map.merge(%{affected: affected, custom_unchanged: custom, shared_rematerialize: rematerialize, shared_blockers: shared_blockers})

      {:delete, :shared} ->
        users = Map.get(users_by_pair, {section.from_stop_id, section.to_stop_id}, [])
        {affected, custom} = split_review_users(users, pattern.id, op.position)
        {rematerialize, shared_blockers} = shared_review_effects(op, section, affected, pattern, audit_context)

        base
        |> Map.put(:action, :delete_shared)
        |> Map.merge(%{affected: affected, custom_unchanged: custom, shared_rematerialize: rematerialize, shared_blockers: shared_blockers})
    end
  end

  # A shared write or delete re-materializes only affected patterns that
  # already own a shape and are complete with the proposed geometry
  # substituted (R8). Patterns on imported shapes keep them until their own
  # save. The origin pattern materializes as the origin, never here.
  defp shared_review_effects(op, section, affected, origin_pattern, audit_context) do
    affected
    |> Enum.filter(&(&1.owns_shape? and &1.pattern_id != origin_pattern.id))
    |> Enum.reduce({[], []}, fn user, {rematerialize, blockers} ->
      case rematerialize_review_candidate(user, section, op, audit_context) do
        nil -> {rematerialize, blockers}
        {entry, user_blockers} -> {[entry | rematerialize], blockers ++ user_blockers}
      end
    end)
    |> then(fn {rematerialize, blockers} -> {Enum.reverse(rematerialize), blockers} end)
  end

  defp rematerialize_review_candidate(user, section, op, audit_context) do
    with %RoutePattern{} = pattern <-
           scoped_review_pattern(user.pattern_id, audit_context),
         resolved <- resolve(pattern) do
      substituted = substitute_review_shared(resolved.sections, section, op)

      if Enum.all?(substituted, &(&1.kind not in [:missing, :blocked])) do
        plan = shape_plan(pattern, length(resolved.visits))

        entry = %{
          route_pattern_id: user.route_pattern_id,
          pattern_label: user.pattern_label,
          route_label: user.route_label,
          trips: user.linked_trip_count
        }

        {entry, plan.blockers}
      else
        nil
      end
    else
      _ -> nil
    end
  end

  defp substitute_review_shared(sections, changed, op) do
    Enum.map(sections, fn section ->
      if section.from_stop_id == changed.from_stop_id and section.to_stop_id == changed.to_stop_id and
           section.kind in [:shared, :missing] do
        case op.op do
          :set -> %{section | kind: :shared, blocked_reason: nil, points: op.points}
          :delete -> %{section | kind: :missing, blocked_reason: nil, points: []}
        end
      else
        section
      end
    end)
  end

  # Applies the drafted ops to the resolved sections in memory to decide
  # whether the origin pattern completes. A `:set` always resolves; a
  # `:delete` or `:use_shared` on an override falls back to the shared path
  # or to missing; a `:delete` on shared is missing.
  defp apply_review_ops(sections, ops, fallbacks) do
    ops_by_position = Map.new(ops, &{&1.position, &1})

    Enum.map(sections, fn section ->
      case Map.get(ops_by_position, section.position) do
        nil ->
          section

        %{op: :set} = op ->
          if section.kind == :override do
            %{section | kind: :override, blocked_reason: nil, points: op.points}
          else
            %{section | kind: :shared, blocked_reason: nil, points: op.points}
          end

        %{op: op} when op in [:delete, :use_shared] ->
          if section.kind == :override do
            case Map.get(fallbacks, {section.from_stop_id, section.to_stop_id}) do
              nil -> %{section | kind: :missing, blocked_reason: nil, points: []}
              points -> %{section | kind: :shared, blocked_reason: nil, points: points}
            end
          else
            %{section | kind: :missing, blocked_reason: nil, points: []}
          end
      end
    end)
  end

  defp review_fingerprint(pattern, resolved, ops, sections_by_position, review_sections, plan) do
    plan_part =
      if plan do
        {plan.shape_id, plan.mode, Enum.map(plan.replaced, & &1.shape_id)}
      else
        nil
      end

    rematerialized =
      review_sections
      |> Enum.flat_map(fn section ->
        Enum.map(section.shared_rematerialize, fn entry ->
          {entry.route_pattern_id, entry.pattern_label, entry.route_label, entry.trips}
        end)
      end)
      |> Enum.sort()
      |> Enum.uniq()

    term = {
      pattern.id,
      Enum.map(resolved.visits, &{&1.occurrence_id, &1.stop_id, &1.position}),
      Enum.map(
        ops,
        &{&1.position, &1.op, &1.points, &1.base.segment_id, &1.base.lock_version,
         &1.from_occurrence_id, &1.to_stop_id}
      ),
      Enum.map(ops, fn op ->
        revision = Map.fetch!(sections_by_position, op.position).revision
        {op.position, revision.segment_id, revision.lock_version}
      end),
      Enum.map(review_sections, fn section ->
        {section.position, section.action,
         Enum.map(section.affected, &{&1.pattern_id, &1.visit_positions, &1.custom_positions, &1.owns_shape?}),
         Enum.map(section.custom_unchanged, &{&1.pattern_id, &1.visit_positions, &1.custom_positions, &1.owns_shape?})}
      end),
      plan_part,
      rematerialized
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(review_canonical(term), [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp review_canonical(%Decimal{} = value), do: {:decimal, Decimal.to_string(value, :normal)}
  defp review_canonical(%_{} = value), do: value |> Map.from_struct() |> review_canonical()

  defp review_canonical(value) when is_map(value) and not is_struct(value) do
    value
    |> Enum.map(fn {key, val} -> {to_string(key), review_canonical(val)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp review_canonical(value) when is_list(value), do: Enum.map(value, &review_canonical/1)

  defp review_canonical(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&review_canonical/1) |> List.to_tuple()
  end

  defp review_canonical(value), do: value

  @apply_attempts 3

  # Unique violations worth one fresh snapshot: the two alignment segment
  # indexes, the owned-shape index and the shapes identity index (R7).
  @apply_retry_constraints ~w(
    alignment_segments_shared_pair_index
    alignment_segments_override_visit_index
    route_patterns_owned_shape_index
    shapes_organization_id_gtfs_version_id_shape_id_shape_pt_sequence_index
  )

  @apply_retry_marker :alignment_apply_retry

  @doc """
  Applies a reviewed alignment save transactionally (R6/R7/R8/R12/R13).

  Recomputes `review_save/3` inside a SERIALIZABLE `ReviewedApplyTransaction`
  transaction, compares the fingerprint in constant time (`:stale_review` on
  mismatch), validates the scope/confirmation choices (`:missing_scope` /
  `:confirmation_required`), locks the origin and re-materialized routes
  (`FOR UPDATE` in `route_id` order), their patterns (in id order) and their
  linked trips (in id order), writes the segment rows with one
  `:alignment_segment` audit entry each, then materializes the origin when
  it is complete and each affected shape-owning pattern that is complete
  afterwards (R8). A differing base returns `{:conflict, current_sections}`
  and a changed identity `:stale_stops`, both with no writes; trip-count
  mismatches roll the whole save back with `{:blocked, blockers}` (R13).
  Serialization failures (`40001`), deadlocks (`40P01`) and unique
  violations (`23505`) on the alignment and shape indexes retry with a
  fresh snapshot up to three times, then return `:busy`. There is no
  advisory lock (CR-3).

  Callers pass the `draft_params` and `fingerprint` from `review_save/3`
  plus `choices` of `%{"scopes" => %{position => "local" | "shared"},
  "confirm_replacements" => boolean()}`. Consumed by
  `RoutePatternAlignmentEvents` (step 28) through
  `Gtfs.apply_alignment_save/5`.
  """
  @spec apply_save(Ecto.UUID.t(), [map()], map() | nil, String.t(), AuditContext.t()) ::
          {:ok,
           %{
             materialized: [String.t()],
             trips_updated: non_neg_integer(),
             shapes_deleted: [String.t()],
             segments_written: non_neg_integer()
           }}
          | {:error,
             :not_found
             | :stale_stops
             | :stale_review
             | :busy
             | :missing_scope
             | :confirmation_required
             | :invalid_input
             | {:conflict, [section()]}
             | {:blocked, [blocker()]}
             | {:invalid_draft, atom()}}
  def apply_save(pattern_id, draft_params, choices, fingerprint, %AuditContext{} = audit_context)
      when is_binary(pattern_id) do
    apply_with_retries(pattern_id, draft_params, choices, fingerprint, audit_context, @apply_attempts)
  end

  def apply_save(_, _, _, _, _), do: {:error, :invalid_input}

  defp apply_transaction_runner do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )
  end

  defp apply_with_retries(pattern_id, draft_params, choices, fingerprint, audit_context, attempts) do
    result =
      try do
        apply_transaction_runner().run(fn ->
          apply_transaction(pattern_id, draft_params, choices, fingerprint, audit_context)
        end)
      rescue
        error in [Postgrex.Error, Ecto.ConstraintError, Ecto.StaleEntryError] ->
          {:apply_raised, error, __STACKTRACE__}
      end

    case result do
      {:ok, applied} ->
        {:ok, applied}

      {:error, @apply_retry_marker} ->
        if attempts > 1 do
          apply_with_retries(pattern_id, draft_params, choices, fingerprint, audit_context, attempts - 1)
        else
          {:error, :busy}
        end

      {:error, _} = error ->
        error

      {:apply_raised, error, stacktrace} ->
        cond do
          apply_retryable?(error) and attempts > 1 ->
            apply_with_retries(pattern_id, draft_params, choices, fingerprint, audit_context, attempts - 1)

          apply_retryable?(error) ->
            {:error, :busy}

          true ->
            reraise(error, stacktrace)
        end
    end
  end

  # A SERIALIZABLE race surfaces as 40001/40P01, as a unique violation on
  # one of the four apply indexes, or as a stale optimistic lock on the
  # same lost race. Each retries with a fresh snapshot, where the
  # recomputed review surfaces the race as a conflict or stale review.
  defp apply_retryable?(%Postgrex.Error{postgres: %{code: code} = fields}) do
    cond do
      code in [:serialization_failure, "40001", :deadlock_detected, "40P01"] -> true
      code in [:unique_violation, "23505"] ->
        to_string(Map.get(fields, :constraint, "")) in @apply_retry_constraints
      true -> false
    end
  end

  defp apply_retryable?(%Postgrex.Error{}), do: false

  defp apply_retryable?(%Ecto.ConstraintError{constraint: constraint}),
    do: to_string(constraint) in @apply_retry_constraints

  defp apply_retryable?(%Ecto.StaleEntryError{}), do: true
  defp apply_retryable?(_), do: false

  defp apply_transaction(pattern_id, draft_params, choices, fingerprint, audit_context) do
    case compute_review(pattern_id, draft_params, audit_context) do
      {:error, reason} ->
        Repo.rollback(reason)

      {:ok, review, ops, resolved} ->
        with :ok <- verify_apply_fingerprint(review.fingerprint, fingerprint),
             {:ok, decisions} <- apply_decisions(review, choices) do
          execute_apply(pattern_id, review, ops, resolved, decisions, audit_context)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp verify_apply_fingerprint(expected, actual) do
    if secure_equal?(expected, actual), do: :ok, else: {:error, :stale_review}
  end

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Plug.Crypto.secure_compare(left, right)

  defp secure_equal?(_, _), do: false

  # Validates the dialog choices against the fresh review: every
  # `:choose_scope` position needs a `"local"`/`"shared"` scope, every
  # `:delete_shared` position that others still use needs `"shared"`, and
  # a review that replaces imported shapes needs `confirm_replacements`.
  # Returns the per-position decision (`:local`, `:shared` or `:direct`).
  defp apply_decisions(review, choices) do
    scopes = apply_scopes(choices)
    confirm? = apply_confirmed?(choices)

    result =
      Enum.reduce_while(review.sections, {:ok, %{}}, fn section, {:ok, decisions} ->
        case apply_section_decision(section, scopes) do
          {:error, _} = error -> {:halt, error}
          {:ok, decision} -> {:cont, {:ok, Map.put(decisions, section.position, decision)}}
        end
      end)

    case result do
      {:error, _} = error -> error
      {:ok, decisions} ->
        if review.requires_confirmation? and not confirm?,
          do: {:error, :confirmation_required},
          else: {:ok, decisions}
    end
  end

  defp apply_scopes(choices) when is_map(choices) do
    raw = Map.get(choices, "scopes", Map.get(choices, :scopes, %{}))

    if is_map(raw) do
      Map.new(raw, fn {key, value} -> {apply_scope_key(key), apply_scope_value(value)} end)
    else
      %{}
    end
  end

  defp apply_scopes(_), do: %{}

  defp apply_scope_key(key) when is_integer(key), do: key

  defp apply_scope_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {position, ""} -> position
      _ -> :drop
    end
  end

  defp apply_scope_key(key) when is_atom(key) do
    key |> Atom.to_string() |> apply_scope_key()
  end

  defp apply_scope_key(_), do: :drop

  defp apply_scope_value("local"), do: :local
  defp apply_scope_value(:local), do: :local
  defp apply_scope_value("shared"), do: :shared
  defp apply_scope_value(:shared), do: :shared
  defp apply_scope_value(_), do: :invalid

  defp apply_confirmed?(choices) when is_map(choices) do
    Map.get(choices, "confirm_replacements", Map.get(choices, :confirm_replacements, false)) == true
  end

  defp apply_confirmed?(_), do: false

  defp apply_section_decision(%{action: :choose_scope, position: position}, scopes) do
    case Map.get(scopes, position, :missing) do
      :local -> {:ok, :local}
      :shared -> {:ok, :shared}
      _ -> {:error, :missing_scope}
    end
  end

  defp apply_section_decision(%{action: :delete_shared, affected: affected, position: position}, scopes) do
    cond do
      affected == [] -> {:ok, :direct}
      Map.get(scopes, position, :missing) == :shared -> {:ok, :shared}
      true -> {:error, :missing_scope}
    end
  end

  defp apply_section_decision(_section, _scopes), do: {:ok, :direct}

  defp execute_apply(pattern_id, review, ops, resolved, decisions, audit_context) do
    origin_route_id =
      case review_route_id(pattern_id, audit_context) do
        {:ok, route_id} -> route_id
        {:error, reason} -> Repo.rollback(reason)
      end

    targets = apply_shared_targets(pattern_id, review, decisions)

    route_ids =
      ([origin_route_id | Enum.map(targets, &elem(&1, 1))] |> Enum.uniq() |> Enum.sort())

    routes =
      Map.new(route_ids, fn route_id ->
        {route_id, RoutePatterns.lock_published_route!(audit_context, route_id)}
      end)

    route_for = Map.new(targets, fn {id, route_id} -> {id, route_id} end)
    route_for = Map.put(route_for, pattern_id, origin_route_id)

    pattern_ids = ([pattern_id | Enum.map(targets, &elem(&1, 0))] |> Enum.uniq() |> Enum.sort())

    locked =
      Map.new(pattern_ids, fn id ->
        {id, RoutePatterns.lock_pattern!(Map.fetch!(routes, Map.fetch!(route_for, id)), id)}
      end)

    Enum.each(pattern_ids, fn id -> lock_apply_trips!(Map.fetch!(locked, id)) end)

    sections_by_position = Map.new(review.sections, &{&1.position, &1})
    resolved_by_position = Map.new(resolved.sections, &{&1.position, &1})
    locked_origin = Map.fetch!(locked, pattern_id)

    segments_written =
      ops
      |> Enum.sort_by(& &1.position)
      |> Enum.reduce(0, fn op, count ->
        section = Map.fetch!(sections_by_position, op.position)
        resolved_section = Map.fetch!(resolved_by_position, op.position)

        count +
          apply_section_write!(
            op,
            section,
            resolved_section,
            Map.fetch!(decisions, op.position),
            audit_context,
            locked_origin
          )
      end)

    {materialized, trips_updated, shapes_deleted} =
      apply_materializations(pattern_id, pattern_ids, locked, audit_context)

    %{
      materialized: materialized,
      trips_updated: trips_updated,
      shapes_deleted: shapes_deleted,
      segments_written: segments_written
    }
  end

  # Rematerialization candidates are the affected shape-owning patterns of
  # sections whose decision actually writes or deletes the shared row. The
  # origin rematerializes through its own path, never here.
  defp apply_shared_targets(origin_id, review, decisions) do
    review.sections
    |> Enum.filter(&(Map.get(decisions, &1.position) == :shared))
    |> Enum.flat_map(& &1.affected)
    |> Enum.filter(&(&1.owns_shape? and &1.pattern_id != origin_id))
    |> Enum.map(&{&1.pattern_id, &1.route_id})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp lock_apply_trips!(%RoutePattern{} = pattern) do
    from(t in Trip,
      where:
        t.organization_id == ^pattern.organization_id and
          t.gtfs_version_id == ^pattern.gtfs_version_id and
          t.route_id == ^pattern.route_id and
          t.route_pattern_id == ^pattern.route_pattern_id,
      order_by: [asc: t.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()

    :ok
  end

  defp apply_section_write!(op, section, resolved_section, decision, audit_context, locked_origin) do
    case {op.op, section.action, decision} do
      {:set, :write_override, _} ->
        write_override_segment!(op, resolved_section, audit_context, locked_origin)

      {:set, :choose_scope, :local} ->
        write_override_segment!(op, resolved_section, audit_context, locked_origin)

      {:set, :write_shared, _} ->
        write_shared_segment!(resolved_section, op.points, audit_context, locked_origin)

      {:set, :choose_scope, :shared} ->
        write_shared_segment!(resolved_section, op.points, audit_context, locked_origin) +
          delete_override_segment!(op, audit_context, locked_origin)

      {op_name, :delete_override, _} when op_name in [:delete, :use_shared] ->
        delete_override_segment!(op, audit_context, locked_origin)

      {:delete, :delete_shared, _} ->
        delete_shared_segment!(resolved_section, audit_context, locked_origin)

      _ ->
        Repo.rollback({:invalid_draft, :unsupported_op})
    end
  end

  defp fetch_shared_segment(audit_context, from_stop_id, to_stop_id) do
    Repo.one(
      from(s in AlignmentSegment,
        where:
          s.organization_id == ^audit_context.organization_id and
            s.gtfs_version_id == ^audit_context.gtfs_version_id and
            is_nil(s.from_occurrence_id) and s.from_stop_id == ^from_stop_id and
            s.to_stop_id == ^to_stop_id
      )
    )
  end

  defp fetch_override_segment(audit_context, occurrence_id, to_stop_id) do
    Repo.one(
      from(s in AlignmentSegment,
        where:
          s.organization_id == ^audit_context.organization_id and
            s.gtfs_version_id == ^audit_context.gtfs_version_id and
            s.from_occurrence_id == ^occurrence_id and s.to_stop_id == ^to_stop_id
      )
    )
  end

  defp write_shared_segment!(section, points, audit_context, locked_origin) do
    case fetch_shared_segment(audit_context, section.from_stop_id, section.to_stop_id) do
      nil ->
        %AlignmentSegment{
          organization_id: audit_context.organization_id,
          gtfs_version_id: audit_context.gtfs_version_id,
          from_stop_id: section.from_stop_id,
          to_stop_id: section.to_stop_id
        }
        |> AlignmentSegment.changeset(%{points: points})
        |> Repo.insert()
        |> case do
          {:ok, segment} ->
            audit!(audit_context, :alignment_segment, segment, "created", %{
              before: nil,
              after: apply_segment_after(segment)
            })

            1

          {:error, changeset} ->
            apply_segment_error!(changeset, audit_context, locked_origin)
        end

      %{points: current} when current == points ->
        0

      existing ->
        before = apply_segment_before(existing)

        existing
        |> AlignmentSegment.changeset(%{points: points})
        |> Repo.update()
        |> case do
          {:ok, segment} ->
            audit!(audit_context, :alignment_segment, segment, "updated", %{
              before: before,
              after: apply_segment_after(segment)
            })

            1

          {:error, changeset} ->
            apply_segment_error!(changeset, audit_context, locked_origin)
        end
    end
  end

  # An override upsert heals a stale-identity row for the same visit and
  # target: the unique index allows only one row per visit, so a lingering
  # row takes the current stop pair and points instead of conflicting.
  defp write_override_segment!(op, section, audit_context, locked_origin) do
    case fetch_override_segment(audit_context, op.from_occurrence_id, op.to_stop_id) do
      nil ->
        %AlignmentSegment{
          organization_id: audit_context.organization_id,
          gtfs_version_id: audit_context.gtfs_version_id,
          from_stop_id: section.from_stop_id,
          to_stop_id: section.to_stop_id,
          from_occurrence_id: op.from_occurrence_id
        }
        |> AlignmentSegment.changeset(%{points: op.points})
        |> Repo.insert()
        |> case do
          {:ok, segment} ->
            audit!(audit_context, :alignment_segment, segment, "created", %{
              before: nil,
              after: apply_segment_after(segment)
            })

            1

          {:error, changeset} ->
            apply_segment_error!(changeset, audit_context, locked_origin)
        end

      %{points: current, from_stop_id: stored}
      when current == op.points and stored == section.from_stop_id ->
        0

      existing ->
        before = apply_segment_before(existing)

        %{existing | from_stop_id: section.from_stop_id}
        |> AlignmentSegment.changeset(%{points: op.points})
        |> Repo.update()
        |> case do
          {:ok, segment} ->
            audit!(audit_context, :alignment_segment, segment, "updated", %{
              before: before,
              after: apply_segment_after(segment)
            })

            1

          {:error, changeset} ->
            apply_segment_error!(changeset, audit_context, locked_origin)
        end
    end
  end

  defp delete_shared_segment!(section, audit_context, _locked_origin) do
    case fetch_shared_segment(audit_context, section.from_stop_id, section.to_stop_id) do
      nil ->
        0

      existing ->
        before = apply_segment_before(existing)

        case Repo.delete(existing) do
          {:ok, segment} ->
            audit!(audit_context, :alignment_segment, segment, "deleted", %{
              before: before,
              after: nil
            })

            1

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  defp delete_override_segment!(op, audit_context, _locked_origin) do
    case fetch_override_segment(audit_context, op.from_occurrence_id, op.to_stop_id) do
      nil ->
        0

      existing ->
        before = apply_segment_before(existing)

        case Repo.delete(existing) do
          {:ok, segment} ->
            audit!(audit_context, :alignment_segment, segment, "deleted", %{
              before: before,
              after: nil
            })

            1

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
    end
  end

  # A duplicate pair inside the transaction is the lost-race retry marker;
  # any other segment validation failure (unreachable after `Draft`) rolls
  # back as a conflict against the freshly resolved sections.
  defp apply_segment_error!(changeset, _audit_context, locked_origin) do
    if apply_unique_retry?(changeset) do
      Repo.rollback(@apply_retry_marker)
    else
      Repo.rollback({:conflict, resolve(locked_origin).sections})
    end
  end

  defp apply_unique_retry?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        to_string(Keyword.get(opts, :constraint_name, "")) in @apply_retry_constraints
    end)
  end

  defp apply_segment_before(segment) do
    %{points: segment.points, lock_version: segment.lock_version}
  end

  defp apply_segment_after(segment) do
    %{points: segment.points, lock_version: segment.lock_version}
  end

  # Materializes the origin first, then each locked candidate that still
  # resolves completely after the writes; incomplete patterns keep their
  # trip shape references and distances byte-for-byte (INV-3). A candidate
  # with trip-count blockers rolls the whole save back (R13).
  defp apply_materializations(origin_id, pattern_ids, locked, audit_context) do
    {materialized, trips_updated, shapes_deleted} =
      apply_materialize_one(Map.fetch!(locked, origin_id), audit_context, {[], 0, []})

    {materialized, trips_updated, shapes_deleted} =
      Enum.reduce(pattern_ids, {materialized, trips_updated, shapes_deleted}, fn id, acc ->
        if id == origin_id do
          acc
        else
          apply_materialize_one(Map.fetch!(locked, id), audit_context, acc)
        end
      end)

    {Enum.reverse(materialized), trips_updated, shapes_deleted}
  end

  defp apply_materialize_one(pattern, audit_context, {materialized, trips_updated, shapes_deleted}) do
    resolved = resolve(pattern)

    if Enum.all?(resolved.sections, &(&1.kind not in [:missing, :blocked])) do
      plan = shape_plan(pattern, length(resolved.visits))
      result = materialize_pattern!(pattern, resolved, plan, audit_context)

      {
        [pattern.route_pattern_id | materialized],
        trips_updated + result.trips_updated,
        shapes_deleted ++ result.shapes_deleted
      }
    else
      {materialized, trips_updated, shapes_deleted}
    end
  end
end

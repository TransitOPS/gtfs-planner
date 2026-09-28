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
  """

  import Ecto.Query

  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Alignments.Materializer
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
end

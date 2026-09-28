defmodule GtfsPlanner.Gtfs.Alignments do
  @moduledoc """
  Resolves a pattern's visit-pair sections and export status.

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
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Stop
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

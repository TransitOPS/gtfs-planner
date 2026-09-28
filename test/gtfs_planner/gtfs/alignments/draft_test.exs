defmodule GtfsPlanner.Gtfs.Alignments.DraftTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Alignments.Draft

  defp section(position, kind, opts \\ []) do
    %{
      position: position,
      from_occurrence_id: "occ-#{position}",
      to_occurrence_id: "occ-#{position + 1}",
      from_stop_id: "S#{position}",
      to_stop_id: "S#{position + 1}",
      kind: kind,
      blocked_reason: Keyword.get(opts, :blocked_reason),
      points: [],
      revision:
        Keyword.get(opts, :revision, %{segment_id: "seg-#{position}", lock_version: 1})
    }
  end

  defp resolved(sections, status \\ %{missing: 0, blocked: 0, export: :stale}) do
    %{pattern: %{}, visits: [], sections: sections, status: status, digest: nil}
  end

  defp four_sections do
    [
      section(1, :shared),
      section(2, :override),
      section(3, :override),
      %{section(4, :missing) | revision: %{segment_id: nil, lock_version: nil}}
    ]
  end

  defp entry(position, op, extra \\ %{}) do
    Map.merge(
      %{
        "position" => position,
        "from_occurrence_id" => "occ-#{position}",
        "to_stop_id" => "S#{position + 1}",
        "op" => op,
        "base" => %{"segment_id" => "seg-#{position}", "lock_version" => 1}
      },
      extra
    )
  end

  test "a valid mixed draft returns ops with atoms, float points and parsed bases" do
    draft = [
      entry(1, "set", %{"points" => [[-74, 40.7], [-73.9, 40.72]]}),
      entry(2, "delete"),
      entry(3, "use_shared")
    ]

    assert {:ok, ops} = Draft.normalize(draft, resolved(four_sections()))
    assert Enum.map(ops, & &1.op) == [:set, :delete, :use_shared]
    assert Enum.map(ops, & &1.position) == [1, 2, 3]

    [set_op, delete_op, shared_op] = ops
    assert set_op.points == [[-74.0, 40.7], [-73.9, 40.72]]
    assert Enum.all?(set_op.points, fn [lon, lat] -> is_float(lon) and is_float(lat) end)
    assert set_op.base == %{segment_id: "seg-1", lock_version: 1}
    assert delete_op.points == []
    assert shared_op.base == %{segment_id: "seg-3", lock_version: 1}
    assert shared_op.from_occurrence_id == "occ-3"
    assert shared_op.to_stop_id == "S4"
  end

  test "a missing op is malformed" do
    draft = [entry(1, "set", %{"points" => []}) |> Map.delete("op")]

    assert Draft.normalize(draft, resolved(four_sections())) ==
             {:error, {:invalid_draft, :malformed}}
  end

  test "an unknown op string is malformed" do
    assert Draft.normalize([entry(1, "overwrite")], resolved(four_sections())) ==
             {:error, {:invalid_draft, :malformed}}
  end

  test "a string coordinate is malformed" do
    draft = [entry(1, "set", %{"points" => [["-74.0", 40.7]]})]

    assert Draft.normalize(draft, resolved(four_sections())) ==
             {:error, {:invalid_draft, :malformed}}
  end

  test "a position outside the resolved sections is unknown" do
    assert Draft.normalize([entry(9, "delete")], resolved(four_sections())) ==
             {:error, {:invalid_draft, :unknown_section}}
  end

  test "a repeated position is a duplicate" do
    draft = [entry(2, "delete"), entry(2, "delete")]

    assert Draft.normalize(draft, resolved(four_sections())) ==
             {:error, {:invalid_draft, :duplicate_section}}
  end

  test "more than 5,000 points in one section is too many" do
    points = Enum.map(1..5_001, fn _ -> [0.0, 0.0] end)
    draft = [entry(1, "set", %{"points" => points})]

    assert Draft.normalize(draft, resolved(four_sections())) ==
             {:error, {:invalid_draft, :too_many_points}}
  end

  test "more than 50,000 points across sections is too many" do
    sections = Enum.map(1..11, fn pos -> section(pos, :shared) end)
    draft = Enum.map(1..10, fn pos -> entry(pos, "set", %{"points" => points(5_000)}) end) ++
      [entry(11, "set", %{"points" => [[0.0, 0.0]]})]

    assert Draft.normalize(draft, resolved(sections)) ==
             {:error, {:invalid_draft, :too_many_points}}
  end

  test "a latitude outside range is out of range" do
    draft = [entry(1, "set", %{"points" => [[-74.0, 95.0]]})]

    assert Draft.normalize(draft, resolved(four_sections())) ==
             {:error, {:invalid_draft, :out_of_range}}
  end

  test "setting a blocked section is blocked" do
    sections = [%{section(1, :blocked, blocked_reason: :no_coordinates) | points: [[1.0, 2.0]]}]
    draft = [entry(1, "set", %{"points" => [[1.0, 2.0]]})]

    assert Draft.normalize(draft, resolved(sections)) ==
             {:error, {:invalid_draft, :blocked_section}}
  end

  test "deleting a missing section and sharing a shared section are invalid ops" do
    assert Draft.normalize([entry(4, "delete")], resolved(four_sections())) ==
             {:error, {:invalid_draft, :invalid_op}}

    assert Draft.normalize([entry(1, "use_shared")], resolved(four_sections())) ==
             {:error, {:invalid_draft, :invalid_op}}
  end

  test "a changed from_occurrence_id or to_stop_id is stale" do
    from_changed = [entry(2, "delete", %{"from_occurrence_id" => "occ-other"})]

    assert Draft.normalize(from_changed, resolved(four_sections())) == {:error, :stale_stops}

    to_changed = [entry(2, "delete", %{"to_stop_id" => "S-other"})]

    assert Draft.normalize(to_changed, resolved(four_sections())) == {:error, :stale_stops}
  end

  test "an empty draft is empty for incomplete and current patterns" do
    incomplete = resolved(four_sections(), %{missing: 1, blocked: 0, export: :stale})
    assert Draft.normalize([], incomplete) == {:error, {:invalid_draft, :empty}}

    current = resolved(four_sections(), %{missing: 0, blocked: 0, export: :current})
    assert Draft.normalize([], current) == {:error, {:invalid_draft, :empty}}
  end

  test "an empty draft is ok for a complete pattern awaiting materialization" do
    stale = resolved(four_sections(), %{missing: 0, blocked: 0, export: :stale})
    assert Draft.normalize([], stale) == {:ok, []}

    imported = resolved(four_sections(), %{missing: 0, blocked: 0, export: :imported})
    assert Draft.normalize([], imported) == {:ok, []}
  end

  defp points(count), do: Enum.map(1..count, fn _ -> [0.0, 0.0] end)
end

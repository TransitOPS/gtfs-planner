defmodule GtfsPlanner.Gtfs.Routes.SourceTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Routes

  # Pure contract tests: compare_edit/4 is called directly with independently
  # listed base/current/draft maps; no database test double establishes merge
  # correctness.

  @route_uuid "11111111-1111-1111-1111-111111111111"
  @organization_id "22222222-2222-2222-2222-222222222222"
  @gtfs_version_id "33333333-3333-3333-3333-333333333333"
  @updated_at ~U[2026-01-01 00:00:00.000000Z]

  defp identity(overrides \\ %{}) do
    Map.merge(
      %{
        organization_id: @organization_id,
        gtfs_version_id: @gtfs_version_id,
        route_uuid: @route_uuid,
        route_id: "R1"
      },
      overrides
    )
  end

  defp base do
    Map.merge(
      identity(),
      %{
        route_short_name: "32",
        route_long_name: "Original",
        route_type: 3,
        route_color: "0000ff",
        route_text_color: "AABBCC",
        route_sort_order: 7
      }
    )
  end

  defp persisted_route(overrides \\ %{}) do
    struct(
      %Route{
        id: @route_uuid,
        organization_id: @organization_id,
        gtfs_version_id: @gtfs_version_id,
        route_id: "R1",
        route_short_name: "32",
        route_long_name: "Original",
        route_type: 3,
        route_color: "0000ff",
        route_text_color: "AABBCC",
        route_sort_order: 7,
        continuous_pickup: 1,
        continuous_drop_off: 1,
        active: true,
        updated_at: @updated_at
      },
      overrides
    )
  end

  describe "source/1" do
    test "binds organization, version, route UUID and natural ID to raw and normalized values" do
      source = Routes.source(persisted_route())

      assert source.organization_id == @organization_id
      assert source.gtfs_version_id == @gtfs_version_id
      assert source.route_uuid == @route_uuid
      assert source.route_id == "R1"
      assert source.updated_at == @updated_at

      # Raw original values are preserved exactly as persisted.
      assert source.original.route_color == "0000ff"
      assert source.original.route_text_color == "AABBCC"
      assert source.original.route_desc == nil

      # Normalized values are comparison-only.
      assert source.normalized.route_color == "0000FF"
      assert source.normalized.route_text_color == "AABBCC"
    end

    test "keeps identity out of the editable value maps" do
      source = Routes.source(persisted_route())

      refute Map.has_key?(source.original, :route_uuid)
      refute Map.has_key?(source.original, :route_id)
      refute Map.has_key?(source.original, :active)
      refute Map.has_key?(source.normalized, :organization_id)
    end
  end

  describe "normal saves with unchanged current" do
    test "applies only draft-minus-base and preserves untouched raw values" do
      draft =
        Map.merge(base(), %{
          route_long_name: "Renamed",
          route_url: "https://example.test/x",
          route_color: "0000FF",
          route_sort_order: 7
        })

      assert {:ok, result} = Routes.compare_edit(base(), draft, base(), %{})

      assert result.status == :applied
      assert result.compatible == [:route_long_name, :route_url]
      assert result.conflicting == []
      assert result.write == %{route_long_name: "Renamed", route_url: "https://example.test/x"}
      assert result.merged.route_long_name == "Renamed"
      assert result.merged.route_color == "0000ff"
    end

    test "a no-op draft writes nothing" do
      draft =
        Map.merge(base(), %{
          route_long_name: " Original ",
          route_color: "0000FF",
          route_sort_order: 7
        })

      assert {:ok, result} = Routes.compare_edit(base(), draft, base(), %{})

      assert result.status == :applied
      assert result.write == %{}
    end

    test "a draft with no writes never receives merge confirmation shortcuts" do
      draft = Map.put(base(), :route_desc, nil)

      assert {:ok, result} = Routes.compare_edit(base(), draft, base(), %{confirm_merge: true})

      assert result.status == :applied
      assert result.write == %{}
    end
  end

  describe "stale disjoint edits" do
    setup do
      current = Map.put(base(), :route_long_name, "Background")
      draft = Map.put(base(), :route_desc, "Mine")
      %{current: current, draft: draft}
    end

    test "merge only with explicit confirmation", %{current: current, draft: draft} do
      assert {:ok, result} = Routes.compare_edit(base(), draft, current, %{})

      assert result.status == :confirmation_required
      assert result.compatible == [:route_desc, :route_long_name]
      assert result.conflicting == []
      assert result.write == %{}
      assert result.merged == nil
    end

    test "confirmed merge accepts disjoint changes from both sides", %{
      current: current,
      draft: draft
    } do
      assert {:ok, result} =
               Routes.compare_edit(base(), draft, current, %{confirm_merge: true})

      assert result.status == :applied
      assert result.write == %{route_desc: "Mine"}
      assert result.merged.route_desc == "Mine"
      assert result.merged.route_long_name == "Background"
    end

    test "identical stale changes merge with confirmation and no per-field choice", %{
      draft: _draft
    } do
      current = Map.put(base(), :route_sort_order, 9)
      draft = Map.put(base(), :route_sort_order, 9)

      assert {:ok, result} = Routes.compare_edit(base(), draft, current, %{})
      assert result.status == :confirmation_required
      assert result.compatible == [:route_sort_order]

      assert {:ok, result} =
               Routes.compare_edit(base(), draft, current, %{confirm_merge: true})

      assert result.status == :applied
      assert result.conflicting == []
      assert result.write == %{}
      assert result.merged.route_sort_order == 9
    end
  end

  describe "overlapping edits" do
    setup do
      current = Map.put(base(), :route_long_name, "Theirs")
      draft = Map.put(base(), :route_long_name, "Mine")
      %{current: current, draft: draft}
    end

    test "overlap requires a choice", %{current: current, draft: draft} do
      assert {:ok, result} = Routes.compare_edit(base(), draft, current, %{})

      assert result.status == :choices_required
      assert result.conflicting == [:route_long_name]
      assert result.write == %{}
      assert result.merged == nil
    end

    test "choice mine with confirmation writes the draft value", %{current: current, draft: draft} do
      assert {:ok, result} =
               Routes.compare_edit(base(), draft, current, %{
                 route_long_name: "mine",
                 confirm_merge: true
               })

      assert result.status == :applied
      assert result.conflicting == [:route_long_name]
      assert result.write == %{route_long_name: "Mine"}
    end

    test "choice theirs with confirmation keeps the current value", %{
      current: current,
      draft: draft
    } do
      assert {:ok, result} =
               Routes.compare_edit(base(), draft, current, %{
                 route_long_name: "theirs",
                 confirm_merge: true
               })

      assert result.status == :applied
      assert result.write == %{}
      assert result.merged.route_long_name == "Theirs"
    end

    test "a resolved overlap still merges only with explicit confirmation", %{
      current: current,
      draft: draft
    } do
      assert {:ok, result} =
               Routes.compare_edit(base(), draft, current, %{route_long_name: "mine"})

      assert result.status == :confirmation_required
      assert result.write == %{}
      assert result.merged == nil
    end

    test "an invalid choice value is rejected", %{current: current, draft: draft} do
      assert {:error, {:invalid_choice, :route_long_name, "ours"}} =
               Routes.compare_edit(base(), draft, current, %{
                 route_long_name: "ours",
                 confirm_merge: true
               })
    end
  end

  describe "identity binding" do
    test "rejects a same-natural-ID replacement UUID" do
      current =
        base()
        |> Map.put(:route_uuid, "99999999-9999-9999-9999-999999999999")
        |> Map.put(:route_long_name, "Background")

      draft = Map.put(base(), :route_desc, "Mine")

      assert {:error, :source_mismatch} =
               Routes.compare_edit(base(), draft, current, %{confirm_merge: true})
    end

    test "rejects an organization or version scope mismatch" do
      draft = Map.put(base(), :route_desc, "Mine")

      for scope_override <- [
            %{organization_id: "44444444-4444-4444-4444-444444444444"},
            %{gtfs_version_id: "55555555-5555-5555-5555-555555555555"}
          ] do
        current = Map.merge(base(), scope_override)

        assert {:error, :source_mismatch} =
                 Routes.compare_edit(base(), draft, current, %{confirm_merge: true})
      end
    end

    test "rejects when identity is present on only one side" do
      plain_fields = Map.drop(base(), Map.keys(identity()))

      assert {:error, :source_mismatch} =
               Routes.compare_edit(base(), plain_fields, plain_fields, %{})
    end
  end

  describe "color/text coupling" do
    test "an automatic background/foreground pair conflicts and resolves together" do
      draft = Map.merge(base(), %{route_color: "112233", route_text_color: "FFFFFF"})
      current = Map.put(base(), :route_color, "445566")

      assert {:ok, result} = Routes.compare_edit(base(), draft, current, %{})

      assert result.status == :choices_required
      assert result.conflicting == [:route_color, :route_text_color]

      assert {:ok, result} =
               Routes.compare_edit(base(), draft, current, %{
                 route_color: "mine",
                 confirm_merge: true
               })

      assert result.status == :applied
      assert result.write == %{route_color: "112233", route_text_color: "FFFFFF"}
    end

    test "disagreeing pair choices are rejected to keep the conflict coupled" do
      draft = Map.merge(base(), %{route_color: "112233", route_text_color: "FFFFFF"})
      current = Map.put(base(), :route_color, "445566")

      assert {:error, {:coupled_choice_conflict, [:route_color, :route_text_color]}} =
               Routes.compare_edit(base(), draft, current, %{
                 route_color: "mine",
                 route_text_color: "theirs",
                 confirm_merge: true
               })
    end

    test "one-sided pair edits on opposite sides are not disjoint" do
      draft = Map.put(base(), :route_text_color, "111111")
      current = Map.put(base(), :route_color, "222222")

      assert {:ok, result} = Routes.compare_edit(base(), draft, current, %{confirm_merge: true})

      assert result.status == :choices_required
      assert result.conflicting == [:route_color, :route_text_color]
      assert result.compatible == []
    end

    test "identical pair changes stay compatible" do
      draft = Map.put(base(), :route_color, "112233")
      current = Map.put(base(), :route_color, "112233")

      assert {:ok, result} =
               Routes.compare_edit(base(), draft, current, %{confirm_merge: true})

      assert result.status == :applied
      assert result.conflicting == []
      assert result.write == %{}
      assert result.merged.route_color == "112233"
    end
  end

  describe "whitelisted fields only" do
    test "forged identity, scope, active and derivation keys never enter the write set" do
      draft =
        Map.merge(base(), %{
          route_desc: "Mine",
          organization_id: "66666666-6666-6666-6666-666666666666",
          gtfs_version_id: "77777777-7777-7777-7777-777777777777",
          route_uuid: "88888888-8888-8888-8888-888888888888",
          route_id: "R9",
          active: false,
          pattern_derivation_error: "corrupt"
        })

      assert {:ok, result} = Routes.compare_edit(base(), draft, base(), %{})

      assert result.status == :applied
      assert result.write == %{route_desc: "Mine"}
      assert result.merged.route_desc == "Mine"
      refute Map.has_key?(result.merged, :active)
      refute Map.has_key?(result.merged, :pattern_derivation_error)
      refute Map.has_key?(result.merged, :route_id)
      refute Map.has_key?(result.merged, :route_uuid)
    end
  end
end

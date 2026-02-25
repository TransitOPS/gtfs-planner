defmodule GtfsPlanner.Gtfs.Import.DiffTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.{Level, Pathway, Stop}
  alias GtfsPlanner.Gtfs.Import.Diff

  @inserted_at ~U[2024-01-01 00:00:00Z]
  @updated_at ~U[2024-01-01 00:00:00Z]
  @edited_at ~U[2024-01-01 00:00:01Z]

  describe "compute/2" do
    test "returns no decisions for no-op input" do
      assert Diff.compute(default_uploaded(), default_db()) == []
    end

    test "creates add decisions for uploaded keys missing in DB" do
      uploaded =
        default_uploaded(%{
          levels: [
            %{
              level_id: "L1",
              level_index: 1.0,
              level_name: "Platform"
            }
          ]
        })

      decisions = Diff.compute(uploaded, default_db())

      assert [%{id: "level:L1", action: :add, entity_type: :level, dependency_keys: []}] =
               decisions
    end

    test "creates remove decisions for DB keys missing in upload" do
      db = default_db(%{stops: [stop(%{stop_id: "STOP_A"})]})
      uploaded = default_uploaded(%{stops: []})

      decisions = Diff.compute(uploaded, db)

      assert [%{id: "stop:STOP_A", action: :remove, entity_type: :stop}] = decisions
    end

    test "classifies changed intersections as modify when record is not user-edited" do
      db = default_db(%{levels: [level(%{level_id: "L1", level_name: "Old"})]})

      uploaded =
        default_uploaded(%{
          levels: [%{level_id: "L1", level_index: 0.0, level_name: "New"}]
        })

      [decision] = Diff.compute(uploaded, db)

      assert decision.id == "level:L1"
      assert decision.action == :modify
      assert decision.changed_fields == [level_name: {"Old", "New"}]
      refute decision.user_edited
    end

    test "classifies changed intersections as conflict when record was user-edited" do
      db =
        default_db(%{
          levels: [level(%{level_id: "L1", level_name: "Old", updated_at: @edited_at})]
        })

      uploaded =
        default_uploaded(%{
          levels: [%{level_id: "L1", level_index: 0.0, level_name: "New"}]
        })

      [decision] = Diff.compute(uploaded, db)

      assert decision.id == "level:L1"
      assert decision.action == :conflict
      assert decision.user_edited
    end

    test "suppresses unchanged intersections" do
      db = default_db(%{levels: [level(%{level_id: "L1", level_name: "Platform"})]})

      uploaded =
        default_uploaded(%{
          levels: [%{level_id: "L1", level_index: 0.0, level_name: "Platform"}]
        })

      assert Diff.compute(uploaded, db) == []
    end

    test "returns stable entity ordering levels ++ stops ++ pathways" do
      uploaded =
        default_uploaded(%{
          levels: [%{level_id: "L2", level_index: 2.0, level_name: nil}],
          stops: [
            %{
              stop_id: "S2",
              stop_name: "Stop 2",
              stop_desc: nil,
              stop_lat: Decimal.new("42.0"),
              stop_lon: Decimal.new("-71.0"),
              location_type: 0,
              wheelchair_boarding: nil,
              platform_code: nil,
              level_id: nil,
              parent_station: nil
            }
          ],
          pathways: [
            %{
              pathway_id: "P2",
              pathway_mode: 1,
              is_bidirectional: true,
              traversal_time: nil,
              length: nil,
              stair_count: nil,
              max_slope: nil,
              min_width: nil,
              signposted_as: nil,
              reversed_signposted_as: nil,
              from_stop_id: "S2",
              to_stop_id: "S3"
            }
          ]
        })

      decisions = Diff.compute(uploaded, default_db())

      assert Enum.map(decisions, & &1.entity_type) == [:level, :stop, :pathway]
    end

    test "uses Decimal.equal?/2 when both values are decimals" do
      db =
        default_db(%{
          stops: [
            stop(%{stop_id: "S1", stop_lat: Decimal.new("40.0"), stop_lon: Decimal.new("-74.00")})
          ]
        })

      uploaded =
        default_uploaded(%{
          stops: [
            %{
              stop_id: "S1",
              stop_name: "Stop",
              stop_desc: nil,
              stop_lat: Decimal.new("40.00"),
              stop_lon: Decimal.new("-74.0"),
              location_type: 0,
              wheelchair_boarding: nil,
              platform_code: nil,
              level_id: nil,
              parent_station: nil
            }
          ]
        })

      assert Diff.compute(uploaded, db) == []
    end

    test "skips removals when entity file is not uploaded" do
      db = default_db(%{pathways: [pathway(%{pathway_id: "P1"})]})
      uploaded = default_uploaded(%{pathways: :not_uploaded})

      assert Diff.compute(uploaded, db) == []
    end

    test "populates dependency keys for stops and pathways" do
      uploaded =
        default_uploaded(%{
          stops: [
            %{
              stop_id: "S1",
              stop_name: "Child",
              stop_desc: nil,
              stop_lat: Decimal.new("40.0"),
              stop_lon: Decimal.new("-74.0"),
              location_type: 0,
              wheelchair_boarding: nil,
              platform_code: nil,
              level_id: "L1",
              parent_station: "STATION"
            }
          ],
          pathways: [
            %{
              pathway_id: "P1",
              pathway_mode: 1,
              is_bidirectional: true,
              traversal_time: nil,
              length: nil,
              stair_count: nil,
              max_slope: nil,
              min_width: nil,
              signposted_as: nil,
              reversed_signposted_as: nil,
              from_stop_id: "S1",
              to_stop_id: "S2"
            }
          ]
        })

      decisions = Diff.compute(uploaded, default_db())
      stop_decision = Enum.find(decisions, &(&1.entity_type == :stop))
      pathway_decision = Enum.find(decisions, &(&1.entity_type == :pathway))

      assert stop_decision.dependency_keys == ["level:L1", "stop:STATION"]
      assert pathway_decision.dependency_keys == ["stop:S1", "stop:S2"]
    end
  end

  describe "summary/1" do
    test "counts all actions" do
      decisions = [
        %{action: :add},
        %{action: :add},
        %{action: :modify},
        %{action: :remove},
        %{action: :conflict}
      ]

      assert Diff.summary(decisions) == %{add: 2, modify: 1, remove: 1, conflict: 1}
    end
  end

  defp default_uploaded(overrides \\ %{}) do
    Map.merge(%{levels: :not_uploaded, stops: :not_uploaded, pathways: :not_uploaded}, overrides)
  end

  defp default_db(overrides \\ %{}) do
    Map.merge(%{levels: [], stops: [], pathways: []}, overrides)
  end

  defp level(attrs) do
    struct!(
      Level,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate(),
          level_id: "L1",
          level_index: 0.0,
          level_name: nil,
          inserted_at: @inserted_at,
          updated_at: @updated_at
        },
        attrs
      )
    )
  end

  defp stop(attrs) do
    struct!(
      Stop,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate(),
          stop_id: "S1",
          stop_name: "Stop",
          stop_desc: nil,
          stop_lat: Decimal.new("40.0"),
          stop_lon: Decimal.new("-74.0"),
          location_type: 0,
          wheelchair_boarding: nil,
          platform_code: nil,
          diagram_coordinate: nil,
          parent_station: nil,
          level_id: nil,
          inserted_at: @inserted_at,
          updated_at: @updated_at
        },
        attrs
      )
    )
  end

  defp pathway(attrs) do
    struct!(
      Pathway,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate(),
          pathway_id: "P1",
          pathway_mode: 1,
          is_bidirectional: true,
          traversal_time: nil,
          length: nil,
          stair_count: nil,
          max_slope: nil,
          min_width: nil,
          signposted_as: nil,
          reversed_signposted_as: nil,
          from_stop_id: "S1",
          to_stop_id: "S2",
          inserted_at: @inserted_at,
          updated_at: @updated_at
        },
        attrs
      )
    )
  end
end

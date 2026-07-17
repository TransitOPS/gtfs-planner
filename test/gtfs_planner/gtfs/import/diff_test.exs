defmodule GtfsPlanner.Gtfs.Import.DiffTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.{Level, Pathway, Stop}
  alias GtfsPlanner.Gtfs.Import.{Diff, ParsedEntity, ParseFailure}

  @inserted_at ~U[2024-01-01 00:00:00Z]
  @updated_at ~U[2024-01-01 00:00:00Z]
  @edited_at ~U[2024-01-01 00:00:01Z]

  describe "compute/2 applicable behavior (complete uploads)" do
    test "returns no decisions for no-op input" do
      assert Diff.compute(default_uploaded(), default_db()) == %{
               applicable: [],
               preview: [],
               blocked_entities: %{}
             }
    end

    test "creates add decisions for uploaded keys missing in DB" do
      uploaded =
        default_uploaded(%{
          levels: ok_entity(:level, %{"L1" => %{level_id: "L1", level_index: 1.0, level_name: "Platform"}})
        })

      %{applicable: applicable, preview: preview} = Diff.compute(uploaded, default_db())

      assert preview == []
      assert [%{id: "level:L1", action: :add, entity_type: :level, dependency_keys: []}] = applicable
    end

    test "creates remove decisions for DB keys missing in upload (AC-9)" do
      db = default_db(%{stops: [stop(%{stop_id: "STOP_A"})]})
      uploaded = default_uploaded(%{stops: ok_entity(:stop, %{})})

      %{applicable: applicable, preview: preview} = Diff.compute(uploaded, db)

      assert preview == []
      assert [%{id: "stop:STOP_A", action: :remove, entity_type: :stop}] = applicable
    end

    test "classifies changed intersections as modify when record is not user-edited" do
      db = default_db(%{levels: [level(%{level_id: "L1", level_name: "Old"})]})

      uploaded =
        default_uploaded(%{
          levels: ok_entity(:level, %{"L1" => %{level_id: "L1", level_index: 0.0, level_name: "New"}})
        })

      %{applicable: [decision]} = Diff.compute(uploaded, db)

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
          levels: ok_entity(:level, %{"L1" => %{level_id: "L1", level_index: 0.0, level_name: "New"}})
        })

      %{applicable: [decision]} = Diff.compute(uploaded, db)

      assert decision.id == "level:L1"
      assert decision.action == :conflict
      assert decision.user_edited
    end

    test "suppresses unchanged intersections" do
      db = default_db(%{levels: [level(%{level_id: "L1", level_name: "Platform"})]})

      uploaded =
        default_uploaded(%{
          levels: ok_entity(:level, %{"L1" => %{level_id: "L1", level_index: 0.0, level_name: "Platform"}})
        })

      %{applicable: applicable, preview: preview} = Diff.compute(uploaded, db)

      assert applicable == []
      assert preview == []
    end

    test "returns stable entity ordering levels ++ stops ++ pathways" do
      uploaded =
        default_uploaded(%{
          levels: ok_entity(:level, %{"L2" => %{level_id: "L2", level_index: 2.0, level_name: nil}}),
          stops: ok_entity(:stop, %{"S2" => stop_attrs("S2", %{level_id: nil, parent_station: nil})}),
          pathways:
            ok_entity(:pathway, %{
              "P2" => pathway_attrs("P2", %{from_stop_id: "S2", to_stop_id: "S3"})
            })
        })

      %{applicable: applicable} = Diff.compute(uploaded, default_db())

      assert Enum.map(applicable, & &1.entity_type) == [:level, :stop, :pathway]
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
          stops: ok_entity(:stop, %{"S1" => stop_attrs("S1", %{stop_lat: Decimal.new("40.00"), stop_lon: Decimal.new("-74.0")})})
        })

      %{applicable: applicable, preview: preview} = Diff.compute(uploaded, db)

      assert applicable == []
      assert preview == []
    end

    test "skips removals when entity file is not uploaded (AC-8)" do
      db = default_db(%{pathways: [pathway(%{pathway_id: "P1"})]})
      uploaded = default_uploaded(%{pathways: :not_uploaded})

      result = Diff.compute(uploaded, db)

      assert result.applicable == []
      assert result.preview == []
      refute Map.has_key?(result.blocked_entities, :pathway)
    end

    test "populates dependency keys for stops and pathways" do
      uploaded =
        default_uploaded(%{
          stops: ok_entity(:stop, %{"S1" => stop_attrs("S1", %{level_id: "L1", parent_station: "STATION"})}),
          pathways:
            ok_entity(:pathway, %{"P1" => pathway_attrs("P1", %{from_stop_id: "S1", to_stop_id: "S2"})})
        })

      %{applicable: decisions} = Diff.compute(uploaded, default_db())
      stop_decision = Enum.find(decisions, &(&1.entity_type == :stop))
      pathway_decision = Enum.find(decisions, &(&1.entity_type == :pathway))

      assert stop_decision.dependency_keys == ["level:L1", "stop:STATION"]
      assert pathway_decision.dependency_keys == ["stop:S1", "stop:S2"]
    end
  end

  describe "compute/2 failed-upload preview behavior" do
    test "failed entity produces add/modify/conflict previews only, no removals (AC-10)" do
      db = default_db(%{
        levels: [level(%{level_id: "L1", level_name: "Old"})],
        stops: [stop(%{stop_id: "STOP_REMOVED"})]
      })

      uploaded =
        default_uploaded(%{
          levels: error_entity(:level, %{"L1" => %{level_id: "L1", level_index: 0.0, level_name: "New"}}),
          stops: error_entity(:stop, %{})
        })

      %{applicable: applicable, preview: preview, blocked_entities: blocked} = Diff.compute(uploaded, db)

      assert applicable == []
      assert Map.fetch!(blocked, :level) == :parse_failed
      assert Map.fetch!(blocked, :stop) == :parse_failed

      preview_ids = Enum.map(preview, & &1.id)
      assert "level:L1" in preview_ids
      refute Enum.any?(preview, &(&1.action == :remove))
      refute "stop:STOP_REMOVED" in preview_ids
    end

    test "DB key absent from failed upload preview keys yields no removal (AC-12)" do
      db = default_db(%{stops: [stop(%{stop_id: "STOP_ABSENT"})]})

      uploaded =
        default_uploaded(%{
          stops: error_entity(:stop, %{"S2" => stop_attrs("S2", %{level_id: nil, parent_station: nil})})
        })

      %{applicable: applicable, preview: preview} = Diff.compute(uploaded, db)

      assert applicable == []
      refute Enum.any?(preview, &(&1.action == :remove))
      refute Enum.any?([applicable, preview] |> List.flatten(), fn d -> d.id == "stop:STOP_ABSENT" end)
    end

    test "complete empty entity produces removal decisions for every DB key (AC-9)" do
      db = default_db(%{
        levels: [level(%{level_id: "L1"}), level(%{level_id: "L2"})],
        stops: [stop(%{stop_id: "S1"})]
      })

      uploaded = default_uploaded(%{levels: ok_entity(:level, %{})})

      %{applicable: applicable} = Diff.compute(uploaded, db)

      removed_ids = Enum.filter(applicable, &(&1.action == :remove)) |> Enum.map(& &1.id)
      assert "level:L1" in removed_ids
      assert "level:L2" in removed_ids
      refute "stop:S1" in removed_ids
    end
  end

  describe "compute/2 dependency taint" do
    test "failed levels taints uploaded stops to preview (AC-11)" do
      db = default_db(%{levels: [level(%{level_id: "L1", level_name: "Old"})]})

      uploaded =
        default_uploaded(%{
          levels: error_entity(:level, %{}),
          stops: ok_entity(:stop, %{"S1" => stop_attrs("S1", %{level_id: "L1", parent_station: nil})})
        })

      %{applicable: applicable, preview: preview, blocked_entities: blocked} = Diff.compute(uploaded, db)

      assert applicable == []
      assert Map.fetch!(blocked, :level) == :parse_failed
      assert Map.fetch!(blocked, :stop) == :dependency_failed
      assert Enum.all?(preview, &(&1.entity_type == :stop))
    end

    test "failed stops taints uploaded pathways to preview (AC-11)" do
      db = default_db(%{levels: [level(%{level_id: "L1"})]})

      uploaded =
        default_uploaded(%{
          levels: ok_entity(:level, %{"L1" => %{level_id: "L1", level_index: 0.0, level_name: "x"}}),
          stops: error_entity(:stop, %{}),
          pathways: ok_entity(:pathway, %{"P1" => pathway_attrs("P1", %{from_stop_id: "S1", to_stop_id: "S2"})})
        })

      %{applicable: applicable, preview: preview, blocked_entities: blocked} = Diff.compute(uploaded, db)

      assert Enum.all?(applicable, &(&1.entity_type == :level))
      assert Enum.all?(preview, &(&1.entity_type == :pathway))
      assert Map.fetch!(blocked, :stop) == :parse_failed
      assert Map.fetch!(blocked, :pathway) == :dependency_failed
    end

    test "both-failed upstream taints transitively (AC-11)" do
      uploaded =
        default_uploaded(%{
          levels: error_entity(:level, %{}),
          stops: error_entity(:stop, %{}),
          pathways: ok_entity(:pathway, %{"P1" => pathway_attrs("P1", %{from_stop_id: "S1", to_stop_id: "S2"})})
        })

      %{applicable: applicable, preview: preview, blocked_entities: blocked} = Diff.compute(uploaded, db_no_records())

      assert applicable == []
      assert Enum.all?(preview, &(&1.entity_type == :pathway))
      assert Map.fetch!(blocked, :level) == :parse_failed
      assert Map.fetch!(blocked, :stop) == :parse_failed
      assert Map.fetch!(blocked, :pathway) == :dependency_failed
    end

    test "not_uploaded levels leaves uploaded stops applicable (AC-11)" do
      uploaded =
        default_uploaded(%{
          levels: :not_uploaded,
          stops: ok_entity(:stop, %{"S1" => stop_attrs("S1", %{level_id: nil, parent_station: nil})})
        })

      %{applicable: applicable, preview: preview, blocked_entities: blocked} = Diff.compute(uploaded, default_db())

      assert preview == []
      assert Enum.all?(applicable, &(&1.entity_type == :stop))
      refute Map.has_key?(blocked, :stop)
    end

    test "complete entity outside failed dependency closure stays applicable" do
      db = default_db(%{levels: [level(%{level_id: "L1", level_name: "Old"})]})

      uploaded =
        default_uploaded(%{
          levels: ok_entity(:level, %{"L2" => %{level_id: "L2", level_index: 0.0, level_name: "New"}}),
          stops: error_entity(:stop, %{})
        })

      %{applicable: applicable, preview: preview, blocked_entities: blocked} = Diff.compute(uploaded, db)

      assert Enum.any?(applicable, fn d -> d.id == "level:L2" and d.action == :add end)
      assert preview == []
      assert Map.fetch!(blocked, :stop) == :parse_failed
      refute Map.has_key?(blocked, :level)
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

  defp db_no_records do
    %{levels: [], stops: [], pathways: []}
  end

  defp ok_entity(entity_type, records_by_key) do
    {:ok, %ParsedEntity{entity_type: entity_type, filename: "#{entity_type}.txt", records_by_key: records_by_key, source_row_count: map_size(records_by_key)}}
  end

  defp error_entity(entity_type, preview_records_by_key) do
    {:error,
     %ParseFailure{
       entity_type: entity_type,
       filename: "#{entity_type}.txt",
       preview_records_by_key: preview_records_by_key,
       diagnostics: [%{file: "#{entity_type}.txt", reason: :semantic_row}],
       total_error_count: 1,
       truncated?: false,
       source_row_count: map_size(preview_records_by_key),
       first_error_row: 2,
       last_error_row: 2
     }}
  end

  defp stop_attrs(stop_id, overrides) do
    Map.merge(
      %{
        stop_id: stop_id,
        stop_name: "Stop",
        stop_desc: nil,
        stop_lat: Decimal.new("40.0"),
        stop_lon: Decimal.new("-74.0"),
        location_type: 0,
        wheelchair_boarding: nil,
        platform_code: nil,
        level_id: nil,
        parent_station: nil
      },
      overrides
    )
  end

  defp pathway_attrs(pathway_id, overrides) do
    Map.merge(
      %{
        pathway_id: pathway_id,
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
      },
      overrides
    )
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

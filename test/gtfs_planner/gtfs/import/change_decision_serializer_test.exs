defmodule GtfsPlanner.Gtfs.Import.ChangeDecisionSerializerTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.{ChangeDecisionSerializer, DiffDecision}

  describe "version 1 serialization" do
    test "round-trips only fixed fields in a deterministic representation" do
      decision = %DiffDecision{
        id: "stop:central",
        entity_type: :stop,
        action: :modify,
        natural_key: "central",
        current_record: %{
          stop_id: "central",
          stop_name: "Central",
          stop_desc: "Old description",
          stop_lat: Decimal.new("40.123400"),
          stop_lon: Decimal.new("-73.987600"),
          location_type: 1,
          wheelchair_boarding: 1,
          platform_code: "1",
          level_id: "L1",
          parent_station: nil,
          arbitrary: "must not persist"
        },
        uploaded_attrs: %{
          stop_name: "Central Station",
          stop_desc: "New description",
          stop_lat: Decimal.new("40.123400"),
          stop_lon: Decimal.new("-73.987600"),
          location_type: 1,
          wheelchair_boarding: 1,
          platform_code: "1",
          level_id: "L1",
          parent_station: nil
        },
        changed_fields: [stop_name: {"Central", "Central Station"}],
        dependency_keys: ["level:L1"],
        user_edited: true,
        status: :approved
      }

      assert {:ok, serialized} = ChangeDecisionSerializer.serialize(decision)
      assert serialized.serializer_version == 1
      refute Map.has_key?(serialized.current_values, "arbitrary")
      refute Map.has_key?(serialized.uploaded_values, "file_body")
      assert serialized.current_values["stop_lat"] == "40.1234"

      assert serialized.changed_fields == [
               %{"after" => "Central Station", "before" => "Central", "field" => "stop_name"}
             ]

      assert {:ok, restored} = ChangeDecisionSerializer.deserialize(serialized)
      assert restored.id == decision.id
      assert restored.current_record.stop_name == "Central"
      assert restored.current_record.stop_lat == "40.1234"
      assert restored.uploaded_attrs.stop_name == "Central Station"
      assert restored.changed_fields == [stop_name: {"Central", "Central Station"}]

      assert {:ok, repeated} = ChangeDecisionSerializer.serialize(restored)
      assert repeated == serialized
    end

    test "rejects unsupported versions, arbitrary keys, structs, exceptions, and file bodies" do
      decision = %DiffDecision{
        id: "level:L1",
        entity_type: :level,
        action: :modify,
        natural_key: "L1",
        current_record: %{level_index: 1, level_name: "One"},
        uploaded_attrs: %{level_index: 2, level_name: "Two"}
      }

      assert {:error, :unsupported_serializer_version} =
               ChangeDecisionSerializer.deserialize(%{serializer_version: 2})

      assert {:error, {:unsupported_field, :file_body}} =
               ChangeDecisionSerializer.serialize(%{
                 decision
                 | uploaded_attrs: %{file_body: "raw"}
               })

      assert {:error, {:unsafe_value, :current_values}} =
               ChangeDecisionSerializer.serialize(%{
                 decision
                 | current_record: %{level_index: RuntimeError.exception("raw")}
               })

      assert {:error, {:unsafe_value, :uploaded_values}} =
               ChangeDecisionSerializer.serialize(%{
                 decision
                 | uploaded_attrs: %{level_name: %URI{scheme: "https"}}
               })
    end

    test "uses a fixed fingerprint for the normalized current values" do
      values = %{"level_index" => 1, "level_name" => "One"}

      assert ChangeDecisionSerializer.current_fingerprint(values) ==
               ChangeDecisionSerializer.current_fingerprint(%{
                 "level_name" => "One",
                 "level_index" => 1
               })
    end
  end
end

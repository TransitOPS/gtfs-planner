defmodule GtfsPlanner.Routing.DiagnosticTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Routing.Diagnostic

  describe "from_router/1" do
    test "converts a router diagnostic to the application-owned struct" do
      router_diag = %PathwaysRouter.Diagnostic{
        severity: :warning,
        code: :missing_endpoint,
        entity_type: "pathway",
        entity_id: "PW_17",
        message: "Pathway references a missing endpoint",
        detail: %{stop_id: "MISSING_1"}
      }

      diag = Diagnostic.from_router(router_diag)

      assert diag.severity == :warning
      assert diag.code == :missing_endpoint
      assert diag.entity_type == "pathway"
      assert diag.entity_id == "PW_17"
      assert diag.message == "Pathway references a missing endpoint"
    end
  end

  describe "to_map/1" do
    test "produces only string keys and string-or-nil values" do
      diag = %Diagnostic{
        severity: :error,
        code: :missing_endpoint,
        entity_type: "pathway",
        entity_id: "PW_17",
        message: "Pathway references a missing endpoint"
      }

      map = Diagnostic.to_map(diag)

      assert map == %{
               "severity" => "error",
               "code" => "missing_endpoint",
               "entity_type" => "pathway",
               "entity_id" => "PW_17",
               "message" => "Pathway references a missing endpoint"
             }

      assert {:ok, _} = Jason.encode(map)
    end

    test "drops the detail field even when it is a complex term" do
      diag = %Diagnostic{
        severity: :warning,
        code: :unknown_pathway_mode,
        entity_type: "pathway",
        entity_id: "PW_99",
        message: "Pathway has an unrecognized pathway_mode"
      }

      map = Diagnostic.to_map(diag)

      refute Map.has_key?(map, "detail")
      assert {:ok, _} = Jason.encode(map)
    end

    test "entity_id nil encodes as nil, not empty string" do
      diag = %Diagnostic{
        severity: :warning,
        code: :invalid_wheelchair_boarding,
        entity_type: "stop",
        entity_id: nil,
        message: "Stop has an unrecognized wheelchair_boarding value"
      }

      map = Diagnostic.to_map(diag)

      assert map["entity_id"] == nil
      assert {:ok, json} = Jason.encode(map)
      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["entity_id"] == nil
    end
  end
end

defmodule GtfsPlanner.Agents.Packs.FareZonesReadTest do
  @moduledoc """
  Merge evidence (EV-6) for the Fare zone pack's read tools through the real
  composition (`Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> pack ->
  `Gtfs.FareZones`), with only the OpenRouter HTTP boundary doubled.

  Expected zones and counts are hand-derived from
  `GtfsPlanner.FareSelectionFixtures` (stop A2 is in zone "B"; zone "C" is a
  declared record with no stops) plus one fare rule between B and C, so each zone
  has the stop and rule counts written below. What the model read is the decoded
  tool message of the next provider request; refusals are asserted from the
  dispatch fence's own literal messages.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.Agents.PackTurn

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.FareZones
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)
    FareSelectionFixtures.insert_network!(organization, version)
    FareSelectionFixtures.declare_zone!(organization, version, "C")

    Repo.insert!(%FareRule{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      fare_id: "F1",
      origin_id: "B",
      destination_id: "C"
    })

    %{
      organization: organization,
      version: version,
      scope: version_scope(organization, version, "fare_zones")
    }
  end

  defp find(scope, tool, query), do: find_result(scope, tool, query)

  defp find_result(scope, tool, query),
    do: Dispatch.call(FareZones, scope, tool, Jason.encode!(%{"query" => query}))

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  describe "registration" do
    test "the registry names the pack, which declares list_zones and takes no argument",
         context do
      assert Agents.packs()["fare_zones"] == FareZones
      assert FareZones.id() == "fare_zones"
      assert FareZones.title() == "Fare zone helper"

      assert Enum.map(FareZones.tools(), & &1.name) == [
               "list_zones",
               "find_routes",
               "find_stops",
               "query_zone_targets"
             ]

      assert Enum.all?(FareZones.tools(), &(&1.parameters["additionalProperties"] == false))
      assert FareZones.skill() =~ "list_zones"

      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []
    end
  end

  describe "list_zones through a composed turn" do
    test "returns the inventory zones with exact counts and the same total as the evidence",
         context do
      expect_reply(tool_calls_reply([{"call_1", "list_zones", "{}"}]))
      expect_reply(text_reply("This version has two zones."))

      {_pid, entry} = run_turn(context.scope, "Which fare zones exist?")

      assert entry.status == :done
      assert entry.activity == ["Listed fare zones"]

      assert %{"zones" => zones, "total" => 2, "completeness" => "complete"} = tool_result()

      assert zones == [
               %{"zone_id" => "B", "name" => "B", "stop_count" => 1, "rule_count" => 1},
               %{"zone_id" => "C", "name" => "Zone C", "stop_count" => 0, "rule_count" => 1}
             ]

      assert [evidence] = entry.evidence
      assert evidence.kind == "fare_zones"
      assert evidence.total == 2
      assert evidence.total_label == "zones"
      assert evidence.completeness == :complete
      assert evidence.source_ref == "gtfs_fare_zones"
      assert evidence.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert evidence.source_revision == nil
      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.gtfs_version_id == context.version.id
      assert evidence.scope.identity == "version:#{context.version.id}"

      assert Enum.find(evidence.facts, &(&1.label == "Stops with no zone")).value == "5"
      assert Enum.find(evidence.facts, &(&1.label == "Boardable stops")).value == "6"
    end
  end

  describe "find_routes and find_stops" do
    test "a route query returns exact candidates, the total and the same evidence", context do
      assert {:ok, result, evidence} = find(context.scope, "find_routes", "Route")

      assert result["routes"] == [
               %{"route_id" => "R6", "short_name" => "6", "long_name" => "Route Six"},
               %{"route_id" => "R9", "short_name" => "9", "long_name" => "Route Nine"}
             ]

      assert result["total"] == 2
      assert result["completeness"] == "complete"
      assert evidence.kind == "route_candidates"
      assert evidence.total == 2
      assert evidence.completeness == :complete
      assert evidence.scope.identity == "version:#{context.version.id}"
      assert Enum.map(evidence.resources, & &1.id) == ["R6", "R9"]

      assert {:ok, %{"routes" => [%{"route_id" => "R6"}], "total" => 1}, _} =
               find(context.scope, "find_routes", "6")
    end

    test "a stop query returns zone IDs, and a station is never a candidate", context do
      assert {:ok, result, evidence} = find(context.scope, "find_stops", "Airport")

      assert result["stops"] == [
               %{
                 "stop_id" => "AIR1",
                 "stop_name" => "Airport Gate",
                 "zone_id" => nil,
                 "parent_station" => nil
               },
               %{
                 "stop_id" => "AIR2",
                 "stop_name" => "Airport Terminal",
                 "zone_id" => nil,
                 "parent_station" => nil
               }
             ]

      assert result["total"] == 2
      assert evidence.kind == "stop_candidates"
      assert evidence.resources == []

      assert {:ok, %{"stops" => [], "total" => 0}, _} =
               find(context.scope, "find_stops", "Central")
    end

    test "a blank or whitespace query is refused with the literal message", context do
      for tool <- ["find_routes", "find_stops"], query <- ["", "   "] do
        assert FareZones.call(tool, %{"query" => query}, context.scope) ==
                 {:error, "Give a name or ID to search for."}
      end

      # Through the fence an empty string stops at the schema's own minimum.
      assert {:tool_error, "Argument query must be at least 1 characters."} =
               find_result(context.scope, "find_stops", "")

      assert {:tool_error, "Give a name or ID to search for."} =
               find_result(context.scope, "find_routes", "   ")
    end

    test "more than 20 matches return 20, the exact total and an incomplete marker", context do
      FareSelectionFixtures.insert_stops!(
        context.organization,
        context.version,
        for(number <- 1..25, do: %{stop_id: "PINE#{number}", stop_name: "Pine #{pad(number)}"})
      )

      assert {:ok, result, evidence} = find(context.scope, "find_stops", "Pine")

      assert length(result["stops"]) == 20
      assert hd(result["stops"])["stop_name"] == "Pine 01"
      assert List.last(result["stops"])["stop_name"] == "Pine 20"
      assert result["total"] == 25
      assert result["completeness"] == "incomplete"
      assert result["reason"] == "Showing 20 of 25. Search again with more of the name."
      assert evidence.total == 25
      assert evidence.completeness == :incomplete
    end

    test "a twin organization and version with the same names add nothing", context do
      twin_organization = OrganizationsFixtures.organization_fixture()
      twin_version = VersionsFixtures.gtfs_version_fixture(twin_organization.id)
      FareSelectionFixtures.insert_network!(twin_organization, twin_version)
      second_version = VersionsFixtures.gtfs_version_fixture(context.organization.id)
      FareSelectionFixtures.insert_network!(context.organization, second_version)

      assert {:ok, %{"total" => 2} = result, evidence} =
               find(context.scope, "find_stops", "Airport")

      assert length(result["stops"]) == 2
      assert evidence.total == 2

      assert {:ok, %{"total" => 2}, _} = find(context.scope, "find_routes", "Route")
    end

    test "a model-supplied identity is refused before the pack runs", context do
      for tool <- ["find_routes", "find_stops"], extra <- ["version_id", "organization_id"] do
        assert {:tool_error, message} =
                 Dispatch.call(FareZones, context.scope, tool, ~s({"query":"x","#{extra}":"1"}))

        assert message == "Unexpected argument: #{extra}"
      end
    end

    test "a composed turn passes the candidates back to the model", context do
      expect_reply(tool_calls_reply([{"call_1", "find_stops", ~s({"query":"Airport"})}]))
      expect_reply(text_reply("Two stops match Airport."))

      {_pid, entry} = run_turn(context.scope, "Which zone is Airport in?")

      assert entry.activity == ["Found stops"]
      assert %{"total" => 2, "stops" => [%{"stop_id" => "AIR1"}, _]} = tool_result()
      assert [%{kind: "stop_candidates", total: 2}] = entry.evidence
    end
  end

  describe "the dispatch fence and the pack's own guard" do
    test "an identity argument is refused before the pack runs", context do
      for extra <- ["organization_id", "gtfs_version_id", "all"] do
        assert {:tool_error, message} =
                 Dispatch.call(FareZones, context.scope, "list_zones", ~s({"#{extra}":"x"}))

        assert message == "Unexpected argument: #{extra}"
      end
    end

    test "a version with more than 50 zones lists 50 and says the rest were not read", context do
      for number <- 1..49 do
        FareSelectionFixtures.declare_zone!(
          context.organization,
          context.version,
          "Z#{String.pad_leading(Integer.to_string(number), 2, "0")}"
        )
      end

      assert {:ok, result, evidence} = Dispatch.call(FareZones, context.scope, "list_zones", "{}")

      assert result["total"] == 51
      assert length(result["zones"]) == 50
      assert result["completeness"] == "incomplete"
      assert result["reason"] == "Showing 50 of 51 zones."
      assert evidence.total == 51
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason == "Showing 50 of 51 zones."
    end

    test "a scope that is not bound to this version reads nothing", context do
      zones_before = Repo.aggregate(Stop, :count)

      for identity <- [nil, {:version, Ecto.UUID.generate()}, {:route, Ecto.UUID.generate()}] do
        scope = %{context.scope | resource_context: Scope.context(identity)}

        assert FareZones.call("list_zones", %{}, scope) ==
                 {:error, "This version is no longer available."}
      end

      assert Repo.aggregate(Stop, :count) == zones_before
    end
  end
end

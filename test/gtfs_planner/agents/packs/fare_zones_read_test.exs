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

  describe "registration" do
    test "the registry names the pack, which declares list_zones and takes no argument",
         context do
      assert Agents.packs()["fare_zones"] == FareZones
      assert FareZones.id() == "fare_zones"
      assert FareZones.title() == "Fare zone helper"
      assert Enum.map(FareZones.tools(), & &1.name) == ["list_zones"]
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

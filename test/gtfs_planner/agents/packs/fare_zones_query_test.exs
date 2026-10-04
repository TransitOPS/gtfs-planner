defmodule GtfsPlanner.Agents.Packs.FareZonesQueryTest do
  @moduledoc """
  Merge evidence (EV-7) for `query_zone_targets` through the dispatch fence and a
  composed turn: exact counts, the bounded sample with the other routes of each
  stop, shared routes, the fingerprint as the evidence digest, and readable
  refusals. Expected values are hand-derived from
  `GtfsPlanner.FareSelectionFixtures`; the digest is compared with
  `FareZones.route_selection/3`'s own fingerprint for the same predicate. Every
  case re-reads the stored zones to show the tool wrote nothing.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.Agents.PackTurn

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.FareZones, as: Pack
  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.GtfsFixtures
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)
    FareSelectionFixtures.insert_network!(organization, version)

    %{
      organization: organization,
      version: version,
      scope: version_scope(organization, version, "fare_zones"),
      zones_before: zones()
    }
  end

  defp zones,
    do: Repo.all(from(s in Stop, order_by: s.id, select: {s.id, s.zone_id, s.updated_at}))

  # Every stop that existed before the call still has its zone and timestamp.
  defp assert_unchanged(before) do
    current = Map.new(zones(), &{elem(&1, 0), &1})
    for row <- before, do: assert(current[elem(row, 0)] == row)
  end

  defp query(scope, route_ids, opts \\ []) do
    arguments =
      Jason.encode!(%{
        "route_ids" => route_ids,
        "only_unzoned" => Keyword.get(opts, :only_unzoned, true),
        "exclude_stop_ids" => Keyword.get(opts, :exclude, [])
      })

    Dispatch.call(Pack, scope, "query_zone_targets", arguments)
  end

  defp refusal(scope, route_ids, opts \\ []) do
    Pack.call(
      "query_zone_targets",
      %{
        "route_ids" => route_ids,
        "only_unzoned" => Keyword.get(opts, :only_unzoned, true),
        "exclude_stop_ids" => Keyword.get(opts, :exclude, [])
      },
      scope
    )
  end

  test "Route 6 unzoned minus Airport Gate: exact counts, sample, shared routes and digest",
       context do
    assert {:ok, result, evidence} = query(context.scope, ["R6"], exclude: ["AIR1"])

    assert result["selected_count"] == 2
    assert result["served_count"] == 4
    assert result["already_zoned_count"] == 1
    assert result["excluded"] == [%{"stop_id" => "AIR1", "stop_name" => "Airport Gate"}]
    assert result["unmatched_exclusions"] == []
    assert result["routes"] == [%{"route_id" => "R6", "short_name" => "6"}]
    assert result["completeness"] == "complete"

    assert result["sample"] == [
             %{"stop_id" => "A1", "stop_name" => "Alder", "zone_id" => nil, "other_routes" => []},
             %{
               "stop_id" => "A3",
               "stop_name" => "Cedar",
               "zone_id" => nil,
               "other_routes" => ["9"]
             }
           ]

    assert result["shared_routes"] == [
             %{"route_id" => "R9", "route_short_name" => "9", "stop_count" => 1}
           ]

    {:ok, selection} =
      FareZones.route_selection(context.organization.id, context.version.id, %{
        route_ids: ["R6"],
        only_unzoned?: true,
        exclude_stop_ids: ["AIR1"]
      })

    assert evidence.kind == "zone_targets"
    assert evidence.title == "Stops to assign"
    assert evidence.total == 2
    assert evidence.total_label == "stops selected"
    assert evidence.digest == selection.fingerprint
    assert evidence.completeness == :complete
    assert evidence.scope.identity == "version:#{context.version.id}"
    assert [%{kind: "route", id: "R6", label: "6"}] = evidence.resources

    assert Enum.map(evidence.facts, &{&1.label, &1.value}) == [
             {"Stops these routes serve", "4"},
             {"Already in a zone", "1"},
             {"Excluded", "1"},
             {"Also served by other routes", "1"}
           ]

    assert_unchanged(context.zones_before)
  end

  test "an exclusion no named route serves is reported as unmatched", context do
    assert {:ok, result, _evidence} = query(context.scope, ["R6"], exclude: ["AIR2"])

    assert result["unmatched_exclusions"] == ["AIR2"]
    assert result["excluded"] == []
    assert result["selected_count"] == 3
  end

  test "a selection of 25 stops returns a 20-stop sample and an incomplete marker", context do
    GtfsFixtures.route_fixture(context.organization.id, context.version.id, %{route_id: "RBIG"})
    names = Enum.map(1..25, &"B#{&1}")

    FareSelectionFixtures.insert_stops!(
      context.organization,
      context.version,
      Enum.map(names, &%{stop_id: &1})
    )

    FareSelectionFixtures.call_at!(context.organization, context.version, "RBIG", "T-BIG", names)

    assert {:ok, result, evidence} = query(context.scope, ["RBIG"])

    assert result["selected_count"] == 25
    assert length(result["sample"]) == 20
    assert result["completeness"] == "incomplete"
    assert result["reason"] == "Showing 20 of 25 selected stops."
    assert evidence.total == 25
    assert evidence.completeness == :incomplete

    assert_unchanged(context.zones_before)
  end

  describe "refusals return a readable message and no data" do
    test "an unknown route, an unknown stop and a station", context do
      assert refusal(context.scope, ["NOPE"]) ==
               {:error, "Route NOPE is not in this version. Use find_routes."}

      assert refusal(context.scope, ["R6"], exclude: ["GHOST"]) ==
               {:error, "Stop GHOST is not a boardable stop of this version. Use find_stops."}

      assert refusal(context.scope, ["R6"], exclude: ["S1"]) ==
               {:error, "Stop S1 is not a boardable stop of this version. Use find_stops."}

      assert_unchanged(context.zones_before)
    end

    test "six routes, 101 exclusions and a route with 1,001 served stops", context do
      assert refusal(context.scope, ~w(R1 R2 R3 R4 R5 R6)) == {:error, "Name at most 5 routes."}

      assert refusal(context.scope, ["R6"], exclude: Enum.map(1..101, &"X#{&1}")) ==
               {:error, "Exclude at most 100 stops."}

      GtfsFixtures.route_fixture(context.organization.id, context.version.id, %{route_id: "RBIG"})
      names = Enum.map(1..1001, &"B#{&1}")

      FareSelectionFixtures.insert_stops!(
        context.organization,
        context.version,
        Enum.map(names, &%{stop_id: &1})
      )

      FareSelectionFixtures.call_at!(
        context.organization,
        context.version,
        "RBIG",
        "T-BIG",
        names
      )

      assert refusal(context.scope, ["RBIG"]) ==
               {:error, "These routes serve more than 1,000 stops. Name fewer routes."}
    end

    test "an empty route list and a model-supplied identity stop at the dispatch fence",
         context do
      assert {:tool_error, "Argument route_ids must have 1 or more items."} =
               query(context.scope, [])

      assert {:tool_error, "Unexpected argument: version_id"} =
               Dispatch.call(
                 Pack,
                 context.scope,
                 "query_zone_targets",
                 ~s({"route_ids":["R6"],"only_unzoned":true,"exclude_stop_ids":[],"version_id":"x"})
               )

      assert {:tool_error, "Missing required argument: only_unzoned"} =
               Dispatch.call(
                 Pack,
                 context.scope,
                 "query_zone_targets",
                 ~s({"route_ids":["R6"],"exclude_stop_ids":[]})
               )

      assert_unchanged(context.zones_before)
    end
  end

  test "a composed turn gives the model the counts and the panel the evidence", context do
    arguments = ~s({"route_ids":["R6"],"only_unzoned":true,"exclude_stop_ids":["AIR1"]})
    expect_reply(tool_calls_reply([{"call_1", "query_zone_targets", arguments}]))
    expect_reply(text_reply("2 stops have no zone."))

    {_pid, entry} =
      run_turn(context.scope, "How many unzoned Route 6 stops, except Airport Gate?")

    assert entry.status == :done
    assert entry.activity == ["Counted stops to assign"]
    assert %{"selected_count" => 2, "shared_routes" => [%{"route_id" => "R9"}]} = tool_result()
    assert [%{kind: "zone_targets", total: 2}] = entry.evidence
  end
end

defmodule GtfsPlanner.Agents.Packs.FareZonesPrepareTest do
  @moduledoc """
  Merge evidence (EV-8) for `prepare_zone_assignment` through the dispatch fence
  and a composed turn: the prepared command carries the explicit stop UUIDs, the
  predicate and the fingerprint the pack resolved on the server, the summary
  states the counts, exclusions, shared routes and the export consequence for an
  unmanaged and a managed version, refusals are readable, and nothing is written.

  Expected values are hand-derived from `GtfsPlanner.FareSelectionFixtures`
  (zones "B", named "Zone B", and "C"). Every case re-reads the stored zones and
  `updated_at` to show the tool wrote nothing.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.Agents.PackTurn

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.FareZones, as: Pack
  alias GtfsPlanner.FareSelectionFixtures
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)
    stops = FareSelectionFixtures.insert_network!(organization, version)
    FareSelectionFixtures.declare_zone!(organization, version, "B")
    FareSelectionFixtures.declare_zone!(organization, version, "C")

    %{
      organization: organization,
      version: version,
      stops: stops,
      scope: version_scope(organization, version, "fare_zones"),
      zones_before: zones()
    }
  end

  defp zones,
    do: Repo.all(from(s in Stop, order_by: s.id, select: {s.id, s.zone_id, s.updated_at}))

  defp prepare(scope, zone_id, opts \\ []) do
    Dispatch.call(
      Pack,
      scope,
      "prepare_zone_assignment",
      Jason.encode!(%{
        "route_ids" => Keyword.get(opts, :route_ids, ["R6"]),
        "only_unzoned" => Keyword.get(opts, :only_unzoned, true),
        "exclude_stop_ids" => Keyword.get(opts, :exclude, ["AIR1"]),
        "zone_id" => zone_id
      })
    )
  end

  test "R6 unzoned minus Airport Gate to zone B prepares the explicit stops and the summary",
       context do
    assert {:prepared, prepared, result, evidence} = prepare(context.scope, "B")

    {:ok, selection} =
      FareZones.route_selection(context.organization.id, context.version.id, %{
        route_ids: ["R6"],
        only_unzoned?: true,
        exclude_stop_ids: ["AIR1"]
      })

    assert prepared.command ==
             {:zone_assignment,
              %{
                target: "B",
                predicate: %{route_ids: ["R6"], only_unzoned?: true, exclude_stop_ids: ["AIR1"]},
                stop_ids: [context.stops["A1"].id, context.stops["A3"].id],
                fingerprint: selection.fingerprint
              }}

    assert prepared.summary == %{
             title: "Assign 2 stops to Zone B",
             detail:
               "Review the stops, shared routes and export effect, then save in the zone review.",
             lines: [
               "Routes: 6",
               "Stops with no zone only",
               "2 gain a zone, 0 move from another zone, 0 already in Zone B",
               "Excluded: Airport Gate (AIR1)",
               "Also served by route 9 (1 stop)",
               "These zones export in the stops.txt zone column; fare rules keep their zone references."
             ]
           }

    assert result["selected_count"] == 2
    assert result["added_count"] == 2
    assert result["moved_count"] == 0
    assert result["already_in_zone_count"] == 0
    assert result["zone_name"] == "Zone B"
    assert evidence.kind == "zone_assignment"
    assert evidence.total == 2
    assert evidence.digest == selection.fingerprint

    assert zones() == context.zones_before
  end

  test "a managed version states the areas export instead", context do
    Repo.insert!(%FareVersionSetting{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      managed_at: DateTime.utc_now()
    })

    assert {:prepared, prepared, _result, _evidence} = prepare(context.scope, "B")

    assert List.last(prepared.summary.lines) ==
             "This version's areas and stop areas export from these zones."
  end

  test "moving a zoned stop is counted as a move, not a gain", context do
    assert {:prepared, prepared, result, _evidence} =
             prepare(context.scope, "C", only_unzoned: false, exclude: [])

    assert result["added_count"] == 3
    assert result["moved_count"] == 1
    assert prepared.summary.title == "Assign 4 stops to Zone C"

    assert "3 gain a zone, 1 move from another zone, 0 already in Zone C" in prepared.summary.lines
    assert "Includes stops already in another zone" in prepared.summary.lines
  end

  describe "refusals" do
    test "a zone outside the inventory", context do
      assert {:tool_error, "Zone Z is not in this version. Use list_zones."} =
               prepare(context.scope, "Z")

      assert zones() == context.zones_before
    end

    test "a predicate that matches no stop", context do
      assert {:tool_error, "No stops match."} =
               prepare(context.scope, "B",
                 only_unzoned: true,
                 route_ids: ["R9"],
                 exclude: ["A3", "AIR2"]
               )

      assert zones() == context.zones_before
    end

    test "a selection that is already entirely in the target zone", context do
      assert {:tool_error, "Nothing would change: every selected stop is already in zone B."} =
               prepare(context.scope, "B",
                 only_unzoned: false,
                 route_ids: ["R6"],
                 exclude: ["A1", "A3", "AIR1"]
               )

      assert zones() == context.zones_before
    end

    test "a stop UUID list or an identity is not an argument", context do
      for extra <- ["stop_ids", "organization_id", "gtfs_version_id"] do
        arguments =
          ~s({"route_ids":["R6"],"only_unzoned":true,"exclude_stop_ids":[],"zone_id":"B","#{extra}":["x"]})

        assert {:tool_error, "Unexpected argument: " <> ^extra} =
                 Dispatch.call(Pack, context.scope, "prepare_zone_assignment", arguments)
      end

      assert {:tool_error, "Missing required argument: zone_id"} =
               Dispatch.call(
                 Pack,
                 context.scope,
                 "prepare_zone_assignment",
                 ~s({"route_ids":["R6"],"only_unzoned":true,"exclude_stop_ids":[]})
               )
    end
  end

  test "a composed turn hands the command to Agents.prepared/3 and writes no zone", context do
    arguments =
      ~s({"route_ids":["R6"],"only_unzoned":true,"exclude_stop_ids":["AIR1"],"zone_id":"B"})

    expect_reply(tool_calls_reply([{"call_1", "prepare_zone_assignment", arguments}]))
    expect_reply(text_reply("I prepared assigning 2 stops to Zone B."))

    {pid, entry} = run_turn(context.scope, "Put those stops in Zone B")

    assert entry.status == :done
    assert entry.activity == ["Prepared a zone assignment"]
    assert %{"prepared" => true, "selected_count" => 2} = tool_result()

    assert {:ok, ^pid, %{conversation_id: conversation_id}} = Agents.open(context.scope)

    assert {:ok, %{command: {:zone_assignment, %{target: "B", stop_ids: [_, _]}}} = prepared} =
             Agents.prepared(pid, conversation_id, entry.id)

    assert prepared.summary.title == "Assign 2 stops to Zone B"
    assert zones() == context.zones_before
  end
end

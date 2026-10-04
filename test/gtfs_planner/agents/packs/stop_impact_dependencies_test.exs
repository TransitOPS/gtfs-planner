defmodule GtfsPlanner.Agents.Packs.StopImpactDependenciesTest do
  @moduledoc """
  Merge evidence (EV-13) for the Stop impact helper's admission and
  `get_stop_dependencies`.

  Counts are written by hand from the fixture: a station `ST` with one pattern
  occurrence, one relief point, one child stop (all blocking) and one transfer and
  one stop area (descriptive), and a stop `D` on forty patterns. The pack is reached
  through `Dispatch` and `Agents.open/1`; the provider fake is the only boundary
  doubled and must never be called for a refused target.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.StopHelperFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.StopImpact
  alias GtfsPlanner.Agents.ScriptedProvider
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopArea

  setup do
    Req.Test.set_req_test_to_shared()
    ScriptedProvider.track_sessions()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    route = route_fixture(organization.id, version.id, %{route_id: "1", route_short_name: "1"})

    station =
      stop_fixture(organization.id, version.id, %{
        stop_id: "ST",
        stop_name: "Main St Station",
        location_type: 1
      })

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_pattern_id: "P",
        route_id: route.route_id,
        headsign: "To P"
      })

    route_pattern_stop_fixture(pattern, "ST", 1)
    relief_point_fixture(organization.id, version.id, %{stop_id: "ST"})

    child_stop_fixture(organization.id, version.id, "ST", %{
      stop_id: "ST-A",
      stop_name: "Platform A",
      location_type: 4
    })

    other = stop_fixture(organization.id, version.id, %{stop_id: "OTHER", stop_name: "Other"})

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: "ST",
      to_stop_id: other.stop_id,
      min_transfer_time: 60
    })

    Repo.insert!(%StopArea{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      area_id: "zone-1",
      stop_id: "ST"
    })

    unused = stop_fixture(organization.id, version.id, %{stop_id: "FREE", stop_name: "Unused"})

    %{
      organization: organization,
      version: version,
      user: user,
      membership: membership,
      route: route,
      station: station,
      unused: unused
    }
  end

  describe "get_stop_dependencies" do
    test "lists each class with its count and says the native delete is refused", context do
      scope = scope(context, stop_focus(context.station.id))
      before = stamps(context)

      assert {:ok, result, evidence} = dependencies(scope)

      assert %{"stop_id" => "ST", "stop_name" => "Main St Station", "location_type" => 1} ==
               result["stop"]

      classes = fn rows -> Map.new(rows, &{&1["key"], &1["count"]}) end

      assert classes.(result["blocking"]) == %{
               "route_pattern_stops" => 1,
               "relief_points" => 1,
               "child_stops" => 1
             }

      assert classes.(result["descriptive"]) == %{"transfers_from" => 1, "stop_areas" => 1}
      assert {result["blocking_total"], result["descriptive_total"]} == {3, 2}

      assert %{"result" => "refused", "labels" => labels} = result["delete_outcome"]
      assert Enum.sort(labels) == ["Patterns", "Relief points", "Stops in this station"]

      pattern = Enum.find(result["blocking"], &(&1["key"] == "route_pattern_stops"))
      assert pattern["details"] == ["1 · To P"]
      assert pattern["details_omitted"] == 0

      area = Enum.find(result["descriptive"], &(&1["key"] == "stop_areas"))
      assert area["details"] == ["zone-1"]

      # The unchecked effects are always stated.
      assert length(result["unchecked"]) == 3
      assert Enum.any?(result["unchecked"], &(&1 =~ "alerts"))
      assert Enum.any?(result["unchecked"], &(&1 =~ "Boarding safety"))
      assert Enum.any?(result["unchecked"], &(&1 =~ "Accessibility"))

      assert evidence.kind == "stop_dependencies"
      assert evidence.total == 5
      assert evidence.total_label == "rows that name this stop"
      assert evidence.completeness == :complete
      assert evidence.resources == [%{kind: "stop", id: "ST", label: "Main St Station"}]

      assert evidence.scope == %{
               organization_id: context.organization.id,
               gtfs_version_id: context.version.id,
               identity: "version:#{context.version.id}"
             }

      # Reading changed no row, update stamp or audit entry.
      assert stamps(context) == before
    end

    test "an unused stop is allowed with no rows", context do
      scope = scope(context, stop_focus(context.unused.id))

      assert {:ok, result, evidence} = dependencies(scope)
      assert {result["blocking"], result["descriptive"]} == {[], []}
      assert result["delete_outcome"] == %{"result" => "allowed", "labels" => []}
      assert {evidence.total, evidence.completeness} == {0, :complete}
    end

    test "a stop on forty patterns keeps the exact count and bounds the labels", context do
      busy =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: "BUSY",
          stop_name: "Busy"
        })

      for index <- 1..40 do
        pattern =
          route_pattern_fixture(context.organization.id, context.version.id, %{
            route_pattern_id: "BP-#{index}",
            route_id: context.route.route_id,
            headsign: "To #{index}"
          })

        route_pattern_stop_fixture(pattern, "BUSY", 1)
      end

      scope = scope(context, stop_focus(busy.id))
      assert {:ok, result, evidence} = dependencies(scope)

      assert [pattern_class] = result["blocking"]
      assert pattern_class["count"] == 40
      assert length(pattern_class["details"]) == 10
      assert pattern_class["details_omitted"] == 30

      assert evidence.total == 40
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "Patterns"
      assert byte_size(Jason.encode!(result)) < 32_768
    end
  end

  describe "admission" do
    test "a target the page did not admit is unavailable before any provider request", context do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign = stop_fixture(foreign_organization.id, foreign_version.id, %{stop_id: "ST"})
      other_version = gtfs_version_fixture(context.organization.id)
      elsewhere = stop_fixture(context.organization.id, other_version.id, %{stop_id: "ST"})

      gone = stop_fixture(context.organization.id, context.version.id, %{stop_id: "GONE"})
      Repo.delete!(gone)

      here = context.unused.id
      pin = %{"lat" => 44.62, "lon" => -124.05}

      cases = [
        {"stop of another organization", stop_focus(foreign.id)},
        {"stop of another version", stop_focus(elsewhere.id)},
        {"deleted stop", stop_focus(gone.id)},
        {"non-UUID stop", stop_focus("not-a-uuid")},
        {"latitude 91", stop_focus(here, %{"lat" => 91, "lon" => -124.05})},
        {"longitude 181", stop_focus(here, %{"lat" => 44.6, "lon" => 181})},
        {"NaN-like longitude", stop_focus(here, %{"lat" => 44.6, "lon" => "NaN"})},
        {"non-numeric latitude", stop_focus(here, %{"lat" => "44.6", "lon" => -124.0})},
        {"half a pin", stop_focus(here, %{"lat" => 44.6})},
        {"schema version 2",
         {"stop_focus", %{"schema_version" => 2, "stop_uuid" => here, "candidate" => nil}}},
        {"another snapshot kind", {"stop_set", %{"schema_version" => 1, "stop_uuid" => here}}},
        {"no snapshot", :none}
      ]

      stub_provider()

      for {label, snapshot} <- cases do
        scope = scope(context, snapshot)
        assert StopImpact.authorize_context(scope) == {:error, :unavailable}, label
        assert Agents.open(scope) == {:error, :unavailable}, label

        assert Dispatch.call(StopImpact, scope, "get_stop_dependencies", "{}") ==
                 {:error, :unavailable},
               label
      end

      # A valid pin is admitted.
      assert StopImpact.authorize_context(scope(context, stop_focus(here, pin))) == :ok
      refute_received :provider_called
    end

    test "a revoked membership refuses the next request, tool and delivered result", context do
      scope = scope(context, stop_focus(context.unused.id))
      assert {:ok, session, _snapshot} = Agents.open(scope)

      stub_provider()
      deactivate_membership_fixture(context.membership)

      assert Agents.send_message(session, "What uses this stop?") == {:error, :forbidden}

      assert Dispatch.call(StopImpact, scope, "get_stop_dependencies", "{}") ==
               {:error, :forbidden}

      assert Agents.open(scope) == {:error, :forbidden}
      refute_received :provider_called
    end

    test "no tool names a stop or a coordinate and dispatch rejects one", context do
      scope = scope(context, stop_focus(context.unused.id))

      for tool <- StopImpact.tools() do
        assert tool.parameters["properties"] == %{}
        assert tool.parameters["additionalProperties"] == false
      end

      for key <- ~w(stop_uuid stop_id lat lon candidate organization_id gtfs_version_id) do
        assert {:tool_error, "Unexpected argument: " <> ^key} =
                 Dispatch.call(StopImpact, scope, "get_stop_dependencies", ~s({"#{key}":"x"}))
      end
    end
  end

  describe "pack declaration" do
    test "the registry ships a read-only pack" do
      assert Agents.packs()["stop_impact"] == StopImpact
      assert StopImpact.id() == "stop_impact"
      assert StopImpact.title() == "Stop impact helper"

      # The exact tool list is pinned in the prepare test, which owns the last tool added.
      assert "get_stop_dependencies" in Enum.map(StopImpact.tools(), & &1.name)

      assert StopImpact.skill() =~ "get_stop_dependencies"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp scope(context, snapshot),
    do: helper_scope("stop_impact", context.organization, context.version, context.user, snapshot)

  defp dependencies(scope), do: Dispatch.call(StopImpact, scope, "get_stop_dependencies", "{}")

  defp stamps(context) do
    {Repo.all(from(s in Stop, order_by: s.id, select: {s.id, s.updated_at, s.stop_name})),
     Repo.aggregate(
       from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
       :count
     )}
  end

  defp stub_provider do
    test = self()

    Req.Test.stub(GtfsPlanner.Agents.Model, fn conn ->
      send(test, :provider_called)
      Plug.Conn.send_resp(conn, 500, "unexpected provider request")
    end)
  end
end

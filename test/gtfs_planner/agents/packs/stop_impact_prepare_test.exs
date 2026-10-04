defmodule GtfsPlanner.Agents.Packs.StopImpactPrepareTest do
  @moduledoc """
  Merge evidence (EV-15) for `prepare_stop_move`.

  The prepared command is only a pointer to the native move review: the host
  stop's UUID and the pin as 6-decimal strings, nothing applied, no routing request
  and no row written. The staged stop is `1434` in
  `GtfsPlanner.StopHelperFixtures`, saved at 44.6210, -124.0530.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.StopHelperFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.StopImpact
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop

  @routing_owner GtfsPlanner.StreetRouting.Geoapify
  @pin %{"lat" => 44.621124, "lon" => -124.053}

  setup do
    Req.Test.set_req_test_to_shared(%{})
    on_exit(fn -> Req.Test.set_req_test_to_private(%{}) end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)
    %{stops: stops} = staged_move_fixture(organization, version)

    %{organization: organization, version: version, user: user, stops: stops}
  end

  test "prepares exactly the stop's UUID and the pin as 6-decimal strings", context do
    stop = context.stops["1434"]
    counter = counting_routing_stub()
    before = stamps(context)

    assert {:prepared, prepared, result, evidence} = prepare(scope(context, @pin))

    assert prepared.command ==
             {:stop_move, %{stop_uuid: stop.id, lat: "44.621124", lon: "-124.053000"}}

    assert prepared.summary == %{
             title: "Move 1434 to the selected point",
             detail: "Same stop ID, new position",
             lines: [
               "Nothing is saved",
               "The native move review checks the street path and asks for your choices",
               "Retirement and replacement stay native actions"
             ]
           }

    assert result["prepared"] == true
    assert result["note"] =~ "pointer to the native move review only"
    assert {result["lat"], result["lon"]} == {"44.621124", "-124.053000"}

    assert evidence.kind == "stop_move_prepared"
    assert evidence.resources == [%{kind: "stop", id: "1434", label: "Stop 1434"}]
    assert evidence.scope.identity == "version:#{context.version.id}"

    # A pin given as integers still prepares the same-shaped strings.
    assert {:prepared, %{command: {:stop_move, %{lat: "45.000000", lon: "-124.000000"}}}, _, _} =
             prepare(scope(context, %{"lat" => 45, "lon" => -124}))

    assert :counters.get(counter, 1) == 0
    assert stamps(context) == before
  end

  test "no pin, or a pin on the saved position, prepares nothing", context do
    assert {:tool_error, "No pin is placed. Move the pin on the map, then ask again."} =
             prepare(scope(context, nil))

    # 0.2 m north of the saved position is inside the 0.5 m threshold; 0.8 m is a move.
    {lon, lat} = north(staged_lat(), 0.2)
    assert {:tool_error, message} = prepare(scope(context, %{"lat" => lat, "lon" => lon}))
    assert message =~ "saved position"

    {lon, lat} = north(staged_lat(), 0.8)

    assert {:prepared, _prepared, _result, _evidence} =
             prepare(scope(context, %{"lat" => lat, "lon" => lon}))

    for key <- ~w(lat lon stop_uuid candidate) do
      assert {:tool_error, "Unexpected argument: " <> ^key} =
               Dispatch.call(
                 StopImpact,
                 scope(context, @pin),
                 "prepare_stop_move",
                 ~s({"#{key}":1})
               )
    end
  end

  test "the pack names exactly three tools and none applies, deletes, replaces or retires" do
    names = Enum.map(StopImpact.tools(), & &1.name)
    assert names == ["get_stop_dependencies", "preview_stop_move", "prepare_stop_move"]
    refute Enum.any?(names, &(&1 =~ ~r/apply|delete|replace|retire/))
    assert StopImpact.skill() =~ "explicitly asks to keep the stop's ID"
  end

  test "another version's stop is unavailable before any provider request", context do
    other_version = gtfs_version_fixture(context.organization.id)

    elsewhere =
      stop_fixture(context.organization.id, other_version.id, %{
        stop_id: "1434",
        stop_name: "Elsewhere"
      })

    test = self()

    Req.Test.stub(GtfsPlanner.Agents.Model, fn conn ->
      send(test, :provider_called)
      Plug.Conn.send_resp(conn, 500, "unexpected provider request")
    end)

    scope =
      helper_scope(
        "stop_impact",
        context.organization,
        context.version,
        context.user,
        stop_focus(elsewhere.id, @pin)
      )

    assert Agents.open(scope) == {:error, :unavailable}
    assert Dispatch.call(StopImpact, scope, "prepare_stop_move", "{}") == {:error, :unavailable}
    refute_received :provider_called
  end

  # -- helpers ----------------------------------------------------------------

  defp scope(context, candidate) do
    helper_scope(
      "stop_impact",
      context.organization,
      context.version,
      context.user,
      stop_focus(context.stops["1434"].id, candidate)
    )
  end

  defp prepare(scope), do: Dispatch.call(StopImpact, scope, "prepare_stop_move", "{}")

  defp counting_routing_stub do
    counter = :counters.new(1, [])

    Req.Test.stub(@routing_owner, fn conn ->
      :counters.add(counter, 1, 1)
      Plug.Conn.send_resp(conn, 500, "routing must not be called")
    end)

    counter
  end

  defp stamps(context) do
    {Repo.all(
       from(s in Stop, order_by: s.id, select: {s.id, s.updated_at, s.stop_lat, s.stop_lon})
     ),
     Repo.aggregate(
       from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
       :count
     )}
  end
end

defmodule GtfsPlanner.Agents.Packs.StopImpactMoveTest do
  @moduledoc """
  Merge evidence (EV-14) for `preview_stop_move`.

  The expected numbers come from the staged served stop in
  `GtfsPlanner.StopHelperFixtures` (stop `1434` on one pattern with one weekday trip,
  a transfer east, a transfer from the north and a relief point). A counting
  `Req.Test` stub for street routing must read zero requests: the preview answers from
  `StopEditing.move_impact/3` at the pin the page admitted.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.StopHelperFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.StopImpact
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopReferences
  alias GtfsPlanner.Gtfs.Transfer

  @routing_owner GtfsPlanner.StreetRouting.Geoapify

  setup do
    Req.Test.set_req_test_to_shared(%{})
    on_exit(fn -> Req.Test.set_req_test_to_private(%{}) end)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)
    %{stops: stops, route: route} = staged_move_fixture(organization, version)

    %{organization: organization, version: version, user: user, stops: stops, route: route}
  end

  test "a 13.7 m pin reports a review band with the trips, patterns, transfers and relief point",
       context do
    scope = scope(context, pin(13.7))
    counter = counting_routing_stub()
    before = stamps(context)

    assert {:ok, result, evidence} = preview(scope)

    assert result["stop"] == %{
             "stop_id" => "1434",
             "stop_name" => "Stop 1434",
             "location_type" => 0
           }

    assert_in_delta result["distance_m"], 13.7, 0.3
    assert result["band"] == "review"
    assert result["band_note"] =~ "move review is required"
    assert {result["served"], result["weekday_trips"]} == {true, 1}
    assert result["patterns"] == [%{"label" => "1 · To P", "weekday_trips" => 1}]
    assert {result["patterns_omitted"], result["transfers_omitted"]} == {0, 0}

    assert [east, north] = Enum.sort_by(result["transfers"], & &1["min_transfer_time"], :desc)
    assert east["label"] =~ "Stop 2000"
    assert_in_delta east["before_m"], 79.2, 0.5
    assert_in_delta east["after_m"], 80.4, 0.5
    assert {north["min_transfer_time"], north["label"] =~ "Stop 3000"} == {120, true}
    assert_in_delta north["before_m"], 111.2, 0.5
    assert_in_delta north["after_m"], 97.5, 0.5

    assert result["relief_points"] == ["Relief at 1434"]

    assert Map.new(result["references"], &{&1["key"], {&1["kind"], &1["count"]}}) == %{
             "relief_points" => {"blocking", 1},
             "route_pattern_stops" => {"blocking", 1},
             "stop_times" => {"blocking", 1},
             "transfers_from" => {"descriptive", 1},
             "transfers_to" => {"descriptive", 1}
           }

    assert Enum.any?(
             result["unchecked"],
             &(&1 =~ "pattern lines would be redrawn is decided by the native")
           )

    assert Enum.any?(result["unchecked"], &(&1 =~ "street path is decided by the native"))
    assert length(result["unchecked"]) == 5

    assert evidence.kind == "stop_move_impact"
    assert {evidence.total, evidence.total_label} == {5, "rows that name this stop"}
    assert evidence.completeness == :complete
    assert evidence.resources == [%{kind: "stop", id: "1434", label: "Stop 1434"}]
    assert evidence.scope.identity == "version:#{context.version.id}"

    # No routing request, no row, update stamp or audit entry changed.
    assert :counters.get(counter, 1) == 0
    assert stamps(context) == before
  end

  test "pins at 7.9 m, 101 m and 400 m on an unserved stop report their native bands", context do
    for {metres, band, note} <- [
          {7.9, "correction", "without a move review"},
          {101.0, "far", "same stop"}
        ] do
      assert {:ok, result, _evidence} = preview(scope(context, pin(metres)))
      assert result["band"] == band
      assert result["band_note"] =~ note
    end

    unserved =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "9999",
        stop_name: "Nothing serves this",
        stop_lat: Decimal.from_float(staged_lat()),
        stop_lon: Decimal.from_float(-124.0)
      })

    {lon, lat} = north(staged_lat(), 400.0)

    scope =
      scope(context, %{"lat" => lat, "lon" => lon}, unserved.id)

    assert {:ok, result, _evidence} = preview(scope)
    assert {result["band"], result["served"]} == {"correction", false}
    assert result["band_note"] =~ "without a move review"
  end

  test "no pin returns the message and no evidence; arguments cannot supply one", context do
    scope = scope(context, nil)

    assert Dispatch.call(StopImpact, scope, "preview_stop_move", "{}") ==
             {:tool_error, "No pin is placed. Move the pin on the map, then ask again."}

    for key <- ~w(lat lon stop_uuid candidate) do
      assert {:tool_error, "Unexpected argument: " <> ^key} =
               Dispatch.call(StopImpact, scope, "preview_stop_move", ~s({"#{key}":1}))
    end
  end

  test "a stop on forty patterns and forty-one transfers caps the lists and keeps exact counts",
       context do
    busy = context.stops["1434"]

    for index <- 1..39 do
      pattern =
        route_pattern_fixture(context.organization.id, context.version.id, %{
          route_pattern_id: "BP-#{index}",
          route_id: context.route.route_id,
          headsign: "To #{index}"
        })

      route_pattern_stop_fixture(pattern, "1434", 1)

      other =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: "T-#{index}",
          stop_name: "Transfer #{index}",
          stop_lat: Decimal.from_float(44.63),
          stop_lon: Decimal.from_float(-124.04)
        })

      Repo.insert!(%Transfer{
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        from_stop_id: "1434",
        to_stop_id: other.stop_id,
        transfer_type: 0
      })
    end

    assert {:ok, result, evidence} = preview(scope(context, pin(13.7), busy.id))

    assert length(result["patterns"]) == 10
    assert result["patterns_omitted"] == 30
    assert length(result["transfers"]) == 10
    # 40 outgoing transfers (the fixture's plus 39) and the fixture's one incoming.
    assert result["transfers_omitted"] == 31

    # The ten listed are the first ten by label, not the first ten the read returned.
    %{blocking: blocking, descriptive: descriptive} =
      StopReferences.usage(context.organization.id, context.version.id, busy)

    all =
      for %{key: key, details: details} <- blocking ++ descriptive,
          key in [:transfers_from, :transfers_to],
          detail <- details,
          do: detail.label

    assert Enum.map(result["transfers"], & &1["label"]) == all |> Enum.sort() |> Enum.take(10)

    counts = Map.new(result["references"], &{&1["key"], &1["count"]})
    assert {counts["route_pattern_stops"], counts["transfers_from"]} == {40, 40}

    assert evidence.completeness == :incomplete
    assert evidence.completeness_reason =~ "patterns, transfers"
    assert byte_size(Jason.encode!(result)) < 32_768
  end

  # -- helpers ----------------------------------------------------------------

  defp pin(metres) do
    {lon, lat} = north(staged_lat(), metres)
    %{"lat" => lat, "lon" => lon}
  end

  defp scope(context, candidate, stop_uuid \\ nil) do
    stop_uuid = stop_uuid || context.stops["1434"].id

    helper_scope(
      "stop_impact",
      context.organization,
      context.version,
      context.user,
      stop_focus(stop_uuid, candidate)
    )
  end

  defp preview(scope), do: Dispatch.call(StopImpact, scope, "preview_stop_move", "{}")

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
     ), Repo.all(from(t in Transfer, order_by: t.id, select: {t.id, t.updated_at})),
     Repo.aggregate(
       from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
       :count
     )}
  end
end

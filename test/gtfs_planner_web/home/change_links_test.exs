defmodule GtfsPlannerWeb.Home.ChangeLinksTest do
  use ExUnit.Case, async: true

  alias GtfsPlannerWeb.Home.ChangeLinks
  alias GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents

  @version_id "9b2f4c1e-7a3d-4e5f-8b6c-1d2e3f4a5b6c"

  describe "path/2" do
    test "links a schedules item to the route schedules screen with its service" do
      item = %{kind: :schedules, params: %{route_id: "12", service_id: "WKDY"}}

      assert ChangeLinks.path(@version_id, item) ==
               "/gtfs/#{@version_id}/routes/12/schedules?service_id=WKDY"
    end

    test "links a calendar item to the calendar screen and encodes the service id" do
      item = %{kind: :calendar, params: %{service_id: "Week day"}}

      assert ChangeLinks.path(@version_id, item) ==
               "/gtfs/#{@version_id}/calendars/show?service_id=Week+day"
    end

    test "links a route pattern item to that pattern" do
      item = %{kind: :route_pattern, params: %{route_id: "12", route_pattern_id: "RP-7"}}

      assert ChangeLinks.path(@version_id, item) ==
               "/gtfs/#{@version_id}/routes/12/patterns/RP-7"
    end

    test "links a route patterns item to the route's pattern list" do
      item = %{kind: :route_patterns, params: %{route_id: "12"}}

      assert ChangeLinks.path(@version_id, item) == "/gtfs/#{@version_id}/routes/12"
    end

    test "links a station item to the floorplan open on the GTFS level" do
      item = %{kind: :station, params: %{stop_id: "STA", level_id: "L2"}}

      assert ChangeLinks.path(@version_id, item) ==
               "/gtfs/#{@version_id}/stops/STA/diagram?level=L2"
    end

    test "links a station item without a level to the default floorplan" do
      item = %{kind: :station, params: %{stop_id: "STA"}}

      assert ChangeLinks.path(@version_id, item) == "/gtfs/#{@version_id}/stops/STA/diagram"
    end

    test "links a stop item to the stop detail screen" do
      item = %{kind: :stop, params: %{stop_id: "P1"}}

      assert ChangeLinks.path(@version_id, item) == "/gtfs/#{@version_id}/stops/P1"
    end

    test "links a transfers item to the transfers screen" do
      assert ChangeLinks.path(@version_id, %{kind: :transfers, params: %{}}) ==
               "/gtfs/#{@version_id}/transfers"
    end

    test "returns no link for an item whose entity no longer exists" do
      assert ChangeLinks.path(@version_id, %{kind: :none, params: %{}}) == nil
      assert ChangeLinks.path(@version_id, %{kind: :none}) == nil
    end

    test "returns no link for an unknown kind" do
      assert ChangeLinks.path(@version_id, %{kind: :bogus, params: %{stop_id: "STA"}}) == nil
    end
  end

  describe "station_path/2" do
    test "links a station board row to the stop detail screen" do
      assert ChangeLinks.station_path(@version_id, "STA") == "/gtfs/#{@version_id}/stops/STA"
    end
  end

  describe "display_name/1" do
    test "titlecases the local part of an email" do
      assert ChangeLinks.display_name("dana.lee@example.com") == "Dana Lee"
    end

    test "returns Unknown for nil and the empty string" do
      assert ChangeLinks.display_name(nil) == "Unknown"
      assert ChangeLinks.display_name("") == "Unknown"
    end

    test "is the source the change history component delegates to" do
      assert ChangeHistoryComponents.__test_display_name__("dana.lee@example.com") ==
               ChangeLinks.display_name("dana.lee@example.com")
    end
  end
end

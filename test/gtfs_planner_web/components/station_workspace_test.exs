defmodule GtfsPlannerWeb.StationWorkspaceTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.StationWorkspace

  defp doc(html), do: LazyHTML.from_fragment(html)

  describe "station_header/1" do
    test "names the station, its identifier and the way back to the stops list" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StationWorkspace.station_header title="Central" stop_id="CEN" gtfs_version_id="v1">
          <:meta>Station · 2 platforms</:meta>
        </StationWorkspace.station_header>
        """)

      header = doc(html)

      assert header |> LazyHTML.query("h1") |> LazyHTML.text() == "Central"

      assert header |> LazyHTML.query("#station-back") |> LazyHTML.attribute("href") == [
               "/gtfs/v1/stops"
             ]

      assert LazyHTML.text(header) =~ "Station · 2 platforms"
      assert header |> LazyHTML.query("span.font-mono") |> LazyHTML.text() == "CEN"
    end

    test "links each station view and marks the current one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StationWorkspace.station_header
          title="Central"
          stop_id="CEN"
          gtfs_version_id="v1"
          active_tab={:report}
        />
        """)

      tabs = doc(html) |> LazyHTML.query("nav[aria-label='Station views'] a")

      assert tabs |> LazyHTML.attribute("href") == [
               "/gtfs/v1/stops/CEN",
               "/gtfs/v1/stops/CEN/diagram",
               "/gtfs/v1/stops/CEN/report",
               "/gtfs/v1/stops/CEN/reachability",
               "/gtfs/v1/stops/CEN/evolutions"
             ]

      current = doc(html) |> LazyHTML.query("a[aria-current='page']")
      assert LazyHTML.attribute(current, "id") == ["station-tab-report"]
    end

    test "leaves out the views of a stop that is not a station" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StationWorkspace.station_header
          title="City Hall"
          stop_id="CH"
          gtfs_version_id="v1"
          tabs?={false}
        />
        """)

      assert Enum.empty?(doc(html) |> LazyHTML.query("nav"))
    end

    test "names a parent station in the way back when given one" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StationWorkspace.station_header
          title="Bay 2"
          stop_id="B2"
          gtfs_version_id="v1"
          tabs?={false}
          back={%{label: "Central", navigate: "/gtfs/v1/stops/CEN"}}
        />
        """)

      back = doc(html) |> LazyHTML.query("#station-back")

      assert LazyHTML.attribute(back, "href") == ["/gtfs/v1/stops/CEN"]
      assert back |> LazyHTML.text() |> String.trim() == "Central"
    end

    test "omits the identifier and views before a stop has loaded" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StationWorkspace.station_header title="Stop details" gtfs_version_id="v1" />
        """)

      header = doc(html)

      assert Enum.empty?(header |> LazyHTML.query("nav"))
      assert Enum.empty?(header |> LazyHTML.query("span.font-mono"))
    end

    test "renders the page's actions beside the title" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <StationWorkspace.station_header title="Central" stop_id="CEN" gtfs_version_id="v1">
          <:actions><a id="primary-action" href="/go">Go</a></:actions>
        </StationWorkspace.station_header>
        """)

      assert Enum.count(doc(html) |> LazyHTML.query("#primary-action")) == 1
    end
  end
end

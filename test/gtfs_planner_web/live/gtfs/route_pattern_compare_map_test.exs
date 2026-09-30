defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareMapTest do
  @moduledoc """
  Merge evidence (EV-19) for CL-13 and CL-22: the compare page's sticky map pane
  carries the `Gtfs.load_pattern_compare_map/4` payload with the differences'
  numbered pins on `#compare-map`, and a map read outage is isolated to
  `#compare-map-unavailable`, whose "Retry map" reloads that one read.

  Every case enters through ordinary login and the real `CatalogReadAdapter.Repo`
  on the local test database (`CR-7`); `CatalogReadAdapterMock` is substituted
  only to fail the map read, and its expectations count the comparison read so
  the retry case proves the retry touched nothing else. The expected series,
  pin numbers and pin stops below are hand-derived from the fixtures: B replaces
  A's third stop with two stops, and its run between the first two shared stops
  is a minute longer. The focused gate command is deferred to branch review:

      MIX_ENV=test MIX_TEST_PARTITION=_s19 ELIXIR_ERL_OPTIONS="+S 4" gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/route_pattern_compare_map_test.exs
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock

  @adapter_key :gtfs_catalog_read_adapter

  setup :verify_on_exit!

  # Adapter substitution exists only to fail the map read. Successful reads use
  # the real context through the production Repo adapter; this helper restores
  # the previous configuration on exit.
  defp substitute_read_adapter(_context) do
    previous = Application.fetch_env(:gtfs_planner, @adapter_key)
    Application.put_env(:gtfs_planner, @adapter_key, CatalogReadAdapterMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, @adapter_key, value)
        :error -> Application.delete_env(:gtfs_planner, @adapter_key)
      end
    end)

    :ok
  end

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{
        alias: "route-pattern-compare-map-#{System.system_time(:nanosecond)}"
      })

    user =
      user_fixture(%{
        email: "pattern-compare-map-#{System.unique_integer([:positive])}@example.com"
      })

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_user(conn, user, organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp log_user(conn, user, organization), do: log_in_user(conn, user, organization: organization)

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} corridor"
    })
  end

  # Every stop is located: the map read draws only located stops, and an
  # unlocated one would silently vanish from the payload this file asserts.
  defp located_stop(organization, version, stop_id, lat, lon) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: "#{stop_id} stop",
      location_type: 0,
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  defp schedule_pattern(organization, version, route, attrs, stops) do
    schedule_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      route_pattern_id: attrs.id,
      route_pattern_name: attrs.name,
      direction_id: attrs.direction_id,
      route_pattern_sort_order: Map.get(attrs, :sort_order, 0),
      timing_name: attrs.name,
      stops: stops
    })
  end

  # Route CMP1 with the replacement pair: FULL runs S1, S2, S3, S4 and DEV
  # replaces S3 with two stops, a minute slower between the first two shared
  # stops. Its sections therefore split into one shared stretch (S1–S2, equal on
  # both sides), A's own two and B's own three, and its differences into a stop
  # difference at S3 and a running-time difference at S2.
  defp comparison_route(%{organization: organization, version: version}) do
    route = route(organization, version, "CMP1")

    located_stop(organization, version, "CMP1_S1", "40.7000", "-74.0200")
    located_stop(organization, version, "CMP1_S2", "40.7012", "-74.0178")
    located_stop(organization, version, "CMP1_S3", "40.7024", "-74.0156")
    located_stop(organization, version, "CMP1_S3A", "40.7018", "-74.0170")
    located_stop(organization, version, "CMP1_S3B", "40.7030", "-74.0148")
    located_stop(organization, version, "CMP1_S4", "40.7036", "-74.0134")

    calendar_fixture(organization.id, version.id, %{service_id: "WEEKDAY"})

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      service_description: "Weekday"
    })

    full =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "FULL", name: "Full", direction_id: 0, sort_order: 0},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 180, 180, 0},
          {"CMP1_S3", 360, 360, 0},
          {"CMP1_S4", 600, 660, 1}
        ]
      )

    dev =
      schedule_pattern(
        organization,
        version,
        route,
        %{id: "DEV", name: "Dev", direction_id: 0, sort_order: 1},
        [
          {"CMP1_S1", 0, 0, 1},
          {"CMP1_S2", 240, 240, 0},
          {"CMP1_S3A", 420, 420, 0},
          {"CMP1_S3B", 540, 540, 0},
          {"CMP1_S4", 780, 780, 1}
        ]
      )

    schedule_trip_fixture(organization.id, version.id, route.route_id, full, %{
      service_id: "WEEKDAY",
      start_time: "06:00:00"
    })

    schedule_trip_fixture(organization.id, version.id, route.route_id, dev, %{
      service_id: "WEEKDAY",
      start_time: "07:00:00"
    })

    %{route: route, full: full, dev: dev}
  end

  defp compare_path(version, route, params) do
    base = "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/compare"

    case Enum.reject(params, fn {_key, value} -> is_nil(value) end) do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end

  # The hook's own input: the pane's `data-map-payload` as JSON, exactly what the
  # browser parses before drawing.
  defp map_payload(view) do
    view
    |> element("#compare-map")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-map-payload")
    |> List.first()
    |> Jason.decode!()
  end

  defp series(payload), do: Enum.map(payload["sections"], & &1["series"])

  describe "map pane" do
    setup :editor_scope

    test "the replacement pair carries the map payload and its difference pins",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "DEV"}))

      assert has_element?(view, "#compare-map[phx-hook='PatternCompareMap'][phx-update='ignore']")
      refute has_element?(view, "#compare-map-unavailable")

      # The legend names the series and the stop shapes the hook draws, and the
      # numbered pin item appears with the differences.
      assert has_element?(view, "#compare-map-legend", "Only B")
      assert has_element?(view, "#compare-map-legend", "Difference")

      payload = map_payload(view)

      # A's sections in order, then B's own: S1–S2 is equal on both sides and
      # drawn once, A keeps S2–S3 and S3–S4, B's replacement adds three.
      assert series(payload) == ["both", "a", "a", "b", "b", "b"]

      assert Enum.map(payload["sections"], & &1["from_stop_id"]) == [
               "CMP1_S1",
               "CMP1_S2",
               "CMP1_S3",
               "CMP1_S2",
               "CMP1_S3A",
               "CMP1_S3B"
             ]

      assert Enum.map(payload["stops"], &{&1["stop_id"], &1["served"]}) == [
               {"CMP1_S1", "both"},
               {"CMP1_S2", "both"},
               {"CMP1_S3", "a"},
               {"CMP1_S3A", "b"},
               {"CMP1_S3B", "b"},
               {"CMP1_S4", "both"}
             ]

      # The differences in the read's order: the 60 s running-time difference at
      # S2 (row 1), then the replaced stop at S3 (row 2). Pins number from 1 and
      # sit on stops the payload draws.
      assert payload["pins"] == [
               %{"n" => 1, "stop_id" => "CMP1_S2"},
               %{"n" => 2, "stop_id" => "CMP1_S3"}
             ]

      stop_ids = MapSet.new(payload["stops"], & &1["stop_id"])

      assert Enum.all?(payload["pins"], &MapSet.member?(stop_ids, &1["stop_id"]))

      assert payload["ends"] == %{
               "a" => %{"first_stop_id" => "CMP1_S1", "last_stop_id" => "CMP1_S4"},
               "b" => %{"first_stop_id" => "CMP1_S1", "last_stop_id" => "CMP1_S4"}
             }
    end

    test "a map read outage takes only the map pane",
         %{conn: conn, version: version} = context do
      substitute_read_adapter(%{})
      %{route: route} = comparison_route(context)

      expect(CatalogReadAdapterMock, :load_pattern_comparison, 1, fn org, ver, params ->
        CatalogReadAdapter.Repo.load_pattern_comparison(org, ver, params)
      end)

      expect(CatalogReadAdapterMock, :load_pattern_compare_map, 1, fn _org, _ver, _a, _b ->
        {:error, :unavailable}
      end)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "DEV"}))

      refute has_element?(view, "#compare-map")
      assert has_element?(view, "#compare-map-unavailable", "The map is unavailable")
      assert has_element?(view, "#compare-map-unavailable-retry", "Retry map")

      # The comparison itself is untouched: slots, summary and the stop table
      # are all still there, so a map outage never costs the planner the page.
      assert has_element?(view, "#compare-slots")
      assert has_element?(view, "#summary-diff-1")
      assert has_element?(view, "#compare-stops", "Stop by stop")
      assert has_element?(view, "#compare-rows", "CMP1_S1 stop")
    end

    test "Retry map reloads only the map read",
         %{conn: conn, version: version} = context do
      substitute_read_adapter(%{})
      %{route: route} = comparison_route(context)
      reads = :atomics.new(1, [])

      # Exactly one comparison read for the whole case: the retry must not
      # repeat it, so the loaded comparison and its stream stay as they were.
      expect(CatalogReadAdapterMock, :load_pattern_comparison, 1, fn org, ver, params ->
        CatalogReadAdapter.Repo.load_pattern_comparison(org, ver, params)
      end)

      stub(CatalogReadAdapterMock, :load_pattern_compare_map, fn org, ver, a, b ->
        case :atomics.add_get(reads, 1, 1) do
          1 -> {:error, :unavailable}
          _recovered -> CatalogReadAdapter.Repo.load_pattern_compare_map(org, ver, a, b)
        end
      end)

      {:ok, view, _html} =
        live(conn, compare_path(version, route, %{"a" => "FULL", "b" => "DEV"}))

      assert has_element?(view, "#compare-map-unavailable")

      view |> element("#compare-map-unavailable-retry") |> render_click()

      refute has_element?(view, "#compare-map-unavailable")
      assert has_element?(view, "#compare-map[phx-hook='PatternCompareMap']")
      assert has_element?(view, "#compare-map-legend", "Difference")
      assert has_element?(view, "#compare-stops", "Stop by stop")

      assert :atomics.get(reads, 1) == 2
      assert Enum.map(map_payload(view)["pins"], & &1["n"]) == [1, 2]
    end

    test "a comparison without B draws A alone and pins nothing",
         %{conn: conn, version: version} = context do
      %{route: route} = comparison_route(context)

      {:ok, view, _html} = live(conn, compare_path(version, route, %{"a" => "FULL"}))

      assert has_element?(view, "#compare-map")
      refute has_element?(view, "#compare-map-unavailable")

      # A alone: the legend names A's line and nothing B or a pin could explain.
      assert has_element?(view, "#compare-map-legend", "A")
      refute has_element?(view, "#compare-map-legend", "Only B")

      payload = map_payload(view)

      assert series(payload) == ["a", "a", "a"]
      assert Enum.map(payload["stops"], & &1["served"]) == ["a", "a", "a", "a"]
      assert payload["pins"] == []
      assert payload["ends"]["b"] == nil
    end
  end
end

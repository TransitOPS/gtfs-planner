defmodule GtfsPlanner.Gtfs.CatalogReadAdapterTest do
  # `async: false` is mandatory: the catalog read adapter is resolved from global
  # application config, and the Mox-backed cases below swap that config. Running
  # alone keeps the real-Repo cases on the production adapter and the Mox cases
  # isolated from other suites.
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.CatalogReadAdapterMock
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import Mox

  @adapter_key :gtfs_catalog_read_adapter

  setup do
    organization = organization_fixture()
    gtfs_version = gtfs_version_fixture(organization.id)
    %{organization: organization, gtfs_version: gtfs_version}
  end

  describe "route catalog through the production Repo adapter" do
    test "ready route catalog returns rows, total, page, route_types, and agencies", %{
      organization: org,
      gtfs_version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1", route_type: 3, agency_id: "a1"})
      route_fixture(org.id, version.id, %{route_id: "r2", route_type: 0, agency_id: "a2"})
      route_fixture(org.id, version.id, %{route_id: "r3", route_type: 3, agency_id: "a1"})

      assert {:ok, page} = Gtfs.load_route_catalog(org.id, version.id, page: 1, per_page: 25)

      assert page.total_count == 3
      assert page.page == 1
      assert Enum.map(page.rows, & &1.route_id) == ["r1", "r2", "r3"]
      assert page.route_types == [0, 3]
      assert page.agencies == ["a1", "a2"]
      assert %Route{} = hd(page.rows)
    end

    test "out-of-range page 999 with 3 pages of data returns rows at page 3", %{
      organization: org,
      gtfs_version: version
    } do
      for i <- 1..5, do: route_fixture(org.id, version.id, %{route_id: "r#{i}"})

      assert {:ok, page} = Gtfs.load_route_catalog(org.id, version.id, page: 999, per_page: 2)

      assert page.total_count == 5
      assert page.page == 3
      assert Enum.map(page.rows, & &1.route_id) == ["r5"]
    end

    test "page 0 clamps to the first page", %{organization: org, gtfs_version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      assert {:ok, page} = Gtfs.load_route_catalog(org.id, version.id, page: 0, per_page: 25)
      assert page.page == 1
      assert Enum.map(page.rows, & &1.route_id) == ["r1"]
    end

    test "negative page clamps to the first page", %{organization: org, gtfs_version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      assert {:ok, page} = Gtfs.load_route_catalog(org.id, version.id, page: -7, per_page: 25)
      assert page.page == 1
      assert length(page.rows) == 1
    end

    test "non-integer page clamps to the first page", %{organization: org, gtfs_version: version} do
      route_fixture(org.id, version.id, %{route_id: "r1"})

      assert {:ok, page} =
               Gtfs.load_route_catalog(org.id, version.id, page: "garbage", per_page: 25)

      assert page.page == 1
      assert length(page.rows) == 1
    end

    test "zero routes clamp any page to 1 with empty rows", %{
      organization: org,
      gtfs_version: version
    } do
      assert {:ok, page} = Gtfs.load_route_catalog(org.id, version.id, page: 5, per_page: 25)

      assert page.total_count == 0
      assert page.page == 1
      assert page.rows == []
      assert page.route_types == []
      assert page.agencies == []
    end

    test "even division keeps the last full page canonical", %{
      organization: org,
      gtfs_version: version
    } do
      for i <- 1..4, do: route_fixture(org.id, version.id, %{route_id: "r#{i}"})

      assert {:ok, page2} = Gtfs.load_route_catalog(org.id, version.id, page: 2, per_page: 2)
      assert page2.page == 2
      assert Enum.map(page2.rows, & &1.route_id) == ["r3", "r4"]

      assert {:ok, clamped} = Gtfs.load_route_catalog(org.id, version.id, page: 3, per_page: 2)
      assert clamped.page == 2
      assert Enum.map(clamped.rows, & &1.route_id) == ["r3", "r4"]
    end

    test "search filter is preserved through the canonical page", %{
      organization: org,
      gtfs_version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "alpha", route_long_name: "Alpha Line"})
      route_fixture(org.id, version.id, %{route_id: "beta", route_long_name: "Beta Line"})

      assert {:ok, page} =
               Gtfs.load_route_catalog(org.id, version.id, page: 9, per_page: 25, search: "alpha")

      assert page.total_count == 1
      assert page.page == 1
      assert Enum.map(page.rows, & &1.route_id) == ["alpha"]
    end
  end

  describe "stop catalog through the production Repo adapter" do
    test "ready stop catalog returns rows with route enrichment", %{
      organization: org,
      gtfs_version: version
    } do
      _station = stop_fixture(org.id, version.id, %{stop_id: "st1", location_type: 1})
      _other = stop_fixture(org.id, version.id, %{stop_id: "st2", location_type: 1})

      route_fixture(org.id, version.id, %{route_id: "r1", route_short_name: "1"})
      trip = trip_fixture(org.id, version.id, "r1")
      stop_time_fixture(org.id, version.id, trip.trip_id, "st1")

      assert {:ok, page} = Gtfs.load_stop_catalog(org.id, version.id, page: 1, per_page: 50)

      assert page.total_count == 2
      assert page.page == 1
      assert Enum.map(page.rows, & &1.stop_id) == ["st1", "st2"]
      assert %Stop{} = hd(page.rows)

      assert Enum.any?(page.available_routes, &(&1.route_id == "r1"))
      assert [%{route_id: "r1"} | _] = Map.get(page.routes_by_stop, "st1", [])
      assert Map.get(page.routes_by_stop, "st2", []) == []
    end

    test "stop catalog clamps an out-of-range page", %{organization: org, gtfs_version: version} do
      for i <- 1..3, do: stop_fixture(org.id, version.id, %{stop_id: "st#{i}", location_type: 1})

      assert {:ok, page} = Gtfs.load_stop_catalog(org.id, version.id, page: 99, per_page: 2)

      assert page.total_count == 3
      assert page.page == 2
      assert Enum.map(page.rows, & &1.stop_id) == ["st3"]
    end
  end

  describe "route and stop detail through the production Repo adapter" do
    test "fetch_catalog_route returns the route", %{organization: org, gtfs_version: version} do
      route = route_fixture(org.id, version.id, %{route_id: "r1"})

      assert {:ok, %Route{} = fetched} = Gtfs.fetch_catalog_route(org.id, version.id, "r1")
      assert fetched.id == route.id
    end

    test "fetch_catalog_route with an unknown route_id returns not_found", %{
      organization: org,
      gtfs_version: version
    } do
      assert Gtfs.fetch_catalog_route(org.id, version.id, "missing") == {:error, :not_found}
    end

    test "load_catalog_route_patterns returns the route patterns", %{
      organization: org,
      gtfs_version: version
    } do
      route_fixture(org.id, version.id, %{route_id: "r1"})
      insert_route_pattern(org.id, version.id, "r1", "rp1", 0)
      insert_route_pattern(org.id, version.id, "r1", "rp2", 1)

      assert {:ok, patterns} = Gtfs.load_catalog_route_patterns(org.id, version.id, "r1")

      assert length(patterns) == 2
      assert Enum.all?(patterns, &match?(%RoutePattern{}, &1))
      assert Enum.map(patterns, & &1.route_pattern_id) == ["rp1", "rp2"]
    end

    test "load_catalog_route_patterns returns an empty list for an unknown route", %{
      organization: org,
      gtfs_version: version
    } do
      assert Gtfs.load_catalog_route_patterns(org.id, version.id, "missing") == {:ok, []}
    end

    test "fetch_catalog_stop returns the stop", %{organization: org, gtfs_version: version} do
      stop = stop_fixture(org.id, version.id, %{stop_id: "st1"})

      assert {:ok, %Stop{} = fetched} = Gtfs.fetch_catalog_stop(org.id, version.id, "st1")
      assert fetched.id == stop.id
    end

    test "fetch_catalog_stop with an unknown stop_id returns not_found", %{
      organization: org,
      gtfs_version: version
    } do
      assert Gtfs.fetch_catalog_stop(org.id, version.id, "missing") == {:error, :not_found}
    end

    test "load_catalog_stop_regions returns independent ok outcomes", %{
      organization: org,
      gtfs_version: version
    } do
      _station = stop_fixture(org.id, version.id, %{stop_id: "st1", location_type: 1})
      level = level_fixture(org.id, version.id, %{level_id: "L1"})

      _child =
        stop_fixture(org.id, version.id, %{
          stop_id: "child1",
          location_type: 0,
          parent_station: "st1",
          level_id: "L1"
        })

      assert {:ok, %Stop{} = fetched} = Gtfs.fetch_catalog_stop(org.id, version.id, "st1")

      regions = Gtfs.load_catalog_stop_regions(org.id, version.id, fetched)

      assert {:ok, [%Stop{stop_id: "child1"}]} = regions.child_stops
      assert {:ok, levels} = regions.levels
      assert Enum.any?(levels, fn entry -> entry.level.id == level.id end)
      assert {:ok, []} = regions.pathways
      assert {:ok, nil} = regions.editing_status
    end
  end

  describe "exception scope through the production Repo adapter" do
    test "a non-connection exception propagates instead of becoming unavailable", %{
      gtfs_version: version
    } do
      assert_raise Ecto.Query.CastError, fn ->
        Gtfs.load_route_catalog("not-a-uuid", version.id, [])
      end
    end

    test "a non-connection exception propagates for stop detail reads", %{
      gtfs_version: version
    } do
      assert_raise Ecto.Query.CastError, fn ->
        Gtfs.fetch_catalog_stop("not-a-uuid", version.id, "st1")
      end
    end
  end

  describe "outcome classification with a configured adapter" do
    setup :verify_on_exit!

    setup do
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

    test "stop catalog route enrichment failure returns a partial page with loaded rows" do
      stop = %Stop{stop_id: "st1"}

      partial_page = %{
        rows: [stop],
        total_count: 1,
        page: 1,
        available_routes: [],
        routes_by_stop: %{}
      }

      expect(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _version, _opts ->
        {:partial, partial_page, :route_enrichment_unavailable}
      end)

      assert {:partial, ^partial_page, :route_enrichment_unavailable} =
               Gtfs.load_stop_catalog(Ecto.UUID.generate(), Ecto.UUID.generate(), [])
    end

    test "primary stop/count failure returns unavailable" do
      expect(CatalogReadAdapterMock, :load_stop_catalog, fn _org, _version, _opts ->
        {:error, :unavailable}
      end)

      assert Gtfs.load_stop_catalog(Ecto.UUID.generate(), Ecto.UUID.generate(), []) ==
               {:error, :unavailable}
    end

    test "route catalog connection loss returns unavailable" do
      expect(CatalogReadAdapterMock, :load_route_catalog, fn _org, _version, _opts ->
        {:error, :unavailable}
      end)

      assert Gtfs.load_route_catalog(Ecto.UUID.generate(), Ecto.UUID.generate(), []) ==
               {:error, :unavailable}
    end

    test "an unexpected exception raised by the adapter propagates" do
      expect(CatalogReadAdapterMock, :load_route_catalog, fn _org, _version, _opts ->
        raise RuntimeError, "boom"
      end)

      assert_raise RuntimeError, "boom", fn ->
        Gtfs.load_route_catalog(Ecto.UUID.generate(), Ecto.UUID.generate(), [])
      end
    end

    test "detail reads surface not_found and unavailable from the adapter" do
      id = Ecto.UUID.generate()

      expect(CatalogReadAdapterMock, :fetch_route, fn _org, _version, "missing" ->
        {:error, :not_found}
      end)

      expect(CatalogReadAdapterMock, :fetch_stop, fn _org, _version, "missing" ->
        {:error, :unavailable}
      end)

      expect(CatalogReadAdapterMock, :load_route_patterns, fn _org, _version, _route_id ->
        {:error, :unavailable}
      end)

      assert Gtfs.fetch_catalog_route(id, id, "missing") == {:error, :not_found}
      assert Gtfs.fetch_catalog_stop(id, id, "missing") == {:error, :unavailable}
      assert Gtfs.load_catalog_route_patterns(id, id, "r1") == {:error, :unavailable}
    end

    test "stop regions resolve independently through the adapter" do
      id = Ecto.UUID.generate()
      station = %Stop{stop_id: "st1"}

      expect(CatalogReadAdapterMock, :load_stop_regions, fn _org, _version, ^station ->
        %{
          child_stops: {:ok, []},
          levels: {:error, :unavailable},
          pathways: {:ok, []},
          editing_status: {:ok, nil}
        }
      end)

      regions = Gtfs.load_catalog_stop_regions(id, id, station)

      assert regions.child_stops == {:ok, []}
      assert regions.levels == {:error, :unavailable}
      assert regions.pathways == {:ok, []}
      assert regions.editing_status == {:ok, nil}
    end
  end

  defp insert_route_pattern(organization_id, gtfs_version_id, route_id, pattern_id, direction_id) do
    %RoutePattern{}
    |> RoutePattern.changeset(%{
      route_pattern_id: pattern_id,
      route_id: route_id,
      direction_id: direction_id,
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id
    })
    |> Repo.insert!()
  end
end

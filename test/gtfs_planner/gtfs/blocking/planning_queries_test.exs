defmodule GtfsPlanner.Gtfs.Blocking.PlanningQueriesTest do
  @moduledoc """
  Merge evidence for the reads a loaded planning context is built from: the
  `shape_id` a trip row now carries, the four planning-input kinds, shape points,
  stop paths and the garage and vehicle-type maps.

  Every case is scoped: the same rows are written into a foreign organization and
  into a second version of this organization, and the reads must not return any of
  them. The scope is the whole of CR-4's guarantee for these reads, so it is
  asserted per kind rather than once.

  Rows are created inside the SQL Sandbox transaction and rolled back. The focused
  gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/planning_queries_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes
  alias GtfsPlanner.Gtfs.Blocking.Distance
  alias GtfsPlanner.Gtfs.Blocking.Queries
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Operations

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    foreign = organization_fixture()

    %{
      organization: organization,
      version: version,
      other_version: gtfs_version_fixture(organization.id),
      # A version belongs to one organization, so a foreign organization's rows
      # are written into its own version. The planning-input tables carry no
      # version lock and are written into *this* version instead, which is the
      # stronger scope check: a foreign organization's row sitting in our own
      # version must not surface either.
      foreign: foreign,
      foreign_version: gtfs_version_fixture(foreign.id)
    }
  end

  describe "trip_rows/3" do
    test "each trip carries its own shape_id, nil for a trip without one", %{
      organization: o,
      version: v
    } do
      shaped_a = trip!(o, v, "a", shape_id: "SH-A")
      shaped_b = trip!(o, v, "b", shape_id: "SH-A")
      shapeless = trip!(o, v, "c")

      rows = Queries.trip_rows(o.id, v.id, {:services, ["WK"]})

      assert length(rows) == 3

      assert Map.new(rows, &{&1.trip_id, &1.id}) == %{
               "a" => shaped_a.id,
               "b" => shaped_b.id,
               "c" => shapeless.id
             }

      assert Map.new(rows, &{&1.trip_id, &1.shape_id}) == %{
               "a" => "SH-A",
               "b" => "SH-A",
               "c" => nil
             }

      # Two trips naming one shape, so the shape is measured once and shared.
      assert Enum.count(rows, &(&1.shape_id == "SH-A")) == 2
    end

    test "a foreign organization's trip and another version's trip are absent", %{
      organization: o,
      version: v,
      foreign: foreign,
      foreign_version: fv,
      other_version: other
    } do
      mine = trip!(o, v, "mine", shape_id: "SH-MINE")
      _theirs = trip!(foreign, fv, "theirs", shape_id: "SH-THEIRS")
      _elsewhere = trip!(o, other, "elsewhere", shape_id: "SH-OTHER")

      rows = Queries.trip_rows(o.id, v.id, {:services, ["WK"]})

      assert MapSet.new(rows, & &1.trip_id) == MapSet.new([mine.trip_id])
      assert Enum.map(rows, & &1.shape_id) == ["SH-MINE"]
    end
  end

  describe "planning_rows/3" do
    test "returns the four kinds of this organization and version, attributes only for the given services",
         %{organization: o, version: v, foreign: foreign, other_version: other} do
      garage = garage_fixture(o.id)

      own_route = route_operating_setting_fixture(o.id, v.id, %{route_id: "R1"})

      _own_weekday =
        block_attribute_fixture(o.id, v.id, %{
          service_id: "WK",
          block_id: "101",
          garage_id: garage.id
        })

      _own_saturday = block_attribute_fixture(o.id, v.id, %{service_id: "SAT", block_id: "201"})
      _own_spare = block_attribute_fixture(o.id, v.id, %{service_id: "WK", block_id: "102"})

      own_deadhead =
        deadhead_time_fixture(o.id, v.id, %{
          from_ref: {:garage, garage.id},
          to_ref: {:stop, "S1"},
          minutes: 12
        })

      own_relief = relief_point_fixture(o.id, v.id, %{stop_id: "S1"})

      # The same four kinds, out of scope: a foreign organization and a second
      # version of this organization.
      route_operating_setting_fixture(foreign.id, v.id, %{route_id: "R1"})
      block_attribute_fixture(foreign.id, v.id, %{service_id: "WK", block_id: "101"})
      deadhead_time_fixture(foreign.id, v.id, %{from_ref: {:stop, "S1"}, to_ref: {:stop, "S2"}})
      relief_point_fixture(foreign.id, v.id, %{stop_id: "S9"})

      route_operating_setting_fixture(o.id, other.id, %{route_id: "R1"})
      block_attribute_fixture(o.id, other.id, %{service_id: "WK", block_id: "101"})
      deadhead_time_fixture(o.id, other.id, %{from_ref: {:stop, "S3"}, to_ref: {:stop, "S4"}})
      relief_point_fixture(o.id, other.id, %{stop_id: "S8"})

      assert Queries.planning_rows(o.id, v.id, ["WK"]) == %{
               route_settings: [
                 %{
                   route_id: own_route.route_id,
                   garage_id: nil,
                   required_vehicle_type_id: nil
                 }
               ],
               attributes: [
                 %{service_id: "WK", block_id: "101", garage_id: garage.id, vehicle_type_id: nil},
                 %{service_id: "WK", block_id: "102", garage_id: nil, vehicle_type_id: nil}
               ],
               deadhead: [
                 %{
                   from_ref: own_deadhead.from_ref,
                   to_ref: own_deadhead.to_ref,
                   minutes: own_deadhead.minutes
                 }
               ],
               relief: [%{stop_id: own_relief.stop_id}]
             }

      # The Saturday row is kept in the database for that day type rather than
      # deleted, and it is not an input of a weekday context.
      assert Repo.aggregate(
               from(a in BlockAttribute, where: a.service_id == "SAT"),
               :count
             ) == 1

      # Every returned reference is one step 7 can decode; a row whose refs do not
      # decode is skipped by the builder, so the read must not invent a form.
      assert DeadheadTimes.decode_ref(own_deadhead.from_ref) == {:ok, {:garage, garage.id}}
      assert DeadheadTimes.decode_ref(own_deadhead.to_ref) == {:ok, {:stop, "S1"}}
    end

    test "an empty service list returns no attribute rows and the other three kinds",
         %{organization: o, version: v} do
      _attribute = block_attribute_fixture(o.id, v.id, %{service_id: "WK", block_id: "101"})
      _relief = relief_point_fixture(o.id, v.id, %{stop_id: "S1"})

      assert Queries.planning_rows(o.id, v.id, []) == %{
               route_settings: [],
               attributes: [],
               deadhead: [],
               relief: [%{stop_id: "S1"}]
             }
    end

    test "attributes carry the vehicle type a route or attribute row names",
         %{organization: o, version: v} do
      vehicle_type = vehicle_type_fixture(o.id)

      _attribute =
        block_attribute_fixture(o.id, v.id, %{
          service_id: "WK",
          block_id: "101",
          vehicle_type_id: vehicle_type.id
        })

      _route =
        route_operating_setting_fixture(o.id, v.id, %{
          route_id: "R1",
          required_vehicle_type_id: vehicle_type.id
        })

      rows = Queries.planning_rows(o.id, v.id, ["WK"])

      assert [%{vehicle_type_id: type_id}] = rows.attributes
      assert [%{required_vehicle_type_id: required_id}] = rows.route_settings
      assert type_id == vehicle_type.id
      assert required_id == vehicle_type.id
    end
  end

  describe "shape_points/3" do
    test "returns each shape's points in shape_pt_sequence order as floats", %{
      organization: o,
      version: v
    } do
      # Inserted out of order, as a feed that lists points back-to-front would.
      shape_point!(o, v, "SH-A", 3, "42.0030", "-71.0000")
      shape_point!(o, v, "SH-A", 1, "42.0000", "-71.0000")
      shape_point!(o, v, "SH-A", 2, "42.0015", "-71.0000")
      shape_point!(o, v, "SH-B", 1, "43.0000", "-71.0000")
      shape_point!(o, v, "SH-B", 2, "43.0020", "-71.0000")

      points = Queries.shape_points(o.id, v.id, ["SH-A", "SH-B"])

      assert points == %{
               "SH-A" => [{42.0, -71.0}, {42.0015, -71.0}, {42.003, -71.0}],
               "SH-B" => [{43.0, -71.0}, {43.002, -71.0}]
             }

      for {_shape_id, path} <- points do
        assert Enum.all?(path, fn {lat, lon} -> is_float(lat) and is_float(lon) end)
      end

      # The answer is the input step 7 hands to the path measure.
      assert Distance.path_km(points["SH-A"]) > 0.0
      assert Distance.path_km(points["SH-B"]) > 0.0
    end

    test "a shape with no points, another version's shape and a foreign organization's shape are absent",
         %{organization: o, version: v, foreign: foreign, other_version: other} do
      shape_point!(o, v, "SH-A", 1, "42.0000", "-71.0000")
      shape_point!(foreign.id, v.id, "SH-FOREIGN", 1, "42.0000", "-71.0000")
      shape_point!(o.id, other.id, "SH-OTHER", 1, "42.0000", "-71.0000")

      assert Queries.shape_points(o.id, v.id, ["SH-A", "SH-EMPTY", "SH-FOREIGN", "SH-OTHER"]) ==
               %{
                 "SH-A" => [{42.0, -71.0}]
               }
    end

    test "asking for no shapes returns an empty map", %{organization: o, version: v} do
      shape_point!(o, v, "SH-A", 1, "42.0000", "-71.0000")

      assert Queries.shape_points(o.id, v.id, []) == %{}
    end
  end

  describe "stop_paths/3" do
    test "returns each trip's stops in stop_sequence order, substituting the parent's coordinates",
         %{organization: o, version: v} do
      origin = stop!(o, v, "P1", "42.0000", "-71.0000")
      child = parented_stop!(o, v, "P2", "P2A")
      parent = stop!(o, v, "P2A", "42.0020", "-71.0000")
      # No coordinates of its own and no parent station: it must not appear.
      unplaced = stop_fixture(o.id, v.id, %{stop_id: "P3", stop_lat: nil, stop_lon: nil})

      trip = trip!(o, v, "t1")

      # Inserted out of order, as a feed that lists stops back-to-front would.
      stop_time!(o, v, trip.trip_id, unplaced.stop_id, 3, "08:20:00")
      stop_time!(o, v, trip.trip_id, origin.stop_id, 1, "08:00:00")
      stop_time!(o, v, trip.trip_id, child.stop_id, 2, "08:10:00")

      assert Queries.stop_paths(o.id, v.id, [trip.trip_id]) == %{
               "t1" => [{42.0, -71.0}, {42.002, -71.0}]
             }

      # The child stop's own row is the one named, but the point walked is the
      # parent's, which is what the read substituted.
      assert child.parent_station == "P2A"
      assert child.stop_lat == nil
      assert parent.stop_id == "P2A"
      assert origin.stop_lat == Decimal.new("42.0000")

      # The answer is the input step 7 hands to the path measure.
      assert Distance.path_km(Queries.stop_paths(o.id, v.id, [trip.trip_id])["t1"]) > 0.0
    end

    test "a stop the version does not describe is dropped, and another trip's path is unaffected",
         %{organization: o, version: v} do
      first = stop!(o, v, "S1", "42.0000", "-71.0000")
      second = stop!(o, v, "S2", "42.0010", "-71.0000")

      trip = trip!(o, v, "t1")
      other_trip = trip!(o, v, "t2")

      stop_time!(o, v, trip.trip_id, first.stop_id, 1, "08:00:00")
      stop_time!(o, v, trip.trip_id, "S_ABSENT", 2, "08:10:00")
      stop_time!(o, v, trip.trip_id, second.stop_id, 3, "08:20:00")
      stop_time!(o, v, other_trip.trip_id, second.stop_id, 1, "09:00:00")
      stop_time!(o, v, other_trip.trip_id, first.stop_id, 2, "09:10:00")

      assert Queries.stop_paths(o.id, v.id, [trip.trip_id, other_trip.trip_id]) == %{
               "t1" => [{42.0, -71.0}, {42.001, -71.0}],
               "t2" => [{42.001, -71.0}, {42.0, -71.0}]
             }
    end

    test "another organization's and another version's stop times are absent", %{
      organization: o,
      version: v,
      foreign: foreign,
      foreign_version: fv,
      other_version: other
    } do
      mine = stop!(o, v, "S1", "42.0000", "-71.0000")
      theirs = stop!(foreign, fv, "S1", "43.0000", "-71.0000")
      elsewhere = stop!(o, other, "S1", "44.0000", "-71.0000")

      trip = trip!(o, v, "t1")
      stop_time!(o, v, trip.trip_id, mine.stop_id, 1, "08:00:00")
      stop_time!(foreign, fv, trip.trip_id, theirs.stop_id, 1, "08:00:00")
      stop_time!(o, other, trip.trip_id, elsewhere.stop_id, 1, "08:00:00")

      assert Queries.stop_paths(o.id, v.id, [trip.trip_id]) == %{"t1" => [{42.0, -71.0}]}
    end

    test "a trip with no stops at all has no path", %{organization: o, version: v} do
      trip = trip!(o, v, "t1")

      assert Queries.stop_paths(o.id, v.id, [trip.trip_id]) == %{}
    end
  end

  describe "Operations.planning_garages/1 and planning_vehicle_types/1" do
    test "returns the garages and vehicle types of one organization keyed by UUID", %{
      organization: o,
      foreign: foreign
    } do
      garage =
        garage_fixture(o.id, %{
          "garage_id" => "GAR-1",
          "name" => "North Yard",
          "lat" => Decimal.new("42.3601"),
          "lon" => Decimal.new("-71.0589")
        })

      untyped = vehicle_type_fixture(o.id, %{"name" => "Orion"})

      limited =
        vehicle_type_fixture(o.id, %{"name" => "Nimbus", "max_out_hours" => Decimal.new("5.5")})

      _foreign_garage = garage_fixture(foreign.id, %{"garage_id" => "GAR-1"})
      _foreign_type = vehicle_type_fixture(foreign.id, %{"name" => "Orion"})

      assert Operations.planning_garages(o.id) == %{
               garage.id => %{
                 id: garage.id,
                 garage_id: "GAR-1",
                 name: "North Yard",
                 lat: 42.3601,
                 lon: -71.0589
               }
             }

      assert Operations.planning_vehicle_types(o.id) == %{
               untyped.id => %{id: untyped.id, name: "Orion", max_out_minutes: nil},
               limited.id => %{id: limited.id, name: "Nimbus", max_out_minutes: 330}
             }

      garage_entry = Operations.planning_garages(o.id)[garage.id]
      assert is_float(garage_entry.lat) and is_float(garage_entry.lon)
      assert Map.keys(garage_entry) |> Enum.sort() == [:garage_id, :id, :lat, :lon, :name]

      assert Map.keys(Operations.planning_vehicle_types(o.id)[limited.id]) |> Enum.sort() ==
               [:id, :max_out_minutes, :name]
    end

    test "an organization with no garages or types returns empty maps", %{organization: o} do
      assert Operations.planning_garages(o.id) == %{}
      assert Operations.planning_vehicle_types(o.id) == %{}
    end
  end

  describe "query counts" do
    test "each read costs one query per kind whatever the number of rows", %{
      organization: o,
      version: v
    } do
      route_operating_setting_fixture(o.id, v.id, %{route_id: "R1"})
      route_operating_setting_fixture(o.id, v.id, %{route_id: "R2"})
      block_attribute_fixture(o.id, v.id, %{service_id: "WK", block_id: "101"})
      relief_point_fixture(o.id, v.id, %{stop_id: "S1"})
      deadhead_time_fixture(o.id, v.id, %{from_ref: {:stop, "S1"}, to_ref: {:stop, "S2"}})
      deadhead_time_fixture(o.id, v.id, %{from_ref: {:stop, "S2"}, to_ref: {:stop, "S3"}})

      shape_point!(o, v, "SH-A", 1, "42.0000", "-71.0000")
      shape_point!(o, v, "SH-A", 2, "42.0010", "-71.0000")
      shape_point!(o, v, "SH-B", 1, "43.0000", "-71.0000")

      stop = stop!(o, v, "S1", "42.0000", "-71.0000")
      trip = trip!(o, v, "t1")
      other_trip = trip!(o, v, "t2")
      stop_time!(o, v, trip.trip_id, stop.stop_id, 1, "08:00:00")
      stop_time!(o, v, other_trip.trip_id, stop.stop_id, 1, "09:00:00")

      assert {rows, 4} = count_queries(fn -> Queries.planning_rows(o.id, v.id, ["WK"]) end)
      assert length(rows.attributes) == 1
      assert length(rows.deadhead) == 2

      assert {points, 1} =
               count_queries(fn -> Queries.shape_points(o.id, v.id, ["SH-A", "SH-B"]) end)

      assert map_size(points) == 2

      assert {paths, 1} =
               count_queries(fn ->
                 Queries.stop_paths(o.id, v.id, [trip.trip_id, other_trip.trip_id])
               end)

      assert map_size(paths) == 2

      # One shape is still one query, so a day of many shapes is bounded too.
      assert {_points, 1} = count_queries(fn -> Queries.shape_points(o.id, v.id, ["SH-A"]) end)
    end
  end

  # --- helpers ---------------------------------------------------------------

  # The second argument is always a version of the organization given as the
  # first: `Gtfs.create_trip/1` and `Gtfs.create_stop/1` take the version's
  # org-scoped share lock, so a foreign organization's row cannot be written into
  # our version at all.
  defp trip!(organization, version, trip_id, attrs \\ %{}) do
    trip_fixture(
      organization.id,
      version.id,
      "R1",
      attrs
      |> Map.new()
      |> Map.put(:trip_id, trip_id)
      |> Map.put(:service_id, "WK")
    )
  end

  defp stop!(organization, version, stop_id, lat, lon) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  # A child stop with no coordinates of its own, written through the permissive
  # import changeset the fixture module uses because a parented stop needs a level.
  defp parented_stop!(organization, version, stop_id, parent_station) do
    stop_with_coordinates_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      parent_station: parent_station,
      stop_lat: nil,
      stop_lon: nil
    })
  end

  defp stop_time!(organization, version, trip_id, stop_id, stop_sequence, time) do
    stop_time_fixture(organization.id, version.id, trip_id, stop_id, %{
      stop_sequence: stop_sequence,
      arrival_time: time,
      departure_time: time
    })
  end

  defp shape_point!(organization, version, shape_id, sequence, lat, lon) do
    %Shape{}
    |> Shape.changeset(%{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      shape_id: shape_id,
      shape_pt_sequence: sequence,
      shape_pt_lat: Decimal.new(lat),
      shape_pt_lon: Decimal.new(lon)
    })
    |> Repo.insert!()
  end

  # Ecto runs a repo telemetry handler in the process that issued the query, so
  # counting only this test's own messages keeps other tests' queries out.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = "blocking-planning-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, _metadata, pid ->
        if self() == pid, do: send(pid, {:blocking_query, handler_id})
      end,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    try do
      {fun.(), drain_queries(handler_id, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(handler_id, count) do
    receive do
      {:blocking_query, ^handler_id} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end
end

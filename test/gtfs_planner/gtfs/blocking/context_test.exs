defmodule GtfsPlanner.Gtfs.Blocking.ContextTest do
  @moduledoc """
  Merge evidence for the planning context: the layover-only context that
  reproduces spec 05's behaviour, the fingerprint every reviewed planning write
  carries (INV-7, R12), and the builder that fills the struct from a version's
  reads.

  The first two groups are pure — `Context` reads its arguments and touches no
  repository, clock, file or network — so `layover_only/1` and `digest/1` need no
  fixtures. The third group goes through the real `Blocking.load_day/3`, because
  that is the path the builder runs on and the only place its reads can be
  observed as a whole.

  The digest cases are the ones that matter for INV-7, and they are written to
  fail if the fingerprint narrows. A digest covering only the inputs one plan
  happened to read would let a write through that nobody reviewed, so every
  field is asserted to change it — including a field for a service the day does
  not use, which is the over-invalidation the spec accepts on purpose (Notes:
  "`Context.digest/1` fingerprints the whole context instead of enumerating
  inputs; it over-invalidates a preview when an unrelated planning input
  changes, which is safe").

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/context_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.StationReport2.Helpers

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.Gtfs.Blocking
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @garage_uuid "11111111-1111-4111-8111-111111111111"
  @vehicle_type_uuid "22222222-2222-4222-8222-222222222222"

  describe "layover_only/1" do
    test "carries the layover and nothing else" do
      context = Context.layover_only(7)

      assert context.min_layover_minutes == 7
      assert context.planning? == false

      assert context.garages == %{}
      assert context.vehicle_types == %{}
      assert context.route_settings == %{}
      assert context.attributes == %{}
      assert context.entered_minutes == %{}
      assert MapSet.equal?(context.relief_stop_ids, MapSet.new())
      assert context.fleet == []
      assert context.trip_km == %{}
    end

    test "leaves every other field at the struct's default" do
      assert %Context{
               min_layover_minutes: 0,
               max_block_minutes: nil,
               pull_out_buffer_minutes: 0,
               interlining: :any,
               default_garage_id: nil,
               deadhead_speed_kmh: 30,
               deadhead_circuity: 1.3,
               max_piece_minutes: nil,
               planning?: false
             } = Context.layover_only(0)
    end

    test "digests differently from a planning context with the same layover" do
      # The same layover value planned against is a different input set, and
      # `planning?` is what tells the two apart. A fingerprint taken from a
      # layover-only context must not match a real one.
      assert Context.digest(Context.layover_only(7)) !=
               Context.digest(%Context{min_layover_minutes: 7})
    end
  end

  describe "digest/1" do
    test "is a lowercase SHA-256 hex digest" do
      assert Context.digest(Context.layover_only(5)) =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "two equal contexts digest alike however their maps were built" do
      garages = complete_context().garages

      first = complete_context()
      second = complete_context(garages: garages |> Enum.to_list() |> Enum.reverse() |> Map.new())

      # Two equal contexts, the second with the garage map keyed in the opposite
      # insertion order. A digest taken over the struct's map order rather than
      # over sorted entries would answer differently here.
      refute Map.keys(first.garages) == Map.keys(second.garages)
      assert first == second
      assert Context.digest(first) == Context.digest(second)
    end

    test "changing any one field changes the digest" do
      base = complete_context()
      baseline = Context.digest(base)

      changes = [
        {"a setting", &put_in(&1.min_layover_minutes, 11)},
        {"a second setting", &put_in(&1.interlining, :none)},
        {"one entered minute", &put_in(&1.entered_minutes[{{:stop, "S1"}, {:stop, "S2"}}], 99)},
        {"one marked relief stop",
         &put_in(&1.relief_stop_ids, MapSet.put(&1.relief_stop_ids, "S9"))},
        {"one attribute row",
         &put_in(&1.attributes[{"WKDY", "101"}], %{
           garage_id: @vehicle_type_uuid,
           vehicle_type_id: nil
         })},
        {"one garage coordinate", &put_in(&1.garages[@garage_uuid].lat, 40.9)},
        {"one fleet count",
         &put_in(&1.fleet, [%{garage_id: @garage_uuid, vehicle_type_id: nil, count: 2}])},
        {"one trip distance", &put_in(&1.trip_km["trip-1"], {9.5, :path})},
        {"the planning flag", &%{&1 | planning?: false}}
      ]

      for {label, change} <- changes do
        assert Context.digest(change.(base)) != baseline,
               "#{label} must change the digest"
      end
    end

    test "an attribute row for an unused service changes the digest" do
      # The context holds the whole attributes map, not only the rows the day
      # reads, and the absence of such a row is part of what is encoded: a
      # context without it must not digest alike.
      without = complete_context()

      with_row = %{
        without
        | attributes:
            Map.put(without.attributes, {"OTHER", "101"}, %{garage_id: nil, vehicle_type_id: nil})
      }

      assert Context.digest(without) != Context.digest(with_row)
    end

    test "a marked-stop set holds the same members in any insertion order" do
      first = %Context{min_layover_minutes: 5, relief_stop_ids: MapSet.new(["A", "B", "C"])}
      second = %Context{min_layover_minutes: 5, relief_stop_ids: MapSet.new(["C", "A", "B"])}

      assert Context.digest(first) == Context.digest(second)
    end

    test "a decimal's stored scale is not part of the digest" do
      # The canonical form stringifies a decimal normalized, so a stored `1.30`
      # and a `1.3` name the same number and must not read as a change. A float
      # is kept as the float it is, which is what the builder always produces: no
      # field of a context built by `Blocking` holds a decimal.
      scaled = %Context{min_layover_minutes: 5, deadhead_circuity: Decimal.new("1.30")}
      plain = %Context{min_layover_minutes: 5, deadhead_circuity: Decimal.new("1.3")}

      assert Context.digest(scaled) == Context.digest(plain)
    end

    test "is stable across repeated calls" do
      context = complete_context()

      assert Context.digest(context) == Context.digest(context)
    end

    test "list order is part of the digest" do
      # The fleet is a list because `Operations.fleet_summary/1` returns a
      # meaningful order that `Fleet.rows/2` reports. Permuting it is a real
      # change to the context, and digesting alike would under-invalidate.
      first = %Context{
        min_layover_minutes: 5,
        fleet: [
          %{garage_id: nil, vehicle_type_id: nil, count: 1},
          %{garage_id: @garage_uuid, vehicle_type_id: nil, count: 1}
        ]
      }

      second = %Context{first | fleet: Enum.reverse(first.fleet)}

      assert Context.digest(first) != Context.digest(second)
    end
  end

  describe "the context a day load builds" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      # Two stops at a known point, so every trip written by `trip!/4` is
      # plottable and the day's blocks, counts and peak are real.
      for {stop_id, lat} <- [{"S1", "40.0"}, {"S2", "40.01"}] do
        stop_with_coordinates_fixture(organization.id, version.id, %{
          stop_id: stop_id,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new("-74.0")
        })
      end

      %{organization: organization, version: version}
    end

    test "carries the saved settings", %{organization: organization, version: version} do
      garage = garage_fixture(organization.id, %{"name" => "Main"})

      assert {:ok, _settings} =
               update_settings(organization.id, version.id, %{
                 "min_layover_minutes" => "7",
                 "interlining" => "same_stop",
                 "deadhead_speed_kmh" => "25",
                 "pull_out_buffer_minutes" => "4",
                 "default_garage_id" => garage.id
               })

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      assert day.context.min_layover_minutes == 7
      assert day.context.interlining == :same_stop
      assert day.context.deadhead_speed_kmh == 25
      assert day.context.pull_out_buffer_minutes == 4
      assert day.context.default_garage_id == garage.id
      assert day.context.deadhead_circuity == 1.3
      assert day.context.planning? == true
    end

    test "carries decoded driving times and drops a row whose ref does not decode", %{
      organization: organization,
      version: version
    } do
      deadhead_time_fixture(organization.id, version.id, %{
        from_ref: {:stop, "S1"},
        to_ref: {:stop, "S2"},
        minutes: 12
      })

      # A hand-edited or corrupt row: neither ref decodes, so it cannot answer a
      # lookup. Keying the map with the stored strings instead would make every
      # real lookup miss and quietly degrade every entered time to an estimate.
      %DeadheadTime{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        from_ref: "garage:not-a-uuid",
        to_ref: "martian:1234"
      }
      |> DeadheadTime.changeset(%{minutes: 5})
      |> Repo.insert!()

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      assert day.context.entered_minutes == %{{{:stop, "S1"}, {:stop, "S2"}} => 12}
    end

    test "carries the attributes of the day type's services and ignores the rest", %{
      organization: organization,
      version: version
    } do
      garage = garage_fixture(organization.id)

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "WK",
        block_id: "101",
        garage_id: garage.id
      })

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "OFF",
        block_id: "101"
      })

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      assert day.context.attributes == %{
               {"WK", "101"} => %{garage_id: garage.id, vehicle_type_id: nil}
             }
    end

    test "carries route settings, marked stops, the garage map and the fleet", %{
      organization: organization,
      version: version
    } do
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "R1",
        required_vehicle_type_id: vehicle_type.id
      })

      relief_point_fixture(organization.id, version.id, %{stop_id: "S1"})

      garage = garage_fixture(organization.id, %{"name" => "Main"})

      vehicle_fixture(organization.id, %{
        garage_id: garage.id,
        vehicle_type_id: vehicle_type.id
      })

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      assert day.context.route_settings == %{
               "R1" => %{garage_id: nil, required_vehicle_type_id: vehicle_type.id}
             }

      # A mark names the stop as stored. Whether a child stop's parent station is
      # also marked is `Relief`'s question, not the builder's.
      assert MapSet.equal?(day.context.relief_stop_ids, MapSet.new(["S1"]))

      assert day.context.garages[garage.id] == %{
               id: garage.id,
               garage_id: garage.garage_id,
               name: "Main",
               lat: 40.7128,
               lon: -74.006
             }

      assert day.context.vehicle_types[vehicle_type.id] == %{
               id: vehicle_type.id,
               name: "Cutaway",
               max_out_minutes: nil
             }

      assert day.context.fleet == [
               %{garage_id: garage.id, vehicle_type_id: vehicle_type.id, count: 1}
             ]
    end

    test "measures a shared shape once and a shapeless trip from its stops", %{
      organization: organization,
      version: version
    } do
      shared_km = shape!(organization, version, "SH-A", [{1, 40.0, -74.0}, {2, 40.01, -74.0}])

      shaped_a = trip!(organization, version, "a", shape_id: "SH-A")
      shaped_b = trip!(organization, version, "b", shape_id: "SH-A")
      shapeless = shapeless_trip!(organization, version, "c")

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      assert map_size(day.context.trip_km) == 3

      {a_km, a_source} = day.context.trip_km[shaped_a.id]
      {b_km, b_source} = day.context.trip_km[shaped_b.id]
      {c_km, c_source} = day.context.trip_km[shapeless.id]

      assert a_source == :shape
      assert b_source == :shape
      assert a_km == shared_km
      assert b_km == shared_km

      assert c_source == :path
      assert c_km > 0.0
      refute c_km == a_km
    end

    test "a trip naming a shape the version does not describe measures zero", %{
      organization: organization,
      version: version
    } do
      orphan = trip!(organization, version, "a", shape_id: "SH-MISSING")

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      assert day.context.trip_km[orphan.id] == {0.0, :shape}
    end

    test "reads the shapes and the stop paths once however the day's shapes divide", %{
      organization: organization,
      version: version
    } do
      for {shape_id, lat} <- [{"SH-A", "40.0"}, {"SH-B", "41.0"}, {"SH-C", "42.0"}] do
        shape!(organization, version, shape_id, [
          {1, String.to_float(lat), -74.0},
          {2, String.to_float(lat) + 0.01, -74.0}
        ])
      end

      trip!(organization, version, "a", shape_id: "SH-A")
      trip!(organization, version, "b", shape_id: "SH-A")

      distinct = organization_fixture()
      distinct_version = gtfs_version_fixture(distinct.id)

      calendar_service_fixture(distinct.id, distinct_version.id, %{
        service_id: "WK",
        name: "Weekday"
      })

      trip!(distinct, distinct_version, "a", shape_id: "SH-A")
      trip!(distinct, distinct_version, "b", shape_id: "SH-B")
      trip!(distinct, distinct_version, "c", shape_id: "SH-C")

      {_shared, shared_queries} =
        count_queries(fn -> load_day(organization.id, version.id, nil) end)

      {_many, many_queries} =
        count_queries(fn -> load_day(distinct.id, distinct_version.id, nil) end)

      # One day holds two trips over one shape, the other three trips over three
      # shapes. A shape measured per trip would make the second day cost two
      # more queries; one measured per distinct `shape_id` costs the same.
      assert shared_queries > 0
      assert shared_queries == many_queries
    end

    test "leaves the day's blocks, counts, peak and findings as they were", %{
      organization: organization,
      version: version
    } do
      trip!(organization, version, "a", block_id: "101")
      trip!(organization, version, "b", block_id: "101", first: "10:00:00", last: "11:00:00")

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      # Nothing consumes `context` yet, so the day the spec 05 tests assert is
      # the day this still returns.
      assert day.counts == %{blocks: 1, trips: 2, unassigned: 0, problems: 0, notices: 0}
      assert Enum.map(day.blocks, & &1.summary.block_id) == ["101"]
      assert day.peak.count == 1
      assert day.findings == []
    end
  end

  defp complete_context(opts \\ []) do
    base = %Context{
      min_layover_minutes: 7,
      garages: %{
        @garage_uuid => %{
          id: @garage_uuid,
          garage_id: "G-MAIN",
          name: "Main",
          lat: 40.7128,
          lon: -74.006
        }
      },
      vehicle_types: %{
        @vehicle_type_uuid => %{id: @vehicle_type_uuid, name: "Cutaway", max_out_minutes: 330}
      },
      route_settings: %{"R1" => %{garage_id: @garage_uuid, required_vehicle_type_id: nil}},
      attributes: %{{"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil}},
      entered_minutes: %{{{:stop, "S1"}, {:stop, "S2"}} => 12},
      relief_stop_ids: MapSet.new(["S1", "S2"]),
      fleet: [%{garage_id: @garage_uuid, vehicle_type_id: nil, count: 1}],
      trip_km: %{"trip-1" => {4.2, :shape}}
    }

    Enum.reduce(opts, base, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  # Writes the shape's points and returns the path length in kilometres expected
  # of them, computed here from the haversine formula rather than by calling
  # `Blocking.Distance.path_km/1`, so the assertion is independent of the module
  # that produced the value.
  defp shape!(organization, version, shape_id, points) do
    for {sequence, lat, lon} <- points do
      %Shape{}
      |> Shape.changeset(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        shape_id: shape_id,
        shape_pt_sequence: sequence,
        shape_pt_lat: Decimal.new(to_string(lat)),
        shape_pt_lon: Decimal.new(to_string(lon))
      })
      |> Repo.insert!()
    end

    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(0.0, fn [{_, from_lat, from_lon}, {_, to_lat, to_lon}], sum ->
      sum + Helpers.haversine(from_lat, from_lon, to_lat, to_lon)
    end)
    |> then(&(&1 / 1000))
  end

  defp trip!(organization, version, trip_id, attrs) do
    {first, attrs} = attrs |> Map.new() |> Map.pop(:first, "08:00:00")
    {last, attrs} = attrs |> Map.new() |> Map.pop(:last, "09:00:00")

    trip =
      trip_fixture(
        organization.id,
        version.id,
        "R1",
        attrs |> Map.put(:trip_id, trip_id) |> Map.put(:service_id, "WK")
      )

    stop_time_fixture(organization.id, version.id, trip_id, "S1", %{
      stop_sequence: 1,
      arrival_time: first,
      departure_time: first
    })

    stop_time_fixture(organization.id, version.id, trip_id, "S2", %{
      stop_sequence: 2,
      arrival_time: last,
      departure_time: last
    })

    trip
  end

  # A trip with no shape at all: its distance can only come from its own stops,
  # so it gets two stops at a known point and no shape points.
  defp shapeless_trip!(organization, version, trip_id) do
    for {stop_id, lat} <- [{"P1", "43.0"}, {"P2", "43.02"}] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-79.0")
      })
    end

    trip = trip_fixture(organization.id, version.id, "R1", %{trip_id: trip_id, service_id: "WK"})

    stop_time_fixture(organization.id, version.id, trip_id, "P1", %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    })

    stop_time_fixture(organization.id, version.id, trip_id, "P2", %{
      stop_sequence: 2,
      arrival_time: "09:00:00",
      departure_time: "09:00:00"
    })

    trip
  end

  # Ecto runs a repo telemetry handler in the process that issued the query, so
  # counting only this test's own messages keeps other tests' queries out.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = "blocking-context-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, _metadata, pid ->
        if self() == pid, do: send(pid, {:blocking_context_query, handler_id})
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
      {:blocking_context_query, ^handler_id} -> drain_queries(handler_id, count + 1)
    after
      0 -> count
    end
  end
end

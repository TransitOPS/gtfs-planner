defmodule GtfsPlanner.Gtfs.Blocking.ContextTest do
  @moduledoc """
  Tests for the planning context: the layover-only context that
  reproduces the pre-planning behaviour, the fingerprint every reviewed planning write
  carries, the builder that fills the struct from a version's
  reads, and `resolve_block/3` — the one rule that decides a block's garage and
  vehicle type.

  The first three groups are pure — `Context` reads its arguments and touches no
  repository, clock, file or network — so `layover_only/1`, `digest/1` and
  `resolve_block/3` need no fixtures. The resolution cases are written against
  hand-built `Checks.trip_row()` values because the rule reads only four fields
  of a trip; the last group goes through the real `Blocking.load_day/3` and
  resolves a real block from the `day.context` and `day.blocks[].trips` the page
  would use, because that is the path the rule runs on and the only place its
  reads can be observed as a whole.

  The digest cases are the ones that matter most, and they are written to
  fail if the fingerprint narrows. A digest covering only the inputs one plan
  happened to read would let a write through that nobody reviewed, so every
  field is asserted to change it — including a field for a service the day does
  not use, which is over-invalidation accepted on purpose: `Context.digest/1`
  fingerprints the whole context instead of enumerating inputs, so an unrelated
  planning input changes a preview's fingerprint, which is safe.

  Run with:
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
  @garage_north_uuid "33333333-3333-4333-8333-333333333333"
  @vehicle_type_uuid "22222222-2222-4222-8222-222222222222"
  @bus_type_uuid "44444444-4444-4444-8444-444444444444"
  @deleted_uuid "99999999-9999-4999-8999-999999999999"

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
      # insertion order. Erlang stores small map keys in term order, so the
      # insertion order is not observable from the map itself; what the digest
      # claims is that it does not depend on it, and these two are the same
      # value either way.
      assert first == second
      assert first.garages == second.garages
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

  describe "resolve_block/3" do
    test "the block's own attribute row names the garage and the type" do
      context =
        complete_context(
          attributes: %{
            {"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: @vehicle_type_uuid}
          }
        )

      assert Context.resolve_block(context, "101", [trip_row(%{})]) == %{
               garage_id: @garage_uuid,
               vehicle_type_id: @vehicle_type_uuid,
               garage_source: :attribute,
               conflict: nil
             }
    end

    test "with no rows the first trip's route home garage answers" do
      context =
        complete_context(
          garages: known_garages(),
          attributes: %{},
          route_settings: %{
            "12" => %{garage_id: @garage_north_uuid, required_vehicle_type_id: nil}
          }
        )

      assert Context.resolve_block(context, "101", [trip_row(%{route_id: "12"})]) == %{
               garage_id: @garage_north_uuid,
               vehicle_type_id: nil,
               garage_source: :route,
               conflict: nil
             }
    end

    test "with no rows and no route garage the version's default garage answers" do
      context =
        complete_context(
          attributes: %{},
          route_settings: %{"12" => %{garage_id: nil, required_vehicle_type_id: nil}},
          default_garage_id: @garage_uuid
        )

      assert Context.resolve_block(context, "101", [trip_row(%{route_id: "12"})]) == %{
               garage_id: @garage_uuid,
               vehicle_type_id: nil,
               garage_source: :default,
               conflict: nil
             }
    end

    test "with nothing set at all the block has no garage and no type" do
      nothing_set = complete_context(attributes: %{}, route_settings: %{}, default_garage_id: nil)

      expected = %{garage_id: nil, vehicle_type_id: nil, garage_source: :none, conflict: nil}

      # A route row that sets neither value is the same answer as no route row:
      # "no row at all" and "a row that says nothing" both fall through, and the resolution
      # never invents a garage between them.
      route_says_nothing =
        complete_context(
          attributes: %{},
          route_settings: %{"R1" => %{garage_id: nil, required_vehicle_type_id: nil}},
          default_garage_id: nil
        )

      assert Context.resolve_block(nothing_set, "101", [trip_row(%{})]) == expected
      assert Context.resolve_block(route_says_nothing, "101", [trip_row(%{})]) == expected
    end

    test "the type falls back to the first trip's route required type" do
      context =
        complete_context(
          vehicle_types: known_vehicle_types(),
          attributes: %{{"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil}},
          route_settings: %{"30" => %{garage_id: nil, required_vehicle_type_id: @bus_type_uuid}}
        )

      result = Context.resolve_block(context, "101", [trip_row(%{route_id: "30"})])

      assert result.vehicle_type_id == @bus_type_uuid
      assert result.garage_id == @garage_uuid
      assert result.garage_source == :attribute
    end

    test "rows naming different garages conflict and the first trip's service row decides" do
      context =
        complete_context(
          garages: known_garages(),
          vehicle_types: known_vehicle_types(),
          route_settings: %{},
          attributes: %{
            {"WKDY", "102"} => %{garage_id: @garage_uuid, vehicle_type_id: @vehicle_type_uuid},
            {"SCHOOL", "102"} => %{
              garage_id: @garage_north_uuid,
              vehicle_type_id: @vehicle_type_uuid
            }
          }
        )

      weekday = trip_row(%{trip_id: "T-1", service_id: "WKDY", hour: 8})
      school = trip_row(%{trip_id: "T-2", service_id: "SCHOOL", hour: 10})

      result = Context.resolve_block(context, "102", [weekday, school])

      assert result.garage_id == @garage_uuid
      assert result.garage_source == :attribute
      assert result.vehicle_type_id == @vehicle_type_uuid

      # Every row for the block's services is listed, in `service_id` order and
      # not in trip order, and not only the two that disagree — the report lists
      # "every calendar's values".
      assert result.conflict == [
               %{
                 service_id: "SCHOOL",
                 garage_id: @garage_north_uuid,
                 vehicle_type_id: @vehicle_type_uuid
               },
               %{service_id: "WKDY", garage_id: @garage_uuid, vehicle_type_id: @vehicle_type_uuid}
             ]

      # The same block with the later trip first: the row that decides is still
      # the earliest trip's service's, and the report is unchanged.
      assert Context.resolve_block(context, "102", [school, weekday]) == result
    end

    test "a row naming a garage the context does not carry falls through" do
      context =
        complete_context(
          garages: known_garages(),
          attributes: %{
            {"WKDY", "103"} => %{garage_id: @deleted_uuid, vehicle_type_id: @vehicle_type_uuid}
          },
          route_settings: %{
            "R1" => %{garage_id: @garage_north_uuid, required_vehicle_type_id: nil}
          }
        )

      # The deleted UUID is not a garage the block can pull out of, so the route
      # answers instead of a dead identifier reaching every downstream plan.
      assert Context.resolve_block(context, "103", [trip_row(%{})]) == %{
               garage_id: @garage_north_uuid,
               vehicle_type_id: @vehicle_type_uuid,
               garage_source: :route,
               conflict: nil
             }
    end

    test "a row naming a vehicle type the context does not carry falls through" do
      context =
        complete_context(
          vehicle_types: known_vehicle_types(),
          attributes: %{{"WKDY", "104"} => %{garage_id: nil, vehicle_type_id: @deleted_uuid}},
          route_settings: %{
            "R1" => %{garage_id: nil, required_vehicle_type_id: @vehicle_type_uuid}
          }
        )

      result = Context.resolve_block(context, "104", [trip_row(%{})])

      assert result.vehicle_type_id == @vehicle_type_uuid
      assert result.garage_id == nil
      assert result.garage_source == :none
    end

    test "a route garage the context does not carry falls through to the default" do
      context =
        complete_context(
          route_settings: %{"R1" => %{garage_id: @deleted_uuid, required_vehicle_type_id: nil}},
          default_garage_id: @garage_uuid
        )

      # The block has no attribute row, so the route's deleted garage does not
      # answer and the default is what remains.
      result = Context.resolve_block(context, "999", [trip_row(%{})])

      assert result.garage_id == @garage_uuid
      assert result.garage_source == :default
    end

    test "the same block number on two services keeps two rows and two answers" do
      context =
        complete_context(
          garages: known_garages(),
          attributes: %{
            {"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil},
            {"SAT", "101"} => %{garage_id: @garage_north_uuid, vehicle_type_id: nil}
          }
        )

      weekday = Context.resolve_block(context, "101", [trip_row(%{service_id: "WKDY"})])

      saturday =
        Context.resolve_block(context, "101", [trip_row(%{trip_id: "T-S", service_id: "SAT"})])

      assert weekday.garage_id == @garage_uuid
      assert saturday.garage_id == @garage_north_uuid
      assert weekday.conflict == nil
      assert saturday.conflict == nil
    end

    test "a row for another block or a service with no trip is not read" do
      context =
        complete_context(
          garages: known_garages(),
          attributes: %{
            {"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil},
            {"WKDY", "999"} => %{garage_id: @garage_north_uuid, vehicle_type_id: nil},
            {"SAT", "101"} => %{garage_id: @garage_north_uuid, vehicle_type_id: nil}
          }
        )

      result = Context.resolve_block(context, "101", [trip_row(%{service_id: "WKDY"})])

      assert result.garage_id == @garage_uuid
      assert result.conflict == nil
    end

    test "a row naming a garage beside a row naming none is not a conflict" do
      context =
        complete_context(
          garages: known_garages(),
          route_settings: %{},
          attributes: %{
            {"WKDY", "105"} => %{garage_id: @garage_uuid, vehicle_type_id: nil},
            {"SCHOOL", "105"} => %{garage_id: nil, vehicle_type_id: nil}
          }
        )

      result =
        Context.resolve_block(context, "105", [
          trip_row(%{trip_id: "T-1", service_id: "WKDY", hour: 8}),
          trip_row(%{trip_id: "T-2", service_id: "SCHOOL", hour: 10})
        ])

      assert result.garage_id == @garage_uuid
      assert result.garage_source == :attribute
      assert result.conflict == nil
    end

    test "rows agreeing on the garage and disagreeing on the type are a conflict" do
      context =
        complete_context(
          garages: known_garages(),
          vehicle_types: known_vehicle_types(),
          route_settings: %{},
          attributes: %{
            {"WKDY", "106"} => %{garage_id: @garage_uuid, vehicle_type_id: @vehicle_type_uuid},
            {"SCHOOL", "106"} => %{garage_id: @garage_uuid, vehicle_type_id: @bus_type_uuid}
          }
        )

      result =
        Context.resolve_block(context, "106", [
          trip_row(%{trip_id: "T-1", service_id: "WKDY", hour: 8}),
          trip_row(%{trip_id: "T-2", service_id: "SCHOOL", hour: 10})
        ])

      assert result.garage_id == @garage_uuid
      assert result.vehicle_type_id == @vehicle_type_uuid

      assert result.conflict == [
               %{service_id: "SCHOOL", garage_id: @garage_uuid, vehicle_type_id: @bus_type_uuid},
               %{service_id: "WKDY", garage_id: @garage_uuid, vehicle_type_id: @vehicle_type_uuid}
             ]
    end

    test "a block whose trips cannot be sequenced uses the smallest trip id" do
      context =
        complete_context(
          garages: known_garages(),
          route_settings: %{},
          attributes: %{
            {"WKDY", "107"} => %{garage_id: @garage_uuid, vehicle_type_id: nil},
            {"SCHOOL", "107"} => %{garage_id: @garage_north_uuid, vehicle_type_id: nil}
          }
        )

      # Frequency-based and unplottable trips are exactly what `Checks.sequence/1`
      # leaves out, so this block has no sequence. It still has a first trip, and
      # the answer must not depend on the order the caller passed them in.
      unsequenced = [
        trip_row(%{
          trip_id: "T-2",
          service_id: "SCHOOL",
          frequency?: true,
          plottable?: false,
          hour: 8
        }),
        trip_row(%{trip_id: "T-1", service_id: "WKDY", plottable?: false, hour: 10})
      ]

      result = Context.resolve_block(context, "107", unsequenced)

      assert result.garage_id == @garage_uuid
      assert result.garage_source == :attribute
      assert Context.resolve_block(context, "107", Enum.reverse(unsequenced)) == result
    end

    test "a block with no trips resolves to nothing" do
      context = complete_context(default_garage_id: @garage_uuid)

      # No trips means no services, so no row and no route: the version's default
      # garage is still a real garage and still answers. A block that exists with
      # nothing in it is described, not crashed on.
      assert Context.resolve_block(context, "108", []) == %{
               garage_id: @garage_uuid,
               vehicle_type_id: nil,
               garage_source: :default,
               conflict: nil
             }

      assert Context.resolve_block(complete_context(), "108", []) == %{
               garage_id: nil,
               vehicle_type_id: nil,
               garage_source: :none,
               conflict: nil
             }
    end
  end

  describe "the resolution a real day load makes" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      for {stop_id, lat} <- [{"S1", "40.0"}, {"S2", "40.01"}] do
        stop_with_coordinates_fixture(organization.id, version.id, %{
          stop_id: stop_id,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new("-74.0")
        })
      end

      %{organization: organization, version: version}
    end

    test "reads the block's own row through the day the page loads", %{
      organization: organization,
      version: version
    } do
      main = garage_fixture(organization.id, %{"name" => "Main"})
      north = garage_fixture(organization.id, %{"name" => "North"})
      cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "R1",
        garage_id: north.id
      })

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "WK",
        block_id: "101",
        garage_id: main.id,
        vehicle_type_id: cutaway.id
      })

      trip!(organization, version, "a", block_id: "101")
      trip!(organization, version, "b", block_id: "101", first: "10:00:00", last: "11:00:00")

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      [block] = day.blocks
      resolution = Context.resolve_block(day.context, "101", block.trips)

      # The row wins over the route's home garage, which is the whole of the
      # first rule, and the row's type is the block's type.
      assert resolution.garage_id == main.id
      assert resolution.vehicle_type_id == cutaway.id
      assert resolution.garage_source == :attribute
      assert resolution.conflict == nil
    end

    test "a block with no row resolves from the route the day's trips run", %{
      organization: organization,
      version: version
    } do
      north = garage_fixture(organization.id, %{"name" => "North"})
      cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "R1",
        garage_id: north.id,
        required_vehicle_type_id: cutaway.id
      })

      trip!(organization, version, "a", block_id: "101")

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      [block] = day.blocks
      resolution = Context.resolve_block(day.context, "101", block.trips)

      assert resolution.garage_id == north.id
      assert resolution.vehicle_type_id == cutaway.id
      assert resolution.garage_source == :route
      assert resolution.conflict == nil
    end

    test "a block with neither a row nor a route garage falls back to the default", %{
      organization: organization,
      version: version
    } do
      main = garage_fixture(organization.id, %{"name" => "Main"})

      assert {:ok, _settings} =
               update_settings(editor_audit_fixture(organization.id, version.id), %{
                 "default_garage_id" => main.id
               })

      trip!(organization, version, "a", block_id: "101")

      assert {:ok, day} = load_day(organization.id, version.id, nil)

      [block] = day.blocks
      resolution = Context.resolve_block(day.context, "101", block.trips)

      assert resolution.garage_id == main.id
      assert resolution.garage_source == :default
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
               update_settings(editor_audit_fixture(organization.id, version.id), %{
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

      # A context carries the attributes of the day type's own blocks, and a
      # block exists only for the trips assigned to it. `OFF` is not in this day
      # type, so nothing reads its row.
      trip!(organization, version, "a", block_id: "101")

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

      # With no planning inputs set, the day is the one the layover-only checks give.
      assert day.counts == %{blocks: 1, trips: 2, unassigned: 0, problems: 0, notices: 0}
      assert Enum.map(day.blocks, & &1.summary.block_id) == ["101"]
      assert day.peak.count == 1
      assert day.findings == []
    end
  end

  defp complete_context(opts \\ []) do
    base = %Context{
      min_layover_minutes: 7,
      garages: known_garages(),
      vehicle_types: known_vehicle_types(),
      route_settings: %{"R1" => %{garage_id: @garage_uuid, required_vehicle_type_id: nil}},
      attributes: %{{"WKDY", "101"} => %{garage_id: @garage_uuid, vehicle_type_id: nil}},
      entered_minutes: %{{{:stop, "S1"}, {:stop, "S2"}} => 12},
      relief_stop_ids: MapSet.new(["S1", "S2"]),
      fleet: [%{garage_id: @garage_uuid, vehicle_type_id: nil, count: 1}],
      trip_km: %{"trip-1" => {4.2, :shape}}
    }

    Enum.reduce(opts, base, fn {key, value}, acc -> Map.put(acc, key, value) end)
  end

  # Two garages and two types, so a resolution can be asked for one of each and
  # for a second one to disagree with. `@garage_uuid` is Main and
  # `@garage_north_uuid` is North, which is what the resolution cases below name.
  defp known_garages do
    %{
      @garage_uuid => garage(@garage_uuid, "Main"),
      @garage_north_uuid => garage(@garage_north_uuid, "North")
    }
  end

  defp known_vehicle_types do
    %{
      @vehicle_type_uuid => %{id: @vehicle_type_uuid, name: "Cutaway", max_out_minutes: 330},
      @bus_type_uuid => %{id: @bus_type_uuid, name: "Bus", max_out_minutes: nil}
    }
  end

  defp garage(id, name) do
    %{id: id, garage_id: "G-" <> name, name: name, lat: 40.0, lon: -74.0}
  end

  # One `Checks.trip_row()` for the pure resolution cases: a plottable,
  # non-frequency trip that sequences, anchored on `hour` so a case can put two
  # trips of the same block in a known order. `Checks.sequence/1` reads exactly
  # these fields, and building the rest of the row keeps the case honest about
  # the shape `resolve_block/3` is handed.
  defp trip_row(attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      trip_id: "T-1",
      route_id: "R1",
      service_id: "WKDY",
      block_id: "101",
      trip_headsign: nil,
      route_pattern_id: nil,
      shape_id: nil,
      updated_at: ~U[2026-01-01 00:00:00Z],
      frequency?: false,
      headway_secs: nil,
      first_arrival: 8 * 3600,
      first_departure: 8 * 3600,
      last_arrival: 9 * 3600,
      last_departure: 9 * 3600,
      first_stop: nil,
      last_stop: nil,
      plottable?: true
    }

    attrs = Map.new(attrs)

    defaults
    |> Map.merge(Map.drop(attrs, [:hour]))
    |> then(fn row ->
      case Map.fetch(attrs, :hour) do
        {:ok, hour} -> %{row | first_arrival: hour * 3600, first_departure: hour * 3600}
        :error -> row
      end
    end)
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

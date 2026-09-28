defmodule GtfsPlanner.Gtfs.Blocking.LoadDayTest do
  # EV-6: one day type's blocks, pool and checks observed through the ordinary
  # `Gtfs.load_blocking_day/3` entry on the production `CatalogReadAdapter.Repo` and
  # the scoped `Blocking` context. Rows are created inside the SQL Sandbox
  # transaction and rolled back.
  #
  # `async: false` because one case asserts the configured catalog read adapter, and
  # `catalog_read_adapter_test.exs` swaps that global config.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner/gtfs/blocking/load_day_test.exs`.
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.CatalogReadAdapter
  alias GtfsPlanner.Versions

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  setup do
    %{scope: new_scope()}
  end

  describe "a day type's blocks and pool" do
    test "every trip of the day type appears exactly once in a block or the pool", %{
      scope: scope
    } do
      %{organization: organization, version: version, route: route} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      a1 =
        blocked_trip(scope, %{trip_id: "a1", block_id: "101", first: "06:00:00", last: "07:00:00"})

      a2 =
        blocked_trip(scope, %{trip_id: "a2", block_id: "101", first: "07:30:00", last: "08:30:00"})

      b1 =
        blocked_trip(scope, %{trip_id: "b1", block_id: "102", first: "07:00:00", last: "08:00:00"})

      p1 = blocked_trip(scope, %{trip_id: "p1", first: "06:30:00", last: "07:00:00"})
      p2 = blocked_trip(scope, %{trip_id: "p2", first: "05:30:00", last: "06:00:00"})
      p3 = blocked_trip(scope, %{trip_id: "p3", first: "10:00:00", last: "11:00:00"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.day_type.key == hd(day.day_types).key
      assert Enum.map(day.day_types, & &1.service_ids) == [["WK"]]
      assert day.settings == %{min_layover_minutes: 5}
      assert day.mixed_timezones? == false

      assert day.counts == %{blocks: 2, trips: 6, unassigned: 3, problems: 0, notices: 0}

      assert Enum.map(day.blocks, & &1.summary.block_id) == ["101", "102"]
      assert Enum.map(hd(day.blocks).trips, & &1.trip_id) == ["a1", "a2"]
      assert Enum.map(day.pool, & &1.trip_id) == ["p2", "p1", "p3"]
      assert day.unplottable == []

      loaded_ids = Enum.map(all_rows(day), & &1.id)
      assert Enum.sort(loaded_ids) == Enum.sort(Enum.map([a1, a2, b1, p1, p2, p3], & &1.id))
      assert length(Enum.uniq(loaded_ids)) == 6

      route_info = Map.fetch!(day.routes, route.route_id)

      assert route_info == %{
               route_id: route.route_id,
               short_name: route.route_short_name,
               long_name: route.route_long_name,
               route_color: route.route_color,
               route_text_color: route.route_text_color
             }

      assert day.axis == %{start_secs: 18_000, end_secs: 39_600}

      assert day.peak == %{
               count: 2,
               at_secs: 25_200,
               excluded_unassigned: 3,
               excluded_frequency: 0
             }

      assert hd(day.bins) == %{start_secs: 21_600, count: 1}
      assert Enum.max_by(day.bins, & &1.count).count == 2

      assert day.in_seat == %{}
    end

    test "the pool is ordered by first departure with unplottable trips last", %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      _late = blocked_trip(scope, %{trip_id: "p_late", first: "07:00:00", last: "08:00:00"})
      _early = blocked_trip(scope, %{trip_id: "p_early", first: "06:00:00", last: "06:30:00"})

      untimed =
        blocked_trip(scope, %{
          trip_id: "p_untimed",
          first: "08:00:00",
          last: nil,
          last_departure: nil
        })

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert Enum.map(day.pool, & &1.trip_id) == ["p_early", "p_late", "p_untimed"]
      assert Enum.map(day.unplottable, & &1.trip_id) == ["p_untimed"]

      untimed_row = Enum.find(day.pool, &(&1.trip_id == "p_untimed"))
      assert untimed_row.plottable? == false
      assert untimed_row.last_arrival == nil
      assert untimed_row.last_departure == nil

      assert day.counts.trips == 3
      assert day.counts.unassigned == 3
      assert day.counts.blocks == 0
      assert day.counts.notices == 1
      assert day.counts.problems == 0

      assert [%{code: :unplottable, severity: :notice, block_id: nil, trip_ids: [trip_id]}] =
               Enum.filter(day.findings, &(&1.code == :unplottable))

      assert trip_id == untimed.id
    end

    test "trips of another organization, version and day type are absent", %{scope: scope} do
      %{organization: organization, version: version, route: route} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})
      mine = blocked_trip(scope, %{trip_id: "mine", block_id: "1"})

      foreign_scope = new_scope()

      calendar_service_fixture(foreign_scope.organization.id, foreign_scope.version.id, %{
        service_id: "WK",
        name: "Weekday"
      })

      blocked_trip(foreign_scope, %{trip_id: "foreign_org", block_id: "1"})

      other_version = gtfs_version_fixture(organization.id)
      other_route = route_fixture(organization.id, other_version.id)

      calendar_service_fixture(organization.id, other_version.id, %{
        service_id: "WK",
        name: "Weekday"
      })

      blocked_trip_fixture(organization.id, other_version.id, other_route.route_id, %{
        trip_id: "other_version",
        service_id: "WK",
        block_id: "1"
      })

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "SAT",
        name: "Saturday",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0
      })

      blocked_trip(scope, %{trip_id: "saturday", service_id: "SAT", block_id: "1"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert Enum.map(day.day_types, & &1.service_ids) == [["WK"], ["SAT"]]
      assert day.day_type.service_ids == ["WK"]
      assert Enum.map(all_rows(day), & &1.trip_id) == ["mine"]
      assert Enum.map(all_rows(day), & &1.id) == [mine.id]
      assert day.counts == %{blocks: 1, trips: 1, unassigned: 0, problems: 0, notices: 0}

      assert {:ok, saturday} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["SAT"]))

      assert Enum.map(all_rows(saturday), & &1.trip_id) == ["saturday"]
      assert Map.keys(saturday.routes) == [route.route_id]
    end
  end

  describe "endpoint times" do
    test "25:10:00 parses to 90_600 and sequences after a 05:00:00 trip", %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      _early =
        blocked_trip(scope, %{
          trip_id: "early",
          block_id: "7",
          first: "05:00:00",
          last: "06:00:00"
        })

      late =
        blocked_trip(scope, %{trip_id: "late", block_id: "7", first: "25:00:00", last: "25:10:00"})

      # The endpoints come from stop sequence, not from the clock text: this trip's
      # first stop is later than its last.
      _unsorted =
        blocked_trip(scope, %{
          trip_id: "unsorted",
          block_id: "8",
          first: "09:00:00",
          last: "08:00:00"
        })

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert Enum.map(day.blocks, & &1.summary.block_id) == ["7", "8"]
      assert Enum.map(hd(day.blocks).trips, & &1.trip_id) == ["early", "late"]

      late_row = Enum.find(all_rows(day), &(&1.trip_id == "late"))
      assert late_row.first_departure == 90_000
      assert late_row.last_arrival == 90_600
      assert late_row.plottable? == true
      assert late_row.id == late.id

      unsorted_row = Enum.find(all_rows(day), &(&1.trip_id == "unsorted"))
      assert unsorted_row.first_arrival == 32_400
      assert unsorted_row.last_arrival == 28_800

      assert hd(day.blocks).summary.start_secs == 18_000
      assert hd(day.blocks).summary.end_secs == 90_600
      assert day.axis == %{start_secs: 18_000, end_secs: 93_600}
    end
  end

  describe "the day type key" do
    test "nil selects the first day type, an explicit key selects its day type", %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "SAT",
        name: "Saturday",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0
      })

      for trip_id <- ["wk_1", "wk_2", "wk_3"] do
        blocked_trip(scope, %{trip_id: trip_id, service_id: "WK", block_id: "1"})
      end

      blocked_trip(scope, %{trip_id: "sat_1", service_id: "SAT", block_id: "1"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.day_type.key == DayTypes.key(["WK"])
      assert day.day_type.label == "Weekday"
      assert Enum.map(day.day_types, & &1.key) == [DayTypes.key(["WK"]), DayTypes.key(["SAT"])]
      assert Enum.map(all_rows(day), & &1.trip_id) == ["wk_1", "wk_2", "wk_3"]

      assert {:ok, saturday} =
               Gtfs.load_blocking_day(organization.id, version.id, DayTypes.key(["SAT"]))

      assert saturday.day_type.service_ids == ["SAT"]
      assert Enum.map(all_rows(saturday), & &1.trip_id) == ["sat_1"]
    end

    test "an unknown key returns the derived day types and selects none", %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})
      blocked_trip(scope, %{trip_id: "wk_1", block_id: "1"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert {:error, {:unknown_day_type, day_types}} =
               Gtfs.load_blocking_day(organization.id, version.id, "not-a-key")

      assert Enum.map(day_types, & &1.key) == Enum.map(day.day_types, & &1.key)
      assert Enum.map(day_types, & &1.label) == ["Weekday"]
    end

    test "an unpublished, foreign or unknown version is not found", %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      other_organization = organization_fixture()

      assert Gtfs.load_blocking_day(other_organization.id, version.id, nil) ==
               {:error, :not_found}

      assert Gtfs.load_blocking_day(organization.id, Ecto.UUID.generate(), nil) ==
               {:error, :not_found}

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
      calendar_service_fixture(organization.id, staging.id, %{service_id: "WK", name: "Weekday"})

      assert Gtfs.load_blocking_day(organization.id, staging.id, nil) == {:error, :not_found}
    end

    test "a version with no calendars loads an empty day" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.day_types == []
      assert day.day_type == nil
      assert day.blocks == []
      assert day.pool == []
      assert day.unplottable == []
      assert day.findings == []
      assert day.in_seat == %{}
      assert day.bins == []
      assert day.axis == nil
      assert day.routes == %{}
      assert day.settings == %{min_layover_minutes: 5}
      assert day.mixed_timezones? == false
      assert day.counts == %{blocks: 0, trips: 0, unassigned: 0, problems: 0, notices: 0}
      assert day.peak == %{count: 0, at_secs: nil, excluded_unassigned: 0, excluded_frequency: 0}

      assert {:ok, %{day_type: nil, day_types: []}} =
               Gtfs.load_blocking_day(organization.id, version.id, "not-a-key")
    end
  end

  describe "dates-only services" do
    test "a dates-only service forms its own day type", %{scope: scope} do
      %{organization: organization, version: version} = scope

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "SPECIAL",
        name: "Special day",
        dates: [~D[2026-03-04]]
      })

      blocked_trip(scope, %{trip_id: "special_1", service_id: "SPECIAL", block_id: "1"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.day_type.service_ids == ["SPECIAL"]
      assert day.day_type.dates == [~D[2026-03-04]]
      assert day.day_type.date_count == 1
      assert day.day_type.special? == true
      assert day.day_type.label == "Special day"
      assert day.counts.trips == 1
      assert Enum.map(all_rows(day), & &1.trip_id) == ["special_1"]
    end

    test "a dates-only service joins the day type of a weekly service on that date", %{
      scope: scope
    } do
      %{organization: organization, version: version} = scope

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "WK",
        name: "Weekday",
        monday: 0,
        tuesday: 0,
        wednesday: 1,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-03-01],
        end_date: ~D[2026-03-31]
      })

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "SPECIAL",
        name: "Special day",
        dates: [~D[2026-03-04]]
      })

      blocked_trip(scope, %{trip_id: "wk_1", service_id: "WK", block_id: "1"})
      blocked_trip(scope, %{trip_id: "special_1", service_id: "SPECIAL", block_id: "1"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert Enum.map(day.day_types, & &1.service_ids) == [["SPECIAL", "WK"], ["WK"]]
      assert day.day_type.service_ids == ["SPECIAL", "WK"]
      assert day.day_type.dates == [~D[2026-03-04]]
      assert day.day_type.label == "Special day + Weekday"
      assert day.counts.trips == 2
      assert Enum.sort(Enum.map(all_rows(day), & &1.trip_id)) == ["special_1", "wk_1"]
    end
  end

  describe "the day's checks" do
    test "the stored minimum layover decides a short layover and an overlapping pair", %{
      scope: scope
    } do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      assert {:ok, _setting} =
               Blocking.update_settings(organization.id, version.id, %{min_layover_minutes: 10})

      tight_a =
        blocked_trip(scope, %{
          trip_id: "tight_a",
          block_id: "101",
          first: "08:00:00",
          last: "09:00:00"
        })

      tight_b =
        blocked_trip(scope, %{
          trip_id: "tight_b",
          block_id: "101",
          first: "09:07:00",
          last: "10:00:00"
        })

      overlap_a =
        blocked_trip(scope, %{
          trip_id: "overlap_a",
          block_id: "102",
          first: "09:00:00",
          last: "10:00:00"
        })

      overlap_b =
        blocked_trip(scope, %{
          trip_id: "overlap_b",
          block_id: "102",
          first: "09:30:00",
          last: "10:30:00"
        })

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert day.settings == %{min_layover_minutes: 10}

      assert [layover] = Enum.filter(day.findings, &(&1.code == :short_layover))
      assert layover.severity == :warning
      assert layover.block_id == "101"
      assert Enum.sort(layover.trip_ids) == Enum.sort([tight_a.id, tight_b.id])
      assert layover.detail == %{gap_secs: 420}

      assert [overlap] = Enum.filter(day.findings, &(&1.code == :overlap))
      assert overlap.severity == :error
      assert overlap.block_id == "102"
      assert Enum.sort(overlap.trip_ids) == Enum.sort([overlap_a.id, overlap_b.id])

      assert day.counts.problems == 2
      assert day.counts.notices == 0

      statuses = Map.new(day.blocks, &{&1.summary.block_id, &1.summary})
      assert statuses["101"].status == :warning
      assert statuses["101"].status_code == :short_layover
      assert statuses["102"].status == :error
      assert statuses["102"].status_code == :overlap
      assert statuses["101"].trip_count == 2
    end

    test "two child stops of one parent share a station and a stop without coordinates uses its parent's",
         %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      _parent =
        stop_fixture(organization.id, version.id, %{
          stop_id: "PAR",
          stop_name: "Union",
          location_type: 1,
          stop_lat: Decimal.new("40.712800"),
          stop_lon: Decimal.new("-74.006000")
        })

      _child_a = child_stop(organization.id, version.id, "CA", "Platform A", "PAR")
      _child_b = child_stop(organization.id, version.id, "CB", "Platform B", "PAR")

      _parent_far =
        stop_fixture(organization.id, version.id, %{
          stop_id: "PAR_FAR",
          stop_name: "Union Far",
          location_type: 1,
          stop_lat: Decimal.new("40.713800"),
          stop_lon: Decimal.new("-74.006000")
        })

      _child_c = child_stop(organization.id, version.id, "CC", "Far A", "PAR_FAR")
      _child_d = child_stop(organization.id, version.id, "CD", "Far B", "PAR")

      first =
        blocked_trip(scope, %{
          trip_id: "same_station_a",
          block_id: "1",
          first_stop: "CA",
          last_stop: "CA",
          first: "08:00:00",
          last: "09:00:00"
        })

      second =
        blocked_trip(scope, %{
          trip_id: "same_station_b",
          block_id: "1",
          first_stop: "CB",
          last_stop: "CB",
          first: "09:10:00",
          last: "10:00:00"
        })

      third =
        blocked_trip(scope, %{
          trip_id: "nearby_a",
          block_id: "2",
          first_stop: "CC",
          last_stop: "CC",
          first: "08:00:00",
          last: "09:00:00"
        })

      fourth =
        blocked_trip(scope, %{
          trip_id: "nearby_b",
          block_id: "2",
          first_stop: "CD",
          last_stop: "CD",
          first: "09:10:00",
          last: "10:00:00"
        })

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      same_station_block = block(day, "1")

      assert [%{from_id: from_id, to_id: to_id, gap_secs: 600, handoff: :same_station}] =
               same_station_block.gaps

      assert from_id == first.id
      assert to_id == second.id

      assert hd(same_station_block.trips).last_stop == %{
               stop_id: "CA",
               name: "Platform A",
               parent_station: "PAR",
               lat: 40.7128,
               lon: -74.006
             }

      nearby_block = block(day, "2")

      assert [
               %{
                 from_id: nearby_from,
                 to_id: nearby_to,
                 gap_secs: 600,
                 handoff: {:nearby, meters}
               }
             ] =
               nearby_block.gaps

      assert nearby_from == third.id
      assert nearby_to == fourth.id
      assert meters == 111

      assert Enum.map(day.findings, & &1.code) == []
      assert day.counts.problems == 0
    end

    test "stops without coordinates and without a parent are an unknown empty move", %{
      scope: scope
    } do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      _unknown_a =
        stop_fixture(organization.id, version.id, %{
          stop_id: "UNK_A",
          stop_lat: nil,
          stop_lon: nil
        })

      _unknown_b =
        stop_fixture(organization.id, version.id, %{
          stop_id: "UNK_B",
          stop_lat: nil,
          stop_lon: nil
        })

      first =
        blocked_trip(scope, %{
          trip_id: "unknown_a",
          block_id: "9",
          first_stop: "UNK_A",
          last_stop: "UNK_A",
          first: "08:00:00",
          last: "09:00:00"
        })

      second =
        blocked_trip(scope, %{
          trip_id: "unknown_b",
          block_id: "9",
          first_stop: "UNK_B",
          last_stop: "UNK_B",
          first: "09:10:00",
          last: "10:00:00"
        })

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert [%{from_id: from_id, to_id: to_id, gap_secs: 600, handoff: {:moves, nil}}] =
               block(day, "9").gaps

      assert from_id == first.id
      assert to_id == second.id

      assert [%{code: :repositions, severity: :notice, block_id: "9", detail: detail}] =
               Enum.filter(day.findings, &(&1.code == :repositions))

      assert detail == %{gap_secs: 600, meters: nil}
      assert day.counts.notices == 1
      assert day.counts.problems == 0

      assert hd(block(day, "9").trips).last_stop == %{
               stop_id: "UNK_A",
               name: "Test Stop",
               parent_station: nil,
               lat: nil,
               lon: nil
             }
    end

    test "a frequency-based trip is reported as a repeat and is left out of the checks", %{
      scope: scope
    } do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      frequency =
        blocked_trip(scope, %{
          trip_id: "frequency",
          block_id: "3",
          first: "08:00:00",
          last: "09:30:00"
        })

      _regular =
        blocked_trip(scope, %{
          trip_id: "regular",
          block_id: "3",
          first: "08:30:00",
          last: "09:30:00"
        })

      pooled =
        blocked_trip(scope, %{trip_id: "pooled_frequency", first: "10:00:00", last: "11:00:00"})

      frequency_row_fixture(organization.id, version.id, %{
        trip_id: "frequency",
        headway_secs: 1200
      })

      frequency_row_fixture(organization.id, version.id, %{
        trip_id: "frequency",
        start_time: "10:00:00",
        headway_secs: 900
      })

      frequency_row_fixture(organization.id, version.id, %{
        trip_id: "pooled_frequency",
        headway_secs: 1800
      })

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      frequency_row = Enum.find(all_rows(day), &(&1.trip_id == "frequency"))
      assert frequency_row.frequency? == true
      assert frequency_row.headway_secs == 900
      assert frequency_row.id == frequency.id

      pooled_row = Enum.find(day.pool, &(&1.trip_id == "pooled_frequency"))
      assert pooled_row.id == pooled.id
      assert pooled_row.frequency? == true
      assert pooled_row.headway_secs == 1800

      # The frequency window would overlap `regular` if it were sequenced; AC-6 keeps
      # it out of the overlap and layover checks and still lists it in its block.
      assert Enum.filter(day.findings, &(&1.code == :overlap)) == []
      assert Enum.map(block(day, "3").trips, & &1.trip_id) == ["regular", "frequency"]

      assert [
               %{
                 code: :frequency_trip,
                 severity: :notice,
                 block_id: "3",
                 detail: %{headway_secs: 900},
                 trip_ids: [trip_id]
               }
             ] =
               Enum.filter(day.findings, &(&1.code == :frequency_trip and &1.block_id == "3"))

      assert trip_id == frequency.id

      assert [%{code: :frequency_trip, block_id: nil, trip_ids: [pooled_id]}] =
               Enum.filter(day.findings, &(&1.code == :frequency_trip and is_nil(&1.block_id)))

      assert pooled_id == pooled.id

      assert block(day, "3").summary.start_secs == 30_600
      assert block(day, "3").summary.end_secs == 34_200
      assert block(day, "3").summary.trip_count == 2
      assert day.peak.excluded_frequency == 2
      assert day.peak.excluded_unassigned == 1
      assert day.counts.notices == 2
      assert day.counts.problems == 0
    end

    test "agencies with two timezones set mixed_timezones?", %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})
      blocked_trip(scope, %{trip_id: "wk_1", block_id: "1"})

      _first_agency =
        agency_fixture(organization.id, version.id, %{
          agency_id: "a1",
          agency_timezone: "America/New_York"
        })

      assert {:ok, single} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      assert single.mixed_timezones? == false

      _second_agency =
        agency_fixture(organization.id, version.id, %{
          agency_id: "a2",
          agency_timezone: "America/Los_Angeles"
        })

      assert {:ok, mixed} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      assert mixed.mixed_timezones? == true
    end
  end

  describe "the query count" do
    test "stays the same for a 10-trip and a 60-trip day of the same shape" do
      small = seeded_scope(10)
      large = seeded_scope(60)

      {small_result, small_count} =
        count_queries(fn ->
          Gtfs.load_blocking_day(small.organization.id, small.version.id, nil)
        end)

      {large_result, large_count} =
        count_queries(fn ->
          Gtfs.load_blocking_day(large.organization.id, large.version.id, nil)
        end)

      assert {:ok, small_day} = small_result
      assert {:ok, large_day} = large_result
      assert small_day.counts == %{blocks: 5, trips: 10, unassigned: 0, problems: 0, notices: 0}
      assert large_day.counts == %{blocks: 30, trips: 60, unassigned: 0, problems: 0, notices: 0}
      assert small_count > 0
      assert small_count == large_count
    end
  end

  describe "trip_day_types/3" do
    test "names every day type the trip runs in and nothing from another scope", %{scope: scope} do
      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

      calendar_service_fixture(organization.id, version.id, %{
        service_id: "WK2",
        name: "Monday",
        monday: 1,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 0
      })

      blocked_trip(scope, %{trip_id: "wk_1", service_id: "WK", block_id: "1"})
      blocked_trip(scope, %{trip_id: "wk2_1", service_id: "WK2", block_id: "1"})

      foreign_scope = new_scope()

      calendar_service_fixture(foreign_scope.organization.id, foreign_scope.version.id, %{
        service_id: "WK",
        name: "Weekday"
      })

      blocked_trip(foreign_scope, %{trip_id: "foreign", block_id: "1"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)

      assert {:ok, %{trip_id: "wk_1", day_types: day_types}} =
               Blocking.trip_day_types(organization.id, version.id, "wk_1")

      assert Enum.map(day_types, & &1.service_ids) == [["WK", "WK2"], ["WK"]]
      assert Enum.map(day_types, & &1.key) == Enum.map(day.day_types, & &1.key)

      assert Blocking.trip_day_types(organization.id, version.id, "missing") ==
               {:error, :not_found}

      assert Blocking.trip_day_types(foreign_scope.organization.id, version.id, "foreign") ==
               {:error, :not_found}
    end
  end

  describe "the ordinary entry" do
    test "Gtfs.load_blocking_day/3 returns the same day as the scoped context", %{scope: scope} do
      assert Application.get_env(:gtfs_planner, :gtfs_catalog_read_adapter) in [
               nil,
               CatalogReadAdapter.Repo
             ]

      %{organization: organization, version: version} = scope
      calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})
      blocked_trip(scope, %{trip_id: "wk_1", block_id: "1", first: "08:00:00", last: "09:00:00"})

      assert {:ok, day} = Gtfs.load_blocking_day(organization.id, version.id, nil)
      assert {:ok, ^day} = Blocking.load_day(organization.id, version.id, nil)

      assert {:ok, ^day} = Gtfs.load_blocking_day(organization.id, version.id, day.day_type.key)
    end
  end

  defp new_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      version: version,
      route: route_fixture(organization.id, version.id)
    }
  end

  defp seeded_scope(trip_count) do
    scope = new_scope()

    calendar_service_fixture(scope.organization.id, scope.version.id, %{
      service_id: "WK",
      name: "Weekday"
    })

    for index <- 1..trip_count do
      {first, last} =
        if rem(index, 2) == 1, do: {"08:00:00", "09:00:00"}, else: {"09:30:00", "10:30:00"}

      blocked_trip(scope, %{
        trip_id: "trip_#{index}",
        service_id: "WK",
        block_id: "block_#{div(index - 1, 2)}",
        first: first,
        last: last
      })
    end

    scope
  end

  # A test that only cares about block membership, service or scope passes no times,
  # so a distinct default pair is used unless the caller names them; `last: nil` still
  # stores an empty last time, which is what the unplottable case needs.
  defp blocked_trip(scope, attrs) do
    {first, attrs} = attrs |> Map.new() |> Map.pop(:first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      scope.organization.id,
      scope.version.id,
      scope.route.route_id,
      attrs
      |> Map.put_new(:service_id, "WK")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  defp child_stop(organization_id, gtfs_version_id, stop_id, name, parent_station) do
    stop_fixture(organization_id, gtfs_version_id, %{
      stop_id: stop_id,
      stop_name: name,
      location_type: 0,
      parent_station: parent_station,
      level_id: "L1",
      stop_lat: nil,
      stop_lon: nil
    })
  end

  defp block(day, block_id), do: Enum.find(day.blocks, &(&1.summary.block_id == block_id))

  defp all_rows(day), do: Enum.flat_map(day.blocks, & &1.trips) ++ day.pool

  # Ecto runs a repo telemetry handler in the process that issued the query, so
  # counting only this test's own messages keeps other tests' queries out.
  defp count_queries(fun) do
    test_pid = self()
    handler_id = "blocking-load-day-#{System.unique_integer([:positive])}"

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

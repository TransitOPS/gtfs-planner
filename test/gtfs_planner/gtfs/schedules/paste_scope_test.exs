defmodule GtfsPlanner.Gtfs.Schedules.PasteScopeTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.TimetablePaste

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, audit: audit}
  end

  describe "load_paste_scope/5" do
    test "a scope holds both directions' trips with spans, timings and transfers", context do
      scope = schedule_scope!(context)

      assert {:ok, paste} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{service_id: scope.service, direction_id: 0}
               )

      assert paste.route.route_id == scope.route_id
      assert paste.calendar.service_id == scope.service
      assert paste.calendar.name == "Paste Weekday"
      assert paste.calendar.trip_count == 4
      assert paste.direction_id == 0
      assert paste.pattern_id == scope.main.pattern.id
      assert paste.other_calendars? == true

      assert Enum.map(paste.patterns, & &1.id) == [scope.main.pattern.id]

      [main] = paste.patterns
      assert main.route_pattern_id == "MAIN"
      assert main.name == "Main"
      assert main.headsign == "Hospital"
      assert Enum.map(main.occurrences, & &1.stop_id) == ["PSA-1", "PSA-2", "PSA-3"]
      assert Enum.map(main.occurrences, & &1.position) == [1, 2, 3]

      assert [timing] = main.timings
      assert timing.name == "Standard"

      assert Enum.map(timing.rows, &{&1.arrival_offset, &1.departure_offset, &1.timepoint}) ==
               [{0, 0, 1}, {300, 330, 1}, {720, 720, 1}]

      assert timing.trip_count == 2

      assert paste.stops["PSA-1"] == %{stop_code: "1001", stop_name: "Central Station"}
      assert paste.stops["PSA-2"] == %{stop_code: "1002", stop_name: "Market Street"}
      assert paste.stops["PSA-3"] == %{stop_code: "1003", stop_name: "Hospital"}

      by_trip = Map.new(paste.trips, &{&1.trip_id, &1})
      assert Map.keys(by_trip) |> Enum.sort() == scope.trips |> Map.values() |> Enum.sort()

      first = by_trip[scope.trips[:first]]
      assert first.direction_id == 0
      assert first.route_pattern_id == "MAIN"
      assert first.timed_pattern_id == scope.main.timing.id
      assert first.pattern_derivation_state == "linked"
      assert first.start_secs == 6 * 3600
      assert first.end_secs == 6 * 3600 + 720
      assert first.span == %{start_secs: 6 * 3600, end_secs: 6 * 3600 + 720}
      assert first.spans == [%{start_secs: 6 * 3600, end_secs: 6 * 3600 + 720}]
      assert first.frequencies == []
      assert first.frequency_rows == []
      assert first.stops_differ? == false
      assert first.trip_short_name == "101"
      assert first.block_id == nil
      assert first.trip_headsign == "Hospital"
      assert %DateTime{} = first.updated_at
      assert first.transfer_ids == [scope.transfer_id, scope.in_seat_id] |> Enum.sort()
      assert first.in_seat_transfer == true

      second = by_trip[scope.trips[:second]]
      assert second.start_secs == 7 * 3600
      assert second.span == %{start_secs: 7 * 3600, end_secs: 7 * 3600 + 720}

      assert [%{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1200}] =
               Enum.map(
                 second.frequencies,
                 &Map.take(&1, [:start_time, :end_time, :headway_secs])
               )

      assert second.frequency_rows == second.frequencies
      assert second.transfer_ids == []
      assert second.in_seat_transfer == false

      custom = by_trip[scope.trips[:custom]]
      assert custom.pattern_derivation_state == "custom"
      assert custom.timed_pattern_id == nil
      assert custom.stops_differ? == true
      assert custom.start_secs == 9 * 3600
      assert custom.span == %{start_secs: 9 * 3600, end_secs: 9 * 3600 + 720}

      reverse = by_trip[scope.trips[:reverse]]
      assert reverse.direction_id == 1
      assert reverse.route_pattern_id == "REV"
      assert reverse.start_secs == 8 * 3600
      assert reverse.span == %{start_secs: 8 * 3600, end_secs: 8 * 3600 + 720}
      assert reverse.transfer_ids == [scope.transfer_id, scope.in_seat_id] |> Enum.sort()
      assert reverse.in_seat_transfer == true
    end

    test "missing values resolve like the Schedules read", context do
      scope = schedule_scope!(context)

      assert {:ok, paste} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{}
               )

      assert paste.calendar.service_id == scope.service
      assert paste.direction_id == 0
      assert paste.pattern_id == scope.main.pattern.id

      assert {:ok, natural} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{
                   "service_id" => scope.service,
                   "direction_id" => "0",
                   "route_pattern_id" => "MAIN"
                 }
               )

      assert natural.pattern_id == scope.main.pattern.id
      assert natural.direction_id == 0
    end

    test "a route_pattern_id spelled like another pattern's row UUID selects exactly the requested kind",
         context do
      scope = schedule_scope!(context)

      # This pattern's feed ID is the main pattern's row UUID.
      lookalike =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: scope.route_id,
          direction_id: 0,
          route_pattern_id: scope.main.pattern.id,
          route_pattern_name: "Lookalike",
          stops: []
        })

      load = fn params ->
        Schedules.load_paste_scope(
          context.organization.id,
          context.version.id,
          scope.route_id,
          Map.merge(%{service_id: scope.service, direction_id: 0}, params)
        )
      end

      for params <- [
            %{pattern_id: scope.main.pattern.id},
            %{pattern: scope.main.pattern.id},
            %{"pattern_id" => scope.main.pattern.id}
          ] do
        assert {:ok, by_row} = load.(params)
        assert by_row.pattern_id == scope.main.pattern.id
      end

      assert {:ok, by_feed_id} = load.(%{route_pattern_id: scope.main.pattern.id})
      assert by_feed_id.pattern_id == lookalike.pattern.id

      assert {:ok, by_main_feed_id} = load.(%{route_pattern_id: "MAIN"})
      assert by_main_feed_id.pattern_id == scope.main.pattern.id
    end

    test "naming a row UUID and a route_pattern_id together is :not_found", context do
      scope = schedule_scope!(context)

      # Even two selectors that name the same pattern are refused.
      for params <- [
            %{pattern_id: scope.main.pattern.id, route_pattern_id: "MAIN"},
            %{pattern: scope.main.pattern.id, route_pattern_id: "MAIN"},
            %{"pattern_id" => scope.main.pattern.id, "route_pattern_id" => "MAIN"}
          ] do
        assert {:error, :not_found} =
                 Schedules.load_paste_scope(
                   context.organization.id,
                   context.version.id,
                   scope.route_id,
                   Map.merge(%{service_id: scope.service, direction_id: 0}, params)
                 )
      end
    end

    test "a natural ID under the row selector is :not_found", context do
      scope = schedule_scope!(context)

      assert {:error, :not_found} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{service_id: scope.service, direction_id: 0, pattern_id: "MAIN"}
               )
    end

    test "a foreign route, organization or version is :not_found", context do
      scope = schedule_scope!(context)
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_route = route_fixture(other_organization.id, other_version.id)

      assert {:error, :not_found} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 context.version.id,
                 other_route.route_id,
                 %{}
               )

      assert {:error, :not_found} =
               Schedules.load_paste_scope(
                 other_organization.id,
                 context.version.id,
                 scope.route_id,
                 %{}
               )

      assert {:error, :not_found} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 other_version.id,
                 scope.route_id,
                 %{}
               )
    end

    test "a pattern outside the chosen direction is :not_found", context do
      scope = schedule_scope!(context)

      stranger =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: scope.other_route_id,
          direction_id: 0,
          stops: []
        })

      for selector <- [
            %{pattern_id: scope.rev.pattern.id},
            %{route_pattern_id: "REV"},
            %{pattern_id: stranger.pattern.id},
            %{route_pattern_id: stranger.pattern.route_pattern_id}
          ] do
        assert {:error, :not_found} =
                 Schedules.load_paste_scope(
                   context.organization.id,
                   context.version.id,
                   scope.route_id,
                   Map.merge(%{service_id: scope.service, direction_id: 0}, selector)
                 )
      end

      assert {:ok, paste} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{service_id: scope.service, direction_id: 1, pattern_id: scope.rev.pattern.id}
               )

      assert paste.pattern_id == scope.rev.pattern.id
      assert Enum.map(paste.patterns, & &1.id) == [scope.rev.pattern.id]
    end

    test "the loaded scope feeds the pure review", context do
      scope = schedule_scope!(context)

      assert {:ok, paste} =
               Schedules.load_paste_scope(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 %{service_id: scope.service, direction_id: 0}
               )

      text =
        "Central Station\tMarket Street\tHospital\n" <>
          "11:00\t11:05\t11:12\n" <>
          "11:30\t11:35\t11:42\n"

      input = %{
        text: text,
        layout: :auto,
        header?: true,
        overrides: %{},
        confirmations: MapSet.new(),
        decisions: %{},
        mode: :add,
        template_timing_id: nil,
        stamp: "Sep 28",
        block_rows: []
      }

      assert {:ok, review} = TimetablePaste.review(paste, input)
      assert Enum.map(review.rows, & &1.status) == [:ready, :ready]
      assert review.plan.counts.add == 2
      assert review.plan.vehicles.before == 2
      assert review.plan.vehicles.after == 2
    end
  end

  describe "load_block_rows/4" do
    test "block rows come from other routes on the same calendar", context do
      scope = schedule_scope!(context)

      assert [row] =
               Schedules.load_block_rows(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 {[scope.block_id], scope.service}
               )

      assert row.trip_id == scope.other_trip_id
      assert row.block_id == scope.block_id
      assert row.service_id == scope.service

      assert [%{trip_id: trip_id}] =
               Schedules.load_block_rows(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 [scope.block_id]
               )

      assert trip_id == scope.other_trip_id

      assert [] =
               Schedules.load_block_rows(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 {[scope.block_id], "NO-SUCH-SERVICE"}
               )

      assert [] =
               Schedules.load_block_rows(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 []
               )

      assert [] =
               Schedules.load_block_rows(
                 context.organization.id,
                 context.version.id,
                 scope.route_id,
                 {["NO-SUCH-BLOCK"], scope.service}
               )
    end
  end

  defp schedule_scope!(context) do
    route = route_fixture(context.organization.id, context.version.id, %{route_id: "R-PASTE"})

    other_route =
      route_fixture(context.organization.id, context.version.id, %{route_id: "R-OTHER"})

    for {stop_id, name, code} <- [
          {"PSA-1", "Central Station", "1001"},
          {"PSA-2", "Market Street", "1002"},
          {"PSA-3", "Hospital", "1003"}
        ] do
      stop =
        stop_fixture(context.organization.id, context.version.id, %{
          stop_id: stop_id,
          stop_name: name
        })

      # stop_code is import-managed (the editor changeset never casts it),
      # so stamp it directly; the scope must still surface it per stop.
      stop |> Ecto.Changeset.change(%{stop_code: code}) |> Repo.update!()
    end

    service = weekly_calendar!(context, "WKD-PASTE", "Paste Weekday")
    saturday = weekly_calendar!(context, "SAT-PASTE", "Paste Saturday")

    main =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "MAIN",
        route_pattern_name: "Main",
        route_pattern_sort_order: 0,
        headsign: "Hospital",
        timing_name: "Standard",
        stops: [{"PSA-1", 0, 0, 1}, {"PSA-2", 300, 330, 1}, {"PSA-3", 720, 720, 1}]
      })

    rev =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: route.route_id,
        direction_id: 1,
        route_pattern_id: "REV",
        route_pattern_name: "Reverse",
        route_pattern_sort_order: 1,
        headsign: "Central",
        timing_name: "Standard",
        stops: [{"PSA-3", 0, 0, 1}, {"PSA-2", 300, 330, 1}, {"PSA-1", 720, 720, 1}]
      })

    first =
      schedule_trip_fixture(context.organization.id, context.version.id, route.route_id, main, %{
        trip_id: "R-PASTE-0-WKD-PASTE-0600",
        service_id: service,
        start_time: "06:00:00",
        trip_short_name: "101",
        trip_headsign: "Hospital"
      }).trip

    second =
      schedule_trip_fixture(context.organization.id, context.version.id, route.route_id, main, %{
        trip_id: "R-PASTE-0-WKD-PASTE-0700",
        service_id: service,
        start_time: "07:00:00"
      }).trip

    frequency_fixture(context.organization.id, context.version.id, second.trip_id, %{
      start_time: "09:00:00",
      end_time: "12:00:00",
      headway_secs: 1200,
      exact_times: 0
    })

    custom =
      schedule_trip_fixture(context.organization.id, context.version.id, route.route_id, main, %{
        trip_id: "R-PASTE-0-WKD-PASTE-0900",
        service_id: service,
        state: "custom",
        stop_times: [
          {"PSA-1", "09:00:00", "09:00:00"},
          {"PSA-3", "09:12:00", "09:12:00"}
        ]
      }).trip

    reverse =
      schedule_trip_fixture(context.organization.id, context.version.id, route.route_id, rev, %{
        trip_id: "R-PASTE-1-WKD-PASTE-0800",
        service_id: service,
        start_time: "08:00:00"
      }).trip

    saturday_trip =
      schedule_trip_fixture(context.organization.id, context.version.id, route.route_id, main, %{
        trip_id: "R-PASTE-0-SAT-PASTE-1000",
        service_id: saturday,
        start_time: "10:00:00"
      }).trip

    transfer =
      transfer_fixture(context.organization.id, context.version.id, %{
        from_stop_id: "PSA-1",
        to_stop_id: "PSA-3",
        from_trip_id: first.trip_id,
        to_trip_id: reverse.trip_id,
        transfer_type: 0
      })

    in_seat =
      transfer_fixture(context.organization.id, context.version.id, %{
        from_stop_id: "PSA-2",
        to_stop_id: "PSA-3",
        from_trip_id: first.trip_id,
        to_trip_id: reverse.trip_id,
        transfer_type: 4
      })

    other_bundle =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: other_route.route_id,
        direction_id: 0,
        route_pattern_id: "OTHER",
        stops: [{"PSA-1", 0, 0, 1}, {"PSA-3", 600, 600, 1}]
      })

    other_trip =
      schedule_trip_fixture(
        context.organization.id,
        context.version.id,
        other_route.route_id,
        other_bundle,
        %{
          trip_id: "R-OTHER-0-WKD-PASTE-0630",
          service_id: service,
          start_time: "06:30:00",
          block_id: "B101"
        }
      ).trip

    %{
      route_id: route.route_id,
      other_route_id: other_route.route_id,
      service: service,
      main: main,
      rev: rev,
      trips: %{
        first: first.trip_id,
        second: second.trip_id,
        custom: custom.trip_id,
        reverse: reverse.trip_id
      },
      saturday_trip_id: saturday_trip.trip_id,
      transfer_id: transfer.id,
      in_seat_id: in_seat.id,
      block_id: "B101",
      other_trip_id: other_trip.trip_id
    }
  end

  defp weekly_calendar!(context, service_id, name) do
    attrs = %{
      service_id: service_id,
      name: name,
      kind: :weekly,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-02-27]
    }

    assert {:ok, _payload} = Gtfs.create_calendar(attrs, context.audit)
    service_id
  end
end

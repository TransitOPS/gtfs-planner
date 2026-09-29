defmodule GtfsPlanner.Gtfs.Schedules.PasteApplyTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Schedules
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimetablePaste
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip

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

  describe "apply_paste/5 removals" do
    test "a Replace removal deletes the trip, its stop times and its two transfers", context do
      scope = apply_case!(context)
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.remove == 1

      assert {:ok, summary} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert summary.added == 0
      assert summary.changed == 0
      assert summary.removed == 1
      assert summary.transfers_removed == 2
      assert summary.new_timings == []
      assert summary.trip_ids == []
      assert summary.vehicles_before == review.plan.vehicles.before
      assert summary.vehicles_after == review.plan.vehicles.after

      # The removed trip, its stop times and both transfers naming it are gone
      # while the kept trip is byte-identical.
      assert Repo.get_by(Trip, trip_id: scope.trips.first) == nil

      assert scoped(StopTime, context) |> where_trip(scope.trips.first) |> Repo.all() == []
      assert scoped(Transfer, context) |> Repo.all() == []

      assert Schedules.count_trip_transfers(context.organization.id, context.version.id, [
               scope.trips.first
             ]) == 0

      assert %Trip{trip_id: trip_id} = Repo.get_by(Trip, trip_id: scope.trips.second)
      assert trip_id == scope.trips.second

      # One 'deleted' trip audit carries the shared operation id.
      [log] =
        context |> trip_logs() |> Enum.filter(&(&1.action == "deleted"))

      assert log.entity_external_id == scope.trips.first
      assert log.changed_fields["before"]["trip_id"] == scope.trips.first
      assert is_binary(log.changed_fields["operation_id"])
      assert log.changed_fields["affected_trip_ids"] == [log.entity_id]
    end

    test "an unused timing edit between prepare and apply returns :stale_plan with no writes",
         context do
      scope = apply_case!(context, %{spare_timing?: true})
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.remove == 1
      counts_before = scoped_counts(context)

      # An edit to a timing no trip uses still changes the fingerprint.
      scope.spare_rows
      |> hd()
      |> Ecto.Changeset.change(%{departure_offset: 60})
      |> Repo.update!()

      assert {:error, :stale_plan} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      # Nothing was written: the doomed trip, its stop times and both
      # transfers are all still there.
      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)

      assert Schedules.count_trip_transfers(context.organization.id, context.version.id, [
               scope.trips.first
             ]) == 2
    end

    test "a Replace scope holding a frequency trip returns :refused with no writes", context do
      scope = apply_case!(context, %{frequency?: true})
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert {:frequency, _trip} = review.plan.refusal
      counts_before = scoped_counts(context)

      assert {:error, :refused} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.second)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.third)
    end

    test "a plan with an open pairing decision returns :blocking_issues with no writes",
         context do
      scope = apply_case!(context, %{duplicate_start?: true})
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert review.plan.counts.needs_decision == 1
      counts_before = scoped_counts(context)

      assert {:error, :blocking_issues} =
               Schedules.apply_paste(
                 scope.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      # The block runs before any write, so the unpaired trip survives too.
      assert scoped_counts(context) == counts_before
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.first)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.second)
      assert %Trip{} = Repo.get_by(Trip, trip_id: scope.trips.second_b)
    end

    test "a foreign route_id returns :not_found", context do
      scope = apply_case!(context)
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      assert {:error, :not_found} =
               Schedules.apply_paste(
                 "R-NOPE",
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_route = route_fixture(other_organization.id, other_version.id)

      assert {:error, :not_found} =
               Schedules.apply_paste(
                 other_route.route_id,
                 scope_params(scope),
                 input,
                 review.fingerprint,
                 context.audit
               )
    end

    test "a pattern outside the direction returns :not_found", context do
      scope = apply_case!(context)
      input = replace_input(keep_b_text())
      review = prepare_review!(context, scope, input)

      params =
        scope_params(scope)
        |> Map.put(:pattern_id, scope.rev.pattern.id)

      assert {:error, :not_found} =
               Schedules.apply_paste(
                 scope.route_id,
                 params,
                 input,
                 review.fingerprint,
                 context.audit
               )
    end
  end

  defp prepare_review!(context, scope, input) do
    assert {:ok, loaded} =
             Schedules.load_paste_scope(
               context.organization.id,
               context.version.id,
               scope.route_id,
               scope_params(scope)
             )

    assert {:ok, review} = TimetablePaste.review(loaded, input)
    review
  end

  defp scope_params(scope), do: %{service_id: scope.service, direction_id: 0}

  defp replace_input(text) do
    %{
      text: text,
      layout: :auto,
      header?: true,
      overrides: %{},
      confirmations: MapSet.new(),
      decisions: %{},
      mode: :replace,
      template_timing_id: nil,
      stamp: "Sep 28",
      block_rows: []
    }
  end

  # Keeps the 07:00 trip; the 06:00 trip is unpaired and becomes the removal.
  defp keep_b_text do
    "Central Station\tMarket Street\tHospital\n07:00\t07:05\t07:10\n"
  end

  defp scoped_counts(context) do
    %{
      trips: scoped(Trip, context) |> Repo.aggregate(:count),
      stop_times: scoped(StopTime, context) |> Repo.aggregate(:count),
      transfers: scoped(Transfer, context) |> Repo.aggregate(:count)
    }
  end

  defp scoped(schema, context) do
    from(row in schema,
      where:
        row.organization_id == ^context.organization.id and
          row.gtfs_version_id == ^context.version.id
    )
  end

  defp where_trip(query, trip_id), do: from(row in query, where: row.trip_id == ^trip_id)

  defp trip_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^context.organization.id and
            l.gtfs_version_id == ^context.version.id and l.entity_type == "trip",
        order_by: [asc: l.entity_external_id, asc: l.inserted_at]
      )
    )
  end

  defp apply_case!(context, opts \\ %{}) do
    opts = Map.new(opts)
    organization_id = context.organization.id
    version_id = context.version.id

    route = route_fixture(organization_id, version_id, %{route_id: "R-APPLY"})

    for {stop_id, name, code} <- [
          {"PSA-1", "Central Station", "1001"},
          {"PSA-2", "Market Street", "1002"},
          {"PSA-3", "Hospital", "1003"}
        ] do
      stop =
        stop_fixture(organization_id, version_id, %{stop_id: stop_id, stop_name: name})

      stop |> Ecto.Changeset.change(%{stop_code: code}) |> Repo.update!()
    end

    service = weekly_calendar!(context, "WKD-APPLY", "Apply Weekday")

    main =
      schedule_pattern_fixture(organization_id, version_id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: "MAIN",
        route_pattern_name: "Main",
        route_pattern_sort_order: 0,
        headsign: "Hospital",
        timing_name: "Standard",
        stops: [{"PSA-1", 0, 0, 1}, {"PSA-2", 300, 300, 1}, {"PSA-3", 600, 600, 1}]
      })

    rev =
      schedule_pattern_fixture(organization_id, version_id, %{
        route_id: route.route_id,
        direction_id: 1,
        route_pattern_id: "REV",
        route_pattern_name: "Reverse",
        route_pattern_sort_order: 1,
        headsign: "Central",
        timing_name: "Standard",
        stops: [{"PSA-3", 0, 0, 1}, {"PSA-2", 300, 300, 1}, {"PSA-1", 600, 600, 1}]
      })

    first =
      schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
        trip_id: "R-APPLY-0-WKD-APPLY-0600",
        service_id: service,
        start_time: "06:00:00"
      }).trip

    second =
      schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
        trip_id: "R-APPLY-0-WKD-APPLY-0700",
        service_id: service,
        start_time: "07:00:00"
      }).trip

    transfer_fixture(organization_id, version_id, %{
      from_stop_id: "PSA-1",
      to_stop_id: "PSA-2",
      from_trip_id: first.trip_id,
      to_trip_id: second.trip_id,
      transfer_type: 0
    })

    transfer_fixture(organization_id, version_id, %{
      from_stop_id: "PSA-2",
      to_stop_id: "PSA-3",
      from_trip_id: second.trip_id,
      to_trip_id: first.trip_id,
      transfer_type: 0
    })

    extra = %{third: nil, second_b: nil, spare_rows: []}

    extra =
      if opts[:frequency?] do
        third =
          schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
            trip_id: "R-APPLY-0-WKD-APPLY-0900",
            service_id: service,
            start_time: "09:00:00"
          }).trip

        frequency_fixture(organization_id, version_id, third.trip_id, %{
          start_time: "09:00:00",
          end_time: "12:00:00",
          headway_secs: 1200,
          exact_times: 0
        })

        %{extra | third: third.trip_id}
      else
        extra
      end

    extra =
      if opts[:duplicate_start?] do
        second_b =
          schedule_trip_fixture(organization_id, version_id, route.route_id, main, %{
            trip_id: "R-APPLY-0-WKD-APPLY-0700B",
            service_id: service,
            start_time: "07:00:00"
          }).trip

        %{extra | second_b: second_b.trip_id}
      else
        extra
      end

    extra =
      if opts[:spare_timing?] do
        spare = timed_pattern_fixture(main.pattern, %{name: "Spare"})

        rows =
          [{0, 0}, {360, 360}, {720, 720}]
          |> Enum.zip(main.occurrences)
          |> Enum.map(fn {{arrival, departure}, occurrence} ->
            timed_pattern_stop_fixture(spare, occurrence, %{
              arrival_offset: arrival,
              departure_offset: departure,
              timepoint: 1
            })
          end)

        %{extra | spare_rows: rows}
      else
        extra
      end

    %{
      route_id: route.route_id,
      service: service,
      main: main,
      rev: rev,
      trips: %{
        first: first.trip_id,
        second: second.trip_id,
        third: extra.third,
        second_b: extra.second_b
      },
      spare_rows: extra.spare_rows
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

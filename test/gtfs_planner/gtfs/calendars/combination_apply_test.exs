defmodule GtfsPlanner.Gtfs.Calendars.CombinationApplyTest do
  @moduledoc """
  The reviewed calendar combination's write path (step 16): `Gtfs.apply_calendar_change/3`
  dispatching the combination to `Calendars` and the one-transaction move with its audits.

  These cases prove, against real scoped rows, the committed package-05 producer and the
  ordinary read-committed `Repo` (no injected internal transaction adapter):

  - Every source trip moves exactly once to the destination while keeping its identity,
    pattern, shape, stop times and frequencies, its source keeps every native and metadata
    row with a trip count of zero, and no transfer row is inserted, changed or deleted.
  - Only destination native dates and moved trip columns are written; the destination's
    effective dates evaluate to exactly the reviewed result and an unchanged destination
    keeps its stored rows.
  - Exactly one operation UUID links the logs, exactly one real log carries the complete
    `combination` envelope, and no trip log repeats the member list (AC-26, critique M3).
  - A no-op writes no anchor, row or log and has a nil `operation_id`; a stale token, a
    refused native encoding or a foreign/staging/non-editor scope writes nothing.
  - An audit rejection (a deferred insert trigger), an injected trip row-count mismatch and
    a single injected serialization failure each leave the whole operation consistent: the
    first two roll every calendar, trip and log back, and the third retries the whole
    transaction and commits exactly one operation.

  The focused gate command
  `mix test test/gtfs_planner/gtfs/calendars/combination_apply_test.exs
  test/gtfs_planner/gtfs/calendars/combination_concurrency_test.exs` is deferred to branch
  review; every assertion here is unexecuted until that gate runs.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @command {:combine, "DEST", ["SAT"], %{}}

  # The reviewed destination "DEST" is the weekday run 2026-03-02..2026-03-06 (Mon-Fri) and the
  # moving source "SAT" is a dates-only calendar on 2026-03-07 and 2026-03-09, so the union adds
  # both the gained Saturday and the gained Monday. The non-selected companion "MID" runs on
  # 2026-03-02, which the moving trip only gains, so its block clears.
  @review_union [
    ~D[2026-03-02],
    ~D[2026-03-03],
    ~D[2026-03-04],
    ~D[2026-03-05],
    ~D[2026-03-06],
    ~D[2026-03-07],
    ~D[2026-03-09]
  ]

  # The destination's weekly row keeps its Mon-Fri mask but has to span the gained Monday.
  @projected_weekly_end_date ~D[2026-03-09]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R_COMBINE_APPLY"})
    actor = user_fixture(%{email: "combination-apply-#{unique()}@example.test"})
    organization_membership_fixture(actor, organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    %{
      organization: organization,
      version: version,
      route: route,
      actor: actor,
      audit: audit_for(organization.id, version.id, actor.id)
    }
  end

  describe "applying a reviewed combination" do
    test "moves every source trip once and audits the destination and the trips atomically",
         context do
      scope = seed_moving_scope(context)
      source_rows_before = source_footprint(context, "SAT")
      children_before = trip_children(context, scope.trips.source.id)
      transfers_before = footprint(context).transfers

      assert {:ok, result} = apply_combination(context, review_token(context))

      assert result.action == :combined
      assert result.destination_id == "DEST"
      assert result.moved_trip_count == 1
      assert result.changed_trip_ids == [scope.trips.source.id]
      assert result.affected_service_ids == ["DEST", "SAT"]

      assert result.operation_id =~
               ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

      # AC-11: the moved trip is the same trip - identity, route, pattern, shape, head sign,
      # stop times and frequencies all survive - and only its service and reviewed clear changed.
      moved = reload_trip(context, scope.trips.source.id)
      assert moved.trip_id == "SAT_T1"
      assert moved.service_id == "DEST"
      assert moved.block_id == nil
      assert moved.route_id == scope.trips.source.route_id
      assert moved.route_pattern_id == scope.trips.source.route_pattern_id
      assert moved.shape_id == "S_SAT"
      assert moved.trip_headsign == scope.trips.source.trip_headsign
      assert trip_children(context, moved.id) == children_before
      assert source_trip_count(context, "SAT") == 0
      assert source_footprint(context, "SAT") == source_rows_before

      # The destination's own trip keeps its service and block and is never moved.
      destination_trip = reload_trip(context, scope.trips.destination.id)
      assert destination_trip.service_id == "DEST"
      assert destination_trip.block_id == "A701"
      assert destination_trip.updated_at == scope.trips.destination.updated_at

      # AC-11/AC-18: every transfer row is exactly what it was, and the non-selected companion
      # stayed on its own calendar.
      assert footprint(context).transfers == transfers_before
      assert reload_trip(context, scope.trips.companion.id).service_id == "MID"

      # AC-9 only writes the destination's native rows: the weekly endpoints span the gained
      # Monday, the gained Saturday is one addition, and the stored rows evaluate exactly to the
      # reviewed result. The destination keeps its metadata anchor.
      assert destination_weekly(context) == {"DEST", ~D[2026-03-02], @projected_weekly_end_date}
      assert destination_exceptions(context) == [{"DEST", ~D[2026-03-07], 1}]
      assert destination_dates(context) == @review_union
      assert destination_name(context) == "Service DEST"

      assert_written_logs(context, result)
    end

    test "a trip-only combination writes no calendar log and hosts the envelope on the trip log",
         context do
      scope = seed_static_destination_scope(context, with_source_trip: true)
      destination_before = destination_footprint(context)

      assert {:ok, result} = apply_combination(context, review_token(context))

      assert result.action == :combined
      assert result.moved_trip_count == 1
      assert result.changed_trip_ids == [scope.trips.source.id]
      assert result.affected_service_ids == ["DEST", "SAT"]

      # The destination's effective dates were already the reviewed result, so no calendar row,
      # exception row or calendar log is written at all.
      assert destination_footprint(context) == destination_before
      assert reload_trip(context, scope.trips.source.id).service_id == "DEST"

      assert [log] = change_logs(context)
      assert log.entity_type == "trip"
      assert log.entity_external_id == "SAT_T1"
      assert log.changed_fields["operation_id"] == result.operation_id
      refute Map.has_key?(log.changed_fields, "affected_trip_ids")

      assert log.changed_fields["combination"] == %{
               "destination_id" => "DEST",
               "selected_service_ids" => ["DEST", "SAT"],
               "changed_trip_ids" => [scope.trips.source.id],
               "decisions" => %{}
             }
    end

    test "moves three source trips in one operation with one envelope and no member list per log",
         context do
      scope = seed_static_destination_scope(context, with_source_trip: true)

      second =
        trip_fixture(context.organization.id, context.version.id, context.route.id, %{
          trip_id: "SAT_T2",
          service_id: "SAT",
          block_id: "A700"
        })

      third =
        trip_fixture(context.organization.id, context.version.id, context.route.id, %{
          trip_id: "SAT_T3",
          service_id: "SAT",
          block_id: nil
        })

      assert {:ok, result} = apply_combination(context, review_token(context))

      assert Enum.sort(result.changed_trip_ids) ==
               Enum.sort([scope.trips.source.id, second.id, third.id])

      logs = change_logs(context)

      # Every moved trip is logged once and exactly one log carries the complete member list, so a
      # larger selection cannot repeat the members per trip (AC-19/AC-26, critique M3). A trip log
      # carries its own snapshot and the operation UUID and nothing that grows with the selection.
      assert Enum.map(logs, & &1.entity_type) == ["trip", "trip", "trip"]

      assert Enum.count(logs, &Map.has_key?(&1.changed_fields, "combination")) == 1

      assert Enum.all?(logs, &(&1.changed_fields["operation_id"] == result.operation_id))

      assert Enum.all?(logs, fn log ->
               Enum.sort(Map.keys(log.changed_fields)) == ["after", "before", "operation_id"]
             end)
    end

    test "an unchanged combination writes nothing and reports no operation", context do
      _scope = seed_static_destination_scope(context, with_source_trip: false)
      before = footprint(context)

      assert {:ok, result} = apply_combination(context, review_token(context))

      # AC-12: no trips move and the destination's effective dates are unchanged, so there is no
      # operation UUID, no anchor, no row and no log.
      assert result == %{
               action: :unchanged,
               operation_id: nil,
               destination_id: "DEST",
               moved_trip_count: 0,
               changed_trip_ids: [],
               affected_service_ids: []
             }

      assert footprint(context) == before
      assert change_logs(context) == []
    end
  end

  describe "refresh, scope and rollback refusals" do
    test "a second confirmation with the old token never moves newly created trips", context do
      scope = seed_moving_scope(context)

      assert {:ok, first} = apply_combination(context, review_token(context))
      assert reload_trip(context, scope.trips.source.id).service_id == "DEST"

      # The retained source allows later creation (AC-11), and the old token describes neither the
      # committed result nor the new trip.
      created =
        trip_fixture(context.organization.id, context.version.id, context.route.id, %{
          trip_id: "SAT_T2",
          service_id: "SAT",
          block_id: "A700"
        })

      logs_before = change_logs(context)

      assert {:error, :stale_review} = apply_combination(context, first.operation_id)

      assert reload_trip(context, created.id).service_id == "SAT"
      assert reload_trip(context, created.id).updated_at == created.updated_at
      assert reload_trip(context, scope.trips.source.id).service_id == "DEST"
      assert change_logs(context) == logs_before
    end

    test "a token reviewed before another committed change is stale with zero writes", context do
      _scope = seed_moving_scope(context)
      token = review_token(context)

      # A cooperating writer commits a new source trip after the review: the reviewed rows are no
      # longer current, so the token is refused before any write.
      trip_fixture(context.organization.id, context.version.id, context.route.id, %{
        trip_id: "SAT_T9",
        service_id: "SAT"
      })

      before = footprint(context)

      assert {:error, :stale_review} = apply_combination(context, token)
      assert footprint(context) == before
      assert change_logs(context) == []
    end

    test "refuses a destination that cannot carry the result natively", context do
      _scope = seed_metadata_only_scope(context)
      before = footprint(context)

      # The projected destination would have neither a weekly row nor an exception row while a
      # moved trip still references it, so the reviewed move is refused before anything is written.
      assert {:error, :native_service_required} =
               apply_combination(
                 context,
                 String.duplicate("a", 64),
                 {:combine, "META", ["SAT"], %{}}
               )

      assert footprint(context) == before
      assert change_logs(context) == []
    end

    test "denies a foreign, staging or non-editor scope without writing", context do
      _scope = seed_moving_scope(context)
      token = review_token(context)
      before = footprint(context)
      foreign = foreign_scope()

      # A context naming another organization cannot resolve this organization's published version,
      # and this organization cannot name another organization's version.
      foreign_organization = %{context.audit | organization_id: foreign.organization.id}

      assert {:error, :not_found} =
               Gtfs.apply_calendar_change(@command, token, foreign_organization)

      foreign_version = %{context.audit | gtfs_version_id: foreign.version.id}

      assert {:error, :not_found} = Gtfs.apply_calendar_change(@command, token, foreign_version)

      # A published-version requirement: the combination never treats a staging version as writable.
      assert {:error, :not_found} =
               with_staging_version(context, fn ->
                 Gtfs.apply_calendar_change(@command, token, context.audit)
               end)

      # A current active editor membership is required, and a plain member is refused.
      assert {:error, :forbidden} =
               Gtfs.apply_calendar_change(@command, token, member_audit(context))

      assert footprint(context) == before
      assert change_logs(context) == []
      assert source_trip_count(context, "SAT") == 1
    end

    test "rolls the destination rows and every trip back when the calendar audit is rejected",
         context do
      _scope = seed_moving_scope(context)
      token = review_token(context)
      before = footprint(context)

      install_audit_rejection_trigger!("calendar")

      # The destination's own rows are written before the calendar log, so this rejection is the
      # failure the whole transaction must undo.
      assert {:error, %Postgrex.Error{}} = apply_combination(context, token)

      drop_audit_rejection_trigger()

      assert footprint(context) == before
      assert change_logs(context) == []
    end

    test "rolls the destination change and the trip moves back when a trip audit is rejected",
         context do
      _scope = seed_moving_scope(context)
      token = review_token(context)
      before = footprint(context)

      install_audit_rejection_trigger!("trip")

      assert {:error, {:audit_failed, %Postgrex.Error{}}} = apply_combination(context, token)

      drop_audit_rejection_trigger()

      # The destination update and its calendar log are already inside the transaction, and both
      # are rolled back with the refused trip log.
      assert footprint(context) == before
      assert change_logs(context) == []
    end

    test "rolls everything back when the moving trip update affects the wrong row count",
         context do
      _scope = seed_moving_scope(context)
      token = review_token(context)
      before = footprint(context)

      install_trip_update_skip_trigger!()

      assert {:error, {:count_mismatch, 1, 0}} = apply_combination(context, token)

      drop_trip_update_skip_trigger()

      assert footprint(context) == before
      assert change_logs(context) == []
    end

    test "retries the whole transaction after one injected serialization failure", context do
      scope = seed_moving_scope(context)
      token = review_token(context)

      install_serialization_failure_once_trigger!()

      assert {:ok, result} = apply_combination(context, token)

      drop_serialization_failure_once_trigger()

      # The failed attempt wrote nothing that survived: the committed state is exactly one
      # operation's, with one calendar log and one trip log sharing one operation UUID.
      assert result.action == :combined
      assert reload_trip(context, scope.trips.source.id).service_id == "DEST"
      assert Enum.map(change_logs(context), & &1.entity_type) == ["calendar", "trip"]
      assert_written_logs(context, result)
    end
  end

  # --- the committed operation's audit contract ------------------------------

  defp assert_written_logs(context, result) do
    logs = change_logs(context)

    assert [calendar_log, trip_log] = logs
    assert calendar_log.entity_type == "calendar"
    assert calendar_log.entity_external_id == "DEST"
    assert trip_log.entity_type == "trip"
    assert trip_log.entity_external_id == "SAT_T1"

    # One operation UUID links the logs; the complete selection, the changed trip IDs and the
    # decisions occur in exactly one real log envelope, and the destination calendar log hosts it
    # because that calendar actually changed (AC-19). No dummy calendar log exists for trip-only
    # work, and no trip log repeats the member list (AC-26, critique M3).
    assert calendar_log.changed_fields["operation_id"] == result.operation_id
    assert trip_log.changed_fields["operation_id"] == result.operation_id
    refute Map.has_key?(trip_log.changed_fields, "combination")
    refute Map.has_key?(trip_log.changed_fields, "affected_trip_ids")

    assert calendar_log.changed_fields["combination"] == %{
             "destination_id" => "DEST",
             "selected_service_ids" => ["DEST", "SAT"],
             "changed_trip_ids" => result.changed_trip_ids,
             "decisions" => %{}
           }

    # The persisted JSON carries the existing aggregate before/after snapshots plus the envelope.
    assert calendar_log.changed_fields["before"]["weekly"]["end_date"] == "2026-03-06"
    assert calendar_log.changed_fields["after"]["weekly"]["end_date"] == "2026-03-09"
    assert calendar_log.changed_fields["after"]["name"] == "Service DEST"

    assert calendar_log.changed_fields["after"]["dates"] == [
             %{"date" => "2026-03-07", "exception_type" => 1}
           ]

    # One trip log per moved trip: its own before/after snapshot, the destination service and the
    # reviewed clear, and no member list.
    assert trip_log.changed_fields["before"]["service_id"] == "SAT"
    assert trip_log.changed_fields["before"]["block_id"] == "A700"
    assert trip_log.changed_fields["after"]["service_id"] == "DEST"
    assert trip_log.changed_fields["after"]["block_id"] == nil

    assert trip_log.changed_fields["after"]["frequencies"] ==
             trip_log.changed_fields["before"]["frequencies"]
  end

  # --- fixtures --------------------------------------------------------------

  # A destination with a weekly row, a moving dates-only source and a non-selected companion on the
  # moving trip's block. The destination trip and the companion trip are real counterpart rows the
  # committed producer reads, and the type-4 record between the moving trip and the companion must
  # survive the move.
  defp seed_moving_scope(context) do
    {organization_id, version_id} = {context.organization.id, context.version.id}
    route_id = context.route.route_id

    destination =
      calendar_service_fixture(organization_id, version_id, %{
        service_id: "DEST",
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-03-02],
        end_date: ~D[2026-03-06]
      })

    source =
      calendar_service_fixture(organization_id, version_id, %{
        service_id: "SAT",
        dates: [~D[2026-03-07], ~D[2026-03-09]]
      })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "MID",
      dates: [~D[2026-03-02]]
    })

    destination_trip =
      blocked_trip_fixture(organization_id, version_id, route_id, %{
        trip_id: "DEST_T1",
        service_id: destination.service_id,
        block_id: "A701",
        first_arrival: "08:00:00",
        last_arrival: "09:00:00"
      })

    source_trip =
      blocked_trip_fixture(organization_id, version_id, route_id, %{
        trip_id: "SAT_T1",
        service_id: source.service_id,
        block_id: "A700",
        first_arrival: "09:30:00",
        last_arrival: "10:30:00"
      })
      |> set_trip_attribute(:shape_id, "S_SAT")

    companion_trip =
      blocked_trip_fixture(organization_id, version_id, route_id, %{
        trip_id: "MID_T1",
        service_id: "MID",
        block_id: "A700",
        first_arrival: "11:00:00",
        last_arrival: "12:00:00"
      })

    frequency_row_fixture(organization_id, version_id, %{
      trip_id: "SAT_T1",
      start_time: "09:00:00",
      end_time: "12:00:00",
      headway_secs: 900
    })

    transfer = in_seat_transfer_fixture(organization_id, version_id, source_trip, companion_trip)

    %{
      trips: %{
        destination: destination_trip,
        source: source_trip,
        companion: companion_trip
      },
      transfer: transfer
    }
  end

  # A destination whose own effective dates already cover every moving date, so the encoded
  # destination rows are unchanged. The source either has one trip (a real move with no calendar
  # write) or none at all (the no-op).
  defp seed_static_destination_scope(context, opts) do
    {organization_id, version_id} = {context.organization.id, context.version.id}

    destination =
      calendar_service_fixture(organization_id, version_id, %{
        service_id: "DEST",
        saturday: 1,
        sunday: 0,
        start_date: ~D[2026-03-02],
        end_date: ~D[2026-03-28]
      })

    source =
      calendar_service_fixture(organization_id, version_id, %{
        service_id: "SAT",
        dates: [~D[2026-03-07], ~D[2026-03-14]]
      })

    destination_trip =
      blocked_trip_fixture(organization_id, version_id, context.route.route_id, %{
        trip_id: "DEST_T1",
        service_id: destination.service_id,
        block_id: "A701"
      })

    source_trip =
      if Keyword.fetch!(opts, :with_source_trip) do
        blocked_trip_fixture(organization_id, version_id, context.route.route_id, %{
          trip_id: "SAT_T1",
          service_id: source.service_id,
          block_id: "A700"
        })
      end

    %{trips: %{destination: destination_trip, source: source_trip}}
  end

  # A metadata-only destination with no native service row while a moving trip exists, and a source
  # whose dates-only additions never intersect the destination: the reviewed union is empty, so the
  # projected destination has neither a weekly row nor an exception row.
  defp seed_metadata_only_scope(context) do
    {organization_id, version_id} = {context.organization.id, context.version.id}

    calendar_attribute_fixture(organization_id, version_id, %{
      service_id: "META",
      service_description: "Metadata Only"
    })

    # A dates-only identity with one removal and no weekly row has no active date and no baseline
    # date it deliberately removes, so the reviewed union is empty.
    calendar_date_fixture(organization_id, version_id, %{
      service_id: "SAT",
      date: ~D[2026-03-30],
      exception_type: 2
    })

    trip_fixture(organization_id, version_id, context.route.id, %{
      trip_id: "SAT_T1",
      service_id: "SAT"
    })

    :ok
  end

  defp foreign_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture(%{email: "combination-foreign-#{unique()}@example.test"})
    organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      audit: audit_for(organization.id, version.id, actor.id)
    }
  end

  defp member_audit(context) do
    member = user_fixture(%{email: "combination-member-#{unique()}@example.test"})
    organization_membership_fixture(member, context.organization, ["viewer"])

    audit_for(context.organization.id, context.version.id, member.id)
  end

  defp with_staging_version(context, fun) do
    Repo.update_all(
      from(v in GtfsVersion, where: v.id == ^context.version.id),
      set: [publication_status: "staging"]
    )

    fun.()
  end

  # --- helpers ---------------------------------------------------------------

  defp unique, do: System.unique_integer([:positive])

  defp audit_for(organization_id, version_id, actor_id) do
    %AuditContext{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      station_stop_id: nil,
      actor_id: actor_id,
      actor_email: "combination-apply@example.test"
    }
  end

  defp apply_combination(context, token, command \\ @command) do
    Gtfs.apply_calendar_change(command, token, context.audit)
  end

  defp review_combination(context, command \\ @command) do
    Gtfs.review_calendar_change(command, selected_fingerprints(command), context.audit)
  end

  defp review_token(context) do
    assert {:ok, review} = review_combination(context)
    assert review.ready?
    assert is_binary(review.fingerprint)
    review.fingerprint
  end

  defp selected_fingerprints({:combine, destination_id, source_ids, _decisions}) do
    Map.new([destination_id | source_ids], &{&1, "client-#{&1}"})
  end

  defp set_trip_attribute(trip, field, value) do
    {:ok, trip} = Repo.update(Ecto.Changeset.change(trip, %{field => value}))
    trip
  end

  defp reload_trip(context, id) do
    Repo.get_by!(Trip, id: id, organization_id: context.organization.id)
  end

  defp source_trip_count(context, service_id) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^context.organization.id and
            t.gtfs_version_id == ^context.version.id and t.service_id == ^service_id
      ),
      :count
    )
  end

  defp trip_children(context, trip_uuid) do
    trip_id = Repo.get!(Trip, trip_uuid).trip_id
    {organization_id, version_id} = {context.organization.id, context.version.id}

    %{
      stop_times:
        Repo.all(
          from(st in StopTime,
            where:
              st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id and
                st.trip_id == ^trip_id,
            order_by: st.stop_sequence,
            select: {st.stop_sequence, st.stop_id, st.arrival_time, st.departure_time}
          )
        ),
      frequencies:
        Repo.all(
          from(f in Frequency,
            where:
              f.organization_id == ^organization_id and f.gtfs_version_id == ^version_id and
                f.trip_id == ^trip_id,
            order_by: f.start_time,
            select: {f.start_time, f.end_time, f.headway_secs}
          )
        )
    }
  end

  defp destination_weekly(context) do
    Repo.one!(
      from(c in Calendar,
        where:
          c.organization_id == ^context.organization.id and
            c.gtfs_version_id == ^context.version.id and c.service_id == "DEST",
        select: {c.service_id, c.start_date, c.end_date}
      )
    )
  end

  defp destination_exceptions(context) do
    Repo.all(
      from(d in CalendarDate,
        where:
          d.organization_id == ^context.organization.id and
            d.gtfs_version_id == ^context.version.id and d.service_id == "DEST",
        order_by: d.date,
        select: {d.service_id, d.date, d.exception_type}
      )
    )
  end

  defp destination_name(context) do
    Repo.one!(
      from(a in CalendarAttribute,
        where:
          a.organization_id == ^context.organization.id and
            a.gtfs_version_id == ^context.version.id and a.service_id == "DEST",
        select: a.service_description
      )
    )
  end

  defp destination_dates(context) do
    weekly =
      Repo.one(
        from(c in Calendar,
          where:
            c.organization_id == ^context.organization.id and
              c.gtfs_version_id == ^context.version.id and c.service_id == "DEST"
        )
      )

    exceptions =
      Repo.all(
        from(d in CalendarDate,
          where:
            d.organization_id == ^context.organization.id and
              d.gtfs_version_id == ^context.version.id and d.service_id == "DEST",
          order_by: d.date
        )
      )

    ServiceDates.active_dates(weekly, exceptions)
  end

  defp source_footprint(context, service_id) do
    {organization_id, version_id} = {context.organization.id, context.version.id}

    %{
      weekly:
        Repo.all(
          from(c in Calendar,
            where:
              c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id and
                c.service_id == ^service_id,
            select: {c.service_id, c.start_date, c.end_date, c.updated_at}
          )
        ),
      exceptions:
        Repo.all(
          from(d in CalendarDate,
            where:
              d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id and
                d.service_id == ^service_id,
            order_by: d.date,
            select: {d.date, d.exception_type}
          )
        ),
      attributes:
        Repo.all(
          from(a in CalendarAttribute,
            where:
              a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id and
                a.service_id == ^service_id,
            select: {a.service_id, a.service_description, a.rating_start_date}
          )
        )
    }
  end

  defp destination_footprint(context) do
    %{
      weekly: source_footprint(context, "DEST").weekly,
      exceptions: source_footprint(context, "DEST").exceptions,
      attributes: source_footprint(context, "DEST").attributes
    }
  end

  # Everything a combination must not write when it refuses or rolls back.
  defp footprint(context) do
    {organization_id, version_id} = {context.organization.id, context.version.id}

    %{
      logs:
        Repo.aggregate(
          from(l in ChangeLog, where: l.organization_id == ^organization_id),
          :count
        ),
      trips:
        Repo.all(
          from(t in Trip,
            where: t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id,
            order_by: t.id,
            select: {t.id, t.trip_id, t.service_id, t.block_id, t.updated_at}
          )
        ),
      calendars:
        Repo.all(
          from(c in Calendar,
            where: c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id,
            order_by: c.service_id,
            select: {c.service_id, c.monday, c.start_date, c.end_date, c.updated_at}
          )
        ),
      exceptions:
        Repo.all(
          from(d in CalendarDate,
            where: d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id,
            order_by: [d.service_id, d.date],
            select: {d.service_id, d.date, d.exception_type}
          )
        ),
      attributes:
        Repo.all(
          from(a in CalendarAttribute,
            where: a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id,
            order_by: a.service_id,
            select: {a.service_id, a.service_description}
          )
        ),
      transfers:
        Repo.all(
          from(tr in Transfer,
            where: tr.organization_id == ^organization_id and tr.gtfs_version_id == ^version_id,
            order_by: tr.id,
            select: {tr.id, tr.transfer_type, tr.from_trip_id, tr.to_trip_id}
          )
        ),
      stop_times:
        Repo.all(
          from(st in StopTime,
            where: st.organization_id == ^organization_id and st.gtfs_version_id == ^version_id,
            order_by: [st.trip_id, st.stop_sequence],
            select: {st.trip_id, st.stop_sequence, st.stop_id, st.arrival_time, st.departure_time}
          )
        ),
      frequencies:
        Repo.all(
          from(f in Frequency,
            where: f.organization_id == ^organization_id and f.gtfs_version_id == ^version_id,
            order_by: [f.trip_id, f.start_time],
            select: {f.trip_id, f.start_time, f.end_time, f.headway_secs}
          )
        )
    }
  end

  defp change_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^context.organization.id and
            l.gtfs_version_id == ^context.version.id,
        order_by: [asc: l.entity_type, asc: l.inserted_at, asc: l.id]
      )
    )
  end

  # --- database-level fault injection ---------------------------------------

  # A deferred insert trigger rejecting one entity type's change log is the same fixture the block
  # apply tests use: it proves a refused audit insert rolls the already-written rows back.
  defp install_audit_rejection_trigger!(entity_type) do
    Repo.query!("""
    CREATE FUNCTION combination_audit_rejection_#{entity_type}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = '#{entity_type}' THEN
        RAISE EXCEPTION 'combination audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER combination_audit_rejection_#{entity_type}_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION combination_audit_rejection_#{entity_type}();
    """)
  end

  defp drop_audit_rejection_trigger do
    for entity_type <- ["calendar", "trip"] do
      Repo.query!(
        "DROP TRIGGER IF EXISTS combination_audit_rejection_#{entity_type}_trigger ON change_logs"
      )

      Repo.query!("DROP FUNCTION IF EXISTS combination_audit_rejection_#{entity_type}()")
    end
  end

  # A `BEFORE UPDATE ... RETURN NULL` trigger makes the moving trip statement skip its rows, so the
  # statement's affected-row count is smaller than the number of moved trips.
  defp install_trip_update_skip_trigger! do
    Repo.query!("""
    CREATE FUNCTION combination_trip_update_skip() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RETURN NULL;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER combination_trip_update_skip_trigger
    BEFORE UPDATE ON trips
    FOR EACH ROW
    EXECUTE FUNCTION combination_trip_update_skip();
    """)
  end

  defp drop_trip_update_skip_trigger do
    Repo.query!("DROP TRIGGER IF EXISTS combination_trip_update_skip_trigger ON trips")
    Repo.query!("DROP FUNCTION IF EXISTS combination_trip_update_skip()")
  end

  # A sequence advances outside the transaction, so this trigger raises a serialization failure for
  # the first moving-trip update only: the whole transaction is retried and the second attempt
  # commits. `nextval` is the one state a rolled-back transaction cannot undo, which is what makes
  # the injection deterministic without a sleep or an arbitrary attempt counter.
  defp install_serialization_failure_once_trigger! do
    Repo.query!("DROP SEQUENCE IF EXISTS combination_serialization_probe_seq")
    Repo.query!("CREATE SEQUENCE combination_serialization_probe_seq START 1")

    Repo.query!("""
    CREATE FUNCTION combination_serialization_probe() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF nextval('combination_serialization_probe_seq') = 1 THEN
        RAISE EXCEPTION 'injected serialization failure' USING ERRCODE = '40001';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER combination_serialization_probe_trigger
    BEFORE UPDATE ON trips
    FOR EACH ROW
    WHEN (NEW.service_id = 'DEST')
    EXECUTE FUNCTION combination_serialization_probe();
    """)
  end

  defp drop_serialization_failure_once_trigger do
    Repo.query!("DROP TRIGGER IF EXISTS combination_serialization_probe_trigger ON trips")
    Repo.query!("DROP FUNCTION IF EXISTS combination_serialization_probe()")
    Repo.query!("DROP SEQUENCE IF EXISTS combination_serialization_probe_seq")
  end
end

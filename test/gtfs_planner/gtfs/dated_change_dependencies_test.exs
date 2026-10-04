defmodule GtfsPlanner.Gtfs.DatedChangeDependenciesTest do
  @moduledoc """
  Merge evidence (EV-5) for `DatedChangePlan.prepare/2`: the impact report's
  dependency identities, its honest description of the current `Copy`/`Shift`
  contracts, and the fact that composing it changes nothing.

  The fixture is the Harbor Transit dataset, and every expectation is derived
  by hand from its rows and from the acceptance cases rather than from a second
  call into the module under test:

    * `WEEKDAY` is the 2026 weekday calendar with 2026-11-11 removed, so its
      complete original D is the 260 weekdays of 2026 less that one date. The
      accepted interval 2026-11-02..2026-11-13 holds nine of them - Nov 2, 3, 4,
      5, 6, 9, 10, 12 and 13 - so 251 dates are normal. `SPECIAL` is a second
      calendar of the same shape, and `H12-1` is another route's trip on
      `WEEKDAY`, so a plan that only read the selection would never see it.
    * `H8-1` and `H8-2` share block `B1`; `H8-2` is not selected, so it is both
      an unaffected user of `WEEKDAY` and a same-block peer whose own service
      runs on the affected dates. `H12-1` shares no block and is an unaffected
      user only. Both are reported; neither is in the change.
    * The version carries one transfer rule of each `transfer_type` 0 through 5,
      including the general type 4 and type 5 rules that reference two trips and
      no route pair. All six are dependencies whether or not they name a
      selected trip, and each row keeps its stored selectors verbatim.
    * `H8-1` and `H8-2` each hold a run assignment on `WEEKDAY`, keyed by the
      `Trip.id` UUID - not by the imported `H8-1` string the transfer rules use.
      A run assignment on a trip the plan does not touch is not listed.

  ## The current native contracts, read from their own code

  The second case drives the real `Schedules.TripChanges.Copy` and `Shift`
  planners over a hand-built review state and asserts what they do, so the
  report's `execution_stages` reasons are checked against behaviour rather than
  against prose: a copy allocates a new `trip_id`, writes no `block_id` and no
  transfer row, and its listed-duplicate check keys on pattern plus clock with
  no date in it; a shift keeps the block and moves clocks, and neither planner
  creates, removes or subdivides a calendar.

  ## What these cases do not establish

  Nothing here establishes concurrent visibility, the loader's own admission or
  the clock projection: those are EV-2, EV-3 and EV-4's subjects, and this file
  consumes what `prepare/2` composes from them. No automated gate has run yet;
  branch review executes this file.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.ConcurrencyHelpers
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DatedChangePlan
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Gtfs.Schedules.TripChanges
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo

  @first ~D[2026-11-02]
  @last ~D[2026-11-13]
  @holiday ~D[2026-11-11]
  @central "CENTRAL"
  @harbor "HARBOR"
  @depot "DEPOT"
  @task_timeout 30_000

  # The exact report keys: no command, callback, token or operation list can
  # ride along with the analysis.
  @report_keys [
    :computation,
    :dependency_digest,
    :dependency_rows,
    :execution_stages,
    :input_digest,
    :partitions,
    :projected_clocks,
    :scope,
    :schema_version,
    :timing,
    :totals,
    :unaffected_users,
    :unresolved
  ]

  # The nine weekdays the accepted interval holds, Nov 2..13 2026 less the
  # removed 2026-11-11.
  @nine ~w(2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-09 2026-11-10
           2026-11-12 2026-11-13)

  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "prepare/2 dependency impact (AC-9)" do
    test "names every calendar, block and transfer user without widening the selection", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.selected.id, harbor.second.id])
      {:ok, report} = DatedChangePlan.prepare(harbor.scope, accepted)

      rows = report.dependency_rows

      # -- the touched calendars and who else runs on them -------------------

      # Services are reported in `service_id` order, so `SPECIAL` precedes
      # `WEEKDAY`.
      assert [special, weekday] = rows.affected_services
      assert weekday.service_id == "WEEKDAY"
      assert weekday.calendar_id == harbor.weekday_calendar.id
      assert weekday.selected_trip_ids == [harbor.selected.id]

      # The two UUIDs are generated, so the pair is compared as a set.
      assert Enum.sort(weekday.unaffected_trip_ids) ==
               Enum.sort([harbor.other.id, harbor.peer.id])

      assert weekday.temporary_date_count == 9
      assert weekday.normal_date_count == 251

      assert special.service_id == "SPECIAL"
      assert special.calendar_id == harbor.special_calendar.id
      assert special.selected_trip_ids == [harbor.second.id]
      assert special.unaffected_trip_ids == []
      assert special.temporary_date_count == 9

      # A trip of a calendar no selected trip runs on is read but is not a
      # user of a touched one.
      refute Enum.any?(
               Enum.flat_map(rows.affected_services, & &1.unaffected_trip_ids),
               &(&1 == harbor.collide.id)
             )

      # The unselected users are named as dependencies and stay out of the
      # plan: neither appears in a partition's selected trips.
      assert report.unaffected_users |> Enum.sort() ==
               Enum.sort([harbor.other.id, harbor.peer.id])

      assert Enum.flat_map(report.partitions, & &1.selected_trip_ids) |> Enum.sort() ==
               Enum.sort([harbor.selected.id, harbor.second.id])

      # -- route, pattern, timing and block selectors ------------------------

      # The selection is sorted by `Trip.id`, so the two rows are identified by their
      # block rather than by their position.
      assert [blocked, unblocked] =
               Enum.sort_by(rows.trip_selectors, &(&1.block_id != nil), :desc)

      assert blocked.trip_id == harbor.selected.id
      assert blocked.route_id == "H8"
      assert blocked.block_id == "B1"
      assert unblocked.trip_id == harbor.second.id

      # Every trip of the touched block is named, ordered by its imported
      # reference, and the peer whose own service runs on the affected dates is
      # the successor candidate.
      assert [first, peer] = rows.same_block_trips

      assert peer.trip_id == harbor.peer.id
      assert peer.trip_ref == "H8-2"
      assert peer.block_id == "B1"
      assert peer.selected == false
      assert peer.successor_candidate == true

      assert first.trip_id == harbor.selected.id
      assert first.trip_ref == "H8-1"
      assert first.selected == true
      assert first.successor_candidate == true

      # A trip on another route that shares no block is a calendar user and
      # never a block peer.
      refute Enum.any?(rows.same_block_trips, &(&1.trip_id == harbor.other.id))

      # -- stop incidence of the selected trips ------------------------------

      # The two selected trips call at three stops between them; the unselected
      # peers' stop times are not the change's incidence.
      assert [
               %{stop_id: @central, occurrence_count: 2, trip_refs: ["H8-1", "H8-3"]},
               %{stop_id: @depot, occurrence_count: 1, trip_refs: ["H8-3"]},
               %{stop_id: @harbor, occurrence_count: 1, trip_refs: ["H8-1"]}
             ] = rows.stop_incidence

      # -- transfer rules of every type, conservatively --------------------

      types = rows.transfers |> Enum.map(& &1.transfer_type) |> Enum.sort()

      # One rule of each type 0..5 is present, the general types included.
      assert types == [0, 1, 2, 3, 4, 5]

      # Every row is disclosed as a review candidate, and none of them claims a
      # connection is feasible.
      assert Enum.all?(rows.transfers, &(&1.applicability == :conservative_review_candidate))

      general = transfer(rows, 5)

      # A type 5 in-seat rule names two trips and no route pair, and it is
      # listed with the stored selectors verbatim.
      assert general.from_trip_id == "H8-1"
      assert general.to_trip_id == "H8-2"
      assert general.from_route_id == nil
      assert general.to_route_id == nil

      # A rule naming a selected trip records which side referenced it; one
      # naming nothing at all references no selected trip.
      assert transfer(rows, 3).references_selected_trips == [:from_trip]
      assert transfer(rows, 5).references_selected_trips == [:from_trip]
      assert transfer(rows, 0).references_selected_trips == []
      assert transfer(rows, 4).references_selected_trips == [:to_trip]

      # -- block attributes, operating settings and run assignments ----------

      assert [%{block_id: "B1", service_id: "WEEKDAY"}] = rows.block_attributes
      assert [%{min_layover_minutes: 5}] = rows.blocking_settings
      assert [%{route_id: "H8"}] = rows.route_operating_settings

      # Runs are keyed by the `Trip.id` UUID and `day_type_key`; both selected
      # and unselected block members of the plan hold one, and the trip that
      # shares only a calendar holds none.
      # The rows are sorted by their own primary key, which is a generated
      # UUID, so this compares the set of assignments rather than their order.
      assert rows.trip_runs
             |> Enum.map(&Map.take(&1, [:day_type_key, :run_id, :trip_id]))
             |> Enum.sort_by(& &1.trip_id) ==
               Enum.sort_by(
                 [
                   %{day_type_key: "WEEKDAY", run_id: "R1", trip_id: harbor.selected.id},
                   %{day_type_key: "WEEKDAY", run_id: "R1", trip_id: harbor.peer.id}
                 ],
                 & &1.trip_id
               )
    end

    test "carries the exact totals, partitions, clocks and a blocked execution", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.selected.id, harbor.second.id])
      {:ok, report} = DatedChangePlan.prepare(harbor.scope, accepted)

      # Scoped identity is the server's own, in the imported route namespace.
      assert report.scope.organization_id == harbor.organization.id
      assert report.scope.gtfs_version_id == harbor.version.id
      assert report.scope.route_id == "H8"

      # Both digests bind this analysis to its own inputs and its own read.
      assert report.input_digest == accepted.input_digest
      assert is_binary(report.dependency_digest)
      assert String.length(report.dependency_digest) == 64

      # Two selected trips over nine affected dates each is eighteen affected
      # trip-date pairs and 502 unchanged ones; a unique-date count would say
      # nine and 251 and would hide that two trips move.
      assert report.computation == :complete
      assert report.timing == :complete
      assert report.unresolved == []

      assert report.totals == %{
               selected_trips: 2,
               affected_trip_dates: 18,
               unchanged_trip_dates: 502,
               unaffected_calendar_users: 2
             }

      assert [special, weekday] = report.partitions
      assert dates(weekday.temporary_dates) == @nine
      assert dates(special.temporary_dates) == @nine
      assert length(weekday.original_dates) == 260
      assert length(weekday.normal_dates) == 251

      # The removed holiday is in none of the three sets.
      refute Date.to_iso8601(@holiday) in dates(weekday.original_dates)

      # Partitions are reported in `service_id` order, so `SPECIAL`'s `H8-3`
      # projects first: 07:00:00 is 25,200 s and 07:15:00 is 26,100 s, both
      # +300 s, and `H8-1`'s 06:00:00/06:15:00 are 21,600 s and 22,500 s, also
      # +300 s. No clock wraps into another service day.
      assert [
               %{trip_id: second, stop_sequence: 1, temporary_departure: 25_500},
               %{trip_id: second, stop_sequence: 2, temporary_departure: 26_400},
               %{trip_id: first, stop_sequence: 1, temporary_departure: 21_900},
               %{trip_id: first, stop_sequence: 2, temporary_departure: 22_800}
             ] = report.projected_clocks

      assert second == harbor.second.id
      assert first == harbor.selected.id
    end

    test "refuses a scope or source it was not asked about instead of reporting less", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.selected.id])
      user = user_fixture()

      # A scope that names no route has no dated plan for this version.
      version_scope = %Scope{
        organization_id: harbor.organization.id,
        gtfs_version_id: harbor.version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "service_queries",
        version_name: harbor.version.name,
        resource_context: Scope.context({:version, harbor.version.id})
      }

      assert {:error, :not_found} = DatedChangePlan.prepare(version_scope, accepted)
      assert {:error, :not_found} = DatedChangePlan.prepare(%{}, accepted)

      # A forged accepted source is refused as a source, whole.
      forged = Map.put(accepted, :input_digest, String.duplicate("0", 64))

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               DatedChangePlan.prepare(harbor.scope, forged)

      # A trip that is not the scoped route's is one refusal.
      {:ok, foreign} = accept([harbor.other.id])
      assert {:error, :not_found} = DatedChangePlan.prepare(harbor.scope, foreign)
    end
  end

  describe "the current native Copy and Shift contracts (AC-10)" do
    test "the report calls every execution stage foundation-missing and says why", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.selected.id, harbor.second.id])
      {:ok, report} = DatedChangePlan.prepare(harbor.scope, accepted)

      kinds = report.execution_stages |> Enum.map(& &1.kind) |> Enum.sort()

      assert kinds == [
               :block_transfer_lineage,
               :partial_save_reconciliation,
               :partition_reassignment,
               :temporary_identity_overlap
             ]

      # Nothing here is executable, and nothing is claimed complete.
      assert Enum.all?(report.execution_stages, &(&1.status == :foundation_missing))
      assert Enum.all?(report.execution_stages, &(&1.reasons != []))

      # No key anywhere in the report is a command, a callback or a token.
      assert Enum.sort(Map.keys(report)) == @report_keys

      for stage <- report.execution_stages do
        refute stage.reasons |> Enum.join(" ") |> String.contains?("safe temporary")
      end

      # The partition stage names the services it would partition; the identity
      # stage names the selected trips.
      partition = stage(report, :partition_reassignment)
      assert partition.affected_ids == ["SPECIAL", "WEEKDAY"]
      assert Enum.any?(partition.reasons, &String.contains?(&1, "MoveCalendar"))

      identity = stage(report, :temporary_identity_overlap)
      assert Enum.sort(identity.affected_ids) == Enum.sort([harbor.selected.id, harbor.second.id])
      assert Enum.any?(identity.reasons, &String.contains?(&1, "allocate_trip_ids/5"))

      lineage = stage(report, :block_transfer_lineage)
      assert lineage.affected_ids == ["B1"]
      assert Enum.any?(lineage.reasons, &String.contains?(&1, "no connection is feasible"))

      reconciliation = stage(report, :partial_save_reconciliation)
      assert Enum.any?(reconciliation.reasons, &String.contains?(&1, "publication"))
      assert Enum.any?(reconciliation.reasons, &String.contains?(&1, "no apply command"))
    end

    test "Copy allocates a new identity, keeps no block and writes no transfer row", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      state = review_state(harbor)

      assert {:ok, change_set} =
               TripChanges.plan(
                 {:copy, [harbor.selected.id], "SPECIAL", 300, true},
                 state
               )

      assert [insert] = change_set.inserts

      # A copy is a new trip, not a temporary form of the old one.
      assert insert.attrs.trip_id != "H8-1"
      assert insert.attrs.trip_id =~ "H8"
      refute Map.has_key?(insert.attrs, :block_id)
      assert insert.attrs.service_id == "SPECIAL"

      # The stop times moved by the offset, and no transfer row is planned.
      assert Enum.map(insert.stop_times, & &1.departure_time) == ["06:05:00", "06:20:00"]
      assert Map.keys(change_set) |> Enum.sort() == [:consequences, :deletes, :inserts, :updates]
      assert change_set.updates == []
      assert change_set.deletes == []
    end

    test "Copy's listed-duplicate check keys on pattern and clock, with no date in it", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      state = review_state(harbor)

      # `H8-4` already leaves the target pattern at 06:05:00, and a copy of
      # `H8-1` shifted by +300 would leave at exactly 06:05:00, so the copy is
      # skipped. The key `duplicate_candidates/2` builds is
      # `{route_pattern_id, first_departure}` against trips of the target
      # service, and nothing in it is a date.
      assert {:ok, change_set} =
               TripChanges.plan({:copy, [harbor.selected.id], "SPECIAL", 300, true}, state)

      assert change_set.inserts == []
      assert [{:note, {:skipped_existing, id, "06:05:00"}}] = change_set.consequences
      assert id == harbor.selected.id

      # Nothing in the duplicate key is a date. The only thing Copy says about
      # dates is a warning that two calendars share some - it is not a
      # date-aware duplicate check, and 260 shared dates change nothing about
      # the collision above.
      assert {:warning, {:shared_dates, "WEEKDAY", 260}} in change_set_trip_change(harbor, state)
    end

    test "Shift keeps the block, moves the clocks and never partitions a calendar", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      state = review_state(harbor)

      assert {:ok, change_set} =
               TripChanges.plan({:shift, [harbor.selected.id, harbor.peer.id], 300, nil}, state)

      assert [%{trip_id: first}, %{trip_id: second}] = change_set.updates
      assert first.trip_id == harbor.selected.id
      assert second.trip_id == harbor.peer.id

      # No update carries `block_id`, so the block these trips already have is
      # kept, and the change set inserts and deletes nothing.
      assert Enum.all?(change_set.updates, &(not Map.has_key?(&1.fields, :block_id)))
      assert change_set.inserts == []
      assert change_set.deletes == []

      # The clocks moved; the service id did not, and no calendar row is part
      # of a change set at all.
      assert Enum.map(first.stop_times, & &1.departure_time) == ["06:05:00", "06:20:00"]
      assert Enum.map(second.stop_times, & &1.departure_time) == ["06:10:00", "06:25:00"]
      assert Map.keys(change_set) |> Enum.sort() == [:consequences, :deletes, :inserts, :updates]
    end

    test "MoveCalendar moves whole trips to another calendar without splitting dates", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      state = review_state(harbor)

      assert {:ok, change_set} =
               TripChanges.plan({:move_calendar, [harbor.selected.id], "SPECIAL"}, state)

      assert [update] = change_set.updates
      assert update.trip_id == harbor.selected.id
      assert update.fields.service_id == "SPECIAL"
      assert update.stop_times == :unchanged
      assert update.frequencies == :unchanged

      # A move carries no calendar, no block and no transfer write, and it
      # moves whole trips: nothing here creates or removes a service date.
      assert Map.keys(change_set) |> Enum.sort() == [:consequences, :deletes, :inserts, :updates]
      assert change_set.inserts == []
      assert change_set.deletes == []
    end
  end

  describe "prepare/2 is read-only (AC-10, INV-1)" do
    test "leaves every entity and audit row byte-for-byte identical", %{supervisor: supervisor} do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.selected.id, harbor.second.id])

      before = scoped_content(harbor)

      assert {:ok, _report} = DatedChangePlan.prepare(harbor.scope, accepted)

      assert scoped_content(harbor) == before
    end

    test "says the same thing twice for the same snapshot", %{supervisor: supervisor} do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept([harbor.selected.id, harbor.second.id])

      assert {:ok, first} = DatedChangePlan.prepare(harbor.scope, accepted)
      assert {:ok, second} = DatedChangePlan.prepare(harbor.scope, accepted)

      # The report is a function of the accepted source and the read, so two
      # runs over unchanged data are identical - including the digests that
      # step 8's freshness recheck compares.
      assert first == second
      assert first.dependency_digest == second.dependency_digest
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # `H8-1` is the selected trip, `H8-2` its unselected same-block peer on the
  # same calendar, `H12-1` another route's trip on that calendar, `H8-3` a second
  # selected trip on `SPECIAL`, and `H8-4` a listed trip of the target pattern
  # already leaving at 06:05:00 - the departure a +300 copy of `H8-1` would
  # take. Fixtures commit on their own connections, so the loader takes the
  # production snapshot boundary; each case removes exactly its organization.
  defp harbor_scope(supervisor) do
    harbor = in_task(supervisor, fn -> build_harbor_scope() end)
    commit_cleanup(harbor.organization_ids)
    harbor
  end

  defp build_harbor_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [
          {@central, "Central Station"},
          {@harbor, "Harbor Yards"},
          {@depot, "Depot Road"}
        ] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    route_fixture(organization.id, version.id, %{route_id: "H12"})

    weekday_calendar = calendar_fixture(organization.id, version.id, weekday("WEEKDAY"))
    special_calendar = calendar_fixture(organization.id, version.id, weekday("SPECIAL"))

    # A third calendar no selected trip runs on, so `H8-4` is a version trip
    # the plan reads and does not touch.
    calendar_fixture(organization.id, version.id, weekday("OFFPEAK"))

    for service_id <- ["WEEKDAY", "SPECIAL"] do
      calendar_date_fixture(organization.id, version.id, %{
        service_id: service_id,
        date: @holiday,
        exception_type: 2
      })
    end

    pattern_id = "HP1"

    selected =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-1",
        route_id: "H8",
        service_id: "WEEKDAY",
        block_id: "B1",
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "06:00:00"}, {@harbor, 2, "06:15:00"}]
      })

    peer =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-2",
        route_id: "H8",
        service_id: "WEEKDAY",
        block_id: "B1",
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "06:05:00"}, {@harbor, 2, "06:20:00"}]
      })

    second =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-3",
        route_id: "H8",
        service_id: "SPECIAL",
        block_id: nil,
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "07:00:00"}, {@depot, 2, "07:15:00"}]
      })

    other =
      service_trip(organization.id, version.id, %{
        trip_id: "H12-1",
        route_id: "H12",
        service_id: "WEEKDAY",
        block_id: nil,
        route_pattern_id: "HP12",
        stops: [{@central, 1, "08:00:00"}, {@harbor, 2, "08:15:00"}]
      })

    collide =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-4",
        route_id: "H8",
        service_id: "OFFPEAK",
        block_id: nil,
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "06:05:00"}, {@harbor, 2, "06:20:00"}]
      })

    Repo.insert!(%BlockAttribute{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      service_id: "WEEKDAY",
      block_id: "B1"
    })

    Repo.insert!(%BlockingSetting{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      min_layover_minutes: 5
    })

    Repo.insert!(%RouteOperatingSetting{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      route_id: "H8"
    })

    # One rule of each type 0..5. Types 4 and 5 are the in-seat rules, which
    # name two trips and no route pair; the rest name stops, and type 2 carries
    # its minimum time. All six are dependencies of the version.
    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @central,
      to_stop_id: @harbor,
      transfer_type: 0
    })

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @harbor,
      to_stop_id: @depot,
      transfer_type: 1
    })

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @depot,
      to_stop_id: @central,
      transfer_type: 2,
      min_transfer_time: 300
    })

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @central,
      to_stop_id: @depot,
      from_trip_id: "H8-3",
      to_trip_id: "H8-4",
      transfer_type: 3,
      min_transfer_time: 120
    })

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @harbor,
      to_stop_id: @depot,
      from_trip_id: "H8-2",
      to_trip_id: "H8-3",
      transfer_type: 4
    })

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @depot,
      to_stop_id: @central,
      from_trip_id: "H8-1",
      to_trip_id: "H8-2",
      transfer_type: 5
    })

    for trip <- [selected, peer] do
      Repo.insert!(%TripRun{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        trip_id: trip.id,
        day_type_key: "WEEKDAY",
        run_id: "R1"
      })
    end

    user = user_fixture()
    organization_membership_fixture(user, organization)

    %{
      organization: organization,
      version: version,
      route: route,
      pattern_id: pattern_id,
      weekday_calendar: weekday_calendar,
      special_calendar: special_calendar,
      selected: selected,
      peer: peer,
      second: second,
      other: other,
      collide: collide,
      user: user,
      organization_ids: [organization.id],
      scope: scope(organization, version, route, user)
    }
  end

  defp service_trip(organization_id, version_id, attrs) do
    stops = Map.fetch!(attrs, :stops)
    trip_id = Map.fetch!(attrs, :trip_id)

    trip =
      trip_fixture(organization_id, version_id, Map.fetch!(attrs, :route_id), %{
        trip_id: trip_id,
        service_id: Map.fetch!(attrs, :service_id),
        block_id: Map.get(attrs, :block_id),
        route_pattern_id: Map.get(attrs, :route_pattern_id)
      })

    for {stop_id, sequence, time} <- stops do
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end

    trip
  end

  defp weekday(service_id) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    }
  end

  defp scope(organization, version, route, user) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "service_queries",
      version_name: version.name,
      resource_context: Scope.context({:route, route.id})
    }
  end

  defp accept(selected) do
    {:ok, draft} =
      DatedChangePlan.normalize_intent(
        %{
          "first_date" => Date.to_iso8601(@first),
          "last_date" => Date.to_iso8601(@last),
          "delta_seconds" => "+300",
          "approval_note" => "Approved for the winter timetable review.",
          "source_label" => "Winter review"
        },
        selected
      )

    DatedChangePlan.accept_intent(draft, selected)
  end

  # -- native review state ----------------------------------------------------

  # The review state the native planners read, built by hand from the fixture's
  # own rows rather than through the native loader, so the oracle stays a
  # separate statement about the same data.
  defp review_state(harbor) do
    %{
      route: harbor.route,
      trips: %{
        harbor.selected.id =>
          trip_entry(harbor.selected, "WEEKDAY", "B1", "06:00:00", "06:15:00"),
        harbor.peer.id => trip_entry(harbor.peer, "WEEKDAY", "B1", "06:05:00", "06:20:00"),
        harbor.second.id => trip_entry(harbor.second, "SPECIAL", nil, "07:00:00", "07:15:00"),
        harbor.other.id => trip_entry(harbor.other, "WEEKDAY", nil, "08:00:00", "08:15:00"),
        harbor.collide.id => trip_entry(harbor.collide, "SPECIAL", nil, "06:05:00", "06:20:00")
      },
      patterns: %{},
      calendars: %{},
      service_dates: %{
        "WEEKDAY" => service_dates(),
        "SPECIAL" => service_dates(),
        "OFFPEAK" => service_dates()
      },
      pattern_trips: %{},
      existing_trip_ids: existing_trip_ids(harbor),
      block_inputs: nil
    }
  end

  defp trip_entry(trip, service_id, block_id, first, last) do
    %{
      trip: %{
        trip_id: trip.trip_id,
        route_id: trip.route_id,
        service_id: service_id,
        block_id: block_id,
        route_pattern_id: "HP1",
        timed_pattern_id: nil,
        pattern_derivation_state: "custom",
        trip_short_name: nil
      },
      stop_times: [stop_time(1, first), stop_time(2, last)],
      frequencies: []
    }
  end

  defp stop_time(sequence, departure_time) do
    %{
      id: sequence,
      stop_id: if(sequence == 1, do: @central, else: @harbor),
      stop_sequence: sequence,
      arrival_time: departure_time,
      departure_time: departure_time
    }
  end

  # The 260 weekdays of 2026 the fixture's calendars run, less the removed
  # 2026-11-11, written out rather than derived from the module under test.
  defp service_dates do
    ~D[2026-01-01]
    |> Date.range(~D[2026-12-31])
    |> Enum.filter(&(Date.day_of_week(&1) <= 5))
    |> Enum.reject(&(&1 == @holiday))
  end

  defp existing_trip_ids(harbor) do
    Repo.all(
      from(t in Trip,
        where:
          t.organization_id == ^harbor.organization.id and
            t.gtfs_version_id == ^harbor.version.id,
        select: t.trip_id
      )
    )
  end

  # The Copy shared-date warning, read from the same planner over the same
  # state, is the only date-aware thing Copy says - and it is a warning about
  # two calendars sharing dates, not a duplicate check with date lineage.
  defp change_set_trip_change(harbor, state) do
    {:ok, change_set} =
      TripChanges.plan({:copy, [harbor.selected.id], "SPECIAL", 300, true}, state)

    change_set.consequences
  end

  # -- assertions and content -------------------------------------------------

  defp stage(report, kind) do
    Enum.find(report.execution_stages, &(&1.kind == kind))
  end

  defp transfer(rows, type) do
    Enum.find(rows.transfers, &(&1.transfer_type == type))
  end

  defp dates(dates), do: Enum.map(dates, &Date.to_iso8601/1)

  # Every entity row this plan could touch, plus every audit row, as sorted
  # content. Comparing two of these byte-for-byte is what "the report changed
  # nothing" means here: not equal counts, but equal values.
  defp scoped_content(harbor) do
    organization_id = harbor.organization.id

    %{
      trips:
        content(Trip, organization_id, [:id, :trip_id, :service_id, :block_id, :route_pattern_id]),
      stop_times:
        content(StopTime, organization_id, [
          :id,
          :trip_id,
          :stop_id,
          :stop_sequence,
          :arrival_time,
          :departure_time
        ]),
      frequencies:
        content(Frequency, organization_id, [:id, :trip_id, :start_time, :end_time, :headway_secs]),
      calendars: content(Calendar, organization_id, [:id, :service_id, :start_date, :end_date]),
      calendar_dates:
        content(CalendarDate, organization_id, [:id, :service_id, :date, :exception_type]),
      block_attributes:
        content(BlockAttribute, organization_id, [:id, :block_id, :service_id, :garage_id]),
      blocking_settings:
        content(BlockingSetting, organization_id, [:id, :min_layover_minutes, :interlining]),
      route_operating_settings:
        content(RouteOperatingSetting, organization_id, [:id, :route_id, :garage_id]),
      transfers:
        content(Transfer, organization_id, [
          :id,
          :from_stop_id,
          :to_stop_id,
          :from_route_id,
          :to_route_id,
          :from_trip_id,
          :to_trip_id,
          :transfer_type,
          :min_transfer_time
        ]),
      trip_runs: content(TripRun, organization_id, [:id, :trip_id, :day_type_key, :run_id]),
      audit: audit_content(organization_id)
    }
  end

  # The rows are read whole and projected here rather than in the query: the
  # comparison is about values, and a projection the database builds would be a
  # second thing under test.
  defp content(queryable, organization_id, fields) do
    queryable
    |> where([row], row.organization_id == ^organization_id)
    |> Repo.all()
    |> Enum.map(&Map.take(&1, fields))
    |> Enum.sort_by(&inspect/1)
    |> Enum.map(&inspect/1)
  end

  defp audit_content(organization_id) do
    ChangeLog
    |> where([row], row.organization_id == ^organization_id)
    |> select(
      [row],
      {row.entity_type, row.entity_id, row.entity_external_id, row.action, row.snapshot,
       row.changed_fields}
    )
    |> Repo.all()
    |> Enum.map(&inspect/1)
    |> Enum.sort()
  end

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(@task_timeout)
  end

  # `on_exit` runs after the test process has exited, so a `start_supervised!/1`
  # supervisor is already dead here; the cleanup owns its own unboxed
  # connection, as `stations/stop_levels_test.exs` does.
  defp commit_cleanup(organization_ids) do
    on_exit(fn ->
      ConcurrencyHelpers.unboxed(fn ->
        ConcurrencyHelpers.delete_committed_members!(organization_ids)
        ConcurrencyHelpers.delete_committed_scope!(organization_ids)
      end)
    end)
  end
end

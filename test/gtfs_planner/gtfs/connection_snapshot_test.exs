defmodule GtfsPlanner.Gtfs.ConnectionSnapshotTest do
  @moduledoc """
  Merge evidence (EV-6) for `ConnectionComparison.load/3`: the exact endpoint
  occurrences, the native service/minimum evidence and the single read-only
  snapshot they come from.

  Every expectation is hand-derived from the acceptance cases and the GTFS
  reference, not from a second invocation of the module under test:

    * 09:02 arrives at the loop's first visit to `CENTRAL-P1` and 09:08 leaves
      `HARBOR`; a stored type 2 rule naming the parent station covers the
      platform and states a 300 second minimum. 09:02 is 32,520 service-day
      seconds and 09:08 is 32,880.
    * The trip calls `CENTRAL-P1` twice, so `stop_sequence` 1 and
      `stop_sequence` 5 are different occurrences of the same stop. Only the
      requested one is loaded, and a sequence the trip does not call is an
      absent occurrence, not a guess at the nearest one.
    * `EXCEPTION` is exception-only: it has no weekly row and adds exactly this
      Thursday, so the whole service on this date comes from that one exception.
      `DAILY` adds the next day instead, so the second endpoint's own
      `service_date_offset` decides which of the two its trip runs on.
    * The R2 coverage expansion is what lets a rule naming the parent station
      apply to the platform, and the best-ranked applicable rule is the one that
      decides: a trip-specific type 2 outranks the broad one, a type 3 prohibits
      even beside an explicit supplied minimum, and two equal-best rules with
      differing effects stay unresolved.

  The interleaving case runs the production snapshot boundary on its own
  committing connection, so the writer's committed change - the minimum and the
  calendar exception together - is wholly invisible or wholly visible to the
  rows, the minimum, the totals and the digest.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ConnectionComparison
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @collect_timeout 10_000
  @pause_timeout 30_000
  @race_handler {__MODULE__, :connection_snapshot_race}

  # 2026-11-26 is a Thursday, so the exception-only calendar that adds exactly
  # this one date is the whole service on it, and 2026-11-27 is the next civil
  # date an offset of one names.
  @service_date ~D[2026-11-26]
  @next_date ~D[2026-11-27]
  @station "CENTRAL"
  @platform "CENTRAL-P1"
  @harbor "HARBOR"
  @arrival_trip "R1-0902"
  @departure_trip "R2-0908"
  @next_day_trip "R2-2350"
  @old_minimum 300
  @new_minimum 900

  # `start_supervised!` rather than a linked `Task.Supervisor.start_link/0`: a
  # linked supervisor is already shutting down by the time `on_exit` runs, so
  # stopping it there races and fails the test for a reason of its own.
  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "load/3 exact occurrences (AC-6, AC-8)" do
    test "loads the requested occurrence of each approved endpoint from one snapshot" do
      scope = connection_scope()

      assert {:ok, snapshot} = load(scope, [pair("p1", scope)], @service_date)

      assert snapshot.scope == %{
               organization_id: scope.organization_id,
               gtfs_version_id: scope.gtfs_version_id
             }

      assert snapshot.service_date == @service_date
      assert snapshot.approved_route_ids == ["R1", "R2"]
      assert snapshot.digest =~ ~r/\A[0-9a-f]{64}\z/

      assert [row] = snapshot.rows
      assert row.id == "p1"
      assert row.reason == nil

      # The from endpoint resolves to the trip's first visit to the platform,
      # not to the route's other stop and not to the loop's second visit.
      assert row.from.side == :from
      assert row.from.route == "R1"
      assert row.from.route_id == scope.from_route.id
      assert row.from.trip == @arrival_trip
      assert row.from.stop_id == @platform
      assert row.from.stop_sequence == 1
      assert row.from.trip_on_route? == true
      assert row.from.occurrence_found? == true
      assert row.from.arrival_secs == secs("09:02:00")
      assert row.from.arrival_time == "09:02:00"

      # The to endpoint is the exact departure occurrence, and neither clock is
      # normalized against a 24-hour day.
      assert row.to.side == :to
      assert row.to.route == "R2"
      assert row.to.trip == @departure_trip
      assert row.to.stop_id == @harbor
      assert row.to.departure_secs == secs("09:08:00")
      assert row.to.departure_time == "09:08:00"

      # Service comes from the exception-only calendar, and the zone is the
      # route agency's own.
      assert row.from.service_id == "EXCEPTION"
      assert row.from.service_active? == true
      assert row.from.service_reason == nil
      assert row.from.timezone == "America/New_York"
      assert row.from.zone_reason == nil
      assert row.to.timezone == "America/New_York"

      assert snapshot.totals == %{
               requested: 1,
               endpoints: 2,
               resolved_rows: 1,
               unresolved_rows: 0,
               resolved_minimum: 1,
               prohibited_minimum: 0,
               conflicting_minimum: 0,
               absent_minimum: 0
             }
    end

    test "keeps each endpoint on its own civil date and reports an absent service" do
      scope = connection_scope()

      next_day = pair("p1", scope, to_trip: scope.next_day_trip, to_offset: 1)

      assert {:ok, snapshot} = load(scope, [next_day], @service_date)
      row = row(snapshot, "p1")

      # The second endpoint's own civil date is the Thursday plus its own
      # offset, so `DAILY`'s Friday addition is what makes it active.
      assert row.to.civil_date == @next_date
      assert row.to.service_date_offset == 1
      assert row.to.service_id == "DAILY"
      assert row.to.service_active? == true
      assert row.from.civil_date == @service_date
      assert row.from.service_date_offset == 0
      assert row.reason == nil
      assert snapshot.totals.resolved_rows == 1

      # The same trip on the requested date's basis has no service at all, which
      # is a classified row, never a silent zero.
      same_date = pair("p2", scope, to_trip: scope.next_day_trip)

      assert {:ok, snapshot} = load(scope, [same_date], @service_date)
      absent = row(snapshot, "p2")

      assert absent.to.civil_date == @service_date
      assert absent.to.service_active? == false
      assert absent.reason == :no_recorded_service
      assert snapshot.totals.unresolved_rows == 1
      assert snapshot.totals.resolved_rows == 0
    end

    test "loads the loop's other occurrence and reports an absent one" do
      scope = connection_scope()

      assert {:ok, later} = load(scope, [pair("later", scope, from_sequence: 5)], @service_date)
      assert row(later, "later").from.stop_sequence == 5
      assert row(later, "later").from.arrival_secs == secs("09:52:00")

      # A sequence the trip does not call is an absent occurrence. The pair is
      # still classified, and the stored minimum beside it is still the stored
      # minimum.
      assert {:ok, absent} = load(scope, [pair("absent", scope, from_sequence: 9)], @service_date)
      missing = row(absent, "absent")

      assert missing.from.occurrence_found? == false
      assert missing.from.arrival_secs == nil
      assert missing.reason == :occurrence_not_found
      assert missing.minimum.status == :resolved
      assert missing.minimum.seconds == @old_minimum
    end

    test "reports an endpoint whose recorded clock cannot be read" do
      scope = connection_scope()

      unreadable =
        timed_trip(scope.organization_id, scope.gtfs_version_id, "R2", "R2-BLANK", "EXCEPTION", [
          {@harbor, 4, nil}
        ])

      assert {:ok, snapshot} =
               load(
                 scope,
                 [pair("p1", scope, to_trip: unreadable, to_sequence: 4)],
                 @service_date
               )

      assert row(snapshot, "p1").to.departure_secs == nil
      assert row(snapshot, "p1").reason == :unknown_departure_time
    end

    test "refuses a third route, a foreign reference and a trip that is not on its route" do
      scope = connection_scope()

      third = route_fixture(scope.organization_id, scope.gtfs_version_id, %{route_id: "R3"})

      third_trip =
        trip_fixture(scope.organization_id, scope.gtfs_version_id, "R3", %{
          trip_id: "R3-1",
          service_id: "EXCEPTION"
        })

      assert {:error, :too_many} =
               load(
                 scope,
                 [pair("p1", scope), pair("p2", scope, to_route: third, to_trip: third_trip)],
                 @service_date
               )

      # A route of the other organization is created in that organization's
      # own version, so its UUID cannot resolve inside this scope.
      foreign_route =
        route_fixture(scope.foreign_organization.id, scope.foreign_version.id, %{route_id: "R1"})

      assert {:error, :not_found} =
               load(scope, [pair("p1", scope, from_route: foreign_route)], @service_date)

      # A trip of another organization is not this version's trip.
      assert {:error, :not_found} =
               load(scope, [pair("p1", scope, from_trip: scope.foreign_trip)], @service_date)

      # A trip that does not run on the route the pair names is a mismatch, not
      # a connection between the two.
      assert {:error, :not_found} =
               load(scope, [pair("p1", scope, from_route: scope.to_route)], @service_date)
    end

    test "refuses malformed and over-limit requests before it reads" do
      scope = connection_scope()
      base = pair("p1", scope)

      assert {:error, :invalid_input} = load(scope, [base, %{base | id: "p1"}], @service_date)

      assert {:error, :invalid_input} =
               load(scope, [put_in(base, [:from, :service_date_offset], -1)], @service_date)

      assert {:error, :invalid_input} =
               load(scope, [put_in(base, [:from, :stop_id], "")], @service_date)

      assert {:error, :invalid_input} =
               load(scope, [put_in(base, [:from, :trip_id], "not-a-uuid")], @service_date)

      # An endpoint this module will not read whole is a malformed value.
      partial =
        base
        |> Map.delete(:from)
        |> Map.merge(%{
          from: Map.delete(base.from, :service_date_offset)
        })

      assert {:error, :invalid_input} = load(scope, [partial], @service_date)

      assert {:error, :invalid_input} =
               load(
                 scope,
                 [Map.put(base, :minimum, %{origin: :supplied, seconds: -1})],
                 @service_date
               )

      assert {:error, :invalid_input} = load(scope, [base], "2026-11-26")
      assert {:error, :invalid_input} = load(scope, :pairs, @service_date)

      assert {:error, :invalid_input} =
               load(%{scope | organization_id: "not-a-uuid"}, [base], @service_date)

      over_limit =
        for index <- 1..(ConnectionComparison.pair_limit() + 1), do: %{base | id: "p#{index}"}

      assert {:error, :too_many} = load(scope, over_limit, @service_date)

      # The refusals read nothing and wrote nothing.
      assert audit_count(scope) == 0
      assert row_counts(scope) == seeded_counts()
    end
  end

  describe "load/3 minimum resolution (AC-9)" do
    test "a best-ranked type 2 supplies the stored minimum with its row provenance" do
      scope = connection_scope()

      assert {:ok, snapshot} = load(scope, [pair("p1", scope)], @service_date)
      stored = row(snapshot, "p1").minimum

      assert stored.origin == :stored
      assert stored.seconds == @old_minimum
      assert stored.status == :resolved
      assert stored.supplied == nil
      assert stored.provenance.kind == :stored_best
      assert stored.provenance.transfer_type == 2
      assert stored.provenance.min_transfer_time == @old_minimum
      assert stored.provenance.transfer_id == scope.stored_transfer.id
      assert stored.provenance.rank == 6
      assert stored.provenance.rule_ids == [scope.stored_transfer.id]
      assert %DateTime{} = stored.provenance.revision

      # A trip-specific rule outranks the broad one, so the specific minimum is
      # the one that decides.
      specific = connection_scope(specific_minimum: 600)

      assert {:ok, snapshot} = load(specific, [pair("p1", specific)], @service_date)
      ranked = row(snapshot, "p1").minimum

      assert ranked.seconds == 600
      assert ranked.provenance.rank == 3
      assert ranked.provenance.transfer_id == scope_transfer_id(specific, @arrival_trip)
    end

    test "a supplied minimum never replaces a stored one" do
      scope = connection_scope()

      supplied =
        pair("p1", scope,
          minimum: %{origin: :supplied, seconds: 120, approval: "shift lead 9:00"}
        )

      assert {:ok, snapshot} = load(scope, [supplied], @service_date)
      minimum = row(snapshot, "p1").minimum

      assert minimum.origin == :stored
      assert minimum.seconds == @old_minimum
      assert minimum.supplied == %{seconds: 120, approval: "shift lead 9:00"}
    end

    test "type 3 prohibits even beside a supplied minimum" do
      scope = connection_scope(policy: :type3)

      assert {:ok, snapshot} = load(scope, [pair("p1", scope)], @service_date)
      prohibited = row(snapshot, "p1").minimum

      assert prohibited.status == :prohibited
      assert prohibited.seconds == nil
      assert prohibited.provenance.kind == :stored_best
      assert prohibited.provenance.reason == :prohibited_by_best_rule
      assert prohibited.provenance.transfer_type == 3

      supplied =
        pair("p2", scope, minimum: %{origin: :supplied, seconds: 120, approval: "approved"})

      assert {:ok, snapshot} = load(scope, [supplied], @service_date)
      refused = row(snapshot, "p2").minimum

      # The supplied number is reported, and it does not erase the prohibition.
      assert refused.status == :prohibited
      assert refused.seconds == nil
      assert refused.supplied == %{seconds: 120, approval: "approved"}
    end

    test "equal-best rules with differing effects stay unresolved" do
      scope = connection_scope(policy: :conflicting)

      assert {:ok, snapshot} = load(scope, [pair("p1", scope)], @service_date)
      conflicting = row(snapshot, "p1").minimum

      assert conflicting.status == :conflicting
      assert conflicting.seconds == nil
      assert conflicting.provenance.kind == :stored_best
      assert conflicting.provenance.reason == :conflicting_best_rules
      assert conflicting.provenance.rank == 3
      assert length(conflicting.provenance.rule_ids) == 2

      assert Enum.map(conflicting.provenance.effects, & &1.min_transfer_time) |> Enum.sort() ==
               [240, 300]

      assert Enum.all?(conflicting.provenance.effects, &(&1.transfer_type == 2))

      supplied =
        pair("p2", scope, minimum: %{origin: :supplied, seconds: 120, approval: "approved"})

      assert {:ok, snapshot} = load(scope, [supplied], @service_date)
      refused = row(snapshot, "p2").minimum

      assert refused.status == :conflicting
      assert refused.seconds == nil
      assert refused.supplied == %{seconds: 120, approval: "approved"}
    end

    test "a version with no applicable rule leaves the minimum absent until one is supplied" do
      scope = connection_scope(policy: :none)

      assert {:ok, snapshot} = load(scope, [pair("p1", scope)], @service_date)

      assert row(snapshot, "p1").minimum.status == :absent
      assert row(snapshot, "p1").minimum.seconds == nil
      assert row(snapshot, "p1").minimum.provenance.kind == :no_applicable_rule
      assert snapshot.totals.absent_minimum == 1
      assert snapshot.totals.resolved_minimum == 0

      supplied =
        pair("p2", scope, minimum: %{origin: :supplied, seconds: 120, approval: "dispatch"})

      assert {:ok, snapshot} = load(scope, [supplied], @service_date)
      answered = row(snapshot, "p2").minimum

      assert answered.origin == :supplied
      assert answered.seconds == 120
      assert answered.status == :resolved
      assert answered.provenance.kind == :no_applicable_rule
      assert answered.supplied == %{seconds: 120, approval: "dispatch"}
    end

    test "a rule naming a stop this pair does not serve does not apply to it" do
      scope = connection_scope(policy: :none)

      elsewhere =
        stop_fixture(scope.organization_id, scope.gtfs_version_id, %{stop_id: "ELSEWHERE"})

      transfer_fixture(scope.organization_id, scope.gtfs_version_id, %{
        from_stop_id: elsewhere.stop_id,
        to_stop_id: @harbor,
        transfer_type: 2,
        min_transfer_time: 900
      })

      assert {:ok, snapshot} = load(scope, [pair("p1", scope)], @service_date)
      assert row(snapshot, "p1").minimum.status == :absent
      assert row(snapshot, "p1").minimum.provenance.kind == :no_applicable_rule
    end
  end

  describe "load/3 snapshot boundary (AC-6)" do
    test "reads a writer's change committed after its first query wholly from the old state", %{
      supervisor: supervisor
    } do
      scope = in_task(supervisor, fn -> connection_scope() end)
      on_exit(fn -> cleanup(scope) end)

      seeded = row_counts(scope)
      request = [pair("p1", scope)]
      parent = self()

      use_production_snapshot()

      assert {:ok, before_change} =
               in_task(supervisor, fn -> load(scope, request, @service_date) end)

      reader = start_worker(fn -> pause_then_read(scope, request, parent) end)

      assert_receive {:reader_ready, reader_pid}, @collect_timeout

      # The reader pauses inside its repeatable-read transaction, after it has
      # read the trips and before it reads the stored policy and the calendars.
      pause_after_trip_read(parent, reader_pid)
      send(reader_pid, :start_read)
      assert_receive {:reader_paused, ^reader_pid}, @collect_timeout

      assert :ok = in_task(supervisor, fn -> move_service_to_the_next_day(scope) end)
      send(reader_pid, :resume_query)

      assert {:ok, during_change} = await_worker(reader)

      # The writer committed the stored minimum and the calendar exception
      # together after the reader's first query. A repeatable-read snapshot is taken
      # at that first query, so the reader finishes on the old state throughout;
      # a reader that took a fresh snapshot per statement would see the writer's
      # commit on the policy and calendar reads it makes after the pause.
      assert old_state?(before_change)
      assert old_state?(during_change)
      assert during_change.digest == before_change.digest

      assert {:ok, after_change} =
               in_task(supervisor, fn -> load(scope, request, @service_date) end)

      # Wholly after the commit: the Thursday has no service and the new stored
      # minimum is the one that applies.
      assert new_state?(after_change)
      refute old_state?(after_change)

      assert [%{reason: :no_recorded_service, minimum: %{seconds: @new_minimum}}] =
               after_change.rows

      assert during_change.digest != after_change.digest

      # The queries read only: the only changed rows are the writer's own.
      assert row_counts(scope) == seeded
      assert audit_count(scope) == 0
    end

    test "the ordinary default path uses the production boundary outside a sandbox", %{
      supervisor: supervisor
    } do
      scope = in_task(supervisor, fn -> connection_scope() end)
      on_exit(fn -> cleanup(scope) end)

      previous = Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot)
      on_exit(fn -> restore_snapshot_module(previous) end)
      Application.delete_env(:gtfs_planner, :gtfs_service_query_snapshot)

      # With nothing configured, the production adapter is the entry point.
      assert Snapshot.module() == Snapshot.Repo

      assert {:ok, snapshot} =
               in_task(supervisor, fn -> load(scope, [pair("p1", scope)], @service_date) end)

      assert [%{reason: nil, minimum: %{seconds: @old_minimum}}] = snapshot.rows
      assert snapshot.totals.resolved_rows == 1
    end

    test "an enclosing sandbox case reads through the configured no-op boundary" do
      # The SQL sandbox already holds an open transaction, so the configured
      # boundary is the no-op one and this case's uncommitted rows are visible.
      assert Snapshot.module() == Snapshot.Sandbox

      scope = connection_scope()

      assert {:ok, snapshot} = load(scope, [pair("p1", scope)], @service_date)
      assert [%{reason: nil}] = snapshot.rows

      # The sandbox rolls this case's own rows back.
      assert audit_count(scope) == 0
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # Two expressly approved routes. `EXCEPTION` has no weekly row and adds only
  # the reviewed Thursday; `DAILY` adds the next day instead, so the second
  # endpoint's own offset decides which one its trip runs on. The arrival trip
  # calls the platform twice, and the transfer policy names the parent station,
  # so its R2 coverage is what lets it apply to the platform.
  defp connection_scope(opts \\ []) do
    organization = organization_fixture(%{alias: unique_alias()})
    version = gtfs_version_fixture(organization.id)

    agency_fixture(organization.id, version.id, %{
      agency_id: "CONN",
      agency_timezone: "America/New_York"
    })

    from_route = route_fixture(organization.id, version.id, %{route_id: "R1", agency_id: "CONN"})
    to_route = route_fixture(organization.id, version.id, %{route_id: "R2", agency_id: "CONN"})

    station_fixture(organization.id, version.id, @station)
    child_stop_fixture(organization.id, version.id, @station, %{stop_id: @platform})
    stop_fixture(organization.id, version.id, %{stop_id: @harbor})

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "EXCEPTION",
      date: @service_date,
      exception_type: 1
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "DAILY",
      date: @next_date,
      exception_type: 1
    })

    arrival_trip =
      timed_trip(organization.id, version.id, "R1", @arrival_trip, "EXCEPTION", [
        {@platform, 1, "09:02:00"},
        {@platform, 5, "09:52:00"}
      ])

    departure_trip =
      timed_trip(organization.id, version.id, "R2", @departure_trip, "EXCEPTION", [
        {@harbor, 2, "09:08:00"}
      ])

    next_day_trip =
      timed_trip(organization.id, version.id, "R2", @next_day_trip, "DAILY", [
        {@harbor, 2, "23:50:00"}
      ])

    stored_transfer = seed_policy(organization.id, version.id, opts)

    # A second organization's own version: its trips are never this scope's,
    # and no fixture of it can satisfy a reference the scope made.
    foreign_organization = organization_fixture(%{alias: unique_alias()})
    foreign_version = gtfs_version_fixture(foreign_organization.id)

    foreign_trip =
      trip_fixture(foreign_organization.id, foreign_version.id, "R1", %{
        trip_id: @arrival_trip,
        service_id: "EXCEPTION"
      })

    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      organization: organization,
      foreign_organization: foreign_organization,
      version: version,
      foreign_version: foreign_version,
      from_route: from_route,
      to_route: to_route,
      arrival_trip: arrival_trip,
      departure_trip: departure_trip,
      next_day_trip: next_day_trip,
      stored_transfer: stored_transfer,
      foreign_trip: foreign_trip
    }
  end

  # `System.unique_integer/0` restarts with the VM, so an organization this file
  # commits and later deletes can collide with an earlier run's leftovers. The
  # alias carries a per-run token instead.
  defp unique_alias, do: "conn-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp station_fixture(organization_id, version_id, stop_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Central Station",
      location_type: 1
    })
  end

  defp timed_trip(organization_id, version_id, route_id, trip_id, service_id, stops) do
    trip =
      trip_fixture(organization_id, version_id, route_id, %{
        trip_id: trip_id,
        service_id: service_id,
        direction_id: 0
      })

    Enum.each(stops, fn {stop_id, sequence, time} ->
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end)

    trip
  end

  defp seed_policy(organization_id, version_id, opts) do
    case Keyword.get(opts, :policy, :type2) do
      :none ->
        nil

      :type3 ->
        transfer_fixture(organization_id, version_id, %{
          from_stop_id: @station,
          to_stop_id: @harbor,
          transfer_type: 3
        })

      # Two equally specific rules - one naming the arrival trip, the other the
      # departure trip - that both rank 3 and state different minima. The
      # version's unique rule key accepts them because neither selector repeats.
      :conflicting ->
        transfer_fixture(organization_id, version_id, %{
          from_stop_id: @station,
          to_stop_id: @harbor,
          from_trip_id: @arrival_trip,
          transfer_type: 2,
          min_transfer_time: 240
        })

        transfer_fixture(organization_id, version_id, %{
          from_stop_id: @station,
          to_stop_id: @harbor,
          to_trip_id: @departure_trip,
          transfer_type: 2,
          min_transfer_time: @old_minimum
        })

      :type2 ->
        stored =
          transfer_fixture(organization_id, version_id, %{
            from_stop_id: @station,
            to_stop_id: @harbor,
            transfer_type: 2,
            min_transfer_time: @old_minimum
          })

        case Keyword.get(opts, :specific_minimum) do
          nil ->
            stored

          seconds ->
            transfer_fixture(organization_id, version_id, %{
              from_stop_id: @station,
              to_stop_id: @harbor,
              from_trip_id: @arrival_trip,
              transfer_type: 2,
              min_transfer_time: seconds
            })
        end
    end
  end

  defp scope_transfer_id(scope, trip_id) do
    from(t in Transfer,
      where:
        t.organization_id == ^scope.organization_id and
          t.gtfs_version_id == ^scope.gtfs_version_id and t.from_trip_id == ^trip_id
    )
    |> Repo.one!()
    |> Map.fetch!(:id)
  end

  defp pair(id, scope, opts \\ []) do
    %{
      id: id,
      from:
        endpoint(
          Keyword.get(opts, :from_route, scope.from_route),
          Keyword.get(opts, :from_trip, scope.arrival_trip),
          Keyword.get(opts, :from_stop, @platform),
          Keyword.get(opts, :from_sequence, 1),
          Keyword.get(opts, :from_offset, 0)
        ),
      to:
        endpoint(
          Keyword.get(opts, :to_route, scope.to_route),
          Keyword.get(opts, :to_trip, scope.departure_trip),
          Keyword.get(opts, :to_stop, @harbor),
          Keyword.get(opts, :to_sequence, 2),
          Keyword.get(opts, :to_offset, 0)
        ),
      minimum: Keyword.get(opts, :minimum, %{origin: :stored})
    }
  end

  defp endpoint(route, trip, stop_id, sequence, offset) do
    %{
      route_id: route.id,
      trip_id: trip.id,
      stop_id: stop_id,
      stop_sequence: sequence,
      service_date_offset: offset
    }
  end

  # -- calls ------------------------------------------------------------------

  defp load(scope, pairs, service_date),
    do: ConnectionComparison.load(scope, pairs, service_date)

  defp row(snapshot, id), do: Enum.find(snapshot.rows, &(&1.id == id))

  defp secs(clock) do
    {:ok, value} = GtfsTime.parse(clock)
    value
  end

  # The one state each read describes. Coherence is what FH-6 denies: a row
  # cannot carry the old minimum with the removed exception, or the new minimum
  # with the exception still in place.
  defp old_state?(%{rows: [row]}),
    do: row.reason == nil and row.minimum.seconds == @old_minimum

  defp new_state?(%{rows: [row]}),
    do: row.reason == :no_recorded_service and row.minimum.seconds == @new_minimum

  defp seeded_counts do
    %{transfers: 1, trips: 3, stop_times: 4, calendar_dates: 2}
  end

  defp row_counts(scope) do
    %{
      transfers:
        Repo.aggregate(
          from(t in Transfer, where: t.organization_id == ^scope.organization_id),
          :count
        ),
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^scope.organization_id),
          :count
        ),
      stop_times:
        Repo.aggregate(
          from(s in StopTime, where: s.organization_id == ^scope.organization_id),
          :count
        ),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^scope.organization_id),
          :count
        )
    }
  end

  defp audit_count(scope) do
    Repo.aggregate(
      from(l in ChangeLog, where: l.organization_id == ^scope.organization_id),
      :count
    )
  end

  # -- snapshot plumbing ------------------------------------------------------

  # The reader runs the production entrypoint on its own committing connection,
  # so `SET TRANSACTION ISOLATION LEVEL` applies and the pause happens inside the
  # snapshot rather than inside the test's rolled-back transaction.
  defp pause_then_read(scope, pairs, parent) do
    send(parent, {:reader_ready, self()})

    receive do
      :start_read -> :ok
    end

    unboxed(fn -> load(scope, pairs, @service_date) end)
  end

  # Every worker runs on its own committing connection through an unlinked
  # spawn, so a rendezvous pause in one worker cannot take a supervisor down.
  defp start_worker(fun) do
    parent = self()
    spawn_monitor(fn -> send(parent, {:done, self(), unboxed(fun)}) end)
  end

  defp await_worker({pid, ref}) do
    receive do
      {:done, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("load worker failed: #{inspect(reason)}")
    after
      @collect_timeout ->
        flunk("load worker timed out")
    end
  end

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> unboxed(fun) end)
    |> Task.await(@collect_timeout)
  end

  # `SET TRANSACTION ISOLATION LEVEL` only applies at the top of a transaction,
  # so the production boundary needs a connection that holds no enclosing
  # transaction. The adapter is selected here, in the test process, so its
  # restore belongs to this test's `on_exit` and survives a killed worker.
  defp use_production_snapshot do
    previous = Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot)
    on_exit(fn -> restore_snapshot_module(previous) end)

    Application.put_env(:gtfs_planner, :gtfs_service_query_snapshot, Snapshot.Repo)
  end

  defp restore_snapshot_module(nil),
    do: Application.delete_env(:gtfs_planner, :gtfs_service_query_snapshot)

  defp restore_snapshot_module(previous),
    do: Application.put_env(:gtfs_planner, :gtfs_service_query_snapshot, previous)

  defp pause_after_trip_read(parent, reader_pid) do
    :telemetry.attach(
      @race_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, reader} ->
        if self() == reader and String.contains?(to_string(metadata[:query]), ~s(FROM "trips")) do
          :telemetry.detach(@race_handler)
          send(owner, {:reader_paused, self()})

          receive do
            :resume_query -> :ok
          after
            @pause_timeout -> :ok
          end
        end
      end,
      {parent, reader_pid}
    )

    on_exit(fn -> :telemetry.detach(@race_handler) end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # The writer commits both halves of one change together: the exception-only
  # service for the reviewed Thursday is removed and the stored minimum moves to
  # 900. A repeatable-read reader cannot see one without the other.
  defp move_service_to_the_next_day(scope) do
    Repo.transaction(fn ->
      {1, _returned} =
        Repo.update_all(
          from(d in CalendarDate,
            where:
              d.organization_id == ^scope.organization_id and
                d.gtfs_version_id == ^scope.gtfs_version_id and
                d.service_id == "EXCEPTION" and d.date == ^@service_date
          ),
          set: [exception_type: 2]
        )

      {1, _returned} =
        Repo.update_all(
          from(t in Transfer,
            where:
              t.organization_id == ^scope.organization_id and
                t.gtfs_version_id == ^scope.gtfs_version_id
          ),
          set: [min_transfer_time: @new_minimum]
        )

      :ok
    end)

    :ok
  end

  # Unboxed cases commit, so this package's own fixtures are deleted explicitly.
  defp cleanup(scope) do
    unboxed(fn ->
      organization_ids = [scope.organization_id, scope.foreign_organization.id]

      Repo.delete_all(from(f in Frequency, where: f.organization_id in ^organization_ids))
      Repo.delete_all(from(s in StopTime, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Trip, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(t in Transfer, where: t.organization_id in ^organization_ids))
      Repo.delete_all(from(d in CalendarDate, where: d.organization_id in ^organization_ids))
      Repo.delete_all(from(c in Calendar, where: c.organization_id in ^organization_ids))
      Repo.delete_all(from(l in Level, where: l.organization_id in ^organization_ids))
      Repo.delete_all(from(s in Stop, where: s.organization_id in ^organization_ids))
      Repo.delete_all(from(r in Route, where: r.organization_id in ^organization_ids))
      Repo.delete_all(from(a in Agency, where: a.organization_id in ^organization_ids))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      Repo.delete_all(from(o in Organization, where: o.id in ^organization_ids))

      refute Repo.exists?(from(t in Trip, where: t.organization_id in ^organization_ids))
      refute Repo.exists?(from(v in GtfsVersion, where: v.organization_id in ^organization_ids))
      refute Repo.exists?(from(o in Organization, where: o.id in ^organization_ids))
      :ok
    end)
  end
end

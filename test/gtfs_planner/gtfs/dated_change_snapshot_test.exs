defmodule GtfsPlanner.Gtfs.DatedChangeSnapshotTest do
  @moduledoc """
  Merge evidence (EV-2) for `DatedChangePlan.load/2`: one reauthorized scoped
  read-only repeatable-read snapshot, a content digest that survives no
  same-count substitution, the refusals, and truthful cap and deadline
  incompleteness.

  Every expectation is hand-derived from the acceptance cases and the GTFS
  Schedule reference, not from a second invocation of the module under test:

    * `H8-1` and `H8-2` are the selected route's trips on `WEEKDAY`, whose
      weekly range is 2026-01-01..2026-12-31 and which loses 2026-11-11 to a
      `calendar_dates` removal. `H12-1` is a trip of another route on the same
      calendar, so a read scoped to the selection alone would hide the shared
      user a plan has to preserve.
    * A version read is not a selection read: the snapshot carries all three
      trips, both routes, every stop time, the frequency window, the block
      attribute of block `B1`, the version's blocking settings and operating
      setting, every version transfer rule and the trip's run assignment.
    * A digest that hashed counts would survive replacing one `H8-2` headsign
      with a different string, or one transfer's `min_transfer_time` with a
      different number, or moving the 2026-11-11 removal to 2026-11-12, because
      none of those changes a row count. The digest is over sorted complete
      field content, so all three change it.
    * A selection naming another route's trip, another organization's trip, or
      no trip of this route is one refusal, and so is a scope bound to no
      route. Revoked editor membership is refused before any scoped read.
    * A cancelled statement is the read deadline, not a complete answer.

  ## What the SQL sandbox does not establish

  Fixtures here commit on their own connections, so the interleaving case runs
  the production `REPEATABLE READ READ ONLY` boundary. An ordinary case that
  runs inside the test's rolled-back transaction takes the sandbox's no-op
  boundary instead: it proves the loader's own reads, projections and refusals,
  and it proves nothing about concurrent visibility. Only the case that names
  the production adapter and an independent committing writer can reject a
  loader that read its sources in separate transactions.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.ConcurrencyHelpers
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DatedChangePlan
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo

  # 2026-11-11 is the removed weekday service date the plan protects.
  @holiday ~D[2026-11-11]
  @moved_holiday ~D[2026-11-12]
  @central "CENTRAL"
  @harbor "HARBOR"
  @read_timeout_env :gtfs_dated_change_read_timeout_ms
  @pause_handler {__MODULE__, :pause_after_calendars}
  @collect_timeout 10_000
  @pause_timeout 30_000

  setup do
    {:ok, supervisor: start_supervised!({Task.Supervisor, []})}
  end

  describe "load/2 completeness (AC-3)" do
    test "reads every applicable dependency of the scoped version, not only the selection", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      assert {:ok, snapshot} = load(harbor, accepted)

      # The route identity the scope names, resolved under this organization.
      assert snapshot.scope.organization_id == harbor.organization.id
      assert snapshot.scope.gtfs_version_id == harbor.version.id
      assert snapshot.scope.route_id == "H8"
      assert snapshot.selected_trip_ids == [harbor.trip.id]
      assert snapshot.input_digest == accepted.input_digest

      # The whole version, so the shared-calendar user of another route is
      # visible instead of disappearing from the plan.
      assert imported_trip_ids(snapshot) == ["H12-1", "H8-1", "H8-2"]
      assert Enum.map(snapshot.calendars, & &1.service_id) == ["WEEKDAY"]

      assert [%{service_id: "WEEKDAY", date: @holiday, exception_type: 2}] =
               snapshot.calendar_dates

      assert length(snapshot.stop_times) == 6

      assert [
               %{
                 trip_id: "H8-1",
                 start_time: "06:00:00",
                 end_time: "08:00:00",
                 headway_secs: 1200
               }
             ] = snapshot.frequencies

      assert Enum.map(snapshot.routes, & &1.route_id) |> Enum.sort() == ["H12", "H8"]
      assert [%{block_id: "B1", service_id: "WEEKDAY"}] = snapshot.block_attributes
      assert [%{min_layover_minutes: 5}] = snapshot.blocking_settings
      assert [%{route_id: "H8"}] = snapshot.route_operating_settings
      assert length(snapshot.transfers) == 2
      assert [%{day_type_key: "WEEKDAY", run_id: "R1"}] = snapshot.trip_runs

      # Nothing here has a pattern or a timing, and the loader says so rather
      # than inventing a row.
      assert snapshot.route_patterns == []
      assert snapshot.route_pattern_stops == []
      assert snapshot.timed_patterns == []
      assert snapshot.timed_pattern_stops == []

      # The read changes no source row and writes no audit row.
      assert row_count(harbor) == harbor.seeded
      assert audit_count(harbor) == harbor.seeded_audit
    end
  end

  describe "load/2 isolation (AC-3, AC-4)" do
    test "reads a controlled writer's committed change wholly before or wholly after", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)
      {:ok, before_change} = load(harbor, accepted)

      use_production_snapshot()

      parent = self()

      {reader, _ref} =
        spawn_monitor(fn ->
          send(parent, {:done, self(), paused_reader(harbor, accepted, parent)})
        end)

      # The reader is parked before it opens its transaction, so the pause hook
      # is attached in time to catch the calendars read.
      receive do
        {:reader_ready, ^reader} -> :ok
      after
        @collect_timeout -> flunk("the reader never started")
      end

      # The reader pauses inside its repeatable-read transaction, after it has
      # read the calendars and before it reads the exception and the transfers.
      pause_after_calendars(parent, reader)
      send(reader, :start_read)

      receive do
        {:paused, ^reader} -> :ok
      after
        @collect_timeout -> flunk("the reader never reached the calendars read")
      end

      # The writer commits from its own autocommit connection. Running it in
      # this test process would execute inside the sandbox transaction, roll
      # back, and prove nothing about a committed interleaving.
      assert :ok = unboxed(fn -> commit_interleaving_writer(harbor) end)
      send(reader, :resume)

      assert {:ok, during} = await(reader)

      # Wholly before the commit: the exception and the transfer are the ones
      # this transaction read, so the digest describes that whole state.
      assert during.calendar_dates == before_change.calendar_dates
      assert during.transfers == before_change.transfers
      assert during.dependency_digest == before_change.dependency_digest

      # Wholly after the commit: a fresh read sees both changes, and never one
      # of each.
      assert {:ok, after_change} = unboxed(fn -> DatedChangePlan.load(harbor.scope, accepted) end)

      assert after_change.calendar_dates
             |> Enum.map(&Map.take(&1, [:service_id, :date, :exception_type])) ==
               [%{service_id: "WEEKDAY", date: @holiday, exception_type: 1}]

      refute after_change.transfers == during.transfers
      refute after_change.dependency_digest == during.dependency_digest
    end
  end

  describe "load/2 content digest (AC-4)" do
    test "changes for a same-count trip, transfer and exception substitution", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      assert {:ok, first} = load(harbor, accepted)

      # One trip's content changes; the trip count, the calendar count and the
      # exception count all stay exactly where they were.
      substitute_trip(harbor)

      assert {:ok, second} = load(harbor, accepted)
      assert length(second.trips) == length(first.trips)
      assert length(second.calendars) == length(first.calendars)
      assert length(second.calendar_dates) == length(first.calendar_dates)
      assert second.trips != first.trips
      refute second.dependency_digest == first.dependency_digest

      # One transfer's content changes; the transfer count is unchanged.
      substitute_transfer(harbor)

      assert {:ok, third} = load(harbor, accepted)
      assert length(third.transfers) == length(second.transfers)
      refute third.dependency_digest == second.dependency_digest

      # The exception date itself moves; the exception count is unchanged.
      move_exception(harbor)

      assert {:ok, fourth} = load(harbor, accepted)
      assert [%{date: @moved_holiday}] = fourth.calendar_dates
      refute fourth.dependency_digest == third.dependency_digest
    end

    test "is stable for the same content read twice", %{supervisor: supervisor} do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      assert {:ok, first} = load(harbor, accepted)
      assert {:ok, second} = load(harbor, accepted)

      assert second.dependency_digest == first.dependency_digest
      assert second.transfers == first.transfers
    end
  end

  describe "load/2 refusals (AC-3, AC-5)" do
    test "refuses a foreign, cross-route or unknown selection and a scope without its route", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      assert {:error, :not_found} = load(harbor, with_trips(accepted, [harbor.foreign_trip.id]))
      assert {:error, :not_found} = load(harbor, with_trips(accepted, [harbor.other_trip.id]))
      assert {:error, :not_found} = load(harbor, with_trips(accepted, [Ecto.UUID.generate()]))

      assert {:error, :not_found} =
               load(harbor, with_trips(accepted, [harbor.trip.id, harbor.other_trip.id]))

      version_scope = %{
        harbor.scope
        | resource_context: Scope.context({:version, harbor.version.id})
      }

      assert {:error, :not_found} = load(harbor, accepted, version_scope)

      unknown_route = %{
        harbor.scope
        | resource_context: Scope.context({:route, Ecto.UUID.generate()})
      }

      assert {:error, :not_found} = load(harbor, accepted, unknown_route)

      # A different version of this organization holds no such route.
      # A different version of this organization holds no such route. It is created
      # on its own committing connection so the case does not leave an
      # uncommitted row holding locks the committed-fixture cleanup needs.
      other_version = unboxed(fn -> gtfs_version_fixture(harbor.organization.id) end)

      assert {:error, :not_found} =
               load(harbor, accepted, %{harbor.scope | gtfs_version_id: other_version.id})

      # A scope that is not a scope, and an organization that is not this
      # scope's organization, are both forbidden.
      assert {:error, :forbidden} =
               load(harbor, accepted, %{organization_id: harbor.organization.id})

      assert {:error, :forbidden} = load(harbor, accepted, %{harbor.scope | organization_id: nil})
    end

    test "refuses a revoked editor before any scoped read", %{supervisor: supervisor} do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      revoke(harbor)
      assert {:error, :forbidden} = load(harbor, accepted)

      restore(harbor)
      assert {:ok, _snapshot} = load(harbor, accepted)
    end

    test "refuses a source that is not an accepted intent", %{supervisor: supervisor} do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               load(harbor, %{accepted | input_digest: String.duplicate("0", 64)})

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               load(harbor, Map.delete(accepted, :approval_note))

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               load(harbor, with_trips(accepted, [harbor.trip.id, harbor.trip.id]))

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               load(harbor, with_trips(accepted, []))

      assert {:error, {:incomplete, :invalid_accepted_source}} =
               load(harbor, %{accepted | trip_ids: ["not-a-uuid"]})
    end
  end

  describe "load/2 admission (AC-5)" do
    test "reports an over-cap selection as incomplete instead of a partial snapshot", %{
      supervisor: supervisor
    } do
      cap = cap_scope(supervisor)

      # 101 selected trips against a cap of 100: the `cap + 1` read is refused
      # before any of it is materialized.
      assert {:error, {:incomplete, {:row_cap_exceeded, :selected_trips, 100}}} =
               DatedChangePlan.load(cap.scope, cap.accepted)
    end

    test "reports a read that cannot finish inside its deadline as incomplete", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      use_read_timeout(300)
      use_production_snapshot()

      # Another connection holds the calendars the loader must read, so the read
      # blocks and PostgreSQL cancels it: a deadline, not a complete answer.
      assert {:error, {:incomplete, :statement_timeout}} =
               with_held_table_lock("calendars", fn ->
                 unboxed(fn -> DatedChangePlan.load(harbor.scope, accepted) end)
               end)

      # The same load without the lock still reads completely. The 300 ms
      # deadline above bounds how long a blocked read waits, not how long an
      # ordinary read of this version may take, so it is lifted for this half.
      use_read_timeout(60_000)

      assert {:ok, _snapshot} = unboxed(fn -> DatedChangePlan.load(harbor.scope, accepted) end)
    end

    test "reports calendar data the native date evaluator cannot read as incomplete", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      # A retained weekly range the changeset refuses, written as persisted
      # source: `ServiceDates.active_dates/2` would raise on it, so a complete D
      # cannot be computed from this read.
      insert_unreadable_calendar(harbor, "BROKEN")

      assert {:error, {:incomplete, {:unreadable_calendar, "BROKEN"}}} = load(harbor, accepted)
    end

    test "an ordinary sandboxed read proves the reads, not the isolation", %{
      supervisor: supervisor
    } do
      harbor = harbor_scope(supervisor)
      {:ok, accepted} = accept(harbor)

      # The sandbox boundary is a no-op, so this case deliberately establishes
      # nothing about concurrent visibility; the production-adapter case above
      # is the one that does.
      assert {:ok, snapshot} = load(harbor, accepted)
      assert imported_trip_ids(snapshot) == ["H12-1", "H8-1", "H8-2"]
    end
  end

  # -- fixtures ---------------------------------------------------------------

  # The Harbor Transit A02/A19 dataset: `H8` is the scoped route, `H12` shares
  # `WEEKDAY` and is never selected, and block `B1` carries both `H8` trips.
  defp harbor_scope(supervisor) do
    harbor = in_task(supervisor, fn -> build_harbor_scope() end)
    commit_cleanup(harbor.organization_ids)
    harbor
  end

  defp build_harbor_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [{@central, "Central Station"}, {@harbor, "Harbor Yards"}] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    route_fixture(organization.id, version.id, %{route_id: "H12"})

    calendar_fixture(
      organization.id,
      version.id,
      weekday_calendar("WEEKDAY", ~D[2026-01-01], ~D[2026-12-31])
    )

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      date: @holiday,
      exception_type: 2
    })

    trip = timed_trip(organization.id, version.id, "H8", "H8-1", "B1")
    timed_trip(organization.id, version.id, "H8", "H8-2", "B1")
    other_trip = timed_trip(organization.id, version.id, "H12", "H12-1", nil)

    frequency_fixture(organization.id, version.id, "H8-1", %{
      start_time: "06:00:00",
      end_time: "08:00:00",
      headway_secs: 1200,
      exact_times: 0
    })

    Repo.insert!(%BlockAttribute{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      service_id: "WEEKDAY",
      block_id: "B1"
    })

    Repo.insert!(%BlockingSetting{organization_id: organization.id, gtfs_version_id: version.id})

    Repo.insert!(%RouteOperatingSetting{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      route_id: "H8"
    })

    # A general rule and a trip-to-trip rule: every version transfer is a
    # conservative dependency, so both are read.
    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @central,
      to_stop_id: @harbor,
      transfer_type: 0
    })

    transfer_fixture(organization.id, version.id, %{
      from_stop_id: @harbor,
      to_stop_id: @central,
      from_trip_id: "H8-1",
      to_trip_id: "H8-2",
      transfer_type: 3,
      min_transfer_time: 120
    })

    Repo.insert!(%TripRun{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      trip_id: trip.id,
      day_type_key: "WEEKDAY",
      run_id: "R1"
    })

    user = user_fixture()
    organization_membership_fixture(user, organization)
    foreign = foreign_organization_trip()

    harbor = %{
      organization: organization,
      version: version,
      route: route,
      trip: trip,
      other_trip: other_trip,
      foreign_trip: foreign,
      user: user,
      organization_ids: [organization.id, foreign.organization_id]
    }

    Map.merge(harbor, %{
      scope: scope(organization, version, route, user),
      seeded: row_count(harbor),
      seeded_audit: audit_count(harbor)
    })
  end

  # The over-cap case needs 101 selectable trips of one route, so it gets its own
  # organization rather than inflating the fixture every other case reads.
  defp cap_scope(supervisor) do
    cap = in_task(supervisor, fn -> build_cap_scope() end)
    commit_cleanup(cap.organization_ids)
    cap
  end

  defp build_cap_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "H8"})

    trips =
      for index <- 1..101 do
        trip_fixture(organization.id, version.id, "H8", %{
          trip_id: "H8-#{index}",
          service_id: "WEEKDAY"
        })
      end

    user = user_fixture()
    organization_membership_fixture(user, organization)
    selected = trips |> Enum.map(& &1.id) |> Enum.take(100)

    {:ok, draft} = DatedChangePlan.normalize_intent(intent_params(), selected)
    {:ok, accepted} = DatedChangePlan.accept_intent(draft, selected)

    %{
      organization: organization,
      version: version,
      scope: scope(organization, version, route, user),
      organization_ids: [organization.id],
      accepted: with_trips(accepted, Enum.map(trips, & &1.id))
    }
  end

  defp foreign_organization_trip do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    trip_fixture(organization.id, version.id, "H8", %{trip_id: "H8-1", service_id: "WEEKDAY"})
  end

  # These cases commit their fixtures, so each one removes exactly the
  # organizations it created. `on_exit` runs after the test process has exited,
  # so the cleanup owns its own unboxed connection rather than borrowing the
  # `start_supervised!/1` supervisor, which is already dead by then.
  defp commit_cleanup(organization_ids) do
    on_exit(fn ->
      ConcurrencyHelpers.unboxed(fn ->
        ConcurrencyHelpers.delete_committed_members!(organization_ids)
        ConcurrencyHelpers.delete_committed_scope!(organization_ids)
      end)
    end)
  end

  defp timed_trip(organization_id, version_id, route_id, trip_id, block_id) do
    trip =
      trip_fixture(organization_id, version_id, route_id, %{
        trip_id: trip_id,
        service_id: "WEEKDAY",
        block_id: block_id
      })

    for {stop_id, sequence, time} <- [{@central, 1, "06:00:00"}, {@harbor, 2, "06:15:00"}] do
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end

    trip
  end

  defp weekday_calendar(service_id, first, last) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: first,
      end_date: last
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

  defp intent_params do
    %{
      "first_date" => "2026-11-02",
      "last_date" => "2026-11-13",
      "delta_seconds" => "+300",
      "approval_note" => "Approved for the winter timetable review.",
      "source_label" => "Winter review"
    }
  end

  defp accept(harbor) do
    {:ok, draft} = DatedChangePlan.normalize_intent(intent_params(), [harbor.trip.id])
    DatedChangePlan.accept_intent(draft, [harbor.trip.id])
  end

  # The digest is the module's own, because the subject here is `load/2`'s trust
  # in its source rather than the digest's derivation, which step 1's test pins
  # against a hand-derived literal.
  defp with_trips(accepted, trip_ids) do
    bound = accepted |> Map.delete(:input_digest) |> Map.put(:trip_ids, Enum.sort(trip_ids))
    Map.put(bound, :input_digest, DatedChangePlan.input_digest(bound))
  end

  # -- committed writers ------------------------------------------------------

  # Each of these writers commits from its own autocommit connection. A write
  # made in the test process would stay in the sandbox transaction until ExUnit
  # rolls it back, which is after `on_exit` runs, so it would hold row locks the
  # committed-fixture cleanup needs and it would never really commit.
  defp substitute_trip(harbor) do
    unboxed(fn ->
      Repo.update_all(
        from(t in Trip,
          where:
            t.organization_id == ^harbor.organization.id and
              t.gtfs_version_id == ^harbor.version.id and
              t.trip_id == "H8-2"
        ),
        set: [trip_headsign: "Harbor via Market"]
      )
    end)
  end

  defp substitute_transfer(harbor) do
    unboxed(fn ->
      Repo.update_all(
        from(x in Transfer,
          where:
            x.organization_id == ^harbor.organization.id and
              x.gtfs_version_id == ^harbor.version.id and
              x.from_trip_id == "H8-1"
        ),
        set: [min_transfer_time: 300]
      )
    end)
  end

  defp move_exception(harbor) do
    unboxed(fn ->
      Repo.update_all(
        from(d in CalendarDate,
          where:
            d.organization_id == ^harbor.organization.id and
              d.gtfs_version_id == ^harbor.version.id and
              d.service_id == "WEEKDAY"
        ),
        set: [date: @moved_holiday]
      )
    end)
  end

  defp commit_interleaving_writer(harbor) do
    {1, _returned} =
      Repo.update_all(
        from(d in CalendarDate,
          where:
            d.organization_id == ^harbor.organization.id and
              d.gtfs_version_id == ^harbor.version.id and
              d.service_id == "WEEKDAY"
        ),
        set: [exception_type: 1]
      )

    {1, _returned} =
      Repo.update_all(
        from(x in Transfer,
          where:
            x.organization_id == ^harbor.organization.id and
              x.gtfs_version_id == ^harbor.version.id and
              x.from_trip_id == "H8-1"
        ),
        set: [min_transfer_time: 300]
      )

    :ok
  end

  defp revoke(harbor) do
    unboxed(fn ->
      Repo.update_all(
        from(m in UserOrgMembership,
          where: m.user_id == ^harbor.user.id and m.organization_id == ^harbor.organization.id
        ),
        set: [deactivated_at: DateTime.utc_now()]
      )
    end)
  end

  defp restore(harbor) do
    unboxed(fn ->
      Repo.update_all(
        from(m in UserOrgMembership,
          where: m.user_id == ^harbor.user.id and m.organization_id == ^harbor.organization.id
        ),
        set: [deactivated_at: nil]
      )
    end)
  end

  # A reversed weekly range cannot be written through the changeset, so the row
  # is inserted as the persisted source it is.
  defp insert_unreadable_calendar(harbor, service_id) do
    unboxed(fn ->
      Repo.insert!(
        struct!(%Calendar{}, %{
          organization_id: harbor.organization.id,
          gtfs_version_id: harbor.version.id,
          service_id: service_id,
          monday: 1,
          tuesday: 0,
          wednesday: 0,
          thursday: 0,
          friday: 0,
          saturday: 0,
          sunday: 0,
          start_date: ~D[2026-12-31],
          end_date: ~D[2026-01-01]
        })
      )
    end)
  end

  # -- counts and snapshot plumbing ------------------------------------------

  defp imported_trip_ids(snapshot) do
    snapshot.trips |> Enum.map(& &1.trip_id) |> Enum.sort()
  end

  defp row_count(harbor) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^harbor.organization.id),
          :count
        ),
      transfers:
        Repo.aggregate(
          from(x in Transfer, where: x.organization_id == ^harbor.organization.id),
          :count
        ),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^harbor.organization.id),
          :count
        )
    }
  end

  defp audit_count(harbor) do
    Repo.aggregate(
      from(l in ChangeLog, where: l.organization_id == ^harbor.organization.id),
      :count
    )
  end

  # Every case runs the production entrypoint; only the adapter and the owning
  # connection differ between them.
  defp load(harbor, accepted, scope \\ nil),
    do: DatedChangePlan.load(scope || harbor.scope, accepted)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # The reader runs the production entrypoint on its own committing connection,
  # so `SET TRANSACTION ISOLATION LEVEL` applies and the pause happens inside
  # the snapshot rather than inside the test's rolled-back transaction.
  defp paused_reader(harbor, accepted, parent) do
    send(parent, {:reader_ready, self()})

    receive do
      :start_read -> :ok
    end

    unboxed(fn -> DatedChangePlan.load(harbor.scope, accepted) end)
  end

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> unboxed(fun) end)
    |> Task.await(@collect_timeout)
  end

  defp await(pid) do
    ref = Process.monitor(pid)

    receive do
      {:done, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("the load worker failed: #{inspect(reason)}")
    after
      @collect_timeout -> flunk("the load worker timed out")
    end
  end

  # `SET TRANSACTION ISOLATION LEVEL` applies only at the top of a transaction,
  # so the interleaving and deadline cases select the production boundary here,
  # in the test process, and restore it in this test's `on_exit`.
  defp use_production_snapshot do
    previous = Application.get_env(:gtfs_planner, :gtfs_service_query_snapshot)
    on_exit(fn -> Application.put_env(:gtfs_planner, :gtfs_service_query_snapshot, previous) end)

    Application.put_env(:gtfs_planner, :gtfs_service_query_snapshot, Snapshot.Repo)
  end

  defp use_read_timeout(milliseconds) do
    previous = Application.get_env(:gtfs_planner, @read_timeout_env)
    on_exit(fn -> Application.put_env(:gtfs_planner, @read_timeout_env, previous) end)

    Application.put_env(:gtfs_planner, @read_timeout_env, milliseconds)
  end

  defp pause_after_calendars(parent, reader) do
    :telemetry.attach(
      @pause_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == reader and
             String.contains?(to_string(metadata[:query]), ~s(FROM "calendars")) do
          :telemetry.detach(@pause_handler)
          send(parent, {:paused, self()})

          receive do
            :resume -> :ok
          after
            @pause_timeout -> :ok
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(@pause_handler) end)
  end

  # A real held lock, released in `after`, is what makes the deadline
  # deterministic: the read blocks and PostgreSQL cancels it, with no sleep.
  defp with_held_table_lock(table, fun) do
    parent = self()

    {holder, _ref} =
      spawn_monitor(fn ->
        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE #{table} IN ACCESS EXCLUSIVE MODE")
          send(parent, {:locked, self()})

          receive do
            :release -> :ok
          after
            @pause_timeout -> :ok
          end
        end)
      end)

    receive do
      {:locked, ^holder} -> :ok
    after
      @collect_timeout -> flunk("the table lock was never taken")
    end

    try do
      fun.()
    after
      send(holder, :release)
    end
  end
end

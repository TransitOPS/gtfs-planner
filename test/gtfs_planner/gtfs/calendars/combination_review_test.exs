defmodule GtfsPlanner.Gtfs.Calendars.CombinationReviewTest do
  @moduledoc """
  Step 14: the protected input set one calendar combination is reviewed and applied from.

  `Calendars.load_combination_inputs!/2` is the internal entrypoint steps 15 and 16 call
  inside their own ordinary read-committed `Repo.transaction/1`. These cases prove, against
  real scoped rows and the committed package-05 producer:

  - The closure starts at every selected trip and grows to every trip on a touched non-nil
    block across all services of the version, the type-4/5 records naming one of those trips,
    each record's counterpart trip and every trip on a counterpart's block, deduplicated by
    UUID, while an unrelated block stays out.
  - It returns the real `Blocking.Queries.trip_rows/3` shape - parsed endpoint clocks,
    frequency flag, stop refs with the parent-coordinate fallback - together with the raw rows
    a fingerprint binds: endpoint stop times, stops, parents, every frequency row, the settings
    row or its absence, the exact selected calendar rows and the version's agencies.
  - The read is batched: the query count does not grow with the number of trips.
  - Access is current and scoped: a foreign, unpublished or non-editor scope is refused, a
    revocation committed while the version lock is awaited is refused, and the internal
    boundary refuses an enclosing repeatable snapshot instead of claiming freshness.
  - A source writer that commits while the version lock is awaited is present in the loaded
    inputs even when its calendar had no trips when the wait began.

  Step 15 owns the public `Gtfs.review_calendar_change/3` dispatch and EV-4. The focused gate
  command `mix test test/gtfs_planner/gtfs/calendars/combination_review_test.exs` is deferred to
  branch review.
  """
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @query_event [:gtfs_planner, :repo, :query]
  @contention_timeout 10_000
  @collect_timeout 15_000
  @poll_interval 10

  # The selected destination and one moving source, both seeded by every fixture below.
  @command {:combine, "DEST", ["SAT"], %{}}

  setup do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R_COMBINE_REVIEW"})
    actor = user_fixture(%{email: "combination-review-#{unique()}@example.test"})
    organization_membership_fixture(actor, organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    %{
      supervisor: supervisor,
      organization: organization,
      version: version,
      route: route,
      actor: actor,
      audit: audit_for(organization.id, version.id, actor.id)
    }
  end

  describe "the loaded closure" do
    test "loads selected trips, touched-block companions and transfer counterparts once each",
         context do
      scope = seed_closure(context)

      assert {:ok, inputs} = load_inputs(context.audit, @command)

      assert trip_uuids(inputs) ==
               Enum.sort([
                 scope.trips.destination.id,
                 scope.trips.source.id,
                 scope.trips.companion.id,
                 scope.trips.counterpart.id,
                 scope.trips.block_mate.id
               ])

      # An untouched block and its calendar are outside the closure, and the selected set
      # names only the destination's and the source's own trips.
      refute scope.trips.unrelated.id in trip_uuids(inputs)

      assert inputs.selected_trip_ids ==
               Enum.sort([scope.trips.destination.id, scope.trips.source.id])

      # Two records name the source trip; one names an already-companion trip, so the
      # counterpart and the record are each present once (AC-14, AC-18).
      transfer_ids = Enum.map(inputs.transfers, & &1.id)

      assert Enum.sort(transfer_ids) ==
               Enum.sort([scope.transfers.to_counterpart.id, scope.transfers.to_companion.id])

      assert Enum.uniq(transfer_ids) == transfer_ids

      assert Enum.map(inputs.raw.transfers, & &1.id) == transfer_ids
    end

    test "returns real endpoint clocks, frequency rows and the parent-coordinate fallback",
         context do
      scope = seed_closure(context)

      assert {:ok, inputs} = load_inputs(context.audit, @command)

      source_row = trip_row(inputs, scope.trips.source.id)

      assert source_row.first_arrival == 9 * 3600 + 30 * 60
      assert source_row.last_arrival == 10 * 3600 + 30 * 60
      assert source_row.plottable?
      assert source_row.frequency?
      assert source_row.headway_secs == 900

      # A natural pattern reference is carried by the loaded rows, while one this version
      # does not hold has nothing to lock and is skipped rather than refused.
      assert source_row.route_pattern_id == scope.pattern.route_pattern_id

      assert Enum.find(inputs.raw.trips, &(&1.trip_id == "MID_T1")).route_pattern_id ==
               "PATTERN_MISSING"

      # The stop's own coordinates are absent and the parent station's are used instead,
      # while the raw stop and parent rows are both preserved for the fingerprint.
      assert source_row.first_stop.stop_id == "CHILD_REVIEW"
      assert source_row.first_stop.parent_station == "PARENT_REVIEW"
      assert source_row.first_stop.lat == 42.36
      assert source_row.first_stop.lon == -71.06

      assert stop_ids(inputs) |> Enum.member?("CHILD_REVIEW")
      assert parent_ids(inputs) == ["PARENT_REVIEW"]

      assert Enum.map(inputs.raw.frequencies, & &1.headway_secs) == [900, 1200]

      assert Enum.any?(
               inputs.raw.stop_times,
               &(&1.trip_id == "SAT_T1" and &1.stop_sequence == 1 and
                   &1.arrival_time == "09:30:00" and &1.departure_time == "09:30:00")
             )

      raw_trip = Enum.find(inputs.raw.trips, &(&1.id == scope.trips.source.id))
      assert raw_trip.trip_id == "SAT_T1"
      assert raw_trip.service_id == "SAT"
      assert raw_trip.block_id == "700"
      assert raw_trip.updated_at == scope.trips.source.updated_at
    end

    test "is the committed producer's input contract", context do
      scope = seed_closure(context)

      assert {:ok, inputs} = load_inputs(context.audit, @command)

      # The source moves onto the destination's dates, which include the companion's own day,
      # so the moved block gains a companion it did not have before and must be cleared; the
      # destination trip on its own block stays assigned.
      result =
        Blocking.project_calendar_combination(inputs, %{
          destination_id: "DEST",
          source_ids: ["SAT"],
          result_dates: [~D[2026-03-02], ~D[2026-03-07]]
        })

      assert result.cleared_trip_ids == [scope.trips.source.id]

      assert Enum.sort(Enum.map(result.transfers, & &1.id)) ==
               Enum.sort([scope.transfers.to_counterpart.id, scope.transfers.to_companion.id])
    end

    test "loads every calendar the closure uses and only the selected snapshots", context do
      seed_closure(context)

      assert {:ok, inputs} = load_inputs(context.audit, @command)

      # Every service a closure trip runs in, plus every selected ID; the unrelated
      # calendar is not part of the closure.
      assert Enum.map(inputs.calendars, & &1.service_id) |> Enum.sort() ==
               ["DEST", "HOL", "MID", "SAT", "SUN"]

      assert Map.keys(inputs.raw.selected_calendars) |> Enum.sort() == ["DEST", "SAT"]

      assert inputs.raw.selected_calendars["SAT"].trip_count == 1
      assert inputs.raw.selected_calendars["SAT"].calendar.service_id == "SAT"
      assert inputs.raw.selected_calendars["SAT"].exceptions == []
      assert is_struct(inputs.raw.selected_calendars["SAT"].attributes, CalendarAttribute)

      # No stored layover row: the real default is used and its absence is kept.
      assert inputs.raw.settings == []
      assert inputs.settings == %{min_layover_minutes: 5, absent?: true}

      assert Enum.map(inputs.raw.agencies, & &1.agency_timezone) == ["America/New_York"]
      assert is_struct(inputs.today, Date)
    end

    test "keeps a stored layover and its presence marker", context do
      seed_closure(context)

      assert {:ok, _setting} =
               Gtfs.update_blocking_settings(context.organization.id, context.version.id, %{
                 min_layover_minutes: 12
               })

      assert {:ok, inputs} = load_inputs(context.audit, @command)

      assert inputs.settings == %{min_layover_minutes: 12, absent?: false}
      assert Enum.map(inputs.raw.settings, & &1.min_layover_minutes) == [12]
      assert trip_uuids(inputs) != []
    end

    test "issues the same number of queries for a larger closure", context do
      seed_closure(context)

      {_first, base_queries} = count_queries(context.audit)

      extra_trip_ids =
        for index <- 1..4 do
          trip_fixture(context.organization.id, context.version.id, context.route.route_id, %{
            trip_id: "DEST_EXTRA_#{index}",
            service_id: "DEST"
          })
        end

      {inputs, expanded_queries} = count_queries(context.audit)

      assert length(extra_trip_ids) == 4
      assert expanded_queries == base_queries
      assert base_queries > 0

      assert MapSet.subset?(
               MapSet.new(Enum.map(extra_trip_ids, & &1.id)),
               MapSet.new(trip_uuids(inputs))
             )
    end

    test "refuses a foreign, unpublished or non-editor scope without loading data", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, staging_version} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      viewer = user_fixture(%{email: "combination-reviewer-#{unique()}@example.test"})
      organization_membership_fixture(viewer, context.organization, ["pathways_studio_admin"])

      assert {:error, :forbidden} =
               load_inputs(%{context.audit | actor_id: viewer.id}, @command)

      # A foreign organization cannot reach this version, and this organization cannot
      # reach another organization's version or its own unpublished staging scope.
      assert {:error, :not_found} =
               load_inputs(%{context.audit | organization_id: other_organization.id}, @command)

      assert {:error, :not_found} =
               load_inputs(%{context.audit | gtfs_version_id: other_version.id}, @command)

      assert {:error, :not_found} =
               load_inputs(
                 audit_for(context.organization.id, staging_version.id, context.actor.id),
                 @command
               )
    end

    test "refuses an enclosing repeatable snapshot", context do
      # The configured SERIALIZABLE apply adapter is not this command's transaction: a
      # combination loaded inside it would keep its pre-wait snapshot after the version
      # lock, so the internal boundary refuses it (critique M1).
      assert {:error, {:unsupported_isolation, "serializable"}} =
               unboxed(fn ->
                 ReviewedApplyTransaction.Repo.run(fn ->
                   Calendars.load_combination_inputs!(@command, context.audit)
                 end)
               end)
    end
  end

  describe "the protected version wait" do
    test "sees a trip a writer committed while the version lock was awaited",
         %{supervisor: supervisor} do
      scope = unboxed(fn -> seed_committed_scope("late-writer") end)
      on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

      # The source calendar starts with no trips at all.
      assert source_trip_ids(scope) == []

      writer = start_trip_writer(supervisor, scope)
      loader = start_loader(supervisor, scope)

      assert_blocked_by(loader.backend, writer.backend)

      send(writer.task.pid, :commit)

      assert {:ok, created_trip_id} = Task.await(writer.task, @collect_timeout)
      assert {:ok, inputs} = Task.await(loader.task, @collect_timeout)

      # The load acquired the exclusive version lock only after the writer committed, so
      # the trip it inserted is part of the reviewed closure (AC-15).
      assert created_trip_id in trip_uuids(inputs)
      assert created_trip_id in inputs.selected_trip_ids
      assert Enum.map(inputs.raw.trips, & &1.trip_id) |> Enum.member?("LATE_SAT_T1")
    end

    test "refuses a membership revoked while the version lock was awaited",
         %{supervisor: supervisor} do
      scope = unboxed(fn -> seed_committed_scope("revoked") end)
      on_exit(fn -> unboxed(fn -> cleanup(scope) end) end)

      holder = hold_exclusive_version(supervisor, scope)
      loader = start_loader(supervisor, scope)

      assert_blocked_by(loader.backend, holder.backend)

      # The revocation commits while the loader waits on the version row, and the loader
      # re-resolves the membership after it acquires the lock (AC-13).
      unboxed(fn ->
        from(m in UserOrgMembership, where: m.id == ^scope.membership_id)
        |> Repo.one()
        |> deactivate_membership_fixture()
      end)

      send(holder.task.pid, :release)
      assert {:error, :released} = Task.await(holder.task, @collect_timeout)
      assert {:error, :forbidden} = Task.await(loader.task, @collect_timeout)
    end
  end

  # --- fixtures -------------------------------------------------------------

  # Destination and source plus one non-selected companion on the touched block, one
  # type-4/5 counterpart on its own block with a block mate, and an unrelated trip whose
  # block and calendar must stay outside the closure.
  defp seed_closure(context) do
    {organization_id, version_id} = {context.organization.id, context.version.id}
    route_id = context.route.route_id

    destination = calendar_service_fixture(organization_id, version_id, %{service_id: "DEST"})

    source =
      calendar_service_fixture(organization_id, version_id, %{
        service_id: "SAT",
        saturday: 1,
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        sunday: 0,
        start_date: ~D[2026-03-01],
        end_date: ~D[2026-03-31]
      })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "MID",
      dates: [~D[2026-03-09]]
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "SUN",
      dates: [~D[2026-03-08]]
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "HOL",
      dates: [~D[2026-03-10]]
    })

    calendar_service_fixture(organization_id, version_id, %{
      service_id: "OTHER",
      dates: [~D[2026-03-11]]
    })

    parent =
      stop_fixture(organization_id, version_id, %{
        stop_id: "PARENT_REVIEW",
        location_type: 1,
        stop_lat: Decimal.new("42.36"),
        stop_lon: Decimal.new("-71.06")
      })

    # A stop with a parent station requires a level, so the geometry fallback is exercised
    # through exactly the stop changeset the application accepts.
    level =
      level_fixture(organization_id, version_id, %{
        level_id: "LEVEL_REVIEW",
        level_name: "Street",
        level_index: 0.0
      })

    child =
      stop_fixture(organization_id, version_id, %{
        stop_id: "CHILD_REVIEW",
        stop_lat: nil,
        stop_lon: nil,
        parent_station: parent.stop_id,
        level_id: level.id
      })

    pattern =
      route_pattern_fixture(organization_id, version_id, %{
        route_id: route_id,
        route_pattern_id: "PATTERN_REVIEW"
      })

    trips = %{
      destination:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "DEST_T1",
          service_id: destination.service_id,
          block_id: "701",
          first_arrival: "08:00:00",
          last_arrival: "09:00:00"
        }),
      source:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "SAT_T1",
          service_id: source.service_id,
          block_id: "700",
          first_arrival: "09:30:00",
          last_arrival: "10:30:00",
          first_stop: child.stop_id
        }),
      companion:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "MID_T1",
          service_id: "MID",
          block_id: "700",
          first_arrival: "11:00:00",
          last_arrival: "12:00:00"
        }),
      counterpart:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "SUN_T1",
          service_id: "SUN",
          block_id: "800",
          first_arrival: "13:00:00",
          last_arrival: "14:00:00"
        }),
      block_mate:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "HOL_T1",
          service_id: "HOL",
          block_id: "800",
          first_arrival: "13:30:00",
          last_arrival: "14:30:00"
        }),
      unrelated:
        blocked_trip_fixture(organization_id, version_id, route_id, %{
          trip_id: "OTHER_T1",
          service_id: "OTHER",
          block_id: "900",
          first_arrival: "15:00:00",
          last_arrival: "16:00:00"
        })
    }

    # The trip changeset does not cast pattern classification, so the fixture helper writes it
    # the way the application does: a real natural reference for the source and one this
    # version does not hold for the companion.
    trips = %{
      trips
      | source:
          trip_pattern_metadata_fixture(trips.source, %{
            route_pattern_id: pattern.route_pattern_id
          }),
        companion:
          trip_pattern_metadata_fixture(trips.companion, %{route_pattern_id: "PATTERN_MISSING"})
    }

    # Two frequency windows on the source trip: the projection uses the smallest headway,
    # while the fingerprint has to carry both rows.
    frequency_row_fixture(organization_id, version_id, %{
      trip_id: "SAT_T1",
      start_time: "06:00:00",
      end_time: "09:00:00",
      headway_secs: 900
    })

    frequency_row_fixture(organization_id, version_id, %{
      trip_id: "SAT_T1",
      start_time: "09:00:00",
      end_time: "12:00:00",
      headway_secs: 1200
    })

    transfers = %{
      to_counterpart:
        in_seat_transfer_fixture(
          organization_id,
          version_id,
          trips.source,
          trips.counterpart
        ),
      to_companion:
        in_seat_transfer_fixture(organization_id, version_id, trips.source, trips.companion)
    }

    %{trips: trips, transfers: transfers, pattern: pattern}
  end

  defp seed_committed_scope(suffix) do
    unique = "#{System.system_time(:millisecond)}-#{unique()}"
    organization = organization_fixture(%{alias: "combination-review-#{suffix}-#{unique}"})
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R_#{unique}"})
    actor = user_fixture(%{email: "combination-review-#{unique}@example.test"})
    membership = organization_membership_fixture(actor, organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    calendar_service_fixture(organization.id, version.id, %{service_id: "DEST"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SAT",
      dates: [~D[2026-03-07]]
    })

    %{
      organization_id: organization.id,
      version_id: version.id,
      actor_id: actor.id,
      membership_id: membership.id,
      route_id: route.route_id,
      audit: audit_for(organization.id, version.id, actor.id)
    }
  end

  defp source_trip_ids(scope) do
    unboxed(fn ->
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization_id and t.gtfs_version_id == ^scope.version_id and
            t.service_id == "SAT",
        select: t.id
      )
      |> Repo.all()
    end)
  end

  defp unique, do: System.unique_integer([:positive])

  defp audit_for(organization_id, version_id, actor_id) do
    %AuditContext{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      station_stop_id: nil,
      actor_id: actor_id,
      actor_email: "combination-review@example.test"
    }
  end

  # --- assertions -----------------------------------------------------------

  defp load_inputs(audit, command) do
    Repo.transaction(fn -> Calendars.load_combination_inputs!(command, audit) end)
  end

  defp trip_uuids(inputs), do: inputs.trips |> Enum.map(& &1.id) |> Enum.sort()

  defp trip_row(inputs, id), do: Enum.find(inputs.trips, &(&1.id == id))

  defp stop_ids(inputs), do: Enum.map(inputs.raw.stops, & &1.stop_id)

  defp parent_ids(inputs), do: Enum.map(inputs.raw.parents, & &1.stop_id)

  # Counts the queries one protected load issues by observing the repo's own telemetry, so
  # a second measurement over a larger closure can reject a per-trip read.
  defp count_queries(audit) do
    test_pid = self()
    ref = make_ref()
    handler = {__MODULE__, ref, :queries}

    :telemetry.attach(
      handler,
      @query_event,
      fn _event, _measurements, _metadata, pid -> send(pid, {:query, ref}) end,
      test_pid
    )

    try do
      {:ok, inputs} = load_inputs(audit, @command)
      {inputs, drain_queries(ref, 0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_queries(ref, count) do
    receive do
      {:query, ^ref} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end

  # --- contention helpers ---------------------------------------------------

  defp hold_exclusive_version(supervisor, scope) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> hold_version(scope, parent) end)

    assert_receive {:held, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  defp hold_version(scope, parent) do
    unboxed(fn -> Repo.transaction(fn -> lock_version_until_released(scope, parent) end) end)
  end

  defp lock_version_until_released(scope, parent) do
    Repo.one(
      from(v in GtfsVersion,
        where: v.id == ^scope.version_id and v.organization_id == ^scope.organization_id,
        lock: "FOR UPDATE"
      )
    )

    send(parent, {:held, self(), backend_pid()})

    receive do
      :release -> Repo.rollback(:released)
    end
  end

  defp start_loader(supervisor, scope) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> await_release(scope, parent) end)

    assert_receive {:loader_ready, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    send(task.pid, :go)
    %{task: task, backend: backend}
  end

  defp await_release(scope, parent) do
    unboxed(fn ->
      backend = backend_pid()
      send(parent, {:loader_ready, self(), backend})

      receive do
        :go -> :ok
      end

      Repo.transaction(fn -> Calendars.load_combination_inputs!(@command, scope.audit) end)
    end)
  end

  defp start_trip_writer(supervisor, scope) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> write_late_trip(scope, parent) end)

    assert_receive {:writer_locked, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  # The direct trip writer's own order: the scoped version row `FOR SHARE` first, then the
  # insert through the real `Gtfs.create_trip/1` path, committed by this transaction.
  defp write_late_trip(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Versions.lock_for_input_write!(scope.organization_id, scope.version_id)
        send(parent, {:writer_locked, self(), backend_pid()})

        receive do
          :commit -> :ok
        end

        created_trip_id!(scope)
      end)
    end)
  end

  defp created_trip_id!(scope) do
    {:ok, trip} =
      Gtfs.create_trip(%{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.version_id,
        route_id: scope.route_id,
        trip_id: "LATE_SAT_T1",
        service_id: "SAT"
      })

    trip.id
  end

  defp assert_blocked_by(backend, holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout

    case unboxed(fn -> await_blocker(backend, holder_backend, deadline) end) do
      :ok ->
        :ok

      {:error, blocked_by} ->
        flunk(
          "expected backend #{backend} to wait on #{holder_backend}, saw #{inspect(blocked_by)}"
        )
    end
  end

  defp await_blocker(backend, holder_backend, deadline) do
    blocked_by = blockers_of(backend)

    cond do
      holder_backend in blocked_by ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, blocked_by}

      true ->
        Process.sleep(@poll_interval)
        await_blocker(backend, holder_backend, deadline)
    end
  end

  defp blockers_of(backend) do
    %Postgrex.Result{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend])
    List.wrap(blockers)
  end

  defp backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  # --- cleanup --------------------------------------------------------------

  # `async: false` with unboxed committing connections means the committed fixtures are not
  # rolled back, so the scope this case created is deleted explicitly.
  defp cleanup(scope) do
    organization_id = scope.organization_id

    Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
    Repo.delete_all(from(t in Transfer, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
    Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
    Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id == ^organization_id))
    Repo.delete_all(from(d in CalendarDate, where: d.organization_id == ^organization_id))
    Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
    Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
    Repo.delete_all(from(a in Agency, where: a.organization_id == ^organization_id))

    Repo.delete_all(
      from(m in UserOrgMembership,
        where: m.organization_id == ^organization_id or m.user_id == ^scope.actor_id
      )
    )

    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(u in User, where: u.id == ^scope.actor_id))
    Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))

    :ok
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end

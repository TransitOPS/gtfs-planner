defmodule GtfsPlanner.Gtfs.Calendars.CombinationResourcesTest do
  @moduledoc """
  Isolated scale evidence for the calendar list and one reviewed combination (step 21, EV-6,
  CL-6, AC-25/AC-26).

  The list half reads the ordinary `Gtfs.load_calendar_screen/3` through the production
  `CatalogReadAdapter.Repo`: a 100-identity version and a five-identity version of the same
  shapes must issue the same number of queries, which is AC-25's "queries are batched by entity
  family" at the sourced 100-calendar size. The measured read time is printed as an observation;
  the two-second route budget is asserted by the browser journey, which is the route.

  The combination half measures one reviewed apply through the public
  `Gtfs.apply_calendar_change/3` on real committing connections, at 612, 1,000 and 2,000
  equivalent moving trips, with the same calendar shapes at every size. Each size records the
  whole transaction duration, the version-lock window observed from a second connection with
  `... FOR UPDATE NOWAIT` polling, the persisted audit metadata bytes (`pg_column_size` and the
  serialized JSON length of `change_logs.changed_fields`), the final row and audit counts, and
  that exactly one real log hosts the complete membership envelope. Metadata must grow linearly:
  doubling the uniform fixture may grow the persisted bytes at most 2.2 times (AC-26, critique
  M3), and no 500-trip cap may refuse the 612-trip operation.

  No production latency SLA is asserted for the combination: the elapsed values are the recorded
  measurement, and only the linear-growth bound and the completeness facts are asserted. Every
  case is `async: false`; the combination fixtures commit on their own connections like the
  step-16 contention cases, so each organization scope is deleted explicitly.

  The focused gate command
  `MIX_ENV=test MIX_TEST_PARTITION=_calendar17 mix test test/gtfs_planner/gtfs/calendars/combination_resources_test.exs`
  is EV-6's ExUnit half and is also included in the EV-9 suite.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
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
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @query_event [:gtfs_planner, :repo, :query]

  # The measured combination sizes, in ascending order: 612 proves the operation is not capped at
  # 500 trips, and 1,000 and 2,000 are the uniform pair whose metadata growth must stay linear.
  @sizes [612, 1_000, 2_000]

  # The destination holds a small fixed trip set at every size, so the two uniform fixtures differ
  # only in their moving trip count.
  @destination_trips 3

  @lock_poll_interval 2
  @ready_timeout 60_000
  @lock_timeout 120_000
  @collect_timeout 300_000

  @moduletag timeout: 600_000

  @command {:combine, "DEST", ["SAT"], %{}}

  describe "the hundred-calendar screen read" do
    test "issues the same batched query count for 100 identities as for five and records the read" do
      organization = organization_fixture()

      large_version = screen_version(organization.id, 100)
      small_version = screen_version(organization.id, 5)

      {large_screen, large_ms, large_queries} =
        measure_queries(fn -> Gtfs.load_calendar_screen(organization.id, large_version.id) end)

      {small_screen, small_ms, small_queries} =
        measure_queries(fn -> Gtfs.load_calendar_screen(organization.id, small_version.id) end)

      assert {:ok, screen} = large_screen
      assert {:ok, small} = small_screen
      assert length(screen.rows) == 100
      assert length(small.rows) == 5
      assert screen.horizon.first_date < screen.horizon.last_date

      line =
        "EV-6: screen_rows=#{length(screen.rows)} small_screen_rows=#{length(small.rows)} " <>
          "queries=#{large_queries} small_queries=#{small_queries} " <>
          "read_ms=#{large_ms} small_read_ms=#{small_ms}"

      IO.puts(line)

      # Batched by entity family: the query count does not grow with the number of identities.
      assert large_queries == small_queries
      assert large_queries > 0
      # A per-identity read would issue at least one query per row.
      assert large_queries < 20
    end
  end

  describe "the reviewed combination at 612, 1000 and 2000 trips" do
    test "moves every trip once and grows the persisted operation metadata linearly" do
      supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})

      measurements =
        for size <- @sizes do
          scope = unboxed(fn -> seed_combine_scope(size) end)

          try do
            measure_size(supervisor, scope, size)
          after
            unboxed(fn -> cleanup(scope) end)
          end
        end

      by_size = Map.new(measurements, &{&1.size, &1})

      assert Enum.map(measurements, & &1.size) == @sizes
      # AC-26: a 612-trip reviewed combine is not capped, and every fixture moves exactly its own
      # membership with one complete envelope.
      assert by_size[612].moved == 612

      for measurement <- measurements do
        assert measurement.source_trips_left == 0
        assert measurement.audit_logs == measurement.size
        assert measurement.envelope_logs == 1
        assert measurement.envelope_members == measurement.size
        assert measurement.lock_ms > 0
        assert measurement.apply_ms > 0
      end

      # The 1,000 and 2,000 fixtures are uniform but for their trip count: doubling the trips may
      # grow the persisted metadata at most 2.2 times (fixed overhead and one membership envelope
      # are part of both sides of the ratio).
      growth = by_size[2_000].payload_text_bytes / by_size[1_000].payload_text_bytes
      growth_stored = by_size[2_000].payload_bytes / by_size[1_000].payload_bytes

      line =
        "EV-6: growth_1000_to_2000=#{Float.round(growth, 3)} " <>
          "stored_growth_1000_to_2000=#{Float.round(growth_stored, 3)}"

      IO.puts(line)

      assert growth <= 2.2
      assert growth_stored <= 2.2
    end
  end

  # --- measurements ----------------------------------------------------------

  # One whole public apply: the reviewed token is taken first (outside the measured window), then a
  # second connection observes the scoped version row with `FOR UPDATE NOWAIT` polling while the
  # apply task runs through the ordinary production `Repo` transaction.
  defp measure_size(supervisor, scope, size) do
    {review_us, {:ok, review}} =
      unboxed(fn ->
        :timer.tc(fn ->
          Gtfs.review_calendar_change(@command, client_fingerprints(), scope.audit)
        end)
      end)

    assert review.ready?
    assert review.moved_trip_count == size

    observer = start_lock_observer(supervisor, scope)
    apply_task = start_apply(supervisor, scope, review.fingerprint)

    {apply_us, result} = Task.await(apply_task.task, @collect_timeout)
    assert {:ok, %{action: :combined, moved_trip_count: ^size} = applied} = result

    lock_ms =
      receive do
        {:lock_window, ^observer, held_at, released_at} -> released_at - held_at
      after
        @collect_timeout -> flunk("the version-lock observer never reported a window")
      end

    counts = audit_counts(scope)
    envelope = envelope_membership(scope)

    measurement = %{
      size: size,
      moved: applied.moved_trip_count,
      review_ms: div(review_us, 1_000),
      apply_ms: div(apply_us, 1_000),
      lock_ms: lock_ms,
      source_trips_left: source_trip_count(scope),
      audit_logs: counts.logs,
      envelope_logs: counts.envelopes,
      envelope_members: length(envelope),
      payload_bytes: counts.payload_bytes,
      payload_text_bytes: counts.payload_text_bytes
    }

    # The observation line is printed before any completeness assertion, so the recorded numbers
    # survive a later failure on the same run.
    IO.puts(
      "EV-6: size=#{size} moved=#{measurement.moved} review_ms=#{measurement.review_ms} " <>
        "apply_ms=#{measurement.apply_ms} lock_ms=#{measurement.lock_ms} " <>
        "audit_logs=#{measurement.audit_logs} envelope_logs=#{measurement.envelope_logs} " <>
        "envelope_members=#{measurement.envelope_members} " <>
        "payload_bytes=#{measurement.payload_bytes} " <>
        "payload_text_bytes=#{measurement.payload_text_bytes}"
    )

    # AC-26: complete membership is recorded once, in the one envelope log, in UUID order, and no
    # other log repeats it.
    assert envelope == Enum.sort(applied.changed_trip_ids)
    assert length(applied.changed_trip_ids) == size
    refute Enum.any?(change_logs(scope), &Map.has_key?(&1.changed_fields, "affected_trip_ids"))

    measurement
  end

  defp start_apply(supervisor, scope, token) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> timed_apply(scope, token, parent) end)

    assert_receive {:apply_ready, task_pid, _backend}, @ready_timeout
    assert task_pid == task.pid
    send(task.pid, :go)
    %{task: task}
  end

  defp timed_apply(scope, token, parent) do
    unboxed(fn ->
      send(parent, {:apply_ready, self(), backend_pid()})

      receive do
        :go -> :ok
      end

      :timer.tc(fn -> Gtfs.apply_calendar_change(@command, token, scope.audit) end)
    end)
  end

  # The lock window is measured from a second committing connection: `FOR UPDATE NOWAIT` succeeds
  # while the row is free and raises `lock_not_available` while the apply holds it, so the interval
  # between the first unavailable attempt and the first available one is the interval the scoped
  # version row was exclusively held. The row is observed free once before the apply is released,
  # so the window cannot start before the apply acquired it.
  defp start_lock_observer(supervisor, scope) do
    parent = self()
    task = Task.Supervisor.async_nolink(supervisor, fn -> observe_lock(scope, parent) end)

    assert_receive {:observer_ready, task_pid}, @ready_timeout
    assert task_pid == task.pid
    task.pid
  end

  defp observe_lock(scope, parent) do
    unboxed(fn ->
      refute version_row_held?(scope)
      send(parent, {:observer_ready, self()})

      deadline = System.monotonic_time(:millisecond) + @lock_timeout
      held_at = await_lock_state(scope, true, deadline)
      released_at = await_lock_state(scope, false, deadline)
      send(parent, {:lock_window, self(), held_at, released_at})
    end)
  end

  defp await_lock_state(scope, want_held?, deadline) do
    held? = version_row_held?(scope)

    cond do
      held? == want_held? ->
        System.monotonic_time(:millisecond)

      System.monotonic_time(:millisecond) >= deadline ->
        raise "version row never reached held?=#{want_held?}"

      true ->
        Process.sleep(@lock_poll_interval)
        await_lock_state(scope, want_held?, deadline)
    end
  end

  defp version_row_held?(scope) do
    Repo.query!(
      "SELECT 1 FROM gtfs_versions WHERE id = $1::uuid AND organization_id = $2::uuid " <>
        "FOR UPDATE NOWAIT",
      [Ecto.UUID.dump!(scope.version_id), Ecto.UUID.dump!(scope.organization_id)]
    )

    false
  rescue
    error in [Postgrex.Error] ->
      if error.postgres.code == :lock_not_available do
        true
      else
        reraise error, __STACKTRACE__
      end
  end

  defp backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  # --- recorded values -------------------------------------------------------

  defp audit_counts(scope) do
    %Postgrex.Result{rows: [[logs, envelopes, payload_bytes, text_bytes]]} =
      Repo.query!(
        """
        SELECT count(*),
               count(*) FILTER (WHERE changed_fields ? 'combination'),
               coalesce(sum(pg_column_size(changed_fields)), 0),
               coalesce(sum(octet_length(changed_fields::text)), 0)
        FROM change_logs
        WHERE organization_id = $1::uuid AND gtfs_version_id = $2::uuid
        """,
        [Ecto.UUID.dump!(scope.organization_id), Ecto.UUID.dump!(scope.version_id)]
      )

    %{
      logs: logs,
      envelopes: envelopes,
      payload_bytes: payload_bytes,
      payload_text_bytes: text_bytes
    }
  end

  defp envelope_membership(scope) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        SELECT changed_fields -> 'combination' -> 'changed_trip_ids'
        FROM change_logs
        WHERE organization_id = $1::uuid AND gtfs_version_id = $2::uuid
          AND changed_fields ? 'combination'
        """,
        [Ecto.UUID.dump!(scope.organization_id), Ecto.UUID.dump!(scope.version_id)]
      )

    case rows do
      [[ids]] -> ids
      _other -> []
    end
  end

  # --- list fixture ----------------------------------------------------------

  # One version whose identities cycle the same five shapes as the browser resource fixture: a
  # weekly range, a Mon-Fri range, a dates-only identity, a Mon-Fri range with a break and a
  # metadata-only identity. Row counts differ; the shapes do not.
  defp screen_version(organization_id, count) do
    version = gtfs_version_fixture(organization_id)
    now = DateTime.utc_now()
    indexes = 0..(count - 1)

    calendars =
      for index <- indexes, rem(index, 5) in [0, 1, 3] do
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: version.id,
          service_id: screen_service_id(index),
          monday: 1,
          tuesday: 1,
          wednesday: 1,
          thursday: 1,
          friday: 1,
          saturday: if(rem(index, 5) == 0, do: 1, else: 0),
          sunday: if(rem(index, 5) == 0, do: 1, else: 0),
          start_date: ~D[2026-01-01],
          end_date: ~D[2026-12-31],
          inserted_at: now,
          updated_at: now
        }
      end

    attributes =
      for index <- indexes do
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: version.id,
          service_id: screen_service_id(index),
          service_description: "Screen service #{index}",
          service_schedule_typicality: 0,
          inserted_at: now,
          updated_at: now
        }
      end

    exceptions =
      for index <- indexes, rem(index, 5) in [2, 3], offset <- [30, 31, 32, 90] do
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          gtfs_version_id: version.id,
          service_id: screen_service_id(index),
          date: Date.add(~D[2026-01-01], offset),
          exception_type: if(rem(index, 5) == 2, do: 1, else: 2),
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Calendar, calendars)
    Repo.insert_all(CalendarAttribute, attributes)
    Repo.insert_all(CalendarDate, exceptions)

    version
  end

  defp screen_service_id(index), do: "SCREEN_" <> pad(index)

  # --- combination fixture ---------------------------------------------------

  # A committed scope for one size: a destination weekly calendar that already covers every date
  # the moving source adds, so the reviewed union changes no destination row and the operation is a
  # pure trip move with one trip log per moved trip. The source is a dates-only calendar whose
  # additions fall inside the destination's range, so the review has no conflict to answer.
  defp seed_combine_scope(trip_count) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "R_RESOURCE"})
    actor = user_fixture(%{email: "combination-resource-#{unique()}@example.test"})
    organization_membership_fixture(actor, organization)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "DEST",
      name: "Resource destination",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1,
      start_date: ~D[2026-03-01],
      end_date: ~D[2026-03-31]
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SAT",
      name: "Resource source",
      dates: [~D[2026-03-07], ~D[2026-03-14]]
    })

    insert_trips!(
      organization.id,
      version.id,
      route.route_id,
      "DEST",
      "RES_DEST",
      @destination_trips
    )

    insert_trips!(organization.id, version.id, route.route_id, "SAT", "RES_SRC", trip_count)

    %{
      organization_id: organization.id,
      version_id: version.id,
      actor_id: actor.id,
      audit: audit_for(organization.id, version.id, actor.id)
    }
  end

  defp insert_trips!(organization_id, version_id, route_id, service_id, prefix, count) do
    now = DateTime.utc_now()

    organization_id
    |> trip_rows(version_id, route_id, service_id, prefix, count, now)
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk ->
      {inserted, _rows} = Repo.insert_all(Trip, chunk)

      if inserted != length(chunk) do
        raise "trip fixture inserted #{inserted} of #{length(chunk)} rows"
      end
    end)
  end

  defp trip_rows(organization_id, version_id, route_id, service_id, prefix, count, now) do
    for index <- 1..count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        route_id: route_id,
        service_id: service_id,
        trip_id: "#{prefix}_#{pad(index)}",
        trip_headsign: "Resource trip",
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp source_trip_count(scope) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^scope.organization_id and
            t.gtfs_version_id == ^scope.version_id and t.service_id == "SAT"
      ),
      :count
    )
  end

  defp change_logs(scope) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.organization_id == ^scope.organization_id and l.gtfs_version_id == ^scope.version_id
      )
    )
  end

  defp client_fingerprints do
    Map.new(["DEST", "SAT"], &{&1, "client-#{&1}"})
  end

  defp audit_for(organization_id, version_id, actor_id) do
    %AuditContext{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      station_stop_id: nil,
      actor_id: actor_id,
      actor_email: "combination-resources@example.test"
    }
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(3, "0")

  defp unique, do: System.unique_integer([:positive])

  # --- query counting --------------------------------------------------------

  # Ecto emits `[:gtfs_planner, :repo, :query]` in the process that issues the query, so the handler
  # reports to this test process and the measured call runs in it.
  defp measure_queries(fun) do
    ref = make_ref()
    handler_id = "combination-resources-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      @query_event,
      fn _event, _measurements, _metadata, _config -> send(test_pid, {:query, ref}) end,
      nil
    )

    try do
      {elapsed_us, result} = :timer.tc(fun)
      {result, div(elapsed_us, 1_000), drain_queries(ref, 0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_queries(ref, count) do
    receive do
      {:query, ^ref} -> drain_queries(ref, count + 1)
    after
      0 -> count
    end
  end

  # --- cleanup ---------------------------------------------------------------

  # `async: false` with unboxed committing connections means the committed fixtures are not rolled
  # back, so the scope this case created is deleted explicitly.
  defp cleanup(scope) do
    organization_id = scope.organization_id

    Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
    Repo.delete_all(from(t in Transfer, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
    Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
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

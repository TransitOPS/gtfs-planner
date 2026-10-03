defmodule GtfsPlanner.Gtfs.Import.BatchFencingTest do
  @moduledoc """
  Merge evidence (EV-40) for CL-10: a superseded full-import worker writes nothing
  after its run is handed over (INV-4).

  Every case drives `Publication.run/4` with a real claimed run, so the fence travels
  `Publication` -> `Import.import_files/5` -> `BatchProcessor` exactly as in production.
  The two interleavings commit their own organization, users, version, run and rows on
  own connections, because the paused worker and the handover run concurrently, and they
  delete exactly those rows in `on_exit` even when the test fails. Identities carry a
  random UUID so a leaked row cannot collide with a later run.

  - the paused import is held by a telemetry handler in the worker process at the
    `BEGIN` of its second stop_times batch; its lease is then expired and reconciled by
    `ImportRuns.reconcile_expired/1`, and after it resumes no batch 2 row exists;
  - a batch whose fence callback holds the run `FOR SHARE` makes a concurrent
    `ImportRuns.renew_lease/3` wait until the batch commits.

  The derivation and extension cases run in the shared SQL sandbox. A telemetry
  handler marks the run `interrupted` right after the stop_times insert, standing in for
  a handover, and the next fenced transaction must refuse to write.

  The proof boundary is one PostgreSQL instance at READ COMMITTED. Extension image files
  are written after the extension transaction commits and are not fenced.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.Extensions.Manifest
  alias GtfsPlanner.Gtfs.Import.BatchProcessor
  alias GtfsPlanner.Gtfs.Import.Publication
  alias GtfsPlanner.Gtfs.Import.RowParser
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions.GtfsVersion

  @expired ~U[2000-01-01 00:00:00.000000Z]
  @receive_timeout 5_000
  @hold_timeout 10_000
  @topic "import:batch-fencing"

  @levels "level_id,level_index,level_name\nL1,0.0,Ground\n"

  @stops """
  stop_id,stop_name,stop_lat,stop_lon,level_id,location_type,wheelchair_boarding
  S1,Main,40.7,-74.0,L1,1,1
  S2,Second,40.8,-74.1,L1,0,1
  """

  @routes "route_id,route_type,route_short_name,route_long_name\nR1,3,1,Route One\n"

  @calendar """
  service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
  WK,1,1,1,1,1,0,0,20260101,20261231
  """

  @trips "trip_id,route_id,service_id,direction_id\nT1,R1,WK,0\n"

  @stop_times """
  trip_id,stop_id,stop_sequence,arrival_time,departure_time
  T1,S1,1,08:00:00,08:00:00
  T1,S2,2,08:10:00,08:10:00
  """

  describe "a fenced import of a complete feed" do
    test "publishes through its phase 1, batch, derivation and extension transactions" do
      organization = organization_fixture()
      {run, token} = claimed_run(organization)

      files =
        feed_files(:with_trips) ++
          [%{filename: "_pathways_extensions.json", content: coordinate_manifest()}]

      assert {:ok, published, result} =
               Publication.run(run, token, StagedImport.stage(files), @topic)

      assert published.id == run.gtfs_version_id
      assert published.publication_status == "published"
      assert result.counts.stop_times == 2
      # The feed names no route pattern, so derivation classifies its one trip as custom.
      assert result.counts.trips_custom == 1
      assert result.counts.extensions_stop_coordinates == 1
      assert result.extensions == :complete
      assert Repo.get!(Run, run.id).state == "published"
    end
  end

  describe "an import whose run was reconciled before it started" do
    test "writes no row and leaves the run interrupted" do
      organization = organization_fixture()
      {run, token} = claimed_run(organization)
      set_lease_expiry(run.id, @expired)

      assert [%Run{id: run_id, state: "interrupted"}] =
               ImportRuns.reconcile_expired(organization.id)

      assert run_id == run.id

      assert {:error, %GtfsVersion{id: version_id}, :lease_lost} =
               Publication.run(run, token, StagedImport.stage(feed_files(:with_trips)), @topic)

      assert version_id == run.gtfs_version_id

      assert row_counts(organization.id, run.gtfs_version_id) ==
               %{levels: 0, stops: 0, trips: 0, stop_times: 0}

      assert Repo.get!(Run, run.id).state == "interrupted"
    end
  end

  describe "an import paused before its second stop_times batch" do
    test "commits no stop_times row from batch 2 after its run is reconciled" do
      scope = committed_run()
      on_exit(fn -> delete_committed_scope(scope) end)
      handler_id = "batch-fencing-#{Ecto.UUID.generate()}"
      files = StagedImport.stage(two_batch_files())

      worker =
        Task.async(fn ->
          receive do
            :go -> :ok
          end

          unboxed(fn -> Publication.run(scope.run, scope.token, files, @topic) end)
        end)

      :ok =
        :telemetry.attach(
          handler_id,
          [:gtfs_planner, :repo, :query],
          &__MODULE__.pause_at_third_begin/4,
          %{test: self(), worker: worker.pid, begins: :counters.new(1, [])}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      send(worker.pid, :go)

      assert_receive {:import_paused, worker_pid}, @receive_timeout

      # Phase 1 and the first 1,000-row batch are committed; batch 2 has not begun to write.
      assert committed_counts(scope).stop_times == 1_000

      unboxed(fn -> set_lease_expiry(scope.run.id, @expired) end)

      assert [%Run{id: run_id, state: "interrupted"}] =
               unboxed(fn -> ImportRuns.reconcile_expired(scope.organization_id) end)

      assert run_id == scope.run.id

      send(worker_pid, :resume)

      assert {:ok, {:error, %GtfsVersion{publication_status: "failed"}, :lease_lost}} =
               Task.yield(worker, @receive_timeout)

      assert committed_counts(scope).stop_times == 1_000
    end
  end

  describe "a batch transaction in progress" do
    test "holds the run FOR SHARE, so renewing the lease waits for the commit and then succeeds" do
      scope = committed_run()
      on_exit(fn -> delete_committed_scope(scope) end)
      parent = self()
      earlier = DateTime.add(DateTime.utc_now(), 60, :second)
      unboxed(fn -> set_lease_expiry(scope.run.id, earlier) end)

      batch =
        Task.async(fn ->
          unboxed(fn ->
            BatchProcessor.insert_batched_with_transactions(
              Repo,
              Level,
              [{:ok, 2, %{"level_id" => "L1", "level_index" => "0.0", "level_name" => "Ground"}}],
              &RowParser.level_row_to_attrs/3,
              organization_id: scope.organization_id,
              gtfs_version_id: scope.version_id,
              file_name: "levels.txt",
              topic: @topic,
              total_rows: 1,
              fence: fn -> hold_fence(parent, scope) end
            )
          end)
        end)

      assert_receive {:fence_held, holder_backend}, @receive_timeout

      renewer =
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:renewer_started, backend_pid()})
            ImportRuns.renew_lease(scope.organization_id, scope.run.id, scope.token)
          end)
        end)

      assert_receive {:renewer_started, renewer_backend}, @receive_timeout

      deadline = System.monotonic_time(:millisecond) + @receive_timeout
      assert :ok == unboxed(fn -> await_blocker(renewer_backend, holder_backend, deadline) end)

      send(batch.pid, :release)

      assert {:ok, 1} = Task.await(batch, @receive_timeout)
      assert :ok = Task.await(renewer, @receive_timeout)

      renewed = unboxed(fn -> Repo.get!(Run, scope.run.id).lease_expires_at end)
      assert DateTime.compare(renewed, earlier) == :gt
    end
  end

  describe "an import handed over before its derivation phase" do
    test "refuses to derive and leaves the trips pending" do
      organization = organization_fixture()
      {run, token} = claimed_run(organization)
      hand_over_after_stop_times_insert(run)

      assert {:error, %GtfsVersion{}, :lease_lost} =
               Publication.run(run, token, StagedImport.stage(feed_files(:with_trips)), @topic)

      assert row_counts(organization.id, run.gtfs_version_id).stop_times == 2

      assert %Trip{pattern_derivation_state: "pending"} =
               Repo.get_by!(Trip, organization_id: organization.id, trip_id: "T1")

      assert Repo.get!(Run, run.id).state == "interrupted"
    end
  end

  describe "an import handed over before it classifies the trips of a missing route" do
    test "classifies none of them" do
      organization = organization_fixture()
      {run, token} = claimed_run(organization)
      hand_over_after_stop_times_insert(run)

      files =
        Enum.reject(feed_files(:with_trips), &(&1.filename == "routes.txt"))

      assert {:error, %GtfsVersion{}, :lease_lost} =
               Publication.run(run, token, StagedImport.stage(files), @topic)

      assert %Trip{pattern_derivation_state: "pending"} =
               Repo.get_by!(Trip, organization_id: organization.id, trip_id: "T1")
    end
  end

  describe "an import handed over before its extension phase" do
    test "refuses to restore extension data and leaves the stop untouched" do
      organization = organization_fixture()
      {run, token} = claimed_run(organization)
      hand_over_after_stop_times_insert(run)

      files =
        feed_files(:without_trips) ++
          [%{filename: "_pathways_extensions.json", content: coordinate_manifest()}]

      assert {:error, %GtfsVersion{}, :lease_lost} =
               Publication.run(run, token, StagedImport.stage(files), @topic)

      assert row_counts(organization.id, run.gtfs_version_id).stop_times == 2

      assert %Stop{diagram_coordinate: nil} =
               Repo.get_by!(Stop, organization_id: organization.id, stop_id: "S1")
    end
  end

  # Runs in the process that issued the query: the paused worker. It counts that
  # worker's BEGINs and holds it at the third (phase 1, batch 1, then batch 2), before
  # the batch's fence statement.
  @doc false
  def pause_at_third_begin(
        _event,
        _measurements,
        %{query: "begin"},
        %{test: test, worker: worker, begins: begins}
      )
      when worker == self() do
    :counters.add(begins, 1, 1)

    case :counters.get(begins, 1) do
      3 ->
        send(test, {:import_paused, self()})

        receive do
          :resume -> :ok
        after
          @hold_timeout -> :ok
        end

      _earlier ->
        :ok
    end
  end

  def pause_at_third_begin(_event, _measurements, _metadata, _config), do: :ok

  # Stands in for a handover the moment the first stop_times batch is inserted: the run
  # leaves `running`, so every later fenced transaction of this test process must refuse.
  @doc false
  def mark_interrupted_after_stop_times_insert(
        _event,
        _measurements,
        %{source: "stop_times", query: "INSERT" <> _},
        %{owner: owner, run_id: run_id}
      )
      when owner == self() do
    Repo.update_all(
      from(r in Run, where: r.id == ^run_id),
      set: [
        state: "interrupted",
        counts_complete: false,
        finished_at: DateTime.utc_now(),
        lease_token: nil,
        lease_expires_at: nil
      ]
    )
  end

  def mark_interrupted_after_stop_times_insert(_event, _measurements, _metadata, _config),
    do: :ok

  defp hand_over_after_stop_times_insert(run) do
    handler_id = "batch-fencing-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:gtfs_planner, :repo, :query],
        &__MODULE__.mark_interrupted_after_stop_times_insert/4,
        %{owner: self(), run_id: run.id}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # Takes the fence as the production batch does, then keeps the transaction open until
  # the test releases it. A batch that was never released fails instead of hanging.
  defp hold_fence(parent, scope) do
    ImportRuns.assert_owner!(scope.organization_id, scope.run.id, scope.token, ~w(running))
    send(parent, {:fence_held, backend_pid()})

    receive do
      :release -> :ok
    after
      @hold_timeout -> Repo.rollback(:not_released)
    end
  end

  defp feed_files(:with_trips) do
    [
      %{filename: "levels.txt", content: @levels},
      %{filename: "stops.txt", content: @stops},
      %{filename: "routes.txt", content: @routes},
      %{filename: "calendar.txt", content: @calendar},
      %{filename: "trips.txt", content: @trips},
      %{filename: "stop_times.txt", content: @stop_times}
    ]
  end

  defp feed_files(:without_trips) do
    [
      %{filename: "levels.txt", content: @levels},
      %{filename: "stops.txt", content: @stops},
      %{filename: "stop_times.txt", content: @stop_times}
    ]
  end

  # `Import` batches every 1,000 rows, so 1,001 rows make exactly two batches.
  defp two_batch_files do
    rows = Enum.map_join(1..1_001, "", fn n -> "T1,S1,#{n},08:00:00,08:00:00\n" end)

    [
      %{filename: "levels.txt", content: @levels},
      %{filename: "stops.txt", content: @stops},
      %{
        filename: "stop_times.txt",
        content: "trip_id,stop_id,stop_sequence,arrival_time,departure_time\n" <> rows
      }
    ]
  end

  defp coordinate_manifest do
    [%{stop_id: "S1", diagram_coordinate: %{x: 10.0, y: 20.0}}]
    |> Manifest.build([], [], [])
    |> Manifest.encode()
  end

  # A pending staging target claimed for import by an active editor of the organization.
  defp claimed_run(organization) do
    user = user_fixture(%{email: "batch-fence-#{Ecto.UUID.generate()}@example.com"})
    organization_membership_fixture(user, organization)

    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(
        organization.id,
        %{id: user.id, email: user.email},
        %{name: "Fenced import"}
      )

    {:ok, claimed, _version, token} =
      ImportRuns.claim_import(organization.id, run.id, run.lease_token)

    {claimed, token}
  end

  # The organization, users, version and run of the committed cases, created on an own
  # connection so the worker and the handover see them. `delete_committed_scope/1`
  # removes exactly these rows.
  defp committed_run do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "batch-fence-#{Ecto.UUID.generate()}"})
      {run, token} = claimed_run(organization)

      %{
        organization_id: organization.id,
        version_id: run.gtfs_version_id,
        run: run,
        token: token
      }
    end)
  end

  defp row_counts(organization_id, version_id) do
    %{
      levels: count_rows(Level, organization_id, version_id),
      stops: count_rows(Stop, organization_id, version_id),
      trips: count_rows(Trip, organization_id, version_id),
      stop_times: count_rows(StopTime, organization_id, version_id)
    }
  end

  defp committed_counts(scope),
    do: unboxed(fn -> row_counts(scope.organization_id, scope.version_id) end)

  defp count_rows(schema, organization_id, version_id) do
    Repo.aggregate(
      from(r in schema,
        where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id
      ),
      :count
    )
  end

  defp delete_committed_scope(%{organization_id: organization_id}) do
    unboxed(fn ->
      user_ids =
        Repo.all(
          from(m in UserOrgMembership,
            where: m.organization_id == ^organization_id,
            select: m.user_id
          )
        )

      Repo.delete_all(from(r in StopTime, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(r in Stop, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(r in Level, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(r in Run, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id == ^organization_id))
      delete_versions!(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
    end)
  end

  defp set_lease_expiry(run_id, expiry) do
    {1, nil} =
      Repo.update_all(from(r in Run, where: r.id == ^run_id), set: [lease_expires_at: expiry])
  end
end

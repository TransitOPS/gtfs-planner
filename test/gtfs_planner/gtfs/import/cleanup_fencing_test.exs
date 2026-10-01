defmodule GtfsPlanner.Gtfs.Import.CleanupFencingTest do
  @moduledoc """
  Merge evidence (EV-39) for CL-9 and CL-10: a cleanup owner keeps its lease while
  it works, and a superseded owner deletes nothing (INV-4).

  The `assert_owner!/4` and wrong-token cases run in the shared SQL sandbox. The two
  interleavings commit their own organization, users, version, run and rows on own
  connections, because the paused worker and the handover run concurrently, and they
  delete exactly those rows in `on_exit` even when the test fails. Identities carry a
  random UUID so a leaked row cannot collide with a later run.

  - the paused cleanup is blocked by `{:pause_after_batch, fun}` between two committed
    batches; its lease is then expired and reconciled by
    `ImportRuns.reconcile_expired/1`, and after it resumes no row or file is removed;
  - a closure of the run waits for a batch that already holds the fence, and a cleanup
    that starts after the closure deletes nothing.

  The proof boundary is one PostgreSQL instance at READ COMMITTED. The diagram
  namespace is deleted after the last fenced batch but is not itself fenced.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.Import.Failure
  alias GtfsPlanner.Gtfs.Import.Recovery
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.Level
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @expired ~U[2000-01-01 00:00:00.000000Z]
  @receive_timeout 5_000
  @hold_timeout 10_000

  setup do
    previous_uploads = Application.fetch_env(:gtfs_planner, :uploads_path)
    previous_batch = Application.fetch_env(:gtfs_planner, :import_cleanup_batch_size)
    previous_injection = Application.fetch_env(:gtfs_planner, :import_cleanup_inject_failure)

    root = Path.join(System.tmp_dir!(), "cleanup_fencing_#{Ecto.UUID.generate()}")
    Application.put_env(:gtfs_planner, :uploads_path, root)

    on_exit(fn ->
      File.rm_rf!(root)
      restore_env(:uploads_path, previous_uploads)
      restore_env(:import_cleanup_batch_size, previous_batch)
      restore_env(:import_cleanup_inject_failure, previous_injection)
    end)

    :ok
  end

  describe "ImportRuns.renew_lease/3" do
    test "renews the lease of a cleaning run for its token" do
      organization = organization_fixture()
      %{run: run, token: token} = cleaning_run(organization)

      earlier = DateTime.add(Repo.get!(Run, run.id).lease_expires_at, -1, :second)
      set_lease_expiry(run.id, earlier)

      assert :ok = ImportRuns.renew_lease(organization.id, run.id, token)

      assert DateTime.compare(Repo.get!(Run, run.id).lease_expires_at, earlier) == :gt
    end
  end

  describe "ImportRuns.assert_owner!/4" do
    test "returns the locked run to its owner" do
      organization = organization_fixture()
      %{run: run, token: token} = cleaning_run(organization)

      assert {:ok, %Run{id: run_id, state: "cleaning"}} =
               Repo.transaction(fn ->
                 ImportRuns.assert_owner!(organization.id, run.id, token, ~w(cleaning))
               end)

      assert run_id == run.id
    end

    test "raises outside a transaction, where its share lock would end with the statement" do
      assert_raise ArgumentError, ~r/inside Repo.transaction/, fn ->
        unboxed(fn ->
          ImportRuns.assert_owner!(
            Ecto.UUID.generate(),
            Ecto.UUID.generate(),
            Ecto.UUID.generate(),
            ~w(cleaning)
          )
        end)
      end
    end

    test "rolls back :lease_lost for a wrong token" do
      organization = organization_fixture()
      %{run: run} = cleaning_run(organization)

      assert {:error, :lease_lost} =
               Repo.transaction(fn ->
                 ImportRuns.assert_owner!(
                   organization.id,
                   run.id,
                   Ecto.UUID.generate(),
                   ~w(cleaning)
                 )
               end)
    end

    test "rolls back :lease_lost for a state outside the expected list" do
      organization = organization_fixture()
      %{run: run, token: token} = cleaning_run(organization)

      assert {:error, :lease_lost} =
               Repo.transaction(fn ->
                 ImportRuns.assert_owner!(organization.id, run.id, token, ~w(running))
               end)
    end

    test "rolls back :lease_lost for an expired lease" do
      organization = organization_fixture()
      %{run: run, token: token} = cleaning_run(organization)
      set_lease_expiry(run.id, @expired)

      assert {:error, :lease_lost} =
               Repo.transaction(fn ->
                 ImportRuns.assert_owner!(organization.id, run.id, token, ~w(cleaning))
               end)
    end
  end

  describe "Recovery.run/3 with a token the run no longer holds" do
    test "deletes no rows and no files, and leaves the run cleaning" do
      organization = organization_fixture()
      %{run: run, version: version, token: token} = cleaning_run(organization)
      scope = seed(organization.id, version.id, levels: 3, routes: 2)
      file = write_namespace_file(organization.id, version.id)

      assert {:error, :lease_lost} =
               Recovery.run(organization.id, run.id, Ecto.UUID.generate())

      assert row_counts(scope) == %{levels: 3, routes: 2}
      assert File.exists?(file)

      still_cleaning = Repo.get!(Run, run.id)
      assert still_cleaning.state == "cleaning"
      assert still_cleaning.lease_token == token
    end
  end

  describe "a cleanup paused between delete batches" do
    test "deletes no further rows or files after its lease is expired and reconciled" do
      scope = committed_scope(levels: 5, routes: 3)
      on_exit(fn -> delete_committed_scope(scope) end)
      file = write_namespace_file(scope.organization_id, scope.version_id)

      Application.put_env(:gtfs_planner, :import_cleanup_batch_size, 2)

      Application.put_env(
        :gtfs_planner,
        :import_cleanup_inject_failure,
        {:pause_after_batch, pause_hook(self())}
      )

      worker =
        Task.async(fn ->
          unboxed(fn -> Recovery.run(scope.organization_id, scope.run_id, scope.token) end)
        end)

      assert_receive {:cleanup_paused, _schema, worker_pid}, @receive_timeout

      # Five levels and three routes were seeded; one batch of two rows is gone.
      paused_counts = committed_counts(scope)
      assert paused_counts.levels + paused_counts.routes == 6

      unboxed(fn -> set_lease_expiry(scope.run_id, @expired) end)

      assert [%Run{id: run_id, state: "cleanup_failed"}] =
               unboxed(fn -> ImportRuns.reconcile_expired(scope.organization_id) end)

      assert run_id == scope.run_id

      send(worker_pid, :resume)

      assert {:ok, {:error, :lease_lost}} = Task.yield(worker, @receive_timeout)
      assert committed_counts(scope) == paused_counts
      assert File.exists?(file)

      assert unboxed(fn ->
               Repo.exists?(from(v in GtfsVersion, where: v.id == ^scope.version_id))
             end)
    end
  end

  describe "a handover racing a cleanup batch" do
    test "waits for the batch holding the fence, and a later cleanup deletes nothing" do
      scope = committed_scope(levels: 3, routes: 2)
      on_exit(fn -> delete_committed_scope(scope) end)
      parent = self()

      holder =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              ImportRuns.assert_owner!(
                scope.organization_id,
                scope.run_id,
                scope.token,
                ~w(cleaning)
              )

              send(parent, {:fence_held, backend_pid()})

              receive do
                :release -> :held
              after
                @hold_timeout -> Repo.rollback(:not_released)
              end
            end)
          end)
        end)

      assert_receive {:fence_held, holder_backend}, @receive_timeout

      closer =
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:closer_started, backend_pid()})

            ImportRuns.fail_cleanup(
              scope.organization_id,
              scope.run_id,
              scope.token,
              :executor_lost
            )
          end)
        end)

      assert_receive {:closer_started, closer_backend}, @receive_timeout

      deadline = System.monotonic_time(:millisecond) + @receive_timeout
      assert :ok == unboxed(fn -> await_blocker(closer_backend, holder_backend, deadline) end)

      send(holder.pid, :release)

      assert {:ok, :held} = Task.await(holder, @receive_timeout)
      assert {:ok, %Run{state: "cleanup_failed"}} = Task.await(closer, @receive_timeout)

      assert {:error, :lease_lost} =
               unboxed(fn ->
                 Recovery.run(scope.organization_id, scope.run_id, scope.token)
               end)

      assert committed_counts(scope) == %{levels: 3, routes: 2}
    end
  end

  # Blocks the cleanup worker after a committed batch until the test resumes it. A
  # worker that was not stopped would block here again, and the test's bounded yield
  # then fails instead of hanging.
  defp pause_hook(test_pid) do
    fn schema ->
      send(test_pid, {:cleanup_paused, schema, self()})

      receive do
        :resume -> :ok
      after
        @hold_timeout -> :ok
      end
    end
  end

  # A staging target that failed, then claimed for cleanup by a second editor. Returns
  # the cleaning run, its version and the cleanup lease token.
  defp cleaning_run(organization) do
    operator = editor_actor(organization)
    cleaner = editor_actor(organization)

    {:ok, %{run: run, version: version}} =
      ImportRuns.create_pending_target(organization.id, operator, %{name: "Fenced cleanup"})

    {:ok, _run, _version, import_token} =
      ImportRuns.claim_import(organization.id, run.id, run.lease_token)

    failure =
      Failure.from_error(:unknown, phase: :phase_2, outcome: :failed, committed_counts: %{})

    {:ok, _run, _version} = ImportRuns.fail_import(organization.id, run.id, import_token, failure)

    {:ok, cleaning, _version, token} = ImportRuns.claim_cleanup(organization.id, run.id, cleaner)

    %{run: cleaning, version: version, token: token}
  end

  defp editor_actor(organization) do
    user = user_fixture(%{email: "fence-#{Ecto.UUID.generate()}@example.com"})
    organization_membership_fixture(user, organization)
    %{id: user.id, email: user.email}
  end

  # Everything the committed cases create, on an own connection so the worker and the
  # handover see it. `delete_committed_scope/1` removes exactly these rows.
  defp committed_scope(rows) do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "fence-#{Ecto.UUID.generate()}"})
      %{run: run, version: version, token: token} = cleaning_run(organization)
      scope = seed(organization.id, version.id, rows)

      Map.merge(scope, %{run_id: run.id, token: token})
    end)
  end

  defp seed(organization_id, version_id, levels: level_count, routes: route_count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    levels =
      Enum.map(1..level_count, fn i ->
        %{
          id: Ecto.UUID.generate(),
          level_id: "L#{i}",
          level_index: 0.0,
          level_name: "Level #{i}",
          organization_id: organization_id,
          gtfs_version_id: version_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    routes =
      Enum.map(1..route_count, fn i ->
        %{
          id: Ecto.UUID.generate(),
          route_id: "R#{i}",
          route_type: 3,
          route_short_name: "R#{i}",
          route_long_name: "Route #{i}",
          organization_id: organization_id,
          gtfs_version_id: version_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    {^level_count, nil} = Repo.insert_all(Level, levels)
    {^route_count, nil} = Repo.insert_all(Route, routes)

    %{organization_id: organization_id, version_id: version_id}
  end

  defp row_counts(%{organization_id: organization_id, version_id: version_id}) do
    %{
      levels: count_rows(Level, organization_id, version_id),
      routes: count_rows(Route, organization_id, version_id)
    }
  end

  defp committed_counts(scope), do: unboxed(fn -> row_counts(scope) end)

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

      Repo.delete_all(from(r in Level, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(r in Run, where: r.organization_id == ^organization_id))
      Repo.delete_all(from(m in UserOrgMembership, where: m.organization_id == ^organization_id))
      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^organization_id))
      Repo.delete_all(from(u in User, where: u.id in ^user_ids))
    end)
  end

  defp set_lease_expiry(run_id, expiry) do
    {1, nil} =
      Repo.update_all(from(r in Run, where: r.id == ^run_id), set: [lease_expires_at: expiry])
  end

  defp write_namespace_file(organization_id, version_id) do
    file =
      Application.fetch_env!(:gtfs_planner, :uploads_path)
      |> Path.join("diagrams")
      |> Path.join(organization_id)
      |> Path.join(version_id)
      |> Path.join("station_a/plan.png")
      |> Path.expand()

    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "bytes")
    file
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end

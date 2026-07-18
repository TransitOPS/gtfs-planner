defmodule GtfsPlanner.Gtfs.ImportRunsTest do
  @moduledoc """
  Coupled import-run state machine: creation, lease-guarded transitions, races,
  reconciliation, recovery, and legacy adoption.

  Exercises the real Repo and PostgreSQL row locks / database-time leases.
  Concurrency uses `Task.async` + `Sandbox.allow` with no sleeps.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Failure, Result, Run}
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.OrganizationsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "operator@example.com"}
  @cleanup_actor %{id: Ecto.UUID.generate(), email: "cleaner@example.com"}

  defp expired_past, do: ~U[2000-01-01 00:00:00.000000Z]

  defp set_run_lease_expiry(run, expiry) do
    from(r in Run, where: r.id == ^run.id) |> Repo.update_all(set: [lease_expires_at: expiry])
    Repo.get!(Run, run.id)
  end

  defp make_failure(opts \\ []) do
    Failure.from_error(:unknown, opts)
  end

  describe "create_pending_target/3" do
    test "inserts a staging version and a pending run with a preparation lease" do
      org = organization_fixture()

      assert {:ok, %{run: run, version: version}} =
               ImportRuns.create_pending_target(org.id, @actor, %{name: "Spring 2024"})

      assert run.state == "pending"
      assert run.organization_id == org.id
      assert run.version_name == "Spring 2024"
      assert run.gtfs_version_id == version.id
      assert run.actor_id == @actor.id
      assert run.actor_email == @actor.email
      assert run.counts_complete == false
      assert not is_nil(run.lease_token)
      assert not is_nil(run.lease_expires_at)

      assert version.publication_status == "staging"
      assert is_nil(version.published_at)
      assert version.name == "Spring 2024"
    end

    test "returns an error changeset when the version name is invalid" do
      org = organization_fixture()

      assert {:error, changeset} =
               ImportRuns.create_pending_target(org.id, @actor, %{name: nil})

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "claim_import/3" do
    setup do
      org = organization_fixture()

      {:ok, %{run: run, version: version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})

      %{org: org, run: run, version: version, token: run.lease_token}
    end

    test "transitions pending -> running and staging -> importing with a fresh lease", %{
      org: org,
      run: run,
      token: token
    } do
      assert {:ok, claimed, version, new_token} =
               ImportRuns.claim_import(org.id, run.id, token)

      assert claimed.state == "running"
      assert claimed.id == run.id
      assert new_token != token
      assert claimed.lease_token == new_token
      assert not is_nil(claimed.started_at)
      assert version.publication_status == "importing"
    end

    test "rejects a wrong lease token and writes nothing", %{org: org, run: run} do
      assert {:error, :lease_lost} =
               ImportRuns.claim_import(org.id, run.id, Ecto.UUID.generate())

      reloaded = Repo.get!(Run, run.id)
      assert reloaded.state == "pending"
      assert Repo.get!(GtfsVersion, run.gtfs_version_id).publication_status == "staging"
    end

    test "rejects a cross-organization request", %{run: run, token: token} do
      other_org = organization_fixture()

      assert {:error, :not_found} = ImportRuns.claim_import(other_org.id, run.id, token)

      assert Repo.get!(Run, run.id).state == "pending"
    end

    test "rejects a non-pending run", %{org: org, run: run, token: token} do
      # claim once to leave running
      {:ok, _, _, new_token} = ImportRuns.claim_import(org.id, run.id, token)

      # a second claim with the now-stale original token
      assert {:error, :invalid_transition} =
               ImportRuns.claim_import(org.id, run.id, token)

      # a second claim with the valid new token (already running)
      assert {:error, :invalid_transition} =
               ImportRuns.claim_import(org.id, run.id, new_token)

      assert Repo.get!(Run, run.id).state == "running"
    end
  end

  describe "renew_lease/3" do
    setup do
      org = organization_fixture()
      {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})
      %{org: org, run: run, token: run.lease_token}
    end

    test "renews an active lease with database time", %{org: org, run: run, token: token} do
      assert :ok = ImportRuns.renew_lease(org.id, run.id, token)
      assert not is_nil(Repo.get!(Run, run.id).lease_expires_at)
    end

    test "rejects a wrong token", %{org: org, run: run} do
      assert {:error, :lease_lost} =
               ImportRuns.renew_lease(org.id, run.id, Ecto.UUID.generate())
    end

    test "rejects a terminal run", %{org: org, run: run} do
      # A published run has no lease, so renewal must fail closed.
      {:ok, %{run: pending, version: version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Other"})

      {:ok, _, _, exec_token} = ImportRuns.claim_import(org.id, pending.id, pending.lease_token)

      {:ok, _, _} =
        ImportRuns.publish_import(org.id, pending.id, exec_token, %Result{
          counts: %{routes: 1},
          unrecognized_files: [],
          topic: "import:x",
          archive_warnings: [],
          extensions: :not_present
        })

      assert {:error, :lease_lost} = ImportRuns.renew_lease(org.id, pending.id, exec_token)
      assert Repo.get!(Run, pending.id).state == "published"
      assert Repo.get!(GtfsVersion, version.id).publication_status == "published"
    end
  end

  describe "publish_import/4" do
    setup do
      org = organization_fixture()
      {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})
      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)
      %{org: org, run: run, token: token}
    end

    test "couples run -> published and version -> published with complete counts", %{
      org: org,
      run: run,
      token: token
    } do
      result = %Result{
        counts: %{routes: 3, stops: 10},
        unrecognized_files: [],
        topic: "import:p",
        archive_warnings: [],
        extensions: :not_present
      }

      assert {:ok, published_run, version} =
               ImportRuns.publish_import(org.id, run.id, token, result)

      assert published_run.state == "published"
      assert published_run.counts_complete == true
      assert published_run.committed_counts == %{"routes" => 3, "stops" => 10}
      assert not is_nil(published_run.finished_at)
      assert is_nil(published_run.lease_token)
      assert version.publication_status == "published"
      assert not is_nil(version.published_at)
    end

    test "a wrong token cannot publish", %{org: org, run: run} do
      result = %Result{
        counts: %{routes: 1},
        unrecognized_files: [],
        topic: "import:p",
        archive_warnings: [],
        extensions: :not_present
      }

      assert {:error, :invalid_transition} =
               ImportRuns.publish_import(org.id, run.id, Ecto.UUID.generate(), result)

      assert Repo.get!(Run, run.id).state == "running"
    end

    test "publish/fail race: publish wins under the lock", %{org: org, run: run, token: token} do
      result = %Result{
        counts: %{routes: 1},
        unrecognized_files: [],
        topic: "import:p",
        archive_warnings: [],
        extensions: :not_present
      }

      parent = self()

      publish_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        ImportRuns.publish_import(org.id, run.id, token, result)
      end

      fail_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())

        ImportRuns.fail_import(
          org.id,
          run.id,
          token,
          make_failure(phase: :phase_2, outcome: :partial)
        )
      end

      t1 = Task.async(publish_fn)
      t2 = Task.async(fail_fn)

      results = Task.await_many([t1, t2], 5000)

      wins = Enum.filter(results, &match?({:ok, _, _}, &1))
      losers = Enum.filter(results, &match?({:error, _}, &1))
      assert length(wins) == 1
      assert length(losers) == 1

      final = Repo.get!(Run, run.id)
      final_version = Repo.get!(GtfsVersion, run.gtfs_version_id)

      case final.state do
        "published" ->
          assert final_version.publication_status == "published"
          assert not is_nil(final_version.published_at)

        state when state in ~w(failed partial interrupted) ->
          assert final_version.publication_status == "failed"
          assert is_nil(final_version.published_at)
      end
    end
  end

  describe "fail_import/4" do
    setup do
      org = organization_fixture()
      {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})
      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)
      %{org: org, run: run, token: token}
    end

    test "sets a terminal failure state and fails the version", %{
      org: org,
      run: run,
      token: token
    } do
      failure =
        Failure.from_error(:unknown,
          phase: :phase_2,
          outcome: :partial,
          committed_counts: %{routes: 5, stops: 20}
        )

      assert {:ok, failed_run, version} =
               ImportRuns.fail_import(org.id, run.id, token, failure)

      assert failed_run.state == "partial"
      assert failed_run.committed_counts == %{"routes" => 5, "stops" => 20}
      assert failed_run.counts_complete == true
      assert not is_nil(failed_run.finished_at)
      assert is_nil(failed_run.lease_token)
      assert version.publication_status == "failed"
      assert is_nil(version.published_at)
    end

    test "a wrong token cannot fail", %{org: org, run: run} do
      failure = make_failure(phase: :phase_2, outcome: :failed)

      assert {:error, :invalid_transition} =
               ImportRuns.fail_import(org.id, run.id, Ecto.UUID.generate(), failure)

      assert Repo.get!(Run, run.id).state == "running"
    end
  end

  describe "record_publication_failure/5 and retry_publication/2" do
    setup do
      org = organization_fixture()
      {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})
      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)
      %{org: org, run: run, token: token}
    end

    test "records publication_failed with complete counts and leaves version importing", %{
      org: org,
      run: run,
      token: token
    } do
      result = %Result{
        counts: %{routes: 2},
        unrecognized_files: [],
        topic: "import:pf",
        archive_warnings: [],
        extensions: :not_present
      }

      assert {:ok, failed_run} =
               ImportRuns.record_publication_failure(
                 org.id,
                 run.id,
                 token,
                 result,
                 :database_error
               )

      assert failed_run.state == "publication_failed"
      assert failed_run.counts_complete == true
      assert failed_run.committed_counts == %{"routes" => 2}
      assert failed_run.reason_code == "database_error"
      assert not is_nil(failed_run.finished_at)
      assert Repo.get!(GtfsVersion, run.gtfs_version_id).publication_status == "importing"

      # retry publishes without invoking import_files
      assert {:ok, published_run, version} =
               ImportRuns.retry_publication(org.id, run.id)

      assert published_run.state == "published"
      assert version.publication_status == "published"
      assert not is_nil(version.published_at)
    end

    test "retry rejects a non-publication_failed run", %{org: org, run: run} do
      assert {:error, :invalid_transition} = ImportRuns.retry_publication(org.id, run.id)
      assert Repo.get!(Run, run.id).state == "running"
    end

    test "retry rejects when counts are incomplete", %{org: org, run: run, token: token} do
      incomplete =
        Failure.from_error(:unknown,
          phase: :publication,
          outcome: :interrupted,
          committed_counts: %{},
          counts_complete: false
        )

      {:ok, _, _} =
        ImportRuns.fail_import(org.id, run.id, token, incomplete)

      # The run is interrupted, not publication_failed; retry must refuse.
      assert {:error, :invalid_transition} = ImportRuns.retry_publication(org.id, run.id)
    end
  end

  describe "reconcile_expired/1" do
    test "moves expired pending/running to interrupted and fails the version (AC-7)", %{} do
      org = organization_fixture()

      {:ok, %{run: pending}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Pending"})

      {:ok, %{run: claimed}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Running"})

      {:ok, _, _, _} = ImportRuns.claim_import(org.id, claimed.id, claimed.lease_token)

      pending = set_run_lease_expiry(pending, expired_past())
      claimed = set_run_lease_expiry(claimed, expired_past())

      reconciled = ImportRuns.reconcile_expired(org.id) |> Enum.map(& &1.id) |> MapSet.new()

      assert MapSet.member?(reconciled, pending.id)
      assert MapSet.member?(reconciled, claimed.id)

      assert Repo.get!(Run, pending.id).state == "interrupted"
      assert Repo.get!(Run, pending.id).counts_complete == false
      assert Repo.get!(GtfsVersion, pending.gtfs_version_id).publication_status == "failed"

      assert Repo.get!(Run, claimed.id).state == "interrupted"
      assert Repo.get!(GtfsVersion, claimed.gtfs_version_id).publication_status == "failed"
    end

    test "refuses a fresh lease on an expired run (AC-8)", %{} do
      org = organization_fixture()

      {:ok, %{run: pending}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Pending"})

      pending = set_run_lease_expiry(pending, expired_past())

      assert {:error, :lease_lost} =
               ImportRuns.renew_lease(org.id, pending.id, pending.lease_token)
    end

    test "refuses reconciliation of a terminal run (AC-8)", %{} do
      org = organization_fixture()
      {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "Pending"})

      # Non-expired; reconciliation must not touch it.
      assert ImportRuns.reconcile_expired(org.id) == []

      assert Repo.get!(Run, run.id).state == "pending"
    end

    test "an expired cleaning lease becomes cleanup_failed (AC-11)", %{} do
      org = organization_fixture()

      {:ok, %{run: run, version: version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})

      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

      {:ok, _, _} =
        ImportRuns.fail_import(
          org.id,
          run.id,
          token,
          make_failure(phase: :phase_2, outcome: :failed)
        )

      {:ok, _, _, cleanup_token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      run = set_run_lease_expiry(Repo.get!(Run, run.id), expired_past())

      reconciled = ImportRuns.reconcile_expired(org.id)
      assert Enum.any?(reconciled, fn r -> r.id == run.id end)

      assert Repo.get!(Run, run.id).state == "cleanup_failed"
      # version remains failed
      assert Repo.get!(GtfsVersion, version.id).publication_status == "failed"
      # cleanup_failed is retryable: a fresh claim succeeds and re-issues a lease
      assert {:ok, reclaimed, _, _} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)
      assert reclaimed.state == "cleaning"
      _ = cleanup_token
    end
  end

  describe "claim_cleanup/3" do
    setup do
      org = organization_fixture()

      {:ok, %{run: run, version: version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})

      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

      {:ok, _, _} =
        ImportRuns.fail_import(
          org.id,
          run.id,
          token,
          make_failure(phase: :phase_2, outcome: :failed)
        )

      %{org: org, run: run, version: version}
    end

    test "grants exactly one cleaning lease", %{org: org, run: run, version: version} do
      assert {:ok, cleaning, claimed_version, cleanup_token} =
               ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert cleaning.state == "cleaning"
      assert not is_nil(cleaning.cleanup_started_at)
      assert cleaning.cleanup_actor_id == @cleanup_actor.id
      assert cleaning.cleanup_actor_email == @cleanup_actor.email
      assert claimed_version.id == version.id
      assert not is_nil(cleanup_token)
    end

    test "a competitor receives already_claimed", %{org: org, run: run} do
      {:ok, _, _, _} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert {:error, :already_claimed} =
               ImportRuns.claim_cleanup(org.id, run.id, %{
                 id: Ecto.UUID.generate(),
                 email: "rival@example.com"
               })
    end

    test "rejects a terminal (published) run", %{org: org} do
      {:ok, %{run: run, version: version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Pub"})

      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

      {:ok, _, _} =
        ImportRuns.publish_import(org.id, run.id, token, %Result{
          counts: %{routes: 1},
          unrecognized_files: [],
          topic: "import:z",
          archive_warnings: [],
          extensions: :not_present
        })

      assert {:error, :invalid_transition} =
               ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)

      assert Repo.get!(GtfsVersion, version.id).publication_status == "published"
    end
  end

  describe "finish_cleanup/3 and fail_cleanup/4" do
    setup do
      org = organization_fixture()

      {:ok, %{run: run, version: version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})

      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

      {:ok, _, _} =
        ImportRuns.fail_import(
          org.id,
          run.id,
          token,
          make_failure(phase: :phase_2, outcome: :failed)
        )

      {:ok, _, _, cleanup_token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)
      %{org: org, run: run, version: version, cleanup_token: cleanup_token}
    end

    test "finish_cleanup atomically deletes the version, marks cleaned, and clears the lease", %{
      org: org,
      run: run,
      version: version,
      cleanup_token: cleanup_token
    } do
      assert {:ok, cleaned} = ImportRuns.finish_cleanup(org.id, run.id, cleanup_token)

      assert cleaned.state == "cleaned"
      assert not is_nil(cleaned.cleanup_finished_at)
      assert is_nil(cleaned.lease_token)
      refute Repo.get(GtfsVersion, version.id)
    end

    test "a wrong cleanup token cannot finish", %{org: org, run: run} do
      assert {:error, :invalid_transition} =
               ImportRuns.finish_cleanup(org.id, run.id, Ecto.UUID.generate())

      assert Repo.get!(Run, run.id).state == "cleaning"
    end

    test "fail_cleanup moves to cleanup_failed", %{
      org: org,
      run: run,
      cleanup_token: cleanup_token
    } do
      assert {:ok, failed} =
               ImportRuns.fail_cleanup(org.id, run.id, cleanup_token, :filesystem_error)

      assert failed.state == "cleanup_failed"
      assert failed.reason_code == "filesystem_error"
      assert is_nil(failed.lease_token)
    end
  end

  describe "publish/cleanup race" do
    test "publish and cleanup cannot both win on a publication_failed run (AC-10)", %{} do
      org = organization_fixture()
      {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "Feed"})
      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

      {:ok, _} =
        ImportRuns.record_publication_failure(
          org.id,
          run.id,
          token,
          %Result{
            counts: %{routes: 1},
            unrecognized_files: [],
            topic: "import:pc",
            archive_warnings: [],
            extensions: :not_present
          },
          :database_error
        )

      parent = self()

      publish_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        ImportRuns.retry_publication(org.id, run.id)
      end

      cleanup_fn = fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)
      end

      t1 = Task.async(publish_fn)
      t2 = Task.async(cleanup_fn)

      results = Task.await_many([t1, t2], 5000)

      wins = Enum.filter(results, &match?({:ok, _, _}, &1))
      losers = Enum.filter(results, &match?({:error, _}, &1))
      assert length(wins) == 1
      assert length(losers) == 1

      final = Repo.get!(Run, run.id)
      final_version = Repo.get!(GtfsVersion, run.gtfs_version_id)

      case final.state do
        "published" ->
          assert final_version.publication_status == "published"

        "cleaning" ->
          assert final_version.publication_status == "importing"
      end
    end
  end

  describe "legacy adoption and recoverable queries" do
    test "adopt_legacy_failed_targets creates interrupted runs idempotently (AC-19)", %{} do
      org = organization_fixture()
      {:ok, v1} = Versions.create_staging_gtfs_version(org.id, %{name: "Legacy 1"})
      {:ok, v1} = Versions.fail_unpublished_gtfs_version(org.id, v1.id)
      {:ok, v2} = Versions.create_staging_gtfs_version(org.id, %{name: "Legacy 2"})
      {:ok, v2} = Versions.fail_unpublished_gtfs_version(org.id, v2.id)

      # A failed version that already has a run must be skipped.
      {:ok, %{run: existing, version: ev}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Has Run"})

      {:ok, _, _, token} = ImportRuns.claim_import(org.id, existing.id, existing.lease_token)

      {:ok, _, _} =
        ImportRuns.fail_import(
          org.id,
          existing.id,
          token,
          make_failure(phase: :phase_1, outcome: :failed)
        )

      adopted = ImportRuns.adopt_legacy_failed_targets(org.id)
      adopted_ids = Enum.map(adopted, & &1.gtfs_version_id) |> MapSet.new()

      assert MapSet.member?(adopted_ids, v1.id)
      assert MapSet.member?(adopted_ids, v2.id)
      refute MapSet.member?(adopted_ids, ev.id)

      for run <- adopted do
        assert run.state == "interrupted"
        assert run.counts_complete == false
        assert run.committed_counts == %{}
        assert is_nil(run.actor_id)
        assert is_nil(run.actor_email)
      end

      # Idempotent: a second call adopts nothing new.
      adopted_again = ImportRuns.adopt_legacy_failed_targets(org.id)
      assert Enum.empty?(adopted_again)

      assert length(ImportRuns.list_recoverable(org.id)) ==
               length(adopted) + 1
    end

    test "list_recoverable excludes published and cleaned", %{} do
      org = organization_fixture()
      {:ok, %{run: pending}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "P"})
      {:ok, %{run: run}} = ImportRuns.create_pending_target(org.id, @actor, %{name: "F"})
      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

      {:ok, _, _} =
        ImportRuns.fail_import(
          org.id,
          run.id,
          token,
          make_failure(phase: :phase_2, outcome: :failed)
        )

      {:ok, _, _, cleanup_token} = ImportRuns.claim_cleanup(org.id, run.id, @cleanup_actor)
      {:ok, _} = ImportRuns.finish_cleanup(org.id, run.id, cleanup_token)

      recoverable = ImportRuns.list_recoverable(org.id) |> Enum.map(& &1.id)
      assert pending.id in recoverable
      refute run.id in recoverable
    end
  end

  describe "audit retention" do
    test "audit fields survive version deletion (AC-13)", %{} do
      org = organization_fixture()

      {:ok, %{run: run, version: version}} =
        ImportRuns.create_pending_target(org.id, @actor, %{name: "Doomed"})

      {:ok, _, _, token} = ImportRuns.claim_import(org.id, run.id, run.lease_token)

      {:ok, _, _} =
        ImportRuns.fail_import(
          org.id,
          run.id,
          token,
          make_failure(phase: :phase_2, outcome: :failed)
        )

      # Simulate Recovery deleting the version row (step 7 ownership).
      {1, _} = Repo.delete_all(from(v in GtfsVersion, where: v.id == ^version.id))

      reloaded = Repo.get!(Run, run.id)
      assert reloaded.gtfs_version_id == version.id
      assert reloaded.version_name == "Doomed"
      assert reloaded.actor_id == @actor.id
      assert reloaded.actor_email == @actor.email
      assert reloaded.state == "failed"
    end
  end

  describe "topic/1" do
    test "returns the stable topic for a run or id" do
      run = %Run{id: "abc-123"}
      assert ImportRuns.topic(run) == "import:abc-123"
      assert ImportRuns.topic("xyz") == "import:xyz"
    end
  end
end

defmodule GtfsPlanner.Validations.LeaseTest do
  @moduledoc """
  Fenced lease transitions for validation runs.

  Runs against the real Repo with the SQL sandbox. Lease expiry is set directly in
  the database, and expected expiry times come from PostgreSQL's own clock, never
  the test process's.
  """

  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @expired ~U[2000-01-01 00:00:00.000000Z]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "mobility_data")

    %{organization: organization, version: version, run: run}
  end

  defp claim!(organization, run) do
    {:ok, claimed, token} = Validations.claim_run(organization.id, run.id)
    {claimed, token}
  end

  defp set_lease_expiry(run, expiry) do
    from(r in ValidationRun, where: r.id == ^run.id)
    |> Repo.update_all(set: [lease_expires_at: expiry])

    Repo.get!(ValidationRun, run.id)
  end

  # The sandbox holds one transaction for the whole test, so CURRENT_TIMESTAMP is
  # the same instant for every statement the test and the code under test run.
  defp database_now do
    %Postgrex.Result{rows: [[now]]} = Repo.query!("SELECT CURRENT_TIMESTAMP")
    now
  end

  defp lease_seconds, do: Application.fetch_env!(:gtfs_planner, :validation_lease_seconds)

  defp result do
    %Result{
      summary: %{errors: 1, warnings: 2, infos: 3},
      notices: [
        %{"code" => "missing_required_field", "severity" => "ERROR", "totalNotices" => 1}
      ],
      duration_ms: 1500,
      validated_at: ~U[2026-01-01 00:00:00.000000Z]
    }
  end

  describe "claim_run/2" do
    test "moves a started run to running with a new token and a database-time lease", %{
      organization: organization,
      run: run
    } do
      assert {:ok, claimed, token} = Validations.claim_run(organization.id, run.id)

      assert claimed.status == "running"
      assert claimed.lease_token == token
      assert {:ok, _} = Ecto.UUID.cast(token)
      assert claimed.lease_expires_at == DateTime.add(database_now(), lease_seconds(), :second)
      assert Repo.get!(ValidationRun, run.id).lease_token == token
    end

    test "returns :invalid_transition for a second claim and keeps the first owner's lease", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)

      assert Validations.claim_run(organization.id, run.id) == {:error, :invalid_transition}
      assert Repo.get!(ValidationRun, run.id) == claimed
    end

    test "returns :not_found for a run of another organization and leaves it started", %{
      run: run
    } do
      other_organization = organization_fixture()

      assert Validations.claim_run(other_organization.id, run.id) == {:error, :not_found}
      assert Repo.get!(ValidationRun, run.id) == run
    end
  end

  describe "renew_lease/3" do
    test "extends the lease of the current owner", %{organization: organization, run: run} do
      {claimed, token} = claim!(organization, run)
      set_lease_expiry(claimed, DateTime.add(database_now(), 10, :second))

      assert Validations.renew_lease(organization.id, run.id, token) == :ok

      assert Repo.get!(ValidationRun, run.id).lease_expires_at ==
               DateTime.add(database_now(), lease_seconds(), :second)
    end

    test "returns :lease_lost for a stale token and leaves the lease unchanged", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)
      claimed = set_lease_expiry(claimed, DateTime.add(database_now(), 10, :second))

      assert Validations.renew_lease(organization.id, run.id, Ecto.UUID.generate()) ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == claimed
    end

    test "returns :lease_lost once the lease expired and leaves it expired", %{
      organization: organization,
      run: run
    } do
      {claimed, token} = claim!(organization, run)
      expired = set_lease_expiry(claimed, @expired)

      assert Validations.renew_lease(organization.id, run.id, token) == {:error, :lease_lost}
      assert Repo.get!(ValidationRun, run.id) == expired
    end
  end

  describe "complete_run/4" do
    test "stores the result, clears the lease and marks the run completed", %{
      organization: organization,
      run: run
    } do
      {_claimed, token} = claim!(organization, run)

      assert {:ok, completed} = Validations.complete_run(organization.id, run.id, token, result())

      assert completed.status == "completed"
      assert completed.errors_count == 1
      assert completed.warnings_count == 2
      assert completed.infos_count == 3
      assert completed.duration_ms == 1500
      assert completed.completed_at

      persisted = Repo.get!(ValidationRun, run.id)
      assert persisted.result_json == %{"notices" => result().notices}
      assert persisted.lease_token == nil
      assert persisted.lease_expires_at == nil
    end

    test "returns :lease_lost for a stale token and leaves the row unchanged", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)

      assert Validations.complete_run(organization.id, run.id, Ecto.UUID.generate(), result()) ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == claimed
    end

    test "returns :lease_lost after the lease expired and leaves the row unchanged", %{
      organization: organization,
      run: run
    } do
      {claimed, token} = claim!(organization, run)
      expired = set_lease_expiry(claimed, @expired)

      assert Validations.complete_run(organization.id, run.id, token, result()) ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == expired
    end

    test "returns :lease_lost for another organization and leaves the row unchanged", %{
      organization: organization,
      run: run
    } do
      {claimed, token} = claim!(organization, run)
      other_organization = organization_fixture()

      assert Validations.complete_run(other_organization.id, run.id, token, result()) ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == claimed
    end

    test "a second completion returns :lease_lost and keeps the first result", %{
      organization: organization,
      run: run
    } do
      {_claimed, token} = claim!(organization, run)
      {:ok, completed} = Validations.complete_run(organization.id, run.id, token, result())

      assert Validations.complete_run(organization.id, run.id, token, %{
               result()
               | summary: %{errors: 9, warnings: 9, infos: 9}
             }) == {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == completed
    end

    test "a worker whose lease was reconciled cannot complete the run", %{
      organization: organization,
      run: run
    } do
      {claimed, token} = claim!(organization, run)
      set_lease_expiry(claimed, @expired)
      [reconciled] = Validations.reconcile_expired(organization.id)

      assert Validations.complete_run(organization.id, run.id, token, result()) ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == reconciled
      assert reconciled.status == "failed"
    end
  end

  describe "fail_run/4" do
    test "stores a string reason, clears the lease and marks the run failed", %{
      organization: organization,
      run: run
    } do
      {_claimed, token} = claim!(organization, run)

      assert {:ok, failed} = Validations.fail_run(organization.id, run.id, token, "executor_lost")

      assert failed.status == "failed"
      assert failed.error_details == "executor_lost"
      assert failed.completed_at

      persisted = Repo.get!(ValidationRun, run.id)
      assert persisted.lease_token == nil
      assert persisted.lease_expires_at == nil
    end

    test "stores an atom reason by name", %{organization: organization, run: run} do
      {_claimed, token} = claim!(organization, run)

      assert {:ok, failed} = Validations.fail_run(organization.id, run.id, token, :timeout)
      assert failed.error_details == "timeout"
    end

    test "stores any other reason with inspect", %{organization: organization, run: run} do
      {_claimed, token} = claim!(organization, run)

      assert {:ok, failed} =
               Validations.fail_run(organization.id, run.id, token, {:invalid_report, :truncated})

      assert failed.error_details == "{:invalid_report, :truncated}"
    end

    test "returns :lease_lost for a stale token and leaves the row unchanged", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)

      assert Validations.fail_run(organization.id, run.id, Ecto.UUID.generate(), "late") ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == claimed
    end

    test "returns :lease_lost after the lease expired and leaves the row unchanged", %{
      organization: organization,
      run: run
    } do
      {claimed, token} = claim!(organization, run)
      expired = set_lease_expiry(claimed, @expired)

      assert Validations.fail_run(organization.id, run.id, token, "late") ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == expired
    end

    test "cannot overwrite a completed run", %{organization: organization, run: run} do
      {_claimed, token} = claim!(organization, run)
      {:ok, completed} = Validations.complete_run(organization.id, run.id, token, result())

      assert Validations.fail_run(organization.id, run.id, token, "late") ==
               {:error, :lease_lost}

      assert Repo.get!(ValidationRun, run.id) == completed
    end
  end

  describe "fail_unstarted/3" do
    test "moves a started run to failed with the reason", %{organization: organization, run: run} do
      assert {:ok, failed} = Validations.fail_unstarted(organization.id, run.id, "busy")

      assert failed.status == "failed"
      assert failed.error_details == "busy"
      assert failed.completed_at
      assert Repo.get!(ValidationRun, run.id).status == "failed"
    end

    test "returns :invalid_transition for a claimed run and leaves it running", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)

      assert Validations.fail_unstarted(organization.id, run.id, "busy") ==
               {:error, :invalid_transition}

      assert Repo.get!(ValidationRun, run.id) == claimed
    end

    test "returns :not_found for a run of another organization and leaves it started", %{
      run: run
    } do
      other_organization = organization_fixture()

      assert Validations.fail_unstarted(other_organization.id, run.id, "busy") ==
               {:error, :not_found}

      assert Repo.get!(ValidationRun, run.id) == run
    end
  end

  describe "reconcile_expired/1" do
    test "fails an expired running run with error_details lease_expired", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)
      set_lease_expiry(claimed, @expired)

      assert [reconciled] = Validations.reconcile_expired(organization.id)

      assert reconciled.id == run.id
      assert reconciled.status == "failed"
      assert reconciled.error_details == "lease_expired"
      assert reconciled.completed_at

      persisted = Repo.get!(ValidationRun, run.id)
      assert persisted.status == "failed"
      assert persisted.lease_token == nil
      assert persisted.lease_expires_at == nil
    end

    test "leaves live, unstarted, lease-less and other-organization runs unchanged", %{
      organization: organization,
      version: version,
      run: unstarted
    } do
      {:ok, live} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      {live, _token} = claim!(organization, live)

      # A station reachability run is inserted as running and never carries a lease.
      leaseless =
        %ValidationRun{organization_id: organization.id, gtfs_version_id: version.id}
        |> ValidationRun.changeset(%{
          run_type: "station_reachability",
          status: "running",
          engine: "pathways_router",
          result_schema_version: 1,
          started_at: DateTime.utc_now(),
          result_json: %{"metadata" => %{"station_stop_id" => "station-1"}}
        })
        |> Repo.insert!()

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, foreign} =
        Validations.create_validation_run(
          other_organization.id,
          other_version.id,
          "mobility_data"
        )

      {foreign, _token} = claim!(other_organization, foreign)
      foreign = set_lease_expiry(foreign, @expired)

      assert Validations.reconcile_expired(organization.id) == []

      assert Repo.get!(ValidationRun, unstarted.id) == unstarted
      assert Repo.get!(ValidationRun, live.id) == live
      assert Repo.get!(ValidationRun, leaseless.id) == leaseless
      assert Repo.get!(ValidationRun, foreign.id) == foreign
    end

    test "a second reconcile finds nothing left to fail", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)
      set_lease_expiry(claimed, @expired)
      [_reconciled] = Validations.reconcile_expired(organization.id)

      assert Validations.reconcile_expired(organization.id) == []
    end
  end

  describe "broadcasts on the validation topic" do
    setup %{run: run} do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Validations.topic(run.id))
    end

    test "completion arrives when the row already reads completed", %{
      organization: organization,
      run: run
    } do
      {_claimed, token} = claim!(organization, run)
      run_id = run.id

      {:ok, _completed} = Validations.complete_run(organization.id, run.id, token, result())

      assert_receive {:validation_completed, ^run_id}
      assert Repo.get!(ValidationRun, run.id).status == "completed"
    end

    test "a refused completion broadcasts nothing", %{organization: organization, run: run} do
      {_claimed, _token} = claim!(organization, run)

      {:error, :lease_lost} =
        Validations.complete_run(organization.id, run.id, Ecto.UUID.generate(), result())

      refute_received {:validation_completed, _run_id}
      refute_received {:validation_failed, _run_id}
    end

    test "fail_run broadcasts a failure", %{organization: organization, run: run} do
      {_claimed, token} = claim!(organization, run)
      run_id = run.id

      {:ok, _failed} = Validations.fail_run(organization.id, run.id, token, "executor_lost")

      assert_receive {:validation_failed, ^run_id}
      assert Repo.get!(ValidationRun, run.id).status == "failed"
    end

    test "fail_unstarted broadcasts a failure", %{organization: organization, run: run} do
      run_id = run.id

      {:ok, _failed} = Validations.fail_unstarted(organization.id, run.id, "busy")

      assert_receive {:validation_failed, ^run_id}
    end

    test "reconcile_expired broadcasts a failure for each reconciled run", %{
      organization: organization,
      run: run
    } do
      {claimed, _token} = claim!(organization, run)
      set_lease_expiry(claimed, @expired)
      run_id = run.id

      [_reconciled] = Validations.reconcile_expired(organization.id)

      assert_receive {:validation_failed, ^run_id}
      refute_received {:validation_completed, _run_id}
    end

    test "claim and renew broadcast nothing", %{organization: organization, run: run} do
      {_claimed, token} = claim!(organization, run)
      :ok = Validations.renew_lease(organization.id, run.id, token)

      refute_received {:validation_completed, _run_id}
      refute_received {:validation_failed, _run_id}
    end
  end
end

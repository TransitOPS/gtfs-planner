defmodule GtfsPlanner.Gtfs.MaintenanceRunsTest do
  @moduledoc """
  Periodic maintenance recovers import runs, validation runs and import source
  directories for organizations that have no change or export runs, without a
  LiveView mount.

  `maintain/0` is called directly because the GenServer is disabled in test config.
  Lease expiry is written to the database; sleeping cannot expire a lease in the
  sandbox, where `CURRENT_TIMESTAMP` is fixed for the whole test.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Import.{ChangeRun, SourceStorage}
  alias GtfsPlanner.Gtfs.Import.Run, as: ImportRun
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Gtfs.TaskArtifactMaintenance
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun
  alias GtfsPlanner.Versions.GtfsVersion

  @expired ~U[2000-01-01 00:00:00.000000Z]
  @long_ago {{2000, 1, 1}, {0, 0, 0}}

  setup do
    root = Path.join(System.tmp_dir!(), "maintenance-runs-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    previous = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous)
    end)

    organization = organization_fixture()
    editor = editor_fixture(organization)

    %{organization: organization, actor: %{id: editor.id, email: editor.email}}
  end

  describe "import runs" do
    test "interrupts an expired running import run of an organization with no change or export runs",
         %{organization: organization, actor: actor} do
      run = running_import_run!(organization, actor)
      expire_lease!(ImportRun, run.id)
      refute Repo.exists?(from r in ChangeRun, where: r.organization_id == ^organization.id)
      refute Repo.exists?(from r in Export.Run, where: r.organization_id == ^organization.id)

      assert :ok = TaskArtifactMaintenance.maintain()

      interrupted = Repo.get!(ImportRun, run.id)
      assert interrupted.state == "interrupted"
      assert interrupted.lease_token == nil
      assert interrupted.lease_expires_at == nil
      assert Repo.get!(GtfsVersion, run.gtfs_version_id).publication_status == "failed"
    end

    test "keeps a running import run whose lease has not expired", %{
      organization: organization,
      actor: actor
    } do
      run = running_import_run!(organization, actor)

      assert :ok = TaskArtifactMaintenance.maintain()

      kept = Repo.get!(ImportRun, run.id)
      assert kept.state == "running"
      assert kept.lease_token == run.lease_token
      assert kept.lease_expires_at == run.lease_expires_at
    end
  end

  describe "validation runs" do
    test "fails an expired running validation run with lease_expired", %{
      organization: organization
    } do
      run = running_validation_run!(organization)
      expire_lease!(ValidationRun, run.id)

      assert :ok = TaskArtifactMaintenance.maintain()

      failed = Repo.get!(ValidationRun, run.id)
      assert failed.status == "failed"
      assert failed.error_details == "lease_expired"
      assert failed.lease_token == nil
    end

    test "keeps a running validation run whose lease has not expired", %{
      organization: organization
    } do
      run = running_validation_run!(organization)

      assert :ok = TaskArtifactMaintenance.maintain()

      kept = Repo.get!(ValidationRun, run.id)
      assert kept.status == "running"
      assert kept.lease_token == run.lease_token
      assert kept.lease_expires_at == run.lease_expires_at
    end
  end

  describe "import source directories" do
    test "removes an orphan source directory older than the orphan grace", %{
      organization: organization
    } do
      directory = source_directory!(organization, Ecto.UUID.generate())
      File.touch!(directory, @long_ago)

      assert :ok = TaskArtifactMaintenance.maintain()

      refute File.exists?(directory)
    end

    test "keeps an orphan source directory younger than the orphan grace", %{
      organization: organization
    } do
      directory = source_directory!(organization, Ecto.UUID.generate())

      assert :ok = TaskArtifactMaintenance.maintain()

      assert File.dir?(directory)
    end

    test "keeps the source directory of a pending import run older than the orphan grace", %{
      organization: organization,
      actor: actor
    } do
      {:ok, %{run: run}} =
        ImportRuns.create_pending_target(organization.id, actor, %{name: "Feed"})

      directory = source_directory!(organization, run.id)
      File.touch!(directory, @long_ago)

      assert :ok = TaskArtifactMaintenance.maintain()

      assert File.dir?(directory)
      assert Repo.get!(ImportRun, run.id).state == "pending"
    end

    test "removes the source directory of an import run that the same sweep interrupts", %{
      organization: organization,
      actor: actor
    } do
      run = running_import_run!(organization, actor)
      directory = source_directory!(organization, run.id)
      File.touch!(directory, @long_ago)
      expire_lease!(ImportRun, run.id)

      assert :ok = TaskArtifactMaintenance.maintain()

      assert Repo.get!(ImportRun, run.id).state == "interrupted"
      refute File.exists?(directory)
    end
  end

  defp running_import_run!(organization, actor) do
    {:ok, %{run: pending}} =
      ImportRuns.create_pending_target(organization.id, actor, %{name: "Feed"})

    {:ok, running, _version, _token} =
      ImportRuns.claim_import(organization.id, pending.id, pending.lease_token)

    running
  end

  defp running_validation_run!(organization) do
    version = gtfs_version_fixture(organization.id)

    {:ok, started} =
      Validations.create_validation_run(organization.id, version.id, "mobility_data")

    {:ok, running, _token} = Validations.claim_run(organization.id, started.id)
    running
  end

  defp expire_lease!(schema, run_id) do
    {1, nil} =
      from(r in schema, where: r.id == ^run_id)
      |> Repo.update_all(set: [lease_expires_at: @expired])
  end

  defp source_directory!(organization, run_id) do
    {:ok, directory} = SourceStorage.run_dir(organization.id, run_id)
    File.mkdir_p!(Path.join(directory, "source"))
    directory
  end
end

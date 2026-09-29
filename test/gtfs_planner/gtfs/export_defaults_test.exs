defmodule GtfsPlanner.Gtfs.ExportDefaultsTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportDefault
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    root =
      Path.join(System.tmp_dir!(), "export-defaults-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if old_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, old_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    :ok
  end

  describe "get/1" do
    test "returns include_flex true and realtime_source :unsure without inserting a row" do
      organization = organization_fixture()

      defaults = ExportDefaults.get(organization.id)

      assert defaults.include_flex == true
      assert defaults.realtime_source == :unsure
      assert defaults.organization_id == organization.id
      refute Repo.get_by(ExportDefault, organization_id: organization.id)
    end
  end

  describe "update/2" do
    test "upserts so a second update changes the same row and keeps an omitted setting" do
      organization = organization_fixture()

      assert {:ok, created} =
               ExportDefaults.update(organization.id, %{
                 include_flex: false,
                 realtime_source: :own
               })

      assert created.include_flex == false
      assert created.realtime_source == :own

      assert {:ok, updated} = ExportDefaults.update(organization.id, %{include_flex: true})

      assert updated.id == created.id
      assert updated.include_flex == true
      assert updated.realtime_source == :own

      assert Repo.aggregate(
               from(default in ExportDefault,
                 where: default.organization_id == ^organization.id
               ),
               :count
             ) == 1
    end

    test "an unknown realtime source is an invalid changeset and writes nothing" do
      organization = organization_fixture()

      assert {:error, changeset} =
               ExportDefaults.update(organization.id, %{realtime_source: "bogus"})

      refute changeset.valid?
      assert %{realtime_source: ["is invalid"]} = errors_on(changeset)
      refute Repo.get_by(ExportDefault, organization_id: organization.id)
    end

    test "one organization's defaults do not change another organization's" do
      organization_a = organization_fixture()
      organization_b = organization_fixture()

      assert {:ok, _} =
               ExportDefaults.update(organization_a.id, %{
                 include_flex: false,
                 realtime_source: :flex
               })

      assert ExportDefaults.get(organization_a.id).include_flex == false
      assert ExportDefaults.get(organization_a.id).realtime_source == :flex

      other = ExportDefaults.get(organization_b.id)
      assert other.include_flex == true
      assert other.realtime_source == :unsure
      refute Repo.get_by(ExportDefault, organization_id: organization_b.id)
    end
  end

  describe "run creation" do
    test "a full run records the stored include_flex value at creation" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:ok, _} = ExportDefaults.update(organization.id, %{include_flex: false})

      assert {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
      assert run.include_flex == false

      assert {:ok, cancelled} = ExportRuns.request_cancel(organization.id, run.id)
      assert cancelled.state == :cancelled

      assert {:ok, _} = ExportDefaults.update(organization.id, %{include_flex: true})

      assert {:ok, next_run} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :full)

      assert next_run.id != run.id
      assert next_run.include_flex == true
    end

    test "an operations run records the switch and a pathways run never carries flex" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:ok, _} = ExportDefaults.update(organization.id, %{include_flex: true})

      assert {:ok, operations} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :operations)

      assert operations.include_flex == true

      assert {:ok, pathways} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :pathways)

      assert pathways.include_flex == false
    end

    test "a retried full run records the switch value at creation" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
      assert run.include_flex == true

      assert {:ok, _building, generation, token} =
               ExportRuns.claim(organization.id, run.id, :build)

      assert {:ok, failed} =
               ExportRuns.fail_build(organization.id, run.id, generation, token, "build_failed")

      assert failed.state == :failed

      assert {:ok, _} = ExportDefaults.update(organization.id, %{include_flex: false})

      assert {:ok, retried} = ExportRuns.retry(organization.id, run.id)
      assert retried.id != run.id
      assert retried.include_flex == false
    end

    test "public params cannot change the recorded switch" do
      changeset = Run.changeset(%Run{include_flex: false}, %{include_flex: true})

      assert changeset.changes == %{}
    end
  end
end

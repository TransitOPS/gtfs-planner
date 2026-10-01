defmodule GtfsPlannerWeb.Gtfs.ImportLiveBusyTest do
  @moduledoc """
  ImportLive while the import and change runner supervisors are full. A blocking
  worker holds the only slot; the page says another job is running, closes the run
  that never started, and keeps what the person chose so the same action works
  once the slot is free.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Import.{ChangeRun, ChangeRunner, ChangeRuns}
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.Import.Runner
  alias GtfsPlanner.Gtfs.Import.SourceStorage
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.{BlockingImportWorker, BlockingJobWorker, RunnerSlots}
  alias GtfsPlanner.Versions.GtfsVersion

  @import_busy "Another import is running. Try again when it finishes."
  @change_busy "Another change review is running. Try again when it finishes."
  @levels "level_id,level_index,level_name\nL1,0.0,Ground"

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    previous = %{
      import_worker: Application.fetch_env(:gtfs_planner, :import_worker_module),
      import_owner: Application.fetch_env(:gtfs_planner, :blocking_import_worker_owner),
      job_owner: Application.fetch_env(:gtfs_planner, :blocking_job_worker_owner)
    }

    Application.put_env(:gtfs_planner, :import_worker_module, BlockingImportWorker)
    Application.put_env(:gtfs_planner, :blocking_import_worker_owner, self())
    Application.put_env(:gtfs_planner, :blocking_job_worker_owner, self())

    on_exit(fn ->
      RunnerSlots.await_idle()
      restore_env(:import_worker_module, previous.import_worker)
      restore_env(:blocking_import_worker_owner, previous.import_owner)
      restore_env(:blocking_job_worker_owner, previous.job_owner)
    end)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  describe "a feed import while another import is running" do
    test "keeps the chosen file and name, and closes the run it never started", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {_runner, _worker} = hold_import_slot(organization, user)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      upload_feed(view)
      submit_import(view, "Busy Feed")

      assert has_element?(view, "#flash-error", @import_busy)
      assert has_element?(view, "#gtfs-import-upload-entries", "levels.txt")
      assert has_element?(view, "#gtfs-import-version-name[value='Busy Feed']")
      refute has_element?(view, "#gtfs-import-submit[disabled]")
      refute has_element?(view, "#gtfs-importing-card")

      run = Repo.get_by!(Run, organization_id: organization.id, version_name: "Busy Feed")
      assert %Run{state: "failed", reason_code: "busy"} = run
      assert Repo.get(GtfsVersion, run.gtfs_version_id) == nil
      refute has_element?(view, "#import-run-#{run.id}")

      {:ok, run_dir} = SourceStorage.run_dir(organization.id, run.id)
      refute File.exists?(run_dir)
    end

    test "starts with the same file and name once the first import has finished", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {runner, worker} = hold_import_slot(organization, user)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")
      upload_feed(view)
      submit_import(view, "Busy Feed")
      assert has_element?(view, "#flash-error", @import_busy)

      release(runner, worker)
      submit_import(view, "Busy Feed")

      assert_receive {:blocking_import_worker_started, second_worker}, 2_000
      on_exit(fn -> send(second_worker, :finish) end)
      assert has_element?(view, "#gtfs-importing-card", "Busy Feed")

      states =
        Repo.all(
          from(r in Run,
            where: r.organization_id == ^organization.id and r.version_name == "Busy Feed",
            select: r.state
          )
        )

      assert Enum.sort(states) == ["failed", "running"]
    end
  end

  describe "deleting a failed import while another import is running" do
    test "says another import is running and leaves the failed version", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      actor = %{id: user.id, email: user.email}

      {:ok, %{run: stopped}} =
        ImportRuns.create_pending_target(organization.id, actor, %{name: "Stopped Feed"})

      {:ok, _run, _version} =
        ImportRuns.fail_pending_target(
          organization.id,
          stopped.id,
          stopped.lease_token,
          :upload_consumption_failed
        )

      {_runner, _worker} = hold_import_slot(organization, user)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")
      assert has_element?(view, "#import-run-#{stopped.id}")

      render_click(view, "begin_discard", %{"run_id" => stopped.id})
      render_click(view, "delete_version", %{"run_id" => stopped.id})

      assert has_element?(view, "#import-recovery-error", @import_busy)
      assert has_element?(view, "#import-run-#{stopped.id}")
      assert %Run{state: "failed"} = Repo.get!(Run, stopped.id)
      assert %GtfsVersion{} = Repo.get!(GtfsVersion, stopped.gtfs_version_id)
    end
  end

  describe "a station change review while another review is running" do
    test "closes the review as busy and retries it from the saved file", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {runner, worker} = hold_change_slot(organization, user)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

      view
      |> file_input("#diff-upload-form", :diff_files, [
        %{name: "levels.txt", content: @levels, type: "text/plain"}
      ])
      |> render_upload("levels.txt")

      view |> form("#diff-upload-form") |> render_submit()

      assert has_element?(view, "#flash-error", @change_busy)
      assert has_element?(view, "#diff-run-state[data-state='failed']", "Another change review")

      assert %ChangeRun{state: :failed, failure_code: "busy"} =
               latest_change_run(organization, version)

      release(runner, worker)
      view |> element("#diff-retry-btn") |> render_click()
      RunnerSlots.await_idle()
      render(view)

      assert %ChangeRun{state: :review} = latest_change_run(organization, version)
      assert has_element?(view, "#diff-decisions [data-review-row]")
    end
  end

  defp hold_import_slot(organization, user) do
    {:ok, %{run: run}} =
      ImportRuns.create_pending_target(organization.id, %{id: user.id, email: user.email}, %{
        name: "Occupant #{System.unique_integer([:positive])}"
      })

    {:ok, runner} = Runner.start_import(organization.id, run.id, run.lease_token, [])
    assert_receive {:blocking_import_worker_started, worker}, 2_000
    on_exit(fn -> send(worker, :finish) end)
    {runner, worker}
  end

  defp hold_change_slot(organization, user) do
    other_version = gtfs_version_fixture(organization.id)

    {:ok, run} =
      ChangeRuns.create_pending_compute(
        organization.id,
        other_version.id,
        %{id: user.id, email: user.email},
        []
      )

    {:ok, runner} = ChangeRunner.start_compute(organization.id, run.id, BlockingJobWorker)
    assert_receive {:blocking_job_worker_started, :compute, worker}, 2_000
    on_exit(fn -> send(worker, :finish) end)
    {runner, worker}
  end

  defp latest_change_run(organization, version),
    do: ChangeRuns.latest_for_version(organization.id, version.id)

  defp upload_feed(view) do
    view
    |> file_input("#gtfs-import-form", :gtfs_files, [
      %{name: "levels.txt", content: @levels, type: "text/plain"}
    ])
    |> render_upload("levels.txt")
  end

  defp submit_import(view, version_name) do
    view
    |> form("#gtfs-import-form", %{"gtfs_import_form" => %{"version_name" => version_name}})
    |> render_submit()
  end

  # Releases the worker and waits until its runner has exited, so the slot is free.
  defp release(runner, worker) do
    ref = Process.monitor(runner)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end

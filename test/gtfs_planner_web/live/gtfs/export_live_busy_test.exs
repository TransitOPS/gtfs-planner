defmodule GtfsPlannerWeb.Gtfs.ExportLiveBusyTest do
  @moduledoc """
  ExportLive while the export runner supervisor is full. A blocking worker holds
  the only slot; the page says another export is running, closes the run that
  never started, and keeps the chosen export type and the export it was showing
  so the same action works once the slot is free.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.Runner
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.{BlockingJobWorker, RunnerSlots}

  @busy "Another export is running. Try again when it finishes."

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    root = Path.join(System.tmp_dir!(), "export-live-busy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    previous = %{
      root: Application.fetch_env(:gtfs_planner, :gtfs_task_artifacts_path),
      owner: Application.fetch_env(:gtfs_planner, :blocking_job_worker_owner)
    }

    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)
    Application.put_env(:gtfs_planner, :blocking_job_worker_owner, self())

    # Every build finishes before its artifact root is removed and the sandbox
    # connection is released.
    on_exit(fn ->
      RunnerSlots.await_idle()
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, previous.root)
      restore_env(:blocking_job_worker_owner, previous.owner)
    end)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  test "a busy export keeps the chosen type and closes the run it never started", %{
    conn: conn,
    organization: organization,
    user: user,
    version: version
  } do
    {_runner, _worker} = hold_export_slot(organization, user)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=pathways")
    assert has_element?(view, "#export-type-pathways[checked]")

    view |> element("#start-export") |> render_click()

    assert has_element?(view, "#export-notice", @busy)
    assert has_element?(view, "#export-type-pathways[checked]")
    assert has_element?(view, "#start-export", "Export station pathways")
    assert has_element?(view, "#export-files-card")

    assert [%Run{id: busy_id, state: :failed, failure_code: "busy", export_type: :pathways}] =
             version_runs(version)

    assert has_element?(view, "#export-file-#{busy_id}", "Could not start")
    refute has_element?(view, "#export-file-#{busy_id}", "Export failed")

    assert ExportRuns.latest_for_version(organization.id, version.id, :pathways) == nil
  end

  test "a retry that cannot start keeps the failed export on screen", %{
    conn: conn,
    organization: organization,
    user: user,
    version: version
  } do
    {:ok, failed} = ExportRuns.create_pending(organization.id, version.id, actor(user), :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, failed.id, :build)

    {:ok, _failed} =
      ExportRuns.fail_build(organization.id, failed.id, generation, token, "build_failed")

    {_runner, _worker} = hold_export_slot(organization, user)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    assert has_element?(view, "#export-file-#{failed.id} button[phx-click='retry_file']")

    view
    |> element("#export-file-#{failed.id} button[phx-click='retry_file']")
    |> render_click()

    assert has_element?(view, "#export-notice", @busy)
    assert has_element?(view, "#export-file-#{failed.id} button[phx-click='retry_file']")

    assert version_runs(version) |> Enum.map(& &1.failure_code) |> Enum.sort() ==
             ["build_failed", "busy"]
  end

  test "starts the same export once the first export has finished", %{
    conn: conn,
    organization: organization,
    user: user,
    version: version
  } do
    {runner, worker} = hold_export_slot(organization, user)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")
    view |> element("#start-export") |> render_click()
    assert has_element?(view, "#export-notice", @busy)

    release(runner, worker)
    view |> element("#start-export") |> render_click()

    refute has_element?(view, "#export-notice")
    assert has_element?(view, "#export-files-card")

    assert Repo.exists?(
             from(r in Run, where: r.gtfs_version_id == ^version.id and r.state != :failed)
           )
  end

  # The held export belongs to another version, so it never shares a run with the
  # page's own export.
  defp hold_export_slot(organization, user) do
    other_version = gtfs_version_fixture(organization.id)

    {:ok, run} =
      ExportRuns.create_pending(organization.id, other_version.id, actor(user), :full)

    {:ok, runner} = Runner.start_build(organization.id, run.id, BlockingJobWorker)
    assert_receive {:blocking_job_worker_started, :build, worker}, 2_000
    on_exit(fn -> send(worker, :finish) end)
    {runner, worker}
  end

  defp actor(user), do: %{id: user.id, email: user.email}

  defp version_runs(version),
    do: Repo.all(from(r in Run, where: r.gtfs_version_id == ^version.id))

  # Releases the worker and waits until its runner has exited, so the slot is free.
  defp release(runner, worker) do
    ref = Process.monitor(runner)
    send(worker, :finish)
    assert_receive {:DOWN, ^ref, :process, ^runner, _reason}, 5_000
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:gtfs_planner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:gtfs_planner, key)
end

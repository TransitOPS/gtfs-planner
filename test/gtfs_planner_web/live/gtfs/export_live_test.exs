defmodule GtfsPlannerWeb.Gtfs.ExportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.RunnerSupervisor
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  # LiveView "start_export" clicks start a real Export.Runner child that holds
  # the sandbox connection while it builds. Waiting here for any runner child
  # created during the test keeps that build (or its forced teardown) inside
  # this test's on_exit, which runs before ConnCase releases the DB owner.
  @runner_exit_timeout 5_000

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    existing_runners = runner_pids()
    on_exit(fn -> await_new_runners(existing_runners) end)

    %{user: user, organization: organization, gtfs_version: gtfs_version}
  end

  test "runs the only validation from a single control", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    assert has_element?(view, "#run-validation", "Run validation")
    refute has_element?(view, "#validation-checks")
    refute has_element?(view, ~s(input[type="checkbox"][name="validation[checks][]"]))
  end

  test "starts an export instead of reporting storage as unavailable", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    html = view |> element("#start-export") |> render_click()

    refute html =~ "cannot write export files"
    assert has_element?(view, "#export-run-status")
    refute has_element?(view, "#export-empty-history")
  end

  test "renders with a recent legacy pathways_tests run present", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "pathways_tests")

    run
    |> ValidationRun.changeset(%{status: "failed"})
    |> Repo.update!()

    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    assert has_element?(view, "#export-workspace")
    assert has_element?(view, "#validation-history-counts")
    assert has_element?(view, "a.link", "Pathways Tests")
    assert has_element?(view, "#recent-validation-counts-#{run.id}")
  end

  defp runner_pids do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(RunnerSupervisor), is_pid(pid), do: pid
  end

  defp await_new_runners(existing_runners) do
    for pid <- runner_pids(), pid not in existing_runners do
      await_runner_down(pid)
    end
  end

  defp await_runner_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @runner_exit_timeout -> force_runner_down(pid, ref)
    end
  end

  defp force_runner_down(pid, ref) do
    task_pid =
      try do
        case :sys.get_state(pid, @runner_exit_timeout) do
          %{task_pid: task_pid} -> task_pid
          _ -> nil
        end
      catch
        :exit, _ -> nil
      end

    task_ref = task_pid && Process.monitor(task_pid)

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end

    if task_ref do
      receive do
        {:DOWN, ^task_ref, :process, ^task_pid, _reason} -> :ok
      end
    end
  end
end

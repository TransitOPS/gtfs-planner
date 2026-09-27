defmodule GtfsPlannerWeb.Gtfs.ExportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.Export.RunnerSupervisor
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

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

    root = Path.join(System.tmp_dir!(), "export-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    # Registered before the runner wait below: `on_exit` runs last-registered
    # first, so every owned build finishes before its artifact root is removed.
    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, previous_root)
    end)

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

  describe "operations export" do
    test "selecting the operations option patches the URL and lists the TODS files", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      garage_fixture(organization.id, garage_id: "garage_main")
      garage_fixture(organization.id)
      vehicle_fixture(organization.id)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      refute has_element?(view, "#export-type-operations[checked]")
      refute has_element?(view, "#operations-export-note")

      view
      |> form("#gtfs-export-form", export: %{type: "operations"})
      |> render_change()

      assert_patch(view, "/gtfs/#{version.id}/export?type=operations")
      assert has_element?(view, "#export-type-operations[checked]")
      assert has_element?(view, "#operations-export-note")

      assert tods_inventory_rows(view) == [
               ["stops_supplement.txt", "2"],
               ["vehicles.txt", "1"]
             ]

      view
      |> form("#gtfs-export-form", export: %{type: "full"})
      |> render_change()

      assert_patch(view, "/gtfs/#{version.id}/export?type=full")
      assert has_element?(view, "#export-type-full[checked]")
      refute has_element?(view, "#operations-export-note")
      assert tods_inventory_rows(view) == []
    end

    test "an operations URL preselects the option and its run, and an unknown type falls back", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      assert {:ok, _run} =
               ExportRuns.create_pending(organization.id, version.id, @actor, :operations)

      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")
      assert has_element?(view, "#export-type-operations[checked]")
      refute has_element?(view, "#export-empty-history")
      assert has_element?(view, "#export-run-status")

      {:ok, fallback_view, _html} = live(conn, "/gtfs/#{version.id}/export?type=bogus")
      assert has_element?(fallback_view, "#export-type-full[checked]")
      assert has_element?(fallback_view, "#export-empty-history")
    end

    test "starting an operations export publishes a downloadable ZIP with both TODS files", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      agency_fixture(organization.id, version.id, agency_id: "AGENCY1")
      stop_fixture(organization.id, version.id, stop_id: "STOP1")
      route_fixture(organization.id, version.id, route_id: "ROUTE1", route_short_name: "1")
      garage_fixture(organization.id, garage_id: "garage_main", name: "Main garage")
      vehicle_fixture(organization.id, vehicle_id: "bus-1", vehicle_label: "Bus 1")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      start_export_and_wait(view)

      assert %Run{state: :ready} = run = latest_operations_run(organization, version)
      assert has_element?(view, "#export-download-link")

      download = get(conn, "/gtfs/#{version.id}/export-runs/#{run.id}/download")
      assert download.status == 200

      {:ok, entries} = :zip.unzip(download.resp_body, [:memory])
      filenames = Enum.map(entries, fn {name, _content} -> to_string(name) end)

      assert "stops_supplement.txt" in filenames
      assert "vehicles.txt" in filenames
    end

    test "an operations export omits the TODS files for empty tables and reports it", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stop_fixture(organization.id, version.id, stop_id: "STOP1")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      start_export_and_wait(view)

      assert %Run{state: :ready} = latest_operations_run(organization, version)
      assert has_element?(view, "#export-warning-panel", "stops_supplement.txt was not included")
      assert has_element?(view, "#export-warning-panel", "vehicles.txt was not included")
      refute has_element?(view, "#export-conflict-panel")
    end

    test "a garage/stop ID conflict is actionable and clears after the ID is corrected", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      stop_fixture(organization.id, version.id, stop_id: "STOP1", stop_name: "Main Street")
      garage = garage_fixture(organization.id, garage_id: "STOP1", name: "Main garage")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export?type=operations")

      start_export_and_wait(view)

      assert %Run{state: :failed, failure_code: "garage_stop_id_conflict"} =
               latest_operations_run(organization, version)

      assert has_element?(view, "#export-conflict-panel")
      assert has_element?(view, "#export-conflicts", "Main garage")
      assert has_element?(view, "#export-conflicts", "Main Street")

      assert attribute_values(render(view), "#export-edit-garages", "href") == [
               "/gtfs/#{version.id}/blocks/garages"
             ]

      # The conflict detail belongs to the conflict panel only.
      refute has_element?(view, "#export-warning-panel")

      assert {:ok, _garage} =
               Operations.update_garage(organization.id, operations_actor(), garage.id, %{
                 "garage_id" => "garage_main"
               })

      start_export_and_wait(view, "#retry-export")

      assert %Run{state: :ready} = latest_operations_run(organization, version)
      assert has_element?(view, "#export-download-link")
      refute has_element?(view, "#export-conflict-panel")
      refute has_element?(view, "#retry-export")
    end
  end

  describe "GTFS area navigation" do
    test "mounts the GTFS tabs with Export current above the unchanged page", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/export")

      assert has_element?(view, "#gtfs-sub-nav")
      assert has_element?(view, "#gtfs-tab-export[aria-current='page']")
      assert has_element?(view, "#gtfs-tab-import[href='/gtfs/#{version.id}/import']")
      refute has_element?(view, "#gtfs-tab-import[aria-current='page']")

      assert heading_text(html, "header h1") == "Export & Validate"
      assert has_element?(view, "#gtfs-export-form")
      assert has_element?(view, "#export-download-container")
    end
  end

  defp heading_text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp start_export_and_wait(view, button_id \\ "#start-export") do
    existing_runners = runner_pids()
    view |> element(button_id) |> render_click()
    await_new_runners(existing_runners)
    render(view)
  end

  defp latest_operations_run(organization, version),
    do: ExportRuns.latest_for_version(organization.id, version.id, :operations)

  defp tods_inventory_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#export-inventory tbody tr")
    |> Enum.map(fn row ->
      row |> LazyHTML.query("td") |> Enum.map(&String.trim(LazyHTML.text(&1)))
    end)
    |> Enum.filter(fn [filename, _count] ->
      filename in ["stops_supplement.txt", "vehicles.txt"]
    end)
  end

  defp attribute_values(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

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

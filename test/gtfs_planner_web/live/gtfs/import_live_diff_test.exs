defmodule GtfsPlannerWeb.Gtfs.ImportLiveDiffTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeRuns

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()
    version = gtfs_version_fixture(organization.id)

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/import")

    %{conn: conn, view: view, organization: organization, version: version}
  end

  test "the route stages uploads, starts the real runner, and reattaches its persisted review", %{
    conn: conn,
    view: view,
    organization: organization,
    version: version
  } do
    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nRECONNECT,1.0,Durable")
    await_change_task(view)

    assert %{state: :review, gtfs_version_id: version_id} =
             ChangeRuns.latest_for_version(organization.id, version.id)

    assert version_id == version.id
    assert has_element?(view, "#diff-decisions [data-version-diff-row]")

    assert has_element?(
             view,
             "button[phx-click='approve-decision'][phx-value-id='level:RECONNECT']"
           )

    {:ok, reconnected, _html} = live(conn, "/gtfs/#{version.id}/import")

    assert has_element?(reconnected, "#diff-decisions [data-version-diff-row]")

    assert has_element?(
             reconnected,
             "button[phx-click='approve-decision'][phx-value-id='level:RECONNECT']"
           )
  end

  test "persists approval and applies through the scoped runner without retargeting the route version",
       %{
         view: view,
         organization: organization,
         version: version
       } do
    published_elsewhere = gtfs_version_fixture(organization.id)

    submit_diff(view, "levels.txt", "level_id,level_index,level_name\nDURABLE,2.0,Applied")
    await_change_task(view)

    view
    |> element("button[phx-click='approve-decision'][phx-value-id='level:DURABLE']")
    |> render_click()

    assert has_element?(view, "#diff-apply-btn", "Apply Approved (1)")

    assert [%{status: :approved}] =
             ChangeRuns.latest_for_version(organization.id, version.id)
             |> then(&ChangeRuns.list_decisions(organization.id, &1.id))

    view |> element("#diff-apply-btn") |> render_click()
    await_change_task(view)

    assert Gtfs.get_level_by_level_id(organization.id, version.id, "DURABLE")
    refute Gtfs.get_level_by_level_id(organization.id, published_elsewhere.id, "DURABLE")
    assert has_element?(view, "#diff-reset-btn")
  end

  test "a pending durable review exposes a reconnect-safe cancellation action", %{
    conn: conn,
    view: view,
    organization: organization,
    version: version
  } do
    actor = %{id: Ecto.UUID.generate(), email: "reviewer@example.com"}
    assert {:ok, run} = ChangeRuns.create_pending_compute(organization.id, version.id, actor, [])

    {:ok, reconnected, _html} = live(conn, "/gtfs/#{version.id}/import")
    assert has_element?(reconnected, "#diff-run-state[data-state='pending_compute']")

    reconnected |> element("#diff-cancel-btn") |> render_click()
    assert %{state: :cancelled} = ChangeRuns.get_for_version(organization.id, version.id, run.id)
  end

  defp submit_diff(view, filename, content) do
    upload =
      file_input(view, "#diff-upload-form", :diff_files, [
        %{name: filename, content: content, type: "text/plain"}
      ])

    render_upload(upload, filename)
    view |> form("#diff-upload-form") |> render_submit()
  end

  defp await_change_task(view) do
    for pid <- Task.Supervisor.children(GtfsPlanner.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 15_000
    end

    render(view)
  end
end

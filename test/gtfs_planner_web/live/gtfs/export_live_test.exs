defmodule GtfsPlannerWeb.Gtfs.ExportLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

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
end

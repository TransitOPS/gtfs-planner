defmodule GtfsPlannerWeb.AssignGtfsVersionTest do
  @moduledoc """
  Boundary coverage for the `AssignGtfsVersion` mount hook: only a published,
  same-organization version may be resolved from a direct URL. Every unavailable
  identity (staging, importing, failed, foreign-organization, malformed) must
  fail closed with the established not-found redirect.
  """
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    {:ok, published} = Versions.create_gtfs_version(organization.id, %{name: "Published"})

    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, organization: organization, user: user, published: published}
  end

  defp staging_version(org_id, name) do
    {:ok, staging} = Versions.create_staging_gtfs_version(org_id, %{name: name})
    staging
  end

  defp importing_version(org_id, name) do
    staging = staging_version(org_id, name)
    {:ok, importing} = Versions.claim_staging_gtfs_version(org_id, staging.id)
    importing
  end

  defp failed_version(org_id, name) do
    staging = staging_version(org_id, name)
    {:ok, failed} = Versions.fail_unpublished_gtfs_version(org_id, staging.id)
    failed
  end

  test "mounts a published same-organization version from a direct route", %{
    conn: conn,
    published: published
  } do
    {:ok, _view, html} = live(conn, "/gtfs/#{published.id}/stops")
    assert html =~ "Stations"
  end

  test "redirects to dashboard for a staging version", %{conn: conn, organization: org} do
    staging = staging_version(org.id, "Staging")

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
             live(conn, "/gtfs/#{staging.id}/stops")
  end

  test "redirects to dashboard for an importing version", %{conn: conn, organization: org} do
    importing = importing_version(org.id, "Importing")

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
             live(conn, "/gtfs/#{importing.id}/stops")
  end

  test "redirects to dashboard for a failed version", %{conn: conn, organization: org} do
    failed = failed_version(org.id, "Failed")

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
             live(conn, "/gtfs/#{failed.id}/stops")
  end

  test "redirects to dashboard for a published version from another organization", %{conn: conn} do
    other_org = organization_fixture()
    {:ok, foreign} = Versions.create_gtfs_version(other_org.id, %{name: "Foreign"})

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
             live(conn, "/gtfs/#{foreign.id}/stops")
  end

  test "redirects to dashboard for a valid-format but nonexistent version", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
             live(conn, "/gtfs/#{Ecto.UUID.generate()}/stops")
  end

  test "redirects to dashboard for a malformed version id", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "GTFS version not found"}}}} =
             live(conn, "/gtfs/not-a-uuid/stops")
  end
end

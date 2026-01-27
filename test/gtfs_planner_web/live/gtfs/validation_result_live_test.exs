defmodule GtfsPlannerWeb.Gtfs.ValidationResultLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Validations

  describe "ValidationResultLive" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS editor role
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "displays summary counts for completed validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a completed validation run
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 5,
          warnings: 10,
          infos: 3
        },
        notices: [
          %{
            "code" => "missing_required_field",
            "severity" => "error",
            "totalNotices" => 5,
            "notices" => [
              %{
                "filename" => "stops.txt",
                "csvRowNumber" => 10,
                "csvFieldName" => "stop_name",
                "message" => "Missing required field"
              }
            ]
          }
        ],
        duration_ms: 1500
      }

      {:ok, run} = Validations.mark_completed(run, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display summary counts
      assert html =~ "5"
      assert html =~ "10"
      assert html =~ "3"
      assert html =~ "Errors"
      assert html =~ "Warnings"
      assert html =~ "Info"

      # Should display status badge
      assert html =~ "COMPLETED"
    end

    test "displays error details for failed validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a failed validation run
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      error_reason = %RuntimeError{message: "Validation process crashed"}
      {:ok, run} = Validations.mark_failed(run, error_reason)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display failed status
      assert html =~ "FAILED"
      assert html =~ "Validation Failed"

      # Should display error details
      assert html =~ "RuntimeError"
    end

    test "displays loading state for started validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a started validation run (not yet completed)
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display loading state
      assert html =~ "STARTED"
      assert html =~ "Validation starting..."
    end

    test "displays loading state for running validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a running validation run
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")
      {:ok, run} = Validations.mark_running(run)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display loading state
      assert html =~ "RUNNING"
      assert html =~ "Validation in progress..."
    end

    test "displays notice details when validation has notices", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a completed validation run with notices
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 1,
          warnings: 0,
          infos: 0
        },
        notices: [
          %{
            "code" => "missing_required_field",
            "severity" => "error",
            "totalNotices" => 1,
            "notices" => [
              %{
                "filename" => "stops.txt",
                "csvRowNumber" => 10,
                "csvFieldName" => "stop_name",
                "message" => "Missing required field"
              }
            ]
          }
        ],
        duration_ms: 1500
      }

      {:ok, run} = Validations.mark_completed(run, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display notice code
      assert has_element?(view, "span.font-mono", "missing_required_field")

      # Should display severity badge
      assert has_element?(view, "div.badge-error", "ERROR")
    end

    test "displays no issues message when validation has no notices", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a completed validation run with no notices
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 0,
          warnings: 0,
          infos: 0
        },
        notices: [],
        duration_ms: 1500
      }

      {:ok, run} = Validations.mark_completed(run, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display success message
      assert html =~ "No validation issues found!"
      assert html =~ "Your GTFS data passed all checks."
    end

    test "history drawer contains links to past validation runs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create multiple validation runs
      {:ok, run1} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Process.sleep(10)

      {:ok, run2} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Process.sleep(10)

      {:ok, run3} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      # Mark them with different statuses
      result = %{
        summary: %{errors: 1, warnings: 2, infos: 3},
        notices: [],
        duration_ms: 1500
      }

      {:ok, _run1} = Validations.mark_completed(run1, result)
      {:ok, _run2} = Validations.mark_running(run2)
      # run3 remains in "started" status

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run3.id}")

      # Check that View History button exists
      assert has_element?(view, "label[for='validation-history-drawer']", "View History")

      # Check that history drawer contains past runs
      html = render(view)

      # Should contain the history drawer
      assert html =~ "Validation History"

      # Should contain status badges for each run
      assert html =~ "completed"
      assert html =~ "running"
      assert html =~ "started"
    end

    test "clicking history item navigates to that validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create two validation runs
      {:ok, run1} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Process.sleep(10)

      {:ok, run2} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{errors: 1, warnings: 2, infos: 3},
        notices: [],
        duration_ms: 1500
      }

      {:ok, run1} = Validations.mark_completed(run1, result)
      {:ok, _run2} = Validations.mark_completed(run2, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run2.id}")

      # Should have links to both runs in the history
      assert has_element?(view, "a[href='/gtfs/#{version.id}/validation/#{run1.id}']")
      assert has_element?(view, "a[href='/gtfs/#{version.id}/validation/#{run2.id}']")
    end

    test "shows Back to Export button", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should have Back to Export button
      assert has_element?(view, "a[href='/gtfs/#{version.id}/export']", "Back to Export")
    end

    test "denies access to validation run from different organization", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a different organization and validation run
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, other_run} =
        Validations.create_validation_run(
          other_organization.id,
          other_version.id,
          "mobility_data"
        )

      # Try to access the other organization's validation run
      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               live(conn, "/gtfs/#{version.id}/validation/#{other_run.id}")

      assert path == "/gtfs/#{version.id}/export"
      assert flash["error"] == "Unauthorized access to validation run"
    end
  end
end

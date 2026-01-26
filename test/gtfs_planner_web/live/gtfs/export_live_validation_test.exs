defmodule GtfsPlannerWeb.Gtfs.ExportLiveValidationTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures
  import Mox

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ValidatorMock

  # Make sure mocks are verified after each test
  setup :verify_on_exit!

  describe "ExportLive Validation" do
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
      # Create an agency so there is at least some data to export
      _agency = agency_fixture(organization.id, gtfs_version.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "shows 'Run Validation' button by default", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/export")

      assert html =~ "Run Validation"
      assert html =~ "MobilityData GTFS Validator"
    end

    test "can toggle validation selection", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Click mobility_data checkbox
      view
      |> element("input[phx-value-validation='mobility_data']")
      |> render_click()

      # It should be checked
      assert has_element?(view, "input[phx-value-validation='mobility_data'][checked]")
    end

    test "clicking 'Run Validation' without selecting validator shows info flash", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      view |> element("button", "Run Validation") |> render_click()

      assert render(view) =~ "Select &#39;MobilityData GTFS Validator&#39; to run validation"
    end

    test "starts validation when validator is selected and button is clicked", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to simulate a quick failure (no Java)
      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:error, :validator_path_not_configured}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select validator
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()

      # Run validation
      view |> element("button", "Run Validation") |> render_click()

      # Wait for async task to complete
      Process.sleep(100)

      html = render(view)
      assert html =~ "Validation failed"
    end

    test "updates progress bar via PubSub", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to broadcast progress updates
      stub(ValidatorMock, :validate, fn _org_id, _version_id, opts ->
        validation_id = Keyword.fetch!(opts, :validation_run_id)

        # Simulate progress broadcasts
        Phoenix.PubSub.broadcast(
          GtfsPlanner.PubSub,
          "validation:#{validation_id}",
          {:validation_progress, %{phase: :validating, percent: 50, message: "Testing..."}}
        )

        # Keep the task running to maintain validating state
        Process.sleep(200)
        {:error, :test_timeout}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select validator and run
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Wait for progress update to be broadcast and processed
      Process.sleep(100)

      html = render(view)
      assert html =~ "Running validator..."
    end

    test "displays results when validation completes", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to return a successful result
      result = %GtfsPlanner.Gtfs.Validator.Result{
        summary: %{errors: 1, warnings: 2, infos: 3},
        notices: [],
        duration_ms: 1000,
        validated_at: DateTime.utc_now()
      }

      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:ok, result}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select and run
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Wait for async task to complete
      Process.sleep(100)

      html = render(view)
      assert html =~ "Errors"
      assert html =~ "1"
      assert html =~ "Warnings"
      assert html =~ "2"
      assert html =~ "View Full Results"
    end

    test "handles validation failure", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to return an error
      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:error, :cli_failed}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Select and run
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Wait for async task to complete
      Process.sleep(100)

      assert render(view) =~ "Validation failed: :cli_failed"
      # Should be back to initial state (Run Validation button visible)
      assert has_element?(view, "button", "Run Validation")
    end

    test "can reset validation to run again", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Mock the validator to return a successful result
      result = %GtfsPlanner.Gtfs.Validator.Result{
        summary: %{errors: 0, warnings: 0, infos: 0},
        notices: [],
        duration_ms: 100,
        validated_at: DateTime.utc_now()
      }

      stub(ValidatorMock, :validate, fn _org_id, _version_id, _opts ->
        {:ok, result}
      end)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      # Run and complete
      view |> element("input[phx-value-validation='mobility_data']") |> render_click()
      view |> element("button", "Run Validation") |> render_click()

      # Wait for async task to complete
      Process.sleep(100)
      assert render(view) =~ "View Full Results"

      # Click Run Again
      view |> element("button", "Run Again") |> render_click()

      # Should be back to initial state
      assert has_element?(view, "button", "Run Validation")
      refute render(view) =~ "View Full Results"
    end
  end
end

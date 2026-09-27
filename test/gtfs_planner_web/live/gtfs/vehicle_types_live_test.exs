defmodule GtfsPlannerWeb.Gtfs.VehicleTypesLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Operations

  @fleet_path "/blocks/fleet"

  defp editor_setup(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{user: user, organization: organization, version: version}
  end

  defp fleet_url(version), do: "/gtfs/#{version.id}#{@fleet_path}"

  defp open_edit(view, vehicle_type) do
    view |> element("#vehicle-type-name-#{vehicle_type.id}") |> render_click()
  end

  defp submit_type(view, attrs),
    do: render_submit(view, "save_vehicle_type", %{"vehicle_type" => attrs})

  describe "disclosure" do
    setup :editor_setup

    test "the Vehicle types section renders collapsed on normal entry", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle_type_fixture(organization.id, %{"name" => "Cutaway", "max_out_hours" => "10"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(view, "#vehicle-types")
      assert has_element?(view, "#vehicle-types-summary", "Vehicle types")
      assert has_element?(view, "#vehicle-types-summary", "1 types · Manage types and limits")
      refute has_element?(view, "#vehicle-types[open]")
      refute has_element?(view, "#vehicle-type-drawer-overlay[data-open='true']")
    end

    test "expanding the summary opens the disclosure and lists the types table", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#vehicle-types-summary") |> render_click()

      assert has_element?(view, "#vehicle-types[open]")

      assert has_element?(
               view,
               "tr#vehicle_types-#{vehicle_type.id} td[data-label='Name']",
               "Cutaway"
             )
    end

    test "an organization without types shows the empty line and the Add type action", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(view, "#vehicle-types-summary", "0 types")
      assert has_element?(view, "#vehicle-types-empty", "No vehicle types yet")
      refute has_element?(view, "#vehicle-types-table")
      assert has_element?(view, "#add-vehicle-type", "Add type")
    end
  end

  describe "editing a stored limit" do
    setup :editor_setup

    test "editing a stored 600-minute type opens with 10 hours", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle_type =
        vehicle_type_fixture(organization.id, %{"name" => "Cutaway", "max_out_hours" => "10"})

      assert vehicle_type.max_out_minutes == 600

      {:ok, view, _html} = live(conn, fleet_url(version))
      open_edit(view, vehicle_type)

      assert has_element?(view, "#vehicle-type-drawer-overlay[data-open='true']")
      assert has_element?(view, "#vehicle_type_max_out_hours[value='10']")

      assert has_element?(
               view,
               "tr#vehicle_types-#{vehicle_type.id} td[data-label='Maximum time away from garage']",
               "10 hours"
             )
    end

    test "blank clears the limit and an absent field preserves it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      blanked =
        vehicle_type_fixture(organization.id, %{"name" => "Blank me", "max_out_hours" => "10"})

      kept =
        vehicle_type_fixture(organization.id, %{"name" => "Keep me", "max_out_hours" => "10"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_edit(view, blanked)
      submit_type(view, %{"name" => "Blank me", "max_out_hours" => ""})

      open_edit(view, kept)
      submit_type(view, %{"name" => "Keep me"})

      types = Operations.list_vehicle_types(organization.id)
      assert Enum.find(types, &(&1.name == "Blank me")).max_out_minutes == nil
      assert Enum.find(types, &(&1.name == "Keep me")).max_out_minutes == 600

      assert has_element?(
               view,
               "tr#vehicle_types-#{blanked.id} td[data-label='Maximum time away from garage']",
               "No limit set"
             )

      assert has_element?(
               view,
               "tr#vehicle_types-#{kept.id} td[data-label='Maximum time away from garage']",
               "10 hours"
             )
    end

    test "the limit survives a change event that leaves the hours field alone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle_type =
        vehicle_type_fixture(organization.id, %{"name" => "Cutaway", "max_out_hours" => "10"})

      {:ok, view, _html} = live(conn, fleet_url(version))
      open_edit(view, vehicle_type)

      render_change(element(view, "#vehicle-type-form"), %{
        "_target" => ["vehicle_type", "name"],
        "vehicle_type" => %{"name" => "Cutaway renamed", "max_out_hours" => "10"}
      })

      assert has_element?(view, "#vehicle_type_max_out_hours[value='10']")
    end
  end

  describe "creating and validating a type" do
    setup :editor_setup

    test "adding a type with 10 hours stores 600 minutes and shows 10 hours", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#add-vehicle-type") |> render_click()
      assert has_element?(view, "#vehicle-type-drawer-overlay[data-open='true']")
      assert has_element?(view, "#vehicle-type-drawer-title", "Add vehicle type")

      submit_type(view, %{"name" => "Cutaway", "max_out_hours" => "10"})

      assert [type] = Operations.list_vehicle_types(organization.id)
      assert type.max_out_minutes == 600

      assert has_element?(view, "dialog#vehicle-type-drawer-overlay[data-open='false']")
      assert has_element?(view, "#vehicle-type-notice", "Cutaway saved.")

      assert has_element?(
               view,
               "tr#vehicle_types-#{type.id} td[data-label='Maximum time away from garage']",
               "10 hours"
             )
    end

    test "25 hours shows a field error and inserts nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#add-vehicle-type") |> render_click()
      submit_type(view, %{"name" => "Too long", "max_out_hours" => "25"})

      assert has_element?(view, "#vehicle_type_max_out_hours[aria-invalid='true']")
      assert has_element?(view, "#vehicle-type-form-error", "Check the highlighted fields")

      assert_push_event(view, "focus_form_error", %{
        form_id: "vehicle-type-form",
        fallback_id: "vehicle-type-form-error"
      })

      assert Operations.list_vehicle_types(organization.id) == []
    end

    test "a case-variant duplicate name shows an error and changes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#add-vehicle-type") |> render_click()
      submit_type(view, %{"name" => "cutaway"})

      assert has_element?(view, "#vehicle_type_name[aria-invalid='true']")
      assert length(Operations.list_vehicle_types(organization.id)) == 1
    end
  end

  describe "deletion" do
    setup :editor_setup

    test "an in-use type explains the block and an unused type needs confirmation", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      in_use = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
      unused = vehicle_type_fixture(organization.id, %{"name" => "Spare"})

      vehicle =
        vehicle_fixture(organization.id, %{"vehicle_id" => "1201", "vehicle_type_id" => in_use.id})

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_edit(view, in_use)
      view |> element("#delete-vehicle-type") |> render_click()

      assert has_element?(view, "#vehicle-type-in-use-dialog", "1 vehicles use Cutaway")
      refute has_element?(view, "#vehicle-type-delete-confirm")
      assert Enum.count(Operations.list_vehicle_types(organization.id)) == 2

      view |> element("#vehicle-type-in-use-dialog-cancel") |> render_click()
      refute has_element?(view, "#vehicle-type-in-use-dialog")

      view |> element("#vehicle-type-drawer-close") |> render_click()
      open_edit(view, unused)
      view |> element("#delete-vehicle-type") |> render_click()

      assert has_element?(
               view,
               "#vehicle-type-delete-confirm-body",
               "This removes the type from this organization."
             )

      # Cancelling keeps the type.
      view |> element("#vehicle-type-delete-confirm-cancel") |> render_click()
      assert has_element?(view, "tr#vehicle_types-#{unused.id}")

      # Confirming removes it and refreshes the list.
      open_edit(view, unused)
      view |> element("#delete-vehicle-type") |> render_click()
      view |> element("#vehicle-type-delete-confirm-confirm") |> render_click()

      refute has_element?(view, "tr#vehicle_types-#{unused.id}")
      assert has_element?(view, "#vehicle-type-notice", "Spare deleted.")
      assert Enum.map(Operations.list_vehicle_types(organization.id), & &1.id) == [in_use.id]

      # The assigned type and its vehicle are untouched.
      assert has_element?(view, "tr#vehicle_types-#{in_use.id}")
      assert has_element?(view, "tr#vehicles-#{vehicle.id}", "Cutaway")
    end
  end

  describe "normal-route persistence" do
    setup :editor_setup

    test "the expanded disclosure saves 600 minutes and redisplays 10 hours on edit", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#vehicle-types-summary") |> render_click()
      assert has_element?(view, "#vehicle-types[open]")

      view |> element("#add-vehicle-type") |> render_click()
      submit_type(view, %{"name" => "Cutaway", "max_out_hours" => "10"})

      assert [type] = Operations.list_vehicle_types(organization.id)
      assert type.max_out_minutes == 600

      # The disclosure stays open across the mutation, so the new row is visible.
      assert has_element?(view, "#vehicle-types[open]")

      open_edit(view, type)

      assert has_element?(view, "#vehicle-type-drawer-title", "Edit vehicle type")
      assert has_element?(view, "#vehicle_type_max_out_hours[value='10']")
    end
  end
end

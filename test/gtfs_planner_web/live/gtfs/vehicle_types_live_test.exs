defmodule GtfsPlannerWeb.Gtfs.VehicleTypesLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Operations

  @fleet_path "/settings/fleet"

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

  describe "type list" do
    setup :editor_setup

    test "types are listed with their limit and no drawer is open on entry", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      limited =
        vehicle_type_fixture(organization.id, %{"name" => "Electric", "max_out_hours" => "10"})

      unlimited = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(view, "#vehicle-types-table")
      assert has_element?(view, "tr#vehicle_types-#{limited.id}", "Electric")
      assert has_element?(view, "tr#vehicle_types-#{limited.id}", "Up to 10 hours away")
      assert has_element?(view, "tr#vehicle_types-#{unlimited.id}", "Cutaway")
      refute has_element?(view, "tr#vehicle_types-#{unlimited.id}", "hours away")
      refute has_element?(view, "#vehicle-type-drawer-overlay[data-open='true']")
    end

    test "an organization without types shows the empty message and the Add vehicle type action",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(view, "#vehicle-types-empty", "No vehicle types yet")
      refute has_element?(view, "#vehicle-types-table")
      assert has_element?(view, "#add-vehicle-type", "Add vehicle type")
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
               "tr#vehicle_types-#{vehicle_type.id}",
               "Up to 10 hours away"
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

      assert has_element?(view, "tr#vehicle_types-#{blanked.id}", "Blank me")
      refute has_element?(view, "tr#vehicle_types-#{blanked.id}", "hours away")

      assert has_element?(view, "tr#vehicle_types-#{kept.id}", "Up to 10 hours away")
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

      assert has_element?(view, "tr#vehicle_types-#{type.id}", "Up to 10 hours away")
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
      assert has_element?(view, "#vehicle-type-form-error", "Vehicle type not saved")

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

      assert has_element?(view, "#vehicle-type-in-use-dialog", "Cutaway is used by 1 vehicle")
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
               "This removes Spare from #{organization.name}."
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

    test "a type a block and a route require is refused and the page names both", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      in_use = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
      vehicle_type_fixture(organization.id, %{"name" => "Spare"})

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "7",
        vehicle_type_id: in_use.id
      })

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "10",
        required_vehicle_type_id: in_use.id
      })

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_edit(view, in_use)
      view |> element("#delete-vehicle-type") |> render_click()

      assert has_element?(
               view,
               "#vehicle-type-in-use-dialog",
               "Cutaway is used by 1 block and 1 route. Change those first."
             )

      refute has_element?(view, "#vehicle-type-delete-confirm")

      assert Operations.vehicle_type_in_use_counts(organization.id, in_use.id) ==
               %{vehicles: 0, blocks: 1, routes: 1}
    end
  end

  describe "normal-route persistence" do
    setup :editor_setup

    test "a saved type stores 600 minutes and redisplays 10 hours on edit", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#add-vehicle-type") |> render_click()
      submit_type(view, %{"name" => "Cutaway", "max_out_hours" => "10"})

      assert [type] = Operations.list_vehicle_types(organization.id)
      assert type.max_out_minutes == 600

      assert has_element?(view, "tr#vehicle_types-#{type.id}", "Up to 10 hours away")

      open_edit(view, type)

      assert has_element?(view, "#vehicle-type-drawer-title", "Edit vehicle type")
      assert has_element?(view, "#vehicle_type_max_out_hours[value='10']")
    end
  end
end

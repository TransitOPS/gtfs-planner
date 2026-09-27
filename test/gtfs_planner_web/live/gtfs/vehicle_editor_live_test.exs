defmodule GtfsPlannerWeb.Gtfs.VehicleEditorLiveTest do
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

  defp stored_ids(organization),
    do: Enum.map(Operations.list_vehicles(organization.id, %{}), & &1.vehicle_id)

  defp open_add_drawer(view, selector \\ "#add-vehicles-header") do
    view |> element(selector) |> render_click()
  end

  defp choose_numbered_group(view) do
    view |> element("#vehicle-mode-form") |> render_change(%{"vehicle_mode" => "range"})
  end

  defp submit_vehicle(view, attrs), do: render_submit(view, "save_vehicle", %{"vehicle" => attrs})

  defp submit_range(view, attrs), do: render_submit(view, "save_vehicle", %{"range" => attrs})

  describe "adding one vehicle" do
    setup :editor_setup

    test "the first-use action opens the drawer in One vehicle mode", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(view, "#vehicles-first-use-empty")
      assert has_element?(view, "#import-tods:not([disabled])")
      refute has_element?(view, "#add-vehicles[disabled]")

      open_add_drawer(view, "#add-vehicles")

      assert has_element?(view, "#vehicle-drawer-overlay[data-open='true']")
      assert has_element?(view, "#vehicle-drawer-title", "Add vehicles")
      assert has_element?(view, "#vehicle-drawer-description", "add a numbered group")
      assert has_element?(view, "#vehicle-mode-option-single[checked]")

      assert has_element?(
               view,
               "#vehicle-drawer-overlay[data-initial-focus-id='vehicle_vehicle_id']"
             )

      assert has_element?(view, "#vehicle_vehicle_id")
      refute has_element?(view, "#vehicle-range-form")

      view |> element("#vehicle-drawer-close") |> render_click()

      assert has_element?(view, "dialog#vehicle-drawer-overlay[data-open='false']")
    end

    test "adding one vehicle saves every field and relists it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)

      assert has_element?(view, "#vehicle-drawer-overlay[data-open='true']")

      # The assignment selects offer the organization's own rows plus the blank prompt.
      assert has_element?(view, "#vehicle_vehicle_type_id option[value='#{vehicle_type.id}']")
      assert has_element?(view, "#vehicle_garage_id option[value='#{garage.id}']")
      assert has_element?(view, "#vehicle_vehicle_type_id option[value='']", "Not assigned")

      submit_vehicle(view, %{
        "vehicle_id" => "1201",
        "vehicle_label" => "River shuttle",
        "vehicle_type_id" => vehicle_type.id,
        "garage_id" => garage.id,
        "license_plate" => "CV 201"
      })

      assert [vehicle] = Operations.list_vehicles(organization.id, %{})
      assert vehicle.vehicle_id == "1201"
      assert vehicle.vehicle_label == "River shuttle"
      assert vehicle.vehicle_type_id == vehicle_type.id
      assert vehicle.garage_id == garage.id
      assert vehicle.license_plate == "CV 201"

      assert has_element?(view, "dialog#vehicle-drawer-overlay[data-open='false']")
      assert has_element?(view, "#vehicle-notice", "1201 added.")

      assert has_element?(view, "tr#vehicles-#{vehicle.id} td[data-label='Vehicle ID']", "1201")
      assert has_element?(view, "#vehicles-count", "1 of 1 vehicles")
      assert has_element?(view, "#add-vehicles-header:not([disabled])")
      assert has_element?(view, "#import-tods:not([disabled])")
    end

    test "a taken vehicle ID shows the field error and inserts nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)
      submit_vehicle(view, %{"vehicle_id" => "1201"})

      assert has_element?(view, "#vehicle_vehicle_id[aria-invalid='true']")
      assert has_element?(view, "#vehicle_vehicle_id[value='1201']")
      assert has_element?(view, "#vehicle-form-error", "Check the highlighted fields")

      assert_push_event(view, "focus_form_error", %{
        form_id: "vehicle-form",
        fallback_id: "vehicle-form-error"
      })

      assert stored_ids(organization) == ["1201"]
      assert has_element?(view, "#vehicle-drawer-overlay[data-open='true']")
    end

    test "a foreign garage is refused and inserts nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      foreign_garage = garage_fixture(organization_fixture().id)

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)

      submit_vehicle(view, %{"vehicle_id" => "1201", "garage_id" => foreign_garage.id})

      assert Operations.list_vehicles(organization.id, %{}) == []
      assert has_element?(view, "dialog#vehicle-drawer-overlay[data-open='false']")
      refute has_element?(view, "#vehicle-notice")
    end
  end

  describe "numbered group" do
    setup :editor_setup

    test "#range-preview states the padded group and its count", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)

      assert has_element?(
               view,
               "#vehicle-drawer-overlay[data-initial-focus-id='vehicle_vehicle_id']"
             )

      choose_numbered_group(view)

      refute has_element?(view, "#vehicle-form")
      assert has_element?(view, "#vehicle-range-form")
      assert has_element?(view, "#range-preview", "Choose a numbered group of 1 to 200 vehicles.")

      view
      |> element("#vehicle-range-form")
      |> render_change(%{"range" => %{"first" => "1201", "last" => "1215"}})

      assert has_element?(view, "#range-preview", "Adds 1201–1215 (15 vehicles)")

      # A single-vehicle range reads as one, not as a group.
      view
      |> element("#vehicle-range-form")
      |> render_change(%{"range" => %{"first" => "1201", "last" => "1201"}})

      assert has_element?(view, "#range-preview", "Adds 1201–1201 (1 vehicle)")

      # The Last number before the First number is not a group.
      view
      |> element("#vehicle-range-form")
      |> render_change(%{"range" => %{"first" => "1215", "last" => "1201"}})

      assert has_element?(view, "#range-preview", "Choose a numbered group of 1 to 200 vehicles.")
    end

    test "a 201-vehicle range shows the limit message and refuses the submit", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)
      choose_numbered_group(view)

      view
      |> element("#vehicle-range-form")
      |> render_change(%{"range" => %{"first" => "1201", "last" => "1401"}})

      assert has_element?(view, "#range-preview", "Choose a numbered group of 1 to 200 vehicles.")
      refute has_element?(view, "#vehicle-form-error")

      submit_range(view, %{"first" => "1201", "last" => "1401"})

      assert has_element?(
               view,
               "#vehicle-form-error",
               "Choose a numbered group of 1 to 200 vehicles."
             )

      assert Operations.list_vehicles(organization.id, %{}) == []

      # The refused submit keeps the mode and both entries.
      assert has_element?(view, "#vehicle-range-form")
      assert has_element?(view, "#range_first[value='1201']")
      assert has_element?(view, "#range_last[value='1401']")
      refute has_element?(view, "#vehicle-notice")
    end

    test "a collision names the existing IDs and adds nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "1203"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)
      choose_numbered_group(view)
      submit_range(view, %{"first" => "1201", "last" => "1203"})

      assert has_element?(
               view,
               "#vehicle-form-error",
               "No vehicles were added. These IDs already exist: 1201, 1203. Choose unused numbers."
             )

      assert stored_ids(organization) == ["1201", "1203"]
      assert has_element?(view, "#vehicle-range-form")
      assert has_element?(view, "#range_first[value='1201']")
    end

    test "a successful range reports its count and assigns every row", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)
      choose_numbered_group(view)

      view
      |> element("#vehicle-range-form")
      |> render_change(%{
        "range" => %{"first" => "1201", "last" => "1215", "garage_id" => garage.id}
      })

      assert has_element?(view, "#range-preview", "Adds 1201–1215 (15 vehicles)")

      submit_range(view, %{
        "first" => "1201",
        "last" => "1215",
        "vehicle_type_id" => vehicle_type.id,
        "garage_id" => garage.id
      })

      assert has_element?(view, "dialog#vehicle-drawer-overlay[data-open='false']")
      assert has_element?(view, "#vehicle-notice", "15 vehicles added.")

      vehicles = Operations.list_vehicles(organization.id, %{})
      assert Enum.map(vehicles, & &1.vehicle_id) == Enum.map(1201..1215, &Integer.to_string/1)
      assert Enum.all?(vehicles, &(&1.vehicle_type_id == vehicle_type.id))
      assert Enum.all?(vehicles, &(&1.garage_id == garage.id))

      assert has_element?(view, "#vehicles-count", "15 of 15 vehicles")
      assert has_element?(view, "#fleet-summary", "15 vehicles total")
    end
  end

  describe "editing a vehicle" do
    setup :editor_setup

    test "editing saves label, type, garage and plate", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#vehicle-id-#{vehicle.id}") |> render_click()

      assert has_element?(view, "#vehicle-drawer-overlay[data-open='true']")
      assert has_element?(view, "#vehicle-drawer-title", "Edit vehicle")
      assert has_element?(view, "#vehicle-drawer-description", "Update this vehicle")
      assert has_element?(view, "#vehicle_vehicle_id[value='1201']")
      # Editing keeps one vehicle: no mode switch, no numbered group.
      refute has_element?(view, "#vehicle-mode")
      refute has_element?(view, "#vehicle-range-form")

      submit_vehicle(view, %{
        "vehicle_id" => "1201",
        "vehicle_label" => "River shuttle",
        "vehicle_type_id" => vehicle_type.id,
        "garage_id" => garage.id,
        "license_plate" => "CV 201"
      })

      assert [saved] = Operations.list_vehicles(organization.id, %{})
      assert saved.vehicle_id == "1201"
      assert saved.vehicle_label == "River shuttle"
      assert saved.vehicle_type_id == vehicle_type.id
      assert saved.garage_id == garage.id
      assert saved.license_plate == "CV 201"

      assert has_element?(view, "#vehicle-notice", "1201 saved.")

      assert has_element?(
               view,
               "tr#vehicles-#{vehicle.id} td[data-label='Label']",
               "River shuttle"
             )

      assert has_element?(view, "tr#vehicles-#{vehicle.id} td[data-label='Type']", "Cutaway")

      assert has_element?(
               view,
               "tr#vehicles-#{vehicle.id} td[data-label='Garage']",
               "Main garage"
             )

      assert has_element?(
               view,
               "tr#vehicles-#{vehicle.id} td[data-label='License plate']",
               "CV 201"
             )
    end

    test "the blank prompt clears an assignment and leaves the other one alone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      vehicle =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "1201",
          "garage_id" => garage.id,
          "vehicle_type_id" => vehicle_type.id
        })

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#vehicle-id-#{vehicle.id}") |> render_click()

      assert has_element?(view, "#vehicle_garage_id option[value='#{garage.id}'][selected]")

      submit_vehicle(view, %{
        "vehicle_id" => "1201",
        "vehicle_type_id" => vehicle_type.id,
        "garage_id" => ""
      })

      assert [saved] = Operations.list_vehicles(organization.id, %{})
      assert saved.garage_id == nil
      assert saved.vehicle_type_id == vehicle_type.id

      assert has_element?(
               view,
               "tr#vehicles-#{vehicle.id} td[data-label='Garage']",
               "Not assigned"
             )

      assert has_element?(view, "tr#vehicles-#{vehicle.id} td[data-label='Type']", "Cutaway")
    end

    test "a foreign or missing vehicle id opens nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      foreign_vehicle = vehicle_fixture(organization_fixture().id)
      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      view |> element("#vehicle-id-#{vehicle.id}") |> render_click()
      view |> element("#vehicle-drawer-close") |> render_click()

      render_click(view, "open_vehicle", %{"vehicle_id" => foreign_vehicle.id})
      assert has_element?(view, "dialog#vehicle-drawer-overlay[data-open='false']")

      render_click(view, "open_vehicle", %{"vehicle_id" => "not-a-uuid"})
      assert has_element?(view, "dialog#vehicle-drawer-overlay[data-open='false']")
    end
  end

  describe "normal-route persistence" do
    setup :editor_setup

    test "a numbered group persists padded IDs and a collision inserts nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      open_add_drawer(view)
      choose_numbered_group(view)

      # The preview and the write agree on the padding rule.
      view
      |> element("#vehicle-range-form")
      |> render_change(%{"range" => %{"first" => "0098", "last" => "0102"}})

      assert has_element?(view, "#range-preview", "Adds 0098–0102 (5 vehicles)")

      submit_range(view, %{
        "first" => "0098",
        "last" => "0102",
        "garage_id" => garage.id,
        "vehicle_type_id" => vehicle_type.id
      })

      assert has_element?(view, "#vehicle-notice", "5 vehicles added.")
      assert stored_ids(organization) == ["0098", "0099", "0100", "0101", "0102"]

      # A colliding group adds none of its IDs.
      open_add_drawer(view)
      choose_numbered_group(view)
      submit_range(view, %{"first" => "0100", "last" => "0104"})

      assert has_element?(
               view,
               "#vehicle-form-error",
               "These IDs already exist: 0100, 0101, 0102"
             )

      assert stored_ids(organization) == ["0098", "0099", "0100", "0101", "0102"]

      assert has_element?(view, "#vehicles-count", "5 of 5 vehicles")
      assert has_element?(view, "#fleet-summary", "5 vehicles total")
    end
  end
end

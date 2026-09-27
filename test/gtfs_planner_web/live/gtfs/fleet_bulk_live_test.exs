defmodule GtfsPlannerWeb.Gtfs.FleetBulkLiveTest do
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

  defp fleet_url(version, query \\ nil),
    do: "/gtfs/#{version.id}#{@fleet_path}#{query_suffix(query)}"

  defp query_suffix(nil), do: ""
  defp query_suffix(encoded), do: "?#{encoded}"

  defp stored(organization),
    do: Map.new(Operations.list_vehicles(organization.id, %{}), &{&1.vehicle_id, &1})

  defp select_vehicle(view, vehicle),
    do: view |> element("#select-vehicle-#{vehicle.id}") |> render_click()

  defp select_all(view), do: view |> element("#select-all-vehicles") |> render_click()

  defp open_bulk(view, field), do: view |> element("#bulk-set-#{field}") |> render_click()

  # A crafted id has no row to click, so the event carries it directly — exactly
  # what a hand-made payload does.
  defp craft_selection(view, vehicle_id) do
    render_click(view, "toggle_vehicle_selection", %{"vehicle_id" => vehicle_id})
  end

  defp submit_bulk(view, value) do
    render_submit(view, "save_bulk_assignment", %{"bulk" => %{"value" => value}})
  end

  defp change_filter(view, params) do
    view |> element("#vehicle-filters") |> render_change(params)
  end

  defp blank_filter(value), do: %{"q" => value, "type" => "", "garage" => ""}

  describe "selecting vehicles" do
    setup :editor_setup

    test "select-all takes only the rows the filter shows", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})

      river =
        vehicle_fixture(organization.id, %{"vehicle_id" => "1201", "vehicle_label" => "River"})

      coach =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "1202",
          "vehicle_label" => "River coach"
        })

      depot =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "1301",
          "vehicle_label" => "Depot spare"
        })

      {:ok, view, _html} = live(conn, fleet_url(version, "q=River"))

      assert has_element?(view, "#vehicles-count", "2 of 3 vehicles")
      assert has_element?(view, "tr#vehicles-#{coach.id}")
      refute has_element?(view, "tr#vehicles-#{depot.id}")

      select_all(view)

      assert has_element?(view, "#select-all-vehicles[checked]")
      assert has_element?(view, "#select-vehicle-#{river.id}[checked]")
      assert has_element?(view, "#bulk-bar-count", "2 vehicles selected")

      open_bulk(view, "garage")
      assert has_element?(view, "#bulk-drawer-overlay[data-open='true']")
      assert has_element?(view, "#bulk-drawer-title", "Set garage")
      submit_bulk(view, garage.id)

      assert has_element?(view, "#vehicle-notice", "Garage updated on 2 vehicles.")
      assert has_element?(view, "dialog#bulk-drawer-overlay[data-open='false']")

      after_bulk = stored(organization)
      assert after_bulk["1201"].garage_id == garage.id
      assert after_bulk["1202"].garage_id == garage.id
      assert is_nil(after_bulk["1301"].garage_id)

      refute has_element?(view, "#bulk-bar")
    end

    test "a row checkbox toggles one vehicle and Clear selection empties the bar", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      first = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})
      second = vehicle_fixture(organization.id, %{"vehicle_id" => "1202"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      refute has_element?(view, "#bulk-bar")

      select_vehicle(view, first)
      assert has_element?(view, "#bulk-bar-count", "1 vehicle selected")
      assert has_element?(view, "#select-vehicle-#{first.id}[checked]")
      refute has_element?(view, "#select-all-vehicles[checked]")

      select_vehicle(view, second)
      assert has_element?(view, "#bulk-bar-count", "2 vehicles selected")
      assert has_element?(view, "#select-all-vehicles[checked]")

      select_vehicle(view, first)
      assert has_element?(view, "#bulk-bar-count", "1 vehicle selected")
      refute has_element?(view, "#select-vehicle-#{first.id}[checked]")

      view |> element("#bulk-clear-selection") |> render_click()

      refute has_element?(view, "#bulk-bar")
      refute has_element?(view, "#select-vehicle-#{second.id}[checked]")
      refute has_element?(view, "#select-all-vehicles[checked]")
    end

    test "a filter change clears the selection", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      first = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "1202"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      select_vehicle(view, first)
      assert has_element?(view, "#bulk-bar-count", "1 vehicle selected")

      change_filter(view, blank_filter("1202"))

      assert_patch(view, fleet_url(version, "q=1202"))
      refute has_element?(view, "#bulk-bar")
      refute has_element?(view, "#select-all-vehicles[checked]")

      change_filter(view, blank_filter(""))

      refute has_element?(view, "#select-vehicle-#{first.id}[checked]")
      refute has_element?(view, "#bulk-bar")
    end

    test "a crafted field name opens no drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      select_vehicle(view, vehicle)

      render_click(view, "open_bulk_drawer", %{"field" => "license_plate"})

      assert has_element?(view, "dialog#bulk-drawer-overlay[data-open='false']")
    end
  end

  describe "bulk assignment" do
    setup :editor_setup

    test "set type changes only the type", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      stored_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
      chosen_type = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})

      first =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "1201",
          "vehicle_type_id" => stored_type.id,
          "garage_id" => garage.id
        })

      second =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "1202",
          "vehicle_type_id" => stored_type.id,
          "garage_id" => garage.id
        })

      {:ok, view, _html} = live(conn, fleet_url(version))

      select_vehicle(view, first)
      select_vehicle(view, second)
      assert has_element?(view, "#bulk-bar-count", "2 vehicles selected")

      open_bulk(view, "type")

      assert has_element?(view, "#bulk-drawer-title", "Set type")
      assert has_element?(view, "#bulk_value option[value='#{chosen_type.id}']")
      assert has_element?(view, "#bulk_value option[value='']", "Not assigned")

      submit_bulk(view, chosen_type.id)

      assert has_element?(view, "#vehicle-notice", "Type updated on 2 vehicles.")

      after_bulk = stored(organization)
      assert after_bulk["1201"].vehicle_type_id == chosen_type.id
      assert after_bulk["1202"].vehicle_type_id == chosen_type.id
      assert after_bulk["1201"].garage_id == garage.id
      assert after_bulk["1202"].garage_id == garage.id

      assert has_element?(view, "tr#vehicles-#{first.id} td[data-label='Type']", "35-ft diesel")
      assert has_element?(view, "tr#vehicles-#{first.id} td[data-label='Garage']", "Main garage")
    end

    test "set garage changes only the garage, and Not assigned clears just it", %{
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
          "vehicle_type_id" => vehicle_type.id
        })

      {:ok, view, _html} = live(conn, fleet_url(version))

      select_vehicle(view, vehicle)

      open_bulk(view, "garage")

      assert has_element?(view, "#bulk-drawer-title", "Set garage")
      assert has_element?(view, "#bulk_value option[value='#{garage.id}']")

      submit_bulk(view, garage.id)

      assert has_element?(view, "#vehicle-notice", "Garage updated on 1 vehicle.")
      assert stored(organization)["1201"].garage_id == garage.id
      assert stored(organization)["1201"].vehicle_type_id == vehicle_type.id

      select_vehicle(view, vehicle)
      open_bulk(view, "garage")
      submit_bulk(view, "")

      after_clear = stored(organization)["1201"]
      assert is_nil(after_clear.garage_id)
      assert after_clear.vehicle_type_id == vehicle_type.id

      assert has_element?(
               view,
               "tr#vehicles-#{vehicle.id} td[data-label='Garage']",
               "Not assigned"
             )

      assert has_element?(view, "tr#vehicles-#{vehicle.id} td[data-label='Type']", "Cutaway")
    end

    test "a crafted foreign vehicle id changes nothing and reports the refreshed list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      local = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      foreign_organization = organization_fixture()

      foreign =
        vehicle_fixture(foreign_organization.id, %{
          "vehicle_id" => "9001",
          "garage_id" => garage_fixture(foreign_organization.id, %{"name" => "Foreign depot"}).id
        })

      {:ok, view, _html} = live(conn, fleet_url(version))

      craft_selection(view, foreign.id)

      assert has_element?(view, "#bulk-bar-count", "1 vehicle selected")
      assert has_element?(view, "tr#vehicles-#{local.id}")
      refute has_element?(view, "tr#vehicles-#{foreign.id}")

      open_bulk(view, "garage")
      submit_bulk(view, garage.id)

      assert has_element?(
               view,
               "#bulk-error",
               "Some vehicles are no longer available. The list has been refreshed."
             )

      refute has_element?(view, "#bulk-bar")
      assert has_element?(view, "dialog#bulk-drawer-overlay[data-open='false']")
      assert is_nil(stored(organization)["1201"].garage_id)
      assert length(Operations.list_vehicles(organization.id, %{})) == 1

      foreign_stored = Operations.list_vehicles(foreign_organization.id, %{})
      assert [unchanged] = foreign_stored
      assert unchanged.garage_id
      assert unchanged.updated_by_id == foreign.updated_by_id
    end

    test "a crafted foreign garage target changes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})
      foreign_garage = garage_fixture(organization_fixture().id, %{"name" => "Foreign depot"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      select_vehicle(view, vehicle)
      open_bulk(view, "garage")
      submit_bulk(view, foreign_garage.id)

      assert has_element?(
               view,
               "#bulk-error",
               "Some vehicles are no longer available. The list has been refreshed."
             )

      assert is_nil(stored(organization)["1201"].garage_id)
      assert length(Operations.list_vehicles(organization.id, %{})) == 1
    end

    test "a malformed UUID payload fails safely like an unknown UUID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      # A malformed selected id.
      craft_selection(view, "not-a-uuid")

      assert has_element?(view, "#bulk-bar-count", "1 vehicle selected")

      open_bulk(view, "type")
      submit_bulk(view, vehicle_type.id)

      assert has_element?(
               view,
               "#bulk-error",
               "Some vehicles are no longer available. The list has been refreshed."
             )

      assert is_nil(stored(organization)["1201"].vehicle_type_id)

      # A malformed target.
      select_vehicle(view, vehicle)
      open_bulk(view, "type")
      submit_bulk(view, "not-a-uuid")

      assert has_element?(
               view,
               "#bulk-error",
               "Some vehicles are no longer available. The list has been refreshed."
             )

      assert is_nil(stored(organization)["1201"].vehicle_type_id)
    end
  end

  describe "bulk deletion" do
    setup :editor_setup

    test "delete asks for confirmation naming the vehicles, and only then removes them", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "1202"})
      vehicle_fixture(organization.id, %{"vehicle_id" => "1203"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      select_all(view)

      view |> element("#bulk-delete") |> render_click()

      assert has_element?(view, "#bulk-delete-confirm-title", "Delete 3 vehicles?")
      assert has_element?(view, "#bulk-delete-ids", "1201")
      assert has_element?(view, "#bulk-delete-ids", "1202")
      assert has_element?(view, "#bulk-delete-ids", "1203")
      refute has_element?(view, "#bulk-delete-more")

      view |> element("#bulk-delete-confirm-cancel") |> render_click()

      refute has_element?(view, "#bulk-delete-confirm")
      assert length(Operations.list_vehicles(organization.id, %{})) == 3

      view |> element("#bulk-delete") |> render_click()
      view |> element("#bulk-delete-confirm-confirm") |> render_click()

      assert has_element?(view, "#vehicle-notice", "3 vehicles deleted.")
      assert Operations.list_vehicles(organization.id, %{}) == []
      assert has_element?(view, "#vehicles-first-use-empty")
      refute has_element?(view, "#bulk-bar")
    end

    test "delete names at most five vehicles and reports the rest", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      Enum.each(1201..1207, fn number ->
        vehicle_fixture(organization.id, %{"vehicle_id" => Integer.to_string(number)})
      end)

      {:ok, view, _html} = live(conn, fleet_url(version))

      select_all(view)

      view |> element("#bulk-delete") |> render_click()

      assert has_element?(view, "#bulk-delete-confirm-title", "Delete 7 vehicles?")

      listed = view |> element("#bulk-delete-ids") |> render()
      assert length(Regex.scan(~r/<li/, listed)) == 5
      assert listed =~ "1201"
      assert listed =~ "1205"
      refute listed =~ "1206"

      assert has_element?(view, "#bulk-delete-more", "and 2 more")

      view |> element("#bulk-delete-confirm-cancel") |> render_click()

      assert length(Operations.list_vehicles(organization.id, %{})) == 7
    end
  end
end

defmodule GtfsPlannerWeb.Gtfs.GarageEditorLiveTest do
  # `async: false` follows the other LiveView tests that swap the geocoding
  # adapter with Mox, so the expectation set in the test process is the one the
  # LiveView process observes.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Operations

  @garages_path "/settings/garages"

  @selected_result %GtfsPlanner.Geocoding.Result{
    formatted_address: "120 Depot Road, Cedar Valley",
    lat: 44.4759,
    lon: -73.2121,
    city: "Cedar Valley"
  }

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

  defp open_editor(conn, user, organization, version, path \\ @garages_path) do
    conn = log_in_user(conn, user, organization: organization)
    live(conn, "/gtfs/#{version.id}#{path}")
  end

  # Every add test starts from an organization with no garages, where the
  # first-use panel carries the create action.
  defp open_add(view), do: view |> element("#add-garage-empty") |> render_click()

  defp open_edit(view, garage) do
    view |> element("#garage-name-#{garage.id}") |> render_click()
  end

  defp change(view, garage_params, target) do
    render_change(view, "validate_garage", %{"_target" => target, "garage" => garage_params})
  end

  defp garage_params(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    Map.merge(
      %{"name" => "", "garage_id" => "", "address" => "", "lat" => "", "lon" => ""},
      attrs
    )
  end

  describe "ID defaulting" do
    setup :editor_setup

    test "a new garage derives its ID from the name until the ID field is edited", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      change(view, garage_params(name: "Main Garage"), "garage[name]")
      assert has_element?(view, "#garage_garage_id[value='garage_main_garage']")

      # Typing the ID counts as editing, so a later name change leaves it alone.
      change(
        view,
        garage_params(name: "Main Garage", garage_id: "garage_custom"),
        "garage[garage_id]"
      )

      assert has_element?(view, "#garage_garage_id[value='garage_custom']")

      change(
        view,
        garage_params(name: "Renamed Garage", garage_id: "garage_custom"),
        "garage[name]"
      )

      assert has_element?(view, "#garage_garage_id[value='garage_custom']")
    end

    test "clearing the ID field counts as editing and never restores auto-generation", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      change(view, garage_params(name: "North yard", garage_id: ""), "garage[garage_id]")
      assert has_element?(view, "#garage_garage_id[value='']")

      change(view, garage_params(name: "North depot", garage_id: ""), "garage[name]")
      assert has_element?(view, "#garage_garage_id[value='']")
    end

    test "a saved garage never regenerates its ID from a name change", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main", "name" => "Main"})

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_edit(view, garage)

      change(
        view,
        garage_params(name: "Main garage renamed", garage_id: "garage_main"),
        "garage[name]"
      )

      assert has_element?(view, "#garage_garage_id[value='garage_main']")
      assert has_element?(view, "#garage-id-change-hint")
    end
  end

  describe "drawer wording" do
    setup :editor_setup

    test "a new garage says its ID is filled in and offers Create garage", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      assert has_element?(view, "#garage-drawer-title", "Create garage")
      assert has_element?(view, "#garage-drawer-scope", "Shared across all versions")
      assert has_element?(view, "#garage_garage_id-help", "Filled in from the name.")
      assert has_element?(view, "#garage-save", "Create garage")
      refute has_element?(view, "#garage-delete")
      refute has_element?(view, "#garage-assigned-vehicles")
      refute has_element?(view, "#garage-id-change-hint")
    end

    test "a saved garage names itself, keeps its ID unfilled and offers Save changes", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main", "name" => "Main"})

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_edit(view, garage)

      assert has_element?(view, "#garage-drawer-title", "Edit garage")
      assert has_element?(view, "#garage-drawer-scope", "Main · shared across all versions")
      refute has_element?(view, "#garage_garage_id-help", "Filled in from the name.")
      assert has_element?(view, "#garage-save", "Save changes")
      assert has_element?(view, "#garage-delete", "Delete garage")
    end

    test "the reference note counts one vehicle, several and none in plain words", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      one = garage_fixture(organization.id, %{"garage_id" => "garage_one", "name" => "One"})
      many = garage_fixture(organization.id, %{"garage_id" => "garage_many", "name" => "Many"})
      none = garage_fixture(organization.id, %{"garage_id" => "garage_none", "name" => "None"})

      vehicle_fixture(organization.id, %{"garage_id" => one.id})
      vehicle_fixture(organization.id, %{"garage_id" => many.id})
      vehicle_fixture(organization.id, %{"garage_id" => many.id})

      {:ok, view, _html} = open_editor(conn, user, organization, version)

      open_edit(view, one)

      assert has_element?(
               view,
               "#garage-assigned-vehicles",
               "Used by 1 vehicle. To delete it, first change those."
             )

      view |> element("#garage-drawer-close") |> render_click()
      open_edit(view, many)

      assert has_element?(
               view,
               "#garage-assigned-vehicles",
               "Used by 2 vehicles. To delete it, first change those."
             )

      view |> element("#garage-drawer-close") |> render_click()
      open_edit(view, none)

      assert has_element?(
               view,
               "#garage-assigned-vehicles",
               "Nothing uses this garage, so you can delete it without moving anything."
             )
    end

    test "the reference note names a garage only a block or a route uses", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      by_block =
        garage_fixture(organization.id, %{"garage_id" => "garage_block", "name" => "Block"})

      by_route =
        garage_fixture(organization.id, %{"garage_id" => "garage_route", "name" => "Route"})

      live_block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "12",
        garage_id: by_block.id
      })

      live_route_setting_fixture(organization.id, version.id, %{
        route_id: "10",
        garage_id: by_route.id
      })

      {:ok, view, _html} = open_editor(conn, user, organization, version)

      open_edit(view, by_block)

      assert has_element?(
               view,
               "#garage-assigned-vehicles",
               "Used by 1 block. To delete it, first change those."
             )

      refute has_element?(view, "#garage-assigned-vehicles", "Nothing uses this garage")

      view |> element("#garage-drawer-close") |> render_click()
      open_edit(view, by_route)

      assert has_element?(
               view,
               "#garage-assigned-vehicles",
               "Used by 1 route. To delete it, first change those."
             )
    end

    test "the reference note ignores a block or route that no longer exists", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      garage = garage_fixture(organization.id, %{"garage_id" => "garage_main", "name" => "Main"})

      block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "12",
        garage_id: garage.id
      })

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "10",
        garage_id: garage.id
      })

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_edit(view, garage)

      assert has_element?(
               view,
               "#garage-assigned-vehicles",
               "Nothing uses this garage, so you can delete it without moving anything."
             )

      view |> element("#garage-delete") |> render_click()
      view |> element("#garage-delete-confirm-confirm") |> render_click()

      assert has_element?(view, "#garage-notice", "Main deleted.")
      assert Operations.list_garages(organization.id) == []
    end
  end

  describe "address search" do
    setup :editor_setup

    setup do
      Mox.set_mox_global()
      :ok
    end

    test "a geocoding result fills the coordinates", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Depot", _opts ->
        {:ok, [@selected_result]}
      end)

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      render_hook(view, "live_select_change", %{"text" => "Depot", "id" => "garage-address"})
      render_async(view)

      # LiveSelect writes the selection into the form's hidden address input, whose
      # change names `garage[address]` as the target.
      change(
        view,
        garage_params(name: "Riverside storage", address: "120 Depot Road, Cedar Valley"),
        "garage[address]"
      )

      assert has_element?(view, "#garage_lat[value='44.4759']")
      assert has_element?(view, "#garage_lon[value='-73.2121']")
      refute has_element?(view, "#garage-address-retry")
    end

    test "a failed geocoding call shows the unavailable hint and keeps coordinates editable", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Depot", _opts ->
        {:error, :network_error}
      end)

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      render_hook(view, "live_select_change", %{"text" => "Depot", "id" => "garage-address"})
      render_async(view)

      assert has_element?(
               view,
               "#garage-address-search-status",
               "Address search is unavailable."
             )

      assert has_element?(view, "#garage-address-retry", "Retry search")

      change(
        view,
        garage_params(name: "Riverside", lat: "44.4503", lon: "-73.2202"),
        "garage[lat]"
      )

      assert has_element?(view, "#garage_lat[value='44.4503']")
      assert has_element?(view, "#garage_lon[value='-73.2202']")
    end

    test "a later search wins while the earlier task is still waiting", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      test_pid = self()

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, 2, fn text, _opts ->
        case text do
          "Main" ->
            send(test_pid, {:slow_search, self()})

            receive do
              {:release_search, :main} -> {:ok, [@selected_result]}
            after
              5_000 -> {:error, :timeout}
            end

          "Main St" ->
            {:ok, [Map.put(@selected_result, :formatted_address, "Main St, Cedar Valley")]}
        end
      end)

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      render_hook(view, "live_select_change", %{"text" => "Main", "id" => "garage-address"})
      assert_receive {:slow_search, slow_task}
      assert has_element?(view, "#garage-address-search-status", "Searching addresses…")

      # An ordinary drawer event still completes while the first request waits.
      change(view, garage_params(name: "Main garage"), "garage[name]")
      assert has_element?(view, "#garage_garage_id[value='garage_main_garage']")

      render_hook(view, "live_select_change", %{"text" => "Main St", "id" => "garage-address"})
      render_async(view)
      assert has_element?(view, "#garage-address", "Main St, Cedar Valley")

      ref = Process.monitor(slow_task)
      send(slow_task, {:release_search, :main})
      assert_receive {:DOWN, ^ref, :process, ^slow_task, :normal}
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#garage-address", "Main St, Cedar Valley")
      refute has_element?(view, "#garage-address", "120 Depot Road, Cedar Valley")
    end

    test "the drawer can close while address search is pending", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      test_pid = self()

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Main", _opts ->
        send(test_pid, {:pending_search, self()})

        receive do
          :release_search -> {:ok, [@selected_result]}
        after
          5_000 -> {:error, :timeout}
        end
      end)

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)
      render_hook(view, "live_select_change", %{"text" => "Main", "id" => "garage-address"})
      assert_receive {:pending_search, task}

      view |> element("#garage-cancel") |> render_click()
      assert has_element?(view, "dialog#garage-drawer-overlay[data-open='false']")

      ref = Process.monitor(task)
      send(task, :release_search)
      assert_receive {:DOWN, ^ref, :process, ^task, :normal}
      _ = :sys.get_state(view.pid)
      refute has_element?(view, "#garage-address-search-status")
    end

    test "empty results and retry keep the address search recoverable", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      counter = start_supervised!({Agent, fn -> 0 end})

      Mox.expect(GtfsPlanner.GeocodingMock, :autocomplete, 3, fn "Depot", _opts ->
        case Agent.get_and_update(counter, fn attempt -> {attempt, attempt + 1} end) do
          0 -> {:ok, []}
          1 -> {:error, :network_error}
          _ -> {:ok, [@selected_result]}
        end
      end)

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      render_hook(view, "live_select_change", %{"text" => "Depot", "id" => "garage-address"})
      render_async(view)
      assert has_element?(view, "#garage-address-search-status", "No matching addresses")

      render_hook(view, "live_select_change", %{"text" => "Depot", "id" => "garage-address"})
      render_async(view)
      assert has_element?(view, "#garage-address-retry")

      view |> element("#garage-address-retry") |> render_click()
      render_async(view)
      assert has_element?(view, "#garage-address", "120 Depot Road, Cedar Valley")
      refute has_element?(view, "#garage-address-retry")
      refute has_element?(view, "#garage-form-error")
    end
  end

  describe "validation" do
    setup :editor_setup

    test "a submit with missing coordinates shows field errors and keeps the input", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      render_submit(view, "save_garage", %{
        "garage" => %{
          "name" => "Riverside storage",
          "garage_id" => "garage_river",
          "address" => "",
          "lat" => "",
          "lon" => ""
        }
      })

      assert has_element?(view, "#garage_name[value='Riverside storage']")
      assert has_element?(view, "#garage_lat[aria-invalid='true']")
      assert has_element?(view, "#garage_lon[aria-invalid='true']")
      assert has_element?(view, "#garage-form-error", "Garage not saved")

      assert_push_event(view, "focus_form_error", %{
        form_id: "garage-form",
        fallback_id: "garage-form-error"
      })

      assert Operations.list_garages(organization.id) == []
    end
  end

  describe "ID correction" do
    setup :editor_setup

    test "a used ID is rejected with a field error and an ID change keeps assignments", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      garage =
        garage_fixture(organization.id, %{"garage_id" => "garage_main", "name" => "Main garage"})

      garage_fixture(organization.id, %{"garage_id" => "garage_north", "name" => "North yard"})
      vehicle_fixture(organization.id, %{"garage_id" => garage.id})
      vehicle_fixture(organization.id, %{"garage_id" => garage.id})

      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_edit(view, garage)

      assert has_element?(view, "#garage-assigned-vehicles", "Used by 2 vehicles.")

      render_submit(view, "save_garage", %{
        "garage" => %{
          "name" => "Main garage",
          "garage_id" => "garage_north",
          "address" => "",
          "lat" => "40.7128",
          "lon" => "-74.0060"
        }
      })

      assert has_element?(view, "#garage_garage_id[aria-invalid='true']")
      assert has_element?(view, "tr#garages-#{garage.id}", "garage_main")

      render_submit(view, "save_garage", %{
        "garage" => %{
          "name" => "Main garage",
          "garage_id" => "garage_depot",
          "address" => "",
          "lat" => "40.7128",
          "lon" => "-74.0060"
        }
      })

      assert has_element?(view, "tr#garages-#{garage.id}", "garage_depot")
      assert has_element?(view, "tr#garages-#{garage.id} td[data-label='Vehicles']", "2 vehicles")
      assert has_element?(view, "#garage-notice", "Main garage saved.")
    end
  end

  describe "deletion" do
    setup :editor_setup

    test "an in-use garage explains the block and an unused garage needs confirmation", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      in_use =
        garage_fixture(organization.id, %{"garage_id" => "garage_main", "name" => "Main garage"})

      unused =
        garage_fixture(organization.id, %{
          "garage_id" => "garage_river",
          "name" => "Riverside storage"
        })

      vehicle_fixture(organization.id, %{"garage_id" => in_use.id})
      vehicle_fixture(organization.id, %{"garage_id" => in_use.id})

      {:ok, view, _html} = open_editor(conn, user, organization, version)

      open_edit(view, in_use)
      view |> element("#garage-delete") |> render_click()

      assert has_element?(view, "#garage-in-use-dialog", "Can't delete Main garage")

      assert has_element?(
               view,
               "#garage-in-use-dialog-body",
               "Main garage is used by 2 vehicles. Change those first."
             )

      refute has_element?(view, "#garage-delete-confirm")
      assert Enum.count(Operations.list_garages(organization.id)) == 2

      view |> element("#garage-in-use-dialog-cancel") |> render_click()
      refute has_element?(view, "#garage-in-use-dialog")

      view |> element("#garage-drawer-close") |> render_click()
      open_edit(view, unused)
      view |> element("#garage-delete") |> render_click()

      assert has_element?(
               view,
               "#garage-delete-confirm-body",
               "This removes the garage from every service version. You can't undo it."
             )

      # Cancelling keeps the garage.
      view |> element("#garage-delete-confirm-cancel") |> render_click()
      assert has_element?(view, "tr#garages-#{unused.id}")

      # Confirming removes it and refreshes the list.
      view |> element("#garage-name-#{unused.id}") |> render_click()
      view |> element("#garage-delete") |> render_click()
      view |> element("#garage-delete-confirm-confirm") |> render_click()

      refute has_element?(view, "tr#garages-#{unused.id}")
      assert has_element?(view, "#garage-notice", "Riverside storage deleted.")
      assert Enum.map(Operations.list_garages(organization.id), & &1.id) == [in_use.id]
    end

    test "a garage a block and a route name is refused and the page names both", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      in_use =
        garage_fixture(organization.id, %{"garage_id" => "garage_main", "name" => "Main"})

      unused =
        garage_fixture(organization.id, %{"garage_id" => "garage_river", "name" => "Riverside"})

      live_block_attribute_fixture(organization.id, version.id, %{
        service_id: "weekday",
        block_id: "12",
        garage_id: in_use.id
      })

      live_route_setting_fixture(organization.id, version.id, %{
        route_id: "10",
        garage_id: in_use.id
      })

      {:ok, view, _html} = open_editor(conn, user, organization, version)

      open_edit(view, in_use)

      assert has_element?(
               view,
               "#garage-assigned-vehicles",
               "Used by 1 block and 1 route. To delete it, first change those."
             )

      view |> element("#garage-delete") |> render_click()

      assert has_element?(
               view,
               "#garage-in-use-dialog",
               "Main is used by 1 block and 1 route. Change those first."
             )

      refute has_element?(view, "#garage-delete-confirm")

      # Both references and the garage itself survive the refusal.
      assert Operations.garage_in_use_counts(organization.id, in_use.id) ==
               %{vehicles: 0, blocks: 1, routes: 1}

      view |> element("#garage-in-use-dialog-cancel") |> render_click()

      assert Operations.list_garages(organization.id) |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([in_use.id, unused.id])
    end
  end

  describe "saving" do
    setup :editor_setup

    test "a normal submission persists coordinates and returns to a refreshed list", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {:ok, view, _html} = open_editor(conn, user, organization, version)
      open_add(view)

      render_submit(view, "save_garage", %{
        "garage" => %{
          "name" => "Riverside storage",
          "garage_id" => "garage_river",
          "address" => "16 River Road",
          "lat" => "44.4503",
          "lon" => "-73.2202"
        }
      })

      assert has_element?(view, "dialog#garage-drawer-overlay[data-open='false']")
      refute has_element?(view, "#garage-form-error")
      assert has_element?(view, "#garage-notice", "Riverside storage saved.")

      assert has_element?(view, "#garages-table", "Riverside storage")
      assert has_element?(view, "#garages-table", "16 River Road")
      assert has_element?(view, "#garages-status", "1 garage · 0 vehicles assigned")

      assert [garage] = Operations.list_garages(organization.id)
      assert garage.garage_id == "garage_river"
      assert Decimal.equal?(garage.lat, Decimal.new("44.4503"))
      assert Decimal.equal?(garage.lon, Decimal.new("-73.2202"))
    end
  end
end

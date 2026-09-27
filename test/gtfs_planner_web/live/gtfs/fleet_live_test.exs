defmodule GtfsPlannerWeb.Gtfs.FleetLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Versions

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

  describe "first use and filtered empty" do
    setup :editor_setup

    test "an organization without vehicles sees first use, not an empty table", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(view, "#vehicles-first-use-empty", "Add your first vehicles")
      assert has_element?(view, "#add-vehicles", "Add vehicles")
      refute has_element?(view, "#vehicles-table")
      refute has_element?(view, "#vehicle-filters")
      refute has_element?(view, "#vehicles-filtered-empty")
      refute has_element?(view, "#fleet-summary")
      refute has_element?(view, "#vehicles-count")
    end

    test "a filter that matches nothing shows the filtered-empty state, distinct from first use",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version, "q=zzz"))

      assert has_element?(view, "#vehicles-filtered-empty", "No vehicles match")
      assert has_element?(view, "#clear-filters-empty", "Clear filters")
      assert has_element?(view, "#vehicle-filters")
      refute has_element?(view, "#vehicles-first-use-empty")
      refute has_element?(view, "#vehicles-table")
      refute has_element?(view, "#vehicles-count")
    end

    test "Clear filters patches back to the unfiltered list and restores the table", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version, "q=zzz"))

      view |> element("#clear-filters-empty") |> render_click()

      assert_patch(view, fleet_url(version))

      assert has_element?(view, "tr#vehicles-#{vehicle.id}", "1201")
      assert has_element?(view, "#vehicles-count", "1 of 1 vehicles")
      refute has_element?(view, "#vehicles-filtered-empty")
    end
  end

  describe "filters" do
    setup :editor_setup

    test "type, garage and q filters survive a live/2 reload and render their controls", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      garage = garage_fixture(organization.id, %{"name" => "Main garage"})
      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      matching =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "1201",
          "vehicle_label" => "River shuttle",
          "vehicle_type_id" => vehicle_type.id,
          "garage_id" => garage.id
        })

      vehicle_fixture(organization.id, %{
        "vehicle_id" => "1301",
        "vehicle_label" => "Spare vehicle"
      })

      query = "type=#{vehicle_type.id}&garage=#{garage.id}&q=river"

      {:ok, view, _html} = live(conn, fleet_url(version, query))

      assert has_element?(view, "tr#vehicles-#{matching.id}", "1201")
      assert has_element?(view, "#vehicles-count", "1 of 2 vehicles")
      assert has_element?(view, "#vehicle-filters #q[value='river']")

      assert has_element?(
               view,
               "#vehicle-filters #type option[value='#{vehicle_type.id}'][selected]"
             )

      assert has_element?(view, "#vehicle-filters #garage option[value='#{garage.id}'][selected]")

      {:ok, reloaded_view, _html} = live(conn, fleet_url(version, query))

      assert has_element?(reloaded_view, "tr#vehicles-#{matching.id}", "1201")
      assert has_element?(reloaded_view, "#vehicles-count", "1 of 2 vehicles")
      assert has_element?(reloaded_view, "#vehicle-filters #q[value='river']")
    end

    test "none selects only the unassigned rows", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      garage = garage_fixture(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)

      assigned =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "1201",
          "garage_id" => garage.id,
          "vehicle_type_id" => vehicle_type.id
        })

      unassigned = vehicle_fixture(organization.id, %{"vehicle_id" => "1301"})

      {:ok, view, _html} = live(conn, fleet_url(version, "garage=none&type=none"))

      assert has_element?(view, "tr#vehicles-#{unassigned.id}", "1301")
      refute has_element?(view, "tr#vehicles-#{assigned.id}")
      assert has_element?(view, "#vehicles-count", "1 of 2 vehicles")
    end

    test "a changed filter patches the URL to the encoded query", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle_type = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})
      matching = vehicle_fixture(organization.id, %{"vehicle_type_id" => vehicle_type.id})

      {:ok, view, _html} = live(conn, fleet_url(version))

      render_change(element(view, "#vehicle-filters"), %{
        "q" => "",
        "type" => vehicle_type.id,
        "garage" => ""
      })

      assert_patch(view, fleet_url(version, "type=#{vehicle_type.id}"))

      assert has_element?(view, "tr#vehicles-#{matching.id}")
      assert has_element?(view, "#clear-filters")
    end

    test "an invalid UUID parameter is ignored rather than hiding every row", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version, "type=not-a-uuid&garage=/bad"))

      assert has_element?(view, "tr#vehicles-#{vehicle.id}", "1201")
      assert has_element?(view, "#vehicles-count", "1 of 1 vehicles")
      assert has_element?(view, "#vehicle-filters #type option[value='']", "All types")
    end
  end

  describe "search contract" do
    setup :editor_setup

    test "literal % and _ characters match themselves instead of SQL wildcards", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      underscore = vehicle_fixture(organization.id, %{"vehicle_id" => "A_B"})
      plain = vehicle_fixture(organization.id, %{"vehicle_id" => "AXB"})
      percent = vehicle_fixture(organization.id, %{"vehicle_id" => "P%1"})
      other = vehicle_fixture(organization.id, %{"vehicle_id" => "PZZ1"})

      {:ok, underscore_view, _html} = live(conn, fleet_url(version, "q=_"))

      assert has_element?(underscore_view, "tr#vehicles-#{underscore.id}", "A_B")
      refute has_element?(underscore_view, "tr#vehicles-#{plain.id}")
      assert has_element?(underscore_view, "#vehicles-count", "1 of 4 vehicles")

      {:ok, percent_view, _html} = live(conn, fleet_url(version, "q=%25"))

      assert has_element?(percent_view, "tr#vehicles-#{percent.id}", "P%1")
      refute has_element?(percent_view, "tr#vehicles-#{other.id}")
      assert has_element?(percent_view, "#vehicles-count", "1 of 4 vehicles")
    end

    test "a wildcard-only query does not raise and keeps the literal semantics", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      plain = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})
      underscore = vehicle_fixture(organization.id, %{"vehicle_id" => "A_B"})
      percent = vehicle_fixture(organization.id, %{"vehicle_id" => "P%1"})

      {:ok, combined_view, _html} = live(conn, fleet_url(version, "q=_%25_"))

      assert has_element?(combined_view, "#vehicles-filtered-empty", "No vehicles match")
      refute has_element?(combined_view, "tr#vehicles-#{plain.id}")
      refute has_element?(combined_view, "tr#vehicles-#{underscore.id}")
      refute has_element?(combined_view, "tr#vehicles-#{percent.id}")

      {:ok, percent_view, _html} = live(conn, fleet_url(version, "q=%25"))

      assert has_element?(percent_view, "tr#vehicles-#{percent.id}", "P%1")
      refute has_element?(percent_view, "tr#vehicles-#{plain.id}")
      assert has_element?(percent_view, "#vehicles-count", "1 of 3 vehicles")
    end
  end

  describe "summary and partial state" do
    setup :editor_setup

    test "#fleet-summary counts per garage and type, the total and those needing an assignment",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)

      main = garage_fixture(organization.id, %{"name" => "Main garage"})
      north = garage_fixture(organization.id, %{"name" => "North yard"})
      cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      for vehicle_id <- ["1001", "1002"] do
        vehicle_fixture(organization.id, %{
          "vehicle_id" => vehicle_id,
          "garage_id" => main.id,
          "vehicle_type_id" => cutaway.id
        })
      end

      vehicle_fixture(organization.id, %{"vehicle_id" => "2001", "garage_id" => main.id})
      vehicle_fixture(organization.id, %{"vehicle_id" => "3001", "vehicle_type_id" => cutaway.id})
      vehicle_fixture(organization.id, %{"vehicle_id" => "4001"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      summary = view |> element("#fleet-summary") |> render()

      assert summary =~ "Main garage"
      assert summary =~ "2 Cutaway · 1 No type"
      assert summary =~ "5 vehicles total"
      assert summary =~ "3 need a garage or type"
      refute summary =~ north.name
    end

    test "the partial warning appears only when a vehicle lacks a type or garage", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      garage = garage_fixture(organization.id)
      vehicle_type = vehicle_type_fixture(organization.id)

      vehicle_fixture(organization.id, %{
        "vehicle_id" => "1201",
        "garage_id" => garage.id,
        "vehicle_type_id" => vehicle_type.id
      })

      {:ok, complete_view, _html} = live(conn, fleet_url(version))

      refute has_element?(complete_view, "#fleet-partial-warning")

      vehicle_fixture(organization.id, %{"vehicle_id" => "1301"})

      {:ok, partial_view, _html} = live(conn, fleet_url(version))

      assert has_element?(partial_view, "#fleet-partial-warning")
      assert partial_view |> element("#fleet-partial-warning") |> render() =~ "type or garage"
    end

    test "the summary and the table show a Not assigned badge for missing values", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      vehicle = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(
               view,
               "tr#vehicles-#{vehicle.id} td[data-label='Type'] .badge",
               "Not assigned"
             )

      assert has_element?(
               view,
               "tr#vehicles-#{vehicle.id} td[data-label='Garage'] .badge",
               "Not assigned"
             )
    end
  end

  describe "version switching" do
    setup :editor_setup

    test "a version switch keeps the active filter query string", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, other_version} = Versions.create_gtfs_version(organization.id, %{name: "V2"})

      vehicle_type = vehicle_type_fixture(organization.id)
      query = "type=#{vehicle_type.id}&q=river"

      {:ok, view, _html} = live(conn, fleet_url(version, query))

      render_hook(view, "switch_gtfs_version", %{"version" => to_string(other_version.id)})

      assert_redirect(view, fleet_url(other_version, query))
    end
  end

  describe "tenant scope" do
    setup :editor_setup

    test "a normal URL entry shows only the caller organization's vehicles", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)

      own = vehicle_fixture(organization.id, %{"vehicle_id" => "1201"})

      other_organization = organization_fixture()
      foreign = vehicle_fixture(other_organization.id, %{"vehicle_id" => "9999"})

      {:ok, view, _html} = live(conn, fleet_url(version))

      assert has_element?(view, "tr#vehicles-#{own.id}", "1201")
      refute has_element?(view, "tr#vehicles-#{foreign.id}")
      assert has_element?(view, "#vehicles-count", "1 of 1 vehicles")
      assert has_element?(view, "#fleet-summary", "1 vehicles total")
    end
  end
end

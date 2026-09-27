defmodule GtfsPlannerWeb.Gtfs.TodsImportLiveTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Operations.Tods

  @garages_path "/blocks/garages"
  @fleet_path "/blocks/fleet"

  @garage_file "test/fixtures/tods/stops_supplement.txt"
  @vehicle_file "test/fixtures/tods/tods_example_vehicles.txt"

  # The message AC-22 fixes for an apply whose recomputed plan no longer matches
  # the reviewed preview.
  @stale_message "Records changed since the preview. Review the updated counts, then import again."

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

  # Enters through the ordinary router with no private assigns and opens the
  # drawer through its real header action.
  defp open_import(conn, user, organization, version, path) do
    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}#{path}")

    assert has_element?(view, "#import-tods:not([disabled])")
    view |> element("#import-tods") |> render_click()
    assert has_element?(view, "#tods-import-drawer-overlay[data-open='true']")

    view
  end

  defp upload_content(view, filename, content) do
    upload =
      file_input(view, "#tods-file-upload", :tods_file, [
        %{name: filename, content: content, type: "text/plain"}
      ])

    render_upload(upload, filename)
  end

  defp upload_fixture(view, path), do: upload_content(view, Path.basename(path), File.read!(path))

  defp count_items(view, selector) do
    document = view |> element(selector) |> render() |> LazyHTML.from_fragment()
    LazyHTML.query(document, "li") |> Enum.count()
  end

  defp garage(organization, garage_id, attrs) do
    garage_fixture(
      organization.id,
      Map.merge(%{"garage_id" => garage_id, "name" => "Stored #{garage_id}"}, attrs)
    )
  end

  describe "Garages import" do
    setup :editor_setup

    test "the extended fixture previews counts, reasons and ignored columns, and apply reports both counts",
         %{conn: conn, user: user, organization: organization, version: version} do
      stored = garage(organization, "garage_east", %{"name" => "East depot"})

      view = open_import(conn, user, organization, version, @garages_path)
      upload_fixture(view, @garage_file)

      assert has_element?(view, "#tods-import-preview", "Review stops_supplement.txt")
      assert has_element?(view, "#tods-import-count-add", "1")
      assert has_element?(view, "#tods-import-count-update", "1")
      assert has_element?(view, "#tods-import-count-skipped", "3")
      assert has_element?(view, "#tods-import-count-error", "0")

      # Skipped reasons come from `Tods.classify/1` verbatim, with their physical
      # row numbers and IDs; unknown columns are listed, and the accepted rows
      # never appear as skipped.
      assert has_element?(
               view,
               "#tods-import-skipped",
               "Row 4 · garage-waypoint · Not a garage (TODS_location_type: waypoint)."
             )

      assert has_element?(
               view,
               "#tods-import-skipped",
               "Row 5 · stop_401 · Changes or adds a public stop; not imported."
             )

      assert has_element?(
               view,
               "#tods-import-skipped",
               "Row 6 · garage_old · Requests a deletion; deletions are not imported."
             )

      refute has_element?(view, "#tods-import-skipped", "garage_main")

      assert has_element?(view, "#tods-import-ignored", "location_type")
      assert has_element?(view, "#tods-import-ignored", "zone_id")
      refute has_element?(view, "#tods-import-ignored", "stop_lat")
      refute has_element?(view, "#tods-import-errors")

      assert has_element?(view, "#apply-tods-import:not([disabled])", "Import 2 garages")

      view |> element("#apply-tods-import") |> render_click()

      assert has_element?(view, "#garage-notice", "Garages imported: 1 added, 1 updated.")
      assert has_element?(view, "#tods-import-drawer-overlay[data-open='false']")
      refute has_element?(view, "#tods-import-preview")

      garages = Operations.list_garages(organization.id)
      assert Enum.map(garages, & &1.garage_id) == ["garage_east", "garage_main"]

      assert Enum.find(garages, &(&1.garage_id == "garage_east")).id == stored.id
      assert has_element?(view, "#garages-table", "garage_main")
    end

    test "a file with errors disables apply and names the row",
         %{conn: conn, user: user, organization: organization, version: version} do
      content = """
      stop_id,stop_name,stop_lat,stop_lon,TODS_location_type
      garage_main,Main garage,45.5121,-122.6587,garage
      garage_main,Main again,45.5121,-122.6587,garage
      """

      view = open_import(conn, user, organization, version, @garages_path)
      upload_content(view, "repeated.txt", content)

      assert has_element?(view, "#tods-import-count-error", "1")
      assert has_element?(view, "#tods-import-count-add", "1")
      assert has_element?(view, "#tods-import-errors", "Repeats garage_main from row 2.")

      assert has_element?(view, "#apply-tods-import[disabled]", "Import 1 garage")

      assert has_element?(
               view,
               "#tods-import-apply-reason",
               "Fix the rows marked as errors before importing."
             )

      # The disabled control is the contract; a crafted event still changes nothing.
      view |> render_click("apply_tods_import")
      assert Operations.list_garages(organization.id) == []
      assert has_element?(view, "#tods-import-drawer-overlay[data-open='true']")
    end

    test "closing and reopening discards the review and any rejected upload",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @garages_path)
      upload_fixture(view, @garage_file)
      assert has_element?(view, "#tods-import-preview")

      view |> element("#tods-import-drawer-close") |> render_click()
      assert has_element?(view, "#tods-import-drawer-overlay[data-open='false']")

      # A rejected file is a pending upload entry: reopening must not show it.
      view |> element("#import-tods") |> render_click()
      upload_content(view, "huge.txt", :binary.copy("a", Tods.max_import_bytes() + 1))
      assert has_element?(view, "#tods-file-upload-rejected", "File is too large")

      view |> element("#tods-import-drawer-close") |> render_click()
      view |> element("#import-tods") |> render_click()

      refute has_element?(view, "#tods-import-preview")
      refute has_element?(view, "#tods-file-upload-rejected")
      assert has_element?(view, "#apply-tods-import[disabled]", "Import 0 garages")

      assert has_element?(
               view,
               "#tods-import-apply-reason",
               "Choose a TODS file to review."
             )

      view |> render_click("apply_tods_import")
      assert Operations.list_garages(organization.id) == []
    end

    test "choosing another file replaces the review and the earlier preview cannot be applied",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @garages_path)
      upload_fixture(view, @garage_file)
      assert has_element?(view, "#tods-import-count-add", "2")

      second = """
      stop_id,stop_name,stop_lat,stop_lon,TODS_location_type
      garage_solo,Solo depot,45.4000,-122.7000,garage
      """

      upload_content(view, "second.txt", second)

      assert has_element?(view, "#tods-import-preview", "Review second.txt")
      assert has_element?(view, "#tods-import-count-add", "1")
      assert has_element?(view, "#tods-import-count-skipped", "0")

      view |> element("#apply-tods-import") |> render_click()

      assert Enum.map(Operations.list_garages(organization.id), & &1.garage_id) == ["garage_solo"]
    end

    test "a stale apply keeps the drawer open with the refreshed preview and the AC-22 message",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @garages_path)
      upload_fixture(view, @garage_file)
      assert has_element?(view, "#tods-import-count-add", "2")

      # Another session creates one of the previewed IDs after the review.
      garage(organization, "garage_main", %{"name" => "Main garage"})

      view |> element("#apply-tods-import") |> render_click()

      assert has_element?(view, "#tods-import-drawer-overlay[data-open='true']")
      assert has_element?(view, "#tods-import-error", @stale_message)
      assert has_element?(view, "#tods-import-count-add", "1")
      assert has_element?(view, "#tods-import-count-update", "1")
      refute has_element?(view, "#garage-notice")

      # Nothing was applied: the competing row is still the only stored garage.
      assert Enum.map(Operations.list_garages(organization.id), & &1.garage_id) == ["garage_main"]

      # The refreshed preview is applicable.
      view |> element("#apply-tods-import") |> render_click()

      assert has_element?(view, "#garage-notice", "Garages imported: 1 added, 1 updated.")
      refute has_element?(view, "#tods-import-error")
    end

    test "an oversized upload shows an error and no preview",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @garages_path)
      upload_content(view, "huge.txt", :binary.copy("a", Tods.max_import_bytes() + 1))

      assert has_element?(view, "#tods-file-upload-rejected", "File is too large")
      refute has_element?(view, "#tods-import-preview")
      assert has_element?(view, "#apply-tods-import[disabled]")

      view |> render_click("apply_tods_import")
      assert Operations.list_garages(organization.id) == []
    end

    test "a reviewed preview is dropped when a later upload is rejected",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @garages_path)
      upload_fixture(view, @garage_file)
      assert has_element?(view, "#tods-import-preview")

      upload_content(view, "huge.txt", :binary.copy("a", Tods.max_import_bytes() + 1))

      assert has_element?(view, "#tods-file-upload-rejected", "File is too large")
      refute has_element?(view, "#tods-import-preview")

      assert has_element?(
               view,
               "#tods-import-apply-reason",
               "Choose a different file to review."
             )

      view |> render_click("apply_tods_import")
      assert Operations.list_garages(organization.id) == []
    end

    test "the skipped list is bounded at 100 rows and reports the remainder",
         %{conn: conn, user: user, organization: organization, version: version} do
      skipped_rows =
        Enum.map_join(1..101, "\n", fn n -> "stop_#{n},Stop #{n},45.5000,-122.6000," end)

      content = "stop_id,stop_name,stop_lat,stop_lon,TODS_location_type\n" <> skipped_rows

      view = open_import(conn, user, organization, version, @garages_path)
      upload_content(view, "lots.txt", content)

      assert has_element?(view, "#tods-import-count-skipped", "101")
      assert has_element?(view, "#tods-import-count-error", "0")
      assert count_items(view, "#tods-import-skipped") == 100
      assert has_element?(view, "#tods-import-skipped-more", "1 more")
      refute has_element?(view, "#tods-import-errors-more")

      assert has_element?(view, "#apply-tods-import[disabled]", "Import 0 garages")

      assert has_element?(
               view,
               "#tods-import-apply-reason",
               "Nothing to import: every row is skipped or unchanged."
             )
    end
  end

  describe "Fleet import" do
    setup :editor_setup

    test "importing the published vehicle file updates assigned vehicles and keeps their assignments",
         %{conn: conn, user: user, organization: organization, version: version} do
      stored_garage = garage_fixture(organization.id)
      stored_type = vehicle_type_fixture(organization.id)

      first =
        vehicle_fixture(organization.id, %{
          "vehicle_id" => "bus-1",
          "vehicle_label" => "Old label",
          "vehicle_type_id" => stored_type.id,
          "garage_id" => stored_garage.id
        })

      second = vehicle_fixture(organization.id, %{"vehicle_id" => "bus-2"})

      view = open_import(conn, user, organization, version, @fleet_path)
      upload_fixture(view, @vehicle_file)

      assert has_element?(view, "#tods-import-preview", "Review tods_example_vehicles.txt")
      assert has_element?(view, "#tods-import-count-update", "2")
      assert has_element?(view, "#tods-import-count-add", "0")
      assert has_element?(view, "#tods-import-count-error", "0")
      refute has_element?(view, "#tods-import-ignored")
      assert has_element?(view, "#apply-tods-import:not([disabled])", "Import 2 vehicles")

      view |> element("#apply-tods-import") |> render_click()

      assert has_element?(view, "#vehicle-notice", "Vehicles imported: 0 added, 2 updated.")
      assert has_element?(view, "#tods-import-drawer-overlay[data-open='false']")

      vehicles = Operations.list_vehicles(organization.id, %{})
      assert Enum.map(vehicles, & &1.vehicle_id) == ["bus-1", "bus-2"]

      refreshed = Enum.find(vehicles, &(&1.vehicle_id == "bus-1"))
      assert refreshed.id == first.id
      assert refreshed.vehicle_label == "Old Reliable"
      assert refreshed.license_plate == "OR-E285104"
      assert refreshed.vehicle_type_id == stored_type.id
      assert refreshed.garage_id == stored_garage.id

      assert Enum.find(vehicles, &(&1.vehicle_id == "bus-2")).id == second.id

      assert has_element?(view, "tr#vehicles-#{first.id} td[data-label='Label']", "Old Reliable")
    end

    test "importing into an empty fleet adds the vehicles and refreshes the list",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @fleet_path)
      upload_fixture(view, @vehicle_file)

      assert has_element?(view, "#tods-import-count-add", "2")
      assert has_element?(view, "#apply-tods-import:not([disabled])", "Import 2 vehicles")

      view |> element("#apply-tods-import") |> render_click()

      assert has_element?(view, "#vehicle-notice", "Vehicles imported: 2 added, 0 updated.")
      assert has_element?(view, "#vehicles-count", "2 of 2 vehicles")
      assert has_element?(view, "#vehicles-table", "bus-1")
      refute has_element?(view, "#vehicles-first-use-empty")

      # A new vehicle starts unassigned: import never invents a type or garage.
      vehicles = Operations.list_vehicles(organization.id, %{})
      assert Enum.all?(vehicles, &(is_nil(&1.vehicle_type_id) and is_nil(&1.garage_id)))
    end

    test "a structural fault shows the parser message and no preview",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @fleet_path)
      upload_content(view, "no-id.txt", "vehicle_label,license_plate\nOld Reliable,OR-E285104\n")

      assert has_element?(
               view,
               "#tods-import-error",
               "no-id.txt is missing the vehicle_id column."
             )

      refute has_element?(view, "#tods-import-preview")
      refute has_element?(view, "#tods-import-count-add")
      assert has_element?(view, "#apply-tods-import[disabled]")

      view |> render_click("apply_tods_import")
      assert Operations.list_vehicles(organization.id, %{}) == []
    end

    test "cancelling a rejected upload clears it and leaves nothing to apply",
         %{conn: conn, user: user, organization: organization, version: version} do
      view = open_import(conn, user, organization, version, @fleet_path)

      # A rejected entry stays in the upload config and carries its own cancel
      # control; clearing it must leave the drawer with nothing to apply.
      upload_content(view, "huge.txt", :binary.copy("a", Tods.max_import_bytes() + 1))
      assert has_element?(view, "#tods-file-upload-rejected", "File is too large")

      view |> element("#tods-file-upload-entries button") |> render_click()

      refute has_element?(view, "#tods-file-upload-rejected")
      refute has_element?(view, "#tods-import-preview")
      assert has_element?(view, "#apply-tods-import[disabled]")

      view |> render_click("apply_tods_import")
      assert Operations.list_vehicles(organization.id, %{}) == []
    end
  end

  describe "page shell" do
    setup :editor_setup

    test "both pages drop the interim import note and enable the import action",
         %{conn: conn, user: user, organization: organization, version: version} do
      conn = log_in_user(conn, user, organization: organization)

      {:ok, garages_view, _html} = live(conn, "/gtfs/#{version.id}#{@garages_path}")
      assert has_element?(garages_view, "#import-tods:not([disabled])")
      refute has_element?(garages_view, "#garages-actions-note")

      {:ok, fleet_view, _html} = live(conn, "/gtfs/#{version.id}#{@fleet_path}")
      assert has_element?(fleet_view, "#import-tods:not([disabled])")
      refute has_element?(fleet_view, "#fleet-actions-note")
    end

    test "each page reviews its own file kind",
         %{conn: conn, user: user, organization: organization, version: version} do
      garages_view = open_import(conn, user, organization, version, @garages_path)
      assert has_element?(garages_view, "#tods-import-drawer-title", "Import garages")

      assert has_element?(
               garages_view,
               "#tods-import-description",
               "Choose stops_supplement.txt from your operations system."
             )

      garages_view |> element("#tods-import-drawer-close") |> render_click()

      fleet_view = open_import(conn, user, organization, version, @fleet_path)
      assert has_element?(fleet_view, "#tods-import-drawer-title", "Import vehicles")

      assert has_element?(
               fleet_view,
               "#tods-import-description",
               "Choose vehicles.txt from your operations system."
             )

      upload_fixture(fleet_view, @garage_file)
      assert has_element?(fleet_view, "#tods-import-error", "missing the vehicle_id column.")
    end
  end
end

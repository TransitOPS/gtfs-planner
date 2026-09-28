defmodule GtfsPlannerWeb.Gtfs.FaresLiveZoneEditorTest do
  @moduledoc """
  Merge evidence (EV-18) for the zone create/edit drawer and the first-use state.

  Every case mounts the real route, reads the version's real data through the
  default `CatalogReadAdapter.Repo` adapter, and drives the drawer through the
  elements the page renders: the header's `Create zone`, the first-use state's
  `Create first zone`, the stage header's `Edit zone`, the form itself and its
  Cancel. The form's own rendered values are submitted wherever the exact stored
  bytes are the point, so a byte-exact ID is read from the DOM rather than
  reconstructed by the test.

  The fixture carries what the criteria name: a declared zone with a station
  member and a fare-rule reference, an implicit padded zone `" A"`, an implicit
  zone whose only stop leaves the inventory when another editor moves it, an
  empty declared zone, and the same zone IDs in the organization's other version
  and in another organization, so a write that is not scoped to one organization
  and one version is visible. One case mounts a version with no zone at all for
  the first-use state, and another mounts a version whose filter matches no stop
  to prove that a filtered-empty list is not first use.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @in_use_message "That zone ID is already in use. Choose another."
  @missing_message "This zone no longer exists. Another change removed it."
  @save_failed_message "Changes couldn’t be saved. Your edits are still here."

  # The version's inventory in the byte-for-byte ID order it sorts into, so every
  # case reads the row its zone renders as. The row index - never the zone ID -
  # identifies a row's elements (CR-7).
  @inventory [" A", "A", "B", "D", "Z"]

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    insert_zone(organization, version, "A", "Central", "ocean")
    insert_zone(organization, version, "B", "Eastbank", "teal")
    insert_zone(organization, version, "D", "Airport", "ochre")

    stops =
      insert_stops(organization, version, [
        boardable("CENTRAL_1", "Central 1", "A"),
        boardable("CENTRAL_2", "Central 2", "A"),
        boardable("SPACE_A_1", "Riverside", " A"),
        boardable("EAST_1", "East 1", "B"),
        boardable("ZONE_Z_1", "Zed 1", "Z"),
        # A station of the same zone: it is not boardable, so it never joins a
        # count or a list, but a rename moves its ID and an edit discloses it.
        %{stop_id: "CENTRAL_STATION", stop_name: "Central Union", zone_id: "A", location_type: 1}
      ])

    # One rule that references A and B, so an edit summary has a rule and a rename
    # has a fare-rule reference to move.
    insert_rule(organization, version, "CITY", "A", "B")

    # Twin scope: the same organization's other version and another organization
    # carry their own "A" record, and a stop of every one of them.
    other_version = gtfs_version_fixture(organization.id)
    insert_zone(organization, other_version, "A", "Central", "ocean")

    insert_stops(organization, other_version, [boardable("OTHER_VERSION_A", "Other version", "A")])

    other_organization = organization_fixture()
    other_org_version = gtfs_version_fixture(other_organization.id)
    insert_zone(other_organization, other_org_version, "A", "Central", "ocean")

    insert_stops(other_organization, other_org_version, [
      boardable("FOREIGN_A", "Foreign", "A")
    ])

    %{
      user: user,
      organization: organization,
      version: version,
      other_version: other_version,
      other_organization: other_organization,
      other_org_version: other_org_version,
      stops: Map.new(stops, &{&1.stop_id, &1.id})
    }
  end

  describe "first use" do
    setup %{organization: organization} do
      empty_version = gtfs_version_fixture(organization.id)

      insert_stops(organization, empty_version, [
        boardable("FIRST_1", "First stop", nil),
        boardable("FIRST_2", "Second stop", nil)
      ])

      %{empty_version: empty_version}
    end

    test "an inventory with no zone replaces the workspace and its action opens the drawer", %{
      conn: conn,
      user: user,
      organization: organization,
      empty_version: empty_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(empty_version))

      # The version has stops but no declared zone, no stop zone ID and no rule
      # reference, which is the only state that is first use.
      assert has_element?(view, "#fare-zone-first-use", "Start with your first fare zone")

      assert has_element?(
               view,
               "#fare-zone-first-use",
               "A zone groups stops that share a fare area. Give it a name, then select its stops on the map or in a list."
             )

      assert has_element?(
               view,
               "#fare-zone-first-use",
               "Already have a feed? Stop zone IDs from an imported feed appear here."
             )

      refute has_element?(view, "#fare-zones-panel")
      refute has_element?(view, "#fare-zone-inventory")

      # The header action is present too, so the page has one create path while
      # the workspace is replaced and one after it exists.
      assert has_element?(view, "#fare-zone-create", "Create zone")

      view |> element("#fare-zone-first-use-create") |> render_click()

      assert drawer_open?(view)
      assert text_of(view, "#fare-zone-drawer-title") == "Create a fare zone"
    end

    test "creating the first zone replaces the state with the workspace", %{
      conn: conn,
      user: user,
      organization: organization,
      empty_version: empty_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(empty_version))

      view |> element("#fare-zone-first-use-create") |> render_click()
      submit_zone(view, %{"name" => "Central", "zone_id" => "A", "color" => "ocean"})

      assert_patch(view, zones_path(empty_version) <> "?zone=A")
      render_patch(view, zones_path(empty_version) <> "?zone=A")

      refute has_element?(view, "#fare-zone-first-use")
      assert has_element?(view, "#fare-zones-panel")
      assert text_of(view, "#fare-zone-stage-title") == "Central"

      assert [zone] = FareZones.inventory(organization.id, empty_version.id).zones
      assert {zone.zone_id, zone.name, zone.declared?} == {"A", "Central", true}
    end
  end

  describe "the create form" do
    test "the header action opens it with the reference's fields, help and note", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version))

      assert has_element?(view, "dialog#fare-zone-drawer-overlay[data-open='false']")

      view |> element("#fare-zone-create") |> render_click()

      assert drawer_open?(view)
      assert text_of(view, "#fare-zone-drawer-title") == "Create a fare zone"

      assert text_of(view, "#fare-zone-drawer-intro") ==
               "Start with a name people recognize. You can assign stops next."

      assert has_element?(view, "#fare-zone-form", "Zone name")
      assert has_element?(view, "#fare-zone-form", "Zone ID")

      assert has_element?(
               view,
               "#fare-zone-form",
               "Unique in this version. Use letters, numbers, hyphens or underscores."
             )

      assert has_element?(view, "#fare-zone-form", "Map color")

      assert has_element?(
               view,
               "#fare-zone-form",
               "Markers also show the zone ID, so color is never the only cue."
             )

      # The palette's own labels are the options, keyed by the palette key.
      assert option_labels(view, "#fare-zone-color") == [
               "Ocean blue",
               "Teal",
               "Plum",
               "Ochre",
               "Green"
             ]

      assert selected_option(view, "#fare-zone-color") == "ochre"
      assert attribute(view, "#fare-zone-name", "value") == ""
      assert attribute(view, "#fare-zone-id", "value") == ""

      # A create states that the zone starts empty; the edit summary belongs to
      # an edit.
      assert has_element?(
               view,
               "#fare-zone-drawer-note",
               "Your new zone starts empty. It remains available while you build its stop membership."
             )

      refute has_element?(view, "#fare-zone-drawer-summary")

      # Cancel leaves the drawer closed and the next open starts from an empty
      # form again.
      view |> element("#fare-zone-drawer-close") |> render_click()

      refute drawer_open?(view)

      view |> element("#fare-zone-create") |> render_click()

      assert attribute(view, "#fare-zone-name", "value") == ""
      assert selected_option(view, "#fare-zone-color") == "ochre"
    end

    test "a new zone is trimmed, becomes the filter and reports what happened", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version))

      view |> element("#fare-zone-create") |> render_click()
      submit_zone(view, %{"name" => "Waterfront", "zone_id" => "  W  ", "color" => "teal"})

      # Only a newly entered ID is trimmed (CR-3): the padded value becomes W in
      # the URL and in the record.
      assert_patch(view, zones_path(version) <> "?zone=W")

      refute drawer_open?(view)
      assert text_of(view, "#fare-zone-notice") == zone_created_message()

      assert Enum.map(FareZones.inventory(organization.id, version.id).zones, & &1.zone_id) ==
               [" A", "A", "B", "D", "W", "Z"]

      assert inventory_entry(organization, version, "W")
             |> Map.take([:name, :color, :stop_count, :declared?]) == %{
               name: "Waterfront",
               color: "teal",
               stop_count: 0,
               declared?: true
             }

      # The workspace the save changed is read again: the new zone is the current
      # filter and the list below it is empty, and the notice survives the patch
      # because it belongs to the same tab.
      render_patch(view, zones_path(version) <> "?zone=W")

      assert text_of(view, "#fare-zone-stage-title") == "Waterfront"
      assert text_of(view, "#fare-zone-notice") == zone_created_message()

      assert has_element?(
               view,
               "#fare-zone-stops-empty",
               "No stops in this zone yet"
             )

      # Leaving the tab ends it.
      render_patch(view, zones_path(version, :rules))
      render_patch(view, zones_path(version))

      refute has_element?(view, "#fare-zone-notice")
    end

    test "a duplicate ID keeps the drawer, the typed values and the field error", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version))

      before = FareZones.inventory(organization.id, version.id)

      view |> element("#fare-zone-create") |> render_click()
      submit_zone(view, %{"name" => "Waterfront", "zone_id" => "A", "color" => "teal"})

      # The error is beside Zone ID, the drawer stays open, and nothing was
      # written (FH-22).
      assert drawer_open?(view)
      assert has_element?(view, "#fare-zone-id[aria-invalid='true']")
      assert has_element?(view, "#fare-zone-form", @in_use_message)
      assert attribute(view, "#fare-zone-name", "value") == "Waterfront"
      assert selected_option(view, "#fare-zone-color") == "teal"
      assert attribute(view, "#fare-zone-id", "value") == "A"

      # The hook takes focus to the invalid field, not to the submit button.
      assert_push_event(view, "focus_form_error", %{
        form_id: "fare-zone-form",
        fallback_id: "fare-zone-drawer-error"
      })

      assert FareZones.inventory(organization.id, version.id) == before
    end

    test "an invalid ID is rejected while validating on change and keeps the input", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version))

      view |> element("#fare-zone-create") |> render_click()

      view
      |> form("#fare-zone-form", %{
        "zone" => %{"name" => "Waterfront", "zone_id" => "A B", "color" => "teal"}
      })
      |> render_change()

      assert has_element?(view, "#fare-zone-id[aria-invalid='true']")

      assert has_element?(
               view,
               "#fare-zone-form",
               "Use 1–64 letters, numbers, hyphens or underscores."
             )

      assert attribute(view, "#fare-zone-name", "value") == "Waterfront"
      assert selected_option(view, "#fare-zone-color") == "teal"

      # Correcting the ID clears the error without submitting anything.
      view
      |> form("#fare-zone-form", %{
        "zone" => %{"name" => "Waterfront", "zone_id" => "W", "color" => "teal"}
      })
      |> render_change()

      refute has_element?(view, "#fare-zone-id[aria-invalid='true']")
      assert drawer_open?(view)

      assert Enum.map(FareZones.inventory(organization.id, version.id).zones, & &1.zone_id) ==
               @inventory
    end
  end

  describe "the edit form" do
    test "an implicit padded zone keeps its exact ID bytes through a name edit", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stops: stops
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version))

      # The filter's own link is what the case patches through, so the URL is the
      # one the panel produced.
      padded_href = row_href(view, "#fare-zone-row-1")

      render_patch(view, padded_href)

      # The padded ID is read without `text_of/2`'s whitespace collapsing, or the
      # leading space it is about would disappear.
      assert raw_text_of(view, "#fare-zone-stage-title") == " A"

      view |> element("#fare-zone-edit") |> render_click()

      assert drawer_open?(view)

      # The form's ID value is the stored bytes, leading space included, and the
      # summary counts the zone's boardable stop.
      assert attribute(view, "#fare-zone-id", "value") == " A"
      assert text_of(view, "#fare-zone-drawer-summary > p") == "1 stop · 0 related fare rules."
      refute has_element?(view, "#fare-zone-drawer-summary-others")

      # Submitting the form's own values sends the padded ID back untouched: a
      # name-only edit is not a change of ID at all (AC-13).
      view
      |> form("#fare-zone-form", %{"zone" => %{"name" => "Riverside"}})
      |> render_submit()

      refute drawer_open?(view)
      assert text_of(view, "#fare-zone-notice") == "Zone updated."

      # A record now exists under exactly " A", "A" is its own untouched zone, and
      # the stop still carries the padded ID.
      assert Enum.map(FareZones.inventory(organization.id, version.id).zones, & &1.zone_id) ==
               @inventory

      padded = inventory_entry(organization, version, " A")

      assert padded.declared?
      assert padded.name == "Riverside"
      assert zone_id_of(stops["SPACE_A_1"]) == " A"

      assert inventory_entry(organization, version, "A").name == "Central"

      # The filter did not move: the same zone is still selected and now shows the
      # name that was just stored.
      assert text_of(view, "#fare-zone-stage-title") == "Riverside"
      assert has_element?(view, "#fare-zone-row-1[aria-current='page']")
    end

    test "a rename moves the ID, its stops of every type and its rule references", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stops: stops
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version) <> "?zone=A")

      view |> element("#fare-zone-edit") |> render_click()

      # The edit names what the zone carries and what changing its ID rewrites,
      # including the station that is not part of the boardable count.
      assert text_of(view, "#fare-zone-drawer-title") == "Edit Central"
      assert attribute(view, "#fare-zone-id", "value") == "A"
      assert text_of(view, "#fare-zone-drawer-summary > p") == "2 stops · 1 related fare rule."

      assert text_of(view, "#fare-zone-drawer-summary-updates") ==
               "Changing this ID updates these references together."

      assert text_of(view, "#fare-zone-drawer-summary-others") ==
               "Also updates 1 station or entrance with this zone ID."

      submit_zone(view, %{"name" => "Central", "zone_id" => "AA", "color" => "ocean"})

      assert_patch(view, zones_path(version) <> "?zone=AA")

      refute drawer_open?(view)
      assert text_of(view, "#fare-zone-notice") == "Zone updated."

      assert Enum.map(FareZones.inventory(organization.id, version.id).zones, & &1.zone_id) ==
               [" A", "AA", "B", "D", "Z"]

      # The whole zone moved: both boardable stops, the station and the fare-rule
      # reference (CR-5, AC-14).
      assert zone_id_of(stops["CENTRAL_1"]) == "AA"
      assert zone_id_of(stops["CENTRAL_2"]) == "AA"
      assert zone_id_of(stops["CENTRAL_STATION"]) == "AA"

      assert Enum.map(FareZones.list_rule_groups(organization.id, version.id), & &1.origin_id) ==
               ["AA"]

      render_patch(view, zones_path(version) <> "?zone=AA")

      assert text_of(view, "#fare-zone-stage-title") == "Central"
      assert text_of(view, "#fare-zone-stage-subtitle") == "2 stops · Zone ID AA"
    end

    test "a zone with no station member omits the station line", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version) <> "?zone=B")

      view |> element("#fare-zone-edit") |> render_click()

      assert text_of(view, "#fare-zone-drawer-title") == "Edit Eastbank"
      assert text_of(view, "#fare-zone-drawer-summary > p") == "1 stop · 1 related fare rule."

      assert text_of(view, "#fare-zone-drawer-summary-updates") ==
               "Changing this ID updates these references together."

      refute has_element?(view, "#fare-zone-drawer-summary-others")
    end

    test "a zone another change removed keeps the drawer with the removal stated", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stops: stops
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version) <> "?zone=Z")

      view |> element("#fare-zone-edit") |> render_click()

      assert attribute(view, "#fare-zone-id", "value") == "Z"

      # Another editor moves the implicit zone's only stop away, so the ID leaves
      # the inventory between opening the drawer and saving.
      {1, nil} =
        Repo.update_all(from(s in Stop, where: s.id == ^stops["ZONE_Z_1"]),
          set: [zone_id: nil]
        )

      submit_zone(view, %{"name" => "Zed", "zone_id" => "Z", "color" => "ocean"})

      assert drawer_open?(view)
      assert text_of(view, "#fare-zone-drawer-error") == @missing_message
      assert attribute(view, "#fare-zone-name", "value") == "Zed"

      # Nothing was written, and no record was recreated for the removed ID.
      assert Repo.get!(Stop, stops["ZONE_Z_1"]).zone_id == nil

      assert Enum.map(FareZones.inventory(organization.id, version.id).zones, & &1.zone_id) ==
               [" A", "A", "B", "D"]

      assert Repo.aggregate(
               from(z in FareZone, where: z.zone_id == "Z" and z.gtfs_version_id == ^version.id),
               :count
             ) == 0
    end

    test "a version that is no longer published reports the save failure", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version) <> "?zone=A")

      view |> element("#fare-zone-edit") |> render_click()

      {1, nil} =
        Repo.update_all(from(v in GtfsVersion, where: v.id == ^version.id),
          set: [publication_status: "failed"]
        )

      submit_zone(view, %{"name" => "Central West", "zone_id" => "A", "color" => "ocean"})

      # The zone is still in the inventory, so the reason is the write's scope and
      # not a removal.
      assert drawer_open?(view)
      assert text_of(view, "#fare-zone-drawer-error") == @save_failed_message
      assert attribute(view, "#fare-zone-name", "value") == "Central West"

      assert Repo.aggregate(
               from(z in FareZone,
                 where:
                   z.zone_id == "A" and z.gtfs_version_id == ^version.id and z.name == "Central"
               ),
               :count
             ) == 1
    end

    test "a metadata edit writes only this organization's and version's zone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      other_version: other_version,
      other_organization: other_organization,
      other_org_version: other_org_version,
      stops: stops
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version) <> "?zone=A")

      view |> element("#fare-zone-edit") |> render_click()
      submit_zone(view, %{"name" => "Central", "zone_id" => "AA", "color" => "plum"})

      assert_patch(view, zones_path(version) <> "?zone=AA")

      # The twin rows are byte-identical to what they held: their zone ID, name,
      # color and stop membership are untouched (INV-1).
      for {org, ver} <- [
            {organization, other_version},
            {other_organization, other_org_version}
          ] do
        assert Enum.map(FareZones.inventory(org.id, ver.id).zones, & &1.zone_id) == ["A"]

        assert inventory_entry(org, ver, "A") |> Map.take([:name, :color, :declared?]) == %{
                 name: "Central",
                 color: "ocean",
                 declared?: true
               }
      end

      assert Repo.aggregate(
               from(s in Stop,
                 where: s.gtfs_version_id == ^other_version.id and s.zone_id == "A"
               ),
               :count
             ) == 1

      assert Repo.aggregate(
               from(s in Stop,
                 where: s.organization_id == ^other_organization.id and s.zone_id == "A"
               ),
               :count
             ) == 1

      assert Repo.get!(Stop, stops["CENTRAL_1"]).zone_id == "AA"
    end
  end

  describe "first use is not a filtered empty list" do
    test "an empty zone filter keeps the workspace and states the filter's own emptiness", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zones_path(version) <> "?zone=D")

      # The version does have zones; D is simply empty, so this is not first use.
      assert has_element?(view, "#fare-zones-panel")
      refute has_element?(view, "#fare-zone-first-use")
      assert has_element?(view, "#fare-zone-stops-empty", "No stops in this zone yet")
      assert text_of(view, "#fare-zone-stage-subtitle") == "0 stops · Zone ID D"
    end
  end

  defp zones_path(version, action \\ :zones) do
    case action do
      :rules -> "/gtfs/#{version.id}/settings/fares/rules"
      :checks -> "/gtfs/#{version.id}/settings/fares/checks"
      :zones -> "/gtfs/#{version.id}/settings/fares"
    end
  end

  defp zone_created_message, do: "Zone created. Select stops from All stops to get started."

  # The drawer form is submitted through its own rendered values, so a field the
  # case does not name is the value the operator would have seen.
  defp submit_zone(view, params) do
    view |> form("#fare-zone-form", %{"zone" => params}) |> render_submit()
  end

  defp drawer_open?(view), do: attribute(view, "#fare-zone-drawer-overlay", "data-open") == "true"

  defp zone_id_of(stop_id), do: Repo.get!(Stop, stop_id).zone_id

  defp inventory_entry(organization, version, zone_id) do
    Enum.find(FareZones.inventory(organization.id, version.id).zones, &(&1.zone_id == zone_id))
  end

  defp option_labels(view, selector) do
    view |> nodes("#{selector} option") |> Enum.map(&LazyHTML.text/1)
  end

  defp selected_option(view, selector) do
    view
    |> nodes("#{selector} option[selected]")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  # The rendered href of one row: the panel owns the encoding, so the cases read
  # the link it produced instead of rebuilding it.
  defp row_href(view, selector) do
    view |> nodes(selector) |> LazyHTML.attribute("href") |> List.first()
  end

  defp attribute(view, selector, name) do
    view |> nodes(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp text_of(view, selector) do
    value =
      view
      |> nodes(selector)
      |> Enum.map_join(" ", &LazyHTML.text/1)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if value == "", do: nil, else: value
  end

  # The untrimmed text of one node. A byte-exact expectation (the leading space of
  # a padded zone ID) has to read the node without the normalization `text_of/2`
  # applies, or it can never match what was rendered.
  defp raw_text_of(view, selector) do
    view |> nodes(selector) |> Enum.map_join("", &LazyHTML.text/1)
  end

  defp nodes(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn stop ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop.stop_id,
          stop_name: stop.stop_name,
          location_type: Map.get(stop, :location_type, 0),
          zone_id: Map.get(stop, :zone_id),
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
    rows
  end

  defp insert_zone(organization, version, zone_id, name, color) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareZone, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          zone_id: zone_id,
          name: name,
          color: color,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_rule(organization, version, fare_id, origin_id, destination_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareRule, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare_id,
          origin_id: origin_id,
          destination_id: destination_id,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp boardable(stop_id, stop_name, zone_id),
    do: %{stop_id: stop_id, stop_name: stop_name, zone_id: zone_id}
end

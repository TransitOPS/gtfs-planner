defmodule GtfsPlannerWeb.Gtfs.FaresLiveZoneDeleteTest do
  @moduledoc """
  Merge evidence (EV-19) for the delete-zone dialog.

  Every case mounts the real route and reads the version's real data through the
  default `CatalogReadAdapter.Repo` adapter, opens the dialog the way an
  operator does - the inventory row's filter, the stage header's `Edit zone`,
  then `Delete zone…` - and confirms through the dialog's own button. The copy
  and the counts the dialog shows therefore come from
  `FareZones.inventory/2`, and every write is `FareZones.delete_zone/5`.

  The fixture carries what AC-16, AC-26 and AC-27 name: a declared zone three
  fare-rule groups use and a station carries (so the replacement path, the
  station disclosure and the rule rewrite are all reachable), an unreferenced
  zone an operator can move to Unassigned, an empty declared zone, an implicit
  zone whose ID is the padded `" A"` (so the byte-exact ID travels into the
  select and the dialog's own title without being trimmed), and a second version
  whose only zone fare rules use (so the disabled confirm and its reason are
  reachable). Three cases make another editor's change visible between opening
  the dialog and confirming - a stop that moved, a replacement that left the
  inventory and the zone itself being removed - and each asserts that nothing
  was written.
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

  @save_failed_message "Changes couldn’t be saved. Your edits are still here."
  @deleted_message "Zone deleted."
  @missing_message "This zone no longer exists."

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
        # A station of the same zone: it is not boardable, so it never joins a
        # count or a list, but a deletion moves its ID with the others (CR-5).
        %{stop_id: "CENTRAL_STATION", stop_name: "Central Union", zone_id: "A", location_type: 1},
        boardable("EAST_1", "East 1", "B"),
        boardable("EAST_2", "East 2", "B"),
        # An implicit zone of its own, carried only by this stop: no record, so
        # its dialog offers Unassigned.
        boardable("SOLO_1", "Solo 1", "E"),
        # An imported ID with a leading space, kept byte-for-byte.
        boardable("SPACE_A_1", "Riverside", " A"),
        boardable("NO_ZONE_1", "Bayline", nil)
      ])

    # Three rule groups reference A: CITY's A → B, CITY's "through A" and CROSS's
    # "through A + B". CROSS already carries a "through B" row, so rewriting its
    # A row to B produces a duplicate the domain drops instead of a second row.
    insert_rule(organization, version, "CITY", "A", "B")
    insert_rule(organization, version, "CITY", nil, nil, "A")
    insert_rule(organization, version, "CROSS", nil, nil, "A")
    insert_rule(organization, version, "CROSS", nil, nil, "B")

    # A version whose only zone fare rules use: there is no replacement, so the
    # confirm cannot be enabled.
    single_version = gtfs_version_fixture(organization.id)
    insert_zone(organization, single_version, "S", "Solo", "plum")
    insert_stops(organization, single_version, [boardable("S_1", "Solo stop", "S")])
    insert_rule(organization, single_version, "ONLY", nil, nil, "S")

    # Twin scope: the same organization's other version and another organization
    # carry their own "A" record and stop, so a write that is not scoped to one
    # organization and one version is visible.
    other_version = gtfs_version_fixture(organization.id)
    insert_zone(organization, other_version, "A", "Central", "ocean")
    insert_stops(organization, other_version, [boardable("OTHER_A", "Other version A", "A")])

    other_organization = organization_fixture()
    other_org_version = gtfs_version_fixture(other_organization.id)
    insert_zone(other_organization, other_org_version, "A", "Central", "ocean")

    insert_stops(other_organization, other_org_version, [
      boardable("FOREIGN_A", "Foreign A", "A")
    ])

    %{
      user: user,
      organization: organization,
      version: version,
      single_version: single_version,
      other_version: other_version,
      other_organization: other_organization,
      other_org_version: other_org_version,
      stop_ids: Map.new(stops, &{&1.stop_id, &1.id})
    }
  end

  describe "a zone fare rules use" do
    test "the drawer's destructive exit opens the dialog with the reference's copy and options",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, "A"))

      refute has_element?(view, "#fare-zone-delete-dialog")

      view |> element("#fare-zone-edit") |> render_click()

      assert drawer_open?(view)
      assert has_element?(view, "#fare-zone-delete", "Delete zone…")

      view |> element("#fare-zone-delete") |> render_click()

      # The confirm replaces the drawer: both are dialogs, and leaving the edit
      # drawer open behind a modal confirm would hide the change it describes.
      assert dialog_open?(view)
      refute drawer_open?(view)

      assert attribute(view, "#fare-zone-delete-dialog", "data-return-focus-id") ==
               "fare-zone-edit"

      assert text_of(view, "#fare-zone-delete-dialog-title") == "Delete Central?"

      assert text_of(view, "#fare-zone-delete-consequence") ==
               "2 stops and 3 fare rules use this zone."

      assert text_of(view, "#fare-zone-delete-others") ==
               "Also moves 1 station or entrance with this zone ID."

      # A zone fare rules use can only move to another inventory zone, so
      # Unassigned is not offered and the label names the references.
      assert has_element?(view, "#fare-zone-delete-replacement-form", "Replace references with")

      assert option_values(view, "#fare-zone-delete-replacement") == [" A", "B", "D", "E"]

      assert text_of(view, "#fare-zone-delete-warning") ==
               "Stops and fare rules will move together. This changes which journeys the related fares cover."

      assert text_of(view, "#fare-zone-delete-dialog-confirm") == "Replace & delete"
      assert text_of(view, "#fare-zone-delete-dialog-cancel") == "Keep zone"
      refute confirm_disabled?(view)
      refute has_element?(view, "#fare-zone-delete-reason")
      refute has_element?(view, "#fare-zone-delete-empty")

      # Keeping the zone closes the dialog and writes nothing.
      view |> element("#fare-zone-delete-dialog-cancel") |> render_click()

      refute has_element?(view, "#fare-zone-delete-dialog")
      assert zone_id_of(stop_ids(version), "CENTRAL_1") == "A"
      assert inventory_entry(organization, version, "A").stop_count == 2
    end

    test "the confirm moves stops of every location type and rewrites the rule references", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      other_version: other_version,
      other_organization: other_organization,
      other_org_version: other_org_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, "A"))

      open_delete_dialog(view)
      choose_replacement(view, "B")

      assert selected_replacement(view) == "B"

      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      # Success reports from All stops, the base path the reference announces
      # from, and the dialog is done.
      assert_patch(view, zones_path(version))
      render_patch(view, zones_path(version))

      refute has_element?(view, "#fare-zone-delete-dialog")
      assert text_of(view, "#fare-zone-notice") == @deleted_message
      assert text_of(view, "#fare-zone-stage-title") == "All stops"

      # Every location type moved to the exact replacement ID.
      ids = stop_ids(version)

      assert zone_id_of(ids, "CENTRAL_1") == "B"
      assert zone_id_of(ids, "CENTRAL_2") == "B"
      assert zone_id_of(ids, "CENTRAL_STATION") == "B"

      # No row references the deleted ID, the CROSS "through B" group kept
      # exactly one row, and the metadata record is gone.
      assert rule_rows_referencing(version, "A") == []
      assert length(rule_rows_for_contains(version, "CROSS", "B")) == 1
      assert inventory_entry(organization, version, "A") == nil

      # The zones the deletion did not name kept their bytes.
      assert zone_id_of(ids, "SPACE_A_1") == " A"
      assert zone_id_of(ids, "SOLO_1") == "E"
      assert zone_id_of(ids, "EAST_1") == "B"
      assert inventory_entry(organization, version, "D").stop_count == 0

      # The twin scope is untouched: the other version's and the other
      # organization's own "A" records and stop memberships are byte-identical.
      assert inventory_entry(organization, other_version, "A").stop_count == 1

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

      assert inventory_entry(other_organization, other_org_version, "A").name == "Central"
    end
  end

  describe "a zone fare rules do not use" do
    test "offers Unassigned and unassigns its stops", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, "E"))

      open_delete_dialog(view)

      assert text_of(view, "#fare-zone-delete-dialog-title") == "Delete E?"
      # A count of one reads as one.
      assert text_of(view, "#fare-zone-delete-consequence") ==
               "1 stop and 0 fare rules use this zone."

      assert has_element?(view, "#fare-zone-delete-replacement-form", "Move its stops to")
      assert option_values(view, "#fare-zone-delete-replacement") == ["", " A", "A", "B", "D"]

      assert option_labels(view, "#fare-zone-delete-replacement") == [
               "Unassigned",
               " A ·  A",
               "Central · A",
               "Eastbank · B",
               "Airport · D"
             ]

      assert selected_replacement(view) == ""

      assert text_of(view, "#fare-zone-delete-warning") ==
               "Stops are kept. Only their zone assignment changes."

      assert text_of(view, "#fare-zone-delete-dialog-confirm") == "Replace & delete"

      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      assert_patch(view, zones_path(version))
      render_patch(view, zones_path(version))

      assert text_of(view, "#fare-zone-notice") == @deleted_message
      assert zone_id_of(stop_ids(version), "SOLO_1") == nil
      assert inventory_entry(organization, version, "E") == nil

      # Only the named zone's stop moved.
      assert zone_id_of(stop_ids(version), "CENTRAL_1") == "A"
      assert zone_id_of(stop_ids(version), "EAST_1") == "B"
    end

    test "an empty zone deletes without touching stops or fares", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, "D"))

      open_delete_dialog(view)

      assert text_of(view, "#fare-zone-delete-dialog-title") == "Delete Airport?"

      assert text_of(view, "#fare-zone-delete-consequence") ==
               "0 stops and 0 fare rules use this zone."

      assert text_of(view, "#fare-zone-delete-empty") ==
               "This empty zone has no references. Deleting it will not change stops or fares."

      refute has_element?(view, "#fare-zone-delete-replacement-form")
      refute has_element?(view, "#fare-zone-delete-warning")
      refute has_element?(view, "#fare-zone-delete-others")
      assert text_of(view, "#fare-zone-delete-dialog-confirm") == "Delete empty zone"
      refute confirm_disabled?(view)

      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      assert_patch(view, zones_path(version))
      render_patch(view, zones_path(version))

      assert text_of(view, "#fare-zone-notice") == @deleted_message
      assert inventory_entry(organization, version, "D") == nil
      assert zone_id_of(stop_ids(version), "CENTRAL_1") == "A"
      assert rule_rows_referencing(version, "A") != []
    end
  end

  describe "a zone with no replacement" do
    test "the confirm is disabled and says why", %{
      conn: conn,
      user: user,
      organization: organization,
      single_version: single_version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(single_version, "S"))

      open_delete_dialog(view)

      assert text_of(view, "#fare-zone-delete-dialog-title") == "Delete Solo?"

      assert text_of(view, "#fare-zone-delete-consequence") ==
               "1 stop and 1 fare rule use this zone."

      assert option_values(view, "#fare-zone-delete-replacement") == []
      assert confirm_disabled?(view)

      assert text_of(view, "#fare-zone-delete-reason") ==
               "Create another zone first. Fare rules need a replacement zone."

      # The reason is the only thing that changed: nothing was written.
      assert inventory_entry(organization, single_version, "S").rule_count == 1
    end
  end

  describe "a zone a second editor changed" do
    test "a stop assigned since the dialog opened is refused, then the new counts fence the next confirm",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version,
           stop_ids: stop_ids
         } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, "A"))

      open_delete_dialog(view)
      choose_replacement(view, "B")

      # Another editor moves a stop into the zone while the dialog is open, so
      # the zone has one more stop than the dialog showed.
      {1, nil} =
        Repo.update_all(from(s in Stop, where: s.id == ^stop_ids["EAST_1"]), set: [zone_id: "A"])

      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      # The fence refuses the whole write: the dialog stays open with the
      # operator's replacement, states the counts the zone now has, and the
      # dialog's own fence is those counts.
      assert dialog_open?(view)

      assert text_of(view, "#fare-zone-delete-stale") ==
               "This zone changed since you opened this dialog. It now has 3 stops and 3 fare rules."

      assert text_of(view, "#fare-zone-delete-consequence") ==
               "3 stops and 3 fare rules use this zone."

      assert selected_replacement(view) == "B"
      refute confirm_disabled?(view)

      # Nothing was written: the moved stop is where the other editor put it and
      # the zone, its stops and its rule references are all still there.
      assert zone_id_of(stop_ids, "EAST_1") == "A"
      assert zone_id_of(stop_ids, "CENTRAL_1") == "A"
      assert zone_id_of(stop_ids, "CENTRAL_STATION") == "A"
      assert rule_rows_referencing(version, "A") != []
      assert inventory_entry(organization, version, "A") != nil

      # Confirming again deletes against the counts that were just read.
      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      assert_patch(view, zones_path(version))
      render_patch(view, zones_path(version))

      assert text_of(view, "#fare-zone-notice") == @deleted_message
      assert zone_id_of(stop_ids, "EAST_1") == "B"
      assert zone_id_of(stop_ids, "CENTRAL_1") == "B"
      assert rule_rows_referencing(version, "A") == []
      assert inventory_entry(organization, version, "A") == nil
    end

    test "a replacement that left the inventory is refused and the select re-reads", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, "A"))

      open_delete_dialog(view)
      choose_replacement(view, "E")

      # The implicit zone E is carried only by its stop, so unassigning that stop
      # takes E out of the inventory while the dialog is open.
      {1, nil} =
        Repo.update_all(from(s in Stop, where: s.id == ^stop_ids["SOLO_1"]), set: [zone_id: nil])

      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      assert dialog_open?(view)
      assert text_of(view, "#fare-zone-delete-error") == @save_failed_message

      # The select was re-read: E is gone and the dialog fell back to the first
      # replacement that exists.
      assert option_values(view, "#fare-zone-delete-replacement") == [" A", "B", "D"]
      assert selected_replacement(view) == " A"

      # Nothing was written.
      assert zone_id_of(stop_ids, "CENTRAL_1") == "A"
      assert zone_id_of(stop_ids, "SOLO_1") == nil
      assert rule_rows_referencing(version, "A") != []
    end

    test "a zone that left the inventory closes the dialog with what happened", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, "A"))

      open_delete_dialog(view)

      # Another editor removes the zone entirely: its stops of every location
      # type, its rule references and its record.
      {3, nil} =
        Repo.update_all(
          from(s in Stop, where: s.gtfs_version_id == ^version.id and s.zone_id == "A"),
          set: [zone_id: nil]
        )

      {3, nil} =
        Repo.delete_all(
          from(r in FareRule,
            where:
              r.gtfs_version_id == ^version.id and
                (r.origin_id == "A" or r.destination_id == "A" or r.contains_id == "A")
          )
        )

      {1, nil} =
        Repo.delete_all(
          from(z in FareZone, where: z.gtfs_version_id == ^version.id and z.zone_id == "A")
        )

      view |> element("#fare-zone-delete-dialog-confirm") |> render_click()

      refute has_element?(view, "#fare-zone-delete-dialog")
      assert text_of(view, "#fare-zone-notice") == @missing_message
      # The filter no longer names a zone the inventory carries, so the
      # workspace has read itself again at All stops.
      assert text_of(view, "#fare-zone-stage-title") == "All stops"

      # Only the removal that already happened took effect.
      assert zone_id_of(stop_ids, "CENTRAL_1") == nil
      assert zone_id_of(stop_ids, "SPACE_A_1") == " A"
      assert zone_id_of(stop_ids, "EAST_1") == "B"
      assert inventory_entry(organization, version, "B").stop_count == 2
    end
  end

  describe "byte-exact IDs" do
    test "the dialog carries the stored bytes and never puts a zone ID in a DOM ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, zone_url(version, " A"))

      open_delete_dialog(view)

      assert raw_text_of(view, "#fare-zone-stage-title") == " A"
      # The implicit padded zone's own name is its ID, so the title keeps the
      # byte, unnormalized. This reads the node raw: a whitespace-collapsing
      # reader could never see the difference.
      assert raw_text_of(view, "#fare-zone-delete-dialog-title") == "Delete  A?"

      assert raw_text_of(view, "#fare-zone-delete-consequence") ==
               "1 stop and 0 fare rules use this zone."

      assert option_labels(view, "#fare-zone-delete-replacement") == [
               "Unassigned",
               "Central · A",
               "Eastbank · B",
               "Airport · D",
               "E · E"
             ]

      # No DOM ID anywhere on the page derives from a zone ID (CR-7), including
      # the padded one the dialog is about.
      ids = rendered_ids(view)
      assert "fare-zone-delete-dialog-confirm" in ids
      refute Enum.any?(ids, &String.contains?(&1, " A"))

      assert zone_id_of(stop_ids(version), "SPACE_A_1") == " A"
      assert inventory_entry(organization, version, " A").declared? == false
    end
  end

  defp zones_path(version) do
    "/gtfs/#{version.id}/settings/fares"
  end

  # A zone filter is a URL state, so the padded ID travels encoded exactly as
  # the panel's own link builds it.
  defp zone_url(version, zone_id) do
    zones_path(version) <> "?" <> URI.encode_query(zone: zone_id)
  end

  defp open_delete_dialog(view) do
    view |> element("#fare-zone-edit") |> render_click()
    view |> element("#fare-zone-delete") |> render_click()
    assert dialog_open?(view)
  end

  defp choose_replacement(view, zone_id) do
    view
    |> form("#fare-zone-delete-replacement-form", %{"replacement" => zone_id})
    |> render_change()
  end

  defp dialog_open?(view),
    do: attribute(view, "#fare-zone-delete-dialog", "data-open") == "true"

  defp drawer_open?(view), do: attribute(view, "#fare-zone-drawer-overlay", "data-open") == "true"

  defp confirm_disabled?(view) do
    view
    |> nodes("#fare-zone-delete-dialog-confirm")
    |> LazyHTML.attribute("disabled")
    |> Enum.any?()
  end

  defp option_values(view, selector) do
    view |> nodes("#{selector} option") |> LazyHTML.attribute("value")
  end

  defp option_labels(view, selector) do
    view |> nodes("#{selector} option") |> Enum.map(&LazyHTML.text/1)
  end

  defp selected_replacement(view) do
    view
    |> nodes("#fare-zone-delete-replacement option[selected]")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp rendered_ids(view) do
    ~r/(?:^|\s)id="([^"]*)"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> List.flatten()
  end

  defp zone_id_of(stop_ids, stop_id), do: Repo.get!(Stop, stop_ids[stop_id]).zone_id

  defp inventory_entry(organization, version, zone_id) do
    Enum.find(FareZones.inventory(organization.id, version.id).zones, &(&1.zone_id == zone_id))
  end

  # The version's fare-rule rows that mention a zone in any of the three
  # reference columns, as `{origin_id, destination_id, contains_id}`.
  defp rule_rows_referencing(version, zone_id) do
    from(r in FareRule,
      where:
        r.gtfs_version_id == ^version.id and
          (r.origin_id == ^zone_id or r.destination_id == ^zone_id or r.contains_id == ^zone_id),
      select: {r.origin_id, r.destination_id, r.contains_id}
    )
    |> Repo.all()
  end

  defp rule_rows_for_contains(version, fare_id, contains_id) do
    from(r in FareRule,
      where:
        r.gtfs_version_id == ^version.id and r.fare_id == ^fare_id and
          r.contains_id == ^contains_id,
      select: r.contains_id
    )
    |> Repo.all()
  end

  defp stop_ids(version) do
    from(s in Stop, where: s.gtfs_version_id == ^version.id, select: {s.stop_id, s.id})
    |> Repo.all()
    |> Map.new()
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

  # The untrimmed text of one node. A byte-exact expectation (the padded zone ID
  # in the dialog's title) has to read the node without the normalization
  # `text_of/2` applies, or it can never match what was rendered.
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

  defp insert_rule(organization, version, fare_id, origin_id, destination_id, contains_id \\ nil) do
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
          contains_id: contains_id,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp boardable(stop_id, stop_name, zone_id),
    do: %{stop_id: stop_id, stop_name: stop_name, zone_id: zone_id}
end

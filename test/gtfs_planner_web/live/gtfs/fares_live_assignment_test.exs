defmodule GtfsPlannerWeb.Gtfs.FaresLiveAssignmentTest do
  @moduledoc """
  Merge evidence (EV-17) for the Zones tab's assignment review, save and Undo.

  Every case mounts the real route and reads the version's real data through the
  default `CatalogReadAdapter.Repo` adapter, then drives the flow through the
  elements the page renders: a row's checkbox, the bar's `Assign zone` and
  `Unassign`, the dialog's target select, `Refresh review`, `Keep selection`, the
  confirm button and Undo. The counts and rows the dialog shows therefore come
  from `FareZones.preview_assignment/4`, and every zone written comes from
  `FareZones.apply_assignment/2` or `undo_assignment/2`.

  Three of the cases make another editor's change visible between the review and
  the save — a stop's zone, the target zone's deletion and the version's
  publication status — because that is the fence the dialog has to survive, and
  each one asserts both the message the operator sees and that nothing was
  written. The fixture pages 150 stops in one zone so the review's own 100-row
  limit and its "and N more" line are observable, and carries a station, its two
  platforms, a stop in a padded implicit zone and a twin organization and version
  so boardable-only membership, byte-exact IDs and the scope filters are visible
  from the rendered output.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @east_count 150

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

    # 150 boardable stops in one zone: one page holds 100 of them, so the review's
    # 100-row limit is reachable through the page's own "select all matching".
    east =
      for index <- 1..@east_count do
        located_stop("RIVERSIDE_#{pad(index)}", "Riverside #{pad(index)}", "B")
      end

    others = [
      located_stop("WEST_1", "Central West 1", "A"),
      located_stop("WEST_2", "Central West 2", "A"),
      located_stop("BAY_1", "Bayline 1", nil),
      located_stop("BAY_2", "Bayline 2", nil),
      # A station is not boardable: it never renders as an assignable row and its
      # UUID is never a valid selection.
      located_stop("CENTRAL_STATION", "Central Union Station", "A")
      |> Map.put(:location_type, 1),
      located_stop("PLATFORM_1", "Central Union Platform 1", "A")
      |> Map.put(:parent_station, "CENTRAL_STATION")
      |> Map.put(:platform_code, "1"),
      located_stop("PLATFORM_2", "Central Union Platform 2", "A")
      |> Map.put(:parent_station, "CENTRAL_STATION")
      |> Map.put(:platform_code, "2")
    ]

    rows = insert_stops(organization, version, east ++ others)

    # The same organization's other version carries a stop with a real UUID, and
    # another organization carries a stop of its own: neither may be selected,
    # reviewed or written.
    other_version = gtfs_version_fixture(organization.id)

    [other_version_stop] =
      insert_stops(organization, other_version, [
        located_stop("WEST_1", "Other Version West", "A")
      ])

    other_organization = organization_fixture()
    other_org_version = gtfs_version_fixture(other_organization.id)

    [foreign_stop] =
      insert_stops(other_organization, other_org_version, [
        located_stop("FOREIGN", "Other Tenant Stop", "A")
      ])

    %{
      user: user,
      organization: organization,
      version: version,
      other_version: other_version,
      other_version_stop: other_version_stop,
      foreign_stop: foreign_stop,
      stop_ids: Map.new(rows, &{&1.stop_id, &1.id})
    }
  end

  describe "the review" do
    test "the bar opens an assign review whose target is the current filter's zone", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=B")

      refute has_element?(view, "#fare-zone-assignment-dialog")

      # Assign zone needs a selection, so the bar's two actions appear only once
      # one exists.
      select_stop(view, stop_ids["RIVERSIDE_001"])
      refute has_element?(view, "#fare-zone-assignment-dialog")

      view |> element("#fare-zone-assign-selection") |> render_click()

      assert dialog_open?(view)
      assert has_element?(view, "#fare-zone-assignment-dialog-title", "Assign 1 stop to a zone")

      assert text_of(view, "#fare-zone-assignment-intro") ==
               "Review what will change before you save."

      # The target defaults to the zone the operator is filtering by, and its ID
      # travels in the select's option value byte-for-byte.
      assert selected_target(view) == "B"
      assert target_options(view) == [{"Central · A", "A"}, {"Eastbank · B", "B"}]

      # The selected stop is already in B, so the review changes nothing and says
      # so instead of leaving its confirm button unexplained.
      assert tile(view, "added") == "0 Newly assigned"
      assert tile(view, "unchanged") == "1 Already in this zone"
      refute has_element?(view, "#fare-zone-assignment-moved")
      assert confirm_disabled?(view)

      assert text_of(view, "#fare-zone-assignment-reason") ==
               "Nothing to change: every selected stop already has this zone."

      # Changing the target re-reviews: the reviewed row shows the zone it has and
      # the zone it would get, and the moved-stop warning appears with it.
      choose_target(view, "A")

      assert selected_target(view) == "A"
      assert tile(view, "added") == "0 Newly assigned"
      assert tile(view, "moved") == "1 Moved from another zone"
      assert tile(view, "unchanged") == "0 Already in this zone"

      assert text_of(view, "#fare-zone-assignment-moved") =~
               "Moving stops can change which fares apply to journeys that use them."

      assert has_element?(view, "#fare-zone-assignment-row-1", "Riverside 001")
      assert text_of(view, "#fare-zone-assignment-row-1-from") == "Eastbank"
      assert text_of(view, "#fare-zone-assignment-row-1-to") == "Central"
      assert has_element?(view, "#fare-zone-assignment-dialog-confirm", "Assign 1 stop")
      refute confirm_disabled?(view)
      refute has_element?(view, "#fare-zone-assignment-reason")

      # Keep selection closes the review and leaves the selection alone.
      view |> element("#fare-zone-assignment-dialog-cancel") |> render_click()

      refute has_element?(view, "#fare-zone-assignment-dialog")
      assert text_of(view, "#fare-zone-selection-count") == "1 stop selected"

      # Remove zone is its own review: no target select, and a confirm that repeats
      # its verb and object.
      view |> element("#fare-zone-unassign-selection") |> render_click()

      assert has_element?(view, "#fare-zone-assignment-dialog-title", "Remove zone from 1 stop")
      refute has_element?(view, "#fare-zone-assignment-target")
      assert has_element?(view, "#fare-zone-assignment-dialog-confirm", "Remove zone")
      assert tile(view, "changed") == "1 Stops lose their zone"
    end

    test "a review of 150 selected stops lists 100 rows and counts the rest", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=B")

      assert text_of(view, "#fare-zone-select-matching") == "Select all 150 matching"

      view |> element("#fare-zone-select-matching") |> render_click()
      view |> element("#fare-zone-assign-selection") |> render_click()

      assert has_element?(
               view,
               "#fare-zone-assignment-dialog-title",
               "Assign 150 stops to a zone"
             )

      assert has_element?(view, "#fare-zone-assignment-rows", "150 stops in this review")

      assert tile(view, "added") == "0 Newly assigned"
      assert tile(view, "unchanged") == "150 Already in this zone"
      assert length(row_ids(view, "#fare-zone-assignment-rows li")) == 100
      assert has_element?(view, "#fare-zone-assignment-more", "and 50 more")
      assert has_element?(view, "#fare-zone-assignment-row-1", "Riverside 001")
      refute has_element?(view, "#fare-zone-assignment-row-101")
    end
  end

  describe "saving" do
    test "a revoked editor keeps the assignment review and leaves its stop unchanged", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      deactivate_membership_fixture(membership)
      confirm_save(view)

      assert dialog_open?(view)
      assert selected_target(view) == "B"

      assert text_of(view, "#fare-zone-assignment-error") ==
               "Changes couldn’t be saved. Your edits are still here."

      assert zone_id_of(stop_ids["BAY_1"]) == nil
    end

    test "two selected stops are assigned, the callout reports it and Undo restores them", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      select_stop(view, stop_ids["BAY_2"])
      assert text_of(view, "#fare-zone-selection-count") == "2 stops selected"

      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")

      # Both stops have no zone, so both are additions.
      assert tile(view, "added") == "2 Newly assigned"
      assert tile(view, "moved") == "0 Moved from another zone"
      assert tile(view, "unchanged") == "0 Already in this zone"

      # The report is a statement about the rows the save will write.
      assert text_of(view, "#fare-zone-assignment-row-1-from") == "No zone"
      assert text_of(view, "#fare-zone-assignment-row-1-to") == "Eastbank"
      assert text_of(view, "#fare-zone-assignment-row-2-from") == "No zone"
      assert text_of(view, "#fare-zone-assignment-row-2-to") == "Eastbank"

      confirm_save(view)

      # The dialog is gone, the report of what was written replaces it, the
      # selection it was made from is cleared and the rows show the new zone.
      refute has_element?(view, "#fare-zone-assignment-dialog")
      assert text_of(view, "#fare-zone-saved") == "2 stops assigned to Eastbank. Undo"
      refute has_element?(view, "#fare-zone-selection-count")
      assert has_element?(view, "#fare-zone-selection-hint")
      assert zone_id_of(stop_ids["BAY_1"]) == "B"
      assert zone_id_of(stop_ids["BAY_2"]) == "B"
      assert has_element?(view, "#fare-zone-row-2-count", "152")

      view |> element("#fare-zone-undo") |> render_click()

      assert text_of(view, "#fare-zone-saved") == "Change undone."
      refute has_element?(view, "#fare-zone-undo")
      assert zone_id_of(stop_ids["BAY_1"]) == nil
      assert zone_id_of(stop_ids["BAY_2"]) == nil
      assert has_element?(view, "#fare-zone-row-2-count", "150")
      assert has_element?(view, "#fare-zone-row-unassigned-count", "2")
    end

    test "a revoked editor cannot undo a saved assignment", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")
      confirm_save(view)

      assert zone_id_of(stop_ids["BAY_1"]) == "B"
      assert has_element?(view, "#fare-zone-undo")

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      deactivate_membership_fixture(membership)

      view |> element("#fare-zone-undo") |> render_click()

      assert text_of(view, "#fare-zone-saved") ==
               "Changes couldn’t be saved. Your edits are still here."

      refute has_element?(view, "#fare-zone-undo")
      assert zone_id_of(stop_ids["BAY_1"]) == "B"
    end

    test "removing assignments unassigns the reviewed stops", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=A")

      select_stop(view, stop_ids["WEST_1"])
      select_stop(view, stop_ids["WEST_2"])
      view |> element("#fare-zone-unassign-selection") |> render_click()

      assert tile(view, "changed") == "2 Stops lose their zone"
      assert text_of(view, "#fare-zone-assignment-row-1-from") == "Central"
      assert text_of(view, "#fare-zone-assignment-row-1-to") == "No zone"

      confirm_save(view)

      assert text_of(view, "#fare-zone-saved") == "2 stops unassigned. Undo"
      assert zone_id_of(stop_ids["WEST_1"]) == nil
      assert zone_id_of(stop_ids["WEST_2"]) == nil
    end

    test "a sibling platform the selection does not cover is disclosed", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=A")

      # The station itself is not boardable, so it cannot join the selection at
      # all; its platform can, and its sibling is then disclosed.
      select_stop(view, stop_ids["CENTRAL_STATION"])
      refute has_element?(view, "#fare-zone-selection-count")

      select_stop(view, stop_ids["PLATFORM_1"])
      assert text_of(view, "#fare-zone-selection-count") == "1 stop selected"

      view |> element("#fare-zone-assign-selection") |> render_click()

      assert text_of(view, "#fare-zone-assignment-siblings") ==
               "1 sibling platform is not selected. Each platform is assigned separately. Station groups are never changed silently."
    end
  end

  describe "a review that a second editor invalidates" do
    test "a stop that changed since the review is refused and Refresh review re-reads it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      select_stop(view, stop_ids["BAY_2"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")

      assert tile(view, "added") == "2 Newly assigned"
      assert tile(view, "moved") == "0 Moved from another zone"

      # Another editor assigns one of the reviewed stops while the dialog is open.
      {1, nil} =
        Repo.update_all(from(s in Stop, where: s.id == ^stop_ids["BAY_1"]),
          set: [zone_id: "A"]
        )

      confirm_save(view)

      # The fence refuses the whole write: the stops that moved are counted, the
      # review stays open with its target, and the other stop was not written.
      assert dialog_open?(view)

      assert text_of(view, "#fare-zone-assignment-stale") =~
               "1 selected stop changed since you opened this review."

      assert has_element?(view, "#fare-zone-assignment-refresh", "Refresh review")
      assert confirm_disabled?(view)
      assert selected_target(view) == "B"
      assert zone_id_of(stop_ids["BAY_1"]) == "A"
      assert zone_id_of(stop_ids["BAY_2"]) == nil
      assert has_element?(view, "#fare-zone-assignment-row-2", "Bayline 2")

      # Refresh review re-reads from current values: the counts follow the data and
      # the refusal is gone.
      view |> element("#fare-zone-assignment-refresh") |> render_click()

      refute has_element?(view, "#fare-zone-assignment-stale")
      refute confirm_disabled?(view)
      assert selected_target(view) == "B"

      assert tile(view, "added") == "1 Newly assigned"
      assert tile(view, "moved") == "1 Moved from another zone"

      assert text_of(view, "#fare-zone-assignment-row-1-from") == "Central"
      assert text_of(view, "#fare-zone-assignment-row-1-to") == "Eastbank"

      confirm_save(view)

      assert text_of(view, "#fare-zone-saved p") == "2 stops assigned to Eastbank."
      assert zone_id_of(stop_ids["BAY_1"]) == "B"
      assert zone_id_of(stop_ids["BAY_2"]) == "B"
    end

    test "a target zone deleted since the review is refused and the options are re-read", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=A")

      select_stop(view, stop_ids["WEST_1"])
      select_stop(view, stop_ids["WEST_2"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")

      # Another editor deletes the target zone; its 150 stops become unassigned.
      {:ok, _result} =
        FareZones.delete_zone(
          %GtfsPlanner.Gtfs.AuditContext{
            actor_id: user.id,
            actor_email: user.email,
            organization_id: organization.id,
            gtfs_version_id: version.id
          },
          "B",
          nil,
          %{
            stop_count: @east_count,
            rule_count: 0
          }
        )

      confirm_save(view)

      assert dialog_open?(view)

      assert text_of(view, "#fare-zone-assignment-error") ==
               "That zone no longer exists. Choose another zone."

      # The select offers the zones that exist now, and the review was re-read:
      # both selected stops are already in Central, so nothing would change.
      assert target_options(view) == [{"Central · A", "A"}]
      assert selected_target(view) == "A"
      assert confirm_disabled?(view)
      assert zone_id_of(stop_ids["WEST_1"]) == "A"

      # Cancel is still the way out of a review that cannot be saved.
      view |> element("#fare-zone-assignment-dialog-cancel") |> render_click()
      refute has_element?(view, "#fare-zone-assignment-dialog")
    end

    test "a version that is no longer published reports the save failure and keeps the review", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")

      {1, nil} =
        Repo.update_all(from(v in GtfsVersion, where: v.id == ^version.id),
          set: [publication_status: "failed", published_at: nil]
        )

      confirm_save(view)

      assert dialog_open?(view)

      assert text_of(view, "#fare-zone-assignment-error") ==
               "Changes couldn’t be saved. Your edits are still here."

      # The review is untouched: the target is still the chosen one and the row is
      # still the reviewed row.
      assert selected_target(view) == "B"
      assert has_element?(view, "#fare-zone-assignment-row-1", "Bayline 1")
      assert zone_id_of(stop_ids["BAY_1"]) == nil
    end
  end

  describe "Undo" do
    test "a second save replaces Undo instead of stacking it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")
      confirm_save(view)

      assert text_of(view, "#fare-zone-saved p") == "1 stop assigned to Eastbank."

      select_stop(view, stop_ids["WEST_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")
      confirm_save(view)

      # The callout reports the save that just happened, and its Undo refers to
      # that save alone: the first assignment stays where it was.
      assert text_of(view, "#fare-zone-saved p") == "1 stop assigned to Eastbank."
      assert zone_id_of(stop_ids["BAY_1"]) == "B"

      view |> element("#fare-zone-undo") |> render_click()

      assert text_of(view, "#fare-zone-saved") == "Change undone."
      assert zone_id_of(stop_ids["WEST_1"]) == "A"
      assert zone_id_of(stop_ids["BAY_1"]) == "B"
    end

    test "a tab change takes Undo with it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")
      confirm_save(view)

      assert has_element?(view, "#fare-zone-undo")

      render_patch(view, "/gtfs/#{version.id}/settings/fares/rules")

      assert_patch(view, "/gtfs/#{version.id}/settings/fares/rules")
      refute has_element?(view, "#fare-zone-saved")

      # Coming back does not bring it back either: the tab change ended it.
      render_patch(view, "/gtfs/#{version.id}/settings/fares")

      assert has_element?(view, "#fare-zones-panel")
      refute has_element?(view, "#fare-zone-saved")

      # The write itself is permanent until it is undone by editing again.
      assert zone_id_of(stop_ids["BAY_1"]) == "B"
    end

    test "Undo refuses to overwrite a change made after the save", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")
      confirm_save(view)

      assert zone_id_of(stop_ids["BAY_1"]) == "B"

      {1, nil} =
        Repo.update_all(from(s in Stop, where: s.id == ^stop_ids["BAY_1"]),
          set: [zone_id: "A"]
        )

      view |> element("#fare-zone-undo") |> render_click()

      assert text_of(view, "#fare-zone-saved") ==
               "Undo wasn’t applied because some stops changed after the save."

      refute has_element?(view, "#fare-zone-undo")
      assert zone_id_of(stop_ids["BAY_1"]) == "A"
    end

    test "Undo of a save whose version is no longer published reports the failure", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")
      confirm_save(view)

      {1, nil} =
        Repo.update_all(from(v in GtfsVersion, where: v.id == ^version.id),
          set: [publication_status: "failed", published_at: nil]
        )

      view |> element("#fare-zone-undo") |> render_click()

      assert text_of(view, "#fare-zone-saved") ==
               "Changes couldn’t be saved. Your edits are still here."

      refute has_element?(view, "#fare-zone-undo")
      assert zone_id_of(stop_ids["BAY_1"]) == "B"
    end
  end

  describe "zone identity and scope" do
    test "a padded implicit zone ID is offered and written byte-for-byte, and Undo restores it",
         %{
           conn: conn,
           user: user,
           organization: organization,
           version: version
         } do
      # Two implicit zones: " A" (padding included) and "Z", whose only stop leaves
      # the inventory when it moves.
      [padded, last] =
        insert_stops(organization, version, [
          located_stop("GATE_50%", "Gate 50%", " A"),
          located_stop("LAST", "Last Stop", "Z")
        ])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      # " A" sorts before "A", so it is the review's default target, and the
      # select carries its exact bytes; the leading space is never trimmed.
      select_stop(view, last.id)
      view |> element("#fare-zone-assign-selection") |> render_click()

      assert selected_target(view) == " A"
      assert {" A ·  A", " A"} in target_options(view)

      # `text_of/2` collapses whitespace, which would hide the padded ID's leading
      # space, so the row's own nodes are read without normalizing them.
      assert exact_texts(view, "#fare-zone-assignment-row-1-from") == ["Z"]
      assert exact_texts(view, "#fare-zone-assignment-row-1-to") == [" A"]

      assert has_element?(view, "#fare-zone-row-4", "Z")

      choose_target(view, " A")
      confirm_save(view)

      assert zone_id_of(last.id) == " A"
      assert zone_id_of(padded.id) == " A"
      assert raw_text_of(view, "#fare-zone-saved p") == "1 stop assigned to  A."

      # Z left the inventory with its last stop, and Undo still restores it.
      refute has_element?(view, "#fare-zone-row-4")

      view |> element("#fare-zone-undo") |> render_click()

      assert text_of(view, "#fare-zone-saved") == "Change undone."
      assert zone_id_of(last.id) == "Z"
      assert has_element?(view, "#fare-zone-row-4", "Z")
    end

    test "another organization's and another version's stops are never written", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      other_version_stop: other_version_stop,
      foreign_stop: foreign_stop,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares")

      # A crafted toggle cannot put an out-of-scope stop in the selection, so the
      # review it opens cannot contain one either.
      for id <- [foreign_stop.id, other_version_stop.id, stop_ids["CENTRAL_STATION"], "nope"] do
        render_click(view, "toggle_stop", %{"id" => id})
      end

      refute has_element?(view, "#fare-zone-selection-count")

      select_stop(view, stop_ids["BAY_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()
      choose_target(view, "B")

      assert has_element?(view, "#fare-zone-assignment-dialog-title", "Assign 1 stop to a zone")

      refute has_element?(view, "#fare-zone-assignment-row-2")

      confirm_save(view)

      assert zone_id_of(stop_ids["BAY_1"]) == "B"
      assert zone_id_of(foreign_stop.id) == "A"
      assert zone_id_of(other_version_stop.id) == "A"

      view |> element("#fare-zone-undo") |> render_click()

      assert zone_id_of(foreign_stop.id) == "A"
      assert zone_id_of(other_version_stop.id) == "A"
    end

    test "an assign review with no zone to assign to says so", %{
      conn: conn,
      user: user,
      organization: organization
    } do
      # This version carries a stop but no zone at all: there is nothing to assign
      # to, and the page states that instead of offering an action that cannot run.
      empty_zone_version = gtfs_version_fixture(organization.id)

      [stop] =
        insert_stops(organization, empty_zone_version, [located_stop("PLAIN", "Plain Stop", nil)])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{empty_zone_version.id}/settings/fares")

      select_stop(view, stop.id)

      # The version has no zone at all, so the workspace shows its first-use
      # state and the selection bar never mounts; the reason is still proved
      # through the review the crafted event below reaches.
      assert has_element?(view, "#fare-zone-first-use")
      refute has_element?(view, "#fare-zone-assign-unavailable")
      refute has_element?(view, "#fare-zone-assign-selection")

      # A stale or crafted assign event still reaches the review, which says there
      # is no target instead of previewing a write it cannot make. The target
      # select is part of an assign review, so it renders - with no zone in it.
      render_click(view, "open_assignment", %{"mode" => "assign"})

      assert dialog_open?(view)
      assert target_options(view) == []
      assert confirm_disabled?(view)
      assert text_of(view, "#fare-zone-assignment-reason") == "Create a fare zone first."
    end

    test "the review's DOM ids never carry a zone ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version,
      stop_ids: stop_ids
    } do
      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/settings/fares?zone=A")

      select_stop(view, stop_ids["WEST_1"])
      view |> element("#fare-zone-assign-selection") |> render_click()

      # Rows are numbered, options carry the exact IDs as values, and the zone IDs
      # never reach an id attribute (CR-7).
      assert row_ids(view, "#fare-zone-assignment-rows li") == [
               "fare-zone-assignment-row-1"
             ]

      assert row_ids(view, "#fare-zone-assignment-dialog [id]")
             |> Enum.all?(&(&1 =~ ~r/^fare-zone-assignment-[a-z0-9-]+$/))
    end
  end

  # The row is only rendered for the page it is on, so a stop that the current
  # page does not show is selected through the same event its checkbox sends.
  defp tile(view, key), do: text_of(view, "#fare-zone-assignment-summary-#{key}")

  defp select_stop(view, uuid) do
    if has_element?(view, "#stops-#{uuid} input[type='checkbox']") do
      view |> element("#stops-#{uuid} input[type='checkbox']") |> render_click()
    else
      render_click(view, "toggle_stop", %{"id" => uuid})
    end
  end

  defp choose_target(view, zone_id) do
    view |> form("#fare-zone-assignment-target-form", %{"target" => zone_id}) |> render_change()
  end

  defp confirm_save(view) do
    view |> element("#fare-zone-assignment-dialog-confirm") |> render_click()
  end

  defp dialog_open?(view),
    do: attribute(view, "#fare-zone-assignment-dialog", "data-open") == "true"

  defp confirm_disabled?(view) do
    view
    |> nodes("#fare-zone-assignment-dialog-confirm")
    |> LazyHTML.attribute("disabled")
    |> Enum.any?()
  end

  defp target_options(view) do
    options = nodes(view, "#fare-zone-assignment-target option")

    Enum.zip(Enum.map(options, &LazyHTML.text/1), LazyHTML.attribute(options, "value"))
  end

  defp selected_target(view) do
    view
    |> nodes("#fare-zone-assignment-target option[selected]")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp row_ids(view, selector) do
    view |> nodes(selector) |> LazyHTML.attribute("id")
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

  # The text of each matched node with the template's own indentation trimmed.
  # A byte-exact expectation (the leading space of a padded zone ID) has to read
  # the nodes without the whitespace normalization `text_of/2` applies, but the
  # newlines the HEEx template leaves around the value are not part of the value.
  defp raw_texts(view, selector) do
    view |> nodes(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # The text of the nodes exactly as rendered, leading and trailing spaces included:
  # a stored ID's own bytes are what a review shows and what the save writes.
  defp exact_texts(view, selector) do
    view |> nodes(selector) |> Enum.map(&LazyHTML.text/1)
  end

  defp raw_text_of(view, selector), do: view |> raw_texts(selector) |> List.first()

  defp nodes(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp zone_id_of(stop_id), do: Repo.get!(Stop, stop_id).zone_id

  defp insert_stops(organization, version, stops) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(stops, fn stop ->
        {lat, lon} = Map.get(stop, :located_at, {nil, nil})

        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop.stop_id,
          stop_name: stop.stop_name,
          location_type: Map.get(stop, :location_type, 0),
          zone_id: Map.get(stop, :zone_id),
          stop_lat: decimal(lat),
          stop_lon: decimal(lon),
          parent_station: Map.get(stop, :parent_station),
          platform_code: Map.get(stop, :platform_code),
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

  defp located_stop(stop_id, stop_name, zone_id),
    do: %{stop_id: stop_id, stop_name: stop_name, zone_id: zone_id, located_at: {42.3, -71.1}}

  defp pad(index), do: String.pad_leading(Integer.to_string(index), 3, "0")

  defp decimal(nil), do: nil
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal(value), do: Decimal.new(value)
end

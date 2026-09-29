defmodule GtfsPlannerWeb.Gtfs.TransfersLiveEditTest do
  @moduledoc """
  Merge evidence (EV-21) for editing existing transfer rules.

  The editor's edit mode has to open on the rule the inspector shows with every
  stored value in place: the eight GTFS fields, the scope the row's own selectors
  imply, the two stops the version resolves — or the row's own endpoint when the
  stored stop is gone — and the option lists, which keep a stored route or trip
  the version no longer offers with the reason it is not one of the stop's own
  choices. Saving goes through `Gtfs.update_general_transfer/4` with the row's own
  `updated_at`: an accepted change writes that row and no other, a rule that moved
  on is refused with the reload path while the draft stays, and a rule that was
  deleted closes the editor with a flash.

  "Create the reverse rule" must open an unsaved create draft with the six key fields
  mirrored and the effect copied, so nothing reaches the database until the
  operator saves it, and the duplicate message's "Open existing rule" and the
  compare view's "Edit rule" must name another rule in the URL — filters cleared —
  and open that rule's editor after the load. The in-seat view renders none of
  these controls and ignores the event, because types 4/5 belong to Blocks (R1).

  Every case asserts literal copy, field values, option labels, patched URLs and
  the stored rows against the shared fixture network. The form events here are
  written by hand, so no browser is involved; the same editor driven by a real
  operator is the `edit:` journey in `assets/e2e/transfers.spec.js` (step 30).

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner_web/live/gtfs/transfers_live_edit_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  # The eight fields a draft carries, as the editor's own form sends them. A case
  # names the fields it moves and the rest travel with the payload the way a
  # browser form sends them.
  @blank_draft %{
    "from_stop_id" => "",
    "to_stop_id" => "",
    "from_route_id" => "",
    "to_route_id" => "",
    "from_trip_id" => "",
    "to_trip_id" => "",
    "transfer_type" => "2",
    "min_transfer_time" => ""
  }

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    transfer_network_fixture(organization.id, version.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      version: version
    }
  end

  describe "opening a stored rule" do
    test "the inspector's Edit loads the stored stops, routes, type and time", ctx do
      rule =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: rule.id))

      assert has_element?(view, "#transfer-inspector-edit", "Edit rule")
      assert has_element?(view, "#transfer-inspector-reverse-create", "Create the reverse rule")

      view |> element("#transfer-inspector-edit") |> render_click()

      document = doc(view)

      # The stored rule is the draft, under the scope its selectors imply: an
      # arriving and a departing route is a route pair.
      assert has_element?(view, "#transfer-editor")
      refute has_element?(view, "#transfers")

      assert text_of(document, "#transfer-editor h2") == "Edit transfer rule"

      assert text_of(document, "#transfer-editor > p") ==
               "#{ctx.version.name} · works in one direction"

      assert has_element?(view, "#transfer-scope-routes[checked]")
      assert has_element?(view, "#transfer_from_stop_id[value='CEN-A']")
      assert has_element?(view, "#transfer_to_stop_id[value='CEN-C']")

      assert has_element?(
               view,
               "#transfer_from_stop_id_text_input[value='Central · Bay A']"
             )

      assert has_element?(view, "#transfer_to_stop_id_text_input[value='Central · Bay C']")
      assert text_of(document, "#transfer-from-stop-hint") == "Platform A at Central Station"
      assert text_of(document, "#transfer-to-stop-hint") == "Platform C at Central Station"

      assert has_element?(view, "#transfer-from-route option[value='12'][selected]")
      assert has_element?(view, "#transfer-to-route option[value='24'][selected]")

      # Only the routes each stop's coverage carries are offered.
      assert option_labels(document, "#transfer-from-route option") == [
               "Choose route",
               "12 · Riverside",
               "6 · Museum"
             ]

      assert option_labels(document, "#transfer-to-route option") == [
               "Choose route",
               "24 · Harbor"
             ]

      assert has_element?(view, "#transfer-type-2[checked]")
      assert has_element?(view, "#transfer-min-time[value='180']")

      assert text_of(document, "#transfer-min-time-readout") ==
               "3 min · include the walk between the stops and a buffer for late buses."

      # The stored rule is not yet a change, and the trip select waits for the
      # mixed-selector scope.
      refute has_element?(view, "#transfer-from-trip")
      refute has_element?(view, "#transfer-to-trip")
      refute has_element?(view, "#transfer-dirty")

      assert has_element?(view, "#transfer-save[phx-disable-with='Saving…']", "Save changes")
      assert has_element?(view, "#transfer-cancel", "Cancel")
      refute has_element?(view, "#transfer-form-error")
      refute has_element?(view, "#transfer-stale")

      assert text_of(document, "#transfer-draft-preview") =~ "Central · Bay A"
      assert text_of(document, "#transfer-draft-preview") =~ "Central · Bay C"
    end

    test "a stored trip opens the mixed-selector scope with the trip selected", ctx do
      rule =
        rule!(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "12",
          from_trip_id: "12-0815",
          transfer_type: 0
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: rule.id))
      view |> element("#transfer-inspector-edit") |> render_click()

      document = doc(view)

      assert has_element?(view, "#transfer-scope-custom[checked]")
      assert has_element?(view, "#transfer-from-route option[value='12'][selected]")
      assert has_element?(view, "#transfer-from-trip option[value='12-0815'][selected]")

      assert option_labels(document, "#transfer-from-trip option") == [
               "Any trip",
               "08:25 · Harbor · WKDY",
               "10:10 · Harbor · WKDY"
             ]

      assert has_element?(view, "#transfer-type-0[checked]")
      refute has_element?(view, "#transfer-min-time")
      refute has_element?(view, "#transfer-dirty")
    end

    test "stored selectors the version no longer offers stay selected, with their notes", ctx do
      # The inactive route 99 serves MKT in the fixture network but is never
      # offered on its own, and trip 12-1010 belongs to a route that serves
      # CEN-A without stopping there.
      inactive =
        rule!(ctx, %{
          from_stop_id: "MKT",
          to_stop_id: "HBR",
          from_route_id: "99",
          to_route_id: "24",
          transfer_type: 1
        })

      stale_trip =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "MKT",
          from_route_id: "12",
          from_trip_id: "12-1010",
          transfer_type: 0
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: inactive.id))
      view |> element("#transfer-inspector-edit") |> render_click()

      document = doc(view)

      assert option_labels(document, "#transfer-from-route option") == [
               "Choose route",
               "12 · Riverside",
               "24 · Harbor",
               "99 · Old Line — inactive route"
             ]

      assert has_element?(view, "#transfer-from-route option[value='99'][selected]")
      assert has_element?(view, "#transfer-to-route option[value='24'][selected]")

      view |> element("#transfer-cancel") |> render_click()
      view |> element("#transfer-select-#{stale_trip.id}") |> render_click()
      view |> element("#transfer-inspector-edit") |> render_click()

      document = doc(view)

      assert has_element?(view, "#transfer-scope-custom[checked]")

      assert option_labels(document, "#transfer-from-trip option") == [
               "Any trip",
               "08:15 · Harbor · WKDY",
               "Harbor · WKDY — doesn't stop here"
             ]

      assert has_element?(view, "#transfer-from-trip option[value='12-1010'][selected]")
    end

    test "a stored stop the version no longer holds still shows as the draft's value", ctx do
      rule = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "GHOST", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: rule.id))
      view |> element("#transfer-inspector-edit") |> render_click()

      document = doc(view)

      assert has_element?(view, "#transfer_to_stop_id[value='GHOST']")
      assert has_element?(view, "#transfer_to_stop_id_text_input[value='GHOST']")
      assert text_of(document, "#transfer-to-stop-hint") == "Not in this version"
      assert has_element?(view, "#transfer-scope-stops[checked]")
    end
  end

  describe "saving an edit" do
    test "the accepted change writes that rule only and selects it", ctx do
      untouched = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      rule =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 2,
          min_transfer_time: 180
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: rule.id))
      view |> element("#transfer-inspector-edit") |> render_click()

      change_draft(view, ["transfer", "min_transfer_time"], :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "240"
      })

      assert has_element?(view, "#transfer-dirty")

      assert text_of(doc(view), "#transfer-min-time-readout") ==
               "4 min · include the walk between the stops and a buffer for late buses."

      save_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "240"
      })

      assert has_element?(view, "#flash-info", "Transfer rule saved in #{ctx.version.name}.")
      refute has_element?(view, "#transfer-editor")

      # The row is updated, the other rule and the row count are not.
      assert Repo.get(Transfer, rule.id).min_transfer_time == 240
      assert Repo.get(Transfer, untouched.id).transfer_type == 0
      assert length(Repo.all_by(Transfer, gtfs_version_id: ctx.version.id)) == 2

      assert has_element?(view, "#transfers")
      assert has_element?(view, "#transfer-select-#{rule.id}[aria-current='true']")
      assert_patch(view, transfers_path(ctx.version, rule: rule.id))
    end

    test "a rule changed elsewhere keeps the draft and reopens the stored values on reload",
         ctx do
      rule =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 2,
          min_transfer_time: 180
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: rule.id))
      view |> element("#transfer-inspector-edit") |> render_click()

      # Another writer saves the same rule while the editor is open.
      assert {:ok, _moved} =
               Gtfs.update_general_transfer(
                 rule.id,
                 %{
                   from_stop_id: "CEN-A",
                   to_stop_id: "CEN-C",
                   transfer_type: 2,
                   min_transfer_time: 300
                 },
                 rule.updated_at,
                 audit(ctx)
               )

      stored = %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2"
      }

      change_draft(
        view,
        ["transfer", "min_transfer_time"],
        :stops,
        Map.put(stored, "min_transfer_time", "240")
      )

      save_draft(view, :stops, Map.put(stored, "min_transfer_time", "240"))

      document = doc(view)

      assert text_of(document, "#transfer-stale") =~ "This rule changed while you were editing"
      assert text_of(document, "#transfer-stale") =~ "Someone saved a change to it."

      assert text_of(document, "#transfer-stale") =~
               "Your entries are still here. Reload the rule to see what changed before you save."

      assert has_element?(view, "#transfer-reload-rule", "Reload rule")
      refute has_element?(view, "#transfer-form-error")

      # The other writer's value is still stored and the operator's entry is kept.
      assert Repo.get(Transfer, rule.id).min_transfer_time == 300
      assert has_element?(view, "#transfer-min-time[value='240']")
      assert has_element?(view, "#transfer-dirty")

      view |> element("#transfer-reload-rule") |> render_click()

      # The editor reopens on the stored rule, without the stale notice.
      assert has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfer-min-time[value='300']")
      refute has_element?(view, "#transfer-stale")
      refute has_element?(view, "#transfer-dirty")
      assert text_of(doc(view), "#transfer-editor h2") == "Edit transfer rule"
    end

    test "a rule deleted elsewhere closes the editor and flashes", ctx do
      rule = rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0})
      keeper = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: rule.id))
      view |> element("#transfer-inspector-edit") |> render_click()

      assert {:ok, _deleted} =
               Gtfs.delete_general_transfer(rule.id, rule.updated_at, audit(ctx))

      change_draft(view, ["transfer", "transfer_type"], :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "1"
      })

      save_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "1"
      })

      assert has_element?(view, "#flash-info", "This rule is no longer in this version.")

      refute has_element?(view, "#transfer-editor")

      # The list loaded again without the rule, and nothing was written.
      assert Repo.get(Transfer, rule.id) == nil
      refute has_element?(view, "tr#transfers-#{rule.id}")
      assert has_element?(view, "tr#transfers-#{keeper.id}")
    end
  end

  describe "reverse drafts" do
    test "Create reverse rule mirrors the key into an unsaved draft", ctx do
      rule =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: rule.id))

      view |> element("#transfer-inspector-reverse-create") |> render_click()

      document = doc(view)

      # A create draft, not an edit of the stored rule.
      assert text_of(document, "#transfer-editor h2") == "Create transfer rule"
      assert has_element?(view, "#transfer-save", "Create rule")
      assert has_element?(view, "#transfer-scope-routes[checked]")

      # The six key fields are mirrored and the effect is copied.
      assert has_element?(view, "#transfer_from_stop_id[value='CEN-C']")
      assert has_element?(view, "#transfer_to_stop_id[value='CEN-A']")
      assert has_element?(view, "#transfer-from-route option[value='24'][selected]")
      assert has_element?(view, "#transfer-to-route option[value='12'][selected]")
      assert has_element?(view, "#transfer-type-2[checked]")
      assert has_element?(view, "#transfer-min-time[value='180']")
      assert text_of(document, "#transfer-dirty") == "Unsaved changes"

      assert text_of(document, "#transfer-draft-preview") =~ "Central · Bay C"
      assert text_of(document, "#transfer-draft-preview") =~ "Central · Bay A"

      # Nothing is written until the draft is saved.
      assert Repo.all_by(Transfer, gtfs_version_id: ctx.version.id) |> Enum.map(& &1.id) == [
               rule.id
             ]

      save_draft(view, :routes, %{
        "from_stop_id" => "CEN-C",
        "to_stop_id" => "CEN-A",
        "from_route_id" => "24",
        "to_route_id" => "12",
        "transfer_type" => "2",
        "min_transfer_time" => "180"
      })

      assert has_element?(view, "#flash-info", "Transfer rule saved in #{ctx.version.name}.")

      reverse =
        Repo.get_by(Transfer,
          gtfs_version_id: ctx.version.id,
          from_stop_id: "CEN-C",
          to_stop_id: "CEN-A"
        )

      assert reverse.from_route_id == "24"
      assert reverse.to_route_id == "12"
      assert reverse.transfer_type == 2
      assert reverse.min_transfer_time == 180

      assert Repo.get(Transfer, rule.id).from_stop_id == "CEN-A"
      assert length(Repo.all_by(Transfer, gtfs_version_id: ctx.version.id)) == 2
    end
  end

  describe "another rule's editor" do
    test "the duplicate's Open existing rule patches to that rule with filters cleared", ctx do
      collision =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 2,
          min_transfer_time: 240
        })

      rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      # The colliding rule is not in the list the operator is looking at.
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, q: "harbor"))

      view |> element("#transfers-create") |> render_click()

      save_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "240"
      })

      assert text_of(doc(view), "#transfer-form-error") =~
               "A rule already covers these stops and services."

      assert has_element?(view, "#transfer-open-existing", "Open existing rule")

      view |> element("#transfer-open-existing") |> render_click()

      # The refused draft is dirty, so the departure waits behind the discard
      # question (AC-20); confirming it opens the rule the collision names.
      assert has_element?(view, "#transfer-discard-dialog[data-open='true']")
      view |> element("#transfer-discard-dialog-confirm") |> render_click()

      # The rule is named in the URL — the search is gone — and its editor is the
      # one that opened.
      assert_patch(view, transfers_path(ctx.version, rule: collision.id))
      assert has_element?(view, "#transfer-editor")
      assert text_of(doc(view), "#transfer-editor h2") == "Edit transfer rule"
      assert has_element?(view, "#transfer-min-time[value='240']")
      assert has_element?(view, "#transfer_from_stop_id[value='CEN-A']")

      view |> element("#transfer-cancel") |> render_click()

      # The list behind the editor is the bare general list: the colliding rule
      # the search had hidden is the selected row of it, and the search field is
      # empty. Closing the editor keeps the URL the opening patch already set.
      refute has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfer-select-#{collision.id}[aria-current='true']")
      assert has_element?(view, "#transfer-search-form input[name='q'][value='']")
      assert has_element?(view, "#transfer-check-#{collision.id}")
    end

    test "the compare view's Edit rule opens that rule's editor", ctx do
      arrival =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_route_id: "12",
          transfer_type: 2,
          min_transfer_time: 120
        })

      departure =
        rule!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          to_route_id: "24",
          transfer_type: 3
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: arrival.id))

      view |> element("#transfer-inspector-compare") |> render_click()

      assert has_element?(view, "#transfer-compare-dialog")

      # Each listed rule carries its own action, and the selected rule's Edit is
      # the one the dialog offers for it.
      assert has_element?(view, "#transfer-compare-edit-#{arrival.id}", "Edit rule")
      assert has_element?(view, "#transfer-compare-edit-#{departure.id}", "Edit rule")

      view |> element("#transfer-compare-edit-#{departure.id}") |> render_click()

      refute has_element?(view, "#transfer-compare-dialog")
      assert_patch(view, transfers_path(ctx.version, rule: departure.id))

      assert has_element?(view, "#transfer-editor")
      assert text_of(doc(view), "#transfer-editor h2") == "Edit transfer rule"
      assert has_element?(view, "#transfer-type-3[checked]")
      assert has_element?(view, "#transfer-scope-routes[checked]")
      assert has_element?(view, "#transfer-to-route option[value='24'][selected]")
      refute has_element?(view, "#transfer-min-time")
    end
  end

  describe "the in-seat view and crafted events" do
    test "no edit or reverse control renders, and a pushed open_edit changes nothing", ctx do
      record =
        in_seat!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_trip_id: "12-0815",
          to_trip_id: "24-0840",
          transfer_type: 4
        })

      general = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      refute has_element?(view, "#transfer-inspector-edit")
      refute has_element?(view, "#transfer-inspector-reverse-create")
      refute has_element?(view, "#transfer-inspector-delete")

      render_hook(view, "open_edit", %{"id" => record.id})
      render_hook(view, "reverse_draft", %{})

      refute has_element?(view, "#transfer-editor")

      # The general view ignores an id it is not showing, a malformed id and the
      # in-seat record's own id: only a loaded general row opens.
      {:ok, general_view, _html} = live(ctx.conn, transfers_path(ctx.version))

      render_hook(general_view, "open_edit", %{"id" => record.id})
      refute has_element?(general_view, "#transfer-editor")

      render_hook(general_view, "open_edit", %{"id" => "not-a-uuid"})
      refute has_element?(general_view, "#transfer-editor")

      render_hook(general_view, "open_edit", %{"id" => Ecto.UUID.generate()})
      refute has_element?(general_view, "#transfer-editor")

      render_hook(general_view, "open_edit", %{"id" => general.id})

      assert has_element?(general_view, "#transfer-editor")
      assert has_element?(general_view, "#transfer-editor h2", "Edit transfer rule")
    end
  end

  # The editor's form submits the whole draft; a case names the fields it moved and
  # the rest travel the way a browser form sends them.
  defp change_draft(view, target, scope, values) do
    render_change(
      element(view, "#transfer-form"),
      %{"_target" => target, "scope" => to_string(scope), "transfer" => draft(values)}
    )
  end

  defp save_draft(view, scope, values) do
    render_submit(
      element(view, "#transfer-form"),
      %{"scope" => to_string(scope), "transfer" => draft(values)}
    )
  end

  defp draft(values), do: Map.merge(@blank_draft, values)

  defp option_labels(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp transfers_path(version, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{version.id}/transfers#{query}"
  end

  defp rule!(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  defp in_seat!(ctx, attrs), do: rule!(ctx, Map.put_new(attrs, :transfer_type, 4))

  defp audit(ctx) do
    %AuditContext{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      station_stop_id: nil,
      actor_id: ctx.user.id,
      actor_email: ctx.user.email
    }
  end

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end
end

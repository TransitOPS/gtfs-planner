defmodule GtfsPlannerWeb.Gtfs.TransfersLiveCreateTest do
  @moduledoc """
  Merge evidence (EV-20) for the create-transfer editor.

  The editor replaces the list pane while a draft is open: the header's "Create
  transfer rule" button and the first-use CTA open it in the general view only, the
  draft starts as a minimum-time rule with no stops and no time, and the context
  pane previews it before it exists. The draft's own rules are the cases here —
  the stop search offers only the stops a rule may name, the route and trip
  selects follow the chosen scope and stop, a changed scope, stop or route clears
  the selectors that were answered for the old one, the minimum time appears only
  for type 2, and the route pair a required scope needs is refused on the select
  that is missing.

  Saving goes through `Gtfs.create_general_transfer/2`: a valid draft creates one
  row, flashes the version it landed in and selects the new rule; the server's own
  reference errors come back on the field that caused them with every entered
  value kept; a key collision names the row that holds it — a general rule to
  edit, a type 4/5 record to view on Blocks; and three serialization failures keep
  the draft with a retry. A crafted save payload cannot name a tenant or a type 4
  row, because the changeset casts the eight GTFS fields and nothing else.

  The form events here are written by hand, so no browser is involved; the
  LiveSelect widget's own keyboard handling and the same editor driven by a real
  operator are the `create:` journey in `assets/e2e/transfers.spec.js` (step 30).
  Every case asserts literal copy, field values, option labels and stored rows
  against the shared fixture network.

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner_web/live/gtfs/transfers_live_create_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  # The eight fields the draft starts with, as the editor's own form sends them:
  # a minimum-time rule, no stops and no time. A case names the fields it moves and
  # the rest travel with the payload the way a browser form sends them.
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
    # The busy case swaps `:reviewed_apply_transaction` for the mock, so the file
    # runs one case at a time and restores the previous adapter afterwards.
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

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

  describe "opening the editor" do
    test "the header button replaces the list pane with the draft", ctx do
      rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(view, "#transfers-create", "Create transfer rule")
      refute has_element?(view, "#transfer-editor")

      view |> element("#transfers-create") |> render_click()

      document = doc(view)

      # The draft is the only thing the pane shows, and the context pane answers
      # the draft rather than a selected rule.
      assert has_element?(view, "#transfer-editor")
      refute has_element?(view, "#transfers")
      refute has_element?(view, "#transfers-view-general")
      refute has_element?(view, "#transfers-create")

      assert text_of(document, "#transfer-editor h2") == "Create transfer rule"

      assert text_of(document, "#transfer-editor > p") ==
               "#{ctx.version.name} · works in one direction"

      assert has_element?(view, "#transfer-back", "Back to transfers")

      # A minimum-time rule with nothing chosen and no time entered.
      assert has_element?(view, "#transfer-scope-stops[checked]")
      assert has_element?(view, "#transfer-type-2[checked]")
      assert has_element?(view, "#transfer-min-time[value='']")
      assert has_element?(view, "#transfer-from-stop")
      assert has_element?(view, "#transfer-to-stop")

      assert text_of(document, "#transfer-from-stop-hint") ==
               "Choose a stop or a whole station from this version."

      assert text_of(document, "#transfer-to-stop-hint") ==
               "Choose a stop or a whole station from this version."

      # No route and no trip selector until a scope asks for one.
      refute has_element?(view, "#transfer-from-route")
      refute has_element?(view, "#transfer-to-route")
      refute has_element?(view, "#transfer-from-trip")
      refute has_element?(view, "#transfer-dirty")

      assert has_element?(view, "#transfer-save[phx-disable-with='Saving…']", "Create rule")
      assert has_element?(view, "#transfer-cancel", "Cancel")

      # No time typed yet, so the readout is only the guidance.
      assert text_of(document, "#transfer-min-time-readout") ==
               "Include the walk between the stops and a buffer for late buses."

      assert text_of(document, "#transfer-draft-preview") =~
               "What riders and trip planners will see"

      assert text_of(document, "#transfer-draft-preview") =~
               "Choose both stops to preview the connection."

      refute has_element?(view, "#transfer-inspector-empty")
    end

    test "the first-use CTA opens the same editor on a version with no rules", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(view, "#transfers-first-use")
      assert has_element?(view, "#transfers-first-use-create", "Create transfer rule")

      view |> element("#transfers-first-use-create") |> render_click()

      assert has_element?(view, "#transfer-editor")
      refute has_element?(view, "#transfers-first-use")
    end

    test "the in-seat view offers no create control and no editor", ctx do
      in_seat!(ctx, %{
        from_stop_id: "CEN",
        to_stop_id: "CEN",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 4
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      refute has_element?(view, "#transfers-create")
      refute has_element?(view, "#transfers-first-use-create")
      refute has_element?(view, "#transfer-editor")

      # A draft is a general-view surface: the same event leaves the in-seat list
      # as it was.
      assert render_hook(view, "open_create", %{}) =~ "Read-only here"

      refute has_element?(view, "#transfer-editor")
    end
  end

  describe "the stop search" do
    test "offers only the stops a rule may name", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      # The widget's own hook opens the dropdown on a text change, then the widget
      # asks the page for the options to show.
      render_hook(element(view, "#transfer-from-stop"), "change", %{"text" => "central"})

      render_hook(view, "live_select_change", %{"text" => "central", "id" => "transfer-from-stop"})

      # `Gtfs.search_transfer_stops/3` answers in name then ID order, so the two
      # platforms precede the station they belong to. CEN-E is an entrance: a rule
      # cannot name it, so the search never offers it (R2).
      assert option_labels(doc(view), "#transfer-from-stop li span:first-child") == [
               "Central · Bay A",
               "Central · Bay C",
               "Central Station"
             ]

      # Each option says what kind of place it is under its name.
      assert option_labels(doc(view), "#transfer-from-stop li span:last-child") == [
               "Platform A at Central Station",
               "Platform C at Central Station",
               "Station · covers 2 platforms"
             ]

      refute render(view) =~ "Central · Main entrance"
    end

    test "resolves the chosen stop's kind line", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      change_draft(view, ["transfer", "from_stop_id"], :stops, %{"from_stop_id" => "CEN"})

      assert text_of(doc(view), "#transfer-from-stop-hint") == "Station · covers 2 platforms"

      change_draft(view, ["transfer", "from_stop_id"], :stops, %{"from_stop_id" => "CEN-A"})

      assert text_of(doc(view), "#transfer-from-stop-hint") == "Platform A at Central Station"
    end
  end

  describe "the scope and its selectors" do
    test "a route pair lists the routes serving the chosen stop", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      state = %{"from_stop_id" => "CEN"}

      change_draft(view, ["transfer", "from_stop_id"], :stops, state)
      change_draft(view, ["scope"], :routes, state)

      document = doc(view)

      # The station's coverage: routes 12, 24 and 6 serve CEN, CEN-A and CEN-C;
      # the inactive route 99 is not offered.
      assert has_element?(view, "#transfer-from-route")
      assert option_values(document, "#transfer-from-route option") == ["", "12", "24", "6"]

      assert option_labels(document, "#transfer-from-route option") == [
               "Choose route",
               "12 · Riverside",
               "24 · Harbor",
               "6 · Museum"
             ]

      # The shared select renders its label as a span beside the control.
      assert render(view) =~ "Arriving route</span>"
      assert render(view) =~ "Departing route</span>"
    end

    test "a specific-trip scope lists the route's own trips with their details", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      state = %{"from_stop_id" => "CEN-A"}

      change_draft(view, ["scope"], :custom, state)
      refute has_element?(view, "#transfer-from-trip")

      state = Map.put(state, "from_route_id", "12")
      change_draft(view, ["transfer", "from_route_id"], :custom, state)

      document = doc(view)

      assert has_element?(view, "#transfer-from-trip")
      assert render(view) =~ "Arriving route (optional)</span>"

      # Only the trips of route 12 that serve CEN-A, labelled by the time they
      # serve it, their headsign and their service (AC-XFER-029).
      assert option_labels(document, "#transfer-from-trip option") == [
               "Any trip",
               "08:15 · Harbor · WKDY"
             ]
    end

    test "a changed scope, stop or route clears the selectors answered for the old one", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      state = %{"from_stop_id" => "CEN-A", "to_stop_id" => "CEN-C"}
      change_draft(view, ["scope"], :custom, state)

      state =
        Enum.reduce(
          [
            {"from_route_id", "12"},
            {"to_route_id", "24"},
            {"from_trip_id", "12-0815"},
            {"to_trip_id", "24-0840"}
          ],
          state,
          fn {field, value}, state ->
            # Each choice is one form event carrying the draft so far, as the
            # browser sends it.
            state = Map.put(state, field, value)
            change_draft(view, ["transfer", field], :custom, state)
            state
          end
        )

      document = doc(view)

      assert text_of(document, "#transfer-draft-preview") =~ "Trip 12-0815"
      assert text_of(document, "#transfer-draft-preview") =~ "Trip 24-0840"

      # A changed route clears that side's trip and keeps the route.
      state = state |> Map.put("from_route_id", "6") |> Map.put("from_trip_id", "")
      change_draft(view, ["transfer", "from_route_id"], :custom, state)

      document = doc(view)

      assert text_of(document, "#transfer-draft-preview") =~ "Route 6"
      refute text_of(document, "#transfer-draft-preview") =~ "Trip 12-0815"
      # A nil selector value leaves `options_for_select/2` with nothing to mark, so
      # the empty option carries no `selected` attribute; it is still the select's
      # value because it comes first. The route that replaced the cleared trip is
      # the draft's own value.
      assert has_element?(view, "#transfer-from-trip option[value='']")
      assert has_element?(view, "#transfer-from-route option[value='6'][selected]")

      # A changed stop clears that side's route and trip.
      state =
        state
        |> Map.put("from_stop_id", "HBR")
        |> Map.put("from_route_id", "")
        |> Map.put("from_trip_id", "")

      change_draft(view, ["transfer", "from_stop_id"], :custom, state)

      document = doc(view)

      assert text_of(document, "#transfer-draft-preview") =~ "Any arriving route"
      assert option_values(document, "#transfer-from-route option") == ["", "12", "24"]

      # Harbor serves route 12, so one side can hold a route and a trip again
      # before the scope changes.
      state = state |> Map.put("from_route_id", "12") |> Map.put("from_trip_id", "12-0815")
      change_draft(view, ["transfer", "from_trip_id"], :custom, state)
      assert text_of(doc(view), "#transfer-draft-preview") =~ "Trip 12-0815"

      # A new scope drops all four: a route chosen under one question is not the
      # answer to the next.
      change_draft(view, ["scope"], :routes, state)

      document = doc(view)

      assert text_of(document, "#transfer-draft-preview") =~ "Any arriving route"
      assert text_of(document, "#transfer-draft-preview") =~ "Any departing route"
      refute text_of(document, "#transfer-draft-preview") =~ "Trip 12-0815"
      assert has_element?(view, "#transfer-from-route option[value='']")
      assert has_element?(view, "#transfer-to-route option[value='']")
      refute has_element?(view, "#transfer-from-trip")
    end
  end

  describe "the type field" do
    test "the minimum time belongs to type 2 alone", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      change_draft(view, ["transfer", "transfer_type"], :stops, %{"transfer_type" => "1"})

      refute has_element?(view, "#transfer-min-time")
      refute has_element?(view, "#transfer-min-time-readout")

      change_draft(view, ["transfer", "transfer_type"], :stops, %{"transfer_type" => "2"})

      assert has_element?(view, "#transfer-min-time")

      change_draft(view, ["transfer", "min_transfer_time"], :stops, %{
        "transfer_type" => "2",
        "min_transfer_time" => "150"
      })

      assert text_of(doc(view), "#transfer-min-time-readout") ==
               "2 min 30 sec · include the walk between the stops and a buffer for late buses."
    end
  end

  describe "saving" do
    test "a valid draft is created, flashed and selected", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      save_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "180"
      })

      assert [rule] = stored_transfers(ctx)

      assert rule.from_stop_id == "CEN-A"
      assert rule.to_stop_id == "CEN-C"
      assert rule.transfer_type == 2
      assert rule.min_transfer_time == 180
      assert rule.organization_id == ctx.organization.id
      assert rule.gtfs_version_id == ctx.version.id

      assert render(view) =~ "Transfer rule saved in #{ctx.version.name}."

      refute has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfers")
      assert has_element?(view, "#transfer-select-#{rule.id}[aria-current='true']")
      assert_patch(view, transfers_path(ctx.version, rule: rule.id))
    end

    test "a blank required field is an error after a refused save, not while the draft changes",
         ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      # Choosing the first stop is not a mistake about the second stop or the time.
      change_draft(view, ["transfer", "from_stop_id"], :stops, %{"from_stop_id" => "CEN-A"})

      refute has_element?(view, "#transfer-to-stop-error")
      refute has_element?(view, "#transfer-min-time-error")
      refute has_element?(view, "#transfer-error-summary")

      save_draft(view, :stops, %{"from_stop_id" => "CEN-A"})

      assert_push_event(view, "focus_form_error", %{form_id: "transfer-form"})

      assert has_element?(view, "#transfer-to-stop-error", "Choose a stop or station")
      assert has_element?(view, "#transfer-min-time-error", "Enter a whole number of seconds")
      refute has_element?(view, "#transfer-from-stop-error")

      # The summary lists each problem and links to the field it names.
      assert text_of(doc(view), "#transfer-error-summary strong") ==
               "Rule not saved. Fix these 2:"

      assert has_element?(
               view,
               "#transfer-error-summary a[href='#transfer_to_stop_id_text_input']",
               "Riders board at: Choose a stop or station"
             )

      assert has_element?(
               view,
               "#transfer-error-summary a[href='#transfer-min-time']",
               "Minimum time: Enter a whole number of seconds, zero or more."
             )

      # The stop group that is wrong says so, so the error focus can find it.
      assert has_element?(view, "#transfer-editor [role='group'][aria-invalid='true']")
    end

    test "a required route pair is refused before the server", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      state = %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "from_route_id" => "12"
      }

      change_draft(view, ["scope"], :routes, state)
      save_draft(view, :routes, state)

      document = doc(view)

      assert text_of(document, "#transfer-to-route-error") == "Choose a departing route"
      refute has_element?(view, "#transfer-from-route-error")
      assert stored_transfers(ctx) == []

      # The draft is still open with what was entered.
      assert has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfer-from-route option[value='12'][selected]")
      assert has_element?(view, "#transfer-to-route option[value='']")
      assert has_element?(view, "#transfer-dirty")
    end

    test "the server's reference errors return on the field and keep the draft", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      entered = %{
        "from_stop_id" => "CEN-E",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "180"
      }

      change_draft(view, ["transfer", "to_stop_id"], :stops, entered)
      save_draft(view, :stops, entered)

      assert text_of(doc(view), "#transfer-from-stop-error") ==
               "Choose a stop, platform or station"

      assert stored_transfers(ctx) == []

      # Every entered value survives the refusal: an entrance is not a stop a rule
      # may name, but it is still the value the draft holds.
      document = doc(view)

      assert has_element?(view, "#transfer_from_stop_id[value='CEN-E']")
      assert has_element?(view, "#transfer_to_stop_id[value='CEN-C']")
      assert has_element?(view, "#transfer-min-time[value='180']")
      assert has_element?(view, "#transfer-type-2[checked]")
      assert has_element?(view, "#transfer-dirty")
      assert text_of(document, "#transfer-to-stop-hint") == "Platform C at Central Station"

      # A trip whose route is right but which never stops at the chosen stop is
      # refused on the trip itself. A scope change drops every selector answered for
      # the previous scope, so the scope moves first and the route and trip after it,
      # as the browser drives it.
      entered = %{
        "from_stop_id" => "MKT",
        "to_stop_id" => "HBR",
        "transfer_type" => "0"
      }

      change_draft(view, ["scope"], :custom, entered)

      routed = Map.put(entered, "from_route_id", "6")
      change_draft(view, ["transfer", "from_route_id"], :custom, routed)

      trip_draft = Map.put(routed, "from_trip_id", "6-0815")
      change_draft(view, ["transfer", "from_trip_id"], :custom, trip_draft)
      save_draft(view, :custom, trip_draft)

      assert text_of(doc(view), "#transfer-from-trip-error") == "This trip doesn't stop here"
      assert stored_transfers(ctx) == []
      assert has_element?(view, "#transfer-from-trip option[value='6-0815'][selected]")
    end

    test "a crafted payload cannot name a tenant or a type this page does not create", ctx do
      other_organization = organization_fixture()

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      # A type 4 row is authored on Blocks: the changeset refuses it (R1).
      save_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "4"
      })

      assert has_element?(
               view,
               "#transfer-editor p",
               "Choose one of the four transfer types"
             )

      assert stored_transfers(ctx) == []

      # A tenant in the payload is not a field the changeset casts, so the rule
      # lands in the page's own version and in no other organization (R10).
      save_draft(view, :stops, %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "180",
        "organization_id" => other_organization.id,
        "gtfs_version_id" => other_organization.id,
        "id" => Ecto.UUID.generate()
      })

      assert [rule] = stored_transfers(ctx)
      assert rule.organization_id == ctx.organization.id
      assert rule.gtfs_version_id == ctx.version.id

      refute Repo.exists?(from t in Transfer, where: t.organization_id == ^other_organization.id)
    end
  end

  describe "duplicates and the busy server" do
    setup :verify_on_exit!

    test "a duplicate of a general rule names the rule to edit instead", ctx do
      rule!(ctx, %{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        transfer_type: 2,
        min_transfer_time: 240
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-create") |> render_click()

      draft = %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "240"
      }

      change_draft(view, ["transfer", "to_stop_id"], :stops, draft)
      save_draft(view, :stops, draft)

      document = doc(view)

      assert text_of(document, "#transfer-form-error") =~ "This connection already has a rule"

      assert text_of(document, "#transfer-form-error") =~
               "A rule already covers these stops and services. " <>
                 "Edit it instead of adding a second one."

      refute has_element?(view, "#transfer-view-in-seat-link")
      assert length(stored_transfers(ctx)) == 1

      # The draft is kept, so the operator corrects what they entered instead of
      # retyping it.
      assert has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfer-min-time[value='240']")
      assert has_element?(view, "#transfer-dirty")
    end

    test "a duplicate of an in-seat record points at the in-seat view", ctx do
      # A type 4/5 row always holds both trips, and the six-column key is what the
      # unique index compares, so the record and the draft name the same stops and
      # the same two trips.
      in_seat!(ctx, %{
        from_stop_id: "CEN",
        to_stop_id: "CEN",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 4
      })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      state = %{
        "from_stop_id" => "CEN",
        "to_stop_id" => "CEN",
        "transfer_type" => "2",
        "min_transfer_time" => "180"
      }

      change_draft(view, ["scope"], :custom, state)

      draft = Map.put(state, "from_trip_id", "12-0815") |> Map.put("to_trip_id", "24-0840")
      change_draft(view, ["transfer", "from_trip_id"], :custom, draft)
      save_draft(view, :custom, draft)

      document = doc(view)

      assert text_of(document, "#transfer-form-error") =~
               "A stay-on-board record already uses these trips"

      assert text_of(document, "#transfer-form-error") =~
               "Stay-on-board records are set in Blocks, and a transfer rule can’t repeat one of them."

      assert attribute(document, "#transfer-view-in-seat-link", "href") ==
               transfers_path(ctx.version, view: "in_seat")

      assert length(stored_transfers(ctx)) == 1
      assert has_element?(view, "#transfer-min-time[value='180']")
    end

    test "three serialization failures keep the draft and offer the retry", ctx do
      Application.put_env(
        :gtfs_planner,
        :reviewed_apply_transaction,
        ReviewedApplyTransactionMock
      )

      expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
        raise Postgrex.Error.exception(
                postgres: %{code: "40001", severity: "ERROR", message: "serialization failure"}
              )
      end)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))
      view |> element("#transfers-first-use-create") |> render_click()

      draft = %{
        "from_stop_id" => "CEN-A",
        "to_stop_id" => "CEN-C",
        "transfer_type" => "2",
        "min_transfer_time" => "180"
      }

      save_draft(view, :stops, draft)

      document = doc(view)

      assert text_of(document, "#transfer-form-error") =~
               "The server didn’t respond. Nothing was changed and your entries are still here."

      assert has_element?(view, "#transfer-retry-save", "Retry saving")
      assert has_element?(view, "#transfer-save[phx-disable-with='Saving…']")
      assert stored_transfers(ctx) == []

      # The retry replays the draft the page still holds through the ordinary
      # adapter.
      Application.put_env(
        :gtfs_planner,
        :reviewed_apply_transaction,
        ReviewedApplyTransaction.Sandbox
      )

      view |> element("#transfer-retry-save") |> render_click()

      assert [rule] = stored_transfers(ctx)
      assert rule.from_stop_id == "CEN-A"
      assert rule.min_transfer_time == 180
      refute has_element?(view, "#transfer-editor")
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

  defp option_values(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> List.first() || ""))
  end

  defp transfers_path(version, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{version.id}/transfers#{query}"
  end

  defp rule!(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  # The test database can hold rows this case did not create, so every stored-row
  # assertion reads only this case's organization and version.
  defp stored_transfers(ctx) do
    Repo.all(
      from(t in Transfer,
        where: t.organization_id == ^ctx.organization.id and t.gtfs_version_id == ^ctx.version.id
      )
    )
  end

  defp in_seat!(ctx, attrs), do: rule!(ctx, Map.put_new(attrs, :transfer_type, 4))

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attribute(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end
end

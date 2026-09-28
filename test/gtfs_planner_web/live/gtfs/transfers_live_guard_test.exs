defmodule GtfsPlannerWeb.Gtfs.TransfersLiveGuardTest do
  @moduledoc """
  Merge evidence (EV-23) for the unsaved-draft guard.

  A draft the operator typed is the only copy of it, so every way out of the
  editor asks before it is lost: Cancel and Back, "Open existing rule", a link
  departure the `DraftGuard` hook intercepted, and a version switch. The editor
  container carries the hook with the transfer page's own depart event and
  discard message, and a clean draft — or no draft at all — leaves without a
  question so the ordinary paths keep their behavior.

  The dialog is the shared destructive confirmation: "Discard unsaved changes?"
  with "Keep editing" as the safe action and "Discard changes" naming what is
  lost. The client half is the hook's click interception; the path it sends is
  accepted only when it starts with `/` and not `//` (R10), and the browser
  journey that drives a real header link is the `guard:` journey in
  `assets/e2e/transfers.spec.js` (step 30).

  The focused command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner_web/live/gtfs/transfers_live_guard_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

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

  describe "the editor's departure guard" do
    test "the editor carries the hook, the depart event and the discard message", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      document = doc(view)

      assert attribute(document, "#transfer-editor", "phx-hook") == "DraftGuard"
      assert attribute(document, "#transfer-editor", "data-depart-event") == "transfer_depart"

      assert attribute(document, "#transfer-editor", "data-discard-message") ==
               "Discard unsaved transfer changes? Cancel to keep editing."

      assert attribute(document, "#transfer-editor", "data-dirty") == "false"

      # The hook spreads the form-error focus, so the draft still focuses its
      # first invalid field without a second hook on the same element.
      assert attribute(document, "#transfer-editor", "data-focus-on-mount") ==
               "transfer-editor-title"

      assert has_element?(view, "#transfer-discard-dialog[data-open='false']")

      change_draft(view, ["transfer", "min_transfer_time"], :stops, %{
        "min_transfer_time" => "120"
      })

      assert attribute(doc(view), "#transfer-editor", "data-dirty") == "true"
    end

    test "a clean draft leaves without a question", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()
      view |> element("#transfer-cancel") |> render_click()

      refute has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfer-discard-dialog[data-open='false']")
      assert has_element?(view, "#transfers-create")
    end

    test "a dirty draft is asked about before Cancel, and kept by Keep editing", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      change_draft(view, ["transfer", "min_transfer_time"], :stops, %{
        "min_transfer_time" => "120"
      })

      view |> element("#transfer-back") |> render_click()

      document = doc(view)

      assert has_element?(view, "#transfer-discard-dialog[data-open='true']")
      assert text_of(document, "#transfer-discard-dialog-title") == "Discard unsaved changes?"

      assert text_of(document, "#transfer-discard-dialog-body") =~
               "Your saved transfer will stay as it was. The changes in this form will be lost."

      assert has_element?(view, "#transfer-discard-dialog-cancel", "Keep editing")
      assert has_element?(view, "#transfer-discard-dialog-confirm", "Discard changes")

      view |> element("#transfer-discard-dialog-cancel") |> render_click()

      # The draft is exactly where it was: same editor, same entered time.
      assert has_element?(view, "#transfer-discard-dialog[data-open='false']")
      assert has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfer-min-time[value='120']")
      assert has_element?(view, "#transfer-dirty")

      view |> element("#transfer-cancel") |> render_click()
      view |> element("#transfer-discard-dialog-confirm") |> render_click()

      refute has_element?(view, "#transfer-editor")
      assert has_element?(view, "#transfers")
    end

    test "a link departure asks the same question and then navigates", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      change_draft(view, ["transfer", "min_transfer_time"], :stops, %{
        "min_transfer_time" => "120"
      })

      path = "/gtfs/#{ctx.version.id}/routes"

      render_hook(view, "transfer_depart", %{"path" => path})

      assert has_element?(view, "#transfer-discard-dialog[data-open='true']")

      view |> element("#transfer-discard-dialog-confirm") |> render_click()

      assert_redirect(view, path)
    end

    test "a departure path this page did not author is refused", ctx do
      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      change_draft(view, ["transfer", "min_transfer_time"], :stops, %{
        "min_transfer_time" => "120"
      })

      for path <- ["//evil.example", "https://evil.example", "routes"] do
        render_hook(view, "transfer_depart", %{"path" => path})

        assert has_element?(view, "#transfer-discard-dialog[data-open='false']")
        assert has_element?(view, "#transfer-editor")
      end

      # A refused path leaves the departure for the operator to ask for again.
      render_hook(view, "transfer_depart", %{"path" => "/gtfs/#{ctx.version.id}/routes"})

      assert has_element?(view, "#transfer-discard-dialog[data-open='true']")
    end

    test "a version switch asks before it navigates", ctx do
      other = gtfs_version_fixture(ctx.organization.id)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      change_draft(view, ["transfer", "min_transfer_time"], :stops, %{
        "min_transfer_time" => "120"
      })

      render_hook(view, "switch_gtfs_version", %{"version" => other.id})

      assert has_element?(view, "#transfer-discard-dialog[data-open='true']")

      view |> element("#transfer-discard-dialog-confirm") |> render_click()

      assert_redirect(view, "/gtfs/#{other.id}/transfers")
    end

    test "discarding a colliding draft opens the rule that holds the key", ctx do
      collision =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          transfer_type: 2,
          min_transfer_time: 240
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> element("#transfers-create") |> render_click()

      draft = %{"from_stop_id" => "CEN-A", "to_stop_id" => "CEN-C", "min_transfer_time" => "240"}

      change_draft(view, ["transfer", "to_stop_id"], :stops, draft)
      save_draft(view, :stops, draft)

      assert text_of(doc(view), "#transfer-form-error") =~
               "A rule already exists for these stops and services."

      view |> element("#transfer-open-existing") |> render_click()

      assert has_element?(view, "#transfer-discard-dialog[data-open='true']")

      view |> element("#transfer-discard-dialog-confirm") |> render_click()

      assert_patch(view, transfers_path(ctx.version, rule: collision.id))
      assert text_of(doc(view), "#transfer-editor h2") == "Edit transfer"
      assert has_element?(view, "#transfer-min-time[value='240']")
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

  defp transfers_path(version, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{version.id}/transfers#{query}"
  end

  defp rule!(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attribute(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end
end

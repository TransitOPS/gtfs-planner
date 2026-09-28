defmodule GtfsPlannerWeb.Gtfs.TransfersLiveDeleteTest do
  @moduledoc """
  Merge evidence (EV-24) for deleting transfer rules from the Transfers page.

  The general view lists one checkbox per rule and select-all for the shown page,
  and the count bar says how many rules are checked and offers "Delete selected";
  the inspector's own Delete confirms the rule it shows. Confirming sends the exact
  `{id, updated_at}` pairs of the rules the click captured, so a filter, a search,
  a sort, a page or a view change — each of which clears the checked set — never
  defines the delete scope, and an id the shown page does not hold (an in-seat
  record's, a foreign one, another page's) checks nothing, because the server
  resolves every id against the page it rendered (R8, CR-5, CR-1).

  The refusals are the delete facades' own: a rule that changed after it was
  checked, one that was already removed, and a busy server each keep the dialog
  open with the reason and delete nothing, so a failed deletion cannot close over
  rows the operator never confirmed. Every case asserts stored rows, literal copy
  and the patched URL against the shared fixture network; the browser's own
  checkbox interaction is the `delete:` journey in `assets/e2e/transfers.spec.js`
  (step 30) and the captures in `evidence/step-025/`.

  The busy case swaps `:reviewed_apply_transaction` for the mock, so the file runs
  one case at a time and restores the previous adapter afterwards. The focused
  command is deferred to branch review:
  `MIX_TEST_PARTITION=_xfer15 mix test test/gtfs_planner_web/live/gtfs/transfers_live_delete_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.TransfersFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

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
      version: version,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: user.id,
        actor_email: user.email
      }
    }
  end

  describe "the select column and the count bar" do
    test "each shown rule carries its own checkbox beside the count's selection", ctx do
      %{scoped: scoped, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(view, "#transfer-check-#{scoped.id}")
      assert has_element?(view, "#transfer-check-#{plain.id}")

      # The label names the connection the checkbox selects, not the rule id.
      assert attribute(doc(view), "#transfer-check-#{plain.id}", "aria-label") ==
               "Select Market Street to Harbor"

      assert text_of(doc(view), "#transfers-count") == "3 rules"
      refute has_element?(view, "#transfers-select-all")
      refute has_element?(view, "#transfers-delete-selected")
      assert has_element?(view, "#transfers-direction-hint", "One direction per rule")

      # Checking is the count bar's own live region: it says what the operator's
      # next decision is about, and the selection's controls appear with it.
      view |> check_row(scoped.id)
      view |> check_row(plain.id)

      assert attribute(doc(view), "#transfer-check-#{scoped.id}", "checked") != nil
      assert attribute(doc(view), "#transfer-check-#{plain.id}", "checked") != nil
      assert text_of(doc(view), "#transfers-count") == "2 selected · this version"
      assert has_element?(view, "#transfers-select-all")
      assert text_of(doc(view), "label:has(#transfers-select-all)") == "Select all shown"
      assert attribute(doc(view), "#transfers-select-all", "checked") == nil
      assert has_element?(view, "#transfers-delete-selected", "Delete selected")
      refute has_element?(view, "#transfers-direction-hint")

      # Unchecking one rule returns the count bar to the list count.
      view |> check_row(plain.id)

      assert attribute(doc(view), "#transfer-check-#{plain.id}", "checked") == nil
      assert text_of(doc(view), "#transfers-count") == "1 selected · this version"
    end

    test "select all checks every rule the page shows and clears them again", ctx do
      %{scoped: scoped, at_end: at_end, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      # The bar's select all appears with the first checked rule, as the reference
      # does, and the page it selects is the one the server rendered.
      refute has_element?(view, "#transfers-select-all")

      view |> check_row(scoped.id)
      view |> element("#transfers-select-all") |> render_click()

      for rule <- [scoped, at_end, plain] do
        assert attribute(doc(view), "#transfer-check-#{rule.id}", "checked") != nil
      end

      assert attribute(doc(view), "#transfers-select-all", "checked") != nil
      assert text_of(doc(view), "#transfers-count") == "3 selected · this version"

      view |> element("#transfers-select-all") |> render_click()

      for rule <- [scoped, at_end, plain] do
        assert attribute(doc(view), "#transfer-check-#{rule.id}", "checked") == nil
      end

      # An empty selection takes the controls away again and leaves the bar as a
      # fresh page reads it.
      refute has_element?(view, "#transfers-select-all")
      refute has_element?(view, "#transfers-delete-selected")
      assert text_of(doc(view), "#transfers-count") == "3 rules"
      assert has_element?(view, "#transfers-direction-hint", "One direction per rule")
    end
  end

  describe "the delete dialog" do
    test "it names the checked rules, the version and the consequence", ctx do
      %{scoped: scoped, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> check_row(scoped.id)
      view |> check_row(plain.id)
      view |> element("#transfers-delete-selected") |> render_click()

      assert has_element?(view, "#transfer-delete-dialog")

      assert text_of(doc(view), "#transfer-delete-dialog-title") ==
               "Delete 2 transfer rules?"

      assert text_of(doc(view), "#transfer-delete-row-#{scoped.id}") =~
               "Central · Bay A → Central · Bay C"

      assert text_of(doc(view), "#transfer-delete-row-#{scoped.id}") =~
               "Route 12 → Route 24 · Minimum time"

      assert text_of(doc(view), "#transfer-delete-row-#{plain.id}") =~
               "Market Street → Harbor"

      assert text_of(doc(view), "#transfer-delete-row-#{plain.id}") =~
               "All arriving routes → All departing routes · Recommended"

      body = text_of(doc(view), "#transfer-delete-dialog-body")

      assert body =~ "These exact rules will be removed from #{ctx.version.name}"
      assert body =~ "Stops, routes, and rules outside this selection stay unchanged."
      assert body =~ "In-seat records are excluded. This cannot be undone."
      assert text_of(doc(view), "#transfer-delete-dialog-confirm") == "Delete 2 rules"
      refute has_element?(view, "#transfer-delete-error")

      # Cancelling closes the dialog and keeps every rule.
      view |> element("#transfer-delete-dialog-cancel") |> render_click()

      refute has_element?(view, "#transfer-delete-dialog")
      assert Repo.aggregate(Transfer, :count) == 3
      assert text_of(doc(view), "#transfers-count") == "2 selected · this version"
    end

    test "it deletes the checked rules only, and reloads the filtered list", ctx do
      %{scoped: scoped, at_end: at_end, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} =
        live(ctx.conn, transfers_path(ctx.version, stop: "CEN-A"))

      assert row_ids(doc(view)) |> Enum.sort() ==
               Enum.sort(["transfers-#{scoped.id}", "transfers-#{at_end.id}"])

      view |> check_row(scoped.id)
      view |> check_row(at_end.id)
      view |> element("#transfers-delete-selected") |> render_click()
      view |> element("#transfer-delete-dialog-confirm") |> render_click()

      assert has_element?(view, "#flash-info", "2 transfer rules deleted.")
      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?stop=CEN-A")
      refute has_element?(view, "#transfer-delete-dialog")
      refute has_element?(view, "#transfers-delete-selected")
      assert text_of(doc(view), "#transfers-count") == "0 rules"
      assert has_element?(view, "#transfers-no-results")

      assert Repo.get(Transfer, scoped.id) == nil
      assert Repo.get(Transfer, at_end.id) == nil
      assert Repo.get(Transfer, plain.id) != nil

      # The rule the filter hid is still there, in the unfiltered list.
      {:ok, list, _html} = live(ctx.conn, transfers_path(ctx.version))

      assert has_element?(list, "tr#transfers-#{plain.id}")
      refute has_element?(list, "tr#transfers-#{scoped.id}")
    end

    test "the inspector's Delete confirms the rule it shows", ctx do
      %{scoped: scoped, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, rule: scoped.id))

      view |> element("#transfer-select-#{scoped.id}") |> render_click()
      view |> element("#transfer-inspector-delete") |> render_click()

      assert has_element?(view, "#transfer-delete-dialog")

      assert text_of(doc(view), "#transfer-delete-dialog-title") ==
               "Delete 1 transfer rule?"

      assert text_of(doc(view), "#transfer-delete-dialog-confirm") == "Delete 1 rule"
      assert has_element?(view, "#transfer-delete-row-#{scoped.id}")

      view |> element("#transfer-delete-dialog-confirm") |> render_click()

      assert has_element?(view, "#flash-info", "1 transfer rule deleted.")
      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers")
      assert Repo.get(Transfer, scoped.id) == nil
      assert Repo.get(Transfer, plain.id) != nil

      # The list reloads without a selected rule and keeps the rows it still has.
      refute has_element?(view, "#transfer-delete-dialog")
      assert has_element?(view, "tr#transfers-#{plain.id}")
      refute has_element?(view, "tr#transfers-#{scoped.id}")
    end

    test "the in-seat view has no selection and no delete", ctx do
      general = rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})

      record =
        in_seat!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_trip_id: "12-0815",
          to_trip_id: "24-0840",
          transfer_type: 4
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, view: "in_seat"))

      refute has_element?(view, "#transfers-select-all")
      refute has_element?(view, "#transfers-delete-selected")
      refute has_element?(view, "#transfer-check-#{record.id}")
      refute has_element?(view, "#transfer-inspector-delete")
      assert has_element?(view, "#transfers-direction-hint", "One direction per rule")

      # A crafted check of the in-seat record's id, and of a general rule the view
      # does not list, changes nothing here.
      view |> render_click("toggle_check", %{"id" => record.id})
      view |> render_click("toggle_check", %{"id" => general.id})

      refute has_element?(view, "#transfers-delete-selected")
      refute has_element?(view, "#transfer-delete-dialog")
      assert text_of(doc(view), "#transfers-count") == "1 in-seat record"
    end
  end

  describe "refusals" do
    test "a rule that changed after it was checked keeps the dialog open", ctx do
      %{scoped: scoped, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> check_row(scoped.id)
      view |> check_row(plain.id)

      # The rule is edited through the facade after the click captured its pair.
      assert {:ok, _updated} =
               Gtfs.update_general_transfer(
                 scoped.id,
                 %{"min_transfer_time" => "240"},
                 scoped.updated_at,
                 ctx.audit
               )

      view |> element("#transfers-delete-selected") |> render_click()
      view |> element("#transfer-delete-dialog-confirm") |> render_click()

      assert has_element?(view, "#transfer-delete-dialog")

      error = text_of(doc(view), "#transfer-delete-error")

      assert error =~ "Nothing was deleted."

      assert error =~
               "One or more rules changed since you selected them. Close this dialog to see the latest rules."

      refute has_element?(view, "#flash-info")
      assert Repo.get(Transfer, scoped.id) != nil
      assert Repo.get(Transfer, plain.id) != nil

      # Closing the dialog shows the list again, with the edited rule in it.
      view |> element("#transfer-delete-dialog-cancel") |> render_click()

      refute has_element?(view, "#transfer-delete-dialog")
      assert has_element?(view, "tr#transfers-#{scoped.id}")
    end

    test "a rule removed after it was checked says it is gone", ctx do
      %{scoped: scoped, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> check_row(scoped.id)
      view |> check_row(plain.id)

      # The rule leaves through the facade between the click and the confirm.
      assert {:ok, _deleted} =
               Gtfs.delete_general_transfer(plain.id, plain.updated_at, ctx.audit)

      view |> element("#transfers-delete-selected") |> render_click()
      view |> element("#transfer-delete-dialog-confirm") |> render_click()

      assert has_element?(view, "#transfer-delete-dialog")

      error = text_of(doc(view), "#transfer-delete-error")

      assert error =~ "Nothing was deleted."
      assert error =~ "One or more rules were already removed or can't be deleted here."

      refute has_element?(view, "#flash-info")
      assert Repo.get(Transfer, scoped.id) != nil
    end

    test "a busy server keeps the dialog open with the retry message", ctx do
      scoped =
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        })

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

      view |> check_row(scoped.id)
      view |> element("#transfers-delete-selected") |> render_click()
      view |> element("#transfer-delete-dialog-confirm") |> render_click()

      assert has_element?(view, "#transfer-delete-dialog")

      error = text_of(doc(view), "#transfer-delete-error")

      assert error =~ "Nothing was deleted."
      assert error =~ "The server was busy. Try again."

      refute has_element?(view, "#flash-info")
      assert Repo.get(Transfer, scoped.id) != nil

      # A retry through the ordinary adapter deletes the rule the dialog still
      # holds, so the failure did not lose the operator's selection.
      Application.put_env(
        :gtfs_planner,
        :reviewed_apply_transaction,
        ReviewedApplyTransaction.Sandbox
      )

      view |> element("#transfer-delete-dialog-confirm") |> render_click()

      assert has_element?(view, "#flash-info", "1 transfer rule deleted.")
      assert Repo.get(Transfer, scoped.id) == nil
    end
  end

  describe "the delete scope" do
    test "a filter, a search, a sort and a view change clear the checked rules", ctx do
      %{scoped: scoped, plain: plain} = three_rules!(ctx)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      view |> check_row(scoped.id)

      # The rule stays listed through every change below, so an unchecked box and
      # a list count are what "cleared" has to mean.
      view |> form("#transfer-filter-form", %{"route" => "12"}) |> render_change()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?route=12")
      assert attribute(doc(view), "#transfer-check-#{scoped.id}", "checked") == nil
      refute has_element?(view, "#transfers-delete-selected")
      assert text_of(doc(view), "#transfers-count") == "1 rule"

      view |> check_row(scoped.id)
      view |> form("#transfer-search-form", %{"q" => "central"}) |> render_change()

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?q=central&route=12")
      assert attribute(doc(view), "#transfer-check-#{scoped.id}", "checked") == nil
      refute has_element?(view, "#transfers-delete-selected")

      view |> check_row(scoped.id)
      view |> render_click("sort", %{"key" => "to"})

      assert attribute(doc(view), "#transfer-check-#{scoped.id}", "checked") == nil
      refute has_element?(view, "#transfers-delete-selected")

      view |> check_row(scoped.id)
      view |> element("#transfers-view-in-seat") |> render_click()

      refute has_element?(view, "#transfers-delete-selected")
      refute has_element?(view, "#transfer-check-#{scoped.id}")

      view |> element("#transfers-view-general") |> render_click()

      assert attribute(doc(view), "#transfer-check-#{scoped.id}", "checked") == nil
      assert attribute(doc(view), "#transfer-check-#{plain.id}", "checked") == nil
      assert text_of(doc(view), "#transfers-count") == "3 rules"
    end

    test "moving to another page clears the checked rules", ctx do
      rules = many_rules(ctx, 51)

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version))

      # The count bar names the version's whole list, not the page's slice of it:
      # "Select all shown" and the pagination beside it carry the page's extent.
      assert text_of(doc(view), "#transfers-count") == "51 rules"

      first = hd(row_ids(doc(view))) |> String.replace_prefix("transfers-", "")

      view |> check_row(first)
      assert text_of(doc(view), "#transfers-count") == "1 selected · this version"

      view |> render_click("paginate", %{"page" => "2"})

      assert_patched(view, ~p"/gtfs/#{ctx.version.id}/transfers?page=2")
      refute has_element?(view, "#transfers-delete-selected")
      # The checked rules are gone, so the count bar is back to the whole list.
      assert text_of(doc(view), "#transfers-count") == "51 rules"
      assert length(rules) == 51
    end

    test "crafted events cannot widen the scope beyond the shown page", ctx do
      %{scoped: scoped, at_end: at_end, plain: plain} = three_rules!(ctx)

      record =
        in_seat!(ctx, %{
          from_stop_id: "CEN",
          to_stop_id: "CEN",
          from_trip_id: "12-0815",
          to_trip_id: "24-0840",
          transfer_type: 4
        })

      {:ok, view, _html} = live(ctx.conn, transfers_path(ctx.version, stop: "CEN-A"))

      # An in-seat record's id, an unknown id, and a general rule the filter hides
      # are all outside the page the server rendered.
      view |> render_click("toggle_check", %{"id" => record.id})
      refute has_element?(view, "#transfers-delete-selected")

      view |> render_click("toggle_check", %{"id" => Ecto.UUID.generate()})
      refute has_element?(view, "#transfers-delete-selected")

      view |> render_click("toggle_check", %{"id" => plain.id})
      refute has_element?(view, "#transfers-delete-selected")

      view |> render_click("toggle_check", %{"id" => "not-a-uuid"})
      refute has_element?(view, "#transfers-delete-selected")

      view |> render_click("toggle_check", %{"id" => scoped.id})
      assert has_element?(view, "#transfers-delete-selected")
      assert text_of(doc(view), "#transfers-count") == "1 selected · this version"

      # A confirm with no dialog behind it deletes nothing and says nothing.
      view |> render_click("apply_delete", %{})

      refute has_element?(view, "#transfer-delete-dialog")
      refute has_element?(view, "#flash-info")
      assert Repo.aggregate(Transfer, :count) == 4
      assert Repo.get(Transfer, plain.id) != nil
      assert Repo.get(Transfer, scoped.id) != nil
      assert Repo.get(Transfer, at_end.id) != nil
    end
  end

  # Three general rules: a route-scoped minimum-time rule at a station platform, a
  # second rule that shares the platform stop, and a stop pair the CEN-A filter
  # hides. A search for a station name finds the first two.
  defp three_rules!(ctx) do
    %{
      scoped:
        rule!(ctx, %{
          from_stop_id: "CEN-A",
          to_stop_id: "CEN-C",
          from_route_id: "12",
          to_route_id: "24",
          transfer_type: 2,
          min_transfer_time: 180
        }),
      at_end: rule!(ctx, %{from_stop_id: "CEN-A", to_stop_id: "MUS", transfer_type: 0}),
      plain: rule!(ctx, %{from_stop_id: "MKT", to_stop_id: "HBR", transfer_type: 0})
    }
  end

  # 51 rules need 51 distinct keys, because the six-field key is unique per
  # version; the fixture network's eight stops supply more ordered pairs than the
  # two pages need.
  defp many_rules(ctx, count) do
    stops = ~w(CEN-A CEN-C CEN-E CEN MKT HBR MUS NOC)

    pairs = for from <- stops, to <- stops, from != to, do: {from, to}

    pairs
    |> Enum.take(count)
    |> Enum.map(fn {from, to} ->
      rule!(ctx, %{from_stop_id: from, to_stop_id: to, transfer_type: 0})
    end)
  end

  defp rule!(ctx, attrs), do: transfer_fixture(ctx.organization.id, ctx.version.id, attrs)
  defp in_seat!(ctx, attrs), do: rule!(ctx, Map.put_new(attrs, :transfer_type, 4))

  defp check_row(view, id), do: view |> element("#transfer-check-#{id}") |> render_click()

  defp transfers_path(version, params \\ []) do
    query = if params == [], do: "", else: "?" <> URI.encode_query(params)
    "/gtfs/#{version.id}/transfers#{query}"
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp attribute(document, selector, name) do
    document |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp row_ids(document) do
    document
    |> LazyHTML.query("tbody#transfers tr")
    |> Enum.map(fn row -> row |> LazyHTML.attribute("id") |> List.first() end)
  end
end

defmodule GtfsPlannerWeb.Gtfs.FareEditorHelperTest do
  @moduledoc """
  Merge evidence (EV-15) for the managed Prices tab's helper: the panel, the
  native price review opened from a prepared entry and the confirmed save.

  The page, the conversation session and the turn task are separate processes, so
  the SQL sandbox and the `Req.Test` plug are shared (`async: false`) and only the
  OpenRouter HTTP boundary is scripted. The version enters rows the way a user's
  version does (the production importer of `north_coast_v2` and the production
  conversion), and every expected price is a literal from that fixture.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures

  import GtfsPlanner.Agents.PackTurn,
    only: [expect_reply: 1, setup_conversations: 0, text_reply: 1, tool_calls_reply: 1]

  import GtfsPlanner.FaresFixtures, only: [import!: 3, managed!: 3]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareVersionSetting
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.FareEditorComponents

  @prepare_arguments Jason.encode!(%{
                       "currency" => "USD",
                       "changes" => [
                         %{
                           "fare_product_id" => "local_ride_adult_cash",
                           "rider_category_id" => "adult",
                           "fare_media_id" => "cash",
                           "amount" => "1.75"
                         },
                         %{
                           "fare_product_id" => "local_ride_reduced_cash",
                           "rider_category_id" => "reduced",
                           "fare_media_id" => "cash",
                           "amount" => "0.85"
                         },
                         %{
                           "fare_product_id" => "local_ride_youth_cash",
                           "rider_category_id" => "youth",
                           "fare_media_id" => "cash",
                           "amount" => "1.00"
                         }
                       ]
                     })

  @unavailable_notice "That prepared change is no longer available. Ask the helper again."
  @close_first_notice "Close the open drawer or dialog first."
  @unsaved_notice "Save or discard your unsaved prices before reviewing the helper's prices."
  @changed_notice "Prices changed after the helper prepared this. Ask the helper again."
  @unmanaged_notice "This version's fares are not edited here yet."
  @stale_error "1 price changed since this review. Nothing was saved. Ask the helper again."
  @save_failed "Prices couldn't be saved. Nothing changed."

  setup {Req.Test, :verify_on_exit!}

  setup do
    setup_conversations()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Helper Prices Version"})
    scope = managed!(organization, version, user)

    %{
      organization: organization,
      user: user,
      membership: membership,
      version: version,
      scope: scope
    }
  end

  describe "the panel" do
    test "Open helper renders the panel with the fare price intro, and the grid still works",
         context do
      {:ok, view, _html} = open(context, context.version)

      assert has_element?(view, "#agent-helper-open", "Open helper")
      refute has_element?(view, "#agent-panel")

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#agent-helper-open[aria-expanded=true]")
      assert has_element?(view, "#agent-panel", "Fare price helper")
      assert has_element?(view, "#agent-panel", "I can list this version's fare prices")
      assert has_element?(view, "#agent-example-1", "Raise the Local ride adult and reduced cash")
      assert_push_event(view, "agent:focus", %{id: "agent-composer-input"})

      view
      |> element("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1.75"}})

      assert has_element?(view, "#fare-table-form")
      assert has_element?(view, "#create-fare")
    end

    test "the button is absent where the helper cannot work", context do
      for path <- ["/where", "/transfers", "/checks"] do
        {:ok, view, _html} = open_path(context, context.version, path)
        refute has_element?(view, "#agent-helper-open"), "tab #{path}"
      end

      # While loading: the static render has not loaded the workspace.
      static =
        build_conn()
        |> log_in(context)
        |> get("/gtfs/#{context.version.id}/settings/fares")

      refute html_response(static, 200) =~ "agent-helper-open"

      # An unmanaged version shows the read-only view and its conversion prompt.
      unmanaged = gtfs_version_fixture(context.organization.id, %{name: "Unmanaged Prices"})
      import!(context.organization, unmanaged, "north_coast_v1")
      {:ok, view, _html} = open(context, unmanaged)

      assert has_element?(view, "#unmanaged-fares")
      refute has_element?(view, "#agent-helper-open")

      # A version with no fares is in the first-use setup.
      blank = gtfs_version_fixture(context.organization.id, %{name: "Blank Prices"})
      import!(context.organization, blank, "no_fare")
      {:ok, view, _html} = open(context, blank)

      assert has_element?(view, "#fare-setup")
      refute has_element?(view, "#agent-helper-open")
    end

    test "a panel left open does not follow the editor to another tab", context do
      {:ok, view, _html} = open(context, context.version)
      view |> element("#agent-helper-open") |> render_click()
      assert has_element?(view, "#agent-panel")

      {:ok, view, _html} = open_path(context, context.version, "/where")
      refute has_element?(view, "#agent-panel")
    end
  end

  describe "the handoff into the price review" do
    test "a prepared turn writes nothing, and Review opens the exact before and after",
         context do
      before = prices(context)
      {view, _pid} = prepared_view(context)

      assert has_element?(view, "#agent-review-prepared-2", "Review prices")
      refute has_element?(view, "#price-review-dialog")
      assert prices(context) == before

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#price-review-dialog")
      assert has_element?(view, "#price-review-badge", "Review · not saved")
      assert text_of(view, "#price-review-count") =~ "2"
      assert text_of(view, "#price-review-largest") =~ "+$0.25"
      assert text_of(view, "#price-review-fares") =~ "1"

      adult = text_of(view, "#price-review-row-local_ride_adult_cash-adult-cash")
      assert adult =~ "Local ride"
      assert adult =~ "$1.50"
      assert adult =~ "$1.75"

      reduced = text_of(view, "#price-review-row-local_ride_reduced_cash-reduced-cash")
      assert reduced =~ "$0.75"
      assert reduced =~ "$0.85"

      unchanged = text_of(view, "#price-review-unchanged")
      assert unchanged =~ "1 price is already at the amount you gave"
      assert unchanged =~ "Youth (6-18)"
      assert unchanged =~ "$1.00"

      assert has_element?(view, "#price-review-dialog-confirm", "Save 2 prices")
      refute has_element?(view, "#price-review-dialog-confirm[disabled]")
      assert prices(context) == before

      assert %{origin: %{entry_id: 2, return_focus_id: "agent-prepared-2"}} =
               assigns(view).price_review
    end

    test "Keep prices closes the review and writes nothing", context do
      before = prices(context)
      {view, _pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#price-review-dialog-cancel") |> render_click()

      refute has_element?(view, "#price-review-dialog")
      assert prices(context) == before
    end

    test "an unsaved grid edit is kept and nothing opens", context do
      {view, _pid} = prepared_view(context)

      view
      |> element("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1.80"}})

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @unsaved_notice)
      refute has_element?(view, "#price-review-dialog")
      assert %{"local_ride_adult_cash|adult|cash" => _edit} = assigns(view).price_edits
    end

    test "an open Change prices dialog or fare drawer is never replaced", context do
      {view, _pid} = prepared_view(context)

      view |> element("#change-prices") |> render_click()
      assert has_element?(view, "#price-change-dialog")

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @close_first_notice)
      assert has_element?(view, "#price-change-dialog")
      refute has_element?(view, "#price-review-dialog")

      view |> element("#price-change-dialog-cancel") |> render_click()
      view |> element("#create-fare") |> render_click()
      assert assigns(view).fare_draft

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @close_first_notice)
      assert assigns(view).fare_draft
      refute has_element?(view, "#price-review-dialog")
    end

    test "a forged, unknown or reset entry opens nothing and changes nothing", context do
      {view, pid} = prepared_view(context)
      before = prices(context)
      assert has_element?(view, "#agent-review-prepared-2")

      for id <- ["abc", "999", "-1", "0", "2.5", ""] do
        render_click(view, "agent_review_prepared", %{"entry" => id})

        assert has_element?(view, "#agent-panel", @unavailable_notice), "entry #{inspect(id)}"
        refute has_element?(view, "#price-review-dialog")
      end

      view |> element("#agent-new-conversation") |> render_click()
      assert_receive {:agent_event, ^pid, {:reset, _conversation_id}}, 5_000
      render(view)

      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert has_element?(view, "#agent-panel", @unavailable_notice)
      refute has_element?(view, "#price-review-dialog")
      assert prices(context) == before
    end

    test "a price another editor changed after the preparation is a changed review", context do
      {view, _pid} = prepared_view(context)

      assert {:ok, _written} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "local_ride_adult_cash",
                   rider_category_id: "adult",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("1.50"),
                   amount: Decimal.new("1.60")
                 }
               ])

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @changed_notice)
      refute has_element?(view, "#price-review-dialog")
    end

    test "an unchanged cell that another editor moved is also a changed review", context do
      {view, _pid} = prepared_view(context)

      assert {:ok, _written} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "local_ride_youth_cash",
                   rider_category_id: "youth",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("1.00"),
                   amount: Decimal.new("1.10")
                 }
               ])

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#agent-panel", @changed_notice)
      refute has_element?(view, "#price-review-dialog")
    end

    test "a forced handoff on an unmanaged version is refused", context do
      unmanaged = gtfs_version_fixture(context.organization.id, %{name: "Unmanaged Prices"})
      import!(context.organization, unmanaged, "north_coast_v1")
      {:ok, view, _html} = open(context, unmanaged)

      refute has_element?(view, "#agent-helper-open")
      render_click(view, "agent_open", %{})
      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert assigns(view).agent_notice == @unmanaged_notice
      refute has_element?(view, "#price-review-dialog")
    end
  end

  describe "confirming the price review" do
    test "writes the two prepared prices, one change-log entry, the grid note and the receipt",
         context do
      before = prices(context)
      {view, pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#price-review-dialog-confirm") |> render_click()

      refute has_element?(view, "#price-review-dialog")

      after_save = prices(context)

      changed =
        for {key, amount} <- price_amounts(after_save),
            Decimal.compare(amount, Map.fetch!(price_amounts(before), key)) != :eq,
            do: {key, Decimal.to_string(amount)}

      assert Enum.sort(changed) == [
               {{"local_ride_adult_cash", "adult", "cash"}, "1.75"},
               {{"local_ride_reduced_cash", "reduced", "cash"}, "0.85"}
             ]

      assert length(after_save) == length(before)

      assert [log] = fare_logs(context)
      assert log.changed_fields["summary"] == "Changed 2 prices"
      assert log.actor_id == context.user.id
      assert log.actor_email == context.user.email

      assert text_of(view, "#fare-note") =~ "2 prices saved to Helper Prices Version service."
      assert has_element?(view, "#undo-prices")

      refute has_element?(view, "#agent-review-prepared-2")
      assert {:ok, ^pid, %{conversation_id: conversation_id}} = Agents.open(scope(context))
      assert Agents.prepared(pid, conversation_id, 2) == :error

      # A forged repeat after success finds no review and changes nothing.
      render_click(view, "save_price_review", %{})
      assert prices(context) == after_save
      assert length(fare_logs(context)) == 1

      # Undo is the grid's own.
      view |> element("#undo-prices") |> render_click()

      assert price_amounts(prices(context)) == price_amounts(before)
      assert text_of(view, "#fare-note") =~ "Change undone."
    end

    test "a price another editor changed between review and confirm writes nothing", context do
      {view, pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()

      assert {:ok, _written} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "local_ride_adult_cash",
                   rider_category_id: "adult",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("1.50"),
                   amount: Decimal.new("1.60")
                 }
               ])

      before = prices(context)
      logs = length(fare_logs(context))

      view |> element("#price-review-dialog-confirm") |> render_click()

      assert prices(context) == before
      assert length(fare_logs(context)) == logs
      assert has_element?(view, "#price-review-dialog")
      assert has_element?(view, "#price-review-error", @stale_error)
      assert has_element?(view, "#price-review-stale")
      assert confirm_disabled?(render(view))

      amounts = price_amounts(prices(context))

      assert Decimal.equal?(
               amounts[{"local_ride_adult_cash", "adult", "cash"}],
               Decimal.new("1.60")
             )

      assert {:ok, ^pid, %{conversation_id: conversation_id}} = Agents.open(scope(context))
      assert {:ok, %{command: {:price_cells, _}}} = Agents.prepared(pid, conversation_id, 2)
    end

    test "a revoked editor writes nothing and sees the save failure", context do
      {view, _pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()
      before = prices(context)
      logs = length(fare_logs(context))

      deactivate_membership_fixture(context.membership)
      view |> element("#price-review-dialog-confirm") |> render_click()

      assert prices(context) == before
      assert length(fare_logs(context)) == logs
      assert has_element?(view, "#price-review-error", @save_failed)
      assert has_element?(view, "#price-review-dialog")
    end

    test "a version that is no longer managed writes nothing and says so", context do
      {view, _pid} = prepared_view(context)
      view |> element("#agent-review-prepared-2") |> render_click()
      before = prices(context)

      Repo.delete_all(
        from(s in FareVersionSetting,
          where:
            s.organization_id == ^context.organization.id and
              s.gtfs_version_id == ^context.version.id
        )
      )

      view |> element("#price-review-dialog-confirm") |> render_click()

      assert prices(context) == before
      assert has_element?(view, "#price-review-error", @unmanaged_notice)
    end
  end

  describe "the review's states" do
    test "a stale review, an empty review and a save error disable or explain the confirm",
         context do
      {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)

      {:ok, %{rows: rows, unchanged: unchanged}} =
        Fares.preview_price_cells(context.organization.id, context.version.id, "USD", [
          %{
            fare_product_id: "local_ride_adult_cash",
            rider_category_id: "adult",
            fare_media_id: "cash",
            amount: "1.75"
          }
        ])

      origin = %{return_focus_id: "agent-prepared-2"}

      render = fn review ->
        render_component(&FareEditorComponents.price_review_dialog/1,
          review:
            Map.merge(
              %{rows: rows, unchanged: unchanged, error: nil, stale?: false, origin: origin},
              review
            ),
          workspace: workspace,
          version_name: "Helper Prices Version",
          published?: true,
          return_focus_id: "agent-prepared-2"
        )
      end

      assert render.(%{}) =~ "Save 1 price"
      refute confirm_disabled?(render.(%{}))

      stale = render.(%{stale?: true})
      assert stale =~ "price-review-stale"
      assert confirm_disabled?(stale)

      empty = render.(%{rows: []})
      assert empty =~ "Nothing to save: every price already has that amount."
      assert confirm_disabled?(empty)

      error = render.(%{error: "Changes couldn’t be saved. Your edits are still here."})
      assert error =~ "price-review-error"
    end
  end

  ## Helpers

  defp text_of(view, selector) do
    view
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp confirm_disabled?(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#price-review-dialog-confirm")
    |> LazyHTML.attribute("disabled")
    |> Enum.any?()
  end

  defp price_amounts(rows),
    do:
      Map.new(rows, fn {product, rider, medium, amount, _updated} ->
        {{product, rider, medium}, amount}
      end)

  defp fare_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.gtfs_version_id == ^context.version.id and l.entity_type == "fare_version" and
            fragment("?->>'summary' = ?", l.changed_fields, "Changed 2 prices")
      )
    )
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp prices(context) do
    Repo.all(
      from(p in FareProduct,
        where: p.gtfs_version_id == ^context.version.id,
        order_by: [p.fare_product_id, p.rider_category_id, p.fare_media_id],
        select: {p.fare_product_id, p.rider_category_id, p.fare_media_id, p.amount, p.updated_at}
      )
    )
  end

  # Opens the helper, attaches this process to the same conversation so the settled
  # entry can be awaited, and scripts the two provider replies of one prepare turn.
  defp prepared_view(context) do
    {:ok, view, _html} = open(context, context.version)
    view |> element("#agent-helper-open") |> render_click()

    pid = assigns(view).agent_session
    assert {:ok, ^pid, _snapshot} = Agents.open(scope(context))

    expect_reply(tool_calls_reply([{"call_1", "prepare_price_changes", @prepare_arguments}]))
    expect_reply(text_reply("I prepared 2 price changes."))

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Raise Local ride adult and reduced cash"}})

    assert_receive {:agent_event, ^pid,
                    {:entry, %{status: :done, prepared: %{command: command}}}},
                   10_000

    assert {:price_cells, %{currency: "USD", rows: [_, _], unchanged: [_]}} = command
    render(view)

    {view, pid}
  end

  defp scope(context) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "fare_prices",
      version_name: context.version.name,
      resource_context: Scope.context({:version, context.version.id})
    }
  end

  defp log_in(conn, context),
    do: log_in_user(conn, context.user, organization: context.organization)

  defp open(context, version), do: open_path(context, version, "")

  defp open_path(context, version, suffix) do
    build_conn()
    |> log_in(context)
    |> live("/gtfs/#{version.id}/settings/fares#{suffix}")
  end
end

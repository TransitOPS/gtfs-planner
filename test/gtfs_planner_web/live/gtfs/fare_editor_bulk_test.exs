defmodule GtfsPlannerWeb.Gtfs.FareEditorBulkTest do
  @moduledoc """
  Merge evidence (EV-34) for the Change prices dialog: the preview it shows for
  the choices the operator makes, the rows it writes, and the Undo that reverses
  them (AC-15, AC-37).

  Every case drives the real page against the real writers, through
  `Fares.preview_price_change/3` and `Fares.apply_price_change/3`, and asserts
  on the elements the dialog is required to carry rather than on the words it
  happens to read.

  The version enters its rows the way a user's version does — through the
  production importer of `north_coast_v2` and the production conversion that
  manages it — and the expected amounts are worked by hand from that feed.

  `test/fixtures/gtfs/fares/north_coast_v2/fare_products.txt` carries seven
  fares, each sold to an adult, a reduced rider, a youth rider and a child who
  rides free. The default dialog is +$0.25 to the nearest nickel over single
  rides, and every fare in this feed reads as a single ride — the feed has no
  `fare_product_details` rows and no `bundle_amount`, so
  `Fares.preview_price_change/3` infers each one as a single ride. That is 24
  priced rows, each rising by $0.25:

  | Fare              | Adult         | Reduced         | Youth          |
  |---|---|---|---|
  | Coast ride        | $3.50 → $3.75 | $1.75 → $2.00   | $2.00 → $2.25  |
  | Day pass          | $4.00 → $4.25 | $2.00 → $2.25   | $2.50 → $2.75  |
  | Intercity ride    | $6.00 → $6.25 | $3.00 → $3.25   | $4.00 → $4.25  |
  | Local ride, cash  | $1.50 → $1.75 | $0.75 → $1.00   | $1.00 → $1.25  |
  | Local ride, app   | $1.25 → $1.50 | $0.60 → $0.85   | $0.75 → $1.00  |
  | 31-day pass       | $50.00 → $50.25 | $25.00 → $25.25 | $30.00 → $30.25 |
  | Valley-coast ride | $5.00 → $5.25 | $2.50 → $2.75   | $3.00 → $3.25  |
  | Valley ride       | $2.50 → $2.75 | $1.25 → $1.50   | $1.50 → $1.75  |

  The reduced rider stays at half of the new adult price on a feed whose reduced
  row shares the adult row's `fare_product_id` — which is what the first-use
  setup writes, and what `test/gtfs_planner/gtfs/fares/price_change_test.exs`
  proves. This feed gives every rider type its own product row, so the reduced
  row has no adult row to be half of and moves by the ordinary rule instead.
  The children under 6 ride free on every fare, so no row names them either way.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  setup context do
    organization =
      organization_fixture(%{alias: "fare-bulk-#{System.unique_integer([:positive])}"})

    user = user_fixture(%{email: editor_email()})
    version = gtfs_version_fixture(organization.id, %{name: "Fare change version"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    import!(organization, version, "north_coast_v2")

    scope = scope(organization, version, user)
    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    {:ok,
     conn: log_in_user(context.conn, user, organization: organization),
     organization: organization,
     user: user,
     version: version}
  end

  describe "previewing a change" do
    test "the default choices show what +$0.25 to single rides would do", ctx do
      view = open_change_prices(ctx)

      assert has_element?(view, "#price-change-dialog")
      assert has_element?(view, "#price-change-preview-badge")
      refute has_element?(view, "#price-change-empty")

      # Every priced rider type of every fare the single-ride scope covers
      # moves by $0.25, so the three tiles state the whole change.
      assert has_element?(view, "#price-change-count", "24 prices change")
      assert has_element?(view, "#price-change-largest", "+$0.25")
      assert has_element?(view, "#price-change-fares", "7 fares affected")

      # Local ride, both methods, worked by hand from the feed: its adult cash
      # price is $1.50 and $1.50 + $0.25 is $1.75, already a whole nickel.
      row = change_row(view, "local_ride_adult_cash")
      assert row =~ "Local ride"
      assert row =~ "Adult"
      assert row =~ "$1.50"
      assert row =~ "$1.75"

      assert change_row(view, "local_ride_youth_cash") =~ "$1.25"
      assert change_row(view, "local_ride_adult_app") =~ "$1.50"
      assert change_row(view, "local_ride_reduced_app") =~ "$0.85"

      # The half-fare rule is on by default and is offered as chosen. This feed
      # gives every rider type its own `fare_products` row, so the reduced row
      # has no adult row of the same product to be half of and moves by the
      # ordinary rule instead: $0.75 + $0.25 = $1.00.
      assert has_element?(view, "#price-change-half[checked]")
      assert change_row(view, "local_ride_reduced_cash") =~ "$1.00"

      # A child rides free, so no row names one.
      refute has_element?(view, "#price-change-row-local_ride_child_cash")

      # A preview writes nothing.
      assert amount(ctx, "local_ride_adult_cash") == Decimal.new("1.50")
      assert amount(ctx, "local_ride_reduced_cash") == Decimal.new("0.75")
    end

    test "the choices narrow what the preview lists", ctx do
      view = open_change_prices(ctx)

      # Only the adult rider type, so the preview lists one row per fare.
      view
      |> element("#price-change-form")
      |> render_change(%{"change" => %{"riders" => ["adult"]}})

      refute has_element?(view, "#price-change-row-local_ride_reduced_cash")
      assert has_element?(view, "#price-change-row-local_ride_adult_cash")

      # A percentage moves the imported Coast ride fare on the same rule:
      # 10% of $3.50 is $3.85, which is 15.4 quarters and rounds down to $3.75.
      view
      |> element("#price-change-form")
      |> render_change(%{
        "change" => %{"how" => "percent", "percent" => "10", "round" => "0.25"}
      })

      assert has_element?(view, "#price-change-percent")
      assert change_row(view, "coast_ride_adult_cash") =~ "$3.75"
      refute has_element?(view, "#price-change-row-local_ride_youth_cash")
    end

    test "a choice that moves no price disables Update with the reason", ctx do
      view = open_change_prices(ctx)

      view
      |> element("#price-change-form")
      |> render_change(%{"change" => %{"amount" => "0.00"}})

      assert has_element?(view, "#price-change-empty", "No prices change with these choices.")
      assert has_element?(view, "#price-change-count", "0 prices change")
      assert has_element?(view, "#price-change-largest", "—")
      assert has_element?(view, "#price-change-dialog-confirm[disabled]")
      assert has_element?(view, "#price-change-dialog-confirm", "Update prices")

      # The reason is on the dialog's own status line, not only in the table.
      assert status_text(view) =~ "Nothing changes until you update."

      # And an unreadable amount is refused the same way, with its own reason.
      view
      |> element("#price-change-form")
      |> render_change(%{"change" => %{"amount" => "twenty five cents"}})

      assert has_element?(view, "#price-change-value-error")
      assert has_element?(view, "#price-change-dialog-confirm[disabled]")
      assert amount(ctx, "local_ride_adult_cash") == Decimal.new("1.50")
    end

    test "it does not open over prices the operator has not saved", ctx do
      view = open_prices(ctx)

      view
      |> element("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride|adult|cash" => "1.60"}})

      assert has_element?(view, "#price-save-bar")

      view |> element("#change-prices") |> render_click()

      refute has_element?(view, "#price-change-dialog")
      assert render(view) =~ "Save or discard your unsaved prices"

      # Discarding the edit opens it as normal.
      view |> element("#discard-prices") |> render_click()
      view |> element("#change-prices") |> render_click()

      assert has_element?(view, "#price-change-dialog")
    end
  end

  describe "applying a change" do
    test "Update writes the previewed rows and Undo restores them", ctx do
      view = open_change_prices(ctx)

      # Only the adult rider type, so the write is one row per single ride.
      view
      |> element("#price-change-form")
      |> render_change(%{"change" => %{"riders" => ["adult"]}})

      view |> element("#price-change-dialog-confirm") |> render_click()

      refute has_element?(view, "#price-change-dialog")
      assert has_element?(view, "#undo-prices")
      assert render(view) =~ "8 prices changed"

      # The rows the preview showed are the rows stored, on the cash method the
      # grid's main row is.
      assert amount(ctx, "local_ride_adult_cash") == Decimal.new("1.75")
      assert amount(ctx, "local_ride_adult_app") == Decimal.new("1.50")
      assert amount(ctx, "valley_ride_adult_cash") == Decimal.new("2.75")
      assert amount(ctx, "coast_ride_adult_cash") == Decimal.new("3.75")
      assert amount(ctx, "valley_coast_ride_adult_cash") == Decimal.new("5.25")
      assert amount(ctx, "intercity_ride_adult_cash") == Decimal.new("6.25")

      # A rider type the dialog did not name is not in the write at all.
      assert amount(ctx, "local_ride_reduced_cash") == Decimal.new("0.75")
      assert amount(ctx, "local_ride_youth_cash") == Decimal.new("1.00")

      # And the grid shows what was written, because the workspace was reloaded.
      assert view |> element("#price-local_ride-adult") |> render() =~ "1.75"

      view |> element("#undo-prices") |> render_click()

      assert amount(ctx, "local_ride_adult_cash") == Decimal.new("1.50")
      assert amount(ctx, "local_ride_adult_app") == Decimal.new("1.25")
      assert amount(ctx, "intercity_ride_adult_cash") == Decimal.new("6.00")
      assert view |> element("#price-local_ride-adult") |> render() =~ "1.50"
    end

    test "a price changed since the preview refuses the whole change", ctx do
      view = open_change_prices(ctx)

      view
      |> element("#price-change-form")
      |> render_change(%{"change" => %{"riders" => ["adult"]}})

      # Another operator saves the adult price between this preview and its
      # update, so the reviewed $1.50 is no longer what is stored.
      {:ok, _saved} =
        Fares.save_prices(scope(ctx.organization, ctx.version, ctx.user), [
          %{
            fare_product_id: "local_ride_adult_cash",
            rider_category_id: "adult",
            fare_media_id: "cash",
            reviewed: Decimal.new("1.50"),
            amount: Decimal.new("1.60")
          }
        ])

      view |> element("#price-change-dialog-confirm") |> render_click()

      # The dialog stays open with the reason, and nothing was written.
      assert has_element?(view, "#price-change-dialog")
      assert status_text(view) =~ "changed since this preview"
      assert amount(ctx, "local_ride_adult_cash") == Decimal.new("1.60")
      assert amount(ctx, "intercity_ride_adult_cash") == Decimal.new("6.00")
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # A per-call address: the shared `user_fixture/1` counter restarts with each
  # BEAM run, so a row an unboxed test left in the shared database can collide
  # with it inside the fixture. The prefix keeps this file out of that range.
  defp editor_email do
    "fare-bulk-#{System.pid()}-#{System.unique_integer([:positive])}@example.com"
  end

  defp open_prices(ctx) do
    {:ok, view, _html} = live(ctx.conn, ~p"/gtfs/#{ctx.version.id}/settings/fares")

    # The shell's connected mount owns the load, so the grid only renders once
    # the workspace has arrived.
    assert render(view) =~ "fare-table"
    view
  end

  defp open_change_prices(ctx) do
    view = open_prices(ctx)
    view |> element("#change-prices") |> render_click()
    assert has_element?(view, "#price-change-dialog")
    view
  end

  defp change_row(view, product_id) do
    view |> element("#price-change-row-#{product_id}") |> render()
  end

  # The status slot sits beside the actions, outside the dialog's own form.
  defp status_text(view) do
    view |> element("#price-change-status") |> render()
  end

  defp amount(ctx, product_id) do
    organization_id = ctx.organization.id
    version_id = ctx.version.id

    FareProduct
    |> where(
      [product],
      product.organization_id == ^organization_id and product.gtfs_version_id == ^version_id and
        product.fare_product_id == ^product_id
    )
    |> Repo.one()
    |> then(& &1.amount)
  end

  defp scope(organization, version, actor) do
    %{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end
end

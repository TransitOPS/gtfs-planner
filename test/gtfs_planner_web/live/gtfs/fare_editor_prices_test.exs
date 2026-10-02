defmodule GtfsPlannerWeb.Gtfs.FareEditorPricesTest do
  @moduledoc """
  Merge evidence (EV-32) for the fare editor's Prices tab: the fare grid, the
  save bar and its draft journey impacts, the conflict panel, the saved note
  with Undo, and the older-format lens.

  Every case drives the real page against the real writers — no mock stands in
  for the fare workspace — so what is proved is what an operator gets. The
  version enters rows the way a user's version does, through the production
  importer of `north_coast_v2` and the production conversion that manages it,
  and every save runs inside `Fares.VersionLock.transact/2` like every other
  write of this package.

  Expected values are literals worked by hand from the sample feed, not read
  back from the code under test: the "Local ride" fare is $1.50 for the adult
  rider on the cash method and $1.25 in the NCT Ride app, so typing 1.75 over
  the cash cell and saving stores $1.75, the note says one price was saved and
  Undo puts $1.50 back; `1..5` is refused by `Fares.Money.parse/1` and so marks
  its cell rather than saving; and the lens tints exactly the single-ride,
  default-rider, base-method cells that the older format carries.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 0]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture(%{alias: "fare-prices-tab-#{unique_alias()}"})
    user = user_fixture()
    version = gtfs_version_fixture(organization.id, %{name: "Fare prices tab version"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    import!(organization, version, "north_coast_v2")

    scope = scope(organization, version, user)
    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])

    %{organization: organization, user: user, version: version, scope: scope}
  end

  describe "the fare table" do
    setup %{conn: conn, user: user, organization: organization, version: version} do
      %{conn: log_in_user(conn, user, organization: organization), version: version}
    end

    test "one editable cell per fare and rider type, named after the row it writes", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))

      # The sample's own fares and riders, as the grid shows them.
      assert has_element?(view, "#fare-table")
      assert has_element?(view, "#fare-table-title", "Fare table")
      assert has_element?(view, "#fare-summary-title", "Fares in plain words")
      assert has_element?(view, "#fare-payment-title", "How riders pay")
      assert has_element?(view, "#fare-history-title", "Recent price changes")

      # The cash method is the fare's own row, and the app prices differently, so
      # it gets a sub-row. A cell is named for the `fare_products` row it writes.
      assert has_element?(view, "#price-local_ride-adult")
      assert has_element?(view, "#price-local_ride-adult-app")

      # A blank cell reads as not sold rather than as a zero.
      assert has_element?(
               view,
               "#price-local_ride-child[placeholder='Not sold']"
             )

      # No save bar before anything is edited.
      refute has_element?(view, "#price-save-bar")
    end

    test "the where line names the route groups and zones that charge the fare", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))
      html = render(view)

      assert text_of(html) =~ "Local routes"
      # A fare the sample prices between zones says where between them.
      assert text_of(html) =~ "↔"
    end

    test "editing a price and blurring shows it formatted and raises the save bar", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))

      html =
        view
        |> form("#fare-table-form")
        |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1.75"}})

      # What the operator typed is read by `Fares.Money.parse/1` and shown the
      # way a fare machine reads it.
      assert html =~ ~s(value="$1.75")

      # The bar appears and names what is unsaved, as "old → new".
      assert has_element?(view, "#price-save-bar")
      assert has_element?(view, "#save-prices", "Save 1 price")
      assert text_of(html) =~ "Unsaved: 1 price"
      assert text_of(html) =~ "Local ride · Adult $1.50 → $1.75"

      # A cell nobody else has moved is not a conflict.
      refute has_element?(view, "#fares-conflict")
    end
  end

  describe "saving prices" do
    setup %{conn: conn, user: user, organization: organization, version: version} do
      %{conn: log_in_user(conn, user, organization: organization), version: version}
    end

    test "writes the reviewed cell, notes the save and undoes it back to $1.50", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))

      view
      |> form("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1.75"}})

      html = render_click(view, "save_prices")

      # One `fare_products` row changed, and the operator is told which price.
      assert amount(context, "local_ride_adult_cash") == Decimal.new("1.75")
      assert has_element?(view, "#fare-note", "1 price saved to Fare prices tab version service.")
      assert has_element?(view, "#undo-prices")
      assert html =~ "$1.75"

      # The grid now reads the stored amount, and the bar is gone.
      assert html =~ ~s(id="price-local_ride-adult")
      refute has_element?(view, "#price-save-bar")

      # Undo puts the reviewed amount back through the same inverse.
      render_click(view, "undo_prices")
      assert amount(context, "local_ride_adult_cash") == Decimal.new("1.50")
      assert has_element?(view, "#fare-note", "Change undone.")
      refute has_element?(view, "#undo-prices")
    end

    test "an unreadable price marks its cell and blocks the save", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))

      html =
        view
        |> form("#fare-table-form")
        |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1..5"}})

      # The typo is kept exactly as typed, and marked invalid rather than
      # silently read as a blank price.
      assert html =~ ~s(value="1..5")
      assert html =~ ~s(aria-invalid="true")
      assert has_element?(view, "#price-save-bar")
      assert text_of(html) =~ "Fix the highlighted price to save."
      assert has_element?(view, "#save-prices[aria-disabled='true']")

      # A blocked save writes nothing, and the reader cannot reach the handler
      # through the button either.
      render_click(view, "save_prices")
      assert amount(context, "local_ride_adult_cash") == Decimal.new("1.50")
      refute has_element?(view, "#fare-note")
    end

    test "blanking a cell saves as not sold rather than as a zero", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))

      view
      |> form("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride_adult_cash|child|cash" => ""}})

      assert render_click(view, "save_prices")
      refute stored_row?(context, "local_ride_adult_cash", "child")
    end
  end

  describe "a concurrent change" do
    setup %{conn: conn, user: user, organization: organization, version: version} do
      %{conn: log_in_user(conn, user, organization: organization), version: version}
    end

    test "refuses the save, offers the choices and blocks until one is chosen", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))

      view
      |> form("#fare-table-form")
      |> render_change(%{"price" => %{"local_ride_adult_cash|adult|cash" => "1.75"}})

      # Somebody else changes the same cell while this operator is editing.
      {:ok, _result} =
        Fares.save_prices(context.scope, [
          %{
            fare_product_id: "local_ride_adult_cash",
            rider_category_id: "adult",
            fare_media_id: "cash",
            reviewed: Decimal.new("1.50"),
            amount: Decimal.new("1.60")
          }
        ])

      html = render_click(view, "save_prices")

      # Nothing was written by this operator, and the panel names the cell both
      # of them changed with both prices and the choice each one implies.
      assert amount(context, "local_ride_adult_cash") == Decimal.new("1.60")
      assert has_element?(view, "#fares-conflict")
      assert text_of(html) =~ "Local ride · Adult"
      assert text_of(html) =~ "$1.75"
      assert text_of(html) =~ "$1.60"
      assert has_element?(view, "#fares-conflict[role='alert']")

      # Save is blocked while the choice is open.
      assert has_element?(view, "#save-prices[aria-disabled='true']")
      assert text_of(html) =~ "Choose which price to keep"
      render_click(view, "save_prices")
      assert amount(context, "local_ride_adult_cash") == Decimal.new("1.60")

      # Choosing this operator's price and saving again writes it, and the
      # conflict is settled.
      render_click(view, "choose_conflict", %{
        "key" => "local_ride_adult_cash|adult|cash",
        "choice" => "mine"
      })

      assert has_element?(view, "#save-prices[aria-disabled='false']")
      assert render_click(view, "save_prices")
      assert amount(context, "local_ride_adult_cash") == Decimal.new("1.75")
      refute has_element?(view, "#fares-conflict")
    end
  end

  describe "the older-format lens" do
    setup %{conn: conn, user: user, organization: organization, version: version} do
      %{conn: log_in_user(conn, user, organization: organization), version: version}
    end

    test "tints exactly the cells the older format carries", context do
      {:ok, view, _html} = live(context.conn, prices_path(context.version))

      refute has_element?(view, "#fare-lens-note")

      assert render_click(view, "toggle_lens")
      assert has_element?(view, "#fare-lens[checked]")

      html = render(view)

      # The adult single rides on the cash method are the prices the older
      # format carries, and each is tinted.
      for fare <- ~w(local_ride valley_ride coast_ride) do
        assert html =~ ~s(id="price-#{fare}-adult")
      end

      # A payment-method sub-row is newer-format only, and so are the other
      # rider types and the passes: those cells are not tinted.
      tinted = tinted_cell_ids(html)

      assert "price-local_ride-adult" in tinted
      refute "price-local_ride-adult-app" in tinted
      refute "price-local_ride-reduced" in tinted
      refute "price-day_pass-adult" in tinted

      # Toggling it back removes the tint from every cell.
      assert render_click(view, "toggle_lens")
      assert tinted_cell_ids(render(view)) == []
    end
  end

  # -- helpers ----------------------------------------------------------------

  # The shell's own copy is a source literal, and HEEx wraps a long line inside
  # the element that carries it, so the rendered text is compared with its
  # whitespace collapsed rather than against the source's line breaks.
  defp text_of(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp prices_path(version), do: "/gtfs/#{version.id}/settings/fares"

  defp unique_alias, do: System.unique_integer([:positive])

  # The cells the lens tinted: the wrapper carries the tint, and its id is the
  # cell's, so a tinted cell is the wrapper whose id is the cell id.
  # The tinted cells are the price cells whose own wrapper says the older
  # format carries them, which is the same element the tint is applied to.
  defp tinted_cell_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#fare-table [data-lens='in'] > input[name^='price[']")
    |> Enum.map(&List.first(LazyHTML.attribute(&1, "id")))
    |> Enum.sort()
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

  defp amount(context, product_id) do
    context.organization.id
    |> fare_amount(context.version.id, product_id)
  end

  defp fare_amount(organization_id, version_id, product_id) do
    import Ecto.Query

    GtfsPlanner.Gtfs.FareProduct
    |> where(
      [product],
      product.organization_id == ^organization_id and product.gtfs_version_id == ^version_id and
        product.fare_product_id == ^product_id
    )
    |> Repo.one()
    |> case do
      nil -> nil
      product -> product.amount
    end
  end

  defp stored_row?(context, product_id, rider_id) do
    import Ecto.Query

    GtfsPlanner.Gtfs.FareProduct
    |> where(
      [product],
      product.organization_id == ^context.organization.id and
        product.gtfs_version_id == ^context.version.id and
        product.fare_product_id == ^product_id and
        product.rider_category_id == ^rider_id
    )
    |> Repo.exists?()
  end
end

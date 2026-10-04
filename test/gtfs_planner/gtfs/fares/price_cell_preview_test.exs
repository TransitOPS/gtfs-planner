defmodule GtfsPlanner.Gtfs.Fares.PriceCellPreviewTest do
  @moduledoc """
  Merge evidence (EV-12) for `Fares.preview_price_cells/4`: an exact before and
  after for explicit cells that never rounds, creates or deletes a price.

  Every expected amount is worked by hand from the `north_coast_v2` fixture (Local
  ride adult cash 1.50, reduced cash 0.75, youth cash 1.00) and every refusal case
  re-reads the stored rows to show nothing was written. The twin organization
  carries the same product IDs, so a missing scope predicate is observable. The
  last case feeds a successful preview to the production writer
  `Fares.save_prices/2` to show the two shapes agree.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3, managed!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 0]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1]

  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    actor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id)
    scope = managed!(organization, version, actor)

    twin_organization = organization_fixture()
    twin_version = gtfs_version_fixture(twin_organization.id)
    managed!(twin_organization, twin_version, editor_fixture(twin_organization))

    unmanaged_version = gtfs_version_fixture(organization.id)
    import!(organization, unmanaged_version, "north_coast_v1")

    %{
      organization: organization,
      version: version,
      scope: scope,
      twin_organization: twin_organization,
      twin_version: twin_version,
      unmanaged_version: unmanaged_version,
      before: stored(version)
    }
  end

  defp stored(version) do
    Repo.all(
      from(p in FareProduct,
        where: p.gtfs_version_id == ^version.id,
        order_by: [p.fare_product_id, p.rider_category_id, p.fare_media_id],
        select: {p.fare_product_id, p.rider_category_id, p.fare_media_id, p.amount, p.currency}
      )
    )
  end

  defp cell(product, rider, medium, amount),
    do: %{
      fare_product_id: product,
      rider_category_id: rider,
      fare_media_id: medium,
      amount: amount
    }

  defp adult(amount), do: cell("local_ride_adult_cash", "adult", "cash", amount)

  defp preview(context, cells, currency \\ "USD"),
    do: Fares.preview_price_cells(context.organization.id, context.version.id, currency, cells)

  test "returns the exact rows in input order and the unchanged cell, writing nothing", context do
    input = [
      adult("1.75"),
      cell("local_ride_reduced_cash", "reduced", "cash", "0.85"),
      cell("local_ride_youth_cash", "youth", "cash", "1.00")
    ]

    assert {:ok, %{rows: [adult_row, reduced_row], unchanged: [youth]}} = preview(context, input)

    assert %{
             fare_product_id: "local_ride_adult_cash",
             rider_category_id: "adult",
             fare_media_id: "cash",
             fare_name: "Local ride",
             rider_name: "Adult",
             medium_name: "Cash on board"
           } = adult_row

    assert Decimal.equal?(adult_row.now, Decimal.new("1.50"))
    assert Decimal.equal?(adult_row.new, Decimal.new("1.75"))
    assert reduced_row.fare_product_id == "local_ride_reduced_cash"
    assert Decimal.equal?(reduced_row.now, Decimal.new("0.75"))
    assert Decimal.equal?(reduced_row.new, Decimal.new("0.85"))
    assert reduced_row.rider_name == "Reduced fare"

    assert %{fare_product_id: "local_ride_youth_cash", rider_category_id: "youth"} = youth
    assert Decimal.equal?(youth.amount, Decimal.new("1.00"))

    assert stored(context.version) == context.before
  end

  test "reads a dollar sign and Free as the person writes them", context do
    assert {:ok, %{rows: [row]}} = preview(context, [adult("$1.75")])
    assert Decimal.equal?(row.new, Decimal.new("1.75"))

    assert {:ok, %{rows: [free]}} = preview(context, [adult("Free")])
    assert Decimal.equal?(free.new, Decimal.new("0"))
  end

  test "blank, negative, unreadable and over-precise amounts are refused and delete nothing",
       context do
    for amount <- ["", "  ", "-1.00", "abc", "1.505", nil, 1.75] do
      assert preview(context, [adult(amount)]) == {:error, :invalid_price},
             "amount #{inspect(amount)}"
    end

    assert stored(context.version) == context.before
  end

  describe "currency" do
    test "a zero-decimal currency accepts 150 and refuses 150.50 instead of storing 151",
         context do
      Repo.update_all(from(p in FareProduct, where: p.gtfs_version_id == ^context.version.id),
        set: [currency: "JPY"]
      )

      before = stored(context.version)

      assert {:ok, %{rows: [row]}} = preview(context, [adult("150")], "JPY")
      assert Decimal.equal?(row.new, Decimal.new("150"))
      assert preview(context, [adult("150.50")], "JPY") == {:error, :invalid_price}
      assert stored(context.version) == before
    end

    test "a currency that is not the product's own is a mismatch", context do
      assert preview(context, [adult("1.75")], "CAD") == {:error, :currency_mismatch}

      Repo.update_all(
        from(p in FareProduct,
          where:
            p.gtfs_version_id == ^context.version.id and
              p.fare_product_id == "local_ride_adult_cash"
        ),
        set: [currency: "JPY"]
      )

      assert preview(context, [adult("175")]) == {:error, :currency_mismatch}
    end
  end

  describe "cells" do
    test "a repeated key, an unknown product and another organization's product", context do
      assert preview(context, [adult("1.75"), adult("1.80")]) == {:error, :duplicate_cell}

      assert preview(context, [cell("nope", "adult", "cash", "1.00")]) == {:error, :not_found}

      # A product only the twin organization's version holds.
      Repo.insert!(%FareProduct{
        organization_id: context.twin_organization.id,
        gtfs_version_id: context.twin_version.id,
        fare_product_id: "twin_only_ride",
        rider_category_id: "adult",
        fare_media_id: "cash",
        amount: Decimal.new("1.00"),
        currency: "USD"
      })

      assert preview(context, [cell("twin_only_ride", "adult", "cash", "2.00")]) ==
               {:error, :not_found}
    end

    test "a product with no row at that rider is a missing cell and nothing is created",
         context do
      count = Repo.aggregate(FareProduct, :count)

      assert preview(context, [cell("local_ride_adult_cash", "youth", "cash", "1.00")]) ==
               {:error, {:missing_cell, {"local_ride_adult_cash", "youth", "cash"}}}

      assert Repo.aggregate(FareProduct, :count) == count
    end

    test "51 cells are too many and no cells is no prices", context do
      cells = for number <- 1..51, do: cell("p#{number}", "adult", "cash", "1.00")

      assert preview(context, cells) == {:error, :too_many}
      assert preview(context, []) == {:error, :no_prices}
    end

    test "an unmanaged version previews nothing", context do
      assert Fares.preview_price_cells(
               context.organization.id,
               context.unmanaged_version.id,
               "USD",
               [adult("1.75")]
             ) == {:error, :unmanaged}
    end
  end

  test "a successful preview fed to save_prices/2 writes exactly the previewed rows", context do
    input = [adult("1.75"), cell("local_ride_reduced_cash", "reduced", "cash", "0.85")]
    assert {:ok, %{rows: rows}} = preview(context, input)

    save_cells =
      Enum.map(rows, fn row ->
        %{
          fare_product_id: row.fare_product_id,
          rider_category_id: row.rider_category_id,
          fare_media_id: row.fare_media_id,
          reviewed: row.now,
          amount: row.new
        }
      end)

    assert {:ok, _written} = Fares.save_prices(context.scope, save_cells)

    after_save = stored(context.version)

    assert length(after_save) == length(context.before)

    changed =
      for row <- after_save, row not in context.before, do: {elem(row, 0), elem(row, 3)}

    assert Enum.sort(Enum.map(changed, fn {id, amount} -> {id, Decimal.to_string(amount)} end)) ==
             [{"local_ride_adult_cash", "1.75"}, {"local_ride_reduced_cash", "0.85"}]
  end
end

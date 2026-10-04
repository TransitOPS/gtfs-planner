defmodule GtfsPlanner.Gtfs.Fares.PriceCellsReadTest do
  @moduledoc """
  Merge evidence (EV-11) for `Fares.list_price_cells/3`: the stored prices of a
  managed version with the recorded structure that says what each one is.

  The version enters rows the way a user's version does: the production importer
  of `test/fixtures/gtfs/fares/north_coast_v2` and the production conversion. The
  expected cells are literal values read from that fixture, never from the code
  under test, and the totals are compared with an independent scoped count of
  `fare_products` rows. A twin organization carries the same product IDs, so a
  missing scope predicate doubles the answer.

  Classification comes from `fare_product_details.kind` and `fare_media_type`:
  "Cash single ride" sold on the app medium is listed as an app (type 4) price.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3, managed!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 0]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 1]

  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    actor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id)
    managed!(organization, version, actor)
    record_pass_kind(organization, version)

    twin_organization = organization_fixture()
    twin_actor = editor_fixture(twin_organization)
    twin_version = gtfs_version_fixture(twin_organization.id)
    managed!(twin_organization, twin_version, twin_actor)

    unmanaged_version = gtfs_version_fixture(organization.id)
    import!(organization, unmanaged_version, "north_coast_v1")

    %{
      organization: organization,
      version: version,
      unmanaged_version: unmanaged_version,
      twin_organization: twin_organization,
      twin_version: twin_version
    }
  end

  # The conversion leaves every fare a single ride; recording the three month
  # passes as passes is the operator's own fact, as the Where tab's passes table
  # and the browser seed record it.
  defp record_pass_kind(organization, version) do
    {3, nil} =
      Repo.update_all(
        from(d in FareProductDetail,
          where:
            d.organization_id == ^organization.id and d.gtfs_version_id == ^version.id and
              like(d.fare_product_id, "month_pass_%")
        ),
        set: [kind: "pass"]
      )
  end

  defp cells(context, opts \\ []) do
    {:ok, result} = Fares.list_price_cells(context.organization.id, context.version.id, opts)
    result
  end

  defp key(cell), do: {cell.fare_product_id, cell.rider_category_id, cell.fare_media_id}

  defp stored_count(organization, version) do
    Repo.aggregate(
      from(p in FareProduct,
        where: p.organization_id == ^organization.id and p.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  test "lists a cash cell and an app cell with their recorded structure and exact amounts",
       context do
    result = cells(context)

    assert result.currency == "USD"
    assert result.total == stored_count(context.organization, context.version)

    cash = Enum.find(result.cells, &(key(&1) == {"local_ride_adult_cash", "adult", "cash"}))

    assert %{
             fare_name: "Local ride",
             kind: "single",
             rider_name: "Adult",
             medium_name: "Cash on board",
             medium_type: 0,
             currency: "USD"
           } = cash

    assert Decimal.equal?(cash.amount, Decimal.new("1.50"))

    app = Enum.find(result.cells, &(key(&1) == {"local_ride_adult_app", "adult", "app"}))
    assert app.medium_type == 4
    assert Decimal.equal?(app.amount, Decimal.new("1.25"))
  end

  test "search and kind narrow the list and the total", context do
    local = cells(context, search: "local ride")

    assert local.total == 8
    assert Enum.all?(local.cells, &(&1.fare_name == "Local ride"))

    riders_by_medium =
      local.cells |> Enum.map(&{&1.rider_category_id, &1.fare_media_id}) |> Enum.sort()

    assert riders_by_medium ==
             Enum.sort(
               for rider <- ~w(adult reduced youth child),
                   medium <- ~w(cash app),
                   do: {rider, medium}
             )

    passes = cells(context, kind: "pass")

    assert Enum.sort(Enum.map(passes.cells, & &1.fare_product_id)) ==
             ~w(month_pass_adult_app month_pass_reduced_app month_pass_youth_app)

    singles = cells(context, kind: "single")
    refute Enum.any?(singles.cells, &String.starts_with?(&1.fare_product_id, "month_pass"))
    assert singles.total == cells(context).total - 3
  end

  test "the list is bounded at 50 cells and the total stays exact", context do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      for number <- 1..30 do
        %{
          id: Ecto.UUID.generate(),
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          fare_product_id: "extra_#{number}",
          fare_product_name: "Extra #{number}",
          rider_category_id: "adult",
          fare_media_id: "cash",
          amount: Decimal.new("9.00"),
          currency: "USD",
          inserted_at: now,
          updated_at: now
        }
      end

    {30, nil} = Repo.insert_all(FareProduct, rows)

    result = cells(context)
    assert length(result.cells) == 50
    assert result.total == stored_count(context.organization, context.version)
    assert result.total > 50

    assert length(cells(context, limit: 5).cells) == 5
    assert length(cells(context, limit: 500).cells) == 50
  end

  test "an unmanaged version lists nothing", context do
    assert Fares.list_price_cells(context.organization.id, context.unmanaged_version.id) ==
             {:error, :unmanaged}

    assert Fares.list_price_cells(context.organization.id, Ecto.UUID.generate()) ==
             {:error, :unmanaged}
  end

  test "a twin organization's identical product IDs never join the answer", context do
    own = cells(context)

    twin =
      cells(%{context | organization: context.twin_organization, version: context.twin_version})

    assert own.total == twin.total
    assert own.total == stored_count(context.organization, context.version)

    # The same pair crossed with the twin's version is not a managed version.
    assert Fares.list_price_cells(context.organization.id, context.twin_version.id) ==
             {:error, :unmanaged}
  end

  test "a product named for cash but sold on the app medium is listed as an app price", context do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareProduct, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          fare_product_id: "cash_single_app",
          fare_product_name: "Cash single ride",
          rider_category_id: "adult",
          fare_media_id: "app",
          amount: Decimal.new("3.00"),
          currency: "USD",
          inserted_at: now,
          updated_at: now
        }
      ])

    result = cells(context, search: "cash single")

    assert [%{medium_type: 4, medium_name: "NCT Ride app", kind: "single"} = cell] = result.cells
    assert cell.fare_media_id == "app"
  end
end

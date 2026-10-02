defmodule GtfsPlanner.Gtfs.Fares.PricesTest do
  @moduledoc """
  Merge evidence (EV-15) for `Fares.save_prices/2` and the price inverse
  `Fares.undo/3` applies (AC-14, AC-26, R9, R15).

  Every expected value is worked by hand from the spec and from the answers the
  test gives, not read back from the code under test: a flat first-use setup
  prices the one "Local ride" fare at $1.50 for the adult rider, half that to the
  nearest nickel ($0.75) for the reduced rider and nothing for the child, so
  saving $1.75 over a reviewed $1.50 changes one row and records one entry, a
  reviewed $1.50 over a stored $1.60 is a stale cell, and a blank cell is a
  missing row rather than a zero.

  The version enters rows the way a user's version does — through the production
  importer of `test/fixtures/gtfs/fares/no_fare` and then the production
  first-use setup — and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/2`, the one transaction every
  writer of this package uses.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture(%{alias: "fares-prices-#{unique_alias()}"})
    actor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id, %{name: "Fare prices version"})
    import!(organization, version, "no_fare")

    context = %{
      organization: organization,
      version: version,
      scope: scope(organization, version, actor)
    }

    {:ok, _setup} = Conversion.setup(context.scope, flat_answers())

    context
  end

  describe "saving a price" do
    test "changes one row and records one entry", context do
      assert {:ok, result} = save(context, [adult_cell(Decimal.new("1.50"), "1.75")])

      # $1.50 over a reviewed $1.50, and nothing else touched: the reduced rider
      # keeps $0.75 and the child keeps nothing.
      assert price_amounts(context) == %{
               "adult" => Decimal.new("1.75"),
               "child" => Decimal.new("0"),
               "reduced" => Decimal.new("0.75")
             }

      assert [entry] = fare_logs(context, "updated")
      assert entry.id == result.operation_id
      assert entry.changed_fields["operation_id"] == result.operation_id
      assert entry.changed_fields["summary"] == "Changed 1 price"

      assert entry.changed_fields["before"] == [
               %{
                 "fare_product_id" => "local_ride",
                 "rider_category_id" => "adult",
                 "fare_media_id" => "cash",
                 "amount" => "1.50"
               }
             ]

      assert entry.changed_fields["after"] == [
               %{
                 "fare_product_id" => "local_ride",
                 "rider_category_id" => "adult",
                 "fare_media_id" => "cash",
                 "amount" => "1.75"
               }
             ]

      # The editor's read side agrees with the row that was written.
      {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)
      assert [fare] = workspace.fares
      assert Decimal.equal?(fare.prices["adult"], Decimal.new("1.75"))
    end

    test "reads what an operator typed and rounds to the currency's minor units", context do
      # R9 accepts 1.5, 1.50, $1.50, .5 and Free, and stores the amount in the
      # currency's minor units, so $2.005 is $2.01 and "Free" is a stored zero
      # rather than a missing row.
      assert {:ok, _result} = save(context, [adult_cell(Decimal.new("1.50"), "$2.005")])
      assert amount(context, "adult") == Decimal.new("2.01")

      assert {:ok, _result} = save(context, [adult_cell(Decimal.new("2.01"), "Free")])
      assert amount(context, "adult") == Decimal.new("0")
    end

    test "refuses a mistyped or negative cell and writes nothing", context do
      # R9's counterexamples: 1.5.0 and -1.00. A negative is refused here rather
      # than stored, because only the transfer-fee writer may store one.
      assert {:error, :invalid_price} = save(context, [adult_cell(Decimal.new("1.50"), "$")])
      assert {:error, :invalid_price} = save(context, [adult_cell(Decimal.new("1.50"), "1.5.0")])
      assert {:error, :invalid_price} = save(context, [adult_cell(Decimal.new("1.50"), "-1.00")])

      assert amount(context, "adult") == Decimal.new("1.50")
      assert fare_logs(context, "updated") == []
    end

    test "refuses a save of no cells", context do
      assert {:error, :no_prices} = Fares.save_prices(context.scope, [])

      assert fare_logs(context, "updated") == []
    end
  end

  describe "the reviewed amount" do
    test "a stored amount that is not the reviewed one refuses the whole save", context do
      # Somebody else saved $1.60 first.
      assert {:ok, _result} = save(context, [adult_cell(Decimal.new("1.50"), "1.60")])

      assert {:error, {:stale, [stale]}} =
               save(context, [
                 adult_cell(Decimal.new("1.50"), "1.75"),
                 cell("local_ride", "reduced", "0.90", Decimal.new("0.75"))
               ])

      assert stale.fare_product_id == "local_ride"
      assert stale.rider_category_id == "adult"
      assert stale.fare_media_id == "cash"
      assert Decimal.equal?(stale.reviewed, Decimal.new("1.50"))
      assert Decimal.equal?(stale.stored, Decimal.new("1.60"))

      # Only the one cell is named, because the reduced rider's cell still held
      # what the editor reviewed.
      assert {:error, {:stale, [only]}} =
               save(context, [adult_cell(Decimal.new("1.50"), "1.75")])

      assert only.rider_category_id == "adult"

      # Nothing at all was written, so the current cell's $0.90 is not stored
      # either and the stale cell still reads $1.60.
      assert amount(context, "adult") == Decimal.new("1.60")
      assert amount(context, "reduced") == Decimal.new("0.75")

      # One entry, the one that stored $1.60.
      assert [entry] = fare_logs(context, "updated")

      assert entry.changed_fields["after"] == [
               %{
                 "fare_product_id" => "local_ride",
                 "rider_category_id" => "adult",
                 "fare_media_id" => "cash",
                 "amount" => "1.60"
               }
             ]
    end

    test "a row the editor saw is gone is stale too", context do
      # Blank means not sold: the reduced row is deleted, so a cell that
      # reviewed $0.75 asks to change a row that is no longer there.
      assert {:ok, _result} =
               save(context, [cell("local_ride", "reduced", nil, Decimal.new("0.75"))])

      assert amount(context, "reduced") == nil

      assert {:error, {:stale, [stale]}} =
               save(context, [cell("local_ride", "reduced", "0.90", Decimal.new("0.75"))])

      assert is_nil(stale.stored)
      assert amount(context, "reduced") == nil
    end
  end

  describe "undo" do
    test "a blank cell deletes the row and undo puts it back", context do
      before_row = price_row(context, "adult")

      assert {:ok, _updated} = save(context, [adult_cell(Decimal.new("1.50"), "1.75")])
      assert {:ok, deleted} = save(context, [adult_cell(Decimal.new("1.75"), "")])
      assert amount(context, "adult") == nil

      assert {:ok, undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)
      assert undone.operation_id == deleted.operation_id
      assert undone.inverse == nil

      # The row comes back with the amount it held and the id it had, so a
      # `fare_leg_rules` row naming the product finds the same row.
      restored = price_row(context, "adult")
      assert restored.id == before_row.id
      assert Decimal.equal?(restored.amount, Decimal.new("1.75"))

      # The reversal names the entry it reverses.
      assert [rolled_back] = fare_logs(context, "rolled_back")
      assert rolled_back.rolled_back_to_log_id == deleted.operation_id
      assert rolled_back.changed_fields["operation_id"] == deleted.operation_id
    end

    test "undoing a changed row restores the amount it held", context do
      assert {:ok, result} = save(context, [adult_cell(Decimal.new("1.50"), "1.75")])
      assert amount(context, "adult") == Decimal.new("1.75")

      assert {:ok, _undone} = Fares.undo(context.scope, result.operation_id, result.inverse)
      assert amount(context, "adult") == Decimal.new("1.50")
    end

    test "a later save of the same cell makes the reversal stale", context do
      assert {:ok, first} = save(context, [adult_cell(Decimal.new("1.50"), "1.60")])
      assert {:ok, _second} = save(context, [adult_cell(Decimal.new("1.60"), "1.70")])

      assert {:error, :stale} = Fares.undo(context.scope, first.operation_id, first.inverse)

      # The later save stands: undo never reverts somebody else's edit.
      assert amount(context, "adult") == Decimal.new("1.70")
      assert fare_logs(context, "rolled_back") == []
    end

    test "an operation this version never recorded is stale", context do
      assert {:ok, result} = save(context, [adult_cell(Decimal.new("1.50"), "1.75")])

      assert {:error, :stale} = Fares.undo(context.scope, Ecto.UUID.generate(), result.inverse)

      assert amount(context, "adult") == Decimal.new("1.75")
    end

    test "an inverse no writer of this package produced is refused", context do
      assert {:error, :unknown_inverse} =
               Fares.undo(context.scope, Ecto.UUID.generate(), :whatever)
    end
  end

  describe "a price for a rider the fare is not sold to" do
    test "creates the row and undo removes it again", context do
      # A converted older-format version sells each fare to the one Adult
      # default, so the grid's reduced-rider cell is blank until it is priced.
      older = gtfs_version_fixture(context.organization.id, %{name: "North Coast v1 prices"})
      import!(context.organization, older, "north_coast_v1")
      older_scope = scope_for(context, older.id)
      {:ok, preview} = Conversion.preview(context.organization.id, older.id)
      assert {:ok, _converted} = Conversion.apply(older_scope, preview.fingerprint, [])

      added = %{
        fare_product_id: "LOCAL",
        rider_category_id: "reduced",
        fare_media_id: "cash",
        reviewed: nil,
        amount: "0.75"
      }

      assert {:ok, result} = Fares.save_prices(older_scope, [added])

      [row] =
        context
        |> products(older.id)
        |> Enum.filter(&(&1.rider_category_id == "reduced" and &1.fare_product_id == "LOCAL"))

      assert Decimal.equal?(row.amount, Decimal.new("0.75"))
      # The fare keeps one name and one currency across its riders.
      assert row.fare_product_name == "LOCAL"
      assert row.currency == "USD"

      assert {:ok, _undone} = Fares.undo(older_scope, result.operation_id, result.inverse)

      assert context
             |> products(older.id)
             |> Enum.filter(&(&1.rider_category_id == "reduced")) == []
    end
  end

  describe "the scope" do
    test "a product of another organization is not found", context do
      other = organization_fixture(%{alias: "fares-prices-other-#{unique_alias()}"})
      other_version = gtfs_version_fixture(other.id, %{name: "Other fares"})
      import!(other, other_version, "no_fare")

      other_scope = scope(other, other_version, editor_fixture(other))

      assert {:ok, _result} =
               Conversion.setup(other_scope, %{
                 kind: :route,
                 groups: [{"Local", "1.50"}, {"Intercity", "6.00"}],
                 reduced: false,
                 youth: false,
                 child: false,
                 transfer_minutes: nil
               })

      # "intercity_ride" names a product of the other organization; this version
      # holds no product by that name, so nothing of it is written here.
      assert {:error, :not_found} =
               save(context, [cell("intercity_ride", "adult", "7.00", Decimal.new("6.00"))])

      assert price_amounts(context) == %{
               "adult" => Decimal.new("1.50"),
               "child" => Decimal.new("0"),
               "reduced" => Decimal.new("0.75")
             }

      assert fare_logs(context, "updated") == []
    end

    test "a version that is not published is refused with nothing written", context do
      {:ok, staging} =
        GtfsPlanner.Versions.create_staging_gtfs_version(context.organization.id, %{
          name: "Staging prices"
        })

      assert {:error, :not_found} =
               Fares.save_prices(
                 scope_for(context, staging.id),
                 [adult_cell(Decimal.new("1.50"), "1.75")]
               )

      assert fare_logs(context, "updated") == []
    end

    test "a version that is not managed is refused", context do
      unmanaged = gtfs_version_fixture(context.organization.id, %{name: "Unmanaged prices"})
      import!(context.organization, unmanaged, "no_fare")

      assert {:error, :unmanaged} =
               Fares.save_prices(
                 scope_for(context, unmanaged.id),
                 [cell("local_ride", "adult", "1.75", nil)]
               )

      refute Fares.managed?(context.organization.id, unmanaged.id)
      assert products(context, unmanaged.id) == []
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # A first-use setup with one "Local ride" fare: $1.50 adult, half of it to the
  # nearest nickel for the reduced rider, nothing for the child.
  defp flat_answers do
    %{
      kind: :flat,
      adult: Decimal.new("1.50"),
      reduced: true,
      youth: false,
      child: true,
      transfer_minutes: 90
    }
  end

  defp cell(product_id, rider_id, amount, reviewed) do
    %{
      fare_product_id: product_id,
      rider_category_id: rider_id,
      fare_media_id: "cash",
      reviewed: reviewed,
      amount: amount
    }
  end

  defp adult_cell(reviewed, amount), do: cell("local_ride", "adult", amount, reviewed)

  defp save(context, cells), do: Fares.save_prices(context.scope, cells)

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

  # The same scope pointed at another version of the same organization, so a
  # refusal can be asked of that version.
  defp scope_for(context, gtfs_version_id) do
    %{
      context.scope
      | gtfs_version_id: gtfs_version_id,
        audit: %{context.scope.audit | gtfs_version_id: gtfs_version_id}
    }
  end

  # A per-run alias suffix, so this file's organizations never collide with rows
  # another run left on the shared test partition.
  defp unique_alias do
    "s29-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp amount(context, rider_id) do
    case price_row(context, rider_id) do
      nil -> nil
      row -> row.amount
    end
  end

  defp price_row(context, rider_id) do
    Enum.find(products(context, context.version.id), &(&1.rider_category_id == rider_id))
  end

  defp products(context, gtfs_version_id) do
    organization_id = context.organization.id

    FareProduct
    |> where(
      [p],
      p.organization_id == ^organization_id and p.gtfs_version_id == ^gtfs_version_id
    )
    |> Repo.all()
  end

  # `numeric` columns keep no scale, so a stored zero reads back as `0` and not
  # as `0.00`. The map is keyed by rider type id because row order is Postgres's.
  defp price_amounts(context) do
    context
    |> products(context.version.id)
    |> Map.new(&{&1.rider_category_id, &1.amount})
  end

  defp fare_logs(context, action) do
    organization_id = context.organization.id
    gtfs_version_id = context.version.id

    ChangeLog
    |> where(
      [log],
      log.organization_id == ^organization_id and log.gtfs_version_id == ^gtfs_version_id and
        log.entity_type == "fare_version" and log.action == ^action
    )
    |> Repo.all()
  end
end

defmodule GtfsPlanner.Gtfs.Fares.PriceChangeTest do
  @moduledoc """
  Merge evidence (EV-16) for `Fares.preview_price_change/3` and
  `Fares.apply_price_change/3`, the Change prices dialog's pair (AC-15).

  Every expected value is worked by hand from the spec and the fixtures, not
  read back from the code under test:

  - a flat first-use setup prices one "Local ride" fare at $1.50 for the adult
    rider, half of it to the nearest nickel ($0.75) for the reduced rider and
    nothing for the child, so +$0.25 rounded to the nearest nickel gives the
    adult $1.75 and, kept at half, the reduced rider $0.90 — $1.75 is $0.875,
    which is 17.5 nickels, which rounds up to 18 — while the child's free price
    is not in the answer at all;
  - the North Coast v1 feed carries `COAST,3.50`, and 10% of $3.50 is $3.85,
    which is 15.4 quarters and rounds down to 15 quarters, or $3.75.

  The version enters rows the way a user's version does — through the production
  importer of `test/fixtures/gtfs/fares/no_fare` and `north_coast_v1` and then the
  production first-use setup and v1 conversion — and every write runs inside
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
    organization = organization_fixture(%{alias: "fares-change-#{unique_alias()}"})
    actor = editor_fixture(organization)
    version = gtfs_version_fixture(organization.id, %{name: "Fare change version"})
    import!(organization, version, "no_fare")

    context = %{
      organization: organization,
      version: version,
      actor: actor,
      scope: scope(organization, version, actor)
    }

    {:ok, _setup} = Conversion.setup(context.scope, flat_answers())

    context
  end

  describe "previewing a change" do
    test "raises the adult price and keeps the reduced rider at half of it", context do
      rows = preview(context, flat_change("0.25"))

      # +$0.25 on $1.50 is $1.75, and the reduced rider is half of the new adult
      # price to the nearest nickel: $0.875 is 17.5 nickels, which rounds to 18.
      assert [
               %{
                 fare_product_id: "local_ride",
                 rider_category_id: "adult",
                 fare_media_id: "cash",
                 now: adult_now,
                 new: adult_new
               },
               %{
                 fare_product_id: "local_ride",
                 rider_category_id: "reduced",
                 fare_media_id: "cash",
                 now: reduced_now,
                 new: reduced_new
               }
             ] = rows

      assert Decimal.equal?(adult_now, Decimal.new("1.50"))
      assert Decimal.equal?(adult_new, Decimal.new("1.75"))
      assert Decimal.equal?(reduced_now, Decimal.new("0.75"))
      assert Decimal.equal?(reduced_new, Decimal.new("0.90"))

      # The child rides free, so no row names it: a free price stays free.
      refute Enum.any?(rows, &(&1.rider_category_id == "child"))

      # A preview writes nothing.
      assert amount(context, "adult") == Decimal.new("1.50")
      assert amount(context, "reduced") == Decimal.new("0.75")
    end

    test "a percentage moves an imported fare's price to the chosen step", context do
      imported = convert_v1(context)

      rows =
        preview(imported, %{
          scope: :single,
          riders: ["adult"],
          how: :percent,
          value: "10",
          round: "0.25",
          half_reduced?: false
        })

      # `COAST,3.50` in the feed: 10% is $3.85, which is 15.4 quarters and so
      # rounds down to $3.75.
      coast = Enum.find(rows, &(&1.fare_product_id == "COAST"))
      assert Decimal.equal?(coast.now, Decimal.new("3.50"))
      assert Decimal.equal?(coast.new, Decimal.new("3.75"))
    end

    test "moves only the fares and riders the dialog chose", context do
      assert [_adult, _reduced] = preview(context, flat_change("0.25"))

      # Without the half-fare rule each rider moves by its own price, so the
      # reduced rider goes from $0.75 to $1.00 rather than to half the adult.
      unhalved =
        preview(context, %{flat_change("0.25") | half_reduced?: false})

      assert Decimal.equal?(
               Enum.find(unhalved, &(&1.rider_category_id == "reduced")).new,
               Decimal.new("1.00")
             )

      # A rider type the dialog did not choose is not in the answer at all.
      adult_only = preview(context, %{flat_change("0.25") | riders: ["adult"]})
      assert [%{rider_category_id: "adult"}] = adult_only

      # And a change nobody's price moves previews nothing: the setup's reduced
      # price is already half its adult price, so neither row moves.
      assert preview(context, flat_change("0")) == []
    end
  end

  describe "applying a previewed change" do
    test "writes exactly the rows the preview showed", context do
      rows = preview(context, flat_change("0.25"))

      assert {:ok, result} = Fares.apply_price_change(context.scope, flat_change("0.25"), rows)

      assert price_amounts(context) == %{
               "adult" => Decimal.new("1.75"),
               "reduced" => Decimal.new("0.90"),
               "child" => Decimal.new("0")
             }

      assert [entry] = fare_logs(context, "updated")
      assert entry.id == result.operation_id
      assert entry.changed_fields["summary"] == "Changed 2 prices with Change prices"

      # The rows the entry records are the previewed rows, before and after.
      assert entry.changed_fields["before"] == [
               %{
                 "fare_product_id" => "local_ride",
                 "rider_category_id" => "adult",
                 "fare_media_id" => "cash",
                 "amount" => "1.50"
               },
               %{
                 "fare_product_id" => "local_ride",
                 "rider_category_id" => "reduced",
                 "fare_media_id" => "cash",
                 "amount" => "0.75"
               }
             ]

      assert entry.changed_fields["after"] == [
               %{
                 "fare_product_id" => "local_ride",
                 "rider_category_id" => "adult",
                 "fare_media_id" => "cash",
                 "amount" => "1.75"
               },
               %{
                 "fare_product_id" => "local_ride",
                 "rider_category_id" => "reduced",
                 "fare_media_id" => "cash",
                 "amount" => "0.90"
               }
             ]

      # The inverse is the price inverse `undo/3` already applies, so the dialog's
      # Undo reverses the change it was offered.
      assert {:ok, _undone} = Fares.undo(context.scope, result.operation_id, result.inverse)

      assert price_amounts(context) == %{
               "adult" => Decimal.new("1.50"),
               "reduced" => Decimal.new("0.75"),
               "child" => Decimal.new("0")
             }
    end

    test "a row changed since the preview refuses the whole change", context do
      rows = preview(context, flat_change("0.25"))

      # Somebody saved the adult price first, so the preview's $1.50 is stale.
      assert {:ok, _result} =
               Fares.save_prices(context.scope, [
                 cell("adult", Decimal.new("1.50"), "1.60")
               ])

      assert {:error, {:stale, [stale]}} =
               Fares.apply_price_change(context.scope, flat_change("0.25"), rows)

      assert stale.fare_product_id == "local_ride"
      assert stale.rider_category_id == "adult"
      assert Decimal.equal?(stale.stored, Decimal.new("1.60"))

      # The stale row refused the whole change, so the reduced row the preview
      # showed is untouched too, and no second entry was recorded.
      assert amount(context, "reduced") == Decimal.new("0.75")
      assert length(fare_logs(context, "updated")) == 1
    end

    test "an empty preview is a change of nothing", context do
      assert preview(context, flat_change("0")) == []

      assert {:error, :no_prices} =
               Fares.apply_price_change(context.scope, flat_change("0"), [])

      assert fare_logs(context, "updated") == []
    end
  end

  # -- Helpers ------------------------------------------------------------------

  # +$0.25 on every single-ride price of the three rider types the setup made,
  # rounded to the nearest nickel, keeping the reduced rider at half.
  defp flat_change(value) do
    %{
      scope: :single,
      riders: ["adult", "reduced", "child"],
      how: :amount,
      value: value,
      round: "0.05",
      half_reduced?: true
    }
  end

  defp preview(context, options) do
    Fares.preview_price_change(context.organization.id, context.version.id, options)
  end

  # A second version of the same organization, imported from the North Coast v1
  # feed and converted, so its prices are the ones the feed carries rather than
  # the ones the first-use setup asked for.
  defp convert_v1(context) do
    version = gtfs_version_fixture(context.organization.id, %{name: "Imported fares"})
    import!(context.organization, version, "north_coast_v1")

    imported = %{
      context
      | version: version,
        scope: scope(context.organization, version, context.actor)
    }

    {:ok, plan} = Conversion.preview(imported.organization.id, version.id)
    {:ok, _result} = Conversion.apply(imported.scope, plan.fingerprint, [])

    imported
  end

  defp cell(rider_id, reviewed, amount) do
    %{
      fare_product_id: "local_ride",
      rider_category_id: rider_id,
      fare_media_id: "cash",
      reviewed: reviewed,
      amount: amount
    }
  end

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

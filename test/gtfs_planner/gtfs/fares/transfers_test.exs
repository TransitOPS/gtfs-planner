defmodule GtfsPlanner.Gtfs.Fares.TransfersTest do
  @moduledoc """
  Merge evidence (EV-22) for `Fares.Transfers.save/5` and the inverse
  `Fares.undo/3` applies (AC-23, AC-26, R5, R6, R15, FH-22, INV-1, INV-4, INV-5).

  Every expected value is worked by hand from
  `test/fixtures/gtfs/fares/north_coast_v2` and from the GTFS reference, never read
  back from the code under test (CR-2):

  - the fixture declares two networks, `N_LOCAL` "Local routes" and `N_INTERCITY`
    "Intercity". After the production v2 conversion the version's leg rules are the
    fixture's forty-six: 39 naming `N_LOCAL`, 4 naming `N_INTERCITY` (the Intercity
    ride's four rider types) and 3 naming no network (the 31-day pass).
  - the five single rides are `Local ride`, `Valley ride`, `Coast ride`,
    `Valley coast ride` and `Intercity ride`, each one `fare_product_name` over
    four rider rows. `N_LOCAL` is priced by the first four and `N_INTERCITY` by the
    Intercity ride alone.
  - the adult cash amounts, which the R6 guard compares: Local $1.50, Valley
    $2.50, Coast $3.50, Valley coast $5.00, Intercity $6.00. So `N_LOCAL ->
    N_INTERCITY` may be a difference ($6.00 covers every origin amount, $5.00 being
    the largest), and a `$3.00` shuttle group may not (it is below every one of the
    origin's adult cash amounts).
  - R5's `duration_limit` is in seconds: 90 minutes is `5400`. R5's basis `1`
    measures from the first departure and is the default.
  - R5 writes `transfer_count` only where the two leg groups are the same one, so
    a cross-group row carries `nil` whatever the drawer's count was.

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3` with `Fares.Normalize.run!/2`
  before the commit, which is the path every writer of this package takes.
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Repo

  # A Monday inside the sample's calendar span, for the Pricing check.
  @monday ~D[2026-10-05]

  # `N_LOCAL -> N_LOCAL`, free for 90 minutes and two free changes: R5's
  # same-group row, `(local, local, nil, 2, 5400, 1, 0)` in the prepared case.
  @local_free %{pay: :free, minutes: 90, count: 2}

  setup do
    organization =
      organization_fixture(%{alias: "fares-transfers-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      user_fixture(%{
        email: "fares-transfers-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast fares editor"})
    import!(organization, version, "north_coast_v2")

    context = %{
      organization: organization,
      version: version,
      scope: scope(organization, version, actor)
    }

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(context.scope, plan.fingerprint, [])

    context
  end

  describe "a free policy between two groups" do
    test "writes the pair's type 0 row, and the count only where both groups are one", context do
      assert {:ok, saved} = Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", @local_free, nil)

      assert saved.inverse.transfer.from == "N_LOCAL"
      assert saved.inverse.transfer.to == "N_LOCAL"
      assert saved.inverse.transfer.removed == []

      # The prepared case: `local -> local`, no product, two free changes, 90
      # minutes as 5400 seconds, basis 1, and type 0.
      assert rule(context, "N_LOCAL", "N_LOCAL") == %{
               from_leg_group_id: "N_LOCAL",
               to_leg_group_id: "N_LOCAL",
               transfer_count: 2,
               duration_limit: 5400,
               duration_limit_type: 1,
               fare_transfer_type: 0,
               fare_product_id: nil
             }

      # A different pair carries no count at all, whatever the drawer held.
      assert {:ok, _cross} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :free, minutes: 45, count: 7},
                 nil
               )

      assert rule(context, "N_LOCAL", "N_INTERCITY").transfer_count == nil
    end

    test "a pair carries one policy, so a second save replaces the first row", context do
      assert {:ok, _first} = Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", @local_free, nil)

      assert {:ok, second} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :free, minutes: 45},
                 nil
               )

      rows = transfer_rows(context, "N_LOCAL", "N_LOCAL")

      assert length(rows) == 1
      assert Enum.map(rows, & &1.duration_limit) == [2700]
      assert Enum.map(rows, & &1.transfer_count) == [nil]
      assert [replaced] = second.inverse.transfer.removed
      assert replaced.duration_limit == 5400
    end
  end

  describe "a difference policy" do
    test "names the destination's own single-ride product on a type 2 row", context do
      assert {:ok, _saved} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :difference, minutes: 90},
                 nil
               )

      # The Intercity ride is the only fare `N_INTERCITY` is priced by, and the
      # default rider type is `adult` on `cash`, so the row names the Intercity
      # ride's adult cash product (R5, R6).
      assert rule(context, "N_LOCAL", "N_INTERCITY") == %{
               from_leg_group_id: "N_LOCAL",
               to_leg_group_id: "N_INTERCITY",
               transfer_count: nil,
               duration_limit: 5400,
               duration_limit_type: 1,
               fare_transfer_type: 2,
               fare_product_id: "intercity_ride_adult_cash"
             }
    end

    test "a destination cheaper than the origin is refused and writes nothing", context do
      shuttle = shuttle_group(context, "3.00")

      # The prepared case: a `$3.00` shuttle group against an origin whose adult
      # cash fares run to `$5.00`, so a difference could undercharge (R6).
      assert {:error, :difference_not_expressible} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 shuttle,
                 %{pay: :difference, minutes: 90},
                 nil
               )

      assert transfer_rows(context, "N_LOCAL", shuttle) == []
    end

    test "a destination group charging two single rides is refused", context do
      two_fares = two_fare_group(context, "6.00", "7.00")

      # The group is priced by two fares, both dearer than every origin amount,
      # and a type 2 row cannot say which of the two the rider should pay the
      # difference against (R6).
      assert {:error, :difference_not_expressible} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 two_fares,
                 %{pay: :difference, minutes: 90},
                 nil
               )

      assert transfer_rows(context, "N_LOCAL", two_fares) == []
    end
  end

  describe "a fee policy" do
    test "writes a transfer_fee product and a type 0 row naming it", context do
      assert {:ok, saved} =
               Transfers.save(
                 context.scope,
                 "N_INTERCITY",
                 "N_LOCAL",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      # The prepared case: `$0.25` as a `transfer_fee` product and a type 0 row.
      assert rule(context, "N_INTERCITY", "N_LOCAL") == %{
               from_leg_group_id: "N_INTERCITY",
               to_leg_group_id: "N_LOCAL",
               transfer_count: nil,
               duration_limit: 3600,
               duration_limit_type: 1,
               fare_transfer_type: 0,
               fare_product_id: "fee_N_INTERCITY_N_LOCAL"
             }

      # The fee is one row naming no rider type and no payment method, which GTFS
      # reads as the fee for every rider on every method, in the version's
      # currency.
      assert fee_product(context, "fee_N_INTERCITY_N_LOCAL") == %{
               amount: Decimal.new("0.25"),
               currency: "USD",
               rider_category_id: nil,
               fare_media_id: nil
             }

      assert fee_detail(context, "fee_N_INTERCITY_N_LOCAL") == %{
               kind: "transfer_fee",
               position: 0,
               accepted_network_ids: []
             }

      assert saved.inverse.transfer.fee_after == %{
               product_id: "fee_N_INTERCITY_N_LOCAL",
               id: fee_product_id(context, "fee_N_INTERCITY_N_LOCAL"),
               amount: Decimal.new("0.25")
             }

      assert saved.inverse.transfer.fee_before == %{product: nil, detail: nil}
    end

    test "a fee with no readable amount is refused and writes no product", context do
      assert {:error, :invalid_price} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60},
                 nil
               )

      assert fee_products(context) == []
      assert transfer_rows(context, "N_LOCAL", "N_INTERCITY") == []

      assert {:error, :invalid_price} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: "not money"},
                 nil
               )

      assert fee_products(context) == []
    end

    test "a second fee on the same pair reuses the product and updates its amount", context do
      assert {:ok, first} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      assert {:ok, second} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: "0.50"},
                 nil
               )

      assert fee_products(context) == ["fee_N_LOCAL_N_INTERCITY"]

      assert fee_product(context, "fee_N_LOCAL_N_INTERCITY").amount == Decimal.new("0.50")

      # The product this writer created is in the second save's inverse, so it
      # can be put back the way it was.
      assert is_nil(first.inverse.transfer.fee_before.product)
      assert second.inverse.transfer.fee_before.product.amount == Decimal.new("0.25")
      assert second.inverse.transfer.fee_after.amount == Decimal.new("0.50")
    end
  end

  describe "a full policy" do
    test "leaves the pair with no row and takes the fee product with it", context do
      assert {:ok, _fee} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      assert fee_products(context) == ["fee_N_LOCAL_N_INTERCITY"]

      # The prepared case: `full` leaves the pair with no row at all, and the fee
      # product goes with it, so the export never carries a fee nobody is charged.
      assert {:ok, removed} =
               Transfers.save(context.scope, "N_LOCAL", "N_INTERCITY", %{pay: :full}, nil)

      assert transfer_rows(context, "N_LOCAL", "N_INTERCITY") == []
      assert fee_products(context) == []
      assert fee_details(context) == []

      assert [gone] = removed.inverse.transfer.removed
      assert gone.fare_product_id == "fee_N_LOCAL_N_INTERCITY"
      assert removed.inverse.transfer.added == nil
      assert removed.inverse.transfer.fee_after == nil
      assert removed.inverse.transfer.fee_before.product.amount == Decimal.new("0.25")
    end

    test "a fee another rule still names is left in place", context do
      assert {:ok, _fee} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      # The same fee product is now the fee of a second pair too, so removing
      # the first pair's policy must not take it away from the second (R5).
      assert {:ok, _other} =
               Transfers.save(
                 context.scope,
                 "N_INTERCITY",
                 "N_LOCAL",
                 %{pay: :fee, minutes: 60, fee: "0.25"},
                 nil
               )

      assert {:ok, _full} =
               Transfers.save(context.scope, "N_LOCAL", "N_INTERCITY", %{pay: :full}, nil)

      assert fee_products(context) == ["fee_N_INTERCITY_N_LOCAL"]
    end
  end

  describe "what the write is fenced against" do
    test "a policy that moved since the drawer opened is refused", context do
      assert {:ok, _saved} = Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", @local_free, nil)

      # The drawer showed the pair as it is stored, so this save is allowed.
      assert {:ok, _same} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :free, minutes: 120},
                 %{pay: :free, minutes: 90, count: 2}
               )

      # The drawer showed two free changes, and the stored rule allows none, so
      # the count has moved (R15).
      assert {:error, {:stale, stale}} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :free, minutes: 30},
                 %{pay: :free, minutes: 120, count: 2}
               )

      assert stale == [%{field: :count, reviewed: 2, stored: nil}]

      # Nothing was written by the refused save.
      assert rule(context, "N_LOCAL", "N_LOCAL").duration_limit == 7200
    end

    test "a fee is compared as an amount however either side spells it", context do
      assert {:ok, _saved} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      # The same fee the drawer showed, read back as the string the grid sends,
      # is the same fact and does not fence the save.
      assert {:ok, _same} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 90, fee: "0.50"},
                 %{
                   pay: :fee,
                   minutes: 60,
                   fee: "fee_N_LOCAL_N_INTERCITY"
                 }
               )

      assert {:error, {:stale, [fee]}} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 120, fee: "0.50"},
                 %{pay: :fee, minutes: 90, fee: Decimal.new("1.00")}
               )

      assert fee.field == :fee
      assert fee.reviewed == Decimal.new("1.00")
      assert fee.stored == "fee_N_LOCAL_N_INTERCITY"
    end

    test "an unmanaged version and a version that is not published are refused", context do
      assert {:error, :unmanaged} =
               Transfers.save(unmanaged_scope(context), "N_LOCAL", "N_LOCAL", @local_free, nil)

      assert {:error, :not_found} =
               Transfers.save(staging_scope(context), "N_LOCAL", "N_LOCAL", @local_free, nil)

      assert transfer_rows(context, "N_LOCAL", "N_LOCAL") == []
    end

    test "a leg group this version does not hold is refused", context do
      # Another version's group, or an id no version of this organization holds,
      # is never written through this writer (AC-26, INV-5).
      assert {:error, :not_found} =
               Transfers.save(context.scope, "N_LOCAL", "N_NOWHERE", @local_free, nil)

      assert {:error, :not_found} =
               Transfers.save(context.scope, "N_NOWHERE", "N_LOCAL", @local_free, nil)

      assert transfer_rows(context, "N_LOCAL", "N_NOWHERE") == []
      assert transfer_rows(context, "N_LOCAL", "N_LOCAL") == []

      # The fixture's imported transfer rules name `LG_LOCAL` and `LG_INTERCITY`,
      # which the conversion does not carry into this version's leg groups, so a
      # write naming one is refused rather than reaching a row no group holds.
      assert {:error, :not_found} =
               Transfers.save(context.scope, "N_LOCAL", "LG_INTERCITY", @local_free, nil)
    end

    test "a choice, a time limit and a basis the reference does not allow are refused", context do
      assert {:error, :invalid_policy} =
               Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", %{pay: :halved}, nil)

      assert {:error, :invalid_minutes} =
               Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", %{pay: :free}, nil)

      assert {:error, :invalid_minutes} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :free, minutes: 0},
                 nil
               )

      assert {:error, :invalid_basis} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :free, minutes: 90, basis: 4},
                 nil
               )

      assert {:error, :invalid_count} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :free, minutes: 90, count: 0},
                 nil
               )

      assert transfer_rows(context, "N_LOCAL", "N_LOCAL") == []
    end
  end

  describe "the change-log entry" do
    test "one entry per save, naming the pair and the choice", context do
      assert {:ok, saved} = Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", @local_free, nil)

      assert [entry] = transfer_writes(context)
      assert entry.id == saved.operation_id
      assert entry.action == "created"
      assert entry.entity_type == "fare_version"
      assert entry.entity_external_id == "fares"

      assert entry.changed_fields["summary"] ==
               "Set the Local routes to Local routes transfer to be free for 90 minutes"

      assert [after_row] = entry.changed_fields["after"]
      assert after_row["duration_limit"] == 5400
      assert after_row["transfer_count"] == 2
      assert entry.changed_fields["before"] == []
    end

    test "a fee entry names the amount, a full entry is a deletion", context do
      assert {:ok, _fee} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      assert [entry] = transfer_writes(context)
      assert entry.action == "created"

      assert entry.changed_fields["summary"] ==
               "Set the Local routes to Intercity transfer to charge $0.25"

      assert [rule_row, fee_row] = entry.changed_fields["after"]
      assert rule_row["fare_product_id"] == "fee_N_LOCAL_N_INTERCITY"
      assert fee_row == %{"transfer_fee" => "fee_N_LOCAL_N_INTERCITY", "amount" => "0.25"}

      assert {:ok, _full} =
               Transfers.save(context.scope, "N_LOCAL", "N_INTERCITY", %{pay: :full}, nil)

      assert [deletion] =
               transfer_writes(context) |> Enum.filter(&(&1.action == "deleted"))

      assert deletion.changed_fields["summary"] ==
               "Removed the Local routes to Intercity transfer policy"

      assert deletion.changed_fields["after"] == []
      assert [gone] = deletion.changed_fields["before"]
      assert gone["fare_product_id"] == "fee_N_LOCAL_N_INTERCITY"
    end
  end

  describe "undoing a transfer change" do
    test "a replacement puts the pair's own rule back", context do
      assert {:ok, _first} = Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", @local_free, nil)

      assert {:ok, second} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :free, minutes: 45},
                 nil
               )

      assert {:ok, _undone} = Fares.undo(context.scope, second.operation_id, second.inverse)

      assert rule(context, "N_LOCAL", "N_LOCAL") == %{
               from_leg_group_id: "N_LOCAL",
               to_leg_group_id: "N_LOCAL",
               transfer_count: 2,
               duration_limit: 5400,
               duration_limit_type: 1,
               fare_transfer_type: 0,
               fare_product_id: nil
             }

      # R15: a second reversal of the same operation is stale, not applied twice.
      assert {:error, :stale} = Fares.undo(context.scope, second.operation_id, second.inverse)

      assert transfer_writes(context) |> Enum.filter(&(&1.action == "rolled_back")) |> length() ==
               1

      assert [rollback] =
               transfer_writes(context) |> Enum.filter(&(&1.action == "rolled_back"))

      assert rollback.rolled_back_to_log_id == second.operation_id
      assert rollback.actor_email == context.scope.audit.actor_email
    end

    test "a fee reversal puts the pair's rule and fee back", context do
      assert {:ok, saved} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      assert {:ok, _undone} = Fares.undo(context.scope, saved.operation_id, saved.inverse)

      assert transfer_rows(context, "N_LOCAL", "N_INTERCITY") == []
      assert fee_products(context) == []
      assert fee_details(context) == []
    end

    test "a fee reversal restores the amount the write replaced", context do
      assert {:ok, first} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      assert {:ok, second} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: "0.50"},
                 nil
               )

      assert {:ok, _undone} = Fares.undo(context.scope, second.operation_id, second.inverse)

      assert fee_product(context, "fee_N_LOCAL_N_INTERCITY").amount == Decimal.new("0.25")

      assert rule(context, "N_LOCAL", "N_INTERCITY").fare_product_id ==
               first.inverse.transfer.fee_after.product_id

      # The first save's own reversal is still available after it.
      assert {:ok, _undone_first} = Fares.undo(context.scope, first.operation_id, first.inverse)

      assert transfer_rows(context, "N_LOCAL", "N_INTERCITY") == []
      assert fee_products(context) == []
    end

    test "an edit made since is not reverted", context do
      assert {:ok, first} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: Decimal.new("0.25")},
                 nil
               )

      assert {:ok, second} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :fee, minutes: 60, fee: "0.50"},
                 nil
               )

      assert {:error, :stale} = Fares.undo(context.scope, first.operation_id, first.inverse)

      assert fee_product(context, "fee_N_LOCAL_N_INTERCITY").amount == Decimal.new("0.50")

      assert rule(context, "N_LOCAL", "N_INTERCITY").fare_product_id ==
               second.inverse.transfer.fee_after.product_id
    end

    test "an inverse no writer of this package produced is refused", context do
      assert {:error, :unknown_inverse} =
               Fares.undo(context.scope, Ecto.UUID.generate(), %{invented: []})
    end
  end

  describe "what the written rows price" do
    test "a third local change inside the limit is charged again", context do
      assert {:ok, _saved} = Transfers.save(context.scope, "N_LOCAL", "N_LOCAL", @local_free, nil)

      result =
        Pricing.price_journey(
          Interpreter.load_rows(context.organization.id, context.version.id),
          %{
            rider_category_id: "adult",
            fare_media_id: "cash",
            service_date: @monday,
            legs: four_local_rides()
          }
        )

      assert result.problems == []

      # The prepared case: the first Local ride opens the fare at $1.50, the
      # second and third rides are inside the 90-minute limit and within the two
      # free changes the rule allows, and the fourth is change 3, which the rule
      # does not cover, so it opens a new fare at $1.50 again.
      assert Enum.map(result.legs, & &1.charged) == [
               Decimal.new("1.50"),
               Decimal.new("0"),
               Decimal.new("0"),
               Decimal.new("1.50")
             ]

      assert Enum.map(result.legs, &(&1.transfer && &1.transfer.applied?)) == [
               nil,
               true,
               true,
               false
             ]

      assert Enum.at(result.legs, 3).reason =~ "Change 3"
      assert Enum.at(result.legs, 3).reason =~ "allows only 2 free changes"
      assert result.total == Decimal.new("3.00")
    end

    test "a paid fee is charged on top of the fare already paid", context do
      assert {:ok, _fee} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_LOCAL",
                 %{pay: :fee, minutes: 90, fee: Decimal.new("0.25")},
                 nil
               )

      result =
        Pricing.price_journey(
          Interpreter.load_rows(context.organization.id, context.version.id),
          %{
            rider_category_id: "adult",
            fare_media_id: "cash",
            service_date: @monday,
            legs: [
              %{
                route_id: "4",
                from_stop_id: "TOLEDO",
                to_stop_id: "NTC",
                departs: 7 * 3600 + 40 * 60,
                arrives: 8 * 3600 + 55 * 60
              },
              %{
                route_id: "2",
                from_stop_id: "NTC",
                to_stop_id: "SBPR",
                departs: 8 * 3600 + 40 * 60,
                arrives: 8 * 3600 + 55 * 60
              }
            ]
          }
        )

      assert Enum.map(result.legs, & &1.charged) == [Decimal.new("2.50"), Decimal.new("0.25")]
      assert result.total == Decimal.new("2.75")
    end
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

  defp scope_for(context, gtfs_version_id) do
    %{
      context.scope
      | gtfs_version_id: gtfs_version_id,
        audit: %{context.scope.audit | gtfs_version_id: gtfs_version_id}
    }
  end

  # A second version of the same organization, imported but never converted, so a
  # refusal can be asked of a scope that names an unmanaged version.
  defp unmanaged_scope(context) do
    version = gtfs_version_fixture(context.organization.id, %{name: "Unmanaged fares"})
    import!(context.organization, version, "north_coast_v2")
    scope_for(context, version.id)
  end

  defp staging_scope(context) do
    {:ok, staging} =
      GtfsPlanner.Versions.create_staging_gtfs_version(context.organization.id, %{
        name: "Staging fares"
      })

    scope_for(context, staging.id)
  end

  # A route group of its own, priced by one fare at `amount`, the way the
  # prepared case's `$3.00` shuttle is.
  defp shuttle_group(context, amount) do
    {group, _product_id} = group_with_fares(context, "Shuttle", [{amount, "ride", nil, nil}])
    group
  end

  # A route group priced by two fares over two different sets of conditions, both
  # dearer than every origin amount, so the only thing that could refuse the
  # difference is the count of its fares (R6).
  defp two_fare_group(context, first_amount, second_amount) do
    {group, _product_ids} =
      group_with_fares(context, "Express", [
        {first_amount, "ride", "TOL", "NPT"},
        {second_amount, "express", "NPT", "CST"}
      ])

    group
  end

  defp group_with_fares(context, name, fares) do
    {:ok, saved} = Fares.save_route_group(context.scope, %{name: name, route_ids: []})
    network_id = saved.inverse.route_group.network.after.network_id

    product_ids =
      Enum.map(fares, fn {amount, suffix, from_area_id, to_area_id} ->
        product_id = add_fare(context, "#{name} #{suffix}", amount)

        {:ok, _rule} =
          Fares.save_rule(context.scope, %{
            network_id: network_id,
            from_area_id: from_area_id,
            to_area_id: to_area_id,
            fare_product_id: product_id
          })

        product_id
      end)

    {network_id, product_ids}
  end

  defp add_fare(context, name, amount) do
    {:ok, saved} =
      Fares.save_fare(context.scope, %{
        name: name,
        kind: "single",
        media_ids: ["cash"],
        prices: %{"adult" => amount}
      })

    saved.inverse.fare.fare_product_id
  end

  # Four rides on routes the sample puts in `N_LOCAL`, each departing inside the
  # sample's 90-minute change window from the first, at the times
  # `stop_times.txt` records for those trips: 06:45, 07:20, 07:40 and 08:00.
  defp four_local_rides do
    [
      %{
        route_id: "30",
        from_stop_id: "SBPR",
        to_stop_id: "NTC",
        departs: 24_300,
        arrives: 25_200
      },
      %{
        route_id: "11",
        from_stop_id: "NTC",
        to_stop_id: "AGATE",
        departs: 26_400,
        arrives: 27_300
      },
      %{route_id: "2", from_stop_id: "NTC", to_stop_id: "SBPR", departs: 27_600, arrives: 27_900},
      %{route_id: "12", from_stop_id: "NYE", to_stop_id: "HOSP", departs: 28_800, arrives: 30_000}
    ]
  end

  defp transfer_rows(context, from, to) do
    FareTransferRule
    |> where(
      [rule],
      rule.organization_id == ^context.organization.id and
        rule.gtfs_version_id == ^context.version.id and
        rule.from_leg_group_id == ^from and rule.to_leg_group_id == ^to
    )
    |> Repo.all()
    |> Enum.sort_by(& &1.duration_limit)
    |> Enum.map(&rule_fields/1)
  end

  defp rule(context, from, to) do
    case transfer_rows(context, from, to) do
      [row] -> row
      rows -> rows
    end
  end

  defp rule_fields(rule) do
    %{
      from_leg_group_id: rule.from_leg_group_id,
      to_leg_group_id: rule.to_leg_group_id,
      transfer_count: rule.transfer_count,
      duration_limit: rule.duration_limit,
      duration_limit_type: rule.duration_limit_type,
      fare_transfer_type: rule.fare_transfer_type,
      fare_product_id: rule.fare_product_id
    }
  end

  defp fee_products(context) do
    FareProduct
    |> where(
      [product],
      product.organization_id == ^context.organization.id and
        product.gtfs_version_id == ^context.version.id and
        like(product.fare_product_id, "fee_%")
    )
    |> Repo.all()
    |> Enum.map(& &1.fare_product_id)
    |> Enum.sort()
  end

  defp fee_product_rows(context, product_id) do
    FareProduct
    |> where(
      [product],
      product.organization_id == ^context.organization.id and
        product.gtfs_version_id == ^context.version.id and
        product.fare_product_id == ^product_id
    )
    |> Repo.all()
    |> Enum.sort_by(&{&1.rider_category_id || "", &1.fare_media_id || ""})
  end

  defp fee_product_id(context, product_id) do
    case fee_product_rows(context, product_id) do
      [row] -> row.id
      rows -> rows
    end
  end

  defp fee_product(context, product_id) do
    case fee_product_rows(context, product_id) do
      [row] ->
        %{
          amount: row.amount,
          currency: row.currency,
          rider_category_id: row.rider_category_id,
          fare_media_id: row.fare_media_id
        }

      rows ->
        rows
    end
  end

  defp fee_detail(context, product_id) do
    FareProductDetail
    |> where(
      [detail],
      detail.organization_id == ^context.organization.id and
        detail.gtfs_version_id == ^context.version.id and
        detail.fare_product_id == ^product_id
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      row ->
        %{
          kind: row.kind,
          position: row.position,
          accepted_network_ids: row.accepted_network_ids
        }
    end
  end

  defp fee_details(context) do
    FareProductDetail
    |> where(
      [detail],
      detail.organization_id == ^context.organization.id and
        detail.gtfs_version_id == ^context.version.id and
        like(detail.fare_product_id, "fee_%")
    )
    |> Repo.all()
    |> Enum.map(& &1.fare_product_id)
    |> Enum.sort()
  end

  # The change-log entries this writer makes: the ones whose summary names a
  # transfer, and the reversal's own. The conversion writes a `created` entry of
  # its own for the whole version, and a fare save names a fare.
  defp transfer_writes(context) do
    entries(context)
    |> Enum.filter(&transfer_summary?/1)
    |> Enum.sort_by(& &1.inserted_at)
  end

  defp entries(context) do
    ChangeLog
    |> where(
      [log],
      log.organization_id == ^context.organization.id and
        log.gtfs_version_id == ^context.version.id and
        log.entity_type == "fare_version"
    )
    |> Repo.all()
  end

  defp transfer_summary?(%{action: "rolled_back"}), do: true

  defp transfer_summary?(entry) do
    summary = entry.changed_fields["summary"] || ""

    String.starts_with?(summary, "Set the ") or
      String.starts_with?(summary, "Removed the ") or
      String.starts_with?(summary, "Restored the transfer policy")
  end
end

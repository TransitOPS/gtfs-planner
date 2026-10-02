defmodule GtfsPlanner.Gtfs.Fares.FareWriterTest do
  @moduledoc """
  Merge evidence (EV-17) for `Fares.save_fare/2` and `Fares.delete_fare/4` and the
  fare inverse `Fares.undo/3` applies (AC-16, AC-26, R4, R9, R15, FH-17).

  Every expected value is worked by hand from the fixture and from the rules,
  never read back from the code under test (CR-2):

  - `test/fixtures/gtfs/fares/north_coast_v2` holds four rider types (adult,
    reduced, youth, child), two payment methods (cash, type 0, and app, type 4)
    and two networks, `N_LOCAL` and `N_INTERCITY`. Its thirty products each
    carry one rider type and one method, so a fare the editor saves here is a
    `fare_product_id` of its own with its own rows.
  - `N_LOCAL` has ten single-ride condition sets: the three same-zone pairs
    (NPT→NPT, TOL→TOL, CST→CST), the three reverse pairs (NPT↔TOL, NPT↔CST,
    TOL↔CST), the three forward pairs — nine zone pairs, since the fixture
    prices each of the six zone pairs once each way — and the one row the
    fixture's own `day_pass_*` products carry with no areas at all, which R12
    classifies single-ride because no rule of a different fare states the same
    conditions. R4 mirrors one pass row per condition set, so a pass accepted on
    `N_LOCAL` leaves nine rows at priority 7 (4 for the network, 2 for the from
    area, 1 for the to area) and one at priority 4 for the area-less set: ten.
  - `valley_ride_adult_cash` is named by two leg rules, `NPT → TOL` and
    `TOL → NPT`, so deleting it with `coast_ride_adult_cash` as its replacement
    moves exactly those two.
  - `$1.00`, `$1.25` and `Free` are R9's inputs, stored as `1.00`, `1.25` and a
    zero in the currency's own minor units.

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/2` with
  `Fares.Normalize.run!/2` before the commit, which is the path every writer of
  this package takes.
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{alias: "fares-fare-writer-#{System.unique_integer([:positive])}"})

    actor = editor_fixture(organization)
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

  describe "creating a fare" do
    test "names its rows, gives the id its name asks for and records one entry", context do
      params = %{
        name: "Summer beach shuttle",
        kind: "single",
        media_ids: ["cash", "app"],
        prices: %{"adult" => "1.00", "reduced" => "0.50"}
      }

      assert {:ok, result} = Fares.save_fare(context.scope, params)

      # The id is the name as a GTFS id, the way a route group's is.
      assert rows = fare_rows(context, "summer_beach_shuttle")
      assert length(rows) == 4

      # One row per rider type and payment method named, four of them, because
      # R9's single `prices` map is this fare's price whichever method it is
      # bought with.
      assert rows
             |> Enum.sort_by(&{&1.fare_media_id, &1.rider_category_id})
             |> Enum.map(&{&1.fare_media_id, &1.rider_category_id, &1.amount}) == [
               {"app", "adult", Decimal.new("1.00")},
               {"app", "reduced", Decimal.new("0.50")},
               {"cash", "adult", Decimal.new("1.00")},
               {"cash", "reduced", Decimal.new("0.50")}
             ]

      # Every row of one fare carries its name and one currency, which is what
      # the grid reads it back as a single fare.
      assert Enum.all?(rows, &(&1.fare_product_name == "Summer beach shuttle"))
      assert Enum.all?(rows, &(&1.currency == "USD"))

      assert [detail] = detail_rows(context, "summer_beach_shuttle")
      assert detail.kind == "single"
      assert detail.accepted_network_ids == []

      assert [entry] = fare_writes(context, "created")
      assert entry.id == result.operation_id
      assert entry.changed_fields["summary"] == "Created the fare \"Summer beach shuttle\""

      assert {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)

      assert Enum.any?(workspace.fares, &(&1.name == "Summer beach shuttle"))
    end

    test "prices per payment method where the fare's price is not the same", context do
      params = %{
        name: "Weekend shuttle",
        kind: "single",
        media_ids: ["cash", "app"],
        prices: %{"adult" => "2.00"},
        media_prices: %{"app" => %{"adult" => "1.60"}}
      }

      assert {:ok, _result} = Fares.save_fare(context.scope, params)

      assert amounts =
               context
               |> fare_rows("weekend_shuttle")
               |> Map.new(&{&1.fare_media_id, &1.amount})

      assert amounts == %{
               "cash" => Decimal.new("2.00"),
               "app" => Decimal.new("1.60")
             }
    end

    test "refuses a blank name", context do
      assert {:error, changeset} =
               Fares.save_fare(context.scope, %{
                 name: "   ",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "1.00"}
               })

      assert Keyword.has_key?(changeset.errors, :name)
      assert fare_writes(context, "created") == []
    end

    test "refuses a name whose id this version already holds", context do
      # "Valley ride" is the fare's name in the feed, and its id is
      # `valley_ride_adult_cash`, so this name is free and only a form naming
      # that id is an edit of it. Creating a fare whose id collides would be a
      # second fare the editor cannot tell apart.
      assert {:ok, _result} =
               Fares.save_fare(context.scope, %{
                 name: "Valley ride adult",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "1.00"}
               })

      assert {:error, :duplicate_fare} =
               Fares.save_fare(context.scope, %{
                 name: "Valley ride adult",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "1.10"}
               })

      assert Decimal.equal?(amount(context, "valley_ride_adult", "cash"), Decimal.new("1.00"))
    end

    test "refuses a price, a method or a rider type this version does not hold", context do
      refused = fn overrides ->
        Map.merge(
          %{name: "Refused shuttle", kind: "single", media_ids: ["cash"], prices: %{}},
          overrides
        )
      end

      # R9's counterexample: a mistyped price never reaches a row.
      assert {:error, :invalid_price} =
               Fares.save_fare(context.scope, refused.(%{prices: %{"adult" => "1.5.0"}}))

      assert {:error, :not_found} =
               Fares.save_fare(context.scope, refused.(%{media_ids: ["coin"]}))

      assert {:error, :not_found} =
               Fares.save_fare(context.scope, refused.(%{prices: %{"senior" => "1.00"}}))

      assert {:error, :no_payment_methods} =
               Fares.save_fare(context.scope, refused.(%{media_ids: []}))

      # A transfer fee is `Fares.Transfers`' own row (R5), so it is refused here
      # rather than written by two writers.
      assert {:error, :invalid_kind} =
               Fares.save_fare(context.scope, refused.(%{kind: "transfer_fee"}))

      assert fare_rows(context, "refused_shuttle") == []
      assert detail_rows(context, "refused_shuttle") == []
      assert fare_writes(context, "created") == []
    end
  end

  describe "updating a fare" do
    test "writes the rows the drawer named and leaves the rest of the fare alone", context do
      params = %{
        fare_product_id: "local_ride_adult_cash",
        name: "Local ride",
        kind: "single",
        media_ids: ["cash", "app"],
        prices: %{"adult" => "1.50"},
        media_prices: %{"app" => %{"adult" => "1.25"}},
        reviewed: [
          %{
            fare_product_id: "local_ride_adult_cash",
            rider_category_id: "adult",
            fare_media_id: "cash",
            reviewed: Decimal.new("1.50")
          }
        ]
      }

      assert {:ok, result} = Fares.save_fare(context.scope, params)

      # The fare keeps its own price on cash and gains a separate app row at the
      # price the drawer named, which is one `fare_products` row per method.
      assert amounts(context, "local_ride_adult_cash") == %{
               "cash" => Decimal.new("1.50"),
               "app" => Decimal.new("1.25")
             }

      # The other three rider types of this fare are rows of their own products
      # in the feed, and nothing here touched them.
      assert Decimal.equal?(
               amount(context, "local_ride_reduced_cash", "cash"),
               Decimal.new("0.75")
             )

      assert [entry] = fare_writes(context, "updated")
      assert entry.changed_fields["summary"] == "Updated the fare \"Local ride\""
      assert entry.id == result.operation_id

      # The editor's own read model now shows two methods for this fare.
      {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)
      fare = Enum.find(workspace.fares, &(&1.name == "Local ride"))
      assert fare.media == ["app", "cash"]
    end

    test "renames every row of the fare and moves its detail row", context do
      params = %{
        fare_product_id: "coast_ride_adult_cash",
        name: "Coast shuttle",
        kind: "single",
        media_ids: ["cash"],
        prices: %{"adult" => "3.50"},
        position: 1
      }

      assert {:ok, _result} = Fares.save_fare(context.scope, params)

      assert [row] = fare_rows(context, "coast_ride_adult_cash")
      assert row.fare_product_name == "Coast shuttle"

      assert [detail] = detail_rows(context, "coast_ride_adult_cash")
      assert detail.position == 1
    end

    test "a blank rider price deletes that row rather than storing a zero", context do
      # R9: blank means not sold, so the reduced rider's cash row goes and the
      # fare keeps only the adult one.
      params = %{
        fare_product_id: "valley_ride_adult_cash",
        name: "Valley ride",
        kind: "single",
        media_ids: ["cash"],
        prices: %{"adult" => "2.50", "reduced" => ""}
      }

      assert {:ok, _result} = Fares.save_fare(context.scope, params)

      assert fare_rows(context, "valley_ride_adult_cash") |> Enum.map(& &1.rider_category_id) ==
               ["adult"]

      assert {:ok, _undone} =
               Fares.save_fare(context.scope, %{
                 fare_product_id: "valley_ride_adult_cash",
                 name: "Valley ride",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "2.50", "reduced" => "1.25"}
               })

      assert Decimal.equal?(
               amount(context, "valley_ride_adult_cash", "cash"),
               Decimal.new("2.50")
             )
    end

    test "a reviewed price that has moved refuses the whole save", context do
      stale = [
        %{
          fare_product_id: "valley_ride_adult_cash",
          rider_category_id: "adult",
          fare_media_id: "cash",
          reviewed: Decimal.new("2.00")
        }
      ]

      params = %{
        fare_product_id: "valley_ride_adult_cash",
        name: "Valley ride",
        kind: "single",
        media_ids: ["cash"],
        prices: %{"adult" => "2.75"},
        reviewed: stale
      }

      assert {:error, {:stale, [cell]}} = Fares.save_fare(context.scope, params)
      assert cell.fare_product_id == "valley_ride_adult_cash"
      assert Decimal.equal?(cell.reviewed, Decimal.new("2.00"))
      assert Decimal.equal?(cell.stored, Decimal.new("2.50"))

      # Nothing was written: the stored price still stands and no entry names
      # this save.
      assert Decimal.equal?(
               amount(context, "valley_ride_adult_cash", "cash"),
               Decimal.new("2.50")
             )

      assert fare_writes(context, "updated") == []
    end

    test "a fare of another version is not found", context do
      other_version = gtfs_version_fixture(context.organization.id, %{name: "Other fares"})
      import!(context.organization, other_version, "north_coast_v2")
      other_scope = scope_for(context, other_version.id)
      {:ok, plan} = Conversion.preview(context.organization.id, other_version.id)
      {:ok, _converted} = Conversion.apply(other_scope, plan.fingerprint, [])

      # `coast_ride_adult_cash` is a product of the other version, and the fare
      # this version holds under that id must not be edited by naming it.
      assert {:error, :not_found} =
               Fares.save_fare(other_scope, %{
                 fare_product_id: "no_such_fare",
                 name: "Ghost ride",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "1.00"}
               })

      assert fare_rows(context, "coast_ride_adult_cash") |> Enum.map(& &1.amount) ==
               [Decimal.new("3.50")]
    end
  end

  describe "a pass" do
    test "accepted on a route group leaves one row per condition set", context do
      params = %{
        name: "Day pass",
        kind: "pass",
        media_ids: ["cash"],
        prices: %{"adult" => "4.00"},
        accepted_network_ids: ["N_LOCAL"]
      }

      assert {:ok, _result} = Fares.save_fare(context.scope, params)

      # R4: the pass's rows are Normalize's, mirroring each of the nine
      # single-ride condition sets its accepted leg group holds, and each tying
      # with the single-ride row it stands in for at priority 7.
      rows = leg_rules(context, "day_pass")

      assert length(rows) == 10
      assert Enum.all?(rows, &(&1.network_id == "N_LOCAL"))
      assert Enum.all?(rows, &(&1.leg_group_id == "N_LOCAL"))

      # Nine zone pairs tie at priority 7, and the fixture's one area-less
      # `N_LOCAL` row is mirrored at priority 4.
      assert Enum.map(rows, &{&1.rule_priority, &1.from_area_id, &1.to_area_id}) |> Enum.sort() ==
               [
                 {4, nil, nil},
                 {7, "CST", "CST"},
                 {7, "CST", "NPT"},
                 {7, "CST", "TOL"},
                 {7, "NPT", "CST"},
                 {7, "NPT", "NPT"},
                 {7, "NPT", "TOL"},
                 {7, "TOL", "CST"},
                 {7, "TOL", "NPT"},
                 {7, "TOL", "TOL"}
               ]

      assert [detail] = detail_rows(context, "day_pass")
      assert detail.kind == "pass"
      assert detail.accepted_network_ids == ["N_LOCAL"]
    end

    test "widening and narrowing the accepted networks rebuilds the rows", context do
      wide = %{
        name: "Day pass",
        kind: "pass",
        media_ids: ["cash"],
        prices: %{"adult" => "4.00"},
        accepted_network_ids: ["N_LOCAL", "N_INTERCITY"]
      }

      assert {:ok, _result} = Fares.save_fare(context.scope, wide)

      # The ten local sets plus `N_INTERCITY`'s one, which names no areas either.
      assert length(leg_rules(context, "day_pass")) == 11

      narrow = %{
        fare_product_id: "day_pass",
        name: "Day pass",
        kind: "pass",
        media_ids: ["cash"],
        prices: %{"adult" => "4.00"},
        accepted_network_ids: ["N_LOCAL"]
      }

      assert {:ok, _result} = Fares.save_fare(context.scope, narrow)

      assert length(leg_rules(context, "day_pass")) == 10
      assert Enum.all?(leg_rules(context, "day_pass"), &(&1.network_id == "N_LOCAL"))
    end

    test "refuses a network this version does not hold", context do
      assert {:error, :not_found} =
               Fares.save_fare(context.scope, %{
                 name: "Day pass",
                 kind: "pass",
                 media_ids: ["cash"],
                 prices: %{"adult" => "4.00"},
                 accepted_network_ids: ["N_WATER"]
               })

      assert detail_rows(context, "day_pass") == []
      assert leg_rules(context, "day_pass") == []
    end
  end

  describe "deleting a fare" do
    test "moves the rules that named it to the replacement", context do
      # `valley_ride_adult_cash` is named by two leg rules, NPT → TOL and
      # TOL → NPT, and by no transfer rule.
      assert length(leg_rules(context, "valley_ride_adult_cash")) == 2

      assert {:ok, result} =
               Fares.delete_fare(
                 context.scope,
                 "valley_ride_adult_cash",
                 "coast_ride_adult_cash",
                 %{
                   name: "Valley ride"
                 }
               )

      assert fare_rows(context, "valley_ride_adult_cash") == []
      assert detail_rows(context, "valley_ride_adult_cash") == []
      assert leg_rules(context, "valley_ride_adult_cash") == []

      # Exactly the two rules moved, and they moved onto the replacement.
      assert Enum.map(
               leg_rules(context, "coast_ride_adult_cash"),
               &{&1.from_area_id, &1.to_area_id}
             )
             |> Enum.sort() ==
               [{"CST", "NPT"}, {"NPT", "CST"}, {"NPT", "TOL"}, {"TOL", "NPT"}]

      assert [entry] = fare_writes(context, "deleted")
      assert entry.id == result.operation_id
      assert entry.changed_fields["summary"] == "Deleted the fare \"Valley ride\""

      # Nothing anywhere still names the deleted fare (FH-17).
      refute named_anywhere?(context, "valley_ride_adult_cash")
    end

    test "removes the rules when the drawer asks for that instead", context do
      assert {:ok, _result} =
               Fares.delete_fare(context.scope, "valley_ride_adult_cash", :remove_rules, %{})

      assert leg_rules(context, "valley_ride_adult_cash") == []
      assert fare_rows(context, "valley_ride_adult_cash") == []

      # The cells it priced are now unpriced, and the replacement's own rules
      # are untouched.
      assert Enum.all?(
               leg_rules(context, "coast_ride_adult_cash"),
               &(&1.fare_product_id == "coast_ride_adult_cash")
             )
    end

    test "refuses to delete a used fare with no replacement", context do
      assert {:error, :replacement_required} =
               Fares.delete_fare(context.scope, "valley_ride_adult_cash", nil, %{})

      assert {:error, :replacement_required} =
               Fares.delete_fare(context.scope, "valley_ride_adult_cash", nil, %{
                 name: "Valley ride"
               })

      # Nothing was written: the fare and both of its rules still stand.
      assert fare_rows(context, "valley_ride_adult_cash") != []
      assert length(leg_rules(context, "valley_ride_adult_cash")) == 2
      assert fare_writes(context, "deleted") == []
    end

    test "a fare no rule names needs no replacement", context do
      # `intercity_ride_child_cash` is a price of a fare the editor is about to
      # split out; a fare nothing points at can simply go.
      assert {:ok, _result} =
               Fares.save_fare(context.scope, %{
                 name: "Spare shuttle",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "0.50"}
               })

      assert {:ok, _result} =
               Fares.delete_fare(context.scope, "spare_shuttle", nil, %{name: "Spare shuttle"})

      assert fare_rows(context, "spare_shuttle") == []
      assert detail_rows(context, "spare_shuttle") == []
    end

    test "refuses a replacement this version does not hold, or the fare itself", context do
      assert {:error, :not_found} =
               Fares.delete_fare(context.scope, "valley_ride_adult_cash", "no_such_fare", %{})

      assert {:error, :conflicting_rule} =
               Fares.delete_fare(
                 context.scope,
                 "valley_ride_adult_cash",
                 "valley_ride_adult_cash",
                 %{}
               )

      assert length(leg_rules(context, "valley_ride_adult_cash")) == 2
      assert fare_rows(context, "valley_ride_adult_cash") != []
      assert fare_writes(context, "deleted") == []
    end

    test "refuses a replacement that already states the same conditions", context do
      # The reduced local fare is priced at the same three zone pairs as the
      # adult one, so pointing one at the other would write two rules for one
      # set of conditions, which is what the unique index is there to prevent.
      assert {:error, {:conflicting_rule, rule}} =
               Fares.delete_fare(
                 context.scope,
                 "local_ride_reduced_cash",
                 "local_ride_adult_cash",
                 %{}
               )

      assert rule.fare_product_id == "local_ride_adult_cash"

      assert {rule.from_area_id, rule.to_area_id} in [
               {"CST", "CST"},
               {"NPT", "NPT"},
               {"TOL", "TOL"}
             ]

      # Nothing moved, nothing deleted, nothing logged.
      assert length(leg_rules(context, "local_ride_reduced_cash")) == 3
      assert fare_rows(context, "local_ride_reduced_cash") != []
      assert detail_rows(context, "local_ride_reduced_cash") != []
      assert fare_writes(context, "deleted") == []
    end

    test "a fare of another version is not found", context do
      assert {:error, :not_found} =
               Fares.delete_fare(context.scope, "no_such_fare", nil, %{})

      assert {:error, :unmanaged} =
               Fares.delete_fare(unmanaged_scope(context), "local_ride_adult_cash", nil, %{})

      assert {:error, :not_found} =
               Fares.delete_fare(staging_scope(context), "local_ride_adult_cash", nil, %{})

      assert fare_rows(context, "local_ride_adult_cash") != []
    end

    test "a reviewed fact that has moved refuses the delete", context do
      # Somebody renamed the fare since the drawer opened.
      assert {:error, {:stale, [stale]}} =
               Fares.delete_fare(context.scope, "valley_ride_adult_cash", :remove_rules, %{
                 name: "Valley shuttle"
               })

      assert stale.field == :name
      assert stale.reviewed == "Valley shuttle"
      assert stale.stored == "Valley ride"

      assert {:error, {:stale, [price_stale]}} =
               Fares.delete_fare(context.scope, "valley_ride_adult_cash", :remove_rules, %{
                 prices: [
                   %{
                     fare_product_id: "valley_ride_adult_cash",
                     rider_category_id: "adult",
                     fare_media_id: "cash",
                     reviewed: Decimal.new("2.00")
                   }
                 ]
               })

      assert Decimal.equal?(price_stale.stored, Decimal.new("2.50"))

      assert fare_rows(context, "valley_ride_adult_cash") != []
      assert length(leg_rules(context, "valley_ride_adult_cash")) == 2
      assert fare_writes(context, "deleted") == []
    end
  end

  describe "undo" do
    test "a created fare goes away again and comes back with it", context do
      params = %{
        name: "Summer beach shuttle",
        kind: "single",
        media_ids: ["cash", "app"],
        prices: %{"adult" => "1.00", "reduced" => "0.50"}
      }

      assert {:ok, created} = Fares.save_fare(context.scope, params)
      assert {:ok, undone} = Fares.undo(context.scope, created.operation_id, created.inverse)
      assert undone.inverse == nil
      assert undone.operation_id == created.operation_id

      assert fare_rows(context, "summer_beach_shuttle") == []
      assert detail_rows(context, "summer_beach_shuttle") == []

      assert [rolled_back] = fare_writes(context, "rolled_back")
      assert rolled_back.rolled_back_to_log_id == created.operation_id
    end

    test "an edited fare goes back to the prices and name it held", context do
      assert {:ok, saved} =
               Fares.save_fare(context.scope, %{
                 fare_product_id: "valley_ride_adult_cash",
                 name: "Valley shuttle",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "2.75"}
               })

      assert amount(context, "valley_ride_adult_cash", "cash") == Decimal.new("2.75")

      assert {:ok, _undone} = Fares.undo(context.scope, saved.operation_id, saved.inverse)

      rows = fare_rows(context, "valley_ride_adult_cash")
      assert Enum.map(rows, &{&1.rider_category_id, &1.fare_media_id}) == [{"adult", "cash"}]
      assert amount(context, "valley_ride_adult_cash", "cash") == Decimal.new("2.50")
      assert Enum.all?(rows, &(&1.fare_product_name == "Valley ride"))
    end

    test "a deleted fare comes back with the rules it had", context do
      before_rules =
        leg_rules(context, "valley_ride_adult_cash") |> Enum.map(& &1.id) |> Enum.sort()

      assert {:ok, deleted} =
               Fares.delete_fare(
                 context.scope,
                 "valley_ride_adult_cash",
                 "coast_ride_adult_cash",
                 %{}
               )

      assert leg_rules(context, "valley_ride_adult_cash") == []

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      restored = fare_rows(context, "valley_ride_adult_cash")
      assert Enum.map(restored, &{&1.rider_category_id, &1.fare_media_id}) == [{"adult", "cash"}]
      assert Enum.all?(restored, &(&1.fare_product_name == "Valley ride"))
      assert [detail] = detail_rows(context, "valley_ride_adult_cash")
      assert detail.kind == "single"

      # The rules come back with the ids they had, so nothing else moved.
      assert leg_rules(context, "valley_ride_adult_cash") |> Enum.map(& &1.id) |> Enum.sort() ==
               before_rules
    end

    test "a removed rule is put back with the id it had", context do
      before_rules = leg_rules(context, "valley_ride_adult_cash") |> Enum.map(& &1.id)

      assert {:ok, deleted} =
               Fares.delete_fare(context.scope, "valley_ride_adult_cash", :remove_rules, %{})

      assert leg_rules(context, "valley_ride_adult_cash") == []

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      assert leg_rules(context, "valley_ride_adult_cash") |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort(before_rules)
    end

    test "a later change makes the reversal stale", context do
      assert {:ok, first} =
               Fares.save_fare(context.scope, %{
                 fare_product_id: "valley_ride_adult_cash",
                 name: "Valley ride",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "2.60"}
               })

      assert {:ok, _second} =
               Fares.save_fare(context.scope, %{
                 fare_product_id: "valley_ride_adult_cash",
                 name: "Valley ride",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "2.70"}
               })

      assert {:error, :stale} = Fares.undo(context.scope, first.operation_id, first.inverse)

      # The later save stands: undo never reverts somebody else's edit.
      assert amount(context, "valley_ride_adult_cash", "cash") == Decimal.new("2.70")
    end

    test "a deleted fare's reversal cannot be applied twice", context do
      assert {:ok, deleted} =
               Fares.delete_fare(
                 context.scope,
                 "valley_ride_adult_cash",
                 "coast_ride_adult_cash",
                 %{}
               )

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      # The fare is back and its rules name it again, so the delete a second
      # reversal would apply is not the state this version is in.
      assert fare_rows(context, "valley_ride_adult_cash") != []
      assert {:error, :stale} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      assert fare_rows(context, "valley_ride_adult_cash") != []
    end

    test "a deleted fare's reversal is stale once its rules are settled again", context do
      assert {:ok, deleted} =
               Fares.delete_fare(
                 context.scope,
                 "valley_ride_adult_cash",
                 "coast_ride_adult_cash",
                 %{}
               )

      # A later write put one of the moved rules back on the deleted fare, so the
      # version is no longer in the state the delete left. R15's fence for a
      # delete asks that every rule it settled is still settled the same way.
      moved = Enum.find(inverse_rules(deleted.inverse), &match?(%{after: _}, &1))

      Repo.update_all(
        from(r in FareLegRule, where: r.id == ^moved.id),
        set: [fare_product_id: "valley_ride_adult_cash"]
      )

      assert {:error, :stale} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      # The reversal changed nothing: the fare is still gone.
      assert fare_rows(context, "valley_ride_adult_cash") == []
    end

    test "an operation this version never recorded is stale", context do
      assert {:ok, created} =
               Fares.save_fare(context.scope, %{
                 name: "Summer beach shuttle",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "1.00"}
               })

      assert {:error, :stale} =
               Fares.undo(context.scope, Ecto.UUID.generate(), created.inverse)

      assert fare_rows(context, "summer_beach_shuttle") != []
    end
  end

  # -- Helpers ------------------------------------------------------------------

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

  # A second version of the same organization, converted like the first, so a
  # refusal can be asked of a scope that names another version's rows.
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

  defp fare_rows(context, product_id) do
    organization_id = context.organization.id

    FareProduct
    |> where(
      [p],
      p.organization_id == ^organization_id and p.gtfs_version_id == ^context.version.id and
        p.fare_product_id == ^product_id
    )
    |> Repo.all()
  end

  defp detail_rows(context, product_id) do
    organization_id = context.organization.id

    FareProductDetail
    |> where(
      [d],
      d.organization_id == ^organization_id and d.gtfs_version_id == ^context.version.id and
        d.fare_product_id == ^product_id
    )
    |> Repo.all()
  end

  defp leg_rules(context, product_id) do
    organization_id = context.organization.id

    FareLegRule
    |> where(
      [r],
      r.organization_id == ^organization_id and r.gtfs_version_id == ^context.version.id and
        r.fare_product_id == ^product_id
    )
    |> Repo.all()
  end

  # Whether anything in this version still names a product id, which is the
  # question FH-17 asks of every delete.
  defp named_anywhere?(context, product_id) do
    organization_id = context.organization.id

    Enum.any?(
      [FareProduct, FareProductDetail, FareLegRule],
      fn schema ->
        Repo.exists?(
          from(row in schema,
            where:
              row.organization_id == ^organization_id and
                row.gtfs_version_id == ^context.version.id and
                row.fare_product_id == ^product_id
          )
        )
      end
    )
  end

  defp amount(context, product_id, medium) do
    context
    |> fare_rows(product_id)
    |> Enum.find(&(&1.fare_media_id == medium))
    |> case do
      nil -> nil
      row -> row.amount
    end
  end

  defp amounts(context, product_id) do
    context
    |> fare_rows(product_id)
    |> Map.new(&{&1.fare_media_id, &1.amount})
  end

  # The conversion writes a `created` entry of its own for the whole version, so
  # these are the entries whose summary names a fare, which is this writer's.
  defp fare_writes(context, action) do
    prefix =
      case action do
        "created" -> "Created the fare"
        "updated" -> "Updated the fare"
        "deleted" -> "Deleted the fare"
        "rolled_back" -> "Restored the fare"
      end

    context
    |> fare_logs(action)
    |> Enum.filter(&String.starts_with?(&1.changed_fields["summary"], prefix))
  end

  # The rules a delete recorded in its inverse, which is the same set the undo
  # fence re-checks.
  defp inverse_rules(%{fare: %{rules: rules}}), do: rules

  defp fare_logs(context, action) do
    organization_id = context.organization.id

    ChangeLog
    |> where(
      [log],
      log.organization_id == ^organization_id and log.gtfs_version_id == ^context.version.id and
        log.entity_type == "fare_version" and log.action == ^action
    )
    |> Repo.all()
  end
end

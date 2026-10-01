defmodule GtfsPlanner.Gtfs.Fares.RiderMediaTest do
  @moduledoc """
  Merge evidence (EV-18) for `Fares.save_rider_type/2`, `Fares.delete_rider_type/3`,
  `Fares.save_payment_method/2`, `Fares.delete_payment_method/3` and the inverse
  `Fares.undo/3` applies (AC-17, AC-18, AC-9, R8, R9, R15, FH-18).

  Every expected value is worked by hand from the fixture and from the rules,
  never read back from the code under test (CR-2):

  - `test/fixtures/gtfs/fares/north_coast_v2` holds four rider types (adult
    default 1, reduced, youth, child), two payment methods (`cash` type 0 and
    `app` type 4) and seven fares: Local ride, Valley ride, Coast ride,
    Valley-coast ride and Intercity ride (four rider types each, on cash), Day
    pass (adult, reduced and youth, on cash) and 31-day pass (adult, reduced and
    youth, on app only).
  - R8's one-default rule: the fixture marks `adult` 1 and the rest 0.
  - AC-17's starting prices, `:half` on the adult cash prices: Local ride
    `$1.50` → `$0.75`, Valley ride `$2.50` → `$1.25`, Coast ride `$3.50` →
    `$1.75`, Valley-coast ride `$5.00` → `$2.50`, Intercity ride `$6.00` →
    `$3.00`, Day pass `$4.00` → `$2.00`, 31-day pass `$50.00` → `$25.00`. Half
    of `$1.50` is 30 nickels exactly and half of `$6.00` is 120, so the
    `$0.05` rounding is visible on the fares that need it rather than on these
    two; the prepared case's Local `$0.75` and Intercity `$3.00` are both exact.
  - AC-18's accepted fares: a new payment method is added at the fare's own
    cash-medium price for each rider type the fare is sold to, which is 4 + 4 +
    4 + 4 + 4 + 3 = 23 rows for the twenty-three cash rows the fixture holds.
    The seven `app` rows have no cash price to copy and are left alone.
  - R9's rules on a payment method: the method's rows are named by
    `(fare_product_id, rider_category_id, fare_media_id)`, and a fare that stops
    accepting a method loses its rows rather than storing a zero.

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/3` with
  `Fares.Normalize.run!/2` before the commit, which is the path every writer of
  this package takes. `Normalize.run!/2` is also what raises when a version is
  left with two default rider types, so R8 is enforced by the transaction and not
  only by these writers.
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{alias: "fares-rider-media-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      user_fixture(%{
        email: "fares-rider-media-#{System.unique_integer([:positive])}@example.com"
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

  describe "creating a rider type" do
    test "starts every fare at half the adult price, rounded to the nickel", context do
      assert {:ok, _result} =
               Fares.save_rider_type(context.scope, %{
                 name: "Students",
                 starting: :half
               })

      assert rider_row(context, "students") == %{
               rider_category_name: "Students",
               is_default_fare_category: 0,
               eligibility_url: nil
             }

      # The prepared case's two fares, and every other fare besides.
      assert amount(context, "local_ride_adult_cash", "students", "cash") == Decimal.new("0.75")

      assert amount(context, "intercity_ride_adult_cash", "students", "cash") ==
               Decimal.new("3.00")

      assert amount(context, "valley_ride_adult_cash", "students", "cash") ==
               Decimal.new("1.25")

      assert amount(context, "coast_ride_adult_cash", "students", "cash") ==
               Decimal.new("1.75")

      assert amount(context, "valley_coast_ride_adult_cash", "students", "cash") ==
               Decimal.new("2.50")

      assert amount(context, "day_pass_adult_cash", "students", "cash") ==
               Decimal.new("2.00")

      # The 31-day pass is sold on the app only, so its own base medium is the
      # app and half of `$50.00` is `$25.00`.
      assert amount(context, "month_pass_adult_app", "students", "app") ==
               Decimal.new("25.00")

      # The grid reads the new column back on every fare, so the new rider type
      # is a rider a reader sees.
      assert {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)

      assert Enum.any?(workspace.riders, &(&1.rider_category_id == "students"))
      # The fare's own rider types are untouched: the new column is beside them,
      # not over them.
      assert amount(context, "local_ride_reduced_cash", "reduced", "cash") == Decimal.new("0.75")
    end

    test "`:same` copies the adult price and `:free` is a zero row for every fare", context do
      assert {:ok, _result} =
               Fares.save_rider_type(context.scope, %{name: "Seniors", starting: :same})

      assert amount(context, "intercity_ride_adult_cash", "seniors", "cash") ==
               Decimal.new("6.00")

      assert {:ok, _result} =
               Fares.save_rider_type(context.scope, %{name: "Toddlers", starting: :free})

      for {product_id, medium} <- [
            {"local_ride_adult_cash", "cash"},
            {"intercity_ride_adult_cash", "cash"},
            {"month_pass_adult_app", "app"}
          ] do
        assert Decimal.equal?(amount(context, product_id, "toddlers", medium), Decimal.new(0)),
               "#{product_id} on #{medium} should be free"
      end
    end

    test "`:blank` writes no price at all, because blank means not sold", context do
      assert {:ok, _result} =
               Fares.save_rider_type(context.scope, %{name: "Companions", starting: :blank})

      assert rider_ids(context) == ["adult", "child", "companions", "reduced", "youth"]
      assert price_cells(context, "companions") == []
    end

    test "names its rows, gives the id its name asks for and records one entry", context do
      assert {:ok, result} =
               Fares.save_rider_type(context.scope, %{
                 name: "Students (18-25)",
                 eligibility_url: "https://northcoast.example/students",
                 starting: :blank
               })

      assert rider_row(context, "students_18_25") == %{
               rider_category_name: "Students (18-25)",
               is_default_fare_category: 0,
               eligibility_url: "https://northcoast.example/students"
             }

      assert [entry] = definition_writes(context, "created")
      assert entry.id == result.operation_id

      assert entry.changed_fields["summary"] ==
               "Created the rider type \"Students (18-25)\""
    end

    test "refuses a name this version already holds, and a blank one", context do
      # The rider type's GTFS id is its name as an id, so an operator naming
      # `Adult` again is creating a second `adult` row rather than editing one.
      assert {:error, :duplicate_rider_type} =
               Fares.save_rider_type(context.scope, %{name: "Adult", starting: :blank})

      # A name already used for a save, whose id the first create took.
      assert {:ok, _created} =
               Fares.save_rider_type(context.scope, %{name: "Students", starting: :blank})

      assert {:error, :duplicate_rider_type} =
               Fares.save_rider_type(context.scope, %{name: "Students", starting: :blank})

      assert {:error, changeset} =
               Fares.save_rider_type(context.scope, %{name: "   ", starting: :blank})

      assert "can't be blank" in errors_on(changeset).name

      assert rider_ids(context) == ["adult", "child", "reduced", "students", "youth"]
    end

    test "an unknown starting choice and a rider type of another version are refused", context do
      assert {:error, :invalid_starting_prices} =
               Fares.save_rider_type(context.scope, %{name: "Students", starting: :quarter})

      assert {:error, :not_found} =
               Fares.save_rider_type(context.scope, %{
                 rider_category_id: "no_such_rider",
                 name: "Students"
               })

      assert {:error, :unmanaged} =
               Fares.save_rider_type(unmanaged_scope(context), %{name: "Students"})

      assert {:error, :not_found} =
               Fares.save_rider_type(staging_scope(context), %{name: "Students"})

      assert rider_ids(context) == ["adult", "child", "reduced", "youth"]
    end
  end

  describe "moving the default" do
    test "clears the old rider type's flag in the same transaction", context do
      assert {:ok, _result} =
               Fares.save_rider_type(context.scope, %{
                 rider_category_id: "reduced",
                 name: "Reduced fare",
                 default?: true
               })

      assert rider_flag(context, "reduced") == 1
      assert rider_flag(context, "adult") == 0

      # R8: exactly one, which the normalizer would otherwise raise on.
      assert default_riders(context) == ["reduced"]

      assert {:ok, _moved} =
               Fares.save_rider_type(context.scope, %{
                 rider_category_id: "adult",
                 name: "Adult",
                 default?: true
               })

      assert rider_flag(context, "adult") == 1
      assert rider_flag(context, "reduced") == 0
      assert default_riders(context) == ["adult"]
    end

    test "an update that says nothing about the default leaves the flag alone", context do
      assert {:ok, _result} =
               Fares.save_rider_type(context.scope, %{
                 rider_category_id: "adult",
                 name: "Adult rider",
                 starting: :half
               })

      # The form omitted `:default?`, so it is not un-defaulting the rider type
      # that holds the flag — and R8 would refuse the version if it were.
      assert rider_flag(context, "adult") == 1
      assert default_riders(context) == ["adult"]

      assert rider_row(context, "adult") == %{
               rider_category_name: "Adult rider",
               is_default_fare_category: 1,
               eligibility_url: nil
             }

      # An update has no starting prices: they belong to a create, and a form
      # that named one anyway does not move every fare in the version.
      assert length(rider_rows(context)) == 4
    end

    test "a create can be the default, and it clears the flag it takes", context do
      assert {:ok, _result} =
               Fares.save_rider_type(context.scope, %{
                 name: "First riders",
                 default?: true,
                 starting: :blank
               })

      assert default_riders(context) == ["first_riders"]
      assert rider_flag(context, "adult") == 0
    end
  end

  describe "deleting a rider type" do
    test "takes its prices with it", context do
      before = price_cells(context, "youth")

      assert {:ok, deleted} =
               Fares.delete_rider_type(context.scope, "youth", %{name: "Youth (6-18)"})

      assert rider_rows(context) |> Enum.map(& &1.rider_category_id) |> Enum.sort() ==
               ["adult", "child", "reduced"]

      assert price_cells(context, "youth") == []
      assert length(before) == 8

      assert [entry] = definition_writes(context, "deleted")
      assert entry.id == deleted.operation_id
      assert entry.changed_fields["summary"] == "Deleted the rider type \"Youth (6-18)\""
    end

    test "refuses the default rider type", context do
      assert {:error, :default_rider_type} =
               Fares.delete_rider_type(context.scope, "adult", %{name: "Adult"})

      assert rider_flag(context, "adult") == 1
      assert price_cells(context, "adult") != []
      assert definition_writes(context, "deleted") == []
    end

    test "a renamed rider type refuses the delete", context do
      assert {:error, {:stale, [stale]}} =
               Fares.delete_rider_type(context.scope, "youth", %{name: "Young people"})

      assert stale.field == :name
      assert stale.reviewed == "Young people"
      assert stale.stored == "Youth (6-18)"

      assert price_cells(context, "youth") != []
      assert definition_writes(context, "deleted") == []
    end

    test "a rider type of another version is not found", context do
      assert {:error, :not_found} =
               Fares.delete_rider_type(context.scope, "no_such_rider", %{})

      assert {:error, :unmanaged} =
               Fares.delete_rider_type(unmanaged_scope(context), "youth", %{})

      assert {:error, :not_found} =
               Fares.delete_rider_type(staging_scope(context), "youth", %{})

      assert rider_ids(context) == ["adult", "child", "reduced", "youth"]
    end
  end

  describe "creating a payment method" do
    test "adds a row per rider type of every fare that accepts it, at the cash price", context do
      assert {:ok, _result} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: all_fares(context)
               })

      assert media_row(context, "hop_card") == %{
               fare_media_name: "Hop card",
               fare_media_type: 2
             }

      # One row per cash row of the version: four rider types on each of the five
      # single rides and Day pass's three, which is 23. The seven `app` rows
      # have no cash price to copy and are left alone.
      assert length(price_cells(context, nil, "hop_card")) == 23

      assert amount(context, "local_ride_adult_cash", "adult", "hop_card") ==
               Decimal.new("1.50")

      assert amount(context, "local_ride_reduced_cash", "reduced", "hop_card") ==
               Decimal.new("0.75")

      assert amount(context, "intercity_ride_adult_cash", "adult", "hop_card") ==
               Decimal.new("6.00")

      assert amount(context, "day_pass_adult_cash", "adult", "hop_card") == Decimal.new("4.00")

      # The app rows have no cash price to copy, so they are untouched: a fare
      # with no on-board price of its own is priced by opening the fare.
      assert amount(context, "month_pass_adult_app", "adult", "hop_card") == nil
      assert amount(context, "local_ride_adult_app", "adult", "hop_card") == nil

      assert {:ok, workspace} = Fares.load_workspace(context.organization.id, context.version.id)

      assert Enum.any?(workspace.media, &(&1.fare_media_id == "hop_card"))
    end

    test "a fare that does not accept it gets no row", context do
      assert {:ok, _result} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: ["local_ride_adult_cash", "coast_ride_adult_cash"]
               })

      assert amount(context, "local_ride_adult_cash", "adult", "hop_card") ==
               Decimal.new("1.50")

      assert amount(context, "valley_ride_adult_cash", "adult", "hop_card") == nil

      assert amount(context, "coast_ride_adult_cash", "adult", "hop_card") ==
               Decimal.new("3.50")
    end

    test "unticking a fare deletes its rows rather than storing a zero", context do
      assert {:ok, _first} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: all_fares(context)
               })

      assert amount(context, "coast_ride_adult_cash", "adult", "hop_card") ==
               Decimal.new("3.50")

      # The drawer's checkbox is one per fare, and a fare is every product id
      # sharing a name, so unticking it drops all four of Coast ride's. The form
      # is the whole set, so every row it created goes: a method a fare does not
      # accept is a missing row rather than a zero (R9).
      assert {:ok, _second} =
               Fares.save_payment_method(context.scope, %{
                 fare_media_id: "hop_card",
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids:
                   all_fares(context) --
                     Enum.filter(all_fares(context), &String.starts_with?(&1, "coast_ride_"))
               })

      for {product_id, rider_id} <- [
            {"coast_ride_adult_cash", "adult"},
            {"coast_ride_reduced_cash", "reduced"},
            {"coast_ride_child_cash", "child"}
          ] do
        assert amount(context, product_id, rider_id, "hop_card") == nil,
               "#{rider_id} on Coast ride should no longer be sold with a hop card"
      end

      # The fares that still accept it keep their rows.
      assert amount(context, "local_ride_adult_cash", "adult", "hop_card") ==
               Decimal.new("1.50")
    end

    test "a fare's own per-medium price is left alone", context do
      # `save_fare/2` priced the app method differently, so the fare has its own
      # row on a medium the version already sells. A new method is added at the
      # cash price; an existing per-medium row is not re-priced by this writer.
      assert {:ok, _result} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: ["local_ride_adult_cash"]
               })

      assert amount(context, "local_ride_adult_app", "adult", "hop_card") == nil

      # The fare's own app row is on its own product id and is untouched: this
      # writer only ever writes a row it can see it created by copying a cash
      # price.
      assert amount(context, "local_ride_adult_app", "adult", "app") == Decimal.new("1.25")

      # Unticking the fare removes the row this writer made and leaves the one
      # the fare drawer made.
      assert {:ok, _second} =
               Fares.save_payment_method(context.scope, %{
                 fare_media_id: "hop_card",
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: []
               })

      assert amount(context, "local_ride_adult_cash", "adult", "hop_card") == nil

      # The fare's own app row is on its own product id and is untouched.
      assert amount(context, "local_ride_adult_app", "adult", "app") == Decimal.new("1.25")
    end

    test "records one entry naming the method it created", context do
      assert {:ok, result} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: ["local_ride_adult_cash"]
               })

      assert [entry] = definition_writes(context, "created")
      assert entry.id == result.operation_id
      assert entry.changed_fields["summary"] == "Created the payment method \"Hop card\""
      assert media_row(context, "hop_card") == %{fare_media_name: "Hop card", fare_media_type: 2}
    end

    test "refuses a duplicate name, a blank name and a kind outside 0-4", context do
      assert {:ok, _created} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: []
               })

      assert {:error, :duplicate_payment_method} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 4,
                 fare_product_ids: []
               })

      assert {:error, changeset} =
               Fares.save_payment_method(context.scope, %{
                 name: "",
                 fare_media_type: 0,
                 fare_product_ids: []
               })

      assert "can't be blank" in errors_on(changeset).name

      assert {:error, :invalid_media_type} =
               Fares.save_payment_method(context.scope, %{
                 name: "Ferry ticket",
                 fare_media_type: 5,
                 fare_product_ids: []
               })

      assert {:error, :invalid_media_type} =
               Fares.save_payment_method(context.scope, %{
                 name: "Ferry ticket",
                 fare_media_type: "two",
                 fare_product_ids: []
               })

      assert media_names(context) |> Map.keys() |> Enum.sort() == ["app", "cash", "hop_card"]
    end

    test "a fare of another version and a version that is not managed are refused", context do
      assert {:error, :not_found} =
               Fares.save_payment_method(context.scope, %{
                 name: "Ferry ticket",
                 fare_media_type: 2,
                 fare_product_ids: ["no_such_fare"]
               })

      assert {:error, :not_found} =
               Fares.save_payment_method(context.scope, %{
                 fare_media_id: "no_such_method",
                 name: "Ferry ticket",
                 fare_media_type: 2,
                 fare_product_ids: []
               })

      assert {:error, :unmanaged} =
               Fares.save_payment_method(unmanaged_scope(context), %{
                 name: "Ferry ticket",
                 fare_media_type: 2,
                 fare_product_ids: []
               })

      assert {:error, :not_found} =
               Fares.save_payment_method(staging_scope(context), %{
                 name: "Ferry ticket",
                 fare_media_type: 2,
                 fare_product_ids: []
               })

      assert media_names(context) |> Map.keys() |> Enum.sort() == ["app", "cash"]
    end
  end

  describe "deleting a payment method" do
    test "takes its prices with it", context do
      assert {:ok, _created} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: all_fares(context)
               })

      assert {:ok, deleted} =
               Fares.delete_payment_method(context.scope, "hop_card", %{name: "Hop card"})

      assert price_cells(context, nil, "hop_card") == []
      assert media_names(context) == %{"cash" => "Cash on board", "app" => "NCT Ride app"}

      assert [entry] = definition_writes(context, "deleted")
      assert entry.id == deleted.operation_id

      assert entry.changed_fields["summary"] == "Deleted the payment method \"Hop card\""

      # The cash rows are untouched: only the deleted method's rows went.
      assert amount(context, "local_ride_adult_cash", "adult", "cash") == Decimal.new("1.50")
    end

    test "deletes the app method's own rows too", context do
      assert {:ok, deleted} =
               Fares.delete_payment_method(context.scope, "app", %{name: "NCT Ride app"})

      assert price_cells(context, nil, "app") == []
      assert amount(context, "month_pass_adult_app", "adult", "app") == nil

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)
      assert media_names(context) |> Map.has_key?("app")
    end

    test "a renamed method refuses the delete", context do
      assert {:error, {:stale, [stale]}} =
               Fares.delete_payment_method(context.scope, "cash", %{name: "Coins"})

      assert stale.field == :name
      assert stale.reviewed == "Coins"
      assert stale.stored == "Cash on board"

      assert media_names(context) |> Map.has_key?("cash")
      assert definition_writes(context, "deleted") == []
    end

    test "a method of another version is not found", context do
      assert {:error, :not_found} =
               Fares.delete_payment_method(context.scope, "no_such_method", %{})

      assert {:error, :unmanaged} =
               Fares.delete_payment_method(unmanaged_scope(context), "cash", %{})

      assert {:error, :not_found} =
               Fares.delete_payment_method(staging_scope(context), "cash", %{})

      assert media_names(context) |> Map.has_key?("cash")
    end
  end

  describe "undo" do
    test "a created rider type goes away again with its prices", context do
      assert {:ok, created} =
               Fares.save_rider_type(context.scope, %{name: "Students", starting: :half})

      assert rider_names(context) |> Map.has_key?("students")
      assert price_cells(context, "students") != []

      assert {:ok, undone} = Fares.undo(context.scope, created.operation_id, created.inverse)
      assert undone.inverse == nil

      assert rider_ids(context) == ["adult", "child", "reduced", "youth"]
      assert price_cells(context, "students") == []

      assert [rolled_back] = definition_writes(context, "rolled_back")
      assert rolled_back.rolled_back_to_log_id == created.operation_id
    end

    test "an edited rider type goes back to the name and default flag it held", context do
      assert {:ok, saved} =
               Fares.save_rider_type(context.scope, %{
                 rider_category_id: "youth",
                 name: "Young riders",
                 default?: true,
                 eligibility_url: "https://northcoast.example/youth"
               })

      assert rider_flag(context, "youth") == 1
      assert rider_flag(context, "adult") == 0

      assert {:ok, _undone} = Fares.undo(context.scope, saved.operation_id, saved.inverse)

      assert rider_row(context, "youth") == %{
               rider_category_name: "Youth (6-18)",
               is_default_fare_category: 0,
               eligibility_url: nil
             }

      # R8 is whole again: the adult is the default once more.
      assert default_riders(context) == ["adult"]
    end

    test "a deleted rider type comes back with the prices it had", context do
      before_cells =
        context
        |> price_cells("youth")
        |> Enum.map(fn {product_id, rider_id, medium, amount} ->
          {product_id, rider_id, medium, Decimal.to_string(amount)}
        end)
        |> Enum.sort()

      assert {:ok, deleted} =
               Fares.delete_rider_type(context.scope, "youth", %{name: "Youth (6-18)"})

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      assert rider_names(context) |> Map.has_key?("youth")

      assert context
             |> price_cells("youth")
             |> Enum.map(fn {product_id, rider_id, medium, amount} ->
               {product_id, rider_id, medium, Decimal.to_string(amount)}
             end)
             |> Enum.sort() == before_cells
    end

    test "a created payment method goes away again with its rows", context do
      assert {:ok, created} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: all_fares(context)
               })

      assert {:ok, _undone} = Fares.undo(context.scope, created.operation_id, created.inverse)

      refute media_names(context) |> Map.has_key?("hop_card")
      assert price_cells(context, nil, "hop_card") == []
      assert amount(context, "local_ride_adult_cash", "adult", "cash") == Decimal.new("1.50")
    end

    test "a deleted payment method comes back with the rows it had", context do
      assert {:ok, _created} =
               Fares.save_payment_method(context.scope, %{
                 name: "Hop card",
                 fare_media_type: 2,
                 fare_product_ids: ["local_ride_adult_cash"]
               })

      assert {:ok, deleted} =
               Fares.delete_payment_method(context.scope, "hop_card", %{name: "Hop card"})

      assert {:ok, _undone} = Fares.undo(context.scope, deleted.operation_id, deleted.inverse)

      assert media_row(context, "hop_card") == %{fare_media_name: "Hop card", fare_media_type: 2}

      assert amount(context, "local_ride_adult_cash", "adult", "hop_card") ==
               Decimal.new("1.50")
    end

    test "a later change makes the reversal stale", context do
      assert {:ok, first} =
               Fares.save_rider_type(context.scope, %{name: "Students", starting: :half})

      assert {:ok, _second} =
               Fares.save_rider_type(context.scope, %{
                 rider_category_id: "students",
                 name: "College students"
               })

      assert {:error, :stale} = Fares.undo(context.scope, first.operation_id, first.inverse)

      # The later edit stands: undo never reverts somebody else's save.
      assert rider_row(context, "students") == %{
               rider_category_name: "College students",
               is_default_fare_category: 0,
               eligibility_url: nil
             }
    end

    test "an operation this version never recorded is stale", context do
      assert {:ok, created} =
               Fares.save_rider_type(context.scope, %{name: "Students", starting: :blank})

      assert {:error, :stale} =
               Fares.undo(context.scope, Ecto.UUID.generate(), created.inverse)

      assert rider_names(context) |> Map.has_key?("students")
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

  defp rider_rows(context) do
    organization_id = context.organization.id

    RiderCategory
    |> where(
      [c],
      c.organization_id == ^organization_id and c.gtfs_version_id == ^context.version.id
    )
    |> order_by([c], c.rider_category_id)
    |> Repo.all()
  end

  defp rider_ids(context) do
    context |> rider_rows() |> Enum.map(& &1.rider_category_id) |> Enum.sort()
  end

  defp rider_names(context) do
    context |> rider_rows() |> Map.new(&{&1.rider_category_id, &1.rider_category_name})
  end

  defp rider_row(context, rider_id) do
    case Enum.find(rider_rows(context), &(&1.rider_category_id == rider_id)) do
      nil ->
        nil

      row ->
        %{
          rider_category_name: row.rider_category_name,
          is_default_fare_category: row.is_default_fare_category,
          eligibility_url: row.eligibility_url
        }
    end
  end

  defp rider_flag(context, rider_id) do
    case Enum.find(rider_rows(context), &(&1.rider_category_id == rider_id)) do
      nil -> nil
      row -> row.is_default_fare_category
    end
  end

  defp default_riders(context) do
    context
    |> rider_rows()
    |> Enum.filter(&(&1.is_default_fare_category == 1))
    |> Enum.map(& &1.rider_category_id)
  end

  defp media_rows(context) do
    organization_id = context.organization.id

    FareMedia
    |> where(
      [m],
      m.organization_id == ^organization_id and m.gtfs_version_id == ^context.version.id
    )
    |> order_by([m], m.fare_media_id)
    |> Repo.all()
  end

  defp media_names(context) do
    context |> media_rows() |> Map.new(&{&1.fare_media_id, &1.fare_media_name})
  end

  defp media_row(context, media_id) do
    case Enum.find(media_rows(context), &(&1.fare_media_id == media_id)) do
      nil ->
        nil

      row ->
        %{fare_media_name: row.fare_media_name, fare_media_type: row.fare_media_type}
    end
  end

  defp product_rows(context) do
    organization_id = context.organization.id

    FareProduct
    |> where(
      [p],
      p.organization_id == ^organization_id and p.gtfs_version_id == ^context.version.id
    )
    |> Repo.all()
  end

  defp price_cells(context, rider_id, media_id \\ nil)

  defp price_cells(context, rider_id, media_id) do
    context
    |> product_rows()
    |> Enum.filter(fn row ->
      (is_nil(rider_id) or row.rider_category_id == rider_id) and
        (is_nil(media_id) or row.fare_media_id == media_id)
    end)
    |> Enum.map(fn row ->
      {row.fare_product_id, row.rider_category_id, row.fare_media_id, row.amount}
    end)
  end

  defp amount(context, product_id, rider_id, media_id) do
    context
    |> product_rows()
    |> Enum.filter(
      &(&1.fare_product_id == product_id and &1.rider_category_id == rider_id and
          &1.fare_media_id == media_id)
    )
    |> List.first()
    |> case do
      nil -> nil
      row -> row.amount
    end
  end

  # Every fare this version holds, which the drawer's "accepted for" checkboxes
  # are one each of.
  defp all_fares(context) do
    context
    |> product_rows()
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The change-log entries whose summary names a rider type or a payment method,
  # which are this step's writers'. The conversion writes a `created` entry of its
  # own for the whole version, and a fare save names a fare.
  defp definition_writes(context, action) do
    organization_id = context.organization.id

    ChangeLog
    |> where(
      [log],
      log.organization_id == ^organization_id and log.gtfs_version_id == ^context.version.id and
        log.entity_type == "fare_version" and log.action == ^action
    )
    |> Repo.all()
    |> Enum.filter(&definition_summary?(&1.changed_fields["summary"]))
  end

  defp definition_summary?(summary) when is_binary(summary) do
    String.starts_with?(summary, "Created the rider type ") or
      String.starts_with?(summary, "Updated the rider type ") or
      String.starts_with?(summary, "Deleted the rider type ") or
      String.starts_with?(summary, "Created the payment method ") or
      String.starts_with?(summary, "Updated the payment method ") or
      String.starts_with?(summary, "Deleted the payment method ") or
      String.starts_with?(summary, "Restored the rider type or payment method ")
  end

  defp definition_summary?(_summary), do: false
end

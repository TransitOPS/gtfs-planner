defmodule GtfsPlanner.Gtfs.Fares.ChecksTest do
  @moduledoc """
  Merge evidence (EV-29) for `Fares.Checks.run/2` (AC-31, AC-33, R6, R8, R10, R11,
  R16, FH-29, INV-1, INV-5).

  Every expected value is worked by hand from
  `test/fixtures/gtfs/fares/north_coast_v2` and the GTFS reference, never read back
  from the code under test (CR-2):

  - the fixture declares two networks, `N_LOCAL` "Local routes" over thirteen
    routes and `N_INTERCITY` "Intercity" over route 10. Every route is in one, and
    after the production v2 conversion every `fare_leg_rule` names a network, so
    no route is priced only by an "any route group" rule.
  - `N_LOCAL` prices the pairs `NPT↔NPT`, `TOL↔TOL`, `CST↔CST` (the three local
    rides), `NPT↔TOL` (valley), `NPT↔CST` (coast) and `TOL↔CST` (valley-coast), so
    the matrix's nine cells all hold a fare. `N_INTERCITY` names no area, so it has
    no matrix at all. Clearing the `CST→TOL` cell therefore leaves exactly one gap
    pair.
  - the twelve stops in `stop_areas.txt` carry their zone and `CORVALLIS` carries
    none. Route 10 serves `CORVALLIS` and no zone-priced route does, so the sample
    has one stop outside every fare zone and none on a zone-priced route.
  - the four `rider_categories.txt` rows hold exactly one default, `adult`, so the
    default-rider codes are silent.
  - the adult cash amounts the R6 guard compares: Local $1.50, Valley $2.50,
    Coast $3.50, Valley-coast $5.00, Intercity $6.00. So `N_LOCAL → N_INTERCITY`
    may pay the difference ($6.00 covers $5.00) and a Local fare raised above
    $6.00 makes the stored rule charge less than the ride it follows.
  - `Day pass` and `31-day pass` are passes, and every other fare is named by four
    leg rules, so the sample has no fare no rule charges. A fare created with no
    rule is one.
  - the v2 format needs one default rider type, several rider prices and the
    passes, so the sample carries the `older_format_leaves_out` note.
  - R10's weekday bitmask for Monday through Friday is `31`, and `24:00:00` is
    `86_400` seconds within the day.

  The version enters rows through the production importer and the production v2
  conversion, and every write runs inside
  `GtfsPlanner.Gtfs.Fares.VersionLock.transact/2` with `Fares.Normalize.run!/2`
  before the commit, which is the path every writer of this package takes. The
  states no writer can produce — a negative imported price, an imported calendar
  row sharing a period's service id, an imported rule stale against a later price
  edit — are written as the stored rows they are, which is what an import of an
  edited feed looks like.
  """
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 2]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Checks
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Gtfs.RiderCategory
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteNetwork
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  # R10's weekday bitmask for Monday through Friday.
  @weekdays 31

  setup do
    organization =
      organization_fixture(%{alias: "fares-checks-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      editor_fixture(organization, %{
        email: "fares-checks-#{System.unique_integer([:positive])}@example.com"
      })

    version = gtfs_version_fixture(organization.id, %{name: "North Coast fares editor"})
    import!(organization, version, "north_coast_v2")

    context = %{
      organization: organization,
      version: version,
      actor: actor,
      scope: scope(organization, version, actor)
    }

    {:ok, plan} = Conversion.preview(organization.id, version.id)
    {:ok, _converted} = Conversion.apply(context.scope, plan.fingerprint, [])

    context
  end

  describe "the clean North Coast version" do
    test "reports no repair or review item, and the older-format note", context do
      checks = run(context)

      assert checks.repair == []
      assert checks.review == []

      assert [note] = checks.notes
      assert note.code == "older_format_leaves_out"
      assert note.action == nil
      assert note.tab == nil

      # The note says what the older format cannot state. The sample has no time
      # period, so R11's fifth sentence has nothing to say.
      assert note.body =~ "Passes: Day pass and 31-day pass"
      assert note.body =~ "NCT Ride app"
      # The sample's own transfer rows name the pre-conversion leg groups
      # `LG_LOCAL`/`LG_INTERCITY`, which R3's leg groups do not, so the note names
      # them by their stored ids.
      assert note.body =~ "Transfers between route groups (LG_INTERCITY to LG_LOCAL"
    end

    test "passes what it found right, in the tab's own sentences", context do
      %{passed: passed} = run(context)

      assert "Every ride between zones on Local routes has a fare" in passed
      assert "Every route is in a route group" in passed
      assert "No ride has two single-ride fares" in passed
      assert "Every fare is charged somewhere" in passed
      assert "Adult is the rider type trip planners show first" in passed
    end
  end

  describe "a gap in the zone matrix" do
    test "clearing the CST to TOL cell reports one unpriced ride pair", context do
      assert {:ok, _cleared} =
               Fares.set_zone_fare(
                 context.scope,
                 "N_LOCAL",
                 "CST",
                 "TOL",
                 nil,
                 false,
                 reviewed_cell(context, "CST", "TOL")
               )

      assert [repair] = run(context).repair

      assert repair.code == "zone_pair_without_fare"
      assert repair.title == "1 ride between zones on Local routes has no fare"

      assert repair.body ==
               "Coast zone → Toledo and valley. Trip planners show no price for these rides."

      assert repair.action == "Set the missing fare"
      assert repair.tab == :where
    end
  end

  describe "a route in no route group" do
    test "removing route 40 from Local routes reports it", context do
      assert {:ok, _saved} =
               Fares.save_route_group(context.scope, %{
                 network_id: "N_LOCAL",
                 name: "Local routes",
                 route_ids: Enum.reject(local_routes(context), &(&1 == "40"))
               })

      assert [repair] = run(context).repair

      assert repair.code == "route_without_fare"
      assert repair.title == "1 route is in no route group"
      assert repair.body =~ "Route 40 40"
      assert repair.action == "Edit route groups"
      assert repair.tab == :where
    end

    test "a rule naming any route group prices the loose routes instead", context do
      # R3: a rule with no network prices every route, so a route in no group is
      # not missing a fare while such a rule exists.
      assert {:ok, _saved} =
               Fares.save_rule(
                 context.scope,
                 %{
                   network_id: nil,
                   from_area_id: "NPT",
                   to_area_id: "TOL",
                   from_timeframe_group_id: nil,
                   fare_product_id: "valley_ride_adult_cash"
                 },
                 :keep_both
               )

      assert {:ok, _saved} =
               Fares.save_route_group(context.scope, %{
                 network_id: "N_LOCAL",
                 name: "Local routes",
                 route_ids: Enum.reject(local_routes(context), &(&1 == "40"))
               })

      assert run(context).repair == []
    end
  end

  describe "two fares for one ride" do
    test "keeping a second fare on a cell that already has one is reported", context do
      assert {:ok, _kept} =
               Fares.save_rule(
                 context.scope,
                 %{
                   network_id: "N_LOCAL",
                   from_area_id: "CST",
                   to_area_id: "CST",
                   from_timeframe_group_id: nil,
                   fare_product_id: "coast_ride_adult_cash"
                 },
                 :keep_both
               )

      assert [review] = run(context).review

      assert review.code == "ride_with_two_fares"
      assert review.title == "1 ride has two fares"

      assert review.body ==
               "Local routes, Coast zone → Coast zone: Coast ride and Local ride. Trip planners show both prices."

      assert review.action == "Choose one fare"
      assert review.tab == :where
    end
  end

  describe "a fare nothing charges" do
    test "a fare created with no rule is reported", context do
      assert {:ok, _saved} =
               Fares.save_fare(context.scope, %{
                 name: "Shuttle fare",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{
                   "adult" => "3.00",
                   "reduced" => "1.50",
                   "youth" => "2.00",
                   "child" => "0.00"
                 }
               })

      assert [review] = run(context).review

      assert review.code == "fare_never_charged"
      assert review.title == "1 fare is never charged"
      assert review.body =~ "Shuttle fare"
      assert review.action == "Show where fares apply"
    end
  end

  describe "a saved journey" do
    test "a price edit that changes its total is reported", context do
      assert {:ok, _saved} =
               Fares.save_journey(context.scope, %{
                 name: "Toledo to Corvallis",
                 rider_category_id: "adult",
                 fare_media_id: "cash",
                 service_date: ~D[2026-10-05],
                 legs: [
                   %{
                     route_id: "10",
                     from_stop_id: "TOLEDO",
                     to_stop_id: "CORVALLIS",
                     departs: 7 * 3_600,
                     arrives: 9 * 3_600
                   }
                 ]
               })

      assert "All 1 saved journeys cost what you expect" in run(context).passed

      # Raising the Intercity fare from $6.00 to $7.00 makes the journey cost more
      # than the amount it was saved with.
      assert {:ok, _priced} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "intercity_ride_adult_cash",
                   rider_category_id: "adult",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("6.00"),
                   amount: "7.00"
                 }
               ])

      assert [review] = run(context).review

      assert review.code == "saved_journey_price_changed"
      assert review.title == "1 saved journey costs a different amount"

      assert review.body ==
               "Toledo to Corvallis: expected $6.00, now $7.00. Update the fares, or accept the new price if the change is intended."

      assert review.action == "Review saved journeys"
      assert review.tab == :checks
    end

    test "accepting the new price clears the item", context do
      assert {:ok, %{journey: journey}} =
               Fares.save_journey(context.scope, %{
                 name: "Toledo to Corvallis",
                 rider_category_id: "adult",
                 fare_media_id: "cash",
                 service_date: ~D[2026-10-05],
                 legs: [
                   %{
                     route_id: "10",
                     from_stop_id: "TOLEDO",
                     to_stop_id: "CORVALLIS",
                     departs: 7 * 3_600,
                     arrives: 9 * 3_600
                   }
                 ]
               })

      assert {:ok, _priced} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "intercity_ride_adult_cash",
                   rider_category_id: "adult",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("6.00"),
                   amount: "7.00"
                 }
               ])

      assert [review] = run(context).review
      assert review.code == "saved_journey_price_changed"

      assert {:ok, _accepted} =
               Fares.accept_journey_price(context.scope, journey.id, "7.00")

      assert run(context).review == []
    end
  end

  describe "time periods" do
    test "a period ending at 23:59:00 leaves the last minute unpriced", context do
      assert {:ok, _saved} =
               Fares.save_time_period(
                 context.scope,
                 period_form("Evening peak", 18 * 3_600, 23 * 3_600 + 59 * 60)
               )

      assert [review] = run(context).review

      assert review.code == "time_period_ends_2359"
      assert review.body =~ "Evening peak"
      assert review.tab == :where
    end

    test "two periods over the same weekday minutes overlap", context do
      assert {:ok, _first} =
               Fares.save_time_period(
                 context.scope,
                 period_form("Morning peak", 6 * 3_600, 9 * 3_600)
               )

      assert {:ok, _second} =
               Fares.save_time_period(context.scope, period_form("Midday", 8 * 3_600, 12 * 3_600))

      assert [review] = run(context).review

      assert review.code == "time_period_overlap"
      assert review.body =~ "Morning peak"
      assert review.body =~ "Midday"
    end

    test "a period ending at the end of the service day is not reported", context do
      assert {:ok, _saved} =
               Fares.save_time_period(context.scope, %{
                 name: "Evening peak",
                 weekdays: @weekdays,
                 until_end_of_day?: true,
                 ranges: [%{start_seconds: 18 * 3_600, end_seconds: 24 * 3_600}]
               })

      codes = Enum.map(run(context).review, & &1.code)

      refute "time_period_ends_2359" in codes
    end
  end

  describe "a period sharing a calendar service id" do
    test "an imported calendar row holding the period's id is reported", context do
      assert {:ok, _saved} =
               Fares.save_time_period(
                 context.scope,
                 period_form("Weekday peak", 6 * 3_600, 9 * 3_600)
               )

      # The fixture's calendar holds `weekday`; a feed edited after import can hold
      # the period's own id, which the export then has to rename.
      insert_calendar(context, "fare_weekday_peak")

      assert [review] = run(context).review

      assert review.code == "fare_calendar_collision"
      assert review.body =~ "Weekday peak"
      assert review.tab == :where
    end
  end

  describe "a pays-the-difference transfer" do
    test "raising an origin fare above the destination makes the rule undercharge", context do
      # The stored `LG_LOCAL → LG_INTERCITY` difference is not a managed leg group,
      # so it is written through the writer, which names the version's own groups.
      assert {:ok, _saved} =
               Transfers.save(
                 context.scope,
                 "N_LOCAL",
                 "N_INTERCITY",
                 %{pay: :difference, minutes: 90, count: nil},
                 nil
               )

      assert run(context).review == []

      # $7.00 for the Local ride is above the $6.00 the difference charges, so the
      # transfer now totals less than the ride it follows (R6).
      assert {:ok, _priced} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "local_ride_adult_cash",
                   rider_category_id: "adult",
                   fare_media_id: "cash",
                   reviewed: Decimal.new("1.50"),
                   amount: "7.00"
                 }
               ])

      assert [review] = run(context).review

      assert review.code == "difference_transfer_undercharges"
      assert review.body =~ "N_LOCAL → N_INTERCITY"
      assert review.tab == :transfers
    end

    test "the sample's imported difference rows are not reported", context do
      # The fixture's transfer rows name `LG_LOCAL`/`LG_INTERCITY`, which the
      # managed leg rules do not price, so nothing is undercharging a rider.
      codes = Enum.map(run(context).review, & &1.code)

      refute "difference_transfer_undercharges" in codes
    end
  end

  describe "several agencies" do
    test "a charging group spanning two agencies leaves the fare without an agency", context do
      insert_agency(context, "OTHER")

      assert {:ok, _saved} =
               Fares.save_route_group(context.scope, %{
                 network_id: "N_LOCAL",
                 name: "Local routes",
                 route_ids: local_routes(context)
               })

      # Route 40 now runs on the other agency, so no Local fare's groups share one.
      Repo.update_all(
        from(r in Route,
          where:
            r.organization_id == ^context.organization.id and
              r.gtfs_version_id == ^context.version.id and r.route_id == "40"
        ),
        set: [agency_id: "OTHER"]
      )

      assert [review] = run(context).review

      assert review.code == "missing_agency_id"
      assert review.body =~ "Local ride"
      assert review.tab == :where
    end
  end

  describe "a stored row that breaks this editor's rules" do
    test "a negative imported price is reported", context do
      negate_price(context.organization.id, context.version.id, "local_ride_adult_cash")

      assert [repair] = run(context).repair

      assert repair.code == "invalid_imported_fare_rows"
      assert repair.body =~ "Local ride (local_ride_adult_cash)"
      assert repair.tab == :prices
    end
  end

  describe "two carriers of the route-to-group map" do
    test "a route network named in routes.txt and route_networks.txt is reported", context do
      Repo.update_all(
        from(r in Route,
          where:
            r.organization_id == ^context.organization.id and
              r.gtfs_version_id == ^context.version.id and r.route_id == "40"
        ),
        set: [network_id: "N_LOCAL"]
      )

      assert [repair] = run(context).repair

      assert repair.code == "network_in_both_files"
      assert repair.body =~ "1 routes carry a `network_id`"
      assert repair.tab == :where
    end
  end

  describe "a fare sold at two methods" do
    test "a rider type priced on one method only is reported", context do
      assert {:ok, _saved} =
               Fares.save_fare(context.scope, %{
                 name: "Harbor shuttle",
                 kind: "single",
                 media_ids: ["cash", "app"],
                 prices: %{
                   "adult" => "3.00",
                   "reduced" => "1.50",
                   "youth" => "2.00",
                   "child" => "0.00"
                 },
                 media_prices: %{
                   "app" => %{
                     "adult" => "2.50",
                     "reduced" => "1.25",
                     "youth" => "1.75",
                     "child" => "0.00"
                   }
                 }
               })

      codes = Enum.map(run(context).review, & &1.code)

      refute "missing_rider_media_price" in codes

      # Blanking the app price for one rider type is "not sold" there (R9), which
      # leaves that rider able to buy the fare with cash and not with the app.
      assert {:ok, _priced} =
               Fares.save_prices(context.scope, [
                 %{
                   fare_product_id: "harbor_shuttle",
                   rider_category_id: "reduced",
                   fare_media_id: "app",
                   reviewed: Decimal.new("1.25"),
                   amount: ""
                 }
               ])

      holes = Enum.filter(run(context).review, &(&1.code == "missing_rider_media_price"))

      assert [hole] = holes

      assert hole.body =~ "Harbor shuttle"
      assert hole.body =~ "Reduced fare"
      assert hole.body =~ "NCT Ride app"
      assert hole.action == "Show the price grid"
      assert hole.tab == :prices
    end
  end

  describe "a rider type the version has no default for" do
    test "two rider types marked default are reported", context do
      # R8 lets exactly one category hold `is_default_fare_category = 1`, and a
      # feed edited after import can carry two, which is a state the editor shows.
      Repo.update_all(
        from(r in RiderCategory,
          where:
            r.organization_id == ^context.organization.id and
              r.gtfs_version_id == ^context.version.id and r.rider_category_id == "reduced"
        ),
        set: [is_default_fare_category: 1]
      )

      assert [repair] = run(context).repair

      assert repair.code == "multiple_default_rider_types"
      assert repair.body =~ "Adult"
      assert repair.body =~ "Reduced fare"
      assert repair.action == "Choose a default"
      assert repair.tab == :prices
    end
  end

  describe "a stop on a zone-priced route with no zone" do
    test "is reported by name", context do
      # `DEPOE` is in the Coast zone and Route 4 serves it, so clearing its zone
      # leaves a ride the matrix cannot place.
      Repo.update_all(
        from(s in Stop,
          where:
            s.organization_id == ^context.organization.id and
              s.gtfs_version_id == ^context.version.id and s.stop_id == "DEPOE"
        ),
        set: [zone_id: nil]
      )

      assert [repair] = run(context).repair

      assert repair.code == "zoned_route_stop_without_zone"
      assert repair.title == "Stops on zone-priced routes have no zone"
      assert repair.body == "Depoe Bay"
      assert repair.action == "Assign zones"
      assert repair.tab == :zones
    end
  end

  describe "an unmanaged version" do
    test "is asked only the questions an imported feed can be wrong about", context do
      version = gtfs_version_fixture(context.organization.id, %{name: "Imported fares"})
      import!(context.organization, version, "north_coast_v2")

      checks = Checks.run(context.organization.id, version.id)

      # Every route of the imported sample is in a group, the sample has one default
      # rider type and every zone-priced stop is in a zone, so nothing is reported.
      assert checks.repair == []
      assert checks.review == []

      # A fare rule the imported rows leave out is this editor's question, not the
      # importer's: nothing is asked about a gap, an unused fare or an overlap.
      negate_price(context.organization.id, version.id, "local_ride_adult_cash")
      clear_cell(context.organization.id, version.id, "CST", "TOL")

      assert [repair] = Checks.run(context.organization.id, version.id).repair
      assert repair.code == "invalid_imported_fare_rows"
    end

    test "reports both network carriers and a missing default rider type", context do
      version = gtfs_version_fixture(context.organization.id, %{name: "Imported fares"})
      import!(context.organization, version, "north_coast_v2")

      Repo.update_all(
        from(r in Route,
          where:
            r.organization_id == ^context.organization.id and r.gtfs_version_id == ^version.id
        ),
        set: [network_id: "N_LOCAL"]
      )

      Repo.update_all(
        from(c in GtfsPlanner.Gtfs.RiderCategory,
          where:
            c.organization_id == ^context.organization.id and c.gtfs_version_id == ^version.id
        ),
        set: [is_default_fare_category: 0]
      )

      codes = Checks.run(context.organization.id, version.id).repair |> Enum.map(& &1.code)

      assert "network_in_both_files" in codes
      assert "no_default_rider_type" in codes
    end
  end

  describe "a pair that is not a version of the organization" do
    test "reports nothing", context do
      other = organization_fixture(%{alias: "fares-checks-other"})

      assert Checks.run(other.id, context.version.id) == %{
               repair: [],
               review: [],
               notes: [],
               passed: []
             }
    end
  end

  # -- Helpers ------------------------------------------------------------------------

  defp run(context) do
    Checks.run(context.organization.id, context.version.id)
  end

  # The product ids `CST → TOL` holds as the matrix shows it, which is the fence
  # `set_zone_fare/7` reviews (R15).
  defp reviewed_cell(context, from, to) do
    Fares.Interpreter.load_rows(context.organization.id, context.version.id).fare_leg_rules
    |> Enum.filter(fn rule ->
      rule.network_id == "N_LOCAL" and rule.from_area_id == from and rule.to_area_id == to
    end)
    |> Enum.map(& &1.fare_product_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp local_routes(context) do
    context.organization.id
    |> then(fn organization_id ->
      context.version.id
      |> then(fn gtfs_version_id ->
        RouteNetwork
        |> where(
          [row],
          row.organization_id == ^organization_id and row.gtfs_version_id == ^gtfs_version_id and
            row.network_id == "N_LOCAL"
        )
        |> select([row], row.route_id)
        |> Repo.all()
      end)
    end)
    |> Enum.sort()
  end

  defp period_form(name, start_seconds, end_seconds) do
    %{
      name: name,
      weekdays: @weekdays,
      until_end_of_day?: false,
      ranges: [%{start_seconds: start_seconds, end_seconds: end_seconds}]
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

  # A stored row an import can leave behind, written the way a feed edited after
  # import is: the row is there and its amount is one this package refuses to write.
  defp negate_price(organization_id, gtfs_version_id, product_id) do
    now = DateTime.utc_now()

    FareProduct
    |> where(
      [product],
      product.organization_id == ^organization_id and
        product.gtfs_version_id == ^gtfs_version_id and
        product.fare_product_id == ^product_id
    )
    |> Repo.update_all(set: [amount: Decimal.new("-1.50"), updated_at: now])
  end

  defp clear_cell(organization_id, gtfs_version_id, from, to) do
    GtfsPlanner.Gtfs.FareLegRule
    |> where(
      [rule],
      rule.organization_id == ^organization_id and rule.gtfs_version_id == ^gtfs_version_id and
        rule.from_area_id == ^from and rule.to_area_id == ^to
    )
    |> Repo.delete_all()
  end

  defp insert_calendar(context, service_id) do
    now = DateTime.utc_now()

    Repo.insert_all(Calendar, [
      %{
        id: Ecto.UUID.generate(),
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        service_id: service_id,
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-09-01],
        end_date: ~D[2026-09-30],
        inserted_at: now,
        updated_at: now
      }
    ])
  end

  defp insert_agency(context, agency_id) do
    now = DateTime.utc_now()

    Repo.insert_all(Agency, [
      %{
        id: Ecto.UUID.generate(),
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        agency_id: agency_id,
        agency_name: "Other Agency",
        agency_url: "https://other.example",
        agency_timezone: "America/Los_Angeles",
        agency_lang: "en",
        inserted_at: now,
        updated_at: now
      }
    ])
  end
end

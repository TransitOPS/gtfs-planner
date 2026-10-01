defmodule GtfsPlanner.Gtfs.Fares.ProjectionV1Test do
  @moduledoc """
  Merge evidence (EV-26) for `Fares.Projection.v1_rows/2`, the `fare_attributes`
  and `fare_rules` rows a managed version derives for the older GTFS fare format
  (AC-27, AC-29, R11).

  The version enters rows through the production importer and the production v2
  conversion of `test/fixtures/gtfs/fares/north_coast_v2`, and every expected
  value is worked by hand from that feed and the GTFS reference, never read back
  from the code under test (CR-2):

  - the feed's own five single-ride fares are `local_ride` 1.50, `valley_ride`
    2.50, `coast_ride` 3.50, `valley_coast_ride` 5.00 and `intercity_ride` 6.00,
    each priced for four rider types on cash, and the adult cash amount is the
    one price the older format can state. `local_ride` also sells an app price
    of 1.25, which the older format has no column for, so its row reads the cash
    price;
  - the feed's `day_pass_*` and `month_pass_*` products each carry one leg rule
    with no areas at all, which R12 classifies single-ride. Nine N_LOCAL rules
    state both areas of every pair of the sample's three zones and outrank them,
    so no ride is charged the Day pass and the 31-day pass, and R11 gives them no
    `fare_attributes` row;
  - `fare_attributes.txt` holds five rows. The three local fares and the
    valley-coast fare are charged on `N_LOCAL`, whose own free policy is two
    changes inside 90 minutes, which is `transfers` 2 and `transfer_duration`
    5400; `intercity_ride` is charged on `N_INTERCITY`, which has no free policy
    of its own, so its row reads `transfers` 0 and a blank duration;
  - `fare_rules.txt` holds 34 rows. `NPT -> TOL` and `TOL -> NPT` are the only
    zone pairs Route 10 also serves, and a rule with no route matches every
    route, so those two cells name each of `N_LOCAL`'s thirteen routes and the
    other seven zone pairs keep a blank `route_id`. The Intercity cell names no
    area and Route 10 serves stops in the zones its blank ends leave open, so it
    is narrowed to Route 10 alone;
  - a stored `fare_rules` row naming a `contains_id` is appended unchanged for a
    fare the projection derived, and left out for one it did not.

  The sample's own `fare_transfer_rules.txt` names `LG_LOCAL`/`LG_INTERCITY`,
  which R3's leg groups — the network ids — do not match, so both policies this
  sample is read under are written in setup through the production
  `Fares.Transfers.save/5`: R5's own policy for each pair, and R6's allowed
  difference, which $6.00 covers because $5.00 is the largest local amount.

  Every read here filters by `organization_id` and `gtfs_version_id` together
  (INV-5).
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [user_fixture: 1]
  import GtfsPlanner.FaresFixtures, only: [import!: 3]
  import GtfsPlanner.OrganizationsFixtures, only: [organization_fixture: 1]
  import GtfsPlanner.VersionsFixtures, only: [gtfs_version_fixture: 2]

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Gtfs.Fares.Conversion
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.Fares.Projection
  alias GtfsPlanner.Gtfs.Fares.Transfers
  alias GtfsPlanner.Repo

  @attributes "fare_attributes.txt"
  @rules "fare_rules.txt"

  # The thirteen routes of `N_LOCAL` in `route_networks.txt`, and the fare the
  # sample prices a change inside.
  @local_routes ~w(1 11 12 2 20 21 3 30 4 40 5 6 7)
  @local_fare "local_ride"

  # The zone pairs that keep a blank `route_id`, with the fare that charges each.
  @zone_pairs [
    {"CST", "CST", "local_ride"},
    {"CST", "NPT", "coast_ride"},
    {"CST", "TOL", "valley_coast_ride"},
    {"NPT", "CST", "coast_ride"},
    {"NPT", "NPT", "local_ride"},
    {"TOL", "CST", "valley_coast_ride"},
    {"TOL", "TOL", "local_ride"}
  ]

  setup do
    organization =
      organization_fixture(%{alias: "fares-projection-#{System.unique_integer([:positive])}"})

    # An explicit email rather than `user_fixture/0`: the smokes on this shared
    # partition commit a `user-1@example.com`, and `System.unique_integer/1`
    # restarts per BEAM, so the default email collides on the second run.
    actor =
      user_fixture(%{
        email: "fares-projection-#{System.unique_integer([:positive])}@example.com"
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

    # Two changes inside 90 minutes are free on the local routes, which is the
    # allowance `fare_attributes` states as `transfers` 2 and
    # `transfer_duration` 5400, and a change onto the Intercity pays the
    # difference, which is what the sample's journey prices under.
    {:ok, _free} =
      Transfers.save(
        context.scope,
        "N_LOCAL",
        "N_LOCAL",
        %{pay: :free, count: 2, minutes: 90},
        nil
      )

    {:ok, _difference} =
      Transfers.save(
        context.scope,
        "N_LOCAL",
        "N_INTERCITY",
        %{pay: :difference, minutes: 90},
        nil
      )

    Map.put(context, :rows, Interpreter.load_rows(organization.id, version.id))
  end

  describe "the fare_attributes a version derives" do
    test "one row per single-ride fare a leg rule charges", context do
      attributes = attributes(context)

      assert fare_ids(attributes) == [
               "coast_ride",
               "intercity_ride",
               @local_fare,
               "valley_coast_ride",
               "valley_ride"
             ]
    end

    test "prices the default rider type on the cash medium", context do
      # $1.50 is `local_ride_adult_cash`; the same fare's app price of $1.25 has
      # no column in the older format.
      assert attribute(context, @local_fare) == %{
               fare_id: @local_fare,
               price: Decimal.new("1.50"),
               currency_type: "USD",
               payment_method: 0,
               transfers: 2,
               agency_id: "NCT",
               transfer_duration: 5400
             }

      # Every sample fare is sold on cash, which the older format states as paid
      # on board.
      assert Enum.all?(attributes(context), &(&1.payment_method == 0))
    end

    test "carries the fare's own route group's free transfer allowance", context do
      # The Intercity fare is charged on `N_INTERCITY`, whose transfer policies
      # are the difference onto it and the free change off it, so it has no free
      # policy of its own to state.
      assert attribute(context, "intercity_ride") == %{
               fare_id: "intercity_ride",
               price: Decimal.new("6.00"),
               currency_type: "USD",
               payment_method: 0,
               transfers: 0,
               agency_id: "NCT",
               transfer_duration: nil
             }

      assert Enum.all?(
               attributes(context),
               &(&1.agency_id == "NCT")
             )
    end
  end

  describe "the fare_rules a version derives" do
    test "one row per zone pair, a route list only where Route 10 also serves both zones",
         context do
      rules = rules(context)

      assert length(rules) == 34

      # Route 10 runs Newport (NPT) → Toledo (TOL) → Corvallis (no zone), so it
      # is the only route outside `N_LOCAL` serving stops in both ends of these
      # two cells, and a rule with no route would price its rides at the valley
      # fare.
      for {from_area_id, to_area_id} <- [{"NPT", "TOL"}, {"TOL", "NPT"}] do
        routes =
          Enum.map(rules(context), &{&1.route_id, &1.origin_id, &1.destination_id})
          |> Enum.filter(fn {_, origin_id, destination_id} ->
            origin_id == from_area_id and destination_id == to_area_id
          end)

        assert Enum.map(routes, &elem(&1, 0)) == @local_routes
      end

      # The seven other zone pairs keep a blank `route_id`.
      assert Enum.count(rules(context), &is_nil(&1.route_id)) == 7
    end

    test "keeps a blank route_id for the zone pairs no other route serves", context do
      blank =
        Enum.filter(rules(context), &is_nil(&1.route_id))
        |> Enum.map(&{&1.origin_id, &1.destination_id, &1.fare_id})
        |> Enum.sort()

      assert blank == Enum.sort(@zone_pairs)
    end

    test "narrows the Intercity cell to Route 10", context do
      assert [
               %{
                 fare_id: "intercity_ride",
                 route_id: "10",
                 origin_id: nil,
                 destination_id: nil,
                 contains_id: nil
               }
             ] = rules_for(context, &(&1.fare_id == "intercity_ride"))
    end

    test "a dearer weekday peak takes the cell from the all-day fare", context do
      assert {:ok, _period} = Fares.save_time_period(context.scope, weekday_peak_form())

      assert {:ok, _fare} =
               Fares.save_fare(context.scope, %{
                 name: "Intercity peak",
                 kind: "single",
                 media_ids: ["cash"],
                 prices: %{"adult" => "7.00"}
               })

      # The period exists first, so this is the production path a rule naming a
      # time period takes (R3, INV-4).
      assert {:ok, _rule} =
               Fares.save_rule(context.scope, %{
                 network_id: "N_INTERCITY",
                 from_timeframe_group_id: "weekday_peak",
                 fare_product_id: "intercity_peak"
               })

      # Both fares are charged for the Intercity cell, at $7.00 and $6.00, and
      # the older format holds a cell once, at the dearer of them.
      assert attribute(context, "intercity_peak").price == Decimal.new("7.00")

      assert [
               %{
                 fare_id: "intercity_peak",
                 route_id: "10",
                 origin_id: nil,
                 destination_id: nil,
                 contains_id: nil
               }
             ] = rules_for(context, &(&1.fare_id == "intercity_peak"))
    end
  end

  describe "the older format's price of a journey" do
    test "is never cheaper than the newer format's, for any rider", context do
      rows = derived(context)

      for journey <- journeys(), rider_category_id <- rider_ids() do
        priced =
          Pricing.price_journey(rows, Map.put(journey, :rider_category_id, rider_category_id))

        older =
          Interpreter.price_journey_v1(
            rows,
            Map.put(journey, :rider_category_id, rider_category_id)
          )

        assert Decimal.compare(older.total, priced.total) in [:gt, :eq],
               "#{journey.name} for #{rider_category_id} is #{inspect(older.total)} against" <>
                 " #{inspect(priced.total)}"
      end
    end

    test "reads the adult cash price of one fare, or splits a journey into two", context do
      rows = derived(context)
      journey = Map.put(hd(journeys()), :rider_category_id, "adult")

      # Toledo → Corvallis is the valley fare and then the intercity fare, which
      # no single derived row covers: $2.50 + $6.00 = $8.50, against the $6.00
      # the difference the change pays.
      older = Interpreter.price_journey_v1(rows, journey)

      assert older.total == Decimal.new("8.50")
      assert older.split? == true
      assert Enum.map(older.parts, & &1.fare_id) == ["valley_ride", "intercity_ride"]

      # The same journey in the newer format, where the change pays the
      # difference, is the intercity fare alone.
      assert Pricing.price_journey(rows, journey).total == Decimal.new("6.00")
    end

    test "covers a journey inside one zone with the local fare's own allowance", context do
      rows = derived(context)

      # Nye Beach → NTC → South Beach is NPT → NPT on two local routes, one
      # change inside 5400 seconds, which `local_ride`'s own allowance covers at
      # the adult cash price of $1.50.
      older = Interpreter.price_journey_v1(rows, around_newport())

      assert older.total == Decimal.new("1.50")
      assert older.split? == false
      assert [part] = older.parts
      assert part.fare_id == @local_fare
    end
  end

  describe "stored fare_rules rows" do
    test "appends a contains_id row for a derived fare", context do
      assert {:ok, _stored} = insert_contains_rule(context, "valley_coast_ride", "NPT")

      appended = Enum.filter(rules(context), &(&1.contains_id == "NPT"))

      assert appended == [
               %{
                 fare_id: "valley_coast_ride",
                 route_id: nil,
                 origin_id: "TOL",
                 destination_id: "CST",
                 contains_id: "NPT"
               }
             ]
    end

    test "leaves out a contains_id row for a fare the projection did not derive", context do
      # The Day pass is held by this version and is a single ride R12's reading
      # finds no rule of a different fare shares conditions with, but no ride is
      # charged it, so it has no derived fare for its stored row to name.
      assert {:ok, _stored} = insert_contains_rule(context, "day_pass", "NPT")

      assert Enum.all?(rules(context), &is_nil(&1.contains_id))
    end
  end

  # -- The version, read both ways ---------------------------------------------------

  # The managed rows with the derived older-format rows substituted for the
  # stored ones, which is what `price_journey_v1/2` reads.
  defp derived(context) do
    %Rows{} = rows = context.rows
    projection = Projection.v1_rows(context.organization.id, context.version.id)

    %{rows | fare_attributes: projection[@attributes], fare_rules: projection[@rules]}
  end

  defp attributes(context), do: derived(context).fare_attributes

  defp rules(context), do: derived(context).fare_rules

  defp fare_ids(attributes), do: Enum.map(attributes, & &1.fare_id)

  defp attribute(context, fare_id) do
    context |> attributes() |> Enum.find(&(&1.fare_id == fare_id))
  end

  defp rules_for(context, fun), do: Enum.filter(rules(context), fun)

  defp rider_ids, do: ~w(adult reduced youth child)

  # The sample's three journeys, worked out from `stops.txt` and `routes.txt`.
  defp journeys do
    [toledo_to_corvallis(), around_newport(), lincoln_city_to_toledo()]
  end

  defp toledo_to_corvallis do
    %{
      name: "Toledo to Corvallis, changing in Newport",
      fare_media_id: "cash",
      service_date: ~D[2026-10-05],
      legs: [
        %{
          route_id: "4",
          from_stop_id: "TOLEDO",
          to_stop_id: "NTC",
          departs: 7 * 3600 + 40 * 60,
          arrives: 8 * 3600 + 55 * 60
        },
        %{
          route_id: "10",
          from_stop_id: "NTC",
          to_stop_id: "CORVALLIS",
          departs: 8 * 3600 + 20 * 60,
          arrives: 10 * 3600 + 20 * 60
        }
      ]
    }
  end

  defp around_newport do
    %{
      name: "Nye Beach to South Beach",
      fare_media_id: "cash",
      service_date: ~D[2026-10-05],
      legs: [
        %{
          route_id: "3",
          from_stop_id: "NYE",
          to_stop_id: "NTC",
          departs: 9 * 3600,
          arrives: 9 * 3600 + 20 * 60
        },
        %{
          route_id: "2",
          from_stop_id: "NTC",
          to_stop_id: "SBPR",
          departs: 9 * 3600 + 25 * 60,
          arrives: 9 * 3600 + 45 * 60
        }
      ]
    }
  end

  defp lincoln_city_to_toledo do
    %{
      name: "Lincoln City to Toledo",
      fare_media_id: "cash",
      service_date: ~D[2026-10-05],
      legs: [
        %{
          route_id: "1",
          from_stop_id: "LCTC",
          to_stop_id: "NTC",
          departs: 7 * 3600,
          arrives: 8 * 3600 + 25 * 60
        },
        %{
          route_id: "4",
          from_stop_id: "NTC",
          to_stop_id: "TOLEDO",
          departs: 8 * 3600 + 25 * 60,
          arrives: 9 * 3600 + 30 * 60
        }
      ]
    }
  end

  # R10's weekday peak: 06:00–09:00 and 15:00–18:00 on Monday through Friday.
  defp weekday_peak_form do
    %{
      name: "Weekday peak",
      weekdays: 31,
      ranges: [
        %{start_seconds: 6 * 3600, end_seconds: 9 * 3600},
        %{start_seconds: 15 * 3600, end_seconds: 18 * 3600}
      ],
      until_end_of_day?: false
    }
  end

  # A stored `fare_rules` row is only ever imported, and this version was
  # imported as Fares v2, so the rows the case needs are written here.
  defp insert_contains_rule(context, fare_id, contains_id) do
    %FareRule{}
    |> Ecto.Changeset.change(%{
      fare_id: fare_id,
      route_id: nil,
      origin_id: "TOL",
      destination_id: "CST",
      contains_id: contains_id,
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id
    })
    |> Repo.insert()
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

defmodule GtfsPlanner.Gtfs.Fares.PricingTest do
  @moduledoc """
  Merge evidence (EV-8): what a journey costs in North Coast's managed fare rows,
  and what each ride in it is charged for.

  Every row here is a `%Fares.Interpreter.Rows{}` literal — the North Coast sample
  in the managed form of R3–R5 — and every expected amount is a dollar figure
  worked out by hand from the sample in the spec and from the GTFS reference's
  transfer rules, so nothing in this file reads the database or asks the code under
  test for its own answer (CR-2).

  The rows are the managed form rather than the imported `fare_leg_rules.txt`:
  every leg rule carries the priority R3 gives it (`4` for a network, `2` for a
  departure area, `1` for an arrival area), `leg_group_id` is the rule's network,
  and each fare is one `fare_product_id` with a `fare_products` row per rider
  category and payment medium, which is what the editor writes. The two pass rows
  for each accepted cell are here because `Fares.Normalize` derives them (R4).
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.FareLegRule
  alias GtfsPlanner.Gtfs.FareMedia
  alias GtfsPlanner.Gtfs.FareProduct
  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows
  alias GtfsPlanner.Gtfs.Fares.Pricing
  alias GtfsPlanner.Gtfs.FareTransferRule
  alias GtfsPlanner.Gtfs.Network
  alias GtfsPlanner.Gtfs.RiderCategory

  # A Monday inside the sample's calendar span.
  @monday ~D[2026-10-05]

  describe "a change between route groups" do
    test "a Local ride then an Intercity ride is the Intercity fare, and the second ride says it pays the difference" do
      result = price(toledo_to_corvallis(), "adult", "cash")

      assert result.total == Decimal.new("6.00")
      assert result.problems == []

      assert [valley, intercity] = result.legs
      assert valley.product_id == "valley_ride"
      assert valley.product_name == "Valley ride"
      assert valley.full == Decimal.new("2.50")
      assert valley.charged == Decimal.new("2.50")
      assert valley.reason =~ "Route 4 is on Local routes"
      assert valley.reason =~ "from TOL to NPT pays Valley ride, $2.50"
      assert valley.transfer == nil

      assert intercity.product_id == "intercity_ride"
      assert intercity.full == Decimal.new("6.00")
      # The rider is charged what the Intercity fare adds, and the fare paid so far
      # becomes the Intercity fare, so the journey totals $6.00 rather than $8.50.
      assert intercity.charged == Decimal.new("3.50")
      assert intercity.reason =~ "Pays the difference"
      assert intercity.reason =~ "Intercity ride at $6.00 replaces the $2.50 already paid"
      assert intercity.transfer.fare_transfer_type == 2
      assert intercity.transfer.applied?
      assert intercity.transfer.from_leg_group_id == "N_LOCAL"
      assert intercity.transfer.to_leg_group_id == "N_INTERCITY"
      assert intercity.transfer.elapsed_seconds == 40 * 60
      assert List.last(result.legs).running_total == Decimal.new("6.00")
    end

    test "an Intercity ride then a Local ride is not priced as the reverse direction's difference" do
      # The sample's Intercity ride runs two hours, so by the time the Local ride
      # departs the sample's 90-minute change limit has passed and the ride opens a
      # new fare. The pair is read from the `Intercity` -> `Local` rule, not from the
      # `Local` -> `Intercity` `difference` rule, so the rider is not asked for
      # $6.00 minus what they already paid.
      result =
        price(
          [
            leg("10", "NTC", "CORVALLIS", 8 * 3600 + 20 * 60, 10 * 3600 + 20 * 60),
            leg("2", "NTC", "SBPR", 10 * 3600 + 40 * 60, 10 * 3600 + 55 * 60)
          ],
          "adult",
          "cash"
        )

      assert Enum.map(result.legs, & &1.charged) == [Decimal.new("6.00"), Decimal.new("1.50")]
      assert result.total == Decimal.new("7.50")
      assert Enum.at(result.legs, 1).reason =~ "Past the 90-minute limit on this change"
      assert Enum.at(result.legs, 1).transfer.from_leg_group_id == "N_INTERCITY"
      assert Enum.at(result.legs, 1).transfer.to_leg_group_id == "N_LOCAL"
      refute Enum.at(result.legs, 1).transfer.applied?
    end
  end

  describe "a change on one route group" do
    test "a reduced fare bought in the app is read from the medium's own price, and the second ride is free" do
      result =
        price(
          [
            leg("3", "NYE", "NTC", 8 * 3600 + 50 * 60, 9 * 3600),
            leg("2", "NTC", "SBPR", 9 * 3600 + 25 * 60, 9 * 3600 + 40 * 60)
          ],
          "reduced",
          "app"
        )

      assert result.total == Decimal.new("0.60")
      assert result.problems == []
      assert Enum.map(result.legs, & &1.product_id) == ["local_ride", "local_ride"]
      assert Enum.map(result.legs, & &1.charged) == [Decimal.new("0.60"), Decimal.new("0")]
      assert Enum.at(result.legs, 1).reason =~ "Free transfer from Local routes to Local routes"
    end

    test "four rides inside the 90-minute limit are one fare, two free changes and a new one" do
      result =
        price(
          [
            leg("30", "SBPR", "NTC", 6 * 3600 + 45 * 60, 7 * 3600 + 5 * 60),
            leg("11", "NTC", "AGATE", 7 * 3600 + 20 * 60, 7 * 3600 + 35 * 60),
            leg("2", "NTC", "SBPR", 7 * 3600 + 40 * 60, 7 * 3600 + 55 * 60),
            leg("12", "NYE", "HOSP", 8 * 3600, 8 * 3600 + 20 * 60)
          ],
          "adult",
          "cash"
        )

      assert result.total == Decimal.new("3.00")

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

      assert Enum.at(result.legs, 3).reason =~ "only 2 free changes"
      assert Enum.at(result.legs, 3).reason =~ "so this is a new fare"

      assert Enum.map(result.legs, & &1.running_total) == [
               Decimal.new("1.50"),
               Decimal.new("1.50"),
               Decimal.new("1.50"),
               Decimal.new("3.00")
             ]
    end

    test "a change after the 90-minute limit starts a new fare and says the limit" do
      result = price(lincoln_city_to_toledo(), "adult", "cash")

      assert result.total == Decimal.new("6.00")
      assert result.problems == []

      assert [coast, valley] = result.legs
      assert coast.product_id == "coast_ride"
      assert coast.full == Decimal.new("3.50")
      assert valley.product_id == "valley_ride"
      assert valley.full == Decimal.new("2.50")
      assert valley.charged == Decimal.new("2.50")
      assert valley.reason =~ "Past the 90-minute limit on this change"
      assert valley.reason =~ "115 minutes after the first boarding"
      refute valley.transfer.applied?
    end
  end

  describe "passes" do
    test "the Day pass is listed for a Local-only journey" do
      result =
        price([leg("2", "NTC", "SBPR", 9 * 3600 + 25 * 60, 9 * 3600 + 40 * 60)], "adult", "cash")

      assert result.total == Decimal.new("1.50")
      assert [pass] = result.passes
      assert pass.fare_product_id == "day_pass"
      assert pass.name == "Day pass"
      assert pass.amount == Decimal.new("4.00")
      assert pass.currency == "USD"
      assert pass.saves == Decimal.new("-2.50")
    end

    test "the Day pass is absent for an Intercity journey, because the Local network does not accept it" do
      result =
        price(
          [leg("10", "NTC", "CORVALLIS", 8 * 3600 + 20 * 60, 10 * 3600 + 20 * 60)],
          "adult",
          "cash"
        )

      assert result.total == Decimal.new("6.00")
      assert result.passes == []
    end
  end

  describe "a journey nobody can price" do
    test "a ride no rule covers totals nothing and names the route and its zones" do
      result =
        price([leg("99", "NYE", "TOLEDO", 7 * 3600, 8 * 3600)], "adult", "cash")

      assert result.total == nil
      assert result.passes == []
      assert result.problems == ["No fare covers Route 99 from NPT to TOL."]
      assert [ride] = result.legs
      assert ride.product_id == nil
      assert ride.charged == Decimal.new("0")
      assert ride.reason == "No fare covers Route 99 from NPT to TOL."
    end

    test "a priced ride after an unpriced one opens its own fare rather than crashing on the missing one" do
      result =
        price(
          [
            leg("99", "NYE", "TOLEDO", 7 * 3600, 8 * 3600),
            leg("2", "NTC", "SBPR", 8 * 3600 + 30 * 60, 8 * 3600 + 45 * 60)
          ],
          "adult",
          "cash"
        )

      assert result.total == nil
      assert Enum.map(result.legs, & &1.charged) == [Decimal.new("0"), Decimal.new("1.50")]
      assert Enum.at(result.legs, 1).reason =~ "no fare to continue"
      assert Enum.at(result.legs, 1).reason =~ "so this is a new fare"
    end

    test "a fare with no row for this rider and payment method totals nothing and says so" do
      result =
        price(
          [leg("10", "NTC", "CORVALLIS", 8 * 3600 + 20 * 60, 10 * 3600 + 20 * 60)],
          "adult",
          "app"
        )

      assert result.total == nil
      assert result.problems == ["Intercity ride is not sold to Adult on NCT Ride app."]
      assert [ride] = result.legs
      assert ride.product_id == "intercity_ride"
      assert ride.full == nil
    end
  end

  # Toledo City Hall (TOL) to Newport Transit Center (NPT) on Route 4, then
  # Newport Transit Center to Corvallis (no area) on Route 10. Both legs' times are
  # the ones `stop_times.txt` records for those trips; the change rule is measured
  # from departure to departure, so the 40 minutes between the two boardings are
  # the ones that decide it.
  defp toledo_to_corvallis do
    [
      leg("4", "TOLEDO", "NTC", 7 * 3600 + 40 * 60, 8 * 3600 + 55 * 60),
      leg("10", "NTC", "CORVALLIS", 8 * 3600 + 20 * 60, 10 * 3600 + 20 * 60)
    ]
  end

  # Lincoln City Transit Center (CST) to Newport Transit Center (NPT) on Route 1,
  # then Newport to Toledo City Hall (TOL) on Route 4, 115 minutes after the first
  # boarding and so past the 90-minute limit.
  defp lincoln_city_to_toledo do
    [
      leg("1", "LCTC", "NTC", 7 * 3600, 7 * 3600 + 40 * 60),
      leg("4", "NTC", "TOLEDO", 8 * 3600 + 55 * 60, 10 * 3600)
    ]
  end

  defp price(legs, rider_category_id, fare_media_id) do
    Pricing.price_journey(north_coast_rows(), %{
      rider_category_id: rider_category_id,
      fare_media_id: fare_media_id,
      service_date: @monday,
      legs: legs
    })
  end

  defp leg(route_id, from_stop_id, to_stop_id, departs, arrives) do
    %{
      route_id: route_id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      departs: departs,
      arrives: arrives
    }
  end

  # The North Coast sample as a managed version stores it: the five single rides
  # with the sample's adult, reduced, youth and child prices and the Local ride's
  # two app prices, the two passes, the two networks, the three fare zones and the
  # three transfer policies of the sample.
  defp north_coast_rows do
    %Rows{
      organization_id: "11111111-1111-4111-8111-111111111111",
      gtfs_version_id: "22222222-2222-4222-8222-222222222222",
      managed?: true,
      fare_products: Enum.flat_map(products(), & &1),
      fare_product_details: product_details(),
      fare_leg_rules: leg_rules(),
      fare_transfer_rules: transfer_rules(),
      networks: networks(),
      rider_categories: rider_categories(),
      fare_media: fare_media(),
      route_networks: %{
        "1" => "N_LOCAL",
        "2" => "N_LOCAL",
        "3" => "N_LOCAL",
        "4" => "N_LOCAL",
        "5" => "N_LOCAL",
        "6" => "N_LOCAL",
        "7" => "N_LOCAL",
        "11" => "N_LOCAL",
        "12" => "N_LOCAL",
        "20" => "N_LOCAL",
        "21" => "N_LOCAL",
        "30" => "N_LOCAL",
        "40" => "N_LOCAL",
        "10" => "N_INTERCITY"
      },
      stop_areas: %{
        "NTC" => ["NPT"],
        "NYE" => ["NPT"],
        "HOSP" => ["NPT"],
        "AGATE" => ["NPT"],
        "SBPR" => ["NPT"],
        "TOLEDO" => ["TOL"],
        "SILETZ" => ["TOL"],
        "DEPOE" => ["CST"],
        "LCTC" => ["CST"],
        "WALDPORT" => ["CST"],
        "YACHATS" => ["CST"],
        "SEAL" => ["CST"]
      }
    }
  end

  # One `fare_product_id` per fare, with a row per rider category and payment
  # medium, as the editor's price grid writes them. The Local ride is the sample's
  # fare with a cash and an app price; every other fare is a cash fare.
  defp products do
    [
      product("local_ride", "Local ride", [
        {"adult", "cash", "1.50"},
        {"adult", "app", "1.25"},
        {"reduced", "cash", "0.75"},
        {"reduced", "app", "0.60"},
        {"youth", "cash", "1.00"},
        {"child", "cash", "0.00"}
      ]),
      product("valley_ride", "Valley ride", [
        {"adult", "cash", "2.50"},
        {"reduced", "cash", "1.25"},
        {"youth", "cash", "1.50"},
        {"child", "cash", "0.00"}
      ]),
      product("coast_ride", "Coast ride", [
        {"adult", "cash", "3.50"},
        {"reduced", "cash", "1.75"},
        {"youth", "cash", "2.00"},
        {"child", "cash", "0.00"}
      ]),
      product("valley_coast_ride", "Valley-coast ride", [
        {"adult", "cash", "5.00"},
        {"reduced", "cash", "2.50"},
        {"youth", "cash", "3.00"},
        {"child", "cash", "0.00"}
      ]),
      product("intercity_ride", "Intercity ride", [
        {"adult", "cash", "6.00"},
        {"reduced", "cash", "3.00"},
        {"youth", "cash", "4.00"},
        {"child", "cash", "0.00"}
      ]),
      product("day_pass", "Day pass", [
        {"adult", "cash", "4.00"},
        {"reduced", "cash", "2.00"},
        {"youth", "cash", "2.50"}
      ]),
      product("month_pass", "31-day pass", [
        {"adult", "app", "50.00"},
        {"reduced", "app", "25.00"},
        {"youth", "app", "30.00"}
      ])
    ]
  end

  defp product(fare_product_id, fare_product_name, cells) do
    Enum.map(cells, fn {rider_category_id, fare_media_id, amount} ->
      %FareProduct{
        fare_product_id: fare_product_id,
        fare_product_name: fare_product_name,
        rider_category_id: rider_category_id,
        fare_media_id: fare_media_id,
        amount: Decimal.new(amount),
        currency: "USD"
      }
    end)
  end

  defp product_details do
    Enum.map(
      [
        {"local_ride", "single", []},
        {"valley_ride", "single", []},
        {"coast_ride", "single", []},
        {"valley_coast_ride", "single", []},
        {"intercity_ride", "single", []},
        {"day_pass", "pass", ["N_LOCAL"]},
        {"month_pass", "pass", ["N_LOCAL", "N_INTERCITY"]}
      ],
      fn {fare_product_id, kind, accepted_network_ids} ->
        %FareProductDetail{
          fare_product_id: fare_product_id,
          kind: kind,
          position: 0,
          accepted_network_ids: accepted_network_ids
        }
      end
    )
  end

  # Nine priced zone pairs on the Local network, each with the Day pass row beside
  # it because the pass is accepted on the Local network (R4), and one Intercity
  # row for every area with the 31-day pass row beside it. A managed leg rule names
  # the fare, not a fare per rider category: the four prices of a fare are its
  # `fare_products` rows, and one rule prices every rider.
  defp leg_rules do
    Enum.flat_map(zone_pairs(), fn {from_area_id, to_area_id, fare} ->
      [
        zone_rule("N_LOCAL", from_area_id, to_area_id, fare),
        zone_rule("N_LOCAL", from_area_id, to_area_id, "day_pass")
      ]
    end) ++
      [
        zone_rule("N_INTERCITY", nil, nil, "intercity_ride"),
        zone_rule("N_LOCAL", nil, nil, "month_pass"),
        zone_rule("N_INTERCITY", nil, nil, "month_pass")
      ]
  end

  defp zone_pairs do
    [
      {"NPT", "NPT", "local_ride"},
      {"TOL", "TOL", "local_ride"},
      {"CST", "CST", "local_ride"},
      {"NPT", "TOL", "valley_ride"},
      {"TOL", "NPT", "valley_ride"},
      {"NPT", "CST", "coast_ride"},
      {"CST", "NPT", "coast_ride"},
      {"TOL", "CST", "valley_coast_ride"},
      {"CST", "TOL", "valley_coast_ride"}
    ]
  end

  defp zone_rule(network_id, from_area_id, to_area_id, fare) do
    %FareLegRule{
      leg_group_id: network_id,
      network_id: network_id,
      from_area_id: from_area_id,
      to_area_id: to_area_id,
      from_timeframe_group_id: nil,
      to_timeframe_group_id: nil,
      fare_product_id: fare,
      rule_priority: priority(network_id, from_area_id, to_area_id)
    }
  end

  # R3: 4 for a network, 2 for a departure area, 1 for an arrival area.
  defp priority(network_id, from_area_id, to_area_id) do
    4 * one(network_id) + 2 * one(from_area_id) + one(to_area_id)
  end

  defp one(nil), do: 0
  defp one(_value), do: 1

  defp transfer_rules do
    [
      %FareTransferRule{
        from_leg_group_id: "N_LOCAL",
        to_leg_group_id: "N_LOCAL",
        transfer_count: 2,
        duration_limit: 5400,
        duration_limit_type: 1,
        fare_transfer_type: 0,
        fare_product_id: nil
      },
      %FareTransferRule{
        from_leg_group_id: "N_LOCAL",
        to_leg_group_id: "N_INTERCITY",
        transfer_count: nil,
        duration_limit: 5400,
        duration_limit_type: 1,
        fare_transfer_type: 2,
        fare_product_id: "intercity_ride"
      },
      %FareTransferRule{
        from_leg_group_id: "N_INTERCITY",
        to_leg_group_id: "N_LOCAL",
        transfer_count: nil,
        duration_limit: 5400,
        duration_limit_type: 1,
        fare_transfer_type: 0,
        fare_product_id: nil
      }
    ]
  end

  defp networks do
    [
      %Network{network_id: "N_LOCAL", network_name: "Local routes"},
      %Network{network_id: "N_INTERCITY", network_name: "Intercity"}
    ]
  end

  defp rider_categories do
    [
      %RiderCategory{
        rider_category_id: "adult",
        rider_category_name: "Adult",
        is_default_fare_category: 1
      },
      %RiderCategory{
        rider_category_id: "reduced",
        rider_category_name: "Reduced fare",
        is_default_fare_category: 0
      },
      %RiderCategory{
        rider_category_id: "youth",
        rider_category_name: "Youth (6-18)",
        is_default_fare_category: 0
      },
      %RiderCategory{
        rider_category_id: "child",
        rider_category_name: "Children under 6",
        is_default_fare_category: 0
      }
    ]
  end

  defp fare_media do
    [
      %FareMedia{fare_media_id: "cash", fare_media_name: "Cash on board", fare_media_type: 0},
      %FareMedia{fare_media_id: "app", fare_media_name: "NCT Ride app", fare_media_type: 4}
    ]
  end
end

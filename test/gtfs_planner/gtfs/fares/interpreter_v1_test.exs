defmodule GtfsPlanner.Gtfs.Fares.InterpreterV1Test do
  @moduledoc """
  Merge evidence (EV-9): what one journey costs in the older `fare_attributes` and
  `fare_rules` model (AC-6).

  Every row here is a `%Fares.Interpreter.Rows{}` literal mirroring
  `test/fixtures/gtfs/fares/north_coast_v1` — the five `fare_attributes` rows, the
  eleven `fare_rules` rows and the stops' `zone_id` values of that feed — so nothing in
  this file reads the database or asks the code under test for its own answer (CR-2).

  Expected values are worked out by hand from the reference's fare-matching rules for
  `fare_attributes.txt` and `fare_rules.txt` and from the sample's rows, not from
  `Interpreter.price_journey_v1/2`. Leg times are the rider's own journey, which is what
  a saved journey holds; as AC-5's own Toledo → Corvallis pair shows, a journey need not
  be one scheduled trip pair, and the older model prices zones and route ids rather than
  a direction or a schedule.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.Fares.Interpreter
  alias GtfsPlanner.Gtfs.Fares.Interpreter.Rows

  # The zones of the sample, as `stops.txt` gives them. Corvallis is in none.
  @stop_zones %{
    "NTC" => "NPT",
    "NYE" => "NPT",
    "HOSP" => "NPT",
    "AGATE" => "NPT",
    "SBPR" => "NPT",
    "TOLEDO" => "TOL",
    "SILETZ" => "TOL",
    "DEPOE" => "CST",
    "LCTC" => "CST",
    "WALDPORT" => "CST",
    "YACHATS" => "CST",
    "SEAL" => "CST",
    "CORVALLIS" => nil
  }

  describe "a fare that covers the whole journey" do
    test "prices one Local ride at $1.50" do
      # Route 3 inside NPT, the only rule pair a one-zone ride can match: LOCAL
      # NPT → NPT. No other fare names an NPT → NPT cell.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([leg("3", "NTC", "NYE", at(8, 30), at(8, 50))])
        )

      assert result == %{
               total: Decimal.new("1.50"),
               parts: [
                 %{
                   fare_id: "LOCAL",
                   price: Decimal.new("1.50"),
                   currency: "USD",
                   payment_method: 0,
                   legs: 1,
                   from_stop_id: "NTC",
                   to_stop_id: "NYE"
                 }
               ],
               split?: false,
               unknown?: false
             }
    end

    test "prices Toledo → Newport and a Newport loop inside 90 minutes as one $2.50 fare" do
      # Route 4 (TOL → NPT) then route 3 (NPT → NPT) is one change, which VALLEY's
      # `transfers` of 2 allows, and 07:40 → 09:10 is 5400 seconds, which its
      # `transfer_duration` covers exactly. LOCAL and COAST name no TOL → NPT cell, so
      # VALLEY at $2.50 is the only covering fare.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([
            leg("4", "TOLEDO", "NTC", at(7, 40), at(8, 55)),
            leg("3", "NTC", "HOSP", at(8, 30), at(9, 10))
          ])
        )

      assert result.total == Decimal.new("2.50")
      assert result.split? == false
      assert result.unknown? == false
      assert [%{fare_id: "VALLEY", price: valley, legs: 2}] = result.parts
      assert valley == Decimal.new("2.50")
    end

    test "prices a journey that crosses the contained zone as one fare" do
      # VALCOAST's `contains_id` row (TOL → CST, contains NPT) covers TOL → NPT → CST
      # at $5.00, which is less than the $6.00 the same journey costs leg by leg
      # (VALLEY $2.50 + COAST $3.50), and its `transfer_duration` of 5400 covers the
      # 5100 seconds from 07:40 to 09:05. Route 1 is read here in the Newport → Lincoln
      # City direction: the older model prices a journey by zone and route id.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([
            leg("4", "TOLEDO", "NTC", at(7, 40), at(8, 55)),
            leg("1", "NTC", "DEPOE", at(8, 55), at(9, 5))
          ])
        )

      assert result.total == Decimal.new("5.00")
      assert result.split? == false
      assert [%{fare_id: "VALCOAST", price: valcoast, legs: 2}] = result.parts
      assert valcoast == Decimal.new("5.00")
    end
  end

  describe "a journey no one fare covers" do
    test "prices Toledo → Corvallis as two fares totalling $8.50" do
      # No fare covers it: INTERCITY's only rule names route 10, so it never covers the
      # route 4 leg, and every other fare needs an origin and a destination the journey
      # does not have (its last stop is in no zone). Leg by leg, route 4 TOL → NPT is
      # VALLEY at $2.50 and route 10 NTC → Corvallis is INTERCITY at $6.00.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([
            leg("4", "TOLEDO", "NTC", at(7, 40), at(8, 55)),
            leg("10", "NTC", "CORVALLIS", at(9, 20), at(10, 20))
          ])
        )

      assert result.total == Decimal.new("8.50")
      assert result.split? == true
      assert result.unknown? == false

      assert [
               %{fare_id: "VALLEY", price: valley, from_stop_id: "TOLEDO", to_stop_id: "NTC"},
               %{
                 fare_id: "INTERCITY",
                 price: intercity,
                 from_stop_id: "NTC",
                 to_stop_id: "CORVALLIS"
               }
             ] = result.parts

      assert valley == Decimal.new("2.50")
      assert intercity == Decimal.new("6.00")
    end

    test "splits a 100-minute journey its fare's 90-minute transfer duration does not cover" do
      # The same journey as the covered case, waiting five minutes longer at Newport:
      # 07:40 → 09:40 is 6000 seconds, past VALLEY's `transfer_duration` of 5400, and
      # the leg-by-leg price of $2.50 + $1.50 is the answer instead.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([
            leg("4", "TOLEDO", "NTC", at(7, 40), at(8, 55)),
            leg("3", "NTC", "HOSP", at(9, 0), at(9, 40))
          ])
        )

      assert result.total == Decimal.new("4.00")
      assert result.split? == true

      assert [%{fare_id: "VALLEY", price: valley}, %{fare_id: "LOCAL", price: local}] =
               result.parts

      assert valley == Decimal.new("2.50")
      assert local == Decimal.new("1.50")
    end

    test "does not price two rides on a fare that allows no change" do
      # INTERCITY's `transfers` is 0, so it cannot cover two rides, and no other fare
      # names an origin and a destination in no zone. The journey is $12.00 rather than
      # one $6.00 fare.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([
            leg("10", "CORVALLIS", "NTC", at(10, 20), at(11, 20)),
            leg("10", "NTC", "CORVALLIS", at(11, 40), at(12, 40))
          ])
        )

      assert result.total == Decimal.new("12.00")
      assert result.split? == true
      assert Enum.map(result.parts, & &1.fare_id) == ["INTERCITY", "INTERCITY"]
    end
  end

  describe "a leg no fare covers" do
    test "leaves the total unknown rather than reading it as a free ride" do
      # Route 2 from NPT to a stop in no zone: INTERCITY is the only fare with an empty
      # destination, and it names route 10.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([leg("2", "NTC", "CORVALLIS", at(9, 25), at(9, 40))])
        )

      assert result.total == nil
      assert result.unknown? == true
      assert result.split? == false

      assert [%{fare_id: nil, price: nil, legs: 1, from_stop_id: "NTC", to_stop_id: "CORVALLIS"}] =
               result.parts
    end

    test "leaves the total unknown when only one leg of a split journey is unpriced" do
      # The same unpriced route 2 leg behind a priced one: the priced part is kept so
      # the Check a journey line can show what it could price, and the total stays nil.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([
            leg("3", "NTC", "NYE", at(8, 30), at(8, 50)),
            leg("2", "NTC", "CORVALLIS", at(9, 25), at(9, 40))
          ])
        )

      assert result.total == nil
      assert result.unknown? == true
      assert result.split? == true
      assert Enum.map(result.parts, & &1.fare_id) == ["LOCAL", nil]
    end
  end

  describe "contains_id rules" do
    test "need every one of a fare's rows to be crossed" do
      # TOL → NPT crosses NPT but never CST, so COASTAL at $1.00 does not apply, and
      # VALLEY's 90-minute duration is 5 minutes short of this journey's 100, so the
      # answer is the leg-by-leg VALLEY $2.50 + LOCAL $1.50.
      result =
        Interpreter.price_journey_v1(
          rows_with_coastal(),
          journey([
            leg("4", "TOLEDO", "NTC", at(7, 40), at(8, 55)),
            leg("3", "NTC", "NYE", at(9, 0), at(9, 20))
          ])
        )

      assert result.total == Decimal.new("4.00")
      assert result.split? == true
      assert Enum.map(result.parts, & &1.fare_id) == ["VALLEY", "LOCAL"]
    end

    test "apply once the journey crosses them all" do
      # TOL → NPT → CST crosses both, so the $1.00 fare wins over VALCOAST's $5.00.
      result =
        Interpreter.price_journey_v1(
          rows_with_coastal(),
          journey([
            leg("4", "TOLEDO", "NTC", at(7, 40), at(8, 55)),
            leg("1", "NTC", "DEPOE", at(8, 55), at(9, 5))
          ])
        )

      assert result.total == Decimal.new("1.00")
      assert result.split? == false
      assert [%{fare_id: "COASTAL", price: coastal, legs: 2}] = result.parts
      assert coastal == Decimal.new("1.00")
    end

    test "do not cover a journey that never reaches the zone" do
      # The sample's VALCOAST contains NPT, which this journey never crosses: TOL is its
      # first zone and its last stop is in no zone, so no fare covers the journey and it
      # is the leg-by-leg LOCAL $1.50 + INTERCITY $6.00.
      result =
        Interpreter.price_journey_v1(
          rows(),
          journey([
            leg("7", "SILETZ", "TOLEDO", at(8, 0), at(8, 35)),
            leg("10", "TOLEDO", "CORVALLIS", at(9, 20), at(10, 20))
          ])
        )

      assert result.total == Decimal.new("7.50")
      assert result.split? == true
      assert Enum.map(result.parts, & &1.fare_id) == ["LOCAL", "INTERCITY"]
    end
  end

  describe "a journey with no rides" do
    test "costs nothing and has no parts" do
      assert Interpreter.price_journey_v1(rows(), %{legs: []}) == %{
               total: Decimal.new(0),
               parts: [],
               split?: false,
               unknown?: false
             }
    end
  end

  # COASTAL is the cheapest fare in the sample, so it applies exactly when every one of
  # its `contains_id` rows is crossed, and never otherwise.
  defp rows_with_coastal do
    rows(
      [fare("COASTAL", "1.00", 2, 5400)],
      [rule("COASTAL", nil, nil, nil, "NPT"), rule("COASTAL", nil, nil, nil, "CST")]
    )
  end

  defp rows(extra_attributes \\ [], extra_rules \\ []) do
    %Rows{
      managed?: false,
      fare_attributes: attributes() ++ extra_attributes,
      fare_rules: fare_rules() ++ extra_rules,
      stop_zones: @stop_zones
    }
  end

  defp attributes do
    [
      fare("LOCAL", "1.50", 2, 5400),
      fare("VALLEY", "2.50", 2, 5400),
      fare("COAST", "3.50", 2, 5400),
      fare("VALCOAST", "5.00", 2, 5400),
      fare("INTERCITY", "6.00", 0, nil)
    ]
  end

  defp fare(fare_id, price, transfers, transfer_duration) do
    %FareAttribute{
      fare_id: fare_id,
      price: Decimal.new(price),
      currency_type: "USD",
      payment_method: 0,
      transfers: transfers,
      agency_id: "NCT",
      transfer_duration: transfer_duration
    }
  end

  defp fare_rules do
    [
      rule("LOCAL", nil, "NPT", "NPT", nil),
      rule("LOCAL", nil, "TOL", "TOL", nil),
      rule("LOCAL", nil, "CST", "CST", nil),
      rule("VALLEY", nil, "NPT", "TOL", nil),
      rule("VALLEY", nil, "TOL", "NPT", nil),
      rule("COAST", nil, "NPT", "CST", nil),
      rule("COAST", nil, "CST", "NPT", nil),
      rule("VALCOAST", nil, "TOL", "CST", nil),
      rule("VALCOAST", nil, "CST", "TOL", nil),
      rule("VALCOAST", nil, "TOL", "CST", "NPT"),
      rule("INTERCITY", "10", nil, nil, nil)
    ]
  end

  defp rule(fare_id, route_id, origin_id, destination_id, contains_id) do
    %FareRule{
      fare_id: fare_id,
      route_id: route_id,
      origin_id: origin_id,
      destination_id: destination_id,
      contains_id: contains_id
    }
  end

  defp journey(legs), do: %{rider_category_id: nil, fare_media_id: nil, legs: legs}

  defp leg(route_id, from_stop_id, to_stop_id, departs, arrives) do
    %{
      route_id: route_id,
      from_stop_id: from_stop_id,
      to_stop_id: to_stop_id,
      departs: departs,
      arrives: arrives
    }
  end

  defp at(hours, minutes), do: hours * 3600 + minutes * 60
end

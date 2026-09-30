defmodule GtfsPlanner.Gtfs.Schedules.ServiceMixTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Schedules.ServiceMix

  # Every date, service id and expected value below is literal and hand-derived from
  # the R9 rule and its examples in spec.md §4.2. Nothing here computes an
  # expectation with the module under test.

  @d1 ~D[2026-06-01]
  @d2 ~D[2026-06-02]
  @d3 ~D[2026-06-03]
  @d4 ~D[2026-06-04]
  @d5 ~D[2026-06-05]

  @listed_weekday %{service_id: "WKD", frequency?: false}
  @frequency_saturday %{service_id: "SAT", frequency?: true}

  # WKD runs Monday-Thursday; SAT shares Monday-Wednesday and adds Friday.
  @weekday_dates MapSet.new([@d1, @d2, @d3, @d4])
  @saturday_dates MapSet.new([@d1, @d2, @d3, @d5])

  describe "check/3" do
    test "refuses frequency service added on dates three of which carry a listed trip" do
      assert ServiceMix.check(
               [@listed_weekday],
               [@listed_weekday, @frequency_saturday],
               %{"WKD" => @weekday_dates, "SAT" => @saturday_dates}
             ) ==
               {:error, {:mixed_service, %{service_ids: ["SAT", "WKD"], date_count: 3}}}
    end

    test "accepts frequency service added on disjoint dates" do
      assert ServiceMix.check(
               [@listed_weekday],
               [@listed_weekday, @frequency_saturday],
               %{"WKD" => @weekday_dates, "SAT" => MapSet.new([@d5])}
             ) == :ok
    end

    test "accepts an already-mixed date that stays mixed" do
      assert ServiceMix.check(
               [@listed_weekday, @frequency_saturday],
               [@listed_weekday, @frequency_saturday, %{service_id: "SUN", frequency?: true}],
               %{
                 "WKD" => @weekday_dates,
                 "SAT" => @saturday_dates,
                 "SUN" => MapSet.new([@d2, @d3])
               }
             ) == :ok
    end

    test "accepts an imported mix the action leaves unchanged" do
      trips = [@listed_weekday, @frequency_saturday]

      assert ServiceMix.check(trips, trips, %{
               "WKD" => @weekday_dates,
               "SAT" => @saturday_dates
             }) == :ok
    end

    test "accepts removing the frequency service" do
      assert ServiceMix.check(
               [@listed_weekday, @frequency_saturday],
               [@listed_weekday],
               %{"WKD" => @weekday_dates, "SAT" => @saturday_dates}
             ) == :ok
    end

    test "refuses frequency service added to the service that carries the listed trips" do
      assert ServiceMix.check(
               [%{service_id: "WKD", frequency?: false}],
               [%{service_id: "WKD", frequency?: false}, %{service_id: "WKD", frequency?: true}],
               %{"WKD" => MapSet.new([@d1, @d2])}
             ) ==
               {:error, {:mixed_service, %{service_ids: ["WKD"], date_count: 2}}}
    end

    test "counts only the dates that became mixed and names every service running on them" do
      assert ServiceMix.check(
               [%{service_id: "A", frequency?: false}, %{service_id: "B", frequency?: true}],
               [%{service_id: "C", frequency?: false}, %{service_id: "B", frequency?: true}],
               %{
                 "A" => MapSet.new([@d1]),
                 "B" => MapSet.new([@d1, @d2, @d3]),
                 "C" => MapSet.new([@d1, @d2, @d3])
               }
             ) ==
               {:error, {:mixed_service, %{service_ids: ["B", "C"], date_count: 2}}}
    end

    test "accepts a date that was already mixed when different services carry the kinds" do
      assert ServiceMix.check(
               [%{service_id: "A", frequency?: false}, %{service_id: "B", frequency?: true}],
               [%{service_id: "C", frequency?: false}, %{service_id: "B", frequency?: true}],
               %{
                 "A" => MapSet.new([@d1]),
                 "B" => MapSet.new([@d1]),
                 "C" => MapSet.new([@d1])
               }
             ) == :ok
    end

    test "accepts trips of one kind growing on shared dates" do
      assert ServiceMix.check(
               [@listed_weekday],
               [@listed_weekday, %{service_id: "SAT", frequency?: false}],
               %{"WKD" => @weekday_dates, "SAT" => @saturday_dates}
             ) == :ok

      assert ServiceMix.check(
               [@frequency_saturday],
               [@frequency_saturday, %{service_id: "WKD", frequency?: true}],
               %{"WKD" => @weekday_dates, "SAT" => @saturday_dates}
             ) == :ok
    end

    test "counts each newly mixed date once however many trips share it" do
      assert ServiceMix.check(
               [@listed_weekday],
               [
                 @listed_weekday,
                 %{service_id: "WKD", frequency?: false},
                 @frequency_saturday,
                 %{service_id: "SAT", frequency?: true}
               ],
               %{"WKD" => @weekday_dates, "SAT" => @saturday_dates}
             ) ==
               {:error, {:mixed_service, %{service_ids: ["SAT", "WKD"], date_count: 3}}}
    end

    test "accepts a service the caller's date map does not name" do
      assert ServiceMix.check(
               [@listed_weekday],
               [@listed_weekday, @frequency_saturday],
               %{"WKD" => @weekday_dates}
             ) == :ok
    end

    test "accepts empty trip lists" do
      assert ServiceMix.check([], [], %{}) == :ok
    end
  end
end

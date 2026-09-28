defmodule GtfsPlanner.Gtfs.Blocking.DayTypesTest do
  @moduledoc """
  Merge evidence (EV-2) for the pure day-type derivation:

  - A and B active on Monday, A and C active on Tuesday derive exactly two day types,
    and a service's day types come back in list order.
  - Keys are 43 URL-safe characters, do not depend on the order the service IDs
    arrive in, and separate `["A+B", "C"]` from `["A", "B+C"]`.
  - Order is trip count descending, then date count descending, then key ascending.
  - Labels join the services' names in service-ID order and fall back to the ID for a
    missing or blank name; `special?` is true exactly for one-date day types.
  - Service dates map each service ID to the set of its active dates.
  - 200 fixed-seed cases of up to six services over one 60-day window match an
    independent per-date grouping that never calls the derived day types' internals.

  The focused gate command is deferred to branch review:
  `mix test test/gtfs_planner/gtfs/blocking/day_types_test.exs`. Every expectation is
  hand-derived or produced by the fixed-seed generator plus that oracle; the module
  reads no database, clock, files or network.
  """
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.DayTypes

  # Fixed generator seed and bounded window: case `index` starts its window at
  # `@window_start + index * @window_days`, so any failing case is reproducible on its
  # own. The generator never shares a window between cases.
  @seeded_cases 200
  @seeded_services 6
  @seeded_seed {1, 2, 3}
  @window_days 60
  @window_start ~D[2026-01-05]

  # The canonical key of one service named "A": SHA-256 of `["A"]` as JSON, unpadded
  # URL-safe Base64. Computed from R1 outside this module.
  @key_of_a "0qSzfKwKV-QrH-ACpowkSafkFkbuwakqDwrNOfrlic4"

  describe "derive/1" do
    test "groups one week into one day type per exact service set" do
      monday = ~D[2026-01-05]
      tuesday = ~D[2026-01-06]

      calendars = [
        calendar("A", "Weekday", [monday, tuesday], 5),
        calendar("B", "Monday only", [monday], 3),
        calendar("C", "Tuesday only", [tuesday], 2)
      ]

      assert [
               %{service_ids: ["A", "B"], dates: [^monday], date_count: 1},
               %{service_ids: ["A", "C"], dates: [^tuesday], date_count: 1}
             ] = DayTypes.derive(calendars)
    end

    test "derives no day types from no calendars" do
      assert DayTypes.derive([]) == []
    end

    test "orders by trip count, then date count, then key" do
      calendars = [
        calendar("bulk", "Bulk", dates(0, 100), 500),
        calendar("long", "Long", dates(100, 210), 12),
        calendar("many", "Many", dates(310, 5), 40),
        calendar("few", "Few", dates(315, 3), 40),
        calendar("tie_b", "Tie B", dates(318, 2), 9),
        calendar("tie_a", "Tie A", dates(320, 2), 9),
        calendar("tie_c", "Tie C", dates(322, 2), 9)
      ]

      day_types = DayTypes.derive(calendars)
      service_ids = Enum.map(day_types, & &1.service_ids)

      assert length(day_types) == 7

      # 500 trips beats the 210-date day type's 12; equal trip counts put the
      # five-date day type before the three-date one.
      assert Enum.take(service_ids, 3) == [["bulk"], ["many"], ["few"]]

      long_index = Enum.find_index(service_ids, &(&1 == ["long"]))
      bulk_index = Enum.find_index(service_ids, &(&1 == ["bulk"]))
      assert long_index > bulk_index
      assert %{date_count: 210, trip_count: 12} = Enum.at(day_types, long_index)

      ties = Enum.filter(day_types, &(&1.trip_count == 9))
      assert Enum.sort(Enum.map(ties, & &1.service_ids)) == [["tie_a"], ["tie_b"], ["tie_c"]]
      assert Enum.map(ties, & &1.key) == Enum.sort(Enum.map(ties, & &1.key))
    end

    test "labels with the services' names in service-ID order and marks one-date day types special" do
      monday = ~D[2026-01-05]
      tuesday = ~D[2026-01-06]
      wednesday = ~D[2026-01-07]

      calendars = [
        calendar("A", "Weekday", [monday, tuesday], 1),
        calendar("B", nil, [monday, tuesday], 1),
        calendar("C", "   ", [monday, tuesday], 1),
        calendar("D", "Special day", [wednesday], 1)
      ]

      day_types = DayTypes.derive(calendars)

      assert %{label: "Weekday + B + C", special?: false, date_count: 2} =
               find_day_type(day_types, ["A", "B", "C"])

      assert %{label: "Special day", special?: true, date_count: 1} =
               find_day_type(day_types, ["D"])
    end

    test "matches an independent per-date grouping across 200 seeded calendars" do
      cases = generated_cases()

      assert length(cases) == @seeded_cases

      for {index, calendars, window} <- cases do
        assert_matches_independent_grouping(index, calendars, window)
      end
    end
  end

  describe "containing/2" do
    test "returns the day types of one service in list order" do
      monday = ~D[2026-01-05]
      tuesday = ~D[2026-01-06]

      day_types =
        DayTypes.derive([
          calendar("A", "A", [monday, tuesday], 5),
          calendar("B", "B", [monday], 3),
          calendar("C", "C", [tuesday], 2)
        ])

      assert Enum.map(DayTypes.containing(day_types, "A"), & &1.service_ids) == [
               ["A", "B"],
               ["A", "C"]
             ]

      assert Enum.map(DayTypes.containing(day_types, "B"), & &1.service_ids) == [["A", "B"]]
      assert DayTypes.containing(day_types, "D") == []
    end
  end

  describe "key/1" do
    test "is the 43-character URL-safe digest of the sorted service IDs" do
      key = DayTypes.key(["B", "A"])

      assert String.length(key) == 43
      assert key =~ ~r/\A[A-Za-z0-9_-]{43}\z/

      assert DayTypes.key(["A"]) == @key_of_a
      assert key == DayTypes.key(["A", "B"])
      refute key == DayTypes.key(["A", "B", "C"])
      refute DayTypes.key(["A+B", "C"]) == DayTypes.key(["A", "B+C"])
    end
  end

  describe "service_dates/1" do
    test "maps each service to the set of its active dates" do
      monday = ~D[2026-01-05]
      tuesday = ~D[2026-01-06]

      assert DayTypes.service_dates([
               calendar("A", "A", [monday, tuesday], 3),
               calendar("B", nil, [], 0)
             ]) == %{
               "A" => MapSet.new([monday, tuesday]),
               "B" => MapSet.new()
             }
    end
  end

  defp calendar(service_id, name, active_dates, trip_count) do
    %{service_id: service_id, name: name, active_dates: active_dates, trip_count: trip_count}
  end

  defp dates(offset, count) do
    for index <- 0..(count - 1), do: Date.add(@window_start, offset + index)
  end

  defp find_day_type(day_types, service_ids) do
    Enum.find(day_types, &(&1.service_ids == service_ids))
  end

  # -- fixed-seed generator and independent oracle -----------------------------

  # One case is up to six services over one 60-day window: a random weekday mask per
  # service, then a random exception flip per date, so a service can gain dates the
  # mask excludes and lose dates it includes.
  defp generated_cases do
    :rand.seed(:exsss, @seeded_seed)

    for index <- 1..@seeded_cases do
      start = Date.add(@window_start, index * @window_days)
      window = Enum.map(0..(@window_days - 1), &Date.add(start, &1))

      calendars =
        for number <- 1..:rand.uniform(@seeded_services) do
          generated_calendar(index, number, start)
        end

      {index, calendars, window}
    end
  end

  defp generated_calendar(index, number, start) do
    mask = :rand.uniform(128) - 1

    active_dates =
      0..(@window_days - 1)
      |> Enum.filter(fn offset ->
        weekly? = Bitwise.band(mask, Bitwise.bsl(1, rem(offset, 7))) != 0
        exception? = :rand.uniform(10) == 1
        weekly? != exception?
      end)
      |> Enum.map(&Date.add(start, &1))

    %{
      service_id: "service-#{index}-#{number}",
      name: if(rem(number, 2) == 0, do: nil, else: "Service #{number}"),
      active_dates: active_dates,
      trip_count: :rand.uniform(50)
    }
  end

  defp assert_matches_independent_grouping(index, calendars, window) do
    day_types = DayTypes.derive(calendars)
    {expected_by_services, expected_by_date} = independent_grouping(calendars, window)

    assert length(day_types) == map_size(expected_by_services), "case #{index} day type count"

    assert Map.new(day_types, &{MapSet.new(&1.service_ids), &1.dates}) == expected_by_services,
           "case #{index} grouping"

    for date <- window do
      containing = Enum.filter(day_types, &(date in &1.dates))

      case Map.fetch(expected_by_date, date) do
        {:ok, service_ids} ->
          assert length(containing) == 1, "case #{index} #{Date.to_iso8601(date)}"
          assert MapSet.new(hd(containing).service_ids) == service_ids, "case #{index}"

        :error ->
          assert containing == [], "case #{index} inactive #{Date.to_iso8601(date)}"
      end
    end

    for day_type <- day_types do
      members = Enum.filter(calendars, &(&1.service_id in day_type.service_ids))
      label = "case #{index} #{inspect(day_type.service_ids)}"

      assert day_type.dates == Enum.sort(day_type.dates, Date), "#{label} ascending dates"
      assert day_type.date_count == length(day_type.dates), "#{label} date count"
      assert day_type.first_date == hd(day_type.dates), "#{label} first date"
      assert day_type.last_date == List.last(day_type.dates), "#{label} last date"
      assert day_type.special? == (day_type.date_count == 1), "#{label} special"
      assert day_type.trip_count == Enum.sum(Enum.map(members, & &1.trip_count)), label
    end
  end

  # Groups every window date by the services active on that date using plain list
  # membership, then reads the result back per date. It never calls `derive/1` and
  # shares no code with the module under test.
  defp independent_grouping(calendars, window) do
    {by_services, by_date} =
      Enum.reduce(window, {%{}, %{}}, fn date, {by_services, by_date} ->
        service_ids =
          calendars |> Enum.filter(&(date in &1.active_dates)) |> MapSet.new(& &1.service_id)

        if MapSet.size(service_ids) == 0 do
          {by_services, by_date}
        else
          {Map.update(by_services, service_ids, [date], &(&1 ++ [date])),
           Map.put(by_date, date, service_ids)}
        end
      end)

    {by_services, by_date}
  end
end

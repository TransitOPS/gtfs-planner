defmodule GtfsPlanner.Gtfs.RoutePatterns.MaterializerTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer

  test "rebases first-stop dwell and keeps retained absolute values fixed" do
    old = [%{id: "a", stop_id: "A"}, %{id: "b", stop_id: "B"}, %{id: "c", stop_id: "C"}]
    new = [%{id: "b", stop_id: "B"}, %{id: "c", stop_id: "C"}]

    rows = [
      %{arrival_offset: -60, departure_offset: 0},
      %{arrival_offset: 240, departure_offset: 300},
      %{arrival_offset: 600, departure_offset: 660}
    ]

    values = %{"t1" => %{}}

    assert {:ok, %{start_shift: 300, timing_rows: [timing]}} =
             Materializer.review_stops(old, new, [%{timing_id: "t1", rows: rows}], values)

    assert Enum.map(timing.rows, &{&1.arrival_offset, &1.departure_offset}) == [
             {-60, 0},
             {300, 360}
           ]
  end

  test "divides a bracketed interval between every inserted stop it holds" do
    old = [%{id: "a", stop_id: "A"}, %{id: "b", stop_id: "B"}]

    new = [
      %{id: "a", stop_id: "A"},
      %{key: "x", stop_id: "X"},
      %{key: "y", stop_id: "Y"},
      %{id: "b", stop_id: "B"}
    ]

    rows = [
      %{arrival_offset: 0, departure_offset: 0},
      %{arrival_offset: 600, departure_offset: 600}
    ]

    assert {:ok, %{timing_rows: [timing]}} =
             Materializer.review_stops(old, new, [%{timing_id: "t1", rows: rows}], %{"t1" => %{}})

    assert Enum.map(timing.rows, & &1.arrival_offset) == [0, 200, 400, 600]

    # Three insertions floor each share of an interval that does not divide
    # evenly: floor(10/4), floor(20/4), floor(30/4).
    three = [
      %{id: "a", stop_id: "A"},
      %{key: "x", stop_id: "X"},
      %{key: "y", stop_id: "Y"},
      %{key: "z", stop_id: "Z"},
      %{id: "b", stop_id: "B"}
    ]

    short_rows = [
      %{arrival_offset: 0, departure_offset: 0},
      %{arrival_offset: 10, departure_offset: 10}
    ]

    assert {:ok, %{timing_rows: [short]}} =
             Materializer.review_stops(old, three, [%{timing_id: "t1", rows: short_rows}], %{
               "t1" => %{}
             })

    assert Enum.map(short.rows, & &1.arrival_offset) == [0, 2, 5, 7, 10]
  end

  test "interpolates each timing against its own anchors" do
    old = [%{id: "a", stop_id: "A"}, %{id: "b", stop_id: "B"}]
    new = [%{id: "a", stop_id: "A"}, %{key: "x", stop_id: "X"}, %{id: "b", stop_id: "B"}]

    timings = [
      %{
        timing_id: "weekday",
        rows: [
          %{arrival_offset: 0, departure_offset: 0},
          %{arrival_offset: 600, departure_offset: 600}
        ]
      },
      %{
        timing_id: "weekend",
        rows: [
          %{arrival_offset: 0, departure_offset: 0},
          %{arrival_offset: 900, departure_offset: 1_200}
        ]
      }
    ]

    values = %{"weekday" => %{}, "weekend" => %{}}

    assert {:ok, %{timing_rows: timing_rows}} =
             Materializer.review_stops(old, new, timings, values)

    by_id = Map.new(timing_rows, fn row -> {row.timing_id, row.rows} end)
    assert Enum.map(by_id["weekday"], & &1.arrival_offset) == [0, 300, 600]
    assert Enum.map(by_id["weekend"], & &1.arrival_offset) == [0, 450, 900]
  end

  test "materializes absolute clocks and rejects a negative resulting time or chronology" do
    occurrences = [%{id: "a", stop_id: "A"}, %{id: "b", stop_id: "B"}]

    rows = [
      %{arrival_offset: -60, departure_offset: 0},
      %{arrival_offset: 240, departure_offset: 300}
    ]

    assert {:ok,
            [
              %{arrival_time: "07:59:00", departure_time: "08:00:00"},
              %{arrival_time: "08:04:00", departure_time: "08:05:00"}
            ]} =
             Materializer.materialize(28_800, occurrences, rows)

    assert {:error, :negative_time} = Materializer.materialize(30, occurrences, rows)

    assert {:error, :invalid_chronology} =
             Materializer.materialize(28_800, occurrences, [
               %{arrival_offset: 60, departure_offset: 0},
               %{arrival_offset: 30, departure_offset: 30}
             ])
  end

  test "estimates interior insertions by integer interpolation and requires explicit terminal values" do
    old = [%{id: "a", stop_id: "A"}, %{id: "b", stop_id: "B"}]
    new = [%{id: "a", stop_id: "A"}, %{key: "x", stop_id: "X"}, %{id: "b", stop_id: "B"}]

    rows = [
      %{arrival_offset: -60, departure_offset: 0},
      %{arrival_offset: 301, departure_offset: 360}
    ]

    assert {:ok, %{estimates: [estimate], timing_rows: [timing]}} =
             Materializer.review_stops(old, new, [%{timing_id: "t1", rows: rows}], %{"t1" => %{}})

    assert estimate.arrival_offset == 150
    assert estimate.departure_offset == 150
    added = Enum.at(timing.rows, 1)
    assert added.timepoint == 0
    assert added.pickup_type == 0
    assert added.drop_off_type == 0
    assert is_nil(added.stop_headsign)

    terminal = [%{key: "x", stop_id: "X"}, %{id: "b", stop_id: "B"}]

    assert {:error, :explicit_terminal_values_required} =
             Materializer.review_stops(old, terminal, [%{timing_id: "t1", rows: rows}], %{
               "t1" => %{}
             })
  end
end

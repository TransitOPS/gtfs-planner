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

  describe "reordering retained stops" do
    @old [%{id: "a", stop_id: "A"}, %{id: "b", stop_id: "B"}, %{id: "c", stop_id: "C"}]

    defp timed_rows do
      [
        %{
          arrival_offset: 0,
          departure_offset: 0,
          timepoint: 1,
          pickup_type: 0,
          drop_off_type: 1,
          stop_headsign: "Alpha"
        },
        %{
          arrival_offset: 300,
          departure_offset: 360,
          timepoint: 0,
          pickup_type: 1,
          drop_off_type: 0,
          stop_headsign: "Bravo"
        },
        %{
          arrival_offset: 900,
          departure_offset: 900,
          timepoint: 1,
          pickup_type: 2,
          drop_off_type: 3,
          stop_headsign: "Charlie"
        }
      ]
    end

    test "gives each retained stop the time slot of its new position and moves its own attributes with it" do
      new = [%{id: "a", stop_id: "A"}, %{id: "c", stop_id: "C"}, %{id: "b", stop_id: "B"}]

      assert {:ok, %{start_shift: 0, timing_rows: [%{rows: [first, second, third]}]}} =
               Materializer.review_stops(
                 @old,
                 new,
                 [%{timing_id: "t1", rows: timed_rows()}],
                 %{"t1" => %{}}
               )

      assert first == %{
               arrival_offset: 0,
               departure_offset: 0,
               timepoint: 1,
               pickup_type: 0,
               drop_off_type: 1,
               stop_headsign: "Alpha"
             }

      assert second == %{
               arrival_offset: 300,
               departure_offset: 360,
               timepoint: 1,
               pickup_type: 2,
               drop_off_type: 3,
               stop_headsign: "Charlie"
             }

      assert third == %{
               arrival_offset: 900,
               departure_offset: 900,
               timepoint: 0,
               pickup_type: 1,
               drop_off_type: 0,
               stop_headsign: "Bravo"
             }
    end

    test "flags each row whose time changed as a re-sequenced estimate" do
      new = [%{id: "a", stop_id: "A"}, %{id: "c", stop_id: "C"}, %{id: "b", stop_id: "B"}]

      assert {:ok, %{estimates: estimates}} =
               Materializer.review_stops(
                 @old,
                 new,
                 [%{timing_id: "t1", rows: timed_rows()}],
                 %{"t1" => %{}}
               )

      assert estimates == [
               %{
                 id: "c",
                 timing_id: "t1",
                 arrival_offset: 300,
                 departure_offset: 360,
                 resequenced: true
               },
               %{
                 id: "b",
                 timing_id: "t1",
                 arrival_offset: 900,
                 departure_offset: 900,
                 resequenced: true
               }
             ]
    end

    test "keeps the first departure at the timing's first departure when the first stop moves" do
      new = [%{id: "b", stop_id: "B"}, %{id: "a", stop_id: "A"}, %{id: "c", stop_id: "C"}]

      assert {:ok, %{start_shift: 0, timing_rows: [%{rows: rows}]}} =
               Materializer.review_stops(
                 @old,
                 new,
                 [%{timing_id: "t1", rows: timed_rows()}],
                 %{"t1" => %{}}
               )

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset}) ==
               [{0, 0}, {300, 360}, {900, 900}]

      assert Enum.map(rows, & &1.stop_headsign) == ["Bravo", "Alpha", "Charlie"]
    end

    test "keeps a first-stop dwell as the first slot and shifts nothing" do
      dwell_rows = [
        %{arrival_offset: -60, departure_offset: 0},
        %{arrival_offset: 240, departure_offset: 300},
        %{arrival_offset: 600, departure_offset: 660}
      ]

      new = [%{id: "b", stop_id: "B"}, %{id: "a", stop_id: "A"}, %{id: "c", stop_id: "C"}]

      assert {:ok, %{start_shift: 0, timing_rows: [%{rows: rows}]}} =
               Materializer.review_stops(
                 @old,
                 new,
                 [%{timing_id: "t1", rows: dwell_rows}],
                 %{"t1" => %{}}
               )

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset}) ==
               [{-60, 0}, {240, 300}, {600, 660}]
    end

    test "leaves times and estimates alone when the retained order does not change" do
      removed_middle = [%{id: "a", stop_id: "A"}, %{id: "c", stop_id: "C"}]

      assert {:ok, %{estimates: [], timing_rows: [%{rows: rows}]}} =
               Materializer.review_stops(
                 @old,
                 removed_middle,
                 [%{timing_id: "t1", rows: timed_rows()}],
                 %{"t1" => %{}}
               )

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset}) == [{0, 0}, {900, 900}]
    end

    test "reports no estimate when swapped stops share identical times" do
      zero_rows = for _ <- 1..3, do: %{arrival_offset: 0, departure_offset: 0}
      new = [%{id: "b", stop_id: "B"}, %{id: "a", stop_id: "A"}, %{id: "c", stop_id: "C"}]

      assert {:ok, %{estimates: []}} =
               Materializer.review_stops(
                 @old,
                 new,
                 [%{timing_id: "t1", rows: zero_rows}],
                 %{"t1" => %{}}
               )
    end

    test "re-sequences each timing against its own times" do
      weekend_rows = [
        %{arrival_offset: 0, departure_offset: 0},
        %{arrival_offset: 450, departure_offset: 480},
        %{arrival_offset: 1_200, departure_offset: 1_200}
      ]

      new = [%{id: "a", stop_id: "A"}, %{id: "c", stop_id: "C"}, %{id: "b", stop_id: "B"}]

      timings = [
        %{timing_id: "weekday", rows: timed_rows()},
        %{timing_id: "weekend", rows: weekend_rows}
      ]

      assert {:ok, %{timing_rows: timing_rows, estimates: estimates}} =
               Materializer.review_stops(@old, new, timings, %{"weekday" => %{}, "weekend" => %{}})

      by_id = Map.new(timing_rows, &{&1.timing_id, &1.rows})

      assert Enum.map(by_id["weekday"], &{&1.arrival_offset, &1.departure_offset}) ==
               [{0, 0}, {300, 360}, {900, 900}]

      assert Enum.map(by_id["weekend"], &{&1.arrival_offset, &1.departure_offset}) ==
               [{0, 0}, {450, 480}, {1_200, 1_200}]

      assert Enum.map(estimates, &{&1.timing_id, &1.id}) ==
               [{"weekday", "c"}, {"weekday", "b"}, {"weekend", "c"}, {"weekend", "b"}]
    end

    test "estimates an added stop between the re-sequenced neighbours in the same review" do
      new = [
        %{id: "a", stop_id: "A"},
        %{key: "x", stop_id: "X"},
        %{id: "c", stop_id: "C"},
        %{id: "b", stop_id: "B"}
      ]

      assert {:ok, %{timing_rows: [%{rows: rows}], estimates: estimates}} =
               Materializer.review_stops(
                 @old,
                 new,
                 [%{timing_id: "t1", rows: timed_rows()}],
                 %{"t1" => %{}}
               )

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset}) ==
               [{0, 0}, {150, 150}, {300, 360}, {900, 900}]

      assert Enum.map(estimates, &{&1[:id], &1[:key]}) == [{"c", nil}, {"b", nil}, {nil, "x"}]
    end

    test "ignores the time slot of a removed stop" do
      four = @old ++ [%{id: "d", stop_id: "D"}]

      rows =
        timed_rows() ++
          [%{arrival_offset: 1_200, departure_offset: 1_200, stop_headsign: "Delta"}]

      new = [%{id: "a", stop_id: "A"}, %{id: "d", stop_id: "D"}, %{id: "b", stop_id: "B"}]

      assert {:ok, %{timing_rows: [%{rows: reviewed}]}} =
               Materializer.review_stops(four, new, [%{timing_id: "t1", rows: rows}], %{
                 "t1" => %{}
               })

      assert Enum.map(reviewed, &{&1.arrival_offset, &1.departure_offset, &1.stop_headsign}) ==
               [{0, 0, "Alpha"}, {300, 360, "Delta"}, {1_200, 1_200, "Bravo"}]
    end
  end
end

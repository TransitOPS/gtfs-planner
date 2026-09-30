defmodule GtfsPlanner.Gtfs.TimingFillTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.TimingFill

  # Summer weekday-like timing: times at the first and last stops only, eight
  # blank non-timepoint stops between them, 100 m hops, 540 s span.
  defp summer_rows do
    [
      %{
        position: 1,
        arrival: "08:00:00",
        departure: "08:00:00",
        timepoint: true,
        estimated: false
      },
      %{position: 2, arrival: "", departure: "", timepoint: false, estimated: false},
      %{position: 3, arrival: "", departure: "", timepoint: false, estimated: false},
      %{position: 4, arrival: "", departure: "", timepoint: false, estimated: false},
      %{position: 5, arrival: "", departure: "", timepoint: false, estimated: false},
      %{position: 6, arrival: "", departure: "", timepoint: false, estimated: false},
      %{position: 7, arrival: "", departure: "", timepoint: false, estimated: false},
      %{position: 8, arrival: "", departure: "", timepoint: false, estimated: false},
      %{position: 9, arrival: "", departure: "", timepoint: false, estimated: false},
      %{
        position: 10,
        arrival: "08:09:00",
        departure: "08:09:00",
        timepoint: true,
        estimated: false
      }
    ]
  end

  defp summer_distances, do: Enum.map(0..9, &(&1 * 100.0))
  defp no_coords(count), do: List.duplicate(nil, count)

  describe "default_scope/1" do
    test "is :missing when a middle non-timepoint row has a blank" do
      assert TimingFill.default_scope(summer_rows()) == :missing
    end

    test "is :between when every middle non-timepoint row is timed" do
      rows = [
        %{
          position: 1,
          arrival: "08:00:00",
          departure: "08:00:00",
          timepoint: true,
          estimated: false
        },
        %{
          position: 2,
          arrival: "08:01:00",
          departure: "08:01:00",
          timepoint: false,
          estimated: false
        },
        %{
          position: 3,
          arrival: "08:02:00",
          departure: "08:02:00",
          timepoint: true,
          estimated: false
        }
      ]

      assert TimingFill.default_scope(rows) == :between
    end
  end

  describe "preview/4 with scope :missing" do
    test "fills eight blanks with literal distance shares and reports changed 8" do
      preview =
        TimingFill.preview(summer_rows(), summer_distances(), no_coords(10),
          scope: :missing,
          method: :distance
        )

      assert preview.changed == 8
      assert preview.problems == []
      assert preview.fast_spans == []

      assert preview.summary ==
               "Fills 8 stops in 1 section between timepoints. Every time already here stays as it is."

      by_position = Map.new(preview.rows, &{&1.position, &1})

      # 540 s over 900 m in ninths: floor(60 * k) past 08:00:00.
      expected = %{
        2 => 28_860,
        3 => 28_920,
        4 => 28_980,
        5 => 29_040,
        6 => 29_100,
        7 => 29_160,
        8 => 29_220,
        9 => 29_280
      }

      for {position, seconds} <- expected do
        row = by_position[position]
        assert row.arrival == seconds
        assert row.departure == seconds
        assert row.estimated == true
      end

      assert %{arrival: 28_800, departure: 28_800, estimated: false} =
               Map.take(by_position[1], [:arrival, :departure, :estimated])

      assert %{arrival: 29_340, departure: 29_340, estimated: false} =
               Map.take(by_position[10], [:arrival, :departure, :estimated])
    end

    test "a timepoint with a blank value yields a problem naming its position" do
      rows = [
        %{
          position: 1,
          arrival: "08:00:00",
          departure: "08:00:00",
          timepoint: true,
          estimated: false
        },
        %{position: 2, arrival: "", departure: "", timepoint: false, estimated: false},
        %{position: 3, arrival: "", departure: "", timepoint: true, estimated: false},
        %{
          position: 4,
          arrival: "08:10:00",
          departure: "08:10:00",
          timepoint: true,
          estimated: false
        }
      ]

      preview =
        TimingFill.preview(rows, [0.0, 100.0, 200.0, 300.0], no_coords(4),
          scope: :missing,
          method: :distance
        )

      assert preview.changed == 0

      assert preview.problems == [
               %{
                 position: 3,
                 kind: :timepoint_without_time,
                 message:
                   "Stop 3 is a timepoint without a time, so the stops around it were left blank."
               }
             ]
    end

    test "a 97 mph span appears in fast_spans without blocking the fill" do
      rows = [
        %{
          position: 1,
          arrival: "08:00:00",
          departure: "08:00:00",
          timepoint: true,
          estimated: false
        },
        %{position: 2, arrival: "", departure: "", timepoint: false, estimated: false},
        %{
          position: 3,
          arrival: "08:02:00",
          departure: "08:02:00",
          timepoint: true,
          estimated: false
        }
      ]

      preview =
        TimingFill.preview(rows, [0.0, 2_600.0, 5_200.0], no_coords(3),
          scope: :missing,
          method: :distance
        )

      assert preview.changed == 1
      assert preview.problems == []
      assert [%{from_position: 1, to_position: 3, mph: mph}] = preview.fast_spans
      assert_in_delta mph, 97.0, 1.0
    end

    test "an unparsable staged value is treated as blank and reported" do
      rows = [
        %{
          position: 1,
          arrival: "08:00:00",
          departure: "08:00:00",
          timepoint: true,
          estimated: false
        },
        %{position: 2, arrival: "midnight", departure: "", timepoint: false, estimated: false},
        %{
          position: 3,
          arrival: "08:06:00",
          departure: "08:06:00",
          timepoint: true,
          estimated: false
        }
      ]

      preview =
        TimingFill.preview(rows, [0.0, 100.0, 200.0], no_coords(3),
          scope: :missing,
          method: :distance
        )

      assert preview.changed == 1

      by_position = Map.new(preview.rows, &{&1.position, &1})
      assert by_position[2].arrival == 28_980
      assert by_position[2].estimated == true

      assert preview.problems == [
               %{
                 position: 2,
                 kind: :invalid_time,
                 message: "midnight at stop 2 is not a valid time and was treated as blank."
               }
             ]
    end
  end

  describe "preview/4 with scope :between" do
    test "recalculates typed non-timepoint rows while timepoints never change" do
      rows = [
        %{
          position: 1,
          arrival: "08:00:00",
          departure: "08:00:00",
          timepoint: true,
          estimated: false
        },
        %{
          position: 2,
          arrival: "08:01:00",
          departure: "08:01:00",
          timepoint: false,
          estimated: false
        },
        %{
          position: 3,
          arrival: "08:05:00",
          departure: "08:05:00",
          timepoint: false,
          estimated: false
        },
        %{
          position: 4,
          arrival: "08:12:00",
          departure: "08:12:00",
          timepoint: true,
          estimated: false
        }
      ]

      preview =
        TimingFill.preview(rows, [0.0, 100.0, 200.0, 300.0], no_coords(4),
          scope: :between,
          method: :distance
        )

      assert preview.changed == 2

      assert preview.summary ==
               "Recalculates 2 stops in 1 section between timepoints. Timepoint times never change."

      by_position = Map.new(preview.rows, &{&1.position, &1})
      assert %{arrival: 29_040, departure: 29_040, estimated: true} = by_position[2]
      assert %{arrival: 29_280, departure: 29_280, estimated: true} = by_position[3]
      assert %{arrival: 28_800, estimated: false} = by_position[1]
      assert %{arrival: 29_520, estimated: false} = by_position[4]
    end
  end

  describe "apply_preview/2" do
    test "writes formatted offsets with estimated true only on changed rows" do
      rows = summer_rows()

      preview =
        TimingFill.preview(rows, summer_distances(), no_coords(10),
          scope: :missing,
          method: :distance
        )

      applied = TimingFill.apply_preview(rows, preview)
      by_position = Map.new(applied, &{&1.position, &1})

      expected_strings = %{
        2 => "08:01:00",
        3 => "08:02:00",
        4 => "08:03:00",
        5 => "08:04:00",
        6 => "08:05:00",
        7 => "08:06:00",
        8 => "08:07:00",
        9 => "08:08:00"
      }

      for {position, string} <- expected_strings do
        row = by_position[position]
        assert row.arrival == string
        assert row.departure == string
        assert row.estimated == true
        assert row.timepoint == false
      end

      assert by_position[1].arrival == "08:00:00"
      assert by_position[1].estimated == false
      assert by_position[10].departure == "08:09:00"
      assert by_position[10].estimated == false
    end
  end

  describe "retime_candidates/5" do
    defp lincoln_rows(edited_sixth) do
      base = [
        {"08:00:00", true},
        {"08:00:30", false},
        {"08:01:00", false},
        {"08:01:40", true},
        {"08:03:20", false},
        {"08:06:40", true},
        {"08:08:20", false},
        {"08:10:00", false},
        {"08:11:40", false},
        {"08:13:20", false},
        {"08:16:40", true}
      ]

      Enum.with_index(base, 1)
      |> Enum.map(fn {{time, timepoint}, position} ->
        time = if position == 6, do: edited_sixth, else: time

        %{
          position: position,
          arrival: time,
          departure: time,
          timepoint: timepoint,
          estimated: false
        }
      end)
    end

    test "reports the moved anchor with the signed change and stops that would move" do
      base = lincoln_rows("08:06:40")
      edited = lincoln_rows("08:08:40")
      distances = Enum.map(0..10, &(&1 * 100.0))

      assert %{anchor: 6, moved_seconds: 120, stops: 5} =
               TimingFill.retime_candidates(base, edited, distances, no_coords(11),
                 method: :distance
               )
    end

    test "returns nil when nothing changed" do
      base = lincoln_rows("08:06:40")
      distances = Enum.map(0..10, &(&1 * 100.0))

      assert TimingFill.retime_candidates(base, base, distances, no_coords(11), method: :distance) ==
               nil
    end

    test "returns nil when only a non-timepoint row changed" do
      base = lincoln_rows("08:06:40")

      edited =
        Enum.map(base, fn row ->
          if row.position == 2,
            do: %{row | arrival: "08:00:40", departure: "08:00:40"},
            else: row
        end)

      distances = Enum.map(0..10, &(&1 * 100.0))

      assert TimingFill.retime_candidates(base, edited, distances, no_coords(11),
               method: :distance
             ) == nil
    end
  end
end

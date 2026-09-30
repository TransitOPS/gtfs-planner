defmodule GtfsPlanner.Gtfs.TimetablePaste.TimeTokenTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.TimetablePaste.TimeToken

  # Renders a clock reading the way an ambiguous timetable column would:
  # 12-hour wall time without a meridiem marker and without a leading zero,
  # so every output classifies :ambiguous.
  defp ambiguous_text(total) do
    clock = rem(total, 86_400)
    hour = div(clock, 3_600)
    minute = div(rem(clock, 3_600), 60)
    display = rem(hour, 12)
    display = if display == 0, do: 12, else: display
    "#{display}:#{String.pad_leading(Integer.to_string(minute), 2, "0")}"
  end

  defp classify_row(texts), do: Enum.map(texts, &TimeToken.classify/1)

  describe "classify/1 — clock readings" do
    test "12:00 AM is midnight and 12:00 PM is noon" do
      assert TimeToken.classify("12:00 AM") == {:time, 0, :h12}
      assert TimeToken.classify("12:00 PM") == {:time, 12 * 3_600, :h12}
    end

    test "11:50 PM reads as an h12 evening time" do
      assert TimeToken.classify("11:50 PM") == {:time, 23 * 3_600 + 50 * 60, :h12}
    end

    test "hours of 13 and above are h24" do
      assert TimeToken.classify("18:05") == {:time, 18 * 3_600 + 5 * 60, :h24}
      assert TimeToken.classify("13:00") == {:time, 13 * 3_600, :h24}
    end

    test "a leading zero is h24" do
      assert TimeToken.classify("06:05") == {:time, 6 * 3_600 + 5 * 60, :h24}
      assert TimeToken.classify("00:10") == {:time, 10 * 60, :h24}
    end

    test "plain daytime readings without a marker are ambiguous" do
      assert TimeToken.classify("6:05") == {:time, 6 * 3_600 + 5 * 60, :ambiguous}
      assert TimeToken.classify("605") == {:time, 6 * 3_600 + 5 * 60, :ambiguous}
      assert TimeToken.classify("12:10") == {:time, 12 * 3_600 + 10 * 60, :ambiguous}
    end

    test "explicit after-midnight times are kept as h24" do
      assert TimeToken.classify("24:30") == {:time, 24 * 3_600 + 30 * 60, :h24}
      assert TimeToken.classify("25:10") == {:time, 25 * 3_600 + 10 * 60, :h24}
    end

    test "meridiem spelling variants read as h12" do
      evening = 18 * 3_600 + 5 * 60

      for text <- ["6:05 PM", "6:05PM", "6:05 pm", "6:05p", "6:05 P", "6:05 aM"] do
        expected =
          if String.contains?(String.downcase(text), "p"), do: evening, else: 6 * 3_600 + 5 * 60

        assert TimeToken.classify(text) == {:time, expected, :h12}, "for #{inspect(text)}"
      end

      assert TimeToken.classify("6:05:30 pm") == {:time, evening + 30, :h12}
    end

    test "dotted meridiem markers read as h12" do
      assert TimeToken.classify("6:05 p.m.") == {:time, 18 * 3_600 + 5 * 60, :h12}
      assert TimeToken.classify("6:05 A.M.") == {:time, 6 * 3_600 + 5 * 60, :h12}
    end

    test "hour 0, a leading zero, and three digits keep their kinds" do
      assert TimeToken.classify("0:30") == {:time, 30 * 60, :h24}
      assert TimeToken.classify("06:05") == {:time, 6 * 3_600 + 5 * 60, :h24}
      assert TimeToken.classify("605") == {:time, 6 * 3_600 + 5 * 60, :ambiguous}
    end

    test "seconds are kept with their kind" do
      assert TimeToken.classify("6:05:30") == {:time, 6 * 3_600 + 5 * 60 + 30, :ambiguous}
    end

    test "surrounding whitespace is trimmed" do
      assert TimeToken.classify("  6:05  ") == {:time, 6 * 3_600 + 5 * 60, :ambiguous}
    end

    test "classified seconds round-trip through GtfsTime formatting" do
      for secs <- [0, 60, 4_500, 36_610, 43_200, 66_300, 86_399, 86_400, 87_000, 90_600, 129_600] do
        assert match?({:time, ^secs, _}, TimeToken.classify(GtfsTime.format(secs)))
      end
    end
  end

  describe "classify/1 — not served" do
    test "every contract marker is not served, case-insensitively" do
      for marker <- ["", "   ", "-", "–", "—", "…", "|", "x", "X", "n/a", "N/A", "  -  "] do
        assert TimeToken.classify(marker) == :not_served, "for #{inspect(marker)}"
      end
    end

    test "three ASCII dots are not the ellipsis marker" do
      assert TimeToken.classify("...") == {:error, :unrecognized}
    end
  end

  describe "classify/1 — unrecognized" do
    test "hour-only and relative forms are unrecognized in paste" do
      for text <- ["6", "18", "6p", "6 pm", "6 p.m.", "+3", "-10"] do
        assert TimeToken.classify(text) == {:error, :unrecognized}, "for #{inspect(text)}"
      end
    end

    test "6:6 is unrecognized" do
      assert TimeToken.classify("6:6") == {:error, :unrecognized}
    end

    test "non-clock text and out-of-range fields are unrecognized" do
      for text <- ["abc", "12", "123456", "12:60", "12:00:60", "--", "13:00 PM", "0:30 AM", "Run"] do
        assert TimeToken.classify(text) == {:error, :unrecognized}, "for #{inspect(text)}"
      end
    end
  end

  describe "resolve_row/2 — rollover" do
    test "11:50 PM then 12:10 gives 24:10" do
      tokens = classify_row(["11:50 PM", "12:10"])

      assert TimeToken.resolve_row(tokens) ==
               {:ok,
                [
                  %{secs: 23 * 3_600 + 50 * 60, rolled: nil},
                  %{secs: 24 * 3_600 + 10 * 60, rolled: :h12}
                ]}

      assert GtfsTime.format(24 * 3_600 + 10 * 60) == "24:10:00"
    end

    test "11:45 PM, 11:55 PM, 12:03 gives 24:03" do
      tokens = classify_row(["11:45 PM", "11:55 PM", "12:03"])

      assert TimeToken.resolve_row(tokens) ==
               {:ok,
                [
                  %{secs: 23 * 3_600 + 45 * 60, rolled: nil},
                  %{secs: 23 * 3_600 + 55 * 60, rolled: nil},
                  %{secs: 24 * 3_600 + 3 * 60, rolled: :h12}
                ]}
    end

    test "explicit 24:30 and 25:10 are kept" do
      assert TimeToken.resolve_row(classify_row(["24:30", "25:10"])) ==
               {:ok,
                [
                  %{secs: 24 * 3_600 + 30 * 60, rolled: nil},
                  %{secs: 25 * 3_600 + 10 * 60, rolled: nil}
                ]}
    end

    test "an ambiguous 8:10 then 8:00 reads the second as 20:00" do
      assert TimeToken.resolve_row(classify_row(["8:10", "8:00"])) ==
               {:ok,
                [
                  %{secs: 8 * 3_600 + 10 * 60, rolled: nil},
                  %{secs: 20 * 3_600, rolled: :h12}
                ]}
    end

    test "an h24 midnight crossing rolls +24 h" do
      assert TimeToken.resolve_row(classify_row(["23:50", "00:10"])) ==
               {:ok,
                [
                  %{secs: 23 * 3_600 + 50 * 60, rolled: nil},
                  %{secs: 24 * 3_600 + 10 * 60, rolled: :h24}
                ]}
    end

    test "h12 times past midnight roll +24 h" do
      tokens = classify_row(["11:30 PM", "11:40 PM", "11:50 PM", "12:00 AM", "12:10 AM"])

      assert TimeToken.resolve_row(tokens) ==
               {:ok,
                [
                  %{secs: 23 * 3_600 + 30 * 60, rolled: nil},
                  %{secs: 23 * 3_600 + 40 * 60, rolled: nil},
                  %{secs: 23 * 3_600 + 50 * 60, rolled: nil},
                  %{secs: 24 * 3_600, rolled: :h24},
                  %{secs: 24 * 3_600 + 10 * 60, rolled: :h24}
                ]}
    end

    test "an ambiguous time far past the previous one rolls +24 h" do
      assert TimeToken.resolve_row(classify_row(["30:00", "12:00"])) ==
               {:ok,
                [
                  %{secs: 30 * 3_600, rolled: nil},
                  %{secs: 36 * 3_600, rolled: :h24}
                ]}
    end

    test "equal times are non-decreasing" do
      assert TimeToken.resolve_row(classify_row(["8:00", "8:00"])) ==
               {:ok,
                [
                  %{secs: 8 * 3_600, rolled: nil},
                  %{secs: 8 * 3_600, rolled: nil}
                ]}
    end

    test "not-served and unrecognized cells pass through with positions aligned" do
      tokens = ["8:00", "-", "8:10"] |> classify_row()

      assert TimeToken.resolve_row(tokens) ==
               {:ok,
                [
                  %{secs: 8 * 3_600, rolled: nil},
                  :not_served,
                  %{secs: 8 * 3_600 + 10 * 60, rolled: nil}
                ]}

      tokens = [
        {:time, 8 * 3_600, :ambiguous},
        {:error, :unrecognized},
        {:time, 8 * 3_600 + 10 * 60, :ambiguous}
      ]

      assert TimeToken.resolve_row(tokens) ==
               {:ok,
                [
                  %{secs: 8 * 3_600, rolled: nil},
                  {:error, :unrecognized},
                  %{secs: 8 * 3_600 + 10 * 60, rolled: nil}
                ]}
    end

    test "an empty row resolves to an empty row" do
      assert TimeToken.resolve_row([]) == {:ok, []}
    end

    test "a time that cannot be made non-decreasing is a named error" do
      assert TimeToken.resolve_row(classify_row(["25:00", "00:30"])) ==
               {:error, {:time_goes_backwards, 1}}
    end

    test "the error index counts input positions across gaps" do
      assert TimeToken.resolve_row(classify_row(["25:00", "-", "00:30"])) ==
               {:error, {:time_goes_backwards, 2}}
    end
  end

  describe "resolve_row/2 — first-time shift" do
    test "the shift applies to the first time only" do
      [token] = classify_row(["1:15"])
      assert token == {:time, 3_600 + 15 * 60, :ambiguous}

      assert TimeToken.resolve_row([token], 0) == {:ok, [%{secs: 4_500, rolled: nil}]}
      assert TimeToken.resolve_row([token]) == {:ok, [%{secs: 4_500, rolled: nil}]}
      assert TimeToken.resolve_row([token], 43_200) == {:ok, [%{secs: 47_700, rolled: nil}]}
      assert TimeToken.resolve_row([token], 86_400) == {:ok, [%{secs: 90_900, rolled: nil}]}
    end

    test "later times roll forward from the shifted start" do
      tokens = classify_row(["1:15", "1:30"])

      assert TimeToken.resolve_row(tokens, 86_400) ==
               {:ok,
                [
                  %{secs: 25 * 3_600 + 15 * 60, rolled: nil},
                  %{secs: 25 * 3_600 + 30 * 60, rolled: :h24}
                ]}
    end
  end

  describe "twelve_hour_question?/2" do
    test "1:15 with a 23:45 median start asks the question" do
      assert TimeToken.twelve_hour_question?(
               {:time, 3_600 + 15 * 60, :ambiguous},
               23 * 3_600 + 45 * 60
             )
    end

    test "1:15 with a 06:00 median start does not" do
      refute TimeToken.twelve_hour_question?({:time, 3_600 + 15 * 60, :ambiguous}, 6 * 3_600)
    end

    test "the boundaries are strict: 04:00 and a 12:00 median do not ask" do
      evening = 23 * 3_600 + 45 * 60

      assert TimeToken.twelve_hour_question?({:time, 3 * 3_600 + 59 * 60, :ambiguous}, evening)
      refute TimeToken.twelve_hour_question?({:time, 4 * 3_600, :ambiguous}, evening)
      refute TimeToken.twelve_hour_question?({:time, 3_600 + 15 * 60, :ambiguous}, 12 * 3_600)
      assert TimeToken.twelve_hour_question?({:time, 3_600 + 15 * 60, :ambiguous}, 12 * 3_600 + 1)
    end

    test "only an ambiguous first time with a known median asks" do
      evening = 23 * 3_600 + 45 * 60
      early = 3 * 3_600

      refute TimeToken.twelve_hour_question?({:time, early, :h24}, evening)
      refute TimeToken.twelve_hour_question?({:time, early, :h12}, evening)
      refute TimeToken.twelve_hour_question?(:not_served, evening)
      refute TimeToken.twelve_hour_question?({:error, :unrecognized}, evening)
      refute TimeToken.twelve_hour_question?({:time, 3_600 + 15 * 60, :ambiguous}, nil)
    end
  end

  describe "generated monotone rows" do
    test "morning rows that cross noon recover their absolute seconds" do
      starts = [3_600 + 5 * 60, 5 * 3_600 + 15 * 60, 9 * 3_600, 11 * 3_600 + 50 * 60, 12 * 3_600]

      for start <- starts do
        expected = for step <- 0..5, do: start + step * 600
        tokens = expected |> Enum.map(&ambiguous_text/1) |> classify_row()

        assert Enum.all?(tokens, &match?({:time, _, :ambiguous}, &1)),
               "all generated cells stay ambiguous for start #{start}"

        assert {:ok, cells} = TimeToken.resolve_row(tokens)
        assert Enum.map(cells, & &1.secs) == expected

        for secs <- expected do
          assert {:ok, ^secs} = GtfsTime.parse(GtfsTime.format(secs))
        end
      end
    end

    test "a noon row running twelve hours past midnight recovers every reading" do
      expected = for step <- 0..72, do: 12 * 3_600 + step * 600
      tokens = expected |> Enum.map(&ambiguous_text/1) |> classify_row()

      assert {:ok, cells} = TimeToken.resolve_row(tokens)
      assert Enum.map(cells, & &1.secs) == expected
      assert List.last(cells) == %{secs: 24 * 3_600, rolled: :h12}
    end
  end
end

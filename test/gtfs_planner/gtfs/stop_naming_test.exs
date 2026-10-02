defmodule GtfsPlanner.Gtfs.StopNamingTest do
  @moduledoc """
  What a stop placed on a map is called, and what is wrong with a name once it
  is typed. Both are pure, so every case is a literal.

  The advice list is the part worth reading twice. Each entry names a mistake
  that survives into a published feed and is expensive to find once riders have
  the data, so the cases check that each one fires on its own condition and does
  not fire on a clean name.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StopNaming

  @connector " & "

  defp street(name, distance \\ nil), do: %{street: name, name: nil, distance_m: distance}
  defp amenity(name, distance), do: %{street: nil, name: name, distance_m: distance}

  describe "connector/1" do
    test "takes the most common connector in the version" do
      assert StopNaming.connector(["Main St & 1st Ave", "2nd St & 3rd Ave", "A St at B Ave"]) ==
               " & "
    end

    test "a version that mostly says at uses at" do
      assert StopNaming.connector(["Main St at 1st Ave", "2nd St at 3rd Ave", "A St & B Ave"]) ==
               " at "
    end

    test "a version with no stops falls back to the common US form" do
      assert StopNaming.connector([]) == " & "
    end

    test "names with no connector at all fall back too" do
      assert StopNaming.connector(["Main Street"]) == " & "
    end
  end

  describe "suggestions/3" do
    test "two street results are joined into one name" do
      # A stop at an intersection is named for both streets, so the name is the
      # join rather than the better-scoring one.
      assert %{name: "US 101 & NE 2nd St", alternatives: []} =
               StopNaming.suggestions([street("US 101"), street("NE 2nd St")], [], @connector)
    end

    test "one street result and a neighbour name offers the neighbour's full name" do
      %{name: name, alternatives: alternatives} =
        StopNaming.suggestions(
          [street("US 101")],
          ["US 101 & SE 1st St"],
          @connector
        )

      assert name == "US 101"
      assert alternatives == ["US 101 & SE 1st St"]
    end

    test "an amenity within 90 m appears in the alternatives" do
      %{alternatives: alternatives} =
        StopNaming.suggestions(
          [street("US 101"), amenity("Newport City Hall", 80.0)],
          [],
          @connector
        )

      assert "Newport City Hall" in alternatives
    end

    test "an amenity further away than 90 m does not" do
      %{alternatives: alternatives} =
        StopNaming.suggestions(
          [street("US 101"), amenity("Newport City Hall", 90.1)],
          [],
          @connector
        )

      refute "Newport City Hall" in alternatives
    end

    test "nothing found gives no name rather than a wrong one" do
      assert %{name: nil, alternatives: []} = StopNaming.suggestions([], [], @connector)
    end
  end

  describe "next_stop_id/3" do
    test "the highest ID plus one, never filling the gap" do
      # 1302 was retired. Reusing it would make its history point at a live stop.
      assert StopNaming.next_stop_id(["1301", "1302", "1531"], [], {0, "Main St & 3rd Ave"}) ==
               "1532"
    end

    test "a garage number is skipped" do
      assert StopNaming.next_stop_id(["1301", "1531"], ["1532"], {0, "Main St & 3rd Ave"}) ==
               "1533"
    end

    test "a version with no numeric IDs falls back to a slug" do
      assert StopNaming.next_stop_id(["NTC-A"], [], {0, "Main St & 3rd Ave"}) ==
               "platform_main_st_3rd_ave"
    end

    test "a slug already taken gets a suffix rather than a collision" do
      assert StopNaming.next_stop_id(
               ["platform_main_st_3rd_ave"],
               [],
               {0, "Main St & 3rd Ave"}
             ) == "platform_main_st_3rd_ave_2"
    end
  end

  describe "code_is_id_share/1" do
    test "9 of 10 codes repeating their ID is a share of 0.9" do
      stops =
        Enum.map(1..9, fn n -> %{stop_id: "1#{n}", stop_code: "1#{n}"} end) ++
          [%{stop_id: "200", stop_code: "A"}]

      assert StopNaming.code_is_id_share(stops) == 0.9
    end

    test "stops with no code are not counted either way" do
      stops = [
        %{stop_id: "1", stop_code: "1"},
        %{stop_id: "2", stop_code: nil}
      ]

      assert StopNaming.code_is_id_share(stops) == 1.0
    end

    test "a version with no codes at all is zero, not a division by zero" do
      assert StopNaming.code_is_id_share([%{stop_id: "1", stop_code: nil}]) == 0.0
    end
  end

  describe "sign_conflict/3" do
    test "names the other stop using this sign number" do
      stops = [
        %{stop_id: "1434", stop_name: "Main St & 1st Ave", stop_code: "A1"},
        %{stop_id: "1435", stop_name: "Main St & 2nd Ave", stop_code: "1434"}
      ]

      assert StopNaming.sign_conflict("1434", stops, nil) == "Main St & 2nd Ave"
    end

    test "the stop being edited matching itself is not a conflict" do
      stops = [%{stop_id: "1434", stop_name: "Main St & 1st Ave", stop_code: "1434"}]

      assert StopNaming.sign_conflict("1434", stops, "1434") == nil
    end

    test "no code means no conflict to find" do
      assert StopNaming.sign_conflict(nil, [%{stop_id: "1", stop_code: "1"}], nil) == nil
    end
  end

  describe "advice/4" do
    test "all capitals is advice" do
      advice = StopNaming.advice("MAIN ST & 1ST AVE", nil, nil, @connector)

      assert Enum.any?(advice, &(&1 =~ "capitals"))
    end

    test "a direction word is advice" do
      advice = StopNaming.advice("US 101 NB & SE 1st St", nil, nil, @connector)

      assert Enum.any?(advice, &(&1 =~ "direction"))
    end

    test "a sign number in the name is advice" do
      advice = StopNaming.advice("1434 US 101 & SE 1st St", "1434", nil, @connector)

      assert Enum.any?(advice, &(&1 =~ "stop code"))
    end

    test "a name over 50 characters is advice" do
      long = String.duplicate("a", 51)
      advice = StopNaming.advice(long, nil, nil, @connector)

      assert Enum.any?(advice, &(&1 =~ "characters"))
    end

    test "a description repeating the name is advice" do
      advice =
        StopNaming.advice("US 101 & SE 1st St", nil, "US 101 & SE 1st St", @connector)

      assert Enum.any?(advice, &(&1 =~ "repeats the name"))
    end

    test "a description saying stop is advice" do
      advice = StopNaming.advice("US 101 & SE 1st St", nil, "Bus stop", @connector)

      assert Enum.any?(advice, &(&1 =~ "stop or station"))
    end

    test "a different connector is advice" do
      advice = StopNaming.advice("US 101 at SE 1st St", nil, nil, @connector)

      assert Enum.any?(advice, &(&1 =~ "joins streets"))
    end

    test "a clean name gets no advice at all" do
      assert StopNaming.advice(
               "US 101 & SE 1st St",
               "A1",
               "Two blocks from the ferry",
               @connector
             ) ==
               []
    end
  end
end

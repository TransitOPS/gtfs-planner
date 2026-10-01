defmodule GtfsPlanner.Gtfs.TimetableSourceTest do
  @moduledoc """
  Focused coverage for the reviewed approved-source projection (step 2, EV-2).

  Every expected value here is written out by hand: the November 2026 service
  dates, the service-day seconds, the occurrence identities and the two
  calendar groups. Nothing is asserted against another call into
  `GtfsPlanner.Gtfs.TimetableSource`, so a change in the projection cannot
  quietly rewrite its own oracle.

  The four cases are the execution card's four observable cases. They exercise
  the real production composition — `ClipboardParser` and `TimeToken` through
  `normalize/2`, then the public `accept/2`, `native_input/3` and
  `assistant_payload/1` entrypoints — with no private function called directly
  and no database fixture, because the module is pure by contract.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.TimetablePaste
  alias GtfsPlanner.Gtfs.TimetablePaste.ClipboardParser
  alias GtfsPlanner.Gtfs.TimetableSource

  # 2026-11-02..2026-11-06, 09..13, 16..20, 23..25 (Thanksgiving Thursday
  # 2026-11-26 removed), 27, 30. Hand-written from the calendar, not computed
  # by the module under test.
  @november_weekdays ~w(
    2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06
    2026-11-09 2026-11-10 2026-11-11 2026-11-12 2026-11-13
    2026-11-16 2026-11-17 2026-11-18 2026-11-19 2026-11-20
    2026-11-23 2026-11-24 2026-11-25 2026-11-27 2026-11-30
  )

  describe "case 1: a reviewed Monday-Friday interval with one holiday removal" do
    setup do
      {:ok, draft: normalize!(weekday_params())}
    end

    test "expands the hand-written weekday set and drops the removed holiday", %{draft: draft} do
      assert draft.interval == {~D[2026-11-01], ~D[2026-11-30]}
      assert TimetableSource.date_count(draft.interval) == 30

      assert Enum.map(draft.rows, & &1.dates) |> List.flatten() |> Enum.uniq() |> iso_dates() ==
               @november_weekdays

      refute ~D[2026-11-26] in hd(draft.rows).dates
      assert length(hd(draft.rows).dates) == 20
    end

    test "keeps every row on the same reviewed dates and resolves its feed trip", %{draft: draft} do
      assert Enum.map(draft.rows, & &1.feed_trip_id) == ["trip-weekday-a", "trip-weekday-b"]
      assert Enum.map(draft.rows, & &1.service_id) == ["svc-weekday", "svc-weekday"]
      assert Enum.map(draft.rows, & &1.pattern_id) == ["pat-1", "pat-1"]
      assert Enum.map(draft.rows, & &1.direction_id) == [0, 0]
      assert draft.unresolved == []
      assert draft.exclusions == []
    end

    test "maps each pasted column to its own occurrence with exact service-day seconds",
         %{draft: draft} do
      assert [
               %{
                 occurrence: %{stop_id: "S1", stop_sequence: 0},
                 arrival: 21_600,
                 departure: 21_600
               },
               %{
                 occurrence: %{stop_id: "S1", stop_sequence: 1},
                 arrival: 21_900,
                 departure: 21_900
               },
               %{
                 occurrence: %{stop_id: "S2", stop_sequence: 0},
                 arrival: 22_200,
                 departure: 22_200
               },
               %{
                 occurrence: %{stop_id: "S2", stop_sequence: 1},
                 arrival: 22_800,
                 departure: 22_800
               },
               %{
                 occurrence: %{stop_id: "S3", stop_sequence: 0},
                 arrival: 23_400,
                 departure: 23_400
               }
             ] =
               hd(draft.rows).cells

      assert [
               %{arrival: 25_200},
               %{arrival: 25_500},
               %{arrival: 25_800},
               %{arrival: 26_400},
               %{arrival: 27_000}
             ] = Enum.map(List.last(draft.rows).cells, & &1)
    end

    test "preserves the pasted text, notes, label and revision verbatim", %{draft: draft} do
      assert draft.raw_text == weekday_params()["text"]
      assert draft.notes == "Thanksgiving Thursday removed; weekdays otherwise."
      assert draft.label == "November 2026 board sheet"
      assert draft.revision == "r3"
      assert draft.accepted? == false
    end

    test "accepts only after an explicit confirmation", %{draft: draft} do
      assert {:error, :not_confirmed} = TimetableSource.accept(draft, %{})
      assert {:error, :not_confirmed} = TimetableSource.accept(draft, %{confirmed?: false})
      assert {:error, :not_confirmed} = TimetableSource.accept(draft, %{note: "the model agrees"})

      assert {:ok, accepted} = TimetableSource.accept(draft, %{confirmed?: true})
      assert accepted.accepted? == true
      assert accepted.rows == draft.rows
      assert accepted.notes == draft.notes
      refute accepted.digest == draft.digest
      assert String.match?(accepted.digest, ~r/\A[0-9a-f]{64}\z/)
    end

    test "binds the digest to every comparison-affecting reviewed input", %{draft: draft} do
      {:ok, same} = TimetableSource.normalize(weekday_params(), native_scope())
      assert same.digest == draft.digest

      {:ok, later_removal} =
        TimetableSource.normalize(
          put_in(weekday_params(), ["removed_dates"], ["2026-11-26", "2026-11-27"]),
          native_scope()
        )

      refute later_removal.digest == draft.digest

      {:ok, relabelled} =
        TimetableSource.normalize(
          put_in(weekday_params(), ["revision"], "r4"),
          native_scope()
        )

      refute relabelled.digest == draft.digest
    end
  end

  describe "case 2: repeated stop columns, overnight clocks and unsupported notes" do
    setup do
      params = loop_params()

      {:ok, draft: normalize!(params), params: params}
    end

    test "maps a repeated stop to distinct occurrence identities", %{draft: draft} do
      occurrences = Enum.map(hd(draft.rows).cells, & &1.occurrence)

      assert occurrences == [
               %{stop_id: "S1", stop_sequence: 0},
               %{stop_id: "S2", stop_sequence: 0},
               %{stop_id: "S2", stop_sequence: 1},
               %{stop_id: "S3", stop_sequence: 0}
             ]

      assert length(Enum.uniq(occurrences)) == 4
    end

    test "keeps arrival and departure of one occurrence independent", %{draft: draft} do
      assert [
               %{
                 occurrence: %{stop_id: "S1", stop_sequence: 0},
                 arrival: 87_000,
                 departure: 87_300
               }
               | _rest
             ] = hd(draft.rows).cells
    end

    test "keeps 24:10 and 00:10 as different service-day clocks", %{draft: draft} do
      [overnight, after_midnight] = draft.rows

      assert Enum.map(overnight.cells, & &1.arrival) == [87_000, 87_600, 87_900, 88_200]
      assert Enum.map(after_midnight.cells, & &1.arrival) == [600, 1_200, 1_500, 1_800]

      assert Enum.map(overnight.cells, & &1.arrival) !=
               Enum.map(after_midnight.cells, & &1.arrival)
    end

    test "discloses unsupported notes without erasing the row", %{draft: draft} do
      assert draft.unresolved == [{:unsupported_column, 1, 5}]
      refute TimetableSource.blocking_reason?({:unsupported_column, 1, 5})
      assert length(hd(draft.rows).cells) == 4

      # A disclosed note survives acceptance and stays visible to the caller.
      assert {:ok, accepted} = TimetableSource.accept(draft, %{confirmed?: true})
      assert accepted.unresolved == [{:unsupported_column, 1, 5}]
    end

    test "reads an unreadable mapped cell as unknown, never as a clock", %{draft: params} do
      params =
        put_in(params, ["text"], String.replace(params["text"], "\t24:25\t", "\twhenever\t"))

      draft = normalize!(params)

      assert Enum.map(hd(draft.rows).cells, & &1.arrival) == [87_000, 87_600, :unknown, 88_200]
      assert {:unsupported_clock, 3, "whenever"} in draft.unresolved
    end

    test "refuses a rolled twelve-hour reading until the editor reviews it" do
      draft = normalize!(roll_params())

      assert Enum.map(hd(draft.rows).cells, & &1.departure) == [45_000, 47_100, 48_000]
      assert draft.unresolved == [{:unreviewed_twelve_hour, 1}]
      assert TimetableSource.blocking_reason?({:unreviewed_twelve_hour, 1})

      assert {:error, {:unresolved, [{:unreviewed_twelve_hour, 1}]}} =
               TimetableSource.accept(draft, %{confirmed?: true})

      reviewed =
        put_in(roll_params(), ["mapping", "rows", "1"], %{
          "feed_trip_id" => "trip-weekday-a",
          "shift" => 0
        })

      assert {:ok, accepted} =
               reviewed
               |> normalize!(native_scope())
               |> TimetableSource.accept(%{confirmed?: true})

      assert accepted.unresolved == []
      assert Enum.map(hd(accepted.rows).cells, & &1.departure) == [45_000, 47_100, 48_000]
    end
  end

  describe "case 3: native bounds unchanged and an oversized source refused for the assistant only" do
    test "the native page still refuses 204,801 raw bytes" do
      text = String.duplicate("a", 204_801)

      assert ClipboardParser.parse(text) == {:error, {:too_large, 204_801}}

      assert TimetablePaste.review(%{}, %{text: text, header?: false}) ==
               {:error, {:too_large, 204_801}}
    end

    test "the native page still refuses 501 trip rows and 151 columns" do
      rows_500 = Enum.map_join(1..500, "\n", fn _index -> "06:00\t06:05" end)
      rows_501 = Enum.map_join(1..501, "\n", fn _index -> "06:00\t06:05" end)
      wide = Enum.map_join(1..151, "\t", fn _index -> "06:00" end)

      assert {:ok, _review} = TimetablePaste.review(%{}, %{text: rows_500, header?: false})

      assert TimetablePaste.review(%{}, %{text: rows_501, header?: false}) ==
               {:error, {:too_many_rows, 501}}

      assert TimetablePaste.review(%{}, %{text: wide, header?: false}) ==
               {:error, {:too_many_columns, 151}}
    end

    test "the source refuses the same bounds with its own field errors" do
      rows_501 = Enum.map_join(1..501, "\n", fn _index -> "06:00\t06:05" end)
      wide = Enum.map_join(1..151, "\t", fn _index -> "06:00" end)
      scope = native_scope()

      assert {:error, %{"text" => ["must stay within 500 trip rows"]}} =
               TimetableSource.normalize(base_params(rows_501, "false"), scope)

      assert {:error, %{"text" => ["must stay within 150 columns"]}} =
               TimetableSource.normalize(base_params(wide, "false"), scope)

      assert {:error, %{"text" => [message]}} =
               TimetableSource.normalize(
                 base_params(String.duplicate("a", 204_801), "true"),
                 scope
               )

      assert message == "must stay within 204800 bytes, got 204801"
    end

    test "a valid source over the helper ceiling keeps its native projection and refuses attachment" do
      draft = normalize!(wide_params(), wide_scope())

      assert length(draft.rows) == 100
      assert byte_size(draft.raw_text) < 204_800
      assert draft.unresolved == []

      assert TimetableSource.assistant_payload(draft) == {:error, :too_large}

      # The full native source and the manual comparison stay available.
      assert {:ok, %{service_id: "svc-wide", input: input}} =
               TimetableSource.native_input(draft, Enum.to_list(1..100), "svc-wide")

      assert input.text == draft.raw_text
      assert input.decisions == %{}
      assert input.mode == :add
      assert input.header? == true

      assert {:ok, accepted} = TimetableSource.accept(draft, %{confirmed?: true})
      assert TimetableSource.assistant_payload(accepted) == {:error, :too_large}
    end

    test "a small source attaches whole, with every row and unresolved item present" do
      draft = normalize!(loop_params())
      {:ok, payload} = TimetableSource.assistant_payload(draft)

      assert payload["label"] == "Overnight board sheet"
      assert payload["accepted?"] == false
      assert payload["digest"] == draft.digest

      assert payload["interval"] == %{
               "first_date" => "2026-11-02",
               "last_date" => "2026-11-02",
               "date_count" => 1
             }

      assert length(payload["rows"]) == 2

      assert [
               %{
                 "source_row_id" => 1,
                 "feed_trip_id" => "trip-a",
                 "service_id" => "svc-weekday",
                 "direction_id" => 0,
                 "pattern_id" => "pat-1",
                 "dates" => ["2026-11-02"],
                 "cells" => cells
               }
               | _rest
             ] = payload["rows"]

      assert cells == [
               %{
                 "stop_id" => "S1",
                 "stop_sequence" => 0,
                 "arrival" => 87_000,
                 "departure" => 87_300
               },
               %{
                 "stop_id" => "S2",
                 "stop_sequence" => 0,
                 "arrival" => 87_600,
                 "departure" => 87_600
               },
               %{
                 "stop_id" => "S2",
                 "stop_sequence" => 1,
                 "arrival" => 87_900,
                 "departure" => 87_900
               },
               %{
                 "stop_id" => "S3",
                 "stop_sequence" => 0,
                 "arrival" => 88_200,
                 "departure" => 88_200
               }
             ]

      assert payload["unresolved"] == ["{:unsupported_column, 1, 5}"]
      assert payload["exclusions"] == []
      assert byte_size(Jason.encode!(payload)) <= 65_536
    end
  end

  describe "case 4: two calendar groups stay two explicit row selections" do
    setup do
      {:ok, draft: normalize!(two_calendar_params())}
    end

    test "one selection per calendar, each naming exactly one service id", %{draft: draft} do
      assert Enum.map(draft.rows, &{&1.source_row_id, &1.feed_trip_id, &1.service_id}) == [
               {1, "trip-weekday-a", "svc-weekday"},
               {2, "trip-friday-b", "svc-friday"}
             ]

      assert {:ok, %{service_id: "svc-weekday", input: weekday}} =
               TimetableSource.native_input(draft, [1], "svc-weekday")

      assert weekday.text == draft.raw_text
      assert Map.keys(weekday.decisions) == [2]
      assert weekday.decisions[2] == %{skip: true, cells: %{}, shift: 0}

      assert {:ok, %{service_id: "svc-friday", input: friday}} =
               TimetableSource.native_input(draft, [2], "svc-friday")

      assert Map.keys(friday.decisions) == [1]
      assert friday.text == draft.raw_text
    end

    test "no projection ever carries a combined service id", %{draft: draft} do
      assert {:error, :mixed_calendars} =
               TimetableSource.native_input(draft, [1, 2], "svc-weekday")

      assert {:error, :mixed_calendars} =
               TimetableSource.native_input(draft, [1, 2], "svc-friday")

      assert {:error, :unknown_row} = TimetableSource.native_input(draft, [1, 9], "svc-weekday")
      assert {:error, :empty_selection} = TimetableSource.native_input(draft, [], "svc-weekday")

      service_ids =
        ["svc-weekday", "svc-friday"]
        |> Enum.flat_map(fn calendar ->
          1..2
          |> Enum.flat_map(fn row ->
            case TimetableSource.native_input(draft, [row], calendar) do
              {:ok, %{service_id: service_id}} -> [service_id]
              {:error, reason} -> [{calendar, row, reason}]
            end
          end)
        end)

      assert service_ids == [
               "svc-weekday",
               {"svc-weekday", 2, :mixed_calendars},
               {"svc-friday", 1, :mixed_calendars},
               "svc-friday"
             ]
    end
  end

  describe "school policy" do
    test "uses exactly the supplied school dates and never a weekday guess" do
      params =
        weekday_params()
        |> Map.merge(%{
          "date_policy" => "school",
          "weekdays" => nil,
          "removed_dates" => [],
          "school_dates" => ["2026-11-25", "2026-11-27"]
        })

      draft = normalize!(params)

      assert iso_dates(hd(draft.rows).dates) == ["2026-11-25", "2026-11-27"]
      refute ~D[2026-11-26] in hd(draft.rows).dates
      refute ~D[2026-11-02] in hd(draft.rows).dates
      assert draft.unresolved == []
      assert {:ok, _accepted} = TimetableSource.accept(draft, %{confirmed?: true})
    end

    test "a school policy without supplied dates stays unresolved and cannot be accepted" do
      params =
        weekday_params()
        |> Map.merge(%{"date_policy" => "school", "weekdays" => nil, "removed_dates" => []})

      draft = normalize!(params)

      assert draft.date_rules.policy == :school
      assert draft.rows |> hd() |> Map.fetch!(:dates) == []
      assert draft.unresolved == [{:missing_school_dates, {~D[2026-11-01], ~D[2026-11-30]}}]
      assert TimetableSource.blocking_reason?(hd(draft.unresolved))

      assert {:error, {:unresolved, [{:missing_school_dates, {~D[2026-11-01], ~D[2026-11-30]}}]}} =
               TimetableSource.accept(draft, %{confirmed?: true})
    end

    test "explicit additions outside the weekly range and removals are applied and excluded" do
      params =
        weekday_params()
        |> Map.merge(%{
          "weekdays" => [1, 3],
          "added_dates" => ["2026-11-28", "2026-12-05"],
          "removed_dates" => ["2026-11-25"]
        })

      draft = normalize!(params)

      assert iso_dates(hd(draft.rows).dates) == [
               "2026-11-02",
               "2026-11-04",
               "2026-11-09",
               "2026-11-11",
               "2026-11-16",
               "2026-11-18",
               "2026-11-23",
               "2026-11-28",
               "2026-11-30"
             ]

      assert draft.exclusions == [{:addition_outside_interval, ~D[2026-12-05]}]
    end
  end

  describe "validation refusals" do
    test "a date both added and removed is a validation error, not a silent preference" do
      params =
        weekday_params()
        |> Map.merge(%{"added_dates" => ["2026-11-26"], "removed_dates" => ["2026-11-26"]})

      assert {:error, %{"removed_dates" => ["must not repeat a date in added_dates"]}} =
               TimetableSource.normalize(params, native_scope())
    end

    test "a multi-month interval keeps its dates in chronological order" do
      params =
        weekday_params()
        |> Map.merge(%{
          "first_date" => "2026-11-01",
          "last_date" => "2026-12-31",
          "weekdays" => [1],
          "removed_dates" => []
        })

      dates = iso_dates(hd(normalize!(params).rows).dates)

      assert length(dates) == 9
      assert hd(dates) == "2026-11-02"
      assert List.last(dates) == "2026-12-28"

      assert dates == Enum.sort(dates)

      assert dates == [
               "2026-11-02",
               "2026-11-09",
               "2026-11-16",
               "2026-11-23",
               "2026-11-30",
               "2026-12-07",
               "2026-12-14",
               "2026-12-21",
               "2026-12-28"
             ]
    end

    test "a reversed or over-long interval is refused with its own field" do
      assert {:error, %{"last_date" => ["must not precede first_date"]}} =
               TimetableSource.normalize(
                 put_in(weekday_params(), ["last_date"], "2026-10-01"),
                 native_scope()
               )

      assert {:error, %{"last_date" => ["must stay within 366 inclusive dates"]}} =
               TimetableSource.normalize(
                 put_in(weekday_params(), ["last_date"], "2027-11-02"),
                 native_scope()
               )
    end

    test "over-long notes and a column without an occurrence are refused" do
      assert {:error, %{"notes" => ["must be at most 2000 characters"]}} =
               TimetableSource.normalize(
                 put_in(weekday_params(), ["notes"], String.duplicate("n", 2_001)),
                 native_scope()
               )

      assert {:error, %{"mapping.columns.2" => message}} =
               TimetableSource.normalize(
                 put_in(weekday_params(), ["mapping", "columns", "2"], %{
                   "stop_id" => "S2"
                 }),
                 native_scope()
               )

      assert message == "must name a stop_id and a 0-based stop_sequence"
    end

    test "a weekly policy without weekdays cannot name a date set" do
      assert {:error, %{"weekdays" => ["must list at least one ISO weekday (1 = Monday)"]}} =
               TimetableSource.normalize(
                 Map.delete(weekday_params(), "weekdays"),
                 native_scope()
               )

      assert {:error, %{"weekdays" => ["must be ISO weekdays 1 to 7"]}} =
               TimetableSource.normalize(
                 put_in(weekday_params(), ["weekdays"], [1, 9]),
                 native_scope()
               )
    end

    test "rows without one scoped candidate are missing, and never silently deduplicated" do
      params = put_in(weekday_params(), ["mapping", "rows"], %{})

      # Row 1 starts at 06:00, which only one scoped trip starts at; row 2 starts
      # at 07:00, which two scoped trips start at.
      candidates = normalize!(params)
      assert Enum.map(candidates.rows, & &1.feed_trip_id) == ["trip-weekday-a", nil]
      assert candidates.unresolved == [{:ambiguous_mapping, 2, 2}]

      assert {:error, {:unresolved, [{:ambiguous_mapping, 2, 2}]}} =
               TimetableSource.accept(candidates, %{confirmed?: true})

      no_candidate = normalize!(params, %{patterns: [%{id: "pat-1", occurrences: []}], trips: []})
      assert Enum.map(no_candidate.rows, & &1.feed_trip_id) == [nil, nil]
      assert no_candidate.unresolved == [{:missing_mapping, 1}, {:missing_mapping, 2}]

      duplicated =
        normalize!(
          put_in(params, ["mapping", "rows"], %{
            "1" => %{"feed_trip_id" => "trip-weekday-a"},
            "2" => %{"feed_trip_id" => "trip-weekday-a"}
          }),
          native_scope()
        )

      assert duplicated.unresolved == [{:duplicate_feed_trip, "trip-weekday-a"}]

      assert {:error, {:unresolved, [{:duplicate_feed_trip, "trip-weekday-a"}]}} =
               TimetableSource.accept(duplicated, %{confirmed?: true})
    end

    test "a feed trip outside the attached scope is refused, not invented" do
      params =
        put_in(weekday_params(), ["mapping", "rows", "1"], %{"feed_trip_id" => "trip-elsewhere"})

      draft = normalize!(params)

      assert [{:unknown_feed_trip, 1, "trip-elsewhere"}] = draft.unresolved
      assert hd(draft.rows).feed_trip_id == nil

      assert {:error, {:unresolved, [{:unknown_feed_trip, 1, "trip-elsewhere"}]}} =
               TimetableSource.accept(draft, %{confirmed?: true})
    end

    test "a mapping that contradicts its feed trip is refused" do
      params =
        weekday_params()
        |> Map.update!("mapping", &Map.put(&1, "direction_id", 1))

      draft = normalize!(params)

      assert [{:mapping_conflict, 1, "trip-weekday-a"}, {:mapping_conflict, 2, "trip-weekday-b"}] =
               draft.unresolved

      assert Enum.map(draft.rows, & &1.feed_trip_id) == [nil, nil]
    end
  end

  # --- Fixtures ---

  defp normalize!(params, scope \\ nil) do
    {:ok, draft} = TimetableSource.normalize(params, scope || native_scope())
    draft
  end

  defp native_scope do
    %{
      patterns: [
        %{
          id: "pat-1",
          occurrences: [
            %{stop_id: "S1", stop_sequence: 0},
            %{stop_id: "S1", stop_sequence: 1},
            %{stop_id: "S2", stop_sequence: 0},
            %{stop_id: "S2", stop_sequence: 1},
            %{stop_id: "S3", stop_sequence: 0}
          ]
        }
      ],
      trips: [
        %{
          id: "trip-weekday-a",
          direction_id: 0,
          pattern_id: "pat-1",
          first_departure_secs: 21_600,
          service_id: "svc-weekday"
        },
        %{
          id: "trip-weekday-b",
          direction_id: 0,
          pattern_id: "pat-1",
          first_departure_secs: 25_200,
          service_id: "svc-weekday"
        },
        %{
          id: "trip-friday-b",
          direction_id: 0,
          pattern_id: "pat-1",
          first_departure_secs: 25_200,
          service_id: "svc-friday"
        }
      ]
    }
  end

  defp weekday_params do
    %{
      "text" =>
        "Depart\tMain\tMain\tDepot\tDepot\n06:00\t06:05\t06:10\t06:20\t06:30\n07:00\t07:05\t07:10\t07:20\t07:30\n",
      "label" => "November 2026 board sheet",
      "revision" => "r3",
      "notes" => "Thanksgiving Thursday removed; weekdays otherwise.",
      "first_date" => "2026-11-01",
      "last_date" => "2026-11-30",
      "date_policy" => "weekly",
      "weekdays" => [1, 2, 3, 4, 5],
      "removed_dates" => ["2026-11-26"],
      "mapping" => weekday_mapping()
    }
  end

  defp weekday_mapping do
    %{
      "direction_id" => 0,
      "pattern_id" => "pat-1",
      "columns" => %{
        "0" => %{"stop_id" => "S1", "stop_sequence" => 0},
        "1" => %{"stop_id" => "S1", "stop_sequence" => 1},
        "2" => %{"stop_id" => "S2", "stop_sequence" => 0},
        "3" => %{"stop_id" => "S2", "stop_sequence" => 1},
        "4" => %{"stop_id" => "S3", "stop_sequence" => 0}
      },
      "rows" => %{
        "1" => %{"feed_trip_id" => "trip-weekday-a"},
        "2" => %{"feed_trip_id" => "trip-weekday-b"}
      }
    }
  end

  defp loop_params do
    %{
      "text" =>
        "Trip\tMain arrive\tMain leave\tLoop\tLoop\tNotes\n24:10\t24:15\t24:20\t24:25\t24:30\tsee memo\n00:10\t00:15\t00:20\t00:25\t00:30\t\n",
      "label" => "Overnight board sheet",
      "first_date" => "2026-11-02",
      "last_date" => "2026-11-02",
      "date_policy" => "weekly",
      "weekdays" => [1],
      "mapping" => %{
        "direction_id" => 0,
        "pattern_id" => "pat-1",
        "columns" => %{
          "0" => %{"stop_id" => "S1", "stop_sequence" => 0, "side" => "arrival"},
          "1" => %{"stop_id" => "S1", "stop_sequence" => 0, "side" => "departure"},
          "2" => %{"stop_id" => "S2", "stop_sequence" => 0},
          "3" => %{"stop_id" => "S2", "stop_sequence" => 1},
          "4" => %{"stop_id" => "S3", "stop_sequence" => 0}
        },
        "rows" => %{
          "1" => %{"feed_trip_id" => "trip-weekday-a"},
          "2" => %{"feed_trip_id" => "trip-weekday-b"}
        }
      }
    }
  end

  defp roll_params do
    %{
      "text" => "Trip\tDepot\tMain\n12:30\t1:05\t1:20\n",
      "first_date" => "2026-11-02",
      "last_date" => "2026-11-02",
      "date_policy" => "weekly",
      "weekdays" => [1],
      "mapping" => %{
        "direction_id" => 0,
        "columns" => %{
          "0" => %{"stop_id" => "S1", "stop_sequence" => 0},
          "1" => %{"stop_id" => "S2", "stop_sequence" => 0},
          "2" => %{"stop_id" => "S3", "stop_sequence" => 0}
        },
        "rows" => %{"1" => %{"feed_trip_id" => "trip-weekday-a"}}
      }
    }
  end

  defp two_calendar_params do
    weekday_params()
    |> Map.put(
      "mapping",
      put_in(weekday_mapping(), ["rows"], %{"2" => %{"feed_trip_id" => "trip-friday-b"}})
    )
  end

  defp wide_params do
    header = Enum.map_join(0..9, "\t", fn column -> "H#{column}" end)
    row = Enum.map_join(0..9, "\t", fn _column -> "06:00" end)
    text = Enum.join([header | Enum.map(1..100, fn _index -> row end)], "\n") <> "\n"

    %{
      "text" => text,
      "label" => "Wide source",
      "first_date" => "2026-11-02",
      "last_date" => "2026-11-02",
      "date_policy" => "weekly",
      "weekdays" => [1],
      "mapping" => %{
        "direction_id" => 0,
        "columns" =>
          Enum.into(0..9, %{}, fn column ->
            {Integer.to_string(column), %{"stop_id" => "S#{column}", "stop_sequence" => 0}}
          end),
        "rows" =>
          Enum.into(1..100, %{}, fn row ->
            {Integer.to_string(row), %{"feed_trip_id" => "trip-wide-#{row}"}}
          end)
      }
    }
  end

  defp wide_scope do
    %{
      patterns: [%{id: "pat-wide", occurrences: [%{stop_id: "S0", stop_sequence: 0}]}],
      trips:
        Enum.map(1..100, fn row ->
          %{
            id: "trip-wide-#{row}",
            direction_id: 0,
            pattern_id: "pat-wide",
            service_id: "svc-wide"
          }
        end)
    }
  end

  defp base_params(text, header?) do
    %{
      "text" => text,
      "header?" => header?,
      "first_date" => "2026-11-02",
      "last_date" => "2026-11-02",
      "date_policy" => "weekly",
      "weekdays" => [1]
    }
  end

  defp iso_dates(dates), do: Enum.map(dates, &Date.to_iso8601/1)
end

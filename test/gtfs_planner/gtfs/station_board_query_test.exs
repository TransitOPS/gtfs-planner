defmodule GtfsPlanner.Gtfs.StationBoardQueryTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.StationBoard

  describe "classify/2" do
    test "classifies a station without pathways as not started regardless of its status" do
      station = base("STA", %{pathway_count: 0})

      assert StationBoard.classify(station, nil) == :not_started
      assert StationBoard.classify(station, status()) == :not_started
      assert StationBoard.classify(station, status(%{issues: 3})) == :not_started
    end

    test "classifies a station with pathways and no status as unknown" do
      assert StationBoard.classify(base("STA"), nil) == :unknown
    end

    test "classifies no issues with a fresh passed run as clean" do
      assert StationBoard.classify(base("STA"), status()) == :clean
    end

    test "classifies a warning run as in progress" do
      assert StationBoard.classify(base("STA"), status(%{reachability: run(:warning)})) ==
               :in_progress
    end

    test "classifies a not applicable run as in progress" do
      assert StationBoard.classify(base("STA"), status(%{reachability: run(:not_applicable)})) ==
               :in_progress
    end

    test "classifies a stale passed run as in progress" do
      status = status(%{reachability: run(:passed, %{stale?: true})})

      assert StationBoard.classify(base("STA"), status) == :in_progress
    end

    test "classifies a station with no run as in progress" do
      assert StationBoard.classify(base("STA"), status(%{reachability: nil})) == :in_progress
    end

    test "classifies a station with issues as in progress" do
      station = base("STA")

      assert StationBoard.classify(station, status(%{issues: 1})) == :in_progress

      assert StationBoard.classify(station, status(%{issues: 2, reachability: run(:passed)})) ==
               :in_progress
    end
  end

  describe "parse_params/1" do
    test "returns the defaults for an empty map" do
      assert StationBoard.parse_params(%{}) == %{stage: :all, q: "", page: 1}
    end

    test "maps the known stages" do
      assert StationBoard.parse_params(%{"stage" => "all"}).stage == :all
      assert StationBoard.parse_params(%{"stage" => "not_started"}).stage == :not_started
      assert StationBoard.parse_params(%{"stage" => "in_progress"}).stage == :in_progress
      assert StationBoard.parse_params(%{"stage" => "clean"}).stage == :clean
    end

    test "falls back to all for an unknown stage" do
      assert StationBoard.parse_params(%{"stage" => "bogus"}).stage == :all
      assert StationBoard.parse_params(%{"stage" => "NOT_STARTED"}).stage == :all
    end

    test "accepts a positive integer page and falls back to 1 otherwise" do
      assert StationBoard.parse_params(%{"page" => "3"}).page == 3
      assert StationBoard.parse_params(%{"page" => 3}).page == 3
      assert StationBoard.parse_params(%{"page" => "-3"}).page == 1
      assert StationBoard.parse_params(%{"page" => "0"}).page == 1
      assert StationBoard.parse_params(%{"page" => "abc"}).page == 1
      assert StationBoard.parse_params(%{"page" => "2.5"}).page == 1
    end

    test "trims the search term and truncates it to 100 characters" do
      assert StationBoard.parse_params(%{"q" => "  Union Station  "}).q == "Union Station"

      long_query = "  " <> String.duplicate("a", 120) <> "  "

      assert StationBoard.parse_params(%{"q" => long_query}).q == String.duplicate("a", 100)
    end

    test "never raises on unexpected param values" do
      assert StationBoard.parse_params(%{"stage" => ["not_started"], "q" => 5, "page" => %{}}) ==
               %{stage: :all, q: "", page: 1}
    end
  end

  describe "query/3" do
    test "searches the stop_id and the name case-insensitively" do
      bases = [
        base("UNS", %{name: "Central", last_edited_at: ~U[2026-09-01 10:00:00.000000Z]}),
        base("STB", %{name: "Union Station", last_edited_at: ~U[2026-09-02 10:00:00.000000Z]}),
        base("OTH", %{name: "Depot", last_edited_at: ~U[2026-09-03 10:00:00.000000Z]})
      ]

      by_id = StationBoard.query(bases, %{}, StationBoard.parse_params(%{"q" => "uns"}))
      assert ids(by_id) == ["UNS"]
      assert by_id.total == 1

      by_name = StationBoard.query(bases, %{}, StationBoard.parse_params(%{"q" => "UNION"}))
      assert ids(by_name) == ["STB"]
    end

    test "returns no rows and a single page when nothing matches" do
      result = StationBoard.query([base("UNS")], %{}, StationBoard.parse_params(%{"q" => "zzz"}))

      assert ids(result) == []
      assert result.total == 0
      assert result.total_pages == 1
      assert result.page == 1
    end

    test "orders by last edited descending with never-edited stations last, then by name" do
      bases = [
        base("S1", %{name: "Zulu", last_edited_at: ~U[2026-09-03 10:00:00.000000Z]}),
        base("S2", %{name: "Able", last_edited_at: ~U[2026-09-03 10:00:00.000000Z]}),
        base("S3", %{name: "Middle", last_edited_at: ~U[2026-09-01 10:00:00.000000Z]}),
        base("S4", %{name: "Never"})
      ]

      result = StationBoard.query(bases, %{}, StationBoard.parse_params(%{}))

      assert ids(result) == ["S2", "S1", "S3", "S4"]
    end

    test "orders the not-started filter by name" do
      bases = [
        base("S1", %{
          name: "Zulu",
          pathway_count: 0,
          last_edited_at: ~U[2026-09-03 10:00:00.000000Z]
        }),
        base("S2", %{
          name: "Able",
          pathway_count: 0,
          last_edited_at: ~U[2026-09-01 10:00:00.000000Z]
        }),
        base("S3", %{name: "Middle", pathway_count: 0}),
        base("S4", %{name: "Started", last_edited_at: ~U[2026-09-04 10:00:00.000000Z]})
      ]

      result =
        StationBoard.query(bases, %{}, StationBoard.parse_params(%{"stage" => "not_started"}))

      assert ids(result) == ["S2", "S3", "S1"]
      assert Enum.map(result.rows, & &1.stage) == [:not_started, :not_started, :not_started]
      assert result.counts.not_started == 3
    end

    test "filters by the in-progress and clean stages" do
      bases = [
        base("NEVER", %{name: "Never", pathway_count: 0}),
        base("CLEAN", %{name: "Clean"}),
        base("ISSUES", %{name: "Issues"}),
        base("STALE", %{name: "Stale"})
      ]

      statuses = %{
        "CLEAN" => status(),
        "ISSUES" => status(%{issues: 2}),
        "STALE" => status(%{reachability: run(:passed, %{stale?: true})})
      }

      clean =
        StationBoard.query(bases, statuses, StationBoard.parse_params(%{"stage" => "clean"}))

      assert ids(clean) == ["CLEAN"]
      assert Enum.map(clean.rows, & &1.status) == [statuses["CLEAN"]]

      in_progress =
        StationBoard.query(
          bases,
          statuses,
          StationBoard.parse_params(%{"stage" => "in_progress"})
        )

      assert in_progress |> ids() |> Enum.sort() == ["ISSUES", "STALE"]
    end

    test "keeps the stage counts as version totals independent of the search" do
      bases = [
        base("NEVER", %{pathway_count: 0}),
        base("CLEAN_1", %{name: "Clean One"}),
        base("CLEAN_2", %{name: "Clean Two"}),
        base("ISSUES", %{name: "Issues"})
      ]

      statuses = %{
        "CLEAN_1" => status(),
        "CLEAN_2" => status(),
        "ISSUES" => status(%{issues: 2})
      }

      result = StationBoard.query(bases, statuses, StationBoard.parse_params(%{"q" => "issues"}))

      assert result.counts == %{all: 4, not_started: 1, in_progress: 1, clean: 2}
      assert result.total == 1
      assert ids(result) == ["ISSUES"]
    end

    test "reports unknown stages and nil counts when statuses are unavailable" do
      bases = [
        base("NEVER", %{name: "Never", pathway_count: 0}),
        base("STARTED", %{name: "Started"})
      ]

      result = StationBoard.query(bases, :unavailable, StationBoard.parse_params(%{}))

      assert result.counts == %{all: 2, not_started: 1, in_progress: nil, clean: nil}

      assert Enum.map(result.rows, &{&1.base.stop_id, &1.stage, &1.status}) == [
               {"NEVER", :not_started, nil},
               {"STARTED", :unknown, nil}
             ]

      clean =
        StationBoard.query(bases, :unavailable, StationBoard.parse_params(%{"stage" => "clean"}))

      assert ids(clean) == []
    end

    test "pages twelve rows and clamps a page past the last" do
      bases = for index <- 1..13, do: base("S" <> String.pad_leading(to_string(index), 2, "0"))

      first = StationBoard.query(bases, %{}, StationBoard.parse_params(%{"page" => "1"}))
      assert first.page == 1
      assert first.total == 13
      assert first.total_pages == 2
      assert length(first.rows) == 12

      past_end = StationBoard.query(bases, %{}, StationBoard.parse_params(%{"page" => "9"}))
      assert past_end.page == 2
      assert ids(past_end) == ["S13"]
    end
  end

  defp base(stop_id, attrs \\ %{}) do
    Map.merge(
      %{
        id: "8d7d4a1a-0000-4000-8000-000000000000",
        stop_id: stop_id,
        name: "#{stop_id} Station",
        level_count: 0,
        floorplan_count: 0,
        pathway_count: 1,
        last_edited_at: nil,
        last_edited_by: nil
      },
      attrs
    )
  end

  defp status(attrs \\ %{}) do
    Map.merge(%{issues: 0, reachability: run(:passed)}, attrs)
  end

  defp run(outcome, attrs \\ %{}) do
    Map.merge(
      %{
        run_id: "1f2d3c4b-0000-4000-8000-000000000000",
        outcome: outcome,
        reachable: 4,
        pair_count: 4,
        completed_at: ~U[2026-09-01 09:00:00.000000Z],
        stale?: false
      },
      attrs
    )
  end

  defp ids(result), do: Enum.map(result.rows, & &1.base.stop_id)
end

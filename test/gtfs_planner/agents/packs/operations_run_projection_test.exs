defmodule GtfsPlanner.Agents.Packs.OperationsRunProjectionTest do
  @moduledoc """
  The run-day projection's observable contract: the payload an operations helper
  session reads over one loaded Runs day.

  `GtfsPlanner.Gtfs.OperationsAssistance.run_day/1` is called on the real
  `GtfsPlanner.Gtfs.Runs.load_runs/3` result, so every expected second below is
  the clock arithmetic of the fixtures' own stop times, worked out in the comment
  above each case rather than read back from the projection. The crew rules are
  the researched defaults the version stores: a 15-minute pull-out report, a
  5-minute relief report, a 5-minute sign-off, a 30-minute paid break maximum and
  a 720-minute spread limit, with a 120-minute piece limit set by this version's
  own blocking settings.

  The fixture's garage sits on the same point as its stops, so a drive the
  geometry does not imply is a real zero minutes rather than an estimate, and the
  one stop without coordinates is what makes a leg unmeasurable. Nothing in the
  day is invented for the projection: `NOCOORD` has no point at all, so the leg
  to and from it is the domain's own unknown.

  The cases follow the step's own obligations:

  - the overnight block's run and the run whose second piece starts before the
    first one ends are paid, spread, reported and signed off on handwritten
    seconds, above 24:00 where the service day runs over; the negative break
    stays −2,100 s and the `:cannot_reach_piece` error raised against it is
    copied beside it;
  - the two runs handed over at the unmeasurable stop keep their zero travel
    seconds and their `:unknown` legs, and the day keeps the overlong overnight
    piece's `:piece_too_long` warning, one uncovered trip and one orphan
    assignment as separate labelled counts;
  - a sentinel employee name, employee ID, seniority and operator note planted
    in the loaded input is absent from the serialized payload, and the shape
    refusals - a value that is not a loaded runs day, a day with no day type, a
    finding naming a run the day does not hold - are `:unavailable` rather than
    another day's answer.

  Rows are created inside the SQL Sandbox transaction and rolled back. The
  focused gate command is handed to branch review:
  `mix test test/gtfs_planner/agents/packs/operations_run_projection_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures, only: [editor_audit_fixture: 2]
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures, only: [route_fixture: 3, stop_fixture: 3]
  import GtfsPlanner.OperationsFixtures, only: [garage_fixture: 2]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures, only: [trip_run_fixture: 3]
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.OperationsAssistance
  alias GtfsPlanner.Gtfs.Runs

  @sentinel "OPERATOR-SENTINEL"

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    # The garage sits on the same point as the day's stops, so a drive the day's
    # geometry does not imply estimates to a real zero minutes. `NOCOORD` is the
    # one place with no point at all, which is what makes the legs to and from it
    # unknown rather than measured.
    garage =
      garage_fixture(organization.id, %{
        "lat" => Decimal.new("40.0"),
        "lon" => Decimal.new("-74.0")
      })

    stop_fixture(organization.id, version.id, %{
      stop_id: "BAY_A",
      stop_name: "Bay A",
      stop_lat: Decimal.new("40.0"),
      stop_lon: Decimal.new("-74.0")
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "NOCOORD",
      stop_name: "Nowhere",
      stop_lat: nil,
      stop_lon: nil
    })

    {:ok, _settings} =
      Blocking.update_settings(audit, %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: "any",
        default_garage_id: garage.id,
        deadhead_speed_kmh: 30,
        deadhead_circuity: 1.3,
        max_piece_minutes: nil
      })

    # A piece limit with no marked relief point: this day has no candidate to mark,
    # so a cut cannot be planned into it and the copy must say so rather than
    # claim relief is ready.
    {:ok, :ok} =
      Blocking.update_relief_settings(audit, nil, %{max_piece_minutes: 120, marked: []})

    day_key = day_key!(organization, version)

    world = %{organization: organization, version: version, route: route, day_key: day_key}
    free_trip = seed_runs(world)

    # One assignment row under a day type key this version no longer has. It is
    # counted on every day type's page, and it is the day's one orphan.
    trip_run_fixture(organization.id, version.id, %{
      trip: free_trip,
      day_type_key: "deleted-day-type",
      run_id: "7777"
    })

    Map.merge(world, %{garage: garage})
  end

  describe "the work components of a run" do
    # Run 4001 is one piece: the overnight block leaves 22:30 and arrives 25:10,
    # so the piece is 9,600 s. Its report is the 15-minute pull-out, its sign-off
    # allowance is 5 minutes, and every leg of the day is garage to itself, so
    # there is no travel at all:
    #
    #   sign on   81,000 − 900                = 80,100  (22:15)
    #   sign off  90,600 + 300                = 90,900  (25:15, past midnight)
    #   spread    90,900 − 80,100             = 10,800  (180 min)
    #   paid      900 + 9,600 + 0 + 300       = 10,800  (180 min)
    #
    # The piece runs 160 minutes against this version's 120-minute piece limit, so
    # the day keeps one `:piece_too_long` warning and never a feasibility claim.
    test "an overnight run is paid, spread and signed off on its own seconds", context do
      payload = project!(load_runs!(context))

      assert payload["schema_version"] == 1
      assert payload["section"] == "runs"
      assert payload["day_key"] == context.day_key
      assert payload["completeness"] == "complete"
      assert payload["scope"]["mode"] == "whole_day"
      assert payload["selection"] == %{"selected_run_refs" => [], "selected_trip_refs" => []}
      assert payload["plan"] == nil

      night = run(payload, "4001")

      assert night["sign_on_secs"] == 80_100
      assert night["sign_off_secs"] == 90_900
      assert night["spread_secs"] == 10_800
      assert night["vehicle_secs"] == 9_600
      assert night["report_secs"] == 900
      assert night["sign_off_allowance_secs"] == 300
      assert night["travel_secs"] == 0
      assert night["paid_secs"] == 10_800
      assert night["type"] == "one_piece"
      assert night["garage_id"] == context.garage.id
      assert night["breaks"] == []
      assert night["unknown_travel"] == []

      # Above 86,400 s: the service day carries an overnight value through
      # unchanged rather than wrapping it.
      assert night["sign_off_secs"] > 86_400

      assert [piece] = night["pieces"]
      assert piece["piece_index"] == 1
      assert piece["block_id"] == "201"
      assert {piece["start_secs"], piece["end_secs"]} == {81_000, 90_600}
      assert piece["start_kind"] == "block_start"
      assert piece["end_kind"] == "block_end"
      assert piece["trip_refs"] == [trip_entity(payload, "night")["trip_ref"]]

      assert [long] = issues(payload, "piece_too_long")
      assert long["severity"] == "warning"
      assert long["run_refs"] == [night["run_ref"]]
      assert long["detail"] == %{"piece" => 1, "secs" => 9_600, "limit_secs" => 7_200}
      assert payload["constraints"]["max_piece_minutes"] == 120

      assert payload["day_ref"] =~ ~r/\Aday_[0-9a-f]{32}\z/
      assert payload["source_digest"] =~ ~r/\A[0-9a-f]{64}\z/
    end

    # Run 3001 serves two whole blocks. The first piece is 05:50–06:50; the second
    # block leaves at 06:30, which is before the first piece ends, so the break
    # between them is 06:30 − 15 min of report − 06:50 = −35 min = −2,100 s:
    #
    #   sign on   21,000 − 900                = 20,100  (05:35)
    #   sign off  25,200 + 300                = 25,500  (07:05)
    #   spread    25,500 − 20,100             = 5,400   (90 min)
    #   reports   900 + 900                   = 1,800   (30 min)
    #   vehicle   2,400 + 3,000               = 5,400   (90 min)
    #   paid      1,800 + 5,400 + 0 + 300     = 7,500   (125 min)
    #
    # The negative break is unpaid, so the run is a split, and it is copied as the
    # negative number it is: 06:30 − 06:50 = −1,200 s is available and 900 s of it
    # is the report with nowhere to go.
    test "a negative break stays negative and the error raised against it travels with it",
         context do
      payload = project!(load_runs!(context))

      split = run(payload, "3001")

      assert split["sign_on_secs"] == 20_100
      assert split["sign_off_secs"] == 25_500
      assert split["spread_secs"] == 5_400
      assert split["report_secs"] == 1_800
      assert split["vehicle_secs"] == 5_400
      assert split["travel_secs"] == 0
      assert split["paid_secs"] == 7_500
      assert split["type"] == "split"

      assert [%{"secs" => -2_100, "paid?" => false, "after_piece" => 1}] = split["breaks"]

      assert [first, second] = split["pieces"]
      assert {first["piece_index"], second["piece_index"]} == {1, 2}
      assert first["block_id"] == "203"
      assert second["block_id"] == "204"

      assert [error] = issues(payload, "cannot_reach_piece")
      assert error["severity"] == "error"
      assert error["run_refs"] == [split["run_ref"]]
      assert error["block_id"] == "203"

      assert error["detail"] == %{
               "needed_secs" => 900,
               "available_secs" => -1_200,
               "secs" => -2_100,
               "stop_id" => "BAY_A",
               "after_piece" => 1,
               "piece" => "3001"
             }
    end
  end

  describe "work the day could not measure" do
    # Block 202 hands over at `NOCOORD`, which has no coordinates, so no window
    # exists there and the change happens where the earlier trip ends. Both legs
    # touching that stop are unmeasurable, and `Runs.WorkTime` charges each of them
    # zero seconds:
    #
    #   run 5001 (the outgoing piece): report 900, vehicle 1,800, sign-off 300
    #     sign on  28,800 − 900 = 27,900 (07:45)   sign off 30,600 + 300 = 30,900 (08:35)
    #     spread 3,000 (50 min)   paid 900 + 1,800 + 0 + 300 = 3,000 (50 min)
    #   run 5002 (the incoming piece, a 5-minute relief report):
    #     sign on  30,600 − 300 = 30,300 (08:25)   sign off 34,200 + 300 = 34,500 (09:35)
    #     spread 4,200 (70 min)   paid 300 + 3,600 + 0 + 300 = 4,200 (70 min)
    test "an unmeasured leg keeps its unknown status beside its zero seconds", context do
      payload = project!(load_runs!(context))

      out = run(payload, "5001")

      assert out["sign_on_secs"] == 27_900
      assert out["sign_off_secs"] == 30_900
      assert out["spread_secs"] == 3_000
      assert out["report_secs"] == 900
      assert out["vehicle_secs"] == 1_800
      assert out["travel_secs"] == 0
      assert out["paid_secs"] == 3_000
      assert out["type"] == "one_piece"

      assert [%{"piece_index" => 1, "start_kind" => "block_start", "end_kind" => "relief"}] =
               out["pieces"]

      assert out["unknown_travel"] == [
               %{"from" => "stop:NOCOORD", "to" => "garage:#{context.garage.id}"}
             ]

      incoming = run(payload, "5002")

      assert incoming["sign_on_secs"] == 30_300
      assert incoming["sign_off_secs"] == 34_500
      assert incoming["spread_secs"] == 4_200
      assert incoming["report_secs"] == 300
      assert incoming["vehicle_secs"] == 3_600
      assert incoming["travel_secs"] == 0
      assert incoming["paid_secs"] == 4_200

      assert [%{"piece_index" => 1, "start_kind" => "relief", "end_kind" => "block_end"}] =
               incoming["pieces"]

      assert incoming["unknown_travel"] == [
               %{"from" => "garage:#{context.garage.id}", "to" => "stop:NOCOORD"}
             ]

      # One notice per unmeasured leg, copied with the legs themselves: a zero
      # never reads as a measured zero.
      assert [first, second] = issues(payload, "travel_unknown")

      assert Enum.all?([first, second], &(&1["severity"] == "notice"))

      assert Enum.sort([first["run_refs"], second["run_refs"]]) ==
               Enum.sort([[out["run_ref"]], [incoming["run_ref"]]])

      assert Enum.sort(Enum.map([first, second], & &1["detail"]["to"])) ==
               ["garage:#{context.garage.id}", "stop:NOCOORD"]

      # The handover is not at a relief point, so the day keeps that error against
      # both of the runs it names, with the boundary's trips as this session's own
      # refs rather than their database rows.
      assert [handover] = issues(payload, "not_at_relief")
      assert handover["severity"] == "error"
      assert handover["block_id"] == "202"

      assert handover["run_refs"] == [out["run_ref"], incoming["run_ref"]]

      assert handover["detail"] == %{
               "stop_id" => "NOCOORD",
               "stop_name" => "Nowhere",
               "from_trip_ref" => trip_entity(payload, "hand_out")["trip_ref"],
               "to_trip_ref" => trip_entity(payload, "hand_in")["trip_ref"]
             }
    end

    # One trip of block 205 is nobody's, so it is one uncovered segment of
    # 11:30 − 11:00 = 1,800 s. One assignment row sits under a day type key that
    # no longer exists, which `Runs.load_runs/3` counts as an orphan and reports as
    # a notice; it is counted beside the findings rather than inside them, and its
    # run "7777" reaches no run in the copy.
    test "uncovered work and orphan rows stay separately labelled counts", context do
      payload = project!(load_runs!(context))

      assert payload["orphans"] == %{"count" => 1}
      assert payload["figures"]["uncovered"] == %{"trips" => 1, "secs" => 1_800}

      assert [uncovered] = issues(payload, "uncovered_work")
      assert uncovered["severity"] == "warning"
      assert uncovered["detail"] == %{"trips" => 1, "secs" => 1_800}
      assert uncovered["trip_refs"] == [trip_entity(payload, "free")["trip_ref"]]

      # The trip is carried with no run against it, which is how a reader tells
      # uncovered work from a trip no payload mentions.
      assert trip_entity(payload, "free")["run_ref"] == nil
      assert trip_entity(payload, "night")["run_ref"] == run(payload, "4001")["run_ref"]

      assert [orphan] = issues(payload, "orphan_assignments")
      assert orphan["severity"] == "notice"
      assert orphan["detail"] == %{"count" => 1}
      refute "7777" in Enum.map(payload["entities"]["runs"], & &1["run_id"])
      refute "7777" in Enum.map(payload["scope"]["run_refs"], & &1)

      # Finding instance counts, never a sum over the figures above them: the two
      # handovers the boundary names are one finding, and the day's own arithmetic
      # for these numbers is the one beside them.
      assert payload["totals"] == %{
               "cannot_reach_piece" => 1,
               "not_at_relief" => 1,
               "orphan_assignments" => 1,
               "piece_too_long" => 1,
               "travel_unknown" => 2,
               "uncovered_work" => 1
             }

      assert payload["figures"]["runs"] == 4
      assert payload["figures"]["by_type"] == %{"one_piece" => 3, "straight" => 0, "split" => 1}
      assert payload["figures"]["straight_share"] == 0
      assert payload["figures"]["paid_secs"] == 25_500
      assert payload["figures"]["vehicle_secs"] == 20_400
      assert payload["figures"]["vehicle_share"] == 80

      assert payload["figures"]["longest_spread"] == %{
               "run_ref" => run(payload, "4001")["run_ref"],
               "run_id" => "4001",
               "secs" => 10_800
             }

      assert payload["figures"]["axis"] == %{"start_secs" => 20_100, "end_secs" => 90_900}
      assert payload["figures"]["problems"] == %{"errors" => 2, "warnings" => 2, "notices" => 3}

      # The stored crew rules travel with the copy, and the version's own marked
      # relief point and entered drive times are the inputs it was computed over.
      assert payload["constraints"]["crew"] == %{
               "report_pull_out_minutes" => 15,
               "report_relief_minutes" => 5,
               "sign_off_minutes" => 5,
               "paid_break_max_minutes" => 30,
               "max_spread_minutes" => 720
             }

      assert payload["constraints"]["relief_ready"] == false
      assert payload["constraints"]["marked_relief_stops"] == 0
      assert payload["constraints"]["entered_drive_times"] == 0
      assert payload["constraints"]["planning_inputs"] == true
      assert payload["constraints"]["default_garage_id"] == context.garage.id
    end
  end

  describe "the copy the session is handed" do
    test "an employee field planted in the loaded input never reaches the payload", context do
      runs_day = load_runs!(context)

      # The sentinels stand in for the personnel an operator change record or an
      # arbitrary note would carry if the copy were the loaded day.
      seeded =
        Map.update!(runs_day, :crew, &Map.put(&1, :employee_name, @sentinel))
        |> Map.update!(:derived, fn derived ->
          %{
            derived
            | runs:
                Enum.map(derived.runs, fn run ->
                  run
                  |> Map.put(:employee_id, @sentinel)
                  |> Map.update!(:work, &Map.put(&1, :seniority, @sentinel))
                  |> Map.update!(:pieces, fn pieces ->
                    Enum.map(pieces, &Map.put(&1, :operator_note, @sentinel))
                  end)
                end),
              uncovered: Enum.map(derived.uncovered, &Map.put(&1, :employee_name, @sentinel)),
              findings:
                Enum.map(derived.findings, fn finding ->
                  finding
                  |> Map.put(:employee_name, @sentinel)
                  |> Map.update!(:detail, &Map.put(&1, :employee_id, @sentinel))
                end)
          }
        end)

      encoded = Jason.encode!(project!(seeded))

      refute encoded =~ @sentinel
      refute encoded =~ "employee"
      refute encoded =~ "seniority"
      refute encoded =~ "operator_note"
    end

    test "a value that is not a loaded runs day, and a row the day cannot answer for, are unavailable",
         context do
      runs_day = load_runs!(context)

      assert OperationsAssistance.run_day(%{}) == {:error, :unavailable}
      assert OperationsAssistance.run_day(:not_a_day) == {:error, :unavailable}
      assert OperationsAssistance.run_day(Map.delete(runs_day, :crew)) == {:error, :unavailable}

      assert OperationsAssistance.run_day(Map.delete(runs_day, :fingerprint)) ==
               {:error, :unavailable}

      assert OperationsAssistance.run_day(
               Map.update!(runs_day, :derived, &Map.delete(&1, :stats))
             ) == {:error, :unavailable}

      # A version whose calendars derive no day type has no day to project, and
      # the projection does not fall back to another one.
      assert OperationsAssistance.run_day(
               Map.update!(runs_day, :day, &Map.put(&1, :day_type, nil))
             ) ==
               {:error, :unavailable}

      assert OperationsAssistance.run_day(%{runs_day | day: :not_a_day}) ==
               {:error, :unavailable}

      # A finding naming a run the day does not hold has no evidence to resolve,
      # so the whole projection is unavailable rather than quietly losing the row.
      forged =
        Map.update!(runs_day, :derived, fn derived ->
          %{
            derived
            | findings: [
                %{
                  code: :spread_too_long,
                  severity: :warning,
                  run_ids: ["9999"],
                  block_id: nil,
                  trip_ids: [],
                  detail: %{}
                }
              ]
          }
        end)

      assert OperationsAssistance.run_day(forged) == {:error, :unavailable}

      # The sections resolve nothing of each other's: a session holding both
      # projections names one day's blocks and the same day's runs with different
      # receipts.
      assert {:ok, block_payload} = OperationsAssistance.block_day(runs_day.day, %{})
      payload = project!(runs_day)

      refute block_payload["day_ref"] == payload["day_ref"]
      refute block_payload["source_digest"] == payload["source_digest"]
    end
  end

  # --- fixtures ----------------------------------------------------------

  # Five blocks, six trips and four runs. The days' own clocks are the expectations
  # in the cases above; this only stores them.
  defp seed_runs(context) do
    trip(context, "night", "201", "22:30:00", "25:10:00", "BAY_A", "BAY_A", "4001")

    trip(context, "hand_out", "202", "08:00:00", "08:30:00", "BAY_A", "NOCOORD", "5001")

    trip(context, "hand_in", "202", "09:00:00", "09:30:00", "NOCOORD", "NOCOORD", "5002")

    trip(context, "early", "203", "05:50:00", "06:50:00", "BAY_A", "BAY_A", "3001")

    trip(context, "late", "204", "06:30:00", "07:00:00", "BAY_A", "BAY_A", "3001")

    # Nobody serves this one, so it is the day's uncovered work.
    trip(context, "free", "205", "11:00:00", "11:30:00", "BAY_A", "BAY_A", nil)
  end

  defp trip(context, trip_id, block_id, first, last, first_stop, last_stop, run_id) do
    trip =
      blocked_trip_fixture(context.organization.id, context.version.id, context.route.route_id, %{
        trip_id: trip_id,
        service_id: "WK",
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_departure: first,
        last_arrival: last
      })

    if run_id do
      trip_run_fixture(context.organization.id, context.version.id, %{
        trip: trip,
        day_type_key: context.day_key,
        run_id: run_id
      })
    end

    trip
  end

  defp day_key!(organization, version) do
    {:ok, day} = Blocking.load_day(organization.id, version.id, nil)
    day.day_type.key
  end

  # --- reads --------------------------------------------------------------

  defp load_runs!(context) do
    assert {:ok, runs_day} =
             Runs.load_runs(context.organization.id, context.version.id, context.day_key)

    runs_day
  end

  defp project!(runs_day) do
    assert {:ok, payload} = OperationsAssistance.run_day(runs_day)
    payload
  end

  defp issues(payload, code), do: Enum.filter(payload["issues"], &(&1["code"] == code))

  defp run(payload, run_id),
    do: Enum.find(payload["entities"]["runs"], &(&1["run_id"] == run_id))

  defp trip_entity(payload, trip_id),
    do: Enum.find(payload["entities"]["trips"], &(&1["trip_id"] == trip_id))
end

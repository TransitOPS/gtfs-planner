defmodule GtfsPlanner.Agents.ServiceQueriesPackTest do
  @moduledoc """
  Merge evidence (EV-4) for the Schedule pack through the real composition:
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> `Packs.ServiceQueries`
  -> `Gtfs.ServiceQueries`, with only the OpenRouter HTTP boundary doubled.

  The registry, session, turn loop, dispatch fence, pack and domain query are the
  shipped ones, so a pack that was never registered, a tool that never reached the
  domain and evidence that never reached the entry all fail here rather than
  passing over a hand-built controller. What the model actually read is asserted
  on the tool message of the next provider request, so the rows the pack sent and
  the card the panel will render come from the same read.

  Every expectation is hand-derived from the A02/A19 acceptance cases and the
  GTFS Schedule reference, not from a second invocation of the module under test:

    * 2026-11-26 is a Thursday whose weekday service is removed and replaced by an
      exception-only calendar, so `18:20` and `19:10` are the only listed
      departures strictly after 18:00 and the two 18:00 trips are excluded.
    * The loop visits Central Station at sequences 1 and 9, so a stop-only request
      is ambiguous and the candidates are the exact sequences that answer it.
    * The frequency trip leaves its first stop at 20:00 and boards Central Station
      15 minutes later, so its window reads 20:15-22:15 there, separate from the
      listed departures, with an exact second window kept distinct.
    * The trip with no recorded time is disclosed and counted in no total.
    * H8 has no active trip on either November date while H12 keeps Sunday service
      through `SCHOOL`, so a coverage read names the alternate service.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Packs.ServiceQueries
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @thanksgiving "2026-11-26"
  @thanksgiving_eve "2026-11-25"
  @central "CENTRAL"
  @harbor "HARBOR"

  @departure_arguments ~s({"service_date":"2026-11-26","stop_id":"CENTRAL","stop_sequence":1,"after":"18:00","include_after_midnight":false})
  @loop_arguments ~s({"service_date":"2026-11-26","stop_id":"CENTRAL","after":"18:00","include_after_midnight":false})
  @occurrence_arguments ~s({"service_date":"2026-11-26"})
  @coverage_arguments ~s({"dates":["2026-11-25","2026-11-26"]})
  @calendar_coverage_arguments ~s({"service_id":"REGULAR","dates":["2026-11-25","2026-11-26"],"route_ids":["H8","H12"]})
  @calendar_usage_arguments ~s({"service_id":"REGULAR","dates":["2026-11-26"]})
  @final_text "Central Station has two departures after 6:00pm on Thanksgiving."

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox are both shared (`async: false`).
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    harbor = harbor_scope()

    Map.put(harbor, :scope, scope(harbor, "service_queries", harbor.route))
  end

  describe "the shipped registration" do
    test "the registry names the pack and a route identity opens its session", context do
      assert Agents.packs()["service_queries"] == ServiceQueries
      assert ServiceQueries.id() == "service_queries"
      assert ServiceQueries.title() == "Schedule helper"

      assert Enum.map(ServiceQueries.tools(), & &1.name) == [
               "list_boarding_occurrences",
               "query_departures",
               "summarize_service",
               "compare_service_dates"
             ]

      assert Enum.all?(ServiceQueries.tools(), &(&1.parameters["additionalProperties"] == false))
      assert ServiceQueries.skill() =~ "list_boarding_occurrences"

      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []

      # The same person on another route is a different conversation, and a
      # version-bound one is not this pack's conversation at all.
      other_route = context.other_route
      assert {:ok, other_session, _snapshot} = Agents.open(route_scope(context, other_route))
      refute other_session == session

      assert Agents.open(%{context.scope | resource_context: Scope.context(nil)}) ==
               {:error, :unavailable}
    end

    test "a version-bound conversation cannot run this pack's tools", context do
      version_scope = %{context.scope | resource_context: Scope.context(nil)}

      assert {:error, :unavailable} =
               Dispatch.call(
                 ServiceQueries,
                 version_scope,
                 "query_departures",
                 @departure_arguments
               )
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> domain)" do
    test "a departure question answers from the real query and carries its evidence", context do
      expect_reply(tool_calls_reply([{"call_1", "query_departures", @departure_arguments}]))
      expect_reply(text_reply(@final_text))

      entry = run_turn(context.scope, "What leaves Central Station after 6pm on Thanksgiving?")

      assert entry.status == :done
      assert entry.text == @final_text
      assert entry.activity == ["Checked departures"]

      # What the model read: the two listed departures, the translated windows
      # and the separately disclosed unknown time.
      assert %{
               "departures" => departures,
               "frequency_windows" => windows,
               "unknown_times" => unknown
             } =
               tool_result()

      assert Enum.map(departures, & &1["time"]) == ["18:20:00", "19:10:00"]
      assert Enum.map(departures, & &1["trip_id"]) == ["H8-1820", "H8-1910"]
      assert Enum.all?(departures, &(&1["service_id"] == "HOLIDAY"))

      assert Enum.map(windows, &{&1["start"], &1["end"], &1["exact_times"]}) == [
               {"20:15:00", "22:15:00", 0},
               {"21:15:00", "22:15:00", 1}
             ]

      assert Enum.all?(windows, &(&1["expanded"] == false))
      assert Enum.map(unknown, & &1["trip_id"]) == ["H8-UNKNOWN"]

      # The card's count is the server's count, over the same rows.
      assert [evidence] = entry.evidence
      assert evidence.kind == "service_departures"
      assert evidence.total == 2
      assert evidence.total_label == "departures"
      assert evidence.completeness == :complete
      assert evidence.source_ref == "gtfs_service_queries"
      assert evidence.digest =~ ~r/\A[0-9a-f]{64}\z/
      assert evidence.source_revision == nil

      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.gtfs_version_id == context.version.id
      assert evidence.scope.identity == "route:#{context.route.id}"
      assert [%{kind: "route", id: "H8", label: "H8"}] = evidence.resources

      assert Enum.find(evidence.facts, &(&1.label == "Route time zone")).value ==
               "America/New_York"

      # A read query writes nothing.
      assert Repo.aggregate(Trip, :count) == context.trip_count
    end

    test "an ambiguous stop is refused with its candidate occurrences and no total", context do
      expect_reply(tool_calls_reply([{"call_1", "query_departures", @loop_arguments}]))
      expect_reply(text_reply("Which visit did you mean?"))

      entry = run_turn(context.scope, "When does the 8 leave Central Station after 6pm?")

      assert entry.status == :done
      assert %{"error" => message} = tool_result()
      assert message =~ "occurrence 1"
      assert message =~ "occurrence 9"

      # A refusal produces no evidence, so no card can claim a count.
      assert entry.evidence == []
    end

    test "occurrence discovery offers both loop visits before any departure is asked", context do
      expect_reply(
        tool_calls_reply([{"call_1", "list_boarding_occurrences", @occurrence_arguments}])
      )

      expect_reply(text_reply("Which visit did you mean?"))

      entry = run_turn(context.scope, "Which stops does this route board at on Thanksgiving?")

      assert %{"occurrences" => occurrences, "total" => 2} = tool_result()

      central = Enum.find(occurrences, &(&1["stop_id"] == @central))
      assert central["stop_name"] == "Central Station"
      assert central["stop_sequences"] == [1, 9]
      assert central["ambiguous"] == true

      harbor = Enum.find(occurrences, &(&1["stop_id"] == @harbor))
      assert harbor["stop_sequences"] == [0]
      assert harbor["ambiguous"] == false

      assert [evidence] = entry.evidence
      assert evidence.kind == "boarding_occurrences"
      assert evidence.total == 2
      assert evidence.total_label == "stops to board at"
    end

    test "coverage uses every active calendar and names the alternate service", context do
      expect_reply(tool_calls_reply([{"call_1", "summarize_service", @coverage_arguments}]))
      expect_reply(text_reply("The 8 runs on Thanksgiving only."))

      entry = run_turn(context.scope, "Does the 8 run on the 25th and the 26th?")

      assert %{"records" => records, "total" => 2} = tool_result()

      with_service = Enum.find(records, &(&1["date"] == @thanksgiving))
      without_service = Enum.find(records, &(&1["date"] == @thanksgiving_eve))

      assert with_service["recorded_service"] == true
      assert with_service["service_ids"] == ["HOLIDAY"]
      assert with_service["frequency_templates"] == 1
      assert with_service["missing_time_templates"] == 1
      assert with_service["absence_reason"] == nil

      assert without_service["recorded_service"] == false
      assert without_service["absence_reason"] == "no_active_trip"
      assert without_service["listed_trip_templates"] == 0

      assert [evidence] = entry.evidence
      assert evidence.kind == "service_coverage"
      assert evidence.total == 2
      assert evidence.completeness == :complete
      assert Enum.find(evidence.facts, &(&1.label == "Dates with recorded service")).value == "1"
    end

    test "comparing dates lists both dates for the route", context do
      expect_reply(tool_calls_reply([{"call_1", "compare_service_dates", @coverage_arguments}]))
      expect_reply(text_reply("Thanksgiving runs; the day before does not."))

      entry = run_turn(context.scope, "Compare the 25th and the 26th for this route.")

      assert %{"comparisons" => [comparison]} = tool_result()
      assert comparison["route_id"] == "H8"
      assert comparison["dates_with_service"] == [@thanksgiving]
      assert comparison["dates_without_service"] == [@thanksgiving_eve]
      assert comparison["service_ids"] == ["HOLIDAY"]

      assert [evidence] = entry.evidence
      assert evidence.kind == "service_date_comparison"
      assert evidence.total == 2
    end

    test "an over-limit request is refused by the fence with a narrowing path", context do
      dates = Enum.map_join(1..32, ",", &Jason.encode!("2027-01-#{pad(&1)}"))
      arguments = ~s({"dates":[#{dates}]})

      expect_reply(tool_calls_reply([{"call_1", "summarize_service", arguments}]))
      expect_reply(text_reply("Let me look at fewer dates."))

      entry = run_turn(context.scope, "Compare a whole month of dates.")

      assert %{"error" => message} = tool_result()
      assert message =~ "31"
      assert entry.evidence == []
    end

    test "a deleted route refuses the next turn without a provider request", context do
      expect_reply(text_reply(@final_text))

      assert {:ok, session, _snapshot} = Agents.open(context.scope)
      Repo.delete!(context.route)

      assert {:error, :unavailable} = Agents.send_message(session, "What leaves after 6pm?")
      refute_received {:model_request, _request}
      assert_receive {:agent_event, ^session, {:entry, %{status: :unavailable}}}, 5_000
    end
  end

  describe "the Calendar pack's coverage and usage reads" do
    test "summarize_calendar_coverage reports route and date facts for the named routes",
         context do
      expect_reply(
        tool_calls_reply([
          {"call_1", "summarize_calendar_coverage", @calendar_coverage_arguments}
        ])
      )

      expect_reply(text_reply("H8 loses service after Regular ends; H12 keeps Sunday service."))

      entry =
        run_turn(scope(context, "calendars"), "What happens to H8 and H12 after Regular ends?")

      assert %{"records" => records, "total" => 4} = tool_result()

      h8_after = Enum.find(records, &(&1["route_id"] == "H8" and &1["date"] == @thanksgiving_eve))

      h12_after =
        Enum.find(records, &(&1["route_id"] == "H12" and &1["date"] == @thanksgiving_eve))

      assert h8_after["recorded_service"] == false
      assert h8_after["absence_reason"] == "no_active_trip"
      assert h12_after["recorded_service"] == true
      assert h12_after["service_ids"] == ["SCHOOL"]

      assert [evidence] = entry.evidence
      assert evidence.kind == "calendar_coverage"
      assert evidence.total == 4
      assert evidence.source_ref == "gtfs_service_queries"
      assert evidence.scope.identity == "version:#{context.version.id}"
      assert Enum.map(evidence.resources, & &1.id) == ["H12", "H8"]
    end

    test "get_calendar_usage covers the routes the calendar is used by", context do
      expect_reply(
        tool_calls_reply([{"call_1", "get_calendar_usage", @calendar_usage_arguments}])
      )

      expect_reply(text_reply("Regular runs H8 on Thanksgiving."))

      entry = run_turn(scope(context, "calendars"), "Which routes use Regular on Thanksgiving?")

      assert %{"records" => records} = tool_result()
      assert Enum.all?(records, &(&1["date"] == @thanksgiving))

      assert [evidence] = entry.evidence
      assert evidence.kind == "calendar_usage"
      assert evidence.total == length(records)
    end

    test "a foreign route in the Calendar coverage read is refused before any disclosure",
         context do
      organization_fixture()
      arguments = ~s({"service_id":"REGULAR","dates":["2026-11-26"],"route_ids":["H8","FOREIGN"]})

      expect_reply(tool_calls_reply([{"call_1", "summarize_calendar_coverage", arguments}]))
      expect_reply(text_reply("That route is not in this version."))

      entry = run_turn(scope(context, "calendars"), "Check the foreign route too.")

      assert %{"error" => message} = tool_result()
      assert message == "A named route is not in this service version."
      assert entry.evidence == []
    end

    test "the old Calendar tool calls keep working", context do
      expect_reply(tool_calls_reply([{"call_1", "list_calendars", "{}"}]))
      expect_reply(text_reply("Three calendars match."))

      entry = run_turn(scope(context, "calendars"), "Which calendars are here?")

      assert entry.activity == ["Looked up calendars"]
      assert entry.evidence == []
      assert "prepare_date_change" in Enum.map(Calendars.tools(), & &1.name)
    end
  end

  describe "the dispatch fence" do
    test "a model-supplied route, version or organization argument never reaches the pack",
         context do
      for extra <- ["route_id", "organization_id", "gtfs_version_id"] do
        arguments =
          ~s({"service_date":"2026-11-26","stop_id":"CENTRAL","after":"18:00","include_after_midnight":false,"#{extra}":"x"})

        assert {:tool_error, message} =
                 Dispatch.call(ServiceQueries, context.scope, "query_departures", arguments)

        assert message =~ "Unexpected argument"
      end
    end

    test "a missing required argument is refused before the pack runs", context do
      assert {:tool_error, message} =
               Dispatch.call(
                 ServiceQueries,
                 context.scope,
                 "query_departures",
                 ~s({"service_date":"2026-11-26"})
               )

      assert message =~ "include_after_midnight"
    end

    test "the pack refuses a malformed date with a message the model can correct", context do
      assert {:error, message} =
               ServiceQueries.call(
                 "list_boarding_occurrences",
                 %{"service_date" => "not-a-date"},
                 context.scope
               )

      assert message =~ "2026-11-26"

      assert {:error, message} =
               ServiceQueries.call(
                 "query_departures",
                 %{
                   "service_date" => @thanksgiving,
                   "stop_id" => @central,
                   "after" => "half past six",
                   "include_after_midnight" => false
                 },
                 context.scope
               )

      assert message =~ "18:00"
    end

    test "an occurrence that does not run on the date is refused without a total", context do
      assert {:error, message} =
               ServiceQueries.call(
                 "query_departures",
                 %{
                   "service_date" => @thanksgiving,
                   "stop_id" => "NOWHERE",
                   "after" => "18:00",
                   "include_after_midnight" => false
                 },
                 context.scope
               )

      assert message =~ "does not board"
    end
  end

  ## Helpers

  # The working placeholder arrives before the settled entry, and each provider
  # request is observable, so a turn is driven and read without polling a render
  # or sleeping.
  defp run_turn(scope, text) do
    assert {:ok, pid, _snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    await_settled(pid)
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  # The tool message the turn sent back to the provider is the pack's own result,
  # decoded, so the assertions read what the model read.
  defp tool_result do
    assert_receive {:model_request, request}, 5_000

    request["messages"]
    |> Enum.filter(&(&1["role"] == "tool"))
    |> List.last()
    |> Map.fetch!("content")
    |> Jason.decode!()
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # Harbor Transit's A02/A19 dataset: `WEEKDAY` is the recurring calendar removed
  # on the holiday, `HOLIDAY` is exception-only, `SCHOOL` keeps H12's Sunday
  # service after `REGULAR` ends, and `REGULAR` is the calendar the coverage
  # question reviews.
  defp harbor_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [{@central, "Central Station"}, {@harbor, "Harbor Yards"}] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    other_route = route_fixture(organization.id, version.id, %{route_id: "H12"})

    calendar_fixture(organization.id, version.id, weekday_calendar("WEEKDAY"))
    calendar_fixture(organization.id, version.id, daily_calendar("REGULAR"))
    calendar_fixture(organization.id, version.id, sunday_calendar("SCHOOL"))

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      date: Date.from_iso8601!(@thanksgiving),
      exception_type: 2
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "HOLIDAY",
      date: Date.from_iso8601!(@thanksgiving),
      exception_type: 1
    })

    seed_trips(organization.id, version.id)

    %{
      organization: organization,
      version: version,
      route: route,
      other_route: other_route,
      trip_count: Repo.aggregate(Trip, :count)
    }
  end

  defp seed_trips(organization_id, version_id) do
    for {trip_id, time} <- [
          {"H8-1800", "18:00:00"},
          {"H8-1820", "18:20:00"},
          {"H8-1910", "19:10:00"}
        ] do
      holiday_trip(organization_id, version_id, trip_id, [{@central, 1, time}])
    end

    holiday_trip(organization_id, version_id, "H8-LOOP", [
      {@central, 1, "18:00:00"},
      {@harbor, 5, "21:00:00"},
      {@central, 9, "23:50:00"}
    ])

    holiday_trip(organization_id, version_id, "H8-FREQ", [
      {@harbor, 0, "20:00:00"},
      {@central, 1, "20:15:00"}
    ])

    for {start_time, end_time, headway_secs, exact_times} <- [
          {"20:00:00", "22:00:00", 1200, 0},
          {"21:00:00", "22:00:00", 600, 1}
        ] do
      frequency_fixture(organization_id, version_id, "H8-FREQ", %{
        start_time: start_time,
        end_time: end_time,
        headway_secs: headway_secs,
        exact_times: exact_times
      })
    end

    holiday_trip(organization_id, version_id, "H8-UNKNOWN", [{@central, 1, nil}])

    school_trip(organization_id, version_id, "H12-SUN-FREQ", [{@central, 1, "12:00:00"}])

    frequency_fixture(organization_id, version_id, "H12-SUN-FREQ", %{
      start_time: "12:00:00",
      end_time: "14:00:00",
      headway_secs: 1800,
      exact_times: 0
    })
  end

  defp holiday_trip(organization_id, version_id, trip_id, stops) do
    trip_fixture(organization_id, version_id, "H8", %{
      trip_id: trip_id,
      service_id: "HOLIDAY",
      direction_id: 0
    })

    add_stop_times(organization_id, version_id, trip_id, stops)
  end

  defp school_trip(organization_id, version_id, trip_id, stops) do
    trip_fixture(organization_id, version_id, "H12", %{
      trip_id: trip_id,
      service_id: "SCHOOL"
    })

    add_stop_times(organization_id, version_id, trip_id, stops)
  end

  # A `nil` time is the dataset's one row with no recorded time; the column is
  # written blank after insertion so the row reaches the pack as the feed
  # exports it.
  defp add_stop_times(organization_id, version_id, trip_id, stops) do
    Enum.each(stops, fn
      {stop_id, sequence, nil} ->
        stop_time =
          stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
            stop_sequence: sequence
          })

        Repo.update_all(from(t in StopTime, where: t.id == ^stop_time.id),
          set: [arrival_time: nil, departure_time: nil]
        )

      {stop_id, sequence, time} ->
        stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
          stop_sequence: sequence,
          arrival_time: time,
          departure_time: time
        })
    end)
  end

  defp weekday_calendar(service_id) do
    Map.merge(weekdays(), %{
      service_id: service_id,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    })
  end

  defp daily_calendar(service_id) do
    weekdays()
    |> Map.merge(%{
      service_id: service_id,
      saturday: 1,
      sunday: 1,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-10-31]
    })
  end

  defp sunday_calendar(service_id) do
    weekdays()
    |> Map.merge(%{
      service_id: service_id,
      saturday: 0,
      sunday: 1,
      start_date: ~D[2026-09-01],
      end_date: ~D[2026-12-31]
    })
  end

  defp weekdays do
    %{
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    }
  end

  defp scope(context, pack_id, route \\ nil) do
    user = user_fixture()
    organization_membership_fixture(user, context.organization)

    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: pack_id,
      version_name: context.version.name,
      resource_context: route_context(route)
    }
  end

  defp route_scope(context, route), do: scope(context, "service_queries", route)

  defp route_context(nil), do: Scope.context(nil)
  defp route_context(route), do: Scope.context({:route, route.id})

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end

  ## Scripted OpenRouter replies

  defp expect_reply(payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  defp text_reply(content) do
    %{
      "id" => "gen-test-text",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 16, "cost" => 0.0}
    }
  end

  defp tool_calls_reply(calls) do
    %{
      "id" => "gen-test-tool",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" =>
              Enum.map(calls, fn {id, name, arguments} ->
                %{
                  "id" => id,
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => arguments}
                }
              end)
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 32, "cost" => 0.0}
    }
  end
end

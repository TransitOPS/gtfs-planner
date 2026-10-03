defmodule GtfsPlanner.Agents.BrowserOpenRouterTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Agents.BrowserOpenRouter
  alias GtfsPlanner.Agents.Model
  alias GtfsPlanner.Agents.Packs.Alerts
  alias GtfsPlanner.Agents.Packs.Calendars

  @user_school "No school service next Monday and Tuesday"
  @prepared_sentence "I prepared the change. Review it before applying."
  @generic_sentence "I can answer questions about calendars and prepare date changes."
  @alerts_prepared_sentence "I prepared a detour on Route 12."
  @user_route_12 "Route 12 is detouring between Elm and 3rd"
  @route_12_id "11111111-2222-3333-4444-555555555555"
  @today "2026-10-01"

  describe "scripted replies" do
    test "a school request asks for the school calendars" do
      body = post([user(@user_school)])

      assert body["model"] == "test/model-a"

      assert {arguments, "list_calendars"} = tool_call(body)
      assert Jason.decode!(arguments) == %{"query" => "school"}
    end

    test "an out-of-scope request gets the Calendars skill's sentence" do
      content = final_text(post([user("Delete route 12")]))

      assert content =~ "That isn't available in Calendars"
      assert String.contains?(Calendars.skill(), content)
    end

    test "any other request gets the generic sentence" do
      assert final_text(post([user("Hello")])) == @generic_sentence
    end

    test "a tool result with no matching call gets the generic sentence" do
      messages = [user("Hello"), tool_result("call_unknown", %{"error" => "Unknown tool."})]

      assert final_text(post(messages)) == @generic_sentence
    end

    test "a list_calendars result prepares the next Monday and Tuesday" do
      body =
        post([
          user(@user_school),
          assistant_tool_call("call_list_calendars", "list_calendars", %{"query" => "school"}),
          tool_result("call_list_calendars", %{"calendars" => []})
        ])

      assert {arguments, "prepare_date_change"} = tool_call(body)

      assert Jason.decode!(arguments) == %{
               "dates" => next_prepared_dates(),
               "stop" => ["SCHOOL_EX", "SCHOOL_WD"],
               "run" => []
             }
    end

    test "a prepare_date_change result finishes with the prepared sentence" do
      assert final_text(post(prepared_conversation())) == @prepared_sentence
    end

    test "a departures question asks the seeded route's own first stop after 05:00" do
      body = post([user("What leaves the first stop after 5:00am?")])

      assert {arguments, "query_departures"} = tool_call(body)

      assert Jason.decode!(arguments) == %{
               "service_date" => tomorrow(),
               "stop_id" => "BSS_1",
               "stop_sequence" => 1,
               "after" => "05:00",
               "include_after_midnight" => false
             }
    end

    test "a boarding question asks the next service date's occurrences" do
      body = post([user("Which stops does this route board at?")])

      assert {arguments, "list_boarding_occurrences"} = tool_call(body)
      assert Jason.decode!(arguments) == %{"service_date" => tomorrow()}
    end

    test "a Schedule tool result finishes with the Schedule sentence" do
      messages = [
        user("What leaves the first stop after 5:00am?"),
        assistant_tool_call("call_query_departures", "query_departures", %{}),
        tool_result("call_query_departures", %{"departures" => []})
      ]

      assert final_text(post(messages)) ==
               "Three trips leave the first stop after 5:00am."
    end

    test "the Calendars script still answers a Calendars turn that names a route" do
      assert final_text(post([system(Calendars.skill()), user("Delete route 12")])) =~
               "That isn't available in Calendars"
    end
  end

  describe "scripted alerts replies" do
    test "a Route 12 request reads the draft first" do
      assert {"{}", "get_draft"} = tool_call(post([system(Alerts.skill()), user(@user_route_12)]))
    end

    test "the draft result searches for Route 12" do
      messages = [system(Alerts.skill())] ++ [user(@user_route_12)] ++ draft_call()

      assert {arguments, "search_routes"} = tool_call(post(messages))
      assert Jason.decode!(arguments) == %{"query" => "12"}
    end

    test "the search result prepares a now detour on the row the search returned" do
      body = post(alerts_conversation())

      assert {arguments, "propose_changes"} = tool_call(body)

      assert Jason.decode!(arguments) == %{
               "urgency" => "now",
               "situation" => "detour",
               "scope" => %{"shape" => "routes", "route_ids" => [@route_12_id]},
               "timing" => %{"start_date" => @today, "end_kind" => "estimated"}
             }
    end

    test "the prepared result finishes with a sentence that never claims a save" do
      messages =
        [system(Alerts.skill())] ++
          [user(@user_route_12)] ++
          draft_call() ++
          search_call()

      content = final_text(post(messages ++ propose_call()))

      assert content =~ @alerts_prepared_sentence
      refute content =~ ~r/saved|published|riders can see/i
    end

    test "a search that did not return Route 12 prepares nothing" do
      messages =
        [system(Alerts.skill())] ++
          [user(@user_route_12)] ++
          draft_call() ++
          [
            assistant_tool_call("call_search_routes", "search_routes", %{"query" => "12"}),
            tool_result("call_search_routes", %{
              "routes" => [%{"id" => "other", "route_id" => "1"}]
            })
          ]

      assert final_text(post(messages)) ==
               "I could not find Route 12 in this service version. Which route did you mean?"
    end

    test "a refused propose_changes result says nothing was prepared" do
      messages =
        [system(Alerts.skill())] ++
          [user(@user_route_12)] ++
          draft_call() ++
          search_call() ++
          [
            assistant_tool_call("call_propose_changes", "propose_changes", %{}),
            tool_result("call_propose_changes", %{"error" => "Unexpected argument: scope.nope"})
          ]

      assert final_text(post(messages)) ==
               "I could not prepare that change. Tell me which route and dates you mean."
    end

    test "any other alerts request gets the interview's first question" do
      content = final_text(post([system(Alerts.skill()), user("Hello")]))

      assert content =~ "affected right now, or on planned dates"
    end

    test "the alerts marker is the alerts skill's own heading" do
      assert Alerts.skill() =~ "Alerts helper"
      refute Calendars.skill() =~ "Alerts helper"
    end
  end

  describe "the production model client" do
    test "normalizes the scripted list_calendars reply" do
      stub_plug()

      assert {:ok, reply} = Model.complete([user(@user_school)], Calendars.tools())

      assert %{
               content: nil,
               finish_reason: "tool_calls",
               model: "test/model-a"
             } = reply

      assert reply.cost == 0.0

      assert [%{id: "call_list_calendars", name: "list_calendars", arguments: arguments}] =
               reply.tool_calls

      assert Jason.decode!(arguments) == %{"query" => "school"}
    end

    test "normalizes the scripted prepared-change reply" do
      stub_plug()

      assert {:ok, reply} = Model.complete(prepared_conversation(), Calendars.tools())

      assert %{
               content: @prepared_sentence,
               tool_calls: [],
               finish_reason: "stop",
               model: "test/model-a"
             } = reply

      assert reply.cost == 0.0
    end

    test "normalizes the scripted alerts propose_changes reply" do
      stub_plug()

      assert {:ok, reply} = Model.complete(alerts_conversation(), Alerts.tools())

      assert %{
               content: nil,
               finish_reason: "tool_calls",
               model: "test/model-a"
             } = reply

      assert [%{id: "call_propose_changes", name: "propose_changes", arguments: arguments}] =
               reply.tool_calls

      assert Jason.decode!(arguments) == %{
               "urgency" => "now",
               "situation" => "detour",
               "scope" => %{"shape" => "routes", "route_ids" => [@route_12_id]},
               "timing" => %{"start_date" => @today, "end_kind" => "estimated"}
             }
    end
  end

  test "the test environment routes the helper through the scripted plug only under BROWSER_E2E" do
    options = Application.get_env(:gtfs_planner, :agents_req_options)

    if System.get_env("BROWSER_E2E") == "true" do
      assert options == [plug: BrowserOpenRouter]
    else
      assert options == [plug: {Req.Test, GtfsPlanner.Agents.Model}, retry_delay: 0]
    end
  end

  defp post(messages) do
    body =
      Jason.encode!(%{
        "model" => "test/model-a",
        "messages" => messages,
        "tools" => []
      })

    conn =
      Plug.Test.conn(:post, "/api/v1/chat/completions", body)
      |> BrowserOpenRouter.call([])

    assert conn.status == 200
    assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers

    Jason.decode!(conn.resp_body)
  end

  # The plug answers the HTTP boundary the model client replaces only in browser
  # journeys, so these two cases run the shipped `Model.complete/2` with
  # `Req.Test` calling the plug instead of the HTTP adapter.
  defp stub_plug do
    Req.Test.stub(GtfsPlanner.Agents.Model, &BrowserOpenRouter.call(&1, []))
  end

  defp user(content), do: %{"role" => "user", "content" => content}

  defp tomorrow, do: Date.to_iso8601(Date.add(Date.utc_today(), 1))

  defp system(skill),
    do: %{
      "role" => "system",
      "content" =>
        skill <>
          "\n\nToday is #{@today}, Thursday, October 1, 2026 (America/Los_Angeles), in the agency's local time.\nService version: Browser Alerts Version.\nSection: Alert assistant."
    }

  # The messages the turn loop has sent by the time it answers the
  # prepare_date_change call: user request, list_calendars call and result, then
  # the prepare_date_change call and result.
  defp prepared_conversation do
    [
      user(@user_school),
      assistant_tool_call("call_list_calendars", "list_calendars", %{"query" => "school"}),
      tool_result("call_list_calendars", %{"calendars" => []}),
      assistant_tool_call("call_prepare_date_change", "prepare_date_change", %{
        "dates" => next_prepared_dates(),
        "stop" => ["SCHOOL_EX", "SCHOOL_WD"],
        "run" => []
      }),
      tool_result("call_prepare_date_change", %{"prepared" => true})
    ]
  end

  defp assistant_tool_call(id, name, arguments) do
    %{
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => [
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
        }
      ]
    }
  end

  defp tool_result(id, payload) do
    %{"role" => "tool", "tool_call_id" => id, "content" => Jason.encode!(payload)}
  end

  # The messages the alerts turn loop has sent by the time it answers each
  # call: the user's request, the get_draft call and its result, then the
  # search_routes call and its result.
  defp alerts_conversation do
    [system(Alerts.skill())] ++ [user(@user_route_12)] ++ draft_call() ++ search_call()
  end

  defp draft_call do
    [
      assistant_tool_call("call_get_draft", "get_draft", %{}),
      tool_result("call_get_draft", %{"revision" => 1, "urgency" => nil, "situation" => nil})
    ]
  end

  defp search_call do
    [
      assistant_tool_call("call_search_routes", "search_routes", %{"query" => "12"}),
      tool_result("call_search_routes", %{
        "routes" => [
          %{
            "id" => @route_12_id,
            "label" => "Route 12",
            "route_id" => "12",
            "short_name" => "Route 12",
            "long_name" => "Nye Beach – Hospital"
          }
        ]
      })
    ]
  end

  defp propose_call do
    [
      assistant_tool_call("call_propose_changes", "propose_changes", %{
        "urgency" => "now",
        "situation" => "detour",
        "scope" => %{"shape" => "routes", "route_ids" => [@route_12_id]},
        "timing" => %{"start_date" => @today, "end_kind" => "estimated"}
      }),
      tool_result("call_propose_changes", %{"status" => "prepared"})
    ]
  end

  defp tool_call(%{"choices" => [%{"finish_reason" => "tool_calls", "message" => message}]}) do
    assert [call] = message["tool_calls"]

    assert %{"type" => "function", "function" => %{"name" => name, "arguments" => arguments}} =
             call

    {arguments, name}
  end

  defp final_text(%{"choices" => [%{"finish_reason" => "stop", "message" => message}]}) do
    assert Map.get(message, "tool_calls") in [nil, []]
    message["content"]
  end

  # The next Monday strictly after today and the day after it, found by stepping
  # forward from tomorrow so the expectation does not repeat the plug's
  # arithmetic. Day 1 is Monday. The seed's Monday-Friday calendars run on both
  # dates.
  defp next_prepared_dates do
    monday = Date.utc_today() |> Date.add(1) |> find_day(1)
    [Date.to_iso8601(monday), Date.to_iso8601(Date.add(monday, 1))]
  end

  defp find_day(date, day_of_week) do
    if Date.day_of_week(date) == day_of_week do
      date
    else
      date |> Date.add(1) |> find_day(day_of_week)
    end
  end
end

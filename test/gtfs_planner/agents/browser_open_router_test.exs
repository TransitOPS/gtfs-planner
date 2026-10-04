defmodule GtfsPlanner.Agents.BrowserOpenRouterTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Agents.BrowserOpenRouter
  alias GtfsPlanner.Agents.Model
  alias GtfsPlanner.Agents.Packs.Alerts
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Packs.FarePrices
  alias GtfsPlanner.Agents.Packs.FareZones
  alias GtfsPlanner.Agents.Packs.Headsigns
  alias GtfsPlanner.Agents.Packs.ReleaseComparison
  alias GtfsPlanner.Agents.Packs.StopImpact
  alias GtfsPlanner.Agents.Packs.StopText

  @user_school "No school service next Monday and Tuesday"
  @prepared_sentence "I prepared the change. Review it before applying."
  @generic_sentence "I can answer questions about calendars and prepare date changes."
  @alerts_prepared_sentence "I prepared a detour on Route 12."
  @user_route_12 "Route 12 is detouring between Elm and 3rd"
  @route_12_id "11111111-2222-3333-4444-555555555555"
  @today "2026-10-01"
  @loss_question "Did we lose any service between these two files?"
  @total_question "What is the total change in departures?"

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

  describe "scripted release comparison replies" do
    test "the comparison marker is the pack's own heading" do
      assert ReleaseComparison.skill() =~ "Comparison helper"
      refute Calendars.skill() =~ "Comparison helper"
      refute Alerts.skill() =~ "Comparison helper"
    end

    test "a loss question reads the summary, then the differences" do
      messages = comparison(@loss_question)

      assert {"{}", "get_export_comparison"} = tool_call(post(messages))

      messages = messages ++ summary_call("incomplete")
      assert {"{}", "inspect_service_difference"} = tool_call(post(messages))
    end

    test "the differences are stated as one loss and one rename that is not a loss" do
      messages =
        comparison(@loss_question) ++
          summary_call("incomplete") ++
          [
            assistant_tool_call(
              "call_inspect_service_difference",
              "inspect_service_difference",
              %{}
            ),
            tool_result("call_inspect_service_difference", %{
              "records" => [
                %{
                  "type" => "effective",
                  "kind" => "count_changed",
                  "date" => "2026-11-26",
                  "route_ids" => %{"left" => "R1", "right" => "R1"},
                  "counts" => %{
                    "left" => %{"scheduled_count" => 2},
                    "right" => %{"scheduled_count" => 1}
                  }
                },
                %{
                  "type" => "structural",
                  "entity" => "route",
                  "change" => "identifier",
                  "left" => "R2",
                  "right" => "R2X"
                }
              ]
            })
          ]

      assert final_text(post(messages)) ==
               "R1 lost 1 trip on Thu Nov 26, 2026, from 2 to 1. " <>
                 "R2 was only renamed R2X: same service under a new identifier, so that is not a loss. " <>
                 "The comparison is incomplete, so this is not a clean answer."
    end

    test "a total that was not measured is never given as a number" do
      messages =
        comparison(@total_question) ++
          summary_call("incomplete", %{
            "exact_count_delta" => nil,
            "reasons" => ["incomplete_counts"]
          })

      assert final_text(post(messages)) ==
               "I can't give a total change in departures: it was not measured. " <>
                 "A route states frequency windows rather than exact departures."
    end

    test "a no-difference sentence needs a complete comparison with no changes" do
      question = "Did anything change between these files?"

      complete = comparison(question) ++ summary_call("complete", %{}, 0, 0)
      incomplete = comparison(question) ++ summary_call("incomplete", %{}, 0, 0)

      assert final_text(post(complete)) ==
               "Nothing changed in service, and the comparison is complete."

      assert final_text(post(incomplete)) ==
               "The comparison is incomplete, so I can't say nothing changed."
    end

    test "an unresolved question reads the unresolved matches" do
      assert {"{}", "inspect_unresolved_entity_matches"} =
               tool_call(post(comparison("Which stops could not be matched?")))
    end

    test "a provider question is a real 401" do
      body = Jason.encode!(%{"messages" => comparison("Is the provider reachable?")})

      conn =
        Plug.Test.conn(:post, "/api/v1/chat/completions", body)
        |> BrowserOpenRouter.call([])

      assert conn.status == 401
    end
  end

  describe "scripted headsign replies" do
    test "a headsign request summarizes the headsigns first" do
      body = post([system(Headsigns.skill()), user("Rename the Lincoln City headsign")])

      assert {"{}", "summarize_headsigns"} = tool_call(body)
    end

    test "the summary prepares the Lincoln City rename with no exclusions" do
      body = post(headsign_conversation() ++ headsign_summary())

      assert {arguments, "prepare_headsign_change"} = tool_call(body)

      assert Jason.decode!(arguments) == %{
               "current_text" => "Lincoln City",
               "new_text" => "Central Station"
             }
    end

    test "the prepared result says prepared and never saved" do
      messages =
        headsign_conversation() ++
          headsign_summary() ++
          [
            assistant_tool_call("call_prepare_headsign_change", "prepare_headsign_change", %{}),
            tool_result("call_prepare_headsign_change", %{"prepared" => true})
          ]

      content = final_text(post(messages))

      assert content =~ "I prepared the rename"
      refute content =~ ~r/saved|changed|done/i
    end

    test "a refused rename says nothing was prepared" do
      messages =
        headsign_conversation() ++
          headsign_summary() ++
          [
            assistant_tool_call("call_prepare_headsign_change", "prepare_headsign_change", %{}),
            tool_result("call_prepare_headsign_change", %{
              "error" => "current_text is not this page's current default."
            })
          ]

      assert final_text(post(messages)) =~ "I could not prepare that rename"
    end

    test "the headsign marker is the headsigns skill's own heading" do
      assert Headsigns.skill() =~ "Headsign helper"
      refute Calendars.skill() =~ "Headsign helper"
    end
  end

  describe "scripted stop text replies" do
    @stop_request "Prepare stop changes: S410 stop_name=Txt Elm @ 3rd; S410 stop_code=E-2; S411 stop_name=Txt Pine"

    test "a stop change request reads the approved list first" do
      body = post([system(StopText.skill()), user(@stop_request)])

      assert {"{}", "read_stop_set"} = tool_call(body)
    end

    test "the list prepares the rows the message named, one per stop in order" do
      body = post(stop_text_conversation())

      assert {arguments, "prepare_stop_metadata_changes"} = tool_call(body)

      assert Jason.decode!(arguments) == %{
               "rows" => [
                 %{"stop_id" => "S410", "stop_name" => "Txt Elm @ 3rd", "stop_code" => "E-2"},
                 %{"stop_id" => "S411", "stop_name" => "Txt Pine"}
               ],
               "basis" => @stop_request
             }
    end

    test "the prepared result says prepared and never saved; a refusal says nothing was prepared" do
      call = assistant_tool_call("call_prepare", "prepare_stop_metadata_changes", %{})

      prepared =
        final_text(
          post(
            stop_text_conversation() ++ [call, tool_result("call_prepare", %{"prepared" => true})]
          )
        )

      assert prepared =~ "I prepared the stop changes"
      refute prepared =~ ~r/saved|changed|done/i

      refused =
        final_text(
          post(
            stop_text_conversation() ++ [call, tool_result("call_prepare", %{"error" => "no"})]
          )
        )

      assert refused =~ "I could not prepare those changes"
    end

    test "any other message gets the generic sentence and the marker is the skill's heading" do
      assert final_text(post([system(StopText.skill()), user("Hello")])) =~
               "I can help with the stops you approved"

      assert StopText.skill() =~ "Stop text helper"
      refute Calendars.skill() =~ "Stop text helper"
    end
  end

  describe "scripted stop impact replies" do
    test "a question reads the dependencies, then previews the pin" do
      question = [system(StopImpact.skill()), user("What would moving this stop affect?")]

      assert {"{}", "get_stop_dependencies"} = tool_call(post(question))

      read = [
        assistant_tool_call("call_dependencies", "get_stop_dependencies", %{}),
        tool_result("call_dependencies", %{"count" => 1})
      ]

      assert {"{}", "preview_stop_move"} = tool_call(post(question ++ read))

      previewed = [
        assistant_tool_call("call_preview", "preview_stop_move", %{}),
        tool_result("call_preview", %{
          "distance_m" => 13.7,
          "band" => "review",
          "patterns" => [%{"label" => "Route 1 toward Lincoln City", "weekday_trips" => 12}],
          "transfers" => [%{"label" => "Bay B", "before_m" => 40.0, "after_m" => 52.5}],
          "relief_points" => ["Relief point R1"],
          "unchecked" => ["The street path is decided by the native move review, not here."]
        })
      ]

      sentence = final_text(post(question ++ read ++ previewed))

      assert sentence ==
               "Moving this stop 13.7 m is a review move. " <>
                 "Patterns: Route 1 toward Lincoln City (12 weekday trips). " <>
                 "Transfers: Bay B 40.0 m before and 52.5 m after. " <>
                 "Relief points: Relief point R1. " <>
                 "The street path is decided by the native move review, not here."

      refused =
        final_text(
          post(
            question ++
              read ++
              [
                assistant_tool_call("call_preview", "preview_stop_move", %{}),
                tool_result("call_preview", %{"error" => "No pin is placed."})
              ]
          )
        )

      assert refused =~ "I could not read the move"
    end

    test "only an explicit request prepares the move; the result says prepared, never saved" do
      request = [system(StopImpact.skill()), user("Keep the stop's ID and prepare the move.")]

      assert {"{}", "prepare_stop_move"} = tool_call(post(request))

      call = assistant_tool_call("call_prepare", "prepare_stop_move", %{})

      prepared =
        final_text(post(request ++ [call, tool_result("call_prepare", %{"pointer" => true})]))

      assert prepared =~ "I prepared the move"
      refute prepared =~ ~r/saved|changed|done/i

      refused =
        final_text(post(request ++ [call, tool_result("call_prepare", %{"error" => "no pin"})]))

      assert refused =~ "I could not prepare that move"
    end

    test "the marker is the skill's own heading" do
      assert StopImpact.skill() =~ "Stop impact helper"
      refute Calendars.skill() =~ "Stop impact helper"
    end
  end

  describe "scripted fare zone replies" do
    @user_zone "Put unzoned Route 1 stops in the Coast zone except Newport Transit Center"
    @zone_selection %{"route_ids" => ["1"], "only_unzoned" => true, "exclude_stop_ids" => ["NTC"]}

    test "the unzoned Route 1 request asks for the scripted selection" do
      body = post([system(FareZones.skill()), user(@user_zone)])

      assert {arguments, "query_zone_targets"} = tool_call(body)
      assert Jason.decode!(arguments) == @zone_selection
    end

    test "the query result prepares the same selection for zone CST" do
      body = post(zone_conversation(["query_zone_targets"]))

      assert {arguments, "prepare_zone_assignment"} = tool_call(body)
      assert Jason.decode!(arguments) == Map.put(@zone_selection, "zone_id", "CST")
    end

    test "the prepare result gets the prepared sentence, and a refusal says nothing was prepared" do
      prepared =
        final_text(post(zone_conversation(["query_zone_targets", "prepare_zone_assignment"])))

      assert prepared =~ "I prepared the zone assignment."
      refute prepared =~ ~r/was saved|I saved/

      refused =
        zone_conversation(["query_zone_targets", "prepare_zone_assignment"])
        |> List.replace_at(
          -1,
          tool_result("call_prepare_zone_assignment", %{"error" => "No stops match."})
        )
        |> post()
        |> final_text()

      assert refused =~ "I could not prepare that assignment."
    end

    test "a Beach request searches for Beach and then asks which stop" do
      messages = [system(FareZones.skill()), user("Which zone is Beach in?")]

      assert {arguments, "find_stops"} = tool_call(post(messages))
      assert Jason.decode!(arguments) == %{"query" => "Beach"}

      answered =
        messages ++
          [
            assistant_tool_call("call_find_stops", "find_stops", %{"query" => "Beach"}),
            tool_result("call_find_stops", %{"stops" => [], "total" => 2})
          ]

      assert final_text(post(answered)) =~ "Which one do you mean?"
    end

    test "other fare zone messages get the helper's sentence and other scripts are unchanged" do
      assert final_text(post([system(FareZones.skill()), user("Hello")])) =~
               "I can find stops by route"

      # The same words under the Calendars skill still get its out-of-scope sentence.
      assert final_text(post([system(Calendars.skill()), user(@user_zone)])) =~
               "That isn't available in Calendars"
    end

    test "the fare zone marker is the pack's own heading" do
      assert FareZones.skill() =~ "# Fare zone helper"
      refute Alerts.skill() =~ "Fare zone helper"
      refute Calendars.skill() =~ "Fare zone helper"
    end
  end

  describe "scripted fare price replies" do
    @user_price "Raise the Local ride adult and reduced cash prices to 1.75 and 0.85"
    @price_changes %{
      "currency" => "USD",
      "changes" => [
        %{
          "fare_product_id" => "local_ride_adult_cash",
          "rider_category_id" => "adult",
          "fare_media_id" => "cash",
          "amount" => "1.75"
        },
        %{
          "fare_product_id" => "local_ride_reduced_cash",
          "rider_category_id" => "reduced",
          "fare_media_id" => "cash",
          "amount" => "0.85"
        }
      ]
    }

    test "a Local ride request reads the cells first" do
      body = post([system(FarePrices.skill()), user(@user_price)])

      assert {arguments, "list_price_cells"} = tool_call(body)
      assert Jason.decode!(arguments) == %{"search" => "Local ride"}
    end

    test "the cells result prepares the two exact changes" do
      body = post(price_conversation(["list_price_cells"]))

      assert {arguments, "prepare_price_changes"} = tool_call(body)
      assert Jason.decode!(arguments) == @price_changes
    end

    test "the prepare result gets the prepared sentence, and a refusal says nothing was prepared" do
      prepared =
        final_text(post(price_conversation(["list_price_cells", "prepare_price_changes"])))

      assert prepared == "I prepared 2 price changes. Review them before saving."

      refused =
        price_conversation(["list_price_cells", "prepare_price_changes"])
        |> List.replace_at(
          -1,
          tool_result("call_prepare_price_changes", %{
            "error" => "Every price already equals the amount you gave."
          })
        )
        |> post()
        |> final_text()

      assert refused =~ "I could not prepare those prices."
    end

    test "a percentage asks for exact amounts and calls no tool, other messages are generic" do
      percent = post([system(FarePrices.skill()), user("Raise Local ride prices by 10%")])

      assert final_text(percent) =~ "exact amounts"

      assert final_text(post([system(FarePrices.skill()), user("Hello")])) =~
               "I can list this version's fare prices"
    end

    test "the price marker is the pack's own heading and the other scripts are unchanged" do
      assert FarePrices.skill() =~ "# Fare price helper"
      refute FareZones.skill() =~ "Fare price helper"
      refute Calendars.skill() =~ "Fare price helper"
      refute Alerts.skill() =~ "Fare price helper"

      assert {_arguments, "query_zone_targets"} =
               post([system(FareZones.skill()), user(@user_zone)]) |> tool_call()

      # The same words under the Calendars skill still get its own generic sentence.
      assert final_text(post([system(Calendars.skill()), user(@user_price)])) == @generic_sentence
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

  defp comparison(question) do
    [
      %{
        "role" => "system",
        "content" => ReleaseComparison.skill() <> "\n\nSection: #{ReleaseComparison.title()}."
      },
      user(question)
    ]
  end

  # The summary tool's call and result, as the turn loop sends them back.
  defp summary_call(status, totals \\ %{}, effective \\ 1, structural \\ 2) do
    result = %{
      "totals" => Map.merge(%{"exact_count_delta" => -1, "reasons" => []}, totals),
      "completeness" => %{"status" => status, "reasons" => []},
      "counts" => %{
        "effective_changes" => %{"total" => effective},
        "structural_changes" => %{"total" => structural}
      }
    }

    [
      assistant_tool_call("call_get_export_comparison", "get_export_comparison", %{}),
      tool_result("call_get_export_comparison", result)
    ]
  end

  # The messages the fare zone turn loop has sent after each answered tool.
  defp zone_conversation(answered_tools) do
    selection = %{"route_ids" => ["1"], "only_unzoned" => true, "exclude_stop_ids" => ["NTC"]}

    calls =
      Enum.flat_map(answered_tools, fn name ->
        arguments =
          if name == "query_zone_targets",
            do: selection,
            else: Map.put(selection, "zone_id", "CST")

        [
          assistant_tool_call("call_#{name}", name, arguments),
          tool_result("call_#{name}", %{"selected_count" => 2})
        ]
      end)

    [system(FareZones.skill()), user(@user_zone)] ++ calls
  end

  defp price_conversation(answered_tools) do
    changes = %{
      "currency" => "USD",
      "changes" => [
        %{
          "fare_product_id" => "local_ride_adult_cash",
          "rider_category_id" => "adult",
          "fare_media_id" => "cash",
          "amount" => "1.75"
        }
      ]
    }

    calls =
      Enum.flat_map(answered_tools, fn name ->
        arguments = if name == "list_price_cells", do: %{"search" => "Local ride"}, else: changes

        [
          assistant_tool_call("call_#{name}", name, arguments),
          tool_result("call_#{name}", %{"currency" => "USD"})
        ]
      end)

    [system(FarePrices.skill()), user(@user_price)] ++ calls
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
  defp headsign_conversation,
    do: [system(Headsigns.skill()), user("Rename the Lincoln City headsign")]

  defp headsign_summary do
    [
      assistant_tool_call("call_summarize_headsigns", "summarize_headsigns", %{}),
      tool_result("call_summarize_headsigns", %{"default" => "Lincoln City"})
    ]
  end

  defp stop_text_conversation do
    [
      system(StopText.skill()),
      user(@stop_request),
      assistant_tool_call("call_read_stop_set", "read_stop_set", %{}),
      tool_result("call_read_stop_set", %{"total" => 2})
    ]
  end

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

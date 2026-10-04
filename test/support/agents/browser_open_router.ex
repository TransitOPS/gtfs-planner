defmodule GtfsPlanner.Agents.BrowserOpenRouter do
  @moduledoc """
  Test-only OpenRouter stand-in for the helper browser journeys.

  `config/test.exs` selects it only while `BROWSER_E2E` is `true`, because a
  Playwright journey drives the helper in a real browser, where no `Req.Test`
  stub exists. Ordinary ExUnit runs keep `{Req.Test, GtfsPlanner.Agents.Model}`,
  so every test-env request still carries `:agents_req_options` and none can
  reach the provider (INV-5).

  It answers one deterministic scripted reply per request, choosing on the last
  message the turn loop sent and replying in OpenRouter's chat-completions
  shape. Which script runs is read from the turn's own system message, so one
  stand-in serves every pack the browser journeys drive.

  The Calendars script is the Calendars skill's school-break example plus the A02
  and A19 service-answer questions of the `Browser Service Answers Version`
  (`test/support/browser_seed.exs`):

    * a `"user"` message mentioning a route gets the Calendars skill's
      out-of-scope sentence;
    * a `"user"` message mentioning school gets a `list_calendars` call with
      `query: "school"`;
    * a `"user"` message asking about dates gets a `get_calendar` call for the
      next Monday through Sunday of the seeded `SCHOOL_WD` calendar;    * the `list_calendars` tool result gets a `prepare_date_change` call that
      stops `SCHOOL_EX` and `SCHOOL_WD` on the next Monday and Tuesday after
      `Date.utc_today()`; the seeded `Browser Helper Version`
      (`test/support/browser_seed.exs`) resolves the same UTC date, so both
      dates are real service dates;
    * the `prepare_date_change` tool result gets the prepared-change sentence;
    * the `get_calendar` tool result gets a sentence that contradicts the
      server's own count on purpose, so the browser journey proves the card and
      not the prose is the answer;
    * a `"user"` message asking about departures gets a `query_departures` call
      for the route's own first stop after 05:00 on the next date the seeded
      `CAL_DAILY` calendar runs, so the Schedule journey reads a real page's own
      trip; a message about the seeded holiday instead asks for Central Station
      occurrence 2 after 18:00 on the shared A02 date;
    * a `"user"` message about which dates keep service gets a
      `summarize_calendar_coverage` call for `REGULAR`, H8 and H12 on the two
      shared A19 dates; a message asking for two months of dates is refused by
      the dispatch fence before the pack sees it;
    * a `"user"` message asking which visit at a stop, naming a calendar the
      version does not have, or naming more dates than one answer covers gets a
      call the domain refuses, so the browser journey shows the refusal and the
      next action it names;
    * a `"user"` message asking to extend a calendar gets a
      `prepare_calendar_extension` call for the same end date the journey
      approves in *Approve a calendar extension*, so the tool reads the
      editor's approval instead of one the model supplied; a message about the
      service-answer feed asks for that version's `WEEKDAY` calendar and every
      other message keeps the seeded `SCHOOL_WD` calendar;
    * a `"user"` message about this Flex service's hours, booking rules or
      policy source gets the `flex_policy` pack's `get_flex_policy_context`
      call, and that result gets the `prepare_flex_policy` call the journey
      approves: the complete weekday/Saturday hours array of the seeded
      `Browser Flex Version` `Newport Dial-a-Ride` service
      (`test/support/browser_seed.exs`) with the weekday window moved to
      08:00-17:00; an ask for same-day service when the dispatcher agrees
      sends the complete hours array with that statement in `unsupported`
      under `all_supported`, and an ask for a business-day rule sends an
      `office_service_id` the version does not hold, so the real
      `GtfsPlanner.Gtfs.Flex.Assistant` refuses both. A prepared result gets a
      review sentence; a refused one gets the assistant's own refusal reason
      verbatim, so what the browser shows is the server's reason and not this
      stand-in's wording;
    * a `"user"` message asking whether the provider is reachable gets a 401, so
      the panel's failed entry, its Retry control and the failure text render
      from a real provider failure rather than from a scripted turn;
    * a `"user"` message naming a timetable row (`Prepare inbound row 2 …`)
      gets the Timetables pack's own sequence: `read_timetable_source`, then
      `inspect_timetable_scope`, then a `prepare_timetable_input` for the rows
      the message named against the seeded `BROWSER_PASTE` route's own calendar,
      direction and pattern, and finally the prepared-batch sentence. A message
      may name a second calendar (`… for calendar CAL_SCHOOL`), which the pack
      refuses because the route does not run it. The selectors are the seeded
      route's own, so the batch can only be prepared from what the Paste page
      already accepted;
    * the `query_departures` and `list_boarding_occurrences` tool results get a
      Schedule sentence, one of which contradicts the server's count on purpose;
    * the `read_timetable_source`, `inspect_timetable_scope` and
      `prepare_timetable_input` tool results get the next Timetables call or
      the prepared-batch sentence;
    * the `prepare_calendar_extension` tool result gets the prepared-extension
      sentence;
    * a `"user"` message asking about a connection between two of the seeded
      transfer stops gets a `prepare_transfer_policy` call for the selection the
      Transfers page admitted, so the tool prepares from the page's own draft; a
      message asking to check one direction first gets an
      `inspect_transfer_competition` call for the same selection, and its result
      gets the prepared-change sentence with no write;
    * a `"user"` message asking what is wrong with this day's blocks or runs
      gets an operations tool call carrying **no** `day_ref`. The ref is an
      opaque server digest a model cannot type, and leaving it out is what the
      two packs now accept, so the journey proves a real model can reach the
      first call rather than reading the ref out of the snapshot the way the
      ExUnit cases do;
    * a `"user"` message naming a day that disagrees with the attached one gets
      an operations call carrying a foreign `day_ref`, so the journey shows the
      anti-forgery refusal is unchanged for a ref that IS supplied;
    * a `"user"` message asking to prepare or fix the day gets a
      `prepare_block_suggestion` or `prepare_run_suggestion` call, so the
      journey can show the prepared card and the native drawer handoff;
    * the `get_blocking_issues`, `get_run_issues` and `get_crew_rules` tool
      results get the findings sentence, which quotes only codes the tool
      returned;
    * the `prepare_block_suggestion` and `prepare_run_suggestion` tool results
      get the prepared-sentence the panel follows with a native drawer;
    * a `"user"` message about station widths gets a
      `prepare_station_import_decisions` call for the three seeded
      `BROWSER_PW_ELEVATOR`, `BROWSER_PW_SAME_LEVEL` and `BROWSER_PW_CROSS_LEVEL`
      decisions of the import review the import page computed, so the station
      journey reviews a real prepared selection beside the rows the review
      leaves unresolved;
    * the `prepare_station_import_decisions` tool result gets the
      prepared-measurement sentence;
    * a `"user"` message asking what the recorded check found gets a
      `get_station_result` call; one asking which pairs it recorded gets a
      `list_station_result_pairs` call; one asking what is true of the station
      today gets a `get_station_report_facts` call. All three take their station
      and check from the page's own context, so the stand-in names no ids;
    * each of those three tool results gets its own fixed sentence;
    * anything else gets the helper's generic sentence.

  The in-seat script is the Blocks page's own worked example, and it is the one the
  in-seat journey drives:

    * a `"user"` message asking whether a connection may hold gets the pack's own
      argument-free `inspect_in_seat_connections` call, so the answer is the
      source's rather than a scripted one;
    * any other `"user"` message gets a `prepare_in_seat_policy` call whose
      `choice` is the person's own wording — `"must reboard"` prepares
      `must_reboard` and anything else prepares `stay_on_board` — so the tool can
      only ever prepare the setting the journey actually asked for;
    * either tool result gets the prepared-change sentence, which says
      "prepared" and never "saved".

  The Alerts script is the alerts skill's Route 12 worked example, and it is
  the one the editor's journey drives:

    * a `"user"` message mentioning Route 12 gets a `get_draft` call, which is
      the skill's "call `get_draft` first" rule;
    * the `get_draft` result gets `search_routes` with `query: "12"`;
    * the `search_routes` result gets `propose_changes` carrying the row id the
      result itself returned for Route 12, a `now` urgency, a `detour`
      situation and an `estimated` end. The identity is read out of the tool
      result rather than invented, so a search that found nothing prepares
      nothing and says so;
    * the `propose_changes` result gets the prepared sentence, which says
      "prepared" and never "saved" or "published", unless the result is a tool
      error, which gets a sentence that says nothing was prepared;
    * any other `"user"` message gets the interview's first question, and any
      other tool result gets the alerts generic sentence.

  The date in the prepared timing is the agency-local date the turn's own
  system message states, read out of that message rather than from a clock.

  The Release comparison script answers the Export page's helper from what the
  tools returned, never from a fixed sentence about the seeded files, so a card
  that drifted from the comparison fails the journey instead of agreeing with a
  script:

    * a `"user"` message asking whether service was lost gets a
      `get_export_comparison` call, then `inspect_service_difference`, and the
      sentence states each effective loss and each renamed route the result
      returned, saying a rename is not a loss;
    * a message asking for the total change in departures gets
      `get_export_comparison` and either the measured delta or the reasons the
      total was not measured;
    * a message asking whether anything changed gets `get_export_comparison` and
      a no-difference sentence only for a complete comparison with no changes;
    * a message asking about unresolved or alike stops gets
      `inspect_unresolved_entity_matches`;
    * a message asking what was compared gets
      `resolve_export_comparison_scope`;
    * a message asking whether the provider is reachable gets a 401, so the
      panel's failed entry and Retry control render from a real provider failure.
  """

  @behaviour Plug

  alias GtfsPlanner.Agents.BrowserFeedQuality
  alias GtfsPlanner.Agents.BrowserServiceAnswers

  @model "test/model-a"

  # Kept identical to the Calendars skill's out-of-scope answer
  # (priv/agents/packs/calendars/SKILL.md, "Anything outside calendars gets this
  # answer, unchanged"); the plug test asserts this reply appears verbatim in
  # Packs.Calendars.skill/0, so the two cannot drift apart silently.
  @out_of_scope "That isn't available in Calendars. I can answer questions about calendars and prepare service date changes. To ask for a new ability, contact the TransitOPS team."
  @generic "I can answer questions about calendars and prepare date changes."
  @prepared "I prepared the change. Review it before applying."
  # Deliberately wrong: the seeded School weekdays calendar runs five of the
  # seven dates the stand-in asks about, so the card and this sentence disagree
  # and the journey can show which one the panel treats as the answer.
  @contradicted_count "Three of those dates run service."
  @schedule_departures "Three trips leave the first stop after 5:00am."
  @schedule_occurrences "This route boards at three stops."
  # Deliberately wrong about the seeded holiday: H8 has two listed departures
  # after 18:00 at Central Station, so the card and this sentence disagree and
  # the journey can show which one the panel treats as the answer.
  @holiday_departures "Five trips leave Central Station after 6:00pm."
  # Agrees with the seeded coverage: H8's standard calendar has ended on both
  # dates, and H12 keeps Sunday service through its own calendar.
  @coverage_answer "H8 has no service on either date. H12 keeps Sunday service through SCHOOL."
  @too_many_dates "Ask about fewer dates at a time."
  # Kept identical to the Flex policy skill's out-of-scope answer
  # (priv/agents/packs/flex_policy/SKILL.md, "Anything outside this service's
  # hours and booking rules gets this answer, unchanged").
  @flex_prepared "I moved the weekday hours. Review the comparison on the service page; nothing is saved until you press Save changes there."
  @unknown_calendar "No calendar with service_id RETIRED in this service version."
  # The domain refused the call because the seeded loop visits Central Station
  # twice, so the follow-up names the next action instead of answering anyway.
  @ambiguous_visit "I did not answer, because Central Station is visited more than once on that date. Ask which visit you mean."
  @prepared_extension "I prepared the extension. Review it before applying."
  @prepared_timetable "I prepared the batch. Review it before applying."

  # The seeded `BROWSER_PASTE` route (test/support/browser_seed.exs): the
  # Weekday calendar plus its outbound and inbound main patterns. The stand-in
  # names only what the Paste page already resolved, because the pack compares
  # every selector with the route's own loaded scope and the reviewed source.
  @timetable_service_id "BPS_WKDY"
  @timetable_pattern_id "BPS-MAIN"
  @timetable_direction_id 0
  @timetable_inbound_pattern_id "BPS-INBOUND"
  @timetable_inbound_direction_id 1
  @timetable_row ~r/prepare (inbound |outbound )?row (\d+)(?: for calendar ([A-Z0-9_]+))?/i
  @timetable_tools ~w(read_timetable_source inspect_timetable_scope prepare_timetable_input)
  @feed_quality_tools ~w(list_validation_findings explain_notice prepare_export_options)

  @prepared_transfer "I prepared the transfer rule. Review it before applying."
  @compared_connections "I compared the connections you approved with the minimum you supplied. The margins beside this reply are this version's own numbers."
  # The station journey's own sentence. It claims nothing was applied: the
  # journey confirms the statuses and then applies them itself.
  @prepared_measurement "I prepared the width decisions those measurements support. Review them before applying."
  # The three decisions the import page's computed review holds for the seeded
  # elevator, same-level and cross-level pathways. The journey captures an
  # accepted measurement for the first and a disputed one for the second, and
  # changes two fields on the third, so one row prepares and two stay unresolved
  # for the reasons the domain gives.
  @station_width_decisions [
    "pathway:BROWSER_PW_ELEVATOR",
    "pathway:BROWSER_PW_SAME_LEVEL",
    "pathway:BROWSER_PW_CROSS_LEVEL"
  ]
  @recorded_result "That is what the recorded check stored. The server evidence beside it is the answer."
  @recorded_pairs "Those are the recorded pairs. The card lists them; the list may be a bounded page."
  @current_facts "Those are the station's current report facts, captured now. They are not an explanation of the recorded check."
  # The end date the browser journey approves in the Calendars page's own form,
  # 200 days from today: inside the 366-day horizon, and later than the seeded
  # calendar's own end date, so the tool can only prepare it from that approval.
  @extension_days 200

  # The alerts skill's own heading, and the sentences the alerts script answers
  # with. The question is the skill's first interview step, the prepared
  # sentence keeps to the skill's "say I prepared, never saved or published"
  # rule, and the not-found sentence is what the skill asks for when a search
  # did not return what the person meant.
  @in_seat_marker "the selected in-seat connections"
  @prepared_in_seat "I prepared the in-seat setting. Review it before applying."

  @alerts_marker "Alerts helper"
  @alerts_question "Now or planned: are riders affected right now, or on planned dates?"
  @alerts_prepared "I prepared a detour on Route 12. The answers are filled in on the form. Check the preview."
  @alerts_not_prepared "I could not prepare that change. Tell me which route and dates you mean."
  @alerts_not_found "I could not find Route 12 in this service version. Which route did you mean?"
  @alerts_generic "I can read this alert's routes, stops and departures and prepare answers for you to review."

  # The operations branches. The seeded in-seat day carries `overlap` and
  # `in_seat_stale` findings, so these sentences name only codes the tools
  # actually returned rather than counts the stand-in invented.
  @block_findings "This day has overlap errors and stale in-seat warnings. Read the card for the per-block detail."
  @run_findings "This day has run issues and uncovered work. Read the card for the per-run detail."
  @crew_rules "This day carries the stored crew rules, the pull-out, relief and sign-off reports and the break and spread limits."
  @operations_prepared "I prepared a change from what the card showed. Review it before applying."
  @operations_answers %{
    "get_blocking_issues" => @block_findings,
    "get_run_issues" => @run_findings,
    "get_crew_rules" => @crew_rules,
    "prepare_block_suggestion" => @operations_prepared,
    "prepare_run_suggestion" => @operations_prepared
  }
  @operations_tools Map.keys(@operations_answers)

  # A ref shaped like the server's own, so the pack's fence is what refuses it
  # and not the stand-in declining to invent a value.
  @foreign_day_ref "day_ffffffffffffffffffffffffffffffff"

  # The Release comparison skill's own heading, which the turn's system message
  # carries, and the sentence for a request the script does not know.
  @comparison_marker "Comparison helper"
  @comparison_generic "I can explain the comparison shown on this page."

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"messages" => messages} = Jason.decode!(body)

    case reply(messages) do
      {:status, status, body} ->
        Req.Test.json(%{conn | status: status}, body)

      body ->
        Req.Test.json(conn, body)
    end
  end

  defp reply(messages) do
    cond do
      in_seat?(messages) -> in_seat_reply(messages)
      alerts?(messages) -> alerts_reply(messages)
      comparison?(messages) -> comparison_reply(messages)
      true -> calendars_reply(messages)
    end
  end

  defp comparison?(messages), do: Enum.any?(messages, &system_contains?(&1, @comparison_marker))

  defp system_contains?(%{"role" => "system", "content" => content}, marker)
       when is_binary(content),
       do: String.contains?(content, marker)

  defp system_contains?(_message, _marker), do: false

  # The turn's system message is the pack's own skill body, so the script is
  # chosen from what the turn says it can do rather than from the tools it
  # carries, and a pack this stand-in does not script falls through to the
  # Calendars script exactly as it did before the alerts one existed.
  defp alerts?(messages) do
    Enum.any?(messages, fn
      %{"role" => "system", "content" => content} when is_binary(content) ->
        String.contains?(content, @alerts_marker)

      _other ->
        false
    end)
  end

  # The Blocks page's in-seat pack, whose skill body names the selection this
  # script prepares. Its tools carry no pair, no block and no date, so the
  # scripted call can only ever act on the source the page admitted.
  defp in_seat?(messages) do
    Enum.any?(messages, fn
      %{"role" => "system", "content" => content} when is_binary(content) ->
        String.contains?(content, @in_seat_marker)

      _other ->
        false
    end)
  end

  defp in_seat_reply(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) ->
        if content =~ ~r/hold|may|eligible|can riders|check/i do
          tool_calls_reply("inspect_in_seat_connections", %{})
        else
          tool_calls_reply("prepare_in_seat_policy", %{"choice" => in_seat_choice(content)})
        end

      %{"role" => "tool"} ->
        text_reply(@prepared_in_seat)

      _other ->
        text_reply(@prepared_in_seat)
    end
  end

  # The person's own wording is the only argument the call carries, so the
  # journey's "must reboard" prepares `must_reboard` and its stay-on-board
  # question prepares `stay_on_board`.
  defp in_seat_choice(content) do
    if content =~ ~r/reboard|re-board|get off|new bus/i,
      do: "must_reboard",
      else: "stay_on_board"
  end

  defp calendars_reply(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) ->
        user_reply(content)

      %{"role" => "tool"} = tool_message ->
        tool_reply(messages, tool_message)

      _other ->
        text_reply(@generic)
    end
  end

  defp user_reply(content) do
    cond do
      content =~ ~r/provider reachable|provider down|provider key/i ->
        provider_failure()

      # The Flex branches come first: the Calendars questions below are keyed on
      # words a Flex question also uses ("weekday"), and this pack only ever
      # answers on the Flex service page.
      flex_policy_request?(content) ->
        tool_calls_reply("get_flex_policy_context", %{})

      content =~ ~r/extend/i ->
        tool_calls_reply("prepare_calendar_extension", extension_arguments(content))

      # Before the calendar questions, so a timetable message is never read as
      # a Calendars one.
      content =~ @timetable_row ->
        tool_calls_reply("read_timetable_source", %{})

      station_result_question?(content) ->
        tool_calls_reply(station_result_tool(content), %{})

      station_width_question?(content) ->
        tool_calls_reply("prepare_station_import_decisions", station_width_arguments())

      BrowserFeedQuality.question?(content) ->
        {name, arguments} = BrowserFeedQuality.user_reply(content)
        tool_calls_reply(name, arguments)

      true ->
        schedule_question_reply(content)
    end
  end

  # The Schedules and Calendars questions, after the scenarios that name their
  # own pack. Split from `user_reply/1` so each stays small enough to read.
  defp schedule_question_reply(content) do
    cond do
      # The Schedules page asks whether a connection can be made, which is the
      # connections pack's own read. It takes no arguments: the approved pairs,
      # the supplied clocks and the supplied minimum are all in the page's
      # source, and this branch is above the transfer wording below so the
      # question reaches the pack whose source it was approved against.
      content =~ ~r/make the connection|how much time|how tight|margin/i ->
        tool_calls_reply("compare_connection_margins", %{})

      transfer_question?(content) ->
        transfer_reply(content)

      service_question?(content) ->
        service_question_reply(content)

      calendar_question?(content) ->
        calendar_question_reply(content)

      true ->
        unscripted_reply(content)
    end
  end

  # The operations questions are the last scripted family, so every earlier
  # script keeps the messages it matched before they existed.
  defp unscripted_reply(content) do
    if operations_question?(content),
      do: operations_reply(content),
      else: text_reply(@generic)
  end

  # The Transfers page names its own selections, so the stand-in prepares the one
  # the journey staged rather than one it invented: `selection-1` is the first
  # draft the operator added, and the pack refuses any other id.
  defp transfer_reply(content) do
    if content =~ ~r/check|compete|competing|look at/i do
      tool_calls_reply("inspect_transfer_competition", %{"selection_id" => "selection-1"})
    else
      tool_calls_reply("prepare_transfer_policy", %{"selection_ids" => ["selection-1"]})
    end
  end

  # The operations questions are matched before the generic branch so a message
  # naming a block, a run or the crew rules reaches a real operations tool call.
  # `unassigned` and `uncovered` are the page's own vocabulary for the two
  # scopes, so a question naming one of them is an operations question even
  # without the word "block" or "run".
  defp operations_question?(content) do
    Enum.any?(
      [
        ~r/block/i,
        ~r/run/i,
        ~r/crew/i,
        ~r/unassigned|uncovered|overlap|in-seat/i,
        ~r/prepare|rebuild|fix|assign/i,
        ~r/relief|pull-out|sign-off|spread|break/i
      ],
      &Regex.match?(&1, content)
    )
  end

  # A Flex question names the service's own policy, and no Calendars, Schedule
  # or service-answer journey below uses these words.
  defp flex_policy_request?(content) do
    Enum.any?(
      [~r/flex/i, ~r/hours/i, ~r/booking/i, ~r/book a|office calendar|business day/i],
      &Regex.match?(&1, content)
    )
  end

  # A question naming a day other than the attached one still asks for a call;
  # the pack refuses it, which is the refusal the journey shows.
  defp operations_reply(content) do
    cond do
      foreign_day?(content) ->
        tool_calls_reply("get_blocking_issues", %{"day_ref" => @foreign_day_ref})

      content =~ ~r/prepare|fix|rebuild|assign/i ->
        prepare_operations_arguments(content)

      crew_rules_question?(content) ->
        tool_calls_reply("get_crew_rules", %{})

      run_question?(content) ->
        tool_calls_reply("get_run_issues", %{})

      true ->
        tool_calls_reply("get_blocking_issues", %{})
    end
  end

  # A question about some day other than this conversation's own. The stand-in
  # answers it with a `day_ref` no attached day has, so the refusal comes from
  # the pack's own fence rather than from the stub refusing to answer.
  defp foreign_day?(content) do
    content =~ ~r/yesterday|last week|next week|tomorrow|another day|a different day/i
  end

  defp crew_rules_question?(content) do
    Regex.match?(~r/crew rules|judging|pull-out|relief|sign-off|break|spread/i, content)
  end

  defp run_question?(content),
    do: Regex.match?(~r/run|crew|assignment|uncovered/i, content)

  # `replace_all` plans every trip on the day again, so the journeys that offer
  # it expect the warning that hand-tuned blocks may change. The two packs name
  # their narrowing differently: blocks takes a `mode`, runs takes a `scope`.
  defp prepare_operations_arguments(content) do
    replacement = content =~ ~r/rebuild|whole day|replace|everything|full/i

    if run_question?(content) do
      tool_calls_reply("prepare_run_suggestion", %{"scope" => scope(replacement)})
    else
      tool_calls_reply("prepare_block_suggestion", %{"mode" => mode(replacement)})
    end
  end

  defp mode(true), do: "replace_all"
  defp mode(false), do: "unassigned_only"

  defp scope(true), do: "replace_all"
  defp scope(false), do: "uncovered_only"

  defp calendar_question?(content) do
    Enum.any?([~r/route/i, ~r/dates|week/i, ~r/school/i], &Regex.match?(&1, content))
  end

  # Keyed on the word the station journey uses, so no other scripted journey
  # reaches the station pack by accident.
  defp station_width_question?(content), do: content =~ ~r/width|clear width/i

  defp station_width_arguments, do: %{"decision_ids" => @station_width_decisions}

  # Keyed on the words the station result journey uses, which no other scripted
  # journey mentions, so the station result pack is only reached deliberately.
  defp station_result_question?(content),
    do: content =~ ~r/recorded check|which pairs|right now|current station report/i

  # The first matching phrase wins, so a question naming both a recorded result
  # and the current facts still gets the branch the journey expects.
  defp station_result_tool(content) do
    cond do
      content =~ ~r/which pairs/i -> "list_station_result_pairs"
      content =~ ~r/right now|current station report/i -> "get_station_report_facts"
      true -> "get_station_result"
    end
  end

  defp calendar_question_reply(content) do
    cond do
      content =~ ~r/route/i ->
        text_reply(@out_of_scope)

      content =~ ~r/dates|week/i ->
        tool_calls_reply("get_calendar", get_calendar_arguments())

      content =~ ~r/school/i ->
        tool_calls_reply("list_calendars", %{"query" => "school"})
    end
  end

  defp service_question?(content) do
    Enum.any?(
      [
        ~r/central station/i,
        ~r/keep service|still run/i,
        ~r/retired calendar/i,
        ~r/next two months/i,
        ~r/depart|leaves? |after \d/i,
        ~r/board|stops? does/i
      ],
      &Regex.match?(&1, content)
    )
  end

  # The Transfers page asks about connections, so the seeded transfer stops and
  # this stand-in's own "connection" wording are what no other scripted journey
  # mentions.
  defp transfer_question?(content) do
    Enum.any?(
      [~r/transfer/i, ~r/connection/i, ~r/change (at|between) stops/i],
      &Regex.match?(&1, content)
    )
  end

  # The first matching question wins, so a request that names both a calendar and
  # a departure still gets the branch the scripted journey expects.
  defp service_question_reply(content) do
    cond do
      # The A02 question and its refusals are keyed on Central Station, which no
      # other scripted journey mentions, so the seeded holidays feed only this
      # spec's messages.
      content =~ ~r/central station/i ->
        holiday_departure_reply(content)

      content =~ ~r/keep service|still run/i ->
        tool_calls_reply("summarize_calendar_coverage", coverage_arguments())

      content =~ ~r/retired calendar/i ->
        tool_calls_reply("get_calendar", %{
          "service_id" => "RETIRED",
          "from" => Date.to_iso8601(BrowserServiceAnswers.thanksgiving_eve()),
          "to" => Date.to_iso8601(BrowserServiceAnswers.thanksgiving())
        })

      content =~ ~r/next two months/i ->
        tool_calls_reply("summarize_calendar_coverage", over_limit_arguments())

      content =~ ~r/depart|leaves? |after \d/i ->
        tool_calls_reply("query_departures", departure_arguments())

      content =~ ~r/board|stops? does/i ->
        tool_calls_reply("list_boarding_occurrences", %{
          "service_date" => Date.to_iso8601(next_service_date())
        })
    end
  end

  # A real provider failure, so the panel's failed entry, its Retry control and
  # the unavailable status are the shipped rendering of a rejected request
  # rather than of a scripted refusal.
  defp provider_failure, do: {:status, 401, %{"error" => "provider key rejected"}}

  # The A02 question asks for the occurrence the seeded loop makes ambiguous,
  # and the refusal branches below ask for the calls the domain refuses.
  defp holiday_departure_reply(content) do
    if content =~ ~r/which visit/i do
      tool_calls_reply("query_departures", ambiguous_departure_arguments())
    else
      tool_calls_reply("query_departures", holiday_departure_arguments())
    end
  end

  # AI-04's timetable tools have their own fixed chain over the accepted
  # source, the transfer and connection tools answer with one sentence, and the
  # feed quality tools answer with one fixed sentence each, so all three are
  # answered apart from the calendar tools and `tool_reply` only decides which
  # group stands in for the pack.
  defp tool_reply(messages, %{"tool_call_id" => tool_call_id}) do
    tool = answered_tool(messages, tool_call_id)

    cond do
      tool in @timetable_tools ->
        timetable_tool_reply(tool, messages)

      tool in @operations_tools ->
        operations_tool_reply(tool, messages)

      tool in @feed_quality_tools ->
        text_reply(BrowserFeedQuality.tool_reply(tool))

      true ->
        case prose_sentence(tool) do
          nil -> calendar_tool_reply(tool, messages)
          sentence -> text_reply(sentence)
        end
    end
  end

  defp timetable_tool_reply("read_timetable_source", _messages),
    do: tool_calls_reply("inspect_timetable_scope", %{})

  defp timetable_tool_reply("inspect_timetable_scope", messages),
    do: tool_calls_reply("prepare_timetable_input", timetable_arguments(messages))

  defp timetable_tool_reply("prepare_timetable_input", _messages),
    do: text_reply(@prepared_timetable)

  defp calendar_tool_reply("list_calendars", _messages),
    do: tool_calls_reply("prepare_date_change", prepare_arguments())

  defp calendar_tool_reply("prepare_date_change", _messages), do: text_reply(@prepared)

  defp calendar_tool_reply("get_calendar", messages), do: get_calendar_reply(messages)

  defp calendar_tool_reply("query_departures", messages), do: departure_reply(messages)

  defp calendar_tool_reply("summarize_calendar_coverage", messages),
    do: coverage_reply(messages)

  defp calendar_tool_reply("get_flex_policy_context", messages),
    do: tool_calls_reply("prepare_flex_policy", flex_prepare_arguments(messages))

  defp calendar_tool_reply("prepare_flex_policy", messages),
    do: flex_prepared_reply(messages)

  defp calendar_tool_reply("list_boarding_occurrences", _messages),
    do: text_reply(@schedule_occurrences)

  defp calendar_tool_reply("prepare_calendar_extension", _messages),
    do: text_reply(@prepared_extension)

  defp calendar_tool_reply(_other, _messages), do: text_reply(@generic)

  # These tools are answered with one scripted sentence each: the two the
  # Transfers page drafts with, the connections read, whose whole answer comes
  # from the approved source rather than from anything scripted here, and the
  # station import review and result tools. Any other tool leaves `nil` and is
  # answered by the Schedule pack's clauses.
  defp prose_sentence(name)
       when name in ["inspect_transfer_competition", "prepare_transfer_policy"],
       do: @prepared_transfer

  defp prose_sentence("compare_connection_margins"), do: @compared_connections

  defp prose_sentence("prepare_station_import_decisions"), do: @prepared_measurement
  defp prose_sentence("get_station_result"), do: @recorded_result
  defp prose_sentence("list_station_result_pairs"), do: @recorded_pairs
  defp prose_sentence("get_station_report_facts"), do: @current_facts

  defp prose_sentence(_other), do: nil

  # The turn loop treats a bounded tool error as a message the model may correct
  # and asks again, so a stub that ignored it would answer a question its own
  # call had just been refused for. These branches read the error back out of
  # the last tool message and stand down, which is what the journeys assert: the
  # refusal is the last word, and no evidence card follows it.
  defp operations_tool_reply(tool, messages),
    do: operations_result_reply(messages, Map.fetch!(@operations_answers, tool))

  # A tool result that carries an `error` is a refusal. The stand-in does not
  # retry past one: it names what the domain said and stops, which is what a
  # model reading a refused day should do.
  defp operations_result_reply(messages, answer) do
    case last_tool_content(messages) do
      %{"error" => error} when is_binary(error) -> text_reply(error)
      _answered -> text_reply(answer)
    end
  end

  defp last_tool_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "tool", "content" => content} when is_binary(content) ->
        case Jason.decode(content) do
          {:ok, decoded} -> decoded
          {:error, _reason} -> nil
        end

      _message ->
        false
    end)
  end

  # The seeded A02 answer has two listed departures, so the stand-in's sentence
  # for that call contradicts the card; the refusal branches keep the generic
  # Schedule sentence.
  defp departure_reply(messages) do
    cond do
      last_user_content(messages) =~ ~r/which visit/i ->
        text_reply(@ambiguous_visit)

      mentions_central_station?(messages) ->
        text_reply(@holiday_departures)

      true ->
        text_reply(@schedule_departures)
    end
  end

  # A refused preparation is the assistant's own reason, so the stand-in repeats
  # what the tool returned rather than paraphrasing it: the refusal the browser
  # journey reads is the server's refusal, not this file's wording.
  defp flex_prepared_reply(messages) do
    case last_tool_payload(messages) do
      %{"error" => reason} when is_binary(reason) ->
        text_reply("I did not prepare that. " <> reason)

      _prepared ->
        text_reply(@flex_prepared)
    end
  end

  # The turn loop answers a tool call with a `"tool"` message whose content is the
  # result payload it encoded, so the newest tool message is this turn's last
  # tool result.
  defp last_tool_payload(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(%{}, fn
      %{"role" => "tool", "content" => content} when is_binary(content) ->
        case Jason.decode(content) do
          {:ok, payload} when is_map(payload) -> payload
          _unreadable -> nil
        end

      _message ->
        nil
    end)
  end

  # The complete replacement hours array of the seeded `Newport Dial-a-Ride`
  # service: both saved rows, with the weekday window moved to 08:00-17:00 and
  # the Saturday window exactly as saved. A replacement array is the final state
  # of the array, unchanged rows included.
  defp flex_prepare_arguments(messages) do
    content = last_user_content(messages)

    cond do
      content =~ ~r/same-day|same day|dispatcher/i ->
        %{
          "scope" => "all_supported",
          "hours" => flex_hours(),
          "unsupported" => ["Same-day bookings when the dispatcher agrees."]
        }

      content =~ ~r/business day|office/i ->
        %{
          "scope" => "all_supported",
          "booking_rules" => [
            %{
              "when" => "earlier_day",
              "minutes" => 1440,
              "business_days" => true,
              "office_service_id" => "office"
            }
          ]
        }

      true ->
        %{"scope" => "all_supported", "hours" => flex_hours()}
    end
  end

  defp flex_hours do
    [
      %{"area_key" => "a1", "service_id" => "weekday", "start" => "08:00", "end" => "17:00"},
      %{"area_key" => "a1", "service_id" => "saturday", "start" => "09:00", "end" => "16:00"}
    ]
  end

  defp coverage_reply(messages) do
    if last_user_content(messages) =~ ~r/next two months/i do
      text_reply(@too_many_dates)
    else
      text_reply(@coverage_answer)
    end
  end

  # The retired-calendar refusal leaves the domain's own sentence behind, so the
  # panel announces the same next action the tool did.
  defp get_calendar_reply(messages) do
    if last_user_content(messages) =~ ~r/retired calendar/i do
      text_reply(@unknown_calendar)
    else
      text_reply(@contradicted_count)
    end
  end

  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{"role" => "user", "content" => content} when is_binary(content) -> content
      _message -> false
    end)
  end

  defp mentions_central_station?(messages) do
    Enum.any?(messages, fn
      %{"role" => "user", "content" => content} when is_binary(content) ->
        content =~ ~r/central station/i

      _message ->
        false
    end)
  end

  # -- Release comparison -----------------------------------------------------

  defp comparison_reply(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) ->
        comparison_user_reply(content)

      %{"role" => "tool"} = tool_message ->
        comparison_tool_reply(messages, tool_message)

      _other ->
        text_reply(@comparison_generic)
    end
  end

  defp comparison_user_reply(content) do
    cond do
      content =~ ~r/provider reachable|provider down|provider key/i ->
        provider_failure()

      content =~ ~r/unresolved|could not be matched|look alike/i ->
        tool_calls_reply("inspect_unresolved_entity_matches", %{})

      content =~ ~r/what did you compare|which files/i ->
        tool_calls_reply("resolve_export_comparison_scope", %{})

      content =~ ~r/lose|lost|loss/i or content =~ ~r/total|anything change/i ->
        tool_calls_reply("get_export_comparison", %{})

      true ->
        text_reply(@comparison_generic)
    end
  end

  # A loss question reads the summary first and then the differences; every other
  # question is answered from the one call it made.
  defp comparison_tool_reply(messages, %{"tool_call_id" => tool_call_id} = tool_message) do
    question = last_user_content(messages)
    result = decoded_tool_result(tool_message)
    loss? = question =~ ~r/lose|lost|loss/i

    case {answered_tool(messages, tool_call_id), loss?} do
      {"get_export_comparison", true} ->
        tool_calls_reply("inspect_service_difference", %{})

      {"get_export_comparison", false} ->
        text_reply(comparison_summary_sentence(question, result))

      {"inspect_service_difference", _loss?} ->
        text_reply(loss_and_churn_sentence(result, comparison_status(messages)))

      {"inspect_unresolved_entity_matches", _loss?} ->
        text_reply(unresolved_sentence(result))

      {"resolve_export_comparison_scope", _loss?} ->
        text_reply(scope_sentence(result))

      _other ->
        text_reply(@comparison_generic)
    end
  end

  defp decoded_tool_result(%{"content" => content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, result} when is_map(result) -> result
      _other -> %{}
    end
  end

  defp decoded_tool_result(_tool_message), do: %{}

  # The completeness the summary tool reported earlier in this same turn.
  defp comparison_status(messages) do
    messages
    |> Enum.filter(&(&1["role"] == "tool"))
    |> Enum.map(&decoded_tool_result/1)
    |> Enum.find_value("unknown", fn
      %{"completeness" => %{"status" => status}, "counts" => _counts} -> status
      _result -> nil
    end)
  end

  defp loss_and_churn_sentence(%{"records" => records}, status) do
    losses =
      for %{"type" => "effective", "kind" => "count_changed"} = record <- records,
          fewer = trips_lost(record),
          fewer > 0,
          do:
            "#{record["route_ids"]["left"]} lost #{trips(fewer)} on #{weekday(record["date"])}, " <>
              "from #{record["counts"]["left"]["scheduled_count"]} to " <>
              "#{record["counts"]["right"]["scheduled_count"]}."

    renames =
      for %{"type" => "structural", "entity" => "route", "change" => "identifier"} = record <-
            records,
          do:
            "#{record["left"]} was only renamed #{record["right"]}: same service under a new " <>
              "identifier, so that is not a loss."

    (losses ++ renames ++ incomplete_sentence(status))
    |> case do
      [] -> ["No service loss was found."]
      sentences -> sentences
    end
    |> Enum.join(" ")
  end

  defp loss_and_churn_sentence(_result, _status),
    do: "I could not read the differences."

  defp trips_lost(%{"counts" => %{"left" => left, "right" => right}}),
    do: left["scheduled_count"] - right["scheduled_count"]

  defp trips_lost(_record), do: 0

  defp trips(1), do: "1 trip"
  defp trips(count), do: "#{count} trips"

  defp incomplete_sentence("incomplete"),
    do: ["The comparison is incomplete, so this is not a clean answer."]

  defp incomplete_sentence(_status), do: []

  defp comparison_summary_sentence(question, %{"totals" => totals} = result) do
    cond do
      question =~ ~r/anything change/i ->
        no_difference_sentence(result)

      is_nil(totals["exact_count_delta"]) ->
        "I can't give a total change in departures: it was not measured. " <>
          reasons_sentence(totals["reasons"])

      true ->
        "Exact departures changed by #{signed(totals["exact_count_delta"])} across the compared routes."
    end
  end

  defp comparison_summary_sentence(_question, _result), do: "I could not read the summary."

  defp no_difference_sentence(%{"counts" => counts, "completeness" => %{"status" => status}}) do
    changes = counts["effective_changes"]["total"] + counts["structural_changes"]["total"]

    cond do
      status == "complete" and changes == 0 ->
        "Nothing changed in service, and the comparison is complete."

      status == "complete" ->
        "#{changes} differences were found, so something changed."

      true ->
        "The comparison is incomplete, so I can't say nothing changed."
    end
  end

  defp reasons_sentence(reasons) when is_list(reasons) do
    reasons
    |> Enum.map(&reason_words/1)
    |> Enum.join(" ")
  end

  defp reasons_sentence(_reasons), do: ""

  defp reason_words("incomplete_counts"),
    do: "A route states frequency windows rather than exact departures."

  defp reason_words("unmapped_route"),
    do: "A route in one file has no proven match in the other."

  defp reason_words(reason), do: "Reason: #{String.replace(reason, "_", " ")}."

  defp unresolved_sentence(%{"records" => records, "true_total" => total}) do
    "#{total} stop matches are unresolved across #{length(records)} listed. " <>
      "The comparison claims no change for them, and none of them is a loss."
  end

  defp unresolved_sentence(_result), do: "I could not read the unresolved matches."

  defp scope_sentence(%{"window" => %{"from" => from, "to" => to}, "route_pairs" => pairs}) do
    "Two retained exports were compared from #{weekday(from)} to #{weekday(to)} " <>
      "across #{length(pairs)} route pairs."
  end

  defp scope_sentence(_result), do: "I could not read the comparison scope."

  defp signed(delta) when delta > 0, do: "+#{delta}"
  defp signed(delta), do: Integer.to_string(delta)

  defp weekday(iso), do: iso |> Date.from_iso8601!() |> Calendar.strftime("%a %b %-d, %Y")

  defp alerts_reply(messages) do
    case List.last(messages) do
      %{"role" => "user", "content" => content} when is_binary(content) ->
        if content =~ ~r/route\s*12/i,
          do: tool_calls_reply("get_draft", %{}),
          else: text_reply(@alerts_question)

      %{"role" => "tool"} = tool_message ->
        alerts_tool_reply(messages, tool_message)

      _other ->
        text_reply(@alerts_question)
    end
  end

  defp alerts_tool_reply(messages, %{"tool_call_id" => tool_call_id} = tool_message) do
    case answered_tool(messages, tool_call_id) do
      "get_draft" ->
        tool_calls_reply("search_routes", %{"query" => "12"})

      "search_routes" ->
        # The alerts skill forbids naming a route no tool returned, so the route
        # id comes out of this turn's own search result and a result without
        # Route 12 prepares nothing.
        case route_12_id(tool_message) do
          nil -> text_reply(@alerts_not_found)
          route_id -> tool_calls_reply("propose_changes", change_arguments(messages, route_id))
        end

      "propose_changes" ->
        # A refused call prepared nothing, so the sentence that says it did is
        # only for a result that carries no error.
        if tool_error?(tool_message),
          do: text_reply(@alerts_not_prepared),
          else: text_reply(@alerts_prepared)

      _other ->
        text_reply(@alerts_generic)
    end
  end

  defp route_12_id(%{"content" => content}) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"routes" => routes}} when is_list(routes) ->
        Enum.find_value(routes, &route_12_feed_id/1)

      _other ->
        nil
    end
  end

  defp route_12_id(_other), do: nil

  defp route_12_feed_id(%{"id" => id} = route) when is_binary(id) do
    if route["route_id"] == "12" or route["short_name"] == "Route 12", do: id
  end

  defp route_12_feed_id(_route), do: nil

  # The turn loop reports a refused tool call as `{"error": message}`.
  defp tool_error?(%{"content" => content}) when is_binary(content),
    do: match?({:ok, %{"error" => _message}}, Jason.decode(content))

  defp tool_error?(_tool_message), do: false

  defp change_arguments(messages, route_id) do
    %{
      "urgency" => "now",
      "situation" => "detour",
      "scope" => %{"shape" => "routes", "route_ids" => [route_id]},
      "timing" => %{"start_date" => today(messages), "end_kind" => "estimated"}
    }
  end

  # The agency-local date the turn's system message states. Reading it out of
  # that message keeps the script off any clock of its own; a request with no
  # system message falls back to the UTC date the Calendars script already uses.
  defp today(messages) do
    case Regex.run(~r/Today is (\d{4}-\d{2}-\d{2})/, system_content(messages)) do
      [_all, date | _rest] -> date
      _other -> Date.to_iso8601(Date.utc_today())
    end
  end

  defp system_content(messages) do
    Enum.find_value(messages, fn
      %{"role" => "system", "content" => content} when is_binary(content) -> content
      _other -> nil
    end) || ""
  end

  # The turn loop answers a tool call with a `"tool"` message carrying the
  # call's id, so the answered tool is the most recent assistant call with that
  # id. A tool result with no such call falls back to the generic sentence.
  defp answered_tool(messages, tool_call_id) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"role" => "assistant", "tool_calls" => calls} when is_list(calls) ->
        Enum.find_value(calls, fn
          %{"id" => ^tool_call_id, "function" => %{"name" => name}} when is_binary(name) -> name
          _call -> nil
        end)

      _message ->
        nil
    end)
  end

  # Next Monday strictly after today, then the Tuesday after it: the seed's
  # Monday-Friday calendars run on both dates.
  # The next Monday through the Sunday after it: the seeded School weekdays
  # calendar runs Monday through Friday, so the server answer is five of seven.
  defp get_calendar_arguments do
    monday = Date.add(Date.utc_today(), 8 - Date.day_of_week(Date.utc_today()))

    %{
      "service_id" => "SCHOOL_WD",
      "from" => Date.to_iso8601(monday),
      "to" => Date.to_iso8601(Date.add(monday, 6))
    }
  end

  # The next date strictly after today: the seeded `CAL_DAILY` calendar runs
  # every day, so the schedule routes' trips are active on it whatever day the
  # journey runs. The first stop of the seeded Schedules patterns is `BSS_1` at
  # sequence 1, and 05:00 is before every seeded departure, so the answer is the
  # page's own trips rather than an empty read.
  defp departure_arguments do
    %{
      "service_date" => Date.to_iso8601(next_service_date()),
      "stop_id" => "BSS_1",
      "stop_sequence" => 1,
      "after" => "05:00",
      "include_after_midnight" => false
    }
  end

  defp next_service_date, do: Date.add(Date.utc_today(), 1)

  # The tool reads the approval from the server-held context, so the stand-in
  # can only name the calendar and end date the editor wrote into the page's
  # own form. A message about the seeded service-answer feed asks for that
  # version's `WEEKDAY` calendar; every other extension message keeps the school
  # calendar the other journeys approve.
  defp extension_arguments(content) do
    %{
      "service_id" => extension_service_id(content),
      "end_date" => Date.to_iso8601(Date.add(Date.utc_today(), @extension_days))
    }
  end

  # Each extension journey approves a calendar of its own, so a second approval
  # of the same calendar would be refused for extending nothing.
  defp extension_service_id(content) do
    cond do
      content =~ ~r/harbor/i -> "WEEKDAY"
      content =~ ~r/express/i -> "SCHOOL_EX"
      true -> "SCHOOL_WD"
    end
  end

  # The seeded holiday question: Central Station is occurrence 2 on every H8
  # trip, so the answer can name it instead of guessing which visit was meant.
  defp holiday_departure_arguments do
    %{
      "service_date" => Date.to_iso8601(BrowserServiceAnswers.thanksgiving()),
      "stop_id" => "CENTRAL",
      "stop_sequence" => 2,
      "after" => "18:00",
      "include_after_midnight" => false
    }
  end

  # The same call with the occurrence left out. The seeded loop visits Central
  # Station twice, so the domain refuses with its occurrence candidates.
  defp ambiguous_departure_arguments do
    %{
      "service_date" => Date.to_iso8601(BrowserServiceAnswers.thanksgiving()),
      "stop_id" => "CENTRAL",
      "after" => "18:00",
      "include_after_midnight" => false
    }
  end

  # H8's `REGULAR` service has ended by both dates, while H12 keeps Sunday
  # service through `SCHOOL`, so the card can show a gap and an alternate.
  defp coverage_arguments do
    %{
      "service_id" => "REGULAR",
      "dates" =>
        Enum.map(
          [BrowserServiceAnswers.nov_first(), BrowserServiceAnswers.nov_sunday()],
          &Date.to_iso8601/1
        ),
      "route_ids" => ["H8", "H12"]
    }
  end

  # More dates than the dispatch fence allows, so the turn ends on the fence's
  # refusal and names the narrowing next action instead of answering.
  defp over_limit_arguments do
    %{
      "service_id" => "REGULAR",
      "dates" =>
        BrowserServiceAnswers.range_start()
        |> then(&Date.range(&1, Date.add(&1, 60)))
        |> Enum.map(&Date.to_iso8601/1),
      "route_ids" => ["H8", "H12"]
    }
  end

  # The rows the editor's own message named, against the seeded route's own
  # calendar and the direction the message named. The pack refuses any other
  # combination, so the browser journey can only reach a real batch by
  # preparing this route's own accepted source.
  defp timetable_arguments(messages) do
    # `Regex.run/2` omits a trailing group that did not participate, so the
    # calendar is read from whatever the match carried rather than from a
    # fixed-width match.
    [_, direction, row | named] = Regex.run(@timetable_row, last_user_content(messages))
    calendar = List.first(named)
    inbound? = String.trim(direction) == "inbound"

    %{
      "row_ids" => [String.to_integer(row)],
      # A message may name a second calendar. The pack compares it with the
      # calendar the page's own scope resolved and refuses the call, so the
      # journey shows a refused second calendar rather than a second batch of
      # the first one.
      "service_id" => named_service_id(calendar),
      "pattern_id" =>
        if(inbound?, do: @timetable_inbound_pattern_id, else: @timetable_pattern_id),
      "direction_id" =>
        if(inbound?, do: @timetable_inbound_direction_id, else: @timetable_direction_id)
    }
  end

  defp named_service_id(calendar) when calendar in [nil, ""], do: @timetable_service_id
  defp named_service_id(calendar), do: calendar

  defp prepare_arguments do
    monday = Date.add(Date.utc_today(), 8 - Date.day_of_week(Date.utc_today()))

    %{
      "dates" => Enum.map([monday, Date.add(monday, 1)], &Date.to_iso8601/1),
      "stop" => ["SCHOOL_EX", "SCHOOL_WD"],
      "run" => []
    }
  end

  defp tool_calls_reply(name, arguments) do
    %{
      "id" => "gen-browser-#{name}",
      "model" => @model,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_#{name}",
                "type" => "function",
                "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
              }
            ]
          }
        }
      ],
      "usage" => usage(32)
    }
  end

  defp text_reply(content) do
    %{
      "id" => "gen-browser-text",
      "model" => @model,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => usage(16)
    }
  end

  # The model client reads only `usage.cost`; the token counts keep the reply
  # shaped like OpenRouter's. The stand-in bills nothing.
  defp usage(completion_tokens) do
    %{
      "prompt_tokens" => 128,
      "completion_tokens" => completion_tokens,
      "total_tokens" => 128 + completion_tokens,
      "cost" => 0.0
    }
  end
end

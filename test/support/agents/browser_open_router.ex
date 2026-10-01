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
  shape. The script is the Calendars skill's school-break example:

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
      trip;
    * a `"user"` message asking to extend a calendar gets a
      `prepare_calendar_extension` call for the seeded `SCHOOL_WD` calendar and
      the same end date the journey approves in *Approve a calendar extension*,
      so the tool reads the editor's approval instead of one the model supplied;
    * the `query_departures` and `list_boarding_occurrences` tool results get a
      Schedule sentence, one of which contradicts the server's count on purpose;
    * the `prepare_calendar_extension` tool result gets the prepared-extension
      sentence;
    * anything else gets the helper's generic sentence.
  """

  @behaviour Plug

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
  @prepared_extension "I prepared the extension. Review it before applying."
  # The end date the browser journey approves in the Calendars page's own form,
  # 200 days from today: inside the 366-day horizon, and later than the seeded
  # calendar's own end date, so the tool can only prepare it from that approval.
  @extension_days 200

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"messages" => messages} = Jason.decode!(body)

    Req.Test.json(conn, reply(messages))
  end

  defp reply(messages) do
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
      content =~ ~r/extend/i ->
        tool_calls_reply("prepare_calendar_extension", %{
          "service_id" => "SCHOOL_WD",
          "end_date" => Date.to_iso8601(Date.add(Date.utc_today(), @extension_days))
        })

      content =~ ~r/depart|leaves? |after \d/i ->
        tool_calls_reply("query_departures", departure_arguments())

      content =~ ~r/board|stops? does/i ->
        tool_calls_reply("list_boarding_occurrences", %{
          "service_date" => Date.to_iso8601(next_service_date())
        })

      content =~ ~r/route/i ->
        text_reply(@out_of_scope)

      content =~ ~r/dates|week/i ->
        tool_calls_reply("get_calendar", get_calendar_arguments())

      content =~ ~r/school/i ->
        tool_calls_reply("list_calendars", %{"query" => "school"})

      true ->
        text_reply(@generic)
    end
  end

  defp tool_reply(messages, %{"tool_call_id" => tool_call_id}) do
    case answered_tool(messages, tool_call_id) do
      "list_calendars" -> tool_calls_reply("prepare_date_change", prepare_arguments())
      "prepare_date_change" -> text_reply(@prepared)
      "get_calendar" -> text_reply(@contradicted_count)
      "query_departures" -> text_reply(@schedule_departures)
      "list_boarding_occurrences" -> text_reply(@schedule_occurrences)
      "prepare_calendar_extension" -> text_reply(@prepared_extension)
      _other -> text_reply(@generic)
    end
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

defmodule GtfsPlanner.Agents.Packs.InSeat do
  @moduledoc """
  The Blocks in-seat helper pack: whether the connections the person selected may be
  set on every date, and the choice they stated, prepared for the page.

  The pack is registered here because `BlocksLive` offers it beside the native
  connection and Set-all reviews, and the panel refuses to mount a selector naming a
  pack the application does not ship. It reads nothing but the immutable `in_seat`
  snapshot the host admitted through
  `GtfsPlanner.Agents.Scope.with_source_snapshot/2`, so a conversation with no
  approved in-seat source is refused before any request, tool read, delivered result
  or prepared lookup (INV-1, INV-2).

  Neither tool names a trip, a block, a date or a pair.
  `inspect_in_seat_connections/3` takes no arguments at all: the group's own token,
  the day type on screen and every selected pair are the page's, so a model can
  neither move the question to another day nor choose which pair is checked. The
  only answer is `GtfsPlanner.Gtfs.check_in_seat_connections/3` over exactly those
  pairs, which evaluates `GtfsPlanner.Gtfs.Blocking.InSeat.state/2` over every day
  type both trips run in, so a pair that is consecutive on the displayed day and has
  another trip between them on another date is refused with that date's day type and
  intervening trip (FH-11, CR-3). A one-day shared block is never read as full-date
  eligibility.

  `prepare_in_seat_policy/3` takes one argument, `choice`, and only an explicit
  `stay_on_board` or `must_reboard` maps to a setting: any other wording is asked
  about once and prepared never, because "clear it" is the page's own removal rather
  than a third setting. The prepared command is
  `%{kind: :in_seat_policy, pairs: [%{from_uuid:, to_uuid:}], choice:, source_digest:}`
  and carries no expected rows: the host rebuilds them from fresh native reads when
  the person confirms, so no model text and no earlier read can become the guard a
  write compares against.

  There is no apply, remove or undo tool here, and none is reachable: the pack names
  no writer, so `Gtfs.set_in_seat_connection/5`, `Gtfs.set_in_seat_connections/3` and
  `Gtfs.remove_in_seat_records/2` stay the native review's own path (CR-1, CR-3).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs

  @source_kind "in_seat"
  @schema_version 1
  @source_ref "gtfs_in_seat"

  # An engineering ceiling, not a product limit: the native group save carries at
  # most 500 pairs, and this pack refuses a larger selection rather than preparing
  # a command the page could not carry.
  @max_pairs 500

  # The model's witness and the page card are bounded separately from the selection,
  # so a 500-pair group is answered with a bounded witness whose totals still cover
  # every selected pair rather than refused whole or truncated silently.
  @max_witness_rows 25
  @max_card_rows 10

  @max_label_length 200

  @skill_path Path.expand("../../../../priv/agents/packs/in_seat/SKILL.md", __DIR__)
  @external_resource @skill_path

  @skill @skill_path
         |> File.read!()
         |> String.split("\n")
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.drop_while(&(&1 != "---"))
         |> Enum.drop(1)
         |> Enum.join("\n")
         |> String.trim()

  @impl true
  def id, do: @source_kind

  @impl true
  def title, do: "In-seat helper"

  @impl true
  def intro do
    "I can tell you whether the in-seat connections you selected here hold on every date they run, and prepare the stay-on-board or must-reboard choice you stated for your own review. I can't change trips, calendars, stops, routes or blocks."
  end

  @impl true
  def examples do
    [
      "Can riders stay on board across these connections?",
      "Prepare these connections as must reboard"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "inspect_in_seat_connections",
        description:
          "Check whether the in-seat connections selected on this page may be set on every date both trips run, and report each pair as eligible or refused with the reason. The group, the day on screen and the pairs are the page's own selection, so this tool takes no arguments: call it whenever the person asks whether a connection can hold, whether a setting is allowed, or why a connection cannot be set.",
        activity: "Checked the in-seat connections",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_in_seat_policy",
        description:
          "Prepare the person's own stay-on-board or must-reboard setting for the selected connections, so they can review and save it on this page. Pass exactly the setting they stated; anything else, including removing a record, is asked about instead. The whole selection takes one setting at a time. It saves nothing.",
        activity: "Prepared the in-seat setting",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "choice" => %{"type" => "string", "minLength" => 1, "maxLength" => 64}
          },
          "required" => ["choice"],
          "additionalProperties" => false
        }
      }
    ]
  end

  # The admission rule the whole helper rests on: the page's own admitted snapshot,
  # its native group and day identity, and every selected pair resolvable as this
  # organization's trips of this version. A missing, deleted or foreign trip is
  # refused here — before the provider request — with the same result a malformed
  # payload gives, so no other tenant's or version's metadata can reach the model.
  @impl true
  def authorize_context(%Scope{} = scope) do
    case request(scope) do
      {:ok, _request} -> :ok
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  @impl true
  def call("inspect_in_seat_connections", _args, %Scope{} = scope),
    do: inspected(scope)

  def call("prepare_in_seat_policy", args, %Scope{} = scope),
    do: prepared(Map.get(args, "choice"), scope)

  def call(_name, _args, %Scope{}), do: {:error, "This helper has no such tool."}

  # -- the check -------------------------------------------------------------

  defp inspected(scope) do
    with {:ok, request} <- admitted(scope) do
      answer(request, scope)
    end
  end

  defp admitted(scope) do
    case request(scope) do
      {:ok, request} -> {:ok, request}
      # `authorize_context/1` has already refused such a conversation, so this is a
      # defensive message rather than a path the turn can reach.
      {:error, :unavailable} -> {:error, unavailable_message()}
    end
  end

  defp answer(request, scope) do
    with {:ok, checks} <- check(request, scope) do
      result = result(request, checks, scope)

      {:ok, result, evidence(request, checks, result, scope)}
    end
  end

  # The one read: the native full-date rule over the selected pairs, scoped to this
  # organization and version. Nothing here writes, and no lock is taken, because the
  # save repeats the same rule under the block writers' locks.
  defp check(request, scope) do
    case Gtfs.check_in_seat_connections(
           scope.organization_id,
           scope.gtfs_version_id,
           Enum.map(request.pairs, &{&1.from_trip_id, &1.to_trip_id})
         ) do
      {:ok, checks} ->
        {:ok, checks}

      {:error, :not_found} ->
        {:error, "These connections are not in this service version."}

      {:error, _reason} ->
        {:error, "These connections could not be checked right now. Try again."}
    end
  end

  # -- the preparation -------------------------------------------------------

  defp prepared(choice, scope) do
    case setting(choice) do
      {:ok, choice} -> prepare(choice, scope)
      {:error, message} -> {:error, message}
    end
  end

  # Only an explicit stay or reboard maps to a setting. "Not stated", "clear it" and
  # anything else is one question, because removing a record is the page's own
  # action and not a third in-seat choice.
  defp setting("stay_on_board"), do: {:ok, :stay_on_board}
  defp setting("must_reboard"), do: {:ok, :must_reboard}

  defp setting(_choice),
    do:
      {:error,
       "Which setting do you mean for these connections — stay on board, or must reboard? I have not prepared anything."}

  # The preparation runs the same check the inspection runs and refuses the whole
  # selection rather than preparing the pairs that happen to pass: a command the
  # page would partly skip is a list whose order and completeness the person never
  # saw.
  defp prepare(choice, scope) do
    with {:ok, request} <- admitted(scope),
         {:ok, checks} <- check(request, scope),
         :ok <- refusable(request, checks) do
      result = result(request, checks, scope) |> Map.put("choice", to_string(choice))

      {:prepared,
       %{
         summary: summary(request, choice, scope),
         command: %{
           kind: :in_seat_policy,
           pairs: Enum.map(request.pairs, &%{from_uuid: &1.from_uuid, to_uuid: &1.to_uuid}),
           choice: choice,
           source_digest: source_digest(scope)
         }
       }, result, evidence(request, checks, result, scope, choice)}
    end
  end

  defp refusable(request, checks) do
    refused =
      for pair <- request.pairs,
          check = check_for(checks, pair),
          check != :ok,
          do: {pair, check}

    case refused do
      [] ->
        :ok

      [_first | _rest] ->
        named = Enum.take(refused, 3)

        {:error,
         "I have not prepared anything: #{length(refused)} of the #{length(request.pairs)} selected connections cannot be set on every date they run (#{Enum.map_join(named, "; ", &refusal_label/1)}#{if length(refused) > 3, do: "; and #{length(refused) - 3} more", else: ""}). Ask about those connections on this page first."}
    end
  end

  defp check_for(checks, pair), do: Map.get(checks, {pair.from_trip_id, pair.to_trip_id}, :ok)

  defp refusal_label({pair, check}) do
    %{status: status, reason: reason} = state_result(check)

    "#{pair.from_trip_id} to #{pair.to_trip_id} #{reason_sentence(status, to_string(reason))}"
  end

  # -- the admitted selection ----------------------------------------------

  # Every host JSON key is mapped to its atom explicitly: `String.to_atom/1` on
  # snapshot content would let an admitted label allocate atoms, so this is the
  # whole decoder and it accepts only the documented shapes. A selected pair is
  # resolved to this version's own trip here, so the natural trip ids the native
  # rule takes are never read from the payload.
  defp request(%Scope{} = scope) do
    with %{kind: @source_kind, payload: payload} <- Scope.source_snapshot(scope),
         %{"schema_version" => @schema_version} <- payload,
         {:ok, group_token} <- label(payload["group_token"]),
         {:ok, day_type_key} <- label(payload["day_type_key"]),
         {:ok, day_type_label} <- label(payload["day_type_label"]),
         {:ok, pairs} <- pairs(payload["pairs"], scope) do
      {:ok,
       %{
         group_token: group_token,
         day_type_key: day_type_key,
         day_type_label: day_type_label,
         pairs: pairs
       }}
    else
      _other -> {:error, :unavailable}
    end
  end

  defp label(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and String.length(trimmed) <= @max_label_length do
      {:ok, trimmed}
    else
      :error
    end
  end

  defp label(_value), do: :error

  defp pairs(value, scope) when is_list(value) and value != [] and length(value) <= @max_pairs do
    Enum.reduce_while(value, {:ok, []}, fn pair, {:ok, acc} ->
      case pair(pair, scope) do
        {:ok, decoded} -> {:cont, {:ok, acc ++ [decoded]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp pairs(_value, _scope), do: :error

  defp pair(%{"from_uuid" => from_uuid, "to_uuid" => to_uuid}, scope) do
    with {:ok, from} <- trip(from_uuid, scope),
         {:ok, to} <- trip(to_uuid, scope),
         true <- from_uuid != to_uuid do
      {:ok,
       %{
         from_uuid: from_uuid,
         to_uuid: to_uuid,
         from_trip_id: from.trip_id,
         to_trip_id: to.trip_id
       }}
    else
      _other -> :error
    end
  end

  defp pair(_pair, _scope), do: :error

  defp trip(uuid, scope) do
    Gtfs.get_trip_in_version(scope.organization_id, scope.gtfs_version_id, uuid)
  end

  # -- the model's answer ----------------------------------------------------

  defp result(request, checks, scope) do
    rows = Enum.map(request.pairs, &pair_result(&1, check_for(checks, &1)))

    %{
      "group_token" => request.group_token,
      "day_type_key" => request.day_type_key,
      "day_type_label" => request.day_type_label,
      "pairs" => Enum.take(rows, @max_witness_rows),
      "pairs_shown" => min(length(rows), @max_witness_rows),
      "pairs_omitted" => max(length(rows) - @max_witness_rows, 0),
      "totals" => totals(request.pairs, rows),
      "completeness" => completeness(request.pairs, rows),
      "source_digest" => source_digest(scope)
    }
  end

  defp pair_result(pair, check) do
    state = state_result(check)

    %{
      "from_uuid" => pair.from_uuid,
      "to_uuid" => pair.to_uuid,
      "from_trip_id" => pair.from_trip_id,
      "to_trip_id" => pair.to_trip_id,
      "status" => state.status,
      "reason" => state.reason,
      "other_days" => Map.get(state, :day_types)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # The native rule's own answer, named rather than flattened: a not-next refusal
  # keeps the day types and intervening trips it decided on, so a shared block that
  # works on the displayed day is reported with the date it fails on.
  defp state_result(:ok), do: %{status: "eligible", reason: nil}

  defp state_result({:refused, {:stale, {:not_next, failures}}}) do
    %{
      status: "refused",
      reason: "not_next",
      day_types:
        Enum.map(failures, fn failure ->
          %{
            "day_type_key" => failure.key,
            "day_type_label" => failure.label,
            "date_count" => failure.date_count,
            "next_trip_id" => failure.next_trip_id
          }
        end)
    }
  end

  defp state_result({:refused, {:stale, reason}}),
    do: %{status: "refused", reason: to_string(reason)}

  defp state_result({:refused, {:unconfirmed, reason}}),
    do: %{status: "unconfirmed", reason: to_string(reason)}

  defp totals(pairs, rows) do
    %{
      "selected" => length(pairs),
      "eligible" => Enum.count(rows, &(&1["status"] == "eligible")),
      "refused" => Enum.count(rows, &(&1["status"] in ["refused", "unconfirmed"]))
    }
  end

  defp completeness(pairs, rows) do
    withheld = length(pairs) - @max_witness_rows
    refused = totals(pairs, rows)["refused"]

    %{
      "complete?" => withheld <= 0 and refused == 0,
      "withheld" => max(withheld, 0)
    }
  end

  # -- summaries -------------------------------------------------------------

  defp summary(request, choice, scope) do
    %{
      title:
        "Prepare #{count_label(length(request.pairs), "in-seat setting", "in-seat settings")}",
      detail: "#{choice_label(choice)} · #{request.day_type_label}",
      lines: [
        "Selected on this page · nothing is saved",
        "Checked on every date both trips run",
        "Source digest · #{String.slice(source_digest(scope), 0, 12)}"
      ]
    }
  end

  defp choice_label(:stay_on_board), do: "Stay on board"
  defp choice_label(:must_reboard), do: "Must reboard"

  defp count_label(1, one, _many), do: "1 #{one}"
  defp count_label(count, _one, many), do: "#{count} #{many}"

  # -- evidence -------------------------------------------------------------

  defp evidence(request, checks, result, scope, choice \\ nil) do
    totals = result["totals"]
    complete = result["completeness"]["complete?"]

    %{
      kind: if(choice, do: "in_seat_policy", else: "in_seat_connections"),
      title:
        "#{request.day_type_label} · #{count_label(totals["selected"], "connection", "connections")}",
      total: totals["selected"],
      total_label: "selected connection pairs",
      completeness: if(complete, do: :complete, else: :incomplete),
      completeness_reason: completeness_reason(result),
      facts: facts(request, result, scope, choice),
      source_ref: @source_ref,
      digest: source_digest(scope),
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      # The page renders these rows itself, so it never reads an answer out of the
      # model's reply: they are the same rows the tool result carries.
      rows: Enum.take(card_rows(request.pairs, checks), @max_card_rows),
      exclusions: exclusions(result),
      resources:
        Enum.map(Enum.take(request.pairs, @max_witness_rows), fn pair ->
          state = state_result(check_for(checks, pair))

          %{
            kind: "in_seat_connection",
            id: "#{pair.from_uuid}->#{pair.to_uuid}",
            label:
              "#{pair.from_trip_id} to #{pair.to_trip_id}: #{state.status}" <>
                reason_suffix(state)
          }
        end)
    }
  end

  # The page's own row, keyed the way a LiveView assign reads it. It carries the
  # same values the tool result reports, so nothing on the card is re-derived.
  defp card_rows(pairs, checks) do
    Enum.map(pairs, fn pair ->
      row = pair_result(pair, check_for(checks, pair))

      %{
        from_uuid: row["from_uuid"],
        to_uuid: row["to_uuid"],
        from_trip_id: row["from_trip_id"],
        to_trip_id: row["to_trip_id"],
        status: row["status"],
        reason: row["reason"],
        other_days: row["other_days"]
      }
    end)
  end

  defp facts(request, result, scope, choice) do
    totals = result["totals"]
    shown = result["pairs"]

    [
      %{label: "Day type on screen", value: request.day_type_label},
      %{label: "Connection group", value: request.group_token},
      %{label: "Selected pairs", value: Integer.to_string(totals["selected"])},
      %{label: "Eligible on every date", value: Integer.to_string(totals["eligible"])},
      %{label: "Refused", value: Integer.to_string(totals["refused"])},
      %{label: "Pairs listed", value: "#{result["pairs_shown"]} of #{totals["selected"]}"},
      %{label: "Setting prepared", value: choice && choice_label(choice)},
      %{label: "Refused for want of a successor", value: count_not_next(shown)},
      %{label: "Approved source digest", value: source_digest(scope)}
    ]
    |> Enum.reject(fn fact -> is_nil(fact.value) end)
  end

  defp count_not_next(rows),
    do: Integer.to_string(Enum.count(rows, &(&1["reason"] == "not_next")))

  defp completeness_reason(%{"completeness" => %{"complete?" => true}}), do: nil

  defp completeness_reason(result) do
    totals = result["totals"]

    reasons =
      result["pairs"]
      |> Enum.reject(&(&1["status"] == "eligible"))
      |> Enum.map(&reason_sentence(&1["status"], &1["reason"]))
      |> Enum.uniq()
      |> Enum.sort()

    withheld = result["pairs_omitted"]

    summary =
      "#{totals["eligible"]} of #{totals["selected"]} selected pairs may be set on every date they run" <>
        if(reasons == [], do: ".", else: ": " <> Enum.join(reasons, ", ") <> ".")

    if withheld > 0 do
      summary <> " #{withheld} further selected pairs are counted above but not listed here."
    else
      summary
    end
  end

  defp reason_suffix(%{reason: nil}), do: ""
  defp reason_suffix(%{reason: reason}), do: " (#{reason})"

  defp exclusions(result) do
    withheld = result["pairs_omitted"]

    base =
      for row <- result["pairs"],
          row["status"] != "eligible",
          do:
            "#{row["from_trip_id"]} to #{row["to_trip_id"]}: #{reason_sentence(row["status"], row["reason"])}"

    if withheld > 0 do
      base ++
        [
          "#{withheld} further selected pairs are not listed here; the counts above cover all #{result["totals"]["selected"]}."
        ]
    else
      base
    end
  end

  # The rule's own vocabulary, in the words a person reads: a refusal is never
  # reported as a bare enum the model could paraphrase into eligibility. The
  # reasons are the strings the result already carries, so this table never makes
  # an atom; a reason it does not name keeps the rule's own spelling with its
  # status.
  defp reason_sentence(_status, nil), do: "no exact answer"

  defp reason_sentence(_status, "trip_missing"),
    do: "one of the two trips is not in this service version"

  defp reason_sentence(_status, "no_shared_date"),
    do: "the two trips never run on the same date"

  defp reason_sentence(_status, "no_block"), do: "one of the two trips is in no block"

  defp reason_sentence(_status, "stops_changed"),
    do: "a stored record's stops no longer match the trips"

  defp reason_sentence(_status, "not_next"),
    do: "another trip runs between them on at least one date"

  defp reason_sentence(_status, "next_service_day"),
    do: "the second trip runs the day after the first, not with it"

  defp reason_sentence(_status, "untimed"),
    do: "one of the two trips has no plottable clock or is frequency-based"

  defp reason_sentence(_status, "coupling"),
    do: "the second trip departs before the first one arrives"

  defp reason_sentence(status, reason), do: "#{status} (#{reason})"

  defp identity_label(scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  defp unavailable_message do
    "These connections cannot be read as selected. Ask the person to select them again."
  end

  defp source_digest(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{digest: digest} -> digest
      nil -> "none"
    end
  end
end

defmodule GtfsPlanner.Agents.Packs.InSeatTest do
  @moduledoc """
  Merge evidence (EV-11) for the native in-seat pack through the real composition:
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> `Packs.InSeat` ->
  `Gtfs.check_in_seat_connections/3`, with only the OpenRouter HTTP boundary
  doubled.

  The registry, session, turn loop, dispatch fence, pack, the step 1 snapshot
  admission and the native `Blocking.InSeat.state/2` rule are the shipped ones, so a
  pack that was never registered, a tool that never reached the real check and
  evidence the panel could not trust all fail here rather than passing over a
  hand-built controller.

  Every expected answer is hand-derived from the rule's own order and the fixture's
  dates, not from a second invocation of the module under test:

    * `a` and `b` share block 101 and are consecutive on the Monday day type, but
      trip `X` runs between them on the Tuesday day type, so the pair is refused by
      the full-date rule with that day type, its one date and the intervening trip
      `X` (FH-11). Nothing about the displayed Monday is eligible.
    * `c` and `d` are consecutive in block 202 on every date they run, so the pair
      is eligible and may be prepared.
    * `e` and `f` are consecutive but `f` is frequency-based, `g` and `h` are timed
      but coupled (the second departs before the first arrives) and `i` and `j` run
      on different service days, so each is refused or unconfirmed with its own
      reason rather than reported as eligible.
    * The only two settings that map are an explicit stay and an explicit reboard;
      anything else is one question and prepares nothing.
    * There is no expected row anywhere in the answer: the host rebuilds them from
      fresh native reads, and no model text becomes a write guard.
    * The pack offers no apply, remove or undo tool, and no type 4/5 general CRUD.
    * A missing, deleted or foreign selected trip is refused by
      `authorize_context/1` before any provider request.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_s11 mix test test/gtfs_planner/agents/packs/in_seat_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.InSeat
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip

  # 2026-08-31 is a Monday and 2026-09-01 the Tuesday after it.
  @monday ~D[2026-08-31]
  @tuesday ~D[2026-09-01]

  @group_token "group-101"
  @monday_day_type "Weekday + School"
  @tuesday_day_type "No school + Weekday"

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and the
    # SQL sandbox are both shared.
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    network = build_network()
    built = scope(network, payload(network, [%{from: :c, to: :d}]))

    network
    |> Map.put(:scope, built)
    |> Map.put(:scope_digest, built.resource_context.source_snapshot.digest)
    |> Map.put(:counts, row_counts(network.organization.id))
  end

  describe "the shipped registration" do
    test "the registry names the pack, its two tools and its skill", _context do
      assert Agents.packs()["in_seat"] == InSeat
      assert InSeat.id() == "in_seat"
      assert InSeat.title() == "In-seat helper"

      assert [
               %{name: "inspect_in_seat_connections", parameters: inspect_parameters},
               %{name: "prepare_in_seat_policy", parameters: prepare_parameters}
             ] = InSeat.tools()

      # Nothing may be named in the inspection: no trip, pair, block, date or day.
      assert inspect_parameters["properties"] == %{}
      assert inspect_parameters["additionalProperties"] == false

      # The only declared argument is the person's own explicit setting.
      assert prepare_parameters["required"] == ["choice"]
      assert Map.keys(prepare_parameters["properties"]) == ["choice"]
      assert prepare_parameters["additionalProperties"] == false

      assert InSeat.skill() =~ "inspect_in_seat_connections"
      assert InSeat.skill() =~ "prepare_in_seat_policy"
      refute InSeat.skill() =~ "no in-seat tool is registered"
    end

    test "a version identity opens the conversation", context do
      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []
    end

    test "a conversation with no admitted in-seat source is refused", context do
      bare = scope(context, nil)

      assert {:error, :unavailable} = Agents.open(bare)

      assert {:error, :unavailable} =
               Dispatch.call(InSeat, bare, "inspect_in_seat_connections", "{}")
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> check/3)" do
    test "reports the native full-date answer for the page's own pair UUIDs", context do
      expect_reply(tool_calls_reply([{"call_1", "inspect_in_seat_connections", "{}"}]))
      expect_reply(text_reply("That connection holds on every date it runs."))

      {entry, session, conversation} =
        run_turn(context.scope, "Can riders stay on board across these connections?")

      assert entry.status == :done
      assert entry.activity == ["Checked the in-seat connections"]
      assert entry.prepared == nil
      assert :error == Agents.prepared(session, conversation, entry.id)

      {request, result} = tool_result_with_request()

      assert %{
               "group_token" => @group_token,
               "day_type_key" => @monday_day_type,
               "pairs" => [pair],
               "totals" => %{"selected" => 1, "eligible" => 1, "refused" => 0},
               "completeness" => %{"complete?" => true, "withheld" => 0}
             } = result

      # The pair is named by the page's own UUIDs and the version's own trip ids,
      # and nothing else: no expected row and no model-written setting.
      assert pair["from_uuid"] == context.c.id
      assert pair["to_uuid"] == context.d.id
      assert pair["from_trip_id"] == "c"
      assert pair["to_trip_id"] == "d"
      assert pair["status"] == "eligible"
      assert pair["reason"] == nil
      assert pair["other_days"] == nil
      refute Map.has_key?(result, "expected")
      refute Map.has_key?(result, "choice")
      assert result["source_digest"] == context.scope_digest

      assert [evidence] = entry.evidence
      assert evidence.kind == "in_seat_connections"
      assert evidence.title =~ "connection"
      assert evidence.total == 1
      assert evidence.total_label == "selected connection pairs"
      assert evidence.completeness == :complete
      assert evidence.source_ref == "gtfs_in_seat"
      assert evidence.source_revision == nil
      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.identity == "version:#{context.version.id}"

      assert fact(evidence, "Day type on screen") == @monday_day_type
      assert fact(evidence, "Connection group") == @group_token
      assert fact(evidence, "Eligible on every date") == "1"
      assert fact(evidence, "Refused") == "0"
      assert fact(evidence, "Approved source digest") == context.scope_digest
      refute Enum.any?(evidence.facts, &(&1.label == "Setting prepared"))

      assert [row] = evidence.rows
      assert row.from_trip_id == "c"
      assert row.to_trip_id == "d"
      assert row.status == "eligible"

      assert [%{kind: "in_seat_connection", id: id, label: label}] = evidence.resources
      assert id == "#{context.c.id}->#{context.d.id}"
      assert label =~ "c to d: eligible"
      assert evidence.exclusions == []

      # The tool the model was offered takes no arguments at all.
      assert [function] =
               request["tools"]
               |> Enum.filter(&(&1["function"]["name"] == "inspect_in_seat_connections"))
               |> Enum.map(& &1["function"])

      assert function["parameters"]["properties"] == %{}
      assert function["parameters"]["additionalProperties"] == false

      assert row_counts(context.organization.id) == context.counts
    end

    test "an explicit stay prepares stay_on_board and no expected rows", context do
      expect_reply(
        tool_calls_reply([{"call_1", "prepare_in_seat_policy", ~s({"choice":"stay_on_board"})}])
      )

      expect_reply(text_reply("Prepared; nothing is saved until you confirm it here."))

      {entry, session, conversation} =
        run_turn(context.scope, "Let riders stay on board for these connections.")

      assert entry.status == :done
      assert entry.activity == ["Prepared the in-seat setting"]

      assert {:ok, prepared} = Agents.prepared(session, conversation, entry.id)

      assert %{
               summary: %{title: title, lines: lines},
               command: %{
                 kind: :in_seat_policy,
                 pairs: [%{from_uuid: from_uuid, to_uuid: to_uuid}],
                 choice: :stay_on_board,
                 source_digest: digest
               }
             } = prepared

      assert title =~ "1 in-seat setting"
      assert from_uuid == context.c.id
      assert to_uuid == context.d.id
      assert digest == context.scope_digest

      # The expected rows are the host's own fresh read; a prepared command never
      # carries them, so no earlier answer can become a write guard (CR-3).
      refute Map.has_key?(prepared.command, :expected)
      refute Map.has_key?(prepared.command, :transfer_type)
      refute Map.has_key?(prepared.command, :min_transfer_time)

      assert Enum.any?(lines, &(&1 =~ "nothing is saved"))

      assert %{"choice" => "stay_on_board"} = tool_result()
      assert row_counts(context.organization.id) == context.counts
    end

    test "an explicit reboard prepares must_reboard", context do
      expect_reply(
        tool_calls_reply([{"call_1", "prepare_in_seat_policy", ~s({"choice":"must_reboard"})}])
      )

      expect_reply(text_reply("Prepared; nothing is saved until you confirm it here."))

      {entry, session, conversation} =
        run_turn(context.scope, "These have to be a reboard.")

      assert entry.status == :done

      assert {:ok, %{command: %{choice: :must_reboard}}} =
               Agents.prepared(session, conversation, entry.id)

      assert %{"choice" => "must_reboard"} = tool_result()
      assert row_counts(context.organization.id) == context.counts
    end

    test "any other setting is asked about once and prepares nothing", context do
      for choice <- ["not_stated", "clear", "leave it blank", "both", "whatever you think"] do
        assert {:tool_error, message} =
                 Dispatch.call(
                   InSeat,
                   context.scope,
                   "prepare_in_seat_policy",
                   Jason.encode!(%{"choice" => choice})
                 )

        assert message =~ "stay on board"
        assert message =~ "must reboard"
        assert message =~ "have not prepared anything"
      end

      assert {:tool_error, message} =
               Dispatch.call(InSeat, context.scope, "prepare_in_seat_policy", "{}")

      assert message =~ "Missing required argument: choice"
      assert row_counts(context.organization.id) == context.counts
    end

    test "a shared block that only holds on the displayed day is refused whole-date", context do
      scope = scope(context, payload(context, [%{from: :a, to: :b}]))

      expect_reply(tool_calls_reply([{"call_1", "inspect_in_seat_connections", "{}"}]))
      expect_reply(text_reply("That pair cannot be set on every date."))

      {entry, _session, _conversation} =
        run_turn(scope, "Are these connections eligible?")

      assert %{"pairs" => [pair], "totals" => totals, "completeness" => completeness} =
               tool_result()

      assert totals == %{"selected" => 1, "eligible" => 0, "refused" => 1}
      assert completeness == %{"complete?" => false, "withheld" => 0}

      # The refusal is the other date's own answer: the Tuesday day type, its one
      # date and the trip that actually runs between the two there (FH-11).
      assert pair["from_trip_id"] == "a"
      assert pair["to_trip_id"] == "b"
      assert pair["status"] == "refused"
      assert pair["reason"] == "not_next"

      assert [
               %{
                 "day_type_key" => day_type_key,
                 "day_type_label" => day_type_label,
                 "date_count" => 1,
                 "next_trip_id" => "X"
               }
             ] = pair["other_days"]

      assert day_type_label == @tuesday_day_type
      assert is_binary(day_type_key) and day_type_key != @monday_day_type

      assert [evidence] = entry.evidence
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "0 of 1 selected pairs"
      assert evidence.completeness_reason =~ "another trip runs between them"
      assert fact(evidence, "Refused") == "1"
      assert fact(evidence, "Refused for want of a successor") == "1"

      assert evidence.exclusions == [
               "a to b: another trip runs between them on at least one date"
             ]

      assert row_counts(context.organization.id) == context.counts
    end

    test "a refused pair is never prepared, and nothing is saved", context do
      scope = scope(context, payload(context, [%{from: :a, to: :b}]))

      assert {:tool_error, message} =
               Dispatch.call(
                 InSeat,
                 scope,
                 "prepare_in_seat_policy",
                 ~s({"choice":"stay_on_board"})
               )

      assert message =~ "have not prepared anything"
      assert message =~ "a to b"
      assert message =~ "another trip runs between them"
      assert row_counts(context.organization.id) == context.counts
    end

    test "a frequency-based, coupled or next-service-day pair is surfaced, never inferred",
         context do
      scope =
        scope(
          context,
          payload(context, [
            %{from: :e, to: :f},
            %{from: :g, to: :h},
            %{from: :i, to: :j}
          ])
        )

      expect_reply(tool_calls_reply([{"call_1", "inspect_in_seat_connections", "{}"}]))
      expect_reply(text_reply("Three of them cannot be set."))

      {entry, _session, _conversation} =
        run_turn(scope, "Check the other three connections.")

      assert %{
               "pairs" => [frequency, coupling, next_day],
               "totals" => %{"selected" => 3, "eligible" => 0, "refused" => 3},
               "completeness" => %{"complete?" => false}
             } = tool_result()

      # `f` is frequency-based, so no exact clock decides the rule.
      assert frequency["from_trip_id"] == "e"
      assert frequency["to_trip_id"] == "f"
      assert frequency["status"] == "unconfirmed"
      assert frequency["reason"] == "untimed"
      assert frequency["other_days"] == nil

      # `h` leaves before `g` arrives, so the pair is a coupling rather than a
      # connection.
      assert coupling["from_trip_id"] == "g"
      assert coupling["to_trip_id"] == "h"
      assert coupling["status"] == "unconfirmed"
      assert coupling["reason"] == "coupling"

      # `j` runs the day after `i`, which is a day the rule cannot decide.
      assert next_day["from_trip_id"] == "i"
      assert next_day["to_trip_id"] == "j"
      assert next_day["status"] == "unconfirmed"
      assert next_day["reason"] == "next_service_day"

      assert [evidence] = entry.evidence
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "the second trip runs the day after the first"

      assert evidence.exclusions == [
               "e to f: one of the two trips has no plottable clock or is frequency-based",
               "g to h: the second trip departs before the first one arrives",
               "i to j: the second trip runs the day after the first, not with it"
             ]

      assert row_counts(context.organization.id) == context.counts
    end
  end

  describe "the pack names no writer" do
    test "apply, remove and undo are not reachable", context do
      for name <- [
            "set_in_seat_connection",
            "set_in_seat_connections",
            "remove_in_seat_records",
            "undo_in_seat_change",
            "apply_in_seat_policy",
            "save_in_seat_policy"
          ] do
        assert {:tool_error, message} = Dispatch.call(InSeat, context.scope, name, "{}")
        assert message =~ "Unknown tool"
      end

      assert {:ok, _result, _evidence} =
               Dispatch.call(InSeat, context.scope, "inspect_in_seat_connections", "{}")

      assert row_counts(context.organization.id) == context.counts
    end

    test "no general transfer CRUD and no identity argument reaches the pack", context do
      for arguments <- [
            ~s({"transfer_type":4}),
            ~s({"min_transfer_time":300}),
            ~s({"from_trip_id":"a","to_trip_id":"b"}),
            ~s({"choice":"stay_on_board","organization_id":"00000000-0000-0000-0000-000000000000"})
          ] do
        assert {:tool_error, message} =
                 Dispatch.call(InSeat, context.scope, "prepare_in_seat_policy", arguments)

        assert message == "Unexpected argument: transfer_type" or
                 message == "Unexpected argument: min_transfer_time" or
                 message == "Unexpected argument: from_trip_id" or
                 message == "Unexpected argument: to_trip_id" or
                 message == "Unexpected argument: organization_id"
      end

      assert row_counts(context.organization.id) == context.counts
    end
  end

  describe "the read boundary (authorize_context/1)" do
    test "a trip of another organization in the selection is refused before any request",
         context do
      other = build_network()

      foreign =
        put_in(
          payload(context, [%{from: :c, to: :d}]),
          ["pairs", Access.at(0), "to_uuid"],
          other.d.id
        )

      assert {:error, :unavailable} = Agents.open(scope(context, foreign))

      assert {:error, :unavailable} =
               Dispatch.call(
                 InSeat,
                 scope(context, foreign),
                 "inspect_in_seat_connections",
                 "{}"
               )

      refute_received {:model_request, _request}
    end

    test "a deleted selected trip is refused before any provider request", context do
      Repo.delete!(context.d)

      assert {:error, :unavailable} =
               Dispatch.call(InSeat, context.scope, "inspect_in_seat_connections", "{}")

      refute_received {:model_request, _request}
    end

    test "a selection that is not one the page can admit is refused", context do
      for selected <- [
            payload(context, []),
            Map.delete(payload(context, [%{from: :c, to: :d}]), "group_token"),
            Map.put(payload(context, [%{from: :c, to: :d}]), "day_type_key", "  "),
            Map.put(payload(context, [%{from: :c, to: :d}]), "pairs", [
              %{"from_uuid" => context.c.id}
            ]),
            Map.update!(payload(context, [%{from: :c, to: :d}]), "pairs", fn [pair] ->
              Map.put(pair, "to_uuid", "not-a-uuid")
            end),
            Map.update!(payload(context, [%{from: :c, to: :d}]), "pairs", fn [pair] ->
              Map.put(pair, "to_uuid", pair["from_uuid"])
            end),
            Map.put(payload(context, [%{from: :c, to: :d}]), "schema_version", 2)
          ] do
        assert {:error, :unavailable} = Agents.open(scope(context, selected))
      end

      refute_received {:model_request, _request}
    end

    test "an oversized selection is refused truthfully", context do
      pairs =
        for _index <- 1..501,
            do: %{"from_uuid" => context.c.id, "to_uuid" => context.d.id}

      oversized =
        context
        |> payload([%{from: :c, to: :d}])
        |> Map.put("pairs", pairs)

      assert {:error, :unavailable} = Agents.open(scope(context, oversized))
    end
  end

  ## Helpers

  defp fact(evidence, label) do
    Enum.find_value(evidence.facts, fn fact -> fact.label == label && fact.value end)
  end

  defp run_turn(scope, text) do
    assert {:ok, pid, snapshot} = Agents.open(scope)
    assert :ok = Agents.send_message(pid, text)
    {await_settled(pid), pid, snapshot.conversation_id}
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  defp tool_result do
    {_request, result} = tool_result_with_request()
    result
  end

  defp tool_result_with_request do
    assert_receive {:model_request, request}, 5_000

    case tool_messages(request) do
      [] ->
        tool_result_with_request()

      messages ->
        {request, messages |> List.last() |> Map.fetch!("content") |> Jason.decode!()}
    end
  end

  defp tool_messages(request) do
    Enum.filter(request["messages"] || [], &(&1["role"] == "tool"))
  end

  # -- fixtures ---------------------------------------------------------------

  # The rule's own order, made literal:
  #
  #   * `a` and `b` share block 101 on the Monday day type and are consecutive
  #     there, but trip `X` runs between them on the Tuesday day type;
  #   * `c` and `d` are consecutive in block 202 on every date they run;
  #   * `e` and `f` are consecutive in block 303 and `f` is frequency-based;
  #   * `g` and `h` are timed, and `h` departs before `g` arrives;
  #   * `i` runs on `W` and `j` only on the day after, so the two share no date.
  defp build_network do
    organization = organization_fixture(%{alias: unique_alias()})
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: [@monday, @tuesday]
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SCHOOL",
      name: "School",
      dates: [@monday]
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "NS",
      name: "No school",
      dates: [@tuesday]
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "NEXT",
      name: "Next day",
      dates: [Date.add(@tuesday, 1)]
    })

    a =
      trip(organization, version, route, %{
        trip_id: "a",
        block_id: "101",
        first: "06:00:00",
        last: "07:00:00"
      })

    x =
      trip(organization, version, route, %{
        trip_id: "X",
        service_id: "NS",
        block_id: "101",
        first: "07:05:00",
        last: "08:05:00"
      })

    b =
      trip(organization, version, route, %{
        trip_id: "b",
        block_id: "101",
        first: "08:10:00",
        last: "09:10:00"
      })

    c =
      trip(organization, version, route, %{
        trip_id: "c",
        block_id: "202",
        first: "10:00:00",
        last: "11:00:00"
      })

    d =
      trip(organization, version, route, %{
        trip_id: "d",
        block_id: "202",
        first: "11:10:00",
        last: "12:10:00"
      })

    e =
      trip(organization, version, route, %{
        trip_id: "e",
        block_id: "303",
        first: "13:00:00",
        last: "14:00:00"
      })

    f =
      trip(organization, version, route, %{
        trip_id: "f",
        block_id: "303",
        first: "14:10:00",
        last: "15:10:00"
      })

    frequency_row_fixture(organization.id, version.id, %{trip_id: "f"})

    g =
      trip(organization, version, route, %{
        trip_id: "g",
        block_id: "404",
        first: "16:00:00",
        last: "17:00:00"
      })

    h =
      trip(organization, version, route, %{
        trip_id: "h",
        block_id: "405",
        first: "16:30:00",
        last: "17:30:00"
      })

    i =
      trip(organization, version, route, %{
        trip_id: "i",
        block_id: "505",
        first: "18:00:00",
        last: "19:00:00"
      })

    j =
      trip(organization, version, route, %{
        trip_id: "j",
        service_id: "NEXT",
        block_id: "505",
        first: "19:10:00",
        last: "20:10:00"
      })

    %{
      organization: organization,
      version: version,
      a: a,
      x: x,
      b: b,
      c: c,
      d: d,
      e: e,
      f: f,
      g: g,
      h: h,
      i: i,
      j: j,
      change_log_count: Repo.aggregate(ChangeLog, :count)
    }
  end

  defp trip(organization, version, route, attrs) do
    attrs = Map.new(attrs)

    blocked_trip_fixture(
      organization.id,
      version.id,
      route.route_id,
      attrs
      |> Map.put_new(:service_id, "W")
      |> Map.merge(%{
        first_arrival: Map.get(attrs, :first, "08:00:00"),
        last_arrival: Map.get(attrs, :last, "09:00:00")
      })
    )
  end

  defp unique_alias, do: "inseat-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  # -- the page's admitted payload ------------------------------------------

  defp payload(network, selected) do
    %{
      "schema_version" => 1,
      "group_token" => @group_token,
      "day_type_key" => @monday_day_type,
      "day_type_label" => @monday_day_type,
      "pairs" =>
        Enum.map(selected, fn pair ->
          %{
            "from_uuid" => trip!(network, pair.from).id,
            "to_uuid" => trip!(network, pair.to).id
          }
        end)
    }
  end

  defp trip!(network, key), do: Map.fetch!(network, key)

  defp scope(network, payload) do
    user = user_fixture()
    organization_membership_fixture(user, network.organization)

    resource_context =
      case payload do
        nil ->
          Scope.context({:version, network.version.id})

        admitted ->
          assert {:ok, admitted} =
                   Scope.with_source_snapshot(
                     Scope.context({:version, network.version.id}),
                     %{kind: "in_seat", payload: admitted}
                   )

          admitted
      end

    %Scope{
      organization_id: network.organization.id,
      gtfs_version_id: network.version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "in_seat",
      version_name: network.version.name,
      resource_context: resource_context
    }
  end

  defp row_counts(organization_id) do
    %{
      trips:
        Repo.aggregate(from(t in Trip, where: t.organization_id == ^organization_id), :count),
      transfers:
        Repo.aggregate(from(t in Transfer, where: t.organization_id == ^organization_id), :count),
      calendar_dates:
        Repo.aggregate(
          from(d in CalendarDate, where: d.organization_id == ^organization_id),
          :count
        ),
      change_logs:
        Repo.aggregate(from(l in ChangeLog, where: l.organization_id == ^organization_id), :count)
    }
  end

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

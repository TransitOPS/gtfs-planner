defmodule GtfsPlanner.Agents.Packs.ConnectionsTest do
  @moduledoc """
  Merge evidence (EV-9) for the read-only connections pack through the real
  composition: `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` ->
  `Packs.Connections` -> `Gtfs.ConnectionComparison.compare/4`, with only the
  OpenRouter HTTP boundary doubled.

  The registry, session, turn loop, dispatch fence, pack and the step 6/7 snapshot
  and margin code are the shipped ones, so a pack that was never registered, a
  tool that never reached the comparison and evidence the panel could not trust all
  fail here rather than passing over a hand-built controller.

  Every expected number is hand-derived from the AC-7 case and the GTFS
  reference, not from a second invocation of the module under test:

    * The page admitted route 1 arriving at `CENTRAL-P1` (the loop's first visit)
      at 09:02:00 and route 2 leaving `HARBOR` at 09:08:00, so
      32,880 - 32,520 = 360 seconds are available against the stored 300 second
      minimum, leaving a 60 second margin. The supplied candidate arrives at
      09:07:00, leaving 60 seconds, a -240 second margin and a
      -240 - 60 = -300 delta.
    * A second approved pair at a stop no stored rule covers has no stated
      minimum, so it is unresolved, the totals are incomplete and the evidence
      card says so instead of counting one comparable pair.
    * The tool declares no arguments at all, so a date, a pair or an id the model
      supplies is refused by the dispatch fence, and the pack has no other tool:
      there is nothing to prepare and nothing to apply.
    * A provider failure on the final request ends the turn failed and leaves the
      trips, stop times, transfers and change log exactly as they were.
    * A missing, deleted or other-organization endpoint, and a payload that no
      longer hashes to its admitted digest, are refused by `authorize_context/1`
      before any provider request.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_s9 mix test test/gtfs_planner/agents/packs/connections_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Connections
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ConnectionComparison
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip

  # 2026-11-26 is a Thursday, which is the date `EXCEPTION` adds for both trips.
  @service_date ~D[2026-11-26]
  @service_date_iso "2026-11-26"
  @station "CENTRAL"
  @platform "CENTRAL-P1"
  @harbor "HARBOR"
  @away "AWAY"
  @stored_minimum 300
  @zone "America/New_York"
  @candidate_approval "reviewed-by-transitops"

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the HTTP boundary.
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
    payload = approved_payload(network)

    network
    |> Map.put(:base_digest, payload["base_digest"])
    |> Map.put(:scope, scope(network, payload))
    |> Map.put(:counts, row_counts(network.organization.id))
  end

  describe "the shipped registration" do
    test "the registry names the pack, its one argument-free tool and its skill", _context do
      assert Agents.packs()["connections"] == Connections
      assert Connections.id() == "connections"
      assert Connections.title() == "Connection helper"

      assert [%{name: "compare_connection_margins"} = tool] = Connections.tools()
      assert tool.parameters["properties"] == %{}
      assert tool.parameters["additionalProperties"] == false

      # Nothing may be named in a call: no date, pair, minimum, candidate or id.
      assert Enum.all?(Connections.tools(), &(Map.keys(&1.parameters["properties"]) == []))

      assert Connections.skill() =~ "compare_connection_margins"
      refute Connections.skill() =~ "no comparison tool is registered"
    end

    test "a route identity opens the conversation and a bare one is refused", context do
      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []

      bare = %{context.scope | resource_context: Scope.context(nil)}
      assert {:error, :unavailable} = Agents.open(bare)
    end

    test "a conversation with no admitted connections source is refused", context do
      bare = scope(context, nil)
      assert {:error, :unavailable} = Agents.open(bare)

      assert {:error, :unavailable} =
               Dispatch.call(Connections, bare, "compare_connection_margins", "{}")
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> compare/4)" do
    test "renders the official arithmetic in trusted evidence and writes nothing", context do
      expect_reply(tool_calls_reply([{"call_1", "compare_connection_margins", "{}"}]))
      expect_reply(text_reply("Yes, with 60 seconds of slack."))

      {entry, session, conversation} =
        run_turn(context.scope, "Can riders make the connection I approved?")

      assert entry.status == :done
      assert entry.activity == ["Compared the approved connections"]
      assert entry.prepared == nil
      assert :error == Agents.prepared(session, conversation, entry.id)

      # 09:08:00 - 09:02:00 = 360 seconds available against the stored minimum of
      # 300, and the supplied 09:07:00 candidate leaves -240 and a -300 delta.
      # The tool result and the request that carried it, so the schema the model
      # was offered is read from the same request, not a second `assert_receive`.
      {request, result} = tool_result_with_request()

      assert %{
               "service_date" => @service_date_iso,
               "pairs" => [pair],
               "totals" => %{
                 "requested" => 1,
                 "comparable" => 1,
                 "unresolved" => 0,
                 "not_applicable" => 0,
                 "prohibited" => 0,
                 "meets_stated_minimum" => 1,
                 "below_stated_minimum" => 1
               },
               "completeness" => %{"complete?" => true, "withheld" => 0}
             } = result

      assert pair["id"] == "central-to-harbor"
      assert pair["status"] == "comparable"
      assert pair["reason"] == nil
      assert pair["current"]["arrival"] == "09:02:00"
      assert pair["current"]["departure"] == "09:08:00"
      assert pair["current"]["available_seconds"] == 360
      assert pair["current"]["margin_seconds"] == 60
      assert pair["current"]["margin_status"] == "meets_stated_minimum"
      assert pair["candidate"]["arrival"] == "09:07:00"
      assert pair["candidate"]["available_seconds"] == 60
      assert pair["candidate"]["margin_seconds"] == -240
      assert pair["candidate"]["margin_status"] == "below_stated_minimum"
      assert pair["delta_seconds"] == -300

      # The minimum is stated with the stored rule that supplied it, not with a
      # number the model could have written.
      assert pair["minimum"]["origin"] == "stored"
      assert pair["minimum"]["seconds"] == @stored_minimum
      assert pair["minimum"]["status"] == "resolved"
      assert pair["minimum"]["provenance"]["kind"] == "stored_best"
      assert pair["minimum"]["provenance"]["transfer_id"] == context.stored.id
      assert pair["minimum"]["provenance"]["revision"]

      # The candidate is bound to the snapshot the person approved, and reported
      # as the external supplied evidence it is.
      assert %{
               "candidate" => %{
                 "origin" => "supplied",
                 "evidence" => "external_exact_supplied",
                 "approval" => @candidate_approval,
                 "supplied_pairs" => ["central-to-harbor"]
               }
             } = result

      assert [evidence] = entry.evidence
      assert evidence.kind == "connection_comparison"
      assert evidence.title == "Connections for #{@service_date_iso}"
      assert evidence.total == 1
      assert evidence.total_label == "approved connection pairs"
      assert evidence.completeness == :complete
      assert evidence.source_ref == "gtfs_connections"
      assert evidence.source_revision == nil
      assert evidence.scope.organization_id == context.organization.id
      assert evidence.scope.identity == "route:#{context.from_route.id}"

      assert fact(evidence, "Comparable") == "1"
      assert fact(evidence, "Unresolved") == "0"
      assert fact(evidence, "Meets the stated minimum") == "1"
      assert fact(evidence, "Below the stated minimum") == "1"
      assert fact(evidence, "Compared snapshot digest") == context.base_digest
      assert fact(evidence, "Supplied candidate pairs") == "1"

      assert [%{kind: "connection_pair", id: "central-to-harbor", label: label}] =
               evidence.resources

      assert label =~ "central-to-harbor"
      assert evidence.exclusions == []

      # The tool the model was offered takes no arguments at all.
      assert [function] =
               request["tools"]
               |> Enum.filter(&(&1["function"]["name"] == "compare_connection_margins"))
               |> Enum.map(& &1["function"])

      assert function["parameters"]["properties"] == %{}
      assert function["parameters"]["additionalProperties"] == false

      assert row_counts(context.organization.id) == context.counts
    end

    test "an unresolved pair is reported as unresolved with its own reason", context do
      # `AWAY` is covered by no stored rule, so this version states no minimum for
      # the pair and the comparison has nothing exact to compute.
      scope = scope(context, payload_with(context, ["central-to-harbor", "away-uncovered"]))

      expect_reply(tool_calls_reply([{"call_1", "compare_connection_margins", "{}"}]))
      expect_reply(text_reply("One pair has no stated minimum."))

      {entry, _session, _conversation} =
        run_turn(scope, "Compare both connections I approved.")

      assert %{
               "pairs" => [_, unresolved],
               "totals" => %{"requested" => 2, "comparable" => 1, "unresolved" => 1},
               "completeness" => %{"complete?" => false, "withheld" => 1}
             } = tool_result()

      assert unresolved["id"] == "away-uncovered"
      assert unresolved["status"] == "unresolved"
      assert unresolved["reason"] == "no_stated_minimum"
      assert unresolved["current"] == nil
      assert unresolved["delta_seconds"] == nil

      assert [evidence] = entry.evidence
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "Only 1 of 2"
      assert evidence.completeness_reason =~ "no_stated_minimum"
      assert fact(evidence, "Unresolved") == "1"
      assert evidence.exclusions == ["away-uncovered: no_stated_minimum"]
      assert row_counts(context.organization.id) == context.counts
    end

    test "a provider failure on the final request writes nothing", context do
      expect_reply(tool_calls_reply([{"call_1", "compare_connection_margins", "{}"}]))
      expect_response(500, %{"error" => %{"message" => "provider unavailable"}})

      {entry, session, conversation} =
        run_turn(context.scope, "Can riders make the connection I approved?")

      assert entry.status == :failed
      assert entry.prepared == nil
      assert :error == Agents.prepared(session, conversation, entry.id)

      # The comparison read before the failure, and it wrote nothing: the same
      # trips, stop times, transfers and change log as before the turn.
      assert row_counts(context.organization.id) == context.counts
      assert Repo.aggregate(ChangeLog, :count) == context.change_log_count
      assert Repo.get!(Transfer, context.stored.id).min_transfer_time == @stored_minimum
    end
  end

  describe "the dispatch fence and the pack's own refusals" do
    test "a date, pair or id argument never reaches the pack", context do
      for arguments <- [
            ~s({"service_date":"2026-12-01"}),
            ~s({"pair_id":"central-to-harbor"}),
            ~s({"minimum_seconds":600}),
            ~s({"candidate":{"arrival":"09:07:00"}})
          ] do
        assert {:tool_error, message} =
                 Dispatch.call(
                   Connections,
                   context.scope,
                   "compare_connection_margins",
                   arguments
                 )

        assert message =~ "Unexpected argument"
      end
    end

    test "the pack offers no preparation and no write", context do
      for name <- [
            "prepare_connection_changes",
            "apply_connection_changes",
            "set_min_transfer_time",
            "save_connections"
          ] do
        assert {:tool_error, message} = Dispatch.call(Connections, context.scope, name, "{}")
        assert message =~ "Unknown tool"
      end

      assert {:ok, result, _evidence} =
               Dispatch.call(Connections, context.scope, "compare_connection_margins", "{}")

      # The answer is an answer: there is no command key for a page to apply.
      refute Map.has_key?(result, "command")
      assert row_counts(context.organization.id) == context.counts
    end

    test "a candidate bound to a snapshot that has changed is refused as stale", context do
      # The version's stored minimum moves after the person approved the candidate.
      Repo.update_all(
        from(t in Transfer, where: t.id == ^context.stored.id),
        set: [min_transfer_time: 900]
      )

      assert {:tool_error, message} =
               Dispatch.call(Connections, context.scope, "compare_connection_margins", "{}")

      assert message =~ "changed since the person approved them"
      assert context.base_digest != current_snapshot_digest(context)
    end

    test "a payload whose candidate names two approvals is refused", context do
      scope =
        scope(
          context,
          Map.update!(approved_payload(context), "candidates", fn [_only | _rest] ->
            [
              %{
                "pair_id" => "central-to-harbor",
                "origin" => "supplied",
                "arrival" => "09:07:00",
                "departure" => "09:08:00",
                "approval" => "reviewed-by-transitops"
              },
              %{
                "pair_id" => "away-uncovered",
                "origin" => "supplied",
                "arrival" => "09:07:00",
                "departure" => "09:08:00",
                "approval" => "reviewed-by-someone-else"
              }
            ]
          end)
        )

      assert {:error, :unavailable} = Agents.open(scope)
    end
  end

  describe "the read boundary (authorize_context/1)" do
    test "a missing endpoint is refused before any provider request", context do
      payload = approved_payload(context)

      missing =
        put_in(payload, ["pairs", Access.at(0), "to", "trip_id"], Ecto.UUID.generate())

      assert {:error, :unavailable} = Agents.open(scope(context, missing))

      assert {:error, :unavailable} =
               Dispatch.call(
                 Connections,
                 scope(context, missing),
                 "compare_connection_margins",
                 "{}"
               )

      refute_received {:model_request, _request}
    end

    test "a deleted endpoint is refused before any provider request", context do
      Repo.delete_all(
        from(s in StopTime,
          where: s.gtfs_version_id == ^context.version.id and s.trip_id == "R2-0908"
        )
      )

      Repo.delete!(context.departure_trip)

      assert {:error, :unavailable} =
               Dispatch.call(Connections, context.scope, "compare_connection_margins", "{}")

      refute_received {:model_request, _request}
    end

    test "an endpoint in another organization is refused before any provider request", context do
      other = build_network()

      payload =
        put_in(
          approved_payload(context),
          ["pairs", Access.at(0), "to", "trip_id"],
          other.departure_trip.id
        )

      assert {:error, :unavailable} = Agents.open(scope(context, payload))

      # Same refusal as a route the person did not approve in this version.
      unapproved =
        put_in(
          approved_payload(context),
          ["pairs", Access.at(0), "to", "route_id"],
          other.to_route.id
        )

      assert {:error, :unavailable} = Agents.open(scope(context, unapproved))
      refute_received {:model_request, _request}
    end

    test "a payload that no longer hashes to its digest is refused", context do
      assert %Scope{resource_context: %{source_snapshot: %{payload: payload, digest: digest}}} =
               context.scope

      replaced =
        Map.update!(payload, "service_date", fn _date -> "2026-12-01" end)

      tampered = %{
        context.scope
        | resource_context: %{
            context.scope.resource_context
            | source_snapshot: %{kind: "connections", payload: replaced, digest: digest}
          }
      }

      # The digest is the scope module's own hash of the admitted payload, so a
      # payload replaced after admission is refused there before the pack reads it.
      assert {:error, :unavailable} = Scope.authorized_context(tampered)

      assert {:error, :unavailable} =
               Dispatch.call(Connections, tampered, "compare_connection_margins", "{}")

      refute_received {:model_request, _request}
    end
  end

  ## Helpers

  defp fact(evidence, label) do
    Enum.find_value(evidence.facts, fn fact -> fact.label == label && fact.value end)
  end

  defp current_snapshot_digest(context) do
    {:ok, snapshot} =
      ConnectionComparison.load(
        %{organization_id: context.organization.id, gtfs_version_id: context.version.id},
        pair_requests(context, ["central-to-harbor"]),
        @service_date
      )

    snapshot.digest
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

  # The literal A37 network: a loop whose first visit to the platform arrives at
  # 09:02:00, a route leaving the harbor at 09:08:00, and one stored type 2 rule
  # stating a 300 second minimum across the station's coverage.
  defp build_network do
    organization = organization_fixture(%{alias: unique_alias()})
    version = gtfs_version_fixture(organization.id)

    agency =
      agency_fixture(organization.id, version.id, %{
        agency_id: "MAIN",
        agency_timezone: @zone
      })

    from_route =
      route_fixture(organization.id, version.id, %{route_id: "R1", agency_id: agency.agency_id})

    to_route =
      route_fixture(organization.id, version.id, %{route_id: "R2", agency_id: agency.agency_id})

    station_fixture(organization.id, version.id, @station)
    child_stop_fixture(organization.id, version.id, @station, %{stop_id: @platform})
    stop_fixture(organization.id, version.id, %{stop_id: @harbor})
    stop_fixture(organization.id, version.id, %{stop_id: @away})

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "EXCEPTION",
      date: @service_date,
      exception_type: 1
    })

    arrival_trip =
      timed_trip(organization.id, version.id, "R1", "R1-0902", [
        {@platform, 1, "09:02:00"},
        {@platform, 5, "09:52:00"}
      ])

    departure_trip =
      timed_trip(organization.id, version.id, "R2", "R2-0908", [
        {@harbor, 2, "09:08:00"}
      ])

    away_trip =
      timed_trip(organization.id, version.id, "R1", "R1-AWAY", [
        {@away, 1, "09:02:00"}
      ])

    stored =
      transfer_fixture(organization.id, version.id, %{
        from_stop_id: @station,
        to_stop_id: @harbor,
        transfer_type: 2,
        min_transfer_time: @stored_minimum
      })

    %{
      organization: organization,
      version: version,
      from_route: from_route,
      to_route: to_route,
      arrival_trip: arrival_trip,
      departure_trip: departure_trip,
      away_trip: away_trip,
      stored: stored,
      change_log_count: Repo.aggregate(ChangeLog, :count)
    }
  end

  defp timed_trip(organization_id, version_id, route_id, trip_id, stops) do
    trip =
      trip_fixture(organization_id, version_id, route_id, %{
        trip_id: trip_id,
        service_id: "EXCEPTION",
        direction_id: 0
      })

    Enum.each(stops, fn {stop_id, sequence, time} ->
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end)

    trip
  end

  defp unique_alias, do: "connpack-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp station_fixture(organization_id, version_id, stop_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: "Central Station",
      location_type: 1
    })
  end

  # -- the page's admitted payload ------------------------------------------

  defp payload_with(context, pair_ids) do
    Map.merge(base_payload(context), %{
      "pairs" => Enum.map(pair_ids, &pair_payload(context, &1)),
      "base_digest" => base_digest(context, pair_ids)
    })
  end

  defp approved_payload(context), do: payload_with(context, ["central-to-harbor"])

  # The page read the pairs first and admitted the digest it was read at, so the
  # candidate the person approved is bound to those exact rows.
  defp base_digest(context, pair_ids) do
    {:ok, snapshot} =
      ConnectionComparison.load(
        %{organization_id: context.organization.id, gtfs_version_id: context.version.id},
        pair_requests(context, pair_ids),
        @service_date
      )

    snapshot.digest
  end

  defp base_payload(context) do
    %{
      "schema_version" => 1,
      "service_date" => @service_date_iso,
      "approved_route_ids" => [context.from_route.route_id, context.to_route.route_id],
      "pairs" => [],
      "candidates" => [
        %{
          "pair_id" => "central-to-harbor",
          "origin" => "supplied",
          "arrival" => "09:07:00",
          "departure" => "09:08:00",
          "approval" => @candidate_approval
        }
      ],
      "trips" => ["R1-0902", "R2-0908"]
    }
  end

  defp pair_payload(context, "central-to-harbor"),
    do: pair_request(context, "central-to-harbor") |> encode_pair()

  defp pair_payload(context, "away-uncovered"),
    do: pair_request(context, "away-uncovered") |> encode_pair()

  defp pair_request(context, "central-to-harbor") do
    %{
      id: "central-to-harbor",
      from: endpoint(context.from_route, context.arrival_trip, @platform, 1),
      to: endpoint(context.to_route, context.departure_trip, @harbor, 2),
      minimum: %{origin: :stored}
    }
  end

  defp pair_request(context, "away-uncovered") do
    %{
      id: "away-uncovered",
      from: endpoint(context.from_route, context.away_trip, @away, 1),
      to: endpoint(context.to_route, context.departure_trip, @harbor, 2),
      minimum: %{origin: :stored}
    }
  end

  defp pair_requests(context, pair_ids), do: Enum.map(pair_ids, &pair_request(context, &1))

  # The host JSON shape, mapped key by key: the pack decodes strings, never atoms.
  defp encode_pair(pair) do
    %{
      "id" => pair.id,
      "from" => encode_endpoint(pair.from),
      "to" => encode_endpoint(pair.to),
      "minimum" => %{"origin" => "stored"}
    }
  end

  defp encode_endpoint(endpoint) do
    %{
      "route_id" => endpoint.route_id,
      "trip_id" => endpoint.trip_id,
      "stop_id" => endpoint.stop_id,
      "stop_sequence" => endpoint.stop_sequence,
      "service_date_offset" => endpoint.service_date_offset
    }
  end

  defp endpoint(route, trip, stop_id, sequence) do
    %{
      route_id: route.id,
      trip_id: trip.id,
      stop_id: stop_id,
      stop_sequence: sequence,
      service_date_offset: 0
    }
  end

  defp scope(context, payload) do
    user = user_fixture()
    organization_membership_fixture(user, context.organization)

    resource_context =
      case payload do
        nil ->
          Scope.context({:route, context.from_route.id})

        admitted ->
          assert {:ok, admitted} =
                   Scope.with_source_snapshot(
                     Scope.context({:route, context.from_route.id}),
                     %{kind: "connections", payload: admitted}
                   )

          admitted
      end

    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "connections",
      version_name: context.version.name,
      resource_context: resource_context
    }
  end

  defp row_counts(organization_id) do
    %{
      trips:
        Repo.aggregate(from(t in Trip, where: t.organization_id == ^organization_id), :count),
      stop_times:
        Repo.aggregate(from(s in StopTime, where: s.organization_id == ^organization_id), :count),
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

  defp expect_response(status, payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(payload))
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

defmodule GtfsPlanner.Agents.Packs.DatedChangesTest do
  @moduledoc """
  Merge evidence (EV-6) for the dated-changes pack through the real composition:
  `Agents.open/1` -> `Session` -> `Turn` -> `Dispatch` -> `Packs.DatedChanges`
  -> `Gtfs.DatedChangePlan.prepare/2`, with only the OpenRouter HTTP boundary
  doubled.

  The registry, session, turn loop, dispatch fence, pack and domain read are the
  shipped ones, so a pack that was never registered, a tool that never reached
  `prepare/2` and evidence that never reached the entry all fail here rather than
  passing over a hand-built controller. What the model actually read is asserted
  on the tool message of the next provider request, so the rows the pack sent and
  the card the panel will render come from the same read.

  The fixture is the Harbor Transit dataset, and every expectation is derived by
  hand from its rows rather than from a second call into the module under test:

    * `WEEKDAY` is the 2026 weekday calendar with 2026-11-11 removed, so its
      complete original D is the 260 weekdays of 2026 less that one date. The
      accepted interval 2026-11-02..2026-11-13 holds nine of them - Nov 2, 3, 4,
      5, 6, 9, 10, 12 and 13 - so 251 dates stay normal.
    * `H8-1` on `WEEKDAY` and `H8-3` on `SPECIAL` are the two selected trips, so
      two trips over nine affected dates each is eighteen affected trip-date
      pairs and 502 unchanged ones.
    * `H8-2` is an unselected same-block peer of `H8-1` and `H12-1` is another
      route's trip on the same calendar, so the plan has two unaffected calendar
      users and neither is in the change.
    * The six transfer rules include the general type 4 and type 5 rows, and
      every row keeps its stored selectors plus the conservative applicability
      marker.

  ## What these cases do not establish

  Nothing here establishes the loader's caps, the concurrent snapshot boundary,
  the date partition or the clock projection on their own: those are EV-2 to
  EV-5's subjects, and this file consumes what `prepare/2` composes from them.
  No automated gate has run yet; branch review executes this file.
  """
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.DatedChanges
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.ConcurrencyHelpers
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.BlockingSetting
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.DatedChangePlan
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response below replaces only the HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  # A turn here is a real `prepare/2` snapshot read plus two OpenRouter round
  # trips, and this host's PostgreSQL is shared, so the budget a turn needs is
  # the environment's, not a fixed five seconds.
  @agent_turn_timeout 60_000

  @first ~D[2026-11-02]
  @last ~D[2026-11-13]
  @holiday ~D[2026-11-11]
  @central "CENTRAL"
  @harbor "HARBOR"
  @depot "DEPOT"
  @task_timeout 30_000
  @witnesses 20

  @nine ~w(2026-11-02 2026-11-03 2026-11-04 2026-11-05 2026-11-06 2026-11-09 2026-11-10
           2026-11-12 2026-11-13)

  # The exact answer keys the plan tool returns. Nothing here is an operation:
  # there is no command, callback, token or pending-change key to grow later
  # without failing this list (CR-1, INV-1).
  @result_keys [
    "computation",
    "dependency_digest",
    "execution_stages",
    "intent",
    "partitions",
    "planning_only",
    "projected_clocks",
    "route_id",
    "timing",
    "totals",
    "unaffected_trips",
    "unresolved"
  ]

  @forbidden_keys ~w(apply callback command operations prepared_command token)

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is not in this process's callers, so the Req.Test plug and
    # the SQL sandbox are both shared (`async: false`).
    Req.Test.set_req_test_to_shared()
    supervisor = start_supervised!({Task.Supervisor, []})
    ensure_turn_supervisor()
    track_sessions()

    harbor = harbor_scope(supervisor)

    %{
      harbor: harbor,
      scope: snapshot_context(harbor, "dated_changes"),
      accepted: accepted_source(harbor, nil),
      supervisor: supervisor
    }
  end

  describe "the shipped registration" do
    test "the registry names the pack beside the existing ones", context do
      assert Agents.packs()["dated_changes"] == DatedChanges
      assert Agents.packs()["service_queries"] == GtfsPlanner.Agents.Packs.ServiceQueries
      assert Agents.packs()["calendars"] == GtfsPlanner.Agents.Packs.Calendars

      assert DatedChanges.id() == "dated_changes"
      assert DatedChanges.title() == "Dated change planner"

      assert Enum.map(DatedChanges.tools(), & &1.name) == [
               "inspect_dated_change_scope",
               "inspect_dated_change_dependencies",
               "prepare_dated_change_plan"
             ]

      # Every tool is an empty closed object: the selection, dates, shift and
      # approval are server snapshot inputs, not arguments.
      for tool <- DatedChanges.tools() do
        assert tool.parameters == %{
                 "type" => "object",
                 "properties" => %{},
                 "required" => [],
                 "additionalProperties" => false
               }
      end

      assert DatedChanges.skill() =~ "prepare_dated_change_plan"
      assert DatedChanges.skill() =~ "cannot change anything"

      # A route-bound conversation with an accepted source opens its session.
      assert {:ok, session, snapshot} = Agents.open(context.scope)
      assert is_pid(session)
      assert snapshot.entries == []

      # No accepted source and no attached route are the same refusal, and it
      # is refused before any conversation exists.
      assert {:error, :unavailable} = Agents.open(version_scope(context.harbor))
      assert {:error, :unavailable} = Agents.open(no_snapshot_scope(context.harbor))
    end
  end

  describe "the composed turn (Agents -> Session -> Dispatch -> pack -> prepare/2)" do
    test "the plan tool answers from the real report and carries its evidence", context do
      expect_reply(tool_calls_reply([{"call_1", "prepare_dated_change_plan", "{}"}]))

      expect_reply(text_reply("Nine dates in that window would move; nothing has been saved."))

      before = scoped_content(context.harbor)
      entry = run_turn(context.scope, "Which dates would this shift affect?")

      assert entry.status == :done
      assert entry.activity == ["Prepared the dated change plan"]

      result = tool_result()

      assert result["planning_only"] == true
      assert result["route_id"] == "H8"
      assert result["computation"] == "complete"
      assert result["timing"] == "complete"

      # The accepted intent is echoed from the snapshot the host froze, and the
      # selection is an exact count rather than a second list to reason about.
      assert result["intent"] == %{
               "first_date" => "2026-11-02",
               "last_date" => "2026-11-13",
               "delta_seconds" => 300,
               "selected_trip_count" => 2,
               "approval_note_recorded" => true,
               "source_label" => "Winter review",
               "input_digest" => context.accepted.input_digest
             }

      # The exact totals are the report's own, and the nine affected dates of
      # the fixture's `WEEKDAY` calendar are listed in full because nine is
      # under the sample bound.
      assert result["totals"] == %{
               "selected_trips" => 2,
               "affected_trip_dates" => 18,
               "unchanged_trip_dates" => 502,
               "unaffected_calendar_users" => 2
             }

      assert [special, weekday] = result["partitions"]
      assert weekday["service_id"] == "WEEKDAY"
      assert weekday["dates"]["affected"] == @nine
      assert weekday["dates"]["affected_total"] == 9
      assert weekday["dates"]["affected_shown"] == 9
      assert weekday["dates"]["affected_truncated"] == false
      assert weekday["dates"]["original_total"] == 260
      assert weekday["dates"]["unchanged_total"] == 251
      assert special["service_id"] == "SPECIAL"

      # The removed holiday is in none of the shown dates.
      refute "2026-11-11" in (weekday["dates"]["original"] ++ weekday["dates"]["affected"])

      # The two unselected users of the touched calendars are named and counted,
      # never folded into the change.
      assert result["unaffected_trips"]["total"] == 2

      assert Enum.sort(result["unaffected_trips"]["trip_ids"]) ==
               Enum.sort([context.harbor.peer.id, context.harbor.other.id])

      # Every execution stage is foundation-missing, and nothing in the result
      # is a command, a callback or a token.
      assert Enum.map(result["execution_stages"], & &1["stage"]) == [
               "partition_reassignment",
               "temporary_identity_overlap",
               "block_transfer_lineage",
               "partial_save_reconciliation"
             ]

      assert Enum.all?(result["execution_stages"], &(&1["status"] == "foundation_missing"))
      assert Enum.all?(result["execution_stages"], &(&1["affected_id_count"] >= 1))

      # No key anywhere in the answer is a command, a callback or a token, and
      # the turn itself settled no prepared proposal for the host to render.
      assert Enum.sort(Map.keys(result)) == Enum.sort(@result_keys)

      for value <- Map.values(result) do
        refute is_map(value) and Enum.any?(Map.keys(value), &(&1 in @forbidden_keys))
      end

      # The turn settled no prepared proposal for the host to render.
      assert entry.prepared == nil

      # The card's counts are the server's counts over the same rows.
      assert [evidence] = entry.evidence
      assert evidence.kind == "dated_change_plan"
      assert evidence.total == 18
      assert evidence.total_label == "affected trip-dates"
      assert evidence.completeness == :complete
      assert evidence.completeness_reason == nil
      assert evidence.source_ref == "gtfs_dated_change_plan"
      assert evidence.digest == result["dependency_digest"]
      assert evidence.source_revision == nil

      assert evidence.scope.organization_id == context.harbor.organization.id
      assert evidence.scope.gtfs_version_id == context.harbor.version.id
      assert evidence.scope.identity == "route:#{context.harbor.route.id}"

      assert Enum.map(evidence.resources, & &1.id) == ["H8", "SPECIAL", "WEEKDAY"]

      assert Enum.find(evidence.facts, &(&1.label == "Accepted date range")).value ==
               "2026-11-02 to 2026-11-13"

      assert Enum.find(evidence.facts, &(&1.label == "Exact timing")).value == "complete"

      # Reading the plan changed no calendar, trip, timing, block, transfer, run
      # or audit row.
      assert scoped_content(context.harbor) == before
    end

    test "the scope tool reports the accepted plan without a dependency listing", context do
      expect_reply(tool_calls_reply([{"call_1", "inspect_dated_change_scope", "{}"}]))
      expect_reply(text_reply("This covers Nov 2 to Nov 13 on two selected trips."))

      entry = run_turn(context.scope, "What does the accepted change cover?")

      assert entry.activity == ["Checked the accepted plan"]
      result = tool_result()

      assert result["totals"]["selected_trips"] == 2
      assert Enum.map(result["services"], & &1["service_id"]) == ["SPECIAL", "WEEKDAY"]
      assert Enum.map(result["services"], & &1["affected_date_count"]) == [9, 9]

      assert [evidence] = entry.evidence
      assert evidence.kind == "dated_change_scope"
      assert evidence.total == 2
      assert evidence.total_label == "selected trips"
      assert evidence.source_revision == nil
    end

    test "the dependency tool reports every category with its exact total beside a sample",
         context do
      expect_reply(tool_calls_reply([{"call_1", "inspect_dated_change_dependencies", "{}"}]))

      expect_reply(
        text_reply("Two other trips share those calendars and six transfer rules apply.")
      )

      before = scoped_content(context.harbor)
      entry = run_turn(context.scope, "What else does this change touch?")

      assert entry.activity == ["Read the change's dependencies"]
      result = tool_result()

      categories = Map.new(result["categories"], &{&1["category"], &1})

      assert Enum.sort(Map.keys(categories)) ==
               Enum.sort([
                 "affected_services",
                 "block_attributes",
                 "blocking_settings",
                 "route_operating_settings",
                 "same_block_trips",
                 "stop_incidence",
                 "transfers",
                 "trip_runs",
                 "trip_selectors"
               ])

      # Six transfer rules of type 0..5, including the general in-seat rules,
      # all disclosed as review candidates rather than as connections.
      transfers = categories["transfers"]
      assert transfers["total"] == 6
      assert transfers["shown"] == 6
      assert transfers["truncated"] == false
      assert transfers["sample_label"] == "Showing all 6."

      assert transfers["rows"] |> Enum.map(& &1["transfer_type"]) |> Enum.sort() == [
               0,
               1,
               2,
               3,
               4,
               5
             ]

      assert Enum.all?(
               transfers["rows"],
               &(&1["applicability"] == "conservative_review_candidate")
             )

      in_seat = Enum.find(transfers["rows"], &(&1["transfer_type"] == 5))
      assert in_seat["from_trip_id"] == "H8-1"
      assert in_seat["to_trip_id"] == "H8-2"
      assert in_seat["from_route_id"] == nil

      # The same-block peer and its successor-candidate flag survive the
      # projection; the other route's trip is not a block peer.
      same_block = categories["same_block_trips"]
      assert same_block["total"] == 2
      assert Enum.map(same_block["rows"], & &1["trip_ref"]) == ["H8-1", "H8-2"]
      assert Enum.all?(same_block["rows"], &(&1["successor_candidate"] == true))
      assert Enum.all?(same_block["rows"], &(&1["block_id"] == "B1"))

      assert categories["trip_selectors"]["total"] == 2
      assert categories["block_attributes"]["total"] == 1
      assert categories["blocking_settings"]["total"] == 1
      assert categories["route_operating_settings"]["total"] == 1
      assert categories["trip_runs"]["total"] == 2
      assert categories["affected_services"]["total"] == 2

      # Three stops are called by the two selected trips between them.
      assert categories["stop_incidence"]["total"] == 3

      assert result["dependency_row_total"] ==
               Enum.sum(Enum.map(result["categories"], & &1["total"]))

      assert [evidence] = entry.evidence
      assert evidence.kind == "dated_change_dependencies"
      assert evidence.total == result["dependency_row_total"]
      assert evidence.total_label == "dependency rows"
      assert evidence.source_revision == nil

      assert Enum.find(evidence.facts, &(&1.label == "Transfer rules listed for review")).value ==
               "6"

      assert scoped_content(context.harbor) == before
    end
  end

  describe "the fence refuses what the pack must not be asked" do
    test "a model-supplied argument never reaches the pack", context do
      for arguments <- [
            ~s({"trip_ids":["#{context.harbor.other.id}"]}),
            ~s({"route_id":"H8"}),
            ~s({"first_date":"2026-11-02"}),
            ~s({"delta_seconds":300})
          ] do
        assert {:tool_error, message} =
                 Dispatch.call(
                   DatedChanges,
                   context.scope,
                   "prepare_dated_change_plan",
                   arguments
                 )

        assert message =~ "Unexpected argument"
      end
    end

    test "an apply-shaped tool name is not a tool this pack has", context do
      for name <- [
            "apply_dated_change_plan",
            "prepare_dated_change_command",
            "commit_dated_change",
            "save_dated_change"
          ] do
        assert {:tool_error, message} = Dispatch.call(DatedChanges, context.scope, name, "{}")
        assert message == "Unknown tool: " <> name
      end
    end

    test "the pack returns no prepared command for any of its tools", context do
      for tool <- DatedChanges.tools() do
        assert {:ok, result, %{} = evidence} = DatedChanges.call(tool.name, %{}, context.scope)

        # The `{:prepared, ...}` transport is the only other shape `Dispatch`
        # accepts, and a prepared result carries a `command` this pack must never
        # build.
        refute Map.has_key?(evidence, :command)
        refute Map.has_key?(result, "command")
      end
    end

    test "a revoked membership refuses the next turn without a provider request", context do
      # No request is stubbed: a turn admitted on a revoked membership must never
      # reach the provider, so `verify_on_exit!` is the assertion.
      assert {:ok, session, _snapshot} = Agents.open(context.scope)
      deactivate_membership_fixture(context.harbor.membership)

      monitor = Process.monitor(session)

      # A revoked membership is the session's own `:forbidden` refusal, the one
      # `session_test.exs` pins, and it stops the conversation with it.
      assert {:error, :forbidden} = Agents.send_message(session, "Which dates change?")
      refute_received {:model_request, _request}
      assert_receive {:agent_event, ^session, {:status, :forbidden}}, @agent_turn_timeout
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 2_000
    end

    test "a conversation with no accepted source cannot read a plan", context do
      assert {:error, :unavailable} =
               Dispatch.call(
                 DatedChanges,
                 no_snapshot_scope(context.harbor),
                 "prepare_dated_change_plan",
                 "{}"
               )

      # A snapshot of another pack's kind is not this pack's source either.
      other_kind = snapshot_context(context.harbor, "timetables")

      assert {:error, :unavailable} =
               Dispatch.call(DatedChanges, other_kind, "prepare_dated_change_plan", "{}")
    end

    test "a foreign or forged selection is refused instead of partly answered", context do
      # A trip of another route, inside the same version and organization.
      foreign = snapshot_context(context.harbor, "dated_changes", [context.harbor.other.id])

      assert {:tool_error, message} =
               Dispatch.call(DatedChanges, foreign, "prepare_dated_change_plan", "{}")

      assert message ==
               "The route or a selected trip is no longer available in this service version."

      # A trip UUID no version holds.
      unknown =
        snapshot_context(context.harbor, "dated_changes", [Ecto.UUID.generate()])

      assert {:tool_error, ^message} =
               Dispatch.call(DatedChanges, unknown, "prepare_dated_change_plan", "{}")

      # A snapshot whose payload no longer matches the digest the envelope
      # computed is refused by the shared admission before the pack runs.
      forged = forged_snapshot(context.scope)

      assert {:error, :unavailable} =
               Dispatch.call(DatedChanges, forged, "prepare_dated_change_plan", "{}")
    end

    test "a deleted route refuses the pack's own precondition", context do
      Repo.delete!(context.harbor.route)

      assert {:error, :unavailable} =
               Dispatch.call(DatedChanges, context.scope, "prepare_dated_change_plan", "{}")
    end
  end

  describe "the bounded summary never reads as complete" do
    test "a 260-date partition shows 20 dates beside its exact total", context do
      expect_reply(tool_calls_reply([{"call_1", "prepare_dated_change_plan", "{}"}]))
      expect_reply(text_reply("The full calendar is 260 dates; 20 are shown here."))

      run_turn(context.scope, "Show me every original date.")

      assert [special, weekday] = tool_result()["partitions"]
      dates = weekday["dates"]

      # The 260 original dates are truncated to the sample bound, and the exact
      # total and label survive beside it (CR-3).
      assert dates["original_total"] == 260
      assert dates["original_shown"] == @witnesses
      assert dates["original_truncated"] == true
      assert dates["original_label"] == "Showing 20 of 260."
      assert length(dates["original"]) == @witnesses

      # `SPECIAL` holds the same 260 originals, and the affected window is
      # under the bound so it is shown whole.
      assert special["dates"]["original_total"] == 260
      assert special["dates"]["affected_total"] == 9
      assert special["dates"]["affected_label"] == "Showing all 9."

      # The unchanged dates are counted, not listed: 251 rows would be a whole
      # calendar, not a bounded answer.
      assert dates["unchanged_total"] == 251
      refute Map.has_key?(dates, "unchanged")
    end

    test "an over-limit answer is refused whole rather than truncated", context do
      wide = wide_scope(context)
      before = scoped_content(context.harbor)

      # The seeded transfer rows carry long stored selectors, so even a 20-row
      # sample of that one category cannot fit the shared 32 KiB tool envelope.
      assert {:tool_error, message} =
               Dispatch.call(DatedChanges, wide, "inspect_dated_change_dependencies", "{}")

      assert message =~ "too large"
      assert message =~ "native plan"

      # The refusal is a message, not a partial envelope: there is no result and
      # no evidence for a card to render a count from, and the plan tool's own
      # bounded summary is unaffected by the wide dependency listing.
      assert {:ok, _result, _evidence} =
               Dispatch.call(DatedChanges, wide, "prepare_dated_change_plan", "{}")

      assert scoped_content(context.harbor) == before
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
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}},
                   @agent_turn_timeout

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  # The tool message the turn sent back to the provider is the pack's own result,
  # decoded, so the assertions read what the model read. It only exists from the
  # request after the tool answered, so the earlier requests are drained first.
  defp tool_result do
    assert_receive {:model_request, request}, @agent_turn_timeout

    request
    |> tool_messages()
    |> case do
      [] -> tool_result()
      messages -> messages |> List.last() |> Map.fetch!("content") |> Jason.decode!()
    end
  end

  defp tool_messages(request) do
    Enum.filter(request["messages"] || [], &(&1["role"] == "tool"))
  end

  # -- scopes and snapshots ---------------------------------------------------

  defp scope(harbor, identity) do
    %Scope{
      organization_id: harbor.organization.id,
      gtfs_version_id: harbor.version.id,
      user_id: harbor.user.id,
      user_email: harbor.user.email,
      pack_id: "dated_changes",
      version_name: harbor.version.name,
      resource_context: Scope.context(identity)
    }
  end

  defp version_scope(harbor), do: scope(harbor, {:version, harbor.version.id})

  # The same route-bound conversation with no accepted source at all.
  defp no_snapshot_scope(harbor), do: scope(harbor, {:route, harbor.route.id})

  # The accepted source in the JSON-safe form a host freezes: ISO dates, sorted
  # UUIDs and the server's own input digest.
  defp snapshot_context(harbor, kind, trip_ids \\ nil) do
    source = accepted_source(harbor, trip_ids)

    payload = %{
      "schema_version" => source.schema_version,
      "trip_ids" => source.trip_ids,
      "first_date" => Date.to_iso8601(source.first_date),
      "last_date" => Date.to_iso8601(source.last_date),
      "delta_seconds" => source.delta_seconds,
      "approval_note" => source.approval_note,
      "source_label" => source.source_label,
      "input_digest" => source.input_digest
    }

    assert {:ok, resource_context} =
             Scope.with_source_snapshot(
               Scope.context({:route, harbor.route.id}),
               %{kind: kind, payload: payload}
             )

    harbor |> scope({:route, harbor.route.id}) |> Map.put(:resource_context, resource_context)
  end

  # A snapshot whose payload no longer matches the digest the envelope computed,
  # so the shared admission refuses it instead of the pack trusting it.
  defp forged_snapshot(scope) do
    snapshot = Scope.source_snapshot(scope)
    tampered = Map.put(snapshot, :payload, Map.put(snapshot.payload, "delta_seconds", 86_400))

    %{
      scope
      | resource_context: Map.put(scope.resource_context, :source_snapshot, tampered)
    }
  end

  defp accepted_source(harbor, trip_ids) do
    selection = trip_ids || [harbor.selected.id, harbor.second.id]

    {:ok, draft} =
      DatedChangePlan.normalize_intent(
        %{
          "first_date" => Date.to_iso8601(@first),
          "last_date" => Date.to_iso8601(@last),
          "delta_seconds" => "+300",
          "approval_note" => "Approved for the winter timetable review.",
          "source_label" => "Winter review"
        },
        selection
      )

    {:ok, accepted} = DatedChangePlan.accept_intent(draft, selection)
    accepted
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

  # -- fixtures ---------------------------------------------------------------

  # `H8-1` is a selected trip on `WEEKDAY`, `H8-2` its unselected same-block
  # peer on the same calendar, `H8-3` a second selected trip on `SPECIAL`,
  # `H12-1` another route's trip on that calendar, and `H8-4` a trip of a third
  # calendar the plan reads and does not touch. Fixtures commit on their own
  # connections, so the loader takes the production snapshot boundary; each case
  # removes exactly its organization.
  defp harbor_scope(supervisor) do
    harbor = in_task(supervisor, fn -> build_harbor_scope() end)
    commit_cleanup(harbor.organization_ids)
    harbor
  end

  defp build_harbor_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "America/New_York"})

    for {stop_id, stop_name} <- [
          {@central, "Central Station"},
          {@harbor, "Harbor Yards"},
          {@depot, "Depot Road"}
        ] do
      stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})
    end

    route = route_fixture(organization.id, version.id, %{route_id: "H8"})
    route_fixture(organization.id, version.id, %{route_id: "H12"})

    calendar_fixture(organization.id, version.id, weekday("WEEKDAY"))
    calendar_fixture(organization.id, version.id, weekday("SPECIAL"))
    calendar_fixture(organization.id, version.id, weekday("OFFPEAK"))

    for service_id <- ["WEEKDAY", "SPECIAL"] do
      calendar_date_fixture(organization.id, version.id, %{
        service_id: service_id,
        date: @holiday,
        exception_type: 2
      })
    end

    pattern_id = "HP1"

    selected =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-1",
        route_id: "H8",
        service_id: "WEEKDAY",
        block_id: "B1",
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "06:00:00"}, {@harbor, 2, "06:15:00"}]
      })

    peer =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-2",
        route_id: "H8",
        service_id: "WEEKDAY",
        block_id: "B1",
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "06:05:00"}, {@harbor, 2, "06:20:00"}]
      })

    second =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-3",
        route_id: "H8",
        service_id: "SPECIAL",
        block_id: nil,
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "07:00:00"}, {@depot, 2, "07:15:00"}]
      })

    other =
      service_trip(organization.id, version.id, %{
        trip_id: "H12-1",
        route_id: "H12",
        service_id: "WEEKDAY",
        block_id: nil,
        route_pattern_id: "HP12",
        stops: [{@central, 1, "08:00:00"}, {@harbor, 2, "08:15:00"}]
      })

    untouched =
      service_trip(organization.id, version.id, %{
        trip_id: "H8-4",
        route_id: "H8",
        service_id: "OFFPEAK",
        block_id: nil,
        route_pattern_id: pattern_id,
        stops: [{@central, 1, "09:00:00"}, {@depot, 2, "09:15:00"}]
      })

    Repo.insert!(%BlockAttribute{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      service_id: "WEEKDAY",
      block_id: "B1"
    })

    Repo.insert!(%BlockingSetting{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      min_layover_minutes: 5
    })

    Repo.insert!(%RouteOperatingSetting{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      route_id: "H8"
    })

    # One rule of each type 0..5. Types 4 and 5 are the in-seat rules, which
    # name two trips and no route pair; the rest name stops, and type 2 carries
    # its minimum time. All six are dependencies of the version.
    for attributes <- [
          %{from_stop_id: @central, to_stop_id: @harbor, transfer_type: 0},
          %{from_stop_id: @harbor, to_stop_id: @depot, transfer_type: 1},
          %{
            from_stop_id: @depot,
            to_stop_id: @central,
            transfer_type: 2,
            min_transfer_time: 300
          },
          %{
            from_stop_id: @central,
            to_stop_id: @depot,
            from_trip_id: "H8-3",
            to_trip_id: "H8-4",
            transfer_type: 3,
            min_transfer_time: 120
          },
          %{
            from_stop_id: @harbor,
            to_stop_id: @depot,
            from_trip_id: "H8-2",
            to_trip_id: "H8-3",
            transfer_type: 4
          },
          %{
            from_stop_id: @depot,
            to_stop_id: @central,
            from_trip_id: "H8-1",
            to_trip_id: "H8-2",
            transfer_type: 5
          }
        ] do
      transfer_fixture(organization.id, version.id, attributes)
    end

    for trip <- [selected, peer] do
      Repo.insert!(%TripRun{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        trip_id: trip.id,
        day_type_key: "WEEKDAY",
        run_id: "R1"
      })
    end

    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    accepted = accepted_source(%{selected: selected, second: second}, nil)

    %{
      organization: organization,
      version: version,
      route: route,
      selected: selected,
      peer: peer,
      second: second,
      other: other,
      untouched: untouched,
      user: user,
      membership: membership,
      accepted: accepted,
      organization_ids: [organization.id]
    }
  end

  # A second, wider fixture in the same organization: its dependency rows carry
  # long stored selectors, so a bounded 20-row sample per category still exceeds
  # the shared 32 KiB tool envelope and the pack must refuse rather than cut the
  # encoded truth. The rows commit on their own connection, like every other
  # fixture here, so the loader reads them through its ordinary boundary.
  defp wide_scope(context) do
    harbor = context.harbor
    long = String.duplicate("X", 240)

    in_task(context.supervisor, fn ->
      for index <- 1..40 do
        transfer_fixture(harbor.organization.id, harbor.version.id, %{
          from_stop_id: "#{long}-#{index}",
          to_stop_id: "#{long}-TO-#{index}",
          from_route_id: "#{long}-FROM-ROUTE-#{index}",
          to_route_id: "#{long}-TO-ROUTE-#{index}",
          from_trip_id: "#{long}-TRIP-#{index}",
          to_trip_id: "#{long}-TO-TRIP-#{index}",
          transfer_type: 0
        })
      end
    end)

    snapshot_context(harbor, "dated_changes", [harbor.selected.id, harbor.second.id])
  end

  defp service_trip(organization_id, version_id, attrs) do
    stops = Map.fetch!(attrs, :stops)
    trip_id = Map.fetch!(attrs, :trip_id)

    trip =
      trip_fixture(organization_id, version_id, Map.fetch!(attrs, :route_id), %{
        trip_id: trip_id,
        service_id: Map.fetch!(attrs, :service_id),
        block_id: Map.get(attrs, :block_id),
        route_pattern_id: Map.get(attrs, :route_pattern_id)
      })

    for {stop_id, sequence, time} <- stops do
      stop_time_fixture(organization_id, version_id, trip_id, stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end

    trip
  end

  defp weekday(service_id) do
    %{
      service_id: service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31]
    }
  end

  # Every entity row this plan could touch, plus every audit row, as sorted
  # content. Comparing two of these byte-for-byte is what "the pack changed
  # nothing" means here: not equal counts, but equal values.
  defp scoped_content(harbor) do
    organization_id = harbor.organization.id

    %{
      trips:
        content(Trip, organization_id, [:id, :trip_id, :service_id, :block_id, :route_pattern_id]),
      stop_times:
        content(StopTime, organization_id, [
          :id,
          :trip_id,
          :stop_id,
          :stop_sequence,
          :arrival_time,
          :departure_time
        ]),
      frequencies:
        content(Frequency, organization_id, [:id, :trip_id, :start_time, :end_time, :headway_secs]),
      calendars: content(Calendar, organization_id, [:id, :service_id, :start_date, :end_date]),
      calendar_dates:
        content(CalendarDate, organization_id, [:id, :service_id, :date, :exception_type]),
      block_attributes:
        content(BlockAttribute, organization_id, [:id, :block_id, :service_id, :garage_id]),
      blocking_settings:
        content(BlockingSetting, organization_id, [:id, :min_layover_minutes, :interlining]),
      route_operating_settings:
        content(RouteOperatingSetting, organization_id, [:id, :route_id, :garage_id]),
      transfers:
        content(Transfer, organization_id, [
          :id,
          :from_stop_id,
          :to_stop_id,
          :from_route_id,
          :to_route_id,
          :from_trip_id,
          :to_trip_id,
          :transfer_type,
          :min_transfer_time
        ]),
      trip_runs: content(TripRun, organization_id, [:id, :trip_id, :day_type_key, :run_id]),
      audit: audit_content(organization_id)
    }
  end

  # The rows are read whole and projected here rather than in the query: the
  # comparison is about values, and a projection the database builds would be a
  # second thing under test.
  defp content(queryable, organization_id, fields) do
    queryable
    |> where([row], row.organization_id == ^organization_id)
    |> Repo.all()
    |> Enum.map(&Map.take(&1, fields))
    |> Enum.sort_by(&inspect/1)
    |> Enum.map(&inspect/1)
  end

  defp audit_content(organization_id) do
    ChangeLog
    |> where([row], row.organization_id == ^organization_id)
    |> select(
      [row],
      {row.entity_type, row.entity_id, row.entity_external_id, row.action, row.snapshot,
       row.changed_fields}
    )
    |> Repo.all()
    |> Enum.map(&inspect/1)
    |> Enum.sort()
  end

  defp in_task(supervisor, fun) do
    supervisor
    |> Task.Supervisor.async_nolink(fn -> Sandbox.unboxed_run(Repo, fun) end)
    |> Task.await(@task_timeout)
  end

  # `on_exit` runs after the test process has exited, so the `start_supervised!/1`
  # supervisor is already dead here; the cleanup owns its own unboxed
  # connection, as the four `dated_change_*` domain files do.
  defp commit_cleanup(organization_ids) do
    on_exit(fn ->
      ConcurrencyHelpers.unboxed(fn ->
        ConcurrencyHelpers.delete_committed_members!(organization_ids)
        ConcurrencyHelpers.delete_committed_scope!(organization_ids)
      end)
    end)
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

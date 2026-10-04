defmodule GtfsPlanner.Agents.Packs.BlocksTest do
  @moduledoc """
  The Blocks pack's public contract, exercised through the production fence.

  Every tool call here goes through `GtfsPlanner.Agents.Dispatch.call/4` against
  the registered `GtfsPlanner.Agents.Packs.Blocks` module, over a scope carrying
  a real editor membership and a real snapshot that
  `GtfsPlanner.Gtfs.OperationsAssistance` admitted from a real
  `Blocking.load_day/3` day. The only thing this file performs itself is the
  admission of that copy, which in the application is the Blocks page's job;
  nothing about the tools, the fence or the domain is replaced.

  The cases follow this step's own obligations:

  - the pack declares four tools, each rejecting undeclared keys;
  - a read answers from the frozen copy under its own digest, and the cursor a
    first page returned pages the rest of the day's issues without re-reading the
    day;
  - a nested cursor with an undeclared field, a foreign `day_ref`, a trip ref the
    snapshot does not hold, a `selected` mode with no blocks selected, a day type
    the catalog no longer derives and a revoked membership all refuse;
  - `unassigned_only` on a day whose pool is empty stays `unassigned_only` and is
    never promoted to `replace_all`, and a pool-only selection is not turned into
    a solver mode;
  - a prepared scope carries configuration only - no plan, no target list, no
    actor - and neither the prepared call nor any read changes a stored row.

  Rows are created inside the SQL Sandbox transaction and rolled back. The
  focused gate command is handed to branch review:
  `mix test test/gtfs_planner/agents/packs/blocks_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Blocks
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.OperationsAssistance

  describe "pack declaration" do
    test "declares exactly the four blocks tools with their activity labels" do
      assert Blocks.id() == "blocks"
      assert Blocks.title() == "Blocks helper"
      assert Blocks.intro() =~ "blocking problems"

      assert Enum.map(Blocks.tools(), & &1.name) == [
               "get_blocking_issues",
               "inspect_blocking_constraints",
               "prepare_block_suggestion",
               "compare_block_proposal"
             ]

      assert Enum.map(Blocks.tools(), & &1.activity) == [
               "Checked this day's blocking issues",
               "Inspected blocking constraints",
               "Prepared a block suggestion scope",
               "Compared a block proposal"
             ]

      assert Enum.all?(Blocks.tools(), &(&1.parameters["additionalProperties"] == false))
    end

    test "the registry is the only place the agent core names this pack" do
      assert Agents.packs()["blocks"] == Blocks
    end
  end

  describe "reading a day's issues" do
    setup :wide_world

    test "answers from the frozen copy under its own digest", context do
      assert {:ok, result, evidence} = issues(context, %{"day_ref" => day_ref(context)})

      assert result["day_key"] == context.day_key
      assert result["digest"] == context.payload["source_digest"]
      assert result["total"] == 51
      assert result["completeness"] == "complete"
      assert result["scope"]["mode"] == "whole_day"

      # 51 trips of one block, each carrying the block's own vehicle-type
      # problem, so the first page holds 50 of them.
      assert length(result["rows"]) == 50
      assert result["page_limited?"] == true
      assert Enum.all?(result["rows"], &(&1["code"] == "type_mismatch"))

      # The evidence is built from the same frozen copy the rows came from.
      assert evidence.kind == "blocking_issues"
      assert evidence.total == 51
      assert evidence.digest == result["digest"]
      assert evidence.source_revision == nil
      assert evidence.scope.gtfs_version_id == context.version.id
      assert evidence.resources == []
    end

    test "the second page is the same frozen evidence after the day is reloaded", context do
      assert {:ok, first, _evidence} = issues(context, %{"day_ref" => day_ref(context)})
      assert first["next_cursor"]

      # A host reload and a fresh suggestion of the same day change nothing the
      # frozen copy describes: the second page is the copy's page, not a new read.
      assert {:ok, _day} =
               Blocking.load_day(context.organization.id, context.version.id, context.day_key)

      assert {:ok, _plan} =
               Blocking.suggest_blocks(
                 context.organization.id,
                 context.version.id,
                 context.day_key,
                 :replace_all
               )

      assert {:ok, second, evidence} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => first["next_cursor"]})

      assert second["total"] == first["total"]
      assert second["digest"] == first["digest"]
      assert second["next_cursor"] == nil
      assert length(second["rows"]) == 1
      assert evidence.total == 51
    end

    test "pages that fill the byte budget still fit beside the pack's envelope", context do
      # Each issue carries enough detail that fifty of them overrun 32 KiB, so the
      # pager must narrow the page. The page, the pack's envelope and the
      # evidence together still have to fit the one result ceiling.
      padded =
        Enum.map(context.payload["issues"], &Map.put(&1, "note", String.duplicate("x", 300)))

      context = admit(context, Map.put(context.payload, "issues", padded))

      pages = all_pages(context, nil, [])

      assert length(hd(pages)["rows"]) < 50
      assert pages |> Enum.flat_map(& &1["rows"]) |> length() == 51
      assert List.last(pages)["next_cursor"] == nil
    end

    test "narrows by a code the frozen copy carries and refuses one it does not", context do
      assert {:ok, result, _evidence} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "filters" => %{"code" => "type_mismatch", "severity" => "error"}
               })

      assert Enum.all?(result["rows"], &(&1["code"] == "type_mismatch"))
      assert Enum.all?(result["rows"], &(&1["severity"] == "error"))
      assert result["filters"] == %{"code" => "type_mismatch", "severity" => "error"}

      assert {:tool_error, message} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "filters" => %{"code" => "no_such_code"}
               })

      assert message =~ "Start the list again"

      assert {:tool_error, "Unexpected argument: filters.run_refs"} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "filters" => %{"run_refs" => ["run_1"]}
               })
    end

    test "refuses a day from another conversation and an undeclared argument", context do
      assert {:tool_error, message} =
               issues(context, %{"day_ref" => "day_" <> String.duplicate("a", 32)})

      assert message == "That day is not the day attached to this conversation."

      assert {:tool_error, "Unexpected argument: organization_id"} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "organization_id" => context.organization.id
               })
    end

    test "an omitted day_ref reads the attached day the supplied one names", context do
      # The ref is an opaque server-generated digest the model can neither derive
      # nor retype, so leaving it out has to reach the same day rather than fail.
      assert {:ok, omitted, omitted_evidence} = issues(context, %{})

      assert {:ok, supplied, supplied_evidence} =
               issues(context, %{"day_ref" => day_ref(context)})

      assert omitted == supplied
      assert omitted_evidence == supplied_evidence
      assert omitted["day_ref"] == day_ref(context)

      # And the fence is unchanged for a ref that is supplied: a foreign one is
      # still refused, so omitting the argument is not a way past the check.
      assert {:tool_error, "That day is not the day attached to this conversation."} =
               issues(context, %{"day_ref" => "day_" <> String.duplicate("a", 32)})
    end

    test "an omitted day_ref prepares the attached day's scope", context do
      assert {:prepared, prepared, result, _evidence} =
               prepare(context, %{"mode" => "unassigned_only"})

      assert {:operations_suggestion, command} = prepared.command
      assert command.day_key == context.day_key
      assert result["day_ref"] == day_ref(context)
      assert result["suggestion_started?"] == false
      assert result["saved?"] == false
    end

    test "refuses a nested cursor with an undeclared field or a foreign position", context do
      assert {:ok, first, _evidence} = issues(context, %{"day_ref" => day_ref(context)})
      cursor = first["next_cursor"]

      assert {:tool_error, "Unexpected argument: cursor.limit"} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "cursor" => Map.put(cursor, "limit", 10)
               })

      # A cursor may only name the filters this very call is reading under.
      assert {:tool_error, message} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "cursor" => Map.put(cursor, "filters", %{"severity" => "error"})
               })

      assert message =~ "Start the list again"

      stale = Map.put(cursor, "digest", String.duplicate("a", 64))

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => stale})

      assert message =~ "Start the list again"

      changed = Map.put(cursor, "filters", %{"code" => "type_mismatch"})

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => changed})

      assert message =~ "Start the list again"

      last = Map.put(cursor, "offset", 50)

      assert {:ok, page, _evidence} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => last})

      assert length(page["rows"]) == 1

      beyond = Map.put(cursor, "offset", 52)

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => beyond})

      assert message =~ "Start the list again"
    end
  end

  describe "inspecting constraints" do
    setup :narrow_world

    test "reports the stored rules and the named trips' own identities", context do
      ref = trip_ref(context, "loose_1")

      assert {:ok, result, evidence} =
               constraints(context, %{"day_ref" => day_ref(context), "trip_refs" => [ref]})

      assert [trip] = result["trips"]
      assert trip["trip_id"] == "loose_1"
      assert trip["trip_ref"] == ref

      # The rules are the day's own stored values, copied: nothing is recomputed.
      assert result["constraints"]["settings"]["min_layover_minutes"] == 5
      assert is_boolean(result["constraints"]["planning_inputs"])
      assert evidence.kind == "blocking_constraints"
      assert evidence.total == 1
      assert [%{kind: "route", id: "R30"}] = evidence.resources
    end

    test "a pool trip inspection names no block and invents no solver mode", context do
      ref = trip_ref(context, "loose_1")

      assert {:ok, result, _evidence} =
               constraints(context, %{"day_ref" => day_ref(context), "trip_refs" => [ref]})

      assert [trip] = result["trips"]
      assert is_nil(trip["block_ref"])

      # The trip is unassigned, so the day's own check for it - the route
      # requires a vehicle type the trip has none of - is reported exactly as
      # the checks raised it, with no block invented for a trip that has none.
      assert [issue] = result["issues"]
      assert issue["code"] == "type_mismatch"
      assert issue["block_ref"] == nil
      assert issue["trip_refs"] == [ref]
      assert result["matching_issue_count"] == 1
    end

    test "refuses a trip ref this snapshot does not hold", context do
      foreign = "trip_" <> String.duplicate("a", 32)

      assert {:tool_error, message} =
               constraints(context, %{"day_ref" => day_ref(context), "trip_refs" => [foreign]})

      assert message =~ "holds no trip reference"

      ref = trip_ref(context, "loose_1")

      assert {:tool_error, message} =
               constraints(context, %{
                 "day_ref" => day_ref(context),
                 "trip_refs" => [ref, ref]
               })

      assert message =~ "named twice"

      assert {:tool_error, message} =
               constraints(context, %{"day_ref" => day_ref(context), "trip_refs" => []})

      assert message == "Argument trip_refs must have 1 or more items."
    end
  end

  describe "preparing a suggestion scope" do
    setup :blocked_world

    test "prepares configuration only, with no plan, target list or actor", context do
      before_counts = row_counts()

      assert {:prepared, prepared, result, evidence} =
               prepare(context, %{"day_ref" => day_ref(context), "mode" => "replace_all"})

      assert {:operations_suggestion, command} = prepared.command

      assert command == %{
               section: "blocks",
               day_key: context.day_key,
               source_digest: context.payload["source_digest"],
               selection_digest: selection_digest(context.payload),
               mode: "replace_all"
             }

      # No write plan, no target list and no actor travel with the configuration.
      assert prepared.summary.title == "Rebuild the whole day on #{context.day_key}"
      assert hd(prepared.summary.lines) == "Rebuilds every block on #{context.day_key} · 1 blocks"
      assert result["blocks_in_scope"] == 1
      assert result["suggestion_started?"] == false
      assert result["saved?"] == false
      assert evidence.kind == "block_suggestion_configuration"

      serialized = Jason.encode!(%{result: result, evidence: evidence})

      refute serialized =~ "apply_block_plan"

      # No database row reaches the configuration the model reads: the scope
      # identity in the evidence is the conversation's own version id, and the
      # answer itself carries no row of any kind.
      refute Jason.encode!(result) =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-/

      # The prepared command itself is an Elixir term the host interprets, and
      # it carries no plan, no row and no target list.
      refute inspect(prepared) =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-/

      # Preparing a scope starts no solver and moves no trip.
      assert row_counts() == before_counts
    end

    test "unassigned-only stays unassigned-only when the pool is empty", context do
      # Every trip on this day is already in block 101, so there is nothing
      # unassigned. The mode stays the unassigned one, because the drawer's own
      # default would otherwise rebuild the whole day from an empty pool.
      assert context.payload["scope"]["trip_refs"] == []

      assert {:prepared, %{command: {:operations_suggestion, command}}, result, _evidence} =
               prepare(context, %{"day_ref" => day_ref(context), "mode" => "unassigned_only"})

      assert command.mode == "unassigned_only"
      assert result["scope"]["trip_refs"] == []
      assert result["selected_block_count"] == 0
    end

    test "selected is offered only for the blocks the editor has selected", context do
      context = selected!(context, "101")

      assert {:prepared, %{command: {:operations_suggestion, command}}, result, _evidence} =
               prepare(context, %{"day_ref" => day_ref(context), "mode" => "selected"})

      assert command.mode == "selected"
      assert command.selection_digest == selection_digest(context.payload)
      assert result["selected_block_count"] == 1
      assert result["completeness"] == "scoped"
    end

    test "selected refuses a page with nothing selected, and an unknown mode", context do
      assert {:tool_error, message} =
               prepare(context, %{"day_ref" => day_ref(context), "mode" => "selected"})

      assert message =~ "No blocks are selected"

      assert {:tool_error, message} =
               prepare(context, %{"day_ref" => day_ref(context), "mode" => "everything"})

      assert message == "mode must be one of: unassigned_only, selected, replace_all."

      assert {:tool_error, "Unexpected argument: block_ids"} =
               prepare(context, %{
                 "day_ref" => day_ref(context),
                 "mode" => "unassigned_only",
                 "block_ids" => ["101"]
               })
    end
  end

  describe "preparing from a trip-only selection" do
    setup :narrow_world

    test "selected refuses a pool-trip selection rather than inventing a solver mode", context do
      # The editor selected one unassigned trip on the page. That narrows what
      # can be inspected; it is not a rebuildable block selection, so the pack
      # offers no mode rather than inventing one the native drawer cannot run.
      context = scoped!(context, %{selected_trip_ids: [pool_trip_id(context)]})

      assert {:tool_error, message} =
               prepare(context, %{"day_ref" => day_ref(context), "mode" => "selected"})

      assert message =~ "a trip selection cannot be rebuilt"

      # The other modes stay available: they never need a selection.
      for mode <- ["unassigned_only", "replace_all"] do
        assert {:prepared, _prepared, result, _evidence} =
                 prepare(context, %{"day_ref" => day_ref(context), "mode" => mode})

        assert result["mode"] == mode
      end
    end
  end

  describe "preparing a day-wide mode with a selection on the page" do
    setup :narrow_world

    test "states no count taken from the selection", context do
      # The day holds one block, but the copy holds only the selected pool trip,
      # so a count read from it would say a full rebuild touches no block.
      context = scoped!(context, %{selected_trip_ids: [pool_trip_id(context)]})

      assert {:prepared, prepared, result, evidence} =
               prepare(context, %{"mode" => "replace_all"})

      assert prepared.summary.lines == [
               "Rebuilds every block on #{context.day_key}, not only the selected ones",
               "Existing blocks on this day are replaced",
               "Nothing is suggested or saved yet"
             ]

      assert prepared.summary.detail ==
               "The page has a selection, so this copy holds no day-wide counts"

      assert result["blocks_in_scope"] == nil

      assert Enum.map(evidence.facts, & &1.label) == ["Day", "Mode", "Day-wide counts", "Started"]

      assert {:prepared, prepared, _result, _evidence} =
               prepare(context, %{"mode" => "unassigned_only"})

      assert hd(prepared.summary.lines) ==
               "Works only on the trips with no block on #{context.day_key}"
    end
  end

  describe "comparing a completed proposal" do
    setup :narrow_world

    test "reads the proposal the page already holds", context do
      context = with_plan!(context)

      assert {:ok, result, evidence} =
               compare(context, %{"plan_ref" => plan_ref(context)})

      assert result["day_key"] == context.day_key
      assert result["plan_ref"] == plan_ref(context)
      assert is_integer(result["proposal"]["move_count"])
      assert evidence.kind == "block_proposal"
      assert evidence.digest == context.payload["source_digest"]

      # The proposal's own warnings and leftovers are reported as its own, never
      # as the day's problems, and nothing about it was computed here.
      assert Enum.all?(result["proposal"]["warnings"], &is_map/1)
      assert Enum.all?(result["proposal"]["leftovers"], &is_map/1)
    end

    test "an omitted plan_ref reads the proposal the supplied one names", context do
      # Like the day ref, the plan ref is an opaque digest no tool result or
      # prompt gives the model, so leaving it out has to reach the attached
      # proposal rather than fail for a value the model cannot know.
      context = with_plan!(context)

      assert {:ok, omitted, omitted_evidence} = compare(context, %{})

      assert {:ok, supplied, supplied_evidence} =
               compare(context, %{"plan_ref" => plan_ref(context)})

      assert omitted == supplied
      assert omitted_evidence == supplied_evidence
      assert omitted["plan_ref"] == plan_ref(context)
    end

    test "an omitted plan_ref with no proposal on the page reads as no proposal", context do
      assert {:tool_error, message} = compare(context, %{})

      assert message =~ "no completed block proposal"
    end

    test "refuses no plan at all and a plan the page does not hold", context do
      # No native job has run, so the attached copy carries no proposal.
      assert {:tool_error, message} =
               compare(context, %{"plan_ref" => "plan_" <> String.duplicate("a", 32)})

      assert message =~ "no completed block proposal"

      context = with_plan!(context)

      assert {:tool_error, message} =
               compare(context, %{"plan_ref" => "plan_" <> String.duplicate("b", 32)})

      assert message =~ "not the one this page holds"
    end
  end

  describe "authorization" do
    setup :narrow_world

    test "a revoked membership refuses before the pack runs", context do
      assert Scope.authorize(context.scope) == :ok

      deactivate_membership_fixture(context.membership)

      assert Dispatch.call(Blocks, context.scope, "get_blocking_issues", args(day_ref(context))) ==
               {:error, :forbidden}

      assert Dispatch.call(
               Blocks,
               context.scope,
               "prepare_block_suggestion",
               Jason.encode!(%{"day_ref" => day_ref(context), "mode" => "unassigned_only"})
             ) == {:error, :forbidden}
    end

    test "a conversation with no attached day is unavailable", context do
      bare = %{context.scope | resource_context: Scope.context({:version, context.version.id})}

      assert Blocks.authorize_context(bare) == {:error, :unavailable}

      assert Dispatch.call(Blocks, bare, "get_blocking_issues", args(day_ref(context))) ==
               {:error, :unavailable}
    end

    test "another section's snapshot and a foreign identity refuse alike", context do
      {:ok, runs_context} =
        OperationsAssistance.context({:version, context.version.id}, %{
          "schema_version" => 1,
          "section" => "runs",
          "day_key" => context.day_key,
          "issues" => []
        })

      runs = %{context.scope | resource_context: runs_context}

      assert Blocks.authorize_context(runs) == {:error, :unavailable}

      # The identity must be this conversation's own version: a route-bound
      # identity is a different page, not this day.
      %Scope{} = scope = context.scope

      routed = %{
        scope
        | resource_context:
            Map.put(scope.resource_context, :identity, {:route, Ecto.UUID.generate()})
      }

      assert Blocks.authorize_context(routed) == {:error, :unavailable}
    end

    test "a day type the catalog no longer derives refuses", context do
      # The copy's own day key names a day type the current calendars no longer
      # derive. Its digest still verifies - the server hashed it - so only the
      # scoped day catalog read can notice, and the answer is the single refusal.
      stale_payload = Map.put(context.payload, "day_key", "2026:1:absent")

      assert {:ok, resource_context} =
               Scope.with_source_snapshot(Scope.context({:version, context.version.id}), %{
                 kind: "operations_blocks",
                 payload: stale_payload
               })

      assert Blocks.authorize_context(%{context.scope | resource_context: resource_context}) ==
               {:error, :unavailable}
    end
  end

  # --- the fence ---------------------------------------------------------

  defp issues(context, tool_args) do
    Dispatch.call(Blocks, context.scope, "get_blocking_issues", Jason.encode!(tool_args))
  end

  defp constraints(context, tool_args) do
    Dispatch.call(
      Blocks,
      context.scope,
      "inspect_blocking_constraints",
      Jason.encode!(tool_args)
    )
  end

  defp prepare(context, tool_args) do
    Dispatch.call(Blocks, context.scope, "prepare_block_suggestion", Jason.encode!(tool_args))
  end

  defp compare(context, tool_args) do
    Dispatch.call(Blocks, context.scope, "compare_block_proposal", Jason.encode!(tool_args))
  end

  defp args(value), do: Jason.encode!(%{"day_ref" => value})

  defp day_ref(context), do: context.payload["day_ref"]

  defp selection_digest(payload) do
    payload
    |> Map.fetch!("selection")
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp trip_ref(context, trip_id) do
    context.payload["entities"]["trips"]
    |> Enum.find(&(&1["trip_id"] == trip_id))
    |> Map.fetch!("trip_ref")
  end

  defp pool_trip_id(context) do
    context.payload["entities"]["trips"]
    |> Enum.find(&is_nil(&1["block_ref"]))
    |> Map.fetch!("trip_id")
  end

  defp plan_ref(context), do: context.payload["plan"]["plan_ref"]

  defp row_counts do
    %{
      trips: Repo.aggregate(GtfsPlanner.Gtfs.Trip, :count),
      block_attributes: Repo.aggregate(GtfsPlanner.Gtfs.BlockAttribute, :count)
    }
  end

  # A host that publishes a completed proposal attaches its copy to the frozen
  # day and republishes the resource context, which is what the page will do.
  defp with_plan!(context) do
    assert {:ok, plan} =
             Blocking.suggest_blocks(
               context.organization.id,
               context.version.id,
               context.day_key,
               :replace_all
             )

    assert {:ok, payload} = OperationsAssistance.with_plan(context.payload, :blocks, plan)

    attach(context, payload)
  end

  defp selected!(context, block_id), do: scoped!(context, %{selected_block_ids: [block_id]})

  # A changed selection publishes a narrower frozen copy under a new session key.
  defp scoped!(context, selection) do
    assert {:ok, day} =
             Blocking.load_day(context.organization.id, context.version.id, context.day_key)

    assert {:ok, payload} = OperationsAssistance.block_day(day, selection)

    attach(context, payload)
  end

  # Follows every cursor from `cursor` to the end, asserting each page is served.
  defp all_pages(context, cursor, pages) do
    tool_args = if cursor, do: %{"cursor" => cursor}, else: %{}

    assert {:ok, page, _evidence} = issues(context, tool_args)

    case page["next_cursor"] do
      nil -> Enum.reverse([page | pages])
      next -> all_pages(context, next, [page | pages])
    end
  end

  # Admits a hand-edited copy of the day, as a page that published it would.
  defp admit(context, payload) do
    assert {:ok, resource_context} =
             Scope.with_source_snapshot(Scope.context({:version, context.version.id}), %{
               kind: "operations_blocks",
               payload: payload
             })

    %{context | payload: payload, scope: %{context.scope | resource_context: resource_context}}
  end

  defp attach(context, payload) do
    assert {:ok, resource_context} =
             OperationsAssistance.context({:version, context.version.id}, payload)

    %{context | payload: payload, scope: %{context.scope | resource_context: resource_context}}
  end

  # --- worlds -------------------------------------------------------------

  # 51 trips of one block whose vehicle type the route does not allow, so each
  # trip raises exactly one `:type_mismatch` error and the day holds 51 issues:
  # more than one page can hold.
  defp wide_world(_context), do: build_world(51, false)

  # Three trips of one block plus one unassigned trip.
  defp narrow_world(_context), do: build_world(3, true)

  # The same three trips with nothing unassigned, so the pool is empty.
  defp blocked_world(_context), do: build_world(3, false)

  defp build_world(trips, pool?) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "R30", route_short_name: "30"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      name: "Weekday",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    stop_fixture(organization.id, version.id, %{stop_id: "S1"})

    main =
      garage_fixture(organization.id, %{
        "name" => "Main",
        "lat" => Decimal.new("40.0400"),
        "lon" => Decimal.new("-74.0")
      })

    cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
    diesel = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})

    route_operating_setting_fixture(organization.id, version.id, %{
      route_id: "R30",
      required_vehicle_type_id: diesel.id
    })

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WEEKDAY",
      block_id: "101",
      garage_id: main.id,
      vehicle_type_id: cutaway.id
    })

    {:ok, _settings} =
      Blocking.update_settings(audit, %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: "any",
        default_garage_id: main.id,
        deadhead_speed_kmh: 30,
        deadhead_circuity: 1.3,
        max_piece_minutes: nil
      })

    for index <- 0..(trips - 1) do
      start = 360 + index * 25

      blocked_trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: "b#{index}",
        service_id: "WEEKDAY",
        block_id: "101",
        first_stop: "S1",
        last_stop: "S1",
        first_arrival: clock(start),
        first_departure: clock(start),
        last_arrival: clock(start + 20),
        last_departure: clock(start + 20)
      })
    end

    if pool? do
      blocked_trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: "loose_1",
        service_id: "WEEKDAY",
        first_stop: "S1",
        last_stop: "S1",
        first_arrival: "23:00:00",
        first_departure: "23:00:00",
        last_arrival: "23:20:00",
        last_departure: "23:20:00"
      })
    end

    day_key = DayTypes.key(["WEEKDAY"])

    assert {:ok, day} = Blocking.load_day(organization.id, version.id, day_key)
    assert {:ok, payload} = OperationsAssistance.block_day(day, %{})

    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    context = %{
      organization: organization,
      version: version,
      day_key: day_key,
      payload: payload,
      membership: membership,
      scope: %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "blocks",
        version_name: version.name
      }
    }

    attach(context, payload)
  end

  defp clock(minutes) do
    hours = Integer.to_string(div(minutes, 60)) |> String.pad_leading(2, "0")
    rest = Integer.to_string(rem(minutes, 60)) |> String.pad_leading(2, "0")
    "#{hours}:#{rest}:00"
  end
end

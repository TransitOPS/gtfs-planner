defmodule GtfsPlanner.Agents.Packs.RunsTest do
  @moduledoc """
  The Runs pack's public contract, exercised through the production fence.

  Every tool call here goes through `GtfsPlanner.Agents.Dispatch.call/4` against
  the registered `GtfsPlanner.Agents.Packs.Runs` module, over a scope carrying a
  real editor membership and a real snapshot that
  `GtfsPlanner.Gtfs.OperationsAssistance` admitted from a real
  `Runs.load_runs/3` day. The only thing this file performs itself is the
  admission of that copy, which in the application is the Runs page's job;
  nothing about the tools, the fence or the domain is replaced.

  The cases follow this step's own obligations:

  - the pack declares four tools, each rejecting undeclared keys, and its own
    source names no cutter, plan-apply, move or settings-write API;
  - a read answers from the frozen copy under its own digest, a run narrowing to
    a ref the copy holds pages only that run's issues, and a cursor from another
    day, filter set or position refuses;
  - the stored crew rules read reports the copy's own numbers - a negative break
    stays negative and an unmeasured leg keeps its unknown status - with no
    recomputation and no operator or roster field anywhere in the answer;
  - `uncovered_only` stays `uncovered_only` however small the uncovered list is
    and is never promoted to `replace_all`, which is only prepared when asked
    for explicitly;
  - a prepared scope carries configuration only - no plan, no run list, no actor
    - and neither the prepared call nor any read changes a stored trip_run,
    crew or roster row.

  Rows are created inside the SQL Sandbox transaction and rolled back. The
  focused gate command is handed to branch review:
  `mix test test/gtfs_planner/agents/packs/runs_test.exs`.
  """
  use GtfsPlanner.DataCase, async: true

  import GtfsPlanner.AccountsFixtures,
    only: [
      deactivate_membership_fixture: 1,
      editor_audit_fixture: 2,
      organization_membership_fixture: 2,
      user_fixture: 0
    ]

  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures, only: [route_fixture: 3, stop_fixture: 3]
  import GtfsPlanner.OperationsFixtures, only: [garage_fixture: 2]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RunsFixtures, only: [trip_run_fixture: 3]
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Dispatch
  alias GtfsPlanner.Agents.Packs.Runs
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.OperationsAssistance
  alias GtfsPlanner.Gtfs.RosterLine
  alias GtfsPlanner.Gtfs.RosterLineDay
  alias GtfsPlanner.Gtfs.Runs, as: RunsDomain
  alias GtfsPlanner.Gtfs.TripRun
  alias GtfsPlanner.Operations.Operator

  @pack_source "lib/gtfs_planner/agents/packs/runs.ex"

  # A sentinel planted in every operator, roster and seniority field of the
  # fixture world, so "the answer carries no personnel" is a real observation.
  @sentinel "OPERATOR-SENTINEL"

  # Every call a prepare-only pack must never make, however it is spelled.
  @forbidden_calls ~w(
    suggest_runs
    apply_run_plan
    apply_moves
    update_crew_settings
    update_settings
    update_relief_settings
    put_deadhead_time
    clear_deadhead_time
    remove_orphans
    rename_run
  )

  describe "pack declaration" do
    test "declares exactly the four runs tools with their activity labels" do
      assert Runs.id() == "runs"
      assert Runs.title() == "Runs helper"
      assert Runs.intro() =~ "crew rules"

      assert Enum.map(Runs.tools(), & &1.name) == [
               "get_run_issues",
               "get_crew_rules",
               "prepare_run_suggestion",
               "inspect_run_proposal"
             ]

      assert Enum.map(Runs.tools(), & &1.activity) == [
               "Checked this day's run issues",
               "Checked this day's stored crew rules",
               "Prepared a run suggestion scope",
               "Inspected a run proposal"
             ]

      assert Enum.all?(Runs.tools(), &(&1.parameters["additionalProperties"] == false))
    end

    test "names no cutter, apply or settings write API in its own source" do
      source = File.read!(Path.join(File.cwd!(), @pack_source))

      for call <- @forbidden_calls do
        refute source =~ ~r/\b#{call}\s*\(/
      end
    end

    test "the registry is the only place the agent core names this pack" do
      assert Agents.packs()["runs"] == Runs
    end
  end

  describe "reading a day's run issues" do
    setup :run_world

    test "answers from the frozen copy under its own digest", context do
      assert {:ok, result, evidence} = issues(context, %{"day_ref" => day_ref(context)})

      assert result["day_key"] == context.day_key
      assert result["digest"] == context.payload["source_digest"]
      assert result["completeness"] == "complete"
      assert result["scope"]["mode"] == "whole_day"
      assert result["total"] > 0
      assert length(result["rows"]) == result["total"]
      assert result["next_cursor"] == nil
      assert result["page_limited?"] == false

      # Uncovered work and orphan rows are the day's own counts, carried beside
      # the findings rather than inside them.
      assert result["uncovered"] == %{"trips" => 1, "secs" => 1_800}
      assert result["orphan_assignments"] == 1

      assert evidence.kind == "run_issues"
      assert evidence.total == result["total"]
      assert evidence.digest == result["digest"]
      assert evidence.source_revision == nil
      assert evidence.scope.gtfs_version_id == context.version.id
      assert evidence.resources == []
    end

    test "narrows to a run ref the frozen copy holds", context do
      ref = run_ref(context, "4001")

      assert {:ok, result, _evidence} =
               issues(context, %{"day_ref" => day_ref(context), "run_refs" => [ref]})

      assert result["filters"] == %{"run_refs" => [ref]}
      assert result["rows"] != []
      assert Enum.all?(result["rows"], &(ref in Map.get(&1, "run_refs", [])))
      assert result["total"] < length(context.payload["issues"])

      # The day-wide totals stay beside the page, so a narrowed answer never
      # reads as the whole day.
      assert result["totals"] == context.payload["totals"]
    end

    test "refuses a run ref this snapshot does not hold, twice, or empty", context do
      foreign = "run_" <> String.duplicate("a", 32)

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "run_refs" => [foreign]})

      assert message =~ "holds no run reference"

      ref = run_ref(context, "4001")

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "run_refs" => [ref, ref]})

      assert message =~ "named twice"

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "run_refs" => []})

      assert message == "Argument run_refs must have 1 or more items."
    end

    test "refuses a foreign day, an undeclared argument and a filter the copy does not carry",
         context do
      assert {:tool_error, message} =
               issues(context, %{"day_ref" => "day_" <> String.duplicate("a", 32)})

      assert message == "That day is not the day attached to this conversation."

      assert {:tool_error, "Unexpected argument: organization_id"} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "organization_id" => context.organization.id
               })

      assert {:tool_error, message} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "filters" => %{"code" => "no_such_code"}
               })

      assert message =~ "Start the list again"

      assert {:ok, result, _evidence} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "filters" => %{"severity" => "warning"}
               })

      assert Enum.all?(result["rows"], &(&1["severity"] == "warning"))
    end

    test "refuses a cursor from another day, another filter set or another position", context do
      # This day's issues fit one page, so the refusals are driven from a cursor
      # built out of the first page's own values: no cursor can name a position
      # this copy does not have.
      assert {:ok, first, _evidence} = issues(context, %{"day_ref" => day_ref(context)})

      cursor = %{
        "digest" => first["digest"],
        "collection" => "issues",
        "filters" => %{},
        "offset" => first["total"]
      }

      assert {:ok, same, _evidence} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => cursor})

      assert same["rows"] == []

      assert {:tool_error, "Unexpected argument: cursor.limit"} =
               issues(context, %{
                 "day_ref" => day_ref(context),
                 "cursor" => Map.put(cursor, "limit", 10)
               })

      stale = Map.put(cursor, "digest", String.duplicate("a", 64))

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => stale})

      assert message =~ "Start the list again"

      changed = Map.put(cursor, "filters", %{"run_refs" => [run_ref(context, "4001")]})

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => changed})

      assert message =~ "Start the list again"

      beyond = Map.put(cursor, "offset", first["total"] + 1)

      assert {:tool_error, message} =
               issues(context, %{"day_ref" => day_ref(context), "cursor" => beyond})

      assert message =~ "Start the list again"
    end

    test "the page is the copy's page, not a fresh read", context do
      assert {:ok, first, _evidence} = issues(context, %{"day_ref" => day_ref(context)})

      # A host reload and a fresh native suggestion of the same day change
      # nothing the frozen copy describes.
      assert {:ok, _runs_day} =
               RunsDomain.load_runs(context.organization.id, context.version.id, context.day_key)

      assert {:ok, _plan} =
               RunsDomain.suggest_runs(
                 context.organization.id,
                 context.version.id,
                 context.day_key,
                 :replace_all
               )

      assert {:ok, second, evidence} = issues(context, %{"day_ref" => day_ref(context)})

      assert second == first
      assert evidence.digest == context.payload["source_digest"]
    end
  end

  describe "reading the stored crew rules" do
    setup :run_world

    test "reports the copy's own rules and figures without recomputing them", context do
      assert {:ok, result, evidence} = crew(context, %{"day_ref" => day_ref(context)})

      rules = result["crew_rules"]

      # The researched defaults this version stores: read, not derived.
      assert rules["crew"]["report_pull_out_minutes"] == 15
      assert rules["crew"]["report_relief_minutes"] == 5
      assert rules["crew"]["sign_off_minutes"] == 5
      assert rules["crew"]["paid_break_max_minutes"] == 30
      assert rules["crew"]["max_spread_minutes"] == 720
      assert rules["max_piece_minutes"] == 120
      assert rules["planning_inputs"] == true
      assert rules["relief_ready"] == false

      assert result["run_count"] == 4
      assert result["figures"] == context.payload["figures"]
      assert result["orphans"] == %{"count" => 1}
      assert result["longest_spread"] == context.payload["figures"]["longest_spread"]

      assert evidence.kind == "crew_rules"
      assert evidence.total == 4
      assert evidence.source_revision == nil
    end

    test "a negative break stays negative and an unknown leg keeps its status", context do
      assert {:ok, result, _evidence} = crew(context, %{"day_ref" => day_ref(context)})

      # Run 3001's second block starts before the first ends, so the gap between
      # its pieces is negative in the domain and negative here. Nothing tidied
      # it, and the run's type is still the domain's own.
      assert [split] = result["negative_breaks"]
      assert split["run_id"] == "3001"
      assert split["after_piece"] == 1
      assert split["secs"] == -2_100
      assert split["paid?"] == false

      assert Enum.find(result["unknown_travel"], &(&1["to"] == "stop:NOCOORD"))

      derived = run_entity(context.payload, "3001")
      assert derived["type"] == "split"
      assert result["negative_breaks"] == negative_breaks_in_copy(context.payload)
    end

    test "carries no operator, roster or assignment field", context do
      assert {:ok, result, evidence} = crew(context, %{"day_ref" => day_ref(context)})

      # The roster fixture below stores a real operator row for this day, and the
      # copy carries none of it: no name, no employee number, no seniority, no
      # run assignment.
      assert context.roster.operator_id
      serialized = Jason.encode!(%{result: result, evidence: evidence})

      for forbidden <- [
            "employee",
            "operator",
            "roster",
            "seniority",
            "qualification",
            "membership",
            @sentinel
          ] do
        refute String.downcase(serialized) =~ forbidden
      end
    end

    test "refuses a foreign day and an undeclared argument", context do
      assert {:tool_error, message} = crew(context, %{"day_ref" => "day_nope"})

      assert message == "That day is not the day attached to this conversation."

      assert {:tool_error, "Unexpected argument: run_ids"} =
               crew(context, %{"day_ref" => day_ref(context), "run_ids" => ["4001"]})
    end

    test "an omitted day_ref reads the attached day the supplied one names", context do
      # The ref is an opaque server-generated digest the model can neither derive
      # nor retype, so leaving it out has to reach the same day rather than fail.
      assert {:ok, omitted, omitted_evidence} = crew(context, %{})
      assert {:ok, supplied, supplied_evidence} = crew(context, %{"day_ref" => day_ref(context)})

      assert omitted == supplied
      assert omitted_evidence == supplied_evidence
      assert omitted["day_ref"] == day_ref(context)

      # The fence is unchanged for a ref that is supplied.
      assert {:tool_error, "That day is not the day attached to this conversation."} =
               crew(context, %{"day_ref" => "day_nope"})
    end

    test "an omitted day_ref prepares the attached day's scope", context do
      assert {:prepared, prepared, result, _evidence} =
               prepare(context, %{"scope" => "uncovered_only"})

      assert {:operations_suggestion, command} = prepared.command
      assert command.day_key == context.day_key
      assert result["day_ref"] == day_ref(context)
      assert result["suggestion_started?"] == false
      assert result["saved?"] == false
    end
  end

  describe "preparing a run suggestion scope" do
    setup :run_world

    test "prepares configuration only, with no plan, run list or actor", context do
      before_counts = row_counts()

      assert {:prepared, prepared, result, evidence} =
               prepare(context, %{"day_ref" => day_ref(context), "scope" => "replace_all"})

      assert {:operations_suggestion, command} = prepared.command

      assert command == %{
               section: "runs",
               day_key: context.day_key,
               source_digest: context.payload["source_digest"],
               selection_digest: selection_digest(context.payload),
               mode: "replace_all"
             }

      assert prepared.summary.title == "Recut the whole day on #{context.day_key}"
      assert result["suggestion_started?"] == false
      assert result["saved?"] == false
      assert result["runs_in_scope"] == 4
      assert evidence.kind == "run_suggestion_configuration"

      # No write plan, no run list and no actor travel with the configuration.
      refute Jason.encode!(%{result: result, evidence: evidence}) =~ "apply_run_plan"
      refute Jason.encode!(result) =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-/
      refute inspect(prepared) =~ ~r/[0-9a-f]{8}-[0-9a-f]{4}-/

      # Preparing a scope starts no cutter, moves no assignment and writes no
      # crew or roster row.
      assert row_counts() == before_counts
    end

    test "uncovered-only stays uncovered-only on a day with one uncovered trip", context do
      assert {:prepared, %{command: {:operations_suggestion, command}}, result, _evidence} =
               prepare(context, %{"day_ref" => day_ref(context), "scope" => "uncovered_only"})

      assert command.mode == "uncovered_only"
      assert result["mode"] == "uncovered_only"
      assert result["uncovered"] == %{"trips" => 1, "secs" => 1_800}

      # The summary names the narrow scope and says what it keeps.
      [first, second, third] = result_lines(context, "uncovered_only")
      assert first == "Works only on the 1 trips no run covers on #{context.day_key}"
      assert second == "Keeps every run already on this day"
      assert third == "Nothing is cut or saved yet"
    end

    test "uncovered-only on a fully covered day is still uncovered-only", context do
      context = cover_uncovered!(context)

      assert {:prepared, %{command: {:operations_suggestion, command}}, result, _evidence} =
               prepare(context, %{"day_ref" => day_ref(context), "scope" => "uncovered_only"})

      # Nothing is uncovered, which is exactly the case where a rebuild would be
      # the wider scope nobody asked for. The mode does not widen.
      assert result["uncovered"] == %{"trips" => 0, "secs" => 0}
      assert command.mode == "uncovered_only"
    end

    test "refuses a third scope, a selected mode and an undeclared target list", context do
      assert {:tool_error, message} =
               prepare(context, %{"day_ref" => day_ref(context), "scope" => "everything"})

      assert message == "scope must be one of: uncovered_only, replace_all."

      # Runs are cut in two scopes only: there is no selected or partial mode to
      # offer, and a target list would be an argument that widened the native
      # cutter's own scope.
      assert {:tool_error, message} =
               prepare(context, %{"day_ref" => day_ref(context), "scope" => "selected"})

      assert message == "scope must be one of: uncovered_only, replace_all."

      assert {:tool_error, "Unexpected argument: run_ids"} =
               prepare(context, %{
                 "day_ref" => day_ref(context),
                 "scope" => "replace_all",
                 "run_ids" => ["4001"]
               })
    end
  end

  describe "inspecting a completed proposal" do
    setup :run_world

    test "reads the proposal the page already holds", context do
      context = with_plan!(context)

      assert {:ok, result, evidence} =
               inspect_plan(context, %{"plan_ref" => plan_ref(context)})

      assert result["day_key"] == context.day_key
      assert result["plan_ref"] == plan_ref(context)
      assert result["proposal"]["mode"] == "replace_all"
      assert is_integer(result["proposal"]["move_count"])
      assert evidence.kind == "run_proposal"
      assert evidence.digest == context.payload["source_digest"]

      # A runs proposal has no leftovers of its own: the uncovered work is the
      # day's own labelled count, disclosed beside the proposal rather than
      # counted twice.
      assert result["proposal"]["leftovers"] == []
      assert Enum.any?(evidence.exclusions, &(&1 =~ "trips no run covers"))
    end

    test "refuses no proposal at all and one the page does not hold", context do
      # No native cutter has run, so the attached copy carries no proposal.
      assert {:tool_error, message} =
               inspect_plan(context, %{"plan_ref" => "plan_" <> String.duplicate("a", 32)})

      assert message =~ "no completed run proposal"

      context = with_plan!(context)

      assert {:tool_error, message} =
               inspect_plan(context, %{"plan_ref" => "plan_" <> String.duplicate("b", 32)})

      assert message =~ "not the one this page holds"
    end
  end

  describe "authorization" do
    setup :run_world

    test "a revoked membership refuses before the pack runs", context do
      assert Scope.authorize(context.scope) == :ok

      deactivate_membership_fixture(context.membership)

      assert Dispatch.call(Runs, context.scope, "get_run_issues", args(day_ref(context))) ==
               {:error, :forbidden}

      assert Dispatch.call(
               Runs,
               context.scope,
               "prepare_run_suggestion",
               Jason.encode!(%{"day_ref" => day_ref(context), "scope" => "uncovered_only"})
             ) == {:error, :forbidden}
    end

    test "a conversation with no attached day is unavailable", context do
      bare = %{context.scope | resource_context: Scope.context({:version, context.version.id})}

      assert Runs.authorize_context(bare) == {:error, :unavailable}

      assert Dispatch.call(Runs, bare, "get_crew_rules", args(day_ref(context))) ==
               {:error, :unavailable}
    end

    test "another section's snapshot and a foreign identity refuse alike", context do
      {:ok, blocks_context} =
        OperationsAssistance.context({:version, context.version.id}, %{
          "schema_version" => 1,
          "section" => "blocks",
          "day_key" => context.day_key,
          "issues" => []
        })

      assert Runs.authorize_context(%{context.scope | resource_context: blocks_context}) ==
               {:error, :unavailable}

      %Scope{} = scope = context.scope

      routed = %{
        scope
        | resource_context:
            Map.put(scope.resource_context, :identity, {:route, Ecto.UUID.generate()})
      }

      assert Runs.authorize_context(routed) == {:error, :unavailable}
    end

    test "a day type the catalog no longer derives refuses", context do
      stale_payload = Map.put(context.payload, "day_key", "2026:1:absent")

      assert {:ok, resource_context} =
               Scope.with_source_snapshot(Scope.context({:version, context.version.id}), %{
                 kind: "operations_runs",
                 payload: stale_payload
               })

      assert Runs.authorize_context(%{context.scope | resource_context: resource_context}) ==
               {:error, :unavailable}
    end
  end

  # --- the fence -----------------------------------------------------------

  defp issues(context, tool_args) do
    Dispatch.call(Runs, context.scope, "get_run_issues", Jason.encode!(tool_args))
  end

  defp crew(context, tool_args) do
    Dispatch.call(Runs, context.scope, "get_crew_rules", Jason.encode!(tool_args))
  end

  defp prepare(context, tool_args) do
    Dispatch.call(Runs, context.scope, "prepare_run_suggestion", Jason.encode!(tool_args))
  end

  defp inspect_plan(context, tool_args) do
    Dispatch.call(Runs, context.scope, "inspect_run_proposal", Jason.encode!(tool_args))
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

  defp run_ref(context, run_id), do: run_entity(context.payload, run_id)["run_ref"]

  defp run_entity(payload, run_id) do
    Enum.find(payload["entities"]["runs"], &(&1["run_id"] == run_id))
  end

  defp negative_breaks_in_copy(payload) do
    for run <- payload["entities"]["runs"],
        break <- run["breaks"],
        break["secs"] < 0,
        do: %{
          "run_ref" => run["run_ref"],
          "run_id" => run["run_id"],
          "after_piece" => break["after_piece"],
          "secs" => break["secs"],
          "paid?" => break["paid?"]
        }
  end

  defp result_lines(context, scope) do
    assert {:prepared, prepared, _result, _evidence} =
             prepare(context, %{"day_ref" => day_ref(context), "scope" => scope})

    prepared.summary.lines
  end

  defp plan_ref(context), do: context.payload["plan"]["plan_ref"]

  defp row_counts do
    %{
      trip_runs: Repo.aggregate(TripRun, :count),
      crews: Repo.aggregate(GtfsPlanner.Gtfs.BlockingSetting, :count),
      operators: Repo.aggregate(Operator, :count),
      roster_lines: Repo.aggregate(RosterLine, :count),
      roster_line_days: Repo.aggregate(RosterLineDay, :count),
      change_logs: Repo.aggregate(GtfsPlanner.Gtfs.ChangeLog, :count)
    }
  end

  # A host that publishes a completed proposal attaches its copy to the frozen
  # day and republishes the resource context, which is what the page will do.
  defp with_plan!(context) do
    assert {:ok, plan} =
             RunsDomain.suggest_runs(
               context.organization.id,
               context.version.id,
               context.day_key,
               :replace_all
             )

    assert {:ok, payload} = OperationsAssistance.with_plan(context.payload, :runs, plan)

    attach(context, payload)
  end

  # Giving the last uncovered trip a run makes the day fully covered, which is
  # the state a helper must not read as "rebuild everything".
  defp cover_uncovered!(context) do
    assert {:ok, runs_day} =
             RunsDomain.load_runs(context.organization.id, context.version.id, context.day_key)

    free = uncovered_trip(runs_day)
    existing = runs_day.derived.runs |> hd() |> Map.fetch!(:run_id)

    trip_run_fixture(context.organization.id, context.version.id, %{
      trip: free,
      day_type_key: context.day_key,
      run_id: existing
    })

    refresh(context)
  end

  defp refresh(context) do
    assert {:ok, runs_day} =
             RunsDomain.load_runs(context.organization.id, context.version.id, context.day_key)

    assert {:ok, payload} = OperationsAssistance.run_day(runs_day)

    attach(context, payload)
  end

  defp uncovered_trip(runs_day) do
    covered = MapSet.new(runs_day.assignments, &elem(&1, 0))

    Enum.find(runs_day.day.blocks, fn block ->
      Enum.any?(block.trips, &(not MapSet.member?(covered, &1.id)))
    end).trips
    |> hd()
  end

  defp attach(context, payload) do
    assert {:ok, resource_context} =
             OperationsAssistance.context({:version, context.version.id}, payload)

    %{context | payload: payload, scope: %{context.scope | resource_context: resource_context}}
  end

  # --- the world -----------------------------------------------------------

  # Four blocks, six trips and four runs, seeded so the day's own findings hold
  # every shape the pack has to explain: one overnight piece over the stored
  # limit, one negative break between two pieces of a single run, two runs
  # handed over at a stop the geometry cannot measure, one uncovered trip and one
  # orphan assignment row. The clocks are the domain's own; this only stores
  # them.
  defp run_world(_context) do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    audit = editor_audit_fixture(organization, version)
    route = route_fixture(organization.id, version.id, %{route_id: "R1"})

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    # The garage sits on the same point as the day's stops, so a drive the day's
    # geometry does not imply measures to a real zero. `NOCOORD` has no point at
    # all, which is what makes the legs to and from it unknown rather than
    # measured.
    garage =
      garage_fixture(organization.id, %{
        "lat" => Decimal.new("40.0"),
        "lon" => Decimal.new("-74.0")
      })

    stop_fixture(organization.id, version.id, %{
      stop_id: "BAY_A",
      stop_name: "Bay A",
      stop_lat: Decimal.new("40.0"),
      stop_lon: Decimal.new("-74.0")
    })

    stop_fixture(organization.id, version.id, %{
      stop_id: "NOCOORD",
      stop_name: "Nowhere",
      stop_lat: nil,
      stop_lon: nil
    })

    {:ok, _settings} =
      Blocking.update_settings(audit, %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: "any",
        default_garage_id: garage.id,
        deadhead_speed_kmh: 30,
        deadhead_circuity: 1.3,
        max_piece_minutes: nil
      })

    # A 120-minute piece limit with no marked relief point: no candidate exists
    # on this day, so a cut cannot be planned into it and the copy says so.
    {:ok, :ok} =
      Blocking.update_relief_settings(audit, nil, %{max_piece_minutes: 120, marked: []})

    day_key = day_key!(organization, version)

    world = %{organization: organization, version: version, route: route, day_key: day_key}

    seed_runs(world)

    # One assignment row under a day type key this version no longer has. It is
    # counted on every day type's page, and it is the day's one orphan.
    free_trip =
      trip(world, "free", "205", "11:00:00", "11:30:00", "BAY_A", "BAY_A", nil)

    trip_run_fixture(organization.id, version.id, %{
      trip: free_trip,
      day_type_key: "deleted-day-type",
      run_id: "7777"
    })

    user = user_fixture()
    membership = organization_membership_fixture(user, organization)

    # A real operator, roster line and roster-day row for this day, holding the
    # sentinel in every field a helper must never carry. Nothing below reads them
    # back into an answer; they are here so their absence from the pack's output
    # is a real absence rather than an absent fixture.
    roster = roster!(organization, version, day_key)

    assert {:ok, runs_day} = RunsDomain.load_runs(organization.id, version.id, day_key)
    assert {:ok, payload} = OperationsAssistance.run_day(runs_day)

    context = %{
      organization: organization,
      version: version,
      day_key: day_key,
      payload: payload,
      membership: membership,
      roster: roster,
      scope: %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        user_id: user.id,
        user_email: user.email,
        pack_id: "runs",
        version_name: version.name
      }
    }

    attach(context, payload)
  end

  # One operator with a sentinel employee id, display name and seniority, one
  # weekly line holding them, and one run-day that assigns run 3001 to that
  # operator with its sign-on and sign-off seconds.
  defp roster!(organization, version, day_key) do
    operator =
      Repo.insert!(
        struct(%Operator{}, %{
          organization_id: organization.id,
          employee_id: @sentinel,
          display_name: @sentinel,
          seniority_number: 99
        })
      )

    line =
      Repo.insert!(
        struct(%RosterLine{}, %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          line_number: 1,
          operator_id: operator.id
        })
      )

    day =
      Repo.insert!(
        struct(%RosterLineDay{}, %{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          roster_line_id: line.id,
          weekday: 2,
          day_type_key: day_key,
          run_id: "3001",
          run_sign_on_secs: 20_100,
          run_sign_off_secs: 25_500
        })
      )

    %{operator: operator, line: line, day: day, operator_id: operator.id}
  end

  defp seed_runs(context) do
    trip(context, "night", "201", "22:30:00", "25:10:00", "BAY_A", "BAY_A", "4001")
    trip(context, "hand_out", "202", "08:00:00", "08:30:00", "BAY_A", "NOCOORD", "5001")
    trip(context, "hand_in", "202", "09:00:00", "09:30:00", "NOCOORD", "NOCOORD", "5002")
    trip(context, "early", "203", "05:50:00", "06:50:00", "BAY_A", "BAY_A", "3001")
    trip(context, "late", "204", "06:30:00", "07:00:00", "BAY_A", "BAY_A", "3001")
  end

  defp trip(context, trip_id, block_id, first, last, first_stop, last_stop, run_id) do
    trip =
      blocked_trip_fixture(context.organization.id, context.version.id, context.route.route_id, %{
        trip_id: trip_id,
        service_id: "WK",
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_departure: first,
        last_arrival: last
      })

    if run_id do
      trip_run_fixture(context.organization.id, context.version.id, %{
        trip: trip,
        day_type_key: context.day_key,
        run_id: run_id
      })
    end

    trip
  end

  defp day_key!(organization, version) do
    {:ok, day} = Blocking.load_day(organization.id, version.id, nil)
    day.day_type.key
  end
end

defmodule GtfsPlanner.Agents.Packs.Blocks do
  @moduledoc """
  The Blocks helper pack: bounded reads of one frozen blocking day and one
  prepared block-suggestion scope.

  Every tool reads the immutable source snapshot the host admitted for this
  conversation - the copy `GtfsPlanner.Gtfs.OperationsAssistance.block_day/2`
  built and `context/2` admitted under the kind `operations_blocks` - and never
  reloads the day. A read therefore answers about the day as it was when the
  page published that copy, labelled with the copy's own `source_digest`; the
  native handoff, not this pack, is what re-checks the current loaded inputs.

  Nothing here starts a solver or writes a row. `suggest_blocks/4` and
  `apply_block_plan/3` are not called anywhere in this pack's call graph, and no
  write, actor or command value reaches a tool result:
  `prepare_block_suggestion/3` returns `{:prepared, prepared, result, evidence}`
  whose command is the configuration tuple the owning LiveView interprets -
  `{:operations_suggestion, %{section:, day_key:, source_digest:,
  selection_digest:, mode:}}` - carrying no target list and no plan. Which blocks
  a `selected` scope would rebuild is the attached selection, bound by
  `selection_digest`, so an argument cannot widen or narrow it. The `selected`
  mode is offered only for a nonempty displayed block selection, and an empty
  pool never promotes `unassigned_only` to `replace_all` (AC-7).

  `authorize_context/1` is the fence the shared owner asks of this pack: the
  version identity, the current day catalog and every technical trip identity the
  copy names are resolved with scoped queries, and a malformed, foreign or
  deleted scope returns the single `{:error, :unavailable}` result before any
  provider request, tool read, delivered result or prepared lookup. Membership
  remains `Scope`'s authority and is checked separately by `Dispatch`.

  Arguments carry no authority: the day is the attached `day_ref`, an issue page
  is a cursor over the frozen collection, and a detail request may only narrow to
  trip refs this snapshot holds. Enum, distinctness and digest equality are
  enforced in this module's code rather than by a schema keyword the dispatch
  fence does not implement.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Packs.Operations
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.OperationsAssistance

  @section "blocks"
  @source_ref "gtfs_blocking"

  @snapshot %{
    kind: "operations_blocks",
    section: @section,
    map_keys: ["scope", "selection", "constraints", "entities"],
    unavailable:
      "This conversation has no blocking day attached. Ask the editor to reload the Blocks page, then start again."
  }

  @scoped_reason "This day was read for the selection shown on the page, not the whole day."

  # The modes the native drawer itself understands. The enum is checked here
  # rather than in a schema keyword `Dispatch` does not implement.
  @modes ["unassigned_only", "selected", "replace_all"]

  # A detail request is all-or-refuse above this many trip refs; a run-oriented
  # `run_refs` filter does not exist here because a blocks snapshot holds no
  # runs, so offering it could only ever be refused.
  @max_detail_trips 100

  # The issues a detail read reports are capped rather than left to the shared
  # result ceiling, and the count beside the rows discloses the cap.
  @max_detail_issues 50

  # Resources are typed references the panel may resolve; a blocks snapshot's
  # route ids are the only allowlisted kind, and they are bounded so the evidence
  # stays inside the same ceiling the page was served under.
  @max_resources 10

  @skill_path Path.expand("../../../../priv/agents/packs/blocks/SKILL.md", __DIR__)
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
  def id, do: "blocks"

  @impl true
  def title, do: "Blocks helper"

  @impl true
  def intro do
    "I can explain this day's blocking problems and stored rules, compare a proposal this page already holds, and prepare which blocks a suggestion would rebuild. I can't build or save blocks."
  end

  @impl true
  def examples,
    do: ["What is wrong with this day's blocks?", "Get me ready to rebuild two blocks"]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "get_blocking_issues",
        description:
          "List this day's blocking issues from the frozen copy attached to this conversation, " <>
            "narrowed by an optional issue code and severity. At most 50 issues are returned per " <>
            "page; keep reading with next_cursor until it is absent before describing the whole " <>
            "day, and say which frozen totals you read.",
        activity: "Checked this day's blocking issues",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "day_ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
            "filters" => filters_schema(),
            "cursor" => cursor_schema()
          },
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "inspect_blocking_constraints",
        description:
          "Report this day's stored blocking rules together with the technical identities and " <>
            "issues of the named trips, so you can explain why a trip is blocked or still loose. " <>
            "Name at most #{@max_detail_trips} trip_refs from a previous answer; a ref this " <>
            "snapshot does not hold is refused. This read never widens the day's scope and never " <>
            "proposes rebuilding anything.",
        activity: "Inspected blocking constraints",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "day_ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
            "trip_refs" => %{
              "type" => "array",
              "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
              "minItems" => 1,
              "maxItems" => @max_detail_trips
            }
          },
          "required" => ["trip_refs"],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_block_suggestion",
        description:
          "Prepare which blocks a block suggestion would rebuild on this day, for the editor to " <>
            "review in *Suggest blocks*. It starts nothing, computes no plan and saves nothing. " <>
            "Use \"unassigned_only\" whenever the pool is empty: that mode must be passed " <>
            "explicitly and is never upgraded to a full rebuild. Use \"selected\" only when the " <>
            "editor has blocks selected on the page - you cannot name the targets, the attached " <>
            "selection is the only set it will rebuild. Use \"replace_all\" only for a full " <>
            "rebuild the editor asked for, and warn them it discards the existing blocks.",
        activity: "Prepared a block suggestion scope",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "day_ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
            "mode" => %{"type" => "string", "minLength" => 1, "maxLength" => 32}
          },
          "required" => ["mode"],
          "additionalProperties" => false
        }
      },
      %{
        name: "compare_block_proposal",
        description:
          "Compare the completed block proposal this page already holds, by the plan_ref a " <>
            "previous answer returned: its before and after figures, how many trips it moves, the " <>
            "trips it could not place and the problems it would add. It never re-runs anything, " <>
            "and a proposal the page no longer holds, one that has been replaced and one still " <>
            "running are all refused.",
        activity: "Compared a block proposal",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "plan_ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 255}
          },
          "required" => ["plan_ref"],
          "additionalProperties" => false
        }
      }
    ]
  end

  # Only the two filters a blocks snapshot can act on are declared, so the fence
  # rejects an undeclared one before this pack runs. `run_refs` belongs to the
  # runs pack: a blocks payload holds no runs, so it could only ever be refused.
  defp filters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "code" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
        "severity" => %{"type" => "string", "minLength" => 1, "maxLength" => 20}
      },
      "required" => [],
      "additionalProperties" => false
    }
  end

  # A cursor is the plain object the previous page returned: this snapshot's
  # digest, the collection, the filters it was read under and a non-negative
  # offset. It is rejected here when any field disagrees with this call.
  defp cursor_schema do
    %{
      "type" => "object",
      "properties" => %{
        "digest" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
        "collection" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
        "filters" => filters_schema(),
        "offset" => %{"type" => "integer", "minimum" => 0}
      },
      "required" => ["digest", "collection", "filters", "offset"],
      "additionalProperties" => false
    }
  end

  @doc """
  Returns `:ok` only for a scope whose attached snapshot is this pack's own.

  The check is the shared owner's own refusal, so a stale panel, another
  organization's day or a trip the current version no longer holds reads the same
  way: `{:error, :unavailable}`, before any request, read or prepared lookup.
  """
  @impl true
  def authorize_context(%Scope{} = scope), do: Operations.authorize_context(scope, @snapshot)

  @impl true
  def call("get_blocking_issues", args, %Scope{} = scope),
    do: get_blocking_issues(args, scope)

  def call("inspect_blocking_constraints", args, %Scope{} = scope),
    do: inspect_blocking_constraints(args, scope)

  def call("prepare_block_suggestion", args, %Scope{} = scope),
    do: prepare_block_suggestion(args, scope)

  def call("compare_block_proposal", args, %Scope{} = scope),
    do: compare_block_proposal(args, scope)

  # -- issue reads ---------------------------------------------------------

  defp get_blocking_issues(args, %Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         :ok <- Operations.check_day_ref(args["day_ref"], payload),
         {:ok, filters} <- Operations.read_filters(args["filters"]),
         {:ok, cursor} <-
           Operations.read_cursor(
             args["cursor"],
             payload,
             compact(filters),
             pager_filters(filters)
           ) do
      Operations.issues_page(payload, pager_filters(filters), cursor, fn page ->
        {issues_result(payload, page, filters), issues_evidence(scope, payload, page, filters)}
      end)
    end
  end

  # The pager normalizes absent filters to explicit nulls and carries a
  # `run_refs` key this section never sets, so the cursor it compares against is
  # rebuilt here rather than echoed. A blocks snapshot holds no runs, so that key
  # is always empty and no run ref could narrow this collection.
  defp pager_filters(filters) do
    %{
      "code" => Map.get(filters, "code"),
      "severity" => Map.get(filters, "severity"),
      "run_refs" => []
    }
  end

  defp compact(filters) do
    filters
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp issues_result(payload, page, filters) do
    %{
      "day_ref" => payload["day_ref"],
      "day_key" => payload["day_key"],
      "scope" => Operations.scope_summary(payload["scope"]),
      "completeness" => payload["completeness"],
      "totals" => payload["totals"],
      "filters" => compact(filters),
      "rows" => page.rows,
      "total" => page.total,
      "next_cursor" => Operations.tool_cursor(page.next_cursor, compact(filters)),
      "digest" => page.digest,
      "page_limited?" => page.total > length(page.rows)
    }
  end

  defp issues_evidence(%Scope{} = scope, payload, page, filters) do
    %{
      kind: "blocking_issues",
      title: "Blocking issues on #{payload["day_key"]}",
      total: page.total,
      total_label: "issue instances in the frozen day",
      completeness: Operations.completeness(payload),
      completeness_reason: Operations.completeness_reason(payload, @scoped_reason),
      facts: [
        %{label: "Day", value: payload["day_key"]},
        %{label: "Scope", value: payload["scope"]["mode"]},
        %{label: "Filtered by", value: filter_label(filters)},
        %{label: "Issues shown", value: "#{length(page.rows)} of #{page.total}"},
        %{label: "Completeness", value: payload["completeness"]}
      ],
      source_ref: @source_ref,
      digest: page.digest,
      # There is no native revision behind a frozen read: the day is a copy the
      # page published, not a stored document with a version of its own.
      source_revision: nil,
      scope: Operations.scope_evidence(scope),
      exclusions: Operations.exclusions(payload),
      resources: []
    }
  end

  defp filter_label(filters) do
    case compact(filters) |> Enum.sort() do
      [] -> "nothing"
      pairs -> Enum.map_join(pairs, ", ", fn {key, value} -> "#{key} #{value}" end)
    end
  end

  # -- constraint detail ---------------------------------------------------

  # This read narrows to trips the frozen copy already names. It cannot widen the
  # day's scope, and it answers with the day's own stored rules rather than any
  # recomputed figure: naming a pool trip here says what is stored about it, never
  # that it may be rebuilt.
  defp inspect_blocking_constraints(args, %Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         :ok <- Operations.check_day_ref(args["day_ref"], payload),
         {:ok, trip_refs} <- read_trip_refs(args["trip_refs"], payload),
         {:ok, trips} <- resolve_trips(trip_refs, payload) do
      matching = Enum.filter(payload["issues"], &names_any?(&1, trip_refs))
      shown = Enum.take(matching, @max_detail_issues)

      result = %{
        "day_ref" => payload["day_ref"],
        "day_key" => payload["day_key"],
        "scope" => payload["scope"],
        "completeness" => payload["completeness"],
        "constraints" => payload["constraints"],
        "trips" => trips,
        "issues" => shown,
        "matching_issue_count" => length(matching),
        "issues_capped_at" => @max_detail_issues,
        "digest" => payload["source_digest"]
      }

      {:ok, result, constraints_evidence(scope, payload, result, shown, length(matching))}
    end
  end

  defp read_trip_refs(refs, payload) when is_list(refs) do
    known = trip_refs(payload)

    cond do
      refs == [] ->
        {:error, "Name at least one trip to inspect."}

      length(refs) > @max_detail_trips ->
        {:error, "Name at most #{@max_detail_trips} trips at a time."}

      MapSet.size(MapSet.new(refs)) != length(refs) ->
        {:error, "The same trip was named twice."}

      not Enum.all?(refs, &(is_binary(&1) and String.length(&1) in 1..255)) ->
        {:error, "trip_refs must be trip references from this day's frozen copy."}

      true ->
        case Enum.find(refs, &(not MapSet.member?(known, &1))) do
          nil -> {:ok, refs}
          foreign -> {:error, unknown_trip_message(foreign)}
        end
    end
  end

  defp read_trip_refs(_refs, _payload),
    do: {:error, "trip_refs must be a list of trip references."}

  # An unknown ref is reported without naming what the snapshot does hold, so a
  # ref from another day or another section learns nothing about this one.
  defp unknown_trip_message(foreign) do
    "This day's frozen copy holds no trip reference #{foreign}. Read the day's issues first and use a trip_ref from that answer."
  end

  # Every ref was checked against this snapshot's own trips a step earlier, so
  # this only reads them back in the order the editor named them.
  defp resolve_trips(trip_refs, payload) do
    by_ref = Map.new(payload["entities"]["trips"], &{&1["trip_ref"], &1})
    {:ok, Enum.map(trip_refs, &Map.fetch!(by_ref, &1))}
  end

  defp names_any?(issue, trip_refs) do
    Enum.any?(Map.get(issue, "trip_refs", []), &(&1 in trip_refs))
  end

  defp constraints_evidence(%Scope{} = scope, payload, result, shown, matching) do
    %{
      kind: "blocking_constraints",
      title: "Stored blocking rules on #{payload["day_key"]}",
      total: length(result["trips"]),
      total_label: "trips inspected",
      completeness: Operations.completeness(payload),
      completeness_reason: Operations.completeness_reason(payload, @scoped_reason),
      facts: [
        %{label: "Day", value: payload["day_key"]},
        %{label: "Trips named", value: Integer.to_string(length(result["trips"]))},
        %{label: "Issues naming them", value: Integer.to_string(matching)},
        %{
          label: "Issues shown",
          value: "#{length(shown)} of #{matching} (cap #{@max_detail_issues})"
        },
        %{label: "Scope", value: payload["scope"]["mode"]}
      ],
      source_ref: @source_ref,
      digest: payload["source_digest"],
      source_revision: nil,
      scope: Operations.scope_evidence(scope),
      exclusions: Operations.exclusions(payload),
      resources: route_resources(result["trips"])
    }
  end

  # -- prepared configuration ----------------------------------------------

  # The command is configuration, not a plan: a section, the day, the two
  # digests the host re-checks before opening its drawer, and the mode. There is
  # no target list, no plan and no actor, and nothing in this path reaches
  # `suggest_blocks/4` or `apply_block_plan/3`.
  defp prepare_block_suggestion(args, %Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         :ok <- Operations.check_day_ref(args["day_ref"], payload),
         {:ok, mode} <- read_mode(args["mode"]),
         :ok <- check_selected_scope(mode, payload) do
      command =
        {:operations_suggestion,
         %{
           section: @section,
           day_key: payload["day_key"],
           source_digest: payload["source_digest"],
           selection_digest: selection_digest(payload),
           mode: mode
         }}

      result = configuration_result(payload, mode, command)

      {:prepared, %{summary: summary(payload, mode), command: command}, result,
       configuration_evidence(scope, payload, mode, result)}
    end
  end

  defp read_mode(mode) when mode in @modes, do: {:ok, mode}

  defp read_mode(_mode) do
    {:error, "mode must be one of: " <> Enum.join(@modes, ", ") <> "."}
  end

  # `selected` rebuilds the blocks the editor has selected on the page. It is
  # offered only for a nonempty displayed selection whose refs this snapshot
  # holds: a mode with no targets would rebuild one block the editor did not
  # ask about, and a forged selection has no evidence behind it. A pool-only
  # selection is not a rebuildable one, so it refuses here rather than being
  # turned into a solver mode of its own.
  defp check_selected_scope("selected", payload) do
    selection = payload["selection"]
    block_refs = selection["selected_block_refs"]
    known = block_refs(payload)

    cond do
      block_refs == [] and selection["selected_trip_refs"] != [] ->
        {:error,
         "Only trips are selected, and a trip selection cannot be rebuilt. Ask the editor to " <>
           "select the blocks themselves."}

      block_refs == [] ->
        {:error,
         "No blocks are selected on this page. Ask the editor to select the blocks to rebuild."}

      Enum.any?(block_refs, &(not MapSet.member?(known, &1))) ->
        {:error, "The selected blocks are not part of this day's frozen copy."}

      true ->
        :ok
    end
  end

  defp check_selected_scope(_mode, _payload), do: :ok

  # The selection digest binds the exact blocks the editor had selected when the
  # copy was published, so the host can refuse a prepared scope whose selection
  # has since changed without this pack ever naming a target. It is the shared
  # projection's own function, so the host recomputes exactly what this wrote.
  defp selection_digest(payload), do: OperationsAssistance.selection_digest(payload)

  defp configuration_result(payload, mode, command) do
    {_tag, prepared} = command

    %{
      "day_ref" => payload["day_ref"],
      "day_key" => prepared.day_key,
      "mode" => mode,
      "scope" => payload["scope"],
      "completeness" => payload["completeness"],
      "selected_block_count" => length(payload["selection"]["selected_block_refs"]),
      "selected_trip_count" => length(payload["selection"]["selected_trip_refs"]),
      "blocks_in_scope" => day_count(payload, :blocks),
      "source_digest" => prepared.source_digest,
      "selection_digest" => prepared.selection_digest,
      "suggestion_started?" => false,
      "saved?" => false,
      "totals" => payload["totals"]
    }
  end

  defp summary(payload, mode) do
    %{
      title: "#{mode_label(mode)} on #{payload["day_key"]}",
      detail: summary_detail(payload, mode),
      lines: summary_lines(payload, mode)
    }
  end

  # Day-wide counts exist only in a whole-day copy. With a selection on the page
  # the copy's blocks and scope refs hold only that selection, while a full
  # rebuild or an unassigned-only run reaches the whole day, so a count taken
  # from the selection would understate what the editor is about to start.
  defp day_count(%{"scope" => %{"mode" => "whole_day"}} = payload, :blocks),
    do: length(payload["entities"]["blocks"])

  defp day_count(%{"scope" => %{"mode" => "whole_day"}} = payload, :unassigned),
    do: length(payload["scope"]["trip_refs"])

  defp day_count(_payload, _kind), do: nil

  defp summary_detail(payload, mode) do
    case {day_count(payload, :blocks), mode} do
      {nil, "selected"} ->
        "#{length(payload["selection"]["selected_block_refs"])} blocks selected on this page"

      {nil, _mode} ->
        "The page has a selection, so this copy holds no day-wide counts"

      {blocks, _mode} ->
        "#{blocks} blocks in the day's scope"
    end
  end

  defp summary_lines(payload, "replace_all") do
    rebuilds =
      case day_count(payload, :blocks) do
        nil -> "Rebuilds every block on #{payload["day_key"]}, not only the selected ones"
        blocks -> "Rebuilds every block on #{payload["day_key"]} · #{blocks} blocks"
      end

    [rebuilds, "Existing blocks on this day are replaced", "Nothing is suggested or saved yet"]
  end

  defp summary_lines(payload, "selected") do
    selected = length(payload["selection"]["selected_block_refs"])

    [
      "Rebuilds the #{selected} blocks selected on this page",
      "Keeps every other block on #{payload["day_key"]}",
      "Nothing is suggested or saved yet"
    ]
  end

  # An empty pool is exactly the case where the native drawer would otherwise
  # default to a full rebuild, so the summary states the unassigned scope plainly
  # and never offers the wider one.
  defp summary_lines(payload, "unassigned_only") do
    works =
      case day_count(payload, :unassigned) do
        nil -> "Works only on the trips with no block on #{payload["day_key"]}"
        trips -> "Works only on the #{trips} trips with no block on #{payload["day_key"]}"
      end

    [works, "Keeps every block already on this day", "Nothing is suggested or saved yet"]
  end

  defp mode_label("unassigned_only"), do: "Unassigned work only"
  defp mode_label("selected"), do: "Rebuild selected blocks"
  defp mode_label("replace_all"), do: "Rebuild the whole day"

  defp configuration_evidence(%Scope{} = scope, payload, mode, result) do
    %{
      kind: "block_suggestion_configuration",
      title: "#{mode_label(mode)} on #{payload["day_key"]}",
      total: result["selected_block_count"],
      total_label: "selected blocks in the prepared scope",
      completeness: Operations.completeness(payload),
      completeness_reason: Operations.completeness_reason(payload, @scoped_reason),
      facts:
        Enum.concat([
          [%{label: "Day", value: payload["day_key"]}, %{label: "Mode", value: mode}],
          day_count_facts(payload),
          [%{label: "Started", value: "No · the editor starts it in Suggest blocks"}]
        ]),
      source_ref: @source_ref,
      digest: payload["source_digest"],
      source_revision: nil,
      scope: Operations.scope_evidence(scope),
      exclusions: Operations.exclusions(payload),
      resources: []
    }
  end

  defp day_count_facts(payload) do
    case {day_count(payload, :blocks), day_count(payload, :unassigned)} do
      {nil, nil} ->
        [%{label: "Day-wide counts", value: "Not in this copy · the page has a selection"}]

      {blocks, unassigned} ->
        [
          %{label: "Blocks in the day's scope", value: Integer.to_string(blocks)},
          %{label: "Unassigned trips in scope", value: Integer.to_string(unassigned)}
        ]
    end
  end

  # -- completed proposal --------------------------------------------------

  # The comparison reads the plan copy the attached snapshot carries. There is no
  # recomputation and no host callback: a snapshot with no plan, one whose
  # `plan_ref` names a different plan and one whose plan was replaced are all the
  # same refusal, because a proposal this page no longer holds cannot be
  # compared honestly.
  defp compare_block_proposal(args, %Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         {:ok, plan} <- attached_plan(payload),
         :ok <- check_plan_ref(args["plan_ref"], plan) do
      result = %{
        "day_ref" => payload["day_ref"],
        "day_key" => payload["day_key"],
        "plan_ref" => plan["plan_ref"],
        "native_fingerprint" => plan["native_fingerprint"],
        "proposal" => plan,
        "digest" => payload["source_digest"]
      }

      {:ok, result, proposal_evidence(scope, payload, plan, result)}
    end
  end

  defp attached_plan(payload) do
    case Map.get(payload, "plan") do
      %{"plan_ref" => plan_ref, "section" => @section} when is_binary(plan_ref) ->
        {:ok, Map.fetch!(payload, "plan")}

      _none ->
        {:error, "This page holds no completed block proposal to compare."}
    end
  end

  defp check_plan_ref(plan_ref, plan) do
    if plan_ref == plan["plan_ref"] do
      :ok
    else
      {:error,
       "That proposal is not the one this page holds. It may have been replaced; ask the editor " <>
         "to start the suggestion again."}
    end
  end

  defp proposal_evidence(%Scope{} = scope, payload, plan, result) do
    before_figures = plan["before"]
    after_figures = plan["after"]

    %{
      kind: "block_proposal",
      title: "Block proposal for #{payload["day_key"]}",
      total: plan["move_count"],
      total_label: "trips the proposal moves",
      completeness: Operations.completeness(payload),
      completeness_reason: Operations.completeness_reason(payload, @scoped_reason),
      facts: [
        %{label: "Day", value: payload["day_key"]},
        %{label: "Mode", value: proposal_mode(plan["mode"])},
        %{label: "Blocks before", value: Integer.to_string(before_figures["vehicles"])},
        %{label: "Blocks after", value: Integer.to_string(after_figures["vehicles"])},
        %{
          label: "Problems before and after",
          value: "#{before_figures["problems"]} → #{after_figures["problems"]}"
        },
        %{
          label: "Trips it could not place",
          value: Integer.to_string(length(plan["leftovers"]))
        },
        %{
          label: "Problems it would add",
          value: Integer.to_string(length(plan["warnings"]))
        },
        %{label: "Applied", value: "No · a proposal until the editor applies it in the drawer"}
      ],
      source_ref: @source_ref,
      digest: result["digest"],
      source_revision: nil,
      scope: Operations.scope_evidence(scope),
      exclusions: leftovers(plan),
      resources: []
    }
  end

  defp proposal_mode("selected"), do: "selected blocks"
  defp proposal_mode(mode) when is_binary(mode), do: mode

  # -- the attached copy ---------------------------------------------------

  defp attached_payload(%Scope{} = scope), do: Operations.attached_payload(scope, @snapshot)

  # The leftovers a proposal could not place are reported as the proposal's own,
  # never as the day's problems.
  defp leftovers(plan) do
    plan["leftovers"]
    |> Enum.map(fn leftover ->
      "proposal could not place trip #{leftover["trip_id"]} (#{leftover["reason"]})"
    end)
  end

  # Only the route ids the panel already knows how to link are typed references.
  # Trip and block refs stay plain receipts: they belong to this frozen copy, and
  # a route link that resolves is the only navigation an answer may promise.
  defp route_resources(trips) do
    trips
    |> Enum.map(& &1["route_id"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_resources)
    |> Enum.map(&%{kind: "route", id: &1, label: &1})
  end

  defp trip_refs(payload) do
    MapSet.new(payload["entities"]["trips"], & &1["trip_ref"])
  end

  defp block_refs(payload) do
    MapSet.new(payload["entities"]["blocks"], & &1["block_ref"])
  end
end

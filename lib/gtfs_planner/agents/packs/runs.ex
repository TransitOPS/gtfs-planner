defmodule GtfsPlanner.Agents.Packs.Runs do
  @moduledoc """
  The Runs helper pack: bounded reads of one frozen runs day and one prepared
  run-suggestion scope.

  Every tool reads the immutable source snapshot the host admitted for this
  conversation - the copy `GtfsPlanner.Gtfs.OperationsAssistance.run_day/1`
  built and `context/2` admitted under the kind `operations_runs` - and never
  reloads the day. A read therefore answers about the day as it was when the
  page published that copy, labelled with the copy's own `source_digest`; the
  native handoff, not this pack, is what re-checks the current loaded inputs.

  Nothing here starts the cutter or writes a row. `suggest_runs/4`,
  `apply_run_plan/2`, `apply_moves/3` and every crew-settings write are not
  called anywhere in this pack's call graph, and no write, actor or command
  value reaches a tool result: `prepare_run_suggestion/3` returns
  `{:prepared, prepared, result, evidence}` whose command is the configuration
  tuple the owning LiveView interprets -
  `{:operations_suggestion, %{section:, day_key:, source_digest:,
  selection_digest:, mode:}}` - carrying no run list and no plan. Runs are cut in
  one of exactly two modes, so there is no target list to bind at all: the
  frozen scope the page holds is the whole work of the chosen mode.

  Paid and spread figures are `Runs.WorkTime`'s own, copied. This pack never
  recomputes a clock, never totals two categories into one number, and never
  calls a day, a run or a crew compliant, legal or optimal. Personnel is never
  present to leak: the copy carries no employee names, numbers, seniority or
  assignments, and no tool here returns a roster.

  `authorize_context/1` is the fence the shared owner asks of this pack: the
  version identity, the current day catalog and every technical trip identity the
  copy names are resolved with scoped queries, and a malformed, foreign or
  deleted scope returns the single `{:error, :unavailable}` result before any
  provider request, tool read, delivered result or prepared lookup. Membership
  remains `Scope`'s authority and is checked separately by `Dispatch`.

  Arguments carry no authority: the day is the attached `day_ref`, an issue page
  is a cursor over the frozen collection, and a run narrowing may only name run
  refs this snapshot holds. Enum, distinctness and digest equality are enforced
  in this module's code rather than by a schema keyword the dispatch fence does
  not implement.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Queries, as: BlockingQueries
  alias GtfsPlanner.Gtfs.OperationsAssistance

  @section "runs"
  @snapshot_kind "operations_runs"
  @collection "issues"
  @source_ref "gtfs_runs"

  # The only two scopes `GtfsPlanner.Gtfs.Runs.Cutter` understands. The enum is
  # checked here rather than in a schema keyword `Dispatch` does not implement,
  # and there is no selected or partial mode to offer.
  @scopes ["uncovered_only", "replace_all"]

  # A run narrowing is all-or-refuse above this many refs, which is also what the
  # frozen pager accepts.
  @max_run_refs 100

  # The issues a proposal read reports are capped rather than left to the shared
  # result ceiling, and the count beside the rows discloses the cap.
  @max_proposal_warnings 50

  # Resources are typed references the panel may resolve. A runs snapshot's route
  # ids are the only allowlisted kind, but no tool here names a trip or block, so
  # the evidence resolves no route either: the routes are already reachable from
  # the day's own rows, and a typed reference the model could not have earned is
  # not one this pack should mint.
  @max_exclusions 20

  @skill_path Path.expand("../../../../priv/agents/packs/runs/SKILL.md", __DIR__)
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
  def id, do: "runs"

  @impl true
  def title, do: "Runs helper"

  @impl true
  def intro do
    "I can explain this day's run and crew problems and stored crew rules, compare a proposal this page already holds, and prepare which work a run suggestion would cut. I can't cut runs or save anything."
  end

  @impl true
  def examples,
    do: ["What's wrong with this day's runs?", "Get me ready to cut the uncovered work"]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "get_run_issues",
        description:
          "List this day's run and crew issues from the frozen copy attached to this " <>
            "conversation, optionally narrowed to named run_refs, an issue code and a " <>
            "severity. At most 50 issues are returned per page; keep reading with " <>
            "next_cursor until it is absent before describing the whole day, and say which " <>
            "frozen totals you read. Uncovered work and orphan assignment rows are counted " <>
            "separately and are not part of this issue list.",
        activity: "Checked this day's run issues",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "day_ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
            "run_refs" => %{
              "type" => "array",
              "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
              "minItems" => 1,
              "maxItems" => @max_run_refs
            },
            "filters" => filters_schema(),
            "cursor" => cursor_schema()
          },
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_crew_rules",
        description:
          "Report this day's stored crew rules - the report, sign-off, paid break and " <>
            "spread minutes, the piece limit and whether any relief point is ready - beside " <>
            "the day's own figures as they were computed: runs, paid and vehicle seconds, the " <>
            "uncovered work count, orphan assignment rows, negative breaks and unmeasured " <>
            "travel legs. It reports those stored rules and those numbers. It never recomputes " <>
            "them, never calls a run or a crew compliant, and never returns operator or roster " <>
            "information.",
        activity: "Checked this day's stored crew rules",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "day_ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 255}
          },
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_run_suggestion",
        description:
          "Prepare which work a run suggestion would cut on this day, for the editor to " <>
            "review in *Suggest runs*. It starts nothing, computes no plan and saves nothing. " <>
            "Use \"uncovered_only\" for the trips no run covers - the only scope that leaves " <>
            "existing runs alone, and never upgrade it to a full rebuild. Use \"replace_all\" " <>
            "only when the editor explicitly asked for a full recut, and warn them it replaces " <>
            "the existing runs. There is no partial or selected scope: the native drawer cuts " <>
            "the uncovered work or the whole day.",
        activity: "Prepared a run suggestion scope",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "day_ref" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
            "scope" => %{"type" => "string", "minLength" => 1, "maxLength" => 32}
          },
          "required" => ["scope"],
          "additionalProperties" => false
        }
      },
      %{
        name: "inspect_run_proposal",
        description:
          "Read the completed run proposal this page already holds, by the plan_ref a " <>
            "previous answer returned: its before and after figures, how many runs it changes " <>
            "or adds, how many assignments it moves and the problems it would add. It never " <>
            "re-runs the cutter, and a proposal the page no longer holds, one that has been " <>
            "replaced and one still running are all refused.",
        activity: "Inspected a run proposal",
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
        "filters" => %{
          "type" => "object",
          "properties" => %{
            "code" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
            "severity" => %{"type" => "string", "minLength" => 1, "maxLength" => 20},
            "run_refs" => %{
              "type" => "array",
              "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
              "maxItems" => @max_run_refs
            }
          },
          "required" => [],
          "additionalProperties" => false
        },
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
  def authorize_context(%Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         :ok <- resolve_version(scope),
         :ok <- resolve_day_catalog(scope, payload),
         :ok <- resolve_trip_identities(scope, payload) do
      :ok
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  @impl true
  def call("get_run_issues", args, %Scope{} = scope),
    do: get_run_issues(args, scope)

  def call("get_crew_rules", args, %Scope{} = scope),
    do: get_crew_rules(args, scope)

  def call("prepare_run_suggestion", args, %Scope{} = scope),
    do: prepare_run_suggestion(args, scope)

  def call("inspect_run_proposal", args, %Scope{} = scope),
    do: inspect_run_proposal(args, scope)

  # -- issue reads ---------------------------------------------------------

  defp get_run_issues(args, %Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         :ok <- check_day_ref(args["day_ref"], payload),
         {:ok, run_refs} <- read_run_refs(args["run_refs"], payload),
         {:ok, filters} <- read_filters(args["filters"]) do
      read_issue_page(args, scope, payload, build_narrowing(filters, run_refs))
    end
  end

  defp read_issue_page(args, scope, payload, narrowing) do
    with {:ok, cursor} <- read_cursor(args["cursor"], payload, narrowing) do
      case OperationsAssistance.page(payload, @collection, pager_filters(narrowing), cursor) do
        {:ok, page} ->
          {:ok, issues_result(payload, page, narrowing),
           issues_evidence(scope, payload, page, narrowing)}

        {:error, :unavailable} ->
          {:error, "That page of this day's issues is not available. Start the list again."}
      end
    end
  end

  # A run narrowing is the same three filters the pager understands: an optional
  # code and severity this call declared, and the run refs named directly rather
  # than inside the filter object.
  defp build_narrowing(filters, run_refs),
    do: %{
      "code" => Map.get(filters, "code"),
      "severity" => Map.get(filters, "severity"),
      "run_refs" => run_refs
    }

  defp read_filters(nil), do: {:ok, %{}}

  defp read_filters(filters) when is_map(filters), do: {:ok, filters}

  defp read_filters(_filters), do: {:error, "filters must be an object."}

  # Run refs are checked against this snapshot's own runs before the pager sees
  # them, so a ref from another day, another feed or another section learns
  # nothing about this one and is refused instead of silently narrowing nothing.
  defp read_run_refs(nil, _payload), do: {:ok, []}

  defp read_run_refs(run_refs, payload) when is_list(run_refs) do
    known = run_refs(payload)

    cond do
      run_refs == [] ->
        {:error, "Name at least one run, or leave run_refs out."}

      length(run_refs) > @max_run_refs ->
        {:error, "Name at most #{@max_run_refs} runs at a time."}

      MapSet.size(MapSet.new(run_refs)) != length(run_refs) ->
        {:error, "The same run was named twice."}

      not Enum.all?(run_refs, &(is_binary(&1) and String.length(&1) in 1..255)) ->
        {:error, "run_refs must be run references from this day's frozen copy."}

      true ->
        case Enum.find(run_refs, &(not MapSet.member?(known, &1))) do
          nil -> {:ok, run_refs}
          foreign -> {:error, unknown_run_message(foreign)}
        end
    end
  end

  defp read_run_refs(_run_refs, _payload),
    do: {:error, "run_refs must be a list of run references."}

  defp unknown_run_message(foreign) do
    "This day's frozen copy holds no run reference #{foreign}. Read the day's issues first and use a run_ref from that answer."
  end

  # The first page has no cursor. A later one must agree with this snapshot, this
  # collection, these filters and land inside the frozen total; there is no store
  # behind it, so a mismatched, malformed or out-of-range cursor is refused rather
  # than followed.
  defp read_cursor(nil, _payload, _narrowing), do: {:ok, nil}

  defp read_cursor(cursor, payload, narrowing) when is_map(cursor) do
    digest = payload["source_digest"]

    with true <- Map.get(cursor, "digest") == digest,
         true <-
           Map.keys(cursor) |> Enum.sort() ==
             ["collection", "digest", "filters", "offset"],
         true <- Map.get(cursor, "collection") == @collection,
         true <- Map.get(cursor, "filters") == applied_filters(narrowing),
         offset when is_integer(offset) and offset >= 0 <- Map.get(cursor, "offset") do
      # The cursor the pager is handed is its own normalized form - absent
      # filters are explicit nulls there - while the cursor this tool accepts and
      # echoes carries only the filters that were applied. The two are compared
      # against the same narrowing, so a cursor from another day, another filter
      # set or another position still cannot be followed.
      {:ok,
       %{
         "digest" => digest,
         "collection" => @collection,
         "filters" => pager_filters(narrowing),
         "offset" => offset
       }}
    else
      _mismatch ->
        {:error,
         "That cursor belongs to a different day, filter set or position. Start the list again."}
    end
  end

  defp read_cursor(_cursor, _payload, _narrowing),
    do: {:error, "cursor must be the object a previous page returned."}

  # The pager normalizes absent filters to explicit nulls, so the cursor it
  # compares against is rebuilt here rather than echoed.
  defp pager_filters(narrowing) do
    %{
      "code" => narrowing["code"],
      "severity" => narrowing["severity"],
      "run_refs" => narrowing["run_refs"]
    }
  end

  # The filter object the tool hands back: only what this call actually applied.
  # An empty run narrowing is left out rather than sent as `[]`, so the next
  # call's cursor stays inside the declared shape; the strictness is unchanged,
  # because `read_cursor/3` compares the returned filters against the same
  # narrowing this call rebuilt from its arguments.
  defp applied_filters(narrowing) do
    %{
      "code" => narrowing["code"],
      "severity" => narrowing["severity"],
      "run_refs" => applied_run_refs(narrowing["run_refs"])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  defp applied_run_refs([]), do: []
  defp applied_run_refs(run_refs), do: Enum.sort(run_refs)

  defp issues_result(payload, page, narrowing) do
    %{
      "day_ref" => payload["day_ref"],
      "day_key" => payload["day_key"],
      "scope" => payload["scope"],
      "completeness" => payload["completeness"],
      "totals" => payload["totals"],
      "filters" => applied_filters(narrowing),
      "rows" => page.rows,
      "total" => page.total,
      "next_cursor" => page.next_cursor && tool_cursor(page.next_cursor, narrowing),
      "digest" => page.digest,
      "page_limited?" => page.total > length(page.rows),
      # Uncovered work and orphan rows are the day's own work counts, not issue
      # instances, and they are reported beside the findings rather than inside
      # them.
      "uncovered" => payload["figures"]["uncovered"],
      "orphan_assignments" => payload["orphans"]["count"]
    }
  end

  defp tool_cursor(%{"digest" => digest, "offset" => offset}, narrowing) do
    %{
      "digest" => digest,
      "collection" => @collection,
      "filters" => applied_filters(narrowing),
      "offset" => offset
    }
  end

  defp issues_evidence(%Scope{} = scope, payload, page, narrowing) do
    %{
      kind: "run_issues",
      title: "Run and crew issues on #{payload["day_key"]}",
      total: page.total,
      total_label: "issue instances in the frozen day",
      completeness: completeness(payload),
      completeness_reason: completeness_reason(payload),
      facts: [
        %{label: "Day", value: payload["day_key"]},
        %{label: "Scope", value: payload["scope"]["mode"]},
        %{label: "Filtered by", value: filter_label(narrowing)},
        %{label: "Issues shown", value: "#{length(page.rows)} of #{page.total}"},
        %{label: "Uncovered work", value: uncovered_label(payload)},
        %{label: "Orphan assignment rows", value: Integer.to_string(payload["orphans"]["count"])},
        %{label: "Completeness", value: payload["completeness"]}
      ],
      source_ref: @source_ref,
      digest: page.digest,
      # There is no native revision behind a frozen read: the day is a copy the
      # page published, not a stored document with a version of its own.
      source_revision: nil,
      scope: scope_evidence(scope),
      exclusions: exclusions(payload),
      resources: []
    }
  end

  defp filter_label(narrowing) do
    case applied_filters(narrowing) |> Enum.sort() do
      [] -> "nothing"
      pairs -> Enum.map_join(pairs, ", ", fn {key, value} -> "#{key} #{value}" end)
    end
  end

  defp uncovered_label(payload) do
    uncovered = payload["figures"]["uncovered"]
    "#{uncovered["trips"]} trips, #{uncovered["secs"]} s"
  end

  # -- stored crew rules ---------------------------------------------------

  # Everything here is copied out of the frozen copy: the crew rules the day's
  # runs were cut against, the day's own figures as `Runs.Day.derive/4` derived
  # them, and the counts of the anomalies already present in the copy's runs.
  # Nothing is recomputed, and nothing about a person is returned: the copy
  # holds no roster, and this read has no second source to draw one from.
  defp get_crew_rules(args, %Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         :ok <- check_day_ref(args["day_ref"], payload) do
      runs = payload["entities"]["runs"]

      result = %{
        "day_ref" => payload["day_ref"],
        "day_key" => payload["day_key"],
        "scope" => payload["scope"],
        "completeness" => payload["completeness"],
        "crew_rules" => payload["constraints"],
        "figures" => payload["figures"],
        "orphans" => payload["orphans"],
        "run_count" => length(runs),
        "negative_breaks" => negative_breaks(runs),
        "unknown_travel" => unknown_travel(runs),
        "longest_spread" => payload["figures"]["longest_spread"],
        "digest" => payload["source_digest"]
      }

      {:ok, result, crew_evidence(scope, payload, result, runs)}
    end
  end

  # A negative break stays the negative number the domain stored it as, named by
  # the piece it follows so it can be located without recomputing it.
  defp negative_breaks(runs) do
    for run <- runs,
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

  # An unmeasured leg keeps its own status beside the zero seconds it was
  # charged, so an unknown never reads as a measured zero.
  defp unknown_travel(runs) do
    for run <- runs,
        leg <- run["unknown_travel"],
        do: %{
          "run_ref" => run["run_ref"],
          "run_id" => run["run_id"],
          "from" => leg["from"],
          "to" => leg["to"]
        }
  end

  defp crew_evidence(%Scope{} = scope, payload, result, runs) do
    %{
      kind: "crew_rules",
      title: "Stored crew rules on #{payload["day_key"]}",
      total: length(runs),
      total_label: "runs the frozen copy measures against these rules",
      completeness: completeness(payload),
      completeness_reason: completeness_reason(payload),
      facts: [
        %{label: "Day", value: payload["day_key"]},
        %{label: "Runs in the copy", value: Integer.to_string(length(runs))},
        %{
          label: "Paid and vehicle seconds",
          value: "#{result["figures"]["paid_secs"]} · #{result["figures"]["vehicle_secs"]}"
        },
        %{
          label: "Uncovered work",
          value: uncovered_label(payload)
        },
        %{label: "Negative breaks", value: Integer.to_string(length(result["negative_breaks"]))},
        %{
          label: "Unmeasured travel legs",
          value: Integer.to_string(length(result["unknown_travel"]))
        },
        %{
          label: "Relief point ready",
          value: if(payload["constraints"]["relief_ready"], do: "Yes", else: "No")
        }
      ],
      source_ref: @source_ref,
      digest: payload["source_digest"],
      source_revision: nil,
      scope: scope_evidence(scope),
      exclusions: exclusions(payload),
      resources: []
    }
  end

  # -- prepared configuration ----------------------------------------------

  # The command is configuration, not a plan: a section, the day, the two
  # digests the host re-checks before opening its drawer, and the mode. There is
  # no run list, no plan and no actor, and nothing in this path reaches
  # `suggest_runs/4`, `apply_run_plan/2` or `apply_moves/3`.
  defp prepare_run_suggestion(args, %Scope{} = scope) do
    with {:ok, payload} <- attached_payload(scope),
         :ok <- check_day_ref(args["day_ref"], payload),
         {:ok, mode} <- read_scope(args["scope"]) do
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

  defp read_scope(mode) when mode in @scopes, do: {:ok, mode}

  defp read_scope(_scope) do
    {:error, "scope must be one of: " <> Enum.join(@scopes, ", ") <> "."}
  end

  # The runs page has no narrower selection to freeze, so this digest binds the
  # copy's own (empty) selection exactly as the blocks pack binds the blocks the
  # editor had selected. It is the shared owner's own function, which the host
  # also calls on the copy it re-projects, so the two cannot compute the same
  # binding two different ways.
  defp selection_digest(payload), do: OperationsAssistance.selection_digest(payload)

  defp configuration_result(payload, mode, command) do
    {_tag, prepared} = command

    %{
      "day_ref" => payload["day_ref"],
      "day_key" => prepared.day_key,
      "mode" => mode,
      "scope" => payload["scope"],
      "completeness" => payload["completeness"],
      "runs_in_scope" => length(payload["entities"]["runs"]),
      "uncovered" => payload["figures"]["uncovered"],
      "orphan_assignments" => payload["orphans"]["count"],
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
      detail: "#{length(payload["entities"]["runs"])} runs on the day's frozen copy",
      lines: summary_lines(payload, mode)
    }
  end

  defp summary_lines(payload, "replace_all") do
    [
      "Recuts every run on #{payload["day_key"]} · #{length(payload["entities"]["runs"])} runs",
      "Existing runs on this day are replaced",
      "Nothing is cut or saved yet"
    ]
  end

  # An empty or small uncovered list is exactly the case where a rebuild would be
  # the wider scope nobody asked for, so the summary names the uncovered work
  # plainly and never offers the wider one.
  defp summary_lines(payload, "uncovered_only") do
    uncovered = payload["figures"]["uncovered"]

    [
      "Works only on the #{uncovered["trips"]} trips no run covers on #{payload["day_key"]}",
      "Keeps every run already on this day",
      "Nothing is cut or saved yet"
    ]
  end

  defp mode_label("uncovered_only"), do: "Uncovered work only"
  defp mode_label("replace_all"), do: "Recut the whole day"

  defp configuration_evidence(%Scope{} = scope, payload, mode, result) do
    %{
      kind: "run_suggestion_configuration",
      title: "#{mode_label(mode)} on #{payload["day_key"]}",
      total: length(payload["entities"]["runs"]),
      total_label: "runs already on the day's frozen copy",
      completeness: completeness(payload),
      completeness_reason: completeness_reason(payload),
      facts: [
        %{label: "Day", value: payload["day_key"]},
        %{label: "Scope", value: mode},
        %{label: "Runs already on the day", value: Integer.to_string(result["runs_in_scope"])},
        %{
          label: "Uncovered trips in the day",
          value: Integer.to_string(result["uncovered"]["trips"])
        },
        %{label: "Started", value: "No · the editor starts it in Suggest runs"}
      ],
      source_ref: @source_ref,
      digest: payload["source_digest"],
      source_revision: nil,
      scope: scope_evidence(scope),
      exclusions: exclusions(payload),
      resources: []
    }
  end

  # -- completed proposal --------------------------------------------------

  # The inspection reads the plan copy the attached snapshot carries. There is no
  # recomputation and no host callback: a snapshot with no plan, one whose
  # `plan_ref` names a different plan and one whose plan was replaced are all the
  # same refusal, because a proposal this page no longer holds cannot be
  # described honestly.
  defp inspect_run_proposal(args, %Scope{} = scope) do
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
        {:error, "This page holds no completed run proposal to read."}
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
    warnings = Enum.take(plan["warnings"], @max_proposal_warnings)

    %{
      kind: "run_proposal",
      title: "Run proposal for #{payload["day_key"]}",
      total: plan["move_count"],
      total_label: "assignments the proposal moves",
      completeness: completeness(payload),
      completeness_reason: completeness_reason(payload),
      facts: [
        %{label: "Day", value: payload["day_key"]},
        %{label: "Scope", value: plan["mode"]},
        %{label: "Runs before", value: Integer.to_string(before_figures["runs"])},
        %{label: "Runs after", value: Integer.to_string(after_figures["runs"])},
        %{
          label: "Problems before and after",
          value: "#{problems(before_figures)} → #{problems(after_figures)}"
        },
        %{
          label: "Runs changed or added",
          value: "#{plan["changed_run_count"]} · #{plan["new_run_count"]}"
        },
        %{
          label: "Problems it would add",
          value:
            "#{length(warnings)} shown of #{length(plan["warnings"])} (cap #{@max_proposal_warnings})"
        },
        %{label: "Applied", value: "No · a proposal until the editor applies it in the drawer"}
      ],
      source_ref: @source_ref,
      digest: result["digest"],
      source_revision: nil,
      scope: scope_evidence(scope),
      # A runs proposal has no leftovers: the work no run covers is already
      # carried as the day's own labelled uncovered count, so it is disclosed
      # here rather than counted twice.
      exclusions: uncovered_exclusions(payload),
      resources: []
    }
  end

  defp problems(figures) do
    figures["problems"]
    |> Map.values()
    |> Enum.sum()
  end

  # -- the attached copy ---------------------------------------------------

  defp attached_payload(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{kind: @snapshot_kind, payload: payload} when is_map(payload) ->
        if well_formed?(payload) do
          {:ok, payload}
        else
          {:error, unavailable_message()}
        end

      _none ->
        {:error, unavailable_message()}
    end
  end

  @binary_keys ["day_key", "day_ref", "source_digest"]
  @map_keys ["scope", "selection", "constraints", "figures", "entities"]

  defp well_formed?(payload) do
    Map.get(payload, "section") == @section and
      Enum.all?(@binary_keys, &is_binary(Map.get(payload, &1))) and
      is_list(Map.get(payload, "issues")) and
      Enum.all?(@map_keys, &is_map(Map.get(payload, &1)))
  end

  defp unavailable_message,
    do:
      "This conversation has no runs day attached. Ask the editor to reload the Runs page, then start again."

  # The day is the one the page attached, so a `day_ref` from another day, another
  # section or a model's guess is refused before any read.
  #
  # An absent `day_ref` resolves to the attached day's own ref. The ref is an
  # opaque server-generated digest over the section and day key, so a model could
  # not derive it from anything it can see and could not retype it reliably even
  # if it were disclosed; requiring it made every read unreachable in production
  # while the ExUnit cases, which read the ref out of the snapshot and script it
  # in, passed regardless. Omitting it therefore names the same day, and a ref
  # that IS supplied is still checked exactly as before, so the model gains no
  # path to a day this conversation did not attach.
  defp check_day_ref(nil, _payload), do: :ok

  defp check_day_ref(day_ref, payload) when is_binary(day_ref) do
    if day_ref == payload["day_ref"] do
      :ok
    else
      {:error, "That day is not the day attached to this conversation."}
    end
  end

  defp check_day_ref(_day_ref, _payload),
    do: {:error, "day_ref must be the day reference this page attached."}

  # -- authorization helpers -----------------------------------------------

  defp resolve_version(%Scope{} = scope) do
    case Scope.identity(scope) do
      {:version, id} -> if id == scope.gtfs_version_id, do: :ok, else: {:error, :unavailable}
      _other -> {:error, :unavailable}
    end
  end

  # The frozen copy names a day type; the current catalog decides whether that
  # day type still exists in this organization and version. A copy whose day has
  # gone, and a version this organization no longer publishes, refuse alike.
  defp resolve_day_catalog(%Scope{} = scope, payload) do
    key = payload["day_key"]

    if Enum.any?(current_day_types(scope), &(&1.key == key)),
      do: :ok,
      else: {:error, :unavailable}
  end

  # `list_day_types/2` rolls back and re-raises `{:error, :not_found}` for a
  # version this organization does not publish. A read that raises is not an
  # answer about another organization either, so it is caught here and answered
  # with the single refusal rather than failing the whole turn.
  defp current_day_types(%Scope{} = scope) do
    Blocking.list_day_types(scope.organization_id, scope.gtfs_version_id)
  rescue
    _unavailable -> []
  catch
    :exit, _reason -> []
  end

  # Every technical trip identity the copy names must still resolve in the
  # scoped version. A trip moved to another organization or version, or deleted
  # after the copy was published, means this snapshot no longer describes this
  # scope, and the refusal is the same one a foreign snapshot produces.
  defp resolve_trip_identities(%Scope{} = scope, payload) do
    ids = trip_ids(payload)

    resolved =
      BlockingQueries.trip_identities(
        scope.organization_id,
        scope.gtfs_version_id,
        {:trip_ids, MapSet.to_list(ids)}
      )

    if resolved |> Enum.map(& &1.trip_id) |> MapSet.new() |> MapSet.equal?(ids) do
      :ok
    else
      {:error, :unavailable}
    end
  end

  defp trip_ids(payload) do
    payload["entities"]["trips"]
    |> Enum.map(& &1["trip_id"])
    |> MapSet.new()
  end

  # -- shared evidence parts -----------------------------------------------

  defp completeness(%{"completeness" => "complete"}), do: :complete
  defp completeness(_payload), do: :incomplete

  defp completeness_reason(%{"completeness" => "complete"}), do: nil

  defp completeness_reason(%{"completeness" => "scoped"}),
    do: "This day was read for a narrower scope than the whole day."

  defp completeness_reason(_payload),
    do: "This day's copy is not a whole-day read."

  # The evidence scope records the scope the read ran under, so the panel can
  # drop a card that answers for a day this panel no longer holds. It is the
  # authorized scope's own values, never an argument's.
  defp scope_evidence(%Scope{} = scope) do
    %{
      organization_id: scope.organization_id,
      gtfs_version_id: scope.gtfs_version_id,
      identity: identity_label(scope)
    }
  end

  defp identity_label(%Scope{} = scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  # Exclusions are the copy's own disclosure - unplottable and frequency-based
  # trips, and rows an explicit subset left out - bounded so the card cannot push
  # the answer past the result ceiling the page was served under.
  defp exclusions(payload) do
    payload["exclusions"]
    |> Enum.take(@max_exclusions)
    |> Enum.map(&exclusion_label/1)
    |> Enum.reject(&is_nil/1)
  end

  defp exclusion_label(%{"kind" => "frequency_trip", "trip_ref" => ref}),
    do: "frequency-based trip #{ref}"

  defp exclusion_label(%{"kind" => "unplottable", "trip_ref" => ref}),
    do: "unplottable trip #{ref}"

  defp exclusion_label(%{"kind" => "outside_scope", "block_ref" => ref}),
    do: "block #{ref} outside the selected scope"

  defp exclusion_label(%{"kind" => "outside_scope", "trip_ref" => ref}),
    do: "trip #{ref} outside the selected scope"

  defp exclusion_label(_exclusion), do: nil

  # The uncovered work a proposal does not address is disclosed as the day's own
  # work count, beside the proposal rather than inside it.
  defp uncovered_exclusions(payload) do
    uncovered = payload["figures"]["uncovered"]

    [
      "#{uncovered["trips"]} trips no run covers in the day's frozen copy",
      "#{payload["orphans"]["count"]} assignment rows belonging to no current trip"
    ]
  end

  defp run_refs(payload) do
    MapSet.new(payload["entities"]["runs"], & &1["run_ref"])
  end
end

defmodule GtfsPlanner.Agents.Packs.DatedChanges do
  @moduledoc """
  The dated-change planning pack: a read-only, plan-only description of what an
  accepted date-bounded shift on one route's selected trips would touch.

  Every tool takes an empty object. The selection, the inclusive dates, the
  shift and the approval come from the source snapshot the host froze after its
  own native form confirmation, never from an argument and never from model
  output (AC-11, AC-12). A conversation with no accepted `dated_changes`
  snapshot is refused in `authorize_context/1` before any provider request, tool
  read or delivered result, and the route identity is re-resolved by
  `Scope.authorized_context/1` on every one of those boundaries.

  `GtfsPlanner.Gtfs.DatedChangePlan.prepare/2` is the only read this pack
  performs, and it is called with the scope's own server-held values: its
  organization, version and route identity, and the accepted source rebuilt from
  the snapshot payload. The payload is JSON-safe, so the two `Date` values are
  parsed back here and the source's own `input_digest` is re-derived by
  `prepare/2`, which refuses a payload that was never accepted.

  Each tool returns `{:ok, result, evidence}` and nothing else. There is no
  `{:prepared, ...}` return, no apply callback, no token and no command of any
  kind in the module, and the three tools are the whole surface: the pack cannot
  write a calendar, a trip, a stop time, a frequency, a block, a transfer, a run
  or an audit row (CR-1, INV-1).

  The result the model reads is a bounded summary, never the report. Each date,
  clock and dependency category carries at most 20 witnesses beside its exact
  total and an explicit label saying how many of how many were shown, so a
  sampled row can never read as the whole computation (CR-3). A summary whose
  encoded result and evidence together exceed the shared 32,768-byte tool
  envelope is refused whole with a message that keeps the native plan and the
  native editors available, rather than cutting the encoded truth (AC-12).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.DatedChangePlan
  alias GtfsPlanner.Gtfs.GtfsTime

  @source_ref "gtfs_dated_change_plan"
  @snapshot_kind "dated_changes"

  # The shared tool envelope `GtfsPlanner.Agents.Dispatch` enforces. The pack
  # measures its own pair against the same limit so the refusal names what the
  # editor can still do instead of arriving as a bare fence error.
  @max_envelope_bytes 32_768
  @max_witnesses 20

  @payload_keys ~w(
    approval_note
    delta_seconds
    first_date
    input_digest
    last_date
    schema_version
    source_label
    trip_ids
  )

  @skill_path Path.expand("../../../../priv/agents/packs/dated_changes/SKILL.md", __DIR__)
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
  def id, do: @snapshot_kind

  @impl true
  def title, do: "Dated change planner"

  @impl true
  def intro do
    "I can plan an approved date-bounded shift for the trips selected on this page and explain which dates, times and other trips it touches. I can't change anything."
  end

  @impl true
  def examples,
    do: [
      "Which dates would this shift affect?",
      "What else does this change touch?"
    ]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "inspect_dated_change_scope",
        description:
          "Report what the accepted dated change covers: the route, the inclusive date range, the shift, the selected trip count, the calendars involved and the exact affected and unchanged totals. Call this first to confirm which plan the conversation is about. Takes no arguments.",
        activity: "Checked the accepted plan",
        parameters: empty_parameters()
      },
      %{
        name: "inspect_dated_change_dependencies",
        description:
          "Report who else the accepted dated change touches: other trips on the same calendars, same-block trips and successor candidates, transfer rules listed for review, block attributes, operating settings, run assignments and stop incidence. Each category carries its exact total beside a bounded sample. Takes no arguments.",
        activity: "Read the change's dependencies",
        parameters: empty_parameters()
      },
      %{
        name: "prepare_dated_change_plan",
        description:
          "Report the accepted dated change's dates, projected clocks and execution prerequisites: the affected and unchanged dates of every calendar with their exact counts, the projected service-day clocks, and the stages that have no implementation today. The report is planning only; nothing here can be applied. Takes no arguments.",
        activity: "Prepared the dated change plan",
        parameters: empty_parameters()
      }
    ]
  end

  @impl true
  def authorize_context(%Scope{} = scope) do
    with {:route, _route_id} <- Scope.identity(scope),
         %{kind: @snapshot_kind, payload: payload} <- Scope.source_snapshot(scope),
         {:ok, _accepted} <- accepted_source(payload) do
      :ok
    else
      _other -> {:error, :unavailable}
    end
  end

  @impl true
  def call("inspect_dated_change_scope", _args, %Scope{} = scope),
    do: answer(scope, &scope_result/2)

  def call("inspect_dated_change_dependencies", _args, %Scope{} = scope),
    do: answer(scope, &dependencies_result/2)

  def call("prepare_dated_change_plan", _args, %Scope{} = scope),
    do: answer(scope, &plan_result/2)

  def call(_name, _args, %Scope{}), do: {:error, "That question cannot be answered here."}

  # The one read every tool performs. `prepare/2` re-authorizes the current
  # editor inside its own snapshot and re-derives the accepted source's digest,
  # so the two refusals below are the domain's own vocabulary and this module
  # never invents a complete answer where the read could not produce one.
  defp answer(%Scope{} = scope, build) do
    with {:ok, payload} <- dated_changes_payload(scope),
         {:ok, accepted} <- accepted_source(payload),
         {:ok, report} <- DatedChangePlan.prepare(scope, accepted) do
      {result, evidence} = build.(report, accepted)

      if envelope_bytes(result, evidence) > @max_envelope_bytes do
        {:error, error_message(:too_large)}
      else
        {:ok, result, evidence}
      end
    else
      {:error, :invalid_accepted_source} -> {:error, error_message(:invalid_source)}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  # A conversation with no accepted `dated_changes` source is refused before a
  # tool reads anything, the same refusal `authorize_context/1` gives.
  defp dated_changes_payload(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{kind: @snapshot_kind, payload: payload} when is_map(payload) -> {:ok, payload}
      _other -> {:error, :invalid_accepted_source}
    end
  end

  defp envelope_bytes(result, evidence) do
    byte_size(Jason.encode!(result)) + byte_size(Jason.encode!(evidence))
  end

  # -- the accepted source ----------------------------------------------------

  # The payload is the JSON-safe form the host froze. Only this pack's own kind
  # is read, every key is required and no foreign key is tolerated, and the two
  # dates are parsed back into the `Date` structs `prepare/2` computes over. The
  # source's `input_digest` is recomputed here rather than read from the
  # payload, so a payload whose digest does not match its own values never
  # reaches a read, and the domain recomputes it a second time.
  defp accepted_source(payload) when is_map(payload) do
    if payload |> Map.keys() |> Enum.sort() == @payload_keys do
      build_accepted(payload)
    else
      {:error, :invalid_accepted_source}
    end
  end

  defp accepted_source(_payload), do: {:error, :invalid_accepted_source}

  defp build_accepted(payload) do
    with {:ok, first_date} <- date(payload["first_date"]),
         {:ok, last_date} <- date(payload["last_date"]),
         {:ok, delta_seconds} <- integer(payload["delta_seconds"]),
         {:ok, trip_ids} <- trip_ids(payload["trip_ids"]),
         true <- is_integer(payload["schema_version"]) and payload["schema_version"] > 0,
         true <- is_binary(payload["approval_note"]),
         true <- optional_string(payload["source_label"]),
         true <- is_binary(payload["input_digest"]) do
      accepted = %{
        schema_version: payload["schema_version"],
        trip_ids: trip_ids,
        first_date: first_date,
        last_date: last_date,
        delta_seconds: delta_seconds,
        approval_note: payload["approval_note"],
        source_label: payload["source_label"]
      }

      digest = DatedChangePlan.input_digest(accepted)

      # The payload's own digest is checked against the one recomputed from its
      # values, and only then is the recomputed value carried forward, so a
      # tampered payload is refused rather than silently re-digested.
      if payload["input_digest"] == digest do
        {:ok, Map.put(accepted, :input_digest, digest)}
      else
        {:error, :invalid_accepted_source}
      end
    else
      _other -> {:error, :invalid_accepted_source}
    end
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_accepted_source}
    end
  end

  defp date(_value), do: {:error, :invalid_accepted_source}

  defp integer(value) when is_integer(value), do: {:ok, value}
  defp integer(_value), do: {:error, :invalid_accepted_source}

  defp optional_string(nil), do: true
  defp optional_string(value) when is_binary(value), do: true
  defp optional_string(_value), do: false

  # The selection is the server's own sorted UUID list. It is re-sorted here
  # rather than trusted, and an entry that is not a UUID refuses the source
  # before any route trip is read.
  defp trip_ids(value) when is_list(value) do
    if value != [] and Enum.all?(value, &(is_binary(&1) and Ecto.UUID.cast(&1) == {:ok, &1})) do
      {:ok, Enum.sort(value)}
    else
      {:error, :invalid_accepted_source}
    end
  end

  defp trip_ids(_value), do: {:error, :invalid_accepted_source}

  # -- results ----------------------------------------------------------------

  defp scope_result(report, accepted) do
    intent = intent(report, accepted)
    services = Enum.map(report.partitions, &service_row/1)

    result = %{
      "route_id" => report.scope.route_id,
      "intent" => intent,
      "services" => services,
      "totals" => totals(report.totals),
      "computation" => Atom.to_string(report.computation),
      "timing" => Atom.to_string(report.timing),
      "dependency_digest" => report.dependency_digest
    }

    facts = [
      %{label: "Accepted date range", value: date_range(intent)},
      %{label: "Shift applied", value: shift_label(intent["delta_seconds"])},
      %{label: "Selected trips", value: Integer.to_string(intent["selected_trip_count"])},
      %{
        label: "Affected trip-dates",
        value: Integer.to_string(report.totals.affected_trip_dates)
      },
      %{
        label: "Unchanged trip-dates",
        value: Integer.to_string(report.totals.unchanged_trip_dates)
      },
      %{
        label: "Other trips on those calendars",
        value: Integer.to_string(report.totals.unaffected_calendar_users)
      },
      %{label: "Exact timing", value: Atom.to_string(report.timing)}
    ]

    {result,
     evidence(
       report,
       "dated_change_scope",
       "accepted dated change",
       report.totals.selected_trips,
       "selected trips",
       facts
     )}
  end

  # The nine dependency kinds step 5 reports, in the order the model reads
  # them. Each becomes one category with its exact total beside a bounded
  # sample, so no category can read as complete from its sample alone.
  @dependency_categories [
    :affected_services,
    :trip_selectors,
    :same_block_trips,
    :transfers,
    :block_attributes,
    :blocking_settings,
    :route_operating_settings,
    :trip_runs,
    :stop_incidence
  ]

  defp dependencies_result(report, _accepted) do
    rows = report.dependency_rows
    categories = Enum.map(@dependency_categories, &dependency_category(&1, Map.fetch!(rows, &1)))

    result = %{
      "route_id" => report.scope.route_id,
      "dependency_digest" => report.dependency_digest,
      "totals" => totals(report.totals),
      "categories" => categories,
      "dependency_row_total" => Enum.sum(Enum.map(categories, & &1["total"])),
      "completeness" => Atom.to_string(report.computation)
    }

    facts = [
      %{
        label: "Dependency rows",
        value: Integer.to_string(Enum.sum(Enum.map(categories, & &1["total"])))
      },
      %{label: "Calendars touched", value: Integer.to_string(length(report.partitions))},
      %{
        label: "Other trips on those calendars",
        value: Integer.to_string(report.totals.unaffected_calendar_users)
      },
      %{
        label: "Transfer rules listed for review",
        value: Integer.to_string(length(rows.transfers))
      }
    ]

    {result,
     evidence(
       report,
       "dated_change_dependencies",
       "who else this change touches",
       Enum.sum(Enum.map(categories, & &1["total"])),
       "dependency rows",
       facts
     )}
  end

  defp plan_result(report, accepted) do
    intent = intent(report, accepted)
    projections = report.projected_clocks

    result = %{
      "route_id" => report.scope.route_id,
      "intent" => intent,
      "planning_only" => true,
      "computation" => Atom.to_string(report.computation),
      "timing" => Atom.to_string(report.timing),
      "totals" => totals(report.totals),
      "partitions" => Enum.map(report.partitions, &partition_summary/1),
      "projected_clocks" => %{
        "total" => length(projections),
        "shown" => min(length(projections), @max_witnesses),
        "truncated" => length(projections) > @max_witnesses,
        "sample_label" => sample_label(length(projections)),
        "rows" => sample(projections, @max_witnesses, &clock_row/1)
      },
      "unaffected_trips" => %{
        "total" => length(report.unaffected_users),
        "shown" => min(length(report.unaffected_users), @max_witnesses),
        "truncated" => length(report.unaffected_users) > @max_witnesses,
        "sample_label" => sample_label(length(report.unaffected_users)),
        "trip_ids" => sample(report.unaffected_users, @max_witnesses, & &1)
      },
      "execution_stages" => Enum.map(report.execution_stages, &stage_row/1),
      "unresolved" => %{
        "total" => length(report.unresolved),
        "shown" => min(length(report.unresolved), @max_witnesses),
        "truncated" => length(report.unresolved) > @max_witnesses,
        "sample_label" => sample_label(length(report.unresolved)),
        "reasons" => sample(report.unresolved, @max_witnesses, &unresolved_row/1)
      },
      "dependency_digest" => report.dependency_digest
    }

    facts = [
      %{label: "Accepted date range", value: date_range(intent)},
      %{
        label: "Affected trip-dates",
        value: Integer.to_string(report.totals.affected_trip_dates)
      },
      %{
        label: "Unchanged trip-dates",
        value: Integer.to_string(report.totals.unchanged_trip_dates)
      },
      %{label: "Projected clock rows", value: Integer.to_string(length(projections))},
      %{label: "Exact timing", value: Atom.to_string(report.timing)},
      %{
        label: "Stages with no implementation",
        value:
          Integer.to_string(
            Enum.count(report.execution_stages, &(&1.status == :foundation_missing))
          )
      }
    ]

    {result,
     evidence(
       report,
       "dated_change_plan",
       "dated change plan",
       report.totals.affected_trip_dates,
       "affected trip-dates",
       facts
     )}
  end

  defp dependency_category(kind, rows) do
    %{
      "category" => Atom.to_string(kind),
      "total" => length(rows),
      "shown" => min(length(rows), @max_witnesses),
      "truncated" => length(rows) > @max_witnesses,
      "sample_label" => sample_label(length(rows)),
      "rows" => sample(rows, @max_witnesses, &json_value/1)
    }
  end

  # The accepted source as the model reads it. The two dates and the shift are
  # the accepted values the domain computed over, and the selection is reported
  # as an exact count rather than as a list, so the intent echo cannot become a
  # second copy of the selection to reason about. The approval note is reported
  # as recorded, never as an approval this conversation granted.
  defp intent(report, accepted) do
    %{
      "first_date" => Date.to_iso8601(accepted.first_date),
      "last_date" => Date.to_iso8601(accepted.last_date),
      "delta_seconds" => accepted.delta_seconds,
      "selected_trip_count" => length(accepted.trip_ids),
      "approval_note_recorded" => is_binary(accepted.approval_note),
      "source_label" => accepted.source_label,
      "input_digest" => report.input_digest
    }
  end

  defp totals(totals) do
    %{
      "selected_trips" => totals.selected_trips,
      "affected_trip_dates" => totals.affected_trip_dates,
      "unchanged_trip_dates" => totals.unchanged_trip_dates,
      "unaffected_calendar_users" => totals.unaffected_calendar_users
    }
  end

  defp service_row(partition) do
    %{
      "service_id" => partition.service_id,
      "selected_trip_count" => length(partition.selected_trip_ids),
      "unaffected_trip_count" => length(partition.unaffected_trip_ids),
      "original_date_count" => length(partition.original_dates),
      "affected_date_count" => length(partition.temporary_dates),
      "unchanged_date_count" => length(partition.normal_dates)
    }
  end

  defp partition_summary(partition) do
    %{
      "service_id" => partition.service_id,
      "selected_trip_count" => length(partition.selected_trip_ids),
      "unaffected_trip_count" => length(partition.unaffected_trip_ids),
      "dates" => %{
        "original_total" => length(partition.original_dates),
        "original_shown" => min(length(partition.original_dates), @max_witnesses),
        "original_truncated" => length(partition.original_dates) > @max_witnesses,
        "original_label" => sample_label(length(partition.original_dates)),
        "original" => sample(partition.original_dates, @max_witnesses, &Date.to_iso8601/1),
        "affected_total" => length(partition.temporary_dates),
        "affected_shown" => min(length(partition.temporary_dates), @max_witnesses),
        "affected_truncated" => length(partition.temporary_dates) > @max_witnesses,
        "affected_label" => sample_label(length(partition.temporary_dates)),
        "affected" => sample(partition.temporary_dates, @max_witnesses, &Date.to_iso8601/1),
        "unchanged_total" => length(partition.normal_dates),
        "unchanged_label" => sample_label(length(partition.normal_dates))
      }
    }
  end

  defp clock_row(row) do
    %{
      "trip_id" => row.trip_id,
      "stop_sequence" => row.stop_sequence,
      "before_arrival" => clock(row.before_arrival),
      "before_departure" => clock(row.before_departure),
      "temporary_arrival" => clock(row.temporary_arrival),
      "temporary_departure" => clock(row.temporary_departure)
    }
  end

  defp clock(:unknown), do: "unknown"
  defp clock(seconds) when is_integer(seconds), do: GtfsTime.format(seconds)

  defp stage_row(stage) do
    %{
      "stage" => Atom.to_string(stage.kind),
      "status" => Atom.to_string(stage.status),
      "affected_id_count" => length(stage.affected_ids),
      "affected_id_sample" => sample(stage.affected_ids, @max_witnesses, & &1),
      "reasons" => stage.reasons
    }
  end

  defp unresolved_row(reason) do
    %{
      "reason" => Atom.to_string(reason.reason),
      "service_id" => reason.service_id,
      "trip_id" => reason.trip_id,
      "stop_sequence" => reason.stop_sequence,
      "clock" => reason.clock && Atom.to_string(reason.clock)
    }
  end

  # A bounded sample always carries its exact total and a label saying how much
  # was shown, so a reader cannot mistake the sample for the whole computation
  # (CR-3). The sample itself is the first `@max_witnesses` rows of the report's
  # own deterministic order.
  defp sample(values, limit, encode) do
    values |> Enum.take(limit) |> Enum.map(encode)
  end

  defp sample_label(count) when count > @max_witnesses,
    do: "Showing #{@max_witnesses} of #{count}."

  defp sample_label(count), do: "Showing all #{count}."

  # A dependency row is projected with explicit keys rather than encoded
  # straight: its stored content is what the model must read, and a struct or an
  # atom value would not survive JSON as itself.
  defp json_value(row) when is_map(row) do
    row
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, value} -> {to_string(key), json_scalar(value)} end)
  end

  defp json_scalar(%Date{} = date), do: Date.to_iso8601(date)

  # `Transfer.min_transfer_time` is a stored decimal, and its exact value is the
  # row's content rather than something this projection may round or refloat.
  defp json_scalar(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  defp json_scalar(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp json_scalar(value) when is_list(value), do: Enum.map(value, &json_scalar/1)
  defp json_scalar(%_{} = struct), do: inspect(struct)
  defp json_scalar(value) when is_map(value), do: json_value(value)
  defp json_scalar(value), do: value

  # -- evidence ---------------------------------------------------------------

  # The evidence is built from the same report the model read, so its counts
  # cannot disagree with the rows it describes: `total` is the domain's own exact
  # count, `completeness` is the report's own computation status, and `digest` is
  # the report's dependency digest. `source_revision` is `nil`, because no native
  # revision exists for a plan that reads no saved change.
  defp evidence(report, kind, title, total, total_label, facts) do
    %{
      kind: kind,
      title: title,
      total: total,
      total_label: total_label,
      completeness: report.computation,
      completeness_reason: completeness_reason(report),
      facts: facts,
      source_ref: @source_ref,
      digest: report.dependency_digest,
      source_revision: nil,
      scope: %{
        organization_id: report.scope.organization_id,
        gtfs_version_id: report.scope.gtfs_version_id,
        identity: identity_label(report)
      },
      exclusions: exclusions(report),
      resources: resources(report)
    }
  end

  # An unresolved clock does not make the date partition incomplete, so the
  # card's completeness follows the computation and the reason names the timing
  # separately. Nothing here claims complete exact timing it does not have.
  defp completeness_reason(report) do
    case {report.computation, report.timing} do
      {:complete, :complete} ->
        nil

      {:complete, :unresolved} ->
        "#{length(report.unresolved)} clocks could not be projected exactly."

      _incomplete ->
        "The dependency read was not complete, so no complete plan exists."
    end
  end

  defp exclusions(report) do
    ["Showing at most #{@max_witnesses} of each exact total; the totals above are complete."] ++
      Enum.map(report.execution_stages, &stage_exclusion/1)
  end

  defp stage_exclusion(stage),
    do: "#{stage.kind}: #{stage.status} - no writer in this application can do this yet."

  # Only resources the read actually resolved become typed references: the bound
  # route and the calendars it touched. Blocks, transfers and runs stay text
  # until a typed ownership check exists for them.
  defp resources(report) do
    route = %{kind: "route", id: report.scope.route_id, label: report.scope.route_id}

    [route] ++
      Enum.map(report.partitions, &%{kind: "calendar", id: &1.service_id, label: &1.service_id})
  end

  defp identity_label(report), do: "route:#{report.scope.route_uuid}"

  defp date_range(%{"first_date" => first, "last_date" => last}), do: "#{first} to #{last}"

  defp shift_label(seconds) when is_integer(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    "#{sign}#{abs(seconds)} seconds"
  end

  # -- refusals ---------------------------------------------------------------

  defp error_message(:forbidden),
    do: "This conversation is no longer allowed to read this service version."

  defp error_message(:not_found),
    do: "The route or a selected trip is no longer available in this service version."

  defp error_message(:invalid_source),
    do: "The accepted input on this page is no longer readable. Review the input again."

  defp error_message({:incomplete, _reason}),
    do:
      "This version has more dated service than one answer can read completely, so no complete plan is available."

  defp error_message(:too_large),
    do:
      "This plan is too large to describe in one answer. Narrow the selection or the date range; the native plan and the schedule editor are still available."

  defp error_message(_reason),
    do: "That plan could not be prepared."

  # -- tool schema ------------------------------------------------------------

  # Every tool takes an empty, closed object: the selection, the dates, the
  # shift and the approval are all server snapshot inputs, so a model-supplied
  # argument has nothing legitimate to say and an undeclared one is refused.
  defp empty_parameters do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => [],
      "additionalProperties" => false
    }
  end
end

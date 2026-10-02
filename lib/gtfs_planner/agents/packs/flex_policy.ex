defmodule GtfsPlanner.Agents.Packs.FlexPolicy do
  @moduledoc """
  The Flex policy helper pack: one bounded read of the selected service's saved
  hours and booking policy, and one prepared candidate for the editor to review
  on the native service page.

  The service is never named by a tool argument. It comes from the accepted
  `flex_policy` source snapshot the host froze after the editor accepted their
  own policy text, and `GtfsPlanner.Agents.Scope.authorized_context/1` has
  already re-authorized the membership, the organization, the version and that
  envelope. `authorize_context/1` refuses a conversation with no accepted
  `flex_policy` source at all, so a page without accepted source makes no
  provider request and reads nothing.

  `get_flex_policy_context` returns the saved service's own bounded projection —
  its policy fields, its named areas, its hours rows, its booking rules, the
  calendars those rows name, the native generated rider wording and the native
  readiness checks — beside the server evidence the panel trusts, unchanged from
  `GtfsPlanner.Gtfs.Flex.Assistant.workspace/1`. `get_flex_calendar_facts`
  answers one of those calendars, and refuses a calendar this service does not
  depend on. Neither reveals area geometry, another service or any other
  version's record.

  `prepare_flex_policy` hands the proposal to
  `GtfsPlanner.Gtfs.Flex.Assistant.prepare/2`, which validates the allowlisted
  input, casts every row through the native changesets and computes the native
  comparison. This pack builds no policy of its own: the returned command is
  exactly the six fields a later guarded native save needs
  (`{:flex_policy, %{source_digest:, context_digest:, saved_fingerprint:, patch:,
  scope:, exclusions:}}`), and the refusal messages carry the assistant's own
  reason verbatim so the editor sees why a proposal was not prepared.

  No tool here writes. Not an entity, not an audit row, not a job; only the
  service page's explicit Save persists anything, and this pack has no save or
  export tool to ask for one (AC-1–AC-4, AC-6, AC-7).
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Flex.Assistant

  @snapshot_kind "flex_policy"
  @source_ref "gtfs_flex_policy_workspace"

  # The whole allowlist the assistant validates, restated here so the schema the
  # model reads and the input it is checked against are one contract.
  @max_rows 100
  @max_unsupported 20
  @max_statement_length 500

  @weekday_fields [
    {"Mon", :monday},
    {"Tue", :tuesday},
    {"Wed", :wednesday},
    {"Thu", :thursday},
    {"Fri", :friday},
    {"Sat", :saturday},
    {"Sun", :sunday}
  ]

  @skill_path Path.expand("../../../../priv/agents/packs/flex_policy/SKILL.md", __DIR__)
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
  def id, do: "flex_policy"

  @impl true
  def title, do: "Flex policy helper"

  @impl true
  def intro do
    "I can read this service's saved hours and booking policy and prepare a supported change for you to review. I can't save it, export it or change anything else."
  end

  @impl true
  def examples,
    do: [
      "Which hours and booking rules does this service have saved?",
      "Set weekday hours to 8 am to 5 pm"
    ]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "get_flex_policy_context",
        description:
          "Read the saved hours, booking rules, area names, calendars, generated rider wording and readiness checks of the Flex service on this page. Call this first; it names every area key and calendar service_id you may use in a proposal. It saves nothing.",
        activity: "Read the flex policy",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_flex_calendar_facts",
        description:
          "Read one calendar this service's hours or booking rules depend on: the days it runs, the span it covers, its recorded date exceptions, its schedule description and which saved rows use it. Use this before relying on a business-day booking rule, which needs the real office calendar rather than a weekday guess.",
        activity: "Read a flex calendar",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "service_id" => %{"type" => "string", "maxLength" => 200}
          },
          "required" => ["service_id"],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_flex_policy",
        description:
          "Prepare a complete replacement of the service's hours rows and/or booking rules for the editor to review. Each array you send is the final state of that array, unchanged rows included; omit an array to keep it exactly as saved. " <>
            "`scope` is `all_supported` or `hours_only`; `hours_only` keeps every booking rule and reports the prose it could not represent. Anything you cannot express natively goes in `unsupported`, and under `all_supported` any entry there refuses the preparation. This saves nothing.",
        activity: "Prepared a flex policy change",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "scope" => %{
              "type" => "string",
              "maxLength" => 20,
              "description" => "all_supported or hours_only"
            },
            "hours" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @max_rows,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "area_key" => %{"type" => "string", "maxLength" => 200},
                  "service_id" => %{"type" => "string", "maxLength" => 200},
                  "start" => %{"type" => "string", "maxLength" => 5},
                  "end" => %{"type" => "string", "maxLength" => 5}
                },
                "required" => ["service_id", "start", "end"],
                "additionalProperties" => false
              }
            },
            "booking_rules" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @max_rows,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "service_id" => %{"maxLength" => 200},
                  "when" => %{"type" => "string", "maxLength" => 20},
                  "minutes" => %{"type" => "integer", "minimum" => 0},
                  "days" => %{"type" => "integer", "minimum" => 0},
                  "by" => %{"type" => "string", "maxLength" => 5},
                  "business_days" => %{"type" => "boolean"},
                  "office_service_id" => %{"maxLength" => 200},
                  "max_days" => %{"type" => "integer", "minimum" => 0}
                },
                "required" => [],
                "additionalProperties" => false
              }
            },
            "unsupported" => %{
              "type" => "array",
              "maxItems" => @max_unsupported,
              "items" => %{"type" => "string", "maxLength" => @max_statement_length}
            }
          },
          "required" => ["scope"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @impl true
  def authorize_context(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{kind: @snapshot_kind, payload: %{"service_id" => service_id}}
      when is_binary(service_id) and service_id != "" ->
        :ok

      _other ->
        {:error, :unavailable}
    end
  end

  @impl true
  def call("get_flex_policy_context", _args, %Scope{} = scope), do: policy_context(scope)

  def call("get_flex_calendar_facts", args, %Scope{} = scope), do: calendar_facts(args, scope)

  def call("prepare_flex_policy", args, %Scope{} = scope), do: prepare(args, scope)

  # --- the read ---------------------------------------------------------------

  # The projection and the evidence are the workspace's own: one code-owned read
  # produced both, so the counts on the card cannot disagree with the rows the
  # model read (INV-2). Nothing is added here, and nothing is written.
  defp policy_context(scope) do
    with {:ok, workspace, evidence} <- load(scope) do
      {:ok, workspace.view, evidence}
    end
  end

  # One calendar of the saved service, with the saved rows that name it. A
  # calendar this service does not depend on is refused by name only: the pack
  # never looks a calendar up outside the workspace it just read.
  defp calendar_facts(args, scope) do
    with {:ok, service_id} <- calendar_id(args["service_id"]),
         {:ok, workspace, _evidence} <- load(scope) do
      case Map.fetch(workspace.calendar_rows, service_id) do
        {:ok, row} -> calendar_answer(workspace, row, scope)
        :error -> {:error, calendar_refusal(service_id)}
      end
    end
  end

  defp calendar_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp calendar_id(_value), do: {:error, "A calendar service_id is required."}

  defp calendar_answer(workspace, row, %Scope{} = scope) do
    result = calendar_result(workspace, row)
    service = workspace.dependencies.service

    {:ok, result,
     %{
       kind: "flex_calendar_facts",
       title: calendar_name(row),
       total: length(result["exceptions"]),
       total_label: "recorded date exceptions",
       completeness: :complete,
       completeness_reason: nil,
       facts: [
         %{label: "Days it runs", value: days_label(row.weekly)},
         %{label: "Covers", value: span_label(row.weekly)},
         %{label: "Date exceptions", value: Integer.to_string(length(result["exceptions"]))},
         %{label: "Used by hours rows", value: used_by_hours(workspace, row.service_id)},
         %{label: "Used by booking rules", value: used_by_rules(workspace, row.service_id)},
         %{
           label: "Office calendar for business days",
           value: office_label(workspace, row.service_id)
         }
       ],
       source_ref: @source_ref,
       digest: digest(result),
       source_revision: Integer.to_string(service.lock_version),
       scope: scope_label(scope),
       exclusions: [
         "Every other calendar in this service version is outside this answer."
       ],
       resources: [%{kind: "flex_service", id: service.id, label: service.name}]
     }}
  end

  defp calendar_result(workspace, row) do
    %{
      "service_id" => row.service_id,
      "name" => calendar_name(row),
      "weekly" => jsonify(row.weekly),
      "exceptions" => jsonify(row.exceptions),
      "attributes" => jsonify(row.attributes),
      "used_by" => %{
        "hours_rows" => hours_using(workspace, row.service_id),
        "booking_rules" => rules_using(workspace, row.service_id),
        "business_day_office_calendar" => office_for?(workspace, row.service_id)
      }
    }
  end

  defp calendar_name(%{attributes: %{service_schedule_name: name}}) when is_binary(name), do: name

  defp calendar_name(%{attributes: %{service_description: description}})
       when is_binary(description),
       do: description

  defp calendar_name(%{service_id: service_id}), do: service_id

  defp calendar_refusal(service_id) do
    "Calendar " <>
      service_id <>
      " is not one this service's saved hours or booking rules depend on. " <>
      "Read the policy context and use a calendar it named."
  end

  # The hours rows that name this calendar, by the area key the native page
  # shows. A row with no area covers every area of the service.
  defp hours_using(workspace, service_id) do
    workspace.dependencies.service.hours
    |> Enum.filter(&(&1.service_id == service_id))
    |> Enum.map(&area_label(&1.area_key))
    |> Enum.uniq()
  end

  defp rules_using(workspace, service_id) do
    workspace.dependencies.service.booking_rules
    |> Enum.filter(fn rule ->
      rule.service_id == service_id or
        (rule.business_days and rule.office_service_id == service_id)
    end)
    |> Enum.map(&rule_label/1)
  end

  defp rule_label(rule) do
    when_label = if rule.when, do: Atom.to_string(rule.when), else: "unspecified"

    case rule.service_id do
      nil -> "the whole service (#{when_label})"
      service_id -> "#{service_id} (#{when_label})"
    end
  end

  defp office_for?(workspace, service_id) do
    Enum.any?(workspace.dependencies.service.booking_rules, fn rule ->
      rule.business_days and rule.office_service_id == service_id
    end)
  end

  defp area_label(nil), do: "every area"
  defp area_label(area_key), do: area_key

  defp used_by_hours(workspace, service_id) do
    case hours_using(workspace, service_id) do
      [] -> "No saved hours row"
      area_keys -> Enum.join(area_keys, ", ")
    end
  end

  defp used_by_rules(workspace, service_id) do
    case rules_using(workspace, service_id) do
      [] -> "No saved booking rule"
      rules -> Enum.join(rules, ", ")
    end
  end

  defp office_label(workspace, service_id) do
    if office_for?(workspace, service_id),
      do: "Yes · business-day rules resolve their days here",
      else: "No"
  end

  defp days_label(nil), do: "None recorded"

  defp days_label(weekly) do
    case recorded_day_labels(weekly) do
      [] -> "None recorded"
      labels -> Enum.join(labels, ", ")
    end
  end

  defp recorded_day_labels(weekly) do
    Enum.flat_map(@weekday_fields, fn {label, field} ->
      if Map.get(weekly, field) == 1, do: [label], else: []
    end)
  end

  defp span_label(nil), do: "Unknown"

  defp span_label(weekly) do
    "#{Date.to_iso8601(weekly.start_date)} to #{Date.to_iso8601(weekly.end_date)}"
  end

  # --- the preparation --------------------------------------------------------

  # The proposal goes to the assistant, which authorizes through the same
  # workspace read, validates the allowlist, casts every row through the native
  # changesets and produces the native comparison. This pack only names the
  # result and carries the assistant's own refusal reason.
  defp prepare(args, %Scope{} = scope) do
    case Assistant.prepare(scope, args) do
      {:ok, prepared} ->
        result = prepare_result(prepared)

        {:prepared, %{summary: summary(prepared), command: command(prepared)}, result,
         prepare_evidence(prepared, result, scope)}

      {:error, reason} ->
        {:error, error_message(reason)}
    end
  end

  # The one command a later guarded native save interprets. It carries the
  # accepted source digest, the conversation context digest, the saved
  # dependency fingerprint, the patch, the prepare scope and the exclusions, and
  # nothing else: no service identity, because the service is the source's.
  defp command(prepared) do
    {:flex_policy,
     %{
       source_digest: prepared.source_digest,
       context_digest: prepared.context_digest,
       saved_fingerprint: prepared.saved_fingerprint,
       patch: prepared.patch,
       scope: prepared.prepare_scope,
       exclusions: prepared.exclusions
     }}
  end

  defp prepare_result(prepared) do
    %{
      "service_id" => prepared.service_id,
      "service_key" => prepared.service_key,
      "prepare_scope" => Atom.to_string(prepared.prepare_scope),
      "replaced" => Enum.map(prepared.replaced, &Atom.to_string/1),
      "hours" => jsonify(prepared.hours),
      "booking_rules" => jsonify(prepared.booking_rules),
      "unchanged_fields" => field_names(prepared.unchanged_fields),
      "changed_fields" => field_names(prepared.changed_fields),
      "rider_text" => %{
        "saved" => jsonify(prepared.rider_text.saved),
        "candidate" => jsonify(prepared.rider_text.candidate),
        "changes" => prepared.rider_text.changes
      },
      "checks" => %{
        "introduced" => jsonify(prepared.checks.introduced),
        "status" => jsonify(prepared.checks.status)
      },
      "export" => export_view(prepared.export),
      "unsupported" => prepared.unsupported,
      "exclusions" => prepared.exclusions,
      "warnings" => prepared.warnings,
      "digests" => %{
        "source" => prepared.source_digest,
        "context" => prepared.context_digest,
        "saved_fingerprint" => prepared.saved_fingerprint
      }
    }
  end

  # The supported export columns one candidate produces, beside the plan rows
  # the service page's own export drawer would list. The plan's file counts and
  # detour zone tuples are the native exporter's own display, not policy this
  # preparation decides.
  defp export_view(export) do
    candidate = export.candidate

    %{
      "headline" => candidate.headline,
      "rows" => jsonify(candidate.rows),
      "booking_rule_fields" => jsonify(candidate.booking_rule_fields)
    }
  end

  defp field_names(fields) do
    fields
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
  end

  # The generic copy the panel renders beside the card. The counts come from the
  # same comparison the result carries, so the card cannot claim a different
  # change than the rows below it.
  defp summary(prepared) do
    service = prepared.candidate

    %{
      title: summary_title(prepared, service),
      detail:
        "#{count_label(changed_count(prepared), "row", "rows")} changed · " <>
          "#{count_label(length(prepared.changed_fields), "field", "fields")} changed · " <>
          "saved version #{prepared.saved_lock_version}",
      lines: summary_lines(prepared)
    }
  end

  defp summary_title(prepared, service) do
    case prepared.replaced do
      [:hours] -> "Prepare hours for #{service_label(service)}"
      [:booking_rules] -> "Prepare booking rules for #{service_label(service)}"
      _both -> "Prepare hours and booking rules for #{service_label(service)}"
    end
  end

  defp service_label(service), do: service.name || service.key || "this service"

  defp summary_lines(prepared) do
    replaced_lines =
      Enum.flat_map(prepared.replaced, fn field ->
        [replaced_line(field, Map.fetch!(prepared, field))]
      end)

    rider_lines =
      prepared.rider_text.changes
      |> Enum.take(3)
      |> Enum.map(&"Rider wording · #{&1}")

    exclusion_lines =
      case prepared.exclusions do
        [] ->
          []

        exclusions ->
          ["Left out of this candidate · #{count_label(length(exclusions), "note", "notes")}"]
      end

    replaced_lines ++
      ["Readiness · #{prepared.checks.status.label}"] ++
      rider_lines ++
      exclusion_lines ++
      ["Saves nothing. Review the comparison, then Save on the service page."]
  end

  defp replaced_line(:hours, comparison) do
    "Hours · #{count_label(length(comparison.saved), "row", "rows")} saved, " <>
      "#{count_label(length(comparison.changed), "changed", "changed")}, " <>
      "#{count_label(length(comparison.added), "added", "added")}, " <>
      "#{count_label(length(comparison.removed), "removed", "removed")}"
  end

  defp replaced_line(:booking_rules, comparison) do
    "Booking rules · #{count_label(length(comparison.saved), "rule", "rules")} saved, " <>
      "#{count_label(length(comparison.changed), "changed", "changed")}, " <>
      "#{count_label(length(comparison.added), "added", "added")}, " <>
      "#{count_label(length(comparison.removed), "removed", "removed")}"
  end

  defp changed_count(prepared) do
    Enum.reduce(prepared.replaced, 0, fn field, total ->
      total + length(Map.fetch!(prepared, field).changed)
    end)
  end

  defp count_label(count, one, _many) when count == 1, do: "1 #{one}"
  defp count_label(count, _one, many), do: "#{count} #{many}"

  # The evidence describes exactly the result above: the digest covers the
  # payload returned, the totals are the comparison's own counts and the typed
  # reference is the one service this preparation is about (INV-2).
  defp prepare_evidence(prepared, result, %Scope{} = scope) do
    service = prepared.candidate

    %{
      kind: "flex_policy_preparation",
      title: service_label(service),
      total: changed_count(prepared),
      total_label: "rows changed",
      completeness: :complete,
      completeness_reason: nil,
      facts: [
        %{label: "Preparation scope", value: Atom.to_string(prepared.prepare_scope)},
        %{label: "Arrays replaced", value: list_label(prepared.replaced)},
        %{label: "Hours rows saved", value: Integer.to_string(length(prepared.hours.saved))},
        %{
          label: "Booking rules saved",
          value: Integer.to_string(length(prepared.booking_rules.saved))
        },
        %{label: "Readiness", value: prepared.checks.status.label},
        %{label: "Excluded statements", value: Integer.to_string(length(prepared.exclusions))},
        %{
          label: "Accepted source",
          value: prepared.source_digest && short_digest(prepared.source_digest)
        }
      ],
      source_ref: @source_ref,
      digest: digest(result),
      source_revision: Integer.to_string(prepared.saved_lock_version),
      scope: scope_label(scope),
      exclusions: prepared.exclusions,
      resources: [%{kind: "flex_service", id: prepared.service_id, label: service.name}]
    }
  end

  defp list_label(fields) do
    case Enum.map(fields, &Atom.to_string/1) do
      [] -> "None; both arrays stay as saved"
      fields -> Enum.join(fields, " and ")
    end
  end

  # --- shared -----------------------------------------------------------------

  defp load(%Scope{} = scope) do
    case Assistant.workspace(scope) do
      {:ok, workspace, evidence} -> {:ok, workspace, evidence}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  # The assistant's own vocabulary reaches the model verbatim, so the editor
  # reads the same reason the native review would. Every sentence is bounded:
  # a refusal is a message, not a dump of the proposal.
  defp error_message(:forbidden), do: "Access to Flex services changed."
  defp error_message(:unavailable), do: "This Flex service is not available."

  defp error_message({:incomplete, {:missing_calendar, service_id}}) do
    "The calendar #{service_id} this service's saved policy depends on is not in this " <>
      "service version. Fix the hours or booking rule on the Flex page first."
  end

  defp error_message({:incomplete, :workspace_too_large}) do
    "This service's saved policy does not fit in one answer. Narrow the request, or " <>
      "shorten the policy on the Flex page."
  end

  defp error_message({:incomplete, reason}),
    do: "This service's saved policy is incomplete: #{describe(reason)}."

  defp error_message({:invalid_input, reason}),
    do: "That proposal cannot be prepared: #{describe(reason)}."

  defp error_message({:unsupported, reason}),
    do: "This policy cannot be represented here: #{describe(reason)}."

  defp error_message(_reason), do: "That request could not be prepared."

  defp describe({:unknown_key, key}), do: "#{key} is not a field this page owns"
  defp describe({:unknown_area, key}), do: "#{key} is not an area of this service"
  defp describe({:unknown_calendar, field, value}), do: "#{value} is not a calendar in #{field}"

  defp describe({:field, field, :not_a_map}),
    do: "row #{inspect(field)} is not an object"

  defp describe({:invalid_hours, index, messages}),
    do: "hours row #{index} is not valid: #{messages(messages)}"

  defp describe({:invalid_booking_rules, index, messages}),
    do: "booking rule #{index} is not valid: #{messages(messages)}"

  defp describe({field, index, :not_a_map}),
    do: "#{label(field)} row #{index} is not an object"

  defp describe({field, index, :unknown_field}),
    do: "#{label(field)} row #{index} has a field this page does not own"

  defp describe({field, :replacement}),
    do: "#{label(field)} must be a complete, non-empty list of at most #{@max_rows} rows"

  defp describe(:scope), do: "scope must be all_supported or hours_only"
  defp describe(:no_replacement), do: "send hours, booking_rules, or both"

  defp describe(:unsupported),
    do: "unsupported must be a list of at most #{@max_unsupported} short statements"

  defp describe({:unsupported_statement, _statement}),
    do: "an unsupported entry is empty or longer than #{@max_statement_length} characters"

  defp describe({:invalid_changeset, messages}),
    do: "the whole service change is not valid: #{messages(messages)}"

  defp describe(:foreign_candidate), do: "the candidate is not this service"
  defp describe(:not_a_map), do: "the request must be an object"

  defp describe({:source_statements, statements}) do
    "the source states policy this helper cannot represent: " <> list(statements)
  end

  defp describe(:booking_rules_in_hours_only),
    do: "booking_rules cannot be replaced in an hours_only preparation; the saved rules are kept"

  defp describe({:contradictory_policy, texts}) do
    "the candidate introduces a native readiness problem: " <> list(texts)
  end

  defp describe(reason), do: bounded(inspect(reason, limit: 3, printable_limit: 80))

  defp label(:hours), do: "hours"
  defp label(:booking_rules), do: "booking_rules"
  defp label(field), do: field

  defp messages(list) when is_list(list), do: bounded(Enum.join(list, "; "))
  defp messages(other), do: bounded(inspect(other, limit: 3, printable_limit: 80))

  defp list(values) when is_list(values), do: bounded(Enum.join(Enum.take(values, 3), "; "))
  defp list(other), do: bounded(inspect(other, limit: 3, printable_limit: 80))

  defp bounded(text) when byte_size(text) <= 200, do: text
  defp bounded(text), do: String.slice(text, 0, 197) <> "..."

  defp scope_label(%Scope{} = scope) do
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

  defp digest(value) do
    value
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp short_digest(digest), do: String.slice(digest, 0, 12)

  # The assistant's own comparison is built from native structs, so every key and
  # enum travels to the model as a string. Nothing here interprets a value; it
  # only makes the answer encodable.
  defp jsonify(%Date{} = date), do: Date.to_iso8601(date)

  defp jsonify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp jsonify(%_{} = value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> jsonify()
  end

  defp jsonify(value) when is_map(value),
    do: Map.new(value, fn {key, entry} -> {to_string(key), jsonify(entry)} end)

  defp jsonify(value) when is_list(value), do: Enum.map(value, &jsonify/1)

  defp jsonify(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp jsonify(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value
end

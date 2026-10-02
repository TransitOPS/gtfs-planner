defmodule GtfsPlanner.Agents.Packs.FeedQuality do
  @moduledoc "The Feed quality helper pack: bounded, read-only validation findings and export readiness for the service version the conversation is bound to."

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Packs.FeedQuality.Remedies
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Validations.Evidence

  @source_ref "gtfs_feed_quality"

  @skill_path Path.expand("../../../../priv/agents/packs/feed_quality/SKILL.md", __DIR__)
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

  @snapshot_kind "feed_quality"
  @snapshot_schema 1
  @snapshot_sections ["validation", "export"]
  @export_types ["full", "pathways", "operations"]
  @max_result_bytes 32_768

  @impl true
  def id, do: "feed_quality"

  @impl true
  def title, do: "Feed quality helper"

  @impl true
  def intro do
    "I can answer questions about the validation findings and export readiness of this service version. I can't change the feed, the findings, the runs or the exports."
  end

  @impl true
  def examples,
    do: [
      "What are the most common validation findings on this version?",
      "Were this export's bytes checked?"
    ]

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "list_validation_findings",
        description:
          "List bounded pages of one completed MobilityData validation report: without code it walks code/severity groups (default 20, max 50); with code it walks that code's retained samples (default 50, max 100). A continuation must pass the next_cursor and digest a first page returned. Exact totals are always reported; retained samples may be fewer than the total.",
        activity: "Listed validation findings",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "run_ref" => %{"type" => "string", "maxLength" => 200},
            "severity" => %{"type" => "string", "maxLength" => 32},
            "code" => %{"type" => "string", "maxLength" => 128},
            "cursor" => %{"type" => "string", "maxLength" => 1024},
            "digest" => %{"type" => "string", "maxLength" => 128},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
          },
          "required" => ["run_ref"],
          "additionalProperties" => false
        }
      },
      %{
        name: "explain_notice",
        description:
          "Report the stored findings of one notice code with pinned documentation only for the validator version it was captured from; other versions or codes disclose unavailable documentation beside the real findings.",
        activity: "Explained a notice",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "run_ref" => %{"type" => "string", "maxLength" => 200},
            "code" => %{"type" => "string", "maxLength" => 128}
          },
          "required" => ["run_ref", "code"],
          "additionalProperties" => false
        }
      },
      %{
        name: "locate_affected_records",
        description:
          "Return the current GTFS records one retained finding names, resolved inside this organization and service version; a duplicated key or a row number resolves to nothing.",
        activity: "Located affected records",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "run_ref" => %{"type" => "string", "maxLength" => 200},
            "instance_ref" => %{"type" => "string", "maxLength" => 300}
          },
          "required" => ["run_ref", "instance_ref"],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_export_readiness",
        description:
          "Report the current defaults'd profile, structured preflight totals, recent scoped checks and whether the selected artifact's exact bytes were checked. export_type is full, pathways, operations or stations (the stations alias names the pathways files) and artifact is primary or flex. relationship is checked, different_bytes, different_profile, unknown or unavailable; currentness is always unknown and publication is unsupported.",
        activity: "Read export readiness",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "export_type" => %{
              "type" => "string",
              "maxLength" => 32
            },
            "export_ref" => %{"type" => "string", "maxLength" => 200},
            "artifact" => %{"type" => "string", "maxLength" => 16}
          },
          "required" => ["export_type"],
          "additionalProperties" => false
        }
      },
      %{
        name: "get_export_validation",
        description:
          "Report the completed validation checks recorded for this export selection and whether these exact bytes were checked.",
        activity: "Read export validation history",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "export_ref" => %{"type" => "string", "maxLength" => 200},
            "artifact" => %{"type" => "string", "maxLength" => 16}
          },
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_export_options",
        description:
          "Prepare a native export selection of one type for Review options; the type is full, pathways, operations or stations (the stations alias names the pathways files). It proposes only the type, starts no export, saves no defaults, and the person still presses the native control.",
        activity: "Prepared export options",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "export_type" => %{
              "type" => "string",
              "maxLength" => 32
            }
          },
          "required" => ["export_type"],
          "additionalProperties" => false
        }
      },
      %{
        name: "list_supported_remedies",
        description:
          "List what the helper can do about a finding: an empty correction list and whether navigation is available; it cannot fix anything.",
        activity: "Listed supported remedies",
        parameters: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        }
      },
      %{
        name: "inspect_remedy_targets",
        description: "Return the current records one retained finding names, as navigation only.",
        activity: "Inspected remedy targets",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "run_ref" => %{"type" => "string", "maxLength" => 200},
            "instance_ref" => %{"type" => "string", "maxLength" => 300}
          },
          "required" => ["run_ref", "instance_ref"],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_remedy_handoff",
        description:
          "Prepare the navigation handoff for one finding, only when the person explicitly requested that exact finding on the page; without that request it returns discovery, never a handoff. No edits are ever prepared or applied.",
        activity: "Prepared remedy handoff",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "run_ref" => %{"type" => "string", "maxLength" => 200},
            "instance_ref" => %{"type" => "string", "maxLength" => 300}
          },
          "required" => ["run_ref", "instance_ref"],
          "additionalProperties" => false
        }
      }
    ]
  end

  # The membership, the snapshot envelope and the snapshot's defaults digest
  # are rechecked here, so a changed default makes every request, tool,
  # delivery and prepared lookup the one :unavailable refusal.
  @impl true
  def authorize_context(%Scope{} = scope) do
    with :ok <- Scope.authorized_context(scope),
         :ok <- feed_context(scope),
         :ok <- snapshot_defaults(scope) do
      :ok
    else
      _other -> {:error, :unavailable}
    end
  end

  # The snapshot may pin the organization's defaults digest; a default saved
  # after the snapshot means every answer below would be from a stale settings
  # truth. Without a pinned digest the snapshot behaves exactly as before.
  defp snapshot_defaults(%Scope{} = scope) do
    case snapshot_payload(scope) do
      %{"defaults_digest" => expected} when is_binary(expected) ->
        if defaults_digest(ExportDefaults.get(scope.organization_id)) == expected,
          do: :ok,
          else: {:error, :unavailable}

      _other ->
        :ok
    end
  end

  # Requires the host-admitted AI04 snapshot envelope for this pack. Kind must be
  # "feed_quality"; payload must carry schema_version 1 and section validation|export.
  # Anything absent, foreign or malformed is the single :unavailable refusal.
  defp feed_context(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{
        kind: @snapshot_kind,
        payload: %{"schema_version" => @snapshot_schema, "section" => section}
      }
      when section in @snapshot_sections ->
        :ok

      _other ->
        {:error, :unavailable}
    end
  end

  @impl true
  def call("list_validation_findings", args, %Scope{} = scope),
    do: list_validation_findings(args, scope)

  def call("explain_notice", args, %Scope{} = scope), do: explain_notice(args, scope)

  def call("locate_affected_records", args, %Scope{} = scope),
    do: locate_affected_records(args, scope)

  def call("get_export_readiness", args, %Scope{} = scope), do: get_export_readiness(args, scope)

  def call("get_export_validation", args, %Scope{} = scope),
    do: get_export_validation(args, scope)

  def call("prepare_export_options", args, %Scope{} = scope),
    do: prepare_export_options(args, scope)

  def call("list_supported_remedies", _args, %Scope{} = scope),
    do: list_supported_remedies(scope)

  def call("inspect_remedy_targets", args, %Scope{} = scope),
    do: inspect_remedy_targets(args, scope)

  def call("prepare_remedy_handoff", args, %Scope{} = scope),
    do: prepare_remedy_handoff(args, scope)

  def call(_name, _args, _scope), do: {:error, "That tool is not available."}

  # -- tools ------------------------------------------------------------------

  defp list_validation_findings(args, %Scope{} = scope) do
    with {:ok, run_ref} <- take_bound(args, "run_ref", 200, true),
         {:ok, severity} <- take_bound(args, "severity", 32, false),
         {:ok, code} <- take_bound(args, "code", 128, false),
         {:ok, cursor} <- take_bound(args, "cursor", 1024, false),
         {:ok, digest} <- take_bound(args, "digest", 128, false),
         {:ok, limit} <- take_limit(args) do
      answer(
        scope,
        fn ->
          Evidence.findings(scope, %{
            run_id: run_ref,
            code: code,
            severity: severity,
            limit: limit,
            cursor: cursor,
            digest: digest
          })
        end,
        fn report -> findings_result(report, scope) end,
        :validation
      )
    end
  end

  defp explain_notice(args, %Scope{} = scope) do
    with {:ok, run_ref} <- take_bound(args, "run_ref", 200, true),
         {:ok, code} <- take_bound(args, "code", 128, true) do
      answer(
        scope,
        fn -> Evidence.explain(scope, run_ref, code) end,
        fn explanation -> explanation_result(explanation, scope) end,
        :validation
      )
    end
  end

  defp locate_affected_records(args, %Scope{} = scope) do
    with {:ok, run_ref} <- take_bound(args, "run_ref", 200, true),
         {:ok, instance_ref} <- take_bound(args, "instance_ref", 300, true) do
      answer(
        scope,
        fn -> Evidence.locate(scope, run_ref, instance_ref) end,
        fn location -> location_result(location, scope) end,
        :validation
      )
    end
  end

  defp get_export_readiness(args, %Scope{} = scope) do
    with {:ok, export_type} <- take_export_type(args),
         {:ok, export_ref} <- take_bound(args, "export_ref", 200, false),
         {:ok, artifact} <- take_artifact(args) do
      answer(
        scope,
        fn -> Evidence.readiness(scope, export_type, export_ref, artifact) end,
        fn readiness -> readiness_result(readiness, scope) end,
        :export
      )
    end
  end

  defp get_export_validation(args, %Scope{} = scope) do
    payload = snapshot_payload(scope)

    with {:ok, export_ref} <- take_bound(args, "export_ref", 200, false),
         {:ok, export_ref} <- resolve_export_ref(args, payload, export_ref),
         {:ok, export_type} <- resolve_export_type(payload),
         {:ok, artifact} <- take_artifact(args) do
      answer(
        scope,
        fn -> Evidence.readiness(scope, export_type, export_ref, artifact) end,
        fn readiness -> validation_result(readiness, scope) end,
        :export
      )
    end
  end

  # -- prepared export selection ----------------------------------------------

  # The prepared command proposes only the type. The current authoritative
  # defaults are read here and carried as facts and as a digest the host may
  # pin, so the native form still makes every real choice and nothing is saved.
  defp prepare_export_options(args, %Scope{} = scope) do
    with {:ok, export_type} <- take_export_type(args),
         {:ok, readiness} <- readiness_for(scope, export_type) do
      defaults = ExportDefaults.get(scope.organization_id)
      prepared_export_options(readiness, defaults, scope)
    end
  end

  defp readiness_for(scope, export_type) do
    case Evidence.readiness(scope, export_type, nil, :primary) do
      {:ok, readiness} -> {:ok, readiness}
      {:error, reason} -> {:error, error_message(reason, :export)}
    end
  end

  defp prepared_export_options(readiness, defaults, %Scope{} = scope) do
    result = export_options_result(readiness, defaults)
    evidence = export_options_evidence(readiness, defaults, scope)

    command =
      {:feed_quality_export_options,
       %{
         export_type: readiness.export_type,
         defaults_digest: defaults_digest(defaults),
         context_digest: Scope.context_digest(scope)
       }}

    case bounded_reply(result, evidence) do
      {:ok, _result, _evidence} ->
        {:prepared, %{summary: export_options_summary(readiness, defaults), command: command},
         result, evidence}

      {:error, _message} = error ->
        error
    end
  end

  # -- remedies ---------------------------------------------------------------

  defp list_supported_remedies(%Scope{} = scope) do
    %{corrections: corrections, navigation: navigation} = Remedies.list()
    result = %{"corrections" => corrections, "navigation" => navigation}

    bounded_reply(
      result,
      remedy_evidence([], "corrections", "supported_remedies", "supported remedies", scope)
    )
  end

  defp inspect_remedy_targets(args, %Scope{} = scope) do
    with {:ok, run_ref} <- take_bound(args, "run_ref", 200, true),
         {:ok, instance_ref} <- take_bound(args, "instance_ref", 300, true) do
      case Remedies.inspect(scope, run_ref, instance_ref) do
        {:ok, navigation} ->
          bounded_reply(
            remedy_result(navigation),
            remedy_evidence(
              navigation.targets,
              "current records",
              "remedy_targets",
              "remedy targets",
              scope
            )
          )

        {:error, reason} ->
          {:error, error_message(reason, :validation)}
      end
    end
  end

  # The approval is the server snapshot field the native Inspect target action
  # copies; a model argument or paraphrase can never establish it. Without it
  # the person gets discovery, never a handoff, and no edit command exists here.
  defp prepare_remedy_handoff(args, %Scope{} = scope) do
    with {:ok, run_ref} <- take_bound(args, "run_ref", 200, true),
         {:ok, instance_ref} <- take_bound(args, "instance_ref", 300, true) do
      requested? = snapshot_payload(scope)["requested_instance_ref"] == instance_ref

      case remedy_navigation(scope, run_ref, instance_ref, requested?) do
        {:ok, navigation} ->
          bounded_reply(
            remedy_handoff_result(navigation, requested?),
            remedy_evidence(
              navigation.targets,
              "current records",
              "remedy_handoff",
              "remedy handoff",
              scope
            )
          )

        {:error, reason} ->
          {:error, error_message(reason, :validation)}
      end
    end
  end

  defp remedy_navigation(scope, run_ref, instance_ref, true),
    do: remedy_result_of(Remedies.prepare(scope, run_ref, instance_ref, true))

  defp remedy_navigation(scope, run_ref, instance_ref, false),
    do: remedy_result_of(Remedies.inspect(scope, run_ref, instance_ref))

  defp remedy_result_of({:ok, navigation}), do: {:ok, navigation}
  defp remedy_result_of({:error, reason}), do: {:error, reason}

  defp remedy_handoff_result(navigation, true) do
    nav = remedy_result(navigation)
    Map.merge(nav, %{"requested" => true, "handoff" => nav})
  end

  defp remedy_handoff_result(navigation, false) do
    nav = remedy_result(navigation)
    Map.merge(nav, %{"requested" => false, "handoff" => nil, "navigation" => nav})
  end

  # Every read goes through the already-authorized scope, so the pack only
  # builds the exact argument map the Evidence read it names declares. A refusal
  # is one bounded message; the evidence builder only ever sees an `{:ok, read}`.
  # Each builder returns its result beside its evidence, which this promotes to
  # the `{:ok, result, evidence}` form the `Pack` contract declares, refusing
  # only what would no longer fit in one tool answer.
  defp answer(%Scope{} = _scope, query, build, error_class) do
    case query.() do
      {:ok, read} ->
        {result, evidence} = build.(read)
        bounded_reply(result, evidence)

      {:error, reason} ->
        {:error, error_message(reason, error_class)}
    end
  end

  # -- results ----------------------------------------------------------------

  defp findings_result(report, %Scope{} = scope) do
    result = %{
      "digest" => report.digest,
      "groups" => report.groups,
      "totals_by_severity" => report.totals_by_severity,
      "total_instances" => report.total_instances,
      "retained_instances" => report.retained_instances,
      "completeness" => report.completeness,
      "exclusions" =>
        Enum.map(report.exclusions, fn exclusion ->
          %{"reason" => exclusion.reason, "count" => exclusion.count}
        end),
      "next_cursor" => report.next_cursor
    }

    facts = [
      %{label: "Total findings", value: Integer.to_string(report.total_instances)},
      %{label: "Retained samples", value: Integer.to_string(report.retained_instances)},
      %{label: "Groups on this page", value: Integer.to_string(length(report.groups))},
      %{
        label: "Reported severities",
        value:
          Enum.map_join(report.totals_by_severity, ", ", fn {severity, count} ->
            "#{severity}: #{count}"
          end)
      }
    ]

    {result,
     evidence(
       report,
       scope,
       "validation_findings",
       "validation findings",
       report.total_instances,
       "validation findings",
       facts
     )}
  end

  defp explanation_result(explanation, %Scope{} = scope) do
    findings = explanation.findings

    result = %{
      "digest" => explanation.digest,
      "code" => explanation.code,
      "validator_version" => explanation.validator_version,
      "documentation" => documentation_result(explanation.documentation),
      "findings" => %{
        "severities" => findings.severities,
        "total_instances" => findings.total_instances,
        "retained_instances" => findings.retained_instances,
        "completeness" => findings.completeness
      }
    }

    facts = [
      %{label: "Documentation status", value: explanation.documentation.status},
      %{label: "Validator version", value: explanation.validator_version},
      %{label: "Total findings", value: Integer.to_string(findings.total_instances)},
      %{label: "Retained samples", value: Integer.to_string(findings.retained_instances)}
    ]

    {result,
     evidence(
       Map.put(explanation, :completeness, findings.completeness),
       scope,
       "notice_explanation",
       "notice explanation",
       findings.total_instances,
       "findings",
       facts
     )}
  end

  defp documentation_result(%{
         status: status,
         reason: reason,
         summary: summary,
         source_url: source_url,
         evidence_fields: evidence_fields,
         declared_severity: declared_severity
       }) do
    %{
      "status" => status,
      "reason" => reason,
      "summary" => summary,
      "source_url" => source_url,
      "evidence_fields" => evidence_fields,
      "declared_severity" => declared_severity
    }
  end

  defp location_result(location, %Scope{} = scope) do
    result = %{
      "ref" => location.ref,
      "digest" => location.digest,
      "context" => location.context,
      "excluded_keys" => location.excluded_keys,
      "targets" =>
        Enum.map(location.targets, fn target ->
          %{"kind" => target.kind, "id" => target.id, "label" => target.label}
        end),
      "unresolved" =>
        Enum.map(location.unresolved, fn item ->
          %{"reason" => item.reason, "field" => item.field, "value" => item.value}
        end)
    }

    facts = [
      %{label: "Records resolved", value: Integer.to_string(length(location.targets))},
      %{label: "Unresolved reasons", value: Integer.to_string(length(location.unresolved))}
    ]

    {result,
     evidence(
       location,
       scope,
       "affected_records",
       "affected records",
       length(location.targets),
       "current records",
       facts
     )}
  end

  defp readiness_result(readiness, %Scope{} = scope) do
    result = %{
      "export_type" => readiness.export_type,
      "profile" => readiness.profile,
      "product_visibility" => readiness.product_visibility,
      "preflight" => readiness.preflight,
      "recent_checks" => readiness.recent_checks,
      "selected_artifact" => Atom.to_string(readiness.selected_artifact),
      "relationship" => readiness.relationship,
      "digest" => readiness.digest,
      "currentness" => readiness.currentness,
      "publication_status" => readiness.publication_status
    }

    facts = [
      %{label: "Export type", value: readiness.export_type},
      %{label: "Relationship", value: readiness.relationship},
      %{label: "Profile", value: profile_label(readiness.profile)},
      %{label: "Preflight findings", value: Integer.to_string(length(readiness.preflight))}
    ]

    {result,
     evidence(
       readiness,
       scope,
       "export_readiness",
       "export readiness",
       length(readiness.preflight),
       "preflight findings",
       facts
     )}
  end

  defp validation_result(readiness, %Scope{} = scope) do
    result = %{
      "recent_checks" => readiness.recent_checks,
      "relationship" => readiness.relationship,
      "selected_artifact" => Atom.to_string(readiness.selected_artifact),
      "currentness" => readiness.currentness,
      "publication_status" => readiness.publication_status,
      "digest" => readiness.digest
    }

    facts = [
      %{label: "Relationship", value: readiness.relationship},
      %{label: "Completed checks", value: Integer.to_string(length(readiness.recent_checks))}
    ]

    {result,
     evidence(
       readiness,
       scope,
       "export_validation",
       "export validation",
       length(readiness.recent_checks),
       "completed checks",
       facts
     )}
  end

  # -- evidence ---------------------------------------------------------------

  # The evidence is built from the same read the model received, so the card's
  # count cannot disagree with the rows it describes. `total` is the read's own
  # count, the digest is the read's own digest, and nil digests read as "".
  defp evidence(read, %Scope{} = scope, kind, title, total, total_label, facts) do
    %{
      kind: kind,
      title: title,
      total: total,
      total_label: total_label,
      completeness: read |> Map.get(:completeness, "complete") |> completeness_atom(),
      completeness_reason: completeness_reason(read),
      facts: facts,
      source_ref: @source_ref,
      digest: read.digest || "",
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: read |> Map.get(:exclusions, []) |> Enum.map(&exclusion_label/1),
      resources: []
    }
  end

  defp completeness_atom("complete"), do: :complete
  defp completeness_atom("incomplete"), do: :incomplete
  defp completeness_atom(_other), do: :incomplete

  # A partial page tells the panel exactly that: follow the cursor with the
  # digest; any other incompleteness reads as itself without invented detail.
  defp completeness_reason(%{completeness: "complete"}), do: nil

  defp completeness_reason(%{completeness: "incomplete", next_cursor: cursor})
       when is_binary(cursor),
       do: "Only part of the report; pass next_cursor with the digest to continue."

  # An explanation reads retained samples without a cursor, so its
  # incompleteness is the samples themselves; the panel still gets a reason.
  defp completeness_reason(%{completeness: "incomplete"}),
    do: "Only retained samples of this code's findings are available."

  defp completeness_reason(_read), do: nil

  defp exclusion_label(%{reason: reason, count: count}), do: "#{reason} · #{count}"
  defp exclusion_label(reason) when is_binary(reason), do: reason

  defp profile_label(nil), do: "Unknown"
  defp profile_label(profile) when is_binary(profile), do: profile

  defp profile_label(%{} = profile) do
    profile
    |> Enum.map(fn {name, value} -> "#{name}=#{value}" end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp identity_label(%Scope{} = scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  # -- refusals ---------------------------------------------------------------

  defp error_message(:unavailable, :export),
    do: "This export selection is not available in this service version."

  defp error_message(:unavailable, _class),
    do: "This validation run is not available in this service version."

  defp error_message(:stale, _class),
    do: "That page is from an older report. Start again from the first page."

  defp error_message(:too_large, _class),
    do:
      "That result is larger than one answer can read. Narrow the page with a code or a smaller limit."

  defp error_message(:invalid_arguments, _class),
    do: "That request is not valid. Check the values and try again."

  defp error_message(:not_requested, _class),
    do: "The person has not requested this finding. Open Inspect target on that finding first."

  defp error_message(_reason, _class), do: "That question could not be answered."

  # -- arguments --------------------------------------------------------------

  # Model arguments are never passed through: only the known, bounded keys are
  # read here and rebuilt into the exact map the Evidence read declares.
  defp take_bound(args, _key, _max_length, _required) when not is_map(args),
    do: {:error, invalid_request()}

  defp take_bound(args, key, max_length, required) do
    case Map.fetch(args, key) do
      {:ok, value} when is_binary(value) and byte_size(value) <= max_length -> {:ok, value}
      {:ok, _value} -> {:error, invalid_request()}
      :error when required -> {:error, invalid_request()}
      :error -> {:ok, nil}
    end
  end

  defp take_limit(args) when not is_map(args), do: {:error, invalid_request()}

  defp take_limit(args) do
    case Map.fetch(args, "limit") do
      {:ok, value} when is_integer(value) and value >= 1 and value <= 100 -> {:ok, value}
      {:ok, _value} -> {:error, invalid_request()}
      :error -> {:ok, nil}
    end
  end

  defp take_export_type(args), do: take_bound(args, "export_type", 32, true)

  defp resolve_export_ref(_args, payload, export_ref) do
    if is_binary(export_ref) do
      {:ok, export_ref}
    else
      payload_export_ref = Map.get(payload, "selected_export_ref")

      case payload_export_ref do
        ref when is_binary(ref) -> {:ok, ref}
        _other -> {:ok, nil}
      end
    end
  end

  # The snapshot's type decides which export readiness to read; it is one of the
  # kinds this snapshot admits, defaulting to the full export.
  defp resolve_export_type(payload) do
    case Map.get(payload, "type") do
      "stations" -> {:ok, "pathways"}
      type when is_binary(type) and type in @export_types -> {:ok, type}
      nil -> {:ok, "full"}
      _other -> {:error, invalid_request()}
    end
  end

  defp take_artifact(%{"artifact" => "primary"}), do: {:ok, :primary}
  defp take_artifact(%{"artifact" => "flex"}), do: {:ok, :flex}
  defp take_artifact(%{"artifact" => _other}), do: {:error, invalid_request()}
  defp take_artifact(_args), do: {:ok, :primary}

  defp bounded_reply(result, evidence) do
    if byte_size(Jason.encode!(%{"result" => result, "evidence" => evidence})) >
         @max_result_bytes do
      {:error, "That answer is larger than one tool result can carry. Narrow the request."}
    else
      {:ok, result, evidence}
    end
  end

  defp remedy_result(navigation) do
    %{
      "targets" =>
        Enum.map(navigation.targets, fn target ->
          %{"kind" => target.kind, "id" => target.id, "label" => target.label}
        end),
      "unresolved" =>
        Enum.map(navigation.unresolved, fn item ->
          %{"reason" => item.reason, "field" => item.field, "value" => item.value}
        end),
      "navigable" => navigation.navigable
    }
  end

  defp remedy_evidence(targets, total_label, kind, title, %Scope{} = scope) do
    %{
      kind: kind,
      title: title,
      total: length(targets),
      total_label: total_label,
      completeness: :complete,
      completeness_reason: nil,
      facts: [%{label: "Navigation targets", value: Integer.to_string(length(targets))}],
      source_ref: @source_ref,
      digest: digest({:remedy, kind, Enum.map(targets, &{&1.kind, &1.id})}),
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [],
      resources: Enum.map(targets, &%{kind: &1.kind, id: &1.id, label: &1.label})
    }
  end

  defp export_options_result(readiness, defaults) do
    %{
      "export_type" => Atom.to_string(readiness.export_type),
      "profile" => readiness.profile,
      "product_visibility" => readiness.product_visibility,
      "defaults" => %{
        "include_flex" => defaults.include_flex,
        "estimate_missing_times" => defaults.estimate_missing_times,
        "estimate_method" => defaults.estimate_method && Atom.to_string(defaults.estimate_method)
      },
      "digest" => readiness.digest,
      "command_proposed" => true
    }
  end

  defp export_options_evidence(readiness, defaults, %Scope{} = scope) do
    %{
      kind: "export_options",
      title: "export options",
      total: length(readiness.preflight),
      total_label: "preflight findings",
      completeness: :complete,
      completeness_reason: nil,
      facts: [
        %{label: "Export type", value: export_type_label(readiness.export_type)},
        %{label: "Flex companion", value: flex_label(defaults)},
        %{label: "Missing times", value: estimate_label(defaults)}
      ],
      source_ref: @source_ref,
      digest:
        digest(
          {:export_options, readiness.export_type, defaults_digest(defaults),
           readiness.relationship}
        ),
      source_revision: nil,
      scope: %{
        organization_id: scope.organization_id,
        gtfs_version_id: scope.gtfs_version_id,
        identity: identity_label(scope)
      },
      exclusions: [],
      resources: []
    }
  end

  defp export_options_summary(readiness, defaults) do
    %{
      title: "Review export options",
      detail:
        "Review options selects #{export_type_label(readiness.export_type)} in the native export form. Nothing is exported and no default is saved.",
      lines: [
        "Export type: #{export_type_label(readiness.export_type)}",
        "Flex companion: #{flex_label(defaults)}",
        "Missing times: #{estimate_label(defaults)}"
      ]
    }
  end

  defp export_type_label(:full), do: "Full feed"
  defp export_type_label(:pathways), do: "Pathways / stations files"
  defp export_type_label(:operations), do: "Operations"
  defp export_type_label(other), do: to_string(other)

  defp flex_label(%{include_flex: true}), do: "included (current default)"
  defp flex_label(%{include_flex: false}), do: "excluded (current default)"
  defp flex_label(_defaults), do: "unknown"

  defp estimate_label(%{estimate_missing_times: true, estimate_method: method})
       when not is_nil(method),
       do: "estimated (#{method})"

  defp estimate_label(%{estimate_missing_times: true}), do: "estimated"
  defp estimate_label(%{estimate_missing_times: false}), do: "not estimated"
  defp estimate_label(_defaults), do: "unknown"

  defp digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def defaults_digest(defaults) do
    {:export_defaults, defaults.include_flex, defaults.realtime_source,
     defaults.estimate_missing_times, defaults.estimate_method}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp snapshot_payload(%Scope{} = scope) do
    case Scope.source_snapshot(scope) do
      %{payload: payload} when is_map(payload) -> payload
      _other -> %{}
    end
  end

  defp invalid_request,
    do: "That request is not valid. Check the values and try again."
end

defmodule GtfsPlanner.Agents.Packs.ReleaseComparison do
  @moduledoc """
  The Release comparison helper pack: read the finished comparison of two
  retained exports that the Export page already completed and admitted.

  Every tool reads the immutable copy `GtfsPlanner.Gtfs.ReleaseComparison.AssistantContext`
  froze into this conversation's resource context through
  `GtfsPlanner.Agents.Scope.with_source_snapshot/2`. Nothing here claims a
  retained artifact, opens a file, reads an export receipt, computes a
  comparison or touches the live version: a tool takes no tenant, run, path or
  date argument, and the only selectors are a route pair the admitted copy
  already names, a cursor this module issued and a page size (AC-11, CR-3).

  Four tools read the one copy: `resolve_export_comparison_scope` names what was
  compared, `get_export_comparison` states the totals, completeness and counts of
  every collection, `inspect_service_difference` pages the effective service
  changes and the identifier changes beside them, and
  `inspect_unresolved_entity_matches` pages the entities that could not be
  paired. Every number a tool states is the comparison's own, so a model sentence
  cannot restate a total or invent a link (INV-2, INV-3).

  A page names its collection, its true total and the digest of the selected
  scope, and its cursor is URL-safe base64 of exactly that digest, that
  collection and an offset. A cursor is a position, never authority: it is
  validated against the copy this conversation holds on every call, so a cursor
  from another comparison, another narrowing or another tool is refused.

  The pack's own precondition is `authorize_context/1`: the admitted copy must
  be a `release_comparison` snapshot this pack understands, unexpired, bound to
  the host version this page is on, and both compared source versions must still
  resolve inside the organization. Any other state is the single
  `{:error, :unavailable}` an absent resource produces, so no export, version or
  run metadata can reach the model.
  """

  @behaviour GtfsPlanner.Agents.Pack

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions

  @snapshot_kind "release_comparison"
  @schema_version 1
  @source_ref "gtfs_release_comparison"
  @resource_kind "export_comparison"

  @default_limit 25
  @max_limit 100
  @max_ref_length 256
  @max_cursor_length 512
  @unknown_examples 10

  @unavailable "No completed comparison is attached to this page."
  @invalid_cursor "That cursor does not belong to this comparison. Call the tool again without one."
  @unknown_ref "That result_ref is not a route pair in this comparison. Use one listed by resolve_export_comparison_scope."

  @skill_path Path.expand("../../../../priv/agents/packs/release_comparison/SKILL.md", __DIR__)
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

  # Reasons the comparison reports in `completeness` and in a suppressed total.
  # A reason this table does not know is shown as its own words rather than
  # dropped, so a new reason can never read as no reason.
  @reasons %{
    "no_service_groups" => "neither file states service for these routes and dates",
    "unmeasured_units" => "at least one route and date could not be compared on both sides",
    "unresolved_entity_matches" => "some entities could not be paired with confidence",
    "stop_meaning_changed" =>
      "a stop moved or changed type, so its trips were not compared for timing",
    "left_evaluation_incomplete" => "the earlier file has rows that could not be read",
    "right_evaluation_incomplete" => "the candidate file has rows that could not be read",
    "unmapped_route" => "a route in one file has no proven match in the other",
    "one_sided_unit" => "a route states service in one file only",
    "incomplete_counts" => "a route states frequency windows rather than exact departures",
    "unknown_timezone" => "a route's timezone is unknown",
    "timezone_mismatch" => "the two files give a route different timezones",
    "stop_ambiguous" => "a stop could not be told apart from a similar one",
    "stop_unresolved" => "a stop has no proven correspondence"
  }

  @impl true
  def id, do: "release_comparison"

  @impl true
  def title, do: "Comparison helper"

  @impl true
  def intro do
    "I can explain the comparison on this page: what changed in service, what only changed " <>
      "identifiers, and what could not be compared. I cannot change your feed or start another comparison."
  end

  @impl true
  def examples do
    [
      "Did any service end between these exports?",
      "Which changes are only renamed identifiers?"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "resolve_export_comparison_scope",
        description:
          "State what this comparison covers: the two retained exports, the shared dates, the " <>
            "route pairs and dates in scope, whether the scope is narrowed, and when the " <>
            "retained files expire. It takes no arguments.",
        activity: "Read the comparison scope",
        parameters: no_arguments()
      },
      %{
        name: "get_export_comparison",
        description:
          "Read the comparison's totals, its completeness, how many differences, identifier " <>
            "changes, unresolved matches and unknown rows it holds, and what it does not cover. " <>
            "A total the comparison could not measure is reported with its reasons, never as " <>
            "zero. It takes no arguments.",
        activity: "Read the comparison summary",
        parameters: no_arguments()
      },
      %{
        name: "inspect_service_difference",
        description:
          "Read one page of the comparison's differences: the effective service changes " <>
            "(type effective) and the identifier and presence changes (type structural), in a " <>
            "stable order. result_ref optionally limits the page to one route pair named by " <>
            "resolve_export_comparison_scope. cursor continues a previous page and limit sets " <>
            "the page size.",
        activity: "Read service differences",
        parameters: page_arguments(%{"result_ref" => result_ref_schema()})
      },
      %{
        name: "inspect_unresolved_entity_matches",
        description:
          "Read one page of the entities this comparison could not pair with confidence, with " <>
            "the reason and the file rows involved. An unresolved entity is never counted as a " <>
            "loss. cursor continues a previous page and limit sets the page size.",
        activity: "Read unresolved matches",
        parameters: page_arguments(%{})
      }
    ]
  end

  defp no_arguments do
    %{
      "type" => "object",
      "properties" => %{},
      "required" => [],
      "additionalProperties" => false
    }
  end

  defp result_ref_schema do
    %{"type" => "string", "minLength" => 1, "maxLength" => @max_ref_length}
  end

  defp page_arguments(extra) do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(extra, %{
          "cursor" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_cursor_length},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_limit}
        }),
      "required" => [],
      "additionalProperties" => false
    }
  end

  @doc """
  The pack's own precondition: an admitted, unexpired comparison on the host page.

  It runs before the provider request, every tool, a delivered result and a
  prepared lookup. It reads the admitted copy and the two source versions only:
  no file, receipt or artifact is touched.
  """
  @impl true
  def authorize_context(%Scope{} = scope) do
    with {:ok, comparison} <- admitted(scope),
         {:version, host_version_id} <- Scope.identity(scope),
         true <- host_version_id == scope.gtfs_version_id,
         :lt <- DateTime.compare(DateTime.utc_now(), comparison.expires_at),
         true <- Enum.all?(comparison.version_ids, &version_available?(scope, &1)) do
      :ok
    else
      _other -> {:error, :unavailable}
    end
  end

  @impl true
  def call("resolve_export_comparison_scope", _args, %Scope{} = scope),
    do: with_comparison(scope, &resolve_scope(&1, scope))

  def call("get_export_comparison", _args, %Scope{} = scope),
    do: with_comparison(scope, &get_comparison(&1, scope))

  def call("inspect_service_difference", args, %Scope{} = scope),
    do: with_comparison(scope, &inspect_differences(&1, args, scope))

  def call("inspect_unresolved_entity_matches", args, %Scope{} = scope),
    do: with_comparison(scope, &inspect_unresolved(&1, args, scope))

  defp with_comparison(scope, fun) do
    case admitted(scope) do
      {:ok, comparison} -> fun.(comparison)
      :error -> {:error, @unavailable}
    end
  end

  # -- resolve_export_comparison_scope ----------------------------------------

  defp resolve_scope(%{payload: payload} = comparison, scope) do
    artifacts = Enum.map(payload["artifacts"], &artifact/1)

    result = %{
      "digest" => comparison.selected_digest,
      "result_digest" => payload["result_digest"],
      "narrowed" => narrowed?(payload),
      "window" => payload["window"],
      "artifacts" => artifacts,
      "route_pairs" => payload["selected_route_pairs"],
      "dates" => payload["selected_dates"],
      "expires_at" => payload["expires_at"]
    }

    evidence =
      evidence(comparison, scope, %{
        kind: "export_comparison_scope",
        total: length(payload["selected_route_pairs"]),
        total_label: "route pairs in scope",
        completeness: completeness(payload),
        completeness_reason: completeness_reason(payload),
        facts:
          [
            fact("Compared dates", date_range(payload["window"])),
            fact("Dates in scope", length(payload["selected_dates"])),
            fact("Scope", scope_label(payload)),
            fact("Earliest expiry", payload["expires_at"])
          ] ++ estimate_facts(artifacts),
        exclusions: exclusion_strings(payload)
      })

    {:ok, result, evidence}
  end

  # A retained file is named by what the export recorded. The run and version
  # identifiers stay on the server: a model has no use for them and no tool
  # accepts one back.
  defp artifact(artifact) do
    %{
      "side" => artifact["side"],
      "label" => side_label(artifact["side"]),
      "profile" => artifact["profile"],
      "sha256" => artifact["sha256"],
      "size" => artifact["size"],
      "expires_at" => artifact["expires_at"],
      "estimate_missing_times" => artifact["estimate_missing_times"],
      "estimate_method" => artifact["estimate_method"]
    }
  end

  defp side_label("left"), do: "Earlier export"
  defp side_label("right"), do: "Candidate export"
  defp side_label(_side), do: "Export"

  # The exporter fills missing times silently, so a file made with estimates is
  # disclosed as possibly holding them. No per-row provenance exists to say more.
  defp estimate_facts(artifacts) do
    artifacts
    |> Enum.filter(&(&1["estimate_missing_times"] == true))
    |> Enum.map(&fact(&1["label"], "exported times may include estimates"))
  end

  # -- get_export_comparison ---------------------------------------------------

  defp get_comparison(%{payload: payload} = comparison, scope) do
    effective = payload["changes"]["effective"]
    structural = payload["changes"]["structural"]
    totals = payload["totals"]

    result = %{
      "digest" => comparison.selected_digest,
      "selection" => selection(payload, nil),
      "totals" => totals,
      "completeness" => payload["completeness"],
      "counts" => %{
        "route_date_units" => length(payload["groups"]),
        "effective_changes" => %{
          "total" => length(effective),
          "by_kind" => tally(effective, ["kind"])
        },
        "structural_changes" => %{
          "total" => length(structural),
          "by_change" => tally(structural, ["entity", "change"])
        },
        "unresolved" => %{
          "total" => length(payload["unresolved"]),
          "by_reason" => tally(payload["unresolved"], ["entity", "reason"])
        },
        "unknowns" => %{
          "total" => length(payload["unknowns"]),
          "by_reason" => tally(payload["unknowns"], ["side", "layer", "reason"]),
          "examples" => Enum.take(payload["unknowns"], @unknown_examples)
        }
      },
      "exclusions" => exclusions(payload)
    }

    evidence =
      evidence(comparison, scope, %{
        kind: "export_comparison",
        total: length(effective),
        total_label: "effective service differences",
        completeness: completeness(payload),
        completeness_reason: completeness_reason(payload),
        facts: [
          fact("Exact departures", delta_text(totals["exact_count_delta"], totals)),
          fact("Scheduled trips", delta_text(totals["scheduled_count_delta"], totals)),
          fact(
            "Route and date groups measured",
            "#{totals["measured_units"]} of #{totals["total_units"]}"
          ),
          fact("Identifier and presence changes", length(structural)),
          fact("Unresolved matches", length(payload["unresolved"])),
          fact("Unknown rows", length(payload["unknowns"]))
        ],
        exclusions: exclusion_strings(payload)
      })

    {:ok, result, evidence}
  end

  # A suppressed total keeps its reasons: a bare "none" would read as no change.
  defp delta_text(nil, totals), do: "not measured (#{reasons_text(totals["reasons"])})"
  defp delta_text(0, _totals), do: "no change"
  defp delta_text(delta, _totals) when delta > 0, do: "+#{delta}"
  defp delta_text(delta, _totals), do: Integer.to_string(delta)

  # -- inspect_service_difference ----------------------------------------------

  defp inspect_differences(%{payload: payload} = comparison, args, scope) do
    with {:ok, ref} <- result_ref(payload, Map.get(args, "result_ref")) do
      rows = differences(payload, ref)
      collection = if ref, do: "differences:" <> ref, else: "differences"

      page(comparison, scope, args, %{
        collection: collection,
        rows: rows,
        ref: ref,
        kind: "export_comparison_differences",
        title: "Service differences",
        total_label: "differences"
      })
    end
  end

  # The effective changes first, then the identifier and presence changes, each
  # tagged so a reader never takes a rename for a service change.
  defp differences(payload, ref) do
    effective = payload["changes"]["effective"]
    structural = payload["changes"]["structural"]

    {effective, structural} =
      case ref do
        nil ->
          {effective, structural}

        ref ->
          {Enum.filter(effective, &(pair_key(&1["route_ids"]) == ref)),
           pair_structural(payload, structural, ref)}
      end

    Enum.map(effective, &Map.put(&1, "type", "effective")) ++
      Enum.map(structural, &Map.put(&1, "type", "structural"))
  end

  # Only a route's own change is attributable to a route pair, as the native
  # narrowing decides it; a stop, trip or agency change names no route here.
  defp pair_structural(payload, structural, ref) do
    route_ids =
      payload["groups"]
      |> Enum.map(& &1["route_ids"])
      |> Enum.filter(&(pair_key(&1) == ref))
      |> Enum.flat_map(&[&1["left"], &1["right"]])
      |> Enum.reject(&is_nil/1)

    Enum.filter(structural, &(&1["entity"] == "route" and &1["id"] in route_ids))
  end

  defp pair_key(%{"left" => left, "right" => right}), do: "#{left || "?"}/#{right || "?"}"
  defp pair_key(_route_ids), do: nil

  defp result_ref(_payload, nil), do: {:ok, nil}

  defp result_ref(payload, ref) when is_binary(ref) do
    if ref in payload["selected_route_pairs"], do: {:ok, ref}, else: {:error, @unknown_ref}
  end

  defp result_ref(_payload, _ref), do: {:error, @unknown_ref}

  # -- inspect_unresolved_entity_matches ---------------------------------------

  defp inspect_unresolved(%{payload: payload} = comparison, args, scope) do
    page(comparison, scope, args, %{
      collection: "unresolved",
      rows: payload["unresolved"],
      ref: nil,
      kind: "export_comparison_unresolved",
      title: "Unresolved entity matches",
      total_label: "unresolved entity matches"
    })
  end

  # -- paging ------------------------------------------------------------------

  # A page slices the admitted list, which is already in the comparison's own
  # stable order, so a cursor can only name a position in that one list.
  defp page(%{payload: payload} = comparison, scope, args, spec) do
    total = length(spec.rows)
    limit = Map.get(args, "limit", @default_limit)

    with {:ok, offset} <- offset(Map.get(args, "cursor"), comparison, spec.collection, total) do
      records = spec.rows |> Enum.slice(offset, limit)
      next = offset + length(records)

      next_cursor =
        if next < total, do: cursor(comparison.selected_digest, spec.collection, next)

      result = %{
        "records" => records,
        "true_total" => total,
        "returned_count" => length(records),
        "next_cursor" => next_cursor,
        "digest" => comparison.selected_digest,
        "selection" => selection(payload, spec.ref),
        "completeness" => payload["completeness"],
        "exclusions" => exclusions(payload)
      }

      whole? = length(records) == total

      evidence =
        evidence(comparison, scope, %{
          kind: spec.kind,
          title: spec.title,
          total: total,
          total_label: spec.total_label,
          completeness:
            if(whole? and completeness(payload) == :complete, do: :complete, else: :incomplete),
          completeness_reason: page_reason(payload, whole?, offset, length(records), total),
          facts: [
            fact("Rows returned", length(records)),
            fact("Starting at row", offset + 1),
            fact("More rows", if(next_cursor, do: "yes", else: "no"))
          ],
          exclusions: exclusion_strings(payload)
        })

      {:ok, result, evidence}
    end
  end

  # A bounded answer is never shown as a whole one, and a page of an incomplete
  # comparison keeps the comparison's own reasons.
  defp page_reason(payload, true, _offset, _count, _total), do: completeness_reason(payload)

  defp page_reason(payload, false, offset, count, total) do
    shown = "Showing rows #{offset + 1} to #{offset + count} of #{total}."

    case completeness_reason(payload) do
      nil -> shown
      reason -> shown <> " " <> reason
    end
  end

  defp offset(nil, _comparison, _collection, _total), do: {:ok, 0}

  defp offset(cursor, comparison, collection, total) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{"selected_digest" => digest, "collection" => ^collection, "offset" => offset} = body}
         when map_size(body) == 3 and is_integer(offset) <- Jason.decode(decoded),
         true <- digest == comparison.selected_digest,
         true <- offset >= 1 and offset < total do
      {:ok, offset}
    else
      _invalid -> {:error, @invalid_cursor}
    end
  end

  defp offset(_cursor, _comparison, _collection, _total), do: {:error, @invalid_cursor}

  defp cursor(digest, collection, offset) do
    %{"selected_digest" => digest, "collection" => collection, "offset" => offset}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  # -- the admitted copy ---------------------------------------------------------

  # The copy is read only after `Scope.authorized_context/1` re-verified its
  # envelope and digest. A snapshot of another kind or schema is simply no
  # comparison here, and a payload that is not the shape this pack reads is
  # refused rather than half-read.
  defp admitted(%Scope{} = scope) do
    with %{kind: @snapshot_kind, payload: %{"schema_version" => @schema_version} = payload} <-
           Scope.source_snapshot(scope),
         {:ok, selected_digest} <- sha256(payload["selected_digest"]),
         {:ok, _result_digest} <- sha256(payload["result_digest"]),
         [_, _] = artifacts <- payload["artifacts"],
         {:ok, version_ids} <- version_ids(artifacts),
         {:ok, expires_at} <- timestamp(payload["expires_at"]),
         true <- shaped?(payload) do
      {:ok,
       %{
         payload: payload,
         selected_digest: selected_digest,
         version_ids: version_ids,
         expires_at: expires_at
       }}
    else
      _other -> :error
    end
  end

  @lists ~w(selected_route_pairs selected_dates groups unresolved unknowns exclusions)

  defp shaped?(payload) do
    Enum.all?(@lists, &is_list(payload[&1])) and is_map(payload["totals"]) and
      is_map(payload["completeness"]) and is_map(payload["window"]) and
      is_map(payload["changes"]) and is_list(payload["changes"]["effective"]) and
      is_list(payload["changes"]["structural"])
  end

  defp sha256(value) when is_binary(value) do
    if value =~ ~r/\A[0-9a-f]{64}\z/, do: {:ok, value}, else: :error
  end

  defp sha256(_value), do: :error

  defp version_ids(artifacts) do
    ids = Enum.map(artifacts, &(is_map(&1) && &1["version_id"]))
    if Enum.all?(ids, &Values.uuid?/1), do: {:ok, Enum.uniq(ids)}, else: :error
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> :error
    end
  end

  defp timestamp(_value), do: :error

  defp version_available?(%Scope{organization_id: organization_id}, version_id),
    do: not is_nil(Versions.get_gtfs_version_for_lifecycle(organization_id, version_id))

  # -- shared shapes --------------------------------------------------------------

  defp narrowed?(payload), do: is_map(payload["scope"])

  defp scope_label(payload) do
    if narrowed?(payload),
      do: "narrowed to the selected routes and dates",
      else: "the complete comparison"
  end

  defp selection(payload, ref) do
    %{
      "narrowed" => narrowed?(payload),
      "window" => payload["window"],
      "route_pair_count" => length(payload["selected_route_pairs"]),
      "date_count" => length(payload["selected_dates"]),
      "result_ref" => ref
    }
  end

  defp completeness(payload) do
    if payload["completeness"]["status"] == "complete", do: :complete, else: :incomplete
  end

  defp completeness_reason(payload) do
    case {completeness(payload), payload["completeness"]["reasons"]} do
      {:complete, _reasons} -> nil
      {:incomplete, reasons} -> "This comparison is incomplete: #{reasons_text(reasons)}."
    end
  end

  defp reasons_text([]), do: "no reason recorded"

  defp reasons_text(reasons) when is_list(reasons) do
    Enum.map_join(reasons, "; ", fn reason ->
      Map.get(@reasons, reason, String.replace(to_string(reason), "_", " "))
    end)
  end

  # The summary of what the comparison does not cover. A narrowed scope lists
  # every left-out route and date, so those are counted here rather than copied:
  # the count is bounded and the omission is still disclosed.
  defp exclusions(payload) do
    payload["exclusions"]
    |> Enum.group_by(&{&1["entity"], &1["reason"]})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {{entity, reason}, rows} ->
      %{
        "entity" => entity,
        "reason" => reason,
        "count" => length(rows),
        "detail" => if(length(rows) == 1, do: hd(rows)["detail"], else: nil)
      }
    end)
  end

  defp exclusion_strings(payload) do
    Enum.map(exclusions(payload), fn
      %{"detail" => detail} when is_binary(detail) ->
        detail

      %{"count" => count, "entity" => entity, "reason" => reason} ->
        "#{count} #{words(entity)} entries left out: #{words(reason)}"
    end)
  end

  defp tally(rows, keys) do
    rows
    |> Enum.frequencies_by(fn row -> Enum.map(keys, &row[&1]) end)
    |> Enum.sort()
    |> Enum.map(fn {values, count} ->
      keys |> Enum.zip(values) |> Map.new() |> Map.put("count", count)
    end)
  end

  defp date_range(%{"from" => from, "to" => to}), do: "#{from} to #{to}"

  defp words(token), do: token |> to_string() |> String.replace("_", " ")

  # -- evidence ---------------------------------------------------------------------

  # The card is built from the same admitted copy as the result it describes, and
  # names exactly one resource: this comparison, by the digest of what it shows.
  # The panel resolves that digest against the copy it currently holds, so a
  # reference to any other comparison renders as text.
  defp evidence(comparison, scope, attrs) do
    Map.merge(
      %{
        title: "Release comparison",
        source_ref: @source_ref,
        digest: comparison.selected_digest,
        source_revision: nil,
        scope: %{
          organization_id: scope.organization_id,
          gtfs_version_id: scope.gtfs_version_id,
          identity: identity_label(scope)
        },
        resources: [
          %{kind: @resource_kind, id: comparison.selected_digest, label: "Release comparison"}
        ]
      },
      attrs
    )
  end

  defp identity_label(scope) do
    case Scope.identity(scope) do
      {kind, id} -> "#{kind}:#{id}"
      nil -> nil
    end
  end

  defp fact(label, value), do: %{label: label, value: to_string(value)}
end

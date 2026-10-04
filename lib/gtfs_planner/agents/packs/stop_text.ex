defmodule GtfsPlanner.Agents.Packs.StopText do
  @moduledoc """
  The Stop text helper pack: read the stops an editor approved on the stops catalog,
  so a naming convention can be applied to exactly those stops.

  The only target is the approved set the catalog froze into this conversation's
  source snapshot of kind `stop_set`: one to 100 distinct stop UUIDs the editor chose,
  written by a native host action, never by a tool. No tool declares a stop,
  organization or version argument, and `authorize_context/1` re-resolves every UUID
  of the set inside the conversation's organization and version before every provider
  request, tool read, delivered result and prepared lookup; a foreign, deleted,
  duplicate, empty or oversized set is the single `{:error, :unavailable}` (AC-15,
  CR-2). Nothing in this module writes (CR-1).
  """

  @behaviour GtfsPlanner.Agents.Pack

  import Ecto.Query

  alias GtfsPlanner.Agents.Pack
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Wording

  @snapshot_kind "stop_set"
  @source_ref "gtfs_stop_set"
  @max_set 100
  @page_size 25
  @field_limit 200
  @max_offset 100_000
  @listed_resources 10
  @text_fields ~w(stop_code stop_name stop_desc stop_url)
  @named_limit 5
  @listed_rows 10
  @field_nouns [
    {"stop_name", "name", "names"},
    {"stop_code", "code", "codes"},
    {"stop_desc", "description", "descriptions"},
    {"stop_url", "URL", "URLs"}
  ]

  @skill_path Path.expand("../../../../priv/agents/packs/stop_text/SKILL.md", __DIR__)
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
  def id, do: "stop_text"

  @impl true
  def title, do: "Stop text helper"

  @impl true
  def intro do
    "I can read the stops you approved and prepare name, code, description and URL changes " <>
      "for you to review and save. I cannot save anything myself."
  end

  @impl true
  def examples do
    [
      "Show me the stops in this list",
      "Apply our naming convention to these stops"
    ]
  end

  @impl true
  def skill, do: @skill

  @impl true
  def tools do
    [
      %{
        name: "read_stop_set",
        description:
          "Read the approved stops: each one's stop_id, stop_code, stop_name, stop_desc, " <>
            "stop_url, location_type and parent_station, 25 per page sorted by stop_id, with " <>
            "the exact total. offset continues a listing from next_offset. It takes no stop " <>
            "arguments, so it can only describe the list the editor approved.",
        activity: "Read the approved stops",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "offset" => %{"type" => "integer", "minimum" => 0, "maximum" => @max_offset}
          },
          "required" => [],
          "additionalProperties" => false
        }
      },
      %{
        name: "prepare_stop_metadata_changes",
        description:
          "Prepare name, code, description and URL changes for stops in the approved list, " <>
            "for the editor to review and save. Each row names a stop_id from the approved " <>
            "list and at least one of stop_name, stop_code, stop_desc and stop_url with the " <>
            "new value. basis optionally names the convention applied. Nothing but those four " <>
            "fields can change. It saves nothing; the server validates every row first. Send " <>
            "at most 100 rows, and prepare large lists in several smaller batches.",
        activity: "Prepared stop changes",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "rows" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @max_set,
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "stop_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 100},
                  "stop_name" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
                  "stop_code" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
                  "stop_desc" => %{"type" => "string", "minLength" => 1, "maxLength" => 500},
                  "stop_url" => %{"type" => "string", "minLength" => 1, "maxLength" => 500}
                },
                "required" => ["stop_id"],
                "additionalProperties" => false
              }
            },
            "basis" => %{"type" => "string", "maxLength" => 300}
          },
          "required" => ["rows"],
          "additionalProperties" => false
        }
      }
    ]
  end

  @doc """
  The pack's own precondition: every stop of the approved set still resolves in this
  organization and version.

  Every other case, including a missing, malformed, empty or oversized set, is the
  single `{:error, :unavailable}`.
  """
  @impl true
  def authorize_context(%Scope{} = scope) do
    case bound(scope) do
      {:ok, _uuids} -> :ok
      :error -> {:error, :unavailable}
    end
  end

  @impl true
  def call("read_stop_set", args, %Scope{} = scope), do: read_stop_set(args, scope)

  def call("prepare_stop_metadata_changes", args, %Scope{} = scope),
    do: prepare_changes(args, scope)

  # -- read_stop_set ----------------------------------------------------------

  defp read_stop_set(args, scope) do
    with {:ok, uuids} <- require_bound(scope) do
      offset = Map.get(args, "offset", 0)
      stops = page(scope, uuids, offset)

      result = %{
        "total" => length(uuids),
        "offset" => offset,
        "returned" => length(stops),
        "next_offset" => if(offset + length(stops) < length(uuids), do: offset + length(stops)),
        "stops" => Enum.map(stops, &stop_row/1)
      }

      {:ok, result, set_evidence(result, stops, scope)}
    end
  end

  defp page(scope, uuids, offset) do
    Repo.all(
      from(stop in Stop,
        where:
          stop.id in ^uuids and stop.organization_id == ^scope.organization_id and
            stop.gtfs_version_id == ^scope.gtfs_version_id,
        order_by: [asc: stop.stop_id, asc: stop.id],
        offset: ^offset,
        limit: @page_size
      )
    )
  end

  # Each text field is cut at 200 characters and named in `truncated`, so a long
  # description is never mistaken for the whole value.
  defp stop_row(stop) do
    cut =
      for field <- @text_fields, long?(Map.get(stop, String.to_existing_atom(field))), do: field

    base =
      Map.new(@text_fields, fn field ->
        {field, stop |> Map.get(String.to_existing_atom(field)) |> shorten()}
      end)

    base
    |> Map.merge(%{
      "stop_id" => stop.stop_id,
      "location_type" => stop.location_type,
      "parent_station" => stop.parent_station,
      "truncated" => cut
    })
  end

  defp long?(value) when is_binary(value), do: String.length(value) > @field_limit
  defp long?(_value), do: false

  defp shorten(value) when is_binary(value), do: String.slice(value, 0, @field_limit)
  defp shorten(value), do: value

  defp set_evidence(result, stops, scope) do
    next = result["next_offset"]

    %{
      kind: "stop_set",
      title: "Approved stops",
      total: result["total"],
      total_label: "stops in the approved list",
      completeness: if(next, do: :incomplete, else: :complete),
      completeness_reason: if(next, do: "Showing #{result["returned"]} of #{result["total"]}"),
      facts: [
        %{label: "Starting at stop", value: Integer.to_string(result["offset"] + 1)},
        %{label: "On this page", value: Integer.to_string(result["returned"])}
      ],
      source_ref: @source_ref,
      digest: digest(result),
      source_revision: nil,
      scope: Pack.evidence_scope(scope),
      exclusions: [],
      resources:
        stops
        |> Enum.take(@listed_resources)
        |> Enum.map(&%{kind: "stop", id: &1.stop_id, label: &1.stop_name})
    }
  end

  defp digest(result) do
    result
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # -- prepare_stop_metadata_changes --------------------------------------------

  # The model proposes values; the server picks the stops (only the approved set's own
  # GTFS IDs), validates every row through the native batch review and prepares a
  # fixed command of changed fields only. No stop identity, count or digest reaches
  # the command (CR-1, CR-2, CR-7).
  defp prepare_changes(args, scope) do
    rows = Map.fetch!(args, "rows")

    with {:ok, uuids} <- require_bound(scope),
         {:ok, batch} <- select_rows(rows, uuids, scope),
         {:ok, review} <- native_review(batch, scope),
         :ok <- require_changes(review) do
      prepared = %{
        command: metadata_command(review),
        summary: metadata_summary(review, Map.get(args, "basis"))
      }

      {:prepared, prepared, metadata_result(review), metadata_evidence(review, scope)}
    end
  end

  # Rows are keyed by the approved set's own GTFS stop IDs, so a stop outside it, or a
  # stop named twice, is refused by name before any review.
  defp select_rows(rows, uuids, scope) do
    by_stop_id =
      Repo.all(
        from(stop in Stop,
          where:
            stop.id in ^uuids and stop.organization_id == ^scope.organization_id and
              stop.gtfs_version_id == ^scope.gtfs_version_id,
          select: {stop.stop_id, stop.id}
        )
      )
      |> Map.new()

    stop_ids = Enum.map(rows, & &1["stop_id"])

    cond do
      (outside = Enum.reject(stop_ids, &Map.has_key?(by_stop_id, &1))) != [] ->
        {:error, "These stop IDs are not in the approved list: " <> named(outside) <> "."}

      (repeated = stop_ids -- Enum.uniq(stop_ids)) != [] ->
        {:error,
         "Each stop may appear once per batch; repeated: " <> named(Enum.uniq(repeated)) <> "."}

      true ->
        rows |> Enum.map(&batch_row(&1, by_stop_id)) |> checked_rows()
    end
  end

  defp batch_row(row, by_stop_id) do
    changes =
      row
      |> Map.take(@text_fields)
      |> Map.new(fn {field, value} -> {field, String.trim(value)} end)

    %{
      stop_id: row["stop_id"],
      stop_uuid: Map.fetch!(by_stop_id, row["stop_id"]),
      changes: changes
    }
  end

  defp checked_rows(rows) do
    case Enum.filter(
           rows,
           &(&1.changes == %{} or Enum.any?(&1.changes, fn {_f, v} -> v == "" end))
         ) do
      [] ->
        {:ok, rows}

      bad ->
        {:error,
         "Each row needs at least one of stop_name, stop_code, stop_desc and stop_url with a " <>
           "nonblank value; check: " <> named(Enum.map(bad, & &1.stop_id)) <> "."}
    end
  end

  defp named(stop_ids) do
    shown = stop_ids |> Enum.take(@named_limit) |> Enum.join(", ")
    if length(stop_ids) > @named_limit, do: shown <> " and more", else: shown
  end

  defp native_review(batch, scope) do
    rows = Enum.map(batch, &%{stop_uuid: &1.stop_uuid, changes: &1.changes})

    case StopEditing.review_metadata_batch(rows, Scope.audit_context(scope)) do
      {:ok, %{valid?: true} = review} ->
        {:ok, review}

      {:ok, review} ->
        {:error, invalid_message(review)}

      {:error, :forbidden} ->
        {:error, "Your access to this service version has changed."}

      {:error, :not_found} ->
        {:error, "A stop in the approved list is no longer in this service version."}

      {:error, :too_many} ->
        {:error, "Send at most 100 rows; prepare the rest in another batch."}

      {:error, _invalid_input} ->
        {:error, "Those rows could not be prepared. Check the field names and values."}
    end
  end

  defp invalid_message(review) do
    problems =
      for %{status: :invalid, stop_id: stop_id, errors: errors} <- review.rows,
          {field, messages} <- Enum.sort(errors),
          do: "#{stop_id} #{field}: #{Enum.join(messages, " ")}"

    "The native review refused these rows: " <> named(problems) <> ". Nothing was prepared."
  end

  defp require_changes(%{changed: 0}),
    do: {:error, "Every value already matches what is stored, so there is nothing to change."}

  defp require_changes(_review), do: :ok

  # Changed rows only, each with its changed fields only (the normalized new values),
  # sorted by stop UUID.
  defp metadata_command(review) do
    rows =
      for %{status: :changed} = row <- review.rows do
        %{stop_uuid: row.stop_uuid, changes: Map.take(row.new, row.changed_fields)}
      end

    {:stop_metadata, %{rows: Enum.sort_by(rows, & &1.stop_uuid)}}
  end

  defp metadata_summary(review, basis) do
    %{
      title: "Change #{Wording.count_noun(review.changed, "stop")}",
      detail: Values.presence(basis) || "From your approved stop list",
      lines:
        [field_line(review)] ++
          unchanged_line(review.unchanged) ++
          warning_line(review.warnings) ++
          ["Nothing is saved; coordinates, IDs and accessibility are not changed"]
    }
  end

  defp field_line(review) do
    changed = Enum.filter(review.rows, &(&1.status == :changed))

    parts =
      for {field, one, many} <- @field_nouns,
          count = Enum.count(changed, &(field in &1.changed_fields)),
          count > 0,
          do: Wording.count_noun(count, one, many)

    verb =
      if Enum.sum(
           for {field, _, _} <- @field_nouns,
               do: Enum.count(changed, &(field in &1.changed_fields))
         ) == 1, do: "changes", else: "change"

    Enum.join(parts, ", ") <> " " <> verb
  end

  defp unchanged_line(0), do: []

  defp unchanged_line(count),
    do: [
      "#{Wording.count_noun(count, "stop")} #{if count == 1, do: "already matches", else: "already match"}"
    ]

  defp warning_line([]), do: []

  defp warning_line(warnings),
    do: ["#{Wording.count_noun(length(warnings), "warning")}: duplicate names"]

  defp metadata_result(review) do
    changed = Enum.filter(review.rows, &(&1.status == :changed))

    %{
      "prepared" => true,
      "changed" => review.changed,
      "unchanged" => review.unchanged,
      "field_counts" =>
        Map.new(@field_nouns, fn {field, _one, _many} ->
          {field, Enum.count(changed, &(field in &1.changed_fields))}
        end),
      "rows" =>
        changed
        |> Enum.take(@listed_rows)
        |> Enum.map(&%{"stop_id" => &1.stop_id, "changed_fields" => &1.changed_fields}),
      "rows_omitted" => max(length(changed) - @listed_rows, 0),
      "warnings" =>
        review.warnings
        |> Enum.take(@named_limit)
        |> Enum.map(&%{"kind" => "duplicate_name", "name" => &1.name, "others" => &1.others}),
      "note" => "Nothing is saved until the editor reviews and saves the change on the catalog."
    }
  end

  defp metadata_evidence(review, scope) do
    changed = Enum.filter(review.rows, &(&1.status == :changed))
    unchanged = Enum.filter(review.rows, &(&1.status == :unchanged))

    warnings =
      Enum.map(review.warnings, &"#{&1.name}: also used by #{Enum.join(&1.others, ", ")}")

    %{
      kind: "stop_metadata_batch",
      title: "Stop text changes",
      total: review.changed,
      total_label: "stops will change",
      completeness: :complete,
      completeness_reason: nil,
      facts: [%{label: "Stops already matching", value: Integer.to_string(review.unchanged)}],
      source_ref: @source_ref,
      digest: digest(%{changed: Enum.map(changed, &{&1.stop_uuid, &1.new})}),
      source_revision: nil,
      scope: Pack.evidence_scope(scope),
      exclusions: Enum.map(unchanged, &"#{&1.stop_id} already matches") ++ warnings,
      resources:
        changed
        |> Enum.take(@listed_resources)
        |> Enum.map(&%{kind: "stop", id: &1.stop_id, label: &1.new["stop_name"]})
    }
  end

  # -- the host-approved set ----------------------------------------------------

  defp require_bound(scope) do
    case bound(scope) do
      {:ok, uuids} -> {:ok, uuids}
      :error -> {:error, "This helper's approved stop list is not available."}
    end
  end

  # The set is the admitted snapshot, read only after `Scope.authorized_context/1`
  # re-verified its envelope. One scoped query must return exactly its stops: a
  # deleted, foreign or other-version stop leaves the count short.
  defp bound(%Scope{} = scope) do
    with %{kind: @snapshot_kind, payload: %{"schema_version" => 1, "stop_uuids" => uuids}} <-
           Scope.source_snapshot(scope),
         true <- is_list(uuids) and length(uuids) in 1..@max_set,
         true <- Enum.all?(uuids, &Values.uuid?/1),
         canonical = Enum.map(uuids, &canonical/1),
         true <- length(Enum.uniq(canonical)) == length(canonical),
         true <- present_count(scope, canonical) == length(canonical) do
      {:ok, canonical}
    else
      _other -> :error
    end
  end

  defp canonical(uuid) do
    {:ok, uuid} = Ecto.UUID.cast(uuid)
    uuid
  end

  defp present_count(scope, uuids) do
    Repo.aggregate(
      from(stop in Stop,
        where:
          stop.id in ^uuids and stop.organization_id == ^scope.organization_id and
            stop.gtfs_version_id == ^scope.gtfs_version_id
      ),
      :count
    )
  end
end

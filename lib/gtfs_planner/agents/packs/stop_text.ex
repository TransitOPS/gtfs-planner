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
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values

  @snapshot_kind "stop_set"
  @source_ref "gtfs_stop_set"
  @max_set 100
  @page_size 25
  @field_limit 200
  @max_offset 100_000
  @listed_resources 10
  @text_fields ~w(stop_code stop_name stop_desc stop_url)

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

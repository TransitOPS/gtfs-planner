defmodule GtfsPlanner.Gtfs.StationAnswer do
  @moduledoc """
  The boundary shared by every bounded station answer.

  A station answer is either the recorded reachability result and its current
  report facts (`GtfsPlanner.Gtfs.StationAssistant`) or the scoped projection of
  one computed native import run and the selection prepared from it
  (`GtfsPlanner.Gtfs.Import.ChangeRunReview`). Both must prove the same things
  the same way, so what they share lives here:

    * `owned_station?/2` - the snapshot's station must be the one the server host
      resolved: the same database row, a top-level station row, and the same GTFS
      stop id. A snapshot that does not prove it is refused, never repaired.
    * `scope_field/1` - the organization, version and station identity an answer
      is scoped to, reported beside it.
    * `digest/1` - one deterministic lowercase SHA-256 over `:erlang` terms, so
      two processes describing the same state produce the same digest.
    * `capture_time/0` - the answer's own capture time, kept separate from the
      capture time of the data it describes.
    * `encoded_bytes/2` and `shrink/5` - the existing 32 KiB tool-result limit. An
      oversized prefix is shortened to the rows that fit; a single row that cannot
      fit returns zero rows with narrowing guidance rather than a partial row that
      looks whole.
  """

  alias GtfsPlanner.Gtfs.ServiceQueries

  @typedoc "One station/run selection read from a server-frozen source snapshot."
  @type selection :: %{
          organization_id: Ecto.UUID.t(),
          gtfs_version_id: Ecto.UUID.t(),
          station_id: Ecto.UUID.t(),
          station_stop_id: String.t(),
          run_id: Ecto.UUID.t() | nil,
          actor_id: Ecto.UUID.t() | nil,
          source_snapshot: map()
        }

  @max_encoded_bytes 32 * 1024

  @doc """
  Whether the current station snapshot describes the station this answer is scoped
  to.

  The database UUID, the top-level `location_type` 1 and the GTFS stop id must all
  match, so a station that was replaced, deleted or re-identified is one refusal
  rather than a projection of somebody else's station.
  """
  @spec owned_station?(map(), selection()) :: boolean()
  def owned_station?(%{station: station}, selection) do
    station.id == selection.station_id and station.location_type == 1 and
      station.stop_id == selection.station_stop_id
  end

  def owned_station?(_snapshot, _selection), do: false

  @doc "The organization, version and station identity this answer is scoped to."
  @spec scope_field(selection()) :: map()
  def scope_field(selection) do
    %{
      organization_id: selection.organization_id,
      gtfs_version_id: selection.gtfs_version_id,
      identity: "station:#{selection.station_stop_id}"
    }
  end

  @doc "The deterministic digest of one answer term."
  @spec digest(term()) :: String.t()
  def digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The read-only snapshot implementation every answer reads through.

  It follows the existing `ServiceQueries` boundary and stays overridable through
  the same application environment, so a station answer and a service-query
  snapshot always agree on how a read is isolated.
  """
  @spec snapshot_module() :: module()
  def snapshot_module do
    Application.get_env(
      :gtfs_planner,
      :gtfs_service_query_snapshot,
      ServiceQueries.Snapshot.Repo
    )
  end

  @doc "This answer's own capture time, to the second."
  @spec capture_time() :: String.t()
  def capture_time, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "The encoded size of one answer and its evidence together."
  @spec encoded_bytes(term(), term()) :: non_neg_integer()
  def encoded_bytes(result, evidence) do
    Jason.encode!(%{result: result, evidence: evidence}) |> byte_size()
  end

  @doc """
  Keeps one answer inside the 32 KiB tool-result limit.

  `builder` rebuilds the evidence for a candidate answer, so the reported counts
  always describe the rows that answer actually carries.
  """
  @spec shrink(map(), String.t(), String.t(), String.t(), (map() -> map())) :: map()
  def shrink(result, rows_key, counts_key, guidance, builder) do
    if encoded_bytes(result, builder.(result)) <= @max_encoded_bytes do
      result
    else
      case result[rows_key] do
        [] ->
          result
          |> Map.put(rows_key, [])
          |> Map.put("completeness", "incomplete")
          |> Map.put("narrowing", guidance)

        rows ->
          # The tail goes first, so the page keeps the rows that begin at this
          # answer's offset and the next offset continues from where it stopped.
          shortened = Enum.drop(rows, -1)

          result
          |> Map.put(rows_key, shortened)
          |> Map.put("counts", adjust_counts(result["counts"], counts_key, length(shortened)))
          # A shortened page continues where it actually stopped, so a caller
          # paging by this offset never steps over the rows the size bound
          # removed from this answer.
          |> Map.put("next_offset", offset_of(result["counts"]) + length(shortened))
          |> Map.put("completeness", "incomplete")
          |> Map.put("narrowing", guidance)
          |> shrink(rows_key, counts_key, guidance, builder)
      end
    end
  end

  defp offset_of(counts) when is_map(counts), do: Map.get(counts, "offset", 0)
  defp offset_of(_counts), do: 0

  defp adjust_counts(counts, counts_key, returned) do
    Map.put(counts, counts_key, returned)
  end
end

defmodule GtfsPlanner.Gtfs.ReleaseComparison.Compute do
  @moduledoc """
  The byte-owning half of one native comparison: read, project, compare.

  The coordinator in `GtfsPlanner.Gtfs.ReleaseComparison.Runner` owns the
  download claims and this module never claims, releases or finalizes anything.
  It receives the claims the coordinator already took plus the selection those
  claims came from, and reads each distinct artifact exactly once through
  `GtfsPlanner.Gtfs.ReleaseComparison.Reader/2`, projects it through step 3's
  `Projection.build/1` and compares the two projections through step 6's
  `Compare.run/3`.

  A repeated run identity is resolved once and both sides reuse that one
  projection, so comparing an artifact with itself never reads the bytes twice
  and never produces a second receipt.

  Every refusal is one of the reasons step 2's reader and steps 3 and 6 already
  name - `:unavailable`, `:unsupported_size`, `:invalid_archive` or
  `:malformed_csv` - so the coordinator reports a truthful cause instead of a
  generic failure.
  """

  alias GtfsPlanner.Gtfs.ReleaseComparison.Compare
  alias GtfsPlanner.Gtfs.ReleaseComparison.Projection
  alias GtfsPlanner.Gtfs.ReleaseComparison.Reader

  @type reason :: :unavailable | :unsupported_size | :invalid_archive | :malformed_csv

  @doc """
  Reads and compares the two claimed artifacts of `selection`.

  `claims` maps a run id to the claim `ExportRuns.claim_download/4` returned for
  it. A run whose claim is missing never reads anything and refuses as
  `:unavailable`.
  """
  @spec run(map(), %{optional(Ecto.UUID.t()) => map()}) ::
          {:ok, map()} | {:error, reason()}
  def run(selection, claims) when is_map(selection) and is_map(claims) do
    with {:ok, projections} <- project_each(claims, [selection.left, selection.right]) do
      Compare.run(
        Map.fetch!(projections, selection.left.run_id),
        Map.fetch!(projections, selection.right.run_id),
        %{from: selection.from, to: selection.to}
      )
    end
  end

  def run(_selection, _claims), do: {:error, :unavailable}

  # Each distinct artifact is read once. A comparison of one artifact with itself
  # therefore describes the same bytes once instead of twice.
  defp project_each(claims, identities) do
    Enum.reduce_while(identities, {:ok, %{}}, &project_step(claims, &1, &2))
  end

  defp project_step(claims, identity, {:ok, projections}) do
    case Map.fetch(projections, identity.run_id) do
      {:ok, _projection} ->
        {:cont, {:ok, projections}}

      :error ->
        case project(claims, identity) do
          {:ok, projection} -> {:cont, {:ok, Map.put(projections, identity.run_id, projection)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end
  end

  defp project(claims, identity) do
    with {:ok, claim} <- fetch_claim(claims, identity.run_id),
         {:ok, reader_output} <- Reader.read(claim, identity) do
      Projection.build(reader_output)
    end
  end

  defp fetch_claim(claims, run_id) do
    case Map.fetch(claims, run_id) do
      {:ok, claim} -> {:ok, claim}
      :error -> {:error, :unavailable}
    end
  end
end

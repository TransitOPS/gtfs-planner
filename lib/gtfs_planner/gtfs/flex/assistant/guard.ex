defmodule GtfsPlanner.Gtfs.Flex.Assistant.Guard do
  @moduledoc """
  The reviewed assistant guard one guarded native Flex save is fenced with
  (AC-10, AC-11; CL-5).

  A guard is created on the server, after an editor has reviewed a prepared
  candidate against a frozen workspace, and it carries five digests and nothing
  else:

    * `source_digest` — the accepted source envelope's own server-computed
      digest, so a replaced source cannot carry an old review into a save;
    * `context_digest` — the conversation context digest the preparation was
      dispatched under, so a different context cannot either;
    * `saved_fingerprint` — the baseline `GtfsPlanner.Gtfs.Flex.Assistant.fingerprint/1`
      over the dependencies the review read;
    * `patch_digest` — the exact prepared patch the review compared, through
      `patch_digest/1`;
    * `candidate_digest` — the final whole page the review was shown, through
      `candidate_digest/3`.

  `candidate_digest/3` is computed from the same `loaded` struct, `attrs` and
  `area_inputs` the save itself will submit, so a field the editor changes after
  the review, an area renamed after it, a removed geometry or an hours row edited
  after it all move the digest and the save is refused. The service's own
  identity, `lock_version` and timestamps are left out: the baseline fingerprint
  already covers the stored row, and the native optimistic lock owns the
  `:stale` outcome.

  Nothing here writes, reads or authorizes. `new/1` only checks that a guard is
  well shaped, and every digest is content-addressed through
  `GtfsPlanner.Gtfs.Flex.Assistant.canonical/1`, so the same content always
  produces the same guard and any change to it produces a different one. A guard
  is never taken from a client payload: the host that reviewed the candidate
  builds it and hands it to `GtfsPlanner.Gtfs.Flex.save_service/5`.
  """

  alias GtfsPlanner.Gtfs.Flex.Assistant
  alias GtfsPlanner.Gtfs.FlexService

  @digest_fields [
    :source_digest,
    :context_digest,
    :saved_fingerprint,
    :patch_digest,
    :candidate_digest
  ]

  # Every digest in this slice is a lowercase hex SHA256 over one canonical
  # encoding, so a guard cannot carry a truncated, re-cased or invented value.
  @digest_format ~r/\A[0-9a-f]{64}\z/

  # The area fields one save may write, plus the geometry it carries with them.
  # The input position is implied by the list order, which the digest keeps.
  @area_fields [
    :key,
    :name,
    :source,
    :census_geoid,
    :census_layer,
    :census_vintage,
    :route_ids,
    :distance_m,
    :geojson
  ]

  defstruct @digest_fields

  @type t :: %__MODULE__{
          source_digest: String.t(),
          context_digest: String.t(),
          saved_fingerprint: String.t(),
          patch_digest: String.t(),
          candidate_digest: String.t()
        }

  @typedoc "Why a proposed guard is not a guard at all."
  @type error :: {:invalid_guard, term()}

  @doc """
  Builds a guard from exactly its five digests.

  Anything else — a missing field, an extra field, a value that is not a
  64-character lowercase hex digest — is `{:error, {:invalid_guard, reason}}`,
  so a host cannot construct a half-bound guard and hand it to a save.
  """
  @spec new(map()) :: {:ok, t()} | {:error, error()}
  def new(attrs) when is_map(attrs) do
    with :ok <- check_fields(attrs), {:ok, digests} <- check_digests(attrs) do
      {:ok, struct(__MODULE__, digests)}
    end
  end

  def new(_attrs), do: {:error, {:invalid_guard, :not_a_map}}

  @doc """
  The digest of one prepared patch, as the review read it.

  The patch is the string-keyed replacement arrays `Assistant.prepare/2` returns,
  and it is digested exactly as submitted, so a review of one patch cannot be
  spent on another.
  """
  @spec patch_digest(map()) :: String.t()
  def patch_digest(patch) when is_map(patch), do: digest(patch)

  @doc """
  The digest of the whole page one save will write.

  `loaded` is the struct the page loaded, `attrs` the same map
  `GtfsPlanner.Gtfs.Flex.save_service/4,5` will apply and `area_inputs` the same
  ordered list of atom-keyed area inputs it will replace the areas with. The
  candidate is the native changeset's own applied result, so the digest covers
  the values that would be stored rather than the submitted shape of them.

  `:invalid` means the native changeset refuses this page; there is then no
  candidate to review, and the caller answers with the native refusal instead of
  a staleness.
  """
  @spec candidate_digest(FlexService.t(), map(), [map()]) :: {:ok, String.t()} | :invalid
  def candidate_digest(%FlexService{} = loaded, attrs, area_inputs)
      when is_map(attrs) and is_list(area_inputs) do
    with {:ok, candidate} <- candidate(loaded, attrs) do
      {:ok,
       digest(%{
         service:
           candidate
           |> Map.from_struct()
           |> Map.drop([
             :__struct__,
             :__meta__,
             :id,
             :lock_version,
             :inserted_at,
             :updated_at,
             :areas
           ]),
         areas: Enum.map(area_inputs, &area_content/1)
       })}
    end
  end

  defp candidate(%FlexService{} = loaded, attrs) do
    changeset = FlexService.changeset(loaded, attrs)

    if changeset.valid? do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    else
      :invalid
    end
  end

  defp area_content(input) when is_map(input), do: Map.take(input, @area_fields)

  defp check_fields(attrs) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(@digest_fields) do
      :ok
    else
      {:error, {:invalid_guard, {:fields, Enum.sort(Map.keys(attrs))}}}
    end
  end

  defp check_digests(attrs) do
    Enum.reduce_while(@digest_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch(attrs, field) do
        {:ok, value} when is_binary(value) ->
          if Regex.match?(@digest_format, value) do
            {:cont, {:ok, Map.put(acc, field, value)}}
          else
            {:halt, {:error, {:invalid_guard, field}}}
          end

        _other ->
          {:halt, {:error, {:invalid_guard, field}}}
      end
    end)
  end

  defp digest(value) do
    value
    |> Assistant.canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

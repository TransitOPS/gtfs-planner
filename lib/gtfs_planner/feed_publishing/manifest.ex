defmodule GtfsPlanner.FeedPublishing.Manifest do
  @moduledoc """
  Encodes and names the one current-manifest object for a publishing channel.

  The independent serving layer reads this small JSON object and then reads the
  immutable payload objects it names; it never calls the application or the
  database. The manifest therefore carries only public protocol values: the
  claimed namespace prefix, the opaque public claim, the channel, a unique
  public generation, the sequence, the generated instant and the payload object
  descriptors. No actor, organization id, database id, draft or diagnostic is
  written here.

  Every payload key must stay under the same claimed prefix. A descriptor that
  points anywhere else is refused as `{:error, :invalid_objects}` rather than
  published, because the serving consumer only accepts same-prefix keys.

  The manifest body is frozen once per attempt and never regenerated: the
  attempt's stored `manifest_body` is what a retry replays, so a repeated
  upload installs the exact same bytes or fails its own precondition. Distinct
  attempts always encode a different `generation`, so a strong representation
  ETag cannot recur merely because the ZIP or feed contents repeat.

  `key/2` names the one manifest object for a channel; the payload object keys
  are already frozen in the attempt's `object_receipts`.
  """

  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication

  @schema 1
  @max_bytes 64 * 1024
  @object_fields ~w(key sha256 bytes content_type)
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/

  @keys %{
    full: "static/current-gtfs.json",
    flex: "static/current-flex.json",
    pathways: "static/current-pathways.json",
    alerts: "realtime/current-alerts.json"
  }

  @doc """
  Names the current-manifest object key for a claimed prefix and channel.

  ## Examples

      iex> key("rivercity", :alerts)
      "rivercity/realtime/current-alerts.json"
  """
  @spec key(String.t(), atom()) :: String.t()
  def key(prefix, channel) when is_binary(prefix) do
    case Map.fetch(@keys, channel) do
      {:ok, suffix} -> prefix <> "/" <> suffix
      :error -> raise ArgumentError, "unknown publishing channel #{inspect(channel)}"
    end
  end

  @doc """
  Encodes the manifest bytes for one attempt.

  The attempt must have its `publication` and `publication.namespace`
  associations loaded, because the manifest names the claimed prefix and claim.

  ## Examples

      iex> encode(attempt_with_namespace)
      {:ok, ~s({"schema":1,"namespace":"rivercity",...})}

      iex> encode(%Attempt{})
      {:error, :incomplete}
  """
  @spec encode(Attempt.t()) :: {:ok, binary()} | {:error, atom()}
  def encode(
        %Attempt{
          publication: %Publication{channel: channel, namespace: %Namespace{} = namespace}
        } = attempt
      ) do
    with {:ok, channel} <- channel(channel),
         {:ok, objects} <- objects(attempt, namespace.prefix) do
      body =
        Jason.encode!(%{
          "schema" => @schema,
          "namespace" => namespace.prefix,
          "claim" => namespace.public_claim,
          "channel" => Atom.to_string(channel),
          "generation" => attempt.generation,
          "sequence" => attempt.sequence,
          "generated_at" => generated_at(attempt),
          "objects" => objects
        })

      if byte_size(body) <= @max_bytes, do: {:ok, body}, else: {:error, :too_large}
    end
  end

  def encode(_attempt), do: {:error, :incomplete}

  defp channel(channel) when is_atom(channel) do
    if Map.has_key?(@keys, channel), do: {:ok, channel}, else: {:error, :unsupported_channel}
  end

  defp channel(_channel), do: {:error, :unsupported_channel}

  defp objects(%Attempt{object_receipts: objects} = _attempt, prefix) when is_map(objects) do
    if Enum.all?(objects, &valid_object?(&1, prefix)) do
      {:ok, objects}
    else
      {:error, :invalid_objects}
    end
  end

  defp objects(_attempt, _prefix), do: {:error, :invalid_objects}

  defp valid_object?({role, descriptor}, prefix) do
    is_binary(role) and is_map(descriptor) and
      Enum.all?(@object_fields, &Map.has_key?(descriptor, &1)) and
      is_binary(descriptor["key"]) and String.starts_with?(descriptor["key"], prefix <> "/") and
      is_binary(descriptor["sha256"]) and Regex.match?(@sha256_pattern, descriptor["sha256"]) and
      is_integer(descriptor["bytes"]) and descriptor["bytes"] >= 0 and
      is_binary(descriptor["content_type"]) and descriptor["content_type"] != ""
  end

  # A persisted attempt has an inserted_at, which keeps re-encoding the same
  # attempt byte-identical. The fallback only applies to an unsaved struct.
  defp generated_at(%Attempt{inserted_at: %DateTime{} = at}),
    do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp generated_at(_attempt),
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end

defmodule GtfsPlanner.FeedPublishing.Storage do
  @moduledoc """
  The concrete protocol boundary for public object storage.

  This module is the only place the application talks to object storage. It uses
  the installed `Req` client, and `Req`'s own AWS Signature Version 4 step, so no
  additional S3 SDK is involved. Every request is signed for the explicit `s3`
  service and the configured region with the dedicated publishing credentials;
  `GtfsPlanner.FeedPublishing.Config` refuses to enable publishing until a
  complete endpoint, region, credential pair and public origin are present.

  A request is always sent to the configured endpoint only, over the deployed
  HTTPS origin, with TLS verification left at the `Req`/Mint default (on).
  Redirects are disabled and automatic retries never run: a transport-level
  redirect or a transient provider error is reported to the caller instead of
  being silently followed or replayed. `GtfsPlanner.FeedPublishing.Publisher`
  owns retry because it, not the HTTP client, knows whether an attempt is frozen
  and identical. Connect timeout is 10 seconds and the response wait is 30
  seconds. A transport timeout cannot prove whether a write happened, so every
  timeout is reported as `:unknown` rather than as a definite failure; other
  transport failures are `:unavailable`.

  ## Immutable payloads

  `put_payload/5` uploads with `If-None-Match: *`. A `412` is not a failure by
  itself: the existing object is read back and its size, its server-owned
  `publication-*` metadata and a real SHA-256 of its bytes must all match the
  caller's `sha256`/`identity`. Only then does the call return the existing
  object as the receipt. A foreign object is refused as `:conflict` and never
  overwritten or adopted.

  `source` is `{:file, path}` to stream a file or `{:bytes, binary}` to upload
  bytes already in memory. A streamed file uses `UNSIGNED-PAYLOAD` in its
  signature and carries an explicit `Content-Length` taken from the file size,
  as the installed `Req` SigV4 step requires. The `identity` map is
  `%{claim: binary, channel: binary, sequence: integer, generation: binary}`;
  those four values become the object's `x-amz-meta-publication-*` metadata and
  nothing else, so no private identifier is written to a public object.

  ## Manifest objects

  `read_manifest/2` performs one bounded `GET`. A body larger than 64 KiB is
  refused as `:manifest_too_large` rather than truncated, and the provider's
  opaque strong `ETag` and `Last-Modified` are returned exactly as received. A
  missing object is `:missing`; anything else that cannot be read truthfully is
  an error, never a fabricated empty manifest. `put_manifest/4` replaces the
  single current manifest with `If-None-Match: *` on first creation or
  `If-Match` of the frozen predecessor otherwise, and reports a lost condition
  as `:precondition_failed` so a stale worker cannot rebase.

  ## Diagnostics

  Every error term is a bare atom. Signed headers, credential values, request
  URLs and provider response bodies never enter a returned error, so a public
  status or a log line built from one of these results cannot disclose a secret
  or a private identifier.

  ## Test substitution

  Tests replace only the final HTTP transport. `config/test.exs` installs
  `GtfsPlanner.FeedPublishing.HTTPBoundary.request/4` as the Req `:finch_request`
  option, so request construction and SigV4 signing above remain real while no
  test can reach a live provider.
  """

  alias GtfsPlanner.FeedPublishing.Config

  @connect_timeout 10_000
  @receive_timeout 30_000
  @manifest_max_bytes 64 * 1024
  @stream_chunk_bytes 64 * 1024
  @http_options_key :feed_publishing_http_options

  @type source :: {:file, Path.t()} | {:bytes, binary()}

  @type identity :: %{
          claim: binary(),
          channel: binary(),
          sequence: integer(),
          generation: binary()
        }

  @type receipt :: %{
          key: binary(),
          etag: binary() | nil,
          last_modified: binary() | nil,
          sha256: binary(),
          bytes: non_neg_integer()
        }

  @type error ::
          :unknown
          | :unavailable
          | :conflict
          | :precondition_failed
          | :manifest_too_large
          | :invalid_response
          | :source_unavailable

  @doc """
  Uploads one immutable payload, or accepts the identical object that already
  exists at `key`.

  Returns `{:ok, receipt}` when this call created the object or when the existing
  object is byte-identical with matching identity; `{:error, :conflict}` when a
  foreign object occupies the key; and `{:error, :unknown}` when a transport
  timeout leaves the outcome undecided.

  ## Examples

      iex> put_payload(config, "rivercity/static/objects/gen/gtfs.zip", {:file, path}, sha256, %{claim: "c", channel: "full", sequence: 3, generation: "g"})
      {:ok, %{key: "rivercity/static/objects/gen/gtfs.zip", sha256: sha256, bytes: 42}}
  """
  @spec put_payload(Config.t(), binary(), source(), binary(), identity()) ::
          {:ok, receipt()} | {:error, error()}
  def put_payload(
        %Config{} = config,
        key,
        source,
        sha256,
        %{claim: _, channel: _, sequence: _, generation: _} = identity
      )
      when is_binary(key) and is_binary(sha256) do
    with {:ok, body, size} <- payload_body(source) do
      request =
        request(config, :put, key,
          headers:
            [{"content-length", Integer.to_string(size)}, {"if-none-match", "*"}] ++
              identity_headers(identity),
          body: body
        )

      case send(request) do
        {:ok, %Req.Response{status: 412}} ->
          verify_existing(config, key, sha256, size, identity)

        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok, receipt(key, response.headers, sha256, size)}

        {:ok, %Req.Response{}} ->
          {:error, :unavailable}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, :unknown}

        {:error, _transport_failure} ->
          {:error, :unavailable}
      end
    end
  end

  @doc """
  Reads the current manifest object, bounded to 64 KiB.

  Returns `:missing` for an absent object, `{:ok, bytes, etag, last_modified}`
  with the provider's opaque ETag and Last-Modified unchanged, or an error.

  ## Examples

      iex> read_manifest(config, "rivercity/static/current-gtfs.json")
      :missing

      iex> read_manifest(config, "rivercity/static/current-gtfs.json")
      {:ok, ~s({"schema":1}), ~s("strong-etag"), "Thu, 02 Oct 2026 12:00:00 GMT"}
  """
  @spec read_manifest(Config.t(), binary()) ::
          :missing | {:ok, binary(), binary(), binary() | nil} | {:error, error()}
  def read_manifest(%Config{} = config, key) when is_binary(key) do
    case send(request(config, :get, key, [])) do
      {:ok, %Req.Response{status: 404}} ->
        :missing

      {:ok, %Req.Response{status: status, headers: headers, body: body}}
      when status in 200..299 ->
        read_manifest_body(headers, body)

      {:ok, %Req.Response{}} ->
        {:error, :unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :unknown}

      {:error, _transport_failure} ->
        {:error, :unavailable}
    end
  end

  @doc """
  Conditionally writes the current manifest object.

  `condition` is `:absent` for a first creation (`If-None-Match: *`) or
  `{:etag, etag}` to replace the frozen predecessor (`If-Match`). Returns
  `{:error, :precondition_failed}` when the provider rejected the condition and
  `{:error, :unknown}` when a timeout leaves the outcome undecided.

  ## Examples

      iex> put_manifest(config, "rivercity/static/current-gtfs.json", ~s({"schema":1}), :absent)
      {:ok, %{key: "rivercity/static/current-gtfs.json"}}

      iex> put_manifest(config, "rivercity/static/current-gtfs.json", ~s({"schema":1}), {:etag, ~s("stale")})
      {:error, :precondition_failed}
  """
  @spec put_manifest(Config.t(), binary(), binary(), :absent | {:etag, binary()}) ::
          {:ok, receipt()} | {:error, error()}
  def put_manifest(%Config{} = config, key, bytes, condition)
      when is_binary(key) and is_binary(bytes) do
    headers =
      [
        {"content-type", "application/json"},
        {"content-length", Integer.to_string(byte_size(bytes))}
      ] ++ condition_headers(condition)

    case send(request(config, :put, key, headers: headers, body: bytes)) do
      {:ok, %Req.Response{status: 412}} ->
        {:error, :precondition_failed}

      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, receipt(key, response.headers, sha256_hex(bytes), byte_size(bytes))}

      {:ok, %Req.Response{}} ->
        {:error, :unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :unknown}

      {:error, _transport_failure} ->
        {:error, :unavailable}
    end
  end

  defp condition_headers(:absent), do: [{"if-none-match", "*"}]
  defp condition_headers({:etag, etag}) when is_binary(etag), do: [{"if-match", etag}]

  defp read_manifest_body(headers, body) do
    cond do
      oversize_manifest?(headers, body) ->
        {:error, :manifest_too_large}

      is_binary(header(headers, "etag")) ->
        {:ok, body, header(headers, "etag"), header(headers, "last-modified")}

      true ->
        {:error, :invalid_response}
    end
  end

  defp verify_existing(config, key, sha256, size, identity) do
    case send(request(config, :head, key, [])) do
      {:ok, %Req.Response{status: status, headers: headers}} when status in 200..299 ->
        if metadata_matches?(headers, size, identity) do
          confirm_existing_bytes(config, key, sha256, size, headers)
        else
          {:error, :conflict}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :unknown}

      {:ok, %Req.Response{}} ->
        {:error, :conflict}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :unknown}

      {:error, _transport_failure} ->
        {:error, :unavailable}
    end
  end

  # A 412 only proves *something* is at the key. The bytes are re-hashed before
  # the existing object can stand in for this upload, so a same-size impostor is
  # still refused. The download can be no larger than the size the caller is
  # already reproducing, because the size precondition above is checked first.
  defp confirm_existing_bytes(config, key, sha256, size, headers) do
    case send(request(config, :get, key, [])) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        cond do
          byte_size(body) != size -> {:error, :conflict}
          sha256_hex(body) != sha256 -> {:error, :conflict}
          true -> {:ok, receipt(key, headers, sha256, size)}
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :unknown}

      {:ok, %Req.Response{}} ->
        {:error, :conflict}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :unknown}

      {:error, _transport_failure} ->
        {:error, :unavailable}
    end
  end

  defp metadata_matches?(headers, size, identity) do
    header(headers, "content-length") == Integer.to_string(size) and
      header(headers, "x-amz-meta-publication-claim") == identity.claim and
      header(headers, "x-amz-meta-publication-channel") == identity.channel and
      header(headers, "x-amz-meta-publication-sequence") == Integer.to_string(identity.sequence) and
      header(headers, "x-amz-meta-publication-generation") == identity.generation
  end

  defp payload_body({:bytes, bytes}) when is_binary(bytes), do: {:ok, bytes, byte_size(bytes)}

  defp payload_body({:file, path}) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:ok, File.stream!(path, [], @stream_chunk_bytes), size}

      _ ->
        {:error, :source_unavailable}
    end
  end

  defp identity_headers(identity) do
    [
      {"x-amz-meta-publication-claim", identity.claim},
      {"x-amz-meta-publication-channel", identity.channel},
      {"x-amz-meta-publication-sequence", Integer.to_string(identity.sequence)},
      {"x-amz-meta-publication-generation", identity.generation}
    ]
  end

  defp request(%Config{} = config, method, key, options) do
    Req.new(
      method: method,
      url: object_url(config, key),
      headers: Keyword.get(options, :headers, []),
      body: Keyword.get(options, :body),
      decode_body: false,
      redirect: false,
      retry: false,
      connect_options: [timeout: @connect_timeout],
      receive_timeout: @receive_timeout,
      aws_sigv4: [
        access_key_id: config.access_key_id,
        secret_access_key: config.secret_access_key,
        service: :s3,
        region: config.region
      ]
    )
  end

  defp object_url(%Config{endpoint: %URI{} = endpoint, bucket: bucket}, key) do
    endpoint
    |> URI.merge("/#{bucket}/#{key}")
    |> URI.to_string()
  end

  defp send(request), do: Req.request(request, transport_options())

  # The production build has no `:feed_publishing_http_options`, so nothing is
  # merged and the real Finch transport runs. Tests install the loopback final
  # transport here; request construction and signing are untouched.
  defp transport_options do
    case Application.get_env(:gtfs_planner, @http_options_key) do
      options when is_list(options) -> options
      _ -> []
    end
  end

  defp oversize_manifest?(headers, body) do
    byte_size(body) > @manifest_max_bytes or declared_size(headers) > @manifest_max_bytes
  end

  defp declared_size(headers) do
    case header(headers, "content-length") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {size, ""} -> size
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp receipt(key, headers, sha256, size) do
    %{
      key: key,
      etag: header(headers, "etag"),
      last_modified: header(headers, "last-modified"),
      sha256: sha256,
      bytes: size
    }
  end

  defp header(headers, name), do: headers |> Map.get(name, []) |> List.first()

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

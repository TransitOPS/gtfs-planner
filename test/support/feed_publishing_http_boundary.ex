defmodule GtfsPlanner.FeedPublishing.HTTPBoundary do
  @moduledoc """
  Deterministic in-memory object store that stands in for the Req final HTTP
  transport in tests.

  `GtfsPlanner.FeedPublishing.Config` has no `config/test.exs` counterpart that
  could reach a provider, so `config/test.exs` installs `request/4` as the Req
  `:finch_request` option. Only the final network hop is replaced: the production
  `GtfsPlanner.FeedPublishing.Storage` request building, SigV4 signing,
  conditional headers, timeouts, redirect setting and retry setting all run
  unchanged and are visible on the recorded `%Req.Request{}`.

  State lives in the calling process's dictionary, so each ExUnit test starts
  empty and passes without a shared table. The store understands the small S3
  surface Storage uses: `PUT` with `If-None-Match: *` or `If-Match`, `GET`, and
  `HEAD`, with `ETag`, `Last-Modified`, `Content-Length` and `x-amz-meta-*`
  headers. `script/1` queues canned responses or transport errors for the next
  requests so a test can observe that a redirect is not followed and a transient
  write failure is not retried.
  """

  @objects {__MODULE__, :objects}
  @requests {__MODULE__, :requests}
  @script {__MODULE__, :script}

  @doc """
  Req `:finch_request` function. Records the request, then answers from the
  queued script if one is present, otherwise from the in-memory store.
  """
  @spec request(Req.Request.t(), Finch.Request.t(), term(), list()) ::
          {Req.Request.t(), Req.Response.t() | Exception.t()}
  def request(req, finch_request, _finch_name, _finch_options) do
    record(req, finch_request)

    case take_script() do
      {:ok, result} -> {req, resolve(result)}
      :none -> {req, serve(req)}
    end
  end

  @doc "Clears seeded objects, recorded requests and any queued script."
  @spec reset() :: :ok
  def reset do
    Process.delete(@objects)
    Process.delete(@requests)
    Process.delete(@script)
    :ok
  end

  @doc "Seeds one object. `:metadata` is a map of `publication-*` suffix to value."
  @spec put_object(binary(), binary(), keyword()) :: :ok
  def put_object(key, body, opts \\ []) do
    Process.put(@objects, Map.put(objects(), key, object(body, opts)))
    :ok
  end

  @doc "Returns the seeded objects keyed by object key."
  @spec objects() :: map()
  def objects, do: Process.get(@objects, %{})

  @doc "Returns every request this process's Storage calls made, oldest first."
  @spec requests() :: [%{request: Req.Request.t(), finch_request: Finch.Request.t()}]
  def requests, do: @requests |> Process.get([]) |> Enum.reverse()

  @doc """
  Queues results for the next requests, each one of:

    * `{:response, status, headers, body}` — a canned HTTP response
    * `{:transport_error, reason}` — a `Req.TransportError`
  """
  @spec script([term()]) :: :ok
  def script(results) when is_list(results) do
    Process.put(@script, results)
    :ok
  end

  defp take_script do
    case Process.get(@script, []) do
      [next | rest] ->
        Process.put(@script, rest)
        {:ok, next}

      [] ->
        :none
    end
  end

  defp resolve({:transport_error, reason}), do: %Req.TransportError{reason: reason}
  defp resolve({:response, status, headers, body}), do: respond(status, headers, body)

  defp serve(req) do
    key = object_key(req)

    case req.method do
      :put -> serve_put(req, key)
      :get -> if list_request?(req), do: serve_list(req), else: serve_get(key, false)
      :head -> serve_get(key, true)
      :delete -> serve_delete(key)
      _other -> respond(405, [], "")
    end
  end

  defp serve_delete(key) do
    Process.put(@objects, Map.delete(objects(), key))
    respond(204, [], "")
  end

  # A bounded listing, so `Storage.list_payloads/4` can be exercised at the real
  # boundary. The continuation token is the last key of the page, which is
  # opaque to the caller exactly as a provider token would be.
  defp list_request?(%Req.Request{url: %URI{query: query}}),
    do: is_binary(query) and String.contains?(query, "list-type=2")

  defp serve_list(%Req.Request{url: %URI{query: query}}) do
    params = URI.decode_query(query || "")
    prefix = params["prefix"] || ""
    token = params["continuation-token"]
    max = max_keys(params["max-keys"])

    keys =
      objects()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.sort()
      |> drop_through(token)

    {page, rest} = Enum.split(keys, max)
    truncated = rest != []
    next = if truncated, do: List.last(page), else: nil

    respond(
      200,
      [{"content-type", "application/xml"}],
      list_body(prefix, page, max, truncated, next)
    )
  end

  defp drop_through(keys, nil), do: keys
  defp drop_through(keys, token), do: Enum.drop_while(keys, &(&1 <= token))

  defp max_keys(value) when is_binary(value) do
    case Integer.parse(value) do
      {max, ""} when max > 0 -> max
      _other -> 1000
    end
  end

  defp max_keys(_value), do: 1000

  defp list_body(prefix, keys, max, truncated, next) do
    contents =
      Enum.map_join(keys, fn key ->
        object = Map.fetch!(objects(), key)

        "<Contents><Key>#{escape_xml(key)}</Key>" <>
          "<LastModified>#{object.last_modified}</LastModified>" <>
          "<ETag>#{escape_xml(object.etag)}</ETag>" <>
          "<Size>#{byte_size(object.body)}</Size></Contents>"
      end)

    next_token =
      if truncated,
        do: "<NextContinuationToken>#{escape_xml(next)}</NextContinuationToken>",
        else: ""

    ~s(<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Name>gtfs-planner-loopback</Name>) <>
      "<Prefix>#{escape_xml(prefix)}</Prefix>" <>
      "<KeyCount>#{length(keys)}</KeyCount><MaxKeys>#{max}</MaxKeys>" <>
      "<IsTruncated>#{truncated}</IsTruncated>#{next_token}#{contents}</ListBucketResult>"
  end

  defp escape_xml(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_xml(value), do: value

  defp serve_put(req, key) do
    existing = Map.get(objects(), key)

    cond do
      header(req, "if-none-match") == "*" and existing != nil ->
        respond(412, [], "")

      if_match = header(req, "if-match") ->
        if existing != nil and existing.etag == if_match do
          store_put(key, req)
        else
          respond(412, [], "")
        end

      true ->
        store_put(key, req)
    end
  end

  defp store_put(key, req) do
    object = object(body_bytes(req.body), metadata: metadata_from(req))
    Process.put(@objects, Map.put(objects(), key, object))
    respond(200, object_headers(object), "")
  end

  defp serve_get(key, head?) do
    case Map.get(objects(), key) do
      nil -> respond(404, [], "")
      object -> respond(200, object_headers(object), if(head?, do: "", else: object.body))
    end
  end

  defp object(body, opts) do
    %{
      body: body,
      etag: Keyword.get(opts, :etag) || strong_etag(body),
      last_modified: Keyword.get(opts, :last_modified, http_date()),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp object_headers(object) do
    [
      {"etag", object.etag},
      {"last-modified", object.last_modified},
      {"content-length", Integer.to_string(byte_size(object.body))}
    ] ++ Enum.map(object.metadata, fn {name, value} -> {"x-amz-meta-#{name}", value} end)
  end

  defp metadata_from(req) do
    req.headers
    |> Enum.filter(fn {name, _values} -> String.starts_with?(name, "x-amz-meta-") end)
    |> Map.new(fn {name, values} ->
      {String.replace_prefix(name, "x-amz-meta-", ""), List.first(values)}
    end)
  end

  defp object_key(%Req.Request{url: %URI{path: path}}) do
    path
    |> String.trim_leading("/")
    |> String.split("/", parts: 2)
    |> List.last()
  end

  defp body_bytes(body) when is_binary(body), do: body
  defp body_bytes(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp body_bytes(body), do: body |> Enum.to_list() |> IO.iodata_to_binary()

  defp header(req, name), do: req.headers |> Map.get(name, []) |> List.first()

  defp respond(status, headers, body) do
    Enum.reduce(headers, Req.Response.new(status: status, body: body), fn {name, value},
                                                                          response ->
      Req.Response.put_header(response, name, value)
    end)
  end

  defp strong_etag(body),
    do: ~s(") <> Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> ~s(")

  defp http_date, do: Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S GMT")

  defp record(req, finch_request) do
    entry = %{request: req, finch_request: finch_request}
    Process.put(@requests, [entry | Process.get(@requests, [])])
  end
end

defmodule GtfsPlanner.FeedPublishing.StorageTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Storage

  @config %Config{
    bucket: "gtfs-planner-loopback",
    endpoint: URI.parse("https://storage.loopback.invalid"),
    region: "us-east-1",
    access_key_id: "loopback-access-key",
    secret_access_key: "loopback-secret-access-key",
    public_base_url: URI.parse("https://feeds.loopback.invalid")
  }

  @identity %{
    claim: "opaque-public-claim",
    channel: "full",
    sequence: 17,
    generation: "unique-public-generation"
  }

  setup do
    HTTPBoundary.reset()
    :ok
  end

  describe "signed, bounded requests" do
    test "a streamed payload is SigV4 signed to the configured endpoint with Content-Length and no redirects or retries" do
      body = "streamed-payload-bytes"
      path = write_temp!(body)
      key = "rivercity/static/objects/unique-public-generation/gtfs.zip"

      assert {:ok, receipt} =
               Storage.put_payload(@config, key, {:file, path}, sha256_hex(body), @identity)

      assert receipt.key == key
      assert receipt.sha256 == sha256_hex(body)
      assert receipt.bytes == byte_size(body)
      assert is_binary(receipt.etag)
      assert is_binary(receipt.last_modified)

      assert [sent] = HTTPBoundary.requests()
      request = sent.request

      assert request.url.scheme == "https"
      assert request.url.host == "storage.loopback.invalid"
      assert request.url.path == "/gtfs-planner-loopback/#{key}"

      sigv4 = request.options[:aws_sigv4]
      assert sigv4[:service] == :s3
      assert sigv4[:region] == "us-east-1"
      assert sigv4[:access_key_id] == "loopback-access-key"

      assert request.options[:redirect] == false
      assert request.options[:retry] == false
      assert request.options[:receive_timeout] == 30_000
      assert request.options[:connect_options][:timeout] == 10_000
      refute get_in(request.options, [:connect_options, :transport_opts, :verify]) == :verify_none

      assert header(request, "content-length") == Integer.to_string(byte_size(body))
      assert header(request, "x-amz-content-sha256") == "UNSIGNED-PAYLOAD"
      assert header(request, "if-none-match") == "*"
      assert {:stream, _stream} = sent.finch_request.body

      authorization = header(request, "authorization")

      assert String.starts_with?(
               authorization,
               "AWS4-HMAC-SHA256 Credential=loopback-access-key/"
             )

      assert authorization =~ "/us-east-1/s3/aws4_request"
      assert authorization =~ "SignedHeaders="
      refute authorization =~ @config.secret_access_key

      refute Enum.any?(request.headers, fn {_name, values} ->
               @config.secret_access_key in values
             end)
    end

    test "a payload sent from memory signs the body and still carries the identity metadata" do
      body = "in-memory-payload"

      assert {:ok, _receipt} =
               Storage.put_payload(
                 @config,
                 "rivercity/realtime/objects/gen/alerts.pb",
                 {:bytes, body},
                 sha256_hex(body),
                 %{
                   @identity
                   | channel: "alerts"
                 }
               )

      request = hd(HTTPBoundary.requests()).request

      assert header(request, "x-amz-content-sha256") == sha256_hex(body)
      assert header(request, "x-amz-meta-publication-channel") == "alerts"
      assert header(request, "x-amz-meta-publication-claim") == @identity.claim
      assert header(request, "x-amz-meta-publication-sequence") == "17"
      assert header(request, "x-amz-meta-publication-generation") == @identity.generation
    end

    test "a redirect response is not followed" do
      HTTPBoundary.script([
        {:response, 302, [{"location", "https://storage.loopback.invalid/other"}], ""}
      ])

      assert {:error, :unavailable} =
               Storage.read_manifest(@config, "rivercity/static/current-gtfs.json")

      assert length(HTTPBoundary.requests()) == 1
    end

    test "a transient write failure is not retried automatically" do
      HTTPBoundary.script([
        {:response, 503, [], "temporarily unavailable"},
        {:response, 200, [], ""}
      ])

      assert {:error, :unavailable} =
               Storage.put_manifest(
                 @config,
                 "rivercity/static/current-gtfs.json",
                 ~s({"schema":1}),
                 :absent
               )

      assert length(HTTPBoundary.requests()) == 1
    end

    test "a transport timeout is unknown, not a definite failure" do
      HTTPBoundary.script([{:transport_error, :timeout}])

      assert {:error, :unknown} =
               Storage.put_manifest(
                 @config,
                 "rivercity/static/current-gtfs.json",
                 ~s({"schema":1}),
                 :absent
               )
    end
  end

  describe "immutable payload conflicts" do
    test "an identical existing object is accepted after size, identity and hash all match" do
      key = "rivercity/static/objects/gen/gtfs.zip"
      body = "identical immutable payload"
      HTTPBoundary.put_object(key, body, metadata: metadata())

      assert {:ok, receipt} =
               Storage.put_payload(@config, key, {:bytes, body}, sha256_hex(body), @identity)

      assert receipt.sha256 == sha256_hex(body)
      assert receipt.bytes == byte_size(body)

      assert length(HTTPBoundary.requests()) == 3
    end

    test "a foreign object at the key is refused and never adopted" do
      key = "rivercity/static/objects/gen/gtfs.zip"

      HTTPBoundary.put_object(key, "someone else's bytes",
        metadata: %{metadata() | "publication-claim" => "foreign"}
      )

      assert {:error, :conflict} =
               Storage.put_payload(
                 @config,
                 key,
                 {:bytes, "identical immutable payload"},
                 sha256_hex("identical immutable payload"),
                 @identity
               )

      assert length(HTTPBoundary.requests()) == 2
    end

    test "a same-size impostor with matching identity metadata is refused by the byte hash" do
      key = "rivercity/static/objects/gen/gtfs.zip"
      body = "identical immutable payload"
      HTTPBoundary.put_object(key, String.duplicate("x", byte_size(body)), metadata: metadata())

      assert {:error, :conflict} =
               Storage.put_payload(@config, key, {:bytes, body}, sha256_hex(body), @identity)

      assert length(HTTPBoundary.requests()) == 3
    end
  end

  describe "manifest reads and conditional writes" do
    test "a missing manifest is missing, and a present one preserves its strong opaque ETag" do
      key = "rivercity/static/current-gtfs.json"
      assert :missing = Storage.read_manifest(@config, key)

      etag = ~s("5d41402abc4b2a76b9719d911017c592")
      last_modified = "Thu, 02 Oct 2026 12:00:00 GMT"
      HTTPBoundary.put_object(key, ~s({"schema":1}), etag: etag, last_modified: last_modified)

      assert {:ok, ~s({"schema":1}), ^etag, ^last_modified} = Storage.read_manifest(@config, key)
    end

    test "a manifest body larger than 64 KiB is refused, not truncated" do
      key = "rivercity/static/current-gtfs.json"
      HTTPBoundary.put_object(key, :binary.copy("a", 64 * 1024 + 1))

      assert {:error, :manifest_too_large} = Storage.read_manifest(@config, key)
    end

    test "first creation uses If-None-Match * and a stale predecessor is refused" do
      key = "rivercity/static/current-gtfs.json"

      assert {:ok, _receipt} = Storage.put_manifest(@config, key, ~s({"schema":1}), :absent)
      assert header(hd(HTTPBoundary.requests()).request, "if-none-match") == "*"

      HTTPBoundary.reset()
      HTTPBoundary.put_object(key, ~s({"schema":1}), etag: ~s("current-etag"))

      assert {:ok, _receipt} =
               Storage.put_manifest(@config, key, ~s({"schema":2}), {:etag, ~s("current-etag")})

      HTTPBoundary.reset()
      HTTPBoundary.put_object(key, ~s({"schema":2}), etag: ~s("newer-etag"))

      assert {:error, :precondition_failed} =
               Storage.put_manifest(@config, key, ~s({"schema":1}), {:etag, ~s("stale-etag")})

      assert header(hd(HTTPBoundary.requests()).request, "if-match") == ~s("stale-etag")
    end
  end

  describe "public diagnostics" do
    test "payload identity metadata is exactly claim, channel, sequence and generation" do
      body = "payload"

      Storage.put_payload(
        @config,
        "rivercity/static/objects/gen/gtfs.zip",
        {:bytes, body},
        sha256_hex(body),
        @identity
      )

      request = hd(HTTPBoundary.requests()).request

      meta =
        request.headers
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, "x-amz-meta-"))
        |> Enum.sort()

      assert meta == [
               "x-amz-meta-publication-channel",
               "x-amz-meta-publication-claim",
               "x-amz-meta-publication-generation",
               "x-amz-meta-publication-sequence"
             ]
    end

    test "errors are bare atoms and no response content or credential leaks" do
      key = "rivercity/static/objects/gen/gtfs.zip"

      HTTPBoundary.put_object(key, "foreign",
        metadata: %{metadata() | "publication-generation" => "other"}
      )

      assert {:error, reason} =
               Storage.put_payload(
                 @config,
                 key,
                 {:bytes, "payload"},
                 sha256_hex("payload"),
                 @identity
               )

      assert reason == :conflict
      assert is_atom(reason)
      refute reason |> inspect() =~ "loopback-secret-access-key"
      refute reason |> inspect() =~ "storage.loopback.invalid"
    end
  end

  defp metadata do
    %{
      "publication-claim" => @identity.claim,
      "publication-channel" => @identity.channel,
      "publication-sequence" => Integer.to_string(@identity.sequence),
      "publication-generation" => @identity.generation
    }
  end

  defp write_temp!(content) do
    path =
      Path.join(System.tmp_dir!(), "feedpub-storage-#{System.unique_integer([:positive])}.bin")

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp header(%Req.Request{headers: headers}, name),
    do: headers |> Map.get(name, []) |> List.first()
end

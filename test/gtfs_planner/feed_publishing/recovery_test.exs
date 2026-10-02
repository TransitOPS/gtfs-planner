defmodule GtfsPlanner.FeedPublishing.RecoveryTest do
  @moduledoc """
  Step 14: frozen, retry-safe manifest publication (AC-18, AC-19, AC-20; CL-4, CL-6).

  Every case calls the production entry point `FeedPublishing.advance/1`, which
  loads the durable attempt and drives `Publisher` against the concrete `Storage`
  boundary. Only the Req final HTTP transport is substituted (the shared
  `HTTPBoundary` loopback); the request building, SigV4 signing, conditional
  headers and the database are real.

  The literal expectations below are the frozen manifest bytes, the predecessor
  condition and the remote receipt. A retry must replay the same bytes and the
  same condition; a stale request must not become current; both payloads must be
  confirmed before the one manifest switches; and a remote success with a lost
  database receipt must be recovered without acknowledging newer content.

  The focused gate command is
  `MIX_TEST_PARTITION=_feedpub mix test test/gtfs_planner/feed_publishing/recovery_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Manifest
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  @task_timeout 15_000

  @config %Config{
    bucket: "gtfs-planner-loopback",
    endpoint: URI.parse("https://storage.loopback.invalid"),
    region: "us-east-1",
    access_key_id: "loopback-access-key",
    secret_access_key: "loopback-secret-access-key",
    public_base_url: URI.parse("https://feeds.loopback.invalid")
  }

  setup do
    HTTPBoundary.reset()
    previous = Application.get_env(:gtfs_planner, :feed_publishing_config)
    Application.put_env(:gtfs_planner, :feed_publishing_config, {:enabled, @config})

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:gtfs_planner, :feed_publishing_config)
        value -> Application.put_env(:gtfs_planner, :feed_publishing_config, value)
      end
    end)

    :ok
  end

  describe "Manifest.encode/1" do
    test "encodes only the public protocol values under the claimed prefix" do
      namespace = %Namespace{prefix: "rivercity", public_claim: "opaque-public-claim"}
      publication = %Publication{channel: :alerts, namespace: namespace}

      attempt = %Attempt{
        publication: publication,
        generation: "generation-1",
        sequence: 4,
        inserted_at: ~U[2026-10-02 12:00:00.000000Z],
        object_receipts: %{
          "pb" => %{
            "key" => "rivercity/realtime/objects/generation-1/alerts.pb",
            "sha256" => String.duplicate("a", 64),
            "bytes" => 3,
            "content_type" => "application/x-protobuf"
          }
        }
      }

      assert {:ok, body} = Manifest.encode(attempt)

      assert %{
               "schema" => 1,
               "namespace" => "rivercity",
               "claim" => "opaque-public-claim",
               "channel" => "alerts",
               "generation" => "generation-1",
               "sequence" => 4,
               "generated_at" => "2026-10-02T12:00:00Z",
               "objects" => %{
                 "pb" => %{
                   "key" => "rivercity/realtime/objects/generation-1/alerts.pb",
                   "content_type" => "application/x-protobuf"
                 }
               }
             } = Jason.decode!(body)

      refute body =~ "organization_id"
      refute body =~ "actor"
    end

    test "a fresh generation yields different bytes even when payload descriptors repeat" do
      namespace = %Namespace{prefix: "rivercity", public_claim: "opaque-public-claim"}
      publication = %Publication{channel: :full, namespace: namespace}

      objects = %{
        "zip" => %{
          "key" => "rivercity/static/objects/shared/gtfs.zip",
          "sha256" => String.duplicate("a", 64),
          "bytes" => 2,
          "content_type" => "application/zip"
        }
      }

      assert {:ok, first} =
               Manifest.encode(%Attempt{
                 publication: publication,
                 generation: "generation-a",
                 sequence: 1,
                 object_receipts: objects,
                 inserted_at: ~U[2026-10-02 12:00:00.000000Z]
               })

      assert {:ok, second} =
               Manifest.encode(%Attempt{
                 publication: publication,
                 generation: "generation-b",
                 sequence: 2,
                 object_receipts: objects,
                 inserted_at: ~U[2026-10-02 12:00:00.000000Z]
               })

      refute first == second
    end

    test "refuses an object key outside the claimed prefix" do
      namespace = %Namespace{prefix: "rivercity", public_claim: "claim"}
      publication = %Publication{channel: :full, namespace: namespace}

      objects = %{
        "zip" => %{
          "key" => "southbank/static/objects/g/gtfs.zip",
          "sha256" => String.duplicate("a", 64),
          "bytes" => 2,
          "content_type" => "application/zip"
        }
      }

      assert {:error, :invalid_objects} =
               Manifest.encode(%Attempt{
                 publication: publication,
                 generation: "generation-a",
                 sequence: 1,
                 object_receipts: objects
               })
    end

    test "refuses an attempt without its publication and namespace" do
      assert {:error, :incomplete} = Manifest.encode(%Attempt{})
    end
  end

  describe "advance/1 recovery" do
    test "death after the sending-state commit replays identical bytes and condition" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :full, desired_revision: 1)

      attempt = attempt_fixture(publication, namespace, state: "switching", sequence: 1)
      publication = activate(publication, attempt)

      assert {:ok, :current} = FeedPublishing.advance(publication.id)

      key = Manifest.key("rivercity", :full)
      assert [sent] = requests_for(:put, key)
      assert sent.request.body == attempt.manifest_body
      assert header(sent.request, "if-none-match") == "*"

      reloaded = Repo.get!(Attempt, attempt.id)
      assert reloaded.state == "current"
      assert reloaded.manifest_body == attempt.manifest_body
      assert reloaded.predecessor_etag == attempt.predecessor_etag

      assert HTTPBoundary.objects()[key].body == attempt.manifest_body

      publication = Repo.get!(Publication, publication.id)
      assert publication.status == :current
      assert publication.manifest_bytes == attempt.manifest_body
      assert publication.manifest_etag == HTTPBoundary.objects()[key].etag
      assert publication.manifest_generation == attempt.generation
    end

    test "a replacement attempt replays the frozen predecessor ETag" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :flex, desired_revision: 1)

      attempt =
        attempt_fixture(publication, namespace,
          state: "switching",
          sequence: 2,
          predecessor_etag: "\"predecessor\""
        )

      publication = activate(publication, attempt)
      key = Manifest.key("rivercity", :flex)
      HTTPBoundary.put_object(key, "predecessor-body", etag: "\"predecessor\"")

      assert {:ok, :current} = FeedPublishing.advance(publication.id)

      assert [sent] = requests_for(:put, key)
      assert header(sent.request, "if-match") == "\"predecessor\""
      assert Repo.get!(Attempt, attempt.id).predecessor_etag == "\"predecessor\""
    end

    test "a delayed predecessor request cannot overwrite a newer unique manifest" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :full, desired_revision: 1)

      stale = attempt_fixture(publication, namespace, state: "switching", sequence: 1)
      publication = activate(publication, stale)

      key = Manifest.key("rivercity", :full)
      newer_body = manifest_body(namespace, :full, sequence: 2, generation: "generation-b")

      HTTPBoundary.put_object(key, newer_body,
        etag: "\"newer\"",
        last_modified: "Thu, 02 Oct 2026 12:00:00 GMT"
      )

      # The stale node still saw an absent predecessor and replayed its own
      # first-create, but the store had already installed the newer manifest.
      HTTPBoundary.script([
        {:response, 404, [], ""},
        {:response, 412, [], ""},
        {:response, 200,
         [{"etag", "\"newer\""}, {"last-modified", "Thu, 02 Oct 2026 12:00:00 GMT"}], newer_body}
      ])

      assert {:ok, :superseded} = FeedPublishing.advance(publication.id)

      assert [sent] = requests_for(:put, key)
      assert header(sent.request, "if-none-match") == "*"

      reloaded = Repo.get!(Attempt, stale.id)
      assert reloaded.state == "superseded"
      assert reloaded.retired_at != nil
      assert reloaded.predecessor_etag == stale.predecessor_etag

      assert HTTPBoundary.objects()[key].body == newer_body
    end
  end

  describe "advance/1 payload gating" do
    test "both alerts payloads are staged before one shared manifest switches" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :alerts, desired_revision: 1)

      {attempt, publication} = alerts_attempt(publication, namespace)

      assert {:ok, :current} = FeedPublishing.advance(publication.id)

      key = Manifest.key("rivercity", :alerts)
      pb_key = "rivercity/realtime/objects/#{attempt.generation}/alerts.pb"
      json_key = "rivercity/realtime/objects/#{attempt.generation}/alerts.json"

      assert [_pb] = requests_for(:put, pb_key)
      assert [_json] = requests_for(:put, json_key)
      assert [sent] = requests_for(:put, key)
      assert sent.request.body == attempt.manifest_body

      order = Enum.map(HTTPBoundary.requests(), & &1.request.url.path)
      manifest_index = index_of(order, "/#{key}")

      assert index_of(order, "/#{pb_key}") < manifest_index
      assert index_of(order, "/#{json_key}") < manifest_index

      manifest = Jason.decode!(sent.request.body)
      assert manifest["objects"]["pb"]["key"] == pb_key
      assert manifest["objects"]["json"]["key"] == json_key
    end

    test "a failed payload staging leaves the prior manifest pair untouched" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :alerts, desired_revision: 1)

      key = Manifest.key("rivercity", :alerts)
      prior = manifest_body(namespace, :alerts, sequence: 1, generation: "prior-generation")

      HTTPBoundary.put_object(key, prior,
        etag: "\"prior\"",
        last_modified: "Thu, 02 Oct 2026 12:00:00 GMT"
      )

      {_attempt, publication} = alerts_attempt(publication, namespace)

      # The first payload upload fails; the shared manifest must not switch.
      HTTPBoundary.script([{:response, 500, [], "unavailable"}])

      assert {:ok, :pending} = FeedPublishing.advance(publication.id)

      assert requests_for(:put, key) == []
      assert HTTPBoundary.objects()[key].body == prior

      publication = Repo.get!(Publication, publication.id)
      assert publication.status == :pending
    end
  end

  describe "advance/1 lease fencing" do
    test "a live lease on another node defers without sending" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :full, desired_revision: 1)

      attempt =
        attempt_fixture(publication, namespace,
          state: "switching",
          sequence: 1,
          lease_token: "other-node",
          lease_expires_at: DateTime.add(DateTime.utc_now(), 60)
        )

      publication = activate(publication, attempt)

      assert {:ok, :pending} = FeedPublishing.advance(publication.id)
      assert HTTPBoundary.requests() == []
    end

    test "an expired lease lets the same frozen attempt proceed" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :full, desired_revision: 1)

      attempt =
        attempt_fixture(publication, namespace,
          state: "switching",
          sequence: 1,
          lease_token: "other-node",
          lease_expires_at: DateTime.add(DateTime.utc_now(), -1)
        )

      publication = activate(publication, attempt)

      assert {:ok, :current} = FeedPublishing.advance(publication.id)
      assert [_sent] = requests_for(:put, Manifest.key("rivercity", :full))
    end

    test "two nodes advancing one attempt issue exactly one manifest write" do
      scope = committed_scope()
      on_exit(fn -> cleanup_committed_scope(scope) end)

      results =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn ->
            HTTPBoundary.reset()

            result =
              Sandbox.unboxed_run(Repo, fn ->
                FeedPublishing.advance(scope.publication_id)
              end)

            {result, HTTPBoundary.requests()}
          end)
        end)
        |> Enum.map(&Task.await(&1, @task_timeout))

      writes =
        results
        |> Enum.flat_map(fn {_result, requests} ->
          Enum.filter(requests, &manifest_write?(&1, scope.manifest_key))
        end)

      assert length(writes) == 1

      assert unboxed(fn -> Repo.get!(Publication, scope.publication_id).status end) == :current
      assert unboxed(fn -> Repo.get!(Attempt, scope.attempt_id).state end) == "current"

      Enum.each(results, fn {result, _requests} ->
        assert match?({:ok, :current}, result) or match?({:ok, :pending}, result)
      end)
    end
  end

  describe "advance/1 receipt recovery" do
    test "a remote success with a lost database receipt is reconciled without resending" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :full, desired_revision: 1)

      attempt = attempt_fixture(publication, namespace, state: "switching", sequence: 1)
      publication = activate(publication, attempt)

      key = Manifest.key("rivercity", :full)

      HTTPBoundary.put_object(key, attempt.manifest_body,
        etag: "\"remote\"",
        last_modified: "Thu, 02 Oct 2026 12:00:00 GMT"
      )

      assert {:ok, :current} = FeedPublishing.advance(publication.id)

      assert requests_for(:put, key) == []

      publication = Repo.get!(Publication, publication.id)
      assert publication.status == :current
      assert publication.manifest_etag == "\"remote\""
      assert publication.manifest_generation == attempt.generation
      assert publication.manifest_last_modified == ~U[2026-10-02 12:00:00.000000Z]
    end

    test "a served remote manifest does not acknowledge newer accepted content" do
      %{publication: publication, namespace: namespace} =
        publication_fixture(channel: :full, desired_revision: 2)

      attempt =
        attempt_fixture(publication, namespace,
          state: "switching",
          sequence: 1,
          desired_revision: 1
        )

      publication = activate(publication, attempt)
      key = Manifest.key("rivercity", :full)

      HTTPBoundary.put_object(key, attempt.manifest_body,
        etag: "\"remote\"",
        last_modified: "Thu, 02 Oct 2026 12:00:00 GMT"
      )

      assert {:ok, :superseded} = FeedPublishing.advance(publication.id)
      assert requests_for(:put, key) == []

      publication = Repo.get!(Publication, publication.id)
      assert publication.status == :pending
      assert publication.manifest_generation == attempt.generation
      assert publication.manifest_etag == "\"remote\""
      assert publication.active_attempt_id == nil
      assert Repo.get!(Attempt, attempt.id).state == "superseded"
    end
  end

  # -- Fixtures and helpers -------------------------------------------------

  defp publication_fixture(opts) do
    organization = organization_fixture()

    namespace =
      Repo.insert!(
        Namespace.claim_changeset(
          organization.id,
          "rivercity",
          Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        )
      )

    publication =
      Repo.insert!(%Publication{
        organization_id: organization.id,
        namespace_id: namespace.id,
        channel: Keyword.get(opts, :channel, :full),
        status: Keyword.get(opts, :status, :pending),
        desired_revision: Keyword.get(opts, :desired_revision, 1)
      })

    %{organization: organization, namespace: namespace, publication: publication}
  end

  defp attempt_fixture(publication, namespace, opts) do
    generation =
      Keyword.get(opts, :generation, "generation-#{System.unique_integer([:positive])}")

    base = %Attempt{
      publication_id: publication.id,
      organization_id: publication.organization_id,
      sequence: Keyword.get(opts, :sequence, 1),
      generation: generation,
      desired_revision: Keyword.get(opts, :desired_revision, publication.desired_revision),
      predecessor_etag: Keyword.get(opts, :predecessor_etag),
      object_receipts: Keyword.get(opts, :object_receipts, %{}),
      private_snapshot: Keyword.get(opts, :private_snapshot),
      state: Keyword.get(opts, :state, "switching"),
      lease_token: Keyword.get(opts, :lease_token),
      lease_expires_at: Keyword.get(opts, :lease_expires_at)
    }

    body =
      Keyword.get_lazy(opts, :manifest_body, fn ->
        attempt = %{base | publication: %{publication | namespace: namespace}}
        {:ok, body} = Manifest.encode(attempt)
        body
      end)

    Repo.insert!(%{base | manifest_body: body, manifest_sha256: sha256_hex(body)})
  end

  defp alerts_attempt(publication, namespace) do
    generation = "generation-#{System.unique_integer([:positive])}"
    pb = "protobuf-bytes"
    json = ~s({"schema":"1"})
    pb_key = "rivercity/realtime/objects/#{generation}/alerts.pb"
    json_key = "rivercity/realtime/objects/#{generation}/alerts.json"

    objects = %{
      "pb" => %{
        "key" => pb_key,
        "sha256" => sha256_hex(pb),
        "bytes" => byte_size(pb),
        "content_type" => "application/x-protobuf"
      },
      "json" => %{
        "key" => json_key,
        "sha256" => sha256_hex(json),
        "bytes" => byte_size(json),
        "content_type" => "application/json"
      }
    }

    private = %{
      "objects" => %{
        "pb" => %{"bytes_base64" => Base.encode64(pb)},
        "json" => %{"bytes_base64" => Base.encode64(json)}
      }
    }

    attempt =
      attempt_fixture(publication, namespace,
        state: "pending",
        sequence: 1,
        generation: generation,
        object_receipts: objects,
        private_snapshot: private
      )

    {attempt, activate(publication, attempt)}
  end

  defp activate(publication, attempt) do
    Repo.update!(Ecto.Changeset.change(publication, active_attempt_id: attempt.id))
  end

  defp manifest_body(namespace, channel, opts) do
    Jason.encode!(%{
      "schema" => 1,
      "namespace" => namespace.prefix,
      "claim" => namespace.public_claim,
      "channel" => Atom.to_string(channel),
      "generation" => Keyword.fetch!(opts, :generation),
      "sequence" => Keyword.fetch!(opts, :sequence),
      "generated_at" => "2026-10-02T12:00:00Z",
      "objects" => %{}
    })
  end

  defp committed_scope do
    unboxed(fn ->
      organization = organization_fixture()
      prefix = "rivercity-race-#{System.unique_integer([:positive])}"

      namespace =
        Repo.insert!(
          Namespace.claim_changeset(
            organization.id,
            prefix,
            Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
          )
        )

      publication =
        Repo.insert!(%Publication{
          organization_id: organization.id,
          namespace_id: namespace.id,
          channel: :full,
          status: :pending,
          desired_revision: 1
        })

      base = %Attempt{
        publication_id: publication.id,
        organization_id: organization.id,
        sequence: 1,
        generation: "generation-race-#{System.unique_integer([:positive])}",
        desired_revision: 1,
        state: "pending"
      }

      {:ok, body} = Manifest.encode(%{base | publication: %{publication | namespace: namespace}})
      attempt = Repo.insert!(%{base | manifest_body: body, manifest_sha256: sha256_hex(body)})

      publication =
        Repo.update!(Ecto.Changeset.change(publication, active_attempt_id: attempt.id))

      %{
        organization_id: organization.id,
        publication_id: publication.id,
        attempt_id: attempt.id,
        manifest_key: Manifest.key(prefix, :full)
      }
    end)
  end

  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      Repo.update_all(
        from(p in Publication, where: p.organization_id == ^scope.organization_id),
        set: [active_attempt_id: nil]
      )

      Repo.delete_all(from(a in Attempt, where: a.organization_id == ^scope.organization_id))
      Repo.delete_all(from(p in Publication, where: p.organization_id == ^scope.organization_id))
      Repo.delete_all(from(n in Namespace, where: n.organization_id == ^scope.organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
    end)
  end

  defp requests_for(method, key) do
    Enum.filter(HTTPBoundary.requests(), fn entry ->
      entry.request.method == method and
        String.ends_with?(entry.request.url.path, "/#{key}")
    end)
  end

  defp manifest_write?(entry, key) do
    entry.request.method == :put and String.ends_with?(entry.request.url.path, "/#{key}")
  end

  defp index_of(paths, suffix) do
    Enum.find_index(paths, &String.ends_with?(&1, suffix))
  end

  defp header(request, name), do: request.headers |> Map.get(name, []) |> List.first()

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end

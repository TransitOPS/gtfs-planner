defmodule GtfsPlanner.FeedPublishing.RetentionTest do
  @moduledoc """
  Step 17: reclaiming safely retired payloads (AC-21; CL-3, CL-4).

  Every case drives the production `FeedPublishing.collect_retired/2` (and, for
  the heartbeat case, `Publisher.tick/1`, which runs the same collection). The
  durable attempts, the retirement watermark, the real `Manifest.encode/1`, the
  real `Storage.list_payloads/4`/`head_payload/2`/`delete_payload/2` boundary and
  the step-13 loopback final HTTP transport all run unchanged; only the clock is
  an explicit argument.

  The focused gate command is
  `MIX_TEST_PARTITION=_feedpub mix test test/gtfs_planner/feed_publishing/retention_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Manifest
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.FeedPublishing.Publisher
  alias GtfsPlanner.FeedPublishing.Storage
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  @now ~U[2026-10-03 12:00:00.000000Z]
  @grace_seconds 24 * 60 * 60

  @config %Config{
    bucket: "gtfs-planner-loopback",
    endpoint: URI.parse("https://storage.loopback.invalid"),
    region: "us-east-1",
    access_key_id: "loopback-access-key",
    secret_access_key: "loopback-secret-access-key",
    public_base_url: URI.parse("https://feeds.loopback.invalid")
  }

  setup do
    previous = Application.get_env(:gtfs_planner, :feed_publishing_config)
    Application.put_env(:gtfs_planner, :feed_publishing_config, {:enabled, @config})
    HTTPBoundary.reset()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:gtfs_planner, :feed_publishing_config)
        value -> Application.put_env(:gtfs_planner, :feed_publishing_config, value)
      end
    end)

    :ok
  end

  test "current and unresolved payloads survive; a retired object is collected only after grace" do
    %{namespace: namespace, publication: publication} = channel_fixture(:full)

    current_key = object_key(namespace, 3)
    retired_key = object_key(namespace, 2)
    unresolved_key = object_key(namespace, 4)

    current =
      attempt_fixture(publication, namespace, sequence: 3, key: current_key, state: "current")

    retired =
      attempt_fixture(publication, namespace,
        sequence: 2,
        key: retired_key,
        state: "superseded",
        retired_at: DateTime.add(@now, -25 * 60 * 60)
      )

    _unresolved =
      attempt_fixture(publication, namespace,
        sequence: 4,
        key: unresolved_key,
        state: "switching"
      )

    seed_manifest(namespace, :full, current_key, "gen-3")
    seed_object(current_key, identity(namespace, :full, 3), @now)
    seed_object(retired_key, identity(namespace, :full, 2), @now)
    seed_object(unresolved_key, identity(namespace, :full, 4), @now)

    publication =
      activate(publication, current, retired_through_sequence: 1, next_sequence: 5)

    # Two hours before the grace elapses nothing is eligible.
    assert {:ok, 0} = FeedPublishing.collect_retired(DateTime.add(@now, -2 * 60 * 60))
    assert object_exists?(retired_key)

    # Past the grace only the retired generation is removed.
    assert {:ok, 1} = FeedPublishing.collect_retired(@now)

    refute object_exists?(retired_key)
    assert object_exists?(current_key)
    assert object_exists?(unresolved_key)

    refute Repo.get(Attempt, retired.id)
    assert Repo.get(Attempt, current.id)
    assert Repo.get!(Publication, publication.id).retired_through_sequence == 2
  end

  test "a late upload after retirement cannot become current and is collected as an orphan" do
    %{namespace: namespace, publication: publication} = channel_fixture(:full)

    current_key = object_key(namespace, 3)
    orphan_key = object_key(namespace, 2)
    other_namespace_key = "southbank/static/objects/gen-1/gtfs.zip"
    asset_key = "images/logo.png"

    current =
      attempt_fixture(publication, namespace, sequence: 3, key: current_key, state: "current")

    seed_manifest(namespace, :full, current_key, "gen-3")
    seed_object(current_key, identity(namespace, :full, 3), @now)

    seed_object(
      other_namespace_key,
      %{claim: "other", channel: "full", sequence: 1, generation: "gen-1"},
      @now
    )

    seed_object(
      asset_key,
      %{claim: "website", channel: "images", sequence: 1, generation: "gen-1"},
      @now
    )

    _publication = activate(publication, current, retired_through_sequence: 2, next_sequence: 4)

    # A delayed PUT recreates the retired generation's key with matching identity
    # metadata and an old observation instant.
    seed_object(
      orphan_key,
      identity(namespace, :full, 2),
      DateTime.add(@now, -(@grace_seconds + 60 * 60))
    )

    # The served manifest still names the current generation, so the late upload
    # never becomes current.
    served = HTTPBoundary.objects()[Manifest.key(namespace.prefix, :full)].body
    assert served =~ "gen-3"
    refute served =~ orphan_key

    assert {:ok, 1} = FeedPublishing.collect_retired(@now)

    refute object_exists?(orphan_key)
    assert object_exists?(current_key)
    assert object_exists?(other_namespace_key)
    assert object_exists?(asset_key)
  end

  test "disabled collection makes no requests and preserves records" do
    Application.put_env(:gtfs_planner, :feed_publishing_config, :disabled)

    %{namespace: namespace, publication: publication} = channel_fixture(:full)
    retired_key = object_key(namespace, 1)

    retired =
      attempt_fixture(publication, namespace,
        sequence: 1,
        key: retired_key,
        state: "superseded",
        retired_at: DateTime.add(@now, -25 * 60 * 60)
      )

    seed_manifest(namespace, :full, object_key(namespace, 2), "gen-2")
    seed_object(retired_key, identity(namespace, :full, 1), @now)

    assert {:ok, 0} = FeedPublishing.collect_retired(@now)
    assert HTTPBoundary.requests() == []

    assert object_exists?(retired_key)
    assert Repo.get(Attempt, retired.id)
  end

  test "repeated heartbeats prune retired attempts, advance the watermark and keep bounded history" do
    %{namespace: namespace, publication: publication} = channel_fixture(:full)

    current_key = object_key(namespace, 6)

    current =
      attempt_fixture(publication, namespace, sequence: 6, key: current_key, state: "current")

    seed_manifest(namespace, :full, current_key, "gen-6")
    seed_object(current_key, identity(namespace, :full, 6), @now)

    for sequence <- 1..5 do
      key = object_key(namespace, sequence)

      attempt_fixture(publication, namespace,
        sequence: sequence,
        key: key,
        state: "superseded",
        retired_at: DateTime.add(@now, -(@grace_seconds + 60 * 60))
      )

      seed_object(key, identity(namespace, :full, sequence), @now)
    end

    publication = activate(publication, current, retired_through_sequence: 0, next_sequence: 7)

    retired = for _heartbeat <- 1..3, do: Publisher.tick(@now).retired

    assert Enum.sum(retired) == 5
    assert attempts_count(publication) == 1
    assert Repo.get!(Publication, publication.id).retired_through_sequence == 5

    # A further heartbeat finds nothing, so history does not keep growing.
    assert Publisher.tick(@now).retired == 0
    assert attempts_count(publication) == 1
  end

  test "an unavailable provider deletes nothing and keeps every record" do
    %{namespace: namespace, publication: publication} = channel_fixture(:full)

    current_key = object_key(namespace, 2)
    retired_key = object_key(namespace, 1)

    current =
      attempt_fixture(publication, namespace, sequence: 2, key: current_key, state: "current")

    retired =
      attempt_fixture(publication, namespace,
        sequence: 1,
        key: retired_key,
        state: "superseded",
        retired_at: DateTime.add(@now, -(@grace_seconds + 60 * 60))
      )

    body = manifest_body(namespace, :full, current_key, "gen-2")
    seed_object(current_key, identity(namespace, :full, 2), @now)
    seed_object(retired_key, identity(namespace, :full, 1), @now)
    publication = activate(publication, current, retired_through_sequence: 0, next_sequence: 3)

    # The manifest reads back, then the DELETE times out: nothing may be pruned.
    HTTPBoundary.script([
      {:response, 200, [{"etag", ~s("m")}, {"last-modified", "Thu, 02 Oct 2026 12:00:00 GMT"}],
       body},
      {:transport_error, :timeout}
    ])

    assert {:ok, 0} = FeedPublishing.collect_retired(@now)

    assert Repo.get(Attempt, retired.id)
    assert object_exists?(retired_key)
    assert Repo.get!(Publication, publication.id).retired_through_sequence == 0
  end

  test "a manifest or website asset is refused, and conflicting object metadata is left alone" do
    %{namespace: namespace, publication: publication} = channel_fixture(:full)

    current_key = object_key(namespace, 2)
    foreign_key = object_key(namespace, 1)

    current =
      attempt_fixture(publication, namespace, sequence: 2, key: current_key, state: "current")

    seed_manifest(namespace, :full, current_key, "gen-2")
    seed_object(current_key, identity(namespace, :full, 2), @now)

    # Only a server-owned retired payload key is ever deletable.
    assert {:error, :refused} =
             Storage.delete_payload(@config, Manifest.key(namespace.prefix, :full))

    assert {:error, :refused} = Storage.delete_payload(@config, "images/logo.png")
    assert {:error, :refused} = Storage.delete_payload(@config, namespace.prefix)

    # A listed object whose identity metadata conflicts with this channel is not
    # collected, and the manifest is never deleted.
    seed_object(
      foreign_key,
      %{claim: "someone-else", channel: "full", sequence: 1, generation: "gen-1"},
      DateTime.add(@now, -(@grace_seconds + 60 * 60))
    )

    _publication = activate(publication, current, retired_through_sequence: 1, next_sequence: 3)

    assert {:ok, 0} = FeedPublishing.collect_retired(@now)

    assert object_exists?(foreign_key)
    assert object_exists?(Manifest.key(namespace.prefix, :full))
  end

  # -- Fixtures and helpers -------------------------------------------------

  defp channel_fixture(channel) do
    organization = organization_fixture()
    {:ok, namespace} = FeedPublishing.ensure_namespace_for(organization.id)

    publication =
      Repo.insert!(%Publication{
        organization_id: organization.id,
        namespace_id: namespace.id,
        channel: channel,
        status: :pending,
        desired_revision: 1,
        next_sequence: 1
      })

    %{organization: organization, namespace: namespace, publication: publication}
  end

  defp attempt_fixture(publication, namespace, opts) do
    sequence = Keyword.fetch!(opts, :sequence)
    key = Keyword.fetch!(opts, :key)
    generation = Keyword.get(opts, :generation, "gen-#{sequence}")
    bytes = "bytes-#{generation}"

    base = %Attempt{
      publication_id: publication.id,
      organization_id: publication.organization_id,
      sequence: sequence,
      generation: generation,
      desired_revision: 1,
      object_receipts: %{
        "zip" => %{
          "key" => key,
          "sha256" => sha256_hex(bytes),
          "bytes" => byte_size(bytes),
          "content_type" => "application/zip"
        }
      },
      state: Keyword.get(opts, :state, "superseded"),
      retired_at: Keyword.get(opts, :retired_at)
    }

    {:ok, body} = Manifest.encode(%{base | publication: %{publication | namespace: namespace}})
    Repo.insert!(%{base | manifest_body: body, manifest_sha256: sha256_hex(body)})
  end

  defp activate(publication, attempt, opts) do
    Repo.update!(
      Ecto.Changeset.change(publication, %{
        active_attempt_id: attempt.id,
        retired_through_sequence: Keyword.get(opts, :retired_through_sequence, 0),
        next_sequence: Keyword.get(opts, :next_sequence, attempt.sequence + 1)
      })
    )
  end

  defp object_key(namespace, sequence),
    do: "#{namespace.prefix}/static/objects/gen-#{sequence}/gtfs.zip"

  defp identity(namespace, channel, sequence) do
    %{
      claim: namespace.public_claim,
      channel: Atom.to_string(channel),
      sequence: sequence,
      generation: "gen-#{sequence}"
    }
  end

  defp seed_object(key, identity, %DateTime{} = observed_at) do
    HTTPBoundary.put_object(key, "payload-#{key}",
      metadata: %{
        "publication-claim" => identity.claim,
        "publication-channel" => identity.channel,
        "publication-sequence" => Integer.to_string(identity.sequence),
        "publication-generation" => identity.generation
      },
      last_modified: http_date(observed_at)
    )
  end

  defp seed_manifest(namespace, channel, key, generation) do
    body = manifest_body(namespace, channel, key, generation)

    HTTPBoundary.put_object(Manifest.key(namespace.prefix, channel), body,
      etag: ~s("manifest"),
      last_modified: "Thu, 02 Oct 2026 12:00:00 GMT"
    )

    body
  end

  defp manifest_body(namespace, channel, key, generation) do
    Jason.encode!(%{
      "schema" => 1,
      "namespace" => namespace.prefix,
      "claim" => namespace.public_claim,
      "channel" => Atom.to_string(channel),
      "generation" => generation,
      "sequence" => 1,
      "generated_at" => "2026-10-02T12:00:00Z",
      "objects" => %{
        "zip" => %{
          "key" => key,
          "sha256" => String.duplicate("a", 64),
          "bytes" => 3,
          "content_type" => "application/zip"
        }
      }
    })
  end

  defp object_exists?(key), do: Map.has_key?(HTTPBoundary.objects(), key)

  defp attempts_count(publication) do
    Repo.aggregate(from(a in Attempt, where: a.publication_id == ^publication.id), :count)
  end

  defp http_date(%DateTime{} = at), do: Calendar.strftime(at, "%a, %d %b %Y %H:%M:%S GMT")

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end

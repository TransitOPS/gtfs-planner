defmodule GtfsPlanner.FeedPublishing.PublisherTest do
  @moduledoc """
  Step 16: supervised refresh and delivery (AC-1, AC-13, AC-16, AC-17, AC-20;
  CL-1, CL-4, CL-6, CL-7).

  Every case drives the production `GtfsPlanner.FeedPublishing.Publisher`
  through `tick/1` or through `GtfsPlanner.Application`'s own supervision. The
  durable `FeedPublishing` rows, the attempt lease, the real `Manifest.encode/1`
  and the real `Alerts.Feed.encode/2` all run unchanged; only the final HTTP
  transport (the step-13 loopback) and the clock (an explicit `tick/1` argument)
  are substituted.

  The focused gate command is
  `MIX_TEST_PARTITION=_feedpub mix test test/gtfs_planner/feed_publishing/publisher_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Feed, as: AlertsFeed
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.Publication, as: AlertPublication
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Manifest
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.FeedPublishing.Publisher
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @moduletag timeout: 120_000

  @static_tasks GtfsPlanner.FeedPublishing.Publisher.StaticTasks

  @t0 ~U[2026-10-02 12:00:00.000000Z]

  @config %Config{
    bucket: "gtfs-planner-loopback",
    endpoint: URI.parse("https://storage.loopback.invalid"),
    region: "us-east-1",
    access_key_id: "loopback-access-key",
    secret_access_key: "loopback-secret-access-key",
    public_base_url: URI.parse("https://feeds.loopback.invalid")
  }

  setup do
    root = Path.join(System.tmp_dir!(), "publisher-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    artifacts = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    config = Application.get_env(:gtfs_planner, :feed_publishing_config)
    settings = Application.get_env(:gtfs_planner, :feed_publishing_settings)

    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)
    Application.put_env(:gtfs_planner, :feed_publishing_config, {:enabled, @config})
    HTTPBoundary.reset()

    on_exit(fn ->
      restore_env(:gtfs_task_artifacts_path, artifacts)
      restore_env(:feed_publishing_config, config)
      restore_env(:feed_publishing_settings, settings)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  describe "ordinary startup" do
    test "the application supervises the publisher and it discovers queued work" do
      organization = organization_fixture()
      {publication, _attempt} = queued_static(organization)

      assert Publisher in GtfsPlanner.Application.feed_publishing_children()

      start_supervised!({Publisher, interval_ms: 30_000})
      assert :ok = Publisher.await_idle()

      channel = Repo.get!(Publication, publication.id)
      assert channel.status == :current
      assert is_binary(channel.manifest_etag)
      assert match?(%DateTime{}, channel.manifest_last_modified)
    end

    test "a disabled installation starts no worker and sends no HTTP" do
      Application.put_env(:gtfs_planner, :feed_publishing_config, :disabled)

      organization = organization_fixture()
      {publication, attempt} = queued_static(organization)

      assert GtfsPlanner.Application.feed_publishing_children() == []
      assert Publisher.tick(@t0) == :disabled

      assert HTTPBoundary.requests() == []
      assert Repo.get!(Attempt, attempt.id).state == "pending"
      assert Repo.get!(Publication, publication.id).status == :pending
    end
  end

  describe "realtime refresh" do
    test "a 30-second tick refreshes the feed with a new generation and keeps dates fixed" do
      organization = organization_fixture()
      accepted = accepted_alert(organization, notice_at: unix(@t0) - 100)

      assert %{realtime: 1} = Publisher.tick(@t0)

      channel = alerts_channel(organization)
      assert channel.status == :current
      first = Repo.get!(Attempt, channel.active_attempt_id)
      assert channel.manifest_generation == first.generation
      assert channel.manifest_bytes == first.manifest_body

      before = Repo.get!(AlertPublication, accepted.id)

      at = DateTime.add(@t0, 30, :second)
      assert %{realtime: 1} = Publisher.tick(at)

      channel = Repo.get!(Publication, channel.id)
      second = Repo.get!(Attempt, channel.active_attempt_id)

      refute second.id == first.id
      refute second.generation == first.generation
      assert channel.manifest_generation == second.generation
      assert Repo.get!(Attempt, first.id).state == "superseded"
      assert Repo.get!(Attempt, first.id).retired_at != nil

      # The payload is exactly what the encoder produces at the tick's clock.
      assert {:ok, %{pb: pb}} = AlertsFeed.encode([stored_snapshot(accepted)], unix(at))
      assert second.private_snapshot["objects"]["pb"]["bytes_base64"] == Base.encode64(pb)

      after_state = Repo.get!(AlertPublication, accepted.id)
      assert after_state.last_published_at == before.last_published_at
      assert after_state.confirmed_revision == before.confirmed_revision
      assert after_state.confirmed_snapshot == before.confirmed_snapshot
    end

    test "notice and expiry eligibility follow the tick's clock" do
      organization = organization_fixture()
      notice_at = unix(@t0) + 3_600

      accepted =
        accepted_alert(organization,
          notice_at: notice_at,
          start: notice_at,
          end: notice_at + 7_200
        )

      entity_id = entity_id(accepted)

      # Before notice the feed is valid and empty.
      assert %{realtime: 1} = Publisher.tick(@t0)
      assert entity_ids(active_attempt(organization, :alerts)) == []

      # Past notice the same accepted snapshot becomes one entity.
      at = DateTime.add(@t0, 7_200, :second)
      assert %{realtime: 1} = Publisher.tick(at)
      assert entity_ids(active_attempt(organization, :alerts)) == [entity_id]

      # Once every period has ended the entity is dropped again.
      ended = DateTime.add(at, 7_200, :second)
      assert %{realtime: 1} = Publisher.tick(ended)
      assert entity_ids(active_attempt(organization, :alerts)) == []
    end
  end

  describe "frozen intent and capacity" do
    test "a tick resumes the exact frozen intent after an uncertain send" do
      organization = organization_fixture()
      {publication, attempt} = queued_static(organization, state: "switching")

      assert %{static: []} = Publisher.tick(@t0)

      key = Manifest.key(prefix(publication), :full)
      assert [sent] = Enum.filter(HTTPBoundary.requests(), &manifest_put?(&1, key))
      assert sent.finch_request.body == attempt.manifest_body

      reloaded = Repo.get!(Attempt, attempt.id)
      assert reloaded.manifest_body == attempt.manifest_body
      assert reloaded.predecessor_etag == attempt.predecessor_etag
      assert reloaded.state == "current"
      assert Repo.get!(Publication, publication.id).status == :current
    end

    test "a saturated static pool defers static work while the realtime refresh completes" do
      organization = organization_fixture()
      {_static_publication, _static_attempt} = queued_static(organization)
      accepted_alert(organization, notice_at: unix(@t0) - 100)

      start_supervised!({Publisher, interval_ms: 30_000})
      assert :ok = Publisher.await_idle()

      first_generation = alerts_channel(organization).manifest_generation

      # Occupy the only static slot so the pool is at capacity.
      {:ok, blocker} =
        Task.Supervisor.start_child(@static_tasks, fn ->
          receive do
            :release -> :ok
          end
        end)

      on_exit(fn -> send(blocker, :release) end)

      # A new static generation is queued while the alerts channel still refreshes.
      {pending_publication, pending_attempt} =
        queue_attempt(organization, :pathways, prefix(organization))

      at = DateTime.add(@t0, 30, :second)
      assert %{realtime: 1, static: []} = Publisher.tick(at)

      channel = alerts_channel(organization)
      refute channel.manifest_generation == first_generation

      # The static item was refused at capacity and deferred, not dropped.
      assert Repo.get!(Attempt, pending_attempt.id).state == "pending"
      assert Repo.get!(Publication, pending_publication.id).status == :pending

      send(blocker, :release)
      await_down(blocker)

      assert %{static: [pid]} = Publisher.tick(DateTime.add(at, 30, :second))
      await_down(pid)

      assert Repo.get!(Publication, pending_publication.id).status == :current
    end
  end

  describe "re-enable and removals" do
    test "a re-enabled tick reconciles the served manifest before composing" do
      organization = organization_fixture()
      accepted_alert(organization, notice_at: unix(@t0) - 100)

      {:ok, namespace} = FeedPublishing.ensure_namespace_for(organization.id)

      stale =
        Repo.insert!(%Publication{
          organization_id: organization.id,
          namespace_id: namespace.id,
          channel: :alerts,
          status: :current,
          desired_revision: 1,
          next_sequence: 2,
          manifest_bytes: "stale-local-body",
          manifest_sha256: sha256_hex("stale-local-body"),
          manifest_etag: ~s("stale"),
          manifest_generation: "stale-generation",
          manifest_sequence: 1
        })

      remote =
        Jason.encode!(%{
          "schema" => 1,
          "namespace" => namespace.prefix,
          "claim" => namespace.public_claim,
          "channel" => "alerts",
          "generation" => "remote-generation",
          "sequence" => 7,
          "generated_at" => "2026-10-02T11:59:00Z",
          "objects" => %{}
        })

      key = Manifest.key(namespace.prefix, :alerts)

      HTTPBoundary.put_object(key, remote,
        etag: ~s("remote"),
        last_modified: "Thu, 02 Oct 2026 12:00:00 GMT"
      )

      assert %{realtime: 1} = Publisher.tick(@t0)

      # The provider's manifest replaced the stale local receipt and became the
      # condition the new attempt was frozen against.
      channel = Repo.get!(Publication, stale.id)
      assert channel.status == :current
      assert match?(%DateTime{}, channel.manifest_last_modified)

      attempt = Repo.get!(Attempt, channel.active_attempt_id)
      assert attempt.predecessor_etag == ~s("remote")
      assert channel.manifest_generation == attempt.generation

      [sent] = Enum.filter(HTTPBoundary.requests(), &manifest_put?(&1, key))
      assert request_header(sent.request, "if-match") == ~s("remote")
    end

    test "a retained removal is excluded from the feed and never resurrected" do
      organization = organization_fixture()
      kept = accepted_alert(organization, notice_at: unix(@t0) - 100, header: "Kept")
      removed = accepted_alert(organization, notice_at: unix(@t0) - 100, withdrawal: :pending)

      assert %{realtime: 1} = Publisher.tick(@t0)

      attempt = active_attempt(organization, :alerts)
      ids = entity_ids(attempt)
      assert entity_id(kept) in ids
      refute entity_id(removed) in ids

      # A later tick after a re-enable still leaves the removal out.
      assert %{realtime: 1} = Publisher.tick(DateTime.add(@t0, 30, :second))
      ids = entity_ids(active_attempt(organization, :alerts))
      assert entity_id(kept) in ids
      refute entity_id(removed) in ids
    end
  end

  # -- Fixtures and helpers -------------------------------------------------

  defp queued_static(organization, opts \\ []) do
    channel = Keyword.get(opts, :channel, :full)
    {:ok, namespace} = FeedPublishing.ensure_namespace_for(organization.id)

    generation = "generation-#{System.unique_integer([:positive])}"
    bytes = "zip-#{generation}"
    path = write_temp!(bytes)
    key = "#{namespace.prefix}/static/objects/#{generation}/gtfs.zip"

    objects = %{
      "zip" => %{
        "key" => key,
        "sha256" => sha256_hex(bytes),
        "bytes" => byte_size(bytes),
        "content_type" => "application/zip"
      }
    }

    private = %{"objects" => %{"zip" => %{"file" => path}}}

    publication =
      Repo.insert!(%Publication{
        organization_id: organization.id,
        namespace_id: namespace.id,
        channel: channel,
        status: :pending,
        desired_revision: 1,
        next_sequence: 2
      })

    attempt =
      insert_attempt(publication, namespace,
        sequence: 1,
        generation: generation,
        desired_revision: 1,
        objects: objects,
        private: private,
        state: Keyword.get(opts, :state, "pending")
      )

    publication = Repo.update!(Ecto.Changeset.change(publication, active_attempt_id: attempt.id))
    {publication, attempt}
  end

  defp queue_attempt(organization, channel, prefix) do
    {:ok, namespace} = FeedPublishing.ensure_namespace_for(organization.id)
    generation = "generation-#{System.unique_integer([:positive])}"
    bytes = "zip-#{generation}"
    path = write_temp!(bytes)
    key = "#{prefix}/static/objects/#{generation}/pathways.zip"

    objects = %{
      "zip" => %{
        "key" => key,
        "sha256" => sha256_hex(bytes),
        "bytes" => byte_size(bytes),
        "content_type" => "application/zip"
      }
    }

    publication =
      Repo.insert!(%Publication{
        organization_id: organization.id,
        namespace_id: namespace.id,
        channel: channel,
        status: :pending,
        desired_revision: 1,
        next_sequence: 2
      })

    attempt =
      insert_attempt(publication, namespace,
        sequence: 1,
        generation: generation,
        desired_revision: 1,
        objects: objects,
        private: %{"objects" => %{"zip" => %{"file" => path}}},
        state: "pending"
      )

    publication = Repo.update!(Ecto.Changeset.change(publication, active_attempt_id: attempt.id))
    {publication, attempt}
  end

  defp insert_attempt(publication, namespace, opts) do
    base = %Attempt{
      publication_id: publication.id,
      organization_id: publication.organization_id,
      sequence: Keyword.fetch!(opts, :sequence),
      generation: Keyword.fetch!(opts, :generation),
      desired_revision: Keyword.get(opts, :desired_revision, publication.desired_revision),
      predecessor_etag: Keyword.get(opts, :predecessor),
      object_receipts: Keyword.get(opts, :objects, %{}),
      private_snapshot: Keyword.get(opts, :private),
      state: Keyword.get(opts, :state, "pending")
    }

    {:ok, body} = Manifest.encode(%{base | publication: %{publication | namespace: namespace}})
    Repo.insert!(%{base | manifest_body: body, manifest_sha256: sha256_hex(body)})
  end

  defp accepted_alert(organization, attrs) do
    alert =
      Repo.insert!(%Alert{
        organization_id: organization.id,
        public_entity_id: Ecto.UUID.generate(),
        revision: 1,
        scope: %ScopeAnswer{},
        timing: %TimingAnswer{},
        message: %MessageAnswer{}
      })

    notice_at = Keyword.get(attrs, :notice_at, 1_700_000_000)

    Repo.insert!(%AlertPublication{
      organization_id: organization.id,
      alert_id: alert.id,
      desired_revision: 1,
      desired_snapshot: %{
        "public_entity_id" => alert.public_entity_id,
        "accepted_revision" => 1,
        "notice_at" => notice_at,
        "periods" => [
          %{"start" => Keyword.get(attrs, :start, notice_at), "end" => Keyword.get(attrs, :end)}
        ],
        "effect" => "detour",
        "cause" => "construction",
        "header" => Keyword.get(attrs, :header, "Alert"),
        "scope" => %{
          "shape" => "routes",
          "agencies" => [],
          "routes" => Keyword.get(attrs, :routes, ["R1"]),
          "stops" => [],
          "route_stops" => [],
          "trips" => []
        }
      },
      withdrawal: Keyword.get(attrs, :withdrawal, :none)
    })
  end

  defp stored_snapshot(%AlertPublication{desired_snapshot: snapshot}),
    do: AlertPublication.snapshot_from_stored(snapshot)

  defp alerts_channel(organization) do
    Repo.get_by!(Publication, organization_id: organization.id, channel: :alerts)
  end

  defp active_attempt(organization, channel) do
    channel = Repo.get_by!(Publication, organization_id: organization.id, channel: channel)
    Repo.get!(Attempt, channel.active_attempt_id)
  end

  defp entity_id(%AlertPublication{desired_snapshot: snapshot}), do: snapshot["public_entity_id"]

  defp entity_ids(attempt) do
    pb = Base.decode64!(attempt.private_snapshot["objects"]["pb"]["bytes_base64"])

    pb
    |> Protobuf.decode(TransitRealtime.FeedMessage)
    |> Map.get(:entity)
    |> Kernel.||([])
    |> Enum.map(& &1.id)
  end

  defp prefix(%Publication{namespace_id: namespace_id}) do
    Repo.get!(GtfsPlanner.FeedPublishing.Namespace, namespace_id).prefix
  end

  defp prefix(%Organization{id: id}) do
    Repo.get_by!(GtfsPlanner.FeedPublishing.Namespace, organization_id: id).prefix
  end

  defp manifest_put?(entry, key) do
    entry.request.method == :put and String.ends_with?(entry.request.url.path, "/#{key}")
  end

  defp request_header(request, name), do: request.headers |> Map.get(name, []) |> List.first()

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      10_000 -> flunk("task #{inspect(pid)} did not finish")
    end
  end

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)

  defp write_temp!(bytes) do
    path = Path.join(System.tmp_dir!(), "publisher-payload-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp sha256_hex(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end

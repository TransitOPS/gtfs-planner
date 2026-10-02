defmodule GtfsPlanner.FeedPublishing.StaticPublicationTest do
  @moduledoc """
  Step 15: reviewed static publication consent (AC-3–AC-7; CL-2, CL-3, CL-8).

  Every case calls the production commands `FeedPublishing.preview_static/3` and
  `FeedPublishing.publish_static/4`. They run the real `ExportRuns` pin owner, the
  real `StaticArtifact.inspect/1` catalog reader, the real
  `Validations.start_artifact_run/3` runner (through the existing fake-CLI
  substitute) and the real `Authorization` membership check. Object storage is
  never contacted by preview or publish; the one case that completes a public
  manifest uses the step-13 loopback HTTP transport.

  The focused gate command is
  `MIX_TEST_PARTITION=_feedpub mix test test/gtfs_planner/feed_publishing/static_publication_test.exs`.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.MessageAnswer
  alias GtfsPlanner.Alerts.Publication, as: AlertPublication
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.TimingAnswer
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Namespace
  alias GtfsPlanner.FeedPublishing.Publication
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.PublicationPin
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.RunnerSlots
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @moduletag timeout: 120_000

  @echo_scope %{
    "shape" => "routes",
    "agencies" => [],
    "routes" => ["R99"],
    "stops" => [],
    "route_stops" => [],
    "trips" => []
  }

  @fake_java Path.expand("../../support/fixtures/fake_validator.sh", __DIR__)

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  @config %Config{
    bucket: "gtfs-planner-loopback",
    endpoint: URI.parse("https://storage.loopback.invalid"),
    region: "us-east-1",
    access_key_id: "loopback-access-key",
    secret_access_key: "loopback-secret-access-key",
    public_base_url: URI.parse("https://feeds.loopback.invalid")
  }

  @full_members [
    {"agency.txt",
     "agency_id,agency_name,agency_url,agency_timezone\n" <>
       "MTA,Metro Transit,https://metro.example,America/New_York\n"},
    {"routes.txt",
     "route_id,agency_id,route_short_name,route_type\n" <> "R1,MTA,One,3\nR2,MTA,Two,1\n"},
    {"trips.txt", "trip_id,route_id,service_id\nT1,R1,S1\nT2,R2,S2\n"},
    {"stops.txt", "stop_id,stop_name\nA1,Alpha\nB1,Bravo\n"},
    {"stop_times.txt",
     "trip_id,arrival_time,departure_time,stop_id\n" <>
       "T1,06:00:00,06:00:00,A1\nT1,06:10:00,06:10:00,B1\nT2,07:00:00,07:00:00,A1\n"},
    {"route_patterns.txt", "route_pattern_id,route_id\nRP1,R1\n"},
    {"stop-area.png", "not-really-a-png"}
  ]

  setup do
    root = Path.join(System.tmp_dir!(), "static-pub-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    old_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    old_config = Application.get_env(:gtfs_planner, :feed_publishing_config)
    Application.put_env(:gtfs_planner, :feed_publishing_config, {:enabled, @config})
    HTTPBoundary.reset()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    editor = editor_fixture(organization)

    on_exit(fn ->
      RunnerSlots.await_idle()
      File.rm_rf(root)

      restore_env(:gtfs_task_artifacts_path, old_root)
      restore_env(:feed_publishing_config, old_config)
    end)

    %{
      root: root,
      organization: organization,
      version: version,
      editor: editor,
      scope: %{organization_id: organization.id, actor_id: editor.id}
    }
  end

  describe "preview_static/3" do
    test "starts a hash-bound validation, reports it pending, then returns a ready preview",
         context do
      use_fake_validator("report")

      run = ready_run(context, [])

      assert {:pending, review_id} = FeedPublishing.preview_static(context.scope, run.id, :main)
      assert await_terminal(review_id, :validation_completed)

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)

      assert preview.profile == :static
      assert preview.channel == :full
      assert preview.slot == :main
      assert preview.artifact_sha256 == run.artifact_sha256
      assert preview.report_id == review_id
      assert preview.errors_count == 0
      assert preview.destination_revision == 0
      namespace = Repo.get_by!(Namespace, organization_id: context.organization.id)

      assert preview.destination_url ==
               "https://feeds.loopback.invalid/#{namespace.prefix}/static/gtfs.zip"

      assert "route_patterns.txt" in preview.inventory
      assert "stop-area.png" in preview.inventory
      assert is_binary(preview.inventory_digest)
      assert preview.notices == []
      assert is_binary(preview.token)
    end

    test "an operations run is never offered as publishable bytes", context do
      run =
        ready_run(
          context,
          [
            {"vehicles.txt", "vehicle_id\nV1\n"}
          ],
          export_type: :operations
        )

      _review = seed_review(run, :main, [])

      assert {:error, :operations_profile_not_publishable} =
               FeedPublishing.preview_static(context.scope, run.id, :main)
    end

    test "refuses a run the organization does not own", context do
      other = organization_fixture(%{alias: "southbank"})
      run = ready_run(%{organization: other, version: gtfs_version_fixture(other.id)}, [])

      assert {:error, :not_found} = FeedPublishing.preview_static(context.scope, run.id, :main)
    end
  end

  describe "publish_static/4" do
    test "queues a frozen attempt bound to the reviewed artifact hash", context do
      run = ready_run(context, [])
      review = seed_review(run, :main, [])

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)
      assert {:ok, publication_id} = publish(context, preview)

      channel = Repo.get!(Publication, publication_id)
      assert channel.channel == :full
      assert channel.organization_id == context.organization.id
      assert channel.status == :pending
      assert channel.desired_revision == 1
      assert channel.next_sequence == 2

      attempt = Repo.get!(Attempt, channel.active_attempt_id)
      assert attempt.state == "pending"
      assert attempt.desired_revision == 1
      assert attempt.predecessor_etag == nil
      assert attempt.object_receipts["zip"]["sha256"] == run.artifact_sha256
      assert attempt.object_receipts["zip"]["bytes"] == run.artifact_size_bytes
      assert attempt.object_receipts["zip"]["content_type"] == "application/zip"
      assert attempt.manifest_body =~ ~s("channel":"full")
      assert attempt.manifest_body =~ run.artifact_sha256
      assert attempt.private_snapshot["review"]["report_id"] == review.id
      assert File.exists?(attempt.private_snapshot["objects"]["zip"]["file"])

      # The reviewed bytes stay leased for the publisher that will upload them.
      pin = Repo.one!(from p in PublicationPin, where: p.export_run_id == ^run.id)
      assert pin.owner_id == "static-publish:#{review.id}"
    end

    test "a completed report with errors needs the explicit count confirmation", context do
      run = ready_run(context, [])
      _review = seed_review(run, :main, errors_count: 2, warnings_count: 1)

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)
      assert preview.errors_count == 2
      assert preview.warnings_count == 1

      assert {:error, {:errors_require_confirmation, 2}} =
               FeedPublishing.publish_static(
                 context.scope,
                 preview.token,
                 preview.destination_revision
               )

      assert Repo.get_by(Publication, organization_id: context.organization.id, channel: :full) ==
               nil

      assert {:ok, _publication_id} =
               FeedPublishing.publish_static(
                 context.scope,
                 preview.token,
                 preview.destination_revision,
                 confirm_errors?: true
               )
    end

    test "a validator failure always refuses, even after consent was issued", context do
      run = ready_run(context, [])
      review = seed_review(run, :main, [])

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)

      Repo.update!(Ecto.Changeset.change(review, status: "failed"))

      assert {:error, :validation_failed} = publish(context, preview)
    end

    test "a changed destination revision rejects stale consent", context do
      run = ready_run(context, [])
      _review = seed_review(run, :main, [])

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)

      assert {:error, :stale_destination} =
               FeedPublishing.publish_static(
                 context.scope,
                 preview.token,
                 preview.destination_revision + 1
               )

      assert {:ok, _publication_id} = publish(context, preview)

      # The same token, replayed after the channel moved, is stale consent.
      assert {:error, :stale_destination} = publish(context, preview)
    end
  end

  describe "mismatch notices" do
    test "are advisory: shown, never blocking, and never mutating alerts", context do
      run = ready_run(context, [])
      _review = seed_review(run, :main, [])
      publication = seed_accepted_alert(context)

      before = Repo.get!(AlertPublication, publication.id)

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)

      assert [notice] = preview.notices
      assert notice.reason == :unknown_route
      assert notice.ids == ["R99"]
      assert notice.alert_name == "Ice on Route 99"

      assert {:ok, _publication_id} = publish(context, preview)

      after_state = Repo.get!(AlertPublication, publication.id)
      assert after_state.desired_snapshot == before.desired_snapshot
      assert after_state.confirmed_revision == before.confirmed_revision
      assert after_state.confirmed_snapshot == before.confirmed_snapshot
      assert after_state.withdrawal == before.withdrawal
    end
  end

  describe "revocation and retention" do
    test "a revoked editor cannot confirm an interactive publication", context do
      run = ready_run(context, [])
      _review = seed_review(run, :main, [])

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)

      membership =
        Repo.get_by!(UserOrgMembership,
          organization_id: context.organization.id,
          user_id: context.editor.id
        )

      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} = publish(context, preview)
    end

    test "a source edit and an expired artifact TTL never rewrite already public bytes",
         context do
      route =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "R1",
          route_short_name: "One",
          route_type: 3
        })

      run = ready_run(context, [])
      _review = seed_review(run, :main, [])

      assert {:ok, preview} = FeedPublishing.preview_static(context.scope, run.id, :main)
      assert {:ok, publication_id} = publish(context, preview)

      # Complete the public manifest through the real publisher and loopback HTTP.
      assert {:ok, :current} = FeedPublishing.advance(publication_id)

      channel = Repo.get!(Publication, publication_id)
      assert channel.status == :current
      assert channel.manifest_bytes =~ run.artifact_sha256
      assert is_binary(channel.manifest_sha256)
      served = {channel.manifest_bytes, channel.manifest_sha256, channel.manifest_generation}

      # The private source changes and the artifact TTL passes after publication.
      Repo.update!(Ecto.Changeset.change(route, route_short_name: "Renamed"))

      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        set: [artifact_expires_at: ~U[2000-01-01 00:00:00.000000Z]]
      )

      assert {:ok, :current} = FeedPublishing.advance(publication_id)

      reloaded = Repo.get!(Publication, publication_id)

      assert {reloaded.manifest_bytes, reloaded.manifest_sha256, reloaded.manifest_generation} ==
               served

      assert reloaded.status == :current
    end
  end

  # -- Fixtures and helpers -------------------------------------------------

  defp ready_run(context, extra_members, opts \\ []) do
    organization = context.organization
    version = context.version
    export_type = Keyword.get(opts, :export_type, :full)

    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    bytes = zip_bytes(@full_members ++ extra_members)

    {:ok, main} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", bytes)

    {:ok, ready} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{main: main, flex: nil})

    ready
  end

  defp seed_review(run, slot, opts) do
    digest = if slot == :main, do: run.artifact_sha256, else: run.flex_artifact_sha256

    Repo.insert!(%ValidationRun{
      organization_id: run.organization_id,
      gtfs_version_id: run.gtfs_version_id,
      run_type: "mobility_data_artifact",
      status: Keyword.get(opts, :status, "completed"),
      errors_count: Keyword.get(opts, :errors_count, 0),
      warnings_count: Keyword.get(opts, :warnings_count, 0),
      infos_count: Keyword.get(opts, :infos_count, 0),
      artifact_sha256: digest,
      artifact_slot: slot,
      artifact_export_run_id: run.id,
      started_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    })
  end

  defp seed_accepted_alert(context) do
    alert =
      Repo.insert!(%Alert{
        organization_id: context.organization.id,
        source_gtfs_version_id: context.version.id,
        revision: 1,
        public_entity_id: Ecto.UUID.generate(),
        scope: %ScopeAnswer{},
        timing: %TimingAnswer{},
        message: %MessageAnswer{}
      })

    Repo.insert!(%AlertPublication{
      organization_id: context.organization.id,
      alert_id: alert.id,
      desired_revision: 1,
      desired_snapshot: %{
        "public_entity_id" => alert.public_entity_id,
        "accepted_revision" => 1,
        "header" => "Ice on Route 99",
        "effect" => "detour",
        "scope" => @echo_scope
      },
      withdrawal: :none
    })
  end

  defp publish(context, preview) do
    FeedPublishing.publish_static(context.scope, preview.token, preview.destination_revision)
  end

  defp zip_bytes(members) do
    dir = Path.join(System.tmp_dir!(), "static-pub-zip-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "archive.zip")

    entries = Enum.map(members, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, _written} = :zip.create(String.to_charlist(path), entries)
    bytes = File.read!(path)
    File.rm_rf!(dir)
    bytes
  end

  defp use_fake_validator(mode) do
    put_env(:validator_module, Validator)
    put_env(:java_path, @fake_java)
    put_env(:gtfs_validator_path, mode)
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:gtfs_planner, key)
    Application.put_env(:gtfs_planner, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:gtfs_planner, key, old)
        :error -> Application.delete_env(:gtfs_planner, key)
      end
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

  # Subscribing first and then reading the stored status closes the race: either
  # the broadcast arrives after the subscription, or the terminal row is already
  # committed when it is read.
  defp await_terminal(run_id, event) do
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Validations.topic(run_id))

    receive do
      {^event, ^run_id} -> true
    after
      0 ->
        status = Validations.get_validation_run(run_id).status

        if (status == "completed" and event == :validation_completed) or
             (status == "failed" and event == :validation_failed) do
          true
        else
          receive do
            {^event, ^run_id} -> true
          after
            15_000 -> false
          end
        end
    end
  end
end

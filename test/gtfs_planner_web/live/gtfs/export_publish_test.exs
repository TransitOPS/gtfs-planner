defmodule GtfsPlannerWeb.Gtfs.ExportPublishTest do
  @moduledoc """
  Step 15: the row-bound publication flow on the Export Files list (CL-11).

  Every case drives the routed `/gtfs/:version/export` page, the scoped
  `publish_file` event, and the real `FeedPublishing.preview_static/3` /
  `publish_static/4` over a real export run and a seeded completed
  `mobility_data_artifact` report. Only the object-storage boundary is doubled.
  A durable `:current` publication is asserted only when the fixture actually
  produces one.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.HTTPBoundary
  alias GtfsPlanner.FeedPublishing.Manifest
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

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
    {"routes.txt", "route_id,agency_id,route_short_name,route_type\n" <> "R1,MTA,One,3\n"},
    {"trips.txt", "trip_id,route_id,service_id\nT1,R1,S1\n"},
    {"stops.txt", "stop_id,stop_name\nA1,Alpha\n"},
    {"stop_times.txt",
     "trip_id,arrival_time,departure_time,stop_id\n" <> "T1,06:00:00,06:00:00,A1\n"}
  ]

  @unavailable "That file isn't available."

  setup do
    root = Path.join(System.tmp_dir!(), "export-publish-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    previous_config = Application.get_env(:gtfs_planner, :feed_publishing_config)
    Application.put_env(:gtfs_planner, :feed_publishing_config, {:enabled, @config})
    HTTPBoundary.reset()

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, previous_root)
      restore_env(:feed_publishing_config, previous_config)
    end)

    %{organization: organization, version: version, user: user}
  end

  describe "eligibility" do
    test "operations rows expose no publish item and a forged event opens nothing", context do
      run = ready_run(context, export_type: :operations)

      {:ok, view, _html} = live(conn(context), export_path(context))

      refute has_element?(view, "#export-file-#{run.id}-publish")

      render_hook(view, "publish_file", %{"run" => run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#export-files-notice", @unavailable)
      refute has_element?(view, "#publish-drawer-overlay[data-open='true']")
    end

    test "operations_only rows expose no publish item and a forged event opens nothing",
         context do
      run = ready_run(context, export_type: :operations_only)

      {:ok, view, _html} = live(conn(context), export_path(context))

      refute has_element?(view, "#export-file-#{run.id}-publish")

      render_hook(view, "publish_file", %{"run" => run.id})
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#export-files-notice", @unavailable)
      refute has_element?(view, "#publish-drawer-overlay[data-open='true']")
    end

    test "a foreign or other-version run id is refused without opening a drawer", context do
      foreign_organization = organization_fixture()

      foreign =
        ready_run(%{
          organization: foreign_organization,
          version: gtfs_version_fixture(foreign_organization.id)
        })

      other_version = gtfs_version_fixture(context.organization.id)
      other = ready_run(%{organization: context.organization, version: other_version})

      {:ok, view, _html} = live(conn(context), export_path(context))

      for run <- [foreign, other] do
        render_hook(view, "publish_file", %{"run" => run.id})
        _ = :sys.get_state(view.pid)
        assert has_element?(view, "#export-files-notice", @unavailable)
        refute has_element?(view, "#publish-drawer-overlay[data-open='true']")
      end
    end

    test "a disabled installation hides the address card and publish items", context do
      Application.put_env(:gtfs_planner, :feed_publishing_config, :disabled)
      run = ready_run(context)
      _report = seed_report(context, run)

      {:ok, view, _html} = live(conn(context), export_path(context))

      refute has_element?(view, "#feed-publish")
      refute has_element?(view, "#export-file-#{run.id}-publish")
    end
  end

  describe "row binding" do
    test "an older ready row opens a drawer bound to that run despite a newer full run",
         context do
      older = ready_run(context)
      _older_report = seed_report(context, older)
      _newer = ready_run(context)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#export-file-#{older.id}-publish") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#publish-drawer-overlay[data-open='true']")
      assert has_element?(view, "#publish-reviewed-run[data-run-id='#{older.id}']")
      assert has_element?(view, "#feed-publish-review")
    end
  end

  describe "consent and refusal" do
    test "an error report keeps Publish refused until the consent box is checked", context do
      run = ready_run(context)
      _report = seed_report(context, run, errors_count: 2)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#export-file-#{run.id}-publish") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#feed-publish-confirm-errors")

      # An unchecked submit is refused before any consent.
      view |> form("#feed-publish-consent") |> render_submit()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#feed-publish-refusal")

      view
      |> form("#feed-publish-consent", %{"publication" => %{"confirm_errors" => "true"}})
      |> render_change()

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#feed-publish-confirm", "Publish feed")

      # Checked consent succeeds.
      view |> form("#feed-publish-consent") |> render_submit()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#export-toast-text", "Full feed queued for publication.")
    end
  end

  describe "the pending-check fence" do
    test "selecting run B clears run A's pending check so A's late completion cannot open it",
         context do
      run_a = ready_run(context)
      report_a = seed_report(context, run_a, status: "running", completed_at: nil)
      run_b = ready_run(context)
      _report_b = seed_report(context, run_b)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#export-file-#{run_a.id}-publish") |> render_click()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#publish-reviewed-run[data-run-id='#{run_a.id}']")

      view |> element("#export-file-#{run_b.id}-publish") |> render_click()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#publish-reviewed-run[data-run-id='#{run_b.id}']")

      # A's report finishes late; the review stays on B.
      complete_report(report_a)
      broadcast_validation(:validation_completed, report_a.id)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#publish-reviewed-run[data-run-id='#{run_b.id}']")
    end
  end

  describe "successful confirmation" do
    test "polling observes serving completion and keeps warnings available", context do
      run = ready_run(context, warnings: [warning()])
      _report = seed_report(context, run)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#export-file-#{run.id}-publish") |> render_click()
      _ = :sys.get_state(view.pid)

      view
      |> form("#feed-publish-consent")
      |> render_submit()

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#export-toast-text", "Full feed queued for publication.")
      refute has_element?(view, "#feed-publish-review")
      assert has_element?(view, "#export-file-#{run.id}-warnings")
      refute has_element?(view, "#export-file-#{run.id}-published")

      # Advance the real publisher loopback so the channel genuinely serves the
      # file. The production polling message, not an unrelated export-run
      # broadcast, refreshes the row and Public address card.
      publication_id = :sys.get_state(view.pid).socket.assigns.publication.publication_id
      assert is_binary(publication_id)
      assert {:ok, :current} = FeedPublishing.advance(publication_id)

      poll_publication(view)

      assert has_element?(view, "#export-toast-text", "Full feed published.")
      assert has_element?(view, "#export-file-#{run.id}-published", "Published")
      assert has_element?(view, "#export-file-#{run.id}-warnings", "1 warnings")
      assert has_element?(view, "#public-address-card")
      assert has_element?(view, "#public-address-url-full")
      assert has_element?(view, "#public-address-serving-full")

      view |> element("#export-file-#{run.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#export-file-#{run.id}-warnings-detail", "Build warning")
    end

    test "a current published run still exposes its warnings on initial mount", context do
      run = ready_run(context, warnings: [warning()])
      _report = seed_report(context, run)
      publish_run!(context, run)

      {:ok, view, _html} = live(conn(context), export_path(context))

      assert has_element?(view, "#export-file-#{run.id}-published", "Published")
      assert has_element?(view, "#export-file-#{run.id}-warnings", "1 warnings")

      view |> element("#export-file-#{run.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)
      assert has_element?(view, "#export-file-#{run.id}-warnings-detail", "Build warning")
    end

    test "polling exposes a durable publication failure", context do
      run = ready_run(context)
      _report = seed_report(context, run)

      {:ok, view, _html} = live(conn(context), export_path(context))

      view |> element("#export-file-#{run.id}-publish") |> render_click()
      _ = :sys.get_state(view.pid)
      view |> form("#feed-publish-consent") |> render_submit()
      state = :sys.get_state(view.pid)

      publication_id = state.socket.assigns.publication.publication_id
      scope = publication_scope(context)
      {:ok, publications} = FeedPublishing.status(scope)
      publication = Enum.find(publications, &(&1.id == publication_id))

      HTTPBoundary.put_object(
        Manifest.key(publication.namespace.prefix, :full),
        "manifest owned by another publisher",
        etag: ~s("foreign")
      )

      assert {:error, :blocked} = FeedPublishing.advance(publication_id)

      poll_publication(view)

      assert has_element?(view, "#export-toast-text", "Publication failed.")
      refute has_element?(view, "#export-file-#{run.id}-published")
      refute has_element?(view, "#public-address-url-full")
    end
  end

  # -- Fixtures and helpers -------------------------------------------------

  defp conn(context),
    do: log_in_user(build_conn(), context.user, organization: context.organization)

  defp export_path(context), do: "/gtfs/#{context.version.id}/export"

  defp ready_run(context, opts \\ []) do
    organization = context.organization
    version = context.version
    export_type = Keyword.get(opts, :export_type, :full)

    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    warnings = Keyword.get(opts, :warnings, [])

    if warnings != [] do
      {:ok, _run} =
        ExportRuns.persist_warnings(organization.id, run.id, generation, token, warnings)
    end

    {:ok, main} =
      ArtifactStorage.publish(
        organization.id,
        version.id,
        run.id,
        "network.zip",
        zip_bytes(@full_members)
      )

    {:ok, ready} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{main: main, flex: nil})

    ready
  end

  defp seed_report(context, run, opts \\ []) do
    Repo.insert!(%ValidationRun{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      run_type: "mobility_data_artifact",
      status: Keyword.get(opts, :status, "completed"),
      errors_count: Keyword.get(opts, :errors_count, 0),
      warnings_count: 0,
      infos_count: 0,
      artifact_sha256: run.artifact_sha256,
      artifact_slot: :main,
      artifact_export_run_id: run.id,
      started_at: DateTime.utc_now(),
      completed_at: Keyword.get(opts, :completed_at, DateTime.utc_now())
    })
  end

  defp complete_report(report) do
    report
    |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp broadcast_validation(event, run_id) do
    Phoenix.PubSub.broadcast(GtfsPlanner.PubSub, Validations.topic(run_id), {event, run_id})
  end

  defp publish_run!(context, run) do
    scope = publication_scope(context)
    {:ok, preview} = FeedPublishing.preview_static(scope, run.id, :main)

    {:ok, publication_id} =
      FeedPublishing.publish_static(scope, preview.token, preview.destination_revision)

    assert {:ok, :current} = FeedPublishing.advance(publication_id)
    publication_id
  end

  defp publication_scope(context) do
    %{
      organization_id: context.organization.id,
      actor_id: context.user.id,
      gtfs_version_id: context.version.id
    }
  end

  defp poll_publication(view) do
    publication = :sys.get_state(view.pid).socket.assigns.publication

    send(
      view.pid,
      {
        :publication_status_poll,
        publication.publication_id,
        publication.poll_token,
        1
      }
    )

    _ = :sys.get_state(view.pid)
  end

  defp warning do
    %{"code" => "build_warning", "detail" => "Build warning needs attention."}
  end

  defp zip_bytes(members) do
    dir = Path.join(System.tmp_dir!(), "export-publish-zip-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "archive.zip")

    entries = Enum.map(members, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, _written} = :zip.create(String.to_charlist(path), entries)
    bytes = File.read!(path)
    File.rm_rf!(dir)
    bytes
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end

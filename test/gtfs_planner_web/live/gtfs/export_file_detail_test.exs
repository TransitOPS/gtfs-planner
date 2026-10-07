defmodule GtfsPlannerWeb.Gtfs.ExportFileDetailTest do
  @moduledoc """
  EV-14: a Files row's grouped warning detail and its R3 match statement, driven
  through the routed export page and the real ExportRuns/publication reads.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.{Attempt, Publication}
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup %{conn: conn} do
    organization = organization_fixture(%{alias: "files#{System.unique_integer([:positive])}"})
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    root =
      Path.join(System.tmp_dir!(), "export-file-detail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    %{
      conn: log_in_user(conn, user, organization: organization),
      user: user,
      organization: organization,
      version: version
    }
  end

  describe "the grouped warning detail" do
    test "sums the trip counts in a tods_runs_uncovered group and links to runs", context do
      run =
        make_ready!(context.organization, context.version, :operations_only,
          warnings: [
            warning("tods_runs_uncovered", "90 trips are not in a run for Weekday."),
            warning("tods_runs_uncovered", "87 trips are not in a run for Saturday.")
          ]
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))
      refute has_element?(view, "#export-file-#{run.id}-warnings-detail")

      view |> element("#export-file-#{run.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      detail = "#export-file-#{run.id}-warnings-detail"

      assert has_element?(view, detail, "177 trips are not in a run")
      assert has_element?(view, detail, "· 2 warnings")
      assert has_element?(view, detail, "90 trips are not in a run for Weekday.")
      assert has_element?(view, detail, "tods_runs_uncovered")
      assert has_element?(view, detail, "Open runs")

      assert has_element?(
               view,
               "#warning-fix-tods_runs_uncovered[href='/gtfs/#{context.version.id}/runs']"
             )
    end

    test "shows the run's recorded build settings", context do
      set_defaults!(context.organization, %{
        estimate_missing_times: true,
        estimate_method: :distance,
        include_flex: true
      })

      run =
        make_ready!(context.organization, context.version, :operations,
          flex?: true,
          warnings: [warning("tods_movements_omitted", "1 movement has no driving time.")]
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))
      view |> element("#export-file-#{run.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      assert has_element?(
               view,
               "#export-file-#{run.id}-warnings-detail",
               "Made with: missing stop times estimated by distance along the path · flex services in a separate file"
             )
    end

    test "names stale defaults when the run's settings differ from today's", context do
      set_defaults!(context.organization, %{
        estimate_missing_times: true,
        estimate_method: :distance
      })

      run =
        make_ready!(context.organization, context.version, :operations,
          warnings: [warning("tods_movements_omitted", "1 movement has no driving time.")]
        )

      set_defaults!(context.organization, %{estimate_method: :even})

      {:ok, view, _html} = live(context.conn, export_path(context.version))
      view |> element("#export-file-#{run.id}-warnings") |> render_click()
      _ = :sys.get_state(view.pid)

      stale = "#export-file-#{run.id}-stale-settings"

      assert has_element?(view, stale, "distance along the path")
      assert has_element?(view, stale, "equal time per stop")
    end
  end

  describe "the R3 match statement" do
    test "a served run with an equal fingerprint is a published match", context do
      fingerprint = String.duplicate("a", 64)

      served =
        make_ready!(context.organization, gtfs_version_fixture(context.organization.id), :full,
          fingerprint: fingerprint
        )

      serve_full!(context.organization, served.id)

      run =
        make_ready!(context.organization, context.version, :operations_only,
          fingerprint: fingerprint
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(
               view,
               "#export-file-#{run.id}-match",
               "Matches the published full feed network.zip"
             )
    end

    test "a same-version full file is the match when no run is served", context do
      fingerprint = String.duplicate("a", 64)
      _file = make_ready!(context.organization, context.version, :full, fingerprint: fingerprint)

      run =
        make_ready!(context.organization, context.version, :operations_only,
          fingerprint: fingerprint
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(view, "#export-file-#{run.id}-match", "Matches network.zip")
    end

    test "a served run without a fingerprint answers published_unknown", context do
      served =
        make_ready!(context.organization, gtfs_version_fixture(context.organization.id), :full)

      serve_full!(context.organization, served.id)

      run =
        make_ready!(context.organization, context.version, :operations_only,
          fingerprint: String.duplicate("a", 64)
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(
               view,
               "#export-file-#{run.id}-match",
               "published before matching was added"
             )
    end

    test "a differing served fingerprint answers none with a current channel", context do
      served =
        make_ready!(context.organization, gtfs_version_fixture(context.organization.id), :full,
          fingerprint: String.duplicate("b", 64)
        )

      serve_full!(context.organization, served.id)

      run =
        make_ready!(context.organization, context.version, :operations_only,
          fingerprint: String.duplicate("a", 64)
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(
               view,
               "#export-file-#{run.id}-match",
               "Doesn't match the published feed or any full feed from the last 24 hours"
             )
    end

    test "no served run and no file answers none without a current channel", context do
      run =
        make_ready!(context.organization, context.version, :operations_only,
          fingerprint: String.duplicate("a", 64)
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(
               view,
               "#export-file-#{run.id}-match",
               "Doesn't match any full feed from the last 24 hours"
             )
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp export_path(version), do: "/gtfs/#{version.id}/export"

  defp warning(code, detail) do
    %{
      "code" => code,
      "detail" => detail,
      "file" => "run_events.txt",
      "entity_type" => "run"
    }
  end

  defp set_defaults!(organization, attrs) do
    {:ok, _defaults} = ExportDefaults.update(organization.id, editor_fixture(organization), attrs)
  end

  defp make_ready!(organization, version, export_type, opts \\ []) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)

    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    case Keyword.get(opts, :warnings, []) do
      [] ->
        :ok

      warnings ->
        {:ok, _} =
          ExportRuns.persist_warnings(organization.id, run.id, generation, token, warnings)
    end

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", empty_zip())

    flex =
      if Keyword.get(opts, :flex?, false) do
        {:ok, flex_artifact} =
          ArtifactStorage.publish(
            organization.id,
            version.id,
            run.id,
            "gtfs-flex.zip",
            empty_zip()
          )

        flex_artifact
      end

    {:ok, ready} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: flex,
        reference_sha256: Keyword.get(opts, :fingerprint)
      })

    ready
  end

  defp serve_full!(organization, run_id) do
    actor = editor_fixture(organization)
    scope = %{organization_id: organization.id, actor_id: actor.id}
    {:ok, namespace} = FeedPublishing.claim_namespace(scope)

    publication =
      Repo.insert!(%Publication{
        organization_id: organization.id,
        namespace_id: namespace.id,
        channel: :full,
        status: :current,
        desired_revision: 1
      })

    attempt =
      Repo.insert!(%Attempt{
        publication_id: publication.id,
        organization_id: organization.id,
        sequence: 1,
        generation: "generation-#{System.unique_integer([:positive])}",
        desired_revision: 1,
        state: "pending",
        manifest_body: "{}",
        manifest_sha256: String.duplicate("a", 64),
        private_snapshot: %{"source" => %{"run_id" => run_id}}
      })

    publication
    |> Ecto.Changeset.change(%{active_attempt_id: attempt.id, status: :current})
    |> Repo.update!()
  end

  defp empty_zip do
    {:ok, {_, bytes}} =
      :zip.create(
        ~c"network.zip",
        [{~c"agency.txt", "agency_id,agency_name,agency_url,agency_timezone\n"}],
        [:memory]
      )

    bytes
  end
end

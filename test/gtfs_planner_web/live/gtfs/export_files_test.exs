defmodule GtfsPlannerWeb.Gtfs.ExportFilesTest do
  @moduledoc """
  First red coverage for the Export Files collection: the version-scoped list and
  its paging, forged cancel events, the live run broadcast, and the finished band.

  Every case drives the routed `/gtfs/:version/export` page, the real
  `GtfsPlanner.Gtfs.ExportRuns` reads and writes, and the real PubSub broadcast
  those writes emit. Rows are asserted through the public LiveView/DB boundary by
  their stable `#export-file-<id>` ids, and lifecycle changes synchronise with
  `:sys.get_state/1` rather than sleeps.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}
  @unavailable "That file isn't available."

  setup %{conn: conn} do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    root = Path.join(System.tmp_dir!(), "export-files-#{System.unique_integer([:positive])}")
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

  describe "the version-scoped list and paging" do
    test "renders the newest 25 runs, then load-more appends the 26th without dropping rows",
         context do
      for _ <- 1..26, do: ready_run!(context.organization, context.version)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      expected = ExportRuns.list_files(context.organization.id, context.version.id, limit: 25)
      expected_ids = Enum.map(expected, &to_string(&1.id))
      assert visible_file_ids(view) == expected_ids

      render_click(view, "load_more_files")
      _ = :sys.get_state(view.pid)

      ids = visible_file_ids(view)
      assert length(ids) == 26
      assert Enum.take(ids, 25) == expected_ids

      all = ExportRuns.list_files(context.organization.id, context.version.id, limit: 26)
      assert Enum.map(all, &to_string(&1.id)) == ids
    end
  end

  describe "scoped row actions" do
    test "forged cancel_file and retry_file reject foreign and other-version runs", context do
      foreign_organization = organization_fixture()

      foreign =
        ready_run!(foreign_organization, gtfs_version_fixture(foreign_organization.id))

      other_version = gtfs_version_fixture(context.organization.id)
      other = ready_run!(context.organization, other_version)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      for event <- ["cancel_file", "retry_file"], run <- [foreign, other] do
        before = Repo.get!(Run, run.id).state
        render_hook(view, event, %{"run" => run.id})
        _ = :sys.get_state(view.pid)

        assert Repo.get!(Run, run.id).state == before
        assert has_element?(view, "#export-files-notice", @unavailable)
      end
    end
  end

  describe "live run changes" do
    test "reconciles a listed nonselected run that finishes just before subscription", context do
      {building, generation, token} =
        building_run!(context.organization, context.version, :operations_only)

      put_lifecycle_observer(fn
        :before_subscribe, %{id: id} when id == building.id ->
          # A ready row is subscribed too (its expiry can change a displayed
          # match), so the connected mount reaches this checkpoint again after
          # the first transition; only the first call is the one under test.
          if Repo.get!(Run, building.id).state == :building do
            mark_ready!(
              context.organization,
              context.version,
              building,
              generation,
              token
            )
          else
            :ok
          end

        _stage, _run ->
          :ok
      end)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(view, "#export-file-#{building.id}-download")
      refute has_element?(view, "#export-file-#{building.id}", "Building…")
    end

    test "a listed building run marked ready through the real path shows Download", context do
      {building, generation, token} = building_run!(context.organization, context.version)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(view, "#export-file-#{building.id}")
      refute has_element?(view, "#export-file-#{building.id}-download")

      mark_ready!(context.organization, context.version, building, generation, token)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#export-file-#{building.id}-download")
    end
  end

  describe "the finished band" do
    test "the first export replaces the prototype empty state and reconciles an instant finish",
         context do
      owner = self()

      put_lifecycle_observer(fn
        :before_start, run ->
          ready = finish_pending_run!(context.organization, context.version, run)
          send(owner, {:instant_export_ready, ready.id})

        _stage, _run ->
          :ok
      end)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(view, "#export-files-empty .hero-document")

      assert has_element?(
               view,
               "#export-files-empty",
               "Files you export appear here to download, publish or compare."
             )

      refute has_element?(view, "#export-files-rows")

      render_click(view, "start_export")
      assert_receive {:instant_export_ready, run_id}

      refute has_element?(view, "#export-files-empty")
      assert has_element?(view, "#export-file-#{run_id}-download")
      assert has_element?(view, "#export-finished .hero-check-circle")
      assert has_element?(view, "#export-finished + div #files-h")
      assert has_element?(view, "#export-download-link.btn-primary.min-h-11")
      assert has_element?(view, "#export-finished-dismiss[aria-label='Dismiss finished export']")
    end

    test "a run started here that becomes ready shows the band; a listed run does not", context do
      # A listed run that another session made ready belongs to the list, not the
      # band.
      listed = ready_run!(context.organization, context.version)
      {:ok, view, _html} = live(context.conn, export_path(context.version))

      refute has_element?(view, "#export-finished")

      # A run this page starts and then finishes owns the band.
      render_click(view, "start_export")
      _ = :sys.get_state(view.pid)
      started = ExportRuns.latest_for_version(context.organization.id, context.version.id, :full)

      assert started != nil
      assert started.id != listed.id

      mark_ready!(context.organization, context.version, started)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#export-finished")
      assert has_element?(view, "#export-finished #export-download-link")
    end

    test "dismissal survives a ready download broadcast", context do
      owner = self()

      put_lifecycle_observer(fn
        :before_start, run ->
          ready = finish_pending_run!(context.organization, context.version, run)
          send(owner, {:instant_export_ready, ready.id})

        _stage, _run ->
          :ok
      end)

      {:ok, view, _html} = live(context.conn, export_path(context.version))
      render_click(view, "start_export")
      assert_receive {:instant_export_ready, run_id}
      assert has_element?(view, "#export-finished")

      render_click(view, "dismiss_finished")
      refute has_element?(view, "#export-finished")

      assert {:ok, claim} =
               ExportRuns.claim_download(context.organization.id, context.version.id, run_id)

      assert :ok =
               ExportRuns.complete_download(
                 context.organization.id,
                 context.version.id,
                 run_id,
                 claim.claim_id
               )

      _ = :sys.get_state(view.pid)
      refute has_element?(view, "#export-finished")
    end

    test "a ready-to-expired transition clears the band and download", context do
      owner = self()

      put_lifecycle_observer(fn
        :before_start, run ->
          ready = finish_pending_run!(context.organization, context.version, run)
          send(owner, {:instant_export_ready, ready.id})

        _stage, _run ->
          :ok
      end)

      {:ok, view, _html} = live(context.conn, export_path(context.version))
      render_click(view, "start_export")
      assert_receive {:instant_export_ready, run_id}
      assert has_element?(view, "#export-finished")

      Run
      |> Repo.get!(run_id)
      |> backdate!(:artifact_expires_at)

      assert ExportRuns.cleanup_expired(context.organization.id) == 1
      _ = :sys.get_state(view.pid)

      refute has_element?(view, "#export-finished")
      refute has_element?(view, "#export-file-#{run_id}-download")
      assert has_element?(view, "#export-file-#{run_id}", "Download expired")
    end
  end

  describe "retry ordering" do
    test "a successful retry is prepended, retains older rows and reconciles an instant finish",
         context do
      older = ready_run!(context.organization, context.version)
      failed = failed_run!(context.organization, context.version, "build_failed")
      owner = self()

      put_lifecycle_observer(fn
        :before_start, run ->
          ready = finish_pending_run!(context.organization, context.version, run)
          send(owner, {:instant_retry_ready, ready.id})

        _stage, _run ->
          :ok
      end)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      view
      |> element("#export-file-#{failed.id} button[phx-click='retry_file']")
      |> render_click()

      assert_receive {:instant_retry_ready, retry_id}

      assert [^retry_id, failed_id, older_id | _rest] = visible_file_ids(view)
      assert failed_id == to_string(failed.id)
      assert older_id == to_string(older.id)
      assert has_element?(view, "#export-file-#{retry_id}-download")
    end
  end

  describe "the rendered row states and actions" do
    test "renders each state's stable row, status, action, filename, href and Private tag",
         context do
      ready = ready_run!(context.organization, context.version, :full)
      failed = failed_run!(context.organization, context.version, "build_failed")
      cancelled = cancelled_run!(context.organization, context.version)
      interrupted = interrupted_run!(context.organization, context.version)
      expired = expired_run!(context.organization, context.version)
      legacy = ready_run!(context.organization, context.version, :operations)
      {building, _g, _t} = building_run!(context.organization, context.version, :operations_only)
      pending = pending_only!(context.organization, context.version, :pathways)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(view, "#export-file-#{pending.id}", "Queued")

      assert has_element?(
               view,
               "#export-file-#{pending.id} button[phx-click='cancel_file']",
               "Cancel"
             )

      assert has_element?(view, "#export-file-#{building.id}", "Building…")
      assert has_element?(view, "#export-file-#{building.id}-progress")

      assert has_element?(view, "#export-file-#{ready.id}", "No warnings")
      assert has_element?(view, "#export-file-#{ready.id}", "network.zip")

      assert has_element?(
               view,
               "#export-file-#{ready.id}-download[href='/gtfs/#{context.version.id}/export-runs/#{ready.id}/download']"
             )

      assert has_element?(view, "#export-file-#{failed.id}", "Export failed")

      assert has_element?(
               view,
               "#export-file-#{failed.id} button[phx-click='retry_file']",
               "Retry export"
             )

      assert has_element?(view, "#export-file-#{cancelled.id}", "Export cancelled")
      assert has_element?(view, "#export-file-#{interrupted.id}", "Export interrupted")
      assert has_element?(view, "#export-file-#{expired.id}", "Download expired")
      assert has_element?(view, "#export-file-#{legacy.id}", "Private")
    end

    test "a garage clash renders the callout, its detail and the row's retry", context do
      clash =
        failed_run!(context.organization, context.version, "garage_stop_id_conflict",
          warnings: [
            %{"code" => "garage_stop_id_conflict", "detail" => "Garage Main matches stop S1."}
          ]
        )

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      assert has_element?(view, "#export-garage-clash")
      assert has_element?(view, "#export-garage-clash-details", "Garage Main matches stop S1.")

      assert has_element?(
               view,
               "#export-edit-garages[href='/gtfs/#{context.version.id}/settings/garages']",
               "Edit garages"
             )

      assert has_element?(
               view,
               "#export-file-#{clash.id} button[phx-click='retry_file']",
               "Retry export"
             )
    end

    test "a listed building run that fails with a garage clash shows the callout live",
         context do
      {building, generation, token} = building_run!(context.organization, context.version)

      {:ok, view, _html} = live(context.conn, export_path(context.version))
      refute has_element?(view, "#export-garage-clash")

      {:ok, _warned} =
        ExportRuns.persist_warnings(
          context.organization.id,
          building.id,
          generation,
          token,
          [%{"code" => "garage_stop_id_conflict", "detail" => "Garage Main matches stop S1."}]
        )

      {:ok, _failed} =
        ExportRuns.fail_build(
          context.organization.id,
          building.id,
          generation,
          token,
          "garage_stop_id_conflict"
        )

      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#export-garage-clash")
      assert has_element?(view, "#export-garage-clash-details", "Garage Main matches stop S1.")
    end

    test "cancelling a listed building row shows the exact cancellation toast", context do
      {building, _g, _t} = building_run!(context.organization, context.version)

      {:ok, view, _html} = live(context.conn, export_path(context.version))

      view
      |> element("#export-file-#{building.id} button[phx-click='cancel_file']")
      |> render_click()

      assert has_element?(view, "#export-toast-text", "Export cancelled. No file was saved.")
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp export_path(version), do: "/gtfs/#{version.id}/export"

  defp visible_file_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[id^='export-file-']")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> to_string()))
    |> Enum.filter(&Regex.match?(~r/^export-file-[0-9a-f-]{36}$/, &1))
    |> Enum.map(&String.replace_prefix(&1, "export-file-", ""))
  end

  defp ready_run!(organization, version, export_type \\ :full) do
    {run, generation, token} = pending_run!(organization, version, export_type)
    mark_ready!(organization, version, run, generation, token)
  end

  defp building_run!(organization, version, export_type \\ :full) do
    pending_run!(organization, version, export_type)
  end

  defp finish_pending_run!(organization, version, run) do
    {:ok, building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)
    mark_ready!(organization, version, building, generation, token)
  end

  # Creates a pending run and claims it, returning the building run with the
  # generation and token the ready transition fences on.
  defp pending_run!(organization, version, export_type) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)

    {:ok, building, generation, token} =
      ExportRuns.claim(organization.id, run.id, :build)

    {building, generation, token}
  end

  defp mark_ready!(organization, version, run, generation \\ nil, token \\ nil) do
    {generation, token} =
      cond do
        is_integer(generation) and is_binary(token) ->
          {generation, token}

        true ->
          claimed = Repo.get!(Run, run.id)
          {claimed.lease_generation, claimed.lease_token}
      end

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", empty_zip())

    {:ok, ready} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    ready
  end

  defp pending_only!(organization, version, export_type) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
    run
  end

  defp failed_run!(organization, version, code, opts \\ []) do
    {run, generation, token} = pending_run!(organization, version, :full)

    case Keyword.get(opts, :warnings, []) do
      [] ->
        :ok

      warnings ->
        {:ok, _run} =
          ExportRuns.persist_warnings(organization.id, run.id, generation, token, warnings)
    end

    {:ok, _failed} = ExportRuns.fail_build(organization.id, run.id, generation, token, code)
    Repo.get!(Run, run.id)
  end

  defp cancelled_run!(organization, version) do
    {run, generation, token} = pending_run!(organization, version, :full)
    {:ok, _run} = ExportRuns.request_cancel(organization.id, run.id)

    {:ok, _cancelled} =
      ExportRuns.fail_build(organization.id, run.id, generation, token, "build_failed")

    Repo.get!(Run, run.id)
  end

  defp interrupted_run!(organization, version) do
    {run, _generation, _token} = pending_run!(organization, version, :full)
    backdate!(run, :lease_expires_at)
    ExportRuns.reconcile_expired(organization.id)
    Repo.get!(Run, run.id)
  end

  defp expired_run!(organization, version) do
    run = ready_run!(organization, version, :full)
    backdate!(run, :artifact_expires_at)
    ExportRuns.cleanup_expired(organization.id)
    Repo.get!(Run, run.id)
  end

  defp backdate!(run, field) do
    past = DateTime.add(DateTime.utc_now(), -3_600, :second)
    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [{field, past}])
  end

  defp put_lifecycle_observer(observer) do
    previous = Application.fetch_env(:gtfs_planner, :export_files_lifecycle_observer)
    Application.put_env(:gtfs_planner, :export_files_lifecycle_observer, observer)

    on_exit(fn ->
      case previous do
        {:ok, value} ->
          Application.put_env(:gtfs_planner, :export_files_lifecycle_observer, value)

        :error ->
          Application.delete_env(:gtfs_planner, :export_files_lifecycle_observer)
      end
    end)
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

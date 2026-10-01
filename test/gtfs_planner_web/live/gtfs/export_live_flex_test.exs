defmodule GtfsPlannerWeb.Gtfs.ExportLiveFlexTest do
  @moduledoc """
  Judges the Export page's flex download and flex validation (EV-25, AC-28, R15).

  The download link is scoped to a ready run that actually holds a flex
  artifact. The "Check flex file" button starts a `mobility_data_flex` run
  through the configured validator module (Mox in tests), and the validator
  itself selects the `:flex` export profile from that run type. The history
  table titles the run "Flex file check" and the results page leads with "Flex file".
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    root =
      Path.join(System.tmp_dir!(), "export-live-flex-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore_env(:gtfs_task_artifacts_path, previous_root)
    end)

    %{user: user, organization: organization, gtfs_version: version}
  end

  test "offers the flex download only on a ready run that holds a flex artifact", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    log_in = log_in_user(conn, user, organization: organization)

    main_run = ready_run!(organization.id, version.id, "main zip bytes", nil)

    {:ok, main_view, _html} = live(log_in, "/gtfs/#{version.id}/export")

    assert has_element?(main_view, "#export-download-link", "Download file")
    refute has_element?(main_view, "#export-flex-download-link")
    refute main_run.flex_artifact_key

    flex_run = ready_run!(organization.id, version.id, "main zip bytes", "flex zip bytes")

    {:ok, flex_view, _html} = live(log_in, "/gtfs/#{version.id}/export")

    assert attribute_values(render(flex_view), "#export-download-link", "href") == [
             "/gtfs/#{version.id}/export-runs/#{flex_run.id}/download"
           ]

    assert attribute_values(render(flex_view), "#export-flex-download-link", "href") == [
             "/gtfs/#{version.id}/export-runs/#{flex_run.id}/download?file=flex"
           ]

    assert has_element?(flex_view, "#export-flex-download-link", "Download flex file")
  end

  describe "flex validation" do
    setup :set_mox_global
    setup :verify_on_exit!

    test "the flex button starts a mobility_data_flex run through the validator module", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      log_in = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(log_in, "/gtfs/#{version.id}/export")

      assert has_element?(view, "#run-validation", "Check feed")
      assert has_element?(view, "#validate-flex-button", "Check flex file")

      test_pid = self()

      expect(GtfsPlanner.Gtfs.ValidatorMock, :validate, fn org_id, version_id, opts ->
        send(test_pid, {:validator_called, org_id, version_id, opts})

        {:ok,
         %Result{
           summary: %{errors: 0, warnings: 0, infos: 0},
           notices: [],
           duration_ms: 1,
           validated_at: DateTime.utc_now()
         }}
      end)

      view |> element("#validate-flex-button") |> render_click()

      assert_receive {:validator_called, called_org_id, called_version_id, opts}
      assert called_org_id == organization.id
      assert called_version_id == version.id

      run = Repo.get!(ValidationRun, Keyword.fetch!(opts, :validation_run_id))

      assert %ValidationRun{
               run_type: "mobility_data_flex",
               organization_id: organization_id,
               gtfs_version_id: gtfs_version_id
             } = run

      assert organization_id == organization.id
      assert gtfs_version_id == version.id
    end

    test "the flex button is absent when the organization's switch is off", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, _defaults} =
        ExportDefaults.update(organization.id, editor_fixture(organization), %{
          include_flex: false
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

      assert has_element?(view, "#run-validation")
      refute has_element?(view, "#validate-flex-button")
    end
  end

  describe "validator export profile" do
    test "validate/3 exports the flex profile for a mobility_data_flex run", %{
      organization: organization,
      gtfs_version: version
    } do
      # `__MODULE__` because the nested recording module is defined below its
      # first use; a bare `RecordingExport` here resolves to the top-level atom.
      with_export_module(__MODULE__.RecordingExport)
      without_validator_path()

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data_flex")

      assert {:error, :validator_path_not_configured} =
               Validator.validate(organization.id, version.id, validation_run_id: run.id)

      assert_received {:exported, organization_id, version_id, :flex, [estimate: :distance]}
      assert organization_id == organization.id
      assert version_id == version.id
    end

    test "validate/3 exports the full profile for every other run type", %{
      organization: organization,
      gtfs_version: version
    } do
      with_export_module(__MODULE__.RecordingExport)
      without_validator_path()

      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      assert {:error, :validator_path_not_configured} =
               Validator.validate(organization.id, version.id, validation_run_id: run.id)

      assert_received {:exported, organization_id, version_id, :full, [estimate: :distance]}
      assert organization_id == organization.id
      assert version_id == version.id
    end
  end

  test "titles a flex run as a flex file check in history and names it on its results page", %{
    conn: conn,
    user: user,
    organization: organization,
    gtfs_version: version
  } do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "mobility_data_flex")

    {:ok, run} =
      Validations.mark_completed(run, %{
        summary: %{errors: 0, warnings: 1, infos: 2},
        notices: [],
        duration_ms: 12
      })

    conn = log_in_user(conn, user, organization: organization)
    {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/export")

    assert has_element?(view, "#recent-validation-counts-#{run.id}")
    assert has_element?(view, "#recent-check-#{run.id}", "Flex file check")

    {:ok, result_view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")
    assert has_element?(result_view, "header p", "Flex file")
  end

  # Stands in for the configured export module so the test observes the export
  # profile `Validator.validate/3` selects without exporting the version.
  defmodule RecordingExport do
    def export_to_zip(organization_id, gtfs_version_id, profile, opts) do
      send(self(), {:exported, organization_id, gtfs_version_id, profile, opts})
      {:ok, :binary.copy(<<0>>, 32)}
    end
  end

  defp ready_run!(organization_id, version_id, main_bytes, flex_bytes) do
    {:ok, run} = ExportRuns.create_pending(organization_id, version_id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization_id, run.id, :build)

    {:ok, main} =
      ArtifactStorage.publish(
        organization_id,
        version_id,
        run.id,
        "gtfs-#{run.id}.zip",
        main_bytes
      )

    flex =
      if flex_bytes do
        {:ok, artifact} =
          ArtifactStorage.publish(
            organization_id,
            version_id,
            run.id,
            "gtfs-flex-#{run.id}.zip",
            flex_bytes
          )

        artifact
      end

    {:ok, ready} =
      ExportRuns.mark_ready(organization_id, run.id, generation, token, %{
        main: main,
        flex: flex
      })

    ready
  end

  defp attribute_values(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
  end

  defp with_export_module(module) do
    previous = Application.get_env(:gtfs_planner, :gtfs_export_module)
    Application.put_env(:gtfs_planner, :gtfs_export_module, module)
    on_exit(fn -> restore_env(:gtfs_export_module, previous) end)
  end

  defp without_validator_path do
    previous = Application.get_env(:gtfs_planner, :gtfs_validator_path)
    Application.put_env(:gtfs_planner, :gtfs_validator_path, nil)
    on_exit(fn -> restore_env(:gtfs_validator_path, previous) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)
end

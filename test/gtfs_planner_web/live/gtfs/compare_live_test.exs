defmodule GtfsPlannerWeb.Gtfs.CompareLiveTest do
  @moduledoc """
  Focused evidence for the Compare page's production wiring (EV-9): the routed
  `/gtfs/:version_id/compare` page, the sub-navigation between Export and
  Compare, the initial right/left selection, and the `?newer=` prefill guard.

  The cases drive the production path: `CompareLive` reads its choices through
  `ReleaseComparison.list_choices/2` over real retained artifacts published
  through `ExportRuns`/`ArtifactStorage`, and `ExportRuns.get_comparable/3`
  resolves a prefilled id with the same organization scope the comparison uses.
  No claim is taken and no comparison is run here: cancellation and claim release
  are proved by the rerouted selection suite, which owns the slow coordinator
  fixture and is not duplicated.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ReleaseComparisonFixtures
  import GtfsPlanner.VersionsFixtures
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns

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
      Path.join(
        System.tmp_dir!(),
        "compare-live-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    %{user: user, organization: organization, version: version}
  end

  describe "the Compare route and sub-navigation" do
    test "Compare is the current tab, and Export links to /export", context do
      %{conn: conn, user: user, organization: organization, version: version} = context

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), compare_path(version))

      assert has_element?(view, "#gtfs-tab-compare[aria-current='page']")
      assert has_element?(view, "#gtfs-tab-export[href='/gtfs/#{version.id}/export']")
      refute has_element?(view, "#gtfs-tab-export[aria-current='page']")
    end

    test "Export links back to Compare and renders no comparison form", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      publish_run!(organization, version, simple_zip())

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), "/gtfs/#{version.id}/export")

      assert has_element?(view, "#gtfs-tab-compare[href='/gtfs/#{version.id}/compare']")
      refute has_element?(view, "#gtfs-tab-compare[aria-current='page']")
      refute has_element?(view, "#export-comparison-form")
    end
  end

  describe "the initial selection" do
    test "defaults the newest comparable to the right and the second-newest to the left",
         context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      publish_run!(organization, version, left_zip())
      publish_run!(organization, version, right_zip())

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), compare_path(version))

      [newest, second | _rest] = ExportRuns.list_comparable(organization.id)

      assert selected_run_ids(view, "comparison-right") == [to_string(newest.id)]
      assert selected_run_ids(view, "comparison-left") == [to_string(second.id)]
      assert date_value(render(view), "input#comparison-from") == ""
      assert date_value(render(view), "input#comparison-to") == ""
    end

    test "?newer=<owned full run id> is selected as the candidate", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      publish_run!(organization, version, simple_zip())
      chosen = publish_run!(organization, version, left_zip())

      {:ok, view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          compare_path(version) <> "?newer=#{chosen.id}"
        )

      assert selected_run_ids(view, "comparison-right") == [to_string(chosen.id)]

      # The left side is the first comparable row distinct from the candidate,
      # so the page never compares a file with itself.
      [newest, second | _rest] = ExportRuns.list_comparable(organization.id)
      expected_left = if newest.id == chosen.id, do: second, else: newest
      assert selected_run_ids(view, "comparison-left") == [to_string(expected_left.id)]
    end

    test "a pathways run id and a foreign-org run id are ignored without error", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      publish_run!(organization, version, simple_zip())
      publish_run!(organization, version, left_zip())

      pathways = publish_pathways_run!(organization, version)

      foreign_organization = organization_fixture()

      foreign =
        publish_run!(
          foreign_organization,
          gtfs_version_fixture(foreign_organization.id),
          right_zip()
        )

      [newest, second | _rest] = ExportRuns.list_comparable(organization.id)

      for ignored <- [pathways, foreign] do
        {:ok, view, _html} =
          live(
            log_in_user(conn, user, organization: organization),
            compare_path(version) <> "?newer=#{ignored.id}"
          )

        assert selected_run_ids(view, "comparison-right") == [to_string(newest.id)]
        assert selected_run_ids(view, "comparison-left") == [to_string(second.id)]
        refute render(view) =~ ignored.id
      end

      # A malformed id is refused before it can reach the query, and the ordinary
      # defaults stand.
      {:ok, malformed_view, _html} =
        live(
          log_in_user(conn, user, organization: organization),
          compare_path(version) <> "?newer=not-a-uuid"
        )

      assert selected_run_ids(malformed_view, "comparison-right") == [to_string(newest.id)]
      assert selected_run_ids(malformed_view, "comparison-left") == [to_string(second.id)]
    end
  end

  describe "the comparison form states" do
    test "a range over 62 dates renders the error and starts no comparison", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      publish_run!(organization, version, left_zip())
      publish_run!(organization, version, right_zip())

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), compare_path(version))

      render_change(view, "select_comparison", %{
        "comparison" => %{"from" => "2026-10-12", "to" => "2027-01-12"}
      })

      assert has_element?(view, "#comparison-window-note", "Choose 62 dates or fewer")
      assert has_element?(view, "#comparison-window-note", "93")
      refute has_element?(view, "#comparison-progress")
      refute has_element?(view, "#comparison-status-title", "Comparing exports")
    end

    test "no comparable choices renders the empty state linking to the full export", context do
      %{conn: conn, user: user, organization: organization, version: version} = context

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), compare_path(version))

      assert has_element?(view, "#comparison-empty")
      assert has_element?(view, "#comparison-empty", "Export full feed")

      assert has_element?(
               view,
               "#comparison-export-full[href='/gtfs/#{version.id}/export?type=full']"
             )
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp compare_path(version), do: "/gtfs/#{version.id}/compare"

  # A real ready pathways run, so the `newer` guard rejects a resolvable run of
  # the wrong profile rather than an absent one. The bytes are never read: the
  # guard classifies the run, it does not compare it.
  defp publish_pathways_run!(organization, version) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :pathways)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "pathways.zip", simple_zip())

    {:ok, run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    run
  end

  defp selected_run_ids(view, id) do
    view
    |> element("form#export-comparison-form select##{id}")
    |> render()
    |> fragment()
    |> LazyHTML.query("select##{id} option[selected]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> to_string()))
  end

  defp date_value(html, selector) do
    html
    |> fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> to_string()))
    |> List.first()
  end

  defp fragment(html), do: LazyHTML.from_fragment(html)
end

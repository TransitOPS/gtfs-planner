defmodule GtfsPlannerWeb.DashboardRegionsTest do
  @moduledoc """
  One failed homepage region does not break the page, and "Try again" reloads
  only the region it names (AC-29, CR-7).

  Every case installs `GtfsPlanner.HomeSourceStub` as the page's read boundary
  through `:home_source` and names the `GtfsPlanner.Home` function that must
  raise in `:home_failing_functions`. Both are application-wide, so this case is
  `async: false` and `on_exit` restores their exact prior values.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.HomeSourceStub
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  @editor_role "pathways_studio_editor"

  setup do
    previous_source = Application.get_env(:gtfs_planner, :home_source)
    previous_failing = Application.get_env(:gtfs_planner, :home_failing_functions)

    on_exit(fn ->
      restore_env(:home_source, previous_source)
      restore_env(:home_failing_functions, previous_failing)
    end)

    :ok
  end

  describe "GTFS Planner regions" do
    test "a failed resume read renders its error while the check and share facts render", ctx do
      %{organization: organization, version: version, user: user} = planner_fixture()
      insert_check(organization, version, %{errors_count: 0, warnings_count: 12})
      conn = log_in_user(ctx.conn, user, organization: organization)

      install_stub([:resume])

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#region-error-resume", "Your recent changes could not load.")

      assert has_element?(
               view,
               "#region-error-resume",
               "Routes, calendars and stops still open from the menu. Nothing you saved is affected."
             )

      assert has_element?(view, "#region-error-retry-resume", "Try again")

      # The status and check regions still render their own facts.
      assert has_element?(view, "#home-lede", "no calendars yet")
      assert has_element?(view, "#check-badge", "No errors · 12 warnings")
      refute has_element?(view, "#region-error-check")
    end

    test "clearing the failure and clicking Try again reloads only the resume region", ctx do
      %{organization: organization, version: version, user: user} = planner_fixture()
      insert_check(organization, version, %{errors_count: 0, warnings_count: 12})
      stop_change(organization, version, user, "MKT", "Market Street 3rd")
      conn = log_in_user(ctx.conn, user, organization: organization)

      install_stub([:resume])

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#region-error-resume", "Your recent changes could not load.")

      # The resume failure is cleared and the check read is armed to fail: a
      # retry that reloaded the check too would render its error block.
      Application.put_env(:gtfs_planner, :home_failing_functions, [:check_and_share])

      view |> element("#region-error-retry-resume") |> render_click()
      render_async(view)

      refute has_element?(view, "#region-error-resume")
      assert has_element?(view, "#resume-latest", "Market Street 3rd")
      assert has_element?(view, "#resume-open[href='#{~p"/gtfs/#{version.id}/stops/MKT"}']")
      refute has_element?(view, "#region-error-check")
      assert has_element?(view, "#check-badge", "No errors · 12 warnings")
    end

    test "an unknown region value is ignored", ctx do
      %{organization: organization, user: user} = planner_fixture()
      conn = log_in_user(ctx.conn, user, organization: organization)

      install_stub([:resume])

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      # Clearing the failure makes a reload observable: a click that re-ran the
      # resume region would replace its error block with the loaded list.
      Application.put_env(:gtfs_planner, :home_failing_functions, [])

      view |> element("#region-error-retry-resume") |> render_click(%{"region" => "bogus"})

      assert has_element?(view, "#region-error-resume", "Your recent changes could not load.")
      assert has_element?(view, "#region-error-retry-resume", "Try again")
    end

    test "a retry naming the other page state's region is ignored", ctx do
      %{organization: organization, version: version, user: user} = planner_fixture()
      insert_check(organization, version, %{errors_count: 0, warnings_count: 12})
      conn = log_in_user(ctx.conn, user, organization: organization)

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      # `board` is a Pathways region; accepting it on the planner page would
      # start a board read whose answer has no board params to fold into.
      render_click(view, "retry", %{"region" => "board"})
      render_async(view)

      assert has_element?(view, "#home-planner")
      assert has_element?(view, "#check-badge", "No errors · 12 warnings")
      refute has_element?(view, "#board")
    end
  end

  describe "Station board statuses" do
    test "a failed statuses read renders Unavailable cells and – counts", ctx do
      %{organization: organization, version: version, user: user} = pathways_fixture()
      conn = log_in_user(ctx.conn, user, organization: organization)

      install_stub([:station_statuses])

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      # The board keeps its own facts and offers a scoped retry.
      assert has_element?(view, "#board-filter-all span", "1")
      assert has_element?(view, "#home-lede", "1 in #{version.name} · 1 have pathways")
      refute has_element?(view, "#home-lede", "no open issues")
      assert has_element?(view, "#board-row-UNS", "Union Station")

      assert has_element?(
               view,
               "#board",
               "Report and reachability status could not load."
             )

      assert has_element?(view, "#board", "Stations, levels and pathways are current.")
      assert has_element?(view, "#region-error-retry-statuses", "Try again")

      # Report and Reachability are the fourth and fifth cells of the row.
      cells = row_cells(view, "UNS")
      assert Enum.at(cells, 3) == "Unavailable"
      assert Enum.at(cells, 4) == "Unavailable"

      # Only the two stage counts that need the statuses read fall back to "–".
      assert has_element?(view, "#board-filter-not_started span", "0")
      assert has_element?(view, "#board-filter-in_progress span", "–")
      assert has_element?(view, "#board-filter-clean span", "–")
    end
  end

  # -- Fixtures --

  defp planner_fixture do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = member(organization, [@editor_role])

    # One stop, so the version is not a first-use one: the planner page renders
    # the editor-work grid the resume-failure cases inject into.
    _stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "REGION-STOP",
        stop_name: "Region Stop"
      })

    %{organization: organization, version: version, user: user}
  end

  # One Pathways station whose entrance is connected to its platform, so the
  # board row has a report and a reachability cell to degrade.
  defp pathways_fixture do
    organization = organization_fixture(%{name: "Regions Pathways Org", product: :pathways})
    version = gtfs_version_fixture(organization.id)
    user = member(organization, [@editor_role])
    level = level_fixture(organization.id, version.id, %{level_id: "L1"})

    station =
      stop_fixture(organization.id, version.id, %{
        stop_id: "UNS",
        stop_name: "Union Station",
        location_type: 1
      })

    entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "UNS_entrance_1",
        stop_name: "Union Station Entrance",
        location_type: 2,
        parent_station: "UNS",
        level_id: level.level_id
      })

    platform =
      stop_fixture(organization.id, version.id, %{
        stop_id: "UNS_platform_1",
        stop_name: "Union Station Platform",
        location_type: 0,
        parent_station: "UNS",
        level_id: level.level_id
      })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_mode: 5
    })

    %{organization: organization, version: version, user: user, station: station}
  end

  defp member(organization, roles) do
    user = user_fixture()

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: roles
      })

    user
  end

  defp stop_change(organization, version, actor, stop_id, stop_name) do
    stop_fixture(organization.id, version.id, %{stop_id: stop_id, stop_name: stop_name})

    insert_change_log(organization, version, %{
      entity_type: "stop",
      entity_external_id: stop_id,
      changed_fields: %{"stop_lat" => %{"from" => "40.71", "to" => "40.72"}},
      actor_id: actor.id,
      actor_email: actor.email,
      inserted_at: ~U[2026-09-20 12:00:00.000000Z]
    })
  end

  defp insert_change_log(organization, version, attrs) do
    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "trip",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "editor@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: organization.id,
          gtfs_version_id: version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        attrs
      )

    Repo.insert_all(ChangeLog, [row])
  end

  defp insert_check(organization, version, attrs) do
    attrs =
      Map.merge(
        %{
          run_type: "mobility_data",
          status: "completed",
          errors_count: 0,
          warnings_count: 0,
          infos_count: 0,
          started_at: ~U[2026-09-20 09:00:00.000000Z]
        },
        attrs
      )

    %ValidationRun{
      id: Ecto.UUID.generate(),
      organization_id: organization.id,
      gtfs_version_id: version.id
    }
    |> ValidationRun.changeset(attrs)
    |> Repo.insert!()
  end

  # -- Failure injection --

  # `GtfsPlanner.HomeSourceStub` delegates to `GtfsPlanner.Home` except for the
  # named functions, which raise before delegating.
  defp install_stub(failing_functions) do
    Application.put_env(:gtfs_planner, :home_source, HomeSourceStub)
    Application.put_env(:gtfs_planner, :home_failing_functions, failing_functions)
  end

  defp restore_env(key, nil), do: Application.delete_env(:gtfs_planner, key)
  defp restore_env(key, value), do: Application.put_env(:gtfs_planner, key, value)

  # -- Observation helpers --

  # `:statuses` starts only once `:board` answers, so the first wait cannot see
  # it; the second is a no-op when everything already settled.
  defp render_board(view) do
    render_async(view)
    render_async(view)
  end

  defp row_cells(view, stop_id) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#board-row-#{stop_id} td")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end

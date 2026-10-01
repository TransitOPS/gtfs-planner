defmodule GtfsPlannerWeb.DashboardPathwaysTest do
  @moduledoc """
  The Pathways station board (`#home-pathways`) through the real
  `GtfsPlanner.Home` read boundary.

  The fixture is one 14-station version covering every stage and reachability
  outcome, with two editing statuses, one resume change and the attention facts.
  Each case mounts `/` for an editor of a Pathways organization and awaits both
  async waves — `:statuses` starts only once `:board` answers, so the second
  `render_async/1` is the one that sees the finished page.
  """

  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export.Run, as: ExportRun
  alias GtfsPlanner.Gtfs.Import.Run, as: ImportRun
  alias GtfsPlanner.Gtfs.StationReport2.Outcome
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Home.ChangeLinks

  @editor_role "pathways_studio_editor"

  setup do
    organization = organization_fixture(%{name: "Pathways Board Org", product: :pathways})
    version = gtfs_version_fixture(organization.id)
    user = pathways_member(organization)

    %{organization: organization, version: version, user: user}
  end

  describe "Station board" do
    test "the board lists every station with the version-total filter counts", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      assert has_element?(view, "#home-title", "Stations")

      assert has_element?(
               view,
               "#home-lede",
               "14 in #{ctx.version.name} · 6 have pathways · 1 have no open issues"
             )

      assert has_element?(view, "#board-filter-all[aria-pressed='true']", "All")
      assert has_element?(view, "#board-filter-all span", "14")
      assert has_element?(view, "#board-filter-not_started", "Not started")
      assert has_element?(view, "#board-filter-not_started span", "8")
      assert has_element?(view, "#board-filter-in_progress", "In progress")
      assert has_element?(view, "#board-filter-in_progress span", "5")
      assert has_element?(view, "#board-filter-clean", "No open issues")
      assert has_element?(view, "#board-filter-clean span", "1")

      # The default order is last edited descending, then name, with 12 rows a
      # page.
      assert board_row_ids(view) == [
               "board-row-UNS",
               "board-row-HBP",
               "board-row-MKT",
               "board-row-APT",
               "board-row-BYF",
               "board-row-CDG",
               "board-row-CEN",
               "board-row-CVC",
               "board-row-ELM",
               "board-row-GRV",
               "board-row-PNS",
               "board-row-STQ"
             ]

      assert has_element?(
               view,
               "#board-count",
               "Showing 12 of 14 · most recently edited first, then by name"
             )
    end

    test "a station row shows its lines, report, reachability and last edit", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      # UNS is the clean station: two platforms served by two routes, one level
      # with one floorplan, a fresh passed run and a named last editor.
      assert has_element?(view, "#board-row-UNS", "Union Station")
      assert has_element?(view, "#board-row-UNS", "UNS · 2 lines")
      assert has_element?(view, "#board-row-UNS", "1 · 1 floorplan")
      assert has_element?(view, "#board-row-UNS", "No issues")
      assert has_element?(view, "#board-row-UNS", "5 of 5 pass")
      assert has_element?(view, "#board-row-UNS", "alex.kim@example.test")

      assert has_element?(
               view,
               "#board-row-UNS a[href='#{ChangeLinks.station_path(ctx.version.id, "UNS")}']"
             )

      # HBP's issue count is its own report's count, and its passed run predates
      # the station's latest change (AC-22, AC-23).
      assert issue_count(ctx, "HBP") > 0
      assert has_element?(view, "#board-row-HBP", "#{issue_count(ctx, "HBP")} issues")
      assert has_element?(view, "#board-row-HBP", "Edited since run")

      # MKT's run is a warning and PNS's failed; RVS, whose run is not
      # applicable, sits on the second page (asserted in the pager case).
      assert has_element?(view, "#board-row-MKT", "2 of 4 pass")
      assert has_element?(view, "#board-row-PNS", "1 of 4 pass")

      # A station with no pathways is Not started whatever its status, and a
      # never-edited station shows a dash.
      assert has_element?(view, "#board-row-CDG", "Not started")
      assert has_element?(view, "#board-row-CDG", "Not run")
      assert has_element?(view, "#board-row-APT", "—")
    end

    test "the not-started filter leaves only 0-pathway rows, ordered by name", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/?stage=not_started")
      render_board(view)

      assert has_element?(view, "#board-filter-not_started[aria-pressed='true']")

      assert board_row_ids(view) == [
               "board-row-APT",
               "board-row-BYF",
               "board-row-CDG",
               "board-row-CVC",
               "board-row-ELM",
               "board-row-GRV",
               "board-row-STQ",
               "board-row-WGT"
             ]

      assert has_element?(view, "#board-count", "Showing 8 of 8 · by name")
    end

    test "a filter click patches the URL and resets the rows", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      view |> element("#board-filter-not_started") |> render_click()
      assert_patch(view, "/?stage=not_started")

      assert has_element?(view, "#board-filter-not_started[aria-pressed='true']")
      refute has_element?(view, "#board-row-UNS")
      assert has_element?(view, "#board-row-CDG", "Not started")
    end

    test "the search form patches the URL and leaves only the matching station", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      view |> form("#board-search-form", %{"board" => %{"q" => "UNS"}}) |> render_change()
      assert_patch(view, "/?q=UNS")

      assert board_row_ids(view) == ["board-row-UNS"]
      assert has_element?(view, "#board-count", "Showing 1 of 1")
    end

    test "an invalid stage and page fall back to the default page", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/?stage=bogus&page=-3")
      render_board(view)

      assert has_element?(view, "#board-filter-all[aria-pressed='true']", "All")
      assert has_element?(view, "#board-filter-all span", "14")
      assert length(board_row_ids(view)) == 12
      assert has_element?(view, "#board-count", "Showing 12 of 14")
    end

    test "a page past the last one clamps to it", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/?page=9")
      render_board(view)

      assert board_row_ids(view) == ["board-row-RVS", "board-row-WGT"]
      assert has_element?(view, "#board-row-RVS", "0 of 0 pass")
      assert has_element?(view, "#board-count", "Showing 2 of 14")
      assert has_element?(view, "#board-prev[href='/']")
      refute has_element?(view, "#board-next")
    end

    test "a search with no match shows the empty state and its clear link", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/?q=ZZZ")
      render_board(view)

      assert has_element?(
               view,
               "#board-empty",
               "No station matches. Clear the search or choose another filter."
             )

      assert has_element?(view, "#board-empty-clear[href='/']", "Clear filters")
      assert board_row_ids(view) == []
    end

    test "a version with no stations renders the import panel as the only primary", ctx do
      conn = log_in(ctx)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      assert has_element?(view, "#firstuse-nofeed", "Import your GTFS feed first")

      assert has_element?(
               view,
               "#firstuse-import.bg-action[href='#{~p"/gtfs/#{ctx.version.id}/import"}']",
               "Import feed"
             )

      assert primaries(view) == ["Import feed"]
      assert has_element?(view, "#home-lede", "#{ctx.version.name} · no stops or stations yet")
      refute has_element?(view, "#board")
      refute has_element?(view, "#resume")
    end

    test "stations with no pathways keep the table as the chooser", ctx do
      conn = log_in(ctx)
      level = level_fixture(ctx.organization.id, ctx.version.id, %{level_id: "L1"})

      _airport = unmapped_station(ctx, level, "APT", "Airport")
      _bayfront = unmapped_station(ctx, level, "BYF", "Bayfront")

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      assert has_element?(
               view,
               "#board-guidance",
               "No station has pathways yet. Pick one below to start."
             )

      assert has_element?(view, "#home-lede", "2 in #{ctx.version.name} · none with pathways yet")
      assert has_element?(view, "#board-filter-not_started", "Not started")
      assert has_element?(view, "#board-filter-not_started span", "2")
      assert has_element?(view, "#board-row-APT", "1 · no floorplan")

      # The guidance sits above the table, and the rail keeps only the share
      # card: a new mapper has no changes to continue and nobody to coordinate
      # with yet.
      assert render(view) =~ ~r/id="board-guidance".*id="board-rows"/s
      refute has_element?(view, "#resume")
      refute has_element?(view, "#editing-now")
      assert has_element?(view, "#share")
    end

    test "a dead render shows the board and rail skeletons", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      html = conn |> get(~p"/") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert LazyHTML.query(document, "#board-loading") |> Enum.any?()
      assert LazyHTML.query(document, "#resume-loading") |> Enum.any?()
      assert LazyHTML.query(document, "#share-loading") |> Enum.any?()
      assert LazyHTML.query(document, "#attention-loading") |> Enum.any?()

      assert document |> LazyHTML.query("#home-lede") |> LazyHTML.text() == ctx.version.name
    end
  end

  describe "Station board rail" do
    test "Continue opens the station's floorplan and Editing now lists other people", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      assert has_element?(view, "#resume-title", "Continue where you left off")

      assert has_element?(
               view,
               "#resume-open.bg-action[href='#{~p"/gtfs/#{ctx.version.id}/stops/UNS/diagram?level=L2"}']",
               "Open floorplan"
             )

      assert primaries(view) == ["Open floorplan"]

      assert has_element?(view, "#editing-now", "Market Street")
      assert has_element?(view, "#editing-now", "Priya N")
      assert has_element?(view, "#editing-now", "since")

      # The viewer's own editing status is the row's marker, not a rail entry.
      refute has_element?(view, "#editing-station-UNS")
      assert has_element?(view, "#board-row-UNS", "editing now")

      assert has_element?(view, "#share", "No errors · 4 warnings")
      assert has_element?(view, "#share", "download expired")
      assert has_element?(view, "#share", "1 change, 1 station")
    end

    test "a member with no own changes sees the team list in the rail", ctx do
      board_fixture(ctx)
      viewer = member(ctx.organization, "team.viewer@example.test")
      conn = log_in_user(ctx.conn, viewer, organization: ctx.organization)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      assert has_element?(view, "#resume-title", "What your team changed recently")
      assert has_element?(view, "#resume-list", ctx.user.email)
      refute has_element?(view, "#resume-open")
    end
  end

  describe "Station board times" do
    test "the board and the rail show one change at the same agency-local time", ctx do
      agency_fixture(ctx.organization.id, ctx.version.id, %{agency_timezone: "America/New_York"})
      level = level_fixture(ctx.organization.id, ctx.version.id, %{level_id: "L1"})
      mapped_station(ctx, level, "UNS", "Union Station")

      change_log(ctx, %{
        entity_type: "stop",
        entity_external_id: "UNS",
        station_stop_id: "UNS",
        actor_id: ctx.user.id,
        actor_email: ctx.user.email,
        snapshot: %{"level_id" => "L1"},
        changed_fields: %{"stop_name" => %{"from" => "Old name", "to" => "Union Station"}},
        inserted_at: ~U[2026-03-10 10:28:00.000000Z]
      })

      viewer = member(ctx.organization, "team.viewer@example.test")
      conn = log_in_user(ctx.conn, viewer, organization: ctx.organization)

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      assert has_element?(view, "#board-row-UNS", "Mar 10, 6:28 AM")
      assert has_element?(view, "#resume-row-1", "Mar 10, 6:28 AM")
    end

    test "the rail's export day is the agency's calendar day", ctx do
      agency_fixture(ctx.organization.id, ctx.version.id, %{agency_timezone: "America/New_York"})
      station_row(ctx, "UNS", "Union Station")

      insert_export(ctx, %{
        finished_at: ~U[2026-03-10 02:30:00.000000Z],
        artifact_expires_at: ~U[2099-01-01 00:00:00.000000Z]
      })

      {:ok, view, _html} = live(log_in(ctx), ~p"/")
      render_board(view)

      assert has_element?(view, "#export-line", "Mar 9")
    end
  end

  describe "Station board attention" do
    test "the strip lists the check's errors and a stopped import only", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      check =
        insert_check(ctx, %{
          errors_count: 3,
          warnings_count: 4,
          started_at: ~U[2026-09-27 09:00:00.000000Z]
        })

      stopped_import(ctx, "October 2026 feed")

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      assert has_element?(view, "#attention", "The last check found 3 errors")
      assert has_element?(view, "#attention", "The import of “October 2026 feed” stopped partway")

      assert has_element?(
               view,
               "#attention-action-check[href='#{~p"/gtfs/#{ctx.version.id}/validation/#{check.id}"}']",
               "View the 3 errors"
             )

      assert has_element?(
               view,
               "#attention-action-import[href='#{~p"/gtfs/#{ctx.version.id}/import"}']",
               "Review import"
             )

      assert attention_item_count(view) == 2
    end

    test "an ending calendar raises no Pathways attention", ctx do
      conn = log_in(ctx)
      board_fixture(ctx)

      calendar_fixture(ctx.organization.id, ctx.version.id, %{
        service_id: "WKDY",
        start_date: Date.add(Date.utc_today(), -30),
        end_date: Date.add(Date.utc_today(), 10)
      })

      {:ok, view, _html} = live(conn, ~p"/")
      render_board(view)

      refute has_element?(view, "#attention")
    end
  end

  # -- Fixtures --

  defp log_in(ctx), do: log_in_user(ctx.conn, ctx.user, organization: ctx.organization)

  # The 14-station board: one clean station, five in progress (a stale passed
  # run, a warning run, no run, a failed run and a not-applicable run) and eight
  # with no pathways yet.
  defp board_fixture(ctx) do
    level = level_fixture(ctx.organization.id, ctx.version.id, %{level_id: "L1"})

    # UNS: two routes through one platform, one level with one floorplan, a
    # passed run newer than its latest change, and an editing status of the
    # viewer's own.
    {uns, uns_platform} = mapped_station(ctx, level, "UNS", "Union Station")
    serve(ctx, "5", "UNS-T5", uns_platform.stop_id)
    serve(ctx, "7", "UNS-T7", uns_platform.stop_id)
    floorplan(ctx, uns, level, "UNS-L1.png")

    run(ctx, "UNS", %{
      outcome: "passed",
      reachable: 5,
      pair_count: 5,
      completed_at: ~U[2026-09-27 09:00:05.000000Z],
      inserted_at: ~U[2026-09-27 09:00:00.000000Z]
    })

    change_log(ctx, %{
      station_stop_id: "UNS",
      actor_email: "alex.kim@example.test",
      inserted_at: ~U[2026-09-26 15:10:00.000000Z]
    })

    # HBP: one isolated entrance makes its report fail, and its passed run
    # predates the station's latest change.
    {hbp, _hbp_platform} = mapped_station(ctx, level, "HBP", "Harbor Point")
    _isolated = child_stop(ctx, level, "HBP_entrance_2", "HBP", 2, "Harbor Point Side Entrance")

    run(ctx, "HBP", %{
      outcome: "passed",
      reachable: 6,
      pair_count: 6,
      completed_at: ~U[2026-09-01 09:00:05.000000Z],
      inserted_at: ~U[2026-09-01 09:00:00.000000Z]
    })

    change_log(ctx, %{
      station_stop_id: "HBP",
      actor_email: "priya.n@example.test",
      inserted_at: ~U[2026-09-20 14:52:00.000000Z]
    })

    # MKT: a warning run and another user's editing status.
    {mkt, _mkt_platform} = mapped_station(ctx, level, "MKT", "Market Street")

    run(ctx, "MKT", %{
      outcome: "warning",
      reachable: 2,
      pair_count: 4,
      completed_at: ~U[2026-09-19 09:00:05.000000Z],
      inserted_at: ~U[2026-09-19 09:00:00.000000Z]
    })

    change_log(ctx, %{
      station_stop_id: "MKT",
      actor_email: "sam.o@example.test",
      inserted_at: ~U[2026-09-18 09:12:00.000000Z]
    })

    # CEN has pathways but no run; PNS's run failed; RVS's is not applicable.
    _cen = mapped_station(ctx, level, "CEN", "Central Station")

    _pns = mapped_station(ctx, level, "PNS", "Pine Street")

    run(ctx, "PNS", %{
      outcome: "failed",
      reachable: 1,
      pair_count: 4,
      completed_at: ~U[2026-09-10 09:00:05.000000Z],
      inserted_at: ~U[2026-09-10 09:00:00.000000Z]
    })

    _rvs = mapped_station(ctx, level, "RVS", "Riverside")

    run(ctx, "RVS", %{
      outcome: "not_applicable",
      reachable: 0,
      pair_count: 0,
      completed_at: ~U[2026-09-12 09:00:05.000000Z],
      inserted_at: ~U[2026-09-12 09:00:00.000000Z]
    })

    # Eight stations with no pathways yet, each with one level and no floorplan.
    for {stop_id, name} <- [
          {"CDG", "Cedar Grove"},
          {"ELM", "Elm Park"},
          {"WGT", "Westgate"},
          {"APT", "Airport"},
          {"BYF", "Bayfront"},
          {"CVC", "Civic Center"},
          {"GRV", "Grove Hill"},
          {"STQ", "Quarry Road"}
        ] do
      _unmapped = unmapped_station(ctx, level, stop_id, name)
    end

    editing_status(ctx, uns, ctx.user)
    editing_status(ctx, mkt, other_editor(ctx))

    insert_check(ctx, %{errors_count: 0, warnings_count: 4})
    insert_export(ctx, %{finished_at: ~U[2026-09-25 12:00:00.000000Z]})

    resume_change(ctx, ctx.user, "UNS", "L2")

    %{uns: uns, hbp: hbp, mkt: mkt}
  end

  defp pathways_member(organization) do
    member(organization, "board.editor@example.test")
  end

  defp member(organization, email) do
    user = user_fixture(%{email: email})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: [@editor_role]
      })

    user
  end

  defp other_editor(ctx), do: member(ctx.organization, "priya.n@example.test")

  defp station_row(ctx, stop_id, name) do
    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: stop_id,
      stop_name: name,
      location_type: 1
    })
  end

  defp child_stop(ctx, level, stop_id, parent_station, location_type, stop_name) do
    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: stop_id,
      stop_name: stop_name,
      location_type: location_type,
      parent_station: parent_station,
      level_id: level.level_id
    })
  end

  # A station whose entrance is connected to its platform: the report builders
  # find nothing to fail (the fixture step 10's parity test uses too). The ids
  # follow the report's own prefix convention (`<station>_entrance_` and
  # `<station>_platform_`), so the naming checks pass as well.
  defp mapped_station(ctx, level, stop_id, name) do
    station = station_row(ctx, stop_id, name)

    entrance =
      child_stop(ctx, level, "#{stop_id}_entrance_1", stop_id, 2, "#{name} Entrance")

    platform =
      child_stop(ctx, level, "#{stop_id}_platform_1", stop_id, 0, "#{name} Platform")

    pathway_fixture(
      ctx.organization.id,
      ctx.version.id,
      entrance.stop_id,
      platform.stop_id,
      %{pathway_mode: 5}
    )

    {station, platform}
  end

  defp unmapped_station(ctx, level, stop_id, name) do
    station = station_row(ctx, stop_id, name)

    platform =
      child_stop(ctx, level, "#{stop_id}_platform_1", stop_id, 0, "#{name} Platform")

    {station, platform}
  end

  defp serve(ctx, route_short_name, trip_id, stop_id) do
    route =
      route_fixture(ctx.organization.id, ctx.version.id, %{
        route_id: "R#{route_short_name}",
        route_short_name: route_short_name,
        route_long_name: "Route #{route_short_name}"
      })

    trip = trip_fixture(ctx.organization.id, ctx.version.id, route.route_id, %{trip_id: trip_id})
    stop_time_fixture(ctx.organization.id, ctx.version.id, trip.trip_id, stop_id)
  end

  defp floorplan(ctx, station, level, diagram_filename) do
    {:ok, stop_level} =
      insert_stop_level(%{
        stop_id: station.id,
        level_id: level.id,
        diagram_filename: diagram_filename,
        organization_id: ctx.organization.id,
        gtfs_version_id: ctx.version.id
      })

    stop_level
  end

  defp run(ctx, station_stop_id, attrs) do
    attrs =
      Map.merge(
        %{
          status: "completed",
          completed_at: ~U[2026-09-01 09:00:05.000000Z],
          inserted_at: ~U[2026-09-01 09:00:00.000000Z]
        },
        attrs
      )

    %ValidationRun{organization_id: ctx.organization.id, gtfs_version_id: ctx.version.id}
    |> ValidationRun.changeset(%{
      run_type: "station_reachability",
      status: attrs.status,
      started_at: attrs.inserted_at,
      completed_at: attrs.completed_at,
      error_details: nil,
      result_json: %{
        "metadata" => %{"station_stop_id" => station_stop_id},
        "outcome" => attrs.outcome,
        "totals" => %{"reachable" => attrs.reachable, "pair_count" => attrs.pair_count}
      }
    })
    |> Ecto.Changeset.put_change(:inserted_at, attrs.inserted_at)
    |> Repo.insert!()
  end

  defp editing_status(ctx, station, user) do
    station_editing_status_fixture(ctx.organization, ctx.version, station, user)
  end

  # One stop edit on a station level: the rail's Continue item, whose link must
  # carry the GTFS level id (INV-6).
  defp resume_change(ctx, user, stop_id, level_id) do
    change_log(ctx, %{
      entity_type: "stop",
      entity_external_id: stop_id,
      station_stop_id: stop_id,
      actor_id: user.id,
      actor_email: user.email,
      snapshot: %{"level_id" => level_id},
      changed_fields: %{"stop_name" => %{"from" => "Old name", "to" => "Union Station"}},
      inserted_at: ~U[2026-09-22 10:00:00.000000Z]
    })
  end

  defp change_log(ctx, attrs) do
    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "pathway",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "editor@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: ctx.organization.id,
          gtfs_version_id: ctx.version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        attrs
      )

    Repo.insert_all(ChangeLog, [row])
  end

  defp insert_check(ctx, attrs) do
    attrs =
      Map.merge(
        %{
          run_type: "mobility_data",
          status: "completed",
          errors_count: 0,
          warnings_count: 0,
          infos_count: 0,
          started_at: ~U[2026-09-25 09:00:00.000000Z]
        },
        attrs
      )

    %ValidationRun{
      id: Ecto.UUID.generate(),
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id
    }
    |> ValidationRun.changeset(attrs)
    |> Repo.insert!()
  end

  # A ready :pathways export the sweep has not reached yet: its artifact expired
  # before now and its finished_at bounds the since count (AC-19).
  defp insert_export(ctx, attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      export_type: :pathways,
      state: :ready,
      phase: :cleanup,
      artifact_key: "exports/#{Ecto.UUID.generate()}.zip",
      artifact_filename: "pathways.zip",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1024,
      artifact_expires_at: ~U[2026-09-26 12:00:00.000000Z],
      started_at: ~U[2026-09-25 11:50:00.000000Z],
      finished_at: ~U[2026-09-25 12:00:00.000000Z],
      inserted_at: ~U[2026-09-25 12:00:00.000000Z],
      updated_at: ~U[2026-09-25 12:00:00.000000Z]
    }

    Repo.insert!(struct!(ExportRun, Map.merge(defaults, attrs)))
  end

  defp stopped_import(ctx, version_name) do
    {:ok, version} =
      Versions.create_staging_gtfs_version(ctx.organization.id, %{name: version_name})

    Repo.insert!(
      struct!(ImportRun, %{
        organization_id: ctx.organization.id,
        gtfs_version_id: version.id,
        version_name: version_name,
        state: "failed",
        failed_file: "stop_times.txt",
        failed_row: 18_204,
        committed_counts: %{},
        counts_complete: true,
        finished_at: ~U[2026-09-25 05:00:00.000000Z]
      })
    )
  end

  defp issue_count(ctx, station_stop_id) do
    {:ok, snapshot} =
      Gtfs.get_station_report_snapshot(ctx.organization.id, ctx.version.id, station_stop_id)

    Outcome.counts(Outcome.report_items(snapshot)).failed
  end

  # `:statuses` starts only once `:board` answers, so the first wait cannot see
  # it; the second is a no-op when everything already settled. Under the full
  # suite's database load the board's reads can outlast `render_async/1`'s
  # default 100 ms wait.
  defp render_board(view) do
    render_async(view, 2_000)
    render_async(view, 2_000)
  end

  defp board_row_ids(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#board-rows tr[id]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> List.first()))
  end

  defp attention_item_count(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#attention li")
    |> Enum.count()
  end

  defp primaries(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(".bg-action")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end

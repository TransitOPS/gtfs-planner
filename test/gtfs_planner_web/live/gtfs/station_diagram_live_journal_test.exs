defmodule GtfsPlannerWeb.Gtfs.StationDiagramLiveJournalTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    gtfs_version = gtfs_version_fixture(organization.id)

    station =
      stop_fixture(organization.id, gtfs_version.id, %{
        stop_id: "STATION_1",
        stop_name: "Test Station",
        location_type: 1
      })

    level =
      level_fixture(organization.id, gtfs_version.id, %{
        level_id: "L1",
        level_name: "Level 1",
        level_index: 0.0
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
        organization_id: organization.id,
        gtfs_version_id: gtfs_version.id,
        stop_id: station.id,
        level_id: level.id
      })

    %{
      user: user,
      organization: organization,
      gtfs_version: gtfs_version,
      station: station,
      level: level,
      stop_level: stop_level
    }
  end

  defp entry_fixture(org, version, station, author, attrs) do
    base = %{
      "id" => Ecto.UUID.generate(),
      "organization_id" => org.id,
      "gtfs_version_id" => version.id,
      "station_id" => station.id,
      "author_id" => author.id,
      "target_type" => "station",
      "body" => "a note",
      "captured_at" => "2026-06-20T10:00:00Z"
    }

    {:ok, entry} = Gtfs.upsert_journal_entry(Map.merge(base, attrs))
    entry
  end

  defp open_diagram(conn, ctx) do
    conn = log_in_user(conn, ctx.user, organization: ctx.organization)

    {:ok, view, _html} =
      live(conn, "/gtfs/#{ctx.gtfs_version.id}/stops/#{ctx.station.stop_id}/diagram",
        on_error: :warn
      )

    view
  end

  defp open_panel(view) do
    view |> element("button[phx-click='open_journal_panel']") |> render_click()
  end

  test "the journal panel lists station entries with body + author", %{conn: conn} = ctx do
    entry_fixture(ctx.organization, ctx.gtfs_version, ctx.station, ctx.user, %{
      "body" => "platform gap on the eastbound side"
    })

    html = ctx |> then(&open_diagram(conn, &1)) |> open_panel()

    assert html =~ "platform gap on the eastbound side"
    assert html =~ ctx.user.email
  end

  test "closing an entry stamps closed_at/closed_by and keeps it listed", %{conn: conn} = ctx do
    entry =
      entry_fixture(ctx.organization, ctx.gtfs_version, ctx.station, ctx.user, %{
        "body" => "needs signage"
      })

    view = open_diagram(conn, ctx)
    open_panel(view)

    html =
      view
      |> element("button[phx-click='close_journal_entry'][phx-value-id='#{entry.id}']")
      |> render_click()

    # Still in the list (never hidden), now with the closed treatment + Reopen.
    assert html =~ "journal-entry-#{entry.id}"
    assert html =~ "Closed"
    assert html =~ "Reopen"

    reloaded = Repo.get(JournalEntry, entry.id)
    assert reloaded.closed_at
    assert reloaded.closed_by == ctx.user.id
  end

  test "reopening a closed entry clears its closed state", %{conn: conn} = ctx do
    entry =
      entry_fixture(ctx.organization, ctx.gtfs_version, ctx.station, ctx.user, %{
        "closed_at" => "2026-06-21T10:00:00Z",
        "closed_by" => ctx.user.id
      })

    view = open_diagram(conn, ctx)
    open_panel(view)

    view
    |> element("button[phx-click='reopen_journal_entry'][phx-value-id='#{entry.id}']")
    |> render_click()

    reloaded = Repo.get(JournalEntry, entry.id)
    refute reloaded.closed_at
    refute reloaded.closed_by
  end

  test "a pin entry renders a marker on the active level diagram", %{conn: conn} = ctx do
    # The overlay (and pin layer) only render when the active level has a diagram.
    ctx.stop_level
    |> Ecto.Changeset.change(diagram_filename: "floorplan.png")
    |> Repo.update!()

    pin =
      entry_fixture(ctx.organization, ctx.gtfs_version, ctx.station, ctx.user, %{
        "target_type" => "pin",
        "stop_level_id" => ctx.stop_level.id,
        "diagram_x" => 40.0,
        "diagram_y" => 60.0,
        "body" => "broken wayfinding sign"
      })

    html = conn |> open_diagram(ctx) |> render()

    assert html =~ ~s(data-journal-pin-id="#{pin.id}")
  end

  test "the Journal button shows an open-entry count badge", %{conn: conn} = ctx do
    entry_fixture(ctx.organization, ctx.gtfs_version, ctx.station, ctx.user, %{"body" => "one"})

    entry_fixture(ctx.organization, ctx.gtfs_version, ctx.station, ctx.user, %{
      "body" => "two, already closed",
      "closed_at" => "2026-06-21T10:00:00Z",
      "closed_by" => ctx.user.id
    })

    html = conn |> open_diagram(ctx) |> render()

    # Two entries, one closed → the badge counts the single open one.
    assert html =~ ~r/badge badge-sm badge-warning[^>]*>\s*1\s*</
  end
end

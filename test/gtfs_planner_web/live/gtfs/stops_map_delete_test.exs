defmodule GtfsPlannerWeb.Gtfs.StopsMapDeleteTest do
  @moduledoc """
  Tests for the delete panels.

  What is claimed here is the shape of the answer, not just the write: a stop a
  timetable depends on is refused with every dependent listed and a link to each
  place that dependent is edited, and with no delete button beside it at all; a
  station's own structure blocks the same way; a stop nothing uses is confirmed
  with the rows that go named, and the delete removes the stop; and a reference
  that appears while the confirmation is open refuses the delete and refreshes
  the list the editor was shown.

  The last case is the one that would pass behind a "the command refuses"
  assertion. What is checked is that the panel says *nothing was deleted* and
  shows the reference that arrived, because a refusal that still showed the old
  list would ask the editor the same question about facts that no longer hold.

  The distances and counts are literals, and the seeds are written through the
  same tables the commands read.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox, only: [set_mox_global: 1]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.GeocodingMock
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.ReliefPoint
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Translation
  alias GtfsPlanner.Repo

  setup :set_mox_global

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    ctx = %{
      organization: organization,
      version: version,
      editor: editor,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }

    {:ok, Map.put(ctx, :fixture, seeded(ctx))}
  end

  describe "a stop something uses" do
    test "delete on 1434 lists the patterns and the run, with no delete button", ctx do
      view = open_stop(ctx, "1434")

      view |> element("#stops-map-edit-more") |> render_click()
      view |> element("#stops-map-edit-delete") |> render_click()

      assert settle(view) |> has_element?("#stops-map-delete-panel")
      assert has_element?(view, "#stops-map-delete-blocked-list")

      # The message names the service, which is what stopping here costs.
      assert view |> element("#stops-map-delete-blocked-message") |> render() =~
               "weekday trips stop here"

      # Each dependent is named, and the ones that live somewhere else link to
      # it: a pattern to the pattern editor, a run to the runs page.
      assert has_element?(view, "#stops-map-delete-blocked-pattern-MOVE_P")
      assert has_element?(view, "#stops-map-delete-open-pattern-MOVE_P", "Open")
      assert has_element?(view, "[id^='stops-map-delete-blocked-run-']")
      assert has_element?(view, "[id^='stops-map-delete-open-run-']", "Open")

      # No primary action beside rows that would refuse the delete.
      refute has_element?(view, "#stops-map-delete-go")
      assert has_element?(view, "#stops-map-delete-keep", "Back to stop")
      assert has_element?(view, "#stops-map-delete-close", "Close")

      # Nothing was written by asking.
      assert stop_exists?(ctx, "1434")
    end

    test "delete on the station lists its level and journal entries as blocking", ctx do
      view = open_stop(ctx, "ST-NTC")

      view |> element("#stops-map-edit-more") |> render_click()
      assert has_element?(view, "#stops-map-edit-delete", "Delete station…")

      view |> element("#stops-map-edit-delete") |> render_click()

      assert settle(view) |> has_element?("#stops-map-delete-blocked-list")
      assert has_element?(view, "#stops-map-delete-blocked-stop_levels")
      assert has_element?(view, "#stops-map-delete-blocked-journal_entries")
      refute has_element?(view, "#stops-map-delete-go")
      assert stop_exists?(ctx, "ST-NTC")
    end
  end

  describe "a stop nothing uses" do
    test "1531 confirms with the Spanish name named, and deleting removes the stop", ctx do
      view = open_stop(ctx, "1531")

      view |> element("#stops-map-edit-more") |> render_click()
      view |> element("#stops-map-edit-delete") |> render_click()

      assert settle(view) |> has_element?("#stops-map-delete-panel")
      assert has_element?(view, "#stops-map-delete-clear")
      assert has_element?(view, "[id^='stops-map-delete-removed-translations-']")

      assert view |> element("#stops-map-delete-removed") |> render() =~
               "Spanish name"

      assert view |> element("#stops-map-delete-removed") |> render() =~
               "Bulevar SE Bay y SE Moore Dr"

      view |> element("#stops-map-delete-go") |> render_click()

      assert settle(view) |> has_element?("#stops-map-panel")
      refute has_element?(view, "#stops-map-delete-panel")
      refute has_element?(view, "#stops-map-edit-delete")
      refute stop_exists?(ctx, "1531")

      # The confirmation named a row that went with it.
      refute translation_exists?(ctx, "1531")
    end

    test "a review that cannot be read says so and offers no delete", ctx do
      view = open_stop(ctx, "1531")

      # The editor loses the role after the panel opened, so the review the
      # delete button asks for is refused rather than answered.
      Repo.update_all(
        from(m in UserOrgMembership, where: m.user_id == ^ctx.editor.id),
        set: [roles: []]
      )

      view |> element("#stops-map-edit-more") |> render_click()
      view |> element("#stops-map-edit-delete") |> render_click()

      assert settle(view) |> has_element?("#stops-map-delete-failed-message")
      assert has_element?(view, "#stops-map-delete-heading", "Delete")
      refute has_element?(view, "#stops-map-delete-go")

      view |> element("#stops-map-delete-keep") |> render_click()

      assert has_element?(view, "#stops-map-edit-panel")
      assert stop_exists?(ctx, "1531")
    end

    test "keeping the stop writes nothing and returns to the form", ctx do
      view = open_stop(ctx, "1531")

      view |> element("#stops-map-edit-more") |> render_click()
      view |> element("#stops-map-edit-delete") |> render_click()

      assert settle(view) |> has_element?("#stops-map-delete-go")

      view |> element("#stops-map-delete-keep") |> render_click()

      assert has_element?(view, "#stops-map-edit-panel")
      refute has_element?(view, "#stops-map-delete-panel")
      assert stop_exists?(ctx, "1531")
    end

    test "a reference added after the confirm opened deletes nothing and refreshes the list",
         ctx do
      view = open_stop(ctx, "1531")

      view |> element("#stops-map-edit-more") |> render_click()
      view |> element("#stops-map-edit-delete") |> render_click()

      assert settle(view) |> has_element?("#stops-map-delete-go")

      add_transfer(ctx)

      view |> element("#stops-map-delete-go") |> render_click()

      assert settle(view) |> has_element?("#stops-map-delete-refused")

      assert view |> element("#stops-map-delete-refused-message") |> render() =~
               "Nothing was deleted."

      # The refreshed list is the one the command refused against: the transfer
      # that arrived is now named as a row that would be removed, so the editor
      # is asked again rather than being offered the same answer.
      assert has_element?(view, "#stops-map-delete-removed")
      assert view |> element("#stops-map-delete-removed") |> render() =~ "Transfer rule to"
      assert stop_exists?(ctx, "1531")
      assert transfer_exists?(ctx, "1531")
    end
  end

  # --- fixture ---------------------------------------------------------------

  # Three stops: one a pattern and a relief point depend on, one a station with
  # the structure that blocks a delete, and one nothing uses but a translation.
  defp seeded(ctx) do
    stops =
      Map.new(
        [
          {"1434", "Main St", 44.6210, 0},
          {"1531", "SE Bay Blvd & SE Moore Dr", 44.6300, 0},
          {"ST-NTC", "Newport Transit Center", 44.6100, 1}
        ],
        fn {id, name, lat, location_type} ->
          {id,
           stop_fixture(ctx.organization.id, ctx.version.id, %{
             stop_id: id,
             stop_name: name,
             location_type: location_type,
             stop_lat: Decimal.from_float(lat),
             stop_lon: Decimal.from_float(-124.0530)
           })}
        end
      )

    route = route_fixture(ctx.organization.id, ctx.version.id, %{route_short_name: "1"})
    calendar = calendar_fixture(ctx.organization.id, ctx.version.id, %{service_id: "WEEKDAYS"})

    pattern =
      route_pattern_fixture(ctx.organization.id, ctx.version.id, %{
        route_pattern_id: "MOVE_P",
        route_id: route.route_id,
        direction_id: 0,
        headsign: "To Main St"
      })

    route_pattern_stop_fixture(pattern, "1434", 1)

    trip =
      trip_fixture(ctx.organization.id, ctx.version.id, route.route_id, %{
        trip_id: "DELETE-TRIP",
        service_id: calendar.service_id
      })

    timing = timed_pattern_fixture(pattern)

    trip
    |> Ecto.Changeset.change(
      route_pattern_id: pattern.route_pattern_id,
      pattern_derivation_state: "linked",
      timed_pattern_id: timing.id
    )
    |> Repo.update!()

    stop_time_fixture(ctx.organization.id, ctx.version.id, "DELETE-TRIP", "1434", %{
      stop_sequence: 1
    })

    Repo.insert!(%ReliefPoint{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      stop_id: "1434",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    Repo.insert!(%Translation{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      table_name: "stops",
      field_name: "stop_name",
      language: "es",
      translation: "Bulevar SE Bay y SE Moore Dr",
      record_id: "1531",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })

    station_level(ctx, stops["ST-NTC"])

    Map.put(stops, :organization, ctx.organization)
  end

  # A station's structure: a floorplan row and a journal entry, both matched on
  # the station's `stops.id` rather than its GTFS ID.
  defp station_level(ctx, station) do
    level =
      level_fixture(ctx.organization.id, ctx.version.id, %{
        level_id: "ST_NTC_L0",
        level_name: "Ground",
        level_index: 0.0
      })

    {:ok, _stop_level} =
      GtfsPlanner.GtfsFixtures.insert_stop_level(%{
        organization_id: ctx.organization.id,
        gtfs_version_id: ctx.version.id,
        stop_id: station.id,
        level_id: level.id
      })

    Repo.insert!(%JournalEntry{
      id: Ecto.UUID.generate(),
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      station_id: station.id,
      author_id: Ecto.UUID.generate(),
      target_type: "node",
      target_id: level.id,
      body: "Concourse note",
      captured_at: DateTime.utc_now()
    })
  end

  defp add_transfer(ctx) do
    Repo.insert!(%Transfer{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      from_stop_id: "1531",
      to_stop_id: "1434",
      transfer_type: 0,
      min_transfer_time: 180
    })
  end

  defp stop_exists?(ctx, stop_id) do
    Repo.exists?(
      from(s in Stop,
        where:
          s.organization_id == ^ctx.organization.id and s.gtfs_version_id == ^ctx.version.id and
            s.stop_id == ^stop_id
      )
    )
  end

  defp translation_exists?(ctx, stop_id) do
    Repo.exists?(
      from(t in Translation,
        where:
          t.organization_id == ^ctx.organization.id and t.gtfs_version_id == ^ctx.version.id and
            t.record_id == ^stop_id
      )
    )
  end

  defp transfer_exists?(ctx, stop_id) do
    Repo.exists?(
      from(t in Transfer,
        where:
          t.organization_id == ^ctx.organization.id and t.gtfs_version_id == ^ctx.version.id and
            t.from_stop_id == ^stop_id
      )
    )
  end

  # The review is read, and the apply writes and reloads the model behind it.
  # Each round is a call to the LiveView process, which puts it behind every
  # message already queued.
  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 5_000)
    settle(view, rounds - 1)
  end

  defp open_stop(ctx, stop_id) do
    path = "/gtfs/#{ctx.version.id}/stops/map?stop=#{stop_id}"
    {:ok, view, _html} = live(ctx.editor_conn, path)
    settle(view)

    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)
    Mox.allow(GeocodingMock, self(), view.pid)

    assert has_element?(view, "#stops-map-edit-panel")

    view
  end
end

defmodule GtfsPlannerWeb.Gtfs.StopsMapEditTest do
  @moduledoc """
  Merge evidence (EV-30) for the stop edit panel: opening a stop from the three
  ways in, its fields, the read-only fare zone, what else uses it, the dirty
  footer, the unsaved-changes guard on every exit, a stale save and a failed
  save.

  The expectations are literals from the card's cases and from the fixture rows:
  the stop names, IDs, zone and sign number are the ones written in below, and
  the other editor's email is the one the conflicting write was audited with.

  The write path is exercised through the real command rather than by poking
  assigns, so a case that passes here is a case where the panel, the LiveView and
  `StopEditing.update_stop/4` agree — which is the whole claim.

  The focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_sa28 ELIXIR_ERL_OPTIONS="+S 4" mix test test/gtfs_planner_web/live/gtfs/stops_map_edit_test.exs`.
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
  alias GtfsPlanner.GeocodingMock
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
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

    %{
      organization: organization,
      version: version,
      editor: editor,
      editor_conn: log_in_user(build_conn(), editor, organization: organization)
    }
  end

  describe "opening a stop" do
    test "?stop= opens the edit panel with the stop's own fields", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      assert has_element?(view, "#stops-map-edit-panel", "US 101 & SE 1st St")
      assert has_element?(view, "#stops-map-edit-panel", "Stop · ID 1434")
      # Seeded from the loaded row rather than from a default: a form that opens
      # blank beside a heading that names the stop is two different stops.
      assert has_element?(view, "#stops-map-edit-name[value='US 101 & SE 1st St']")
      assert has_element?(view, "#stops-map-edit-code[value='1434']")
      assert has_element?(view, "#stops-map-edit-wb-1[checked]")

      # Route badges are on the heading: "which bus stops here" is the first
      # question about a stop, and the model already holds the answer.
      assert has_element?(view, "#stops-map-edit-panel", "1")
      assert has_element?(view, "#stops-map-edit-where")
    end

    test "a stop of another version is not opened by its ID", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "does-not-exist")

      refute has_element?(view, "#stops-map-edit-panel")
      assert has_element?(view, "#stops-map-panel")
    end

    test "choosing a row in the browse list opens the same panel", ctx do
      seeded(ctx)

      view = open_map(ctx)

      assert has_element?(view, "#stops-map-row-1434")
      view |> element("#stops-map-row-1434") |> render_click()

      assert has_element?(view, "#stops-map-edit-panel", "US 101 & SE 1st St")
    end

    test "a stop a search returns opens the same panel", ctx do
      seeded(ctx)

      view = open_map(ctx)

      view
      |> form("#stops-map-search", %{"search" => %{"query" => "NE 7th"}})
      |> render_change()

      assert has_element?(view, "#stops-map-search-results")
      view |> element("#stops-map-search-results-stop-1330 button") |> render_click()

      assert has_element?(view, "#stops-map-edit-panel", "US 101 & NE 7th St")
    end
  end

  describe "the panel's fields" do
    test "the fare zone is text with a link, and there is no zone control", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      assert has_element?(view, "#stops-map-edit-zone", "Newport local")

      assert view
             |> element("#stops-map-edit-panel a[href$='/settings/fares']")
             |> render() =~ "Settings"

      # The zone belongs to Settings › Fares (AC-STOP-023), so a control here
      # would offer a choice this page cannot honour.
      refute has_element?(view, "#stops-map-edit-zone select")
      refute has_element?(view, "#stops-map-edit-panel select[name*='zone']")
    end

    test "an unserved stop says so and offers no keep-in-feed choice", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1531")

      assert has_element?(view, "#stops-map-edit-panel", "Not served")
      # Context decision 4: there is no export change in this package, so the
      # prototype's checkbox would be a control that changes nothing.
      refute has_element?(view, "#stops-map-keep-in-feed")
      refute has_element?(view, "input[name*='keep']")
    end

    test "where it's used lists what schedules a visit and says when nothing does", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")
      settle(view)

      assert has_element?(view, "#stops-map-edit-used-items")
      assert has_element?(view, "#stops-map-edit-used-pattern-BROWSER_SM_NB", "toward Newport")

      unserved = open_map(ctx, stop: "1531")
      settle(unserved)

      assert has_element?(
               unserved,
               "#stops-map-edit-used-empty",
               "Nothing uses this stop"
             )
    end

    test "a station lists its bays", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1500")
      settle(view)

      assert has_element?(view, "#stops-map-edit-panel", "Station · ID 1500")
      assert has_element?(view, "#stops-map-edit-bay-items")
    end
  end

  describe "the unsaved-changes guard" do
    test "a clean form exits without a question", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")
      view |> element("#stops-map-edit-cancel") |> render_click()

      assert has_element?(view, "#stops-map-panel")
      refute has_element?(view, "#stops-map-discard[data-open=true]")
    end

    test "a changed field marks the footer and disables nothing else", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      assert has_element?(view, "#stops-map-edit-status", "No changes yet")
      assert has_element?(view, "#stops-map-edit-save[disabled]")

      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_desc" => "By the post office"}})
      |> render_change()

      assert has_element?(view, "#stops-map-edit-status", "Unsaved changes")
      refute has_element?(view, "#stops-map-edit-save[disabled]")
      # The draft is the server's, so a re-render cannot take it back out.
      assert has_element?(view, "#stops-map-edit-desc[value='By the post office']")
    end

    test "Cancel on a dirty form asks, and Discard returns to the browse panel", ctx do
      seeded(ctx)

      view = dirty_view(ctx)
      view |> element("#stops-map-edit-cancel") |> render_click()

      assert has_element?(view, "#stops-map-discard[data-open=true]", "Discard changes to US 101")
      # Still the same stop, still holding the draft: the question has not been
      # answered yet.
      assert has_element?(view, "#stops-map-edit-panel")

      view |> element("#stops-map-discard-go") |> render_click()

      assert has_element?(view, "#stops-map-panel")
      refute has_element?(view, "#stops-map-edit-panel")
    end

    test "Keep editing drops the draft's exit and keeps the draft", ctx do
      seeded(ctx)

      view = dirty_view(ctx)
      view |> element("#stops-map-edit-cancel") |> render_click()

      assert has_element?(view, "#stops-map-discard[data-open=true]")
      view |> element("#stops-map-discard-keep") |> render_click()

      refute has_element?(view, "#stops-map-discard[data-open=true]")
      assert has_element?(view, "#stops-map-edit-panel")
      assert has_element?(view, "#stops-map-edit-desc[value='By the post office']")
    end

    test "choosing another stop while dirty asks, and Discard opens that stop", ctx do
      seeded(ctx)

      view = dirty_view(ctx)

      # The map and the checks both name a stop, so the choice arrives as an
      # event naming it — the same event a search result row pushes.
      render_hook(view, "select_stop", %{"stop_id" => "1330"})

      assert has_element?(view, "#stops-map-discard[data-open=true]")
      assert has_element?(view, "#stops-map-edit-panel", "US 101 & SE 1st St")

      view |> element("#stops-map-discard-go") |> render_click()

      assert has_element?(view, "#stops-map-edit-panel", "US 101 & NE 7th St")
    end

    test "Escape on a dirty form asks the same question", ctx do
      seeded(ctx)

      view = dirty_view(ctx)

      render_hook(view, "edit_escape", %{"key" => "Escape"})

      assert has_element?(view, "#stops-map-discard[data-open=true]", "Discard changes to US 101")
    end

    test "Escape on a clean form leaves without a question", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")
      render_hook(view, "edit_escape", %{"key" => "Escape"})

      refute has_element?(view, "#stops-map-discard[data-open=true]")
      assert has_element?(view, "#stops-map-panel")
    end
  end

  describe "saving" do
    test "a save writes the change through the audited command", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      view
      |> form("#stops-map-edit-form", %{
        "stop" => %{"stop_desc" => "By the post office", "stop_name" => "US 101 & SE 1st St"}
      })
      |> render_submit()

      settle(view)

      stop = Repo.get_by!(Stop, stop_id: "1434")
      assert stop.stop_desc == "By the post office"

      # The audit entry is written in the same transaction (INV-2), and the
      # panel reloads the model so the list and the map show the new row.
      log =
        Repo.all(
          from(l in ChangeLog,
            where: l.entity_type == "stop" and l.entity_external_id == "1434",
            select: %{action: l.action, actor_email: l.actor_email}
          )
        )

      assert [%{action: "updated", actor_email: actor_email}] = log
      assert actor_email == ctx.editor.email

      assert has_element?(view, "#stops-map-edit-panel")
      assert has_element?(view, "#stops-map-edit-status", "No changes yet")
    end

    test "a save posts the loaded updated_at, so a second save is not stale", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_desc" => "First"}})
      |> render_submit()

      settle(view)

      # Without the loaded `updated_at` posted back this second save would be
      # refused as stale against the first one's write.
      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_desc" => "Second"}})
      |> render_submit()

      settle(view)

      assert Repo.get_by!(Stop, stop_id: "1434").stop_desc == "Second"
    end

    test "a stop ID posted with the form does not change the stop's ID", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      # A forged event rather than a form post: the browser cannot add a field
      # the form does not render, which is exactly the point being tested.
      render_hook(view, "save_stop", %{
        "stop" => %{"stop_desc" => "Renamed by a forged param", "stop_id" => "9999"}
      })

      settle(view)

      assert Repo.get_by!(Stop, stop_id: "1434").stop_desc == "Renamed by a forged param"
      refute Repo.get_by(Stop, stop_id: "9999")
    end

    test "a stale save shows the conflict and writes nothing", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_desc" => "Mine"}})
      |> render_change()

      # Another editor saves the same stop first, audited under their own name.
      other = other_editor_write(ctx, "1434", %{"stop_desc" => "Northbound, by Post Office"})

      view |> form("#stops-map-edit-form") |> render_submit()
      settle(view)

      assert has_element?(view, "#stops-map-edit-conflict", other.email)
      # Their write is the one that stands, and the draft that asked to
      # overwrite it is still here rather than discarded.
      assert Repo.get_by!(Stop, stop_id: "1434").stop_desc == "Northbound, by Post Office"
      assert has_element?(view, "#stops-map-edit-desc[value='Mine']")
    end

    test "a refused save keeps the input and says nothing was changed", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")
      view |> element("#stops-map-edit-tech-toggle") |> render_click()

      # A web page that is not a URL is refused by the changeset, so the command
      # answers with a changeset rather than writing.
      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_url" => "not a url"}})
      |> render_submit()

      settle(view)

      assert has_element?(view, "#stops-map-edit-errors")
      assert has_element?(view, "#stops-map-edit-url[value='not a url']")
      assert has_element?(view, "#stops-map-edit-status", "Unsaved changes")
    end

    test "an empty name is refused rather than saved blank", ctx do
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_name" => ""}})
      |> render_submit()

      settle(view)

      assert has_element?(view, "#stops-map-edit-errors")
      assert has_element?(view, "#stops-map-edit-name[aria-invalid=true]")
      # The saved name is untouched and the draft that failed is still there.
      assert Repo.get_by!(Stop, stop_id: "1434").stop_name == "US 101 & SE 1st St"
      assert has_element?(view, "#stops-map-edit-name[value='']")
    end

    test "a move past the correction band opens the review, not a written save", ctx do
      stub_routing(200)
      seeded(ctx)

      view = open_map(ctx, stop: "1434")

      # Served by a pattern, so a move beyond the correction band is a review
      # rather than a correction. Step 31 replaced this panel's message with the
      # review itself; stops_map_move_test.exs carries the review's own cases.
      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_lat" => "44.63661"}})
      |> render_submit()

      settle(view)

      assert has_element?(view, "#stops-map-move-panel")
      assert Decimal.to_float(Repo.get_by!(Stop, stop_id: "1434").stop_lat) == 44.63561
    end
  end

  # The review is read through the real `StreetRouting` composition with only
  # its HTTP boundary faked, so a move can be typed and submitted here without
  # reaching the address service.
  defp stub_routing(status) do
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(GtfsPlanner.StreetRouting.Geoapify, fn conn ->
      Plug.Conn.send_resp(
        Plug.Conn.put_resp_content_type(conn, "application/json"),
        status,
        Jason.encode!(%{
          "type" => "FeatureCollection",
          "features" => [
            %{
              "type" => "Feature",
              "properties" => %{"mode" => "bus"},
              "geometry" => %{
                "type" => "MultiLineString",
                "coordinates" => [[[-124.0530, 44.6205], [-124.0530, 44.6215]]]
              }
            }
          ]
        })
      )
    end)

    on_exit(fn -> Req.Test.set_req_test_to_private(%{}) end)
  end

  # --- fixture --------------------------------------------------------------

  # The browser seed's own geography, at the scale this test needs: two stops on
  # one road, a northbound pattern that visits the first of them, a station with
  # a bay, and an unserved stop. 1434 is served, so its move band is the served
  # one; 1531 is served by nothing, so it is a correction at any distance.
  defp seeded(ctx) do
    served =
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1434",
        stop_name: "US 101 & SE 1st St",
        stop_desc: "Northbound",
        stop_lat: Decimal.from_float(44.63561),
        stop_lon: Decimal.from_float(-124.05317),
        wheelchair_boarding: 1
      })

    other =
      stop_fixture(ctx.organization.id, ctx.version.id, %{
        stop_id: "1330",
        stop_name: "US 101 & NE 7th St",
        stop_lat: Decimal.from_float(44.64126),
        stop_lon: Decimal.from_float(-124.05297)
      })

    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1531",
      stop_name: "SE Bay Blvd & SE Moore Dr",
      stop_lat: Decimal.from_float(44.63095),
      stop_lon: Decimal.from_float(-124.04077)
    })

    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1500",
      stop_name: "Transit Center",
      location_type: 1,
      stop_lat: Decimal.from_float(44.63610),
      stop_lon: Decimal.from_float(-124.05320)
    })

    stop_fixture(ctx.organization.id, ctx.version.id, %{
      stop_id: "1501",
      stop_name: "Transit Center Bay B",
      parent_station: "1500",
      stop_lat: Decimal.from_float(44.63615),
      stop_lon: Decimal.from_float(-124.05321)
    })

    # `GtfsFixtures.insert_stop/1` casts through `Stop.changeset/2`, which
    # deliberately does not cast the sign number, so the fixture writes that one
    # column the way the importer does — otherwise the panel's sign-number field
    # would be empty in every test that is not about the sign number.
    served
    |> Ecto.Changeset.change(%{stop_code: "1434", zone_id: "NL"})
    |> Repo.update!()

    route = route_fixture(ctx.organization.id, ctx.version.id, %{route_short_name: "1"})

    pattern =
      route_pattern_fixture(ctx.organization.id, ctx.version.id, %{
        route_pattern_id: "BROWSER_SM_NB",
        route_id: route.route_id,
        headsign: "Newport"
      })

    route_pattern_stop_fixture(pattern, "1434", 1)
    route_pattern_stop_fixture(pattern, "1330", 2)

    fare_zone(ctx, "NL", "Newport local")

    %{served: served, other: other}
  end

  defp fare_zone(ctx, zone_id, name) do
    Repo.insert!(%FareZone{
      zone_id: zone_id,
      name: name,
      color: "#0d737d",
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id
    })
  end

  # Waiting for the panel to stop working.
  #
  # `render_async/2` waits for the async tasks that exist when it is called, and
  # a save starts a second task from its own result (the model reload), so one
  # call is not enough. It also answers before the LiveView has handled the
  # task's result, because that handling is triggered by the task's `DOWN`
  # message rather than by the call. Each round here is a call to the LiveView
  # process, which puts it behind every message already queued, so repeating it
  # drains the chain rather than racing it. The bound is there so a genuine
  # hang fails the test instead of looping.
  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 2_000)
    settle(view, rounds - 1)
  end

  defp open_map(ctx, params \\ []) do
    path =
      case params do
        [] -> "/gtfs/#{ctx.version.id}/stops/map"
        other -> "/gtfs/#{ctx.version.id}/stops/map?" <> URI.encode_query(other)
      end

    {:ok, view, _html} = live(ctx.editor_conn, path)
    # Twice, because `render_async/2` waits for the async tasks that exist when
    # it is called. Opening a stop starts the usage read from the model load's
    # own result, so the second call is what waits for it.
    settle(view)

    # The search half of the field asks the address service. No case here is
    # about that answer, so it is stubbed once rather than expected per test:
    # expectation first, permission second, scoped to this LiveView's process.
    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)
    Mox.allow(GeocodingMock, self(), view.pid)

    view
  end

  # A panel that is open and has been typed into: every guard case needs both,
  # and the dirty half is the one worth building once.
  defp dirty_view(ctx) do
    view = open_map(ctx, stop: "1434")

    view
    |> form("#stops-map-edit-form", %{"stop" => %{"stop_desc" => "By the post office"}})
    |> render_change()

    view
  end

  # The other editor's write goes through the same audited command the panel
  # uses, under a different actor. A conflict manufactured by poking a timestamp
  # would prove the panel reads a column; this proves it reads the command's
  # refusal and the audit entry the command wrote.
  defp other_editor_write(ctx, stop_id, attrs) do
    other = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: other.id,
      organization_id: ctx.organization.id,
      roles: ["pathways_studio_editor"]
    })

    stop = Repo.get_by!(Stop, stop_id: stop_id)

    audit = %AuditContext{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      station_stop_id: nil,
      actor_id: other.id,
      actor_email: other.email
    }

    assert {:ok, _stop} = StopEditing.update_stop(stop.id, attrs, stop.updated_at, audit)

    # `stops.updated_at` is a whole second, so a write landing in the same
    # second as the one the panel was rendered from would not read as someone
    # else's save. Backdating the row is deterministic where the clock is not:
    # the panel's copy was read at the start of the test, minutes earlier than
    # anything this test writes.
    stop
    |> Ecto.Changeset.change(%{updated_at: DateTime.add(DateTime.utc_now(), -120, :second)})
    |> Repo.update!()

    other
  end
end

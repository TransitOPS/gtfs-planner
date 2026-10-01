defmodule GtfsPlannerWeb.Gtfs.StopsMapMoveTest do
  @moduledoc """
  Tests for the move and the move review.

  Five things are claimed here, and each is asserted through the real view and
  the real commands rather than by poking assigns: a correction saves without a
  review, a move past the correction band opens the review and lists each
  pattern that shares the pair with its own outcome, applying the review commits
  the coordinates and reports what it redrew and what it left stale, a far move
  asks whether this is the same stop and writes nothing until it is answered,
  and a review answered against a stop that has since changed is refused.

  The distances are literals — 5 ft, 45 ft and 1,000 ft — and so are the
  outcomes, because both come from the product rules rather than from anything
  the code computes. The routing boundary is faked at HTTP only
  (`Req.Test`), so `StopEditing.move_review/3` and `apply_move/4` run the real
  `StreetRouting` composition over it.
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
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Repo

  @routing_owner GtfsPlanner.StreetRouting.Geoapify
  @test_key "test-move-panel-key-9b4d7f0c2a1e"

  @stop_lat 44.6210
  @stop_lon -124.0530
  @metres_per_degree 111_320.0

  # Past `StopPlacement.move_band/2`'s correction band and inside its far one.
  @review_m 13.7
  # Past the far threshold, which is 100 m.
  @far_m 330.0

  setup :set_mox_global

  setup do
    Req.Test.set_req_test_to_shared(%{})

    original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
    Application.put_env(:gtfs_planner, :geoapify_api_key, @test_key)

    on_exit(fn ->
      if is_nil(original_key) do
        Application.delete_env(:gtfs_planner, :geoapify_api_key)
      else
        Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)
      end

      Req.Test.set_req_test_to_private(%{})
    end)

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

  describe "a correction" do
    test "pin_moved 5 ft away shows the move, and saving writes it with no review", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(1.5), "lon" => @stop_lon})

      # The distance is stated in the editor's units: a curb is measured in feet.
      assert has_element?(view, "#stops-map-edit-moved")

      assert view |> element("#stops-map-edit-moved") |> render() =~
               ~r/Moved \d+ ft of where it was/

      assert has_element?(view, "#stops-map-edit-save", "Save changes")

      view |> form("#stops-map-edit-form") |> render_submit()

      assert settle(view) |> has_element?("#stops-map-edit-panel")
      refute has_element?(view, "#stops-map-move-panel")
      assert saved_lat(ctx) == numeric(moved_lat(1.5))
    end

    test "putting the pin back restores the saved position and keeps the typed name", ctx do
      stub_routing(200)
      view = open_map(ctx)

      view
      |> form("#stops-map-edit-form", %{"stop" => %{"stop_name" => "Renamed"}})
      |> render_change()

      render_hook(view, "pin_moved", %{"lat" => moved_lat(1.5), "lon" => @stop_lon})
      assert has_element?(view, "#stops-map-edit-moved")

      view |> element("#stops-map-edit-put-back") |> render_click()

      refute has_element?(view, "#stops-map-edit-moved")
      assert has_element?(view, "#stops-map-edit-name[value='Renamed']")
    end
  end

  describe "the review" do
    test "a 45 ft move on a served stop reviews and names both patterns on the pair", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@review_m), "lon" => @stop_lon})
      assert has_element?(view, "#stops-map-edit-save", "Review move")

      view |> form("#stops-map-edit-form") |> render_submit()

      assert settle(view) |> has_element?("#stops-map-move-panel")
      assert has_element?(view, "#stops-map-move-heading", "Review move")
      assert has_element?(view, "#stops-map-move-patterns")

      # Both patterns share the 1330 → 1434 pair, so both are on the review, and
      # each is reported with its own outcome rather than a single verdict.
      assert has_element?(view, "#stops-map-move-patterns", "Will redraw")

      assert has_element?(
               view,
               "#stops-map-move-patterns",
               "Blocked: trips don’t match the stops"
             )

      # Nothing has been written yet: a review is a question, not a save.
      assert saved_lat(ctx) == numeric(@stop_lat)
    end

    test "back to editing keeps the move and the draft", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@review_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()
      assert settle(view) |> has_element?("#stops-map-move-panel")

      view |> element("#stops-map-move-back") |> render_click()

      assert has_element?(view, "#stops-map-edit-panel")
      assert has_element?(view, "#stops-map-edit-moved")
    end

    test "Save move with Redraw commits and names one redrawn and one out-of-date", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@review_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()
      assert settle(view) |> has_element?("#stops-map-move-panel")

      view |> element("#stops-map-move-save") |> render_click()

      html = settle(view) |> element("#stops-map-move-saved-message") |> render()

      assert html =~ "1 pattern redrawn"
      assert html =~ "1 pattern marked out of date"
      assert saved_lat(ctx) == numeric(moved_lat(@review_m))
      refute has_element?(view, "#stops-map-edit-moved")
    end

    test "a stop changed elsewhere while reviewing is refused and writes nothing", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@review_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()
      assert settle(view) |> has_element?("#stops-map-move-panel")

      # Someone else saves the stop after the review was read. The fingerprint
      # covers the row, so the answer the editor is giving no longer describes
      # it and the move is refused rather than applied.
      stop(ctx)
      |> Ecto.Changeset.change(%{stop_desc: "Changed elsewhere"})
      |> Repo.update!()

      view |> element("#stops-map-move-save") |> render_click()

      assert settle(view) |> has_element?("#stops-map-move-stale")

      assert has_element?(
               view,
               "#stops-map-move-stale-message",
               "This stop changed while you were reviewing"
             )

      assert saved_lat(ctx) == numeric(@stop_lat)
    end
  end

  describe "the far move" do
    test "1,000 ft away asks whether this is the same stop, with no answer chosen", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@far_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()

      assert settle(view) |> has_element?("#stops-map-move-panel")
      assert has_element?(view, "#stops-map-move-far")
      assert has_element?(view, "#stops-map-move-far", "Is this the same stop?")

      # No default: a move this far is exactly the case where the editor is the
      # only one who knows which stop this is.
      refute has_element?(view, "#stops-map-move-far input[checked]")
    end

    test "Save move without an answer shows the error and writes nothing", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@far_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()
      assert settle(view) |> has_element?("#stops-map-move-panel")

      view |> element("#stops-map-move-save") |> render_click()

      assert settle(view) |> has_element?("#stops-map-move-errors")
      assert has_element?(view, "#stops-map-move-errors", "Choose one.")
      assert saved_lat(ctx) == numeric(@stop_lat)
    end

    test "No, this is a new stop opens the add panel at the pin", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@far_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()
      assert settle(view) |> has_element?("#stops-map-move-panel")

      view |> element("#stops-map-move-far input[value='new']") |> render_click()
      assert has_element?(view, "#stops-map-move-new")

      view |> element("#stops-map-move-save") |> render_click()

      # The add panel opens at the pin, and the old stop is untouched: "no" is
      # an answer, not a deletion.
      assert settle(view) |> has_element?("#stops-map-add-panel")
      assert has_element?(view, "#stops-map-add-lat[value='#{moved_lat_text(@far_m)}']")
      assert saved_lat(ctx) == numeric(@stop_lat)
    end

    test "Yes, the same stop has moved here saves the move", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@far_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()
      assert settle(view) |> has_element?("#stops-map-move-panel")

      view |> element("#stops-map-move-far input[value='same']") |> render_click()
      view |> element("#stops-map-move-save") |> render_click()

      assert settle(view) |> has_element?("#stops-map-move-saved-message")
      assert saved_lat(ctx) == numeric(moved_lat(@far_m))
    end
  end

  describe "a result for a stop the panel has left" do
    test "a move review read for one stop does not fill the next stop's panel", ctx do
      hold_routing(200)
      view = open_map(ctx)

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@review_m), "lon" => @stop_lon})
      view |> form("#stops-map-edit-form") |> render_submit()

      # The review is in flight: it has reached the routing service, which is
      # not answering yet.
      assert_receive {:routing_held, routing}, 5_000
      assert has_element?(view, "#stops-map-move-panel")

      render_hook(view, "select_stop", %{"stop_id" => "1330"})
      render_hook(view, "discard_changes", %{})
      assert has_element?(view, "#stops-map-edit-panel", "Cedar St")

      send(routing, :release)
      settle(view)

      assert has_element?(view, "#stops-map-edit-panel", "Cedar St")
      refute has_element?(view, "#stops-map-move-panel")
    end
  end

  describe "a pin the editor cannot see" do
    test "a pin moved outside the reported view offers to find it", ctx do
      stub_routing(200)
      view = open_map(ctx)

      render_hook(view, "stop_map_bounds", %{
        "south" => 44.6200,
        "north" => 44.6220,
        "west" => -124.0600,
        "east" => -124.0500
      })

      render_hook(view, "pin_moved", %{"lat" => moved_lat(@far_m), "lon" => @stop_lon})

      assert has_element?(view, "#stops-map-edit-find-pin")
      view |> element("#stops-map-edit-find-pin") |> render_click()
      assert has_element?(view, "#stops-map-edit-panel")
    end
  end

  # --- fixture ---------------------------------------------------------------

  # Two patterns on the same pair, one of which cannot be redrawn: the smallest
  # fixture that can show a review naming a per-pattern outcome and an apply
  # that commits while one line stays stale.
  defp seeded(ctx) do
    stops =
      Map.new(
        [
          {"1330", "Cedar St", 44.6200},
          {"1434", "Main St", @stop_lat},
          {"1355", "Elm St", 44.6220}
        ],
        fn {id, name, lat} ->
          {id,
           stop_fixture(ctx.organization.id, ctx.version.id, %{
             stop_id: id,
             stop_name: name,
             stop_lat: Decimal.from_float(lat),
             stop_lon: Decimal.from_float(@stop_lon)
           })}
        end
      )

    route = route_fixture(ctx.organization.id, ctx.version.id, %{route_short_name: "1"})

    segment(ctx, "1330", "1434", [[-124.06, 44.63]])
    segment(ctx, "1434", "1355", [[-124.04, 44.63]])

    p = pattern(ctx, route, "MOVE_P", ["1330", "1434"], "SHAPE-P")
    q = pattern(ctx, route, "MOVE_Q", ["1330", "1434", "1355"], "SHAPE-Q")

    calendar = calendar_fixture(ctx.organization.id, ctx.version.id, %{service_id: "WEEKDAYS"})

    # P's trip matches its visits. Q's has two stop times for three visits, so
    # `Alignments.shape_plan/2` reports the pattern as blocked.
    trip(ctx, p, "MOVE-TRIP-P", ["1330", "1434"], calendar.service_id)
    trip(ctx, q, "MOVE-TRIP-Q", ["1330", "1434"], calendar.service_id)

    shape(ctx, "SHAPE-P")
    shape(ctx, "SHAPE-Q")

    Map.put(stops, :organization, ctx.organization)
  end

  defp pattern(ctx, route, route_pattern_id, stop_ids, shape_id) do
    pattern =
      route_pattern_fixture(ctx.organization.id, ctx.version.id, %{
        route_pattern_id: route_pattern_id,
        route_id: route.route_id,
        direction_id: 0,
        headsign: "To #{route_pattern_id}"
      })
      |> Ecto.Changeset.change(shape_id: shape_id)
      |> Repo.update!()

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    pattern
  end

  defp trip(ctx, pattern_row, trip_id, stop_ids, service_id) do
    trip =
      trip_fixture(ctx.organization.id, ctx.version.id, pattern_row.route_id, %{
        trip_id: trip_id,
        service_id: service_id
      })

    timing = timed_pattern_fixture(pattern_row)

    trip
    |> Ecto.Changeset.change(
      route_pattern_id: pattern_row.route_pattern_id,
      pattern_derivation_state: "linked",
      timed_pattern_id: timing.id
    )
    |> Repo.update!()

    stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      stop_time_fixture(ctx.organization.id, ctx.version.id, trip_id, stop_id, %{
        stop_sequence: position
      })
    end)
  end

  defp segment(ctx, from_id, to_id, points) do
    %AlignmentSegment{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      from_stop_id: from_id,
      to_stop_id: to_id
    }
    |> AlignmentSegment.changeset(%{points: points})
    |> Repo.insert!()
  end

  defp shape(ctx, shape_id) do
    now = DateTime.utc_now()

    Repo.insert_all(Shape, [
      %{
        organization_id: ctx.organization.id,
        gtfs_version_id: ctx.version.id,
        shape_id: shape_id,
        shape_pt_lon: Decimal.from_float(-124.05),
        shape_pt_lat: Decimal.from_float(44.60),
        shape_pt_sequence: 1,
        inserted_at: now,
        updated_at: now
      }
    ])

    :ok
  end

  defp stop(ctx) do
    Repo.one!(
      from(s in Stop,
        where:
          s.organization_id == ^ctx.organization.id and s.gtfs_version_id == ^ctx.version.id and
            s.stop_id == "1434"
      )
    )
  end

  defp saved_lat(ctx) do
    ctx
    |> stop()
    |> Map.fetch!(:stop_lat)
    |> Decimal.to_float()
    |> numeric()
  end

  defp numeric(value) do
    value
    |> Float.round(5)
    |> then(&trunc(&1 * 100_000))
  end

  defp moved_lat(metres), do: @stop_lat + metres / @metres_per_degree

  defp moved_lat_text(metres), do: moved_lat(metres) |> Float.round(5) |> to_string()

  defp stub_routing(status), do: Req.Test.stub(@routing_owner, &routing_response(&1, status))

  # The routing service holds its first request until the test sends it
  # `:release`, so a review stays in flight for as long as the test needs it to.
  # A review makes one request per pattern; the later ones answer at once.
  defp hold_routing(status) do
    test = self()
    requests = :atomics.new(1, [])

    Req.Test.stub(@routing_owner, fn conn ->
      if :atomics.add_get(requests, 1, 1) == 1 do
        send(test, {:routing_held, self()})

        receive do
          :release -> :ok
        end
      end

      routing_response(conn, status)
    end)
  end

  defp routing_response(conn, status) do
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
  end

  # Waiting for the panel to stop working: the review is read, then the apply
  # writes and reloads the model behind it. Each round is a call to the LiveView
  # process, which puts it behind every message already queued.
  defp settle(view, rounds \\ 8)
  defp settle(view, 0), do: view

  defp settle(view, rounds) do
    render_async(view, 5_000)
    settle(view, rounds - 1)
  end

  defp open_map(ctx) do
    path = "/gtfs/#{ctx.version.id}/stops/map?stop=1434"
    {:ok, view, _html} = live(ctx.editor_conn, path)
    settle(view)

    Mox.stub(GeocodingMock, :autocomplete, fn _text, _opts -> {:ok, []} end)
    Mox.allow(GeocodingMock, self(), view.pid)

    view
  end
end

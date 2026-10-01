defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentBulkTest do
  @moduledoc false
  # Step 36 / EV-36: bulk "Generate missing paths" on Route › Patterns
  # (CL-32/FH-45, AC-41). `confirm_bulk_generation` runs
  # `Gtfs.suggest_missing_alignments/4` under `start_async` through the
  # real StreetRouting composition with a faked HTTP boundary (`Req.Test`
  # shared mode, so the async task process sees the stubs); per-pattern
  # results render with Review actions, Review patches to the pattern's
  # Alignment task where `hook_ready` embeds the suggestions in
  # `alignment:load`, and the hook's `alignment_suggestions_applied` ack
  # drops them. Bulk generation never writes (CR-9): every case asserts
  # the segment row count is unchanged. No live Geoapify call happens here.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  @routing_owner GtfsPlanner.StreetRouting.Geoapify
  @test_key "test-bulk-key-9d4c1b7e2a6f"

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

    :ok
  end

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "align-blk-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-blk-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp viewer_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "align-blk-vw-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-blk-vw-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_viewer"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, user: user, organization: organization, version: version}
  end

  defp route(organization, version, route_id) do
    route_fixture(organization.id, version.id, %{
      route_id: route_id,
      route_short_name: route_id,
      route_long_name: "#{route_id} corridor"
    })
  end

  defp coord_stop(organization, version, stop_id, name, lat, lon) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: name,
      stop_lat: Decimal.new(lat),
      stop_lon: Decimal.new(lon)
    })
  end

  defp pattern(organization, version, route, route_pattern_id) do
    route_pattern_fixture(organization.id, version.id, %{
      route_id: route.route_id,
      route_pattern_id: route_pattern_id,
      route_pattern_name: route_pattern_id,
      direction_id: 0
    })
  end

  defp occurrences(pattern, stop_ids) do
    stop_ids
    |> Enum.with_index(1)
    |> Enum.map(fn {stop_id, position} ->
      route_pattern_stop_fixture(pattern, stop_id, position)
    end)
  end

  defp patterns_path(version, route),
    do: "/gtfs/#{version.id}/routes/#{route.route_id}/patterns"

  defp audit(organization, version) do
    actor = editor_fixture(organization)

    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp section_at(pattern, position) do
    pattern
    |> Gtfs.Alignments.resolve()
    |> Map.fetch!(:sections)
    |> Enum.find(&(&1.position == position))
  end

  defp draw!(pattern, entries, audit_context) do
    pattern = Repo.reload!(pattern)

    draft =
      Enum.map(entries, fn {position, points} ->
        section = section_at(pattern, position)

        %{
          "position" => section.position,
          "from_occurrence_id" => section.from_occurrence_id,
          "to_stop_id" => section.to_stop_id,
          "op" => "set",
          "points" => points,
          "base" => %{
            "segment_id" => section.revision.segment_id,
            "lock_version" => section.revision.lock_version
          }
        }
      end)

    {:ok, review} = Gtfs.review_alignment_save(pattern.id, draft, audit_context)

    {:ok, _result} =
      Gtfs.apply_alignment_save(
        pattern.id,
        draft,
        %{"scopes" => %{}},
        review.fingerprint,
        audit_context
      )
  end

  defp segments_count(organization, version) do
    from(s in AlignmentSegment,
      where:
        s.organization_id == ^organization.id and
          s.gtfs_version_id == ^version.id
    )
    |> Repo.aggregate(:count)
  end

  defp routing_response(legs) do
    %{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "properties" => %{"mode" => "bus"},
          "geometry" => %{"type" => "MultiLineString", "coordinates" => legs}
        }
      ]
    }
  end

  defp stub_json(status, payload) do
    Req.Test.stub(@routing_owner, fn conn ->
      Plug.Conn.send_resp(
        Plug.Conn.put_resp_content_type(conn, "application/json"),
        status,
        Jason.encode!(payload)
      )
    end)
  end

  # Bulk routing round-trips through `start_async`, so the results land
  # after `render_click` returns. Poll the rendered view: the notice's
  # presence proves the async result was handled.
  defp assert_bulk_notice(view, text, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_bulk_notice(view, text, deadline)
    assert has_element?(view, "#patterns-bulk-notice", text)
  end

  defp poll_bulk_notice(view, text, deadline) do
    if has_element?(view, "#patterns-bulk-notice", text) do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        :timeout
      else
        Process.sleep(50)
        poll_bulk_notice(view, text, deadline)
      end
    end
  end

  # Two patterns totalling 3 missing sections: A has two, B has one on a
  # distinct stop pair (with distinct coordinates, so the routing stub
  # can fail B while routing A).
  defp three_missing_route(organization, version, route_id \\ "BLK1") do
    route = route(organization, version, route_id)

    coord_stop(organization, version, "BKA1", "Bulk A1", "40.712800", "-74.006000")
    coord_stop(organization, version, "BKA2", "Bulk A2", "40.713800", "-74.005000")
    coord_stop(organization, version, "BKA3", "Bulk A3", "40.714800", "-74.004000")
    coord_stop(organization, version, "BKB1", "Bulk B1", "40.721800", "-73.998000")
    coord_stop(organization, version, "BKB2", "Bulk B2", "40.722800", "-73.997000")

    pattern_a = pattern(organization, version, route, "P-BLK-A")
    occurrences(pattern_a, ["BKA1", "BKA2", "BKA3"])

    pattern_b = pattern(organization, version, route, "P-BLK-B")
    occurrences(pattern_b, ["BKB1", "BKB2"])

    {route, pattern_a, pattern_b}
  end

  # One request per pattern run: A's three waypoints answer two legs,
  # B's pair answers 400 (:no_route). The waypoints arrive as
  # "lat,lon|…" so B is recognized by its distinct latitude.
  defp stub_partial(leg_a1, leg_a2) do
    Req.Test.stub(@routing_owner, fn conn ->
      waypoints = Plug.Conn.fetch_query_params(conn).params["waypoints"] || ""

      if String.contains?(waypoints, "40.7218") do
        Plug.Conn.send_resp(
          Plug.Conn.put_resp_content_type(conn, "application/json"),
          400,
          Jason.encode!(%{"message" => "No route found"})
        )
      else
        Plug.Conn.send_resp(
          Plug.Conn.put_resp_content_type(conn, "application/json"),
          200,
          Jason.encode!(routing_response([leg_a1, leg_a2]))
        )
      end
    end)
  end

  defp open_bulk_dialog(view) do
    view |> element("#patterns-bulk-generate") |> render_click()
    assert has_element?(view, "#alignment-bulk-dialog[data-open=\"true\"]")
    view
  end

  defp confirm_bulk_dialog(view) do
    view |> element("#alignment-bulk-dialog-confirm") |> render_click()
  end

  describe "bulk selection" do
    setup :editor_scope

    test "the dialog lists patterns with missing sections, checked, and leaves out complete ones",
         %{
           conn: conn,
           organization: organization,
           version: version
         } do
      {route, _a, _b} = three_missing_route(organization, version)

      # FULL draws on its own stop pair so no scope choice is involved.
      coord_stop(organization, version, "BKF1", "Bulk F1", "40.730800", "-73.990000")
      coord_stop(organization, version, "BKF2", "Bulk F2", "40.731800", "-73.989000")

      full = pattern(organization, version, route, "P-BLK-FULL")
      occurrences(full, ["BKF1", "BKF2"])
      draw!(full, [{1, [[-73.989500, 40.731300]]}], audit(organization, version))

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-bulk-generate", "Generate missing paths")

      assert has_element?(
               view,
               "#patterns-attention",
               "2 patterns have 3 sections without a path."
             )

      open_bulk_dialog(view)

      assert has_element?(view, "#pattern-bulk-select-P-BLK-A[checked]")
      assert has_element?(view, "#pattern-bulk-select-P-BLK-B[checked]")
      refute has_element?(view, "#pattern-bulk-select-P-BLK-FULL")
    end

    test "toggling a checkbox changes the dialog count", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, _a, _b} = three_missing_route(organization, version)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      open_bulk_dialog(view)

      view |> element("#pattern-bulk-select-P-BLK-B") |> render_click()
      refute has_element?(view, "#pattern-bulk-select-P-BLK-B[checked]")

      assert has_element?(
               view,
               "#alignment-bulk-summary",
               "2 sections in 1 pattern will get a suggested path."
             )
    end

    test "unchecking every pattern leaves nothing to generate", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, _a, _b} = three_missing_route(organization, version)

      {:ok, view, _html} = live(conn, patterns_path(version, route))
      open_bulk_dialog(view)

      view |> element("#pattern-bulk-select-P-BLK-A") |> render_click()
      view |> element("#pattern-bulk-select-P-BLK-B") |> render_click()

      assert has_element?(view, "#alignment-bulk-summary", "Choose at least one pattern.")
      assert has_element?(view, "#alignment-bulk-dialog-confirm[disabled]")
    end

    test "the dialog states the section count and the saved-paths promise", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, _a, _b} = three_missing_route(organization, version)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      open_bulk_dialog(view)

      assert has_element?(
               view,
               "#alignment-bulk-dialog",
               "Saved and custom paths stay unchanged, and nothing is saved until you review each suggestion."
             )

      assert has_element?(
               view,
               "#alignment-bulk-summary",
               "3 sections in 2 patterns will get a suggested path."
             )

      refute has_element?(view, "#alignment-bulk-dialog-confirm[disabled]")
    end

    test "a selection over 200 sections turns confirm off until patterns are unchecked", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route = route(organization, version, "BLKLONG")

      coord_stop(organization, version, "BKL1", "Bulk L1", "40.712800", "-74.006000")
      coord_stop(organization, version, "BKL2", "Bulk L2", "40.713800", "-74.005000")
      coord_stop(organization, version, "BKS1", "Bulk S1", "40.722800", "-73.997000")
      coord_stop(organization, version, "BKS2", "Bulk S2", "40.723800", "-73.996000")

      long = pattern(organization, version, route, "P-BLK-LONG")

      long_visits =
        ["BKL1", "BKL2"]
        |> Stream.cycle()
        |> Enum.take(202)

      occurrences(long, long_visits)
      occurrences(pattern(organization, version, route, "P-BLK-SHORT"), ["BKS1", "BKS2"])

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      open_bulk_dialog(view)

      assert has_element?(view, "#pattern-bulk-select-P-BLK-LONG[checked]")
      assert has_element?(view, "#alignment-bulk-summary", "Choose fewer patterns.")

      assert has_element?(
               view,
               "#alignment-bulk-summary",
               "These cover 202 sections, and one run covers at most 200."
             )

      assert has_element?(view, "#alignment-bulk-dialog-confirm[disabled]")

      view |> element("#pattern-bulk-select-P-BLK-LONG") |> render_click()

      assert has_element?(
               view,
               "#alignment-bulk-summary",
               "1 section in 1 pattern will get a suggested path."
             )

      refute has_element?(view, "#alignment-bulk-dialog-confirm[disabled]")
    end
  end

  describe "bulk selection for viewers" do
    setup :viewer_scope

    test "viewers never reach the bulk controls", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, _a, _b} = three_missing_route(organization, version, "BLKVW")

      assert {:error, {:redirect, _}} = live(conn, patterns_path(version, route))
    end
  end

  describe "bulk generation" do
    setup :editor_scope

    test "partial success keeps suggestions, shows per-pattern results and writes nothing",
         %{conn: conn, organization: organization, version: version} do
      {route, _a, _b} = three_missing_route(organization, version, "BLK2")

      leg_a1 = [[-74.006, 40.7128], [-74.0058, 40.713], [-74.0055, 40.7133], [-74.005, 40.7138]]
      leg_a2 = [[-74.005, 40.7138], [-74.0047, 40.7141], [-74.0045, 40.7143], [-74.004, 40.7148]]
      stub_partial(leg_a1, leg_a2)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      open_bulk_dialog(view)
      confirm_bulk_dialog(view)

      assert_bulk_notice(view, "Suggested paths for 2 of 3 sections")
      assert has_element?(view, "#pattern-bulk-success-P-BLK-A", "Review suggestion")
      assert has_element?(view, "#pattern-bulk-failed-P-BLK-B", "Draw 1 section")
      assert has_element?(view, "#pattern-bulk-review-P-BLK-A", "Review")
      refute has_element?(view, "#patterns-attention")

      assert segments_count(organization, version) == 0
      refute render(view) =~ @test_key
    end

    test "Review patches to the editor with suggestions and the ack drops them",
         %{conn: conn, organization: organization, version: version} do
      {route, _a, _b} = three_missing_route(organization, version, "BLK3")

      leg_a1 = [[-74.006, 40.7128], [-74.0058, 40.713], [-74.0055, 40.7133], [-74.005, 40.7138]]
      leg_a2 = [[-74.005, 40.7138], [-74.0047, 40.7141], [-74.0045, 40.7143], [-74.004, 40.7148]]
      stub_partial(leg_a1, leg_a2)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      open_bulk_dialog(view)
      confirm_bulk_dialog(view)
      assert_bulk_notice(view, "Suggested paths for 2 of 3 sections")

      view |> element("#pattern-bulk-review-P-BLK-A") |> render_click()

      assert_patch(
        view,
        "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/P-BLK-A?task=alignment"
      )

      assert has_element?(view, "#alignment-task")

      render_hook(view, "alignment_hook_ready", %{})

      assert_push_event(
        view,
        "alignment:load",
        %{
          model: %{
            suggestions: [
              %{position: 1, points: [[-74.0058, 40.713], [-74.0055, 40.7133]]},
              %{position: 2, points: [[-74.0047, 40.7141], [-74.0045, 40.7143]]}
            ]
          }
        },
        5_000
      )

      render_hook(view, "alignment_suggestions_applied", %{"route_pattern_id" => "P-BLK-A"})
      render_hook(view, "alignment_hook_ready", %{})

      assert_push_event(view, "alignment:load", %{model: %{suggestions: []}}, 5_000)
      assert segments_count(organization, version) == 0
    end

    test "pending suggestions guard navigation with the discard dialog",
         %{conn: conn, organization: organization, version: version} do
      {route, _a, _b} = three_missing_route(organization, version, "BLK4")

      leg_a1 = [[-74.006, 40.7128], [-74.0058, 40.713], [-74.0055, 40.7133], [-74.005, 40.7138]]
      leg_a2 = [[-74.005, 40.7138], [-74.0047, 40.7141], [-74.0045, 40.7143], [-74.004, 40.7148]]
      stub_partial(leg_a1, leg_a2)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      open_bulk_dialog(view)
      confirm_bulk_dialog(view)
      assert_bulk_notice(view, "Suggested paths for 2 of 3 sections")

      render_click(view, "open_pattern", %{"pattern-id" => "P-BLK-B"})

      assert has_element?(view, "#discard-changes-dialog", "Discard unsaved changes?")
      assert has_element?(view, "#patterns-list-container")

      render_click(element(view, "#discard-changes-dialog-cancel"))
      assert has_element?(view, "#patterns-list-container")
    end

    test "cancelling the flight shows no results and writes nothing",
         %{conn: conn, organization: organization, version: version} do
      {route, _a, _b} = three_missing_route(organization, version, "BLK5")

      leg = [[-74.006, 40.7128], [-74.0055, 40.7133], [-74.005, 40.7138]]
      test_pid = self()

      Req.Test.stub(@routing_owner, fn conn ->
        # Entered once per routed run: the test cancels only after a run
        # is sleeping here, so the kill never lands mid-query on the
        # shared sandbox connection.
        send(test_pid, :bulk_routing_started)
        Process.sleep(600)

        Plug.Conn.send_resp(
          Plug.Conn.put_resp_content_type(conn, "application/json"),
          200,
          Jason.encode!(routing_response([leg]))
        )
      end)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      open_bulk_dialog(view)
      confirm_bulk_dialog(view)

      assert_receive :bulk_routing_started, 10_000

      view |> element("#patterns-bulk-cancel") |> render_click()
      refute has_element?(view, "#patterns-bulk-running")

      Process.sleep(1_500)
      refute has_element?(view, "#patterns-bulk-notice")
      refute has_element?(view, "#pattern-bulk-success-P-BLK-A")
      assert segments_count(organization, version) == 0
    end

    test "a revoked editor is halted on confirm", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      {route, _a, _b} = three_missing_route(organization, version, "BLK6")

      leg = [[-74.006, 40.7128], [-74.0055, 40.7133], [-74.005, 40.7138]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, patterns_path(version, route))
      open_bulk_dialog(view)

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      Repo.delete!(membership)

      render_click(view, "confirm_bulk_generation", %{})

      assert has_element?(view, "#pattern-editor-revoked")
      refute has_element?(view, "#patterns-bulk-notice")
      assert segments_count(organization, version) == 0
      refute render(view) =~ @test_key
    end
  end

  describe "suggest_missing/4" do
    setup :editor_scope

    test "a run over 200 sections is refused before any routing call", %{
      organization: organization,
      version: version
    } do
      route = route(organization, version, "BLKCTX")

      coord_stop(organization, version, "BKX1", "Bulk X1", "40.712800", "-74.006000")
      coord_stop(organization, version, "BKX2", "Bulk X2", "40.713800", "-74.005000")

      long = pattern(organization, version, route, "P-BLK-CTX-LONG")

      long_visits =
        ["BKX1", "BKX2"]
        |> Stream.cycle()
        |> Enum.take(202)

      occurrences(long, long_visits)

      Req.Test.stub(@routing_owner, fn _conn -> raise "must not route over the cap" end)

      assert {:error, :too_many_sections} =
               Gtfs.suggest_missing_alignments(
                 organization.id,
                 version.id,
                 route.route_id,
                 ["P-BLK-CTX-LONG", "P-BLK-CTX-UNKNOWN"]
               )

      assert segments_count(organization, version) == 0
    end

    test "foreign patterns resolve to no suggestions", %{
      organization: organization,
      version: version
    } do
      route = route(organization, version, "BLKCTX2")

      assert {:ok, %{patterns: %{}, generated: 0, total: 0}} =
               Gtfs.suggest_missing_alignments(
                 organization.id,
                 version.id,
                 route.route_id,
                 ["P-BLK-CTX-UNKNOWN"]
               )
    end
  end
end

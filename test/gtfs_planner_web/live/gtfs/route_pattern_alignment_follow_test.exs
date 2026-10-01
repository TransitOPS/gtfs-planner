defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentFollowTest do
  @moduledoc false
  # Step 33 / EV-33: follow streets between selected points (CL-30/FH-43).
  # `alignment_follow_streets` runs `Gtfs.suggest_alignment_between/2`
  # under `start_async` with the real StreetRouting composition and a
  # faked HTTP boundary (`Req.Test` shared mode, so the async task process
  # sees the stubs); success pushes `alignment:follow_result` with the
  # echoed run bounds, out-of-range coordinates push nothing, and a 400
  # shows the no-path notice. Follow never writes (CR-9): every case
  # asserts the segment row count is unchanged. No live Geoapify call
  # happens here.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

  @routing_owner GtfsPlanner.StreetRouting.Geoapify
  @test_key "test-follow-key-9d4b1c2e8f6a"

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
      organization_fixture(%{alias: "align-fol-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-fol-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
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

  defp pattern_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=alignment"
  end

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
    |> Alignments.resolve()
    |> Map.fetch!(:sections)
    |> Enum.find(&(&1.position == position))
  end

  defp set_entry(section, points) do
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
  end

  # Draws sections through the real review/apply facade, like an editor's
  # confirmed dialog would.
  defp draw!(pattern, entries, audit_context) do
    pattern = Repo.reload!(pattern)

    draft =
      Enum.map(entries, fn {position, points} ->
        set_entry(section_at(pattern, position), points)
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

  # Follow round-trips through `start_async`, so the push lands after
  # `render_click` returns. `assert_push_event` already waits; the notice
  # needs the same polling the generation suite uses.
  defp assert_follow_notice(view, text, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_follow_notice(view, text, deadline)
    assert has_element?(view, "#alignment-generate-notice", text)
  end

  defp poll_follow_notice(view, text, deadline) do
    if has_element?(view, "#alignment-generate-notice", text) do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        :timeout
      else
        Process.sleep(50)
        poll_follow_notice(view, text, deadline)
      end
    end
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

  # A drawn section with five interior points [p1..p5]; the hook's run
  # {2,3,4} (1-based UI labels) routes between p1 and p5.
  defp drawn_pattern(organization, version, route, pattern_id, prefix) do
    coord_stop(organization, version, "#{prefix}A", "#{prefix} Alpha", "40.712800", "-74.006000")
    coord_stop(organization, version, "#{prefix}B", "#{prefix} Beta", "40.713800", "-74.005000")
    follow_pattern = pattern(organization, version, route, pattern_id)
    occurrences(follow_pattern, ["#{prefix}A", "#{prefix}B"])

    draw!(
      follow_pattern,
      [
        {1,
         [
           [-74.006000, 40.712800],
           [-74.005500, 40.713300],
           [-74.005000, 40.713800],
           [-74.004500, 40.714300],
           [-74.004000, 40.714800]
         ]}
      ],
      audit(organization, version)
    )

    follow_pattern
  end

  defp follow_params(overrides \\ %{}) do
    Map.merge(
      %{
        "position" => "1",
        "start_index" => 1,
        "end_index" => 3,
        "from" => [-74.006000, 40.712800],
        "to" => [-74.004000, 40.714800]
      },
      overrides
    )
  end

  describe "follow streets" do
    setup :editor_scope

    test "a valid follow request pushes the routed interior with the run bounds",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "FOL1")
      follow_pattern = drawn_pattern(organization, version, route, "P-FOL-OK", "F1")
      before_count = segments_count(organization, version)
      assert before_count == 1

      leg = [[-74.006, 40.7128], [-74.005, 40.7138], [-74.004, 40.7148]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, follow_pattern))

      render_click(view, "alignment_follow_streets", follow_params())

      assert_push_event(
        view,
        "alignment:follow_result",
        %{position: 1, start_index: 1, end_index: 3, points: [[-74.005, 40.7138]]},
        5_000
      )

      assert segments_count(organization, version) == before_count
      refute render(view) =~ @test_key
    end

    test "latitude 95.0 in from is rejected with a notice, no push and no routing call",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "FOLX")
      follow_pattern = drawn_pattern(organization, version, route, "P-FOL-BADCOORD", "F2")

      Req.Test.stub(@routing_owner, fn _conn -> raise "must not route invalid coordinates" end)

      {:ok, view, _html} = live(conn, pattern_path(version, route, follow_pattern))

      render_click(view, "alignment_follow_streets", follow_params(%{"from" => [-74.006, 95.0]}))

      refute_push_event(view, "alignment:follow_result", %{}, 300)
      assert has_element?(view, "#alignment-generate-notice")
      assert segments_count(organization, version) == 1
    end

    test "out-of-range indexes show the rejection notice and push nothing",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "FOLR")
      follow_pattern = drawn_pattern(organization, version, route, "P-FOL-BADRANGE", "F3")

      leg = [[-74.006, 40.7128], [-74.005, 40.7138], [-74.004, 40.7148]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, follow_pattern))

      render_click(view, "alignment_follow_streets", follow_params(%{"end_index" => 9}))

      refute_push_event(view, "alignment:follow_result", %{}, 300)
      assert has_element?(view, "#alignment-generate-notice")
      assert segments_count(organization, version) == 1
    end

    test "an unknown position pushes nothing and shows no notice",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "FOLR2")
      follow_pattern = drawn_pattern(organization, version, route, "P-FOL-BADRANGE2", "F3B")

      {:ok, view, _html} = live(conn, pattern_path(version, route, follow_pattern))

      render_click(view, "alignment_follow_streets", follow_params(%{"position" => "7"}))

      refute_push_event(view, "alignment:follow_result", %{}, 300)
      refute has_element?(view, "#alignment-generate-notice")
      assert segments_count(organization, version) == 1
    end

    test "a run past the saved length routes against the pushed draft length",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "FOLD")
      follow_pattern = drawn_pattern(organization, version, route, "P-FOL-DRAFT", "F6")

      leg = [[-74.006, 40.7128], [-74.005, 40.7138], [-74.004, 40.7148]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, follow_pattern))

      # Five saved points, but the hook's unsaved Add-midpoint draft holds
      # six: the last draft point is a legal run end.
      render_click(
        view,
        "alignment_follow_streets",
        follow_params(%{"end_index" => 5, "interior_length" => 6})
      )

      assert_push_event(
        view,
        "alignment:follow_result",
        %{position: 1, start_index: 1, end_index: 5, points: [[-74.005, 40.7138]]},
        5_000
      )

      refute has_element?(view, "#alignment-generate-notice")
      assert segments_count(organization, version) == 1
    end

    test "a stubbed 400 shows the No street path found notice",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "FOL400")
      follow_pattern = drawn_pattern(organization, version, route, "P-FOL-NOROUTE", "F4")

      stub_json(400, %{"message" => "No route found"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, follow_pattern))

      render_click(view, "alignment_follow_streets", follow_params())

      assert_follow_notice(view, "No street path found")
      refute_push_event(view, "alignment:follow_result", %{}, 300)
      assert segments_count(organization, version) == 1
      refute render(view) =~ @test_key
    end

    test "a revoked editor is halted with no push",
         %{conn: conn, user: user, organization: organization, version: version} do
      route = route(organization, version, "FOLRV")
      follow_pattern = drawn_pattern(organization, version, route, "P-FOL-REVOKED", "F5")

      leg = [[-74.006, 40.7128], [-74.005, 40.7138], [-74.004, 40.7148]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, follow_pattern))

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      Repo.delete!(membership)

      render_click(view, "alignment_follow_streets", follow_params())

      assert has_element?(view, "#pattern-editor-revoked")
      refute_push_event(view, "alignment:follow_result", %{}, 300)
      assert segments_count(organization, version) == 1
      refute render(view) =~ @test_key
    end
  end
end

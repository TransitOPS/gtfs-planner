defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentGenerationTest do
  @moduledoc false
  # Step 32 / EV-32: in-editor street-path generation (CL-10/FH-19,
  # CL-29/FH-42). `start_async` in RoutePatternAlignmentEvents drives
  # `Gtfs.suggest_alignment_paths/5` through the real StreetRouting
  # composition with a faked HTTP boundary (`Req.Test` shared mode, so the
  # async task process sees the stubs); the LiveView pushes
  # `alignment:suggestions` with `review: true`, and failures, cancel and
  # pattern switches push nothing. Generation never writes (CR-9): every
  # generation case asserts the segment row count is unchanged. No live
  # Geoapify call happens here.
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
  @test_key "test-generation-key-7c2b9a4e1f5d"

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
      organization_fixture(%{alias: "align-gen-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-gen-#{System.unique_integer([:positive])}@example.com"})

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
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: Ecto.UUID.generate(),
      actor_email: "align-gen@example.com"
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
  # confirmed dialog would. Fresh stop pairs apply directly (`:write_shared`
  # with no affected patterns), so scopes stay empty.
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

  # Street generation round-trips through `start_async`, so the notice
  # lands after `render_click` returns. Poll the rendered view instead of
  # asserting once: the notice's presence proves the async result was
  # handled, which also makes the later `refute_push_event` meaningful.
  defp assert_generate_notice(view, text, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_generate_notice(view, text, deadline)
    assert has_element?(view, "#alignment-generate-notice", text)
  end

  defp poll_generate_notice(view, text, deadline) do
    if has_element?(view, "#alignment-generate-notice", text) do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        :timeout
      else
        Process.sleep(50)
        poll_generate_notice(view, text, deadline)
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

  defp four_stops(organization, version, prefix) do
    coord_stop(organization, version, "#{prefix}A", "#{prefix} Alpha", "40.712800", "-74.006000")
    coord_stop(organization, version, "#{prefix}B", "#{prefix} Beta", "40.713800", "-74.005000")
    coord_stop(organization, version, "#{prefix}C", "#{prefix} Gamma", "40.714800", "-74.004000")
    coord_stop(organization, version, "#{prefix}D", "#{prefix} Delta", "40.715800", "-74.003000")
    ["#{prefix}A", "#{prefix}B", "#{prefix}C", "#{prefix}D"]
  end

  describe "street-path generation" do
    setup :editor_scope

    test "generating all missing sections pushes suggestions and writes nothing",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GEN1")
      stop_ids = four_stops(organization, version, "G1")
      gen_pattern = pattern(organization, version, route, "P-GEN-ALL")
      occurrences(gen_pattern, stop_ids)

      draw!(gen_pattern, [{1, [[-74.005500, 40.713300]]}], audit(organization, version))
      before_count = segments_count(organization, version)
      assert before_count == 1

      leg1 = [[-74.005, 40.7138], [-74.0048, 40.7141], [-74.0045, 40.7144], [-74.004, 40.7148]]
      leg2 = [[-74.004, 40.7148], [-74.0037, 40.7151], [-74.0033, 40.7154], [-74.003, 40.7158]]
      stub_json(200, routing_response([leg1, leg2]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, gen_pattern))

      view |> element("#alignment-generate-missing") |> render_click()

      assert_push_event(
        view,
        "alignment:suggestions",
        %{
          sections: [
            %{position: 2, points: [[-74.0048, 40.7141], [-74.0045, 40.7144]]},
            %{position: 3, points: [[-74.0037, 40.7151], [-74.0033, 40.7154]]}
          ],
          review: true
        },
        5_000
      )

      assert segments_count(organization, version) == before_count
      refute render(view) =~ @test_key
    end

    test "a section with saved points asks first through the replace dialog",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GENR")
      coord_stop(organization, version, "GRA", "Gen Replace A", "40.712800", "-74.006000")
      coord_stop(organization, version, "GRB", "Gen Replace B", "40.713800", "-74.005000")
      replace_pattern = pattern(organization, version, route, "P-GEN-REPLACE")
      occurrences(replace_pattern, ["GRA", "GRB"])

      draw!(replace_pattern, [{1, [[-74.005500, 40.713300]]}], audit(organization, version))

      leg = [[-74.006, 40.7128], [-74.0055, 40.7133], [-74.005, 40.7138]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, replace_pattern))

      view |> element("#alignment-generate-section") |> render_click()

      assert has_element?(view, "#alignment-generate-replace-dialog[data-open=\"true\"]")
      assert has_element?(view, "#alignment-generate-replace-dialog", "Replace the drawn path?")
      refute_push_event(view, "alignment:suggestions", %{}, 300)

      view |> element("#alignment-generate-replace-dialog-confirm") |> render_click()

      assert_push_event(
        view,
        "alignment:suggestions",
        %{sections: [%{position: 1, points: [[-74.0055, 40.7133]]}], review: true},
        5_000
      )

      assert segments_count(organization, version) == 1
    end

    test "a 400 shows No street path found naming the section with Retry and Draw manually",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GEN400")
      coord_stop(organization, version, "G4A", "Stop A", "40.712800", "-74.006000")
      coord_stop(organization, version, "G4B", "Stop B", "40.713800", "-74.005000")
      missing_pattern = pattern(organization, version, route, "P-GEN-NOROUTE")
      occurrences(missing_pattern, ["G4A", "G4B"])

      stub_json(400, %{"message" => "No route found"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, missing_pattern))

      view |> element("#alignment-generate-section") |> render_click()

      assert_generate_notice(view, "No street path found")
      assert has_element?(view, "#alignment-generate-notice", "Stop A → Stop B")
      assert has_element?(view, "#alignment-generate-retry", "Retry")
      assert has_element?(view, "#alignment-generate-draw", "Draw manually")
      refute_push_event(view, "alignment:suggestions", %{}, 300)
      assert segments_count(organization, version) == 0
      refute render(view) =~ @test_key
    end

    test "a 500 shows the unavailable notice",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GEN500")
      coord_stop(organization, version, "G5A", "Stop A", "40.712800", "-74.006000")
      coord_stop(organization, version, "G5B", "Stop B", "40.713800", "-74.005000")
      missing_pattern = pattern(organization, version, route, "P-GEN-UNAVAILABLE")
      occurrences(missing_pattern, ["G5A", "G5B"])

      stub_json(500, %{"message" => "Internal error"})

      {:ok, view, _html} = live(conn, pattern_path(version, route, missing_pattern))

      view |> element("#alignment-generate-section") |> render_click()

      # The adapter retries 500s, so the notice takes seconds to land.
      assert_generate_notice(view, "Street routing is unavailable", 15_000)

      assert has_element?(
               view,
               "#alignment-generate-notice",
               "Draw the section or try again later."
             )

      refute_push_event(view, "alignment:suggestions", %{}, 300)
      assert segments_count(organization, version) == 0
    end

    test "a missing key shows the unavailable notice",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GENKEY")
      coord_stop(organization, version, "GKA", "Stop A", "40.712800", "-74.006000")
      coord_stop(organization, version, "GKB", "Stop B", "40.713800", "-74.005000")
      missing_pattern = pattern(organization, version, route, "P-GEN-NOKEY")
      occurrences(missing_pattern, ["GKA", "GKB"])

      Application.delete_env(:gtfs_planner, :geoapify_api_key)
      on_exit(fn -> Application.put_env(:gtfs_planner, :geoapify_api_key, @test_key) end)

      Req.Test.stub(@routing_owner, fn _conn -> raise "must not request without a key" end)

      {:ok, view, _html} = live(conn, pattern_path(version, route, missing_pattern))

      view |> element("#alignment-generate-section") |> render_click()

      assert_generate_notice(view, "Street routing is unavailable")

      assert has_element?(
               view,
               "#alignment-generate-notice",
               "Draw the section or try again later."
             )

      refute_push_event(view, "alignment:suggestions", %{}, 300)
    end

    test "cancelling generation pushes nothing even after the stub responds",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GENC")
      coord_stop(organization, version, "GCA", "Gen Cancel A", "40.712800", "-74.006000")
      coord_stop(organization, version, "GCB", "Gen Cancel B", "40.713800", "-74.005000")
      cancel_pattern = pattern(organization, version, route, "P-GEN-CANCEL")
      occurrences(cancel_pattern, ["GCA", "GCB"])

      leg = [[-74.006, 40.7128], [-74.0055, 40.7133], [-74.005, 40.7138]]

      Req.Test.stub(@routing_owner, fn conn ->
        Process.sleep(600)

        Plug.Conn.send_resp(
          Plug.Conn.put_resp_content_type(conn, "application/json"),
          200,
          Jason.encode!(routing_response([leg]))
        )
      end)

      {:ok, view, _html} = live(conn, pattern_path(version, route, cancel_pattern))

      view |> element("#alignment-generate-section") |> render_click()
      assert has_element?(view, "#alignment-generating", "Finding a street path…")

      view |> element("#alignment-cancel-generation") |> render_click()
      refute has_element?(view, "#alignment-generating")

      # The stub responds after the sleep; the cancelled flight must push nothing.
      refute_push_event(view, "alignment:suggestions", %{}, 1_500)
      assert segments_count(organization, version) == 0
    end

    test "switching patterns before the result arrives drops it",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GENS")
      coord_stop(organization, version, "GSA", "Gen Switch A", "40.712800", "-74.006000")
      coord_stop(organization, version, "GSB", "Gen Switch B", "40.713800", "-74.005000")
      coord_stop(organization, version, "GSC", "Gen Switch C", "40.714800", "-74.004000")
      coord_stop(organization, version, "GSD", "Gen Switch D", "40.715800", "-74.003000")
      first_pattern = pattern(organization, version, route, "P-GEN-FIRST")
      occurrences(first_pattern, ["GSA", "GSB"])
      second_pattern = pattern(organization, version, route, "P-GEN-SECOND")
      occurrences(second_pattern, ["GSC", "GSD"])

      leg = [[-74.006, 40.7128], [-74.0055, 40.7133], [-74.005, 40.7138]]

      Req.Test.stub(@routing_owner, fn conn ->
        Process.sleep(600)

        Plug.Conn.send_resp(
          Plug.Conn.put_resp_content_type(conn, "application/json"),
          200,
          Jason.encode!(routing_response([leg]))
        )
      end)

      {:ok, view, _html} = live(conn, pattern_path(version, route, first_pattern))

      view |> element("#alignment-generate-section") |> render_click()
      assert has_element?(view, "#alignment-generating", "Finding a street path…")

      render_patch(view, pattern_path(version, route, second_pattern))
      assert has_element?(view, "#alignment-title", "Alignment")
      assert has_element?(view, "#alignment-detail", "Gen Switch C → Gen Switch D")

      # The first pattern's late result must never land on the second pattern.
      refute_push_event(view, "alignment:suggestions", %{}, 1_500)
      assert segments_count(organization, version) == 0
    end

    test "a revoked editor is halted and the key never renders",
         %{conn: conn, user: user, organization: organization, version: version} do
      route = route(organization, version, "GENRV")
      coord_stop(organization, version, "GRVA", "Gen Revoked A", "40.712800", "-74.006000")
      coord_stop(organization, version, "GRVB", "Gen Revoked B", "40.713800", "-74.005000")
      revoked_pattern = pattern(organization, version, route, "P-GEN-REVOKED")
      occurrences(revoked_pattern, ["GRVA", "GRVB"])

      leg = [[-74.006, 40.7128], [-74.0055, 40.7133], [-74.005, 40.7138]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, revoked_pattern))
      assert has_element?(view, "#alignment-generate-all", "Generate street paths")

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      Repo.delete!(membership)

      view |> element("#alignment-generate-all") |> render_click()

      assert has_element?(view, "#pattern-editor-revoked")
      refute_push_event(view, "alignment:suggestions", %{}, 300)
      assert segments_count(organization, version) == 0
      refute render(view) =~ @test_key
    end

    test "an unknown or malformed position pushes nothing and starts nothing",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "GENX")
      coord_stop(organization, version, "GXA", "Gen X A", "40.712800", "-74.006000")
      coord_stop(organization, version, "GXB", "Gen X B", "40.713800", "-74.005000")
      unknown_pattern = pattern(organization, version, route, "P-GEN-UNKNOWN")
      occurrences(unknown_pattern, ["GXA", "GXB"])

      leg = [[-74.006, 40.7128], [-74.0055, 40.7133], [-74.005, 40.7138]]
      stub_json(200, routing_response([leg]))

      {:ok, view, _html} = live(conn, pattern_path(version, route, unknown_pattern))

      render_click(view, "alignment_generate_paths", %{"position" => "999"})
      render_click(view, "alignment_generate_paths", %{"position" => "abc"})

      refute has_element?(view, "#alignment-generating")
      refute_push_event(view, "alignment:suggestions", %{}, 300)
      assert segments_count(organization, version) == 0
    end
  end
end

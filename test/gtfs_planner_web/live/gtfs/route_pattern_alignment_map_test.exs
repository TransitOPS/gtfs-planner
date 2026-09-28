defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentMapTest do
  @moduledoc false
  # Step 23 / EV-22: the PatternAlignment hook contract on the LiveView side
  # (CL-22/FH-33). `alignment_hook_ready` pushes `alignment:load` with the
  # production `Alignments.hook_model/2` (`[lon, lat]` points, verbatim route
  # colour); a tile failure shows the `#alignment-notice` with Retry while
  # the sections stay usable; recovery clears it; inspector selection pushes
  # `alignment:select` for the hook. Every assertion enters through
  # `live(conn, "...?task=alignment")` on the isolated `_align12` database.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.AlignmentSegment
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "align-map-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-map-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)
    conn = log_in_user(conn, user, organization: organization)

    %{conn: conn, organization: organization, version: version}
  end

  # Two sections: 1 saved by a direct override row, 2 missing.
  defp saved_pair(organization, version) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: "MAP1",
        route_short_name: "MAP1",
        route_long_name: "MAP1 corridor"
      })

    for {stop_id, name, lat, lon} <- [
          {"MAP_A", "Map Alpha", "40.712800", "-74.006000"},
          {"MAP_B", "Map Bravo", "40.713800", "-74.005000"},
          {"MAP_C", "Map Charlie", "40.714800", "-74.004000"}
        ] do
      stop_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })
    end

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "P-MAP-A",
        route_pattern_name: "P-MAP-A",
        direction_id: 0
      })

    [occ_a, _occ_b, _occ_c] =
      Enum.map([{"MAP_A", 1}, {"MAP_B", 2}, {"MAP_C", 3}], fn {stop_id, position} ->
        route_pattern_stop_fixture(pattern, stop_id, position)
      end)

    %AlignmentSegment{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      from_occurrence_id: occ_a.id,
      from_stop_id: "MAP_A",
      to_stop_id: "MAP_B"
    }
    |> AlignmentSegment.changeset(%{points: [[-74.005500, 40.713300]]})
    |> Repo.insert!()

    {route, pattern}
  end

  defp pattern_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=alignment"
  end

  describe "alignment map hook contract" do
    setup :editor_scope

    test "hook_ready pushes alignment:load with [lon, lat] points",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = saved_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      assert has_element?(view, "#alignment-map-root")
      assert view |> element("#alignment-map-root") |> render() =~ "phx-hook"

      render_hook(view, "alignment_hook_ready", %{})

      assert_push_event(view, "alignment:load", %{model: model})
      assert is_binary(model.route_color)

      [first | _] = model.sections
      assert first.position == 1
      assert first.kind == "override"
      # Wire order is [lon, lat] (INV-1): negative longitude first.
      assert [[lon, lat]] = first.points
      assert lon < 0 and lat > 0
      assert [lon, lat] == [-74.005500, 40.713300]

      assert [%{position: 1, lat: visit_lat, lon: visit_lon} | _] = model.visits
      assert is_number(visit_lat) and is_number(visit_lon)
    end

    test "tile failure shows the notice with Retry; recovery clears it",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = saved_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      render_hook(view, "alignment_map_error", %{})
      assert has_element?(view, "#alignment-notice", "The background map couldn't load")

      assert has_element?(
               view,
               "#alignment-notice",
               "Your alignment and stop list are still available"
             )

      assert has_element?(view, "#alignment-notice button", "Retry map")
      # The sections stay usable behind the notice.
      assert has_element?(view, "#alignment-section-1")

      view |> element("#alignment-notice button") |> render_click()
      assert_push_event(view, "alignment:retry_tiles", %{})

      render_hook(view, "alignment_map_ok", %{})
      refute has_element?(view, "#alignment-notice")
    end

    test "inspector selection pushes alignment:select for the hook",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = saved_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-section-2") |> render_click()
      assert_push_event(view, "alignment:select", %{position: 2})
      assert has_element?(view, "#alignment-detail", "Map Bravo")
    end
  end
end

defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentImportTest do
  @moduledoc false
  # Step 29 / EV-28: the import review UI for patterns still on imported
  # shapes (CL-28/FH-41): the imported notice with its review entry point,
  # the single-shape dialog (length, visits, points), the divergent radios
  # with trip counts and the all-trips warning, and the alignment:convert
  # push for the chosen shape. Conversion only drafts (CR-9); saving the
  # replacement is EV-27/EV-17 territory.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "align-import-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-import-#{System.unique_integer([:positive])}@example.com"})

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

  defp shape_rows(organization, version, shape_id, rows) do
    for {sequence, lat, lon, dist} <- rows do
      %Shape{}
      |> Shape.changeset(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        shape_id: shape_id,
        shape_pt_sequence: sequence,
        shape_pt_lat: lat,
        shape_pt_lon: lon,
        shape_dist_traveled: dist
      })
      |> Repo.insert!()
    end
  end

  defp link_trip(organization, version, route, pattern, timing, trip_id, shape_id) do
    trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: trip_id,
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })
  end

  defp pattern_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=alignment"
  end

  # One pattern on a single three-point imported shape: no segments, so
  # every section is missing and the export reads :imported.
  defp single_imported(organization, version) do
    route = route(organization, version, "IMP1")

    coord_stop(organization, version, "IM1_A", "Import Alpha", "40.740800", "-73.987000")
    coord_stop(organization, version, "IM1_B", "Import Bravo", "40.741800", "-73.986000")

    pattern = pattern(organization, version, route, "P-IMPORT-SINGLE")
    occurrences(pattern, ["IM1_A", "IM1_B"])
    timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

    shape_rows(organization, version, "IMP-SINGLE", [
      {0, "40.740800", "-73.987000", "0"},
      {1, "40.741300", "-73.986500", "70.2"},
      {2, "40.741800", "-73.986000", "139.5"}
    ])

    link_trip(organization, version, route, pattern, timing, "IMP_SINGLE_T1", "IMP-SINGLE")

    {route, pattern}
  end

  # One pattern whose linked trips diverge across two shapes: X on two
  # trips, Y on one.
  defp divergent_imported(organization, version) do
    route = route(organization, version, "IMP2")

    coord_stop(organization, version, "IM2_A", "Divergent Alpha", "40.742800", "-73.985000")
    coord_stop(organization, version, "IM2_B", "Divergent Bravo", "40.743800", "-73.984000")

    pattern = pattern(organization, version, route, "P-IMPORT-DIVERGENT")
    occurrences(pattern, ["IM2_A", "IM2_B"])
    timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

    shape_rows(organization, version, "IMP-DIV-X", [
      {0, "40.742800", "-73.985000", "0"},
      {1, "40.743800", "-73.984000", "139.5"}
    ])

    shape_rows(organization, version, "IMP-DIV-Y", [
      {0, "40.742900", "-73.985100", "0"},
      {1, "40.743900", "-73.984100", "141.0"}
    ])

    link_trip(organization, version, route, pattern, timing, "IMP_DIV_X1", "IMP-DIV-X")
    link_trip(organization, version, route, pattern, timing, "IMP_DIV_X2", "IMP-DIV-X")
    link_trip(organization, version, route, pattern, timing, "IMP_DIV_Y1", "IMP-DIV-Y")

    {route, pattern}
  end

  describe "imported shape review" do
    setup :editor_scope

    test "a single imported shape shows the notice with a review entry point",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      assert has_element?(view, "#alignment-notice", "Imported path · original shape retained")
      assert has_element?(view, "#alignment-review-import", "Review imported path")
    end

    test "the single-shape dialog names length, visits and points",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()

      assert has_element?(view, "#alignment-import-dialog[data-open=\"true\"]")
      assert has_element?(view, "#alignment-import-dialog", "Review imported path")
      assert has_element?(view, "#alignment-import-dialog", "Shape IMP-SINGLE")
      assert has_element?(view, "#alignment-import-dialog", "0.1 km")
      assert has_element?(view, "#alignment-import-dialog", "2 visits")
      assert has_element?(view, "#alignment-import-dialog", "3 imported points")
      assert has_element?(view, "#alignment-import-dialog-cancel", "Keep original")

      assert has_element?(
               view,
               "#alignment-import-dialog-confirm",
               "Create editable draft"
             )
    end

    test "confirming the single-shape dialog pushes alignment:convert",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()
      view |> element("#alignment-import-dialog-confirm") |> render_click()

      assert_push_event(view, "alignment:convert", %{shape_id: "IMP-SINGLE"})
    end

    test "Keep original only closes the dialog",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()
      assert has_element?(view, "#alignment-import-dialog[data-open=\"true\"]")

      view |> element("#alignment-import-dialog-cancel") |> render_click()
      assert has_element?(view, "#alignment-import-dialog[data-open=\"false\"]")
      refute_push_event(view, "alignment:convert", %{})
    end

    test "divergent shapes list trip counts and convert the chosen shape",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = divergent_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      assert has_element?(view, "#alignment-notice", "This pattern uses 2 imported shapes")
      assert has_element?(view, "#alignment-review-import", "Compare shapes")

      view |> element("#alignment-review-import") |> render_click()

      assert has_element?(view, "#alignment-import-dialog[data-open=\"true\"]")
      assert has_element?(view, "#alignment-import-dialog", "Choose an imported path")
      assert has_element?(view, "#alignment-import-dialog", "Shape IMP-DIV-X")
      assert has_element?(view, "#alignment-import-dialog", "2 trips")
      assert has_element?(view, "#alignment-import-dialog", "Shape IMP-DIV-Y")
      assert has_element?(view, "#alignment-import-dialog", "1 trip")

      assert has_element?(
               view,
               "#alignment-import-dialog",
               "Saving the replacement would affect all 3 trips."
             )

      view
      |> element("#alignment-import-form")
      |> render_change(%{"import_shape" => "IMP-DIV-Y"})

      view |> element("#alignment-import-dialog-confirm") |> render_click()

      assert_push_event(view, "alignment:convert", %{shape_id: "IMP-DIV-Y"})
    end
  end
end

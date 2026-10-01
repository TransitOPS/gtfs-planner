defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentImportTest do
  @moduledoc false
  # Step 29 / EV-28 and step 32 / EV-31: the review for patterns still on
  # imported shapes (CL-28/FH-41, CL-26/FH-26). The notice keeps its entry
  # point; opening it now renders the imported-line card in the panel rather
  # than a dialog, names the shape's length, visits and points, shows the
  # chooser when the trips diverge, renders the hook's fit review, and pushes
  # the chosen shape's points for measurement and alignment:convert for the
  # draft. Conversion only drafts (CR-9); saving the replacement is
  # EV-27/EV-17 territory.
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
      refute has_element?(view, "#imported-line-card")
    end

    test "opening the card renders the fit review and no dialog",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()

      assert has_element?(view, "#imported-line-card")
      refute has_element?(view, "#alignment-import-dialog")

      # Card anatomy: the shape's own identity, trips and length.
      assert has_element?(view, "#imported-line-card", "Imported shape IMP-SINGLE")
      assert has_element?(view, "#imported-line-card", "0.1 km")
      assert has_element?(view, "#imported-line-card", "3 points")
      assert has_element?(view, "#imported-line-card", "2 visits")
      assert has_element?(view, "#imported-line-card", "Nothing changes until you save")

      # The hook has not reported a fit yet, so the card waits rather than
      # measuring the shape itself.
      assert has_element?(view, "#imported-line-checking")
      refute has_element?(view, "#file-fit-review")
    end

    test "the card's fit review renders the hook's report for the chosen shape",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()

      render_hook(view, "alignment_fit_result", %{
        "direction" => "same",
        "reaches_start" => true,
        "reaches_end" => true,
        "far" => [%{"position" => 2, "distance_m" => 180.0}],
        "within" => 1,
        "visit_count" => 2,
        "length_m" => 139.5
      })

      assert has_element?(view, "#imported-line-card #file-fit-review")
      assert has_element?(view, "#imported-line-card #file-fit-headline", "1 of 2")
      assert has_element?(view, "#imported-line-card #fit-far", "Import Bravo")
      # A reversed fit cannot be drafted; an "unknown" one can (INV-5).
      assert has_element?(view, "#imported-line-draft")

      render_hook(view, "alignment_fit_result", %{
        "direction" => "unknown",
        "reaches_start" => true,
        "reaches_end" => true,
        "far" => [],
        "within" => 2,
        "visit_count" => 2,
        "length_m" => 139.5
      })

      assert has_element?(view, "#imported-line-card #fit-direction-unknown")
      assert has_element?(view, "#imported-line-draft:not([disabled])")
      assert has_element?(view, "#imported-line-card #file-fit-headline", "2 of 2")

      render_hook(view, "alignment_fit_result", %{
        "direction" => "reversed",
        "reaches_start" => true,
        "reaches_end" => true,
        "far" => [],
        "within" => 2,
        "visit_count" => 2,
        "length_m" => 139.5
      })

      assert has_element?(view, "#imported-line-draft[disabled]")
    end

    test "opening the card pushes the chosen shape's points to the hook",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()

      assert_push_event(view, "alignment:file_line", %{points: points, name: "IMP-SINGLE"})

      assert points == [
               [-73.987, 40.7408],
               [-73.9865, 40.7413],
               [-73.986, 40.7418]
             ]
    end

    test "Create editable draft pushes alignment:convert for the shown shape",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()
      view |> element("#imported-line-draft") |> render_click()

      assert_push_event(view, "alignment:clear_file_line", %{})
      assert_push_event(view, "alignment:convert", %{shape_id: "IMP-SINGLE"})
      refute has_element?(view, "#imported-line-card")
    end

    test "closing the card drops the fit and pushes nothing",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = single_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      view |> element("#alignment-review-import") |> render_click()
      view |> element("#imported-line-close") |> render_click()

      refute has_element?(view, "#imported-line-card")
      assert_push_event(view, "alignment:clear_file_line", %{})
      refute_push_event(view, "alignment:convert", %{})
    end

    test "divergent shapes render the chooser in the card and measure the chosen one",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = divergent_imported(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern))

      assert has_element?(view, "#alignment-notice", "This pattern uses 2 imported shapes")
      assert has_element?(view, "#alignment-review-import", "Compare shapes")

      view |> element("#alignment-review-import") |> render_click()

      assert has_element?(view, "#imported-line-card")
      refute has_element?(view, "#alignment-import-dialog")
      assert has_element?(view, "#imported-line-card", "Imported shape IMP-DIV-X")
      assert has_element?(view, "label[for=imported-shape-IMP-DIV-X]", "2 trips")
      assert has_element?(view, "label[for=imported-shape-IMP-DIV-Y]", "1 trip")
      assert has_element?(view, "#imported-line-card", "Saving the replacement would affect all 3 trips.")

      view
      |> element("#imported-shape-form")
      |> render_change(%{"import_shape" => "IMP-DIV-Y"})

      assert has_element?(view, "#imported-line-card", "Imported shape IMP-DIV-Y")
      assert_push_event(view, "alignment:file_line", %{points: points, name: "IMP-DIV-Y"})
      assert length(points) == 2

      view |> element("#imported-line-draft") |> render_click()

      assert_push_event(view, "alignment:convert", %{shape_id: "IMP-DIV-Y"})
    end
  end
end

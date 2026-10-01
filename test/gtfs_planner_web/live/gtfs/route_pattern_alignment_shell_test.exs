defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentShellTest do
  @moduledoc false
  # Step 20 / EV-19: the Alignment task renders the server-side shell from
  # `Gtfs.alignment_editor/4` (CL-10/FH-19, CL-22/FH-33): sections with
  # statuses and scope labels from DB rows, loop labels, the read-only viewer
  # branch, server-side section selection, R9 footer states, and no placeholder
  # or generation control. Every assertion enters through
  # `live(conn, "...?task=alignment")` except the viewer branch, which is
  # proven at the component boundary: the router gate redirects members
  # without the editor role before render (see the redirect test below), so
  # only editors ever reach the LiveView.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Alignments
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo
  alias GtfsPlannerWeb.Gtfs.RoutePatternAlignmentComponents

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "align-shell-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-shell-#{System.unique_integer([:positive])}@example.com"})

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

  defp audit(organization, version) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: Ecto.UUID.generate(),
      actor_email: "align-shell@example.com"
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

  # Draws the given sections through the production review/apply composition.
  # `scopes` maps position strings to "shared" or "local" and only needs
  # entries where the review asks for a scope decision.
  defp draw!(pattern, entries, scopes, audit_context) do
    pattern = Repo.reload!(pattern)

    draft =
      Enum.map(entries, fn {position, points} ->
        set_entry(section_at(pattern, position), points)
      end)

    {:ok, review} = Gtfs.review_alignment_save(pattern.id, draft, audit_context)

    needed =
      for section <- review.sections,
          section.action == :choose_scope,
          into: %{},
          do: {to_string(section.position), Map.fetch!(scopes, to_string(section.position))}

    choices = %{"scopes" => needed}

    choices =
      if review.requires_confirmation?,
        do: Map.put(choices, "confirm_replacements", true),
        else: choices

    {:ok, _result} =
      Gtfs.apply_alignment_save(pattern.id, draft, choices, review.fingerprint, audit_context)
  end

  defp pattern_path(version, route, pattern, query) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{query}"
  end

  # Four visits: section 1 shared with a second pattern, section 2 a local
  # override beside a shared path (Custom path), section 3 missing.
  defp drawn_pair(organization, version) do
    route = route(organization, version, "SHELL1")

    coord_stop(organization, version, "SH1_A", "Shell Alpha", "40.712800", "-74.006000")
    coord_stop(organization, version, "SH1_B", "Shell Bravo", "40.713800", "-74.005000")
    coord_stop(organization, version, "SH1_C", "Shell Charlie", "40.714800", "-74.004000")
    coord_stop(organization, version, "SH1_D", "Shell Delta", "40.715800", "-74.003000")

    first =
      pattern(organization, version, route, "P-SHELL-A")

    occurrences(first, ["SH1_A", "SH1_B", "SH1_C", "SH1_D"])

    second = pattern(organization, version, route, "P-SHELL-B")
    occurrences(second, ["SH1_A", "SH1_B", "SH1_C"])

    audit_context = audit(organization, version)

    draw!(
      first,
      [{1, [[-74.005500, 40.713300]]}, {2, [[-74.004500, 40.714300]]}],
      %{"1" => "shared", "2" => "local"},
      audit_context
    )

    draw!(second, [{2, [[-74.004600, 40.714200]]}], %{"2" => "shared"}, audit_context)

    {route, Repo.reload!(first)}
  end

  describe "alignment shell" do
    setup :editor_scope

    test "renders sections with statuses and scope labels from DB rows",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      assert has_element?(view, "#alignment-task")
      assert has_element?(view, "h2#alignment-title", "Path between stops")
      assert has_element?(view, "#alignment-status", "! 1 missing")

      assert has_element?(view, "#alignment-section-1", "Shell Alpha")
      assert has_element?(view, "#alignment-section-1", "Shell Bravo")
      assert has_element?(view, "#alignment-section-status-1", "✓ Saved")
      assert has_element?(view, "#alignment-section-1", "Shared by 2 patterns")

      assert has_element?(view, "#alignment-section-status-2", "✓ Saved")
      assert has_element?(view, "#alignment-section-2", "Custom path")

      assert has_element?(view, "#alignment-section-status-3", "! Missing")
      assert has_element?(view, "#alignment-section-3", "This pattern")

      assert has_element?(
               view,
               "#alignment-footer",
               "Add the missing paths to complete this pattern."
             )
    end

    test "renders blocked sections from DB rows",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "SHELL2")

      stop_fixture(organization.id, version.id, %{
        stop_id: "SH2_A",
        stop_name: "Shell Nocoord",
        stop_lat: nil,
        stop_lon: nil
      })

      coord_stop(organization, version, "SH2_B", "Shell Fixed", "40.720000", "-74.010000")

      pattern = pattern(organization, version, route, "P-SHELL-BLOCKED")
      occurrences(pattern, ["SH2_A", "SH2_B"])

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      assert has_element?(view, "#alignment-section-status-1", "⚠ Blocked")
      assert has_element?(view, "#alignment-status", "⚠ Blocked")
      assert has_element?(view, "#alignment-detail", "no coordinates")
    end

    test "shows the repeated-stop label for loop traversals",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "SHELL3")

      coord_stop(organization, version, "SH3_A", "Loop Alpha", "40.712800", "-74.006000")
      coord_stop(organization, version, "SH3_B", "Loop Bravo", "40.713800", "-74.005000")
      coord_stop(organization, version, "SH3_C", "Loop Charlie", "40.714800", "-74.004000")

      pattern = pattern(organization, version, route, "P-SHELL-LOOP")
      occurrences(pattern, ["SH3_A", "SH3_B", "SH3_C", "SH3_A", "SH3_B"])

      draw!(
        pattern,
        [
          {1, [[-74.005500, 40.713300]]},
          {2, [[-74.004500, 40.714300]]},
          {3, [[-74.005000, 40.713500]]},
          {4, [[-74.005600, 40.713200]]}
        ],
        %{"1" => "shared", "4" => "shared"},
        audit(organization, version)
      )

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      assert has_element?(view, "#alignment-section-4", "Visit 4 → 5")

      render_click(element(view, "#alignment-section-4"))

      assert has_element?(view, "#alignment-detail[data-position='4']", "1 / 4")
    end

    test "selecting a section updates the detail",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      assert has_element?(view, "#alignment-section-1 + #alignment-detail[data-position='1']")

      render_click(element(view, "#alignment-section-2"))

      assert has_element?(view, "#alignment-section-2[aria-pressed='true']")
      assert has_element?(view, "#alignment-section-2 + #alignment-detail[data-position='2']")
      assert has_element?(view, "#alignment-section-2", "Shell Bravo")
      assert has_element?(view, "#alignment-section-2", "Shell Charlie")

      # An unknown position leaves the selection unchanged instead of crashing.
      render_click(view, "alignment_select_section", %{"position" => "99"})
      assert has_element?(view, "#alignment-detail[data-position='2']")
    end

    test "footer states the R9 export status",
         %{conn: conn, organization: organization, version: version} do
      {route, incomplete} = drawn_pair(organization, version)

      coord_stop(organization, version, "SH4_A", "Export Alpha", "40.730800", "-73.997000")
      coord_stop(organization, version, "SH4_B", "Export Bravo", "40.731800", "-73.996000")
      coord_stop(organization, version, "SH4_C", "Export Charlie", "40.732800", "-73.995000")

      current = pattern(organization, version, route, "P-SHELL-CURRENT")
      occurrences(current, ["SH4_A", "SH4_B", "SH4_C"])

      draw!(
        current,
        [{1, [[-73.996500, 40.731200]]}, {2, [[-73.995500, 40.732200]]}],
        %{},
        audit(organization, version)
      )

      {:ok, incomplete_view, _html} =
        live(conn, pattern_path(version, route, incomplete, "?task=alignment"))

      assert has_element?(incomplete_view, "#alignment-status", "! 1 missing")

      assert has_element?(
               incomplete_view,
               "#alignment-footer",
               "Add the missing paths to complete this pattern."
             )

      {:ok, current_view, _html} =
        live(conn, pattern_path(version, route, current, "?task=alignment"))

      assert has_element?(current_view, "#alignment-status", "✓ Exported")

      assert has_element?(
               current_view,
               "#alignment-footer",
               "Saved paths are included in shapes.txt."
             )
    end

    test "shows the imported-shape notice for linked imported trips",
         %{conn: conn, organization: organization, version: version} do
      route = route(organization, version, "SHELL5")

      coord_stop(organization, version, "SH5_A", "Import Alpha", "40.740800", "-73.987000")
      coord_stop(organization, version, "SH5_B", "Import Bravo", "40.741800", "-73.986000")

      pattern = pattern(organization, version, route, "P-SHELL-IMPORTED")
      occurrences(pattern, ["SH5_A", "SH5_B"])
      timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

      %Shape{}
      |> Shape.changeset(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        shape_id: "IMP-SHELL",
        shape_pt_sequence: 0,
        shape_pt_lat: "40.740800",
        shape_pt_lon: "-73.987000",
        shape_dist_traveled: "0"
      })
      |> Repo.insert!()

      %Shape{}
      |> Shape.changeset(%{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        shape_id: "IMP-SHELL",
        shape_pt_sequence: 1,
        shape_pt_lat: "40.741800",
        shape_pt_lon: "-73.986000",
        shape_dist_traveled: "120.5"
      })
      |> Repo.insert!()

      trip =
        trip_fixture(organization.id, version.id, route.route_id, %{
          trip_id: "SHELL_IMP_T",
          shape_id: "IMP-SHELL"
        })

      trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: "P-SHELL-IMPORTED",
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      assert has_element?(view, "#alignment-notice", "Imported path")
      assert has_element?(view, "#alignment-footer", "Imported shape")
    end

    test "renders no placeholder and the step-32 generation entry point",
         %{conn: conn, organization: organization, version: version} do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      refute has_element?(view, "#coming-soon")
      # CR-10's slice-A restriction is lifted for these controls only:
      # the selected saved section offers street generation under its rare
      # actions (the replace dialog asks first), while Save stays the only commit.
      assert has_element?(view, "#alignment-generate-section", "Replace with a street path")
      assert has_element?(view, "#alignment-save[disabled]")
    end

    test "members without the editor role cannot reach the shell",
         %{conn: conn, organization: organization, version: version} do
      member =
        user_fixture(%{email: "shell-member-#{System.unique_integer([:positive])}@example.com"})

      Accounts.create_user_org_membership(%{
        user_id: member.id,
        organization_id: organization.id,
        roles: []
      })

      {route, pattern} = drawn_pair(organization, version)
      member_conn = log_in_user(conn, member, organization: organization)

      assert {:error, {:redirect, %{to: "/admin/organizations"}}} =
               live(member_conn, pattern_path(version, route, pattern, "?task=alignment"))
    end

    test "the read-only branch renders the notice and a Save that cannot run" do
      # The router gate above keeps non-editors off the LiveView, so the
      # viewer rendering is proven at the component boundary with the same
      # assigns the LiveView passes.
      organization = organization_fixture(%{alias: "align-shell-ro-#{System.unique_integer()}"})
      version = gtfs_version_fixture(organization.id)
      route = route(organization, version, "SHELLRO")

      coord_stop(organization, version, "SHR_A", "Read Alpha", "40.750800", "-73.977000")
      coord_stop(organization, version, "SHR_B", "Read Bravo", "40.751800", "-73.976000")

      pattern = pattern(organization, version, route, "P-SHELL-RO")
      occurrences(pattern, ["SHR_A", "SHR_B"])

      {:ok, alignment} =
        Gtfs.alignment_editor(organization.id, version.id, route.route_id, "P-SHELL-RO")

      html =
        render_component(&RoutePatternAlignmentComponents.alignment_task/1,
          alignment: alignment,
          state: %{
            dirty_positions: [],
            selected: 1,
            mode: "pan",
            selected_point_count: 0,
            point_count: 0,
            can_undo: false,
            can_redo: false,
            flagged_positions: [],
            review_positions: []
          },
          notice: :read_only,
          dialog_open: false,
          editable?: false,
          offline?: false,
          # The download menu's links are scoped to this published version.
          version_id: version.id,
          version_name: version.name,
          organization_name: organization.name,
          # The path-file panel is not rendered here, but the upload it takes
          # is a required attr of the task shell.
          map_line_upload: %Phoenix.LiveView.UploadConfig{}
        )

      assert html =~ "alignment-notice"
      assert html =~ "You can view this map line"

      # Save is rendered by the page's save bar from this state.
      save =
        RoutePatternAlignmentComponents.save_state(%{
          alignment: alignment,
          editable?: false,
          offline?: false,
          applying?: false,
          dirty_positions: [],
          generating?: false
        })

      refute save.enabled?
      assert save.title == "Only editors can save the map line."
    end
  end
end

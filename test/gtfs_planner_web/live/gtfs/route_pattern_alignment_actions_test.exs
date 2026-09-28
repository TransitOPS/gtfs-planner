defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentActionsTest do
  @moduledoc false
  # Step 26 / EV-25: section-level draft actions (CL-23/FH-34, FH-35).
  # Draw/Clear/Use shared dispatch DOM actions to the hook (asserted in
  # the hook test); here the LiveView owns per-kind buttons, the delete
  # and simplify dialogs with their hook pushes, and the status messages
  # for simplify results and hook notices. Every assertion enters through
  # `live(conn, "...?task=alignment")` on the isolated `_align12`
  # database; persistence is EV-27 territory.
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
  alias GtfsPlanner.Repo

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "align-act-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-act-#{System.unique_integer([:positive])}@example.com"})

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
      organization_fixture(%{alias: "align-act-view-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-act-view-#{System.unique_integer([:positive])}@example.com"})

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

  defp audit(organization, version) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: Ecto.UUID.generate(),
      actor_email: "align-act@example.com"
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

  # Four visits: section 1 shared with three interior points (chain 5, so
  # Simplify shows), section 2 a local override beside a shared path
  # (chain 3, so Simplify hides but Use shared path shows), section 3
  # missing (Draw manually shows).
  defp drawn_pair(organization, version) do
    route = route(organization, version, "ACT1")

    coord_stop(organization, version, "ACT_A", "Act Alpha", "40.712800", "-74.006000")
    coord_stop(organization, version, "ACT_B", "Act Bravo", "40.713800", "-74.005000")
    coord_stop(organization, version, "ACT_C", "Act Charlie", "40.714800", "-74.004000")
    coord_stop(organization, version, "ACT_D", "Act Delta", "40.715800", "-74.003000")

    first = pattern(organization, version, route, "P-ACT-A")
    occurrences(first, ["ACT_A", "ACT_B", "ACT_C", "ACT_D"])

    second = pattern(organization, version, route, "P-ACT-B")
    occurrences(second, ["ACT_A", "ACT_B", "ACT_C"])

    audit_context = audit(organization, version)

    draw!(
      first,
      [
        {1, [[-74.005700, 40.713100], [-74.005500, 40.713300], [-74.005200, 40.713600]]},
        {2, [[-74.004500, 40.714300]]}
      ],
      %{"1" => "shared", "2" => "local"},
      audit_context
    )

    draw!(second, [{2, [[-74.004600, 40.714200]]}], %{"2" => "shared"}, audit_context)

    {route, Repo.reload!(first)}
  end

  describe "section actions" do
    setup :editor_scope

    test "shows Draw manually on a missing section", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      render_click(element(view, "#alignment-section-3"))

      assert has_element?(view, "#alignment-detail", "Draw manually")
      assert has_element?(view, "#alignment-draw", "Draw manually")
      refute has_element?(view, "#alignment-clear")
      refute has_element?(view, "#alignment-delete-open")
    end

    test "shows More section actions per kind on saved sections", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      # Section 1 is shared: Clear and Delete show, Use shared path does not.
      assert has_element?(view, "#alignment-detail", "More section actions")
      assert has_element?(view, "#alignment-clear", "Clear interior points")
      assert has_element?(view, "#alignment-delete-open", "Delete section")
      refute has_element?(view, "#alignment-use-shared")

      # Section 2 is an override beside a shared path: Use shared path shows.
      render_click(element(view, "#alignment-section-2"))
      assert has_element?(view, "#alignment-use-shared", "Use shared path")
    end

    test "shows Simplify only for sections with at least 4 points", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      # Section 1 holds three interior points plus two anchors.
      assert has_element?(view, "#alignment-simplify-open", "Simplify")

      # Section 2 holds one interior point: no Simplify. Section 3 is missing.
      render_click(element(view, "#alignment-section-2"))
      refute has_element?(view, "#alignment-simplify-open")

      render_click(element(view, "#alignment-section-3"))
      refute has_element?(view, "#alignment-simplify-open")
    end

    test "opens the delete dialog naming the section and pushes the delete", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      render_click(element(view, "#alignment-section-2"))
      render_click(element(view, "#alignment-delete-open"))

      assert has_element?(view, "#alignment-delete-dialog", "Delete this section's path?")
      assert has_element?(view, "#alignment-delete-dialog", "Act Bravo → Act Charlie")
      assert has_element?(view, "#alignment-delete-dialog-confirm", "Delete path")

      render_click(element(view, "#alignment-delete-dialog-confirm"))
      assert_push_event(view, "alignment:delete_section", %{position: 2})
      assert has_element?(view, "#alignment-delete-dialog[data-open='false']")
    end

    test "ignores the delete dialog for unknown positions", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      render_click(view, "alignment_open_delete", %{"position" => "99"})
      assert has_element?(view, "#alignment-delete-dialog[data-open='false']")
    end

    test "opens the simplify dialog with 10 m selected and pushes the tolerance", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      render_click(element(view, "#alignment-simplify-open"))

      assert has_element?(view, "#alignment-simplify-dialog", "Simplify this section")
      assert has_element?(view, "#alignment-simplify-dialog", "Maximum path deviation")

      html = render(view)
      assert html =~ ~s(<option value="10" selected)
      assert html =~ "5 metres · preserve detail"
      assert html =~ "25 metres · fewer points"

      view
      |> form("#alignment-simplify-tolerance-form")
      |> render_change(%{"tolerance_m" => "25"})

      render_click(element(view, "#alignment-simplify-dialog-confirm"))
      assert_push_event(view, "alignment:simplify", %{position: 1, tolerance_m: 25})
      assert has_element?(view, "#alignment-simplify-dialog[data-open='false']")
    end

    test "reports simplify results in the status region", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      render_hook(view, "alignment_simplify_result", %{"removed" => 3})
      assert has_element?(view, "#status", "3 points removed. Undo restores them.")

      render_hook(view, "alignment_simplify_result", %{"removed" => 1})
      assert has_element?(view, "#status", "1 point removed. Undo restores them.")

      render_hook(view, "alignment_simplify_result", %{"removed" => 0})

      assert has_element?(
               view,
               "#status",
               "No points can be removed at this tolerance. Path unchanged."
             )
    end

    test "announces hook section actions in the status region", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      render_hook(view, "alignment_action_notice", %{
        "message" => "Interior points cleared. A straight draft remains. Undo is available."
      })

      assert has_element?(
               view,
               "#status",
               "Interior points cleared. A straight draft remains. Undo is available."
             )

      render_hook(view, "alignment_action_notice", %{"message" => ""})
      render_hook(view, "alignment_simplify_result", %{"removed" => "many"})

      assert has_element?(
               view,
               "#status",
               "Interior points cleared. A straight draft remains. Undo is available."
             )
    end
  end

  describe "section actions as a viewer" do
    setup :viewer_scope

    test "viewers never reach the alignment actions", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route = route(organization, version, "ACTV")
      coord_stop(organization, version, "ACTV_A", "Act View A", "40.712800", "-74.006000")
      coord_stop(organization, version, "ACTV_B", "Act View B", "40.713800", "-74.005000")
      viewer_pattern = pattern(organization, version, route, "P-ACT-V")
      occurrences(viewer_pattern, ["ACTV_A", "ACTV_B"])

      assert {:error, {:redirect, _}} =
               live(conn, pattern_path(version, route, viewer_pattern, "?task=alignment"))
    end
  end
end

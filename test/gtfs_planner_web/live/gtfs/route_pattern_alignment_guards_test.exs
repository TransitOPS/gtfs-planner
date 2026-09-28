defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentGuardsTest do
  @moduledoc false
  # Step 27 / EV-26: alignment drafts wired into the editor guards
  # (CL-26/FH-39). The hook owns draft geometry (CR-5); here the LiveView
  # owns the badges, the dirty guard, the in-place discard dialog and the
  # offline commit marker. Every assertion enters through
  # `live(conn, "...?task=alignment")` on the isolated `_align12`
  # database; persistence is EV-27 territory and a real socket drop is
  # EV-29 territory.
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
      organization_fixture(%{alias: "align-grd-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-grd-#{System.unique_integer([:positive])}@example.com"})

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
      actor_email: "align-grd@example.com"
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

  # Four visits: sections 1 and 2 saved (shared, then a local override),
  # section 3 missing. Section 2 is the dirty-position target, section 3
  # the flagged-position target.
  defp drawn_pair(organization, version) do
    route = route(organization, version, "GRD1")

    coord_stop(organization, version, "GRD_A", "Grd Alpha", "40.712800", "-74.006000")
    coord_stop(organization, version, "GRD_B", "Grd Bravo", "40.713800", "-74.005000")
    coord_stop(organization, version, "GRD_C", "Grd Charlie", "40.714800", "-74.004000")
    coord_stop(organization, version, "GRD_D", "Grd Delta", "40.715800", "-74.003000")

    first = pattern(organization, version, route, "P-GRD-A")
    occurrences(first, ["GRD_A", "GRD_B", "GRD_C", "GRD_D"])

    second = pattern(organization, version, route, "P-GRD-B")
    occurrences(second, ["GRD_A", "GRD_B", "GRD_C"])

    audit_context = audit(organization, version)

    draw!(
      first,
      [
        {1, [[-74.005700, 40.713100], [-74.005500, 40.713300]]},
        {2, [[-74.004500, 40.714300]]}
      ],
      %{"1" => "shared", "2" => "local"},
      audit_context
    )

    draw!(second, [{1, [[-74.005600, 40.713200]]}], %{"1" => "shared"}, audit_context)

    {route, Repo.reload!(first)}
  end

  defp dirty_state(view, positions) do
    render_hook(view, "alignment_draft_state", %{"dirty_positions" => positions})
  end

  describe "draft guards" do
    setup :editor_scope

    test "draft state marks the badges and pushes the dirty guard", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      dirty_state(view, [2])

      assert has_element?(view, "#alignment-status", "◷ Unsaved changes")
      assert has_element?(view, "#alignment-section-status-2", "◷ Unsaved")
      assert has_element?(view, "#alignment-discard", "Discard changes")
      assert_push_event(view, "route_pattern_dirty", %{dirty: true})
    end

    test "flagged positions ask for review on that section", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      render_hook(view, "alignment_draft_state", %{"flagged_positions" => [3]})

      assert has_element?(view, "#alignment-section-status-3", "Check this section")
      # Flags alone are not drafts: no unsaved badges and no dirty guard.
      refute has_element?(view, "#alignment-status", "◷ Unsaved changes")
      refute has_element?(view, "#alignment-discard")
    end

    test "a dirty task switch opens the existing discard dialog", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      dirty_state(view, [2])
      assert_push_event(view, "route_pattern_dirty", %{dirty: true})

      render_click(element(view, "#pattern-task-stops"))

      # The existing navigation guard opens; the draft stays on the page.
      assert has_element?(view, "#discard-changes-dialog", "Discard unsaved changes?")
      assert has_element?(view, "#alignment-task")
      assert has_element?(view, "#alignment-status", "◷ Unsaved changes")

      # Keep editing preserves the dirty state and the badges.
      render_click(element(view, "#discard-changes-dialog-cancel"))

      assert has_element?(view, "#alignment-status", "◷ Unsaved changes")
      assert has_element?(view, "#alignment-section-status-2", "◷ Unsaved")
      assert has_element?(view, "#alignment-task")
    end

    test "discarding pushes the saved model and clears on the next clean state", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      dirty_state(view, [2])
      assert_push_event(view, "route_pattern_dirty", %{dirty: true})

      render_click(element(view, "#alignment-discard"))

      assert has_element?(view, "#alignment-discard-dialog", "Discard unsaved changes?")

      assert has_element?(
               view,
               "#alignment-discard-dialog",
               "Your saved path will stay unchanged."
             )

      render_click(element(view, "#alignment-discard-dialog-confirm"))

      assert_push_event(view, "alignment:load", %{model: model})
      assert length(model.sections) == 3

      # The draft stays dirty until the hook confirms the clean redraw.
      assert has_element?(view, "#alignment-status", "◷ Unsaved changes")

      dirty_state(view, [])
      assert_push_event(view, "route_pattern_dirty", %{dirty: false})

      assert has_element?(view, "#alignment-section-status-2", "✓ Saved")
      refute has_element?(view, "#alignment-discard")
    end

    test "the save control carries the offline commit marker", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      assert has_element?(view, "#alignment-save[data-commit='alignment']")
    end

    test "a fresh mount restores the badges from the hook push", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route, pattern} = drawn_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=alignment"))

      # The reconnect path: a fresh mount followed by the hook's draft
      # push restores the unsaved badges without any stored server draft.
      render_hook(view, "alignment_draft_state", %{"dirty_positions" => [2]})

      assert has_element?(view, "#alignment-status", "◷ Unsaved changes")
      assert has_element?(view, "#alignment-section-status-2", "◷ Unsaved")
      assert_push_event(view, "route_pattern_dirty", %{dirty: true})
    end
  end
end

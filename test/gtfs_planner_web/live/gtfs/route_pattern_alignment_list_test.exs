defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentListTest do
  @moduledoc false
  # Step 35 / EV-35: Route › Patterns shows each pattern's alignment status
  # from the batched `Gtfs.route_alignment_summary/3` read and links by
  # `push_patch` to the pattern's Alignment task (CL-31/FH-44). Every
  # assertion enters through `live(conn, ".../patterns")` on the isolated
  # `_align12` database; the summary math itself is EV-34 territory.
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
      organization_fixture(%{alias: "align-lst-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-lst-#{System.unique_integer([:positive])}@example.com"})

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

  defp coord_stop(organization, version, stop_id, lat, lon) do
    stop_fixture(organization.id, version.id, %{
      stop_id: stop_id,
      stop_name: stop_id,
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

  defp patterns_path(version, route),
    do: "/gtfs/#{version.id}/routes/#{route.route_id}/patterns"

  # Four patterns on one route, one per badge state: two missing sections,
  # a materialized export, a stale digest, and an imported shape reached
  # through another pattern's shared section. Stop pairs never repeat
  # across patterns except the deliberate shared pair, so no other
  # pattern's sections leak into these statuses.
  defp four_status_route(organization, version) do
    route = route(organization, version, "LST1")

    coord_stop(organization, version, "LST_MA", "40.712800", "-74.006000")
    coord_stop(organization, version, "LST_MB", "40.713800", "-74.005000")
    coord_stop(organization, version, "LST_MC", "40.714800", "-74.004000")
    coord_stop(organization, version, "LST_EA", "40.715800", "-74.003000")
    coord_stop(organization, version, "LST_EB", "40.716800", "-74.002000")
    coord_stop(organization, version, "LST_SA", "40.717800", "-74.001000")
    coord_stop(organization, version, "LST_SB", "40.718800", "-74.000000")

    audit_context = audit(organization, version)

    missing = pattern(organization, version, route, "P-LST-MISS")
    occurrences(missing, ["LST_MA", "LST_MB", "LST_MC"])

    exported = pattern(organization, version, route, "P-LST-EXP")
    occurrences(exported, ["LST_EA", "LST_EB"])

    draw!(
      exported,
      [{1, [[-74.002500, 40.716300]]}],
      %{"1" => "shared"},
      audit_context
    )

    stale = pattern(organization, version, route, "P-LST-STALE")
    occurrences(stale, ["LST_SA", "LST_SB"])

    draw!(
      stale,
      [{1, [[-74.000500, 40.718300]]}],
      %{"1" => "shared"},
      audit_context
    )

    # A stop/geometry change without a recompute leaves the owned shape
    # behind: same production shape as the shared-edit conflict, without
    # dragging a second writer into this list test.
    stale
    |> Repo.reload!()
    |> Ecto.Changeset.change(%{alignment_digest: "tampered"})
    |> Repo.update!()

    imported = pattern(organization, version, route, "P-LST-IMP")
    imported_occurrences = occurrences(imported, ["LST_EA", "LST_EB"])
    imported_timing = timed_pattern_fixture(imported, %{name: "Alignment"})

    Enum.each(imported_occurrences, fn occurrence ->
      timed_pattern_stop_fixture(imported_timing, occurrence, %{
        arrival_offset: 0,
        departure_offset: 0
      })
    end)

    imported_trip =
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: "LST_IMP_T1",
        shape_id: "IMP-LST-1"
      })

    trip_pattern_metadata_fixture(imported_trip, %{
      route_pattern_id: imported.route_pattern_id,
      timed_pattern_id: imported_timing.id,
      pattern_derivation_state: "linked"
    })

    route
  end

  describe "patterns map line column" do
    setup :editor_scope

    test "each pattern shows its six-state map line status", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route = four_status_route(organization, version)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      assert has_element?(view, "#patterns-list-container", "Map line")
      assert has_element?(view, "#pattern-alignment-P-LST-MISS", "2 sections missing")
      assert has_element?(view, "#pattern-alignment-P-LST-EXP", "Ready")
      assert has_element?(view, "#pattern-alignment-P-LST-STALE", "Out of date")
      assert has_element?(view, "#pattern-alignment-P-LST-IMP", "Imported line")
    end

    test "a clean cell click patches to the Alignment task without remounting", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route = four_status_route(organization, version)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      render_click(element(view, "#pattern-alignment-P-LST-EXP"))

      assert_patch(
        view,
        "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/P-LST-EXP?task=alignment"
      )

      assert has_element?(view, "#alignment-task")
      assert has_element?(view, "#alignment-status", "✓ Exported")
    end

    test "a dirty click opens the existing discard dialog instead of patching", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      route = four_status_route(organization, version)

      {:ok, view, _html} = live(conn, patterns_path(version, route))

      render_hook(view, "alignment_draft_state", %{"dirty_positions" => [1]})
      assert_push_event(view, "route_pattern_dirty", %{dirty: true})

      render_click(element(view, "#pattern-alignment-P-LST-EXP"))

      assert has_element?(view, "#discard-changes-dialog", "Discard unsaved changes?")
      assert has_element?(view, "#patterns-list-container")

      render_click(element(view, "#discard-changes-dialog-cancel"))

      assert has_element?(view, "#patterns-list-container")
      assert has_element?(view, "#pattern-alignment-P-LST-EXP", "Ready")
    end
  end
end

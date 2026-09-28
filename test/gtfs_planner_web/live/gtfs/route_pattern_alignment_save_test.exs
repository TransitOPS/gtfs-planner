defmodule GtfsPlannerWeb.Gtfs.RoutePatternAlignmentSaveTest do
  @moduledoc false
  # Step 28 / EV-27: save alignments through the review dialogs
  # (CL-10/FH-19, CL-14/FH-24, CL-27/FH-40). Every assertion enters through
  # `live(conn, "...?task=alignment")` and the real
  # `Gtfs.review_alignment_save/3` / `Gtfs.apply_alignment_save/5` on the
  # isolated `_align12` database. Races are EV-12 territory; pixel
  # geography is the inspected browser captures.
  use GtfsPlannerWeb.ConnCase, async: false

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
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Repo

  import Ecto.Query

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "align-save-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "align-save-#{System.unique_integer([:positive])}@example.com"})

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

  defp base_stops(organization, version) do
    coord_stop(organization, version, "S1", "Stop One", "40.712800", "-74.006000")
    coord_stop(organization, version, "S2", "Stop Two", "40.713800", "-74.005000")
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
      actor_email: "align-save@example.com"
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

  defp save_params(entries), do: %{"sections" => entries}

  # Draws sections through the real review/apply facade, supplying local
  # scope wherever the review asks, so seeds reach a saved state exactly
  # like an editor's confirmed dialog would.
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

  defp link_trip(organization, version, pattern, trip_id, shape_id) do
    timing = timed_pattern_fixture(pattern)

    trip =
      trip_fixture(organization.id, version.id, pattern.route_id, %{
        trip_id: trip_id,
        shape_id: shape_id
      })

    trip_pattern_metadata_fixture(trip, %{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing.id,
      pattern_derivation_state: "linked"
    })

    for sequence <- [1, 2] do
      stop_time_fixture(organization.id, version.id, trip.trip_id, "S1", %{
        stop_sequence: sequence,
        shape_dist_traveled: "0"
      })
    end

    trip
  end

  defp insert_shape(organization, version, shape_id) do
    for {sequence, lat, lon, dist} <- [
          {0, "40.712800", "-74.006000", "0"},
          {1, "40.713800", "-74.005000", "150.5"}
        ] do
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

  defp shape_rows(organization, version, shape_id) do
    from(s in Shape,
      where:
        s.organization_id == ^organization.id and
          s.gtfs_version_id == ^version.id and
          s.shape_id == ^shape_id,
      order_by: [asc: s.shape_pt_sequence]
    )
    |> Repo.all()
    |> Enum.map(&{&1.shape_pt_lat, &1.shape_pt_lon, &1.shape_dist_traveled})
  end

  defp segments_count(organization, version) do
    from(s in AlignmentSegment,
      where:
        s.organization_id == ^organization.id and
          s.gtfs_version_id == ^version.id
    )
    |> Repo.aggregate(:count)
  end

  defp pattern_path(version, route, pattern) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}?task=alignment"
  end

  defp save_open?(view), do: has_element?(view, "#alignment-save-dialog[data-open=\"true\"]")

  defp blocked_open?(view),
    do: has_element?(view, "#alignment-blocked-dialog[data-open=\"true\"]")

  defp conflict_open?(view),
    do: has_element?(view, "#alignment-conflict-dialog[data-open=\"true\"]")

  # Two patterns on different routes sharing the S1→S2 pair, both drawn
  # shared so both own a materialized shape.
  defp shared_pair(organization, version) do
    base_stops(organization, version)
    route_one = route(organization, version, "SV1")
    route_two = route(organization, version, "SV2")
    first = pattern(organization, version, route_one, "P-SV-A")
    occurrences(first, ["S1", "S2"])
    second = pattern(organization, version, route_two, "P-SV-B")
    occurrences(second, ["S1", "S2"])
    link_trip(organization, version, first, "SV-T1", nil)
    link_trip(organization, version, second, "SV-T2", nil)
    audit_context = audit(organization, version)

    draw!(second, [{1, [[-74.005600, 40.713200]]}], %{"1" => "shared"}, audit_context)
    draw!(first, [{1, [[-74.005500, 40.713300]]}], %{"1" => "shared"}, audit_context)

    {route_one, route_two, Repo.reload!(first), Repo.reload!(second)}
  end

  describe "save dialogs" do
    setup :editor_scope

    test "a set on a sole-user missing section applies without a dialog", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      base_stops(organization, version)
      route_one = route(organization, version, "SV0")
      solo = pattern(organization, version, route_one, "P-SV-SOLO")
      occurrences(solo, ["S1", "S2"])

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, solo))

      draft = [set_entry(section_at(Repo.reload!(solo), 1), [[-74.005500, 40.713100]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert segments_count(organization, version) == 1
      assert_push_event(view, "alignment:load", %{model: _model})
      assert has_element?(view, "#status", "Alignment saved. 0 trips updated.")
      refute save_open?(view)
    end

    test "a direct apply clears the dirty mirror the hook drops on load", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      base_stops(organization, version)
      route_one = route(organization, version, "SV0C")
      solo = pattern(organization, version, route_one, "P-SV-SOLO-CLEAR")
      occurrences(solo, ["S1", "S2"])

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, solo))

      # The hook drops its drafts on the pushed load without pushing, so the
      # server must reset its own mirror when the apply persists them.
      render_hook(view, "alignment_draft_state", %{"dirty_positions" => [1]})
      assert has_element?(view, "#alignment-status", "◷ Unsaved changes")
      assert_push_event(view, "route_pattern_dirty", %{dirty: true})

      draft = [set_entry(section_at(Repo.reload!(solo), 1), [[-74.005500, 40.713100]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert has_element?(view, "#status", "Alignment saved. 0 trips updated.")
      assert_push_event(view, "alignment:load", %{model: _model})
      assert_push_event(view, "route_pattern_dirty", %{dirty: false})
      assert has_element?(view, "#alignment-section-status-1", "✓ Saved")
      refute has_element?(view, "#alignment-status", "◷ Unsaved changes")
    end

    test "a shared-section edit opens the scope dialog defaulting to local", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route_one, _route_two, first, _second} = shared_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, first))

      draft = [set_entry(section_at(Repo.reload!(first), 1), [[-74.005100, 40.713500]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert save_open?(view)
      assert has_element?(view, "#alignment-save-dialog", "Only this pattern")
      assert has_element?(view, "#alignment-save-scope-1-local[checked]")
      assert has_element?(view, "#alignment-save-dialog", "SV2 · P-SV-B")
      # No rows change before the choice is confirmed.
      assert segments_count(organization, version) == 1
    end

    test "confirming shared updates the other pattern's shape rows", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route_one, _route_two, first, second} = shared_pair(organization, version)
      before_rows = shape_rows(organization, version, Repo.reload!(second).shape_id)

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, first))

      draft = [set_entry(section_at(Repo.reload!(first), 1), [[-74.005100, 40.713500]])]
      render_hook(view, "alignment_save_requested", save_params(draft))
      assert save_open?(view)

      view
      |> element("#alignment-save-form")
      |> render_change(%{"scopes" => %{"1" => "shared"}})

      view
      |> element("#alignment-save-dialog-confirm")
      |> render_click()

      after_rows = shape_rows(organization, version, Repo.reload!(second).shape_id)
      assert after_rows != before_rows
      assert_push_event(view, "alignment:load", %{model: _model})
      assert has_element?(view, "#status", "Alignment saved. 2 trips updated.")
      refute save_open?(view)
    end

    test "confirming local leaves the other pattern byte-equal and writes an override", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route_one, _route_two, first, second} = shared_pair(organization, version)
      before_rows = shape_rows(organization, version, Repo.reload!(second).shape_id)

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, first))

      draft = [set_entry(section_at(Repo.reload!(first), 1), [[-74.005100, 40.713500]])]
      render_hook(view, "alignment_save_requested", save_params(draft))
      assert save_open?(view)

      view
      |> element("#alignment-save-dialog-confirm")
      |> render_click()

      assert shape_rows(organization, version, Repo.reload!(second).shape_id) == before_rows

      assert Repo.one(
               from(s in AlignmentSegment,
                 where:
                   s.organization_id == ^organization.id and
                     s.gtfs_version_id == ^version.id and
                     not is_nil(s.from_occurrence_id)
               )
             ) != nil

      assert_push_event(view, "alignment:load", %{model: _model})
      assert has_element?(view, "#status", "Alignment saved. 1 trip updated.")
    end

    test "a replacement names the shape and trip count and waits for confirmation", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      base_stops(organization, version)
      route_one = route(organization, version, "SVR")
      imported = pattern(organization, version, route_one, "P-SV-IMP")
      occurrences(imported, ["S1", "S2"])
      insert_shape(organization, version, "IMP-X")
      link_trip(organization, version, imported, "SVR-T1", "IMP-X")
      link_trip(organization, version, imported, "SVR-T2", "IMP-X")
      before_rows = shape_rows(organization, version, "IMP-X")

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, imported))

      draft = [set_entry(section_at(Repo.reload!(imported), 1), [[-74.005500, 40.713100]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert save_open?(view)
      assert has_element?(view, "#alignment-save-dialog", "Replace imported shapes")
      assert has_element?(view, "#alignment-save-dialog", "IMP-X")
      assert has_element?(view, "#alignment-save-dialog", "2 trips")
      # The imported rows are untouched until the choice is confirmed.
      assert shape_rows(organization, version, "IMP-X") == before_rows

      view
      |> element("#alignment-save-dialog-confirm")
      |> render_click()

      assert shape_rows(organization, version, "IMP-X") != before_rows
      assert_push_event(view, "alignment:load", %{model: _model})
      assert has_element?(view, "#status", "Alignment saved. 2 trips updated.")
    end

    test "a trip with a mismatched stop-time count opens the blocked dialog", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      base_stops(organization, version)
      route_one = route(organization, version, "SVB")
      blocked = pattern(organization, version, route_one, "P-SV-BLK")
      occurrences(blocked, ["S1", "S2"])
      timing = timed_pattern_fixture(blocked)

      trip =
        trip_fixture(organization.id, version.id, route_one.route_id, %{trip_id: "SVB-T1"})

      trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: blocked.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

      stop_time_fixture(organization.id, version.id, trip.trip_id, "S1", %{
        stop_sequence: 1,
        shape_dist_traveled: "0"
      })

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, blocked))

      draft = [set_entry(section_at(Repo.reload!(blocked), 1), [[-74.005500, 40.713100]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert blocked_open?(view)
      assert has_element?(view, "#alignment-blocked-dialog", "SVB-T1")
      assert segments_count(organization, version) == 0
    end

    test "a stale base conflicts and keep-local rebases into an override save", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route_one, _route_two, first, _second} = shared_pair(organization, version)
      stale_section = section_at(Repo.reload!(first), 1)

      # Another editor moves the shared path first.
      shared =
        Repo.one!(
          from(s in AlignmentSegment,
            where:
              s.organization_id == ^organization.id and
                s.gtfs_version_id == ^version.id and
                is_nil(s.from_occurrence_id)
          )
        )

      shared
      |> AlignmentSegment.changeset(%{points: [[-74.004900, 40.713900]]})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, first))

      draft = [set_entry(stale_section, [[-74.005100, 40.713500]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert conflict_open?(view)

      view
      |> element("#alignment-conflict-dialog-confirm")
      |> render_click()

      assert_push_event(view, "alignment:rebase", %{bases: [%{position: 1}]})

      # The rebased draft reviews against the newer shared path and stays
      # local without reopening the scope dialog.
      fresh_draft = [set_entry(section_at(Repo.reload!(first), 1), [[-74.005100, 40.713500]])]
      render_hook(view, "alignment_save_requested", save_params(fresh_draft))

      refute save_open?(view)
      refute conflict_open?(view)

      assert Repo.one(
               from(s in AlignmentSegment,
                 where:
                   s.organization_id == ^organization.id and
                     s.gtfs_version_id == ^version.id and
                     not is_nil(s.from_occurrence_id)
               )
             ) != nil

      assert_push_event(view, "alignment:load", %{model: _model})
    end

    test "changed stops show the stale-stops notice with Reload", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      base_stops(organization, version)
      route_one = route(organization, version, "SVS")
      moving = pattern(organization, version, route_one, "P-SV-STALE")
      occurrences(moving, ["S1", "S2"])
      stale_section = section_at(Repo.reload!(moving), 1)

      # The stops are reordered after the draft was drawn: the section's
      # next visit no longer matches the drafted identity.
      Repo.update_all(
        from(o in GtfsPlanner.Gtfs.RoutePatternStop,
          where: o.route_pattern_id == ^moving.id and o.position == 2
        ),
        set: [stop_id: "S1"]
      )

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, moving))

      draft = [set_entry(stale_section, [[-74.005500, 40.713100]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert has_element?(
               view,
               "#alignment-save-notice",
               "Stops changed since you opened this alignment"
             )

      assert has_element?(view, "#alignment-save-reload", "Reload")

      view
      |> element("#alignment-save-reload")
      |> render_click()

      assert_push_event(view, "alignment:load", %{model: _model})
      refute has_element?(view, "#alignment-save-notice")
    end

    test "a changed review shows Review again", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      {route_one, _route_two, first, _second} = shared_pair(organization, version)

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, first))

      draft = [set_entry(section_at(Repo.reload!(first), 1), [[-74.005100, 40.713500]])]
      render_hook(view, "alignment_save_requested", save_params(draft))
      assert save_open?(view)

      # A third pattern starts using the shared pair before this one
      # confirms: the bases still match, but the review fingerprint no
      # longer does.
      third_route = route(organization, version, "SVS3")
      third = pattern(organization, version, third_route, "P-SV-THIRD")
      occurrences(third, ["S1", "S2"])

      view
      |> element("#alignment-save-dialog-confirm")
      |> render_click()

      assert has_element?(
               view,
               "#alignment-save-notice",
               "The patterns this save affects changed. Review again."
             )

      view
      |> element("#alignment-review-again")
      |> render_click()

      refute has_element?(view, "#alignment-save-notice")
      refute save_open?(view)
    end

    test "a revoked editor is halted and writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      base_stops(organization, version)
      route_one = route(organization, version, "SVX")
      guarded = pattern(organization, version, route_one, "P-SV-RVK")
      occurrences(guarded, ["S1", "S2"])

      {:ok, view, _html} = live(conn, pattern_path(version, route_one, guarded))

      membership = Accounts.get_user_org_membership(user.id, organization.id)
      Repo.delete!(membership)

      draft = [set_entry(section_at(Repo.reload!(guarded), 1), [[-74.005500, 40.713100]])]
      render_hook(view, "alignment_save_requested", save_params(draft))

      assert has_element?(view, "#pattern-editor-revoked")
      assert segments_count(organization, version) == 0
    end
  end
end

defmodule GtfsPlannerWeb.Gtfs.StationJournalComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.JournalPhoto
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlannerWeb.Gtfs.StationJournalComponents

  @entry_id "10000000-0000-0000-0000-000000000001"
  @closed_entry_id "10000000-0000-0000-0000-000000000002"
  @author_id "20000000-0000-0000-0000-000000000001"
  @target_id "30000000-0000-0000-0000-000000000001"
  @removed_target_id "30000000-0000-0000-0000-000000000002"
  @photo_id "40000000-0000-0000-0000-000000000001"

  @scope %Scope{
    organization_id: "50000000-0000-0000-0000-000000000001",
    gtfs_version_id: "60000000-0000-0000-0000-000000000001",
    station_id: "70000000-0000-0000-0000-000000000001",
    station_stop_id: "OLNEY_TC",
    actor_id: "80000000-0000-0000-0000-000000000001"
  }

  defp entry(overrides \\ %{}) do
    Map.merge(
      %JournalEntry{
        id: @entry_id,
        organization_id: @scope.organization_id,
        gtfs_version_id: @scope.gtfs_version_id,
        station_id: @scope.station_id,
        author_id: @author_id,
        target_type: "node",
        target_id: @target_id,
        body:
          "Signage says Bay C here, not Central. Confirm the field note before the next export.",
        captured_at: ~U[2026-07-16 18:32:00Z],
        closed_at: nil,
        photos: [
          %JournalPhoto{
            id: @photo_id,
            journal_entry_id: @entry_id,
            filename: "#{@photo_id}.jpg",
            content_type: "image/jpeg",
            byte_size: 128,
            captured_at: ~U[2026-07-16 18:32:00Z]
          }
        ],
        inserted_at: ~U[2026-07-16 18:32:00Z],
        updated_at: ~U[2026-07-16 18:32:00Z]
      },
      overrides
    )
  end

  defp panel_assigns(overrides) do
    base = [
      journal_scope: @scope,
      journal_entries: [{"journal-entries-#{@entry_id}", entry()}],
      journal_state: :ready,
      journal_loaded_once?: true,
      journal_refresh_error?: false,
      journal_open_count: 1,
      journal_closed_count: 0,
      journal_visible_count: 1,
      journal_pending_new_ids: MapSet.new(),
      journal_authors: %{@author_id => %User{email: "alex.rivera@example.com"}},
      journal_targets: %{@target_id => %{label: "Busway Central"}},
      journal_local_times: %{
        {@entry_id, :captured} => ~N[2026-07-16 14:32:00]
      },
      journal_display_zone: %{
        timezone: "America/New_York",
        fallback?: false,
        fallback_reason: nil
      },
      journal_now: ~N[2026-07-18 14:35:00],
      journal_live_message: nil,
      journal_error_message: nil
    ]

    Keyword.merge(base, overrides)
  end

  defp render_panel(overrides \\ []) do
    render_component(&StationJournalComponents.journal_panel/1, panel_assigns(overrides))
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp attrs_of(d, selector, name),
    do: d |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

  describe "author_label/1" do
    test "compacts roster users and email strings without exposing the domain" do
      assert StationJournalComponents.author_label(%User{email: "alex.rivera@example.com"}) ==
               "A. Rivera"

      assert StationJournalComponents.author_label("jules@example.com") == "Jules"
      assert StationJournalComponents.author_label("mary-jane_watson@example.com") == "M. Watson"
    end

    test "falls back to Unknown for missing or unusable authors" do
      assert StationJournalComponents.author_label(nil) == "Unknown"
      assert StationJournalComponents.author_label(%User{email: nil}) == "Unknown"
      assert StationJournalComponents.author_label("@example.com") == "Unknown"
    end
  end

  describe "journal time helpers" do
    test "formats compact relative boundaries from caller-localized times" do
      now = ~N[2026-07-18 14:35:00]

      assert StationJournalComponents.relative_time(~N[2026-07-18 14:34:30], now) == "just now"
      assert StationJournalComponents.relative_time(~N[2026-07-18 14:33:00], now) == "2m ago"
      assert StationJournalComponents.relative_time(~N[2026-07-18 12:35:00], now) == "2h ago"
      assert StationJournalComponents.relative_time(~N[2026-07-17 20:00:00], now) == "yesterday"
      assert StationJournalComponents.relative_time(~N[2026-07-13 14:35:00], now) == "5d ago"
      assert StationJournalComponents.relative_time(~N[2026-07-02 14:35:00], now) == "Jul 2"
    end

    test "formats an absolute caller-localized wall clock" do
      assert StationJournalComponents.absolute_time(~N[2026-07-16 14:32:00]) ==
               "Jul 16, 2026 · 2:32 PM"
    end
  end

  describe "journal_trigger/1" do
    test "exposes the panel relationship, state, and count as a compact link-style trigger" do
      html =
        render_component(&StationJournalComponents.journal_trigger/1,
          entry_count: 3,
          panel_open?: false
        )

      d = doc(html)
      trigger = LazyHTML.query(d, "#journal-trigger")

      assert LazyHTML.attribute(trigger, "aria-controls") == ["station-journal-panel"]
      assert LazyHTML.attribute(trigger, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(trigger, "phx-click") == ["open_journal"]
      assert LazyHTML.attribute(trigger, "class") |> List.first() =~ "py-1.5"

      assert LazyHTML.query(d, "#journal-trigger-count") |> LazyHTML.text() |> String.trim() ==
               "3"
    end

    test "acts as the close control when the panel is already open" do
      html =
        render_component(&StationJournalComponents.journal_trigger/1,
          entry_count: 0,
          panel_open?: true
        )

      trigger = html |> doc() |> LazyHTML.query("#journal-trigger")

      assert LazyHTML.attribute(trigger, "aria-expanded") == ["true"]
      assert LazyHTML.attribute(trigger, "phx-click") == ["close_journal"]
    end
  end

  describe "journal_panel/1 ready presentation" do
    test "renders the 340px panel hierarchy, close control, entry count, and polite status" do
      html = render_panel()
      d = doc(html)
      panel = LazyHTML.query(d, "aside#station-journal-panel")

      assert LazyHTML.attribute(panel, "aria-label") == ["Station journal"]
      assert LazyHTML.attribute(panel, "class") |> List.first() =~ "w-[340px]"
      assert Enum.count(LazyHTML.query(d, "#journal-panel-close[phx-click='close_journal']")) == 1

      assert LazyHTML.query(d, "#journal-count-summary") |> LazyHTML.text() |> String.trim() ==
               "1 entry"

      # Completion-status filtering was removed: no segmented control, no filter event.
      assert Enum.empty?(LazyHTML.query(d, "#journal-filter"))
      refute html =~ "set_journal_filter"

      status = LazyHTML.query(d, "#journal-status")
      assert LazyHTML.attribute(status, "role") == ["status"]
      assert LazyHTML.attribute(status, "aria-live") == ["polite"]
      assert Enum.empty?(LazyHTML.query(d, "#journal-target-scope"))
    end

    test "renders #journal-target-scope and #journal-clear-target-scope button when target scope is active" do
      target_scope = %{target_type: :node, target_id: @target_id, label: "Node · Busway Central"}

      d =
        render_panel(
          journal_target_scope: target_scope,
          journal_scoped_open_count: 2,
          journal_scoped_closed_count: 1,
          journal_open_count: 10,
          journal_closed_count: 5
        )
        |> doc()

      scope_bar = LazyHTML.query(d, "#journal-target-scope")
      assert LazyHTML.text(scope_bar) =~ "Node · Busway Central"

      clear_btn = LazyHTML.query(d, "#journal-clear-target-scope")
      assert LazyHTML.attribute(clear_btn, "phx-click") == ["clear_journal_target_scope"]
      assert LazyHTML.text(clear_btn) =~ "Show all entries"

      # Header summary sums the scoped counts, not the station-wide ones.
      summary = LazyHTML.query(d, "#journal-count-summary") |> LazyHTML.text()
      assert summary |> String.trim() == "3 entries"
      refute summary =~ "15"
    end

    test "renders each entry complete — note, photos, metadata, and actions — with no disclosure" do
      html = render_panel()
      d = doc(html)
      row = LazyHTML.query(d, "#journal-entries-#{@entry_id}")
      time = LazyHTML.query(row, "time")
      photo = LazyHTML.query(row, "#journal-photo-#{@photo_id}")
      edit = LazyHTML.query(row, "#journal-edit-target-#{@entry_id}")

      assert Enum.empty?(LazyHTML.query(row, "[aria-expanded]"))
      assert Enum.empty?(LazyHTML.query(row, "#journal-entry-toggle-#{@entry_id}"))

      assert Enum.count(LazyHTML.query(row, "#journal-entry-target-#{@entry_id}")) == 1

      assert LazyHTML.query(row, "[data-role='journal-note']") |> LazyHTML.text() =~
               "Confirm the field note before the next export."

      assert LazyHTML.attribute(time, "datetime") == ["2026-07-16T18:32:00Z"]
      assert LazyHTML.attribute(time, "title") |> List.first() =~ "Jul 16, 2026 · 2:32 PM"

      assert LazyHTML.attribute(photo, "phx-click") == ["open_journal_photo"]
      assert LazyHTML.attribute(photo, "phx-value-photo_id") == [@photo_id]
      assert LazyHTML.attribute(photo, "phx-value-entry_id") == [@entry_id]

      assert LazyHTML.attribute(LazyHTML.query(photo, "img"), "src") == [
               "/uploads/field-captures/#{@scope.organization_id}/OLNEY_TC/#{@photo_id}.jpg"
             ]

      assert LazyHTML.attribute(edit, "phx-click") == ["edit_child_stop"]
      assert LazyHTML.attribute(edit, "phx-value-id") == [@target_id]

      assert Enum.empty?(LazyHTML.query(row, "[phx-click='show_journal_entry']"))
      refute html =~ "Show on floorplan"
    end

    test "renders Show on floorplan button only for floorplan-eligible entry IDs" do
      eligible_id = @entry_id
      ineligible_id = @closed_entry_id

      closed = entry(%{id: ineligible_id, closed_at: ~U[2026-07-17 15:00:00Z]})

      html =
        render_panel(
          journal_entries: [
            {"journal-entries-#{eligible_id}", entry()},
            {"journal-entries-#{ineligible_id}", closed}
          ],
          journal_floorplan_entry_ids: MapSet.new([eligible_id]),
          journal_closed_count: 1,
          journal_visible_count: 2
        )

      d = doc(html)

      eligible_btn = LazyHTML.query(d, "#journal-show-entry-#{eligible_id}")
      assert LazyHTML.attribute(eligible_btn, "phx-click") == ["show_journal_entry_on_floorplan"]
      assert LazyHTML.attribute(eligible_btn, "phx-value-id") == [eligible_id]
      assert LazyHTML.text(eligible_btn) =~ "Show on floorplan"

      assert Enum.empty?(LazyHTML.query(d, "#journal-show-entry-#{ineligible_id}"))
    end

    test "suppresses edit actions for removed targets" do
      closed =
        entry(%{
          id: @closed_entry_id,
          target_id: @removed_target_id,
          target_type: "pathway",
          closed_at: ~U[2026-07-17 15:00:00Z],
          photos: []
        })

      d =
        render_panel(
          journal_entries: [{"journal-entries-#{@closed_entry_id}", closed}],
          journal_open_count: 0,
          journal_closed_count: 1,
          journal_targets: %{},
          journal_local_times: %{
            {@closed_entry_id, :captured} => ~N[2026-07-16 14:32:00]
          }
        )
        |> doc()

      assert LazyHTML.query(d, "#journal-entry-target-#{@closed_entry_id}") |> LazyHTML.text() =~
               "(removed)"

      assert Enum.empty?(LazyHTML.query(d, "#journal-edit-target-#{@closed_entry_id}"))
    end

    test "renders closed entries identically to open ones, with no status affordances" do
      closed = entry(%{closed_at: ~U[2026-07-17 15:00:00Z]})

      html =
        render_panel(
          journal_entries: [{"journal-entries-#{@entry_id}", closed}],
          journal_open_count: 0,
          journal_closed_count: 1
        )

      d = doc(html)
      row = LazyHTML.query(d, "#journal-entries-#{@entry_id}")

      # The edit-target action still renders; closed state suppresses nothing.
      assert Enum.count(LazyHTML.query(row, "#journal-edit-target-#{@entry_id}")) == 1

      # Completion-status affordances were removed for closed rows.
      assert LazyHTML.attribute(row, "data-entry-state") == []
      refute LazyHTML.attribute(row, "class") |> List.first() =~ "opacity-70"
      refute html =~ "Closed ·"
      assert Enum.empty?(LazyHTML.query(d, "#journal-close-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-reopen-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-undo-strip-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-undo-entry-#{@entry_id}"))
    end

    test "scopes the arrival highlight to entries flagged as new" do
      quiet = render_panel() |> doc()

      refute LazyHTML.attribute(LazyHTML.query(quiet, "#journal-entries-#{@entry_id}"), "class")
             |> List.first() =~ "journal-entry-motion"

      highlighted =
        render_panel(journal_new_entry_ids: MapSet.new([@entry_id])) |> doc()

      assert LazyHTML.attribute(
               LazyHTML.query(highlighted, "#journal-entries-#{@entry_id}"),
               "class"
             )
             |> List.first() =~ "journal-entry-motion"
    end

    test "renders the photo viewer as a modal dialog with close and original-file controls" do
      refute render_panel() =~ "journal-photo-viewer"

      d =
        render_panel(
          journal_photo_viewer: %{
            photo_id: @photo_id,
            entry_id: @entry_id,
            src: "/uploads/field-captures/org/OLNEY_TC/#{@photo_id}.jpg",
            index: 1,
            count: 2
          }
        )
        |> doc()

      viewer = LazyHTML.query(d, "#journal-photo-viewer")

      assert LazyHTML.attribute(viewer, "role") == ["dialog"]
      assert LazyHTML.attribute(viewer, "aria-modal") == ["true"]
      assert LazyHTML.attribute(viewer, "aria-label") == ["Journal photo 1 of 2"]

      assert LazyHTML.attribute(
               LazyHTML.query(viewer, "#journal-photo-viewer-backdrop"),
               "phx-click"
             ) == ["close_journal_photo"]

      assert LazyHTML.attribute(
               LazyHTML.query(viewer, "#journal-photo-viewer-close"),
               "phx-click"
             ) == ["close_journal_photo"]

      original = LazyHTML.query(viewer, "#journal-photo-viewer-original")
      assert LazyHTML.attribute(original, "target") == ["_blank"]

      assert LazyHTML.attribute(original, "href") == [
               "/uploads/field-captures/org/OLNEY_TC/#{@photo_id}.jpg"
             ]
    end

    test "offers an identity-derived pending refresh without modifying the row list" do
      d =
        render_panel(journal_pending_new_ids: MapSet.new([@entry_id, @closed_entry_id]))
        |> doc()

      pending = LazyHTML.query(d, "#journal-pending-entries")

      assert LazyHTML.attribute(pending, "phx-click") == ["refresh_journal"]
      assert LazyHTML.text(pending) =~ "2 new entries"
      assert Enum.count(LazyHTML.query(d, "#journal-entry-list > article")) == 1
    end
  end

  describe "journal_context_box/1" do
    test "renders nothing without a context" do
      html =
        render_component(&StationJournalComponents.journal_context_box/1, context: nil)

      assert String.trim(html) == ""
    end

    test "restates the originating entry above a form" do
      html =
        render_component(&StationJournalComponents.journal_context_box/1,
          context: %{
            entry_id: @entry_id,
            body: "Confirm signage before export.",
            byline: "A. Rivera",
            captured_label: "2d ago"
          }
        )

      box = html |> doc() |> LazyHTML.query("#journal-form-context")

      assert LazyHTML.text(box) =~ "Journal entry"
      assert LazyHTML.text(box) =~ "A. Rivera"
      assert LazyHTML.text(box) =~ "2d ago"
      assert LazyHTML.text(box) =~ "Confirm signage before export."
    end
  end

  describe "journal_panel/1 lifecycle states" do
    test "loading shows a delayed row-shaped busy skeleton" do
      d =
        render_panel(
          journal_entries: [],
          journal_state: :loading,
          journal_loaded_once?: false,
          journal_open_count: 0,
          journal_visible_count: 0
        )
        |> doc()

      loading = LazyHTML.query(d, "#journal-loading")

      assert LazyHTML.attribute(loading, "aria-busy") == ["true"]
      assert LazyHTML.attribute(loading, "class") |> List.first() =~ "journal-loading-delay"
      assert Enum.count(LazyHTML.query(loading, "[data-role='journal-skeleton-row']")) == 3
    end

    test "first-use empty explains the source without a false CTA" do
      html =
        render_panel(
          journal_entries: [],
          journal_open_count: 0,
          journal_closed_count: 0,
          journal_visible_count: 0
        )

      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#journal-empty-first-use")) == 1
      assert Enum.count(LazyHTML.query(d, "#journal-empty-first-use .journal-empty-icon")) == 1
      assert Enum.count(LazyHTML.query(d, "#journal-empty-first-use .journal-empty-copy")) == 1
      assert Enum.empty?(LazyHTML.query(d, "#journal-empty-first-use button"))
      refute html =~ "Add entry"
    end

    test "stays in the ready state when entries exist but none are visible" do
      d =
        render_panel(
          journal_entries: [],
          journal_open_count: 0,
          journal_closed_count: 7,
          journal_visible_count: 0
        )
        |> doc()

      panel = LazyHTML.query(d, "aside#station-journal-panel")

      assert LazyHTML.attribute(panel, "data-state") == ["ready"]
      assert Enum.empty?(LazyHTML.query(d, "#journal-empty-filtered"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-empty-first-use"))
    end

    test "first-load error is contained, announced, and recoverable" do
      d =
        render_panel(
          journal_entries: [],
          journal_state: :error,
          journal_loaded_once?: false,
          journal_open_count: 0,
          journal_visible_count: 0,
          journal_error_message: "database timeout that must not render"
        )
        |> doc()

      error = LazyHTML.query(d, "#journal-load-error")

      assert LazyHTML.attribute(error, "role") == ["alert"]

      assert LazyHTML.attribute(LazyHTML.query(error, "#journal-retry"), "phx-click") == [
               "refresh_journal"
             ]

      refute LazyHTML.text(error) =~ "database timeout"
    end

    test "refresh error preserves stale rows and provides a retry" do
      d =
        render_panel(
          journal_state: :error,
          journal_refresh_error?: true,
          journal_loaded_once?: true
        )
        |> doc()

      assert Enum.count(LazyHTML.query(d, "#journal-refresh-error")) == 1
      assert Enum.count(LazyHTML.query(d, "#journal-entries-#{@entry_id}")) == 1

      assert Enum.count(LazyHTML.query(d, "#journal-refresh-retry[phx-click='refresh_journal']")) ==
               1
    end
  end

  describe "entity_journal_panel/1" do
    defp entity_panel_assigns(overrides) do
      base = [
        entity_type: "stop",
        entity_id: "stop-1",
        entity_label: "stop",
        journal_scope: @scope,
        journal_entries: [{"drawer-journal-entry-#{@entry_id}", entry()}],
        journal_state: :ready,
        journal_entries_exist?: true,
        journal_error_fallback?: false,
        journal_authors: %{@author_id => %User{email: "alex.rivera@example.com"}},
        journal_local_times: %{
          {@entry_id, :captured} => ~N[2026-07-16 14:32:00]
        },
        journal_now: ~N[2026-07-18 14:35:00]
      ]

      Keyword.merge(base, overrides)
    end

    defp render_entity_panel(overrides \\ []) do
      render_component(
        &StationJournalComponents.entity_journal_panel/1,
        entity_panel_assigns(overrides)
      )
    end

    test "renders the panel with stable entity-prefixed IDs" do
      d = doc(render_entity_panel())

      panel = LazyHTML.query(d, "#drawer-journal-stop-stop-1")
      assert LazyHTML.attribute(panel, "data-role") == ["entity-journal-panel"]

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-stop-entry-list")) == 1
      assert attrs_of(d, "#drawer-journal-stop-entry-list", "phx-update") == ["stream"]
    end

    test "renders a ready entry card with note, author, and time" do
      d = doc(render_entity_panel())

      row = LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")
      assert LazyHTML.attribute(row, "data-role") == ["entity-journal-entry"]

      note = LazyHTML.query(row, "[data-role='journal-note']")
      assert LazyHTML.text(note) =~ "Confirm the field note before the next export."

      assert LazyHTML.text(row) =~ "A. Rivera"
      assert LazyHTML.text(row) =~ "2d ago"

      time = LazyHTML.query(row, "time")
      assert LazyHTML.attribute(time, "datetime") == ["2026-07-16T18:32:00Z"]
    end

    test "renders photo thumbnails as new-tab links to their scoped public path" do
      d = doc(render_entity_panel())

      photo_link = LazyHTML.query(d, "#entity-journal-photo-#{@photo_id}")
      assert LazyHTML.attribute(photo_link, "target") == ["_blank"]
      assert LazyHTML.attribute(photo_link, "rel") == ["noopener noreferrer"]

      assert LazyHTML.attribute(photo_link, "href") == [
               "/uploads/field-captures/#{@scope.organization_id}/OLNEY_TC/#{@photo_id}.jpg"
             ]

      img = LazyHTML.query(photo_link, "img")

      assert LazyHTML.attribute(img, "src") == [
               "/uploads/field-captures/#{@scope.organization_id}/OLNEY_TC/#{@photo_id}.jpg"
             ]
    end

    test "renders no-note fallback when body is empty" do
      no_note = entry(%{body: ""})

      d =
        doc(
          render_entity_panel(journal_entries: [{"drawer-journal-entry-#{@entry_id}", no_note}])
        )

      row = LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")
      assert LazyHTML.text(row) =~ "No note provided"
    end

    test "renders initial loading state with skeleton" do
      d =
        doc(
          render_entity_panel(
            journal_entries: [],
            journal_state: :initial_loading,
            journal_entries_exist?: false
          )
        )

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-stop-loading")) == 1

      assert LazyHTML.query(d, "#drawer-journal-stop-loading") |> LazyHTML.text() =~
               "Loading journal entries"

      assert Enum.empty?(LazyHTML.query(d, "[data-role='entity-journal-entry']"))
    end

    test "renders empty state for ready with zero entries" do
      d =
        doc(
          render_entity_panel(
            journal_entries: [],
            journal_state: :ready,
            journal_entries_exist?: false
          )
        )

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-stop-empty")) == 1

      assert LazyHTML.query(d, "#drawer-journal-stop-empty") |> LazyHTML.text() =~
               "No journal entries for this stop"

      assert Enum.empty?(LazyHTML.query(d, "[data-role='entity-journal-entry']"))
    end

    test "empty state uses the entity label" do
      d =
        doc(
          render_entity_panel(
            entity_type: "pathway",
            entity_id: "pw-1",
            entity_label: "pathway",
            journal_entries: [],
            journal_state: :ready,
            journal_entries_exist?: false
          )
        )

      assert LazyHTML.query(d, "#drawer-journal-pathway-empty") |> LazyHTML.text() =~
               "No journal entries for this pathway"
    end

    test "renders refreshing state while retaining prior rows" do
      d =
        doc(
          render_entity_panel(
            journal_state: :refreshing,
            journal_entries_exist?: true
          )
        )

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-stop-refreshing")) == 1

      assert LazyHTML.query(d, "#drawer-journal-stop-refreshing") |> LazyHTML.text() =~
               "Refreshing journal entries"

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")) == 1
    end

    test "renders initial error with callout and retry" do
      d =
        doc(
          render_entity_panel(
            journal_entries: [],
            journal_state: :error,
            journal_entries_exist?: false,
            journal_error_fallback?: false
          )
        )

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-stop-error")) == 1

      assert LazyHTML.query(d, "#drawer-journal-stop-error") |> LazyHTML.text() =~
               "Journal entries could not load"

      retry = LazyHTML.query(d, "#drawer-journal-stop-retry")
      assert LazyHTML.attribute(retry, "phx-click") == ["retry_drawer_journal"]
    end

    test "renders stale error preserving rows and offering retry" do
      d =
        doc(
          render_entity_panel(
            journal_state: :error,
            journal_entries_exist?: true,
            journal_error_fallback?: true
          )
        )

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-stop-stale-error")) == 1

      assert LazyHTML.query(d, "#drawer-journal-stop-stale-error") |> LazyHTML.text() =~
               "Journal entries may be out of date"

      assert Enum.count(LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")) == 1

      retry = LazyHTML.query(d, "#drawer-journal-stop-retry")
      assert LazyHTML.attribute(retry, "phx-click") == ["retry_drawer_journal"]
    end

    test "omits target label (the chip is absent)" do
      d = doc(render_entity_panel())

      row = LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")

      # No target-related elements should exist
      assert Enum.empty?(LazyHTML.query(row, "#journal-entry-target-#{@entry_id}"))
      refute LazyHTML.text(row) =~ "Busway Central"
    end

    test "has no lifecycle, status, or action controls" do
      d = doc(render_entity_panel())

      row = LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")

      # No status data attributes
      assert LazyHTML.attribute(row, "data-entry-state") == []
      refute LazyHTML.attribute(row, "class") |> List.first() =~ "opacity"

      # No lifecycle controls
      assert Enum.empty?(LazyHTML.query(d, "#journal-close-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-reopen-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-undo-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-delete-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-undo-strip-#{@entry_id}"))

      # No filter
      assert Enum.empty?(LazyHTML.query(d, "[phx-change^='filter']"))

      # No marker navigation
      assert Enum.empty?(LazyHTML.query(d, "#journal-show-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "[phx-click='show_journal_entry_on_floorplan']"))

      # No panel handoff
      assert Enum.empty?(LazyHTML.query(d, "[phx-click^='show_journal']"))
      refute LazyHTML.text(row) =~ "Show in journal panel"

      # No status-related copy
      refute LazyHTML.text(row) =~ "Open"
      refute LazyHTML.text(row) =~ "Closed"
      refute LazyHTML.text(row) =~ "Completed"
      refute LazyHTML.text(row) =~ "Status"
    end

    test "multiple entries render in stream order" do
      second_id = @closed_entry_id

      second =
        entry(%{
          id: second_id,
          body: "Second entry note.",
          captured_at: ~U[2026-07-17 15:00:00Z],
          photos: []
        })

      d =
        doc(
          render_entity_panel(
            journal_entries: [
              {"drawer-journal-entry-#{@entry_id}", entry()},
              {"drawer-journal-entry-#{second_id}", second}
            ],
            journal_local_times: %{
              {@entry_id, :captured} => ~N[2026-07-16 14:32:00],
              {second_id, :captured} => ~N[2026-07-17 15:00:00]
            }
          )
        )

      rows = LazyHTML.query(d, "[data-role='entity-journal-entry']")
      assert Enum.count(rows) == 2

      ids = LazyHTML.attribute(rows, "id")
      assert ids == ["drawer-journal-entry-#{@entry_id}", "drawer-journal-entry-#{second_id}"]
    end

    test "handles unknown author gracefully" do
      d =
        doc(render_entity_panel(journal_authors: %{}))

      row = LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")
      assert LazyHTML.text(row) =~ "Unknown"
    end

    test "handles missing local time gracefully" do
      d =
        doc(render_entity_panel(journal_local_times: %{}))

      row = LazyHTML.query(d, "#drawer-journal-entry-#{@entry_id}")
      time = LazyHTML.query(row, "time")
      assert LazyHTML.attribute(time, "datetime") == ["2026-07-16T18:32:00Z"]
    end
  end
end

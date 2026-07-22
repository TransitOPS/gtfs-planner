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
      journal_filter: :open,
      journal_loaded_once?: true,
      journal_refresh_error?: false,
      journal_open_count: 1,
      journal_closed_count: 0,
      journal_visible_count: 1,
      journal_expanded_id: nil,
      journal_undo_ids: MapSet.new(),
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
    test "exposes the panel relationship, state, count, and a 44px action target" do
      html =
        render_component(&StationJournalComponents.journal_trigger/1,
          open_count: 3,
          panel_open?: false
        )

      d = doc(html)
      trigger = LazyHTML.query(d, "#journal-trigger")

      assert LazyHTML.attribute(trigger, "aria-controls") == ["station-journal-panel"]
      assert LazyHTML.attribute(trigger, "aria-expanded") == ["false"]
      assert LazyHTML.attribute(trigger, "phx-click") == ["open_journal"]
      assert LazyHTML.attribute(trigger, "class") |> List.first() =~ "min-h-11"

      assert LazyHTML.query(d, "#journal-trigger-count") |> LazyHTML.text() |> String.trim() ==
               "3"
    end

    test "acts as the close control when the panel is already open" do
      html =
        render_component(&StationJournalComponents.journal_trigger/1,
          open_count: 0,
          panel_open?: true
        )

      trigger = html |> doc() |> LazyHTML.query("#journal-trigger")

      assert LazyHTML.attribute(trigger, "aria-expanded") == ["true"]
      assert LazyHTML.attribute(trigger, "phx-click") == ["close_journal"]
    end
  end

  describe "journal_panel/1 ready presentation" do
    test "renders the 340px panel hierarchy, native filters, close control, and polite status" do
      d = render_panel() |> doc()
      panel = LazyHTML.query(d, "aside#station-journal-panel")

      assert LazyHTML.attribute(panel, "aria-label") == ["Station journal"]
      assert LazyHTML.attribute(panel, "class") |> List.first() =~ "w-[340px]"
      assert Enum.count(LazyHTML.query(d, "#journal-panel-close[phx-click='close_journal']")) == 1
      assert LazyHTML.query(d, "#journal-count-summary") |> LazyHTML.text() =~ "1 open"

      assert Enum.count(LazyHTML.query(d, "#journal-filter input[type='radio']")) == 2

      assert LazyHTML.attribute(
               LazyHTML.query(d, "#journal-filter-option-open"),
               "checked"
             ) == [""]

      assert LazyHTML.attribute(LazyHTML.query(d, "#journal-filter-form"), "phx-change") == [
               "set_journal_filter"
             ]

      status = LazyHTML.query(d, "#journal-status")
      assert LazyHTML.attribute(status, "role") == ["status"]
      assert LazyHTML.attribute(status, "aria-live") == ["polite"]
    end

    test "renders a target-first collapsed disclosure with UTC machine time and photo count" do
      d = render_panel() |> doc()
      row = LazyHTML.query(d, "#journal-entries-#{@entry_id}")
      disclosure = LazyHTML.query(row, "#journal-entry-toggle-#{@entry_id}")
      time = LazyHTML.query(row, "time")

      assert LazyHTML.attribute(disclosure, "aria-expanded") == ["false"]

      assert LazyHTML.attribute(disclosure, "aria-controls") == [
               "journal-entry-detail-#{@entry_id}"
             ]

      assert LazyHTML.attribute(disclosure, "phx-click") == ["select_journal_entry"]
      assert LazyHTML.attribute(time, "datetime") == ["2026-07-16T18:32:00Z"]
      assert Enum.count(LazyHTML.query(row, "#journal-entry-target-#{@entry_id}")) == 1
      assert Enum.count(LazyHTML.query(row, "#journal-entry-photo-count-#{@entry_id}")) == 1

      assert LazyHTML.attribute(LazyHTML.query(row, "[data-role='journal-excerpt']"), "class")
             |> List.first() =~ "line-clamp-2"

      assert Enum.empty?(LazyHTML.query(row, "#journal-entry-detail-#{@entry_id}"))
    end

    test "expands inline with full note, scoped photos, localized absolute time, and node actions" do
      d = render_panel(journal_expanded_id: @entry_id) |> doc()
      detail = LazyHTML.query(d, "#journal-entry-detail-#{@entry_id}")
      photo = LazyHTML.query(detail, "#journal-photo-#{@photo_id}")
      edit = LazyHTML.query(detail, "#journal-edit-target-#{@entry_id}")

      assert Enum.count(detail) == 1

      assert LazyHTML.attribute(photo, "href") == [
               "/uploads/field-captures/#{@scope.organization_id}/OLNEY_TC/#{@photo_id}.jpg"
             ]

      assert LazyHTML.attribute(photo, "target") == ["_blank"]
      assert LazyHTML.attribute(edit, "phx-click") == ["edit_child_stop"]
      assert LazyHTML.attribute(edit, "phx-value-id") == [@target_id]
      assert Enum.count(LazyHTML.query(detail, "#journal-close-entry-#{@entry_id}")) == 1

      assert LazyHTML.query(detail, "#journal-captured-at-#{@entry_id}") |> LazyHTML.text() =~
               "Jul 16, 2026 · 2:32 PM"

      assert Enum.empty?(LazyHTML.query(detail, "[phx-click='show_journal_entry']"))
      refute render_panel(journal_expanded_id: @entry_id) =~ "Show on floorplan"
    end

    test "suppresses edit actions for removed targets and exposes reopen for closed rows" do
      closed =
        entry(%{
          id: @closed_entry_id,
          target_id: @removed_target_id,
          target_type: "pathway",
          closed_at: ~U[2026-07-17 15:00:00Z],
          photos: []
        })

      html =
        render_panel(
          journal_entries: [{"journal-entries-#{@closed_entry_id}", closed}],
          journal_open_count: 0,
          journal_closed_count: 1,
          journal_filter: :all,
          journal_expanded_id: @closed_entry_id,
          journal_targets: %{},
          journal_local_times: %{
            {@closed_entry_id, :captured} => ~N[2026-07-16 14:32:00],
            {@closed_entry_id, :closed} => ~N[2026-07-17 11:00:00]
          }
        )

      d = doc(html)

      assert LazyHTML.query(d, "#journal-entry-target-#{@closed_entry_id}") |> LazyHTML.text() =~
               "(removed)"

      assert Enum.empty?(LazyHTML.query(d, "#journal-edit-target-#{@closed_entry_id}"))
      assert Enum.count(LazyHTML.query(d, "#journal-reopen-entry-#{@closed_entry_id}")) == 1
    end

    test "replaces mutation actions with an Undo strip for a temporarily closed row" do
      closed = entry(%{closed_at: ~U[2026-07-18 18:00:00Z]})

      d =
        render_panel(
          journal_entries: [{"journal-entries-#{@entry_id}", closed}],
          journal_expanded_id: @entry_id,
          journal_undo_ids: MapSet.new([@entry_id]),
          journal_local_times: %{
            {@entry_id, :captured} => ~N[2026-07-16 14:32:00],
            {@entry_id, :closed} => ~N[2026-07-18 14:00:00]
          }
        )
        |> doc()

      undo = LazyHTML.query(d, "#journal-undo-entry-#{@entry_id}")

      assert LazyHTML.attribute(undo, "phx-click") == ["undo_journal_close"]
      assert Enum.empty?(LazyHTML.query(d, "#journal-reopen-entry-#{@entry_id}"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-close-entry-#{@entry_id}"))
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

    test "first-use empty explains the source without filter or false CTA" do
      html =
        render_panel(
          journal_entries: [],
          journal_open_count: 0,
          journal_closed_count: 0,
          journal_visible_count: 0
        )

      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#journal-empty-first-use")) == 1
      assert Enum.empty?(LazyHTML.query(d, "#journal-filter"))
      assert Enum.empty?(LazyHTML.query(d, "#journal-empty-first-use button"))
      refute html =~ "Add entry"
    end

    test "filtered empty keeps the filter and offers the single useful next action" do
      d =
        render_panel(
          journal_entries: [],
          journal_open_count: 0,
          journal_closed_count: 7,
          journal_visible_count: 0
        )
        |> doc()

      view_all = LazyHTML.query(d, "#journal-view-all")

      assert Enum.count(LazyHTML.query(d, "#journal-filter")) == 1
      assert LazyHTML.attribute(view_all, "phx-click") == ["set_journal_filter"]
      assert LazyHTML.attribute(view_all, "phx-value-journal-filter") == ["all"]
      assert Enum.count(LazyHTML.query(d, "#journal-empty-filtered .hero-check-circle")) == 1
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
end

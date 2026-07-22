# Step 5 Learning: Add deterministic marker-to-panel scoping

## Summary of Accomplishments

1. **Marker-to-Panel Focus and Entity Scoping Contracts**:
   - Implemented exact-row and entity-scoped journal panel focus triggered via canvas markers (`StationJournalComponents`, `StationDiagramLive`, and `StationJournalMarkers`).
   - Pin activation clears entity target scope (`target_scope = nil`), selects `focus_entry_id = marker.focus_entry_id`, switches filter to `:all` if current filter excludes entry, opens panel, and pushes `journal-focus` with selector `#journal-entries-<entry-id>`.
   - Node and pathway activation sets `target_scope = %{target_type: kind, target_id: marker.target_id, label: label}`, selects `focus_entry_id = marker.focus_entry_id`, calculates scoped open/closed counts without modifying station-wide toolbar count, and pushes `journal-focus` for the focus entry.
   - Preserved current filter tab when entry is present within the target scope; otherwise fell back to `:all`.

2. **Scoped Summary Bar and Clear Action**:
   - Rendered `#journal-target-scope` in `StationJournalComponents.journal_panel/1` when `:journal_target_scope` is present, displaying target entity label and `#journal-clear-target-scope` ("Show all entries") quiet primary button.
   - Clicking "Show all entries" triggers `clear_journal_target_scope`, which resets `:journal_target_scope` to `nil` and reloads station entries under current filter.
   - Closing the journal panel or reopening from the station-wide toolbar clears target scope to return to station-wide queue.

3. **Verification**:
   - Passed all ExUnit unit and integration tests across components, state sync, and marker projection (`51 tests, 0 failures`).
   - Passed Playwright browser test `Package 03 marker to panel scoping and clear action` verifying visual target scope bar rendering, DOM focus management, clear action, and snapshot persistence at `.artifacts/journal-03/production-marker-to-panel.png`.
   - Clean `mix precommit` run with 0 format, credo, or test errors.

## Key Technical Decisions

- **Preserving Toolbar Totals vs Scoped Tab Counts**: Station-wide toolbar count (`open_count + closed_count`) remains invariant when entity target scope is active, maintaining station-level awareness while updating panel header tab counts for scoped items.
- **Marker Projection Alignment**: Ensured `active_journal_geometry` uses `active_level_id(socket)` (`level_id` string token) to maintain exact match with `StationJournalMarkers.project` stop-level index coordinates.
- **Scope Reset Triggers**: Explicitly reset `:journal_target_scope`, `:journal_scoped_open_count`, and `:journal_scoped_closed_count` on `close_journal_panel` and `open_journal_panel(clear_scope?: true)`.

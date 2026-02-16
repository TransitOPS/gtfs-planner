# Cross-Level Node Icons Refactor Spec

## Qualifications
- Elixir (OTP, pattern matching, tagged tuple error handling)
- Phoenix LiveView (event handling, streams, HEEx component composition)
- Ecto query composition and data shaping in context boundaries
- JavaScript (DOM geometry/scaling logic in LiveView hooks)
- Data processing and deterministic transformation design (grouping/sorting pathway-derived badge data)
- Frontend interaction design in SVG/HEEx (pointer events, event propagation control)
- ExUnit + Phoenix.LiveViewTest + Vitest/JSDOM testing for behavior-level verification

## Problem Statement
The current station node secondary icon behavior is inconsistent with pathway editing workflows.

Current issues:
- Non-cross-level secondary badges are still rendered on nodes (`data-stop-badge` wheelchair badge), which violates the target icon model.
- Cross-level badge rendering is derived from distinct modes per stop (`cross_level_pathway_modes`) rather than concrete pathways, so badges cannot map 1:1 to editable pathway records.
- Cross-level badges are non-interactive (`pointer-events-none`), so users cannot open the pathway edit drawer by clicking the icon.

This creates a mismatch between visual indicators and actionable data, and prevents direct pathway editing from the icon affordance.

## Goal
Implement a deterministic cross-level icon system where:
- Node secondary icons represent only cross-level pathways.
- Each secondary icon is derived from an individual cross-level pathway record connected to the active-level stop endpoint.
- Clicking a secondary icon opens the pathway edit drawer for that exact pathway using existing LiveView edit behavior.

## Architecture
### Data Flow
- Source of truth remains `Gtfs.list_pathways_for_level/4`.
- `StationDiagramLive.load_level_data/2` builds stop-keyed, pathway-backed badge data from `level_pathways`.
- Badge data is assigned on socket and passed into diagram components.
- `stops_layer` renders one badge per cross-level pathway for the stop on the active level.
- Badge click dispatches `edit_pathway` with pathway ID; existing handler opens drawer with populated form.

### Data Shape
Replace mode-set structure with a pathway-backed structure.

Current:
- `%{stop_id => MapSet<pathway_mode>}`

Target:
- `%{stop_id => [%{pathway_id: binary(), pathway_mode: integer()}]}`

Rules:
- Include only `is_cross_level == true` pathways.
- Include entry for the endpoint that is on active level.
- Preserve deterministic order per stop (ascending `pathway_id`).
- Do not deduplicate by mode.

### UI/Event Model
- Stop interaction remains through explicit stop hit target element.
- Cross-level badge wrapper becomes interactive and emits `phx-click="edit_pathway"` with `phx-value-id` pathway UUID.
- Badge icon path remains pointer-enabled through wrapper behavior.
- Wheelchair minority badge is removed from node secondary icon rendering.

### Scaling Model
- Keep cross-level icon path scaling in `assets/js/diagram_canvas_hook.js`.
- Remove wheelchair badge scaling loop (`[data-stop-badge]`) because element is removed.

### Standards Alignment
- Context boundary remains intact: data shaping in LiveView from context-returned data, no Repo calls in components.
- Keep functions focused and single-purpose.
- Preserve explicit data flow and deterministic rendering order.
- Tests verify behavior, not implementation internals.

## Acceptance Criteria
1. No node-level secondary icon exists for wheelchair minority state (`[data-stop-badge]` absent in diagram rendering).
2. A stop with `N` cross-level pathways connected on the active level renders exactly `N` cross-level secondary icons.
3. Badge icon type per rendered icon is determined by that pathway’s `pathway_mode`:
   - modes `2` and `4` use stairs icon
   - all other modes use elevator icon
4. Clicking any cross-level secondary icon opens pathway drawer (`#pathway-form`) for the clicked pathway ID.
5. Clicking a cross-level badge does not trigger stop edit selection flow.
6. Platform code label shift continues to prevent overlap using count of rendered cross-level badges.
7. Cross-level pathways remain excluded from the canvas pathway SVG layer and remain visible in list/table views.
8. Existing pathway click behavior is unchanged:
   - view mode: pathway click opens edit drawer
   - add mode: pathway click does not open drawer
9. JS overlay scaling test coverage reflects current DOM model (no stop-badge scaling assertions).
10. All updated targeted tests pass.

## Notes
- Reuse existing `handle_event("edit_pathway", %{"id" => id}, socket)`; do not introduce a new edit event.
- Keep `Pathway.mode_label/1` tooltip behavior on each badge.
- Ensure HEEx class list syntax and LiveView event attributes follow existing project conventions.
- Keep deterministic sorting explicit to avoid flaky test ordering.
- Do not add backward-compatibility branches for the removed wheelchair node badge path.

## Implementation Steps
1. In `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex`, remove socket assigns related only to wheelchair minority node badge rendering (`:wheelchair_minority`) from `mount/3` and level-loading reset branches.
2. In `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex`, delete `compute_wheelchair_minority/1` and all call sites in `load_level_data/2`.
3. In `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex`, replace `cross_level_pathway_modes/2` with a new private helper that builds `%{stop_id => [%{pathway_id, pathway_mode}]}` from `level_pathways` and `active_level_stop_ids`.
4. In the new helper, include only rows where `pathway.is_cross_level == true`; map each pathway to the stop endpoint on active level (`from_stop.id` when `from` endpoint on active level, else `to_stop.id`).
5. In the new helper, append entries per stop and apply deterministic sort per stop by `pathway_id` ascending.
6. In `load_level_data/2`, replace `cross_level_pathway_modes` assignment with new badge map assign (e.g. `:cross_level_badges_by_stop`) and propagate to socket assigns.
7. In `lib/gtfs_planner_web/live/gtfs/station_diagram_live.ex` render tree, replace all `cross_level_pathway_modes={...}` component arguments with the new assign name.
8. In `lib/gtfs_planner_web/live/gtfs/station_diagram_components.ex`, update `diagram_canvas/1`, `diagram_overlay/1`, and `stops_layer/1` attrs to accept the new badge map attr and remove `wheelchair_minority` attr.
9. In `stops_layer/1`, remove the `<text ... data-stop-badge="true">` wheelchair badge block entirely.
10. In `stops_layer/1`, update badge count derivation to call a helper that counts pathway badge entries for the stop from the new map.
11. In `station_diagram_components.ex`, replace `cross_level_badge_count/2` implementation to count list length from new badge map and remove `MapSet` logic.
12. In `station_diagram_components.ex`, remove `show_wheelchair_badge?/2` since no node badge path remains.
13. In `cross_level_badges/1`, change inputs to read stop-specific pathway badge entry list (not modes).
14. In `cross_level_badges/1`, iterate with index over pathway badge entries; compute `badge_offset_x = 1.1 + index * 1.25` unchanged.
15. In `cross_level_badges/1`, set wrapper group to interactive and add `phx-click="edit_pathway"` plus `phx-value-id` with pathway ID.
16. In `cross_level_badges/1`, set tooltip title from `Pathway.mode_label(pathway_mode)` per entry.
17. In `cross_level_badges/1`, select stairs/elevator icon component based on `pathway_mode in [2, 4]` rule.
18. In `stops_layer/1`, move `phx-click="stop_clicked"` and `phx-value-id` from parent `<g>` to the explicit stop hit target element so badge click does not bubble into stop edit flow.
19. In `assets/js/diagram_canvas_hook.js`, remove scaling loop for `[data-stop-badge]` and keep all cross-level badge path scaling logic intact.
20. In `assets/js/__tests__/diagram_canvas_scale_test.js`, remove fixture node with `data-stop-badge` and remove assertions tied to its scaled attributes.
21. In `test/gtfs_planner_web/live/gtfs/station_diagram_live_test.exs`, delete or replace tests that assert wheelchair node badge presence/absence via `[data-stop-badge]` selectors.
22. In `test/gtfs_planner_web/live/gtfs/station_diagram_live_test.exs`, add a focused test that creates at least one cross-level pathway, clicks that stop’s cross-level badge selector, and asserts `#pathway-form` is present with clicked pathway values loaded.
23. In `test/gtfs_planner_web/live/gtfs/station_diagram_live_test.exs`, add a focused test proving a stop with two cross-level pathways of the same mode renders two badges (no mode dedupe).
24. In `test/gtfs_planner_web/live/gtfs/station_diagram_live_test.exs`, keep and adjust existing cross-level badge rendering assertions to use new deterministic selectors/data attributes introduced in badge wrappers.
25. In `lib/gtfs_planner_web/live/gtfs/station_diagram_components.ex`, update diagram legend’s cross-level badge example to match actual rendered cross-level badge appearance.
26. Run targeted tests for modified coverage areas only:
   - `mix test test/gtfs_planner_web/live/gtfs/station_diagram_live_test.exs`
   - JS hook test file for diagram scaling behavior.

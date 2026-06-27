# Step 6 learning: Extend other-levels tests

- **Step:** 6 — "Extend other-levels tests."
- **Step reference:** `.specs/standardize-icons/spec.md` §7 Implementation
  Steps item 6. One-line objective: rewrite the pin-rendering describe block
  in `assets/js/__tests__/map_overlay_layers_test.js` so it exercises the
  restored Entrance/Exit outline, the white halo on non-entrance markers,
  the `OUTLINE_DOT_MIN_OPACITY` legibility floor on outline markers, the
  hover tooltip retention, and the unknown-`location_type` circle
  fallback — importing `symbolForLocationType` from `../stop_icon_symbols`
  and wiring it through `deps.symbolFor`. This is the regression guard
  for AC-9, AC-10, AC-11, AC-12, and AC-15 (overlay half).
- **Covers:** AC-9, AC-10, AC-11, AC-12, AC-15 (overlay half — also feeds
  the T-register rows in `.specs/standardize-icons/criteria.md` and the
  C-6 + C-8 + C-10 tripwires for the other-levels surface).
- **Outcome:** as-specified, with a small DRY polish that was not in the
  pre-implementation file.

## Findings for later steps

- `assets/js/__tests__/map_overlay_layers_test.js` now imports
  `symbolForLocationType`, `HALO_COLOR`, `OUTLINE_DOT_MIN_OPACITY`, and
  `treatmentForLocationType` from `../stop_icon_symbols`. The
  `deps.symbolFor: symbolForLocationType` injection seam is wired with
  a real import (the receiver in `map_overlay_layers.js` no longer reads
  it, but the seam is preserved per C-10 for any future consumer or test
  override).
- The committed version (in `0b9349e`, bundled with step 5) covers all of
  the spec's required assertions. The working-tree version adds an
  `expectMarkerTreatment(pin, locationType, color)` helper that mirrors
  step 5's `expectPinTreatment(pin, locationType)` pattern — pulling
  `{width, height, backgroundColor, borderColor, borderRadius}` from
  `treatmentForLocationType(locationType, color)` and asserting them in
  one call. The helper does not add or remove any AC coverage; it makes
  the assertions explicitly tied to the shared module rather than to
  hand-written literals. The same pattern appears in step 5's
  `map_alignment_hook_test.js` (`expectPinTreatment`).
- No production code (render paths or shared module) was modified by
  this step. `assets/js/map_overlay_layers.js` and
  `assets/js/map_overlay_layers_test.js` already satisfy every AC step 6
  owns; the working-tree helper is a DRY polish on top of that surface.
- Step 6 is the last step in the spec (`§7 Implementation Steps` runs 1–6
  plus the pinning test step 4; steps 4, 5, 6 are the test-side
  deliveries; the spec has no step 7 onward). No later steps depend on
  this learning.

## Discrepancies & risks

- **Pre-implementation work present (committed form).** The committed-at-
  `0b9349e` version of `map_overlay_layers_test.js` (bundled with step 5)
  already satisfies AC-9, AC-10, AC-11, AC-12, and AC-15 (overlay half)
  against the verification below. The committed version imports
  `symbolForLocationType` from `../stop_icon_symbols`, wires it as
  `deps.symbolFor`, asserts the outline, halo, dashed border, opacity
  clamp, and tooltip retention per the spec, and passes 15/15 in
  focused vitest. The step-6 deliverable was effectively already
  complete before this implement pass; the implement pass adds the
  formal subspec, the verification record, and this learning file.
- **Working-tree polish — `expectMarkerTreatment` helper.** Between
  the time this implement pass began (`git status` clean) and the
  vitest verification, the working-tree copy of
  `assets/js/__tests__/map_overlay_layers_test.js` was modified to
  extract an `expectMarkerTreatment(pin, locationType, color)` helper
  that mirrors step 5's `expectPinTreatment`. The helper pulls the
  full treatment descriptor from `treatmentForLocationType` and asserts
  `width`/`height`/`backgroundColor`/`borderColor`/`borderRadius` against
  the resolved pin's DOM styles. Three tests were refactored to use it
  ("renders one pin group per level with non-entrance markers…",
  "renders Entrance/Exit markers…", "renders unknown location types as
  circle markers"). This is a strict improvement (cleaner, less
  duplication, assertions stay aligned with the shared module) and is
  consistent with the step-5 learning's "Findings for later steps"
  note that "`expectPinTreatment` is the reusable shape for 'the
  resolved pin matches the treatment descriptor.'" No AC coverage was
  added or removed; no production code was touched. This step's commit
  includes the polish alongside the subspec and learning file.
- **JS test runner still unwired at the repo level.** As noted in the
  step-1, step-2, step-3, step-4, and step-5 learnings, the repo has no
  `package.json`, no vitest config, and no committed `node_modules`.
  Step 6 verifies behaviorally via two paths:
  1. A 43-case behavioral script (`/tmp/verify-step6/verify.mjs`,
     scratch, deleted after the run) that imports
     `createOtherLevelsLayers` and the shared module against jsdom,
     builds the spec's three-pin payload (entrance, platform, generic
     node), calls `createMarker` and `setOpacity`, and asserts the
     resolved pin styles against `treatmentForLocationType(...)`. **43/43
     pass.**
  2. A focused vitest run against a scratch
     `node_modules/.bin/vitest` install: `vitest run
     assets/js/__tests__/map_overlay_layers_test.js` → **15/15 pass.**
  C-12 ("no new runtime or dev dependencies") is preserved — no
  `package.json`, no `bun.lock`, no `vitest.config.js`, no
  `node_modules` is committed to the repo.
- **`node_modules/.vite/vitest/.../results.json` is a transient cache
  file.** It is in `git ls-files` (committed at `c21c576` and `0f5d389`)
  but represents vitest's per-run results scratch. The step-6 commit
  deliberately does NOT stage it; the change is reverted with
  `git checkout -- node_modules/.vite/vitest/...` after verification
  (see Verification below). The step-4 learning's note that this file
  is "gitignored-equivalent" applies here as well — it is left in the
  working tree in its on-disk state and excluded from the commit.

## Verification

- `node --check assets/js/__tests__/map_overlay_layers_test.js` → ok
  (ES-module syntax accepted; vitest's `describe`/`it`/`expect` are
  runtime imports, not parser errors).
- 43-case behavioral verification
  (`/tmp/verify-step6/verify.mjs`, scratch dir, deleted after the run):
  - AC-9 (6/6): type-2 marker — `8px × 12px`, white fill, level-color
    border, dashed, `2px` radius.
  - AC-10 (6/6): non-entrance markers — level-color fill, white halo,
    dashed (groups A and B).
  - AC-11 (2/2): tooltip retained with
    `classList.contains("group-hover:opacity-100") === true`; tooltip
    text "Stop 1".
  - AC-12 (4/4): at `setOpacity(0)`, type-2 dot opacity ===
    `String(OUTLINE_DOT_MIN_OPACITY)` (clamped), non-entrance dot
    opacity === `"0.35"` (standard path). At `setOpacity(1)`,
    type-2 dot opacity === `"1"` (no clamp when input is above the
    floor).
  - AC-15 (8/8): `location_type: "unknown"`, `null`, `undefined` all
    render a `10px × 10px` circle (`borderRadius === "9999px"`).
    Numeric string `"2"` renders the outline treatment (white fill,
    level-color border, `8px` width) — verifies the
    `Number.parseInt(String(x), 10)` normalization the shared module
    applies (per step 1's "Findings for later steps").
  - Negative per-type-hue regression (9/9): no non-entrance marker
    renders `cssColor("#2563EB")`, `cssColor("#CA8A04")`, or
    `cssColor("#334155")` as its background. The other-levels layer's
    per-level palette `color` flows through `treatment.fill` only.
  - Total: **43/43 pass**, no fix-up attempts.
- Focused vitest run (against a scratch `node_modules/.bin/vitest`
  install, deleted after the run): `vitest run
  assets/js/__tests__/map_overlay_layers_test.js` → **15/15 pass**,
  no fix-up attempts. The `*_test.js` include pattern required a
  temporary `vitest.config.js` since vitest 4's default glob does not
  match the repo's underscore-prefixed convention.
- Full-suite vitest run (scratch vitest install, informational;
  pre-existing failures are out of scope):
  - `map_overlay_layers_test.js` — **15/15 pass** (this step's
    deliverable).
  - `stop_icon_symbols_test.js` — **5/5 pass** (step 4).
  - `map_alignment_hook_test.js` — **10/10 pass** (step 5).
  - `gtfs_version_hook_test.js` — passes (untouched).
  - `diagram_canvas_scale_test.js` — 3 pre-existing floating-point
    failures unrelated to standardize-icons.
  - Net: step 6's surface is **15/15 green**; the 3 pre-existing
    failures are out of step 6's scope.
- criteria.md tripwires for step 6's surface:
  - C-6 (no local geometry helpers in `map_overlay_layers.js`):
    PASS — `rg "function dimensionsForSymbol|function
    borderRadiusForSymbol|dimensionsForSymbol\s*=|borderRadiusForSymbol\s*="
    map_overlay_layers.js` returns no matches.
  - C-8 (imports from `./stop_icon_symbols`): PASS —
    `map_overlay_layers.js:17` imports `OUTLINE_DOT_MIN_OPACITY` and
    `treatmentForLocationType`.
  - C-9 (single treatment descriptor, defined once, consumed by both
    paths): PASS — `treatmentForLocationType` is defined only at
    `assets/js/stop_icon_symbols.js:47`; both
    `map_alignment_hook.js` and `map_overlay_layers.js` consume it.
  - C-10 (seam `symbolFor: symbolForLocationType` preserved):
    PASS — `map_alignment_hook.js:248` still passes
    `symbolFor: symbolForLocationType`. The receiver
    (`createOtherLevelsLayers`) no longer reads `deps.symbolFor`, but
    the call-site seam is intact, satisfying C-10's intent.
- INV-1 (single client-side owner of the vocabulary):
  PASS — `rg "function (symbolForLocationType|dimensionsForSymbol|
  borderRadiusForSymbol|treatmentForLocationType)|
  \b(symbolForLocationType|dimensionsForSymbol|borderRadiusForSymbol|
  treatmentForLocationType)\s*=" assets/js/` filtered to exclude
  `stop_icon_symbols.js` returns no matches.
- INV-2 (color encodes state and level, never type): PASS — `rg
  "#2563EB|#CA8A04|#334155" assets/js/map_alignment_hook.js
  assets/js/map_overlay_layers.js` returns no matches. The other-levels
  layer's per-level palette `color` flows through `treatment.fill` /
  `treatment.stroke` only — color still encodes *which floor* a ghost
  belongs to, never *what type*.
- `mix assets.build` → ok (no JS changes in this step that affect the
  bundle's surface; the test file is loaded only by vitest, not bundled
  into `priv/static/assets/js/app.js`).
- `git diff --check` → ok.

Learning: .specs/standardize-icons/learnings/6-learning.md (step 6)

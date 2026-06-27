# Subspec — Step 5: Update active-layer tests

## Step reference

`.specs/standardize-icons/spec.md` §7 Implementation Steps item 5.

**One-line objective:** rewrite `assets/js/__tests__/map_alignment_hook_test.js`
so the active child-stops rendering describe block exercises the reconciled
color key (base `#0080FF` for non-entrance, white `#FFFFFF` fill + `#0080FF`
border for type-2) and the shared treatment descriptor (width/height/border-
radius come from `treatmentForLocationType`, not from inline literals), and
import `symbolForLocationType` from `../stop_icon_symbols` (not the hook).
This is the regression guard for AC-5, AC-6, AC-7, AC-8, AC-13.

## Prior-step context (what earlier steps already changed)

- **Step 1 (commit `39a69e5`, `6ecf1f9`):** shared module
  `assets/js/stop_icon_symbols.js` now owns `symbolForLocationType`,
  `treatmentForLocationType`, the geometry helpers, the color constants, and
  the outline predicate. Import-free, DOM-free, Leaflet-free.
- **Step 2 (commit `461f971`, `c21c576`):** other-levels render path
  (`map_overlay_layers.js`) routes through `treatmentForLocationType` and
  clamps outline-type dot opacity to `OUTLINE_DOT_MIN_OPACITY`.
- **Step 3 (commit `1578b09`):** active render path
  (`map_alignment_hook.js`) routes through `treatmentForLocationType` with
  `DIAGRAM_BASE_COLOR`, drops `ACTIVE_TYPE_COLORS` /
  `activeColorForLocationType` and the inline geometry switch in
  `_renderActiveChildStops`. The hook still re-exports
  `symbolForLocationType` (line ~1060) as a passthrough so existing
  callers — including the test file at HEAD — keep working until step 5
  migrates them.
- **Step 4 (commit `1578b09`):** pinning test
  `assets/js/__tests__/stop_icon_symbols_test.js` covers AC-1..AC-4 and
  AC-15 for the shared module. Step 5 mirrors that import convention
  (from `../stop_icon_symbols` directly).

## Resolved step text

Spec §7 step 5 (current text — judge has not adapted it):

> In `assets/js/__tests__/map_alignment_hook_test.js`, import
> `symbolForLocationType` from `../stop_icon_symbols` (not the hook).
> Remove the `activeColorForLocationType` per-type-hue assertions (~45–70).
> In the active child-stops rendering describe block, assert: non-entrance
> pins fill `#0080FF` with a white `#FFFFFF` border; a `location_type: 2` pin
> renders white fill with `#0080FF` border; pins of different types share
> the base fill and differ only by shape/geometry from the shared module.

The pre-implementation working tree already carries the step-5
modifications as uncommitted changes against `assets/js/__tests__/map_alignment_hook_test.js`.
The implement pass's contribution is the formal subspec, the verification
record, and the step-5 learning file.

## Target file & symbols (current state)

`assets/js/__tests__/map_alignment_hook_test.js` (modified, not yet committed):

- **Imports** (lines 7–12): already includes
  `DIAGRAM_BASE_COLOR`, `HALO_COLOR`, `symbolForLocationType`,
  `treatmentForLocationType` from `../stop_icon_symbols`. The
  `map_alignment_hook` import on line 3 is restricted to the hook surface
  the test still exercises (`MapAlignmentHook`, `parseAlignmentPayload`,
  `readActiveAlignment`) — no `activeColorForLocationType`, no
  `symbolForLocationType` re-import.
- **`cssColor` helper** (lines 14–18): unchanged.
- **`expectPinTreatment` helper** (lines 20–29, new): pulls the full
  treatment from `treatmentForLocationType(locationType, DIAGRAM_BASE_COLOR)`
  and asserts pin `width`/`height`, dot `backgroundColor`/`borderColor`/
  `borderRadius` against it. This is the single assertion both render paths
  can share — it replaces the four hard-coded geometry literals (8px, 12px,
  10px, 2px, 9999px) that were inline.
- **Active child-stops describe block** (lines 232–350):
  - Stale-payload test (lines 233–259): unchanged.
  - Numeric-string normalization test (lines 261–298): unchanged.
  - **Reconciled color-key test (lines 300–350, rewritten):** renders
    three pins (boarding `location_type: 0`, entrance `location_type: 2`,
    generic-node `location_type: "bad"`) and asserts per pin:
    - `expectPinTreatment(pin, locationType)` for full geometry + colors
    - `symbolForLocationType(locationType)` for the symbol grammar
    - `dot.backgroundColor` is `cssColor(DIAGRAM_BASE_COLOR)` for non-
      entrance and `cssColor(HALO_COLOR)` for type-2
    - `dot.borderColor` is `cssColor(HALO_COLOR)` for non-entrance and
      `cssColor(DIAGRAM_BASE_COLOR)` for type-2
    - Negative assertions on the non-entrance pin: `backgroundColor !==
      cssColor("#2563EB")`, `cssColor("#CA8A04")`, `cssColor("#334155")` —
      guards against any future re-introduction of the per-type hues.

## Concrete edit sequence

The implement pass lands the following single-file edit (already in the
working tree as uncommitted modifications against HEAD's
`map_alignment_hook_test.js`):

1. Add `treatmentForLocationType` to the `../stop_icon_symbols` import block.
2. Add the `expectPinTreatment(pin, locationType)` helper below `cssColor`.
3. In the "renders active child stops with diagram colors, halo, and shared
   geometry" test case, replace the four hard-coded `pin.style.width`/
   `pin.style.height`/`dot.style.borderRadius` literals per pin with a
   single `expectPinTreatment(pin, locationType)` call. Keep the
   `symbolForLocationType(...)` assertion and the resolved fill/stroke
   color checks; add the three negative per-type-hue assertions on the
   non-entrance (boarding) pin.

No other files are touched by step 5. The shared module, both render
paths, the pinning test, and the other-levels test remain for steps 1–4
and 6.

## Targeted tests

- `assets/js/__tests__/map_alignment_hook_test.js` (the file under edit)
  must run cleanly under vitest + jsdom. The "renders active child stops"
  describe block must contain the three new assertions (per-pin
  `expectPinTreatment`, `symbolForLocationType`, and the negative
  `#2563EB` / `#CA8A04` / `#334155` checks).
- All other describe blocks in the file (alignment parsing, pure helpers,
  alignment compute + payload gating, zoom slider) must remain green.

## Verification plan

1. `node --check assets/js/__tests__/map_alignment_hook_test.js` →
   syntax ok (ES-module `import`/`describe`/`it`/`expect` valid).
2. Behavioral verification script (`/tmp/verify-step5/verify.mjs`):
   - Constructs the same three-stop payload as the test case
     (`location_type: 0`, `2`, `"bad"`).
   - Imports `MapAlignmentHook` + the shared module against jsdom.
   - Calls `_renderActiveChildStops` and reads each pin's resolved
     width/height/backgroundColor/borderColor/borderRadius.
   - Asserts 27 cases covering AC-5 (positive + 3 negative hue checks),
     AC-6 (type-2 fill/stroke inversion), AC-7 (non-entrance halo),
     AC-8 (width/height/borderRadius per treatment), AC-15
     (`location_type: "bad"` → circle).
3. Focused vitest run against a scratch `node_modules/.bin/vitest`
   install: `vitest run map_alignment_hook_test.js` → **10/10 pass**.
4. Full-suite vitest run (informational; pre-existing failures are out
   of scope):
   - `map_alignment_hook_test.js`: **10/10 pass** (this step's deliverable).
   - `stop_icon_symbols_test.js`: **5/5 pass** (step 4).
   - `gtfs_version_hook_test.js`: passes (untouched).
   - `diagram_canvas_scale_test.js`: 3 pre-existing floating-point
     failures — unrelated to standardize-icons.
   - `map_overlay_layers_test.js`: 1 pre-existing failure (step 6's
     surface; the test still asserts `borderColor === "rgb(255, 0, 0)"`
     against the post-step-2 white-halo implementation).
5. `mix assets.build` → ok (no JS changes that affect the bundle's
   surface; the test file is loaded only by vitest, not bundled into
   `priv/static/assets/js/app.js`).
6. `git diff --check` → ok.

## Conformance guardrails

From `.specs/standardize-icons/criteria.md`:

- **C-4 (G) — per-type hue literals removed from the active layer:**
  the test file must assert `backgroundColor !== "#2563EB"`, `!==
  "#CA8A04"`, `!== "#334155"` on the non-entrance active pin.
- **C-11 (S) — no inline geometry switch remains in the active render
  method:** the test file must assert width/height/border-radius *only*
  via the shared treatment descriptor (no hard-coded `"8px"`/`"12px"`/
  `"2px"`/`"9999px"` literals).

From `.specs/standardize-icons/invariants.md`:

- **INV-2 — Color encodes state and level, never type:** the negative
  hue assertions are the only client-side guard against re-introducing a
  per-type color lookup in the active render path. The test file is
  the regression tripwire.

## Assumptions

- The pre-implementation working tree carries the step-5 modifications
  already, matching this subspec verbatim. The implement pass's
  contribution is the formal subspec, the verification record, and the
  step-5 learning file. This matches the orchestrator's "subspec →
  implement" split (consistent with step 1's pre-implementation note
  and step 2's note about the prior `subspec` pass).
- The vitest + jsdom runner remains unwired at the repo level (no
  `package.json`, no committed `node_modules`). Verification uses a
  scratch `/tmp/verify-step5/` install, deleted after the run. C-12
  ("no new runtime or dev dependencies") is preserved — no
  `package.json`, no `bun.lock`, no `vitest.config.js`, no
  `node_modules` is committed to the repo.
- The hook still re-exports `symbolForLocationType` (line ~1060). After
  step 5 the test file no longer imports it from the hook, but the
  re-export is left in place as a passthrough so any other external
  consumer keeps working. Step 5 does not touch the re-export (that
  decision is step 3's and stands).

## Hard stop conditions

- If a behavioral assertion fails (vitest run or `/tmp/verify-step5`
  script), make at most two fix-up attempts scoped to this step. The
  diff must remain limited to `map_alignment_hook_test.js` plus the
  subspec + learning files.
- If a failure indicates a real bug in the step-3 active render path
  (i.e. the production code does not produce what the spec describes),
  STOP and write a `blocked` learning file recording the discrepancy —
  this would be a step-3 regression, not a step-5 surface.
- If `node --check` fails on the test file, STOP. The test file must be
  valid ES-module syntax.
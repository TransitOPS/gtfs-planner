# Subspec — Step 6: Extend other-levels tests

## Step reference

`.specs/standardize-icons/spec.md` §7 Implementation Steps item 6.

**One-line objective:** rewrite the other-levels pin-rendering tests in
`assets/js/__tests__/map_overlay_layers_test.js` so each marker assertion is
driven by `treatmentForLocationType(locationType, levelColor)` from the shared
module — locking AC-9, AC-10, AC-11, AC-12, and AC-15 against a single
contract, mirroring the step-5 pattern (`expectPinTreatment`).

## Prior-step context (what earlier steps already changed)

- **Step 1 (commit `39a69e5`, `6ecf1f9`):** shared module
  `assets/js/stop_icon_symbols.js` owns `symbolForLocationType`,
  `treatmentForLocationType`, the geometry helpers, the color constants, and
  the outline predicate. Import-free, DOM-free, Leaflet-free.
- **Step 2 (commit `461f971`, `c21c576`):** other-levels render path
  (`map_overlay_layers.js`) routes through `treatmentForLocationType` and
  clamps outline-type dot opacity to `OUTLINE_DOT_MIN_OPACITY`. The receiver
  no longer reads `deps.symbolFor` (the seam is preserved on the caller side
  per C-10); the marker record carries `outline: treatment.outline` for
  `setOpacity` to re-apply the clamp without re-walking the payload.
- **Step 3 (commit `1578b09`):** active render path routes through the shared
  module with `DIAGRAM_BASE_COLOR`; re-exports `symbolForLocationType` as a
  passthrough (line ~1060).
- **Step 4 (commit `1578b09`):** pinning test
  `assets/js/__tests__/stop_icon_symbols_test.js` covers AC-1..AC-4 and
  AC-15 for the shared module. Step 6 mirrors that import convention
  (from `../stop_icon_symbols` directly).
- **Step 5 (commit `0b9349e`, `e3672fe`, `837bcb5`):** the active-layer test
  adopted an `expectPinTreatment(pin, locationType)` helper that pulls the
  full descriptor from `treatmentForLocationType(locationType,
  DIAGRAM_BASE_COLOR)` and asserts width/height/backgroundColor/borderColor/
  borderRadius against it. Step 6 mirrors that pattern but parameterizes
  the color (the other-levels layer's color channel is the level `color`,
  not the diagram base).
- **Step 5 finding (carry into step 6):** the helper is the reusable shape
  for "the resolved marker matches the treatment descriptor." The
  inlining is trivial because `treatmentForLocationType` already accepts
  the color parameter.

## Resolved step text

Spec §7 step 6 (current text — judge has not adapted it):

> In `assets/js/__tests__/map_overlay_layers_test.js`, pass a real
> `symbolForLocationType` (imported from `../stop_icon_symbols`) as
> `deps.symbolFor` where the marker treatment matters. Add cases: a
> `location_type: 2` marker renders white fill with the level `color` as
> border (outline); a non-entrance marker renders the level `color` as fill
> with a white `#FFFFFF` border and `border-style: dashed`; an unknown
> `location_type` renders a circle; after `setOpacity` at a low value, a
> type-2 marker's dot opacity is at least `OUTLINE_DOT_MIN_OPACITY` while a
> non-entrance marker uses the standard reduced opacity; the hover tooltip
> remains present.

## Current state of the test file

`assets/js/__tests__/map_overlay_layers_test.js` (HEAD, pre-step-6):

- **Imports (lines 1–8):** includes `HALO_COLOR`, `OUTLINE_DOT_MIN_OPACITY`,
  `symbolForLocationType` from `../stop_icon_symbols`. **Missing:**
  `treatmentForLocationType` (step 6 imports it).
- **`cssColor` helper (lines 14–18):** unchanged.
- **`makeDeps` helper (lines 20–29):** already passes
  `symbolFor: symbolForLocationType` as a real imported dep, satisfying the
  step-6 "pass a real `symbolForLocationType`" requirement. Per C-10 the
  receiver no longer reads it, but the seam stays wired.
- **`floorplan`, `stop`, `level` factories (lines 31–53):** unchanged.
- **Test "creates one overlay img per floorplan level …" (lines 56–75):**
  AC-14 surface, pre-existing. Stays.
- **Test "re-applies a floorplan transform …" (lines 77–94):** pre-existing.
  Stays.
- **Tests "removes only the omitted level's overlay" / "removes the overlay
  when floorplan becomes null" (lines 96–137):** pre-existing. Stay.
- **Test "renders one pin group per level with non-entrance markers using
  level fill and white dashed halo" (lines 141–180, AC-10):** asserts
  `backgroundColor === "rgb(255, 0, 0)"` (the literal cssColor of the level
  color) and `borderColor === cssColor(HALO_COLOR)` plus `borderStyle ===
  "dashed"`. **Refactor target:** replace the literal `rgb(...)` and
  `HALO_COLOR` usages with a treatment-driven assertion
  (`expectMarkerTreatment(pin, locationType, levelColor)`). The test must
  still cover two levels with two different colors (`#ff0000`, `#00ff00`)
  to lock the per-level palette channel — the test's value is "level color
  drives fill, not a per-type hue."
- **Test "renders Entrance/Exit markers with white fill and the level color
  as the outline" (lines 182–207, AC-9):** hardcodes `pin.style.width ===
  "8px"`, `pin.style.height === "12px"`, `dot.style.borderRadius ===
  "2px"`, and `dot.style.borderColor === "rgb(51, 102, 153)"`. **Refactor
  target:** drive every assertion through
  `treatmentForLocationType(2, levelColor)`. Keep `borderStyle === "dashed"`
  and `dot.style.backgroundColor === cssColor(HALO_COLOR)` as the
  figure/ground + ghost affordances.
- **Test "renders unknown location types as circle markers" (lines 209–231,
  AC-15):** hardcodes `pin.style.width === "10px"`, `pin.style.height ===
  "10px"`, `dot.style.borderRadius === "9999px"`. **Refactor target:**
  `expectMarkerTreatment(pin, "unknown", levelColor)`. AC-15 belongs to
  both layers, but the pinning test in step 4 already locks the helper
  side; step 6 locks the render-side fallback explicitly.
- **Test "keeps outline opacity above the legibility floor while reducing
  non-entrance markers normally" (lines 233–257, AC-12):** asserts
  `dots[0].style.opacity === String(OUTLINE_DOT_MIN_OPACITY)` for the
  type-2 marker and `dots[1].style.opacity === "0.35"` for the non-entrance
  marker at `setOpacity(0)`. **Refactor target:** keep the clamp assertion
  for the outline marker (the AC); replace the literal `"0.35"` for the
  non-entrance marker with a behavior assertion
  (`expect(...).toBeLessThan(OUTLINE_DOT_MIN_OPACITY)`) so the test fails
  if a future change re-introduces a per-marker override or widens the
  floor. The "0.35" literal currently duplicates the implementation's
  `dotOpacityFor(0)` formula; asserting the behavioral bound is the
  regression tripwire.
- **Test "falls back to stop name, id, and platform …" (lines 259–283,
  AC-11 partial):** asserts the tooltip carries `group-hover:opacity-100`.
  Step 6 keeps this test; adds an explicit assertion on a non-entrance pin's
  tooltip class and an `Entrance/Exit` pin's tooltip class so AC-11 is
  covered for both marker kinds (the spec text: "Other-level markers
  retain the hover tooltip (`group-hover:opacity-100`)"). Tighten the
  selector so it locates the tooltip on the marker that contains the
  rendered pin, not on the parent group's last descendant.
- **Tests "updates marker positions …", "removes the pin group …", "renders
  overlay containers with pointer-events none …", "sets opacity on every
  overlay img via setOpacity", "removes all nodes on destroy …", "throws
  when a required dependency is missing" (lines 285–411):** pre-existing,
  untouched by step 6.

## Concrete edit sequence

Single-file edit on `assets/js/__tests__/map_overlay_layers_test.js`:

1. **Add `treatmentForLocationType` to the shared-module import** (after the
   existing `OUTLINE_DOT_MIN_OPACITY` import on line 6). The block becomes:
   ```js
   import {
     HALO_COLOR,
     OUTLINE_DOT_MIN_OPACITY,
     symbolForLocationType,
     treatmentForLocationType,
   } from "../stop_icon_symbols";
   ```
2. **Add `expectMarkerTreatment(pin, locationType, color)` helper** after
   `cssColor` (between line 18 and line 20). Mirrors step 5's
   `expectPinTreatment` but takes the level color:
   ```js
   function expectMarkerTreatment(pin, locationType, color) {
     const treatment = treatmentForLocationType(locationType, color);
     const dot = pin.firstChild;
     expect(pin.style.width).toBe(treatment.width);
     expect(pin.style.height).toBe(treatment.height);
     expect(dot.style.backgroundColor).toBe(cssColor(treatment.fill));
     expect(dot.style.borderColor).toBe(cssColor(treatment.stroke));
     expect(dot.style.borderRadius).toBe(treatment.borderRadius);
   }
   ```
3. **Refactor the AC-10 test (lines 141–180)** to call
   `expectMarkerTreatment(dotA.firstElementChild.parentElement, 1, "#ff0000")`
   (and the same for level B with `1, "#00ff00"`) inside the existing
   `expect` block. Keep the `borderStyle === "dashed"` assertions; drop
   the hardcoded `rgb(255, 0, 0)` / `rgb(0, 255, 0)` literals in favor of
   the treatment's `fill`. The pin element is the `.map-pin` div, and the
   dot is its first child; the helper takes the pin and walks `.firstChild`
   — so the test passes the pin, not the dot. Update the assertions
   accordingly.
4. **Refactor the AC-9 test (lines 182–207)** to call
   `expectMarkerTreatment(pin, 2, "#336699")` plus the `borderStyle ===
   "dashed"` check. Drop `pin.style.width`, `pin.style.height`,
   `dot.style.backgroundColor`, `dot.style.borderColor`, and
   `dot.style.borderRadius` literals.
5. **Refactor the AC-15 test (lines 209–231)** to call
   `expectMarkerTreatment(pin, "unknown", "#ff0000")` plus a check that
   the dot's `borderStyle === "dashed"`. Drop the three hardcoded
   geometry literals.
6. **Refactor the AC-12 test (lines 233–257)** to keep the outline-clamp
   assertion (`dots[0].style.opacity === String(OUTLINE_DOT_MIN_OPACITY)`)
   and replace `dots[1].style.opacity === "0.35"` with
   `expect(parseFloat(dots[1].style.opacity)).toBeLessThan(OUTLINE_DOT_MIN_OPACITY)`
   so the test asserts behavior, not the literal formula result.
7. **Add an AC-11 explicit assertion** in the existing tooltip test (lines
   259–283): confirm `group-hover:opacity-100` is on the tooltip child of
   the same marker. The current test already locates
   `.map-pin > div:last-child` and checks the class — step 6 keeps that
   selector and adds an explicit AC-11 framing comment.

No other files are touched by step 6. The shared module, both render paths,
the pinning test, and the active-layer test remain at their post-step-1..5
state.

## Targeted tests

- `assets/js/__tests__/map_overlay_layers_test.js` (the file under edit)
  must run cleanly under vitest + jsdom.
- AC-9, AC-10, AC-11, AC-12, AC-15 must all be covered by assertions in
  this file.
- All pre-existing describe blocks ("AC-14", "AC-16", opacity/teardown,
  dependency validation) must remain green.

## Verification plan

1. `node --check assets/js/__tests__/map_overlay_layers_test.js` → ok.
2. Behavioral verification script (`/tmp/verify-step6/verify.mjs`):
   - Imports `createOtherLevelsLayers` and `treatmentForLocationType`
     against jsdom.
   - Constructs the same payloads as the test cases (AC-9 entrance with
     level color `#336699`, AC-10 non-entrance on two levels `#ff0000` /
     `#00ff00`, AC-15 unknown type, AC-12 setOpacity clamp).
   - Asserts each pin's resolved style against the treatment descriptor.
   - Covers AC-9 (4 cases), AC-10 (6 cases across 2 levels × 3 asserts),
     AC-11 (2 cases, both marker kinds), AC-12 (4 cases: outline clamp +
     non-entrance bound), AC-15 (4 cases: width, height, borderRadius,
     symbol-grammar). Target: ~20 cases.
3. Focused vitest run against a scratch `node_modules/.bin/vitest`
   install: `vitest run map_overlay_layers_test.js` → all tests pass.
4. Full-suite vitest run (informational; pre-existing failures are out of
   scope):
   - `map_overlay_layers_test.js`: all tests pass (this step's deliverable).
   - `stop_icon_symbols_test.js`: 5/5 pass (step 4).
   - `map_alignment_hook_test.js`: 10/10 pass (step 5).
   - `gtfs_version_hook_test.js`: passes (untouched).
   - `diagram_canvas_scale_test.js`: 3 pre-existing floating-point
     failures — unrelated to standardize-icons.
5. `mix assets.build` → ok (test file is loaded only by vitest; the bundle
   surface is unchanged).
6. `git diff --check` → ok.

## Conformance guardrails

From `.specs/standardize-icons/criteria.md`:

- **C-6 (G) — other-levels layer drops local geometry helpers:** the
  receiver side of `map_overlay_layers.js` is unchanged by step 6. The
  test file must not reintroduce the old geometry tables; it sources
  width/height/border-radius from the shared treatment descriptor.
- **C-8 (G) — other-levels module imports the shared module:** unchanged;
  step 2 satisfied this. Step 6's test file also imports
  `treatmentForLocationType` from the shared module.
- **C-9 (G) — single treatment descriptor, consumed by both paths:**
  step 6 adds the test file to the set of consumers; the AC-9 / AC-10 /
  AC-15 assertions are pinned through the same descriptor.
- **C-10 (G) — `deps.symbolFor` seam preserved:** the test file passes
  `symbolFor: symbolForLocationType` (already present at line 26).
- **C-12 (S) — no new runtime or dev dependencies:** step 6 preserves
  this — no `package.json`, no `bun.lock`, no `vitest.config.js`, no
  `node_modules` is committed.

From `.specs/standardize-icons/invariants.md`:

- **INV-1 — single client-side owner of the icon vocabulary:** step 6's
  test file consumes `treatmentForLocationType`; it does not redefine
  geometry, symbols, or treatment tables.
- **INV-2 — color encodes state and level, never type:** the test file
  exercises level-color fill on non-entrance markers and a level-color
  border on entrance markers (intentional, documented state/level
  channel). No per-`location_type` color literals appear in the test
  file beyond the level-color fixtures (`#ff0000`, `#00ff00`,
  `#336699`), which are level keys, not type encodings.

## Assumptions

- The vitest + jsdom runner remains unwired at the repo level (no
  `package.json`, no committed `node_modules`). Verification uses a
  scratch `/tmp/verify-step6/` install, deleted after the run. C-12 is
  preserved.
- `treatmentForLocationType` is the only new import. The test file's
  existing `HALO_COLOR`, `OUTLINE_DOT_MIN_OPACITY`, `symbolForLocationType`
  imports stay; the existing `cssColor` helper stays.
- The `expectMarkerTreatment` helper takes `(pin, locationType, color)` —
  the same `(pin, locationType)` shape as step 5's `expectPinTreatment`
  plus the level color channel. The active-layer helper keeps the
  `DIAGRAM_BASE_COLOR` constant; the other-levels layer needs the
  parameterized color because the level `color` is the document-level
  signal being tested.
- The receiver side of `map_overlay_layers.js` does not read
  `deps.symbolFor` (per step 2). Step 6 keeps `makeDeps` wiring the seam
  because the test's job is to exercise the public contract — including
  the seam — and because C-10 demands the seam is preserved.

## Hard stop conditions

- If a behavioral assertion fails (vitest run or `/tmp/verify-step6`
  script), make at most two fix-up attempts scoped to this step. The
  diff must remain limited to `map_overlay_layers_test.js` plus the
  subspec + learning files.
- If a failure indicates a real bug in the step-2 other-levels render
  path (i.e. the production code does not produce what the spec
  describes), STOP and write a `blocked` learning file recording the
  discrepancy — this would be a step-2 regression, not a step-6 surface.
- If `node --check` fails on the test file, STOP. The test file must be
  valid ES-module syntax.
- If the `map_overlay_layers.js` source needs any change (e.g. the
  receiver reads `deps.symbolFor` after all and the dep isn't wired),
  STOP. Step 6 is test-only; touching the receiver is out of scope.
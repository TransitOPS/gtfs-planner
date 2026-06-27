# Step 5 learning: Update active-layer tests

- **Step:** 5 — "Update active-layer tests."
- **Step reference:** `.specs/standardize-icons/spec.md` §7 Implementation Steps
  item 5. One-line objective: rewrite the active child-stops describe block in
  `assets/js/__tests__/map_alignment_hook_test.js` so it exercises the
  reconciled color key (base `#0080FF` for non-entrance, white `#FFFFFF`
  fill + `#0080FF` border for type-2) and the shared treatment descriptor
  (width/height/border-radius from `treatmentForLocationType`, not from
  inline literals), with negative hue assertions guarding against any
  re-introduction of the per-type hues.
- **Covers:** AC-5, AC-6, AC-7, AC-8, AC-13 (also feeds T-register rows for
  AC-5..AC-8 in `.specs/standardize-icons/criteria.md`, plus the C-4
  tripwire's behavioral half and C-11's "no inline switch" half).
- **Outcome:** as-specified.

## Findings for later steps

- The `expectPinTreatment(pin, locationType)` helper at lines 20–29 is
  the reusable shape for "the resolved pin matches the treatment
  descriptor." Step 6 should consider adopting the same helper in
  `map_overlay_layers_test.js` for the level-color fill + halo border
  assertions; if step 6 wants different colors per type (it does —
  `treatmentForLocationType(locationType, levelColor)` instead of
  `DIAGRAM_BASE_COLOR`), the helper can take a `color` argument or be
  inlined. The shared module's `treatmentForLocationType` already
  accepts the color parameter, so the inlining is trivial.
- The negative hue assertions (`backgroundColor !== "#2563EB"`,
  `!== "#CA8A04"`, `!== "#334155"`) live on the non-entrance boarding
  pin only. They are the regression tripwire for AC-5 + C-4: if any
  future change re-introduces a per-type color lookup, this test fails
  before the visual divergence reaches production. Step 6 has no
  equivalent hues to guard against (the other-levels layer's per-level
  palette is the documented state/level channel and stays), so no
  parallel negative assertions are needed there.
- The step-3 re-export of `symbolForLocationType` at line ~1060 of
  `map_alignment_hook.js` is now unused by any in-repo caller (the only
  consumer was this test file, which migrated to
  `../stop_icon_symbols`). The re-export is left in place — external
  callers (if any) keep their current behavior, and removing it is out
  of step 5's surface. A future cleanup commit could drop the re-export
  once the call surface is confirmed.
- Step 6 (`map_overlay_layers_test.js`) is the last test step. Its
  pre-existing failure ("renders one pin group per level with markers
  colored by the level color", asserting `borderColor === "rgb(255, 0,
  0)"` against the post-step-2 white-halo implementation) is the test
  step 6 will rewrite — the spec's step-6 paragraph calls this out
  explicitly. Step 5 leaves it untouched.
- The diff is exactly 21 lines inserted, 9 lines deleted in
  `assets/js/__tests__/map_alignment_hook_test.js`. No other files are
  touched by step 5 — the shared module, both render paths, the
  pinning test, and the other-levels test remain at their post-step-3
  / post-step-4 states.

## Discrepancies & risks

- **Pre-implementation work present.** The implement pass was launched
  with `assets/js/__tests__/map_alignment_hook_test.js` already
  carrying the step-5 modifications as uncommitted changes against
  HEAD. The file's contents match the spec's §7 step-5 paragraph
  verbatim and satisfy AC-5, AC-6, AC-7, AC-8, and AC-13 against the
  verification below. The implement pass's contribution is the formal
  subspec, the commit, and this learning file. This matches the
  orchestrator's "subspec → implement" split (consistent with steps 1,
  2, 3, and 4's pre-implementation notes).
- **`activeColorForLocationType` was already gone from the test file
  in HEAD.** The spec's step-5 paragraph mentions "Remove the
  `activeColorForLocationType` per-type-hue assertions (~45–70)."
  Reading HEAD's `map_alignment_hook_test.js` shows no
  `activeColorForLocationType` import or assertion: step 3's commit
  (`1578b09`) already removed them as part of the active-render-path
  refactor (the prior implementation had a `describe` block
  asserting `activeColorForLocationType(0) === "#2563EB"`, etc.). The
  current step-5 diff is therefore a clean rewrite of the active-
  child-stops rendering test, not a removal of stale assertions.
  This is a documentation/scope drift, not a code discrepancy — the
  test still asserts what the spec describes (no per-type hues, halo
  on non-entrance, white-fill + `#0080FF` border on type-2, shared
  treatment geometry).
- **JS test runner still unwired.** As noted in the step-1, step-2,
  step-3, and step-4 learnings, the repo has no `package.json`, no
  vitest config, and no committed `node_modules`. Step 5 verifies
  behaviorally via two paths:
  1. A 27-case behavioral script (`/tmp/verify-step5/verify.mjs`,
     scratch, deleted after the run) that imports the production
     hook and shared module against jsdom, calls
     `_renderActiveChildStops` with the spec's three-stop payload,
     and asserts the resolved pin styles against
     `treatmentForLocationType(...)`. **27/27 pass.**
  2. A focused vitest run against a scratch
     `node_modules/.bin/vitest` install: `vitest run
     map_alignment_hook_test.js` → **10/10 pass.**
  C-12 ("no new runtime or dev dependencies") is preserved — no
  `package.json`, no `bun.lock`, no `vitest.config.js`, no
  `node_modules` is committed to the repo.
- **Pre-existing failures in other test files (informational, out of
  scope).** When the scratch vitest runner is configured to pick up
  all `*_test.js` files in `__tests__/`, two unrelated test files
  fail before any step-5 work:
  - `diagram_canvas_scale_test.js` — 3 floating-point precision
    failures (e.g. `0.6000000000000014` vs `1.75`). Unrelated to the
    standardize-icons spec.
  - `map_overlay_layers_test.js` — 1 failure ("renders one pin group
    per level with markers colored by the level color"), asserting
    `borderColor === "rgb(255, 0, 0)"` against an implementation that
    now renders a white halo. This is the test the spec's step 6
    will rewrite.
  Step 5 does not touch either file. The active-layer test passes
  10/10 in isolation and 10/10 in the full-suite run.

## Verification

- `node --check assets/js/__tests__/map_alignment_hook_test.js` → ok
  (ES-module syntax accepted).
- 27-case behavioral verification
  (`/tmp/verify-step5/verify.mjs`, scratch, deleted after the run):
  - AC-5 positive (boarding fill `#0080FF`): 1/1.
  - AC-5 negative (boarding fill ≠ `#2563EB` / `#CA8A04` /
    `#334155`): 3/3.
  - AC-6 (entrance fill `#FFFFFF`, border `#0080FF`): 2/2.
  - AC-7 (boarding border `#FFFFFF`): 1/1.
  - AC-8 (boarding/entrance/generic width/height/border-radius per
    `treatmentForLocationType(...)`): 15/15 (5 assertions × 3 pins).
  - AC-15 (`location_type: "bad"` → circle, base fill + halo): 5/5.
  - Total: **27/27 pass**, no fix-up attempts.
- Focused vitest run (against a scratch `node_modules/.bin/vitest`
  install, deleted after the run): `vitest run
  map_alignment_hook_test.js` → **10/10 pass**, no fix-up attempts.
- Full-suite run (scratch vitest install, informational; pre-existing
  failures are out of scope):
  - `map_alignment_hook_test.js` — **10/10 pass** (this step's
    deliverable).
  - `stop_icon_symbols_test.js` — **5/5 pass** (step 4).
  - `gtfs_version_hook_test.js` — passes (untouched).
  - `diagram_canvas_scale_test.js` — 3 pre-existing failures
    unrelated to standardize-icons.
  - `map_overlay_layers_test.js` — 1 pre-existing failure (step 6's
    surface).
  - Net: step 5's surface is **10/10 green**; the 4 pre-existing
    failures are out of step 5's scope.
- criteria.md tripwires for step 5's surface:
  - C-4 (no per-type hue literals in `map_alignment_hook.js`):
    PASS — `rg "#2563EB|#CA8A04|#334155"` returns no matches.
  - C-5 (no local `ACTIVE_TYPE_COLORS` / `activeColorForLocationType`
    / `symbolForLocationType` defs in `map_alignment_hook.js`):
    PASS — `rg` returns no matches (the re-export at line ~1060
    imports and re-exports; no local `function`/`=` definitions).
  - C-11 (no inline geometry switch in `_renderActiveChildStops`):
    PASS — `rg "symbol === \"rect_upright\"|symbol === \"rect_square\""
    map_alignment_hook.js` returns no matches.
- INV-2 (no per-`location_type` color lookup in either render path):
  PASS — `rg "#2563EB|#CA8A04|#334155" map_alignment_hook.js
  map_overlay_layers.js` returns no matches.
- `mix assets.build` → ok (test file is loaded only by vitest; the
  bundle surface is unchanged from the post-step-3 state).
- `git diff --check` → ok.
- `git status` after the step-5 commit: working tree clean for this
  step's files (the subspec and learning files are part of the
  commit).

Learning: .specs/standardize-icons/learnings/5-learning.md (step 5)
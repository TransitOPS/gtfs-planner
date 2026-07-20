# Design-System Alignment Plan

## Status of this document

This document is the design-system alignment plan referenced by the design-system alignment audit. It tracks each Package's progress and the verification gates that bound its completion. The plan was not previously present on the `018-dsa` branch; it is created here so Package 18 can record its owned completion evidence while forward-referencing other Packages' owning artifacts rather than fabricating their contents.

Other Packages' rows will be established by their owning packages. Rows below are populated only when the owning package has produced committed evidence in this branch.

## Verification gates

A Package is recorded as complete only after every gate that applies to its scope has passed. The gates are:

1. **Focused server-side tests** — ExUnit cases for the modified server modules and contracts.
2. **Focused browser tests** — Playwright cases for any contract that depends on a real browser runtime (reflow, focus, target size, native navigation).
3. **`mix precommit`** — the repository-required final gate: `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `credo diff --from-git-ref origin/main --strict`, and `test` (see `mix.exs`).

## Package rows

### Package 18 — Resolve Exceptional HTML Error Surfaces

**Status:** complete.

**Scope:** Replace `GtfsPlannerWeb.ErrorHTML`'s plain 404/500 status phrases with static, branded, semantically structured error pages that compose the existing anonymous `Layouts.app/1` shell and shared `<.button>` component, while leaving JSON errors, prototype retirement, and every other status fallback intact. Close the remaining `ErrorHTML` portion of `EXC-005` and `EXC-012`.

**Findings closed:** `EXC-005`; the remaining `ErrorHTML` portion of `EXC-012`. The `ErrorJSON` portion of `EXC-012` was already satisfied by the existing envelope and was not modified.

**Findings preserved (not addressed by this package):** `EXC-010` remains transferred to Packages 15, 16, and 19; those packages will record their own closure evidence in their own artifacts. Prototype-only findings `EXC-001`–`EXC-004`, `EXC-006`–`EXC-009`, and `EXC-011` remain closed by the Package 8 retirement recorded in `.specs/design-system-alignment/prototype-and-exceptional-surfaces.md`.

**Steps and commits:**

1. Configure format-scoped endpoint error documents — step 1 commit `9f7fef3`. Added `root_layout: [html: {GtfsPlannerWeb.Layouts, :root}]` to `:render_errors`, retained `layout: false`, kept JSON unwrapped. Pinned the format boundary with focused ConnCase assertions on the unknown HTML and JSON paths.
2. Implement safe 404 and 500 templates — step 2 commit `65fb54e`. Embedded `error_html/*` templates, retained the catch-all `render/2`, and created `404.html.heex` and `500.html.heex` with the stable DOM IDs, anonymous `Layouts.app` composition, native recovery anchors, and zero diagnostic disclosure.
3. Add the real-browser error contract and close findings — step 3 commit recorded in this row. Added `assets/e2e/error_pages.spec.js` for the real 404 response, viewport reflow, keyboard focus, target sizing, and native home navigation. Repaired the shared `<.button>` component to enforce `min-h-11` so the recovery CTA meets the 44 px design-system target. Created the audit and plan documents with Package 18's evidence.

**Focused server-side gate:**

```
mix test test/gtfs_planner_web/controllers/error_html_test.exs test/gtfs_planner_web/controllers/station_resolution_prototype_retirement_test.exs
```

Outcome: `9 tests, 0 failures`.

**Focused browser gate:**

```
cd assets && npm run test:browser -- error_pages.spec.js
```

Outcome: `8 passed` (real 404 response, four viewport widths, keyboard reach, focus visibility, target size, native Enter navigation to `/users/log_in`).

**Other affected coverage:** the design-system LiveView suite was re-run after the `<.button>` change to confirm no regression — `mix test test/gtfs_planner_web/live/design_system_live_test.exs` → `129 tests, 0 failures`. The full Playwright overlays suite requires a separately-seeded browser database (`test/support/browser_seed.exs`) and was not re-run as a Package 18 gate; the focused `error_pages.spec.js` is the relevant browser evidence and the controller suite covers the rest of the regression surface.

**Final repository gate:** `mix precommit` (recorded in step 3's learning block alongside the focused gates).

**Intentional limitations:**

- The real 500 page is not exercised end-to-end. The production router exposes no stable URL whose contract is to crash, and Package 18 rejected adding a deliberate crashing route or preserving a malformed URL as a 500 fixture. The 500 template is exercised through direct render in `test/gtfs_planner_web/controllers/error_html_test.exs`; the real 404 route exercises the same root, anonymous shell, `<.button>`, and asset composition the 500 template would use.
- The 404/500 page title renders as `Pathways Studio · Pathways Studio` because `root.html.heex` uses `<.live_title default="Pathways Studio" suffix=" · Pathways Studio">` and the embedded error templates do not pass a `:page_title`. Cosmetic only; no DOM- or copy-contract is affected.

**Documentation deltas:** none. The implementation consumes the already graduated Package 9 shell, button, typography, focus, and feedback contracts. No Components/Foundation documentation update was required.

### Package 15, 16, 19 — own `EXC-010` transfer

Not yet present in this branch. Those packages will record their own completion evidence in their own artifacts when their work lands. This plan does not close, weaken, or modify the transfer.

# Prototype and Exceptional Surfaces Audit

## Status of this document

This document is the exceptional-surfaces audit referenced by the design-system alignment plan. It records the disposition of every Package 8 `EXC-*` finding that the audit ever owned, the retirement decisions that closed the prototype-only findings, and the closure evidence for the production endpoint-rendered error surfaces that Package 18 owns.

The audit was not previously present on the `018-dsa` branch. It is created here so Package 18 can record its owned findings (`EXC-005` and the remaining `ErrorHTML` portion of `EXC-012`) with concrete file/test/browser evidence, while forward-referencing the other Packages' owning documents rather than fabricating their contents. When a later Package establishes its own disposition for `EXC-010` (currently transferred to Packages 15, 16, and 19), that Package's evidence should land in its own package artifact; the cross-references here are not intended to substitute for those.

## Scope

The audit covers two related but disjoint surfaces:

1. The retired `station-data-resolution-prototype` Phoenix route and its retained research files in `priv/prototypes/`.
2. The production endpoint-rendered HTML error surfaces (404 and 500) that the Phoenix application serves when a request cannot be routed or fails.

Both surfaces are user-visible failure paths, but the prototype is intentionally advisory and unreachable, while the production error surfaces are the canonical recovery experience for every unmatched request.

## Package 8 dispositions (retirement, preserved)

Package 8 retired the station-resolution prototype and closed the prototype-only findings. These dispositions are preserved verbatim and must not be reopened by subsequent design-system or error-page work.

- **`EXC-001`** — closed by retirement. The prototype URL `/station-data-resolution-prototype` is unrouted and returns 404. The aligned 404 surface is asserted by `test/gtfs_planner_web/controllers/station_resolution_prototype_retirement_test.exs`.
- **`EXC-002`** — closed by retirement. The prototype's HTML, CSS, and JS files are advisory research artifacts under `priv/prototypes/README.md`, are not in `GtfsPlannerWeb.static_dirs/0`, and are not linked from any product surface.
- **`EXC-003`** — closed by retirement. The former prototype stylesheet URL returns 404 with the aligned error surface (asserted in the retirement test).
- **`EXC-004`** — closed by retirement. The prototype-only navigation, copy, and visual treatments are no longer reachable.
- **`EXC-006`** — closed by retirement. The prototype-only modal and overlay interactions are no longer reachable.
- **`EXC-007`** — closed by retirement. The prototype-only station resolution workflow is no longer reachable.
- **`EXC-008`** — closed by retirement. The prototype-only keyboard map-editing affordances are no longer reachable.
- **`EXC-009`** — closed by retirement. The prototype-only feedback states are no longer reachable.
- **`EXC-011`** — closed by retirement. The prototype-only form and validation surfaces are no longer reachable.

## Transfer (preserved)

- **`EXC-010`** — transferred. This finding's user-navigation, organization/version switcher, and authenticated-control concerns are owned by Packages 15, 16, and 19, not by the exceptional-surfaces audit. Those packages will record their own closure evidence in their own artifacts; this audit does not close, weaken, or modify the transfer.

## Package 18 dispositions (production error surfaces)

Package 18 replaces `GtfsPlannerWeb.ErrorHTML`'s bare status phrases with branded, semantically structured, anonymous 404 and 500 templates that compose the existing `Layouts.root/1` and anonymous `Layouts.app/1` shell and use the shared `<.button>` component for native recovery. The 404 page is exercised end-to-end against the real Phoenix endpoint through a missing-route fixture; the 500 page is exercised through direct template rendering because the production router does not expose a stable URL whose contract is to crash.

### `EXC-005` — closed by Package 18

> Production HTML errors must preserve application identity, landmarks, copy, and a safe recovery action even when LiveView or application JavaScript is unavailable.

**Status:** closed.

**Implementation evidence:**

- `config/config.exs` — `render_errors` adds `root_layout: [html: {GtfsPlannerWeb.Layouts, :root}]` for HTML only, retaining `layout: false` and the existing HTML/JSON view map. The root document supplies the `lang` attribute, viewport meta, favicon, the bundled `app.css`, and the bundled `app.js` that every other browser page uses.
- `lib/gtfs_planner_web/controllers/error_html.ex` — `embed_templates "error_html/*"` plus the catch-all `render/2` keep the public shape. Embedded 404/500 templates take precedence; every other HTML status (e.g. 422) still falls through to `Phoenix.Controller.status_message_from_template/1`.
- `lib/gtfs_planner_web/controllers/error_html/404.html.heex` — composes `<Layouts.app flash={%{}}>` (anonymous branch), exposes `#error-page-404`, `#error-page-404-status`, exactly one `h1`, a plain-language explanation, and one `Return home` recovery anchor at `#error-page-404-home[href="/"]`.
- `lib/gtfs_planner_web/controllers/error_html/500.html.heex` — same anonymous shell, exposes `#error-page-500`, `#error-page-500-status`, one `h1`, plain explanation, and two anchors: `#error-page-500-reload[href=""]` (primary GET reload) and `#error-page-500-home[href="/"]` (secondary escape). No form is rendered, so a failed POST/DELETE body cannot be replayed.

**Test evidence:**

- `test/gtfs_planner_web/controllers/error_html_test.exs` — direct-render cases pin the stable IDs, the one-`h1` hierarchy, the visible status labels, the recovery hrefs and copy, the absence of diagnostic sentinels (`SENTINEL_KIND_LEAK`, `SENTINEL_REASON_LEAK`, `SENTINEL_STACK_LEAK`), the absence of `<form>`, and the absence of authenticated controls (`users/log_in`, `users/log_out`, `Log out`). The 422 fallback case verifies `Unprocessable Content` still renders through the catch-all. Endpoint integration cases verify the unknown HTML path returns 404 with `text/html`, `html[lang="en"]`, the bundled stylesheet and script references, `#app-header`, `#main-content`, and `#error-page-404`. The unknown JSON path case verifies the exact `%{"errors" => %{"detail" => "Not Found"}}` envelope with no HTML wrapper.

**Browser evidence:**

- `assets/e2e/error_pages.spec.js` — real Chromium navigation to `/missing-route-error-pages-018-dsa-step-3` returns HTTP 404 with `text/html`; `#app-header`, `#main-content`, `#error-page-404`, `#error-page-404-status`, the `h1`, and `#error-page-404-home` are all visible; the recovery anchor's `href` is `/` and its label contains `Return home`.

### `EXC-012` — partial closure by Package 18 (ErrorHTML portion only)

> The endpoint-rendered HTML error pages must work at the supported responsive widths, support keyboard recovery, and meet the shared target and focus contracts.

**Status:** the remaining `ErrorHTML` portion is closed. The `ErrorJSON` portion of `EXC-012` was already satisfied by the existing JSON envelope and is not modified by Package 18.

**Test evidence (ErrorHTML portion):**

- `test/gtfs_planner_web/controllers/error_html_test.exs` — the direct-render and endpoint integration cases listed under `EXC-005` also pin the recovery DOM contract (one `h1`, stable IDs, anchor hrefs and copy, no form, no authenticated controls). The fallback case confirms uncustomized statuses do not raise.

**Browser evidence (ErrorHTML portion):**

- `assets/e2e/error_pages.spec.js`:
  - **Responsive reflow:** at 320 px, 640 px, 768 px, and 1280 px CSS viewports, `document.body.scrollWidth <= window.innerWidth` holds.
  - **Keyboard reach:** sequential Tab from a fresh page load reaches `#error-page-404-home` within the anonymous shell's tab order (skip link, header logo home link, recovery anchor).
  - **Focus visibility:** `#error-page-404-home` shows a non-trivial computed outline or box-shadow when focused, satisfying the visible-focus contract.
  - **Target sizing:** `#error-page-404-home` renders a bounding box of at least 44 px tall. (This required repairing `<.button>` to enforce `min-h-11` on its base classes — daisyUI's bare `.btn` is 40 px and the recovery CTA was therefore below the design-system target contract.)
  - **Native navigation:** pressing Enter on `#error-page-404-home` performs native anchor navigation to `/`, which the existing authentication plug redirects to `/users/log_in`. No JavaScript-only event is involved.

**Intentional 500 limitation:** Package 18 does not exercise the real 500 response end-to-end. The Phoenix application exposes no stable production URL whose contract is to raise, and Package 18 rejected both adding a deliberate crashing route and preserving a malformed URL as a 500 fixture. The 500 template is exercised through direct render in `test/gtfs_planner_web/controllers/error_html_test.exs`; the real 404 route exercises the same `Layouts.root/1`, anonymous `Layouts.app/1`, `<.button>`, and asset composition that the 500 template would use at runtime.

## Cross-references

- Prototype retirement test: `test/gtfs_planner_web/controllers/station_resolution_prototype_retirement_test.exs`.
- Prototype fixture boundary: `priv/prototypes/README.md`.
- Endpoint configuration: `config/config.exs` under `GtfsPlannerWeb.Endpoint` `:render_errors`.
- Browser fixture: `assets/playwright.config.js` webServer (Chromium, port 4002, `MIX_ENV=test`).
- Shared design-system contracts (target size, focus, viewport, reflow): `assets/e2e/shared_design_contracts.spec.js`.
- Overlay and dialog contracts (not modified by Package 18): `assets/e2e/overlays.spec.js`.

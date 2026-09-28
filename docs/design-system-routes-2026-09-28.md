# TransitOps design system — routes work surface (2026-09-28)

The routes list (`/gtfs/<version>/routes`) moves from the daisyUI palette to the
TransitOps application design system, superseding the page-content half of the
2026-09-27 header decision ("page content keeps the current theme until a
separate decision") for this one page.

## Applicability check

`tmp/redesign/routes.html` and the design system's `application.html` share one
token grammar, and the prototype is the DS's own workbench pattern:

- Palette: navy `--color-strong`/`--color-default`/`--color-muted`, magenta
  `--color-action`, cyan accent. All present in the DS theme.
- Surfaces: `--color-canvas` page, `--color-subtle`/`--color-control` borders,
  `--radius-control`/`--radius-card`/`--radius-badge`.
- Workbench: search + filters toolbar over a full-width card containing a
  summary row and a sticky-header table. The DS calls this shape `.workbench`,
  so the CSS here uses that name.

The DS also references this codebase, so its tokens already line up with the
header tokens adopted on 2026-09-27. Nothing in the DS contradicted the
prototype.

## What changed

`assets/css/app.css` — the `@theme` block gained the tokens page content needs
(`--color-default`, `--color-action-hover`, `--color-navy-300`/`--color-navy-800`,
`--color-cyan-300`, the `--color-error-*` triple, `--radius-badge`), plus
`.workbench`, `.workbench-table`, and `.workbench-list`. Names stay clear of
daisyUI's (`primary`, `base-*`, `brand`) so the two palettes do not collide.

`lib/gtfs_planner_web/components/route_identity.ex` — one span, 4px badge
radius, bold tabular numerals, an inset `ring-subtle` when the route color sits
below the 3:1 component-graphics floor (WCAG 1.4.11), and a neutral fallback
surface when `route_color` is missing or invalid.

`lib/gtfs_planner_web/live/gtfs/routes_live.ex` — one card holds the search +
filter toolbar, a summary row (result count, one removable chip per active
constraint, clear), the desktop table (Route badge / Name / Mode / Route ID,
sticky header, 44px sort targets), and pagination. Phones get a list of
whole-row links from a second stream, `:routes_mobile`, because one stream
cannot be rendered into both a table and a list — LiveView keys stream items by
DOM id.

## Deliberately not changed

`--color-primary` is still daisyUI purple app-wide. The route ID link keeps
`font-mono link-primary` so the shared table contract holds; the DS magenta
arrives via `text-action`/`bg-action` on this page only. Unifying primary is a
separate, app-wide decision.

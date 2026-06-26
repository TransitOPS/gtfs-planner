# Web Components and Layouts Agent Doc

Source target: `lib-gtfs-planner-web-components`
Scope: Provides shared Phoenix components, layouts, navigation, email layouts, and the GTFS version switcher used across the web UI.
Deep analysis: [`lib-gtfs-planner-web-components.md`](../analysis/lib-gtfs-planner-web-components.md)
Freshness: `source_hash=sha256:5bb8a41d6fb20a8187fd528aec37d3cd159e673f7931aff284faa08072024411`, `last_synthesized=null`

## Use When
- Adding or modifying shared UI components (buttons, inputs, tables, drawers, etc.).
- Changing the app/auth layout shells, header, or flash messages.
- Adjusting navigation link visibility, role gating, or active-tab detection.
- Working on the GTFS version dropdown, rename flow, or JS version-switching hook.
- Touching `station_sub_nav`, `route_sub_nav`, pagination, or route badge rendering.

## Read First
- `lib/gtfs_planner_web/components/core_components.ex` — All reusable function components (flash, button, input, table, drawer, etc.).
- `lib/gtfs_planner_web/components/layouts.ex` — App and auth layouts, flash_group, root embedding.
- `lib/gtfs_planner_web/components/navigation.ex` — Role-gated top navigation bar with active-tab logic.
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex` — LiveComponent for version dropdown + inline rename.
- `assets/js/gtfs_version_hook.js` — Client-side JS hook for version switching via localStorage + URL replacement.
- `lib/gtfs_planner_web.ex:80-101` — `html_helpers` macro that auto-imports CoreComponents into all HTML modules.

## Interfaces

### CoreComponents (stateless function components)
| Component | Key Required Attrs | Notes |
|-----------|-------------------|-------|
| `flash/1` | `kind` (`:info`\|`:error`) | daisyUI toast; click clears flash via `lv:clear-flash` |
| `button/1` | `inner_block` slot | 4 variants (`primary`/`secondary`/`quiet`/`danger`), 3 sizes; auto-picks `<.link>` vs `<button>` |
| `input/1` | `name` or `field` (FormField); `options` for select | Text, checkbox, select, textarea, hidden; daisyUI sizing; error classes swapped on validation fail |
| `checkbox_group/1` | `name`, `label`, `options` | Fieldset with legend; checked via `value in @selected` |
| `header/1` | `inner_block` slot | Page title with optional subtitle and actions slot |
| `table/1` | `id`, `rows`, `:col` slot | Handles both static lists and LiveStreams (`phx-update="stream"`); `row_click` callback optional |
| `list/1` | `:item` slot | Simple item list |
| `route_badge/1` | `route` map | Renders colored pill from `route_color`/`route_text_color`; degrades gracefully on nil colors |
| `pagination/1` | `page`, `per_page`, `total` | Prev/Next buttons emit `phx-click="paginate"`; alert: label hardcoded to "routes" |
| `icon/1` | `name` (must start with `"hero-"`) | Heroicon rendering via bundled JS |
| `simple_form/1` | `inner_block` slot | Adds `space-y-6` wrapper + actions slot over `<.form>` |
| `drawer/1` | `id`, `inner_block` slot | Right slide-in panel; `@open` drives CSS transition; close via `@on_close` event |
| `station_sub_nav/1` | `station`, `gtfs_version_id` | 4 tabs (Details, Diagram, Reports, Reachability); Diagram tab includes upload controls |
| `route_sub_nav/1` | `route`, `gtfs_version_id` | 2 tabs (Details, Patterns); display name by precedence |
| `translate_error/1` | error tuple `{msg, opts}` | Gettext-backed in `"errors"` domain |
| `translate_errors/2` | error keyword list, field atom | **Possibly dead code** — no callers found |

JS helpers: `show/2`, `hide/2` — animated show/hide via `JS` commands.

### Layouts (stateless function components)
| Component | Required | Notes |
|-----------|----------|-------|
| `app/1` | `flash`, `inner_block` | Skip-to-content, header with logo + nav + version switcher + logout; content in `max-w-7xl` |
| `auth/1` | `flash`, `inner_block` | Centered card (`max-w-md`); login/registration pages |
| `flash_group/1` | `flash` | Renders info/error; hidden disconnect notices for `phx-disconnected`/`phx-connected` |
| `root/1` | (embedded template) | Root HTML shell set via `put_root_layout` in router |

### Navigation (stateless function component)
- `top_nav/1` — Requires `current_user`; consumes `current_organization`, `user_roles`, `current_path`, `current_gtfs_version`.

### GtfsVersionSwitcher (LiveComponent — stateful)
- `update/2` — Resets edit state if version ID changes.
- `render/1` — Dropdown (`phx-hook="GtfsVersionHook"`) or inline rename form.
- Events: `start_edit`, `cancel_edit`, `validate`, `save` (calls `Versions.update_gtfs_version/2`, sends `{:gtfs_version_renamed, updated}` to parent).

## Rules & Invariants

### Navigation visibility policy (hard gating)
1. **System admin** (`is_administrator?/1` → `"administrator"` role in any org): **Organizations** tab visible.
2. **Org admin** (`pathways_studio_admin` role in current org): **Users** tab visible.
3. **Editor** (`pathways_studio_editor` in current org) AND `current_organization` AND `current_gtfs_version` all present: Routes, Stations, Import, Export tabs visible.
   - Conjunctive gate: editor tabs require **both** role AND org+version context. Missing either → no GTFS tabs.

### Active-tab detection
- Admin tabs: `String.starts_with?(current_path, literal_path)`.
- GTFS tabs: `String.starts_with?(current_path, "/gtfs") && String.contains?(current_path, tab_name)`.
- This means `/gtfs/v1/import` would not falsely match `contains?("routes")`, but a path like `/gtfs/v1/admin/routes` could — unlikely given current route design.

### Route display name precedence (route_sub_nav)
1. `"short_name - long_name"` (both present)
2. `short_name` alone
3. `long_name` alone
4. `route_id` (fallback — always displayed)

### Pagination invariant
- Empty state: when `total == 0`, displays "0–0" instead of computing start/end (which would produce "1–0").
- **Risk:** label is hardcoded to "routes". Using pagination for non-route collections produces misleading text.
- **Risk:** `page` is not clamped to max; oversized page produces nonsensical display (e.g., "41–25 of 25").

### Diagram upload constraints (station_sub_nav)
- Max 10 MB, PNG/JPG/JPEG/SVG only, single file. Error messages are in-component; constraints are set in parent LiveView's `allow_upload/3`.

## State, I/O & Side Effects

### Server-side state (GtfsVersionSwitcher only)
- `editing?` (boolean), `form` (Phoenix.HTML.Form or nil). Reset when incoming `current_version.id` differs.
- Other components: all stateless (pure renders from assigns).

### I/O and side effects
- **GtfsVersionSwitcher:** `Versions.update_gtfs_version/2` writes to DB on save. Sends `{:gtfs_version_renamed, updated}` message to parent LiveView process on success.
- **JS hook (GtfsVersionHook):** Reads/writes `localStorage` (`gtfs_version_{organizationId}`). On select change, sets `window.location.href` (full page navigation). On mount on GTFS page, pushes `gtfs_version_loaded` event to server.
- **Flash:** `phx-click` pushes `lv:clear-flash` to LiveView to dismiss.
- **All other components:** No direct I/O — pure renderers driven by assigns.

### Integration chain
```
LiveView assigns → <Layouts.app> → <Navigation.top_nav> + <.live_component GtfsVersionSwitcher> + <.flash_group>
```
CoreComponents auto-imported via `html_helpers` into all `use GtfsPlannerWeb, :html` and `:live_component` modules.

## Failure Modes

| Location | Failure | Impact |
|----------|---------|--------|
| `button/1` (core_components.ex:125) | Invalid variant/size bypasses compile check | `Map.fetch!/2` raises `KeyError` |
| `layouts.ex:101` | `current_organization.id` accessed without nil guard | Crash if org nil but version+switcher conditions met |
| `gtfs_version_switcher.ex:30` | `current_version` has no `:id` | Pattern match failure, process crash |
| `gtfs_version_switcher.ex:126` | `Versions.update_gtfs_version/2` raises | Unhandled — crashes LiveComponent |
| `gtfs_version_hook.js:48` | localStorage unavailable (private browsing) | `SecurityError` — not caught |
| `station_sub_nav` diagram mode | `uploads.diagram` nil | Guarded by `@active_level && @uploads` |
| `pagination` (core_components.ex:563) | `page` > actual max, `per_page` = 0 | Nonsensical display or arithmetic error |
| `navigation.ex` | `current_path` not a string | `FunctionClauseError` on `String.starts_with?` |

## Change Checklist
- [ ] Changing `station_sub_nav` or `route_sub_nav` tabs: update URL strings (duplicated from router — no path helper).
- [ ] Changing navigation role gating: review conjunctive editor checks (both role AND org+version required).
- [ ] Adding a new GTFS tab in navigation: update active-detection logic in `navigation.ex:117-125`.
- [ ] Modifying `GtfsVersionSwitcher` save: ensure parent LiveView handles `{:gtfs_version_renamed, ...}` message.
- [ ] Changing pagination: consider parameterizing the "routes" label; guard against `page` overflow.
- [ ] Modifying button/input/drawer: check all consumer LiveViews (20+ use `<Layouts.app>`; CoreComponents imported everywhere).
- [ ] Touching `layouts.ex:101`: audit nil-safety of `current_organization`.
- [ ] Tests: coverage is minimal — only `drawer` and `pagination` have tests. All other components lack dedicated tests.

## Escalate To Deep Analysis
- `email_layouts.ex` is **empty (0 lines)** — dead code or placeholder? Check deep analysis §11.1.
- `translate_errors/2` has **no callers** found — dead code? Check §11.8.
- `simple_form` overlaps with Phoenix's built-in `<.form>` — design rationale? Check §11.3.
- Path URL strings in `station_sub_nav`/`route_sub_nav` duplicate router patterns — refactoring risk. Check §11.6.
- localStorage cross-tab synchronization not implemented — intentional? Check §11.5.

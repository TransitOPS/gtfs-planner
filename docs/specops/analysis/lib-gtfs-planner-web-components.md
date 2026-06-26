# SpecOps Analysis: Web Components and Layouts

**Target:** `lib-gtfs-planner-web-components`
**Source directory:** `lib/gtfs_planner_web/components/`
**Source hash:** `sha256:811017b44c450a9c1fadf34e2eec6fccef3735bc482a59773f73d5ffcc369ecd`
**Analysis date:** 2026-06-26
**Structural unit:** `lib/gtfs_planner_web/components`

---

## 1. Purpose & Responsibilities

This structural unit provides the shared Phoenix component layer for the GtfsPlanner web UI. It encompasses:

1. **Core UI components** (`CoreComponents`) — Reusable function components: flash notices, buttons, form inputs (text/checkbox/select/textarea/hidden), checkbox groups, headers, tables (with LiveView stream support), lists, route badges, pagination, Heroicon rendering, slide-in drawers, a generic `simple_form` wrapper, and station/route sub-navigation bars.
2. **Application layouts** (`Layouts`) — The `app` layout (authenticated main UI with header, navigation, version switcher, and content area), the `auth` layout (unauthenticated login/registration pages with centered card), and the `flash_group` component (info, error, client-disconnect, and server-disconnect flash messages). The root HTML skeleton is embedded from `root.html.heex` via `embed_templates`.
3. **Navigation** (`Navigation`) — Role-aware top navigation bar with pill-style links. Visibility of each link is gated on user roles (`administrator`, `pathways_studio_admin`, `pathways_studio_editor`) and availability of `current_organization` / `current_gtfs_version` assigns.
4. **GTFS Version Switcher** (`GtfsVersionSwitcher`) — A `LiveComponent` that renders a `<select>` dropdown for switching between GTFS versions (client-side navigation via JS hook) and an inline rename form (server-side validation/persistence via `Versions` context).
5. **Email Layouts** (`EmailLayouts`) — An empty module (0 lines). Present as a placeholder or artifact of the Phoenix generator.

### Evidence

- `lib/gtfs_planner_web/components/core_components.ex:1-3` — Module definition with moduledoc
- `lib/gtfs_planner_web/components/layouts.ex:1-5` — Layouts module definition
- `lib/gtfs_planner_web/components/navigation.ex:1-6` — Navigation module definition
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:1-11` — GtfsVersionSwitcher LiveComponent
- `lib/gtfs_planner_web/components/email_layouts.ex` — Empty file (0 lines)
- `lib/gtfs_planner_web/components/layouts/root.html.heex` — Root HTML template
- `lib/gtfs_planner_web.ex:80-101` — `html_helpers` macro imports `CoreComponents`, aliases `Layouts`

---

## 2. Public Interfaces & Entry Points

### 2.1 CoreComponents (GtfsPlannerWeb.CoreComponents)

All functions are public function components callable from any HEEx template that `use`s `GtfsPlannerWeb, :html` or imports `GtfsPlannerWeb.CoreComponents`.

| Component | Signature | Required Attrs |
|-----------|-----------|----------------|
| `flash/1` | `flash(assigns)` | `kind` (atom, `:info`\|`:error`) |
| `button/1` | `button(assigns)` | `inner_block` slot |
| `input/1` | `input(assigns)` | `name` (when no `field`), `options` (when `type: "select"`) |
| `checkbox_group/1` | `checkbox_group(assigns)` | `name`, `label`, `options` |
| `header/1` | `header(assigns)` | `inner_block` slot |
| `table/1` | `table(assigns)` | `id`, `rows`, `:col` slot |
| `list/1` | `list(assigns)` | `:item` slot |
| `route_badge/1` | `route_badge(assigns)` | `route` (map) |
| `pagination/1` | `pagination(assigns)` | `page`, `per_page`, `total` |
| `icon/1` | `icon(assigns)` | `name` (string, must start with `"hero-"`) |
| `simple_form/1` | `simple_form(assigns)` | `inner_block` slot |
| `drawer/1` | `drawer(assigns)` | `id`, `inner_block` slot |
| `station_sub_nav/1` | `station_sub_nav(assigns)` | `station`, `gtfs_version_id` |
| `route_sub_nav/1` | `route_sub_nav(assigns)` | `route`, `gtfs_version_id` |
| `translate_error/1` | `translate_error({msg, opts})` | error tuple |
| `translate_errors/2` | `translate_errors(errors, field)` | error keyword list, field atom |

JS helper functions (not components):
- `show/2`, `hide/2` — Returns JS commands for animated show/hide transitions.

### 2.2 Layouts (GtfsPlannerWeb.Layouts)

| Component | Signature | Required Attrs |
|-----------|-----------|----------------|
| `app/1` | `app(assigns)` | `flash`, `inner_block` slot |
| `auth/1` | `auth(assigns)` | `flash`, `inner_block` slot |
| `flash_group/1` | `flash_group(assigns)` | `flash` |
| `root/1` | (embedded template) | (used as root layout) |

### 2.3 Navigation (GtfsPlannerWeb.Navigation)

| Component | Signature | Required Attrs |
|-----------|-----------|----------------|
| `top_nav/1` | `top_nav(assigns)` | `current_user` |

### 2.4 GtfsVersionSwitcher (GtfsPlannerWeb.Components.GtfsVersionSwitcher)

This is a `LiveComponent` (not a function component).

| Callback | Purpose |
|----------|---------|
| `update/2` | Receives assigns from parent, resets edit state if version changed |
| `render/1` | Renders dropdown or inline rename form |
| `handle_event("start_edit", ...)` | Enters rename mode |
| `handle_event("cancel_edit", ...)` | Exits rename mode |
| `handle_event("validate", ...)` | Validates rename form changes |
| `handle_event("save", ...)` | Persists rename, sends `{:gtfs_version_renamed, ...}` to parent |

### 2.5 EmailLayouts

Empty module — no public interface.

### Evidence

- `lib/gtfs_planner_web/components/core_components.ex:34-1093` — All component definitions
- `lib/gtfs_planner_web/components/layouts.ex:30-233` — All layout component definitions
- `lib/gtfs_planner_web/components/navigation.ex:31-98` — `top_nav/1` definition
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:18-134` — All LiveComponent callbacks
- `lib/gtfs_planner_web.ex:80-101` — `html_helpers` imports `CoreComponents` and aliases `Layouts` into all HTML modules

---

## 3. Data Models & Structures

### 3.1 CoreComponents assigns (input data)

- **flash**: Map of flash messages keyed by kind atom (`:info`, `:error`). Consumed via `Phoenix.Flash.get/2`.
- **form field**: `Phoenix.HTML.FormField` struct — carries `field.id`, `field.name`, `field.value`, `field.errors`.
- **route badge**: Map with keys `:route_color` (hex string), `:route_text_color` (hex string), `:route_short_name` (string or nil).
- **table rows**: Either a list of items or a `Phoenix.LiveView.LiveStream` struct. When a LiveStream, `row_id` defaults to extracting the tuple id (`fn {id, _item} -> id end`).
- **station record**: Map with at minimum `:stop_name`, `:stop_id`.
- **route record**: Map with `:route_id`, `:route_short_name`, `:route_long_name`.

### 3.2 Layouts assigns

- **flash**: Map of flash messages.
- **current_user**: User struct or nil.
- **current_organization**: Organization struct or nil (must have `:id`).
- **user_roles**: List of role strings (e.g. `["pathways_studio_editor"]`).
- **current_path**: String, current URL path for tab highlighting.
- **current_gtfs_version**: Map with at minimum `:id`, `:name`.
- **available_versions**: List of `{id, name}` tuples for the GTFS dropdown.

### 3.3 Navigation assigns

- **current_user**, **current_organization**, **user_roles**, **current_path**, **current_gtfs_version**: Same as Layouts.

### 3.4 GtfsVersionSwitcher assigns

- **current_version**: `%GtfsVersion{}` struct (has `:id`, `:name`).
- **versions**: List of `{id, name}` tuples.
- **organization_id**: Used as `data-organization-id` on the container DOM element.
- **editing?**: Boolean, controls display of inline rename form vs dropdown.
- **form**: `Phoenix.HTML.Form` struct derived from `Versions.change_gtfs_version/1` changeset.

### 3.5 Error translation

Errors are `{msg, opts}` tuples passed through Gettext via `dgettext`/`dngettext` with the `"errors"` domain and the `GtfsPlannerWeb.Gettext` backend.

### Evidence

- `lib/gtfs_planner_web/components/core_components.ex:42-46,50-51,213-229,537-539,557-559` — Assign definitions
- `lib/gtfs_planner_web/components/layouts.ex:30-57` — App layout assigns
- `lib/gtfs_planner_web/components/layouts.ex:200` — Auth layout assigns
- `lib/gtfs_planner_web/components/navigation.ex:31-36` — Navigation assigns
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:18-27` — Update callback assigns
- `lib/gtfs_planner_web/components/core_components.ex:1069-1085` — translate_error implementation

---

## 4. Behavioral Contracts

### 4.1 Flash component

- Renders a toast-alert div positioned top-right (`toast-top toast-end z-50`).
- On click, pushes `lv:clear-flash` JS event and hides self with animation.
- Displays an icon based on `kind` (`hero-information-circle` for info, `hero-exclamation-circle` for error).
- Renders only when `render_slot(@inner_block)` is truthy or `Phoenix.Flash.get(@flash, @kind)` returns a message.
- Uses daisyUI `alert-info`/`alert-error` classes.

### 4.2 Button component

- Renders either a `<.link>` or `<button>` depending on whether `href`, `navigate`, or `patch` attributes are present in `rest`.
- Supports 4 variants (`primary` → `btn-primary`, `secondary` → `btn-outline`, `quiet` → `btn-ghost`, `danger` → `btn-error`) and 3 sizes (`sm` → `btn-sm`, `md` → `""`, `lg` → `btn-lg`).
- Default variant is `primary`, default size is `md`.
- Uses `Map.fetch!/2` — will raise if an invalid variant/size string is passed (but the attr `:values` constraint prevents this at compile time).

### 4.3 Input component

- When passed a `Phoenix.HTML.FormField` via `field`, extracts `id`, `name`, `value`, and errors from it. Appends `"[]"` suffix to name when `multiple: true`.
- For checkbox: renders a hidden input with `value="false"` before the visible checkbox to ensure unchecked state is submitted.
- For select: uses `Phoenix.HTML.Form.options_for_select/2`. Supports `prompt` option for a blank first option.
- For textarea: normalizes value with `Phoenix.HTML.Form.normalize_value/2`.
- For text and other inputs: applies `Phoenix.HTML.Form.normalize_value/2`.
- Default classes apply daisyUI `input-lg`, `select-lg`, `textarea-lg`, `checkbox` sizing.
- Error state is indicated by swapping to `input-error`/`select-error`/`textarea-error` class (or custom `error_class`).
- Help text (when present) is rendered below the input with `aria-describedby` linking.

### 4.4 Checkbox group component

- Renders a `<fieldset>` with a legend containing the label (and red `*` if required).
- Each option renders as a `<label>` with an `<input type="checkbox">`.
- `checked` state determined by `value in @selected`.
- Error is rendered with `role="alert"` and `aria-live="polite"`.

### 4.5 Table component

- Supports both static lists and LiveView streams.
- When `rows` is a `LiveStream`, `phx-update="stream"` is set on the `<tbody>`, and `row_id` defaults to `fn {id, _item} -> id end`.
- Optional `row_click` callback sets `phx-click` and hover cursor on each cell.
- Optional `row_item` mapping function (defaults to `&Function.identity/1`) transforms rows before passing to slots.
- Actions column renders only when `@action` slot is non-empty.

### 4.6 Pagination component

- Displays "Showing X–Y of Z routes" (static label text).
- Empty state special case: when `total == 0`, shows "Showing 0–0 of 0 routes" instead of "Showing 1–0".
- Previous/Next buttons emit `phx-click="paginate"` with `phx-value-page` set to decremented/incremented page.
- Buttons are disabled on boundary pages.

### 4.7 Drawer component

- Renders an overlay (z-40) and a slide-in panel (z-50) from the right side.
- Open/close state driven by `@open` boolean — uses CSS classes `translate-x-0` (open) vs `translate-x-full` (closed) with `transition-transform duration-300`.
- Overlay uses `opacity-100`/`opacity-0 pointer-events-none` classes.
- Both overlay and close button emit `phx-click={@on_close}` (default `"close_drawer"`).
- Header background is `bg-emerald-50` with `border-emerald-100`.
- Default max width: `max-w-[min(100vw,48rem)]`, min width: `320px`.
- Content area is scrollable with `overflow-y-auto`.

### 4.8 Station sub-navigation component

- Renders a back button navigating to `/gtfs/:gtfs_version_id/stops`.
- Displays 4 tabs as links with underline active styles: Details, Diagram, Reports, Reachability.
- Active tab indicated by `border-primary` class and `aria-selected="true"`, `aria-current="page"`.
- On the Diagram tab, additional controls render: Add Level, Edit Level, Apply Naming buttons + diagram upload form with live file input.
- Diagram upload errors are surfaced via `upload_errors/1` helper.
- Upload constraints enforced by `diagram_upload_error_to_string/1`: max 10 MB, PNG/JPG/JPEG/SVG only, single file, plus generic failure messages.

### 4.9 Route sub-navigation component

- Renders a back button navigating to `/gtfs/:gtfs_version_id/routes`.
- Displays route name by precedence: `short_name - long_name` > `short_name` > `long_name` > `route_id`.
- 2 tabs: Details, Patterns.

### 4.10 App layout

- Renders a skip-to-content link at the top.
- Header bar contains:
  - Logo + "Pathways Studio" branding linking to `/`.
  - (When authenticated) Top navigation bar (centered).
  - (When authenticated) GTFS version switcher LiveComponent (if versions available).
  - Logout link.
- Optional `sub_header` slot renders between header and main content.
- Main content is wrapped in `max-w-7xl` (authenticated) or `max-w-2xl` (unauthenticated).
- `flash_group` renders at the bottom.

### 4.11 Auth layout

- Centered card layout with logo branding for login/registration/etc.
- Card uses `max-w-md`, shadow-sm, with border.
- `flash_group` renders at the bottom.

### 4.12 Flash group

- Renders info and error flash notices.
- Additionally renders two hidden flash notices that become visible on disconnect:
  - `#client-error`: "We can't find the internet" — shown on `phx-disconnected`, hidden on `phx-connected`.
  - `#server-error`: "Something went wrong!" — shown on `phx-disconnected`, hidden on `phx-connected`.
  - Both show "Attempting to reconnect" with a spinning arrow icon.

### 4.13 Navigation (top_nav)

- Renders a `<nav>` with `aria-label="Main navigation"`.
- Each link is role-gated:
  - **Organizations**: visible only when `is_administrator?(current_user)` returns true (system admin, checks `"administrator"` in user's org memberships).
  - **Users**: visible when user has `pathways_studio_admin` role AND `current_organization` is set.
  - **Routes, Stations, Import, Export**: visible when user has `pathways_studio_editor` role AND `current_organization` AND `current_gtfs_version` are set.
- Active pill styling uses `bg-[#009966]` (emerald green) for active, `bg-emerald-50` for inactive.
- Active detection:
  - Non-GTFS tabs: `String.starts_with?(current_path, tab_path)`.
  - GTFS tabs: `String.starts_with?(current_path, "/gtfs") && String.contains?(current_path, tab_name)`.

### 4.14 GTFS Version Switcher

- In non-editing mode: renders a labeled `<select>` dropdown bound to `phx-hook="GtfsVersionHook"`.
  - The JS hook (`GtfsVersionHook`) drives version switching via localStorage and client-side navigation (`window.location.href` replacement).
  - The hook also pushes `gtfs_version_loaded` event to the server on mount if on a GTFS page.
  - The hook's `selectVersion` replaces the version ID segment in the URL path via regex `/\/gtfs\/[^/]+/`.
- In editing mode: renders an inline rename form with validation.
  - On save: calls `Versions.update_gtfs_version/2`, sends `{:gtfs_version_renamed, updated}` to parent process.
  - On validation: calls `Versions.change_gtfs_version/2`, tags changeset with `action: :validate`.
- When assigned version changes (different `id`), edit state is reset (`editing?: false, form: nil`).

### Evidence

- `lib/gtfs_planner_web/components/core_components.ex:50-79` — Flash
- `lib/gtfs_planner_web/components/core_components.ex:99-145` — Button
- `lib/gtfs_planner_web/components/core_components.ex:213-349` — Input (all clauses)
- `lib/gtfs_planner_web/components/core_components.ex:372-404` — Checkbox group
- `lib/gtfs_planner_web/components/core_components.ex:465-501` — Table
- `lib/gtfs_planner_web/components/core_components.ex:561-602` — Pagination
- `lib/gtfs_planner_web/components/core_components.ex:712-759` — Drawer
- `lib/gtfs_planner_web/components/core_components.ex:808-960` — Station sub-nav
- `lib/gtfs_planner_web/components/core_components.ex:993-1064` — Route sub-nav
- `lib/gtfs_planner_web/components/layouts.ex:59-141` — App layout
- `lib/gtfs_planner_web/components/layouts.ex:203-233` — Auth layout
- `lib/gtfs_planner_web/components/layouts.ex:153-183` — Flash group
- `lib/gtfs_planner_web/components/navigation.ex:37-98` — Top nav
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:40-103` — Render
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:106-134` — Event handlers
- `assets/js/gtfs_version_hook.js:1-55` — JS hook implementation

---

## 4A. Decision Logic, Business Rules & Policy Surface

### Navigation visibility policy

The navigation component encodes an authorization policy:

1. **System Administrator** (`is_administrator?/1` → checks for `"administrator"` role in ANY organization membership): Can see "Organizations" tab.
2. **Organization Admin** (`pathways_studio_admin` role in current organization): Can see "Users" tab.
3. **Editor** (`pathways_studio_editor` role in current organization): Can see Routes, Stations, Import, Export tabs — but ONLY when both `current_organization` AND `current_gtfs_version` are present.

This is a conjunctive gate: editor tabs require BOTH role AND org+version context.

### GTFS tab active detection

GTFS tabs use a different active-detection logic than admin tabs:
- Admin tabs: `String.starts_with?(current_path, "/admin/organizations")` etc.
- GTFS tabs: `String.starts_with?(current_path, "/gtfs") && String.contains?(current_path, tab_name)`.

This means a path like `/gtfs/v1/import` would match `String.contains?("routes")` → false, which is correct. But a hypothetical path like `/gtfs/v1/admin/routes` could theoretically falsely match.

### Route display name precedence

In `route_sub_nav`, the display name is resolved by this precedence:
1. `"short_name - long_name"` (when both present)
2. `short_name` alone
3. `long_name` alone
4. `route_id` (fallback)

### Diagram upload constraints

The `station_sub_nav` component defines upload error messages for:
- `:too_large` → "File is too large (max 10 MB)"
- `:not_accepted` → "File type not accepted (PNG, JPG, JPEG, SVG only)"
- `:too_many_files` → "Only one file can be uploaded at a time"
- `:external_client_failure` → "Upload failed"
- `{:error, reason}` → reason string
- binary string → the string itself
- catch-all → "Upload error"

Note: These error messages are in the component file but refer to LiveView upload constraints configured elsewhere (likely in the parent LiveView's `allow_upload/3` call). The component only displays them.

### Pagination empty state

Special case logic: when `total == 0`, the display shows "0–0" instead of computing `(page - 1) * per_page + 1`, which would produce "1–0".

### Evidence

- `lib/gtfs_planner_web/components/navigation.ex:40-96` — Role-gating logic
- `lib/gtfs_planner_web/components/navigation.ex:117-125` — Active tab detection
- `lib/gtfs_planner_web/components/core_components.ex:996-1008` — Route name precedence
- `lib/gtfs_planner_web/components/core_components.ex:962-973` — Upload error messages
- `lib/gtfs_planner_web/components/core_components.ex:563` — Pagination empty state

---

## 4B. Policy Tests & Behavioral Scenarios

### Navigation role gating

| Scenario | Expected Behavior |
|----------|-------------------|
| User is system administrator | "Organizations" pill is visible |
| User has `pathways_studio_admin` in current org | "Users" pill is visible |
| User has `pathways_studio_editor` with org and version set | Routes, Stations, Import, Export pills are visible |
| User has `pathways_studio_editor` but no `current_organization` | No GTFS pills visible |
| User has `pathways_studio_editor` but no `current_gtfs_version` | No GTFS pills visible |
| Unauthenticated user (no current_user) | No navigation rendered (guarded by `<%= if @current_user do %>` in layouts.ex) |

### Pagination

| Scenario | Expected |
|----------|----------|
| Page 1, 10 per page, 25 total | "Showing 1–10 of 25 routes", Previous disabled, Next enabled |
| Page 2, 10 per page, 25 total | "Showing 11–20 of 25 routes", both enabled |
| Page 3, 10 per page, 25 total | "Showing 21–25 of 25 routes", Previous enabled, Next disabled |
| Page 1, 10 per page, 0 total | "Showing 0–0 of 0 routes", both disabled |

### Drawer

| Scenario | Expected |
|----------|----------|
| `open: true` | Panel has `translate-x-0`, overlay has `opacity-100` |
| `open: false` | Panel has `translate-x-full`, overlay has `opacity-0 pointer-events-none` |
| `title` provided | Title renders in header |
| `on_close` custom | Both overlay and close button use custom event name |

### GTFS Version Switcher

| Scenario | Expected |
|----------|----------|
| Non-editing mode with versions | Dropdown visible, rename button visible |
| Click rename button | Switches to editing mode with form |
| Save with valid name | Calls `Versions.update_gtfs_version`, sends message to parent |
| Save with invalid name | Shows validation errors via changeset |
| Click cancel | Returns to non-editing mode, discards form |
| Incoming version has different ID | Resets edit state to non-editing |
| User changes dropdown selection | JS hook intercepts, updates localStorage, navigates browser |

### Evidence

- `test/gtfs_planner_web/components/core_components_test.exs:9-217` — Drawer and pagination tests
- `test/gtfs_planner_web/live/components_live_test.exs:13-200` — Components page integration tests
- `lib/gtfs_planner_web/components/navigation.ex:40-96` — Role gating

---

## 5. State Management

### Server-side state

All components are stateless function components except `GtfsVersionSwitcher` which is a `LiveComponent` with internal state:

| State field | Type | Purpose |
|-------------|------|---------|
| `editing?` | boolean | Whether inline rename form is visible |
| `form` | `Phoenix.HTML.Form` or nil | Form for rename (derived from changeset) |

State transitions:
- `update/2`: Resets state (`editing?: false, form: nil`) when `current_version.id` changes.
- `"start_edit"` → sets `editing?: true`, `form: to_form(Versions.change_gtfs_version(current_version))`.
- `"validate"` → updates `form` from changeset with `action: :validate`.
- `"save"` success → sets `editing?: false, form: nil, current_version: updated`.
- `"save"` failure → updates `form` with error changeset.
- `"cancel_edit"` → sets `editing?: false, form: nil`.

### Client-side state (JS hook)

The `GtfsVersionHook` manages:
- `localStorage` key `gtfs_version_{organizationId}` to persist selected version across page loads.
- `select` element change event binding/unbinding in `mounted`/`updated`/`destroyed`.
- On mount: if on a GTFS page (`/\/gtfs\/[^/]+/`), pushes `gtfs_version_loaded` event to server with stored version ID.

### Layout-level state (pass-through)

The layouts and navigation components hold no internal state. They are pure renders driven by parent assigns passed through from LiveViews.

### Evidence

- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:18-35` — Update callback with state reset
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:106-134` — Event handlers
- `assets/js/gtfs_version_hook.js:1-55` — Client-side state management
- `lib/gtfs_planner_web/components/core_components.ex:1-1093` — All function components are stateless
- `lib/gtfs_planner_web/components/layouts.ex:1-234` — All layout components are stateless
- `lib/gtfs_planner_web/components/navigation.ex:1-131` — Navigation is stateless

---

## 6. Dependencies

### Internal (within GtfsPlannerWeb)

| Module | Depends On | Relationship |
|--------|-----------|-------------|
| `CoreComponents` | `Phoenix.Component`, `GtfsPlannerWeb.Gettext`, `Phoenix.LiveView.JS` | Uses component system, i18n, JS commands |
| `Layouts` | `GtfsPlannerWeb, :html` (imports CoreComponents, UserAuth), `Navigation`, `GtfsVersionSwitcher` | Composes navigation and version switcher |
| `Navigation` | `CoreComponents` (for icon), `UserAuth` (for `is_administrator?/1`) | Import |
| `GtfsVersionSwitcher` | `GtfsPlannerWeb, :live_component` (imports CoreComponents), `GtfsPlanner.Versions` | Uses Versions context for CRUD |
| `root.html.heex` | Embedded by `Layouts` via `embed_templates "layouts/*"` | Template embedding |

### External (beyond GtfsPlannerWeb)

| Module | Dependency | Purpose |
|--------|-----------|---------|
| `GtfsVersionSwitcher` | `GtfsPlanner.Versions` | `change_gtfs_version/2`, `update_gtfs_version/2` |
| `CoreComponents` | `Phoenix.Flash` | Flash message retrieval |
| `CoreComponents` | `Phoenix.HTML.Form` | `normalize_value/2`, `options_for_select/2` |
| `Navigation` | `GtfsPlanner.Accounts` (via `UserAuth.is_administrator?/1`) | Checks for admin role |

### CSS/DaisyUI dependencies

- All components use Tailwind CSS v4 classes and daisyUI component classes (`btn`, `alert`, `input`, `select`, `textarea`, `checkbox`, `table`, `fieldset`, `card`, `navbar`, `toast`, etc.).
- Icons depend on Heroicons being bundled via `assets/vendor/heroicons.js`.

### JS dependencies

- `GtfsVersionSwitcher` is bound to the `GtfsVersionHook` JS hook imported in `assets/js/app.js`.
- Flash components use `phx-click` JS commands (`show`, `hide`, `JS.push`).
- Drawer close uses `phx-click` which maps to a LiveView event handler in the parent.

### Evidence

- `lib/gtfs_planner_web/components/core_components.ex:29-32` — Uses Phoenix.Component, Gettext, alias JS
- `lib/gtfs_planner_web/components/layouts.ex:6-8` — `use GtfsPlannerWeb, :html`, alias Navigation
- `lib/gtfs_planner_web/components/navigation.ex:8-10` — Imports CoreComponents, UserAuth
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:13-15` — `use GtfsPlannerWeb, :live_component`, alias Versions
- `lib/gtfs_planner_web.ex:80-101` — `html_helpers` macro composes all imports
- `assets/js/app.js:27,37` — GtfsVersionHook registration
- `lib/gtfs_planner_web/router.ex:8,18,29` — Root layout configuration

---

## 7. Side Effects & I/O

### Network I/O

| Component | Side Effect | Trigger |
|-----------|------------|---------|
| `GtfsVersionSwitcher` | `Versions.update_gtfs_version/2` — writes to database | `"save"` event |
| `GtfsVersionSwitcher` | `send(self(), {:gtfs_version_renamed, updated})` — message to parent process | After successful save |
| `GtfsVersionSwitcher` (via JS hook) | `localStorage.setItem()` — browser storage write | Version dropdown change |
| `GtfsVersionSwitcher` (via JS hook) | `window.location.href` assignment — full page navigation | Version dropdown change |
| `GtfsVersionSwitcher` (via JS hook) | `this.pushEvent("gtfs_version_loaded", ...)` — LiveView event | On mount when on GTFS page |
| `flash` component | `JS.push("lv:clear-flash", ...)` — LiveView event to clear flash | Click on flash toast |

### JS hook I/O (client-side)

The `GtfsVersionHook`:
1. Reads `localStorage` on mount to find persisted version.
2. If on a GTFS page, pushes `gtfs_version_loaded` event to server.
3. On select change, writes to `localStorage` and navigates by replacing the GTFS version segment in the URL path.
4. Binds/unbinds DOM event listeners.

### No direct I/O

- `CoreComponents`, `Layouts`, `Navigation` do not perform direct I/O. They are pure renderers.
- `EmailLayouts` is empty and does nothing.

### Evidence

- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:125-128` — DB write and process message
- `assets/js/gtfs_version_hook.js:6-14` — localStorage read and LiveView event push
- `assets/js/gtfs_version_hook.js:47-52` — localStorage write and navigation
- `lib/gtfs_planner_web/components/core_components.ex:57` — Flash clear event push
- `lib/gtfs_planner_web/components/core_components.ex:1-1093` — No I/O in CoreComponents
- `lib/gtfs_planner_web/components/layouts.ex:1-234` — No I/O in Layouts
- `lib/gtfs_planner_web/components/navigation.ex:1-131` — No I/O in Navigation

---

## 8. Error Handling & Failure Modes

### CoreComponents

| Component | Failure Mode | Handling |
|-----------|-------------|----------|
| `button/1` | Invalid variant/size string | Compile-time validation via `attr :values` constraint. If bypassed, `Map.fetch!/2` raises `KeyError` at runtime. |
| `input/1` | Missing field or name | `assign_new` provides defaults; falls through. For hidden without name, renders broken input. |
| `input/1` (select) | Nil options | `Phoenix.HTML.Form.options_for_select/2` handles nil/empty list. |
| `table/1` | Non-LiveStream rows without `row_id` | `row_id` defaults to nil; table renders without row IDs. |
| `pagination/1` | Negative page | No guard — would produce negative start_item. |
| `route_badge/1` | Missing route_color/route_text_color | Would render `style="background-color: #; color: #"` — CSS ignores invalid values. |
| `station_sub_nav/1` | Missing `uploads.diagram` in diagram mode | `@active_level && @uploads` guard prevents rendering of upload controls when nil. |

### Layouts

| Failure Mode | Handling |
|-------------|----------|
| `current_organization` is nil but user is not admin | `current_organization.id` access in `layouts.ex:101` would crash with nil. Conditional `if @current_gtfs_version && @available_versions != []` partially guards, but `current_organization.id` is accessed unconditionally. |
| `current_gtfs_version` is nil but editor role tabs are shown | Navigation gates on `@current_gtfs_version`, but layout only renders switcher when both conditions are met. |
| Flash contains unexpected keys | Only `:info` and `:error` are rendered in flash_group; unknown keys are silently ignored. |

### GtfsVersionSwitcher

| Failure Mode | Handling |
|-------------|----------|
| `current_version` has no `:id` | Pattern match `%{id: incoming_id}` in `reset_edit_if_version_changed` would crash with match error. |
| `Versions.update_gtfs_version/2` returns error | Caught in `{:error, changeset}` clause, form is updated with errors. |
| `Versions.change_gtfs_version/2` raises | Not handled — would crash the LiveComponent process. |
| JS hook fails to find select element | `bindSelect()` returns early if no select found; hook silently degrades. |
| localStorage unavailable (private browsing) | `localStorage.setItem/getItem` throws `SecurityError` in some browsers — not caught in JS hook. |

### Navigation

| Failure Mode | Handling |
|-------------|----------|
| `current_user` is nil but `is_administrator?` called | `is_administrator?/1` has a catch-all clause returning `false` for non-maps. |
| `current_path` is not a string | `String.starts_with?` would raise `FunctionClauseError`. |
| `has_role?` receives atom role | Converts to string with `Atom.to_string/1`; safe. |

### Evidence

- `lib/gtfs_planner_web/components/core_components.ex:125` — `Map.fetch!/2` potential key error
- `lib/gtfs_planner_web/components/layouts.ex:101` — `current_organization.id` nil risk
- `lib/gtfs_planner_web/components/navigation.ex:127-130` — `has_role?` atom handling
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:30-32` — Pattern match on version id
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:126-133` — Error handling in save
- `assets/js/gtfs_version_hook.js:30-36` — Select binding defensive check
- `assets/js/gtfs_version_hook.js:48` — localStorage write without try/catch

---

## 9. Integration Points & Data Flow

### 9.1 Layouts as integration hub

The `Layouts` module is the primary integration point:
- It composes `Navigation.top_nav`, `GtfsVersionSwitcher` LiveComponent, and `CoreComponents.flash`.
- It receives data through assigns passed from LiveViews (via `<Layouts.app flash={@flash} current_user={...} ...>`).

**Data flow:**
```
LiveView assigns
  → <Layouts.app flash={@flash} current_user={@current_user} ...>
    → <Navigation.top_nav current_user={...} current_organization={...} .../>
    → <.live_component module={GtfsVersionSwitcher} current_version={...} versions={...}/>
    → <.flash_group flash={@flash}/>
```

### 9.2 Router integration

The root layout is set in all browser pipelines:
```
plug :put_root_layout, html: {GtfsPlannerWeb.Layouts, :root}
```
This renders `root.html.heex` as the outermost HTML shell, with `{@inner_content}` replaced by the app/auth layout.

### 9.3 LiveView template usage

20+ LiveView modules use `<Layouts.app>` as their layout wrapper. Examples:
- `DashboardLive`, `RoutesLive`, `StopsLive`, `StopDetailLive`, `RouteDetailLive`, `ImportLive`, `ExportLive`, `StationDiagramLive`, `StationReachabilityLive`, `StationReport2Live`, `ValidationResultLive`, `UserSettingsLive`, `OrganizationsLive`, `UsersLive`, `ComponentsLive`.

Auth pages use `<Layouts.auth>`:
- `UserLoginLive`, `UserForgotPasswordLive`, `UserResetPasswordLive`, `UserConfirmationLive`, `UserAcceptInviteLive`, `FirstAdminLive`.

### 9.4 CoreComponents consumers

`CoreComponents` is auto-imported via `html_helpers` in `gtfs_planner_web.ex:88`:
```elixir
import GtfsPlannerWeb.CoreComponents
```
This makes all CoreComponents functions available in every LiveView, LiveComponent, and HTML module that does `use GtfsPlannerWeb, :html` or `use GtfsPlannerWeb, :live_component`.

### 9.5 GtfsVersionSwitcher → JS hook → server round-trip

1. User selects version in dropdown.
2. `GtfsVersionHook.selectVersion` fires → writes to localStorage → sets `window.location.href`.
3. Full page navigation occurs → server renders the new version's page.
4. On page load, if on GTFS page, hook pushes `gtfs_version_loaded` with stored version ID.
5. Parent LiveView handles `gtfs_version_loaded` event (server-side logic outside this target).

### 9.6 GtfsVersionSwitcher rename flow

1. User clicks rename → `"start_edit"` → shows form.
2. User types → `"validate"` → validates via `Versions.change_gtfs_version/2`.
3. User submits → `"save"` → `Versions.update_gtfs_version/2` → on success, `send(self(), {:gtfs_version_renamed, updated})` to parent LiveView.
4. Parent LiveView handles `{:gtfs_version_renamed, updated}` (reloads version data, updates assigns).

### Evidence

- `lib/gtfs_planner_web/router.ex:8,18,29` — Root layout plug
- `lib/gtfs_planner_web/components/layouts.ex:59-141` — App layout composition
- `lib/gtfs_planner_web.ex:88` — CoreComponents auto-import
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:40-103` — Render with phx-hook binding
- `assets/js/gtfs_version_hook.js:1-55` — Full JS hook flow

---

## 10. Edge Cases & Implicit Behavior

### 10.1 Pagination with page > ceil(total/per_page)

If `page` is larger than the theoretical max (e.g., page 5 with 25 items, 10 per page), the component would compute `end_item = min(50, 25) = 25`, `start_item = 41`. This would show "Showing 41–25 of 25 routes" — a nonsensical display. The component does not clamp `page` to a valid maximum. (**Risk**)

### 10.2 Pagination with zero per_page

If `per_page` is 0, division by zero in `(page - 1) * per_page + 1` produces arithmetic error in Elixir. (**Risk**)

### 10.3 Pagination label hardcoded to "routes"

The pagination component always displays "... of N routes". This is semantically incorrect when used for non-route collections (e.g., stations, users). The label is hardcoded. (**Design issue**)

### 10.4 Table with both static list and stream update

When `rows` is a LiveStream, `phx-update="stream"` is set. When rows is a plain list, no `phx-update` is set. This means the table handles both modes transparently but the parent must be aware of which mode is in use.

### 10.5 Drawer with rapid open/close toggling

CSS transitions (`duration-300`) mean the drawer takes 300ms to animate. If `@open` is toggled rapidly, CSS transitions will be interrupted mid-animation. The `pointer-events-none` on the closed overlay prevents phantom clicks during transition, but the panel itself has no such protection.

### 10.6 Flash messages after redirect

Phoenix flash messages persist across redirects (stored in session). The `flash_group` renders them on the next page load. The `phx-click` to clear flash pushes `lv:clear-flash` which is handled by LiveView's built-in flash clearing mechanism.

### 10.7 Checkbox group with duplicate option values

If `@options` contains duplicate values, multiple checkboxes will share the same `name` and `value`, potentially causing confusing behavior. No deduplication is performed.

### 10.8 Input component `checked` attribute for non-checkbox

The `checked` attr is documented for checkbox inputs but is technically accepted on all input types. It would produce invalid HTML (checked on text inputs) but browsers would ignore it.

### 10.9 Route badge with empty/missing color

If `route_color` or `route_text_color` is nil, the style attribute would render `background-color: #;` — browsers would ignore this invalid CSS value. The badge would render unstyled.

### 10.10 Station sub-nav with missing station name

Falls back to `stop_id` for display: `{@station.stop_name || @station.stop_id}`.

### 10.11 Route sub-nav with all name fields nil

Falls through all cond branches to `route_id`. This ensures something is always displayed.

### 10.12 `email_layouts.ex` — empty file

The file exists (0 bytes) but the scans show `use Phoenix.Component` in its header was presumably removed at some point. The file might be a forgotten artifact or a placeholder for future email layout components. Currently does nothing. (**Ambiguity**)

### 10.13 GtfsVersionSwitcher — memory leak risk from send to self()

On successful rename, `send(self(), {:gtfs_version_renamed, updated})` is called. If the parent LiveView process is terminated or not handling this message, it will accumulate in the mailbox. (**Low risk** — parent is always a LiveView process that should handle this message.)

### 10.14 JS hook — path replacement regex

The regex `/\/gtfs\/[^/]+/` matches the first occurrence of `/gtfs/<anything>` in the path. This assumes:
- The version ID segment immediately follows `/gtfs/`.
- There is exactly one such segment.
- The path structure is always `/gtfs/{version_id}/{resource}/...`.

If a path like `/gtfs/v1/admin/routes` existed (unlikely given current route design), it would still work correctly. However, if a path contained `/gtfs/` in a deeper segment (e.g., `/admin/gtfs/v1/routes`), it would match incorrectly.

### Evidence

- `lib/gtfs_planner_web/components/core_components.ex:563-564` — Pagination start_item/end_item computation
- `lib/gtfs_planner_web/components/core_components.ex:578` — Hardcoded "routes" label
- `lib/gtfs_planner_web/components/core_components.ex:726-731` — Drawer CSS transitions
- `lib/gtfs_planner_web/components/core_components.ex:826` — Station name fallback
- `lib/gtfs_planner_web/components/core_components.ex:996-1008` — Route name fallback chain
- `assets/js/gtfs_version_hook.js:50` — Path replacement regex
- `lib/gtfs_planner_web/components/email_layouts.ex` — Empty file
- `lib/gtfs_planner_web/components/gtfs_version_switcher.ex:127` — send to parent process

---

## 11. Open Questions & Ambiguities

1. **EmailLayouts — dead code?** The `email_layouts.ex` file contains 0 lines. Is it an intentional placeholder for future email layout components, or an artifact that should be removed? Not referenced anywhere in the codebase.

2. **Pagination "routes" label** — The pagination component hardcodes "routes" in its display text. Should this be parameterized so it can be reused for other entity types? Currently no other collection uses it (routes listing is the primary consumer), but the component is in CoreComponents, implying general reuse.

3. **`simple_form` vs built-in `<.form>`** — The `simple_form` component adds `space-y-6` wrapper and an actions slot, but there's overlap with Phoenix's built-in `<.form>`. Is there a specific reason `simple_form` exists rather than using `<.form>` directly with custom wrappers?

4. **Layout `current_organization.id` nil-safety** — `layouts.ex:101` accesses `current_organization.id` without nil check, guarded only by `if @current_gtfs_version && @available_versions != []`. If a non-admin user has a `current_gtfs_version` but no `current_organization`, this would crash. Is this scenario impossible given the authentication pipeline? (**Confidence: Medium** — the auth pipeline likely guarantees organization context for non-admin users, but this isn't enforced within the layout component itself.)

5. **Version switcher localStorage key collision** — The localStorage key is `gtfs_version_{organizationId}`. If multiple browser tabs for the same organization are open, changing the version in one tab would not affect others until page reload (since the hook only reads localStorage on mount). Is cross-tab synchronization desired?

6. **`station_sub_nav` tab URLs** — The URL patterns embedded in `station_sub_nav` (`/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}`, `/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}/diagram`, etc.) duplicate route patterns that are defined in the router. A route change would require updating strings in the component. Is there helper module for generating these paths?

7. **Missing tests** — No tests found specifically for:
   - `flash/1` component
   - `button/1` component (all variants/sizes)
   - `input/1` component (all types, form field integration)
   - `checkbox_group/1` component
   - `table/1` component
   - `header/1`, `list/1`, `route_badge/1`, `icon/1`
   - `simple_form/1`
   - `station_sub_nav/1`, `route_sub_nav/1`
   - `layouts.ex` (app, auth, flash_group)
   - `navigation.ex` (top_nav role gating)
   - `GtfsVersionSwitcher` LiveComponent

   Tests exist only for `drawer/1` and `pagination/1`. Coverage is minimal.

8. **`translate_errors/2` usage** — This function is defined but grep across the codebase shows no callers. It may be dead code or used in generated forms not yet committed.

### Evidence

- `lib/gtfs_planner_web/components/email_layouts.ex` — Empty file
- `lib/gtfs_planner_web/components/core_components.ex:578` — Hardcoded "routes"
- `lib/gtfs_planner_web/components/layouts.ex:101` — Nil risk
- `test/gtfs_planner_web/components/core_components_test.exs` — Limited coverage
- `lib/gtfs_planner_web/components/core_components.ex:1090-1092` — `translate_errors/2`

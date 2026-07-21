defmodule GtfsPlannerWeb.Design.ProposalPages do
  @moduledoc ~S"""
  Proposals pages for the `/design` section: improvements, content & IA,
  transit patterns, and experimental components.

  Most pages here are plain-HTML-and-Tailwind mockups of something that does not
  exist yet, so a proposal cannot be mistaken for shipped API. A proposal
  graduates by landing in `core_components.ex` and earning a Components page —
  never by being promoted from this module.

  The experimental page is an exception: it renders real components that are
  implemented and tested but not yet adopted in production. These are marked
  experimental with clear ownership and graduation paths.

  Every Tailwind/daisyUI class here is a literal string. Tailwind v4 scans
  source text, so an interpolated class name compiles but is silently missing
  from the bundle. See the moduledoc on `FoundationPages`.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents

  @doc """
  Grounded recommendations: observed problems, proposed fixes, and the gaps
  against neighboring design systems.
  """
  def improvements(assigns) do
    ~H"""
    <section id="ds-page-improvements" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Improvements</h1>
      <p class="mt-2 text-base-content/70">
        What the system needs next, grounded in the code it has today. A proposal
        graduates by landing in <code class="font-mono text-sm">core_components.ex</code>
        and earning a Components page — never by being promoted from this module. As
        each one ships, its section leaves this page and the gap table below records
        where it went.
      </p>

      <h2 class="mt-8 text-lg font-semibold">This round, graduated</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Five components shipped: <code class="font-mono text-sm">callout</code>, <code class="font-mono text-sm">status_badge</code>, <code class="font-mono text-sm">empty_state</code>, <code class="font-mono text-sm">skeleton</code>, and
        <code class="font-mono text-sm">confirm_dialog</code>
        — see Feedback, Badges, and Overlays. Alongside them: the off-token palettes
        retired (drawer header, upload controls, diagram tooltip now on tokens), the
        toast lifted to <code class="font-mono text-sm">z-[60]</code>
        above every surface, <code class="font-mono text-sm">&lt;.pagination&gt;</code>
        took an entity attribute, <code class="font-mono text-sm">&lt;.table&gt;</code>
        gained column alignment and a sort affordance, and the drawer now traps focus
        and closes on Escape. The sections that proposed them are gone; the mechanic
        stays.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Gaps against neighboring systems</h2>
      <p class="mt-1 text-sm text-base-content/60">
        What Polaris, Carbon, and the GOV.UK system ship that this one lacks.
        Precedent is not a reason by itself; each row is here because the need is
        already visible in this app. Shipped rows stay as a record of the round.
      </p>
      <div class="mt-3 overflow-x-auto">
        <table id="ds-gaps-table" class="w-full text-sm">
          <thead>
            <tr class="border-y border-base-300 text-left text-xs font-semibold text-base-content/60">
              <th class="py-2 pr-4 font-semibold">Pattern</th>
              <th class="py-2 pr-4 font-semibold">Precedent</th>
              <th class="py-2 pr-4 font-semibold">Here today</th>
              <th class="py-2 font-semibold">Where it lands</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr>
              <td class="py-2 pr-4 font-medium">Empty state</td>
              <td class="py-2 pr-4 text-base-content/70">Polaris empty state, GOV.UK "no results"</td>
              <td class="py-2 pr-4 font-medium text-success">Shipped</td>
              <td class="py-2 text-base-content/70">Feedback</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Loading skeleton</td>
              <td class="py-2 pr-4 text-base-content/70">Carbon skeleton states</td>
              <td class="py-2 pr-4 font-medium text-success">Shipped</td>
              <td class="py-2 text-base-content/70">Feedback</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Confirmation dialog</td>
              <td class="py-2 pr-4 text-base-content/70">Polaris and Material dialogs</td>
              <td class="py-2 pr-4 font-medium text-success">Shipped</td>
              <td class="py-2 text-base-content/70">Overlays</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Inline callout</td>
              <td class="py-2 pr-4 text-base-content/70">Polaris banner, Carbon notification</td>
              <td class="py-2 pr-4 font-medium text-success">Shipped</td>
              <td class="py-2 text-base-content/70">Feedback</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Status badge</td>
              <td class="py-2 pr-4 text-base-content/70">Polaris badge, Carbon tag</td>
              <td class="py-2 pr-4 font-medium text-success">Shipped</td>
              <td class="py-2 text-base-content/70">Badges</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Z-index scale</td>
              <td class="py-2 pr-4 text-base-content/70">Carbon layers, Material elevation</td>
              <td class="py-2 pr-4 font-medium text-success">Shipped</td>
              <td class="py-2 text-base-content/70">Overlays</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Breadcrumb</td>
              <td class="py-2 pr-4 text-base-content/70">GOV.UK, Carbon</td>
              <td class="py-2 pr-4 text-base-content/70">Back links move one hop</td>
              <td class="py-2 text-base-content/70">Content &amp; IA</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Global search</td>
              <td class="py-2 pr-4 text-base-content/70">Carbon UI shell search</td>
              <td class="py-2 pr-4 text-base-content/70">Per-table filters only</td>
              <td class="py-2 text-base-content/70">Content &amp; IA</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Content guidelines</td>
              <td class="py-2 pr-4 text-base-content/70">
                Polaris content section, GOV.UK style guide
              </td>
              <td class="py-2 pr-4 text-base-content/70">House-rule bullets on Introduction</td>
              <td class="py-2 text-base-content/70">Content &amp; IA</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Date &amp; number standards</td>
              <td class="py-2 pr-4 text-base-content/70">Carbon, GOV.UK date guidance</td>
              <td class="py-2 pr-4 text-base-content/70">Ad hoc per page</td>
              <td class="py-2 text-base-content/70">Content &amp; IA</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Accessibility page</td>
              <td class="py-2 pr-4 text-base-content/70">GOV.UK, Carbon accessibility docs</td>
              <td class="py-2 pr-4 text-base-content/70">Contrast documented on Colors</td>
              <td class="py-2 text-base-content/70">
                Foundations, next — seed is the Overrides block
              </td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Data-viz palette</td>
              <td class="py-2 pr-4 text-base-content/70">Carbon data-viz palette</td>
              <td class="py-2 pr-4 text-base-content/70">Map and diagram colors picked locally</td>
              <td class="py-2 text-base-content/70">Backlog</td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="mt-3 text-sm text-base-content/60">
        Open rows next in wayfinding order — breadcrumb, then global search — because
        finding a record is the top task; the Content &amp; IA standards and the
        Foundations accessibility page follow.
      </p>
    </section>
    """
  end

  @doc """
  Information architecture and copywriting: terminology, formats, microcopy,
  and wayfinding rules.
  """
  def content(assigns) do
    ~H"""
    <section id="ds-page-content" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Content &amp; IA</h1>
      <p class="mt-2 text-base-content/70">
        Words and structure are components too: reused everywhere, versioned nowhere.
        This page fixes terms, formats, and paths once so individual screens stop
        deciding them locally. Examples are plain-HTML mockups.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Scope is wayfinding</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Every record lives inside a GTFS version, and the version switcher already
        sits in the app header. The rules that keep that working: scope never
        disappears on a scoped view, the title names the record and the subtitle
        names the scope (the Navigation header demo already does this), and a
        read-only version says so where editing would start — not on submit.
      </p>
      <div
        id="ds-version-chip-demo"
        class="mt-3 flex flex-wrap items-center gap-3 border border-base-300 p-4"
      >
        <span class="inline-flex items-center gap-1.5 border border-base-300 px-2 py-1 text-sm">
          <span class="font-mono">2026-01</span>
          <span class="inline-flex items-center gap-1">
            <span class="size-1.5 rounded-full bg-base-content/40" aria-hidden="true"></span>
            <span class="font-medium text-base-content/60">Draft</span>
          </span>
        </span>
        <span class="inline-flex items-center gap-1.5 border border-base-300 px-2 py-1 text-sm">
          <span class="font-mono">2025-04</span>
          <span class="inline-flex items-center gap-1">
            <span class="size-1.5 rounded-full bg-success" aria-hidden="true"></span>
            <span class="font-medium text-success">Published</span>
          </span>
        </span>
        <span class="text-sm text-base-content/60">
          — published versions are read-only; the chip says so before an edit begins
        </span>
      </div>

      <h2 class="mt-8 text-lg font-semibold">The hierarchy needs a ladder</h2>
      <p class="mt-1 text-sm text-base-content/60">
        GTFS nests: station, level, platform, boarding area. The sub-navigation bars
        move sideways between tabs, and the back button moves one hop; nothing shows
        the whole path or jumps two levels. A breadcrumb is the ladder.
      </p>
      <nav id="ds-breadcrumb-demo" aria-label="Breadcrumb" class="mt-3 border border-base-300 p-4">
        <ol class="flex flex-wrap items-center gap-1.5 text-sm">
          <li><a href="#" class="text-primary hover:underline">Stations</a></li>
          <li aria-hidden="true" class="text-base-content/40">/</li>
          <li><a href="#" class="text-primary hover:underline">Demo Central</a></li>
          <li aria-hidden="true" class="text-base-content/40">/</li>
          <li><a href="#" class="text-primary hover:underline">Level 1</a></li>
          <li aria-hidden="true" class="text-base-content/40">/</li>
          <li aria-current="page" class="font-medium">Platform A</li>
        </ol>
      </nav>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          the current page is text, not a link · truncate the middle on narrow screens, never the record name
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Search is the front door</h2>
      <p class="mt-1 text-sm text-base-content/60">
        A production feed carries thousands of stops; browse-then-paginate makes the
        top task — find a specific stop or route — cost a page walk. A global search
        that matches names and GTFS ids, reachable by keyboard, turns it into one
        keystroke and three characters.
      </p>
      <div id="ds-search-demo" class="mt-3 border border-base-300 p-4">
        <div class="max-w-md">
          <div class="flex h-10 items-center gap-2 border border-control-border px-3 focus-within:border-primary">
            <span class="hero-magnifying-glass size-4 text-base-content/60" aria-hidden="true"></span>
            <input
              type="search"
              placeholder="Search stops, routes, ids"
              class="w-full bg-transparent text-sm focus:outline-none"
              aria-label="Search stops, routes, and ids"
            />
            <kbd class="border border-base-300 px-1.5 font-mono text-xs text-base-content/60">⌘K</kbd>
          </div>
          <ul class="mt-1 divide-y divide-base-300 border border-base-300 text-sm">
            <li class="bg-base-200 px-3 py-1 text-xs font-semibold text-base-content/60">Stops</li>
            <li class="flex items-center justify-between px-3 py-2">
              <span>Harbor Terminal</span>
              <span class="font-mono text-xs text-base-content/60">stop_4211</span>
            </li>
            <li class="flex items-center justify-between px-3 py-2">
              <span>Harborview &amp; 3rd</span>
              <span class="font-mono text-xs text-base-content/60">stop_0388</span>
            </li>
            <li class="bg-base-200 px-3 py-1 text-xs font-semibold text-base-content/60">Routes</li>
            <li class="flex items-center justify-between px-3 py-2">
              <span>231 · Harbor Shuttle</span>
              <span class="font-mono text-xs text-base-content/60">route_231</span>
            </li>
          </ul>
        </div>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          results grouped by kind · the GTFS id matches too, in mono · Enter opens the first result
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Navigate by task, not by file</h2>
      <p class="mt-2 text-base-content/70">
        Name destinations by what users do — Stations, Routes, Import feed, Validate,
        Publish — never by GTFS internals: a screen per
        <code class="font-mono text-sm">stop_times</code>
        or <code class="font-mono text-sm">calendars</code>
        is the spec leaking into the sitemap. The test: a new planner predicts what is
        behind every label without knowing GTFS.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Terminology</h2>
      <p class="mt-1 text-sm text-base-content/60">
        GTFS names things riders never say, and names some things twice. Pick one term
        per concept and keep it. Raw field names appear only as mono metadata — the
        Typography page already sets ids that way — never as labels.
      </p>
      <div class="mt-3 overflow-x-auto">
        <table id="ds-terminology-table" class="w-full text-sm">
          <thead>
            <tr class="border-y border-base-300 text-left text-xs font-semibold text-base-content/60">
              <th class="py-2 pr-4 font-semibold">Concept</th>
              <th class="py-2 pr-4 font-semibold">Use</th>
              <th class="py-2 pr-4 font-semibold">Not</th>
              <th class="py-2 font-semibold">GTFS</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Parent location</td>
              <td class="py-2 pr-4 font-medium">Station</td>
              <td class="py-2 pr-4 text-base-content/70">Hub, terminal</td>
              <td class="py-2 font-mono text-xs text-base-content/70">location_type=1</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Boarding point inside a station</td>
              <td class="py-2 pr-4 font-medium">Platform</td>
              <td class="py-2 pr-4 text-base-content/70">Stop, quay, bay</td>
              <td class="py-2 font-mono text-xs text-base-content/70">location_type=0, parented</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Standalone boarding point</td>
              <td class="py-2 pr-4 font-medium">Stop</td>
              <td class="py-2 pr-4 text-base-content/70">Station</td>
              <td class="py-2 font-mono text-xs text-base-content/70">location_type=0</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Working copy of the data</td>
              <td class="py-2 pr-4 font-medium">Version</td>
              <td class="py-2 pr-4 text-base-content/70">Dataset, snapshot</td>
              <td class="py-2 font-mono text-xs text-base-content/70">—</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Imported or exported artifact</td>
              <td class="py-2 pr-4 font-medium">Feed</td>
              <td class="py-2 pr-4 text-base-content/70">File, archive</td>
              <td class="py-2 font-mono text-xs text-base-content/70">the zip itself</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">A service pattern riders board</td>
              <td class="py-2 pr-4 font-medium">Route</td>
              <td class="py-2 pr-4 text-base-content/70">Line, service</td>
              <td class="py-2 font-mono text-xs text-base-content/70">routes.txt</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">One vehicle run</td>
              <td class="py-2 pr-4 font-medium">Trip</td>
              <td class="py-2 pr-4 text-base-content/70">Journey, run</td>
              <td class="py-2 font-mono text-xs text-base-content/70">trips.txt</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Walking link inside a station</td>
              <td class="py-2 pr-4 font-medium">Pathway</td>
              <td class="py-2 pr-4 text-base-content/70">Connection, link</td>
              <td class="py-2 font-mono text-xs text-base-content/70">pathways.txt</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 class="mt-8 text-lg font-semibold">Formatting standards</h2>
      <p class="mt-1 text-sm text-base-content/60">
        One format per data type, chosen once. The list demo already writes ISO dates;
        this table makes the rest explicit.
      </p>
      <div class="mt-3 overflow-x-auto">
        <table id="ds-formats-table" class="w-full text-sm">
          <thead>
            <tr class="border-y border-base-300 text-left text-xs font-semibold text-base-content/60">
              <th class="py-2 pr-4 font-semibold">Data</th>
              <th class="py-2 pr-4 font-semibold">Format</th>
              <th class="py-2 font-semibold">Example</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Date</td>
              <td class="py-2 pr-4">ISO 8601</td>
              <td class="py-2 font-mono text-xs">2026-07-15</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Time</td>
              <td class="py-2 pr-4">24-hour HH:MM, agency timezone</td>
              <td class="py-2 font-mono text-xs">14:05</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Time past midnight</td>
              <td class="py-2 pr-4">Wall clock plus next-day marker — see Transit patterns</td>
              <td class="py-2 font-mono text-xs">01:14 +1</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Duration</td>
              <td class="py-2 pr-4">Largest natural unit</td>
              <td class="py-2 font-mono text-xs">45 s · 3 min</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Coordinates</td>
              <td class="py-2 pr-4">5 decimals (~1 m), mono</td>
              <td class="py-2 font-mono text-xs">47.60621</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Counts in columns</td>
              <td class="py-2 pr-4">Tabular numerals, right-aligned</td>
              <td class="py-2 font-mono text-xs tabular-nums">1,204</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 text-base-content/70">Ids and codes</td>
              <td class="py-2 pr-4">Mono, verbatim, never as a label</td>
              <td class="py-2 font-mono text-xs">stop_4211</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 class="mt-8 text-lg font-semibold">Microcopy patterns</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Three templates cover most of what screens write. Each pair below is
        instead-of / write.
      </p>
      <div id="ds-microcopy-demo" class="mt-3 divide-y divide-base-300 border-y border-base-300">
        <div class="grid gap-4 py-3 sm:grid-cols-2">
          <div>
            <p class="mb-1 text-xs font-semibold text-base-content/60">Instead of</p>
            <p class="text-sm text-base-content/70">
              Silence — today a failed address search empties the dropdown and logs <span class="font-mono text-xs">:network_error</span>; the user gets nothing.
            </p>
          </div>
          <div>
            <p class="mb-1 text-xs font-semibold text-base-content/60">Write</p>
            <p class="text-sm">
              Address search is unavailable. Check the connection and try again.
              <span class="font-mono text-xs text-base-content/60">ref: network_error</span>
            </p>
          </div>
        </div>
        <div class="grid gap-4 py-3 sm:grid-cols-2">
          <div>
            <p class="mb-1 text-xs font-semibold text-base-content/60">Instead of</p>
            <p class="text-sm text-base-content/70">No data.</p>
          </div>
          <div>
            <p class="mb-1 text-xs font-semibold text-base-content/60">Write</p>
            <p class="text-sm">No stops yet. Stops appear after you import a feed.</p>
          </div>
        </div>
        <div class="grid gap-4 py-3 sm:grid-cols-2">
          <div>
            <p class="mb-1 text-xs font-semibold text-base-content/60">Instead of</p>
            <p class="text-sm text-base-content/70">Are you sure? — Yes / No</p>
          </div>
          <div>
            <p class="mb-1 text-xs font-semibold text-base-content/60">Write</p>
            <p class="text-sm">
              Delete route 42? This removes 214 trips. — Cancel / Delete route
            </p>
          </div>
        </div>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          error: what failed + how to recover, code as secondary detail · empty: what belongs here + why · confirm: object named, verb + object repeated on the button
        </code>
      </p>
    </section>
    """
  end

  @doc """
  Display conventions for the problems GTFS data actually poses: feed colors,
  the service-day clock, tri-state accessibility, and sequence.
  """
  def transit(assigns) do
    ~H"""
    <section id="ds-page-transit" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Transit patterns</h1>
      <p class="mt-2 text-base-content/70">
        Generic design systems stop where transit data starts: colors arrive from the
        feed, the clock passes 24:00, accessibility has three values, and sequence is
        the data. These are proposed conventions for those problems, shown as
        plain-HTML mockups.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Feed colors, guarded</h2>
      <p class="mt-1 text-sm text-base-content/60">
        <code class="font-mono text-sm">route_color</code>
        and <code class="font-mono text-sm">route_text_color</code>
        are feed data, and real feeds ship illegible pairs. The Badges page warns
        about this; a warning is not a guard. Compute the pair's contrast at render
        and, below 4.5:1, keep the background — the identity lives there — and replace
        the text with black or white, whichever wins.
      </p>
      <div
        id="ds-route-guard-demo"
        class="mt-3 flex flex-wrap items-center gap-6 border border-base-300 p-4"
      >
        <div class="flex flex-col items-center gap-2">
          <span
            class="inline-flex items-center justify-center rounded px-2 py-0.5 text-xs font-medium"
            style="background-color: #D32F2F; color: #FFFFFF"
          >
            42
          </span>
          <code class="font-mono text-xs text-base-content/70">as fed · 5.0:1</code>
        </div>
        <div class="flex flex-col items-center gap-2">
          <span
            class="inline-flex items-center justify-center rounded px-2 py-0.5 text-xs font-medium"
            style="background-color: #FFDD00; color: #FFFFFF"
          >
            L1
          </span>
          <code class="font-mono text-xs text-base-content/70">as fed · 1.3:1</code>
        </div>
        <div class="flex flex-col items-center gap-2">
          <span
            class="inline-flex items-center justify-center rounded px-2 py-0.5 text-xs font-medium"
            style="background-color: #FFDD00; color: #000000"
          >
            L1
          </span>
          <code class="font-mono text-xs text-base-content/70">guarded · 15.6:1</code>
        </div>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          the guard changes text only, never the feed's background · the badge still never distinguishes routes alone — keep the name beside it
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Stop sequence</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Order is the data: a table of stops hides it, a line shows it. The rail
        carries the route color, filled dots are termini, open dots are stops, and
        the stop name is the link. Times sit right, in mono.
      </p>
      <div id="ds-stop-sequence-demo" class="mt-3 border border-base-300 p-4">
        <ol aria-label="Stops on route A, outbound" class="max-w-md">
          <li class="relative pb-6 pl-6">
            <span class="absolute bottom-0 left-[5px] top-1.5 w-0.5" style="background-color: #1976D2">
            </span>
            <span
              class="absolute left-0 top-1.5 size-3 rounded-full"
              style="background-color: #1976D2"
            >
            </span>
            <div class="flex items-baseline justify-between gap-4">
              <div>
                <a href="#" class="font-medium text-primary hover:underline">Harbor Terminal</a>
                <p class="text-sm text-base-content/70">Terminus · Bay 3</p>
              </div>
              <span class="font-mono text-sm tabular-nums">06:12</span>
            </div>
          </li>
          <li class="relative pb-6 pl-6">
            <span class="absolute bottom-0 left-[5px] top-0 w-0.5" style="background-color: #1976D2">
            </span>
            <span
              class="absolute left-0 top-1.5 size-3 rounded-full border-2 bg-base-100"
              style="border-color: #1976D2"
            >
            </span>
            <div class="flex items-baseline justify-between gap-4">
              <div>
                <a href="#" class="font-medium text-primary hover:underline">Fifth &amp; Main</a>
                <p class="flex items-center gap-1.5 text-sm text-base-content/70">
                  Transfer:
                  <span
                    class="inline-flex items-center justify-center rounded px-1.5 text-xs font-medium"
                    style="background-color: #D32F2F; color: #FFFFFF"
                  >
                    42
                  </span>
                  <span
                    class="inline-flex items-center justify-center rounded px-1.5 text-xs font-medium"
                    style="background-color: #43A047; color: #000000"
                  >
                    7X
                  </span>
                </p>
              </div>
              <span class="font-mono text-sm tabular-nums">06:19</span>
            </div>
          </li>
          <li class="relative pb-6 pl-6">
            <span class="absolute bottom-0 left-[5px] top-0 w-0.5" style="background-color: #1976D2">
            </span>
            <span
              class="absolute left-0 top-1.5 size-3 rounded-full border-2 bg-base-100"
              style="border-color: #1976D2"
            >
            </span>
            <div class="flex items-baseline justify-between gap-4">
              <div>
                <a href="#" class="font-medium text-primary hover:underline">City Center</a>
                <p class="text-sm text-base-content/70">Step-free via elevator</p>
              </div>
              <span class="font-mono text-sm tabular-nums">06:24</span>
            </div>
          </li>
          <li class="relative pl-6">
            <span class="absolute left-[5px] top-0 h-1.5 w-0.5" style="background-color: #1976D2">
            </span>
            <span
              class="absolute left-0 top-1.5 size-3 rounded-full"
              style="background-color: #1976D2"
            >
            </span>
            <div class="flex items-baseline justify-between gap-4">
              <a href="#" class="font-medium text-primary hover:underline">Airport North</a>
              <span class="font-mono text-sm tabular-nums">06:40</span>
            </div>
          </li>
        </ol>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          an ol, not divs — sequence is semantic · transfers name the route beside its badge color
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">The clock past midnight</h2>
      <p class="mt-1 text-sm text-base-content/60">
        GTFS times run past 24:00:00 so an overnight trip stays one ordered service
        day: 25:14:00 is 01:14 the next calendar day. Display the wall clock with an
        explicit next-day marker, and never re-sort by it — service-day order is the
        truth, and a naive sort puts 01:14 before 23:55 on the same trip.
      </p>
      <div id="ds-service-day-demo" class="mt-3 overflow-x-auto border border-base-300 p-4">
        <table class="w-full max-w-md text-sm">
          <thead>
            <tr class="border-b border-base-300 text-left text-xs font-semibold text-base-content/60">
              <th class="py-2 pr-4 font-semibold">Stop</th>
              <th class="py-2 pr-4 text-right font-semibold">Stored</th>
              <th class="py-2 text-right font-semibold">Displayed</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr>
              <td class="py-2 pr-4">City Center</td>
              <td class="py-2 pr-4 text-right font-mono text-xs tabular-nums text-base-content/70">
                23:55:00
              </td>
              <td class="py-2 text-right font-mono tabular-nums">23:55</td>
            </tr>
            <tr>
              <td class="py-2 pr-4">Fifth &amp; Main</td>
              <td class="py-2 pr-4 text-right font-mono text-xs tabular-nums text-base-content/70">
                24:08:00
              </td>
              <td class="py-2 text-right font-mono tabular-nums">
                00:08 <span class="text-xs font-medium text-base-content/60">+1</span>
              </td>
            </tr>
            <tr>
              <td class="py-2 pr-4">Harbor Terminal</td>
              <td class="py-2 pr-4 text-right font-mono text-xs tabular-nums text-base-content/70">
                25:14:00
              </td>
              <td class="py-2 text-right font-mono tabular-nums">
                01:14 <span class="text-xs font-medium text-base-content/60">+1</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          +1 means next calendar day, same service day · the marker never drops, even in exports and tooltips
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Days of service</h2>
      <p class="mt-1 text-sm text-base-content/60">
        calendar.txt is seven booleans plus dated exceptions. Fill is the signal —
        filled chips run, outlined chips do not — so the pattern survives grayscale.
        Exceptions are always textual, with the symbol and the word.
      </p>
      <div id="ds-calendar-demo" class="mt-3 space-y-4 border border-base-300 p-4">
        <div class="flex items-center gap-4">
          <span class="w-24 text-sm text-base-content/70">Weekday</span>
          <span class="sr-only">Runs Monday through Friday</span>
          <span class="flex gap-1" aria-hidden="true">
            <span class="inline-flex size-7 items-center justify-center bg-neutral text-xs font-semibold text-neutral-content">
              M
            </span>
            <span class="inline-flex size-7 items-center justify-center bg-neutral text-xs font-semibold text-neutral-content">
              T
            </span>
            <span class="inline-flex size-7 items-center justify-center bg-neutral text-xs font-semibold text-neutral-content">
              W
            </span>
            <span class="inline-flex size-7 items-center justify-center bg-neutral text-xs font-semibold text-neutral-content">
              T
            </span>
            <span class="inline-flex size-7 items-center justify-center bg-neutral text-xs font-semibold text-neutral-content">
              F
            </span>
            <span class="inline-flex size-7 items-center justify-center border border-base-300 text-xs font-semibold text-base-content/60">
              S
            </span>
            <span class="inline-flex size-7 items-center justify-center border border-base-300 text-xs font-semibold text-base-content/60">
              S
            </span>
          </span>
        </div>
        <div class="flex items-center gap-4">
          <span class="w-24 text-sm text-base-content/70">Weekend</span>
          <span class="sr-only">Runs Saturday and Sunday</span>
          <span class="flex gap-1" aria-hidden="true">
            <span class="inline-flex size-7 items-center justify-center border border-base-300 text-xs font-semibold text-base-content/60">
              M
            </span>
            <span class="inline-flex size-7 items-center justify-center border border-base-300 text-xs font-semibold text-base-content/60">
              T
            </span>
            <span class="inline-flex size-7 items-center justify-center border border-base-300 text-xs font-semibold text-base-content/60">
              W
            </span>
            <span class="inline-flex size-7 items-center justify-center border border-base-300 text-xs font-semibold text-base-content/60">
              T
            </span>
            <span class="inline-flex size-7 items-center justify-center border border-base-300 text-xs font-semibold text-base-content/60">
              F
            </span>
            <span class="inline-flex size-7 items-center justify-center bg-neutral text-xs font-semibold text-neutral-content">
              S
            </span>
            <span class="inline-flex size-7 items-center justify-center bg-neutral text-xs font-semibold text-neutral-content">
              S
            </span>
          </span>
        </div>
        <p class="text-sm">
          <span class="font-medium text-success">+ Added Jul 4</span>
          <span class="text-base-content/40">·</span>
          <span class="font-medium text-error">− Removed Dec 25</span>
        </p>
      </div>

      <h2 class="mt-8 text-lg font-semibold">Accessibility is three-valued</h2>
      <p class="mt-1 text-sm text-base-content/60">
        <code class="font-mono text-sm">wheelchair_boarding</code>
        is 1 accessible, 2 not accessible, and 0 or empty for no data. Collapsing "no
        data" into "not accessible" misreports the network; collapsing it the other
        way is worse. Three values get three renders, and the empty value inherits
        from the parent station before it defaults.
      </p>
      <div id="ds-tri-state-demo" class="mt-3 flex flex-wrap gap-2 border border-base-300 p-4">
        <span class="inline-flex items-center gap-1.5 border border-base-300 px-2 py-0.5 text-sm">
          <span class="size-1.5 rounded-full bg-success" aria-hidden="true"></span>
          <span class="font-medium text-success">Accessible</span>
        </span>
        <span class="inline-flex items-center gap-1.5 border border-base-300 px-2 py-0.5 text-sm">
          <span class="size-1.5 rounded-full bg-error" aria-hidden="true"></span>
          <span class="font-medium text-error">Not accessible</span>
        </span>
        <span class="inline-flex items-center gap-1.5 border border-dashed border-base-300 px-2 py-0.5 text-sm">
          <span class="font-medium text-base-content/60">No data</span>
        </span>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          "No data", not "Unknown" — it names the fix · the dashed border is the third shape, so the state survives grayscale
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Pathways</h2>
      <p class="mt-1 text-sm text-base-content/60">
        A pathway is a mode, a direction, and a traversal time. The time is the
        comparison number, so it is mono; direction is text; stairs carry their step
        count because "45 s" hides what the 45 seconds are made of.
      </p>
      <div id="ds-pathway-demo" class="mt-3 flex flex-wrap gap-2 border border-base-300 p-4">
        <span class="inline-flex items-center gap-2 border border-base-300 px-2.5 py-1 text-sm">
          <span class="font-medium">Stairs ↑</span>
          <span class="text-base-content/60">32 steps</span>
          <span class="font-mono tabular-nums text-base-content/70">45 s</span>
        </span>
        <span class="inline-flex items-center gap-2 border border-base-300 px-2.5 py-1 text-sm">
          <span class="font-medium">Escalator ↑</span>
          <span class="font-mono tabular-nums text-base-content/70">30 s</span>
        </span>
        <span class="inline-flex items-center gap-2 border border-base-300 px-2.5 py-1 text-sm">
          <%!-- &#xFE0E; forces text presentation: ↕ and ↔ otherwise fall back to
                Apple Color Emoji from the font stack and render as emoji glyphs. --%>
          <span class="font-medium">Elevator ↕&#xFE0E;</span>
          <span class="font-mono tabular-nums text-base-content/70">60 s</span>
          <span class="inline-flex items-center gap-1">
            <span class="size-1.5 rounded-full bg-success" aria-hidden="true"></span>
            <span class="font-medium text-success">Accessible</span>
          </span>
        </span>
        <span class="inline-flex items-center gap-2 border border-base-300 px-2.5 py-1 text-sm">
          <span class="font-medium">Walkway ↔&#xFE0E;</span>
          <span class="text-base-content/60">120 m</span>
          <span class="font-mono tabular-nums text-base-content/70">95 s</span>
        </span>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          ↑ ↓ ↕&#xFE0E; ↔&#xFE0E; from is_bidirectional and the level pair · in a pathways table these become rows with the time column right-aligned
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Severity counts</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Validation and reachability both summarize error, warning, and info counts,
        each with its own markup today. One counts strip: the chips are the filters,
        counts in tabular numerals, pressed state via <code class="font-mono text-sm">aria-pressed</code>.
      </p>
      <div id="ds-severity-demo" class="mt-3 flex flex-wrap gap-2 border border-base-300 p-4">
        <button
          type="button"
          aria-pressed="true"
          class="inline-flex h-8 items-center gap-1.5 border border-base-content/40 px-2.5 text-sm"
        >
          <span class="size-1.5 rounded-full bg-error" aria-hidden="true"></span>
          <span class="font-medium text-error tabular-nums">3 errors</span>
        </button>
        <button
          type="button"
          aria-pressed="false"
          class="inline-flex h-8 items-center gap-1.5 border border-control-border px-2.5 text-sm"
        >
          <span class="size-1.5 rounded-full bg-warning" aria-hidden="true"></span>
          <span class="font-medium text-warning tabular-nums">12 warnings</span>
        </button>
        <button
          type="button"
          aria-pressed="false"
          class="inline-flex h-8 items-center gap-1.5 border border-control-border px-2.5 text-sm"
        >
          <span class="size-1.5 rounded-full bg-info" aria-hidden="true"></span>
          <span class="font-medium text-info tabular-nums">5 info</span>
        </button>
      </div>
      <p class="mt-3">
        <code class="ds-code-caption font-mono text-xs text-base-content/70">
          the pressed chip carries the heavier border · zero-count chips render disabled, not hidden, so the strip never shifts
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Further patterns</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          Headway bands: frequencies.txt as "every 10 min" spans across the service
          day, not exploded into trip rows.
        </li>
        <li>
          Transfer matrix: minimum transfer time between platform pairs as a mono
          seconds grid.
        </li>
        <li>
          Map conventions: the route's map color is its badge color; selection is
          weight and halo, never a hue shift.
        </li>
        <li>
          Fares: currency-aware mono amounts, fare rules written as plain sentences.
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  Experimental components: upload, pressed filters, and segmented controls.
  These are real components with deterministic demo state, marked experimental
  with ownership and maturity labels.
  """
  def experimental(assigns) do
    ~H"""
    <section id="ds-page-experimental" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Experimental</h1>
      <p class="mt-2 text-base-content/70">
        Components that are implemented and tested but not yet adopted in production.
        Each has a deterministic demo, clear ownership, and a path to graduation.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Upload field</h2>
      <p class="mt-1 text-sm text-base-content/60">
        A file upload field with Phoenix LiveView's UploadConfig. Presents a labeled
        native file input, constraints, entry progress, cancellation, and rejection.
        Does not consume or persist files.
      </p>
      <div class="mt-2 text-xs text-base-content/50">
        <span class="font-semibold">Maturity:</span>
        Experimental · <span class="font-semibold">Owner:</span>
        Packages 14/16 (import and diagram upload) · <span class="font-semibold">Graduation:</span>
        Package 19
      </div>
      <div id="ds-upload-demo" class="mt-3 border border-base-300 p-4">
        <.upload_field
          id="feed-upload"
          upload={@uploads.feed}
          label="GTFS feed"
          help="ZIP file, max 50MB"
          cancel_event="cancel_upload"
        />
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.upload_field id="feed-upload" upload={@uploads.feed} label="GTFS feed" help="ZIP file, max 50MB" cancel_event="cancel_upload" /&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Pressed filter</h2>
      <p class="mt-1 text-sm text-base-content/60">
        A toggle button with aria-pressed state for filtering data. Server-owned
        pressed state, pending/disabled copy, configured event/value/target.
      </p>
      <div class="mt-2 text-xs text-base-content/50">
        <span class="font-semibold">Maturity:</span>
        Experimental · <span class="font-semibold">Owner:</span>
        Packages 14–17 (selection adoption) · <span class="font-semibold">Graduation:</span>
        Package 19
      </div>
      <div id="ds-pressed-filter-demo" class="mt-3 flex flex-wrap gap-2 border border-base-300 p-4">
        <.pressed_filter
          id="filter-active"
          pressed={@filter_active}
          event="toggle_filter"
          value="active"
        >
          Active
        </.pressed_filter>
        <.pressed_filter
          id="filter-inactive"
          pressed={@filter_inactive}
          event="toggle_filter"
          value="inactive"
        >
          Inactive
        </.pressed_filter>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.pressed_filter id="filter-active" pressed={@filter_active} event="toggle_filter" value="active"&gt;Active&lt;/.pressed_filter&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Segmented control</h2>
      <p class="mt-1 text-sm text-base-content/60">
        A fieldset with visible legend and native same-name radio group. Server-owned
        selected value, configured event/target, disabled explanation.
      </p>
      <div class="mt-2 text-xs text-base-content/50">
        <span class="font-semibold">Maturity:</span>
        Experimental · <span class="font-semibold">Owner:</span>
        Packages 14–17 (selection adoption) · <span class="font-semibold">Graduation:</span>
        Package 19
      </div>
      <div id="ds-segmented-control-demo" class="mt-3 border border-base-300 p-4">
        <.segmented_control
          id="view-mode"
          name="view_mode"
          legend="View mode"
          options={[{"List", "list"}, {"Map", "map"}, {"Table", "table"}]}
          value={@view_mode}
          event="change_view"
        />
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.segmented_control id="view-mode" name="view_mode" legend="View mode" options={[{"List", "list"}, {"Map", "map"}]} value={@view_mode} event="change_view" /&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Semantic decision matrix</h2>
      <p class="mt-1 text-sm text-base-content/60">
        When to use each selection primitive. Navigation uses links with aria-current,
        pressed filters use buttons with aria-pressed, and single choice uses a
        fieldset with native radios.
      </p>
      <div class="mt-3 overflow-x-auto">
        <table id="ds-selection-matrix" class="w-full text-sm">
          <thead>
            <tr class="border-y border-base-300 text-left text-xs font-semibold text-base-content/60">
              <th class="py-2 pr-4 font-semibold">Pattern</th>
              <th class="py-2 pr-4 font-semibold">Component</th>
              <th class="py-2 pr-4 font-semibold">Semantics</th>
              <th class="py-2 font-semibold">Use when</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr>
              <td class="py-2 pr-4 font-medium">Navigation</td>
              <td class="py-2 pr-4">Link</td>
              <td class="py-2 pr-4">aria-current</td>
              <td class="py-2">Moving between pages or records</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Filter toggle</td>
              <td class="py-2 pr-4">pressed_filter</td>
              <td class="py-2 pr-4">aria-pressed</td>
              <td class="py-2">Toggling a filter on/off</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Single choice</td>
              <td class="py-2 pr-4">segmented_control</td>
              <td class="py-2 pr-4">fieldset + radio</td>
              <td class="py-2">Choosing one option from a set</td>
            </tr>
            <tr>
              <td class="py-2 pr-4 font-medium">Disclosure</td>
              <td class="py-2 pr-4">details/summary</td>
              <td class="py-2 pr-4">native disclosure</td>
              <td class="py-2">Showing/hiding content</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2 class="mt-8 text-lg font-semibold">Non-goals</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          These components do not consume or persist files. Upload adoption in import
          and diagram pages is owned by Packages 14 and 16.
        </li>
        <li>
          These components do not migrate ImportLive, station-diagram upload, or
          change-history tabs. Those migrations are owned by Packages 14–17.
        </li>
        <li>
          These components are not a generic selection abstraction. Navigation, pressed
          filters, and single choice remain distinct contracts with distinct semantics.
        </li>
      </ul>
    </section>
    """
  end
end

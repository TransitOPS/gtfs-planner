defmodule GtfsPlannerWeb.Design.ComponentPages do
  @moduledoc ~S"""
  Components pages for the `/design` section: buttons, inputs & forms, badges,
  tables & lists, feedback, navigation, and overlays.

  Every Tailwind/daisyUI class here is a literal string. Tailwind v4 scans source
  text, so an interpolated class name (`"btn-#{variant}"`) compiles but is silently
  missing from the bundle. See the precedent comment at
  `lib/gtfs_planner_web/components/navigation.ex:102`.

  The variant × size grid is written as twelve explicit `<.button>` calls rather
  than a comprehension: `attr :variant` and `attr :size` are validated at compile
  time only for literal values, and the calls double as copyable documentation.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents

  @doc """
  Every `<.button>` variant × size combination, plus the disabled and with-icon forms.
  """
  def buttons(assigns) do
    ~H"""
    <section id="ds-page-buttons" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Buttons</h1>
      <p class="mt-2 text-base-content/70">
        One component, four variants, three sizes. The variant names are semantic —
        pick by the role the action plays, not by the color you want. Every button
        below is the real <code class="font-mono text-sm">core_components.ex</code>
        component; the caption under each row is the call that produces it.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Variants and sizes</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Labels here name the combination so the mapping is visible. Real buttons use
        verb + noun.
      </p>

      <div class="mt-3 divide-y divide-base-300 border-y border-base-300">
        <div class="py-4">
          <div class="flex flex-wrap items-center gap-3">
            <.button variant="primary" size="sm">primary / sm</.button>
            <.button variant="primary" size="md">primary / md</.button>
            <.button variant="primary" size="lg">primary / lg</.button>
          </div>
          <p class="mt-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              &lt;.button variant="primary"&gt; → btn-primary · the one affirmative action in a view
            </code>
          </p>
        </div>

        <div class="py-4">
          <div class="flex flex-wrap items-center gap-3">
            <.button variant="secondary" size="sm">secondary / sm</.button>
            <.button variant="secondary" size="md">secondary / md</.button>
            <.button variant="secondary" size="lg">secondary / lg</.button>
          </div>
          <p class="mt-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              &lt;.button variant="secondary"&gt; → btn-outline · a real alternative to the primary
            </code>
          </p>
        </div>

        <div class="py-4">
          <div class="flex flex-wrap items-center gap-3">
            <.button variant="quiet" size="sm">quiet / sm</.button>
            <.button variant="quiet" size="md">quiet / md</.button>
            <.button variant="quiet" size="lg">quiet / lg</.button>
          </div>
          <p class="mt-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              &lt;.button variant="quiet"&gt; → btn-ghost · low-emphasis: Cancel, toolbar actions
            </code>
          </p>
        </div>

        <div class="py-4">
          <div class="flex flex-wrap items-center gap-3">
            <.button variant="danger" size="sm">danger / sm</.button>
            <.button variant="danger" size="md">danger / md</.button>
            <.button variant="danger" size="lg">danger / lg</.button>
          </div>
          <p class="mt-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              &lt;.button variant="danger"&gt; → btn-error · destructive only, never merely urgent
            </code>
          </p>
        </div>
      </div>

      <p class="mt-3 text-sm text-base-content/60">
        <code phx-no-curly-interpolation class="ds-code-caption font-mono text-xs">
          size="sm" → btn-sm · size="md" → no class (the default) · size="lg" → btn-lg
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Disabled</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Passed through to the underlying element. A disabled control must still explain
        why it is unavailable — put the reason next to it, not in a tooltip alone.
      </p>
      <div class="mt-3 border border-base-300 p-4">
        <.button variant="primary" size="md" disabled>Save changes</.button>
        <p class="mt-3">
          <code
            phx-no-curly-interpolation
            class="ds-code-caption font-mono text-xs text-base-content/70"
          >
            &lt;.button variant="primary" disabled&gt;Save changes&lt;/.button&gt;
          </code>
        </p>
      </div>

      <h2 class="mt-8 text-lg font-semibold">With icon</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Text first. The icon reinforces the label; it does not replace it.
      </p>
      <div class="mt-3 border border-base-300 p-4">
        <.button variant="secondary" size="md">
          <.icon name="hero-arrow-path" class="size-4" /> Refresh data
        </.button>
        <p class="mt-3">
          <code
            phx-no-curly-interpolation
            class="ds-code-caption font-mono text-xs text-base-content/70"
          >
            &lt;.button variant="secondary"&gt;&lt;.icon name="hero-arrow-path" class="size-4" /&gt; Refresh data&lt;/.button&gt;
          </code>
        </p>
      </div>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>A label is a promise. Write verb + noun in sentence case: Save changes, Add stop.</li>
        <li>One primary per view. Two primaries mean the hierarchy has not been decided.</li>
        <li>Destructive actions repeat verb + object: Delete route, not Confirm.</li>
        <li>
          Passing <code class="font-mono text-sm">navigate</code>, <code class="font-mono text-sm">patch</code>, or
          <code class="font-mono text-sm">href</code>
          renders an anchor instead of a button — use it for navigation, not for actions.
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  The `<.input>` clauses, `<.checkbox_group>`, and a `<.simple_form>` with an error example.

  The error example passes `errors={["can't be blank"]}` explicitly. Field-derived
  errors cannot be shown here: `input/1` gates them behind
  `Phoenix.Component.used_input?/1`, which is false for every field on a form the
  user has not touched, so a changeset with errors would still render clean. It also
  needs its own `id` — it reuses the `:name` field, and two inputs from one field
  would otherwise emit duplicate DOM ids.
  """
  def inputs(assigns) do
    ~H"""
    <section id="ds-page-inputs" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Inputs &amp; Forms</h1>
      <p class="mt-2 text-base-content/70">
        <code class="font-mono text-sm">&lt;.input&gt;</code>
        is the only way to render a form field in this app. It owns the label, the help
        text, the error, and the daisyUI classes, so a hand-rolled
        <code class="font-mono text-sm">&lt;input&gt;</code>
        drifts from every other form. Pass it a <code class="font-mono text-sm">field</code>
        from a form and a <code class="font-mono text-sm">type</code>.
      </p>

      <h2 class="mt-8 text-lg font-semibold">The clauses</h2>
      <p class="mt-1 text-sm text-base-content/60">
        One live form, one column, labels above fields. The form below submits to a
        no-op handler — it is a demo, not a real record.
      </p>

      <div class="mt-3 border border-base-300 p-4">
        <.simple_form
          for={@demo_form}
          id="ds-inputs-demo-form"
          phx-submit="demo_form_submit"
          class="max-w-xl"
        >
          <.input
            field={@demo_form[:name]}
            type="text"
            label="Name"
            help="Help text sits under the field and is wired to it with aria-describedby."
          />
          <.input
            field={@demo_form[:kind]}
            type="select"
            label="Kind"
            prompt="Choose a kind"
            options={[Bus: "bus", Rail: "rail"]}
            help="A prompt gives the empty value a name instead of a blank first row."
          />
          <.input field={@demo_form[:notes]} type="textarea" label="Notes" />
          <.input field={@demo_form[:active]} type="checkbox" label="Active" />
          <:actions>
            <.button variant="primary">Save changes</.button>
          </:actions>
        </.simple_form>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.input field={@form[:name]} type="text" label="Name" help="…" /&gt; · types: text, select, textarea, checkbox
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Error state</h2>
      <p class="mt-1 text-sm text-base-content/60">
        The field turns <code class="font-mono text-sm">input-error</code>
        and the message renders below it. Say what to do, not just what broke.
      </p>
      <div class="mt-3 max-w-xl border border-base-300 p-4">
        <.input
          field={@demo_form[:name]}
          type="text"
          label="Name (error state)"
          id="demo_name_error"
          errors={["can't be blank"]}
        />
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.input … id="demo_name_error" errors={["can't be blank"]} /&gt; · explicit errors always render
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Checkbox group</h2>
      <p class="mt-1 text-sm text-base-content/60">
        A fieldset with a legend for multi-select options. It takes a bare
        <code class="font-mono text-sm">name</code>
        and a selected list, not a form field.
      </p>
      <div class="mt-3 max-w-xl border border-base-300 p-4">
        <.checkbox_group
          name="demo[roles][]"
          label="Roles"
          options={[{"Admin", "admin"}, {"Editor", "editor"}]}
          selected={["admin"]}
          help="The name ends in [] so the params arrive as a list."
        />
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.checkbox_group name="demo[roles][]" label="Roles" options={[{"Admin", "admin"}]} selected={@roles} /&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>Every field is a cost. Remove it before you design it.</li>
        <li>One column, labels above fields. Placeholders are hints, never labels.</li>
        <li>
          Errors follow interaction: <code class="font-mono text-sm">&lt;.input&gt;</code>
          hides field errors until the input is used, so an untouched form is never
          pre-reddened. Pass <code class="font-mono text-sm">errors</code>
          explicitly only to document the state, as above.
        </li>
        <li>
          Mark optional fields rather than required ones, and never signal either with
          color alone.
        </li>
        <li>One primary action per form. Do not disable submit to hide errors.</li>
      </ul>
    </section>
    """
  end

  @doc """
  `<.route_badge>` across representative GTFS route color inputs.
  """
  def badges(assigns) do
    ~H"""
    <section id="ds-page-badges" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Badges</h1>
      <p class="mt-2 text-base-content/70">
        <code class="font-mono text-sm">&lt;.route_badge&gt;</code>
        renders a route's identity using the colors the GTFS feed supplies. It takes a
        map with <code class="font-mono text-sm">route_color</code>, <code class="font-mono text-sm">route_text_color</code>, and
        <code class="font-mono text-sm">route_short_name</code>
        — a route struct satisfies it directly.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Samples</h2>
      <dl class="mt-3 divide-y divide-base-300 border-y border-base-300">
        <div class="grid grid-cols-4 items-center gap-4 py-3">
          <dt>
            <.route_badge route={
              %{route_color: "D32F2F", route_text_color: "FFFFFF", route_short_name: "42"}
            } />
          </dt>
          <dd class="col-span-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              %{route_color: "D32F2F", route_text_color: "FFFFFF", route_short_name: "42"}
            </code>
          </dd>
        </div>

        <div class="grid grid-cols-4 items-center gap-4 py-3">
          <dt>
            <.route_badge route={
              %{route_color: "1976D2", route_text_color: "FFFFFF", route_short_name: "A"}
            } />
          </dt>
          <dd class="col-span-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              %{route_color: "1976D2", route_text_color: "FFFFFF", route_short_name: "A"}
            </code>
          </dd>
        </div>

        <div class="grid grid-cols-4 items-center gap-4 py-3">
          <dt>
            <.route_badge route={
              %{route_color: "43A047", route_text_color: "000000", route_short_name: "7X"}
            } />
          </dt>
          <dd class="col-span-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              %{route_color: "43A047", route_text_color: "000000", route_short_name: "7X"}
            </code>
          </dd>
        </div>

        <div class="grid grid-cols-4 items-center gap-4 py-3">
          <dt>
            <.route_badge route={
              %{route_color: "9E9E9E", route_text_color: "FFFFFF", route_short_name: nil}
            } />
          </dt>
          <dd class="col-span-3">
            <code
              phx-no-curly-interpolation
              class="ds-code-caption font-mono text-xs text-base-content/70"
            >
              %{route_color: "9E9E9E", route_text_color: "FFFFFF", route_short_name: nil} → falls back to an em dash
            </code>
          </dd>
        </div>
      </dl>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          Hex values carry no <code class="font-mono text-sm">#</code>
          — the component prepends it. That matches the GTFS spec, which stores
          <code class="font-mono text-sm">route_color</code>
          as six hex digits.
        </li>
        <li>
          A route with no short name renders an em dash, so the badge keeps its shape in
          a column instead of collapsing.
        </li>
        <li>
          The feed owns the color pair, so contrast is not guaranteed. Never let the
          badge be the only way to tell two routes apart — keep the route name in text
          beside it.
        </li>
      </ul>
    </section>
    """
  end

  @doc """
  `<.table>` over static sample routes, `<.list>` definition pairs, and a live
  `<.pagination>` demo.

  The pagination demo is driven by the `:pagination_page` assign and emits the
  `paginate` event that `DesignSystemLive` handles; `<.pagination>` hardcodes both the
  event name and `phx-value-page` (`core_components.ex:584-585`), so the demo range
  here (`total={45}`, `per_page={10}` → 5 pages) must stay in step with the clamp in
  `DesignSystemLive.handle_event("paginate", ...)`. A test pins the two together.
  """
  def tables(assigns) do
    ~H"""
    <section id="ds-page-tables" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Tables &amp; Lists</h1>
      <p class="mt-2 text-base-content/70">
        A table exists to find, compare, or act — not to store everything known about a
        record. <code class="font-mono text-sm">&lt;.table&gt;</code>
        takes an <code class="font-mono text-sm">id</code>, a list of <code class="font-mono text-sm">rows</code>, and one
        <code class="font-mono text-sm">&lt;:col&gt;</code>
        slot per column. Rows can be a plain list, as below, or a LiveView stream.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Table</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Sample routes. Ids are right-aligned with tabular numerals so digits line up;
        status carries text beside its color, never color alone.
      </p>

      <div class="mt-3 border border-base-300">
        <.table id="ds-demo-table" rows={sample_routes()}>
          <:col :let={route} label="ID">
            <div class="text-right tabular-nums">{route.id}</div>
          </:col>
          <:col :let={route} label="Name">{route.name}</:col>
          <:col :let={route} label="Status">
            <span class={["inline-flex items-center gap-1.5", status_class(route.status)]}>
              <span class="size-1.5 rounded-full bg-current" aria-hidden="true"></span>
              {route.status}
            </span>
          </:col>
          <:action :let={route}>
            <.button variant="quiet" size="sm" aria-label={"Edit route #{route.name}"}>
              Edit
            </.button>
          </:action>
        </.table>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.table id="routes" rows={@routes}&gt;&lt;:col :let={route} label="Name"&gt;{route.name}&lt;/:col&gt;&lt;/.table&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">List</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Definition pairs for one record. Use it where a table would have one row and
        the columns would read better stacked.
      </p>

      <div class="mt-3 border border-base-300 px-4">
        <.list>
          <:item title="Route">42 · Airport Express</:item>
          <:item title="Agency">Metro Transit</:item>
          <:item title="Last updated">2026-07-14</:item>
        </.list>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.list&gt;&lt;:item title="Route"&gt;{@route.name}&lt;/:item&gt;&lt;/.list&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Pagination</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Live: the buttons below move a real assign. Previous and Next disable at the
        ends of the range rather than disappearing, so the controls never shift position.
      </p>

      <div id="ds-pagination-demo" class="mt-3 border border-base-300 px-4">
        <.pagination page={@pagination_page} per_page={10} total={45} />
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.pagination page={@page} per_page={10} total={45} /&gt; · emits phx-click="paginate" with phx-value-page
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          Every column is a cost. If a column is never used to find, compare, or act,
          delete it or fold it into a subtitle under the primary identifier.
        </li>
        <li>Text left, numbers right. Tabular numerals keep digits in a column.</li>
        <li>
          Status is color plus text. Color alone fails for colorblind users and
          disappears in a screenshot.
        </li>
        <li>
          One or two inline actions per row; three or more belong in a menu. Repeat the
          row's identity in the action's <code class="font-mono text-sm">aria-label</code>
          so "Edit" is not the only thing announced.
        </li>
        <li>
          <code class="font-mono text-sm">&lt;.pagination&gt;</code>
          hardcodes <code class="font-mono text-sm">phx-click="paginate"</code>
          and counts in "routes". It needs a matching
          <code class="font-mono text-sm">handle_event("paginate", …)</code>
          that parses <code class="font-mono text-sm">phx-value-page</code>
          — it arrives as a string — and clamps it before assigning.
        </li>
        <li>
          <code class="font-mono text-sm">&lt;.table&gt;</code>
          renders each header as plain text from the <code class="font-mono text-sm">label</code>
          attribute, so a header cannot carry its own alignment. Right-aligned numeric
          columns keep their left-aligned header until the component grows the hook.
        </li>
      </ul>
    </section>
    """
  end

  @doc ~S"""
  `<.flash>` examples for both kinds, and the LiveView loading variants.

  Both flash examples pass inner-block content and an explicit `id`. The content is
  mandatory: `flash/1` renders only when a message resolves
  (`core_components.ex:55`), and `@flash` is empty on a styleguide page. The ids are
  mandatory too: the component defaults to `flash-#{kind}` (`:51`), which are the ids
  the layout's own `<.flash_group>` uses on this very page.

  `<.flash>` hardcodes `class="toast …"` on its root and daisyUI's `toast` is
  `position: fixed`, so no wrapper class can contain it. The page-scoped rule
  `#ds-flash-demo .toast { position: static; }` in `assets/css/app.css` returns the
  examples to normal flow; `toast-top`/`toast-end` both resolve their translate axis
  to `0`, so neutralizing `position` leaves no offset behind.
  """
  def feedback(assigns) do
    ~H"""
    <section id="ds-page-feedback" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Feedback</h1>
      <p class="mt-2 text-base-content/70">
        Every view has more than one state. This page shows the vocabulary the app uses
        to tell a user what just happened, or what is happening now.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Flash</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Two kinds: <code class="font-mono text-sm">:info</code>
        for a background outcome that succeeded, <code class="font-mono text-sm">:error</code>
        for one that failed. The layout renders the real flashes for you — a page never
        calls <code class="font-mono text-sm">&lt;.flash_group&gt;</code>
        itself. You raise one from the server with <code class="font-mono text-sm">put_flash/3</code>.
      </p>
      <p class="mt-2 text-sm text-base-content/60">
        In the app these appear as a toast pinned to the top right. The two below are the
        real component, shown in place by a page-scoped rule that returns them to normal
        flow — see <code class="font-mono text-sm">#ds-flash-demo</code>
        in <code class="font-mono text-sm">assets/css/app.css</code>. Clicking one
        dismisses it exactly as it would in the app.
      </p>

      <div id="ds-flash-demo" class="mt-3 space-y-3 border border-base-300 p-4">
        <.flash kind={:info} id="ds-flash-info">Sample info message</.flash>
        <.flash kind={:error} id="ds-flash-error">Sample error message</.flash>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          put_flash(socket, :info, "Route saved") · the layout's &lt;.flash_group&gt; renders it · pass title={"…"} for a heading above the message
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Loading</h2>
      <p class="mt-1 text-sm text-base-content/60">
        LiveView adds a class to an element for as long as its event is in flight, so a
        button can show progress without any assign. Both buttons below are the same
        call; the right one carries the class LiveView would add, so the state is visible
        here rather than for the 80ms a real round trip lasts.
      </p>

      <div id="ds-loading-demo" class="mt-3 border border-base-300 p-4">
        <div class="flex flex-wrap items-center gap-8">
          <div>
            <p class="mb-2 text-xs font-semibold text-base-content/60">Idle</p>
            <.button variant="primary" class="phx-click-loading:opacity-60">
              <.icon
                name="hero-arrow-path"
                class="hidden size-4 motion-safe:animate-spin phx-click-loading:inline-block"
              /> Save changes
            </.button>
          </div>
          <div>
            <p class="mb-2 text-xs font-semibold text-base-content/60">While the event runs</p>
            <.button
              variant="primary"
              class="phx-click-loading phx-click-loading:opacity-60"
            >
              <.icon
                name="hero-arrow-path"
                class="hidden size-4 motion-safe:animate-spin phx-click-loading:inline-block"
              /> Save changes
            </.button>
          </div>
        </div>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          phx-click-loading:opacity-60 · phx-click-loading lands on the clicked element, phx-submit-loading on the submitting form, phx-change-loading on the changed one
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          Design every state, not just the ideal one: empty, loading, error, and partial
          are the ones that get skipped.
        </li>
        <li>
          Toasts are for background outcomes. A validation error belongs on the field, and
          a whole-view failure belongs in a banner — never in a flash the user can miss.
        </li>
        <li>
          Say what failed and how to recover. An error code is secondary detail, never the
          message.
        </li>
        <li>
          Acknowledge a click within 100ms. The loading variants above cost nothing and
          are enough for a fast action; anything slower needs progress the user can cancel.
        </li>
        <li>
          Never blank out content that is already on screen to show a loader. Leave it up
          and mark it as refreshing.
        </li>
        <li>
          Prefer undo over a confirmation when the action is reversible. When it is not,
          name the object on the confirm button.
        </li>
        <li>
          The flash container is <code class="font-mono text-sm">aria-live="polite"</code>,
          so a screen reader announces a message without stealing focus. A state change
          the user cannot see must still be announced.
        </li>
      </ul>
    </section>
    """
  end

  @doc ~S"""
  `<.header>` with all three slots, and both sub-navigation bars.

  The sub-navs take plain sample maps: their record attrs are declared `:map`
  (`core_components.ex:789`, `:989`) and they read only `stop_name`/`stop_id` and
  `route_short_name`/`route_long_name`/`route_id`. Their links are real `navigate`
  links built from the sample IDs, so they point at records that do not exist.

  `station_sub_nav` stays on `active_tab={:details}`. The `:diagram` tab renders the
  level and upload controls at `core_components.ex:896-956`, which emit
  `open_add_level`, `open_edit_level`, `open_naming_drawer`, and `upload_diagram` —
  events this section deliberately does not wire.
  """
  def navigation(assigns) do
    ~H"""
    <section id="ds-page-navigation" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Navigation</h1>
      <p class="mt-2 text-base-content/70">
        Three components that answer "where am I". A page header names the current
        record; the two sub-navigation bars carry the tabs for everything under a
        station or a route.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Header</h2>
      <p class="mt-1 text-sm text-base-content/60">
        A title, an optional subtitle, and an optional actions slot. The header only
        takes the row layout when you fill <code class="font-mono text-sm">&lt;:actions&gt;</code>, so a title-only header
        stays flush left.
      </p>

      <div id="ds-header-demo" class="mt-3 border border-base-300 p-4">
        <.header>
          Station detail
          <:subtitle>GTFS version 2026-01</:subtitle>
          <:actions>
            <.button variant="secondary" size="sm">Edit station</.button>
          </:actions>
        </.header>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.header&gt;Station detail&lt;:subtitle&gt;…&lt;/:subtitle&gt;&lt;:actions&gt;…&lt;/:actions&gt;&lt;/.header&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Station sub-navigation</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Back button, station name, and the four station tabs. Both bars below are the
        real component fed sample records, so their links are live but point at IDs
        that do not exist — clicking a tab leaves the design system and lands on
        nothing.
      </p>

      <div id="ds-station-nav-demo" class="mt-3 border border-base-300">
        <.station_sub_nav
          station={%{stop_id: "demo-stop", stop_name: "Demo Central"}}
          gtfs_version_id="demo-version"
          active_tab={:details}
        />
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.station_sub_nav station={@station} gtfs_version_id={@current_gtfs_version.id} active_tab={:details} /&gt; · the :diagram tab adds level and upload controls
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Route sub-navigation</h2>
      <p class="mt-1 text-sm text-base-content/60">
        The same shape with two tabs. The heading is <code class="font-mono text-sm">short_name - long_name</code>, falling back to
        whichever exists and then to <code class="font-mono text-sm">route_id</code>.
      </p>

      <div id="ds-route-nav-demo" class="mt-3 border border-base-300">
        <.route_sub_nav
          route={%{route_id: "demo-route", route_short_name: "42", route_long_name: "Crosstown"}}
          gtfs_version_id="demo-version"
          active_tab={:details}
        />
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.route_sub_nav route={@route} gtfs_version_id={@current_gtfs_version.id} active_tab={:patterns} /&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          Pass <code class="font-mono text-sm">active_tab</code>
          on every page that renders a sub-nav. It is what marks the current tab <code class="font-mono text-sm">aria-current="page"</code>, so an omitted value
          silently tells the user they are somewhere else.
        </li>
        <li>
          The tabs are <code class="font-mono text-sm">navigate</code>
          links, not events. They are real navigation and belong in the browser's
          history — do not reimplement them as click handlers.
        </li>
        <li>
          One header per view. The actions slot holds that view's primary action; if you
          need two, the second is secondary and the third belongs in a menu.
        </li>
        <li>
          Front-load the title with the record, not the section: "Demo Central" beats
          "Station detail for Demo Central".
        </li>
      </ul>
    </section>
    """
  end

  @doc ~S"""
  The `<.drawer>` component, closed by default and driven by the page's own events.

  The drawer is fixed-position and its overlay covers the viewport
  (`core_components.ex:715-731`), so an open-by-default demo would bury the page
  behind it. It renders with `open={@drawer_open}` instead, and the trigger,
  the overlay, and the header close button push `open_drawer`/`close_drawer` —
  all handled by `DesignSystemLive`, which owns the assign.

  `on_close` is left at its `"close_drawer"` default (`core_components.ex:706`).
  """
  def overlays(assigns) do
    ~H"""
    <section id="ds-page-overlays" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Overlays</h1>
      <p class="mt-2 text-base-content/70">
        One overlay component. The drawer slides in from the right for editing a record
        without losing the list behind it.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Drawer</h2>
      <p class="mt-1 text-sm text-base-content/60">
        The drawer is fixed to the viewport and dims the page behind it, so this demo
        starts closed — open it to see the real component. It closes on the header
        button or on a click outside, both of which push
        <code class="font-mono text-sm">on_close</code>
        back to the LiveView that owns the open state.
      </p>

      <div id="ds-drawer-demo" class="mt-3 border border-base-300 p-4">
        <.button phx-click="open_drawer">Open drawer</.button>
        <.drawer id="ds-demo-drawer" open={@drawer_open} title="Demo drawer">
          <p class="text-sm text-base-content/70">
            Drawer content is usually a form. It scrolls independently of the page, so a
            long form does not push the header off screen.
          </p>
          <p class="mt-4 text-sm text-base-content/70">
            The panel is <code class="font-mono text-sm">max-w-[min(100vw,48rem)]</code>
            by default; pass <code class="font-mono text-sm">class</code>
            to narrow it.
          </p>
        </.drawer>
      </div>
      <p class="mt-3">
        <code
          phx-no-curly-interpolation
          class="ds-code-caption font-mono text-xs text-base-content/70"
        >
          &lt;.drawer id="user-form" open={@show_form} on_close="close_form" title="Edit user"&gt;…&lt;/.drawer&gt;
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          The LiveView owns the open state. The drawer renders from
          <code class="font-mono text-sm">open</code>
          and pushes <code class="font-mono text-sm">on_close</code>; it never closes
          itself, so an unhandled close event leaves it stuck open.
        </li>
        <li>
          Reach for a drawer when the context behind it matters — editing one row of a
          list. When it does not, a full page is simpler and links better.
        </li>
        <li>
          The overlay click and the close button are the only close paths. There is no
          Escape binding, so do not tell users there is one.
        </li>
        <li>
          Keep the title a noun phrase naming the record being edited, not the verb:
          "Edit user" is the button, "User" is the drawer.
        </li>
      </ul>
    </section>
    """
  end

  # Static demo data. A design system page shows the component, so these rows are
  # literals rather than a query: the page must render identically on an empty database.
  defp sample_routes do
    [
      %{id: "7", name: "Crosstown Local", status: "Active"},
      %{id: "42", name: "Airport Express", status: "Active"},
      %{id: "108", name: "Night Owl", status: "Suspended"},
      %{id: "231", name: "Harbor Shuttle", status: "Draft"}
    ]
  end

  # Literal class strings, selected rather than built: Tailwind v4 scans source text,
  # so "text-#{tone}" would compile and then be missing from the bundle.
  defp status_class("Active"), do: "text-success"
  defp status_class("Suspended"), do: "text-warning"
  defp status_class("Draft"), do: "text-base-content/60"
end

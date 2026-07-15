defmodule GtfsPlannerWeb.Design.ComponentPages do
  @moduledoc ~S"""
  Components pages for the `/design` section: buttons and badges.

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
end

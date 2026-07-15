defmodule GtfsPlannerWeb.Design.FoundationPages do
  @moduledoc ~S"""
  Foundations pages for the `/design` section: introduction, colors, typography,
  and icons.

  Every Tailwind/daisyUI class here is a literal string. Tailwind v4 scans source
  text, so an interpolated class name (`"bg-#{token}"`) compiles but is silently
  missing from the bundle. See the precedent comment at
  `lib/gtfs_planner_web/components/navigation.ex:102`.
  """
  use Phoenix.Component

  import GtfsPlannerWeb.CoreComponents

  @doc """
  What the design system is, the stack it rests on, and the house rules.
  """
  def introduction(assigns) do
    ~H"""
    <section id="ds-page-introduction" class="max-w-3xl">
      <h1 class="text-2xl font-bold">Introduction</h1>
      <p class="mt-2 text-base-content/70">
        This section documents the tokens, type, icons, and components GTFS Planner is
        built from. Every page renders the real production components from
        <code class="font-mono text-sm">core_components.ex</code>
        — what you see here is what ships.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Stack</h2>
      <dl class="mt-3 divide-y divide-base-300 border-y border-base-300">
        <div class="grid grid-cols-3 gap-4 py-2">
          <dt class="font-medium">Tailwind CSS v4</dt>
          <dd class="col-span-2 text-base-content/70">
            CSS-first configuration in <code class="font-mono text-sm">assets/css/app.css</code>
            — no JS config file. The JIT compiler scans source text, so class names must
            be written literally.
          </dd>
        </div>
        <div class="grid grid-cols-3 gap-4 py-2">
          <dt class="font-medium">daisyUI 5</dt>
          <dd class="col-span-2 text-base-content/70">
            The <code class="font-mono text-sm">light</code>
            theme, loaded as a Tailwind plugin, supplies the semantic color tokens on the
            Colors page.
          </dd>
        </div>
        <div class="grid grid-cols-3 gap-4 py-2">
          <dt class="font-medium">core_components.ex</dt>
          <dd class="col-span-2 text-base-content/70">
            The HEEx function components every page in the Components group demonstrates.
            Pages adapt around these components; they are never edited to suit a demo.
          </dd>
        </div>
      </dl>

      <h2 class="mt-8 text-lg font-semibold">House rules</h2>
      <p class="mt-2 text-base-content/70">
        Distilled from the written guides in <code class="font-mono text-sm">docs/</code>.
        Read those for the full text.
      </p>

      <h3 class="mt-4 font-semibold">Buttons and CTAs</h3>
      <p class="text-sm text-base-content/60">docs/design/cta-design.md</p>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          A button label is a promise. Write verb + noun in sentence case: Add job, Save changes.
        </li>
        <li>
          Match the verb to the outcome: Create makes an entity, Add attaches one, Delete is permanent, Remove detaches.
        </li>
        <li>One to three words. Avoid OK, Done, and Click here.</li>
        <li>One primary action per view. Destructive actions repeat verb + object.</li>
        <li>Icon-only buttons are for universal actions and need a tooltip and an aria-label.</li>
      </ul>

      <h3 class="mt-4 font-semibold">Forms</h3>
      <p class="text-sm text-base-content/60">docs/design/form-design.md</p>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>Every field is a cost. Remove the field before styling it.</li>
        <li>Single column, top-aligned labels, roughly 640px maximum width.</li>
        <li>Labels stay visible. Placeholders are hints, not labels.</li>
        <li>Validate on blur. Say what failed and how to fix it, and preserve what was typed.</li>
        <li>Mark optional fields rather than required ones. Never signal by color alone.</li>
      </ul>

      <h3 class="mt-4 font-semibold">Tables and rows</h3>
      <p class="text-sm text-base-content/60">docs/design/table-row-design.md</p>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>Tables exist to find, compare, or act.</li>
        <li>Horizontal separators only. Vertical gridlines are chartjunk.</li>
        <li>Text aligns left, numbers align right in tabular numerals.</li>
        <li>Status is color plus text. The primary identifier is the link.</li>
        <li>One or two inline actions; three or more belong in a menu.</li>
      </ul>

      <h3 class="mt-4 font-semibold">Functionalist baseline</h3>
      <p class="text-sm text-base-content/60">docs/functionalist-design.md</p>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>
          Form follows data. Maximize the data-ink ratio: if an element can be erased without losing meaning, erase it.
        </li>
        <li>Align to a grid. Whitespace is structure, not filler.</li>
        <li>Color encodes information — state, category, wayfinding. Never decoration.</li>
        <li>Plain, front-loaded language. Omit needless words and adjectives.</li>
      </ul>
    </section>
    """
  end

  @doc """
  The daisyUI semantic color tokens, as swatches labeled with their class names.
  """
  def colors(assigns) do
    ~H"""
    <section id="ds-page-colors" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Colors</h1>
      <p class="mt-2 text-base-content/70">
        The daisyUI <code class="font-mono text-sm">light</code>
        theme supplies these tokens. Use them by name so a theme change propagates
        everywhere; never hardcode a hex value. Color carries meaning — info, success,
        warning, and error signal state and are not interchangeable accents.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Brand</h2>
      <div class="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.swatch class="bg-primary text-primary-content" label="bg-primary" />
        <.swatch class="bg-secondary text-secondary-content" label="bg-secondary" />
        <.swatch class="bg-accent text-accent-content" label="bg-accent" />
        <.swatch class="bg-neutral text-neutral-content" label="bg-neutral" />
      </div>

      <h2 class="mt-8 text-lg font-semibold">Surfaces</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Page and card backgrounds, ascending in depth. Body text on all three is <code class="font-mono text-sm">text-base-content</code>.
      </p>
      <div class="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.swatch class="bg-base-100 text-base-content" label="bg-base-100" />
        <.swatch class="bg-base-200 text-base-content" label="bg-base-200" />
        <.swatch class="bg-base-300 text-base-content" label="bg-base-300" />
      </div>

      <h2 class="mt-8 text-lg font-semibold">State</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Pair state color with text. Color alone is not an accessible signal.
      </p>
      <div class="mt-3 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.swatch class="bg-info text-info-content" label="bg-info" />
        <.swatch class="bg-success text-success-content" label="bg-success" />
        <.swatch class="bg-warning text-warning-content" label="bg-warning" />
        <.swatch class="bg-error text-error-content" label="bg-error" />
      </div>

      <h2 class="mt-8 text-lg font-semibold">Content pairing</h2>
      <p class="mt-2 text-base-content/70">
        Each background token has a matching foreground token —
        <code class="font-mono text-sm">bg-primary</code>
        pairs with <code class="font-mono text-sm">text-primary-content</code>. Use the
        pair. A background token with a hand-picked foreground is how contrast rots.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Overrides</h2>
      <p class="mt-2 text-base-content/70">
        <code class="font-mono text-sm">assets/css/app.css</code>
        replaces some of the stock <code class="font-mono text-sm">light</code>
        values. Every state color is one of them, so the numbers below are the app's,
        not daisyUI's.
      </p>
      <dl class="mt-3 divide-y divide-base-300 border-y border-base-300">
        <div class="grid grid-cols-3 gap-4 py-2">
          <dt class="font-mono text-sm">--color-primary-content</dt>
          <dd class="col-span-2 text-base-content/70">
            Forced to pure white, so text on a primary button stays legible instead of
            taking the theme's computed tint. 8.3:1 on <code class="font-mono text-sm">bg-primary</code>.
          </dd>
        </div>
        <div class="grid grid-cols-3 gap-4 py-2">
          <dt class="font-mono text-sm">--depth</dt>
          <dd class="col-span-2 text-base-content/70">
            Set to <code class="font-mono text-sm">0</code>. daisyUI tints a button's
            drop shadow with the button's own background color and scales it by this
            value; zero resolves the glow away. A shadow that encodes nothing is
            chartjunk.
          </dd>
        </div>
        <div class="grid grid-cols-3 gap-4 py-2">
          <dt class="font-mono text-sm">
            --color-error<br />--color-warning<br />--color-success<br />--color-info
          </dt>
          <dd class="col-span-2 text-base-content/70">
            Darkened to 5.2:1 against <code class="font-mono text-sm">bg-base-100</code>,
            hue unchanged. The stock values are chosen to sit <em>behind</em>
            dark text — <code class="font-mono text-sm">--color-warning</code>
            was 1.76:1 on white — but the app also uses them <em>as</em>
            text, and every one of those failed AA. Contrast is symmetric, so one value
            fixes both directions: <code class="font-mono text-sm">text-error</code>
            on white and white on <code class="font-mono text-sm">bg-error</code>
            are both 5.2:1. Each matching <code class="font-mono text-sm">-content</code>
            token is therefore white.
          </dd>
        </div>
        <div class="grid grid-cols-3 gap-4 py-2">
          <dt class="font-mono text-sm">--color-secondary</dt>
          <dd class="col-span-2 text-base-content/70">
            Darkened the same way. Its stock pairing with
            <code class="font-mono text-sm">--color-secondary-content</code>
            was 3.05:1 — a documented pair that failed AA.
          </dd>
        </div>
      </dl>
      <p class="mt-3 text-sm text-base-content/60">
        <code class="font-mono text-sm">--color-accent</code>
        is untouched and still fails as text: 1.9:1 on white. It is a background token —
        pair it with <code class="font-mono text-sm">text-accent-content</code>
        and never write <code class="font-mono text-sm">text-accent</code>.
      </p>
    </section>
    """
  end

  @doc """
  Typeface provenance and the heading, body, and mono scale used across the app.
  """
  def typography(assigns) do
    ~H"""
    <section id="ds-page-typography" class="max-w-3xl">
      <h1 class="text-2xl font-bold">Typography</h1>
      <p class="mt-2 text-base-content/70">
        The app sets one typeface: Inter. It is self-hosted as a variable font
        (<code class="font-mono text-sm">InterVariable.woff2</code>, weights 100–900, <code class="font-mono text-sm">font-display: swap</code>) and registered as the
        Tailwind sans stack in <code class="font-mono text-sm">assets/css/app.css</code>,
        so <code class="font-mono text-sm">font-sans</code>
        and every unstyled element resolve to Inter. Inter is a neo-grotesque built for
        UI legibility — no display faces, no second family.
      </p>

      <p class="mt-3 overflow-x-auto border border-base-300 bg-base-200 p-3">
        <code phx-no-curly-interpolation class="font-mono text-xs whitespace-nowrap">
          @theme { --font-sans: "Inter", ui-sans-serif, system-ui, sans-serif, ...; }
        </code>
      </p>

      <h2 class="mt-8 text-lg font-semibold">Scale</h2>
      <p class="mt-1 text-sm text-base-content/60">
        The sizes in use. One level per rank — skipping a level to fake emphasis breaks
        the hierarchy.
      </p>

      <dl class="mt-3 divide-y divide-base-300 border-y border-base-300">
        <div class="grid grid-cols-3 items-baseline gap-4 py-3">
          <dt class="font-mono text-xs text-base-content/60">text-2xl font-bold</dt>
          <dd class="col-span-2">
            <p class="ds-type-sample text-2xl font-bold">Page title</p>
          </dd>
        </div>
        <div class="grid grid-cols-3 items-baseline gap-4 py-3">
          <dt class="font-mono text-xs text-base-content/60">text-xl font-semibold</dt>
          <dd class="col-span-2">
            <p class="ds-type-sample text-xl font-semibold">Section heading</p>
          </dd>
        </div>
        <div class="grid grid-cols-3 items-baseline gap-4 py-3">
          <dt class="font-mono text-xs text-base-content/60">text-lg font-semibold</dt>
          <dd class="col-span-2">
            <p class="ds-type-sample text-lg font-semibold">Subsection heading</p>
          </dd>
        </div>
        <div class="grid grid-cols-3 items-baseline gap-4 py-3">
          <dt class="font-mono text-xs text-base-content/60">text-base</dt>
          <dd class="col-span-2">
            <p class="ds-type-sample text-base">
              Body copy. Reads at a comfortable measure and carries the detail.
            </p>
          </dd>
        </div>
        <div class="grid grid-cols-3 items-baseline gap-4 py-3">
          <dt class="font-mono text-xs text-base-content/60">text-sm text-base-content/70</dt>
          <dd class="col-span-2">
            <p class="ds-type-sample text-sm text-base-content/70">
              Secondary and supporting text.
            </p>
          </dd>
        </div>
        <div class="grid grid-cols-3 items-baseline gap-4 py-3">
          <dt class="font-mono text-xs text-base-content/60">font-mono text-sm</dt>
          <dd class="col-span-2">
            <p class="ds-type-sample font-mono text-sm">stop_id · GTFS-2481 · 47.6062</p>
          </dd>
        </div>
      </dl>

      <p class="mt-4 text-base-content/70">
        Identifiers, coordinates, and codes are mono. Numbers that get compared in a
        column are mono for the same reason: the digits line up.
      </p>
    </section>
    """
  end

  @doc """
  Common heroicons rendered through the real `<.icon>` component.
  """
  def icons(assigns) do
    ~H"""
    <section id="ds-page-icons" class="max-w-4xl">
      <h1 class="text-2xl font-bold">Icons</h1>
      <p class="mt-2 text-base-content/70">
        Icons come from
        <.link
          href="https://heroicons.com"
          target="_blank"
          rel="noopener"
          class="link link-primary"
        >
          Heroicons
        </.link>
        via the <code class="font-mono text-sm">core_components.ex</code>
        icon component. Name them with the <code class="font-mono text-sm">hero-</code>
        prefix; add <code class="font-mono text-sm">-solid</code>
        or <code class="font-mono text-sm">-mini</code>
        for those styles. Outline is the default.
      </p>

      <h2 class="mt-8 text-lg font-semibold">Common icons</h2>
      <div class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <div class="flex flex-col items-center gap-2 border border-base-300 p-3">
          <.icon name="hero-x-mark" class="size-5" />
          <code class="ds-icon-label font-mono text-xs text-base-content/70">hero-x-mark</code>
        </div>
        <div class="flex flex-col items-center gap-2 border border-base-300 p-3">
          <.icon name="hero-map-pin" class="size-5" />
          <code class="ds-icon-label font-mono text-xs text-base-content/70">hero-map-pin</code>
        </div>
        <div class="flex flex-col items-center gap-2 border border-base-300 p-3">
          <.icon name="hero-arrow-path" class="size-5" />
          <code class="ds-icon-label font-mono text-xs text-base-content/70">hero-arrow-path</code>
        </div>
        <div class="flex flex-col items-center gap-2 border border-base-300 p-3">
          <.icon name="hero-user-group" class="size-5" />
          <code class="ds-icon-label font-mono text-xs text-base-content/70">hero-user-group</code>
        </div>
        <div class="flex flex-col items-center gap-2 border border-base-300 p-3">
          <.icon name="hero-chevron-left" class="size-5" />
          <code class="ds-icon-label font-mono text-xs text-base-content/70">hero-chevron-left</code>
        </div>
        <div class="flex flex-col items-center gap-2 border border-base-300 p-3">
          <.icon name="hero-exclamation-circle" class="size-5" />
          <code class="ds-icon-label font-mono text-xs text-base-content/70">
            hero-exclamation-circle
          </code>
        </div>
      </div>

      <h2 class="mt-8 text-lg font-semibold">Size</h2>
      <p class="mt-2 text-base-content/70">
        The component defaults to <code class="font-mono text-sm">size-4</code>, and
        <code class="font-mono text-sm">size-5</code>
        is the common inline size next to text. Passing <code class="font-mono text-sm">class</code>
        replaces the default, so include the size whenever you override it.
      </p>
      <div class="mt-3 flex items-end gap-6 border border-base-300 p-4">
        <div class="flex flex-col items-center gap-2">
          <.icon name="hero-map-pin" class="size-4" />
          <code class="font-mono text-xs text-base-content/70">size-4</code>
        </div>
        <div class="flex flex-col items-center gap-2">
          <.icon name="hero-map-pin" class="size-5" />
          <code class="font-mono text-xs text-base-content/70">size-5</code>
        </div>
        <div class="flex flex-col items-center gap-2">
          <.icon name="hero-map-pin" class="size-6" />
          <code class="font-mono text-xs text-base-content/70">size-6</code>
        </div>
      </div>

      <h2 class="mt-8 text-lg font-semibold">Use</h2>
      <ul class="mt-2 list-disc space-y-1 pl-5 text-base-content/70">
        <li>Text first. An icon reinforces a label; it rarely replaces one.</li>
        <li>Icon-only controls are for universal actions and need a tooltip and an aria-label.</li>
        <li>An icon that carries no meaning is chartjunk. Erase it.</li>
      </ul>
    </section>
    """
  end

  # Renders one color swatch. Callers pass the full class string as a literal so
  # Tailwind's source scan finds it; building it here from a token would drop the
  # class from the bundle.
  defp swatch(assigns) do
    ~H"""
    <div>
      <div class={[
        "ds-swatch flex h-16 items-end border border-base-300 p-2",
        @class
      ]}>
        <span class="font-mono text-xs">Aa</span>
      </div>
      <code class="ds-swatch-label mt-1 block font-mono text-xs text-base-content/70">
        {@label}
      </code>
    </div>
    """
  end
end

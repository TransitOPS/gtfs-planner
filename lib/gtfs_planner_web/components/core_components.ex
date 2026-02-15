defmodule GtfsPlannerWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: GtfsPlannerWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # Using btn-active removes the shadow/glow effect that causes visual misalignment
    variants = %{"primary" => "btn-primary btn-active", nil => "btn-primary btn-soft btn-active"}

    assigns =
      assign_new(assigns, :class, fn ->
        []
      end)

    classes =
      ["btn", Map.fetch!(variants, assigns[:variant]), List.wrap(assigns[:class])]

    assigns = assign(assigns, :class, classes)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :help, :string, default: nil, doc: "help text displayed below the input"

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label text-base">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign_new(assigns, :help_id, fn -> if assigns.help, do: "#{assigns.id}-help" end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label text-base mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[
            @class || "w-full select select-lg",
            @errors != [] && (@error_class || "select-error")
          ]}
          multiple={@multiple}
          aria-describedby={@help_id}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = assign_new(assigns, :help_id, fn -> if assigns.help, do: "#{assigns.id}-help" end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label text-base mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea textarea-lg",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          aria-describedby={@help_id}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    # Generate a unique ID for aria-describedby when help text is present
    assigns = assign_new(assigns, :help_id, fn -> if assigns.help, do: "#{assigns.id}-help" end)

    ~H"""
    <div class="fieldset mb-2">
      <label>
        <span :if={@label} class="label text-base mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input input-lg",
            @errors != [] && (@error_class || "input-error")
          ]}
          aria-describedby={@help_id}
          {@rest}
        />
      </label>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a group of checkboxes for multi-select options.

  ## Examples

      <.checkbox_group
        name="invite[roles][]"
        label="Roles"
        options={[{"Admin", "admin"}, {"Editor", "editor"}]}
        selected={@selected_roles}
        required
      />
  """
  attr :name, :string, required: true, doc: "the input name for the checkbox group"
  attr :label, :string, required: true, doc: "the label for the checkbox group"
  attr :options, :list, required: true, doc: "list of {label, value} tuples"
  attr :selected, :list, default: [], doc: "list of currently selected values"
  attr :required, :boolean, default: false, doc: "whether at least one option must be selected"
  attr :error, :string, default: nil, doc: "error message to display"
  attr :help, :string, default: nil, doc: "help text displayed below the checkboxes"

  def checkbox_group(assigns) do
    ~H"""
    <fieldset class="fieldset mb-2" aria-describedby={@error && "#{@name}-error"}>
      <legend class="fieldset-legend text-base">
        {@label}
        <span :if={@required} class="text-error">*</span>
      </legend>
      <div class="space-y-2 mt-2" role="group" aria-label={@label}>
        <label :for={{label, value} <- @options} class="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            name={@name}
            value={value}
            checked={value in @selected}
            class="checkbox checkbox-sm"
          />
          <span class="label">{label}</span>
        </label>
      </div>
      <p :if={@help} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <p
        :if={@error}
        id={"#{@name}-error"}
        role="alert"
        aria-live="polite"
        class="mt-1.5 flex gap-2 items-center text-sm text-error"
      >
        <.icon name="hero-exclamation-circle" class="size-5" />
        {@error}
      </p>
    </fieldset>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@class, @actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a route badge with color, text color, and short name.

  ## Examples

      <.route_badge route={@route} />
  """
  attr :route, :map, required: true

  def route_badge(assigns) do
    ~H"""
    <span
      class="inline-flex items-center justify-center px-2 py-0.5 text-xs font-medium rounded"
      style={"background-color: ##{@route.route_color}; color: ##{@route.route_text_color}"}
    >
      {@route.route_short_name || "—"}
    </span>
    """
  end

  @doc """
  Renders pagination controls with previous/next buttons and item count.

  ## Examples

      <.pagination page={@page} per_page={@per_page} total={@total_count} />
  """
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true

  def pagination(assigns) do
    # Handle empty state: when total is 0, show 0-0 instead of 1-0
    start_item = if assigns.total == 0, do: 0, else: (assigns.page - 1) * assigns.per_page + 1
    end_item = min(assigns.page * assigns.per_page, assigns.total)
    has_prev = assigns.page > 1
    has_next = end_item < assigns.total

    assigns =
      assigns
      |> assign(:start_item, start_item)
      |> assign(:end_item, end_item)
      |> assign(:has_prev, has_prev)
      |> assign(:has_next, has_next)

    ~H"""
    <div class="flex items-center justify-between gap-4 py-3">
      <div class="text-sm text-base-content/70">
        Showing {@start_item}–{@end_item} of {@total} routes
      </div>
      <div class="flex gap-2">
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click="paginate"
          phx-value-page={@page - 1}
          disabled={!@has_prev}
        >
          Previous
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click="paginate"
          phx-value-page={@page + 1}
          disabled={!@has_next}
        >
          Next
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-submit="save">
        <.input field={@form[:email]} type="email" />
        <.input field={@form[:username]} type="text" />
      </.simple_form>

  """
  attr :for, :any, default: nil, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={_f} for={@for} as={@as} {@rest}>
      <div class="space-y-6">
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="mt-8 flex items-center justify-between gap-6">
        {render_slot(@actions)}
      </div>
    </.form>
    """
  end

  @doc """
  Renders a slide-in drawer panel from the right side of the screen.

  The drawer provides a consistent slide-in-from-right behavior with an overlay
  that can be clicked to close. It uses CSS transitions for smooth animations
  and integrates reliably with LiveView's server-driven state model.

  ## Examples

      <.drawer id="user-form" open={@show_form} on_close="close_form" title="Edit User">
        <.simple_form for={@form} phx-submit="save">
          <.input field={@form[:name]} type="text" label="Name" class="max-w-3xl" />
        </.simple_form>
      </.drawer>

  """
  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :on_close, :string, default: "close_drawer"
  attr :title, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true
  slot :header_actions

  def drawer(assigns) do
    ~H"""
    <%!-- Overlay --%>
    <div
      class={[
        "fixed inset-0 bg-black/30 z-40 transition-opacity duration-300",
        @open && "opacity-100",
        !@open && "opacity-0 pointer-events-none"
      ]}
      phx-click={@on_close}
    />
    <%!-- Drawer Panel --%>
    <aside
      id={@id}
      class={[
        "fixed top-0 right-0 h-full w-screen min-w-[320px] max-w-[min(100vw,48rem)] bg-base-100 shadow-xl border-l border-base-200 z-50 transition-transform duration-300 overflow-x-hidden",
        @open && "translate-x-0",
        !@open && "translate-x-full",
        @class
      ]}
    >
      <div class="flex flex-col h-full">
        <%!-- Header --%>
        <header class="flex items-center justify-between px-6 py-4 bg-emerald-50 border-b border-emerald-100">
          <div class="flex items-center gap-3">
            <h2 :if={@title} class="text-lg font-semibold text-emerald-900">
              {@title}
            </h2>
            {render_slot(@header_actions)}
          </div>
          <div :if={!@title && @header_actions == []} class="flex-1" />
          <button
            type="button"
            phx-click={@on_close}
            class="btn btn-ghost btn-sm btn-circle text-emerald-900/70 hover:bg-emerald-200/50"
            aria-label={gettext("close")}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </header>
        <%!-- Content --%>
        <div class="flex-1 overflow-y-auto p-6">
          {render_slot(@inner_block)}
        </div>
      </div>
    </aside>
    """
  end

  @doc """
  Renders a full-width sub-navigation bar for station pages.

  Provides a back button, prominent station name, underline-style tabs for
  switching between views, and a slot for contextual action buttons.

  When `active_tab` is `:diagram`, displays a third row with level controls
  and canvas mode toggle.

  ## Examples

      <.station_sub_nav
        station={@station}
        gtfs_version_id={@current_gtfs_version.id}
        active_tab={:details}
      />

      <.station_sub_nav
        station={@station}
        gtfs_version_id={@current_gtfs_version.id}
        active_tab={:diagram}
        levels={@levels}
        active_level={@active_level}
        mode={@mode}
        uploads={@uploads}
        diagram_error={@diagram_error}
      />
  """
  attr :station, :map, required: true, doc: "the station stop record"
  attr :gtfs_version_id, :any, required: true, doc: "the current GTFS version ID"
  attr :active_tab, :atom, values: [:details, :diagram], default: :details
  attr :levels, :list, default: [], doc: "list of levels for the station (diagram tab)"
  attr :active_level, :any, default: nil, doc: "the currently selected level (diagram tab)"
  attr :mode, :atom, default: :add, doc: "canvas mode - :add or :connect (diagram tab)"
  attr :uploads, :any, default: nil, doc: "uploads struct for diagram upload (diagram tab)"

  attr :has_diagram, :boolean,
    default: false,
    doc: "whether the active level has a diagram uploaded"

  attr :diagram_error, :string, default: nil, doc: "error message for diagram upload"
  slot :actions, doc: "contextual action buttons"

  def station_sub_nav(assigns) do
    ~H"""
    <nav
      id="station-sub-nav"
      class="w-full px-4 sm:px-6 lg:px-8"
      aria-label="Station navigation"
    >
      <%!-- Top row: Back button, station name, actions --%>
      <div class="flex items-center justify-between py-3">
        <div class="flex items-center gap-4">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops"}
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Back to stations list"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <h1 class="text-xl font-semibold leading-tight">
            {@station.stop_name || @station.stop_id}
          </h1>
        </div>
        <div class="flex items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      <%!-- Bottom row: Underline tabs + diagram controls --%>
      <div class="flex items-end justify-between border-b border-base-300">
        <%!-- Left: Tabs --%>
        <div class="flex items-end gap-6" role="tablist">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}"}
            class={[
              "pb-3 text-sm font-medium transition-colors border-b-2 -mb-px",
              @active_tab == :details && "border-primary text-base-content",
              @active_tab != :details &&
                "border-transparent text-base-content/60 hover:text-base-content hover:border-base-300"
            ]}
            role="tab"
            aria-selected={@active_tab == :details}
            aria-current={@active_tab == :details && "page"}
          >
            Details
          </.link>
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}/diagram"}
            class={[
              "pb-3 text-sm font-medium transition-colors border-b-2 -mb-px",
              @active_tab == :diagram && "border-primary text-base-content",
              @active_tab != :diagram &&
                "border-transparent text-base-content/60 hover:text-base-content hover:border-base-300"
            ]}
            role="tab"
            aria-selected={@active_tab == :diagram}
            aria-current={@active_tab == :diagram && "page"}
          >
            Diagram
          </.link>
        </div>

        <%!-- Right: Diagram controls (only on diagram tab) --%>
        <div :if={@active_tab == :diagram} class="flex items-center gap-4 pb-2">
          <%!-- Level context --%>
          <div class="flex items-center gap-2">
            <button
              type="button"
              class="btn btn-sm btn-outline"
              phx-click="open_add_level"
            >
              Add a level
            </button>

            <button
              :if={@active_level}
              type="button"
              class="btn btn-sm btn-outline"
              phx-click="open_edit_level"
            >
              Edit this level
            </button>
          </div>

          <%!-- Canvas actions --%>
          <div :if={@active_level && @uploads} class="flex items-center gap-2">
            <form
              id="diagram-upload-form"
              phx-change="upload_diagram"
              phx-submit="save_diagram"
              phx-hook="AutoSubmitUpload"
            >
              <label class="btn btn-sm btn-outline cursor-pointer">
                {if @has_diagram, do: "Replace diagram", else: "Upload Diagram"}
                <.live_file_input
                  upload={@uploads.diagram}
                  id="station-sub-nav-upload"
                  class="hidden"
                />
              </label>
            </form>
            <span :if={@diagram_error} class="text-error text-sm">{@diagram_error}</span>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  @doc """
  Renders a full-width sub-navigation bar for route pages.

  Provides a back button, prominent route name, and underline-style tabs for
  switching between views.

  ## Examples

      <.route_sub_nav
        route={@route}
        gtfs_version_id={@current_gtfs_version.id}
        active_tab={:patterns}
      />
  """
  attr :route, :map, required: true, doc: "the route record"
  attr :gtfs_version_id, :any, required: true, doc: "the current GTFS version ID"
  attr :active_tab, :atom, values: [:details, :patterns], default: :details

  def route_sub_nav(assigns) do
    # Build route display name: short_name - long_name or route_id
    route_display =
      cond do
        assigns.route.route_short_name && assigns.route.route_long_name ->
          "#{assigns.route.route_short_name} - #{assigns.route.route_long_name}"

        assigns.route.route_short_name ->
          assigns.route.route_short_name

        assigns.route.route_long_name ->
          assigns.route.route_long_name

        true ->
          assigns.route.route_id
      end

    assigns = assign(assigns, :route_display, route_display)

    ~H"""
    <nav class="w-full px-4 sm:px-6 lg:px-8" aria-label="Route navigation">
      <%!-- Top row: Back button and route name --%>
      <div class="flex items-center justify-between py-3">
        <div class="flex items-center gap-4">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/routes"}
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Back to routes list"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <h1 class="text-xl font-semibold leading-tight">
            {@route_display}
          </h1>
        </div>
      </div>
      <%!-- Bottom row: Underline tabs --%>
      <div class="flex items-end justify-between border-b border-base-300">
        <div class="flex items-end gap-6" role="tablist">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}"}
            class={[
              "pb-3 text-sm font-medium transition-colors border-b-2 -mb-px",
              @active_tab == :details && "border-primary text-base-content",
              @active_tab != :details &&
                "border-transparent text-base-content/60 hover:text-base-content hover:border-base-300"
            ]}
            role="tab"
            aria-selected={@active_tab == :details}
            aria-current={@active_tab == :details && "page"}
          >
            Details
          </.link>
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/patterns"}
            class={[
              "pb-3 text-sm font-medium transition-colors border-b-2 -mb-px",
              @active_tab == :patterns && "border-primary text-base-content",
              @active_tab != :patterns &&
                "border-transparent text-base-content/60 hover:text-base-content hover:border-base-300"
            ]}
            role="tab"
            aria-selected={@active_tab == :patterns}
            aria-current={@active_tab == :patterns && "page"}
          >
            Patterns
          </.link>
        </div>
      </div>
    </nav>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(GtfsPlannerWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GtfsPlannerWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end

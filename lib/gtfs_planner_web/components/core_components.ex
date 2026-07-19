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
      class="toast toast-top toast-end z-[60]"
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
        <button
          type="button"
          class="group self-start cursor-pointer min-h-11 min-w-11 flex items-center justify-center"
          aria-label={gettext("Dismiss message")}
          phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
        >
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
      <.button phx-click="go" variant="secondary">Cancel</.button>
      <.button phx-click="go" variant="danger">Delete user</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary secondary quiet danger), default: "primary"
  attr :size, :string, values: ~w(sm md lg), default: "md"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{
      "primary" => "btn-primary",
      "secondary" => "btn-outline",
      "quiet" => "btn-ghost",
      "danger" => "btn-error"
    }

    sizes = %{
      "sm" => "btn-sm",
      "md" => "",
      "lg" => "btn-lg"
    }

    # The focus ring is solid and offset, not tinted. `ring-primary/30` resolved to
    # 1.73:1 against base-100 — below the 3:1 WCAG 1.4.11 asks of a focus indicator —
    # and this is the keyboard affordance for every button in the app. The offset
    # keeps the ring readable on a filled button, where a ring in the button's own
    # color would otherwise sit on top of it.
    base_classes =
      "font-medium transition-colors duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2 focus-visible:ring-offset-base-100"

    assigns =
      assign_new(assigns, :class, fn ->
        []
      end)

    classes =
      [
        "btn",
        base_classes,
        Map.fetch!(sizes, assigns[:size]),
        Map.fetch!(variants, assigns[:variant]),
        List.wrap(assigns[:class])
      ]

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
    explicit_errors = assigns.errors

    translated_errors =
      if explicit_errors != [] do
        explicit_errors
      else
        errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []
        Enum.map(errors, &translate_error/1)
      end

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, translated_errors)
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign(:value, field.value)
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

    assigns =
      with_error_ids(assigns)

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
            aria-invalid={to_string(@errors != [])}
            aria-describedby={@describedby}
            {@rest}
          />{@label}
        </span>
      </label>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <.error id={@error_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    assigns = assign_new(assigns, :value, fn -> nil end)
    assigns = with_error_ids(assigns)

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
          aria-invalid={to_string(@errors != [])}
          aria-describedby={@describedby}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <.error id={@error_id} errors={@errors} />
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    assigns = assign_new(assigns, :value, fn -> nil end)
    assigns = with_error_ids(assigns)

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
          aria-invalid={to_string(@errors != [])}
          aria-describedby={@describedby}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <.error id={@error_id} errors={@errors} />
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    assigns = assign_new(assigns, :value, fn -> nil end)
    assigns = with_error_ids(assigns)

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
          aria-invalid={to_string(@errors != [])}
          aria-describedby={@describedby}
          {@rest}
        />
      </label>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <.error id={@error_id} errors={@errors} />
    </div>
    """
  end

  # Derives stable help/error IDs and a combined `aria-describedby` value so the
  # control references every applicable description. Help and error IDs are
  # deterministic from the input id; `aria-describedby` is nil when neither is
  # present so no empty attribute is emitted.
  defp with_error_ids(assigns) do
    help_id = if assigns.help, do: "#{assigns.id}-help"
    error_id = if assigns.errors != [], do: "#{assigns.id}-error"

    describedby =
      [help_id, error_id]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        ids -> Enum.join(ids, " ")
      end

    assigns
    |> assign(:help_id, help_id)
    |> assign(:error_id, error_id)
    |> assign(:describedby, describedby)
  end

  @doc """
  Renders a group of checkboxes for multi-select options.

  ## Examples

      <.checkbox_group
        id="invite-roles"
        name="invite[roles][]"
        label="Roles"
        options={[{"Admin", "admin"}, {"Editor", "editor"}]}
        selected={@selected_roles}
        required
      />
  """
  attr :id, :string, required: true, doc: "the stable component id"
  attr :name, :string, required: true, doc: "the input name for the checkbox group"
  attr :label, :string, required: true, doc: "the label for the checkbox group"
  attr :options, :list, required: true, doc: "list of {label, value} tuples"
  attr :selected, :list, default: [], doc: "list of currently selected values"
  attr :required, :boolean, default: false, doc: "whether at least one option must be selected"
  attr :error, :string, default: nil, doc: "error message to display"
  attr :help, :string, default: nil, doc: "help text displayed below the checkboxes"

  def checkbox_group(assigns) do
    help_id = if assigns.help, do: "#{assigns.id}-help"
    error_id = if assigns.error, do: "#{assigns.id}-error"

    describedby =
      [help_id, error_id]
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        ids -> Enum.join(ids, " ")
      end

    assigns =
      assigns
      |> assign(:help_id, help_id)
      |> assign(:error_id, error_id)
      |> assign(:describedby, describedby)

    ~H"""
    <fieldset
      id={@id}
      class={["fieldset mb-2", @error && "text-error"]}
      aria-describedby={@describedby}
      aria-invalid={to_string(@error != nil)}
    >
      <legend class="fieldset-legend text-base">
        {@label}
        <span :if={@required} class="text-sm text-base-content/60">(required)</span>
        <span :if={!@required} class="text-sm text-base-content/60">(optional)</span>
      </legend>
      <div class="space-y-2 mt-2" role="group" aria-label={@label}>
        <label :for={{label, value} <- @options} class="flex items-center gap-2 cursor-pointer">
          <input
            type="checkbox"
            id={"#{@id}-#{value}"}
            name={@name}
            value={value}
            checked={value in @selected}
            class="checkbox checkbox-sm"
          />
          <span class="label">{label}</span>
        </label>
      </div>
      <p :if={@help} id={@help_id} class="mt-1.5 text-sm text-base-content/70">{@help}</p>
      <p
        :if={@error}
        id={@error_id}
        class="mt-1.5 flex gap-2 items-center text-sm text-error"
      >
        <.icon name="hero-exclamation-circle" class="size-5" />
        {@error}
      </p>
    </fieldset>
    """
  end

  attr :id, :string, default: nil
  attr :errors, :list, default: []

  defp error(assigns) do
    ~H"""
    <p
      :if={@errors != []}
      id={@id}
      class="mt-1.5 flex flex-col gap-1 text-sm text-error"
    >
      <span :for={msg <- @errors} class="flex gap-2 items-center">
        <.icon name="hero-exclamation-circle" class="size-5" />
        {msg}
      </span>
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
    <header class={[
      @class,
      @actions != [] && "flex flex-col sm:flex-row sm:items-center justify-between gap-4",
      "pb-4"
    ]}>
      <div class="min-w-0">
        <h1 class="text-2xl font-bold leading-8 break-words">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none flex flex-wrap items-center gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a responsive data table with one semantic representation.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  attr :responsive, :string,
    values: ~w(stack scroll),
    default: "scroll",
    doc:
      "\"stack\" presents labeled records on narrow screens; \"scroll\" uses local horizontal overflow"

  attr :sort_target, :any,
    default: nil,
    doc: "LiveComponent target for sort events"

  slot :col, required: true do
    attr :label, :string, required: true
    attr :align, :string, doc: "\"left\" (default) or \"right\""

    attr :sort, :string,
      doc: "\"asc\", \"desc\", or \"none\" — renders aria-sort and an indicator"

    attr :sort_event, :string, doc: "event name that makes the header a sort button"
    attr :sort_key, :string, doc: "value sent as phx-value-key with the sort event"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div id={"#{@id}-container"} class={table_container_class(@responsive)}>
      <table class={["table", @responsive == "stack" && "ds-stack-table"]}>
        <thead>
          <tr>
            <th
              :for={col <- @col}
              class={if(col[:align] == "right", do: "text-right", else: "text-left")}
              aria-sort={sort_aria(col[:sort])}
            >
              <button
                :if={col[:sort_event]}
                type="button"
                class="inline-flex items-center gap-1 min-h-11"
                phx-click={col[:sort_event]}
                phx-value-key={col[:sort_key]}
                phx-target={@sort_target}
              >
                {col[:label]}
                <span
                  :if={col[:sort]}
                  class={["text-xs", col[:sort] == "none" && "text-base-content/30"]}
                  aria-hidden="true"
                >
                  {sort_arrow(col[:sort])}
                </span>
              </button>
              <span :if={!col[:sort_event]} class="inline-flex items-center gap-1">
                {col[:label]}
                <span
                  :if={col[:sort]}
                  class={["text-xs", col[:sort] == "none" && "text-base-content/30"]}
                  aria-hidden="true"
                >
                  {sort_arrow(col[:sort])}
                </span>
              </span>
            </th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td
              :for={col <- @col}
              data-label={col[:label]}
              class={if(col[:align] == "right", do: "text-right", else: "text-left")}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} data-label="Actions" class="w-0 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp table_container_class("stack"), do: "overflow-visible"
  defp table_container_class("scroll"), do: "overflow-x-auto"

  defp sort_aria("asc"), do: "ascending"
  defp sort_aria("desc"), do: "descending"
  defp sort_aria("none"), do: "none"
  defp sort_aria(_), do: nil

  defp sort_arrow("asc"), do: "▲"
  defp sort_arrow("desc"), do: "▼"
  defp sort_arrow(_), do: "↕"

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
  Renders pagination controls with previous/next buttons and item count.

  ## Examples

      <.pagination page={@page} per_page={@per_page} total={@total_count} />
  """
  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total, :integer, required: true
  attr :entity, :string, default: nil, doc: "optional noun appended to the count, e.g. \"routes\""
  attr :event, :string, default: "paginate", doc: "event name emitted by Previous and Next"
  attr :target, :any, default: nil, doc: "LiveComponent target for pagination events"

  def pagination(assigns) do
    total = max(assigns.total, 0)
    per_page = max(assigns.per_page, 1)
    max_page = max(ceil(total / per_page), 1)
    page = assigns.page |> max(1) |> min(max_page)

    start_item = if total == 0, do: 0, else: (page - 1) * per_page + 1
    end_item = min(page * per_page, total)
    has_prev = page > 1
    has_next = end_item < total

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:page, page)
      |> assign(:start_item, start_item)
      |> assign(:end_item, end_item)
      |> assign(:has_prev, has_prev)
      |> assign(:has_next, has_next)

    ~H"""
    <div class="flex items-center justify-between gap-4 py-3">
      <div class="text-sm text-base-content/70">
        Showing {@start_item}–{@end_item} of {@total}{if @entity, do: " #{@entity}"}
      </div>
      <div class="flex gap-2">
        <button
          type="button"
          class="btn btn-sm btn-ghost min-h-11"
          phx-click={@event}
          phx-value-page={@page - 1}
          phx-target={@target}
          disabled={!@has_prev}
        >
          Previous
        </button>
        <button
          type="button"
          class="btn btn-sm btn-ghost min-h-11"
          phx-click={@event}
          phx-value-page={@page + 1}
          phx-target={@target}
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

      <.simple_form for={@form} id="my-form" phx-submit="save">
        <.input field={@form[:email]} type="email" />
        <.input field={@form[:username]} type="text" />
      </.simple_form>

  """
  attr :id, :string, required: true, doc: "the unique id of the form"
  attr :for, :any, default: nil, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form for={@for} as={@as} id={@id} {@rest}>
      <div class="w-full max-w-2xl space-y-6">
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

  Renders a native `<dialog>` backed by the `OverlayDialog` hook. LiveView
  owns the requested state through `data-open`; the hook calls `showModal()`
  or `close()` to synchronize to the browser. The caller-facing panel ID
  stays on the inner `<aside>` so existing selectors and form integrations
  remain valid.

  ## Examples

      <.drawer id="user-form" open={@show_form} on_close="close_form" title="Edit User">
        <.simple_form for={@form} id="user-edit-form" phx-submit="save">
          <.input field={@form[:name]} type="text" label="Name" class="max-w-3xl" />
        </.simple_form>
      </.drawer>

  """
  attr :id, :string, required: true
  attr :open, :boolean, default: false
  attr :on_close, :string, default: "close_drawer"
  attr :target, :any, default: nil
  attr :title, :string, required: true
  attr :initial_focus, :atom, values: [:heading, :first_field], default: :heading
  attr :initial_focus_id, :string, default: nil
  attr :return_focus_id, :string, default: nil
  attr :close_on_backdrop, :boolean, default: true
  attr :class, :string, default: "max-w-[min(100vw,48rem)]"
  slot :inner_block, required: true
  slot :header_actions

  def drawer(assigns) do
    ~H"""
    <dialog
      id={"#{@id}-overlay"}
      phx-mounted={JS.ignore_attributes("open")}
      phx-hook="OverlayDialog"
      data-open={to_string(@open)}
      data-initial-focus={to_string(@initial_focus)}
      data-initial-focus-id={@initial_focus_id}
      data-return-focus-id={@return_focus_id}
      data-close-on-backdrop={to_string(@close_on_backdrop)}
      aria-labelledby={"#{@id}-title"}
      {if @open, do: %{role: "dialog", "aria-modal": "true"}, else: %{inert: true, "aria-hidden": "true"}}
      class="m-0 border-0 w-full h-full max-w-none max-h-none overflow-hidden bg-transparent p-0"
    >
      <aside
        id={@id}
        aria-labelledby={"#{@id}-title"}
        data-dialog-panel
        tabindex="-1"
        class={[
          "absolute top-0 right-0 h-full w-screen min-w-[320px] bg-base-100 shadow-xl border-l border-base-200 overflow-x-hidden",
          @class
        ]}
      >
        <div class="flex flex-col h-full">
          <%!-- Header --%>
          <header class="flex items-center justify-between px-6 py-4 bg-base-200 border-b border-base-300">
            <div class="flex items-center gap-3">
              <h2 id={"#{@id}-title"} class="text-lg font-semibold" tabindex="-1">
                {@title}
              </h2>
              {render_slot(@header_actions)}
            </div>
            <div class="tooltip tooltip-left" data-tip={gettext("close")}>
              <button
                type="button"
                id={"#{@id}-close"}
                phx-click={@on_close}
                phx-target={@target}
                data-dialog-dismiss
                class="btn btn-ghost btn-sm btn-circle min-w-[44px] min-h-[44px] text-base-content/70 hover:bg-base-300/50"
                aria-label={gettext("close")}
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>
          </header>
          <%!-- Content --%>
          <div id={"#{@id}-body"} class="flex-1 overflow-y-auto p-6">
            {render_slot(@inner_block)}
          </div>
        </div>
      </aside>
    </dialog>
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

  attr :active_tab, :atom,
    values: [:details, :diagram, :report, :reachability],
    default: :details

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
      <div class="flex flex-wrap items-center justify-between gap-2 py-3">
        <div class="flex items-center gap-2 min-w-0">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops"}
            class="btn btn-ghost btn-square min-h-11 min-w-11"
            aria-label="Back to stations list"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <h1 class="text-xl font-semibold leading-tight break-words min-w-0">
            {@station.stop_name || @station.stop_id}
          </h1>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>
      <div class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300">
        <div class="flex flex-wrap items-end gap-1">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}"}
            class={sub_nav_link_class(@active_tab == :details)}
            aria-current={@active_tab == :details && "page"}
          >
            Details
          </.link>
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}/diagram"}
            class={sub_nav_link_class(@active_tab == :diagram)}
            aria-current={@active_tab == :diagram && "page"}
          >
            Diagram
          </.link>
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}/report"}
            class={sub_nav_link_class(@active_tab == :report)}
            aria-current={@active_tab == :report && "page"}
          >
            Reports
          </.link>
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/stops/#{@station.stop_id}/reachability"}
            class={sub_nav_link_class(@active_tab == :reachability)}
            aria-current={@active_tab == :reachability && "page"}
          >
            Reachability
          </.link>
        </div>

        <div :if={@active_tab == :diagram} class="flex flex-wrap items-center gap-4 pb-2">
          <div class="flex flex-wrap items-center gap-2">
            <.button
              type="button"
              size="sm"
              variant="secondary"
              class="border-base-300 bg-base-100 text-base-content hover:bg-base-200"
              phx-click="open_add_level"
            >
              Add level
            </.button>

            <.button
              :if={@active_level}
              type="button"
              size="sm"
              variant="secondary"
              class="border-base-300 bg-base-100 text-base-content hover:bg-base-200"
              phx-click="open_edit_level"
            >
              Edit level
            </.button>

            <.button
              type="button"
              size="sm"
              variant="secondary"
              class="border-base-300 bg-base-100 text-base-content hover:bg-base-200"
              phx-click="open_naming_drawer"
            >
              Apply naming
            </.button>
          </div>

          <div :if={@active_level && @uploads} class="flex flex-wrap items-center gap-2">
            <form
              id="diagram-upload-form-sub-nav"
              phx-change="upload_diagram"
            >
              <label class="btn btn-sm btn-outline cursor-pointer border-base-300 bg-base-100 text-base-content hover:bg-base-200">
                {if @has_diagram, do: "Replace diagram", else: "Upload diagram"}
                <.live_file_input
                  upload={@uploads.diagram}
                  id="station-sub-nav-upload"
                  class="hidden"
                />
              </label>
            </form>
            <span :for={error <- upload_errors(@uploads.diagram)} class="text-error text-sm">
              {diagram_upload_error_to_string(error)}
            </span>
            <%= for entry <- @uploads.diagram.entries do %>
              <span :for={error <- upload_errors(@uploads.diagram, entry)} class="text-error text-sm">
                {diagram_upload_error_to_string(error)}
              </span>
            <% end %>
            <span :if={@diagram_error} class="text-error text-sm">{@diagram_error}</span>
          </div>
        </div>
      </div>
    </nav>
    """
  end

  defp sub_nav_link_class(is_active) do
    base =
      "inline-flex items-center px-3 py-2.5 min-h-11 text-sm transition-colors border-b-2 -mb-px focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"

    state =
      if is_active do
        "font-semibold border-primary text-base-content"
      else
        "font-medium border-transparent text-base-content/60 hover:text-base-content hover:border-base-300"
      end

    [base, state]
  end

  defp diagram_upload_error_to_string(:too_large), do: "File is too large (max 10 MB)"

  defp diagram_upload_error_to_string(:not_accepted),
    do: "File type not accepted (PNG, JPG, JPEG, SVG only)"

  defp diagram_upload_error_to_string(:too_many_files),
    do: "Only one file can be uploaded at a time"

  defp diagram_upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp diagram_upload_error_to_string({:error, reason}), do: reason
  defp diagram_upload_error_to_string(error) when is_binary(error), do: error
  defp diagram_upload_error_to_string(_), do: "Upload error"

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
      <div class="flex flex-wrap items-center justify-between gap-2 py-3">
        <div class="flex items-center gap-2 min-w-0">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/routes"}
            class="btn btn-ghost btn-square min-h-11 min-w-11"
            aria-label="Back to routes list"
          >
            <.icon name="hero-chevron-left" class="size-5" />
          </.link>
          <h1 class="text-xl font-semibold leading-tight break-words min-w-0">
            {@route_display}
          </h1>
        </div>
      </div>
      <div class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300">
        <div class="flex flex-wrap items-end gap-1">
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}"}
            class={sub_nav_link_class(@active_tab == :details)}
            aria-current={@active_tab == :details && "page"}
          >
            Details
          </.link>
          <.link
            navigate={"/gtfs/#{@gtfs_version_id}/routes/#{@route.route_id}/patterns"}
            class={sub_nav_link_class(@active_tab == :patterns)}
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
  Renders an inline callout for view-level state the user must not miss.

  Use one `kind` per notice. The state color appears on the left border only;
  the title stays in `base-content`. Put any link or action inside the body.

  ## Examples

      <.callout kind="warning" title="3 stops have no coordinates">
        They will not appear on the map. Fix them before publishing.
        <.link navigate={~p"/stops"} class="text-primary underline">View stops</.link>
      </.callout>
  """
  attr :kind, :string, required: true, values: ~w(info success warning error)
  attr :title, :string, required: true
  attr :rest, :global
  slot :inner_block

  def callout(assigns) do
    wrappers = %{
      "info" => "border-l-4 border-info bg-info/10 px-4 py-3",
      "success" => "border-l-4 border-success bg-success/10 px-4 py-3",
      "warning" => "border-l-4 border-warning bg-warning/10 px-4 py-3",
      "error" => "border-l-4 border-error bg-error/10 px-4 py-3"
    }

    assigns = assign(assigns, :wrapper_class, Map.fetch!(wrappers, assigns.kind))

    ~H"""
    <div class={@wrapper_class} {@rest}>
      <p class="font-medium text-base-content">{@title}</p>
      <div :if={@inner_block != []} class="mt-0.5 text-sm text-base-content/70">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a status badge with a colored dot and a colored word.

  One vocabulary for every status in the app. Known values map to explicit
  human labels and tones; unrecognized or blank values render `Unknown` with
  a neutral treatment. Pass `label` to override the displayed word.

  ## Examples

      <.status_badge status={:pass} />
      <.status_badge status="running" />
      <.status_badge status={run.status} label="In progress" />
  """
  attr :status, :any, required: true, doc: "the status value, as a string or atom"
  attr :label, :string, default: nil, doc: "overrides the displayed word"
  attr :class, :any, default: nil, doc: "extra classes for sizing tweaks"
  attr :rest, :global

  @status_presentation %{
    "pass" => {"Pass", "bg-success", "text-success"},
    "completed" => {"Completed", "bg-success", "text-success"},
    "warning" => {"Warning", "bg-warning", "text-warning"},
    "failed" => {"Failed", "bg-error", "text-error"},
    "error" => {"Error", "bg-error", "text-error"},
    "running" => {"Running", "bg-info", "text-info"},
    "info" => {"Info", "bg-info", "text-info"},
    "started" => {"Started", "bg-base-content/40", "text-base-content/60"},
    "draft" => {"Draft", "bg-base-content/40", "text-base-content/60"},
    "in_progress" => {"In progress", "bg-info", "text-info"}
  }

  @status_unknown {"Unknown", "bg-base-content/40", "text-base-content/60"}

  def status_badge(assigns) do
    status = to_string(assigns.status)
    {label, dot_class, text_class} = Map.get(@status_presentation, status, @status_unknown)

    assigns =
      assigns
      |> assign(:dot_class, dot_class)
      |> assign(:text_class, text_class)
      |> assign(:word, assigns.label || label)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 border border-base-300 px-2 py-0.5 text-sm",
        @class
      ]}
      {@rest}
    >
      <span class={["size-1.5 rounded-full", @dot_class]} aria-hidden="true"></span>
      <span class={["font-medium", @text_class]}>{@word}</span>
    </span>
    """
  end

  @doc """
  Renders an empty state for a data view.

  First-use empties explain what belongs here and give a primary CTA to create
  or import the first item. Filtered/search empties repeat the query and offer
  the undo of the filter (clear search) instead. The caller supplies the CTA in
  the `action` slot.

  ## Examples

      <.empty_state title="No stations yet">
        Stations appear here after you import a GTFS feed.
        <:action><.button navigate={~p"/import"}>Import feed</.button></:action>
      </.empty_state>
  """
  attr :title, :string, required: true
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block
  slot :action, doc: "one CTA; the caller supplies the button or link"

  def empty_state(assigns) do
    ~H"""
    <div class={["border border-base-300 p-8 text-center", @class]} {@rest}>
      <p class="font-semibold">{@title}</p>
      <div :if={@inner_block != []} class="mt-1 text-sm text-base-content/70">
        {render_slot(@inner_block)}
      </div>
      <div :if={@action != []} class="mt-4">
        {render_slot(@action)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a first-paint loading skeleton that mirrors a table layout.

  Show it only for the first paint of a slow view, never to replace content
  already on screen. The bars animate under `motion-safe:` and are hidden from
  assistive tech; the label is visually available above the bars.
  Callers needing exact column mirroring pass their own bars as the inner block.

  ## Examples

      <.skeleton rows={5} label="Loading routes" />
  """
  attr :rows, :integer, default: 3
  attr :label, :string, default: "Loading", doc: "visually available loading copy"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, doc: "replaces the default bars for exact column mirroring"

  def skeleton(assigns) do
    ~H"""
    <div class={@class} {@rest}>
      <p class="text-sm text-base-content/60 mb-2">{@label}</p>
      <div
        :if={@inner_block == []}
        class="space-y-3 motion-safe:animate-pulse"
        aria-hidden="true"
      >
        <div :for={_row <- 1..@rows} class="flex gap-4">
          <div class="h-4 w-10 bg-base-300"></div>
          <div class="h-4 flex-1 bg-base-300"></div>
          <div class="h-4 w-16 bg-base-300"></div>
        </div>
      </div>
      <div :if={@inner_block != []} class="motion-safe:animate-pulse" aria-hidden="true">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a focused confirmation dialog for a destructive action.

  Fully server-owned. Renders a native `<dialog>` backed by the
  `OverlayDialog` hook. Focus lands on Cancel. Escape fires Cancel
  through the hook; the backdrop does not dismiss by default.

  `on_confirm` and `on_cancel` are event name strings. Use `phx-target`
  when the owner is a `LiveComponent`. Supply `described_by` when the
  body contains additional description beyond the title, and render a
  matching concise descendant inside the dialog.

  ## Examples

      <.confirm_dialog
        id="delete-route"
        open={@confirm_open}
        title="Delete route 42?"
        confirm_label="Delete route"
        pending_label="Deleting…"
        on_confirm="delete_route"
        on_cancel="cancel_delete"
        pending={@deleting}
        described_by="delete-route-body"
      >
        This removes the route and its 214 trips from version 2026-01. It cannot be undone.
      </.confirm_dialog>
  """
  attr :id, :string, required: true
  attr :open, :boolean, required: true
  attr :title, :string, required: true
  attr :confirm_label, :string, required: true
  attr :pending_label, :string, required: true
  attr :on_confirm, :string, required: true
  attr :on_cancel, :string, required: true
  attr :target, :any, default: nil
  attr :pending, :boolean, default: false
  attr :return_focus_id, :string, default: nil
  attr :described_by, :string, default: nil
  attr :close_on_backdrop, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  def confirm_dialog(assigns) do
    extra = Map.new(assigns.rest || %{})

    extra =
      if assigns.described_by,
        do: Map.put(extra, "aria-describedby", assigns.described_by),
        else: extra

    extra =
      if assigns.open,
        do: Map.merge(extra, %{role: "alertdialog", "aria-modal": "true"}),
        else: Map.merge(extra, %{inert: true, "aria-hidden": "true"})

    assigns = assign(assigns, :extra, extra)

    ~H"""
    <dialog
      id={@id}
      phx-mounted={JS.ignore_attributes("open")}
      phx-hook="OverlayDialog"
      data-open={to_string(@open)}
      data-close-on-backdrop={to_string(@close_on_backdrop)}
      data-pending={to_string(@pending)}
      data-return-focus-id={@return_focus_id}
      aria-labelledby={"#{@id}-title"}
      {@extra}
      class="m-0 border-0 w-full h-full bg-transparent p-0"
    >
      <div class="w-full h-full flex items-center justify-center p-4">
        <div class="w-full max-w-sm border border-base-300 bg-base-100 p-5">
          <h3 id={"#{@id}-title"} class="font-semibold">{@title}</h3>
          <div id={"#{@id}-body"} class="mt-1 text-sm text-base-content/70">
            {render_slot(@inner_block)}
          </div>
          <div class="mt-4 flex justify-end gap-2">
            <button
              id={"#{@id}-cancel"}
              type="button"
              class="h-[44px] min-w-[44px] border border-base-300 px-4 text-sm font-semibold"
              phx-click={@on_cancel}
              phx-target={@target}
              data-dialog-dismiss
              disabled={@pending}
            >
              Cancel
            </button>
            <button
              id={"#{@id}-confirm"}
              type="button"
              class="h-[44px] min-w-[44px] bg-error px-4 text-sm font-semibold text-error-content"
              phx-click={@on_confirm}
              phx-target={@target}
              phx-disable-with={@pending_label}
              disabled={@pending}
            >
              {if @pending, do: @pending_label, else: @confirm_label}
            </button>
          </div>
        </div>
      </div>
    </dialog>
    """
  end

  @doc """
  Renders a file upload field with Phoenix LiveView's UploadConfig.

  Experimental. Presents a labeled native file input, constraints, entry progress,
  cancellation, rejection, and failure states. Does not consume or persist files.

  ## Examples

      <.upload_field
        id="feed-upload"
        upload={@uploads.feed}
        label="GTFS feed"
        help="ZIP file, max 50MB"
        cancel_event="cancel_upload"
      />
  """
  attr :id, :string, required: true
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :label, :string, required: true
  attr :help, :string, required: true
  attr :cancel_event, :string, required: true
  attr :target, :any, default: nil
  attr :error, :string, default: nil
  slot :failure, doc: "view-level failure message"

  def upload_field(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <label for={"#{@id}-input"} class="block text-sm font-semibold">
        {@label}
      </label>
      <p id={"#{@id}-help"} class="text-sm text-base-content/60">
        {@help}
      </p>

      <label
        for={"#{@id}-input"}
        class="block border-2 border-dashed border-base-300 rounded-lg p-4 cursor-pointer hover:border-primary focus-within:border-primary focus-within:ring-2 focus-within:ring-primary/20"
      >
        <span class="text-sm text-base-content/70">
          Click to select a file or drag and drop
        </span>
        <.live_file_input upload={@upload} id={"#{@id}-input"} class="sr-only" />
      </label>

      <p :if={@error} id={"#{@id}-error"} class="text-sm text-error">
        {@error}
      </p>

      <div :if={@failure != []} id={"#{@id}-failure"} class="text-sm text-error">
        {render_slot(@failure)}
      </div>

      <ul :if={@upload.entries != []} id={"#{@id}-entries"} class="space-y-2">
        <li
          :for={entry <- @upload.entries}
          id={"#{@id}-entry-#{entry.ref}"}
          class="flex items-center gap-2"
        >
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium truncate" title={entry.client_name}>
              {entry.client_name}
            </p>
            <div class="flex items-center gap-2 mt-1">
              <div class="flex-1 h-2 bg-base-300 rounded-full overflow-hidden">
                <div
                  class="h-full bg-primary transition-all"
                  style={"width: #{entry.progress}%"}
                >
                </div>
              </div>
              <span class="text-xs text-base-content/60 tabular-nums">
                {entry.progress}%
              </span>
            </div>
            <ul :if={upload_errors(@upload, entry) != []} class="mt-1 text-xs text-error">
              <li :for={error <- upload_errors(@upload, entry)}>
                {translate_error(error)}
              </li>
            </ul>
          </div>
          <button
            type="button"
            class="h-11 w-11 flex items-center justify-center text-base-content/60 hover:text-error"
            phx-click={@cancel_event}
            phx-value-ref={entry.ref}
            phx-target={@target}
            aria-label={"Cancel #{entry.client_name}"}
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </li>
      </ul>

      <ul :if={@upload.errors != []} id={"#{@id}-rejected"} class="text-sm text-error">
        <li :for={error <- @upload.errors}>
          {upload_error_to_string(error)}
        </li>
      </ul>
    </div>
    """
  end

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:too_many_files), do: "Too many files"
  defp upload_error_to_string(:not_accepted), do: "File type not accepted"
  defp upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp upload_error_to_string({:error, reason}), do: reason
  defp upload_error_to_string(error) when is_binary(error), do: error
  defp upload_error_to_string(error) when is_atom(error), do: Atom.to_string(error)
  defp upload_error_to_string(_), do: "Upload error"

  @doc """
  Renders a pressed filter button with aria-pressed state.

  Experimental. A toggle button for filtering data. Server-owned pressed state,
  pending/disabled copy, configured event/value/target.

  ## Examples

      <.pressed_filter
        id="filter-active"
        pressed={@filter_active}
        event="toggle_filter"
        value="active"
        label="Active"
      />
  """
  attr :id, :string, required: true
  attr :pressed, :boolean, required: true
  attr :event, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :target, :any, default: nil
  attr :pending, :boolean, default: false
  attr :pending_label, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :disabled_reason, :string, default: nil

  def pressed_filter(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={[
        "h-11 min-w-[44px] px-4 text-sm font-semibold border rounded-lg transition-colors",
        @pressed && "bg-primary text-primary-content border-primary",
        !@pressed && "bg-base-100 text-base-content border-base-300 hover:border-primary",
        @disabled && "opacity-50 cursor-not-allowed"
      ]}
      phx-click={@event}
      phx-value={@value}
      phx-target={@target}
      phx-disable-with={if @pending, do: @pending_label || "Loading…", else: nil}
      aria-pressed={to_string(@pressed)}
      disabled={@disabled || @pending}
      title={if @disabled, do: @disabled_reason, else: nil}
    >
      {if @pending, do: @pending_label || "Loading…", else: @label}
    </button>
    """
  end

  @doc """
  Renders a segmented control with native radio inputs.

  Experimental. A fieldset with visible legend and native same-name radio group.
  Server-owned selected value, configured event/target, disabled explanation.

  ## Examples

      <.segmented_control
        id="view-mode"
        name="view_mode"
        legend="View mode"
        options={[{"List", "list"}, {"Map", "map"}, {"Table", "table"}]}
        value={@view_mode}
        event="change_view"
      />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :legend, :string, required: true
  attr :options, :list, required: true
  attr :value, :string, required: true
  attr :event, :string, required: true
  attr :target, :any, default: nil
  attr :disabled, :boolean, default: false
  attr :disabled_reason, :string, default: nil

  def segmented_control(assigns) do
    ~H"""
    <fieldset id={@id} class="space-y-2" disabled={@disabled}>
      <legend class="text-sm font-semibold">{@legend}</legend>
      <p :if={@disabled && @disabled_reason} class="text-xs text-base-content/60">
        {@disabled_reason}
      </p>
      <div class="flex flex-wrap gap-2">
        <label
          :for={{label, val} <- @options}
          class={[
            "h-11 min-w-[44px] px-4 flex items-center justify-center text-sm font-semibold border rounded-lg cursor-pointer transition-colors",
            @value == val && "bg-primary text-primary-content border-primary",
            @value != val && "bg-base-100 text-base-content border-base-300 hover:border-primary"
          ]}
        >
          <input
            type="radio"
            name={@name}
            value={val}
            checked={@value == val}
            class="sr-only"
            phx-click={@event}
            phx-value={val}
            phx-target={@target}
          />
          {label}
        </label>
      </div>
    </fieldset>
    """
  end

  @doc """
  Translates an error message using gettext.

  Accepts the `{msg, opts}` tuple produced by Ecto changesets as well as a
  bare string (used by callers that pass explicit error text), so a field may
  carry either shape without raising.
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

  def translate_error(msg) when is_binary(msg), do: msg

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end

defmodule GtfsPlannerWeb.Gtfs.FareEditorComponents do
  @moduledoc """
  The fare editor shell's own pieces: the one header primary each tab carries,
  and the two states that replace the tab body while the version's fares are
  still resolving or could not be read.

  The shell is the page frame every fare tab draws into — the Settings back
  link, the "Fares" heading and its lede, the five tabs and the one primary
  action for the tab — so the parts that decide *what* the header shows live
  here and the tab bodies are added to the LiveView beside them.

  `loading/1` is the first-paint skeleton and `load_error/1` the single
  recovery action: a lost database connection is reported once, with the
  version's saved fares described as untouched, rather than presenting an
  empty workspace as the version's data.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  @doc """
  Renders the fare editor's one header primary for the current tab, or nothing.

  One primary per view, and it follows the tab's own task: Create fare on
  Prices, Add fare rule on Where fares apply and Add transfer rule on
  Transfers. Checks has none — it reports what it finds rather than asking for
  a change — and the Zones tab belongs to the zone workspace.

  The action is disabled until the version's fares have loaded, because a
  create action offered over an empty workspace would write against data the
  operator never saw. Transfers shows its action only once the version holds a
  transfer rule, which is what the prototype does: a version with none has
  nothing to add a rule beside.

  The buttons carry no event yet: each tab's drawer arrives with the tab's own
  body, and a click that opened nothing would be worse than one that does not
  yet exist.

  ## Examples

      <.header_primary active_tab={:prices} ready?={@load_state == :ready} />
  """
  attr :active_tab, :atom, required: true, doc: "the tab this page renders"
  attr :ready?, :boolean, default: false, doc: "whether the version's fares have loaded"
  attr :transfers?, :boolean, default: false, doc: "whether the version holds a transfer rule"

  def header_primary(assigns) do
    ~H"""
    <%= case header_action(@active_tab, @ready?, @transfers?) do %>
      <% :none -> %>
      <% {:button, id, label} -> %>
        <.button id={id} class="min-h-11" disabled={not @ready?}>
          <.icon name="hero-plus" class="size-4" /> {label}
        </.button>
    <% end %>
    """
  end

  # The tab's own primary, named once so the label and the id cannot drift from
  # each other. `:none` is a real answer for a tab that offers no action.
  defp header_action(:prices, true, _transfers?), do: {:button, "create-fare", "Create fare"}
  defp header_action(:where, true, _transfers?), do: {:button, "add-fare-rule", "Add fare rule"}

  defp header_action(:transfers, true, true),
    do: {:button, "add-transfer-rule", "Add transfer rule"}

  defp header_action(_active_tab, _ready?, _transfers?), do: :none

  @doc """
  Renders the shell's first-paint skeleton.

  Shown while the connected load is still resolving, so the tab body never
  paints as an unexplained blank region. The block widths mirror the header
  and the first rows of a fare table, which is what the tab shows when it
  arrives.

  ## Examples

      <.loading />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def loading(assigns) do
    ~H"""
    <div
      id="fare-editor-loading"
      role="status"
      aria-busy="true"
      class={["overflow-clip rounded-card border border-subtle bg-white", @class]}
      {@rest}
    >
      <div class="motion-safe:animate-pulse" aria-hidden="true">
        <div class="flex gap-3 border-b border-subtle px-5 py-4">
          <div class="h-4 w-32 rounded-badge bg-canvas"></div>
          <div class="h-4 w-40 rounded-badge bg-canvas"></div>
          <div class="h-4 w-28 rounded-badge bg-canvas"></div>
          <div class="h-4 w-24 rounded-badge bg-canvas"></div>
        </div>
        <div :for={_row <- 1..5} class="flex items-center gap-4 border-b border-subtle px-5 py-4">
          <div class="h-3.5 w-2/5 rounded-badge bg-canvas"></div>
          <div class="h-3.5 flex-1 rounded-badge bg-canvas"></div>
          <div class="h-3.5 w-20 rounded-badge bg-canvas"></div>
        </div>
      </div>
      <p class="px-5 py-3 text-sm text-muted">Loading fares…</p>
    </div>
    """
  end

  @doc """
  Renders the shell's load-error state with its single recovery action.

  The title names what failed and the body says the saved data is untouched, so
  the operator can retry without doubting the version's fares.

  ## Examples

      <.load_error />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def load_error(assigns) do
    ~H"""
    <div id="fare-editor-error" class={@class} {@rest}>
      <.message kind="error" title="Fares couldn’t load">
        Nothing you saved is affected. Routes, calendars and stops still open from the menu.
        <:action>
          <.button id="fare-editor-reload" phx-click="reload" class="min-h-11">
            <.icon name="hero-arrow-path" class="size-4" /> Reload fares
          </.button>
        </:action>
      </.message>
    </div>
    """
  end
end

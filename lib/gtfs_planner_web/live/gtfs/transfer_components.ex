defmodule GtfsPlannerWeb.Gtfs.TransferComponents do
  @moduledoc """
  Presentation for the Routes › Transfers page.

  The page shell is one bordered workspace split into the version's general
  rules on the left and the selected connection's context on the right. Each
  pane's own body arrives with the step that owns it, so this module renders the
  shell's states today: the list-pane load failure with its retry, the first-use
  state for a version without general rules, and the context pane before a
  connection is chosen.

  The states reuse the shared callout and empty state rather than the visual
  reference's own state boxes, so a failed load and an empty list read the same
  way here as they do on Routes. The reference is authority for the composition,
  the state copy and the label hierarchy; the application is authority for the
  components, the theme tokens and the accessibility posture.
  """

  use GtfsPlannerWeb, :html

  @doc """
  Renders the two-pane transfer workspace.

  The list pane is the wider column (about 55%) from `lg` up, with the context
  pane beside it and a divider between them; below `lg` the two panes stack so a
  phone-width viewport never scrolls sideways.

  ## Examples

      <.workspace>
        <:list><.first_use /></:list>
        <:context><.context_empty /></:context>
      </.workspace>
  """
  slot :list, required: true, doc: "the rule list pane"
  slot :context, required: true, doc: "the selected connection's context pane"

  def workspace(assigns) do
    ~H"""
    <div class="mt-6 overflow-hidden rounded-box border border-base-300 bg-base-100 lg:grid lg:grid-cols-[11fr_9fr] lg:items-start">
      <section class="min-w-0 lg:border-r lg:border-base-300" aria-label="Transfer rules">
        {render_slot(@list)}
      </section>
      <section
        class="min-w-0 border-t border-base-300 lg:border-t-0"
        aria-label="Connection preview"
      >
        {render_slot(@context)}
      </section>
    </div>
    """
  end

  @doc """
  Renders the list pane's state when the transfer catalog could not load.

  The copy says what failed and what did not change, because a lost database
  connection leaves every stored rule intact. The retry reloads through the same
  adapter the first load used.

  ## Examples

      <.load_failure />
  """
  def load_failure(assigns) do
    ~H"""
    <div id="transfers-unavailable" class="p-4 sm:p-6">
      <.callout kind="error" title="Transfers couldn’t load">
        Your rules haven’t changed. Try loading this version again.
        <.button
          id="transfers-retry"
          phx-click="retry_load"
          variant="secondary"
          size="sm"
          class="mt-2"
        >
          Retry loading
        </.button>
      </.callout>
    </div>
    """
  end

  @doc """
  Renders the list pane's first-use state for a version without general rules.

  It differs from the filtered-empty state a later step adds: nothing is hidden
  by a filter here, so the copy explains what a rule is for rather than undoing a
  query. The caller supplies the "Create transfer" action once the editor exists;
  until then the state stands on its own with no control to offer.

  ## Examples

      <.first_use />
  """
  attr :class, :any, default: nil
  slot :action, doc: "the primary action that creates the version's first rule"

  def first_use(assigns) do
    ~H"""
    <div id="transfers-first-use" class={["p-4 sm:p-6", @class]}>
      <.empty_state title="Make connections clearer">
        Add a rule when riders need a specific connection, extra time, or a different transfer point. Journey planners can infer transfers without these rules.
        <:action :if={@action != []}>
          {render_slot(@action)}
        </:action>
      </.empty_state>
    </div>
    """
  end

  @doc """
  Renders the context pane before any connection is chosen.

  ## Examples

      <.context_empty />
  """
  def context_empty(assigns) do
    ~H"""
    <div id="transfer-inspector-empty" class="p-4 sm:p-6">
      <h2 class="text-xl font-semibold">A little context goes a long way</h2>
      <p class="mt-3 text-sm text-base-content/70">
        Choose a connection to see where riders arrive, where they board next, and which rule applies.
      </p>
    </div>
    """
  end
end

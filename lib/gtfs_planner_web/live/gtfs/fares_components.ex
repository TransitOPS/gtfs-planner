defmodule GtfsPlannerWeb.Gtfs.FaresComponents do
  @moduledoc """
  Function components for the Fare zones workspace.

  This module owns the workspace's non-ideal states: the first-paint skeleton
  the disconnected render shows, and the load-error callout that names what
  failed and offers the one recovery action. The skeleton mirrors the workspace
  body rather than replacing content already on screen, and the error copy states
  that saved zones are unchanged, so a failed read is never mistaken for lost
  work.

  The Zones, Fare rules and Checks bodies are added beside these components by
  the following steps.
  """

  use GtfsPlannerWeb, :html

  @doc """
  Renders the workspace's first-paint skeleton.

  Shown while the connected load is still resolving, so the tab body never paints
  as an unexplained blank region.

  ## Examples

      <.loading />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def loading(assigns) do
    ~H"""
    <.skeleton
      id="fare-zones-loading"
      rows={4}
      label="Loading fare zones…"
      role="status"
      aria-busy="true"
      class={["py-6", @class]}
      {@rest}
    />
    """
  end

  @doc """
  Renders the workspace's load-error state with its single recovery action.

  The title names what failed and the body says the saved data is untouched, so
  the operator can retry without doubting the version's data.

  ## Examples

      <.load_error />
  """
  attr :class, :any, default: nil
  attr :rest, :global

  def load_error(assigns) do
    ~H"""
    <div id="fare-zones-error" class={["mt-2", @class]} {@rest}>
      <.callout kind="error" title="Fare zones couldn’t load">
        <p>Your saved zones haven’t changed. Try loading this version again.</p>
        <%!-- The callout body renders inline, so the block wrapper is what keeps
        the action below the message instead of on top of it. --%>
        <div class="mt-3">
          <.button id="fare-zones-reload" phx-click="reload" class="min-h-11">
            Reload fare zones
          </.button>
        </div>
      </.callout>
    </div>
    """
  end
end

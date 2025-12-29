defmodule GtfsPlannerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use GtfsPlannerWeb, :html

  alias GtfsPlannerWeb.Navigation

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_user, :map,
    default: nil,
    doc: "the current user"

  attr :current_organization, :map,
    default: nil,
    doc: "the current organization context"

  attr :user_roles, :list,
    default: [],
    doc: "list of role strings for the current user in the current organization"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a href="#main-content" class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:p-4 focus:bg-base-100">
      Skip to main content
    </a>
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <.link href={~p"/"} class="text-xl font-bold tracking-tight" aria-label="GTFS Planner - Go to homepage">
          GTFS Planner
        </.link>
      </div>
      <%= if @current_user do %>
        <div class="flex-none flex items-center gap-4">
          <.theme_toggle />
          <.link href={~p"/users/log_out"} method="delete" class="btn btn-ghost" aria-label="Log out of your account">
            Log out
          </.link>
        </div>
      <% else %>
        <div class="flex-none">
          <.theme_toggle />
        </div>
      <% end %>
    </header>

    <%= if @current_user do %>
      <div class="flex">
        <Navigation.sidebar
          current_user={@current_user}
          current_organization={assigns[:current_organization]}
          user_roles={@user_roles}
        />
        <main id="main-content" class="flex-1 px-4 py-20 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-2xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    <% else %>
      <main id="main-content" class="px-4 py-20 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-2xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
      role="group"
      aria-label="Theme selection"
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-3 cursor-pointer w-1/3 focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2 rounded-l-full"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
        title="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4" />
      </button>

      <button
        class="flex p-3 cursor-pointer w-1/3 focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
        title="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4" />
      </button>

      <button
        class="flex p-3 cursor-pointer w-1/3 focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2 rounded-r-full"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
        title="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4" />
      </button>
    </div>
    """
  end
end

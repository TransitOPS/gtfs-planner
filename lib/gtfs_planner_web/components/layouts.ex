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

  attr :current_path, :string,
    default: "/",
    doc: "the current URL path for tab highlighting"

  attr :current_gtfs_version, :map,
    default: nil,
    doc: "the current GTFS version (for GTFS pages)"

  attr :available_versions, :list,
    default: [],
    doc: "list of {id, name} tuples for GTFS version dropdown"

  slot :inner_block, required: true
  slot :sub_header, doc: "optional full-width sub-header rendered between header and main content"

  def app(assigns) do
    ~H"""
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:p-4 focus:bg-base-100"
    >
      Skip to main content
    </a>
    <header
      id="app-header"
      class="navbar bg-base-100 px-4 sm:px-6 lg:px-8 py-3 border-b border-base-300 items-center"
    >
      <div class="flex-none">
        <.link
          href={~p"/"}
          class="flex items-center gap-2"
          aria-label="Pathways Studio - Go to homepage"
        >
          <div class="bg-emerald-600 p-2 rounded-lg">
            <img src={~p"/images/gtfs-logo.svg"} alt="" class="h-8 w-8 brightness-0 invert" />
          </div>
          <span class="text-xl font-semibold tracking-tight text-emerald-700">Pathways Studio</span>
        </.link>
      </div>

      <%= if @current_user do %>
        <div class="flex-1 flex justify-start items-center pl-8">
          <Navigation.top_nav
            current_user={@current_user}
            current_organization={assigns[:current_organization]}
            user_roles={@user_roles}
            current_path={@current_path}
            current_gtfs_version={@current_gtfs_version}
          />
        </div>
        <div class="flex-none flex items-center gap-4">
          <%= if @current_gtfs_version && @available_versions != [] do %>
            <.gtfs_version_switcher
              current_version={@current_gtfs_version}
              versions={@available_versions}
              organization_id={@current_organization.id}
            />
          <% end %>
          <.link
            href={~p"/users/log_out"}
            method="delete"
            class="inline-flex items-center gap-1.5 text-gray-600 hover:text-gray-900 transition-colors"
            aria-label="Log out of your account"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="w-5 h-5" />
            <span class="text-sm font-medium">Log out</span>
          </.link>
        </div>
      <% else %>
        <div class="flex-1"></div>
      <% end %>
    </header>

    <%= if @sub_header != [] do %>
      <div id="sub-header-wrapper" class="bg-base-100 border-b border-base-300">
        {render_slot(@sub_header)}
      </div>
    <% end %>

    <%= if @current_user do %>
      <main id="main-content" class="px-4 py-8 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-7xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>
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
  Renders the auth layout for unauthenticated pages like login, registration, etc.

  This layout provides a centered card with logo branding, suitable for authentication flows.

  ## Examples

      <Layouts.auth flash={@flash}>
        <.header>Log in</.header>
        <.simple_form ...>
        </.simple_form>
      </Layouts.auth>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true

  def auth(assigns) do
    ~H"""
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:p-4 focus:bg-base-100"
    >
      Skip to main content
    </a>

    <main id="main-content" class="min-h-screen flex items-start justify-center px-4 py-12 sm:py-16">
      <div class="w-full max-w-md">
        <div class="card bg-base-100 card-border shadow-sm">
          <div class="card-body">
            <div class="flex items-center justify-center gap-3 mb-6">
              <div class="bg-emerald-600 p-2 rounded-lg">
                <img src={~p"/images/gtfs-logo.svg"} alt="" class="h-8 w-8 brightness-0 invert" />
              </div>
              <span class="text-xl font-semibold tracking-tight text-emerald-700">
                Pathways Studio
              </span>
            </div>

            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end
end

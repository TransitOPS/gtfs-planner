defmodule GtfsPlannerWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use GtfsPlannerWeb, :html

  alias GtfsPlannerWeb.Navigation
  alias GtfsPlannerWeb.ProductSurfaces

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # Signed-out pages belong to both products; signed-in pages use the brand of
  # the organization on the connection.
  defp title_suffix(%{current_user: %{}} = assigns) do
    brand = ProductSurfaces.brand(assigns[:current_organization])
    " · " <> ProductSurfaces.name(brand)
  end

  defp title_suffix(_assigns) do
    " · #{ProductSurfaces.name(:planner)} · #{ProductSurfaces.name(:pathways)}"
  end

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
      class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:p-4 focus:bg-base-100 focus:text-base-content"
    >
      Skip to main content
    </a>
    <header
      id="app-header"
      class="relative z-30 border-b border-subtle bg-white font-ds text-strong"
    >
      <div class="px-4 sm:px-6 lg:px-8">
        <div class="mx-auto flex max-w-7xl flex-wrap items-center gap-x-8">
          <.link
            id="app-brand"
            href={~p"/"}
            class="flex min-h-[72px] shrink-0 items-center gap-3.5 no-underline max-md:flex-col max-md:items-start max-md:justify-center max-md:gap-1.5 max-md:py-2"
            aria-label={"#{ProductSurfaces.name(ProductSurfaces.brand(assigns[:current_organization]))}, go to home"}
          >
            <img
              id="app-brand-logo"
              src={ProductSurfaces.logo_path(ProductSurfaces.brand(assigns[:current_organization]))}
              alt=""
              class="h-9 w-fit md:h-11"
            />
            <span
              :if={assigns[:current_organization]}
              aria-hidden="true"
              class="h-8 w-px bg-subtle max-md:hidden"
            />
            <span :if={assigns[:current_organization]} class="text-[13px] leading-none text-muted">
              {assigns[:current_organization].name}
            </span>
          </.link>

          <%= if @current_user do %>
            <Navigation.top_nav
              current_user={@current_user}
              current_organization={assigns[:current_organization]}
              user_roles={@user_roles}
              current_path={@current_path}
              current_gtfs_version={@current_gtfs_version}
            />
            <div class="ml-auto flex min-h-16 flex-wrap items-center justify-end gap-2">
              <%= if @current_organization && @current_gtfs_version && @available_versions != [] do %>
                <.live_component
                  module={GtfsPlannerWeb.Components.GtfsVersionSwitcher}
                  id="gtfs-version-switcher"
                  current_version={@current_gtfs_version}
                  versions={@available_versions}
                  organization_id={@current_organization.id}
                />
              <% end %>
              <Navigation.user_menu
                current_user={@current_user}
                current_path={@current_path}
                current_organization={assigns[:current_organization]}
                user_roles={@user_roles}
                current_gtfs_version={@current_gtfs_version}
              />
            </div>
          <% else %>
            <div class="ml-auto flex-1"></div>
          <% end %>
        </div>
      </div>
    </header>

    <%= if @sub_header != [] do %>
      <div id="sub-header-wrapper" class="bg-base-100 border-b border-base-300">
        <div class="px-4 sm:px-6 lg:px-8">
          <div class="mx-auto w-full max-w-7xl">
            {render_slot(@sub_header)}
          </div>
        </div>
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
    <div id={@id}>
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

  This layout shows both product logos above a centered card, suitable for
  authentication flows. An optional `:footer` slot renders a muted line below
  the card.

  ## Examples

      <Layouts.auth flash={@flash}>
        <.header>Log in</.header>
        <.simple_form ...>
        </.simple_form>
      </Layouts.auth>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true
  slot :footer, doc: "optional muted line rendered below the card"

  def auth(assigns) do
    ~H"""
    <a
      href="#main-content"
      class="sr-only focus:not-sr-only focus:absolute focus:z-50 focus:p-4 focus:bg-base-100 focus:text-base-content"
    >
      Skip to main content
    </a>

    <main
      id="main-content"
      class="min-h-dvh bg-canvas px-4 pb-32 pt-10 font-ds text-default sm:pt-[max(64px,13vh)]"
    >
      <div class="mx-auto w-full max-w-[440px]">
        <div id="auth-brands" class="mb-6 flex items-center gap-5 px-5 sm:gap-6 sm:px-8">
          <img
            src={~p"/images/gtfs-planner-logo.svg"}
            alt="GTFS Planner"
            class="h-11 w-auto sm:h-14"
          />
          <span aria-hidden="true" class="h-10 w-px shrink-0 bg-subtle sm:h-12"></span>
          <img
            src={~p"/images/pathways-studio-logo.svg"}
            alt="Pathways Studio"
            class="h-11 w-auto sm:h-14"
          />
        </div>

        <section class="rounded-card border border-subtle bg-white p-5 shadow-card sm:p-8">
          {render_slot(@inner_block)}
        </section>

        <p :if={@footer != []} class="mt-5 px-5 text-[13px] text-balance text-muted sm:px-8">
          {render_slot(@footer)}
        </p>
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end
end

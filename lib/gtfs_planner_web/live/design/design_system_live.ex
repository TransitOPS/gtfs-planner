defmodule GtfsPlannerWeb.Design.DesignSystemLive do
  @moduledoc """
  In-app design system section at `/design`.

  Owns the ordered page registry, patch navigation between pages, the sidebar and
  content shell, and page-body dispatch. The registry is the single source of page
  slugs, titles, grouping, and order: the sidebar, the dispatch clauses, and the
  tests all derive from `pages/0`.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlannerWeb.Design.ComponentPages
  alias GtfsPlannerWeb.Design.FoundationPages

  @pages [
    %{slug: "introduction", title: "Introduction", group: "Foundations"},
    %{slug: "colors", title: "Colors", group: "Foundations"},
    %{slug: "typography", title: "Typography", group: "Foundations"},
    %{slug: "icons", title: "Icons", group: "Foundations"},
    %{slug: "buttons", title: "Buttons", group: "Components"},
    %{slug: "inputs", title: "Inputs & Forms", group: "Components"},
    %{slug: "feedback", title: "Feedback", group: "Components"},
    %{slug: "tables", title: "Tables & Lists", group: "Components"},
    %{slug: "navigation", title: "Navigation", group: "Components"},
    %{slug: "badges", title: "Badges", group: "Components"},
    %{slug: "overlays", title: "Overlays", group: "Components"},
    %{slug: "autocomplete", title: "Autocomplete", group: "Components"}
  ]

  @doc """
  The ordered page registry backing the sidebar, dispatch, and tests.
  """
  @spec pages() :: [%{slug: String.t(), title: String.t(), group: String.t()}]
  def pages, do: @pages

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page, hd(@pages))}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply, push_patch(socket, to: ~p"/design/#{first_slug()}")}
  end

  def handle_params(%{"page" => slug}, _uri, socket) do
    case Enum.find(@pages, &(&1.slug == slug)) do
      nil ->
        {:noreply, push_patch(socket, to: ~p"/design/#{first_slug()}")}

      page ->
        {:noreply,
         socket
         |> assign(:page, page)
         |> assign(:page_title, page.title <> " · Design System")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={[]}
    >
      <div class="flex gap-8 max-w-6xl mx-auto">
        <nav id="design-sidebar" aria-label="Design system" class="w-56 shrink-0">
          <div :for={{group, entries} <- page_groups()} class="mb-6">
            <h2 class="text-xs font-semibold text-base-content/60 mb-2">{group}</h2>
            <ul class="menu menu-sm p-0 gap-1 w-full">
              <li :for={entry <- entries}>
                <.link
                  patch={~p"/design/#{entry.slug}"}
                  aria-current={@page.slug == entry.slug && "page"}
                  class={["block", @page.slug == entry.slug && "active font-semibold"]}
                >
                  {entry.title}
                </.link>
              </li>
            </ul>
          </div>
        </nav>
        <div id="design-page-content" class="min-w-0 flex-1">{page_body(assigns)}</div>
      </div>
    </Layouts.app>
    """
  end

  defp first_slug, do: hd(@pages).slug

  # Groups the registry for the sidebar while preserving registry order. Map key
  # order would sort the groups alphabetically, so the order comes from the
  # registry itself rather than from `Enum.group_by/2`.
  defp page_groups do
    grouped = Enum.group_by(pages(), & &1.group)

    pages()
    |> Enum.map(& &1.group)
    |> Enum.uniq()
    |> Enum.map(&{&1, grouped[&1]})
  end

  defp page_body(%{page: %{slug: "introduction"}} = assigns),
    do: FoundationPages.introduction(assigns)

  defp page_body(%{page: %{slug: "colors"}} = assigns), do: FoundationPages.colors(assigns)

  defp page_body(%{page: %{slug: "typography"}} = assigns),
    do: FoundationPages.typography(assigns)

  defp page_body(%{page: %{slug: "icons"}} = assigns), do: FoundationPages.icons(assigns)

  defp page_body(%{page: %{slug: "buttons"}} = assigns), do: ComponentPages.buttons(assigns)

  defp page_body(%{page: %{slug: "badges"}} = assigns), do: ComponentPages.badges(assigns)

  # Temporary catch-all placeholder. Steps 4-8 replace it with one dispatch clause
  # per slug and remove this clause, so an unregistered slug becomes a
  # compile-visible gap.
  defp page_body(assigns) do
    ~H"""
    <section id={"ds-page-#{@page.slug}"}>
      <h1 class="text-2xl font-semibold">{@page.title}</h1>
      <p class="mt-2 text-base-content/70">Page under construction</p>
    </section>
    """
  end
end

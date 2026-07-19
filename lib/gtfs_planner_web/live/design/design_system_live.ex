defmodule GtfsPlannerWeb.Design.DesignSystemLive do
  @moduledoc """
  In-app design system section at `/design`.

  Owns the ordered page registry, patch navigation between pages, the sidebar and
  content shell, and page-body dispatch. The registry is the single source of page
  slugs, titles, grouping, and order: the sidebar, the dispatch clauses, and the
  tests all derive from `pages/0`.
  """
  use GtfsPlannerWeb, :live_view

  require Logger

  alias GtfsPlanner.Geocoding
  alias GtfsPlannerWeb.Design.ComponentPages
  alias GtfsPlannerWeb.Design.FoundationPages
  alias GtfsPlannerWeb.Design.ProposalPages
  alias LiveSelect.Component, as: LiveSelectComponent

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
    %{slug: "autocomplete", title: "Autocomplete", group: "Components"},
    %{slug: "improvements", title: "Improvements", group: "Proposals"},
    %{slug: "content", title: "Content & IA", group: "Proposals"},
    %{slug: "transit", title: "Transit patterns", group: "Proposals"}
  ]

  @doc """
  The ordered page registry backing the sidebar, dispatch, and tests.
  """
  @spec pages() :: [%{slug: String.t(), title: String.t(), group: String.t()}]
  def pages, do: @pages

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page, hd(@pages))
     |> assign(:demo_form, demo_form())
     |> assign(:pagination_page, 1)
     |> assign(:drawer_open, false)
     |> assign(:confirm_open, false)
     |> assign(:confirm_pending, false)
     |> assign(:confirm_result, nil)
     |> assign(:confirm_return_focus_id, nil)
     |> assign(:form, address_form())
     |> assign(:selected_address, nil)
     |> assign(:selected_lat, nil)
     |> assign(:selected_lon, nil)
     |> assign(:selected_result, nil)
     |> assign(:saved_locations, [])
     |> assign(:last_results, [])}
  end

  # Demo state for every page lives here, in the LiveView that owns the events.
  defp demo_form do
    to_form(%{"name" => "", "kind" => "", "notes" => "", "active" => "false"}, as: :demo)
  end

  # `as: :address_search` is load-bearing: the autocomplete handlers below pattern-match
  # on the `"address_search"` params key this name produces.
  defp address_form do
    to_form(%{"address_autocomplete" => ""}, as: :address_search)
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

  # The inputs page's demo form is a showcase, not a record: it validates nothing and
  # persists nothing. The clause exists because a `phx-submit` with no handler would
  # crash the LiveView, and without `phx-submit` the browser would issue a full-page
  # POST and leave the section.
  @impl true
  def handle_event("demo_form_submit", _params, socket) do
    {:noreply, socket}
  end

  # The tables page's `<.pagination>` demo. The component hardcodes the event name
  # (`core_components.ex:584`), so this clause name is not negotiable, and it sends
  # `phx-value-page` as a string. The demo range is the `total={45}` / `per_page={10}`
  # rendered by `ComponentPages.tables/1` — 5 pages.
  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, assign(socket, :pagination_page, clamp_page(page))}
  end

  # The overlays page's `<.drawer>` demo. The drawer never closes itself: it renders
  # from `open` and pushes `on_close`, so these two clauses are what make it work.
  # `close_drawer` is the component's `on_close` default (`core_components.ex:706`) and
  # arrives from both the header close button (`:745`) and the overlay click (`:721`).
  def handle_event("open_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer_open, true)}
  end

  def handle_event("close_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer_open, false)}
  end

  # The overlays page confirmation demo. The confirmation is fully server-owned:
  # open, pending, success, and error are all assigns. Success closes only the
  # child alertdialog and focuses #ds-confirm-result inside the still-open drawer.
  # Error clears pending in place so the user can retry or cancel.
  def handle_event("open_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_open, true)
     |> assign(:confirm_return_focus_id, nil)}
  end

  def handle_event("cancel_confirm", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_open, false)
     |> assign(:confirm_pending, false)
     |> assign(:confirm_return_focus_id, nil)}
  end

  def handle_event("run_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm_pending, true)}
  end

  def handle_event("confirm_success", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_open, false)
     |> assign(:confirm_pending, false)
     |> assign(:confirm_result, :success)
     |> assign(:confirm_return_focus_id, "ds-confirm-result")}
  end

  def handle_event("confirm_error", _params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_pending, false)
     |> assign(:confirm_return_focus_id, nil)}
  end

  # The autocomplete page's LiveSelect demo, migrated from the retired `/components`
  # page. These clauses fire only from that page's component, but they live here
  # because the LiveView is shared across every page in the section.
  #
  # LiveSelect pushes `live_select_change` for both a keystroke and a selection; the
  # selection payload carries the chosen option's `tag`, so that clause comes first.
  def handle_event(
        "live_select_change",
        %{"text" => _text, "id" => _id, "field" => _field, "selection" => %{"tag" => selection}},
        socket
      ) do
    case normalize_result(selection) do
      {:ok, result} ->
        {:noreply, apply_selected_result(socket, result)}

      :error ->
        {:noreply, clear_selected_result(socket)}
    end
  end

  def handle_event("live_select_change", %{"text" => text, "id" => id}, socket) do
    Logger.debug("Autocomplete search initiated for field: #{id}")

    case Geocoding.autocomplete(text) do
      {:ok, results} ->
        Logger.debug("Autocomplete returned #{length(results)} results")

        options =
          Enum.map(results, fn result ->
            %{
              label: result.formatted_address,
              value: result.formatted_address,
              tag: result,
              option: result.formatted_address
            }
          end)

        send_update(LiveSelectComponent, id: id, options: options)

        # Store results for later matching
        {:noreply, assign(socket, :last_results, results)}

      {:error, reason} ->
        Logger.error("Geocoding autocomplete failed: #{inspect(reason)}")
        send_update(LiveSelectComponent, id: id, options: [])
        {:noreply, assign(socket, :last_results, [])}
    end
  end

  def handle_event(
        "change",
        %{"address_search" => %{"address_autocomplete" => selection}},
        socket
      )
      when is_binary(selection) and selection != "" do
    Logger.debug("Address selection change event received for address_autocomplete field")

    {:noreply, apply_selection_by_address(socket, selection)}
  end

  def handle_event("change", _params, socket) do
    Logger.debug("Address form change event (no selection)")
    {:noreply, clear_selected_result(socket)}
  end

  def handle_event(
        "address-form",
        %{"address_search" => %{"address_autocomplete" => selection}},
        socket
      ) do
    Logger.debug("Address form change event for address_autocomplete field")
    {:noreply, apply_selection_by_address(socket, selection)}
  end

  def handle_event("address-form", _params, socket) do
    {:noreply, clear_selected_result(socket)}
  end

  def handle_event("live_select_blur", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_location", _params, socket) do
    case socket.assigns.selected_result do
      nil ->
        {:noreply, socket}

      result ->
        saved_locations = [result | socket.assigns.saved_locations]
        {:noreply, assign(socket, :saved_locations, saved_locations)}
    end
  end

  def handle_event("delete_location", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    saved_locations = List.delete_at(socket.assigns.saved_locations, index)
    {:noreply, assign(socket, :saved_locations, saved_locations)}
  end

  # Resolves a typed/selected address string against the results the last autocomplete
  # call cached. An unmatched string clears the selection rather than keeping a stale
  # one, which is also what makes a failed geocoding call safe.
  defp apply_selection_by_address(socket, selection) do
    result =
      Enum.find(socket.assigns.last_results, fn current_result ->
        current_result.formatted_address == selection
      end)

    case result do
      nil -> clear_selected_result(socket)
      selected_result -> apply_selected_result(socket, selected_result)
    end
  end

  defp apply_selected_result(socket, result) do
    socket
    |> assign(:selected_address, result.formatted_address)
    |> assign(:selected_lat, result.lat)
    |> assign(:selected_lon, result.lon)
    |> assign(:selected_result, result)
  end

  defp clear_selected_result(socket) do
    socket
    |> assign(:selected_address, nil)
    |> assign(:selected_lat, nil)
    |> assign(:selected_lon, nil)
    |> assign(:selected_result, nil)
  end

  # The selection payload arrives from the client as string-keyed JSON, so it is
  # validated back into a Result rather than trusted.
  defp normalize_result(%Geocoding.Result{} = result), do: {:ok, result}

  defp normalize_result(%{} = result) do
    with formatted_address when is_binary(formatted_address) <-
           Map.get(result, "formatted_address"),
         lat when is_float(lat) <- Map.get(result, "lat"),
         lon when is_float(lon) <- Map.get(result, "lon") do
      {:ok,
       %Geocoding.Result{
         formatted_address: formatted_address,
         lat: lat,
         lon: lon,
         city: Map.get(result, "city"),
         state: Map.get(result, "state"),
         country: Map.get(result, "country")
       }}
    else
      _ -> :error
    end
  end

  defp normalize_result(_result), do: :error

  @pagination_last_page 5

  # Clamped rather than trusted: the page value arrives from the client, and an
  # out-of-range page would render a nonsense count ("Showing 91–100 of 45"). Parsing
  # leniently keeps a malformed value from crashing the LiveView for every page.
  defp clamp_page(page) when is_integer(page),
    do: page |> max(1) |> min(@pagination_last_page)

  defp clamp_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {number, _rest} -> clamp_page(number)
      :error -> 1
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
                <%!-- `menu-active`, not `active`: daisyUI 5 renamed the class, and the
                      daisyUI 4 name matches no rule, so the current page carried no
                      highlight at all. --%>
                <.link
                  patch={~p"/design/#{entry.slug}"}
                  aria-current={@page.slug == entry.slug && "page"}
                  class={["block", @page.slug == entry.slug && "menu-active font-semibold"]}
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

  defp page_body(%{page: %{slug: "inputs"}} = assigns), do: ComponentPages.inputs(assigns)

  defp page_body(%{page: %{slug: "badges"}} = assigns), do: ComponentPages.badges(assigns)

  defp page_body(%{page: %{slug: "tables"}} = assigns), do: ComponentPages.tables(assigns)

  defp page_body(%{page: %{slug: "feedback"}} = assigns), do: ComponentPages.feedback(assigns)

  defp page_body(%{page: %{slug: "navigation"}} = assigns), do: ComponentPages.navigation(assigns)

  defp page_body(%{page: %{slug: "overlays"}} = assigns), do: ComponentPages.overlays(assigns)

  defp page_body(%{page: %{slug: "autocomplete"}} = assigns),
    do: ComponentPages.autocomplete(assigns)

  defp page_body(%{page: %{slug: "improvements"}} = assigns),
    do: ProposalPages.improvements(assigns)

  defp page_body(%{page: %{slug: "content"}} = assigns), do: ProposalPages.content(assigns)

  # No catch-all clause: every slug in the registry has a clause above, so adding a
  # registry entry without a body raises a FunctionClauseError on that page rather
  # than rendering a silent placeholder.
  defp page_body(%{page: %{slug: "transit"}} = assigns), do: ProposalPages.transit(assigns)
end

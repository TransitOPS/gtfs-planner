defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareLive do
  @moduledoc """
  LiveView for the pattern comparison page (spec 19, `R11`, `AC-13`–`AC-15`).

  Route › Patterns › Compare patterns lines two patterns up stop by stop. The
  route header, the title row with its view switch and calendar select, and the
  loading and unavailable states are rendered here from
  `RoutePatternCompareComponents.page/1`; the slots, summary, stop table and map
  arrive in later steps.

  The URL carries the whole selection (`R11`): `a`, `b`, `service`, `ta`, `tb`,
  `reverse`, `view`, `dir` and `picker`. A visit without `a` resolves `R8`'s entry
  pair once and patches the URL to it, so every later state is a URL a planner can
  share. Reads go through `Gtfs.load_pattern_comparison/3` and its configured
  `CatalogReadAdapter`; a lost connection renders the unavailable state with an
  explicit retry, and a route or `a` outside the organization, the version or a
  published route returns to the Patterns tab with the `Pattern not found` flash.
  Access uses the same editor guard as the pattern pages. The page writes nothing
  (`INV-2`).
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.PatternComparison
  alias GtfsPlannerWeb.Gtfs.RoutePatternCompareComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The whole selection lives in the URL, so a patch link or the calendar select
  # resends the current params in this one order.
  @query_keys ~w(a b service ta tb reverse view dir picker)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Compare patterns")
     |> assign(:route_id, nil)
     |> assign(:requested, %{})
     |> assign(:view, :two)
     |> assign(:comparison, nil)
     |> assign(:load_state, :loading)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:route_id, params["route_id"])
      |> assign(:requested, params)
      |> assign(:view, if(params["view"] == "all", do: :all, else: :two))

    if connected?(socket) do
      load(socket, params)
    else
      # The first paint is the loading skeleton; the connected visit loads the
      # read (and resolves the entry defaults when the URL has no `a`).
      {:noreply, assign(socket, :load_state, :loading)}
    end
  end

  @impl true
  def handle_event("retry", _params, socket) do
    load(socket, socket.assigns.requested)
  end

  @impl true
  def handle_event("select_calendar", %{"service" => service_id}, socket) do
    {:noreply, push_patch(socket, to: compare_path(socket, %{"service" => service_id}))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_organization={@current_organization}
      user_roles={@user_roles}
      current_path={@current_path}
      current_gtfs_version={assigns[:current_gtfs_version]}
      available_versions={assigns[:available_versions] || []}
    >
      <RoutePatternCompareComponents.page
        load_state={@load_state}
        route={@comparison && @comparison.route}
        version={@current_gtfs_version}
        view={@view}
        comparison={@comparison}
        two_path={compare_path(@current_gtfs_version.id, @route_id, @requested, %{"view" => nil})}
        all_path={compare_path(@current_gtfs_version.id, @route_id, @requested, %{"view" => "all"})}
        patterns_path={patterns_path(@current_gtfs_version.id, @route_id)}
      />
    </Layouts.app>
    """
  end

  # A visit without `a` opens `R8`'s entry pair. The defaults read has no facade
  # callback (the facade carries the four comparison reads), so it goes to
  # `PatternComparison.defaults/3` directly; the patch then loads the comparison
  # through `Gtfs.load_pattern_comparison/3` like every other visit.
  defp load(socket, params) do
    case params["a"] do
      nil -> load_defaults(socket)
      _a -> load_comparison(socket, params)
    end
  end

  defp load_defaults(socket) do
    scope = scope(socket)

    case PatternComparison.defaults(scope, socket.assigns.route_id, []) do
      {:ok, %{a: a, b: b}} when is_binary(a) ->
        {:noreply,
         push_patch(socket, to: compare_path(socket, %{"a" => a, "b" => b}), replace: true)}

      # A route without patterns has nothing to compare; its Patterns tab owns
      # the first-use state.
      _ ->
        not_found(socket)
    end
  end

  defp load_comparison(socket, params) do
    scope = scope(socket)

    read_params = %{
      route_id: socket.assigns.route_id,
      a: params["a"],
      b: params["b"],
      service: params["service"],
      ta: params["ta"],
      tb: params["tb"],
      reverse: params["reverse"] == "1"
    }

    case Gtfs.load_pattern_comparison(scope.organization_id, scope.gtfs_version_id, read_params) do
      {:ok, comparison} ->
        {:noreply,
         socket
         |> assign(:comparison, comparison)
         |> assign(:load_state, :ready)}

      {:error, :not_found} ->
        not_found(socket)

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> assign(:comparison, nil)
         |> assign(:load_state, :unavailable)}
    end
  end

  defp scope(socket) do
    %{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id
    }
  end

  defp not_found(socket) do
    socket
    |> put_flash(:error, "Pattern not found")
    |> push_navigate(
      to: patterns_path(socket.assigns.current_gtfs_version.id, socket.assigns.route_id)
    )
  end

  defp patterns_path(version_id, route_id) do
    "/gtfs/#{version_id}/routes/#{route_id}/patterns"
  end

  # Builds the compare URL from the current params, overriding the named keys; a
  # nil override drops the key. The R11 keys keep one order so the same selection
  # always produces the same URL.
  defp compare_path(socket, overrides) do
    compare_path(
      socket.assigns.current_gtfs_version.id,
      socket.assigns.route_id,
      socket.assigns.requested,
      overrides
    )
  end

  defp compare_path(version_id, route_id, requested, overrides) do
    params =
      @query_keys
      |> Enum.flat_map(fn key ->
        value = Map.get(overrides, key, requested[key])
        if value in [nil, ""], do: [], else: [{key, value}]
      end)

    base = "/gtfs/#{version_id}/routes/#{route_id}/patterns/compare"

    case params do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end
end

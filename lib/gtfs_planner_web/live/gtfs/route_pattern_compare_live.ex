defmodule GtfsPlannerWeb.Gtfs.RoutePatternCompareLive do
  @moduledoc """
  LiveView for the pattern comparison page (spec 19, `R11`, `AC-13`–`AC-15`).

  Route › Patterns › Compare patterns lines two patterns up stop by stop. The
  route header, the title row with its view switch and calendar select, and the
  loading and unavailable states are rendered here from
  `RoutePatternCompareComponents.page/1`; the slots, summary, stop table and
  map pane arrive with it. The stop table is a
  stream (`:compare_rows`), reset on every load and rendered with stable DOM ids
  per row index (`INV-4`).

  The URL carries the whole selection (`R11`): `a`, `b`, `service`, `ta`, `tb`,
  `reverse`, `view`, `dir` and `picker`. A visit without `a` resolves `R8`'s entry
  pair once and patches the URL to it, so every later state is a URL a planner can
  share. Reads go through `Gtfs.load_pattern_comparison/3` and its configured
  `CatalogReadAdapter`; a lost connection renders the unavailable state with an
  explicit retry, and a route or `a` outside the organization, the version or a
  published route returns to the Patterns tab with the `Pattern not found` flash.
  Access uses the same editor guard as the pattern pages. The page writes nothing
  (`INV-2`).

  The map pane (`AC-22`) arrives with the pair: `#compare-map` mounts the
  `PatternCompareMap` hook on `Gtfs.load_pattern_compare_map/4`'s payload, read
  after the comparison and carrying one numbered pin per difference. Its own
  failure is isolated to the pane, and `retry_map` reloads only that read
  (`CL-13`).

  The pattern picker (`AC-20`) is the `picker` param. It opens with
  `Gtfs.load_pattern_picker/3` loaded once per open; `picker_search` filters that
  list in memory, `choose_pattern` patches the chosen side and drops its pinned
  timing, and `close_picker` patches the param away.

  The all-patterns view (`view=all`, `AC-21`) loads
  `Gtfs.load_pattern_overview/4` for the URL's direction instead of a pair: every
  pattern of that direction is a column of the overview, and the checkboxes keep
  the picked columns as server state (the URL does not carry them), at most two
  in pick order. "Compare 2 patterns" patches the picked pair into the two-view
  URL as `a` and `b`.
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
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
     |> assign(:overview, nil)
     |> assign(:overview_dir, 0)
     |> assign(:overview_picked, [])
     |> assign(:picker, nil)
     |> assign(:map_payload, nil)
     |> assign(:load_state, :loading)
     |> stream(:compare_rows, [], dom_id: & &1.dom_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # A crafted query such as `?b[k]=v` decodes to a map; only string values are
    # IDs or flags, so anything else is dropped before it can reach a query.
    params = Map.filter(params, fn {_key, value} -> is_binary(value) end)

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

  # "Retry map" re-runs the map read alone (`CL-13`, `AC-22`): the comparison,
  # its stream and every other pane stay exactly as they were, so a map outage
  # never costs the planner the table. Without a loaded comparison there is
  # nothing to draw and nothing to retry.
  @impl true
  def handle_event("retry_map", _params, socket) do
    case socket.assigns.comparison do
      %{} = comparison -> {:noreply, load_map(socket, comparison)}
      nil -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_calendar", %{"service" => service_id}, socket) do
    {:noreply, push_patch(socket, to: compare_path(socket, %{"service" => service_id}))}
  end

  @impl true
  def handle_event("select_timing", %{"ta" => timing_id}, socket),
    do: patch_timing(socket, "ta", timing_id)

  def handle_event("select_timing", %{"tb" => timing_id}, socket),
    do: patch_timing(socket, "tb", timing_id)

  # Swap A with B (AC-16). When B is on the URL route the patch keeps the page;
  # when it is on another route the whole page navigates to that route's compare
  # URL, because the route is part of the path. A timing the URL pinned follows
  # its pattern across the swap; an unpinned default stays unpinned.
  @impl true
  def handle_event("picker_search", %{"query" => query}, socket) do
    case socket.assigns.picker do
      %{side: _side} = picker -> {:noreply, assign(socket, :picker, %{picker | query: query})}
      _closed -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("choose_pattern", %{"pattern" => pattern_id} = params, socket) do
    case socket.assigns.picker do
      %{side: side} -> {:noreply, push_choice(socket, side, pattern_id, params["route"])}
      _closed -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_picker", _params, socket) do
    if socket.assigns.picker do
      {:noreply, push_patch(socket, to: compare_path(socket, %{"picker" => nil}))}
    else
      {:noreply, socket}
    end
  end

  # One overview checkbox is server state (`INV-4`): the click toggles that
  # pattern in the picked list, which keeps at most two in pick order, so a third
  # pick drops the oldest and the pair compared is the last two chosen (`AC-21`).
  @impl true
  def handle_event("overview_pick", %{"pattern" => pattern_id}, socket) do
    picked = socket.assigns.overview_picked

    next =
      if pattern_id in picked do
        List.delete(picked, pattern_id)
      else
        Enum.take(picked ++ [pattern_id], -2)
      end

    {:noreply, assign(socket, :overview_picked, next)}
  end

  # "Compare 2 patterns" opens the two view with the picked columns as A and B in
  # pick order, which is the order the checkboxes were ticked. The button is
  # disabled unless two are picked, so any other payload keeps the page as it is.
  @impl true
  def handle_event("overview_compare", _params, socket) do
    case socket.assigns.overview_picked do
      [a, b] ->
        {:noreply,
         push_patch(socket, to: compare_path(socket, %{"view" => nil, "a" => a, "b" => b}))}

      _not_two ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("swap", _params, socket) do
    case socket.assigns.comparison && socket.assigns.comparison.b do
      nil ->
        {:noreply, socket}

      b ->
        overrides = swap_overrides(socket, socket.assigns.comparison.a, b)

        socket =
          if b.route.route_id == socket.assigns.route_id do
            push_patch(socket, to: compare_path(socket, overrides))
          else
            push_navigate(socket,
              to:
                compare_path(
                  socket.assigns.current_gtfs_version.id,
                  b.route.route_id,
                  socket.assigns.requested,
                  overrides
                )
            )
          end

        {:noreply, socket}
    end
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
        route={(@comparison && @comparison.route) || (@overview && @overview.route)}
        version={@current_gtfs_version}
        view={@view}
        comparison={@comparison}
        rows={@streams.compare_rows}
        two_path={compare_path(@current_gtfs_version.id, @route_id, @requested, %{"view" => nil})}
        all_path={compare_path(@current_gtfs_version.id, @route_id, @requested, %{"view" => "all"})}
        patterns_path={patterns_path(@current_gtfs_version.id, @route_id)}
        slot_paths={
          @comparison &&
            slot_paths(@comparison, @current_gtfs_version.id, @route_id, @requested)
        }
        reverse_path={reverse_path(@comparison, @current_gtfs_version.id, @route_id, @requested)}
        map_payload={@map_payload}
        picker={@picker}
        overview={@overview}
        overview_dir={@overview_dir}
        overview_picked={@overview_picked}
        overview_dir_paths={overview_dir_paths(@current_gtfs_version.id, @route_id, @requested)}
      />
    </Layouts.app>
    """
  end

  # A visit reads the all-patterns overview or the pair, never both: the overview
  # holds every pattern of a direction, so it needs no A and a bare
  # `?view=all` works, while the two view still resolves R8's entry pair.
  defp load(socket, %{"view" => "all"} = params), do: load_overview(socket, params)

  defp load(socket, params) do
    case params["a"] do
      nil -> load_defaults(socket)
      _a -> load_comparison(socket, params)
    end
  end

  # A visit without `a` opens `R8`'s entry pair; the patch then loads the
  # comparison through `Gtfs.load_pattern_comparison/3` like every other visit.
  defp load_defaults(socket) do
    scope = scope(socket)

    case Gtfs.load_pattern_defaults(
           scope.organization_id,
           scope.gtfs_version_id,
           socket.assigns.route_id
         ) do
      {:ok, %{a: a, b: b}} when is_binary(a) ->
        {:noreply,
         push_patch(socket, to: compare_path(socket, %{"a" => a, "b" => b}), replace: true)}

      {:error, :unavailable} ->
        {:noreply, unavailable(socket)}

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
        socket =
          socket
          |> assign(:comparison, comparison)
          |> assign(:load_state, :ready)
          |> assign(:map_payload, nil)
          |> stream(:compare_rows, RoutePatternCompareComponents.stop_table_items(comparison),
            reset: true
          )
          |> load_map(comparison)

        {:noreply, load_picker(socket, params, comparison)}

      {:error, :not_found} ->
        not_found(socket)

      {:error, :unavailable} ->
        {:noreply, unavailable(socket)}
    end
  end

  defp unavailable(socket) do
    socket
    |> assign(:comparison, nil)
    |> assign(:picker, nil)
    |> assign(:load_state, :unavailable)
  end

  # The map read is separate from the comparison read (`CL-13`, `AC-22`): it runs
  # after a successful pair load, and a failure here changes nothing else on the
  # page, so `nil` means only the pane shows its own unavailable block and
  # retry. A's payload is drawn with B's only when B resolved inside the scope;
  # `:not_found` (A vanished between the two reads) is the same pane failure.
  defp load_map(socket, comparison) do
    scope = scope(socket)

    case Gtfs.load_pattern_compare_map(
           scope.organization_id,
           scope.gtfs_version_id,
           comparison.a.pattern.route_pattern_id,
           comparison.b && comparison.b.pattern.route_pattern_id
         ) do
      {:ok, payload} ->
        assign(socket, :map_payload, Map.put(payload, :pins, map_pins(comparison)))

      {:error, _reason} ->
        assign(socket, :map_payload, nil)
    end
  end

  # The map's numbered pins (`AC-22`): one per difference, in the summary's own
  # order, at the first row of the difference (`R10`). Pin n is the "What's
  # different" item n, so the two numberings agree without a second source; the
  # hook drops a pin whose stop the read left unlocated.
  defp map_pins(%{alignment: %{differences: %{items: items}, rows: rows}}) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {item, number} ->
      %{n: number, stop_id: Enum.at(rows, Enum.min(item.rows)).stop_id}
    end)
  end

  defp map_pins(_comparison_without_alignment), do: []

  # The all-patterns read (`AC-21`): one route direction's overview, at the URL's
  # `dir` and calendar. The picked columns belong to one direction, so a
  # direction change clears them while a calendar change keeps them. The pair's
  # own read and its map are dropped with it: the two views share nothing but
  # the URL.
  defp load_overview(socket, params) do
    direction = direction_param(params["dir"])
    scope = scope(socket)

    case Gtfs.load_pattern_overview(
           scope.organization_id,
           scope.gtfs_version_id,
           socket.assigns.route_id,
           direction: direction,
           service: params["service"]
         ) do
      {:ok, overview} ->
        picked =
          if socket.assigns.overview_dir == direction,
            do: socket.assigns.overview_picked,
            else: []

        {:noreply,
         socket
         |> assign(:overview, overview)
         |> assign(:overview_dir, direction)
         |> assign(:overview_picked, picked)
         |> assign(:comparison, nil)
         |> assign(:map_payload, nil)
         |> assign(:picker, nil)
         |> assign(:load_state, :ready)}

      {:error, :not_found} ->
        not_found(socket)

      {:error, :unavailable} ->
        {:noreply,
         socket
         |> assign(:overview, nil)
         |> assign(:comparison, nil)
         |> assign(:picker, nil)
         |> assign(:load_state, :unavailable)}
    end
  end

  # The picker read loads once per open (`AC-20`): the URL's `picker` side picks
  # the other side for the stops-in-common ranking and the loaded calendar for
  # the trip counts. A patch that keeps the same side and a search that only
  # changes the query stay in memory. A lost connection keeps the drawer with
  # `entries: nil`, which the component renders as its own error state.
  defp load_picker(socket, %{"picker" => side} = _params, comparison)
       when side in ["a", "b"] do
    case socket.assigns.picker do
      %{side: ^side} -> socket
      _closed -> load_picker_entries(socket, side, comparison)
    end
  end

  defp load_picker(socket, _params, _comparison), do: assign(socket, :picker, nil)

  defp load_picker_entries(socket, side, comparison) do
    scope = scope(socket)

    case Gtfs.load_pattern_picker(scope.organization_id, scope.gtfs_version_id,
           other: picker_other(comparison, side),
           service: comparison.service_id
         ) do
      {:ok, entries} ->
        assign(socket, :picker, %{side: side, entries: entries, query: ""})

      {:error, :unavailable} ->
        assign(socket, :picker, %{side: side, entries: nil, query: ""})
    end
  end

  defp picker_other(comparison, "a"),
    do: comparison.b && comparison.b.pattern.route_pattern_id

  defp picker_other(comparison, "b"), do: comparison.a.pattern.route_pattern_id

  # Choosing patches `a` or `b` and drops that side's pinned timing, so the new
  # pattern resolves its own default; the `picker` param goes away. A's route is
  # the URL's route, so an A on another route navigates there the way swap does
  # (`AC-16`), while a B on another route stays on this route.
  defp push_choice(socket, side, pattern_id, route_id) do
    overrides = %{side => pattern_id, "picker" => nil, timing_param(side) => nil}

    if side == "a" and is_binary(route_id) and route_id != socket.assigns.route_id do
      push_navigate(socket,
        to:
          compare_path(
            socket.assigns.current_gtfs_version.id,
            route_id,
            socket.assigns.requested,
            overrides
          )
      )
    else
      push_patch(socket, to: compare_path(socket, overrides))
    end
  end

  defp timing_param("a"), do: "ta"
  defp timing_param("b"), do: "tb"

  defp direction_param("1"), do: 1
  defp direction_param(_dir), do: 0

  defp scope(socket) do
    %{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id
    }
  end

  # The one "not found" exit for a missing route or `a`: flash and return to
  # the Patterns tab. It returns the `{:noreply, socket}` tuple its callers
  # (`handle_params`, `retry`) must hand LiveView, so every path out of
  # `handle_params` has the same shape.
  defp not_found(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "Pattern not found")
     |> push_navigate(
       to: patterns_path(socket.assigns.current_gtfs_version.id, socket.assigns.route_id)
     )}
  end

  defp patch_timing(socket, key, timing_id) do
    {:noreply, push_patch(socket, to: compare_path(socket, %{key => timing_id}))}
  end

  defp swap_overrides(socket, a, b) do
    requested = socket.assigns.requested

    %{
      "a" => b.pattern.route_pattern_id,
      "b" => a.pattern.route_pattern_id,
      "ta" => requested["tb"],
      "tb" => requested["ta"]
    }
  end

  # The slot cards' own paths: the compare URL that opens the picker (`picker`),
  # and each pattern's Stops and Timings tasks. A side without a pattern keeps
  # its change path so the empty and unavailable cards can offer "Choose pattern
  # B"; the pattern task paths are nil until it has one.
  defp slot_paths(comparison, version_id, route_id, requested) do
    %{
      a:
        side_paths(
          comparison.a,
          version_id,
          compare_path(version_id, route_id, requested, %{"picker" => "a"})
        ),
      b:
        side_paths(
          comparison.b,
          version_id,
          compare_path(version_id, route_id, requested, %{"picker" => "b"})
        )
    }
  end

  defp side_paths(nil, _version_id, change_path),
    do: %{change: change_path, open: nil, times: nil}

  defp side_paths(side, version_id, change_path) do
    base =
      ~p"/gtfs/#{version_id}/routes/#{side.route.route_id}/patterns/#{side.pattern.route_pattern_id}"

    %{change: change_path, open: base <> "?task=stops", times: base <> "?task=timings"}
  end

  # The relation callout's toggle target (AC-4): the same URL with `reverse`
  # set or dropped. It exists once a pair is loaded, so the callout and its
  # toggle speak for the same state; `nil` keeps the callout away while B is
  # absent or unavailable.
  defp reverse_path(comparison, version_id, route_id, requested) do
    case comparison && comparison.alignment do
      %{reversed?: reversed?} ->
        compare_path(version_id, route_id, requested, %{
          "reverse" => if(reversed?, do: nil, else: "1")
        })

      _ ->
        nil
    end
  end

  defp patterns_path(version_id, route_id) do
    ~p"/gtfs/#{version_id}/routes/#{route_id}/patterns"
  end

  # The direction toggle's patch targets: the all-patterns URL for each
  # direction, whatever the current URL holds (`AC-21`). `dir` is URL state like
  # every other selection (`INV-4`).
  defp overview_dir_paths(version_id, route_id, requested) do
    Map.new([0, 1], fn direction ->
      path =
        compare_path(version_id, route_id, requested, %{
          "view" => "all",
          "dir" => Integer.to_string(direction)
        })

      {direction, path}
    end)
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

    # `~p` percent-encodes each segment, so an imported route ID such as `10/A`
    # stays one segment instead of producing a path no route matches.
    base = ~p"/gtfs/#{version_id}/routes/#{route_id}/patterns/compare"

    case params do
      [] -> base
      params -> base <> "?" <> URI.encode_query(params)
    end
  end
end

defmodule GtfsPlannerWeb.Gtfs.FareEditorLive do
  @moduledoc """
  The fare editor shell for Settings › This version › Fares: the page frame
  every fare tab draws into.

  The Fares section is two LiveViews. This one owns Prices, Where fares apply,
  Transfers and Checks — the four tabs that read and write the version's fare
  model — and `GtfsPlannerWeb.Gtfs.FaresLive` keeps the Zones tab, whose map,
  selection and assignment review spec 21 built. The shared `fares_tabs/1`
  strip navigates between them, so each tab is its own path and a tab change is
  a real navigation rather than a patch of one LiveView's query state.

  The shell carries the Settings back link, the "Fares" heading and its lede,
  the five tabs, and one primary action per tab, so each tab body arrives inside
  a finished page rather than rewriting the frame around it.

  The version's whole fare read model arrives in one operational read through
  `Gtfs.load_fare_editor/3`, so the tabs cannot disagree about what the version
  holds and a lost database connection resolves to one load-error state with a
  single recovery action instead of a blank page, a partial workspace, or a
  crash reported as downtime. The disconnected render ships the skeleton; the
  connected load resolves to `:ready` or `:unavailable`, and `reload` re-runs the
  same load.

  `/settings/fares/rules` is the retired Fare rules path. Fare rules are edited
  on Where fares apply now, so that action navigates there instead of rendering
  a tab of its own, and a link from outside the page keeps working.

  Access is authorized at mount through `EnsureRole`, following the other GTFS
  pages: there is no view-only GTFS role.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FareEditorComponents,
    only: [header_primary: 1, load_error: 1, loading: 1]

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Fares
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Fares")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:load_state, :loading)
     |> assign(:workspace, nil)
     |> assign(:checks, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      if socket.assigns.live_action == :rules do
        push_navigate(socket, to: fares_path(socket.assigns.current_gtfs_version.id, :where))
      else
        socket
      end

    if connected?(socket) do
      {:noreply, load_workspace(socket)}
    else
      # The static render ships the skeleton; the connected mount owns the load.
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load_workspace(socket)}

  # Version switching follows the other GTFS pages: a selection of another
  # published version of this organization navigates, keeping the tab the
  # operator was reading. The switcher's own hook returns before it sends the
  # event for the version already shown, so both events ignore that case.
  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if version_id && version_id != to_string(socket.assigns.current_gtfs_version.id) &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: fares_path(version_id, socket.assigns.live_action))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: fares_path(version_id, socket.assigns.live_action))}
    else
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
      <div id="fare-editor-page" class="ds-page">
        <.back_link id="settings-back" navigate={settings_path(@current_gtfs_version.id)}>
          Settings
        </.back_link>

        <.header>
          Fares
          <:subtitle>
            What riders pay and which fare each ride charges. Exports include both GTFS fare
            formats.
          </:subtitle>
          <:actions>
            <.header_primary
              active_tab={@live_action}
              ready?={@load_state == :ready}
              transfers?={@workspace != nil and @workspace.transfers != []}
            />
          </:actions>
        </.header>

        <.fares_tabs
          gtfs_version_id={@current_gtfs_version.id}
          active_tab={@live_action}
          checks_count={if @load_state == :ready, do: checks_count(@checks), else: nil}
          checks_tone={if @load_state == :ready, do: checks_tone(@checks), else: nil}
        />

        <div class="mt-4 grid grid-cols-1 gap-4">
          <.loading :if={@load_state == :loading} />
          <.load_error :if={@load_state == :unavailable} />
          <%!-- The tab's own body arrives with the tab that owns it; the shell
          owns the frame above and the load states beside it. --%>
          <div :if={@load_state == :ready} id="fare-editor-panel"></div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # One scoped read of the version's whole fare model. A lost connection is
  # reported once so the page can offer its reload action; a previous workspace
  # stays in assigns, so a failed refresh never erases values a later step can
  # still render — the load state decides what is shown.
  defp load_workspace(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.load_fare_editor(organization_id, gtfs_version_id, []) do
      {:ok, workspace} ->
        socket
        |> assign(:workspace, workspace)
        |> assign(:checks, Fares.Checks.run(organization_id, gtfs_version_id))
        |> assign(:load_state, :ready)

      {:error, :unavailable} ->
        socket
        |> assign(:load_state, :unavailable)
    end
  end

  # The version's fare problems, which the Checks tab's mark reports: everything
  # that needs repair or review, so a setup problem stays visible from every
  # other tab. A version whose fares have not loaded claims no count at all.
  defp checks_count(%{repair: repair, review: review}), do: length(repair) + length(review)

  defp checks_tone(%{repair: [_ | _]}), do: :error
  defp checks_tone(%{review: [_ | _]}), do: :warning
  defp checks_tone(%{}), do: :ok

  defp settings_path(version_id), do: "/gtfs/#{version_id}/settings"

  defp fares_path(gtfs_version_id, :prices), do: "/gtfs/#{gtfs_version_id}/settings/fares"

  defp fares_path(gtfs_version_id, :transfers),
    do: "/gtfs/#{gtfs_version_id}/settings/fares/transfers"

  defp fares_path(gtfs_version_id, :checks), do: "/gtfs/#{gtfs_version_id}/settings/fares/checks"
  defp fares_path(gtfs_version_id, _where), do: "/gtfs/#{gtfs_version_id}/settings/fares/where"
end

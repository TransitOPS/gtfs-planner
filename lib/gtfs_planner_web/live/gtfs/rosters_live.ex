defmodule GtfsPlannerWeb.Gtfs.RostersLive do
  @moduledoc """
  LiveView for Operations › Rosters.

  Rosters is the version's weekly lines: one operator's week of runs, repeated
  through the service period. This step owns the page shell and the states the
  page can be in before it has any lines — the head, the loading skeleton and the
  version that has no runs to build from. The grid, the open work, the pick row
  and the export section arrive with the steps that own them.

  The page mounts through the ordinary `:gtfs_routes` session, which decides
  whether a request reaches it; the editor guard is declared here because a
  session alone grants no GTFS access. Mount carries no page state and never
  patches the URL, so a link to `/rosters` always lands on the page itself.
  Version switching keeps the page on the new version and accepts only a
  published version of the current organization.

  ## The read is the export's composition, and it happens once connected

  `Gtfs.load_roster/2` is the export's whole-version composition
  (`Blocking.export_movements/2` and `Runs.derive_version/3`, then
  `Rosters.Roster.build/1`), reached through the catalog read adapter like every
  other page read, so a stubbed adapter is enough to drive a lost connection. It
  is called from `handle_params/3` and only when connected, for `BlocksLive`'s
  reason: a disconnected render is the static HTML a browser gets before the
  socket opens, and it must not be a version of the page that has already read
  the database. So the first render is the `:loading` skeleton, and the connected
  render replaces it.

  The composition is not recomputed to answer a question it already answers.
  "This version has no runs" is `roster.summary.run_days_total == 0` — the count
  the same composition produced for the count strip step 25 draws — rather than a
  second walk of the day types' runs (INV-15).

  ## Writes re-read the membership, and the list is one list

  Mount checks the editor role once. The `:editor_access` hook re-reads the
  membership through `EnsureRole.editor_member?/2` before each event in
  `@write_events`, so a role revoked while the page is open refuses the next
  write rather than trusting the mount-time snapshot. `RunsLive` asks the same
  question the same way. The list starts with `add_line` and grows with the
  steps that add writes; a write that is not in it is not a write, which is why
  the list is the whole of the page's write surface rather than a per-handler
  guard nobody can enumerate.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.EnsureRole
  alias GtfsPlannerWeb.Gtfs.RostersComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The events that write. Mount checks the editor role once; these re-read the
  # membership before each write. Step 30 gives `add_line` its write; it is
  # named here from the start so the head's control and the guard that covers it
  # are introduced together.
  @write_events ~w(add_line)

  # A role revoked while the page is open is not an error the reader caused and
  # is not a validation problem, so it is a refusal said once, in the page's own
  # toast rather than in a field.
  @editor_access_lost "You no longer have editor access to this organization."

  # The version went unpublished between the session hook and this read. The
  # reader has no roster to look at, and the hook's own answer is the one to give.
  @version_not_found "GTFS version not found"

  # A lost connection is a pause, not a state the page moves into: step 25 draws
  # `#rosters-unavailable` beside the lines that are still on screen.
  @roster_unreadable "The roster could not be read. Reload to try again."

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Rosters")
     # Nothing is loaded yet. `:loading` is the honest first state and the one
     # the disconnected render shows, so the static HTML and the connected HTML
     # agree.
     |> assign(:load_state, :loading)
     |> assign(:roster, nil)
     |> assign(:loaded_version_id, nil)
     # The toast is event state, not page state, so it starts empty. Starting it
     # empty is also what makes `RostersComponents.toast/1` render nothing on
     # first paint: a `role="status"` region present with no text announces
     # nothing and still occupies the fixed box at the foot of the viewport.
     |> assign(:toast, nil)
     |> attach_hook(:editor_access, :handle_event, &require_editor/3)}
  end

  defp require_editor(event, _params, socket) when event in @write_events do
    if editor_access?(socket) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_toast(@editor_access_lost, :refused)
       |> put_flash(:error, @editor_access_lost)}
    end
  end

  defp require_editor(_event, _params, socket), do: {:cont, socket}

  # The membership read lives in `EnsureRole.editor_member?/2` so this page and
  # Runs ask the same question the same way.
  defp editor_access?(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: organization_id} <- socket.assigns[:current_organization] do
      EnsureRole.editor_member?(user_id, organization_id)
    else
      _other -> false
    end
  end

  # The toast, and the timer that takes it away. The token is what keeps a timer
  # set for an earlier toast from dismissing a later one: without it, a reader
  # who acts twice quickly watches the second message vanish on the first one's
  # schedule.
  defp put_toast(socket, text, kind) do
    token = System.unique_integer([:positive, :monotonic])
    Process.send_after(self(), {:dismiss_toast, token}, 4_000)

    assign(socket, :toast, %{text: text, kind: kind, token: token})
  end

  @impl true
  def handle_info({:dismiss_toast, token}, socket) do
    if socket.assigns.toast && socket.assigns.toast.token == token do
      {:noreply, assign(socket, :toast, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, ensure_roster_loaded(socket)}
  end

  # `BlocksLive.ensure_day_loaded/1`'s rule: the disconnected render shows the
  # loading state, and a roster already loaded is not read again. The guard
  # matters because `handle_params/3` runs on every patch.
  defp ensure_roster_loaded(socket) do
    cond do
      not connected?(socket) ->
        assign(socket, :load_state, :loading)

      socket.assigns.loaded_version_id == to_string(socket.assigns.current_gtfs_version.id) ->
        socket

      true ->
        load_roster(socket)
    end
  end

  defp load_roster(socket) do
    %{current_organization: organization, current_gtfs_version: version} = socket.assigns

    case Gtfs.load_roster(organization.id, version.id) do
      {:ok, view} ->
        socket
        |> assign(:roster, view.roster)
        |> assign(:loaded_version_id, to_string(version.id))
        |> assign(:load_state, roster_state(view.roster))

      {:error, :not_found} ->
        # The session hook already refused a version that is not this
        # organization's published one, so this is a version that went
        # unpublished between the hook and this read. `push_navigate/2` is the
        # redirect itself, so the flash and the navigation leave together; the
        # loaded roster is not assigned, because there is none to keep.
        socket
        |> assign(:roster, nil)
        |> put_flash(:error, @version_not_found)
        |> push_navigate(to: ~p"/")

      {:error, :unavailable} ->
        # `roster` is deliberately untouched, so whatever is on screen stays. A
        # first load that fails has nothing on screen, so it keeps the loading
        # panel and says why in the flash rather than leaving a blank region.
        socket
        |> assign(
          :load_state,
          if(socket.assigns.roster, do: :unavailable, else: :loading)
        )
        |> put_flash(:error, @roster_unreadable)
    end
  end

  # "No runs" is the composition's own run-day total, not a second walk of the
  # day types (INV-15). A version with day types but no runs to place, and a
  # version with no calendars at all, are the same answer here: there is nothing
  # to build a line from.
  defp roster_state(%{summary: %{run_days_total: 0}}), do: :no_runs
  defp roster_state(_roster), do: :ready

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/rosters")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/rosters")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_toast", _params, socket) do
    {:noreply, assign(socket, :toast, nil)}
  end

  # Any other event is ignored. This clause is last among the `handle_event`
  # clauses on purpose: a catch-all placed earlier would shadow the real
  # handlers above it.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
      width="wide"
    >
      <:sub_header>
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:rosters} />
      </:sub_header>

      <RostersComponents.toast toast={@toast} />

      <div id="rosters-page" class="ds-page" data-load-state={@load_state}>
        <RostersComponents.page_head state={@load_state} />

        <RostersComponents.page_state
          :if={@load_state in [:loading, :no_runs]}
          kind={@load_state}
          version_id={@current_gtfs_version.id}
        />
      </div>
    </Layouts.app>
    """
  end
end

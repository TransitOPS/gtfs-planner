defmodule GtfsPlannerWeb.Gtfs.RunsLive do
  @moduledoc """
  The Runs page: one day type's runs, and the states the page can be in before
  it has any.

  This step builds the shell only — the head, the day-type scope bar and the
  load states. Later steps fill the plan card. The read is `Gtfs.load_runs/3`
  from step 12, called through the catalog read adapter like every other page
  read, so a stubbed adapter is enough to drive the failure state.

  ## Why the load is not in `mount/3`

  `BlocksLive` has one rule worth copying: **load only once connected**. A
  disconnected render is the static HTML a browser gets before the socket opens,
  and it must not be a version of the page that has already read the database —
  it is the same HTML the connected render will replace, and reading twice would
  make the first paint and the second disagree whenever the world moves between
  them. So the first render is the `:loading` skeleton, and `handle_params/3`
  loads on the connected pass.

  ## The day type comes from the URL, and the URL is the only source of it

  `?day=` is read in `handle_params/3` and nowhere else. There is no separate
  "selected day type" assign that a second code path could set, so the address
  bar and the page can never disagree — which matters more here than usual,
  because a run is scoped to its day type and `Runs.count_runs_for_trips/3` from
  step 19 counts `(day_type_key, run_id)` pairs. A page that showed one day type
  while the URL named another would report counts for a day it is not showing.

  ## `:unavailable` keeps what is on screen

  A read that fails is not a state the page moves into; it is a failure to move
  out of the state it is in. The runs already loaded stay rendered, the callout
  appears above them, and retry re-runs the same read against the same URL. The
  alternative — blanking the page — would destroy work the reader can still read
  and cannot get back, in exchange for a message they could have been given
  without the loss.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlannerWeb.Gtfs.RunsComponents

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Runs")
     # Nothing is loaded yet. `:loading` is the honest first state and the one
     # the disconnected render shows, so the static HTML and the connected HTML
     # agree.
     |> assign(:load_state, :loading)
     |> assign(:runs_day, nil)
     |> assign(:day_types, [])
     |> assign(:day, nil)
     |> assign(:loaded_day_key, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    day = blank_to_nil(params["day"])

    {:noreply,
     socket
     |> assign(:day, day)
     |> ensure_day_loaded()}
  end

  @impl true
  def handle_event("select_day", %{"day" => day}, socket) do
    {:noreply, push_patch(socket, to: runs_path(socket, blank_to_nil(day)))}
  end

  @impl true
  def handle_event("retry", _params, socket) do
    # The reload is a real read, not a re-render: the point of retry is to find
    # out whether the database has come back. Clearing the loaded key through
    # `assign/3` is what makes `ensure_day_loaded/1` re-read rather than see its
    # own guard and return the socket untouched.
    {:noreply, socket |> assign(:loaded_day_key, nil) |> ensure_day_loaded()}
  end

  # `BlocksLive.ensure_day_loaded/1`'s rule: the disconnected render shows the
  # loading state, and a day type already loaded is not read again. The guard
  # matters because `handle_params/3` runs on every patch, so switching tabs or
  # changing a filter would otherwise re-read the whole day.
  defp ensure_day_loaded(socket) do
    cond do
      not connected?(socket) ->
        assign(socket, :load_state, :loading)

      socket.assigns.loaded_day_key == {:key, socket.assigns.day} ->
        socket

      true ->
        load_day(socket)
    end
  end

  defp load_day(socket) do
    %{day: day, current_organization: organization, current_gtfs_version: version} =
      socket.assigns

    case Gtfs.load_runs(organization.id, version.id, day) do
      {:ok, runs_day} ->
        socket
        |> assign(:runs_day, runs_day)
        |> assign(:day, runs_day.day.day_type.key)
        |> assign(:day_types, runs_day.day.day_types)
        |> assign(:loaded_day_key, {:key, runs_day.day.day_type.key})
        |> assign(:load_state, day_state(runs_day))

      {:error, {:unknown_day_type, []}} ->
        # An EMPTY list is the version saying it has no day types at all, which
        # is a missing calendar rather than a day the reader mistyped. The two
        # are the same error shape from the read and different states here,
        # because the reader is sent to a different page for each.
        socket
        |> assign(:runs_day, nil)
        |> assign(:day, day)
        |> assign(:day_types, [])
        |> assign(:loaded_day_key, {:key, day})
        |> assign(:load_state, :no_dates)

      {:error, {:unknown_day_type, day_types}} ->
        # Nothing is applied on the reader's behalf: the page says which day
        # types exist and lets them choose. Falling back to the first would
        # silently show a day nobody asked for, and on a runs page a day is a
        # claim about whose work is whose.
        socket
        |> assign(:runs_day, nil)
        |> assign(:day, day)
        |> assign(:day_types, day_types)
        |> assign(:loaded_day_key, {:key, day})
        |> assign(:load_state, :unknown)

      {:error, _reason} ->
        # `runs_day` is deliberately untouched, so whatever is on screen stays.
        assign(socket, :load_state, :unavailable)
    end
  end

  # The five states, decided the same way `BlocksLive.day_state/1` decides its
  # own. A version with no dates and a version with no trips are different
  # problems with different fixes, and the reader is sent to a different page
  # for each.
  defp day_state(runs_day) do
    cond do
      runs_day.day.day_types == [] -> :no_dates
      runs_day.day.counts.blocks == 0 -> :empty
      true -> :loaded
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # `?day=` is dropped rather than rendered empty when no day type is selected,
  # so `/runs` and `/runs?day=` are the same URL and the first one the one a
  # reader bookmarks.
  defp runs_path(socket, nil) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/runs"
  end

  defp runs_path(socket, day) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/runs?day=#{day}"
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
      width="wide"
    >
      <:sub_header>
        <.operations_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:runs} />
      </:sub_header>

      <div id="runs-page" data-load-state={@load_state}>
        <div class="w-full space-y-4">
          <RunsComponents.page_head />

          <RunsComponents.unavailable_callout :if={@load_state == :unavailable} />

          <RunsComponents.scope_bar
            :if={@load_state == :loaded or @load_state == :unavailable}
            day_types={@day_types}
            selected={@day || ""}
          />

          <RunsComponents.plan_card
            :if={panel_state?(@load_state)}
            version_id={@current_gtfs_version.id}
          >
            <RunsComponents.page_state
              kind={@load_state}
              version_id={@current_gtfs_version.id}
              day_types={@day_types}
            />
          </RunsComponents.plan_card>

          <RunsComponents.page_footnote :if={@load_state == :loaded} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # `:loaded` and `:unavailable` have no panel: the plan step fills the first
  # and `unavailable_callout/0` presents the second. Rendering a plan card
  # around nothing in either state would put an empty bordered box on the page,
  # which reads as a failure to load.
  defp panel_state?(state) when state in [:loading, :no_dates, :empty, :unknown], do: true
  defp panel_state?(_state), do: false
end

defmodule GtfsPlannerWeb.Components.GtfsVersionSwitcher do
  @moduledoc """
  LiveComponent for the GTFS version dropdown switcher with inline rename.

  Renders a labeled pill suitable for the top navigation bar. The select
  binding is preserved verbatim so the existing `GtfsVersionHook` continues
  to drive version switching via localStorage and navigation.

  On successful rename, sends `{:gtfs_version_renamed, %GtfsVersion{}}` to
  the parent LiveView process.
  """

  use GtfsPlannerWeb, :live_component

  alias GtfsPlanner.Versions

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign_new(:editing?, fn -> false end)
      |> assign_new(:form, fn -> nil end)
      |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="gtfs-version-switcher"
      phx-hook="GtfsVersionHook"
      data-organization-id={@organization_id}
      class="flex items-center gap-2 bg-base-200 rounded-full pl-3 pr-1 py-1"
    >
      <%= if @editing? do %>
        <.form
          for={@form}
          id="gtfs-version-rename-form"
          phx-target={@myself}
          phx-change="validate"
          phx-submit="save"
          class="flex items-center gap-2"
        >
          <.input field={@form[:name]} type="text" label="Name" />
          <button type="submit" class="btn btn-primary btn-sm">Save changes</button>
          <button
            type="button"
            phx-click="cancel_edit"
            phx-target={@myself}
            class="btn btn-ghost btn-sm"
          >
            Cancel
          </button>
        </.form>
      <% else %>
        <label
          for="gtfs-version-select"
          class="text-sm font-medium text-base-content/70 whitespace-nowrap"
        >
          GTFS Version:
        </label>
        <select
          id="gtfs-version-select"
          name="version"
          aria-label="Select GTFS version"
          class="select select-sm select-ghost rounded-full bg-base-100 min-w-[120px] focus:outline-none focus:ring-2 focus:ring-primary"
        >
          <option :for={{id, name} <- @versions} value={id} selected={id == @current_version.id}>
            {name}
          </option>
        </select>
        <button
          type="button"
          phx-click="start_edit"
          phx-target={@myself}
          aria-label="Rename version"
          title="Rename version"
          class="btn btn-ghost btn-square min-h-11 h-11 w-11"
        >
          <.icon name="hero-pencil-square" class="w-4 h-4" />
        </button>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("start_edit", _params, socket) do
    form = to_form(Versions.change_gtfs_version(socket.assigns.current_version))
    {:noreply, assign(socket, editing?: true, form: form)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing?: false, form: nil)}
  end

  def handle_event("validate", %{"gtfs_version" => attrs}, socket) do
    changeset =
      socket.assigns.current_version
      |> Versions.change_gtfs_version(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"gtfs_version" => attrs}, socket) do
    case Versions.update_gtfs_version(socket.assigns.current_version, attrs) do
      {:ok, updated} ->
        send(self(), {:gtfs_version_renamed, updated})

        {:noreply,
         assign(socket, editing?: false, form: nil, current_version: updated)}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end

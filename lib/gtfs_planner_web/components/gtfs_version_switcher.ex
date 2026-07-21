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
  alias Phoenix.LiveView.JS

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> reset_edit_if_version_changed(assigns)
      |> assign_new(:editing?, fn -> false end)
      |> assign_new(:form, fn -> nil end)
      |> assign(assigns)

    {:ok, socket}
  end

  defp reset_edit_if_version_changed(socket, %{current_version: %{id: incoming_id}}) do
    case socket.assigns do
      %{current_version: %{id: ^incoming_id}} -> socket
      %{current_version: %{}} -> assign(socket, editing?: false, form: nil)
      _ -> socket
    end
  end

  defp reset_edit_if_version_changed(socket, _assigns), do: socket

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        open_panel:
          JS.toggle(to: "#gtfs-version-panel")
          |> JS.toggle_attribute({"aria-expanded", "true", "false"},
            to: "#gtfs-version-trigger"
          ),
        close_panel:
          JS.hide(to: "#gtfs-version-panel")
          |> JS.set_attribute({"aria-expanded", "false"}, to: "#gtfs-version-trigger")
      )

    ~H"""
    <div
      id="gtfs-version-switcher"
      phx-hook="GtfsVersionHook"
      data-organization-id={@organization_id}
      data-current-version={@current_version.id}
      class="relative inline-flex w-fit flex-wrap items-center gap-2"
    >
      <div id="version-control" class="relative">
        <button
          id="gtfs-version-trigger"
          type="button"
          aria-haspopup="menu"
          aria-expanded="false"
          aria-controls="gtfs-version-panel"
          aria-label={"Version, #{@current_version.name}"}
          phx-click={!@editing? && @open_panel}
          class="inline-flex items-center gap-2 max-w-[14rem] bg-base-100 border border-control-border rounded-md pl-3 pr-2 min-h-11 text-sm font-medium hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2 disabled:opacity-60 disabled:pointer-events-none"
        >
          <span class="flex-none font-normal text-base-content/60">Version</span>
          <span class="truncate text-base-content">{@current_version.name}</span>
          <.icon name="hero-chevron-down" class="size-3.5 flex-none text-base-content/60" />
        </button>

        <%= if @editing? do %>
          <div
            id="gtfs-version-rename-panel"
            class="absolute right-0 top-full mt-1 w-72 z-30 rounded-lg border border-base-300 bg-base-100 shadow-lg p-3"
          >
            <.form
              for={@form}
              id="gtfs-version-rename-form"
              phx-target={@myself}
              phx-change="validate"
              phx-submit="save"
              class="flex flex-col gap-2"
            >
              <label for="gtfs-version-rename-input" class="text-sm font-medium text-base-content/70">
                Version name
              </label>
              <input
                type="text"
                id="gtfs-version-rename-input"
                name="gtfs_version[name]"
                value={Phoenix.HTML.Form.normalize_value("text", @form[:name].value)}
                aria-invalid={to_string(@form[:name].errors != [])}
                aria-describedby={@form[:name].errors != [] && "gtfs-version-rename-error"}
                phx-mounted={JS.focus()}
                class={[
                  "input input-sm w-full",
                  @form[:name].errors != [] && "input-error"
                ]}
              />
              <p
                :if={@form[:name].errors != []}
                id="gtfs-version-rename-error"
                class="text-sm text-error"
              >
                {@form[:name].errors |> Enum.map(&translate_error/1) |> Enum.join(", ")}
              </p>
              <div class="flex items-center justify-end gap-2 pt-1">
                <button
                  type="button"
                  phx-click="cancel_edit"
                  phx-target={@myself}
                  class="btn btn-ghost btn-sm"
                >
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm" phx-disable-with="Saving name…">
                  Save changes
                </button>
              </div>
            </.form>
          </div>
        <% else %>
          <div
            id="gtfs-version-panel"
            role="menu"
            aria-label="Switch version"
            phx-click-away={@close_panel}
            phx-window-keydown={@close_panel}
            phx-key="escape"
            style="display: none;"
            class="absolute right-0 top-full mt-1 w-64 max-h-80 overflow-auto z-30 rounded-lg border border-base-300 bg-base-100 shadow-lg text-sm"
          >
            <button
              id="gtfs-version-rename"
              type="button"
              role="menuitem"
              phx-click={@close_panel |> JS.push("start_edit", target: @myself)}
              class="block w-full px-3 py-2 min-h-11 text-left hover:bg-base-200 focus:outline-none focus:bg-base-200"
            >
              Rename version…
            </button>
            <div class="border-t border-base-300 my-1"></div>
            <div class="px-3 py-1.5 text-[11px] font-medium uppercase tracking-wide text-base-content/40">
              Switch version
            </div>
            <button
              :for={{id, name} <- @versions}
              id={"gtfs-version-option-#{id}"}
              type="button"
              role="menuitem"
              data-version-option
              data-version-id={id}
              aria-current={id == @current_version.id && "true"}
              phx-click={@close_panel}
              class={[
                "flex w-full items-center justify-between gap-2 px-3 py-2 min-h-11 text-left hover:bg-base-200 focus:outline-none focus:bg-base-200 disabled:opacity-60 disabled:pointer-events-none",
                id == @current_version.id && "bg-primary/10 text-primary font-medium"
              ]}
            >
              <span class="truncate">{name}</span>
              <span :if={id == @current_version.id} aria-hidden="true" class="flex-none">
                <.icon name="hero-check" class="size-4" />
              </span>
            </button>
          </div>
        <% end %>
      </div>
      <div id="gtfs-version-pending" hidden class="text-sm text-base-content/70">
        Switching version…
      </div>
      <div id="gtfs-version-failure" hidden class="flex items-center gap-2">
        <span class="text-sm text-error">Version switch failed.</span>
        <button type="button" id="gtfs-version-retry" class="btn btn-ghost btn-xs text-primary">
          Retry
        </button>
      </div>
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

        {:noreply, assign(socket, editing?: false, form: nil, current_version: updated)}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end

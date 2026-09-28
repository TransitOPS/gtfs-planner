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
      class="relative inline-flex w-fit min-w-0 max-w-full flex-wrap items-center gap-2"
    >
      <div id="version-control" class="relative min-w-0">
        <button
          id="gtfs-version-trigger"
          type="button"
          aria-haspopup="menu"
          aria-expanded="false"
          aria-controls="gtfs-version-panel"
          aria-label={"Version, #{@current_version.name}"}
          phx-click={!@editing? && @open_panel}
          class="inline-flex min-h-11 min-w-0 max-w-full items-center gap-2 rounded-control border border-control bg-white pl-3 pr-2.5 text-sm hover:bg-canvas disabled:pointer-events-none disabled:opacity-60"
        >
          <span class="shrink-0 text-muted">Version</span>
          <span class="min-w-0 max-w-[17rem] truncate font-semibold text-strong">
            {@current_version.name}
          </span>
          <.icon name="hero-chevron-down" class="size-4 shrink-0 text-muted" />
        </button>

        <%= if @editing? do %>
          <div
            id="gtfs-version-rename-panel"
            class="absolute right-0 top-full z-30 mt-2 w-72 rounded-card border border-subtle bg-white p-3 shadow-float"
          >
            <.form
              for={@form}
              id="gtfs-version-rename-form"
              phx-target={@myself}
              phx-change="validate"
              phx-submit="save"
              class="flex flex-col gap-2"
            >
              <label for="gtfs-version-rename-input" class="text-[13px] font-semibold text-muted">
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
          <%!-- The reference's 320px panel above md; below md the reference has no
          version menu at all (the deferred phone Menu replaces it), so the panel
          keeps the component's narrower width to stay inside the viewport. --%>
          <div
            id="gtfs-version-panel"
            role="menu"
            aria-label="Switch version"
            phx-click-away={@close_panel}
            phx-window-keydown={@close_panel}
            phx-key="escape"
            style="display: none;"
            class="absolute right-0 top-full z-30 mt-2 max-h-80 w-80 max-md:w-64 overflow-auto rounded-card border border-subtle bg-white p-2 text-sm shadow-float"
          >
            <p class="px-3 pb-1 pt-2 text-[13px] font-semibold text-muted">Switch version</p>
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
                "flex w-full min-h-11 items-center justify-between gap-2 rounded-control px-3 text-left hover:bg-canvas focus:bg-canvas disabled:pointer-events-none disabled:opacity-60",
                if(id == @current_version.id,
                  do: "bg-selection font-semibold text-action",
                  else: "text-strong"
                )
              ]}
            >
              <span class="truncate">{name}</span>
              <span :if={id == @current_version.id} aria-hidden="true" class="flex-none">
                <.icon name="hero-check" class="size-4" />
              </span>
            </button>
            <div class="my-1 border-t border-subtle"></div>
            <button
              id="gtfs-version-rename"
              type="button"
              role="menuitem"
              phx-click={@close_panel |> JS.push("start_edit", target: @myself)}
              class="flex w-full min-h-11 items-center rounded-control px-3 text-left text-strong hover:bg-canvas focus:bg-canvas"
            >
              Rename version…
            </button>
          </div>
        <% end %>
      </div>
      <div id="gtfs-version-pending" hidden class="text-sm text-muted">
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

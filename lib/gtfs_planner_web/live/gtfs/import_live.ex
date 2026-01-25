defmodule GtfsPlannerWeb.Gtfs.ImportLive do
  @moduledoc """
  LiveView for importing GTFS data.
  Requires the pathways_studio_editor role (editor only, not viewer).
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Versions

  on_mount {GtfsPlannerWeb.UserAuth, :ensure_authenticated}
  on_mount GtfsPlannerWeb.AssignOrganization
  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_editor}

  @impl true
  def mount(_params, _session, socket) do
    # Check if version resolution is pending (versionless route)
    if socket.assigns[:gtfs_version_pending] do
      {:ok,
       socket
       |> assign(:page_title, "Import GTFS")
       |> assign(:pending_version_resolution, true)}
    else
      user_roles = get_user_roles(socket)

      {:ok,
       socket
       |> assign(:page_title, "Import GTFS")
       |> assign(:user_roles, user_roles)
       |> allow_upload(:gtfs_files,
         accept: ~w(.txt .csv),
         max_entries: 10,
         max_file_size: 200_000_000
       )
       |> assign(:form, to_form(%{"create_version" => false, "version_name" => ""}, as: :gtfs_import_form))
       |> assign(:import_result, nil)
       |> assign(:version_name_touched, false)
       |> assign(:import_task, nil)
       |> assign(:import_progress, nil)
       |> assign(:importing, false)}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    # Guard clause: if pending version resolution, we need to redirect to a version
    if socket.assigns[:pending_version_resolution] do
      current_organization = socket.assigns.current_organization

      # Use the version from localStorage if valid, otherwise fetch latest
      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          # Fetch latest version for the organization
          case Versions.get_latest_gtfs_version(current_organization.id) do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
          end
        end

      if version_to_use do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/import")}
      else
        # No versions available, stay on pending page
        {:noreply, socket}
      end
    else
      # Normal flow: we already have a current version
      current_organization = socket.assigns.current_organization
      current_version_id = to_string(socket.assigns.current_gtfs_version.id)

      # Try to use the stored version_id from localStorage
      version_to_use =
        if version_id && valid_version_for_org?(version_id, current_organization.id) do
          version_id
        else
          # Fall back to latest version or current version
          case socket.assigns[:latest_gtfs_version] do
            {:ok, version} -> to_string(version.id)
            {:error, :no_versions} -> nil
            # Already on a valid route
            nil -> current_version_id
          end
        end

      # Only navigate if switching to a different version
      if version_to_use && version_to_use != current_version_id do
        {:noreply, push_navigate(socket, to: "/gtfs/#{version_to_use}/import")}
      else
        # Already on correct version, do nothing
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    # Push event to JS hook to update localStorage
    socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

    # Navigate to new version
    {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/import")}
  end

  @impl true
  def handle_event("validate", params, socket) do
    form_data = params["gtfs_import_form"] || %{}
    create_version = form_data["create_version"] == "true"
    version_name = form_data["version_name"] || ""

    # Only show validation errors if user has touched the field
    errors =
      if create_version && String.trim(version_name) == "" && socket.assigns.version_name_touched do
        [version_name: "Version name is required"]
      else
        []
      end

    form = to_form(form_data, as: :gtfs_import_form, errors: errors)

    # Reset version_name_touched when not creating a new version, so that
    # re-enabling "Create a new GTFS version" doesn't immediately show errors.
    socket =
      socket
      |> assign(:form, form)
      |> assign(:version_name_touched, if(create_version, do: socket.assigns.version_name_touched, else: false))

    {:noreply, socket}
  end

  @impl true
  def handle_event("version_name_blur", _params, socket) do
    {:noreply, assign(socket, :version_name_touched, true)}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :gtfs_files, ref)}
  end

  @impl true
  def handle_event("import", params, socket) do
    # Extract form data (nested under gtfs_import_form)
    form_data = params["gtfs_import_form"] || %{}
    create_version = form_data["create_version"] == "true"
    version_name = form_data["version_name"] || ""

    # Validate required fields
    if create_version && String.trim(version_name) == "" do
      {:noreply,
       socket
       |> assign(:version_name_touched, true)
       |> assign(:form, to_form(form_data, as: :gtfs_import_form, errors: [version_name: "Version name is required"]))}
    else
      # Determine GTFS version ID
      gtfs_version_id =
        if create_version && version_name != "" do
          case Versions.create_gtfs_version(socket.assigns.current_organization.id, %{name: version_name}) do
            {:ok, version} -> version.id
            {:error, _changeset} ->
              # If version creation fails, fall back to current version
              socket.assigns.current_gtfs_version.id
          end
        else
          socket.assigns.current_gtfs_version.id
        end

      # Consume uploaded files
      uploaded_files =
        consume_uploaded_entries(socket, :gtfs_files, fn %{path: path}, entry ->
          {:ok, %{filename: entry.client_name, content: File.read!(path)}}
        end)

      # Run import in async task to avoid blocking LiveView process
      task =
        Task.async(fn ->
          GtfsPlanner.Gtfs.Import.import_files(
            socket.assigns.current_organization.id,
            gtfs_version_id,
            uploaded_files
          )
        end)

      # The import_files/3 function returns {:ok, {counts, unrecognized, topic}}
      # We need to subscribe to the progress topic, but we'll do that in handle_info
      # when we receive the task result, since the topic is generated inside import_files

      {:noreply,
       socket
       |> assign(:import_task, task.ref)
       |> assign(:importing, true)
       |> assign(:import_result, nil)
       |> assign(:import_progress, nil)}
    end
  end

  @impl true
  def handle_info({:import_progress, progress}, socket) do
    {:noreply, assign(socket, :import_progress, progress)}
  end

  @impl true
  def handle_info({ref, result}, socket) when socket.assigns.import_task == ref do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        {:ok, {counts, unrecognized, topic}} ->
          # Subscribe to progress topic for future updates (though import is done)
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

          socket
          |> assign(:import_result, {:ok, counts, unrecognized})
          |> assign(:importing, false)
          |> assign(:import_task, nil)

        {:error, error_msg} when is_binary(error_msg) ->
          assign_import_error(socket, error_msg)

        {:error, error_map} when is_map(error_map) ->
          error_msg = extract_error_message(error_map)
          assign_import_error(socket, error_msg)

        {:error, _failed_operation, failed_value, _changes_so_far} ->
          error_msg = extract_error_message(failed_value)
          assign_import_error(socket, error_msg)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket)
      when socket.assigns.import_task == ref do
    # Task crashed or was killed
    socket =
      socket
      |> assign(:import_result, {:error, "Import process failed unexpectedly"})
      |> assign(:importing, false)
      |> assign(:import_task, nil)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if assigns[:pending_version_resolution] do %>
      <%!-- Pending version resolution - mount the hook to trigger redirect --%>
      <div
        id="gtfs-version-resolver"
        phx-hook="GtfsVersionHook"
        data-organization-id={@current_organization.id}
      >
        <div class="flex items-center justify-center min-h-screen">
          <div class="text-center">
            <div class="loading loading-spinner loading-lg"></div>
            <p class="mt-4 text-base-content/60">Loading GTFS version...</p>
          </div>
        </div>
      </div>
    <% else %>
        <Layouts.app
          flash={@flash}
          current_user={@current_user}
          current_organization={@current_organization}
          user_roles={@user_roles}
          current_path={@current_path}
          current_gtfs_version={assigns[:current_gtfs_version]}
          available_versions={assigns[:available_versions] || []}
        >
          <.header>
            Import GTFS
            <:subtitle>
              Upload GTFS files to import levels, stops, and pathways
            </:subtitle>
          </.header>

          <div class="mt-8">
            <div class="bg-base-100 rounded-lg p-6">
              <.form
                for={@form}
                id="gtfs-import-form"
                class="space-y-6"
                phx-change="validate"
                phx-submit="import"
              >
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">GTFS Files</span>
                  </label>
                  <label class="flex flex-col items-center justify-center w-full h-40 border-2 border-dashed border-base-300 rounded-lg cursor-pointer bg-base-200 hover:bg-base-300 transition-colors">
                    <div class="flex flex-col items-center justify-center pt-5 pb-6">
                      <.icon name="hero-arrow-up-tray" class="w-10 h-10 mb-3 text-base-content/60" />
                      <p class="mb-2 text-sm font-medium">
                        <span class="text-primary">Click to upload</span> or drag and drop
                      </p>
                      <p class="text-xs text-base-content/60">
                        routes.txt, route_patterns.txt, calendar.txt, calendar_dates.txt, trips.txt, levels.txt, stops.txt, stop_times.txt, pathways.txt (max 10 files, 200MB each)
                      </p>
                    </div>
                    <.live_file_input upload={@uploads.gtfs_files} class="sr-only" />
                  </label>

                  <%!-- Upload entries display --%>
                  <%= for entry <- @uploads.gtfs_files.entries do %>
                    <div class={[
                      "flex items-center justify-between mt-2 p-2 rounded",
                      upload_errors(@uploads.gtfs_files, entry) == [] && "bg-base-200",
                      upload_errors(@uploads.gtfs_files, entry) != [] && "bg-error/10 border border-error"
                    ]}>
                      <div class="flex-1">
                        <span class="text-sm font-medium"><%= entry.client_name %></span>
                        <%= if upload_errors(@uploads.gtfs_files, entry) == [] do %>
                          <div class="w-full bg-base-300 rounded-full h-2 mt-1">
                            <div
                              class="bg-primary h-2 rounded-full transition-all duration-300"
                              style={"width: #{entry.progress}%"}
                            >
                            </div>
                          </div>
                          <span class="text-xs text-base-content/60">
                            <%= entry.progress %>% uploaded
                          </span>
                        <% else %>
                          <%= for error <- upload_errors(@uploads.gtfs_files, entry) do %>
                            <div class="flex items-center gap-2 mt-1">
                              <.icon name="hero-exclamation-circle" class="w-4 h-4 text-error" />
                              <span class="text-sm text-error"><%= upload_error_to_string(error) %></span>
                            </div>
                          <% end %>
                        <% end %>
                      </div>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs ml-2"
                        phx-click="cancel-upload"
                        phx-value-ref={entry.ref}
                      >
                        Cancel
                      </button>
                    </div>
                  <% end %>

                  <%!-- Upload errors --%>
                  <%= for error <- upload_errors(@uploads.gtfs_files) do %>
                    <div class="alert alert-error mt-2">
                      <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>
                      <span class="text-sm"><%= upload_error_to_string(error) %></span>
                    </div>
                  <% end %>
                </div>

                <div class="form-control">
                  <label class="label cursor-pointer justify-start gap-4">
                    <input
                      type="checkbox"
                      name="gtfs_import_form[create_version]"
                      value="true"
                      class="toggle toggle-primary"
                      checked={@form[:create_version].value}
                    />
                    <div>
                      <span class="label-text font-medium">Create a new GTFS version</span>
                      <p class="text-xs text-base-content/60 mt-0.5">
                        Import into a new version instead of the current one
                      </p>
                    </div>
                  </label>
                </div>

                <%= if @form[:create_version].value do %>
                  <div class="form-control pl-14">
                    <label class="label">
                      <span class="label-text">Version Name</span>
                    </label>
                    <input
                      type="text"
                      name="gtfs_import_form[version_name]"
                      class={[
                        "input input-bordered w-full",
                        @form[:version_name].errors != [] && "input-error"
                      ]}
                      placeholder="e.g., Spring 2025 Schedule"
                      value={@form[:version_name].value}
                      phx-blur="version_name_blur"
                    />
                    <%= if @form[:version_name].errors != [] do %>
                      <p class="text-error text-sm mt-1">
                        <%= Enum.join(@form[:version_name].errors, ", ") %>
                      </p>
                    <% else %>
                      <p class="text-base-content/50 text-xs mt-1">
                        Give this version a descriptive name
                      </p>
                    <% end %>
                  </div>
                <% end %>

                <div class="form-control">
                  <button type="submit" class="btn btn-primary" disabled={@uploads.gtfs_files.entries == [] || @importing}>
                    <%= if @importing do %>
                      <span class="loading loading-spinner loading-sm"></span>
                      Importing...
                    <% else %>
                      Import Files
                    <% end %>
                  </button>
                </div>
              </.form>

              <%= if @importing && @import_progress do %>
                <div class="mt-6 pt-6 border-t border-base-300">
                  <div class="space-y-4">
                    <div>
                      <div class="flex justify-between mb-2">
                        <span class="text-sm font-medium">
                          Processing: <%= @import_progress.file %>
                        </span>
                        <span class="text-sm text-base-content/60">
                          <%= @import_progress.processed %> / <%= @import_progress.total %> rows
                        </span>
                      </div>
                      <progress
                        class="progress progress-primary w-full"
                        value={@import_progress.processed}
                        max={@import_progress.total}
                      >
                      </progress>
                    </div>
                  </div>
                </div>
              <% end %>

              <%= if @import_result do %>
                <div class="mt-6 pt-6 border-t border-base-300">
                  <%= case @import_result do %>
                    <% {:ok, counts, unrecognized} -> %>
                      <div class="alert alert-success">
                        <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>
                        <div>
                          <h3 class="font-bold">Import Successful</h3>
                          <div class="text-xs">
                            Imported <%= counts.routes %> routes, <%= counts.calendars %> calendars, <%= counts.calendar_dates %> calendar dates, <%= counts.route_patterns %> route patterns, <%= counts.trips %> trips, <%= counts.levels %> levels, <%= counts.stops %> stops, <%= counts.stop_times %> stop times, <%= counts.pathways %> pathways.
                          </div>
                        </div>
                      </div>
                      <%= if unrecognized != [] do %>
                        <div class="alert alert-warning mt-2">
                          <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" /></svg>
                          <div>
                            <h3 class="font-bold">Unrecognized Files Skipped</h3>
                            <div class="text-xs">
                              <%= Enum.join(unrecognized, ", ") %>
                            </div>
                          </div>
                        </div>
                      <% end %>
                    <% {:error, error_msg} -> %>
                      <div class="alert alert-error">
                        <svg xmlns="http://www.w3.org/2000/svg" class="stroke-current shrink-0 h-6 w-6" fill="none" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z" /></svg>
                        <div>
                          <h3 class="font-bold">Import Failed</h3>
                          <div class="text-xs">
                            <%= error_msg %>
                          </div>
                        </div>
                      </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </Layouts.app>
    <% end %>
    """
  end

  defp get_user_roles(socket) do
    user = socket.assigns[:current_user]
    organization = socket.assigns[:current_organization]

    case GtfsPlanner.Accounts.get_user_org_membership(user.id, organization.id) do
      %UserOrgMembership{roles: roles} when is_list(roles) -> roles
      _ -> []
    end
  end

  defp valid_version_for_org?(version_id, organization_id) do
    try do
      case Versions.get_gtfs_version(version_id) do
        nil -> false
        version -> version.organization_id == organization_id
      end
    rescue
      _ -> false
    end
  end

  defp assign_import_error(socket, error_msg) do
    socket
    |> assign(:import_result, {:error, error_msg})
    |> assign(:importing, false)
    |> assign(:import_task, nil)
  end

  defp extract_error_message(failed_value) do
    case failed_value do
      # Map error from BatchProcessor with row info
      %{file: file, row: row, reason: reason} ->
        reason_str =
          case reason do
            binary_reason when is_binary(binary_reason) -> binary_reason
            other_reason -> inspect(other_reason)
          end

        "Error in #{file} on row #{row}: #{reason_str}"

      # Map error from BatchProcessor with constraint violation
      %{file: file, constraint: constraint, message: message} ->
        "Error in #{file}: constraint violation (#{constraint}) - #{message}"

      # Map error from BatchProcessor with Postgres error
      %{file: file, postgres_error: code, constraint: constraint, message: message} ->
        constraint_part =
          case constraint do
            nil -> ""
            constraint_value -> " (#{constraint_value})"
          end

        "Error in #{file}: database error #{code}#{constraint_part} - #{message}"

      # Map error from BatchProcessor with generic error
      %{file: file, error: error_message} ->
        "Error in #{file}: #{error_message}"

      # Generic map with message key
      %{message: message} when is_binary(message) ->
        message

      {changeset, line_number} when is_integer(line_number) ->
        "Error in pathways.txt on line #{line_number + 1}: #{extract_error_message(changeset)}"

      %Ecto.Changeset{} = changeset ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Enum.reduce(opts, msg, fn {key, value}, acc ->
              String.replace(acc, "%{#{key}}", to_string(value))
            end)
          end)

        error_strings =
          for {field, messages} <- errors,
              message <- messages do
            "#{field}: #{message}"
          end

        if error_strings == [] do
          "Validation failed"
        else
          Enum.join(error_strings, ", ")
        end

      error when is_binary(error) ->
        error

      _ ->
        "Unknown error"
    end
  end

  defp upload_error_to_string(:too_large), do: "File exceeds 200MB limit"
  defp upload_error_to_string(:too_many_files), do: "Maximum 10 files allowed"
  defp upload_error_to_string(:not_accepted), do: "Only .txt and .csv files accepted"
  defp upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp upload_error_to_string({:error, reason}), do: reason
  defp upload_error_to_string(error) when is_binary(error), do: error
  defp upload_error_to_string(_), do: "Upload error"
end

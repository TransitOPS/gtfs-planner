defmodule GtfsPlannerWeb.Gtfs.ImportLive do
  @moduledoc """
  LiveView for importing GTFS data.
  Requires the pathways_studio_editor role (editor only, not viewer).
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Result, Diff, DiffDecision, RowParser}
  alias GtfsPlanner.Gtfs.Import.Publication
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_editor}

  # List of recognized GTFS filenames
  @recognized_gtfs_files MapSet.new(Import.supported_filenames())

  @diff_filters %{
    "all" => :all,
    "add" => :add,
    "modify" => :modify,
    "remove" => :remove,
    "conflict" => :conflict
  }

  @diff_actions %{
    "add" => :add,
    "modify" => :modify,
    "remove" => :remove,
    "conflict" => :conflict
  }

  def recognized_gtfs_filenames do
    @recognized_gtfs_files
  end

  @impl true
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Import GTFS")
     |> assign(:user_roles, user_roles)
     |> allow_upload(:gtfs_files,
       accept: ~w(.txt .csv .zip),
       max_entries: 50,
       max_file_size: 200_000_000
     )
     |> allow_upload(:diff_files,
       accept: ~w(.txt .csv .zip),
       max_entries: 3,
       max_file_size: 50_000_000
     )
     |> assign(
       :form,
       to_form(%{"version_name" => ""}, as: :gtfs_import_form)
     )
     |> assign(:import_result, nil)
     |> assign(:import_target, nil)
     |> assign(:published_version, nil)
     |> assign(:version_name_touched, false)
     |> assign(:import_task, nil)
     |> assign(:import_progress, nil)
     |> assign(:importing, false)
     |> assign(:unrecognized_upload_files, [])
     |> assign(:diff_step, :upload)
     |> assign(:diff_summary, empty_diff_summary())
     |> assign(:diff_filter, :all)
     |> assign(:diff_parse_errors, [])
     |> assign(:apply_results, [])
     |> assign(:decisions_by_id, %{})
     |> stream(:diff_decisions, [])}
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_organization = socket.assigns.current_organization
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/import")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    current_organization = socket.assigns.current_organization

    if Versions.published_gtfs_version_for_org?(current_organization.id, version_id) do
      # Push event to JS hook to update localStorage
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      # Navigate to new version
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/import")}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    form_data = params["gtfs_import_form"] || %{}
    version_name = form_data["version_name"] || ""

    # Only surface the required-name error once the field has been touched
    # (blur or a prior submit); a blank name is never hidden behind a disabled
    # button.
    errors =
      if String.trim(version_name) == "" && socket.assigns.version_name_touched do
        [version_name: "Version name is required"]
      else
        []
      end

    form = to_form(form_data, as: :gtfs_import_form, errors: errors)

    # Check for unrecognized files in uploads (.zip archives are always recognized)
    unrecognized_files =
      socket.assigns.uploads.gtfs_files.entries
      |> Enum.map(& &1.client_name)
      |> Enum.reject(fn name ->
        lower = String.downcase(name)
        MapSet.member?(@recognized_gtfs_files, lower) or String.ends_with?(lower, ".zip")
      end)

    socket =
      socket
      |> assign(:form, form)
      |> assign(:unrecognized_upload_files, unrecognized_files)

    {:noreply, socket}
  end

  @impl true
  def handle_event("validate_diff", _params, socket) do
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
  def handle_event("cancel-diff-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :diff_files, ref)}
  end

  @impl true
  def handle_event("import", params, socket) do
    form_data = params["gtfs_import_form"] || %{}
    version_name = form_data["version_name"] || ""

    cond do
      # Reject a crafted submission while an import is already active so a
      # replayed event cannot bypass the disabled-button state or start a
      # duplicate task for a target already being written.
      socket.assigns.importing ->
        {:noreply, socket}

      # Reject an empty-file submission (no upload entries) so a crafted event
      # cannot start an import with nothing to write.
      socket.assigns.uploads.gtfs_files.entries == [] ->
        {:noreply,
         socket
         |> assign(:version_name_touched, true)
         |> assign(:form, to_form(form_data, as: :gtfs_import_form))
         |> assign(:import_result, {:error, nil, :no_files_selected})}

      true ->
        create_and_start_import(socket, form_data, version_name)
    end
  end

  @impl true
  def handle_event("compute_diff", _params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :diff_files, fn %{path: path}, entry ->
        {:ok, %{filename: entry.client_name, content: File.read!(path)}}
      end)

    {expanded_files, _archive_warnings} = Import.expand_archives(uploaded_files)

    case categorize_diff_files(expanded_files) do
      {:error, duplicate_errors} ->
        {:noreply,
         socket
         |> assign(:diff_parse_errors, duplicate_errors)
         |> assign(:diff_step, :upload)
         |> assign(:diff_filter, :all)
         |> assign(:diff_summary, empty_diff_summary())
         |> assign(:apply_results, [])
         |> assign(:decisions_by_id, %{})
         |> stream(:diff_decisions, [], reset: true)}

      {:ok, categorized_files} ->
        organization_id = socket.assigns.current_organization.id
        gtfs_version_id = socket.assigns.current_gtfs_version.id

        {levels_upload, level_errors} =
          parse_uploaded_entity_file(categorized_files.levels, "levels.txt", fn row_map ->
            RowParser.level_row_to_attrs(row_map, organization_id, gtfs_version_id)
          end)

        {stops_upload, stop_errors} =
          parse_uploaded_entity_file(categorized_files.stops, "stops.txt", fn row_map ->
            RowParser.stop_row_to_attrs(row_map, organization_id, gtfs_version_id)
          end)

        db_levels = Gtfs.list_levels(organization_id, gtfs_version_id)
        db_stops = Gtfs.list_stops(organization_id, gtfs_version_id)
        db_pathways = Gtfs.list_pathways(organization_id, gtfs_version_id)

        stop_validation_map = build_stop_validation_map(db_stops, stops_upload)

        {pathways_upload, pathway_errors} =
          parse_uploaded_entity_file(categorized_files.pathways, "pathways.txt", fn row_map ->
            RowParser.pathway_row_to_attrs(
              row_map,
              organization_id,
              gtfs_version_id,
              stop_validation_map
            )
          end)

        parse_errors = level_errors ++ stop_errors ++ pathway_errors

        uploaded = %{
          levels: levels_upload,
          stops: stops_upload,
          pathways: pathways_upload
        }

        db = %{
          levels: db_levels,
          stops: db_stops,
          pathways: db_pathways
        }

        decisions = Diff.compute(uploaded, db)
        decisions_by_id = Map.new(decisions, fn decision -> {decision.id, decision} end)
        summary = Diff.summary(decisions)

        {:noreply,
         socket
         |> assign(:diff_parse_errors, parse_errors)
         |> assign(:diff_summary, summary)
         |> assign(:diff_filter, :all)
         |> assign(:apply_results, [])
         |> assign(:decisions_by_id, decisions_by_id)
         |> assign(:diff_step, :review)
         |> stream(:diff_decisions, decisions, reset: true)}
    end
  end

  @impl true
  def handle_event("diff-filter", %{"filter" => filter}, socket) do
    case Map.fetch(@diff_filters, filter) do
      {:ok, filter_atom} ->
        {:noreply,
         socket
         |> assign(:diff_filter, filter_atom)
         |> stream_filtered_diff_decisions()}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("approve-decision", %{"id" => id}, socket) do
    {:noreply, update_decision_status(socket, id, :approved)}
  end

  @impl true
  def handle_event("reject-decision", %{"id" => id}, socket) do
    {:noreply, update_decision_status(socket, id, :rejected)}
  end

  @impl true
  def handle_event("approve-all", %{"action" => action}, socket) do
    case Map.fetch(@diff_actions, action) do
      {:ok, action_atom} ->
        decisions_by_id =
          Enum.reduce(socket.assigns.decisions_by_id, %{}, fn {id, %DiffDecision{} = decision},
                                                              acc ->
            updated_decision =
              if decision.action == action_atom do
                %DiffDecision{decision | status: :approved}
              else
                decision
              end

            Map.put(acc, id, updated_decision)
          end)

        {:noreply,
         socket
         |> assign(:decisions_by_id, decisions_by_id)
         |> stream_filtered_diff_decisions()}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("apply-decisions", _params, socket) do
    approved_decisions =
      socket.assigns.decisions_by_id
      |> Map.values()
      |> Enum.filter(fn decision -> decision.status == :approved end)
      |> order_apply_decisions()

    apply_results =
      Enum.map(approved_decisions, fn decision ->
        {decision.id, apply_decision(decision)}
      end)

    {:noreply,
     socket
     |> assign(:apply_results, apply_results)
     |> assign(:diff_step, :done)}
  end

  @impl true
  def handle_event("reset-diff", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.diff_files.entries, socket, fn entry, acc ->
        cancel_upload(acc, :diff_files, entry.ref)
      end)

    {:noreply,
     socket
     |> assign(:diff_step, :upload)
     |> assign(:diff_summary, empty_diff_summary())
     |> assign(:diff_filter, :all)
     |> assign(:diff_parse_errors, [])
     |> assign(:apply_results, [])
     |> assign(:decisions_by_id, %{})
     |> stream(:diff_decisions, [], reset: true)}
  end

  @impl true
  def handle_info({:import_progress, progress}, socket) do
    {:noreply, assign(socket, :import_progress, progress)}
  end

  @impl true
  def handle_info({ref, result}, socket) when socket.assigns.import_task == ref do
    # The supervised publication task finished; stop monitoring its process.
    Process.demonitor(ref, [:flush])

    {:noreply, apply_import_result(socket, result)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket)
      when socket.assigns.import_task == ref do
    # The supervised publication task crashed before returning a result.
    # Best-effort close the exact target we bound this run to: a still-staging
    # or importing target is failed, while a published or failed terminal state
    # is never overwritten (the conditional transition is a no-op there).
    target = fail_target_best_effort(socket.assigns[:import_target])

    {:noreply,
     socket
     |> assign(:import_target, target)
     |> assign(:import_result, {:error, target, :process_crashed})
     |> assign(:importing, false)
     |> assign(:import_task, nil)}
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
            <div
              id="gtfs-import-destination"
              class="rounded-lg border border-base-300 p-4 bg-base-200"
            >
              <p class="text-sm font-medium">
                Destination: New version “{destination_name(@form)}”
              </p>
              <p class="text-xs text-base-content/70 mt-0.5">
                “{version_display_name(@current_gtfs_version)}” remains available until import succeeds.
              </p>
            </div>

            <div class="form-control">
              <label class="label" for="gtfs-import-version-name">
                <span class="label-text">Version name</span>
              </label>
              <input
                type="text"
                id="gtfs-import-version-name"
                name="gtfs_import_form[version_name]"
                class={[
                  "input input-bordered w-full",
                  @form[:version_name].errors != [] && "input-error"
                ]}
                placeholder="e.g., Spring 2025 Schedule"
                value={@form[:version_name].value}
                phx-blur="version_name_blur"
                aria-invalid={to_string(@form[:version_name].errors != [])}
                aria-describedby="gtfs-import-version-name-error"
              />
              <p
                :if={@form[:version_name].errors != []}
                id="gtfs-import-version-name-error"
                class="text-error text-sm mt-1"
                role="alert"
              >
                {Enum.join(@form[:version_name].errors, ", ")}
              </p>
            </div>

            <div class="form-control">
              <label class="label">
                <span class="label-text">GTFS Files</span>
              </label>
              <label class="flex flex-col items-center justify-center w-full h-40 border-2 border-dashed border-base-300 rounded-lg cursor-pointer bg-base-200 hover:bg-base-300 transition-colors">
                <div class="flex flex-col items-center justify-center pt-5 pb-6 px-6">
                  <.icon name="hero-arrow-up-tray" class="w-10 h-10 mb-3 text-base-content/60" />
                  <p class="mb-2 text-sm font-medium">
                    <span class="text-primary">Click to upload</span> or drag and drop
                  </p>
                  <p class="text-xs text-base-content/60">
                    GTFS .txt/.csv files or a .zip archive (max 50 files, 200MB each)
                  </p>
                </div>
                <.live_file_input upload={@uploads.gtfs_files} class="sr-only" />
              </label>
            </div>

            <%!-- Unrecognized files warning --%>
            <%= if @unrecognized_upload_files != [] do %>
              <div class="alert alert-warning alert-soft mt-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="stroke-current shrink-0 h-6 w-6 text-warning"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                  />
                </svg>
                <div class="text-base-content">
                  <h3 class="font-bold">Unrecognized Files</h3>
                  <div class="text-xs">
                    The following files are not recognized GTFS files and will be skipped during import: {Enum.join(
                      @unrecognized_upload_files,
                      ", "
                    )}
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Upload errors --%>
            <%= for error <- upload_errors(@uploads.gtfs_files) do %>
              <div class="alert alert-error alert-soft mt-2">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="stroke-current shrink-0 h-6 w-6"
                  fill="none"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                  />
                </svg>
                <span class="text-sm">{upload_error_to_string(error)}</span>
              </div>
            <% end %>

            <div class="form-control">
              <button
                type="submit"
                id="gtfs-import-submit"
                class="btn btn-primary"
                disabled={@uploads.gtfs_files.entries == [] || @importing}
              >
                <%= if @importing do %>
                  <span class="loading loading-spinner loading-sm"></span> Importing…
                <% else %>
                  Import feed
                <% end %>
              </button>
            </div>

            <%!-- Upload entries display --%>
            <%= for entry <- @uploads.gtfs_files.entries do %>
              <div class={[
                "flex items-center justify-between mt-2 p-2 rounded",
                upload_errors(@uploads.gtfs_files, entry) == [] && "bg-base-200",
                upload_errors(@uploads.gtfs_files, entry) != [] && "bg-error/10 border border-error"
              ]}>
                <div class="flex-1">
                  <span class="text-sm font-medium">{entry.client_name}</span>
                  <%= if upload_errors(@uploads.gtfs_files, entry) == [] do %>
                    <div class="w-full bg-base-300 rounded-full h-2 mt-1">
                      <div
                        class="bg-primary h-2 rounded-full transition-all duration-300"
                        style={"width: #{entry.progress}%"}
                      >
                      </div>
                    </div>
                    <span class="text-xs text-base-content/60">
                      {entry.progress}% uploaded
                    </span>
                  <% else %>
                    <%= for error <- upload_errors(@uploads.gtfs_files, entry) do %>
                      <div class="flex items-center gap-2 mt-1">
                        <.icon name="hero-exclamation-circle" class="w-4 h-4 text-error" />
                        <span class="text-sm text-error">{upload_error_to_string(error)}</span>
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
          </.form>

          <div id="gtfs-import-status" aria-live="polite" role="status">
            <%= if @importing && @import_progress do %>
              <div class="mt-6 pt-6 border-t border-base-300">
                <div class="space-y-4">
                  <div>
                    <div class="flex justify-between mb-2">
                      <span class="text-sm font-medium">
                        Processing: {@import_progress.file}
                      </span>
                      <span class="text-sm text-base-content/60">
                        {@import_progress.processed} / {@import_progress.total} rows
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
          </div>

          <%= if @import_result do %>
            <div
              id="gtfs-import-result"
              class="mt-6 pt-6 border-t border-base-300"
              aria-live="assertive"
            >
              <%= case @import_result do %>
                <% {:ok, published, %Import.Result{counts: counts, unrecognized_files: unrecognized}} -> %>
                  <div class="alert border border-green-300 bg-green-100 text-black">
                    <.icon name="hero-check-circle" class="shrink-0 h-6 w-6" />
                    <div>
                      <h3 class="font-bold">Import successful</h3>
                      <div class="text-xs">
                        Imported into new version “{published.name}”: {counts.levels} levels, {counts.stops} stops, {counts.pathways} pathways.
                      </div>
                      <div :if={unrecognized != []} class="text-xs mt-1">
                        Unrecognized files skipped: {Enum.join(unrecognized, ", ")}
                      </div>
                      <.link
                        id="gtfs-import-view-version"
                        navigate={~p"/gtfs/#{published.id}/routes"}
                        class="link link-primary text-sm mt-2 inline-block"
                      >
                        View version
                      </.link>
                    </div>
                  </div>
                <% {:error, target, {:publication_failed, _reason}} -> %>
                  <div class="alert alert-error alert-soft">
                    <.icon name="hero-exclamation-triangle" class="shrink-0 h-6 w-6" />
                    <div>
                      <h3 class="font-bold">Publication failed</h3>
                      <div class="text-xs">
                        Version “{target_name(target)}” finished importing but could not be published. It remains unavailable for reconciliation.
                      </div>
                    </div>
                  </div>
                <% {:error, nil, :no_files_selected} -> %>
                  <div class="alert alert-error alert-soft">
                    <.icon name="hero-exclamation-triangle" class="shrink-0 h-6 w-6" />
                    <div>
                      <h3 class="font-bold">Import failed</h3>
                      <div class="text-xs">Select at least one file to import.</div>
                    </div>
                  </div>
                <% {:error, target, reason} -> %>
                  <div class="alert alert-error alert-soft">
                    <.icon name="hero-exclamation-triangle" class="shrink-0 h-6 w-6" />
                    <div>
                      <h3 class="font-bold">Import failed</h3>
                      <div class="text-xs">
                        Version “{target_name(target)}” was not published. {format_import_error(
                          reason
                        )}
                      </div>
                    </div>
                  </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <div class="mt-8">
        <div class="bg-base-100 rounded-lg p-6">
          <div class="flex flex-col gap-2">
            <h2 class="text-xl font-semibold">Update Station Data</h2>
            <p class="text-sm text-base-content/70">
              Upload `levels.txt`, `stops.txt`, and/or `pathways.txt` to review and apply station data diffs.
            </p>
            <p id="diff-destination" class="text-xs text-base-content/60">
              Reviewed changes apply to version “{version_display_name(@current_gtfs_version)}”.
            </p>
          </div>

          <.form
            for={to_form(%{}, as: :diff_upload)}
            id="diff-upload-form"
            class="mt-6 space-y-4"
            phx-change="validate_diff"
            phx-submit="compute_diff"
          >
            <label class="flex flex-col items-center justify-center w-full h-40 border-2 border-dashed border-base-300 rounded-lg cursor-pointer bg-base-200 hover:bg-base-300 transition-colors">
              <div class="flex flex-col items-center justify-center pt-5 pb-6 px-6">
                <.icon name="hero-arrow-up-tray" class="w-10 h-10 mb-3 text-base-content/60" />
                <p class="mb-2 text-sm font-medium">
                  <span class="text-primary">Click to upload</span> or drag and drop
                </p>
                <p class="text-xs text-base-content/60">
                  levels.txt, stops.txt, pathways.txt or a .zip archive (max 3 files, 50MB each)
                </p>
              </div>
              <.live_file_input upload={@uploads.diff_files} class="sr-only" />
            </label>

            <%= for error <- upload_errors(@uploads.diff_files) do %>
              <div class="alert alert-error alert-soft">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>{diff_upload_error_to_string(error)}</span>
              </div>
            <% end %>

            <%= for entry <- @uploads.diff_files.entries do %>
              <div class={[
                "flex items-center justify-between mt-2 p-2 rounded",
                upload_errors(@uploads.diff_files, entry) == [] && "bg-base-200",
                upload_errors(@uploads.diff_files, entry) != [] && "bg-error/10 border border-error"
              ]}>
                <div class="flex-1">
                  <span class="text-sm font-medium">{entry.client_name}</span>
                  <%= if upload_errors(@uploads.diff_files, entry) == [] do %>
                    <div class="w-full bg-base-300 rounded-full h-2 mt-1">
                      <div
                        class="bg-primary h-2 rounded-full transition-all duration-300"
                        style={"width: #{entry.progress}%"}
                      >
                      </div>
                    </div>
                    <span class="text-xs text-base-content/60">
                      {entry.progress}% uploaded
                    </span>
                  <% else %>
                    <%= for error <- upload_errors(@uploads.diff_files, entry) do %>
                      <div class="flex items-center gap-2 mt-1">
                        <.icon name="hero-exclamation-circle" class="w-4 h-4 text-error" />
                        <span class="text-sm text-error">{diff_upload_error_to_string(error)}</span>
                      </div>
                    <% end %>
                  <% end %>
                </div>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs ml-2"
                  phx-click="cancel-diff-upload"
                  phx-value-ref={entry.ref}
                >
                  Cancel
                </button>
              </div>
            <% end %>

            <div class="flex flex-wrap gap-2">
              <button
                type="submit"
                id="diff-compute-btn"
                class="btn btn-primary"
                disabled={@uploads.diff_files.entries == [] || @diff_step != :upload}
              >
                Compute Diff
              </button>

              <%= if @diff_step == :review do %>
                <button
                  type="button"
                  id="diff-reset-btn"
                  class="btn btn-outline"
                  phx-click="reset-diff"
                >
                  Reset
                </button>
              <% end %>
            </div>
          </.form>

          <%= if @diff_step == :review do %>
            <div class="mt-8 border-t border-base-300 pt-6 space-y-4">
              <%!-- Filter tabs + bulk actions --%>
              <div class="flex items-end justify-between border-b border-base-300">
                <div class="flex gap-6" role="tablist" aria-label="Filter decisions">
                  <%= for {filter, label, count} <- [
                    {:all, "All", decision_total(@diff_summary)},
                    {:add, "Add", @diff_summary.add},
                    {:modify, "Modify", @diff_summary.modify},
                    {:conflict, "Conflict", @diff_summary.conflict},
                    {:remove, "Remove", @diff_summary.remove}
                  ] do %>
                    <button
                      type="button"
                      id={"diff-filter-#{filter}"}
                      role="tab"
                      aria-selected={to_string(@diff_filter == filter)}
                      class={[
                        "pb-3 text-sm font-medium transition-colors border-b-2 -mb-px",
                        @diff_filter == filter &&
                          "border-primary text-base-content",
                        @diff_filter != filter &&
                          "border-transparent text-base-content/60 hover:text-base-content hover:border-base-300"
                      ]}
                      phx-click="diff-filter"
                      phx-value-filter={filter}
                    >
                      {label}
                      <span class="ml-1.5 text-xs text-base-content/40">{count}</span>
                    </button>
                  <% end %>
                </div>

                <div class="flex gap-1 pb-3">
                  <%= if @diff_filter != :all do %>
                    <button
                      type="button"
                      class="btn btn-xs btn-outline"
                      phx-click="approve-all"
                      phx-value-action={@diff_filter}
                    >
                      Approve all {@diff_filter}
                    </button>
                  <% else %>
                    <%= for {action, count} <- non_zero_action_counts(@diff_summary) do %>
                      <button
                        type="button"
                        class="btn btn-xs btn-ghost"
                        phx-click="approve-all"
                        phx-value-action={action}
                      >
                        Approve {count} {action}
                      </button>
                    <% end %>
                  <% end %>
                </div>
              </div>

              <%= if @diff_parse_errors != [] do %>
                <.callout kind="warning" title="Parse Errors">
                  <div class="space-y-1 text-xs">
                    <p :for={error <- @diff_parse_errors}>{format_diff_parse_error(error)}</p>
                  </div>
                </.callout>
              <% end %>

              <%!-- Decision table --%>
              <div class="overflow-x-auto">
                <table class="table table-xs w-full">
                  <thead>
                    <tr class="text-xs uppercase tracking-wide text-base-content/60">
                      <th>Type</th>
                      <th>ID</th>
                      <th>Action</th>
                      <th>Details</th>
                      <th class="w-24 text-right">Decision</th>
                    </tr>
                  </thead>
                  <tbody
                    id="diff-decisions"
                    phx-update="stream"
                  >
                    <tr
                      id="diff-decisions-empty"
                      class="hidden only:table-row"
                    >
                      <td colspan="5" class="text-sm text-base-content/70 py-6 text-center">
                        No matching decisions for this filter.
                      </td>
                    </tr>
                    <tr
                      :for={{dom_id, decision} <- @streams.diff_decisions}
                      id={dom_id}
                      class={[
                        "hover:bg-base-200/50",
                        decision.status == :approved && "bg-success/5",
                        decision.status == :rejected && "bg-error/5 opacity-60",
                        decision.first_of_group && "border-t-2 border-base-300"
                      ]}
                    >
                      <td class="text-xs font-medium">{decision.entity_type}</td>
                      <td class="font-mono text-xs">{decision.natural_key}</td>
                      <td>
                        <span class="inline-flex items-center gap-1.5">
                          <span class={[
                            "inline-block w-2 h-2 rounded-full shrink-0",
                            action_dot_color(decision.action)
                          ]}>
                          </span>
                          <span class="text-xs font-medium">{decision.action}</span>
                        </span>
                        <span
                          :if={decision.user_edited}
                          class="text-xs text-base-content/50"
                        >
                          (edited)
                        </span>
                      </td>
                      <td class="text-xs max-w-md">
                        <div class="truncate" title={format_decision_details(decision)}>
                          {format_decision_details(decision)}
                        </div>
                        <%!-- Inline expandable detail --%>
                        <div
                          id={"#{dom_id}-details"}
                          class="hidden mt-2 pt-2 border-t border-base-300/50"
                        >
                          <div class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-xs">
                            <%= for {field, value} <- detail_fields(decision) do %>
                              <span class="text-base-content/60 font-medium">{to_string(field)}</span>
                              <span class="font-mono">{format_value(value)}</span>
                            <% end %>
                          </div>
                          <p
                            :if={decision.dependency_keys != []}
                            class="mt-2 text-xs text-base-content/50"
                          >
                            Depends on: {Enum.join(decision.dependency_keys, ", ")}
                          </p>
                        </div>
                      </td>
                      <td class="text-right align-top">
                        <div class="flex justify-end gap-1">
                          <button
                            type="button"
                            class="btn btn-ghost btn-xs btn-square"
                            phx-click={JS.toggle(to: "[id=\"#{dom_id}-details\"]")}
                            aria-label="Toggle details"
                          >
                            <.icon name="hero-chevron-down" class="size-3" />
                          </button>
                          <button
                            type="button"
                            class={[
                              "btn btn-xs btn-square",
                              decision.status == :approved && "btn-success",
                              decision.status != :approved && "btn-ghost"
                            ]}
                            phx-click="approve-decision"
                            phx-value-id={decision.id}
                            aria-label="Approve"
                          >
                            <.icon name="hero-check" class="size-3.5" />
                          </button>
                          <button
                            type="button"
                            class={[
                              "btn btn-xs btn-square",
                              decision.status == :rejected && "btn-error",
                              decision.status != :rejected && "btn-ghost"
                            ]}
                            phx-click="reject-decision"
                            phx-value-id={decision.id}
                            aria-label="Reject"
                          >
                            <.icon name="hero-x-mark" class="size-3.5" />
                          </button>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <button
                type="button"
                id="diff-apply-btn"
                class="btn btn-primary"
                phx-click="apply-decisions"
                disabled={approved_decision_count(@decisions_by_id) == 0}
              >
                Apply Approved ({approved_decision_count(@decisions_by_id)})
              </button>
            </div>
          <% end %>

          <%= if @diff_step == :done do %>
            <div class="mt-8 border-t border-base-300 pt-6 space-y-4">
              <div class="rounded-lg border border-base-300 p-4 bg-base-200">
                <p class="text-sm font-semibold">
                  Applied {successful_apply_count(@apply_results)} decisions successfully, {failed_apply_count(
                    @apply_results
                  )} failed.
                </p>
              </div>

              <%= if failed_apply_results(@apply_results) != [] do %>
                <div class="space-y-2">
                  <div
                    :for={{decision_id, {:error, reason}} <- failed_apply_results(@apply_results)}
                    class="rounded-lg border border-error/40 bg-error/10 p-3 text-sm"
                  >
                    <p class="font-mono text-xs">{decision_id}</p>
                    <p>{format_apply_reason(reason)}</p>
                  </div>
                </div>
              <% end %>

              <button
                type="button"
                id="diff-reset-btn"
                class="btn btn-outline"
                phx-click="reset-diff"
              >
                Reset
              </button>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Create exactly one staging target, bind it as `:import_target`, consume the
  # uploads into memory, and hand the persisted target to `Publication.run/3`.
  # The route/current version is never a write destination.
  defp create_and_start_import(socket, _form_data, version_name) do
    organization_id = socket.assigns.current_organization.id

    case Versions.create_staging_gtfs_version(organization_id, %{name: version_name}) do
      {:error, changeset} ->
        # Pre-consumption changeset error (blank/duplicate name): return to the
        # form, preserve every selected upload entry, focus/announce the error,
        # and start no task. No lifecycle row was created.
        {:noreply,
         socket
         |> assign(:version_name_touched, true)
         |> assign(
           :form,
           to_form(%{"version_name" => version_name},
             as: :gtfs_import_form,
             errors: changeset_errors(changeset)
           )
         )
         |> assign(:import_result, nil)}

      {:ok, target} ->
        # Bind the persisted target before touching uploads so every downstream
        # path (consume error, task, result, :DOWN) closes this exact version.
        socket = assign(socket, :import_target, target)

        case consume_import_files(socket) do
          {:ok, uploaded_files} ->
            start_import_task(socket, target, uploaded_files)

          {:error, reason} ->
            # Post-create consumption/read error: fail the exact staging target,
            # start no task, and render target-specific feedback.
            failed = fail_target_best_effort(target)

            {:noreply,
             socket
             |> assign(:import_target, failed)
             |> assign(:import_result, {:error, failed, {:upload_consumption_failed, reason}})
             |> assign(:importing, false)
             |> assign(:import_task, nil)
             |> assign(:import_progress, nil)}
        end
    end
  end

  defp start_import_task(socket, %GtfsVersion{} = target, uploaded_files) do
    # Subscribe to the progress topic BEFORE starting the task so no progress
    # message is missed.
    topic = "import:#{:erlang.unique_integer()}"
    Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

    task =
      Task.Supervisor.async_nolink(GtfsPlanner.TaskSupervisor, fn ->
        Publication.run(target, uploaded_files, topic)
      end)

    {:noreply,
     socket
     |> assign(:import_task, task.ref)
     |> assign(:importing, true)
     |> assign(:import_result, nil)
     |> assign(:published_version, nil)
     |> assign(:import_progress, nil)}
  end

  # Consume upload entries by reading each temporary path through the configured
  # production file adapter (`File` by default). Reads use `read/1`, never
  # `read!/1`, so a read failure is a value we can act on rather than a raise.
  defp consume_import_files(socket) do
    reader = import_file_reader()

    results =
      consume_uploaded_entries(socket, :gtfs_files, fn %{path: path}, entry ->
        case reader.read(path) do
          {:ok, content} -> {:ok, {:ok, %{filename: entry.client_name, content: content}}}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      {:error, reason} -> {:error, reason}
      nil -> {:ok, for({:ok, file} <- results, do: file)}
    end
  end

  defp import_file_reader do
    Application.get_env(:gtfs_planner, :import_file_reader, File)
  end

  # Best-effort conditional closure of a still-unpublished target. A published
  # or failed target is left untouched (the transition is a no-op there).
  defp fail_target_best_effort(%GtfsVersion{} = target) do
    case Versions.fail_unpublished_gtfs_version(target.organization_id, target.id) do
      {:ok, failed} -> failed
      {:error, _reason} -> target
    end
  end

  defp fail_target_best_effort(_), do: nil

  defp apply_import_result(socket, {:ok, %GtfsVersion{} = published, %Result{} = result}) do
    socket
    |> assign(:import_result, {:ok, published, result})
    |> assign(:import_target, published)
    |> assign(:published_version, published)
    |> assign(:importing, false)
    |> assign(:import_task, nil)
  end

  defp apply_import_result(socket, {:error, target, {:publication_failed, reason}}) do
    socket
    |> assign(:import_result, {:error, target, {:publication_failed, reason}})
    |> assign(:import_target, target)
    |> assign(:importing, false)
    |> assign(:import_task, nil)
  end

  defp apply_import_result(socket, {:error, target, reason}) do
    socket
    |> assign(:import_result, {:error, target, reason})
    |> assign(:import_target, target)
    |> assign(:importing, false)
    |> assign(:import_task, nil)
  end

  # The version name is edited under the form field `:version_name`, while the
  # schema validates the `:name` column. Remap so the inline error renders
  # against the field the user actually sees.
  defp changeset_errors(%Ecto.Changeset{} = changeset) do
    for {field, {message, _opts}} <- changeset.errors do
      case field do
        :name -> {:version_name, message}
        other -> {other, message}
      end
    end
  end

  defp target_name(%GtfsVersion{name: name}), do: name
  defp target_name(_), do: "the requested version"

  defp destination_name(form) do
    case form[:version_name].value do
      value when is_binary(value) and value != "" -> value
      _ -> "unnamed"
    end
  end

  defp version_display_name(%GtfsVersion{name: name}), do: name
  defp version_display_name(%{name: name}) when is_binary(name), do: name
  defp version_display_name(_), do: "current"

  defp format_import_error({:upload_consumption_failed, reason}),
    do: "The uploaded files could not be read (#{inspect(reason)})."

  defp format_import_error({:import_not_publishable, _result}),
    do: "The import completed with errors and was not published."

  defp format_import_error(:invalid_status_transition),
    do: "The version could not be claimed for import."

  defp format_import_error(:not_found), do: "The target version could not be found."
  defp format_import_error(:process_crashed), do: "The import process failed unexpectedly."
  defp format_import_error(:no_files_selected), do: "Select at least one file to import."
  defp format_import_error(reason) when is_binary(reason), do: reason
  defp format_import_error(reason), do: inspect(reason)

  defp empty_diff_summary do
    %{add: 0, modify: 0, remove: 0, conflict: 0}
  end

  defp categorize_diff_files(files) do
    grouped =
      Enum.reduce(files, %{levels: [], stops: [], pathways: []}, fn file, acc ->
        basename =
          file.filename
          |> Path.basename()
          |> String.downcase()

        normalized_file = %{file | filename: basename}

        case basename do
          "levels.txt" -> Map.update!(acc, :levels, &[normalized_file | &1])
          "stops.txt" -> Map.update!(acc, :stops, &[normalized_file | &1])
          "pathways.txt" -> Map.update!(acc, :pathways, &[normalized_file | &1])
          _ -> acc
        end
      end)

    duplicate_errors =
      grouped
      |> Enum.flat_map(fn
        {_type, []} ->
          []

        {_type, [_single]} ->
          []

        {_type, files_for_type} ->
          basenames = files_for_type |> Enum.map(& &1.filename) |> Enum.uniq() |> Enum.join(", ")

          [
            %{
              file: nil,
              row: nil,
              reason: "Duplicate entity upload detected (#{basenames})"
            }
          ]
      end)

    if duplicate_errors == [] do
      {:ok,
       %{
         levels: single_optional_file(grouped.levels),
         stops: single_optional_file(grouped.stops),
         pathways: single_optional_file(grouped.pathways)
       }}
    else
      {:error, duplicate_errors}
    end
  end

  defp single_optional_file([]), do: nil
  defp single_optional_file([file]), do: file

  defp parse_uploaded_entity_file(nil, _filename, _parser_fun), do: {:not_uploaded, []}

  defp parse_uploaded_entity_file(file, filename, parser_fun) do
    {attrs, parse_errors} =
      file.content
      |> Import.parse_csv_content()
      |> Enum.with_index(2)
      |> Enum.reduce({[], []}, fn {row_map, row_number}, {attrs_acc, errors_acc} ->
        case parser_fun.(row_map) do
          {:ok, attrs} ->
            {[attrs | attrs_acc], errors_acc}

          {:error, reason} ->
            error = %{file: filename, row: row_number, reason: to_string(reason)}
            {attrs_acc, [error | errors_acc]}
        end
      end)

    {Enum.reverse(attrs), Enum.reverse(parse_errors)}
  end

  defp build_stop_validation_map(db_stops, uploaded_stops) do
    db_ids = Enum.map(db_stops, & &1.stop_id)

    uploaded_ids =
      if uploaded_stops == :not_uploaded do
        []
      else
        Enum.map(uploaded_stops, &Map.get(&1, :stop_id))
      end

    (db_ids ++ uploaded_ids)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Map.new(fn stop_id -> {stop_id, true} end)
  end

  defp stream_filtered_diff_decisions(socket) do
    decisions =
      socket.assigns.decisions_by_id
      |> Map.values()
      |> Enum.filter(fn decision ->
        socket.assigns.diff_filter == :all or decision.action == socket.assigns.diff_filter
      end)
      |> Enum.sort_by(&display_decision_sort_key/1)
      |> mark_group_boundaries()

    stream(socket, :diff_decisions, decisions, reset: true)
  end

  defp mark_group_boundaries([]), do: []

  defp mark_group_boundaries([%DiffDecision{} = first | rest]) do
    {annotated, _} =
      Enum.map_reduce(rest, first.entity_type, fn %DiffDecision{} = decision, prev_type ->
        {%DiffDecision{decision | first_of_group: decision.entity_type != prev_type},
         decision.entity_type}
      end)

    [%DiffDecision{first | first_of_group: true} | annotated]
  end

  defp display_decision_sort_key(decision) do
    {entity_sort_rank(decision.entity_type), decision.natural_key,
     action_sort_rank(decision.action)}
  end

  defp update_decision_status(socket, id, status) do
    case Map.fetch(socket.assigns.decisions_by_id, id) do
      {:ok, %DiffDecision{} = decision} ->
        updated_decision = %DiffDecision{decision | status: status}

        socket
        |> assign(:decisions_by_id, Map.put(socket.assigns.decisions_by_id, id, updated_decision))
        |> stream_filtered_diff_decisions()

      :error ->
        socket
    end
  end

  defp order_apply_decisions(decisions) do
    Enum.sort_by(decisions, fn decision ->
      {decision_phase_rank(decision.action),
       decision_entity_rank(decision.action, decision.entity_type)}
    end)
  end

  defp decision_phase_rank(:add), do: 0
  defp decision_phase_rank(:modify), do: 1
  defp decision_phase_rank(:conflict), do: 1
  defp decision_phase_rank(:remove), do: 2

  defp decision_entity_rank(action, entity_type) when action in [:add, :modify, :conflict] do
    case entity_type do
      :level -> 0
      :stop -> 1
      :pathway -> 2
    end
  end

  defp decision_entity_rank(:remove, entity_type) do
    case entity_type do
      :pathway -> 0
      :stop -> 1
      :level -> 2
    end
  end

  defp apply_decision(%DiffDecision{action: :add, entity_type: :level, uploaded_attrs: attrs})
       when is_map(attrs) do
    attrs
    |> Gtfs.create_level()
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{action: :add, entity_type: :stop, uploaded_attrs: attrs})
       when is_map(attrs) do
    attrs
    |> Gtfs.import_create_stop()
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{action: :add, entity_type: :pathway, uploaded_attrs: attrs})
       when is_map(attrs) do
    attrs
    |> Gtfs.create_pathway()
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{
         action: action,
         entity_type: :level,
         current_record: current_record,
         uploaded_attrs: uploaded_attrs
       })
       when action in [:modify, :conflict] and is_map(uploaded_attrs) and
              not is_nil(current_record) do
    managed_attrs = Map.take(uploaded_attrs, [:level_index, :level_name])

    current_record
    |> Gtfs.update_level(managed_attrs)
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{
         action: action,
         entity_type: :stop,
         current_record: current_record,
         uploaded_attrs: uploaded_attrs
       })
       when action in [:modify, :conflict] and is_map(uploaded_attrs) and
              not is_nil(current_record) do
    managed_attrs =
      Map.take(uploaded_attrs, [
        :stop_name,
        :stop_desc,
        :stop_lat,
        :stop_lon,
        :location_type,
        :wheelchair_boarding,
        :platform_code,
        :level_id,
        :parent_station
      ])

    current_record
    |> Gtfs.import_update_stop(managed_attrs)
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{
         action: action,
         entity_type: :pathway,
         current_record: current_record,
         uploaded_attrs: uploaded_attrs
       })
       when action in [:modify, :conflict] and is_map(uploaded_attrs) and
              not is_nil(current_record) do
    managed_attrs =
      Map.take(uploaded_attrs, [
        :pathway_mode,
        :is_bidirectional,
        :traversal_time,
        :length,
        :stair_count,
        :max_slope,
        :min_width,
        :signposted_as,
        :reversed_signposted_as,
        :from_stop_id,
        :to_stop_id
      ])

    current_record
    |> Gtfs.update_pathway(managed_attrs)
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{
         action: :remove,
         entity_type: :level,
         current_record: current_record
       })
       when not is_nil(current_record) do
    current_record
    |> Gtfs.delete_level()
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{
         action: :remove,
         entity_type: :stop,
         current_record: current_record
       })
       when not is_nil(current_record) do
    current_record
    |> Gtfs.delete_stop()
    |> normalize_apply_result()
  end

  defp apply_decision(%DiffDecision{
         action: :remove,
         entity_type: :pathway,
         current_record: current_record
       })
       when not is_nil(current_record) do
    current_record
    |> Gtfs.delete_pathway()
    |> normalize_apply_result()
  end

  defp apply_decision(_), do: {:error, :invalid_decision}

  defp normalize_apply_result({:ok, _record}), do: :ok
  defp normalize_apply_result({:error, reason}), do: {:error, reason}

  defp approved_decision_count(decisions_by_id) do
    decisions_by_id
    |> Map.values()
    |> Enum.count(fn decision -> decision.status == :approved end)
  end

  defp successful_apply_count(apply_results) do
    Enum.count(apply_results, fn {_decision_id, result} -> result == :ok end)
  end

  defp failed_apply_count(apply_results) do
    Enum.count(apply_results, fn {_decision_id, result} -> match?({:error, _}, result) end)
  end

  defp failed_apply_results(apply_results) do
    Enum.filter(apply_results, fn {_decision_id, result} -> match?({:error, _}, result) end)
  end

  defp entity_sort_rank(:level), do: 0
  defp entity_sort_rank(:stop), do: 1
  defp entity_sort_rank(:pathway), do: 2

  defp action_sort_rank(:add), do: 0
  defp action_sort_rank(:modify), do: 1
  defp action_sort_rank(:conflict), do: 2
  defp action_sort_rank(:remove), do: 3

  defp format_value(nil), do: "nil"
  defp format_value(value) when is_binary(value) and value == "", do: "\"\""
  defp format_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  defp action_dot_color(:add), do: "bg-emerald-600"
  defp action_dot_color(:modify), do: "bg-amber-500"
  defp action_dot_color(:conflict), do: "bg-red-600"
  defp action_dot_color(:remove), do: "bg-base-content/40"

  defp managed_fields_for(:level), do: [:level_name, :level_index]

  defp managed_fields_for(:stop),
    do: [
      :stop_name,
      :stop_desc,
      :stop_lat,
      :stop_lon,
      :location_type,
      :platform_code,
      :level_id,
      :parent_station,
      :wheelchair_boarding
    ]

  defp managed_fields_for(:pathway),
    do: [
      :from_stop_id,
      :to_stop_id,
      :pathway_mode,
      :is_bidirectional,
      :traversal_time,
      :length,
      :stair_count,
      :max_slope,
      :min_width,
      :signposted_as,
      :reversed_signposted_as
    ]

  defp format_decision_details(%DiffDecision{action: :add} = d) do
    managed_fields_for(d.entity_type)
    |> Enum.map(fn field -> {field, Map.get(d.uploaded_attrs || %{}, field)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.map(fn {k, v} -> "#{k}: #{format_value(v)}" end)
    |> Enum.join(", ")
  end

  defp format_decision_details(%DiffDecision{action: :remove} = d) do
    record = d.current_record

    managed_fields_for(d.entity_type)
    |> Enum.map(fn field -> {field, record && Map.get(record, field)} end)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.map(fn {k, v} -> "#{k}: #{format_value(v)}" end)
    |> Enum.join(", ")
  end

  defp format_decision_details(%DiffDecision{changed_fields: fields}) do
    fields
    |> Enum.map(fn {field, {old, new}} ->
      "#{field}: #{format_value(old)} \u2192 #{format_value(new)}"
    end)
    |> Enum.join(", ")
  end

  defp detail_fields(%DiffDecision{action: :add} = d) do
    managed_fields_for(d.entity_type)
    |> Enum.map(fn field -> {field, Map.get(d.uploaded_attrs || %{}, field)} end)
  end

  defp detail_fields(%DiffDecision{action: :remove} = d) do
    record = d.current_record

    managed_fields_for(d.entity_type)
    |> Enum.map(fn field -> {field, record && Map.get(record, field)} end)
  end

  defp detail_fields(%DiffDecision{} = d) do
    d.changed_fields
  end

  defp non_zero_action_counts(summary) do
    [:add, :modify, :conflict, :remove]
    |> Enum.map(fn action -> {action, Map.get(summary, action, 0)} end)
    |> Enum.reject(fn {_action, count} -> count == 0 end)
  end

  defp decision_total(summary) do
    (summary.add || 0) + (summary.modify || 0) + (summary.conflict || 0) + (summary.remove || 0)
  end

  defp format_diff_parse_error(%{file: nil, row: nil, reason: reason}), do: reason

  defp format_diff_parse_error(%{file: file, row: row, reason: reason})
       when is_binary(file) and is_integer(row),
       do: "#{file} row #{row}: #{reason}"

  defp format_diff_parse_error(%{file: file, reason: reason}) when is_binary(file),
    do: "#{file}: #{reason}"

  defp format_diff_parse_error(%{reason: reason}), do: reason
  defp format_diff_parse_error(other), do: inspect(other)

  defp format_apply_reason(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    inspect(errors)
  end

  defp format_apply_reason(reason) when is_binary(reason), do: reason
  defp format_apply_reason(reason), do: inspect(reason)

  defp upload_error_to_string(:too_large), do: "File exceeds 200MB limit"
  defp upload_error_to_string(:too_many_files), do: "Maximum 50 files allowed"
  defp upload_error_to_string(:not_accepted), do: "Only .txt, .csv, and .zip files accepted"
  defp upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp upload_error_to_string({:error, reason}), do: reason
  defp upload_error_to_string(error) when is_binary(error), do: error
  defp upload_error_to_string(_), do: "Upload error"

  defp diff_upload_error_to_string(:too_large), do: "File exceeds 50MB limit"
  defp diff_upload_error_to_string(:too_many_files), do: "Maximum 3 files allowed"
  defp diff_upload_error_to_string(:not_accepted), do: "Only .txt, .csv, and .zip files accepted"
  defp diff_upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp diff_upload_error_to_string({:error, reason}), do: reason
  defp diff_upload_error_to_string(error) when is_binary(error), do: error
  defp diff_upload_error_to_string(_), do: "Upload error"
end

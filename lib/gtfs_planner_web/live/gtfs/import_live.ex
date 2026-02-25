defmodule GtfsPlannerWeb.Gtfs.ImportLive do
  @moduledoc """
  LiveView for importing GTFS data.
  Requires the pathways_studio_editor role (editor only, not viewer).
  """
  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.{Diff, DiffDecision, RowParser}
  alias GtfsPlanner.Versions

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
       to_form(%{"create_version" => false, "version_name" => ""}, as: :gtfs_import_form)
     )
     |> assign(:import_result, nil)
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
         valid_version_for_org?(version_id, current_organization.id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/import")}
    else
      {:noreply, socket}
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

    # Check for unrecognized files in uploads (.zip archives are always recognized)
    unrecognized_files =
      socket.assigns.uploads.gtfs_files.entries
      |> Enum.map(& &1.client_name)
      |> Enum.reject(fn name ->
        lower = String.downcase(name)
        MapSet.member?(@recognized_gtfs_files, lower) or String.ends_with?(lower, ".zip")
      end)

    # Reset version_name_touched when not creating a new version, so that
    # re-enabling "Create a new GTFS version" doesn't immediately show errors.
    socket =
      socket
      |> assign(:form, form)
      |> assign(
        :version_name_touched,
        if(create_version, do: socket.assigns.version_name_touched, else: false)
      )
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
    # Extract form data (nested under gtfs_import_form)
    form_data = params["gtfs_import_form"] || %{}
    create_version = form_data["create_version"] == "true"
    version_name = form_data["version_name"] || ""

    # Validate required fields
    if create_version && String.trim(version_name) == "" do
      {:noreply,
       socket
       |> assign(:version_name_touched, true)
       |> assign(
         :form,
         to_form(form_data,
           as: :gtfs_import_form,
           errors: [version_name: "Version name is required"]
         )
       )}
    else
      # Determine GTFS version ID
      gtfs_version_id =
        if create_version && version_name != "" do
          case Versions.create_gtfs_version(socket.assigns.current_organization.id, %{
                 name: version_name
               }) do
            {:ok, version} ->
              version.id

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

      # Generate unique topic for progress updates and subscribe immediately
      # This must happen BEFORE starting the async task to ensure we receive all progress messages
      topic = "import:#{:erlang.unique_integer()}"
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, topic)

      # Run import in async task to avoid blocking LiveView process
      task =
        Task.async(fn ->
          GtfsPlanner.Gtfs.Import.import_files(
            socket.assigns.current_organization.id,
            gtfs_version_id,
            uploaded_files,
            topic
          )
        end)

      {:noreply,
       socket
       |> assign(:import_task, task.ref)
       |> assign(:importing, true)
       |> assign(:import_result, nil)
       |> assign(:import_progress, nil)}
    end
  end

  @impl true
  def handle_event("compute_diff", _params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :diff_files, fn %{path: path}, entry ->
        {:ok, %{filename: entry.client_name, content: File.read!(path)}}
      end)

    expanded_files = Import.expand_archives(uploaded_files)

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
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    socket =
      case result do
        {:ok, {counts, unrecognized, _topic}} ->
          # Note: We already subscribed to the topic before starting the task
          # so we don't need to subscribe again here

          socket
          |> assign(:import_result, {:ok, counts, unrecognized})
          |> assign(:importing, false)
          |> assign(:import_task, nil)

        {:error, error_msg} when is_binary(error_msg) ->
          socket
          |> assign(:import_result, {:error, error_msg})
          |> assign(:importing, false)
          |> assign(:import_task, nil)

        {:error, %{} = error_map} ->
          # Handle map-format errors from BatchProcessor
          error_msg = format_error_map(error_map)

          socket
          |> assign(:import_result, {:error, error_msg})
          |> assign(:importing, false)
          |> assign(:import_task, nil)
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
                    {Enum.join(@form[:version_name].errors, ", ")}
                  </p>
                <% else %>
                  <p class="text-base-content/50 text-xs mt-1">
                    Give this version a descriptive name
                  </p>
                <% end %>
              </div>
            <% end %>

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
                class="btn btn-primary"
                disabled={@uploads.gtfs_files.entries == [] || @importing}
              >
                <%= if @importing do %>
                  <span class="loading loading-spinner loading-sm"></span> Importing...
                <% else %>
                  Import Files
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

          <%= if @import_result do %>
            <div class="mt-6 pt-6 border-t border-base-300">
              <%= case @import_result do %>
                <% {:ok, counts, unrecognized} -> %>
                  <div class="alert border border-green-300 bg-green-100 text-black">
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
                        d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                      />
                    </svg>
                    <div>
                      <h3 class="font-bold">Import Successful</h3>
                      <div class="text-xs">
                        Imported {counts.agencies} agencies, {counts.areas} areas, {counts.attributions} attributions, {counts.booking_rules} booking rules, {counts.calendars} calendars, {counts.calendar_dates} calendar dates, {counts.fare_attributes} fare attributes, {counts.fare_leg_join_rules} fare leg join rules, {counts.fare_leg_rules} fare leg rules, {counts.fare_media} fare media, {counts.fare_products} fare products, {counts.fare_rules} fare rules, {counts.fare_transfer_rules} fare transfer rules, {counts.feed_info} feed info, {counts.frequencies} frequencies, {counts.levels} levels, {counts.locations} locations, {counts.networks} networks, {counts.pathways} pathways, {counts.rider_categories} rider categories, {counts.route_networks} route networks, {counts.route_patterns} route patterns, {counts.routes} routes, {counts.shapes} shapes, {counts.stop_areas} stop areas, {counts.stop_times} stop times, {counts.stops} stops, {counts.timeframes} timeframes, {counts.transfers} transfers, {counts.translations} translations, {counts.trips} trips.
                      </div>
                      <%= if Map.get(counts, :extensions_stop_coordinates, 0) + Map.get(counts, :extensions_stop_levels, 0) + Map.get(counts, :extensions_route_flags, 0) + Map.get(counts, :extensions_images, 0) > 0 do %>
                        <div class="text-xs mt-1">
                          Extensions: {Map.get(counts, :extensions_stop_coordinates, 0)} diagram coordinates, {Map.get(
                            counts,
                            :extensions_stop_levels,
                            0
                          )} stop levels, {Map.get(counts, :extensions_route_flags, 0)} route flags, {Map.get(
                            counts,
                            :extensions_images,
                            0
                          )} images.
                        </div>
                      <% end %>
                    </div>
                  </div>
                  <%= if unrecognized != [] do %>
                    <div class="alert alert-warning mt-2">
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
                      <div>
                        <h3 class="font-bold">Unrecognized Files Skipped</h3>
                        <div class="text-xs">
                          {Enum.join(unrecognized, ", ")}
                        </div>
                      </div>
                    </div>
                  <% end %>
                <% {:error, error_msg} -> %>
                  <div class="alert alert-error alert-soft">
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
                    <div>
                      <h3 class="font-bold">Import Failed</h3>
                      <div class="text-xs">
                        {error_msg}
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
          </div>

          <.form
            for={to_form(%{}, as: :diff_upload)}
            id="diff-upload-form"
            class="mt-6 space-y-4"
            phx-change="validate_diff"
            phx-submit="compute_diff"
          >
            <label class="flex flex-col items-center justify-center w-full h-32 border-2 border-dashed border-base-300 rounded-lg cursor-pointer bg-base-200 hover:bg-base-300 transition-colors">
              <div class="flex flex-col items-center justify-center px-6">
                <.icon name="hero-arrow-up-tray" class="w-8 h-8 mb-2 text-base-content/60" />
                <p class="text-sm font-medium">Upload station files or a zip archive</p>
                <p class="text-xs text-base-content/60 mt-1">Max 3 files, 50MB each</p>
              </div>
              <.live_file_input upload={@uploads.diff_files} class="sr-only" />
            </label>

            <%= for error <- upload_errors(@uploads.diff_files) do %>
              <div class="alert alert-error alert-soft">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>{diff_upload_error_to_string(error)}</span>
              </div>
            <% end %>

            <div
              :for={entry <- @uploads.diff_files.entries}
              class="flex items-center justify-between rounded-lg bg-base-200 p-3"
            >
              <div>
                <p class="text-sm font-medium">{entry.client_name}</p>
                <p class="text-xs text-base-content/60">{entry.progress}% uploaded</p>
                <%= for error <- upload_errors(@uploads.diff_files, entry) do %>
                  <p class="text-xs text-error mt-1">{diff_upload_error_to_string(error)}</p>
                <% end %>
              </div>

              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="cancel-diff-upload"
                phx-value-ref={entry.ref}
              >
                Cancel
              </button>
            </div>

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
                <div class="rounded-lg border border-warning/30 bg-warning/10 p-4">
                  <h3 class="font-semibold text-sm mb-2">Parse Errors</h3>
                  <div class="space-y-1 text-xs">
                    <p :for={error <- @diff_parse_errors}>{format_diff_parse_error(error)}</p>
                  </div>
                </div>
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
    |> Gtfs.create_stop()
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
    |> Gtfs.update_stop(managed_attrs)
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
      :stop_lat,
      :stop_lon,
      :location_type,
      :platform_code,
      :level_id,
      :parent_station
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

  # Format error maps from BatchProcessor into user-friendly strings
  defp format_error_map(%{file: file, row: row, reason: reason}),
    do: "Error in #{file} at row #{row}: #{reason}"

  defp format_error_map(%{file: file, constraint: constraint, message: msg})
       when not is_nil(constraint),
       do: "Constraint error in #{file} (#{constraint}): #{msg}"

  defp format_error_map(%{file: file, error: error}),
    do: "Error in #{file}: #{error}"

  defp format_error_map(%{file: file, message: msg}),
    do: "Error in #{file}: #{msg}"

  defp format_error_map(%{} = map),
    do: inspect(map)
end

defmodule GtfsPlannerWeb.Gtfs.ExportLive do
  @moduledoc """
  LiveView for exporting GTFS data.
  Requires pathways_studio_editor role.
  """
  use GtfsPlannerWeb, :live_view
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Packs.FeedQuality
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Config, as: PublishingConfig
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Export.MissingTimes
  alias GtfsPlanner.Gtfs.Export.Runner, as: ExportRunner
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Evidence
  alias GtfsPlannerWeb.AgentPanel
  alias GtfsPlannerWeb.GtfsVersionNavigation
  alias GtfsPlannerWeb.ProductSurfaces
  alias Phoenix.LiveView.AsyncResult

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]
  import GtfsPlannerWeb.Gtfs.FeedPublicationComponents, only: [publication_section: 1]

  import GtfsPlannerWeb.PlannerComponents, only: [toast: 1]

  import GtfsPlannerWeb.Gtfs.ExportComponents,
    only: [
      check_panel: 1,
      file_row: 1,
      files_card: 1,
      new_file: 1,
      recent_checks: 1
    ]

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The URL is the single source of truth for the selected export type: only
  # these query values are accepted, and `export_type_from_param/1` maps them
  # onto the atoms `ExportRuns` accepts.
  @export_type_params ~w(full pathways operations operations_only)

  # Both operations-bearing kinds read the same organization TODS data, so one
  # operations preview serves either selection.
  @operations_kinds [:operations, :operations_only]

  @export_busy_message "Another export is running. Try again when it finishes."
  @validation_busy_message "Another validation is running. Try again when it finishes."
  @validation_permission_message "You no longer have permission to check this feed. " <>
                                   "Ask an organization administrator to restore your access."

  @empty_feed_quality %{
    relationship: "unknown",
    selected_artifact: nil,
    currentness: "unknown",
    publication_status: "unsupported",
    digest: nil,
    preflight: []
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    user_roles = socket.assigns[:user_roles] || []

    {:ok,
     socket
     |> assign(:page_title, "Export feed")
     |> assign(:user_roles, user_roles)
     |> assign(:export_type, :full)
     |> assign(:export_form, export_form(:full))
     |> assign(:operations?, false)
     |> assign(:include_flex, true)
     |> assign(:file_inventory, [])
     |> assign(:operations_preview, AsyncResult.loading())
     |> assign(:operations_preview_started?, false)
     |> assign(:operations_preview_refreshed_run_id, nil)
     |> assign(:closure_count, 0)
     |> assign(:export_run, nil)
     |> assign(:export_notice, nil)
     |> assign(:export_defaults, nil)
     |> assign(:missing_summary, AsyncResult.loading())
     |> assign(:validation_run_id, nil)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)
     |> assign(:recent_checks, [])
     |> assign(:publication, default_publication())
     |> assign(:feed_quality, @empty_feed_quality)
     |> assign(:files_cursor, nil)
     |> assign(:files_has_more?, false)
     |> assign(:files_empty?, true)
     |> assign(:files_started_ids, MapSet.new())
     |> assign(:files_finished_run, nil)
     |> assign(:files_notice, nil)
     |> assign(:files_toast, nil)
     |> assign(:files_subscribed_ids, MapSet.new())
     |> assign(:files_clash_run, nil)
     |> AgentPanel.mount("feed_quality")
     |> stream_configure(:files, dom_id: &"export-file-#{&1.id}")
     |> stream(:files, [])}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    organization_id = socket.assigns.current_organization.id
    ExportRuns.reconcile_expired(organization_id)
    ExportRuns.cleanup_expired(organization_id)

    organization = socket.assigns.current_organization
    export_type = resolve_export_type(params["type"], organization)

    socket =
      socket
      |> assign(:operations?, ProductSurfaces.visible?(organization, :operations_export))
      |> assign(:export_type, export_type)
      |> assign(:export_form, export_form(export_type))
      |> assign(:export_notice, nil)
      |> assign(:include_flex, ExportDefaults.get(organization_id).include_flex)
      |> assign(:export_defaults, ExportDefaults.get(organization_id))
      |> refresh_export_run()
      |> load_files()
      |> refresh_file_inventory()
      |> assign_recent_checks()
      |> load_missing_summary()
      |> reset_publication()
      |> assign_publication()

    {:noreply,
     socket
     |> refresh_feed_quality()
     |> ensure_operations_preview()}
  end

  @impl Phoenix.LiveView
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         GtfsVersionNavigation.published_for_current_organization?(socket, version_id) do
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if GtfsVersionNavigation.published_for_current_organization?(socket, version_id) do
      # Push event to JS hook to update localStorage
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      # Navigate to new version
      {:noreply, push_navigate(socket, to: "/gtfs/#{version_id}/export")}
    else
      {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("select_export_type", %{"export" => %{"type" => type}}, socket) do
    # Whitelisted before it reaches the URL, so no arbitrary value or new atom
    # can travel through the query string; `handle_params/3` owns the refresh.
    if type in @export_type_params do
      {:noreply,
       push_patch(socket,
         to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/export?type=#{type}"
       )}
    else
      {:noreply, socket}
    end
  end

  # The prepared card hands its proposed type to this page's own native form;
  # only the exact server command the conversation still holds can select it.
  @impl Phoenix.LiveView
  def handle_event("agent_review_prepared", %{"entry" => id}, socket) do
    {:noreply, review_feed_quality_options(socket, id)}
  end

  def handle_event("agent_review_prepared", _params, socket), do: {:noreply, socket}

  # Re-reads the provider-independent readiness without touching any job or form
  # draft, and rebinds the panel's snapshot to the section it just read. Defaults
  # saved on the Export defaults page reach this page only through this read, so
  # it reloads them first; a stale digest would otherwise stop every request.
  @impl Phoenix.LiveView
  def handle_event("feed_quality_refresh", _params, socket) do
    defaults = ExportDefaults.get(socket.assigns.current_organization.id)

    {:noreply,
     socket
     |> assign(:export_defaults, defaults)
     |> assign(:include_flex, defaults.include_flex)
     |> refresh_feed_quality()}
  end

  @impl Phoenix.LiveView
  def handle_event("run_validation", _params, socket),
    do: handle_run_validation(socket, "mobility_data")

  @impl Phoenix.LiveView
  def handle_event("run_flex_validation", _params, socket),
    do: handle_run_validation(socket, "mobility_data_flex")

  @impl Phoenix.LiveView
  def handle_event("reset_validation", _params, socket) do
    if socket.assigns.validation_run_id do
      Phoenix.PubSub.unsubscribe(
        GtfsPlanner.PubSub,
        Validations.topic(socket.assigns.validation_run_id)
      )
    end

    {:noreply,
     socket
     |> assign(:validation_run_id, nil)
     |> assign(:validating, false)
     |> assign(:validation_progress, nil)
     |> assign(:validation_result, nil)
     |> assign(:validation_error, nil)}
  end

  @impl Phoenix.LiveView
  def handle_event("start_export", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    version = socket.assigns.current_gtfs_version
    socket = assign(socket, :export_notice, nil)

    with {:ok, run} <-
           ExportRuns.create_pending(
             organization_id,
             version.id,
             export_actor(socket),
             socket.assigns.export_type
           ),
         :ok <- subscribe_export_run(run),
         :ok <- ExportRunner.ensure_started(organization_id, run) do
      {:noreply,
       socket
       |> subscribe_file_run(run)
       |> assign(:export_run, run)
       |> remember_started(run)
       |> stream_insert(:files, run, at: 0)
       |> assign(:files_finished_run, nil)
       |> refresh_feed_quality()}
    else
      {:error, :invalid_transition} ->
        {:noreply, refresh_export_run(socket)}

      {:error, :busy} ->
        {:noreply, export_busy(socket)}

      {:error, :artifact_storage_unavailable} ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> assign(
           :export_notice,
           "The export couldn’t start: this server can’t write export files. Ask an administrator to check the export storage location."
         )}

      _ ->
        {:noreply,
         socket
         |> refresh_export_run()
         |> assign(:export_notice, "The export couldn’t start. Try again.")}
    end
  end

  # -- Files card ----------------------------------------------------------

  # One page of this version's retained runs. The keyset cursor is the last
  # listed row's `(inserted_at, id)`, so paging cannot skip or repeat a row.
  @files_page_size 25
  @file_unavailable_notice "That file isn't available."

  @impl Phoenix.LiveView
  def handle_event("load_more_files", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    rows =
      ExportRuns.list_files(organization_id, version_id,
        after: socket.assigns.files_cursor,
        limit: @files_page_size + 1
      )

    {page, rest} = Enum.split(rows, @files_page_size)

    {:noreply,
     socket
     |> assign(:files_has_more?, rest != [])
     |> assign(:files_cursor, cursor_for(List.last(page)))
     |> assign(:files_empty?, false)
     |> assign(:files_clash_run, clash_run(page, socket.assigns.files_clash_run))
     |> subscribe_listed_files(page)
     |> stream(:files, page)}
  end

  # A scoped row action casts the submitted id, resolves it inside this
  # organization and version, and only then writes. A forged id changes nothing
  # and is answered with the same opaque notice as an absent run.
  @impl Phoenix.LiveView
  def handle_event("cancel_file", %{"run" => run_id}, socket) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id),
         %{id: _} <- scoped_export_run(socket, uuid),
         {:ok, _run} <- ExportRuns.request_cancel(socket.assigns.current_organization.id, uuid) do
      {:noreply,
       socket
       |> assign(:files_notice, nil)
       |> put_files_toast("Export cancelled. No file was saved.", :done)}
    else
      _ -> {:noreply, assign(socket, :files_notice, @file_unavailable_notice)}
    end
  end

  def handle_event("cancel_file", _params, socket),
    do: {:noreply, assign(socket, :files_notice, @file_unavailable_notice)}

  @impl Phoenix.LiveView
  def handle_event("retry_file", params, socket), do: retry_file(socket, params)

  @impl Phoenix.LiveView
  def handle_event("export_again_file", params, socket), do: retry_file(socket, params)

  @impl Phoenix.LiveView
  def handle_event("dismiss_finished", _params, socket),
    do: {:noreply, assign(socket, :files_finished_run, nil)}

  @impl Phoenix.LiveView
  def handle_event("dismiss_toast", _params, socket),
    do: {:noreply, assign(socket, :files_toast, nil)}

  # -- Static publication --------------------------------------------------

  # The event carries no run, slot, tenant or key: the page's own selected run and
  # export type decide what is reviewed, and the command re-checks the membership
  # and the organization before it answers. A forged event can therefore only ask
  # for a review this page was already allowed to ask for.
  @impl Phoenix.LiveView
  def handle_event("preview_publication", _params, socket) do
    publication = socket.assigns.publication

    cond do
      not publication.available? ->
        {:noreply,
         publication_notice(
           socket,
           :error,
           "Publishing is not available here",
           "This installation or file type cannot publish a public feed."
         )}

      is_nil(publication.run) ->
        {:noreply,
         publication_notice(
           socket,
           :error,
           "There is no file to publish yet",
           "Export the feed first, then review the finished file."
         )}

      true ->
        {:noreply, start_publication_preview(socket)}
    end
  end

  # The tick is the operator's own answer to the error count the server showed, so
  # it is recorded as it changes and survives a refused publish.
  @impl Phoenix.LiveView
  def handle_event("consent_publication", params, socket) do
    consent? = get_in(params, ["publication", "confirm_errors"]) == "true"
    {:noreply, put_publication(socket, %{consent_form: consent_form(consent?)})}
  end

  @impl Phoenix.LiveView
  def handle_event("confirm_publication", params, socket) do
    preview = socket.assigns.publication.preview

    if preview do
      # `confirm_errors?: true` only ever means the operator ticked the box against
      # a review that actually has errors; everything else the command re-derives
      # from its own signed consent token and the durable rows.
      consent? = get_in(params, ["publication", "confirm_errors"]) == "true"
      confirm_errors? = consent? and preview.errors_count > 0

      case FeedPublishing.publish_static(
             publication_scope(socket),
             preview.token,
             preview.destination_revision,
             confirm_errors?: confirm_errors?
           ) do
        {:ok, publication_id} ->
          # The status band is the durable answer and it changes to "Publishing"
          # here, so a second confirmation beside it would only repeat it.
          {:noreply,
           socket
           |> put_publication(%{
             preview: nil,
             pending_id: nil,
             notice: nil,
             consent_form: consent_form(false),
             publication_id: publication_id
           })
           |> refresh_publication_status()}

        {:error, reason} ->
          {kind, title, detail} = publication_error(reason)

          # A refused write changes nothing, so the review stays exactly as the
          # operator left it, tick included, and the refusal is answered beside it.
          socket =
            socket
            |> refresh_publication_status()
            |> put_publication(%{consent_form: consent_form(consent?)})

          {:noreply, publication_notice(socket, kind, title, detail)}
      end
    else
      {:noreply,
       publication_notice(
         socket,
         :error,
         "There is no review to publish",
         "Review the file first, then publish it."
       )}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("close_publication_review", _params, socket) do
    {:noreply, close_publication_review(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:export_run_changed, run_id}, socket) do
    # A newer export is a different file, so a review of the previous one belongs
    # to a page the operator has left. The review is closed for the same reason a
    # version switch closes it.
    previous_run_id = socket.assigns.publication.run && socket.assigns.publication.run.id
    changed_run = scoped_export_run(socket, run_id)
    socket = refresh_export_run(socket)
    current_run_id = socket.assigns.export_run && socket.assigns.export_run.id

    socket =
      if previous_run_id == current_run_id,
        do: socket,
        else: close_publication_review(socket)

    socket =
      case changed_run do
        %{} = run -> stream_insert(socket, :files, run)
        _ -> socket
      end

    # A listed run that fails with a garage/stop clash now owns the card's
    # callout, the same as one already failed when the page mounted.
    socket =
      if changed_run && changed_run.state == :failed &&
           changed_run.failure_code == "garage_stop_id_conflict" do
        assign(socket, :files_clash_run, changed_run)
      else
        socket
      end

    socket =
      if changed_run && changed_run.state == :ready &&
           MapSet.member?(socket.assigns.files_started_ids, changed_run.id) do
        assign(socket, :files_finished_run, changed_run)
      else
        socket
      end

    {:noreply,
     socket
     |> refresh_operations_preview_for_ready_run(changed_run)
     |> assign_publication()
     |> refresh_feed_quality()}
  end

  # The check the open review is waiting for finished. Building the review again is
  # the only way it opens, and both closing the review and leaving the page clear
  # `pending_id`, so a result for a review the operator has left cannot match here.
  @impl Phoenix.LiveView
  def handle_info(
        {:validation_completed, run_id},
        %{assigns: %{publication: %{pending_id: run_id}}} = socket
      ) do
    {:noreply, socket |> put_publication(%{pending_id: nil}) |> start_publication_preview()}
  end

  @impl Phoenix.LiveView
  def handle_info(
        {:validation_failed, run_id},
        %{assigns: %{publication: %{pending_id: run_id}}} = socket
      ) do
    # A failed report is never retried by itself: the operator decides whether the
    # file is worth checking again.
    {:noreply,
     socket
     |> put_publication(%{pending_id: nil})
     |> publication_notice(
       :error,
       "The feed check failed",
       "The file was not checked successfully, so it cannot be published. Start a check again from the panel on the right."
     )}
  end

  @impl Phoenix.LiveView
  def handle_info({:validation_progress, progress}, socket) do
    {:noreply, assign(socket, :validation_progress, progress)}
  end

  # The run's row decides the outcome, so a message that was queued behind a
  # newer state, or a run that finished before this page subscribed, ends the
  # same way. A run the page no longer shows (reset, or a newer check) changes nothing.
  @impl Phoenix.LiveView
  def handle_info(
        {event, run_id},
        %{assigns: %{validation_run_id: run_id}} = socket
      )
      when event in [:validation_completed, :validation_failed] do
    {:noreply, apply_validation_outcome(socket, Validations.get_validation_run!(run_id))}
  end

  @impl Phoenix.LiveView
  def handle_info({event, _run_id}, socket)
      when event in [:validation_completed, :validation_failed] do
    {:noreply, socket}
  end

  # The toast's dismiss timer carries its token, so a timer set for an earlier
  # toast cannot clear a later one.
  @impl Phoenix.LiveView
  def handle_info({:dismiss_toast, token}, socket) do
    if socket.assigns.files_toast && socket.assigns.files_toast.token == token do
      {:noreply, assign(socket, :files_toast, nil)}
    else
      {:noreply, socket}
    end
  end

  defp apply_validation_outcome(socket, %{status: "completed"} = run) do
    socket
    |> assign_persisted_validation_result(run)
    |> assign(:validating, false)
    |> assign(:validation_progress, nil)
    |> refresh_feed_quality()
  end

  defp apply_validation_outcome(socket, %{status: "failed"}) do
    socket
    |> assign(:validation_error, :failed)
    |> assign(:validating, false)
    |> assign(:validation_progress, nil)
  end

  defp apply_validation_outcome(socket, _running_run), do: socket

  defp assign_persisted_validation_result(socket, run) do
    if run.organization_id != socket.assigns.current_organization.id do
      assign(socket, :validation_error, :other_organization)
    else
      socket
      |> assign(:validation_result, %{
        summary: %{
          errors: run.errors_count,
          warnings: run.warnings_count,
          infos: run.infos_count
        }
      })
      |> assign_recent_checks()
    end
  end

  defp load_files(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    rows = ExportRuns.list_files(organization_id, version_id, limit: @files_page_size + 1)
    {page, rest} = Enum.split(rows, @files_page_size)

    socket
    |> assign(:files_has_more?, rest != [])
    |> assign(:files_cursor, cursor_for(List.last(page)))
    |> assign(:files_empty?, page == [])
    |> assign(:files_clash_run, clash_run(page, socket.assigns.files_clash_run))
    |> subscribe_listed_files(page)
    |> stream(:files, page, reset: true)
  end

  defp cursor_for(nil), do: nil
  defp cursor_for(%{inserted_at: inserted_at, id: id}), do: {inserted_at, id}

  defp subscribe_listed_files(socket, runs) do
    Enum.reduce(runs, socket, fn run, acc ->
      if run.state in [:pending, :building], do: subscribe_file_run(acc, run), else: acc
    end)
  end

  # A listed run is subscribed once per LiveView, so a type patch that reloads
  # the same page never doubles its broadcasts; a started or retried run is
  # remembered the same way.
  defp subscribe_file_run(socket, run) do
    if MapSet.member?(socket.assigns.files_subscribed_ids, run.id) do
      socket
    else
      subscribe_export_run(run)

      assign(
        socket,
        :files_subscribed_ids,
        MapSet.put(socket.assigns.files_subscribed_ids, run.id)
      )
    end
  end

  defp clash_run(runs, existing) do
    cond do
      existing != nil ->
        existing

      true ->
        Enum.find(
          runs,
          &(&1.state == :failed and &1.failure_code == "garage_stop_id_conflict")
        )
    end
  end

  defp put_files_toast(socket, text, kind) do
    token = System.unique_integer([:positive, :monotonic])
    Process.send_after(self(), {:dismiss_toast, token}, 4_000)
    assign(socket, :files_toast, %{text: text, kind: kind, token: token})
  end

  defp remember_started(socket, run),
    do: assign(socket, :files_started_ids, MapSet.put(socket.assigns.files_started_ids, run.id))

  defp retry_file(socket, %{"run" => run_id}) do
    organization_id = socket.assigns.current_organization.id

    with {:ok, uuid} <- Ecto.UUID.cast(run_id),
         %{id: _} <- scoped_export_run(socket, uuid),
         {:ok, run} <- ExportRuns.retry(organization_id, uuid),
         :ok <- ExportRunner.ensure_started(organization_id, run) do
      {:noreply,
       socket
       |> subscribe_file_run(run)
       |> remember_started(run)
       |> stream_insert(:files, run)
       |> assign(:files_notice, nil)
       |> assign(:files_finished_run, nil)}
    else
      {:error, :busy} -> {:noreply, export_busy(socket)}
      _ -> {:noreply, assign(socket, :files_notice, @file_unavailable_notice)}
    end
  end

  defp retry_file(socket, _params),
    do: {:noreply, assign(socket, :files_notice, @file_unavailable_notice)}

  @impl Phoenix.LiveView
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
      <:sub_header>
        <.gtfs_sub_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:export} />
      </:sub_header>

      <div id="export-page" class="ds-page">
        <.header>
          Export
          <:actions>
            <.button
              id="agent-helper-open"
              type="button"
              phx-click="agent_open"
              aria-expanded={to_string(@agent_open?)}
              aria-controls="agent-panel"
              variant="quiet"
              class="min-h-11"
            >
              Open helper
            </.button>
          </:actions>
        </.header>

        <div
          id="export-helper-focus"
          phx-hook=".ExportHelperFocus"
          class={["lg:grid lg:gap-6", @agent_open? && "lg:grid-cols-[minmax(0,1fr)_24rem]"]}
        >
          <div class={@agent_open? && "hidden lg:block"}>
            <div
              id="export-download-container"
              class={[
                "mt-2 grid gap-6",
                !@agent_open? && "lg:grid-cols-[minmax(0,1fr)_23rem] lg:items-start"
              ]}
            >
              <div class="grid min-w-0 gap-6">
                <div id="export-workspace">
                  <.new_file
                    form={@export_form}
                    export_type={@export_type}
                    operations?={@operations?}
                    version={@current_gtfs_version}
                    file_inventory={@file_inventory}
                    operations_preview={@operations_preview}
                    missing_summary={@missing_summary}
                    defaults={@export_defaults}
                    run={@export_run}
                    notice={@export_notice}
                    closure_count={@closure_count}
                  />
                </div>

                <.publication_section publication={@publication} />

                <.files_card
                  empty?={@files_empty?}
                  has_more?={@files_has_more?}
                  notice={@files_notice}
                  finished_run={@files_finished_run}
                  clash_run={@files_clash_run}
                  version={@current_gtfs_version}
                >
                  <:files_list>
                    <tbody id="export-files-rows" phx-update="stream">
                      <.file_row
                        :for={{dom_id, run} <- @streams.files}
                        dom_id={dom_id}
                        run={run}
                        version={@current_gtfs_version}
                      />
                    </tbody>
                  </:files_list>
                </.files_card>
              </div>

              <div class="grid min-w-0 gap-6">
                <section
                  id="feed-quality-evidence"
                  class="rounded-card border border-control bg-white px-5 py-4"
                >
                  <h3 class="text-sm font-bold text-strong">Feed quality</h3>
                  <p id="feed-quality-relationship" class="mt-1 text-[13px] text-default">
                    {relationship_copy(@feed_quality)}
                  </p>
                  <p class="mt-1 text-[13px] text-muted">
                    Currentness: {@feed_quality.currentness}. Publication: {@feed_quality.publication_status}.
                  </p>
                  <button
                    id="feed-quality-refresh"
                    type="button"
                    phx-click="feed_quality_refresh"
                    class="mt-2 text-[13px] font-semibold text-action"
                  >
                    Refresh check
                  </button>
                </section>
                <.check_panel
                  validating?={@validating}
                  progress={@validation_progress}
                  result={@validation_result}
                  error={@validation_error}
                  validation_run_id={@validation_run_id}
                  version={@current_gtfs_version}
                  include_flex={@include_flex}
                />
                <.recent_checks :if={@recent_checks != []} checks={@recent_checks} />
              </div>
            </div>
          </div>

          <div
            :if={@agent_open?}
            class="flex min-w-0 lg:sticky lg:top-4 lg:max-h-[calc(100vh-2rem)]"
          >
            <.agent_panel
              id="agent-panel"
              title={@agent_title}
              intro={@agent_intro}
              examples={@agent_examples}
              scope_line={helper_scope_line(@current_gtfs_version)}
              composer_hint={helper_composer_hint()}
              status={@agent_status}
              entries={@streams.agent_entries}
              form={@agent_form}
              notice={@agent_notice}
              entries_empty?={@agent_entries_empty?}
              review_label={&agent_review_label/1}
            />
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ExportHelperFocus">
        export default {
          mounted() {
            this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
          }
        }
      </script>
      <.toast
        :if={@files_toast}
        id="export-toast"
        text_id="export-toast-text"
        toast={@files_toast}
      />
    </Layouts.app>
    """
  end

  defp helper_scope_line(version), do: "Export · " <> version.name

  # The feed quality helper prepares an export-options change for review, which is
  # the component's own default rule.
  defp helper_composer_hint, do: "Review changes before applying."

  # The title a check carries in Recent checks: a plain name for the kind of check.
  defp check_title(%{run_type: "mobility_data"}, _station_names_by_run_id), do: "Feed check"

  defp check_title(%{run_type: "mobility_data_flex"}, _station_names_by_run_id),
    do: "Flex file check"

  defp check_title(%{run_type: "pathways_tests"}, _station_names_by_run_id),
    do: "Pathways test"

  defp check_title(%{run_type: "station_reachability", id: run_id}, station_names_by_run_id) do
    case Map.get(station_names_by_run_id, run_id) do
      station_name when is_binary(station_name) and station_name != "" ->
        "Station reachability · #{station_name}"

      _other ->
        "Station reachability"
    end
  end

  defp check_title(%{run_type: type}, _station_names_by_run_id), do: type

  defp recent_validation_display_counts(%{run_type: "pathways_tests", result_json: result_json})
       when is_map(result_json) do
    summary = Map.get(result_json, "summary", %{})

    %{
      errors: Map.get(summary, "scoring_failure", 0),
      warnings: Map.get(summary, "query_failure", 0),
      infos: Map.get(summary, "passed", 0)
    }
  end

  defp recent_validation_display_counts(run) do
    %{
      errors: run.errors_count,
      warnings: run.warnings_count,
      infos: run.infos_count
    }
  end

  defp build_recent_validation_station_names_map(runs, organization_id, gtfs_version_id) do
    runs
    |> Enum.reduce(%{}, fn run, station_names_by_run_id ->
      case station_reachability_station_stop_id(run) do
        nil ->
          station_names_by_run_id

        station_stop_id ->
          case station_name_for_stop_id(organization_id, gtfs_version_id, station_stop_id) do
            nil -> station_names_by_run_id
            station_name -> Map.put(station_names_by_run_id, run.id, station_name)
          end
      end
    end)
  end

  defp station_reachability_station_stop_id(%{
         run_type: "station_reachability",
         result_json: result_json
       })
       when is_map(result_json) do
    metadata = payload_value(result_json, :metadata)

    payload_value(metadata, :station_stop_id) || payload_value(result_json, :station_stop_id)
  end

  defp station_reachability_station_stop_id(_run), do: nil

  defp station_name_for_stop_id(organization_id, gtfs_version_id, station_stop_id)
       when is_binary(station_stop_id) do
    case Gtfs.get_stop_by_stop_id(organization_id, gtfs_version_id, station_stop_id) do
      %{stop_name: stop_name, stop_id: stop_id} ->
        if is_binary(stop_name) and stop_name != "", do: stop_name, else: stop_id

      _other ->
        nil
    end
  end

  defp station_name_for_stop_id(_organization_id, _gtfs_version_id, _station_stop_id), do: nil

  defp validation_run_results_path(gtfs_version_id, run) do
    case station_reachability_station_stop_id(run) do
      station_stop_id when is_binary(station_stop_id) and station_stop_id != "" ->
        ~p"/gtfs/#{gtfs_version_id}/station-reachability/#{run.id}?stop_id=#{station_stop_id}"

      _other ->
        if run.run_type == "station_reachability" do
          ~p"/gtfs/#{gtfs_version_id}/station-reachability/#{run.id}"
        else
          ~p"/gtfs/#{gtfs_version_id}/validation/#{run.id}"
        end
    end
  end

  defp assign_recent_checks(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    runs = Validations.list_recent_validation_runs(organization_id, gtfs_version_id, 5)

    station_names =
      build_recent_validation_station_names_map(runs, organization_id, gtfs_version_id)

    assign(
      socket,
      :recent_checks,
      Enum.map(runs, fn run ->
        counts = recent_validation_display_counts(run)

        %{
          id: run.id,
          title: check_title(run, station_names),
          started_at: run.started_at,
          path: validation_run_results_path(gtfs_version_id, run),
          kind: if(run.run_type == "pathways_tests", do: :pathways_test, else: :severity),
          errors: counts.errors,
          warnings: counts.warnings,
          infos: counts.infos
        }
      end)
    )
  end

  defp payload_value(nil, _key), do: nil

  defp payload_value(payload, key) when is_map(payload),
    do: Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  defp payload_value(_payload, _key), do: nil

  defp run_mobility_data_validation(socket, organization_id, gtfs_version_id, run_type) do
    case Validations.start_mobility_data_run(
           organization_id,
           gtfs_version_id,
           run_type,
           export_actor(socket)
         ) do
      {:ok, run} ->
        # Subscribe, then read the row: a run that finished before the
        # subscription has no message coming.
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Validations.topic(run.id))

        {:noreply,
         socket
         |> assign(:validation_run_id, run.id)
         |> assign(:validating, true)
         |> assign(:validation_progress, %{phase: :starting, percent: 0})
         |> assign(:validation_result, nil)
         |> assign(:validation_error, nil)
         |> apply_validation_outcome(Validations.get_validation_run!(run.id))}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, @validation_busy_message)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, @validation_permission_message)}

      {:error, _reason} ->
        {:noreply, assign(socket, :validation_error, :not_started)}
    end
  end

  defp handle_run_validation(socket, run_type) do
    if socket.assigns.validating do
      {:noreply, put_flash(socket, :error, "A check is already running.")}
    else
      organization_id = socket.assigns.current_organization.id
      gtfs_version_id = socket.assigns.current_gtfs_version.id
      run_mobility_data_validation(socket, organization_id, gtfs_version_id, run_type)
    end
  end

  defp export_form(export_type),
    do: to_form(%{"type" => Atom.to_string(export_type)}, as: :export)

  defp export_type_from_param("pathways"), do: :pathways
  defp export_type_from_param("operations"), do: :operations
  defp export_type_from_param("operations_only"), do: :operations_only
  defp export_type_from_param(_type), do: :full

  # ProductSurfaces alone decides visibility (INV-1): a Pathways organization
  # never selects either operations kind, so its query param falls back to full.
  defp resolve_export_type(type_param, organization) do
    case export_type_from_param(type_param) do
      type when type in @operations_kinds ->
        if ProductSurfaces.visible?(organization, :operations_export),
          do: type,
          else: :full

      export_type ->
        export_type
    end
  end

  defp operations_kind?(export_type), do: export_type in @operations_kinds

  # The operations preview is one async derivation per LiveView visit. The first
  # time either operations-bearing kind is selected the task starts; switching
  # back to full and then to the other operations kind never starts a second one.
  defp ensure_operations_preview(socket) do
    if operations_kind?(socket.assigns.export_type) and
         not socket.assigns.operations_preview_started? do
      load_operations_preview(socket)
    else
      socket
    end
  end

  # `Export.operations_preview/2` is the sole derivation of the TODS file counts,
  # runs and trips; neither this page nor a component counts them again.
  defp load_operations_preview(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    repo = Repo.get_dynamic_repo()

    socket
    |> assign(:operations_preview_started?, true)
    |> assign_async(:operations_preview, fn ->
      # `assign_async` runs its function in a fresh task, which does not inherit
      # this LiveView's dynamic repo, so the task re-binds it before reading.
      Repo.put_dynamic_repo(repo)

      case Gtfs.Export.operations_preview(organization_id, version_id) do
        {:ok, preview} -> {:ok, %{operations_preview: preview}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # A newly ready operations-bearing run can change the counts the preview read
  # before that run, so the preview is derived once more. The refreshed run's id
  # is recorded, so a repeat broadcast for the same run never starts another task.
  defp refresh_operations_preview_for_ready_run(socket, changed_run) do
    case changed_run do
      %{state: :ready, export_type: export_type, id: run_id}
      when export_type in @operations_kinds ->
        if socket.assigns.operations_preview_refreshed_run_id == run_id do
          socket
        else
          socket
          |> assign(:operations_preview_refreshed_run_id, run_id)
          |> load_operations_preview()
        end

      _other ->
        socket
    end
  end

  defp scoped_export_run(socket, run_id) do
    ExportRuns.get_for_version(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id,
      run_id
    )
  end

  defp export_actor(socket) do
    %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}
  end

  defp refresh_file_inventory(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    export_type = socket.assigns.export_type

    # The combined operations export packages the full GTFS file set; the
    # operations-only export has no GTFS base. TODS counts are never derived
    # here: `Export.operations_preview/2` is the one place that counts them.
    base_type =
      case export_type do
        :operations -> :full
        :operations_only -> nil
        other -> other
      end

    file_inventory =
      case base_type do
        nil -> []
        type -> Gtfs.get_file_inventory(organization_id, version_id, type)
      end

    # The omission notice reads the published closure count through the same
    # scope the Evolutions surface uses; the route only mounts a published
    # version, so it matches the rows the full inventory reports.
    socket
    |> assign(
      :file_inventory,
      Enum.sort_by(file_inventory, fn {filename, _count} -> filename end)
    )
    |> assign(:closure_count, Gtfs.count_closures(organization_id, version_id))
  end

  # -- Feed quality helper ----------------------------------------------------

  # The section and the panel's snapshot read the same scoped evidence, so both
  # describe one selection. Every change of the selected export, its checks, its
  # type or the saved defaults goes through here; `set_context` is a no-op while
  # the snapshot is unchanged and starts a fresh conversation when it moved.
  defp refresh_feed_quality(socket) do
    socket = assign(socket, :feed_quality, feed_quality_summary(socket))

    AgentPanel.set_context(socket, feed_quality_context(socket))
  end

  # The host builds the snapshot the helper reads: only a server fingerprint of
  # the section, export reference, type and defaults digest - never report JSON,
  # paths, logs or personnel fields. A refused or oversized envelope falls back
  # to the plain context, which the pack answers as unavailable, never a crash.
  defp feed_quality_context(socket) do
    version_id = socket.assigns.current_gtfs_version.id
    export_type = socket.assigns.export_type
    defaults_digest = FeedQuality.defaults_digest(socket.assigns.export_defaults)
    selected_export_ref = latest_export_ref(socket)

    payload = %{
      "schema_version" => 1,
      "section" => "export",
      "type" => Atom.to_string(export_type),
      "selected_export_ref" => selected_export_ref,
      "defaults_digest" => defaults_digest,
      "source_digest" =>
        digest(
          {:feed_quality_source, version_id, export_type, defaults_digest, selected_export_ref}
        )
    }

    case Scope.with_source_snapshot(Scope.context({:version, version_id}), %{
           kind: "feed_quality",
           payload: payload
         }) do
      {:ok, context} -> context
      {:error, _reason} -> Scope.context({:version, version_id})
    end
  end

  # The section is provider-independent: it reads the same scoped Evidence the
  # pack reads, and never starts, repairs or publishes anything.
  defp feed_quality_summary(socket) do
    case Evidence.readiness(feed_quality_scope(socket), socket.assigns.export_type, nil, :primary) do
      {:ok, readiness} ->
        %{
          relationship: readiness.relationship,
          selected_artifact: readiness.selected_artifact,
          currentness: readiness.currentness,
          publication_status: readiness.publication_status,
          digest: readiness.digest,
          preflight: readiness.preflight
        }

      {:error, _reason} ->
        @empty_feed_quality
    end
  end

  defp feed_quality_scope(socket) do
    user = socket.assigns.current_user

    %Scope{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "feed_quality",
      version_name: socket.assigns.current_gtfs_version.name,
      resource_context: socket.assigns.agent_context
    }
  end

  defp latest_export_ref(socket) do
    case ExportRuns.latest_for_version(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.export_type
         ) do
      %{id: id} -> id
      _other -> nil
    end
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp review_feed_quality_options(%{assigns: %{agent_pack_id: "feed_quality"}} = socket, id)
       when is_binary(id) do
    case Integer.parse(id) do
      {entry_id, ""} -> review_feed_quality_entry(socket, entry_id)
      _other -> socket
    end
  end

  defp review_feed_quality_options(socket, _id), do: socket

  # The command is read only from the conversation's own prepared entry. Any
  # identity, defaults or context drift is a notice beside the untouched native
  # form: no retry invents a selection, and nothing is recorded as applied.
  defp review_feed_quality_entry(socket, entry_id) do
    case Agents.prepared(
           socket.assigns.agent_session,
           socket.assigns.agent_conversation_id,
           entry_id
         ) do
      {:ok,
       %{
         command:
           {:feed_quality_export_options,
            %{
              export_type: type,
              defaults_digest: defaults_digest,
              context_digest: context_digest
            }}
       }} ->
        type_param = Atom.to_string(type)

        if type_param in @export_type_params and
             defaults_digest == FeedQuality.defaults_digest(socket.assigns.export_defaults) and
             context_digest == Scope.context_digest(feed_quality_scope(socket)) do
          # The panel closes so the native form shows the selection at every
          # width (a phone shows the panel instead of the form), and focus lands
          # on the chosen type, the control the person goes on to review.
          socket
          |> assign(:agent_open?, false)
          |> push_patch(
            to: ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/export?type=#{type_param}"
          )
          |> push_event("agent:focus", %{id: "export-type-#{type_param}"})
        else
          assign(
            socket,
            :agent_notice,
            "The export settings changed since the helper answered. Ask it again."
          )
        end

      _stale_or_unknown ->
        assign(socket, :agent_notice, "That prepared change is no longer available.")
    end
  end

  defp relationship_copy(%{relationship: "checked"}),
    do: "A completed check read these exact bytes."

  defp relationship_copy(%{relationship: "different_bytes"}),
    do: "A completed check read different bytes for this version."

  defp relationship_copy(%{relationship: "different_profile"}),
    do: "A completed check's profile differs from this selection."

  defp relationship_copy(%{relationship: "unavailable"}),
    do: "This export selection is not available."

  defp relationship_copy(_summary),
    do: "The check history cannot be compared to this selection yet."

  defp agent_review_label(%{command: {:feed_quality_export_options, _command}}),
    do: "Review options"

  defp agent_review_label(_prepared), do: "Review prepared change"

  # The runner supervisor is full. The run that never started is already closed,
  # so the page goes back to the export it was showing and says why.
  defp export_busy(socket) do
    socket
    |> refresh_export_run()
    |> assign(:export_notice, @export_busy_message)
  end

  defp refresh_export_run(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    export_run =
      ExportRuns.latest_for_version(organization_id, version_id, socket.assigns.export_type)

    if export_run, do: subscribe_export_run(export_run)
    assign(socket, :export_run, export_run)
  end

  defp subscribe_export_run(run),
    do: Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ExportRuns.topic(run))

  # The version's missing-times count loads apart from the file list, so a
  # large version never blocks the page; the pre-run line reads it when ready.
  defp load_missing_summary(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    assign_async(socket, :missing_summary, fn ->
      {:ok, %{missing_summary: MissingTimes.summary(organization_id, version_id)}}
    end)
  end

  # -- Static publication --------------------------------------------------

  # The export type names the public channel this page is about, and the reviewed
  # artifact is the run's main one. Operations has no channel: the catalog owner
  # refuses that profile outright, so the page never offers the action.
  defp publication_channel(:full), do: :full
  defp publication_channel(:pathways), do: :pathways
  defp publication_channel(_export_type), do: nil

  defp default_publication do
    %{
      available?: false,
      opener?: false,
      channel: nil,
      slot: :main,
      run: nil,
      preview: nil,
      pending_id: nil,
      publication_id: nil,
      consent_form: consent_form(false),
      notice: nil,
      status: not_published_status()
    }
  end

  defp not_published_status do
    %{
      kind: "neutral",
      title: "Not published yet",
      detail:
        "Publishing copies the reviewed file to this organization's public URL, where anyone with the link can download it."
    }
  end

  defp consent_form(consent?), do: to_form(%{"confirm_errors" => consent?}, as: :publication)

  defp publication_scope(socket) do
    %{
      organization_id: socket.assigns.current_organization.id,
      actor_id: socket.assigns.current_user.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id
    }
  end

  defp assign_publication(socket) do
    channel = publication_channel(socket.assigns.export_type)

    if is_nil(channel) or PublishingConfig.current() == :disabled do
      assign(socket, :publication, default_publication())
    else
      run = if(match?(%{state: :ready}, socket.assigns.export_run), do: socket.assigns.export_run)

      socket
      |> put_publication(%{available?: true, channel: channel, slot: :main, run: run})
      |> refresh_publication_status()
    end
  end

  # A navigation names a different version, run or export type, so any open review
  # is left behind here. Closing also clears `pending_id`, which is what rejects a
  # check that finishes after the operator has moved on.
  defp reset_publication(socket) do
    socket
    |> put_publication(%{
      preview: nil,
      pending_id: nil,
      notice: nil,
      consent_form: consent_form(false)
    })
  end

  defp close_publication_review(socket) do
    put_publication(socket, %{
      preview: nil,
      pending_id: nil,
      notice: nil,
      consent_form: consent_form(false)
    })
  end

  defp put_publication(socket, changes) do
    publication = Map.merge(socket.assigns.publication, changes)

    opener? =
      publication.available? and not is_nil(publication.run) and is_nil(publication.preview) and
        is_nil(publication.pending_id)

    assign(socket, :publication, %{publication | opener?: opener?})
  end

  defp publication_notice(socket, kind, title, detail) do
    put_publication(socket, %{notice: %{kind: to_string(kind), title: title, detail: detail}})
  end

  defp start_publication_preview(socket) do
    publication = socket.assigns.publication

    case FeedPublishing.preview_static(
           publication_scope(socket),
           publication.run.id,
           publication.slot
         ) do
      {:ok, preview} ->
        put_publication(socket, %{
          preview: preview,
          pending_id: nil,
          notice: nil,
          consent_form: consent_form(false)
        })

      {:pending, validation_run_id} ->
        # The report is the one the review will show, so its result is what reopens
        # this review; nothing else on the page may answer for it.
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, Validations.topic(validation_run_id))

        socket
        |> put_publication(%{preview: nil, pending_id: validation_run_id})
        |> publication_notice(
          :info,
          "Checking this file",
          "The feed check is running. The review opens here as soon as it finishes, and you can leave this page while it runs."
        )
        |> refresh_publication_status()

      {:error, reason} ->
        {kind, title, detail} = publication_error(reason)

        socket
        |> put_publication(%{preview: nil, pending_id: nil})
        |> publication_notice(kind, title, detail)
    end
  end

  defp refresh_publication_status(%{assigns: %{publication: %{available?: false}}} = socket),
    do: socket

  defp refresh_publication_status(socket) do
    publication = socket.assigns.publication

    status =
      case FeedPublishing.status(publication_scope(socket)) do
        {:ok, channels} ->
          channels
          |> Enum.find(&(&1.channel == publication.channel))
          |> channel_status()

        {:error, _reason} ->
          %{
            kind: "neutral",
            title: "Publication state is unavailable",
            detail: "This organization's publication state could not be read for your account."
          }
      end

    assign(socket, :publication, %{publication | status: status})
  end

  defp channel_status(nil), do: not_published_status()

  defp channel_status(%{status: :current} = channel) do
    %{
      kind: "success",
      title: "Published",
      detail: "The public feed is served from the reviewed file." <> served_since(channel)
    }
  end

  defp channel_status(%{status: status})
       when status in [:pending, :staging, :switching, :reconciling] do
    %{
      kind: "info",
      title: "Publishing",
      detail:
        "The file is queued and becomes public when the switch completes. You can leave this page."
    }
  end

  defp channel_status(%{status: status} = channel) when status in [:failed, :blocked] do
    %{
      kind: "error",
      title: "Publication failed",
      detail:
        channel.last_error || "The publisher could not serve this file. Try publishing again."
    }
  end

  defp channel_status(_channel), do: not_published_status()

  defp served_since(%{manifest_last_modified: %DateTime{} = at}),
    do: " Last served #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}."

  defp served_since(_channel), do: ""

  # Every refusal the command can answer with becomes one plain sentence beside
  # the review that raised it; the operator never has to read an error atom.
  defp publication_error(:disabled),
    do:
      {:error, "Publishing is turned off",
       "This installation has no public feed storage configured. Ask an administrator."}

  defp publication_error(:forbidden),
    do:
      {:error, "You cannot publish this feed",
       "Only an editor of this organization can publish its public feed."}

  defp publication_error(:not_found),
    do:
      {:error, "That file is no longer available",
       "Export the feed again, then review the new file."}

  defp publication_error(:artifact_busy),
    do:
      {:error, "A check or upload is already running",
       "Another review or upload is using this file. Try again when it finishes."}

  defp publication_error(:artifact_unavailable),
    do:
      {:error, "The file has expired",
       "A finished export is kept for a short time. Export the feed again, then review the new file."}

  defp publication_error(:validation_failed),
    do:
      {:error, "The feed check did not pass",
       "The file cannot be published from a failed check. Start a check again from the panel on the right."}

  defp publication_error(:stale_review),
    do:
      {:error, "That review is out of date", "Review the file again and publish the new review."}

  defp publication_error(:review_pending),
    do:
      {:error, "The feed check is still running",
       "Wait for the check to finish, then review the file again."}

  defp publication_error(:expired_preview),
    do:
      {:error, "This review expired",
       "A review is good for fifteen minutes. Review the file again and publish the new review."}

  defp publication_error(:stale_destination),
    do:
      {:error, "The public feed changed while you were reviewing",
       "Someone else published this feed. Review the file again, then publish the new review."}

  defp publication_error({:errors_require_confirmation, count}),
    do:
      {:error, "Confirm the check report first",
       "This review has #{count} #{if count == 1, do: "error", else: "errors"}. Tick the box to confirm you have read #{if count == 1, do: "it", else: "them"}, then publish."}

  defp publication_error(reason)
       when reason in [
              :invalid_preview,
              :invalid_slot
            ],
       do:
         {:error, "That review cannot be used",
          "Review the file again and publish the new review."}

  defp publication_error(reason)
       when reason in [
              :operations_profile_not_publishable,
              :tods_content_not_publishable,
              :unsafe_entry_name,
              :archive_too_large,
              :unreadable_archive,
              :artifact_hash_mismatch,
              :invalid_artifact
            ],
       do:
         {:error, "This file cannot be published",
          "The file is not a feed this installation can serve. Export a full or pathways feed and publish that."}

  defp publication_error(_reason),
    do:
      {:error, "The feed was not published",
       "Nothing changed. Try again, and tell an administrator if it keeps failing."}
end

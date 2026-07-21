defmodule GtfsPlannerWeb.Gtfs.ImportLive do
  @moduledoc """
  LiveView for importing GTFS data.
  Requires the pathways_studio_editor role (editor only, not viewer).
  """
  use GtfsPlannerWeb, :live_view

  import Ecto.Query, only: [from: 2]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import

  alias GtfsPlanner.Gtfs.Import.{
    Result,
    Diff,
    ChangeArtifactStorage,
    ChangeDecision,
    ChangeRun,
    ChangeRunner,
    ChangeRuns,
    Diff,
    DiffDecision,
    ParseError,
    ParseFailure,
    ParsedEntity,
    RowParser
  }

  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.Import.Runner
  alias GtfsPlanner.Gtfs.ImportRuns
  alias GtfsPlannerWeb.Components.TransitPresentation
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
    organization_id = socket.assigns.current_organization.id

    # Reconcile expired leases and adopt runless legacy failed versions into
    # durable, organization-scoped recoverable runs before showing the page, so
    # a reconnect always reconstructs current state from PostgreSQL.
    ImportRuns.adopt_legacy_failed_targets(organization_id)
    ImportRuns.reconcile_expired(organization_id)

    recoverable_runs = ImportRuns.list_recoverable(organization_id)
    route_version_id = socket.assigns.current_gtfs_version.id
    change_run = ChangeRuns.latest_for_version(organization_id, route_version_id)

    for run <- recoverable_runs do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))
    end

    if change_run, do: Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(change_run))

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
     |> assign(:diff_form, to_form(%{}, as: :diff_upload))
     |> assign(:import_result, nil)
     |> assign(:import_target, nil)
     |> assign(:published_version, nil)
     |> assign(:version_name_touched, false)
     |> assign(:import_progress, nil)
     |> assign(:importing, false)
     |> assign(:unrecognized_upload_files, [])
     |> assign(:recovery_empty, recoverable_runs == [])
     |> assign(:recovery_count, length(recoverable_runs))
     |> assign(:pending_discard_run_id, nil)
     |> assign(:processing_discard, false)
     |> assign(:processing_publish, nil)
     |> assign(:recovery_announce, nil)
     |> assign(:change_run, change_run)
     |> assign(:diff_step, diff_step(change_run))
     |> assign(:diff_summary, run_summary(change_run))
     |> assign(:diff_filter, :all)
     |> assign(:diff_parse_failures, [])
     |> assign(:diff_blockers, [])
     |> assign(:diff_preview_count, 0)
     |> assign(:apply_results, [])
     |> assign(:decisions_by_id, %{})
     |> stream(:diff_decisions, [])
     |> stream(:diff_preview_decisions, [])
     |> stream(:import_recovery_runs, recoverable_runs,
       dom_id: fn run -> "import-run-#{run.id}" end
     )
     |> refresh_change_review()}
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

    socket =
      if errors != [],
        do: push_event(socket, "focus_first_error", %{selector: "#gtfs-import-version-name"}),
        else: socket

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

  # --- recovery actions ------------------------------------------------------

  # Begin the two-step destructive confirmation for a recoverable run. Only the
  # card whose "Discard failed import" was clicked reveals the confirming
  # "Delete failed version" button, preventing an accidental discard.
  @impl true
  def handle_event("begin_discard", %{"run_id" => run_id}, socket) do
    case load_run_id(run_id) do
      nil ->
        {:noreply, socket}

      binary_id ->
        case find_recoverable_run(socket, binary_id) do
          %Run{} = run ->
            if discardable?(run) do
              socket = clear_previous_discard_confirmation(socket, run.id)

              confirming = %{run | confirming_discard: true}

              {:noreply,
               socket
               |> stream_insert(:import_recovery_runs, confirming, at: -1)
               |> assign(:pending_discard_run_id, run.id)
               |> assign(:recovery_announce, "Confirm discarding #{run.version_name}")}
            else
              {:noreply, socket}
            end

          nil ->
            {:noreply, socket}
        end
    end
  end

  # Cancel an in-progress discard confirmation (no state change).
  @impl true
  def handle_event("cancel_discard", _params, socket) do
    socket =
      case find_recoverable_run(socket, socket.assigns.pending_discard_run_id) do
        %Run{} = run ->
          socket
          |> stream_insert(:import_recovery_runs, %{run | confirming_discard: false}, at: -1)

        nil ->
          socket
      end

    {:noreply,
     socket
     |> assign(:pending_discard_run_id, nil)
     |> assign(:processing_discard, false)
     |> assign(:recovery_announce, nil)}
  end

  # Retry publication for a run in `publication_failed`. Re-reads organization-
  # scoped durable state; cross-org or wrong-state crafted events are rejected.
  @impl true
  def handle_event("publish_version", %{"run_id" => run_id}, socket) do
    organization_id = socket.assigns.current_organization.id

    case load_run_id(run_id) do
      nil ->
        {:noreply, socket}

      binary_id ->
        case ImportRuns.retry_publication(organization_id, binary_id) do
          {:ok, _run, _version} ->
            # Publication retry closes synchronously; enqueue the same durable
            # reload path used by runner broadcasts so the card is removed and
            # the processing state is cleared.
            send(self(), {:import_run_changed, binary_id})

            {:noreply,
             socket
             |> assign(:recovery_announce, "Publishing version")
             |> assign(:processing_publish, binary_id)}

          {:error, _reason} ->
            {:noreply, assign(socket, :processing_publish, nil)}
        end
    end
  end

  # Execute the discard after confirmation through the supervised cleanup
  # runner. Completion is applied from the runner's durable-state broadcast so
  # cleanup survives this LiveView disconnecting.
  @impl true
  def handle_event("delete_version", %{"run_id" => run_id}, socket) do
    organization_id = socket.assigns.current_organization.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}

    socket = assign(socket, :processing_discard, true)

    case load_run_id(run_id) do
      nil ->
        {:noreply,
         socket
         |> assign(:processing_discard, false)
         |> assign(:recovery_announce, "Could not claim the failed version for cleanup")}

      binary_id ->
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(binary_id))

        case Runner.start_cleanup(organization_id, binary_id, actor) do
          {:ok, _runner_pid} ->
            {:noreply,
             socket
             |> restream_recovery_run(organization_id, binary_id)
             |> assign(:processing_discard, binary_id)
             |> assign(:pending_discard_run_id, nil)
             |> assign(:recovery_announce, "Cleanup in progress")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:processing_discard, false)
             |> assign(:pending_discard_run_id, nil)
             |> assign(:recovery_announce, "Could not claim the failed version for cleanup")}
        end
    end
  end

  @impl true
  def handle_event("compute_diff", _params, socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :diff_files, fn %{path: path}, entry ->
        {:ok, %{filename: entry.client_name, content: File.read!(path)}}
      end)

    {:noreply, start_change_review(socket, uploaded_files)}
  end

  @impl true
  def handle_event("diff-filter", %{"filter" => filter}, socket) do
    case Map.fetch(@diff_filters, filter) do
      {:ok, filter_atom} ->
        {:noreply,
         socket
         |> assign(:diff_filter, filter_atom)
         |> refresh_change_review()}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("approve-decision", %{"id" => id}, socket) do
    {:noreply, update_change_decision(socket, id, :approved)}
  end

  @impl true
  def handle_event("reject-decision", %{"id" => id}, socket) do
    {:noreply, update_change_decision(socket, id, :rejected)}
  end

  @impl true
  def handle_event("approve-all", %{"action" => action}, socket) do
    case Map.fetch(@diff_actions, action) do
      {:ok, action_atom} ->
        socket =
          Enum.reduce(socket.assigns.decisions_by_id, socket, fn {id, decision}, acc ->
            if decision.action == action_atom and decision.status in [:pending, :rejected] do
              update_change_decision(acc, id, :approved)
            else
              acc
            end
          end)

        {:noreply, refresh_change_review(socket)}

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("apply-decisions", _params, socket) do
    {:noreply, request_change_apply(socket)}
  end

  @impl true
  def handle_event("cancel-diff-run", _params, socket), do: {:noreply, cancel_change_run(socket)}

  @impl true
  def handle_event("retry-diff-run", _params, socket), do: {:noreply, retry_change_run(socket)}

  @impl true
  def handle_event("reset-diff", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.diff_files.entries, socket, fn entry, acc ->
        cancel_upload(acc, :diff_files, entry.ref)
      end)

    {:noreply,
     socket
     |> assign(:change_run, nil)
     |> assign(:diff_step, :upload)
     |> assign(:diff_summary, empty_diff_summary())
     |> assign(:diff_filter, :all)
     |> assign(:diff_parse_failures, [])
     |> assign(:diff_blockers, [])
     |> assign(:diff_preview_count, 0)
     |> assign(:apply_results, [])
     |> assign(:decisions_by_id, %{})
     |> stream(:diff_decisions, [], reset: true)
     |> stream(:diff_preview_decisions, [], reset: true)}
  end

  @impl true
  def handle_info({:import_progress, progress}, socket) do
    {:noreply, assign(socket, :import_progress, progress)}
  end

  def handle_info({:import_phase, _phase}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:change_run_changed, run_id}, socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    socket =
      case ChangeRuns.get_for_version(organization_id, version_id, run_id) do
        %ChangeRun{} = run ->
          Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(run))
          socket |> assign(:change_run, run) |> refresh_change_review()

        nil ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:import_run_changed, run_id}, socket) do
    # A terminal or progress transition was broadcast by the supervised Runner
    # (or a peer LiveView) for this organization's run. Reload the durable run
    # and re-stream it; if it is no longer recoverable, drop it from the list
    # and, when the run we started just published its target, surface the
    # success result the old task-owned flow used to return directly.
    organization_id = socket.assigns.current_organization.id

    recoverable_runs = ImportRuns.list_recoverable(organization_id)
    run = Enum.find(recoverable_runs, &(&1.id == run_id))
    recovery_count = length(recoverable_runs)

    socket =
      reconcile_recovery_run(
        socket,
        organization_id,
        run_id,
        run,
        recovery_count,
        recoverable_runs == []
      )

    socket =
      if socket.assigns.processing_publish == run_id and
           (is_nil(run) or run.state != "publication_failed") do
        assign(socket, :processing_publish, nil)
      else
        socket
      end

    socket = settle_discard(socket, organization_id, run_id, run)

    {:noreply, socket}
  end

  defp settle_discard(
         %{assigns: %{processing_discard: run_id}} = socket,
         organization_id,
         run_id,
         run
       ) do
    changed_run =
      run ||
        from(r in Run,
          where: r.id == ^run_id and r.organization_id == ^organization_id
        )
        |> GtfsPlanner.Repo.one()

    case changed_run do
      %Run{state: "cleaned", version_name: removed_name} ->
        socket
        |> assign(:pending_discard_run_id, nil)
        |> assign(:processing_discard, false)
        |> assign(:recovery_announce, "Discarded #{removed_name}")
        |> assign(
          :form,
          to_form(%{"version_name" => removed_name}, as: :gtfs_import_form)
        )
        |> reset_uploads()
        |> push_event("focus_gtfs_import_files", %{})

      %Run{state: "cleanup_failed"} ->
        socket
        |> assign(:pending_discard_run_id, nil)
        |> assign(:processing_discard, false)

      _ ->
        socket
    end
  end

  defp settle_discard(socket, _organization_id, _run_id, _run), do: socket

  # When the run we started reaches `published`, the route-version we bound as
  # `:import_target` is now published. Render the success result with the
  # durable counts from the run's audit row so the import page announces it.
  defp success_for_published_target(socket, run_id) do
    target = socket.assigns[:import_target]

    if target do
      organization_id = socket.assigns.current_organization.id

      run =
        from(r in Run,
          where: r.id == ^run_id and r.organization_id == ^organization_id
        )
        |> GtfsPlanner.Repo.one()

      case Versions.get_gtfs_version_for_lifecycle(
             organization_id,
             target.id
           ) do
        %GtfsVersion{publication_status: "published"} = published ->
          counts = run_counts_to_result(run)

          result = %Result{
            counts: counts,
            unrecognized_files: [],
            topic: nil,
            archive_warnings: [],
            extensions: :not_present
          }

          socket
          |> assign(:import_result, {:ok, published, result})
          |> assign(:import_target, published)
          |> assign(:published_version, published)
          |> assign(:importing, false)
          |> assign(:import_progress, nil)

        _ ->
          socket
          |> assign(:importing, false)
          |> assign(:import_progress, nil)
      end
    else
      socket
    end
  end

  defp run_counts_to_result(nil), do: %{}

  defp run_counts_to_result(%Run{committed_counts: counts}) when is_map(counts) do
    Enum.reduce([:levels, :stops, :pathways], %{}, fn key, acc ->
      case fetch_committed_count(counts, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_committed_count(counts, key) do
    with :error <- Map.fetch(counts, key) do
      Map.fetch(counts, Atom.to_string(key))
    end
  end

  defp restream_recovery_run(socket, organization_id, run_id) do
    recoverable_runs = ImportRuns.list_recoverable(organization_id)

    socket =
      case Enum.find(recoverable_runs, &(&1.id == run_id)) do
        %Run{} = run -> stream_insert(socket, :import_recovery_runs, run, at: -1)
        nil -> socket
      end

    socket
    |> assign(:recovery_count, length(recoverable_runs))
    |> assign(:recovery_empty, recoverable_runs == [])
  end

  defp reconcile_recovery_run(socket, _organization_id, _run_id, %Run{} = run, count, empty?) do
    socket
    |> stream_insert(:import_recovery_runs, run, at: -1)
    |> assign(:recovery_count, count)
    |> assign(:recovery_empty, empty?)
    |> assign(:recovery_announce, recovery_announce_text(run))
  end

  defp reconcile_recovery_run(socket, organization_id, run_id, nil, count, empty?) do
    gone_run =
      from(r in Run,
        where: r.id == ^run_id and r.organization_id == ^organization_id
      )
      |> GtfsPlanner.Repo.one()

    socket = maybe_delete_recovery_run(socket, gone_run)
    socket = assign_recovery_count(socket, count, empty?)

    if gone_run, do: success_for_published_target(socket, run_id), else: socket
  end

  defp maybe_delete_recovery_run(socket, %Run{} = run) do
    stream_delete(socket, :import_recovery_runs, run)
  end

  defp maybe_delete_recovery_run(socket, nil), do: socket

  defp assign_recovery_count(socket, count, empty?) do
    socket
    |> assign(:recovery_count, count)
    |> assign(:recovery_empty, empty?)
  end

  defp start_change_review(socket, uploaded_files) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}
    run_id = Ecto.UUID.generate()

    with {:ok, manifest} <-
           ChangeArtifactStorage.stage(organization_id, version_id, run_id, uploaded_files),
         {:ok, %ChangeRun{} = run} <-
           ChangeRuns.create_pending_compute(organization_id, version_id, actor, manifest, run_id) do
      if run.id != run_id, do: ChangeArtifactStorage.remove(organization_id, version_id, run_id)
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(run))
      _ = ChangeRunner.start_compute(organization_id, run.id)

      socket
      |> assign(:change_run, run)
      |> assign(:diff_filter, :all)
      |> refresh_change_review()
    else
      {:error, reason} ->
        socket
        |> assign(:diff_blockers, [%{reason: reason}])
        |> assign(:diff_step, :upload)
    end
  end

  defp refresh_change_review(socket) do
    case socket.assigns[:change_run] do
      %ChangeRun{} = run ->
        organization_id = socket.assigns.current_organization.id

        run =
          ChangeRuns.get_for_version(
            organization_id,
            socket.assigns.current_gtfs_version.id,
            run.id
          ) || run

        decisions = ChangeRuns.list_decisions(organization_id, run.id)
        applicable = Enum.reject(decisions, &(&1.status == :preview))
        previews = Enum.filter(decisions, &(&1.status == :preview))
        filtered = filter_decisions(applicable, socket.assigns.diff_filter)

        socket
        |> assign(:change_run, run)
        |> assign(:diff_step, diff_step(run))
        |> assign(:diff_summary, run_summary(run))
        |> assign(:diff_blockers, run_blockers(run))
        |> assign(:diff_parse_failures, run_diagnostics(run))
        |> assign(:diff_preview_count, length(previews))
        |> assign(:decisions_by_id, Map.new(applicable, &{&1.decision_id, &1}))
        |> stream(:diff_decisions, filtered, reset: true)
        |> stream(:diff_preview_decisions, previews, reset: true)

      _ ->
        socket
    end
  end

  defp update_change_decision(socket, decision_id, status) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, _decision} <-
           ChangeRuns.set_decision_status(
             socket.assigns.current_organization.id,
             run.id,
             decision_id,
             status
           ) do
      refresh_change_review(socket)
    else
      _ -> socket
    end
  end

  defp request_change_apply(socket) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, pending} <-
           ChangeRuns.request_apply(socket.assigns.current_organization.id, run.id) do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(pending))
      _ = ChangeRunner.start_apply(socket.assigns.current_organization.id, pending.id)
      socket |> assign(:change_run, pending) |> refresh_change_review()
    else
      _ -> socket
    end
  end

  defp cancel_change_run(socket) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, changed} <-
           ChangeRuns.request_cancel(socket.assigns.current_organization.id, run.id) do
      socket |> assign(:change_run, changed) |> refresh_change_review()
    else
      _ -> socket
    end
  end

  defp retry_change_run(socket) do
    with %ChangeRun{} = run <- socket.assigns[:change_run],
         {:ok, retry} <- ChangeRuns.retry(socket.assigns.current_organization.id, run.id) do
      Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ChangeRuns.topic(retry))

      case retry.state do
        :pending_apply -> _ = ChangeRunner.start_apply(retry.organization_id, retry.id)
        :pending_compute -> _ = ChangeRunner.start_compute(retry.organization_id, retry.id)
        _ -> :ok
      end

      socket |> assign(:change_run, retry) |> refresh_change_review()
    else
      _ -> socket
    end
  end

  defp filter_decisions(decisions, :all), do: decisions
  defp filter_decisions(decisions, action), do: Enum.filter(decisions, &(&1.action == action))

  defp diff_step(nil), do: :upload
  defp diff_step(%ChangeRun{state: :review}), do: :review
  defp diff_step(%ChangeRun{state: :completed}), do: :done
  defp diff_step(%ChangeRun{}), do: :processing

  defp run_summary(nil), do: empty_diff_summary()

  defp run_summary(%ChangeRun{summary: summary}) when is_map(summary) do
    Enum.reduce([:add, :modify, :remove, :conflict], empty_diff_summary(), fn key, acc ->
      Map.put(acc, key, Map.get(summary, Atom.to_string(key), Map.get(summary, key, 0)))
    end)
  end

  defp run_blockers(%ChangeRun{state: :review}), do: []
  defp run_blockers(%ChangeRun{state: :failed, failure_code: code}), do: [%{reason: code}]
  defp run_blockers(_), do: []

  defp run_diagnostics(%ChangeRun{diagnostics: diagnostics}) when is_list(diagnostics),
    do: diagnostics

  defp run_diagnostics(_), do: []

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
        <div class="max-w-2xl bg-base-100 rounded-lg p-6">
          <.form
            for={@form}
            id="gtfs-import-form"
            class="space-y-6"
            phx-change="validate"
            phx-submit="import"
            phx-hook=".ImportErrorFocus"
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
              <.input
                id="gtfs-import-version-name"
                field={@form[:version_name]}
                label="Version name"
                placeholder="e.g., Spring 2025 Schedule"
                phx-blur="version_name_blur"
              />
            </div>

            <.upload_field
              id="gtfs-import-upload"
              upload={@uploads.gtfs_files}
              label="GTFS files"
              help="GTFS .txt or .csv files, or one .zip archive. Up to 50 files, 200 MB each."
              action_label="Select GTFS files or drag and drop"
              cancel_event="cancel-upload"
              error_formatter={&upload_error_to_string/1}
              state={upload_field_state(@uploads.gtfs_files)}
            />

            <%= if @unrecognized_upload_files != [] do %>
              <.callout id="gtfs-import-unrecognized" kind="warning" title="Unrecognized files">
                These files will be skipped: {Enum.join(@unrecognized_upload_files, ", ")}.
              </.callout>
            <% end %>

            <.button
              id="gtfs-import-submit"
              type="submit"
              disabled={@uploads.gtfs_files.entries == [] || @importing}
            >
              <%= if @importing do %>
                <span class="loading loading-spinner loading-sm"></span> Importing…
              <% else %>
                Import feed
              <% end %>
            </.button>
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
                  <.callout kind="success" title="Import successful">
                    Imported into new version “{published.name}”: {counts.levels} levels, {counts.stops} stops, {counts.pathways} pathways.
                    <span :if={unrecognized != []}>
                      Unrecognized files skipped: {Enum.join(unrecognized, ", ")}.
                    </span>
                    <.link
                      id="gtfs-import-view-version"
                      navigate={~p"/gtfs/#{published.id}/routes"}
                      class="mt-2 inline-block text-primary underline"
                    >
                      View version
                    </.link>
                  </.callout>
                <% {:error, target, {:publication_failed, _reason}} -> %>
                  <.callout kind="error" title="Publication failed">
                    Version “{target_name(target)}” finished importing but could not be published. It remains unavailable for reconciliation.
                  </.callout>
                <% {:error, nil, :no_files_selected} -> %>
                  <.callout kind="error" title="Import failed">
                    Select at least one file to import.
                  </.callout>
                <% {:error, target, reason} -> %>
                  <.callout kind="error" title="Import failed">
                    Version “{target_name(target)}” was not published. {format_import_error(reason)}
                  </.callout>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Reconnect-safe recovery region: streamed, stable DOM ids, one ARIA
           live region announces each state change once (AC-15/16/17/18, INV-3). --%>
      <div class="mt-8" aria-live="polite" id="gtfs-import-recovery-announce">
        <%= if @recovery_announce do %>
          <span class="sr-only">{@recovery_announce}</span>
        <% end %>
      </div>

      <div class="mt-8">
        <div class="bg-base-100 rounded-lg p-6">
          <div class="flex flex-col gap-3">
            <h2 class="text-xl font-semibold">Import recovery</h2>
            <p class="text-sm text-base-content/70">
              Failed, partial, interrupted, or cleanup-pending imports for this organization. Each can be discarded and re-uploaded.
            </p>
          </div>

          <div
            id="import-recovery-runs"
            phx-update="stream"
            class="mt-4 flex flex-col gap-3"
          >
            <div
              :for={{dom_id, run} <- @streams.import_recovery_runs}
              id={dom_id}
              class={[
                "rounded-lg border p-4",
                recovery_card_border(run)
              ]}
            >
              <.icon name={recovery_card_icon(run)} class="w-5 h-5 mb-2" />
              <div class="flex flex-col gap-1">
                <p class="text-sm font-semibold">{run.version_name}</p>
                <.status_badge
                  status={recovery_badge_status(run)}
                  label={recovery_card_state_label(run)}
                />
                <%= if run.committed_counts != %{} and run.state == "partial" do %>
                  <p class="text-xs text-base-content/70 mt-1">
                    {recovery_counts_summary(run.committed_counts)}
                  </p>
                <% end %>
                <%= if run.state == "partial" and run.failed_file do %>
                  <p class="text-xs text-base-content/70">
                    Last file: {run.failed_file}{if run.failed_row, do: " (row #{run.failed_row})"}
                  </p>
                <% end %>
                <%= if run.state == "interrupted" do %>
                  <p class="text-xs text-base-content/70 mt-1">
                    Durable counts are uncertain after an interrupted import.
                  </p>
                <% end %>
              </div>

              <div class="mt-3 flex flex-wrap gap-2">
                <%= if run.state == "publication_failed" do %>
                  <.button
                    id={"publish-version-#{run.id}"}
                    phx-click="publish_version"
                    phx-value-run_id={run.id}
                    class="btn btn-primary btn-sm"
                    disabled={@processing_publish == run.id}
                  >
                    Publish version
                  </.button>
                <% end %>

                <%= if discardable?(run) do %>
                  <%= if run.confirming_discard do %>
                    <span class="text-xs text-base-content/80 mr-1 self-center">
                      Discard “{run.version_name}” and delete its failed version?
                    </span>
                    <.button
                      id={"delete-version-#{run.id}"}
                      phx-click="delete_version"
                      phx-value-run_id={run.id}
                      class="btn btn-error btn-sm"
                      disabled={@processing_discard}
                    >
                      Delete failed version
                    </.button>
                    <.button
                      id={"cancel-discard-#{run.id}"}
                      phx-click="cancel_discard"
                      class="btn btn-ghost btn-sm"
                      disabled={@processing_discard}
                    >
                      Cancel
                    </.button>
                  <% else %>
                    <.button
                      id={"discard-#{run.id}"}
                      phx-click="begin_discard"
                      phx-value-run_id={run.id}
                      class="btn btn-outline btn-sm"
                    >
                      Discard failed import
                    </.button>
                  <% end %>
                <% end %>

                <%= if run.state in ~w(pending running cleaning) do %>
                  <span class="text-xs text-base-content/50 self-center">
                    {if run.state == "cleaning", do: "Cleanup in progress…", else: "In progress…"}
                  </span>
                <% end %>
              </div>
            </div>
          </div>

          <%= if @recovery_empty do %>
            <.empty_state
              id="import-recovery-empty"
              class="py-6"
              title="No recoverable imports"
            >
              No recoverable imports for this organization.
            </.empty_state>
          <% end %>
        </div>
      </div>

      <div class="mt-8">
        <div class="bg-base-100 rounded-lg p-6">
          <div class="flex flex-col gap-2">
            <h2 class="text-xl font-semibold">Update station data</h2>
            <p class="text-sm text-base-content/70">
              Upload `levels.txt`, `stops.txt`, and/or `pathways.txt` to review and apply station data diffs.
            </p>
            <p id="diff-destination" class="text-xs text-base-content/60">
              Reviewed changes apply to version “{version_display_name(@current_gtfs_version)}”.
            </p>
          </div>

          <.form
            for={@diff_form}
            id="diff-upload-form"
            class="mt-6 space-y-4"
            phx-change="validate_diff"
            phx-submit="compute_diff"
          >
            <.upload_field
              id="diff-upload"
              upload={@uploads.diff_files}
              label="Station data files"
              help="levels.txt, stops.txt, pathways.txt, or one .zip archive. Up to 3 files, 50 MB each."
              action_label="Select station data files or drag and drop"
              cancel_event="cancel-diff-upload"
              error_formatter={&diff_upload_error_to_string/1}
              state={upload_field_state(@uploads.diff_files)}
            />

            <div class="flex flex-wrap gap-2">
              <.button
                id="diff-compute-btn"
                type="submit"
                disabled={@uploads.diff_files.entries == [] || @diff_step != :upload}
              >
                Compute diff
              </.button>

              <%= if @diff_step == :review do %>
                <.button
                  id="diff-reset-btn"
                  variant="secondary"
                  type="button"
                  phx-click="reset-diff"
                >
                  Reset
                </.button>
              <% end %>
            </div>
          </.form>

          <%= if @diff_blockers != [] do %>
            <.callout
              kind="error"
              id="diff-blockers"
              title="Cannot compute review"
              role="alert"
              aria-live="assertive"
            >
              <p class="text-sm">
                One or more uploaded files could not be processed. Choose corrected files to continue.
              </p>
              <ul class="mt-1 space-y-1 text-xs list-disc list-inside">
                <li :for={error <- @diff_blockers}>{format_parse_error(error)}</li>
              </ul>
              <button
                type="button"
                id="diff-choose-corrected-files"
                class="btn btn-primary btn-sm mt-3"
                phx-click="reset-diff"
              >
                Choose corrected files
              </button>
            </.callout>
          <% end %>

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

              <%= if @diff_parse_failures != [] do %>
                <.callout id="diff-degraded-region" kind="error" title="Incomplete file" role="status">
                  <p class="text-sm">Some rows are preview-only until you upload corrected files.</p>
                  <ul class="mt-2 list-inside list-disc text-xs">
                    <li :for={diagnostic <- @diff_parse_failures}>{format_diagnostic(diagnostic)}</li>
                  </ul>
                  <button
                    id="diff-degraded-choose-corrected-files"
                    type="button"
                    class="btn btn-primary btn-sm mt-3"
                    phx-click="reset-diff"
                  >
                    Choose corrected files
                  </button>
                </.callout>
              <% end %>

              <div
                :if={@diff_preview_count != 0}
                id="diff-preview-region"
                class="border border-base-300 bg-base-200 p-4"
              >
                <h3 class="text-sm font-semibold">Read-only preview</h3>
                <div
                  id="diff-preview-decisions"
                  phx-update="stream"
                  class="mt-3 divide-y divide-base-300"
                >
                  <TransitPresentation.version_diff_row
                    :for={{dom_id, decision} <- @streams.diff_preview_decisions}
                    id={dom_id}
                    action={decision.action}
                    entity_label={entity_type_label(decision.entity_type)}
                    natural_key={decision.natural_key}
                    status={decision.status}
                    changes={decision_changes(decision)}
                    dependency_keys={decision.dependency_keys}
                  />
                </div>
              </div>

              <div
                id="diff-decisions"
                phx-update="stream"
                class="divide-y divide-base-300 border-y border-base-300"
              >
                <p
                  id="diff-decisions-empty"
                  class="hidden py-6 text-center text-sm text-base-content/70 only:block"
                >
                  No matching decisions for this filter.
                </p>
                <TransitPresentation.version_diff_row
                  :for={{dom_id, decision} <- @streams.diff_decisions}
                  id={dom_id}
                  action={decision.action}
                  entity_label={entity_type_label(decision.entity_type)}
                  natural_key={decision.natural_key}
                  status={decision.status}
                  changes={decision_changes(decision)}
                  dependency_keys={decision.dependency_keys}
                  edited?={decision.user_edited}
                >
                  <:actions :if={decision.status in [:pending, :approved, :rejected]}>
                    <button
                      type="button"
                      class="btn btn-success btn-sm"
                      phx-click="approve-decision"
                      phx-value-id={decision.decision_id}
                    >
                      Approve
                    </button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-sm"
                      phx-click="reject-decision"
                      phx-value-id={decision.decision_id}
                    >
                      Reject
                    </button>
                  </:actions>
                </TransitPresentation.version_diff_row>
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

          <%= if @diff_step == :processing do %>
            <div
              id="diff-run-state"
              data-state={@change_run.state}
              class="mt-6 border-l-4 border-info bg-info/5 p-4"
              role="status"
            >
              <p class="font-medium">{diff_state_label(@change_run)}</p>
              <p class="mt-1 text-sm text-base-content/70">
                This review is durable. You can safely reconnect while it runs.
              </p>
              <button
                :if={@change_run.state in [:computing, :applying, :pending_compute, :pending_apply]}
                id="diff-cancel-btn"
                type="button"
                class="btn btn-ghost btn-sm mt-3"
                phx-click="cancel-diff-run"
              >
                Cancel review
              </button>
              <button
                :if={@change_run.state in [:partial, :failed, :interrupted, :cancelled, :expired]}
                id="diff-retry-btn"
                type="button"
                class="btn btn-primary btn-sm mt-3"
                phx-click="retry-diff-run"
              >
                Retry
              </button>
            </div>
          <% end %>

          <%= if @diff_step == :done do %>
            <div class="mt-8 border-t border-base-300 pt-6 space-y-4">
              <div class="rounded-lg border border-base-300 p-4 bg-base-200">
                <p class="text-sm font-semibold">
                  Applied {Map.get(@change_run.summary, "applied", 0)} decisions successfully, {Map.get(
                    @change_run.summary,
                    "failed",
                    0
                  )} failed.
                </p>
              </div>

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

    <%!-- Move focus to the first invalid field when validation produces an error,
         using a colocated hook (no embedded script) so keyboard and screen-reader
         users land on the fixable control. --%>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ImportErrorFocus">
      export default {
        mounted() {
          this.handleEvent("focus_first_error", ({selector}) => {
            const el = this.el.querySelector(selector)
            if (el) el.focus()
          })
          this.handleEvent("focus_gtfs_import_files", () => {
            const el = this.el.querySelector("#gtfs-import-upload-input input")
            if (el) el.focus()
          })
        }
      }
    </script>
    """
  end

  # Create exactly one staging target + pending run, subscribe to its stable
  # topic, consume the uploads into memory, and hand the run + lease token to a
  # supervised Runner that claims and executes the import. The route/current
  # version is never a write destination, and no task reference is owned by the
  # socket: the Runner is durable and survives disconnect (AC-6).
  defp create_and_start_import(socket, _form_data, version_name) do
    organization_id = socket.assigns.current_organization.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}

    case ImportRuns.create_pending_target(organization_id, actor, %{name: version_name}) do
      {:error, changeset} ->
        # Pre-consumption changeset error (blank/duplicate name): return to the
        # form, preserve every upload entry, focus/announce the error,
        # and start no runner. No lifecycle row was created.
        socket =
          socket
          |> assign(:version_name_touched, true)
          |> assign(
            :form,
            to_form(%{"version_name" => version_name},
              as: :gtfs_import_form,
              errors: changeset_errors(changeset)
            )
          )
          |> assign(:import_result, nil)

        socket = push_event(socket, "focus_first_error", %{selector: "#gtfs-import-version-name"})

        {:noreply, socket}

      {:ok, %{run: run, version: target}} ->
        # Subscribe to the stable topic BEFORE starting the runner so no
        # broadcast is missed.
        Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, ImportRuns.topic(run.id))

        case consume_import_files(socket) do
          {:ok, uploaded_files} ->
            # Hand the pending run + lease token to the supervised runner. The
            # runner re-claims in init and executes publication through
            # ImportRuns, broadcasting {:import_run_changed, run.id} on closure.
            Runner.start_import(organization_id, run.id, run.lease_token, uploaded_files)

            {:noreply,
             socket
             |> assign(:import_target, target)
             |> assign(:importing, true)
             |> assign(:import_result, nil)
             |> assign(:published_version, nil)
             |> assign(:import_progress, nil)}

          {:error, reason} ->
            # Post-create consumption/read error: fail the exact pending target,
            # start no runner, and render target-specific feedback.
            failed = fail_target_best_effort(run, target)

            {:noreply,
             socket
             |> assign(:import_target, failed)
             |> assign(:import_result, {:error, failed, {:upload_consumption_failed, reason}})
             |> assign(:importing, false)
             |> assign(:import_progress, nil)}
        end
    end
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
  defp fail_target_best_effort(%Run{} = run, %GtfsVersion{} = target) do
    case ImportRuns.fail_pending_target(
           target.organization_id,
           run.id,
           run.lease_token,
           :upload_consumption_failed
         ) do
      {:ok, _run, failed} -> failed
      {:error, _reason} -> target
    end
  end

  # Recovery runs that can be discarded (whole-target cleanup) rather than
  # published. `cleaning` is in-progress and excluded; `published`/`cleaned` are
  # terminal and never recoverable.
  @discardable_states ~w(failed partial interrupted publication_failed cleanup_failed)

  defp discardable?(%Run{state: state}), do: state in @discardable_states

  defp clear_previous_discard_confirmation(
         %{assigns: %{pending_discard_run_id: previous_run_id}} = socket,
         current_run_id
       )
       when is_binary(previous_run_id) and previous_run_id != current_run_id do
    case find_recoverable_run(socket, previous_run_id) do
      %Run{} = previous ->
        stream_insert(
          socket,
          :import_recovery_runs,
          %{previous | confirming_discard: false},
          at: -1
        )

      nil ->
        socket
    end
  end

  defp clear_previous_discard_confirmation(socket, _current_run_id), do: socket

  # Event `run_id` values arrive as string UUIDs, matching the `:binary_id`
  # primary key's Elixir-side string representation. Validate and return the
  # string unchanged so downstream ImportRuns queries and stream lookups match.
  defp load_run_id(run_id) when is_binary(run_id) do
    case Ecto.UUID.cast(run_id) do
      {:ok, _} -> run_id
      :error -> nil
    end
  end

  defp find_recoverable_run(socket, run_id) do
    organization_id = socket.assigns.current_organization.id

    ImportRuns.list_recoverable(organization_id)
    |> Enum.find(&(&1.id == run_id))
  end

  # Reset every staged GTFS upload entry so a discarded target can be re-uploaded
  # cleanly under the same (prefilled) version name.
  defp reset_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.gtfs_files.entries, socket, fn entry, acc ->
      cancel_upload(acc, :gtfs_files, entry.ref)
    end)
  end

  # One short announce string per state so the single ARIA live region (AC-18)
  # reports a meaningful change exactly once per transition.
  defp recovery_announce_text(%Run{state: "pending"}), do: "Import pending"
  defp recovery_announce_text(%Run{state: "running"}), do: "Import running"
  defp recovery_announce_text(%Run{state: "partial"}), do: "Import partially committed"
  defp recovery_announce_text(%Run{state: "failed"}), do: "Import failed"
  defp recovery_announce_text(%Run{state: "interrupted"}), do: "Import interrupted"
  defp recovery_announce_text(%Run{state: "publication_failed"}), do: "Publication failed"
  defp recovery_announce_text(%Run{state: "cleaning"}), do: "Cleanup in progress"
  defp recovery_announce_text(%Run{state: "cleanup_failed"}), do: "Cleanup failed"
  defp recovery_announce_text(%Run{}), do: nil

  @count_labels %{
    levels: "levels",
    stops: "stops",
    pathways: "pathways",
    extensions_stop_coordinates: "stop coordinates",
    extensions_stop_levels: "stop levels",
    extensions_route_flags: "route flags",
    extensions_images: "images"
  }

  defp recovery_counts_summary(counts) when is_map(counts) do
    counts
    |> Enum.reject(fn {_k, v} -> v == 0 or v == nil end)
    |> Enum.sort_by(
      fn {k, _v} ->
        order = [
          :levels,
          :stops,
          :pathways,
          :extensions_stop_coordinates,
          :extensions_stop_levels,
          :extensions_route_flags,
          :extensions_images
        ]

        Enum.find_index(order, &(&1 == String.to_existing_atom(to_string(k)))) || 99
      end,
      fn a, b -> a <= b end
    )
    |> Enum.map(fn {k, v} ->
      label = Map.get(@count_labels, String.to_existing_atom(to_string(k)), to_string(k))
      "#{v} #{label}"
    end)
    |> Enum.join(", ")
  rescue
    ArgumentError -> ""
  end

  defp recovery_card_border(%Run{state: state})
       when state in ~w(failed interrupted cleanup_failed),
       do: "border-error/40 bg-error/5"

  defp recovery_card_border(%Run{state: "partial"}), do: "border-warning/40 bg-warning/5"

  defp recovery_card_border(%Run{state: "publication_failed"}),
    do: "border-warning/40 bg-warning/5"

  defp recovery_card_border(%Run{state: "cleaning"}), do: "border-info/40 bg-info/5"
  defp recovery_card_border(%Run{}), do: "border-base-300 bg-base-200"

  defp recovery_card_icon(%Run{state: state}) when state in ~w(failed interrupted cleanup_failed),
    do: "hero-exclamation-circle"

  defp recovery_card_icon(%Run{state: "partial"}), do: "hero-exclamation-triangle"
  defp recovery_card_icon(%Run{state: "publication_failed"}), do: "hero-exclamation-triangle"
  defp recovery_card_icon(%Run{state: "cleaning"}), do: "hero-arrow-path"
  defp recovery_card_icon(%Run{}), do: "hero-clock"

  defp recovery_badge_status(%Run{state: state}) when state in ~w(pending running cleaning),
    do: :running

  defp recovery_badge_status(%Run{state: "partial"}), do: :warning

  defp recovery_badge_status(%Run{state: state})
       when state in ~w(failed interrupted publication_failed cleanup_failed),
       do: :failed

  defp recovery_badge_status(%Run{}), do: :info

  defp recovery_card_state_label(%Run{state: "pending"}), do: "Import pending — preparing upload."

  defp recovery_card_state_label(%Run{state: "running"}),
    do: "Import running — writing to a new version."

  defp recovery_card_state_label(%Run{state: "partial"}),
    do: "Partially committed — some rows were written before a failure."

  defp recovery_card_state_label(%Run{state: "failed"}),
    do: "Failed — no rows were committed. Safe to discard and re-upload."

  defp recovery_card_state_label(%Run{state: "interrupted"}),
    do: "Interrupted — the import process was lost."

  defp recovery_card_state_label(%Run{state: "publication_failed"}),
    do: "Publication failed — files imported but not published."

  defp recovery_card_state_label(%Run{state: "cleaning"}), do: "Cleanup in progress."

  defp recovery_card_state_label(%Run{state: "cleanup_failed"}),
    do: "Cleanup failed — can be retried by discarding."

  defp recovery_card_state_label(%Run{}), do: "Recoverable import."

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

  defp decision_changes(%ChangeDecision{changed_fields: fields}) when is_list(fields) do
    Enum.map(fields, fn field ->
      %{
        label: Map.get(field, "field", "Changed field"),
        before: Map.get(field, "before"),
        after: Map.get(field, "after")
      }
    end)
  end

  defp decision_changes(_), do: []

  defp format_diagnostic(%{} = diagnostic) do
    code = Map.get(diagnostic, "code", Map.get(diagnostic, :code, "parse_error"))
    detail = Map.get(diagnostic, "detail", Map.get(diagnostic, :detail, ""))
    "#{String.replace(to_string(code), "_", " ")}: #{detail}"
  end

  defp format_diagnostic(diagnostic), do: to_string(diagnostic)

  defp diff_state_label(%ChangeRun{state: :pending_compute}), do: "Staging review files"
  defp diff_state_label(%ChangeRun{state: :computing}), do: "Computing durable review"
  defp diff_state_label(%ChangeRun{state: :pending_apply}), do: "Preparing approved changes"
  defp diff_state_label(%ChangeRun{state: :applying}), do: "Applying approved changes"
  defp diff_state_label(%ChangeRun{state: :partial}), do: "Some changes need attention"
  defp diff_state_label(%ChangeRun{state: :failed}), do: "Review failed"
  defp diff_state_label(%ChangeRun{state: :interrupted}), do: "Review interrupted"
  defp diff_state_label(%ChangeRun{state: :cancelled}), do: "Review cancelled"
  defp diff_state_label(%ChangeRun{state: :expired}), do: "Review expired"
  defp diff_state_label(%ChangeRun{}), do: "Review updated"

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
              file: basenames,
              row: nil,
              reason: :duplicate_entity_file
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

  defp normalize_archive_warnings(warnings) when is_list(warnings) do
    Enum.map(warnings, fn warning ->
      reason =
        case warning.reason do
          :unzip_failed -> :archive_unreadable
          :archive_too_large -> :archive_too_large
          :nested_archive -> :nested_archive
          _unknown -> :archive_unreadable
        end

      %ParseError{
        file: warning.filename,
        reason: reason,
        metadata: %{}
      }
    end)
  end

  defp normalize_duplicate_blocker(duplicate) do
    %ParseError{
      file: Map.get(duplicate, :file),
      reason: :duplicate_entity_file,
      metadata: %{}
    }
  end

  defp build_stop_validation_map(db_stops, stops_result) do
    db_ids = Enum.map(db_stops, & &1.stop_id)

    uploaded_ids =
      case stops_result do
        {:ok, parsed_entity} ->
          records_by_key = ParsedEntity.records_by_key(parsed_entity)
          Map.values(records_by_key) |> Enum.map(&Map.get(&1, :stop_id))

        {:error, %ParseFailure{preview_records_by_key: preview_records_by_key}} ->
          Map.values(preview_records_by_key) |> Enum.map(&Map.get(&1, :stop_id))

        :not_uploaded ->
          []
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

  defp format_parse_error(%ParseError{file: nil, reason: reason}), do: parse_reason_label(reason)

  defp format_parse_error(%ParseError{file: file, row: nil, reason: reason})
       when is_binary(file) do
    "#{file}: #{parse_reason_label(reason)}"
  end

  defp format_parse_error(%ParseError{file: file, row: row, reason: reason})
       when is_binary(file) and is_integer(row) do
    "#{file} row #{row}: #{parse_reason_label(reason)}"
  end

  defp format_parse_error(%ParseError{reason: reason}), do: parse_reason_label(reason)

  defp parse_reason_label(:empty_content), do: "File is empty"
  defp parse_reason_label(:invalid_utf8), do: "File uses an unsupported text encoding"
  defp parse_reason_label(:blank_header), do: "Column name is blank"
  defp parse_reason_label(:duplicate_header), do: "Column name is duplicated"
  defp parse_reason_label(:wrong_field_count), do: "Row has the wrong number of values"
  defp parse_reason_label(:unterminated_quote), do: "Quoted value is not closed"
  defp parse_reason_label(:malformed_quote), do: "Quoted value is malformed"

  defp parse_reason_label(:forbidden_control_character),
    do: "Row contains an invalid line break or tab"

  defp parse_reason_label(:archive_unreadable), do: "Archive could not be read"
  defp parse_reason_label(:archive_too_large), do: "Archive exceeds size limits"
  defp parse_reason_label(:nested_archive), do: "Archive contains a nested archive"
  defp parse_reason_label(:duplicate_entity_file), do: "Duplicate entity file"
  defp parse_reason_label(:missing_natural_key_header), do: "Missing required column"
  defp parse_reason_label(:duplicate_natural_key), do: "Duplicate key"
  defp parse_reason_label(:blank_natural_key), do: "Missing key value"
  defp parse_reason_label(:semantic_row), do: "Invalid row value"
  defp parse_reason_label(:unexpected_parser_failure), do: "Unexpected parse failure"

  defp format_failure_summary(%ParseFailure{
         entity_type: entity_type,
         total_error_count: total_error_count,
         source_row_count: source_row_count
       }) do
    "#{entity_type_label(entity_type)} file could not be fully parsed: #{total_error_count} " <>
      "#{pluralize(total_error_count, "error")} across #{source_row_count} rows."
  end

  defp entity_type_label(:level), do: "Levels"
  defp entity_type_label(:stop), do: "Stops"
  defp entity_type_label(:pathway), do: "Pathways"

  defp pluralize(1, singular), do: singular
  defp pluralize(_count, singular), do: "#{singular}s"

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

  defp upload_field_state(upload) do
    if upload.errors != [] or Enum.any?(upload.entries, &(upload_errors(upload, &1) != [])) do
      :failed
    else
      :idle
    end
  end

  defp diff_upload_error_to_string(:too_large), do: "File exceeds 50MB limit"
  defp diff_upload_error_to_string(:too_many_files), do: "Maximum 3 files allowed"
  defp diff_upload_error_to_string(:not_accepted), do: "Only .txt, .csv, and .zip files accepted"
  defp diff_upload_error_to_string(:external_client_failure), do: "Upload failed"
  defp diff_upload_error_to_string({:error, reason}), do: reason
  defp diff_upload_error_to_string(error) when is_binary(error), do: error
  defp diff_upload_error_to_string(_), do: "Upload error"
end

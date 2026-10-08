defmodule GtfsPlannerWeb.Gtfs.FeedPublicationComponents do
  @moduledoc """
  The Export page's static publication review, on the application design system.

  Publishing is a two-step consent. `publication_section/1` is the row-bound
  drawer host that answers a Files row's Publish action: the permanent public
  address, the emitted profile, the check report and the archive inventory behind
  one primary Publish action. The component carries no state and runs no query:
  `ExportLive` owns the bound run, the events and the command calls, and every
  value shown is one the server put in its own preview.

  The components carry no state and run no queries: `ExportLive` owns the events,
  the command calls and the data. Nothing here decides what may be published - the
  server command refuses an ineligible file, and every value shown is one the server
  put in its own preview.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [drawer_footer: 1, drawer_scroll: 1, message: 1]

  alias GtfsPlanner.Gtfs.DisplayClock

  @doc """
  The row-bound publication drawer host. `ExportLive` passes its own `publication`
  map in; nothing here queries or decides what may be published.
  """
  attr :publication, :map, required: true

  def publication_section(assigns) do
    run = assigns.publication.run

    assigns =
      assigns
      |> assign(:run, run)
      |> assign(:drawer_open?, not is_nil(run) and drawer_open?(assigns.publication))
      |> assign(:drawer_title, drawer_title(run))
      |> assign(:return_focus_id, if(run, do: "export-file-#{run.id}-menu-button", else: nil))

    ~H"""
    <div :if={@publication.available?} id="feed-publish">
      <.drawer
        id="publish-drawer"
        chrome="planner"
        open={@drawer_open?}
        title={@drawer_title}
        initial_focus={:heading}
        return_focus_id={@return_focus_id}
        on_close="close_publication_review"
      >
        <:lede :if={@run}>
          {@run.artifact_filename || "File"} · {DisplayClock.format_datetime(@run.inserted_at)}
        </:lede>

        <.form
          for={@publication.consent_form}
          id="feed-publish-consent"
          phx-change="consent_publication"
          phx-submit="confirm_publication"
          class="flex min-h-0 flex-1 flex-col"
        >
          <.drawer_scroll>
            <span id="publish-reviewed-run" data-run-id={@run && @run.id}></span>

            <div :if={@publication.pending_id} id="feed-publish-checking" class="grid gap-3">
              <p class="text-sm font-semibold text-strong">Checking this file…</p>
              <progress class="progress progress-info w-full" aria-label="Check progress" />
            </div>

            <.message
              :if={@publication.notice}
              id="feed-publish-refusal"
              kind={@publication.notice.kind}
              title={@publication.notice.title}
            >
              {@publication.notice.detail}
            </.message>

            <.mismatch_notice :if={@publication.preview} preview={@publication.preview} />
            <.review_body :if={@publication.preview} publication={@publication} />

            <.input
              :if={@publication.preview && @publication.preview.errors_count > 0}
              field={@publication.consent_form[:confirm_errors]}
              type="checkbox"
              id="feed-publish-confirm-errors"
              label={consent_label(@publication.preview.errors_count)}
            />
          </.drawer_scroll>

          <.drawer_footer>
            <.button
              id="feed-publish-close"
              type="button"
              variant="quiet"
              class="min-h-11"
              phx-click="close_publication_review"
            >
              Close review
            </.button>
            <.button id="feed-publish-confirm" class="min-h-11">
              <.icon name="hero-globe-alt" class="size-4" /> Publish feed
            </.button>
          </.drawer_footer>
        </.form>
      </.drawer>
    </div>
    """
  end

  defp drawer_open?(publication) do
    not is_nil(publication.preview) or not is_nil(publication.pending_id) or
      not is_nil(publication.notice)
  end

  defp drawer_title(%{export_type: :pathways}), do: "Publish station pathways"
  defp drawer_title(_run), do: "Publish full feed"

  attr :preview, :map, required: true

  defp mismatch_notice(assigns) do
    ~H"""
    <div :if={@preview.notices != []}>
      <.message
        id="feed-publish-mismatch"
        kind="warning"
        title="Some rider information is not in this file"
      >
        These alerts name routes, stops or trips this file does not carry, so riders will not
        see them. Publishing still goes ahead, and the alerts stay as they are.
        <ul class="mt-2 grid gap-1">
          <li :for={notice <- @preview.notices}>{notice_detail(notice)}</li>
        </ul>
      </.message>
    </div>
    """
  end

  attr :publication, :map, required: true

  defp review_body(assigns) do
    assigns = assign(assigns, :preview, assigns.publication.preview)

    ~H"""
    <div id="feed-publish-review" class="grid gap-4">
      <dl class="grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]">
        <dt class="text-muted">Public address</dt>
        <dd id="feed-publish-url" class="break-all text-strong">{@preview.destination_url}</dd>

        <dt class="text-muted">Replaces</dt>
        <dd id="feed-publish-replaces" class="text-strong">{replaces_label(@publication)}</dd>

        <dt class="text-muted">Check of this file</dt>
        <dd id="feed-publish-report" class="text-strong">
          {report_label(@preview)}
          <.link
            :if={@preview.report_id}
            id="feed-publish-report-link"
            navigate={~p"/gtfs/#{@publication.run.gtfs_version_id}/validation/#{@preview.report_id}"}
            class="ml-2 font-semibold text-action hover:underline"
          >
            View report
          </.link>
        </dd>
      </dl>

      <div>
        <h4 id="feed-publish-inventory-title" class="text-[13px] font-semibold text-strong">
          In the file ({length(@preview.inventory)} entries)
        </h4>
        <ul
          id="feed-publish-inventory"
          class="mt-2 grid max-h-56 gap-1 overflow-y-auto font-mono text-[13px] leading-relaxed text-default"
        >
          <li :for={entry <- @preview.inventory}>{entry}</li>
        </ul>
      </div>

      <p class="text-[13px] leading-relaxed text-muted">
        Trip planners pick up the new file the next time they read this address. Google reads it at least once a week.
      </p>
    </div>
    """
  end

  defp replaces_label(%{current_address: %{filename: filename} = address})
       when is_binary(filename) do
    "Replaces #{filename}" <> served_since_text(address.served_at)
  end

  defp replaces_label(_publication), do: "Nothing. This is the first publish."

  defp served_since_text(nil), do: ""

  defp served_since_text(%DateTime{} = at),
    do: " (served since #{DisplayClock.format_datetime(at)})"

  defp served_since_text(_at), do: ""

  defp report_label(%{report_id: report_id, errors_count: errors, warnings_count: warnings}) do
    "#{errors} errors, #{warnings} warnings · check #{String.slice(to_string(report_id), 0, 8)}"
  end

  defp consent_label(1), do: "I have reviewed the 1 error in this check report."

  defp consent_label(count), do: "I have reviewed the #{count} errors in this check report."

  defp notice_detail(%{alert_name: name, reason: reason, ids: ids}) do
    "#{name}: #{reason_label(reason)} #{Enum.map_join(ids, ", ", &id_label/1)}"
  end

  defp reason_label(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp id_label({route_id, stop_id}), do: "#{route_id} at #{stop_id}"

  defp id_label(id), do: to_string(id)
end

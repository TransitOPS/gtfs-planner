defmodule GtfsPlannerWeb.Gtfs.FeedPublicationComponents do
  @moduledoc """
  The Export page's static publication review, on the application design system.

  Publishing is a two-step consent. `publish_action/1` is the opener shown beside
  Download once the file is ready, and `publication_section/1` is the review that
  answers it: the permanent public URL, the emitted profile, the reviewed hash, the
  archive inventory and the check report behind one primary Publish action. The same
  section carries the channel's durable state, so a queued, current or failed
  publication is still visible after the operator navigates away and back.

  The components carry no state and run no queries: `ExportLive` owns the events,
  the command calls and the data. Nothing here decides what may be published - the
  server command refuses an ineligible file, and every value shown is one the server
  put in its own preview.
  """

  use GtfsPlannerWeb, :html

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  @profile_labels %{static: "GTFS feed", flex: "GTFS-Flex feed", pathways: "GTFS pathways files"}

  @doc """
  The Publish opener, shown beside Download when the file is ready to review.

  `busy?` covers the states where the operator already has a review to answer: one
  is open, or the check bound to this file is still running.
  """
  attr :busy?, :boolean, default: false

  def publish_action(assigns) do
    ~H"""
    <.button
      :if={not @busy?}
      id="feed-publish-open"
      variant="secondary"
      class="min-h-11"
      phx-click="preview_publication"
    >
      <.icon name="hero-globe-alt" class="size-4" /> Publish feed
    </.button>
    """
  end

  @doc """
  The publication status band and, while one is open, the review that answers it.

  `publication` is `ExportLive`'s own map: `:available?` says the installation and
  the selected export type can publish at all, `:status` is the durable channel
  state, `:notice` is a refused action's message, and `:preview` is the server's
  review of the selected file.
  """
  attr :publication, :map, required: true

  def publication_section(assigns) do
    ~H"""
    <div :if={@publication.available?} id="feed-publish" class="mt-5 grid gap-4">
      <div
        id="feed-publish-status"
        aria-live="polite"
        class="rounded-card border border-subtle bg-canvas px-4 py-3.5"
      >
        <.message
          id="feed-publish-status-message"
          kind={@publication.status.kind}
          title={@publication.status.title}
        >
          {@publication.status.detail}
        </.message>
      </div>

      <div id="feed-publish-notices" aria-live="polite" class="grid gap-3 empty:hidden">
        <.message
          :if={@publication.notice}
          id="feed-publish-refusal"
          kind={@publication.notice.kind}
          title={@publication.notice.title}
        >
          {@publication.notice.detail}
        </.message>

        <.mismatch_notice :if={@publication.preview} preview={@publication.preview} />
      </div>

      <.review :if={@publication.preview} publication={@publication} />
    </div>
    """
  end

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

  defp review(assigns) do
    assigns = assign(assigns, :preview, assigns.publication.preview)

    ~H"""
    <section
      id="feed-publish-review"
      aria-labelledby="feed-publish-review-title"
      class="rounded-card border border-subtle bg-canvas px-5 py-4"
    >
      <h3
        id="feed-publish-review-title"
        tabindex="-1"
        class="text-base font-bold leading-snug text-strong"
      >
        Review before publishing
      </h3>
      <p class="mt-1 max-w-[64ch] text-sm leading-relaxed text-default">
        This is the file and the check report the public feed will be served from. Anyone with
        the link can download it.
      </p>

      <dl class="mt-4 grid gap-x-6 gap-y-2 text-sm sm:grid-cols-[10rem_minmax(0,1fr)]">
        <dt class="text-muted">Public URL</dt>
        <dd id="feed-publish-url" class="break-all text-strong">
          {@preview.destination_url}
        </dd>

        <dt class="text-muted">Profile</dt>
        <dd id="feed-publish-profile" class="text-strong">
          {profile_label(@preview.profile)}
        </dd>

        <dt class="text-muted">Reviewed file</dt>
        <dd id="feed-publish-hash" class="text-strong">
          <span class="font-mono text-[13px]">{short_hash(@preview.artifact_sha256)}</span>
          <span class="text-muted">{" · " <> size_label(@preview.size_bytes)}</span>
        </dd>

        <dt class="text-muted">Check report</dt>
        <dd id="feed-publish-report" class="text-strong">
          {report_label(@preview)}
        </dd>
      </dl>

      <div class="mt-5">
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

      <.form
        for={@publication.consent_form}
        id="feed-publish-consent"
        phx-change="consent_publication"
        phx-submit="confirm_publication"
        class="mt-5 grid gap-3"
      >
        <.input
          :if={@preview.errors_count > 0}
          field={@publication.consent_form[:confirm_errors]}
          type="checkbox"
          id="feed-publish-confirm-errors"
          label={consent_label(@preview.errors_count)}
        />

        <div class="flex flex-wrap items-center gap-2">
          <.button id="feed-publish-confirm" class="min-h-11">
            <.icon name="hero-globe-alt" class="size-4" /> Publish feed
          </.button>
        </div>
      </.form>

      <div class="mt-3">
        <.button
          id="feed-publish-close"
          variant="quiet"
          class="min-h-11"
          phx-click="close_publication_review"
        >
          Close review
        </.button>
      </div>
    </section>
    """
  end

  defp profile_label(profile), do: Map.get(@profile_labels, profile, to_string(profile))

  defp short_hash(hash) when is_binary(hash) and byte_size(hash) > 16,
    do: String.slice(hash, 0, 16) <> "…"

  defp short_hash(hash), do: to_string(hash)

  defp size_label(nil), do: "size not recorded"

  defp size_label(bytes) when is_integer(bytes) do
    "#{bytes} bytes"
  end

  defp size_label(_bytes), do: "size not recorded"

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

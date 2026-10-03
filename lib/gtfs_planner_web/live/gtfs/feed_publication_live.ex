defmodule GtfsPlannerWeb.Gtfs.FeedPublicationLive do
  @moduledoc """
  The organization's published feeds: the permanent public URL of each channel,
  what that URL serves now, and when the application last confirmed it.

  This surface belongs to the organization, not to a version, so it carries no
  version in its route and needs none to work: the URLs and the served state are
  the organization's own, and they do not change when a reader switches the
  version they are editing. That is also why the reported source is the receipt
  the queue froze on the active attempt rather than the reader's selection.

  Every read is local. The page never asks a provider or an object store whether
  a feed is healthy - that would be a remote status probe from a page that must
  work while publishing is turned off - so it reports the application's own rows:
  each channel's state, its manifest's served instant, the last refresh it
  observed, and the receipt of the export it froze.

  A disabled installation still reports what it already published. Disabling
  removes the configured base URL, so the page hides the links and says so while
  keeping the local history readable, and an organization with nothing published
  yet gets an explanation instead of three empty rows.

  Alerts are removed from the realtime feed asynchronously, so an alert whose
  deletion is still outstanding is reported here from
  `Alerts.Publication.pending_removals/1`, which reads the tombstone rather than
  the alert list.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.PlannerComponents, only: [back_link: 1, message: 1]

  alias GtfsPlanner.Alerts.Publication, as: AlertPublication
  alias GtfsPlanner.FeedPublishing
  alias GtfsPlanner.FeedPublishing.Attempt
  alias GtfsPlanner.FeedPublishing.Config
  alias GtfsPlanner.FeedPublishing.Publication

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access_in_organization}

  # The static channels this page reports, in the order their files are listed
  # everywhere else. The realtime Alerts feed is a channel the organization owns
  # too, but its payload is not one of the three permanent download addresses, so
  # it is reported here through the removals it still owes rather than as a URL.
  @channels [:full, :flex, :pathways]

  @channel_labels %{full: "Full feed", flex: "Flex feed", pathways: "Pathways feed"}

  # Labels for the labelled selector, so a client value can only ever be looked up.
  @channel_labels_by_key %{
    "full" => "Full feed",
    "flex" => "Flex feed",
    "pathways" => "Pathways feed"
  }

  # How the frozen receipt names the export the served bytes came from.
  @source_kinds %{
    "full" => "Full feed export",
    "flex" => "Flex feed export",
    "pathways" => "Pathways export",
    "operations" => "Operations export"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Published feeds")
     |> assign(:unavailable?, false)
     |> assign(:disabled?, false)
     |> assign(:rows, [])
     |> assign(:pending_removals, [])
     |> assign(:notice, nil)
     |> assign(:last_refresh_at, nil)}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, socket) do
    {:noreply, load_status(socket)}
  end

  # A copy is a browser capability, so the hook reports what happened and the page
  # announces it: a reader who cannot see the button's own feedback still hears
  # whether the URL is on the clipboard.
  @impl Phoenix.LiveView
  def handle_event("feed_url_copied", %{"channel" => channel}, socket)
      when is_binary(channel) do
    case Map.fetch(@channel_labels_by_key, channel) do
      {:ok, label} -> {:noreply, assign(socket, :notice, label <> " URL copied.")}
      :error -> {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("feed_url_copy_failed", %{"channel" => channel}, socket)
      when is_binary(channel) do
    case Map.fetch(@channel_labels_by_key, channel) do
      {:ok, label} ->
        {:noreply,
         assign(socket, :notice, label <> " URL was not copied. Select it and copy it yourself.")}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

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
      <div id="published-feeds">
        <.back_link :if={@back_path} id="published-feeds-back" navigate={@back_path}>
          Settings
        </.back_link>

        <.header class="pb-8">
          Published feeds
          <:subtitle>
            The permanent public addresses for this organization, and what each one serves now.
          </:subtitle>
        </.header>

        <.message
          :if={@unavailable?}
          id="published-feeds-unavailable"
          kind="info"
          title="No organization selected"
        >
          Published feeds belong to an organization. Choose one to see its addresses.
        </.message>

        <div :if={not @unavailable?} class="grid gap-6">
          <.message
            :if={@disabled?}
            id="feed-status-disabled"
            kind="info"
            title="Publishing is turned off"
          >
            Nothing new is being served, and the addresses below are not reachable while it stays
            off. What this organization already published is kept exactly as it was.
          </.message>

          <.message
            :if={@pending_removals != []}
            id="feed-pending-removals"
            kind="warning"
            title={pending_title(length(@pending_removals))}
          >
            The delete is saved and the rider feed has not confirmed the removal yet, so these
            alerts are still served. Nothing else changes until it is.
            <ul class="mt-2 grid gap-1">
              <li :for={removal <- @pending_removals}>{removal_detail(removal)}</li>
            </ul>
          </.message>

          <ul
            :if={@rows != []}
            id="feed-status-list"
            class="min-w-0 divide-y divide-subtle overflow-hidden rounded-card border border-subtle bg-white"
          >
            <.feed_row :for={row <- @rows} row={row} />
          </ul>

          <.message
            :if={@rows == []}
            id="feed-status-empty"
            kind="neutral"
            title="Nothing published yet"
          >
            When someone publishes an export from the Export feed page, its permanent address
            appears here.
          </.message>

          <div :if={@rows != []} class="min-w-0">
            <p id="feed-refresh-age" class="text-[13px] text-muted">
              {refresh_age(@last_refresh_at)}
            </p>
            <div
              id="feed-copy-notice"
              aria-live="polite"
              class="mt-2 text-[13px] font-semibold text-strong empty:hidden"
            >
              {@notice}
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".FeedUrlCopy">
      export default {
        mounted() {
          this.el.addEventListener("click", () => this.copy())
        },
        async copy() {
          try {
            await navigator.clipboard.writeText(this.el.dataset.feedUrl)
            this.pushEvent("feed_url_copied", { channel: this.el.dataset.feedChannel })
          } catch (_error) {
            this.pushEvent("feed_url_copy_failed", { channel: this.el.dataset.feedChannel })
          }
        },
      }
    </script>
    """
  end

  attr :row, :map, required: true

  defp feed_row(assigns) do
    ~H"""
    <li id={"feed-status-" <> Atom.to_string(@row.channel)} class="grid min-w-0 gap-3 px-5 py-4">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <h2 class="text-base font-bold leading-snug text-strong">{@row.label}</h2>
        <span class={[
          "rounded-control px-2 py-0.5 text-[13px] font-semibold",
          @row.state.tone
        ]}>
          {@row.state.label}
        </span>
      </div>

      <div :if={@row.public_url} class="grid min-w-0 gap-2 sm:grid-cols-[minmax(0,1fr)_auto]">
        <a
          id={"feed-url-" <> Atom.to_string(@row.channel)}
          href={@row.public_url}
          rel="noreferrer"
          class="min-w-0 break-all font-mono text-[13px] leading-relaxed text-strong underline decoration-subtle underline-offset-2 hover:decoration-strong focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-focus"
        >
          {@row.public_url}
        </a>
        <.button
          id={"feed-copy-" <> Atom.to_string(@row.channel)}
          variant="secondary"
          size="sm"
          class="min-h-11 justify-self-start"
          phx-hook=".FeedUrlCopy"
          data-feed-url={@row.public_url}
          data-feed-channel={Atom.to_string(@row.channel)}
          aria-label={"Copy the " <> @row.label <> " URL"}
        >
          <.icon name="hero-clipboard" class="size-4" /> Copy
        </.button>
      </div>

      <dl class="grid gap-x-6 gap-y-1 text-[13px] sm:grid-cols-[10rem_minmax(0,1fr)]">
        <dt class="text-muted">Served from</dt>
        <dd id={"feed-source-" <> Atom.to_string(@row.channel)} class="min-w-0 text-default">
          {@row.source || "Not recorded for this publication."}
        </dd>

        <dt class="text-muted">Served since</dt>
        <dd id={"feed-served-at-" <> Atom.to_string(@row.channel)} class="text-default">
          {@row.served_at || "Not served yet"}
        </dd>
      </dl>

      <p
        :if={@row.detail}
        id={"feed-detail-" <> Atom.to_string(@row.channel)}
        class="max-w-[64ch] text-[13px] text-error-fg"
      >
        {@row.detail}
      </p>

      <p
        :if={@row.note}
        id={"feed-note-" <> Atom.to_string(@row.channel)}
        class="max-w-[64ch] text-[13px] text-default"
      >
        {@row.note}
      </p>

      <p
        :if={is_nil(@row.public_url)}
        id={"feed-status-note-" <> Atom.to_string(@row.channel)}
        class="max-w-[64ch] text-[13px] text-muted"
      >
        This address is not reachable while publishing is turned off.
      </p>
    </li>
    """
  end

  # -- Loading -------------------------------------------------------------

  defp load_status(socket) do
    socket =
      socket
      |> assign(:back_path, back_path(socket))
      |> assign(:disabled?, Config.current() == :disabled)

    case socket.assigns[:current_organization] do
      %{id: organization_id} ->
        publications = scoped_status(socket, organization_id)

        rows = publications |> Enum.filter(&(&1.channel in @channels)) |> ordered_rows()

        socket
        |> assign(:unavailable?, false)
        |> assign(:rows, rows)
        |> assign(:pending_removals, pending_removals(organization_id))
        |> assign(:last_refresh_at, last_refresh(publications))

      _organization ->
        assign(socket,
          unavailable?: true,
          rows: [],
          pending_removals: [],
          last_refresh_at: nil
        )
    end
  end

  defp scoped_status(socket, organization_id) do
    case FeedPublishing.status(%{
           organization_id: organization_id,
           actor_id: socket.assigns.current_user.id
         }) do
      {:ok, publications} -> publications
      {:error, _reason} -> []
    end
  end

  # The tombstone, not the alert list: an alert whose removal the realtime feed has
  # not confirmed is reported even though it is gone from every list the reader sees.
  defp pending_removals(organization_id) do
    organization_id |> AlertPublication.pending_removals() |> Enum.sort_by(& &1.alert_id)
  end

  # `status/1` orders by channel name, which would list Flex before Full. The
  # page lists the channels in the order their files appear everywhere else.
  defp ordered_rows(publications) do
    publications
    |> Enum.sort_by(&Enum.find_index(@channels, fn channel -> channel == &1.channel end))
    |> Enum.map(&row/1)
  end

  defp row(%Publication{} = publication) do
    %{
      channel: publication.channel,
      label: Map.fetch!(@channel_labels, publication.channel),
      state: state(publication),
      public_url: FeedPublishing.public_url(publication.namespace, publication.channel),
      source: source_receipt(publication.active_attempt),
      served_at: served_at(publication.manifest_last_modified),
      detail: failure_detail(publication),
      note: receipt_note(publication)
    }
  end

  # The receipt the queue froze on the active attempt. It is the export that made
  # the served bytes, so it does not move when the reader switches versions.
  defp source_receipt(%Attempt{private_snapshot: %{"source" => source}}) when is_map(source) do
    kind = source |> Map.get("export_type") |> source_kind()
    filename = Map.get(source, "filename")

    [kind, filename] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  defp source_receipt(_attempt), do: nil

  defp source_kind(nil), do: nil
  defp source_kind(type), do: Map.get(@source_kinds, type)

  defp state(%Publication{status: :current}),
    do: %{label: "Published", tone: "bg-soft text-cyan-700"}

  defp state(%Publication{status: status})
       when status in [:pending, :staging, :switching, :reconciling],
       do: %{label: "Publishing", tone: "bg-soft text-cyan-800"}

  defp state(%Publication{status: status}) when status in [:failed, :blocked],
    do: %{label: "Publication failed", tone: "bg-error-bg text-error-fg"}

  defp state(_publication),
    do: %{label: "Not published yet", tone: "border border-subtle bg-white text-muted"}

  defp failure_detail(%Publication{status: status, last_error: error})
       when status in [:failed, :blocked],
       do: error || "The publisher could not serve this feed. It keeps trying."

  defp failure_detail(_publication), do: nil

  # A served file is not a failure. This only says the schedule it was exported from could
  # not become the active schedule.
  defp receipt_note(%Publication{status: :current, last_error: error}) do
    if error == Publication.active_source_unavailable() do
      "The active schedule did not change. The version this feed was exported from is no longer available."
    end
  end

  defp receipt_note(_publication), do: nil

  defp served_at(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp served_at(_at), do: nil

  defp last_refresh(publications) do
    publications
    |> Enum.map(& &1.last_refresh_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp refresh_age(nil), do: "No refresh recorded yet for this organization."

  defp refresh_age(%DateTime{} = at) do
    "Last checked #{age(at)}."
  end

  defp age(at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      seconds when seconds < 60 -> "just now"
      seconds when seconds < 3_600 -> "#{div(seconds, 60)} minutes ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3_600)} hours ago"
      seconds -> "#{div(seconds, 86_400)} days ago"
    end
  end

  defp pending_title(1), do: "1 alert is still being removed"

  defp pending_title(count), do: "#{count} alerts are still being removed"

  defp removal_detail(%{header: header, withdrawn_at: %DateTime{} = at}) do
    name = if is_binary(header) and header != "", do: header, else: "Untitled alert"
    name <> " · deleted " <> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  end

  defp removal_detail(_removal), do: "An alert being removed from the rider feed"

  # Settings is version-scoped, so the way back only exists when the reader has a
  # version; the published feeds themselves are readable without one.
  defp back_path(%{assigns: %{current_gtfs_version: %{id: version_id}}})
       when is_binary(version_id),
       do: "/gtfs/#{version_id}/settings"

  defp back_path(_socket), do: nil
end

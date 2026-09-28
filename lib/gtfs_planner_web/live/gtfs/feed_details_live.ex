defmodule GtfsPlannerWeb.Gtfs.FeedDetailsLive do
  @moduledoc """
  Reads one version's feed information.

  Feed details describe the whole dataset a data consumer receives, so the page
  shows the publisher, the validity dates, the feed release and the technical
  contact in three sections, with "Not set" for every value the version does not
  carry yet (AC-1). A version with no `feed_info` row shows the first-use empty
  state instead, and mounting it writes nothing: the row appears only when the
  editor saves one (AC-2).

  The read goes through `GtfsPlanner.Gtfs.FeedSettings.get_feed_info/2`, which is
  scoped to the organization and version (CR-1). This LiveView never calls the
  unscoped `Gtfs.get_feed_info/1`, and it holds no write path of its own.

  The drawer that creates and edits the row belongs to the steps that follow;
  this page renders the header, the summary, the aside notes and the empty state
  only, so the prototype's Edit and Set actions are absent rather than inert.

  Access follows the other Settings pages through the `:gtfs_routes` session, and
  version switching keeps the section: only a published version of the current
  organization navigates, and the target is always `/settings/feed-details` of
  the selected version.
  """

  use GtfsPlannerWeb, :live_view

  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.LanguageCodes
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @summary_subtitle "Publisher information for this version—not the contact details riders use."
  @empty_subtitle "Tell journey planners who publishes this dataset and when its information is valid."
  @not_set "Not set"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Feed details")
     |> assign(:feed_info, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :feed_info, load_feed_info(socket))}
  end

  # A selection of this page's own version is nothing to do: the switcher hook
  # returns before it sends the event for the version it already shows, and
  # `gtfs_version_loaded/2` below ignores the same case, so both events agree that
  # only another published version of this organization navigates.
  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if version_id != to_string(socket.assigns.current_gtfs_version.id) &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply,
       socket
       |> push_event("gtfs_version_selected", %{version_id: version_id})
       |> push_navigate(to: feed_details_path(version_id))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("gtfs_version_loaded", %{"version_id" => version_id}, socket) do
    current_version_id = to_string(socket.assigns.current_gtfs_version.id)

    if version_id && version_id != current_version_id &&
         Versions.published_gtfs_version_for_org?(
           socket.assigns.current_organization.id,
           version_id
         ) do
      {:noreply, push_navigate(socket, to: feed_details_path(version_id))}
    else
      {:noreply, socket}
    end
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
      <:sub_header>
        <.settings_nav gtfs_version_id={@current_gtfs_version.id} active_tab={:feed_details} />
      </:sub_header>

      <.header>
        Feed details
        <:subtitle>{subtitle(@feed_info)}</:subtitle>
      </.header>

      <.feed_summary
        :if={@feed_info}
        feed_info={@feed_info}
        gtfs_version_id={@current_gtfs_version.id}
      />

      <.empty_state
        :if={is_nil(@feed_info)}
        id="feed-details-empty"
        title="Introduce your feed"
        class="mt-6"
      >
        Add the publisher, website, and language. Dates and technical contacts help others use your
        data with confidence.
      </.empty_state>
    </Layouts.app>
    """
  end

  # The three summary sections follow the prototype's order, and the aside stacks
  # below them until the summary has room for a 250px column beside it.
  attr :feed_info, :any, required: true
  attr :gtfs_version_id, :any, required: true

  defp feed_summary(assigns) do
    ~H"""
    <div id="feed-details-summary" class="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1fr)_250px]">
      <div class="rounded-box border border-base-300">
        <section id="feed-details-publisher" class="border-b border-base-300 p-6">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="text-base font-semibold text-base-content">Publisher</h2>
            <.status_badge status={:active} label="Details set" />
          </div>

          <.summary_list>
            <:row label="Name">{value(@feed_info.feed_publisher_name)}</:row>
            <:row label="Website">{value(@feed_info.feed_publisher_url)}</:row>
            <:row label="Feed language">{language(@feed_info.feed_lang)}</:row>
            <:row label="Default language">{language(@feed_info.default_lang)}</:row>
          </.summary_list>
        </section>

        <section id="feed-details-validity" class="border-b border-base-300 p-6">
          <h2 class="text-base font-semibold text-base-content">Validity and version</h2>

          <.summary_list>
            <:row label="Valid from">{date(@feed_info.feed_start_date)}</:row>
            <:row label="Valid through">{date(@feed_info.feed_end_date)}</:row>
            <:row label="Feed version">{value(@feed_info.feed_version)}</:row>
          </.summary_list>
        </section>

        <section id="feed-details-contact" class="p-6">
          <h2 class="text-base font-semibold text-base-content">Technical contact</h2>

          <.summary_list>
            <:row label="Email">{value(@feed_info.feed_contact_email)}</:row>
            <:row label="Website">{value(@feed_info.feed_contact_url)}</:row>
          </.summary_list>
        </section>
      </div>

      <aside class="text-sm text-base-content/70">
        <h2 class="text-base font-semibold text-base-content">One feed, one publisher</h2>
        <p class="mt-3">
          A regional partnership can publish a dataset containing several agencies. These details describe the whole dataset.
        </p>

        <h2 class="mt-6 text-base font-semibold text-base-content">For data consumers</h2>
        <p class="mt-3">
          Technical contacts receive questions about data quality. Rider contacts belong to each agency.
        </p>

        <.link
          id="feed-details-manage-agencies"
          navigate={agencies_path(@gtfs_version_id)}
          class="mt-6 inline-flex min-h-11 items-center font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-2"
        >
          Manage agencies <span aria-hidden="true" class="ml-2">→</span>
        </.link>

        <p class="mt-6 border-t border-base-300 pt-6">
          These details are included when this version is exported. Saving does not publish the feed.
        </p>
      </aside>
    </div>
    """
  end

  attr :rest, :global

  slot :row, required: true do
    attr :label, :string, required: true
  end

  defp summary_list(assigns) do
    ~H"""
    <dl
      class="mt-4 grid grid-cols-1 gap-y-1 text-sm sm:grid-cols-[10rem_minmax(0,1fr)] sm:gap-x-6 sm:gap-y-4"
      {@rest}
    >
      <%= for row <- @row do %>
        <dt class="text-base-content/70">{row.label}</dt>
        <dd class="mb-3 break-words sm:mb-0">{render_slot(row)}</dd>
      <% end %>
    </dl>
    """
  end

  defp load_feed_info(socket) do
    FeedSettings.get_feed_info(
      socket.assigns.current_organization.id,
      socket.assigns.current_gtfs_version.id
    )
  end

  defp subtitle(nil), do: @empty_subtitle
  defp subtitle(_feed_info), do: @summary_subtitle

  defp value(nil), do: @not_set

  defp value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> @not_set
      trimmed -> trimmed
    end
  end

  defp language(code) do
    case LanguageCodes.label(code) do
      nil -> @not_set
      label -> label
    end
  end

  defp date(nil), do: @not_set
  defp date(%Date{} = date), do: Calendar.strftime(date, "%b %-d, %Y")

  defp feed_details_path(version_id), do: "/gtfs/#{version_id}/settings/feed-details"
  defp agencies_path(version_id), do: "/gtfs/#{version_id}/settings/agencies"
end

defmodule GtfsPlannerWeb.DashboardLive do
  @moduledoc """
  The logged-in homepage at `/`.

  The page picks exactly one state from the organization context the
  `AssignOrganization` hook assigns on mount: the system administrator, no
  organization, organization unavailable, no published version, no task
  access, organization administrator without an editing role, or a working
  page for an editor — the GTFS Planner's Next step or Pathways Studio's
  station board, by the organization's product.

  Every state renders inside `SharedComponents.home_page/1` and carries its own
  root id, so the state is testable and the page has exactly one `h1`. The
  access states' small reads (organization count, administrator emails, member
  count) happen synchronously in `mount` through `home_source/0`; the planner
  page loads its three regions asynchronously once the client is connected —
  `:status` for the lede, attention, areas and first-use facts, `:resume` for
  the user's continue-where-you-left-off list, and `:check` for the check and
  share facts. Each region renders its own skeleton while loading and
  `region_error/1` when it fails, and `retry` reloads only the region it names
  (AC-29, CR-7). This module obtains data only through `home_source/0` and
  `ProductSurfaces`, and owns no message callback of its own — the
  version-rename hook owns the only one (INV-4).
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Home.AccessComponents
  import GtfsPlannerWeb.Home.PlannerComponents, only: [attention_list: 1, first_use: 1]

  import GtfsPlannerWeb.Home.SharedComponents,
    only: [
      areas_strip: 1,
      check_and_share: 1,
      check_skeleton: 1,
      home_head: 1,
      home_page: 1,
      people_row: 1,
      region_error: 1,
      resume_card: 1,
      resume_list: 1,
      resume_skeleton: 1,
      share_card: 1
    ]

  alias GtfsPlannerWeb.ProductSurfaces
  alias Phoenix.LiveView.AsyncResult

  @editor_role "pathways_studio_editor"
  @admin_role "pathways_studio_admin"

  # The retry event accepts only these region names; an unknown value is
  # ignored and never becomes an atom (CR-7). The Pathways regions join this
  # map with that page.
  @retry_regions %{"status" => :status, "resume" => :resume, "check" => :check}

  @impl true
  def mount(_params, _session, socket) do
    state = dashboard_state(socket.assigns)

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:dashboard_state, state)
     |> load_state_data(state)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_path={@current_path}
      user_roles={@user_roles}
      current_organization={@current_organization}
      current_gtfs_version={@current_gtfs_version}
      available_versions={@available_versions}
    >
      <.home_page>
        {render_dashboard_state(@dashboard_state, assigns)}
      </.home_page>
    </Layouts.app>
    """
  end

  defp dashboard_state(%{organization_context_status: :system_administrator}),
    do: :system_administrator

  defp dashboard_state(%{organization_context_status: :missing}), do: :missing

  defp dashboard_state(%{organization_context_status: :unavailable}), do: :unavailable

  defp dashboard_state(%{organization_context_status: :available, current_gtfs_version: nil}),
    do: :no_version

  defp dashboard_state(
         %{
           organization_context_status: :available,
           current_organization: %{},
           current_gtfs_version: %{},
           user_roles: roles
         } = assigns
       ) do
    cond do
      @editor_role in roles -> working_state(assigns.current_organization)
      @admin_role in roles -> :admin_only
      true -> :no_task
    end
  end

  defp working_state(organization) do
    case ProductSurfaces.brand(organization) do
      :planner -> :planner
      :pathways -> :pathways
    end
  end

  # The organization count, the administrator emails and the member count are
  # the access states' whole data need, so they load with mount instead of a
  # region. The working pages load their regions where they are rendered.
  defp load_state_data(socket, :system_administrator) do
    assign(socket, :organization_count, home_source().organization_count())
  end

  defp load_state_data(%{assigns: %{current_organization: organization}} = socket, state)
       when state in [:no_version, :no_task] do
    assign(socket, :organization_admins, home_source().organization_admins(organization.id))
  end

  defp load_state_data(%{assigns: %{current_organization: organization}} = socket, :admin_only) do
    assign(socket, :member_count, home_source().member_count(organization.id))
  end

  defp load_state_data(socket, :planner), do: load_planner_regions(socket)

  defp load_state_data(socket, _state), do: socket

  # The planner page's three regions. `:status` and `:check` are plain
  # `assign_async` regions; `:resume` uses `start_async` because its rows render
  # through a stream, which an `assign_async` result cannot feed (CR-4). All of
  # them only start their read once the client is connected.
  defp load_planner_regions(socket) do
    socket
    |> load_planner_status()
    |> load_planner_resume()
    |> load_planner_check()
  end

  defp load_planner_status(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    assign_async(socket, :status, fn ->
      {:ok, %{status: home_source().planner_status(organization_id, gtfs_version_id)}}
    end)
  end

  defp load_planner_resume(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:resume, AsyncResult.loading())
    |> assign(:resume_scope, :own)
    |> assign(:resume_featured, nil)
    |> start_async(:resume, fn ->
      home_source().resume(organization_id, gtfs_version_id, user_id)
    end)
  end

  defp load_planner_check(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    assign_async(socket, :check, fn ->
      {:ok, %{check: home_source().check_and_share(organization_id, gtfs_version_id, :planner)}}
    end)
  end

  @impl true
  def handle_event("retry", %{"region" => region}, socket) do
    case @retry_regions[region] do
      :status -> {:noreply, load_planner_status(socket)}
      :resume -> {:noreply, load_planner_resume(socket)}
      :check -> {:noreply, load_planner_check(socket)}
      nil -> {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:resume, {:ok, %{scope: scope, items: items}}, socket) do
    {featured, rows} = resume_rows(scope, items)

    {:noreply,
     socket
     |> assign(:resume, AsyncResult.ok(socket.assigns.resume, true))
     |> assign(:resume_scope, scope)
     |> assign(:resume_featured, featured)
     |> stream(:resume_rows, rows, reset: true, dom_id: & &1.row_id)}
  end

  def handle_async(:resume, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, :resume, AsyncResult.failed(socket.assigns.resume, {:exit, reason}))}
  end

  # Resolved per call so the homepage read boundary can be substituted in tests
  # without recompiling this module. Production always uses the context.
  defp home_source do
    Application.get_env(:gtfs_planner, :home_source, GtfsPlanner.Home)
  end

  defp render_dashboard_state(:system_administrator, assigns) do
    ~H"""
    <.sysadmin organization_count={@organization_count} />
    """
  end

  defp render_dashboard_state(:missing, assigns) do
    ~H"""
    <.no_org state={:missing} />
    """
  end

  defp render_dashboard_state(:unavailable, assigns) do
    ~H"""
    <.no_org state={:unavailable} />
    """
  end

  defp render_dashboard_state(:no_version, assigns) do
    ~H"""
    <.no_version organization={@current_organization} admins={@organization_admins} />
    """
  end

  defp render_dashboard_state(:no_task, assigns) do
    ~H"""
    <.no_task organization={@current_organization} admins={@organization_admins} />
    """
  end

  defp render_dashboard_state(:admin_only, assigns) do
    ~H"""
    <.admin_only
      organization={@current_organization}
      product={ProductSurfaces.brand(@current_organization)}
      member_count={@member_count}
    />
    """
  end

  # The GTFS Planner's Next step page (AC-8–AC-19). The head's lede, the
  # attention list, the first-use decision and the areas counts all come from
  # the `:status` region; the editor-work grid holds the resume and check
  # regions; the People row is the organization administrator's only job on
  # this page (AC-7). A first-use version replaces the attention, resume, check
  # and areas blocks with the first-use panel (AC-12).
  defp render_dashboard_state(:planner, assigns) do
    assigns =
      assign(assigns,
        lede: planner_lede(assigns.status, assigns.current_gtfs_version),
        attention: planner_attention(assigns.status),
        counts: planner_counts(assigns.status),
        first_use: planner_first_use?(assigns.status),
        admin?: @admin_role in assigns.user_roles
      )

    ~H"""
    <div id="home-planner">
      <.home_head title={@current_gtfs_version.name} lede={@lede} />

      <.region_error
        :if={@status.failed}
        region="status"
        message="This version's status could not load."
        detail="Your recent changes and the check still load. Nothing you saved is affected."
      />

      <%= if @first_use do %>
        <.first_use version_id={@current_gtfs_version.id} />
      <% else %>
        <.attention_list
          :if={@attention != []}
          items={@attention}
          version_id={@current_gtfs_version.id}
        />

        <div
          id="editor-work"
          class="grid gap-6 lg:grid-cols-[minmax(0,1.7fr)_minmax(0,1fr)] lg:items-start"
        >
          <%= cond do %>
            <% @resume.failed -> %>
              <.resume_card>
                <.region_error
                  region="resume"
                  message="Your recent changes could not load."
                  detail="Routes, calendars and stops still open from the menu. Nothing you saved is affected."
                />
              </.resume_card>
            <% @resume.loading -> %>
              <.resume_skeleton />
            <% true -> %>
              <.resume_list
                items={@streams.resume_rows}
                scope={@resume_scope}
                featured={@resume_featured}
                version_id={@current_gtfs_version.id}
                primary?={@attention == []}
              />
          <% end %>

          <%= cond do %>
            <% @check.failed -> %>
              <.share_card version_id={@current_gtfs_version.id}>
                <.region_error
                  region="check"
                  message="The check and export details could not load."
                  detail="The export page still works. Nothing you saved is affected."
                />
              </.share_card>
            <% @check.loading -> %>
              <.check_skeleton version_id={@current_gtfs_version.id} />
            <% true -> %>
              <.check_and_share
                version_id={@current_gtfs_version.id}
                product={:planner}
                check={@check.result.check}
                export={@check.result.export}
                since={@check.result.since}
              />
          <% end %>
        </div>

        <.areas_strip
          organization={@current_organization}
          version_id={@current_gtfs_version.id}
          counts={@counts}
        />
      <% end %>

      <.people_row :if={@admin?} />
    </div>
    """
  end

  # The Pathways station board is step 20; until it renders, the page carries
  # its root id and head only.
  defp render_dashboard_state(:pathways, assigns) do
    ~H"""
    <div id="home-pathways">
      <.home_head title="Stations" />
    </div>
    """
  end

  # `assign_async(:status, …)` leaves `Home.planner_status/2`'s facts in
  # `@status.result`; the check region does the same for the check-and-share
  # facts. Everything the planner page derives from the status is read here, so
  # the template only ever touches assigns the change tracker knows.

  # The lede states the version's publication and its calendar coverage; an
  # unreadable or failed calendar read makes no coverage claim (AC-8). It is
  # absent until the status region answers, because only the version is known
  # synchronously.
  defp planner_lede(%AsyncResult{ok?: true, result: %{coverage: coverage}}, version) do
    published = format_day(version.published_at || version.inserted_at)

    case coverage do
      {:through, last_date} ->
        "Published #{published} · calendars run through #{format_day(last_date)}"

      :none ->
        "Published #{published} · no calendars yet"

      :unknown ->
        "Published #{published} · calendar coverage could not be checked"
    end
  end

  defp planner_lede(_status, _version), do: nil

  defp planner_attention(%AsyncResult{ok?: true, result: %{attention: items}}), do: items

  defp planner_attention(_status), do: []

  defp planner_counts(%AsyncResult{ok?: true, result: %{counts: counts}}), do: counts
  defp planner_counts(_status), do: %{}

  defp planner_first_use?(%AsyncResult{ok?: true, result: %{first_use?: true}}), do: true

  defp planner_first_use?(_status), do: false

  # The featured item is the own scope's newest destination; the team list keeps
  # every destination as a row (AC-13, AC-14). Each row gets a positional DOM id
  # because a described resume item carries no identity of its own, and the
  # whole stream is reset on every load.
  defp resume_rows(:own, [featured | rows]), do: {featured, numbered_rows(rows)}
  defp resume_rows(_scope, items), do: {nil, numbered_rows(items)}

  defp numbered_rows(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} -> Map.put(row, :row_id, "resume-row-#{index}") end)
  end

  defp format_day(date), do: Calendar.strftime(date, "%b %-d, %Y")
end

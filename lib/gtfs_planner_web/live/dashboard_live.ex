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
  count) happen synchronously in `mount` through `home_source/0`; the working
  pages load their regions asynchronously once the client is connected and
  render each region's own skeleton while it loads. The GTFS Planner's Next step
  page reads three regions — `:status` for the lede, attention, areas and
  first-use facts, `:resume` for the user's continue-where-you-left-off list,
  and `:check` for the check and share facts. The Pathways station board reads
  its attention and check the same way, and starts the board's read first
  because `:statuses` needs the board's stations: `:board` for the station
  summaries and line counts, `:statuses` for the report and reachability
  summary, `:resume` for the rail's Continue card and `:editors` for who else is
  editing. The board's rows render from a stream, so a filter, search or page
  patch resets the visible page. `retry` reloads only the region it names
  (AC-29, CR-7). This module obtains data only through `home_source/0`,
  `ProductSurfaces` and `StationBoard`'s pure query, and owns no message
  callback of its own — the version-rename hook owns the only one (INV-4).
  """
  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Home.AccessComponents
  import GtfsPlannerWeb.Home.PlannerComponents, only: [attention_list: 1, first_use: 1]

  import GtfsPlannerWeb.Home.StationBoardComponents,
    only: [
      attention_error: 1,
      attention_skeleton: 1,
      attention_strip: 1,
      board: 1,
      board_error: 1,
      board_path: 1,
      board_skeleton: 1,
      first_use_no_feed: 1,
      lede: 2,
      rail_card: 1,
      rail_editing: 1,
      rail_resume: 1,
      rail_resume_error: 1,
      rail_resume_skeleton: 1,
      rail_share: 1,
      rail_share_error: 1,
      rail_share_skeleton: 1
    ]

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

  alias GtfsPlanner.Gtfs.StationBoard
  alias GtfsPlannerWeb.ProductSurfaces
  alias Phoenix.LiveView.AsyncResult

  @editor_role "pathways_studio_editor"
  @admin_role "pathways_studio_admin"

  # The retry event accepts only these region names; an unknown value is
  # ignored and never becomes an atom (CR-7).
  @retry_regions %{
    "status" => :status,
    "attention" => :attention,
    "board" => :board,
    "statuses" => :statuses,
    "resume" => :resume,
    "editors" => :editors,
    "check" => :check
  }

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

  defp load_state_data(socket, :pathways), do: load_pathways_regions(socket)

  defp load_state_data(socket, _state), do: socket

  # The planner page's three regions. `:status` and `:check` are plain
  # `assign_async` regions; `:resume` uses `start_async` because its rows render
  # through a stream, which an `assign_async` result cannot feed (CR-4). All of
  # them only start their read once the client is connected.
  defp load_planner_regions(socket) do
    socket
    |> load_status()
    |> load_resume()
    |> load_check(:planner)
  end

  # The station board's five regions. `:board`, `:statuses`, `:resume` and
  # `:editors` feed streams or the streamed rows, so they use `start_async`;
  # `:attention` feeds a plain card and `:check` the rail's facts. `:statuses`
  # starts from `handle_async(:board, …)`, because it needs the board's
  # stations; the board's skeleton stays up until it answers.
  defp load_pathways_regions(socket) do
    socket
    |> assign(:board_params, StationBoard.parse_params(%{}))
    |> assign(:board_summary, nil)
    |> load_attention()
    |> load_board()
    |> load_resume()
    |> load_editors()
    |> load_check(:pathways)
  end

  defp load_status(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    assign_async(socket, :status, fn ->
      {:ok, %{status: home_source().planner_status(organization_id, gtfs_version_id)}}
    end)
  end

  defp load_attention(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    # `assign_async` requires the key's value under it, so `@attention.result`
    # holds the item list itself.
    assign_async(socket, :attention, fn ->
      {:ok, %{attention: home_source().pathways_attention(organization_id, gtfs_version_id)}}
    end)
  end

  defp load_board(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    socket
    |> assign(:board, AsyncResult.loading())
    |> assign(:board_summary, nil)
    |> assign(:statuses, AsyncResult.loading())
    |> start_async(:board, fn ->
      home_source().station_board(organization_id, gtfs_version_id)
    end)
  end

  defp load_statuses(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    case socket.assigns.board do
      %AsyncResult{ok?: true, result: %{stations: stations}} ->
        start_async(socket, :statuses, fn ->
          home_source().station_statuses(organization_id, gtfs_version_id, stations)
        end)

      _unloaded ->
        socket
    end
  end

  defp load_resume(socket) do
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

  # Editing now lists other people; the viewer's own status is the board row's
  # "editing now" marker, not a rail entry (AC-27).
  defp load_editors(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:editors, AsyncResult.loading())
    |> start_async(:editors, fn ->
      home_source().station_editors(organization_id, gtfs_version_id)
      |> Enum.reject(&(&1.user_id == user_id))
    end)
  end

  defp load_check(socket, product) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    assign_async(socket, :check, fn ->
      {:ok, %{check: home_source().check_and_share(organization_id, gtfs_version_id, product)}}
    end)
  end

  defp check_product(%{assigns: %{dashboard_state: :pathways}}), do: :pathways
  defp check_product(_socket), do: :planner

  # The filters and the search form both patch the board's URL; an unchanged
  # pair pushes nothing, so a debounced change that matches the URL is a no-op.
  defp push_board_params(socket, stage, q) do
    current = socket.assigns.board_params
    next = StationBoard.parse_params(%{"stage" => Atom.to_string(stage), "q" => q})

    if next.stage == current.stage and next.q == current.q do
      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: board_path(next))}
    end
  end

  # The board's rows are a stream, so every param change, board answer, statuses
  # answer and editors answer re-derives the visible page and resets it (CR-4).
  # `:board` and `:statuses` results stay in their own assigns; the summary is
  # what the template reads.
  defp put_pathways_rows(socket) do
    %{board: board, statuses: statuses, board_params: params} = socket.assigns

    if board.ok? do
      statuses_arg = if statuses.ok?, do: statuses.result, else: :unavailable
      summary = StationBoard.query(board.result.stations, statuses_arg, params)
      editing = editing_station_ids(socket.assigns.editors)

      rows =
        Enum.map(summary.rows, fn row ->
          row
          |> Map.put(:lines, Map.get(board.result.lines, row.base.stop_id, 0))
          |> Map.put(:editing?, MapSet.member?(editing, row.base.stop_id))
        end)

      socket
      |> assign(:board_summary, %{
        page: summary.page,
        total_pages: summary.total_pages,
        total: summary.total,
        showing: length(rows),
        counts: summary.counts
      })
      |> stream(:board_rows, rows, reset: true, dom_id: &"board-row-#{&1.base.stop_id}")
    else
      socket
    end
  end

  defp editing_station_ids(%AsyncResult{ok?: true, result: editors}) when is_list(editors) do
    MapSet.new(editors, & &1.station_stop_id)
  end

  defp editing_station_ids(_editors), do: MapSet.new()

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      if socket.assigns.dashboard_state == :pathways do
        socket
        |> assign(:board_params, StationBoard.parse_params(params))
        |> put_pathways_rows()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry", %{"region" => region}, socket) do
    case @retry_regions[region] do
      :status -> {:noreply, load_status(socket)}
      :attention -> {:noreply, load_attention(socket)}
      :board -> {:noreply, load_board(socket)}
      :statuses -> {:noreply, load_statuses(socket)}
      :resume -> {:noreply, load_resume(socket)}
      :editors -> {:noreply, load_editors(socket)}
      :check -> {:noreply, load_check(socket, check_product(socket))}
      nil -> {:noreply, socket}
    end
  end

  # The board's filters are buttons because they toggle a view state, and the
  # search form patches the same URL the filters do; both reset the page to the
  # first one and keep the other params (AC-24).
  def handle_event("filter", %{"stage" => stage}, socket) do
    stage = StationBoard.parse_params(%{"stage" => stage}).stage

    push_board_params(socket, stage, socket.assigns.board_params.q)
  end

  def handle_event("search", %{"board" => %{"q" => q}}, socket) do
    push_board_params(socket, socket.assigns.board_params.stage, q)
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

  # The board's own read feeds a stream, and `:statuses` only starts once it has
  # the stations to look up; both re-derive the visible page when they land.
  def handle_async(:board, {:ok, %{stations: _stations, lines: _lines} = board}, socket) do
    {:noreply,
     socket
     |> assign(:board, AsyncResult.ok(socket.assigns.board, board))
     |> put_pathways_rows()
     |> load_statuses()}
  end

  def handle_async(:board, {:exit, reason}, socket) do
    {:noreply, assign(socket, :board, AsyncResult.failed(socket.assigns.board, {:exit, reason}))}
  end

  def handle_async(:statuses, {:ok, statuses}, socket) do
    {:noreply,
     socket
     |> assign(:statuses, AsyncResult.ok(socket.assigns.statuses, statuses))
     |> put_pathways_rows()}
  end

  # A failed statuses read leaves the rows up with "Unavailable" cells and "–"
  # counts, and the board renders the reference's partial banner (AC-29).
  def handle_async(:statuses, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:statuses, AsyncResult.failed(socket.assigns.statuses, {:exit, reason}))
     |> put_pathways_rows()}
  end

  def handle_async(:editors, {:ok, editors}, socket) do
    {:noreply,
     socket
     |> assign(:editors, AsyncResult.ok(socket.assigns.editors, editors))
     |> put_pathways_rows()}
  end

  def handle_async(:editors, {:exit, reason}, socket) do
    {:noreply,
     assign(socket, :editors, AsyncResult.failed(socket.assigns.editors, {:exit, reason}))}
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

  # The Pathways station board (AC-20–AC-29). The board's read owns the head's
  # lede, the filter counts, the first-use decisions and the streamed rows; the
  # attention strip and the rail are their own regions. A version with no
  # stations replaces the strip, board and rail with the import panel (AC-26),
  # and the People row is the organization administrator's only job here
  # (AC-7).
  defp render_dashboard_state(:pathways, assigns) do
    summary = assigns.board_summary
    counts = summary && summary.counts
    first_use_no_feed? = is_map(counts) and counts.all == 0
    no_pathways? = is_map(counts) and counts.all > 0 and counts.not_started == counts.all

    assigns =
      assign(assigns,
        lede: lede(assigns.current_gtfs_version.name, counts),
        counts: counts,
        first_use_no_feed?: first_use_no_feed?,
        no_pathways?: no_pathways?,
        board_ready?: assigns.board.ok? and (assigns.statuses.ok? or assigns.statuses.failed),
        admin?: @admin_role in assigns.user_roles
      )

    ~H"""
    <div id="home-pathways">
      <.home_head title="Stations" lede={@lede} />

      <%= if @first_use_no_feed? do %>
        <.first_use_no_feed version_id={@current_gtfs_version.id} />
      <% else %>
        <%= cond do %>
          <% @attention.failed -> %>
            <.attention_error />
          <% @attention.ok? -> %>
            <.attention_strip
              :if={@attention.result != []}
              items={@attention.result}
              version_id={@current_gtfs_version.id}
            />
          <% true -> %>
            <.attention_skeleton />
        <% end %>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_360px] lg:items-start">
          <%= cond do %>
            <% @board.failed -> %>
              <.board_error />
            <% !@board_ready? -> %>
              <.board_skeleton params={@board_params} />
            <% true -> %>
              <.board
                version_id={@current_gtfs_version.id}
                params={@board_params}
                summary={@board_summary}
                counts={@counts}
                rows={@streams.board_rows}
                statuses_failed?={@statuses.failed}
                no_pathways?={@no_pathways?}
              />
          <% end %>

          <div class="grid grid-cols-1 gap-6">
            <%= if @no_pathways? do %>
              <%!-- The reference's no-pathways state keeps only the share card: --%>
              <%!-- neither Continue nor Editing now has anything to send a new --%>
              <%!-- mapper to. --%>
            <% else %>
              <%= cond do %>
                <% @resume.failed -> %>
                  <.rail_resume_error />
                <% @resume.loading -> %>
                  <.rail_resume_skeleton />
                <% true -> %>
                  <.rail_resume
                    featured={@resume_featured}
                    scope={@resume_scope}
                    items={@streams.resume_rows}
                    version_id={@current_gtfs_version.id}
                  />
              <% end %>

              <%= cond do %>
                <% @editors.failed -> %>
                  <.rail_card id="editing-now" title="Editing now">
                    <.region_error
                      region="editors"
                      message="Who else is editing could not load."
                      detail="The board still shows every station's editing marker."
                    />
                  </.rail_card>
                <% @editors.loading -> %>
                  <%!-- The card appears only when someone else is editing, so a --%>
                  <%!-- loading placeholder would flash for most pages. --%>
                <% true -> %>
                  <.rail_editing
                    editors={@editors.result}
                    version_id={@current_gtfs_version.id}
                  />
              <% end %>
            <% end %>

            <%= cond do %>
              <% @check.failed -> %>
                <.rail_share_error />
              <% @check.loading -> %>
                <.rail_share_skeleton />
              <% true -> %>
                <.rail_share
                  version_id={@current_gtfs_version.id}
                  check={@check.result.check}
                  export={@check.result.export}
                  since={@check.result.since}
                />
            <% end %>
          </div>
        </div>
      <% end %>

      <.people_row :if={@admin?} />
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

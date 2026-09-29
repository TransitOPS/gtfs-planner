defmodule GtfsPlannerWeb.Gtfs.FlexLive do
  @moduledoc """
  The version's flex services list (AC-3).

  This is the Flex area's landing surface, and it replaces the Coming soon
  placeholder that stood here: one streamed table of the version's services with
  their hours, booking summary and readiness badge, the export-state line, the
  first-use question when the version has none, and the map card whose hook
  arrives in step 20.

  The page's data arrives in one operational read through `Gtfs.load_flex_list/2`,
  so the disconnected render shows the loading placeholder and the connected load
  resolves to `:ready` or `:unavailable`. A lost database connection is a
  retryable banner, never an empty list that reads as the version's own answer,
  and `retry` re-runs the same load.

  The create drawer and the copy action are this page's two writes (AC-4, AC-6).
  The drawer answers its own questions before it calls `Flex.create_service/3`,
  then navigates to the new service's page; a name or kind the changeset refuses
  comes back on the field that caused it. On a version with no services the
  first-use state also offers the copy action, which reads the organization's
  other published versions that hold a service and calls
  `Flex.copy_from_version/4` only after the confirmation names the version being
  copied from.

  The map card is the same read's `map` payload, drawn by the `FlexAreaMap` hook:
  the hook mounts on the card's `#flex-list-map` root, pushes `flex_map_ready`,
  and this page answers with `flex_map:load`. The payload is pushed only when the
  read has produced one, so the hook on the loading placeholder's card never
  draws a half-loaded version, and the card the ready render inserts asks again
  and gets it.

  Access is authorized at mount through `EnsureRole`, following the other GTFS
  pages. Every read is scoped to the selected organization and version inside the
  Flex context and `Flex.Checks` (R10, INV-4); the version switch is accepted
  only for a published version of the current organization.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FlexComponents

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.FlexComponents
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The create drawer's answers as its form sends them. `named` is the
  # prototype's own default answer to the one-name question.
  @blank_create %{"kind" => nil, "named" => "one", "name" => "", "route_id" => ""}

  # A changeset refusal mapped back onto the control that caused it. The message
  # for `key` is the changeset's own, because it names the answer to change.
  @create_field_ids %{
    kind: "create-pattern-area",
    name: "create_name",
    route_id: "create_route_id"
  }
  @create_messages %{
    kind: "Choose how the service works.",
    name: "Enter the service name riders see.",
    route_id: "Choose the route that detours."
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Flex")
     |> assign(:flex_state, :loading)
     |> assign(:services_count, 0)
     |> assign(:include_flex, true)
     |> assign(:has_fixed_routes?, true)
     |> assign(:flex_map, nil)
     |> assign(:routes, [])
     |> assign(:copy_sources, [])
     |> assign(:copy_form, copy_form())
     |> assign(:copy_target, nil)
     |> assign(:copy_error, nil)
     |> assign(:create_open, false)
     |> assign(:create_values, @blank_create)
     |> assign(:create_form, to_form(@blank_create, as: :create))
     |> assign(:create_submitted, false)
     |> assign(:create_errors, [])
     |> assign(:create_error, nil)
     |> assign(:create_focus_id, nil)
     |> assign(:create_return_focus_id, nil)
     |> stream_configure(:services, dom_id: &"flex-service-#{&1.id}")
     |> stream(:services, [])}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    if socket.assigns.flex_state == :loading do
      send(self(), :load_flex_services)
      {:noreply, socket}
    else
      {:noreply, load_services(socket)}
    end
  end

  @impl true
  def handle_info(:load_flex_services, socket), do: {:noreply, load_services(socket)}

  @impl true
  def handle_event("retry", _params, socket) do
    send(self(), :load_flex_services)
    {:noreply, assign(socket, :flex_state, :loading)}
  end

  # --- the create drawer -----------------------------------------------------

  @impl true
  def handle_event("open_create", params, socket) do
    # The first-use buttons carry their kind, so the drawer opens with the
    # answer the editor just gave and focus on the name; the header's button
    # opens the question itself.
    kind = params["kind"]
    values = %{@blank_create | "kind" => kind}

    {:noreply,
     socket
     |> assign(:create_open, true)
     |> assign(:create_values, values)
     |> assign(:create_form, to_form(values, as: :create))
     |> assign(:create_submitted, false)
     |> assign(:create_errors, [])
     |> assign(:create_error, nil)
     |> assign(:create_focus_id, if(kind, do: "create_name", else: nil))
     |> assign(:create_return_focus_id, params["opener_id"])}
  end

  @impl true
  def handle_event("close_create", _params, socket) do
    {:noreply, close_create(socket)}
  end

  @impl true
  def handle_event("create_change", %{"create" => params}, socket) do
    {:noreply, change_create(socket, params)}
  end

  def handle_event("create_change", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_submit", %{"create" => params}, socket) do
    values = Map.merge(socket.assigns.create_values, params)
    socket = assign(socket, :create_submitted, true)

    case create_errors(values) do
      [] -> {:noreply, submit_create(socket, values)}
      errors -> {:noreply, show_create_errors(socket, errors)}
    end
  end

  def handle_event("create_submit", _params, socket), do: {:noreply, socket}

  # --- the copy action --------------------------------------------------------

  @impl true
  def handle_event("copy_from_version", %{"copy" => %{"source_version_id" => id}}, socket) do
    case Enum.find(socket.assigns.copy_sources, &(to_string(&1.id) == id)) do
      nil ->
        # A blank answer and a version this page never offered take the same
        # path: nothing is copied, and the answer names what to choose.
        message =
          if id == "",
            do: "Choose a version to copy from.",
            else: "Choose one of this organization’s versions."

        {:noreply, assign(socket, :copy_error, message)}

      source ->
        {:noreply, assign(socket, copy_target: source, copy_error: nil)}
    end
  end

  def handle_event("copy_from_version", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_copy", _params, socket) do
    {:noreply, assign(socket, :copy_target, nil)}
  end

  @impl true
  def handle_event("confirm_copy", _params, socket) do
    case socket.assigns.copy_target do
      nil -> {:noreply, socket}
      source -> {:noreply, copy_services(socket, source)}
    end
  end

  @impl true
  def handle_event("flex_map_ready", _params, socket) do
    # The hook asks once per mount and the payload answers every mount of the
    # card; before the load has one there is nothing to draw, and the ready
    # card's own mount asks again.
    case socket.assigns[:flex_map] do
      %{} = payload -> {:noreply, push_event(socket, "flex_map:load", payload)}
      _missing -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/flex")}
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
      {:noreply, push_navigate(socket, to: ~p"/gtfs/#{version_id}/flex")}
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
      <div id="flex-page" class="ds-page">
        <.header>
          Flex
          <:subtitle>On-demand services in {@current_gtfs_version.name}</:subtitle>
          <:actions :if={@flex_state == :ready and @services_count > 0}>
            <.button
              id="create-service"
              variant="primary"
              class="min-h-11"
              phx-click="open_create"
              phx-value-opener_id="create-service"
            >
              <.icon name="hero-plus" class="size-4" /> Create flex service
            </.button>
          </:actions>
        </.header>

        <.exports_line
          :if={@flex_state == :ready}
          include_flex={@include_flex}
          has_fixed_routes?={@has_fixed_routes?}
          version_id={@current_gtfs_version.id}
        />

        <.loading :if={@flex_state == :loading} />
        <.list_error :if={@flex_state == :unavailable} />

        <div :if={@flex_state == :ready} class="mt-6 grid gap-8 lg:grid-cols-[minmax(0,1fr)_440px]">
          <.first_use
            :if={@services_count == 0}
            sources={@copy_sources}
            copy_form={@copy_form}
            copy_target={@copy_target}
            copy_error={@copy_error}
          />

          <.services_table
            :if={@services_count > 0}
            rows={@streams.services}
            count={@services_count}
          />

          <.list_map_card
            title={FlexComponents.map_title(@services_count)}
            legend={if @services_count > 0, do: :all, else: :routes}
          />
        </div>

        <.create_drawer
          :if={@flex_state == :ready}
          open={@create_open}
          version_name={@current_gtfs_version.name}
          form={@create_form}
          errors={@create_errors}
          routes={@routes}
          error={@create_error}
          focus_id={@create_focus_id}
          return_focus_id={@create_return_focus_id}
        />
      </div>
    </Layouts.app>
    """
  end

  # The version's services with everything the table renders: the readiness
  # checks are run once here for every service (each against the version's other
  # services, which the overlap rule compares), and the calendars map is the one
  # `RiderText` reads.
  defp load_services(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Gtfs.load_flex_list(organization_id, version_id) do
      {:ok, load} ->
        rows =
          Enum.map(load.services, fn entry ->
            FlexComponents.list_row(entry.service, entry.checks, load.calendars, version_id)
          end)

        socket
        |> assign(:flex_state, :ready)
        |> assign(:services_count, length(rows))
        |> assign(:include_flex, load.include_flex)
        |> assign(:has_fixed_routes?, load.has_fixed_routes?)
        |> assign(:flex_map, load.map)
        |> assign(:routes, load.routes)
        |> assign(:copy_sources, copy_sources(socket, rows))
        |> stream(:services, rows, reset: true)

      {:error, :unavailable} ->
        socket
        |> assign(:flex_state, :unavailable)
        |> assign(:services_count, 0)
        |> assign(:flex_map, nil)
        |> assign(:routes, [])
        |> assign(:copy_sources, [])
        |> stream(:services, [], reset: true)
    end
  end

  # --- the create drawer -----------------------------------------------------

  # Every change re-renders the drawer: the kind and the one-name answer each
  # add or remove a question. The answers the editor has already given survive a
  # question disappearing from the form, so flipping a kind back and forth keeps
  # the name and the route. A failed submit keeps its summary live while the
  # editor answers it, so the list shrinks as the answers arrive.
  defp change_create(socket, params) do
    values = Map.merge(socket.assigns.create_values, params)

    socket
    |> assign(:create_values, values)
    |> assign(:create_form, to_form(values, as: :create))
    |> assign(
      :create_errors,
      if(socket.assigns.create_submitted, do: create_errors(values), else: [])
    )
    |> assign(:create_error, nil)
  end

  defp close_create(socket) do
    socket
    |> assign(:create_open, false)
    |> assign(:create_submitted, false)
    |> assign(:create_errors, [])
    |> assign(:create_error, nil)
    |> assign(:create_focus_id, nil)
  end

  # AC-4's questions, answered before the changeset sees them, so the summary
  # lists every missing answer at once and the links name the fields.
  defp create_errors(values) do
    kind = values["kind"]

    [
      if(kind in ["area", "detour"],
        do: nil,
        else: {"create-pattern-area", @create_messages.kind}
      ),
      if(String.trim(values["name"] || "") == "",
        do: {"create_name", @create_messages.name},
        else: nil
      ),
      if(kind == "detour" and blank?(values["route_id"]),
        do: {"create_route_id", @create_messages.route_id},
        else: nil
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp submit_create(socket, values) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    attrs = create_attrs(values)

    case Flex.create_service(organization_id, version_id, attrs) do
      {:ok, service} ->
        push_navigate(socket, to: "/gtfs/#{version_id}/flex/#{service.id}")

      {:error, %Ecto.Changeset{} = changeset} ->
        case changeset_errors(changeset) do
          [] ->
            assign(socket,
              create_errors: [],
              create_error: "Nothing was created. Check the answers and try again."
            )

          errors ->
            show_create_errors(socket, errors)
        end

      {:error, :version_unavailable} ->
        assign(socket,
          create_errors: [],
          create_error: "This version can’t be changed right now. Reload the page and try again."
        )
    end
  end

  # The drawer's answers as `Flex.create_service/3` reads them. A blank detour
  # route stays blank so the changeset reports it rather than the page inventing
  # one, and an area service never sends a route at all.
  defp create_attrs(values) do
    attrs = %{"name" => String.trim(values["name"] || ""), "kind" => values["kind"]}

    if values["kind"] == "detour" do
      Map.put(attrs, "route_id", values["route_id"])
    else
      attrs
    end
  end

  # The summary is the form's own error surface, and the `FormErrorFocus` hook
  # owns the drawer's content: pushing the summary's id moves focus to it, so
  # the editor hears the list rather than the field they just left.
  defp show_create_errors(socket, errors) do
    socket
    |> assign(:create_errors, errors)
    |> assign(:create_error, nil)
    |> push_event("focus_scoped_target", %{id: "create-error-summary"})
  end

  # A changeset refusal belongs on a control the drawer renders; `key` is the
  # name the editor chose, so its message lands on the name field.
  defp changeset_errors(changeset) do
    changeset.errors
    |> Enum.map(fn
      {:key, {message, _opts}} ->
        if Ecto.Changeset.get_field(changeset, :key) in [nil, ""] do
          {"create_name", "Enter a name with at least one letter or number."}
        else
          {"create_name", message}
        end

      {field, _error} when is_map_key(@create_field_ids, field) ->
        {Map.fetch!(@create_field_ids, field), Map.fetch!(@create_messages, field)}

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # --- the copy action --------------------------------------------------------

  defp copy_services(socket, source) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    actor = %{id: socket.assigns.current_user.id, email: socket.assigns.current_user.email}

    case Flex.copy_from_version(organization_id, version_id, source.id, actor) do
      {:ok, 0} ->
        assign(socket,
          copy_target: nil,
          copy_error: "No flex services to copy from #{source.name}."
        )

      {:ok, count} ->
        socket
        |> load_services()
        |> assign(copy_target: nil, copy_error: nil)
        |> put_flash(:info, "#{FlexComponents.count_label(count)} copied from #{source.name}.")

      {:error, :target_not_empty} ->
        # Another editor added a service between the load and the copy: R14
        # copies into an empty version only, so nothing was written.
        socket
        |> load_services()
        |> assign(copy_target: nil)
        |> put_flash(:error, "This version already has a flex service. Nothing was copied.")

      {:error, :not_found} ->
        assign(socket,
          copy_target: nil,
          copy_error: "That version can’t be copied from."
        )
    end
  end

  # The copy action needs a source version only when this version has no
  # service, and `copy_from_version/4` copies into an empty version only. The
  # sources are the organization's published versions that hold a service: a
  # version with none cannot be a source, and this version holds none by the
  # time this runs.
  defp copy_sources(_socket, [_ | _]), do: []

  defp copy_sources(socket, []) do
    organization_id = socket.assigns.current_organization.id
    with_services = Flex.version_ids_with_services(organization_id)

    organization_id
    |> Versions.list_published_gtfs_versions()
    |> Enum.filter(&MapSet.member?(with_services, to_string(&1.id)))
  end

  defp copy_form, do: to_form(%{"source_version_id" => ""}, as: :copy)

  defp blank?(value), do: is_nil(value) or value == ""
end

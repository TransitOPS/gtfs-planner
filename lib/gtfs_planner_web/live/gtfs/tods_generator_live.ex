defmodule GtfsPlannerWeb.Gtfs.TodsGeneratorLive do
  @moduledoc """
  The TODS generator's initiating page.

  It states what the tool does to the selected version before offering a control,
  names its one prerequisite — an existing garage in this organization — and holds
  the five business inputs of a request: the inclusive date range, the Monday
  representative week, the fallback garage and the opt-in terminal relief. The
  dates default to the feed's first active calendar week and a single garage is
  preselected, because one garage is not a choice. The rules the generation would
  keep are shown read-only from the version's stored crew settings, with the Runs
  page named as their owner.

  The page is reached from the account menu and guarded by the same editor role
  the other GTFS pages use; the menu is never the access check. It composes no
  planning data: the request is validated through `TodsGenerator.Input`, a garage
  the organization does not own is never echoed back as a choice, and the
  candidate the request describes stays the generator's own read.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.PlannerComponents,
    only: [aside_link: 1, form_error_summary: 1, form_section: 1, message: 1, scope_line: 1]

  # The stored crew rules are rendered through the wording their own page already
  # owns, so this page never respells a rule the crew drawer states.
  import GtfsPlannerWeb.Gtfs.RunsComponents, only: [crew_rule_text: 1]

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.TodsGenerator.Input
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Wording
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @generator_path "/tods-generator"
  @form_id "tods-generator-form"
  @form_error_id "tods-generator-form-error"

  # The request's controls in the order the form reads them, with the id each one
  # renders: a refused submit's summary links to the control its message names.
  @fields [
    start_date: "tods-start-date",
    end_date: "tods-end-date",
    representative_week: "tods-representative-week",
    garage_id: "tods-garage-select"
  ]

  @field_labels %{
    start_date: "First date",
    end_date: "Last date",
    representative_week: "Representative week",
    garage_id: "Fallback garage"
  }

  # What the page says when the organization has no garage to start from. It is a
  # state rather than a failure, so it is announced politely instead of alerting.
  @missing_garages_status %{
    kind: "warning",
    role: "status",
    title: "Add a garage first.",
    body:
      "Generation places vehicles and operators at the garages you entered, and this organization has none yet."
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "TODS generator")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:form_id, @form_id)
     |> assign(:form_error_id, @form_error_id)
     |> assign(:garages, [])
     |> assign(:active_dates, [])
     |> assign(:crew_rules, nil)
     |> assign(:failures, [])
     |> assign(:status, nil)
     |> assign(:form, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_page(socket)}
  end

  @impl true
  def handle_event("validate_request", %{"input" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(request_changeset(socket, params)))}
  end

  def handle_event("validate_request", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("preview_generation", %{"input" => params}, socket) do
    changeset = request_changeset(socket, params)

    cond do
      # The prerequisite is re-read here rather than trusted from the mount: a
      # control the browser disabled is not a server-side check, and a garage may
      # have been added or removed since the page opened.
      missing_garages?(socket) ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign(:failures, [])
         |> assign(:status, @missing_garages_status)}

      changeset.valid? ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign(:failures, [])
         |> assign(:status, request_status(changeset, socket))}

      true ->
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign(:failures, failures(changeset))
         |> assign(:status, nil)
         |> push_event("focus_form_error", %{
           form_id: @form_id,
           fallback_id: @form_error_id
         })}
    end
  end

  def handle_event("preview_generation", _params, socket), do: {:noreply, socket}

  # A version switch keeps this page, because the page belongs to the version it
  # names: the new version's own ranges, garages and rules are what it must show.
  @impl true
  def handle_event("switch_gtfs_version", %{"version" => version_id}, socket) do
    if Versions.published_gtfs_version_for_org?(
         socket.assigns.current_organization.id,
         version_id
       ) do
      socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})

      {:noreply, push_navigate(socket, to: generator_path(version_id))}
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
      {:noreply, push_navigate(socket, to: generator_path(version_id))}
    else
      {:noreply, socket}
    end
  end

  defp generator_path(version_id), do: "/gtfs/#{version_id}#{@generator_path}"

  defp load_page(socket) do
    organization = socket.assigns.current_organization
    version = socket.assigns.current_gtfs_version

    socket =
      socket
      |> assign(:garages, garages(organization.id))
      |> assign(:active_dates, active_dates(organization.id, version.id))
      |> assign(:crew_rules, Gtfs.get_crew_settings(organization.id, version.id))
      |> assign(:failures, [])
      |> assign(:status, nil)

    assign(socket, :form, to_form(request_changeset(socket, %{})))
  end

  defp garages(organization_id) do
    organization_id
    |> Operations.planning_garages()
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  # The same predicate the generator answers `:missing_garages` with, asked of the
  # stored rows rather than of a page assignment.
  defp missing_garages?(socket) do
    Operations.planning_garages(socket.assigns.current_organization.id) == %{}
  end

  # The feed's dates with scheduled service. The form's default week has to be the
  # week the generator itself would default to, so this is the same scope read
  # (`Calendars.list_calendars/2` filtered by the selected range) the generator's
  # source loader makes. A version whose calendars cannot be read has no dates to
  # offer, and the fields' own validation reports the missing ones.
  defp active_dates(organization_id, gtfs_version_id) do
    case Calendars.list_calendars(organization_id, gtfs_version_id) do
      {:ok, calendars} ->
        calendars |> Enum.flat_map(& &1.active_dates) |> Enum.uniq() |> Enum.sort()

      {:error, :not_found} ->
        []
    end
  end

  # The request the form holds. The dates come from the feed's first active week
  # and a single garage is preselected, because one garage is not a choice; a
  # `garage_id` this organization does not own is not a choice either, so it is
  # replaced with no choice rather than echoed back as if the reader had picked it.
  defp request_changeset(socket, params) do
    params =
      case Map.get(params, "garage_id") do
        garage_id when is_binary(garage_id) ->
          Map.put(params, "garage_id", own_garage_id(socket.assigns.garages, garage_id))

        _none ->
          preselect_only_garage(params, socket.assigns.garages)
      end

    Input.changeset(%Input{}, params, socket.assigns.active_dates)
  end

  defp own_garage_id(garages, garage_id) do
    if Enum.any?(garages, &(&1.id == garage_id)), do: garage_id, else: nil
  end

  defp preselect_only_garage(params, [garage]), do: Map.put(params, "garage_id", garage.id)
  defp preselect_only_garage(params, _garages), do: params

  # What the page answers a request it accepted with: the values the generator
  # would read, in the shared date wording. It states the request, not a candidate.
  defp request_status(changeset, socket) do
    input = Ecto.Changeset.apply_changes(changeset)

    # The changeset is valid, so the garage it names is one of these: an id this
    # organization does not own was dropped before validation.
    garage = Enum.find(socket.assigns.garages, &(&1.id == input.garage_id))

    %{
      kind: "info",
      role: nil,
      title: "Request checked.",
      body:
        "Dates #{Wording.date(input.start_date)} to #{Wording.date(input.end_date)} · " <>
          "representative week #{Wording.date(input.representative_week)} · " <>
          "fallback garage #{garage.name} · terminal relief #{relief_wording(input.terminal_relief?)}"
    }
  end

  defp relief_wording(true), do: "on"
  defp relief_wording(false), do: "off"

  # Every problem at once, each linking to the control it names, in the order the
  # form reads.
  defp failures(changeset) do
    for {field, id} <- @fields,
        {message, _opts} <- Keyword.get_values(changeset.errors, field) do
      %{href: "##{id}", msg: "#{Map.fetch!(@field_labels, field)} #{message}."}
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
      <div id="tods-generator-page" phx-hook="FormErrorFocus" class="ds-page">
        <.header>
          TODS generator
          <:subtitle>
            Builds fictional operating data from a schedule, for internal testing and
            demonstrations.
            <.scope_line id="tods-generator-scope" icon="hero-beaker">
              Builds into {@current_gtfs_version.name} at {@current_organization.name}. Fictional
              operators belong to {@current_organization.name}, so they appear on this
              organization's Rosters page for every version.
            </.scope_line>
          </:subtitle>
        </.header>

        <section
          id="tods-generator-purpose"
          aria-labelledby="tods-generator-purpose-title"
          class="mt-6 max-w-3xl rounded-card border border-subtle bg-white px-5 py-5 sm:px-6"
        >
          <h2
            id="tods-generator-purpose-title"
            class="font-display text-[19px] font-semibold tracking-[-0.02em] text-strong"
          >
            Generate fictional operations data
          </h2>
          <p class="mt-2 text-sm text-default">
            Use this tool to populate GTFS Planner for internal testing and demonstrations. It
            creates made-up operating assignments and operators from this version's schedule and
            your existing garages. The results are planning examples, not an agency's actual
            staffing plan.
          </p>
          <p class="mt-3 text-sm text-default">
            Saving adds data to the Blocks, Runs and Rosters screens of {@current_gtfs_version.name}.
            Fictional operators are saved for the organization and appear in its Operators list
            beside its real ones. Existing assignments are kept; the preview shows what would be
            added and any work it leaves uncovered. Saved data can be edited on those screens and
            is included in later TODS exports. Generating does not publish a feed.
          </p>
          <p class="mt-3 text-sm text-default">
            A roster change repeats by weekday, so a saved slot affects every matching date in
            the calendar — including matching dates after the range you select here. Dates whose
            service differs, such as holidays, stay uncovered.
          </p>
        </section>

        <.message
          :if={@garages == []}
          id="tods-generator-missing-garages"
          kind="warning"
          title="Add a garage first"
          class="mt-6 max-w-3xl"
        >
          Generation places vehicles and operators at garages you entered. This organization has
          none yet, so there is nothing to build from.
          <:action>
            <.button
              id="tods-generator-garages-link"
              variant="secondary"
              class="min-h-11"
              navigate={~p"/gtfs/#{@current_gtfs_version.id}/settings/garages"}
            >
              Open Settings › Garages
            </.button>
          </:action>
        </.message>

        <.message
          :if={@status}
          id="tods-generator-status"
          kind={@status.kind}
          role={@status.role}
          title={@status.title}
          class="mt-6 max-w-3xl"
        >
          {@status.body}
        </.message>

        <.form_error_summary
          id={@form_error_id}
          title="The request needs fixing"
          failures={@failures}
          class="mt-6 max-w-3xl mb-0"
        />

        <.form
          for={@form}
          id={@form_id}
          novalidate
          phx-change="validate_request"
          phx-submit="preview_generation"
          class="mt-6 max-w-3xl overflow-hidden rounded-card border border-subtle bg-white"
        >
          <div class="grid gap-6 p-5 sm:p-6">
            <.form_section title="Service scope" first?>
              <div class="grid gap-4 sm:grid-cols-3">
                <.input
                  field={@form[:start_date]}
                  type="date"
                  id="tods-start-date"
                  label="First date"
                />
                <.input field={@form[:end_date]} type="date" id="tods-end-date" label="Last date" />
                <.input
                  field={@form[:representative_week]}
                  type="date"
                  id="tods-representative-week"
                  label="Representative week"
                />
              </div>
              <p class="text-[13px] text-muted">
                The first date defaults to the feed's first active calendar week. The dates are
                inclusive, and the representative week is a whole Monday-to-Sunday week inside
                them: its weekday pattern is what a saved roster line repeats.
              </p>
            </.form_section>

            <.form_section title="Garage">
              <.input
                field={@form[:garage_id]}
                type="select"
                id="tods-garage-select"
                label="Fallback garage"
                prompt="Choose a garage"
                disabled={@garages == []}
                options={Enum.map(@garages, &{&1.name, &1.id})}
              />
              <p class="text-[13px] text-muted">
                Blocks use this garage only where no existing block, block attribute, route
                setting or default already resolves one. The list is every garage {@current_organization.name} has entered.
              </p>
            </.form_section>

            <.form_section title="Terminal relief">
              <.input
                field={@form[:terminal_relief?]}
                type="checkbox"
                id="tods-terminal-relief"
                label="Allow handovers at a terminal stop"
              />
              <p id="tods-terminal-relief-consequence" class="mt-1 text-[13px] text-muted">
                Adds a handover at a terminal stop only where an existing relief window already
                allows one. No limit is relaxed to make work fit, and any setting this adds is
                shown in the preview before it is saved.
              </p>
            </.form_section>

            <.form_section title="Rules in force">
              <p id="tods-generator-rules" class="text-sm text-default">
                {crew_rule_text(@crew_rules)}
              </p>
              <p id="tods-generator-rules-spread" class="mt-1 text-sm text-default">
                Longest spread: {div(@crew_rules.max_spread_minutes, 60)} h.
              </p>
              <p class="mt-2 text-[13px] text-muted">
                These are {@current_gtfs_version.name}'s stored crew rules. Generation keeps them
                as they are; change them where they are owned.
              </p>
              <.aside_link
                id="tods-generator-rules-link"
                navigate={~p"/gtfs/#{@current_gtfs_version.id}/runs"}
              >
                Crew rules on Runs
              </.aside_link>
            </.form_section>
          </div>

          <div class="flex flex-wrap items-center justify-end gap-3 border-t border-subtle px-5 py-4 sm:px-6">
            <p
              :if={@garages == []}
              id="tods-preview-blocked"
              class="basis-full text-[13px] text-muted sm:mr-auto sm:basis-auto"
            >
              Add a garage before previewing a generation.
            </p>
            <.button
              type="submit"
              id="tods-preview-button"
              class="min-h-11"
              disabled={@garages == []}
              data-unavailable={@garages == []}
            >
              Preview generation
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end

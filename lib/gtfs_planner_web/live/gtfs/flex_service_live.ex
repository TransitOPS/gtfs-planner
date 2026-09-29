defmodule GtfsPlannerWeb.Gtfs.FlexServiceLive do
  @moduledoc """
  One flex service (AC-5): its hours and booking rules, the rider and booking
  previews, its map card, and the page's one Save.

  This is the second half of the Flex workspace: the list (`Gtfs.FlexLive`)
  creates and copies services, and this page is where a service is described.
  The page keeps one draft — the service struct, with a placeholder service-wide
  booking rule when it has none — and derives everything on screen from it, so
  the preview, the readiness badge and the save bar all report the draft rather
  than the last save. `dirty?` is the page's own fields differing from the saved
  ones, exactly as the calendar editor's draft compares its params to its
  baseline.

  Save calls `Flex.save_service/5` once with every field this page owns;
  fields the page does not render (step 23's where, riders, exports and status)
  keep their stored values. A changeset refusal keeps the draft and lists every
  problem in `#flex-service-error-summary` with a link to its control, and a
  `:stale` answer keeps the draft and offers the two ways out the prototype
  has: load their saved values, or save this draft on top of their row.

  Nothing is written before Save. Leaving with unsaved changes asks first: the
  `DraftGuard` hook intercepts an in-app link and sends the path here, and the
  reload path is the browser's own beforeunload. The map card is the same
  `FlexAreaMap` hook the list uses, fed by `Flex.service_map_payload/3`.

  `:area` is this page's second action, and the area editor arrives in step 24;
  here it is a panel that keeps the draft and offers the way back.

  The where, who-can-ride, exports and status sections are this page's second
  half (AC-7, AC-29): the area summaries and connecting stops, the detour
  fields and its derived-zone summary, the registered-riders fields with the
  ADA preset, the export plan with the export-details drawer and the
  organization's realtime answer, and the deactivate/reactivate/delete actions.
  The organization's realtime answer is not part of the service draft: choosing
  it writes `ExportDefaults.update/2` at once, exactly as the Settings page
  step 26 will, and the service's own fields stay unsaved until Save.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.FlexComponents

  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.Export, as: FlexExport
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexHours
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.Gtfs.FlexComponents
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # The booking rule's fields, in the order a save writes them; the page's own
  # attrs map is built from the draft's struct, so a field this page does not
  # render keeps its stored value.
  @rule_fields [
    :service_id,
    :when,
    :minutes,
    :days,
    :by,
    :business_days,
    :office_service_id,
    :max_days
  ]

  # The control ids the sections render, where they differ from the changeset's
  # field id: the reference names these controls `f-…`, and the error summary
  # and the inline errors both have to land on the control that is on screen.
  @field_control_ids %{
    distance_m: "f-distance",
    wording: "f-wording",
    first_stop_id: "f-first",
    last_stop_id: "f-last",
    eligibility: "f-eligibility"
  }

  # The prototype's values for a rule added to one calendar.
  @scoped_rule_default %{when: :earlier_day, days: 2, by: "17:00"}

  # The prototype's default phone-line hours.
  @default_phone_hours %{"days" => "Mon–Fri", "from" => "08:00", "to" => "17:00"}

  # AC-29: ADA-only detours replace paratransit, which must reach ¾ mile, so
  # choosing ADA-only with no distance chosen yet preselects that distance.
  @ada_distance_m 1_200

  # The prototype's ADA preset: the eligibility sentence and the next-day rule
  # 49 CFR 37.131(b) describes.
  @ada_eligibility "Riders with ADA paratransit eligibility. Visitors eligible elsewhere may ride up to 21 days a year"
  @ada_rule %{
    when: :earlier_day,
    days: 1,
    by: "17:00",
    business_days: false,
    max_days: 14,
    minutes: nil,
    office_service_id: nil
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Flex service")
     |> assign(:service_state, :loading)
     |> assign(:service_id, nil)
     |> assign(:saved, nil)
     |> assign(:draft, nil)
     |> assign(:form, nil)
     |> assign(:dirty?, false)
     |> assign(:stale?, false)
     |> assign(:stale_changes, [])
     |> assign(:saving, false)
     |> assign(:checks, [])
     |> assign(:status, %{tone: :neutral, label: "Unknown", errors: 0, warnings: 0})
     |> assign(:facts, nil)
     |> assign(:others, [])
     |> assign(:calendars, %{})
     |> assign(:calendar_rows, %{})
     |> assign(:calendar_options, [])
     |> assign(:stop_choices, [])
     |> assign(:hub_options, [])
     |> assign(:hub_pick, nil)
     |> assign(:route_stop_choices, [])
     |> assign(:trip_counts, %{})
     |> assign(:area_summaries, [])
     |> assign(:plan, nil)
     |> assign(:export_defaults, nil)
     |> assign(:export_details_open, false)
     |> assign(:status_action, nil)
     |> assign(:today, nil)
     |> assign(:area_geojson, %{})
     |> assign(:map, nil)
     |> assign(:save_errors, [])
     |> assign(:field_errors, %{})
     |> assign(:save_error, nil)
     |> assign(:pending_discard, false)
     |> assign(:pending_leave, nil)}
  end

  @impl true
  def handle_params(%{"service" => id}, _uri, socket) do
    socket = assign(socket, :service_id, id)

    # The first paint defers its read, so the disconnected render shows the
    # loading state and the connected mount runs the load once. A patch to the
    # page's own area action keeps the draft: nothing is re-read.
    if socket.assigns.service_state == :loading do
      send(self(), :load_flex_service)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:load_flex_service, socket), do: {:noreply, load_service(socket)}

  @impl true
  def handle_event("retry", _params, socket) do
    send(self(), :load_flex_service)
    {:noreply, assign(socket, :service_state, :loading)}
  end

  # --- the draft --------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"service" => params}, socket) do
    {:noreply, put_draft(socket, params)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_hours", _params, socket) do
    hour = %FlexHours{
      area_key: nil,
      service_id: next_calendar(socket, Enum.map(socket.assigns.draft.hours, & &1.service_id)),
      start: "09:00",
      end: "17:00"
    }

    draft = %{socket.assigns.draft | hours: socket.assigns.draft.hours ++ [hour]}

    {:noreply, put_draft_struct(socket, draft)}
  end

  @impl true
  def handle_event("remove_hours", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {index, ""} ->
        draft = %{socket.assigns.draft | hours: List.delete_at(socket.assigns.draft.hours, index)}
        {:noreply, put_draft_struct(socket, draft)}

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("add_scoped_rule", _params, socket) do
    rule = struct(FlexBookingRule, @scoped_rule_default)

    rule = %{
      rule
      | service_id:
          next_calendar(socket, Enum.map(socket.assigns.draft.booking_rules, & &1.service_id))
    }

    draft = %{
      socket.assigns.draft
      | booking_rules: socket.assigns.draft.booking_rules ++ [rule]
    }

    {:noreply, put_draft_struct(socket, draft)}
  end

  @impl true
  def handle_event("remove_scoped_rule", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {index, ""} ->
        draft = %{
          socket.assigns.draft
          | booking_rules: List.delete_at(socket.assigns.draft.booking_rules, index)
        }

        {:noreply, put_draft_struct(socket, draft)}

      _other ->
        {:noreply, socket}
    end
  end

  # --- saving -----------------------------------------------------------------

  @impl true
  def handle_event("save", %{"service" => params}, socket) do
    socket = put_draft(socket, params)
    {:noreply, write_page(socket, socket.assigns.saved)}
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  # The stale banner's two answers. "Use their changes" reloads the stored
  # service into both the baseline and the draft; "Save both changes" keeps this
  # draft and saves it on top of their row, whose lock_version it re-reads.
  @impl true
  def handle_event("use_their_changes", _params, socket), do: {:noreply, load_service(socket)}

  @impl true
  def handle_event("save_both_changes", _params, socket) do
    case Flex.get_service(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.service_id
         ) do
      {:ok, stored} ->
        {:noreply, write_page(assign(socket, :saving, true), stored)}

      {:error, :not_found} ->
        {:noreply,
         save_error(
           socket,
           "This service was deleted in another session. Your changes are kept here; reload the page to see the list."
         )}
    end
  end

  # --- discarding and leaving -------------------------------------------------

  @impl true
  def handle_event("discard_changes", _params, socket) do
    {:noreply, assign(socket, :pending_discard, true)}
  end

  @impl true
  def handle_event("confirm_discard", _params, socket) do
    {:noreply, socket |> assign(:pending_discard, false) |> load_service()}
  end

  @impl true
  def handle_event("keep_editing", _params, socket) do
    {:noreply, socket |> assign(:pending_discard, false) |> assign(:pending_leave, nil)}
  end

  # The client half of the guard: the `DraftGuard` hook intercepts a same-origin
  # link click while the draft is dirty and sends the path here instead of
  # navigating. A path this page did not author is refused, and so is a payload
  # the hook never sends.
  @impl true
  def handle_event("flex_depart", %{"path" => path}, socket) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      {:noreply, assign(socket, :pending_leave, path)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("flex_depart", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("confirm_leave", _params, socket) do
    case socket.assigns.pending_leave do
      nil -> {:noreply, socket}
      path -> {:noreply, push_navigate(socket, to: path)}
    end
  end

  @impl true
  def handle_event("back_to_service", _params, socket) do
    {:noreply, push_patch(socket, to: service_path(socket))}
  end

  # --- the where section -------------------------------------------------------

  # Both ways into the area editor patch to `:area`, which keeps the draft in
  # the socket (CR-8): the editor's own work and its Save arrive in step 24.
  @impl true
  def handle_event("edit_area", _params, socket) do
    {:noreply, push_patch(socket, to: service_path(socket) <> "/area")}
  end

  def handle_event("add_area", _params, socket) do
    {:noreply, push_patch(socket, to: service_path(socket) <> "/area")}
  end

  @impl true
  def handle_event("pick_hub", %{"hub_stop" => stop_id}, socket) when is_binary(stop_id) do
    {:noreply, assign(socket, :hub_pick, stop_id)}
  end

  def handle_event("pick_hub", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("add_hub", _params, socket) do
    stop_id = socket.assigns.hub_pick

    if is_binary(stop_id) and stop_id != "" and stop_id not in socket.assigns.draft.hub_stop_ids do
      draft = %{
        socket.assigns.draft
        | hub_stop_ids: socket.assigns.draft.hub_stop_ids ++ [stop_id]
      }

      {:noreply, socket |> put_draft_struct(draft) |> assign_hub_choices()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_hub", %{"stop-id" => stop_id}, socket) do
    draft = %{
      socket.assigns.draft
      | hub_stop_ids: List.delete(socket.assigns.draft.hub_stop_ids, stop_id)
    }

    {:noreply, socket |> put_draft_struct(draft) |> assign_hub_choices()}
  end

  def handle_event("remove_hub", _params, socket), do: {:noreply, socket}

  # --- the riders section ------------------------------------------------------

  # The prototype's ADA preset: the eligibility wording and the next-day rule
  # 49 CFR 37.131(b) describes, applied to the service-wide rule.
  @impl true
  def handle_event("ada_preset", _params, socket) do
    draft = %{socket.assigns.draft | riders: :registered, eligibility: @ada_eligibility}

    {:noreply, put_draft_struct(socket, put_main_rule(draft, @ada_rule))}
  end

  # --- the exports section -----------------------------------------------------

  # The realtime answer is the organization's, not the service's, so it is
  # written at once through the same context the Settings page will use and
  # never dirties this page's draft.
  @impl true
  def handle_event("set_realtime", %{"realtime_source" => source}, socket)
      when is_binary(source) do
    case ExportDefaults.update(socket.assigns.current_organization.id, %{
           realtime_source: source
         }) do
      {:ok, defaults} ->
        {:noreply, assign(socket, :export_defaults, defaults)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn’t save your realtime answer. Try again.")}
    end
  end

  def handle_event("set_realtime", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("show_export_details", _params, socket) do
    {:noreply, assign(socket, :export_details_open, true)}
  end

  @impl true
  def handle_event("close_export_details", _params, socket) do
    {:noreply, assign(socket, :export_details_open, false)}
  end

  # The header menu's way to the status controls: the hook focuses the heading
  # and the browser scrolls it into view.
  @impl true
  def handle_event("goto_status", _params, socket) do
    {:noreply, push_event(socket, "focus_scoped_target", %{id: "status-title"})}
  end

  # --- the status section ------------------------------------------------------

  @impl true
  def handle_event("deactivate", _params, socket) do
    {:noreply, assign(socket, :status_action, :deactivate)}
  end

  @impl true
  def handle_event("delete", _params, socket) do
    {:noreply, assign(socket, :status_action, :delete)}
  end

  @impl true
  def handle_event("cancel_status", _params, socket) do
    {:noreply, assign(socket, :status_action, nil)}
  end

  @impl true
  def handle_event("confirm_deactivate", _params, socket) do
    case set_active(socket, false) do
      {:ok, service} ->
        {:noreply, socket |> assign(:status_action, nil) |> apply_status(service)}

      {:error, message} ->
        {:noreply, socket |> assign(:status_action, nil) |> save_error(message)}
    end
  end

  @impl true
  def handle_event("reactivate", _params, socket) do
    case set_active(socket, true) do
      {:ok, service} -> {:noreply, apply_status(socket, service)}
      {:error, message} -> {:noreply, save_error(socket, message)}
    end
  end

  @impl true
  def handle_event("confirm_delete", _params, socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Flex.delete_service(organization_id, version_id, socket.assigns.service_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:status_action, nil)
         |> put_flash(:info, "Deleted #{socket.assigns.saved.name}.")
         |> push_navigate(to: version_list_path(version_id))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(:status_action, nil)
         |> save_error("This service was already deleted. Reload the page to see the list.")}

      {:error, :version_unavailable} ->
        {:noreply,
         socket
         |> assign(:status_action, nil)
         |> save_error("This version can’t be changed right now. Reload the page and try again.")}
    end
  end

  # --- the map and the version panel -----------------------------------------

  @impl true
  def handle_event("flex_map_ready", _params, socket) do
    case socket.assigns[:map] do
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
      if socket.assigns.dirty? do
        {:noreply, assign(socket, :pending_leave, version_list_path(version_id))}
      else
        socket = push_event(socket, "gtfs_version_selected", %{version_id: version_id})
        {:noreply, push_navigate(socket, to: version_list_path(version_id))}
      end
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
      if socket.assigns.dirty? do
        {:noreply, assign(socket, :pending_leave, version_list_path(version_id))}
      else
        {:noreply, push_navigate(socket, to: version_list_path(version_id))}
      end
    else
      {:noreply, socket}
    end
  end

  # --- rendering --------------------------------------------------------------

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
      <.service_loading :if={@service_state == :loading} />

      <.service_not_found
        :if={@service_state == :not_found}
        version_id={@current_gtfs_version.id}
      />

      <.service_unavailable :if={@service_state == :unavailable} />

      <div
        :if={@service_state == :ready}
        id="flex-service-page"
        phx-hook="DraftGuard"
        data-dirty={to_string(@dirty?)}
        data-depart-event="flex_depart"
        data-discard-message="Discard unsaved changes? Cancel to keep editing."
        data-focus-on-mount="svc-title"
        class={@dirty? && "pb-28"}
      >
        <.service_header
          service={@draft}
          status={@status}
          version_id={@current_gtfs_version.id}
        />

        <section :if={@live_action == :area} id="flex-service-area" class="mt-6">
          <.callout kind="info" title="Area editor">
            <p>
              Choosing where this service runs arrives in the next step. Nothing is stored before Save, and your unsaved edits are kept.
            </p>
            <div class="mt-3">
              <.button id="area-back" type="button" class="min-h-11" phx-click="back_to_service">
                Back to service
              </.button>
            </div>
          </.callout>
        </section>

        <div
          :if={@live_action == :show}
          class="mt-5 grid items-start gap-10 xl:grid-cols-[minmax(0,640px)_minmax(0,1fr)]"
        >
          <div class="grid min-w-0 gap-6">
            <.service_error_summary :if={@save_errors != []} errors={@save_errors} />

            <.callout
              :if={@save_error}
              id="flex-service-save-error"
              kind="error"
              title="Nothing was saved"
              tabindex="-1"
            >
              {@save_error}
            </.callout>

            <div
              :if={@stale?}
              id="flex-service-stale"
              role="alert"
              class="flex flex-wrap items-start justify-between gap-3 rounded-card border border-warning-line bg-warning-bg px-4 py-3 text-sm text-warning-fg"
            >
              <p class="flex items-start gap-2">
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4" />
                <span>
                  <strong class="font-[650]">
                    Someone else saved this service while you were editing.
                  </strong>
                  Your edits are kept but not saved.
                  <span :if={@stale_changes != []} class="block">
                    They changed: {Enum.join(@stale_changes, "; ")}.
                  </span>
                </span>
              </p>
              <div class="flex flex-wrap gap-2">
                <.button
                  id="stale-theirs"
                  type="button"
                  variant="secondary"
                  class="min-h-11"
                  phx-click="use_their_changes"
                >
                  Use their changes
                </.button>
                <.button
                  id="stale-both"
                  type="button"
                  variant="primary"
                  class="min-h-11"
                  phx-click="save_both_changes"
                >
                  Save both changes
                </.button>
              </div>
            </div>

            <.form
              for={@form}
              id="flex-service-form"
              novalidate
              phx-change="validate"
              phx-submit="save"
              class="grid min-w-0 gap-8"
            >
              <%!-- The reference orders the sections by how often staff change
              them: a detour's distance and stretch first, an area service's
              hours first. --%>
              <%= if @draft.kind == :detour do %>
                <.where_detour_section
                  form={@form}
                  service={@draft}
                  field_errors={@field_errors}
                  route_stop_choices={@route_stop_choices}
                  plan={@plan}
                  checks={@checks}
                />

                <.booking_section
                  form={@form}
                  service={@draft}
                  field_errors={@field_errors}
                  calendars={@calendars}
                  calendar_options={@calendar_options}
                  checks={@checks}
                />

                <.when_section
                  form={@form}
                  service={@draft}
                  field_errors={@field_errors}
                  calendars={@calendars}
                  calendar_rows={@calendar_rows}
                  calendar_options={@calendar_options}
                  trip_counts={@trip_counts}
                  version_id={@current_gtfs_version.id}
                  today={@today}
                  checks={@checks}
                />
              <% else %>
                <.when_section
                  form={@form}
                  service={@draft}
                  field_errors={@field_errors}
                  calendars={@calendars}
                  calendar_rows={@calendar_rows}
                  calendar_options={@calendar_options}
                  trip_counts={@trip_counts}
                  version_id={@current_gtfs_version.id}
                  today={@today}
                  checks={@checks}
                />

                <.booking_section
                  form={@form}
                  service={@draft}
                  field_errors={@field_errors}
                  calendars={@calendars}
                  calendar_options={@calendar_options}
                  checks={@checks}
                />

                <.where_area_section
                  service={@draft}
                  area_summaries={@area_summaries}
                  stop_choices={@stop_choices}
                  hub_options={@hub_options}
                  hub_pick={@hub_pick}
                  checks={@checks}
                />
              <% end %>

              <.riders_section
                form={@form}
                service={@draft}
                field_errors={@field_errors}
                checks={@checks}
              />

              <.exports_section
                service={@draft}
                plan={@plan}
                export_defaults={@export_defaults}
                status={@status}
              />

              <.status_section service={@draft} status_action={@status_action} />
            </.form>
          </div>

          <aside
            class="grid gap-4 self-start xl:sticky xl:top-4"
            aria-label="Rider preview and map"
          >
            <section
              aria-labelledby="preview-title"
              class="rounded-card border border-subtle bg-white"
            >
              <div class="border-b border-subtle px-4 py-2.5">
                <h2 id="preview-title" class="text-base font-bold text-strong">
                  What riders will see
                </h2>
                <p class="text-[13px] text-muted">
                  In the Transit app and trip planners built on OpenTripPlanner
                </p>
              </div>
              <div class="p-4">
                <.rider_preview service={@draft} calendars={@calendars} />
              </div>
            </section>

            <.service_map_card service={@draft} />
          </aside>
        </div>
      </div>

      <.save_bar
        :if={@service_state == :ready and @live_action == :show and @dirty?}
        service={@draft}
        saved={@saved}
        calendars={@calendars}
        saving={@saving}
      />

      <.export_details_drawer
        :if={@service_state == :ready}
        open={@export_details_open}
        service={@draft}
        plan={@plan}
        export_defaults={@export_defaults}
      />

      <.discard_dialog :if={@service_state == :ready} open={@pending_discard} />
      <.leave_dialog :if={@service_state == :ready} open={not is_nil(@pending_leave)} />
    </Layouts.app>
    """
  end

  # --- loading ----------------------------------------------------------------

  # One load for the whole page: the service and its areas, the readiness facts
  # the checks need, the version's calendars with their days and exceptions for
  # the hours editor, and the map payload. A connection the database drops is
  # the retryable state, never a crash: the editor's work is not on the server
  # yet and nothing about this read is stored.
  defp load_service(socket) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Flex.get_service(organization_id, version_id, socket.assigns.service_id) do
      {:ok, service} -> ready_socket(socket, organization_id, version_id, service)
      {:error, :not_found} -> assign(socket, :service_state, :not_found)
    end
  rescue
    DBConnection.ConnectionError -> assign(socket, :service_state, :unavailable)
  end

  defp ready_socket(socket, organization_id, version_id, service) do
    facts = Checks.version_facts(organization_id, version_id)
    calendars = Flex.calendars_map(organization_id, version_id)
    rows = calendar_rows(organization_id, version_id)
    row_map = Map.new(rows, &{&1.service_id, &1})
    draft = normalize_rules(service)
    area_geojson = area_geojson(service)
    summaries = area_summaries(organization_id, version_id, service, area_geojson)
    route_facts = Flex.route_facts(organization_id, version_id, service)
    stop_choices = Flex.stop_choices(organization_id, version_id)

    others =
      organization_id
      |> Flex.list_services(version_id)
      |> Enum.reject(&(&1.id == service.id))

    socket
    |> assign(:service_state, :ready)
    |> assign(:saved, service)
    |> assign(:draft, draft)
    |> assign(:form, to_form(FlexService.changeset(draft, %{}), as: :service))
    |> assign(:dirty?, false)
    |> assign(:stale?, false)
    |> assign(:stale_changes, [])
    |> assign(:saving, false)
    |> assign(:facts, facts)
    |> assign(:others, others)
    |> assign(:calendars, calendars)
    |> assign(:calendar_rows, row_map)
    |> assign(
      :calendar_options,
      FlexComponents.calendar_options(calendars, row_map, service_calendar_ids(service))
    )
    |> assign(:stop_choices, stop_choices)
    |> assign(:route_stop_choices, route_facts.stops)
    |> assign(:trip_counts, route_facts.trip_counts)
    |> assign(:area_summaries, summaries)
    |> assign(:today, today(organization_id, version_id))
    |> assign(:area_geojson, area_geojson)
    |> assign(:map, Flex.service_map_payload(organization_id, version_id, service))
    |> assign(:export_defaults, ExportDefaults.get(organization_id))
    |> assign(:plan, plan(organization_id, version_id, draft, area_geojson, summaries))
    |> assign(:export_details_open, false)
    |> assign(:status_action, nil)
    |> assign(:save_errors, [])
    |> assign(:field_errors, %{})
    |> assign(:save_error, nil)
    |> assign(:pending_discard, false)
    |> assign(:pending_leave, nil)
    |> assign_hub_choices()
    |> assign_checks()
  end

  defp calendar_rows(organization_id, version_id) do
    case Calendars.list_calendars(organization_id, version_id) do
      {:ok, rows} -> rows
      {:error, :not_found} -> []
    end
  end

  # The agency-local date the Calendars pages use, so "next days without
  # service" is the same day the calendars list shows.
  defp today(organization_id, version_id) do
    DisplayClock.today(organization_id, version_id).date
  rescue
    # A version whose timezone cannot be resolved still shows its service days;
    # the exception line is the only thing the clock is needed for.
    _error -> nil
  end

  # Every calendar a stored field of the service names, so an hours row whose
  # calendar left the version still has an option of its own.
  defp service_calendar_ids(service) do
    service.hours
    |> Enum.map(& &1.service_id)
    |> Kernel.++(Enum.map(service.booking_rules, & &1.service_id))
    |> Enum.uniq()
  end

  defp area_geojson(service) do
    service.areas |> Enum.map(& &1.id) |> Geometry.get_geojson()
  end

  # Each area's rider-facing summary: how big it is, and what is inside it. A
  # stored polygon is measured directly; a `:route_distance` area has no stored
  # geometry, so the page derives it from the version's current shapes exactly
  # as the export will (AC-11), and an area whose geometry cannot be derived
  # yet keeps a nil size rather than a wrong one.
  defp area_summaries(organization_id, version_id, service, area_geojson) do
    Enum.map(service.areas, fn area ->
      case area_geometry(area, area_geojson, organization_id, version_id) do
        {:ok, geojson} ->
          stats = Geometry.stats(organization_id, version_id, geojson)

          %{area: area, km2: stats.km2, stop_ids: stats.stop_ids, route_ids: stats.route_ids}

        :error ->
          %{area: area, km2: nil, stop_ids: [], route_ids: []}
      end
    end)
  end

  defp area_geometry(
         %FlexArea{source: :route_distance, route_ids: route_ids, distance_m: distance},
         _area_geojson,
         organization_id,
         version_id
       )
       when is_list(route_ids) and route_ids != [] and is_integer(distance) do
    Geometry.route_buffer(organization_id, version_id, route_ids, distance)
  end

  defp area_geometry(%FlexArea{id: id}, area_geojson, _organization_id, _version_id) do
    case Map.fetch(area_geojson, id) do
      {:ok, geojson} -> {:ok, geojson}
      :error -> :error
    end
  end

  # The draft's areas as the export's own builders read them, with the measured
  # size each summary showed so the plan's location row can state it.
  defp plan_areas(service, area_geojson, summaries) do
    km2 = Map.new(summaries, &{&1.area.id, &1.km2})

    Enum.map(service.areas, fn area ->
      %{area: area, geojson: Map.get(area_geojson, area.id), km2: Map.get(km2, area.id)}
    end)
  end

  defp plan(organization_id, version_id, service, area_geojson, summaries) do
    FlexExport.plan(
      organization_id,
      version_id,
      service,
      plan_areas(service, area_geojson, summaries)
    )
  end

  # The connecting-stop select offers every stop the version has that is not
  # already a connecting stop, and keeps its choice when the options change.
  defp assign_hub_choices(socket) do
    options = hub_options(socket.assigns.stop_choices, socket.assigns.draft.hub_stop_ids)

    pick =
      case socket.assigns.hub_pick do
        nil -> options |> List.first() |> then(&(&1 && elem(&1, 1)))
        current -> if Enum.any?(options, &(elem(&1, 1) == current)), do: current, else: nil
      end

    socket
    |> assign(:hub_options, options)
    |> assign(:hub_pick, pick || options |> List.first() |> then(&(&1 && elem(&1, 1))))
  end

  defp hub_options(stop_choices, hub_stop_ids) do
    hubs = MapSet.new(hub_stop_ids)
    Enum.reject(stop_choices, fn {_name, stop_id} -> MapSet.member?(hubs, stop_id) end)
  end

  defp assign_checks(socket) do
    checks = Checks.run(socket.assigns.draft, socket.assigns.facts, socket.assigns.others)

    socket
    |> assign(:checks, checks)
    |> assign(:status, Checks.status(socket.assigns.draft, checks))
  end

  # --- the draft ---------------------------------------------------------------

  # A change event answers with the editor's answers applied to the draft. The
  # changeset is the schema's own, so a phone number or a time the version
  # refuses is refused here too; the page shows the answers as typed and only
  # the failed save lists them as errors.
  defp put_draft(socket, params) do
    previous = socket.assigns.draft

    params =
      params
      |> merge_draft_rows(previous)
      |> normalize_params(previous)

    draft =
      previous
      |> FlexService.changeset(params)
      |> Ecto.Changeset.apply_changes()
      |> apply_page_rules(previous)

    put_draft_struct(socket, draft)
  end

  # The submitted rows, completed from the draft.
  #
  # Ecto builds one change per parameter whose data is a fresh embedded struct,
  # so a field the form does not render (the area of a service with one area,
  # the rule fields a booking type does not use) would come back empty and the
  # editor would lose an answer they never touched. Every row's own values are
  # merged under the submitted ones, so an answer the form shows stays the
  # editor's and an answer it does not show stays the draft's.
  defp merge_draft_rows(params, %FlexService{} = draft) do
    hours =
      draft.hours
      |> Enum.with_index()
      |> Map.new(fn {hour, index} ->
        {to_string(index), stringify(Map.take(hour, [:area_key, :service_id, :start, :end]))}
      end)

    rules =
      draft.booking_rules
      |> Enum.with_index()
      |> Map.new(fn {rule, index} ->
        {to_string(index), stringify(Map.take(rule, @rule_fields))}
      end)

    params
    |> Map.put("hours", merge_rows(hours, Map.get(params, "hours")))
    |> Map.put("booking_rules", merge_rows(rules, Map.get(params, "booking_rules")))
  end

  # One row at a time: the submitted row's answers win field by field, and the
  # draft's answers fill the fields the form never rendered.
  defp merge_rows(draft_rows, submitted) when is_map(submitted) do
    draft_rows
    |> Map.keys()
    |> Kernel.++(Map.keys(submitted))
    |> Enum.uniq()
    |> Map.new(fn index ->
      {index, Map.merge(Map.get(draft_rows, index, %{}), Map.get(submitted, index, %{}))}
    end)
  end

  defp merge_rows(draft_rows, _submitted), do: draft_rows

  defp put_draft_struct(socket, draft) do
    draft = normalize_rules(draft)
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    socket
    |> assign(:draft, draft)
    |> assign(:form, to_form(FlexService.changeset(draft, %{}), as: :service))
    |> assign(:save_errors, [])
    |> assign(:field_errors, %{})
    |> assign(:save_error, nil)
    |> assign(
      :plan,
      plan(
        organization_id,
        version_id,
        draft,
        socket.assigns.area_geojson,
        socket.assigns.area_summaries
      )
    )
    |> assign_hub_choices()
    |> assign(:dirty?, page_attrs(draft) != page_attrs(socket.assigns.saved))
    |> refresh_map_for(draft, socket.assigns.draft)
    |> assign_checks()
  end

  # The page always renders the service-wide rule first (its fields are the
  # three booking choices), with a placeholder when the service has none, and
  # the calendar-scoped rules after it in calendar order, so a rule's position
  # on screen is stable while the editor works.
  defp normalize_rules(%FlexService{} = service) do
    main = Enum.find(service.booking_rules, &is_nil(&1.service_id)) || %FlexBookingRule{}

    scoped =
      service.booking_rules
      |> Enum.reject(&is_nil(&1.service_id))
      |> Enum.sort_by(& &1.service_id)

    %{service | booking_rules: [main | scoped]}
  end

  # The service-wide rule with the preset's answers, keeping the rules scoped to
  # one calendar as they are.
  defp put_main_rule(%FlexService{booking_rules: []} = service, fields) do
    %{service | booking_rules: [struct(FlexBookingRule, fields)]}
  end

  defp put_main_rule(%FlexService{booking_rules: [main | scoped]} = service, fields) do
    %{service | booking_rules: [struct(main, fields) | scoped]}
  end

  # The status section's one write. A deactivation keeps the draft: the draft's
  # own fields are what the editor was working on, and only the row's `active`
  # flag and lock version move. A clean page reloads, so every derived read is
  # the stored one again.
  defp set_active(socket, active) do
    case Flex.set_active(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.service_id,
           active
         ) do
      {:ok, service} ->
        {:ok, service}

      {:error, :not_found} ->
        {:error, "This service was already deleted. Reload the page to see the list."}

      {:error, :stale} ->
        {:error,
         "Someone else saved this service while you were editing. Reload the page and try again."}

      {:error, :version_unavailable} ->
        {:error, "This version can’t be changed right now. Reload the page and try again."}
    end
  end

  defp apply_status(socket, %FlexService{} = stored) do
    if socket.assigns.dirty? do
      draft = %{
        socket.assigns.draft
        | active: stored.active,
          lock_version: stored.lock_version,
          updated_at: stored.updated_at
      }

      socket
      |> assign(:saved, stored)
      |> assign(:draft, draft)
      |> assign_checks()
    else
      load_service(socket)
    end
  end

  # The map card draws the service the draft describes. A detour field that
  # changes the derived zones (`route_id`, the stretch, the distance or the way
  # it is measured) rebuilds the same scoped payload the load built and sends it
  # to the hook; nothing else about the page needs a redraw. INV-1 holds: the
  # zones come from `Flex` and `Flex.Geometry`, never from SQL here.
  defp refresh_map_for(socket, draft, previous) do
    if draft.kind == :detour and
         detour_geometry_key(draft) != detour_geometry_key(previous) do
      payload =
        Flex.service_map_payload(
          socket.assigns.current_organization.id,
          socket.assigns.current_gtfs_version.id,
          draft
        )

      socket |> assign(:map, payload) |> push_event("flex_map:load", payload)
    else
      socket
    end
  end

  defp detour_geometry_key(service) do
    {
      service.route_id,
      service.first_stop_id,
      service.last_stop_id,
      service.distance_m,
      service.measure
    }
  end

  # The where and who-can-ride sections answer each other, the way the
  # prototype does: choosing ADA-only without a distance preselects the ¾ mile
  # paratransit minimum (AC-29), and choosing registered riders the first time
  # leaves the service out of the flex feed until the editor asks for it.
  defp apply_page_rules(draft, previous) do
    draft
    |> preselect_ada_distance(previous)
    |> reset_include_registered(previous)
  end

  defp preselect_ada_distance(
         %FlexService{kind: :detour, ada_only: true, distance_m: nil} = draft,
         %FlexService{ada_only: false}
       ),
       do: %{draft | distance_m: @ada_distance_m}

  defp preselect_ada_distance(draft, _previous), do: draft

  defp reset_include_registered(
         %FlexService{riders: :registered, include_registered: include} = draft,
         %FlexService{riders: previous_riders, include_registered: previous_include}
       )
       when previous_riders != :registered and include == previous_include,
       do: %{draft | include_registered: false}

  defp reset_include_registered(draft, _previous), do: draft

  # --- saving ------------------------------------------------------------------

  defp write_page(socket, loaded) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case Flex.save_service(
           organization_id,
           version_id,
           loaded,
           page_attrs(socket.assigns.draft),
           area_inputs(socket)
         ) do
      {:ok, saved} ->
        saved(socket, saved)

      {:error, %Ecto.Changeset{} = changeset} ->
        save_refused(socket, changeset)

      {:error, :stale} ->
        mark_stale(socket)

      {:error, :version_unavailable} ->
        save_error(
          socket,
          "This version can’t be changed right now. Reload the page and try again."
        )

      {:error, {:invalid_area, key, reason}} ->
        save_error(socket, "The area “#{key}” could not be saved: #{area_reason(reason)}.")
    end
  end

  defp saved(socket, saved) do
    socket
    |> assign(:saved, saved)
    |> assign(:draft, normalize_rules(saved))
    |> assign(:form, to_form(FlexService.changeset(saved, %{}), as: :service))
    |> assign(:dirty?, false)
    |> assign(:stale?, false)
    |> assign(:stale_changes, [])
    |> assign(:saving, false)
    |> assign(:save_errors, [])
    |> assign(:field_errors, %{})
    |> assign(:save_error, nil)
    |> assign_checks()
    |> put_flash(:info, "Saved #{saved.name}.")
  end

  # A refusal keeps the draft exactly as the editor left it, lists every problem
  # in the summary with a link to its control, and marks the controls the
  # changeset named. The form itself stays the draft's own: the refused
  # changeset's embedded rows are its replacement pairs, not the rows on screen,
  # so rendering them would double every hours row.
  defp save_refused(socket, changeset) do
    errors = save_error_list(changeset, socket.assigns.draft)

    socket
    |> assign(:saving, false)
    |> assign(:save_errors, errors)
    |> assign(
      :field_errors,
      Map.new(Enum.group_by(errors, &elem(&1, 0)), fn {id, items} ->
        {id, Enum.map(items, &elem(&1, 1))}
      end)
    )
    |> assign(:save_error, nil)
    |> push_event("focus_scoped_target", %{id: "flex-service-error-summary"})
  end

  defp mark_stale(socket) do
    case Flex.get_service(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           socket.assigns.service_id
         ) do
      {:ok, stored} ->
        socket
        |> assign(:stale?, true)
        |> assign(
          :stale_changes,
          RiderText.changes(socket.assigns.saved, stored, socket.assigns.calendars)
        )
        |> assign(:saving, false)

      {:error, :not_found} ->
        save_error(
          socket,
          "This service was deleted in another session. Your changes are kept here; reload the page to see the list."
        )
    end
  end

  defp save_error(socket, message) do
    socket
    |> assign(:saving, false)
    |> assign(:save_errors, [])
    |> assign(:save_error, message)
  end

  # The page's own fields as `Flex.save_service/5` reads them, with string keys
  # so the changeset's own `used_input?/2` reports each field the editor
  # answered. The placeholder main rule an unanswered service carries is not a
  # field an editor filled in, so it is not written.
  defp page_attrs(%FlexService{} = service) do
    %{
      "hours" =>
        Enum.map(service.hours, &stringify(Map.take(&1, [:area_key, :service_id, :start, :end]))),
      "booking_rules" =>
        service.booking_rules
        |> Enum.reject(&placeholder_rule?/1)
        |> Enum.map(&stringify(Map.take(&1, @rule_fields))),
      "phone" => service.phone,
      "phone_hours" => service.phone_hours,
      "booking_url" => service.booking_url,
      "info_url" => service.info_url,
      "note" => service.note,
      "riders" => service.riders,
      "eligibility" => service.eligibility,
      "include_registered" => service.include_registered
    }
    |> Map.merge(kind_attrs(service))
  end

  # The fields only one kind of service has: an area service's connecting stops,
  # and a detour service's distance, wording, measure, stretch, drop-off policy
  # and calendars. A field the page does not render keeps its stored value
  # because it is not in its kind's attrs at all.
  defp kind_attrs(%FlexService{kind: :area} = service) do
    %{"hub_stop_ids" => service.hub_stop_ids}
  end

  defp kind_attrs(%FlexService{kind: :detour} = service) do
    %{
      "distance_m" => service.distance_m,
      "wording" => service.wording,
      "measure" => service.measure,
      "first_stop_id" => service.first_stop_id,
      "last_stop_id" => service.last_stop_id,
      "dropoffs" => service.dropoffs,
      "ada_only" => service.ada_only,
      "calendar_service_ids" => service.calendar_service_ids,
      "band_start" => service.band_start,
      "band_end" => service.band_end
    }
  end

  defp kind_attrs(%FlexService{}), do: %{}

  defp placeholder_rule?(%FlexBookingRule{when: nil}), do: true
  defp placeholder_rule?(%FlexBookingRule{}), do: false

  defp stringify(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)

  # The draft's areas with the geometry the page read for them, so a save
  # carries every stored polygon back through `Flex.Geometry` unchanged. An area
  # without stored geometry (a `:route_distance` area) keeps none (R8).
  defp area_inputs(socket) do
    Enum.map(socket.assigns.draft.areas, fn area ->
      %{
        key: area.key,
        name: area.name,
        source: area.source,
        geojson: Map.get(socket.assigns.area_geojson, area.id),
        census_geoid: area.census_geoid,
        census_layer: area.census_layer,
        census_vintage: area.census_vintage,
        route_ids: area.route_ids,
        distance_m: area.distance_m
      }
    end)
  end

  defp area_reason(:not_polygon), do: "it is not a closed shape"
  defp area_reason(:too_many_vertices), do: "it has too many points"
  defp area_reason(:swapped_coordinates), do: "its coordinates look swapped"
  defp area_reason(:unreadable), do: "it could not be read"
  defp area_reason({:invalid, reason, _location}), do: to_string(reason)
  defp area_reason(reason), do: inspect(reason)

  # Every error the changeset holds, as `{control id, message}` pairs the summary
  # links to and the controls show inline.
  #
  # `traverse_errors/2` cannot be used for the embedded rows: casting a list of
  # parameters onto a stored embed list builds one change per stored row and one
  # per parameter, in that order, so its row indexes are not the row indexes the
  # form renders. The changes themselves say which parameter built them, so an
  # hours row is its parameter's position and a booking rule is the draft rule
  # with the same calendar.
  defp save_error_list(changeset, draft) do
    top =
      Enum.map(changeset.errors, fn {field, {message, _opts}} ->
        {field_control_id(field), message}
      end)

    (top ++ hours_error_items(changeset) ++ rule_error_items(changeset, draft))
    |> Enum.uniq()
  end

  defp field_control_id(field), do: Map.get(@field_control_ids, field, "service_#{field}")

  defp hours_error_items(changeset) do
    changeset.changes
    |> Map.get(:hours, [])
    |> Enum.filter(&(&1.action == :insert))
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, index} -> row_error_items("service_hours_#{index}", row) end)
  end

  defp rule_error_items(changeset, draft) do
    changeset.changes
    |> Map.get(:booking_rules, [])
    |> Enum.filter(&(&1.action == :insert))
    |> Enum.flat_map(fn row ->
      service_id = Ecto.Changeset.get_field(row, :service_id)

      case Enum.find_index(draft.booking_rules, &(&1.service_id == service_id)) do
        nil -> []
        index -> row_error_items("service_booking_rules_#{index}", row)
      end
    end)
  end

  defp row_error_items(id, changeset) do
    Enum.map(changeset.errors, fn {field, {message, _opts}} -> {"#{id}_#{field}", message} end)
  end

  # --- the form's answers ------------------------------------------------------

  # The answers as the schema reads them. A blank input is a cleared field, and
  # the answers the form states outside a field of their own (the phone line's
  # switch, the fields a booking type does not use, the detour band's mode and
  # the detour calendars) are set here, so the draft never keeps a value the
  # editor turned off.
  defp normalize_params(params, %FlexService{} = draft) do
    params
    |> normalize_phone_hours()
    |> normalize_rule_params()
    |> normalize_detour_params(draft)
  end

  defp normalize_detour_params(params, %FlexService{kind: :detour}) do
    params
    |> Map.put("calendar_service_ids", Map.get(params, "calendar_service_ids") || [])
    |> normalize_band()
  end

  defp normalize_detour_params(params, %FlexService{}), do: params

  # AC-29's time of day: the band's own two fields exist only while "Only at
  # certain times" is answered, and choosing "All day" clears them. A change
  # payload that never carried the mode (a programmatic caller) keeps the
  # band's own fields as submitted.
  defp normalize_band(params) do
    case Map.get(params, "band_mode") do
      "band" -> params
      "all" -> params |> Map.put("band_start", "") |> Map.put("band_end", "")
      _other -> params
    end
  end

  defp normalize_phone_hours(params) do
    case Map.get(params, "phone_hours_on") do
      "true" ->
        Map.put(params, "phone_hours", Map.get(params, "phone_hours") || @default_phone_hours)

      _other ->
        Map.put(params, "phone_hours", "")
    end
  end

  defp normalize_rule_params(params) do
    case Map.get(params, "booking_rules") do
      %{} = rules ->
        Map.put(
          params,
          "booking_rules",
          Map.new(rules, fn {index, rule} -> {index, clear_unused_rule_fields(rule)} end)
        )

      _other ->
        params
    end
  end

  # R7: each booking type uses its own fields. Switching a rule's type clears
  # the fields the new type does not use, so a rule never stores a deadline and
  # a horizon for booking types it no longer has.
  defp clear_unused_rule_fields(rule) when is_map(rule) do
    case Map.get(rule, "when") do
      "now" ->
        rule
        |> Map.drop(["minutes", "days", "by", "office_service_id"])
        |> Map.put("business_days", "false")

      "same_day" ->
        rule
        |> Map.drop(["days", "by", "office_service_id"])
        |> Map.put("business_days", "false")

      "earlier_day" ->
        Map.drop(rule, ["minutes"])

      _other ->
        rule
    end
  end

  defp clear_unused_rule_fields(rule), do: rule

  # The calendar a new hours row or a new calendar-scoped rule starts on: the
  # first option nothing else uses, so two rows never start on one calendar.
  defp next_calendar(socket, used) do
    used = used |> Enum.reject(&is_nil/1) |> MapSet.new()
    options = socket.assigns.calendar_options

    Enum.find_value(options, fn {_label, service_id} ->
      if MapSet.member?(used, service_id), do: nil, else: service_id
    end) || options |> List.first() |> then(&(&1 && elem(&1, 1)))
  end

  defp service_path(socket) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/flex/#{socket.assigns.service_id}"
  end

  defp version_list_path(version_id), do: ~p"/gtfs/#{version_id}/flex"
end

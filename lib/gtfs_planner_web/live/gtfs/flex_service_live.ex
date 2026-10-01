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

  Save calls `Flex.save_service/4` once with every field this page owns;
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
  it writes `ExportDefaults.update/3` at once, exactly as the Settings page
  step 26 will, and the service's own fields stay unsaved until Save.

  The approved policy source intake sits beside the hours and booking sections
  and is deliberately its own form (AC-2, AC-7, AC-12). The editor pastes the
  policy text their agency authorized, names it, records a revision if the
  document has one, and accepts it explicitly: acceptance is their statement
  that this is the authorized text, not an agency or legal certification. The
  server freezes it through `GtfsPlanner.Agents.Scope.with_source_snapshot/2`
  together with the service this page already loaded, and hands the returned
  context to `GtfsPlannerWeb.AgentPanel.set_context/2`, which is the only way
  the helper's pack is ever mounted here. The `flex_policy` pack mounts only
  after the scoped load succeeds, and every load rebinds the panel to the plain
  version context, so a replaced service, a discarded draft and a version
  switch all drop the accepted source and the conversation it belonged to.

  No part of the intake writes. A validation failure, an over-limit context and
  a helper that cannot read the service all leave the editor's text, the whole
  native draft and the one Save exactly where they were.
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.AgentComponents, only: [agent_panel: 1]
  import GtfsPlannerWeb.Gtfs.FlexComponents
  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Boundaries
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Checks
  alias GtfsPlanner.Gtfs.Flex.Export, as: FlexExport
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.Flex.RiderText
  alias GtfsPlanner.Gtfs.Flex.Assistant
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexBookingRule
  alias GtfsPlanner.Gtfs.FlexHours
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Versions
  alias GtfsPlannerWeb.AgentPanel
  alias GtfsPlannerWeb.Gtfs.FlexAreaEditorComponents
  alias GtfsPlannerWeb.Gtfs.FlexComponents
  alias GtfsPlannerWeb.Layouts

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  @permission_error "You no longer have permission to change this flex service. " <>
                      "Ask an organization administrator to restore your access."

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

  # The approved policy source this page freezes for the helper. The kind and
  # the payload keys are the `flex_policy` contract `Flex.Assistant.workspace/1`
  # and the pack's `authorize_context/1` both read, and the whole serialized
  # context is admitted against `Scope`'s own 65,536-byte bound.
  @flex_policy_snapshot_kind "flex_policy"
  @flex_policy_section "hours_booking"

  @flex_policy_too_large "The policy source does not fit in one helper answer of 65,536 bytes for the whole page. Shorten the policy above, or make the change yourself."

  @flex_policy_forbidden "Your access to flex services changed, so the helper stopped."

  @flex_policy_unavailable "This flex service is not available, so the helper cannot read it."

  @flex_policy_review_unavailable "This prepared change cannot be reviewed here yet. Nothing was applied."

  @flex_policy_invalid "The policy source was not accepted. Fix the fields it names."

  @flex_policy_review_stale "That prepared change is no longer current. Nothing was applied."

  # The three distances the area editor's routes panel offers, the first three
  # of the reference's `DISTANCES`; the reference's distance for an area service
  # is the general-public half-mile.
  @area_distance_choices [
    {"A few blocks (0.2 km)", 200},
    {"¼ mile (0.4 km)", 400},
    {"½ mile (0.8 km)", 800}
  ]

  # The one reason the editor's name field shows inline: the same sentence the
  # editor's header uses to keep "Use this area" disabled.
  @area_name_reason "Enter the area name riders see."

  # The ways the candidate area can be set, from the event's own strings.
  @area_sources %{
    "choose" => :choose,
    "town" => :town,
    "routes" => :routes,
    "draw" => :draw,
    "import" => :import
  }

  # Point editing (AC-12). The tolerance is roughly a village street: 30 m takes
  # the fine detail off a Census city limit without moving the boundary a rider
  # would notice, and every simplification keeps its topology and holes (R8). The
  # ring the editor accepts is R8's own 5,000-position cap, checked before the
  # ring reaches PostGIS.
  @area_simplify_tolerance_m 30
  @area_max_vertices 5_000
  @area_crossing_reason "The boundary crosses itself where the red mark is."
  @area_too_many_reason "This boundary has more than 5,000 points. Use Simplify to make it editable."

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
     |> allow_upload(:area_file,
       accept: ~w(.geojson .json),
       max_entries: 1,
       max_file_size: 5_000_000,
       auto_upload: true,
       progress: &handle_area_upload_progress/3
     )
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
     |> assign(:plan_zones, nil)
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
     |> assign(:pending_leave, nil)
     |> assign(:area_param, nil)
     |> assign(:area_key, nil)
     |> assign(:area_source, :choose)
     |> assign(:area_candidate, nil)
     |> assign(:area_name, "")
     |> assign(:area_name_form, to_form(%{"name" => ""}, as: :area))
     |> assign(:area_stats, nil)
     |> assign(:area_saved_stats, nil)
     |> assign(:area_overlaps, [])
     |> assign(:area_compare, nil)
     |> assign(:area_places, [])
     |> assign(:area_census_state, :idle)
     |> assign(:area_census_slow, false)
     |> assign(:area_census_failed, nil)
     |> assign(:area_stop_extent, nil)
     |> assign(:area_search, %{"name" => "", "state" => ""})
     |> assign(:area_routes, [])
     |> assign(:area_route_ids, [])
     |> assign(:area_distance, 800)
     |> assign(:area_distance_choices, [])
     |> assign(:area_file, nil)
     |> assign(:area_file_state, :idle)
     |> assign(:area_file_error, nil)
     |> assign(:area_upload_error, nil)
     |> assign(:area_error, nil)
     |> assign(:area_map_base, nil)
     |> assign(:area_map, nil)
     |> assign(:area_use_reason, nil)
     |> assign(:area_name_error, nil)
     |> assign(:area_mode, :pan)
     |> assign(:area_crossing, nil)
     |> assign(:area_vertices, nil)
     |> assign(:area_simplify_note, nil)
     |> assign(:area_editable, false)
     |> assign(:flex_policy_form, flex_policy_form(%{}))
     |> assign(:flex_policy_state, :empty)
     |> assign(:flex_policy_source, nil)
     |> assign(:flex_policy_refusal, nil)
     |> assign(:flex_policy_field_errors, %{})}
  end

  @impl true
  def handle_params(%{"service" => id} = params, _uri, socket) do
    socket = assign(socket, :service_id, id)

    socket =
      if socket.assigns.live_action == :area do
        assign(socket, :area_param, Map.get(params, "area"))
      else
        socket
      end

    # The first paint defers its read, so the disconnected render shows the
    # loading state and the connected mount runs the load once. A patch to the
    # page's own area action keeps the draft: nothing is re-read.
    if socket.assigns.service_state == :loading do
      send(self(), :load_flex_service)
      {:noreply, socket}
    else
      {:noreply, enter_or_leave_area(socket)}
    end
  end

  @impl true
  def handle_info(:load_flex_service, socket), do: {:noreply, load_service(socket)}

  # The Census picker's delayed spinner: a request that is still running after
  # 300 ms shows it, and a reply that already landed makes the flag harmless.
  @impl true
  def handle_info(:area_census_slow, socket),
    do: {:noreply, assign(socket, :area_census_slow, true)}

  def handle_info(_message, socket), do: {:noreply, socket}

  # --- the area editor's Census answers -----------------------------------------

  @impl true
  def handle_async(
        :area_census,
        {:ok, {:ok, %{geojson: geojson, geoid: geoid, layer: layer, vintage: vintage}}},
        socket
      ) do
    candidate = %{
      geojson: geojson,
      source: :census,
      census_geoid: geoid,
      census_layer: layer,
      census_vintage: vintage,
      route_ids: [],
      distance_m: nil
    }

    {:noreply,
     socket
     |> assign(:area_census_state, :ok)
     |> assign(:area_census_slow, false)
     |> put_area_name(pick_name(socket, geoid))
     |> put_area_candidate(candidate)}
  end

  def handle_async(:area_census, {:ok, {:ok, places}}, socket) when is_list(places) do
    {:noreply,
     socket
     |> assign(:area_places, places)
     |> assign(:area_census_state, :ok)
     |> assign(:area_census_slow, false)
     |> assign(:area_error, nil)}
  end

  def handle_async(:area_census, {:ok, {:error, :unavailable}}, socket) do
    {:noreply,
     socket
     |> assign(:area_census_state, :unavailable)
     |> assign(:area_census_slow, false)}
  end

  def handle_async(:area_census, {:ok, {:error, :not_found}}, socket) do
    {:noreply,
     socket
     |> assign(:area_census_state, :ok)
     |> assign(:area_census_slow, false)
     |> assign(
       :area_error,
       "The Census Bureau no longer publishes that boundary. Choose another place."
     )}
  end

  def handle_async(:area_census, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:area_census_state, :ok)
     |> assign(:area_census_slow, false)
     |> assign(
       :area_error,
       "That boundary could not be prepared for this area (#{inspect(reason)}). Choose another place."
     )}
  end

  def handle_async(:area_census, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:area_census_state, :unavailable)
     |> assign(:area_census_slow, false)}
  end

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

  # --- the area editor ---------------------------------------------------------

  # Both ways into the area editor patch to `:area` with the area they name
  # (`?area=<key>` or `?area=new`), which keeps the draft in the socket (CR-8).
  # The editor works on a candidate area and writes it into the draft only when
  # the editor chooses "Use this area"; the service page's Save is the one write.
  @impl true
  def handle_event("edit_area", %{"key" => key}, socket) when is_binary(key) do
    key =
      if Enum.any?(socket.assigns.draft.areas, &(&1.key == key)) do
        key
      else
        new_area_key(socket)
      end

    {:noreply, push_patch(socket, to: area_path(socket, key))}
  end

  def handle_event("edit_area", _params, socket) do
    {:noreply, push_patch(socket, to: area_path(socket, new_area_key(socket)))}
  end

  @impl true
  def handle_event("add_area", _params, socket) do
    {:noreply, push_patch(socket, to: area_path(socket, "new"))}
  end

  # The candidate a source has to offer. Choosing a source clears whatever the
  # editor was looking at, so the map, the stats and the comparison always
  # describe the panel on screen.
  @impl true
  def handle_event("choose_source", %{"source" => source}, socket) do
    case Map.fetch(@area_sources, source) do
      {:ok, source} -> {:noreply, put_area_source(socket, source)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("choose_source", _params, socket), do: {:noreply, socket}

  # The name field's own change event: it is outside the service form, so typing
  # a name never dirties or saves the service.
  @impl true
  def handle_event("area_name", %{"area" => %{"name" => name}}, socket) when is_binary(name) do
    {:noreply, put_area_name(socket, name)}
  end

  def handle_event("area_name", _params, socket), do: {:noreply, socket}

  # --- the area editor's creation routes ---------------------------------------

  @impl true
  def handle_event("census_search", %{"place_name" => name, "state_fips" => state}, socket) do
    name = if is_binary(name), do: String.trim(name), else: ""
    state = if is_binary(state), do: state, else: ""

    socket = assign(socket, :area_search, %{"name" => name, "state" => state})

    if name == "" or state == "" do
      {:noreply, assign(socket, :area_error, "Enter a place name and choose a state.")}
    else
      {:noreply,
       start_census(socket, {:search, name, state}, fn -> Boundaries.search(name, state) end)}
    end
  end

  @impl true
  def handle_event("census_pick", %{"geoid" => geoid}, socket) when is_binary(geoid) do
    case Enum.find(socket.assigns.area_places, &(&1.geoid == geoid)) do
      nil ->
        {:noreply, assign(socket, :area_error, "Choose a place from the list.")}

      place ->
        {:noreply,
         socket
         |> assign(:area_pick_place, place)
         |> start_census({:pick, place.layer, place.geoid}, fn ->
           Boundaries.land_boundary(place.layer, place.geoid)
         end)}
    end
  end

  def handle_event("census_pick", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("census_retry", _params, socket) do
    case socket.assigns.area_census_failed do
      {:pick, layer, geoid} ->
        {:noreply,
         start_census(socket, {:pick, layer, geoid}, fn ->
           Boundaries.land_boundary(layer, geoid)
         end)}

      {:search, name, state} ->
        {:noreply,
         start_census(socket, {:search, name, state}, fn -> Boundaries.search(name, state) end)}

      {:places, bbox} ->
        {:noreply, start_census(socket, {:places, bbox}, fn -> Boundaries.places_near(bbox) end)}

      _missing ->
        {:noreply, start_census_places(socket)}
    end
  end

  @impl true
  def handle_event("route_buffer", params, socket) when is_map(params) do
    route_ids =
      params
      |> Map.get("route_ids", [])
      |> List.wrap()
      |> Enum.filter(&(is_binary(&1) and known_area_route?(socket, &1)))

    distance =
      parse_distance(Map.get(params, "distance_m")) || socket.assigns.area_distance

    {:noreply, put_area_routes(socket, route_ids, distance)}
  end

  def handle_event("route_buffer", _params, socket), do: {:noreply, socket}

  # --- the area editor's file import -------------------------------------------

  # The upload's change event. The entry completes asynchronously
  # (`handle_area_upload_progress/3`), so this only asks for the file's own
  # errors to be rendered; the progress callback consumes the completed entry.
  @impl true
  def handle_event("validate_upload", _params, socket) do
    case uploaded_entries(socket, :area_file) do
      {[entry], []} -> {:noreply, consume_area_file(socket, entry)}
      {_entries, _errors} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_area_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :area_file, ref)}
  end

  def handle_event("cancel_area_upload", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("pick_feature", %{"feature" => index}, socket) when is_binary(index) do
    case Integer.parse(index) do
      {index, ""} -> {:noreply, pick_area_feature(socket, index)}
      _other -> {:noreply, socket}
    end
  end

  def handle_event("pick_feature", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("swap_coordinates", _params, socket) do
    case socket.assigns.area_file do
      %{contents: contents, name: name} ->
        with {:ok, swapped} <- Geometry.swap_coordinates(contents),
             {:ok, %{features: features, name_field: name_field}} <-
               Geometry.import_features(swapped) do
          [first | _rest] = features

          file = %{
            name: name,
            contents: Jason.encode!(swapped),
            features: features,
            name_field: name_field,
            pick: nil
          }

          {:noreply,
           socket
           |> assign(:area_file, file)
           |> assign(:area_file_error, nil)
           |> assign(:area_upload_error, nil)
           |> pick_area_feature(first.index)}
        else
          _error ->
            {:noreply,
             socket
             |> assign(:area_file, nil)
             |> assign(:area_file_error, :unreadable)
             |> assign(:area_error, nil)}
        end

      _missing ->
        {:noreply, assign(socket, :area_error, "Choose a file first.")}
    end
  end

  # --- using and leaving the candidate ------------------------------------------

  # "Use this area" is the one event that touches the draft: it writes the
  # candidate (or the area being edited) into `@draft.areas`, keeps the geometry
  # the editor normalized in `@area_geojson`, refreshes the summaries, the plan
  # and the map card that read the areas, and returns to the service page with
  # the page dirty. Still nothing is stored (CR-8).
  @impl true
  def handle_event("use_area", _params, socket) do
    case socket.assigns.area_use_reason do
      nil -> {:noreply, socket |> put_area_in_draft() |> push_patch(to: service_path(socket))}
      reason -> {:noreply, assign(socket, :area_error, reason)}
    end
  end

  @impl true
  def handle_event("cancel_area", _params, socket) do
    {:noreply, push_patch(socket, to: service_path(socket))}
  end

  # --- the area editor's point editing -------------------------------------------

  # The map's own edits (AC-12): the hook sends the ring it holds after a drag,
  # an insert, a removal or an arrow-key move, at most once per 300 ms burst. The
  # ring is normalized and measured on the server like any picked boundary, and
  # the answer is the crossing marker or its absence. Only the editor's own point
  # tools may write the candidate.
  @impl true
  def handle_event("flex_area_edited", params, socket) do
    if socket.assigns.area_mode in [:edit, :draw] do
      edited_ring(socket, params)
    else
      {:noreply, socket}
    end
  end

  # Pan, Edit points and Draw: which tool the map is in is the server's state, so
  # the toolbar, the panel and the map's own mode all come from one place.
  @impl true
  def handle_event("area_mode", %{"mode" => "edit"}, socket) do
    case editing_candidate(socket) do
      nil ->
        {:noreply, assign(socket, :area_error, no_candidate_reason(socket.assigns.area_source))}

      candidate ->
        # The mode is set before the measurement, so the payload the measurement
        # refreshes is the one that already leaves the candidate to the hook.
        socket =
          socket
          |> assign(:area_mode, :edit)
          |> assign(:area_crossing, nil)
          |> measure_candidate(candidate)

        {:noreply, push_area_mode(socket)}
    end
  end

  def handle_event("area_mode", %{"mode" => "pan"}, socket),
    do: {:noreply, set_area_mode(socket, :pan)}

  def handle_event("area_mode", _params, socket), do: {:noreply, socket}

  # Simplify runs on the server (AC-12) and answers with the ring the map
  # redraws: one undo entry for the hook, so Undo restores the detail.
  @impl true
  def handle_event("flex_area_simplify", _params, socket) do
    case socket.assigns.area_candidate do
      %{geojson: %{} = geojson} -> simplify_area(socket, geojson)
      _no_candidate -> {:noreply, assign(socket, :area_error, "Set the area first.")}
    end
  end

  # --- the where section -------------------------------------------------------

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
    case ExportDefaults.update(
           socket.assigns.current_organization.id,
           socket.assigns.current_user,
           %{
             realtime_source: source
           }
         ) do
      {:ok, defaults} ->
        {:noreply, assign(socket, :export_defaults, defaults)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Couldn’t save your realtime answer. Try again.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, @permission_error)}
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
    version_id = socket.assigns.current_gtfs_version.id

    case Flex.delete_service(AuditContext.from_assigns(socket.assigns), socket.assigns.service_id) do
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

      {:error, :forbidden} ->
        {:noreply,
         socket
         |> assign(:status_action, nil)
         |> save_error(@permission_error)}
    end
  end

  # --- the map and the version panel -----------------------------------------

  @impl true
  def handle_event("flex_map_ready", _params, socket) do
    payload =
      if socket.assigns.live_action == :area,
        do: socket.assigns[:area_map],
        else: socket.assigns[:map]

    case payload do
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

  # The source is the editor's own authorized text, so typing it never touches
  # the service draft and never dirties the page: this is not a service change.
  @impl true
  def handle_event("flex_policy_source_change", params, socket) do
    {:noreply, assign(socket, :flex_policy_form, flex_policy_form(flex_policy_params(params)))}
  end

  @impl true
  def handle_event("flex_policy_source", params, socket) do
    values = flex_policy_values(flex_policy_params(params))

    case flex_policy_errors(values) do
      {:ok, values} ->
        {:noreply, accept_flex_policy_source(socket, values)}

      {:error, errors} ->
        {:noreply, refuse_flex_policy_source(socket, values, errors, @flex_policy_invalid)}
    end
  end

  # The prepared card's own action, and the only way a review can be opened
  # (AC-7). The host verifies the intent the session hands back against the
  # source this page currently holds: the entry id is parsed, the command is
  # looked up through `Agents.prepared/3` on the session this panel holds, and
  # the command's source and context digests must equal the accepted snapshot's
  # own server-computed digests. A forged id, a stale entry, a replaced source
  # and a command for another service are therefore the same refusal, and none
  # of them reaches a surface (AC-1, AC-2).
  #
  # This step owns the intake, not the review: a command that passes the fence
  # is reported and applied by nothing, because only the native Save persists
  # (INV-1). Step 6 replaces the tail of this clause with the review the
  # `{:flex_policy, command}` map is built for.
  @impl true
  def handle_event("agent_review_prepared", %{"entry" => id}, socket) do
    with {entry_id, ""} <- Integer.parse(id),
         {:ok, %{command: {:flex_policy, command}}} <-
           Agents.prepared(
             socket.assigns.agent_session,
             socket.assigns.agent_conversation_id,
             entry_id
           ),
         true <- current_flex_policy_command?(socket, command) do
      {:noreply, assign(socket, :agent_notice, @flex_policy_review_unavailable)}
    else
      _stale_or_unknown ->
        {:noreply, assign(socket, :agent_notice, @flex_policy_review_stale)}
    end
  end

  def handle_event("agent_review_prepared", _params, socket) do
    {:noreply, assign(socket, :agent_notice, @flex_policy_review_stale)}
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
      <div id="flex-service-scope" class="ds-page">
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
          <%!-- The editor's own header replaces the service header while the
          editor is open, exactly as the reference's editor page has one header
          with the service name on the way back. --%>
          <.service_header
            :if={@live_action == :show}
            service={@draft}
            status={@status}
            version_id={@current_gtfs_version.id}
          />

          <div :if={@live_action == :area} id="flex-service-area" class="mt-2">
            <FlexAreaEditorComponents.editor_header
              service={@draft}
              title={@area_title}
              use_reason={@area_use_reason}
            />

            <div class="grid overflow-hidden rounded-card border border-subtle bg-white lg:grid-cols-[minmax(0,392px)_minmax(0,1fr)]">
              <div
                id="area-panel"
                class="order-2 min-w-0 bg-white px-4 py-5 sm:px-5 lg:order-none lg:max-h-[calc(100dvh-200px)] lg:overflow-y-auto lg:border-r lg:border-subtle"
              >
                <div class="grid gap-5">
                  <%= case @area_source do %>
                    <% :town -> %>
                      <FlexAreaEditorComponents.census_panel
                        places={@area_places}
                        state={@area_census_state}
                        slow?={@area_census_slow}
                        no_stops?={is_nil(@area_stop_extent)}
                        search_name={@area_search["name"]}
                        search_state={@area_search["state"]}
                        pick={@area_pick_place && @area_pick_place.geoid}
                        error={@area_error}
                      />
                    <% :routes -> %>
                      <FlexAreaEditorComponents.routes_panel
                        routes={@area_routes}
                        route_ids={@area_route_ids}
                        distance={@area_distance}
                        distance_choices={@area_distance_choices}
                        error={@area_error}
                      />
                    <% :draw -> %>
                      <FlexAreaEditorComponents.draw_panel error={@area_error} />
                    <% :import -> %>
                      <FlexAreaEditorComponents.import_panel
                        upload={@uploads.area_file}
                        upload_state={@area_file_state}
                        upload_error={@area_upload_error}
                        file_name={@area_file && @area_file.name}
                        file_error={@area_file_error}
                        features={(@area_file && @area_file.features) || []}
                        pick={@area_file && @area_file.pick}
                        name_field={@area_file && @area_file.name_field}
                      />
                    <% _choose -> %>
                      <FlexAreaEditorComponents.choose_panel error={@area_error} />
                  <% end %>

                  <FlexAreaEditorComponents.stats_panel
                    :if={@area_candidate}
                    candidate={@area_candidate}
                    name_form={@area_name_form}
                    name_error={@area_name_error}
                    stats={@area_stats}
                    overlaps={@area_overlaps}
                    compare={@area_compare}
                    stop_choices={@stop_choices}
                  />
                </div>
              </div>

              <div class="order-1 min-w-0 lg:order-none">
                <FlexAreaEditorComponents.area_map
                  mode={@area_mode}
                  source={@area_source}
                  editable={@area_editable}
                  vertices={@area_vertices}
                  crossing={@area_crossing}
                  simplify_note={@area_simplify_note}
                />
              </div>
            </div>
          </div>

          <div
            :if={@live_action == :show}
            class="mt-5 grid items-start gap-10 xl:grid-cols-[minmax(0,640px)_minmax(0,1fr)]"
          >
            <div class="grid min-w-0 gap-6">
              <.service_error_summary :if={@save_errors != []} errors={@save_errors} />

              <.message
                :if={@save_error}
                id="flex-service-save-error"
                kind="error"
                title="Nothing was saved"
                tabindex="-1"
              >
                {@save_error}
              </.message>

              <%!-- The save bar's Save changes is the view's one primary while the
              draft is dirty, which it always is when this shows, so both answers
              here are secondary. --%>
              <.message
                :if={@stale?}
                id="flex-service-stale"
                kind="warning"
                title="Someone else saved this service while you were editing."
              >
                Your edits are kept but not saved.
                <span :if={@stale_changes != []} class="block">
                  They changed: {Enum.join(@stale_changes, "; ")}.
                </span>
                <:action>
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
                      variant="secondary"
                      class="min-h-11"
                      phx-click="save_both_changes"
                    >
                      Save both changes
                    </.button>
                  </div>
                </:action>
              </.message>

              <.message
                :if={not @draft.active}
                id="flex-service-inactive"
                kind="neutral"
                title="This service is inactive."
              >
                Exports leave it out. Its setup is kept.
                <:action>
                  <.button
                    id="flex-service-reactivate"
                    type="button"
                    variant="secondary"
                    class="min-h-11"
                    phx-click="reactivate"
                  >
                    Reactivate service
                  </.button>
                </:action>
              </.message>

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

              <%!-- The source intake sits beside the hours and booking sections but is its
              own form: accepting a source is an editor decision about what the helper may
              read, never a field of the service draft, so it never dirties the page and
              only native Save persists anything (INV-1). --%>
              <.flex_policy_source_section
                form={@flex_policy_form}
                state={@flex_policy_state}
                refusal={@flex_policy_refusal}
                field_errors={@flex_policy_field_errors}
                source={@flex_policy_source}
                helper_open?={@agent_open?}
                service_name={@draft.name || @draft.key || "this service"}
              />
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

          <%!-- The panel's focus listener belongs to this persistent wrapper, not to the
          panel: the closing panel cannot own a handler that runs after its own removal,
          so the wrapper outlives both states of the panel. --%>
          <div id="flex-policy-helper-focus" phx-hook=".FlexPolicyHelperFocus" class="mt-6">
            <div :if={@agent_open?} class="flex min-w-0 xl:sticky xl:top-4">
              <.agent_panel
                id="agent-panel"
                title={@agent_title}
                intro={@agent_intro}
                examples={@agent_examples}
                scope_line={"Flex policy · " <> @current_gtfs_version.name}
                status={@agent_status}
                entries={@streams.agent_entries}
                form={@agent_form}
                notice={@agent_notice}
                entries_empty?={@agent_entries_empty?}
                review_label="Review prepared change"
              />
            </div>
          </div>

          <script :type={Phoenix.LiveView.ColocatedHook} name=".FlexPolicyHelperFocus">
            export default {
              mounted() {
                this.handleEvent("agent:focus", ({id}) => document.getElementById(id)?.focus())
              }
            }
          </script>
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
      </div>
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
    |> assign(:plan_zones, nil)
    |> assign(:export_details_open, false)
    |> assign(:status_action, nil)
    |> assign(:save_errors, [])
    |> assign(:field_errors, %{})
    |> assign(:save_error, nil)
    |> assign(:pending_discard, false)
    |> assign(:pending_leave, nil)
    |> assign(:area_routes, Flex.route_choices(organization_id, version_id))
    |> assign(:area_stop_extent, Flex.stop_extent(organization_id, version_id))
    |> assign(:area_distance_choices, @area_distance_choices)
    |> assign_hub_choices()
    |> assign_checks()
    |> reset_flex_policy()
    |> mount_flex_policy_panel(version_id)
    |> enter_or_leave_area()
  end

  # The helper panel is mounted only once the scoped service has loaded, so a
  # conversation can never be bound to a service this page has not read. A
  # reload of the same service (their changes, a discarded draft) re-binds the
  # panel to the plain version context, which drops any accepted source and the
  # conversation it belonged to.
  defp mount_flex_policy_panel(socket, version_id) do
    socket =
      if socket.assigns[:agent_pack_id] do
        socket
      else
        AgentPanel.mount(socket, "flex_policy")
      end

    AgentPanel.set_context(socket, Scope.context({:version, version_id}))
  end

  # A load is the boundary of the accepted source: the editor accepted text for
  # the service as it was, so a reload starts from no accepted source. The text
  # they typed is their own draft and is kept.
  defp reset_flex_policy(socket) do
    socket
    |> assign(:flex_policy_state, :empty)
    |> assign(:flex_policy_source, nil)
    |> assign(:flex_policy_refusal, nil)
    |> assign(:flex_policy_field_errors, %{})
    |> assign(
      :flex_policy_form,
      flex_policy_form(Map.take(socket.assigns.flex_policy_form.params, ~w(label revision text)))
    )
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

  defp area_geometry(%FlexArea{} = area, area_geojson, _organization_id, _version_id) do
    case Map.fetch(area_geojson, geojson_key(area)) do
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

  defp plan(organization_id, version_id, service, area_geojson, summaries, opts \\ []) do
    FlexExport.plan(
      organization_id,
      version_id,
      service,
      plan_areas(service, area_geojson, summaries),
      opts
    )
  end

  # A change event re-plans the draft on every keystroke. A detour's zones are
  # the plan's PostGIS work and move only with the fields
  # `detour_geometry_key/1` names, so they are derived again only when one of
  # those changes; a load clears the cache.
  defp plan_zones(socket, %FlexService{kind: :detour} = draft) do
    key = detour_geometry_key(draft)

    case socket.assigns.plan_zones do
      {^key, zones} ->
        {key, zones}

      _stale ->
        {key,
         FlexExport.plan_zones(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           draft
         )}
    end
  end

  defp plan_zones(_socket, _draft), do: nil

  defp zone_opts({_key, zones}), do: [zones: zones]
  defp zone_opts(nil), do: []

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
    zones = plan_zones(socket, draft)

    socket
    |> assign(:draft, draft)
    |> assign(:form, to_form(FlexService.changeset(draft, %{}), as: :service))
    |> assign(:save_errors, [])
    |> assign(:field_errors, %{})
    |> assign(:save_error, nil)
    |> assign(:plan_zones, zones)
    |> assign(
      :plan,
      plan(
        organization_id,
        version_id,
        draft,
        socket.assigns.area_geojson,
        socket.assigns.area_summaries,
        zone_opts(zones)
      )
    )
    |> assign_hub_choices()
    |> assign(
      :dirty?,
      draft_changed?(draft, socket.assigns.saved, socket.assigns.area_geojson)
    )
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
           AuditContext.from_assigns(socket.assigns),
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

      {:error, :forbidden} ->
        {:error, @permission_error}
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
    |> keep_calendar_order(previous)
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

  # The detour calendars arrive in the checkbox list's order, not the author's.
  # Keeping the stored order for the calendars that stay chosen stops an
  # unrelated edit from reading (and saving) as a reordered rider line.
  defp keep_calendar_order(
         %FlexService{kind: :detour, calendar_service_ids: chosen} = draft,
         %FlexService{kind: :detour, calendar_service_ids: stored}
       ) do
    kept = Enum.filter(stored, &(&1 in chosen))
    added = Enum.reject(chosen, &(&1 in stored))
    %{draft | calendar_service_ids: kept ++ added}
  end

  defp keep_calendar_order(draft, _previous), do: draft

  # --- saving ------------------------------------------------------------------

  defp write_page(socket, loaded) do
    case Flex.save_service(
           AuditContext.from_assigns(socket.assigns),
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

      {:error, :forbidden} ->
        save_error(socket, "Your edits are still on this page. " <> @permission_error)

      {:error, {:invalid_area, key, reason}} ->
        save_error(socket, "The area “#{key}” could not be saved: #{area_reason(reason)}.")
    end
  end

  defp saved(socket, saved) do
    saved_draft = normalize_rules(saved)
    geojson = Map.merge(socket.assigns.area_geojson, area_geojson(saved))

    areas_changed? =
      area_signature(socket.assigns.draft.areas, socket.assigns.area_geojson) !=
        area_signature(saved.areas, geojson)

    socket =
      socket
      |> assign(:saved, saved)
      |> assign(:area_geojson, geojson)
      |> assign(:stale?, false)
      |> assign(:stale_changes, [])
      |> assign(:saving, false)
      |> assign(:save_errors, [])
      |> assign(:field_errors, %{})
      |> assign(:save_error, nil)

    socket =
      if areas_changed? do
        put_areas_draft(socket, saved_draft)
      else
        socket
        |> assign(:draft, saved_draft)
        |> assign(:form, to_form(FlexService.changeset(saved_draft, %{}), as: :service))
        |> assign(:dirty?, false)
        |> assign_checks()
      end

    put_flash(socket, :info, "Saved #{saved.name}.")
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

  # The page's own fields as `Flex.save_service/4` reads them, with string keys
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
        geojson: Map.get(socket.assigns.area_geojson, geojson_key(area)),
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

  # --- the approved policy source -------------------------------------------------

  # The acceptance is explicit and the freeze is the server's: the text, its
  # label and its revision go into `Scope.with_source_snapshot/2` together with
  # the service this page already loaded, and the context that returns replaces
  # the panel's own. Nothing is written to the service, the version or an audit
  # row, and the draft is untouched (AC-2, AC-4).
  defp accept_flex_policy_source(socket, values) do
    socket = assign(socket, :flex_policy_form, flex_policy_form(values))

    case freeze_flex_policy_source(socket, values) do
      {:ok, context} ->
        socket
        |> assign(:flex_policy_state, :accepted)
        |> assign(:flex_policy_source, values)
        |> assign(:flex_policy_refusal, nil)
        |> assign(:flex_policy_field_errors, %{})
        |> AgentPanel.set_context(context)

      {:error, :too_large} ->
        refuse_flex_policy_source(socket, values, %{}, @flex_policy_too_large)

      {:error, reason} ->
        refuse_flex_policy_source(socket, values, %{}, flex_policy_refusal(reason))
    end
  end

  # Every refusal keeps the whole source text in the form and leaves the native
  # hours and booking fields exactly as they were: the helper is optional here
  # and only native Save persists anything (AC-12).
  defp refuse_flex_policy_source(socket, values, errors, refusal) do
    state = if refusal == @flex_policy_forbidden, do: :unavailable, else: :refused

    socket
    |> assign(:flex_policy_state, state)
    |> assign(:flex_policy_form, flex_policy_form(values))
    |> assign(:flex_policy_field_errors, errors)
    |> assign(:flex_policy_refusal, refusal)
    |> push_event("focus_form_error", %{
      form_id: "flex-policy-source-form",
      fallback_id: "flex-policy-source-refusal"
    })
  end

  # The saved fingerprint is frozen with the acceptance, so it is read through
  # the same scoped workspace the pack will read: a service that cannot be
  # scoped, or whose saved policy is incomplete, never becomes an accepted
  # source the helper then cannot answer for.
  defp freeze_flex_policy_source(socket, values) do
    service = socket.assigns.saved
    base = Scope.context({:version, socket.assigns.current_gtfs_version.id})

    with {:ok, workspace, _evidence} <-
           Assistant.workspace(flex_policy_scope(socket, base), service.id) do
      Scope.with_source_snapshot(base, %{
        kind: @flex_policy_snapshot_kind,
        payload: %{
          "service_id" => service.id,
          "section" => @flex_policy_section,
          "source" => %{
            "text" => values["text"],
            "label" => values["label"],
            "revision" => values["revision"],
            "accepted" => true
          },
          "saved_fingerprint" => workspace.fingerprint
        }
      })
    end
  end

  # The command is current only while the source that produced it is still the
  # one this page accepted, and only for the service this page loaded. Both
  # digests are the server's own: the snapshot's from
  # `Scope.with_source_snapshot/2`, the context's from `Scope.context_digest/1`
  # over the same context the panel now holds.
  defp current_flex_policy_command?(
         socket,
         %{source_digest: source_digest, context_digest: context_digest}
       ) do
    scope = flex_policy_scope(socket, socket.assigns.agent_context)

    case Scope.source_snapshot(scope) do
      %{kind: @flex_policy_snapshot_kind, payload: %{"service_id" => service_id}, digest: digest} ->
        service_id == socket.assigns.saved.id and digest == source_digest and
          Scope.context_digest(scope) == context_digest

      _no_source ->
        false
    end
  end

  # The scope every read on this page is authorized against: the host's own
  # organization, version, user and pack, with the version identity this page
  # already holds. `resource_context` is the plain version context for the
  # workspace read before acceptance, and the panel's current context for the
  # digest a command claims to belong to.
  defp flex_policy_scope(socket, resource_context) do
    %Scope{
      organization_id: socket.assigns.current_organization.id,
      gtfs_version_id: socket.assigns.current_gtfs_version.id,
      user_id: socket.assigns.current_user.id,
      user_email: socket.assigns.current_user.email,
      pack_id: "flex_policy",
      version_name: socket.assigns.current_gtfs_version.name,
      resource_context: resource_context
    }
  end

  defp flex_policy_errors(values) do
    errors =
      %{}
      |> put_error("label", blank?(values["label"]), "Name the policy document.")
      |> put_error("text", blank?(values["text"]), "Paste the authorized policy text.")
      |> put_error("label", too_long?(values["label"]), "Keep the name under 200 characters.")
      |> put_error(
        "revision",
        too_long?(values["revision"]),
        "Keep the revision under 200 characters."
      )

    if errors == %{}, do: {:ok, values}, else: {:error, errors}
  end

  defp put_error(errors, _field, false, _message), do: errors
  defp put_error(errors, field, true, message), do: Map.put(errors, field, message)

  defp blank?(value), do: is_binary(value) and String.trim(value) == ""

  defp too_long?(value), do: is_binary(value) and String.length(value) > 200

  # A form event arrives nested under the form name; a bare input event arrives
  # flat, exactly as the Calendars approval form handles it.
  defp flex_policy_params(params) do
    case params["flex_policy"] do
      nested when is_map(nested) -> Map.merge(params, nested)
      _other -> params
    end
  end

  defp flex_policy_values(params) do
    %{
      "label" => String.trim(to_string(params["label"] || "")),
      "revision" => String.trim(to_string(params["revision"] || "")),
      "text" => to_string(params["text"] || "")
    }
  end

  defp flex_policy_form(values) do
    defaults = %{"label" => "", "revision" => "", "text" => ""}
    to_form(Map.merge(defaults, Map.take(values, ~w(label revision text))), as: :flex_policy)
  end

  # The pack's own refusal sentences reach this page unchanged, so the editor
  # reads the same words the assistant would say (AC-1, AC-6).
  defp flex_policy_refusal(:forbidden), do: @flex_policy_forbidden
  defp flex_policy_refusal(:unavailable), do: @flex_policy_unavailable

  defp flex_policy_refusal({:incomplete, :workspace_too_large}),
    do:
      "This service's saved policy does not fit in one helper answer. Shorten the policy on this " <>
        "page, or make the change yourself."

  defp flex_policy_refusal({:incomplete, {:missing_calendar, service_id}}),
    do:
      "The calendar #{service_id} this service's saved policy depends on is not in this version. " <>
        "Fix the hours or booking rule above first."

  defp flex_policy_refusal({:incomplete, _reason}),
    do: "This service's saved policy is incomplete, so the helper cannot read it yet."

  defp flex_policy_refusal(_reason),
    do: "The helper cannot read this service right now. Your text is unchanged."

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

  # --- the area editor's state -------------------------------------------------

  defp area_path(socket, key) do
    service_path(socket) <> "/area?area=" <> URI.encode_www_form(key)
  end

  defp new_area_key(socket), do: next_area_key(socket.assigns.draft.areas)

  defp next_area_key(areas) do
    used = MapSet.new(areas, & &1.key)

    Enum.find_value(1..1_000, "a1", fn number ->
      key = "a#{number}"
      if MapSet.member?(used, key), do: nil, else: key
    end)
  end

  defp enter_or_leave_area(%{assigns: %{live_action: :area, service_state: :ready}} = socket),
    do: enter_area(socket)

  defp enter_or_leave_area(socket), do: socket

  # Entering the editor starts on the choose panel with no candidate: the stored
  # area being edited is the comparison's baseline and stays on the map (muted),
  # and the editor builds a candidate from one of the four sources.
  defp enter_area(socket) do
    {key, stored} = area_target(socket.assigns.draft, socket.assigns.area_param)
    start = area_start(stored)

    socket
    |> assign(:area_key, key)
    |> assign(:area_title, area_title(stored))
    |> assign(:area_source, :choose)
    |> assign(:area_candidate, nil)
    |> assign(:area_name, start.name)
    |> assign(:area_name_form, area_name_form(start.name))
    |> assign(:area_saved_stats, saved_area_stats(socket, stored))
    |> assign(:area_stats, nil)
    |> assign(:area_overlaps, [])
    |> assign(:area_compare, nil)
    |> assign(:area_places, [])
    |> assign(:area_pick_place, nil)
    |> assign(:area_census_state, :idle)
    |> assign(:area_census_slow, false)
    |> assign(:area_census_failed, nil)
    |> assign(:area_search, %{"name" => "", "state" => ""})
    |> assign(:area_route_ids, start.route_ids)
    |> assign(:area_distance, start.distance)
    |> assign(:area_file, nil)
    |> assign(:area_file_state, :idle)
    |> assign(:area_file_error, nil)
    |> assign(:area_upload_error, nil)
    |> assign(:area_error, nil)
    |> assign(:area_name_error, nil)
    |> assign(:area_mode, :pan)
    |> assign(:area_crossing, nil)
    |> assign(:area_vertices, nil)
    |> assign(:area_simplify_note, nil)
    |> assign(:area_map_base, area_map_base(socket))
    |> refresh_area_map()
    |> assign_area_editable()
    |> assign_area_use_reason()
  end

  # The title and the starting values an area offers when the editor opens: the
  # area being edited keeps its name, and a `:route_distance` area opens on the
  # routes panel's own choices.
  defp area_title(%FlexArea{}), do: "Edit area"
  defp area_title(_stored), do: "Add area"

  defp area_start(%FlexArea{source: :route_distance} = stored) do
    %{name: stored.name, route_ids: stored.route_ids, distance: stored.distance_m}
  end

  defp area_start(%FlexArea{name: name}), do: %{name: name, route_ids: [], distance: 800}
  defp area_start(_stored), do: %{name: "", route_ids: [], distance: 800}

  defp saved_area_stats(_socket, nil), do: nil
  defp saved_area_stats(socket, %FlexArea{} = stored), do: area_stats(socket, stored)

  defp area_target(draft, "new"), do: {next_area_key(draft.areas), nil}

  defp area_target(draft, key) when is_binary(key) do
    case Enum.find(draft.areas, &(&1.key == key)) do
      nil -> {next_area_key(draft.areas), nil}
      area -> {area.key, area}
    end
  end

  defp area_target(draft, _missing) do
    case draft.areas do
      [first | _rest] -> {first.key, first}
      [] -> {next_area_key([]), nil}
    end
  end

  # The saved side of the comparison: the stored area measured exactly as the
  # where section measures it (a `:route_distance` area is derived first).
  defp area_stats(socket, %FlexArea{} = area) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    case area_geometry(area, socket.assigns.area_geojson, organization_id, version_id) do
      {:ok, geojson} ->
        stats = Geometry.stats(organization_id, version_id, geojson)
        %{km2: stats.km2, stop_ids: stats.stop_ids, route_ids: stats.route_ids}

      :error ->
        nil
    end
  end

  # The map the editor draws on. The base is the service card's own payload: the
  # service's areas, the other active services' areas as "other", the version's
  # route lines and the service's connecting stops. The editor re-roles the
  # service's own areas and adds the candidate, so one payload builder serves
  # both surfaces (INV-1: the payload carries GeoJSON only).
  defp area_map_base(socket) do
    payload = socket.assigns.map || %{areas: [], routes: [], stops: []}

    %{areas: payload.areas, routes: payload.routes, stops: payload.stops}
  end

  # The editor's map: the candidate (when there is one), the draft's own areas
  # from the geometry the editor holds, and every other active service's stored
  # areas muted. The draft's areas are drawn from `@area_geojson`, not from the
  # rows, because an area the editor has not saved yet has no row to read.
  #
  # While points are being edited the hook owns the ring, so the payload leaves
  # the candidate out and the draft's areas become the faint reference the
  # prototype draws its edited boundary over; otherwise the candidate is the
  # selected area and the draft's own areas sit behind it.
  defp area_payload(socket) do
    base = socket.assigns.area_map_base || %{routes: [], stops: []}
    candidate_areas = if socket.assigns.area_mode == :pan, do: candidate_areas(socket), else: []

    own_role =
      if candidate_areas == [] and socket.assigns.area_mode == :pan, do: "selected", else: "other"

    %{
      areas:
        candidate_areas ++
          draft_areas(socket, socket.assigns.draft, own_role) ++
          other_areas(socket, socket.assigns.draft),
      routes: base.routes,
      stops: base.stops
    }
  end

  # The service card's map while the draft holds areas the save has not written:
  # the draft's areas selected, the other active services' stored areas muted.
  defp service_card_payload(socket, service) do
    base = socket.assigns.area_map_base || socket.assigns.map || %{routes: [], stops: []}

    %{
      areas: draft_areas(socket, service, "selected") ++ other_areas(socket, service),
      routes: base.routes,
      stops: base.stops
    }
  end

  defp candidate_areas(socket) do
    case socket.assigns.area_candidate do
      %{geojson: %{} = geojson} -> [%{id: "area-candidate", geojson: geojson, role: "selected"}]
      _no_candidate -> []
    end
  end

  defp draft_areas(socket, service, role) do
    Enum.flat_map(service.areas, fn area ->
      case Map.fetch(socket.assigns.area_geojson, geojson_key(area)) do
        {:ok, geojson} ->
          [%{id: area.id || "draft-#{area.key}", geojson: geojson, role: role}]

        :error ->
          []
      end
    end)
  end

  defp other_areas(socket, service) do
    base = socket.assigns.area_map_base || %{areas: []}

    own =
      service.areas
      |> Enum.map(& &1.id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    base.areas
    |> Enum.reject(&MapSet.member?(own, &1.id))
    |> Enum.map(&Map.put(&1, :role, "other"))
  end

  defp refresh_area_map(socket) do
    payload = area_payload(socket)
    socket = assign(socket, :area_map, payload)

    # While points are being edited the hook owns the candidate's drawing, so the
    # payload is held for the next mode change instead of being pushed under the
    # user's hands, where it would re-fit the map on every edit.
    if socket.assigns.area_mode == :pan do
      push_event(socket, "flex_map:load", payload)
    else
      socket
    end
  end

  # The map's payload and its mode travel together when a tool changes: the hook
  # draws the ring it is editing, the payload leaves the candidate out, and
  # neither of them draws the candidate twice.
  defp push_area_payload(socket) do
    payload = area_payload(socket)
    socket |> assign(:area_map, payload) |> push_event("flex_map:load", payload)
  end

  # Which tool the map is in, and the ring that tool starts from. The server owns
  # the mode so the toolbar, the panel and the map cannot disagree about it.
  defp set_area_mode(socket, mode) do
    socket
    |> assign(:area_mode, mode)
    |> assign(:area_crossing, nil)
    |> push_area_mode()
  end

  defp push_area_mode(socket) do
    socket
    |> push_event("flex_map:mode", mode_payload(socket, socket.assigns.area_mode))
    |> push_area_payload()
  end

  defp mode_payload(socket, :edit) do
    case socket.assigns.area_candidate do
      %{geojson: %{} = geojson} ->
        ring = outer_ring(geojson)
        %{mode: "edit", ring: ring, vertices: ring_vertices(ring)}

      _no_candidate ->
        %{mode: "edit"}
    end
  end

  defp mode_payload(_socket, :draw), do: %{mode: "draw"}
  defp mode_payload(_socket, :pan), do: %{mode: "pan"}

  # A candidate a source produced belongs to the read-only map: picking a town, a
  # distance or a file while points are being edited hands the map back to the
  # payload. The editor's own edits measure directly and stay in their mode.
  defp leave_point_tools(socket) do
    if socket.assigns.area_mode == :pan, do: socket, else: set_area_mode(socket, :pan)
  end

  # --- the area editor's sources ------------------------------------------------

  defp put_area_source(socket, source) do
    socket =
      socket
      |> reset_area_source(source)
      |> assign(:area_source, source)
      |> assign(:area_error, nil)
      |> put_area_candidate(nil)
      |> push_event("focus_scoped_target", %{id: "area-panel-title"})

    case source do
      :town ->
        start_census_places(socket)

      :routes ->
        socket
        |> put_area_name("")
        |> put_area_routes(socket.assigns.area_route_ids, socket.assigns.area_distance)

      # Drawing is a tool on the map, so choosing it hands the map over to the
      # hook's draw mode; the other sources leave the hook's tools.
      :draw ->
        set_area_mode(socket, :draw)

      _other ->
        socket
    end
  end

  # Each source starts fresh: the picker's own results and the imported file's
  # features belong to the panel that produced them, not to the next one.
  defp reset_area_source(socket, :town), do: assign(socket, :area_places, [])

  defp reset_area_source(socket, :import) do
    socket
    |> assign(:area_file, nil)
    |> assign(:area_file_state, :idle)
    |> assign(:area_file_error, nil)
    |> assign(:area_upload_error, nil)
  end

  defp reset_area_source(socket, _source), do: socket

  # A version with no stops cannot bound an extent query, so the picker becomes
  # the name-and-state search (AC-10).
  defp start_census_places(socket) do
    case socket.assigns.area_stop_extent do
      nil ->
        socket
        |> assign(:area_census_state, :idle)
        |> assign(:area_census_failed, :search)

      bbox ->
        start_census(socket, {:places, bbox}, fn -> Boundaries.places_near(bbox) end)
    end
  end

  defp start_census(socket, failed, fun) do
    socket
    |> assign(:area_census_state, :loading)
    |> schedule_census_slow()
    |> assign(:area_census_failed, failed)
    |> start_async(:area_census, fun)
  end

  defp schedule_census_slow(socket) do
    Process.send_after(self(), :area_census_slow, 300)
    assign(socket, :area_census_slow, false)
  end

  defp pick_name(socket, geoid) do
    case socket.assigns.area_pick_place do
      %{geoid: ^geoid, name: name} when is_binary(name) -> name
      _other -> socket.assigns.area_name
    end
  end

  defp known_area_route?(socket, route_id),
    do: Enum.any?(socket.assigns.area_routes, &(&1.id == route_id))

  # The panel offers fixed distances; any other value, including one past the
  # schema's cap, keeps the current distance rather than reaching ST_Buffer.
  defp parse_distance(value) when is_integer(value) do
    if value > 0 and value <= FlexArea.max_distance_m(), do: value
  end

  defp parse_distance(value) when is_binary(value) do
    case Integer.parse(value) do
      {distance, ""} -> parse_distance(distance)
      _other -> nil
    end
  end

  defp parse_distance(_value), do: nil

  defp put_area_routes(socket, [], distance) do
    socket
    |> assign(:area_route_ids, [])
    |> assign(:area_distance, distance)
    |> put_area_candidate(nil)
  end

  defp put_area_routes(socket, route_ids, distance) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    socket = socket |> assign(:area_route_ids, route_ids) |> assign(:area_distance, distance)

    case Geometry.route_buffer(organization_id, version_id, route_ids, distance) do
      {:ok, geojson} ->
        candidate = %{
          geojson: geojson,
          source: :route_distance,
          route_ids: route_ids,
          distance_m: distance
        }

        socket |> put_area_candidate(candidate) |> maybe_name_corridor(route_ids)

      {:error, :empty} ->
        socket
        |> put_area_candidate(nil)
        |> assign(
          :area_error,
          "These routes have no shapes in this version yet, so there is nothing to follow."
        )

      {:error, {:missing_routes, missing}} ->
        socket
        |> put_area_candidate(nil)
        |> assign(
          :area_error,
          "These routes are not in this version: #{Enum.join(missing, ", ")}."
        )

      {:error, {:invalid, reason, _location}} ->
        socket
        |> put_area_candidate(nil)
        |> assign(
          :area_error,
          "The area around these routes is not a usable shape (#{reason}). Try another distance."
        )
    end
  end

  # The prototype names a route buffer after the route the editor measured from,
  # and renames one already named after a corridor; a name the editor typed is
  # left alone, so the where section has a name to show before the editor types
  # one.
  defp maybe_name_corridor(socket, route_ids) do
    name = String.trim(socket.assigns.area_name)

    if name == "" or String.contains?(name, "corridor") do
      names =
        socket.assigns.area_routes
        |> Enum.filter(&(&1.id in route_ids))
        |> Enum.map(&(&1.long_name || &1.name))

      put_area_name(socket, Enum.join(names, " and ") <> " corridor")
    else
      socket
    end
  end

  # --- the area editor's imported file -----------------------------------------

  # The upload is set with `auto_upload: true`, so choosing a file parses it
  # without a second action; this callback runs as the entry completes.
  defp handle_area_upload_progress(:area_file, entry, socket) do
    socket = if entry.done?, do: consume_area_file(socket, entry), else: socket
    {:noreply, socket}
  end

  defp consume_area_file(socket, entry) do
    # `consume_uploaded_entry/3` unwraps one `{:ok, value}` layer, so the
    # callback carries the read's own result as its value.
    case consume_uploaded_entry(socket, entry, fn %{path: path} -> {:ok, File.read(path)} end) do
      {:ok, contents} ->
        put_area_file(socket, entry.client_name, contents)

      {:error, _reason} ->
        socket
        |> assign(:area_file, nil)
        |> assign(:area_file_state, :failed)
        |> assign(:area_upload_error, "The file could not be read. Choose it again.")
    end
  end

  defp put_area_file(socket, name, contents) do
    case Geometry.import_features(contents) do
      {:ok, %{features: [first | _rest] = features, name_field: name_field}} ->
        file = %{
          name: name,
          contents: contents,
          features: features,
          name_field: name_field,
          pick: nil
        }

        socket
        |> assign(:area_file, file)
        |> assign(:area_file_state, :idle)
        |> assign(:area_file_error, nil)
        |> assign(:area_upload_error, nil)
        |> pick_area_feature(first.index)

      {:error, :unreadable} ->
        socket
        |> assign(:area_file, nil)
        |> assign(:area_file_state, :failed)
        |> assign(:area_file_error, :unreadable)

      {:error, reason} ->
        # A file that offered no area (or a swapped one) is kept by its bytes
        # alone: `swap_coordinates/1` reads them, and the panel renders the
        # file's own problem without a candidate.
        file = %{name: name, contents: contents, features: [], name_field: nil, pick: nil}

        socket
        |> assign(:area_file, file)
        |> assign(:area_file_state, :idle)
        |> assign(:area_file_error, reason)
    end
  end

  defp pick_area_feature(socket, index) do
    file = socket.assigns.area_file
    feature = file && Enum.find(file.features, &(&1.index == index))

    case feature && Geometry.normalize(feature.geojson) do
      {:ok, %{geojson: geojson}} ->
        candidate = %{
          geojson: geojson,
          source: :file,
          route_ids: [],
          distance_m: nil,
          file_name: file.name
        }

        socket
        |> assign(:area_file, %{file | pick: index})
        |> put_area_name(feature.name)
        |> put_area_candidate(candidate)

      {:error, reason} ->
        assign(
          socket,
          :area_error,
          "That area could not be used: #{area_reason(reason)}."
        )

      _no_feature ->
        socket
    end
  end

  # --- the candidate ------------------------------------------------------------

  # A candidate a source produced (a place, a route distance, a file): measured,
  # and then the map back in the payload's hands.
  defp put_area_candidate(socket, candidate) do
    socket |> measure_candidate(candidate) |> leave_point_tools()
  end

  # The candidate's own measurements: the area in km², the stops inside it, the
  # routes serving them, the overlap with other active services and the
  # comparison with the saved area (AC-14, FH-7). The map's own edits measure the
  # same way and stay in their mode, so this half is the one both paths share.
  defp measure_candidate(socket, candidate) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id

    {stats, overlaps, compare} =
      case candidate do
        %{geojson: %{} = geojson} ->
          measured = Geometry.stats(organization_id, version_id, geojson)

          stats = %{km2: measured.km2, stop_ids: measured.stop_ids, route_ids: measured.route_ids}

          overlaps =
            Geometry.overlaps(organization_id, version_id, geojson, socket.assigns.service_id)

          compare =
            case socket.assigns.area_saved_stats do
              nil -> nil
              saved -> Geometry.compare(saved, stats)
            end

          {stats, overlaps, compare}

        _no_candidate ->
          {nil, [], nil}
      end

    socket
    |> assign(:area_candidate, candidate)
    |> assign(:area_stats, stats)
    |> assign(:area_overlaps, overlaps)
    |> assign(:area_compare, compare)
    |> assign(:area_vertices, candidate_vertices(candidate))
    |> assign(:area_error, nil)
    |> refresh_area_map()
    |> assign_area_editable()
    |> assign_area_use_reason()
  end

  # The ring a point editor starts from: the candidate on screen, or the stored
  # area the editor opened on, with its own name, source and provenance.
  defp editing_candidate(socket) do
    case socket.assigns.area_candidate do
      %{geojson: %{}} = candidate -> candidate
      _no_candidate -> stored_candidate(socket)
    end
  end

  defp stored_candidate(socket) do
    with %FlexArea{} = stored <-
           Enum.find(socket.assigns.draft.areas, &(&1.key == socket.assigns.area_key)),
         {:ok, %{} = geojson} <- Map.fetch(socket.assigns.area_geojson, geojson_key(stored)) do
      %{
        geojson: geojson,
        source: stored.source,
        census_geoid: stored.census_geoid,
        census_layer: stored.census_layer,
        census_vintage: stored.census_vintage,
        route_ids: stored.route_ids,
        distance_m: stored.distance_m
      }
    else
      _no_stored_area -> nil
    end
  end

  # The candidate an edit works on: the geometry changes, the source and the
  # provenance stay, so a moved Census boundary still says where it came from and
  # a boundary drawn from scratch starts as a drawn area.
  defp edited_candidate(socket) do
    case socket.assigns.area_candidate do
      %{geojson: %{}} = candidate -> candidate
      _no_candidate -> %{geojson: nil, source: :drawn, route_ids: [], distance_m: nil}
    end
  end

  # The first polygon's outer ring; the R8 output is always a MultiPolygon and a
  # derived area may be a Polygon.
  defp outer_ring(%{"type" => "MultiPolygon", "coordinates" => [[ring | _holes] | _rest]})
       when is_list(ring),
       do: ring

  defp outer_ring(%{"type" => "Polygon", "coordinates" => [ring | _holes]}) when is_list(ring),
    do: ring

  defp outer_ring(_geojson), do: nil

  # The edited ring replaces the first polygon's outer ring; every hole and every
  # other part stays, so editing cannot drop the water a Census boundary left out
  # or a second part of an imported file.
  defp replace_outer_ring(
         %{"type" => "MultiPolygon", "coordinates" => [[_ring | holes] | rest]},
         ring
       ),
       do: %{"type" => "MultiPolygon", "coordinates" => [[ring | holes] | rest]}

  defp replace_outer_ring(%{"type" => "Polygon", "coordinates" => [_ring | holes]}, ring),
    do: %{"type" => "Polygon", "coordinates" => [ring | holes]}

  defp replace_outer_ring(_geojson, ring),
    do: %{"type" => "Polygon", "coordinates" => [ring]}

  # The positions a ring holds, its repeated closing vertex not counted.
  defp ring_vertices([first | _rest] = ring) do
    if List.last(ring) == first, do: length(ring) - 1, else: length(ring)
  end

  defp ring_vertices(_ring), do: 0

  defp candidate_vertices(%{geojson: %{} = geojson}) do
    case outer_ring(geojson) do
      ring when is_list(ring) -> ring_vertices(ring)
      _no_ring -> nil
    end
  end

  defp candidate_vertices(_candidate), do: nil

  # A ring the hook may have pushed: closed, a triangle or more, every position
  # [lon, lat] inside GeoJSON's own range and under R8's vertex cap. Anything else
  # never reaches PostGIS. The mode above already fences who may push at all.
  defp edited_ring(socket, %{"ring" => ring}) when is_list(ring) do
    cond do
      not editable_ring?(ring) ->
        {:noreply, socket}

      length(ring) > @area_max_vertices ->
        {:noreply, assign(socket, :area_error, @area_too_many_reason)}

      true ->
        accept_edited_ring(socket, ring)
    end
  end

  defp edited_ring(socket, _params), do: {:noreply, socket}

  defp editable_ring?([_first | _rest] = ring) do
    length(ring) >= 4 and Enum.all?(ring, &editable_position?/1) and
      List.first(ring) == List.last(ring)
  end

  defp editable_ring?(_ring), do: false

  defp editable_position?([lon, lat | _rest]),
    do: is_number(lon) and is_number(lat) and abs(lon) <= 180 and abs(lat) <= 90

  defp editable_position?(_position), do: false

  # The server's verdict on the edited ring. A valid one becomes the candidate
  # (the normalized geometry, measured for the panel and the comparison) and
  # clears the map's marker; an invalid one keeps the last measurement, names the
  # crossing point and disables "Use this area" with the reason.
  defp accept_edited_ring(socket, ring) do
    base = edited_candidate(socket)

    case Geometry.normalize(replace_outer_ring(base.geojson, ring)) do
      {:ok, %{geojson: geojson}} ->
        {:noreply,
         socket
         |> assign(:area_crossing, nil)
         |> assign(:area_simplify_note, nil)
         |> measure_candidate(%{base | geojson: geojson})
         |> push_event("flex_map:crossing", %{lon: nil, lat: nil, reason: nil})}

      {:error, {:invalid, reason, [lon, lat]}} ->
        {:noreply,
         socket
         |> assign(:area_error, nil)
         |> assign(:area_crossing, %{lon: lon, lat: lat, reason: reason})
         |> assign(:area_vertices, ring_vertices(ring))
         |> assign(:area_simplify_note, nil)
         |> assign_area_use_reason()
         |> push_event("flex_map:crossing", %{lon: lon, lat: lat, reason: reason})}

      {:error, reason} ->
        {:noreply,
         assign(socket, :area_error, "That boundary can’t be used: #{area_reason(reason)}.")}
    end
  end

  defp simplify_area(socket, geojson) do
    before = socket.assigns.area_vertices || 0

    case Geometry.simplify(geojson, @area_simplify_tolerance_m) do
      {:ok, simplified} ->
        ring = outer_ring(simplified)
        vertices = ring_vertices(ring)

        socket =
          socket
          |> assign(:area_crossing, nil)
          |> assign(
            :area_simplify_note,
            "Simplified from #{before} to #{vertices} points. Undo restores the detail."
          )
          |> measure_candidate(%{edited_candidate(socket) | geojson: simplified})

        # The map redraws the simplified ring either way: as the ring the hook is
        # editing (with an undo entry) or, on the read-only map, as the payload.
        if socket.assigns.area_mode == :pan do
          {:noreply, push_area_payload(socket)}
        else
          {:noreply, push_event(socket, "flex_map:ring", %{ring: ring, vertices: vertices})}
        end

      {:error, {:invalid, reason, _location}} ->
        {:noreply,
         assign(socket, :area_error, "The boundary could not be simplified: #{reason}.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :area_error, "The boundary could not be simplified.")}
    end
  end

  defp assign_area_editable(socket),
    do: assign(socket, :area_editable, editing_candidate(socket) != nil)

  defp assign_area_use_reason(socket) do
    reason =
      cond do
        socket.assigns.area_crossing -> @area_crossing_reason
        not candidate_ready?(socket) -> no_candidate_reason(socket.assigns.area_source)
        String.trim(socket.assigns.area_name) == "" -> @area_name_reason
        true -> nil
      end

    name_error = if reason == @area_name_reason, do: reason

    socket
    |> assign(:area_use_reason, reason)
    |> assign(:area_name_error, name_error)
  end

  defp candidate_ready?(socket), do: match?(%{geojson: %{}}, socket.assigns.area_candidate)

  defp no_candidate_reason(:draw), do: "Draw the area on the map first."
  defp no_candidate_reason(:choose), do: "Choose how to set the area first."
  defp no_candidate_reason(:import), do: "Choose an area from the file first."
  defp no_candidate_reason(_source), do: "Set the area first."

  defp put_area_name(socket, name) do
    socket
    |> assign(:area_name, name)
    |> assign(:area_name_form, area_name_form(name))
    |> assign_area_use_reason()
  end

  defp area_name_form(name), do: to_form(%{"name" => name}, as: :area)

  # --- writing the candidate into the draft -------------------------------------

  # The one event that touches the draft: the candidate becomes an area of the
  # service (a new key, or the key being edited), with the geometry the editor
  # normalized held beside it until the service page's Save.
  defp put_area_in_draft(socket) do
    candidate = socket.assigns.area_candidate
    existing = Enum.find(socket.assigns.draft.areas, &(&1.key == socket.assigns.area_key))

    area = %{
      struct(existing || %FlexArea{}, %{
        key: socket.assigns.area_key,
        name: socket.assigns.area_name
      })
      | source: candidate.source,
        census_geoid: candidate[:census_geoid],
        census_layer: candidate[:census_layer],
        census_vintage: candidate[:census_vintage],
        route_ids: candidate[:route_ids] || [],
        distance_m: candidate[:distance_m]
    }

    areas =
      case existing do
        nil ->
          socket.assigns.draft.areas ++ [area]

        _existing ->
          Enum.map(socket.assigns.draft.areas, &if(&1.key == area.key, do: area, else: &1))
      end

    geojson = Map.put(socket.assigns.area_geojson, geojson_key(area), candidate.geojson)

    put_areas_draft(socket |> assign(:area_geojson, geojson), %{
      socket.assigns.draft
      | areas: areas
    })
  end

  # The geometry map is keyed by the stored area's id; an area the editor has
  # not saved yet has no id, so its key is the marker until the save gives it
  # one (the save's own refresh merges the stored id back in).
  defp geojson_key(%FlexArea{id: id, key: key}), do: id || {:new, key}

  # The draft's areas changed: the summaries, the plan and the map card all read
  # them, so they are rebuilt together (and `dirty?` counts the areas, so
  # "Use this area" asks for a Save).
  defp put_areas_draft(socket, draft) do
    organization_id = socket.assigns.current_organization.id
    version_id = socket.assigns.current_gtfs_version.id
    geojson = socket.assigns.area_geojson
    summaries = area_summaries(organization_id, version_id, draft, geojson)

    payload = service_card_payload(socket, draft)

    socket
    |> assign(:draft, draft)
    |> assign(:area_summaries, summaries)
    |> assign(:plan, plan(organization_id, version_id, draft, geojson, summaries))
    |> assign(:map, payload)
    |> assign(:form, to_form(FlexService.changeset(draft, %{}), as: :service))
    |> assign(:dirty?, draft_changed?(draft, socket.assigns.saved, geojson))
    |> assign_hub_choices()
    |> assign_checks()
    |> maybe_push_card_payload(payload)
  end

  # The mounted card already holds its hook, so a payload that changed under it
  # is pushed; in the editor the card is not on screen and the patch back to
  # `:show` mounts it with `@map` through the hook's own handshake.
  defp maybe_push_card_payload(socket, payload) do
    if socket.assigns.live_action == :show do
      push_event(socket, "flex_map:load", payload)
    else
      socket
    end
  end

  # The page is dirty when the fields it renders differ from the stored ones, or
  # when the areas do: adding an area is a change the Save has to write.
  defp draft_changed?(draft, saved, geojson) do
    page_attrs(draft) != page_attrs(saved) or
      area_signature(draft.areas, geojson) != area_signature(saved.areas, geojson)
  end

  defp area_signature(areas, geojson) do
    Enum.map(areas, fn area ->
      {area.key, area.name, area.source, area.census_geoid, area.census_layer,
       area.census_vintage, area.route_ids, area.distance_m, Map.get(geojson, geojson_key(area))}
    end)
  end

  defp service_path(socket) do
    ~p"/gtfs/#{socket.assigns.current_gtfs_version.id}/flex/#{socket.assigns.service_id}"
  end

  defp version_list_path(version_id), do: ~p"/gtfs/#{version_id}/flex"
end

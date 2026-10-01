defmodule GtfsPlannerWeb.Gtfs.StopsMapLive do
  @moduledoc """
  The Map view: the stop editing workspace on `/gtfs/:version/stops/map`.

  The List view answers "which stops are in this feed". The Map view answers
  "where is this stop, and what else is around it", which is the question the
  List view cannot answer at all — and it is the question every edit starts
  from, because a stop's place on the street is the thing being corrected.

  The page owns the server side of the map. `GtfsPlanner.Gtfs.StopsMap.load/2`
  reads the version in a fixed number of queries, the page turns that into the
  `display_payload/2` the hook draws, and the hook reports back the only two
  things the server cannot know: which stops are inside the current view, and
  whether the street basemap is there at all.

  ## What the hook reports

  - `stop_map_ready` — the canvas exists and the payload can be drawn.
  - `stop_map_bounds` — the current view, as south/west/north/east. The browse
    panel lists the stops inside it, so panning changes the list.
  - `map_unavailable` — Leaflet or the tile proxy failed. The list, the route
    lines and coordinate entry keep working; only the basemap is gone.
  - `place` — the hook reported a point the editor chose, by click or by Enter
    on the canvas. The point becomes the draft's position and is echoed back.
  - `pin_moved` — the editor dragged or nudged the pin. One report per change,
    and the point is echoed back the same way.

  The version's placement findings are read after the model rather than with
  it, so the panel lists its stops on the first paint and the disclosure fills
  in when the scan does. Each finding's action names a stop, and the map is
  asked to go to it — `stop_map:focus`, the same rule as a placement: a point
  that cannot be read is dropped rather than clamped.

  Each of these is idempotent and order-independent: the panel recomputes from
  the whole model rather than from deltas, so a report that arrives twice, or
  after the version changed, is answered from what the server holds now.

  ## The draft position is the server's

  The hook moves its pin the instant a pointer or a key moves it, because a
  drag that waits for a round trip lags the hand. What it moved to is the
  server's to answer: `place` and `pin_moved` both write `placement`, and the
  pin the browser draws is the one `push_map_mode/1` last echoed. A refused
  write therefore has nothing behind it — the next echo is the position the
  server still holds, and nothing was saved to leave behind (INV-4).
  """

  use GtfsPlannerWeb, :live_view

  import GtfsPlannerWeb.Gtfs.StopsMapComponents,
    only: [
      browse_panel: 1,
      browse_panel_loading: 1,
      first_use_panel: 1,
      add_panel: 1,
      created_panel: 1,
      edit_panel: 1,
      map_stage: 1,
      page_header: 1,
      search_field: 1,
      search_results: 1,
      stop_list: 1,
      checks_disclosure: 1
    ]

  import GtfsPlannerWeb.PlannerComponents, only: [message: 1]

  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Gtfs.StopNaming
  alias GtfsPlanner.Gtfs.StopPlacement
  alias GtfsPlanner.Gtfs.StopReferences
  alias GtfsPlanner.Gtfs.StopsMap
  alias GtfsPlannerWeb.Gtfs.StopsMapComponents
  require Logger

  on_mount {GtfsPlannerWeb.EnsureRole, :require_gtfs_access}

  # Lines are simplified to this tolerance before they reach the browser. The
  # step-10 budget measured 2.0 m dropping 77% of the points at a 10,000-stop
  # envelope, and a point that does not move the road on screen is a point the
  # editor cannot see. The spec's own rule for the tolerance is the same one:
  # what an editor can see on the map is the tolerance applied.
  @line_tolerance_m 2.0

  # The browse panel is a working list, not a search result: this is how many
  # stops it will show before it stops being a list an editor can read. The
  # prototype uses forty; the count is here rather than in the panel because it
  # is a decision about the model, not about the markup.
  @panel_limit 40

  # A search is an answer, not a list to read: the browse panel's forty rows say
  # "there is more here" and a result list does not. Six stops and four places
  # are the counts the prototype shows, and they are chosen so a screenful of
  # them still fits at 390 px.
  @search_stop_limit 6
  @search_place_limit 4

  # The form name the search field's params arrive under.
  @search_as :search

  # The form name the add form's params arrive under, and the draft's own fields.
  # The list is a whitelist: a param the draft does not name is not a field, so a
  # forged one cannot become an attribute of the stop that gets created.
  @add_as :stop
  @add_fields ~w(name desc code stop_id tts_stop_name stop_url wheelchair_boarding lat lon)

  # How close a stop has to be to the draft for its name to be worth offering as
  # an alternative to the streets. `StopNaming.suggestions/3` takes the names
  # rather than the coordinates on purpose, so the radius that finds them lives
  # with the query that finds them — here.
  @suggestion_neighbour_metres 30.0

  # How many of the nearest stops the fare zone line speaks for.
  @zone_neighbour_count 5

  # The form name the edit form's params arrive under, and the fields the panel
  # will read. The list is a whitelist for the same reason the add form's is: a
  # param the panel does not name is not a field, so a forged one cannot become
  # an attribute of the stop that gets saved.
  @edit_as :stop
  @edit_fields ~w(stop_name stop_desc stop_lat stop_lon stop_code wheelchair_boarding tts_stop_name stop_url)

  # The stop fields whose names the audit entry carries, mapped to the words the
  # conflict message uses. The message names what the other editor changed; the
  # audit row is the only record of that.
  @edit_field_words %{
    "stop_name" => "the name",
    "stop_desc" => "the description",
    "stop_lat" => "the position",
    "stop_lon" => "the position",
    "stop_code" => "the sign number",
    "wheelchair_boarding" => "wheelchair access",
    "tts_stop_name" => "the spoken name",
    "stop_url" => "the stop web page"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Stops & stations")
     |> assign(:user_roles, socket.assigns[:user_roles] || [])
     |> assign(:map_state, :loading)
     |> assign(:panel, :browse)
     |> assign(:model, nil)
     |> assign(:map_state_reason, nil)
     |> assign(:view_bounds, nil)
     |> assign(:selected_stop_id, nil)
     |> assign(:stops_state, :loading)
     |> assign(:placement, nil)
     |> assign(:scope_error, nil)
     |> assign(:checks, nil)
     |> assign(:checks_open, false)
     |> assign(:dismissed_checks, MapSet.new())
     |> assign_edit_state()
     |> assign_add_state()
     |> assign_search("", [], [], false)}
  end

  # Everything the edit panel owns, in one place, so every way into it — the
  # list, the search, the checks disclosure, the map, `?stop=` — starts from the
  # same empty state rather than from whatever the last stop left behind.
  defp assign_edit_state(socket) do
    socket
    |> assign(:edit_stop, nil)
    |> assign(:edit_baseline, nil)
    |> assign(:edit_errors, %{})
    |> assign(:edit_saving, false)
    |> assign(:edit_outcome, :none)
    |> assign(:edit_conflict, nil)
    |> assign(:edit_more_open?, false)
    |> assign(:edit_tech_open?, false)
    |> assign(:edit_usage, nil)
    |> assign(:edit_zone_name, nil)
    |> assign(:edit_usage_for, nil)
    |> assign(:edit_loaded_updated_at, nil)
    |> assign(:edit_dirty?, false)
    |> assign(:edit_review_band, nil)
    |> assign(:discard_action, nil)
    |> assign_edit_draft(empty_edit_draft())
  end

  defp empty_edit_draft do
    %{
      "stop_name" => "",
      "stop_desc" => "",
      "stop_lat" => "",
      "stop_lon" => "",
      "stop_code" => "",
      "wheelchair_boarding" => "0",
      "tts_stop_name" => "",
      "stop_url" => ""
    }
  end

  # The form is rebuilt from the draft on every change rather than carried
  # through, so a refused write, a slow usage read or a re-render cannot take a
  # half-typed name back out of the field. The errors go on the form rather than
  # beside it, which is what makes `<.input>` mark the control `aria-invalid`.
  defp assign_edit_draft(socket, draft),
    do: assign_edit_draft(socket, draft, socket.assigns.edit_errors)

  defp assign_edit_draft(socket, draft, errors) do
    socket
    |> assign(:edit_draft, draft)
    |> assign(:edit_errors, errors)
    |> assign(:edit_form, to_form(draft, as: @edit_as, errors: form_errors(errors)))
  end

  # Everything the add flow owns, in one place, so every way into it — the
  # header's button, the first-use panel, the created panel's "add another" —
  # starts from the same empty draft rather than from whatever the last one left.
  defp assign_add_state(socket) do
    socket
    |> assign(:add_kind, :stop)
    |> assign(:name_touched?, false)
    |> assign(:desc_touched?, false)
    |> assign(:add_saving, false)
    |> assign(:coords_open?, false)
    |> assign(:tech_open?, false)
    |> assign(:created_stop, nil)
    |> assign(:add_suggestion, nil)
    |> assign(:add_reverse_error, nil)
    |> assign(:add_failure, nil)
    |> assign(:add_errors, %{})
    |> assign(:place_token, 0)
    |> assign_draft(blank_draft())
  end

  defp blank_draft do
    %{
      "name" => "",
      "desc" => "",
      "code" => "",
      "wheelchair_boarding" => "0",
      "stop_id" => "",
      "tts_stop_name" => "",
      "stop_url" => "",
      "lat" => "",
      "lon" => ""
    }
  end

  # The form is rebuilt from the draft on every change rather than carried
  # through, so a refused write, a slow reverse geocode or a re-render cannot
  # take a half-typed name back out of the field.
  #
  # The errors go on the form rather than beside it, which is what makes
  # `<.input>` mark the control `aria-invalid` and describe it: the focus hook
  # looks for exactly that attribute when it moves the reader to the first
  # thing they have to fix.
  defp assign_draft(socket, draft), do: assign_draft(socket, draft, socket.assigns.add_errors)

  defp assign_draft(socket, draft, errors) do
    socket
    |> assign(:add_draft, draft)
    |> assign(:add_form, to_form(draft, as: @add_as, errors: form_errors(errors)))
  end

  defp form_errors(errors) do
    for {field, %{long: message}} <- Enum.sort_by(errors, &elem(&1, 0)), do: {field, message}
  end

  @impl true
  def handle_params(params, _url, socket) do
    if connected?(socket) do
      # `?stop=` is the third way into the edit panel, alongside the list and the
      # search. It is remembered rather than acted on here because the stop is
      # read from the model, and the model has not arrived yet.
      socket =
        if is_binary(params["stop"]) do
          assign(socket, :requested_stop_id, params["stop"])
        else
          assign(socket, :requested_stop_id, nil)
        end

      {:noreply, start_load(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:load_model, {:ok, {:ok, model}}, socket) do
    socket =
      socket
      |> assign(:model, model)
      |> assign(:stops_state, :ready)
      |> assign(:scope_error, nil)
      |> assign_new_panel()
      |> start_checks(model)

    {:noreply, push_scene(open_requested_stop(socket))}
  end

  def handle_async(:load_model, {:ok, {:error, :unavailable}}, socket) do
    {:noreply,
     socket
     |> assign(:stops_state, :unavailable)
     |> assign(:scope_error, "The stops for this version could not be read.")}
  end

  def handle_async(:load_model, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:stops_state, :unavailable)
     |> assign(:scope_error, "The stops for this version could not be read.")}
  end

  @impl true
  def handle_async(:checks, {:ok, {:ok, checks}}, socket) when is_map(checks) do
    {:noreply, assign(socket, :checks, checks)}
  end

  # A read that failed leaves the disclosure absent rather than showing a
  # finding nobody can trust. The list and the map are unaffected: they were
  # never waiting on this.
  def handle_async(:checks, _result, socket), do: {:noreply, assign(socket, :checks, nil)}

  # The reverse geocode's answer belongs to the placement that asked for it. The
  # task is named for the placement's token rather than for the placement
  # itself, and a reply whose token is not the current one is dropped: a slower
  # first answer arriving after a faster second one must not replace the
  # suggestion the editor is looking at.
  def handle_async({:reverse, token}, {:ok, {:ok, places}}, socket) do
    if socket.assigns.place_token == token do
      {:noreply, apply_suggestion(socket, places)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:reverse, token}, {:ok, {:error, reason}}, socket) do
    if socket.assigns.place_token == token do
      Logger.error("Geocoding reverse failed: #{inspect(reason)}")

      # The address service is not the form. The placement stands, the fields
      # stay editable, and the panel says the streets could not be looked up so
      # an empty name is the editor's to fill rather than a blank that looks
      # like a failure to read.
      {:noreply,
       socket
       |> assign(:add_suggestion, nil)
       |> assign(:add_reverse_error, reason)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:reverse, token}, {:exit, reason}, socket) do
    Logger.error("Geocoding reverse exited: #{inspect(reason)}")

    if socket.assigns.place_token == token do
      {:noreply,
       socket |> assign(:add_suggestion, nil) |> assign(:add_reverse_error, :unavailable)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:create, {:ok, {:ok, stop}}, socket) do
    {:noreply,
     socket
     |> assign(:add_saving, false)
     |> assign(:panel, :created)
     |> assign(:created_stop, created_row(stop, socket.assigns))
     |> assign(:add_errors, %{})
     |> assign(:placement, nil)
     |> push_map_mode()
     |> start_load()}
  end

  # A changeset came back with the fields it refused. They are the form's own
  # errors, so the summary and the focus are the create flow's, not a message
  # about the command having failed.
  def handle_async(:create, {:ok, {:error, %Ecto.Changeset{} = changeset}}, socket) do
    {errors, message} = changeset_errors(changeset)

    {:noreply,
     socket
     |> assign(:add_saving, false)
     |> assign(:add_failure, message)
     |> assign_add_errors(socket, errors)
     |> focus_first_error(errors)}
  end

  def handle_async(:create, {:ok, {:error, reason}}, socket) do
    Logger.error("Creating a stop failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:add_saving, false)
     |> assign(
       :add_failure,
       "We couldn’t save this stop. Nothing was changed, and your draft is still here."
     )}
  end

  def handle_async(:create, {:exit, reason}, socket) do
    Logger.error("Creating a stop exited: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:add_saving, false)
     |> assign(
       :add_failure,
       "We couldn’t save this stop. Nothing was changed, and your draft is still here."
     )}
  end

  def handle_async(:edit_save, {:ok, {:ok, stop}}, socket) do
    # `stops.updated_at` is a whole second, so the struct an update returns
    # carries the microseconds Ecto generated rather than the value the row
    # holds, which is that instant rounded. Editing from the struct would make
    # the very next save read as someone else's write, so the panel edits from
    # the row as the database now holds it.
    reloaded = reload_stop(socket, stop)

    {:noreply,
     socket
     |> assign(:edit_saving, false)
     |> assign_edit_stop(reloaded)
     |> start_edit_usage(reloaded)
     |> assign(:edit_outcome, :saved)
     |> start_load()}
  end

  def handle_async(:edit_save, {:ok, {:review_required, band}}, socket) do
    # A move past the correction band is step 31's review, not a failure here.
    # Nothing was written, and the panel says so rather than pretending the save
    # landed or discarding the draft that asked for it.
    {:noreply,
     socket
     |> assign(:edit_saving, false)
     |> assign(:edit_outcome, :review_required)
     |> assign(:edit_review_band, band)}
  end

  def handle_async(:edit_save, {:ok, {:error, :stale}}, socket) do
    {:noreply,
     socket
     |> assign(:edit_saving, false)
     |> assign(:edit_outcome, :stale)
     |> assign_edit_conflict(socket.assigns.edit_stop)}
  end

  def handle_async(:edit_save, {:ok, {:error, %Ecto.Changeset{} = changeset}}, socket) do
    {:noreply,
     socket
     |> assign(:edit_saving, false)
     |> assign(:edit_outcome, :invalid)
     |> assign_edit_draft(socket.assigns.edit_draft, edit_changeset_errors(changeset))}
  end

  def handle_async(:edit_save, {:ok, {:error, _reason}}, socket) do
    # A refused command writes nothing. The draft stays exactly as typed, because
    # the editor's next action is to fix the cause and press Save again.
    {:noreply, socket |> assign(:edit_saving, false) |> assign(:edit_outcome, :failed)}
  end

  def handle_async(:edit_save, {:exit, _reason}, socket),
    do: {:noreply, socket |> assign(:edit_saving, false) |> assign(:edit_outcome, :failed)}

  # `start_async/3` hands the callback whatever the function returned, so the
  # function's own `{:ok, _}` is the reply's first layer.
  def handle_async(:edit_usage, {:ok, {:ok, {usage, zone_names}}}, socket) do
    if usage_matches_panel?(socket.assigns, usage) do
      {:noreply, socket |> assign(:edit_usage, usage) |> assign(:edit_zone_name, zone_names)}
    else
      {:noreply, socket}
    end
  end

  # A read that failed leaves the list absent rather than showing "nothing uses
  # this stop" about a read that never answered.
  def handle_async(:edit_usage, _result, socket),
    do: {:noreply, assign(socket, :edit_usage, nil)}

  # The usage is read from one stop's struct, so the reply has to name the stop
  # it was read for or the panel cannot tell whether it is still the right one.
  defp usage_matches_panel?(%{edit_usage_for: stop_id, edit_stop: %{stop_id: stop_id}}, _usage),
    do: true

  defp usage_matches_panel?(_assigns, _usage), do: false

  # Every keystroke arrives as the whole form, so the draft is merged field by
  # field rather than replaced: a param the panel does not name is not a field
  # (the whitelist), and a field the browser did not send keeps its value
  # rather than being blanked by an omission.
  defp apply_edit_field(socket, params) do
    socket
    |> assign_edit_draft(merge_draft(socket.assigns.edit_draft, params, @edit_fields), %{})
    |> assign(:edit_outcome, :none)
    |> assign(:edit_conflict, nil)
    |> assign_dirty()
  end

  defp assign_dirty(socket) do
    assign(socket, :edit_dirty?, edit_dirty?(socket.assigns))
  end

  # Dirty is a comparison against the loaded row, over the same fields the form
  # carries. A coordinate typed with a trailing space and one the editor did not
  # touch are the same value to a rider, so the numbers are compared as numbers
  # rather than as the text in the field.
  defp edit_dirty?(%{edit_baseline: baseline, edit_draft: draft}) when is_map(baseline) do
    Enum.any?(@edit_fields, fn field ->
      if field in ["stop_lat", "stop_lon"] do
        coordinate_changed?(baseline[field], draft[field])
      else
        trim(draft[field]) != trim(baseline[field])
      end
    end)
  end

  defp coordinate_changed?(before, after_value) do
    case {number(before), number(after_value)} do
      {{:ok, a}, {:ok, b}} -> abs(a - b) > 0.000005
      _not_both_numbers -> trim(before) != trim(after_value)
    end
  end

  defp trim(value), do: value |> to_string() |> String.trim()

  # The guard. A clean form exits without a question; a dirty one holds the exit
  # and asks, so the same question and the same two answers serve Escape, Cancel
  # and choosing another stop.
  # The head matches the assigns, not the socket: a socket is a struct, and a
  # pattern written against its own keys would never match it — the dirty flag
  # lives inside `assigns`.
  defp guard_edit(%{assigns: %{edit_dirty?: true}} = socket, action),
    do: assign(socket, :discard_action, action)

  defp guard_edit(socket, {:close}), do: close_edit(socket)
  defp guard_edit(socket, _action), do: socket

  defp close_edit(socket) do
    socket
    |> assign(:panel, :browse)
    |> assign(:selected_stop_id, nil)
    |> assign(:edit_stop, nil)
    |> assign(:edit_baseline, nil)
    |> assign(:edit_dirty?, false)
    |> assign(:edit_outcome, :none)
    |> assign(:edit_conflict, nil)
    |> assign(:edit_usage, nil)
    |> assign_edit_state()
  end

  # --- saving ---------------------------------------------------------------

  defp start_save(socket, params) do
    draft = merge_draft(socket.assigns.edit_draft, params, @edit_fields)

    case socket.assigns.edit_stop do
      nil ->
        assign(socket, :edit_draft, draft)

      stop ->
        attrs = edit_attrs(socket.assigns, stop, draft)
        audit = audit_context(socket.assigns)
        loaded = socket.assigns.edit_loaded_updated_at

        # A submit arrives without a preceding `phx-change` when the editor
        # presses Enter in a field, so the draft and the dirty flag are set from
        # the posted params here too. Otherwise the form would report "No
        # changes yet" while it is writing one.
        socket =
          socket
          |> assign(:edit_draft, draft)
          |> assign(:edit_saving, true)
          |> assign_dirty()

        start_async(socket, :edit_save, fn ->
          StopEditing.update_stop(stop.uuid, attrs, loaded, audit)
        end)
    end
  end

  # Only the fields the panel owns are read out of the form, and they are mapped
  # to the names `Stop.editor_changeset/2` casts. A stop ID, a zone, a parent or
  # a location type posted alongside them is not in this map, so it cannot reach
  # the command even if the command were to read it (INV-5).
  defp edit_attrs(_assigns, stop, draft) do
    %{
      "stop_name" => presence(draft["stop_name"]),
      "stop_desc" => presence(draft["stop_desc"]),
      "stop_lat" => coordinate_value(draft["stop_lat"], stop),
      "stop_lon" => coordinate_value(draft["stop_lon"], stop),
      "stop_code" => presence(draft["stop_code"]),
      "wheelchair_boarding" => wheelchair_value(draft["wheelchair_boarding"]),
      "tts_stop_name" => presence(draft["tts_stop_name"]),
      "stop_url" => presence(draft["stop_url"])
    }
  end

  # An unparseable coordinate is `nil` rather than the loaded value: the command's
  # changeset refuses a nil, and the panel shows why. Writing the loaded value
  # back would silently discard an edit the editor believed they had made.
  defp coordinate_value(value, _stop) do
    case number(value) do
      {:ok, parsed} -> parsed
      :error -> nil
    end
  end

  @impl true
  def handle_event("stop_map_ready", _params, socket) do
    {:noreply, socket |> assign(:map_state, :ready) |> then(&push_scene/1)}
  end

  def handle_event("stop_map_bounds", params, socket) do
    case parse_bounds(params) do
      {:ok, bounds} ->
        {:noreply, assign(socket, :view_bounds, bounds)}

      :error ->
        # A malformed view is ignored rather than believed: an empty panel
        # would read as "this feed has no stops", which is a lie about data.
        {:noreply, socket}
    end
  end

  def handle_event("map_unavailable", _params, socket) do
    {:noreply, socket |> assign(:map_state, :unavailable) |> assign(:map_state_reason, nil)}
  end

  def handle_event("retry_map", _params, socket) do
    {:noreply, socket |> assign(:map_state, :loading) |> then(&push_scene/1)}
  end

  def handle_event("start_add", params, socket) do
    kind = if params["kind"] == "station", do: :station, else: :stop

    {:noreply, socket |> begin_add(kind) |> push_map_mode()}
  end

  def handle_event("cancel_add", _params, socket) do
    {:noreply,
     socket
     |> assign(:panel, :browse)
     |> assign(:placement, nil)
     |> assign_add_state()
     |> push_map_mode()}
  end

  # "Add another stop" from the created panel is the header's button with the
  # draft that was just created thrown away, which is what "another" means.
  def handle_event("add_another", _params, socket) do
    {:noreply, socket |> begin_add(:stop) |> push_map_mode()}
  end

  # The switch from a stop to a station is a new draft rather than a toggle on
  # the old one: a station and a stop are different fields, so a half-filled
  # stop draft cannot become a station draft by accident.
  def handle_event("add_kind", %{"kind" => "station"}, socket),
    do: {:noreply, socket |> begin_add(:station) |> push_map_mode()}

  def handle_event("add_kind", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_coords", _params, socket),
    do: {:noreply, assign(socket, :coords_open?, not socket.assigns.coords_open?)}

  def handle_event("toggle_tech", _params, socket),
    do: {:noreply, assign(socket, :tech_open?, not socket.assigns.tech_open?)}

  # A point the editor chose on the map. It is the draft's position and nothing
  # else: nothing is written until the add flow is submitted, so a placement
  # that is abandoned leaves no row behind.
  def handle_event("place", params, socket) do
    {:noreply, socket |> assign_placement(params) |> maybe_start_reverse()}
  end

  def handle_event("pin_moved", params, socket) do
    {:noreply, socket |> assign_placement(params) |> maybe_start_reverse()}
  end

  # Every keystroke in the add form. The draft is the server's, so the panel
  # answers a change with the whole form rather than with the field that
  # changed — which is what keeps a draft that has been typed into from being
  # taken back out of the field by a re-render.
  def handle_event("add_field", %{"stop" => params}, socket),
    do: {:noreply, change_add_field(socket, params)}

  def handle_event("add_field", _params, socket), do: {:noreply, socket}

  # Taking a suggestion is taking one of the suggestions the server offered. The
  # text arrives from the browser, so it is checked against what is on offer: a
  # forged value is a value the server never derived, and a button that can post
  # arbitrary text is not a suggestion.
  def handle_event("add_suggestion", %{"field" => field, "text" => text}, socket) do
    if suggested?(socket.assigns.add_suggestion, field, text) do
      {:noreply,
       socket
       |> assign_draft(Map.put(socket.assigns.add_draft, field, text))
       |> touch_suggested_field(field)
       |> drop_error(field)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_suggestion", _params, socket), do: {:noreply, socket}

  # "Open <stop>" puts the editor in front of the stop the draft duplicates,
  # without throwing the draft away: the decision is whether this is a second
  # copy of that stop, and that decision needs both stops in view at once.
  # Step 30 turns the selection into that stop's edit panel.
  def handle_event("open_duplicate", %{"key" => key}, socket) do
    with warning when not is_nil(warning) <-
           Enum.find(add_warnings(socket.assigns), &duplicate_action?(&1, key)),
         {_lat, _lon} = point <- stop_point(socket.assigns.model, warning.stop_id) do
      {:noreply, socket |> assign(:selected_stop_id, warning.stop_id) |> push_focus(point)}
    else
      _no_such_finding -> {:noreply, socket}
    end
  end

  def handle_event("open_duplicate", _params, socket), do: {:noreply, socket}

  # "Move it across the street" is the server's reflection, made from the line
  # the finding is about and the draft's own point. The browser names the line
  # and nothing else: a point it chose would be a position the geometry never
  # agreed to.
  def handle_event("move_across", %{"key" => key}, socket) do
    with warning when not is_nil(warning) <-
           Enum.find(add_warnings(socket.assigns), &across_action?(&1, key)),
         {lat, lon} when not is_nil(lat) <- socket.assigns.placement,
         {_lon, _lat} = point when is_tuple(point) <-
           across_point(socket.assigns.model, warning, {lat, lon}) do
      {:noreply,
       socket
       |> assign_placement(%{"lat" => elem(point, 1), "lon" => elem(point, 0)})
       |> maybe_start_reverse()}
    else
      _nothing_to_reflect -> {:noreply, socket}
    end
  end

  def handle_event("move_across", _params, socket), do: {:noreply, socket}

  # Creating a stop is a write, so it is a command: authorized, audited and run
  # in one transaction by `StopEditing.create_stop/2`. It runs asynchronously so
  # the "Creating…" state is a real state rather than a label on a button the
  # server is not answering yet, and so a second submit while it is in flight is
  # refused rather than queued.
  def handle_event("create_stop", %{"stop" => params}, socket) do
    if socket.assigns.add_saving do
      {:noreply, socket}
    else
      draft = merge_draft(socket.assigns.add_draft, params, @add_fields)

      case add_errors(socket.assigns, draft) do
        errors when map_size(errors) == 0 ->
          {:noreply,
           socket
           |> assign_draft(draft)
           |> assign(:add_saving, true)
           |> assign(:add_failure, nil)
           |> start_create(draft)}

        errors ->
          {:noreply, focus_first_error(assign_add_errors(socket, draft, errors), errors)}
      end
    end
  end

  def handle_event("create_stop", _params, socket), do: {:noreply, socket}

  # Search answers two questions at once, and the field is one field: "is this
  # stop in my feed" (this version's own rows) and "where do I put the new one"
  # (the address service). They are searched together and rendered apart, so an
  # editor never has to choose a mode to find out whether a stop exists.
  def handle_event("search", %{"search" => %{"query" => raw}}, socket),
    do: {:noreply, run_search(socket, raw)}

  # A search field that arrives without a query is a search for nothing, which
  # is the same as no search: the panel returns to the list it had.
  def handle_event("search", _params, socket),
    do:
      {:noreply,
       assign_search(
         socket,
         socket.assigns.search_query,
         socket.assigns.search_stops,
         socket.assigns.search_places,
         socket.assigns.search_unavailable?
       )}

  # Choosing another stop while the form is dirty asks first. The pending choice
  # is held rather than performed, so `discard_changes` performs it and
  # `keep_editing` drops it — and neither has to know what the other was.
  def handle_event("select_stop", %{"stop_id" => stop_id}, socket) do
    cond do
      !stop_in_model?(socket.assigns, stop_id) ->
        # A result id that is not one this search produced is refused rather than
        # looked up: the panel only shows what the search returned, so accepting
        # an id it never showed would select a stop the editor cannot see.
        {:noreply, socket}

      socket.assigns.edit_dirty? ->
        {:noreply, assign(socket, :discard_action, {:select, stop_id})}

      true ->
        {:noreply, open_edit(socket, stop_id)}
    end
  end

  # A `select_stop` that carries no stop is no choice at all, so it changes
  # nothing rather than closing the panel.
  def handle_event("select_stop", _params, socket), do: {:noreply, socket}

  def handle_event("edit_field", %{"stop" => params}, socket),
    do: {:noreply, apply_edit_field(socket, params)}

  def handle_event("edit_field", _params, socket), do: {:noreply, socket}

  def handle_event("save_stop", %{"stop" => params}, socket),
    do: {:noreply, start_save(socket, params)}

  def handle_event("save_stop", _params, socket), do: {:noreply, socket}

  # Escape is the one exit with no control of its own, so it arrives as a window
  # key from the panel rather than from a button.
  def handle_event("edit_escape", %{"key" => "Escape"}, socket),
    do: {:noreply, guard_edit(socket, {:close})}

  def handle_event("edit_escape", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_edit", _params, socket),
    do: {:noreply, guard_edit(socket, {:close})}

  # Keeping the draft closes the dialog and nothing else. It writes nothing: a
  # refusal that changed the feed would be the guard's own defect.
  def handle_event("keep_editing", _params, socket),
    do: {:noreply, assign(socket, :discard_action, nil)}

  def handle_event("discard_changes", _params, socket) do
    case socket.assigns.discard_action do
      nil ->
        {:noreply, socket}

      {:select, stop_id} ->
        {:noreply, socket |> assign(:discard_action, nil) |> open_edit(stop_id)}

      {:close} ->
        {:noreply, socket |> assign(:discard_action, nil) |> close_edit()}
    end
  end

  def handle_event("toggle_edit_more", _params, socket),
    do: {:noreply, assign(socket, :edit_more_open?, not socket.assigns.edit_more_open?)}

  def handle_event("toggle_edit_tech", _params, socket),
    do: {:noreply, assign(socket, :edit_tech_open?, not socket.assigns.edit_tech_open?)}

  # Choosing a place is a placement. It writes the same `placement` a click on
  # the map writes, so the pin, the caption and the map's mode are unchanged by
  # how the editor got there — one draft, one position.
  def handle_event("choose_place", params, socket) do
    {:noreply, socket |> assign_placement(params) |> maybe_start_reverse()}
  end

  # --- version checks -------------------------------------------------------

  # The disclosure is a region behind a button, not a `<details>` element, so
  # its open state is the server's and survives the re-render a dismissed row
  # causes. A native disclosure snaps shut under the reader instead.
  def handle_event("toggle_checks", _params, socket),
    do: {:noreply, assign(socket, :checks_open, not socket.assigns.checks_open)}

  # "Review pair" and "Show stop" both name a stop, so both do the same thing
  # here: the panel's heading says which stop, and the map goes to it. Step 33
  # replaces a duplicate's action with the replace flow, which is a panel of
  # its own rather than a focus.
  def handle_event("review_check", %{"key" => key}, socket) do
    case find_check(socket.assigns, key) do
      nil ->
        {:noreply, socket}

      check ->
        {:noreply, socket |> assign(:selected_stop_id, check.stop_id) |> push_focus(check.point)}
    end
  end

  def handle_event("review_check", _params, socket), do: {:noreply, socket}

  # "They're different stops" is the editor's judgement that a pair a metre
  # apart is two places. It is remembered for this session and written to
  # nothing: the next mount asks again, because a dismissal nobody made is a
  # dismissal nobody agreed to.
  def handle_event("dismiss_check", %{"key" => key}, socket) do
    if find_check(socket.assigns, key) do
      {:noreply,
       assign(socket, :dismissed_checks, MapSet.put(socket.assigns.dismissed_checks, key))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_check", _params, socket), do: {:noreply, socket}

  # The checks run after the list, never before it. The panel answers "which
  # stops are here" from the model it already holds, and the findings are a
  # reading of the same model — a page that waited for the findings to list its
  # stops would be slower for no new information.
  defp start_checks(socket, model) do
    start_async(socket, :checks, fn -> {:ok, StopPlacement.version_checks(model)} end)
  end

  # The rows the disclosure lists, in the order the checks were found and with
  # the dismissed ones taken out. Nothing is listed while the read is
  # outstanding, and the list the page already has is not held back for it.
  defp check_rows(%{
         model: model,
         checks: %{duplicates: duplicates, wrong_side: wrong_side, not_served: not_served},
         dismissed_checks: dismissed
       }) do
    [duplicates, wrong_side, not_served]
    |> Enum.concat()
    |> Enum.flat_map(&check_row(&1, model))
    |> Enum.reject(&MapSet.member?(dismissed, &1.key))
  end

  defp check_rows(_assigns), do: []

  defp panel_checks(assigns), do: check_rows(assigns)

  defp check_row({first, second, metres}, _model) do
    [
      %{
        key: pair_key(first, second),
        dom_id: "duplicate-#{dom_key(first, second)}",
        kind: :duplicate,
        title: "Two stops #{format_distance(metres)} apart",
        text: "#{stop_label(first)} and #{stop_label(second)}. Riders see two stops at one sign.",
        action: "Review pair",
        stop_id: first.stop_id,
        point: first.point
      }
    ]
  end

  defp check_row({stop, line}, model) do
    [
      %{
        key: "wrong-side|#{stop.stop_id}",
        dom_id: "wrong-side-#{dom_stop_id(stop)}",
        kind: :wrong_side,
        title: "#{stop_label(stop)} is across the street from its buses",
        text: "#{route_label(model, line)} passes on the far side. Riders board on the right.",
        action: "Show stop",
        stop_id: stop.stop_id,
        point: stop.point
      }
    ]
  end

  defp check_row(stop, _model) when is_map(stop) do
    [
      %{
        key: "not-served|#{stop.stop_id}",
        dom_id: "not-served-#{dom_stop_id(stop)}",
        kind: :not_served,
        title: "#{stop_label(stop)} isn’t served",
        text:
          "No pattern stops here, so the export leaves it out. Delete it if it’s gone for good.",
        action: "Show stop",
        stop_id: stop.stop_id,
        point: stop.point
      }
    ]
  end

  # A pair's key is sorted, so a row's identity does not depend on which stop
  # the scan happened to reach first: a dismissal that changed when the list was
  # read from the other end would not be a dismissal.
  defp pair_key(first, second),
    do: "duplicate|#{Enum.join(Enum.sort([first.stop_id, second.stop_id]), "+")}"

  # A row's DOM id is its key with everything that is not a letter, a digit or
  # a dash replaced. GTFS stop IDs are free text, so `A|B` would otherwise end
  # up in an element id and read as a CSS combinator in every selector and
  # every test that names it.
  defp dom_key(first, second) do
    [first.stop_id, second.stop_id]
    |> Enum.sort()
    |> Enum.join("-")
    |> String.replace(~r/[^A-Za-z0-9-]+/, "-")
  end

  defp dom_stop_id(stop), do: String.replace(stop.stop_id, ~r/[^A-Za-z0-9]+/, "-")

  defp stop_label(stop), do: "#{stop.name || stop.stop_id} (#{stop.stop_id})"

  defp route_label(model, line) do
    case Map.get(model.routes || %{}, line.route_id) do
      %{short_name: short} when is_binary(short) and short != "" -> short
      %{long_name: long} when is_binary(long) and long != "" -> long
      _other -> "Its pattern"
    end
  end

  # The wording the prototype measures a finding in: feet to the nearest five
  # under a thousand of them, miles with two decimals beyond. A pair a metre and
  # a half apart is "5 ft apart" because that is the coarsest distance an
  # editor can act on.
  defp format_distance(metres) do
    feet = metres / 0.3048

    if feet < 1000 do
      "#{round(feet / 5) * 5} ft"
    else
      "#{Float.round(metres / 1609.344, 2)} mi"
    end
  end

  # --- the add flow ----------------------------------------------------------

  # Every way into the add panel starts from an empty draft and no placement, so
  # the header's button, the first-use panel and the created panel's "add
  # another" cannot inherit a draft from the one before them.
  # --- the edit panel -------------------------------------------------------

  # A stop ID this version does not hold is refused rather than looked up. The
  # list, the search and `?stop=` all arrive here, so the model is the one gate:
  # an ID outside it would open a panel for a stop the editor cannot see listed.
  defp stop_in_model?(%{model: nil}, _stop_id), do: false

  defp stop_in_model?(%{model: model}, stop_id),
    do: Enum.any?(model.stops, &(&1.stop_id == stop_id))

  # `?stop=` is answered after the model arrives rather than in `handle_params/3`,
  # so the stop is opened from the same read everything else on the page came
  # from, and an unknown ID leaves the browse panel alone.
  defp open_requested_stop(%{assigns: %{requested_stop_id: stop_id}} = socket)
       when is_binary(stop_id) do
    if stop_in_model?(socket.assigns, stop_id) do
      socket
      |> assign(:requested_stop_id, nil)
      |> open_edit(stop_id)
    else
      assign(socket, :requested_stop_id, nil)
    end
  end

  defp open_requested_stop(socket), do: socket

  # Opening the panel is one query for the row and a second, asynchronous, for
  # what uses it. `usage/3` reads fourteen tables, so the panel paints its
  # fields first and the usage list fills in — the same arrangement as the
  # checks disclosure, and for the same reason.
  defp open_edit(socket, stop_id) do
    case StopsMap.load_stop(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           stop_id
         ) do
      {:ok, stop} ->
        socket
        |> assign_edit_stop(stop)
        |> start_edit_usage(stop)
        |> push_focus(stop_point(socket.assigns.model, stop.stop_id))

      # A stop this version does not hold leaves the panel where it was: an
      # unknown ID is a stale link, not an editor's mistake worth a message.
      _missing ->
        socket
    end
  end

  # The row as the database holds it now. A stop that cannot be read back is
  # not a reason to throw away a save that landed, so the struct the command
  # returned stands in.
  defp reload_stop(socket, stop) do
    case StopsMap.load_stop(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           stop.stop_id
         ) do
      {:ok, reloaded} -> reloaded
      _unavailable -> stop
    end
  end

  defp assign_edit_stop(socket, stop) do
    draft = edit_draft_of(stop)

    socket
    |> assign(:panel, :edit)
    |> assign(:selected_stop_id, stop.stop_id)
    |> assign(:edit_stop, edit_stop_row(stop, socket.assigns))
    |> assign(:edit_loaded_updated_at, stop.updated_at)
    |> assign(:edit_baseline, draft)
    |> assign(:edit_errors, %{})
    |> assign(:edit_outcome, :none)
    |> assign(:edit_conflict, nil)
    |> assign(:edit_more_open?, false)
    |> assign_edit_draft(draft)
    |> assign(:edit_dirty?, false)
  end

  # The draft is the stop's own values as strings. The baseline is the same map,
  # and the two being compared field by field is what "Unsaved changes" means —
  # so the answer cannot disagree with what the form is showing.
  defp edit_draft_of(stop) do
    %{
      "stop_name" => stop.stop_name || "",
      "stop_desc" => stop.stop_desc || "",
      "stop_lat" => decimal_text(stop.stop_lat),
      "stop_lon" => decimal_text(stop.stop_lon),
      "stop_code" => stop.stop_code || "",
      "wheelchair_boarding" => Integer.to_string(stop.wheelchair_boarding || 0),
      "tts_stop_name" => stop.tts_stop_name || "",
      "stop_url" => stop.stop_url || ""
    }
  end

  defp decimal_text(nil), do: ""

  defp decimal_text(value) do
    value
    |> Decimal.to_float()
    |> Float.round(5)
    |> to_string()
  end

  # The panel's own view of the stop: what it is called, where its page is, the
  # routes that call there and the bays of a station. Everything except the
  # fields is read from the model the page already holds, so opening a stop
  # costs the one query and nothing else.
  defp edit_stop_row(stop, assigns) do
    model = assigns.model
    stop_row = Enum.find(model.stops, &(&1.stop_id == stop.stop_id))
    bays = bays_of(model, stop)

    %{
      uuid: stop.id,
      stop_id: stop.stop_id,
      name: stop.stop_name || stop.stop_id,
      desc: stop.stop_desc,
      location_type: stop.location_type,
      parent_station: stop.parent_station,
      zone_id: stop.zone_id,
      level_id: stop.level_id,
      href: ~p"/gtfs/#{assigns.current_gtfs_version.id}/stops/#{stop.stop_id}",
      routes: if(stop_row, do: stop_routes(model, stop_row), else: []),
      bays: bays,
      bay_count: length(bays)
    }
  end

  defp bays_of(model, %{location_type: 1} = stop) do
    model.stops
    |> Enum.filter(&(&1.parent_station == stop.stop_id))
    |> Enum.sort_by(& &1.stop_id)
    |> Enum.map(&%{stop_id: &1.stop_id, name: &1.name || &1.stop_id, dom_id: dom_stop_id(&1)})
  end

  defp bays_of(_model, _stop), do: []

  defp start_edit_usage(socket, stop) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    # The usage clears the moment the panel changes stop, so the list never
    # answers for a stop the editor has already left, and the token names the
    # stop it was read for.
    socket =
      socket
      |> assign(:edit_usage, nil)
      |> assign(:edit_usage_for, stop.stop_id)

    start_async(socket, :edit_usage, fn ->
      zone_names =
        case stop.zone_id do
          nil -> nil
          zone_id -> FareZones.zone_names(organization_id, gtfs_version_id, [zone_id])[zone_id]
        end

      {:ok, {StopReferences.usage(organization_id, gtfs_version_id, stop), zone_names}}
    end)
  end

  # The conflict's other half: who saved, when, and what they changed. The audit
  # entry is the only record of that, and it is read for the stop this panel
  # holds rather than for a name the client supplied.
  defp assign_edit_conflict(socket, stop) do
    conflict =
      case stop do
        nil ->
          nil

        stop ->
          %{
            actor:
              last_actor(
                socket.assigns.current_organization.id,
                socket.assigns.current_gtfs_version.id,
                stop
              ),
            fields:
              changed_field_words(
                socket.assigns.current_organization.id,
                socket.assigns.current_gtfs_version.id,
                stop
              )
          }
      end

    socket |> assign(:edit_conflict, conflict) |> start_edit_usage(stop)
  end

  defp last_actor(organization_id, gtfs_version_id, stop) do
    case StopEditing.last_change(organization_id, gtfs_version_id, stop.uuid) do
      nil -> nil
      log -> log.actor_email
    end
  end

  defp changed_field_words(_organization_id, _gtfs_version_id, nil), do: []

  defp changed_field_words(organization_id, gtfs_version_id, stop) do
    case StopEditing.last_change(organization_id, gtfs_version_id, stop.uuid) do
      nil ->
        []

      log ->
        log.changed_fields
        |> Map.keys()
        |> Enum.filter(&Map.has_key?(@edit_field_words, &1))
        |> Enum.map(&Map.fetch!(@edit_field_words, &1))
        |> Enum.uniq()
    end
  end

  # The command's own messages, keyed to the field names the form posts. Ecto's
  # keys are atoms of the schema; the form's are the strings the browser sent.
  defp edit_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Map.new(fn {field, messages} ->
      {to_string(field), %{short: List.first(messages), long: Enum.join(messages, " ")}}
    end)
  end

  defp begin_add(socket, kind) do
    socket
    |> assign(:panel, :add)
    |> assign(:placement, nil)
    |> assign(:add_kind, kind)
    |> assign(:name_touched?, false)
    |> assign(:desc_touched?, false)
    |> assign(:add_saving, false)
    |> assign(:coords_open?, false)
    |> assign(:tech_open?, false)
    |> assign(:created_stop, nil)
    |> assign(:add_suggestion, nil)
    |> assign(:add_reverse_error, nil)
    |> assign(:add_failure, nil)
    |> assign(:add_errors, %{})
    # The token moves on here too, so a reverse still in flight for the draft
    # that was just abandoned cannot land on the new one.
    |> assign(:place_token, socket.assigns.place_token + 1)
    |> assign_draft(blank_draft())
  end

  # The reverse geocode is asked for only while a draft is being added, and only
  # for a placement there is one. In the browse panel a pin is a selection, not
  # something to name, and reverse geocoding it would spend Geoapify credits on
  # a stop the editor is not creating.
  # The head matches the socket's assigns rather than the socket, because a
  # socket is a struct: a pattern written against its keys would never match it,
  # and the reverse geocode would silently never be asked for.
  defp maybe_start_reverse(%{assigns: %{panel: :add, placement: {lat, lon}}} = socket) do
    token = socket.assigns.place_token + 1

    socket
    |> assign(:place_token, token)
    |> assign(:add_suggestion, :loading)
    |> assign(:add_reverse_error, nil)
    |> start_async({:reverse, token}, fn -> Geocoding.reverse(lat, lon, amenities: true) end)
  end

  defp maybe_start_reverse(socket), do: socket

  # The answer becomes the name field, the alternatives beside it, and the
  # description the side of the street suggests. The name and the description
  # are only filled while the editor has not typed in them: a name somebody
  # wrote is theirs, and a suggestion over the top of it is a suggestion nobody
  # asked for.
  defp apply_suggestion(socket, places) do
    %{name: name, alternatives: alternatives} =
      StopNaming.suggestions(places, neighbour_names(socket.assigns), connector(socket.assigns))

    suggestion = %{
      name: name,
      alternatives: alternatives,
      description: description_suggestion(socket.assigns)
    }

    socket
    |> assign(:add_suggestion, suggestion)
    |> assign(:add_reverse_error, nil)
    |> fill_suggested(suggestion)
  end

  defp fill_suggested(socket, %{name: name, description: description}) do
    draft = socket.assigns.add_draft

    draft =
      if not socket.assigns.name_touched? and is_binary(name) and name != "" do
        Map.put(draft, "name", name)
      else
        draft
      end

    draft =
      if not socket.assigns.desc_touched? and is_binary(description) and
           socket.assigns.add_kind == :stop and draft["desc"] in [nil, ""] do
        Map.put(draft, "desc", description)
      else
        draft
      end

    assign_draft(socket, draft)
  end

  # The connector is this version's own: "Main St & 3rd Ave" and "Main St at 3rd
  # Ave" are both correct, and a version's existing stops are the only evidence
  # of which one it uses.
  defp connector(%{model: nil}), do: StopNaming.connector([])

  defp connector(assigns), do: assigns.model |> stop_names() |> StopNaming.connector()

  defp stop_names(%{stops: stops}) do
    stops
    |> Enum.map(& &1.name)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  # The names of the stops next to the draft. The radius lives here rather than
  # in `StopNaming.suggestions/3`, which takes the names it is given precisely
  # so that one place decides how far is near.
  defp neighbour_names(assigns) do
    case assigns.placement do
      nil ->
        []

      {lat, lon} ->
        assigns.model
        |> located_stops()
        |> Enum.map(fn stop -> {stop, StopPlacement.distance({lon, lat}, stop.point)} end)
        |> Enum.filter(fn {_stop, metres} -> metres <= @suggestion_neighbour_metres end)
        |> Enum.map(fn {stop, _metres} -> stop.name end)
        |> Enum.reject(&(&1 in [nil, ""]))
    end
  end

  # Which way the buses run at the draft's point, which is what a stop's
  # description is for: "Northbound" and "Southbound" are the two stops on one
  # street, and the description is what tells them apart.
  defp description_suggestion(assigns) do
    case assigns.placement do
      nil ->
        nil

      {lat, lon} ->
        assigns.model
        |> Map.get(:lines, [])
        |> then(&StopPlacement.kerb_direction({lon, lat}, &1))
        |> case do
          nil -> nil
          # A description is a sentence's worth of words, not a GTFS enum: the
          # seed's own descriptions read "Northbound", and a rider reads this one
          # on the same sign.
          direction -> direction |> to_string() |> String.capitalize()
        end
    end
  end

  defp assign_add_errors(socket, draft, errors) do
    socket
    |> assign(:add_errors, errors)
    |> assign_draft(draft, errors)
  end

  defp focus_first_error(socket, errors) do
    if map_size(errors) > 0 and connected?(socket) do
      push_event(socket, "focus_form_error", %{
        form_id: "stops-map-add-form",
        fallback_id: "stops-map-add-errors"
      })
    else
      socket
    end
  end

  # A change to the form: the draft is the merge of what was there and what
  # arrived, and only the fields the draft names are read. A paste that carries
  # both numbers into the latitude field places the draft, because that is how a
  # coordinate arrives from a gazetteer or a survey sheet.
  defp change_add_field(socket, params) do
    draft = merge_draft(socket.assigns.add_draft, params, @add_fields)
    socket = socket |> assign_draft(draft) |> touch_fields(params)
    before = socket.assigns.placement

    socket =
      case pasted_point(draft) do
        {:ok, lat, lon} -> assign_placement(socket, %{"lat" => lat, "lon" => lon})
        :error -> socket
      end

    # A keystroke in the name is not a new placement, and a reverse geocode is a
    # call to a service that costs money: one is asked for when the draft moves,
    # not every time a field changes. Asking on every change would also refill a
    # name the editor has just cleared, because an empty field is not a name
    # they have claimed.
    socket =
      if socket.assigns.placement == before, do: socket, else: maybe_start_reverse(socket)

    drop_resolved_errors(socket, params)
  end

  # Only the draft's own fields are read, and only as strings. Everything the
  # command uses is decided server-side from this map, so a forged attribute is
  # not one the command can see. `fields` is the whitelist the caller owns: the
  # add form's and the edit form's are different and neither is the other's.
  defp merge_draft(draft, params, fields) do
    Enum.reduce(fields, draft, fn field, acc ->
      case Map.fetch(params, field) do
        {:ok, value} when is_binary(value) -> Map.put(acc, field, value)
        _absent -> acc
      end
    end)
  end

  # A typed name is the editor's from then on, and so is a typed description.
  # A name the server filled is not: the next placement replaces it.
  defp touch_fields(socket, params) do
    socket
    |> touch_field(params, "name", :name_touched?)
    |> touch_field(params, "desc", :desc_touched?)
  end

  defp touch_field(socket, params, "name", :name_touched?) do
    if typed?(params, "name"), do: assign(socket, :name_touched?, true), else: socket
  end

  defp touch_field(socket, params, "desc", :desc_touched?) do
    if typed?(params, "desc"), do: assign(socket, :desc_touched?, true), else: socket
  end

  defp touch_field(socket, _params, _field, _key), do: socket

  defp typed?(params, field) do
    case Map.get(params, field) do
      value when is_binary(value) and value != "" -> true
      _blank -> false
    end
  end

  # Taking a suggestion is typing: a name the editor pressed a button to accept is
  # theirs, so the next placement does not overwrite it.
  defp touch_suggested_field(socket, "name"), do: assign(socket, :name_touched?, true)
  defp touch_suggested_field(socket, "desc"), do: assign(socket, :desc_touched?, true)
  defp touch_suggested_field(socket, _field), do: socket

  # An error the editor has just answered is dropped as they answer it, so a
  # summary that names a field somebody has since filled in is not a claim the
  # panel cannot back up. Errors nobody has touched stay.
  defp drop_resolved_errors(socket, params) do
    Enum.reduce(params, socket, fn {field, value}, acc ->
      if is_binary(value) and value != "", do: drop_error(acc, field), else: acc
    end)
  end

  defp drop_error(socket, field),
    do: assign(socket, :add_errors, Map.delete(socket.assigns.add_errors, field))

  # "44.6376, -124.0530" in one field is a coordinate pair, and it is the way
  # coordinates are copied out of almost everything that holds them. A field
  # holding one number is a latitude or a longitude and nothing more.
  defp pasted_point(draft) do
    with [lat, lon] <- String.split(draft["lat"] || "", ",", parts: 2),
         {:ok, lat} <- number(String.trim(lat)),
         {:ok, lon} <- number(String.trim(lon)),
         true <- abs(lat) <= 90.0,
         true <- abs(lon) <= 180.0 do
      {:ok, lat, lon}
    else
      _other -> :error
    end
  end

  defp suggested?(:loading, _field, _text), do: false

  defp suggested?(%{name: name}, "name", text), do: is_binary(name) and name == text

  defp suggested?(%{description: description}, "desc", text),
    do: is_binary(description) and description == text

  defp suggested?(_suggestion, _field, _text), do: false

  defp duplicate_action?(finding, key),
    do: finding.action == :open_duplicate and finding.action_key == key

  defp across_action?(finding, key),
    do: finding.action == :move_across and finding.action_key == key

  defp stop_point(nil, _stop_id), do: nil

  defp stop_point(model, stop_id) do
    case Enum.find(model.stops, &(&1.stop_id == stop_id)) do
      %{point: point} -> point
      _missing -> nil
    end
  end

  # The reflection is made from the line the server holds, named by the pattern
  # the finding came from. A browser that named a different line, or named the
  # points itself, would be asking the panel to place a stop somewhere the
  # geometry does not put it.
  defp across_point(nil, _finding, _point), do: nil

  defp across_point(model, finding, {lat, lon}) do
    case Enum.find(model.lines || [], &(&1.pattern_id == finding.action_key)) do
      nil -> nil
      line -> StopPlacement.across_street({lon, lat}, line.points)
    end
  end

  defp add_warnings(%{panel: :add, placement: {lat, lon}, model: model}) do
    StopPlacement.warnings({lon, lat}, model)
  end

  defp add_warnings(_assigns), do: []

  # The one sentence above the fields that says where the draft is. It changes
  # on every placement, which is the point: an editor who cannot see that the
  # sentence moved when the pin did has no way to tell the two apart.
  defp add_where(%{panel: :add, placement: {lat, lon}, model: model}) do
    lat
    |> place_point(lon)
    |> then(&StopPlacement.describe_point(&1, model))
    |> Map.fetch!(:text)
  end

  defp add_where(_assigns), do: nil

  # The same sentence the add panel shows, for the stop's saved position rather
  # than for a draft. It is what tells an editor whether the pin on the map and
  # the row in the form are talking about the same place.
  defp edit_where(%{panel: :edit, edit_stop: %{uuid: uuid}, model: model}) do
    case Enum.find(model.stops, &(&1.id == uuid)) do
      %{point: {lon, lat}} ->
        {lon, lat}
        |> StopPlacement.describe_point(model)
        |> Map.fetch!(:text)

      _unlocated ->
        nil
    end
  end

  defp edit_where(_assigns), do: nil

  # The placement assign holds `{lat, lon}` because that is what the hook reports
  # and what the coordinate fields show; the geometry takes `{lon, lat}`.
  defp place_point(lat, lon), do: {lon, lat}

  # What is worth saying about a name that has problems. It is advice, not a
  # refusal: every one of these names is publishable, and a name somebody
  # deliberately wrote is never blocked for being unusual.
  defp add_advice(%{panel: :add, add_draft: draft} = assigns) do
    StopNaming.advice(
      draft["name"] || "",
      presence(draft["code"]),
      presence(draft["desc"]),
      connector(assigns)
    )
  end

  defp add_advice(_assigns), do: []

  # A sign number is how a rider looks up arrivals, so two stops sharing one is
  # worse than no sign number at all. The conflict is read from the model the
  # panel already holds rather than by asking the database about every keystroke.
  defp add_code_issue(%{panel: :add, add_draft: draft, model: model}) do
    stops = Enum.map((model && model.stops) || [], &sign_row/1)

    case StopNaming.sign_conflict(draft["code"], stops, draft["stop_id"]) do
      nil ->
        nil

      other ->
        "#{other} already has sign number #{String.trim(draft["code"])}. Riders who look it up would get that stop."
    end
  end

  defp add_code_issue(_assigns), do: nil

  # `StopNaming.sign_conflict/3` reads the stop table's own field names, and the
  # map model names the same fields the panel reads them by.
  defp sign_row(stop),
    do: %{stop_id: stop.stop_id, stop_name: stop.name, stop_code: stop.code}

  # The fare zone is stated, not chosen: production has no zone editor on this
  # surface, so the line says which zone the nearest stops are in and where
  # zones are managed, rather than offering a select this page cannot honour.
  defp add_zone_note(%{panel: :add, placement: {lat, lon}, model: model}) do
    case nearest_zoned_stop(model, {lon, lat}) do
      nil ->
        "No stop near here is in a fare zone."

      {stop, _metres} ->
        zone_stops =
          model.stops
          |> Enum.filter(fn other -> other.zone_id == stop.zone_id and other.point end)
          |> length()

        "The #{zone_stops} nearest #{if zone_stops == 1, do: "stop is", else: "stops are"} in #{stop.zone_id}."
    end
  end

  defp add_zone_note(_assigns), do: nil

  # What the panel refuses to create, in the form's own words. A stop with no
  # placement has no coordinates, a stop with no name has nothing a rider can
  # be told, a stop whose typed ID is taken would collide with a live row, and
  # coordinates that disagree with the pin are two different places on a page
  # that draws only one of them.
  defp add_errors(assigns, draft) do
    %{}
    |> put_error(
      is_nil(assigns.placement),
      "location",
      %{
        short: "Place the stop on the map",
        long: "Click the curb where riders wait, or paste a pair of coordinates into Latitude."
      }
    )
    |> put_error(
      blank?(draft["name"]),
      "name",
      %{
        short: "Enter a name",
        long: "Enter a name riders will recognise, such as the cross street."
      }
    )
    |> put_error(
      coordinates_disagree?(assigns, draft),
      "lat",
      %{
        short: "These coordinates don’t match the pin",
        long: "Paste them into Latitude again to move the pin, or drag the pin back to them."
      }
    )
    |> put_error(
      stop_id_taken?(assigns, draft),
      "stop_id",
      %{
        short: "That stop ID is already used",
        long: "Stop IDs are unique within a version. Leave it blank to take the next one."
      }
    )
  end

  defp put_error(errors, true, field, error), do: Map.put(errors, field, error)
  defp put_error(errors, false, _field, _error), do: errors

  defp blank?(value), do: value in [nil, ""]

  # A blank optional field is `nil` rather than an empty string: GTFS says "this
  # stop has no description", which is not the same claim as "its description is
  # the empty string".
  defp presence(value) do
    case String.trim(value || "") do
      "" -> nil
      text -> text
    end
  end

  # The fields say one thing and the pin says another. Nothing is guessed about
  # which one is right: the panel asks, because only the editor knows.
  defp coordinates_disagree?(assigns, draft) do
    case assigns.placement do
      nil ->
        false

      {lat, lon} ->
        # A field that is not a number at all is a half-typed paste or a
        # half-typed coordinate, and the pin is still the draft's position.
        with {:ok, typed_lat} <- number(draft["lat"]),
             {:ok, typed_lon} <- number(draft["lon"]) do
          abs(typed_lat - lat) > 0.00001 or abs(typed_lon - lon) > 0.00001
        else
          _not_a_number -> false
        end
    end
  end

  # The uniqueness index on `(organization, version, stop_id)` is the real
  # authority and `create_stop/2` enforces it; this is the panel saying so
  # before the round trip, from the same rows the panel is already holding.
  defp stop_id_taken?(%{model: nil}, _draft), do: false

  defp stop_id_taken?(assigns, draft) do
    id = String.trim(draft["stop_id"] || "")

    id != "" and Enum.any?(assigns.model.stops, &(&1.stop_id == id))
  end

  defp start_create(socket, draft) do
    attrs = create_attrs(socket.assigns, draft)
    audit = audit_context(socket.assigns)

    start_async(socket, :create, fn -> StopEditing.create_stop(attrs, audit) end)
  end

  # The identity the command is scoped and audited by comes from the socket, not
  # from the form: a browser that posted its own organization or version would be
  # writing into a feed the editor is not looking at.
  defp audit_context(assigns) do
    %AuditContext{
      organization_id: assigns.current_organization.id,
      gtfs_version_id: assigns.current_gtfs_version.id,
      station_stop_id: nil,
      actor_id: assigns.current_user.id,
      actor_email: assigns.current_user.email
    }
  end

  defp create_attrs(assigns, draft) do
    {lat, lon} = assigns.placement

    %{
      "stop_name" => draft["name"],
      "stop_desc" => presence(draft["desc"]),
      "stop_code" => presence(draft["code"]),
      "wheelchair_boarding" => wheelchair_value(draft["wheelchair_boarding"]),
      "location_type" => location_type(assigns.add_kind),
      "stop_lat" => lat,
      "stop_lon" => lon,
      "stop_id" => presence(draft["stop_id"]),
      "tts_stop_name" => presence(draft["tts_stop_name"]),
      "stop_url" => presence(draft["stop_url"])
    }
  end

  # GTFS defines wheelchair boarding as 0 (no information), 1 (accessible) and
  # 2 (not accessible). Anything the browser posts that is not one of the three
  # is "no information" rather than a fourth value.
  defp wheelchair_value(value) do
    case Integer.parse(String.trim(value || "")) do
      {1, _rest} -> 1
      {2, _rest} -> 2
      _other -> 0
    end
  end

  defp location_type(:station), do: 1
  defp location_type(_stop), do: 0

  defp created_row(stop, assigns) do
    point = stop_point_of(stop)

    %{
      kind: if(stop.location_type == 1, do: "station", else: "stop"),
      stop_id: stop.stop_id,
      name: stop.stop_name,
      desc: stop.stop_desc,
      wheelchair: wheelchair_label(stop.wheelchair_boarding),
      zone: zone_name(assigns.model, point),
      href: ~p"/gtfs/#{assigns.current_gtfs_version.id}/stops/#{stop.stop_id}",
      patterns:
        passing_pattern_rows(point, assigns.model, assigns.current_gtfs_version.id, stop.stop_id)
    }
  end

  # The patterns a stop at this point could be added to, each with the two stops
  # it would fall between.
  #
  # The model is not reloaded yet, so the created stop is not among any
  # pattern's stops. That is what makes the neighbours the ones the new stop
  # sits between: the list is the pattern as it stands without it.
  defp passing_pattern_rows(nil, _model, _version_id, _stop_id), do: []

  defp passing_pattern_rows(point, model, version_id, stop_id) do
    point
    |> StopPlacement.passing_patterns(model)
    |> Enum.map(&pattern_row(&1, point, model, version_id, stop_id))
    # A pattern the model has no route for is not a pattern an editor can be
    # sent to, so it is not offered.
    |> Enum.reject(&is_nil/1)
  end

  defp pattern_row(line, point, model, version_id, stop_id) do
    case Map.get(model.routes || %{}, line.route_id) do
      nil ->
        nil

      route ->
        %{
          dom_id: "pattern-#{dom_stop_id(%{stop_id: line.route_pattern_id})}",
          route: route,
          headsign: line.headsign,
          between: between_phrase(line, point, model),
          href:
            ~p"/gtfs/#{version_id}/routes/#{line.route_id}/patterns/#{line.route_pattern_id}?task=stops&add_stop=#{stop_id}"
        }
    end
  end

  # "Between A and B" is a statement about a sequence, so the pattern's stops
  # are put in the order a vehicle meets them before the two either side of the
  # new point are read. A pattern with nothing before or nothing after says "the
  # start" and "the end": a stop at the first or last place on a pattern is a
  # real answer, and naming an absent neighbour is not.
  defp between_phrase(line, point, model) do
    ordered =
      model.stops
      |> Enum.filter(&(&1.point && line.pattern_id in &1.pattern_ids))
      |> StopPlacement.order_stops(line.points)

    index = StopPlacement.insertion_index(point, Enum.map(ordered, & &1.point))

    "Between #{neighbour_name(Enum.at(ordered, index - 1), "the start")} and " <>
      neighbour_name(Enum.at(ordered, index), "the end")
  end

  defp neighbour_name(nil, edge), do: edge
  defp neighbour_name(stop, _edge), do: stop.name || stop.stop_id

  # The stop row's own coordinates as the map's `{lon, lat}` pair. The model is
  # not reloaded yet at this point, so the created stop is not in it, and this is
  # the one place that says where the stop it just wrote actually is.
  defp stop_point_of(%{stop_lat: nil}), do: nil

  defp stop_point_of(stop) do
    {Decimal.to_float(stop.stop_lon), Decimal.to_float(stop.stop_lat)}
  end

  defp wheelchair_label(1), do: "Wheelchair accessible"
  defp wheelchair_label(2), do: "Not wheelchair accessible"
  defp wheelchair_label(_other), do: "Wheelchair access not recorded"

  # The fare zone a created stop is in is the one its neighbours are in, which
  # is what the form said before it was created. A stop with no neighbours has no
  # zone to inherit and is not given one.
  defp zone_name(nil, _point), do: nil

  defp zone_name(_model, nil), do: nil

  # The point is the map's `{lon, lat}`, the order every other call in this
  # module passes coordinates in.
  defp zone_name(model, point) do
    case nearest_zoned_stop(model, point) do
      nil ->
        "No zone"

      {stop, metres} ->
        "#{stop.zone_id} · #{format_distance(metres)} away"
    end
  end

  defp nearest_zoned_stop(model, point) do
    model.stops
    |> Enum.filter(fn stop ->
      stop.location_type == 0 and not blank?(stop.zone_id) and stop.point
    end)
    |> Enum.map(fn stop -> {stop, StopPlacement.distance(point, stop.point)} end)
    |> Enum.sort_by(fn {_stop, metres} -> metres end)
    |> Enum.take(@zone_neighbour_count)
    |> List.first()
  end

  # A refused create says which field it refused, in the form's own words, so
  # the summary and the focus are the create flow's rather than a message about
  # a command having failed.
  defp changeset_errors(changeset) do
    fields =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    {mapped, unclaimed} =
      Enum.split_with(fields, fn {field, _messages} ->
        field in [:stop_name, :stop_id, :stop_url]
      end)

    errors =
      Map.new(mapped, fn {field, messages} ->
        {draft_field(field), %{short: List.first(messages), long: Enum.join(messages, " ")}}
      end)

    message =
      if unclaimed == [] do
        nil
      else
        "We couldn’t save this stop. Nothing was changed, and your draft is still here."
      end

    {errors, message}
  end

  defp draft_field(:stop_name), do: "name"
  defp draft_field(field), do: to_string(field)

  defp find_check(assigns, key), do: Enum.find(check_rows(assigns), &(&1.key == key))

  defp push_focus(socket, {lon, lat}) do
    if connected?(socket) do
      push_event(socket, "stop_map:focus", %{lat: lat, lon: lon})
    else
      socket
    end
  end

  # A stop the model does not carry is not centred on: there is nothing on the
  # map to centre, and a fabricated point would put the editor somewhere else.
  defp push_focus(socket, _missing), do: socket

  # --- search ----------------------------------------------------------------

  defp run_search(socket, raw) do
    case String.trim(raw || "") do
      "" ->
        assign_search(socket, "", [], [], false)

      query ->
        stops = matching_stop_rows(socket.assigns, query)

        case Geocoding.autocomplete(query, bias: search_bias(socket.assigns.model)) do
          {:ok, places} ->
            assign_search(socket, query, stops, Enum.take(places, @search_place_limit), false)

          # A query shorter than the address service's minimum is not a failure,
          # it is a query it has not answered yet. It reads as "nothing yet",
          # which is what it is.
          {:error, :text_too_short} ->
            assign_search(socket, query, stops, [], false)

          {:error, reason} ->
            Logger.error("Geocoding autocomplete failed: #{inspect(reason)}")
            assign_search(socket, query, stops, [], true)
        end
    end
  end

  # The stop half of a search runs against this version's own rows, so it keeps
  # working when the address service does not — which is the whole reason the
  # two halves are separate in the panel.
  defp matching_stop_rows(%{panel: :add}, _query), do: []

  defp matching_stop_rows(assigns, query) do
    needle = String.downcase(query)

    assigns.model
    |> located_stops()
    |> Enum.filter(fn stop ->
      String.contains?(String.downcase(stop.name || ""), needle) or
        String.downcase(stop.stop_id) == needle
    end)
    |> Enum.sort_by(&{&1.location_type != 1, &1.name || &1.stop_id})
    |> Enum.take(@search_stop_limit)
    |> Enum.map(&row(assigns.model, &1))
  end

  # Address results are ranked near the stops this version already has, because
  # an editor is placing a stop in the feed they are editing and not looking
  # for an address anywhere in the world. The bias is the midpoint of the
  # loaded stops' bounds as `{lon, lat}`, the order the geocoding adapter's
  # `:bias` takes. A version with no located stop has no midpoint, and an
  # unranked search beats a fabricated one.
  defp search_bias(nil), do: nil

  defp search_bias(model) do
    points = for point <- Enum.map(model.stops, & &1.point), point, do: point

    case points do
      [] ->
        nil

      points ->
        {midpoint(points, 0), midpoint(points, 1)}
    end
  end

  # `StopsMap` points are `{lon, lat}` tuples.
  defp midpoint(points, axis) do
    values = Enum.map(points, &elem(&1, axis))
    (Enum.min(values) + Enum.max(values)) / 2
  end

  # One place the search's four assigns live, so every exit from a search —
  # cleared, answered, too short, failed — leaves the form holding what the
  # editor typed rather than what the last render happened to know.
  defp assign_search(socket, query, stops, places, unavailable?) do
    socket
    |> assign(:search_query, query)
    |> assign(:search_form, to_form(%{"query" => query}, as: @search_as))
    |> assign(:search_stops, stops)
    |> assign(:search_places, places)
    |> assign(:search_unavailable?, unavailable?)
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
      width="wide"
    >
      <div
        id="stops-map-page"
        class="ds-page overflow-clip rounded-card border border-subtle bg-white"
      >
        <.page_header
          id="stops-map-header"
          version={@current_gtfs_version}
          stop_count={stop_count(@model)}
          station_count={station_count(@model)}
          loading={@stops_state == :loading}
        />

        <%!-- The scope error is above the workspace rather than inside it: the
               workspace is the map and the panel, and a message between them
               would shrink both. --%>
        <div :if={@scope_error} id="stops-map-unavailable-read" class="px-4 pt-4 sm:px-5">
          <.message kind="error" title={@scope_error}>
            The street map needs the version's stops. Reload the page to try again.
          </.message>
        </div>

        <div
          id="stops-map-workspace"
          class="grid min-h-0 lg:h-[calc(100vh-13rem)] lg:grid-cols-[minmax(0,1fr)_408px]"
        >
          <.map_stage
            id="stops-map-stage"
            map_state={@map_state}
            caption={map_caption(assigns)}
          />

          <%= if @panel == :add do %>
            <.add_panel
              id="stops-map-add-panel"
              kind={@add_kind}
              version_name={@current_gtfs_version.name}
              search_form={@search_form}
              query={@search_query}
              places={@search_places}
              unavailable?={@search_unavailable?}
              form={@add_form}
              placement={@placement}
              where={add_where(assigns)}
              warnings={add_warnings(assigns)}
              suggestion={@add_suggestion}
              reverse_error={@add_reverse_error}
              errors={@add_errors}
              advice={add_advice(assigns)}
              code_issue={add_code_issue(assigns)}
              zone_note={add_zone_note(assigns)}
              saving?={@add_saving}
              coords_open?={@coords_open?}
              tech_open?={@tech_open?}
              failure={@add_failure}
            />
          <% else %>
            <%= if @panel == :edit do %>
              <.edit_panel
                id="stops-map-edit-panel"
                stop={@edit_stop}
                form={@edit_form}
                where={edit_where(assigns)}
                usage={@edit_usage}
                zone_id={@edit_stop && @edit_stop.zone_id}
                zone_name={@edit_zone_name}
                zone_href={~p"/gtfs/#{@current_gtfs_version.id}/settings/fares"}
                errors={@edit_errors}
                dirty?={@edit_dirty?}
                saving?={@edit_saving}
                outcome={@edit_outcome}
                review_band={@edit_review_band}
                conflict={@edit_conflict}
                more_open?={@edit_more_open?}
                tech_open?={@edit_tech_open?}
                discard_action={@discard_action}
              />
            <% else %>
              <%= if @panel == :created do %>
                <.created_panel
                  id="stops-map-created-panel"
                  stop={@created_stop}
                  version_name={@current_gtfs_version.name}
                />
              <% else %>
                <.browse_panel
                  id="stops-map-panel"
                  title={panel_title(assigns)}
                  subtitle={panel_subtitle(assigns)}
                >
                  <div class="px-5">
                    <.search_field
                      id="stops-map-search"
                      form={@search_form}
                      label="Find a stop, street or place"
                      placeholder="Name, stop ID or cross street"
                    />
                  </div>

                  <%= if @stops_state == :loading do %>
                    <div id="stops-map-panel-loading" role="status">
                      <span class="sr-only">Loading stops&hellip;</span>
                      <.browse_panel_loading id="stops-map-skeleton" />
                    </div>
                  <% else %>
                    <%= if @model == nil or @model.stops == [] do %>
                      <.first_use_panel id="stops-map-first-use" version={@current_gtfs_version} />
                    <% else %>
                      <%!-- A search replaces the list rather than sitting above it:
                        forty rows under a result set is a page an editor has to
                        scroll past to see what they searched for. --%>
                      <%= if @search_query == "" do %>
                        <%= if panel_checks(assigns) != [] do %>
                          <.checks_disclosure
                            id="stops-map-checks"
                            checks={panel_checks(assigns)}
                            open?={@checks_open}
                          />
                        <% end %>
                        <.stop_list id="stops-map-list" stops={panel_rows(assigns)} />
                      <% else %>
                        <.search_results
                          id="stops-map-search-results"
                          query={@search_query}
                          stops={@search_stops}
                          places={@search_places}
                          unavailable?={@search_unavailable?}
                        />
                      <% end %>
                    <% end %>
                  <% end %>
                </.browse_panel>
              <% end %>
            <% end %>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # The read runs in the LiveView process so the panel and the map never wait on
  # it: the page paints its chrome and the loading states first, and the list
  # arrives when the read does.
  defp start_load(socket) do
    organization_id = socket.assigns.current_organization.id
    gtfs_version_id = socket.assigns.current_gtfs_version.id

    start_async(socket, :load_model, fn -> StopsMap.load(organization_id, gtfs_version_id) end)
  end

  # A version with no stops opens the first-use panel rather than an empty list.
  # An empty list would read as a broken read; this reads as a version nobody has
  # added stops to yet. A create in flight is not disturbed by the reload that
  # follows it: the created stop is in the feed now, so the panel that is about
  # to answer is the created one.
  defp assign_new_panel(%{panel: :browse} = socket) do
    case socket.assigns.model do
      %{stops: []} -> assign(socket, :panel, :first_use)
      _model -> socket
    end
  end

  defp assign_new_panel(socket), do: socket

  defp push_scene(socket) do
    case socket.assigns.model do
      nil ->
        socket

      model ->
        push_event(socket, "stop_map:scene", %{
          payload:
            StopsMap.display_payload(model, @line_tolerance_m)
            |> Map.put(:tolerance_m, @line_tolerance_m)
        })
    end
  end

  # The rows the panel lists: the stops inside the view the hook last reported,
  # or every located stop before any view has been reported. Sorting puts
  # stations first (an editor looking for a stop looks for its station), then
  # orders by name so the list does not jump as the map pans.
  defp panel_rows(assigns) do
    stops =
      case assigns.view_bounds do
        nil -> located_stops(assigns.model)
        bounds -> Enum.filter(located_stops(assigns.model), &inside?(&1.point, bounds))
      end

    stops
    |> Enum.sort_by(&{&1.location_type != 1, &1.name || &1.stop_id})
    |> Enum.take(@panel_limit)
    |> Enum.map(&row(assigns.model, &1))
  end

  defp row(model, stop) do
    %{
      id: stop.stop_id,
      stop_id: stop.stop_id,
      name: stop.name || stop.stop_id,
      desc: stop.desc,
      code: stop.code,
      location_type: stop.location_type,
      served?: stop.served?,
      bays: bay_count(model, stop),
      routes: stop_routes(model, stop)
    }
  end

  defp located_stops(nil), do: []

  defp located_stops(model), do: Enum.filter(model.stops, & &1.point)

  # A stop's routes are the routes of the patterns that visit it. The model
  # carries the patterns per stop and the route per pattern, so this is a
  # lookup rather than a second read.
  defp stop_routes(model, stop) do
    route_ids =
      model.lines
      |> Enum.filter(&(&1.pattern_id in stop.pattern_ids))
      |> Enum.map(& &1.route_id)
      |> Enum.uniq()

    route_ids
    |> Enum.map(&Map.get(model.routes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&(&1.short_name || &1.long_name || &1.route_id))
  end

  # A station's bays are the stops that name it as their parent. The model
  # carries each stop's `parent_station`, so this is a count over what is loaded
  # rather than a read.
  defp bay_count(model, stop) do
    model.stops
    |> Enum.count(&(&1.parent_station == stop.stop_id))
  end

  defp inside?(nil, _bounds), do: false

  defp inside?({lon, lat}, {south, west, north, east}) do
    lat >= south and lat <= north and lon >= west and lon <= east
  end

  defp stop_count(nil), do: 0
  defp stop_count(%{stops: stops}), do: Enum.count(stops, &(&1.location_type == 0))

  defp station_count(nil), do: 0
  defp station_count(%{stops: stops}), do: Enum.count(stops, &(&1.location_type == 1))

  # A chosen search result takes over the panel's heading. Step 30 replaces
  # this with the edit panel's own heading; until then the selection has to be
  # visible somewhere, and the heading is the one place the editor is already
  # looking.
  defp panel_title(%{selected_stop_id: stop_id} = assigns) when is_binary(stop_id) do
    case selected_row(assigns, stop_id) do
      %{name: name} -> name
      nil -> panel_title(%{assigns | selected_stop_id: nil})
    end
  end

  defp panel_title(%{panel: :first_use}), do: "No stops in this version yet"

  defp panel_title(%{stops_state: :unavailable}), do: "Stops could not load"
  defp panel_title(_assigns), do: "Stops in this area"

  defp panel_subtitle(%{selected_stop_id: stop_id} = assigns) when is_binary(stop_id) do
    case selected_row(assigns, stop_id) do
      nil -> panel_subtitle(%{assigns | selected_stop_id: nil})
      row -> StopsMapComponents.selection_note(row)
    end
  end

  defp panel_subtitle(%{stops_state: :loading}), do: "Reading this version’s stops…"
  defp panel_subtitle(%{stops_state: :unavailable}), do: "The list is kept."

  defp panel_subtitle(%{panel: :first_use}),
    do: "This version was started from scratch."

  defp panel_subtitle(%{view_bounds: nil} = assigns) do
    # The same wording the header uses, so the header and the panel cannot
    # disagree about how many stops the version has: stations are counted
    # separately in both, and only the listed rows are counted here.
    listed = panel_rows(assigns)

    StopsMapComponents.scope_note(%{
      stop_count: count_type(listed, 0),
      station_count: count_type(listed, 1),
      loading: false,
      version: assigns.current_gtfs_version
    })
  end

  defp panel_subtitle(%{view_bounds: _bounds} = assigns) do
    listed = panel_rows(assigns) |> length()

    "#{listed} on the map · pan or zoom to change the list"
  end

  defp count_type(rows, location_type) do
    Enum.count(rows, &(&1.location_type == location_type))
  end

  # The row for a chosen result, rebuilt from the loaded model rather than
  # remembered: a stop that was removed while the panel was open has no row,
  # and a heading for a stop this version no longer holds would be a lie.
  defp selected_row(%{model: nil}, _stop_id), do: nil

  defp selected_row(assigns, stop_id) do
    case Enum.find(located_stops(assigns.model), &(&1.stop_id == stop_id)) do
      nil -> nil
      stop -> row(assigns.model, stop)
    end
  end

  # The mode, the pin and the ghost are the hook's half of a placement, and the
  # server decides all three: a point only becomes the pin once the server has
  # read it, and the pin only moves when the server echoes a new point. Add mode
  # is the panel asking for a place, so it ends as soon as there is one.
  defp push_map_mode(socket) do
    # `push_event/3` answers the socket with the push on it, and that answer is
    # the socket: dropping it drops the push, silently, and the map goes on
    # believing it is browsing while the panel is asking for a place.
    if connected?(socket) do
      push_event(socket, "stop_map:mode", mode_payload(socket.assigns))
    else
      socket
    end
  end

  # Add mode is the panel asking for a place, so it ends as soon as there is
  # one: a placed stop is adjusted by its pin, not by placing it again.
  defp mode_payload(%{placement: {lat, lon}}),
    do: %{mode: :browse, pin: %{lat: lat, lon: lon, label: "New stop"}, ghost: nil}

  defp mode_payload(assigns) do
    mode = if assigns.panel == :add, do: :add, else: :browse

    # `ghost` is the position a stop already has in the database, which no
    # placement has yet.
    %{mode: mode, pin: nil, ghost: nil}
  end

  # A point that cannot be read is refused rather than clamped. A lat/lon pair
  # is a position on the Earth, and "north" is not one; saving a clamped pair
  # would put a stop in a place nobody chose.
  defp assign_placement(socket, params) do
    case parse_point(params) do
      {:ok, {lat, lon}} ->
        socket
        |> assign(:placement, {lat, lon})
        |> seed_coordinates(lat, lon)
        |> push_map_mode()

      :error ->
        socket
    end
  end

  # The two coordinate fields are the pin's own numbers, so a pin that moved
  # takes them with it. An editor who then types a pair into them has said
  # something different, and the create flow asks about the disagreement rather
  # than resolving it silently.
  defp seed_coordinates(socket, lat, lon) do
    draft =
      socket.assigns.add_draft
      |> Map.put("lat", coordinate_text(lat))
      |> Map.put("lon", coordinate_text(lon))

    assign_draft(socket, draft)
  end

  defp coordinate_text(value) do
    value |> Float.round(5) |> to_string()
  end

  defp parse_point(%{"lat" => lat, "lon" => lon}) do
    with {:ok, lat} <- number(lat),
         {:ok, lon} <- number(lon),
         true <- abs(lat) <= 90.0,
         true <- abs(lon) <= 180.0 do
      {:ok, {lat, lon}}
    else
      _ -> :error
    end
  end

  defp parse_point(_params), do: :error

  defp map_caption(%{panel: :add, placement: nil}) do
    %{
      title: "Click the curb where riders wait",
      text:
        "Zoom in until you can see the street edge. Press Enter to place it at the crosshair. Escape cancels."
    }
  end

  defp map_caption(%{panel: :add, placement: {_lat, _lon}}) do
    %{
      title: "Drag the pin to adjust",
      text: "Or focus the pin and use the arrow keys: about 3 ft a press, 30 ft with Shift."
    }
  end

  defp map_caption(_assigns), do: nil

  # Bounds arrive from the hook as JSON numbers. A view that cannot be read is
  # rejected rather than clamped: a clamped box would quietly list the wrong
  # stops.
  defp parse_bounds(%{"south" => south, "west" => west, "north" => north, "east" => east}) do
    with {:ok, south} <- number(south),
         {:ok, west} <- number(west),
         {:ok, north} <- number(north),
         {:ok, east} <- number(east),
         true <- south <= north and west <= east do
      {:ok, {south, west, north, east}}
    else
      _ -> :error
    end
  end

  defp parse_bounds(_params), do: :error

  defp number(value) when is_number(value), do: {:ok, value * 1.0}

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp number(_value), do: :error
end

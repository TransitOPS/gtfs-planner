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
      move_review_panel: 1,
      delete_panel: 1,
      replace_panel: 1,
      station_panel: 1,
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

  # How far the nearest stops the replace panel offers are looked for, and how
  # many it shows. A replace is a question about the same place, so the radius
  # is the one a rider would call the same place; the count is the prototype's
  # and keeps the list inside one screen at 390 px.
  @landmark_metres 90.0
  @replace_candidate_metres 260.0
  @replace_candidate_limit 4

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
     |> assign(:requested_stop_id, nil)
     |> assign(:requested_add?, false)
     |> assign(:requested_action, nil)
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
    |> assign_move_state()
    |> assign_delete_state()
    |> assign_replace_state()
    |> assign_station_state()
    |> assign(:discard_action, nil)
    |> assign_edit_draft(empty_edit_draft())
  end

  # Everything the delete panels own, in one place, for the same reason the edit
  # state's: the review is read when the editor asks what deleting would remove,
  # and its fingerprint — never a value the browser sends back — is what the
  # command re-checks, so a reference created while the question was open
  # refuses the delete rather than cascading a row nobody saw.
  defp assign_delete_state(socket) do
    socket
    |> assign(:delete_review, nil)
    |> assign(:delete_loading?, false)
    |> assign(:delete_saving?, false)
    |> assign(:delete_outcome, :none)
  end

  # Everything the make-station panel owns. The form is a `to_form/2` over the
  # two fields the command casts, so a value the browser invents beyond them
  # cannot reach it (INV-5).
  defp assign_station_state(socket) do
    socket
    |> assign(:station_draft, nil)
    |> assign(:station_form, nil)
    |> assign(:station_errors, %{})
    |> assign(:station_landmark, nil)
    |> assign(:station_refusal, nil)
    |> assign(:station_loading?, false)
    |> assign(:station_saving?, false)
    |> assign(:station_refusal, nil)
  end

  # Everything the replace panel owns. The chosen stop is a GTFS ID because that
  # is what the candidates, the map click and the command's own lookup all
  # speak; the review and its fingerprint stay in the assign for the same reason
  # the delete review's does.
  defp assign_replace_state(socket) do
    socket
    |> assign(:replace_candidates, [])
    |> assign(:replace_with, nil)
    |> assign(:replace_review, nil)
    |> assign(:replace_refusals, nil)
    |> assign(:replace_loading?, false)
    |> assign(:replace_saving?, false)
    |> assign(:replace_outcome, :none)
    |> assign(:replace_delete_old, true)
  end

  # Everything the move review owns, in one place, for the same reason the edit
  # state is: the review is opened from a save, from a keyboard nudge or from a
  # restored panel, and every one of those starts from the same empty question
  # rather than from whatever the last move left behind.
  defp assign_move_state(socket) do
    socket
    # The pending move: how far the pin is from the saved position and which
    # band that falls in. `nil` until the pin moves, and `nil` again when it is
    # put back, so the panel never describes a move that is not on the map.
    |> assign(:edit_move, nil)
    |> assign(:move_review, nil)
    |> assign(:move_loading?, false)
    |> assign(:move_lines, :redraw)
    |> assign(:move_answer, nil)
    |> assign(:move_errors, [])
    |> assign(:move_saving?, false)
    |> assign(:move_outcome, :none)
    |> assign(:move_saved, nil)
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

      # `?add=1` is the list's Add stop primary arriving here. It is remembered
      # for the same reason `?stop=` is: the add panel replaces the browse or
      # first-use panel, and which of those the page shows is only known once
      # the model says whether the version holds any stops.
      socket =
        if params["add"] in ["1", "true"] do
          assign(socket, :requested_add?, true)
        else
          assign(socket, :requested_add?, false)
        end

      # `?action=` is the stop page's More actions arriving here. It is held
      # until the stop is open, because every action needs the edit panel's own
      # state behind it, and it is not acted on for a stop this version does not
      # hold — a stale link opens the browse panel rather than a panel about a
      # stop nobody can see.
      socket =
        case params["action"] do
          "delete" -> assign(socket, :requested_action, :delete)
          "replace" -> assign(socket, :requested_action, :replace)
          "make_station" -> assign(socket, :requested_action, :station)
          _other -> assign(socket, :requested_action, nil)
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

    {:noreply, push_scene(open_requested(socket))}
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

  def handle_async(:edit_save, {:ok, {:review_required, _band}}, socket) do
    # The command refused to write and asked the question step 31 answers: a
    # move past the correction band changes which pattern lines run past the
    # stop, so it is reviewed rather than saved. The draft is kept exactly as
    # typed, because the editor's next action is to answer, not to retype.
    {:noreply, start_move_review(socket)}
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

  def handle_async(:move_review, {:ok, {:ok, review}}, socket) do
    {:noreply,
     socket
     |> assign(:move_loading?, false)
     |> assign(:move_review, review)}
  end

  # A review that could not be answered is a failure to say, not an answer: the
  # panel says the review could not run and leaves the draft where it was, so
  # the editor can press Save again rather than guess.
  def handle_async(:move_review, _result, socket) do
    {:noreply,
     socket
     |> assign(:move_loading?, false)
     |> assign(:move_outcome, :review_failed)}
  end

  def handle_async(:move_apply, {:ok, {:ok, result}}, socket) do
    reloaded = reload_stop(socket, result.stop)

    {:noreply,
     socket
     |> assign(:move_saving?, false)
     |> assign(:move_outcome, :moved)
     |> assign(:move_saved, %{redrawn: result.redrawn, stale: result.stale})
     |> assign_move_state_after_apply()
     |> assign_edit_stop(reloaded)
     |> start_edit_usage(reloaded)
     |> start_load()}
  end

  # The review was answered against a version of the data that has since moved
  # on. Nothing was written, and the review is dropped rather than re-run: the
  # editor's next action is to look at the stop again, not to be offered the
  # same question about facts that no longer hold.
  def handle_async(:move_apply, {:ok, {:error, :stale_review}}, socket) do
    # The conflict block names who changed the stop and what they changed, which
    # the audit log is asked about through the row itself — so the row is read
    # back rather than the panel's row, which is the same row with fewer fields.
    changed =
      case socket.assigns.edit_stop do
        nil -> nil
        row -> reload_stop_row(socket, row.stop_id) || row
      end

    {:noreply,
     socket
     |> assign(:move_saving?, false)
     |> assign(:move_outcome, :stale_review)
     |> assign_edit_conflict(changed)}
  end

  # The far-move question has to be answered, and the answer is still missing.
  def handle_async(:move_apply, {:ok, {:error, :answer_required}}, socket) do
    {:noreply,
     socket
     |> assign(:move_saving?, false)
     |> assign(:move_errors, ["Choose one. A move this far changes where riders wait."])}
  end

  def handle_async(:move_apply, {:ok, {:error, :new_stop}}, socket) do
    # "No, this is a new stop" is an answer, not a refusal: the move stops here
    # and the pin becomes the start of an add, with the old stop left alone.
    {:noreply, begin_add_at_pin(socket)}
  end

  def handle_async(:move_apply, {:ok, {:error, %Ecto.Changeset{} = changeset}}, socket) do
    {:noreply,
     socket
     |> assign(:move_saving?, false)
     |> assign_edit_draft(socket.assigns.edit_draft, edit_changeset_errors(changeset))}
  end

  def handle_async(:move_apply, _result, socket) do
    {:noreply,
     socket
     |> assign(:move_saving?, false)
     |> assign(:move_outcome, :move_failed)}
  end

  def handle_async(:delete_review, {:ok, {:ok, review}}, socket) do
    {:noreply,
     socket
     |> assign(:delete_loading?, false)
     |> assign(:delete_review, review)}
  end

  # A review that could not be read is a failure to say, not an answer: the
  # panel says so and keeps the stop, rather than offering a delete button that
  # was asked about nothing.
  def handle_async(:delete_review, _result, socket) do
    {:noreply,
     socket
     |> assign(:delete_loading?, false)
     |> assign(:delete_review, nil)
     |> assign(:delete_outcome, :failed)}
  end

  # A deleted stop is gone from the panel as well as from the feed: the panel
  # would otherwise keep rendering a row the model no longer holds.
  def handle_async(:delete_stop, {:ok, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, deleted_message(socket.assigns.edit_stop, result.removed))
     |> close_edit()
     |> assign_delete_state()
     |> start_load()}
  end

  # A reference appeared while the question was open. Nothing was written, and
  # the review is read again rather than re-used: the list the editor is looking
  # at is the one the command saw when it refused.
  def handle_async(:delete_stop, {:ok, {:error, {:blocked, _items}}}, socket) do
    {:noreply, restart_delete_review(socket, :refused)}
  end

  # A reference appeared or vanished: the review's fingerprint no longer
  # describes the stop. Nothing was written either, and the editor is told so in
  # the same words as any other refusal.
  def handle_async(:delete_stop, {:ok, {:error, :stale_review}}, socket) do
    {:noreply, restart_delete_review(socket, :refused)}
  end

  def handle_async(:delete_stop, {:ok, {:error, :not_found}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "That stop is no longer in this version.")
     |> close_edit()
     |> assign_delete_state()
     |> start_load()}
  end

  def handle_async(:delete_stop, _result, socket) do
    {:noreply, socket |> assign(:delete_saving?, false) |> assign(:delete_outcome, :failed)}
  end

  # A refusal is not a failure: the panel shows the words and offers nothing to
  # press, because the command would refuse the same choice again.
  def handle_async({:landmark, token}, {:ok, {:ok, places}}, socket) do
    if socket.assigns.place_token == token do
      socket =
        socket
        |> assign(:station_loading?, false)
        |> put_station_landmark(places)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:landmark, _token}, _result, socket) do
    # A landmark is a convenience. When the lookup fails the field keeps the
    # stop's own name, which is always a usable starting point.
    {:noreply, assign(socket, :station_loading?, false)}
  end

  def handle_async(:station_create, {:ok, {:ok, %{station: station, stop: bay}}}, socket) do
    socket =
      socket
      |> assign_station_state()
      |> put_flash(:info, "#{station.stop_name} is a station, and #{bay.stop_name} is its bay.")
      |> then(fn closed -> open_edit(closed, bay.stop_id) end)
      |> assign(:selected_stop_id, bay.stop_id)
      |> start_load()

    {:noreply, socket}
  end

  def handle_async(:station_create, {:ok, {:error, reason}}, socket) do
    # The refusals say which part of the feed already answered the question,
    # and the panel stays open with the draft so a refusal costs no typing.
    {:noreply,
     socket
     |> assign(:station_saving?, false)
     |> assign(:station_refusal, station_refusal_text(reason))}
  end

  def handle_async(:station_create, _result, socket) do
    {:noreply,
     socket
     |> assign(:station_saving?, false)
     |> assign(:station_refusal, "The station could not be created. Nothing was changed.")}
  end

  # A stop the feed has already answered for is refused as the panel opens: the
  # form is not shown, because there is nothing to type.
  def handle_async(:replace_review, {:ok, {:ok, review}}, socket) do
    {:noreply,
     socket
     |> assign(:replace_loading?, false)
     |> assign(:replace_review, review)
     |> assign(:replace_refusals, nil)
     |> assign(:replace_outcome, :none)}
  end

  def handle_async(:replace_review, {:ok, {:error, {:refused, reasons}}}, socket) do
    {:noreply,
     socket
     |> assign(:replace_loading?, false)
     |> assign(:replace_review, nil)
     |> assign(:replace_refusals, reasons)
     |> assign(:replace_outcome, :refused)}
  end

  def handle_async(:replace_review, _result, socket) do
    {:noreply,
     socket
     |> assign(:replace_loading?, false)
     |> assign(:replace_review, nil)
     |> assign(:replace_refusals, nil)
     |> assign(:replace_outcome, :failed)}
  end

  # The editor is left on the stop that is now the stop: the panel moves to it,
  # because what is being edited has changed identity rather than content.
  def handle_async(:replace_apply, {:ok, {:ok, result}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, replaced_message(socket.assigns.edit_stop, result.new))
     |> close_edit()
     |> then(fn closed -> open_edit(closed, result.new.stop_id) end)
     |> assign(:selected_stop_id, result.new.stop_id)
     |> start_load()}
  end

  def handle_async(:replace_apply, {:ok, {:error, {:refused, reasons}}}, socket) do
    {:noreply,
     socket
     |> assign(:replace_saving?, false)
     |> assign(:replace_review, nil)
     |> assign(:replace_refusals, reasons)
     |> assign(:replace_outcome, :refused)}
  end

  def handle_async(:replace_apply, {:ok, {:error, :stale_review}}, socket) do
    {:noreply,
     socket
     |> assign(:replace_saving?, false)
     |> assign(:replace_outcome, :stale)
     |> push_map_mode()}
  end

  def handle_async(:replace_apply, _result, socket) do
    {:noreply, socket |> assign(:replace_saving?, false) |> assign(:replace_outcome, :failed)}
  end

  # A move that landed is a move that is over: the review, the pending move and
  # the pin's ghost all belong to the position the stop no longer has.
  defp assign_move_state_after_apply(socket) do
    socket
    |> assign(:edit_move, nil)
    |> assign(:move_review, nil)
    |> assign(:move_errors, [])
  end

  # --- deleting --------------------------------------------------------------

  # The review is read in the LiveView process, like the move review: it takes no
  # locks and asks the reference catalog what names this stop, and the answer is
  # shown rather than written. The outcome is left alone here, because a refusal
  # re-reads the review and must keep saying why it refused.
  defp start_delete_review(socket) do
    case socket.assigns.edit_stop do
      nil ->
        socket

      %{uuid: uuid} ->
        audit = audit_context(socket.assigns)

        socket = socket |> assign(:delete_loading?, true)

        start_async(socket, :delete_review, fn -> StopEditing.delete_review(uuid, audit) end)
    end
  end

  # A refusal re-reads the review rather than reusing the one that was refused,
  # and keeps the outcome the command reported: the list the editor is reading
  # is the list the command saw.
  defp restart_delete_review(socket, outcome) do
    socket
    |> assign(:delete_saving?, false)
    |> assign(:delete_loading?, false)
    |> assign(:delete_outcome, outcome)
    |> start_delete_review()
  end

  # The command is the editor's answer and the panel sends only that. The review
  # that produced the fingerprint stays in the assign, so a `fingerprint` posted
  # by the browser cannot name a deletion the editor was never shown (the step-31
  # rule, applied to the delete).
  defp start_delete(socket) do
    with %{delete_review: review} when is_map(review) <- socket.assigns,
         %{uuid: uuid} <- socket.assigns.edit_stop do
      audit = audit_context(socket.assigns)

      socket = socket |> assign(:delete_saving?, true) |> assign(:delete_outcome, :none)

      start_async(socket, :delete_stop, fn ->
        StopEditing.delete_stop(uuid, review.fingerprint, audit)
      end)
    else
      _no_review -> socket
    end
  end

  # --- replacing ------------------------------------------------------------

  # The candidates are the nearest few stops the model already holds, so opening
  # the panel reads nothing: the version's stops are on the page. A station or a
  # bay is never offered, because the command refuses both and offering them
  # would be offering a choice that cannot be made.
  defp start_replace(socket) do
    case socket.assigns.edit_stop do
      nil ->
        socket

      %{stop_id: stop_id} ->
        socket =
          socket
          |> assign_replace_state()
          |> assign(:replace_candidates, replace_candidates(socket.assigns, stop_id))

        case socket.assigns.replace_candidates do
          [] -> socket
          [nearest | _] -> choose_replace(socket, nearest.stop_id)
        end
    end
  end

  # The panel opens on the editor's own stop, a station name it can already
  # read (the stop's name), and a bay letter of A. The landmark lookup runs
  # beside it: it can replace the name with something riders know the corner
  # by, but it is a suggestion, so an empty answer leaves the field usable.
  defp start_make_station_panel(socket) do
    case socket.assigns.edit_stop do
      nil ->
        socket

      stop ->
        socket =
          socket
          |> assign(:panel, :station)
          |> assign(:station_draft, station_draft(stop))
          |> assign(:station_form, to_form(station_draft(stop), as: :station))
          |> assign(:station_saving?, false)
          |> assign(:station_refusal, nil)
          |> assign(:station_landmark, nil)

        maybe_start_landmark(socket, stop)
    end
  end

  # A stop that is already a bay, or already a station, is refused by the
  # command itself and the panel says so as it opens rather than after a press:
  # the editor has asked for something the feed already says.
  defp stationable?(stop) do
    is_nil(stop.parent_station) and stop.location_type == 0
  end

  defp station_draft(stop) do
    %{"station_name" => stop.name, "platform_code" => "A"}
  end

  defp maybe_start_landmark(socket, %{point: {lat, lon}})
       when is_number(lat) and is_number(lon) do
    token = socket.assigns.place_token + 1

    socket
    |> assign(:place_token, token)
    |> assign(:station_loading?, true)
    |> start_async({:landmark, token}, fn ->
      Geocoding.reverse(lat, lon, amenities: true, only: :amenity)
    end)
  end

  defp maybe_start_landmark(socket, _stop), do: assign(socket, :station_loading?, false)

  # The posted form is merged over the draft field by field, so a field the
  # browser did not send keeps the value it had. A field it did send wins even
  # when it is empty: clearing the name is an edit, and a merge that treated a
  # blank as "unchanged" would make the field impossible to clear.
  @station_fields ["station_name", "platform_code"]

  defp station_draft_merge(draft, params) do
    Enum.reduce(@station_fields, draft, fn field, acc ->
      case Map.fetch(params, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp change_station_field(socket, params) do
    draft = station_draft_merge(socket.assigns.station_draft || %{}, params)

    assign(socket,
      station_draft: draft,
      station_form: to_form(draft, as: :station),
      station_refusal: nil
    )
  end

  # The write is the command's own transaction (INV-2): the station and the bay
  # that names it are written together, or neither is.
  defp start_make_station(socket, params) do
    draft = station_draft_merge(socket.assigns.station_draft || %{}, params)
    errors = station_errors(socket.assigns, draft)

    case {socket.assigns.edit_stop, errors} do
      # The draft is checked against the form's own fields before the stop is
      # looked at, so a blank name is refused in the panel whether or not the
      # stop is one this command could write.
      {_, %{"station_name" => _} = field_errors} ->
        station_refused(socket, draft, field_errors)

      {nil, _no_errors} ->
        socket

      {stop, _} ->
        audit = audit_context(socket.assigns)

        socket =
          socket
          |> assign(:station_draft, draft)
          |> assign(:station_form, to_form(draft, as: :station))
          |> assign(:station_errors, %{})
          |> assign(:station_saving?, true)
          |> assign(:station_refusal, nil)

        start_async(socket, :station_create, fn ->
          StopEditing.make_station(stop.uuid, draft, audit)
        end)
    end
  end

  defp station_refused(socket, draft, errors) do
    assign(socket,
      station_draft: draft,
      station_form: to_form(draft, as: :station),
      station_errors: errors
    )
  end

  defp station_errors(assigns, draft) do
    name = draft["station_name"] |> to_string() |> String.trim()

    case stationable?(assigns.edit_stop) do
      false ->
        %{
          "station_name" =>
            {"This stop is already part of a station.", "This stop is already part of a station."}
        }

      true ->
        if name == "" do
          %{"station_name" => {"is required", "Enter the name riders look for the station by."}}
        else
          %{}
        end
    end
  end

  defp replace_candidates(%{model: model}, stop_id) when is_map(model) do
    case stop_point(model, stop_id) do
      nil ->
        []

      origin ->
        model.stops
        |> Enum.reject(&(&1.stop_id == stop_id))
        |> Enum.filter(&(&1.location_type == 0 and is_nil(&1.parent_station) and &1.point))
        |> Enum.map(&Map.put(&1, :away, StopPlacement.distance(origin, &1.point)))
        |> Enum.filter(&(&1.away <= @replace_candidate_metres))
        |> Enum.sort_by(& &1.away)
        |> Enum.take(@replace_candidate_limit)
        |> Enum.map(fn candidate ->
          %{
            id: candidate.id,
            stop_id: candidate.stop_id,
            name: candidate.name,
            desc: candidate.desc,
            away: format_distance(candidate.away)
          }
        end)
    end
  end

  defp replace_candidates(_assigns, _stop_id), do: []

  # Choosing is one question asked twice — a radio in the panel and a click on
  # the map — so both write the same assign and read the same review.
  defp choose_replace(socket, stop_id) do
    with %{edit_stop: %{uuid: old_uuid}} <- socket.assigns,
         %{uuid: new_uuid} <- replace_uuid(socket.assigns, stop_id) do
      audit = audit_context(socket.assigns)

      socket =
        socket
        |> assign(:replace_with, replace_with_row(socket.assigns, stop_id))
        |> assign(:replace_review, nil)
        |> assign(:replace_refusals, nil)
        |> assign(:replace_loading?, true)
        |> assign(:replace_outcome, :none)

      start_async(socket, :replace_review, fn ->
        StopEditing.replace_review(old_uuid, new_uuid, audit)
      end)
    else
      _not_a_stop -> socket
    end
  end

  # The model rows carry the UUID the command wants, and `stop_point/2`'s row
  # does too; a stop ID the model does not hold is not a choice.
  defp replace_uuid(%{model: model}, stop_id) when is_map(model) do
    case Enum.find(model.stops, &(&1.stop_id == stop_id)) do
      nil -> nil
      stop -> %{uuid: stop.id}
    end
  end

  defp replace_uuid(_assigns, _stop_id), do: nil

  defp replace_with_row(%{model: model}, stop_id) when is_map(model) do
    case Enum.find(model.stops, &(&1.stop_id == stop_id)) do
      nil -> nil
      stop -> %{stop_id: stop.stop_id, name: stop.name}
    end
  end

  defp replace_with_row(_assigns, _stop_id), do: nil

  # The apply carries the editor's two answers — which stop to keep, and whether
  # the old one goes — and the fingerprint from the review in the assign. The
  # `changes` the review computed are never posted back by the browser.
  defp start_replace_apply(socket) do
    with %{replace_review: review} when is_map(review) <- socket.assigns,
         %{edit_stop: %{uuid: old_uuid}} <- socket.assigns,
         %{replace_with: %{stop_id: stop_id}} <- socket.assigns,
         %{uuid: new_uuid} <- replace_uuid(socket.assigns, stop_id) do
      audit = audit_context(socket.assigns)
      options = %{fingerprint: review.fingerprint, delete_old: socket.assigns.replace_delete_old}

      socket = socket |> assign(:replace_saving?, true)

      start_async(socket, :replace_apply, fn ->
        StopEditing.replace_stop(old_uuid, new_uuid, options, audit)
      end)
    else
      _no_review -> socket
    end
  end

  # The first place within the radius is the name to start from; further ones
  # are the editor's to type. A station named after a landmark a block away is a
  # worse starting point than the stop's own name.
  defp put_station_landmark(socket, places) when is_list(places) do
    case Enum.find(places, &(is_number(&1.distance_m) and &1.distance_m <= @landmark_metres)) do
      nil ->
        assign(socket, :station_landmark, nil)

      place ->
        socket
        |> assign(:station_landmark, place.name)
        |> prefill_station_name(socket.assigns.edit_stop, place.name)
    end
  end

  defp put_station_landmark(socket, _places), do: assign(socket, :station_landmark, nil)

  # The suggestion lands in the field the editor has not typed in. A name they
  # have already written is theirs, and a landmark that overwrote it would be an
  # edit nobody made.
  defp prefill_station_name(socket, %{name: name}, landmark) do
    case socket.assigns.station_draft do
      %{"station_name" => ^name} = draft ->
        draft = Map.put(draft, "station_name", landmark)

        socket
        |> assign(:station_draft, draft)
        |> assign(:station_form, to_form(draft, as: :station))

      _typed ->
        socket
    end
  end

  defp prefill_station_name(socket, _stop, _landmark), do: socket

  defp station_refusal_for(%{station_refusal: refusal}) when is_binary(refusal), do: refusal

  defp station_refusal_for(%{edit_stop: stop}) when is_map(stop) do
    if stationable?(stop), do: nil, else: station_refusal_text(child_or_children(stop))
  end

  defp station_refusal_for(_assigns), do: nil

  defp child_or_children(%{parent_station: parent}) when is_binary(parent) and parent != "",
    do: :child

  defp child_or_children(_stop), do: :has_children

  defp station_refusal_text(:child),
    do: "This stop is already a bay of a station, and a bay cannot become a station."

  defp station_refusal_text(:has_children),
    do: "This stop already has bays, so it is a station already."

  defp station_refusal_text(_reason),
    do: "The station could not be created. Nothing was changed."

  defp replaced_message(nil, _new), do: "The references were moved."

  defp replaced_message(old, new), do: "What used #{old.name} now uses #{new.stop_name}."

  defp deleted_message(nil, _removed), do: "That stop was deleted."

  defp deleted_message(stop, removed) do
    rows =
      removed
      |> Enum.map(fn {kind, count} -> "#{count} #{kind}" end)
      |> Enum.sort()
      |> Enum.join(", ")

    case rows do
      "" -> "#{stop.name} was deleted."
      rows -> "#{stop.name} was deleted, along with #{rows} that named it."
    end
  end

  # The usage is read from one stop's struct, so the reply has to name the stop
  # it was read for or the panel cannot tell whether it is still the right one.
  defp usage_matches_panel?(%{edit_usage_for: stop_id, edit_stop: %{stop_id: stop_id}}, _usage),
    do: true

  defp usage_matches_panel?(_assigns, _usage), do: false

  # Every keystroke arrives as the whole form, so the draft is merged field by
  # field rather than replaced: a param the panel does not name is not a field
  # (the whitelist), and a field the browser did not send keeps its value
  # rather than being blanked by an omission.
  #
  # The move is recomputed here rather than only on a `pin_moved`, because the
  # two coordinates are also fields: a pair typed into them is the same move,
  # and the distance label the panel shows has to agree with the map.
  defp apply_edit_field(socket, params) do
    socket
    |> assign_edit_draft(merge_draft(socket.assigns.edit_draft, params, @edit_fields), %{})
    |> assign(:edit_outcome, :none)
    |> assign(:edit_conflict, nil)
    |> refresh_edit_move()
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

  defp guard_edit(socket, {:delete}),
    do: socket |> assign(:delete_outcome, :none) |> start_delete_review()

  defp guard_edit(socket, {:replace}),
    do: socket |> assign_replace_state() |> start_replace()

  defp guard_edit(socket, {:station}),
    do: socket |> assign_station_state() |> start_make_station_panel()

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
    |> assign_station_state()
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
  # --- moving ----------------------------------------------------------------

  # A pin report while the edit panel is open is a move, not a placement: the
  # point becomes the draft's position and the saved position stays where it
  # is. The two coordinate fields follow the pin, because they are the same
  # position written down rather than a second, competing one.
  defp move_edit_pin(socket, lat, lon) do
    draft =
      socket.assigns.edit_draft
      |> Map.put("stop_lat", coordinate_text(lat))
      |> Map.put("stop_lon", coordinate_text(lon))

    socket
    |> assign_edit_draft(draft, %{})
    |> assign(:edit_outcome, :none)
    |> refresh_edit_move()
    |> assign_dirty()
  end

  # Putting the pin back is not the same as closing the panel: the draft goes to
  # the saved position and every other typed field survives, because the editor
  # asked to undo the move, not the edit.
  defp put_back_edit_move(socket) do
    case socket.assigns.edit_baseline do
      baseline when is_map(baseline) ->
        socket
        |> assign_edit_draft(
          Map.merge(socket.assigns.edit_draft, %{
            "stop_lat" => baseline["stop_lat"],
            "stop_lon" => baseline["stop_lon"]
          }),
          %{}
        )
        |> assign(:edit_outcome, :none)
        |> refresh_edit_move()
        |> assign_dirty()
        |> push_map_mode()

      _no_baseline ->
        socket
    end
  end

  # The pending move, measured on the server from the draft against the row the
  # panel loaded. `nil` means there is no move to talk about: either the draft
  # still holds the saved coordinates or one of them cannot be read, and a
  # distance to nowhere is worse than no distance at all.
  defp refresh_edit_move(socket) do
    socket
    |> assign(:edit_move, edit_move(socket.assigns))
    |> push_map_mode()
  end

  defp edit_move(%{edit_baseline: baseline, edit_draft: draft, edit_stop: stop})
       when is_map(baseline) and not is_nil(stop) do
    with {:ok, {lat, lon}} <-
           parse_point(%{"lat" => draft["stop_lat"], "lon" => draft["stop_lon"]}),
         {:ok, {base_lat, base_lon}} <-
           parse_point(%{"lat" => baseline["stop_lat"], "lon" => baseline["stop_lon"]}),
         distance when distance > 0.5 <-
           StopPlacement.distance({base_lon, base_lat}, {lon, lat}) do
      %{
        distance_m: distance,
        band: StopPlacement.move_band(distance, stop.routes != []),
        lat: lat,
        lon: lon
      }
    else
      _not_a_move -> nil
    end
  end

  defp edit_move(_assigns), do: nil

  # The draft's position as geometry. `nil` when the draft holds no readable
  # pair, which is what keeps a forged or half-typed coordinate from being
  # centred on or sent to a review.
  defp draft_point(%{edit_draft: draft}) do
    case parse_point(%{"lat" => draft["stop_lat"], "lon" => draft["stop_lon"]}) do
      {:ok, {lat, lon}} -> {lon, lat}
      :error -> nil
    end
  end

  # The review is read in the LiveView process rather than in the command's
  # transaction, because `move_review/3` asks Geoapify for street geometry and
  # an external call does not belong inside a transaction that is holding locks.
  defp start_move_review(socket) do
    case {socket.assigns.edit_stop, draft_point(socket.assigns)} do
      {%{uuid: uuid}, point} when not is_nil(point) ->
        audit = audit_context(socket.assigns)

        socket =
          socket
          |> assign(:edit_saving, false)
          |> assign(:move_loading?, true)
          |> assign(:move_outcome, :none)
          |> assign(:move_errors, [])
          |> assign(:move_review, nil)
          |> assign(:move_answer, nil)

        start_async(socket, :move_review, fn -> StopEditing.move_review(uuid, point, audit) end)

      _no_stop_or_point ->
        socket |> assign(:edit_saving, false) |> assign(:edit_outcome, :failed)
    end
  end

  # The apply is the editor's answer, so the panel sends only the answers: which
  # lines, and whether the move is the same stop. The geometry the review read
  # is held in the assign, never posted back by the browser — a `suggestions`
  # map that arrived from the client would be a map the server never derived.
  defp start_apply_move(socket) do
    with %{move_review: review} when is_map(review) <- socket.assigns,
         %{uuid: uuid} <- socket.assigns.edit_stop,
         attrs when is_map(attrs) <-
           edit_attrs(socket.assigns, socket.assigns.edit_stop, socket.assigns.edit_draft) do
      options = %{
        lines: socket.assigns.move_lines,
        answer: socket.assigns.move_answer,
        fingerprint: review.fingerprint,
        suggestions: review.suggestions,
        point: draft_point(socket.assigns)
      }

      audit = audit_context(socket.assigns)

      socket = socket |> assign(:move_saving?, true) |> assign(:move_errors, [])

      start_async(socket, :move_apply, fn ->
        StopEditing.apply_move(uuid, attrs, options, audit)
      end)
    else
      _nothing_to_apply -> socket
    end
  end

  # The answers are a whitelist for the same reason the fields are: a param the
  # panel does not name is not an answer, and the value the command receives is
  # one of the two words it understands.
  defp assign_move_choice(socket, %{"lines" => lines}) do
    assign(socket, :move_lines, if(lines == "keep", do: :keep, else: :redraw))
  end

  defp assign_move_choice(socket, %{"answer" => answer}) do
    assign(socket, :move_answer, if(answer == "new", do: :new, else: :same))
  end

  defp assign_move_choice(socket, _params), do: socket

  # "No, this is a new stop" hands the pin to the add flow. The old stop is left
  # exactly as it was — nothing was written — and the new stop starts at the
  # point the editor chose rather than at the stop's old position.
  defp begin_add_at_pin(socket) do
    {lat, lon} =
      case socket.assigns.edit_move do
        %{lat: lat, lon: lon} -> {lat, lon}
        _no_move -> {nil, nil}
      end

    socket
    |> assign(:move_review, nil)
    |> assign(:move_saving?, false)
    |> assign(:move_outcome, :none)
    |> begin_add(:stop)
    |> then(fn add ->
      if is_nil(lat) do
        add
      else
        add |> assign(:placement, {lat, lon}) |> seed_coordinates(lat, lon)
      end
    end)
    |> push_map_mode()
  end

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

  def handle_event("put_back", _params, socket),
    do: {:noreply, put_back_edit_move(socket)}

  # A pin that moved outside the view is still the stop's position: it is simply
  # not on screen. The panel says so and offers to bring it back, because a pin
  # the editor cannot see is a pin they cannot judge.
  def handle_event("find_pin", _params, socket) do
    {:noreply, push_focus(socket, draft_point(socket.assigns))}
  end

  # The review is opened by a save that came back `{:review_required, _}`, so the
  # question the editor is answering is the one the command asked rather than a
  # second read the panel invented.
  def handle_event("move_choice", params, socket) do
    {:noreply, assign_move_choice(socket, params)}
  end

  def handle_event("back_to_edit", _params, socket) do
    # Back to editing keeps the draft and the pending move: the review is a
    # question about this move, and leaving it does not answer it or discard it.
    # The delete panels answer the same way — keeping the stop writes nothing.
    {:noreply,
     socket
     |> assign(:move_review, nil)
     |> assign(:move_loading?, false)
     |> assign(:move_outcome, :none)
     |> assign_delete_state()
     |> assign_replace_state()
     |> assign_station_state()
     |> push_map_mode()}
  end

  # Asking what deleting would remove goes through the same guard as every other
  # exit out of the form: a draft the editor has not saved is theirs, and opening
  # another question over it is not a reason to lose it.
  def handle_event("start_delete", _params, socket) do
    {:noreply, guard_edit(socket, {:delete})}
  end

  def handle_event("delete_stop", _params, socket) do
    {:noreply, start_delete(socket)}
  end

  def handle_event("start_replace", _params, socket) do
    {:noreply, guard_edit(socket, {:replace})}
  end

  def handle_event("choose_replace", %{"stop_id" => stop_id}, socket) do
    {:noreply, choose_replace(socket, stop_id)}
  end

  def handle_event("choose_replace", _params, socket), do: {:noreply, socket}

  def handle_event("replace_delete_old", %{"delete" => value}, socket) do
    {:noreply, assign(socket, :replace_delete_old, value == "true")}
  end

  def handle_event("replace_delete_old", _params, socket), do: {:noreply, socket}

  def handle_event("apply_replace", _params, socket) do
    {:noreply, start_replace_apply(socket)}
  end

  def handle_event("start_make_station", _params, socket) do
    {:noreply, guard_edit(socket, {:station})}
  end

  def handle_event("station_field", %{"station" => params}, socket),
    do: {:noreply, change_station_field(socket, params)}

  def handle_event("station_field", _params, socket), do: {:noreply, socket}

  def handle_event("create_station", %{"station" => params}, socket),
    do: {:noreply, start_make_station(socket, params)}

  def handle_event("create_station", _params, socket), do: {:noreply, socket}

  def handle_event("save_move", _params, socket) do
    {:noreply, start_apply_move(socket)}
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
      # The replace panel is a question about which stop to keep, so a click on
      # the map answers that question instead of opening the stop that was
      # clicked. The gate is the panel being open, not the model: the editor was
      # told any stop on the map can be chosen.
      socket.assigns.replace_candidates != [] and stop_in_model?(socket.assigns, stop_id) ->
        {:noreply, choose_replace(socket, stop_id)}

      !selectable_stop?(socket.assigns, stop_id) ->
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

      {:delete} ->
        # The discard is the editor's answer to "lose the draft", and the delete
        # question is asked from the stop as it is loaded rather than from the
        # row a save would have left behind.
        {:noreply,
         socket
         |> assign(:discard_action, nil)
         |> assign(:delete_outcome, :none)
         |> put_back_edit_move()
         |> start_delete_review()}

      {:replace} ->
        {:noreply,
         socket
         |> assign(:discard_action, nil)
         |> put_back_edit_move()
         |> assign_replace_state()
         |> start_replace()}
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

  # A `select_stop` is only ever a row the editor can see: a search result while
  # a search is showing, and a row of the list otherwise. The model is the wider
  # of the two, and a forged id drawn from it would open a stop the panel never
  # named, so the search narrows the answer while one is on the screen.
  defp selectable_stop?(assigns, stop_id) do
    if assigns.search_query == "" do
      stop_in_model?(assigns, stop_id)
    else
      Enum.any?(assigns.search_stops, &(&1.stop_id == stop_id))
    end
  end

  # `?stop=` is answered after the model arrives rather than in `handle_params/3`,
  # so the stop is opened from the same read everything else on the page came
  # from, and an unknown ID leaves the browse panel alone.
  defp open_requested_stop(%{assigns: %{requested_stop_id: stop_id}} = socket)
       when is_binary(stop_id) do
    if stop_in_model?(socket.assigns, stop_id) do
      socket
      |> assign(:requested_stop_id, nil)
      |> assign(:requested_add?, false)
      |> open_edit(stop_id)
      |> open_requested_action()
    else
      socket |> assign(:requested_stop_id, nil) |> assign(:requested_action, nil)
    end
  end

  defp open_requested_stop(socket), do: socket

  # `?add=1` is answered here too, for the same reason: the add panel needs the
  # scene drawn under it, and the scene comes with the model. A version that
  # holds no stops would otherwise open on its first-use card with the add panel
  # nowhere in it, which is the one state where an editor most needs a place to
  # put a stop.
  defp open_requested_add(%{assigns: %{requested_add?: true}} = socket) do
    socket
    |> assign(:requested_add?, false)
    |> begin_add(:stop)
    |> push_map_mode()
  end

  defp open_requested_add(socket), do: socket

  # Each action goes through `guard_edit/2`, which is the only way into a panel
  # and therefore the only place a dirty draft can be lost. From a link the
  # draft is always empty, so the guard has nothing to ask; it is used anyway,
  # because a second entry that skipped it is the second exit that loses one.
  defp open_requested_action(%{assigns: %{requested_action: action}} = socket)
       when action in [:delete, :replace, :station] do
    guard_edit(socket, {action})
  end

  defp open_requested_action(socket), do: assign(socket, :requested_action, nil)

  # `?stop=` names one stop and `?add=1` names no stop, so the two cannot both
  # be asked for; the stop wins because it names a subject and the add does not.
  defp open_requested(%{assigns: %{requested_stop_id: stop_id}} = socket)
       when is_binary(stop_id),
       do: open_requested_stop(socket)

  defp open_requested(socket), do: open_requested_add(socket)

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
        |> load_parent_name(stop)
        |> start_edit_usage(stop)
        |> push_map_mode()
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

  defp reload_stop_row(socket, stop_id) do
    case StopsMap.load_stop(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           stop_id
         ) do
      {:ok, reloaded} -> reloaded
      _unavailable -> nil
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
      parent_name: parent_station_name(model, stop.parent_station),
      point: stop_point(model, stop.stop_id),
      zone_id: stop.zone_id,
      level_id: stop.level_id,
      href: ~p"/gtfs/#{assigns.current_gtfs_version.id}/stops/#{stop.stop_id}",
      routes: if(stop_row, do: stop_routes(model, stop_row), else: []),
      bays: bays,
      bay_count: length(bays)
    }
  end

  # A bay's subtitle names its station, and the model read that loaded the page
  # does not have a station written after it. One read for the one row the
  # subtitle would otherwise have to fall back to naming by ID.
  defp load_parent_name(socket, %{parent_station: parent})
       when is_binary(parent) and parent != "" do
    case socket.assigns.edit_stop do
      %{parent_name: name} when is_binary(name) -> socket
      _missing -> put_parent_name(socket, parent)
    end
  end

  defp load_parent_name(socket, _stop), do: socket

  defp put_parent_name(socket, parent) do
    case StopsMap.load_stop(
           socket.assigns.current_organization.id,
           socket.assigns.current_gtfs_version.id,
           parent
         ) do
      {:ok, station} ->
        assign(
          socket,
          :edit_stop,
          Map.put(socket.assigns.edit_stop, :parent_name, station.stop_name)
        )

      _unavailable ->
        socket
    end
  end

  defp parent_station_name(model, parent) when is_binary(parent) and parent != "" do
    case Enum.find(model.stops, &(&1.stop_id == parent)) do
      nil -> nil
      station -> station.name
    end
  end

  defp parent_station_name(_model, _parent), do: nil

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
    case StopEditing.last_change(organization_id, gtfs_version_id, stop_uuid(stop)) do
      nil -> nil
      log -> log.actor_email
    end
  end

  # The panel's row names the stop `uuid`; the schema struct Ecto returns names
  # the same column `id`. Both are the same stop, so the audit log is asked with
  # whichever half the caller had.
  defp stop_uuid(%{uuid: uuid}), do: uuid
  defp stop_uuid(%{id: id}), do: id
  defp stop_uuid(_stop), do: nil

  defp changed_field_words(_organization_id, _gtfs_version_id, nil), do: []

  defp changed_field_words(organization_id, gtfs_version_id, stop) do
    case StopEditing.last_change(organization_id, gtfs_version_id, stop_uuid(stop)) do
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
              <%= if @replace_candidates != [] do %>
                <.replace_panel
                  id="stops-map-replace-panel"
                  stop={@edit_stop}
                  candidates={@replace_candidates}
                  with={@replace_with}
                  usage={@edit_usage}
                  review={@replace_review}
                  refusals={@replace_refusals || []}
                  loading?={@replace_loading?}
                  delete_old?={@replace_delete_old}
                  saving?={@replace_saving?}
                  outcome={@replace_outcome}
                />
              <% else %>
                <%= if @delete_review != nil or @delete_loading? do %>
                  <.delete_panel
                    id="stops-map-delete-panel"
                    stop={@edit_stop}
                    review={@delete_review}
                    loading?={@delete_loading?}
                    version_id={@current_gtfs_version.id}
                    saving?={@delete_saving?}
                    outcome={@delete_outcome}
                  />
                <% else %>
                  <%= if @move_review != nil or @move_loading? do %>
                    <.move_review_panel
                      id="stops-map-move-panel"
                      stop={@edit_stop}
                      review={@move_review}
                      loading?={@move_loading?}
                      distance={@edit_move && @edit_move.distance_m}
                      lines={@move_lines}
                      answer={@move_answer}
                      errors={@move_errors}
                      saving?={@move_saving?}
                      outcome={@move_outcome}
                      saved={@move_saved}
                    />
                  <% else %>
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
                      move={@edit_move}
                      move_saved={@move_saved}
                      pin_off_canvas?={pin_off_canvas?(assigns)}
                      conflict={@edit_conflict}
                      more_open?={@edit_more_open?}
                      tech_open?={@edit_tech_open?}
                      discard_action={@discard_action}
                    />
                  <% end %>
                <% end %>
              <% end %>
            <% else %>
              <%= if @panel == :station do %>
                <.station_panel
                  id="stops-map-station-panel"
                  stop={@edit_stop}
                  form={@station_form}
                  usage={@edit_usage}
                  landmark={@station_landmark}
                  loading?={@station_loading?}
                  errors={@station_errors}
                  refusal={station_refusal_for(assigns)}
                  saving?={@station_saving?}
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
  defp mode_payload(%{panel: :edit} = assigns) do
    # The edit panel's pin is the stop's own position, and the ghost is where it
    # is saved — the two are what makes a move legible on the map. Without a
    # pending move there is nothing to compare, so the pin is the saved point
    # and no ghost is drawn.
    saved = edit_saved_point(assigns)
    label = assigns.edit_stop && assigns.edit_stop.name

    case assigns.edit_move do
      %{lat: lat, lon: lon} ->
        %{
          mode: :browse,
          pin: %{lat: lat, lon: lon, label: label},
          ghost: saved
        }

      # Before anything has moved the pin is still the stop's own position, so
      # the editor has something to drag; the ghost appears with the move,
      # because a ghost is the thing the pin left behind.
      _no_move when is_map(saved) ->
        %{mode: :browse, pin: %{lat: saved.lat, lon: saved.lon, label: label}, ghost: nil}

      _no_move ->
        %{mode: :browse, pin: nil, ghost: nil}
    end
  end

  defp mode_payload(%{placement: {lat, lon}}),
    do: %{mode: :browse, pin: %{lat: lat, lon: lon, label: "New stop"}, ghost: nil}

  defp mode_payload(assigns) do
    mode = if assigns.panel == :add, do: :add, else: :browse

    # `ghost` is the position a stop already has in the database, which no
    # placement has yet.
    %{mode: mode, pin: nil, ghost: nil}
  end

  # The saved position, read from the row the panel loaded rather than from the
  # draft: the draft is what the editor is changing, and the ghost's whole job
  # is to be the thing the draft has moved away from.
  defp edit_saved_point(%{edit_baseline: baseline}) when is_map(baseline) do
    case parse_point(%{"lat" => baseline["stop_lat"], "lon" => baseline["stop_lon"]}) do
      {:ok, {lat, lon}} -> %{lat: lat, lon: lon}
      :error -> nil
    end
  end

  defp edit_saved_point(_assigns), do: nil

  # A point that cannot be read is refused rather than clamped. A lat/lon pair
  # is a position on the Earth, and "north" is not one; saving a clamped pair
  # would put a stop in a place nobody chose.
  defp assign_placement(socket, params) do
    case parse_point(params) do
      {:ok, {lat, lon}} ->
        socket = assign(socket, :placement, {lat, lon})

        # A pin is a placement while a stop is being added and a move while one
        # is being edited. The same report means the different thing in each, so
        # the panel decides which, and the add flow's reverse geocode is not
        # asked for a stop that is merely being nudged across the street.
        if socket.assigns.panel == :edit do
          move_edit_pin(socket, lat, lon)
        else
          socket |> seed_coordinates(lat, lon) |> push_map_mode()
        end

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

  # A pin moved outside the current view is a pin the editor cannot see, and a
  # distance they cannot check. The caption says which way it went and offers to
  # find it rather than leaving the editor to pan for it.
  defp map_caption(%{panel: :edit, replace_candidates: [_ | _]}) do
    %{
      title: "Choose the stop to keep",
      text: "Click a stop on the map, or pick one of the nearest in the panel."
    }
  end

  defp map_caption(%{panel: :edit, edit_move: %{distance_m: distance}} = assigns)
       when is_number(distance) do
    off_canvas? = pin_off_canvas?(assigns)

    %{
      title: "The stop has moved",
      text:
        if off_canvas? do
          "The pin is outside the view. Press Find the pin in the panel, or pan to it."
        else
          "Drag the pin again, or focus it and use the arrow keys: about 3 ft a press, 30 ft with Shift."
        end
    }
  end

  defp map_caption(%{panel: :edit}), do: nil

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

  # The bounds the hook last reported are the view the editor is looking at. A
  # pin outside them is not on the canvas, and the panel's own coordinates are
  # the only other answer to where it went.
  defp pin_off_canvas?(%{view_bounds: nil}), do: false

  defp pin_off_canvas?(%{view_bounds: bounds, edit_move: %{lat: lat, lon: lon}}) do
    not inside?({lon, lat}, bounds)
  end

  defp pin_off_canvas?(_assigns), do: false

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

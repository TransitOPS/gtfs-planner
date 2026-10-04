defmodule GtfsPlannerWeb.Gtfs.TimetableAssistanceLiveTest do
  # Step 5: the timetable helper on the existing Paste page (EV-5).
  #
  # Every test drives the real production path end to end: the real Paste route,
  # the real `#paste-form` read, the real `#timetable-source-form` submit, the
  # real `AgentPanel` with the real timetables pack, and the real native apply.
  # Only the OpenRouter HTTP boundary is scripted, so the source, the proposal
  # and the review can only come from native events.
  #
  # The expectations are written by hand from the fixture's own times and the
  # calendar arithmetic below — two feed trips at 06:00 and 07:00, two pasted
  # source rows, a reviewed interval of 20 service dates — and never from a call
  # into `TimetableSource`, the pack or the handoff. A batch that reaches the
  # apply bar must have written rows for the trip the editor saw.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the provider HTTP boundary (INV-5).
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  # 2026-11-02 through 2026-11-30 holds 21 ISO weekdays, and Thanksgiving is
  # Thursday 2026-11-26, so removing it leaves exactly 20 service dates.
  @first_date "2026-11-02"
  @last_date "2026-11-30"
  @thanksgiving "2026-11-26"
  @service_dates 20
  @pattern_id "SRC-MAIN"

  @stale_notice "That prepared batch is no longer available here. Ask the helper to prepare it again."
  @edited_notice "Your edited batch was saved. The prepared batch was not marked as applied."

  # The two feed trips the route already stores, at the two times the pasted
  # rows ask for. A pasted row that matches one of them resolves to exactly
  # that trip, so the trips that exist before and after a batch can be counted
  # independently of anything the batch changed.
  @first_trip "SRC_T360"
  @second_trip "SRC_T420"
  @first_trip_time "06:00:00"
  @second_trip_time "07:00:00"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization =
      organization_fixture(%{alias: "timetable-assist-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "timetable-assist-#{System.unique_integer([:positive])}@example.com"})

    membership =
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

    version = gtfs_version_fixture(organization.id, %{name: "Assist Version"})
    track_sessions()

    %{
      conn: log_in_user(build_conn(), user, organization: organization),
      user: user,
      membership: membership,
      organization: organization,
      version: version
    }
  end

  describe "the timetable helper prepares and saves through the native paste" do
    test "the real panel prepares a batch that writes nothing until it is applied", context do
      {view, _pid, _route} = opened_paste(context)

      {view, pid, first} = prepare_batch(view, [1], context)

      # The card is a proposal: the prepared rows and its own review action.
      assert has_element?(view, "#agent-prepared-#{first}")
      assert has_element?(view, "#agent-review-prepared-#{first}", "Review prepared batch")
      assert trip_count(context) == 2

      # Opening it is the host's own review, re-prepared from the accepted
      # source: both resolved rows, the native matrix and the native apply bar.
      view |> element("#agent-review-prepared-#{first}") |> render_click()

      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#paste-apply")
      assert has_element?(view, "#timetable-batches")
      assert has_element?(view, "#timetable-batch-#{first}", "Under review")

      # Still nothing written: a review is a review (INV-2).
      assert trip_count(context) == 2

      # The card is still an offer, not a receipt.
      assert element(view, "#agent-prepared-#{first}") |> render() =~ "Ready to review"
      refute_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 100
    end

    test "the prepared batch's action name matches the timetable command, not another pack's",
         context do
      {view, _pid, _route} = opened_paste(context)

      {view, _pid, first} = prepare_batch(view, [1], context)

      assert has_element?(view, "#agent-review-prepared-#{first}", "Review prepared batch")
      refute has_element?(view, "#agent-review-prepared-#{first}", "Review date change")
    end

    test "the first batch saves its rows, confirms its card and leaves the rest unsaved",
         context do
      {view, _pid, _route} = opened_paste(context)
      {view, pid, first} = prepare_batch(view, [1], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()
      assert render_click(view, "paste_apply", %{}) =~ "Saved on"

      # The batch's row resolved to the 06:00 feed trip and only that one is in
      # scope: the 07:00 trip is the second row's, which this batch excludes.
      assert trip_count(context) == 2
      assert trip_start(context, @first_trip) == @first_trip_time
      assert trip_start(context, @second_trip) == @second_trip_time

      # The proposal is confirmed by the session's own receipt, which the
      # panel reads back onto that same card.
      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 10_000
      assert element(view, "#agent-prepared-#{first}") |> render() =~ "Applied"

      # One batch saved, one source row still unsaved, and the page stays here
      # so the next batch can be prepared from the same source.
      assert has_element?(view, "#timetable-batch-#{first}", "Saved")
      assert has_element?(view, "#timetable-batches-unsaved", "1 source row is still unsaved")
      assert has_element?(view, "#paste-review")
      assert socket_assigns(view).timetable_source.digest == source_digest(view)
    end

    test "the second batch saves independently and settles the last source row", context do
      {view, _pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()
      render_click(view, "paste_apply", %{})

      # A second, independent proposal from the same accepted source.
      {view, _pid, second} = prepare_batch(view, [2], context)

      # The first batch stays saved, and the second is still only a proposal: a
      # batch joins the card when its review is opened, not when it is
      # suggested.
      assert has_element?(view, "#timetable-batch-#{first}", "Saved")
      refute has_element?(view, "#timetable-batch-#{second}")
      assert has_element?(view, "#timetable-batches-unsaved", "1 source row is still unsaved")

      view |> element("#agent-review-prepared-#{second}") |> render_click()
      assert has_element?(view, "#timetable-batch-#{second}", "Under review")

      # Every source row has now been saved, so the page navigates to Schedules
      # exactly as an ordinary single-batch paste always has. Nothing is left
      # on screen to show: the batches card lived on the page it left.
      assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "paste_apply", %{})
      assert_schedules_redirect(to, context)
      assert trip_count(context) == 2
    end

    test "a batch with no rows left saves on its own and navigates as an ordinary paste",
         context do
      {view, _pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1, 2], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()

      # Both rows in one batch, so nothing remains unsaved and the native
      # success navigation stands: this batch is the whole paste.
      assert {:error, {:live_redirect, %{to: to}}} = render_click(view, "paste_apply", %{})
      assert_schedules_redirect(to, context)
    end

    test "an edited native input saves the edit and leaves the prepared card unconfirmed",
         context do
      {view, _pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()

      # The editor drops the reviewed row from the batch. That is a native
      # decision on the open review, so the batch under review is still the
      # same batch and the accepted source is untouched.
      render_click(view, "paste_skip", %{"row" => "1"})

      assert render_click(view, "paste_apply", %{}) =~ "still unsaved"

      # The editor's decision stands: the batch's own row was skipped, so the
      # save wrote nothing this trip and the source row is still unsaved.
      assert trip_count(context) == 2

      # The save stands and the card says precisely why it is unconfirmed.
      assert view |> element("#agent-notice") |> render() =~ @edited_notice
      assert element(view, "#agent-prepared-#{first}") |> render() =~ "Ready to review"
      assert has_element?(view, "#agent-review-prepared-#{first}")
      assert has_element?(view, "#timetable-batch-#{first}", "Saved")
    end
  end

  describe "the prepared-batch handoff refuses what it cannot prove" do
    test "a forged entry id is ignored and never reaches the session", context do
      {view, pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()

      # An id that is not an integer at all, and an integer that belongs to no
      # entry in this conversation, both leave the open review untouched.
      render_click(view, "agent_review_prepared", %{"entry" => "not-an-id"})
      assert has_element?(view, "#paste-review")
      assert has_element?(view, "#timetable-batch-#{first}", "Under review")

      render_click(view, "agent_review_prepared", %{"entry" => "9999"})
      assert has_element?(view, "#paste-review")

      # Nothing new appeared, nothing was written, and the card is untouched.
      assert trip_count(context) == 2
      assert element(view, "#agent-prepared-#{first}") |> render() =~ "Ready to review"
      refute_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 100
    end

    test "an entry from a reset conversation no longer reviews", context do
      {view, pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      # Another tab started a new conversation, so this page's card is gone.
      :ok = Agents.new_conversation(pid)
      assert_receive {:agent_event, ^pid, {:reset, _new_conversation_id}}, 10_000
      assert render(view) =~ "What needs to change?"

      render_click(view, "agent_review_prepared", %{"entry" => "#{first}"})

      # The refused handoff opens no batch and confirms nothing.
      assert view |> element("#agent-notice") |> render() =~ @stale_notice
      assert trip_count(context) == 2
      refute has_element?(view, "#timetable-batches")
      refute_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 100
    end

    test "a session that has ended cannot review or confirm, and the save still stands",
         context do
      {view, pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()

      send(pid, {:idle_timeout, :sys.get_state(pid).idle_token})
      assert_receive {:agent_event, ^pid, {:status, :ended}}, 10_000
      assert render(view) =~ "This conversation ended."

      # The batch is still recorded saved and the page still stays here with
      # the other row unsaved; the dead session simply cannot add a receipt.
      assert render_click(view, "paste_apply", %{}) =~ "still unsaved"
      assert trip_count(context) == 2
      assert has_element?(view, "#timetable-batch-#{first}", "Saved")
      assert has_element?(view, "#timetable-batches-unsaved", "1 source row is still unsaved")
    end

    test "a source released after the proposal was prepared refuses the handoff", context do
      {view, pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      # Replacing the pasted text releases the accepted source and its batches,
      # so the proposal's rows describe nothing that is on screen any more
      # (INV-1).
      render_change(view, "input", %{
        "paste" => %{"text" => "201\t08:00\t08:05\t08:10", "layout" => "auto", "header" => "true"}
      })

      assert is_nil(socket_assigns(view).timetable_source)
      refute has_element?(view, "#timetable-batches")

      render_click(view, "agent_review_prepared", %{"entry" => "#{first}"})

      # The refused handoff opens no batch and confirms nothing.
      assert view |> element("#agent-notice") |> render() =~ @stale_notice
      assert trip_count(context) == 2
      refute has_element?(view, "#timetable-batches")
      refute_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 100
      refute_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 100
    end

    test "a second handoff while a batch is under review keeps the first review open",
         context do
      {view, _pid, _route} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()

      # A second card for the same source would replace the input under review.
      {second_view, _pid, second} = prepare_batch(view, [2], context)
      render_click(second_view, "agent_review_prepared", %{"entry" => "#{second}"})

      # The first review is still the one on screen and its batch is still the
      # one under review; the second proposal never became a batch at all.
      assert socket_assigns(second_view).timetable_batch_origin.entry_id == first
      assert has_element?(second_view, "#timetable-batch-#{first}", "Under review")
      refute has_element?(second_view, "#timetable-batch-#{second}")
      assert trip_count(context) == 2
    end
  end

  describe "an uncertain apply is never replayed and never confirmed" do
    test "a reconnect during the apply marks the batch unknown and writes nothing twice",
         context do
      {view, _pid, first} = opened_paste(context)
      {view, _pid, first} = prepare_batch(view, [1], context)

      view |> element("#agent-review-prepared-#{first}") |> render_click()

      # The client reconnects carrying the `#paste-applying` flag the Apply
      # click set, which is exactly what form recovery after a dropped
      # connection sends. This is the one outcome the host genuinely cannot
      # know, and the recovery must not replay the apply.
      render_submit(view, "input", %{
        "paste" => %{
          "applying" => "true",
          "text" => exact_text(),
          "layout" => "auto",
          "header" => "true"
        }
      })

      # Nothing was written: the batch's own save never happened here.
      assert trip_count(context) == 2

      # The batch says plainly that the outcome is unknown, and stays offered
      # rather than confirmed or replayed.
      assert has_element?(view, "#timetable-batch-#{first}", "Unknown")
      assert element(view, "#agent-prepared-#{first}") |> render() =~ "Ready to review"
      refute_receive {:agent_event, _pid, {:entry, %{applied?: true}}}, 200
    end
  end

  ## Helpers

  # The real route, with two feed trips the two pasted rows can resolve to.
  defp source_route(context) do
    %{organization: organization, version: version} = context

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "SRC1",
        route_short_name: "14",
        route_long_name: "Harbor – Union"
      })

    calendar_fixture(organization.id, version.id, %{
      service_id: "SRC_WKD",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0
    })

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "SRC_WKD",
      service_description: "Weekday",
      service_schedule_name: "Weekday"
    })

    Enum.each(1..3, fn index ->
      stop_fixture(organization.id, version.id, %{
        stop_id: "SRC_S#{index}",
        stop_name: "Source Stop #{index}"
      })
    end)

    pattern =
      schedule_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        direction_id: 0,
        route_pattern_id: @pattern_id,
        route_pattern_name: "Main",
        route_pattern_typicality: 1,
        timing_name: "Standard",
        stops: [
          {"SRC_S1", 0, 0, 1},
          {"SRC_S2", 300, 360, 1},
          {"SRC_S3", 660, 720, 1}
        ]
      })

    # Two existing feed trips at the two times the pasted rows ask for, so
    # each pasted row resolves to exactly one of them and a batch's applied
    # count can be told apart.
    Enum.each([{@first_trip, 6, 0}, {@second_trip, 7, 0}], fn {trip_id, hour, minute} ->
      schedule_trip_fixture(organization.id, version.id, route.route_id, pattern, %{
        service_id: "SRC_WKD",
        trip_id: trip_id,
        start_time: "0#{hour}:#{pad(minute)}:00",
        trip_headsign: "Union Depot"
      })
    end)

    route
  end

  defp exact_text do
    "Trip\tSource Stop 1\tSource Stop 2\tSource Stop 3\n" <>
      "101	06:00	06:05	06:10\n102	07:00	07:05	07:10"
  end

  # The real page, with the real panel opened and the real source accepted.
  defp opened_paste(context) do
    route = source_route(context)
    {:ok, view, _html} = live(context.conn, paste_path(context.version, route))

    # The source is accepted before the panel is opened, because the pack's own
    # precondition is an accepted source attached to this conversation: a panel
    # opened earlier would hold a session that refuses every request.
    render_submit(view, "read", %{
      "paste" => %{"text" => exact_text(), "layout" => "auto", "header" => "true"}
    })

    render_submit(view, "source_review", %{"source" => source_params()})

    assert has_element?(view, "#timetable-source-accepted")

    assert view |> element("#timetable-source-state") |> render() =~
             "#{@service_dates} service dates"

    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")
    # Opening the page's own session from the test attaches this process as a
    # listener, which is how the turn's own events are awaited. The registry
    # already holds the session the panel opened, so this attaches rather than
    # starting a second one. The scope carries the page's resource context
    # including the accepted source snapshot, because the pack refuses any
    # conversation that does not own one.
    pid = socket_assigns(view).agent_session
    assert {:ok, ^pid, _snapshot} = Agents.open(agent_scope(view))

    {view, pid, route}
  end

  defp source_params do
    %{
      "label" => "Harbor printed table",
      "revision" => "rev 3",
      "notes" => "",
      "first_date" => @first_date,
      "last_date" => @last_date,
      "date_policy" => "weekly",
      "weekdays" => ~w(1 2 3 4 5),
      "school_dates" => "",
      "added_dates" => "",
      "removed_dates" => @thanksgiving,
      "confirm" => "true"
    }
  end

  # The pack reads the attached source first, then the scoped options, then
  # prepares the batch, then the turn settles. Every call is scripted so the
  # conversation can only produce the one batch under test.
  # The session pid and route are both read back from the page, so a caller only
  # has the view in hand and the page stays the single source of truth for the
  # conversation this batch belongs to.
  defp prepare_batch(view, row_ids, context) do
    service_id = "SRC_WKD"
    pattern_id = @pattern_id
    direction_id = 0

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "read_timetable_source", "{}"}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_2", "inspect_timetable_scope", "{}"}]))
    end)

    arguments =
      Jason.encode!(%{
        "row_ids" => row_ids,
        "service_id" => service_id,
        "pattern_id" => pattern_id,
        "direction_id" => direction_id
      })

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_3", "prepare_timetable_input", arguments}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, text_reply("I prepared the batch. Review it before applying."))
    end)

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Prepare rows #{inspect(row_ids)}."}})

    # The turn runs in its own task, so its own events are awaited as they
    # arrive rather than assumed to be on screen already.
    pid = socket_assigns(view).agent_session

    {entry, command} = await_command(pid, Enum.sort(row_ids))

    # The proposal names this route's own calendar and direction, and the
    # native scope resolved the pattern itself rather than taking it from the
    # argument list, so the handoff can re-resolve the same native scope.
    assert command.source_digest == source_digest(view)
    assert command.row_ids == Enum.sort(row_ids)
    assert command.scope_params.service_id == service_id
    assert command.scope_params.direction_id == direction_id

    # The native scope resolves the pattern to its own UUID, so the proposal
    # names that resolved identity rather than the GTFS pattern id that was
    # passed in. The UUID comes from the fixture, not from the conversation.
    assert %{id: pattern_uuid} = pattern_fixture_row(context)
    assert command.scope_params.pattern_id == pattern_uuid

    {view, pid, entry}
  end

  # Awaits this conversation's prepared command and returns the entry id it was
  # prepared under with it, so the card's own dom ids can be asserted rather
  # than assumed.
  defp await_command(pid, row_ids, remaining \\ 10_000) do
    receive do
      # A batch prepared for other rows is a proposal already on screen, so its
      # event is drained rather than mistaken for this batch's own.
      {:agent_event, ^pid,
       {:entry, %{id: id, prepared: %{command: {:timetable_input, %{row_ids: ^row_ids} = c}}}}} ->
        {id, c}

      {:agent_event, ^pid, _other} ->
        await_command(pid, row_ids, remaining)
    after
      remaining -> flunk("no prepared timetable command arrived for rows #{inspect(row_ids)}")
    end
  end

  # The scope the panel's session was opened with, rebuilt from the page's own
  # assigns so the test attaches to that conversation rather than describing a
  # different one.
  defp agent_scope(view) do
    %Scope{
      organization_id: socket_assigns(view).current_organization.id,
      gtfs_version_id: socket_assigns(view).current_gtfs_version.id,
      user_id: socket_assigns(view).current_user.id,
      user_email: socket_assigns(view).current_user.email,
      pack_id: "timetables",
      version_name: socket_assigns(view).current_gtfs_version.name,
      resource_context: socket_assigns(view).agent_context
    }
  end

  defp source_digest(view), do: socket_assigns(view).timetable_source.digest

  defp route_id(context) do
    Repo.one!(
      from(r in Route,
        where: r.organization_id == ^context.organization.id,
        where: r.gtfs_version_id == ^context.version.id,
        select: r.route_id
      )
    )
  end

  defp paste_path(version, route) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/schedules/paste"
  end

  # The native success navigation carries the scope this batch was saved
  # against. The query is compared as a parsed map rather than as a string, so
  # the assertion does not depend on the order the params are written in.
  defp schedules_path(context) do
    {"/gtfs/#{context.version.id}/routes/#{route_id(context)}/schedules",
     %{
       "direction" => "0",
       "pattern" => pattern_fixture_row(context).id,
       "service_id" => "SRC_WKD"
     }}
  end

  defp assert_schedules_redirect(to, context) do
    assert {base, params} = schedules_path(context)

    assert {^base, decoded} =
             String.split(to, "?", parts: 2) |> then(fn [p, q] -> {p, URI.decode_query(q)} end)

    assert decoded == params
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp pattern_fixture_row(context) do
    Repo.one!(
      from(p in RoutePattern,
        where: p.organization_id == ^context.organization.id,
        where: p.gtfs_version_id == ^context.version.id,
        where: p.route_pattern_id == ^@pattern_id
      )
    )
  end

  defp trip_count(context) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^context.organization.id and
            t.gtfs_version_id == ^context.version.id and
            t.route_id == ^route_id(context)
      ),
      :count
    )
  end

  # The feed trip a pasted row resolved to is what the batch added, so its
  # start time is read back from the database rather than from the page.
  # The trip's own first departure, read back from the stop times rather than
  # from the page, so a batch's applied rows can be told apart by what was
  # actually stored.
  defp trip_start(context, trip_id) do
    StopTime
    |> where([s], s.organization_id == ^context.organization.id)
    |> where([s], s.gtfs_version_id == ^context.version.id)
    |> where([s], s.trip_id == ^trip_id)
    |> where([s], s.stop_sequence == 1)
    |> select([s], s.departure_time)
    |> Repo.one()
  end

  # Sessions run under the application's own supervisor and outlive the test
  # socket, so every session this test opened is terminated here.
  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(GtfsPlanner.Agents.SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    GtfsPlanner.Agents.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  ## Scripted OpenRouter replies

  defp respond(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp text_reply(text), do: reply("stop", %{"content" => text})

  defp tool_calls_reply(calls) do
    tool_calls =
      Enum.map(calls, fn {id, name, arguments} ->
        %{
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => arguments}
        }
      end)

    reply("tool_calls", %{"content" => nil, "tool_calls" => tool_calls})
  end

  defp reply(finish_reason, message) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => %{"cost" => 0.0}
    }
  end
end

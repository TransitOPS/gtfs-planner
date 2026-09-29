defmodule GtfsPlannerWeb.Gtfs.CalendarsHelperHandoffTest do
  @moduledoc """
  The prepared-change handoff into the existing drawer review (EV-12).

  The page, the conversation session and the turn task that prepares the change
  are separate processes, so the SQL sandbox and the Req.Test plug are shared
  (`async: false`) and only the OpenRouter HTTP boundary is scripted (INV-5).
  Every expectation comes from the domain fixtures and the domain's own
  review/apply contracts — rows, audit actor, stale refusals — never from the
  handoff's implementation. The drawer write path is the page's existing one
  (INV-3); the pack's prepare turn must not write a row.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @weekdays %{
    monday: 1,
    tuesday: 1,
    wednesday: 1,
    thursday: 1,
    friday: 1,
    saturday: 0,
    sunday: 0
  }

  # Fixture weekdays inside every fixture calendar's 2026 range, so the tests do
  # not depend on the date they run on.
  @dates [~D[2026-10-05], ~D[2026-10-06]]
  @stop_arguments ~s({"dates":["2026-10-05","2026-10-06"],"stop":["SCHOOL_WD","SCHOOL_EX"],"run":[]})
  @new_calendar_arguments ~s({"dates":["2026-10-05","2026-10-06"],"stop":["SCHOOL_NEW"],"run":[]})
  @competing_date ~D[2026-11-03]

  @missing_notice "One of these calendars is no longer in this service version. Refresh the list and ask again."
  @edited_notice "The change you applied differs from the prepared change, so its card is not marked Applied."

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization = organization_fixture()
    user = user_fixture()
    membership = organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Handoff Version"})

    add_calendar(organization, version, "SCHOOL_WD", "School weekdays")
    add_calendar(organization, version, "SCHOOL_EX", "School express")

    track_sessions()

    %{organization: organization, user: user, membership: membership, version: version}
  end

  describe "the handoff into the drawer review" do
    test "a prepared turn writes nothing and renders the card's review button", context do
      {view, _pid} = prepared_view(context)

      assert has_element?(view, "#agent-prepared-2")
      assert has_element?(view, "#agent-review-prepared-2")
      assert scoped_date_count(context) == 0
      refute render(view) =~ "calendar-date-change-review-panel"
    end

    test "Review prepared change opens the drawer review with both calendars", context do
      {view, _pid} = prepared_view(context)

      assert view |> element("#agent-review-prepared-2") |> render_click() =~
               "calendar-date-change-review-panel"

      review =
        view
        |> element("#calendar-date-change-review-panel")
        |> render()

      assert review =~ "School weekdays"
      assert review =~ "School express"
      assert review =~ "Oct 5, 2026"
      assert review =~ "Oct 6, 2026"
      assert scoped_date_count(context) == 0
    end

    test "the drawer's apply writes the reviewed rows, audits the user and settles the card",
         context do
      {view, pid} = prepared_view(context)

      view |> element("#agent-review-prepared-2") |> render_click()

      assert render_click(view, "date_change_apply", %{}) =~ "Applied the date change"

      rows =
        Repo.all(
          from(cd in CalendarDate,
            where: cd.organization_id == ^context.organization.id,
            where: cd.gtfs_version_id == ^context.version.id,
            order_by: [asc: cd.service_id, asc: cd.date]
          )
        )

      assert [
               %{service_id: "SCHOOL_EX"},
               %{service_id: "SCHOOL_EX"},
               %{service_id: "SCHOOL_WD"},
               %{service_id: "SCHOOL_WD"}
             ] = rows

      assert Enum.all?(rows, &(&1.exception_type == 2))
      assert Enum.map(rows, & &1.date) == @dates ++ @dates

      logs = Repo.all(from(l in ChangeLog, where: l.gtfs_version_id == ^context.version.id))
      refute logs == []
      assert Enum.all?(logs, &(&1.actor_id == context.user.id))

      # The receipt is settled by the session's own entry event, not by the page.
      assert_receive {:agent_event, ^pid, {:entry, %{applied?: true}}}, 5_000

      assert element(view, "#agent-prepared-2") |> render() =~ "Applied"
      refute has_element?(view, "#agent-review-prepared-2")
      refute has_element?(view, "#calendar-date-change-review-panel")
    end

    test "a calendar the page snapshot does not know refuses the handoff with the notice",
         context do
      view = helper_view(context)

      # The pack's own catalog read sees this calendar; the page's loaded list does
      # not, so only a refresh could make the handoff possible.
      add_calendar(context.organization, context.version, "SCHOOL_NEW", "New school")

      {view, _pid} = prepare_stop(view, @new_calendar_arguments)

      assert has_element?(view, "#agent-review-prepared-2")

      view |> element("#agent-review-prepared-2") |> render_click()

      assert view |> element("#agent-notice") |> render() =~ @missing_notice
      assigns = socket_assigns(view)
      refute assigns.date_change_open?
      refute render(view) =~ "calendar-date-change-review-panel"
      assert scoped_date_count(context) == 0
    end

    test "a competing apply after the review makes apply stale and writes none of the prepared dates",
         context do
      {view, _pid} = prepared_view(context)

      view |> element("#agent-review-prepared-2") |> render_click()

      # Another session reviews and applies a different command on one of the same
      # calendars.
      command = {:date_change, [@competing_date], ["SCHOOL_WD"], []}

      assert {:ok, review} =
               Gtfs.review_calendar_change(
                 command,
                 %{"SCHOOL_WD" => fingerprint_for(context, "SCHOOL_WD")},
                 audit_context(context)
               )

      assert {:ok, _result} =
               Gtfs.apply_calendar_change(command, review.fingerprint, audit_context(context))

      assert render_click(view, "date_change_apply", %{}) =~ "changed in another session"

      dates =
        Repo.all(
          from(cd in CalendarDate,
            where: cd.organization_id == ^context.organization.id,
            where: cd.gtfs_version_id == ^context.version.id,
            select: cd.date
          )
        )

      assert dates == [@competing_date]
      refute has_element?(view, "#calendar-date-change-review-panel")
    end

    test "an edited drawer command applies the edit and leaves the card unconfirmed", context do
      {view, _pid} = prepared_view(context)

      view |> element("#agent-review-prepared-2") |> render_click()

      render_click(view, "date_change_back", %{})

      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "SCHOOL_EX"})

      render_click(view, "date_change_review", %{})

      assert render_click(view, "date_change_apply", %{}) =~ "Applied the date change"

      rows =
        Repo.all(
          from(cd in CalendarDate,
            where: cd.organization_id == ^context.organization.id,
            where: cd.gtfs_version_id == ^context.version.id,
            order_by: [asc: cd.date]
          )
        )

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.service_id == "SCHOOL_WD" and &1.exception_type == 2))
      assert Enum.map(rows, & &1.date) == @dates

      # The original proposal stays unconfirmed and says why.
      assert view |> element("#agent-notice") |> render() =~ @edited_notice
      assert element(view, "#agent-prepared-2") |> render() =~ "Ready to review"
      assert has_element?(view, "#agent-review-prepared-2")
    end

    test "a conversation reset in another tab lets the apply succeed and marks nothing Applied",
         context do
      {view, pid} = prepared_view(context)

      view |> element("#agent-review-prepared-2") |> render_click()

      # Another tab started a new conversation; this page's card is gone.
      :ok = Agents.new_conversation(pid)
      assert_receive {:agent_event, ^pid, {:reset, _new_conversation_id}}, 5_000

      assert render_click(view, "date_change_apply", %{}) =~ "Applied the date change"
      assert scoped_date_count(context) == 4

      assigns = socket_assigns(view)
      assert assigns.date_change_return_focus == "agent-composer-input"
      assert has_element?(view, "#agent-first-conversation", "What needs to change?")
      refute has_element?(view, "#agent-prepared-2")
    end

    test "a second handoff while the drawer is open preserves the person's selections", context do
      {view, _pid} = prepared_view(context)

      view |> element("#agent-review-prepared-2") |> render_click()
      render_click(view, "date_change_back", %{})

      render_click(view, "date_change_toggle", %{"group" => "remove", "service-id" => "SCHOOL_EX"})

      view |> element("#agent-review-prepared-2") |> render_click()

      assigns = socket_assigns(view)
      assert assigns.date_change_origin.entry_id == 2
      assert assigns.date_change_open?

      assert view |> element("#calendar-date-change-remove-SCHOOL_WD") |> render() =~ "checked"
      refute view |> element("#calendar-date-change-remove-SCHOOL_EX") |> render() =~ "checked"
      assert view |> element("#calendar-date-change-selection") |> render() =~ "Oct 5, 2026"
    end

    test "an expired session keeps the apply successful and the focus target stable", context do
      {view, pid} = prepared_view(context)

      view |> element("#agent-review-prepared-2") |> render_click()

      send(pid, {:idle_timeout, :sys.get_state(pid).idle_token})
      assert_receive {:agent_event, ^pid, {:status, :ended}}, 5_000

      assert render_click(view, "date_change_apply", %{}) =~ "Applied the date change"
      assert scoped_date_count(context) == 4

      assigns = socket_assigns(view)
      assert assigns.date_change_return_focus == "agent-prepared-2"
      assert has_element?(view, "#agent-prepared-2")

      # The dead origin cannot confirm its card; the ordinary drawer result stands.
      assert has_element?(view, "#agent-review-prepared-2")
    end
  end

  ## Helpers

  defp helper_view(context) do
    conn = log_in_user(context.conn, context.user, organization: context.organization)

    assert {:ok, view, _html} = live(conn, "/gtfs/#{context.version.id}/calendars")

    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    pid = session_pid(view)
    assert {:ok, ^pid, _snapshot} = Agents.open(scope(context))

    {view, pid}
  end

  # Scripts the deterministic prepare turn: one model reply calls
  # `prepare_date_change` for the given arguments, the second settles the turn.
  defp prepare_stop({view, pid}, arguments) do
    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "prepare_date_change", arguments}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, text_reply("I prepared the change. Review it before applying."))
    end)

    submit(view, "No school service on October 5 and 6, 2026.")

    assert_receive {:agent_event, ^pid, {:entry, %{status: :working}}}, 5_000

    assert_receive {:agent_event, ^pid,
                    {:entry, %{status: :done, prepared: %{command: command}}} = _entry},
                   5_000

    assert command == {:date_change, @dates, Enum.sort(stop_ids(arguments)), []}

    {view, pid}
  end

  defp prepared_view(context), do: helper_view(context) |> prepare_stop(@stop_arguments)

  # The scripted arguments carry the service IDs the proposal will contain.
  defp stop_ids(arguments) do
    %{"stop" => stop} = Jason.decode!(arguments)
    stop
  end

  defp scope(context) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: "calendars",
      version_name: context.version.name
    }
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  defp session_pid(view), do: socket_assigns(view).agent_session

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp add_calendar(organization, version, service_id, name) do
    calendar_fixture(organization.id, version.id, @weekdays |> Map.put(:service_id, service_id))

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end

  defp scoped_date_count(%{organization: organization, version: version}) do
    Repo.aggregate(
      from(cd in CalendarDate,
        where: cd.organization_id == ^organization.id,
        where: cd.gtfs_version_id == ^version.id
      ),
      :count
    )
  end

  defp fingerprint_for(context, service_id) do
    {:ok, summaries} =
      Gtfs.load_calendar_catalog(context.organization.id, context.version.id, [])

    summary = Enum.find(summaries, &(&1.service_id == service_id))
    summary.fingerprint
  end

  defp audit_context(context) do
    %AuditContext{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      station_stop_id: nil,
      actor_id: context.user.id,
      actor_email: context.user.email
    }
  end

  # Sessions are started under the application's own supervisor and outlive the
  # test socket, so every session this test opened is terminated here.
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

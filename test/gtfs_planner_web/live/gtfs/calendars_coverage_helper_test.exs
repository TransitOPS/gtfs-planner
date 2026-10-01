defmodule GtfsPlannerWeb.Gtfs.CalendarsCoverageHelperTest do
  @moduledoc """
  The approved calendar extension from the helper panel into the Calendars page's
  own reviewed write (EV-6).

  The page, the conversation session and the turn task that prepares the
  extension are separate processes, so the SQL sandbox and the `Req.Test` plug
  are shared (`async: false`) and only the OpenRouter HTTP boundary is scripted
  (INV-5). Every expectation comes from the domain fixtures and the domain's own
  review/apply contracts — end dates, rows, audit actor, stale refusals — never
  from the page's implementation.

  The approval is the editor's own words in the page's form (INV-4): a model
  paraphrase, a pasted approval or an imported GTFS field cannot supply one, and
  an argument that disagrees with the approved calendar or end date is refused.
  Preparation writes nothing; only the regenerated native review's Apply writes,
  through the existing audited `Gtfs.apply_calendar_change/3`.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @service_id "SCHOOL_WD"
  @other_service_id "SCHOOL_EX"
  @route_id "SCHOOL_ROUTE"
  @current_end ~D[2026-12-30]
  @approved_end ~D[2027-03-31]
  @edited_end ~D[2027-02-26]
  @approval "Board approved running the school connector through the spring term."

  @extension_arguments ~s({"service_id":"SCHOOL_WD"})
  @other_extension_arguments ~s({"service_id":"SCHOOL_EX"})

  # H8's standard calendar has ended on both dates and the school connector
  # keeps its Sunday service through the other calendar, so the coverage answer
  # carries a gap and an alternate rather than a uniform run.
  @coverage_arguments ~s({"service_id":"SCHOOL_WD","dates":["2027-01-04","2027-01-10"],"route_ids":["#{@route_id}"]})

  @weekdays %{
    monday: 1,
    tuesday: 1,
    wednesday: 1,
    thursday: 1,
    friday: 1,
    saturday: 0,
    sunday: 0
  }

  # The newly active dates the domain computes for the approved extension: the
  # 65 weekdays from Dec 31, 2026 through Mar 31, 2027.
  @newly_active_count 65

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization)
    version = gtfs_version_fixture(organization.id, %{name: "Extension Version"})

    add_calendar(organization, version, @service_id, "School weekdays")
    add_calendar(organization, version, @other_service_id, "School express")
    add_trips(organization, version, @service_id, ["SCH1", "SCH2"])

    track_sessions()

    %{organization: organization, user: user, version: version}
  end

  describe "an editor-entered approval" do
    test "the page's own form is the only place an approval is written", context do
      view = calendars_view(context)

      assert has_element?(view, "#calendar-extension-approval")

      view
      |> element("#calendar-extension-form")
      |> render_submit(%{
        "extension" => %{
          "service_id" => @service_id,
          "end_date" => Date.to_iso8601(@approved_end),
          "approval_text" => @approval
        }
      })

      assert socket_assigns(view).agent_context.approved_extension == %{
               service_id: @service_id,
               end_date: @approved_end,
               approval_text: @approval
             }

      assert view |> element("#calendar-extension-approved") |> render() =~ "Approved extending"
      assert stored_end_date(context) == @current_end
    end

    test "an unusable approval is refused in place and never reaches the session", context do
      view = calendars_view(context)

      # An end date that is not later than the calendar's own.
      view
      |> element("#calendar-extension-form")
      |> render_submit(%{
        "extension" => %{
          "service_id" => @service_id,
          "end_date" => "2026-12-01",
          "approval_text" => @approval
        }
      })

      assert view |> element("#calendar-extension-errors") |> render() =~
               "not later than the calendar&#39;s current end date"

      assert is_nil(socket_assigns(view).agent_context.approved_extension)
      refute has_element?(view, "#calendar-extension-approved")

      # An approval the editor did not write.
      view
      |> element("#calendar-extension-form")
      |> render_submit(%{
        "extension" => %{
          "service_id" => @service_id,
          "end_date" => "2027-03-31",
          "approval_text" => ""
        }
      })

      assert view |> element("#calendar-extension-errors") |> render() =~
               "Enter why you are approving"

      assert is_nil(socket_assigns(view).agent_context.approved_extension)
    end

    test "a model-named calendar the editor did not approve prepares nothing", context do
      view = approved_view(context)

      prepare(view, @other_extension_arguments)

      # The tool refuses an argument the editor's own approval does not name,
      # so no card carries that approval and nothing offers a review.
      refute has_element?(view, "[id^=\"agent-prepared-\"]")
      refute has_element?(view, "[id^=\"agent-review-prepared-\"]")
      assert render(view) =~ "approve"
      assert stored_end_date(context) == @current_end
    end
  end

  describe "a read-only coverage answer" do
    test "renders the server's records and offers nothing to apply", context do
      view = calendars_view(context)
      view |> element("#agent-helper-open") |> render_click()

      Req.Test.expect(@owner, 1, fn conn ->
        respond(
          conn,
          tool_calls_reply([{"call_1", "summarize_calendar_coverage", @coverage_arguments}])
        )
      end)

      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, text_reply("One of those dates still runs service."))
      end)

      view
      |> element("#agent-composer")
      |> render_submit(%{
        "agent" => %{"message" => "Which dates keep service after the term ends?"}
      })

      settle(view, &settled?/1)

      card = view |> element("#agent-evidence-2-1") |> render()

      assert card =~ "Server result"
      assert card =~ "over 2 dates"
      assert card =~ "2 route and date records"
      assert card =~ "gtfs_service_queries"

      # A read answer prepares nothing, so no card offers Apply or Review.
      refute has_element?(view, "[id^=\"agent-prepared-\"]")
      refute has_element?(view, "[id^=\"agent-review-prepared-\"]")
      assert stored_end_date(context) == @current_end
    end

    test "a calendar the service version does not have is refused with no card", context do
      view = calendars_view(context)
      view |> element("#agent-helper-open") |> render_click()

      arguments = ~s({"service_id":"RETIRED","from":"2026-12-01","to":"2026-12-31"})

      Req.Test.expect(@owner, 1, fn conn ->
        respond(conn, tool_calls_reply([{"call_1", "get_calendar", arguments}]))
      end)

      Req.Test.expect(@owner, 1, fn conn ->
        respond(
          conn,
          text_reply("No calendar with service_id RETIRED in this service version.")
        )
      end)

      view
      |> element("#agent-composer")
      |> render_submit(%{"agent" => %{"message" => "Which dates run for the retired calendar?"}})

      settle(view, &settled?/1)

      assert has_element?(view, "#agent-entry-2", "No calendar with service_id RETIRED")
      refute has_element?(view, "[data-evidence-kind]")
      assert stored_end_date(context) == @current_end
    end
  end

  describe "the prepared extension" do
    test "preparation writes nothing and the card names the exact impact", context do
      view = approved_view(context) |> prepare()

      assert has_element?(view, "#agent-prepared-2")
      assert has_element?(view, "#agent-review-prepared-2")

      card = element(view, "#agent-prepared-2") |> render()

      assert card =~ "Extend School weekdays"
      assert card =~ @approval
      assert card =~ "Newly active dates · #{@newly_active_count} dates"
      assert card =~ "Routes affected · 1 route"
      assert card =~ "Trips affected · 2 trips"
      assert card =~ "Unresolved dates · #{@newly_active_count} dates"
      assert card =~ "Review extension"

      # The server evidence card owns the numbers, not the model's sentence.
      assert view |> element("#agent-evidence-2-1") |> render() =~ "Server result"
      assert stored_end_date(context) == @current_end
      assert exception_count(context) == 0
    end

    test "the review shows the impact and the future-holiday gap, and writes nothing", context do
      view = approved_view(context) |> prepare()

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#calendar-extension-impact")

      impact = element(view, "#calendar-extension-impact") |> render()

      assert impact =~ "Result after applying"
      assert impact =~ "Dec 30, 2026"
      assert impact =~ "Mar 31, 2027"
      assert impact =~ @approval
      assert impact =~ "#{@newly_active_count} dates newly in service"
      assert impact =~ @route_id
      assert impact =~ "2 trips"
      assert impact =~ "#{@newly_active_count} newly active dates have no recorded day off"

      assert stored_end_date(context) == @current_end
    end
  end

  describe "applying the reviewed extension" do
    test "an exact apply writes the reviewed end date once and credits the card", context do
      view = approved_view(context) |> prepare() |> open_review()

      view |> element("#calendar-extension-apply") |> render_click()
      settled = settle(view, &(&1 =~ "Extended SCHOOL_WD"))

      assert settled =~ "Extended SCHOOL_WD through Mar 31, 2027. 1 row changed."
      refute has_element?(view, "#calendar-extension-impact")

      assert stored_end_date(context) == @approved_end

      # One audited write, attributed to the editor who applied it.
      logs = Repo.all(from(l in ChangeLog, where: l.gtfs_version_id == ^context.version.id))
      assert logs != []
      assert Enum.all?(logs, &(&1.actor_id == context.user.id))

      # The card is credited by the page's own receipt, not by the session's
      # events, so the assertion reads what the editor sees.
      assert element(view, "#agent-prepared-2") |> render() =~ "Applied"
      refute has_element?(view, "#agent-review-prepared-2")
    end

    test "a second submission of the same review writes nothing more", context do
      view = approved_view(context) |> prepare() |> open_review()

      view |> element("#calendar-extension-apply") |> render_click()
      _settled = settle(view, &(&1 =~ "Extended SCHOOL_WD"))

      # The reviewed impact is gone, so there is no second control left to press.
      refute has_element?(view, "#calendar-extension-impact")
      assert stored_end_date(context) == @approved_end

      assert Repo.aggregate(
               from(l in ChangeLog, where: l.gtfs_version_id == ^context.version.id),
               :count
             ) == 1
    end

    test "an edited end date applies the edit and leaves the card unconfirmed", context do
      view = approved_view(context) |> prepare() |> open_review()

      view
      |> element("#calendar-extension-review-form")
      |> render_change(%{"extension_review" => %{"end_date" => Date.to_iso8601(@edited_end)}})

      assert element(view, "#calendar-extension-impact") |> render() =~ "Feb 26, 2027"

      view |> element("#calendar-extension-apply") |> render_click()
      settled = settle(view, &(&1 =~ "Extended SCHOOL_WD"))

      assert settled =~ "Extended SCHOOL_WD through Feb 26, 2027."
      assert stored_end_date(context) == @edited_end

      # The native edit is never credited as the helper's exact command.
      assert view |> element("#agent-notice") |> render() =~ "was not applied"
      assert element(view, "#agent-prepared-2") |> render() =~ "Ready to review"
      assert has_element?(view, "#agent-review-prepared-2")
    end

    test "a competing change after the review makes Apply stale and writes nothing", context do
      view = approved_view(context) |> prepare() |> open_review()

      # Another session commits a different end date on the same calendar.
      {:ok, command_review} =
        Gtfs.review_calendar_change(
          {:save, @service_id, %{end_date: Date.to_iso8601(@edited_end)}},
          %{@service_id => fingerprint_for(context, @service_id)},
          audit_context(context)
        )

      assert {:ok, _result} =
               Gtfs.apply_calendar_change(
                 {:save, @service_id, %{end_date: Date.to_iso8601(@edited_end)}},
                 command_review.fingerprint,
                 audit_context(context)
               )

      view |> element("#calendar-extension-apply") |> render_click()
      settled = settle(view, &(&1 =~ "Nothing was extended."))

      assert settled =~ "Nothing was extended."
      assert settled =~ "nothing was written"
      # The stale review leaves Apply disabled until the editor refreshes it.
      assert has_element?(view, "#calendar-extension-refresh")
      assert has_element?(view, "#calendar-extension-apply[disabled]")

      # The competing end date stands; the reviewed one was never written.
      assert stored_end_date(context) == @edited_end
      assert element(view, "#agent-prepared-2") |> render() =~ "Ready to review"
    end
  end

  ## Helpers

  defp calendars_view(context) do
    conn = log_in_user(context.conn, context.user, organization: context.organization)

    assert {:ok, view, _html} = live(conn, "/gtfs/#{context.version.id}/calendars")
    assert has_element?(view, "#calendars-list-container")
    view
  end

  # The approval the editor entered, with the helper panel open on the page that
  # holds it. The conversation is opened afterwards so it carries the approval.
  defp approved_view(context) do
    view = calendars_view(context)

    view
    |> element("#calendar-extension-form")
    |> render_submit(%{
      "extension" => %{
        "service_id" => @service_id,
        "end_date" => Date.to_iso8601(@approved_end),
        "approval_text" => @approval
      }
    })

    # Recording an approval resets the panel, so open the helper if the reset
    # left it closed; the conversation that follows carries the approval.
    if has_element?(view, "#agent-panel") do
      view
    else
      view |> element("#agent-helper-open") |> render_click()
    end

    view
  end

  # Scripts the deterministic prepare turn: one model reply calls
  # `prepare_calendar_extension` with the given arguments, the second settles it.
  defp prepare(view, arguments \\ @extension_arguments) do
    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, tool_calls_reply([{"call_1", "prepare_calendar_extension", arguments}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, text_reply("I prepared the extension. Review it before applying."))
    end)

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => "Can we extend the school weekdays calendar?"}})

    settle(view, &settled?/1)

    view
  end

  defp open_review(view) do
    view |> element("#agent-review-prepared-2") |> render_click()
    assert has_element?(view, "#calendar-extension-impact")
    view
  end

  # `start_async/3` settles the reviewed apply in the page's own task, so the
  # test reads the page until the server's own outcome is on it.
  defp settle(view, ready, attempts \\ 200) when is_function(ready, 1) do
    _ = render_async(view, 5_000)

    Enum.reduce_while(1..attempts, render(view), fn _attempt, html ->
      if ready.(html) do
        {:halt, html}
      else
        Process.sleep(10)
        {:cont, render(view)}
      end
    end)
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The catalog's own fingerprint for one calendar, which is what a reviewed
  # command is bound to.
  defp fingerprint_for(context, service_id) do
    {:ok, summaries} =
      Gtfs.load_calendar_catalog(context.organization.id, context.version.id, [])

    Enum.find(summaries, &(&1.service_id == service_id)).fingerprint
  end

  # The turn is settled when the panel has stopped reporting it as working:
  # the working badge and the status line are the only two places it says so.
  defp settled?(html), do: not String.contains?(html, "Working")

  defp stored_end_date(context) do
    Repo.one(
      from(c in Calendar,
        where: c.organization_id == ^context.organization.id,
        where: c.gtfs_version_id == ^context.version.id,
        where: c.service_id == @service_id,
        select: c.end_date
      )
    )
  end

  defp exception_count(context) do
    Repo.aggregate(
      from(cd in CalendarDate,
        where: cd.organization_id == ^context.organization.id,
        where: cd.gtfs_version_id == ^context.version.id,
        where: cd.service_id == @service_id
      ),
      :count
    )
  end

  defp add_calendar(organization, version, service_id, name) do
    calendar_fixture(
      organization.id,
      version.id,
      %{
        service_id: service_id,
        start_date: ~D[2026-09-01],
        end_date: @current_end
      }
      |> Map.merge(@weekdays)
    )

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end

  defp add_trips(organization, version, service_id, trip_ids) do
    route_fixture(organization.id, version.id, %{
      route_id: @route_id,
      route_long_name: "School connector"
    })

    Repo.insert_all(
      Trip,
      for(trip_id <- trip_ids) do
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_id: @route_id,
          service_id: service_id,
          trip_id: trip_id,
          trip_headsign: "School",
          direction_id: 0,
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
          updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        }
      end
    )
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
    DynamicSupervisor.which_children(GtfsPlanner.Agents.SessionSupervisor)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  defp tool_calls_reply(calls) do
    %{
      "id" => "gen-test-tool",
      "model" => @model,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "tool_calls",
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" =>
              Enum.map(calls, fn {id, name, arguments} ->
                %{
                  "id" => id,
                  "type" => "function",
                  "function" => %{"name" => name, "arguments" => arguments}
                }
              end)
          }
        }
      ],
      "usage" => %{"prompt_tokens" => 128, "completion_tokens" => 32, "cost" => 0.0}
    }
  end

  defp text_reply(content) do
    %{
      "id" => "gen-test-text",
      "model" => @model,
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 128, "completion_tokens" => 16, "cost" => 0.0}
    }
  end

  defp respond(conn, body), do: Req.Test.json(conn, body)
end

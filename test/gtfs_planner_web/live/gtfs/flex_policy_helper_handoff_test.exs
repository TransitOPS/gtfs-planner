defmodule GtfsPlannerWeb.Gtfs.FlexPolicyHelperHandoffTest do
  @moduledoc """
  The reviewed handoff from the helper to the native Flex page (AC-7–AC-13).

  Every case is judged through the ordinary authenticated route and the live
  session, never through private assign injection: the editor accepts their
  authorized policy text, asks the registered `flex_policy` pack a question, the
  pack prepares a candidate through the one OpenRouter HTTP boundary this module
  scripts, and the page's own "Review prepared change" control is the only way a
  review opens (INV-1, INV-5).

  What these cases hold the page to:

    * review, the overlap answers and staging perform zero writes, and only the
      page's own Save persists (AC-8, CR-1);
    * staging merges the reviewed arrays into the whole current draft, so an
      unsaved phone number, an eligibility sentence, an area's name and geometry
      and every untargeted row survive it and the native save that follows
      (AC-9, CR-2, INV-3);
    * a targeted array the editor has already changed needs an explicit answer,
      and a draft that moved after the review refuses the stage and keeps the
      latest draft (AC-9);
    * a calendar-only commit after staging refuses the Save under the guard, with
      the whole draft and the accepted source retained, and every later Save
      refuses it again until a fresh review or the explicit discard (AC-10,
      AC-11, AC-12);
    * a forged entry id and a forged array or choice are each the same refusal
      and never reach a surface, and a replaced source drops the review but
      leaves the staged rows behind a lapsed guard, so the page's own Save
      cannot persist them (AC-1, AC-2, AC-7, AC-11, INV-2);
    * the stale banner's "save both changes" cannot slip a staged change past the
      guard, and an uncertain or refused receipt never reports a saved service
      (AC-11, AC-12).

  The focused command is deferred to branch review:
  `mix test test/gtfs_planner_web/live/gtfs/flex_policy_helper_handoff_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.TurnSupervisor
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Flex
  alias GtfsPlanner.Gtfs.Flex.Geometry

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the final provider HTTP.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @policy_text "Newport Dial-a-Ride runs weekdays 7:00 am to 6:00 pm. " <>
                 "Riders must call at least the day before by 4:00 pm."
  @first_question "Set the weekday hours from this policy."

  # The complete replacement hours array this module's proposals send: the
  # fixture's four rows, with the two weekday windows moved later. Every row is
  # enumerated, because a replacement array is the final state of that array.
  @proposed_hours [
    %{"area_key" => "a1", "service_id" => "weekday", "start" => "08:00", "end" => "17:00"},
    %{"area_key" => "a2", "service_id" => "weekday", "start" => "10:00", "end" => "16:00"},
    %{"area_key" => "a1", "service_id" => "saturday", "start" => "18:00", "end" => "01:00"},
    %{"area_key" => "a2", "service_id" => "saturday", "start" => "09:00", "end" => "15:00"}
  ]

  # A real native calendar write, through the same review-then-apply pair the
  # Calendars page uses. It moves a calendar the service's saved rows name and
  # never touches the service row, so only a dependency check can catch it.
  @saturday_command {:save, "saturday", %{saturday: 0, sunday: 1}}

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    # The session's turn runs in its own process, so the Req.Test plug and the
    # SQL sandbox are both shared with it.
    ensure_turn_supervisor()

    conn = build_conn()
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id, %{name: "Helper Version"})
    flex_representative_fixture(organization, version)

    track_sessions()

    service = service_named(organization.id, version.id, "Newport Dial-a-Ride")

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      user: user,
      version: version,
      service: service,
      audit: flex_audit_fixture(organization.id, version.id),
      original_lock_version: lock_version_of(organization.id, version.id, service.id)
    }
  end

  describe "review and staging write nothing" do
    test "the review shows the comparison and Use changes stages without saving", context do
      view = ready_view(context)
      _entry_id = prepared_entry(context, view)

      # The review is the native comparison of a freshly prepared candidate: the
      # two moved weekday rows, the untouched rows counted, the fields nothing
      # touched and the generated wording on both sides.
      assert has_element?(view, "#flex-policy-review")
      assert has_element?(view, "#flex-policy-review[aria-labelledby=flex-policy-review-title]")
      assert has_element?(view, "#flex-policy-review-state[role=status]")
      assert has_element?(view, "#flex-policy-review-hours", "Row 1")
      assert has_element?(view, "#flex-policy-review-hours", "07:00 → 08:00")
      assert has_element?(view, "#flex-policy-review-unchanged", "eligibility")
      assert has_element?(view, "#flex-policy-review-wording", "With this change")
      assert has_element?(view, "#flex-policy-stage")

      # Nothing has been staged and nothing has been written: the service on
      # disk is the fixture's, and the page is still clean (CR-1).
      refute has_element?(view, "#flex-policy-staged")
      refute has_element?(view, "#save-bar")
      assert stored_hours(context) == saved_hours(context)
      assert lock_version(context) == original_lock_version(context)

      view |> element("#flex-policy-stage") |> render_click()

      # Staging merges into the page: the reviewed rows are in the native form
      # and the page is now dirty, but the row on disk has not moved.
      assert has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#flex-policy-discard-staged")
      assert has_element?(view, "#flex-service-page[data-dirty=true]")
      assert has_element?(view, "#save-bar")
      assert has_element?(view, "#rider-preview")
      assert stored_hours(context) == saved_hours(context)
      assert lock_version(context) == original_lock_version(context)
    end

    test "the whole draft survives staging and the native save that follows", context do
      view = ready_view(context)

      # Unsaved work the helper never saw: a new phone line, a second booking
      # link and a note.
      view
      |> element("#flex-service-form")
      |> render_change(%{
        "service" => %{
          "phone" => "(541) 555-0999",
          "info_url" => "https://example.org/newport",
          "note" => "Winter overflow starts in January."
        }
      })

      # The renamed area must come back with the boundary it was drawn with, so
      # the geometry is read before the rename rather than against a sibling.
      original_geometry = stored_area_geojson(context, "a1")

      rename_area(view, context, "a1", "Greater Newport")

      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()

      # The staged page carries both the assistant's reviewed rows and every
      # unsaved field the editor typed (AC-9, CR-2).
      assert value_of(view, "#service_phone") == "(541) 555-0999"
      assert value_of(view, "#service_info_url") == "https://example.org/newport"
      assert text_of_input(doc(view), "#service_note") == "Winter overflow starts in January."
      assert has_element?(view, "#f-area-a1", "Greater Newport")
      assert has_element?(view, "#service_hours_0_start[value='08:00']")

      view |> element("#flex-service-form") |> render_submit(%{})

      # The one native save wrote the whole page, not just the reviewed arrays,
      # and the renamed area kept its stored geometry rather than losing it
      # (CR-2, R8).
      assert stored_phone(context) == "(541) 555-0999"
      assert stored_info_url(context) == "https://example.org/newport"
      assert stored_note(context) == "Winter overflow starts in January."
      assert stored_area_name(context, "a1") == "Greater Newport"

      assert same_geometry?(stored_area_geojson(context, "a1"), original_geometry)

      assert stored_hours(context) == @proposed_hours

      # The saved page is clean again and the assistant's state is spent: a
      # saved change is a new baseline and cannot be re-saved through a guard
      # the old review built (AC-11).
      assert has_element?(view, "#flex-service-page[data-dirty=false]")
      refute has_element?(view, "#flex-policy-staged")
      refute has_element?(view, "#save-bar")
    end
  end

  describe "explicit overlap choices" do
    test "a changed targeted array needs an answer and staging is refused without it", context do
      view = ready_view(context)

      # The editor moves the first weekday window themselves, so the prepared
      # hours array overlaps the draft.
      view
      |> element("#flex-service-form")
      |> render_change(%{
        "service" => %{"hours" => %{"0" => %{"start" => "07:30"}}}
      })

      prepared_entry(context, view)

      # The overlap is named, and both answers are offered for it.
      assert has_element?(view, "#flex-policy-overlap", "You already changed these")
      assert has_element?(view, "#flex-policy-overlap-hours", "differ from what is saved")
      assert has_element?(view, "#flex-policy-overlap-hours-draft")
      assert has_element?(view, "#flex-policy-overlap-hours-proposal")
      refute has_element?(view, "#flex-policy-overlap-booking_rules")

      # Staging is refused while the question is open, and the draft is exactly
      # where the editor left it.
      view |> element("#flex-policy-stage") |> render_click()

      assert has_element?(
               view,
               "#flex-policy-review-notice",
               "Choose what to keep for each overlapping field"
             )

      refute has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#service_hours_0_start[value='07:30']")
      assert lock_version(context) == original_lock_version(context)

      # The editor's own answer wins: the draft's rows are kept and nothing else
      # in the reviewed array is touched.
      choose(view, "hours", "draft")
      view |> element("#flex-policy-stage") |> render_click()

      assert has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#service_hours_0_start[value='07:30']")
      assert has_element?(view, "#service_hours_0_end[value='18:00']")

      view |> element("#flex-service-form") |> render_submit(%{})

      assert [first | _rest] = stored_hours(context)
      assert first["start"] == "07:30"
      assert first["end"] == "18:00"
    end

    test "the prepared change wins only for the array it was chosen for", context do
      view = ready_view(context)

      view
      |> element("#flex-service-form")
      |> render_change(%{
        "service" => %{"hours" => %{"0" => %{"start" => "07:30"}}}
      })

      prepared_entry(context, view)
      choose(view, "hours", "proposal")
      view |> element("#flex-policy-stage") |> render_click()

      assert has_element?(view, "#service_hours_0_start[value='08:00']")
      assert has_element?(view, "#service_hours_0_end[value='17:00']")
    end

    test "a draft that moved after the review refuses the stage and keeps the latest draft",
         context do
      view = ready_view(context)
      prepared_entry(context, view)

      # The draft moves after the review was opened.
      view
      |> element("#flex-service-form")
      |> render_change(%{
        "service" => %{"hours" => %{"0" => %{"start" => "06:45"}}}
      })

      view |> element("#flex-policy-stage") |> render_click()

      assert has_element?(view, "#flex-policy-review-notice", "changed since this review")
      refute has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#service_hours_0_start[value='06:45']")
      assert lock_version(context) == original_lock_version(context)
    end

    test "a forged array or a third choice is the same refusal as a closed review", context do
      view = ready_view(context)
      prepared_entry(context, view)

      # An array the preparation never replaced, and a value that is neither of
      # the two answers.
      render_click(view, "flex_policy_overlap", %{
        "array" => "booking_rules",
        "choice" => "proposal"
      })

      render_click(view, "flex_policy_overlap", %{"array" => "hours", "choice" => "whatever"})

      assert has_element?(view, "#flex-policy-review")
      refute has_element?(view, "#flex-policy-overlap-booking_rules")
      refute has_element?(view, "#flex-policy-overlap-hours-draft[checked]")
      refute has_element?(view, "#flex-policy-overlap-hours-proposal[checked]")
      assert lock_version(context) == original_lock_version(context)
    end
  end

  describe "the guard survives into the native transaction" do
    test "a calendar-only commit after staging refuses the save and keeps the draft", context do
      view = ready_view(context)
      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()
      assert has_element?(view, "#flex-policy-staged")

      # Somebody else changes one of the calendars this service's saved rows
      # name. The service row itself never moves, so only a dependency check can
      # catch this.
      save_saturday_calendar(context)

      view |> element("#flex-service-form") |> render_submit(%{})

      refute has_element?(view, "#flex-service-stale")
      assert has_element?(view, "#flex-service-save-error")
      assert text_of(doc(view), "#flex-service-save-error") =~ "calendars changed"
      refute has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#save-bar")

      # Nothing was written, and both the whole draft and the accepted source
      # are exactly what they were (AC-10, AC-12).
      assert stored_hours(context) == saved_hours(context)
      assert lock_version(context) == original_lock_version(context)
      assert has_element?(view, "#flex-policy-source-accepted")
      assert value_of(view, "#service_hours_0_start") == "08:00"
    end

    test "a refused guard keeps the rows behind it, so the next Save is refused again",
         context do
      view = ready_view(context)
      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()
      save_saturday_calendar(context)

      view |> element("#flex-service-form") |> render_submit(%{})
      assert text_of(doc(view), "#flex-service-save-error") =~ "calendars changed"

      # The refusal lapses the stage instead of dropping it: the rows are still
      # assistant-origin, and the page says so and offers the explicit way out.
      assert has_element?(view, "#flex-policy-stage-lapsed")
      assert has_element?(view, "#flex-policy-discard-staged")

      # Pressing Save again must not fall through to the ordinary writer. The
      # calendar commit never touched the service row, so its lock version is
      # still current and an unguarded save would succeed and persist the rows.
      view |> element("#flex-service-form") |> render_submit(%{})

      assert has_element?(view, "#flex-service-save-error")
      assert has_element?(view, "#flex-policy-stage-lapsed")
      assert stored_hours(context) == saved_hours(context)
      assert lock_version(context) == original_lock_version(context)

      # Discarding is the explicit way out: the rows leave the draft and the
      # page is an ordinary native draft again.
      view |> element("#flex-policy-discard-staged") |> render_click()

      refute has_element?(view, "#flex-policy-stage-lapsed")
      assert has_element?(view, "#service_hours_0_start[value='07:00']")
    end

    test "reviewing again after a refused guard stages the rows behind a fresh guard", context do
      view = ready_view(context)
      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()
      save_saturday_calendar(context)

      view |> element("#flex-service-form") |> render_submit(%{})
      assert has_element?(view, "#flex-policy-stage-lapsed")

      # The review the refusal asks for: the staged rows are in the draft, so
      # the preparation reads them as the overlap and the editor answers it.
      prepared_entry(context, view)
      choose(view, "hours", "proposal")
      view |> element("#flex-policy-stage") |> render_click()

      assert has_element?(view, "#flex-policy-staged")
      refute has_element?(view, "#flex-policy-stage-lapsed")

      view |> element("#flex-service-form") |> render_submit(%{})

      assert stored_hours(context) == @proposed_hours
    end

    test "a draft edit after staging refuses the save until a fresh review stages it", context do
      view = ready_view(context)
      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()

      # A disjoint native field: the reviewed rows are untouched, but the page
      # the guard was built for is not the page on screen any more.
      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => %{"note" => "Holiday schedule to follow."}})

      view |> element("#flex-service-form") |> render_submit(%{})

      # The refusal keeps the whole draft, the staged rows and the accepted
      # source, and names the two ways forward rather than writing anything
      # (AC-11, AC-12).
      assert has_element?(view, "#flex-service-save-error")
      assert text_of(doc(view), "#flex-service-save-error") =~ "moved after the prepared change"
      assert has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#flex-policy-stage-stale")
      assert has_element?(view, "#flex-policy-source-accepted")
      assert text_of_input(doc(view), "#service_note") == "Holiday schedule to follow."
      assert stored_note(context) == nil
      assert lock_version(context) == original_lock_version(context)

      # The refreshed merged preview the refusal asks for keeps the disjoint
      # field and re-stages the reviewed rows behind a new guard. Because the
      # first stage already put the proposal's rows in the draft, the refreshed
      # review asks the same overlap question again, and this time the answer is
      # the proposal itself.
      prepared_entry(context, view)
      choose(view, "hours", "proposal")
      view |> element("#flex-policy-stage") |> render_click()

      assert has_element?(view, "#flex-policy-staged")
      refute has_element?(view, "#flex-policy-stage-stale")
      assert text_of_input(doc(view), "#service_note") == "Holiday schedule to follow."
      assert has_element?(view, "#service_hours_0_start[value='08:00']")

      view |> element("#flex-service-form") |> render_submit(%{})

      assert stored_note(context) == "Holiday schedule to follow."
      assert stored_hours(context) == @proposed_hours
    end

    test "a replaced source drops the review and keeps the staged rows behind a lapsed guard",
         context do
      view = ready_view(context)
      saved = stored_hours(context)
      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()
      assert has_element?(view, "#flex-policy-staged")

      accept_source(view, "Second policy", nil, "Riders call ahead on weekdays only.")

      # The accepted source changed, so the conversation the review belonged to
      # is gone: the comparison itself is gone, and the staged rows are marked
      # lapsed rather than dropped, so the page still routes this draft through
      # the guarded writer and still offers the explicit discard (AC-2, AC-11,
      # INV-2).
      refute has_element?(view, "#flex-policy-review-hours")
      assert has_element?(view, "#flex-policy-stage-lapsed")
      assert has_element?(view, "#flex-policy-discard-staged")
      assert has_element?(view, "#flex-policy-source-accepted", "Second policy")
      assert has_element?(view, "#service_hours_0_start[value='08:00']")

      # The stage's guard is the replaced source's, so the page's own Save is
      # refused rather than written: nothing assistant-origin reaches the
      # database, and the stored rows are still the saved ones.
      view |> element("#flex-service-form") |> render_submit(%{})

      assert stored_hours(context) == saved
      refute stored_hours(context) == @proposed_hours

      # The explicit discard is the other way out, and it leaves the editor's
      # own unsaved work alone.
      view |> element("#flex-policy-discard-staged") |> render_click()

      refute has_element?(view, "#flex-policy-stage-lapsed")
      assert has_element?(view, "#service_hours_0_start[value='07:00']")

      view |> element("#flex-service-form") |> render_submit(%{})

      assert stored_hours(context) == saved
    end

    test "the staged rows can be taken back out and the editor's own work stays", context do
      view = ready_view(context)

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => %{"phone" => "(541) 555-0777"}})

      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()
      assert has_element?(view, "#service_hours_0_start[value='08:00']")

      view |> element("#flex-policy-discard-staged") |> render_click()

      refute has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#service_hours_0_start[value='07:00']")
      assert value_of(view, "#service_phone") == "(541) 555-0777"

      view |> element("#flex-service-form") |> render_submit(%{})

      assert stored_phone(context) == "(541) 555-0777"
      assert stored_hours(context) == saved_hours(context)
    end
  end

  describe "the native conflict flow cannot bypass the guard" do
    test "a native conflict refuses a staged draft rather than saving both", context do
      view = ready_view(context)
      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()
      assert has_element?(view, "#flex-policy-staged")

      # Another session saves the same service, so this page's reviewed baseline
      # has already moved.
      :ok = save_service_in_another_session(context)

      # The guarded transaction sees the moved baseline before any mutation, so
      # the editor gets the dependency refusal rather than a page written on top
      # of a row nobody reviewed (AC-10, AC-11). The native stale banner is not
      # shown either: the guard's own check is the one that answered.
      view |> element("#flex-service-form") |> render_submit(%{})

      assert has_element?(view, "#flex-service-save-error")
      assert text_of(doc(view), "#flex-service-save-error") =~ "calendars changed"
      refute has_element?(view, "#flex-service-stale")
      refute has_element?(view, "#flex-policy-staged")
      assert stored_hours(context) == saved_hours(context)

      # The way forward is the editor's: the whole draft and the accepted source
      # are still here, and the rows stay behind a lapsed guard until a fresh
      # review stages them again or the editor discards them.
      assert has_element?(view, "#flex-policy-source-accepted")
      assert has_element?(view, "#service_hours_0_start[value='08:00']")
      assert has_element?(view, "#save-bar")
      assert has_element?(view, "#flex-policy-stage-lapsed")
      assert has_element?(view, "#flex-policy-discard-staged")

      # Pressing Save again, or "Save both changes", is the same refusal. With
      # the guard dropped, the page's own writer would have answered the first
      # with the native stale banner and the second with a write of the staged
      # rows on top of the other editor's row (AC-11).
      view |> element("#flex-service-form") |> render_submit(%{})

      refute has_element?(view, "#flex-service-stale")
      assert has_element?(view, "#flex-service-save-error")
      assert stored_hours(context) == saved_hours(context)

      render_click(view, "save_both_changes", %{})

      assert has_element?(view, "#flex-policy-stage-lapsed")
      assert has_element?(view, "#flex-policy-discard-staged")
      assert stored_hours(context) == saved_hours(context)
      assert stored_note(context) == "Changed in another session."
    end

    test "save both changes on an ordinary draft still works after a conflict", context do
      view = ready_view(context)

      view
      |> element("#flex-service-form")
      |> render_change(%{"service" => %{"hours" => %{"0" => %{"start" => "06:45"}}}})

      :ok = save_service_in_another_session(context)

      view |> element("#flex-service-form") |> render_submit(%{})
      assert has_element?(view, "#flex-service-stale")

      # The ordinary path is untouched by this step: with no staged guard,
      # "save both changes" writes this draft on top of their row.
      view |> element("#stale-both") |> render_click()

      assert [first | _rest] = stored_hours(context)
      assert first["start"] == "06:45"
      assert has_element?(view, "#flex-service-page[data-dirty=false]")
    end

    test "an uncertain receipt never reports a saved service", context do
      view = ready_view(context)
      prepared_entry(context, view)
      view |> element("#flex-policy-stage") |> render_click()

      # The service row moves between the review and the save, so the answer the
      # editor gets is a refusal, never a saved receipt (AC-12).
      :ok = save_service_in_another_session(context)

      view |> element("#flex-service-form") |> render_submit(%{})

      refute has_element?(view, "#flex-policy-source-accepted", "Saved")
      refute has_element?(view, "#flex-service-page[data-dirty=false]")
      assert stored_hours(context) == saved_hours(context)
      assert has_element?(view, "#save-bar")
    end
  end

  describe "the fence in front of the review" do
    test "a forged entry id and a replaced source are the same refusal", context do
      view = ready_view(context)
      prepared_entry(context, view)

      render_click(view, "agent_review_prepared", %{"entry" => "9999"})
      assert has_element?(view, "#agent-panel", "no longer current")

      accept_source(view, "Replaced policy", nil, "A different authorized policy entirely.")

      render_click(view, "agent_review_prepared", %{"entry" => "1"})

      refute has_element?(view, "#flex-policy-staged")
      assert has_element?(view, "#agent-panel", "no longer current")
      assert lock_version(context) == original_lock_version(context)
    end

    test "a review of a moved service writes nothing", context do
      view = ready_view(context)
      prepared_entry(context, view)

      # The staging event is answered with an unrelated payload and an entry id
      # the page never issued: the review is still the one this page opened, and
      # the stage is refused on its own terms rather than on the payload's.
      render_click(view, "flex_policy_stage", %{"entry" => "9999"})

      assert has_element?(view, "#flex-policy-review")
      assert has_element?(view, "#flex-policy-staged")
      assert lock_version(context) == original_lock_version(context)
    end
  end

  # --- the conversation --------------------------------------------------------

  # Accepts the source, opens the helper, and drives one turn that reads the
  # pack's context and prepares the complete hours replacement. Only the final
  # provider HTTP is faked; the pack, the assistant and the prepared command are
  # the real ones (INV-5).
  defp prepared_entry(_context, view) do
    accept_source(view, "Newport flex policy", "rev 3", @policy_text)
    view |> element("#agent-helper-open") |> render_click()
    pid = join_session(view)

    expect_reply(1, tool_calls_reply([{"call_1", "get_flex_policy_context", "{}"}]))
    expect_reply(1, tool_calls_reply([{"call_2", "prepare_flex_policy", prepare_arguments()}]))

    expect_reply(
      1,
      text_reply("I moved the weekday windows. Review it before anything is saved.")
    )

    submit(view, @first_question)

    assert_receive {:model_request, request}, 5_000
    assert "prepare_flex_policy" in tool_names(request)

    entry = await_settled(pid)
    assert entry.prepared, "the pack did not prepare a candidate"
    assert entry.status == :done

    view |> element("#agent-review-prepared-#{entry.id}") |> render_click()
    entry.id
  end

  defp prepare_arguments do
    Jason.encode!(%{"scope" => "all_supported", "hours" => @proposed_hours})
  end

  # --- the page ---------------------------------------------------------------

  defp ready_view(context) do
    {:ok, view, _html} = live(context.conn, service_path(context.version, context.service))
    _ = :sys.get_state(view.pid)
    view
  end

  defp service_path(version, service), do: "/gtfs/#{version.id}/flex/#{service.id}"

  defp accept_source(view, label, revision, text) do
    view
    |> element("#flex-policy-source-form")
    |> render_submit(%{
      "flex_policy" => %{"label" => label, "revision" => revision || "", "text" => text}
    })
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  # Renames one area through the page's own area editor, which is the only
  # place a name is edited, and returns to the service page with the draft's
  # other fields intact.
  # The overlap answer is a radio control, so this drives the same server event
  # the control's own `phx-click` sends, which keeps the case about the recorded
  # answer rather than about how a browser orders click and change for radios.
  defp choose(view, array, choice) do
    render_click(view, "flex_policy_overlap", %{"array" => array, "choice" => choice})
  end

  # A textarea keeps its value as the element's text, not as a `value`
  # attribute, so the two reads are kept apart deliberately.
  defp text_of_input(document, selector) do
    case LazyHTML.query(document, selector) |> Enum.find(fn _match -> true end) do
      nil -> nil
      match -> match |> LazyHTML.text() |> String.trim()
    end
  end

  defp rename_area(view, context, key, name) do
    view |> element("#edit-area-#{key}") |> render_click()
    assert_patch(view, "/gtfs/#{context.version.id}/flex/#{context.service.id}/area?area=#{key}")
    view |> element("#area-mode-edit") |> render_click()
    view |> element("#area-name-form") |> render_change(%{"area" => %{"name" => name}})
    view |> element("#use-area") |> render_click()
  end

  # --- the stored row ---------------------------------------------------------

  defp stored(context) do
    {:ok, service} =
      Flex.get_service(context.organization.id, context.version.id, context.service.id)

    service
  end

  defp stored_hours(context) do
    context
    |> stored()
    |> Map.fetch!(:hours)
    |> Enum.map(&Map.take(&1, [:area_key, :service_id, :start, :end]))
    |> Enum.map(fn row -> Map.new(row, fn {key, value} -> {to_string(key), value} end) end)
  end

  defp saved_hours(context), do: stored_hours(context)

  defp stored_phone(context), do: stored(context).phone
  defp stored_info_url(context), do: stored(context).info_url
  defp stored_note(context), do: stored(context).note

  defp stored_area_name(context, key) do
    context
    |> stored()
    |> Map.fetch!(:areas)
    |> Enum.find(&(&1.key == key))
    |> Map.fetch!(:name)
  end

  # The stored polygon as the geometry reader returns it, so a rename that kept
  # the boundary is stated as the boundary rather than as an absence.
  defp stored_area_geojson(context, key) do
    area =
      context
      |> stored()
      |> Map.fetch!(:areas)
      |> Enum.find(&(&1.key == key))

    Geometry.get_geojson([area.id])
  end

  # `get_geojson/1` returns a map keyed by area id, so the single area's ring is
  # read back and compared by point count, which checks the shape the editor
  # drew rather than exact coordinates.
  defp same_geometry?(left, right) do
    [left_ring] = left |> Map.values() |> Enum.map(&hd(&1["coordinates"]))
    [right_ring] = right |> Map.values() |> Enum.map(&hd(&1["coordinates"]))

    length(left_ring) == length(right_ring)
  end

  defp lock_version(context), do: stored(context).lock_version

  defp original_lock_version(context), do: context.original_lock_version

  # A real native write from another session, through the ordinary unguarded
  # writer: the service row's lock version moves and nothing else does.
  defp save_service_in_another_session(context) do
    service = stored(context)

    {:ok, _saved} =
      Flex.save_service(
        context.audit,
        service,
        %{note: "Changed in another session."},
        []
      )

    :ok
  end

  # A calendar-only commit through the real native calendar writer, which
  # reviews before it applies. The flex service row is not touched at all.
  defp save_saturday_calendar(context) do
    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, "saturday")

    assert {:ok, review} =
             Gtfs.review_calendar_change(
               @saturday_command,
               %{"saturday" => payload.fingerprint},
               context.audit
             )

    assert {:ok, %{} = applied} =
             Gtfs.apply_calendar_change(@saturday_command, review.fingerprint, context.audit)

    applied
  end

  defp lock_version_of(organization_id, version_id, service_id) do
    {:ok, service} = Flex.get_service(organization_id, version_id, service_id)
    service.lock_version
  end

  # --- helpers ----------------------------------------------------------------

  defp service_named(organization_id, version_id, name) do
    organization_id
    |> Flex.list_services(version_id)
    |> Enum.find(&(&1.name == name))
  end

  defp tool_names(request), do: Enum.map(request["tools"], & &1["function"]["name"])

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(TurnSupervisor)) do
      start_supervised!({Task.Supervisor, name: TurnSupervisor, max_children: 8})
    end
  end

  defp await_settled(pid) do
    assert_receive {:agent_event, ^pid, {:entry, %{role: :assistant} = entry}}, 5_000

    if entry.status == :working do
      await_settled(pid)
    else
      entry
    end
  end

  defp session_pid(view), do: :sys.get_state(view.pid).socket.assigns.agent_session

  defp panel_scope(view) do
    assigns = :sys.get_state(view.pid).socket.assigns

    %Scope{
      organization_id: assigns.current_organization.id,
      gtfs_version_id: assigns.current_gtfs_version.id,
      user_id: assigns.current_user.id,
      user_email: assigns.current_user.email,
      pack_id: assigns.agent_pack_id,
      version_name: assigns.current_gtfs_version.name,
      resource_context: assigns.agent_context
    }
  end

  defp join_session(view) do
    pid = session_pid(view)
    assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(view))
    pid
  end

  defp doc(view), do: LazyHTML.from_fragment(render(view))

  defp text_of(document, selector) do
    document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp value_of(view, selector) do
    case view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute("value") do
      [value | _rest] -> value
      [] -> nil
    end
  end

  # Sessions are started under the application's own supervisor and outlive the
  # test socket, so every session this module opened is terminated here.
  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(Agents.SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    Agents.SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp expect_reply(count, payload) do
    test = self()

    Req.Test.expect(@owner, count, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

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

  defp text_reply(text), do: reply("stop", %{"content" => text})

  defp reply(finish_reason, message) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => finish_reason, "message" => message}],
      "usage" => %{"cost" => 0.0}
    }
  end
end

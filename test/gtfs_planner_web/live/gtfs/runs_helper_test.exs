defmodule GtfsPlannerWeb.Gtfs.RunsHelperHandoffTest do
  @moduledoc """
  The Runs helper handoff into the existing Suggest runs drawer (EV-7).

  The page, the conversation session and the turn task that prepares a
  configuration are separate processes, so the SQL sandbox and the Req.Test plug
  are shared (`async: false`) and only the OpenRouter HTTP boundary is scripted.
  Everything else is production composition: the real `Runs` day load, the real
  `OperationsAssistance` projection and admission, the real registered pack
  behind the real `Dispatch` fence, and the page's own existing Preview, Apply
  and Confirm handlers.

  The negatives are the point of this file, so each case asserts the mutation
  that must not happen as well as the one that must: no cutter run is started by
  opening a configuration, no row is written by preparing one, and a day, crew
  rules or membership that moved under the panel refuses rather than opening a
  drawer built from someone else's evidence.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.RunsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.OperationsAssistance
  alias GtfsPlanner.Repo

  # The test environment routes `GtfsPlanner.Agents.Model` through this plug, so
  # every scripted response replaces only the OpenRouter HTTP boundary.
  @owner GtfsPlanner.Agents.Model
  @model "test/model-a"

  @stale_notice "prepared from a different day"
  @preview_notice "Discard the current suggestion first"
  @missing_notice "no longer available"
  @draft_notice "another scope chosen"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    world = runs_version_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: world.organization.id,
      roles: ["pathways_studio_editor"]
    })

    track_sessions()

    world = Map.merge(world, %{user: user})
    %{conn: log_in_user(build_conn(), user, organization: world.organization), world: world}
  end

  describe "mounting the helper on the ordinary route" do
    test "the page mounts the registered runs pack and offers its one mode", context do
      {:ok, view, _html} = live(context.conn, runs_path(context.world))

      # The panel is mounted with `runs` as both default and only allowed pack.
      assigns = assigns(view)
      assert assigns.agent_pack_id == "runs"
      assert assigns.agent_allowed_packs == ["runs"]
      assert assigns.agent_title == "Runs helper"

      # The panel is closed until asked for, and the day's own controls are
      # unaffected by its existence.
      refute has_element?(view, "#agent-panel")
      refute has_element?(view, "#runs-helper-notice")
      assert has_element?(view, "#runs-suggest")
      assert has_element?(view, "#runs-review-problems")

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='false']")
    end

    test "opening the panel attaches a real session for this page's day", context do
      {:ok, view, _html} = live(context.conn, runs_path(context.world))

      view |> element("#agent-helper-open") |> render_click()

      assert is_pid(assigns(view).agent_session)
    end

    test "a loaded day is frozen into the panel's own source snapshot", context do
      {:ok, view, _html} = live(context.conn, runs_path(context.world))
      view |> element("#agent-helper-open") |> render_click()

      # The admitted copy is the payload the page's own projection built, under
      # this module's kind — not a pointer to the socket's day assign.
      snapshot = helper_snapshot(context.world, assigns(view))

      assert snapshot.kind == "operations_runs"
      assert snapshot.payload["section"] == "runs"
      assert snapshot.payload["day_key"] == context.world.day_type_key
      assert snapshot.payload["plan"] == nil
      assert snapshot.payload["completeness"] == "complete"
      assert snapshot.payload["scope"]["mode"] == "whole_day"

      # The runs page has no narrower selection to freeze, so the selection is
      # empty rather than a second scope the payload does not honour.
      assert snapshot.payload["selection"] == %{
               "selected_run_refs" => [],
               "selected_trip_refs" => []
             }
    end

    test "a version with no service day holds no copy at all", context do
      # A second version with no calendar derives no day type, so this page has
      # nothing to freeze and the helper says so rather than answering from the
      # day the reader was on a moment ago.
      empty_version = gtfs_version_fixture(context.world.organization.id, %{name: "No Service"})

      {:ok, view, _html} = live(context.conn, "/gtfs/#{empty_version.id}/runs")

      assert assigns(view).runs_day == nil
      assert assigns(view).load_state == :no_dates

      # The helper's own control is offered where there is a day to read, so this
      # page never offers an action with no evidence behind it.
      refute has_element?(view, "#agent-helper-open")
    end
  end

  describe "opening a prepared configuration" do
    test "uncovered_only opens the drawer on that scope and starts no job", context do
      cover_one_segment(context.world)
      before = trip_run_count(context.world)

      {view, pid} = prepared_view(context, "uncovered_only")

      # The card names the configuration, not a change.
      assert has_element?(view, "#agent-prepared-2")
      assert has_element?(view, "#agent-review-prepared-2", "Review configuration")

      assert element(view, "#agent-composer-hint") |> render() =~
               "Start suggestions in the native drawer"

      assert view |> element("#agent-review-prepared-2") |> render_click() =~ "Suggest runs"

      # The drawer's own scope control is on the prepared scope, not on the
      # default this page would otherwise have derived.
      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#runs-scope-uncovered[checked]")
      refute has_element?(view, "#runs-scope-rebuild[checked]")

      # The review discloses the day, the scope, what the day already holds and
      # how much work this scope would add.
      assert has_element?(view, "#runs-helper-scope-details", context.world.day_type_key)
      assert has_element?(view, "#runs-helper-scope-details", "Uncovered work only")
      assert has_element?(view, "#runs-helper-scope-details", "Nothing is cut or saved")

      # No scope here replaces the day, so the rebuild warning is absent.
      refute has_element?(view, "#runs-helper-replacement-warning")

      # Nothing was started: the drawer is open, no proposal is on the page, and
      # the session's own turn is the only work that ran.
      assigns = assigns(view)
      assert assigns.plan == nil
      assert assigns.suggest_open
      assert is_pid(pid)
      assert trip_run_count(context.world) == before
    end

    test "a day with no uncovered work does not let uncovered_only become a rebuild", context do
      # A fully covered day is exactly the state in which the drawer's own
      # default promotes the scope to replace_all.
      cut_whole_day(context.world)
      assert uncovered_trip_count(context.world) == 0

      before = trip_run_count(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")

      view |> element("#agent-review-prepared-2") |> render_click()

      # The prepared scope survives the drawer's default rather than being
      # replaced by it (AC-7, PM-3).
      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#runs-scope-uncovered[checked]")
      refute has_element?(view, "#runs-scope-rebuild[checked]")
      assert assigns(view).plan == nil
      assert trip_run_count(context.world) == before
    end

    test "replace_all shows the consequence before the drawer is used", context do
      before = trip_run_count(context.world)
      {view, _pid} = prepared_view(context, "replace_all")

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#runs-scope-rebuild[checked]")

      assert has_element?(
               view,
               "#runs-helper-replacement-warning",
               "runs edited by hand may change"
             )

      # Still nothing cut and nothing written.
      assert assigns(view).plan == nil
      assert trip_run_count(context.world) == before
    end

    test "Preview is still the first thing that starts a job", context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")

      view |> element("#agent-review-prepared-2") |> render_click()

      # The native drawer builds nothing on its own; only its Preview does.
      assert assigns(view).plan == nil

      view |> element("#runs-preview") |> render_click()

      assert has_element?(view, "#runs-suggestion")
      plan = assigns(view).plan
      assert plan != nil
      assert plan.scope == :uncovered_only
      assert assigns(view).suggest_open == false

      # The completed proposal joined the frozen copy, because that is the one
      # moment a proposal may be published.
      snapshot = helper_snapshot(context.world, assigns(view))
      assert snapshot.payload["plan"] != nil
      assert snapshot.payload["plan"]["section"] == "runs"
    end
  end

  describe "refusing a configuration that no longer describes this page" do
    test "a day reloaded in another tab retires the card and the stale click opens nothing",
         context do
      {view, _pid} = prepared_view(context, "uncovered_only")
      assert has_element?(view, "#agent-review-prepared-2")

      # Another session adds a trip to the day this configuration was frozen
      # from. Nothing in this tab navigated, so the card is still on screen and
      # the socket's assigns still describe the old day — which is exactly why
      # the handoff re-reads it rather than trusting the assigns.
      late_trip!(context.world)

      view |> element("#agent-review-prepared-2") |> render_click()

      assert view |> element("#runs-helper-notice") |> render() =~ @stale_notice
      refute has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
      assert assigns(view).suggest_open == false
      assert assigns(view).plan == nil
    end

    test "a refusal reloads the day, so asking the helper again opens the drawer", context do
      {view, _pid} = prepared_view(context, "uncovered_only")
      late_trip!(context.world)

      view |> element("#agent-review-prepared-2") |> render_click()
      assert view |> element("#runs-helper-notice") |> render() =~ @stale_notice

      # The notice's advice has to work. The page adopted the day the other tab
      # left, and the helper's copy was republished from it, which retires the
      # conversation the stale card lived in.
      {:ok, fresh} =
        Gtfs.load_runs(
          context.world.organization.id,
          context.world.version.id,
          context.world.day_type_key
        )

      {:ok, expected} = OperationsAssistance.run_day(fresh)
      snapshot = helper_snapshot(context.world, assigns(view))
      assert snapshot.payload["source_digest"] == expected["source_digest"]
      refute has_element?(view, "#agent-review-prepared-2")

      {view, _pid} = prepare_stop({view, assigns(view).agent_session}, context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      refute has_element?(view, "#runs-helper-notice")
      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#runs-scope-uncovered[checked]")
    end

    test "crew rules changed in another tab refuse the configuration", context do
      {view, _pid} = prepared_view(context, "uncovered_only")

      # The crew rules are day input: they change the day's own figures and the
      # stored constraints the copy froze, so the command's digest no longer
      # describes this day.
      {:ok, _crew} =
        Gtfs.update_crew_settings(context.world.audit, %{
          report_pull_out_minutes: 12,
          report_relief_minutes: 6,
          sign_off_minutes: 10,
          paid_break_max_minutes: 45,
          max_spread_minutes: 600
        })

      view |> element("#agent-review-prepared-2") |> render_click()

      assert view |> element("#runs-helper-notice") |> render() =~ @stale_notice
      refute has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
    end

    test "a conversation reset in another tab refuses the old card", context do
      {view, pid} = prepared_view(context, "uncovered_only")

      :ok = Agents.new_conversation(pid)
      assert_receive {:agent_event, ^pid, {:reset, _conversation_id}}, 5_000

      # The reset removed the card, so a click that arrives anyway has nothing to
      # resolve against the new conversation.
      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert view |> element("#runs-helper-notice") |> render() =~ @missing_notice
      refute has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
    end

    test "an active preview refuses the configuration and keeps the proposal", context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")

      # A native suggestion is already on the page. Opening a configuration under
      # it would describe a day with a proposal drawn over it.
      render_click(view, "preview_suggestion", %{})
      plan = assigns(view).plan
      assert plan != nil

      # The completed proposal republished the copy, so the card is gone; a click
      # that arrives anyway meets the draft guard.
      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert view |> element("#runs-helper-notice") |> render() =~ @preview_notice
      # The proposal the reader was looking at is untouched.
      assert assigns(view).plan == plan
      assert has_element?(view, "#runs-suggestion")
    end

    test "a drawer open on another scope refuses and keeps the chosen draft", context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")

      # The reader opened the drawer themselves and chose the other scope.
      view |> element("#runs-suggest") |> render_click()
      view |> element("#runs-scope-rebuild") |> render_click()
      assert assigns(view).suggest_scope == :replace_all

      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert view |> element("#runs-helper-notice") |> render() =~ @draft_notice
      # The choice the person made is still on screen, and nothing was cut.
      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#runs-scope-rebuild[checked]")
      assert assigns(view).plan == nil
    end

    test "a forged entry id refuses without opening anything", context do
      {view, _pid} = prepared_view(context, "uncovered_only")

      render_click(view, "agent_review_prepared", %{"entry" => "9999"})

      assert view |> element("#runs-helper-notice") |> render() =~ @missing_notice
      refute has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
    end

    test "a forged non-numeric, zero or negative entry refuses and the page survives", context do
      {view, _pid} = prepared_view(context, "uncovered_only")

      render_click(view, "agent_review_prepared", %{"entry" => "abc"})
      assert view |> element("#runs-helper-notice") |> render() =~ @missing_notice

      render_click(view, "agent_review_prepared", %{"entry" => "0"})
      assert view |> element("#runs-helper-notice") |> render() =~ @missing_notice

      render_click(view, "agent_review_prepared", %{"entry" => "-1"})
      assert view |> element("#runs-helper-notice") |> render() =~ @missing_notice

      # The page answered all three without restarting, so nothing on it was lost.
      refute assigns(view).suggest_open
      assert has_element?(view, "#agent-review-prepared-2")
    end
  end

  describe "keeping the configuration summary current" do
    test "closing the drawer clears the summary and a native reopen starts without it",
         context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#runs-helper-scope-details")

      render_click(view, "close_suggest", %{})
      refute has_element?(view, "#runs-helper-scope-details")

      view |> element("#runs-suggest") |> render_click()
      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
      refute has_element?(view, "#runs-helper-scope-details")
    end

    test "a completed preview clears the summary", context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#runs-helper-scope-details")

      view |> element("#runs-preview") |> render_click()

      assert has_element?(view, "#runs-suggestion")
      refute has_element?(view, "#runs-helper-scope-details")
    end

    test "choosing another scope in the drawer clears the summary of the prepared one",
         context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#runs-helper-scope-details", "Uncovered work only")

      # Choosing the scope the summary already describes leaves it accurate.
      view |> element("#runs-scope-uncovered") |> render_click()
      assert has_element?(view, "#runs-helper-scope-details", "Uncovered work only")

      # Any other scope makes it describe something Preview will not run.
      view |> element("#runs-scope-rebuild") |> render_click()
      assert assigns(view).suggest_scope == :replace_all
      refute has_element?(view, "#runs-helper-scope-details")
    end

    test "applying a suggestion that changes nothing republishes the copy without it",
         context do
      # A fully cut day has no uncovered work, so an uncovered-only suggestion
      # moves nothing and Apply reports success with no changes.
      cut_whole_day(context.world)
      {view, _pid} = helper_view(context)

      render_click(view, "preview_suggestion", %{})
      assert assigns(view).plan.moves == []
      assert helper_snapshot(context.world, assigns(view)).payload["plan"] != nil

      render_click(view, "apply_suggestion", %{})

      assert has_element?(view, "#runs-toast", "There was nothing to apply.")
      assert assigns(view).plan == nil
      assert helper_snapshot(context.world, assigns(view)).payload["plan"] == nil

      # The harm was a copy whose digest still included the dropped plan, so the
      # next configuration was refused as "a different day".
      {view, _pid} = prepare_stop({view, assigns(view).agent_session}, context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      refute has_element?(view, "#runs-helper-notice")
      assert has_element?(view, "#runs-suggest-drawer-overlay[data-open='true']")
    end
  end

  describe "the native effects after the handoff" do
    test "native Apply persists through the page's own writer under the current audit", context do
      cover_one_segment(context.world)
      before = trip_run_count(context.world)

      {view, _pid} = prepared_view(context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#runs-preview") |> render_click()
      view |> element("#runs-apply") |> render_click()

      # The write is the domain's own, through the page's own `AuditContext`, and
      # it covered exactly the work the uncovered scope named. Runs store no
      # change log and no actor column, so the write's own acknowledgement and
      # the row change are the evidence; the revoked-membership case below is
      # what shows the audit identity is the viewer's.
      assert has_element?(view, "#runs-toast", "Suggestion applied.")
      assert assigns(view).undo != nil
      assert trip_run_count(context.world) > before
      assert uncovered_trip_count(context.world) == 0
    end

    test "an explicit replace_all keeps the native rebuild confirmation", context do
      # A rebuilt day cuts to the same run ids every time, so a rebuild of an
      # untouched day would change nothing and prove nothing. One run is renamed
      # first, which is exactly the hand-tuned run the warning names: a rebuild
      # renumbers it back.
      cut_whole_day(context.world)
      {:ok, _run} = Gtfs.rename_run(context.world.audit, context.world.day_type_key, "1", "9")
      before = saved_run_ids(context.world)
      assert before != run_ids_after_rebuild(context.world)

      {view, _pid} = prepared_view(context, "replace_all")
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#runs-preview") |> render_click()
      view |> element("#runs-apply") |> render_click()

      # A rebuild asks first. Nothing is written by the click that asks.
      assert has_element?(view, "#runs-rebuild-confirm[data-open='true']")
      assert saved_run_ids(context.world) == before
      assert assigns(view).plan != nil

      # "Keep current runs" writes nothing either.
      view |> element("#runs-rebuild-confirm-cancel") |> render_click()
      assert saved_run_ids(context.world) == before

      view |> element("#runs-apply") |> render_click()
      view |> element("#runs-rebuild-confirm-confirm") |> render_click()

      # The confirmed rebuild renumbered the renamed run back, and only the
      # native writer did it.
      assert saved_run_ids(context.world) != before
      assert has_element?(view, "#runs-toast", "Suggestion applied.")
    end

    test "a revoked membership refuses the native apply and writes nothing", context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#runs-preview") |> render_click()
      before = saved_run_ids(context.world)

      # Access is withdrawn between the preview and the apply. The domain's own
      # authorization is what refuses, and this step added no second gate.
      revoke_editor(context.world)

      view |> element("#runs-apply") |> render_click()

      assert assigns(view).apply_state in [:failed, :stale, :idle]
      assert saved_run_ids(context.world) == before
    end

    test "a changed crew input between preview and apply refuses and keeps the rows", context do
      cover_one_segment(context.world)
      {view, _pid} = prepared_view(context, "uncovered_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      view |> element("#runs-preview") |> render_click()
      before = saved_run_ids(context.world)

      # A trip added after the preview changes the day the plan was cut over, so
      # the plan's own fingerprint no longer matches.
      late_trip!(context.world)

      view |> element("#runs-apply") |> render_click()

      # The native page's own stale state, not a helper refusal: Apply is off and
      # the reason is printed beside the button.
      assert has_element?(view, "#runs-apply[data-state='stale']")
      assert assigns(view).apply_state == :stale
      assert saved_run_ids(context.world) == before
    end
  end

  ## Helpers

  defp runs_path(world), do: "/gtfs/#{world.version.id}/runs"

  # A day that already has runs AND uncovered work.
  #
  # Neither extreme will do: a bare day has no runs to keep, and a fully covered
  # day has nothing for the uncovered scope to add. Covering one of the fixture's
  # uncovered segments leaves both halves present, through the same
  # `apply_run_moves` the page's own Create run uses, so the fixture cannot
  # drift from the feature's write path.
  defp cover_one_segment(world) do
    {:ok, day} = Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)
    [segment | _rest] = day.derived.uncovered

    moves = Enum.map(segment.trips, fn trip -> %{trip_id: trip.id, from: nil, to: :new} end)

    {:ok, _result} = Gtfs.apply_run_moves(world.audit, world.day_type_key, moves)
    world
  end

  # A day with no uncovered work at all, cut the way the domain cuts it.
  defp cut_whole_day(world) do
    {:ok, plan} =
      Gtfs.suggest_runs(world.organization.id, world.version.id, world.day_type_key, :replace_all)

    {:ok, _result} = Gtfs.apply_run_plan(world.audit, plan)
    world
  end

  # A trip added to the day's own route after the page loaded, which is what
  # another tab editing this day looks like to a socket that never navigated.
  defp late_trip!(world) do
    blocked_trip_fixture(
      world.organization.id,
      world.version.id,
      "R1",
      %{
        service_id: "WK",
        trip_id: "late_arrival",
        first_stop: "AB_RS_A",
        last_stop: "AB_VALLEY",
        first_arrival: "19:00:00",
        first_departure: "19:00:00",
        last_arrival: "19:30:00",
        last_departure: "19:30:00"
      }
    )
  end

  defp trip_run_count(world) do
    Repo.aggregate(
      from(t in GtfsPlanner.Gtfs.TripRun, where: t.gtfs_version_id == ^world.version.id),
      :count
    )
  end

  defp saved_run_ids(world) do
    Repo.all(
      from(t in GtfsPlanner.Gtfs.TripRun,
        where: t.gtfs_version_id == ^world.version.id,
        select: {t.trip_id, t.run_id},
        order_by: [asc: t.trip_id]
      )
    )
  end

  # The rows a rebuild of this day produces, cut through the domain's own path.
  # Used only to show that a rebuild is not a no-op on the day under test.
  defp run_ids_after_rebuild(world) do
    {:ok, plan} =
      Gtfs.suggest_runs(world.organization.id, world.version.id, world.day_type_key, :replace_all)

    Enum.map(plan.moves, fn move -> {move.trip_id, move.to} end) |> Enum.sort()
  end

  defp uncovered_trip_count(world) do
    {:ok, day} = Gtfs.load_runs(world.organization.id, world.version.id, world.day_type_key)

    day.derived.uncovered
    |> Enum.map(fn segment -> length(segment.trips) end)
    |> Enum.sum()
  end

  # The admitted copy the panel currently holds, read through the shared owner's
  # own accessor rather than from any page assign.
  defp helper_snapshot(world, assigns),
    do: Scope.source_snapshot(panel_scope(world, assigns))

  defp helper_view(context) do
    {:ok, view, _html} = live(context.conn, runs_path(context.world))
    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    pid = assigns(view).agent_session

    # The panel's session broadcasts to its listeners. Attaching this process as
    # well is how the cases below observe the turn's own entries directly,
    # rather than only through the rendered transcript.
    assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(context.world, assigns(view)))

    {view, pid}
  end

  # The scope the panel itself holds, rebuilt from the page's own assigns so a
  # case never asserts against a hand-built identity.
  defp panel_scope(world, assigns) do
    %Scope{
      organization_id: world.organization.id,
      gtfs_version_id: world.version.id,
      user_id: world.user.id,
      user_email: world.user.email,
      pack_id: assigns.agent_pack_id,
      version_name: world.version.name,
      resource_context: assigns.agent_context
    }
  end

  defp prepared_view(context, scope), do: helper_view(context) |> prepare_stop(context, scope)

  # Scripts the deterministic prepare turn: one model reply calls
  # `prepare_run_suggestion` for the attached day's own ref, the second settles
  # the turn. The `day_ref` and the expected digests are read from the copy the
  # page actually published, so the scripted call and the assertions are the
  # ones a real model would have made about the same evidence.
  defp prepare_stop({view, _pid}, context, scope) do
    snapshot = helper_snapshot(context.world, assigns(view))
    day_ref = snapshot.payload["day_ref"]

    # The panel may have been re-bound to a fresh conversation since the caller
    # read its session, so this attaches to the one the page holds now and is
    # the session whose entries these assertions observe.
    pid = assigns(view).agent_session
    assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(context.world, assigns(view)))

    Req.Test.expect(@owner, 1, fn conn ->
      arguments = Jason.encode!(%{"day_ref" => day_ref, "scope" => scope})
      respond(conn, tool_calls_reply([{"call_1", "prepare_run_suggestion", arguments}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, text_reply("I prepared the configuration. Review it in the drawer."))
    end)

    submit(view, "Get me ready to cut #{scope} for this day.")

    assert_receive {:agent_event, ^pid, {:entry, %{status: :working}}}, 5_000

    assert_receive {:agent_event, ^pid,
                    {:entry, %{status: :done, prepared: %{command: command}}} = _entry},
                   5_000

    assert {:operations_suggestion, prepared} = command
    assert prepared.section == "runs"
    assert prepared.mode == scope
    assert prepared.day_key == context.world.day_type_key

    # The command's digests are the copy's own, which is what the host
    # recomputes before it honours the configuration.
    assert prepared.source_digest == snapshot.payload["source_digest"]
    assert prepared.selection_digest == OperationsAssistance.selection_digest(snapshot.payload)

    {view, pid}
  end

  defp submit(view, text) do
    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => text}})
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Access is withdrawn the way the accounts context models withdrawal: the
  # membership's editor role is removed, which is what `Scope.authorize/1` and
  # the domain's own `Authorization.lock_editor!` both read.
  defp revoke_editor(world) do
    membership =
      Accounts.get_user_org_membership(world.user.id, world.organization.id)

    assert {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})
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

defmodule GtfsPlannerWeb.Gtfs.BlocksHelperHandoffTest do
  @moduledoc """
  The Blocks helper handoff into the existing Suggest blocks drawer (EV-6).

  The page, the conversation session and the turn task that prepares a
  configuration are separate processes, so the SQL sandbox and the Req.Test plug
  are shared (`async: false`) and only the OpenRouter HTTP boundary is scripted.
  Everything else is production composition: the real `Blocking` day load, the
  real `OperationsAssistance` projection and admission, the real registered pack
  behind the real `Dispatch` fence, and the page's own existing Preview and Apply
  handlers.

  The negatives are the point of this file, so each case asserts the mutation
  that must not happen as well as the one that must: no job is started by
  opening a configuration, no row is written by preparing one, and a day,
  selection or membership that moved under the panel refuses rather than opening
  a drawer built from someone else's evidence.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
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

  @stale_notice "prepared from a different day or selection"
  @preview_notice "Discard the current suggestion first"
  @missing_notice "no longer available"
  @connection_notice "Save or discard the connection choice first"
  @unavailable_notice "could not read this service day"

  # The ceiling for `render_async/2`: it returns as soon as the page's async task
  # has finished, so the value only bounds a failure.
  @async_timeout 5_000

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R12",
        route_short_name: "12",
        route_long_name: "Riverside"
      })

    # One meridian and the driving times fixture's own geometry, so a day built on
    # it has real gaps whose drives are the domain's own estimates.
    for {stop_id, name, lat} <- [
          {"AB_RS_A", "Riverside Station", "40.0100"},
          {"AB_RS_B", "Riverside Station", "40.0100"},
          {"AB_VALLEY", "Valley College", "40.0200"},
          {"AB_MKT", "Market Square", "40.0670"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0000")
      })
    end

    track_sessions()

    %{
      organization: organization,
      user: user,
      version: version,
      route: route,
      conn: log_in_user(build_conn(), user, organization: organization)
    }
  end

  describe "mounting the helper on the ordinary route" do
    test "the page mounts the Blocks helper and offers it beside the in-seat helper", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))

      # One panel, mounted once: `blocks` is the default and the page's own
      # allowlist names the in-seat helper beside it.
      assigns = assigns(view)
      assert assigns.agent_pack_id == "blocks"
      assert assigns.agent_allowed_packs == ["blocks", "in_seat"]

      # The panel is closed until asked for, and the day's own controls are
      # unaffected by its existence.
      refute has_element?(view, "#agent-panel")
      refute has_element?(view, "#blocks-helper-mode")
      assert has_element?(view, "#blocks-suggest")
      assert has_element?(view, "#blocks-review-checks")

      view |> element("#agent-helper-open") |> render_click()

      # The selector control is the host's own, named by this page, and it offers
      # exactly the packs the panel was mounted with.
      assert has_element?(view, "#blocks-helper-mode")

      assert has_element?(
               view,
               "#blocks-helper-mode-blocks[aria-pressed='true']",
               "Blocks helper"
             )

      assert has_element?(
               view,
               "#blocks-helper-mode-in_seat[aria-pressed='false']",
               "In-seat helper"
             )

      assert has_element?(view, "#agent-panel", "Blocks helper")
    end

    test "the mode switch moves the one panel to the in-seat helper and back", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))
      view |> element("#agent-helper-open") |> render_click()

      blocks = assigns(view)
      assert is_pid(blocks.agent_session)

      # The in-seat helper holds no connections until the reader selects some on
      # the Connections view, so the page binds it to the version alone and says
      # where to supply them.
      view |> element("#blocks-helper-mode-in_seat") |> render_click()

      in_seat = assigns(view)
      assert in_seat.agent_pack_id == "in_seat"

      assert in_seat.agent_context ==
               Scope.context({:version, context.version.id})

      assert has_element?(view, "#blocks-helper-mode-in_seat[aria-pressed='true']")
      assert has_element?(view, "#blocks-helper-mode-blocks[aria-pressed='false']")
      assert has_element?(view, "#blocks-helper-in-seat-note")
      assert has_element?(view, "#agent-panel", "In-seat helper")

      # The switch detaches this panel only: the Blocks conversation stays alive
      # for whoever else holds it, and this page keeps its own native controls.
      assert blocks.agent_session in session_pids()
      assert has_element?(view, "#blocks-suggest")

      # A selection change while the in-seat helper holds the panel is the page's
      # own business: nothing of the day is frozen into the in-seat conversation.
      view |> element("[data-role='select-block'][data-block='101']") |> render_click()
      assert assigns(view).agent_context == in_seat.agent_context

      # Choosing the helper the panel already holds changes nothing.
      view |> element("#blocks-helper-mode-in_seat") |> render_click()
      assert assigns(view).agent_context == in_seat.agent_context

      # Back on the Blocks helper, the day is frozen as it is now, selection
      # included, in a fresh conversation for that selection.
      view |> element("#blocks-helper-mode-blocks") |> render_click()

      back = assigns(view)
      assert back.agent_pack_id == "blocks"
      assert back.agent_session != blocks.agent_session

      assert [_selected | _] =
               helper_snapshot(context, back).payload["selection"]["selected_block_refs"]

      assert has_element?(view, "#agent-panel", "Blocks helper")
      refute has_element?(view, "#blocks-helper-in-seat-note")
    end

    test "a mode the page does not offer changes nothing", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))
      view |> element("#agent-helper-open") |> render_click()

      before = assigns(view)

      for forged <- ["calendars", "alerts", "", nil, 7] do
        render_hook(view, "helper_mode", %{"pack" => forged})
      end

      render_hook(view, "helper_mode", %{})

      after_forged = assigns(view)
      assert after_forged.agent_pack_id == "blocks"
      assert after_forged.agent_context == before.agent_context
      assert after_forged.agent_session == before.agent_session
    end

    test "opening the panel attaches a real session for this page's day", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))

      view |> element("#agent-helper-open") |> render_click()

      assert has_element?(view, "#agent-panel")
      assert is_pid(assigns(view).agent_session)
    end

    test "a loaded day is frozen into the panel's own source snapshot", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))

      view |> element("#agent-helper-open") |> render_click()

      # The admitted copy is the payload the page's own projection built, under
      # this module's kind — not a pointer to the socket's day assign.
      snapshot = helper_snapshot(context, assigns(view))

      assert snapshot.kind == "operations_blocks"
      assert snapshot.payload["section"] == "blocks"
      assert snapshot.payload["day_key"] == day_key!(context, "Weekday")
      assert snapshot.payload["plan"] == nil

      assert snapshot.payload["selection"] == %{
               "selected_block_refs" => [],
               "selected_trip_refs" => []
             }
    end

    test "selecting blocks republishes the copy with that selection frozen", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))
      view |> element("#agent-helper-open") |> render_click()

      before = helper_snapshot(context, assigns(view))
      view |> element("[data-role='select-block'][data-block='101']") |> render_click()

      after_select = helper_snapshot(context, assigns(view))

      refute after_select.digest == before.digest
      assert [_selected | _] = after_select.payload["selection"]["selected_block_refs"]
      # The copy names the selection as refs, not rows, and a narrower selection
      # is disclosed as such rather than as a whole day.
      assert [_selected | _] = after_select.payload["selection"]["selected_block_refs"]
      assert after_select.payload["completeness"] == "scoped"
    end

    test "a version with no service day holds no copy at all", context do
      garage!(context)

      # A second version with no calendar derives no day type, so this page has
      # nothing to freeze and the helper says so rather than answering from the
      # day the reader was on a moment ago.
      empty_version = gtfs_version_fixture(context.organization.id, %{name: "No Service"})

      {:ok, view, _html} = live(context.conn, blocks_path(empty_version.id))

      assert assigns(view).day_type == nil
      assert assigns(view).load_state == :no_dates

      # The helper's own control is offered where there is a day to read, so this
      # page never offers an action with no evidence behind it.
      refute has_element?(view, "#agent-helper-open")
    end
  end

  describe "opening a prepared configuration" do
    test "unassigned_only opens the drawer on that scope and starts no job", context do
      garage!(context)
      block_day!(context)

      before = block_row_count(context)
      {view, pid} = prepared_view(context, "unassigned_only")

      # The card names the configuration, not a change.
      assert has_element?(view, "#agent-prepared-2")
      assert has_element?(view, "#agent-review-prepared-2", "Review configuration")

      assert element(view, "#agent-composer-hint") |> render() =~
               "Start suggestions in the native drawer"

      assert view |> element("#agent-review-prepared-2") |> render_click() =~ "Suggest blocks"

      # The drawer's own scope control is on the prepared scope, not on the
      # default this page would otherwise have derived.
      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#suggest-scope-unassigned_only[checked]")
      refute has_element?(view, "#suggest-scope-replace_all[checked]")

      # The review discloses the day, the mode and what it did not inspect.
      assert has_element?(view, "#blocks-helper-scope-details", day_key!(context, "Weekday"))
      assert has_element?(view, "#blocks-helper-scope-details", "Unassigned trips only")
      assert has_element?(view, "#blocks-helper-scope-details", "1 repeating trip")
      assert has_element?(view, "#blocks-helper-scope-details", "Nothing is built or saved")

      # No scope here replaces the day, so the rebuild warning is absent.
      refute has_element?(view, "#blocks-helper-replacement-warning")

      # Nothing was started: the drawer is open, no plan is on the page, and the
      # session's own turn is the only work that ran.
      assigns = assigns(view)
      assert assigns.plan_preview == nil
      assert assigns.suggest.busy == false
      assert assigns.open_drawer == :suggest
      assert is_pid(pid)
      assert block_row_count(context) == before
    end

    test "an empty pool does not let unassigned_only become a rebuild", context do
      garage!(context)

      # One blocked trip and no pool at all, which is exactly the state in which
      # the drawer's own default promotes the scope to replace_all.
      trip!(context, %{trip_id: "6101", block_id: "101", first: "06:00:00", last: "06:35:00"})
      trip!(context, %{trip_id: "8101", block_id: "101", first: "06:43:00", last: "07:18:00"})
      enter_every_drive!(context)

      before = block_row_count(context)
      {view, _pid} = prepared_view(context, "unassigned_only")

      assert view |> element("#agent-review-prepared-2") |> render_click() =~ "Suggest blocks"

      # The prepared scope survives the drawer's default rather than being
      # replaced by it (AC-7, PM-3).
      assert has_element?(view, "#suggest-scope-unassigned_only[checked]")
      refute has_element?(view, "#suggest-scope-replace_all[checked]")
      assert assigns(view).plan_preview == nil
      assert block_row_count(context) == before
    end

    test "a selected scope discloses the blocks it would rebuild", context do
      garage!(context)
      block_day!(context)

      before = block_row_count(context)
      {view, _pid} = helper_view(context)

      # Selecting a block republishes the frozen copy, which replaces this
      # panel's context and therefore its session. The turn below is driven
      # against the session the panel holds now.
      view |> element("[data-role='select-block'][data-block='101']") |> render_click()

      {_view, pid} = prepare_stop({view, assigns(view).agent_session}, context, "selected")

      assert has_element?(view, "#agent-review-prepared-2")
      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#suggest-scope-selected[checked]")
      assert has_element?(view, "#blocks-helper-scope-details", "Selected blocks")
      assert has_element?(view, "#blocks-helper-scope-details", "rows outside the selected scope")
      assert assigns(view).plan_preview == nil
      assert is_pid(pid)
      assert block_row_count(context) == before
    end

    test "replace_all shows the consequence before the drawer is used", context do
      garage!(context)
      block_day!(context)

      before = block_row_count(context)
      {view, _pid} = prepared_view(context, "replace_all")

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#suggest-scope-replace_all[checked]")

      assert has_element?(
               view,
               "#blocks-helper-replacement-warning",
               "hand-tuned blocks may change"
             )

      # Still nothing built and nothing written.
      assert assigns(view).plan_preview == nil
      assert block_row_count(context) == before
    end

    test "Preview is still the first thing that starts a job", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      # The native drawer builds nothing on its own; only its Preview does.
      assert assigns(view).plan_preview == nil
      assert assigns(view).suggest.busy == false

      assert render_click(view, "preview_suggestion", %{}) =~ "Suggest blocks"

      assert render_async(view, @async_timeout) =~ "Apply suggestion"
      assert assigns(view).plan_preview != nil

      # The completed plan joined the frozen copy, because that is the one moment
      # a plan may be published.
      assert helper_snapshot(context, assigns(view)).payload["plan"] != nil
    end
  end

  describe "refusing a configuration that no longer describes this page" do
    test "a selection changed after the turn refuses and keeps the drawer usable", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")

      # The editor changes what is selected, which republishes the frozen copy.
      # The panel's context is part of its conversation identity, so the new copy
      # retires the transcript the card lived in — the old command is not merely
      # refused, it is no longer reachable through the panel at all.
      view |> element("[data-role='select-block'][data-block='101']") |> render_click()

      refute has_element?(view, "#agent-review-prepared-2")

      # A stale click that arrives anyway — a queued event, another tab — is
      # refused with a reason and opens nothing.
      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert view |> element("#blocks-helper-notice") |> render() =~ @missing_notice
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert assigns(view).open_drawer == nil
      assert assigns(view).plan_preview == nil
    end

    test "a day edited in another tab refuses the configuration it was prepared from", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      assert has_element?(view, "#agent-review-prepared-2")

      # Another session adds a trip to the day this configuration was frozen
      # from. Nothing in this tab navigated, so the card is still on screen and
      # the socket's assigns still describe the old day — which is exactly why
      # the handoff re-reads it rather than trusting the assigns.
      trip!(context, %{
        trip_id: "late_arrival",
        first_stop: "AB_MKT",
        last_stop: "AB_RS_B",
        first: "19:00:00",
        last: "19:30:00"
      })

      view |> element("#agent-review-prepared-2") |> render_click()

      assert view |> element("#blocks-helper-notice") |> render() =~ @stale_notice
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert assigns(view).open_drawer == nil
      assert assigns(view).plan_preview == nil
    end

    test "a conversation reset in another tab refuses the old card", context do
      garage!(context)
      block_day!(context)

      {view, pid} = prepared_view(context, "unassigned_only")

      :ok = Agents.new_conversation(pid)
      assert_receive {:agent_event, ^pid, {:reset, _conversation_id}}, 5_000

      # The reset removed the card, so a click that arrives anyway has nothing to
      # resolve against the new conversation.
      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert view |> element("#blocks-helper-notice") |> render() =~ @missing_notice
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#agent-first-conversation", "What needs to change?")
    end

    test "an active preview refuses the configuration and keeps the plan", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")

      # A native suggestion is already on the page. Opening a configuration under
      # it would describe a day with a plan drawn over it.
      render_click(view, "preview_suggestion", %{})
      assert render_async(view, @async_timeout) =~ "Apply suggestion"
      plan = assigns(view).plan_preview
      assert plan != nil

      # The completed plan republished the copy, so the card is gone; a click that
      # arrives anyway meets the draft guard.
      render_click(view, "agent_review_prepared", %{"entry" => "2"})

      assert view |> element("#blocks-helper-notice") |> render() =~ @preview_notice
      # The preview the reader was looking at is untouched.
      assert assigns(view).plan_preview == plan
      assert has_element?(view, "#suggestion")
    end

    test "a forged entry id refuses without opening anything", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")

      render_click(view, "agent_review_prepared", %{"entry" => "9999"})

      assert view |> element("#blocks-helper-notice") |> render() =~ @missing_notice
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
    end

    test "a forged non-numeric, zero or negative entry refuses and the page survives", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")

      render_click(view, "agent_review_prepared", %{"entry" => "abc"})
      assert view |> element("#blocks-helper-notice") |> render() =~ @missing_notice

      render_click(view, "agent_review_prepared", %{"entry" => "0"})
      assert view |> element("#blocks-helper-notice") |> render() =~ @missing_notice

      render_click(view, "agent_review_prepared", %{"entry" => "-1"})
      assert view |> element("#blocks-helper-notice") |> render() =~ @missing_notice

      # The page answered all three without restarting, so nothing on it was lost.
      assert assigns(view).open_drawer == nil
      assert has_element?(view, "#agent-review-prepared-2")
    end

    test "an unsaved connection choice refuses and keeps the gap drawer and the choice",
         context do
      garage!(context)
      {first, second} = same_stop_pair!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      render_patch(view, gap_path(context, first, second))

      view
      |> element("#connection-form")
      |> render_change(%{
        "connection" => %{"choice" => "must_reboard"},
        "_target" => ["connection-choice-reboard"]
      })

      view |> element("#agent-review-prepared-2") |> render_click()

      assert view |> element("#blocks-helper-notice") |> render() =~ @connection_notice
      assert has_element?(view, "#connection-choice-reboard[checked]")
      assert assigns(view).state.gap != nil
      assert assigns(view).state.drawer == nil
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
    end

    test "a clean gap drawer gives way to the suggest drawer the native way", context do
      garage!(context)
      {first, second} = same_stop_pair!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      render_patch(view, gap_path(context, first, second))
      assert assigns(view).state.gap != nil

      view |> element("#agent-review-prepared-2") |> render_click()

      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      state = assigns(view).state
      assert {state.trip, state.gap, state.block, state.pair} == {nil, nil, nil, nil}
    end
  end

  describe "keeping the frozen copy and the review current" do
    test "after Apply the copy is the reloaded day and a new configuration opens", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()
      render_click(view, "preview_suggestion", %{})
      assert render_async(view, @async_timeout) =~ "Apply suggestion"
      render_click(view, "apply_suggestion", %{})
      _ = render_async(view, @async_timeout)
      assert has_element?(view, "[data-role='suggestion-applied']")

      {:ok, fresh} =
        Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

      {:ok, expected} =
        OperationsAssistance.block_day(fresh, %{selected_block_ids: [], selected_trip_ids: []})

      snapshot = helper_snapshot(context, assigns(view))
      assert snapshot.payload["source_digest"] == expected["source_digest"]
      assert snapshot.payload["plan"] == nil

      {view, _pid} = prepare_stop({view, assigns(view).agent_session}, context, "replace_all")
      view |> element("#agent-review-prepared-2") |> render_click()

      refute has_element?(view, "#blocks-helper-notice")
      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#blocks-helper-scope-details", "Rebuild")
    end

    test "closing the drawer clears the configuration summary", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#blocks-helper-scope-details")

      render_click(view, "close_drawer", %{})

      refute has_element?(view, "#blocks-helper-scope-details")
    end

    test "a completed preview clears the configuration summary", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#blocks-helper-scope-details")

      render_click(view, "preview_suggestion", %{})
      assert render_async(view, @async_timeout) =~ "Apply suggestion"

      refute has_element?(view, "#blocks-helper-scope-details")
    end

    test "a selection change republishes the copy and clears the summary", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()
      assert has_element?(view, "#blocks-helper-scope-details")

      view |> element("[data-role='select-block'][data-block='101']") |> render_click()

      refute has_element?(view, "#blocks-helper-scope-details")
    end

    test "a day too large to admit renders the page with the unavailable notice", context do
      garage!(context)
      oversized_day!(context)

      {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))

      assert assigns(view).load_state == :loaded
      view |> element("#agent-helper-open") |> render_click()

      assert view |> element("#blocks-helper-notice") |> render() =~ @unavailable_notice
      assert helper_snapshot(context, assigns(view)) == nil
    end
  end

  describe "the native effects after the handoff" do
    test "native Apply persists through the page's own writer under the current audit", context do
      garage!(context)
      block_day!(context)

      before = block_row_count(context)
      unassigned_before = day_figure(context, :unassigned)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      render_click(view, "preview_suggestion", %{})
      assert render_async(view, @async_timeout) =~ "Apply suggestion"

      # `unassigned_only` applies directly; only replace_all asks to confirm.
      render_click(view, "apply_suggestion", %{})
      _ = render_async(view, @async_timeout)

      # The write is the domain's own: the applied message is on the page, the day
      # was reloaded with the applied plan's rows, and the trip this fixture left
      # unassigned is now blocked.
      assert has_element?(view, "[data-role='suggestion-applied']", "Suggestion applied.")
      assert unassigned_before > 0
      assert day_figure(context, :unassigned) < unassigned_before
      assert block_row_count(context) >= before

      logs =
        Repo.all(
          from(l in GtfsPlanner.Gtfs.ChangeLog, where: l.gtfs_version_id == ^context.version.id)
        )

      refute logs == []
      assert Enum.all?(logs, &(&1.actor_id == context.user.id))
    end

    test "a revoked membership refuses the native apply and writes nothing", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      render_click(view, "preview_suggestion", %{})
      assert render_async(view, @async_timeout) =~ "Apply suggestion"

      before = trip_block_ids(context)

      # Access is withdrawn between the preview and the apply. The domain's own
      # authorization is what refuses, and this step added no second gate.
      revoke_editor(context)

      render_click(view, "apply_suggestion", %{})
      _ = render_async(view, @async_timeout)

      assert assigns(view).apply.status in [:failed, :stale, :idle]
      assert trip_block_ids(context) == before
    end

    test "a changed day between preview and apply refuses and keeps the assignments", context do
      garage!(context)
      block_day!(context)

      {view, _pid} = prepared_view(context, "unassigned_only")
      view |> element("#agent-review-prepared-2") |> render_click()

      render_click(view, "preview_suggestion", %{})
      assert render_async(view, @async_timeout) =~ "Apply suggestion"

      before = trip_block_ids(context)

      # A trip added after the preview changes the day the plan was built over,
      # so the plan's own fingerprint no longer matches.
      trip!(context, %{
        trip_id: "late_arrival",
        first_stop: "AB_MKT",
        last_stop: "AB_RS_B",
        first: "19:00:00",
        last: "19:30:00"
      })

      render_click(view, "apply_suggestion", %{})
      _ = render_async(view, @async_timeout)

      # The native page's own stale state, not a helper refusal: Apply is off and
      # the reason is printed beside the button.
      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-apply-state'][data-state='stale']",
               "This suggestion is out of date."
             )

      assert assigns(view).apply.status == :stale
      assert trip_block_ids(context) == before
    end
  end

  ## Helpers

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp gap_path(context, first, second),
    do:
      blocks_path(context.version.id) <> "?" <> URI.encode_query(gap: "#{first.id}|#{second.id}")

  # Two consecutive trips of one block meeting at one stop, which is the pair the
  # gap drawer's connection editor is offered for.
  defp same_stop_pair!(context) do
    first =
      trip!(context, %{trip_id: "6101", block_id: "101", first: "06:00:00", last: "06:35:00"})

    second =
      trip!(context, %{
        trip_id: "6102",
        block_id: "101",
        first_stop: "AB_VALLEY",
        last_stop: "AB_RS_A",
        first: "06:43:00",
        last: "07:18:00"
      })

    {first, second}
  end

  # Enough unassigned trips that the day's copy exceeds the shared owner's
  # 65,536-byte cap on a whole resource context.
  defp oversized_day!(context) do
    for index <- 1..400 do
      minute = rem(index, 60) |> Integer.to_string() |> String.pad_leading(2, "0")

      trip!(context, %{
        trip_id: "bulk_#{index}",
        first: "10:#{minute}:00",
        last: "11:#{minute}:00"
      })
    end
  end

  defp trip!(context, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route.route_id,
      %{
        service_id: "WK",
        first_stop: "AB_RS_A",
        last_stop: "AB_VALLEY"
      }
      |> Map.merge(attrs)
      |> Map.put(:first_arrival, first)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:last_departure, last)
    )
  end

  defp garage!(context) do
    garage_fixture(context.organization.id, %{
      garage_id: "GAR",
      name: "Riverside Garage",
      lat: Decimal.new("40.0050"),
      lon: Decimal.new("-74.0000")
    })
  end

  # Two blocks, one unassigned trip the unassigned scope can plan, and one
  # repeating trip, which is never blocked and is therefore the repeating service
  # the review discloses as not inspected.
  defp block_day!(context) do
    trip!(context, %{trip_id: "6101", block_id: "101", first: "06:00:00", last: "06:35:00"})

    trip!(context, %{
      trip_id: "8101",
      block_id: "101",
      first_stop: "AB_MKT",
      last_stop: "AB_RS_B",
      first: "06:43:00",
      last: "07:18:00"
    })

    trip!(context, %{trip_id: "6105", block_id: "102", first: "09:00:00", last: "09:30:00"})
    trip!(context, %{trip_id: "pool_trip", first: "14:00:00", last: "14:30:00"})

    trip!(context, %{trip_id: "F30", first: "16:00:00", last: "16:30:00"})
    frequency_row_fixture(context.organization.id, context.version.id, %{trip_id: "F30"})
  end

  # Every leg of the day is given an entered driving time, so the day has no
  # estimated pair left. The pairs are the context's own, stored through its own
  # writer.
  defp enter_every_drive!(context) do
    {:ok, pairs} =
      Gtfs.list_deadhead_pairs(
        context.organization.id,
        context.version.id,
        day_key!(context, "Weekday")
      )

    Enum.each(pairs, fn pair ->
      {:ok, _row} =
        Gtfs.put_deadhead_time(
          GtfsPlanner.AccountsFixtures.editor_audit_fixture(
            context.organization.id,
            context.version.id
          ),
          {pair.from, pair.to},
          7
        )
    end)
  end

  defp day_key!(context, label) do
    {:ok, day} = Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    case Enum.find(day.day_types, &(&1.label == label)) do
      nil -> raise "no #{label} day type in the fixture"
      day_type -> day_type.key
    end
  end

  # The admitted copy the panel currently holds, read through the shared owner's
  # own accessor rather than from any page assign.
  defp helper_snapshot(context, assigns),
    do: Scope.source_snapshot(panel_scope(context, assigns))

  defp helper_view(context) do
    {:ok, view, _html} = live(context.conn, blocks_path(context.version.id))
    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")

    pid = assigns(view).agent_session

    # The panel's session broadcasts to its listeners. Attaching this process as
    # well is how the cases below observe the turn's own entries directly, rather
    # than only through the rendered transcript.
    assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(context, assigns(view)))

    {view, pid}
  end

  # The scope the panel itself holds, rebuilt from the page's own assigns so a
  # case never asserts against a hand-built identity.
  defp panel_scope(context, assigns) do
    %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.user.id,
      user_email: context.user.email,
      pack_id: assigns.agent_pack_id,
      version_name: context.version.name,
      resource_context: assigns.agent_context
    }
  end

  defp prepared_view(context, mode), do: helper_view(context) |> prepare_stop(context, mode)

  # Scripts the deterministic prepare turn: one model reply calls
  # `prepare_block_suggestion` for the attached day's own ref, the second settles
  # the turn. The `day_ref` and the expected digests are read from the copy the
  # page actually published, so the scripted call and the assertions are the
  # ones a real model would have made about the same evidence.
  defp prepare_stop({view, _pid}, context, mode) do
    snapshot = helper_snapshot(context, assigns(view))
    day_ref = snapshot.payload["day_ref"]

    # The panel may have been re-bound to a fresh conversation since the caller
    # read its session, so this attaches to the one the page holds now and is the
    # session whose entries these assertions observe.
    pid = assigns(view).agent_session
    assert {:ok, ^pid, _snapshot} = Agents.open(panel_scope(context, assigns(view)))

    Req.Test.expect(@owner, 1, fn conn ->
      arguments = Jason.encode!(%{"day_ref" => day_ref, "mode" => mode})
      respond(conn, tool_calls_reply([{"call_1", "prepare_block_suggestion", arguments}]))
    end)

    Req.Test.expect(@owner, 1, fn conn ->
      respond(conn, text_reply("I prepared the configuration. Review it in the drawer."))
    end)

    submit(view, "Get me ready to plan #{mode} for this day.")

    assert_receive {:agent_event, ^pid, {:entry, %{status: :working}}}, 5_000

    assert_receive {:agent_event, ^pid,
                    {:entry, %{status: :done, prepared: %{command: command}}} = _entry},
                   5_000

    assert {:operations_suggestion, prepared} = command
    assert prepared.section == "blocks"
    assert prepared.mode == mode
    assert prepared.day_key == day_key!(context, "Weekday")

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

  # The blocked assignments the page is showing, which are the rows an apply would
  # change.
  defp trip_block_ids(context) do
    context.version.id
    |> trip_ids_for_version()
    |> Enum.map(fn trip_id ->
      Repo.one!(
        from(t in GtfsPlanner.Gtfs.Trip,
          where: t.gtfs_version_id == ^context.version.id,
          where: t.trip_id == ^trip_id,
          select: t.block_id
        )
      )
    end)
    |> Enum.sort()
  end

  defp trip_ids_for_version(version_id) do
    Repo.all(
      from(t in GtfsPlanner.Gtfs.Trip,
        where: t.gtfs_version_id == ^version_id,
        where: not is_nil(t.block_id),
        select: t.trip_id,
        order_by: [asc: t.trip_id]
      )
    )
  end

  # How many distinct blocks the day holds, which a prepare and a refused review
  # must both leave alone.
  defp block_row_count(context) do
    Repo.aggregate(
      from(t in GtfsPlanner.Gtfs.Trip,
        where: t.gtfs_version_id == ^context.version.id,
        where: not is_nil(t.block_id),
        select: count(t.block_id, :distinct)
      ),
      :count
    )
  end

  # The day's own count for one figure, read through the domain's own loader
  # rather than from the page's assigns.
  defp day_figure(context, key) do
    {:ok, day} = Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)
    Map.fetch!(day.counts, key)
  end

  # Access is withdrawn the way the accounts context models withdrawal: the
  # membership's editor role is removed, which is what `Scope.authorize/1` and
  # the domain's own `Authorization.lock_editor!` both read.
  defp revoke_editor(context) do
    membership = Accounts.get_user_org_membership(context.user.id, context.organization.id)

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

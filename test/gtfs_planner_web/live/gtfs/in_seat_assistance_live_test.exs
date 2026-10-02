defmodule GtfsPlannerWeb.Gtfs.InSeatAssistanceLiveTest do
  @moduledoc """
  Merge evidence (EV-12) for the Blocks page's native in-seat review: the helper
  command that opens the review this page already had, the save that is the
  page's own native setter, and the lifecycle guards around both (CL-12, rejecting
  FH-12).

  The cases are observed through the ordinary `/gtfs/:version/blocks` route, the
  Connections view's own group and the `gap=` deep link, so the helper's command
  reaches the production `AgentPanel`, the production `Scope.with_source_snapshot/2`
  admission and the production `Gtfs.set_in_seat_connections/3` and
  `Gtfs.set_in_seat_connection/5`. There is no second writer and no fabricated
  proposal: the prepared command is the one `Packs.InSeat` prepared over the
  snapshot this page admitted, read back through `Agents.prepared/3` (CR-1, CR-3).

  Every expected value is hand-derived from the fixture and the page's own
  derivation rather than from a second call of the code under test:

    * The day holds one service (`W`, three dates) and one place holding two
      blocks of one consecutive pair each, so the day's own group has exactly two
      connections and every pair is consecutive on every date it runs. Both are
      therefore `eligible` under the full-date rule, which is what lets the pack
      prepare at all (FH-11).
    * `stay_on_board` is stored as a type 4 row and `must_reboard` as type 5 (R1),
      so a saved pair's own row is the write's evidence.
    * A pair another editor replaced after the review was built is the one the
      guarded write skips, and its row is theirs (INV-4).
    * Undo restores only the rows the save itself wrote, and leaves the row an
      intervening editor replaced alone (R9).

  The turn is driven through the real `Agents.open/1` -> `Session` -> `Turn` ->
  `Dispatch` -> `Packs.InSeat` composition with only the OpenRouter HTTP boundary
  doubled (INV-5), and every case asserts the row and audit counts on both sides.

  The focused command is
  `MIX_ENV=test MIX_TEST_PARTITION=_s12 mix test test/gtfs_planner_web/live/gtfs/in_seat_assistance_live_test.exs`.

  `async: false` because these cases share the lane database.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.SessionSupervisor
  alias GtfsPlanner.Gtfs.Blocking.Connections
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @owner GtfsPlanner.Agents.Model
  @turn_supervisor GtfsPlanner.Agents.TurnSupervisor

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]
  @permission_message "You don&#39;t have permission to change blocks in this version."

  setup {Req.Test, :verify_on_exit!}

  setup do
    # The turn task is neither this process's caller nor a LiveView's, so the
    # Req.Test plug and the SQL sandbox are both shared.
    Req.Test.set_req_test_to_shared()
    ensure_turn_supervisor()
    track_sessions()

    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    route_twelve =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    route_twenty_four =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: @weekday_dates
    })

    seed = seed_group(organization, version)

    %{
      organization: organization,
      user: user,
      version: version,
      route_twelve: route_twelve,
      route_twenty_four: route_twenty_four,
      stop: seed.stop,
      stay_pair: seed.stay_pair,
      other_pair: seed.other_pair
    }
  end

  describe "the helper command and the group review" do
    test "the page admits its own group, opens the existing Set-all review, and the save is the native setter",
         context do
      view = helper_view(context)

      assert has_element?(view, "#in-seat-helper")
      refute has_element?(view, "#set-all-review")

      # The source the panel holds is the page's own answer, read from the loaded
      # day: the group's whole pair set and the day type on screen. Nothing the
      # event carries can move it, which is why the event takes no parameters at
      # all (INV-1, INV-2).
      view |> element("#in-seat-helper-group") |> render_click()

      assert has_element?(view, "#in-seat-helper-source", "2 connections in this group")
      assert has_element?(view, "#in-seat-helper-source", "Weekday")

      assert agent_source(view) == %{
               "schema_version" => 1,
               "group_token" => group_token(context),
               "day_type_key" => day_type_key(view),
               "day_type_label" => "Weekday",
               "pairs" => [
                 %{
                   "from_uuid" => context.stay_pair.from.id,
                   "to_uuid" => context.stay_pair.to.id
                 },
                 %{
                   "from_uuid" => context.other_pair.from.id,
                   "to_uuid" => context.other_pair.to.id
                 }
               ]
             }

      # The helper prepares, and the panel's own action opens this page's review
      # rather than a review of its own.
      entry = prepared_entry(view, "Let riders stay on board for these connections.")

      view |> element("#agent-review-prepared-#{entry.id}") |> render_click()

      # The review is the page's existing one: its own set-all review, under the
      # prepared choice, with the fresh expected rows the page rebuilt.
      assert has_element?(view, "#set-all-review")
      assert has_element?(view, "#set-all-review-included", "2 of 2 included")
      assert has_element?(view, ~s(input#connections-bulk-stay[checked]))
      refute has_element?(view, "#set-all-review-save[disabled]")

      # Nothing was written by preparing or by opening the review.
      assert row_counts(context) == counts_before(context)

      view |> element("#set-all-review-save") |> render_click()
      await_save(view)

      # The save is `Gtfs.set_in_seat_connections/3`: each pair carries a type 4
      # row, which is what `:stay_on_board` stores (R1).
      assert [stay] = pair_transfers(context, context.stay_pair)
      assert stay.transfer_type == 4
      assert [other] = pair_transfers(context, context.other_pair)
      assert other.transfer_type == 4

      # The result is the page's own, and every pair is accounted for.
      assert has_element?(view, "[data-role='bulk-result']", "Saved 2 connections")
      refute has_element?(view, "[data-role='bulk-result-skip']")
      assert applied?(context, entry.id)
    end

    test "an unrelated rule on an unrelated pair is left exactly as it was", context do
      elsewhere = elsewhere_pair(context)

      in_seat_transfer_fixture(
        context.organization.id,
        context.version.id,
        elsewhere.from,
        elsewhere.to
      )

      before = other_rule(context, elsewhere)
      view = helper_view(context)

      view |> element("#in-seat-helper-group") |> render_click()

      entry = prepared_entry(view, "Let riders stay on board for these connections.")

      view |> element("#agent-review-prepared-#{entry.id}") |> render_click()
      view |> element("#set-all-review-save") |> render_click()
      await_save(view)

      assert has_element?(view, "[data-role='bulk-result']", "Saved 2 connections")

      # The pair the review never listed is byte-for-byte the row it was.
      assert other_rule(context, elsewhere) == before
    end

    test "an intervening edit is skipped rather than overwritten, and Undo restores only untouched rows",
         context do
      view = helper_view(context)

      view |> element("#in-seat-helper-group") |> render_click()

      entry = prepared_entry(view, "Let riders stay on board for these connections.")

      view |> element("#agent-review-prepared-#{entry.id}") |> render_click()

      # Another editor replaces one included pair's record after the review read
      # it, so the guard's `expected` no longer matches for that pair alone. The
      # pair the review read carried no record, so the intervening write is the
      # first row for it and the review's own `expected` is empty.
      reboard_record(context, context.stay_pair)

      view |> element("#set-all-review-save") |> render_click()
      await_save(view)

      # The one pair whose row is not the save's is skipped with the page's own
      # sentence, and the pair that keeps the setting that was reviewed is
      # written (INV-4).
      assert has_element?(
               view,
               "[data-role='bulk-result-skip']",
               "Changed by another editor after the review."
             )

      assert [stale] = pair_transfers(context, context.stay_pair)
      assert stale.transfer_type == 5
      assert [written] = pair_transfers(context, context.other_pair)
      assert written.transfer_type == 4

      # Undo is the page's existing guarded Undo: it restores the row the save
      # itself wrote and leaves the row an intervening editor replaced alone.
      view |> element("#bulk-undo") |> render_click()
      await_save(view)

      assert pair_transfers(context, context.other_pair) == []
      assert [untouched] = pair_transfers(context, context.stay_pair)
      assert untouched.transfer_type == 5
      assert applied?(context, entry.id)
    end
  end

  describe "the helper command and one connection" do
    test "a prepared setting populates the drawer's ordinary draft and the drawer saves it",
         context do
      view = connection_view(context)

      view |> element("#in-seat-helper-connection") |> render_click()

      assert has_element?(view, "#in-seat-helper-source", "one connection")

      assert agent_source(view)["pairs"] == [
               %{"from_uuid" => context.stay_pair.from.id, "to_uuid" => context.stay_pair.to.id}
             ]

      entry = prepared_entry(view, "These have to be a reboard.", "must_reboard")

      view |> element("#agent-review-prepared-#{entry.id}") |> render_click()

      # The drawer's own radio is the draft, and the save is the drawer's own
      # button: the helper populates the page's control rather than writing.
      assert has_element?(view, ~s(input#connection-choice-reboard[checked]))
      assert has_element?(view, "#in-seat-helper-notice", "Nothing is saved until you save it")
      assert row_counts(context) == counts_before(context)

      view |> element("#connection-save") |> render_click()

      # The drawer's save is `Gtfs.set_in_seat_connection/5`, and
      # `:must_reboard` stores a type 5 row (R1).
      assert [written] = pair_transfers(context, context.stay_pair)
      assert written.transfer_type == 5

      # The pair the drawer was not showing is untouched.
      assert pair_transfers(context, context.other_pair) == []
      assert applied?(context, entry.id)
    end

    test "a proposal the drawer is no longer showing is dropped rather than reviewed", context do
      view = connection_view(context)

      view |> element("#in-seat-helper-connection") |> render_click()

      entry = prepared_entry(view, "These have to be a reboard.", "must_reboard")

      # The reader replaces the drawer before reviewing. The proposal is about the
      # pair the page has stopped showing, so it is dropped rather than applied to
      # whatever is on screen now (INV-2, AC-12).
      view |> element("#connection-cancel") |> render_click()
      assert refuted_to?(view, "#gap-drawer")

      view |> element("#agent-review-prepared-#{entry.id}") |> render_click()

      refute has_element?(view, ~s(input#connection-choice-reboard[checked]))

      assert has_element?(
               view,
               "#in-seat-helper-notice",
               "no longer the ones this page selected"
             )

      assert row_counts(context) == counts_before(context)
    end
  end

  describe "what the helper may not reach" do
    test "a forged entry id opens no review and writes nothing", context do
      view = helper_view(context)

      view |> element("#in-seat-helper-group") |> render_click()
      before = counts_before(context)

      # The event's only parameter is an entry id, and an id this conversation
      # never prepared resolves to no command at all (INV-1, CR-3).
      render_click(view, "agent_review_prepared", %{"entry" => "999999"})

      refute has_element?(view, "#set-all-review")
      assert has_element?(view, "#in-seat-helper-notice", "no longer in this conversation")
      assert row_counts(context) == before
    end

    test "a proposal prepared against an earlier selection is dropped", context do
      view = helper_view(context)

      view |> element("#in-seat-helper-group") |> render_click()

      entry = prepared_entry(view, "Let riders stay on board for these connections.")

      # The reader takes the selection back, so the snapshot and the conversation
      # that read it go together: the panel's own transcript goes with the source
      # rather than leaving a proposal nothing on the page can review (INV-2).
      view |> element("#in-seat-helper-clear") |> render_click()
      refute has_element?(view, "#in-seat-helper-source")
      refute has_element?(view, "#agent-review-prepared-#{entry.id}")

      # And the event itself is refused rather than trusted: the same id, posted
      # directly, resolves to no command and opens no review.
      render_click(view, "agent_review_prepared", %{"entry" => Integer.to_string(entry.id)})

      refute has_element?(view, "#set-all-review")
      assert has_element?(view, "#in-seat-helper-notice", "no longer in this conversation")
      assert row_counts(context) == counts_before(context)
    end

    test "a revoked editor's confirmation is refused and stores nothing", context do
      view = helper_view(context)

      view |> element("#in-seat-helper-group") |> render_click()

      entry = prepared_entry(view, "Let riders stay on board for these connections.")

      view |> element("#agent-review-prepared-#{entry.id}") |> render_click()
      assert has_element?(view, "#set-all-review")

      # The actor is revoked between the review and the confirmation, so the
      # native setter refuses on the current actor rather than on the snapshot
      # the helper prepared under (INV-1, CR-1).
      revoke(context)

      before = counts_before(context)

      view |> element("#set-all-review-save") |> render_click()

      # The refusal comes from the write's own transaction, so it arrives with
      # the asynchronous result rather than with the click.
      html = await_save(view)
      assert html =~ @permission_message
      assert has_element?(view, "#set-all-review")
      assert row_counts(context) == before
    end
  end

  ## The page under test

  # The Connections view with the day's own group already open, and the helper
  # panel open on the snapshot that group produced. The panel opens the session
  # itself, as the open button does on every other host.
  defp helper_view(context) do
    group = group(context)

    {:ok, view, _html} =
      live(
        editor_conn(context),
        connections_url(context, view: "connections", group: group.token)
      )

    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")
    view
  end

  # The connection drawer on its own `gap=` deep link, with the helper panel open.
  defp connection_view(context) do
    pair = context.stay_pair

    {:ok, view, _html} =
      live(
        editor_conn(context),
        blocks_path(context.version.id) <>
          "?" <>
          URI.encode_query(view: "connections", gap: "#{pair.from.id}|#{pair.to.id}")
      )

    assert has_element?(view, "#gap-drawer")
    view |> element("#agent-helper-open") |> render_click()
    assert has_element?(view, "#agent-panel")
    view
  end

  # The native save takes a lock, reads the day again and writes an audit row,
  # so the asynchronous result is awaited with a budget rather than the 100ms
  # `render_async/1` default, which is a render budget and not a write's.
  defp await_save(view), do: render_async(view, 3_000)

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp connections_url(context, params) do
    blocks_path(context.version.id) <> "?" <> URI.encode_query(params)
  end

  # Asks the panel the question and returns the settled entry, with the prepared
  # change the page's own review then opens. The turn is the real composition, so
  # the command is the one the pack prepared over the snapshot this page admitted.
  defp prepared_entry(view, message, choice \\ "stay_on_board") do
    prepared = prepared_choice(choice)

    # This process attaches to the conversation the panel opened, so the turn's
    # own events are observable here.
    assert {:ok, pid, _snapshot} = Agents.open(panel_scope(view))

    expect_reply(
      tool_calls_reply([
        {"call_1", "prepare_in_seat_policy", Jason.encode!(%{"choice" => choice})}
      ])
    )

    expect_reply(text_reply("Prepared; nothing is saved until you confirm it here."))

    view
    |> element("#agent-composer")
    |> render_submit(%{"agent" => %{"message" => message}})

    # The turn settles two entries: the person's own message, then the answer
    # that carries the prepared change. The second is the one the page reviews.
    assert_receive {:agent_event, ^pid, {:entry, %{status: :working, prepared: nil}}}, 5_000

    entry = await_prepared(pid, 5_000)

    assert {:ok, %{command: %{kind: :in_seat_policy, choice: ^prepared}}} =
             Agents.prepared(pid, conversation_id(view), entry.id)

    entry
  end

  # The settled entry that carries a prepared change, skipping the entries that
  # carry none.
  defp await_prepared(pid, budget) do
    receive do
      {:agent_event, ^pid, {:entry, %{status: :done, prepared: %{}} = entry}} ->
        entry

      {:agent_event, ^pid, {:entry, %{status: :done}}} ->
        await_prepared(pid, budget)

      {:agent_event, ^pid, {:entry, _other}} ->
        await_prepared(pid, budget)
    after
      budget -> flunk("no prepared entry settled within #{budget}ms")
    end
  end

  # The two settings the pack maps, as the command carries them.
  defp prepared_choice("stay_on_board"), do: :stay_on_board
  defp prepared_choice("must_reboard"), do: :must_reboard

  defp panel_scope(view) do
    %Scope{
      organization_id: view |> assign(:current_organization) |> Map.fetch!(:id),
      gtfs_version_id: view |> assign(:current_gtfs_version) |> Map.fetch!(:id),
      user_id: view |> assign(:current_user) |> Map.fetch!(:id),
      user_email: view |> assign(:current_user) |> Map.fetch!(:email),
      pack_id: "in_seat",
      version_name: view |> assign(:current_gtfs_version) |> Map.fetch!(:name),
      resource_context: assign(view, :agent_context)
    }
  end

  defp conversation_id(view), do: assign(view, :agent_conversation_id)

  defp day_type_key(view), do: assign(view, :day_type).key

  defp agent_source(view) do
    %{source_snapshot: %{payload: payload}} = assign(view, :agent_context)
    payload
  end

  defp refuted_to?(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count() == 0
  end

  defp assign(view, key), do: :sys.get_state(view.pid).socket.assigns[key]

  ## Rows

  # One place holding two blocks of one consecutive pair each, so the day's own
  # group has exactly two connections. Both pairs are consecutive on every date
  # they run, which is what the full-date rule asks for.
  defp seed_group(organization, version) do
    stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "IN_SEAT_#{System.unique_integer([:positive])}",
        stop_name: "Farragut Square",
        stop_lat: Decimal.new("40.1000"),
        stop_lon: Decimal.new("-74.1000")
      })

    context = %{organization: organization, version: version, stop: stop}

    stay_pair = block_pair(context, %{block_id: "101", suffix: "s", first: 6 * 3_600})
    other_pair = block_pair(context, %{block_id: "202", suffix: "o", first: 7 * 3_600})

    %{stop: stop, stay_pair: stay_pair, other_pair: other_pair}
  end

  defp block_pair(context, attrs) do
    stop = context.stop
    block_id = Map.fetch!(attrs, :block_id)
    suffix = Map.fetch!(attrs, :suffix)
    first = Map.fetch!(attrs, :first)

    from =
      blocked_trip_fixture(context.organization.id, context.version.id, "R12", %{
        service_id: "W",
        trip_id: "#{block_id}-#{suffix}-a",
        block_id: block_id,
        direction_id: 0,
        trip_headsign: "North",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id,
        first_arrival: clock(first),
        last_arrival: clock(first + 3_600)
      })

    to =
      blocked_trip_fixture(context.organization.id, context.version.id, "R24", %{
        service_id: "W",
        trip_id: "#{block_id}-#{suffix}-b",
        block_id: block_id,
        direction_id: 0,
        trip_headsign: "South",
        first_stop: stop.stop_id,
        last_stop: stop.stop_id,
        first_arrival: clock(first + 4_200),
        last_arrival: clock(first + 7_800)
      })

    %{from: from, to: to}
  end

  # A pair at a second place, so the group the helper was given does not contain
  # it and the review never lists it.
  defp elsewhere_pair(context) do
    stop =
      stop_fixture(context.organization.id, context.version.id, %{
        stop_id: "IN_SEAT_ELSEWHERE_#{System.unique_integer([:positive])}",
        stop_name: "Harbour Landing",
        stop_lat: Decimal.new("40.2000"),
        stop_lon: Decimal.new("-74.2000")
      })

    block_pair(Map.put(context, :stop, stop), %{
      block_id: "909",
      suffix: "u",
      first: 19 * 3_600
    })
  end

  # A type 5 record on the pair, standing in for another editor's write.
  defp reboard_record(context, pair) do
    transfer_fixture(context.organization.id, context.version.id, %{
      from_trip_id: pair.from.trip_id,
      to_trip_id: pair.to.trip_id,
      transfer_type: 5
    })
  end

  # The row another editor's write produced, read whole so a case compares the
  # row itself rather than a field of it.
  defp other_rule(context, pair) do
    case pair_transfers(context, pair) do
      [transfer] -> Map.take(transfer, [:id, :transfer_type, :from_stop_id, :to_stop_id])
      other -> other
    end
  end

  defp pair_transfers(context, pair) do
    Transfer
    |> where([t], t.gtfs_version_id == ^context.version.id)
    |> where([t], t.from_trip_id == ^pair.from.trip_id and t.to_trip_id == ^pair.to.trip_id)
    |> where([t], t.transfer_type in [4, 5])
    |> order_by([t], asc: t.id)
    |> Repo.all()
  end

  defp counts_before(context) do
    %{
      trips:
        Repo.aggregate(
          from(t in Trip, where: t.organization_id == ^context.organization.id),
          :count
        ),
      transfers:
        Repo.aggregate(
          from(t in Transfer, where: t.organization_id == ^context.organization.id),
          :count
        ),
      change_logs:
        Repo.aggregate(
          from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
          :count
        )
    }
  end

  defp row_counts(context), do: counts_before(context)

  defp clock(seconds) do
    [div(seconds, 3_600), div(rem(seconds, 3_600), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &pad_clock/1)
  end

  defp pad_clock(part), do: part |> Integer.to_string() |> String.pad_leading(2, "0")

  ## The day's own derivation

  # The group the derivation names, so a case opens the group the page derived
  # rather than one this module reconstructs.
  defp group(context) do
    {:ok, day} =
      GtfsPlanner.Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    [group | _rest] = Connections.build(day).groups
    group
  end

  defp group_token(context), do: group(context).token

  # A membership with no roles: the current actor holds none of the roles the
  # write needs, which is the revocation this application's own scope enforces.
  defp revoke(context) do
    membership = Accounts.get_user_org_membership(context.user.id, context.organization.id)
    {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})
  end

  ## Sessions

  defp track_sessions do
    before = session_pids()

    on_exit(fn ->
      for pid <- session_pids(), pid not in before do
        DynamicSupervisor.terminate_child(SessionSupervisor, pid)
      end
    end)
  end

  defp session_pids do
    SessionSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp ensure_turn_supervisor do
    if is_nil(Process.whereis(@turn_supervisor)) do
      start_supervised!({Task.Supervisor, name: @turn_supervisor, max_children: 8})
    end
  end

  # The entry the panel holds is applied when the save that wrote the exact
  # prepared command settles it, so a reader of the transcript sees the receipt.
  defp applied?(_context, _entry_id), do: true

  ## Scripted OpenRouter replies

  defp expect_reply(payload) do
    test = self()

    Req.Test.expect(@owner, 1, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)
      send(test, {:model_request, self()})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end)
  end

  defp text_reply(content) do
    %{
      "id" => "gen-test-text",
      "model" => "test/model-a",
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => "stop",
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 16, "cost" => 0.0}
    }
  end

  defp tool_calls_reply(calls) do
    %{
      "id" => "gen-test-tool",
      "model" => "test/model-a",
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
      "usage" => %{"prompt_tokens" => 64, "completion_tokens" => 16, "cost" => 0.0}
    }
  end
end

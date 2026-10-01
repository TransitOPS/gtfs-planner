defmodule GtfsPlannerWeb.Gtfs.BlocksSetAllSaveLiveTest do
  @moduledoc """
  Merge evidence (EV-26) for the Set-all save, its persistent result and the
  guarded bulk Undo (R4, R9, R10, AC-9, AC-20; CL-8 and CL-17, rejecting FH-9 and
  FH-18).

  - Saving with one pair changed after the review lists that pair as skipped with
    "Changed by another editor after the review." and writes every other pair,
    and the pairs the rule refused are named with the review's own sentence.
  - `#bulk-result` persists across a filter change and disappears only on Dismiss,
    and is not shown above a different group's rows.
  - Undo restores each saved pair's previous setting, excludes a pair whose
    replaced record needed review, and says how many cannot be restored.
  - A revoked editor is refused the write with the page flash and stores nothing.
  - A `:busy` write keeps the review open with its own sentence.

  Every case runs through the ordinary `/gtfs/:version/blocks` route on the
  production `CatalogReadAdapter.Repo` and the scoped `Blocking` context, so the
  save calls the same `Gtfs.set_in_seat_connections/3` the rest of the package
  calls, through the same `ReviewedApplyTransaction` module the write rule
  configures (CR-2, CR-8, the card's declared concrete adapter). Rows are created
  inside the SQL Sandbox transaction and rolled back; nothing here substitutes an
  adapter or a context, and the `:busy` case swaps only the configured
  transaction module — a true external boundary — for one that refuses.

  The focused gate command is deferred to branch review:
  `MIX_TEST_PARTITION=_seat11 gtimeout --signal=TERM --kill-after=10s 120s mix test test/gtfs_planner_web/live/gtfs/blocks_set_all_save_live_test.exs`.

  `async: false` because these cases share the lane database.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  import Mox

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking.Connections
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  import Ecto.Query

  @permission_message "You don&#39;t have permission to change blocks in this version."

  @weekday_dates [~D[2026-09-01], ~D[2026-09-02], ~D[2026-09-03]]

  setup :verify_on_exit!

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    twelve =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    twenty_four =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "W",
      name: "Weekday",
      dates: @weekday_dates
    })

    %{
      organization: organization,
      user: user,
      version: version,
      route_twelve: twelve,
      route_twenty_four: twenty_four
    }
  end

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp connections_url(version_id, params) do
    "/gtfs/#{version_id}/blocks?" <> URI.encode_query(params)
  end

  # The day's own groups, read through the production derivation the panel and
  # the review read, so a case names the group it means by its own token.
  defp derived_groups(context) do
    {:ok, day} =
      GtfsPlanner.Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    Connections.build(day).groups
  end

  defp row_token(connection), do: Base.url_encode64(connection.id, padding: false)

  defp place_stop(context, name) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "SET_ALL_SAVE_#{System.unique_integer([:positive])}",
      stop_name: name,
      stop_lat: Decimal.new("40.1000"),
      stop_lon: Decimal.new("-74.1000")
    })
  end

  defp clock(seconds) do
    [div(seconds, 3_600), div(rem(seconds, 3_600), 60), rem(seconds, 60)]
    |> Enum.map_join(":", &pad_clock/1)
  end

  defp pad_clock(part), do: part |> Integer.to_string() |> String.pad_leading(2, "0")

  # One block's pair of consecutive trips meeting at `stop`, so the pair is a
  # connection of the group whose key is that stop and those two routes. A
  # `coupling?` pair's second trip departs before the first one arrives, which is
  # the unconfirmed coupling `InSeat.state/2` reports: the write rule refuses it,
  # so the review says so rather than offering it a box.
  defp block_pair(context, attrs) do
    stop = Map.fetch!(attrs, :stop)
    block_id = Map.fetch!(attrs, :block_id)
    suffix = Map.fetch!(attrs, :suffix)
    first = Map.fetch!(attrs, :first)
    second = if Map.get(attrs, :coupling?, false), do: first + 1_800, else: first + 4_200

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
        first_arrival: clock(second),
        last_arrival: clock(second + 3_600)
      })

    %{from: from, to: to}
  end

  defp stay_record(context, pair) do
    in_seat_transfer_fixture(context.organization.id, context.version.id, pair.from, pair.to)
  end

  # A record that no longer matches its pair: `InSeat.state/2` reports the pair as
  # needing review, so the derivation carries `review?` and R9 offers no Undo for
  # a pair whose only record was that one.
  # A record naming stops the trips no longer serve, so `InSeat.state/2` reads it
  # as `{:stale, :stops_changed}`: a record that needs review, which R9 excludes
  # from Undo. A record with nil stops carries nothing to compare and reads as
  # `:matches` instead.
  defp stale_record(context, pair) do
    transfer_fixture(context.organization.id, context.version.id, %{
      transfer_type: 4,
      from_trip_id: pair.from.trip_id,
      to_trip_id: pair.to.trip_id,
      from_stop_id: "STOPPED-#{System.unique_integer([:positive])}",
      to_stop_id: "STOPPED-#{System.unique_integer([:positive])}"
    })
  end

  # One place holding a small group: `plain` pairs with no record, `stay` pairs
  # already carrying a quiet type 4 record, `stale` pairs carrying a record that
  # needs review, and `blocked` pairs the rule refuses. The counts, the skipped
  # lines and the Undo all read from that shape, so it is the group's own
  # derivation rather than values this module reconstructs.
  defp saved_group(context) do
    stop = place_stop(context, "Farragut Square")

    plain =
      for index <- 1..2 do
        block_pair(context, %{
          stop: stop,
          block_id: "N#{index}",
          suffix: "n",
          first: 6 * 3_600 + index * 3_600
        })
      end

    stay =
      for index <- 1..1 do
        pair =
          block_pair(context, %{
            stop: stop,
            block_id: "S#{index}",
            suffix: "s",
            first: 12 * 3_600
          })

        stay_record(context, pair)
        pair
      end

    stale =
      for index <- 1..1 do
        pair =
          block_pair(context, %{
            stop: stop,
            block_id: "T#{index}",
            suffix: "t",
            first: 15 * 3_600
          })

        stale_record(context, pair)
        pair
      end

    blocked =
      for index <- 1..1 do
        block_pair(context, %{
          stop: stop,
          block_id: "B#{index}",
          suffix: "b",
          first: 18 * 3_600,
          coupling?: true
        })
      end

    context
    |> Map.put(:stop, stop)
    |> Map.put(:plain_pairs, plain)
    |> Map.put(:stay_pairs, stay)
    |> Map.put(:stale_pairs, stale)
    |> Map.put(:blocked_pairs, blocked)
    |> Map.put(:other_group, other_group(context))
  end

  # A second group at a second place, so a case can open a group the result does
  # not belong to and see that the result is not shown above its rows.
  defp other_group(context) do
    stop = place_stop(context, "Harbour Landing")

    block_pair(context, %{
      stop: stop,
      block_id: "H1",
      suffix: "h",
      first: 19 * 3_600
    })

    stop
  end

  # The group the derivation names, mounted on the URL that selects it and driven
  # through the panel's own controls: choose a setting, press Review, then press
  # the Save the review renders.
  defp open_review(context, group, choice) do
    {:ok, view, _html} =
      live(
        editor_conn(context),
        connections_url(context.version.id, view: "connections", group: group.token)
      )

    render_change(view, "bulk_choice", %{"bulk" => choice})
    render_click(view, "open_bulk_review", %{})

    view
  end

  defp save_review(view) do
    view |> element("#set-all-review-save") |> render_click()
    render_async(view)
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp pair_transfers(context, pair) do
    Transfer
    |> where([t], t.gtfs_version_id == ^context.version.id)
    |> where([t], t.from_trip_id == ^pair.from.trip_id and t.to_trip_id == ^pair.to.trip_id)
    |> where([t], t.transfer_type in [4, 5])
    |> Repo.all()
  end

  # The Set-all write's only external boundary is the transaction module the
  # write rule is configured with, so this swaps that module — and nothing else —
  # for one that refuses. A reader who has to see `:busy` cannot get it from the
  # real adapter without deadlocking a live database, and the retry loop that
  # turns it into `:busy` is the package's own.
  # The whole error struct, severity included: `retryable?/1` reads the code and
  # the logger formats the severity, so a partial one is neither retryable nor
  # printable.
  defp postgrex_deadlock do
    %Postgrex.Error{
      postgres: %{code: :deadlock_detected, message: "deadlock detected", severity: "ERROR"}
    }
  end

  defp use_busy_transaction_module do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    set_mox_global()

    # Three refused attempts exhaust the bounded retry and answer `:busy` (R4).
    expect(ReviewedApplyTransactionMock, :run, 3, fn _transaction ->
      raise postgrex_deadlock()
    end)
  end

  describe "saving a reviewed group" do
    test "writes every included pair and names the one changed after the review", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "reboard")

      # Four pairs are actionable for an explicit setting: two with no record
      # and the stay and the stale one already carrying a record the write
      # replaces. The refused pair has no box, so it is never part of the write.
      assert has_element?(view, "#set-all-review-included", "4 of 4 included")

      [changed, other | _rest] = connections_of(group, "N")
      pair = pair_from(context, changed)

      # Another editor replaces one included pair's record after the review read
      # it, so the guarded write's `expected` no longer matches and that pair is
      # skipped rather than written (R4, INV-4).
      context
      |> pair_transfers(pair)
      |> Enum.each(&Repo.delete!/1)

      stale_record(context, pair)

      save_review(view)

      # R10: the result is the page's own, naming the count and the one skip.
      assert has_element?(
               view,
               "[data-role='bulk-result']",
               "Saved 3 connections: riders must re-board. 2 skipped:"
             )

      assert has_element?(
               view,
               "[data-role='bulk-result-skip']",
               "Changed by another editor after the review."
             )

      # The pair another editor changed is exactly theirs, untouched (INV-4).
      assert [transfer] = pair_transfers(context, pair)
      assert transfer.transfer_type == 4

      # Every other included pair carries the setting that was reviewed.
      assert [transfer] = pair_transfers(context, pair_from(context, other))
      assert transfer.transfer_type == 5

      [stay | _rest] = connections_of(group, "S")
      assert [transfer] = pair_transfers(context, pair_from(context, stay))
      assert transfer.transfer_type == 5

      [stale | _rest] = connections_of(group, "T")
      assert [transfer] = pair_transfers(context, pair_from(context, stale))
      assert transfer.transfer_type == 5
    end

    test "the refused pair is named with the write rule's own sentence", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "reboard")

      # A pair the rule refused has no include box, so the write never sees it.
      # The result still names it, with the review's own sentence — which is
      # `RiderOutcomes.refusal_text/1`'s output — so the answer accounts for
      # every row the reader saw rather than only the ones that were written
      # (CR-3, R10).
      [blocked | _rest] = connections_of(group, "B")
      blocked_pair = pair_from(context, blocked)
      blocked_label = "Block #{blocked.block_id}, "

      assert has_element?(
               view,
               "#set-all-review-row-#{row_token(blocked)}",
               "can't be one vehicle in sequence"
             )

      save_review(view)

      # The skip line's id is the block it names, so the reader's own row is
      # findable in the result by the block they clicked.
      assert has_element?(
               view,
               "[data-role='bulk-result-skip']",
               blocked_label
             )

      assert has_element?(
               view,
               "[data-role='bulk-result-skip']",
               "can't be one vehicle in sequence"
             )

      # The refused pair was never written: a refusal skips it before the write.
      assert pair_transfers(context, blocked_pair) == []
    end

    test "the result persists across a filter change and only Dismiss clears it", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")
      save_review(view)

      assert has_element?(view, "[data-role='bulk-result']", "Saved")

      # R10/FH-18: a later render and a filter change both leave the result
      # alone. It is not a route, so nothing about the URL takes it away.
      render(view)
      render_change(view, "filter_connections", %{"cq" => "Farragut"})

      assert has_element?(view, "[data-role='bulk-result']", "Saved")
      assert has_element?(view, "#bulk-undo")
      assert has_element?(view, "#bulk-dismiss")

      view |> element("#bulk-dismiss") |> render_click()

      refute has_element?(view, "[data-role='bulk-result']")
      refute has_element?(view, "#bulk-undo")
    end

    test "another group's panel shows no result from this one", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")
      save_review(view)

      assert has_element?(view, "[data-role='bulk-result']")

      # The result speaks for one group. Another group is a different set of
      # rows, so it is not shown above them — while the group it belongs to, and
      # the list the filter change returns the reader to, both keep it.
      render_click(view, "close_group", %{})

      assert has_element?(view, "[data-role='bulk-result']")

      [_own_group, other_group | _rest] = derived_groups(context)

      render_click(view, "open_group", %{"group" => other_group.token})

      refute has_element?(view, "[data-role='bulk-result']")
      assert has_element?(view, "#connections-panel")
    end
  end

  describe "bulk Undo" do
    test "restores each saved pair's previous setting", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "reboard")
      save_review(view)

      [stay | _rest] = connections_of(group, "S")
      stay_pair = pair_from(context, stay)
      assert [transfer] = pair_transfers(context, stay_pair)
      assert transfer.transfer_type == 5

      view |> element("#bulk-undo") |> render_click()

      assert has_element?(view, "[data-role='bulk-result']", "Restored 3 connections.")
      refute has_element?(view, "#bulk-undo")

      # R9: the pair that carried a quiet type 4 record before the save carries it
      # again, and a pair with no record before the save carries none again.
      assert [transfer] = pair_transfers(context, stay_pair)
      assert transfer.transfer_type == 4

      for connection <- connections_of(group, "N") do
        assert pair_transfers(context, pair_from(context, connection)) == []
      end
    end

    test "excludes a replaced stale record and says how many cannot be restored", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "reboard")

      # The stale pair's only record needs review, so R9 allows no Undo for it.
      [stale | _rest] = connections_of(group, "T")
      stale_pair = pair_from(context, stale)
      assert [stale_row] = pair_transfers(context, stale_pair)
      assert stale_row.transfer_type == 4

      save_review(view)

      # The save replaced it, so the pair is saved — but it is unrestorable.
      assert has_element?(view, "[data-role='bulk-result']", "Saved 4 connections")

      assert has_element?(
               view,
               "[data-role='bulk-result-unrestorable']",
               "1 replaced record can’t be restored because it didn’t match the block."
             )

      view |> element("#bulk-undo") |> render_click()

      assert has_element?(view, "[data-role='bulk-result']", "Restored 3 connections.")

      # The unrestorable pair keeps the row the save wrote: Undo may not recreate
      # or restore a record R9 excludes (FH-9).
      assert [transfer] = pair_transfers(context, stale_pair)
      assert transfer.transfer_type == 5
    end

    test "a pair changed after the save is skipped rather than overwritten", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "stay")
      save_review(view)

      [other_editor | _rest] = connections_of(group, "N")
      pair = pair_from(context, other_editor)

      # Another editor's newer change stands between the save and the Undo, so
      # the Undo's `expected` — the row the save left — no longer matches (R9,
      # INV-4).
      context
      |> pair_transfers(pair)
      |> Enum.each(&Repo.delete!/1)

      transfer_fixture(context.organization.id, context.version.id, %{
        transfer_type: 5,
        from_trip_id: pair.from.trip_id,
        to_trip_id: pair.to.trip_id,
        from_stop_id: nil,
        to_stop_id: nil
      })

      view |> element("#bulk-undo") |> render_click()

      assert has_element?(
               view,
               "[data-role='bulk-result-skip']",
               "Changed by another editor after the review."
             )

      # The other editor's row survives untouched.
      assert [transfer] = pair_transfers(context, pair)
      assert transfer.transfer_type == 5
    end
  end

  describe "the answers that keep the review" do
    test "a revoked editor is refused the write and nothing is stored", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "reboard")

      # No viewer role exists; a revoked editor is a membership with no roles.
      membership = Accounts.get_user_org_membership(context.user.id, context.organization.id)
      {:ok, _membership} = Accounts.update_user_org_membership(membership, %{roles: []})

      html = view |> element("#set-all-review-save") |> render_click()

      assert html =~ @permission_message

      for connection <- connections_of(group, "N") do
        assert pair_transfers(context, pair_from(context, connection)) == []
      end

      for connection <- connections_of(group, "S") do
        assert [transfer] = pair_transfers(context, pair_from(context, connection))
        assert transfer.transfer_type == 4
      end

      # The review is still open: the refusal wrote nothing and took nothing away.
      assert has_element?(view, "#set-all-review")
      assert has_element?(view, "#set-all-review-save", "Save 4 connections")
    end

    test "a busy write keeps the review open and says nothing changed", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "reboard")

      use_busy_transaction_module()

      save_review(view)

      assert has_element?(view, "#set-all-review")

      assert has_element?(
               view,
               "[data-role='set-all-review-error']",
               "Nothing changed. Try again."
             )

      # Nothing was written and the review still holds every included row, so a
      # retry is one click rather than a rebuilt review.
      assert has_element?(view, "#set-all-review-included", "4 of 4 included")
      refute has_element?(view, "[data-role='bulk-result']")

      for connection <- connections_of(group, "N") do
        assert pair_transfers(context, pair_from(context, connection)) == []
      end
    end

    test "a crafted save naming foreign trips writes only the reviewed pairs", context do
      context = saved_group(context)
      [group | _rest] = derived_groups(context)

      view = open_review(context, group, "reboard")
      [blocked | _rest] = connections_of(group, "B")
      blocked_pair = pair_from(context, blocked)

      # The event names trips outside the reviewed group, but the write's pairs
      # are the review's: a crafted event cannot move the write off the pairs the
      # editor reviewed (R5, AC-5). The reviewed pairs are written and nothing
      # else is.
      render_click(view, "save_bulk", %{
        "pairs" => [%{from: blocked_pair.from.trip_id, to: blocked_pair.to.trip_id}]
      })

      assert render_async(view)

      assert pair_transfers(context, blocked_pair) == []

      for connection <- connections_of(group, "N") do
        assert [transfer] = pair_transfers(context, pair_from(context, connection))
        assert transfer.transfer_type == 5
      end
    end
  end

  # The reviewed group's connections whose block id starts with `prefix`, so a
  # case names the kinds of row — not stated, already set, needs review, refused
  # — by the block the fixture gave them.
  defp connections_of(group, prefix) do
    Enum.filter(group.connections, &String.starts_with?(&1.block_id, prefix))
  end

  # The pair one of the group's connections names. A connection's own `from` and
  # `to` are the trips the fixtures built the record from, so the pair a case
  # reads back needs no second lookup.
  defp pair_from(_context, connection), do: %{from: connection.from, to: connection.to}
end

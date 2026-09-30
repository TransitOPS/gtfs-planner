defmodule GtfsPlannerWeb.Gtfs.BlocksApplyPlanLiveTest do
  # Applying a suggestion from the page and every answer the apply can have. The
  # flow is driven through the
  # ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context: `#blocks-suggest`
  # → drawer → Preview → Apply, and for a rebuild the confirmation dialog before
  # the same write.
  #
  # Two failures are asserted directly: a stale
  # plan must not be writable, and a replace-all must not skip its confirmation.
  # The first is proved by entering a driving time between the preview and the
  # apply and reading the saved rows afterwards — the context refuses the write
  # and the page turns Apply off with its reason, so no trip's `block_id` moved.
  # The second by the dialog's own title and count, and by “Keep current blocks”
  # closing it with the saved rows untouched.
  #
  # The panel's numbers are this day's own, so each case asserts the
  # relationship — the message names the plan's own moves and the plan's own
  # affected service days — rather than a pasted number.
  #
  # The `:busy` and audit-failure answers are the one place a mock stands in:
  # `ReviewedApplyTransaction` is the repository's own transaction boundary, and
  # `ReviewedApplyTransactionMock` returns its refusal without opening one. The
  # success and stale cases run against the real adapter and the SQL Sandbox,
  # and the mock is restored in `on_exit`.
  #
  # Rows are created inside the SQL Sandbox transaction and rolled back.
  use GtfsPlannerWeb.ConnCase, async: false

  # The ceiling for `render_async/2`: it returns as soon as the page's async task
  # has finished, so the value only bounds a failure.
  @async_timeout 5_000

  import Phoenix.LiveViewTest

  import Ecto.Query, only: [from: 2]

  import Mox

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.ReviewedApplyTransactionMock
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    # Two day types that share Weekday, so a plan built on Weekday affects both
    # and the applied message has more than one day type to name.
    dates = for(offset <- 0..25, do: Date.add(~D[2026-10-05], offset))

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "WK",
      name: "Weekday",
      dates: dates
    })

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SCH",
      name: "School",
      dates: [Enum.at(dates, 1), Enum.at(dates, 2), Date.add(~D[2026-10-05], 27)]
    })

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R12",
        route_short_name: "12",
        route_long_name: "Riverside"
      })

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

    %{organization: organization, user: user, version: version, route: route}
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
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

  # Two blocks and two trips the unassigned scope can plan.
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

    trip!(context, %{trip_id: "8105", first: "11:00:00", last: "11:30:00"})
    trip!(context, %{trip_id: "6106", first: "13:00:00", last: "13:30:00"})
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp open_suggest(view), do: view |> element("#blocks-suggest") |> render_click()

  defp choose_scope(view, scope),
    do: view |> form("#suggest-scope-form", %{"scope" => scope}) |> render_change()

  defp toggle_block(view, block_id) do
    view
    |> element("[data-role='select-block'][data-block='#{block_id}']")
    |> render_click()
  end

  defp preview(view) do
    view |> element("#suggest-preview") |> render_click()
    _ = render_async(view, @async_timeout)

    assert has_element?(view, "#suggestion")
  end

  # The apply runs under `start_async`, so the click returns before its result
  # lands. A refusal has no message to wait for — it is an apply *state* — so the
  # check is that the pending state has been replaced once the task has finished.
  defp apply_suggestion(view) do
    view |> element("#apply-suggestion") |> render_click()
    _ = render_async(view, @async_timeout)

    assert assigns(view)[:apply].status != :pending
  end

  defp applied?(view), do: not is_nil(assigns(view)[:applied])

  defp plan(view), do: assigns(view)[:suggestion].plan

  defp block_of(trip_id) do
    from(t in Trip, where: t.trip_id == ^trip_id)
    |> Repo.one()
    |> Map.fetch!(:block_id)
  end

  defp use_reviewed_apply_transaction_mock do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)

    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransactionMock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gtfs_planner, :reviewed_apply_transaction, value)
        :error -> Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)
  end

  describe "applying the unassigned scope" do
    test "writes the plan, clears the preview, reloads the day and says what changed",
         context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      plan = plan(view)
      moved = plan.moves
      assert moved != []

      apply_suggestion(view)

      # The preview is gone and the applied message is where it was.
      refute has_element?(view, "[data-role='suggestion-metric']")
      refute has_element?(view, "#blocks-preview-chip")

      assert has_element?(view, "[data-role='suggestion-applied']", "Suggestion applied.")

      days = Enum.map_join(plan.review.effects, " and ", & &1.day_type.label)

      assert has_element?(
               view,
               "[data-role='suggestion-applied']",
               "#{length(moved)} trips changed block across #{days}"
             )

      assert has_element?(
               view,
               "[data-role='suggestion-applied']",
               "Each trip's change history lists its previous block."
             )

      assert has_element?(view, "#dismiss-applied", "Dismiss")

      # Every trip the plan moved is on the block the plan named, read from the
      # table rather than from the plan.
      for move <- moved do
        assert block_of(move.trip.trip_id) == move.to
      end

      # The page draws the saved day again: the reloaded rows are the applied
      # plan's, so the moved trips are inside blocks rather than in the pool.
      assert assigns(view)[:plan_preview] == nil
      assert assigns(view)[:day].counts.unassigned == 0
    end

    test "a second apply submits once and writes nothing further", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      moves = length(plan(view).moves)
      assert moves > 0

      apply_suggestion(view)

      # The preview is gone, so a second click on the event — a double-click, or
      # a click sent after the result — has no plan to write.
      render_click(view, "apply_suggestion", %{})

      assert length(moved_blocks(context)) == moves
      assert length(change_logs(context)) == moves
    end

    test "the applied message is dismissed without changing the day", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      apply_suggestion(view)
      assert has_element?(view, "[data-role='suggestion-applied']")

      view |> element("#dismiss-applied") |> render_click()

      refute has_element?(view, "[data-role='suggestion-applied']")
      assert assigns(view)[:day].counts.unassigned == 0
    end
  end

  describe "the replace confirmation" do
    test "a rebuild asks first, naming the trips and the day types", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      choose_scope(view, "replace_all")
      preview(view)

      moves = length(plan(view).moves)

      view |> element("#apply-suggestion") |> render_click()

      assert has_element?(view, "#suggestion-replace[data-open='true']")
      assert has_element?(view, "#suggestion-replace", "Replace blocks for #{moves} trips?")
      assert has_element?(view, "#suggestion-replace-cancel", "Keep current blocks")

      assert has_element?(
               view,
               "#suggestion-replace-confirm",
               "Replace blocks for #{moves} trips"
             )

      # Nothing is written while the question is open.
      assert change_logs(context) == []
    end

    test "Keep current blocks closes the dialog and writes nothing", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      choose_scope(view, "replace_all")
      preview(view)

      view |> element("#apply-suggestion") |> render_click()
      assert has_element?(view, "#suggestion-replace[data-open='true']")

      view |> element("#suggestion-replace-cancel") |> render_click()

      refute has_element?(view, "#suggestion-replace[data-open='true']")
      assert has_element?(view, "#suggestion")

      # The saved rows are exactly as they were: the pool trips are still
      # unassigned in the table and in the plan.
      for trip_id <- ["8105", "6106"] do
        assert is_nil(block_of(trip_id))
      end

      assert change_logs(context) == []
    end

    test "Replace writes the plan and reports it as applied", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      choose_scope(view, "replace_all")
      preview(view)

      moved = plan(view).moves

      view |> element("#apply-suggestion") |> render_click()
      view |> element("#suggestion-replace-confirm") |> render_click()

      _ = render_async(view, @async_timeout)
      assert applied?(view)

      refute has_element?(view, "#suggestion-replace[data-open='true']")

      for move <- moved do
        assert block_of(move.trip.trip_id) == move.to
      end
    end
  end

  describe "the states that keep the preview" do
    test "a stale plan turns Apply off and writes nothing", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      moved = plan(view).moves

      # Another writer enters a driving time after this preview was built, so the
      # plan's fingerprint no longer matches the locked rows. The pair is
      # the one the unassigned scope planned — 8105 ends at Valley College and
      # 6106 leaves Riverside Station — so this drive is one the plan read.
      deadhead_time_fixture(context.organization.id, context.version.id, %{
        from_ref: {:stop, "AB_VALLEY"},
        to_ref: {:stop, "AB_RS_A"},
        minutes: 20
      })

      apply_suggestion(view)

      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-apply-state'][data-state='stale']",
               "This suggestion is out of date."
             )

      assert has_element?(view, "#suggestion", "Suggest again before applying")

      # Apply is off and says why; “Suggest again” is the primary action.
      assert has_element?(view, "#apply-suggestion[disabled]")
      assert has_element?(view, "#suggestion-apply-reason", "Apply is off")
      assert has_element?(view, "#suggest-again.btn-primary")

      # The preview is still there to be read or discarded.
      assert has_element?(view, "#suggestion")

      # Nothing was written: every trip the plan named is where it was.
      assert change_logs(context) == []

      for move <- moved do
        assert block_of(move.trip.trip_id) == move.from
      end

      # And the refused event changes nothing, because Apply is off.
      render_click(view, "apply_suggestion", %{})
      assert change_logs(context) == []
    end

    test "a busy answer keeps the preview and offers Apply again", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      set_mox_global()
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, fn _transaction -> {:error, :busy} end)

      apply_suggestion(view)

      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-apply-state'][data-state='busy']",
               "Another change to this version's blocks was saving."
             )

      assert has_element?(view, "#suggestion", "Apply again in a moment.")
      assert has_element?(view, "#apply-suggestion", "Apply again")
      refute has_element?(view, "#apply-suggestion[disabled]")
      assert has_element?(view, "#suggestion")
      assert change_logs(context) == []
    end

    test "a failed audit keeps the preview and offers Apply again", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      set_mox_global()
      use_reviewed_apply_transaction_mock()

      expect(ReviewedApplyTransactionMock, :run, fn _transaction ->
        {:error, {:audit_failed, :refused}}
      end)

      apply_suggestion(view)

      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-apply-state'][data-state='failed']",
               "The suggestion couldn't be saved."
             )

      assert has_element?(view, "#suggestion", "Your blocks are unchanged.")
      assert has_element?(view, "#apply-suggestion", "Apply again")
      assert has_element?(view, "#suggestion")
    end
  end

  describe "the block selection after an apply" do
    test "a successful apply clears it", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      toggle_block(view, "101")
      assert has_element?(view, "#block-selection-bar")

      open_suggest(view)
      choose_scope(view, "unassigned_only")
      preview(view)

      apply_suggestion(view)

      assert assigns(view)[:block_selection] == MapSet.new()
      assert assigns(view)[:selected_blocks] == []
      refute has_element?(view, "#block-selection-bar")
    end
  end

  # The trips the plan actually moved, as the table holds them.
  defp moved_blocks(context) do
    from(t in Trip, where: t.gtfs_version_id == ^context.version.id)
    |> Repo.all()
    |> Enum.map(& &1.block_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # One `"trip"` change log per moved trip under one operation, so the
  # count is the write count: it is how “submits once” is proved without a mock.
  defp change_logs(context) do
    Repo.all(
      from row in ChangeLog,
        where:
          row.gtfs_version_id == ^context.version.id and
            row.organization_id ==
              ^context.organization.id and row.entity_type == "trip",
        select: row.id
    )
  end
end

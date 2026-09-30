defmodule GtfsPlannerWeb.Gtfs.BlocksSuggestLiveTest do
  # The Suggest blocks drawer as a planner
  # chooses a scope. The drawer is read through the ordinary
  # `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo` and
  # the scoped `Blocking` context: which trips each scope would plan, which
  # scopes the day type can offer, the rules the suggestion would use, the
  # estimated driving times, the repeating service left out, and a preview that
  # stores a plan and writes nothing.
  #
  # Rows are created inside the SQL Sandbox transaction and rolled back; nothing
  # here substitutes an adapter, a context or a plan. `:plan_preview` is read from
  # the rendered LiveView's own assigns, the way the version switcher's tests read
  # theirs.
  use GtfsPlannerWeb.ConnCase, async: false

  # The ceiling for `render_async/2`: it returns as soon as the page's async task
  # has finished, so the value only bounds a failure.
  @async_timeout 5_000

  import Phoenix.LiveViewTest

  import Ecto.Query, only: [from: 2]

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
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

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R12",
        route_short_name: "12",
        route_long_name: "Riverside"
      })

    # One meridian, the driving times fixture's own geometry, so a day built on
    # it has real gaps whose drives are the domain's own estimates rather than
    # numbers pasted into a fixture.
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

  # Two blocks, one unassigned trip the unassigned scope can plan, and one
  # repeating trip, which is never blocked and is therefore the repeating
  # service the drawer has to name.
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

    # Repeating service is never blocked, so its trip is the one trip the day type
    # holds that no scope of the drawer can plan.
    trip!(context, %{trip_id: "F30", first: "16:00:00", last: "16:30:00"})

    frequency_row_fixture(context.organization.id, context.version.id, %{trip_id: "F30"})
  end

  # Every leg of the day is given an entered driving time, so the day has no
  # estimated pair left and the drawer's warning has nothing to warn about. The
  # pairs and the refs are the context's own, stored through its own writer.
  # A day type is named by its opaque key, not by the service ID it runs on, so
  # the fixture's single "Weekday" day type is read for its key.
  defp day_key!(context, label) do
    {:ok, day} = Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

    case Enum.find(day.day_types, &(&1.label == label)) do
      nil -> raise "no #{label} day type in the fixture"
      day_type -> day_type.key
    end
  end

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
          context.organization.id,
          context.version.id,
          {pair.from, pair.to},
          7
        )
    end)
  end

  defp open_suggest(view), do: view |> element("#blocks-suggest") |> render_click()

  defp close_drawer(view), do: view |> element("#suggest-cancel") |> render_click()

  defp toggle_block(view, block_id) do
    view
    |> element("[data-role='select-block'][data-block='#{block_id}']")
    |> render_click()
  end

  defp rebuild_selected(view), do: view |> element("#block-selection-rebuild") |> render_click()

  # The scope the page's own Driving times button reports, so the warning's count
  # is compared with the same day's own answer rather than a number this file
  # hard-codes.
  defp estimated_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-driving-times")
    |> LazyHTML.text()
    |> then(&Regex.run(~r/· (\d+) estimated/, &1))
    |> case do
      [_, count] -> String.to_integer(count)
      _other -> 0
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  describe "the Suggest blocks page action" do
    test "it opens the drawer with unassigned trips only selected", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")

      open_suggest(view)

      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#suggest-drawer", "Suggest blocks")
      assert has_element?(view, "#suggest-drawer", "Weekday")
      assert has_element?(view, "#suggest-drawer", "Nothing is saved until you")

      # The three scopes are the generator's three modes under the names a reader
      # reads, and the unassigned one is the default the drawer offers.
      assert has_element?(view, "#suggest-scope-unassigned_only[checked]")
      assert has_element?(view, "#suggest-scope-unassigned_only")
      assert has_element?(view, "#suggest-scope-replace_all")
      refute has_element?(view, "#suggest-scope-selected[checked]")

      # The unassigned scope names the trips it would plan — the day type's pool
      # without the repeating trip, which no scope can block.
      assert has_element?(view, "#suggest-scopes", "Add the 1 unassigned trip to")
      refute has_element?(view, "#suggest-scopes", "F30 repeats")
    end

    test "the scope form is the drawer's own control", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      view |> form("#suggest-scope-form", %{"scope" => "replace_all"}) |> render_change()

      assert has_element?(view, "#suggest-scope-replace_all[checked]")
      refute has_element?(view, "#suggest-scope-unassigned_only[checked]")
    end
  end

  describe "the selected blocks scope" do
    test "it is disabled with its reason while no block is selected", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      # The scope is offered with its reason rather than silently
      # available, so a reader is never asked to plan nothing.
      assert has_element?(view, "#suggest-scope-selected[disabled]")
      assert has_element?(view, "#suggest-scopes", "Select blocks on the timeline first.")
      refute has_element?(view, "#suggest-scopes", "Selected blocks (")
    end

    test "it names the selected blocks and is preselected from the selection bar", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      toggle_block(view, "101")
      toggle_block(view, "102")

      # “Rebuild selected blocks” hands off to the drawer, which opens on the scope
      # the reader just chose.
      rebuild_selected(view)

      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#suggest-scope-selected[checked]")
      refute has_element?(view, "#suggest-scope-selected[disabled]")
      assert has_element?(view, "#suggest-scopes", "Selected blocks (101, 102)")
      assert has_element?(view, "#suggest-scopes", "Plan these blocks’ trips again.")

      # The selection survives the drawer, so a reader who cancels and comes back
      # is offered the same blocks.
      close_drawer(view)
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")

      open_suggest(view)
      assert has_element?(view, "#suggest-scopes", "Selected blocks (101, 102)")
    end
  end

  describe "the rules the drawer lists" do
    test "it names the four rules and links the two drawers that own them", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      assert has_element?(view, "#suggest-rules", "Rules used")
      assert has_element?(view, "#suggest-rules-list", "Minimum layover")
      assert has_element?(view, "#suggest-rules-list", "5 min")
      assert has_element?(view, "#suggest-rules-list", "Longest time out")
      assert has_element?(view, "#suggest-rules-list", "Vehicle type limits")
      assert has_element?(view, "#suggest-rules-list", "Route switches")
      assert has_element?(view, "#suggest-rules-list", "Anywhere")
      assert has_element?(view, "#suggest-rules-list", "Operator changes")
      assert has_element?(view, "#suggest-rules-list", "Not checked")

      # With no limit stored, the checks are off, and the drawer says what a
      # suggestion then may produce.
      assert has_element?(
               view,
               "#suggest-operator-note",
               "Operator changes aren’t checked, so suggestions may produce blocks"
             )

      assert has_element?(view, "#suggest-open-rules", "Block rules")
      assert has_element?(view, "#suggest-open-operator-changes", "Operator changes")
    end

    test "the rules read the stored answers", context do
      garage!(context)
      block_day!(context)

      # The same values the Block rules and Operator changes drawers store, read
      # through their own context writers before the page is ever mounted.
      {:ok, _settings} =
        Gtfs.update_blocking_settings(context.organization.id, context.version.id, %{
          min_layover_minutes: 12,
          max_block_minutes: 600,
          interlining: :same_stop
        })

      {:ok, _relief} =
        Gtfs.update_relief_settings(
          context.organization.id,
          context.version.id,
          day_key!(context, "Weekday"),
          %{max_piece_minutes: 300, marked: []}
        )

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      assert has_element?(view, "#suggest-rules-list", "12 min")
      assert has_element?(view, "#suggest-rules-list", "600 min")
      assert has_element?(view, "#suggest-rules-list", "Same stop only")
      assert has_element?(view, "#suggest-rules-list", "Within 300 min")
      refute has_element?(view, "#suggest-operator-note")
    end

    test "the Block rules link opens the rules drawer and leaves this one", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      view |> element("#suggest-open-rules") |> render_click()

      assert has_element?(view, "#block-rules-drawer-overlay[data-open='true']")
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
    end

    test "the Operator changes link opens that drawer and leaves this one", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      view |> element("#suggest-open-operator-changes") |> render_click()

      assert has_element?(view, "#operator-changes-drawer-overlay[data-open='true']")
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
    end
  end

  describe "the estimate warning and the repeating note" do
    test "the warning names the day's estimated pairs and links the driving times",
         context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      count = estimated_count(view)
      assert count > 0

      assert has_element?(
               view,
               "#suggest-estimated-warning",
               "#{count} driving times are estimates."
             )

      assert has_element?(view, "#suggest-estimated-warning", "Traffic and road access")
      assert has_element?(view, "#suggest-review-driving-times", "Review driving times")

      view |> element("#suggest-review-driving-times") |> render_click()

      assert has_element?(view, "#driving-times-drawer-overlay[data-open='true']")
      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
    end

    test "a day with nothing estimated shows no warning", context do
      garage!(context)

      # One trip in one block: the block's own garage pull and return are the
      # only legs, and with no garage movement the day has no estimated pair to
      # warn about.
      trip!(context, %{trip_id: "only", block_id: "101", first: "08:00:00", last: "09:00:00"})
      enter_every_drive!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      # The day's own answer first: a failure here names the driving times rather
      # than the drawer's warning.
      assert estimated_count(view) == 0

      refute has_element?(view, "#suggest-estimated-warning")
      assert has_element?(view, "#suggest-intro")
    end

    test "the repeating-service note names the trip the scopes leave out", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      assert has_element?(view, "#suggest-repeating", "F30")
      assert has_element?(view, "#suggest-repeating", "stays unassigned")
    end
  end

  describe "previewing a suggestion" do
    test "it stores the plan, closes the drawer and writes nothing", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      refute assigns(view)[:plan_preview]

      # A suggestion is built under `start_async`, so the drawer's close follows the
      # task's result rather than the click.
      view |> element("#suggest-preview") |> render_click()
      _ = render_async(view, @async_timeout)

      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")

      plan = assigns(view)[:plan_preview]
      assert plan.mode == :unassigned_only
      assert plan.day_type_key == day_key!(context, "Weekday")
      assert is_list(plan.moves)
      assert is_binary(plan.fingerprint)

      # The preview is a plan, not an application: the day it was read from is
      # still the day on screen, and the blocks still hold what they held.
      assert has_element?(view, "#blocks-page")
      assert unassigned?("pool_trip")
    end

    test "the selected scope is the mode the plan was built from", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      toggle_block(view, "101")
      rebuild_selected(view)

      # A suggestion is built under `start_async`, so the drawer's close follows the
      # task's result rather than the click.
      view |> element("#suggest-preview") |> render_click()
      _ = render_async(view, @async_timeout)

      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")

      plan = assigns(view)[:plan_preview]
      assert {:selected, ids} = plan.mode
      assert ids == ["101"]
    end

    @tag timeout: 300_000
    test "a scope of more than 3,000 trips is refused in the drawer and previews nothing",
         context do
      garage!(context)
      oversized_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)

      view |> element("#suggest-preview") |> render_click()

      _ = render_async(view, 60_000)

      assert has_element?(view, "#suggest-too-large")

      assert has_element?(view, "#suggest-too-large", "3001")
      assert has_element?(view, "#suggest-too-large", "up to 3,000 trips")
      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      refute assigns(view)[:plan_preview]
    end
  end

  describe "a version with no garage" do
    test "the page action is disabled and says why", context do
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      # A suggestion is built from garages; without one there is nothing to build
      # it from, and the action says so rather than opening a drawer that could
      # only fail.
      assert has_element?(
               view,
               "#blocks-suggest[disabled][title='Add a garage in Settings first']"
             )

      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")
    end
  end

  defp unassigned?(trip_id) do
    from(t in GtfsPlanner.Gtfs.Trip, where: t.trip_id == ^trip_id)
    |> Repo.one()
    |> Map.fetch!(:block_id)
    |> is_nil()
  end

  # The oversized day is 3,001 unassigned trips, inserted in bulk inside the
  # sandbox transaction: the generator's bound is 3,000 trips in scope, so this is
  # the smallest day type that can be refused. The rows are the same
  # shape the fixture builds, and they roll back with the test.
  defp oversized_day!(context, count \\ 3_001) do
    stop_fixture(context.organization.id, context.version.id, %{
      stop_id: "AB_BULK",
      stop_name: "Bulk Stop"
    })

    # The trip timestamps are `:utc_datetime_usec` columns, so the value carries
    # microseconds; truncating to seconds is what the column refuses.
    now = DateTime.utc_now()

    trips =
      for index <- 1..count do
        %{
          organization_id: context.organization.id,
          gtfs_version_id: context.version.id,
          trip_id: "bulk_#{index}",
          route_id: context.route.route_id,
          service_id: "WK",
          block_id: nil,
          pattern_derivation_state: "pending",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(GtfsPlanner.Gtfs.Trip, trips)

    stop_times =
      for trip <- trips, {sequence, time} <- [{1, "08:00:00"}, {2, "08:30:00"}] do
        %{
          organization_id: trip.organization_id,
          gtfs_version_id: trip.gtfs_version_id,
          trip_id: trip.trip_id,
          stop_id: "AB_BULK",
          stop_sequence: sequence,
          arrival_time: time,
          departure_time: time,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(GtfsPlanner.Gtfs.StopTime, stop_times)
  end
end

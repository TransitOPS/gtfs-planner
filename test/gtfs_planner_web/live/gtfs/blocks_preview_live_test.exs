defmodule GtfsPlannerWeb.Gtfs.BlocksPreviewLiveTest do
  # EV-38, rejecting FH-38 for CL-38: the Suggested blocks panel as a preview
  # reader inspects before anything is saved — AC-44. The panel is read through
  # the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context, through the same
  # `#blocks-suggest` → drawer → Preview path a planner uses.
  #
  # FH-38 is a claim about two things, and both are asserted here directly: that
  # the preview never edits saved state, and that the controls it would conflict
  # with are off while it is up. The first is checked two ways — every trip's
  # `block_id` in the database, and a second LiveView reading the same day
  # through its own load; the second by the disabled attributes on the day
  # select, the two settings buttons, the page action and the block checkboxes,
  # and by the block selection bar being gone.
  #
  # The panel's numbers are this day's own. The card's sample figures (four
  # vehicles, two moves, "2 existing problems remain", 143 and 38 dates) belong to
  # the prototype's sample data rather than to any fixture this repository owns, so
  # each case asserts the structure and the relationship — the metric reads the
  # plan's before and after pair, the note reads the plan's review, the day-type
  # card reads the affected set — instead of a number that would be pasted rather
  # than read.
  #
  # Rows are created inside the SQL Sandbox transaction and rolled back; nothing
  # here substitutes an adapter, a context or a plan.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_preview_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

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
  alias GtfsPlanner.Gtfs.Blocking.Checks
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

    # Weekday runs every day of the fixture's four weeks and School two of those
    # weekdays, so the version derives two day types and both hold Weekday: a
    # suggestion planned on Weekday therefore affects both, which is what the
    # panel's one-card-per-affected-day-type case needs.
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

    # One meridian, the driving times fixture's own geometry, so a day built on
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

  # Two blocks, two trips the unassigned scope can plan, and one repeating trip,
  # which is never blocked and is therefore the repeating service the panel has
  # to name.
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

    trip!(context, %{trip_id: "F30", first: "16:00:00", last: "16:30:00"})

    frequency_row_fixture(context.organization.id, context.version.id, %{trip_id: "F30"})
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

  # Preview builds the plan under `start_async`, so the panel follows the task's
  # result rather than the click. This waits for it and gives up rather than
  # hanging, so a failure is a failed assertion and not a stalled suite.
  defp preview(view) do
    view |> element("#suggest-preview") |> render_click()

    assert wait_for(fn -> has_element?(view, "#suggestion") end) == :ok
  end

  defp wait_for(condition, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait(condition, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(25) && do_wait(fun, deadline)
    end
  end

  # The panel's own numbers, read from the plan rather than from the DOM, so a
  # case compares the printed figure with the value it was printed from.
  defp suggestion(view), do: assigns(view)[:suggestion]

  describe "the Suggested blocks panel" do
    test "it names the plan, its badge and its four headline figures", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      assert has_element?(view, "#suggestion")
      assert has_element?(view, "#suggestion", "Suggested blocks")
      assert has_element?(view, "#suggestion", "Preview · not saved")

      plan = suggestion(view).plan
      before = plan.before
      after_ = plan.after

      # Vehicles, with the day's own minimum beside it.
      assert has_element?(
               view,
               "#suggestion",
               "Vehicles · current → proposed"
             )

      assert has_element?(
               view,
               "#suggestion",
               "#{before.vehicles} → #{after_.vehicles}"
             )

      assert has_element?(view, "#suggestion", "minimum possible #{suggestion(view).minimum}")

      # Deadhead hours as the reference prints them: one decimal of an hour.
      assert has_element?(view, "#suggestion", "Driving without riders · h")

      assert has_element?(
               view,
               "#suggestion",
               "#{hours(before.drive_secs)} → #{hours(after_.drive_secs)}"
             )

      # The two single figures: the moves are the plan's, and so is the count of
      # problems the plan adds, which is the review's own. A metric's label and
      # its value are separate elements, so each is read on its own — that way a
      # figure cannot be matched against a different metric's label.
      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-metric-label']",
               "Trips changing block"
             )

      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-metric-value']",
               Integer.to_string(length(plan.moves))
             )

      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-metric-label']",
               "New problems"
             )

      assert has_element?(
               view,
               "#suggestion [data-role='suggestion-metric-value']",
               Integer.to_string(plan.review.added_problem_count)
             )
    end

    test "it reports the problems that remain and the ones the plan fixes", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      # The panel's own count, derived from the saved day's findings less the keys
      # the review adds: what a reader can see on the page, not only the blocks
      # the plan touched.
      existing = suggestion(view).existing
      fixed = suggestion(view).fixed

      # The note is the reference's: what is already there beside what is new,
      # and a plan over a day with neither says so rather than printing nothing.
      expected =
        [
          if(existing > 0,
            do:
              "#{existing} existing #{if existing == 1, do: "problem remains", else: "problems remain"}"
          ),
          if(fixed > 0, do: "#{fixed} fixed")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · ")

      assert has_element?(view, "#suggestion", expected)
    end

    test "a rebuild reports the problems it removes as fixed", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      choose_scope(view, "replace_all")
      preview(view)

      # The count is this day's own diff between the saved findings and the
      # proposal's, keyed by `Checks.finding_key/1`; a plan that removes nothing
      # claims no fix rather than printing an empty one.
      fixed = suggestion(view).fixed
      day = assigns(view)[:day]

      expected_fixed =
        day.findings
        |> Enum.filter(&(&1.severity in [:error, :warning]))
        |> Enum.map(&Checks.finding_key/1)
        |> length()

      assert fixed <= expected_fixed

      if fixed > 0 do
        assert has_element?(view, "#suggestion", "#{fixed} fixed")
      else
        refute has_element?(view, "#suggestion", "fixed")
      end

      # A rebuild re-plans the whole day type, so the panel says so in the
      # reference's own words.
      assert has_element?(
               view,
               "#suggestion",
               "Every scheduled trip in this day type was planned again"
             )
    end
  end

  describe "Inspect affected trips and dates" do
    test "the pool trips are listed as Added with the block each is proposed for",
         context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      added =
        suggestion(view).plan.moves
        |> Enum.filter(&is_nil(&1.from))
        |> Enum.map(& &1.trip.trip_id)

      # Every pool trip the plan places is an addition, and each one is shown
      # with the block it would join.
      assert added != []

      for trip_id <- added do
        assert has_element?(view, "#suggestion-moves", trip_id)
        assert has_element?(view, "#suggestion-moves", "Added")
      end

      assert has_element?(
               view,
               "#suggestion-moves [data-role='suggestion-change'][data-change='added']"
             )

      refute has_element?(
               view,
               "#suggestion-moves [data-role='suggestion-change'][data-change='moved']"
             )
    end

    test "one card per affected day type, the selected one first and marked", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      effects = suggestion(view).plan.review.effects

      # The plan's own affected set, and the cards are one per entry of it — the
      # shared `review_effect/1`, so the day type says the same thing here as in
      # the review dialog.
      assert length(effects) > 1

      for effect <- effects do
        selector =
          "#suggestion [data-role='review-effect'][data-selected='#{effect.selected?}']"

        assert has_element?(view, selector, effect.day_type.label)
      end

      assert has_element?(
               view,
               "#suggestion [data-role='review-effect'][data-selected='true']",
               "Current view"
             )

      assert has_element?(
               view,
               "#suggestion [data-role='review-effect'][data-selected='false']",
               "Also changes"
             )

      # The scope sentence is the reference's per scope, and the repeating trip
      # the plan left alone is named rather than counted.
      assert has_element?(view, "#suggestion-scope-note", "Existing assignments stay")
      assert has_element?(view, "#suggestion-scope-note", "F30")
    end
  end

  describe "the proposed plan drawn on the page" do
    test "the changed rows carry the marker and the label, and the legend explains it",
         context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      changed = MapSet.to_list(suggestion(view).changed_block_ids)
      assert changed != []

      for block_id <- changed do
        assert has_element?(
                 view,
                 "#blocks-timeline tr[data-block='#{block_id}'].blocks-row-changed"
               )
      end

      assert has_element?(view, "#blocks-timeline [data-role='block-changed']", "Changed")

      # The legend key is only there while there is something to explain, and it
      # says the change is not saved.
      assert has_element?(view, "#blocks-timeline-legend", "Changed · not saved")
      assert has_element?(view, "#blocks-preview-chip", "Showing the suggestion")
    end

    test "an unchanged block is not marked", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      changed = MapSet.to_list(suggestion(view).changed_block_ids)

      page_blocks =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#blocks-timeline tr[data-block]")
        |> Enum.map(&LazyHTML.attribute(&1, "data-block"))
        |> List.flatten()

      for block_id <- page_blocks -- changed do
        refute has_element?(
                 view,
                 "#blocks-timeline tr[data-block='#{block_id}'].blocks-row-changed"
               )
      end
    end
  end

  describe "the saved day is untouched" do
    test "no trip's block changed and a second LiveView reads the original day",
         context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      # The plan is a proposal: a pool trip the panel draws inside a block is
      # still an unassigned row in the table.
      for trip_id <- ["8105", "6106"] do
        assert is_nil(block_of(trip_id))
      end

      # And a reader who opens the page a second time gets the saved day, not the
      # preview: the preview is one page's state and never becomes the day. The
      # page opens on the Unassigned panel, because that is the panel the pool
      # table belongs to.
      {:ok, other, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?panel=pool")

      refute has_element?(other, "#suggestion")
      refute has_element?(other, "#blocks-preview-chip")

      # The timeline carries the same two saved blocks either panel shows.
      {:ok, timeline, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert has_element?(timeline, "#blocks-timeline tr[data-block='101']")
      assert has_element?(timeline, "#blocks-timeline tr[data-block='102']")

      # The unassigned panel still holds both pool trips, so the saved day the
      # second reader loads is the one before the suggestion.
      # The pool table holds all three unassigned trips at once, so each is found
      # by its own row rather than by matching the whole table's text.
      # The pool arrives as a stream, so its rows land in a patch after the
      # first render and the assertions wait for them.
      assert wait_for(fn -> has_element?(other, "#blocks-pool-table tr") end) == :ok

      for trip_id <- ["8105", "6106", "F30"] do
        assert has_element?(other, "#blocks-pool-table tr", trip_id)
      end
    end

    test "the loaded day assign is the saved one, not the proposal", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      # `render/1` draws the proposal from the `:suggestion` assign; the day it
      # came from is still the loaded one, so discarding needs no reload and a
      # later apply can still match the plan's fingerprint.
      # The pool is 8105, 6106 and the frequency row F30, so three trips are
      # unassigned; the preview does not change the saved day they sit in.
      assert assigns(view)[:day].counts.unassigned == 3
    end
  end

  describe "the controls a preview would conflict with" do
    test "the day select, both settings buttons, the page action and the checkboxes are off",
         context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      # A block is selected so the selection bar would be on the page; a preview
      # takes it away, because "Rebuild selected blocks" is not a control that
      # means anything over a plan.
      toggle_block(view, "101")
      assert has_element?(view, "#block-selection-bar")

      open_suggest(view)
      preview(view)

      assert has_element?(view, "#blocks-day[disabled]")
      assert has_element?(view, "#blocks-block-rules[disabled]")
      assert has_element?(view, "#blocks-driving-times[disabled]")
      assert has_element?(view, "#blocks-suggest[disabled]")

      # Each says why, rather than simply going dead.
      assert has_element?(view, "#blocks-suggest[title]")
      assert has_element?(view, "#blocks-block-rules[title]")

      assert has_element?(view, "[data-role='select-block'][disabled]")
      assert has_element?(view, "#blocks-select-all-blocks[disabled]")

      refute has_element?(view, "#block-selection-bar")
    end

    test "their events are refused even when they are sent", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      # A disabled control that still fired would leave the panel describing a
      # plan the page no longer shows, so the events themselves refuse. The
      # events are sent directly, because a disabled control cannot be clicked.
      render_click(view, "open_drawer", %{"key" => "suggest"})
      render_click(view, "open_drawer", %{"key" => "block_rules"})

      render_click(view, "select_day", %{
        "day" => assigns(view)[:day_types] |> hd() |> Map.fetch!(:key)
      })

      refute has_element?(view, "#suggest-drawer-overlay[data-open='true']")

      render_click(view, "toggle_block", %{"block" => "101"})
      render_click(view, "select_block_page", %{})
      assert MapSet.size(assigns(view)[:block_selection]) == 0
      assert has_element?(view, "#suggestion")
    end
  end

  describe "discarding and suggesting again" do
    test "Discard restores the saved rows and the controls", context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))
      open_suggest(view)
      preview(view)

      assert has_element?(view, "#suggestion")
      assert has_element?(view, "[data-role='block-changed']")

      view |> element("#discard-suggestion") |> render_click()

      refute has_element?(view, "#suggestion")
      refute has_element?(view, "#blocks-preview-chip")
      refute has_element?(view, "#blocks-timeline-legend", "Changed · not saved")
      refute has_element?(view, "[data-role='block-changed']")

      # Every control is back, and the day type select answers again.
      assert has_element?(view, "#blocks-day:not([disabled])")
      assert has_element?(view, "#blocks-suggest:not([disabled])")
      assert has_element?(view, "#blocks-block-rules:not([disabled])")
      assert has_element?(view, "[data-role='select-block']:not([disabled])")
    end

    test "Suggest again reopens the drawer on the scope the plan was built with",
         context do
      garage!(context)
      block_day!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      toggle_block(view, "101")
      view |> element("#block-selection-rebuild") |> render_click()

      assert has_element?(view, "#suggest-scope-selected[checked]")

      preview(view)
      assert has_element?(view, "#suggestion")

      view |> element("#suggest-again") |> render_click()

      assert has_element?(view, "#suggest-drawer-overlay[data-open='true']")
      assert has_element?(view, "#suggest-scope-selected[checked]")
      assert has_element?(view, "#suggest-scopes", "Selected blocks (101)")

      # The panel is gone, because the reader is choosing again rather than
      # reading a proposal.
      refute has_element?(view, "#suggestion")
    end
  end

  defp hours(secs) when is_integer(secs), do: :erlang.float_to_binary(secs / 3600, decimals: 1)
  defp hours(_no_seconds), do: "—"

  defp block_of(trip_id) do
    from(t in GtfsPlanner.Gtfs.Trip, where: t.trip_id == ^trip_id)
    |> Repo.one()
    |> Map.fetch!(:block_id)
  end
end

defmodule GtfsPlannerWeb.Gtfs.BlocksBulkLiveTest do
  # EV-25: the cross-page selection, its pruning and the bulk actions, observed
  # through the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context, so every bulk
  # action reaches the real `Gtfs.apply_block_change/4`. Rows are created inside
  # the SQL Sandbox transaction and rolled back; nothing here substitutes an
  # adapter.
  #
  # The card's browser scenarios (the bar across pages, the mixed-eligibility
  # dialog and the 375px layout) belong to `assets/e2e/blocks.spec.js`, which
  # step 29 owns with EV-28; this file writes the eleven server cases.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_bulk_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # The pool holds one page of 100 trips, like the block pages (Pages / URL state).
  @page_size 100

  @weekend %{
    monday: 0,
    tuesday: 0,
    wednesday: 0,
    thursday: 0,
    friday: 0,
    saturday: 1,
    sunday: 0
  }

  defp editor_scope(_context) do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R1",
        route_short_name: "1",
        route_long_name: "Riverside"
      })

    %{user: user, organization: organization, version: version, route: route}
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp calendar(context, service_id, name, attrs \\ %{}) do
    calendar_service_fixture(
      context.organization.id,
      context.version.id,
      Map.merge(Map.new(attrs), %{service_id: service_id, name: name})
    )
  end

  defp trip(context, attrs) do
    attrs = Map.new(attrs)
    route_id = Map.get(attrs, :route, context.route.route_id)
    {first, attrs} = Map.pop(attrs, :first, "08:00:00")
    {last, attrs} = Map.pop(attrs, :last, "09:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route_id,
      attrs
      |> Map.delete(:route)
      |> Map.put_new(:service_id, "WK")
      |> Map.put_new(:trip_id, "trip_#{System.unique_integer([:positive])}")
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
    )
  end

  # One block's trips, in the order the clocks are given, so a case can hold the
  # trips it selected and read them back from the database.
  defp block_trips(context, block_id, pairs) do
    Enum.map(Enum.with_index(pairs), fn {{first, last}, index} ->
      trip(context, %{
        trip_id: "#{block_id}_#{index}",
        block_id: block_id,
        first: first,
        last: last
      })
    end)
  end

  # 149 plottable pool trips, one per minute from 06:00, plus a trip whose last
  # time is missing: page 1 is the first 100 departures, page 2 the remaining 49
  # and then the untimed trip.
  defp seed_pool_day(context) do
    calendar(context, "WK", "Weekday")

    for index <- 1..149 do
      first = 6 * 3_600 + (index - 1) * 60

      trip(context, %{
        trip_id: pool_id(index),
        first: clock(first),
        last: clock(first + 1_800)
      })
    end

    trip(context, %{trip_id: "p_untimed", last: nil})
  end

  defp pool_id(index), do: "p" <> String.pad_leading(Integer.to_string(index), 3, "0")

  defp clock(secs) do
    "#{pad(div(secs, 3_600))}:#{pad(div(rem(secs, 3_600), 60))}:00"
  end

  defp pad(value), do: String.pad_leading(Integer.to_string(value), 2, "0")

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp element_count(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  # The pool's trip IDs in document order, read from each row's selection
  # control: the row order is what the departure sort and the paging produce.
  defp pool_trip_ids(view) do
    view
    |> doc()
    |> LazyHTML.query("#blocks-pool-table [data-role='select-trip']")
    |> LazyHTML.attribute("data-trip")
  end

  # The selection bar's own sentence, so a case reads what the reader reads.
  defp bulk_count(view) do
    view |> doc() |> LazyHTML.query("#bulk-count") |> LazyHTML.text() |> String.trim()
  end

  # The day-type select's option values, so the day form can be driven by label
  # the way a reader drives it.
  defp day_key(view, label) do
    view
    |> doc()
    |> LazyHTML.query("#blocks-day option")
    |> Enum.find_value(fn option ->
      if String.starts_with?(LazyHTML.text(option) |> String.trim(), label) do
        LazyHTML.attribute(option, "value") |> List.first()
      end
    end)
  end

  defp dates_matching(fun) do
    ~D[2026-01-01] |> Date.range(~D[2026-12-31]) |> Enum.count(fun)
  end

  defp weekday_dates, do: dates_matching(&(Date.day_of_week(&1) in 1..5))

  defp toggle_trip(view, trip_id) do
    view
    |> element("[data-role='select-trip'][data-trip='#{trip_id}']")
    |> render_click()
  end

  defp select_page(view), do: view |> element("#blocks-select-page") |> render_click()

  defp clear_selection(view), do: view |> element("#bulk-clear") |> render_click()

  defp bulk_assign(view), do: view |> element("#bulk-assign") |> render_click()

  defp bulk_remove(view), do: view |> element("#bulk-remove") |> render_click()

  defp submit_bulk(view, destination) do
    view
    |> form("#assign-form", assign: %{destination: destination})
    |> render_submit()
  end

  defp confirm_review(view), do: view |> element("#block-review-confirm") |> render_click()

  defp persisted(trip), do: Repo.get!(Trip, trip.id)

  defp trip_logs(context, trip) do
    Gtfs.list_change_logs_for_entity(
      context.organization.id,
      context.version.id,
      "trip",
      trip.id
    )
  end

  # Two routes and two calendars, so one case can select a trip of each route and
  # switch to the Saturday day type.
  defp route_scope(context) do
    calendar(context, "WK", "Weekday")
    calendar(context, "SAT", "Saturday", @weekend)

    route_fixture(context.organization.id, context.version.id, %{
      route_id: "R2",
      route_short_name: "2",
      route_long_name: "Central"
    })

    trip(context, %{trip_id: "r1_trip", first: "08:00:00", last: "09:00:00"})
    trip(context, %{trip_id: "r2_trip", route: "R2", first: "08:10:00", last: "09:10:00"})

    trip(context, %{
      trip_id: "sat_trip",
      service_id: "SAT",
      first: "08:20:00",
      last: "09:20:00"
    })
  end

  # Three unassigned trips at distinct times, so one bulk assignment covers them
  # without adding a problem of its own.
  defp assign_scope(context) do
    calendar(context, "WK", "Weekday")

    [
      trip(context, %{trip_id: "a1", first: "06:00:00", last: "06:30:00"}),
      trip(context, %{trip_id: "a2", first: "07:00:00", last: "07:30:00"}),
      trip(context, %{trip_id: "a3", first: "08:00:00", last: "08:30:00"})
    ]
  end

  # A repeating trip beside one that can be assigned, which is the mixed
  # selection the reference's dialog names trip by trip.
  defp ineligible_scope(context) do
    calendar(context, "WK", "Weekday")

    frequency = trip(context, %{trip_id: "freq_1", first: "06:00:00", last: "06:30:00"})

    frequency_row_fixture(context.organization.id, context.version.id, %{
      trip_id: frequency.trip_id,
      headway_secs: 1_200
    })

    %{
      frequency: frequency,
      ok: trip(context, %{trip_id: "ok_1", first: "08:00:00", last: "08:30:00"})
    }
  end

  # Two blocks whose trips can be removed, one trip in each block so a bulk
  # removal touches two blocks and both of them keep a trip.
  defp blocked_scope(context) do
    calendar(context, "WK", "Weekday")
    block_trips(context, "201", [{"06:00:00", "06:30:00"}, {"07:00:00", "07:30:00"}])
    block_trips(context, "202", [{"09:00:00", "09:30:00"}])
  end

  describe "a selection that spans pool pages" do
    setup :editor_scope

    test "one trip from each page reports how many are on other pages",
         %{version: version} = context do
      seed_pool_day(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      toggle_trip(view, "p001")

      assert bulk_count(view) == "1 selected"
      assert has_element?(view, "#blocks-bulk-bar")

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='select-trip'][data-trip='p001'][checked]"
             )

      assert has_element?(view, "#bulk-assign", "Assign 1 trip")
      refute has_element?(view, "#bulk-remove")

      # Paging keeps the selection and now reports the trip the page does not
      # hold; the bar stays visible while the reader pages.
      view |> element("#blocks-pool-pager button[phx-value-page='2']") |> render_click()

      assert_patch(view, base <> "?panel=pool&pool_page=2")
      assert bulk_count(view) == "1 selected · 1 on other pages"
      assert has_element?(view, "#blocks-bulk-bar")
      assert hd(pool_trip_ids(view)) == "p101"

      toggle_trip(view, "p101")

      assert bulk_count(view) == "2 selected · 1 on other pages"
      assert has_element?(view, "#bulk-assign", "Assign 2 trips")

      refute has_element?(
               view,
               "#blocks-pool-table [data-role='select-trip'][data-trip='p001']"
             )

      # Back on page 1 the trip selected there is still checked.
      view |> element("#blocks-pool-pager button[phx-value-page='1']") |> render_click()

      assert bulk_count(view) == "2 selected · 1 on other pages"

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='select-trip'][data-trip='p001'][checked]"
             )

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='select-trip'][data-trip='p001'][phx-click='toggle_trip']"
             )
    end

    test "“Select this page” selects every trip on the page and “Clear selection” empties it",
         %{version: version} = context do
      seed_pool_day(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      select_page(view)

      assert bulk_count(view) == "100 selected"

      assert element_count(view, "#blocks-pool-table [data-role='select-trip'][checked]") ==
               @page_size

      # The second page's own trips are added to the same selection.
      view |> element("#blocks-pool-pager button[phx-value-page='2']") |> render_click()
      select_page(view)

      assert bulk_count(view) == "150 selected · 100 on other pages"

      clear_selection(view)

      refute has_element?(view, "#blocks-bulk-bar")
      assert element_count(view, "[data-role='select-trip'][checked]") == 0
      assert element_count(view, "#blocks-pool-table [data-role='select-trip']") == 50
    end
  end

  describe "pruning the selection" do
    setup :editor_scope

    test "the route filter keeps only the selected trips on that route",
         %{version: version} = context do
      route_scope(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      toggle_trip(view, "r1_trip")
      toggle_trip(view, "r2_trip")

      assert bulk_count(view) == "2 selected"

      view |> element("#blocks-filter-form") |> render_change(%{"route" => "R2"})

      assert_patch(view, base <> "?panel=pool&route=R2")
      assert bulk_count(view) == "1 selected"

      assert has_element?(
               view,
               "#blocks-pool-table [data-role='select-trip'][data-trip='r2_trip'][checked]"
             )

      refute has_element?(view, "[data-role='select-trip'][data-trip='r1_trip']")
    end

    test "a day change clears the selection", %{version: version} = context do
      route_scope(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      toggle_trip(view, "r1_trip")
      assert bulk_count(view) == "1 selected"

      saturday = day_key(view, "Saturday")

      view |> element("#blocks-day-form") |> render_change(%{"day" => saturday})

      assert_patch(view, base <> "?day=#{saturday}&panel=pool")
      refute has_element?(view, "#blocks-bulk-bar")
      assert element_count(view, "[data-role='select-trip'][checked]") == 0
      assert pool_trip_ids(view) == ["sat_trip"]
    end
  end

  describe "bulk assigning a selection" do
    setup :editor_scope

    test "three trips are reviewed once and the confirmed block is stored on all of them",
         %{version: version} = context do
      [a1, a2, a3] = assign_scope(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?panel=pool")

      Enum.each(["a1", "a2", "a3"], &toggle_trip(view, &1))

      assert bulk_count(view) == "3 selected"
      assert has_element?(view, "#bulk-assign", "Assign 3 trips")

      bulk_assign(view)

      assert has_element?(view, "#bulk-assign-dialog[data-open='true']")
      assert has_element?(view, "#assign-form", "3 trips · applies on #{weekday_dates()} days")

      submit_bulk(view, "new")

      assert has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-review-confirm", "Assign 3 trips")
      assert has_element?(view, "#block-review-changes-table", "a1")
      assert has_element?(view, "#block-review-changes-table", "a3")

      html = confirm_review(view)

      block_ids = Enum.map([a1, a2, a3], &persisted(&1).block_id)

      assert hd(block_ids)
      assert length(Enum.uniq(block_ids)) == 1
      assert html =~ "Assigned 3 trips to block #{hd(block_ids)}."
      assert Enum.map([a1, a2, a3], &length(trip_logs(context, &1))) == [1, 1, 1]
    end

    test "a successful command clears the selection and hides the bar",
         %{version: version} = context do
      assign_scope(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      Enum.each(["a1", "a2", "a3"], &toggle_trip(view, &1))
      bulk_assign(view)
      submit_bulk(view, "new")
      confirm_review(view)

      refute has_element?(view, "#blocks-bulk-bar")
      refute has_element?(view, "#bulk-count")
      refute has_element?(view, "#bulk-assign-dialog")
      refute has_element?(view, "#block-review[data-open='true']")
      assert element_count(view, "[data-role='select-trip'][checked]") == 0
    end

    test "“Cancel” in the bulk dialog keeps the selection",
         %{version: version} = context do
      [a1 | _rest] = assign_scope(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      toggle_trip(view, "a1")
      bulk_assign(view)

      assert has_element?(view, "#bulk-assign-dialog[data-open='true']")

      view |> element("#bulk-assign-dialog-cancel") |> render_click()

      refute has_element?(view, "#bulk-assign-dialog")
      assert has_element?(view, "#blocks-bulk-bar")
      assert bulk_count(view) == "1 selected"
      assert is_nil(persisted(a1).block_id)
    end
  end

  describe "an ineligible selection" do
    setup :editor_scope

    test "the frequency trip is named with its reason and “Use eligible trips” keeps the dialog open",
         %{version: version} = context do
      %{frequency: frequency, ok: ok} = ineligible_scope(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      toggle_trip(view, "ok_1")
      toggle_trip(view, "freq_1")

      assert bulk_count(view) == "2 selected"

      bulk_assign(view)

      assert has_element?(view, "#bulk-ineligible", "1 selected trip can't be assigned.")

      assert has_element?(
               view,
               "#bulk-ineligible",
               "No trips will change until every selected trip can be assigned."
             )

      assert has_element?(
               view,
               "#bulk-ineligible [data-role='ineligible-trip'][data-trip='freq_1']",
               "freq_1 · repeats every 20 min"
             )

      assert has_element?(view, "#bulk-use-eligible", "Use eligible trips")

      view |> element("#bulk-use-eligible") |> render_click()

      # The dialog stays open on the eligible trip alone and the selection now
      # holds only what can be assigned.
      assert has_element?(view, "#bulk-assign-dialog[data-open='true']")
      assert has_element?(view, "#assign-form")
      refute has_element?(view, "#bulk-ineligible")
      assert bulk_count(view) == "1 selected"
      assert has_element?(view, "#blocks-bulk-bar", "1 selected")

      submit_bulk(view, "new")

      refute has_element?(view, "#block-review[data-open='true']")
      assert persisted(ok).block_id
      assert is_nil(persisted(frequency).block_id)
      assert [log] = trip_logs(context, ok)
      assert log.changed_fields["after"]["block_id"] == persisted(ok).block_id
    end

    test "submitting an ineligible selection writes nothing and keeps the reason",
         %{version: version} = context do
      %{frequency: frequency, ok: ok} = ineligible_scope(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?panel=pool")

      toggle_trip(view, "ok_1")
      toggle_trip(view, "freq_1")
      bulk_assign(view)
      submit_bulk(view, "new")

      # The context refuses the whole command; the page names the trip that
      # refused it and writes neither trip's block.
      assert has_element?(
               view,
               "#bulk-ineligible [data-role='ineligible-trip'][data-trip='freq_1']",
               "repeats every 20 min"
             )

      assert has_element?(view, "#bulk-assign-dialog[data-open='true']")
      refute has_element?(view, "#block-review[data-open='true']")
      assert is_nil(persisted(ok).block_id)
      assert is_nil(persisted(frequency).block_id)
      assert trip_logs(context, ok) == []
      assert trip_logs(context, frequency) == []
    end
  end

  describe "bulk removing a selection" do
    setup :editor_scope

    test "two blocked trips are reviewed and removed to the pool",
         %{version: version} = context do
      blocked_scope(context)
      conn = editor_conn(context)
      base = blocks_path(version.id)

      {:ok, view, _html} = live(conn, base <> "?view=list")

      toggle_trip(view, "201_0")
      toggle_trip(view, "202_0")

      assert bulk_count(view) == "2 selected"
      assert has_element?(view, "#bulk-remove", "Remove from block")

      bulk_remove(view)

      assert has_element?(view, "#block-review[data-open='true']")
      assert has_element?(view, "#block-review-confirm", "Remove 2 trips")

      html = confirm_review(view)

      assert html =~ "Removed 2 trips from their blocks."
      refute has_element?(view, "#blocks-bulk-bar")

      assert {:ok, day} =
               Gtfs.load_blocking_day(context.organization.id, context.version.id, nil)

      assert Enum.map(day.pool, & &1.trip_id) == ["201_0", "202_0"]
    end

    test "“Select this page” in the List view selects the page's block trips",
         %{version: version} = context do
      blocked_scope(context)
      conn = editor_conn(context)

      {:ok, view, _html} = live(conn, blocks_path(version.id) <> "?view=list")

      select_page(view)

      assert bulk_count(view) == "3 selected"
      assert element_count(view, "#blocks-lists [data-role='select-trip'][checked]") == 3

      clear_selection(view)

      refute has_element?(view, "#blocks-bulk-bar")
      assert element_count(view, "#blocks-lists [data-role='select-trip'][checked]") == 0
    end
  end
end

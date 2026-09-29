defmodule GtfsPlannerWeb.Gtfs.BlocksFiguresLiveTest do
  # EV-28, rejecting FH-28 for CL-28: the plan figures in the count strip and the
  # page-level fleet notices, read through the ordinary `/gtfs/:version/blocks`
  # route on the production `CatalogReadAdapter.Repo` and the scoped `Blocking`
  # context. Rows are created inside the SQL Sandbox transaction and rolled
  # back; nothing here substitutes an adapter or hand-builds a day.
  #
  # The four blocks below are the fixture every figure in this file is arithmetic
  # over. Each block runs one 40-minute trip out of the "Main" garage with a
  # 10-minute entered pull-out and a 10-minute entered pull-back, so a block's
  # platform span is 05:50–06:50 and its service is 2,400 s:
  #
  #   * vehicles      4 — the day's block count
  #   * minimum       4 — the lower bound over four trips that all overlap at
  #                      06:00, each extended by the default 5-minute layover
  #   * riders       67% — 9,600 s of service over 14,400 s of platform time
  #   * peak out      4 at 06:05 — the earliest instant all four spans are open
  #
  # The card's own literals (57% and 06:08) are the prototype's own figures for
  # its own sample day, not this fixture's; the expectations below are the
  # arithmetic above, so they would fail if the page re-derived a figure of its
  # own rather than printing `Blocking`'s.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_figures_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  # One trip per block, all four pulling out of "Main" ten minutes before their
  # own departure and returning ten minutes after their own arrival.
  @blocks [
    {"T1", "101", "06:00:00", "06:40:00"},
    {"T2", "102", "06:05:00", "06:45:00"},
    {"T3", "103", "06:10:00", "06:50:00"},
    {"T4", "104", "06:15:00", "06:55:00"}
  ]

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    route = route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "1"})

    # The second route carries a trip inside block 101, so a route filter hides
    # part of the day without changing what the day type needs.
    other = route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    for {stop_id, lat, lon} <- [
          {"S1", "40.0000", "-74.0000"},
          {"S2", "40.0100", "-74.0000"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })
    end

    %{
      organization: organization,
      user: user,
      version: version,
      route: route,
      other: other
    }
  end

  describe "the plan figures" do
    test "the strip shows the three figures after the built counts and a divider",
         %{version: version} = context do
      seed_plan!(context, vehicles: 4)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      # The built four keep their own strip, and the divider sits between them.
      assert has_element?(view, "#blocks-summary-counts")
      assert has_element?(view, "#blocks-summary-figures")
      assert has_element?(view, "#blocks-summary-divider")

      assert item_text(view, "blocks-summary-counts", "blocks") == "Blocks 4"
      assert item_text(view, "blocks-summary-counts", "unassigned") == "Unassigned trips 0"
      assert item_text(view, "blocks-summary-counts", "problems") == "Problems 0"
      assert item_text(view, "blocks-summary-counts", "notices") == "Notices 0"

      assert item_text(view, "blocks-summary-figures", "vehicles") == "Vehicles 4 · minimum 4"

      assert item_text(view, "blocks-summary-figures", "riders") ==
               "Time with riders 67%"

      assert item_text(view, "blocks-summary-figures", "peak") == "Peak out 4 at 06:05"
    end

    test "each figure opens the Plan summary",
         %{version: version} = context do
      seed_plan!(context, vehicles: 4)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      for key <- ["vehicles", "riders", "peak"] do
        assert attribute(view, "#blocks-summary-figures-item-#{key}", "phx-click") ==
                 "open_drawer"

        assert attribute(view, "#blocks-summary-figures-item-#{key}", "phx-value-key") ==
                 "plan_summary"
      end

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "#plan-summary-drawer-overlay[data-open='true']")
    end

    test "the figures are the whole day type's whatever the workspace is showing",
         %{version: version} = context do
      seed_plan!(context, vehicles: 4)

      # A second route's trip inside block 101, after the block's own last
      # arrival, so the day's five trips still fit one vehicle.
      extra_trip!(context, "T12", "101", "06:45:00", "06:55:00")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      assert item_text(view, "blocks-summary-figures", "vehicles") == "Vehicles 4 · minimum 4"
      assert item_text(view, "blocks-summary-figures", "riders") == "Time with riders 67%"
      assert item_text(view, "blocks-summary-figures", "peak") == "Peak out 4 at 06:05"

      # The route filter and “Problems only” describe the workspace, never the
      # day type the strip summarises.
      {:ok, filtered, _html} =
        live(
          editor_conn(%{context | conn: build_conn()}),
          blocks_path(version.id, "?route=12&status=problems")
        )

      assert item_text(filtered, "blocks-summary-figures", "vehicles") == "Vehicles 4 · minimum 4"
      assert item_text(filtered, "blocks-summary-figures", "riders") == "Time with riders 67%"
      assert item_text(filtered, "blocks-summary-figures", "peak") == "Peak out 4 at 06:05"
    end
  end

  describe "the fleet notices" do
    test "a garage short of vehicles says so above the workbench and in Problems",
         %{version: version} = context do
      seed_plan!(context, vehicles: 2)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      assert has_element?(view, "#blocks-fleet-shortfall")

      assert has_element?(
               view,
               "#blocks-fleet-shortfall [data-role='blocks-shortfall-summary']",
               "Main · Cutaway: needs 4 at 06:05, 2 listed."
             )

      # The garage total is its own check against the same demand, and the page
      # says so rather than repeating the typed row.
      assert has_element?(
               view,
               "#blocks-fleet-shortfall [data-role='blocks-shortfall-summary']",
               "Main · All types: needs 4 at 06:05, 2 listed."
             )

      assert has_element?(view, "#blocks-fleet-shortfall-summary", "Open plan summary")

      assert attribute(view, "#blocks-fleet-shortfall-summary", "phx-value-key") == "plan_summary"

      assert attribute(view, "#blocks-fleet-shortfall-fleet-link", "href") =~
               "/settings/fleet"

      # A shortfall is the day's own error finding, so it is counted as a problem
      # rather than hidden behind the count strip's own figure.
      assert item_text(view, "blocks-summary-counts", "problems") == "Problems 2"

      view |> element("#blocks-summary-counts-item-problems") |> render_click()

      assert has_element?(
               view,
               "#checks-drawer-problems [data-role='blocks-finding'][data-code='fleet_shortfall']"
             )
    end

    test "a version with no garage is pointed at the garages, not at a fleet",
         %{version: version} = context do
      seed_plan!(context, garage: false)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      assert has_element?(view, "#blocks-no-garages", "Add a garage to plan travel")
      assert attribute(view, "#blocks-no-garages-link", "href") =~ "/settings/garages"

      refute has_element?(view, "#blocks-no-vehicles")
      refute has_element?(view, "#blocks-fleet-shortfall")
    end

    test "a garage with no vehicles listed is pointed at the fleet",
         %{version: version} = context do
      seed_plan!(context, vehicles: 0)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      assert has_element?(view, "#blocks-no-vehicles", "Fleet limits aren’t checked.")
      assert attribute(view, "#blocks-no-vehicles-link", "href") =~ "/settings/fleet"

      refute has_element?(view, "#blocks-no-garages")
      refute has_element?(view, "#blocks-fleet-shortfall")
    end
  end

  # The day's plan: `garage: false` leaves the version with no garage at all,
  # `vehicles: n` lists `n` Cutaways against it. A listing that is not smaller
  # than the demand reports no shortfall, so four listed vehicles leave the
  # shortfall notice off.
  defp seed_plan!(context, opts) do
    cutaway = vehicle_type_fixture(context.organization.id, %{"name" => "Cutaway"})

    Enum.each(@blocks, fn {trip, block, first, last} ->
      trip!(context, trip, block, first, last)
    end)

    if Keyword.get(opts, :garage, true) do
      garage_plan!(context, cutaway, Keyword.get(opts, :vehicles, 0))
    end

    cutaway
  end

  defp garage_plan!(context, cutaway, listed) do
    garage = garage_fixture(context.organization.id, %{"name" => "Main"})

    Enum.each(@blocks, fn {_trip, block, _first, _last} ->
      block_attribute_fixture(context.organization.id, context.version.id, %{
        service_id: "WK",
        block_id: block,
        garage_id: garage.id,
        vehicle_type_id: cutaway.id
      })
    end)

    deadhead_time_fixture(context.organization.id, context.version.id, %{
      from_ref: {:garage, garage.id},
      to_ref: {:stop, "S1"},
      minutes: 10
    })

    deadhead_time_fixture(context.organization.id, context.version.id, %{
      from_ref: {:stop, "S2"},
      to_ref: {:garage, garage.id},
      minutes: 10
    })

    for index <- 1..listed//1 do
      vehicle_fixture(context.organization.id, %{
        "vehicle_id" => "V#{index}",
        "garage_id" => garage.id,
        "vehicle_type_id" => cutaway.id
      })
    end

    garage
  end

  defp trip!(context, trip_id, block_id, first, last) do
    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route.route_id,
      %{
        trip_id: trip_id,
        service_id: "WK",
        block_id: block_id,
        first_stop: "S1",
        last_stop: "S2",
        first_arrival: first,
        first_departure: first,
        last_arrival: last,
        last_departure: last
      }
    )
  end

  # A second route's trip inside block 101, so the route filter has something to
  # hide without the day's own blocks changing.
  defp extra_trip!(context, trip_id, block_id, first, last) do
    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.other.route_id,
      %{
        trip_id: trip_id,
        service_id: "WK",
        block_id: block_id,
        first_stop: "S1",
        last_stop: "S2",
        first_arrival: first,
        first_departure: first,
        last_arrival: last,
        last_departure: last
      }
    )
  end

  defp blocks_path(version_id, query \\ ""), do: "/gtfs/#{version_id}/blocks#{query}"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp item_text(view, strip, key) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("##{strip}-item-#{key}")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp attribute(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end
end

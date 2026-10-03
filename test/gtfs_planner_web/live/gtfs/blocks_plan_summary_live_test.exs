defmodule GtfsPlannerWeb.Gtfs.BlocksPlanSummaryLiveTest do
  # The Plan summary drawer that replaced the
  # Peak vehicles drawer, read through the ordinary
  # `/gtfs/:version/blocks` route on the production `CatalogReadAdapter.Repo`
  # and the scoped `Blocking` context. Rows are created inside the SQL Sandbox
  # transaction and rolled back; nothing here substitutes an adapter or
  # hand-builds a day.
  #
  # The fixture is the same four-block day `blocks_figures_live_test.exs` seeds,
  # with each block's garage and type set on a `block_attributes` row and an
  # entered 10-minute drive in each direction:
  #
  #   * vehicles      4 — the day's block count
  #   * minimum       4 — the lower bound over four trips that all overlap at
  #                      06:00, each extended by the default 5-minute layover
  #   * riders       67% — 9,600 s of service over 14,400 s of platform time
  #   * platform     14,400 s — four 60-minute platform spans
  #   * service      9,600 s — four 40-minute trips
  #   * layover          0 s — one trip per block, so no gap is a layover
  #   * drive         800 s — four 20-minute pulls, all entered, so nothing on
  #                      the day is estimated and the `est.` marks stay off
  #
  # Blocks 101–103 resolve to Cutaway and block 104 to 35-ft diesel, so the
  # garage carries three rows: the two typed rows and the garage total. With one
  # Cutaway listed the typed row is short by two, and the chart is that row's
  # because it is the first short row.
  #
  # The expectations below are the arithmetic above, so they would fail if the
  # drawer re-derived a figure of its own rather than printing `Blocking`'s.
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.Gtfs.Blocking
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts

  @blocks [
    {"T1", "101", "06:00:00", "06:40:00", "Cutaway"},
    {"T2", "102", "06:05:00", "06:45:00", "Cutaway"},
    {"T3", "103", "06:10:00", "06:50:00", "Cutaway"},
    {"T4", "104", "06:15:00", "06:55:00", "35-ft diesel"}
  ]

  @typed_blocks [
    {"T1", "101", "06:00:00", "06:40:00", "Cutaway"},
    {"T2", "102", "06:05:00", "06:45:00", "Cutaway"},
    {"T3", "103", "06:10:00", "06:50:00", "Cutaway"}
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
      route: route
    }
  end

  describe "opening the drawer" do
    test "the plan_summary key and the old peak key open the same drawer",
         %{version: version} = context do
      seed_plan!(context, cutaways: 1)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> render_hook("open_drawer", %{"key" => "plan_summary"})
      assert has_element?(view, "#plan-summary-drawer-overlay[data-open='true']")

      view |> render_hook("close_drawer", %{})
      refute has_element?(view, "#plan-summary-drawer-overlay[data-open='true']")

      # The old `peak` key is the same drawer under its old name, so a link
      # written before the rename still opens the plan summary.
      view |> render_hook("open_drawer", %{"drawer" => "peak"})
      assert has_element?(view, "#plan-summary-drawer-overlay[data-open='true']")
    end

    test "closing returns focus to the strip item that opened it",
         %{version: version} = context do
      seed_plan!(context, cutaways: 1)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      # The shared drawer component names the element focus returns to on its
      # overlay dialog, so the return target is asserted there.
      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert attribute(view, "#plan-summary-drawer-overlay", "data-return-focus-id") ==
               "blocks-summary-figures-item-vehicles"

      view |> element("#plan-summary-drawer-close") |> render_click()

      refute has_element?(view, "#plan-summary-drawer-overlay[data-open='true']")
      assert has_element?(view, "#blocks-summary-figures-item-vehicles")
    end
  end

  describe "the figures and their help" do
    test "the drawer reports the day's vehicles, minimum and riders share",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "#plan-summary-vehicles", "4 vehicles used")
      assert has_element?(view, "#plan-summary-minimum", "4")
      assert has_element?(view, "#plan-summary-riders", "67%")

      assert has_element?(
               view,
               "#plan-summary-minimum-help",
               "The minimum is the fewest vehicles these trip times allow with a 5-minute layover."
             )
    end

    test "the figures are the whole day type's whatever the workspace is showing",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(version.id, "?status=problems"))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "#plan-summary-vehicles", "4 vehicles used")
      assert has_element?(view, "#plan-summary-riders", "67%")
    end
  end

  describe "the fleet table" do
    test "the table lists each typed row and the garage total", %{version: version} = context do
      seed_plan!(context, cutaways: 4, diesels: 1)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      # Three Cutaway blocks overlap at 06:00 and the diesel block runs on its
      # own, so the two typed rows and the garage total each report their own
      # peak against their own listing. The order is `Fleet.rows/2`'s (garages,
      # then types by UUID), so a row is looked up by what it says rather than
      # by where it lands.
      assert row_text(view, "Cutaway") == "Main · Cutaway 3 4 06:00"
      assert row_text(view, "35-ft diesel") == "Main · 35-ft diesel 1 1 06:05"

      # The garage total is its own row, muted, so it is never mistaken for a
      # type the plan asks for. It is never the garage's typed listing added up
      # as a demand of its own, so it sums the whole garage's peak.
      assert row_text(view, "All types") == "Main · All types 4 5 06:05"
      assert total_row_attribute(view, "All types", "data-total") == "true"

      assert has_element?(
               view,
               "#plan-summary-fleet-note",
               "Blocks without a type count against their garage’s total."
             )
    end

    test "a version with no garage is told what to add instead", %{version: version} = context do
      seed_plan!(context, cutaways: 0, garage?: false)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "#plan-summary-fleet-no-garage", "Add a garage")
      refute has_element?(view, "#plan-summary-fleet-table")
      refute has_element?(view, "#plan-summary-chart")
    end

    test "a garage with no vehicles listed is pointed at the fleet",
         %{version: version} = context do
      seed_plan!(context, cutaways: 0)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "#plan-summary-fleet-no-vehicles", "No vehicles are listed.")
      assert attribute(view, "#plan-summary-fleet-no-vehicles a", "href") =~ "/settings/fleet"
      refute has_element?(view, "#plan-summary-fleet-table")
    end
  end

  describe "the chart" do
    test "a short row charts its own bins against its own listing",
         %{version: version} = context do
      seed_plan!(context, cutaways: 2, untyped_last?: true)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      # One Cutaway row is short, so the chart is that row: three Cutaway blocks
      # need three Cutaways and one is listed.
      assert has_element?(view, "#plan-summary-chart")
      assert attribute(view, "#plan-summary-listed-line", "data-listed") == "2"
      assert has_element?(view, "#plan-summary-listed-label", "2 listed")

      # Blocks span 05:50–06:55, so the chart is whole-hour 15-minute bins from
      # 05:00 to 07:00.
      assert element_count(view, "#plan-summary-chart [data-role='plan-summary-bar']") == 8

      # The 06:00 bin holds all three Cutaway spans, so it is the tallest bar and
      # it is over the listing.
      assert attribute(view, "#plan-summary-bar-21600", "data-over-listed") == "true"
      assert attribute(view, "#plan-summary-bar-21600", "style") =~ "height: 100%"

      # The 05:45 bin holds two spans, which is the listing exactly, so it is not
      # an error bar and is two thirds of the tallest one.
      assert attribute(view, "#plan-summary-bar-20700", "data-over-listed") == "false"
      assert attribute(view, "#plan-summary-bar-20700", "style") =~ "height: 67%"

      # The listing is drawn on the bars' own scale, so two listed sits at two
      # thirds of the chart rather than off its top.
      assert attribute(view, "#plan-summary-listed-line", "style") =~ "bottom: 67%"

      # The chart's accessible label names the row, its peak and its shortfall,
      # and the window the bins cover.
      assert attribute(view, "#plan-summary-chart", "aria-label") ==
               "Main Cutaway vehicles out by 15 minutes; peak 3 at 06:00; 2 listed." <>
                 " Chart covers 05:00 to 07:00."
    end

    test "the chart's sentence names the row, its peak and its shortfall",
         %{version: version} = context do
      seed_plan!(context, cutaways: 1)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(
               view,
               "#plan-summary-chart-summary",
               "Main · Cutaway: 3 out at the busiest time (06:00); 1 listed."
             )

      assert has_element?(view, "#plan-summary-chart-summary", "2 short.")
    end

    test "a listing above every bar draws its line above them all",
         %{version: version} = context do
      seed_plan!(context, cutaways: 5, untyped_last?: true)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      # The tallest bar is the peak of three, so five listed cannot be drawn on
      # that scale without being clipped; the chart's scale is the taller of the
      # two instead.
      assert attribute(view, "#plan-summary-bar-21600", "data-over-listed") == "false"
      assert attribute(view, "#plan-summary-bar-21600", "style") =~ "height: 60%"
      assert attribute(view, "#plan-summary-listed-line", "style") =~ "bottom: 100%"

      assert has_element?(
               view,
               "#plan-summary-chart-summary",
               "Main · Cutaway: 3 out at the busiest time (06:00); 5 listed."
             )

      refute has_element?(view, "#plan-summary-chart-summary", "short.")
    end
  end

  describe "time and distance" do
    test "the totals print the day's own seconds and kilometres",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      # 14,400 s out of the garage, 9,600 s carrying riders, 0 waiting and
      # 4,800 s driving, so the rows read as hours to one decimal.
      assert total_text(view, "platform") == "4.0"
      assert total_text(view, "service") == "2.7"
      assert total_text(view, "layover") == "0.0"
      assert total_text(view, "drive") == "1.3"

      assert has_element?(view, "[data-role='plan-summary-total-service_km']", "km")
      assert has_element?(view, "[data-role='plan-summary-total-deadhead_km']", "km")

      assert has_element?(
               view,
               "#plan-summary-time-note",
               "Includes travel to and from the garage."
             )
    end

    test "every drive on this day is entered, so nothing is marked est.",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      refute has_element?(
               view,
               "[data-role='plan-summary-total-drive'] [data-role='plan-summary-est']"
             )

      refute has_element?(
               view,
               "[data-role='plan-summary-total-deadhead_km'] [data-role='plan-summary-est']"
             )
    end

    test "an estimated drive is marked est. on the time and the distance",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4, entered_drives?: false, untyped_last?: true)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "[data-role='plan-summary-total-drive']", "est.")
      assert has_element?(view, "[data-role='plan-summary-total-deadhead_km']", "est.")

      # The trip times themselves are not estimates, so they are never marked.
      refute has_element?(
               view,
               "[data-role='plan-summary-total-platform'] [data-role='plan-summary-est']"
             )

      refute has_element?(
               view,
               "[data-role='plan-summary-total-service'] [data-role='plan-summary-est']"
             )
    end

    test "an error in the day makes the totals provisional", %{version: version} = context do
      seed_plan!(context, cutaways: 1)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      # The shortfall is the day's own error finding, so the totals that rest on
      # the same fleet are marked provisional rather than presented as final.
      assert has_element?(view, "#plan-summary-time-note", "Totals are provisional while errors")
    end
  end

  describe "operator changes" do
    test "with no limit set the section says it is not checked",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "#plan-summary-relief-off", "Not checked.")
      refute has_element?(view, "#plan-summary-relief-limit")
    end

    test "with a limit set the section names the longest stretch and its block",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      # A second trip inside block 101 stretches it to 05:50–07:50, so its
      # longest unrelieved run is two hours and a one-hour limit is shorter than
      # that. S1 and S2 are marked so the run between them really is unrelieved.
      long_trip!(context, "T1B", "101", "06:40:00", "07:40:00")

      update_settings(editor_audit_fixture(context.organization.id, version.id), %{
        max_piece_minutes: 60
      })

      relief_point_fixture(context.organization.id, version.id, %{stop_id: "S1"})
      relief_point_fixture(context.organization.id, version.id, %{stop_id: "S2"})

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      refute has_element?(view, "#plan-summary-relief-off")

      assert has_element?(view, "[data-role='plan-summary-relief-longest']", "2 h in block 101")
      assert has_element?(view, "#plan-summary-relief-note", "Limit 1 h · 2 stops marked.")

      assert has_element?(
               view,
               "#plan-summary-relief-note",
               "Block 101 has no place to change operators for 2 h."
             )
    end

    test "a limit longer than every stretch names no block",
         %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      update_settings(editor_audit_fixture(context.organization.id, version.id), %{
        max_piece_minutes: 330
      })

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      assert has_element?(view, "[data-role='plan-summary-relief-longest']", "1 h in block 101")
      assert has_element?(view, "#plan-summary-relief-note", "Limit 5 h 30 min · 0 stops marked.")

      refute has_element?(view, "#plan-summary-relief-note", "no place to change operators")
    end

    test "a limit over an hour reads as whole hours", %{version: version} = context do
      seed_plan!(context, cutaways: 4)

      update_settings(editor_audit_fixture(context.organization.id, version.id), %{
        max_piece_minutes: 600
      })

      {:ok, view, _html} = live(editor_conn(context), blocks_path(version.id))

      view |> element("#blocks-summary-figures-item-vehicles") |> render_click()

      # 600 stored minutes is 10 h. The limit is stored in minutes and the
      # canonical duration helper takes seconds, so a caller that forgot the
      # conversion would read "10 min" here.
      assert has_element?(view, "#plan-summary-relief-note", "Limit 10 h · 0 stops marked.")
    end
  end

  # The day's plan: one garage named "Main" and two vehicle types. `cutaways` and
  # `diesels` list that many vehicles against the garage, `garage?: false`
  # leaves the version with no garage at all, and `entered_drives?: false`
  # leaves the pulls estimated rather than entered.
  defp seed_plan!(context, opts) do
    cutaway = vehicle_type_fixture(context.organization.id, %{"name" => "Cutaway"})
    diesel = vehicle_type_fixture(context.organization.id, %{"name" => "35-ft diesel"})

    garage =
      if Keyword.get(opts, :garage?, true) do
        # The garage sits on S1, so an estimated drive is a short one rather than
        # the cross-state run a default garage's coordinates would give.
        garage_fixture(context.organization.id, %{
          "name" => "Main",
          "lat" => Decimal.new("40.0000"),
          "lon" => Decimal.new("-74.0000")
        })
      end

    # The chart focuses one typed row and `Fleet.rows/2` orders types by UUID, so
    # a two-type day leaves which row is focused up to the fixture's random IDs.
    # `:untyped_last?` gives the fourth block no type, which puts it on the
    # garage's `:all` row instead: Cutaway is then the only typed row, and the
    # counts these cases assert are the ones the two-type day already gives.
    untyped_last? = Keyword.get(opts, :untyped_last?, false)
    blocks = if untyped_last?, do: @typed_blocks, else: @blocks

    Enum.each(blocks, fn {trip, block, first, last, type} ->
      trip!(context, trip, block, first, last)

      if garage do
        block_attribute_fixture(context.organization.id, context.version.id, %{
          service_id: "WK",
          block_id: block,
          garage_id: garage.id,
          vehicle_type_id: type_id(type, cutaway, diesel)
        })
      end
    end)

    if garage && Keyword.get(opts, :entered_drives?, true), do: enter_drives!(context, garage)

    if garage do
      list_vehicles!(context, garage, Keyword.get(opts, :cutaways, 0), cutaway)
      list_vehicles!(context, garage, Keyword.get(opts, :diesels, 0), diesel)
    end

    cutaway
  end

  defp type_id("Cutaway", cutaway, _diesel), do: cutaway.id
  defp type_id(_other, _cutaway, diesel), do: diesel.id

  defp enter_drives!(context, garage) do
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
  end

  defp list_vehicles!(_context, _garage, 0, _type), do: :ok

  defp list_vehicles!(context, garage, count, type) do
    for index <- 1..count//1 do
      vehicle_fixture(context.organization.id, %{
        "vehicle_id" => "#{type.name}-#{index}",
        "garage_id" => garage.id,
        "vehicle_type_id" => type.id
      })
    end

    :ok
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

  defp long_trip!(context, trip_id, block_id, first, last) do
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

  defp blocks_path(version_id, query \\ ""), do: "/gtfs/#{version_id}/blocks#{query}"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  # One fleet row as one line of text, so an assertion reads as the table does:
  # garage · type, needed, listed, when. The row is found by its type name
  # because `Fleet.rows/2` orders types by UUID, not by name.
  defp row_text(view, type) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tr[data-role='plan-summary-fleet-row']")
    |> Enum.find_value("", fn row ->
      if String.contains?(LazyHTML.text(row), "· #{type}") do
        # The cells are read one at a time: concatenated cell text runs the
        # "When" clock into the "Listed" number.
        row
        |> LazyHTML.query("td")
        |> Enum.map_join(
          " ",
          &(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim())
        )
        |> String.trim()
      end
    end)
  end

  defp total_row_attribute(view, type, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("tr[data-role='plan-summary-fleet-row']")
    |> Enum.find_value(nil, fn row ->
      if String.contains?(LazyHTML.text(row), "· #{type}"),
        do: LazyHTML.attribute(row, name) |> List.first()
    end)
  end

  defp total_text(view, key) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='plan-summary-total-#{key}']")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp element_count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
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

defmodule GtfsPlannerWeb.Gtfs.BlocksColumnsLiveTest do
  # The timeline's Garage · type, Time out,
  # Hours and Status columns, the two new sort keys and the List view's distance
  # figures, read through the ordinary `/gtfs/:version/blocks` route on the
  # production `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows
  # are created inside the SQL Sandbox transaction and rolled back; nothing here
  # substitutes an adapter or hand-builds a summary.
  #
  # The garage and type names come from the one resolution
  # (`Blocking.Context.resolve_block/3`) and the Time out span from
  # `Blocking.Movements.build/3`, so a cell that disagreed with the day would
  # fail here rather than in a browser. The failures worth catching are "a conflict
  # shows one garage, a status label is missing, or the sort covers only the
  # page", so each case reads the whole rendered header, the row's own cells and the row order.
  #
  # Every expected time is an entered driving time or a fixture clock, never an
  # estimate: Main → S1 is 2 minutes and S1 → Main is 3, so block 101's platform
  # span is 05:48–08:33 and the overnight block's is 23:45 −1d–01:33 +1d. The
  # kilometre figures are only required to be the block's own positive movement
  # totals, which the day load already asserts as literals elsewhere.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Blocking

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

    # Two services on the same dates, so they share one day type and a block can
    # carry one attribute row per calendar — the garage conflict.
    for {service_id, name} <- [{"WK", "Weekday"}, {"WK2", "Weekday 2"}] do
      calendar_service_fixture(organization.id, version.id, %{service_id: service_id, name: name})
    end

    # Four stops on one meridian a hundredth of a degree apart, so every trip is
    # plottable and every pull has a real distance; a stop ninety kilometres
    # north is the drive a block cannot make.
    for {stop_id, lat} <- [{"S1", "40.0000"}, {"S2", "40.0100"}, {"S3", "40.0200"}] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0")
      })
    end

    far =
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: "FAR",
        stop_lat: Decimal.new("41.0000"),
        stop_lon: Decimal.new("-74.0")
      })

    main = garage_fixture(organization.id, %{"name" => "Main"})
    north = garage_fixture(organization.id, %{"name" => "North"})

    cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})
    diesel = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})

    # Main → S1 and S1 → Main are entered, so block 101's pull-out and pull-back
    # are exact minutes rather than a function of the distance estimate.
    for {from_ref, to_ref, minutes} <- [
          {{:garage, main.id}, {:stop, "S1"}, 2},
          {{:stop, "S1"}, {:garage, main.id}, 3},
          {{:garage, main.id}, {:stop, "FAR"}, 15}
        ] do
      deadhead_time_fixture(organization.id, version.id, %{
        from_ref: from_ref,
        to_ref: to_ref,
        minutes: minutes
      })
    end

    %{
      organization: organization,
      user: user,
      version: version,
      route: route,
      far: far,
      main: main,
      north: north,
      cutaway: cutaway,
      diesel: diesel
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  # One trip from `first_stop` at `first` to `last_stop` at `last`, on `service_id`.
  defp trip!(context, trip_id, block_id, first, last, first_stop, last_stop, opts \\ []) do
    %{organization: organization, version: version, route: route} = context

    blocked_trip_fixture(organization.id, version.id, route.route_id, %{
      trip_id: trip_id,
      service_id: Keyword.get(opts, :service_id, "WK"),
      block_id: block_id,
      first_stop: first_stop,
      first_arrival: first,
      first_departure: first,
      last_stop: last_stop,
      last_arrival: last,
      last_departure: last
    })
  end

  defp block_attribute!(context, block_id, garage_id, type_id, opts \\ []) do
    %{organization: organization, version: version} = context

    block_attribute_fixture(organization.id, version.id, %{
      service_id: Keyword.get(opts, :service_id, "WK"),
      block_id: block_id,
      garage_id: garage_id,
      vehicle_type_id: type_id
    })
  end

  defp headers(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-timeline thead th.blocks-meta")
    |> LazyHTML.text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp row_blocks(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-timeline tbody tr")
    |> LazyHTML.attribute("data-block")
  end

  defp cell(view, block_id, class) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#blocks-timeline tbody tr[data-block='#{block_id}'] .#{class}")
    |> LazyHTML.text()
    |> String.trim()
  end

  defp status_cell(view, block_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "#blocks-timeline tbody tr[data-block='#{block_id}'] [data-role='block-status']"
    )
    |> LazyHTML.text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  describe "the timeline's header" do
    test "reads Block, Garage · type, Time out, Hours and Status", context do
      trip!(context, "a", "101", "08:00:00", "09:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      # The row-select column has no visible label, and the Block column carries the
      # current sort arrow.
      assert headers(view) == "Block ↑ Garage · type Time out Hours Status"

      # The three removed columns are gone from the header and from every row.
      refute has_element?(view, "th.blocks-meta-trips")
      refute has_element?(view, "th.blocks-meta-start")
      refute has_element?(view, "th.blocks-meta-end")
      refute has_element?(view, "#blocks-timeline td.blocks-meta-trips")
      refute has_element?(view, "#blocks-timeline td.blocks-meta-start")
      refute has_element?(view, "#blocks-timeline td.blocks-meta-end")
    end

    test "sorts by Garage · type and by Time out, with the direction in aria-sort", context do
      block_attribute!(context, "301", context.north.id, nil)
      block_attribute!(context, "302", context.main.id, context.cutaway.id)
      block_attribute!(context, "303", context.main.id, nil)

      trip!(context, "a", "301", "07:00:00", "08:00:00", "S1", "S2")
      trip!(context, "b", "302", "08:00:00", "09:00:00", "S1", "S2")
      trip!(context, "c", "303", "09:00:00", "10:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      view |> element("button[phx-value-key='garage']") |> render_click()

      # Garage name first, then the type's name: Main's Any type block, then
      # Main's Cutaway block, then North. The sort covers the whole day type, not
      # the page, which is why it returns to page 1.
      assert_patch(view, blocks_path(context.version.id) <> "?sort=garage")
      assert has_element?(view, "th[aria-sort='ascending']", "Garage · type")
      assert row_blocks(view) == ["303", "302", "301"]

      view |> element("button[phx-value-key='garage']") |> render_click()

      assert_patch(view, blocks_path(context.version.id) <> "?sort=garage&dir=desc")
      assert row_blocks(view) == ["301", "302", "303"]

      # Time out sorts by the platform start: 303 leaves last, so it leads the
      # descending order and trails the ascending one.
      view |> element("button[phx-value-key='out']") |> render_click()

      assert_patch(view, blocks_path(context.version.id) <> "?sort=out")
      assert has_element?(view, "th[aria-sort='ascending']", "Time out")
      assert row_blocks(view) == ["301", "302", "303"]

      view |> element("button[phx-value-key='out']") |> render_click()

      assert_patch(view, blocks_path(context.version.id) <> "?sort=out&dir=desc")
      assert row_blocks(view) == ["303", "302", "301"]
    end
  end

  describe "the Garage · type cell" do
    test "names the resolved garage and type, or says it has none", context do
      block_attribute!(context, "101", context.main.id, context.cutaway.id)
      trip!(context, "a", "101", "08:00:00", "09:00:00", "S1", "S2")

      # No attribute row and no route garage: nothing resolves, so the cell says
      # so rather than printing a blank.
      trip!(context, "b", "102", "09:00:00", "10:00:00", "S1", "S2")

      # A garage with no type of its own, and a route that requires none.
      block_attribute!(context, "103", context.main.id, nil)
      trip!(context, "c", "103", "10:00:00", "11:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert cell(view, "101", "blocks-meta-garage") == "Main · Cutaway"
      # A block with no garage still has a type to name, and the column reads
      # "garage · type" in both cases, so the type is spelled out here.
      assert cell(view, "102", "blocks-meta-garage") == "No garage · Any type"
      assert cell(view, "103", "blocks-meta-garage") == "Main · Any type"

      # The muted class is the difference between "no garage" and a name, so the
      # two cannot be confused by colour alone.
      assert has_element?(view, "tr[data-block='102'] .blocks-meta-garage-none")
      refute has_element?(view, "tr[data-block='101'] .blocks-meta-garage-none")
    end

    test "prints Differs and the warning class when the block's calendars disagree", context do
      block_attribute!(context, "104", context.main.id, context.cutaway.id)
      block_attribute!(context, "104", context.north.id, context.cutaway.id, service_id: "WK2")

      # The two calendars' trips do not overlap, so the conflict warning is the
      # block's only finding and the Status cell names it rather than Overlap.
      trip!(context, "a", "104", "08:00:00", "09:00:00", "S1", "S2")
      trip!(context, "b", "104", "10:00:00", "11:00:00", "S1", "S2", service_id: "WK2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      # The conflict names neither of the two garages: the word is the answer,
      # and the status cell carries the same finding.
      assert cell(view, "104", "blocks-meta-garage") == "Differs · Cutaway"
      assert has_element?(view, "tr[data-block='104'] .blocks-meta-garage-conflict")
      assert status_cell(view, "104") =~ "Garage differs"
    end
  end

  describe "the Time out cell" do
    test "prints the platform span, not the trip span", context do
      block_attribute!(context, "101", context.main.id, context.cutaway.id)

      # The first trip leaves at 05:50 and the entered pull-out is 2 minutes, so
      # the span starts at 05:48; the last trip arrives at 08:30 and the entered
      # pull-back is 3, so it ends at 08:33. A cell that read the trip span would
      # print 05:50–08:30.
      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      trip!(context, "b", "101", "08:00:00", "08:30:00", "S3", "S1")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert cell(view, "101", "blocks-meta-out") == "05:48–08:33"
      assert cell(view, "101", "blocks-meta-hours") == "2.8"
    end

    test "prints the day before and the day after midnight", context do
      block_attribute!(context, "105", context.main.id, context.cutaway.id)

      # The entered pull-out from Main to the far stop is 15 minutes and the trip
      # leaves at 00:00, so the span starts at 23:45 the day before. The last
      # trip arrives at 23:58 and the entered pull-back is 3 minutes, so the span
      # ends at 00:01 the day after: both ends sit outside the service day, which
      # is what the two day markers are for.
      trip!(context, "a", "105", "00:00:00", "00:30:00", "FAR", "S1")
      trip!(context, "b", "105", "22:00:00", "23:58:00", "S1", "S1")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert cell(view, "105", "blocks-meta-out") == "23:45 −1d–00:01 +1d"
    end

    test "prints the trip span of a block no garage resolves", context do
      trip!(context, "a", "106", "08:00:00", "09:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert cell(view, "106", "blocks-meta-out") == "08:00–09:00"
    end
  end

  describe "the Status cell" do
    setup context do
      # The route needs a type no block but one has, and the 60-minute operator
      # change limit turns a long unrelieved stretch into a warning.
      # The route requires the diesel type, so a block resolving a Cutaway is the
      # Wrong type error and a block resolving the diesel is not.
      route_operating_setting_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        garage_id: context.main.id,
        required_vehicle_type_id: context.diesel.id
      })

      Blocking.update_settings(
        context.organization.id,
        context.version.id,
        %{max_piece_minutes: 60}
      )

      # 201 resolves a Cutaway the route's type contradicts: Wrong type.
      block_attribute!(context, "201", context.main.id, context.cutaway.id)
      trip!(context, "a", "201", "06:00:00", "06:30:00", "S1", "S2")

      # 202 has the right type and no relief mark, so its whole platform stretch
      # is over the limit: No operator change.
      block_attribute!(context, "202", context.main.id, context.diesel.id)
      trip!(context, "b", "202", "06:00:00", "06:30:00", "S1", "S2")
      trip!(context, "c", "202", "08:00:00", "08:30:00", "S3", "S1")

      # 203's second trip is ninety kilometres from the first's end with ten
      # minutes between them: Can't reach.
      block_attribute!(context, "203", context.main.id, context.diesel.id)
      trip!(context, "d", "203", "06:00:00", "07:00:00", "S1", "S2")
      trip!(context, "e", "203", "07:10:00", "08:00:00", "FAR", "S1")

      # 204's two calendars disagree, and its platform span stays inside the
      # 60-minute limit because it pulls back from S1 on the entered three
      # minutes, so Garage differs is the worst finding it has.
      block_attribute!(context, "204", context.main.id, context.diesel.id)
      block_attribute!(context, "204", context.north.id, context.diesel.id, service_id: "WK2")
      trip!(context, "f", "204", "09:00:00", "09:20:00", "S1", "S2")
      trip!(context, "g", "204", "09:30:00", "09:50:00", "S1", "S1", service_id: "WK2")

      :ok
    end

    test "prints each code's Copy label with its icon", context do
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert status_cell(view, "201") =~ "Wrong type"
      assert status_cell(view, "202") =~ "No operator change"
      assert status_cell(view, "203") =~ "Can't reach"
      assert status_cell(view, "204") =~ "Garage differs"

      # Each label carries an icon, so a status is not identified by its colour
      # alone. `CoreComponents.icon/1` renders a Heroicon as a classed span, so
      # that is what the icon is and not an inline `<svg>`. The icon is chosen by
      # severity rather than per code, so the two errors and the two warnings
      # share one each.
      icons =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          "#blocks-timeline tbody [data-role='block-status'] span[class*='hero-']"
        )
        |> LazyHTML.attribute("class")

      assert length(icons) == 4
      assert Enum.all?(icons, &(&1 =~ "size-4 shrink-0"))

      assert Enum.map(icons, &(&1 =~ "hero-x-circle")) ==
               [true, false, true, false]

      assert Enum.map(icons, &(&1 =~ "hero-exclamation-triangle")) ==
               [false, true, false, true]
    end
  end

  describe "the List view" do
    test "keeps the trips and adds the block's two distance figures", context do
      block_attribute!(context, "101", context.main.id, context.cutaway.id)
      trip!(context, "a", "101", "05:50:00", "06:50:00", "S1", "S2")
      trip!(context, "b", "101", "08:00:00", "08:30:00", "S3", "S1")

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?view=list")

      # The trip table is unchanged: the block's two trips and the one gap
      # between them.
      assert has_element?(view, "[data-role='list-block']", "101")
      assert has_element?(view, "table th", "Trip")
      assert has_element?(view, "td strong", "a")
      assert has_element?(view, "td strong", "b")
      assert count(view, "table tbody tr") == 2
      assert count(view, "[data-role='list-gap']") == 1

      # The two figures are the block's own movement totals, in kilometres, and
      # the one without riders is an estimate.
      assert km(view, "list-km-riders") > 0.0
      assert km(view, "list-km-deadhead") > 0.0
      assert has_element?(view, "[data-role='list-km-riders']", "km with riders")
      assert has_element?(view, "[data-role='list-km-deadhead']", "km without (est.)")
    end
  end

  defp count(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp km(view, role) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-role='#{role}']")
    |> LazyHTML.attribute("data-km")
    |> List.first()
    |> String.to_float()
  end
end

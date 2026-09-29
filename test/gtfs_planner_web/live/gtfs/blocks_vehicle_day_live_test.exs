defmodule GtfsPlannerWeb.Gtfs.BlocksVehicleDayLiveTest do
  # EV-30, rejecting FH-30 for CL-30: the block drawer as the vehicle's day, read
  # through the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes an
  # adapter, a context or a hand-built movement.
  #
  # The fixture is the reference's own block 101 at its own geometry: a Main
  # garage, three trips between Riverside Station, Valley College and Market
  # Square, an 8-minute gap the vehicle needs 14 minutes to cover, and a 22-minute
  # wait at the marked Riverside Station. Every driving time is an *entered* row in
  # `deadhead_times`, so the row times and the `! Needs` numbers are the fixture's
  # own minutes rather than an estimate over its geometry; the one case that needs
  # an estimate says `est.` and asserts the mark rather than a distance.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_vehicle_day_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking
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

    riverside =
      route_fixture(organization.id, version.id, %{route_id: "R12", route_short_name: "12"})

    crosstown =
      route_fixture(organization.id, version.id, %{route_id: "R24", route_short_name: "24"})

    # One meridian, a hundredth of a degree apart, so every leg has a real
    # distance and a real estimate; two platforms of the one station share a point
    # the way the reference's Riverside Station does.
    for {stop_id, name, lat} <- [
          {"AB_RS_A", "Riverside Station", "40.0100"},
          {"AB_RS_B", "Riverside Station", "40.0100"},
          {"AB_VALLEY", "Valley College", "40.0200"},
          {"AB_MKT", "Market Square", "40.0300"}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: name,
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new("-74.0000")
      })
    end

    main =
      garage_fixture(organization.id, %{"name" => "Main", "lat" => "40.0000", "lon" => "-74.0000"})

    block_attribute_fixture(organization.id, version.id, %{
      service_id: "WK",
      block_id: "101",
      garage_id: main.id
    })

    %{
      organization: organization,
      user: user,
      version: version,
      main: main,
      riverside: riverside,
      crosstown: crosstown
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp trip!(context, route, attrs) do
    attrs = Map.new(attrs)
    {first, attrs} = Map.pop(attrs, :first, "06:00:00")
    {last, attrs} = Map.pop(attrs, :last, "07:00:00")

    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      route.route_id,
      attrs
      |> Map.merge(%{
        service_id: "WK",
        block_id: "101",
        first_stop: "AB_RS_A",
        last_stop: "AB_VALLEY"
      })
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_departure, last)
    )
  end

  # The reference's block 101: 06:00 and 07:40 out of Riverside Station, the
  # 06:43 Crosstown out of Market Square between them, and an 8-minute gap the
  # vehicle needs 14 minutes to cover.
  defp block_101!(context) do
    first =
      trip!(context, context.riverside, %{trip_id: "6101", first: "06:00:00", last: "06:35:00"})

    second =
      trip!(context, context.crosstown, %{
        trip_id: "8101",
        first_stop: "AB_MKT",
        last_stop: "AB_RS_B",
        first: "06:43:00",
        last: "07:18:00"
      })

    third =
      trip!(context, context.riverside, %{trip_id: "6103", first: "07:40:00", last: "08:15:00"})

    %{first: first, second: second, third: third}
  end

  # Entered minutes, one direction at a time: A→B says nothing about B→A.
  defp drive!(context, from_ref, to_ref, minutes) do
    deadhead_time_fixture(context.organization.id, context.version.id, %{
      from_ref: from_ref,
      to_ref: to_ref,
      minutes: minutes
    })
  end

  defp entered_day!(context) do
    drive!(context, {:garage, context.main.id}, {:stop, "AB_RS_A"}, 12)
    drive!(context, {:stop, "AB_VALLEY"}, {:garage, context.main.id}, 7)
    drive!(context, {:stop, "AB_VALLEY"}, {:stop, "AB_MKT"}, 14)
    block_101!(context)
  end

  defp text(view, selector) do
    view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp attributes(view, selector, name) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
  end

  defp activities(view) do
    texts(view, "#block-day tr[data-role='block-day-row'] td:nth-child(2)")
  end

  defp times(view) do
    texts(view, "#block-day tr[data-role='block-day-row'] td:nth-child(1)")
  end

  describe "the vehicle's day" do
    test "the summary line carries the count, the platform span, the hours and both totals",
         context do
      entered_day!(context)

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      summary = text(view, "#block-day-summary")

      # The span is the platform span, so the pull-out before the first departure
      # and the pull-back after the last arrival are inside the range.
      assert summary =~ "3 trips"
      assert summary =~ "05:48–08:22"
      assert summary =~ "2.6 h out of the garage"
      assert summary =~ ~r/\d+\.\d km with riders/
      # Every leg is entered, so no kilometre is an estimate and the mark is absent.
      assert summary =~ "0.0 km without"
      refute summary =~ "est."
    end

    test "the rows are the vehicle's day in the order it happens", context do
      entered_day!(context)

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      assert activities(view) == [
               "Leave Main garage",
               "Trip 6101 · route 12",
               "Drive to Market Square",
               "Trip 8101 · route 24",
               "Wait at Riverside Station",
               "Trip 6103 · route 12",
               "Return to Main garage"
             ]

      assert times(view) == [
               "05:48",
               "06:00–06:35",
               "06:35",
               "06:43–07:18",
               "07:18",
               "07:40–08:15",
               "08:22"
             ]

      # The pull-out names the stop it reaches and the pull-back has none to name.
      assert has_element?(view, "#block-day tr[data-kind='leave']", "12 min to Riverside Station")
      assert has_element?(view, "#block-day tr[data-kind='return']", "7 min")

      # A drive the vehicle cannot make in time says both numbers, in the error
      # colour rather than as a claim it could make the connection.
      drive = "#block-day tr[data-kind='drive']"
      assert has_element?(view, drive, "! Needs 14 min; has 8")
      assert has_element?(view, drive, "text-error")

      assert has_element?(view, "#block-day tr[data-kind='wait']", "22 min")
    end

    test "an estimated leg is marked and a block with no garage has no pull rows", context do
      # No entered driving time at all, so every leg is the geometry's estimate and
      # the kilometres without riders are the estimated legs' straight lines.
      block_101!(context)

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      assert has_element?(view, "#block-day-summary", "(est.)")
      assert has_element?(view, "#block-day tr[data-kind='leave']", "est.")
      assert has_element?(view, "#block-day tr[data-kind='drive']", "est.")

      # A block whose calendars name no garage has nowhere to pull from, so the
      # table starts at its first trip rather than inventing a leg.
      Repo.delete_all(from(a in BlockAttribute, where: a.block_id == "101"))

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      refute has_element?(view, "#block-day tr[data-kind='leave']")
      refute has_element?(view, "#block-day tr[data-kind='return']")
      assert has_element?(view, "#block-day tr[data-kind='trip']", "Trip 6101 · route 12")
    end

    test "a wait at a marked stop carries the operator-change mark once a limit is set",
         context do
      entered_day!(context)
      relief_point_fixture(context.organization.id, context.version.id, %{stop_id: "AB_RS_B"})

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      # With no limit set there is no operator change to place, so no wait can
      # carry the mark and no problem is raised for the block.
      refute has_element?(view, "#block-day", "operators can change")

      Blocking.update_settings(context.organization.id, context.version.id, %{
        max_piece_minutes: 180
      })

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      assert has_element?(
               view,
               "#block-day tr[data-kind='wait']",
               "22 min · operators can change ⇄"
             )
    end

    test "a trip the sequence left out stays in the table with its own note", context do
      entered_day!(context)

      # A trip with no usable endpoint times: the vehicle never runs it, so it has
      # no place in the timed day, but the block owns it and the drawer says why.
      trip!(context, context.riverside, %{trip_id: "6109", first: "09:00:00", last: nil})

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      assert activities(view) |> List.last() == "Trip 6109 · route 12"
      assert has_element?(view, "#block-day tr[data-kind='trip']", "Time missing")

      assert attributes(view, "#block-day [data-role='block-inspect']", "phx-value-trip") ==
               ["6101", "8101", "6103", "6109"]
    end

    test "a problem about a connection is a callout that opens that connection", context do
      trips = entered_day!(context)

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      assert has_element?(
               view,
               "#block-problems [data-role='block-problem'][data-code='cannot_reach']",
               "The drive between these two trips needs 14 min and there are 8 min."
             )

      # The callout's link is the only way into the gap drawer for a pair the
      # timeline's own gap bar cannot draw, and it keeps the block in the URL.
      view |> element("#block-problems [data-role='block-open-connection']") |> render_click()

      assert_patch(
        view,
        blocks_path(context.version.id) <>
          "?gap=#{trips.first.id}|#{trips.second.id}&block=101"
      )

      assert has_element?(view, "#gap-drawer", "Open block 101")
    end

    test "a trip row keeps Inspect and a drive row opens the gap, both with the block kept",
         context do
      trips = entered_day!(context)

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      # Every trip row's Inspect carries the block, which is what gives the trip
      # drawer its back link.
      assert attributes(view, "#block-day [data-role='block-inspect']", "phx-value-block") ==
               ["101", "101", "101"]

      view
      |> element("#block-day [data-role='block-inspect'][phx-value-trip='6101']")
      |> render_click()

      assert_patch(view, blocks_path(context.version.id) <> "?trip=6101&block=101")
      assert has_element?(view, "#trip-drawer", "Back to block 101")

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      view
      |> element("#block-day tr[data-kind='drive'] [data-role='block-gap']")
      |> render_click()

      assert_patch(
        view,
        blocks_path(context.version.id) <>
          "?gap=#{trips.first.id}|#{trips.second.id}&block=101"
      )
    end

    test "the block actions are still here, and the in-seat records are still read-only",
         context do
      entered_day!(context)

      {:ok, view, _html} =
        live(editor_conn(context), blocks_path(context.version.id) <> "?block=101")

      assert has_element?(
               view,
               "#block-rename-form[phx-submit='submit_block_action']",
               "Rename block"
             )

      assert has_element?(
               view,
               "#block-merge-form[phx-submit='submit_block_action']",
               "Merge blocks"
             )

      assert has_element?(
               view,
               "#block-remove-all[phx-click='submit_block_action']",
               "Remove all trips"
             )

      # INV-3: nothing in this drawer edits a transfer, and the gap drawer's record
      # list is a read-only report.
      refute has_element?(view, "#block-drawer [phx-value-action='confirm_in_seat']")
      refute has_element?(view, "#block-drawer [data-role='block-in-seat-edit']")
    end
  end
end

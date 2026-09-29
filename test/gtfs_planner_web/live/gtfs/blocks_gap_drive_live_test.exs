defmodule GtfsPlannerWeb.Gtfs.BlocksGapDriveLiveTest do
  # EV-32, rejecting FH-32 for CL-32: the gap drawer as the connection a planner
  # works on — the pair's times, the time available, the drive without riders with
  # its source, the wait behind it, and whether an operator can change there — read
  # through the ordinary `/gtfs/:version/blocks` route on the production
  # `CatalogReadAdapter.Repo` and the scoped `Blocking` context. Rows are created
  # inside the SQL Sandbox transaction and rolled back; nothing here substitutes an
  # adapter, a context or a hand-built movement.
  #
  # The fixture is the reference's own block 101 at its own geometry, scaled so
  # that the Valley College → Market Square leg is 5.2 km: the domain's own
  # estimator over the fixture's own coordinates returns 14 minutes for it, so the
  # drawer's `14 min` and its `Estimated` badge are the estimator's answer rather
  # than a number pasted into a fixture, and the 8 minutes between 6101's 06:35
  # arrival and 8101's 06:43 departure are the ones the reference states. The
  # entered case stores the pair's minutes in `deadhead_times` instead, which is
  # the same leg read the way AC-3 stores one.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_gap_drive_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs

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

    # One meridian. The two platforms of Riverside Station share its point, the
    # way the reference's one station does, and Market Square sits 5.2 km north of
    # Valley College so that leg's estimate is 14 minutes.
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

    %{
      organization: organization,
      user: user,
      version: version,
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
      %{service_id: "WK", block_id: "101", first_stop: "AB_RS_A", last_stop: "AB_VALLEY"}
      |> Map.merge(attrs)
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_departure, last)
    )
  end

  # The reference's block 101: 06:00 and 07:40 out of Riverside Station, the 06:43
  # Crosstown out of Market Square between them, and the 8-minute gap the vehicle
  # needs 14 minutes to cover.
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
      trip!(context, context.riverside, %{
        trip_id: "6103",
        first_stop: "AB_RS_B",
        first: "07:40:00",
        last: "08:15:00"
      })

    %{first: first, second: second, third: third}
  end

  # The same leg, entered rather than estimated: five minutes is a real route a
  # person drove, so the gap becomes reachable and the wait behind it is real too.
  defp entered_drive!(context, minutes) do
    deadhead_time_fixture(context.organization.id, context.version.id, %{
      from_ref: "stop:AB_VALLEY",
      to_ref: "stop:AB_MKT",
      minutes: minutes
    })
  end

  # A relief limit turns the operator-change checks on. With no limit the page has
  # no piece of work to hand over, so no gap is marked and the drawer says so.
  defp relief_limit!(context, minutes) do
    assert {:ok, :ok} =
             Gtfs.update_relief_settings(
               context.organization.id,
               context.version.id,
               nil,
               %{max_piece_minutes: minutes, marked: []}
             )
  end

  defp relief_point!(context, stop_id) do
    relief_point_fixture(context.organization.id, context.version.id, %{stop_id: stop_id})
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp text(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.replace(~r/\s+/, " ")
  end

  defp texts(view, selector) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp attribute_values(view, selector, attribute) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.attribute(&1, attribute) |> List.first()))
  end

  describe "the gap drawer" do
    test "the pair's times, the drive with its source, the wait and the operator change",
         context do
      relief_limit!(context, 330)
      trips = block_101!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      # The timeline's own gap bar opens the drawer, which is the production path
      # from the row to the URL to the drawer.
      view
      |> element(
        "[data-role='blocks-gap'][data-from='#{trips.first.id}'][data-to='#{trips.second.id}']"
      )
      |> render_click()

      assert has_element?(view, "#gap-drawer", "Between trips 6101 and 8101")
      assert has_element?(view, "#gap-drawer", "Block 101 · Weekday")

      assert has_element?(view, "#gap-drawer", "Arrives")
      assert has_element?(view, "#gap-drawer", "06:35 at Valley College")
      assert has_element?(view, "#gap-drawer", "Next trip leaves")
      assert has_element?(view, "#gap-drawer", "06:43 from Market Square")
      assert has_element?(view, "#gap-available", "8 min")
      assert has_element?(view, "#gap-drive", "14 min")
      assert has_element?(view, "#gap-drive-source", "Estimated")

      # The wait is the gap behind a drive the vehicle cannot make, so there is
      # none to report (FH-40).
      assert has_element?(view, "#gap-wait", "—")
      assert has_element?(view, "#gap-operators", "No")

      # The rider note stays off an empty move, and the record list is still there.
      refute has_element?(view, "#gap-rider-note")
      assert has_element?(view, "#gap-transfers", "Transfer records · 0")
    end

    test "the callout reads the minutes needed against the time there is", context do
      relief_limit!(context, 330)
      trips = block_101!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      view
      |> element(
        "[data-role='blocks-gap'][data-from='#{trips.first.id}'][data-to='#{trips.second.id}']"
      )
      |> render_click()

      assert has_element?(
               view,
               "#gap-text",
               "Needs 14 min to reach Market Square; has 8 min."
             )

      assert has_element?(
               view,
               "#gap-text",
               "Move one of the trips to another block, or enter a known driving time if the estimate is too long."
             )
    end

    test "Enter a known driving time opens the driving times drawer for that pair", context do
      relief_limit!(context, 330)
      trips = block_101!(context)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), gap_url(base, trips.first, trips.second))

      assert has_element?(view, "#gap-open-driving-times", "Enter a known driving time")

      view |> element("#gap-open-driving-times") |> render_click()

      assert_patch(view, base <> "?drawer=driving_times&pair=stop%3AAB_VALLEY%7Cstop%3AAB_MKT")

      # The pair the link names is the pair the movement derived, in the stored
      # reference form `Gtfs.list_deadhead_pairs/3` hands out.
      assert attribute_values(view, "#gap-open-driving-times", "phx-value-pair") ==
               ["stop:AB_VALLEY|stop:AB_MKT"]

      # The drawer the link opens is a page drawer, so the stack is dropped rather
      # than left open underneath it.
      refute has_element?(view, "#gap-drawer")
    end

    test "Review operator changes opens the operator changes drawer", context do
      relief_limit!(context, 330)
      trips = block_101!(context)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), gap_url(base, trips.first, trips.second))

      assert has_element?(view, "#gap-open-operator-changes", "Review operator changes")

      view |> element("#gap-open-operator-changes") |> render_click()

      assert_patch(view, base <> "?drawer=operator_changes")
    end

    test "a same-stop gap reads None · same stop and offers no driving time", context do
      relief_limit!(context, 330)
      trips = block_101!(context)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), gap_url(base, trips.second, trips.third))

      assert has_element?(view, "#gap-drawer", "Between trips 8101 and 6103")
      assert has_element?(view, "#gap-drive", "None · same stop")
      assert has_element?(view, "#gap-wait", "22 min")
      # The vehicle never drives, so there is no pair to enter a driving time for.
      refute has_element?(view, "#gap-open-driving-times")
      assert has_element?(view, "#gap-open-operator-changes", "Review operator changes")
    end

    test "an entered drive shows the Entered badge and offers to change it", context do
      relief_limit!(context, 330)
      entered_drive!(context, 5)
      trips = block_101!(context)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), gap_url(base, trips.first, trips.second))

      assert has_element?(view, "#gap-drive", "5 min")
      assert has_element?(view, "#gap-drive-source", "Entered")
      refute has_element?(view, "#gap-drive-source", "Estimated")
      assert has_element?(view, "#gap-wait", "3 min")
      assert has_element?(view, "#gap-open-driving-times", "Change the driving time")

      # A drive the vehicle can make is not the callout's error, and the estimate
      # mark is gone with it.
      assert text(view, "#gap-text") =~
               "Moves empty: Valley College → Market Square. 5 min to drive."

      refute has_element?(view, "#gap-text", "Needs 5 min")
    end

    test "with relief checks off the row reads Not checked", context do
      trips = block_101!(context)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), gap_url(base, trips.first, trips.second))

      # The drawer's own limit is the day type's, and this version has none: there
      # is no piece of work to hand over, so the row says the checks are off rather
      # than claiming a change is impossible.
      assert has_element?(view, "#gap-operators", "Not checked")
    end

    test "a marked stop on both ends of a reachable drive names the places", context do
      relief_limit!(context, 330)
      entered_drive!(context, 5)
      relief_point!(context, "AB_VALLEY")
      relief_point!(context, "AB_MKT")
      trips = block_101!(context)

      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), gap_url(base, trips.first, trips.second))

      assert has_element?(view, "#gap-operators", "Yes, at Valley College; Market Square")

      # Both ends marked, but the drive between them is one operator's work.
      assert has_element?(view, "#gap-change-note", "Both stops are marked")
    end

    test "the row labels read in the drawer's own order", context do
      relief_limit!(context, 330)
      block_101!(context)

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert texts(view, "#gap-drawer dt") == [
               "Arrives",
               "Next trip leaves",
               "Time available",
               "Driving without riders",
               "Wait",
               "Operators can change"
             ]
    end
  end

  # The `gap=` deep link carries both trip UUIDs in one parameter.
  defp gap_url(base, from_trip, to_trip) do
    base <> "?" <> URI.encode_query([{"gap", "#{from_trip.id}|#{to_trip.id}"}])
  end
end

defmodule GtfsPlannerWeb.Gtfs.BlocksMovementsLiveTest do
  # The timeline's garage legs, drives, waits,
  # relief marks and legend, read through the ordinary `/gtfs/:version/blocks`
  # route on the production `CatalogReadAdapter.Repo` and the scoped `Blocking`
  # context. Rows are created inside the SQL Sandbox transaction and rolled back;
  # nothing here substitutes an adapter or hand-builds a movement.
  #
  # Every driving time these cases measure is an *entered* value in
  # `deadhead_times`, never an estimate, so each expected left and width below is
  # arithmetic over the fixture's own clocks: the percentages are literal and the
  # assertions would fail if the page re-derived a geometry of its own. The axis
  # is the day's platform spans snapped outwards to the hour, which is what makes
  # a pull-out before 00:00 land on the track instead of off its left edge.
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

    calendar_service_fixture(organization.id, version.id, %{service_id: "WK", name: "Weekday"})

    # Four stops on one meridian, a hundredth of a degree apart, plus one ninety
    # kilometres north (the drive a vehicle cannot make in ten minutes) and one
    # with no coordinates at all (the drive the version cannot compute). Every
    # trip is plottable and every pull has a real distance.
    # The bar titles name stops by name, not by ID, so each stop is named for the
    # ID it carries.
    for {stop_id, lat, lon} <- [
          {"S1", "40.0000", "-74.0000"},
          {"S2", "40.0100", "-74.0000"},
          {"S3", "40.0200", "-74.0000"},
          {"FAR", "41.0000", "-74.0000"},
          {"NOCOORD", nil, nil}
        ] do
      stop_with_coordinates_fixture(organization.id, version.id, %{
        stop_id: stop_id,
        stop_name: stop_name(stop_id),
        stop_lat: lat && Decimal.new(lat),
        stop_lon: lon && Decimal.new(lon)
      })
    end

    main = garage_fixture(organization.id, %{"name" => "Main"})

    %{
      organization: organization,
      user: user,
      version: version,
      route: route,
      main: main
    }
  end

  defp blocks_path(version_id), do: "/gtfs/#{version_id}/blocks"

  defp editor_conn(context) do
    log_in_user(context.conn, context.user, organization: context.organization)
  end

  defp trip!(context, trip_id, block_id, first, last, first_stop, last_stop) do
    blocked_trip_fixture(
      context.organization.id,
      context.version.id,
      context.route.route_id,
      %{
        trip_id: trip_id,
        service_id: "WK",
        block_id: block_id,
        first_stop: first_stop,
        first_arrival: first,
        first_departure: first,
        last_stop: last_stop,
        last_arrival: last,
        last_departure: last
      }
    )
  end

  defp garage_block!(context, block_id) do
    block_attribute_fixture(context.organization.id, context.version.id, %{
      service_id: "WK",
      block_id: block_id,
      garage_id: context.main.id
    })
  end

  # An entered driving time in one direction only: A→B says nothing about B→A.
  defp drive!(context, from_ref, to_ref, minutes) do
    deadhead_time_fixture(context.organization.id, context.version.id, %{
      from_ref: from_ref,
      to_ref: to_ref,
      minutes: minutes
    })
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp attribute(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name) |> List.first()
  end

  defp attributes(view, selector, name) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp text(view, selector) do
    view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp row(block_id), do: "#blocks-timeline tbody tr[data-block='#{block_id}']"

  describe "the garage legs" do
    test "a pull-out and a pull-back sit at their share of the day's axis", context do
      garage_block!(context, "101")

      # Main → S1 is 12 entered minutes and the first trip leaves at 06:00, so
      # the pull-out runs 05:48–06:00; S2 → Main is 7, so the pull-back runs
      # 07:00–07:07. The platform span is 05:48–07:07 and the axis is the hour
      # outside it: 05:00–08:00, a span of 10,800 seconds.
      drive!(context, {:garage, context.main.id}, {:stop, "S1"}, 12)
      drive!(context, {:stop, "S2"}, {:garage, context.main.id}, 7)

      trip!(context, "a", "101", "06:00:00", "07:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      out = "#{row("101")} [data-role='pull-out']"

      assert attribute(view, out, "style") =~ "left: 26.67%"
      assert attribute(view, out, "style") =~ "width: 6.67%"
      assert attribute(view, out, "phx-click") == "open_block"
      assert attribute(view, out, "phx-value-block") == "101"
      # The title leads with what the bar is, so the reader knows it is a pull.
      assert attribute(view, out, "title") =~
               "Pull-out · leaves Main garage at 05:48, 12 min entered"

      back = "#{row("101")} [data-role='pull-back']"

      assert attribute(view, back, "style") =~ "left: 66.67%"
      assert attribute(view, back, "style") =~ "width: 3.89%"
      assert attribute(view, back, "phx-click") == "open_block"
      # The title leads with what the bar is, so the reader knows it is a pull.
      assert attribute(view, back, "title") =~
               "Pull-back · returns to Main garage at 07:07, 7 min entered"

      # The axis reads the platform span, not the trip span: 05:48 is before the
      # first departure and 07:07 after the last arrival.
      assert has_element?(view, "#{row("101")} .blocks-meta-out", "05:48–07:07")
      assert has_element?(view, "#blocks-timeline .blocks-axis-tick", "05:00")
    end

    test "a block no garage resolves has no garage legs", context do
      trip!(context, "a", "102", "08:00:00", "09:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      refute has_element?(view, "#{row("102")} [data-role='pull-out']")
      refute has_element?(view, "#{row("102")} [data-role='pull-back']")
    end
  end

  describe "the drives between trips" do
    test "a feasible drive is followed by the wait it leaves behind", context do
      # S1 → FAR is 8 entered minutes and the gap is 30, so the drive runs
      # 07:00–07:08 and the wait after it is 22 minutes, 07:08–07:30. The axis is
      # 06:00–09:00 (the trips' own span, no garage), a span of 10,800 seconds.
      drive!(context, {:stop, "S1"}, {:stop, "FAR"}, 8)

      trip!(context, "a", "101", "06:00:00", "07:00:00", "S1", "S1")
      trip!(context, "b", "101", "07:30:00", "08:30:00", "FAR", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      drive = "#{row("101")} [data-role='drive']"

      assert attribute(view, drive, "style") =~ "left: 33.33%"
      assert attribute(view, drive, "style") =~ "width: 4.44%"
      assert attribute(view, drive, "phx-click") == "open_gap"
      assert attribute(view, drive, "title") =~ "Drive to FAR Stop"
      assert attribute(view, drive, "title") =~ "07:00–07:08, 8 min entered, then wait 22 min"

      wait = "#{row("101")} [data-role='blocks-gap']"

      # The wait starts where the drive ended, not where the vehicle arrived.
      assert attribute(view, wait, "style") =~ "left: 37.78%"
      assert attribute(view, wait, "style") =~ "width: 12.22%"
      assert attribute(view, wait, "data-minutes") == "22"
      assert attribute(view, wait, "data-short") == "false"

      # The drive is drawn before the wait, before the wait it precedes.
      roles = attributes(view, "#{row("101")} [data-role]", "data-role")

      assert Enum.find_index(roles, &(&1 == "drive")) <
               Enum.find_index(roles, &(&1 == "blocks-gap"))
    end

    test "a drive the vehicle cannot make in time takes the gap and prints an exclamation mark",
         context do
      # Forty entered minutes of driving against a thirty-minute gap: the gap is
      # the whole mark, it carries `!`, and no wait is drawn behind it because
      # there is none.
      drive!(context, {:stop, "S1"}, {:stop, "FAR"}, 40)

      trip!(context, "a", "101", "06:00:00", "07:00:00", "S1", "S1")
      trip!(context, "b", "101", "07:30:00", "08:30:00", "FAR", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      bad = "#{row("101")} [data-role='drive-bad']"

      assert attribute(view, bad, "style") =~ "left: 33.33%"
      assert attribute(view, bad, "style") =~ "width: 16.67%"
      assert attribute(view, bad, "phx-click") == "open_gap"
      assert attribute(view, bad, "title") =~ "Can't reach FAR Stop"
      assert attribute(view, bad, "title") =~ "needs 40 min to get there, has 30 min"
      assert text(view, bad) == "!"

      refute has_element?(view, "#{row("101")} [data-role='blocks-gap']")
    end

    test "a drive the version cannot compute claims nothing and asks for it", context do
      # The first trip ends at a stop with no coordinates, so the handoff is a
      # move whose duration cannot be estimated: the gap carries `?` and no wait.
      trip!(context, "a", "101", "06:00:00", "07:00:00", "S1", "NOCOORD")
      trip!(context, "b", "101", "07:30:00", "08:30:00", "S2", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      unknown = "#{row("101")} [data-role='drive-unknown']"

      assert attribute(view, unknown, "style") =~ "left: 33.33%"
      assert attribute(view, unknown, "style") =~ "width: 16.67%"
      assert attribute(view, unknown, "phx-click") == "open_gap"
      assert attribute(view, unknown, "title") =~ "is not known"
      assert text(view, unknown) == "?"

      refute has_element?(view, "#{row("101")} [data-role='blocks-gap']")
    end

    test "a wait below the minimum layover keeps the warning outline", context do
      # The same stop at both ends, so the handoff is a layover with no drive:
      # two minutes against the default five-minute minimum.
      trip!(context, "a", "101", "06:00:00", "07:00:00", "S1", "S1")
      trip!(context, "b", "101", "07:02:00", "08:00:00", "S1", "S1")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      wait = "#{row("101")} [data-role='blocks-gap']"

      assert attribute(view, wait, "data-short") == "true"
      assert attribute(view, wait, "data-minutes") == "2"
      assert has_element?(view, "#{wait}.blocks-gap-short")
    end
  end

  describe "the operator-change mark" do
    test "a wait at a marked stop ends with the mark once a limit is set", context do
      # The 60-minute limit is what makes an operator change part of the plan at
      # all, and S1 is marked, so the wait at it is a window.
      Blocking.update_settings(
        GtfsPlanner.AccountsFixtures.editor_audit_fixture(
          context.organization.id,
          context.version.id
        ),
        %{
          max_piece_minutes: 60
        }
      )

      relief_point_fixture(context.organization.id, context.version.id, %{stop_id: "S1"})

      trip!(context, "a", "101", "06:00:00", "07:00:00", "S1", "S1")
      trip!(context, "b", "101", "07:30:00", "08:00:00", "S1", "S1")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert has_element?(
               view,
               "#{row("101")} [data-role='blocks-gap'][data-relief='true']",
               "30"
             )

      assert has_element?(view, "#{row("101")} [data-role='blocks-gap-relief']", "⇄")
    end

    test "no limit means no mark anywhere", context do
      relief_point_fixture(context.organization.id, context.version.id, %{stop_id: "S1"})

      trip!(context, "a", "101", "06:00:00", "07:00:00", "S1", "S1")
      trip!(context, "b", "101", "07:30:00", "08:00:00", "S1", "S1")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert has_element?(view, "#{row("101")} [data-role='blocks-gap'][data-relief='false']")
      refute has_element?(view, "[data-role='blocks-gap-relief']")
      refute has_element?(view, "#blocks-timeline-legend", "Operators can change")
    end
  end

  describe "the axis" do
    test "spans a platform start before 00:00 and prints GTFS hours", context do
      garage_block!(context, "101")

      # Main → FAR is 15 entered minutes and the first trip leaves at 00:00, so
      # the platform span starts at 23:45 the day before; the last trip arrives at
      # 25:00 and S1 → Main is 3, so it ends at 25:03. The axis is the hour
      # outside it, 23:00 the day before to 02:00 the day after.
      drive!(context, {:garage, context.main.id}, {:stop, "FAR"}, 15)
      drive!(context, {:stop, "S1"}, {:garage, context.main.id}, 3)

      trip!(context, "a", "101", "00:00:00", "00:30:00", "FAR", "S1")
      trip!(context, "b", "101", "24:30:00", "25:00:00", "S1", "S1")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      # The axis labels every two hours and drops the last label that would
      # crowd the right edge, so its opening tick carries the `−1d` marker and
      # its closing tick is the same day's 23:00. The span itself continues past
      # midnight, which the row's own cell prints in GTFS hours.
      assert has_element?(view, "#blocks-timeline .blocks-axis-tick", "23:00 −1d")
      assert has_element?(view, "#blocks-timeline .blocks-axis-tick", "23:00")
      assert has_element?(view, "#{row("101")} .blocks-meta-out", "23:45 −1d–25:03")

      # The pull-out is on the track rather than off its left edge: 23:45 is 45
      # minutes after the 23:00 the axis starts at, and the axis spans 25 hours.
      out = "#{row("101")} [data-role='pull-out']"

      assert attribute(view, out, "style") =~ "left: 2.78%"
      assert attribute(view, out, "style") =~ "width: 0.93%"
    end
  end

  describe "the legend" do
    test "names the marks a row can carry", context do
      trip!(context, "a", "101", "08:00:00", "09:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      legend = "#blocks-timeline-legend"

      assert has_element?(view, legend, "Garage travel")
      assert has_element?(view, legend, "Driving without riders")
      assert has_element?(view, legend, "Waiting · minutes")
      assert has_element?(view, "#{legend} .blocks-pull")
      assert has_element?(view, "#{legend} .blocks-drive")
      assert has_element?(view, "#{legend} .blocks-wait")

      # With no limit set there is no operator change to place, so the legend
      # carries no key for one.
      refute has_element?(view, legend, "Operators can change")
    end

    test "adds the operator-change key when a limit is set", context do
      Blocking.update_settings(
        GtfsPlanner.AccountsFixtures.editor_audit_fixture(
          context.organization.id,
          context.version.id
        ),
        %{
          max_piece_minutes: 330
        }
      )

      trip!(context, "a", "101", "08:00:00", "09:00:00", "S1", "S2")

      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert has_element?(view, "#blocks-timeline-legend", "Operators can change")
      assert text(view, "#blocks-timeline-legend .blocks-legend-relief") == "⇄"
    end
  end

  # `S1` names "S1 Stop", so a title that reads a stop by name is unambiguous.
  defp stop_name(stop_id), do: "#{stop_id} Stop"
end

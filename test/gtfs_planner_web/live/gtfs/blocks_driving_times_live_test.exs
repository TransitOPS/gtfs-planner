defmodule GtfsPlannerWeb.Gtfs.BlocksDrivingTimesLiveTest do
  # EV-34, rejecting FH-34 for CL-34: the Driving times drawer as a planner
  # works on — the day's directional pairs, most used first, their minutes and
  # source, the “Estimated only” filter, an entered time, a reset, and a
  # refused value — read through the ordinary `/gtfs/:version/blocks` route on
  # the production `CatalogReadAdapter.Repo` and the scoped `Blocking` context.
  # Rows are created inside the SQL Sandbox transaction and rolled back; nothing
  # here substitutes an adapter, a context or a hand-built pair.
  #
  # The fixture is the reference's own block 101 at its own geometry, scaled so
  # that the Valley College → Market Square leg is 5.2 km, and it adds the
  # reference's second block 104 so one pair is driven twice: that is what makes
  # “most used first” a statement about the list rather than about one row. The
  # minutes in the table are the domain's own estimator over the fixture's own
  # coordinates, not numbers pasted into a fixture, and the entered cases store a
  # pair in `deadhead_times`, which is the same read AC-3 stores one by.
  #
  # The focused gate command is deferred to branch review:
  # `mix test test/gtfs_planner_web/live/gtfs/blocks_driving_times_live_test.exs`.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Ecto.Query, only: [from: 2]

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.DeadheadTime
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

    # One meridian, the fixture of the gap drawer's own gate: the two platforms of
    # Riverside Station share its point and Market Square sits 5.2 km north of
    # Valley College, so the estimator answers 14 minutes for that leg.
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
      %{service_id: "WK", first_stop: "AB_RS_A", last_stop: "AB_VALLEY"}
      |> Map.merge(attrs)
      |> Map.put(:first_arrival, first)
      |> Map.put(:last_arrival, last)
      |> Map.put(:first_departure, first)
      |> Map.put(:last_departure, last)
    )
  end

  # The reference's block 101 and its block 104 both drive Valley College → Market
  # Square once, and block 105 drives that leg the other way, so the day has two
  # directional pairs and the busiest one comes first. The version has no garage,
  # so the only drives the day has are the two gaps: the drawer lists what the
  # movements really are rather than a fixture's extra rows.
  defp blocks!(context) do
    trip!(context, context.riverside, %{
      trip_id: "6101",
      block_id: "101",
      first: "06:00:00",
      last: "06:35:00"
    })

    trip!(context, context.crosstown, %{
      trip_id: "8101",
      block_id: "101",
      first_stop: "AB_MKT",
      last_stop: "AB_RS_B",
      first: "06:43:00",
      last: "07:18:00"
    })

    trip!(context, context.riverside, %{
      trip_id: "6103",
      block_id: "101",
      first_stop: "AB_RS_B",
      last_stop: "AB_VALLEY",
      first: "07:40:00",
      last: "08:15:00"
    })

    trip!(context, context.riverside, %{
      trip_id: "6105",
      block_id: "104",
      first: "09:00:00",
      last: "09:30:00"
    })

    trip!(context, context.crosstown, %{
      trip_id: "8105",
      block_id: "104",
      first_stop: "AB_MKT",
      last_stop: "AB_RS_B",
      first: "09:50:00",
      last: "10:20:00"
    })

    # Block 105 drives the same two places in the other direction, so the day has
    # a second directional pair — each direction is a row of its own (AC-3).
    trip!(context, context.riverside, %{
      trip_id: "6107",
      block_id: "105",
      first_stop: "AB_MKT",
      last_stop: "AB_RS_B",
      first: "10:30:00",
      last: "10:45:00"
    })

    trip!(context, context.crosstown, %{
      trip_id: "8107",
      block_id: "105",
      first_stop: "AB_VALLEY",
      last_stop: "AB_MKT",
      first: "10:50:00",
      last: "11:20:00"
    })
  end

  defp entered_drive!(context, from_ref, to_ref, minutes) do
    deadhead_time_fixture(context.organization.id, context.version.id, %{
      from_ref: from_ref,
      to_ref: to_ref,
      minutes: minutes
    })
  end

  # The stored driving times, as this transaction can see them. The drawer's writes
  # are the only ones in the case, so the row count is the write count: it is how
  # “stores only that row” is proved without a mock.
  defp stored_drive_times(context) do
    Repo.all(
      from row in DeadheadTime,
        where: row.gtfs_version_id == ^context.version.id,
        select: {row.from_ref, row.to_ref, row.minutes},
        order_by: [asc: row.from_ref, asc: row.to_ref]
    )
  end

  defp open_drawer(view), do: view |> element("#blocks-driving-times") |> render_click()

  # The table's cells row by row. LazyHTML's selector subset has no positional
  # pseudo-classes, so each row is read and indexed here rather than with `:nth-child`.
  defp table_cells(view) do
    view
    |> doc()
    |> LazyHTML.query("#driving-times tr")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query("td")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
    end)
  end

  defp column(cells, index), do: Enum.map(cells, &Enum.at(&1, index))

  defp row_classes(view, selector) do
    view |> attribute_values(selector, "class") |> hd() |> String.split()
  end

  defp value_of(view, input_id) do
    view |> doc() |> LazyHTML.query("##{input_id}") |> LazyHTML.attribute("value") |> List.first()
  end

  defp submitted_minutes(view) do
    view
    |> doc()
    |> LazyHTML.query("#driving-times input[type='number']")
    |> Enum.map(
      &{&1 |> LazyHTML.attribute("name") |> List.first(),
       &1 |> LazyHTML.attribute("value") |> List.first()}
    )
  end

  describe "the scope bar's Driving times button" do
    test "it counts the day's estimated pairs", context do
      blocks!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      # Two directional pairs, both estimated, one of them driven twice — so the
      # button counts the estimated pairs, not the rows of the table.
      assert has_element?(view, "#blocks-driving-times", "Driving times · 2 estimated")
    end

    test "with nothing estimated it reads Driving times", context do
      # A version whose only block needs no drive at all: one trip, so the day
      # has no pair to estimate.
      trip!(context, context.riverside, %{trip_id: "1", block_id: "1"})
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert has_element?(view, "#blocks-driving-times", "Driving times")
      refute has_element?(view, "#blocks-driving-times", "estimated")
    end
  end

  describe "the Driving times drawer" do
    test "it lists the day's pairs most used first, with the used count and source",
         context do
      blocks!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      assert has_element?(view, "#driving-times-drawer", "Driving times")
      assert has_element?(view, "#driving-times-intro", "straight-line distance × 1.3 ÷ 30 km/h")
      assert has_element?(view, "#driving-times-count", "2 of 2 estimated")

      # The pair both blocks drive is first, with its two uses; the rest follow in
      # the context's own order.
      assert column(table_cells(view), 0) == [
               "Valley College → Market Square",
               "Riverside Station → Valley College"
             ]

      assert column(table_cells(view), 1) == ["2", "1"]

      # The estimator's own answers, and every row's source is the estimate.
      assert submitted_minutes(view) == [
               {"minutes[stop:AB_VALLEY|stop:AB_MKT]", "14"},
               {"minutes[stop:AB_RS_B|stop:AB_VALLEY]", "3"}
             ]

      assert length(table_cells(view)) == 2

      assert column(table_cells(view), 3) == ["Estimated", "Estimated"]

      # An estimated row offers no reset: there is nothing entered to clear.
      refute has_element?(view, "#driving-time-row-0-reset")
    end

    test "a pair link opens the drawer with that row highlighted and its input focused",
         context do
      blocks!(context)
      base = blocks_path(context.version.id)
      pair = "stop:AB_VALLEY|stop:AB_MKT"

      {:ok, view, _html} =
        live(
          editor_conn(context),
          base <> "?drawer=driving_times&pair=#{URI.encode_www_form(pair)}"
        )

      assert has_element?(view, "#driving-times-drawer", "Driving times")
      assert has_element?(view, "#driving-time-row-0", "Valley College → Market Square")

      assert "bg-base-200" in row_classes(view, "#driving-time-row-0")
      refute "bg-base-200" in row_classes(view, "#driving-time-row-1")

      # The row the URL named is the row the input id names, so the dialog hook
      # focuses the reader's own entry rather than the filter checkbox.
      assert attribute_values(view, "#driving-times-drawer-overlay", "data-initial-focus-id") ==
               ["driving-minutes-0"]

      assert value_of(view, "driving-minutes-0") == "14"
    end

    test "Estimated only hides the entered rows and keeps what was typed", context do
      blocks!(context)
      entered_drive!(context, "stop:AB_RS_B", "stop:AB_VALLEY", 4)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      assert has_element?(view, "#driving-times-count", "1 of 2 estimated")
      assert column(table_cells(view), 3) == ["Estimated", "Entered"]
      assert has_element?(view, "#driving-time-row-1-reset", "Reset to estimate")

      # The reader types into two rows and then narrows the list. The change event
      # carries the filter and every row, so nothing typed is lost.
      view
      |> form("#driving-times-form",
        minutes: %{"stop:AB_VALLEY|stop:AB_MKT" => "9", "stop:AB_RS_B|stop:AB_VALLEY" => "17"}
      )
      |> render_change(%{
        "estimated_only" => "true",
        "minutes" => %{"stop:AB_VALLEY|stop:AB_MKT" => "9", "stop:AB_RS_B|stop:AB_VALLEY" => "17"}
      })

      assert has_element?(view, "#driving-times-count", "1 of 2 estimated")
      assert column(table_cells(view), 0) == ["Valley College → Market Square"]

      # The entered row is hidden, and the visible typed value is in its input.
      refute has_element?(view, "#driving-time-row-1", "Reset to estimate")
      assert value_of(view, "driving-minutes-0") == "9"

      view |> form("#driving-times-form") |> render_submit()

      # The save compares against the listed minutes, so the row the filter hid is
      # compared on what the reader typed and stored as well.
      assert stored_drive_times(context) == [
               {"stop:AB_RS_B", "stop:AB_VALLEY", 17},
               {"stop:AB_VALLEY", "stop:AB_MKT", 9}
             ]
    end

    test "saving one row stores that row, redraws the day and says what it entered",
         context do
      blocks!(context)
      base = blocks_path(context.version.id)
      {:ok, view, _html} = live(editor_conn(context), base)

      assert has_element?(view, "#blocks-driving-times", "Driving times · 2 estimated")
      open_drawer(view)

      view
      |> form("#driving-times-form",
        minutes: %{"stop:AB_VALLEY|stop:AB_MKT" => "9"}
      )
      |> render_submit()

      # One writer call, one stored row: the other three rows keep their
      # estimates and nothing is written for them.
      assert stored_drive_times(context) == [{"stop:AB_VALLEY", "stop:AB_MKT", 9}]

      assert render(view) =~ "1 driving time entered"

      # The row the reader changed is now the version's own answer, the day is
      # redrawn under it — the scope button's estimate count drops by one — and
      # the row itself offers the reset.
      assert has_element?(view, "#blocks-driving-times", "Driving times · 1 estimated")
      assert has_element?(view, "#driving-times-count", "1 of 2 estimated")
      assert column(table_cells(view), 3) == ["Entered", "Estimated"]
      assert has_element?(view, "#driving-time-row-0-reset", "Reset to estimate")
      assert submitted_minutes(view) |> hd() == {"minutes[stop:AB_VALLEY|stop:AB_MKT]", "9"}
    end

    test "Reset to estimate clears the row and the estimate comes back", context do
      blocks!(context)
      entered_drive!(context, "stop:AB_VALLEY", "stop:AB_MKT", 9)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      assert has_element?(view, "#blocks-driving-times", "Driving times · 1 estimated")
      open_drawer(view)

      assert submitted_minutes(view) |> hd() == {"minutes[stop:AB_VALLEY|stop:AB_MKT]", "9"}
      assert has_element?(view, "#driving-time-row-0-reset", "Reset to estimate")

      view |> element("#driving-time-row-0-reset") |> render_click()

      # Only that direction is cleared: the row is the version's estimate again
      # and nothing else changed.
      assert stored_drive_times(context) == []
      assert has_element?(view, "#driving-time-row-0", "Estimated")
      refute has_element?(view, "#driving-time-row-0-reset")
      assert has_element?(view, "#blocks-driving-times", "Driving times · 2 estimated")
      assert render(view) =~ "Driving time reset to its estimate."
      assert submitted_minutes(view) |> hd() == {"minutes[stop:AB_VALLEY|stop:AB_MKT]", "14"}
    end

    test "a value over the range is refused on its own row and keeps every entry",
         context do
      blocks!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      view
      |> form("#driving-times-form",
        minutes: %{"stop:AB_VALLEY|stop:AB_MKT" => "901", "stop:AB_RS_B|stop:AB_VALLEY" => "17"}
      )
      |> render_submit()

      # Nothing is stored: one bad value does not write the other row.
      assert stored_drive_times(context) == []

      assert has_element?(view, "#driving-minutes-0-error", "Enter 0–600 min.")
      assert value_of(view, "driving-minutes-0") == "901"
      assert value_of(view, "driving-minutes-1") == "17"
      refute render(view) =~ "1 driving time entered"
    end

    test "a value that is not a whole number is refused the same way", context do
      blocks!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      view
      |> form("#driving-times-form",
        minutes: %{"stop:AB_VALLEY|stop:AB_MKT" => "9.5"}
      )
      |> render_submit()

      assert stored_drive_times(context) == []
      assert has_element?(view, "#driving-minutes-0-error", "Enter 0–600 min.")
    end

    test "a save with nothing changed stores nothing and says so", context do
      blocks!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      view |> form("#driving-times-form") |> render_submit()

      assert stored_drive_times(context) == []
      assert render(view) =~ "No changes"
    end

    test "a crafted payload cannot name a pair the day type does not drive", context do
      blocks!(context)
      {:ok, view, _html} = live(editor_conn(context), blocks_path(context.version.id))

      open_drawer(view)

      view
      |> form("#driving-times-form")
      |> render_submit(%{"minutes" => %{"stop:AB_MKT|stop:AB_MKT" => "3"}})

      # The payload named a direction the day type never drove, so nothing was
      # written and the row it pretended to name is untouched.
      assert stored_drive_times(context) == []
      assert has_element?(view, "#driving-time-row-0", "Estimated")
      assert value_of(view, "driving-minutes-0") == "14"
    end
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()

  defp attribute_values(view, selector, attribute) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.attribute(&1, attribute) |> List.first()))
  end
end

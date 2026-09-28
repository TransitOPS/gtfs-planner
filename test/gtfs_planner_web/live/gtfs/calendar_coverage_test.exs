defmodule GtfsPlannerWeb.Gtfs.CalendarCoverageTest do
  @moduledoc """
  The shared coverage axis projected from one calendar screen read.

  `CalendarCoverage.project/2` places one axis for the whole feed: month ticks, the
  today marker, the version-wide gap bands, overview bars for the `:whole` and `:all`
  ranges and exact day cells for `:near`. Every case reads real imported identities
  through `Gtfs.load_calendar_screen/3`, so the geometry is asserted against the real
  `ServiceDates` periods, exceptions and warnings rather than hand-built maps. The
  axis `today` is pinned per case so the near window and the today marker are
  deterministic.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlannerWeb.Gtfs.CalendarCoverage

  @near_days 105
  @max_bins 512

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    agency_fixture(organization.id, version.id, %{agency_timezone: "UTC"})

    %{organization: organization, version: version}
  end

  describe "the near range" do
    test "places 105 inclusive days from the Monday two weeks back with exact day cells",
         context do
      screen = weekday_screen(context) |> pinned(~D[2028-03-01])
      projection = CalendarCoverage.project(screen, :near)

      assert projection.first_date == ~D[2028-02-14]
      assert Date.day_of_week(projection.first_date) == 1
      assert projection.last_date == ~D[2028-05-28]
      assert Date.diff(projection.last_date, projection.first_date) + 1 == @near_days
      assert projection.clipped?
      assert projection.today_position == 16.5 / @near_days

      # The axis names the month it starts in even though it starts mid-month, then marks
      # each later month boundary, with January kept as the retained year boundary.
      assert Enum.map(projection.ticks, & &1.date) == [
               ~D[2028-02-14],
               ~D[2028-03-01],
               ~D[2028-04-01],
               ~D[2028-05-01]
             ]

      assert %{line?: false, year?: false} = List.first(projection.ticks)
      assert List.first(projection.ticks).position == 0.0
      assert Enum.all?(Enum.drop(projection.ticks, 1), & &1.line?)
      refute Enum.any?(projection.ticks, & &1.year?)

      marks = marks!(projection, "WKDY")

      # One cell per served day: the removed leap day and the added Saturday each occupy
      # exactly their own day, and a Saturday the row never serves has no cell at all.
      assert length(marks) <= @near_days
      assert Enum.all?(marks, &(&1.first_date == &1.last_date))
      assert Enum.all?(marks, &(&1.left + &1.width <= 1.0))
      assert marks == Enum.sort_by(marks, & &1.first_date, Date)

      removed = mark!(marks, ~D[2028-02-29])
      assert removed.type == :removed
      assert removed.left == 15 / @near_days
      assert removed.width == 1 / @near_days
      refute removed.mixed?

      added = mark!(marks, ~D[2028-03-11])
      assert added.type == :added
      assert added.left == 26 / @near_days
      assert added.width == 1 / @near_days

      assert mark!(marks, ~D[2028-02-28]).type == :service
      assert mark(marks, ~D[2028-02-19]) == nil

      # A specific-dates identity's own date is its regular service, not an addition.
      special = marks!(projection, "SPECIAL")
      assert [lane] = special
      assert lane.type == :service
      assert lane.first_date == ~D[2028-03-11]
      assert lane.last_date == ~D[2028-03-11]
      assert lane.left == 26 / @near_days
    end

    test "filtering the rows leaves the shared axis unchanged", context do
      screen = weekday_screen(context) |> pinned(~D[2028-03-01])
      full = CalendarCoverage.project(screen, :near)
      filtered = CalendarCoverage.project(%{screen | rows: [row!(screen, "SPECIAL")]}, :near)

      keys = [:first_date, :last_date, :ticks, :today_position, :clipped?, :gap_bands]

      assert Map.take(filtered, keys) == Map.take(full, keys)
      assert Map.keys(filtered.rows) == ["SPECIAL"]
    end
  end

  describe "an axis whose endpoints carry today" do
    test "keeps both endpoints inclusive and reports today only inside the axis", context do
      screen = month_screen(context)

      at_first = CalendarCoverage.project(pinned(screen, ~D[2028-02-01]), :whole)

      assert at_first.first_date == ~D[2028-02-01]
      assert at_first.last_date == ~D[2028-02-29]
      assert at_first.today_position == 0.5 / 29
      assert [%{date: ~D[2028-02-01], line?: true, year?: false}] = at_first.ticks
      assert List.first(at_first.ticks).position == 0.0
      assert at_first.gap_bands == []
      refute at_first.clipped?

      # A row serving every day of the month is one bar covering both endpoints.
      assert [daily] = marks!(at_first, "DAILY")
      assert daily.first_date == ~D[2028-02-01]
      assert daily.last_date == ~D[2028-02-29]
      assert daily.left == 0.0
      assert daily.width == 1.0
      assert daily.type == :service
      refute daily.mixed?

      # A single-day lane covers exactly the leap day at the end of the axis.
      assert [lane] = marks!(at_first, "SPECIAL")
      assert lane.first_date == ~D[2028-02-29]
      assert lane.left == 28 / 29
      assert lane.width == 1 / 29
      assert_in_delta(lane.left + lane.width, 1.0, 1.0e-12)

      at_last = CalendarCoverage.project(pinned(screen, ~D[2028-02-29]), :whole)
      assert at_last.today_position == 28.5 / 29

      # Today outside the axis draws no line and does not move the axis.
      outside = CalendarCoverage.project(pinned(screen, ~D[2030-06-15]), :whole)
      assert outside.first_date == ~D[2028-02-01]
      assert outside.last_date == ~D[2028-02-29]
      assert outside.today_position == nil
      refute outside.clipped?
    end
  end

  describe "a nine-year history" do
    test "stays bounded while the exact additions and removals remain on the screen",
         context do
      screen = long_screen(context) |> pinned(~D[2032-11-15])
      recent = CalendarCoverage.project(screen, :whole)

      # Longer than 24 months, so the default range discloses the window from twelve
      # months before today through the feed's last month.
      assert recent.first_date == ~D[2031-11-01]
      assert recent.last_date == ~D[2032-12-31]
      assert recent.clipped?
      assert Enum.count(recent.ticks, & &1.year?) == 1
      assert Enum.map(Enum.filter(recent.ticks, & &1.year?), & &1.date) == [~D[2032-01-01]]

      span = Date.diff(recent.last_date, recent.first_date) + 1
      assert span == 427

      # The recent window is under the bin ceiling, so its marks are one day wide and the
      # exact dates are readable from the geometry.
      added = mark!(marks!(recent, "LONG"), ~D[2032-02-14])
      assert added.type == :added
      assert added.first_date == ~D[2032-02-14]
      assert added.last_date == ~D[2032-02-14]
      assert added.left == Date.diff(~D[2032-02-14], recent.first_date) / span
      assert added.width == 1 / span

      removed = mark!(marks!(recent, "LONG"), ~D[2032-03-01])
      assert removed.type == :removed
      assert removed.width == 1 / span

      # A removal on a day the row never served draws nothing.
      assert mark(marks!(recent, "LONG"), ~D[2032-04-03]) == nil
      assert mark!(marks!(recent, "MANY"), ~D[2032-03-01]).type == :removed

      exact = row!(screen, "LONG")
      assert exact.periods.extra_days == [~D[2032-02-14]]
      assert exact.periods.holidays == [~D[2032-03-01]]

      assert Enum.map(exact.exceptions, &{&1.date, &1.exception_type}) == [
               {~D[2032-02-14], 1},
               {~D[2032-03-01], 2},
               {~D[2032-04-03], 2}
             ]

      assert Enum.count(row!(screen, "MANY").periods.holidays) == length(many_removals())

      all_years = CalendarCoverage.project(screen, :all)

      assert all_years.first_date == ~D[2024-01-01]
      assert all_years.last_date == ~D[2032-12-31]
      assert Date.diff(all_years.last_date, all_years.first_date) + 1 == 3288
      refute all_years.clipped?
      assert Enum.count(all_years.ticks, & &1.year?) == 9

      for service_id <- ["LONG", "MANY"] do
        marks = marks!(all_years, service_id)

        assert length(marks) <= @max_bins
        assert length(marks) < length(many_removals())

        assert Enum.all?(marks, fn mark ->
                 Date.compare(mark.first_date, mark.last_date) != :gt and
                   Date.compare(mark.first_date, all_years.first_date) != :lt and
                   Date.compare(mark.last_date, all_years.last_date) != :gt and
                   mark.left >= 0.0 and mark.left + mark.width <= 1.0 + 1.0e-9
               end)

        # A compressed bin holding several kinds is flagged as an approximation.
        assert Enum.any?(marks, & &1.mixed?)
        assert Enum.any?(marks, &(Date.diff(&1.last_date, &1.first_date) > 1))
      end
    end
  end

  describe "rows against the axis and version-wide gaps" do
    test "report offscreen before or after while keeping their exact dates", context do
      screen = bounded_screen(context) |> pinned(~D[2028-06-15])
      projection = CalendarCoverage.project(screen, :near)

      assert projection.first_date == ~D[2028-05-29]
      assert projection.last_date == ~D[2028-09-10]

      assert projection.rows["BEFORE"] == %{marks: [], offscreen: :before}
      assert projection.rows["FUTURE"] == %{marks: [], offscreen: :after}

      current = marks!(projection, "AFTER")
      assert current != []

      assert Enum.all?(current, fn mark ->
               Date.compare(mark.first_date, projection.first_date) != :lt and
                 Date.compare(mark.last_date, projection.last_date) != :gt
             end)

      # Drawing the visible slice never limits the domain dates a review reads (INV-5).
      assert row!(screen, "AFTER").last_active_date == ~D[2028-12-29]
      assert row!(screen, "BEFORE").last_active_date == ~D[2028-04-28]
    end

    test "clip the version-wide gaps to the axis and claim none without a complete read",
         context do
      screen = bounded_screen(context) |> pinned(~D[2028-06-15])
      near = CalendarCoverage.project(screen, :near)

      # The gap that starts before the axis begins is cut at the axis start.
      clipped = band!(near.gap_bands, ~D[2028-05-29])
      assert clipped.last_date == ~D[2028-06-18]
      assert clipped.left == 0.0
      assert clipped.width == 21 / @near_days

      # A gap fully inside the axis keeps its exact dates.
      weekend = band!(near.gap_bands, ~D[2028-06-24])
      assert weekend.last_date == ~D[2028-06-25]
      assert weekend.left == 26 / @near_days
      assert weekend.width == 2 / @near_days

      # The same gap is unclipped on the range that covers the whole feed.
      whole = CalendarCoverage.project(screen, :whole)

      assert %{first_date: ~D[2028-04-29], last_date: ~D[2028-06-18]} =
               band!(whole.gap_bands, ~D[2028-04-29])

      # An incomplete read (`gaps: nil`) makes no feed-wide gap claim.
      assert CalendarCoverage.project(%{screen | gaps: nil}, :near).gap_bands == []
    end
  end

  describe "a feed without an evaluated date" do
    test "has no axis for any range instead of dividing by a zero span", context do
      screen = metadata_only_screen(context)
      assert screen.horizon == nil

      for range <- [:whole, :near, :all] do
        projection = CalendarCoverage.project(screen, range)

        assert projection.first_date == nil
        assert projection.last_date == nil
        assert projection.ticks == []
        assert projection.today_position == nil
        assert projection.clipped? == false
        assert projection.gap_bands == []
        assert projection.rows == %{"META_ONLY" => %{marks: [], offscreen: nil}}
      end
    end
  end

  describe "a version holding a retained reversed weekly range" do
    test "draws no coverage for the identity the read refused", context do
      screen = invalid_screen(context) |> pinned(~D[2028-03-01])
      projection = CalendarCoverage.project(screen, :whole)

      assert row!(screen, "REVERSED").coverage_error == %{
               service_id: "REVERSED",
               reason: :reversed_range
             }

      assert projection.rows["REVERSED"] == %{marks: [], offscreen: nil}
      assert marks!(projection, "VALID") != []
      refute projection.rows["VALID"].offscreen
    end
  end

  # -- screens ----------------------------------------------------------------

  # A weekday identity with a removed leap day and an added Saturday, plus a
  # specific-dates identity holding one Saturday.
  defp weekday_screen(context) do
    calendar = """
    service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
    WKDY,1,1,1,1,1,0,0,20280103,20281229
    """

    dates = """
    service_id,date,exception_type
    WKDY,20280229,2
    WKDY,20280311,1
    SPECIAL,20280311,1
    """

    attributes = """
    service_id,service_description
    WKDY,Weekday Service
    SPECIAL,Single Saturday
    """

    read_screen(context, calendar, dates, attributes)
  end

  # Every day of February 2028, the feed's whole span, plus a one-day lane on the leap day.
  defp month_screen(context) do
    calendar = """
    service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
    DAILY,1,1,1,1,1,1,1,20280201,20280229
    """

    dates = """
    service_id,date,exception_type
    SPECIAL,20280229,1
    """

    attributes = """
    service_id,service_description
    DAILY,Every Day
    SPECIAL,Leap Day
    """

    read_screen(context, calendar, dates, attributes)
  end

  # Nine years of weekdays: one identity with a single addition and two removals, and one
  # with a removal on every Monday and Wednesday.
  defp long_screen(context) do
    calendar = """
    service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
    LONG,1,1,1,1,1,0,0,20240101,20321231
    MANY,1,1,1,1,1,0,0,20240101,20321231
    """

    dates =
      """
      service_id,date,exception_type
      LONG,20320214,1
      LONG,20320301,2
      LONG,20320403,2
      """ <> removal_rows("MANY", many_removals())

    attributes = """
    service_id,service_description
    LONG,Long History
    MANY,Many Removals
    """

    read_screen(context, calendar, dates, attributes)
  end

  # A weekday identity that ends before the near axis, one that starts inside it and one
  # that starts after it.
  defp bounded_screen(context) do
    calendar = """
    service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
    BEFORE,1,1,1,1,1,0,0,20280103,20280428
    AFTER,1,1,1,1,1,0,0,20280619,20281229
    FUTURE,1,1,1,1,1,0,0,20290101,20290330
    """

    attributes = """
    service_id,service_description
    BEFORE,Ended Before
    AFTER,Starts After The Gap
    FUTURE,Starts Next Year
    """

    read_screen(context, calendar, "", attributes)
  end

  defp metadata_only_screen(context) do
    attributes = """
    service_id,service_description
    META_ONLY,Metadata Only
    """

    read_screen(context, "", "", attributes)
  end

  defp invalid_screen(context) do
    calendar = """
    service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date
    REVERSED,1,1,1,1,1,0,0,20281231,20280101
    VALID,1,1,1,0,0,0,0,20280301,20280331
    """

    attributes = """
    service_id,service_description
    REVERSED,Reversed Weekday
    VALID,Valid Weekday
    """

    read_screen(context, calendar, "", attributes)
  end

  defp many_removals do
    ~D[2024-01-01]
    |> Date.range(~D[2032-12-31])
    |> Enum.filter(&(Date.day_of_week(&1) in [1, 3]))
  end

  defp removal_rows(service_id, dates) do
    Enum.map_join(dates, fn date ->
      "#{service_id},#{date |> Date.to_iso8601() |> String.replace("-", "")},2\n"
    end)
  end

  # -- reads ------------------------------------------------------------------

  defp read_screen(context, calendar, dates, attributes) do
    files =
      [
        {"calendar.txt", calendar},
        {"calendar_dates.txt", dates},
        {"calendar_attributes.txt", attributes}
      ]
      |> Enum.reject(fn {_filename, content} -> content == "" end)
      |> Enum.map(fn {filename, content} -> %{filename: filename, content: content} end)

    assert {:ok, _result} =
             Import.import_files(context.organization.id, context.version.id, files)

    assert {:ok, screen} = Gtfs.load_calendar_screen(context.organization.id, context.version.id)

    screen
  end

  defp pinned(screen, today), do: %{screen | today: today}

  # -- lookups ----------------------------------------------------------------

  defp row!(screen, service_id) do
    Enum.find(screen.rows, &(&1.service_id == service_id)) ||
      flunk(
        "expected a row for #{service_id}, got: #{inspect(Enum.map(screen.rows, & &1.service_id))}"
      )
  end

  defp marks!(projection, service_id), do: projection.rows[service_id].marks

  defp mark(marks, date), do: Enum.find(marks, &(&1.first_date == date and &1.last_date == date))

  defp mark!(marks, date) do
    mark(marks, date) ||
      flunk(
        "expected a single-day mark on #{date}, got: #{inspect(Enum.map(marks, &{&1.type, &1.first_date, &1.last_date}))}"
      )
  end

  defp band!(bands, first_date) do
    Enum.find(bands, &(&1.first_date == first_date)) ||
      flunk("expected a gap band from #{first_date}, got: #{inspect(bands)}")
  end
end

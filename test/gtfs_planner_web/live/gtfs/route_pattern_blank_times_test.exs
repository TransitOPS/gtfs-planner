defmodule GtfsPlannerWeb.Gtfs.RoutePatternBlankTimesTest do
  @moduledoc """
  Running times reads a stop with no scheduled time as absence, not midnight.

  Every case drives the editor through its real route with
  `Phoenix.LiveViewTest`, over timing rows written straight to the database with
  nil offsets, so the rendering under test is the one a reviewer loads. The
  expected values are literals: the rule that a blank stop keeps no time, the
  note's own count of the rows it found, and the offsets the fixture stored.
  """

  use GtfsPlannerWeb.ConnCase, async: false

  import Ecto.Query, except: [select: 2]
  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  setup :editor_scope

  describe "a timing with blank stops" do
    test "the note counts the blank stops and the legend names what saving keeps", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      %{route: route, pattern: pattern} = ten_stop_pattern(organization, version, "BLANK1")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      assert has_element?(view, "#timing-blank-note", "8 stops don’t have times yet")

      assert has_element?(
               view,
               "#timing-blank-legend",
               "Timepoints, the first stop and the last stop always need a time."
             )
    end

    test "a blank row's cells are empty rather than midnight, and carry the no-time mark", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      %{route: route, pattern: pattern} = ten_stop_pattern(organization, version, "BLANK2")

      {:ok, view, html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      for position <- [2, 5, 9] do
        assert input_value(html, "#timing-arrival-#{position}") == [""]
        assert input_value(html, "#timing-departure-#{position}") == [""]
        assert input_attribute(html, "#timing-arrival-#{position}", "placeholder") == ["—"]
        assert input_attribute(html, "#timing-departure-#{position}", "placeholder") == ["—"]
        assert has_element?(view, "#timing-no-time-#{position}", "no scheduled time")
      end

      # The timed ends keep their own values, so the grid is not uniformly blank
      # and a reader can tell a blank from a midnight.
      assert input_value(html, "#timing-arrival-1") == ["00:00"]
      assert input_value(html, "#timing-departure-10") == ["20:00"]

      assert has_element?(view, "#timing-preview-2", "—")
      assert has_element?(view, "#timing-blank-legend", "no scheduled time")
    end

    test "the legend links to the version's Export defaults", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      %{route: route, pattern: pattern} = ten_stop_pattern(organization, version, "BLANK3")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      assert has_element?(
               view,
               "#timing-blank-legend a[href='/gtfs/#{version.id}/settings/export-defaults']",
               "Export defaults"
             )
    end

    test "the blank rows stay blank and are not filled behind the person", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      %{route: route, pattern: pattern} = ten_stop_pattern(organization, version, "BLANK4")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      html = render(view)

      # Main's Fill control (spec 23's estimator) is still offered, so this
      # step no longer asserts its absence. What the spec does require is that
      # no fill has been applied: the cells render blank, and no row carries
      # the Estimated badge that a filled preview would add.
      assert has_element?(view, "#timing-blank-fill")
      refute html =~ "Estimated"
      assert has_element?(view, "#timing-blank-legend", "no scheduled time")
    end

    test "typing a time into a blank row withdraws its mark and the note recounts", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      %{route: route, pattern: pattern, occurrence_rows: occurrence_rows, timing: timing} =
        ten_stop_pattern(organization, version, "BLANK5")

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      assert has_element?(view, "#timing-blank-note", "8 stops don’t have times yet")

      render_change(view, "validate_timing_row", %{
        "_target" => ["timing", "2", "arrival"],
        "timing" => %{"2" => %{"arrival" => "05:00", "departure" => "05:00"}}
      })

      assert has_element?(view, "#timing-blank-note", "7 stops don’t have times yet")
      refute has_element?(view, "#timing-no-time-2")
      assert has_element?(view, "#timing-arrival-2[value='05:00']")

      # The change is the editor's staged edit; nothing is stored until the save
      # is reviewed, and the stored row is still the blank pair.
      assert timing_offsets(timing, occurrence_rows) == [
               0,
               nil,
               nil,
               nil,
               nil,
               nil,
               nil,
               nil,
               nil,
               1200
             ]
    end
  end

  describe "a fully timed timing" do
    test "carries no note, no legend and no mark", %{
      conn: conn,
      organization: organization,
      version: version
    } do
      %{route: route, pattern: pattern, occurrence_rows: occurrence_rows} =
        ten_stop_pattern(organization, version, "FULL1")

      timing = timed_pattern_fixture(pattern, %{name: "Weekday"})

      occurrence_rows
      |> Enum.with_index(0)
      |> Enum.each(fn {occurrence, index} ->
        timed_pattern_stop_fixture(timing, occurrence, %{
          arrival_offset: index * 120,
          departure_offset: index * 120,
          timepoint: 1
        })
      end)

      {:ok, view, _html} = live(conn, pattern_path(version, route, pattern, "?task=timings"))

      # The pattern also carries the blank timing the fixture built, so the
      # fully timed one is chosen the way a person chooses it.
      render_change(view, "select_timing", %{"timing_id" => timing.id})

      html = render(view)

      assert timing_offsets(timing, occurrence_rows) == Enum.map(0..9, &(&1 * 120))

      refute has_element?(view, "#timing-blank-note")
      refute has_element?(view, "#timing-blank-legend")
      refute has_element?(view, "#timing-no-time-2")
      refute html =~ "no scheduled time"
      assert input_value(html, "#timing-arrival-3") == ["04:00"]
    end
  end

  defp editor_scope(%{conn: conn}) do
    organization =
      organization_fixture(%{alias: "route-pattern-blank-#{System.system_time(:nanosecond)}"})

    user =
      user_fixture(%{email: "pattern-blank-#{System.unique_integer([:positive])}@example.com"})

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    %{
      conn: log_in_user(conn, user, organization: organization),
      organization: organization,
      version: version
    }
  end

  # Ten stops whose first and last rows are timed and whose eight interior rows
  # carry no time at all, which is the shape the rule allows: a blank is only
  # ever a non-timepoint stop between the ends.
  defp ten_stop_pattern(organization, version, route_id) do
    route =
      route_fixture(organization.id, version.id, %{
        route_id: route_id,
        route_short_name: route_id,
        route_long_name: "#{route_id} corridor"
      })

    stops =
      for index <- 1..10 do
        stop_fixture(organization.id, version.id, %{
          stop_id: "#{route_id}_S#{index}",
          stop_name: "#{route_id} Stop #{index}",
          location_type: 0
        })
      end

    pattern =
      route_pattern_fixture(organization.id, version.id, %{
        route_id: route.route_id,
        route_pattern_id: "P-#{route_id}",
        route_pattern_name: "P-#{route_id}",
        direction_id: 0
      })

    occurrence_rows =
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, position} ->
        route_pattern_stop_fixture(pattern, stop.stop_id, position)
      end)

    timing = timed_pattern_fixture(pattern, %{name: "Summer weekday supplement"})

    occurrence_rows
    |> Enum.with_index(1)
    |> Enum.each(fn {occurrence, position} ->
      if position in [1, 10] do
        timed_pattern_stop_fixture(timing, occurrence, %{
          arrival_offset: if(position == 1, do: 0, else: 1200),
          departure_offset: if(position == 1, do: 0, else: 1200),
          timepoint: 1
        })
      else
        interior = timed_pattern_stop_fixture(timing, occurrence, %{timepoint: 0})
        # Nil means absent here, so the pair is cleared through the same
        # changeset the app writes rather than by hand.
        interior
        |> TimedPatternStop.changeset(%{arrival_offset: nil, departure_offset: nil})
        |> Repo.update!()
      end
    end)

    %{
      route: route,
      stops: stops,
      pattern: pattern,
      occurrence_rows: occurrence_rows,
      timing: timing
    }
  end

  # The stored arrival offsets in pattern order, which is the shape the editor
  # loads and the source of the note's count.
  defp timing_offsets(timing, occurrence_rows) do
    position_by_id = Map.new(occurrence_rows, &{&1.id, &1.position})

    TimedPatternStop
    |> where([r], r.timed_pattern_id == ^timing.id)
    |> Repo.all()
    |> Map.new(&{position_by_id[&1.route_pattern_stop_id], &1.arrival_offset})
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  defp pattern_path(version, route, pattern, suffix) do
    "/gtfs/#{version.id}/routes/#{route.route_id}/patterns/#{pattern.route_pattern_id}#{suffix}"
  end

  # An input's rendered attribute values, so an empty cell is read as the empty
  # string it renders rather than as a missing attribute.
  defp input_attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, name))
  end

  defp input_value(html, selector), do: input_attribute(html, selector, "value")
end

defmodule GtfsPlannerWeb.Gtfs.RouteSchedulesGridMarkupTest do
  # EV-20: the timetable grid's cell identity and its preview, pending,
  # just-changed and error states (spec 18, step 21; CL-13, FH-32).
  #
  # The loaded-route cases mount through the authenticated router, so the cells
  # come from the production composition (`RouteSchedulesLive` -> `Gtfs` facade ->
  # `Schedules` read -> `ScheduleComponents.section/1`). The state cases render
  # `section/1` directly with the exact `grid` map `display_sections/1` puts on
  # every section, because the events that produce previews, just-changed rows and
  # cell errors arrive in later steps (25, 29) and the pixels are not this file's
  # claim. Every id, position and title is literal and hand-derived from the
  # contract in step 21 and spec.md section 4.5, never computed by the code under
  # test. The grid hook itself is registered in step 22; until then
  # `phx-hook="TimetableGrid"` is an inert attribute.
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlanner.ScheduleEditingFixtures
  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  @route_id "EDT_GRID"

  # The grid contracts live on the natural trip id and the trip UUID separately:
  # ids use the natural id, `data-trip` the UUID.
  @trip_id "GRID_T1"
  @trip_uuid "8a5b4f0e-6f4d-4a0e-9a3e-7c6d5b4a3c2d"

  setup context do
    scope = ScheduleEditingFixtures.editing_scope!(@route_id)

    {:ok,
     conn: log_in_user(context.conn, scope.actor, organization: scope.organization), scope: scope}
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp first_attr(document, selector, attribute),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute) |> List.first()

  defp schedules_path(scope), do: "/gtfs/#{scope.version.id}/routes/#{@route_id}/schedules"

  describe "a loaded timetable" do
    test "marks every cell with its trip, occurrence position and tab stop", %{
      conn: conn,
      scope: scope
    } do
      trip = ScheduleEditingFixtures.linked_trip!(scope, "07:00:00", %{trip_id: @trip_id})

      {:ok, view, _html} = live(conn, schedules_path(scope))
      document = doc(render(view))

      assert first_attr(document, "#schedules-grid", "phx-hook") == "TimetableGrid"
      assert first_attr(document, "#schedules-grid", "data-grid-revision") == "0"
      assert Enum.count(LazyHTML.query(document, "#schedules-grid > #schedules-sections")) == 1

      # One cell per occurrence position, plus the Timing cell. The Departs cell
      # carries the first occurrence's position, so it has no separate id.
      assert Enum.count(LazyHTML.query(document, "#schedules-grid td[id^='cell-']")) == 4

      for position <- [1, 2, 3] do
        cell = LazyHTML.query(document, "#cell-#{@trip_id}-#{position}")

        assert Enum.count(cell) == 1
        assert LazyHTML.attribute(cell, "data-trip") == [trip.id]
        assert LazyHTML.attribute(cell, "data-pos") == [to_string(position)]
        assert LazyHTML.attribute(cell, "tabindex") == ["-1"]
      end

      timing = LazyHTML.query(document, "#cell-#{@trip_id}-timing")

      assert LazyHTML.attribute(timing, "data-trip") == [trip.id]
      assert LazyHTML.attribute(timing, "tabindex") == ["-1"]
    end

    test "renders the empty in-cell editor once, inside the hook and outside the stream", %{
      conn: conn,
      scope: scope
    } do
      ScheduleEditingFixtures.linked_trip!(scope, "07:00:00", %{trip_id: @trip_id})

      {:ok, view, _html} = live(conn, schedules_path(scope))
      document = doc(render(view))

      assert Enum.count(LazyHTML.query(document, "#cell-editor")) == 1
      assert first_attr(document, "#cell-editor", "phx-update") == "ignore"
      assert Enum.count(LazyHTML.query(document, "#schedules-grid > #cell-editor")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#schedules-sections #cell-editor"))
    end

    test "keeps a frequency row's italic reference cells", %{conn: conn, scope: scope} do
      trip =
        ScheduleEditingFixtures.frequency_trip!(scope, [{21_600, 25_200, 900}], %{
          trip_id: "GRID_FREQ"
        })

      {:ok, view, _html} = live(conn, schedules_path(scope))
      document = doc(render(view))

      for position <- [2, 3] do
        assert first_attr(document, "#cell-#{trip.trip_id}-#{position}", "class") =~ "italic"
        assert first_attr(document, "#cell-#{trip.trip_id}-#{position}", "data-trip") == trip.id
      end

      refute first_attr(document, "#cell-#{trip.trip_id}-1", "class") =~ "italic"
    end
  end

  describe "the grid states a section carries" do
    test "a refused edit marks its cell and renders the error row under the trip" do
      section =
        section_fixture(%{
          grid: %{
            preview: %{},
            just_changed: MapSet.new(),
            cell_error: %{
              trip: @trip_uuid,
              position: 2,
              message: "Market Square, 07:00 trip: 7:75 isn't a time. Type 7:45, 745 or +3."
            }
          }
        })

      document = doc(render_section(section))

      assert first_attr(document, "#cell-GRID_T1-2", "class") =~ "is-error"
      refute first_attr(document, "#cell-GRID_T1-1", "class") =~ "is-error"
      refute first_attr(document, "#cell-GRID_T1-timing", "class") =~ "is-error"

      assert text(document, "#trip-GRID_T1-error") =~ "7:75 isn't a time"
      assert first_attr(document, "#trip-GRID_T1-error td", "colspan") == "7"
    end

    test "a reviewed change previews the new time and titles the old one" do
      section =
        section_fixture(%{
          grid: %{
            preview: %{@trip_uuid => %{2 => 26_880}},
            just_changed: MapSet.new(),
            cell_error: nil
          }
        })

      document = doc(render_section(section))

      assert first_attr(document, "#cell-GRID_T1-2", "class") =~ "is-preview"
      assert first_attr(document, "#cell-GRID_T1-2", "title") == "Was 07:10"
      assert text(document, "#cell-GRID_T1-2") == "07:28"
      refute first_attr(document, "#cell-GRID_T1-1", "class") =~ "is-preview"
    end

    test "a cleared preview cell keeps the warning tone and shows the em dash" do
      section =
        section_fixture(%{
          grid: %{
            preview: %{@trip_uuid => %{2 => nil}},
            just_changed: MapSet.new(),
            cell_error: nil
          }
        })

      document = doc(render_section(section))

      assert first_attr(document, "#cell-GRID_T1-2", "class") =~ "is-preview"
      assert first_attr(document, "#cell-GRID_T1-2", "title") == "Was 07:10"
      assert text(document, "#cell-GRID_T1-2") == "—"
    end

    test "a preview that crosses midnight keeps its day marker" do
      section =
        section_fixture(%{
          grid: %{
            preview: %{@trip_uuid => %{2 => 90_600}},
            just_changed: MapSet.new(),
            cell_error: nil
          }
        })

      document = doc(render_section(section))

      assert text(document, "#cell-GRID_T1-2") =~ "25:10"
      assert text(document, "#cell-GRID_T1-2") =~ "+1 day"
      assert first_attr(document, "#cell-GRID_T1-2", "title") == "Was 07:10"
    end

    test "the rows the last write touched take the just-changed tint" do
      section =
        section_fixture(%{
          grid: %{preview: %{}, just_changed: MapSet.new([@trip_uuid]), cell_error: nil}
        })

      document = doc(render_section(section))

      assert first_attr(document, "#trip-GRID_T1", "class") =~ "is-changed"
    end

    test "a section without grid state renders none of the states" do
      document = doc(render_section(Map.delete(section_fixture(%{}), :grid)))

      refute first_attr(document, "#trip-GRID_T1", "class") =~ "is-changed"
      refute first_attr(document, "#cell-GRID_T1-2", "class") =~ "is-preview"
      refute first_attr(document, "#cell-GRID_T1-2", "class") =~ "is-error"
      assert Enum.empty?(LazyHTML.query(document, "#trip-GRID_T1-error"))
    end
  end

  # --- section fixtures ------------------------------------------------------

  defp render_section(section) do
    assigns = %{section: section, selected_ids: MapSet.new(), calendar_label: "Weekday"}

    rendered_to_string(~H"""
    <ScheduleComponents.section
      section={@section}
      selected_ids={@selected_ids}
      calendar_label={@calendar_label}
    />
    """)
  end

  defp section_fixture(overrides) do
    section = %{
      pattern: %{
        route_pattern_id: "GRID-P1",
        route_pattern_name: "Grid pattern",
        route_pattern_typicality: 1
      },
      stops: :timepoints,
      columns: [column(1, "Oak Avenue", "101"), column(2, "Market Square", "102")],
      all_columns: [column(1, "Oak Avenue", "101"), column(2, "Market Square", "102")],
      omitted_stop_count: 0,
      rows: [row_fixture()],
      bands: [],
      timing_lines: [
        %{timing_id: 1, name: "Base", trip_count: 1, segments: [], total_secs: 600}
      ],
      custom_trip_count: 0,
      grid: %{preview: %{}, just_changed: MapSet.new(), cell_error: nil}
    }

    Map.merge(section, overrides)
  end

  defp column(position, stop_name, stop_code) do
    %{position: position, stop_id: "GRID_#{position}", stop_name: stop_name, stop_code: stop_code}
  end

  defp row_fixture do
    %{
      id: @trip_uuid,
      trip_id: @trip_id,
      start_secs: 25_200,
      start_cell: %{text: "07:00", marker: nil, title: nil, missing?: false},
      timing: "Base",
      headsign: nil,
      trip_short_name: nil,
      block_id: nil,
      trip_headsign: nil,
      timed_pattern_id: 1,
      service_id: "GRID_SVC",
      direction_id: 0,
      route_pattern_id: "GRID-P1",
      wheelchair_accessible: nil,
      bikes_allowed: nil,
      frequency_label: nil,
      frequency?: false,
      custom?: false,
      stops_differ?: false,
      updated_at: ~U[2026-09-01 12:00:00.000000Z],
      cells: %{
        1 => %{text: "07:00", marker: nil, title: nil, missing?: false},
        2 => %{text: "07:10", marker: nil, title: nil, missing?: false}
      }
    }
  end
end

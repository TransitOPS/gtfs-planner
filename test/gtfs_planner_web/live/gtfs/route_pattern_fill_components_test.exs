# Step 13 render coverage: each prototype state carries its markers and §4.5 element IDs.
# Execution is deferred to branch review (EV-13); this file is written but not run in this step.

defmodule GtfsPlannerWeb.Gtfs.RoutePatternFillComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Gtfs.RoutePatternComponents

  alias GtfsPlanner.Gtfs.TimingFill

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(html, selector) do
    html
    |> doc()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp count(html, selector) do
    html |> doc() |> LazyHTML.query(selector) |> Enum.count()
  end

  defp grid_row(position, arrival, departure, timepoint, extra \\ %{}) do
    Map.merge(
      %{
        position: position,
        name: "Stop #{position}",
        stop_id: "S#{position}",
        arrival: arrival,
        departure: departure,
        stored_arrival: arrival,
        stored_departure: departure,
        timepoint: timepoint,
        estimated: false,
        preview_arrival: "08:00",
        preview_departure: "08:00",
        pickup: "0",
        drop_off: "0",
        stop_headsign: "",
        arrival_error: nil,
        departure_error: nil
      },
      extra
    )
  end

  defp staged(position, arrival, departure, timepoint) do
    %{position: position, arrival: arrival, departure: departure, timepoint: timepoint}
  end

  defp render_task(rows, opts \\ %{}) do
    base = %{
      timings: [%{timing: %{id: "t1"}, trip_count: 2}],
      selected_timing: %{id: "t1", name: "Weekday"},
      timing_rows: rows,
      timing_form: to_form(%{"timing_id" => "t1"}),
      timing_options: [{"Weekday", "t1"}],
      preview_time: "08:00",
      timing_headsign: "",
      timing_error: nil,
      timing_blank_note: nil,
      blank_count: 0,
      fill: nil,
      fill_preview: nil,
      fill_distances: [],
      fill_coords: [],
      retime: nil,
      offline?: false,
      custom_trip_count: 0,
      dirty?: false,
      busy?: false,
      filling?: false
    }

    assigns = %{task: Map.merge(base, opts)}

    rendered_to_string(~H"""
    <RoutePatternComponents.timings_task
      timings={@task.timings}
      selected_timing={@task.selected_timing}
      timing_rows={@task.timing_rows}
      timing_form={@task.timing_form}
      timing_options={@task.timing_options}
      preview_time={@task.preview_time}
      timing_headsign={@task.timing_headsign}
      timing_error={@task.timing_error}
      timing_blank_note={@task.timing_blank_note}
      blank_count={@task.blank_count}
      fill={@task.fill}
      fill_preview={@task.fill_preview}
      fill_distances={@task.fill_distances}
      fill_coords={@task.fill_coords}
      retime={@task.retime}
      offline?={@task.offline?}
      custom_trip_count={@task.custom_trip_count}
      dirty?={@task.dirty?}
      busy?={@task.busy?}
      filling?={@task.filling?}
    />
    """)
  end

  defp coords do
    [{44.6, -124.05}, {44.61, -124.04}, {44.62, -124.03}, {44.63, -124.02}]
  end

  describe "blank note (rt-blank)" do
    test "names the blank stops and offers the fill action" do
      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(3, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(4, "08:00", "08:00", true)
      ]

      html = render_task(rows, %{blank_count: 2})

      assert text(html, "#timing-blank-note") =~ "2 stops don’t have times yet"
      assert text(html, "#timing-blank-fill") =~ "Fill times"
      refute text(html, "#pattern-timings-task") =~ "Preview · not saved"
    end
  end

  describe "preview with missing times (rt-fill)" do
    setup do
      staged_rows = [
        staged(1, "00:00", "00:00", true),
        staged(2, "", "", false),
        staged(3, "", "", false),
        staged(4, "08:00", "08:00", true)
      ]

      distances = [0, 200, 600, 3000]
      fill = %{scope: :missing, method: :distance, only_anchor: nil}

      preview =
        TimingFill.preview(staged_rows, distances, coords(), scope: :missing, method: :distance)

      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(3, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(4, "08:00", "08:00", true)
      ]

      html =
        render_task(rows, %{
          fill: fill,
          fill_preview: preview,
          fill_distances: distances,
          fill_coords: coords(),
          filling?: true
        })

      %{html: html, preview: preview}
    end

    test "renders the panel contract IDs and the missing scope", %{html: html} do
      assert text(html, "#fill-panel #fill-title") =~ "Fill times between timepoints"
      assert text(html, "#fill-summary") =~ "Fills 2 stops"
      assert count(html, "#fill-scope-missing[checked]") == 1
      assert count(html, "#fill-method-distance[checked]") == 1
      assert text(html, "#fill-apply") =~ "Fill 2 stops"
      assert count(html, "#fill-cancel") == 1
    end

    test "preview cells show the estimate and its was text", %{html: html} do
      assert text(html, "#timing-cell-estimate-2") =~ ~r/\d\d:\d\d/
      assert text(html, "#timing-row-2") =~ "was blank"
      assert text(html, "#timing-row-3") =~ "was blank"
    end

    test "the chart marks two anchors and two estimates", %{html: html} do
      assert count(html, "#fill-profile svg") == 1
      assert count(html, "#fill-profile svg rect") == 2
      assert count(html, "#fill-profile svg circle") == 2
      assert text(html, "#fill-profile") =~ "mph"
    end

    test "the map container carries lon/lat JSON and stays untouched", %{html: html} do
      map = html |> doc() |> LazyHTML.query("#fill-map")
      assert LazyHTML.attribute(map, "phx-update") == ["ignore"]

      payload = map |> LazyHTML.attribute("data-fill-map") |> List.first() |> Jason.decode!()
      first = hd(payload["stops"])
      assert first["coord"] == [-124.05, 44.6]

      assert Enum.map(payload["stops"], & &1["kind"]) == [
               "timepoint",
               "estimate",
               "estimate",
               "timepoint"
             ]
    end
  end

  describe "preview recalculating everything (rt-fill-between)" do
    test "recalculated cells show the replaced value" do
      staged_rows = [
        staged(1, "00:00", "00:00", true),
        staged(2, "06:00", "06:00", false),
        staged(3, "08:00", "08:00", true)
      ]

      distances = [0, 1000, 3000]
      fill = %{scope: :between, method: :distance, only_anchor: nil}

      preview =
        TimingFill.preview(staged_rows, distances, coords() |> Enum.take(3),
          scope: :between,
          method: :distance
        )

      assert preview.changed == 1

      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "06:00", "06:00", false),
        grid_row(3, "08:00", "08:00", true)
      ]

      html =
        render_task(rows, %{
          fill: fill,
          fill_preview: preview,
          fill_distances: distances,
          fill_coords: Enum.take(coords(), 3),
          filling?: true
        })

      assert text(html, "#fill-summary") =~ "Recalculates 1 stop"
      assert count(html, "#fill-scope-between[checked]") == 1
      assert text(html, "#timing-row-2") =~ "was 06:00"
    end
  end

  describe "equal shares (rt-fill-even)" do
    test "checks the even method and still fills the blanks" do
      staged_rows = [
        staged(1, "00:00", "00:00", true),
        staged(2, "", "", false),
        staged(3, "", "", false),
        staged(4, "08:00", "08:00", true)
      ]

      distances = [0, 200, 600, 3000]
      fill = %{scope: :missing, method: :even, only_anchor: nil}

      preview =
        TimingFill.preview(staged_rows, distances, coords(), scope: :missing, method: :even)

      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(3, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(4, "08:00", "08:00", true)
      ]

      html =
        render_task(rows, %{
          fill: fill,
          fill_preview: preview,
          fill_distances: distances,
          fill_coords: coords(),
          filling?: true
        })

      assert count(html, "#fill-method-even[checked]") == 1
      assert text(html, "#fill-summary") =~ "Fills 2 stops"
      assert text(html, "#timing-row-2") =~ "was blank"
    end
  end

  describe "missing path (rt-fill-nopath)" do
    test "warns that the span uses the straight line" do
      staged_rows = [
        staged(1, "00:00", "00:00", true),
        staged(2, "", "", false),
        staged(3, "", "", false),
        staged(4, "08:00", "08:00", true)
      ]

      fill = %{scope: :missing, method: :distance, only_anchor: nil}

      preview =
        TimingFill.preview(staged_rows, [nil, nil, nil, nil], coords(),
          scope: :missing,
          method: :distance
        )

      assert Enum.any?(preview.spans, &(&1.source == :straight_line))

      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(3, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(4, "08:00", "08:00", true)
      ]

      html =
        render_task(rows, %{
          fill: fill,
          fill_preview: preview,
          fill_distances: [nil, nil, nil, nil],
          fill_coords: coords(),
          filling?: true
        })

      assert text(html, "#fill-problems") =~ "straight line"
      assert text(html, "#fill-use-even") =~ "Use equal time per stop"
      assert count(html, "#fill-profile svg") == 1
    end
  end

  describe "out of order (rt-fill-order)" do
    test "problem buttons target the stop input to fix" do
      staged_rows = [
        staged(1, "00:00", "00:00", true),
        staged(2, "05:00", "05:00", true),
        staged(3, "03:00", "03:00", true)
      ]

      distances = [0, 1000, 2000]
      fill = %{scope: :missing, method: :distance, only_anchor: nil}

      preview =
        TimingFill.preview(staged_rows, distances, Enum.take(coords(), 3),
          scope: :missing,
          method: :distance
        )

      assert Enum.any?(preview.problems, &(&1.kind == :order))

      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "05:00", "05:00", true),
        grid_row(3, "03:00", "03:00", true)
      ]

      html =
        render_task(rows, %{
          fill: fill,
          fill_preview: preview,
          fill_distances: distances,
          fill_coords: Enum.take(coords(), 3),
          filling?: true
        })

      assert text(html, "#fill-problems") =~ "timed before"

      buttons =
        html |> doc() |> LazyHTML.query("#fill-problems button[phx-click='focus_form_error']")

      targets = LazyHTML.attribute(buttons, "phx-value-id")
      assert "timing-arrival-3" in targets
      assert text(html, "#fill-apply") =~ "Fill stops"
    end
  end

  describe "timepoint without time (rt-fill-tpblank)" do
    test "names the timepoint and points at its input" do
      staged_rows = [
        staged(1, "00:00", "00:00", true),
        staged(2, "", "", true),
        staged(3, "08:00", "08:00", true)
      ]

      distances = [0, 1000, 2000]
      fill = %{scope: :missing, method: :distance, only_anchor: nil}

      preview =
        TimingFill.preview(staged_rows, distances, Enum.take(coords(), 3),
          scope: :missing,
          method: :distance
        )

      assert Enum.any?(preview.problems, &(&1.kind == :timepoint_without_time))

      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "", "", true, %{stored_arrival: "", stored_departure: ""}),
        grid_row(3, "08:00", "08:00", true)
      ]

      html =
        render_task(rows, %{
          fill: fill,
          fill_preview: preview,
          fill_distances: distances,
          fill_coords: Enum.take(coords(), 3),
          filling?: true
        })

      assert text(html, "#fill-problems") =~ "timepoint without a time"

      buttons =
        html |> doc() |> LazyHTML.query("#fill-problems button[phx-click='focus_form_error']")

      assert "timing-arrival-2" in LazyHTML.attribute(buttons, "phx-value-id")
    end
  end

  describe "fast pace (rt-fill-fast)" do
    test "warns in the panel and styles the chart label" do
      staged_rows = [
        staged(1, "00:00", "00:00", true),
        staged(2, "", "", false),
        staged(3, "01:00", "01:00", true)
      ]

      distances = [0, 5000, 10_000]
      fill = %{scope: :missing, method: :distance, only_anchor: nil}

      preview =
        TimingFill.preview(staged_rows, distances, Enum.take(coords(), 3),
          scope: :missing,
          method: :distance
        )

      assert preview.fast_spans != []

      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(3, "01:00", "01:00", true)
      ]

      html =
        render_task(rows, %{
          fill: fill,
          fill_preview: preview,
          fill_distances: distances,
          fill_coords: Enum.take(coords(), 3),
          filling?: true
        })

      assert text(html, "#fill-problems") =~ "mph"

      label_texts =
        html
        |> doc()
        |> LazyHTML.query("#fill-profile svg text")
        |> Enum.map(&LazyHTML.text/1)

      assert Enum.count(label_texts, &(&1 =~ ~r/\d+ mph/)) == 1
      assert html =~ "fill-warning-fg font-bold"
      assert count(html, "#fill-profile svg rect") == 2
      assert count(html, "#fill-profile svg circle") == 1
    end
  end

  describe "applied estimates (rt-applied)" do
    test "estimated cells carry the badge and cyan classes while typed cells keep amber" do
      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "00:32", "00:32", false, %{
          stored_arrival: "",
          stored_departure: "",
          estimated: true
        }),
        grid_row(3, "01:36", "01:36", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(4, "08:00", "08:00", true)
      ]

      html = render_task(rows)

      assert text(html, "#timing-row-2") =~ "Estimated"
      arrival2 = html |> doc() |> LazyHTML.query("#timing-arrival-2")
      assert arrival2 |> LazyHTML.attribute("class") |> List.first() =~ "bg-soft"

      arrival3 = html |> doc() |> LazyHTML.query("#timing-arrival-3")
      assert arrival3 |> LazyHTML.attribute("class") |> List.first() =~ "bg-warning-bg"
    end
  end

  describe "re-estimate prompt (rt-retime)" do
    test "offers the anchor-limited preview" do
      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "05:00", "05:00", true),
        grid_row(3, "08:00", "08:00", true)
      ]

      html = render_task(rows, %{retime: %{anchor: 2, moved_seconds: 120, stops: 1}})

      assert text(html, "#timing-retime") =~ "Stop 2 moved by 02:00 later"
      assert text(html, "#timing-retime") =~ "1 stop would move"
      assert text(html, "#timing-retime-go") =~ "Re-estimate around stop 2"
    end
  end

  describe "save blocked on blanks (rt-save-blank)" do
    test "keeps the specific message with a fill action" do
      rows = [
        grid_row(1, "00:00", "00:00", true),
        grid_row(2, "", "", false, %{stored_arrival: "", stored_departure: ""}),
        grid_row(3, "08:00", "08:00", true)
      ]

      html =
        render_task(rows, %{
          timing_blank_note: "1 stop needs times before you can save.",
          blank_count: 1
        })

      assert text(html, "#timing-blank-note") =~ "1 stop needs times before you can save."
      assert count(html, "#timing-blank-fill") == 1
    end
  end
end

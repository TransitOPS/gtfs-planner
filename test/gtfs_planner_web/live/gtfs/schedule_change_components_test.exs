defmodule GtfsPlannerWeb.Gtfs.ScheduleChangeComponentsTest do
  # EV-31: the frequency windows editor and the riders-see choice (spec 18, step
  # 33; CL-3, FH-7).
  #
  # The two editors are rendered directly because the drawers that own their
  # events and their save arrive in steps 34 and 35; this step's claim is the row
  # layout, the R8 validation feedback and the choice-card note. Every expected
  # sentence is literal and hand-derived from spec.md section 4.2 (R8), the GTFS
  # frequencies reference and the prototype's states `add-frequency`,
  # `windows-error` and `freq-edit`; none is computed by the code under test.
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Gtfs.ScheduleChangeComponents

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp first_attr(document, selector, attribute),
    do: document |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute) |> List.first()

  defp row(from, until, every), do: %{from: from, until: until, every: every}

  defp render_windows(windows, stop_name \\ nil) do
    assigns = %{windows: windows, stop_name: stop_name}

    rendered_to_string(~H"""
    <ScheduleChangeComponents.windows_editor windows={@windows} stop_name={@stop_name} />
    """)
  end

  defp render_move_review(refusal) do
    assigns = %{
      change: %{
        kind: :move,
        ids: [],
        params: %{service_id: "SAT"},
        review: nil,
        refusal: refusal,
        notice: nil,
        stale?: false
      },
      drawer: %{
        from: "Weekday",
        to: "Saturday",
        target_options: [{"Saturday", "SAT"}],
        rows: [],
        return_focus_id: "bulk-move"
      }
    }

    rendered_to_string(~H"""
    <ScheduleChangeComponents.change_review_drawer
      change={@change}
      drawer={@drawer}
      version_name="Draft"
    />
    """)
  end

  defp render_riders(windows, exact_times) do
    assigns = %{windows: windows, exact_times: exact_times}

    rendered_to_string(~H"""
    <ScheduleChangeComponents.riders_see windows={@windows} exact_times={@exact_times} />
    """)
  end

  describe "windows_editor/1" do
    test "renders each window's fields, its departures sentence and its controls (R8 example)" do
      document =
        doc(
          render_windows(
            [row("10:00", "14:00", "15"), row("14:00", "15:30", "10")],
            "Riverside Station"
          )
        )

      assert text(document, "#frequency-windows legend") =~ "Windows"
      assert text(document, "#frequency-windows legend") =~ "departures from Riverside Station"
      assert text(document, "#frequency-windows") =~ "Windows can touch but not overlap."

      assert first_attr(document, "#windows-0-from", "name") == "drawer[windows][0][from]"
      assert first_attr(document, "#windows-0-from", "value") == "10:00"
      assert first_attr(document, "#windows-0-until", "name") == "drawer[windows][0][until]"
      assert first_attr(document, "#windows-0-until", "value") == "14:00"
      assert first_attr(document, "#windows-0-every", "name") == "drawer[windows][0][every]"
      assert first_attr(document, "#windows-0-every", "value") == "15"
      assert first_attr(document, "#windows-1-from", "value") == "14:00"
      assert first_attr(document, "#windows-1-every", "value") == "10"

      assert text(document, "#windows-row-0") =~
               "16 departures · last 13:45; the next would be 14:00, when this window ends."

      assert text(document, "#windows-row-1") =~
               "9 departures · last 15:20; the next would be 15:30, when this window ends."

      assert first_attr(document, "#windows-0-from", "class") =~ "h-11"
      assert first_attr(document, "#windows-0-from", "class") =~ "focus-visible:outline-2"
      assert first_attr(document, "#windows-remove-0", "class") =~ "size-11"
      assert first_attr(document, "#win-add", "class") =~ "min-h-11"
      assert first_attr(document, "#win-add", "phx-click") == "drawer_add_window"
      assert first_attr(document, "#windows-remove-1", "phx-click") == "drawer_remove_window"
      assert first_attr(document, "#windows-remove-1", "phx-value-index") == "1"
    end

    test "the spec's 06:00–07:00 every 10 min window ends at 06:50, not 07:00" do
      document = doc(render_windows([row("06:00", "07:00", "10")]))

      assert text(document, "#windows-row-0") =~
               "6 departures · last 06:50; the next would be 07:00, when this window ends."
    end

    test "an overlapping window shows the overlap error on the later row and no summary (FH-7)" do
      document =
        doc(
          render_windows([
            row("07:00", "10:00", "10"),
            row("09:30", "12:00", "30"),
            row("13:00", "12:30", "15")
          ])
        )

      assert text(document, "#windows-row-1") =~
               "Overlaps 07:00–10:00. Windows can touch but not overlap."

      refute text(document, "#windows-row-1") =~ "departures"

      assert text(document, "#windows-row-0") =~
               "18 departures · last 09:50; the next would be 10:00, when this window ends."

      assert text(document, "#windows-row-2") =~ "Until must be later than From."
      refute text(document, "#windows-row-2") =~ "departures"

      assert first_attr(document, "#windows-0-from", "aria-invalid") == "false"
      assert first_attr(document, "#windows-1-from", "aria-invalid") == "true"
      assert first_attr(document, "#windows-2-until", "aria-invalid") == "true"
    end

    test "a window nested after a long one names the long window it overlaps" do
      document =
        doc(
          render_windows([
            row("06:00", "10:00", "10"),
            row("07:00", "08:00", "10"),
            row("09:00", "09:30", "10")
          ])
        )

      assert text(document, "#windows-row-2") =~
               "Overlaps 06:00–10:00. Windows can touch but not overlap."
    end

    test "an overlap message never names a reversed window" do
      document =
        doc(
          render_windows([
            row("06:00", "07:00", "10"),
            row("06:30", "06:10", "10"),
            row("06:45", "08:00", "10")
          ])
        )

      assert text(document, "#windows-row-2") =~
               "Overlaps 06:00–07:00. Windows can touch but not overlap."
    end

    test "windows that touch are valid and the last remaining window cannot be removed" do
      document = doc(render_windows([row("06:00", "07:00", "10"), row("07:00", "08:00", "10")]))

      assert text(document, "#windows-row-1") =~
               "6 departures · last 07:50; the next would be 08:00, when this window ends."

      refute text(document, "#frequency-windows") =~ "Overlaps"

      assert Enum.empty?(LazyHTML.query(document, "#windows-remove-0[disabled]"))
      assert Enum.empty?(LazyHTML.query(document, "#windows-remove-1[disabled]"))

      assert Enum.count(
               LazyHTML.query(
                 doc(render_windows([row("06:00", "07:00", "10")])),
                 "#windows-remove-0[disabled]"
               )
             ) == 1
    end

    test "an unreadable time and a gap that is not whole minutes keep the typed text and explain" do
      document = doc(render_windows([row("7:75", "10:00", "7.5")]))

      assert first_attr(document, "#windows-0-from", "value") == "7:75"
      assert first_attr(document, "#windows-0-every", "value") == "7.5"

      assert text(document, "#windows-row-0") =~ "Enter a time such as 6:05, 605, 6:05p or 25:10."

      assert text(document, "#windows-row-0") =~
               "Enter a whole number of minutes greater than zero."

      refute text(document, "#windows-row-0") =~ "departures"
    end

    test "a window shorter than its gap warns after its summary" do
      document = doc(render_windows([row("07:00", "07:20", "30")]))

      assert text(document, "#windows-row-0") =~
               "1 departure · last 07:00; the next would be 07:30."

      assert text(document, "#windows-row-0") =~
               "The gap between departures is longer than this window. Raise Until or lower Every."
    end
  end

  describe "riders_see/1" do
    test "defaults to each departure time and offers every N minutes" do
      document = doc(render_riders([row("10:00", "14:00", "15")], "1"))

      assert text(document, "#riders-see legend") == "What riders see"
      assert first_attr(document, "#riders-each-departure", "name") == "drawer[exact_times]"
      assert first_attr(document, "#riders-each-departure", "value") == "1"
      assert first_attr(document, "#riders-every-n-minutes", "name") == "drawer[exact_times]"
      assert first_attr(document, "#riders-every-n-minutes", "value") == "0"
      assert Enum.count(LazyHTML.query(document, "#riders-each-departure[checked]")) == 1
      assert Enum.empty?(LazyHTML.query(document, "#riders-every-n-minutes[checked]"))
      refute text(document, "#riders-see") =~ "Above 10 minutes"
    end

    test "a blank stored choice still shows the default and no note (AC-18)" do
      document = doc(render_riders([row("10:00", "14:00", "15")], nil))

      assert Enum.count(LazyHTML.query(document, "#riders-each-departure[checked]")) == 1
      refute text(document, "#riders-see") =~ "Above 10 minutes"
      refute text(document, "#riders-see") =~ "Gaps over 20 minutes"
    end

    test "notes above 10 minutes and warns above 20 while every N minutes is chosen" do
      note = doc(render_riders([row("10:00", "14:00", "15")], "0"))

      assert Enum.count(LazyHTML.query(note, "#riders-every-n-minutes[checked]")) == 1
      assert Enum.empty?(LazyHTML.query(note, "#riders-each-departure[checked]"))

      assert text(note, "#riders-see") =~
               "Above 10 minutes, many riders check a schedule before leaving. Each departure time gives them one."

      refute text(note, "#riders-see") =~ "Gaps over 20 minutes"

      warning = doc(render_riders([row("07:00", "10:00", "30")], "0"))

      assert text(warning, "#riders-see") =~
               "Gaps over 20 minutes: riders plan around a wait of up to the full gap, and trip planners show no departure times. Choose Each departure time."
    end

    test "reads the longest gap among the typed windows" do
      document =
        doc(render_riders([row("10:00", "14:00", "15"), row("14:00", "15:30", "30")], "0"))

      assert text(document, "#riders-see") =~ "Gaps over 20 minutes"
    end
  end

  describe "change_review_drawer/1" do
    test "a selection over 500 trips names the limit, says nothing moves and disables Move" do
      document = doc(render_move_review([{:error, :too_many_trips}]))

      assert text(document, "#review-refusal") =~ "Select 500 or fewer trips at a time."
      assert text(document, "#review-status") == "Nothing can be moved until that is fixed."
      assert first_attr(document, "#review-apply", "disabled") != nil
    end
  end
end

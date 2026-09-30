defmodule GtfsPlannerWeb.Gtfs.ScheduleComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Gtfs.ScheduleComponents

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  describe "unlinked_trips/1" do
    test "names one trip in the singular" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.unlinked_trips count={1} patterns_path="/patterns" />
        """)

      assert text(doc(html), "#schedules-unlinked") =~ "1 trip isn't linked to a pattern"
    end

    test "counts several trips and links to the patterns" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.unlinked_trips count={3} patterns_path="/patterns" />
        """)

      document = doc(html)

      assert text(document, "#schedules-unlinked") =~ "3 trips aren't linked to a pattern"

      assert LazyHTML.attribute(LazyHTML.query(document, "#schedules-unlinked a"), "href") ==
               ["/patterns"]
    end
  end

  describe "unavailable_notice/1" do
    test "says nothing loaded when no timetables are on screen" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.unavailable_notice stale?={false} />
        """)

      document = doc(html)

      assert text(document, "#schedules-unavailable") =~ "Schedules couldn't be loaded"
      assert text(document, "#schedules-retry") == "Retry loading"
    end

    test "says the timetables underneath may be out of date after a failed refresh" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.unavailable_notice stale?={true} />
        """)

      assert text(doc(html), "#schedules-unavailable") =~ "may be out of date"
    end
  end

  describe "trip_headsign_line/1" do
    test "renders a likely typo under the timing in warning ink" do
      assigns = %{id: "trip-T4-headsign", headsign: {:differs, "Lincoln city", :case_or_spacing}}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_line id={@id} headsign={@headsign} />
        """)

      document = doc(html)

      assert text(document, "#trip-T4-headsign") == "To Lincoln city"

      classes =
        LazyHTML.attribute(LazyHTML.query(document, "#trip-T4-headsign"), "class") |> List.first()

      assert classes =~ "text-warning-fg"
      refute classes =~ "text-muted"
    end

    test "renders another difference muted" do
      assigns = %{
        id: "trip-T5-headsign",
        headsign: {:differs, "Roads End via Lincoln City", :other}
      }

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_line id={@id} headsign={@headsign} />
        """)

      document = doc(html)

      assert text(document, "#trip-T5-headsign") == "To Roads End via Lincoln City"

      classes =
        LazyHTML.attribute(LazyHTML.query(document, "#trip-T5-headsign"), "class") |> List.first()

      assert classes =~ "text-muted"
      refute classes =~ "text-warning-fg"
    end

    test "renders a trip that continues in another block's route muted too" do
      assigns = %{id: "trip-T5-headsign", headsign: {:differs, "Roads End", :interline}}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_line id={@id} headsign={@headsign} />
        """)

      classes =
        LazyHTML.attribute(LazyHTML.query(doc(html), "#trip-T5-headsign"), "class")
        |> List.first()

      assert classes =~ "text-muted"
      refute classes =~ "text-warning-fg"
    end

    test "renders No headsign for a blank trip on a non-blank default" do
      assigns = %{id: "trip-T6-headsign", headsign: :blank_with_default}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_line id={@id} headsign={@headsign} />
        """)

      document = doc(html)

      assert text(document, "#trip-T6-headsign") == "No headsign"

      classes =
        LazyHTML.attribute(LazyHTML.query(document, "#trip-T6-headsign"), "class") |> List.first()

      assert classes =~ "text-muted"
    end

    test "renders nothing when the trip follows its default" do
      assigns = %{id: "trip-T1-headsign", headsign: nil}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_line id={@id} headsign={@headsign} />
        """)

      assert Enum.empty?(LazyHTML.query(doc(html), "#trip-T1-headsign"))
    end
  end

  describe "trip_headsign_note/1" do
    test "names the pattern's headsign as what a blank value stores" do
      assigns = %{value: "  ", pattern_headsign: "Lincoln City"}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_note
          value={@value}
          pattern_headsign={@pattern_headsign}
        />
        """)

      document = doc(html)

      assert text(document, "#trip-headsign-note") ==
               "Blank uses the pattern’s headsign, Lincoln City."

      classes =
        LazyHTML.attribute(LazyHTML.query(document, "#trip-headsign-note"), "class")
        |> List.first()

      assert classes =~ "text-muted"
      assert Enum.empty?(LazyHTML.query(document, "#trip-headsign-note-use-default"))
    end

    test "names the timing's own headsign as the source of a blank value" do
      assigns = %{
        value: "",
        timing: %{name: "Weekday base", headsign: "Lincoln City via Taft High"}
      }

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_note value={@value} timing={@timing} />
        """)

      assert text(doc(html), "#trip-headsign-note") ==
               "Blank uses the Weekday base timing’s headsign, Lincoln City via Taft High."
    end

    test "falls back to the pattern's headsign when the timing's own is blank" do
      assigns = %{
        value: "",
        timing: %{name: "Weekday base", headsign: " "},
        pattern_headsign: "Lincoln City"
      }

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_note
          value={@value}
          timing={@timing}
          pattern_headsign={@pattern_headsign}
        />
        """)

      assert text(doc(html), "#trip-headsign-note") ==
               "Blank uses the pattern’s headsign, Lincoln City."
    end

    test "confirms a value that follows the default" do
      assigns = %{value: "Lincoln City", pattern_headsign: "Lincoln City"}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_note
          value={@value}
          pattern_headsign={@pattern_headsign}
        />
        """)

      document = doc(html)

      assert text(document, "#trip-headsign-note") ==
               "Same as the pattern’s headsign. Changing that headsign can update this trip."

      classes =
        LazyHTML.attribute(LazyHTML.query(document, "#trip-headsign-note"), "class")
        |> List.first()

      assert classes =~ "text-success-fg"
      assert Enum.empty?(LazyHTML.query(document, "#trip-headsign-note-use-default"))
    end

    test "warns on a likely typo and offers the default" do
      assigns = %{value: "Lincoln city", pattern_headsign: "Lincoln City"}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_note
          value={@value}
          pattern_headsign={@pattern_headsign}
        />
        """)

      document = doc(html)
      note_text = text(document, "#trip-headsign-note") |> String.replace(~r/\s+/u, " ")

      assert note_text =~
               "Differs from the pattern’s headsign, Lincoln City, only in capital"

      assert note_text =~ "Riders may see both spellings."

      classes =
        LazyHTML.attribute(LazyHTML.query(document, "#trip-headsign-note"), "class")
        |> List.first()

      assert classes =~ "bg-warning-bg"
      assert classes =~ "text-warning-fg"

      button = LazyHTML.query(document, "#trip-headsign-note-use-default")

      assert LazyHTML.attribute(button, "phx-click") == ["trip_use_default_headsign"]
      assert button |> LazyHTML.text() |> String.trim() == "Use Lincoln City"
    end

    test "explains that any other difference keeps its headsign" do
      assigns = %{value: "Roads End via Lincoln City", pattern_headsign: "Lincoln City"}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_note
          value={@value}
          pattern_headsign={@pattern_headsign}
        />
        """)

      document = doc(html)
      note_text = text(document, "#trip-headsign-note") |> String.replace(~r/\s+/u, " ")

      assert note_text =~
               "This trip shows Roads End via Lincoln City instead of the pattern’s headsign,"

      assert note_text =~ "When that headsign changes later, this trip keeps"
      assert note_text =~ "Roads End via Lincoln City."

      classes =
        LazyHTML.attribute(LazyHTML.query(document, "#trip-headsign-note"), "class")
        |> List.first()

      assert classes =~ "bg-info-bg"

      assert LazyHTML.attribute(
               LazyHTML.query(document, "#trip-headsign-note-use-default"),
               "phx-click"
             ) == ["trip_use_default_headsign"]
    end

    test "hides the Use button when neither the timing nor the pattern carries a headsign" do
      assigns = %{value: "Downtown", pattern_headsign: nil}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.trip_headsign_note
          value={@value}
          pattern_headsign={@pattern_headsign}
        />
        """)

      document = doc(html)
      note_text = text(document, "#trip-headsign-note") |> String.replace(~r/\s+/u, " ")

      assert note_text =~ "This trip shows Downtown instead of the pattern’s headsign,"
      assert note_text =~ "No headsign"
      assert Enum.empty?(LazyHTML.query(document, "#trip-headsign-note-use-default"))
    end
  end
end

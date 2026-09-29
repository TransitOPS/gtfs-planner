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

  describe "bulk_toolbar/1" do
    test "renders nothing without a selection" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.bulk_toolbar selected_count={0} />
        """)

      assert Enum.empty?(doc(html) |> LazyHTML.query("#schedules-bulk-toolbar"))
    end

    test "counts the selection and offers to clear or delete it" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <ScheduleComponents.bulk_toolbar selected_count={2} />
        """)

      document = doc(html)

      assert text(document, "#schedules-bulk-toolbar") =~ "2 trips selected"
      assert text(document, "#schedules-delete-selected") == "Delete 2 trips"
      assert Enum.count(LazyHTML.query(document, "#schedules-clear-selection")) == 1
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
end

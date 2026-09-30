defmodule GtfsPlannerWeb.Gtfs.RoutePatternHeadsignComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Gtfs.RoutePatternHeadsignComponents, as: Headsign

  # The literal fixture counts follow the browser-seed pattern BROWSER-HS1:
  # five trips, two differing (one case slip, one interline continuation).
  defp trip(id), do: %{id: id}

  defp usage(overrides \\ []) do
    Map.merge(
      %{
        scope: :pattern,
        default: "Lincoln City",
        total: 5,
        same: 3,
        differ: 2,
        shielded: [],
        timings_carry: [],
        groups: [
          %{
            value: "Lincoln city",
            kind: :case_or_spacing,
            likely_typo: true,
            trips: [trip("BROWSER_HS1_T4")]
          },
          %{
            value: "Roads End via Lincoln City",
            kind: :interline,
            likely_typo: false,
            trips: [trip("BROWSER_HS1_T5")]
          }
        ]
      },
      Map.new(overrides)
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(html, selector) do
    doc(html)
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # The counts line is the container's second span, after the icon; the chip
  # and the review button are siblings, not part of the sentence.
  defp line_text(html), do: text(html, "#headsign-usage > span:nth-of-type(2)")

  # The carry note's sentence paragraph; the lift button is a sibling.
  defp carry_text(html), do: text(html, "#headsign-usage > p")

  # The stay-as-they-are lines; the review button is the lines div's other
  # child and carries the same text-size class.
  defp lines_text(html), do: text(html, "#headsign-update-box > div > span")

  defp present?(html, selector), do: not Enum.empty?(LazyHTML.query(doc(html), selector))

  defp attribute(html, selector, name) do
    doc(html)
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp classes(html, selector) do
    html
    |> attribute(selector, "class")
    |> String.split()
  end

  describe "usage_line/1" do
    test "renders the counts, the typo chip and the exceptions review button" do
      html = render_component(&Headsign.usage_line/1, usage: usage())

      assert line_text(html) == "Used by 5 trips · 2 show a different headsign"

      assert text(html, "#headsign-usage [class*=warning-bg]") == "1 likely typo"
      assert text(html, "#headsign-usage-review") == "Review 2 trips"

      assert attribute(html, "#headsign-usage-review", "phx-click") == "open_headsign_review"
      assert attribute(html, "#headsign-usage-review", "phx-value-mode") == "exceptions"
      assert attribute(html, "#headsign-usage-review", "phx-value-scope") == "pattern"
    end

    test "renders the singular counts for one trip and one differing trip" do
      html =
        render_component(&Headsign.usage_line/1,
          usage:
            usage(
              total: 1,
              same: 0,
              differ: 1,
              groups: [
                %{
                  value: "Lincoln city",
                  kind: :case_or_spacing,
                  likely_typo: true,
                  trips: [trip("t4")]
                }
              ]
            )
        )

      assert line_text(html) == "Used by 1 trip · 1 shows a different headsign"
      assert text(html, "#headsign-usage-review") == "Review 1 trip"
    end

    test "renders all matching and no review button when every trip follows" do
      html =
        render_component(&Headsign.usage_line/1,
          usage: usage(total: 3, same: 3, differ: 0, groups: [])
        )

      assert line_text(html) == "Used by 3 trips · all show this headsign"
      refute present?(html, "#headsign-usage-review")
      refute present?(html, "[class*=warning-bg]")
    end

    test "reads all show no headsign when the default is nil" do
      html =
        render_component(&Headsign.usage_line/1,
          usage: usage(default: nil, total: 3, same: 3, differ: 0, groups: [])
        )

      assert line_text(html) == "Used by 3 trips · all show no headsign"
    end

    test "renders the no-trips line for the pattern and the timing scope" do
      html =
        render_component(&Headsign.usage_line/1,
          usage: usage(total: 0, same: 0, differ: 0, groups: [])
        )

      assert text(html, "#headsign-usage") ==
               "No trips use this pattern yet. Trips you add get this headsign."

      html =
        render_component(&Headsign.usage_line/1,
          usage: usage(total: 0, same: 0, differ: 0, groups: []),
          scope_label: "timing"
        )

      assert text(html, "#headsign-usage") ==
               "No trips use this timing yet. Trips you add get this headsign."
    end

    test "adds the shielded-timings clause" do
      html =
        render_component(&Headsign.usage_line/1,
          usage:
            usage(
              shielded: [
                %{
                  timing_id: "tp1",
                  name: "School days",
                  headsign: "Lincoln City via Taft High",
                  trip_count: 6
                }
              ]
            )
        )

      assert line_text(html) ==
               "Used by 5 trips · 2 show a different headsign · 1 timing sets its own"

      html =
        render_component(&Headsign.usage_line/1,
          usage:
            usage(
              shielded: [
                %{
                  timing_id: "tp1",
                  name: "School days",
                  headsign: "Lincoln City via Taft High",
                  trip_count: 6
                },
                %{
                  timing_id: "tp2",
                  name: "Weekend base",
                  headsign: "Lincoln City Transit Center",
                  trip_count: 2
                }
              ]
            )
        )

      assert line_text(html) =~ "2 timings set their own"
    end

    test "renders the timings-carry note and the lift button for one distinct value" do
      html =
        render_component(&Headsign.usage_line/1,
          usage:
            usage(
              default: nil,
              total: 0,
              timings_carry: [
                %{
                  timing_id: "tp1",
                  name: "Weekday base",
                  headsign: "Lincoln City",
                  trip_count: 3
                },
                %{timing_id: "tp2", name: "Weekend base", headsign: "Lincoln City", trip_count: 2}
              ]
            )
        )

      assert carry_text(html) ==
               "Timings set the headsign here: Weekday base shows Lincoln City, " <>
                 "Weekend base shows Lincoln City (5 trips)."

      assert text(html, "#headsign-usage-lift") == "Use Lincoln City for this pattern"
      assert attribute(html, "#headsign-usage-lift", "phx-click") == "use_timings_headsign"
      assert attribute(html, "#headsign-usage-lift", "phx-value-value") == "Lincoln City"
      refute present?(html, "#headsign-usage-review")
    end

    test "omits the lift button when the carrying timings disagree" do
      html =
        render_component(&Headsign.usage_line/1,
          usage:
            usage(
              default: nil,
              timings_carry: [
                %{
                  timing_id: "tp1",
                  name: "Weekday base",
                  headsign: "Lincoln City",
                  trip_count: 3
                },
                %{
                  timing_id: "tp2",
                  name: "School days",
                  headsign: "Lincoln City via Taft High",
                  trip_count: 2
                }
              ]
            )
        )

      assert carry_text(html) =~ "Timings set the headsign here"
      refute present?(html, "#headsign-usage-lift")
    end

    test "adds the no-timing clause when trips remain outside the carrying timings" do
      html =
        render_component(&Headsign.usage_line/1,
          usage:
            usage(
              default: nil,
              total: 4,
              timings_carry: [
                %{timing_id: "tp1", name: "Weekday base", headsign: "Lincoln City", trip_count: 1}
              ]
            )
        )

      assert carry_text(html) =~ "(1 trip)."
      assert carry_text(html) =~ "4 trips on no timing follow this field"
    end

    test "names the timing scope on the review button" do
      html =
        render_component(&Headsign.usage_line/1, usage: usage(scope: {:timing, "tp9"}))

      assert attribute(html, "#headsign-usage-review", "phx-value-scope") == "tp9"
    end
  end

  describe "update_box/1" do
    test "renders the checked update label and the stay-as-they-are line" do
      html =
        render_component(&Headsign.update_box/1,
          from: "Lincoln City",
          to: "Lincoln City via Depoe Bay",
          followers: 3,
          selected_follow: 3,
          extra: 0,
          others: 2,
          update?: true
        )

      assert text(html, "#headsign-update-box label") ==
               "Also update 3 trips that show Lincoln City"

      assert attribute(html, "#headsign-update-toggle", "checked") != nil
      assert attribute(html, "#headsign-update-toggle", "phx-click") == "toggle_headsign_update"
      assert classes(html, "#headsign-update-box") |> Enum.member?("border-action")
      assert classes(html, "#headsign-update-box") |> Enum.member?("bg-selection/50")

      assert lines_text(html) =~ "2 trips with a different headsign stay as they are."

      assert text(html, "#headsign-update-review") == "Review trips"
      assert attribute(html, "#headsign-update-review", "phx-click") == "open_headsign_review"
      assert attribute(html, "#headsign-update-review", "phx-value-mode") == "change"
    end

    test "renders the give-no-headsign label when the old default is nil" do
      html =
        render_component(&Headsign.update_box/1,
          from: nil,
          to: "Lincoln City",
          followers: 3,
          selected_follow: 3,
          extra: 0,
          others: 2,
          update?: true
        )

      assert text(html, "#headsign-update-box label") ==
               "Also give 3 trips with no headsign this headsign"
    end

    test "renders unchecked with the clearing label and the new-trips-only copy" do
      html =
        render_component(&Headsign.update_box/1,
          from: "Lincoln City",
          to: nil,
          followers: 3,
          selected_follow: 3,
          extra: 0,
          others: 0,
          update?: false
        )

      assert text(html, "#headsign-update-box label") ==
               "Also clear the headsign on 3 trips that show Lincoln City"

      assert attribute(html, "#headsign-update-toggle", "checked") == nil
      assert classes(html, "#headsign-update-box") |> Enum.member?("border-control")

      assert lines_text(html) ==
               "Only trips you add get No headsign. 3 trips keep Lincoln City and will count as different."
    end

    test "renders the clearing copy when a cleared value is checked again" do
      html =
        render_component(&Headsign.update_box/1,
          from: "Lincoln City",
          to: nil,
          followers: 3,
          selected_follow: 3,
          extra: 0,
          others: 0,
          update?: true
        )

      assert attribute(html, "#headsign-update-toggle", "checked") != nil
      assert classes(html, "#headsign-update-box") |> Enum.member?("border-action")

      assert lines_text(html) ==
               "Trip planner apps then show those trips with the last stop’s name."
    end

    test "renders the partial selection and the review additions" do
      html =
        render_component(&Headsign.update_box/1,
          from: "Lincoln City",
          to: "Lincoln City via Depoe Bay",
          followers: 3,
          selected_follow: 2,
          extra: 1,
          others: 0,
          update?: true
        )

      assert text(html, "#headsign-update-box label") ==
               "Also update 2 of 3 trips that show Lincoln City"

      assert lines_text(html) =~ "Plus 1 trip you added in the review."
    end

    test "renders one line per shielded timing" do
      html =
        render_component(&Headsign.update_box/1,
          from: "Lincoln City",
          to: "Lincoln City via Depoe Bay",
          followers: 3,
          selected_follow: 3,
          extra: 0,
          others: 2,
          shielded: [
            %{name: "School days", headsign: "Lincoln City via Taft High", trip_count: 6},
            %{name: "Weekend base", headsign: "Lincoln City Transit Center", trip_count: 1}
          ],
          update?: true
        )

      assert lines_text(html) =~
               "School days sets its own headsign, Lincoln City via Taft High; its 6 trips are not changed."

      assert lines_text(html) =~
               "Weekend base sets its own headsign, Lincoln City Transit Center; its 1 trip is not changed."
    end

    test "renders the no-trips copy without a checkbox" do
      html =
        render_component(&Headsign.update_box/1,
          from: "Lincoln City",
          to: "Lincoln City via Depoe Bay",
          followers: 0,
          selected_follow: 0,
          extra: 0,
          others: 0,
          update?: true
        )

      assert text(html, "#headsign-update-box") =~ "No trips show Lincoln City now."
      refute present?(html, "#headsign-update-toggle")
    end

    test "renders the singular stay-as-it-is line" do
      html =
        render_component(&Headsign.update_box/1,
          from: "Lincoln City",
          to: "Lincoln City via Depoe Bay",
          followers: 3,
          selected_follow: 3,
          extra: 0,
          others: 1,
          update?: true
        )

      assert lines_text(html) =~ "1 trip with a different headsign stays as it is."
    end
  end

  describe "wording_warnings/1" do
    test "renders the leading-To warning" do
      html =
        render_component(&Headsign.wording_warnings/1,
          warnings: [:leading_to],
          value: "To Lincoln City"
        )

      assert text(html, "#headsign-warnings") ==
               "Leave out “To”. Trip planner apps add their own “to” or arrow."
    end

    test "renders the all-caps warning with the mixed-case suggestion" do
      html =
        render_component(&Headsign.wording_warnings/1,
          warnings: [:all_caps],
          value: "TO LINCOLN CITY"
        )

      assert text(html, "#headsign-warnings") ==
               "Use mixed case, as vehicle signs and apps do: “Lincoln City”, not “TO LINCOLN CITY”."
    end

    test "renders the route-name warning with the short name" do
      html =
        render_component(&Headsign.wording_warnings/1,
          warnings: [:route_name],
          value: "Route 101 to Lincoln City",
          route: "101"
        )

      assert text(html, "#headsign-warnings") ==
               "Leave out the route name. Apps already show Route 101 beside the headsign."
    end

    test "renders the sibling-case warning with the sibling pattern" do
      html =
        render_component(&Headsign.wording_warnings/1,
          warnings: [:sibling_case],
          value: "LINCOLN CITY",
          sibling: %{name: "Lincoln City express", headsign: "Lincoln City"}
        )

      assert text(html, "#headsign-warnings") ==
               "Lincoln City express uses “Lincoln City”. Match its capitals so riders see one destination."
    end

    test "renders nothing for a sibling-case warning with no named sibling" do
      html =
        render_component(&Headsign.wording_warnings/1,
          warnings: [:sibling_case],
          value: "Lincoln City",
          sibling: nil
        )

      refute present?(html, "#headsign-warnings")
    end

    test "renders the length warning with the character count" do
      value = "Lincoln City Transit Center Depot"

      html =
        render_component(&Headsign.wording_warnings/1, warnings: [:long], value: value)

      assert text(html, "#headsign-warnings") ==
               "33 characters. Vehicle signs and phone screens may cut off headsigns longer than about 30."
    end

    test "renders one warning note per lint atom and nothing without warnings" do
      html =
        render_component(&Headsign.wording_warnings/1,
          warnings: [:leading_to, :all_caps],
          value: "TO LINCOLN CITY"
        )

      assert Enum.count(LazyHTML.query(doc(html), "#headsign-warnings p")) == 2

      html = render_component(&Headsign.wording_warnings/1, warnings: [], value: "Northbound")

      refute present?(html, "#headsign-warnings")
    end
  end
end

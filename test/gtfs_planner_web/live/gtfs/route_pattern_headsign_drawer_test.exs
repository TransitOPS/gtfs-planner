defmodule GtfsPlannerWeb.Gtfs.RoutePatternHeadsignDrawerTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Gtfs.RoutePatternHeadsignComponents, as: Headsign

  # The literal fixture shapes follow the read model `headsign_usage/3`
  # returns and the browser-seed pattern BROWSER-HS1 values, extended to the
  # prototype's review picture: a likely typo, an interline pair and a blank.
  defp trip(id, overrides \\ []) do
    Map.merge(
      %{
        id: id,
        trip_id: String.replace(id, "t", "BROWSER_HS1_T"),
        headsign: nil,
        service_id: "BROWSER_PATTERN_SERVICE",
        departure_secs: 8 * 3600,
        timing_name: "Weekday base",
        custom?: false,
        next_block: nil,
        mid_trip_change: nil
      },
      Map.new(overrides)
    )
  end

  defp usage(overrides \\ []) do
    Map.merge(
      %{
        scope: :pattern,
        default: "Lincoln City",
        total: 5,
        same: 1,
        differ: 4,
        shielded: [],
        timings_carry: [],
        groups: [
          %{
            value: "Lincoln city",
            kind: :case_or_spacing,
            likely_typo: true,
            trips: [trip("t4", departure_secs: 9 * 3600 + 20 * 60)]
          },
          %{
            value: "Roads End via Lincoln City",
            kind: :interline,
            likely_typo: false,
            trips: [
              trip("t5a",
                departure_secs: 17 * 3600 + 10 * 60,
                next_block: %{
                  route_short_name: "20",
                  departure_secs: 18 * 3600 + 22 * 60,
                  headsign: "Roads End"
                }
              ),
              trip("t5b", departure_secs: 19 * 3600 + 50 * 60)
            ]
          },
          %{
            value: nil,
            kind: :blank,
            likely_typo: false,
            trips: [
              trip("t6",
                departure_secs: 18 * 3600 + 30 * 60,
                mid_trip_change: "Gleneden Beach"
              )
            ]
          }
        ]
      },
      Map.new(overrides)
    )
  end

  defp drawer(overrides \\ []) do
    overrides =
      Keyword.merge([mode: :exceptions, usage: usage(), selected: MapSet.new(["t4"])], overrides)

    render_component(&Headsign.review_drawer/1, overrides)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(html, selector) do
    doc(html)
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp present?(html, selector), do: not Enum.empty?(LazyHTML.query(doc(html), selector))

  defp attribute(html, selector, name) do
    doc(html)
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end

  defp all_attributes(html, selector, name) do
    doc(html)
    |> LazyHTML.query(selector)
    |> Enum.map(&(LazyHTML.attribute(&1, name) |> List.first()))
  end

  defp group_titles(html) do
    doc(html)
    |> LazyHTML.query("#headsign-review-drawer section[aria-labelledby] h3")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp row_count(html),
    do: Enum.count(LazyHTML.query(doc(html), "#headsign-review-drawer tbody tr"))

  defp footer_secondary(html) do
    text(html, "#headsign-review-drawer footer button.btn-outline")
  end

  describe "exceptions mode" do
    test "renders the differing groups in read-model order with counts and the typo tag" do
      html = drawer()

      assert group_titles(html) == [
               "Lincoln city · 1 trip Likely typo",
               "Roads End via Lincoln City · 2 trips",
               "No headsign · 1 trip"
             ]
    end

    test "explains each group from its difference kind and marks only the likely typo" do
      html = drawer()
      drawer_text = text(html, "#headsign-review-drawer")

      assert drawer_text =~
               "Differs from Lincoln City only in capital letters or spacing. Riders see two spellings of one destination."

      assert drawer_text =~
               "The bus continues as Route 20 toward Roads End, so the sign shows where riders can stay on to."

      assert drawer_text =~
               "Trip planner apps show these trips with the last stop’s name instead."

      refute drawer_text =~ "Riders see this instead of the default."
      assert Enum.count(String.split(drawer_text, "Likely typo")) == 2
    end

    test "shows the block and mid-trip facts on the rows that carry them" do
      html = drawer()
      drawer_text = text(html, "#headsign-review-drawer")

      assert drawer_text =~ "Next in block: Route 20 at 18:22 toward Roads End"
      assert drawer_text =~ "Headsign changes at Gleneden Beach"
    end

    test "renders the intro, the likely-typo shortcut and the closing note" do
      html = drawer(selected: MapSet.new(["t5a"]))
      drawer_text = text(html, "#headsign-review-drawer")

      assert drawer_text =~ "1 of 5 trips show Lincoln City."
      assert drawer_text =~ "Select trips to change to Lincoln City."
      assert drawer_text =~ "Trips you don’t select keep their headsign."
      assert drawer_text =~ "Only the trip headsign changes."

      assert text(html, "#headsign-review-drawer-select-typos") == "Select 1 likely typo"

      assert attribute(html, "#headsign-review-drawer-select-typos", "phx-click") ==
               "select_headsign_typos"
    end

    test "hides the likely-typo shortcut while every likely typo is selected" do
      html = drawer(selected: MapSet.new(["t4", "t5a"]))

      refute present?(html, "#headsign-review-drawer-select-typos")
    end

    test "disables the primary without a selection and explains why" do
      html = drawer(selected: MapSet.new())

      assert text(html, "#headsign-review-drawer-apply") == "Change trips"
      assert attribute(html, "#headsign-review-drawer-apply", "disabled") == ""
      assert attribute(html, "#headsign-review-drawer-apply", "data-unavailable") == ""

      assert attribute(html, "#headsign-review-drawer-apply", "title") ==
               "Select at least one trip"

      assert text(html, "#headsign-review-drawer-status") ==
               "Select the trips to change. Nothing changes until you apply."
    end

    test "labels the primary with the selection and the default" do
      html = drawer(selected: MapSet.new(["t4", "t5a"]))

      assert text(html, "#headsign-review-drawer-apply") == "Change 2 trips to Lincoln City"
      assert is_nil(attribute(html, "#headsign-review-drawer-apply", "disabled"))
      assert is_nil(attribute(html, "#headsign-review-drawer-apply", "title"))

      assert attribute(html, "#headsign-review-drawer-apply", "phx-click") ==
               "apply_headsign_reset"

      assert text(html, "#headsign-review-drawer-status") ==
               "2 trips selected. Nothing changes until you apply."
    end

    test "points a blank default at no headsign" do
      html = drawer(usage: usage(default: nil), selected: MapSet.new(["t4"]))

      assert text(html, "#headsign-review-drawer-apply") == "Change 1 trip to no headsign"
    end

    test "truncates a large group behind Show all and expands it from open_groups" do
      big_group = %{
        value: "Long way",
        kind: :other,
        likely_typo: false,
        trips: Enum.map(1..7, &trip("long#{&1}", departure_secs: 7 * 3600 + &1 * 600))
      }

      html = drawer(usage: usage(groups: [big_group]), selected: MapSet.new())

      assert row_count(html) == 6
      assert text(html, "#headsign-review-drawer-group-0-more") == "Show all 7 trips"

      assert attribute(html, "#headsign-review-drawer-group-0-more", "phx-click") ==
               "show_headsign_group"

      assert attribute(html, "#headsign-review-drawer-group-0-more", "phx-value-group") == "0"

      html = drawer(usage: usage(groups: [big_group]), selected: MapSet.new(), open_groups: [0])

      assert row_count(html) == 7
      refute present?(html, "#headsign-review-drawer-group-0-more")
    end

    test "carries the trip id and the selection event on every row checkbox" do
      html = drawer()

      assert all_attributes(
               html,
               ~s(#headsign-review-drawer input[type="checkbox"][phx-click="select_headsign_trip"]),
               "phx-value-trip"
             ) == ["t4", "t5a", "t5b", "t6"]

      assert attribute(
               html,
               ~s(#headsign-review-drawer input[type="checkbox"][phx-value-trip="t4"]),
               "checked"
             ) == ""

      assert attribute(
               html,
               ~s(#headsign-review-drawer input[type="checkbox"][phx-value-trip="t5a"]),
               "checked"
             ) == nil
    end

    test "carries the group index and mixed state on the group checkbox" do
      html = drawer(selected: MapSet.new(["t5a"]))

      assert all_attributes(
               html,
               ~s(#headsign-review-drawer input[type="checkbox"][phx-click="select_headsign_group"]),
               "phx-value-group"
             ) == ["1"]

      assert attribute(html, "#headsign-review-drawer-group-1-toggle", "data-indeterminate") ==
               "true"

      assert attribute(html, "#headsign-review-drawer-group-1-toggle", "aria-label") ==
               "Select all 2 trips showing Roads End via Lincoln City"
    end

    test "gives single-trip groups no group checkbox" do
      html = drawer()

      assert all_attributes(
               html,
               ~s(#headsign-review-drawer input[type="checkbox"][phx-click="select_headsign_group"]),
               "phx-value-group"
             ) == ["1"]
    end
  end

  describe "change mode" do
    test "leads with the follows group preselected and hands the selection back" do
      followers = [
        trip("f1", departure_secs: 5 * 3600),
        trip("f2", departure_secs: 5 * 3600 + 1800)
      ]

      html =
        drawer(
          mode: :change,
          selected: MapSet.new(["f1", "f2"]),
          change: %{from: "Lincoln City", to: "Lincoln City via Depoe Bay"},
          usage:
            usage(
              groups: [
                %{value: "Lincoln City", kind: :follows, likely_typo: false, trips: followers},
                Enum.at(usage().groups, 0)
              ]
            )
        )

      assert group_titles(html) |> hd() == "Show Lincoln City · 2 trips"

      assert text(html, "#headsign-review-drawer") =~
               "These trips match the old headsign, so they start selected."

      assert text(html, "#headsign-review-drawer-title") == "Trips the new headsign reaches"

      assert all_attributes(
               html,
               ~s(section[aria-labelledby="headsign-review-drawer-group-0"] input[type="checkbox"][phx-click="select_headsign_trip"]),
               "checked"
             ) == ["", ""]

      assert text(html, "#headsign-review-drawer-status") ==
               "2 trips selected. Nothing changes until you save the headsign."

      assert text(html, "#headsign-review-drawer-use") ==
               "Use this selection"

      assert attribute(html, "#headsign-review-drawer-use", "phx-click") ==
               "use_headsign_selection"

      refute present?(html, "#headsign-review-drawer-apply")
      assert text(html, "#headsign-review-drawer") =~ "Preview · not saved"
    end

    test "reads Have no headsign while clearing and keeps the preview context" do
      html =
        drawer(
          mode: :change,
          selected: MapSet.new(["f1"]),
          change: %{from: nil, to: nil},
          usage:
            usage(
              default: nil,
              groups: [
                %{
                  value: nil,
                  kind: :follows,
                  likely_typo: false,
                  trips: [trip("f1")]
                }
              ]
            )
        )

      assert group_titles(html) |> hd() == "Have no headsign · 1 trip"
      assert text(html, "#headsign-review-drawer") =~ "should keep No headsign."
    end
  end

  describe "drawer states" do
    test ":loading renders the skeleton with Loading trips and no groups" do
      html = drawer(state: :loading, usage: nil, selected: MapSet.new())

      drawer_text = text(html, "#headsign-review-drawer")
      assert drawer_text =~ "Loading trips…"
      refute drawer_text =~ "Default"

      assert present?(html, ~s(#headsign-review-drawer [aria-busy="true"]))
      assert Enum.count(LazyHTML.query(doc(html), "#headsign-review-drawer .animate-pulse")) == 9
      assert row_count(html) == 0
      assert footer_secondary(html) == "Close"
      refute present?(html, "#headsign-review-drawer-apply")
    end

    test ":stale renders the changed-elsewhere callout with Refresh list" do
      html = drawer(state: :stale)

      stale_text = text(html, "#headsign-review-drawer-stale")
      assert stale_text =~ "These trips changed since the list loaded"

      assert stale_text =~
               "Nothing was changed. Refresh the list; your selection is kept where the trips still match."

      assert text(html, "#headsign-review-drawer-apply") == "Refresh list"

      assert attribute(html, "#headsign-review-drawer-apply", "phx-click") ==
               "refresh_headsign_review"

      assert is_nil(attribute(html, "#headsign-review-drawer-apply", "disabled"))
      assert text(html, "#headsign-review-drawer-status") == "Nothing was changed."
    end

    test ":failed renders the failure callout and keeps the apply action" do
      html = drawer(state: :failed, selected: MapSet.new(["t4", "t5a"]))

      failed_text = text(html, "#headsign-review-drawer-failed")
      assert failed_text =~ "No trips were changed"

      assert failed_text =~
               "The update didn’t reach the server. Your selection is kept. Try again."

      assert text(html, "#headsign-review-drawer-apply") == "Change 2 trips to Lincoln City"
    end

    test ":done renders the result with Undo and turns Cancel into Close" do
      html =
        drawer(
          state: :done,
          selected: MapSet.new(),
          done: %{
            title: "1 trip now shows Lincoln City",
            body: "3 trips kept a different headsign. Each change is in History."
          }
        )

      done_text = text(html, "#headsign-review-drawer-done")
      assert done_text =~ "1 trip now shows Lincoln City"
      assert done_text =~ "3 trips kept a different headsign. Each change is in History."

      assert text(html, "#headsign-review-drawer-undo") == "Undo"
      assert attribute(html, "#headsign-review-drawer-undo", "phx-click") == "undo_headsign"
      assert attribute(html, "#headsign-review-drawer-undo", "phx-value-source") == "review"

      assert footer_secondary(html) == "Close"
    end

    test "renders the all-match card for empty groups with only Close" do
      html =
        drawer(usage: usage(total: 5, same: 5, differ: 0, groups: []), selected: MapSet.new())

      drawer_text = text(html, "#headsign-review-drawer")
      assert drawer_text =~ "All 5 trips show Lincoln City"

      assert drawer_text =~
               "Nothing to review. A trip gets a different headsign when someone edits it in Schedules or an import brings one in."

      assert footer_secondary(html) == "Close"
      refute present?(html, "#headsign-review-drawer-apply")
      refute present?(html, "#headsign-review-drawer-select-typos")
      assert row_count(html) == 0
    end

    test "reads no headsign on the empty card for a nil default" do
      html =
        drawer(
          usage: usage(default: nil, groups: []),
          selected: MapSet.new()
        )

      assert text(html, "#headsign-review-drawer") =~ "All 5 trips show No headsign"
    end
  end

  describe "applying" do
    test "freezes the rows, the group toggle and the footer until the write lands" do
      html = drawer(state: :applying, selected: MapSet.new(["t4", "t6"]))

      assert all_attributes(
               html,
               ~s(#headsign-review-drawer input[type="checkbox"][phx-click="select_headsign_trip"]),
               "disabled"
             ) == ["", "", "", ""]

      assert all_attributes(
               html,
               ~s(#headsign-review-drawer input[type="checkbox"][phx-click="select_headsign_group"]),
               "disabled"
             ) == [""]

      assert text(html, "#headsign-review-drawer-apply") == "Changing…"
      assert attribute(html, "#headsign-review-drawer-apply", "disabled") == ""
      assert footer_secondary(html) == "Cancel"

      assert attribute(html, "#headsign-review-drawer footer button.btn-outline", "disabled") ==
               ""

      refute present?(html, "#headsign-review-drawer-select-typos")
      assert text(html, "#headsign-review-drawer-status") == "Changing 2 trips…"
      assert attribute(html, "#headsign-review-drawer-overlay", "data-pending") == "true"
    end
  end

  describe "focus" do
    test "returns focus to the mode's standard opener by default" do
      html = drawer()

      assert attribute(html, "#headsign-review-drawer-overlay", "data-return-focus-id") ==
               "headsign-usage-review"

      html =
        drawer(
          mode: :change,
          selected: MapSet.new(),
          change: %{from: "Lincoln City", to: "Lincoln City via Depoe Bay"},
          usage:
            usage(
              groups: [
                %{
                  value: "Lincoln City",
                  kind: :follows,
                  likely_typo: false,
                  trips: [trip("f1")]
                }
              ]
            )
        )

      assert attribute(html, "#headsign-review-drawer-overlay", "data-return-focus-id") ==
               "headsign-update-review"
    end

    test "passes a caller-supplied opener through to the drawer" do
      html = drawer(return_focus_id: "headsign-usage-timing-1-review")

      assert attribute(html, "#headsign-review-drawer-overlay", "data-return-focus-id") ==
               "headsign-usage-timing-1-review"
    end
  end
end

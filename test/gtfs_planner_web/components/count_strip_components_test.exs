defmodule GtfsPlannerWeb.Components.CountStripComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  import GtfsPlannerWeb.CoreComponents

  # The exact public item shape from the Package 15 architecture contract. Pinned
  # here so a change to the shared component fails this test rather than silently
  # breaking the report, history, and Package 16/17 consumers.
  defp item(overrides \\ %{}) do
    Map.merge(%{key: "name", label: "Name", count: 6, tone: :neutral}, overrides)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp attr_of(doc, selector, attribute) do
    doc |> LazyHTML.query(selector) |> LazyHTML.attribute(attribute)
  end

  defp classes(doc, selector) do
    doc |> LazyHTML.query(selector) |> LazyHTML.attribute("class") |> List.first() || ""
  end

  describe "count_strip/1 display mode" do
    test "renders one non-button entry per item with the caller's label and count" do
      assigns = %{
        items: [
          item(%{key: "stops", label: "Stops", count: 128}),
          item(%{key: "pathways", label: "Pathways", count: 34, tone: :info})
        ]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      document = doc(html)

      assert LazyHTML.query(document, "#report-counts[data-mode='display']") |> Enum.count() == 1
      assert LazyHTML.query(document, "#report-counts button") |> Enum.count() == 0

      assert LazyHTML.query(document, "#report-counts [data-role='count-strip-item']")
             |> Enum.count() == 2

      assert LazyHTML.text(LazyHTML.query(document, "#report-counts-item-stops")) =~ "Stops"
      assert LazyHTML.text(LazyHTML.query(document, "#report-counts-item-stops")) =~ "128"
      assert LazyHTML.text(LazyHTML.query(document, "#report-counts-item-pathways")) =~ "Pathways"
    end

    test "renders counts with tabular numerals so columns of digits align" do
      assigns = %{items: [item(%{key: "stops", label: "Stops", count: 1204})]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      count =
        doc(html) |> LazyHTML.query("#report-counts-item-stops [data-role='count-strip-value']")

      assert LazyHTML.text(count) == "1204"
      assert LazyHTML.attribute(count, "class") |> List.first() =~ "tabular-nums"
    end

    test "carries no click event, pressed state, or filter role in display mode" do
      assigns = %{items: [item()]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      document = doc(html)

      assert attr_of(document, "#report-counts-item-name", "phx-click") == []
      assert attr_of(document, "#report-counts-item-name", "aria-pressed") == []
      assert LazyHTML.query(document, "[data-role='count-strip-filter']") |> Enum.count() == 0
    end

    test "keeps a long label fully readable instead of truncating it" do
      long = "Parent station and pathway signposted name"
      assigns = %{items: [item(%{key: "signposted_as", label: long, count: 1})]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      document = doc(html)

      label =
        LazyHTML.query(
          document,
          "#report-counts-item-signposted_as [data-role='count-strip-label']"
        )

      assert LazyHTML.text(label) == long
      assert LazyHTML.attribute(label, "class") |> List.first() =~ "break-words"
      refute classes(document, "#report-counts-item-signposted_as") =~ "truncate"
    end

    test "renders every supported tone as a semantic token, never a literal color" do
      assigns = %{
        items: [
          item(%{key: "a", tone: :neutral}),
          item(%{key: "b", tone: :info}),
          item(%{key: "c", tone: :success}),
          item(%{key: "d", tone: :warning}),
          item(%{key: "e", tone: :error})
        ]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      document = doc(html)

      for {key, token} <- [
            {"a", "bg-base-content/40"},
            {"b", "bg-info"},
            {"c", "bg-success"},
            {"d", "bg-warning"},
            {"e", "bg-error"}
          ] do
        assert classes(document, "#report-counts-item-#{key} [data-role='count-strip-tone']") =~
                 token
      end

      refute html =~ ~r/#[0-9a-fA-F]{3,8}\b/
    end

    test "renders a disabled reason in display mode instead of dropping it silently" do
      assigns = %{
        items: [
          item(%{
            key: "pathways",
            label: "Pathways",
            count: 0,
            disabled_reason: "None defined for this station"
          })
        ]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      reason =
        doc(html)
        |> LazyHTML.query("#report-counts-item-pathways [data-role='count-strip-reason']")

      assert String.trim(LazyHTML.text(reason)) == "None defined for this station"
    end

    test "renders an empty item list as an empty strip rather than raising" do
      assigns = %{items: []}

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      document = doc(html)

      assert LazyHTML.query(document, "#report-counts") |> Enum.count() == 1

      assert LazyHTML.query(document, "#report-counts [data-role='count-strip-item']")
             |> Enum.count() == 0
    end
  end

  describe "count_strip/1 filter mode" do
    test "renders one native button per item with a stable id, key, and event" do
      assigns = %{
        items: [item(%{key: "name", label: "Name", count: 6}), item(%{key: "location", count: 2})]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" selected_key="name" />
        """)

      document = doc(html)

      assert LazyHTML.query(document, "#history-filter[data-mode='filter']") |> Enum.count() == 1

      assert LazyHTML.query(document, "#history-filter button[type='button']") |> Enum.count() ==
               2

      assert attr_of(document, "#history-filter-item-name", "phx-click") == ["filter_field"]
      assert attr_of(document, "#history-filter-item-name", "phx-value-key") == ["name"]
      assert attr_of(document, "#history-filter-item-location", "phx-value-key") == ["location"]
    end

    test "gives every filter button an explicit aria-pressed value, pressed only for the selection" do
      assigns = %{
        items: [item(%{key: "name", count: 6}), item(%{key: "location", count: 2})]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" selected_key="name" />
        """)

      document = doc(html)

      assert attr_of(document, "#history-filter-item-name", "aria-pressed") == ["true"]
      assert attr_of(document, "#history-filter-item-location", "aria-pressed") == ["false"]
    end

    test "leaves every button unpressed when no key is selected" do
      assigns = %{items: [item(%{key: "name"}), item(%{key: "location", count: 2})]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" />
        """)

      document = doc(html)

      assert attr_of(document, "#history-filter-item-name", "aria-pressed") == ["false"]
      assert attr_of(document, "#history-filter-item-location", "aria-pressed") == ["false"]
    end

    test "shows the selected button with a visible pressed treatment, not colour alone" do
      assigns = %{items: [item(%{key: "name"}), item(%{key: "location", count: 2})]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" selected_key="name" />
        """)

      document = doc(html)
      pressed = classes(document, "#history-filter-item-name")
      unpressed = classes(document, "#history-filter-item-location")

      assert pressed =~ "bg-primary"
      assert pressed =~ "text-primary-content"
      refute unpressed =~ "bg-primary"
      assert pressed != unpressed
    end

    test "passes phx-target through when the caller supplies one" do
      assigns = %{items: [item()]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" target="#history" />
        """)

      assert attr_of(doc(html), "#history-filter-item-name", "phx-target") == ["#history"]
    end

    test "omits phx-target when the caller supplies none" do
      assigns = %{items: [item()]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" />
        """)

      assert attr_of(doc(html), "#history-filter-item-name", "phx-target") == []
    end

    test "appends caller classes to the strip root" do
      assigns = %{items: [item()]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} class="mt-4" />
        """)

      assert classes(doc(html), "#history-filter") =~ "mt-4"
    end
  end

  describe "count_strip/1 zero-count filter items" do
    test "keeps a zero-count item focusable and marks it aria-disabled instead of disabled" do
      assigns = %{
        items: [item(%{key: "name", count: 6}), item(%{key: "wheelchair_boarding", count: 0})]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" />
        """)

      document = doc(html)
      zero = "#history-filter-item-wheelchair_boarding"

      assert attr_of(document, zero, "aria-disabled") == ["true"]
      assert attr_of(document, zero, "disabled") == []
      assert attr_of(document, zero, "tabindex") == []
      assert attr_of(document, "#history-filter-item-name", "aria-disabled") == []
    end

    test "marks the zero-count item visibly, not by colour alone" do
      assigns = %{
        items: [item(%{key: "name", count: 6}), item(%{key: "wheelchair_boarding", count: 0})]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" />
        """)

      document = doc(html)

      assert classes(document, "#history-filter-item-wheelchair_boarding") =~ "border-dashed"
      refute classes(document, "#history-filter-item-name") =~ "border-dashed"

      assert LazyHTML.text(LazyHTML.query(document, "#history-filter-item-wheelchair_boarding")) =~
               "0"
    end

    test "renders the caller's disabled reason as visible text" do
      assigns = %{
        items: [
          item(%{
            key: "wheelchair_boarding",
            label: "Wheelchair boarding",
            count: 0,
            disabled_reason: "No changes in this version"
          })
        ]
      }

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" />
        """)

      reason =
        doc(html)
        |> LazyHTML.query(
          "#history-filter-item-wheelchair_boarding [data-role='count-strip-reason']"
        )

      assert String.trim(LazyHTML.text(reason)) == "No changes in this version"
    end

    test "still dispatches the configured event so the consumer owns rejection" do
      assigns = %{items: [item(%{key: "wheelchair_boarding", count: 0})]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" />
        """)

      document = doc(html)

      assert attr_of(document, "#history-filter-item-wheelchair_boarding", "phx-click") ==
               ["filter_field"]

      assert attr_of(document, "#history-filter-item-wheelchair_boarding", "phx-value-key") ==
               ["wheelchair_boarding"]
    end

    test "meets the 44px minimum target on every filter button" do
      assigns = %{items: [item(%{key: "name", count: 6}), item(%{key: "location", count: 0})]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="history-filter" items={@items} event="filter_field" />
        """)

      document = doc(html)

      for key <- ~w(name location) do
        button_classes = classes(document, "#history-filter-item-#{key}")
        assert button_classes =~ "min-h-11"
        assert button_classes =~ "min-w-11"
        assert button_classes =~ "focus-visible:ring-2"
      end
    end

    test "renders a zero count in display mode without any button" do
      assigns = %{items: [item(%{key: "unreachable", label: "Unreachable", count: 0})]}

      html =
        rendered_to_string(~H"""
        <.count_strip id="report-counts" items={@items} />
        """)

      document = doc(html)

      assert LazyHTML.query(document, "#report-counts button") |> Enum.count() == 0
      assert LazyHTML.text(LazyHTML.query(document, "#report-counts-item-unreachable")) =~ "0"
    end
  end

  describe "count_strip/1 strict item validation" do
    test "rejects a non-map item" do
      assigns = %{items: [{"name", 6}]}

      assert_raise ArgumentError, ~r/item must be a map/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects items that are not a list" do
      assigns = %{items: %{key: "name", label: "Name", count: 1, tone: :neutral}}

      assert_raise ArgumentError, ~r/expects :items to be a list/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects an item missing a required field" do
      assigns = %{items: [%{key: "name", label: "Name", count: 1}]}

      assert_raise ArgumentError, ~r/missing required field\(s\) \[:tone\]/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects an item carrying an extra field" do
      assigns = %{items: [item(%{severity: :high})]}

      assert_raise ArgumentError, ~r/unsupported field\(s\) \[:severity\]/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a struct item, which carries an extra __struct__ field" do
      assigns = %{items: [~D[2026-07-21]]}

      assert_raise ArgumentError, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a negative count" do
      assigns = %{items: [item(%{count: -1})]}

      assert_raise ArgumentError, ~r/:count must be a non-negative integer/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a non-integer count" do
      assigns = %{items: [item(%{count: "6"})]}

      assert_raise ArgumentError, ~r/:count must be a non-negative integer/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects an unsupported tone" do
      assigns = %{items: [item(%{tone: :critical})]}

      assert_raise ArgumentError, ~r/:tone must be one of/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a tone given as a string" do
      assigns = %{items: [item(%{tone: "info"})]}

      assert_raise ArgumentError, ~r/:tone must be one of/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a blank label" do
      assigns = %{items: [item(%{label: "   "})]}

      assert_raise ArgumentError, ~r/:label must be a non-empty string/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a non-string label" do
      assigns = %{items: [item(%{label: :name})]}

      assert_raise ArgumentError, ~r/:label must be a non-empty string/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a key that cannot become a stable DOM id" do
      assigns = %{items: [item(%{key: "stop name"})]}

      assert_raise ArgumentError, ~r/:key must be a non-empty string/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects an atom key" do
      assigns = %{items: [item(%{key: :name})]}

      assert_raise ArgumentError, ~r/:key must be a non-empty string/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects duplicate keys, which would produce duplicate DOM ids" do
      assigns = %{items: [item(%{key: "name"}), item(%{key: "name", label: "Name again"})]}

      assert_raise ArgumentError, ~r/duplicate item key\(s\) \["name"\]/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "rejects a blank disabled reason" do
      assigns = %{items: [item(%{count: 0, disabled_reason: ""})]}

      assert_raise ArgumentError, ~r/:disabled_reason must be a non-empty string/, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end

    test "fails fast in display mode too, not only when rendering buttons" do
      assigns = %{items: [item(%{tone: :critical})]}

      assert_raise ArgumentError, fn ->
        rendered_to_string(~H"""
        <.count_strip id="strip" items={@items} />
        """)
      end
    end
  end
end

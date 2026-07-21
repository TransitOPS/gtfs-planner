defmodule GtfsPlannerWeb.Components.TransitPresentationTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Components.TransitPresentation

  # `version_diff_row/1` is a shared primitive: it renders one record's
  # difference between two versions and owns structure only. Every case below
  # states the component's own contract in domain-neutral terms — the consuming
  # package supplies the words, the raw keys, the values, and the actions.
  defp row(overrides) do
    assigns =
      Keyword.merge(
        [
          id: "diff-1",
          action: :modify,
          entity_label: "Stop",
          natural_key: "STOP-1",
          status: :applied,
          summary: nil,
          changes: [],
          dependency_keys: [],
          edited?: false,
          expanded?: true
        ],
        overrides
      )

    render_component(&TransitPresentation.version_diff_row/1, assigns)
  end

  defp change(overrides) do
    Map.merge(%{label: "Name", before: "Old", after: "New"}, Map.new(overrides))
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  defp text(html, selector) do
    html |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  end

  defp texts(html, selector) do
    html
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp attr_of(html, selector, name) do
    html |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  describe "accessibility_status/1" do
    test "renders all three accessibility states without transforming the source value" do
      for {status, label} <- [
            {:accessible, "Accessible"},
            {:not_accessible, "Not accessible"},
            {:unknown, "No data"}
          ] do
        assigns = %{status: status}

        html =
          rendered_to_string(~H"""
          <TransitPresentation.accessibility_status status={@status} />
          """)

        assert html =~ ~s(data-accessibility="#{status}")
        assert html =~ label
      end
    end

    test "renders No data for the stable :unknown atom" do
      assigns = %{status: :unknown}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} />
        """)

      assert html =~ ~s(data-accessibility="unknown")
      assert html =~ "No data"
      refute html =~ "Accessibility unknown"
    end

    test "does not render inheritance disclosure for the default direct source" do
      assigns = %{status: :accessible}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} />
        """)

      refute html =~ "Inherited from station"
      refute html =~ ~s(data-accessibility-source="inherited")
    end

    test "renders adjacent source text when the value is inherited" do
      assigns = %{status: :accessible}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} source={:inherited} />
        """)

      assert html =~ "Accessible"
      assert html =~ "Inherited from station"
      assert html =~ ~s(data-accessibility-source="inherited")
    end

    test "renders No data without inheritance disclosure for a missing source" do
      assigns = %{status: :unknown}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.accessibility_status status={@status} source={:missing} />
        """)

      assert html =~ "No data"
      refute html =~ "Inherited from station"
    end
  end

  describe "pathway_summary/1" do
    test "renders mode, textual direction, and supplied metrics with mono/tabular values" do
      assigns = %{
        pathway: %{
          pathway_mode: 2,
          is_bidirectional: false,
          stair_count: 24,
          length: Decimal.new("18.5"),
          traversal_time: 32
        }
      }

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ "Stairs"
      assert html =~ "One way"
      assert html =~ "font-mono"
      assert html =~ "tabular-nums"
      assert html =~ ">24<"
      assert html =~ ">stairs<"
      assert html =~ ">18.5<"
      assert html =~ ">m<"
      assert html =~ ">32<"
      assert html =~ ">sec<"
    end

    test "renders bidirectional direction as text" do
      assigns = %{pathway: %{pathway_mode: 1, is_bidirectional: true}}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ "Walkway"
      assert html =~ "Bidirectional"
    end

    test "renders duration in seconds as a natural unit" do
      assigns = %{pathway: %{pathway_mode: 3, is_bidirectional: true, traversal_time: 45}}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ ">45<"
      assert html =~ ">sec<"
    end

    test "omits stair metrics that do not apply to the pathway mode" do
      assigns = %{
        pathway: %{pathway_mode: 5, is_bidirectional: true, stair_count: 24, traversal_time: nil}
      }

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ "Elevator"
      assert html =~ "Bidirectional"
      refute html =~ ">stairs<"
      refute html =~ ">24<"
    end

    test "omits absent length and duration metrics" do
      assigns = %{
        pathway: %{
          pathway_mode: 2,
          is_bidirectional: false,
          stair_count: 12,
          length: nil,
          traversal_time: nil
        }
      }

      html =
        rendered_to_string(~H"""
        <TransitPresentation.pathway_summary pathway={@pathway} />
        """)

      assert html =~ ">12<"
      assert html =~ ">stairs<"
      refute html =~ ">m<"
      refute html =~ ">sec<"
    end
  end

  describe "version_diff_row/1 identity and structure" do
    test "renders one addressable row carrying action, status and expansion state" do
      html = row(id: "diff-42", action: :remove, status: :pending, expanded?: false)

      assert attr_of(html, "#diff-42", "data-role") == ["version-diff-row"]
      assert attr_of(html, "#diff-42", "data-action") == ["remove"]
      assert attr_of(html, "#diff-42", "data-status") == ["pending"]
      assert attr_of(html, "#diff-42", "data-expanded") == ["false"]
    end

    test "states the entity label and its natural key as secondary metadata" do
      html = row(entity_label: "Pathway", natural_key: "PW-EAST-01")

      assert text(html, "[data-role=\"version-diff-entity\"]") == "Pathway"
      assert text(html, "[data-role=\"version-diff-key\"]") == "PW-EAST-01"
    end

    test "renders the caller's summary and omits the element when there is none" do
      html = row(summary: "Edited stop · 2 fields changed")

      assert text(html, "[data-role=\"version-diff-summary\"]") ==
               "Edited stop · 2 fields changed"

      assert texts(row(summary: nil), "[data-role=\"version-diff-summary\"]") == []
    end

    test "marks a locally edited row in words, not by color alone" do
      assert text(row(edited?: true), "[data-role=\"version-diff-edited\"]") == "Edited"
      assert texts(row(edited?: false), "[data-role=\"version-diff-edited\"]") == []
    end
  end

  describe "version_diff_row/1 action and status vocabulary" do
    test "every action renders its own word" do
      for {action, word} <- [
            {:add, "Added"},
            {:modify, "Modified"},
            {:remove, "Removed"},
            {:conflict, "Conflict"}
          ] do
        assert text(row(action: action), "[data-role=\"version-diff-action\"]") == word
      end
    end

    test "every status renders its own word" do
      for {status, word} <- [
            {:pending, "Pending"},
            {:approved, "Approved"},
            {:rejected, "Rejected"},
            {:preview, "Preview"},
            {:applied, "Applied"},
            {:failed, "Failed"}
          ] do
        assert text(row(status: status), "[data-role=\"version-diff-status\"]") == word
      end
    end
  end

  describe "version_diff_row/1 change values" do
    test "renders a human label and its optional raw key as secondary metadata" do
      html = row(changes: [change(label: "Stop name", key: "stop_name")])

      assert text(html, "[data-role=\"version-diff-change-label\"]") == "Stop name"
      assert text(html, "[data-role=\"version-diff-change-key\"]") == "stop_name"
    end

    test "omits the raw key element when the caller supplies no key" do
      html = row(changes: [change(label: "Stop name")])

      assert text(html, "[data-role=\"version-diff-change-label\"]") == "Stop name"
      assert texts(html, "[data-role=\"version-diff-change-key\"]") == []
    end

    test "renders a 61 character value complete and unabbreviated" do
      long = String.duplicate("a", 61)
      html = row(changes: [change(before: "short", after: long)])

      assert String.length(long) == 61
      assert text(html, "[data-role=\"version-diff-after\"]") == long
      refute html =~ "…"
    end

    test "renders a long value in a wrapping container rather than clipping it" do
      html = row(changes: [change(after: String.duplicate("z", 200))])
      [class] = attr_of(html, "[data-role=\"version-diff-after\"]", "class")

      assert class =~ "overflow-wrap:anywhere"
      refute class =~ "truncate"
      refute class =~ "overflow-hidden"
    end

    test "renders false, zero and nil as those exact values" do
      html =
        row(
          changes: [
            change(label: "Bidirectional", before: true, after: false),
            change(label: "Stair count", before: 12, after: 0),
            change(label: "Level index", before: 1, after: nil)
          ]
        )

      assert texts(html, "[data-role=\"version-diff-after\"]") == ["false", "0", "nil"]

      assert attr_of(html, "[data-role=\"version-diff-after\"]", "data-value-kind") ==
               ["boolean", "number", "nil"]
    end

    test "distinguishes a value that was never recorded from a nil value" do
      html =
        row(
          changes: [
            change(label: "Recorded nil", before: TransitPresentation.absent_value(), after: nil)
          ]
        )

      assert text(html, "[data-role=\"version-diff-before\"]") == "Not recorded"
      assert attr_of(html, "[data-role=\"version-diff-before\"]", "data-value-kind") == ["absent"]
      assert text(html, "[data-role=\"version-diff-after\"]") == "nil"
    end

    test "renders an empty string visibly rather than as a blank cell" do
      html = row(changes: [change(before: "Old", after: "")])

      assert text(html, "[data-role=\"version-diff-after\"]") == ~s("")
      assert attr_of(html, "[data-role=\"version-diff-after\"]", "data-value-kind") == ["blank"]
    end

    test "renders decimals in plain notation" do
      html =
        row(
          changes: [
            change(label: "Length", before: Decimal.new("18.50"), after: Decimal.new("0.00"))
          ]
        )

      assert texts(html, "[data-role=\"version-diff-before\"]") == ["18.50"]
      assert texts(html, "[data-role=\"version-diff-after\"]") == ["0.00"]
    end

    test "numeric values use tabular numerals so columns compare" do
      html = row(changes: [change(before: 10, after: 9)])
      [class] = attr_of(html, "[data-role=\"version-diff-after\"]", "class")

      assert class =~ "tabular-nums"
    end

    test "keeps each change addressable by its key and preserves caller order" do
      html = row(changes: [change(label: "B", key: "b_key"), change(label: "A", key: "a_key")])

      assert attr_of(html, "[data-role=\"version-diff-change\"]", "data-change-key") ==
               ["b_key", "a_key"]

      assert texts(html, "[data-role=\"version-diff-change-label\"]") == ["B", "A"]
    end

    test "a collapsed row keeps its complete values in the document but hidden" do
      html = row(changes: [change(after: "New")], expanded?: false)

      assert attr_of(html, "[data-role=\"version-diff-changes\"]", "hidden") == [""]
      assert text(html, "[data-role=\"version-diff-after\"]") == "New"
    end

    test "an expanded row does not hide its changes" do
      html = row(changes: [change([])], expanded?: true)

      assert attr_of(html, "[data-role=\"version-diff-changes\"]", "hidden") == []
    end

    test "no changes renders no change region" do
      assert texts(row(changes: []), "[data-role=\"version-diff-changes\"]") == []
    end
  end

  describe "version_diff_row/1 dependency keys" do
    test "lists each dependency key" do
      html = row(dependency_keys: ["STOP-1", "LEVEL-2"])

      assert texts(html, "[data-role=\"version-diff-dependency\"]") == ["STOP-1", "LEVEL-2"]
    end

    test "renders no dependency region when there are none" do
      assert texts(row(dependency_keys: []), "[data-role=\"version-diff-dependencies\"]") == []
    end
  end

  describe "version_diff_row/1 actions slot" do
    test "renders caller-owned actions in one fixed zone" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <TransitPresentation.version_diff_row
          id="diff-1"
          action={:modify}
          entity_label="Stop"
          natural_key="STOP-1"
          status={:applied}
          changes={[]}
          dependency_keys={[]}
          edited?={false}
          expanded?={true}
        >
          <:actions>
            <button type="button" id="diff-1-undo">Undo change</button>
          </:actions>
        </TransitPresentation.version_diff_row>
        """)

      assert attr_of(html, "[data-role=\"version-diff-actions\"] #diff-1-undo", "type") == [
               "button"
             ]
    end

    test "renders no action zone when the slot is empty" do
      assert texts(row([]), "[data-role=\"version-diff-actions\"]") == []
    end
  end

  describe "version_diff_row/1 fails fast on malformed input" do
    test "rejects a change that is not a map" do
      assert_raise ArgumentError, ~r/diff-1/, fn -> row(changes: ["stop_name"]) end
    end

    test "rejects a change missing before or after" do
      assert_raise ArgumentError, ~r/:after/, fn ->
        row(changes: [%{label: "Name", before: "a"}])
      end
    end

    test "rejects a change carrying an unsupported field" do
      assert_raise ArgumentError, ~r/:tone/, fn ->
        row(changes: [Map.put(change([]), :tone, :error)])
      end
    end

    test "rejects a blank change label" do
      assert_raise ArgumentError, ~r/:label/, fn -> row(changes: [change(label: "  ")]) end
    end

    test "rejects a non-list changes value" do
      assert_raise ArgumentError, ~r/:changes/, fn -> row(changes: %{label: "Name"}) end
    end

    test "rejects a non-string dependency key" do
      assert_raise ArgumentError, ~r/:dependency_keys/, fn -> row(dependency_keys: [:stop]) end
    end

    test "rejects a blank natural key" do
      assert_raise ArgumentError, ~r/:natural_key/, fn -> row(natural_key: "") end
    end

    test "rejects a blank entity label" do
      assert_raise ArgumentError, ~r/:entity_label/, fn -> row(entity_label: "") end
    end
  end
end

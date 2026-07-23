defmodule GtfsPlannerWeb.Components.TransitPresentationTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Components.TransitPresentation

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

  describe "version_diff_row/1" do
    @action_labels %{
      add: {"Added", "hero-plus"},
      modify: {"Changed", "hero-pencil-square"},
      remove: {"Removed", "hero-minus"},
      conflict: {"Conflict", "hero-exclamation-triangle"}
    }

    @status_labels %{
      pending: "Pending",
      approved: "Approved",
      rejected: "Rejected",
      preview: "Preview only",
      applied: "Applied",
      failed: "Failed"
    }

    test "renders every action and status with a text label and semantic symbol" do
      for {action, {action_label, icon}} <- @action_labels,
          {status, status_label} <- @status_labels do
        assigns = diff_row_assigns(action, status)

        html =
          rendered_to_string(~H"""
          <TransitPresentation.version_diff_row
            id={@id}
            action={@action}
            entity_label={@entity_label}
            natural_key={@natural_key}
            status={@status}
          />
          """)

        assert html =~ ~s(data-version-diff-action="#{action}")
        assert html =~ ~s(data-version-diff-status="#{status}")
        assert html =~ action_label
        assert html =~ status_label
        assert html =~ icon
      end
    end

    test "renders the frozen value, dependency, edited, disclosure, and action-slot contract" do
      assigns =
        diff_row_assigns(:modify, :rejected)
        |> Map.merge(%{
          summary: "Corrected the platform position",
          changes: [
            %{label: "Latitude", before: "47.60432", after: "47.60455"},
            %{label: "Wheelchair boarding", before: nil, after: "Allowed"}
          ],
          dependency_keys: ["level:concourse", "stop:harbor-terminal"],
          edited?: true,
          expanded?: true
        })

      html =
        rendered_to_string(~H"""
        <TransitPresentation.version_diff_row
          id={@id}
          action={@action}
          entity_label={@entity_label}
          natural_key={@natural_key}
          status={@status}
          summary={@summary}
          changes={@changes}
          dependency_keys={@dependency_keys}
          edited?={@edited?}
          expanded?={@expanded?}
        >
          <:actions>
            <button id="review-harbor-terminal" type="button" class="min-h-11">Review change</button>
          </:actions>
        </TransitPresentation.version_diff_row>
        """)

      assert html =~ ~s(id="diff-harbor-terminal")
      assert html =~ "Stop"
      assert html =~ "stop:harbor-terminal"
      assert html =~ "Corrected the platform position"
      assert html =~ "Latitude"
      assert html =~ "47.60432"
      assert html =~ "47.60455"
      assert html =~ "No value"
      assert html =~ "Allowed"
      assert html =~ "Depends on: level:concourse, stop:harbor-terminal"
      assert html =~ "Edited before applying"
      assert html =~ "Rejected"
      assert html =~ ~s(id="diff-harbor-terminal-disclosure")
      assert html =~ ~s(aria-controls="diff-harbor-terminal-details")
      assert html =~ ~s(id="diff-harbor-terminal-details")
      assert html =~ "<details id=\"diff-harbor-terminal-details\" open"
      assert html =~ ~s(id="review-harbor-terminal")
      refute html =~ "phx-click"
      refute html =~ "phx-submit"
    end

    test "names an empty-string value instead of rendering nothing" do
      assigns =
        diff_row_assigns(:modify, :applied)
        |> Map.merge(%{
          changes: [%{label: "Stop description", key: "stop_desc", before: "Old text", after: ""}],
          expanded?: true
        })

      html =
        rendered_to_string(~H"""
        <TransitPresentation.version_diff_row
          id={@id}
          action={@action}
          entity_label={@entity_label}
          natural_key={@natural_key}
          status={@status}
          changes={@changes}
          expanded?={@expanded?}
        />
        """)

      assert html =~ ~s(data-role="version-diff-after" data-value-kind="empty")
      assert html =~ ~s(aria-label="Empty value")
      assert html =~ "Empty"
    end

    test "omits an empty disclosure and optional content" do
      assigns = diff_row_assigns(:add, :pending)

      html =
        rendered_to_string(~H"""
        <TransitPresentation.version_diff_row
          id={@id}
          action={@action}
          entity_label={@entity_label}
          natural_key={@natural_key}
          status={@status}
        />
        """)

      refute html =~ "<summary"
      refute html =~ "<details"
      refute html =~ "Corrected the platform position"
      refute html =~ "Edited before applying"
      refute html =~ "Depends on:"
    end

    defp diff_row_assigns(action, status) do
      %{
        id: "diff-harbor-terminal",
        action: action,
        entity_label: "Stop",
        natural_key: "stop:harbor-terminal",
        status: status
      }
    end
  end
end

defmodule GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents

  test "exposes change_log_list/1 as a function component" do
    Code.ensure_loaded!(ChangeHistoryComponents)
    assert function_exported?(ChangeHistoryComponents, :change_log_list, 1)
  end

  test "history tabs expose the hook-owned roving-focus relationships" do
    html =
      render_component(&ChangeHistoryComponents.history_tab_strip/1,
        entity_type: "stop",
        entity_id: "stop-1",
        history_active: false
      )

    assert html =~ ~s(id="stop-tabs")
    assert html =~ ~s(phx-hook="TablistHook")
    assert html =~ ~s(id="stop-tab-details")
    assert html =~ ~s(aria-controls="stop-panel-details")
    assert html =~ ~s(id="stop-tab-history")
    assert html =~ ~s(aria-controls="stop-panel-history")
    assert html =~ ~s(tabindex="0")
    assert html =~ ~s(tabindex="-1")
  end

  describe "display_name/1" do
    test "extracts and titlecases the local part of an email" do
      assert ChangeHistoryComponents.__test_display_name__("ryan.mahoney@example.com") ==
               "Ryan Mahoney"
    end

    test "returns Unknown for nil" do
      assert ChangeHistoryComponents.__test_display_name__(nil) == "Unknown"
    end

    test "returns Unknown for empty string" do
      assert ChangeHistoryComponents.__test_display_name__("") == "Unknown"
    end
  end

  describe "format_date_header/2" do
    test "labels today" do
      today = ~D[2026-04-26]
      assert ChangeHistoryComponents.__test_format_date_header__(today, today) =~ "TODAY"
    end

    test "labels yesterday" do
      today = ~D[2026-04-26]
      yesterday = Date.add(today, -1)

      assert ChangeHistoryComponents.__test_format_date_header__(yesterday, today) =~
               "YESTERDAY"
    end

    test "older dates render plain upcased month/day" do
      today = ~D[2026-04-26]
      older = Date.add(today, -10)
      result = ChangeHistoryComponents.__test_format_date_header__(older, today)

      refute result =~ "TODAY"
      refute result =~ "YESTERDAY"
      assert result == "APR 16"
    end
  end

  describe "format_time_short/2" do
    test "renders today's time without separator" do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      result = ChangeHistoryComponents.__test_format_time_short__(now, today)

      refute result =~ "·"
      assert result =~ ~r/\d{1,2}:\d{2}\s(AM|PM)/
    end

    test "renders other-day time with month/day separator" do
      now = DateTime.utc_now()
      today = DateTime.to_date(now)
      yesterday = DateTime.add(now, -86_400, :second)

      assert ChangeHistoryComponents.__test_format_time_short__(yesterday, today) =~ "·"
    end
  end

  describe "group_entries_by_date/1" do
    test "groups by date and sorts descending" do
      d1 = ~U[2026-04-24 10:00:00Z]
      d2 = ~U[2026-04-25 10:00:00Z]
      d3 = ~U[2026-04-26 10:00:00Z]

      entries = [
        %{id: 1, inserted_at: d1},
        %{id: 2, inserted_at: d3},
        %{id: 3, inserted_at: d2},
        %{id: 4, inserted_at: d3}
      ]

      grouped = ChangeHistoryComponents.__test_group_entries_by_date__(entries)
      dates = Enum.map(grouped, fn {date, _} -> date end)

      assert dates == [~D[2026-04-26], ~D[2026-04-25], ~D[2026-04-24]]
    end
  end

  describe "field_groups/1" do
    test "stop groups lead with All fields and Position" do
      [first, second | _] = ChangeHistoryComponents.__test_field_groups__("stop")

      assert first.key == "all"
      assert first.fields == :all
      assert second.key == "position"
    end

    test "pathway groups expose mode" do
      keys =
        "pathway"
        |> ChangeHistoryComponents.__test_field_groups__()
        |> Enum.map(& &1.key)

      assert "mode" in keys
    end

    test "level groups expose naming and index" do
      keys =
        "level"
        |> ChangeHistoryComponents.__test_field_groups__()
        |> Enum.map(& &1.key)

      assert "naming" in keys
      assert "index" in keys
    end
  end

  describe "categorical_value/2" do
    test "stop wheelchair_boarding accessible" do
      assert ChangeHistoryComponents.__test_categorical_value__(
               {"stop", "wheelchair_boarding"},
               1
             ) == {"Wheelchair accessible", "bg-emerald-600"}
    end

    test "stop wheelchair_boarding no information" do
      assert ChangeHistoryComponents.__test_categorical_value__(
               {"stop", "wheelchair_boarding"},
               0
             ) == {"No information", "bg-base-300"}
    end

    test "stop wheelchair_boarding not accessible" do
      assert ChangeHistoryComponents.__test_categorical_value__(
               {"stop", "wheelchair_boarding"},
               2
             ) == {"Not accessible", "bg-rose-600"}
    end

    test "non-categorical fields fall through to :passthrough" do
      assert ChangeHistoryComponents.__test_categorical_value__({"stop", "stop_name"}, "x") ==
               :passthrough
    end

    test "pathway is_bidirectional true" do
      assert ChangeHistoryComponents.__test_categorical_value__(
               {"pathway", "is_bidirectional"},
               true
             ) == {"Bidirectional", nil}
    end

    test "pathway is_bidirectional false" do
      assert ChangeHistoryComponents.__test_categorical_value__(
               {"pathway", "is_bidirectional"},
               false
             ) == {"One-way", nil}
    end

    test "stop location_type uses Stop.location_type_label/1" do
      assert ChangeHistoryComponents.__test_categorical_value__(
               {"stop", "location_type"},
               1
             ) == {"Station", nil}
    end

    test "pathway pathway_mode uses Pathway.mode_label/1" do
      assert ChangeHistoryComponents.__test_categorical_value__(
               {"pathway", "pathway_mode"},
               5
             ) == {"Elevator", nil}
    end
  end

  describe "apply_field_filter/3" do
    setup do
      rows = [
        %{field: "stop_lat", from: 0.0, to: 1.0},
        %{field: "stop_lon", from: 0.0, to: 2.0},
        %{field: "stop_name", from: "a", to: "b"},
        %{field: "wheelchair_boarding", from: 0, to: 1}
      ]

      {:ok, rows: rows}
    end

    test "position keeps only position fields", %{rows: rows} do
      filtered = ChangeHistoryComponents.__test_apply_field_filter__(rows, "stop", "position")
      assert Enum.map(filtered, & &1.field) == ["stop_lat", "stop_lon"]
    end

    test "all returns rows unchanged", %{rows: rows} do
      assert ChangeHistoryComponents.__test_apply_field_filter__(rows, "stop", "all") == rows
    end

    test "unknown filter key returns rows unchanged", %{rows: rows} do
      assert ChangeHistoryComponents.__test_apply_field_filter__(rows, "stop", "bogus_key") ==
               rows
    end

    test "accessibility keeps only wheelchair_boarding rows", %{rows: rows} do
      filtered =
        ChangeHistoryComponents.__test_apply_field_filter__(rows, "stop", "accessibility")

      assert Enum.map(filtered, & &1.field) == ["wheelchair_boarding"]
    end

    test "empty input yields empty output" do
      assert ChangeHistoryComponents.__test_apply_field_filter__([], "stop", "position") == []
    end
  end

  describe "rollback_button_variant/3" do
    test "latest non-reverted updated entry returns :undo" do
      entry = %{id: 1, action: "updated"}

      assert ChangeHistoryComponents.__test_rollback_button_variant__(entry, %{}, true) ==
               :undo
    end

    test "older non-reverted updated entry returns :restore" do
      entry = %{id: 1, action: "updated"}

      assert ChangeHistoryComponents.__test_rollback_button_variant__(entry, %{}, false) ==
               :restore
    end

    test "latest rolled_back entry returns :undo (it represents the current state)" do
      entry = %{id: 1, action: "rolled_back"}

      assert ChangeHistoryComponents.__test_rollback_button_variant__(entry, %{}, true) ==
               :undo
    end

    test "older rolled_back entry returns :restore" do
      entry = %{id: 1, action: "rolled_back"}

      assert ChangeHistoryComponents.__test_rollback_button_variant__(entry, %{}, false) ==
               :restore
    end

    test "created entry returns :original" do
      entry = %{id: 1, action: "created"}

      assert ChangeHistoryComponents.__test_rollback_button_variant__(entry, %{}, true) ==
               :original
    end

    test "entry whose id is keyed in rollback_by_original_id returns :reapply" do
      entry = %{id: 7, action: "updated"}
      rollback_map = %{7 => %{id: 99, action: "rolled_back"}}

      assert ChangeHistoryComponents.__test_rollback_button_variant__(entry, rollback_map, false) ==
               :reapply
    end

    test "reverted entry takes precedence over current? = true" do
      entry = %{id: 7, action: "updated"}
      rollback_map = %{7 => %{id: 99, action: "rolled_back"}}

      assert ChangeHistoryComponents.__test_rollback_button_variant__(entry, rollback_map, true) ==
               :reapply
    end
  end

  describe "rollback_button_label/1 (atom-arg)" do
    test ":undo" do
      assert ChangeHistoryComponents.__test_rollback_button_label__(:undo) == "Undo this change"
    end

    test ":restore" do
      assert ChangeHistoryComponents.__test_rollback_button_label__(:restore) ==
               "Restore to this state"
    end

    test ":reapply" do
      assert ChangeHistoryComponents.__test_rollback_button_label__(:reapply) ==
               "Re-apply this change"
    end

    test ":original" do
      assert ChangeHistoryComponents.__test_rollback_button_label__(:original) ==
               "Original version"
    end

    test ":none" do
      assert ChangeHistoryComponents.__test_rollback_button_label__(:none) == nil
    end
  end

  describe "preview_matches_entry?/3" do
    test "returns false when preview is nil" do
      entry = %{id: 1}
      refute ChangeHistoryComponents.__test_preview_matches_entry__(nil, "stop", entry)
    end

    test "returns true when entity_type and log id match the entry" do
      entry = %{id: 42}
      preview = %{entity_type: "stop", log: %{id: 42}}

      assert ChangeHistoryComponents.__test_preview_matches_entry__(preview, "stop", entry)
    end

    test "returns false when entity_type does not match" do
      entry = %{id: 42}
      preview = %{entity_type: "stop", log: %{id: 42}}

      refute ChangeHistoryComponents.__test_preview_matches_entry__(preview, "pathway", entry)
    end

    test "returns false when log id does not match the entry id" do
      entry = %{id: 99}
      preview = %{entity_type: "stop", log: %{id: 42}}

      refute ChangeHistoryComponents.__test_preview_matches_entry__(preview, "stop", entry)
    end
  end

  describe "change_diff/1 rendering" do
    test "renders categorical wheelchair_boarding label and dot for stop entity" do
      entry = %{
        id: "abc",
        changed_fields: %{"wheelchair_boarding" => %{"from" => 0, "to" => 1}}
      }

      html =
        render_component(&ChangeHistoryComponents.change_diff/1,
          entry: entry,
          entity_type: "stop"
        )

      assert html =~ "Wheelchair accessible"
      assert html =~ "No information"
      assert html =~ "bg-emerald-600"
      assert html =~ "bg-base-300"
    end

    test "renders not-accessible label and rose dot for to: 2" do
      entry = %{
        id: "abc",
        changed_fields: %{"wheelchair_boarding" => %{"from" => 1, "to" => 2}}
      }

      html =
        render_component(&ChangeHistoryComponents.change_diff/1,
          entry: entry,
          entity_type: "stop"
        )

      assert html =~ "Not accessible"
      assert html =~ "bg-rose-600"
    end

    test "non-categorical fields fall through to plain text without dot span" do
      entry = %{
        id: "abc",
        changed_fields: %{"stop_name" => %{"from" => "Old Name", "to" => "New Name"}}
      }

      html =
        render_component(&ChangeHistoryComponents.change_diff/1,
          entry: entry,
          entity_type: "stop"
        )

      assert html =~ "stop_name"
      assert html =~ "Old Name"
      assert html =~ "New Name"
      refute html =~ "bg-emerald-600"
      refute html =~ "bg-base-300"
      refute html =~ "bg-rose-600"
    end

    test "uses two-column grid layout" do
      entry = %{
        id: "abc",
        changed_fields: %{"stop_name" => %{"from" => "A", "to" => "B"}}
      }

      html =
        render_component(&ChangeHistoryComponents.change_diff/1,
          entry: entry,
          entity_type: "stop"
        )

      assert html =~ "[grid-template-columns:max-content_minmax(0,1fr)]"
    end

    test "accepts pre-filtered rows via :rows attr" do
      rows = [%{field: "wheelchair_boarding", from: 0, to: 1}]

      html =
        render_component(&ChangeHistoryComponents.change_diff/1,
          entry: %{id: "abc", changed_fields: %{}},
          entity_type: "stop",
          rows: rows
        )

      assert html =~ "Wheelchair accessible"
      assert html =~ "bg-emerald-600"
    end
  end

  describe "relative_time/2" do
    test "just now for sub-minute differences" do
      now = DateTime.utc_now()
      assert ChangeHistoryComponents.__test_relative_time__(now, now) =~ "just now"
    end

    test "minutes ago" do
      now = DateTime.utc_now()
      five_min_ago = DateTime.add(now, -5 * 60, :second)

      assert ChangeHistoryComponents.__test_relative_time__(five_min_ago, now) ==
               "5 minutes ago"
    end

    test "yesterday for one-day-ago" do
      now = DateTime.utc_now()
      one_day_ago = DateTime.add(now, -86_400, :second)

      assert ChangeHistoryComponents.__test_relative_time__(one_day_ago, now) == "yesterday"
    end
  end
end

defmodule GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents

  @agency_zone %{timezone: "America/New_York", fallback?: false, fallback_reason: nil}
  @utc_fallback %{timezone: "UTC", fallback?: true, fallback_reason: :conflicting}

  defp filter_form(key \\ "all"), do: Phoenix.Component.to_form(%{"key" => key})

  defp entry(overrides) do
    Map.merge(
      %{
        id: "log-1",
        action: "updated",
        actor_email: "ada.lovelace@example.com",
        inserted_at: ~U[2026-04-26 18:30:00Z],
        rolled_back_to_log_id: nil,
        changed_fields: %{"stop_name" => %{"from" => "Old", "to" => "New"}}
      },
      Map.new(overrides)
    )
  end

  # The LiveView localizes every timestamp in one batch (PostgreSQL owns the
  # IANA conversion) and hands the component the result keyed by entry id.
  # These isolated tests stand in for that batch with a fixed offset: the
  # component's contract is "consume the supplied local values", never convert.
  defp local_times(entries, zone) do
    offset_seconds = if zone.fallback?, do: 0, else: -4 * 3600

    Map.new(entries, fn e ->
      {e.id, e.inserted_at |> DateTime.add(offset_seconds, :second) |> DateTime.to_naive()}
    end)
  end

  defp render_history(opts) do
    entries = Keyword.get(opts, :entries, [])
    zone = Keyword.get(opts, :zone, @agency_zone)

    assigns =
      [
        entity_type: "stop",
        entries: entries,
        state: :ready,
        history_field_filter: "all",
        rollback_preview: nil,
        zone: zone,
        local_times: local_times(entries, zone),
        today: ~D[2026-04-26],
        now: ~N[2026-04-26 14:35:00]
      ]
      |> Keyword.merge(opts)

    assigns = Keyword.put(assigns, :filter_form, filter_form(assigns[:history_field_filter]))

    render_component(&ChangeHistoryComponents.change_log_list/1, assigns)
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  describe "change_log_list/1 lifecycle states" do
    test "initial loading shows a labelled skeleton and no entry list" do
      html = render_history(entries: [], state: :initial_loading)
      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#history-loading-stop")) == 1
      assert html =~ "Loading history"
      assert LazyHTML.attribute(LazyHTML.query(d, "#history-stop"), "data-state") == ["loading"]
      assert Enum.empty?(LazyHTML.query(d, "[data-role=\"history-entry\"]"))
      assert Enum.empty?(LazyHTML.query(d, "#history-empty-stop"))
    end

    test "ready with no entries shows the first-use empty state, not the filtered one" do
      html = render_history(entries: [], state: :ready)
      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#history-empty-stop")) == 1
      assert Enum.empty?(LazyHTML.query(d, "#history-filtered-empty-stop"))
      assert html =~ "No changes have been recorded for this stop"
      assert LazyHTML.attribute(LazyHTML.query(d, "#history-stop"), "data-state") == ["empty"]

      # ux-states: a first-use empty state still offers a next action.
      details = LazyHTML.query(d, "#history-open-details-stop")
      assert LazyHTML.attribute(details, "phx-click") == ["hide_history"]
    end

    test "refreshing keeps the previously loaded entries on screen" do
      entries = [entry(id: "log-1")]
      html = render_history(entries: entries, state: :refreshing)
      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#history-refreshing-stop")) == 1
      assert html =~ "Refreshing history"
      assert Enum.count(LazyHTML.query(d, "#history-entry-log-1")) == 1

      assert LazyHTML.attribute(LazyHTML.query(d, "#history-stop"), "data-state") == [
               "refreshing"
             ]
    end

    test "error with prior entries renders a retry action and a stale-preview disclosure" do
      entries = [entry(id: "log-1")]
      html = render_history(entries: entries, state: :error)
      d = doc(html)

      retry = LazyHTML.query(d, "#history-retry-stop")
      assert Enum.count(retry) == 1
      assert LazyHTML.attribute(retry, "phx-click") == ["retry_history"]
      assert html =~ "Retry"
      assert Enum.count(LazyHTML.query(d, "#history-stale-stop")) == 1
      assert Enum.count(LazyHTML.query(d, "#history-entry-log-1")) == 1
      assert LazyHTML.attribute(LazyHTML.query(d, "#history-stop"), "data-state") == ["error"]
    end

    test "error without prior entries has no stale-preview disclosure" do
      html = render_history(entries: [], state: :error)
      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#history-retry-stop")) == 1
      assert Enum.empty?(LazyHTML.query(d, "#history-stale-stop"))
    end
  end

  describe "change_log_list/1 filter, counts and filtered-empty state" do
    test "the Fields control is a form-bound select with a visible label" do
      entries = [entry(id: "log-1")]
      html = render_history(entries: entries)
      d = doc(html)

      select = LazyHTML.query(d, "select#history-filter-stop")
      assert Enum.count(select) == 1
      assert LazyHTML.attribute(select, "name") == ["key"]

      form = LazyHTML.query(d, "#history-filter-form-stop")
      assert LazyHTML.attribute(form, "phx-change") == ["filter_history"]

      label_text =
        d
        |> LazyHTML.query("#history-filter-form-stop label span")
        |> LazyHTML.text()

      assert label_text =~ "Fields"

      label_class =
        d
        |> LazyHTML.query("#history-filter-form-stop label span")
        |> LazyHTML.attribute("class")
        |> List.first()

      refute label_class =~ "sr-only"
    end

    test "filter options carry their matching change counts" do
      entries = [
        entry(id: "log-1", changed_fields: %{"stop_lat" => %{"from" => 1.0, "to" => 2.0}})
      ]

      html = render_history(entries: entries)

      assert html =~ "All fields (1)"
      assert html =~ "Position only (1)"
      assert html =~ "Accessibility only (0)"
    end

    test "counts render through the shared display-mode count strip" do
      entries = [
        entry(
          id: "log-1",
          changed_fields: %{
            "stop_lat" => %{"from" => 1.0, "to" => 2.0},
            "stop_name" => %{"from" => "A", "to" => "B"}
          }
        )
      ]

      html = render_history(entries: entries)
      d = doc(html)

      strip = LazyHTML.query(d, "#history-counts-stop")
      assert LazyHTML.attribute(strip, "data-role") == ["count-strip"]
      assert LazyHTML.attribute(strip, "data-mode") == ["display"]
      # Display mode owns no buttons, so there is no zero-count click surface here.
      assert Enum.empty?(LazyHTML.query(d, "#history-counts-stop button"))

      entries_value =
        d
        |> LazyHTML.query("#history-counts-stop-item-entries [data-role=\"count-strip-value\"]")
        |> LazyHTML.text()

      changes_value =
        d
        |> LazyHTML.query("#history-counts-stop-item-changes [data-role=\"count-strip-value\"]")
        |> LazyHTML.text()

      assert entries_value == "1"
      assert changes_value == "2"
    end

    test "counts follow the active filter" do
      entries = [
        entry(
          id: "log-1",
          changed_fields: %{
            "stop_lat" => %{"from" => 1.0, "to" => 2.0},
            "stop_name" => %{"from" => "A", "to" => "B"}
          }
        )
      ]

      html = render_history(entries: entries, history_field_filter: "position")

      changes_value =
        html
        |> doc()
        |> LazyHTML.query("#history-counts-stop-item-changes [data-role=\"count-strip-value\"]")
        |> LazyHTML.text()

      assert changes_value == "1"
    end

    test "a filter matching nothing renders one Clear filter region and no per-card no-match text" do
      entries = [
        entry(id: "log-1", changed_fields: %{"stop_name" => %{"from" => "A", "to" => "B"}}),
        entry(id: "log-2", changed_fields: %{"stop_desc" => %{"from" => "A", "to" => "B"}})
      ]

      html = render_history(entries: entries, history_field_filter: "position")
      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#history-filtered-empty-stop")) == 1
      assert Enum.empty?(LazyHTML.query(d, "#history-empty-stop"))
      assert Enum.empty?(LazyHTML.query(d, "[data-testid=\"history-entry-no-match\"]"))
      refute html =~ "No matching changes"

      clear = LazyHTML.query(d, "#history-clear-filter-stop")
      assert Enum.count(clear) == 1
      assert LazyHTML.attribute(clear, "phx-click") == ["clear_history_filter"]
      assert LazyHTML.text(clear) =~ "Clear filter"
      assert LazyHTML.attribute(LazyHTML.query(d, "#history-stop"), "data-state") == ["filtered"]
    end

    test "nonmatching entries are hidden while matching entries remain" do
      entries = [
        entry(id: "log-1", changed_fields: %{"stop_lat" => %{"from" => 1.0, "to" => 2.0}}),
        entry(id: "log-2", changed_fields: %{"stop_desc" => %{"from" => "A", "to" => "B"}})
      ]

      html = render_history(entries: entries, history_field_filter: "position")
      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#history-entry-log-1")) == 1
      assert Enum.empty?(LazyHTML.query(d, "#history-entry-log-2"))
      assert Enum.empty?(LazyHTML.query(d, "#history-filtered-empty-stop"))
    end
  end

  describe "change_log_list/1 agency-local time" do
    test "groups across the agency date boundary rather than the UTC one" do
      # Both instants share one UTC date but straddle midnight in New York.
      entries = [
        entry(id: "log-late", inserted_at: ~U[2026-04-26 20:00:00Z]),
        entry(id: "log-early", inserted_at: ~U[2026-04-26 02:00:00Z])
      ]

      html = render_history(entries: entries, today: ~D[2026-04-26], now: ~N[2026-04-26 16:05:00])
      d = doc(html)

      headers =
        d
        |> LazyHTML.query("[data-testid=\"history-date-header\"] time")
        |> LazyHTML.attribute("datetime")

      assert headers == ["2026-04-26", "2026-04-25"]
    end

    test "times render unpadded 12-hour with uppercase AM/PM" do
      entries = [entry(id: "log-1", inserted_at: ~U[2026-04-26 13:05:00Z])]

      html = render_history(entries: entries)

      # 13:05 UTC is 9:05 AM in New York.
      assert html =~ "9:05 AM"
      refute html =~ "09:05"
      refute html =~ "9:05 am"
    end

    test "a valid agency zone is named once and raises no UTC fallback disclosure" do
      entries = [entry(id: "log-1")]
      html = render_history(entries: entries)
      d = doc(html)

      assert Enum.empty?(LazyHTML.query(d, "#history-utc-fallback-stop"))
      assert Enum.count(LazyHTML.query(d, "#history-timezone-stop")) == 1
      assert html =~ "America/New_York"
    end

    test "a UTC fallback is disclosed exactly once at panel level with its reason" do
      entries = [
        entry(id: "log-1", inserted_at: ~U[2026-04-26 13:05:00Z]),
        entry(id: "log-2", inserted_at: ~U[2026-04-25 13:05:00Z])
      ]

      html = render_history(entries: entries, zone: @utc_fallback)
      d = doc(html)

      assert Enum.count(LazyHTML.query(d, "#history-utc-fallback-stop")) == 1
      assert html =~ "UTC"
      assert html =~ "more than one time zone"
      # Exactly one zone statement: the plain note yields to the disclosure.
      assert Enum.empty?(LazyHTML.query(d, "#history-timezone-stop"))
    end
  end

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
    test "renders today's local time without separator, unpadded and uppercase" do
      assert ChangeHistoryComponents.__test_format_time_short__(
               ~N[2026-04-26 09:05:00],
               ~D[2026-04-26]
             ) == "9:05 AM"
    end

    test "renders other-day time with month/day separator" do
      assert ChangeHistoryComponents.__test_format_time_short__(
               ~N[2026-04-25 21:00:00],
               ~D[2026-04-26]
             ) == "Apr 25 · 9:00 PM"
    end
  end

  describe "group_entries_by_local_date/2" do
    test "groups by the supplied local date and sorts descending" do
      entries = [
        %{id: 1, inserted_at: ~U[2026-04-24 10:00:00Z]},
        %{id: 2, inserted_at: ~U[2026-04-26 10:00:00Z]},
        %{id: 3, inserted_at: ~U[2026-04-25 10:00:00Z]},
        %{id: 4, inserted_at: ~U[2026-04-26 10:00:00Z]}
      ]

      local_times = %{
        1 => ~N[2026-04-24 06:00:00],
        2 => ~N[2026-04-26 06:00:00],
        3 => ~N[2026-04-25 06:00:00],
        4 => ~N[2026-04-26 06:00:00]
      }

      grouped =
        ChangeHistoryComponents.__test_group_entries_by_date__(entries, local_times)

      dates = Enum.map(grouped, fn {date, _} -> date end)

      assert dates == [~D[2026-04-26], ~D[2026-04-25], ~D[2026-04-24]]
    end

    test "an instant whose local date differs from its UTC date groups locally" do
      entries = [%{id: 1, inserted_at: ~U[2026-04-26 02:00:00Z]}]
      local_times = %{1 => ~N[2026-04-25 22:00:00]}

      assert [{~D[2026-04-25], _}] =
               ChangeHistoryComponents.__test_group_entries_by_date__(entries, local_times)
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
      now = ~N[2026-04-26 10:00:00]
      assert ChangeHistoryComponents.__test_relative_time__(now, now) =~ "just now"
    end

    test "minutes ago" do
      now = ~N[2026-04-26 10:00:00]
      five_min_ago = NaiveDateTime.add(now, -5 * 60, :second)

      assert ChangeHistoryComponents.__test_relative_time__(five_min_ago, now) ==
               "5 minutes ago"
    end

    test "yesterday for one-day-ago" do
      now = ~N[2026-04-26 10:00:00]
      one_day_ago = NaiveDateTime.add(now, -86_400, :second)

      assert ChangeHistoryComponents.__test_relative_time__(one_day_ago, now) == "yesterday"
    end
  end
end

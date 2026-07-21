defmodule GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Live.Gtfs.ChangeHistoryComponents

  @agency_zone %{timezone: "America/New_York", fallback?: false, fallback_reason: nil}
  @utc_fallback %{timezone: "UTC", fallback?: true, fallback_reason: :conflicting}

  defp filter_form(key), do: Phoenix.Component.to_form(%{"key" => key})

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

  defp text_of(d, selector),
    do: d |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp texts_of(d, selector),
    do: d |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

  defp attrs_of(d, selector, name),
    do: d |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

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

    d = doc(html)

    assert attrs_of(d, "#stop-tabs", "role") == ["tablist"]
    assert attrs_of(d, "#stop-tabs", "phx-hook") == ["TablistHook"]

    # Both tabs exist, each controls its own panel, and exactly one of them is
    # the roving tab stop while Details is selected.
    assert attrs_of(d, "#stop-tabs [role='tab']", "id") ==
             ["stop-tab-details", "stop-tab-history"]

    assert attrs_of(d, "#stop-tabs [role='tab']", "aria-controls") ==
             ["stop-panel-details", "stop-panel-history"]

    assert attrs_of(d, "#stop-tabs [role='tab']", "aria-selected") == ["true", "false"]
    assert attrs_of(d, "#stop-tabs [role='tab']", "tabindex") == ["0", "-1"]
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

  # A coded GTFS value must reach the audit row as the word an operator reads.
  # The rendered outcome is the contract; the mapper carries no colour token,
  # so nothing here names a utility class.
  describe "coded values render as words" do
    test "wheelchair boarding codes render their accessibility words" do
      for {code, word} <- [
            {0, "No information"},
            {1, "Wheelchair accessible"},
            {2, "Not accessible"}
          ] do
        entries = [
          entry(
            id: "log-1",
            changed_fields: %{"wheelchair_boarding" => %{"from" => nil, "to" => code}}
          )
        ]

        d = doc(render_history(entries: entries))

        assert text_of(d, ~s(#history-diff-log-1 [data-role="version-diff-after"])) == word
      end
    end

    test "an undocumented wheelchair boarding code renders what is stored" do
      entries = [
        entry(
          id: "log-1",
          changed_fields: %{"wheelchair_boarding" => %{"from" => nil, "to" => 9}}
        )
      ]

      d = doc(render_history(entries: entries))

      assert text_of(d, ~s(#history-diff-log-1 [data-role="version-diff-after"])) == "9"
    end

    test "a non-categorical field passes its stored value through untranslated" do
      assert ChangeHistoryComponents.__test_categorical_label__({"stop", "stop_name"}, "x") ==
               :passthrough
    end

    test "pathway bidirectionality renders as a direction word" do
      for {stored, word} <- [{true, "Bidirectional"}, {false, "One-way"}] do
        entries = [
          entry(
            id: "log-1",
            changed_fields: %{"is_bidirectional" => %{"from" => nil, "to" => stored}}
          )
        ]

        d = doc(render_history(entries: entries, entity_type: "pathway"))

        assert text_of(d, ~s(#history-diff-log-1 [data-role="version-diff-after"])) == word
      end
    end

    test "stop location_type uses Stop.location_type_label/1" do
      assert ChangeHistoryComponents.__test_categorical_label__({"stop", "location_type"}, 1) ==
               "Station"
    end

    test "pathway pathway_mode uses Pathway.mode_label/1" do
      assert ChangeHistoryComponents.__test_categorical_label__({"pathway", "pathway_mode"}, 5) ==
               "Elevator"
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

  describe "history entries consume the shared version-diff row" do
    test "there is no local diff renderer left in this module" do
      refute function_exported?(ChangeHistoryComponents, :change_diff, 1)
    end

    test "each entry renders exactly one shared row carrying its action and status" do
      entries = [entry(id: "log-1", action: "updated", entity_external_id: "ALEWIFE-1")]
      d = doc(render_history(entries: entries))

      row = LazyHTML.query(d, "#history-diff-log-1")

      assert LazyHTML.attribute(row, "data-role") == ["version-diff-row"]
      assert LazyHTML.attribute(row, "data-action") == ["modify"]
      assert LazyHTML.attribute(row, "data-status") == ["applied"]
      assert Enum.count(LazyHTML.query(d, "[data-role=\"version-diff-row\"]")) == 1
    end

    test "the entry states the GTFS natural key beside the human entity name" do
      entries = [entry(id: "log-1", entity_external_id: "ALEWIFE-1")]
      d = doc(render_history(entries: entries))

      assert text_of(d, "#history-diff-log-1 [data-role=\"version-diff-entity\"]") == "Stop"
      assert text_of(d, "#history-diff-log-1 [data-role=\"version-diff-key\"]") == "ALEWIFE-1"
    end

    test "a created entry maps to the add action and a deleted entry to remove" do
      created = entry(id: "log-1", action: "created", changed_fields: %{})
      d = doc(render_history(entries: [created]))

      assert LazyHTML.attribute(LazyHTML.query(d, "#history-diff-log-1"), "data-action") == [
               "add"
             ]

      deleted = entry(id: "log-2", action: "deleted")
      d = doc(render_history(entries: [deleted]))

      assert LazyHTML.attribute(LazyHTML.query(d, "#history-diff-log-2"), "data-action") ==
               ["remove"]
    end

    test "a reverted entry carries the rejected status" do
      original = entry(id: "log-1")
      rollback = entry(id: "log-2", action: "rolled_back", rolled_back_to_log_id: "log-1")
      d = doc(render_history(entries: [rollback, original]))

      assert LazyHTML.attribute(LazyHTML.query(d, "#history-diff-log-1"), "data-status") ==
               ["rejected"]
    end

    test "field rows carry a human label and the raw GTFS key as secondary metadata" do
      entries = [
        entry(
          id: "log-1",
          changed_fields: %{"stop_name" => %{"from" => "Old", "to" => "New"}}
        )
      ]

      d = doc(render_history(entries: entries))

      assert text_of(d, "#history-diff-log-1 [data-role=\"version-diff-change-label\"]") ==
               "Stop name"

      assert text_of(d, "#history-diff-log-1 [data-role=\"version-diff-change-key\"]") ==
               "stop_name"
    end

    test "a 61 character value renders complete, with no truncation marker" do
      long = String.duplicate("Kendall-MIT-Northbound-Platform.", 4)
      assert String.length(long) > 60

      entries = [
        entry(id: "log-1", changed_fields: %{"stop_name" => %{"from" => "A", "to" => long}})
      ]

      html = render_history(entries: entries)

      d = doc(html)

      assert text_of(d, ~s(#history-diff-log-1 [data-role="version-diff-after"])) == long

      refute d
             |> LazyHTML.query("#history-diff-log-1")
             |> LazyHTML.text()
             |> String.contains?("…"),
             "the diff row still renders a truncation marker"
    end

    test "false, zero and nil render as those exact values" do
      entries = [
        entry(
          id: "log-1",
          changed_fields: %{
            "custom_flag" => %{"from" => true, "to" => false},
            "min_width" => %{"from" => 1.5, "to" => nil},
            "stair_count" => %{"from" => 12, "to" => 0}
          }
        )
      ]

      d = doc(render_history(entries: entries, entity_type: "pathway"))

      assert texts_of(d, "#history-diff-log-1 [data-role=\"version-diff-after\"]") ==
               ["false", "nil", "0"]

      assert texts_of(d, "#history-diff-log-1 [data-role=\"version-diff-before\"]") ==
               ["true", "1.5", "12"]

      assert attrs_of(
               d,
               "#history-diff-log-1 [data-role=\"version-diff-after\"]",
               "data-value-kind"
             ) ==
               ["boolean", "nil", "number"]
    end

    test "a categorical GTFS code still reads as its documented meaning" do
      entries = [
        entry(
          id: "log-1",
          changed_fields: %{"is_bidirectional" => %{"from" => true, "to" => false}}
        )
      ]

      d = doc(render_history(entries: entries, entity_type: "pathway"))

      assert text_of(d, "#history-diff-log-1 [data-role=\"version-diff-before\"]") ==
               "Bidirectional"

      assert text_of(d, "#history-diff-log-1 [data-role=\"version-diff-after\"]") == "One-way"
    end

    test "a change side the record never captured is not shown as nil" do
      entries = [entry(id: "log-1", changed_fields: %{"stop_name" => %{"to" => "New"}})]
      d = doc(render_history(entries: entries))

      assert text_of(d, "#history-diff-log-1 [data-role=\"version-diff-before\"]") ==
               "Not recorded"

      assert LazyHTML.attribute(
               LazyHTML.query(d, "#history-diff-log-1 [data-role=\"version-diff-before\"]"),
               "data-value-kind"
             ) == ["absent"]
    end

    test "an unknown categorical code is shown as stored rather than as Unknown" do
      entries = [
        entry(id: "log-1", changed_fields: %{"location_type" => %{"from" => 1, "to" => nil}})
      ]

      d = doc(render_history(entries: entries))

      assert texts_of(d, "#history-diff-log-1 [data-role=\"version-diff-before\"]") == ["Station"]
      assert texts_of(d, "#history-diff-log-1 [data-role=\"version-diff-after\"]") == ["nil"]
    end

    test "the active field filter still decides which change rows render" do
      entries = [
        entry(
          id: "log-1",
          changed_fields: %{
            "stop_name" => %{"from" => "A", "to" => "B"},
            "stop_lat" => %{"from" => 1.0, "to" => 2.0}
          }
        )
      ]

      d = doc(render_history(entries: entries, history_field_filter: "position"))

      assert LazyHTML.attribute(
               LazyHTML.query(d, "#history-diff-log-1 [data-role=\"version-diff-change\"]"),
               "data-change-key"
             ) == ["stop_lat"]
    end

    test "history actions are passed through the shared row's action slot" do
      entries = [entry(id: "log-1")]
      d = doc(render_history(entries: entries))

      action =
        LazyHTML.query(
          d,
          "#history-diff-log-1 [data-role=\"version-diff-actions\"] #history-entry-action-log-1"
        )

      assert LazyHTML.attribute(action, "phx-click") == ["preview_rollback_change_log"]
      assert LazyHTML.attribute(action, "phx-value-log-id") == ["log-1"]
      assert LazyHTML.attribute(action, "data-history-entry-action") == ["undo"]
    end

    # The server pushes focus to the panel and to the replacement entry after a
    # rollback. Both must be programmatically focusable or the push is a no-op
    # and focus silently falls to <body>.
    test "the panel and every entry are programmatic focus destinations" do
      entries = [entry(id: "log-1")]
      d = doc(render_history(entries: entries))

      assert attrs_of(d, "#history-stop", "tabindex") == ["-1"]
      assert attrs_of(d, "#history-stop", "phx-hook") == ["FormErrorFocus"]
      assert attrs_of(d, "#history-entry-log-1", "tabindex") == ["-1"]

      [panel_class] = attrs_of(d, "#history-stop", "class")
      assert panel_class =~ "focus-visible:ring"
    end

    test "an unavailable original-version restore states a visible reason" do
      entries = [entry(id: "log-1", action: "created", changed_fields: %{})]
      d = doc(render_history(entries: entries))

      action = LazyHTML.query(d, "#history-entry-action-log-1")
      assert LazyHTML.attribute(action, "aria-disabled") == ["true"]

      assert LazyHTML.attribute(action, "aria-describedby") == ["history-entry-unavailable-log-1"]

      reason = text_of(d, "#history-entry-unavailable-log-1")
      assert reason =~ "No earlier version exists"
      assert reason =~ "stop was created"
    end
  end

  describe "rollback_preview/1" do
    defp preview(overrides) do
      Map.merge(
        %{
          log: %{id: "log-1", entity_external_id: "ALEWIFE-1"},
          entity_type: "stop",
          entity_id: "stop-1",
          entity_name: "Alewife Northbound",
          field_changes: [%{field: "stop_name", current: "New", restored: "Old"}]
        },
        Map.new(overrides)
      )
    end

    defp render_preview(overrides \\ []) do
      render_component(&ChangeHistoryComponents.rollback_preview/1,
        rollback_preview: preview(overrides),
        entity_type: Keyword.get(overrides, :entity_type, "stop")
      )
    end

    test "names the entity and states the consequence before the action" do
      d = doc(render_preview())

      assert text_of(d, "#rollback-preview-heading-stop") == "Revert stop Alewife Northbound?"

      consequence = text_of(d, "#rollback-preview-consequence-stop")
      assert consequence =~ "restores 1 field on this stop"
      assert consequence =~ "re-apply this change to the stop afterwards"
    end

    test "pluralizes the consequence by the number of restored fields" do
      d =
        doc(
          render_preview(
            field_changes: [
              %{field: "stop_name", current: "New", restored: "Old"},
              %{field: "stop_lat", current: 2.0, restored: 1.0}
            ]
          )
        )

      assert text_of(d, "#rollback-preview-consequence-stop") =~ "restores 2 fields on this stop"
    end

    test "renders its evidence through the shared version-diff row in preview status" do
      d = doc(render_preview())

      row = LazyHTML.query(d, "#rollback-preview-diff-stop")
      assert LazyHTML.attribute(row, "data-role") == ["version-diff-row"]
      assert LazyHTML.attribute(row, "data-status") == ["preview"]
      assert LazyHTML.attribute(row, "data-action") == ["modify"]

      assert text_of(d, "#rollback-preview-diff-stop [data-role=\"version-diff-key\"]") ==
               "ALEWIFE-1"
    end

    test "offers one dominant verb+noun action beside a subdued cancel" do
      d = doc(render_preview())

      confirm = LazyHTML.query(d, "#rollback-preview-confirm-stop")
      assert LazyHTML.text(confirm) |> String.trim() == "Revert stop"
      assert LazyHTML.attribute(confirm, "phx-click") == ["confirm_rollback_change_log"]
      assert LazyHTML.attribute(confirm, "phx-value-log-id") == ["log-1"]

      [confirm_class] = LazyHTML.attribute(confirm, "class")
      [cancel_class] = attrs_of(d, "#rollback-preview-cancel-stop", "class")
      assert confirm_class =~ "btn-error"
      assert cancel_class =~ "btn-outline"
    end

    test "prevents a duplicate submission and shows progress while reverting" do
      d = doc(render_preview())

      assert attrs_of(d, "#rollback-preview-confirm-stop", "phx-disable-with") ==
               ["Reverting…"]
    end

    test "takes focus when it opens and returns focus to its opener on cancel" do
      d = doc(render_preview())

      region = LazyHTML.query(d, "#rollback-preview-stop")
      assert LazyHTML.attribute(region, "tabindex") == ["-1"]
      assert [mounted] = LazyHTML.attribute(region, "phx-mounted")
      assert mounted =~ "focus"

      [cancel] = attrs_of(d, "#rollback-preview-cancel-stop", "phx-click")
      assert cancel =~ "cancel_rollback_preview"
      assert cancel =~ "history-entry-action-log-1"
    end

    test "renders complete values with no truncation" do
      long = String.duplicate("b", 61)

      d =
        doc(
          render_preview(field_changes: [%{field: "stop_desc", current: long, restored: "Old"}])
        )

      assert text_of(d, "#rollback-preview-diff-stop [data-role=\"version-diff-before\"]") == long
    end

    test "falls back to the log's natural key when the caller supplies no entity name" do
      d = doc(render_preview(entity_name: nil))

      assert text_of(d, "#rollback-preview-heading-stop") == "Revert stop ALEWIFE-1?"
    end
  end

  describe "history and rollback preview agree on the same change" do
    test "the same field renders the same label, key and values in both places" do
      long = String.duplicate("Davis-Square-Upper-Busway.", 3)

      entries = [
        entry(
          id: "log-1",
          entity_external_id: "DAVIS-1",
          changed_fields: %{"stop_name" => %{"from" => long, "to" => "Davis"}}
        )
      ]

      history = doc(render_history(entries: entries))

      preview =
        doc(
          render_component(&ChangeHistoryComponents.rollback_preview/1,
            entity_type: "stop",
            rollback_preview: %{
              log: %{id: "log-1", entity_external_id: "DAVIS-1"},
              entity_type: "stop",
              entity_id: "stop-1",
              entity_name: "Davis",
              field_changes: [%{field: "stop_name", current: "Davis", restored: long}]
            }
          )
        )

      assert text_of(history, "#history-diff-log-1 [data-role=\"version-diff-change-label\"]") ==
               text_of(
                 preview,
                 "#rollback-preview-diff-stop [data-role=\"version-diff-change-label\"]"
               )

      assert text_of(history, "#history-diff-log-1 [data-role=\"version-diff-change-key\"]") ==
               text_of(
                 preview,
                 "#rollback-preview-diff-stop [data-role=\"version-diff-change-key\"]"
               )

      # The history recorded long -> "Davis"; reverting restores "Davis" -> long.
      # The two sides are mirrored, and every rendered value is identical.
      assert text_of(history, "#history-diff-log-1 [data-role=\"version-diff-before\"]") == long

      assert text_of(preview, "#rollback-preview-diff-stop [data-role=\"version-diff-after\"]") ==
               long
    end

    test "zero renders as zero in both places, never as a blank" do
      entries = [
        entry(id: "log-1", changed_fields: %{"wheelchair_boarding" => %{"from" => 1, "to" => 0}})
      ]

      history = doc(render_history(entries: entries))

      preview =
        doc(
          render_component(&ChangeHistoryComponents.rollback_preview/1,
            entity_type: "stop",
            rollback_preview: %{
              log: %{id: "log-1", entity_external_id: "S-1"},
              entity_type: "stop",
              entity_id: "stop-1",
              entity_name: "S",
              field_changes: [%{field: "level_index", current: 0, restored: 3}]
            }
          )
        )

      assert text_of(history, "#history-diff-log-1 [data-role=\"version-diff-after\"]") ==
               "No information"

      assert text_of(preview, "#rollback-preview-diff-stop [data-role=\"version-diff-before\"]") ==
               "0"
    end
  end

  describe "field_label/2" do
    test "maps GTFS keys to sentence-case human labels per entity type" do
      assert ChangeHistoryComponents.__test_field_label__("stop", "stop_name") == "Stop name"

      assert ChangeHistoryComponents.__test_field_label__("stop", "wheelchair_boarding") ==
               "Accessibility"

      assert ChangeHistoryComponents.__test_field_label__("pathway", "is_bidirectional") ==
               "Direction"

      assert ChangeHistoryComponents.__test_field_label__("level", "level_index") == "Level index"
    end

    test "an unmapped key falls back to its humanized form rather than raising" do
      assert ChangeHistoryComponents.__test_field_label__("stop", "some_new_field") ==
               "Some new field"
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

defmodule GtfsPlannerWeb.Gtfs.RoutePatternListComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlannerWeb.Gtfs.RoutePatternListComponents

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp present?(html, selector), do: not Enum.empty?(LazyHTML.query(doc(html), selector))

  defp text(html, selector) do
    doc(html)
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp summary(id, direction_id, overrides \\ %{}) do
    pattern =
      Map.merge(
        %{
          route_pattern_id: id,
          route_pattern_name: "Pattern #{id}",
          route_pattern_time_desc: "All service days",
          route_pattern_typicality: 1,
          direction_id: direction_id,
          headsign: "Lincoln City"
        },
        Map.get(overrides, :pattern, %{})
      )

    %{
      id: id,
      pattern: pattern,
      stop_count: 12,
      trip_count: Map.get(overrides, :trip_count, 4),
      timing_count: 2,
      headsign_differ_count: Map.get(overrides, :headsign_differ_count, 0),
      headsign_typo_count: Map.get(overrides, :headsign_typo_count, 0),
      alignment: Map.get(overrides, :alignment, %{missing: 0, blocked: 0, export: :current})
    }
  end

  defp rows(summaries) do
    summaries
    |> RoutePatternListComponents.stream_items()
    |> Enum.map(&{"patterns-#{&1.id}", &1})
  end

  defp render_page(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          load_state: :ready,
          route: %{
            route_id: "1",
            route_short_name: "1",
            route_long_name: "Coast Highway",
            route_type: 3,
            active: true,
            route_color: "1F5FB0",
            route_text_color: "FFFFFF"
          },
          version: %{id: "version-1", name: "September 2026 service"},
          patterns: rows([summary("P1", 0), summary("P2", 1)]),
          patterns_empty?: false,
          pattern_count: 2,
          route_trip_count: 8,
          pending_trip_count: 0,
          custom_trip_count: 0,
          derivation_error: nil,
          build_state: :idle,
          build_error: nil,
          build_summary: nil,
          stale?: false,
          editable?: true,
          editor_revoked?: false,
          new_path: "/patterns/new",
          compare_path: "/patterns/compare",
          bulk_candidates: [],
          bulk_selected: MapSet.new(),
          bulk_dialog: nil,
          bulk_result: nil,
          bulk_error: nil,
          bulk_pending: false
        },
        overrides
      )

    render_component(&RoutePatternListComponents.page/1, assigns)
  end

  describe "stream_items/1" do
    test "puts one heading before each direction's patterns and counts them" do
      items =
        RoutePatternListComponents.stream_items([
          summary("A", 0),
          summary("B", 0),
          summary("C", 1)
        ])

      assert Enum.map(items, &{&1.kind, &1.id}) == [
               {:direction, "direction-0"},
               {:pattern, "A"},
               {:pattern, "B"},
               {:direction, "direction-1"},
               {:pattern, "C"}
             ]

      assert [%{count: 2, direction_id: 0}, _, _, %{count: 1, direction_id: 1}, _] = items
    end

    test "gives a pattern without a direction its own group" do
      items = RoutePatternListComponents.stream_items([summary("A", 0), summary("Z", nil)])

      assert [%{kind: :direction, direction_id: 0}, _, %{kind: :direction, direction_id: nil}, _] =
               items
    end

    test "is empty when there are no patterns" do
      assert RoutePatternListComponents.stream_items([]) == []
    end
  end

  describe "page/1 while loading and when unavailable" do
    test "loading shows a busy skeleton with no route header or list" do
      html = render_page(%{load_state: :loading, route: nil})

      assert present?(html, "#patterns-loading[aria-busy='true']")
      assert text(html, "#patterns-loading") =~ "Loading patterns"
      refute present?(html, "#route-workspace")
      refute present?(html, "#patterns-list-container")
    end

    test "unavailable keeps only the way back and a reload" do
      html = render_page(%{load_state: :unavailable, route: nil})

      assert text(html, "#patterns-unavailable") =~ "patterns didn’t load"
      assert present?(html, "#patterns-retry[phx-click='reload_patterns']")
      assert present?(html, "#route-back-to-routes[href='/gtfs/version-1/routes']")
      refute present?(html, "#patterns-list-container")
    end
  end

  describe "page/1 header" do
    test "names the route and marks Patterns as the current tab" do
      html = render_page()

      assert text(html, "#route-title") == "Coast Highway"
      assert text(html, "#route-identifier") =~ "Route ID 1"
      assert present?(html, "#route-tab-patterns[aria-current='page']")
      refute present?(html, "#route-tab-details[aria-current]")
      assert present?(html, "#route-tab-schedules[href='/gtfs/version-1/routes/1/schedules']")
    end
  end

  describe "page/1 create control" do
    test "is the primary while the list is shown" do
      html = render_page()

      assert present?(html, "#patterns-create.btn-primary")
    end

    test "steps back to secondary when trips wait to be grouped" do
      html =
        render_page(%{
          patterns: [],
          patterns_empty?: true,
          pattern_count: 0,
          pending_trip_count: 5
        })

      assert present?(html, "#patterns-create.btn-outline")
      assert present?(html, "#patterns-unlinked #patterns-build")
    end

    test "steps back to secondary when building failed" do
      html =
        render_page(%{
          patterns: [],
          patterns_empty?: true,
          pattern_count: 0,
          derivation_error: "stop_times_out_of_order"
        })

      assert present?(html, "#patterns-create.btn-outline")
      assert present?(html, "#patterns-build-error-retry.btn-primary")
    end

    test "is left to the empty state on first use" do
      html = render_page(%{patterns: [], patterns_empty?: true, pattern_count: 0})

      refute present?(html, "#patterns-create")
      assert present?(html, "#patterns-empty #patterns-create-empty[href='/patterns/new']")
    end

    test "is not offered to someone who cannot edit" do
      html = render_page(%{editable?: false})

      refute present?(html, "#patterns-create")
      assert text(html, "#patterns-readonly-note") =~ "View only"
      refute present?(html, "#patterns-scope-note")
    end
  end

  describe "page/1 states of the list" do
    test "a failed build keeps its reason under technical details" do
      html =
        render_page(%{
          patterns: [],
          patterns_empty?: true,
          pattern_count: 0,
          pending_trip_count: 26,
          derivation_error: "stop_times_out_of_order",
          build_state: :failed,
          build_error: "Building patterns failed (timeout). No trips were changed."
        })

      assert text(html, "#patterns-derivation-error") =~ "26 trips are still not in a pattern"
      assert text(html, "#patterns-build-error") =~ "No trips were changed."
      assert text(html, "#patterns-derivation-error details") =~ "stop_times_out_of_order"
      refute present?(html, "#patterns-unlinked")
      refute present?(html, "#patterns-empty")
    end

    test "editing access removed keeps the rows and takes away every change" do
      html =
        render_page(%{
          editor_revoked?: true,
          bulk_candidates: [%{id: "P1", name: "Pattern P1", missing: 3}]
        })

      assert present?(html, "#pattern-editor-revoked #pattern-editor-reload")
      assert present?(html, "#patterns-P1")
      refute present?(html, "#patterns-create")
      refute present?(html, "#patterns-bulk-generate")
      refute present?(html, "#patterns-readonly-note")
    end

    test "a stale read keeps the rows under a warning with a refresh" do
      html = render_page(%{stale?: true})

      assert present?(html, "#patterns-stale #patterns-stale-reload")
      assert present?(html, "#patterns-P1")
    end

    test "trips outside a pattern get a build offer above the rows" do
      html = render_page(%{pending_trip_count: 6})

      assert text(html, "#patterns-partial") =~ "6 trips are not in a pattern yet"
      assert present?(html, "#patterns-partial #patterns-build-retry.btn-outline")
      assert present?(html, "#patterns-create.btn-primary")
    end

    test "trips that keep imported times are listed by reason, not summarised" do
      html =
        render_page(%{
          patterns: [],
          patterns_empty?: true,
          pattern_count: 0,
          custom_trip_count: 18,
          left_out: [
            %{route_id: "1", reason: "missing_direction", trip_count: 18}
          ]
        })

      assert text(html, "#patterns-left-out") =~ "18 trips aren\u2019t in a pattern"
      assert text(html, "#patterns-left-out-missing_direction") =~ "18 trips have no direction"

      # The card carries the reason and its fix, so the blocked message adds
      # nothing and the first-pattern empty state stays beside it.
      refute present?(html, "#patterns-build-blocked")
      assert present?(html, "#patterns-empty-inline #patterns-create-empty")
    end

    test "a blocked route with nothing outside a pattern says so plainly" do
      html =
        render_page(%{
          patterns: [],
          patterns_empty?: true,
          pattern_count: 0,
          custom_trip_count: 0,
          build_state: :blocked
        })

      assert text(html, "#patterns-build-blocked") =~
               "No trips on this route are waiting to be grouped into patterns."

      refute present?(html, "#patterns-left-out")
      assert present?(html, "#patterns-empty-inline #patterns-create-empty")
    end

    test "the build summary says what was built and what to do next" do
      html = render_page(%{build_summary: %{created: 3, linked: 24, custom: 2}})

      assert text(html, "#patterns-build-summary") =~ "Built 3 patterns from your trips"
      assert text(html, "#patterns-build-summary") =~ "24 trips are now in a pattern"
      assert text(html, "#patterns-build-summary") =~ "2 trips keep the stop times"
      assert text(html, "#patterns-build-summary") =~ "Open each pattern"
    end

    test "linking trips to existing patterns is reported without a build count" do
      html = render_page(%{build_summary: %{created: 0, linked: 6, custom: 0}})

      assert text(html, "#patterns-build-summary") =~ "Added 6 trips to your patterns"
    end
  end

  describe "page/1 headsign column" do
    test "the Headsign header follows Pattern" do
      html = render_page()

      assert text(html, "#patterns-table thead") =~ "Pattern Headsign Use on this route"
    end

    test "a used pattern reads its default and the differ count with the typo warning" do
      html =
        render_page(%{
          patterns:
            rows([
              summary("HS-TYPO", 0, %{headsign_differ_count: 2, headsign_typo_count: 1})
            ]),
          pattern_count: 1
        })

      assert text(html, "#pattern-headsign-HS-TYPO") =~ "Lincoln City"
      assert text(html, "#pattern-headsign-HS-TYPO") =~ "2 trips differ · 1 likely typo"
      assert present?(html, "#pattern-headsign-HS-TYPO .hero-exclamation-triangle")
      assert present?(html, "#pattern-headsign-HS-TYPO .text-warning-fg")
    end

    test "every trip following the default says so without a warning" do
      html =
        render_page(%{
          patterns:
            rows([
              summary("HS-ALL", 0, %{trip_count: 8}),
              summary("HS-DIFFER", 0, %{headsign_differ_count: 3})
            ]),
          pattern_count: 2
        })

      assert text(html, "#pattern-headsign-HS-ALL") =~ "Lincoln City"
      assert text(html, "#pattern-headsign-HS-ALL") =~ "All 8 trips"
      refute present?(html, "#pattern-headsign-HS-ALL .hero-exclamation-triangle")

      assert text(html, "#pattern-headsign-HS-DIFFER") =~ "3 trips differ"
      refute present?(html, "#pattern-headsign-HS-DIFFER .hero-exclamation-triangle")
      refute present?(html, "#pattern-headsign-HS-DIFFER .text-warning-fg")
    end

    test "a pattern without a headsign says so in italic type" do
      html =
        render_page(%{
          patterns:
            rows([
              summary("HS-NONE", 0, %{pattern: %{headsign: nil}})
            ]),
          pattern_count: 1
        })

      assert text(html, "#pattern-headsign-HS-NONE .italic") == "No headsign"
      refute text(html, "#pattern-headsign-HS-NONE") =~ "Lincoln City"
    end

    test "a pattern with no trips shows only its default" do
      html =
        render_page(%{
          patterns: rows([Map.put(summary("HS-EMPTY", 0), :trip_count, 0)])
        })

      assert text(html, "#pattern-headsign-HS-EMPTY") =~ "Lincoln City"
      refute text(html, "#pattern-headsign-HS-EMPTY") =~ "All"
    end
  end

  describe "page/1 rows" do
    test "each row names the pattern and reads its map line" do
      html =
        render_page(%{
          patterns:
            rows([
              summary("P1", 0, %{alignment: %{missing: 3, blocked: 0, export: :none}}),
              summary("P2", 0, %{alignment: nil}),
              summary("P3", 0, %{alignment: %{missing: 0, blocked: 1, export: :none}})
            ]),
          pattern_count: 3
        })

      assert text(html, "#pattern-alignment-status-P1") =~ "3 sections missing"
      assert text(html, "#pattern-alignment-status-P2") =~ "Not saved yet"
      assert text(html, "#pattern-alignment-status-P3") =~ "Blocked"

      assert present?(
               html,
               "#pattern-alignment-P1[phx-click='open_pattern_alignment'][phx-value-pattern-id='P1']"
             )
    end

    test "a pattern without a name is listed by its ID and one without a description says so" do
      html =
        render_page(%{
          patterns:
            rows([
              summary("COAST1-C", 0, %{
                pattern: %{route_pattern_name: nil, route_pattern_time_desc: nil}
              })
            ]),
          pattern_count: 1
        })

      assert text(html, "#pattern-open-COAST1-C") == "COAST1-C"
      assert text(html, "#patterns-COAST1-C") =~ "No service description"
    end

    test "a pattern with no trips says it is not used yet" do
      html =
        render_page(%{patterns: rows([Map.put(summary("P1", 0), :trip_count, 0)])})

      assert text(html, "#patterns-P1 td[data-label='Trips']") =~ "Not used yet"
    end

    test "typicality reads in the operator's words" do
      html =
        render_page(%{
          patterns:
            rows(
              for {id, typicality} <- [
                    {"T0", 0},
                    {"T1", 1},
                    {"T2", 2},
                    {"T3", 3},
                    {"T4", 4},
                    {"T5", 5}
                  ] do
                summary(id, 0, %{pattern: %{route_pattern_typicality: typicality}})
              end
            ),
          pattern_count: 6
        })

      for {id, label} <- [
            {"T0", "Not set"},
            {"T1", "Typical"},
            {"T2", "Deviation"},
            {"T3", "Atypical"},
            {"T4", "Detour"},
            {"T5", "Reference"}
          ] do
        assert text(html, "#patterns-#{id} td[data-label='Use on this route']") =~ label
      end
    end

    test "after a bulk run a row reports what the run found for its pattern" do
      result = %{
        generated: 1,
        total: 2,
        patterns: %{"P1" => %{suggestions: %{1 => []}, failed: %{2 => :no_route}, total: 2}}
      }

      html = render_page(%{bulk_result: result})

      assert text(html, "#pattern-bulk-success-P1") =~ "Review suggestion"
      assert text(html, "#pattern-bulk-failed-P1") =~ "1 to draw by hand"
      assert present?(html, "#pattern-bulk-review-P1[phx-click='review_bulk_suggestions']")
      refute present?(html, "#pattern-alignment-P1")
      assert text(html, "#patterns-bulk-notice") =~ "Suggested paths for 1 of 2 sections"
    end
  end

  describe "page/1 generate missing paths" do
    @candidates [
      %{id: "P1", name: "Pattern P1", missing: 3},
      %{id: "P2", name: "Pattern P2", missing: 2}
    ]

    test "the offer closes the card when a minority of patterns need paths" do
      html =
        render_page(%{
          patterns: rows(for id <- ~w(A B C D), do: summary(id, 0)),
          pattern_count: 4,
          bulk_candidates: [%{id: "A", name: "Pattern A", missing: 3}]
        })

      assert text(html, "#patterns-attention") =~ "1 pattern has 3 sections without a path."
      assert present?(html, "#patterns-attention.border-t")
      assert present?(html, "#patterns-bulk-generate[phx-click='open_bulk']")
    end

    test "the offer leads the card when most patterns need paths" do
      html =
        render_page(%{
          patterns: rows(for id <- ~w(A B C), do: summary(id, 0)),
          pattern_count: 3,
          bulk_candidates: [
            %{id: "A", name: "Pattern A", missing: 3},
            %{id: "B", name: "Pattern B", missing: 5}
          ]
        })

      assert text(html, "#patterns-attention") =~ "2 patterns have 8 sections without a path."
      assert present?(html, "#patterns-attention.border-b")
    end

    test "no offer while paths are being found or after a run" do
      running = render_page(%{bulk_candidates: @candidates, bulk_pending: true})

      finished =
        render_page(%{
          bulk_candidates: @candidates,
          bulk_result: %{generated: 1, total: 1, patterns: %{}}
        })

      refute present?(running, "#patterns-attention")
      assert present?(running, "#patterns-bulk-running #patterns-bulk-cancel")
      refute present?(finished, "#patterns-attention")
    end

    test "the dialog lists each pattern with its sections and checks the selected ones" do
      dialog = %{
        candidates: @candidates,
        total: 3,
        pattern_count: 1,
        pattern_ids: ["P1"],
        too_many?: false
      }

      html =
        render_page(%{
          bulk_candidates: @candidates,
          bulk_selected: MapSet.new(["P1"]),
          bulk_dialog: dialog
        })

      assert present?(html, "#pattern-bulk-select-P1[checked]")
      refute present?(html, "#pattern-bulk-select-P2[checked]")
      assert text(html, "#alignment-bulk-dialog") =~ "3 sections"

      assert text(html, "#alignment-bulk-summary") =~
               "3 sections in 1 pattern will get a suggested path."

      refute present?(html, "#alignment-bulk-dialog-confirm[disabled]")

      assert present?(
               html,
               "#alignment-bulk-dialog[data-initial-focus-id='pattern-bulk-select-P1']"
             )
    end

    test "over the limit the confirm is unavailable and the summary says to choose fewer" do
      dialog = %{
        candidates: [%{id: "P1", name: "Pattern P1", missing: 252}],
        total: 252,
        pattern_count: 1,
        pattern_ids: ["P1"],
        too_many?: true
      }

      html =
        render_page(%{bulk_selected: MapSet.new(["P1"]), bulk_dialog: dialog})

      assert text(html, "#alignment-bulk-summary") =~ "Choose fewer patterns."

      assert text(html, "#alignment-bulk-summary") =~
               "These cover 252 sections, and one run covers at most 200."

      assert present?(html, "#alignment-bulk-dialog-confirm[disabled]")
    end

    test "with nothing chosen the confirm is unavailable" do
      dialog = %{
        candidates: @candidates,
        total: 0,
        pattern_count: 0,
        pattern_ids: [],
        too_many?: false
      }

      html = render_page(%{bulk_dialog: dialog})

      assert text(html, "#alignment-bulk-summary") =~ "Choose at least one pattern."
      assert present?(html, "#alignment-bulk-dialog-confirm[disabled]")
    end

    test "a routing outage says nothing changed and how to go on" do
      html = render_page(%{bulk_error: :routing_unavailable})

      assert text(html, "#patterns-bulk-unavailable") =~ "Street routing is unavailable"
      assert text(html, "#patterns-bulk-unavailable") =~ "nothing was changed"
    end

    test "a refused run names the limit" do
      html = render_page(%{bulk_error: :too_many_sections})

      assert text(html, "#patterns-bulk-too-many") =~ "at most 200 sections"
    end
  end
end

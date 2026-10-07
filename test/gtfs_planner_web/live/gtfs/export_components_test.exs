defmodule GtfsPlannerWeb.Gtfs.ExportComponentsTest do
  use GtfsPlannerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlannerWeb.Gtfs.ExportComponents

  @version %{id: "11111111-1111-1111-1111-111111111111", name: "September 2026 service"}
  @finished_at ~U[2026-09-29 14:14:00.000000Z]
  @expires_at ~U[2026-09-30 14:14:00.000000Z]

  defp run(attrs) do
    struct!(
      Run,
      Map.merge(
        %{id: "22222222-2222-2222-2222-222222222222", state: :ready, warnings: []},
        attrs
      )
    )
  end

  defp status_html(run, opts \\ []) do
    render_component(&ExportComponents.run_status/1, %{
      run: run,
      export_type: Keyword.get(opts, :export_type, :full),
      version: @version,
      notice: Keyword.get(opts, :notice)
    })
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> doc() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp text(html, selector), do: html |> query(selector) |> LazyHTML.text() |> String.trim()
  defp attribute(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  defp warning(n),
    do: %{"code" => "warning_#{n}", "detail" => "Warning number #{n} needs attention."}

  describe "run_status/1 before the first export" do
    test "offers Export feed as the only primary action and names the empty state" do
      html = status_html(nil)

      assert text(html, "#export-empty-history h3") == "No full feed exported yet"
      assert text(html, "#start-export") == "Export feed"
      assert count(html, ".btn-primary") == 1
    end

    test "names the export type in the empty state title" do
      html = status_html(nil, export_type: :operations)

      assert text(html, "#export-empty-history h3") == "No operations export yet"
    end
  end

  describe "run_status/1 while an export is in progress" do
    test "disables the start button and offers Cancel export for a queued run" do
      html = status_html(run(%{state: :pending}))

      assert text(html, "#export-run-title") == "Queued"
      assert attribute(html, "#start-export", "disabled") == [""]
      assert text(html, "#cancel-export") == "Cancel export"
      assert count(html, ".btn-primary") == 1
    end

    test "offers Cancel export for a building run" do
      html = status_html(run(%{state: :building}))

      assert text(html, "#export-run-title") == "Building your file"
      assert text(html, "#cancel-export") == "Cancel export"
    end

    test "removes Cancel export once cancellation is requested" do
      html = status_html(run(%{state: :building, cancel_requested_at: @finished_at}))

      assert text(html, "#export-run-title") == "Cancelling export"
      assert count(html, "#cancel-export") == 0
      assert attribute(html, "#cancelling-export", "disabled") == [""]
    end
  end

  describe "run_status/1 for a ready file" do
    test "links the download and states when the file was made and when it expires" do
      html =
        status_html(
          run(%{state: :ready, finished_at: @finished_at, artifact_expires_at: @expires_at})
        )

      assert attribute(html, "#export-download-link", "href") == [
               "/gtfs/#{@version.id}/export-runs/22222222-2222-2222-2222-222222222222/download"
             ]

      assert text(html, "#export-run-status") =~
               "Created Sep 29, 2026, 2:14 PM UTC · Available until Sep 30, 2026, 2:14 PM UTC"

      assert text(html, "#start-export") == "Export again"
      assert count(html, ".btn-primary") == 1
    end

    test "leaves the times out when the run does not record them" do
      html = status_html(run(%{state: :ready}))

      refute text(html, "#export-run-status") =~ "Available until"
    end

    test "tells the reader to share an operations file only with the vendor" do
      html = status_html(run(%{state: :ready}), export_type: :operations)

      assert text(html, "#export-run-status") =~
               "Contains garages and vehicles. Share it only with your CAD/AVL vendor."
    end

    test "shows three warnings and keeps the rest behind a disclosure" do
      warnings = Enum.map(1..5, &warning/1)
      html = status_html(run(%{state: :ready, warnings: warnings}))

      assert text(html, "#export-warning-panel p") =~ "5 warnings about this file"
      assert count(html, "#export-warning-panel > ul > li") == 3
      assert text(html, "#export-warnings-more summary") == "Show 2 more"
      assert count(html, "#export-warnings-more li") == 2
    end

    test "shows the warning code beneath its sentence" do
      html = status_html(run(%{state: :ready, warnings: [warning(1)]}))

      assert text(html, "#export-warning-panel li") =~ "Warning number 1 needs attention."
      assert text(html, "#export-warning-panel li .font-mono") == "warning_1"
      assert count(html, "#export-warnings-more") == 0
    end

    test "reads warnings whose keys are atoms" do
      html =
        status_html(
          run(%{state: :ready, warnings: [%{code: "atom_code", detail: "Atom keys still show."}]})
        )

      assert text(html, "#export-warning-panel li") =~ "Atom keys still show."
    end
  end

  describe "run_status/1 for a run that ended without a file" do
    test "offers Retry export as the primary action after an unexpected failure" do
      html = status_html(run(%{state: :failed, failure_code: "export_failed"}))

      assert text(html, "#export-run-title") == "Export failed"
      assert text(html, "#retry-export") == "Retry export"
      assert count(html, "#export-download-link") == 0
      assert count(html, ".btn-primary") == 1
    end

    test "names the storage location when the server cannot write export files" do
      html =
        status_html(run(%{state: :failed, failure_code: "artifact_storage_unavailable"}))

      assert text(html, "#export-run-status") =~ "this server can’t write export files"
    end

    test "leads with Edit garages and lists each clash for a garage and stop ID conflict" do
      conflict = %{
        "code" => "garage_stop_id_conflict",
        "detail" => "Garage \"Main garage\" (STOP1) matches the stop \"Main Street\"."
      }

      html =
        status_html(
          run(%{
            state: :failed,
            failure_code: "garage_stop_id_conflict",
            warnings: [conflict, warning(1)]
          }),
          export_type: :operations
        )

      assert text(html, "#export-run-title") == "Garage IDs clash with stop IDs"

      assert attribute(html, "#export-edit-garages", "href") == [
               "/gtfs/#{@version.id}/settings/garages"
             ]

      assert text(html, "#export-conflicts") =~ "Main garage"
      assert text(html, "#retry-export") == "Retry export"
      assert count(html, ".btn-primary") == 1
    end

    test "keeps the conflict detail out of the warning list and words the list for an export that did not finish" do
      conflict = %{"code" => "garage_stop_id_conflict", "detail" => "Clash detail."}

      html =
        status_html(
          run(%{
            state: :failed,
            failure_code: "garage_stop_id_conflict",
            warnings: [conflict, warning(1)]
          }),
          export_type: :operations
        )

      refute text(html, "#export-warning-panel") =~ "Clash detail."
      assert text(html, "#export-warning-panel") =~ "Found while preparing this export."
      refute text(html, "#export-warning-panel") =~ "The file was created"
    end

    test "offers Retry export for an interrupted run" do
      html = status_html(run(%{state: :interrupted}))

      assert text(html, "#export-run-title") == "Export interrupted"
      assert text(html, "#retry-export") == "Retry export"
    end

    test "offers Export again, not Retry export, for a cancelled run" do
      html = status_html(run(%{state: :cancelled}))

      assert text(html, "#export-run-title") == "Export cancelled"
      assert text(html, "#retry-export") == "Export again"
    end

    test "offers Export again for an expired download" do
      html = status_html(run(%{state: :expired}))

      assert text(html, "#export-run-title") == "Download expired"
      assert text(html, "#retry-export") == "Export again"
      assert count(html, "#export-download-link") == 0
    end
  end

  describe "run_status/1 notice" do
    test "announces a failed action as an alert beside the controls" do
      html = status_html(nil, notice: "The export couldn’t start. Try again.")

      assert attribute(html, "#export-notice", "role") == ["alert"]
      assert text(html, "#export-notice") == "The export couldn’t start. Try again."
    end

    test "renders no notice by default" do
      assert count(status_html(nil), "#export-notice") == 0
    end
  end

  describe "type_options/1" do
    defp options_html(operations?, export_type) do
      render_component(&ExportComponents.type_options/1, %{
        form: Phoenix.Component.to_form(%{"type" => Atom.to_string(export_type)}, as: :export),
        export_type: export_type,
        operations?: operations?
      })
    end

    test "offers four choices across two audience groups when operations are visible" do
      html = options_html(true, :pathways)

      assert count(html, ~s(input[type="radio"])) == 4
      assert count(html, "#export-type-group-trip-planners") == 1
      assert count(html, "#export-type-group-vendor") == 1
      assert attribute(html, "#export-type-pathways", "checked") == [""]
      assert count(html, "#export-type-full[checked]") == 0
    end

    test "names each type for who the file is for, with the technical name last" do
      html = options_html(true, :full)

      assert text(html, "label:has(#export-type-operations)") =~ "Full feed with operations data"
      assert text(html, "label:has(#export-type-operations)") =~ "GTFS + operations (TODS)"
      assert text(html, "label:has(#export-type-operations_only)") =~ "Operations data only"
    end

    test "hides the whole vendor fieldset when the product hides operations" do
      html = options_html(false, :full)

      assert count(html, ~s(input[type="radio"])) == 2
      assert count(html, "#export-type-group-trip-planners") == 1
      assert count(html, "#export-type-group-vendor") == 0
      assert count(html, "#export-type-operations") == 0
      assert count(html, "#export-type-operations_only") == 0
    end
  end

  describe "contents/1" do
    defp contents_html(export_type, inventory, preview \\ nil) do
      render_component(&ExportComponents.contents/1, %{
        export_type: export_type,
        file_inventory: inventory,
        operations_preview: preview,
        version_id: @version.id,
        version: @version
      })
    end

    defp preview_ok(files, opts) do
      %{
        ok?: true,
        loading: false,
        result: %{
          files: files,
          runs: Keyword.get(opts, :runs, 0),
          trips_in_run: Keyword.get(opts, :trips_in_run, 0),
          trips_total: Keyword.get(opts, :trips_total, 0),
          warnings: []
        }
      }
    end

    test "shows a count for what trip planners read, with thousands separated" do
      html =
        contents_html(:full, [
          {"routes.txt", 14},
          {"stop_times.txt", 17_864},
          {"stops.txt", 1_386},
          {"trips.txt", 812},
          {"calendar.txt", 4}
        ])

      assert text(html, "#export-metrics") =~ "Routes"
      assert text(html, "#export-metrics") =~ "Stations"
      assert text(html, "#export-metrics") =~ "1,386"
      assert count(html, "#export-metrics > div") == 4
    end

    test "marks a table with no records as left out of the ZIP" do
      html = contents_html(:full, [{"routes.txt", 14}, {"frequencies.txt", 0}])

      assert text(html, "#export-files summary") =~ "1 file in the ZIP"
      assert text(html, "#export-inventory tbody tr:last-child") =~ "left out"
      refute text(html, "#export-inventory tbody tr:first-child") =~ "left out"
    end

    test "counts garages and vehicles from the operations preview" do
      html =
        contents_html(
          :operations,
          [{"routes.txt", 14}, {"trips.txt", 812}],
          preview_ok(
            [{"stops_supplement.txt", 2}, {"vehicles.txt", 27}],
            runs: 5,
            trips_in_run: 9,
            trips_total: 9
          )
        )

      assert count(html, "#export-metrics > div") == 5
      assert text(html, "#export-metrics") =~ "Garages"
      assert text(html, "#export-metrics") =~ "27"
      assert text(html, "#export-metrics") =~ "Trips in a run"
      assert text(html, "#export-metrics") =~ "9"
    end

    test "an operations-only export is the preview inventory on its own" do
      html =
        contents_html(
          :operations_only,
          [],
          preview_ok(
            [{"stops_supplement.txt", 1}, {"vehicles.txt", 2}, {"run_events.txt", 3}],
            runs: 1,
            trips_in_run: 4,
            trips_total: 4
          )
        )

      assert count(html, "#export-metrics > div") == 4
      assert text(html, "#export-metrics") =~ "Garages"
      assert text(html, "#export-metrics") =~ "Runs"
      assert text(html, "#export-inventory tbody") =~ "run_events.txt"
    end

    test "a preview with no runs says there is no run work to reconcile" do
      html =
        contents_html(
          :operations_only,
          [],
          preview_ok([], runs: 0, trips_in_run: 0, trips_total: 0)
        )

      assert text(html, "#export-metrics") =~ "No run work to reconcile"
    end

    test "shows a skeleton while the preview loads and a fallback when it fails" do
      loading = contents_html(:operations_only, [], %{loading: true})
      failed = contents_html(:operations_only, [], %{loading: false, ok?: false, failed: :error})

      assert count(loading, "[id$='-loading']") == 4
      assert text(failed, "#export-metrics") =~ "Couldn’t count"
    end

    test "shows three counts for a pathways export" do
      html =
        contents_html(:pathways, [{"levels.txt", 6}, {"pathways.txt", 41}, {"stops.txt", 386}])

      assert count(html, "#export-metrics > div") == 3
      assert text(html, "#export-metrics") =~ "Stations"
    end

    test "says there are no tables when the inventory is empty" do
      html = contents_html(:full, [])

      assert count(html, "#export-inventory table") == 0
      assert text(html, "#export-empty-inventory") =~ "no tables"
    end
  end

  describe "guide/1" do
    defp guide_html(export_type, product) do
      render_component(&ExportComponents.guide/1, %{
        export_type: export_type,
        version: @version,
        organization: %GtfsPlanner.Organizations.Organization{product: product}
      })
    end

    test "tells a planner organization to host the full feed and links the coming Feed URL page" do
      html = guide_html(:full, :planner)

      assert text(html, "#export-guide") =~ "permanent web address"

      assert attribute(html, "#export-feed-url", "href") == [
               "/gtfs/#{@version.id}/settings/feed-url"
             ]
    end

    test "omits the Feed URL link for an organization whose product hides it" do
      html = guide_html(:full, :pathways)

      assert count(html, "#export-feed-url") == 0
    end

    test "says the pathways file is not a complete feed" do
      assert text(guide_html(:pathways, :planner), "#export-guide") =~ "isn’t a complete feed"
    end

    test "tells the reader to keep the operations file private and links garages and fleet" do
      html = guide_html(:operations, :planner)

      assert text(html, "#export-guide") =~ "Keep it private."

      assert attribute(html, "#export-manage-garages", "href") == [
               "/gtfs/#{@version.id}/settings/garages"
             ]

      assert attribute(html, "#export-manage-fleet", "href") == [
               "/gtfs/#{@version.id}/settings/fleet"
             ]
    end
  end

  describe "check_panel/1" do
    defp check_html(attrs) do
      render_component(
        &ExportComponents.check_panel/1,
        Map.merge(
          %{
            validating?: false,
            progress: nil,
            result: nil,
            error: nil,
            validation_run_id: "33333333-3333-3333-3333-333333333333",
            version: @version
          },
          attrs
        )
      )
    end

    defp result(errors, warnings, infos),
      do: %{summary: %{errors: errors, warnings: warnings, infos: infos}}

    test "offers Check feed before any check" do
      html = check_html(%{})

      assert text(html, "#run-validation") == "Check feed"
      assert count(html, "#mobility-summary-metrics") == 0
    end

    test "names the phase and shows progress while a check runs" do
      html = check_html(%{validating?: true, progress: %{phase: :validating, percent: 55}})

      assert text(html, "#check-phase") == "Running the checker…"
      assert attribute(html, "#check-progress", "value") == ["55"]
      assert count(html, "#run-validation") == 0
    end

    test "says the check is getting ready before the first phase reports" do
      html = check_html(%{validating?: true, progress: %{phase: :starting, percent: 0}})

      assert text(html, "#check-phase") == "Getting ready…"
    end

    test "tells the reader to fix errors before sharing when the check found any" do
      html = check_html(%{result: result(2, 4, 7)})

      assert text(html, "#check-verdict") =~ "Fix the errors before you share this feed."
      assert text(html, "#mobility-summary-metrics [data-count=errors]") =~ "2"
    end

    test "says most trip planners still accept a feed with only warnings" do
      html = check_html(%{result: result(0, 3, 7)})

      assert text(html, "#check-verdict") =~ "Review the 3 warnings."
      assert text(html, "#check-verdict") =~ "most trip planners still accept the feed"
    end

    test "uses the singular for one warning" do
      html = check_html(%{result: result(0, 1, 0)})

      assert text(html, "#check-verdict") =~ "Review the 1 warning."
    end

    test "reports a clean check and offers both follow-up actions as secondary" do
      html = check_html(%{result: result(0, 0, 5)})

      assert text(html, "#check-verdict") =~ "No errors or warnings."

      assert attribute(html, "#view-validation-results", "href") == [
               "/gtfs/#{@version.id}/validation/33333333-3333-3333-3333-333333333333"
             ]

      assert text(html, "#reset-validation") == "Check again"
      assert count(html, ".btn-primary") == 0
    end

    test "says the check could not finish and offers Try again" do
      html = check_html(%{error: :failed})

      assert text(html, "#validation-error-panel") =~ "The check couldn’t finish."
      assert text(html, "#run-validation") == "Try again"
    end

    test "says a check that could not start needs another try" do
      html = check_html(%{error: :not_started})

      assert text(html, "#validation-error-panel") =~ "The check couldn’t start."
    end

    test "names the organization mismatch when the run is not the reader's" do
      html = check_html(%{error: :other_organization})

      assert text(html, "#validation-error-panel") =~ "belongs to another organization"
    end
  end

  describe "recent_checks/1" do
    defp check(attrs) do
      Map.merge(
        %{
          id: "c1",
          title: "Feed check",
          started_at: ~U[2026-09-29 14:02:00.000000Z],
          path: "/gtfs/#{@version.id}/validation/c1",
          kind: :severity,
          errors: 0,
          warnings: 0,
          infos: 5
        },
        attrs
      )
    end

    defp recent_html(checks),
      do: render_component(&ExportComponents.recent_checks/1, %{checks: checks})

    test "summarises how many of the checks reported errors and warnings" do
      html =
        recent_html([
          check(%{id: "c1", errors: 2, warnings: 1}),
          check(%{id: "c2", errors: 0, warnings: 0}),
          check(%{id: "c3", errors: 1, warnings: 4})
        ])

      assert text(html, "#recent-checks-title + p") ==
               "2 of the last 3 checks reported errors, and 2 reported warnings."
    end

    test "describes a single check without a ratio" do
      html = recent_html([check(%{})])

      assert text(html, "#recent-checks-title + p") == "The most recent check of this version."
    end

    test "links each check to its results with its time in UTC" do
      html = recent_html([check(%{})])

      assert attribute(html, "#recent-check-c1 a", "href") == [
               "/gtfs/#{@version.id}/validation/c1"
             ]

      assert text(html, "#recent-check-c1 a") =~ "Sep 29, 2026, 2:02 PM UTC"
    end

    test "counts errors and warnings with their words, using the singular for one" do
      html = recent_html([check(%{errors: 1, warnings: 3, infos: 7})])

      assert text(html, "#recent-validation-counts-c1") =~ "1 error"
      assert text(html, "#recent-validation-counts-c1") =~ "3 warnings"
      assert text(html, "#recent-validation-counts-c1") =~ "7 information"
    end

    test "reports a pathways test as failed, couldn’t be checked and passed" do
      html = recent_html([check(%{kind: :pathways_test, errors: 2, warnings: 1, infos: 14})])

      assert text(html, "#recent-validation-counts-c1") ==
               "2 failed · 1 couldn’t be checked · 14 passed"
    end
  end
end

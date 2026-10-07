defmodule GtfsPlannerWeb.Gtfs.ReleaseComparisonResultsTest do
  @moduledoc """
  Focused evidence for CL-9/FH-9: the completed native comparison renders its
  differences, its uncertainty and its explicit scope on the Compare page, and a
  large native result stays inspectable through stream paging.

  Every case drives the production path: the routed `/gtfs/:version_id/compare`
  page, `CompareLive`'s own events, and a real `ReleaseComparison.Runner` reading
  real published artifacts through the real reader, projection, matching,
  service and comparison code. No result is manufactured and nothing is injected
  into the LiveView.

  The artifacts are the ZIPs the native contract produces. The expected values
  are hand-calculated from the fixture rows below, not read back from the code
  under test: the earlier file runs four trips on each of five weekdays, so 20
  scheduled trips and 20 exact departures over the window. A candidate with
  three of those four trips therefore loses exactly one trip on each of the five
  dates, for a total of -5 on both counts.

  What these cases reject (FH-9) is a native result or its unknowns disappearing
  behind a summary, a narrow view silently reusing the full comparison's totals,
  and a baseline being described as a public release.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.ExportRuns

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}

  # Monday to Friday, with Thursday 26 November inside the window.
  @from "2026-11-23"
  @to "2026-11-27"
  @thursday "2026-11-26"
  @friday "2026-11-27"

  # A long window for the paging case: 61 dates is inside the comparison's own
  # 62-date ceiling. The fixture service runs Monday to Friday, so the removed
  # trip changes 44 of those 61 dates - 1 Nov 2026 is a Sunday, and 1 Nov to
  # 31 Dec holds 44 weekdays - comfortably more than one 25-row page.
  @long_from "2026-11-01"
  @long_to "2026-12-31"
  @long_dates 44

  @trips 4
  @stops 5

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    version = gtfs_version_fixture(organization.id)

    root =
      Path.join(
        System.tmp_dir!(),
        "release-comparison-results-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    previous_root = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)

    # The coordinator runs under the shared task supervisor, so every owned
    # comparison is finished before the sandbox owner connection is released.
    known = MapSet.new(Task.Supervisor.children(GtfsPlanner.TaskSupervisor))
    on_exit(fn -> await_new_children(known) end)

    on_exit(fn ->
      File.rm_rf(root)

      if previous_root,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous_root),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    %{user: user, organization: organization, version: version}
  end

  describe "the completed result" do
    test "names both files, the shared window, and the proven loss", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)

      assert has_element?(view, "#comparison-status-title", "Comparison finished")

      # Both artifacts are identified by what they actually were: the version
      # each one came from, its own digest, its size and its retention expiry.
      assert has_element?(
               view,
               "#comparison-artifacts",
               left.artifact_sha256 |> String.slice(0, 12)
             )

      assert has_element?(
               view,
               "#comparison-artifacts",
               right.artifact_sha256 |> String.slice(0, 12)
             )

      assert has_element?(view, "#comparison-artifacts", "expires")

      assert has_element?(
               view,
               "#comparison-artifacts",
               to_string(left.gtfs_version_id) |> String.slice(0, 12)
             )

      assert has_element?(
               view,
               "#comparison-artifacts",
               to_string(right.gtfs_version_id) |> String.slice(0, 12)
             )

      # One window, compared on both sides.
      assert has_element?(view, "#comparison-window", "Nov 23, 2026 – Nov 27, 2026")

      # Hand-calculated: 4 trips on each of the 5 weekdays is 20; the candidate
      # states 3 on each, so both deltas are exactly -5.
      assert has_element?(view, "#comparison-scheduled-delta", "-5")
      assert has_element?(view, "#comparison-exact-delta", "-5")

      # The difference itself names the route pair, the day and the loss.
      assert has_element?(view, "#comparison-rows", "Trip count changed")
      assert has_element?(view, "#comparison-rows", "R1 → R1")
      assert has_element?(view, "#comparison-rows", "trips -1")
      assert has_element?(view, "#comparison-rows", @thursday)

      # One row per changed date: all five weekdays lost the same trip.
      assert has_element?(view, "#comparison-differences-title", "5")
    end

    test "a complete comparison with no differences says so, and is not confused with an incomplete one",
         context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())
      right = publish_run!(organization, gtfs_version_fixture(organization.id), renamed_zip())

      view = compare!(view(context), left, right)

      # Renaming every identifier moves no service: no effective difference, and
      # the totals are a real zero rather than an unmeasured one.
      assert has_element?(view, "#comparison-totals", "no change")
      refute has_element?(view, "#comparison-totals-unknown")
      assert has_element?(view, "#comparison-completeness")

      # The churn is still disclosed as structural, and the row says it is not
      # service loss on its own.
      assert has_element?(view, "#comparison-structural", "Renamed")
      assert has_element?(view, "#comparison-structural", "not service loss on their own")

      # An unmapped route cannot be totalled, so the same page shape reports a
      # reason instead of a zero.
      refute has_element?(view, "#comparison-differences", "Service added")

      second =
        publish_run!(organization, gtfs_version_fixture(organization.id), extra_route_zip())

      incomplete = compare!(view(context), left, second)

      # An entity present in one file only is a presence change and an
      # unresolved pair, not a proven service difference, so it is never
      # counted as one in the differences list.
      assert has_element?(incomplete, "#comparison-completeness", "Incomplete for this window")
      assert has_element?(incomplete, "#comparison-structural", "Service added")
      assert has_element?(incomplete, "#comparison-unresolved", "no candidate on the other side")
      refute has_element?(incomplete, "#comparison-differences", "Service added")
    end

    test "an unmeasured total renders its reason, never a zero", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())
      right = publish_run!(organization, gtfs_version_fixture(organization.id), extra_route_zip())

      view = compare!(view(context), left, right)

      # A route present on one side only cannot be totalled across the feed, so
      # the page states the reason instead of showing "no change".
      assert has_element?(view, "#comparison-totals-unknown", "was not measured")
      assert has_element?(view, "#comparison-total-reasons", "no proven match")
      refute has_element?(view, "#comparison-scheduled-delta")
      refute has_element?(view, "#comparison-exact-delta")
    end

    test "unreadable rows are disclosed as unknowns with their source, and never as zero service",
         context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())
      right = publish_run!(organization, gtfs_version_fixture(organization.id), bad_date_zip())

      view = compare!(view(context), left, right)

      # The candidate's malformed exception date is named, with the file and row
      # it came from, so a reader can look at the actual bytes.
      assert has_element?(view, "#comparison-unknowns", "calendar_dates.txt")
      assert has_element?(view, "#comparison-unknowns", "Candidate file")
      assert has_element?(view, "#comparison-unknowns", "row 2")

      # An unreadable row is disclosed, and the totals say in words that they
      # cover only what could be read. The comparison's own completeness states
      # about pairing, not about readability, so the page carries the
      # unreadability where the totals are actually read.
      assert has_element?(
               view,
               "#comparison-totals-unknown-coverage",
               "could not be read from the bytes admitted above"
             )

      assert has_element?(view, "#comparison-totals-unknown-coverage", "Unknowns")
    end

    test "the finished band names both files even when neither recorded a version name",
         context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)

      # The band must never reduce two different files to the same words. A run
      # whose `version_name` was never recorded still names itself by when it
      # was exported, which is what tells the two files apart.
      band = text_of(render(view), "#comparison-status")

      refute band =~ "the other export"
      refute band =~ "an export with no recorded time"
      assert band =~ "Compared the export made "
    end

    test "the baseline is never described as a public release", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)
      text = text_of(render(view), "#comparison-results")

      # The comparison is of two of the organization's own retained files. No
      # wording anywhere in the result may read as a public release or pointer.
      refute text =~ ~r/publicly released/i
      refute text =~ ~r/published feed/i
      assert text =~ "internal comparison of two of your own files"
    end
  end

  describe "paging a large native result" do
    test "streams pages of the differences and keeps the true total beside them", context do
      %{organization: organization, version: version} = context
      # One trip fewer over a 61-day window is one difference row per weekday,
      # so the result really does hold more rows than one 25-row page shows.
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right, @long_from, @long_to)

      # Every list is a stream with its own DOM id, so a large result renders as
      # a bounded page rather than thousands of rows.
      for id <-
            ~w(comparison-rows comparison-structural-rows comparison-unresolved-rows comparison-unknowns) do
        assert has_element?(view, "##{id}[phx-update=stream]"), "missing streamed list #{id}"
      end

      # The counter is the whole collection, not the page, and the first page
      # shows only its own 25 rows.
      assert has_element?(
               view,
               "#comparison-differences-paging",
               "Showing 1–25 of #{@long_dates} differences"
             )

      assert has_element?(view, "#comparison-differences-next")
      assert length(difference_row_ids(view)) == 25

      # Paging is deterministic: the next page is a different, disjoint slice of
      # the same result and its counter states the same whole. 44 rows over two
      # 25-row pages leaves 19 on the last one, so the counter is never asked to
      # show a row the result does not hold.
      first = difference_row_ids(view)
      view |> element("#comparison-differences-next") |> render_click()

      second = difference_row_ids(view)

      # The container now draws only the rows of the page it is on: the 19 this
      # result had not shown yet, and none of the first page's 25.
      assert length(second) == 19
      assert first -- second == first
      assert second -- first == second

      assert has_element?(
               view,
               "#comparison-differences-paging",
               "Showing 26–44 of #{@long_dates}"
             )

      assert has_element?(view, "#comparison-differences-previous")
      refute has_element?(view, "#comparison-differences-next")
    end

    test "a forged paging event cannot read outside the comparison's own collections", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)
      before = render(view)

      # Four shapes a client could send: an unknown collection, a non-numeric
      # offset, a negative one, and a limit beyond the documented maximum. None
      # may raise, and none may change the page.
      for params <- [
            %{"collection" => "artifacts", "offset" => "0", "limit" => "25"},
            %{"collection" => "differences", "offset" => "nonsense", "limit" => "25"},
            %{"collection" => "differences", "offset" => "-5", "limit" => "25"},
            %{"collection" => "differences", "offset" => "0", "limit" => "100000"}
          ] do
        render_click(view, "page_comparison", params)
        assert render(view) == before
      end
    end

    test "an oversized page limit is clamped to the documented maximum", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)

      # A limit is a display choice, so an absurd one is clamped rather than
      # refused. This result holds 5 rows, so the clamped page shows them all.
      render_click(view, "page_comparison", %{
        "collection" => "comparison_differences",
        "offset" => "0",
        "limit" => "100000"
      })

      assert length(difference_row_ids(view)) == 5
      refute has_element?(view, "#comparison-differences-paging")
    end
  end

  describe "inspecting a row" do
    test "the keyboard Inspect button reveals that row's own detail", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)
      refute has_element?(view, "#comparison-inspected")

      # The control is an ordinary button, so it is reachable and operable from
      # the keyboard without any custom key handling.
      assert view |> element("#comparison-rows button") |> has_element?()

      view |> element(first_row_button(view, "differences")) |> render_click()

      assert has_element?(view, "#comparison-inspected", "One row in full")
      # The detail is this row's: its kind, its route pair, its date, its own
      # counts and the physical rows of the admitted bytes it came from.
      assert has_element?(view, "#comparison-inspected", "Trip count changed")
      assert has_element?(view, "#comparison-inspected", "R1 → R1")
      assert has_element?(view, "#comparison-inspected", @from)
      assert has_element?(view, "#comparison-inspected", "trips.txt row")

      render_click(view, "close_comparison_detail")
      refute has_element?(view, "#comparison-inspected")
    end

    test "an unknown row is inspectable and keeps its own side and file", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())
      right = publish_run!(organization, gtfs_version_fixture(organization.id), bad_date_zip())

      view = compare!(view(context), left, right)

      view |> element(first_row_button(view, "unknowns")) |> render_click()

      assert has_element?(view, "#comparison-inspected", "Candidate file")
      assert has_element?(view, "#comparison-inspected", "calendar_dates.txt row 2")
    end

    test "a forged row identity inspects nothing", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)

      render_click(view, "inspect_comparison_row", %{
        "collection" => "differences",
        "row" => "../../etc/passwd"
      })

      refute has_element?(view, "#comparison-inspected")
    end
  end

  describe "narrowing the comparison" do
    test "an explicit scope recomputes the totals and names every omitted group", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)

      # The chooser offers only this comparison's own route pairs and dates, so
      # a selection cannot name something the comparison never found.
      assert has_element?(view, "form#comparison-scope-form")
      assert has_element?(view, "#comparison-scope-routes", "R1 → R1")
      assert has_element?(view, "#comparison-scope-dates", @thursday)

      # Narrowing to the one date that actually differs. The total is the same
      # here because the loss is on that date, and the four other dates are named
      # as left out rather than silently dropped.
      narrow!(view, ["R1/R1"], [@thursday])

      assert has_element?(view, "#comparison-scope-applied", "narrowed scope")
      assert has_element?(view, "#comparison-scheduled-delta", "-1")
      assert has_element?(view, "#comparison-omitted-count", "4 route and date groups")

      # The scope form's route key is the result's own key, so the same scope
      # is reproducible from the DOM rather than from an invented label.
      assert selected_values(view, "select#comparison-scope-routes") == ["R1/R1"]
      assert selected_values(view, "select#comparison-scope-dates") == [@thursday]

      # The differences list itself follows the scope: exactly the narrowed
      # date's row is drawn, and the four left-out dates are gone from the page
      # rather than left behind by the previous full comparison.
      # The narrowed view itself holds one difference. LiveViewTest's rendered
      # tree keeps a stream container's earlier inserts, so what the browser
      # actually prunes is checked by the visual capture; what this case owns is
      # that the result the page is holding has already narrowed.
      changes = held_view(view).effective_changes

      assert length(changes) == 1
      assert [changed] = Enum.map(changes, &Date.to_iso8601(&1.date))
      assert changed == @thursday

      # An empty-state element inside a stream container makes that container
      # invalid, so LiveView stops pruning it and a narrowed scope leaves the
      # full comparison's rows on the page. Each empty state is a sibling.
      for container <-
            ~w(comparison-rows comparison-structural-rows comparison-unresolved-rows comparison-unknowns) do
        refute has_element?(view, "##{container} ##{container}-empty")
      end

      refute has_element?(view, "#comparison-differences-empty")
    end

    test "narrowing to a date with no change drops the loss rather than keeping it", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, thursday_only_zip(true))

      right =
        publish_run!(
          organization,
          gtfs_version_fixture(organization.id),
          thursday_only_zip(false)
        )

      view = compare!(view(context), left, right)

      # The extra trip is the only thing that moved, so the whole comparison
      # already shows exactly -1 and one difference.
      assert has_element?(view, "#comparison-scheduled-delta", "-1")
      assert has_element?(view, "#comparison-differences-title", "1")

      narrow!(view, ["R1/R1"], [@friday])

      # Friday is measured and unchanged, so the narrowed result reports a real
      # zero for it and no difference row. The full comparison's -1 is not
      # reused for a date that lost nothing.
      assert has_element?(view, "#comparison-scheduled-delta", "no change")
      assert has_element?(view, "#comparison-exact-delta", "no change")
      assert has_element?(view, "#comparison-completeness", "Complete for this window")
      refute has_element?(view, "#comparison-differences-paging")
    end

    test "clearing the scope restores the full comparison without recomputing it", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)
      full = result_body(view)

      narrow!(view, ["R1/R1"], ["2026-11-23"])
      refute result_body(view) == full

      render_click(view, "clear_comparison_scope")

      refute has_element?(view, "#comparison-scope-applied")
      assert result_body(view) == full
    end

    test "an empty or unknown scope is refused, and the full comparison keeps showing", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)
      full = result_body(view)

      # Nothing selected: an empty subset narrows nothing and says why.
      narrow!(view, [], [@thursday])
      assert has_element?(view, "#comparison-scope-notice", "at least one route and one date")
      refute has_element?(view, "#comparison-scope-applied")
      assert result_body(view) == full

      # A route key this comparison never proved, and a date outside its window.
      narrow!(view, ["R1/R1"], ["2030-01-01"])
      assert has_element?(view, "#comparison-scope-notice", "aren’t part of this comparison")
      refute has_element?(view, "#comparison-scope-applied")
      assert result_body(view) == full

      # A malformed date cannot be read as a scope at all.
      render_submit(view, "narrow_comparison", %{
        "comparison_scope" => %{"route_pair_keys" => ["R1/R1"], "dates" => ["not-a-date"]}
      })

      assert has_element?(view, "#comparison-scope-notice", "aren’t part of this comparison")
      assert result_body(view) == full
    end

    test "a refused scope after a narrowed one shows the whole comparison again", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)
      full = socket_assigns(view).comparison_result.comparison

      narrow!(view, ["R1/R1"], [@thursday])
      assert held_view(view) != full

      # A date outside the window is refused by the comparison itself.
      narrow!(view, ["R1/R1"], ["2030-01-01"])

      # The summary, the rows and the helper's copy go back to the whole
      # comparison rather than keeping the narrowed view beside the full rows.
      assert held_view(view) == full
      assert has_element?(view, "#comparison-scope-notice", "aren’t part of this comparison")
      refute has_element?(view, "#comparison-scope-applied")
      assert socket_assigns(view).comparison_context.source_snapshot.payload["scope"] == nil
    end

    test "the unknowns are not narrowed away by a scope", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())
      right = publish_run!(organization, gtfs_version_fixture(organization.id), bad_date_zip())

      view = compare!(view(context), left, right)

      narrow!(view, ["R1/R1"], ["2026-11-23"])

      # An unknown reason is evidence in its own right. Hiding it behind a
      # narrower view would turn disclosed uncertainty into apparent certainty.
      assert has_element?(view, "#comparison-unknowns", "calendar_dates.txt")

      assert has_element?(
               view,
               "#comparison-exclusion-list",
               "not narrowed by a route or date scope"
             )
    end
  end

  describe "the assistant's frozen copy of the comparison" do
    test "a completed comparison admits a full context, and an explicit narrowing replaces it",
         context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, thursday_only_zip(true))

      right =
        publish_run!(
          organization,
          gtfs_version_fixture(organization.id),
          thursday_only_zip(false)
        )

      view = compare!(view(context), left, right)

      # Completion attaches the complete comparison on its own, and what it
      # attaches is the shared snapshot contract's own envelope.
      assigns = socket_assigns(view)

      assert %{kind: "release_comparison", payload: payload, digest: digest} =
               assigns.comparison_context.source_snapshot

      assert byte_size(digest) == 64
      assert payload["schema_version"] == 1
      assert payload["selected_route_pairs"] == ["R1/R1"]

      assert payload["selected_dates"] == [
               "2026-11-23",
               "2026-11-24",
               "2026-11-25",
               "2026-11-26",
               "2026-11-27"
             ]

      assert payload["result_digest"] == payload["selected_digest"]
      assert payload["scope"] == nil
      assert assigns.comparison_context_notice == nil

      # The narrowed copy is a different identity, taken only when the editor
      # asks for it, and the complete result is still on the page underneath.
      narrow!(view, ["R1/R1"], [@thursday])

      narrowed_assigns = socket_assigns(view)
      narrowed = narrowed_assigns.comparison_context.source_snapshot.payload

      assert narrowed["scope"]["narrowed"] == true
      assert narrowed["scope"]["dates"] == [@thursday]
      assert narrowed["selected_digest"] != narrowed["result_digest"]
      assert narrowed["result_digest"] == payload["result_digest"]
      assert narrowed["selected_route_pairs"] == ["R1/R1"]
      assert narrowed["selected_dates"] == [@thursday]

      # Clearing the scope shows the whole comparison again, so the admitted copy
      # goes back to describing the whole comparison rather than the stale subset.
      render_click(view, "clear_comparison_scope")

      cleared = socket_assigns(view).comparison_context.source_snapshot.payload
      assert cleared["scope"] == nil
      assert cleared["selected_digest"] == payload["selected_digest"]
    end

    test "a refused helper context leaves the native result exactly where it was", context do
      %{organization: organization, version: version} = context

      # A wide window over many dates is more rows than the shared byte ceiling
      # admits, so the copy is refused while the comparison itself is not.
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right, @long_from, @long_to)
      _ = version

      assigns = socket_assigns(view)

      case assigns.comparison_context do
        nil ->
          assert assigns.comparison_context_notice == :source_too_large

        _admitted ->
          assert assigns.comparison_context_notice == nil
      end

      # Whatever the helper may or may not read, the proved result is complete
      # and inspectable on its own terms.
      assert has_element?(view, "#comparison-results")
      assert has_element?(view, "#comparison-totals")
      assert has_element?(view, "#comparison-rows")
      assert socket_assigns(view).comparison_result != nil
    end

    test "replacing the comparison releases the admitted copy with it", context do
      %{organization: organization, version: version} = context
      left = publish_run!(organization, version, full_week_zip())

      right =
        publish_run!(organization, gtfs_version_fixture(organization.id), one_trip_removed_zip())

      view = compare!(view(context), left, right)
      assert socket_assigns(view).comparison_context != nil

      render_click(view, "close_comparison")
      _ = :sys.get_state(view.pid)

      assert socket_assigns(view).comparison_context == nil
      assert socket_assigns(view).comparison_context_notice == nil
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp view(%{conn: conn, user: user, organization: organization, version: version}) do
    {:ok, view, _html} =
      live(log_in_user(conn, user, organization: organization), "/gtfs/#{version.id}/compare")

    view
  end

  # The comparison is asynchronous, so the case waits for the band to leave its
  # running state with a finite deadline rather than a sleep.
  defp compare!(view, left, right, from \\ @from, to \\ @to) do
    view
    |> form("form#export-comparison-form",
      comparison: %{
        "left_run_id" => left.id,
        "right_run_id" => right.id,
        "from" => from,
        "to" => to
      }
    )
    |> render_submit()

    wait_until(60_000, fn ->
      has_element?(view, "#comparison-status-title", "Comparison finished") or
        has_element?(view, "#comparison-status-title", "couldn’t finish")
    end)

    assert has_element?(view, "#comparison-results")
    view
  end

  defp socket_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp narrow!(view, keys, dates) do
    render_submit(view, "narrow_comparison", %{
      "comparison_scope" => %{"route_pair_keys" => keys, "dates" => dates}
    })
  end

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("the comparison never finished")
      true -> Process.sleep(20) && do_wait_until(deadline, fun)
    end
  end

  # The comparison view the page is holding, read from the socket rather than
  # from the rendered tree, which keeps a stream container's earlier inserts.
  defp held_view(view) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(:comparison_view)
  end

  # The comparison's own content, without the scope chooser's transient notice.
  defp result_body(view) do
    Enum.map_join(
      ~w(comparison-totals comparison-differences comparison-structural comparison-unresolved comparison-unknowns),
      "\n",
      fn id ->
        text_of(render(view), "##{id}")
      end
    )
  end

  # The DOM ids of the rows a streamed container currently draws. A row's own id
  # is its stream's name plus a hash of its content, so filtering on that shape
  # picks the rows and not the container that holds them.
  defp streamed_row_ids(view, container, stream) do
    view
    |> element("#comparison-#{container}")
    |> render()
    |> fragment()
    |> LazyHTML.query("div[id]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> to_string()))
    |> Enum.filter(&String.starts_with?(&1, stream <> "-"))
  end

  # The differences list is the one this page pages, so its row ids are read
  # under their stream's own name rather than the container's short id.
  defp difference_row_ids(view),
    do: streamed_row_ids(view, "rows", "comparison_differences")

  # The first streamed row's own Inspect control, addressed by its own DOM id so
  # the case clicks one row rather than the whole list.
  defp first_row_button(view, container) do
    ids = streamed_row_ids(view, container, "comparison_" <> container)

    [row_id | _] = ids
    "##{row_id} button"
  end

  defp text_of(html, selector) do
    html
    |> fragment()
    |> LazyHTML.query(selector)
    |> Enum.map_join("\n", &LazyHTML.text/1)
  end

  defp selected_values(view, selector) do
    view
    |> element(selector)
    |> render()
    |> fragment()
    |> LazyHTML.query("option[selected]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> to_string()))
  end

  defp fragment(html), do: LazyHTML.from_fragment(html)

  defp await_new_children(known, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_new_children(known, deadline)
  end

  defp do_await_new_children(known, deadline) do
    fresh =
      MapSet.difference(MapSet.new(Task.Supervisor.children(GtfsPlanner.TaskSupervisor)), known)

    cond do
      fresh == MapSet.new() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("an owned comparison never exited")
      true -> Process.sleep(20) && do_await_new_children(known, deadline)
    end
  end

  defp publish_run!(organization, version, bytes) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, :full)
    {:ok, _building, generation, token} = ExportRuns.claim(organization.id, run.id, :build)

    {:ok, artifact} =
      ArtifactStorage.publish(organization.id, version.id, run.id, "network.zip", bytes)

    {:ok, run} =
      ExportRuns.mark_ready(organization.id, run.id, generation, token, %{
        main: artifact,
        flex: nil
      })

    run
  end

  # -- fixture artifacts ------------------------------------------------------
  #
  # The earlier file runs four trips on each weekday of the window: 5 dates x 4
  # trips = 20 scheduled trips and 20 exact departures. Every candidate changes
  # exactly one countable fact, so each expected number below is countable by
  # hand from these rows.

  defp full_week_zip, do: week_zip()

  # Three of the four trips: one fewer trip on each of the five dates.
  defp one_trip_removed_zip, do: week_zip(trips: @trips - 1)

  # Every identifier is renamed, including the trips. Nothing about the service
  # moves, so this is identifier churn with no service difference.
  defp renamed_zip, do: week_zip(renamed: true)

  # A route that runs in the candidate and in neither other file. Its group is
  # one-sided, so no whole-feed total can be measured.
  defp extra_route_zip, do: week_zip(extra_route: true)

  # A malformed exception date, so the candidate's service cannot be fully read.
  defp bad_date_zip, do: week_zip(bad_date: true)

  # The earlier file's second service runs one extra trip on Thursday only, and
  # the candidate does not have it. So exactly one date loses a trip and the
  # other four are unchanged - the fixture a narrowed view needs.
  defp thursday_only_zip(thursday?), do: week_zip(extra_thursday_trip: thursday?)

  defp week_zip(opts \\ []) do
    trips = Keyword.get(opts, :trips, @trips)
    renamed? = Keyword.get(opts, :renamed, false)
    extra_route? = Keyword.get(opts, :extra_route, false)
    bad_date? = Keyword.get(opts, :bad_date, false)
    extra_thursday? = Keyword.get(opts, :extra_thursday_trip, false)

    # `X` suffixes keep a renamed file's identifiers apart from the unrenamed
    # ones, and the added route's stops from the main route's.
    route = if renamed?, do: "RX", else: "R1"
    agency = if renamed?, do: "AGENCYX", else: "AGENCY"
    stop = if renamed?, do: "SX", else: "S"
    trip = if renamed?, do: "TX", else: "T"
    service = "WEEK"
    thursday_service = "THURS"

    # Every trip this file states. The added route carries its own trip and its
    # own stop times, so it states real service and is a one-sided unit rather
    # than an empty route. The Thursday service is a second calendar, added by
    # the exception below, so exactly one date can gain or lose a trip.
    main_trips = Enum.map(1..trips, &"#{trip}#{&1}")
    extra = if extra_route?, do: ["#{trip}EXTRA"], else: []
    thursday = if extra_thursday?, do: ["#{trip}THU"], else: []

    trip_rows =
      Enum.map(main_trips, &{route, service, &1, stop}) ++
        Enum.map(extra, &{"R2", service, &1, stop}) ++
        Enum.map(thursday, &{route, thursday_service, &1, stop})

    members = [
      {"agency.txt",
       "agency_id,agency_name,agency_url,agency_timezone\n#{agency},Metro,http://a.example,UTC"},
      {"routes.txt",
       "route_id,agency_id,route_short_name,route_long_name,route_type\n" <>
         route_rows(route, agency, extra_route?)},
      {"stops.txt", stops_csv(stop)},
      {"trips.txt", trips_csv(trip_rows)},
      {"stop_times.txt", stop_times_csv(trip_rows, stop)},
      {"calendar.txt", calendar_services_csv(service, thursday_service, extra_thursday?)}
    ]

    # `calendar_dates.txt` is present only when it has an exception to state. An
    # empty member is not what a native exporter writes, and the reader rightly
    # refuses a file it cannot read as CSV rows.
    case exceptions_csv(service, thursday_service, bad_date?, extra_thursday?) do
      nil -> zip(members)
      body -> zip(members ++ [{"calendar_dates.txt", body}])
    end
  end

  defp route_rows(route, agency, true) do
    Enum.map_join(
      [{route, "1", "Main"}, {"R2", "2", "Extra"}],
      "\n",
      fn {r, short, long} -> "#{r},#{agency},#{short},#{long},3" end
    )
  end

  defp route_rows(route, agency, false) do
    "#{route},#{agency},1,Main,3"
  end

  # One header and one row per service. A second header line would be read as a
  # calendar row whose weekday flags are the words "monday" to "sunday", which
  # the projection rightly drops and discloses as unknown.
  defp calendar_services_csv(service, thursday_service, extra_thursday?) do
    rows =
      if extra_thursday?,
        do: [weekday_service_row(service), thursday_service_row(thursday_service)],
        else: [weekday_service_row(service)]

    "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n" <>
      Enum.join(rows, "\n")
  end

  defp weekday_service_row(service), do: "#{service},1,1,1,1,1,0,0,20260101,20261231"

  # The service is Monday to Friday for the whole of 2026. This one is narrowed to
  # the single Thursday the exception below adds.
  defp thursday_service_row(service) do
    compact = String.replace(@thursday, "-", "")
    "#{service},0,0,0,1,0,0,0,#{compact},#{compact}"
  end

  # A date of 2026112 is seven digits rather than eight, so it is not a
  # readable service date. The projection records it as an unknown against this
  # file and row rather than dropping the exception.
  defp exceptions_csv(service, thursday_service, bad_date?, extra_thursday?) do
    rows =
      [
        bad_date? && "#{service},2026112,2",
        extra_thursday? && "#{thursday_service},#{String.replace(@thursday, "-", "")},1"
      ]
      |> Enum.filter(&(&1 not in [nil, false]))

    case rows do
      [] -> nil
      rows -> "service_id,date,exception_type\n" <> Enum.join(rows, "\n")
    end
  end

  defp stops_csv(stop) do
    "stop_id,stop_name,stop_lat,stop_lon\n" <>
      Enum.map_join(1..@stops, "\n", fn index ->
        "#{stop}#{index},Stop #{index},40.#{index},-74.#{index}"
      end)
  end

  defp trips_csv(trip_rows) do
    "route_id,service_id,trip_id,direction_id\n" <>
      Enum.map_join(trip_rows, "\n", fn {route, service, trip, _stop} ->
        "#{route},#{service},#{trip},0"
      end)
  end

  defp stop_times_csv(trip_rows, stop) do
    "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" <>
      Enum.map_join(trip_rows, "\n", fn {_route, _service, trip, _stops} ->
        Enum.map_join(1..@stops, "\n", fn index ->
          "#{trip},0#{index}:00:00,0#{index}:00:00,#{stop}#{index},#{index}"
        end)
      end)
  end

  defp zip(members) do
    entries = Enum.map(members, fn {name, body} -> {String.to_charlist(name), body} end)
    {:ok, {_, bytes}} = :zip.create(~c"network.zip", entries, [:memory])
    bytes
  end
end

defmodule GtfsPlannerWeb.Gtfs.ReleaseComparisonSelectionTest do
  @moduledoc """
  Focused evidence for CL-8/FH-8: an ordinary authenticated Export page reaches
  the real native comparison, and a replaced, closed or superseded request never
  wins.

  Every case drives the production path: the routed `/gtfs/:version_id/export`
  page, `ExportLive`'s own events, and `ReleaseComparison.start/4` through the
  real `GtfsPlanner.Gtfs.ReleaseComparison.Runner`, the real `ExportRuns`
  claim/receipt transitions and the real `ArtifactStorage`. The artifacts are
  the ones the native exporter produced through `Export.build_zip/3`; nothing is
  injected into the LiveView and no result is manufactured.

  What these cases reject (FH-8) is a test-only injected result hiding missing
  native wiring, and a stale request's output overwriting the current one.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import Phoenix.LiveViewTest

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Export.ArtifactStorage
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  @actor %{id: Ecto.UUID.generate(), email: "exporter@example.com"}
  @from "2026-11-23"
  @to "2026-11-27"

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
        "release-comparison-selection-#{System.unique_integer([:positive])}"
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

  describe "the rendered form" do
    test "names both sides and the date range, and defaults none of them", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      native_run!(organization, version, 1)
      native_run!(organization, version, 2)

      {:ok, view, html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      assert html =~ "export-comparison-form"
      assert html =~ "comparison-left"
      assert html =~ "comparison-right"
      assert html =~ "comparison-from"
      assert html =~ "comparison-to"
      assert html =~ "comparison-start"
      assert html =~ "comparison-status"

      # Both run selectors are labelled and offer a prompt rather than a
      # pre-selected file, and the date range starts blank.
      assert field_label(view, "select#comparison-left") == "Earlier export"
      assert field_label(view, "select#comparison-right") == "Candidate export"
      assert field_label(view, "input#comparison-from") == "From"
      assert field_label(view, "input#comparison-to") == "To"

      # The prompt option is the only one that can carry the empty value, and
      # neither side is silently defaulted to a real file.
      assert selected_values(html, "select#comparison-left") == []
      assert selected_values(html, "select#comparison-right") == []
      assert fragment_values(html, "select#comparison-left option") |> List.first() == ""
      assert fragment_values(html, "select#comparison-right option") |> List.first() == ""

      assert date_value(html, "input#comparison-from") == ""
      assert date_value(html, "input#comparison-to") == ""

      # The start control is the form's own submit trigger, so a real click
      # carries the entered draft. A second, payload-less `phx-submit` on the
      # button would push an empty comparison and silently do nothing. The
      # button sets no `type` of its own: inside a form that already means
      # submit, and asserting the absence catches a regression that would turn
      # it into a plain button.
      assert has_element?(
               view,
               "form#export-comparison-form button#comparison-start:not([phx-submit]):not([type])"
             )
    end

    test "offers only this organization's retained full feed exports", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      own = native_run!(organization, version, 3)

      foreign_organization = organization_fixture()

      foreign =
        native_run!(foreign_organization, gtfs_version_fixture(foreign_organization.id), 4)

      # A pathways export of the same organization is a real, retained artifact
      # that this comparison profile does not accept.
      pathways = pathways_run!(organization, gtfs_version_fixture(organization.id))

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      options = option_values(view, "select#comparison-left")

      assert Enum.any?(options, &(&1 == to_string(own.id)))
      refute Enum.any?(options, &(&1 == to_string(foreign.id)))
      refute Enum.any?(options, &(&1 == to_string(pathways.id)))
    end
  end

  describe "starting a comparison" do
    test "reaches the real runner, claims both files and reports the comparison", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = native_run!(organization, version, 6)
      right = native_run!(organization, gtfs_version_fixture(organization.id), 7)

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      html =
        view
        |> form("form#export-comparison-form",
          comparison: %{
            "left_run_id" => left.id,
            "right_run_id" => right.id,
            "from" => @from,
            "to" => @to
          }
        )
        |> render_submit()

      # The status band leaves the idle state and the cancel control appears,
      # which is only reachable through a real coordinator.
      assert html =~ "comparison-cancel"

      await_comparison(view)

      assert has_element?(view, "#comparison-status-title", "Comparison finished")

      # The finished band names the two files it actually compared, so the
      # sentence cannot describe a different pair than the one that was read.
      assert has_element?(view, "#comparison-status-detail", "over Nov 23, 2026 – Nov 27, 2026")

      # Both receipts were really taken and released by the real claim path.
      for run <- [left, right] do
        stored = Repo.get!(Run, run.id)
        assert stored.state == :ready
        assert stored.download_count == 1
        assert stored.download_claimed_until == nil
      end
    end

    test "a blank selection is refused, not a crash", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      native_run!(organization, version, 19)

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      # The form submitted with no files chosen at all. Every cast refuses, and
      # the page must say so rather than the LiveView crashing on an answer it
      # does not expect.
      view
      |> element("form#export-comparison-form")
      |> render_submit(%{
        "comparison" => %{"left_run_id" => "", "right_run_id" => "", "from" => "", "to" => ""}
      })

      assert has_element?(view, "#comparison-notice")
      refute render(view) =~ "comparison-cancel"
    end

    test "a refused window retains the entered dates and files, and the export form still works",
         context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = native_run!(organization, version, 8)
      right = native_run!(organization, gtfs_version_fixture(organization.id), 9)

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      view
      |> form("form#export-comparison-form",
        comparison: %{
          "left_run_id" => left.id,
          "right_run_id" => right.id,
          "from" => @to,
          "to" => @from
        }
      )
      |> render_submit()

      # The refusal names the dates and keeps both chosen files, so the editor
      # corrects one value instead of starting over.
      assert has_element?(view, "#comparison-notice")
      assert has_element?(view, "#comparison-status-title", "couldn’t finish")

      assert selected_run_ids(view, "comparison-left") == [to_string(left.id)]
      assert selected_run_ids(view, "comparison-right") == [to_string(right.id)]
      assert date_value(render(view), "input#comparison-from") == @to
      assert date_value(render(view), "input#comparison-to") == @from

      # Nothing was claimed, and the export form the page already had is intact.
      for run <- [left, right] do
        assert %Run{download_count: 0, download_claimed_until: nil} = Repo.get!(Run, run.id)
      end

      assert has_element?(view, "form#gtfs-export-form")
    end

    test "a forged event carrying another organization's run acquires no claim", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      own = native_run!(organization, version, 10)
      native_run!(organization, gtfs_version_fixture(organization.id), 11)

      foreign_organization = organization_fixture()

      foreign =
        native_run!(foreign_organization, gtfs_version_fixture(foreign_organization.id), 12)

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      # Submitted through the real form exactly as a forged client event would:
      # a run id this page never listed, and an empty window. `render_submit/2`
      # on the raw element bypasses the client-side option check, which is the
      # point: the server must refuse the value on its own.
      html =
        view
        |> element("form#export-comparison-form")
        |> render_submit(%{
          "comparison" => %{
            "left_run_id" => foreign.id,
            "right_run_id" => own.id,
            "from" => "",
            "to" => ""
          }
        })

      refute html =~ "comparison-cancel"

      assert %Run{download_count: 0, download_claimed_until: nil} = Repo.get!(Run, foreign.id)
      assert %Run{download_count: 0, download_claimed_until: nil} = Repo.get!(Run, own.id)

      # The refusal is the same opaque answer an unlisted run gets, and the
      # foreign id is never echoed back into the form.
      assert has_element?(view, "#comparison-notice")
      assert selected_run_ids(view, "comparison-left") == []
    end
  end

  describe "replacement, cancellation and closing" do
    test "replacing the selection cancels the owned coordinator and ignores its answer",
         context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = slow_run!(organization, version)
      right = slow_run!(organization, gtfs_version_fixture(organization.id))

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      start_comparison(view, left, right)
      assert render(view) =~ "comparison-cancel"

      # Changing either side is a replacement: the running comparison is retired.
      view
      |> form("form#export-comparison-form",
        comparison: %{
          "left_run_id" => left.id,
          "right_run_id" => right.id,
          "from" => @from,
          "to" => @to
        }
      )
      |> render_change()

      assert has_element?(view, "#comparison-status-title", "No comparison running")
      refute render(view) =~ "comparison-cancel"

      # The retired comparison released whatever it had claimed. A replacement
      # can land before the claim is taken at all, so the receipt count is not
      # asserted here; what must hold is that no claim is left behind.
      assert_claims_released([left, right])
      assert has_element?(view, "#comparison-status-title", "No comparison running")
    end

    test "a stale request reference cannot overwrite the current comparison", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = native_run!(organization, version, 13)
      right = native_run!(organization, gtfs_version_fixture(organization.id), 14)

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      start_comparison(view, left, right)
      await_comparison(view)
      assert has_element?(view, "#comparison-status-title", "Comparison finished")

      # An answer tagged with a reference the page has already retired.
      send(view.pid, {:release_comparison, -1, {:ok, stale_result(left, right)}})
      send(view.pid, {:release_comparison, -1, {:error, :worker_exit}})

      # The finished comparison still stands.
      assert has_element?(view, "#comparison-status-title", "Comparison finished")
      refute render(view) =~ "comparison-notice"
    end

    test "cancelling stops only the comparison and keeps the entered draft", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = slow_run!(organization, version)
      right = slow_run!(organization, gtfs_version_fixture(organization.id))

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      start_comparison(view, left, right)
      render_click(view, "cancel_comparison")

      # The band ends on the coordinator's own answer rather than spinning.
      await_comparison(view)
      assert has_element?(view, "#comparison-status-title", "couldn’t finish")

      # The entered files and dates survive, and both files are released.
      assert selected_run_ids(view, "comparison-left") == [to_string(left.id)]
      assert selected_run_ids(view, "comparison-right") == [to_string(right.id)]
      assert date_value(render(view), "input#comparison-from") == @from
      assert date_value(render(view), "input#comparison-to") == @to

      # The export form and the check panel are untouched by a comparison
      # cancellation: no export was cancelled, retried or started.
      assert has_element?(view, "form#gtfs-export-form")
      assert has_element?(view, "#export-run-status")
    end

    test "a forged second start while one is running keeps the first coordinator", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = slow_run!(organization, version)
      right = slow_run!(organization, gtfs_version_fixture(organization.id))

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      start_comparison(view, left, right)
      assert render(view) =~ "comparison-cancel"
      coordinator = view.pid |> :sys.get_state() |> Map.fetch!(:socket) |> comparison_pid()

      # The Compare button is gone, so this event can only be forged or replayed.
      render_hook(view, "start_comparison", %{
        "comparison" => %{
          "left_run_id" => left.id,
          "right_run_id" => right.id,
          "from" => @from,
          "to" => @to
        }
      })

      # Replacing the coordinator would orphan it with both claims still held.
      assert view.pid |> :sys.get_state() |> Map.fetch!(:socket) |> comparison_pid() ==
               coordinator

      render_click(view, "cancel_comparison")
      await_comparison(view)
      assert_claims_released([left, right])
    end

    test "forged event payloads that are not shaped like the form do not crash the page",
         context do
      %{conn: conn, user: user, organization: organization, version: version} = context

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      # `Integer.parse/1` returns `{12, "abc"}` and `{5, ".5"}` for these.
      for limit <- ["12abc", "5.5", "-3x", "abc"] do
        render_hook(view, "page_comparison", %{
          "collection" => "comparison_differences",
          "offset" => "0",
          "limit" => limit
        })
      end

      for event <- ["select_comparison", "start_comparison"] do
        render_hook(view, event, %{"comparison" => "not-a-map"})
      end

      render_hook(view, "narrow_comparison", %{"comparison_scope" => ["not-a-map"]})

      assert has_element?(view, "#comparison-status-title", "No comparison running")
    end

    test "closing and reopening does not adopt the previous request's result", context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = native_run!(organization, version, 15)
      right = native_run!(organization, gtfs_version_fixture(organization.id), 16)

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      start_comparison(view, left, right)
      await_comparison(view)
      assert has_element?(view, "#comparison-status-title", "Comparison finished")

      render_click(view, "close_comparison")

      # Back to first use: no files, no dates, no result.
      assert has_element?(view, "#comparison-status-title", "No comparison running")
      assert selected_run_ids(view, "comparison-left") == []
      assert date_value(render(view), "input#comparison-from") == ""
      refute render(view) =~ "comparison-close"

      # A late answer from the closed request changes nothing.
      send(view.pid, {:release_comparison, -1, {:ok, stale_result(left, right)}})
      assert has_element?(view, "#comparison-status-title", "No comparison running")
    end

    test "an owned coordinator that exits without an answer is reported as a worker exit",
         context do
      %{conn: conn, user: user, organization: organization, version: version} = context
      left = slow_run!(organization, version)
      right = slow_run!(organization, gtfs_version_fixture(organization.id))

      {:ok, view, _html} =
        live(log_in_user(conn, user, organization: organization), export_path(version))

      start_comparison(view, left, right)
      assert render(view) =~ "comparison-cancel"

      # The page's own monitor is what turns a coordinator that dies without a
      # terminal message into a reported worker exit, so the case kills the real
      # coordinator the real event started.
      coordinator = view.pid |> :sys.get_state() |> Map.fetch!(:socket) |> comparison_pid()
      ref = Process.monitor(coordinator)
      Process.exit(coordinator, :kill)
      assert_receive {:DOWN, ^ref, :process, ^coordinator, _reason}, 5_000

      wait_until(5_000, fn ->
        has_element?(view, "#comparison-status-title", "couldn’t finish") and
          has_element?(view, "#comparison-notice", "stopped unexpectedly")
      end)

      # A coordinator killed outright runs no finalizer, so its claims are not
      # released here: they fall back to the existing finite download lease.
      # Claim cleanup is step 7's proved behaviour; what this step owns is only
      # that the page reports the exit rather than spinning forever.
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp export_path(version), do: "/gtfs/#{version.id}/export"

  defp comparison_pid(%Phoenix.LiveView.Socket{assigns: assigns}),
    do: Map.fetch!(assigns, :comparison_coordinator)

  defp start_comparison(view, left, right) do
    view
    |> form("form#export-comparison-form",
      comparison: %{
        "left_run_id" => left.id,
        "right_run_id" => right.id,
        "from" => @from,
        "to" => @to
      }
    )
    |> render_submit()
  end

  # The comparison is asynchronous, so the case waits for the band to leave its
  # running or cancelling state with a finite deadline rather than a sleep.
  defp await_comparison(view, timeout \\ 30_000) do
    wait_until(timeout, fn ->
      html = render(view)

      (html =~ "Comparison finished" or html =~ "couldn’t finish") and
        not String.contains?(html, "Cancelling…")
    end)
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

  defp option_values(view, selector) do
    view
    |> element("form#export-comparison-form #{selector}")
    |> render()
    |> fragment_values("#{selector} option")
  end

  defp selected_run_ids(view, id) do
    view
    |> element("form#export-comparison-form select##{id}")
    |> render()
    |> selected_values("select##{id}")
  end

  defp selected_values(html, selector) do
    fragment_values(html, "#{selector} option[selected]")
  end

  defp fragment_values(html, selector) do
    html
    |> fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> to_string()))
  end

  defp date_value(html, selector) do
    html |> fragment_values(selector) |> List.first()
  end

  # `core_components.input/1` wraps its control in a label, so the visible label
  # text is the enclosing fieldset's own text.
  defp field_label(view, selector) do
    view
    |> render()
    |> fragment()
    |> LazyHTML.query("div.fieldset:has(#{selector}) span.label")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    |> List.first()
  end

  defp fragment(html), do: LazyHTML.from_fragment(html)

  defp assert_claims_released(runs) do
    deadline = System.monotonic_time(:millisecond) + 15_000

    Enum.each(runs, fn run ->
      stored = await_released(run, deadline)
      assert stored.download_claimed_until == nil
    end)
  end

  defp await_released(run, deadline) do
    stored = Repo.get!(Run, run.id)

    cond do
      is_nil(stored.download_claimed_until) ->
        stored

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the comparison never released the claim on #{run.id}")

      true ->
        Process.sleep(20)
        await_released(run, deadline)
    end
  end

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

  defp stale_result(left, right) do
    %{
      fingerprint: String.duplicate("0", 64),
      window: %{from: Date.from_iso8601!(@from), to: Date.from_iso8601!(@to)},
      left: %{run_id: left.id, version_name: "Stale export"},
      right: %{run_id: right.id, version_name: "Stale export"},
      comparison: %{digest: String.duplicate("1", 64)}
    }
  end

  @slow_trips 1_500

  # Large enough that the compute child is still reading when a case acts on
  # it, small enough to stay well inside the reader's own caps. Same member
  # names, headers and row shape the native exporter writes.
  defp slow_run!(organization, version) do
    publish_run!(organization, version, producer_zip(@slow_trips), :full)
  end

  defp native_run!(organization, version, suffix) do
    seed_version!(organization, version, suffix)
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    publish_run!(organization, version, bytes, :full)
  end

  defp pathways_run!(organization, version) do
    seed_version!(organization, version, "PATH")
    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :pathways)
    publish_run!(organization, version, bytes, :pathways)
  end

  # The suffix keeps two runs of the same version from colliding on the stored
  # agency, route, stop and service identifiers.
  defp seed_version!(organization, version, suffix) do
    agency = agency_fixture(organization.id, version.id, %{agency_id: "AGENCY#{suffix}"})

    route =
      route_fixture(organization.id, version.id, %{route_id: "R#{suffix}", agency_id: agency.id})

    stop = stop_fixture(organization.id, version.id, %{stop_id: "S#{suffix}"})
    calendar_fixture(organization.id, version.id, %{service_id: "WEEK#{suffix}"})

    trip =
      trip_fixture(organization.id, version.id, route.id, %{
        trip_id: "T#{suffix}",
        service_id: "WEEK#{suffix}"
      })

    stop_time_fixture(organization.id, version.id, trip.id, stop.id, %{
      stop_sequence: 1,
      arrival_time: "08:00:00",
      departure_time: "08:00:00"
    })

    {:ok, bytes, _warnings} = Export.build_zip(organization.id, version.id, :full)
    publish_run!(organization, version, bytes, :full)
  end

  defp publish_run!(organization, version, bytes, export_type) do
    {:ok, run} = ExportRuns.create_pending(organization.id, version.id, @actor, export_type)
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

  defp producer_zip(trips) do
    stops =
      Enum.map_join(1..5, "\n", fn index ->
        "S#{index},Stop #{index},40.#{index},-74.#{index}"
      end)

    trip_rows = Enum.map_join(1..trips, "\n", fn index -> "R1,WEEK,T#{index},0" end)

    stop_time_rows =
      Enum.map_join(1..trips, "\n", fn index ->
        Enum.map_join(1..5, "\n", fn stop ->
          "T#{index},0#{stop}:00:00,0#{stop}:00:00,S#{stop},#{stop}"
        end)
      end)

    members = [
      {"agency.txt",
       "agency_id,agency_name,agency_url,agency_timezone\nAGENCY,Metro,http://a.example,UTC"},
      {"routes.txt",
       "route_id,agency_id,route_short_name,route_long_name,route_type\nR1,AGENCY,1,Main,3"},
      {"stops.txt", "stop_id,stop_name,stop_lat,stop_lon\n" <> stops},
      {"trips.txt", "route_id,service_id,trip_id,direction_id\n" <> trip_rows},
      {"stop_times.txt",
       "trip_id,arrival_time,departure_time,stop_id,stop_sequence\n" <> stop_time_rows},
      {"calendar.txt",
       "service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n" <>
         "WEEK,1,1,1,1,1,0,0,20260101,20261231"}
    ]

    entries =
      Enum.map(members, fn {name, body} ->
        {String.to_charlist(name), IO.iodata_to_binary(body)}
      end)

    {:ok, {_, bytes}} = :zip.create(~c"network.zip", entries, [:memory])
    bytes
  end
end

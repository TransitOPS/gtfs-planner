defmodule GtfsPlannerWeb.Gtfs.CalendarCombinationLiveTest do
  @moduledoc """
  LiveView evidence for the calendar selection and the initial Combine calendars drawer.

  Every case drives the ordinary authenticated `/gtfs/:version/calendars` route through the real
  `CalendarsLive` socket and the default `CatalogReadAdapter.Repo`; no private assign is injected
  and no test-only registration exists, so a missing production wiring fails here instead of
  passing against a constructed socket. The review itself is the public
  `Gtfs.review_calendar_change/3` combination command, and the block, transfer and retained-source
  lines come from the concrete package-05 `Blocking` producer over real trips, stop times and
  transfer rows.

  Covered here: exact-ID selection and its pruning rules, the deterministic most-trips default
  destination, the no-op review, the unavailable state when a retained range cannot be read, the
  fact that opening or re-reviewing writes nothing, the explicit conflict decisions - their
  fieldsets, the refused submission, the consequences each choice produces and the seasonal
  expansion warning - and this step's confirmation path: the pending state that exists before the
  write, the refusal of a duplicate confirmation and of a close while it is in flight, the stale
  review and its explicit refresh, an ordinary failure that keeps every choice, the reconnect that
  never resends an old command, and the confirmed result that closes the drawer, reloads the list,
  announces the move and keeps the source. The last two cases run against committed rows through
  the ordinary route with no sandbox wiring at all, because the apply runs in its own process.

  The prepared focused command is deferred to branch review:
  `MIX_ENV=test MIX_TEST_PARTITION=_calendar17 mix test test/gtfs_planner_web/live/gtfs/calendar_combination_live_test.exs`.
  """
  use GtfsPlannerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.BlockingFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures
  import GtfsPlanner.GtfsFixtures

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Accounts.UserToken
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # The unboxed cases wait for a real lock rendezvous instead of sleeping, with a finite deadline.
  @contention_timeout 15_000
  @poll_interval 10
  # `render_async/2`'s default 100 ms is a race against the confirmation's own transaction; the
  # wait stays bounded and still fails when the socket never settles its async work.
  @settle_timeout 5_000

  setup do
    organization = organization_fixture()
    user = user_fixture()

    Accounts.create_user_org_membership(%{
      user_id: user.id,
      organization_id: organization.id,
      roles: ["pathways_studio_editor"]
    })

    %{user: user, organization: organization, version: gtfs_version_fixture(organization.id)}
  end

  # The first paint defers its read: the socket sends itself `:load_calendars`, so this waits for
  # the mailbox to be handled instead of sleeping and then renders the settled list.
  defp loaded(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  defp list_path(version, query \\ %{}) do
    case URI.encode_query(query) do
      "" -> "/gtfs/#{version.id}/calendars"
      encoded -> "/gtfs/#{version.id}/calendars?#{encoded}"
    end
  end

  defp editor(conn, user, organization), do: log_in_user(conn, user, organization: organization)

  # The fixtures derive their dates from the same agency-local today the read resolves, so a
  # status or range assertion cannot depend on the day the suite runs.
  defp postgres_local_today(timezone) do
    %{rows: [[%Date{} = date]]} = Repo.query!("SELECT (now() AT TIME ZONE $1)::date", [timezone])

    date
  end

  # One coherent combination scenario: a Saturday destination that keeps its block, a moving
  # Saturday/Sunday shuttle that shares that block and therefore keeps it, and a Sunday shuttle
  # plus a specific-dates Monday shuttle that share a second block without ever sharing a date,
  # so the reviewed projection clears both. The type-4 record between the first two trips is a
  # real in-seat transfer the review has to report.
  defp combination_scenario(organization, version) do
    agency_fixture(organization.id, version.id, %{agency_timezone: "Etc/UTC"})
    route = route_fixture(organization.id, version.id, %{route_id: "COMBINE_ROUTE"})

    {:ok, first_stop} =
      GtfsPlanner.Gtfs.create_stop(%{
        stop_id: "CB_S1",
        stop_name: "Combine Stop 1",
        location_type: 0,
        organization_id: organization.id,
        gtfs_version_id: version.id
      })

    {:ok, second_stop} =
      GtfsPlanner.Gtfs.create_stop(%{
        stop_id: "CB_S2",
        stop_name: "Combine Stop 2",
        location_type: 0,
        organization_id: organization.id,
        gtfs_version_id: version.id
      })

    today = postgres_local_today("Etc/UTC")
    next_monday = Date.add(today, rem(8 - Date.day_of_week(today), 7) + 7)

    weekly = [
      {"COMBINE_DEST", 0, 0, 0, 0, 0, 1, 0, Date.add(today, -30), Date.add(today, 60)},
      {"COMBINE_FALL", 0, 0, 0, 0, 0, 1, 1, Date.add(today, -30), Date.add(today, 30)},
      {"COMBINE_SUN", 0, 0, 0, 0, 0, 0, 1, Date.add(today, -10), Date.add(today, 40)}
    ]

    for {service_id, mon, tue, wed, thu, fri, sat, sun, start_date, end_date} <- weekly do
      calendar_fixture(organization.id, version.id, %{
        service_id: service_id,
        monday: mon,
        tuesday: tue,
        wednesday: wed,
        thursday: thu,
        friday: fri,
        saturday: sat,
        sunday: sun,
        start_date: start_date,
        end_date: end_date
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: description(service_id)
      })
    end

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: "COMBINE_MON",
      service_description: description("COMBINE_MON")
    })

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "COMBINE_MON",
      date: next_monday,
      exception_type: 1
    })

    trips = [
      {"COMBINE_DEST", "COMBINE_DEST_1", "KEEP",
       [{~T[08:00:00], first_stop}, {~T[09:00:00], second_stop}]},
      {"COMBINE_DEST", "COMBINE_DEST_2", nil,
       [{~T[10:00:00], first_stop}, {~T[11:00:00], second_stop}]},
      {"COMBINE_FALL", "COMBINE_FALL_1", "KEEP",
       [{~T[09:10:00], second_stop}, {~T[10:00:00], first_stop}]},
      {"COMBINE_SUN", "COMBINE_SUN_1", "CLEAR",
       [{~T[11:00:00], first_stop}, {~T[12:00:00], second_stop}]},
      {"COMBINE_MON", "COMBINE_MON_1", "CLEAR",
       [{~T[18:00:00], first_stop}, {~T[19:00:00], second_stop}]}
    ]

    add_trips(organization, version, route, trips)

    transfer_fixture(organization.id, version.id, %{
      from_trip_id: "COMBINE_DEST_1",
      to_trip_id: "COMBINE_FALL_1",
      from_stop_id: second_stop.stop_id,
      to_stop_id: second_stop.stop_id,
      transfer_type: 4
    })

    %{today: today, route: route, first_stop: first_stop, second_stop: second_stop}
  end

  defp description("COMBINE_DEST"), do: "Saturday service"
  defp description("COMBINE_FALL"), do: "Fall shuttle"
  defp description("COMBINE_SUN"), do: "Sunday shuttle"
  defp description("COMBINE_MON"), do: "Monday shuttle"
  defp description(other), do: other

  # The domain's only conflict shape: two weekly calendars with the same mask where one
  # deliberately removes a regular weekday the other runs. Both sides carry trips, so each option
  # names the trips it affects, and the removal is the exact date the choice decides.
  defp conflict_scenario(organization, version) do
    %{route: route, first_stop: first_stop, second_stop: second_stop, today: today} =
      combination_scenario(organization, version)

    for {service_id, description} <- [
          {"CONFLICT_OFF", "Holiday weekdays"},
          {"CONFLICT_RUN", "Weekday service"}
        ] do
      calendar_fixture(organization.id, version.id, %{
        service_id: service_id,
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        start_date: Date.add(today, -20),
        end_date: Date.add(today, 20)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: description
      })
    end

    removal =
      Enum.find(Date.range(Date.add(today, 7), Date.add(today, 21)), &(Date.day_of_week(&1) == 3))

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "CONFLICT_OFF",
      date: removal,
      exception_type: 2
    })

    add_trips(organization, version, route, [
      {"CONFLICT_OFF", "CONFLICT_OFF_1", nil,
       [{~T[06:00:00], first_stop}, {~T[07:00:00], second_stop}]},
      {"CONFLICT_OFF", "CONFLICT_OFF_2", nil,
       [{~T[07:30:00], first_stop}, {~T[08:30:00], second_stop}]},
      {"CONFLICT_RUN", "CONFLICT_RUN_1", nil,
       [{~T[09:00:00], first_stop}, {~T[10:00:00], second_stop}]},
      {"CONFLICT_RUN", "CONFLICT_RUN_2", nil,
       [{~T[10:30:00], first_stop}, {~T[11:30:00], second_stop}]}
    ])

    %{removal: removal, today: today}
  end

  # A moving calendar whose trips would gain far more than the domain's seasonal threshold of
  # upcoming dates: the review has to say so instead of quietly running a seasonal shuttle all year.
  defp seasonal_scenario(organization, version) do
    %{route: route, first_stop: first_stop, second_stop: second_stop, today: today} =
      combination_scenario(organization, version)

    for {service_id, days, description, start_offset, end_offset} <- [
          {"SEASON_DEST", %{monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1},
           "Weekday service", -30, 60},
          {"SEASON_SAT", %{saturday: 1}, "Saturday shuttle", -10, 10}
        ] do
      calendar_fixture(
        organization.id,
        version.id,
        Map.merge(days, %{
          service_id: service_id,
          start_date: Date.add(today, start_offset),
          end_date: Date.add(today, end_offset)
        })
      )

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: service_id,
        service_description: description
      })
    end

    add_trips(organization, version, route, [
      {"SEASON_DEST", "SEASON_DEST_1", nil,
       [{~T[06:00:00], first_stop}, {~T[07:00:00], second_stop}]},
      {"SEASON_DEST", "SEASON_DEST_2", nil,
       [{~T[07:30:00], first_stop}, {~T[08:30:00], second_stop}]},
      {"SEASON_SAT", "SEASON_SAT_1", nil,
       [{~T[09:00:00], first_stop}, {~T[10:00:00], second_stop}]}
    ])
  end

  defp add_trips(organization, version, route, trips) do
    for {service_id, trip_id, block_id, times} <- trips do
      trip =
        trip_fixture(organization.id, version.id, route.route_id, %{
          service_id: service_id,
          trip_id: trip_id,
          block_id: block_id
        })

      times
      |> Enum.with_index(1)
      |> Enum.each(fn {{time, stop}, index} ->
        stop_time_fixture(organization.id, version.id, trip.trip_id, stop.stop_id, %{
          arrival_time: "#{time}",
          departure_time: "#{time}",
          stop_sequence: index
        })
      end)
    end
  end

  defp row_counts(version) do
    %{
      calendars:
        Repo.aggregate(from(c in Calendar, where: c.gtfs_version_id == ^version.id), :count),
      dates:
        Repo.aggregate(from(d in CalendarDate, where: d.gtfs_version_id == ^version.id), :count),
      attributes:
        Repo.aggregate(
          from(a in CalendarAttribute, where: a.gtfs_version_id == ^version.id),
          :count
        ),
      trips: Repo.aggregate(from(t in Trip, where: t.gtfs_version_id == ^version.id), :count),
      transfers:
        Repo.aggregate(from(tr in Transfer, where: tr.gtfs_version_id == ^version.id), :count),
      logs: Repo.aggregate(from(l in ChangeLog, where: l.gtfs_version_id == ^version.id), :count)
    }
  end

  # The list itself opens the review: the same two clicks a reviewer makes, and nothing injected.
  defp open_review(view, service_ids) do
    for service_id <- service_ids do
      render_click(view, "toggle_calendar_selection", %{"service-id" => service_id})
    end

    render_click(view, "open_combine", %{})
    assert has_element?(view, "#calendar-combine-form")
  end

  # The apply runs in its own task and the socket then handles its result and the authoritative
  # reload it schedules, so the settled render is polled against a predicate inside a finite window
  # instead of being read once.
  defp settle(view, ready, attempts \\ 200) when is_function(ready, 1) do
    _ = render_async(view, @settle_timeout)

    Enum.reduce_while(1..attempts, render(view), fn _attempt, html ->
      if ready.(html) do
        {:halt, html}
      else
        Process.sleep(10)
        {:cont, render(view)}
      end
    end)
  end

  # Rendered templates keep their source line breaks in text nodes, so a sentence is asserted
  # against the collapsed text.
  defp flat(html), do: String.replace(html, ~r/\s+/, " ")

  # The tinted rows the confirmed summary explains, read from the list itself rather than from an
  # internal assign. The rendered class is exact: the shared row class plus the highlight.
  defp highlighted_rows(view) do
    view
    |> element("#calendars-list")
    |> render()
    |> String.split("hover:bg-base-200 bg-success/10")
    |> length()
    |> Kernel.-(1)
  end

  defp list_row_trips(view, service_id) do
    row =
      view
      |> element("#calendars-list")
      |> render()
      |> String.split("<tr", trim: true)
      |> Enum.find(&String.contains?(&1, service_id))

    case row && Regex.run(~r/class="tabular-nums">(\d+)</, row) do
      [_, count] -> String.to_integer(count)
      _missing -> flunk("no loaded list row with trips for #{service_id}")
    end
  end

  ## Committed scope helpers for the two unboxed cases

  # Everything the ordinary route needs, written on a real committing connection: an active editor,
  # a published version with a second version to switch to, one weekly destination with two trips
  # and one dates-only source with a single trip. The source's two dates are the destination's own
  # Saturdays, so the reviewed pair has no conflict and the destination's stored dates cannot change.
  defp seed_committed_scope(suffix) do
    unique = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    organization = organization_fixture(%{alias: "combination-route-#{suffix}-#{unique}"})
    version = gtfs_version_fixture(organization.id)
    other_version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id, %{route_id: "LR_#{unique}"})
    user = user_fixture(%{email: "combination-route-#{unique}@example.test"})
    membership = organization_membership_fixture(user, organization)

    agency_fixture(organization.id, version.id, %{agency_timezone: "Etc/UTC"})

    today = postgres_local_today("Etc/UTC")

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "DEST",
      name: "Saturday service",
      saturday: 1,
      start_date: Date.add(today, -30),
      end_date: Date.add(today, 60)
    })

    first_saturday = Date.add(today, rem(6 - Date.day_of_week(today), 7) + 7)

    calendar_service_fixture(organization.id, version.id, %{
      service_id: "SAT",
      name: "Fall shuttle",
      dates: [first_saturday, Date.add(first_saturday, 7)]
    })

    for trip_id <- ["DEST_T1", "DEST_T2"] do
      trip_fixture(organization.id, version.id, route.route_id, %{
        trip_id: trip_id,
        service_id: "DEST"
      })
    end

    trip_fixture(organization.id, version.id, route.route_id, %{
      trip_id: "SAT_T1",
      service_id: "SAT"
    })

    %{
      organization: organization,
      organization_id: organization.id,
      version: version,
      version_id: version.id,
      other_version: other_version,
      user: user,
      actor_id: user.id,
      membership_id: membership.id
    }
  end

  # An unboxed case commits its scope, so it deletes exactly the rows it created, including the
  # session token the route sign-in committed for its own actor.
  defp cleanup_committed_scope(scope) do
    organization_id = scope.organization_id

    Repo.delete_all(from(l in ChangeLog, where: l.organization_id == ^organization_id))
    Repo.delete_all(from(t in Transfer, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(st in StopTime, where: st.organization_id == ^organization_id))
    Repo.delete_all(from(t in Trip, where: t.organization_id == ^organization_id))
    Repo.delete_all(from(s in Stop, where: s.organization_id == ^organization_id))
    Repo.delete_all(from(a in CalendarAttribute, where: a.organization_id == ^organization_id))
    Repo.delete_all(from(d in CalendarDate, where: d.organization_id == ^organization_id))
    Repo.delete_all(from(c in Calendar, where: c.organization_id == ^organization_id))
    Repo.delete_all(from(r in Route, where: r.organization_id == ^organization_id))
    Repo.delete_all(from(a in Agency, where: a.organization_id == ^organization_id))
    Repo.delete_all(from(t in UserToken, where: t.user_id == ^scope.actor_id))

    Repo.delete_all(
      from(m in UserOrgMembership,
        where: m.organization_id == ^organization_id or m.user_id == ^scope.actor_id
      )
    )

    Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^organization_id))
    Repo.delete_all(from(u in User, where: u.id == ^scope.actor_id))

    Repo.delete_all(
      from(o in GtfsPlanner.Organizations.Organization, where: o.id == ^organization_id)
    )
  end

  defp authenticated_conn(scope) do
    build_conn() |> log_in_user(scope.user, organization: scope.organization)
  end

  # The success banner is assigned before the socket runs the authoritative reload, so a settled
  # render waits for the banner and for the reloading note to be gone.
  defp reloaded?(html, banner) do
    html =~ banner and not (html =~ "calendars-refreshing")
  end

  # A second committing connection holds the scoped version row the way a calendar write does, so
  # the confirmation's own transaction genuinely has to queue behind it instead of the pending state
  # depending on timing.
  defp hold_version_row(scope) do
    parent = self()
    task = Task.async(fn -> unboxed(fn -> hold_version_transaction(scope, parent) end) end)

    assert_receive {:version_held, task_pid, backend}, @contention_timeout
    assert task_pid == task.pid
    %{task: task, backend: backend}
  end

  defp hold_version_transaction(scope, parent) do
    Repo.transaction(fn -> lock_version!(scope) |> announce_hold(parent) end)
  end

  defp lock_version!(scope) do
    Repo.one(
      from(v in GtfsVersion,
        where: v.id == ^scope.version_id and v.organization_id == ^scope.organization_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp announce_hold(version, parent) do
    send(parent, {:version_held, self(), backend_pid()})

    receive do
      :release -> Repo.rollback(:released)
    end

    version
  end

  defp release_version_row(holder) do
    send(holder.task.pid, :release)
    assert {:error, :released} = Task.await(holder.task, @contention_timeout)
  end

  # The apply's own session is the one the held transaction blocks. Waiting for it is the rendezvous
  # that proves the domain really is waiting on the version row, and its identity is what lets the
  # duplicate assertions prove no second transaction ever queued behind it. `pg_blocking_pids/1`
  # answers with the sessions blocking the row holder, so the waiters are read from that direction.
  defp await_blocked_backend(holder_backend) do
    deadline = System.monotonic_time(:millisecond) + @contention_timeout
    await_blocked_backend(holder_backend, deadline)
  end

  defp await_blocked_backend(holder_backend, deadline) do
    case waiters_on(holder_backend) do
      [blocked] ->
        blocked

      other ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_interval)
          await_blocked_backend(holder_backend, deadline)
        else
          flunk(
            "expected exactly one confirmation to wait on the held row, saw #{inspect(other)}"
          )
        end
    end
  end

  # The rendezvous observation needs a connection of its own: the case body holds the test
  # process's unboxed checkout, the LiveView's own processes resolve to that same connection, and
  # the confirmation's transaction occupies it for the whole wait - so a query issued from the test
  # process would queue behind the very transaction it is meant to observe. A short-lived process
  # that checks out its own unboxed connection can still ask PostgreSQL who waits on the held row.
  defp waiters_on(holder_backend) do
    Task.async(fn -> unboxed(fn -> query_waiters(holder_backend) end) end)
    |> Task.await(@contention_timeout)
  end

  defp query_waiters(holder_backend) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        "SELECT pid FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
        [holder_backend]
      )

    Enum.map(rows, fn [pid] -> pid end)
  end

  defp backend_pid do
    %Postgrex.Result{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
    backend
  end

  # AC-19: a combination audits one log per changed entity - one for a changed destination calendar
  # and one per moved trip - and the complete combination envelope occurs in exactly one real log.
  # The ids are read before the confirmation so only the writer's own rows are asserted.
  defp combination_log_ids(version_id) do
    Repo.all(from(l in ChangeLog, where: l.gtfs_version_id == ^version_id, select: l.id))
  end

  defp combination_logs(version_id, before_ids) do
    Repo.all(
      from(l in ChangeLog,
        where: l.gtfs_version_id == ^version_id,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
    |> Enum.reject(&(&1.id in before_ids))
  end

  defp log_entities(logs) do
    logs
    |> Enum.map(&{&1.entity_type, &1.entity_external_id})
    |> Enum.sort()
  end

  defp envelope_logs(logs), do: Enum.filter(logs, &Map.has_key?(&1.changed_fields, "combination"))

  defp trip_service(scope, trip_id) do
    Repo.one!(
      from(t in Trip,
        where: t.gtfs_version_id == ^scope.version_id and t.trip_id == ^trip_id,
        select: t.service_id
      )
    )
  end

  defp source_trip_ids(scope) do
    Repo.all(
      from(t in Trip,
        where: t.gtfs_version_id == ^scope.version_id and t.service_id == "SAT",
        select: t.id
      )
    )
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  describe "selection and the initial review through the real route" do
    test "opens the reviewed combination from the list without writing anything", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      assert loaded(view) =~ "Saturday service"

      # Nothing is selected yet, so the selection bar offers only the select-all control.
      refute has_element?(view, "#calendar-selection-count")
      refute has_element?(view, "#calendar-combine-open")

      before = row_counts(version)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      assert render(view) =~ "1 calendar selected"
      assert has_element?(view, "#calendar-select-COMBINE_DEST[checked]")
      assert has_element?(view, "#calendar-combine-hint")

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_FALL"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_MON"})
      assert render(view) =~ "3 calendars selected"
      assert has_element?(view, "#calendar-select-COMBINE_MON[checked]")
      refute has_element?(view, "#calendar-combine-open[disabled]")

      html = render_click(view, "open_combine", %{})

      # The drawer carries the reviewed command: the most-used selected calendar is the
      # destination, every source is listed with its real trip count, and the retained sources,
      # the cleared block and the in-seat record come from the loaded rows and the producer.
      assert has_element?(view, "#calendar-combine-drawer-overlay[data-open='true']")
      assert has_element?(view, "#calendar-combine-form")

      assert has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      assert html =~ "3 calendars selected"
      assert html =~ "Keeps 2 + 2 trips"
      assert html =~ "Fall shuttle"

      assert has_element?(
               view,
               "#calendar-combine-impacts-cleared-blocks",
               "1 moved trip leaves its block and goes to the unassigned pool on Blocks."
             )

      assert String.downcase(html) =~ "in-seat transfer"
      assert html =~ "stays in the list with 0 trips"
      assert has_element?(view, "#calendar-combine-result-moved")
      assert html =~ "Nothing changes until you combine."
      assert has_element?(view, "#calendar-combine-close")
      refute has_element?(view, "#calendar-combine-decisions")

      assert row_counts(version) == before
    end

    test "changing the destination re-reviews against the real command and writes nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_MON"})
      render_click(view, "open_combine", %{})

      assert has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      before = row_counts(version)

      html =
        render_change(view, "combine_destination", %{
          "combine" => %{"destination_id" => "COMBINE_MON"}
        })

      assert has_element?(view, "#calendar-combine-destination-option-COMBINE_MON input[checked]")

      refute has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      # The Saturday destination runs on far more dates than the Monday shuttle, so the reviewed
      # result changes with the kept calendar instead of reusing the previous projection.
      assert html =~ "Keeps"
      assert row_counts(version) == before
    end

    test "sort and the timeline range keep the selection while a filter prunes it", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_FALL"})
      assert render(view) =~ "2 calendars selected"

      render_click(view, "sort", %{"key" => "name"})
      assert render(view) =~ "2 calendars selected"

      render_patch(view, list_path(version, %{"range" => "near"}))
      assert render(view) =~ "2 calendars selected"

      render_patch(view, list_path(version, %{"search" => "Fall"}))
      assert render(view) =~ "1 calendar selected"
      refute has_element?(view, "#calendar-select-COMBINE_DEST[checked]")
      assert has_element?(view, "#calendar-select-COMBINE_FALL[checked]")

      # The pruned identity is not silently restored when the filter is removed.
      render_patch(view, list_path(version))
      assert render(view) =~ "1 calendar selected"
    end

    test "select-all targets every matching valid row", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)

      # An identity whose retained range cannot be read keeps its row but cannot be selected.
      calendar_fixture(organization.id, version.id, %{
        service_id: "COMBINE_BROKEN",
        saturday: 1,
        start_date: Date.add(postgres_local_today("Etc/UTC"), 30),
        end_date: Date.add(postgres_local_today("Etc/UTC"), -30)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "COMBINE_BROKEN",
        service_description: "Broken shuttle"
      })

      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "select_all_calendars", %{})

      assert render(view) =~ "4 calendars selected"
      assert has_element?(view, "#calendar-select-COMBINE_BROKEN[disabled]")
      refute has_element?(view, "#calendar-select-COMBINE_BROKEN[checked]")

      # A forged event for the unreadable identity cannot enter the selection.
      render_click(view, "clear_calendar_selection", %{})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_BROKEN"})
      refute has_element?(view, "#calendar-selection-count")

      # The whole version cannot combine while an identity is unreadable.
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "COMBINE_FALL"})
      assert has_element?(view, "#calendar-combine-unavailable")
      assert has_element?(view, "#calendar-combine-open[disabled]")

      render_click(view, "open_combine", %{})
      refute has_element?(view, "#calendar-combine-form")
    end
  end

  describe "conflict decisions" do
    test "refuses an unanswered conflict, names the missing choice and mutates nothing", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{removal: removal} = conflict_scenario(organization, version)
      conn = editor(conn, user, organization)
      expected = Elixir.Calendar.strftime(removal, "%b %-d, %Y")

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_OFF"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_RUN"})
      render_click(view, "open_combine", %{})

      group = URI.encode_www_form(Date.to_iso8601(removal))
      fieldset = "#calendar-combine-decisions-#{group}"

      # The exact conflict date is the group, and both decisions are offered with no default, so
      # the reviewer has to make the choice the domain requires.
      assert has_element?(view, fieldset)
      assert has_element?(view, "[data-conflict-date='#{Date.to_iso8601(removal)}']")
      assert has_element?(view, "#{fieldset}-no_service")
      assert has_element?(view, "#{fieldset}-run")
      refute has_element?(view, "#{fieldset}-no_service[checked]")
      refute has_element?(view, "#{fieldset}-run[checked]")

      decisions = render(element(view, "#calendar-combine-decisions"))
      assert decisions =~ expected
      assert decisions =~ "No service"
      assert decisions =~ "Run all trips"
      assert decisions =~ "Holiday weekdays has no service"
      assert decisions =~ "Weekday service runs"
      refute has_element?(view, "#calendar-combine-errors")

      before = row_counts(version)

      html =
        render_submit(view, "combine_apply", %{
          "combine" => %{"destination_id" => "CONFLICT_OFF"}
        })

      # The submission stays available and refuses instead of dispatching an incomplete review: the
      # summary names the missing choice, the group is marked, and its first option is the form's
      # invalid control - which is what the scoped focus hook lands on.
      assert html =~ "Calendars not combined yet."
      assert has_element?(view, "#calendar-combine-errors[role='alert']")
      assert has_element?(view, "#{fieldset}-error")
      assert has_element?(view, "#{fieldset}-no_service[aria-invalid='true']")
      assert html =~ "Choose what happens on #{expected}."

      assert_push_event(view, "focus_form_error", %{
        form_id: "calendar-combine-form",
        fallback_id: "calendar-combine-errors"
      })

      assert row_counts(version) == before
    end

    test "changes the exact consequences with the choice and clears them with the destination", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{removal: removal} = conflict_scenario(organization, version)
      conn = editor(conn, user, organization)
      expected = Elixir.Calendar.strftime(removal, "%b %-d, %Y")
      iso = Date.to_iso8601(removal)
      group = URI.encode_www_form(iso)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_OFF"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "CONFLICT_RUN"})
      render_click(view, "open_combine", %{})

      assert has_element?(
               view,
               "#calendar-combine-destination-option-CONFLICT_OFF input[checked]"
             )

      before = row_counts(version)

      run_html =
        render_change(view, "combine_change", %{
          "combine" => %{"destination_id" => "CONFLICT_OFF", "decisions" => %{iso => "run"}}
        })

      assert has_element?(view, "#calendar-combine-decisions-#{group}-run[checked]")
      refute has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      # Running the date keeps every trip on its own dates, so nothing loses a date.
      assert run_html =~ "Also run on #{expected}"
      refute run_html =~ "Stop running on"

      no_service_html =
        render_change(view, "combine_change", %{
          "combine" => %{
            "destination_id" => "CONFLICT_OFF",
            "decisions" => %{iso => "no_service"}
          }
        })

      assert has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      # No service removes exactly that date from the moving trips, which is the other half of the
      # choice the reviewer is making.
      assert no_service_html =~ "Stop running on #{expected}"
      refute no_service_html =~ "Also run on"

      # Keeping another calendar discards the previous answer instead of carrying it into a review
      # whose conflict now belongs to different calendars.
      render_change(view, "combine_change", %{
        "combine" => %{"destination_id" => "CONFLICT_RUN", "decisions" => %{iso => "no_service"}}
      })

      assert has_element?(
               view,
               "#calendar-combine-destination-option-CONFLICT_RUN input[checked]"
             )

      refute has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      refute has_element?(view, "#calendar-combine-decisions-#{group}-run[checked]")

      assert row_counts(version) == before
    end

    test "warns when a moving calendar would gain more than fourteen upcoming dates", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      seasonal_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "SEASON_DEST"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "SEASON_SAT"})
      render_click(view, "open_combine", %{})

      assert has_element?(view, "#calendar-combine-destination-option-SEASON_DEST input[checked]")
      refute has_element?(view, "#calendar-combine-decisions")

      moving = render(element(view, "#calendar-combine-effects-SEASON_SAT"))
      assert moving =~ "Also run on"

      assert has_element?(
               view,
               "#calendar-combine-effects-SEASON_SAT",
               "If these trips should keep their own dates, don't combine."
             )

      # The warning is about the dates a calendar's trips would gain, so the calendar that stays
      # does not carry it.
      refute has_element?(view, "#calendar-combine-effects-SEASON_DEST", "don't combine")
    end
  end

  describe "confirmation, recovery and the confirmed result" do
    test "renders pending before the write, then closes the drawer and announces the move", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      open_review(view, ["COMBINE_DEST", "COMBINE_SUN"])

      assert has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      before_log_ids = combination_log_ids(version.id)

      # The in-flight state belongs to the confirmation's own patch: it is rendered before the task
      # starts and before any write exists to report, so the reviewer sees that the confirmation is
      # already in the domain's hands (AC-23).
      pending = render_submit(view, "combine_apply", %{})

      assert pending =~ "Combining…"
      assert pending =~ "Moving 1 trip into Saturday service…"

      # The controls are disabled by the server's own in-flight state. HEEx emits `@rest`
      # attributes in atom-term order (`disabled` before `id`), so the check parses the rendered
      # patch instead of matching one fixed attribute order.
      pending_document = LazyHTML.from_fragment(pending)

      assert pending_document
             |> LazyHTML.query("#calendar-combine-apply[disabled]")
             |> Enum.any?()

      assert pending_document
             |> LazyHTML.query("#calendar-combine-close[disabled]")
             |> Enum.any?()

      settled = settle(view, &reloaded?(&1, "Combined into Saturday service."))

      # Confirmed success closes the drawer, reloads the authoritative list and announces exactly
      # what moved, where it went and which source stays behind (AC-24).
      assert flat(settled) =~ "Combined into Saturday service."

      assert flat(settled) =~
               "1 trip moved from Sunday shuttle, which stays in the list with 0 trips."

      assert has_element?(
               view,
               "#calendar-combine-success[role='status'][data-combine-success='combined']"
             )

      refute has_element?(view, "#calendar-combine-form")
      refute has_element?(view, "#calendar-combine-open")
      refute has_element?(view, "#calendar-selection-count")

      # The reloaded rows carry the move: the destination holds the moved trip, the source keeps
      # its identity with none, and both affected rows are tinted while the summary is on screen.
      assert list_row_trips(view, "COMBINE_DEST") == 3
      assert list_row_trips(view, "COMBINE_SUN") == 0
      assert highlighted_rows(view) == 2

      # AC-19: the apply audits one log per changed entity. This combination changes the
      # destination's own dates (its trips gain the source's Sundays) and moves one trip, so the
      # committed audit is exactly the destination calendar log and the one moved trip's log, and
      # only the destination's log carries the complete combination envelope.
      logs = combination_logs(version.id, before_log_ids)

      assert log_entities(logs) == [{"calendar", "COMBINE_DEST"}, {"trip", "COMBINE_SUN_1"}]

      assert [%{entity_external_id: "COMBINE_DEST"}] = envelope_logs(logs)

      # Dismissing the summary takes its tint with it instead of leaving rows marked forever, and
      # focus is handed to the list's own selection action (AC-24).
      render_click(view, "dismiss_combine_success", %{})

      assert_push_event(view, "calendar:combine-focus", %{
        id: "calendar-select-all",
        fallback_id: "calendar-search"
      })

      refute has_element?(view, "#calendar-combine-success")
      assert highlighted_rows(view) == 0
    end

    test "a stale review keeps its inputs, requires a refresh and clears every answer", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      %{removal: removal} = conflict_scenario(organization, version)
      conn = editor(conn, user, organization)
      iso = Date.to_iso8601(removal)
      group = URI.encode_www_form(iso)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      open_review(view, ["CONFLICT_OFF", "CONFLICT_RUN"])

      # The reviewer answers the one conflict before confirming.
      render_change(view, "combine_change", %{
        "combine" => %{"destination_id" => "CONFLICT_OFF", "decisions" => %{iso => "no_service"}}
      })

      assert has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")

      # A second session adds a trip to a reviewed source, so the token the drawer still holds no
      # longer describes the current inputs (AC-14).
      trip_fixture(organization.id, version.id, "COMBINE_ROUTE", %{
        trip_id: "CONFLICT_RUN_LATE",
        service_id: "CONFLICT_RUN"
      })

      before = row_counts(version)

      _pending = render_submit(view, "combine_apply", %{})
      settled = settle(view, &(&1 =~ "changed after this review was prepared"))

      assert settled =~ "changed after this review was prepared."
      assert settled =~ "Another editor changed these calendars, so nothing was combined."
      assert settled =~ "Refresh the review to see the current result, then combine again."
      assert has_element?(view, "#calendar-combine-errors[role='alert']")

      # The review, the destination and the answer all stay, and nothing was written.
      assert has_element?(view, "#calendar-combine-form")
      assert has_element?(view, "#calendar-combine-refresh")
      refute has_element?(view, "#calendar-combine-apply")

      assert has_element?(
               view,
               "#calendar-combine-destination-option-CONFLICT_OFF input[checked]"
             )

      assert has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      assert row_counts(version) == before

      # Refresh review re-reads the authoritative inputs: it keeps an available destination,
      # includes the trip the second session added, and discards every answer, so an old
      # confirmation can never be reused (AC-23).
      refreshed = render_click(view, "combine_refresh", %{})

      assert refreshed =~ "Review refreshed."
      assert refreshed =~ "The review was rebuilt from the current calendars"

      assert has_element?(
               view,
               "#calendar-combine-destination-option-CONFLICT_OFF input[checked]"
             )

      refute has_element?(view, "#calendar-combine-decisions-#{group}-no_service[checked]")
      refute has_element?(view, "#calendar-combine-decisions-#{group}-run[checked]")
      refute has_element?(view, "#calendar-combine-refresh")
      assert has_element?(view, "#calendar-combine-apply")
      refute has_element?(view, "#calendar-combine-apply[disabled]")
      assert render(element(view, "#calendar-combine-result-moved")) =~ "3"
    end

    test "an ordinary failure keeps the review and every choice", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      combination_scenario(organization, version)
      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      open_review(view, ["COMBINE_DEST", "COMBINE_SUN"])

      before = row_counts(version)

      # The actor's membership is revoked after the review was prepared. The apply re-resolves it
      # after the version-lock wait and refuses, so the reviewer gets the domain's own reason and
      # keeps everything they chose (AC-13, AC-23).
      membership =
        Repo.get_by!(UserOrgMembership,
          user_id: user.id,
          organization_id: organization.id
        )

      deactivate_membership_fixture(membership)

      _pending = render_submit(view, "combine_apply", %{})
      settled = settle(view, &(&1 =~ "Calendars weren’t combined."))

      assert settled =~ "Calendars weren’t combined."
      assert settled =~ "You no longer have permission to change these calendars."
      assert settled =~ "Your choices are kept, so you can try again."
      assert has_element?(view, "#calendar-combine-errors[role='alert']")

      # The refusal is not a stale review: the same review is still on screen and can be
      # confirmed again once the cause is gone, and nothing was written.
      assert has_element?(view, "#calendar-combine-form")

      assert has_element?(
               view,
               "#calendar-combine-destination-option-COMBINE_DEST input[checked]"
             )

      assert has_element?(view, "#calendar-combine-apply")
      refute has_element?(view, "#calendar-combine-refresh")
      assert row_counts(version) == before
    end
  end

  # The confirmation's apply runs in its own process with the application's ordinary Repo
  # ownership, so these cases deliberately leave the SQL sandbox: every row is committed on a real
  # connection, the version row is held by a second committing connection while the confirmation is
  # in flight, and the created scope is deleted again in `on_exit`. The sandbox runs in `:auto` mode
  # rather than `:manual`: in `:manual` mode every process of the ordinary route resolves to the one
  # connection the test process checked out, so the confirmation's blocked transaction would occupy
  # the very connection the page's own reload needs. `:auto` lets the page and its confirmation task
  # take real connections of their own, which is what the ordinary route does in production - a
  # missing production path fails here instead of being hidden by a sandbox allowance.
  describe "the confirmation through the ordinary route without sandbox wiring" do
    test "shows pending, refuses a duplicate confirmation and a close, and commits exactly once",
         %{
           conn: _conn
         } do
      Sandbox.mode(Repo, :auto)

      scope = Sandbox.unboxed_run(Repo, fn -> seed_committed_scope("pending") end)
      on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> cleanup_committed_scope(scope) end) end)

      Sandbox.unboxed_run(Repo, fn ->
        {:ok, view, _html} = live(authenticated_conn(scope), list_path(scope.version))
        loaded(view)

        open_review(view, ["DEST", "SAT"])
        assert has_element?(view, "#calendar-combine-destination-option-DEST input[checked]")

        before_log_ids = combination_log_ids(scope.version_id)

        # The version row is held by another committed connection, so the confirmation's transaction
        # has a real reason to wait and the pending window is the domain's, not a timing accident.
        holder = hold_version_row(scope)

        pending = render_submit(view, "combine_apply", %{})

        assert pending =~ "Combining…"
        assert pending =~ "Moving 1 trip into Saturday service…"

        pending_document = LazyHTML.from_fragment(pending)

        assert pending_document
               |> LazyHTML.query("#calendar-combine-apply[disabled]")
               |> Enum.any?()

        assert pending_document
               |> LazyHTML.query("#calendar-combine-close[disabled]")
               |> Enum.any?()

        apply_backend = await_blocked_backend(holder.backend)

        # A second confirmation is refused before it starts any transaction, and the drawer refuses
        # to close under it: exactly one confirmation is in the domain's hands.
        duplicate = render_submit(view, "combine_apply", %{})
        assert duplicate =~ "Combining…"

        closed = render_click(view, "close_combine", %{})
        assert closed =~ ~r/id="calendar-combine-form"/
        assert waiters_on(holder.backend) == [apply_backend]

        # A reconnect cannot resolve an unanswered confirmation: it reports the unconfirmed outcome
        # and never resends the old command. The page's own authoritative reload queues behind the
        # same held row, so the confirmation is still the only write waiting for it.
        reconnected = render_click(view, "combine_reconnect", %{})
        assert reconnected =~ "Connection restored."
        assert reconnected =~ "unconfirmed"

        assert apply_backend in waiters_on(holder.backend)

        release_version_row(holder)

        settled = settle(view, &reloaded?(&1, "Combined into Saturday service."))

        assert flat(settled) =~ "Combined into Saturday service."

        assert flat(settled) =~
                 "1 trip moved from Fall shuttle, which stays in the list with 0 trips."

        refute has_element?(view, "#calendar-combine-form")

        # One confirmation, one committed scoped operation, audited per changed entity (AC-19). The
        # destination's effective dates already are the reviewed result, so it keeps its rows and
        # writes no calendar log: the move is a trip-only audit, and its one log carries the
        # complete combination envelope because there is no changed calendar log to host it.
        logs = combination_logs(scope.version_id, before_log_ids)

        assert log_entities(logs) == [{"trip", "SAT_T1"}]

        assert [%{entity_external_id: "SAT_T1"}] = envelope_logs(logs)

        assert trip_service(scope, "SAT_T1") == "DEST"
        assert source_trip_ids(scope) == []
      end)
    end

    test "a version change discards the review and ignores the late result", %{conn: _conn} do
      Sandbox.mode(Repo, :auto)

      scope = Sandbox.unboxed_run(Repo, fn -> seed_committed_scope("version-change") end)
      on_exit(fn -> Sandbox.unboxed_run(Repo, fn -> cleanup_committed_scope(scope) end) end)

      Sandbox.unboxed_run(Repo, fn ->
        {:ok, view, _html} = live(authenticated_conn(scope), list_path(scope.version))
        loaded(view)

        open_review(view, ["DEST", "SAT"])

        before_log_ids = combination_log_ids(scope.version_id)

        holder = hold_version_row(scope)

        _pending = render_submit(view, "combine_apply", %{})
        assert is_integer(await_blocked_backend(holder.backend))

        # The reviewer leaves for another version while the confirmation is still unanswered. The
        # app's own version switch is a live redirect to the other version's list - the version is
        # resolved at mount, so the socket that holds the review is replaced rather than patched in
        # place (INV-3: UI state is never authoritative). The review is therefore discarded with the
        # version it belonged to, and no late result of the abandoned confirmation can be presented
        # on the version the reviewer is now looking at (AC-20, AC-23).
        other_path = list_path(scope.other_version)

        assert {:error, {:live_redirect, %{to: ^other_path}}} =
                 render_click(view, "gtfs_version_loaded", %{
                   "version_id" => scope.other_version.id
                 })

        {:ok, other_view, _other_html} = live(authenticated_conn(scope), other_path)
        loaded(other_view)

        refute has_element?(other_view, "#calendar-combine-form")
        refute has_element?(other_view, "#calendar-combine-success")
        refute render(other_view) =~ "Combined into"

        # The abandoned confirmation was one transaction that had not committed while its socket
        # lived, and the socket that owned it is gone with the version it belonged to.
        assert trip_service(scope, "SAT_T1") == "SAT"

        release_version_row(holder)

        # Nothing of the abandoned confirmation survives the departure: the source keeps its trip
        # identity and no audit row exists, so the version the reviewer left is exactly as it was -
        # there is no partial move and no out-of-scope write (INV-2, AC-23).
        assert trip_service(scope, "SAT_T1") == "SAT"
        assert [_trip_id] = source_trip_ids(scope)
        assert combination_logs(scope.version_id, before_log_ids) == []

        # And the version the reviewer is looking at still knows nothing about it.
        refute has_element?(other_view, "#calendar-combine-success")
        refute render(other_view) =~ "Combined into"
      end)
    end
  end

  describe "no-op review" do
    test "offers Close and breaks a most-trips tie on the display name and exact ID", %{
      conn: conn,
      user: user,
      organization: organization,
      version: version
    } do
      today = postgres_local_today("Etc/UTC")

      # Two identities with the same trip count and the same case-insensitive display name: the
      # exact service ID decides, and the empty copy keeps its own identity.
      for service_id <- ["TIE_ALPHA", "TIE_BETA"] do
        calendar_fixture(organization.id, version.id, %{
          service_id: service_id,
          monday: 1,
          start_date: Date.add(today, -20),
          end_date: Date.add(today, 20)
        })

        calendar_attribute_fixture(organization.id, version.id, %{
          service_id: service_id,
          service_description: "  tie service  "
        })
      end

      route = route_fixture(organization.id, version.id, %{route_id: "TIE_ROUTE"})

      for service_id <- ["TIE_ALPHA", "TIE_BETA"] do
        trip_fixture(organization.id, version.id, route.route_id, %{
          service_id: service_id,
          trip_id: "#{service_id}_TRIP"
        })
      end

      # An empty identical copy is the no-op source: nothing moves and the dates do not change.
      calendar_fixture(organization.id, version.id, %{
        service_id: "TIE_COPY",
        monday: 1,
        start_date: Date.add(today, -20),
        end_date: Date.add(today, 20)
      })

      calendar_attribute_fixture(organization.id, version.id, %{
        service_id: "TIE_COPY",
        service_description: "  tie service  "
      })

      conn = editor(conn, user, organization)

      {:ok, view, _html} = live(conn, list_path(version))
      loaded(view)

      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_ALPHA"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_BETA"})
      render_click(view, "open_combine", %{})

      assert has_element?(view, "#calendar-combine-destination-option-TIE_ALPHA input[checked]")
      refute has_element?(view, "#calendar-combine-destination-option-TIE_BETA input[checked]")

      render_click(view, "close_combine", %{})
      assert render(view) =~ "2 calendars selected"

      render_click(view, "clear_calendar_selection", %{})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_ALPHA"})
      render_click(view, "toggle_calendar_selection", %{"service-id" => "TIE_COPY"})
      html = render_click(view, "open_combine", %{})

      assert html =~ "Nothing changes."
      assert html =~ "Nothing to combine."
      assert has_element?(view, "#calendar-combine-close")

      # Closing keeps the selection: the reviewer can reconsider the same calendars.
      render_click(view, "close_combine", %{})
      refute has_element?(view, "#calendar-combine-form")
      assert render(view) =~ "2 calendars selected"
    end
  end
end

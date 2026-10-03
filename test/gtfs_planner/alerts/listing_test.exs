defmodule GtfsPlanner.Alerts.ListingTest do
  @moduledoc """
  `Alerts.list_alerts/2` groups an organization's alerts into the four tabs and
  derives Needs attention and Check-in due from the stored answers (AC-9, R8).
  Organization ownership and the mixed-zone instants belong to
  `organization_scope_test.exs`.

  `Alerts.workspace/2` resolves every alert against the organization's one active
  schedule, so each case that reads Needs attention builds its rows in the version
  the setup activated.

  Every expectation is a literal from the spec's rules, not a value recomputed by
  the module under test. One UTC instant is passed in and each alert is
  localized in its own retained zone, so no assertion depends on a real clock;
  `agency_now/1` is the one case that reads the clock and asserts only its shape.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer.RouteStopPair
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  # 5 October 17:00 UTC is 5 October 10:00 in the fixture's America/Los_Angeles
  # agency zone, so the existing literal expectations keep reading the same civil
  # day while the command now takes one UTC instant.
  @now_utc ~U[2026-10-05 17:00:00Z]

  @contention_timeout 10_000
  @collect_timeout 15_000
  @race_handler {__MODULE__, :alerts_read_race}

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id)

    # Needs attention is read against the organization's active schedule, so the
    # fixture rows go in the version the workspace resolves against.
    activate_version!(organization, version, actor)

    %{
      organization: organization,
      version: version,
      actor: actor,
      audit: audit_context(organization, version, actor)
    }
  end

  describe "list_alerts/2 grouping" do
    test "an alert that has not answered every question is in progress", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert [row] = tabs.in_progress
      assert row.alert.id == alert.id
      assert tabs.current == []
      assert tabs.upcoming == []
      assert tabs.past == []
    end

    test "a complete open-ended alert is current, not past", context do
      alert = open_ended_delay(context, "2026-10-01", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.current, & &1.alert.id) == [alert.id]
      assert tabs.past == []
    end

    test "a complete alert starting later is upcoming", context do
      alert = open_ended_delay(context, "2026-10-10", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.upcoming, & &1.alert.id) == [alert.id]
      assert tabs.current == []
    end

    test "a complete alert that ended before today is past", context do
      alert = open_ended_delay(context, "2026-10-01", "2026-10-04")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.past, & &1.alert.id) == [alert.id]
      assert tabs.current == []
    end

    test "a complete alert ending today is still current", context do
      alert = open_ended_delay(context, "2026-10-01", "2026-10-05")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.current, & &1.alert.id) == [alert.id]
      assert tabs.past == []
    end

    test "today is the local date, not the UTC date", context do
      # The tabs are grouped on the date of `local_now` itself. An alert that
      # ends on 5 October is Current on the agency-local date 5 October; the
      # same alert grouped on 6 October would be Past.
      alert = open_ended_delay(context, "2026-10-05", "2026-10-05")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.current, & &1.alert.id) == [alert.id]
      assert tabs.past == []

      assert {:ok, later_tabs} =
               Alerts.list_alerts(context.audit, ~U[2026-10-06 17:00:00Z])

      assert Enum.map(later_tabs.past, & &1.alert.id) == [alert.id]
      assert later_tabs.current == []
    end

    test "an alert of another version of the same organization is returned too", context do
      mine = open_ended_delay(context, "2026-10-01", nil)

      other_version = gtfs_version_fixture(context.organization.id)
      agency_fixture(context.organization.id, other_version.id)

      other_audit =
        audit_context(context.organization, other_version, context.actor)

      theirs = open_ended_delay(%{audit: other_audit}, "2026-10-01", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.sort(Enum.map(tabs.current, & &1.alert.id)) ==
               Enum.sort([mine.id, theirs.id])
    end

    test "an alert of another organization is not returned", context do
      mine = open_ended_delay(context, "2026-10-01", nil)

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_actor = editor_fixture(other_organization)
      agency_fixture(other_organization.id, other_version.id)

      _theirs =
        open_ended_delay(
          %{audit: audit_context(other_organization, other_version, other_actor)},
          "2026-10-01",
          nil
        )

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.current, & &1.alert.id) == [mine.id]
    end

    test "refuses a member without the editor role", context do
      _mine = open_ended_delay(context, "2026-10-01", nil)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      audit = audit_context(context.organization, context.version, viewer)

      assert {:error, :forbidden} = Alerts.list_alerts(audit, @now_utc)
      assert {:error, :forbidden} = Alerts.workspace(audit, @now_utc)
    end
  end

  describe "workspace/2" do
    test "returns the active schedule, the tabs, the routes and a diagnostics entry per alert",
         context do
      route =
        route_fixture(context.organization.id, context.version.id, %{
          route_id: "r_1",
          route_short_name: "11"
        })

      named = route_delay(context, route.route_id)
      unnamed = open_ended_delay(context, "2026-10-01", nil)

      assert {:ok, workspace} = Alerts.workspace(context.audit, @now_utc)

      assert {:ok, active} = Versions.active_schedule(context.audit)
      assert workspace.active == active
      assert workspace.active.version.id == context.version.id

      assert Enum.sort(Enum.map(workspace.groups.current, & &1.alert.id)) ==
               Enum.sort([named.id, unnamed.id])

      assert %{"r_1" => %{route_short_name: "11"}} = workspace.routes_by_id
      assert workspace.diagnostics_by_alert == %{named.id => [], unnamed.id => []}
      assert {:ok, workspace.groups} == Alerts.list_alerts(context.audit, @now_utc)
    end

    test "resolves alerts from different source versions against the active schedule once",
         context do
      # `RA` exists in the active version and, under another name, in the sibling.
      # `RB` exists only in the sibling.
      route_fixture(context.organization.id, context.version.id, %{
        route_id: "RA",
        route_short_name: "Active A"
      })

      other = gtfs_version_fixture(context.organization.id)
      agency_fixture(context.organization.id, other.id)
      other_audit = audit_context(context.organization, other, context.actor)

      route_fixture(context.organization.id, other.id, %{
        route_id: "RA",
        route_short_name: "Sibling A"
      })

      route_fixture(context.organization.id, other.id, %{route_id: "RB", route_short_name: "B"})

      in_active = route_delay(context, "RA")
      sibling_only = route_delay(%{audit: other_audit}, "RB")
      sibling_shared = route_delay(%{audit: other_audit}, "RA")

      # The sibling's alerts were written while it was active; the read is judged
      # by the schedule that is active now.
      activate_version!(context.organization, context.version, context.actor)

      assert {:ok, workspace} = Alerts.workspace(context.audit, @now_utc)

      # Only the alert that names a route the active schedule lacks is flagged. The
      # sibling alert that names a route both versions have is judged by the active
      # one, and the sibling's own `RB` cannot clear the alert that names it.
      assert workspace.diagnostics_by_alert[in_active.id] == []
      assert workspace.diagnostics_by_alert[sibling_shared.id] == []

      assert [
               %{
                 kind: :missing,
                 target_type: :route,
                 id: "RB",
                 reason: :not_in_active_schedule,
                 selector: %{route_id: "RB"}
               }
             ] = workspace.diagnostics_by_alert[sibling_only.id]

      attention =
        workspace.groups.current
        |> Enum.filter(& &1.needs_attention?)
        |> Enum.map(& &1.alert.id)

      assert attention == [sibling_only.id]

      # The labels come from the active schedule too, never the sibling's row.
      assert Map.keys(workspace.routes_by_id) == ["RA"]
      assert workspace.routes_by_id["RA"].route_short_name == "Active A"

      # The version the navigation has selected decides nothing.
      assert {:ok, ^workspace} = Alerts.workspace(other_audit, @now_utc)
    end

    test "reads a fixed number of times however many alerts it lists", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_1"})
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})

      queries = fn ->
        {:ok, count} = Agent.start_link(fn -> 0 end)
        handler = {__MODULE__, make_ref()}

        :telemetry.attach(
          handler,
          [:gtfs_planner, :repo, :query],
          fn _event, _measurements, _metadata, count ->
            Agent.update(count, &(&1 + 1))
          end,
          count
        )

        {:ok, _workspace} = Alerts.workspace(context.audit, @now_utc)
        :telemetry.detach(handler)
        Agent.get(count, & &1)
      end

      # One alert of each kind of target, then four more of each: the same reads.
      route_delay(context, route.route_id)
      stop_closure(context, stop.stop_id)
      few = queries.()

      for _alert <- 1..4 do
        route_delay(context, route.route_id)
        stop_closure(context, stop.stop_id)
      end

      assert queries.() == few
    end

    test "an organization with no active schedule lists nothing", context do
      _alert = open_ended_delay(context, "2026-10-01", nil)

      from(o in Organization, where: o.id == ^context.organization.id)
      |> Repo.update_all(set: [active_gtfs_version_id: nil])

      assert {:error, :no_active_schedule} = Alerts.workspace(context.audit, @now_utc)
      assert {:error, :no_active_schedule} = Alerts.list_alerts(context.audit, @now_utc)
    end
  end

  # Each case runs `workspace/2` on its own connection with the production snapshot
  # boundary, because the sandbox transaction cannot change its isolation. The writers
  # take the locks the schedule editors and the active-schedule command take.
  describe "workspace/2 beside concurrent writers" do
    setup do
      previous = Application.get_env(:gtfs_planner, :alerts_read_snapshot)

      on_exit(fn -> Application.put_env(:gtfs_planner, :alerts_read_snapshot, previous) end)

      Application.put_env(:gtfs_planner, :alerts_read_snapshot, Snapshot.Repo)

      %{supervisor: start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})}
    end

    test "an open schedule write does not hold the read up", %{supervisor: supervisor} do
      %{organization: organization, scope: scope, spring: spring, alert: alert} =
        unboxed(&committed_switch_fixture/0)

      on_exit(fn -> unboxed(fn -> delete_committed_scope!([organization.id]) end) end)

      audit = audit_context(organization, spring, %{id: scope.actor_id, email: nil})

      # A schedule writer holds the active version, as the stop and route editors do.
      holder =
        start_holder(supervisor, fn ->
          Versions.lock_for_exclusive_write!(organization.id, spring.id)
        end)

      read = start_command(supervisor, fn -> Alerts.workspace(audit, @now_utc) end)
      send(read.pid, :go)

      assert {:ok, workspace} = Task.await(read.task, @collect_timeout)
      assert [row] = workspace.groups.current
      assert row.alert.id == alert.id

      send(holder.pid, :release)
      assert {:ok, :held} = Task.await(holder.task, @collect_timeout)
    end

    test "writers commit while a read is open, and the read keeps the schedule it started on",
         %{supervisor: supervisor} do
      %{organization: organization, scope: scope, spring: spring, fall: fall, alert: alert} =
        unboxed(&committed_switch_fixture/0)

      on_exit(fn -> unboxed(fn -> delete_committed_scope!([organization.id]) end) end)

      audit = audit_context(organization, spring, %{id: scope.actor_id, email: nil})
      {:ok, %{token: token}} = unboxed(fn -> Versions.active_schedule(scope) end)

      read = start_command(supervisor, fn -> Alerts.workspace(audit, @now_utc) end)
      pause_after_alert_read(self(), read.pid)
      send(read.pid, :go)
      assert_receive {:reader_paused, reader}, @contention_timeout

      # The read has its snapshot and still has the routes and stops to read. Neither
      # an input writer's version lock, a rename of the route the alert names nor the
      # switch to the other schedule waits for it.
      input_writer =
        start_command(supervisor, fn ->
          Repo.transaction(fn -> Versions.lock_for_input_write!(organization.id, spring.id) end)
        end)

      rename =
        start_command(supervisor, fn ->
          Repo.update_all(
            from(r in Route, where: r.gtfs_version_id == ^spring.id and r.route_id == "R1"),
            set: [route_short_name: "Renamed"]
          )
        end)

      switch =
        start_command(supervisor, fn -> Versions.set_active_schedule(scope, fall.id, token) end)

      for command <- [input_writer, rename, switch], do: send(command.pid, :go)

      assert {:ok, %GtfsVersion{}} = Task.await(input_writer.task, @collect_timeout)
      assert {1, nil} = Task.await(rename.task, @collect_timeout)
      assert {:ok, %{token: %{revision: switched}}} = Task.await(switch.task, @collect_timeout)

      send(reader, :resume_query)
      assert {:ok, workspace} = Task.await(read.task, @collect_timeout)

      # Tabs, labels and diagnostics all come from the state that was committed when the
      # read began, though three writes committed before it returned.
      assert workspace.active.version.id == spring.id
      assert workspace.active.token.revision == switched - 1
      assert [row] = workspace.groups.current
      assert row.alert.id == alert.id
      assert row.needs_attention? == false
      assert workspace.routes_by_id["R1"].route_short_name == "Spring 1"
      assert workspace.diagnostics_by_alert == %{alert.id => []}

      # The next read is entirely the new schedule's.
      assert {:ok, after_switch} = unboxed(fn -> Alerts.workspace(audit, @now_utc) end)

      assert after_switch.active.version.id == fall.id
      assert [after_row] = after_switch.groups.current
      assert after_row.needs_attention? == true
      assert after_switch.routes_by_id == %{}
      assert [%{kind: :missing, id: "R1"}] = after_switch.diagnostics_by_alert[alert.id]
    end

    test "a revocation in flight does not hold the read up, and the next read is refused", %{
      supervisor: supervisor
    } do
      %{organization: organization, scope: scope, spring: spring} =
        unboxed(&committed_switch_fixture/0)

      on_exit(fn -> unboxed(fn -> delete_committed_scope!([organization.id]) end) end)

      admin = unboxed(fn -> admin_for(organization) end)
      audit = audit_context(organization, spring, %{id: scope.actor_id, email: nil})

      # A membership command takes the organization row, then the member's row, and
      # revokes the editor in the same transaction.
      command =
        start_holder(
          supervisor,
          fn -> Authorization.lock_member_admin!(admin, organization.id) end,
          fn -> revoke_editor(scope.actor_id, organization.id) end
        )

      read = start_command(supervisor, fn -> Alerts.workspace(audit, @now_utc) end)
      send(read.pid, :go)

      # The revocation has not committed, so the editor is still one.
      assert {:ok, _workspace} = Task.await(read.task, @collect_timeout)

      send(command.pid, :release)
      assert {:ok, :held} = Task.await(command.task, @collect_timeout)

      assert {:error, :forbidden} = unboxed(fn -> Alerts.workspace(audit, @now_utc) end)
    end
  end

  describe "list_alerts/2 ordering" do
    test "current and upcoming read forward by first date", context do
      later = open_ended_delay(context, "2026-10-02", nil)
      earlier = open_ended_delay(context, "2026-10-01", nil)
      latest = open_ended_delay(context, "2026-10-03", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.current, & &1.alert.id) == [earlier.id, later.id, latest.id]
    end

    test "in progress reads most recently changed first", context do
      first = alert_fixture(context.audit, %{"urgency" => "now"})
      second = alert_fixture(context.audit, %{"urgency" => "now"})
      third = alert_fixture(context.audit, %{"urgency" => "now"})

      {:ok, saved} =
        Alerts.save_draft(context.audit, first.id, first.revision, %{"cause" => "weather"})

      {:ok, _saved} =
        Alerts.save_draft(context.audit, second.id, second.revision, %{"cause" => "weather"})

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      # `second` was saved last and leads, `first` follows, and `third` was only
      # created, so it keeps the earliest timestamp.
      assert saved.revision == 2

      assert Enum.map(tabs.in_progress, & &1.alert.id) == [second.id, first.id, third.id]
    end

    test "past reads most recently ended first", context do
      ended_earlier = open_ended_delay(context, "2026-10-01", "2026-10-02")
      ended_later = open_ended_delay(context, "2026-10-01", "2026-10-04")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)

      assert Enum.map(tabs.past, & &1.alert.id) == [ended_later.id, ended_earlier.id]
    end
  end

  # `Date` and `DateTime` structs compare field by field under the default term
  # sorter, so these cases use values that order differently by calendar and by
  # field: a month boundary, and two instants in one hour whose microseconds are
  # reversed against their minutes. The alerts are in-memory structs, so no row
  # shape is invented beyond the fields `Listing.rows/3` reads.
  describe "Listing.rows/3 ordering" do
    test "upcoming reads forward across a month boundary" do
      november = in_memory(first_date: ~D[2026-11-02])
      october = in_memory(first_date: ~D[2026-10-30])

      tabs = Listing.rows([november, october], @now_utc)

      assert Enum.map(tabs.upcoming, & &1.alert.id) == [october.id, november.id]
    end

    test "past reads most recently ended first across a month boundary" do
      september = in_memory(first_date: ~D[2026-09-01], last_date: ~D[2026-09-30])
      october = in_memory(first_date: ~D[2026-09-01], last_date: ~D[2026-10-02])

      tabs = Listing.rows([september, october], @now_utc)

      assert Enum.map(tabs.past, & &1.alert.id) == [october.id, september.id]
    end

    test "in progress reads the later minute first when its microseconds are earlier" do
      earlier = in_memory(complete: false, updated_at: ~U[2026-10-05 10:00:00.900000Z])
      later = in_memory(complete: false, updated_at: ~U[2026-10-05 10:25:00.100000Z])

      tabs = Listing.rows([earlier, later], @now_utc)

      assert Enum.map(tabs.in_progress, & &1.alert.id) == [later.id, earlier.id]
    end
  end

  describe "Listing.referenced_ids/1" do
    test "names a route once however many of its stops the alert pairs it with" do
      alert =
        in_memory(
          scope: %ScopeAnswer{
            route_ids: ["route-14"],
            route_stop_pairs: [
              %RouteStopPair{route_id: "route-14", stop_id: "stop-a"},
              %RouteStopPair{route_id: "route-14", stop_id: "stop-b"},
              %RouteStopPair{route_id: "route-14", stop_id: "stop-c"}
            ]
          }
        )

      assert Listing.referenced_ids(alert).routes == ["route-14"]
      assert Listing.referenced_ids(alert).stops == ["stop-a", "stop-b", "stop-c"]
    end
  end

  describe "list_alerts/2 needs attention" do
    test "a stop deleted from the version is flagged and the scope still holds its feed ID",
         context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})
      _alert = stop_closure(context, stop.stop_id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.needs_attention? == false

      delete!(GtfsPlanner.Gtfs.Stop, stop.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.needs_attention? == true
      assert row.alert.scope.stop_ids == ["s_1"]
    end

    test "a route deleted from the version is flagged", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_1"})
      _alert = route_delay(context, route.route_id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.needs_attention? == false

      delete!(GtfsPlanner.Gtfs.Route, route.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.needs_attention? == true
      assert row.alert.scope.route_ids == ["r_1"]
    end

    test "a stop that now belongs to another version does not satisfy an alert's target",
         context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})
      _alert = stop_closure(context, stop.stop_id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.needs_attention? == false

      # The row moves to a sibling version of the same organization, so the
      # alert's feed ID resolves nowhere in its own version.
      other_version = gtfs_version_fixture(context.organization.id)

      {1, _rows} =
        Repo.update_all(
          from(s in GtfsPlanner.Gtfs.Stop, where: s.id == ^stop.id),
          set: [gtfs_version_id: other_version.id]
        )

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.needs_attention? == true
    end

    test "a cancelled trip deleted from the version is flagged", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_1"})

      # The alert's service date is a Monday and the fixture calendar runs Monday
      # to Friday, so the trip is on its date until it is deleted.
      calendar_fixture(context.organization.id, context.version.id, %{service_id: "weekday"})

      trip =
        trip_fixture(context.organization.id, context.version.id, route.route_id, %{
          service_id: "weekday"
        })

      _alert = cancellation(context, route.route_id, trip.trip_id)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @now_utc)
      assert [row] = tabs.current
      assert row.needs_attention? == false

      delete!(GtfsPlanner.Gtfs.Trip, trip.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.needs_attention? == true
    end

    test "an alert that names no target is never flagged", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, %{in_progress: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.alert.id == alert.id
      assert row.needs_attention? == false
    end
  end

  describe "list_alerts/2 check-in due" do
    test "a check-in time at or before the agency-local now is due", context do
      alert = open_ended_delay(context, "2026-10-01", nil, "2026-10-05 09:00:00")

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.check_in_due? == true
      assert row.alert.id == alert.id
    end

    test "a check-in exactly at the agency-local now is due", context do
      _alert = open_ended_delay(context, "2026-10-01", nil, "2026-10-05 10:00:00")

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.check_in_due? == true
    end

    test "a later check-in is not yet due", context do
      _alert = open_ended_delay(context, "2026-10-01", nil, "2026-10-05 11:00:00")

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.check_in_due? == false
    end

    test "an alert with no check-in time is never due", context do
      # A confirmed end expires the alert, so completion needs no check-in for
      # it and the timing answer stores none.
      _alert = open_ended_delay(context, "2026-10-01", "2026-10-06", nil)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @now_utc)
      assert row.check_in_due? == false
    end
  end

  describe "agency_now/1" do
    test "returns the agency's current civil time as a naive value", context do
      # The zone this version's agency declares is a real zone, and the value is
      # the current instant expressed in it: reading it back through the same
      # zone a moment later moves by no more than a couple of seconds.
      local_now = Alerts.agency_now(context.audit)

      assert %NaiveDateTime{} = local_now
      assert NaiveDateTime.diff(Alerts.agency_now(context.audit), local_now) in 0..2

      resolution = DisplayClock.resolve_zone(context.organization.id, context.version.id)

      assert resolution.timezone == "America/Los_Angeles"
      assert resolution.fallback? == false
    end
  end

  # -- Fixtures ------------------------------------------------------------
  # Every alert is built through `create_alert/2` and finished through
  # `save_draft/4`, so no test row carries a field the editor path cannot write.

  # A complete current alert. An alert whose end is confirmed carries that
  # date; an open-ended one (`end_date` nil) uses the estimated end, which
  # completion requires a check-in time for, so `check_in_at` defaults to a time
  # after the fixed local now and is never due unless a case sets it earlier.
  defp open_ended_delay(context, start_date, end_date, check_in_at \\ "2026-10-06 09:00:00") do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "delay",
        "cause" => "weather",
        "scope" => %{"shape" => "system"},
        "message" => message()
      })

    timing = %{
      "start_date" => start_date,
      "start_time" => "08:00:00",
      "end_kind" => if(end_date, do: "confirmed", else: "estimated"),
      "end_date" => end_date,
      "check_in_at" => check_in_at
    }

    save!(context.audit, alert, %{"timing" => timing})
  end

  # Committed rows for the interleaving case: its holder, read and switch each run
  # on their own connection and must see the same data. `R1` is in the spring
  # version the alert names and the first active schedule, and absent from fall.
  defp committed_switch_fixture do
    organization = organization_fixture()
    actor = editor_fixture(organization)
    spring = gtfs_version_fixture(organization.id, %{name: "Spring"})
    fall = gtfs_version_fixture(organization.id, %{name: "Fall"})
    agency_fixture(organization.id, spring.id)
    agency_fixture(organization.id, fall.id)

    route_fixture(organization.id, spring.id, %{route_id: "R1", route_short_name: "Spring 1"})
    activate_version!(organization, spring, actor)

    audit = audit_context(organization, spring, actor)
    alert = route_delay(%{audit: audit}, "R1")

    %{
      organization: organization,
      scope: %{actor_id: actor.id, organization_id: organization.id},
      spring: spring,
      fall: fall,
      alert: alert
    }
  end

  # A command parked on its own connection until `:go`.
  defp start_command(supervisor, command) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          send(parent, {:ready, self(), backend_pid()})

          receive do
            :go -> :ok
          after
            @contention_timeout -> raise "command was not released"
          end

          command.()
        end)
      end)

    assert_receive {:ready, pid, backend}, @contention_timeout
    %{task: task, pid: pid, backend: backend}
  end

  # A transaction that holds what `acquire` locks until `:release`, then runs
  # `finish` in the same transaction before it commits.
  defp start_holder(supervisor, acquire, finish \\ fn -> :ok end) do
    parent = self()

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn -> hold(parent, acquire, finish) end)
      end)

    assert_receive {:held, pid, backend}, @contention_timeout
    %{task: task, pid: pid, backend: backend}
  end

  defp hold(parent, acquire, finish) do
    Repo.transaction(fn ->
      acquire.()
      send(parent, {:held, self(), backend_pid()})

      receive do
        :release -> :ok
      after
        @contention_timeout -> raise "holder was not released"
      end

      finish.()
      :held
    end)
  end

  # Parks the reader inside its transaction once the alert rows are read and before the
  # routes and stops are, until it is sent `:resume_query`.
  defp pause_after_alert_read(owner, reader_pid) do
    :telemetry.attach(
      @race_handler,
      [:gtfs_planner, :repo, :query],
      fn _event, _measurements, metadata, {owner, reader} ->
        if self() == reader and
             String.contains?(to_string(metadata[:query]), ~s(FROM "service_alerts")) do
          :telemetry.detach(@race_handler)
          send(owner, {:reader_paused, self()})

          receive do
            :resume_query -> :ok
          after
            @contention_timeout -> :ok
          end
        end
      end,
      {owner, reader_pid}
    )

    on_exit(fn -> :telemetry.detach(@race_handler) end)
  end

  defp admin_for(organization) do
    admin = user_fixture()
    organization_membership_fixture(admin, organization, ["pathways_studio_admin"])
    admin
  end

  defp revoke_editor(actor_id, organization_id) do
    Repo.update_all(
      from(m in UserOrgMembership,
        where: m.user_id == ^actor_id and m.organization_id == ^organization_id
      ),
      set: [deactivated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  defp stop_closure(context, stop_id) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "stop_closed",
        "cause" => "construction",
        "scope" => %{"shape" => "stop_all_routes", "stop_ids" => [stop_id]},
        "message" => message()
      })

    save!(context.audit, alert, %{"timing" => now_timing()})
  end

  defp route_delay(context, route_id) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "delay",
        "cause" => "weather",
        "scope" => %{"shape" => "routes", "route_ids" => [route_id]},
        "message" => message()
      })

    save!(context.audit, alert, %{"timing" => now_timing()})
  end

  defp cancellation(context, route_id, trip_id) do
    alert =
      alert_fixture(context.audit, %{
        "urgency" => "now",
        "situation" => "cancelled_trips",
        "cause" => "weather",
        "scope" => %{
          "shape" => "trips",
          "route_ids" => [route_id],
          "trips" => [%{"trip_id" => trip_id, "service_date" => "2026-10-05"}]
        },
        "message" => message()
      })

    save!(context.audit, alert, %{})
  end

  defp now_timing do
    %{
      "start_date" => "2026-10-05",
      "start_time" => "08:00:00",
      "end_kind" => "estimated",
      "check_in_at" => "2026-10-06 09:00:00"
    }
  end

  defp message do
    %{
      "header" => "Route 1 buses delayed",
      "description" => "Water main work on Main St. Use Route 2 instead."
    }
  end

  # A complete alert as `Listing.rows/3` reads it, without a stored row.
  defp in_memory(fields) do
    struct!(
      Alert,
      Map.merge(
        %{id: Ecto.UUID.generate(), complete: true, first_date: nil, last_date: nil},
        Map.new(fields)
      )
    )
  end

  defp save!(audit, alert, attrs) do
    assert {:ok, saved} = Alerts.save_draft(audit, alert.id, alert.revision, attrs)
    saved
  end

  # The version edit a Needs attention row comes from. `Repo.delete/2` needs the
  # loaded struct, so the row is read back before it is removed.
  defp delete!(schema, id) do
    schema |> Repo.get!(id) |> Repo.delete!()
  end

  defp audit_context(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end
end

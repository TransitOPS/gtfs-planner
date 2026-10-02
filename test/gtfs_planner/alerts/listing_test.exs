defmodule GtfsPlanner.Alerts.ListingTest do
  @moduledoc """
  Step 7: `Alerts.list_alerts/2` groups a version's alerts into the four tabs and
  derives Needs attention and Check-in due from the stored answers (AC-9, R8).

  Every expectation is a literal from the spec's rules, not a value recomputed by
  the module under test. The agency-local time is passed in as a fixed
  `NaiveDateTime`, so no assertion depends on a real clock; `agency_now/1` is the
  one case that reads the clock and asserts only its shape.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Listing
  alias GtfsPlanner.Alerts.ScopeAnswer
  alias GtfsPlanner.Alerts.ScopeAnswer.RouteStopPair
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.DisplayClock

  @local_now ~N[2026-10-05 10:00:00]

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    agency_fixture(organization.id, version.id)

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

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert [row] = tabs.in_progress
      assert row.alert.id == alert.id
      assert tabs.current == []
      assert tabs.upcoming == []
      assert tabs.past == []
    end

    test "a complete open-ended alert is current, not past", context do
      alert = open_ended_delay(context, "2026-10-01", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert Enum.map(tabs.current, & &1.alert.id) == [alert.id]
      assert tabs.past == []
    end

    test "a complete alert starting later is upcoming", context do
      alert = open_ended_delay(context, "2026-10-10", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert Enum.map(tabs.upcoming, & &1.alert.id) == [alert.id]
      assert tabs.current == []
    end

    test "a complete alert that ended before today is past", context do
      alert = open_ended_delay(context, "2026-10-01", "2026-10-04")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert Enum.map(tabs.past, & &1.alert.id) == [alert.id]
      assert tabs.current == []
    end

    test "a complete alert ending today is still current", context do
      alert = open_ended_delay(context, "2026-10-01", "2026-10-05")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert Enum.map(tabs.current, & &1.alert.id) == [alert.id]
      assert tabs.past == []
    end

    test "today is the local date, not the UTC date", context do
      # The tabs are grouped on the date of `local_now` itself. An alert that
      # ends on 5 October is Current on the agency-local date 5 October; the
      # same alert grouped on 6 October would be Past.
      alert = open_ended_delay(context, "2026-10-05", "2026-10-05")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert Enum.map(tabs.current, & &1.alert.id) == [alert.id]
      assert tabs.past == []

      assert {:ok, later_tabs} =
               Alerts.list_alerts(context.audit, ~N[2026-10-06 10:00:00])

      assert Enum.map(later_tabs.past, & &1.alert.id) == [alert.id]
      assert later_tabs.current == []
    end

    test "an alert of another version of the same organization is not returned", context do
      mine = open_ended_delay(context, "2026-10-01", nil)

      other_version = gtfs_version_fixture(context.organization.id)
      agency_fixture(context.organization.id, other_version.id)

      other_audit =
        audit_context(context.organization, other_version, context.actor)

      _theirs = open_ended_delay(%{audit: other_audit}, "2026-10-01", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert Enum.map(tabs.current, & &1.alert.id) == [mine.id]
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

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      assert Enum.map(tabs.current, & &1.alert.id) == [mine.id]
    end

    test "refuses a member without the editor role", context do
      _mine = open_ended_delay(context, "2026-10-01", nil)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      audit = audit_context(context.organization, context.version, viewer)

      assert {:error, :forbidden} = Alerts.list_alerts(audit, @local_now)
    end
  end

  describe "list_alerts/2 ordering" do
    test "current and upcoming read forward by first date", context do
      later = open_ended_delay(context, "2026-10-02", nil)
      earlier = open_ended_delay(context, "2026-10-01", nil)
      latest = open_ended_delay(context, "2026-10-03", nil)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

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

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

      # `second` was saved last and leads, `first` follows, and `third` was only
      # created, so it keeps the earliest timestamp.
      assert saved.revision == 2

      assert Enum.map(tabs.in_progress, & &1.alert.id) == [second.id, first.id, third.id]
    end

    test "past reads most recently ended first", context do
      ended_earlier = open_ended_delay(context, "2026-10-01", "2026-10-02")
      ended_later = open_ended_delay(context, "2026-10-01", "2026-10-04")

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)

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

      tabs = Listing.rows([november, october], Ecto.UUID.generate(), @local_now)

      assert Enum.map(tabs.upcoming, & &1.alert.id) == [october.id, november.id]
    end

    test "past reads most recently ended first across a month boundary" do
      september = in_memory(first_date: ~D[2026-09-01], last_date: ~D[2026-09-30])
      october = in_memory(first_date: ~D[2026-09-01], last_date: ~D[2026-10-02])

      tabs = Listing.rows([september, october], Ecto.UUID.generate(), @local_now)

      assert Enum.map(tabs.past, & &1.alert.id) == [october.id, september.id]
    end

    test "in progress reads the later minute first when its microseconds are earlier" do
      earlier = in_memory(complete: false, updated_at: ~U[2026-10-05 10:00:00.900000Z])
      later = in_memory(complete: false, updated_at: ~U[2026-10-05 10:25:00.100000Z])

      tabs = Listing.rows([earlier, later], Ecto.UUID.generate(), @local_now)

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
    test "a stop deleted from the version is flagged and the scope still holds its UUID",
         context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})
      _alert = stop_closure(context, stop.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.needs_attention? == false

      delete!(GtfsPlanner.Gtfs.Stop, stop.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.needs_attention? == true
      assert row.alert.scope.stop_ids == [stop.id]
    end

    test "a route deleted from the version is flagged", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_1"})
      _alert = route_delay(context, route.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.needs_attention? == false

      delete!(GtfsPlanner.Gtfs.Route, route.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.needs_attention? == true
      assert row.alert.scope.route_ids == [route.id]
    end

    test "a stop that now belongs to another version does not satisfy an alert's target",
         context do
      stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})
      _alert = stop_closure(context, stop.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.needs_attention? == false

      # The row keeps its UUID and moves to a sibling version of the same
      # organization, so the alert's identity resolves nowhere in its own version.
      other_version = gtfs_version_fixture(context.organization.id)

      {1, _rows} =
        Repo.update_all(
          from(s in GtfsPlanner.Gtfs.Stop, where: s.id == ^stop.id),
          set: [gtfs_version_id: other_version.id]
        )

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.needs_attention? == true
    end

    test "a cancelled trip deleted from the version is flagged", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_1"})
      trip = trip_fixture(context.organization.id, context.version.id, route.id)

      _alert = cancellation(context, route.id, trip.id)

      assert {:ok, tabs} = Alerts.list_alerts(context.audit, @local_now)
      assert [row] = tabs.current
      assert row.needs_attention? == false

      delete!(GtfsPlanner.Gtfs.Trip, trip.id)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.needs_attention? == true
    end

    test "an alert that names no target is never flagged", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, %{in_progress: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.alert.id == alert.id
      assert row.needs_attention? == false
    end
  end

  describe "list_alerts/2 check-in due" do
    test "a check-in time at or before the agency-local now is due", context do
      alert = open_ended_delay(context, "2026-10-01", nil, "2026-10-05 09:00:00")

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.check_in_due? == true
      assert row.alert.id == alert.id
    end

    test "a check-in exactly at the agency-local now is due", context do
      _alert = open_ended_delay(context, "2026-10-01", nil, "2026-10-05 10:00:00")

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.check_in_due? == true
    end

    test "a later check-in is not yet due", context do
      _alert = open_ended_delay(context, "2026-10-01", nil, "2026-10-05 11:00:00")

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
      assert row.check_in_due? == false
    end

    test "an alert with no check-in time is never due", context do
      # A confirmed end expires the alert, so completion needs no check-in for
      # it and the timing answer stores none.
      _alert = open_ended_delay(context, "2026-10-01", "2026-10-06", nil)

      assert {:ok, %{current: [row]}} = Alerts.list_alerts(context.audit, @local_now)
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

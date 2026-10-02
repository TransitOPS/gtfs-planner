defmodule GtfsPlanner.AlertsTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.AlertsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts
  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Completion
  alias GtfsPlanner.Alerts.Recurrence
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo

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

  describe "create_alert/2" do
    test "inserts revision 1 in the context's organization and version", context do
      assert {:ok, alert} = Alerts.create_alert(context.audit, %{"urgency" => "now"})

      assert alert.revision == 1
      assert alert.organization_id == context.organization.id
      assert alert.source_gtfs_version_id == context.version.id
      assert alert.created_by_id == context.actor.id
      assert alert.updated_by_id == context.actor.id
      assert alert.urgency == :now
      assert alert.complete == false
      assert alert.effect == nil
    end

    test "resolves the timing time zone from the version's agency", context do
      {:ok, alert} = Alerts.create_alert(context.audit, %{"urgency" => "now"})

      assert alert.timing.time_zone == "America/Los_Angeles"
    end

    test "ignores identity, revision and derived fields sent as attributes", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(context.organization.id)

      attrs = %{
        "urgency" => "now",
        "organization_id" => other_organization.id,
        "source_gtfs_version_id" => other_version.id,
        "revision" => 99,
        "complete" => true,
        "effect" => "no_service",
        "first_date" => "2020-01-01",
        "last_date" => "2020-01-31",
        "created_by_id" => Ecto.UUID.generate(),
        "updated_by_id" => Ecto.UUID.generate()
      }

      assert {:ok, alert} = Alerts.create_alert(context.audit, attrs)

      assert alert.organization_id == context.organization.id
      assert alert.source_gtfs_version_id == context.version.id
      assert alert.revision == 1
      assert alert.complete == false
      assert alert.effect == nil
      assert alert.first_date == nil
      assert alert.last_date == nil
      assert alert.created_by_id == context.actor.id
      assert alert.updated_by_id == context.actor.id
    end

    test "cannot move an alert's times into another zone", context do
      attrs = %{"urgency" => "now", "timing" => %{"time_zone" => "Asia/Tokyo"}}

      assert {:ok, alert} = Alerts.create_alert(context.audit, attrs)

      assert alert.timing.time_zone == "America/Los_Angeles"
    end

    test "returns an invalid changeset without inserting a row", context do
      attrs = %{"urgency" => "now", "message" => %{"header" => String.duplicate("a", 121)}}

      assert {:error, %Ecto.Changeset{} = changeset} = Alerts.create_alert(context.audit, attrs)

      assert %{message: %{header: [_ | _]}} = nested_errors(changeset)
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "refuses a deactivated member and inserts nothing", context do
      membership = Repo.get_by(GtfsPlanner.Accounts.UserOrgMembership, user_id: context.actor.id)
      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} = Alerts.create_alert(context.audit, %{"urgency" => "now"})
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "refuses a member without the editor role and inserts nothing", context do
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])
      audit = audit_context(context.organization, context.version, viewer)

      assert {:error, :forbidden} = Alerts.create_alert(audit, %{"urgency" => "now"})
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "refuses an editor of another organization and inserts nothing", context do
      other_actor = editor_fixture(organization_fixture())
      audit = audit_context(context.organization, context.version, other_actor)

      assert {:error, :forbidden} = Alerts.create_alert(audit, %{"urgency" => "now"})
      assert Repo.aggregate(Alert, :count) == 0
    end

    test "stores a route, stop and departure of the context's own version", context do
      %{route: route, stop: stop, trip: trip} = version_targets(context)

      attrs = %{
        "urgency" => "now",
        "scope" => %{
          "shape" => "route_stops",
          "route_ids" => [route.id],
          "stop_ids" => [stop.id],
          "trips" => [%{"trip_id" => trip.id, "service_date" => "2026-10-05"}]
        }
      }

      assert {:ok, alert} = Alerts.create_alert(context.audit, attrs)
      assert alert.scope.route_ids == [route.id]
      assert alert.scope.stop_ids == [stop.id]
    end

    test "refuses a stop of another version and inserts nothing", context do
      other_version = gtfs_version_fixture(context.organization.id)
      stop = stop_fixture(context.organization.id, other_version.id)

      attrs = %{"urgency" => "now", "scope" => %{"stop_ids" => [stop.id]}}

      assert {:error, %Ecto.Changeset{} = changeset} = Alerts.create_alert(context.audit, attrs)
      assert %{scope: ["Choose stops from this version."]} = nested_errors(changeset)
      assert Repo.aggregate(Alert, :count) == 0
    end
  end

  describe "get_alert/2" do
    test "returns the context's own alert", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, found} = Alerts.get_alert(context.audit, alert.id)
      assert found.id == alert.id
    end

    test "refuses a deactivated member", context do
      alert = alert_fixture(context.audit)
      membership = Repo.get_by(GtfsPlanner.Accounts.UserOrgMembership, user_id: context.actor.id)
      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} = Alerts.get_alert(context.audit, alert.id)
    end

    test "refuses a member without the editor role", context do
      alert = alert_fixture(context.audit)

      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      assert {:error, :forbidden} =
               Alerts.get_alert(
                 audit_context(context.organization, context.version, viewer),
                 alert.id
               )
    end

    test "refuses a member of another organization", context do
      alert = alert_fixture(context.audit)

      # An editor of another organization holds no membership in this one.
      other_actor = editor_fixture(organization_fixture())
      audit = audit_context(context.organization, context.version, other_actor)

      assert {:error, :forbidden} = Alerts.get_alert(audit, alert.id)
    end

    test "does not find an alert of another organization or another version", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_actor = editor_fixture(other_organization)

      foreign_alert = alert_fixture(audit_context(other_organization, other_version, other_actor))

      other_version_same_org = gtfs_version_fixture(context.organization.id)

      same_org_alert =
        alert_fixture(audit_context(context.organization, other_version_same_org, context.actor))

      assert {:error, :not_found} = Alerts.get_alert(context.audit, foreign_alert.id)
      assert {:error, :not_found} = Alerts.get_alert(context.audit, same_org_alert.id)
      assert {:error, :not_found} = Alerts.get_alert(context.audit, Ecto.UUID.generate())
      assert {:error, :not_found} = Alerts.get_alert(context.audit, "not-a-uuid")
    end
  end

  describe "save_draft/4" do
    test "increments the revision and derives the effect at the current revision", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, saved} =
               Alerts.save_draft(context.audit, alert.id, 1, %{"situation" => "delay"})

      assert saved.id == alert.id
      assert saved.revision == 2
      assert saved.situation == :delay
      assert saved.effect == :significant_delays
      assert saved.updated_by_id == context.actor.id
    end

    test "refuses an older revision and leaves the row unchanged", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})
      {:ok, _saved} = Alerts.save_draft(context.audit, alert.id, 1, %{"situation" => "delay"})

      assert {:error, :stale, %Alert{revision: 2} = current} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "situation" => "detour",
                 "message" => %{"header" => "Bus detour"}
               })

      assert current.revision == 2

      reloaded = Repo.get!(Alert, alert.id)

      assert reloaded.revision == 2
      assert reloaded.situation == :delay
      assert reloaded.effect == :significant_delays
      assert is_nil(reloaded.message.header)
    end

    test "returns an invalid changeset and keeps the revision", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "situation" => "delay",
                 "message" => %{"header" => String.duplicate("a", 121)}
               })

      assert %{message: %{header: [_ | _]}} = nested_errors(changeset)

      reloaded = Repo.get!(Alert, alert.id)

      assert reloaded.revision == 1
      assert is_nil(reloaded.situation)
      assert is_nil(reloaded.effect)
    end

    test "keeps the agency time zone the create resolved", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, saved} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "situation" => "delay",
                 "timing" => %{
                   "start_date" => "2026-10-05",
                   "start_time" => "20:00:00",
                   "time_zone" => "Asia/Tokyo"
                 }
               })

      assert saved.timing.time_zone == "America/Los_Angeles"
      assert saved.timing.start_date == ~D[2026-10-05]
    end

    test "marks a fully answered planned alert complete with its derived dates", context do
      route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_1"})

      alert = alert_fixture(context.audit)

      attrs = weekly_delay_attrs(route.id)

      assert {:ok, saved} = Alerts.save_draft(context.audit, alert.id, 1, attrs)

      assert saved.revision == 2
      assert saved.complete == true
      assert saved.effect == :significant_delays
      assert Completion.errors(saved) == []

      expected = Recurrence.date_range(saved)

      assert expected == {~D[2026-10-05], ~D[2026-10-16]}
      assert saved.first_date == elem(expected, 0)
      assert saved.last_date == elem(expected, 1)
    end

    test "refuses a route, stop or departure that is not in the alert's version", context do
      other_version = gtfs_version_fixture(context.organization.id)
      foreign_stop = stop_fixture(context.organization.id, other_version.id)
      foreign_route = route_fixture(context.organization.id, other_version.id)
      alert = alert_fixture(context.audit)
      stored = Repo.get!(Alert, alert.id)

      for {scope, message} <- [
            {%{"stop_ids" => [foreign_stop.id]}, "Choose stops from this version."},
            {%{"route_ids" => [foreign_route.id]}, "Choose routes from this version."},
            {%{"route_ids" => ["12"]}, "Choose routes from this version."},
            {%{"route_ids" => [Ecto.UUID.generate()]}, "Choose routes from this version."},
            {%{"stretch_from_stop_id" => foreign_stop.id}, "Choose stops from this version."},
            {%{"route_stop_pairs" => [%{"route_id" => "x", "stop_id" => foreign_stop.id}]},
             "Choose routes from this version."},
            {%{"trips" => [%{"trip_id" => Ecto.UUID.generate(), "service_date" => "2026-10-05"}]},
             "Choose departures from this version."}
          ] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Alerts.save_draft(context.audit, alert.id, 1, %{"scope" => scope})

        assert message in nested_errors(changeset).scope
      end

      reloaded = Repo.get!(Alert, alert.id)
      assert reloaded.revision == 1
      assert reloaded.scope == stored.scope
    end

    test "refuses a route type the version does not contain", context do
      route_fixture(context.organization.id, context.version.id, %{route_type: 3})
      alert = alert_fixture(context.audit)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "scope" => %{"shape" => "routes", "mode_route_type" => 1}
               })

      assert %{scope: ["Choose a route type this version has."]} = nested_errors(changeset)

      assert {:ok, saved} =
               Alerts.save_draft(context.audit, alert.id, 1, %{
                 "scope" => %{"shape" => "routes", "mode_route_type" => 3}
               })

      assert saved.scope.mode_route_type == 3
    end

    test "keeps a target the version has since lost and still saves other answers", context do
      %{route: route} = version_targets(context)
      alert = alert_fixture(context.audit, %{"scope" => %{"route_ids" => [route.id]}})
      Repo.delete!(route)

      assert {:ok, saved} =
               Alerts.save_draft(context.audit, alert.id, 1, %{"situation" => "delay"})

      assert saved.scope.route_ids == [route.id]
    end

    test "refuses a deactivated member", context do
      alert = alert_fixture(context.audit)

      membership = Repo.get_by(GtfsPlanner.Accounts.UserOrgMembership, user_id: context.actor.id)
      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} =
               Alerts.save_draft(context.audit, alert.id, 1, %{"situation" => "delay"})

      assert Repo.get!(Alert, alert.id).revision == 1
    end

    test "refuses a member without the editor role", context do
      alert = alert_fixture(context.audit)
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      audit = audit_context(context.organization, context.version, viewer)

      assert {:error, :forbidden} =
               Alerts.save_draft(audit, alert.id, 1, %{"situation" => "delay"})

      assert Repo.get!(Alert, alert.id).revision == 1
    end

    test "refuses a member of another organization", context do
      alert = alert_fixture(context.audit)

      other_actor = editor_fixture(organization_fixture())
      audit = audit_context(context.organization, context.version, other_actor)

      assert {:error, :forbidden} =
               Alerts.save_draft(audit, alert.id, 1, %{"situation" => "delay"})

      assert Repo.get!(Alert, alert.id).revision == 1
    end

    test "does not save an alert of another organization or another version", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_actor = editor_fixture(other_organization)
      foreign_alert = alert_fixture(audit_context(other_organization, other_version, other_actor))

      other_version_same_org = gtfs_version_fixture(context.organization.id)

      same_org_alert =
        alert_fixture(audit_context(context.organization, other_version_same_org, context.actor))

      for alert_id <- [foreign_alert.id, same_org_alert.id, Ecto.UUID.generate(), "not-a-uuid"] do
        assert {:error, :not_found} =
                 Alerts.save_draft(context.audit, alert_id, 1, %{"situation" => "delay"})
      end

      assert Repo.get!(Alert, foreign_alert.id).revision == 1
      assert Repo.get!(Alert, same_org_alert.id).revision == 1
    end
  end

  describe "delete_alert/3" do
    test "deletes at the current revision", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})

      assert {:ok, deleted} = Alerts.delete_alert(context.audit, alert.id, 1)

      assert deleted.id == alert.id
      assert Repo.get(Alert, alert.id) == nil
    end

    test "keeps the row at a stale revision", context do
      alert = alert_fixture(context.audit, %{"urgency" => "now"})
      {:ok, _saved} = Alerts.save_draft(context.audit, alert.id, 1, %{"situation" => "delay"})

      assert {:error, :stale, %Alert{revision: 2} = current} =
               Alerts.delete_alert(context.audit, alert.id, 1)

      assert current.revision == 2

      reloaded = Repo.get!(Alert, alert.id)

      assert reloaded.revision == 2
      assert reloaded.situation == :delay
    end

    test "refuses a deactivated member", context do
      alert = alert_fixture(context.audit)

      membership = Repo.get_by(GtfsPlanner.Accounts.UserOrgMembership, user_id: context.actor.id)
      deactivate_membership_fixture(membership)

      assert {:error, :forbidden} = Alerts.delete_alert(context.audit, alert.id, 1)
      assert Repo.get!(Alert, alert.id)
    end

    test "refuses a member without the editor role", context do
      alert = alert_fixture(context.audit)
      viewer = user_fixture()
      organization_membership_fixture(viewer, context.organization, [])

      audit = audit_context(context.organization, context.version, viewer)

      assert {:error, :forbidden} = Alerts.delete_alert(audit, alert.id, 1)
      assert Repo.get!(Alert, alert.id)
    end

    test "refuses a member of another organization", context do
      alert = alert_fixture(context.audit)

      other_actor = editor_fixture(organization_fixture())
      audit = audit_context(context.organization, context.version, other_actor)

      assert {:error, :forbidden} = Alerts.delete_alert(audit, alert.id, 1)
      assert Repo.get!(Alert, alert.id)
    end

    test "does not delete an alert of another organization or another version", context do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)
      other_actor = editor_fixture(other_organization)

      foreign_alert = alert_fixture(audit_context(other_organization, other_version, other_actor))

      other_version_same_org = gtfs_version_fixture(context.organization.id)

      same_org_alert =
        alert_fixture(audit_context(context.organization, other_version_same_org, context.actor))

      assert {:error, :not_found} = Alerts.delete_alert(context.audit, foreign_alert.id, 1)
      assert {:error, :not_found} = Alerts.delete_alert(context.audit, same_org_alert.id, 1)
      assert {:error, :not_found} = Alerts.delete_alert(context.audit, Ecto.UUID.generate(), 1)
      assert {:error, :not_found} = Alerts.delete_alert(context.audit, "not-a-uuid", 1)

      assert Repo.get!(Alert, foreign_alert.id)
      assert Repo.get!(Alert, same_org_alert.id)
    end
  end

  defp weekly_delay_attrs(route_id) do
    %{
      "urgency" => "planned",
      "situation" => "delay",
      "cause" => "construction",
      "scope" => %{"shape" => "routes", "route_ids" => [route_id]},
      "timing" => %{
        "pattern" => "weekly",
        "first_date" => "2026-10-05",
        "weeks" => 2,
        "weekdays" => [1, 2, 3, 4, 5],
        "start_time" => "20:00:00",
        "end_time" => "05:00:00",
        "removed_dates" => ["2026-10-09"]
      },
      "message" => %{
        "header" => "Route 1 buses delayed",
        "description" => "Construction on Main St. Use Route 2 instead."
      }
    }
  end

  # A route, a stop and a departure of the context's own version, the rows a
  # scope answer may name.
  defp version_targets(context) do
    route = route_fixture(context.organization.id, context.version.id, %{route_id: "r_1"})
    stop = stop_fixture(context.organization.id, context.version.id, %{stop_id: "s_1"})
    trip = trip_fixture(context.organization.id, context.version.id, route.route_id)

    %{route: route, stop: stop, trip: trip}
  end

  # An embedded answer's errors live on its own changeset, not on the parent's
  # `errors`, so they are read through `traverse_errors/2`.
  defp nested_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
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

defmodule GtfsPlanner.Gtfs.Routes.StatusTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.RouteCleanupFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Routes
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  # The production SERIALIZABLE boundary is pinned for every case (step 4
  # convention) and restored afterward, so these committed fixtures exercise
  # real transactions, not the Sandbox adapter.
  setup do
    previous = Application.fetch_env(:gtfs_planner, :reviewed_apply_transaction)
    Application.put_env(:gtfs_planner, :reviewed_apply_transaction, ReviewedApplyTransaction.Repo)

    on_exit(fn ->
      case previous do
        {:ok, adapter} ->
          Application.put_env(:gtfs_planner, :reviewed_apply_transaction, adapter)

        :error ->
          Application.delete_env(:gtfs_planner, :reviewed_apply_transaction)
      end
    end)

    :ok
  end

  describe "set_route_active/4 deliberate status changes" do
    test "deactivation writes boolean state and audit only and retains every dependent row" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      dependents = seed_dependents(fixture)
      base = fresh_source(fixture)

      assert {:ok, %{route: route, source: source}} =
               set_route_active(fixture, "R1", false, base)

      assert route.active == false
      assert route.route_short_name == "15"
      assert route.route_long_name == "Fifteen"
      assert route.route_id == "R1"
      assert route.organization_id == fixture.organization.id
      assert route.gtfs_version_id == fixture.version.id

      # The revision advances, so Undo must act on this fresh source.
      assert DateTime.compare(source.updated_at, base.updated_at) == :gt
      assert source.route_uuid == base.route_uuid

      # Every dependent row is retained unchanged.
      assert dependent_identities(fixture) == dependents

      # The deliberate change writes the boolean state and the transactional
      # audit only: detail values are identical before and after.
      assert [log] = updated_logs(fixture)
      assert log.entity_external_id == "R1"
      assert log.actor_id == fixture.audit.actor_id
      assert log.changed_fields["before"]["active"] == true
      assert log.changed_fields["after"]["active"] == false

      assert Map.delete(log.changed_fields["before"], "active") ==
               Map.delete(log.changed_fields["after"], "active")
    end

    test "null behaves eligible, null-to-true is an effective no-op and never backfills" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture, %{active: nil})
      base = fresh_source(fixture)
      assert reload_route(fixture).active == nil

      # NULL is already effectively eligible: requesting true is a no-op.
      assert {:ok, %{route: route, source: source}} =
               set_route_active(fixture, "R1", true, base)

      assert route.active == nil
      assert route.updated_at == base.updated_at
      assert source.updated_at == base.updated_at
      assert updated_logs(fixture) == []

      # Moving the effectively eligible NULL to explicit inactive is a real
      # change; only explicit false is inactive.
      assert {:ok, %{route: deactivated, source: after_false}} =
               set_route_active(fixture, "R1", false, fresh_source(fixture))

      assert deactivated.active == false
      assert DateTime.compare(after_false.updated_at, base.updated_at) == :gt

      assert [log] = updated_logs(fixture)
      assert log.changed_fields["before"]["active"] == nil
      assert log.changed_fields["after"]["active"] == false

      # Already-effective false is a no-op again.
      assert {:ok, %{route: again, source: _}} =
               set_route_active(fixture, "R1", false, fresh_source(fixture))

      assert again.active == false
      assert [%{id: log_id}] = updated_logs(fixture)
      assert log_id == log.id
      assert reload_route(fixture).updated_at == after_false.updated_at
    end

    test "undo reactivation applies with the fresh source from the deactivation" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)

      assert {:ok, %{route: deactivated, source: undo_source}} =
               set_route_active(fixture, "R1", false, base)

      assert deactivated.active == false

      assert {:ok, %{route: reactivated, source: source}} =
               set_route_active(fixture, "R1", true, undo_source)

      assert reactivated.active == true
      assert source.route_uuid == base.route_uuid

      # Two deliberate changes, each with its own before/after audit.
      [first, second] =
        fixture |> updated_logs() |> Enum.sort_by(& &1.changed_fields["after"]["active"])

      assert first.changed_fields["before"]["active"] == true
      assert first.changed_fields["after"]["active"] == false
      assert second.changed_fields["before"]["active"] == false
      assert second.changed_fields["after"]["active"] == true
      assert second.actor_id == fixture.audit.actor_id
    end
  end

  describe "set_route_active/4 source and authorization" do
    test "a real state change requires the exact UUID and revision" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)

      assert {:ok, %{route: deactivated}} = set_route_active(fixture, "R1", false, base)
      assert deactivated.active == false

      # The stale pre-change source cannot authorize the real reactivation.
      assert {:error, :stale} = set_route_active(fixture, "R1", true, base)

      assert reload_route(fixture).active == false
      assert length(updated_logs(fixture)) == 1

      # A malformed source without the saved revision cannot either.
      assert {:error, :stale} =
               set_route_active(
                 fixture,
                 "R1",
                 true,
                 Map.delete(fresh_source(fixture), :updated_at)
               )

      assert reload_route(fixture).active == false
      assert length(updated_logs(fixture)) == 1
    end

    test "undo refuses deleted and replaced routes" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      original = seed_route(fixture)
      base = Routes.source(original)

      unboxed(fn -> Repo.delete!(original) end)
      replacement = seed_route(fixture)
      assert replacement.id != base.route_uuid

      # The same natural ID is now a replacement row: the old source is stale.
      assert {:error, :stale} = set_route_active(fixture, "R1", true, base)

      assert reload_route(fixture).id == replacement.id
      assert reload_route(fixture).active == true
      assert updated_logs(fixture) == []

      unboxed(fn -> Repo.delete!(replacement) end)

      # A deleted route is not found, and nothing is written.
      assert {:error, :not_found} = set_route_active(fixture, "R1", true, base)
      assert updated_logs(fixture) == []
    end

    test "denied actors cannot change status" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)

      foreign = create_fixture()
      on_exit(fn -> cleanup_fixture(foreign) end)

      # An actor without membership in the target organization is forbidden,
      # even when their claimed scope points at the target's version.
      injected = %{
        foreign.audit
        | organization_id: fixture.organization.id,
          gtfs_version_id: fixture.version.id
      }

      assert {:error, :forbidden} =
               set_route_active(fixture, "R1", false, fresh_source(fixture), injected)

      # A foreign scope never sees this route (AC-1: foreign scope is
      # not-found without counts).
      assert {:error, :not_found} =
               set_route_active(fixture, "R1", false, fresh_source(fixture), foreign.audit)

      # A revoked membership cannot act either.
      unboxed(fn ->
        Repo.delete_all(
          from m in UserOrgMembership,
            where:
              m.user_id == ^fixture.actor.id and m.organization_id == ^fixture.organization.id
        )
      end)

      assert {:error, :forbidden} = set_route_active(fixture, "R1", false, fresh_source(fixture))

      assert reload_route(fixture).active == true
      assert updated_logs(fixture) == []
    end

    test "a failed audit rolls the status change back" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)

      assert {:error, :failed_audit} =
               set_route_active(
                 fixture,
                 "R1",
                 false,
                 base,
                 %{fixture.audit | actor_email: nil}
               )

      assert reload_route(fixture).active == true
      assert reload_route(fixture).updated_at == base.updated_at
      assert updated_logs(fixture) == []
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # The real public domain entrypoint runs outside the shared Sandbox against
  # committed fixtures through the production serializable adapter.
  defp set_route_active(fixture, route_id, active, source, audit \\ nil),
    do:
      unboxed(fn ->
        Gtfs.set_route_active(route_id, active, source, audit || fixture.audit)
      end)

  defp seed_route(fixture, overrides \\ %{}) do
    unboxed(fn ->
      route_fixture(
        fixture.organization.id,
        fixture.version.id,
        Enum.into(overrides, %{
          route_id: "R1",
          route_short_name: "15",
          route_long_name: "Fifteen",
          route_type: 3,
          route_color: "1B4F72",
          route_text_color: "111111",
          route_desc: "Base desc"
        })
      )
    end)
  end

  # A representative dependent set for retention checks: pattern, trip, stop,
  # stop time and frequency rows all reference the route's service directly.
  defp seed_dependents(fixture) do
    unboxed(fn ->
      stop = stop_fixture(fixture.organization.id, fixture.version.id)

      trip =
        trip_fixture(fixture.organization.id, fixture.version.id, "R1", %{
          trip_id: "trip_r1"
        })

      stop_time =
        stop_time_fixture(fixture.organization.id, fixture.version.id, trip.trip_id, stop.stop_id)

      pattern =
        route_pattern_fixture(fixture.organization.id, fixture.version.id, %{route_id: "R1"})

      frequency = frequency_fixture(fixture.organization.id, fixture.version.id, trip.trip_id)

      %{
        pattern_id: pattern.id,
        trip_id: trip.id,
        stop_id: stop.id,
        stop_time_id: stop_time.id,
        frequency_id: frequency.id
      }
    end)
  end

  defp dependent_identities(fixture) do
    unboxed(fn ->
      %{
        pattern_id:
          Repo.one!(
            from p in RoutePattern,
              where: p.organization_id == ^fixture.organization.id,
              select: p.id
          ),
        trip_id:
          Repo.one!(
            from t in Trip, where: t.organization_id == ^fixture.organization.id, select: t.id
          ),
        stop_id:
          Repo.one!(
            from s in Stop, where: s.organization_id == ^fixture.organization.id, select: s.id
          ),
        stop_time_id:
          Repo.one!(
            from st in StopTime,
              where: st.organization_id == ^fixture.organization.id,
              select: st.id
          ),
        frequency_id:
          Repo.one!(
            from f in Frequency,
              where: f.organization_id == ^fixture.organization.id,
              select: f.id
          )
      }
    end)
  end

  defp fresh_source(fixture, route_id \\ "R1"),
    do: Routes.source(reload_route(fixture, route_id))

  defp reload_route(fixture, route_id \\ "R1") do
    unboxed(fn ->
      Repo.one!(
        from r in Route,
          where:
            r.organization_id == ^fixture.organization.id and
              r.gtfs_version_id == ^fixture.version.id and r.route_id == ^route_id
      )
    end)
  end

  defp updated_logs(fixture) do
    unboxed(fn ->
      Repo.all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id and
              l.gtfs_version_id == ^fixture.version.id and
              l.entity_type == "route" and l.action == "updated",
          order_by: l.inserted_at
      )
    end)
  end

  defp create_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "route-status-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)

      actor =
        user_fixture(%{email: "route-status-#{System.unique_integer([:positive])}@example.com"})

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: actor.id,
          organization_id: organization.id,
          roles: [
            "pathways_studio_editor"
          ]
        })

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      %{organization: organization, version: version, actor: actor, audit: audit}
    end)
  end

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      org_id = fixture.organization.id
      version_id = fixture.version.id

      delete_org_or_version!(Frequency, org_id, version_id)

      delete_org_or_version!(StopTime, org_id, version_id)

      delete_org_or_version!(Trip, org_id, version_id)

      delete_org_or_version!(RoutePattern, org_id, version_id)

      delete_org_or_version!(Stop, org_id, version_id)

      delete_org_or_version!(ChangeLog, org_id, version_id)

      delete_org_or_version!(Route, org_id, version_id)

      delete_org_or_version!(GtfsPlanner.Gtfs.Agency, org_id, version_id)

      Repo.delete_all(
        from m in UserOrgMembership,
          where: m.organization_id == ^fixture.organization.id or m.user_id == ^fixture.actor.id
      )

      Repo.delete_all(from v in GtfsVersion, where: v.id == ^fixture.version.id)
      Repo.delete_all(from u in User, where: u.id == ^fixture.actor.id)
      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)
      :ok
    end)
  end
end

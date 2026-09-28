defmodule GtfsPlanner.Gtfs.Routes.UpdateTest do
  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Routes
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  describe "update_route/5 clean saves" do
    test "an unchanged current applies only D minus B and audits before/after" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)

      assert {:ok, %{route: route, source: source}} =
               update(fixture, "R1", %{route_short_name: "42"}, base, %{})

      assert route.route_short_name == "42"
      # Untouched imported values, custom text color, natural ID and scope survive.
      assert route.route_long_name == "Fifteen"
      assert route.route_text_color == "111111"
      assert route.route_id == "R1"
      assert route.organization_id == fixture.organization.id
      assert route.gtfs_version_id == fixture.version.id
      assert source.route_uuid == route.id
      assert source.original[:route_short_name] == "42"

      assert [log] = updated_logs(fixture)
      assert log.entity_external_id == "R1"
      assert log.actor_id == fixture.audit.actor_id
      assert log.changed_fields["before"]["route_short_name"] == "15"
      assert log.changed_fields["after"]["route_short_name"] == "42"
      assert log.changed_fields["after"]["route_long_name"] == "Fifteen"
    end

    test "a no-op writes nothing, touches no timestamp and adds no audit" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)

      # Identical, trimmed-equal and hex-case-only values are all no-ops.
      assert {:ok, %{route: route}} =
               update(
                 fixture,
                 "R1",
                 %{
                   route_short_name: " 15 ",
                   route_long_name: "Fifteen",
                   route_color: "1b4f72"
                 },
                 base,
                 %{}
               )

      assert route.updated_at == base.updated_at
      assert updated_logs(fixture) == []
    end
  end

  describe "update_route/5 reviewed merge" do
    test "a disjoint merge requires a second deliberate submission" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)
      draft = %{route_short_name: "42"}

      # An intervening save changes a disjoint field.
      assert {:ok, _} =
               update(
                 fixture,
                 "R1",
                 %{route_long_name: "Theirs Long"},
                 fresh_source(fixture),
                 %{}
               )

      logs_after_intervening = length(updated_logs(fixture))

      # The first submission returns the fresh conflict payload without writing.
      assert {:error, {:conflict, %{source: fresh, comparison: comparison}}} =
               update(fixture, "R1", draft, base, %{})

      assert comparison.status == :confirmation_required
      assert :route_short_name in comparison.compatible
      assert :route_long_name in comparison.compatible
      assert comparison.conflicting == []
      assert fresh.original[:route_long_name] == "Theirs Long"
      assert fresh.route_uuid == base.route_uuid

      route = reload_route(fixture)
      assert route.route_short_name == "15"
      assert length(updated_logs(fixture)) == logs_after_intervening

      # The second deliberate submission is bound to the displayed revision.
      choices = %{confirm_merge: true, current_updated_at: fresh.updated_at}

      assert {:ok, %{route: merged}} = update(fixture, "R1", draft, base, choices)
      assert merged.route_short_name == "42"
      assert merged.route_long_name == "Theirs Long"
      assert length(updated_logs(fixture)) == logs_after_intervening + 1
    end

    test "a third intervening save returns a fresh conflict instead of the stale draft" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)
      draft = %{route_short_name: "42"}

      assert {:ok, _} =
               update(fixture, "R1", %{route_long_name: "Long Two"}, fresh_source(fixture), %{})

      assert {:error, {:conflict, %{source: displayed}}} = update(fixture, "R1", draft, base, %{})

      # A third save lands before the deliberate submission.
      assert {:ok, _} = update(fixture, "R1", %{route_desc: "Third"}, fresh_source(fixture), %{})

      assert {:error, {:conflict, %{source: fresh, comparison: comparison}}} =
               update(fixture, "R1", draft, base, %{
                 confirm_merge: true,
                 current_updated_at: displayed.updated_at
               })

      assert comparison.status == :confirmation_required
      assert fresh.updated_at != displayed.updated_at
      assert fresh.original[:route_desc] == "Third"

      route = reload_route(fixture)
      assert route.route_short_name == "15"

      # The fresh conflict payload rebinds and then applies everything accepted.
      assert {:ok, %{route: merged}} =
               update(fixture, "R1", draft, base, %{
                 confirm_merge: true,
                 current_updated_at: fresh.updated_at
               })

      assert merged.route_short_name == "42"
      assert merged.route_long_name == "Long Two"
      assert merged.route_desc == "Third"
    end

    test "overlapping values require explicit per-field choices" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)
      draft = %{route_desc: "Mine desc"}

      assert {:ok, _} =
               update(fixture, "R1", %{route_desc: "Theirs desc"}, fresh_source(fixture), %{})

      assert {:error, {:conflict, %{source: displayed, comparison: comparison}}} =
               update(fixture, "R1", draft, base, %{})

      assert comparison.status == :choices_required
      assert comparison.conflicting == [:route_desc]

      assert {:ok, %{route: merged}} =
               update(fixture, "R1", draft, base, %{
                 confirm_merge: true,
                 route_desc: "mine",
                 current_updated_at: displayed.updated_at
               })

      assert merged.route_desc == "Mine desc"

      # Accepting "theirs" keeps the current value and is a no-op with no audit.
      base = fresh_source(fixture)
      draft = %{route_desc: "Second mine"}

      assert {:ok, _} =
               update(fixture, "R1", %{route_desc: "Second theirs"}, fresh_source(fixture), %{})

      assert {:error, {:conflict, %{source: displayed}}} = update(fixture, "R1", draft, base, %{})
      logs_before = length(updated_logs(fixture))

      assert {:ok, %{route: kept}} =
               update(fixture, "R1", draft, base, %{
                 confirm_merge: true,
                 route_desc: "theirs",
                 current_updated_at: displayed.updated_at
               })

      assert kept.route_desc == "Second theirs"
      assert length(updated_logs(fixture)) == logs_before
    end
  end

  describe "update_route/5 authorization, scope and identity" do
    test "a revoked membership cannot mutate" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)

      unboxed(fn ->
        Repo.delete_all(
          from m in UserOrgMembership,
            where:
              m.user_id == ^fixture.actor.id and m.organization_id == ^fixture.organization.id
        )
      end)

      assert {:error, :forbidden} = update(fixture, "R1", %{route_short_name: "99"}, base, %{})

      assert reload_route(fixture).route_short_name == "15"
      assert updated_logs(fixture) == []
    end

    test "a foreign agency cannot mutate while a scoped agency resolves" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)

      unboxed(fn ->
        agency_fixture(fixture.organization.id, fixture.version.id, %{agency_id: "A1"})
        agency_fixture(fixture.organization.id, fixture.version.id, %{agency_id: "A2"})
      end)

      foreign = create_fixture()

      unboxed(fn ->
        agency_fixture(foreign.organization.id, foreign.version.id, %{agency_id: "FOREIGN"})
      end)

      on_exit(fn -> cleanup_fixture(foreign) end)

      base = fresh_source(fixture)

      assert {:error, %Ecto.Changeset{} = changeset} =
               update(fixture, "R1", %{agency_id: "FOREIGN"}, base, %{})

      assert {"is not available in this version", _} = changeset.errors[:agency_id]
      assert reload_route(fixture).agency_id == nil
      assert updated_logs(fixture) == []

      # Seam S-1 resolves a scoped agency inside the transaction under the lock.
      assert {:ok, %{route: assigned}} =
               update(fixture, "R1", %{agency_id: "A2"}, fresh_source(fixture), %{})

      assert assigned.agency_id == "A2"
    end

    test "forged active, scope and natural ID params cannot mutate" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      route = seed_route(fixture)
      base = fresh_source(fixture)

      forged = %{
        route_short_name: "77",
        active: false,
        id: Ecto.UUID.generate(),
        route_id: "HACKED",
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate(),
        route_pattern_build_id: Ecto.UUID.generate()
      }

      assert {:ok, %{route: updated}} = update(fixture, "R1", forged, base, %{})

      assert updated.route_short_name == "77"
      assert updated.route_id == "R1"
      assert updated.active == route.active
      assert updated.organization_id == fixture.organization.id
      assert updated.gtfs_version_id == fixture.version.id

      assert [log] = updated_logs(fixture)
      assert log.changed_fields["after"]["active"] == route.active
    end

    test "a replaced UUID cannot mutate and a deleted route is not found" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      original = seed_route(fixture)
      base = Routes.source(original)

      unboxed(fn -> Repo.delete!(original) end)
      replacement = seed_route(fixture)
      assert replacement.id != base.route_uuid

      assert {:error, :stale} = update(fixture, "R1", %{route_short_name: "99"}, base, %{})

      assert reload_route(fixture).id == replacement.id
      assert reload_route(fixture).route_short_name == "15"
      assert updated_logs(fixture) == []

      unboxed(fn -> Repo.delete!(replacement) end)
      assert {:error, :not_found} = update(fixture, "R1", %{route_short_name: "99"}, base, %{})
    end

    test "a failed audit rolls the edit back" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      seed_route(fixture)
      base = fresh_source(fixture)

      assert {:error, :failed_audit} =
               update_with(
                 fixture,
                 "R1",
                 %{route_short_name: "99"},
                 base,
                 %{},
                 %{fixture.audit | actor_email: nil}
               )

      assert reload_route(fixture).route_short_name == "15"
      assert updated_logs(fixture) == []
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  # The real public domain entrypoint runs outside the shared Sandbox against
  # committed fixtures, so the serializable update transaction is real.
  defp update(fixture, route_id, attrs, source, choices),
    do: update_with(fixture, route_id, attrs, source, choices, fixture.audit)

  defp update_with(_fixture, route_id, attrs, source, choices, audit),
    do: unboxed(fn -> Gtfs.update_route(route_id, attrs, source, choices, audit) end)

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
    fixture =
      unboxed(fn ->
        organization = organization_fixture(%{alias: "route-update-#{stamp()}"})
        version = gtfs_version_fixture(organization.id)

        actor =
          user_fixture(%{email: "route-update-#{System.unique_integer([:positive])}@example.com"})

        {:ok, _membership} =
          Organizations.add_user_to_organization(actor.id, organization.id, [
            "pathways_studio_editor"
          ])

        audit = %AuditContext{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          actor_id: actor.id,
          actor_email: actor.email
        }

        %{organization: organization, version: version, actor: actor, audit: audit}
      end)

    fixture
  end

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      Repo.delete_all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id or
              l.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from r in Route,
          where:
            r.organization_id == ^fixture.organization.id or
              r.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from a in Agency,
          where:
            a.organization_id == ^fixture.organization.id or
              a.gtfs_version_id == ^fixture.version.id
      )

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

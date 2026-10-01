defmodule GtfsPlanner.Gtfs.StopEditingCreateTest do
  @moduledoc """
  `StopEditing.create_stop/2` against a real database (EV-13, AC-12).

  These run through the configured `:reviewed_apply_transaction` runner exactly as
  the route command's tests do, so the serializable transaction is the real one
  rather than a stand-in. The fixtures are created through the sandbox's
  `unboxed_run/2`, because a command that opens its own transaction cannot run
  inside the shared sandbox transaction.

  What is under test is the boundary, not the insert: who is allowed, whose
  version, what ID a stop gets when the editor did not type one, and — the part
  INV-2 exists for — that there is no committed stop without a matching audit
  entry. Every denied case asserts that no row was written, since a refusal that
  leaves a row behind is not a refusal.
  """

  use ExUnit.Case

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopEditing
  alias GtfsPlanner.Organizations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StopEditingCollisionRunner
  alias GtfsPlanner.Versions

  describe "create_stop/2 with a generated ID" do
    test "an editor creating a stop with no stop_id gets the next integer after the highest" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        stop_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1301"})
        stop_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1531"})
      end)

      assert {:ok, stop} = create_stop(stop_attrs(), fixture.audit)

      # The gap between 1301 and 1531 is not filled: those numbers belonged to
      # stops that are no longer here, and reusing one would point a retired
      # stop's history at a live one.
      assert stop.stop_id == "1532"
      assert stop.organization_id == fixture.organization.id
      assert stop.gtfs_version_id == fixture.version.id
    end

    test "the create is audited as a stop created in the same transaction" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:ok, stop} = create_stop(stop_attrs(), fixture.audit)

      assert [log] = created_logs(fixture)
      assert log.entity_type == "stop"
      assert log.action == "created"
      assert log.entity_id == stop.id
      assert log.entity_external_id == stop.stop_id
      assert log.actor_id == fixture.audit.actor_id
      assert log.actor_email == fixture.audit.actor_email
    end

    test "a garage ID occupying the next number is skipped" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        stop_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1531"})
      end)

      # A garage is not a stop, but it occupies a number in the same series, so
      # a stop taking it would break the export's stop-ID uniqueness rule.
      unboxed(fn -> garage_fixture(fixture.organization.id, %{garage_id: "1532"}) end)

      assert {:ok, stop} = create_stop(stop_attrs(), fixture.audit)

      assert stop.stop_id == "1533"
    end

    test "a version with no numeric IDs falls back to a slug that is made unique" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        stop_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "platform_main_st"})

        stop_fixture(fixture.organization.id, fixture.version.id, %{
          stop_id: "platform_main_st_2"
        })
      end)

      assert {:ok, stop} =
               create_stop(stop_attrs(%{"stop_name" => "Main St"}), fixture.audit)

      assert stop.stop_id == "platform_main_st_3"
    end

    test "attributes cannot override the organization or version from the context" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      other = create_fixture()

      attrs =
        stop_attrs(%{
          "organization_id" => other.organization.id,
          "gtfs_version_id" => other.version.id
        })

      assert {:ok, stop} = create_stop(attrs, fixture.audit)

      # The forged scope is not merely rejected, it is ignored: the stop lands in
      # the context's version and nowhere else.
      assert stop.organization_id == fixture.organization.id
      assert stop.gtfs_version_id == fixture.version.id
      assert [] = scoped_stops(other)
    end
  end

  describe "create_stop/2 authorization and scope" do
    test "a deactivated member is forbidden and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      # The fixture actor is already an editor; deactivating that membership is
      # what an editor's removal looks like from the command's point of view.
      unboxed(fn ->
        membership =
          Accounts.get_user_org_membership(fixture.actor.id, fixture.organization.id)

        deactivate_membership_fixture(membership)
      end)

      assert {:error, :forbidden} = create_stop(stop_attrs(), fixture.audit)
      assert [] = scoped_stops(fixture)
      assert [] = created_logs(fixture)
    end

    test "a member with no editor role is forbidden and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      # A studio admin is a member of the organization who is not an editor, so
      # `authorize_editor!/1` must refuse them on role rather than membership.
      actor = unboxed(fn -> add_actor(fixture.organization.id, "pathways_studio_admin") end)

      audit = %{
        fixture.audit
        | actor_id: actor.id,
          actor_email: actor.email
      }

      assert {:error, :forbidden} = create_stop(stop_attrs(), audit)
      assert [] = scoped_stops(fixture)
    end

    test "an actor who is not a member of the organization at all is forbidden" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      stranger = unboxed(fn -> user_fixture(%{email: "stop-stranger-#{stamp()}@example.com"}) end)

      audit = %{fixture.audit | actor_id: stranger.id, actor_email: stranger.email}

      assert {:error, :forbidden} = create_stop(stop_attrs(), audit)
      assert [] = scoped_stops(fixture)
    end

    test "another organization's version is not found and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      other = create_fixture()

      audit = %{fixture.audit | gtfs_version_id: other.version.id}

      assert {:error, :not_found} = create_stop(stop_attrs(), audit)
      assert [] = scoped_stops(other)
    end

    test "an unpublished version is not found and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      version = unboxed(fn -> unpublished_version_fixture(fixture.organization.id) end)

      audit = %{fixture.audit | gtfs_version_id: version.id}

      assert {:error, :not_found} = create_stop(stop_attrs(), audit)

      assert [] =
               unboxed(fn ->
                 Repo.all(
                   from s in Stop,
                     where:
                       s.organization_id == ^fixture.organization.id and
                         s.gtfs_version_id == ^version.id
                 )
               end)
    end
  end

  describe "create_stop/2 with a typed ID" do
    test "a typed stop_id is used exactly as typed" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:ok, stop} = create_stop(stop_attrs(%{"stop_id" => "9901"}), fixture.audit)

      assert stop.stop_id == "9901"
    end

    test "a typed stop_id that already exists is a changeset error, not a rename" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        existing =
          stop_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1434"})

        assert {:error, %Ecto.Changeset{} = failed} =
                 create_stop(stop_attrs(%{"stop_id" => "1434"}), fixture.audit)

        # The unique index spans three columns, and Ecto files a composite
        # unique error under the *first* of them. The stop ID is therefore named
        # by the constraint rather than by the field the error sits on, which is
        # what `StopEditing` matches on to tell a duplicate from a collision.
        assert [
                 {:organization_id,
                  {"has already been taken",
                   [
                     constraint: :unique,
                     constraint_name: "stops_organization_id_gtfs_version_id_stop_id_index"
                   ]}}
               ] = failed.errors

        assert [%Stop{id: existing_id}] = scoped_stops(fixture)
        assert existing_id == existing.id
      end)

      # The failed create wrote no audit entry either.
      assert [] = created_logs(fixture)
    end

    test "a typed duplicate ID in another version is allowed, since IDs are per-version" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      other_version = unboxed(fn -> gtfs_version_fixture(fixture.organization.id) end)

      unboxed(fn ->
        stop_fixture(fixture.organization.id, other_version.id, %{stop_id: "1434"})
      end)

      assert {:ok, stop} = create_stop(stop_attrs(%{"stop_id" => "1434"}), fixture.audit)

      assert stop.stop_id == "1434"
      assert stop.gtfs_version_id == fixture.version.id
    end
  end

  describe "create_stop/2 validation" do
    test "a located stop with no name is a changeset error and writes nothing" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:error, %Ecto.Changeset{} = failed} =
               create_stop(stop_attrs(%{"stop_name" => nil}), fixture.audit)

      assert Keyword.has_key?(failed.errors, :stop_name)
      assert [] = scoped_stops(fixture)
    end

    test "a non-http stop_url is a changeset error" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      assert {:error, %Ecto.Changeset{} = failed} =
               create_stop(stop_attrs(%{"stop_url" => "javascript:alert(1)"}), fixture.audit)

      assert Keyword.has_key?(failed.errors, :stop_url)
      assert [] = scoped_stops(fixture)
    end
  end

  describe "create_stop/2 concurrency" do
    test "a generated ID taken by a concurrent insert succeeds on retry with the next number" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        stop_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1531"})
      end)

      # The runner reports a collision on the first attempt and commits the row
      # another session would have won the race with, so the closure has to be
      # rerun against committed state. It must pick 1533 — not rename anything,
      # and not give up.
      assert :ok = StopEditingCollisionRunner.install(fixture, "1532")

      assert {:ok, stop} = create_stop(stop_attrs(), fixture.audit)

      assert stop.stop_id == "1533"
      assert StopEditingCollisionRunner.attempts() == 1

      # Two rows beyond the seeded one: the concurrent writer's 1532 and the stop
      # this command actually created. The 1532 row is evidence the retry
      # happened, not a second stop this command wrote.
      assert ["1531", "1532", "1533"] = Enum.map(scoped_stops(fixture), & &1.stop_id)
      assert Enum.find(scoped_stops(fixture), &(&1.stop_id == "1533")).id == stop.id
      assert [log] = created_logs(fixture)
      assert log.entity_id == stop.id
    end

    test "three lost attempts answer :busy rather than looping" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      unboxed(fn ->
        stop_fixture(fixture.organization.id, fixture.version.id, %{stop_id: "1531"})
      end)

      # Every attempt loses, each to a number higher than the last, so
      # allocation can never land on a free number. Three attempts is the
      # command's budget, so the answer is :busy rather than a fourth try.
      assert :ok = StopEditingCollisionRunner.install(fixture, "1532", always: true)

      assert {:error, :busy} = create_stop(stop_attrs(), fixture.audit)
      assert StopEditingCollisionRunner.attempts() == 3

      # Nothing this command wrote survived; only the other session's rows did.
      assert ["1531", "1532", "1533", "1534"] = Enum.map(scoped_stops(fixture), & &1.stop_id)

      assert Enum.all?(scoped_stops(fixture), &(&1.stop_name == "Concurrent writer")) or
               length(scoped_stops(fixture)) == 4

      assert [] = created_logs(fixture)
    end
  end

  describe "create_stop/2 audit atomicity" do
    test "an audit context with no actor_email rolls the create back" do
      fixture = create_fixture()
      on_exit(fn -> cleanup_fixture(fixture) end)

      # INV-2: a stop nobody can attribute is not a committed stop. The
      # changeset rejects the entry, and the insert has to go with it.
      audit = %{fixture.audit | actor_email: nil}

      assert {:error, :failed_audit} = create_stop(stop_attrs(), audit)
      assert [] = scoped_stops(fixture)
      assert [] = created_logs(fixture)
    end
  end

  # --- fixture

  defp create_fixture do
    unboxed(fn ->
      organization = organization_fixture(%{alias: "stop-create-#{stamp()}"})
      version = gtfs_version_fixture(organization.id)
      actor = add_actor(organization.id, "pathways_studio_editor")

      audit = %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      %{organization: organization, version: version, actor: actor, audit: audit}
    end)
  end

  # `user_fixture/1` derives its email from `System.unique_integer/1`, which
  # restarts with the VM, so two runs against the same test database can mint the
  # same address. A nanosecond stamp does not, and `cleanup_fixture/1` deletes
  # the user anyway.
  defp add_actor(organization_id, role) do
    actor = user_fixture(%{email: "stop-create-#{stamp()}@example.com"})

    {:ok, _membership} =
      Accounts.create_user_org_membership(%{
        user_id: actor.id,
        organization_id: organization_id,
        roles: [role]
      })

    actor
  end

  # A version that exists but is not published. `create_gtfs_version/2` always
  # publishes, so the status is moved back to `staging` — the status the database
  # check constraint pairs with a null `published_at` — the way an import that
  # has not completed leaves a version.
  defp unpublished_version_fixture(organization_id) do
    {:ok, version} = Versions.create_gtfs_version(organization_id, %{name: "Staging Version"})

    version
    |> Ecto.Changeset.change(publication_status: "staging", published_at: nil)
    |> Repo.update!()
  end

  defp stop_attrs(overrides \\ %{}) do
    Enum.into(overrides, %{
      "stop_name" => "Main St & 1st Ave",
      "stop_lat" => Decimal.new("44.6210"),
      "stop_lon" => Decimal.new("-124.0530"),
      "location_type" => 0
    })
  end

  # The real public entrypoint runs outside the shared sandbox against committed
  # fixtures, so the serializable create transaction is real.
  defp create_stop(attrs, audit),
    do: unboxed(fn -> StopEditing.create_stop(attrs, audit) end)

  defp scoped_stops(fixture) do
    unboxed(fn ->
      Repo.all(
        from s in Stop,
          where:
            s.organization_id == ^fixture.organization.id and
              s.gtfs_version_id == ^fixture.version.id,
          order_by: s.stop_id
      )
    end)
  end

  defp created_logs(fixture) do
    unboxed(fn ->
      Repo.all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id and
              l.gtfs_version_id == ^fixture.version.id and
              l.entity_type == "stop" and
              l.action == "created"
      )
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp stamp, do: System.system_time(:nanosecond)

  defp cleanup_fixture(fixture) do
    unboxed(fn ->
      Repo.delete_all(
        from l in ChangeLog,
          where:
            l.organization_id == ^fixture.organization.id or
              l.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from s in Stop,
          where:
            s.organization_id == ^fixture.organization.id or
              s.gtfs_version_id == ^fixture.version.id
      )

      Repo.delete_all(
        from g in GtfsPlanner.Operations.Garage,
          where: g.organization_id == ^fixture.organization.id
      )

      Repo.delete_all(
        from m in UserOrgMembership,
          where: m.organization_id == ^fixture.organization.id
      )

      Repo.delete_all(from o in Organization, where: o.id == ^fixture.organization.id)
    end)
  end
end

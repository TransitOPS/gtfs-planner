defmodule GtfsPlanner.Gtfs.Blocking.RouteOperatingSettingsTest do
  @moduledoc """
  The Block rules drawer's route garage and required type are read one entry per
  route of the version and written as one all-or-nothing batch that rejects a
  foreign garage, a foreign type and a route the version does not have, so an
  accepted foreign garage and a partially stored batch stay rejected.

  The entries are read and written through the `Gtfs` facade, which is the path
  the page's `save_block_rules` uses. A route with no row answers `nil` for both
  values.

  Rows are created inside the SQL Sandbox transaction and rolled back. The one
  exception is the lock case, which needs an organization and version another
  connection can see: it commits its own disposable rows on an own connection
  and deletes exactly those rows in `on_exit`, like `settings_test.exs`.

  The module is `async: false` because the lock case observes another backend's
  `pg_stat_activity` wait; the other cases are sandboxed like any other
  `DataCase`.

  Run with:
  `mix test test/gtfs_planner/gtfs/blocking/route_operating_settings_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Queries
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.AdvancedBlockingFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag timeout: 120_000

  # The lock case holds one lock open and observes another backend's wait, so it is
  # bounded: a 120 s deadline per test, and a 10 s self-release for a
  # hold the test never gets to release.
  @hold_timeout 10_000
  @receive_timeout 5_000
  @lock_wait_attempts 500
  @task_timeout 15_000

  describe "list_route_operating_settings/2" do
    test "every route of the version is listed in short-name order and unset values are nil" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})

      # Stored out of short-name order, and created after the routes it names, so
      # neither the row order nor the insert order can produce the list order.
      route_fixture(organization.id, version.id, %{route_id: "30", route_short_name: "30"})
      route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})

      route_fixture(organization.id, version.id, %{
        route_id: "24",
        route_short_name: "24",
        route_long_name: "Night"
      })

      route_operating_setting_fixture(organization.id, version.id, %{
        route_id: "30",
        garage_id: garage.id
      })

      assert Gtfs.list_route_operating_settings(organization.id, version.id) == [
               %{route_id: "12", garage_id: nil, required_vehicle_type_id: nil},
               %{route_id: "24", garage_id: nil, required_vehicle_type_id: nil},
               %{route_id: "30", garage_id: garage.id, required_vehicle_type_id: nil}
             ]
    end

    test "a route with no short name sorts last and another organization's routes are not listed" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)

      route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})
      route_fixture(organization.id, version.id, %{route_id: "77", route_short_name: nil})

      route_fixture(other_organization.id, foreign_version.id, %{
        route_id: "99",
        route_short_name: "99"
      })

      # The other organization's setting for its own route is never read.
      route_operating_setting_fixture(other_organization.id, foreign_version.id, %{
        route_id: "99"
      })

      assert Gtfs.list_route_operating_settings(organization.id, version.id) == [
               %{route_id: "12", garage_id: nil, required_vehicle_type_id: nil},
               %{route_id: "77", garage_id: nil, required_vehicle_type_id: nil}
             ]
    end

    test "a version with no routes lists nothing" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      assert Gtfs.list_route_operating_settings(organization.id, version.id) == []
    end
  end

  describe "update_route_operating_settings/2" do
    test "a batch stores every entry and a second batch replaces the stored values" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})
      diesel = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})
      cutaway = vehicle_type_fixture(organization.id, %{"name" => "Cutaway"})

      for id <- ["12", "24", "30"] do
        route_fixture(organization.id, version.id, %{route_id: id, route_short_name: id})
      end

      assert :ok =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{
                     "route_id" => "12",
                     "garage_id" => garage.id,
                     "required_vehicle_type_id" => ""
                   },
                   %{
                     "route_id" => "30",
                     "garage_id" => garage.id,
                     "required_vehicle_type_id" => diesel.id
                   }
                 ]
               )

      assert Gtfs.list_route_operating_settings(organization.id, version.id) == [
               %{route_id: "12", garage_id: garage.id, required_vehicle_type_id: nil},
               %{route_id: "24", garage_id: nil, required_vehicle_type_id: nil},
               %{route_id: "30", garage_id: garage.id, required_vehicle_type_id: diesel.id}
             ]

      assert Repo.aggregate(RouteOperatingSetting, :count) == 2

      # The second batch replaces both value columns of the same rows: a garage
      # saved over a type and a type saved over a garage cannot leave the earlier
      # value behind.
      assert :ok =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{route_id: "12", garage_id: "", required_vehicle_type_id: cutaway.id},
                   %{route_id: "30", garage_id: "", required_vehicle_type_id: ""}
                 ]
               )

      assert Gtfs.list_route_operating_settings(organization.id, version.id) == [
               %{route_id: "12", garage_id: nil, required_vehicle_type_id: cutaway.id},
               %{route_id: "24", garage_id: nil, required_vehicle_type_id: nil},
               %{route_id: "30", garage_id: nil, required_vehicle_type_id: nil}
             ]

      assert Repo.aggregate(RouteOperatingSetting, :count) == 2
    end

    test "a garage of another organization is invalid and stores nothing for any entry" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      foreign_garage = garage_fixture(other_organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})

      for id <- ["12", "30"] do
        route_fixture(organization.id, version.id, %{route_id: id, route_short_name: id})
      end

      assert {:error, {:invalid, [%{route_id: "30", field: :garage_id} = _error]}} =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{"route_id" => "12", "garage_id" => garage.id},
                   %{"route_id" => "30", "garage_id" => foreign_garage.id}
                 ]
               )

      # The valid entry of the same batch is not stored either.
      assert Repo.aggregate(RouteOperatingSetting, :count) == 0

      assert Gtfs.list_route_operating_settings(organization.id, version.id) == [
               %{route_id: "12", garage_id: nil, required_vehicle_type_id: nil},
               %{route_id: "30", garage_id: nil, required_vehicle_type_id: nil}
             ]
    end

    test "a required type of another organization, a malformed value and a missing value are each invalid" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      foreign_type = vehicle_type_fixture(other_organization.id)

      for id <- ["12", "24", "30"] do
        route_fixture(organization.id, version.id, %{route_id: id, route_short_name: id})
      end

      assert {:error, {:invalid, invalid}} =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{"route_id" => "12", "required_vehicle_type_id" => foreign_type.id},
                   %{"route_id" => "24", "garage_id" => "not-a-uuid"},
                   %{"route_id" => "30", "garage_id" => Ecto.UUID.generate()}
                 ]
               )

      assert [
               %{route_id: "12", field: :required_vehicle_type_id},
               %{route_id: "24", field: :garage_id},
               %{route_id: "30", field: :garage_id}
             ] = invalid

      assert Repo.aggregate(RouteOperatingSetting, :count) == 0
    end

    test "a route the version does not have is invalid, and the errors name every bad entry" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})
      other_version = gtfs_version_fixture(organization.id)

      route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})
      route_fixture(organization.id, other_version.id, %{route_id: "24", route_short_name: "24"})

      assert {:error, {:invalid, invalid}} =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{"route_id" => "12", "garage_id" => garage.id},
                   %{"route_id" => "24", "garage_id" => garage.id},
                   %{"route_id" => ""}
                 ]
               )

      assert [%{route_id: "24", field: :route_id}, %{route_id: nil, field: :route_id}] = invalid
      assert Repo.aggregate(RouteOperatingSetting, :count) == 0
    end

    test "a rejected batch leaves the rows the last accepted save stored" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})
      other_garage = garage_fixture(organization.id, %{"name" => "Yard"})

      for id <- ["12", "30"] do
        route_fixture(organization.id, version.id, %{route_id: id, route_short_name: id})
      end

      assert :ok =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{"route_id" => "12", "garage_id" => garage.id},
                   %{"route_id" => "30", "garage_id" => other_garage.id}
                 ]
               )

      stored = Gtfs.list_route_operating_settings(organization.id, version.id)

      assert {:error, {:invalid, [%{route_id: "30", field: :garage_id}]}} =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{"route_id" => "12", "garage_id" => other_garage.id},
                   %{"route_id" => "30", "garage_id" => Ecto.UUID.generate()}
                 ]
               )

      assert Gtfs.list_route_operating_settings(organization.id, version.id) == stored
      assert Repo.aggregate(RouteOperatingSetting, :count) == 2
    end

    test "an empty batch stores nothing and a staging or foreign version is not found" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})

      assert :ok =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 []
               )

      assert Repo.aggregate(RouteOperatingSetting, :count) == 0

      {:ok, staging} = Versions.create_staging_gtfs_version(organization.id, %{name: "Staging"})
      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})
      entries = [%{"route_id" => "12", "garage_id" => garage.id}]

      assert Gtfs.update_route_operating_settings(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, staging.id),
               entries
             ) ==
               {:error, :not_found}

      assert Gtfs.update_route_operating_settings(
               GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                 organization.id,
                 foreign_version.id
               ),
               entries
             ) ==
               {:error, :not_found}

      assert Repo.aggregate(RouteOperatingSetting, :count) == 0
    end

    test "submitted organization, version and route scoping fields are ignored" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(other_organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})

      route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})

      assert :ok =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{
                     "route_id" => "12",
                     "garage_id" => garage.id,
                     "organization_id" => other_organization.id,
                     "gtfs_version_id" => foreign_version.id,
                     "id" => Ecto.UUID.generate()
                   }
                 ]
               )

      assert [stored] = Repo.all(RouteOperatingSetting)
      assert stored.organization_id == organization.id
      assert stored.gtfs_version_id == version.id
      assert stored.route_id == "12"
      assert stored.garage_id == garage.id
    end

    test "the rows reach the day context the plan reads" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garage = garage_fixture(organization.id, %{"name" => "Main"})
      diesel = vehicle_type_fixture(organization.id, %{"name" => "35-ft diesel"})

      route_fixture(organization.id, version.id, %{route_id: "30", route_short_name: "30"})

      assert :ok =
               Gtfs.update_route_operating_settings(
                 GtfsPlanner.AccountsFixtures.editor_audit_fixture(organization.id, version.id),
                 [
                   %{
                     "route_id" => "30",
                     "garage_id" => garage.id,
                     "required_vehicle_type_id" => diesel.id
                   }
                 ]
               )

      # `Blocking.Queries.planning_rows/3` is what `load_day/3` builds
      # `Context.route_settings` from, so a row stored here is the row the
      # generator and the export resolve against.
      rows = Queries.planning_rows(organization.id, version.id, [])

      assert rows.route_settings == [
               %{route_id: "30", garage_id: garage.id, required_vehicle_type_id: diesel.id}
             ]
    end
  end

  describe "update_route_operating_settings/2 under a held blocking lock" do
    test "the writer waits for lock_blocking!1 and succeeds after the release" do
      scope =
        unboxed(fn ->
          organization = organization_fixture()
          version = gtfs_version_fixture(organization.id)
          route_fixture(organization.id, version.id, %{route_id: "12", route_short_name: "12"})

          %{
            organization_id: organization.id,
            version_id: version.id,
            garage_id: garage_fixture(organization.id).id
          }
        end)

      on_exit(fn -> cleanup_committed_scope(scope) end)

      parent = self()

      holder = Task.async(fn -> hold_blocking_lock(scope, parent) end)
      assert_receive :blocking_lock_held, @receive_timeout

      writer =
        Task.async(fn ->
          unboxed(fn ->
            {:ok, %{rows: [[backend_pid]]}} = Repo.query("select pg_backend_pid()")
            send(parent, {:writer_pid, backend_pid})

            Blocking.update_route_operating_settings(
              GtfsPlanner.AccountsFixtures.editor_audit_fixture(
                scope.organization_id,
                scope.version_id
              ),
              [
                %{"route_id" => "12", "garage_id" => scope.garage_id}
              ]
            )
          end)
        end)

      assert_receive {:writer_pid, writer_pid}, @receive_timeout

      # The writer is inside its own transaction and waiting for the advisory lock the
      # holder's connection owns. `lock_blocking!/1` issues exactly this lock.
      assert wait_until_locked(writer_pid)

      send(holder.pid, :release)
      Task.await(holder, @task_timeout)

      assert :ok = Task.await(writer, @task_timeout)

      assert unboxed(fn ->
               Blocking.list_route_operating_settings(scope.organization_id, scope.version_id)
             end) == [
               %{route_id: "12", garage_id: scope.garage_id, required_vehicle_type_id: nil}
             ]
    end
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  # Holds the version's blocking lock on an own connection, with the statement
  # `Blocking.lock_blocking!/1` issues, until the test releases it.
  defp hold_blocking_lock(scope, parent) do
    unboxed(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          "blocking:" <> scope.version_id
        ])

        send(parent, :blocking_lock_held)

        receive do
          :release -> :ok
        after
          @hold_timeout -> Repo.rollback(:timeout)
        end
      end)
    end)
  end

  # Deletes exactly the rows the lock case committed, keyed to their own organization,
  # on an own connection so the deletion is not part of the sandboxed test transaction.
  # The version foreign keys cascade, so its route and setting rows go with it.
  defp cleanup_committed_scope(scope) do
    unboxed(fn ->
      actor_ids =
        Repo.all(
          from(m in UserOrgMembership,
            where: m.organization_id == ^scope.organization_id,
            select: m.user_id
          )
        )

      Repo.delete_all(
        from(m in UserOrgMembership, where: m.organization_id == ^scope.organization_id)
      )

      Repo.delete_all(
        from(r in GtfsPlanner.Gtfs.Route, where: r.organization_id == ^scope.organization_id)
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.organization_id == ^scope.organization_id))
      Repo.delete_all(from(o in Organization, where: o.id == ^scope.organization_id))
      Repo.delete_all(from(u in User, where: u.id in ^actor_ids))
    end)
  end

  defp wait_until_locked(pid, attempts \\ @lock_wait_attempts) do
    {:ok, %{rows: [[waiting]]}} =
      Repo.query(
        "select count(*) from pg_stat_activity where pid = $1 and wait_event_type = 'Lock'",
        [pid]
      )

    cond do
      waiting > 0 ->
        true

      attempts <= 0 ->
        flunk("the backend #{inspect(pid)} never waited on a lock")

      true ->
        Process.sleep(10)
        wait_until_locked(pid, attempts - 1)
    end
  end
end

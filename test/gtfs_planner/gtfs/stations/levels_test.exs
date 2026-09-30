defmodule GtfsPlanner.Gtfs.Stations.LevelsTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.{User, UserOrgMembership}

  alias GtfsPlanner.Gtfs.{
    Audit,
    AuditContext,
    ChangeLog,
    Level,
    Stations,
    Stop,
    StopLevel,
    Translation
  }

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @rendezvous_timeout 10_000
  @collect_timeout 15_000

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, location_type: 1)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: station.stop_id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, actor: actor, station: station, audit: audit}
  end

  test "creation persists both rows in server scope with two history records", scope do
    attrs = %{
      "level_id" => "L1",
      "level_name" => "Concourse",
      "level_index" => "0",
      "organization_id" => Ecto.UUID.generate(),
      "gtfs_version_id" => Ecto.UUID.generate(),
      "lock_version" => 99
    }

    assert {:ok, %{level: level, stop_level: stop_level}} =
             Stations.create_station_level(scope.audit, attrs, %{
               "organization_id" => Ecto.UUID.generate(),
               "gtfs_version_id" => Ecto.UUID.generate(),
               "stop_id" => Ecto.UUID.generate(),
               "level_id" => Ecto.UUID.generate(),
               "diagram_filename" => "../../other-station.png",
               "lock_version" => 99
             })

    assert level.organization_id == scope.organization.id
    assert level.gtfs_version_id == scope.version.id
    assert level.lock_version == 1
    assert stop_level.stop_id == scope.station.id
    assert stop_level.level_id == level.id
    assert stop_level.organization_id == scope.organization.id
    assert stop_level.gtfs_version_id == scope.version.id
    assert stop_level.lock_version == 1
    assert stop_level.diagram_filename == nil
    assert Repo.get!(Level, level.id).level_id == "L1"
    assert Repo.get!(StopLevel, stop_level.id).level_id == level.id
    assert [%{action: "created", actor_id: actor_id}] = logs(scope.audit, :level, level.id)
    assert actor_id == scope.actor.id

    assert [%{action: "created", snapshot: snapshot}] =
             logs(scope.audit, :stop_level, stop_level.id)

    assert snapshot["level_id"] == level.id
  end

  test "existing level attach refuses foreign and absent UUIDs without revealing them", scope do
    other_org = organization_fixture()
    other_org_version = gtfs_version_fixture(other_org.id)
    other_version = gtfs_version_fixture(scope.organization.id)
    foreign_org = level_fixture(other_org.id, other_org_version.id)
    foreign_version = level_fixture(scope.organization.id, other_version.id)
    existing = level_fixture(scope.organization.id, scope.version.id)

    for id <- [foreign_org.id, foreign_version.id, Ecto.UUID.generate(), "invalid"] do
      assert {:error, :not_found} = Stations.add_existing_level(scope.audit, id)
    end

    assert station_level_count(scope) == 0

    assert {:ok, attached} = Stations.add_existing_level(scope.audit, existing.id)
    assert attached.level_id == existing.id
    assert attached.stop_id == scope.station.id
    assert [%{action: "created"}] = logs(scope.audit, :stop_level, attached.id)

    assert {:error, %Ecto.Changeset{}} =
             Stations.add_existing_level(scope.audit, existing.id)

    assert station_level_count(scope) == 1
  end

  test "an attached level rename cascades stops and translations only in its version", scope do
    level = level_fixture(scope.organization.id, scope.version.id, level_id: "L1")
    assert {:ok, attached} = Stations.add_existing_level(scope.audit, level.id)

    child =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: "L1"
      )

    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)

    other_child =
      child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id,
        level_id: "L1"
      )

    other_version = gtfs_version_fixture(scope.organization.id)
    level_fixture(scope.organization.id, other_version.id, level_id: "L1")
    untouched = stop_fixture(scope.organization.id, other_version.id, level_id: "L1")
    translation = translation(scope.organization.id, scope.version.id, "L1")
    foreign_translation = translation(scope.organization.id, other_version.id, "L1")

    assert {:ok, updated} =
             Stations.update_level(
               scope.audit,
               level.id,
               %{
                 "level_id" => "L2",
                 "level_name" => "Upper",
                 "organization_id" => Ecto.UUID.generate(),
                 "gtfs_version_id" => Ecto.UUID.generate(),
                 "lock_version" => 99
               },
               level.lock_version
             )

    assert updated.level_id == "L2"
    assert updated.level_name == "Upper"
    assert updated.lock_version == level.lock_version + 1
    assert Repo.get!(Stop, child.id).level_id == "L2"
    assert Repo.get!(Stop, child.id).lock_version == child.lock_version + 1
    assert Repo.get!(Stop, other_child.id).level_id == "L2"
    assert Repo.get!(Stop, untouched.id).level_id == "L1"
    assert Repo.get!(Translation, translation.id).record_id == "L2"
    assert Repo.get!(Translation, foreign_translation.id).record_id == "L1"
    assert Repo.get!(StopLevel, attached.id).level_id == level.id
    assert [%{action: "updated", changed_fields: fields}] = logs(scope.audit, :level, level.id)
    assert fields["level_id"] == ["L1", "L2"]
    assert fields["references"] == %{"stops" => 2, "translations" => 1}
    assert fields["level_name"] == %{"from" => level.level_name, "to" => "Upper"}

    assert {:error, {:stale, 2}} =
             Stations.update_level(scope.audit, level.id, %{level_name: "Stale"}, 1)

    assert Repo.get!(Level, level.id).level_name == "Upper"
    assert length(logs(scope.audit, :level, level.id)) == 1
  end

  test "only a level attached to the selected station can be edited or removed", scope do
    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)
    level = level_fixture(scope.organization.id, scope.version.id)

    other_audit = %{scope.audit | station_stop_id: other_station.stop_id}
    assert {:ok, attached} = Stations.add_existing_level(other_audit, level.id)

    assert {:error, :not_found} =
             Stations.update_level(scope.audit, level.id, %{level_name: "Denied"}, 1)

    assert {:error, :not_found} =
             Stations.remove_level_from_station(scope.audit, level.id, attached.lock_version)

    assert Repo.get!(Level, level.id).level_name == level.level_name
    assert Repo.get!(StopLevel, attached.id)
    assert logs(scope.audit, :level, level.id) == []
  end

  test "removal checks stop-level revision and clears descendants with history", scope do
    level = level_fixture(scope.organization.id, scope.version.id, level_id: "L1")
    assert {:ok, attached} = Stations.add_existing_level(scope.audit, level.id)

    platform =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: "L1",
        diagram_coordinate: %{x: 10, y: 20}
      )

    boarding =
      child_stop_fixture(scope.organization.id, scope.version.id, platform.stop_id,
        level_id: "L1",
        location_type: 4,
        diagram_coordinate: %{x: 30, y: 40}
      )

    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)

    untouched =
      child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id,
        level_id: "L1",
        diagram_coordinate: %{x: 50, y: 60}
      )

    assert {:error, {:stale, 1}} =
             Stations.remove_level_from_station(scope.audit, level.id, 0)

    assert Repo.get!(StopLevel, attached.id)
    assert Repo.get!(Stop, platform.id).level_id == "L1"
    assert logs(scope.audit, :stop, platform.id) == []

    assert {:ok, :removed} =
             Stations.remove_level_from_station(scope.audit, level.id, attached.lock_version)

    assert Repo.get(StopLevel, attached.id) == nil
    assert Repo.get!(Level, level.id)

    for stop <- [platform, boarding] do
      cleared = Repo.get!(Stop, stop.id)
      assert cleared.level_id == nil
      assert cleared.diagram_coordinate == nil
      assert cleared.lock_version == stop.lock_version + 1

      assert [%{action: "updated", changed_fields: fields}] =
               logs(scope.audit, :stop, stop.id)

      assert fields["level_id"] == %{"from" => "L1", "to" => nil}
    end

    assert Repo.get!(Stop, untouched.id).level_id == "L1"
    assert Repo.get!(Stop, untouched.id).diagram_coordinate != nil

    assert [%{action: "deleted"}, %{action: "created"}] =
             logs(scope.audit, :stop_level, attached.id)
  end

  test "revocation and a failed history insert leave level changes untouched", scope do
    level = level_fixture(scope.organization.id, scope.version.id, level_id: "L1")
    assert {:ok, attached} = Stations.add_existing_level(scope.audit, level.id)

    child =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: "L1"
      )

    invalid_audit = %{scope.audit | actor_email: nil}

    assert {:error, %Ecto.Changeset{}} =
             Stations.create_station_level(
               invalid_audit,
               %{level_id: "FAILED", level_index: 2},
               %{}
             )

    assert Repo.get_by(Level, organization_id: scope.organization.id, level_id: "FAILED") == nil

    assert {:error, %Ecto.Changeset{}} =
             Stations.update_level(invalid_audit, level.id, %{level_id: "FAILED"}, 1)

    assert {:error, %Ecto.Changeset{}} =
             Stations.remove_level_from_station(invalid_audit, level.id, attached.lock_version)

    assert Repo.get!(Level, level.id).level_id == "L1"
    assert Repo.get!(StopLevel, attached.id)
    assert Repo.get!(Stop, child.id).level_id == "L1"
    assert logs(scope.audit, :level, level.id) == []
    assert logs(scope.audit, :stop, child.id) == []

    membership =
      GtfsPlanner.Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)

    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Stations.create_station_level(
               scope.audit,
               %{level_id: "DENIED", level_index: 2},
               %{}
             )

    assert {:error, :forbidden} =
             Stations.update_level(scope.audit, level.id, %{level_name: "Denied"}, 1)

    assert {:error, :forbidden} =
             Stations.remove_level_from_station(scope.audit, level.id, attached.lock_version)

    assert Repo.get_by(Level, organization_id: scope.organization.id, level_id: "DENIED") == nil
    assert Repo.get!(Level, level.id).level_name == level.level_name
    assert Repo.get!(StopLevel, attached.id)
  end

  @tag :unboxed
  test "a version-exclusive holder blocks level removal", _scope do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    scope = unboxed(&seed_unboxed_scope/0)
    on_exit(fn -> unboxed(fn -> cleanup_unboxed(scope) end) end)
    parent = self()

    holder =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            Versions.lock_for_exclusive_write!(scope.organization.id, scope.version.id)
            send(parent, {:holder_locked, backend_pid()})

            receive do
              :release -> :ok
            after
              @rendezvous_timeout -> raise "exclusive holder was not released"
            end
          end)
        end)
      end)

    assert_receive {:holder_locked, holder_backend}, @rendezvous_timeout

    removal =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid()
          send(parent, {:removal_ready, backend})

          Stations.remove_level_from_station(
            scope.audit,
            scope.level.id,
            scope.stop_level.lock_version
          )
        end)
      end)

    assert_receive {:removal_ready, removal_backend}, @rendezvous_timeout

    assert :ok ==
             unboxed(fn ->
               await_blocker(removal_backend, holder_backend, deadline())
             end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, @collect_timeout)
    assert {:ok, :removed} = Task.await(removal, @collect_timeout)
    assert unboxed(fn -> Repo.get(StopLevel, scope.stop_level.id) end) == nil
  end

  defp seed_unboxed_scope do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, location_type: 1)
    level = level_fixture(organization.id, version.id)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: station.stop_id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    {:ok, stop_level} = Stations.add_existing_level(audit, level.id)

    %{
      organization: organization,
      version: version,
      actor: actor,
      level: level,
      stop_level: stop_level,
      audit: audit
    }
  end

  defp cleanup_unboxed(scope) do
    org_id = scope.organization.id
    Repo.delete_all(from row in ChangeLog, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in StopLevel, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in Stop, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in Level, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in UserOrgMembership, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in GtfsVersion, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in Organization, where: row.id == ^org_id)
    Repo.delete_all(from row in User, where: row.id == ^scope.actor.id)
  end

  defp translation(organization_id, version_id, record_id) do
    %Translation{}
    |> Translation.changeset(%{
      organization_id: organization_id,
      gtfs_version_id: version_id,
      table_name: "levels",
      field_name: "level_name",
      language: "es",
      translation: "Piso",
      record_id: record_id
    })
    |> Repo.insert!()
  end

  defp logs(audit, type, id) do
    Audit.list_change_logs_for_entity(
      audit.organization_id,
      audit.gtfs_version_id,
      Atom.to_string(type),
      id
    )
  end

  defp station_level_count(scope) do
    from(sl in StopLevel,
      where:
        sl.organization_id == ^scope.organization.id and
          sl.gtfs_version_id == ^scope.version.id and sl.stop_id == ^scope.station.id
    )
    |> Repo.aggregate(:count)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @rendezvous_timeout
end

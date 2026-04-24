defmodule GtfsPlanner.Gtfs.ChangeLogTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  @valid_attrs %{
    entity_type: "stop",
    entity_id: Ecto.UUID.generate(),
    entity_external_id: "platform_a",
    station_stop_id: "station_central",
    actor_id: Ecto.UUID.generate(),
    actor_email: "user@example.com",
    snapshot: %{"stop_name" => "Platform A"},
    changed_fields: %{"stop_name" => %{"from" => "Old Name", "to" => "Platform A"}},
    action: "updated",
    organization_id: Ecto.UUID.generate(),
    gtfs_version_id: Ecto.UUID.generate()
  }

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      changeset = ChangeLog.changeset(%ChangeLog{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid entity_type returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :entity_type, "invalid"))
      refute changeset.valid?
      assert has_error?(changeset, :entity_type, "is invalid")
    end

    test "invalid action returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "invalid"))
      refute changeset.valid?
      assert has_error?(changeset, :action, "is invalid")
    end

    test "missing entity_type returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :entity_type))
      refute changeset.valid?
      assert has_error?(changeset, :entity_type, "can't be blank")
    end

    test "missing action returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :action))
      refute changeset.valid?
      assert has_error?(changeset, :action, "can't be blank")
    end

    test "missing entity_id returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :entity_id))
      refute changeset.valid?
      assert has_error?(changeset, :entity_id, "can't be blank")
    end

    test "missing organization_id returns error" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.delete(@valid_attrs, :organization_id))
      refute changeset.valid?
      assert has_error?(changeset, :organization_id, "can't be blank")
    end

    test "snapshot and changed_fields are optional" do
      attrs = Map.merge(@valid_attrs, %{snapshot: nil, changed_fields: nil})
      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      assert changeset.valid?
    end

    test "allows rolled_back action" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "rolled_back"))
      assert changeset.valid?
    end

    test "allows deleted action" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "deleted"))
      assert changeset.valid?
    end

    test "allows created action" do
      changeset = ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :action, "created"))
      assert changeset.valid?
    end

    test "sets rolled_back_to_log_id when provided" do
      log_id = Ecto.UUID.generate()
      attrs = Map.put(@valid_attrs, :rolled_back_to_log_id, log_id)
      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :rolled_back_to_log_id) == log_id
    end
  end

  describe "record_change/5" do
    setup do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)

      ctx = %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        station_stop_id: "station_central",
        actor_id: Ecto.UUID.generate(),
        actor_email: "user@example.com"
      }

      %{org: org, version: version, ctx: ctx}
    end

    test "stop created inserts row with nil snapshot", %{org: org, version: version, ctx: ctx} do
      attrs = %{stop_id: "stop_new", stop_name: "New Stop"}

      assert :ok = Gtfs.record_change(ctx, :stop, nil, "created", attrs)

      [log] = Repo.all(ChangeLog)
      assert log.entity_type == "stop"
      assert log.entity_external_id == "stop_new"
      assert log.station_stop_id == "station_central"
      assert log.action == "created"
      assert is_nil(log.snapshot)
      assert is_nil(log.changed_fields)
      assert log.organization_id == org.id
      assert log.gtfs_version_id == version.id
    end

    test "stop updated inserts row with snapshot and changed_fields", %{ctx: ctx} do
      stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        stop_id: "stop_one",
        stop_name: "Old Name",
        stop_desc: "Old Desc"
      })

      attrs = %{stop_name: "New Name", stop_desc: "Old Desc"}

      assert :ok = Gtfs.record_change(ctx, :stop, stop, "updated", attrs)

      [log] = Repo.all(ChangeLog)
      assert log.entity_type == "stop"
      assert log.entity_id == stop.id
      assert log.entity_external_id == "stop_one"
      assert log.action == "updated"
      assert log.snapshot["stop_name"] == "Old Name"
      assert log.snapshot["stop_desc"] == "Old Desc"
      assert log.changed_fields["stop_name"] == %{"from" => "Old Name", "to" => "New Name"}
      refute Map.has_key?(log.changed_fields, "stop_desc")
    end

    test "stop deleted inserts row with snapshot", %{ctx: ctx} do
      stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        stop_id: "stop_del",
        stop_name: "Delete Me"
      })

      assert :ok = Gtfs.record_change(ctx, :stop, stop, "deleted", %{})

      [log] = Repo.all(ChangeLog)
      assert log.entity_type == "stop"
      assert log.entity_id == stop.id
      assert log.action == "deleted"
      assert log.snapshot["stop_name"] == "Delete Me"
      assert is_nil(log.changed_fields)
    end

    test "pathway updated records correct pathway fields", %{ctx: ctx} do
      from_stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{stop_id: "from_s"})
      to_stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{stop_id: "to_s"})

      pw = pathway_fixture(ctx.organization_id, ctx.gtfs_version_id, from_stop.stop_id, to_stop.stop_id, %{
        pathway_id: "pw_one",
        pathway_mode: 1,
        is_bidirectional: true,
        traversal_time: 60
      })

      attrs = %{traversal_time: 120, is_bidirectional: false}

      assert :ok = Gtfs.record_change(ctx, :pathway, pw, "updated", attrs)

      [log] = Repo.all(ChangeLog)
      assert log.entity_type == "pathway"
      assert log.entity_id == pw.id
      assert log.entity_external_id == "pw_one"
      assert log.snapshot["pathway_mode"] == 1
      assert log.snapshot["traversal_time"] == 60
      assert log.changed_fields["traversal_time"] == %{"from" => 60, "to" => 120}
      assert log.changed_fields["is_bidirectional"] == %{"from" => true, "to" => false}
    end

    test "level updated records correct level fields", %{ctx: ctx} do
      level = level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        level_id: "L_test",
        level_name: "Ground Floor",
        level_index: 0.0
      })

      attrs = %{level_name: "First Floor", level_index: 0.5}

      assert :ok = Gtfs.record_change(ctx, :level, level, "updated", attrs)

      [log] = Repo.all(ChangeLog)
      assert log.entity_type == "level"
      assert log.entity_id == level.id
      assert log.entity_external_id == "L_test"
      assert log.snapshot["level_name"] == "Ground Floor"
      assert log.snapshot["level_index"] == 0.0
      assert log.changed_fields["level_name"] == %{"from" => "Ground Floor", "to" => "First Floor"}
      assert log.changed_fields["level_index"] == %{"from" => 0.0, "to" => 0.5}
    end

    test "changed_fields is empty map when no fields change", %{ctx: ctx} do
      stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        stop_id: "stop_same",
        stop_name: "Same Name"
      })

      attrs = %{stop_name: "Same Name"}

      assert :ok = Gtfs.record_change(ctx, :stop, stop, "updated", attrs)

      [log] = Repo.all(ChangeLog)
      assert log.changed_fields == %{}
    end
  end

  describe "list_change_logs_for_entity/4" do
    setup do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)

      ctx = %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        station_stop_id: "station_c",
        actor_id: Ecto.UUID.generate(),
        actor_email: "user@example.com"
      }

      %{org: org, version: version, ctx: ctx}
    end

    test "returns entries ordered most recent first", %{org: org, version: version, ctx: ctx} do
      stop = stop_fixture(org.id, version.id, %{stop_id: "stop_log", stop_name: "First"})

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Second"})
      :timer.sleep(10)
      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Third"})

      logs = Gtfs.list_change_logs_for_entity(org.id, version.id, "stop", stop.id)
      assert length(logs) == 2

      [first, second] = logs
      assert DateTime.compare(first.inserted_at, second.inserted_at) == :gt
    end

    test "returns empty list for entity with no history", %{org: org, version: version} do
      logs = Gtfs.list_change_logs_for_entity(org.id, version.id, "stop", Ecto.UUID.generate())
      assert logs == []
    end

    test "does not return entries for different entity_type", %{org: org, version: version, ctx: ctx} do
      stop = stop_fixture(org.id, version.id, %{stop_id: "stop_typed"})
      level = level_fixture(org.id, version.id, %{level_id: "L_typed"})

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "New"})
      Gtfs.record_change(ctx, :level, level, "updated", %{level_name: "New Level"})

      stop_logs = Gtfs.list_change_logs_for_entity(org.id, version.id, "stop", stop.id)
      assert length(stop_logs) == 1
      assert hd(stop_logs).entity_type == "stop"

      level_logs = Gtfs.list_change_logs_for_entity(org.id, version.id, "level", level.id)
      assert length(level_logs) == 1
      assert hd(level_logs).entity_type == "level"
    end
  end

  describe "rollback_entity/1" do
    setup do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)

      ctx = %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        station_stop_id: "station_rb",
        actor_id: Ecto.UUID.generate(),
        actor_email: "user@example.com"
      }

      %{org: org, version: version, ctx: ctx}
    end

    test "restores stop fields from snapshot and inserts rolled_back entry", %{ctx: ctx} do
      stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        stop_id: "stop_rb",
        stop_name: "Original",
        stop_desc: "Original desc",
        location_type: 0
      })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed", stop_desc: "New desc"})
      log = Repo.one!(ChangeLog)

      {:ok, restored} = Gtfs.rollback_entity(log)
      assert restored.stop_name == "Original"
      assert restored.stop_desc == "Original desc"
      assert restored.stop_id == "stop_rb"

      rollback_logs = Repo.all(from cl in ChangeLog, where: cl.action == "rolled_back")
      assert length(rollback_logs) == 1
      assert hd(rollback_logs).rolled_back_to_log_id == log.id
      assert hd(rollback_logs).entity_id == stop.id
    end

    test "restores pathway fields from snapshot", %{ctx: ctx} do
      from_s = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{stop_id: "from_pw_rb"})
      to_s = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{stop_id: "to_pw_rb"})

      pw = pathway_fixture(ctx.organization_id, ctx.gtfs_version_id, from_s.stop_id, to_s.stop_id, %{
        pathway_id: "pw_rb",
        pathway_mode: 1,
        traversal_time: 60,
        signposted_as: "To Platform"
      })

      Gtfs.record_change(ctx, :pathway, pw, "updated", %{
        signposted_as: "To Exit",
        traversal_time: 90
      })
      log = Repo.one!(ChangeLog)

      {:ok, restored} = Gtfs.rollback_entity(log)
      assert restored.signposted_as == "To Platform"
      assert restored.traversal_time == 60
      assert restored.pathway_id == "pw_rb"
    end

    test "restores level fields from snapshot", %{ctx: ctx} do
      level = level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        level_id: "L_rb",
        level_name: "Original Level",
        level_index: 1.0
      })

      Gtfs.record_change(ctx, :level, level, "updated", %{level_name: "Changed Level", level_index: 2.0})
      log = Repo.one!(ChangeLog)

      {:ok, restored} = Gtfs.rollback_entity(log)
      assert restored.level_name == "Original Level"
      assert restored.level_index == 1.0
      assert restored.level_id == "L_rb"
    end

    test "rejects created action", %{ctx: ctx} do
      attrs = %{stop_id: "stop_cr", stop_name: "Created Stop"}
      Gtfs.record_change(ctx, :stop, nil, "created", attrs)

      log = Repo.one!(ChangeLog)
      assert {:error, :cannot_rollback_create_or_delete} = Gtfs.rollback_entity(log)
    end

    test "rejects deleted action", %{ctx: ctx} do
      stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        stop_id: "stop_del_rb",
        stop_name: "Deleted Stop"
      })
      Gtfs.record_change(ctx, :stop, stop, "deleted", %{})
      log = Repo.one!(ChangeLog)

      assert {:error, :cannot_rollback_create_or_delete} = Gtfs.rollback_entity(log)
    end

    test "returns entity_not_found for non-existent entity", %{ctx: ctx} do
      stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        stop_id: "stop_gone",
        stop_name: "Will Be Deleted"
      })
      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)
      Gtfs.delete_stop(stop)

      assert {:error, :entity_not_found} = Gtfs.rollback_entity(log)
    end

    test "does not change identity fields on rollback", %{ctx: ctx} do
      stop = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
        stop_id: "stop_identity",
        stop_name: "Original"
      })

      original_stop_id = stop.stop_id

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)

      # Artificially set a different stop_id in snapshot to verify it is ignored
      tampered_log = %{log | snapshot: Map.put(log.snapshot, "stop_id", "hacked_id")}

      {:ok, restored} = Gtfs.rollback_entity(tampered_log)
      assert restored.stop_id == original_stop_id
    end
  end

  describe "get_change_log!/1" do
    test "returns entry when it exists" do
      org = organization_fixture()
      version = gtfs_version_fixture(org.id)

      ctx = %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        station_stop_id: "station_g",
        actor_id: Ecto.UUID.generate(),
        actor_email: "user@example.com"
      }

      stop = stop_fixture(org.id, version.id, %{stop_id: "stop_get", stop_name: "Get Me"})
      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)

      assert Gtfs.get_change_log!(log.id).id == log.id
    end

    test "raises when entry does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Gtfs.get_change_log!(Ecto.UUID.generate())
      end
    end
  end

  defp has_error?(changeset, field, message) do
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    Map.get(errors, field, []) |> Enum.member?(message)
  end
end

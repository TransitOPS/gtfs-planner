defmodule GtfsPlanner.Gtfs.ChangeLogTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
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
      changeset =
        ChangeLog.changeset(%ChangeLog{}, Map.put(@valid_attrs, :entity_type, "invalid"))

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
      attrs =
        Map.merge(@valid_attrs, %{
          action: "rolled_back",
          rolled_back_to_log_id: Ecto.UUID.generate()
        })

      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
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

    test "sets rolled_back_to_log_id when provided on rolled_back action" do
      log_id = Ecto.UUID.generate()

      attrs =
        Map.merge(@valid_attrs, %{
          action: "rolled_back",
          rolled_back_to_log_id: log_id
        })

      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :rolled_back_to_log_id) == log_id
    end

    test "created action allows nil entity_id" do
      attrs = Map.merge(@valid_attrs, %{action: "created", entity_id: nil})
      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      assert changeset.valid?
    end

    test "non-created action with nil entity_id returns error" do
      attrs = Map.put(@valid_attrs, :entity_id, nil)
      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      refute changeset.valid?
      assert has_error?(changeset, :entity_id, "can't be blank")
    end

    test "rolled_back action without rolled_back_to_log_id returns error" do
      attrs =
        Map.merge(@valid_attrs, %{
          action: "rolled_back",
          rolled_back_to_log_id: nil
        })

      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      refute changeset.valid?

      assert has_error?(
               changeset,
               :rolled_back_to_log_id,
               "must be set when action is rolled_back"
             )
    end

    test "non-rolled_back action with rolled_back_to_log_id set returns error" do
      attrs = Map.put(@valid_attrs, :rolled_back_to_log_id, Ecto.UUID.generate())
      changeset = ChangeLog.changeset(%ChangeLog{}, attrs)
      refute changeset.valid?

      assert has_error?(
               changeset,
               :rolled_back_to_log_id,
               "must not be set unless action is rolled_back"
             )
    end
  end

  describe "reversible_fields_for/1" do
    test "stop fields include reversible user fields and exclude identity and system fields" do
      fields = Gtfs.reversible_fields_for(:stop)

      assert "stop_name" in fields
      refute "stop_id" in fields
      refute "organization_id" in fields
      refute "gtfs_version_id" in fields
    end

    test "unknown entity types fail fast" do
      assert_raise FunctionClauseError, fn ->
        Gtfs.reversible_fields_for("shape")
      end
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

    test "stop created inserts row with nil snapshot and nil entity_id", %{
      org: org,
      version: version,
      ctx: ctx
    } do
      attrs = %{stop_id: "stop_new", stop_name: "New Stop"}

      assert :ok = Gtfs.record_change(ctx, :stop, nil, "created", attrs)

      [log] = Repo.all(ChangeLog)
      assert log.entity_type == "stop"
      assert is_nil(log.entity_id)
      assert log.entity_external_id == "stop_new"
      assert log.station_stop_id == "station_central"
      assert log.action == "created"
      assert is_nil(log.snapshot)
      assert is_nil(log.changed_fields)
      assert log.organization_id == org.id
      assert log.gtfs_version_id == version.id
    end

    test "stop updated inserts row with snapshot and changed_fields", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_one",
          stop_name: "Old Name",
          stop_desc: "Old Desc",
          diagram_coordinate: %{"x" => 12.5, "y" => 34.0}
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
      assert log.snapshot["diagram_coordinate"] == %{"x" => 12.5, "y" => 34.0}
      assert log.changed_fields["stop_name"] == %{"from" => "Old Name", "to" => "New Name"}
      refute Map.has_key?(log.changed_fields, "stop_desc")
    end

    test "stop deleted inserts row with snapshot", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
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

      pw =
        pathway_fixture(
          ctx.organization_id,
          ctx.gtfs_version_id,
          from_stop.stop_id,
          to_stop.stop_id,
          %{
            pathway_id: "pw_one",
            pathway_mode: 1,
            is_bidirectional: true,
            traversal_time: 60
          }
        )

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
      level =
        level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
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

      assert log.changed_fields["level_name"] == %{
               "from" => "Ground Floor",
               "to" => "First Floor"
             }

      assert log.changed_fields["level_index"] == %{"from" => 0.0, "to" => 0.5}
    end

    test "changed_fields is empty map when no fields change", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
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
      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Third"})

      logs = Gtfs.list_change_logs_for_entity(org.id, version.id, "stop", stop.id)
      assert length(logs) == 2

      [first, second] = logs
      assert DateTime.compare(first.inserted_at, second.inserted_at) != :lt
    end

    test "returns empty list for entity with no history", %{org: org, version: version} do
      logs = Gtfs.list_change_logs_for_entity(org.id, version.id, "stop", Ecto.UUID.generate())
      assert logs == []
    end

    test "does not return entries for different entity_type", %{
      org: org,
      version: version,
      ctx: ctx
    } do
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

  describe "rollback_target_snapshot/1" do
    test "fills missing coordinate from changed_fields without a snapshot value" do
      old_coordinate = %{"x" => 12.5, "y" => 34.0}
      new_coordinate = %{"x" => 90.0, "y" => 45.25}

      log = %ChangeLog{
        action: "updated",
        snapshot: %{},
        changed_fields: %{
          "diagram_coordinate" => %{"from" => old_coordinate, "to" => new_coordinate}
        }
      }

      assert {:ok, target_snapshot} = Gtfs.rollback_target_snapshot(log)
      assert target_snapshot["diagram_coordinate"] == old_coordinate
    end
  end

  describe "rollback_entity/2" do
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
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_rb",
          stop_name: "Original",
          stop_desc: "Original desc",
          location_type: 0
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{
        stop_name: "Changed",
        stop_desc: "New desc"
      })

      {:ok, _changed_stop} =
        Gtfs.update_stop(stop, %{stop_name: "Changed", stop_desc: "New desc"})

      log = Repo.one!(ChangeLog)

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)
      assert restored.stop_name == "Original"
      assert restored.stop_desc == "Original desc"
      assert restored.stop_id == "stop_rb"

      rollback_logs = Repo.all(from cl in ChangeLog, where: cl.action == "rolled_back")
      assert length(rollback_logs) == 1
      assert hd(rollback_logs).rolled_back_to_log_id == log.id
      assert hd(rollback_logs).entity_id == stop.id
    end

    test "rejects no-op rollback without updating entity or inserting rolled_back entry", %{
      ctx: ctx
    } do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_noop_rb",
          stop_name: "Original",
          stop_desc: "Original desc"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)
      before_rollback = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)

      assert {:error, :already_matches_current} = Gtfs.rollback_entity(log, ctx)

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
      assert reloaded.stop_name == "Original"
      assert reloaded.stop_desc == "Original desc"
      assert reloaded.updated_at == before_rollback.updated_at
      assert Repo.all(from cl in ChangeLog, where: cl.action == "rolled_back") == []
    end

    test "restores pathway fields from snapshot", %{ctx: ctx} do
      from_s = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{stop_id: "from_pw_rb"})
      to_s = stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{stop_id: "to_pw_rb"})

      pw =
        pathway_fixture(ctx.organization_id, ctx.gtfs_version_id, from_s.stop_id, to_s.stop_id, %{
          pathway_id: "pw_rb",
          pathway_mode: 1,
          traversal_time: 60,
          signposted_as: "To Platform"
        })

      Gtfs.record_change(ctx, :pathway, pw, "updated", %{
        signposted_as: "To Exit",
        traversal_time: 90
      })

      {:ok, _changed_pathway} =
        Gtfs.update_pathway(pw, %{signposted_as: "To Exit", traversal_time: 90})

      log = Repo.one!(ChangeLog)

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)
      assert restored.signposted_as == "To Platform"
      assert restored.traversal_time == 60
      assert restored.pathway_id == "pw_rb"
    end

    test "restores level fields from snapshot", %{ctx: ctx} do
      level =
        level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          level_id: "L_rb",
          level_name: "Original Level",
          level_index: 1.0
        })

      Gtfs.record_change(ctx, :level, level, "updated", %{
        level_name: "Changed Level",
        level_index: 2.0
      })

      {:ok, _changed_level} =
        Gtfs.update_level(level, %{level_name: "Changed Level", level_index: 2.0})

      log = Repo.one!(ChangeLog)

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)
      assert restored.level_name == "Original Level"
      assert restored.level_index == 1.0
      assert restored.level_id == "L_rb"
    end

    test "rejects created action", %{ctx: ctx} do
      attrs = %{stop_id: "stop_cr", stop_name: "Created Stop"}
      Gtfs.record_change(ctx, :stop, nil, "created", attrs)

      log = Repo.one!(ChangeLog)
      assert {:error, :cannot_rollback_create_or_delete} = Gtfs.rollback_entity(log, ctx)
    end

    test "rejects deleted action", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_del_rb",
          stop_name: "Deleted Stop"
        })

      Gtfs.record_change(ctx, :stop, stop, "deleted", %{})
      log = Repo.one!(ChangeLog)

      assert {:error, :cannot_rollback_create_or_delete} = Gtfs.rollback_entity(log, ctx)
    end

    test "rejects updated log with nil snapshot without mutating entity", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_nil_upd",
          stop_name: "Untouched"
        })

      {:ok, log} =
        Repo.insert(%ChangeLog{
          organization_id: ctx.organization_id,
          gtfs_version_id: ctx.gtfs_version_id,
          station_stop_id: ctx.station_stop_id,
          entity_type: "stop",
          entity_id: stop.id,
          entity_external_id: stop.stop_id,
          action: "updated",
          snapshot: nil,
          changed_fields: nil,
          actor_id: ctx.actor_id,
          actor_email: ctx.actor_email
        })

      assert {:error, :missing_rollback_snapshot} = Gtfs.rollback_entity(log, ctx)

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
      assert reloaded.stop_name == "Untouched"
      assert Repo.all(from cl in ChangeLog, where: cl.action == "rolled_back") == []
    end

    test "rejects rolled_back log with nil snapshot without mutating entity", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_nil_rb",
          stop_name: "Untouched"
        })

      {:ok, prior_log} =
        Repo.insert(%ChangeLog{
          organization_id: ctx.organization_id,
          gtfs_version_id: ctx.gtfs_version_id,
          station_stop_id: ctx.station_stop_id,
          entity_type: "stop",
          entity_id: stop.id,
          entity_external_id: stop.stop_id,
          action: "updated",
          snapshot: %{"stop_name" => "Prior"},
          changed_fields: %{"stop_name" => %{"from" => "Untouched", "to" => "Prior"}},
          actor_id: ctx.actor_id,
          actor_email: ctx.actor_email
        })

      {:ok, log} =
        Repo.insert(%ChangeLog{
          organization_id: ctx.organization_id,
          gtfs_version_id: ctx.gtfs_version_id,
          station_stop_id: ctx.station_stop_id,
          entity_type: "stop",
          entity_id: stop.id,
          entity_external_id: stop.stop_id,
          action: "rolled_back",
          snapshot: nil,
          changed_fields: nil,
          rolled_back_to_log_id: prior_log.id,
          actor_id: ctx.actor_id,
          actor_email: ctx.actor_email
        })

      assert {:error, :missing_rollback_snapshot} = Gtfs.rollback_entity(log, ctx)

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
      assert reloaded.stop_name == "Untouched"

      assert Repo.all(
               from cl in ChangeLog, where: cl.action == "rolled_back" and cl.id != ^log.id
             ) ==
               []
    end

    test "returns entity_not_found for non-existent entity", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_gone",
          stop_name: "Will Be Deleted"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)
      Gtfs.delete_stop(stop)

      assert {:error, :entity_not_found} = Gtfs.rollback_entity(log, ctx)
    end

    test "rolling back a coordinate-only stop update restores diagram_coordinate", %{ctx: ctx} do
      original_coordinate = %{"x" => 12.5, "y" => 34.0}
      moved_coordinate = %{"x" => 90.0, "y" => 45.25}

      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_coord_rb",
          stop_name: "Platform",
          diagram_coordinate: original_coordinate
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{
        diagram_coordinate: moved_coordinate
      })

      {:ok, _moved} = Gtfs.update_stop(stop, %{diagram_coordinate: moved_coordinate})

      log = Repo.one!(from cl in ChangeLog, where: cl.action == "updated")

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)
      assert restored.diagram_coordinate == original_coordinate
      assert restored.stop_id == "stop_coord_rb"
    end

    test "rolling back a stop update restores diagram_coordinate and level_id", %{ctx: ctx} do
      original_coordinate = %{"x" => 12.5, "y" => 34.0}
      moved_coordinate = %{"x" => 90.0, "y" => 45.25}

      level_a =
        level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{level_id: "L_coord_a"})

      level_b =
        level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{level_id: "L_coord_b"})

      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_coord_level_rb",
          stop_name: "Platform",
          diagram_coordinate: original_coordinate,
          level_id: level_a.level_id
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{
        diagram_coordinate: moved_coordinate,
        level_id: level_b.level_id
      })

      {:ok, _moved} =
        Gtfs.update_stop(stop, %{
          diagram_coordinate: moved_coordinate,
          level_id: level_b.level_id
        })

      log = Repo.one!(from cl in ChangeLog, where: cl.action == "updated")

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)
      assert restored.diagram_coordinate == original_coordinate
      assert restored.level_id == level_a.level_id
      assert restored.stop_id == "stop_coord_level_rb"
    end

    test "rolling back historical coordinate log restores from changed_fields fallback", %{
      ctx: ctx
    } do
      original_coordinate = %{"x" => 12.5, "y" => 34.0}
      moved_coordinate = %{"x" => 90.0, "y" => 45.25}

      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_coord_legacy_rb",
          stop_name: "Platform",
          diagram_coordinate: original_coordinate
        })

      {:ok, moved_stop} = Gtfs.update_stop(stop, %{diagram_coordinate: moved_coordinate})

      {:ok, log} =
        Repo.insert(%ChangeLog{
          organization_id: ctx.organization_id,
          gtfs_version_id: ctx.gtfs_version_id,
          station_stop_id: ctx.station_stop_id,
          entity_type: "stop",
          entity_id: moved_stop.id,
          entity_external_id: moved_stop.stop_id,
          action: "updated",
          snapshot: %{"stop_name" => "Platform"},
          changed_fields: %{
            "diagram_coordinate" => %{
              "from" => original_coordinate,
              "to" => moved_coordinate
            }
          },
          actor_id: ctx.actor_id,
          actor_email: ctx.actor_email
        })

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)
      assert restored.diagram_coordinate == original_coordinate
      assert restored.stop_name == "Platform"
    end

    test "rolling back a stop update restores level_id", %{ctx: ctx} do
      level_a =
        level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{level_id: "L_stop_a"})

      level_b =
        level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{level_id: "L_stop_b"})

      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_level_rb",
          stop_name: "Platform",
          level_id: level_a.level_id
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{level_id: level_b.level_id})

      {:ok, _moved} = Gtfs.update_stop(stop, %{level_id: level_b.level_id})

      log = Repo.one!(from cl in ChangeLog, where: cl.action == "updated")

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)
      assert restored.level_id == level_a.level_id
      assert restored.stop_id == "stop_level_rb"
    end

    test "rolling back a level update does not attempt to change level_id", %{ctx: ctx} do
      level =
        level_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          level_id: "L_identity",
          level_name: "Ground",
          level_index: 0.0
        })

      original_level_id = level.level_id

      Gtfs.record_change(ctx, :level, level, "updated", %{level_name: "Changed"})
      {:ok, _changed_level} = Gtfs.update_level(level, %{level_name: "Changed"})
      log = Repo.one!(ChangeLog)

      tampered_log = %{log | snapshot: Map.put(log.snapshot, "level_id", "hacked_level")}

      {:ok, restored} = Gtfs.rollback_entity(tampered_log, ctx)
      assert restored.level_id == original_level_id
      assert restored.level_name == "Ground"
    end

    test "does not broadcast or mutate entity when rollback log insertion fails", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_nobcast",
          stop_name: "Original",
          stop_desc: "Original desc"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      {:ok, _changed_stop} = Gtfs.update_stop(stop, %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)
      before_rollback = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
      :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      # Tamper a field that is required by ChangeLog.changeset/2 but is NOT
      # checked by the cross-org/version guard. This forces insert_rollback_log/3
      # to fail inside the Multi instead of being rejected by the guard before
      # the transaction starts.
      tampered_log = %{log | entity_external_id: nil}

      assert {:error, :rollback_log_failed} = Gtfs.rollback_entity(tampered_log, ctx)

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
      assert reloaded.stop_name == before_rollback.stop_name
      assert reloaded.stop_desc == before_rollback.stop_desc
      assert reloaded.updated_at == before_rollback.updated_at

      refute_receive {[:stops, :updated], _}
    end

    test "broadcasts entity update after successful rollback", %{ctx: ctx} do
      :ok = Phoenix.PubSub.subscribe(GtfsPlanner.PubSub, "stops")

      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_bcast",
          stop_name: "Original"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      {:ok, _changed_stop} = Gtfs.update_stop(stop, %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)

      {:ok, restored} = Gtfs.rollback_entity(log, ctx)

      assert_receive {[:stops, :updated], ^restored}
    end

    test "does not change identity fields on rollback", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_identity",
          stop_name: "Original"
        })

      original_stop_id = stop.stop_id

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      {:ok, _changed_stop} = Gtfs.update_stop(stop, %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)

      # Artificially set a different stop_id in snapshot to verify it is ignored
      tampered_log = %{log | snapshot: Map.put(log.snapshot, "stop_id", "hacked_id")}

      {:ok, restored} = Gtfs.rollback_entity(tampered_log, ctx)
      assert restored.stop_id == original_stop_id
    end

    test "rolled_back log row stores snapshot of pre-rollback entity state", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_reverse",
          stop_name: "Original",
          stop_desc: "Original desc"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{
        stop_name: "Updated",
        stop_desc: "Updated desc"
      })

      {:ok, _updated_stop} =
        Gtfs.update_stop(stop, %{stop_name: "Updated", stop_desc: "Updated desc"})

      update_log = Repo.one!(from cl in ChangeLog, where: cl.action == "updated")

      {:ok, _reverted} = Gtfs.rollback_entity(update_log, ctx)

      rollback_log = Repo.one!(from cl in ChangeLog, where: cl.action == "rolled_back")
      assert rollback_log.snapshot["stop_name"] == "Updated"
      assert rollback_log.snapshot["stop_desc"] == "Updated desc"

      {:ok, re_restored} = Gtfs.rollback_entity(rollback_log, ctx)
      assert re_restored.stop_name == "Updated"
      assert re_restored.stop_desc == "Updated desc"
      assert re_restored.stop_id == "stop_reverse"
    end

    test "rejects cross-org rollback with :unauthorized and does not mutate (R1)", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_xorg",
          stop_name: "Original"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)

      other_org = organization_fixture()
      other_version = gtfs_version_fixture(other_org.id)

      foreign_ctx = %AuditContext{
        organization_id: other_org.id,
        gtfs_version_id: other_version.id,
        station_stop_id: ctx.station_stop_id,
        actor_id: Ecto.UUID.generate(),
        actor_email: "intruder@example.com"
      }

      assert Gtfs.rollback_entity(log, foreign_ctx) == {:error, :unauthorized}

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
      assert reloaded.stop_name == "Original"

      assert Repo.all(from cl in ChangeLog, where: cl.action == "rolled_back") == []
    end

    test "rejects cross-version rollback with :unauthorized (R1)", %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_xver",
          stop_name: "Original"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      log = Repo.one!(ChangeLog)

      other_version = gtfs_version_fixture(ctx.organization_id)

      cross_version_ctx = %{ctx | gtfs_version_id: other_version.id}

      assert Gtfs.rollback_entity(log, cross_version_ctx) == {:error, :unauthorized}

      reloaded = Repo.get!(GtfsPlanner.Gtfs.Stop, stop.id)
      assert reloaded.stop_name == "Original"
    end

    test "rolled_back log records actor identity from rollback ctx, not original log (R2)",
         %{ctx: ctx} do
      stop =
        stop_fixture(ctx.organization_id, ctx.gtfs_version_id, %{
          stop_id: "stop_actor",
          stop_name: "Original"
        })

      Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Changed"})
      {:ok, _changed_stop} = Gtfs.update_stop(stop, %{stop_name: "Changed"})
      original_log = Repo.one!(from cl in ChangeLog, where: cl.action == "updated")

      reverter_id = Ecto.UUID.generate()
      reverter_email = "reverter@example.com"

      reverter_ctx = %{ctx | actor_id: reverter_id, actor_email: reverter_email}

      {:ok, _restored} = Gtfs.rollback_entity(original_log, reverter_ctx)

      rollback_log = Repo.one!(from cl in ChangeLog, where: cl.action == "rolled_back")
      assert rollback_log.actor_id == reverter_id
      assert rollback_log.actor_email == reverter_email
      refute rollback_log.actor_id == original_log.actor_id
      refute rollback_log.actor_email == original_log.actor_email
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

defmodule GtfsPlanner.Gtfs.Stations.StopLevelsTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.ConcurrencyHelpers
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.{User, UserOrgMembership}
  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.{
    Audit,
    AuditContext,
    ChangeLog,
    JournalEntry,
    Level,
    Pathway,
    StationJournal.Scope,
    Stations,
    Stop,
    StopLevel
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
    level = level_fixture(organization.id, version.id, level_id: "L1")

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
      station: station,
      level: level,
      stop_level: stop_level,
      audit: audit
    }
  end

  test "scale save recalculates derived lengths and preserves entered lengths", scope do
    from_stop =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: scope.level.level_id,
        diagram_coordinate: %{x: 0, y: 0}
      )

    to_stop =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: scope.level.level_id,
        diagram_coordinate: %{x: 5, y: 0}
      )

    far_stop =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: scope.level.level_id,
        diagram_coordinate: %{x: 10, y: 0}
      )

    derived =
      pathway_fixture(
        scope.organization.id,
        scope.version.id,
        from_stop.stop_id,
        to_stop.stop_id
      )

    entered =
      pathway_fixture(
        scope.organization.id,
        scope.version.id,
        from_stop.stop_id,
        far_stop.stop_id,
        %{length: Decimal.new("12.50")}
      )

    assert {:ok, %{stop_level: updated, recalculated_count: 1, kept_count: 1}} =
             Stations.save_scale(
               scope.audit,
               scope.stop_level.id,
               scale_attrs(),
               scope.stop_level.lock_version
             )

    assert updated.lock_version == scope.stop_level.lock_version + 1
    assert Decimal.equal?(Repo.get!(Pathway, derived.id).length, Decimal.new("10.00"))
    assert Decimal.equal?(Repo.get!(Pathway, entered.id).length, Decimal.new("12.50"))
    assert [%{action: "updated"}] = updated_logs(scope.audit, :stop_level, updated.id)
    assert [%{action: "updated"}] = updated_logs(scope.audit, :pathway, derived.id)
    assert updated_logs(scope.audit, :pathway, entered.id) == []
  end

  test "scale, clear and alignment commands refuse stale revisions without new history", scope do
    assert {:ok, %{stop_level: updated}} =
             Stations.save_scale(
               scope.audit,
               scope.stop_level.id,
               scale_attrs(),
               scope.stop_level.lock_version
             )

    assert {:error, {:stale, 2}} =
             Stations.save_scale(scope.audit, updated.id, scale_attrs(), 1)

    assert {:error, {:stale, 2}} = Stations.clear_scale(scope.audit, updated.id, 1)

    assert {:error, {:stale, 2}} =
             Stations.save_alignment(scope.audit, updated.id, alignment_attrs(), 1)

    assert length(updated_logs(scope.audit, :stop_level, updated.id)) == 1
    assert Repo.get!(StopLevel, updated.id).floorplan_center_lat == nil

    assert {:ok, cleared} = Stations.clear_scale(scope.audit, updated.id, 2)
    assert cleared.scale_meters_per_unit == nil
    assert cleared.lock_version == 3
    assert length(updated_logs(scope.audit, :stop_level, updated.id)) == 2
  end

  test "revoked actor cannot change calibration, alignment or derived coordinates", scope do
    membership =
      GtfsPlanner.Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)

    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Stations.save_scale(scope.audit, scope.stop_level.id, scale_attrs(), 1)

    assert {:error, :forbidden} = Stations.clear_scale(scope.audit, scope.stop_level.id, 1)

    assert {:error, :forbidden} =
             Stations.save_alignment(scope.audit, scope.stop_level.id, alignment_attrs(), 1)

    assert {:error, :forbidden} =
             Stations.apply_alignment_to_child_stops(scope.audit, scope.stop_level, {1000, 800})

    assert Repo.get!(StopLevel, scope.stop_level.id).lock_version == 1
    assert updated_logs(scope.audit, :stop_level, scope.stop_level.id) == []
  end

  test "failed history insert rolls back an alignment change", scope do
    invalid_audit = %{scope.audit | actor_email: nil}

    assert {:error, %Ecto.Changeset{}} =
             Stations.save_alignment(
               invalid_audit,
               scope.stop_level.id,
               alignment_attrs(),
               scope.stop_level.lock_version
             )

    assert Repo.get!(StopLevel, scope.stop_level.id).floorplan_center_lat == nil
    assert Repo.get!(StopLevel, scope.stop_level.id).lock_version == 1
    assert updated_logs(scope.audit, :stop_level, scope.stop_level.id) == []
  end

  test "alignment application writes one history row per moved child stop", scope do
    assert {:ok, aligned} =
             Stations.save_alignment(
               scope.audit,
               scope.stop_level.id,
               alignment_attrs(),
               scope.stop_level.lock_version
             )

    first =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: scope.level.level_id,
        diagram_coordinate: %{x: 50, y: 40},
        stop_lat: Decimal.new("1"),
        stop_lon: Decimal.new("2")
      )

    second =
      child_stop_fixture(scope.organization.id, scope.version.id, scope.station.stop_id,
        level_id: scope.level.level_id,
        diagram_coordinate: %{x: 60, y: 40},
        stop_lat: Decimal.new("1"),
        stop_lon: Decimal.new("2")
      )

    assert {:ok, 2} =
             Stations.apply_alignment_to_child_stops(scope.audit, aligned, {1000, 800})

    assert length(updated_logs(scope.audit, :stop, first.id)) == 1
    assert length(updated_logs(scope.audit, :stop, second.id)) == 1
    assert Repo.get!(Stop, first.id).lock_version == first.lock_version + 1
    assert Repo.get!(Stop, second.id).lock_version == second.lock_version + 1

    assert {:ok, 0} =
             Stations.apply_alignment_to_child_stops(scope.audit, aligned, {1000, 800})

    assert length(updated_logs(scope.audit, :stop, first.id)) == 1
    assert length(updated_logs(scope.audit, :stop, second.id)) == 1
  end

  test "reviewed alignment entrypoints refuse a revoked actor", scope do
    {:ok, preview} =
      Gtfs.preview_stop_level_coordinate_application(
        scope.stop_level.id,
        alignment_attrs(),
        1000,
        800
      )

    {:ok, review} =
      Gtfs.preview_stop_level_alignment(scope.stop_level.id, alignment_attrs(), 1000, 800)

    membership =
      GtfsPlanner.Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)

    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Gtfs.apply_stop_level_coordinate_preview(preview, scope.audit)

    assert {:error, :forbidden} =
             Gtfs.save_and_apply_stop_level_alignment(
               scope.stop_level.id,
               Map.put(alignment_attrs(), :fingerprint, review.fingerprint),
               1000,
               800,
               scope.audit
             )

    assert Repo.get!(StopLevel, scope.stop_level.id).floorplan_center_lat == nil
    assert updated_logs(scope.audit, :stop_level, scope.stop_level.id) == []
  end

  test "reviewed alignment refreshes only the observation pinned to its own floorplan", scope do
    pin = insert_pin!(scope.organization, scope.version, scope.station, scope.stop_level)

    # The same station and level IDs in another organization own a floorplan and
    # a pin of their own, which an alignment of this floorplan must not reach.
    other_organization = organization_fixture()
    other_version = gtfs_version_fixture(other_organization.id)

    other_station =
      stop_fixture(other_organization.id, other_version.id,
        stop_id: scope.station.stop_id,
        location_type: 1
      )

    other_level =
      level_fixture(other_organization.id, other_version.id, level_id: scope.level.level_id)

    {:ok, other_stop_level} =
      insert_stop_level(%{
        organization_id: other_organization.id,
        gtfs_version_id: other_version.id,
        stop_id: other_station.stop_id,
        level_id: other_level.level_id
      })

    other_pin = insert_pin!(other_organization, other_version, other_station, other_stop_level)

    {:ok, review} =
      Gtfs.preview_stop_level_alignment(scope.stop_level.id, alignment_attrs(), 1000, 800)

    assert {:ok, _result} =
             Stations.apply_reviewed_alignment(
               scope.audit,
               scope.stop_level.id,
               Map.put(alignment_attrs(), :fingerprint, review.fingerprint),
               1000,
               800
             )

    # A pin at the image centre sits on the floorplan's geographic centre.
    refreshed = Repo.get!(JournalEntry, pin.id)
    assert_in_delta refreshed.lat, 40.7128, 1.0e-9
    assert_in_delta refreshed.lon, -74.006, 1.0e-9
    assert %{lat: nil, lon: nil} = Repo.get!(JournalEntry, other_pin.id)
  end

  test "renaming the parent level cascades once to the floorplan and refuses a stale revision",
       scope do
    assert {:ok, renamed} =
             Stations.update_level(
               scope.audit,
               scope.level.id,
               %{"level_id" => "L1_RENAMED"},
               scope.level.lock_version
             )

    assert renamed.level_id == "L1_RENAMED"

    cascaded = Repo.get!(StopLevel, scope.stop_level.id)
    assert cascaded.level_id == "L1_RENAMED"
    assert cascaded.lock_version > scope.stop_level.lock_version

    assert {:error, {:stale, current}} =
             Stations.save_alignment(
               scope.audit,
               scope.stop_level.id,
               alignment_attrs(),
               scope.stop_level.lock_version
             )

    assert current == cascaded.lock_version
    assert Repo.get!(StopLevel, scope.stop_level.id).floorplan_center_lat == nil
  end

  @tag :unboxed
  test "version-exclusive holder blocks scale save", _scope do
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

    save =
      Task.Supervisor.async_nolink(supervisor, fn ->
        unboxed(fn ->
          backend = backend_pid()
          send(parent, {:save_ready, backend})

          Stations.save_scale(
            scope.audit,
            scope.stop_level.id,
            scale_attrs(),
            scope.stop_level.lock_version
          )
        end)
      end)

    assert_receive {:save_ready, save_backend}, @rendezvous_timeout
    assert :ok == unboxed(fn -> await_blocker(save_backend, holder_backend, deadline()) end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, @collect_timeout)
    assert {:ok, %{stop_level: updated}} = Task.await(save, @collect_timeout)
    assert updated.lock_version == scope.stop_level.lock_version + 1
  end

  defp scale_attrs do
    %{
      scale_point_a: %{"x" => 0.0, "y" => 0.0},
      scale_point_b: %{"x" => 10.0, "y" => 0.0},
      scale_distance_meters: Decimal.new("20"),
      scale_meters_per_unit: Decimal.new("2")
    }
  end

  defp alignment_attrs do
    %{
      floorplan_center_lat: 40.7128,
      floorplan_center_lon: -74.0060,
      floorplan_scale_mpp: 0.25,
      floorplan_rotation_deg: 0.0
    }
  end

  defp insert_pin!(organization, version, station, stop_level) do
    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_id: station.id,
      station_stop_id: station.stop_id,
      actor_id: editor_fixture(organization).id
    }

    JournalEntry.create_changeset(
      %JournalEntry{},
      %{
        id: Ecto.UUID.generate(),
        target_type: "pin",
        stop_level_id: stop_level.id,
        diagram_x: 50.0,
        diagram_y: 40.0,
        captured_at: ~U[2026-10-02 12:00:00.000000Z]
      },
      scope
    )
    |> Repo.insert!()
  end

  defp updated_logs(audit, type, id) do
    audit.organization_id
    |> Audit.list_change_logs_for_entity(audit.gtfs_version_id, Atom.to_string(type), id)
    |> Enum.filter(&(&1.action == "updated"))
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
    delete_versions!(from row in GtfsVersion, where: row.organization_id == ^org_id)
    Repo.delete_all(from row in Organization, where: row.id == ^org_id)
    Repo.delete_all(from row in User, where: row.id == ^scope.actor.id)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @rendezvous_timeout
end

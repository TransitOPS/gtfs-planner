defmodule GtfsPlanner.Gtfs.Calendars.AuditTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    %{
      organization: organization,
      version: version,
      actor: actor,
      membership: membership,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: "must-be-cleared",
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  test "calendar audits are accepted, complete and refused by station rollback", context do
    payload = create_weekly(context, "audited", "Audited Service")

    assert [created] = calendar_logs(context, "audited")
    assert created.action == "created"
    assert created.station_stop_id == nil
    assert created.changed_fields["before"] == nil

    after_snapshot = created.changed_fields["after"]
    assert after_snapshot["service_id"] == "audited"
    assert after_snapshot["name"] == "Audited Service"
    assert after_snapshot["kind"] == "weekly"
    assert after_snapshot["weekly"]["start_date"] == "2026-01-05"
    assert after_snapshot["dates"] == []

    assert created.snapshot["service_id"] == "audited"
    assert created.snapshot["service_description"] == "Audited Service"

    assert Gtfs.reversible_fields_for("calendar") == []
    assert Gtfs.reversible_fields_for(:calendar) == []
    assert Gtfs.rollback_previewable_fields(created) == []
    assert {:error, :audit_only_entity} = Gtfs.rollback_target_snapshot(created)
    assert {:error, :audit_only_entity} = Gtfs.rollback_entity(created, context.audit)

    assert ChangeLog.changeset(%ChangeLog{}, %{
             entity_type: "calendar",
             entity_id: payload.attributes.id,
             entity_external_id: "audited",
             actor_id: context.actor.id,
             actor_email: context.actor.email,
             action: "updated",
             organization_id: context.organization.id,
             gtfs_version_id: context.version.id
           }).valid?

    assert {:ok, review} =
             Gtfs.review_calendar_change(
               {:delete, "audited"},
               %{"audited" => payload.fingerprint},
               context.audit
             )

    assert {:ok, _} =
             Gtfs.apply_calendar_change({:delete, "audited"}, review.fingerprint, context.audit)

    assert [^created, deleted] = calendar_logs(context, "audited")
    assert deleted.action == "deleted"
    assert deleted.changed_fields["after"] == nil
    assert deleted.changed_fields["before"] == after_snapshot
    assert {:error, :audit_only_entity} = Gtfs.rollback_target_snapshot(deleted)
    assert {:error, :audit_only_entity} = Gtfs.rollback_entity(deleted, context.audit)
  end

  test "audit snapshots serialize dates as ISO strings and keys as strings", context do
    create_weekly(context, "serialized", "Serialized")

    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: "serialized",
      date: ~D[2026-01-07],
      exception_type: 2
    })

    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: "serialized",
      date: ~D[2026-01-10],
      exception_type: 1
    })

    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, "serialized")

    assert {:ok, review} =
             Gtfs.review_calendar_change(
               {:delete, "serialized"},
               %{"serialized" => payload.fingerprint},
               context.audit
             )

    assert {:ok, _} =
             Gtfs.apply_calendar_change(
               {:delete, "serialized"},
               review.fingerprint,
               context.audit
             )

    assert [created, deleted] = calendar_logs(context, "serialized")
    assert created.changed_fields["after"]["dates"] == []
    before = deleted.changed_fields["before"]
    assert Enum.all?(Map.keys(before), &is_binary/1)
    assert before["weekly"]["end_date"] == "2026-02-27"
    assert before["attributes"]["rating_start_date"] == nil

    assert before["dates"] == [
             %{"date" => "2026-01-07", "exception_type" => 2},
             %{"date" => "2026-01-10", "exception_type" => 1}
           ]
  end

  test "an imported native-only service gets its anchor in the deleting transaction", context do
    calendar_fixture(context.organization.id, context.version.id, %{service_id: "imported"})

    calendar_date_fixture(context.organization.id, context.version.id, %{
      service_id: "imported",
      date: ~D[2026-01-07],
      exception_type: 2
    })

    refute Repo.exists?(
             from(a in CalendarAttribute,
               where: a.gtfs_version_id == ^context.version.id and a.service_id == "imported"
             )
           )

    assert {:ok, payload} =
             Gtfs.get_calendar(context.organization.id, context.version.id, "imported")

    assert payload.attributes == nil

    assert {:ok, review} =
             Gtfs.review_calendar_change(
               {:delete, "imported"},
               %{"imported" => payload.fingerprint},
               context.audit
             )

    assert {:ok, _} =
             Gtfs.apply_calendar_change({:delete, "imported"}, review.fingerprint, context.audit)

    assert [log] = calendar_logs(context, "imported")
    assert log.action == "deleted"
    assert log.entity_external_id == "imported"
    assert is_binary(log.entity_id)
    assert log.changed_fields["before"]["attributes"] == nil
    assert log.changed_fields["before"]["kind"] == "weekly"
    assert log.changed_fields["before"]["weekly"]["monday"] == 1

    assert log.changed_fields["before"]["dates"] == [
             %{"date" => "2026-01-07", "exception_type" => 2}
           ]

    assert table_state(context, "imported") == %{calendar: [], exceptions: [], attributes: []}
  end

  test "a refused actor creates no anchor and no audit row", context do
    assert {:error, :forbidden} = create_result(context, "denied", Ecto.UUID.generate())

    refute Repo.exists?(
             from(a in CalendarAttribute, where: a.organization_id == ^context.organization.id)
           )

    refute Repo.exists?(
             from(l in ChangeLog, where: l.organization_id == ^context.organization.id)
           )

    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} = Gtfs.create_calendar(weekly_attrs("deactivated"), context.audit)

    refute Repo.exists?(
             from(a in CalendarAttribute, where: a.organization_id == ^context.organization.id)
           )

    refute Repo.exists?(
             from(l in ChangeLog, where: l.organization_id == ^context.organization.id)
           )
  end

  test "a later calendar audit failure rolls back every earlier exception upsert", context do
    first = create_single_date_calendar(context, "rollback_a")
    second = create_single_date_calendar(context, "rollback_b")

    authored = %{
      "rollback_a" => table_state(context, "rollback_a"),
      "rollback_b" => table_state(context, "rollback_b")
    }

    logs_before = calendar_logs(context, "rollback_a") ++ calendar_logs(context, "rollback_b")

    install_audit_rejection_trigger!("rollback_b")
    barrier_before = barrier_value!()

    command = {:date_change, [~D[2026-01-05]], ["rollback_a", "rollback_b"], []}

    fingerprints = %{
      "rollback_a" => first.fingerprint,
      "rollback_b" => second.fingerprint
    }

    assert {:ok, review} =
             Gtfs.review_calendar_change(command, fingerprints, context.audit)

    assert review.affected_service_ids == ["rollback_a", "rollback_b"]

    assert_raise Postgrex.Error, fn ->
      Gtfs.apply_calendar_change(command, review.fingerprint, context.audit)
    end

    # The barrier is a PostgreSQL sequence, so its advance survives the rolled-back
    # transaction and independently proves the trigger fired on the later calendar.
    assert barrier_value!() == barrier_before + 1

    assert table_state(context, "rollback_a") == authored["rollback_a"]
    assert table_state(context, "rollback_b") == authored["rollback_b"]

    assert calendar_logs(context, "rollback_a") ++ calendar_logs(context, "rollback_b") ==
             logs_before
  end

  # Test-only fault injection: a constraint trigger scoped to one fixture service ID
  # raises on a later affected calendar's audit insert. The trigger, function and
  # sequence are created inside the sandbox transaction, so the guaranteed sandbox
  # rollback removes them; no production failure switch exists.
  defp install_audit_rejection_trigger!(service_id) do
    Repo.query!("CREATE SEQUENCE calendar_audit_rejection_barrier")
    # Prime the sequence once so a single trigger execution is observable as an
    # exact increment of `last_value`.
    Repo.query!("SELECT nextval('calendar_audit_rejection_barrier')")

    Repo.query!("""
    CREATE FUNCTION calendar_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'calendar' AND NEW.entity_external_id = '#{service_id}' THEN
        PERFORM nextval('calendar_audit_rejection_barrier');
        RAISE EXCEPTION 'calendar audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER calendar_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION calendar_audit_rejection();
    """)
  end

  # A non-consuming read: the sequence only advances when the trigger itself fires.
  defp barrier_value! do
    %{rows: [[value]]} = Repo.query!("SELECT last_value FROM calendar_audit_rejection_barrier")
    value
  end

  defp create_single_date_calendar(context, service_id) do
    assert {:ok, payload} =
             Gtfs.create_calendar(
               %{
                 service_id: service_id,
                 name: "Single #{service_id}",
                 kind: :dates_only,
                 dates: [~D[2026-01-05]]
               },
               context.audit
             )

    payload
  end

  defp create_result(context, service_id, actor_id) do
    Gtfs.create_calendar(
      weekly_attrs(service_id),
      %{context.audit | actor_id: actor_id}
    )
  end

  defp create_weekly(context, service_id, name) do
    assert {:ok, payload} =
             Gtfs.create_calendar(weekly_attrs(service_id, name), context.audit)

    payload
  end

  defp weekly_attrs(service_id, name \\ "Weekly") do
    %{
      service_id: service_id,
      name: name,
      kind: :weekly,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-05],
      end_date: ~D[2026-02-27]
    }
  end

  defp calendar_logs(context, service_id) do
    Repo.all(
      from(l in ChangeLog,
        where:
          l.gtfs_version_id == ^context.version.id and l.entity_type == "calendar" and
            l.entity_external_id == ^service_id,
        order_by: [asc: l.inserted_at]
      )
    )
  end

  defp table_state(context, service_id) do
    organization_id = context.organization.id
    version_id = context.version.id

    %{
      calendar:
        Repo.all(
          from(c in Calendar,
            where:
              c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id and
                c.service_id == ^service_id
          )
        ),
      exceptions:
        Repo.all(
          from(d in CalendarDate,
            where:
              d.organization_id == ^organization_id and d.gtfs_version_id == ^version_id and
                d.service_id == ^service_id
          )
        ),
      attributes:
        Repo.all(
          from(a in CalendarAttribute,
            where:
              a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id and
                a.service_id == ^service_id
          )
        )
    }
  end
end

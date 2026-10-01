defmodule GtfsPlanner.Gtfs.PathwayEvolutions.MutationsTest do
  @moduledoc """
  Stale-safe closure updates and deletes through the ordinary `Gtfs` facade
  (`update_pathway_evolution/4`, `delete_pathway_evolution/3`): fingerprinted
  writes under the published-version lock, reference rechecks and no-op saves
  on update, closure-only deletion, one structured `pathway_evolution` audit per
  real change and atomic rollback on audit failure. Expectations are
  hand-authored from the acceptance cases (AC-2, AC-4 to AC-8).
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Pathway
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    level_fixture(organization.id, version.id, %{level_id: "L_STREET", level_index: 0.0})
    level_fixture(organization.id, version.id, %{level_id: "L_PLAT", level_index: -1.0})

    station =
      stop_fixture(organization.id, version.id, %{stop_id: "STN_1", location_type: 1})

    entrance =
      stop_fixture(organization.id, version.id, %{
        stop_id: "ENT_1",
        location_type: 2,
        parent_station: "STN_1",
        level_id: "L_STREET"
      })

    platform =
      stop_fixture(organization.id, version.id, %{
        stop_id: "PLAT_1",
        location_type: 0,
        parent_station: "STN_1",
        level_id: "L_PLAT"
      })

    outside = stop_fixture(organization.id, version.id, %{stop_id: "OUT_1", location_type: 0})

    outside_peer =
      stop_fixture(organization.id, version.id, %{stop_id: "OUT_2", location_type: 0})

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_ENTRY",
      pathway_mode: 2
    })

    pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
      pathway_id: "PW_SECOND",
      pathway_mode: 1
    })

    pathway_fixture(organization.id, version.id, outside.stop_id, outside_peer.stop_id, %{
      pathway_id: "PW_OUT",
      pathway_mode: 1
    })

    calendar_fixture(organization.id, version.id, %{service_id: "SVC_WEEK"})

    calendar_date_fixture(organization.id, version.id, %{
      service_id: "SVC_DATES",
      date: ~D[2026-07-04],
      exception_type: 1
    })

    # Native (a calendar_dates row exists) but every date is removed, so the
    # service has no active service dates.
    calendar_date_fixture(organization.id, version.id, %{
      service_id: "SVC_EMPTY",
      date: ~D[2026-07-04],
      exception_type: 2
    })

    # Metadata-only identity: a calendar_attributes row without native rows.
    calendar_attribute_fixture(organization.id, version.id, %{service_id: "SVC_META"})

    %{
      organization: organization,
      version: version,
      actor: actor,
      membership: membership,
      station: station,
      entrance: entrance,
      platform: platform,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: "STN_1",
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  describe "Gtfs.update_pathway_evolution/4" do
    test "two edits using one fingerprint commit the first and reject the second as stale_review",
         context do
      created = create_closure(context, %{note: "original"})
      id = created.evolution.id

      # Scope keys in the attribute map are never used: the audit context owns scope.
      forged_scope = %{
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      assert {:ok, first} =
               Gtfs.update_pathway_evolution(
                 id,
                 Map.merge(%{note: "first edit"}, forged_scope),
                 created.fingerprint,
                 context.audit
               )

      assert first.evolution.note == "first edit"
      assert first.evolution.organization_id == context.organization.id
      assert first.evolution.gtfs_version_id == context.version.id
      assert first.fingerprint != created.fingerprint

      reloaded = Repo.get_by!(PathwayEvolution, id: id)
      assert reloaded.note == "first edit"

      assert {:error, :stale_review} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: "second edit"},
                 created.fingerprint,
                 context.audit
               )

      assert Repo.get_by!(PathwayEvolution, id: id).note == "first edit"

      logs = change_logs(context)
      assert length(logs) == 2
      assert Enum.any?(logs, &(&1.action == "created"))
      update_log = Enum.find(logs, &(&1.action == "updated"))

      assert update_log.entity_type == "pathway_evolution"
      assert update_log.entity_id == id
      assert update_log.entity_external_id == "PW_ENTRY"
      assert update_log.actor_id == context.actor.id
      assert update_log.actor_email == context.actor.email
      assert update_log.organization_id == context.organization.id
      assert update_log.gtfs_version_id == context.version.id
      assert update_log.station_stop_id == "STN_1"

      assert update_log.changed_fields["before"]["note"] == "original"
      assert update_log.changed_fields["after"]["note"] == "first edit"
      assert update_log.changed_fields["before"]["start_time"] == 32_400
      assert update_log.changed_fields["after"]["start_time"] == 32_400
      assert update_log.snapshot["note"] == "first edit"
    end

    test "foreign, unknown and malformed closure ids return not_found and never write", context do
      created = create_closure(context)
      id = created.evolution.id

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign = pathway_evolution_fixture(foreign_organization.id, foreign_version.id, %{})

      for foreign_id <- [foreign.id, Ecto.UUID.generate(), "not-a-uuid", nil] do
        assert {:error, :not_found} =
                 Gtfs.update_pathway_evolution(
                   foreign_id,
                   %{note: "never written"},
                   created.fingerprint,
                   context.audit
                 )

        assert {:error, :not_found} =
                 Gtfs.delete_pathway_evolution(foreign_id, created.fingerprint, context.audit)
      end

      assert Repo.get_by!(PathwayEvolution, id: id).note == nil
      assert Repo.get_by!(PathwayEvolution, id: foreign.id)
      assert length(change_logs(context)) == 1
    end

    test "editing a referenced calendar or pathway row never stales the closure", context do
      created = create_closure(context)
      id = created.evolution.id

      # An edit beside the row: new dates for the referenced service.
      calendar_date_fixture(context.organization.id, context.version.id, %{
        service_id: "SVC_WEEK",
        date: ~D[2026-07-05],
        exception_type: 1
      })

      # An edit beside the row: the referenced pathway's own fields.
      Repo.update_all(
        from(p in Pathway,
          where:
            p.organization_id == ^context.organization.id and
              p.gtfs_version_id == ^context.version.id and p.pathway_id == "PW_ENTRY"
        ),
        set: [traversal_time: 999]
      )

      reloaded = Repo.get_by!(PathwayEvolution, id: id)
      assert PathwayEvolutions.fingerprint(reloaded) == created.fingerprint

      # The original fingerprint still commits a one-attribute edit.
      assert {:ok, updated} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: "beside edits"},
                 created.fingerprint,
                 context.audit
               )

      assert updated.evolution.note == "beside edits"
      assert updated.evolution.start_time == 32_400
    end

    test "an unchanged valid save writes neither row nor audit", context do
      created = create_closure(context, %{note: "keep"})
      id = created.evolution.id
      loaded_before = Repo.get_by!(PathwayEvolution, id: id)

      assert {:ok, unchanged} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{
                   pathway_id: "PW_ENTRY",
                   service_id: "SVC_WEEK",
                   start_time: "09:00",
                   end_time: "15:00",
                   note: "keep"
                 },
                 created.fingerprint,
                 context.audit
               )

      assert unchanged.fingerprint == created.fingerprint
      assert unchanged.evolution.id == id
      assert unchanged.notices == []

      reloaded = Repo.get_by!(PathwayEvolution, id: id)
      assert reloaded.updated_at == loaded_before.updated_at
      assert reloaded.inserted_at == loaded_before.inserted_at
      assert reloaded.note == "keep"
      assert length(change_logs(context)) == 1

      # The fingerprint is not consumed: a later one-attribute edit still commits.
      assert {:ok, edited} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{start_time: "10:00"},
                 created.fingerprint,
                 context.audit
               )

      assert edited.evolution.start_time == 36_000
      assert edited.evolution.end_time == 54_000
      assert length(change_logs(context)) == 2
    end

    test "each single-attribute change persists exactly that change with one audit", context do
      created = create_closure(context)
      id = created.evolution.id

      # One attribute at a time, so the digest input and the audit diff are
      # both proven per field rather than across simultaneous changes.
      assert {:ok, r1} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: "n1"},
                 created.fingerprint,
                 context.audit
               )

      assert r1.fingerprint != created.fingerprint
      assert r1.evolution.note == "n1"

      assert {r1.evolution.pathway_id, r1.evolution.service_id, r1.evolution.start_time,
              r1.evolution.end_time} == {"PW_ENTRY", "SVC_WEEK", 32_400, 54_000}

      assert {:ok, r2} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{start_time: "10:00"},
                 r1.fingerprint,
                 context.audit
               )

      assert r2.fingerprint != r1.fingerprint

      assert {r2.evolution.start_time, r2.evolution.end_time, r2.evolution.note} ==
               {36_000, 54_000, "n1"}

      assert {:ok, r3} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{end_time: "16:00"},
                 r2.fingerprint,
                 context.audit
               )

      assert r3.fingerprint != r2.fingerprint
      assert {r3.evolution.start_time, r3.evolution.end_time} == {36_000, 57_600}

      assert {:ok, r4} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{service_id: "SVC_DATES"},
                 r3.fingerprint,
                 context.audit
               )

      assert r4.fingerprint != r3.fingerprint
      assert r4.evolution.service_id == "SVC_DATES"
      assert r4.evolution.note == "n1"

      assert {:ok, r5} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{pathway_id: "PW_SECOND"},
                 r4.fingerprint,
                 context.audit
               )

      assert r5.fingerprint != r4.fingerprint
      assert r5.evolution.pathway_id == "PW_SECOND"

      assert {r5.evolution.service_id, r5.evolution.start_time, r5.evolution.end_time,
              r5.evolution.note} == {"SVC_DATES", 36_000, 57_600, "n1"}

      update_logs = Enum.filter(change_logs(context), &(&1.action == "updated"))
      assert length(update_logs) == 5

      # Each audit snapshot pair differs in exactly one payload field.
      for log <- update_logs do
        differing =
          for key <- Map.keys(log.changed_fields["before"]),
              log.changed_fields["before"][key] != log.changed_fields["after"][key],
              do: key

        assert length(differing) == 1
      end

      reloaded = Repo.get_by!(PathwayEvolution, id: id)
      assert reloaded.note == "n1"
    end

    test "the fingerprint changes for each persisted column changed alone", context do
      created = create_closure(context, %{note: "original"})
      row = Repo.get_by!(PathwayEvolution, id: created.evolution.id)
      base = PathwayEvolutions.fingerprint(row)

      assert base == created.fingerprint

      single_column_changes = [
        {:id, Ecto.UUID.generate()},
        {:organization_id, Ecto.UUID.generate()},
        {:gtfs_version_id, Ecto.UUID.generate()},
        {:pathway_id, "PW_OTHER"},
        {:service_id, "SVC_OTHER"},
        {:start_time, 32_401},
        {:end_time, 54_001},
        {:note, "other"},
        {:inserted_at, DateTime.add(row.inserted_at, 1, :second)},
        {:updated_at, DateTime.add(row.updated_at, 1, :second)}
      ]

      for {field, value} <- single_column_changes do
        assert PathwayEvolutions.fingerprint(Map.put(row, field, value)) != base,
               "fingerprint must cover #{field}"
      end

      # The untouched persisted row keeps its digest across reloads.
      assert PathwayEvolutions.fingerprint(Repo.get_by!(PathwayEvolution, id: row.id)) == base
    end

    test "update rechecks references, window rules and the duplicate tuple", context do
      created = create_closure(context)
      id = created.evolution.id

      second =
        create_closure(context, %{pathway_id: "PW_SECOND", start_time: "18:00", end_time: "19:00"})

      assert {:error, meta} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{service_id: "SVC_META"},
                 created.fingerprint,
                 context.audit
               )

      assert Map.has_key?(errors_on(meta), :service_id)

      assert {:error, ghost_service} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{service_id: "SVC_GHOST"},
                 created.fingerprint,
                 context.audit
               )

      assert Map.has_key?(errors_on(ghost_service), :service_id)

      assert {:error, ghost_pathway} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{pathway_id: "PW_GHOST"},
                 created.fingerprint,
                 context.audit
               )

      assert Map.has_key?(errors_on(ghost_pathway), :pathway_id)

      assert {:error, outside} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{pathway_id: "PW_OUT"},
                 created.fingerprint,
                 context.audit
               )

      assert Map.has_key?(errors_on(outside), :pathway_id)

      assert {:error, wrapped} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{start_time: "23:00", end_time: "02:00"},
                 created.fingerprint,
                 context.audit
               )

      assert Map.has_key?(errors_on(wrapped), :end_time)

      # The 500-character note ceiling holds on this path because the update
      # goes through changeset/2, never a raw struct update.
      assert {:error, long_note} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: String.duplicate("a", 501)},
                 created.fingerprint,
                 context.audit
               )

      assert Map.has_key?(errors_on(long_note), :note)

      # Moving onto a sibling's exact tuple is refused as a duplicate.
      assert {:error, duplicate} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{pathway_id: "PW_SECOND", start_time: "18:00", end_time: "19:00"},
                 created.fingerprint,
                 context.audit
               )

      assert errors_on(duplicate).base == ["This closure already exists."]

      reloaded = Repo.get_by!(PathwayEvolution, id: id)

      assert {reloaded.pathway_id, reloaded.service_id, reloaded.start_time, reloaded.end_time,
              reloaded.note} == {"PW_ENTRY", "SVC_WEEK", 32_400, 54_000, nil}

      assert Repo.get_by!(PathwayEvolution, id: second.evolution.id)
      # The two creates are the only logs: every refusal wrote nothing.
      assert length(change_logs(context)) == 2
    end

    test "a saved edit reports same-service overlaps and no-active-dates", context do
      created = create_closure(context, %{start_time: "09:00", end_time: "15:00"})
      other = create_closure(context, %{start_time: "18:00", end_time: "19:00"})

      assert {:ok, overlapping} =
               Gtfs.update_pathway_evolution(
                 created.evolution.id,
                 %{end_time: "18:30"},
                 created.fingerprint,
                 context.audit
               )

      assert [{:overlaps, [named]}] = overlapping.notices
      assert named.id == other.evolution.id
      assert {named.start_time, named.end_time} == {64_800, 68_400}

      assert {:ok, empty} =
               Gtfs.update_pathway_evolution(
                 created.evolution.id,
                 %{service_id: "SVC_EMPTY"},
                 overlapping.fingerprint,
                 context.audit
               )

      assert empty.notices == [:no_active_dates]
      assert Repo.get_by!(PathwayEvolution, id: created.evolution.id).service_id == "SVC_EMPTY"
    end

    test "foreign, roleless and deactivated actors and unpublished scopes never write", context do
      created = create_closure(context)
      id = created.evolution.id

      foreign_organization = organization_fixture()
      foreign_actor = user_fixture()
      organization_membership_fixture(foreign_actor, foreign_organization)

      foreign_audit = %{
        context.audit
        | actor_id: foreign_actor.id,
          actor_email: foreign_actor.email
      }

      roleless = user_fixture()
      organization_membership_fixture(roleless, context.organization, [])

      roleless_audit = %{
        context.audit
        | actor_id: roleless.id,
          actor_email: roleless.email
      }

      for refused_audit <- [foreign_audit, roleless_audit] do
        assert {:error, :forbidden} =
                 Gtfs.update_pathway_evolution(
                   id,
                   %{note: "never written"},
                   created.fingerprint,
                   refused_audit
                 )

        assert {:error, :forbidden} =
                 Gtfs.delete_pathway_evolution(id, created.fingerprint, refused_audit)
      end

      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      assert {:error, :not_found} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: "never written"},
                 created.fingerprint,
                 %{context.audit | gtfs_version_id: staging.id}
               )

      assert {:error, :not_found} =
               Gtfs.delete_pathway_evolution(
                 id,
                 created.fingerprint,
                 %{context.audit | gtfs_version_id: staging.id}
               )

      deactivate_membership_fixture(context.membership)

      assert {:error, :forbidden} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: "never written"},
                 created.fingerprint,
                 context.audit
               )

      assert {:error, :forbidden} =
               Gtfs.delete_pathway_evolution(id, created.fingerprint, context.audit)

      assert Repo.get_by!(PathwayEvolution, id: id).note == nil
      assert length(change_logs(context)) == 1
    end
  end

  describe "Gtfs.delete_pathway_evolution/3" do
    test "delete removes only the closure and records the before snapshot", context do
      created = create_closure(context, %{note: "to remove"})

      keep =
        create_closure(context, %{
          service_id: "SVC_DATES",
          start_time: "18:00",
          end_time: "19:00"
        })

      id = created.evolution.id

      assert {:ok, %{deleted: deleted}} =
               Gtfs.delete_pathway_evolution(id, created.fingerprint, context.audit)

      assert deleted.id == id
      assert deleted.note == "to remove"

      refute Repo.get_by(PathwayEvolution, id: id)
      assert Repo.get_by(PathwayEvolution, id: keep.evolution.id)

      # The closure's calendar and pathway rows are left intact.
      assert Repo.exists?(from(p in Pathway, where: p.pathway_id == "PW_ENTRY"))
      assert Repo.exists?(from(p in Pathway, where: p.pathway_id == "PW_SECOND"))
      assert Repo.exists?(from(c in Calendar, where: c.service_id == "SVC_WEEK"))
      assert Repo.exists?(from(d in CalendarDate, where: d.service_id == "SVC_DATES"))

      logs = change_logs(context)
      assert length(logs) == 3
      delete_log = Enum.find(logs, &(&1.action == "deleted"))

      assert delete_log.entity_type == "pathway_evolution"
      assert delete_log.entity_id == id
      assert delete_log.entity_external_id == "PW_ENTRY"
      assert delete_log.actor_id == context.actor.id
      assert delete_log.organization_id == context.organization.id
      assert delete_log.gtfs_version_id == context.version.id
      assert delete_log.station_stop_id == "STN_1"
      assert delete_log.changed_fields["after"] == nil

      before = delete_log.changed_fields["before"]
      assert before["pathway_id"] == "PW_ENTRY"
      assert before["service_id"] == "SVC_WEEK"
      assert before["start_time"] == 32_400
      assert before["end_time"] == 54_000
      assert before["note"] == "to remove"
    end

    test "delete is independent of calendar activity and stale deletion preserves the row",
         context do
      created = create_closure(context, %{service_id: "SVC_EMPTY", note: "kept"})
      id = created.evolution.id

      # An edit after the load makes the delete stale.
      assert {:ok, updated} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: "moved on"},
                 created.fingerprint,
                 context.audit
               )

      assert {:error, :stale_review} =
               Gtfs.delete_pathway_evolution(id, created.fingerprint, context.audit)

      assert Repo.get_by!(PathwayEvolution, id: id).note == "moved on"

      # A current-fingerprint delete succeeds even though the service has no
      # active dates: deletion is independent of calendar activity.
      assert {:ok, %{deleted: deleted}} =
               Gtfs.delete_pathway_evolution(id, updated.fingerprint, context.audit)

      assert deleted.note == "moved on"
      refute Repo.get_by(PathwayEvolution, id: id)
      assert length(change_logs(context)) == 3
    end

    test "an audit-rejecting trigger rolls back the update and the delete", context do
      created = create_closure(context, %{note: "before"})
      id = created.evolution.id

      install_audit_rejection_trigger!()

      assert_raise Postgrex.Error, ~r/pathway audit rejection fixture/, fn ->
        Gtfs.update_pathway_evolution(id, %{note: "after"}, created.fingerprint, context.audit)
      end

      reloaded = Repo.get_by!(PathwayEvolution, id: id)
      assert reloaded.note == "before"

      assert_raise Postgrex.Error, ~r/pathway audit rejection fixture/, fn ->
        Gtfs.delete_pathway_evolution(id, created.fingerprint, context.audit)
      end

      assert Repo.get_by!(PathwayEvolution, id: id).note == "before"
      assert length(change_logs(context)) == 1
    end

    test "rollback_entity stays audit_only_entity across create, update and delete logs",
         context do
      created = create_closure(context)
      id = created.evolution.id

      assert {:ok, updated} =
               Gtfs.update_pathway_evolution(
                 id,
                 %{note: "edited"},
                 created.fingerprint,
                 context.audit
               )

      assert {:ok, _deleted} =
               Gtfs.delete_pathway_evolution(id, updated.fingerprint, context.audit)

      logs = change_logs(context)
      assert Enum.sort(Enum.map(logs, & &1.action)) == ["created", "deleted", "updated"]

      for log <- logs do
        assert GtfsPlanner.Gtfs.Audit.reversible_fields_for(log.entity_type) == []

        assert {:error, :audit_only_entity} =
                 GtfsPlanner.Gtfs.Stations.rollback_target_snapshot(log)
      end
    end
  end

  defp create_closure(context, overrides \\ %{}) do
    {:ok, created} = Gtfs.create_pathway_evolution(closure_attrs(overrides), context.audit)
    created
  end

  defp closure_attrs(overrides) do
    Enum.into(overrides, %{
      pathway_id: "PW_ENTRY",
      service_id: "SVC_WEEK",
      start_time: "09:00",
      end_time: "15:00"
    })
  end

  defp change_logs(context) do
    Repo.all(
      from(l in ChangeLog,
        where: l.organization_id == ^context.organization.id,
        order_by: [asc: l.inserted_at, asc: l.id]
      )
    )
  end

  # Test-only fault injection: a constraint trigger raises on this step's audit
  # insert. The trigger and function are created inside the sandbox transaction,
  # so the guaranteed sandbox rollback removes them; no production failure switch
  # exists.
  defp install_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION pathway_evolution_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'pathway_evolution' THEN
        RAISE EXCEPTION 'pathway audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER pathway_evolution_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION pathway_evolution_audit_rejection();
    """)
  end
end

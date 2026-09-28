defmodule GtfsPlanner.Gtfs.PathwayEvolutions.CreateTest do
  @moduledoc """
  Audited closure creation through the ordinary `Gtfs` facade
  (`create_pathway_evolution/2`): validated references under the
  published-version write lock, one structured `pathway_evolution` audit per
  closure, atomic rollback on audit failure and same-service overlap /
  no-active-dates notices. Expectations are hand-authored from the acceptance
  cases (AC-2 to AC-5, AC-7, AC-8).
  """
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
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

    outside_pathway =
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
      outside_pathway: outside_pathway,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_stop_id: "STN_1",
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  describe "Gtfs.create_pathway_evolution/2" do
    test "creates one row and one audit with actor, scope, station and after snapshot", context do
      # Scope keys in the attribute map are never used: the audit context owns scope.
      forged_scope = %{
        organization_id: Ecto.UUID.generate(),
        gtfs_version_id: Ecto.UUID.generate()
      }

      assert {:ok, result} =
               Gtfs.create_pathway_evolution(
                 Map.merge(
                   %{
                     pathway_id: "PW_ENTRY",
                     service_id: "SVC_WEEK",
                     start_time: "09:00",
                     end_time: "15:00",
                     note: "Elevator maintenance"
                   },
                   forged_scope
                 ),
                 context.audit
               )

      evolution = result.evolution
      assert evolution.pathway_id == "PW_ENTRY"
      assert evolution.service_id == "SVC_WEEK"
      assert evolution.start_time == 32_400
      assert evolution.end_time == 54_000
      assert evolution.note == "Elevator maintenance"
      assert evolution.organization_id == context.organization.id
      assert evolution.gtfs_version_id == context.version.id

      reloaded = Repo.get_by!(PathwayEvolution, id: evolution.id)
      assert reloaded.pathway_id == evolution.pathway_id
      assert reloaded.service_id == evolution.service_id
      assert reloaded.start_time == evolution.start_time
      assert reloaded.end_time == evolution.end_time
      assert reloaded.note == evolution.note
      assert reloaded.organization_id == evolution.organization_id
      assert reloaded.gtfs_version_id == evolution.gtfs_version_id

      assert result.fingerprint == PathwayEvolutions.fingerprint(reloaded)
      assert result.notices == []

      assert [log] = change_logs(context)
      assert log.entity_type == "pathway_evolution"
      assert log.action == "created"
      assert log.entity_id == evolution.id
      assert log.entity_external_id == "PW_ENTRY"
      assert log.actor_id == context.actor.id
      assert log.actor_email == context.actor.email
      assert log.organization_id == context.organization.id
      assert log.gtfs_version_id == context.version.id
      assert log.station_stop_id == "STN_1"
      assert log.changed_fields["before"] == nil

      after_snapshot = log.changed_fields["after"]
      assert after_snapshot["pathway_id"] == "PW_ENTRY"
      assert after_snapshot["service_id"] == "SVC_WEEK"
      assert after_snapshot["start_time"] == 32_400
      assert after_snapshot["end_time"] == 54_000
      assert after_snapshot["note"] == "Elevator maintenance"

      assert Gtfs.reversible_fields_for("pathway_evolution") == []
      assert Gtfs.rollback_previewable_fields(log) == []
      assert {:error, :audit_only_entity} = Gtfs.rollback_target_snapshot(log)
      assert {:error, :audit_only_entity} = Gtfs.rollback_entity(log, context.audit)
    end

    test "every pathway mode is eligible", context do
      for {mode, pathway_id} <- [
            {1, "PW_WALK"},
            {2, "PW_STAIRS"},
            {3, "PW_TRAVELATOR"},
            {4, "PW_LIFT"},
            {5, "PW_GATE"},
            {6, "PW_EXIT"},
            {7, "PW_UNKNOWN_MODE"}
          ] do
        pathway_fixture(
          context.organization.id,
          context.version.id,
          context.entrance.stop_id,
          context.platform.stop_id,
          %{pathway_id: pathway_id, pathway_mode: mode}
        )

        assert {:ok, created} =
                 Gtfs.create_pathway_evolution(
                   %{
                     pathway_id: pathway_id,
                     service_id: "SVC_WEEK",
                     start_time: "09:00",
                     end_time: "10:00"
                   },
                   context.audit
                 )

        assert created.evolution.pathway_id == pathway_id
      end

      assert Repo.aggregate(PathwayEvolution, :count) == 7
    end

    test "foreign, deactivated and roleless actors are forbidden and write nothing", context do
      foreign_organization = organization_fixture()
      foreign_actor = user_fixture()
      organization_membership_fixture(foreign_actor, foreign_organization)

      foreign_audit = %{
        context.audit
        | actor_id: foreign_actor.id,
          actor_email: foreign_actor.email
      }

      assert {:error, :forbidden} =
               Gtfs.create_pathway_evolution(closure_attrs(%{}), foreign_audit)

      roleless = user_fixture()
      organization_membership_fixture(roleless, context.organization, [])

      roleless_audit = %{
        context.audit
        | actor_id: roleless.id,
          actor_email: roleless.email
      }

      assert {:error, :forbidden} =
               Gtfs.create_pathway_evolution(closure_attrs(%{}), roleless_audit)

      deactivate_membership_fixture(context.membership)

      assert {:error, :forbidden} =
               Gtfs.create_pathway_evolution(closure_attrs(%{}), context.audit)

      assert Repo.aggregate(PathwayEvolution, :count) == 0
      assert change_logs(context) == []
    end

    test "an unpublished version or foreign station returns not_found without writing", context do
      {:ok, staging} =
        Versions.create_staging_gtfs_version(context.organization.id, %{name: "Staging"})

      assert {:error, :not_found} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{}),
                 %{context.audit | gtfs_version_id: staging.id}
               )

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)

      stop_fixture(foreign_organization.id, foreign_version.id, %{
        stop_id: "STN_F",
        location_type: 1
      })

      assert {:error, :not_found} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{}),
                 %{context.audit | station_stop_id: "STN_F"}
               )

      assert {:error, :not_found} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{}),
                 %{context.audit | station_stop_id: "OUT_1"}
               )

      assert {:error, :not_found} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{}),
                 %{context.audit | station_stop_id: "GHOST"}
               )

      assert Repo.aggregate(PathwayEvolution, :count) == 0
      assert change_logs(context) == []
    end

    test "metadata-only calendars and unknown references produce field errors", context do
      assert {:error, meta} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{service_id: "SVC_META"}),
                 context.audit
               )

      assert Map.has_key?(errors_on(meta), :service_id)

      assert {:error, ghost_service} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{service_id: "SVC_GHOST"}),
                 context.audit
               )

      assert Map.has_key?(errors_on(ghost_service), :service_id)

      assert {:error, ghost_pathway} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{pathway_id: "PW_GHOST"}),
                 context.audit
               )

      assert Map.has_key?(errors_on(ghost_pathway), :pathway_id)

      assert {:error, outside_station} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{pathway_id: "PW_OUT"}),
                 context.audit
               )

      assert Map.has_key?(errors_on(outside_station), :pathway_id)

      assert {:error, wrapped_window} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{start_time: "23:00", end_time: "02:00"}),
                 context.audit
               )

      assert Map.has_key?(errors_on(wrapped_window), :end_time)

      assert {:error, blank_window} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{start_time: "", end_time: ""}),
                 context.audit
               )

      assert Map.has_key?(errors_on(blank_window), :start_time)
      assert Map.has_key?(errors_on(blank_window), :end_time)

      # The 500-character note ceiling holds on this path because the create
      # goes through changeset/2, never a raw struct insert.
      assert {:error, long_note} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{note: String.duplicate("a", 501)}),
                 context.audit
               )

      assert Map.has_key?(errors_on(long_note), :note)

      assert Repo.aggregate(PathwayEvolution, :count) == 0
      assert change_logs(context) == []
    end

    test "an exact duplicate tuple is refused with the closure-already-exists message",
         context do
      attrs = closure_attrs(%{})

      assert {:ok, first} = Gtfs.create_pathway_evolution(attrs, context.audit)
      assert {:error, duplicate} = Gtfs.create_pathway_evolution(attrs, context.audit)

      assert errors_on(duplicate).base == ["This closure already exists."]

      assert [survivor] = Repo.all(PathwayEvolution)
      assert survivor.id == first.evolution.id
      assert [_log] = change_logs(context)
    end

    test "an audit-rejecting trigger leaves no closure row and no log", context do
      install_audit_rejection_trigger!()

      assert_raise Postgrex.Error, ~r/pathway audit rejection fixture/, fn ->
        Gtfs.create_pathway_evolution(closure_attrs(%{}), context.audit)
      end

      assert Repo.aggregate(PathwayEvolution, :count) == 0
      assert change_logs(context) == []
    end

    test "same-service overlap warns naming the other window; other pathways and services do not",
         context do
      assert {:ok, first} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{start_time: "09:00", end_time: "15:00"}),
                 context.audit
               )

      assert first.notices == []

      assert {:ok, overlapping} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{start_time: "14:00", end_time: "18:00"}),
                 context.audit
               )

      assert [{:overlaps, [other]}] = overlapping.notices
      assert other.id == first.evolution.id
      assert {other.start_time, other.end_time} == {32_400, 54_000}

      assert {:ok, adjacent} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{start_time: "18:00", end_time: "19:00"}),
                 context.audit
               )

      assert adjacent.notices == []

      assert {:ok, other_service} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{
                   service_id: "SVC_DATES",
                   start_time: "09:00",
                   end_time: "15:00"
                 }),
                 context.audit
               )

      assert other_service.notices == []

      pathway_fixture(
        context.organization.id,
        context.version.id,
        context.entrance.stop_id,
        context.platform.stop_id,
        %{pathway_id: "PW_SECOND", pathway_mode: 1}
      )

      assert {:ok, other_pathway} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{
                   pathway_id: "PW_SECOND",
                   start_time: "09:00",
                   end_time: "15:00"
                 }),
                 context.audit
               )

      assert other_pathway.notices == []
    end

    test "a calendar with no active dates saves with a no-active-dates notice", context do
      assert {:ok, result} =
               Gtfs.create_pathway_evolution(
                 closure_attrs(%{service_id: "SVC_EMPTY"}),
                 context.audit
               )

      assert result.notices == [:no_active_dates]
      assert Repo.exists?(from(e in PathwayEvolution, where: e.service_id == "SVC_EMPTY"))
    end
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

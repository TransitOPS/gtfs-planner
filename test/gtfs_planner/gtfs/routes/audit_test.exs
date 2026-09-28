defmodule GtfsPlanner.Gtfs.Routes.AuditTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    route =
      route_fixture(organization.id, version.id, %{
        route_id: "R-AUDIT",
        route_short_name: "32",
        route_long_name: "Crosstown",
        route_color: "0000FF",
        route_text_color: "FFFFFF"
      })

    actor = user_fixture()

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: "must-be-cleared",
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      route: route,
      audit: %{audit | station_stop_id: nil},
      actor: actor
    }
  end

  describe "route audit metadata" do
    test "a created route log retains before/after, actor and creation metadata", context do
      creation_attempt_id = Ecto.UUID.generate()
      request_digest = "sha256:5d41402abc4b2a76b9719d911017c592"

      {:ok, route} =
        Repo.insert(
          Route.editor_changeset(
            %Route{
              organization_id: context.organization.id,
              gtfs_version_id: context.version.id
            },
            %{route_id: "R-NEW", route_type: 3, route_short_name: "12", route_long_name: "New"},
            :create
          )
        )

      after_snapshot = %{
        "route_id" => route.route_id,
        "route_short_name" => "12",
        "route_long_name" => "New",
        "route_type" => 3,
        "active" => true
      }

      assert {:ok, log} =
               Repo.transaction(fn ->
                 case Gtfs.record_change_in_transaction(
                        context.audit,
                        :route,
                        route,
                        "created",
                        %{
                          before: nil,
                          after: after_snapshot,
                          creation_attempt_id: creation_attempt_id,
                          request_digest: request_digest
                        }
                      ) do
                   {:ok, log} -> log
                   {:error, changeset} -> Repo.rollback(changeset)
                 end
               end)

      stored = Gtfs.get_change_log(log.id)

      assert stored.entity_type == "route"
      assert stored.entity_id == route.id
      assert stored.entity_external_id == "R-NEW"
      assert stored.action == "created"
      assert stored.actor_id == context.audit.actor_id
      assert stored.actor_email == context.audit.actor_email

      assert stored.snapshot["route_short_name"] == "12"
      assert stored.snapshot["active"] == true
      refute Map.has_key?(stored.snapshot, "route_id")

      assert stored.changed_fields["before"] == nil
      assert stored.changed_fields["after"] == after_snapshot
      assert stored.changed_fields["creation_attempt_id"] == creation_attempt_id
      assert stored.changed_fields["request_digest"] == request_digest

      assert Repo.exists?(from r in Route, where: r.id == ^route.id)
    end

    test "an updated route log retains structured before/after and actor", context do
      before_snapshot = %{
        "route_id" => "R-AUDIT",
        "route_long_name" => "Crosstown",
        "route_color" => "0000FF",
        "active" => true
      }

      after_snapshot = %{
        "route_id" => "R-AUDIT",
        "route_long_name" => "Uptown",
        "route_color" => "0000FF",
        "active" => true
      }

      assert {:ok, log} =
               Gtfs.record_change_in_transaction(
                 context.audit,
                 :route,
                 context.route,
                 "updated",
                 %{
                   before: before_snapshot,
                   after: after_snapshot
                 }
               )

      stored = Gtfs.get_change_log(log.id)

      assert stored.entity_type == "route"
      assert stored.entity_id == context.route.id
      assert stored.entity_external_id == "R-AUDIT"
      assert stored.action == "updated"
      assert stored.actor_id == context.audit.actor_id
      assert stored.actor_email == context.audit.actor_email

      assert stored.snapshot["route_long_name"] == "Crosstown"
      assert stored.changed_fields["before"] == before_snapshot
      assert stored.changed_fields["after"] == after_snapshot
    end

    test "a deleted route log retains before/after, actor and operation metadata", context do
      operation_id = Ecto.UUID.generate()

      before_snapshot = %{
        "route_id" => "R-AUDIT",
        "route_long_name" => "Crosstown",
        "active" => true
      }

      affected_identities = %{"trips" => ["trip-1", "trip-2"], "route_patterns" => ["pattern-1"]}
      affected_counts = %{"trips" => 2, "route_patterns" => 1}

      assert {:ok, log} =
               Gtfs.record_change_in_transaction(
                 context.audit,
                 :route,
                 context.route,
                 "deleted",
                 %{
                   before: before_snapshot,
                   after: nil,
                   operation_id: operation_id,
                   affected_identities: affected_identities,
                   affected_counts: affected_counts
                 }
               )

      stored = Gtfs.get_change_log(log.id)

      assert stored.entity_type == "route"
      assert stored.entity_id == context.route.id
      assert stored.entity_external_id == "R-AUDIT"
      assert stored.action == "deleted"
      assert stored.actor_id == context.audit.actor_id
      assert stored.actor_email == context.audit.actor_email

      assert stored.changed_fields["before"] == before_snapshot
      assert stored.changed_fields["after"] == nil
      assert stored.changed_fields["operation_id"] == operation_id
      assert stored.changed_fields["affected_identities"] == affected_identities
      assert stored.changed_fields["affected_counts"] == affected_counts
    end

    test "route entity type is accepted by the change log schema", context do
      assert ChangeLog.changeset(%ChangeLog{}, %{
               entity_type: "route",
               entity_id: context.route.id,
               entity_external_id: "R-AUDIT",
               actor_id: context.audit.actor_id,
               actor_email: context.audit.actor_email,
               action: "updated",
               organization_id: context.organization.id,
               gtfs_version_id: context.version.id
             }).valid?
    end
  end

  describe "generic rollback refusal" do
    test "rollback refuses route logs and exposes no reversible fields", context do
      before_snapshot = %{"route_id" => "R-AUDIT", "route_long_name" => "Crosstown"}
      after_snapshot = %{"route_id" => "R-AUDIT", "route_long_name" => "Uptown"}

      assert {:ok, updated_log} =
               Gtfs.record_change_in_transaction(
                 context.audit,
                 :route,
                 context.route,
                 "updated",
                 %{
                   before: before_snapshot,
                   after: after_snapshot
                 }
               )

      assert {:ok, created_log} =
               Gtfs.record_change_in_transaction(
                 context.audit,
                 :route,
                 context.route,
                 "created",
                 %{
                   before: nil,
                   after: after_snapshot
                 }
               )

      assert Gtfs.rollback_entity(updated_log, context.audit) == {:error, :audit_only_entity}
      assert Gtfs.rollback_target_snapshot(updated_log) == {:error, :audit_only_entity}
      assert Gtfs.rollback_entity(created_log, context.audit) == {:error, :audit_only_entity}
      assert Gtfs.rollback_target_snapshot(created_log) == {:error, :audit_only_entity}

      assert Gtfs.rollback_previewable_fields(updated_log) == []
      refute Enum.any?(Gtfs.reversible_fields_for("route"))
      refute Enum.any?(Gtfs.reversible_fields_for(:route))

      assert Repo.reload(context.route).route_long_name == "Crosstown"
    end
  end

  describe "audit failure atomicity" do
    test "an injected route-audit insert failure rolls back its caller transaction", context do
      install_route_audit_rejection_trigger!()

      assert_raise Postgrex.Error, fn ->
        Repo.transaction(fn ->
          {:ok, route} =
            Repo.insert(
              Route.editor_changeset(
                %Route{
                  organization_id: context.organization.id,
                  gtfs_version_id: context.version.id
                },
                %{route_id: "R-FAIL", route_type: 3, route_short_name: "99"},
                :create
              )
            )

          case Gtfs.record_change_in_transaction(context.audit, :route, route, "created", %{
                 before: nil,
                 after: %{"route_id" => "R-FAIL", "route_short_name" => "99"}
               }) do
            {:ok, log} -> log
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)
      end

      remove_route_audit_rejection_trigger!()

      refute Repo.exists?(from r in Route, where: r.route_id == "R-FAIL")

      assert Repo.aggregate(
               from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
               :count
             ) == 0
    end

    test "an invalid actor-bound route audit result rolls back its caller transaction", context do
      bad_audit = %{context.audit | actor_id: nil}

      assert {:error, %Ecto.Changeset{}} =
               Repo.transaction(fn ->
                 {:ok, route} =
                   Repo.insert(
                     Route.editor_changeset(
                       %Route{
                         organization_id: context.organization.id,
                         gtfs_version_id: context.version.id
                       },
                       %{route_id: "R-FAIL", route_type: 3, route_short_name: "99"},
                       :create
                     )
                   )

                 case Gtfs.record_change_in_transaction(bad_audit, :route, route, "created", %{
                        before: nil,
                        after: %{"route_id" => "R-FAIL", "route_short_name" => "99"}
                      }) do
                   {:ok, log} -> log
                   {:error, changeset} -> Repo.rollback(changeset)
                 end
               end)

      refute Repo.exists?(from r in Route, where: r.route_id == "R-FAIL")

      assert Repo.aggregate(
               from(l in ChangeLog, where: l.organization_id == ^context.organization.id),
               :count
             ) == 0
    end
  end

  # Test-only fault injection: a constraint trigger on `change_logs` raises on the
  # next route audit insert, after the route row is written. It is created inside
  # the sandbox transaction, so the guaranteed test rollback removes it, and this
  # test also drops it explicitly. No production failure switch exists.
  defp install_route_audit_rejection_trigger! do
    Repo.query!("""
    CREATE FUNCTION route_audit_rejection() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.entity_type = 'route' THEN
        RAISE EXCEPTION 'route audit rejection fixture' USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER route_audit_rejection_trigger
    AFTER INSERT ON change_logs
    DEFERRABLE INITIALLY IMMEDIATE
    FOR EACH ROW
    EXECUTE FUNCTION route_audit_rejection();
    """)
  end

  defp remove_route_audit_rejection_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS route_audit_rejection_trigger ON change_logs")
    Repo.query!("DROP FUNCTION IF EXISTS route_audit_rejection()")
  end
end

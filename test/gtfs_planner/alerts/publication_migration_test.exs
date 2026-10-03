defmodule GtfsPlanner.Alerts.PublicationMigrationTest do
  @moduledoc """
  Step 6: alerts are owned by their organization, not by the GTFS version they
  were written against.

  The migration rehearsal itself — synthetic pre-migration rows captured into
  `target_reference` and `timezone` while their source version still resolved —
  ran against the owned partition database and is recorded in the step learning.
  These cases own the post-migration contract: two versions' alerts survive
  intact, a deleted source clears only the provenance, the database refuses a
  cross-tenant source, and neither old ownership key survives.

  Rows are written by table name with explicit ids, because the point is the
  stored shape rather than a command path. Each expected constraint violation
  aborts the sandbox transaction, so every `assert_raise` sits in its own test
  (docs/engineering-standards.md, SQL Sandbox).
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Alerts.Alert
  alias GtfsPlanner.Alerts.Publication
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  setup do
    organization = organization_fixture()
    spring = gtfs_version_fixture(organization.id)
    fall = gtfs_version_fixture(organization.id)

    %{
      organization: organization,
      spring: spring,
      fall: fall,
      other_organization: organization_fixture(),
      route_uuid: Ecto.UUID.generate()
    }
  end

  describe "retained rows across two versions" do
    setup %{organization: organization, spring: spring, fall: fall, route_uuid: route_uuid} do
      %{
        detour:
          insert_alert(organization, spring, 7, "Detour", %{
            "shape" => "routes",
            "route_ids" => [route_uuid]
          }),
        system: insert_alert(organization, fall, 3, "System")
      }
    end

    test "keep their ids, answers, revisions and both source versions", context do
      detour = Repo.get!(Alert, context.detour)
      system = Repo.get!(Alert, context.system)

      assert detour.id == context.detour
      assert detour.source_gtfs_version_id == context.spring.id
      assert detour.revision == 7
      assert detour.message.header == "Detour"
      assert detour.scope.shape == :routes
      assert detour.scope.route_ids == [context.route_uuid]

      assert system.id == context.system
      assert system.source_gtfs_version_id == context.fall.id
      assert system.revision == 3
      assert system.message.header == "System"

      assert Repo.aggregate(Alert, :count, organization_id: context.organization.id) == 2
    end

    test "carry no public consent, entity id or captured reference", context do
      assert Repo.aggregate(Publication, :count) == 0

      for id <- [context.detour, context.system] do
        alert = Repo.get!(Alert, id)

        assert alert.target_reference == %{}
        assert alert.public_entity_id == nil
        assert alert.deleted_at == nil
        assert alert.timezone == nil
      end
    end

    test "lose only the source when the source version is deleted", context do
      Repo.delete_all(from(v in GtfsVersion, where: v.id == ^context.spring.id))

      alert = Repo.get!(Alert, context.detour)

      assert is_nil(alert.source_gtfs_version_id)
      assert alert.organization_id == context.organization.id
      assert alert.revision == 7
      assert alert.message.header == "Detour"
      assert alert.scope.route_ids == [context.route_uuid]

      # The organization's other version's alert is untouched.
      assert Repo.get!(Alert, context.system).source_gtfs_version_id == context.fall.id
    end

    test "keep captured wire ids and labels after the source version is deleted", context do
      Repo.query!(
        """
        UPDATE service_alerts SET target_reference = $2::text::jsonb WHERE id = $1
        """,
        [
          Ecto.UUID.dump!(context.detour),
          ~s({"source_gtfs_version_id":"#{context.spring.id}",) <>
            ~s("timezone":"America/New_York",) <>
            ~s("selectors":{"shape":"routes","routes":[) <>
            ~s({"id":"#{context.route_uuid}","gtfs_id":"R-1","label":"1 Main"}]}})
        ]
      )

      Repo.delete_all(from(v in GtfsVersion, where: v.id == ^context.spring.id))

      alert = Repo.get!(Alert, context.detour)

      assert alert.target_reference["selectors"]["shape"] == "routes"
      assert [route] = alert.target_reference["selectors"]["routes"]
      assert route["gtfs_id"] == "R-1"
      assert route["label"] == "1 Main"
      assert alert.target_reference["timezone"] == "America/New_York"
    end

    test "refuse a source version of another organization", context do
      foreign_version = gtfs_version_fixture(context.other_organization.id)

      error =
        assert_raise Postgrex.Error, fn ->
          insert_alert(context.organization, foreign_version, 1, "Borrowed")
        end

      assert Exception.message(error) =~ "service_alerts_source_version_owner_fkey"
    end
  end

  describe "alert_publications" do
    setup %{organization: organization, spring: spring} do
      %{alert: insert_alert(organization, spring, 4, "Scheduled")}
    end

    test "accepts one row per alert of the same organization and no public consent by default",
         context do
      assert Repo.aggregate(Publication, :count) == 0

      id = insert_publication(context.organization, context.alert, 4)

      assert Repo.get!(Publication, id).withdrawal == :none
    end

    test "refuse an alert of another organization", context do
      foreign_alert =
        insert_alert(
          context.other_organization,
          gtfs_version_fixture(context.other_organization.id),
          1,
          "Foreign"
        )

      error =
        assert_raise Postgrex.Error, fn ->
          insert_publication(context.organization, foreign_alert, 1)
        end

      assert Exception.message(error) =~ "alert_publications_alert_owner_fkey"
    end

    test "refuse a second row for the same alert", context do
      insert_publication(context.organization, context.alert, 4)

      error =
        assert_raise Postgrex.Error, fn ->
          insert_publication(context.organization, context.alert, 5)
        end

      assert Exception.message(error) =~ "alert_publications_alert_id_organization_id_index"
    end
  end

  describe "unresolved references" do
    test "store no fabricated selector for an identity that never resolved", context do
      unresolved = Ecto.UUID.generate()

      id =
        insert_alert(context.organization, context.spring, 2, "Needs attention", %{
          "shape" => "routes",
          "route_ids" => [unresolved]
        })

      alert = Repo.get!(Alert, id)

      assert alert.target_reference == %{}
      assert alert.scope.route_ids == [unresolved]
      assert alert.public_entity_id == nil
    end

    test "keep the public entity id unique across alerts", context do
      first = insert_alert(context.organization, context.spring, 1, "First")
      second = insert_alert(context.organization, context.fall, 1, "Second")
      entity_id = Ecto.UUID.generate()

      Repo.query!("UPDATE service_alerts SET public_entity_id = $2 WHERE id = $1", [
        Ecto.UUID.dump!(first),
        Ecto.UUID.dump!(entity_id)
      ])

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("UPDATE service_alerts SET public_entity_id = $2 WHERE id = $1", [
            Ecto.UUID.dump!(second),
            Ecto.UUID.dump!(entity_id)
          ])
        end

      assert Exception.message(error) =~ "service_alerts_public_entity_id_index"
    end
  end

  describe "replaced ownership constraints" do
    test "no longer carry the single-column cascade or the composite NO ACTION key" do
      names = constraint_names("service_alerts")

      refute "service_alerts_gtfs_version_id_fkey" in names
      refute "service_alerts_version_owner_fkey" in names
      assert "service_alerts_source_version_owner_fkey" in names
      assert "alert_publications_alert_owner_fkey" in constraint_names("alert_publications")
    end

    test "name the retained provenance key with a SET NULL source and nothing else" do
      %{rows: [[definition]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = $1",
          ["service_alerts_source_version_owner_fkey"]
        )

      assert definition ==
               "FOREIGN KEY (source_gtfs_version_id, organization_id) " <>
                 "REFERENCES gtfs_versions(id, organization_id) " <>
                 "ON DELETE SET NULL (source_gtfs_version_id)"
    end
  end

  defp constraint_names(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT conname FROM pg_constraint WHERE conrelid = to_regclass($1) ORDER BY conname",
        [table]
      )

    List.flatten(rows)
  end

  defp insert_alert(organization, version, revision, header, scope \\ %{}) do
    id = Ecto.UUID.generate()

    defaults = %{
      "shape" => "system",
      "route_ids" => []
    }

    Repo.insert_all("service_alerts", [
      %{
        id: Ecto.UUID.dump!(id),
        organization_id: Ecto.UUID.dump!(organization.id),
        source_gtfs_version_id: Ecto.UUID.dump!(version.id),
        revision: revision,
        scope: Map.merge(defaults, scope),
        timing: %{"time_zone" => "America/New_York"},
        message: %{"header" => header},
        complete: true,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp insert_publication(organization, alert_id, desired_revision) do
    id = Ecto.UUID.generate()

    Repo.insert_all("alert_publications", [
      %{
        id: Ecto.UUID.dump!(id),
        organization_id: Ecto.UUID.dump!(organization.id),
        alert_id: Ecto.UUID.dump!(alert_id),
        desired_revision: desired_revision,
        withdrawal: "none",
        inserted_at: now(),
        updated_at: now()
      }
    ])

    id
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end

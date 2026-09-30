defmodule GtfsPlanner.Gtfs.Stations.PathwayFieldsTest do
  use GtfsPlanner.DataCase, async: false

  import Ecto.Query

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.{Audit, AuditContext, Pathway, Stations}
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)
    station = stop_fixture(organization.id, version.id, location_type: 1)
    from = child_stop_fixture(organization.id, version.id, station.stop_id)
    to = child_stop_fixture(organization.id, version.id, station.stop_id)
    pathway = pathway_fixture(organization.id, version.id, from.stop_id, to.stop_id)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: station.stop_id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      actor: actor,
      from: from,
      to: to,
      pathway: pathway,
      audit: audit
    }
  end

  test "only companion fields persist, and one update increments the revision and history",
       scope do
    attrs = %{
      "traversal_time" => 90,
      "stair_count" => 4,
      "min_width" => "1.8",
      "signposted_as" => "Platform A",
      "reversed_signposted_as" => "Exit",
      "field_notes" => "Measured",
      "field_completed_at" => "2026-09-30T12:00:00Z",
      "pathway_mode" => 2,
      "length" => "99.0",
      "is_bidirectional" => false,
      "pathway_id" => "FORGED",
      "organization_id" => Ecto.UUID.generate(),
      "gtfs_version_id" => Ecto.UUID.generate(),
      "lock_version" => 99
    }

    assert {:ok, updated} =
             Stations.update_pathway_fields(
               scope.audit,
               scope.pathway.id,
               attrs,
               scope.pathway.lock_version
             )

    assert updated.traversal_time == 90
    assert updated.stair_count == 4
    assert Decimal.equal?(updated.min_width, Decimal.new("1.8"))
    assert updated.signposted_as == "Platform A"
    assert updated.reversed_signposted_as == "Exit"
    assert updated.field_notes == "Measured"
    assert DateTime.compare(updated.field_completed_at, ~U[2026-09-30 12:00:00Z]) == :eq
    assert updated.pathway_mode == scope.pathway.pathway_mode
    assert updated.length == scope.pathway.length
    assert updated.is_bidirectional == scope.pathway.is_bidirectional
    assert updated.pathway_id == scope.pathway.pathway_id
    assert updated.organization_id == scope.organization.id
    assert updated.gtfs_version_id == scope.version.id
    assert updated.lock_version == scope.pathway.lock_version + 1
    assert Repo.get!(Pathway, updated.id).lock_version == updated.lock_version

    assert [%{action: "updated", changed_fields: fields}] = logs(scope)

    assert Enum.sort(Map.keys(fields)) ==
             Enum.sort(
               ~w(field_completed_at field_notes min_width reversed_signposted_as signposted_as stair_count traversal_time)
             )
  end

  test "an exact endpoint swap is accepted and other endpoint edits write nothing", scope do
    for attrs <- [
          %{"from_stop_id" => scope.to.stop_id},
          %{"from_stop_id" => scope.to.stop_id, "to_stop_id" => scope.to.stop_id},
          %{"from_stop_id" => scope.from.stop_id, "to_stop_id" => "other-stop"}
        ] do
      assert {:error, :invalid_endpoints} =
               Stations.update_pathway_fields(
                 scope.audit,
                 scope.pathway.id,
                 attrs,
                 scope.pathway.lock_version
               )
    end

    assert Repo.get!(Pathway, scope.pathway.id).from_stop_id == scope.from.stop_id
    assert logs(scope) == []

    assert {:ok, swapped} =
             Stations.update_pathway_fields(
               scope.audit,
               scope.pathway.id,
               %{
                 "from_stop_id" => scope.to.stop_id,
                 "to_stop_id" => scope.from.stop_id,
                 "traversal_time" => 120
               },
               scope.pathway.lock_version
             )

    assert {swapped.from_stop_id, swapped.to_stop_id} ==
             {scope.to.stop_id, scope.from.stop_id}

    assert swapped.lock_version == scope.pathway.lock_version + 1
    assert [%{action: "updated", changed_fields: fields}] = logs(scope)
    assert Enum.sort(Map.keys(fields)) == ~w(from_stop_id to_stop_id traversal_time)
  end

  test "editor normalization cannot change a field outside the companion allowlist", scope do
    {1, _} =
      Repo.update_all(
        from(p in Pathway, where: p.id == ^scope.pathway.id),
        set: [pathway_mode: 7, is_bidirectional: true]
      )

    current = Repo.get!(Pathway, scope.pathway.id)

    assert {:ok, updated} =
             Stations.update_pathway_fields(
               scope.audit,
               current.id,
               %{"traversal_time" => 90, "is_bidirectional" => false},
               current.lock_version
             )

    assert updated.is_bidirectional == true
    assert updated.lock_version == current.lock_version + 1
    assert [%{changed_fields: fields}] = logs(scope)
    assert Map.keys(fields) == ["traversal_time"]
  end

  test "a stale revision, including a replay, cannot write a second history row", scope do
    attrs = %{"traversal_time" => 120}

    assert {:ok, updated} =
             Stations.update_pathway_fields(
               scope.audit,
               scope.pathway.id,
               attrs,
               scope.pathway.lock_version
             )

    assert {:error, {:stale, current}} =
             Stations.update_pathway_fields(
               scope.audit,
               scope.pathway.id,
               attrs,
               scope.pathway.lock_version
             )

    assert current == updated.lock_version
    assert Repo.get!(Pathway, scope.pathway.id).traversal_time == 120
    assert length(logs(scope)) == 1
  end

  test "a revoked actor cannot update a pathway", scope do
    membership =
      GtfsPlanner.Accounts.get_user_org_membership(scope.actor.id, scope.organization.id)

    deactivate_membership_fixture(membership)

    assert {:error, :forbidden} =
             Stations.update_pathway_fields(
               scope.audit,
               scope.pathway.id,
               %{"traversal_time" => 120},
               scope.pathway.lock_version
             )

    assert Repo.get!(Pathway, scope.pathway.id).traversal_time == scope.pathway.traversal_time
    assert logs(scope) == []
  end

  test "a pathway outside the selected station is hidden", scope do
    other_station = stop_fixture(scope.organization.id, scope.version.id, location_type: 1)

    other_from =
      child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id)

    other_to = child_stop_fixture(scope.organization.id, scope.version.id, other_station.stop_id)

    other =
      pathway_fixture(
        scope.organization.id,
        scope.version.id,
        other_from.stop_id,
        other_to.stop_id
      )

    assert {:error, :not_found} =
             Stations.update_pathway_fields(scope.audit, other.id, %{"traversal_time" => 120}, 1)

    assert Repo.get!(Pathway, other.id).traversal_time == other.traversal_time
  end

  test "a failed history insert rolls back the pathway update", scope do
    invalid_audit = %{scope.audit | actor_email: nil}

    assert {:error, %Ecto.Changeset{}} =
             Stations.update_pathway_fields(
               invalid_audit,
               scope.pathway.id,
               %{"traversal_time" => 120},
               scope.pathway.lock_version
             )

    assert Repo.get!(Pathway, scope.pathway.id).traversal_time == scope.pathway.traversal_time
    assert Repo.get!(Pathway, scope.pathway.id).lock_version == scope.pathway.lock_version
    assert logs(scope) == []
  end

  defp logs(scope) do
    Audit.list_change_logs_for_entity(
      scope.audit.organization_id,
      scope.audit.gtfs_version_id,
      "pathway",
      scope.pathway.id
    )
  end
end

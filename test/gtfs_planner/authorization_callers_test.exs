defmodule GtfsPlanner.AuthorizationCallersTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Agency
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FeedSettings
  alias GtfsPlanner.Gtfs.PathwayEvolution
  alias GtfsPlanner.Gtfs.PathwayEvolutions
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    actor = user_fixture()
    membership = organization_membership_fixture(actor, organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      actor: actor,
      membership: membership,
      audit: audit
    }
  end

  test "pathway closure creation rejects a deactivated editor before writing", context do
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             PathwayEvolutions.create_pathway_evolution(
               %{pathway_id: "P1", service_id: "WEEKDAY", start_time: "09:00", end_time: "10:00"},
               context.audit
             )

    refute Repo.exists?(
             from e in PathwayEvolution, where: e.gtfs_version_id == ^context.version.id
           )

    refute Repo.exists?(from l in ChangeLog, where: l.gtfs_version_id == ^context.version.id)
  end

  test "agency update rejects a removed editor role and preserves the row", context do
    agency =
      agency_fixture(context.organization.id, context.version.id, %{
        agency_id: "A1",
        agency_name: "Original",
        agency_url: "https://example.com",
        agency_timezone: "America/New_York"
      })

    context.membership
    |> Ecto.Changeset.change(roles: [])
    |> Repo.update!()

    assert {:error, :forbidden} =
             FeedSettings.update_agency(
               context.audit,
               agency.id,
               %{"agency_name" => "Changed"},
               agency.updated_at
             )

    assert %Agency{agency_name: "Original", updated_at: updated_at} = Repo.get!(Agency, agency.id)
    assert updated_at == agency.updated_at
  end

  test "agent scope rechecks a deactivated membership", context do
    scope = %Scope{
      organization_id: context.organization.id,
      gtfs_version_id: context.version.id,
      user_id: context.actor.id,
      pack_id: "calendars"
    }

    assert :ok = Scope.authorize(scope)
    deactivate_membership_fixture(context.membership)
    assert {:error, :forbidden} = Scope.authorize(scope)
  end
end

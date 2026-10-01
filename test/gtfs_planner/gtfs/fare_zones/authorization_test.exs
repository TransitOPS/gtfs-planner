defmodule GtfsPlanner.Gtfs.FareZones.AuthorizationTest do
  use GtfsPlanner.DataCase, async: true

  import Ecto.Query
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop

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

    %{audit: audit, membership: membership}
  end

  test "a revoked editor cannot write an assignment, zone, or rule", context do
    audit = context.audit

    {:ok, _zone} =
      FareZones.create_zone(audit, %{"zone_id" => "A", "name" => "Central", "color" => "ocean"})

    stop =
      Repo.insert!(%Stop{
        organization_id: audit.organization_id,
        gtfs_version_id: audit.gtfs_version_id,
        stop_id: "P1",
        stop_name: "Platform 1",
        location_type: 0
      })

    Repo.insert!(%FareAttribute{
      organization_id: audit.organization_id,
      gtfs_version_id: audit.gtfs_version_id,
      fare_id: "F1",
      price: Decimal.new("2.50"),
      currency_type: "USD",
      payment_method: 0
    })

    {:ok, %{applied: applied}} =
      FareZones.apply_assignment(audit, [%{id: stop.id, from: nil, to: "A"}])

    rule_attrs = %{
      "fare_id" => "F1",
      "route_id" => "",
      "origin_id" => "A",
      "destination_id" => "",
      "contains" => []
    }

    {:ok, reviewed} = FareZones.save_rule_group(audit, nil, rule_attrs)
    before = scoped_rows(audit)
    deactivate_membership_fixture(context.membership)

    commands = [
      {:apply_assignment,
       fn ->
         FareZones.apply_assignment(audit, [%{id: stop.id, from: "A", to: nil}])
       end},
      {:undo_assignment, fn -> FareZones.undo_assignment(audit, applied) end},
      {:create_zone,
       fn ->
         FareZones.create_zone(audit, %{
           "zone_id" => "B",
           "name" => "East",
           "color" => "teal"
         })
       end},
      {:update_zone, fn -> FareZones.update_zone(audit, "A", %{"name" => "Changed"}) end},
      {:delete_zone,
       fn ->
         FareZones.delete_zone(audit, "A", nil, %{stop_count: 1, rule_count: 1})
       end},
      {:save_rule_group,
       fn ->
         FareZones.save_rule_group(audit, reviewed, %{rule_attrs | "origin_id" => ""})
       end},
      {:delete_rule_group, fn -> FareZones.delete_rule_group(audit, reviewed) end}
    ]

    Enum.each(commands, fn {name, command} ->
      assert {:error, :forbidden} = command.(), "#{name} accepted a revoked editor"
      assert scoped_rows(audit) == before, "#{name} changed fare data"
    end)

    unavailable_audit = %{audit | gtfs_version_id: Ecto.UUID.generate()}

    assert {:error, :forbidden} =
             FareZones.create_zone(unavailable_audit, %{
               "zone_id" => "B",
               "name" => "East",
               "color" => "teal"
             })

    assert scoped_rows(audit) == before
  end

  test "a missing or wrong-role membership cannot create a zone", %{audit: audit} do
    outsider = user_fixture()
    admin = user_fixture()

    organization_membership_fixture(admin, %{id: audit.organization_id}, ["pathways_studio_admin"])

    attrs = %{"zone_id" => "A", "name" => "Central", "color" => "ocean"}
    before = scoped_rows(audit)

    assert {:error, :forbidden} =
             FareZones.create_zone(%{audit | actor_id: outsider.id}, attrs)

    assert scoped_rows(audit) == before

    assert {:error, :forbidden} =
             FareZones.create_zone(%{audit | actor_id: admin.id}, attrs)

    assert scoped_rows(audit) == before
  end

  defp scoped_rows(audit) do
    for schema <- [Stop, FareZone, FareAttribute, FareRule, ChangeLog], into: %{} do
      rows =
        from(row in schema,
          where:
            row.organization_id == ^audit.organization_id and
              row.gtfs_version_id == ^audit.gtfs_version_id,
          order_by: row.id
        )
        |> Repo.all()

      {schema, rows}
    end
  end
end

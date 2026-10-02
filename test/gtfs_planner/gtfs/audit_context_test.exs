defmodule GtfsPlanner.Gtfs.AuditContextTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.AuditContext

  describe "struct" do
    test "can be created with all fields set" do
      org_id = Ecto.UUID.generate()
      version_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      ctx = %AuditContext{
        organization_id: org_id,
        gtfs_version_id: version_id,
        station_stop_id: "station_central",
        actor_id: actor_id,
        actor_email: "user@example.com"
      }

      assert ctx.organization_id == org_id
      assert ctx.gtfs_version_id == version_id
      assert ctx.station_stop_id == "station_central"
      assert ctx.actor_id == actor_id
      assert ctx.actor_email == "user@example.com"
    end

    test "inspect/1 produces a human-readable representation" do
      org_id = Ecto.UUID.generate()
      version_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      ctx = %AuditContext{
        organization_id: org_id,
        gtfs_version_id: version_id,
        station_stop_id: "station_central",
        actor_id: actor_id,
        actor_email: "user@example.com"
      }

      inspected = inspect(ctx)
      assert inspected =~ "GtfsPlanner.Gtfs.AuditContext"
      assert inspected =~ "user@example.com"
    end
  end

  describe "from_assigns/1" do
    test "uses the station stop_id when a station assign is present" do
      organization_id = Ecto.UUID.generate()
      gtfs_version_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert %AuditContext{
               organization_id: ^organization_id,
               gtfs_version_id: ^gtfs_version_id,
               station_stop_id: "S1",
               actor_id: ^actor_id,
               actor_email: "user@example.com"
             } =
               AuditContext.from_assigns(%{
                 current_organization: %{id: organization_id},
                 current_gtfs_version: %{id: gtfs_version_id},
                 current_user: %{id: actor_id, email: "user@example.com"},
                 station: %{stop_id: "S1"}
               })
    end

    test "leaves station_stop_id nil when the assigns have no :station key" do
      organization_id = Ecto.UUID.generate()
      gtfs_version_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert %AuditContext{
               organization_id: ^organization_id,
               gtfs_version_id: ^gtfs_version_id,
               station_stop_id: nil,
               actor_id: ^actor_id,
               actor_email: "user@example.com"
             } =
               AuditContext.from_assigns(%{
                 current_organization: %{id: organization_id},
                 current_gtfs_version: %{id: gtfs_version_id},
                 current_user: %{id: actor_id, email: "user@example.com"}
               })
    end

    test "leaves station_stop_id nil when station is nil" do
      organization_id = Ecto.UUID.generate()
      gtfs_version_id = Ecto.UUID.generate()
      actor_id = Ecto.UUID.generate()

      assert %AuditContext{
               organization_id: ^organization_id,
               gtfs_version_id: ^gtfs_version_id,
               station_stop_id: nil,
               actor_id: ^actor_id,
               actor_email: "user@example.com"
             } =
               AuditContext.from_assigns(%{
                 current_organization: %{id: organization_id},
                 current_gtfs_version: %{id: gtfs_version_id},
                 current_user: %{id: actor_id, email: "user@example.com"},
                 station: nil,
                 stop_id: "S1"
               })
    end
  end
end

defmodule GtfsPlanner.Repo.Migrations.FareEditingOwnershipConstraintsTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.FareProductDetail
  alias GtfsPlanner.Gtfs.FareSavedJourney
  alias GtfsPlanner.Gtfs.FareTimePeriod
  alias GtfsPlanner.Gtfs.FareVersionSetting

  @tables [
    {"fare_product_details", FareProductDetail},
    {"fare_saved_journeys", FareSavedJourney},
    {"fare_time_periods", FareTimePeriod},
    {"fare_version_settings", FareVersionSetting}
  ]

  for {table, schema} <- @tables do
    test "#{table} retains old wrong-owner rows and rejects new wrong-owner rows" do
      table = unquote(table)
      schema = unquote(schema)
      constraint = "#{table}_version_owner_fkey"
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      foreign = organization_fixture()
      retained_version = gtfs_version_fixture(foreign.id)
      new_foreign_version = gtfs_version_fixture(foreign.id)

      %{rows: [[definition, false]]} =
        Repo.query!(
          "SELECT pg_get_constraintdef(oid), convalidated FROM pg_constraint WHERE conname = $1",
          [constraint]
        )

      assert definition =~ "FOREIGN KEY (gtfs_version_id, organization_id)"
      assert definition =~ "REFERENCES gtfs_versions(id, organization_id)"
      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{constraint}")
      retained = row(schema, organization.id, retained_version.id)
      Repo.insert_all(schema, [retained])
      before = Repo.get!(schema, retained.id)

      Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT #{constraint} #{definition}")
      assert Repo.get!(schema, retained.id) == before

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.insert_all(schema, [row(schema, organization.id, new_foreign_version.id)])
          end)
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == constraint
      valid = row(schema, organization.id, version.id)
      assert {1, nil} = Repo.insert_all(schema, [valid])
      assert Repo.get!(schema, valid.id).gtfs_version_id == version.id

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.transaction(fn ->
            Repo.query!("ALTER TABLE #{table} VALIDATE CONSTRAINT #{constraint}")
          end)
        end

      assert error.postgres.code == :foreign_key_violation
      assert error.postgres.constraint == constraint
      assert Repo.get!(schema, retained.id) == before
    end
  end

  defp row(schema, organization_id, version_id) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: version_id,
        inserted_at: now,
        updated_at: now
      },
      attributes(schema)
    )
  end

  defp attributes(FareProductDetail), do: %{fare_product_id: "ownership_ride"}

  defp attributes(FareSavedJourney),
    do: %{
      name: "Ownership journey",
      rider_category_id: "adult",
      legs: [%{"route_id" => "R1", "from_stop_id" => "A", "to_stop_id" => "B"}],
      service_date: ~D[2026-09-07],
      expected_amount: Decimal.new("1.50")
    }

  defp attributes(FareTimePeriod), do: %{name: "Ownership period", service_id: "fare_ownership"}
  defp attributes(FareVersionSetting), do: %{managed_at: DateTime.utc_now()}
end

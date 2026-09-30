defmodule GtfsPlanner.Repo.Migrations.ValidateOwnershipConstraintsTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo.Migrations.ValidateOwnershipConstraints, as: Migration
  alias GtfsPlanner.Repo.Migrations.ValidateUpstreamOwnershipConstraints, as: UpstreamMigration

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @migration_glob "../../../../priv/repo/migrations/*_validate_ownership_constraints.exs"
  @migration_path (case Path.wildcard(Path.expand(@migration_glob, __DIR__)) do
                     [path] ->
                       path

                     paths ->
                       raise "expected one ownership validation migration, got: #{inspect(paths)}"
                   end)

  Code.require_file(@migration_path)

  @upstream_migration_path (case Path.wildcard(
                                   Path.expand(
                                     "../../../../priv/repo/migrations/*_validate_upstream_ownership_constraints.exs",
                                     __DIR__
                                   )
                                 ) do
                              [path] ->
                                path

                              paths ->
                                raise "expected one upstream validation migration, got: #{inspect(paths)}"
                            end)

  Code.require_file(@upstream_migration_path)

  @constraint "routes_version_owner_fkey"

  test "validates every step 8 ownership constraint" do
    reset_route_constraint()
    assert constraint_validated?(@constraint) == false

    assert :ok == Migration.validate_all!(Repo)

    assert %{rows: rows} = Repo.query!(constraint_status_sql(), [])
    assert length(rows) == 66
    assert Enum.all?(rows, fn [_name, validated?] -> validated? end)
  end

  test "the additive migration validates all eleven constraints independently" do
    for {table, name} <- upstream_constraints() do
      %{rows: [[definition]]} =
        Repo.query!(
          """
          SELECT pg_get_constraintdef(c.oid)
          FROM pg_constraint AS c
          JOIN pg_class AS child ON child.oid = c.conrelid
          WHERE child.relname = $1 AND c.conname = $2
          """,
          [table, name]
        )

      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{name}")
      Repo.query!("ALTER TABLE #{table} ADD CONSTRAINT #{name} #{definition} NOT VALID")
      assert constraint_validated?(table, name) == false
    end

    assert :ok = UpstreamMigration.validate_all!(Repo)

    assert Enum.all?(upstream_constraints(), fn {table, name} ->
             constraint_validated?(table, name)
           end)
  end

  test "the additive migration refuses a missing constraint" do
    {table, name} = hd(upstream_constraints())
    Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{name}")

    error = assert_raise RuntimeError, fn -> UpstreamMigration.validate_all!(Repo) end
    assert error.message =~ name
    assert error.message =~ "missing"
    assert error.message =~ "No rows were changed"
  end

  test "a version anomaly fails additive validation without changing the row" do
    name = "deadhead_times_version_owner_fkey"
    Repo.query!("ALTER TABLE deadhead_times DROP CONSTRAINT #{name}")
    org = organization_fixture()
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO deadhead_times
        (id, organization_id, gtfs_version_id, from_ref, to_ref, minutes, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'stop:A', 'stop:B', 7, now(), now())
      """,
      Enum.map([id, org.id, foreign_version.id], &Ecto.UUID.dump!/1)
    )

    Repo.query!("""
    ALTER TABLE deadhead_times ADD CONSTRAINT #{name}
    FOREIGN KEY (gtfs_version_id, organization_id)
    REFERENCES gtfs_versions (id, organization_id) ON DELETE NO ACTION NOT VALID
    """)

    before = row_json("deadhead_times", id)
    assert_validation_failure!(name)
    assert row_json("deadhead_times", id) == before
    assert constraint_validated?("deadhead_times", name) == false
  end

  test "each asset-parent class blocks validation and preserves its anomalous row" do
    org = organization_fixture()
    version = gtfs_version_fixture(org.id)
    foreign_org = organization_fixture()
    garage = GtfsPlanner.OperationsFixtures.garage_fixture(foreign_org.id)
    vehicle_type = GtfsPlanner.OperationsFixtures.vehicle_type_fixture(foreign_org.id)

    for {table, column, parent} <- asset_links() do
      Repo.query!("SAVEPOINT asset_validation_case")
      name = "#{table}_#{column}_owner_fkey"
      Repo.query!("ALTER TABLE #{table} DROP CONSTRAINT #{name}")
      parent_id = if parent == "garages", do: garage.id, else: vehicle_type.id
      id = insert_asset_link!(table, column, org.id, version.id, parent_id)

      Repo.query!("""
      ALTER TABLE #{table} ADD CONSTRAINT #{name}
      FOREIGN KEY (#{column}, organization_id)
      REFERENCES #{parent} (id, organization_id) ON DELETE NO ACTION NOT VALID
      """)

      before = row_json(table, id)
      assert_validation_failure!(name)
      assert row_json(table, id) == before
      assert constraint_validated?(table, name) == false
      Repo.query!("ROLLBACK TO SAVEPOINT asset_validation_case")
    end
  end

  test "an existing ownership anomaly blocks validation without changing its row" do
    Repo.query!("ALTER TABLE routes DROP CONSTRAINT #{@constraint}")

    org = organization_fixture()
    other_org = organization_fixture()
    other_version = gtfs_version_fixture(other_org.id)
    route_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    assert {1, _} =
             Repo.insert_all(Route, [
               %{
                 id: route_id,
                 route_id: "foreign",
                 route_type: 3,
                 organization_id: org.id,
                 gtfs_version_id: other_version.id,
                 inserted_at: now,
                 updated_at: now
               }
             ])

    add_route_constraint()
    before = route_row(route_id)
    assert constraint_validated?(@constraint) == false

    error =
      assert_raise RuntimeError, fn ->
        Repo.transaction(fn -> Migration.validate_all!(Repo) end)
      end

    assert error.message =~ @constraint
    assert error.message =~ "No rows were changed"
    assert error.message =~ "mix gtfs.audit_ownership"

    assert error.message =~
             "bin/gtfs_planner eval 'case GtfsPlanner.Release.audit_ownership() do " <>
               ":ok -> :ok; {:error, _count} -> System.halt(1) end'"

    assert route_row(route_id) == before
    assert constraint_validated?(@constraint) == false
  end

  test "a missing expected constraint stops validation" do
    Repo.query!("ALTER TABLE routes DROP CONSTRAINT #{@constraint}")

    error = assert_raise RuntimeError, fn -> Migration.validate_all!(Repo) end

    assert error.message =~ @constraint
    assert error.message =~ "missing"
    assert error.message =~ "No rows were changed"

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM pg_constraint WHERE conname = $1", [@constraint])
  end

  defp reset_route_constraint do
    Repo.query!("ALTER TABLE routes DROP CONSTRAINT #{@constraint}")
    add_route_constraint()
  end

  defp add_route_constraint do
    Repo.query!("""
    ALTER TABLE routes
    ADD CONSTRAINT #{@constraint}
    FOREIGN KEY (gtfs_version_id, organization_id)
    REFERENCES gtfs_versions (id, organization_id)
    ON DELETE NO ACTION NOT VALID
    """)
  end

  defp constraint_validated?(name) do
    %{rows: [[validated?]]} =
      Repo.query!(
        """
        SELECT c.convalidated
        FROM pg_constraint AS c
        JOIN pg_class AS child ON child.oid = c.conrelid
        JOIN pg_namespace AS ns ON ns.oid = child.relnamespace
        WHERE ns.nspname = 'public' AND child.relname = 'routes' AND c.conname = $1
        """,
        [name]
      )

    validated?
  end

  defp constraint_validated?(table, name) do
    %{rows: [[validated?]]} =
      Repo.query!(
        """
        SELECT c.convalidated FROM pg_constraint AS c
        JOIN pg_class AS child ON child.oid = c.conrelid
        JOIN pg_namespace AS ns ON ns.oid = child.relnamespace
        WHERE ns.nspname = 'public' AND child.relname = $1 AND c.conname = $2
        """,
        [table, name]
      )

    validated?
  end

  defp upstream_constraints do
    Enum.map(
      ~w(block_attributes route_operating_settings deadhead_times relief_points),
      fn table ->
        {table, "#{table}_version_owner_fkey"}
      end
    ) ++
      Enum.map(asset_links(), fn {table, column, _parent} ->
        {table, "#{table}_#{column}_owner_fkey"}
      end)
  end

  defp asset_links do
    [
      {"block_attributes", "garage_id", "garages"},
      {"block_attributes", "vehicle_type_id", "vehicle_types"},
      {"route_operating_settings", "garage_id", "garages"},
      {"route_operating_settings", "required_vehicle_type_id", "vehicle_types"},
      {"blocking_settings", "default_garage_id", "garages"},
      {"vehicles", "garage_id", "garages"},
      {"vehicles", "vehicle_type_id", "vehicle_types"}
    ]
  end

  defp assert_validation_failure!(name) do
    error =
      assert_raise RuntimeError, fn ->
        Repo.transaction(fn -> UpstreamMigration.validate_all!(Repo) end)
      end

    assert error.message =~ name
    assert error.message =~ "No rows were changed"
    assert error.message =~ "mix gtfs.audit_ownership"

    assert error.message =~
             "bin/gtfs_planner eval 'case GtfsPlanner.Release.audit_ownership() do "
  end

  defp row_json(table, id) do
    %{rows: [[json]]} =
      Repo.query!("SELECT row_to_json(t)::text FROM #{table} AS t WHERE t.id = $1", [
        Ecto.UUID.dump!(id)
      ])

    json
  end

  defp insert_asset_link!(table, column, org_id, version_id, parent_id) do
    id = Ecto.UUID.generate()
    base = [Ecto.UUID.dump!(id), Ecto.UUID.dump!(org_id)]
    asset = Ecto.UUID.dump!(parent_id)

    case table do
      "block_attributes" ->
        Repo.query!(
          """
          INSERT INTO block_attributes
            (id, organization_id, gtfs_version_id, service_id, block_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, 'SERVICE', $4, $5, now(), now())
          """,
          base ++ [Ecto.UUID.dump!(version_id), "BLOCK_#{id}", asset]
        )

      "route_operating_settings" ->
        Repo.query!(
          """
          INSERT INTO route_operating_settings
            (id, organization_id, gtfs_version_id, route_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, $5, now(), now())
          """,
          base ++ [Ecto.UUID.dump!(version_id), "ROUTE_#{id}", asset]
        )

      "blocking_settings" ->
        Repo.query!(
          """
          INSERT INTO blocking_settings
            (id, organization_id, gtfs_version_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, now(), now())
          """,
          base ++ [Ecto.UUID.dump!(version_id), asset]
        )

      "vehicles" ->
        Repo.query!(
          """
          INSERT INTO vehicles (id, organization_id, vehicle_id, #{column}, inserted_at, updated_at)
          VALUES ($1, $2, $3, $4, now(), now())
          """,
          base ++ ["VEHICLE_#{id}", asset]
        )
    end

    id
  end

  defp route_row(id) do
    %{rows: [[row]]} =
      Repo.query!("SELECT row_to_json(routes)::text FROM routes WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    row
  end

  defp constraint_status_sql do
    """
    SELECT c.conname, c.convalidated
    FROM pg_constraint AS c
    JOIN pg_class AS child ON child.oid = c.conrelid
    JOIN pg_namespace AS ns ON ns.oid = child.relnamespace
    WHERE ns.nspname = 'public' AND c.contype = 'f'
      AND (c.conname LIKE '%_version_owner_fkey' OR c.conname LIKE '%_owner_fkey')
    """
  end
end

defmodule GtfsPlanner.Repo.Migrations.ValidateOwnershipConstraintsTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Repo.Migrations.ValidateOwnershipConstraints, as: Migration

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

  @constraint "routes_version_owner_fkey"

  test "validates every step 8 ownership constraint" do
    reset_route_constraint()
    assert constraint_validated?(@constraint) == false

    assert :ok == Migration.validate_all!(Repo)

    assert %{rows: rows} = Repo.query!(constraint_status_sql(), [])
    assert length(rows) == 55
    assert Enum.all?(rows, fn [_name, validated?] -> validated? end)
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

defmodule GtfsPlanner.Repo.Migrations.CreatePathwayEvolutionsTest do
  # This migration test exercises real DDL (table, check constraints, unique
  # tuple index, composite scoped pathway reference, rollback) using
  # Ecto.Migrator against real autocommit connections in :auto mode, isolating
  # all writes in a unique PostgreSQL schema dropped on exit.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Repo

  setup_all do
    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  @migration_glob "../../../../priv/repo/migrations/*_create_pathway_evolutions.exs"

  @migration_path (
                    matches = Path.wildcard(Path.expand(@migration_glob, __DIR__))

                    case matches do
                      [path] ->
                        path

                      other ->
                        raise "expected exactly one pathway-evolutions migration file, got: #{inspect(other)}"
                    end
                  )

  Code.require_file(@migration_path)

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  alias GtfsPlanner.Repo.Migrations.CreatePathwayEvolutions, as: Migration

  @now ~U[2026-01-01 00:00:00.000000Z]
  # 23:00 and 26:00 as service-day seconds: the overnight window the design stores.
  @overnight_start 82_800
  @overnight_end 93_600

  describe "up/0 adds the closure table with its scope guarantees" do
    setup do
      scope = build_scope()
      migrate_up(scope.schema)
      scope
    end

    test "the table, primary key, indexes and constraints exist", %{schema: schema} do
      assert table_exists?(schema, "pathway_evolutions")

      indexes = index_names(schema, "pathway_evolutions")

      for name <- ~w(pathway_evolutions_pkey pathway_evolutions_closure_index
                     pathway_evolutions_service_id_index) do
        assert name in indexes, "expected index #{name}, got: #{inspect(indexes)}"
      end

      constraints = constraint_names(schema, "pathway_evolutions")

      for name <- ~w(
            pathway_evolutions_identity_check
            pathway_evolutions_window_check
            pathway_evolutions_closure_index
            pathway_evolutions_pathway_fkey
          ) do
        assert name in constraints, "expected constraint #{name}, got: #{inspect(constraints)}"
      end
    end

    test "the closure tuple is unique only within its organization and version", scope do
      insert_closure(scope, pathway_id: "PW_A", service_id: "SVC_1")

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "PW_A", service_id: "SVC_1")
      end

      # A different window, service, pathway, version or organization is a new tuple.
      insert_closure(scope, pathway_id: "PW_A", service_id: "SVC_1", start_time: 3600)
      insert_closure(scope, pathway_id: "PW_A", service_id: "SVC_2")
      insert_closure(scope, pathway_id: "PW_B", service_id: "SVC_1")

      sibling_version = insert_version(scope.schema, scope.org_id)
      insert_pathway(scope.schema, scope.org_id, sibling_version, "PW_A")

      insert_closure(scope,
        gtfs_version_id: sibling_version,
        pathway_id: "PW_A",
        service_id: "SVC_1"
      )

      other_org = insert_org(scope.schema)
      other_version = insert_version(scope.schema, other_org)
      insert_pathway(scope.schema, other_org, other_version, "PW_A")

      insert_closure(scope,
        organization_id: other_org,
        gtfs_version_id: other_version,
        pathway_id: "PW_A",
        service_id: "SVC_1"
      )
    end

    test "an identifier that differs only by an internal space is a distinct tuple",
         scope do
      insert_pathway(scope.schema, scope.org_id, scope.version_id, "PW SPACE")
      insert_pathway(scope.schema, scope.org_id, scope.version_id, "PWSPACE")

      insert_closure(scope, pathway_id: "PW SPACE", service_id: "SVC_1")
      insert_closure(scope, pathway_id: "PWSPACE", service_id: "SVC_1")

      assert %{rows: rows} =
               SQL.query!(
                 Repo,
                 ~s|SELECT pathway_id FROM "#{scope.schema}".pathway_evolutions WHERE service_id = 'SVC_1' ORDER BY pathway_id|,
                 []
               )

      assert rows == [["PW SPACE"], ["PWSPACE"]]
    end

    test "the composite reference restricts deletion of a referenced pathway", scope do
      insert_closure(scope, pathway_id: "PW_A")

      # confdeltype "r" (RESTRICT) and confupdtype "a" (NO ACTION).
      assert %{rows: [["r", "a"]]} =
               SQL.query!(
                 Repo,
                 """
                 SELECT con.confdeltype, con.confupdtype
                 FROM pg_constraint con
                 JOIN pg_namespace ns ON ns.oid = con.connamespace
                 WHERE con.conname = 'pathway_evolutions_pathway_fkey' AND ns.nspname = $1
                 """,
                 [scope.schema]
               )

      assert_raise Postgrex.Error, fn ->
        SQL.query!(
          Repo,
          ~s|DELETE FROM "#{scope.schema}".pathways WHERE pathway_id = 'PW_A'|,
          []
        )
      end
    end
  end

  describe "up/down/up preserves preexisting pathway rows" do
    test "pathway rows remain unchanged across a migration cycle" do
      schema = setup_prefix()
      org_id = insert_org(schema)
      version_id = insert_version(schema, org_id)
      insert_pathway(schema, org_id, version_id, "PW_KEEP")
      pre_pathways = fetch_pathways(schema)

      assert pre_pathways != []

      migrate_up(schema)
      assert table_exists?(schema, "pathway_evolutions")
      assert fetch_pathways(schema) == pre_pathways

      migrate_down(schema)
      refute table_exists?(schema, "pathway_evolutions")
      assert fetch_pathways(schema) == pre_pathways
      assert_surrounding_tables(schema)

      migrate_up(schema)
      assert table_exists?(schema, "pathway_evolutions")
      assert fetch_pathways(schema) == pre_pathways
    end

    test "migration down removes only the closure table" do
      schema = setup_prefix()
      org_id = insert_org(schema)
      version_id = insert_version(schema, org_id)
      insert_pathway(schema, org_id, version_id, "PW_KEEP")
      migrate_up(schema)

      insert_closure(
        %{schema: schema, org_id: org_id, version_id: version_id},
        pathway_id: "PW_KEEP"
      )

      migrate_down(schema)

      refute table_exists?(schema, "pathway_evolutions")
      assert_surrounding_tables(schema)
      assert fetch_pathways(schema) != []
    end
  end

  describe "database constraints refuse malformed or unscoped closures" do
    setup do
      scope = build_scope(~w(PW_A PW_B PW_ORDER PW_OVERNIGHT))
      migrate_up(scope.schema)
      scope
    end

    test "an overnight window stores integer service-day seconds", scope do
      insert_closure(scope, pathway_id: "PW_OVERNIGHT")

      assert %{rows: [[@overnight_start, @overnight_end]]} =
               SQL.query!(
                 Repo,
                 ~s|SELECT start_time, end_time FROM "#{scope.schema}".pathway_evolutions WHERE pathway_id = 'PW_OVERNIGHT'|,
                 []
               )
    end

    test "an end at or before the start, and a negative start, fail at the database", scope do
      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "PW_ORDER", start_time: 3600, end_time: 3600)
      end

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope,
          pathway_id: "PW_ORDER",
          start_time: @overnight_end,
          end_time: @overnight_start
        )
      end

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "PW_ORDER", start_time: -3600, end_time: 3600)
      end

      # The same pathway with a half-open window, a zero start and the overnight
      # window above 24:00 are all accepted, so the refusals above are the window
      # check and not a fixture artefact.
      insert_closure(scope, pathway_id: "PW_ORDER", start_time: 3600, end_time: 3601)
      insert_closure(scope, pathway_id: "PW_ORDER", start_time: 0, end_time: 3600)
    end

    test "a blank pathway or service identifier fails at the database even when a
      blank pathway row exists",
         scope do
      # The identifier check is what refuses these rows, not the composite reference.
      insert_pathway(scope.schema, scope.org_id, scope.version_id, "   ")

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "   ", service_id: "SVC_1")
      end

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "PW_A", service_id: "   ")
      end

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "", service_id: "SVC_1")
      end
    end

    test "an unknown pathway, a pathway from another version and a mixed scope all fail",
         scope do
      # No pathway row with this identifier exists in this scope.
      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "PW_MISSING")
      end

      # The identifier exists in the database, but only in a foreign organization.
      foreign_org = insert_org(scope.schema)
      foreign_version = insert_version(scope.schema, foreign_org)
      insert_pathway(scope.schema, foreign_org, foreign_version, "PW_FOREIGN")

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "PW_FOREIGN")
      end

      # The identifier exists in this organization, but in another version.
      sibling_version = insert_version(scope.schema, scope.org_id)
      insert_pathway(scope.schema, scope.org_id, sibling_version, "PW_SIBLING")

      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, pathway_id: "PW_SIBLING")
      end

      # A real pathway in this version, claimed under a foreign organization, is a
      # mixed scope and cannot borrow the local pathway row.
      assert_raise Postgrex.Error, fn ->
        insert_closure(scope, organization_id: foreign_org, pathway_id: "PW_A")
      end
    end
  end

  # --- helpers -------------------------------------------------------------

  defp build_scope(pathway_ids \\ ~w(PW_A PW_B)) do
    schema = setup_prefix()
    org_id = insert_org(schema)
    version_id = insert_version(schema, org_id)

    for pathway_id <- pathway_ids do
      insert_pathway(schema, org_id, version_id, pathway_id)
    end

    %{schema: schema, org_id: org_id, version_id: version_id}
  end

  defp setup_prefix do
    schema = "test_pathway_evol_#{System.unique_integer([:positive])}"

    SQL.query!(Repo, ~s|CREATE SCHEMA "#{schema}"|, [])

    on_exit(fn ->
      SQL.query!(Repo, ~s|DROP SCHEMA IF EXISTS "#{schema}" CASCADE|, [])
    end)

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".organizations (
        id uuid PRIMARY KEY,
        name varchar(255) NOT NULL,
        inserted_at timestamp NOT NULL DEFAULT now(),
        updated_at timestamp NOT NULL DEFAULT now()
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".gtfs_versions (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        name varchar(255) NOT NULL DEFAULT 'First Version',
        inserted_at timestamp(6) NOT NULL,
        updated_at timestamp(6) NOT NULL
      )
      """,
      []
    )

    # Mirrors the scoped pathway uniqueness the composite reference requires.
    SQL.query!(
      Repo,
      """
      CREATE TABLE "#{schema}".pathways (
        id uuid PRIMARY KEY,
        organization_id uuid NOT NULL REFERENCES "#{schema}".organizations(id) ON DELETE CASCADE,
        gtfs_version_id uuid NOT NULL,
        pathway_id varchar(255) NOT NULL,
        pathway_mode integer NOT NULL DEFAULT 1,
        from_stop_id varchar(255) NOT NULL DEFAULT 'FROM',
        to_stop_id varchar(255) NOT NULL DEFAULT 'TO',
        inserted_at timestamp(6) NOT NULL DEFAULT now(),
        updated_at timestamp(6) NOT NULL DEFAULT now()
      )
      """,
      []
    )

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX "#{schema}_pathways_scope_index"
      ON "#{schema}".pathways (organization_id, gtfs_version_id, pathway_id)
      """,
      []
    )

    schema
  end

  defp insert_org(schema) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [dump(id), "Org #{System.unique_integer([:positive])}"]
    )

    id
  end

  defp insert_version(schema, org_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".gtfs_versions (id, organization_id, name, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $4)|,
      [dump(id), dump(org_id), "Version #{System.unique_integer([:positive])}", @now]
    )

    id
  end

  defp insert_pathway(schema, org_id, version_id, pathway_id) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{schema}".pathways (
        id, organization_id, gtfs_version_id, pathway_id, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $5)
      """,
      [dump(id), dump(org_id), dump(version_id), pathway_id, @now]
    )

    id
  end

  defp insert_closure(scope, opts) do
    organization_id = Keyword.get(opts, :organization_id, scope.org_id)
    gtfs_version_id = Keyword.get(opts, :gtfs_version_id, scope.version_id)
    pathway_id = Keyword.fetch!(opts, :pathway_id)
    service_id = Keyword.get(opts, :service_id, "SVC_DEFAULT")
    start_time = Keyword.get(opts, :start_time, @overnight_start)
    end_time = Keyword.get(opts, :end_time, @overnight_end)
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{scope.schema}".pathway_evolutions (
        id, organization_id, gtfs_version_id, pathway_id, service_id,
        start_time, end_time, note, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9)
      """,
      [
        dump(id),
        dump(organization_id),
        dump(gtfs_version_id),
        pathway_id,
        service_id,
        start_time,
        end_time,
        Keyword.get(opts, :note),
        @now
      ]
    )
  end

  defp fetch_pathways(schema) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT organization_id, gtfs_version_id, pathway_id FROM "#{schema}".pathways ORDER BY pathway_id|,
        []
      )

    rows
  end

  defp assert_surrounding_tables(schema) do
    for table <- ~w(organizations gtfs_versions pathways) do
      assert table_exists?(schema, table), "expected #{table} to survive the migration down"
    end
  end

  defp migrate_up(schema),
    do: Ecto.Migrator.up(Repo, @migration_version, Migration, prefix: schema, log: false)

  defp migrate_down(schema),
    do: Ecto.Migrator.down(Repo, @migration_version, Migration, prefix: schema, log: false)

  defp table_exists?(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = $1 AND table_name = $2
        """,
        [schema, table]
      )

    rows != []
  end

  defp index_names(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = $2
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp constraint_names(schema, table) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT con.conname FROM pg_constraint con
        JOIN pg_namespace ns ON ns.oid = con.connamespace
        JOIN pg_class cls ON cls.oid = con.conrelid
        WHERE ns.nspname = $1 AND cls.relname = $2
        """,
        [schema, table]
      )

    List.flatten(rows)
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end

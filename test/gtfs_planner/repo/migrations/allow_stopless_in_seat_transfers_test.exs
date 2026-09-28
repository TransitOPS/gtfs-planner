defmodule GtfsPlanner.Repo.Migrations.AllowStoplessInSeatTransfersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias GtfsPlanner.Repo

  @create_migration_glob "../../../../priv/repo/migrations/*_create_transfers.exs"

  @create_migration_path @create_migration_glob
                         |> Path.expand(__DIR__)
                         |> Path.wildcard()
                         |> List.first()

  @create_migration_version @create_migration_path
                            |> Path.basename()
                            |> String.split("_", parts: 2)
                            |> hd()
                            |> String.to_integer()

  Code.require_file(@create_migration_path)

  alias GtfsPlanner.Repo.Migrations.CreateTransfers, as: CreateMigration

  @migration_glob "../../../../priv/repo/migrations/*_allow_stopless_in_seat_transfers.exs"

  @migration_path @migration_glob
                  |> Path.expand(__DIR__)
                  |> Path.wildcard()
                  |> List.first()

  @migration_version @migration_path
                     |> Path.basename()
                     |> String.split("_", parts: 2)
                     |> hd()
                     |> String.to_integer()

  Code.require_file(@migration_path)

  alias GtfsPlanner.Repo.Migrations.AllowStoplessInSeatTransfers, as: Migration

  @index "transfers_org_id_version_id_from_to_stop_route_trip_index"
  @stops_check "transfers_stops_required_unless_in_seat"
  @trips_check "transfers_in_seat_trips_required"

  @stops_check_definition "CHECK (((transfer_type = ANY (ARRAY[4, 5])) OR " <>
                            "((from_stop_id IS NOT NULL) AND (to_stop_id IS NOT NULL))))"

  @trips_check_definition "CHECK (((transfer_type <> ALL (ARRAY[4, 5])) OR " <>
                            "((from_trip_id IS NOT NULL) AND (to_trip_id IS NOT NULL))))"

  @key_column_names [
    "organization_id",
    "gtfs_version_id",
    "from_stop_id",
    "to_stop_id",
    "from_route_id",
    "to_route_id",
    "from_trip_id",
    "to_trip_id"
  ]

  @refusal_prefix "Cannot apply allow_stopless_in_seat_transfers: "
  @inserted_at ~U[2026-01-01 00:00:00.000000Z]

  setup_all do
    Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)
    :ok
  end

  setup do
    schema = create_schema()
    organization_id = insert_organization(schema)

    Migrator.up(Repo, @create_migration_version, CreateMigration, prefix: schema, log: false)

    %{schema: schema, organization_id: organization_id, version_id: Ecto.UUID.generate()}
  end

  describe "up" do
    test "removes exact duplicates, keeps the earliest row, and leaves distinct rows", context do
      other_version_id = Ecto.UUID.generate()

      kept_id = insert_transfer!(context, inserted_at: ~U[2026-01-01 00:00:00.000000Z])
      later_duplicate_id = insert_transfer!(context, inserted_at: ~U[2026-01-02 00:00:00.000000Z])

      last_duplicate_id = insert_transfer!(context, inserted_at: ~U[2026-01-03 00:00:00.000000Z])

      # Differs from the duplicates in one key column only.
      route_row_id = insert_transfer!(context, from_route_id: "R1")

      # Differs in transfer_type and min_transfer_time, in another key group.
      min_time_row_id =
        insert_transfer!(
          context,
          from_stop_id: "S5",
          to_stop_id: "S6",
          transfer_type: 2,
          min_transfer_time: 120
        )

      # Identical rows in another version form their own key group and collapse
      # to one row there.
      other_version_id_1 = insert_transfer!(context, gtfs_version_id: other_version_id)
      other_version_id_2 = insert_transfer!(context, gtfs_version_id: other_version_id)

      log = capture_log(fn -> migrate_up!(context) end)

      # This version keeps one row per key group: the earliest duplicate row, the
      # row differing in from_route_id and the row differing in type and min time.
      assert transfer_ids(context) == Enum.sort([kept_id, route_row_id, min_time_row_id])

      # The other version holds the same key group, so exactly one of its two
      # identical rows survives; both share inserted_at, so (inserted_at, id)
      # legitimately picks either.
      assert [surviving_other_version_id] = transfer_ids(context, version_id: other_version_id)
      assert surviving_other_version_id in [other_version_id_1, other_version_id_2]

      assert log =~
               "Removed duplicate transfer id=#{later_duplicate_id} " <>
                 "organization_id=#{context.organization_id} " <>
                 "gtfs_version_id=#{context.version_id}"

      assert log =~
               "Removed duplicate transfer id=#{last_duplicate_id} " <>
                 "organization_id=#{context.organization_id} " <>
                 "gtfs_version_id=#{context.version_id}"

      refute log =~ "Removed duplicate transfer id=#{kept_id}"
      refute log =~ "Removed duplicate transfer id=#{route_row_id}"

      removed_other_version_ids =
        Enum.filter([other_version_id_1, other_version_id_2], fn id ->
          log =~ "Removed duplicate transfer id=#{id}"
        end)

      assert length(removed_other_version_ids) == 1
    end

    test "recreates the unique index with NULLS NOT DISTINCT and relaxes only the stop columns",
         context do
      original_definition = index_definition(context)
      refute original_definition =~ "NULLS NOT DISTINCT"

      migrate_up!(context)

      definition = index_definition(context)

      assert definition =~ "CREATE UNIQUE INDEX #{@index} ON #{context.schema}.transfers"
      assert definition =~ "NULLS NOT DISTINCT"
      assert index_column_names(definition) == @key_column_names

      assert nullability(context, "from_stop_id") == "YES"
      assert nullability(context, "to_stop_id") == "YES"
      assert nullability(context, "transfer_type") == "NO"
      assert nullability(context, "id") == "NO"

      assert check_constraints(context) == [
               {@trips_check, @trips_check_definition},
               {@stops_check, @stops_check_definition}
             ]

      assert migrated_versions(context) == [@create_migration_version, @migration_version]
    end

    test "stores one stopless in-seat key per version, empty equal to empty", context do
      migrate_up!(context)

      other_version_id = Ecto.UUID.generate()
      stopless = [transfer_type: 4, from_stop_id: nil, to_stop_id: nil]
      trips = Keyword.merge(stopless, from_trip_id: "T1", to_trip_id: "T2")

      insert_transfer!(context, trips)

      error = assert_raise(Postgrex.Error, fn -> insert_transfer!(context, trips) end)

      assert error.postgres.code == :unique_violation
      assert error.postgres.constraint == @index

      # Empty equals empty, so a key that adds a route does not collide.
      insert_transfer!(context, Keyword.put(trips, :from_route_id, "R1"))

      # Another version holds the same key without conflict.
      insert_transfer!(context, Keyword.put(trips, :gtfs_version_id, other_version_id))

      assert length(transfer_ids(context)) == 2
      assert length(transfer_ids(context, version_id: other_version_id)) == 1
    end

    test "requires stops for types 0-3 and both trips for types 4-5", context do
      migrate_up!(context)

      # A stop-scoped row with no trip ids stays valid.
      insert_transfer!(context, transfer_type: 0, from_stop_id: "S1", to_stop_id: "S2")

      stops_error =
        assert_raise(Postgrex.Error, fn ->
          insert_transfer!(context,
            transfer_type: 2,
            from_stop_id: nil,
            to_stop_id: "S3",
            min_transfer_time: 120
          )
        end)

      assert stops_error.postgres.code == :check_violation
      assert stops_error.postgres.constraint == @stops_check

      trips_error =
        assert_raise(Postgrex.Error, fn ->
          insert_transfer!(context,
            transfer_type: 5,
            from_stop_id: "S4",
            to_stop_id: "S5",
            from_trip_id: "T1"
          )
        end)

      assert trips_error.postgres.code == :check_violation
      assert trips_error.postgres.constraint == @trips_check

      # Types 4 and 5 with both trips and no stops are the newly accepted shape.
      insert_transfer!(context,
        transfer_type: 4,
        from_stop_id: nil,
        to_stop_id: nil,
        from_trip_id: "T1",
        to_trip_id: "T2"
      )

      insert_transfer!(context,
        transfer_type: 5,
        from_stop_id: nil,
        to_stop_id: nil,
        from_trip_id: "T3",
        to_trip_id: "T4"
      )

      assert length(transfer_ids(context)) == 3
    end

    test "refuses conflicting key groups and leaves every row and definition unchanged",
         context do
      # This pair shares transfer_type and differs only in min_transfer_time, so
      # dropping min_transfer_time from the dedupe partition would collapse it.
      conflicting_min_time_nil_id = insert_transfer!(context, transfer_type: 0)

      conflicting_min_time_120_id =
        insert_transfer!(context, transfer_type: 0, min_transfer_time: 120)

      # A second key group sharing min_transfer_time and differing only in
      # transfer_type, so dropping transfer_type from the partition collapses it.
      conflicting_type_0_id =
        insert_transfer!(context,
          from_stop_id: "S7",
          to_stop_id: "S8",
          transfer_type: 0,
          min_transfer_time: 120
        )

      conflicting_type_2_id =
        insert_transfer!(context,
          from_stop_id: "S7",
          to_stop_id: "S8",
          transfer_type: 2,
          min_transfer_time: 120
        )

      duplicate_id_1 = insert_transfer!(context, from_stop_id: "S5", to_stop_id: "S6")
      duplicate_id_2 = insert_transfer!(context, from_stop_id: "S5", to_stop_id: "S6")

      original_definition = index_definition(context)
      original_versions = migrated_versions(context)

      {error, log} =
        with_log(fn -> assert_raise(RuntimeError, fn -> migrate_up!(context) end) end)

      assert error.message =~
               @refusal_prefix <>
                 "2 transfer key groups hold rows that differ in transfer_type or " <>
                 "min_transfer_time, and 0 type 4 or 5 transfers lack from_trip_id or " <>
                 "to_trip_id. Nothing was changed. Resolve these rows and rerun."

      assert error.message =~
               ~s(conflicting key group: organization_id=#{context.organization_id} ) <>
                 ~s(gtfs_version_id=#{context.version_id} from_stop_id="S1" to_stop_id="S2" ) <>
                 "from_route_id=nil to_route_id=nil from_trip_id=nil to_trip_id=nil"

      assert error.message =~
               ~s(conflicting key group: organization_id=#{context.organization_id} ) <>
                 ~s(gtfs_version_id=#{context.version_id} from_stop_id="S7" to_stop_id="S8" ) <>
                 "from_route_id=nil to_route_id=nil from_trip_id=nil to_trip_id=nil"

      # A refused run logs no removal for the exact duplicate pair its rollback keeps.
      refute log =~ "Removed duplicate transfer"

      # The refused migration deleted nothing, not even the exact duplicate pair.
      assert transfer_ids(context) ==
               Enum.sort([
                 conflicting_min_time_nil_id,
                 conflicting_min_time_120_id,
                 conflicting_type_0_id,
                 conflicting_type_2_id,
                 duplicate_id_1,
                 duplicate_id_2
               ])

      assert index_definition(context) == original_definition
      refute index_definition(context) =~ "NULLS NOT DISTINCT"
      assert nullability(context, "from_stop_id") == "NO"
      assert nullability(context, "to_stop_id") == "NO"
      assert check_constraints(context) == []
      assert migrated_versions(context) == original_versions
    end

    test "refuses a type 4 row without a trip id and leaves every row and definition unchanged",
         context do
      row_id =
        insert_transfer!(context,
          transfer_type: 4,
          from_stop_id: "S1",
          to_stop_id: "S2",
          from_trip_id: "T1"
        )

      original_definition = index_definition(context)
      original_versions = migrated_versions(context)

      error = assert_raise(RuntimeError, fn -> migrate_up!(context) end)

      assert error.message =~
               @refusal_prefix <>
                 "0 transfer key groups hold rows that differ in transfer_type or " <>
                 "min_transfer_time, and 1 type 4 or 5 transfers lack from_trip_id or " <>
                 "to_trip_id. Nothing was changed. Resolve these rows and rerun."

      assert error.message =~
               "type 4 transfer without a trip id: id=#{row_id} " <>
                 "organization_id=#{context.organization_id} " <>
                 "gtfs_version_id=#{context.version_id}"

      assert transfer_ids(context) == [row_id]
      assert index_definition(context) == original_definition
      assert nullability(context, "from_stop_id") == "NO"
      assert check_constraints(context) == []
      assert migrated_versions(context) == original_versions
    end
  end

  describe "down" do
    test "restores NOT NULL stops, the NULLS DISTINCT index and drops the checks", context do
      insert_transfer!(context,
        transfer_type: 4,
        from_stop_id: "S1",
        to_stop_id: "S2",
        from_trip_id: "T1",
        to_trip_id: "T2"
      )

      original_definition = index_definition(context)

      migrate_up!(context)

      Migrator.down(Repo, @migration_version, Migration, prefix: context.schema, log: false)

      assert index_definition(context) == original_definition
      assert index_column_names(index_definition(context)) == @key_column_names
      refute index_definition(context) =~ "NULLS NOT DISTINCT"

      assert nullability(context, "from_stop_id") == "NO"
      assert nullability(context, "to_stop_id") == "NO"
      assert check_constraints(context) == []
      assert migrated_versions(context) == [@create_migration_version]

      # NULLS DISTINCT again: two rows sharing every key column are storable.
      insert_transfer!(context, from_stop_id: "S7", to_stop_id: "S8")
      insert_transfer!(context, from_stop_id: "S7", to_stop_id: "S8")

      assert length(transfer_ids(context)) == 3
    end

    test "refuses to roll back while a stopless transfer exists and changes nothing", context do
      migrate_up!(context)

      row_id =
        insert_transfer!(context,
          transfer_type: 4,
          from_stop_id: nil,
          to_stop_id: nil,
          from_trip_id: "T1",
          to_trip_id: "T2"
        )

      definition = index_definition(context)
      checks = check_constraints(context)
      versions = migrated_versions(context)

      error =
        assert_raise(RuntimeError, fn ->
          Migrator.down(Repo, @migration_version, Migration, prefix: context.schema, log: false)
        end)

      assert error.message ==
               "Cannot roll back allow_stopless_in_seat_transfers: 1 transfers have no " <>
                 "from_stop_id or to_stop_id. Keep this migration and fix forward."

      assert transfer_ids(context) == [row_id]
      assert index_definition(context) == definition
      assert nullability(context, "from_stop_id") == "YES"
      assert check_constraints(context) == checks
      assert migrated_versions(context) == versions
    end
  end

  defp migrate_up!(context) do
    Migrator.up(Repo, @migration_version, Migration, prefix: context.schema, log: false)
  end

  defp create_schema do
    schema = "test_stopless_in_seat_#{System.unique_integer([:positive])}"
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

    schema
  end

  defp insert_organization(schema) do
    id = Ecto.UUID.generate()

    SQL.query!(
      Repo,
      ~s|INSERT INTO "#{schema}".organizations (id, name) VALUES ($1, $2)|,
      [dump(id), "Test"]
    )

    id
  end

  # Seeds through raw SQL because the migrations under test are the only writers.
  defp insert_transfer!(context, attrs) do
    id = Keyword.get(attrs, :id, Ecto.UUID.generate())

    SQL.query!(
      Repo,
      """
      INSERT INTO "#{context.schema}".transfers (
        id, organization_id, gtfs_version_id, from_stop_id, to_stop_id, from_route_id,
        to_route_id, from_trip_id, to_trip_id, transfer_type, min_transfer_time,
        inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12)
      """,
      [
        dump(id),
        dump(context.organization_id),
        dump(Keyword.get(attrs, :gtfs_version_id, context.version_id)),
        Keyword.get(attrs, :from_stop_id, "S1"),
        Keyword.get(attrs, :to_stop_id, "S2"),
        Keyword.get(attrs, :from_route_id),
        Keyword.get(attrs, :to_route_id),
        Keyword.get(attrs, :from_trip_id),
        Keyword.get(attrs, :to_trip_id),
        Keyword.get(attrs, :transfer_type, 0),
        Keyword.get(attrs, :min_transfer_time),
        Keyword.get(attrs, :inserted_at, @inserted_at)
      ]
    )

    id
  end

  defp transfer_ids(context, opts \\ []) do
    version_id = Keyword.get(opts, :version_id, context.version_id)

    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT id::text FROM "#{context.schema}".transfers
        WHERE organization_id = $1 AND gtfs_version_id = $2
        ORDER BY id
        """,
        [dump(context.organization_id), dump(version_id)]
      )

    List.flatten(rows)
  end

  defp index_definition(context) do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT indexdef FROM pg_indexes WHERE schemaname = $1 AND indexname = $2",
        [context.schema, @index]
      )

    definition
  end

  defp index_column_names(index_definition) do
    [columns] = Regex.run(~r/\(([^)]+)\)/, index_definition, capture: :all_but_first)
    String.split(columns, ", ")
  end

  defp nullability(context, column) do
    %{rows: [[nullable]]} =
      SQL.query!(
        Repo,
        """
        SELECT is_nullable FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = 'transfers' AND column_name = $2
        """,
        [context.schema, column]
      )

    nullable
  end

  defp check_constraints(context) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT con.conname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1 AND rel.relname = 'transfers' AND con.contype = 'c'
        ORDER BY con.conname
        """,
        [context.schema]
      )

    Enum.map(rows, fn [name, definition] -> {name, definition} end)
  end

  defp migrated_versions(context) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        ~s|SELECT version FROM "#{context.schema}".schema_migrations ORDER BY version|,
        []
      )

    List.flatten(rows)
  end

  defp dump(uuid), do: Ecto.UUID.dump!(uuid)
end

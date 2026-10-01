defmodule GtfsPlanner.Repo.Migrations.ValidateRunsOwnershipConstraints do
  use Ecto.Migration

  @constraints [
    {"trip_runs_version_owner_fkey", "gtfs_versions", ~w(gtfs_version_id organization_id),
     ~w(id organization_id)},
    {"trip_runs_trips_owner_fkey", "trips", ~w(trip_id organization_id gtfs_version_id),
     ~w(id organization_id gtfs_version_id)}
  ]

  def up, do: validate_all!(repo(), prefix())

  def down, do: :ok

  def validate_all!(repo, schema \\ nil) do
    schema = schema || repo.query!("SELECT current_schema()", []).rows |> hd() |> hd()
    names = Enum.map(@constraints, &elem(&1, 0))

    %{rows: rows} =
      repo.query!(
        """
        SELECT c.conname, child.relname, parent.relname, parent_ns.nspname,
               c.contype, c.convalidated, c.confdeltype,
               ARRAY(
                 SELECT a.attname::text
                 FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, position)
                 JOIN pg_attribute AS a ON a.attrelid = child.oid AND a.attnum = k.attnum
                 ORDER BY k.position
               ),
               ARRAY(
                 SELECT a.attname::text
                 FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, position)
                 JOIN pg_attribute AS a ON a.attrelid = parent.oid AND a.attnum = k.attnum
                 ORDER BY k.position
               )
        FROM pg_constraint AS c
        JOIN pg_class AS child ON child.oid = c.conrelid
        JOIN pg_namespace AS child_ns ON child_ns.oid = child.relnamespace
        JOIN pg_class AS parent ON parent.oid = c.confrelid
        JOIN pg_namespace AS parent_ns ON parent_ns.oid = parent.relnamespace
        WHERE child_ns.nspname = $1 AND child.relname = 'trip_runs'
          AND c.conname = ANY($2::text[])
        """,
        [schema, names]
      )

    # Check both definitions before validating either one.
    states =
      Enum.map(@constraints, fn {name, parent, child_columns, parent_columns} ->
        case Enum.filter(rows, &(hd(&1) == name)) do
          [
            [
              ^name,
              "trip_runs",
              ^parent,
              ^schema,
              "f",
              validated?,
              "a",
              ^child_columns,
              ^parent_columns
            ]
          ]
          when is_boolean(validated?) ->
            {name, validated?}

          _ ->
            raise "Ownership constraint #{name} is missing or has the wrong key in #{schema}.trip_runs; " <>
                    "run mix gtfs.audit_ownership before migrating. No rows were changed."
        end
      end)

    for {name, false} <- states do
      validate_constraint!(repo, schema, name)
    end

    :ok
  end

  defp validate_constraint!(repo, schema, name) do
    repo.query!(
      "ALTER TABLE #{quote_identifier(schema)}.trip_runs VALIDATE CONSTRAINT #{name}",
      []
    )
  rescue
    error in Postgrex.Error ->
      if error.postgres.code == :foreign_key_violation do
        raise "Ownership constraint #{name} has rows that violate it. No rows were changed. " <>
                "Run mix gtfs.audit_ownership (or " <>
                "bin/gtfs_planner eval 'case GtfsPlanner.Release.audit_ownership() do " <>
                ":ok -> :ok; {:error, _count} -> System.halt(1) end') and resolve " <>
                "the reported rows before migrating."
      else
        reraise error, __STACKTRACE__
      end
  end

  defp quote_identifier(value), do: ~s("#{String.replace(value, "\"", "\"\"")}")
end

defmodule GtfsPlanner.Repo.Migrations.ValidateUpstreamOwnershipConstraints do
  use Ecto.Migration

  @version_owner_tables ~w(block_attributes route_operating_settings deadhead_times relief_points)

  @organization_parent_links [
    {"block_attributes", "garage_id"},
    {"block_attributes", "vehicle_type_id"},
    {"route_operating_settings", "garage_id"},
    {"route_operating_settings", "required_vehicle_type_id"},
    {"blocking_settings", "default_garage_id"},
    {"vehicles", "garage_id"},
    {"vehicles", "vehicle_type_id"}
  ]

  @constraints Enum.map(@version_owner_tables, &{"#{&1}_version_owner_fkey", &1}) ++
                 Enum.map(@organization_parent_links, fn {child, column} ->
                   {"#{child}_#{column}_owner_fkey", child}
                 end)

  def up, do: validate_all!(repo(), prefix())

  def down, do: :ok

  def validate_all!(repo, schema \\ nil) do
    schema = schema || repo.query!("SELECT current_schema()", []).rows |> hd() |> hd()
    names = Enum.map(@constraints, &elem(&1, 0))

    %{rows: rows} =
      repo.query!(
        """
        SELECT c.conname, child.relname, c.convalidated
        FROM pg_constraint AS c
        JOIN pg_class AS child ON child.oid = c.conrelid
        JOIN pg_namespace AS ns ON ns.oid = child.relnamespace
        WHERE ns.nspname = $1 AND c.contype = 'f' AND c.conname = ANY($2::text[])
        """,
        [schema, names]
      )

    constraints = Map.new(rows, fn [name, table, validated?] -> {name, {table, validated?}} end)

    for {name, table} <- @constraints do
      case Map.get(constraints, name) do
        {^table, validated?} when is_boolean(validated?) ->
          :ok

        _ ->
          raise "Ownership constraint #{name} is missing from #{schema}.#{table}; " <>
                  "run mix gtfs.audit_ownership before migrating. No rows were changed."
      end
    end

    for {name, table} <- @constraints do
      case Map.fetch!(constraints, name) do
        {^table, false} -> validate_constraint!(repo, schema, table, name)
        {^table, true} -> :ok
      end
    end

    :ok
  end

  defp validate_constraint!(repo, schema, table, name) do
    repo.query!(
      "ALTER TABLE #{quote_identifier(schema)}.#{table} VALIDATE CONSTRAINT #{name}",
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

defmodule GtfsPlanner.Repo.Migrations.ValidateOwnershipConstraints do
  use Ecto.Migration

  # Keep the step 8 constraint set fixed in this migration. A later audit-catalog
  # change must not alter what an existing installation validates.
  @version_owner_tables ~w(
    agencies alignment_segments areas attributions blocking_settings booking_rules
    calendar_attributes calendar_dates calendars change_logs fare_attributes
    fare_leg_join_rules fare_leg_rules fare_media fare_products fare_rules
    fare_transfer_rules fare_zones feed_info flex_areas flex_services frequencies
    gtfs_validation_runs journal_entries levels locations networks pathway_evolutions
    pathways rider_categories route_networks route_pattern_stops route_patterns routes
    shapes station_editing_statuses stop_areas stop_levels stop_times stops
    timed_patterns timeframes transfers translations trips walkability_tests
  )

  @containment [
    {"stop_levels", "stops"},
    {"stop_levels", "levels"},
    {"route_pattern_stops", "route_patterns"},
    {"timed_patterns", "route_patterns"},
    {"trips", "timed_patterns"},
    {"alignment_segments", "route_pattern_stops"},
    {"flex_areas", "flex_services"},
    {"journal_entries", "stops"},
    {"station_editing_statuses", "stops"}
  ]

  @constraints Enum.map(@version_owner_tables, &{"#{&1}_version_owner_fkey", &1}) ++
                 Enum.map(@containment, fn {child, parent} ->
                   {"#{child}_#{parent}_owner_fkey", child}
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

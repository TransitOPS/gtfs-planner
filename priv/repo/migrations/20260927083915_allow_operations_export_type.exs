defmodule GtfsPlanner.Repo.Migrations.AllowOperationsExportType do
  use Ecto.Migration

  @state_check "gtfs_export_runs_state_check"

  # The widened expression is the contract later export-type migrations must keep
  # (a crew export migration re-creates this same constraint).
  @gated_export_types "['full','pathways']"
  @open_export_types "['full','pathways','operations']"

  # Shared text keeps the state and phase clauses byte-for-byte identical to the
  # expression in 20260721062803_create_gtfs_export_runs.exs.
  @state_clause "state = ANY(ARRAY['pending','building','ready','failed','interrupted','cancelled','expired']::text[])"
  @phase_clause "phase IS NULL OR phase = ANY(ARRAY['preflight','packaging','publishing','cleanup']::text[])"

  def up do
    replace_state_check(@open_export_types)
  end

  def down do
    case operations_run_count() do
      0 -> replace_state_check(@gated_export_types)
      count -> raise rollback_refused(count)
    end
  end

  defp replace_state_check(export_types) do
    drop constraint(:gtfs_export_runs, @state_check)
    create constraint(:gtfs_export_runs, @state_check, check: state_check(export_types))
  end

  defp state_check(export_types) do
    "export_type = ANY(ARRAY#{export_types}::text[]) AND #{@state_clause} AND (#{@phase_clause})"
  end

  defp operations_run_count do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        GtfsPlanner.Repo,
        "SELECT COUNT(*) FROM #{qualified_table()} WHERE export_type = 'operations'",
        []
      )

    count
  end

  defp rollback_refused(count) do
    "Cannot roll back allow_operations_export_type: #{count} export runs use export_type " <>
      "'operations'. Keep this migration and fix forward."
  end

  # Raw `execute/1` statements are not prefix-aware, so qualify the table with
  # the migration prefix when one is set (e.g. isolated-schema tests).
  defp qualified_table do
    case prefix() do
      nil -> "gtfs_export_runs"
      schema -> ~s("#{schema}".gtfs_export_runs)
    end
  end
end

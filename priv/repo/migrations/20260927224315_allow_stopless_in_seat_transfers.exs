defmodule GtfsPlanner.Repo.Migrations.AllowStoplessInSeatTransfers do
  use Ecto.Migration

  require Logger

  @index :transfers_org_id_version_id_from_to_stop_route_trip_index

  # The GTFS transfers.txt primary key. Empty equals empty: the index is recreated
  # with NULLS NOT DISTINCT so two rows sharing every key column, stop- or
  # trip-scoped, cannot both be stored.
  @key_columns [
    :organization_id,
    :gtfs_version_id,
    :from_stop_id,
    :to_stop_id,
    :from_route_id,
    :to_route_id,
    :from_trip_id,
    :to_trip_id
  ]

  @key_columns_sql "organization_id, gtfs_version_id, from_stop_id, to_stop_id, " <>
                     "from_route_id, to_route_id, from_trip_id, to_trip_id"

  # Two rows identical in the key columns, transfer_type and min_transfer_time
  # carry no information the kept row lacks, so they are the only rows removed.
  @duplicate_columns_sql @key_columns_sql <> ", transfer_type, min_transfer_time"

  @stops_check "transfers_stops_required_unless_in_seat"
  @trips_check "transfers_in_seat_trips_required"

  @stops_check_expression "transfer_type IN (4, 5) OR " <>
                            "(from_stop_id IS NOT NULL AND to_stop_id IS NOT NULL)"

  @trips_check_expression "transfer_type NOT IN (4, 5) OR " <>
                            "(from_trip_id IS NOT NULL AND to_trip_id IS NOT NULL)"

  @sample_limit 20

  def up do
    lock_transfers_table!()

    removed_duplicates = remove_exact_duplicates()
    refuse_unrepairable_rows()
    log_removed_duplicates(removed_duplicates)

    drop index(:transfers, [], name: @index)
    create unique_index(:transfers, @key_columns, name: @index, nulls_distinct: false)

    alter table(:transfers) do
      modify :from_stop_id, :string, null: true, from: {:string, null: false}
      modify :to_stop_id, :string, null: true, from: {:string, null: false}
    end

    create constraint(:transfers, @stops_check, check: @stops_check_expression)
    create constraint(:transfers, @trips_check, check: @trips_check_expression)
  end

  def down do
    lock_transfers_table!()

    case stopless_transfer_count() do
      0 ->
        drop constraint(:transfers, @stops_check)
        drop constraint(:transfers, @trips_check)

        alter table(:transfers) do
          modify :from_stop_id, :string, null: false, from: {:string, null: true}
          modify :to_stop_id, :string, null: false, from: {:string, null: true}
        end

        drop index(:transfers, [], name: @index)
        create unique_index(:transfers, @key_columns, name: @index)

      count ->
        raise "Cannot roll back allow_stopless_in_seat_transfers: #{count} transfers have no " <>
                "from_stop_id or to_stop_id. Keep this migration and fix forward."
    end
  end

  # The lock is issued through the repo rather than execute/1: the runner queues
  # every command for the flush after the operation returns, so a queued LOCK
  # would arrive with the DDL and leave the checks below unguarded.
  defp lock_transfers_table! do
    repo().query!("LOCK TABLE #{qualified_table()} IN ACCESS EXCLUSIVE MODE")
  end

  defp remove_exact_duplicates do
    %{rows: removed} =
      repo().query!(
        """
        WITH ranked AS (
          SELECT id,
                 ROW_NUMBER() OVER (
                   PARTITION BY #{@duplicate_columns_sql}
                   ORDER BY inserted_at, id
                 ) AS rank
          FROM #{qualified_table()}
        )
        DELETE FROM #{qualified_table()} AS duplicate
        USING ranked
        WHERE duplicate.id = ranked.id AND ranked.rank > 1
        RETURNING duplicate.id::text, duplicate.organization_id::text,
                  duplicate.gtfs_version_id::text
        """,
        []
      )

    removed
  end

  # Emitted only after refuse_unrepairable_rows/0 has passed, so a refused or
  # aborted run logs no removal lines for the deletions its rollback discards.
  defp log_removed_duplicates(removed) do
    Enum.each(removed, fn [id, organization_id, gtfs_version_id] ->
      Logger.warning(
        "Removed duplicate transfer id=#{id} organization_id=#{organization_id} " <>
          "gtfs_version_id=#{gtfs_version_id}"
      )
    end)
  end

  defp refuse_unrepairable_rows do
    group_count = conflicting_key_group_count()
    stopless_count = stopless_in_seat_transfer_count()

    if group_count > 0 or stopless_count > 0 do
      raise refusal_message(group_count, stopless_count)
    end
  end

  defp refusal_message(group_count, stopless_count) do
    samples =
      conflicting_key_group_samples(group_count) ++ stopless_in_seat_samples(stopless_count)

    "Cannot apply allow_stopless_in_seat_transfers: #{group_count} transfer key groups hold " <>
      "rows that differ in transfer_type or min_transfer_time, and #{stopless_count} type 4 or 5 " <>
      "transfers lack from_trip_id or to_trip_id. Nothing was changed. Resolve these rows and " <>
      "rerun.\n" <> Enum.join(samples, "\n")
  end

  # Counts and samples are read before any queued DDL runs, so the refusal leaves
  # the index, the columns and every row exactly as they were.
  defp conflicting_key_group_count do
    %{rows: [[count]]} =
      repo().query!(
        """
        SELECT COUNT(*) FROM (
          SELECT 1 FROM #{qualified_table()}
          GROUP BY #{@key_columns_sql}
          HAVING COUNT(*) > 1
        ) AS conflicting_key_groups
        """,
        []
      )

    count
  end

  defp conflicting_key_group_samples(0), do: []

  defp conflicting_key_group_samples(_count) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT organization_id::text, gtfs_version_id::text, from_stop_id, to_stop_id,
               from_route_id, to_route_id, from_trip_id, to_trip_id
        FROM #{qualified_table()}
        GROUP BY #{@key_columns_sql}
        HAVING COUNT(*) > 1
        ORDER BY 1, 2, 3, 4, 5, 6, 7, 8
        LIMIT #{@sample_limit}
        """,
        []
      )

    Enum.map(rows, fn [organization_id, gtfs_version_id | key_values] ->
      "  conflicting key group: organization_id=#{organization_id} " <>
        "gtfs_version_id=#{gtfs_version_id} " <> sample_key_values(key_values)
    end)
  end

  defp stopless_in_seat_transfer_count do
    %{rows: [[count]]} =
      repo().query!(
        """
        SELECT COUNT(*) FROM #{qualified_table()}
        WHERE transfer_type IN (4, 5) AND (from_trip_id IS NULL OR to_trip_id IS NULL)
        """,
        []
      )

    count
  end

  defp stopless_in_seat_samples(0), do: []

  defp stopless_in_seat_samples(_count) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id::text, organization_id::text, gtfs_version_id::text, transfer_type
        FROM #{qualified_table()}
        WHERE transfer_type IN (4, 5) AND (from_trip_id IS NULL OR to_trip_id IS NULL)
        ORDER BY 1
        LIMIT #{@sample_limit}
        """,
        []
      )

    Enum.map(rows, fn [id, organization_id, gtfs_version_id, transfer_type] ->
      "  type #{transfer_type} transfer without a trip id: id=#{id} " <>
        "organization_id=#{organization_id} gtfs_version_id=#{gtfs_version_id}"
    end)
  end

  defp sample_key_values([
         from_stop_id,
         to_stop_id,
         from_route_id,
         to_route_id,
         from_trip_id,
         to_trip_id
       ]) do
    "from_stop_id=#{inspect(from_stop_id)} to_stop_id=#{inspect(to_stop_id)} " <>
      "from_route_id=#{inspect(from_route_id)} to_route_id=#{inspect(to_route_id)} " <>
      "from_trip_id=#{inspect(from_trip_id)} to_trip_id=#{inspect(to_trip_id)}"
  end

  defp stopless_transfer_count do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM #{qualified_table()} WHERE from_stop_id IS NULL OR to_stop_id IS NULL",
        []
      )

    count
  end

  # Raw SQL is not prefix-aware, so qualify the table with the migration prefix
  # when one is set (for example the disposable-schema migration test).
  defp qualified_table do
    case prefix() do
      nil -> "transfers"
      schema -> ~s("#{schema}".transfers)
    end
  end
end

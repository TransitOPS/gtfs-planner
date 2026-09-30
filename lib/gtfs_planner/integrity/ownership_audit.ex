defmodule GtfsPlanner.Integrity.OwnershipAudit do
  @moduledoc """
  Reports live GTFS ownership mismatches without changing stored rows.

  A cleaned import run is a historical receipt: its target version may have
  been deleted during cleanup. Other import runs still require a matching
  version owned by their organization.
  """

  alias GtfsPlanner.Repo

  @version_owner_tables ~w(
    agencies alignment_segments areas attributions blocking_settings booking_rules
    calendar_attributes calendar_dates calendars change_logs fare_attributes
    fare_leg_join_rules fare_leg_rules fare_media fare_products fare_rules
    fare_transfer_rules fare_zones feed_info flex_areas flex_services frequencies
    gtfs_change_runs gtfs_export_runs gtfs_validation_runs journal_entries levels
    locations networks pathway_evolutions pathways rider_categories route_networks
    route_pattern_stops route_patterns routes shapes station_editing_statuses
    stop_areas stop_levels stop_times stops timed_patterns timeframes transfers
    translations trips walkability_tests
  )

  @containment [
    {"stop_levels→stops", "stop_levels", "stop_id", "stops"},
    {"stop_levels→levels", "stop_levels", "level_id", "levels"},
    {"route_pattern_stops→route_patterns", "route_pattern_stops", "route_pattern_id",
     "route_patterns"},
    {"timed_patterns→route_patterns", "timed_patterns", "route_pattern_id", "route_patterns"},
    {"trips.timed_pattern_id→timed_patterns", "trips", "timed_pattern_id", "timed_patterns"},
    {"alignment_segments.from_occurrence_id→route_pattern_stops", "alignment_segments",
     "from_occurrence_id", "route_pattern_stops"},
    {"flex_areas→flex_services", "flex_areas", "flex_service_id", "flex_services"},
    {"journal_entries.station_id→stops", "journal_entries", "station_id", "stops"},
    {"station_editing_statuses.station_id→stops", "station_editing_statuses", "station_id",
     "stops"}
  ]

  @doc "Lists the tables whose rows must belong to their named GTFS version."
  def version_owner_tables, do: @version_owner_tables

  @doc """
  Counts each ownership anomaly and returns up to `:sample_limit` row UUIDs.

  The table and column names are fixed in this module. The sample limit is a
  bound query parameter, and all queries run in a read-only transaction.
  """
  def run(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    sample_limit = Keyword.get(opts, :sample_limit, 20)

    unless is_integer(sample_limit) and sample_limit in 0..20 do
      raise ArgumentError, ":sample_limit must be an integer from 0 to 20"
    end

    {:ok, report} =
      repo.transaction(fn ->
        repo.query!("SET TRANSACTION READ ONLY")

        relationships =
          Enum.map(@version_owner_tables, &version_owner(&1, repo, sample_limit)) ++
            Enum.map(@containment, &containment(&1, repo, sample_limit)) ++
            [import_receipts(repo, sample_limit)]

        %{relationships: relationships, total: Enum.sum(Enum.map(relationships, & &1.anomalies))}
      end)

    report
  end

  @doc "Formats one tab-separated line per ownership relationship."
  def report_lines(%{relationships: relationships}) do
    Enum.map(relationships, fn relationship ->
      "#{relationship.name}\t#{relationship.anomalies}\t#{Enum.join(relationship.samples, ",")}"
    end)
  end

  defp version_owner(table, repo, sample_limit) do
    query = """
    SELECT t.id
    FROM #{table} AS t
    LEFT JOIN gtfs_versions AS v
      ON v.id = t.gtfs_version_id AND v.organization_id = t.organization_id
    WHERE v.id IS NULL
    """

    relationship("#{table}→gtfs_versions", table, :version_owner, query, repo, sample_limit)
  end

  defp containment({name, child, fk, parent}, repo, sample_limit) do
    query = """
    SELECT t.id
    FROM #{child} AS t
    JOIN #{parent} AS p ON p.id = t.#{fk}
    WHERE t.#{fk} IS NOT NULL
      AND (t.organization_id IS DISTINCT FROM p.organization_id
        OR t.gtfs_version_id IS DISTINCT FROM p.gtfs_version_id)
    """

    relationship(name, child, :containment, query, repo, sample_limit)
  end

  defp import_receipts(repo, sample_limit) do
    query = """
    SELECT t.id
    FROM gtfs_import_runs AS t
    LEFT JOIN gtfs_versions AS v
      ON v.id = t.gtfs_version_id AND v.organization_id = t.organization_id
    WHERE t.state <> 'cleaned' AND v.id IS NULL
    """

    relationship(
      "gtfs_import_runs→gtfs_versions",
      "gtfs_import_runs",
      :import_receipt,
      query,
      repo,
      sample_limit
    )
  end

  defp relationship(name, table, kind, anomaly_query, repo, sample_limit) do
    sql = """
    SELECT (SELECT count(*) FROM (#{anomaly_query}) AS anomalies),
           ARRAY(SELECT id::text FROM (#{anomaly_query}) AS anomalies ORDER BY id LIMIT $1)
    """

    %{rows: [[count, samples]]} = repo.query!(sql, [sample_limit])
    %{name: name, table: table, kind: kind, anomalies: count, samples: samples}
  end
end

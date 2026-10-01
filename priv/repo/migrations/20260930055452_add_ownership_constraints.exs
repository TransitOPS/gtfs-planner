defmodule GtfsPlanner.Repo.Migrations.AddOwnershipConstraints do
  use Ecto.Migration

  # This list is fixed at migration time so later audit-catalog changes cannot
  # change what this migration applies on a fresh installation.
  @version_owner_tables ~w(
    agencies alignment_segments areas attributions blocking_settings booking_rules
    calendar_attributes calendar_dates calendars change_logs fare_attributes
    fare_leg_join_rules fare_leg_rules fare_media fare_products fare_rules
    fare_transfer_rules fare_zones feed_info flex_areas flex_services frequencies
    gtfs_validation_runs journal_entries levels locations networks pathway_evolutions
    pathways rider_categories route_networks route_pattern_stops route_patterns routes
    shapes station_editing_statuses stop_areas stop_levels stop_times stops
    timed_patterns timeframes transfers translations trips walkability_tests
  )a

  @containment [
    {:stop_levels, :stop_id, :stops},
    {:stop_levels, :level_id, :levels},
    {:route_pattern_stops, :route_pattern_id, :route_patterns},
    {:timed_patterns, :route_pattern_id, :route_patterns},
    {:trips, :timed_pattern_id, :timed_patterns},
    {:alignment_segments, :from_occurrence_id, :route_pattern_stops},
    {:flex_areas, :flex_service_id, :flex_services},
    {:journal_entries, :station_id, :stops},
    {:station_editing_statuses, :station_id, :stops}
  ]

  def up do
    for table <- ~w(route_patterns timed_patterns route_pattern_stops flex_services)a do
      create unique_index(table, [:id, :organization_id, :gtfs_version_id])
    end

    for table <- @version_owner_tables do
      execute("""
      ALTER TABLE #{qualified_table(table)}
      ADD CONSTRAINT #{table}_version_owner_fkey
      FOREIGN KEY (gtfs_version_id, organization_id)
      REFERENCES #{qualified_table(:gtfs_versions)} (id, organization_id)
      ON DELETE NO ACTION NOT VALID
      """)
    end

    for {child, foreign_key, parent} <- @containment do
      execute("""
      ALTER TABLE #{qualified_table(child)}
      ADD CONSTRAINT #{child}_#{parent}_owner_fkey
      FOREIGN KEY (#{foreign_key}, organization_id, gtfs_version_id)
      REFERENCES #{qualified_table(parent)} (id, organization_id, gtfs_version_id)
      ON DELETE NO ACTION NOT VALID
      """)
    end
  end

  def down do
    raise "Ownership constraints preserve retained data; fix forward with a new migration"
  end

  defp qualified_table(table) do
    case prefix() do
      nil -> Atom.to_string(table)
      schema -> ~s("#{schema}".#{table})
    end
  end
end

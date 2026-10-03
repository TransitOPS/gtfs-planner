defmodule GtfsPlanner.Repo.Migrations.CoverStopTimesStopTripSequence do
  use Ecto.Migration

  # Alert stretch and pair checks join a stop's stop times to the other stop times of the
  # same trip and compare `stop_sequence`. With `stop_sequence` stored in the index both
  # sides of that join are index-only scans. The key columns are the old index's, so the
  # new index replaces it.
  #
  # Built concurrently so imports and editors keep writing `stop_times` during the build,
  # and the old index is dropped only after the new one is valid. Both statements are
  # idempotent: an interrupted run can leave the new index invalid, and a plain create
  # would then fail on its name.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @key [:organization_id, :gtfs_version_id, :stop_id, :trip_id]

  def up do
    drop_if_exists index(:stop_times, @key,
                     name: :stop_times_stop_trip_incl_seq_idx,
                     concurrently: true
                   )

    create index(:stop_times, @key,
             include: [:stop_sequence],
             name: :stop_times_stop_trip_incl_seq_idx,
             concurrently: true
           )

    drop_if_exists index(:stop_times, @key,
                     name: :stop_times_org_version_stop_trip_idx,
                     concurrently: true
                   )
  end

  def down do
    drop_if_exists index(:stop_times, @key,
                     name: :stop_times_org_version_stop_trip_idx,
                     concurrently: true
                   )

    create index(:stop_times, @key,
             name: :stop_times_org_version_stop_trip_idx,
             concurrently: true
           )

    drop_if_exists index(:stop_times, @key,
                     name: :stop_times_stop_trip_incl_seq_idx,
                     concurrently: true
                   )
  end
end

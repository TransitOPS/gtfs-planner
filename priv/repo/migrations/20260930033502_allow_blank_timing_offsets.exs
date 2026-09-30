defmodule GtfsPlanner.Repo.Migrations.AllowBlankTimingOffsets do
  use Ecto.Migration

  # A non-timepoint stop may carry neither a time nor a place to interpolate one,
  # so both offsets become optional. The pair check keeps a half-filled row out:
  # one nil offset with the other set has no meaning, and consumers read the two
  # offsets as one value. The name is repeated as a literal in
  # `GtfsPlanner.Gtfs.TimedPatternStop.changeset/2` so the changeset can name the
  # same error the database raises.
  def change do
    alter table(:timed_pattern_stops) do
      modify :arrival_offset, :integer, null: true, from: {:integer, null: false}
      modify :departure_offset, :integer, null: true, from: {:integer, null: false}
    end

    create constraint(:timed_pattern_stops, :timed_pattern_stops_offsets_both_or_neither,
             check: "(arrival_offset IS NULL) = (departure_offset IS NULL)"
           )
  end
end

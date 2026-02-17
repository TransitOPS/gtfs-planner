defmodule GtfsPlanner.Repo.Migrations.AddStopLevelScaleFields do
  use Ecto.Migration

  def change do
    alter table(:stop_levels) do
      add :scale_point_a, :map
      add :scale_point_b, :map
      add :scale_distance_meters, :decimal, precision: 10, scale: 4
      add :scale_meters_per_unit, :decimal, precision: 12, scale: 8
    end

    create constraint(
             :stop_levels,
             :stop_levels_scale_all_or_none_ck,
             check: """
             (
               scale_point_a IS NULL AND
               scale_point_b IS NULL AND
               scale_distance_meters IS NULL AND
               scale_meters_per_unit IS NULL
             ) OR (
               scale_point_a IS NOT NULL AND
               scale_point_b IS NOT NULL AND
               scale_distance_meters IS NOT NULL AND
               scale_meters_per_unit IS NOT NULL
             )
             """
           )

    create constraint(
             :stop_levels,
             :stop_levels_scale_positive_ck,
             check: """
             (scale_distance_meters IS NULL OR scale_distance_meters > 0) AND
             (scale_meters_per_unit IS NULL OR scale_meters_per_unit > 0)
             """
           )

    create constraint(
             :stop_levels,
             :stop_levels_scale_points_bounds_ck,
             check: """
             (
               scale_point_a IS NULL OR (
                 jsonb_typeof(scale_point_a) = 'object' AND
                 jsonb_typeof(scale_point_a->'x') = 'number' AND
                 jsonb_typeof(scale_point_a->'y') = 'number' AND
                 ((scale_point_a->>'x')::double precision BETWEEN 0 AND 100) AND
                 ((scale_point_a->>'y')::double precision BETWEEN 0 AND 100)
               )
             ) AND (
               scale_point_b IS NULL OR (
                 jsonb_typeof(scale_point_b) = 'object' AND
                 jsonb_typeof(scale_point_b->'x') = 'number' AND
                 jsonb_typeof(scale_point_b->'y') = 'number' AND
                 ((scale_point_b->>'x')::double precision BETWEEN 0 AND 100) AND
                 ((scale_point_b->>'y')::double precision BETWEEN 0 AND 100)
               )
             )
             """
           )
  end
end

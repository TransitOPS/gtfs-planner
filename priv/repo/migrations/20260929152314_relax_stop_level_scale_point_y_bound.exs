defmodule GtfsPlanner.Repo.Migrations.RelaxStopLevelScalePointYBound do
  use Ecto.Migration

  # Diagram coordinates are width-normalized, so a portrait floorplan extends
  # past y = 100. The y ceiling of 400 matches
  # `GtfsPlanner.Gtfs.Coordinates.max_diagram_coordinate/1`; keep the two in
  # step. It is a literal here because migrations must not depend on
  # application modules.
  def up do
    drop constraint(:stop_levels, :stop_levels_scale_points_bounds_ck)
    create constraint(:stop_levels, :stop_levels_scale_points_bounds_ck, check: bounds_check(400))
  end

  # Fails if a row already holds a scale point with y > 100, which is expected:
  # such a row cannot satisfy the original bound.
  def down do
    drop constraint(:stop_levels, :stop_levels_scale_points_bounds_ck)
    create constraint(:stop_levels, :stop_levels_scale_points_bounds_ck, check: bounds_check(100))
  end

  defp bounds_check(max_y) do
    """
    (
      scale_point_a IS NULL OR (
        jsonb_typeof(scale_point_a) = 'object' AND
        jsonb_typeof(scale_point_a->'x') = 'number' AND
        jsonb_typeof(scale_point_a->'y') = 'number' AND
        ((scale_point_a->>'x')::double precision BETWEEN 0 AND 100) AND
        ((scale_point_a->>'y')::double precision BETWEEN 0 AND #{max_y})
      )
    ) AND (
      scale_point_b IS NULL OR (
        jsonb_typeof(scale_point_b) = 'object' AND
        jsonb_typeof(scale_point_b->'x') = 'number' AND
        jsonb_typeof(scale_point_b->'y') = 'number' AND
        ((scale_point_b->>'x')::double precision BETWEEN 0 AND 100) AND
        ((scale_point_b->>'y')::double precision BETWEEN 0 AND #{max_y})
      )
    )
    """
  end
end

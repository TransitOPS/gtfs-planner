defmodule GtfsPlanner.Boundaries.Behaviour do
  @moduledoc """
  Behaviour for a Census boundary service (R9).

  The area editor calls it while staff choose an area boundary and never during
  export or validation (CR-7). A `place` is one pickable boundary: the Census
  `name`, the `layer` it comes from (`"place"`, `"cdp"`, `"county_subdivision"`
  or `"county"`), its `geoid`, the Census `vintage` the boundary belongs to,
  `cdp?: true` for a census-designated place (a statistical boundary, not a
  legal one), and the two-digit `state_fips`.

  `water/1` answers the Census areal hydrography intersecting an envelope, one
  GeoJSON geometry per feature, so `GtfsPlanner.Boundaries.land_boundary/2` can
  subtract it.
  """

  @type bbox :: {float(), float(), float(), float()}

  @type place :: %{
          name: String.t(),
          layer: String.t(),
          geoid: String.t(),
          vintage: String.t(),
          cdp?: boolean(),
          state_fips: String.t() | nil
        }

  @callback places_near(bbox()) :: {:ok, [place()]} | {:error, :unavailable}

  @callback search(name :: String.t(), state_fips :: String.t()) ::
              {:ok, [place()]} | {:error, :unavailable}

  @callback boundary(layer :: String.t(), geoid :: String.t()) ::
              {:ok, %{geojson: map(), vintage: String.t()}}
              | {:error, :unavailable | :not_found}

  @callback water(bbox()) :: {:ok, [map()]} | {:error, :unavailable}
end

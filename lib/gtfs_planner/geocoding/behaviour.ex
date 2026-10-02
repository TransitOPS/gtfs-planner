defmodule GtfsPlanner.Geocoding.Behaviour do
  @moduledoc """
  Behaviour for a geocoding service.
  """

  alias GtfsPlanner.Geocoding.Place
  alias GtfsPlanner.Geocoding.Result

  @callback autocomplete(String.t(), keyword()) ::
              {:ok, [Result.t()]} | {:error, atom() | tuple()}

  @doc """
  Reports the places near a coordinate.

  This is the reverse of `autocomplete/2`: the editor has a point from a map
  click and wants to name it, rather than a name and wants a point.
  """
  @callback reverse(float(), float(), keyword()) ::
              {:ok, [Place.t()]} | {:error, atom() | tuple()}
end

defmodule GtfsPlanner.Geocoding.Behaviour do
  @moduledoc """
  Behaviour for a geocoding service.
  """

  alias GtfsPlanner.Geocoding.Result

  @callback autocomplete(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, atom() | tuple()}
end

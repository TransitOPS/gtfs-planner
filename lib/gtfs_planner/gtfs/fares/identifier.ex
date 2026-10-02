defmodule GtfsPlanner.Gtfs.Fares.Identifier do
  @moduledoc "Normalizes authored fare and route-group identifiers."

  def normalize(name) when is_binary(name) do
    name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
  end
end

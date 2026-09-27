defmodule GtfsPlanner.OperationsFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the
  `GtfsPlanner.Operations` context.
  """

  alias GtfsPlanner.Operations

  @doc """
  Generate a garage in an organization.

  `organization_id` is the owning organization's id; `attrs` overrides the
  generated garage attributes. The acting user is a fresh actor id, which is
  enough for `updated_by_id` because it is a bare `binary_id`.
  """
  def garage_fixture(organization_id, attrs \\ %{}) do
    attrs =
      Enum.into(normalize_keys(attrs), %{
        "garage_id" => "garage_#{System.unique_integer([:positive])}",
        "name" => "Garage #{System.unique_integer([:positive])}",
        "lat" => Decimal.new("40.7128"),
        "lon" => Decimal.new("-74.0060")
      })

    {:ok, garage} = Operations.create_garage(organization_id, actor(), attrs)
    garage
  end

  @doc """
  Generate a vehicle type in an organization.

  Pass `"max_out_hours"` to set the optional limit; it is stored as minutes.
  """
  def vehicle_type_fixture(organization_id, attrs \\ %{}) do
    attrs =
      Enum.into(
        normalize_keys(attrs),
        %{"name" => "Type #{System.unique_integer([:positive])}"}
      )

    {:ok, vehicle_type} = Operations.create_vehicle_type(organization_id, actor(), attrs)
    vehicle_type
  end

  @doc """
  Generate a vehicle in an organization.

  Pass `"vehicle_type_id"` and/or `"garage_id"` to assign organization-owned
  parents.
  """
  def vehicle_fixture(organization_id, attrs \\ %{}) do
    attrs =
      Enum.into(
        normalize_keys(attrs),
        %{"vehicle_id" => "vehicle_#{System.unique_integer([:positive])}"}
      )

    {:ok, vehicle} = Operations.create_vehicle(organization_id, actor(), attrs)
    vehicle
  end

  @doc """
  Generate an opaque actor map for Operations writes.
  """
  def operations_actor, do: actor()

  defp actor, do: %{id: Ecto.UUID.generate()}

  defp normalize_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end

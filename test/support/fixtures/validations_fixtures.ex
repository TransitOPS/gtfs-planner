defmodule GtfsPlanner.ValidationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Validations` context.
  """

  @doc """
  Generate a walkability test fixture.

  Requires `organization_id` in attrs.
  """
  def walkability_test_fixture(attrs) do
    {organization_id, attrs} = Map.pop!(attrs, :organization_id)

    attrs =
      Enum.into(attrs, %{
        stop_id: "stop-1",
        address: "123 Main St",
        address_lat: Decimal.new("42.3601"),
        address_lon: Decimal.new("-71.0589")
      })

    {:ok, walkability_test} =
      GtfsPlanner.Validations.create_walkability_test(organization_id, attrs)

    walkability_test
  end
end

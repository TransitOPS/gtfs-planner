defmodule GtfsPlanner.ValidationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Validations` context.
  """

  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.WalkabilityTest

  @doc """
  Generate a walkability test fixture via direct insertion.

  The write API was retired; tests that need legacy data insert directly.
  """
  def walkability_test_fixture(attrs \\ %{}) do
    {organization_id, attrs} = Map.pop!(attrs, :organization_id)
    {gtfs_version_id, attrs} = Map.pop!(attrs, :gtfs_version_id)

    attrs =
      Enum.into(attrs, %{
        stop_id: "stop-1",
        address: "123 Main St",
        address_lat: Decimal.new("42.3601"),
        address_lon: Decimal.new("-71.0589")
      })

    %WalkabilityTest{organization_id: organization_id, gtfs_version_id: gtfs_version_id}
    |> WalkabilityTest.changeset(attrs)
    |> Repo.insert!()
  end
end

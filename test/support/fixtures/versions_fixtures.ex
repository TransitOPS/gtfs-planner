defmodule GtfsPlanner.VersionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Versions` context.
  """

  alias GtfsPlanner.Versions

  @doc """
  Generate a GTFS version fixture.
  """
  def gtfs_version_fixture(organization_id, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Version #{System.unique_integer()}"
      })

    {:ok, version} = Versions.create_gtfs_version(organization_id, attrs)
    version
  end
end

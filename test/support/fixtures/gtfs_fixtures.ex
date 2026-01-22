defmodule GtfsPlanner.GtfsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Gtfs` context.
  """

  alias GtfsPlanner.Gtfs

  @doc """
  Generate valid level attributes for testing.
  """
  def valid_level_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      level_id: "L#{System.unique_integer()}",
      level_index: 0.0,
      level_name: "Test Level"
    })
  end

  @doc """
  Generate a level fixture.
  """
  def level_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    {:ok, level} = Gtfs.create_level(
      valid_level_attrs(attrs)
      |> Map.put(:organization_id, organization_id)
      |> Map.put(:gtfs_version_id, gtfs_version_id)
    )
    level
  end

  @doc """
  Generate valid stop attributes for testing.
  """
  def valid_stop_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      stop_id: "stop_#{System.unique_integer()}",
      stop_name: "Test Stop",
      stop_lat: Decimal.new("40.7128"),
      stop_lon: Decimal.new("-74.0060"),
      location_type: 0,
      wheelchair_boarding: 0
    })
  end

  @doc """
  Generate a stop fixture.
  """
  def stop_fixture(organization_id, gtfs_version_id, attrs \\ %{}) do
    {:ok, stop} = Gtfs.create_stop(
      valid_stop_attrs(attrs)
      |> Map.put(:organization_id, organization_id)
      |> Map.put(:gtfs_version_id, gtfs_version_id)
    )
    stop
  end

  @doc """
  Generate valid pathway attributes for testing.
  """
  def valid_pathway_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      pathway_id: "pathway_#{System.unique_integer()}",
      pathway_mode: 1,
      is_bidirectional: true,
      traversal_time: 60,
      length: Decimal.new("10.5"),
      stair_count: 12
    })
  end

  @doc """
  Generate a pathway fixture.
  """
  def pathway_fixture(organization_id, gtfs_version_id, from_stop_id, to_stop_id, attrs \\ %{}) do
    {:ok, pathway} = Gtfs.create_pathway(
      valid_pathway_attrs(attrs)
      |> Map.put(:organization_id, organization_id)
      |> Map.put(:gtfs_version_id, gtfs_version_id)
      |> Map.put(:from_stop_id, from_stop_id)
      |> Map.put(:to_stop_id, to_stop_id)
    )
    pathway
  end
end

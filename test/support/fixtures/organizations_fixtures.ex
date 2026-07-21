defmodule GtfsPlanner.OrganizationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Organizations` context.
  """

  @doc """
  Generate a unique organization alias.
  """
  def unique_organization_alias, do: "org#{System.unique_integer()}"

  @doc """
  Generate a valid organization alias.
  """
  def valid_organization_alias, do: "example-org"

  @doc """
  Generate a valid organization name.
  """
  def valid_organization_name, do: "Example Organization"

  @doc """
  Generate valid organization attributes.
  """
  def valid_organization_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      alias: unique_organization_alias(),
      name: valid_organization_name()
    })
  end

  @doc """
  Generate an organization fixture.
  """
  def organization_fixture(attrs \\ %{}) do
    {:ok, organization} =
      attrs
      |> valid_organization_attributes()
      |> GtfsPlanner.Organizations.create_organization()

    organization
  end
end

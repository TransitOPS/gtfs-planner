defmodule GtfsPlanner.OrganizationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Organizations` context.
  """

  alias GtfsPlanner.AccountsFixtures

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

  @doc """
  Generate valid API key attributes.
  """
  def valid_api_key_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      description: "Test API Key",
      roles: ["read"]
    })
  end

  @doc """
  Generate an API key fixture.
  """
  def api_key_fixture(attrs \\ %{}, organization_fixture \\ &organization_fixture/0) do
    organization = organization_fixture.()
    api_key_attrs = valid_api_key_attributes(attrs)

    {:ok, {api_key, token}} =
      GtfsPlanner.Organizations.create_api_key(organization.id, api_key_attrs)

    {api_key, token}
  end

  @doc """
  Generate an API key fixture for a specific organization.
  """
  def api_key_fixture_for_organization(organization_id, attrs \\ %{}) do
    api_key_attrs = valid_api_key_attributes(attrs)

    {:ok, {api_key, token}} =
      GtfsPlanner.Organizations.create_api_key(organization_id, api_key_attrs)

    {api_key, token}
  end
end

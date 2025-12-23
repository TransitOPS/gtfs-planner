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
  def api_key_fixture(organization, attrs \\ %{})

  def api_key_fixture(%GtfsPlanner.Organizations.Organization{id: id}, attrs) do
    api_key_attrs = valid_api_key_attributes(attrs)

    {:ok, {api_key, token}} =
      GtfsPlanner.Organizations.create_api_key(id, api_key_attrs)

    {api_key, token}
  end

  def api_key_fixture(organization_id, attrs) when is_binary(organization_id) do
    api_key_attrs = valid_api_key_attributes(attrs)

    {:ok, {api_key, token}} =
      GtfsPlanner.Organizations.create_api_key(organization_id, api_key_attrs)

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

  @doc """
  Generate a complete fixture with organization and API key.
  Returns a map with :api_key and :api_key_token keys.
  """
  def complete_fixture(attrs \\ %{}) do
    organization = organization_fixture(attrs)
    {api_key, token} = api_key_fixture_for_organization(organization.id)

    %{api_key: api_key, api_key_token: token}
  end
end

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
  Generate a valid organization name.
  """
  def valid_organization_name, do: "Test Organization #{System.unique_integer()}"

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
  Generate a organization fixture.
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
  Generate an API key fixture for an organization.
  """
  def api_key_fixture(organization, attrs \\ %{}) do
    {:ok, {api_key, token}} =
      attrs
      |> valid_api_key_attributes()
      |> GtfsPlanner.Organizations.create_api_key(organization.id)

    {api_key, token}
  end

  @doc """
  Generate a user membership in an organization.
  """
  def user_org_membership_fixture(user, organization, roles \\ []) do
    {:ok, membership} =
      GtfsPlanner.Organizations.add_user_to_organization(
        user.id,
        organization.id,
        roles
      )

    membership
  end

  @doc """
  Generate a complete test setup with user, organization, and API key.
  """
  def complete_fixture(roles \\ ["administrator"]) do
    user = AccountsFixtures.user_fixture()
    organization = organization_fixture()
    user_org_membership_fixture(user, organization, roles)
    {api_key, token} = api_key_fixture(organization)

    %{
      user: user,
      organization: organization,
      api_key: api_key,
      api_key_token: token
    }
  end
end

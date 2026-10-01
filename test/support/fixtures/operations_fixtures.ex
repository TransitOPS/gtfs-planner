defmodule GtfsPlanner.OperationsFixtures do
  @moduledoc """
  This module defines test helpers for creating entities via the
  `GtfsPlanner.Operations` context.
  """

  import Ecto.Query

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

  @editor_role "pathways_studio_editor"

  @doc """
  Generate a garage in an organization.

  `organization_id` is the owning organization's id; `attrs` overrides the
  generated garage attributes. The acting user has a current editor membership.
  """
  def garage_fixture(organization_id, attrs \\ %{}) do
    attrs =
      Enum.into(normalize_keys(attrs), %{
        "garage_id" => "garage_#{System.unique_integer([:positive])}",
        "name" => "Garage #{System.unique_integer([:positive])}",
        "lat" => Decimal.new("40.7128"),
        "lon" => Decimal.new("-74.0060")
      })

    {:ok, garage} =
      Operations.create_garage(organization_id, operations_actor(organization_id), attrs)

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

    {:ok, vehicle_type} =
      Operations.create_vehicle_type(organization_id, operations_actor(organization_id), attrs)

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

    {:ok, vehicle} =
      Operations.create_vehicle(organization_id, operations_actor(organization_id), attrs)

    vehicle
  end

  @doc """
  Return an actor with a current editor membership in the given organization,
  creating one when the organization has no active editor.
  """
  def operations_actor(organization_id) do
    Repo.one(
      from(m in UserOrgMembership,
        join: user in User,
        on: user.id == m.user_id,
        where:
          m.organization_id == ^organization_id and is_nil(m.deactivated_at) and
            ^@editor_role in m.roles,
        order_by: [asc: m.inserted_at],
        select: user,
        limit: 1
      )
    ) || GtfsPlanner.AccountsFixtures.editor_fixture(Repo.get!(Organization, organization_id))
  end

  defp normalize_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end

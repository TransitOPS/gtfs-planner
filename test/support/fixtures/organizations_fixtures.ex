defmodule GtfsPlanner.OrganizationsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Organizations` context.
  """

  import Ecto.Query, only: [from: 2, select: 3]

  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo

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
      |> GtfsPlanner.Organizations.create_organization_unchecked()

    organization
  end

  @doc """
  Deletes the versions `versions` selects, clearing any organization's active schedule
  that points at one of them first.

  The active schedule's ownership key refuses a delete of the active version alone.
  A test that removes an organization's versions directly, to model an organization
  with none or to clean up committed rows, clears the pointer the way an editor would
  by selecting another version. Returns what `Repo.delete_all/1` returns.
  """
  def delete_versions!(versions) do
    Repo.update_all(
      from(o in Organization,
        where: o.active_gtfs_version_id in subquery(select(versions, [v], v.id))
      ),
      set: [active_gtfs_version_id: nil]
    )

    Repo.delete_all(versions)
  end
end

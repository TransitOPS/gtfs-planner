defmodule GtfsPlanner.Versions do
  @moduledoc """
  The Versions context for managing GTFS versions scoped to organizations.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @doc """
  Creates a GTFS version for an organization.

  ## Examples

      iex> create_gtfs_version(organization_id, %{name: "Spring 2024"})
      {:ok, %GtfsVersion{}}

      iex> create_gtfs_version(organization_id, %{name: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_gtfs_version(organization_id, attrs) do
    %GtfsVersion{organization_id: organization_id}
    |> GtfsVersion.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a default "First Version" GTFS version for an organization.

  ## Examples

      iex> create_default_version(organization_id)
      {:ok, %GtfsVersion{name: "First Version"}}
  """
  def create_default_version(organization_id) do
    create_gtfs_version(organization_id, %{name: "First Version"})
  end

  @doc """
  Returns the list of GTFS versions for an organization.

  ## Examples

      iex> list_gtfs_versions(organization_id)
      [%GtfsVersion{}, ...]
  """
  def list_gtfs_versions(organization_id) do
    from(v in GtfsVersion,
      where: v.organization_id == ^organization_id,
      order_by: [asc: v.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Gets a single GTFS version.

  Raises `Ecto.NoResultsError` if the GtfsVersion does not exist.

  ## Examples

      iex> get_gtfs_version!(123)
      %GtfsVersion{}

      iex> get_gtfs_version!(456)
      ** (Ecto.NoResultsError)
  """
  def get_gtfs_version!(id), do: Repo.get!(GtfsVersion, id)
end

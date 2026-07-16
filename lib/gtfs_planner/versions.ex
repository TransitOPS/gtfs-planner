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
    |> GtfsVersion.published_create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a GTFS version.

  ## Examples

      iex> update_gtfs_version(version, %{name: "Renamed"})
      {:ok, %GtfsVersion{}}

      iex> update_gtfs_version(version, %{name: nil})
      {:error, %Ecto.Changeset{}}
  """
  @spec update_gtfs_version(GtfsVersion.t(), map()) ::
          {:ok, GtfsVersion.t()} | {:error, Ecto.Changeset.t()}
  def update_gtfs_version(%GtfsVersion{} = version, attrs) do
    version
    |> GtfsVersion.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking GTFS version changes.

  ## Examples

      iex> change_gtfs_version(version)
      %Ecto.Changeset{data: %GtfsVersion{}}
  """
  @spec change_gtfs_version(GtfsVersion.t(), map()) :: Ecto.Changeset.t()
  def change_gtfs_version(%GtfsVersion{} = version, attrs \\ %{}) do
    GtfsVersion.changeset(version, attrs)
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
  Returns a list of GTFS version tuples for dropdown/select components.

  Returns a list of `{id, name}` tuples ordered by most recent first.

  ## Examples

      iex> list_gtfs_versions_for_dropdown(organization_id)
      [{1, "Spring 2024"}, {2, "Winter 2024"}]

      iex> list_gtfs_versions_for_dropdown(organization_id_with_no_versions)
      []
  """
  def list_gtfs_versions_for_dropdown(organization_id) do
    from(v in GtfsVersion,
      where: v.organization_id == ^organization_id,
      order_by: [desc: v.inserted_at],
      select: {v.id, v.name}
    )
    |> Repo.all()
  end

  @doc """
  Gets the latest GTFS version for an organization.

  Returns `{:ok, %GtfsVersion{}}` if a version exists, or `{:error, :no_versions}` if none exist.

  ## Examples

      iex> get_latest_gtfs_version(organization_id)
      {:ok, %GtfsVersion{}}

      iex> get_latest_gtfs_version(organization_id_with_no_versions)
      {:error, :no_versions}
  """
  def get_latest_gtfs_version(organization_id) do
    result =
      from(v in GtfsVersion,
        where: v.organization_id == ^organization_id,
        order_by: [desc: v.inserted_at],
        limit: 1
      )
      |> Repo.one()

    case result do
      nil -> {:error, :no_versions}
      version -> {:ok, version}
    end
  end

  @doc """
  Gets a single GTFS version.

  Returns nil if the GtfsVersion does not exist.

  ## Examples

      iex> get_gtfs_version(123)
      %GtfsVersion{}

      iex> get_gtfs_version(456)
      nil
  """
  def get_gtfs_version(id), do: Repo.get(GtfsVersion, id)

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

defmodule GtfsPlanner.Operations do
  @moduledoc """
  Organization-wide operational assets (TODS garages and, in later steps, vehicle
  types and vehicles).

  Every read and write filters on the caller's `organization_id` only; GTFS
  versions remain navigation context. `organization_id` and `updated_by_id` are
  set programmatically and are never accepted from user params.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [put_change: 3]

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Repo

  @type actor :: %{required(:id) => Ecto.UUID.t()}

  @type conflict :: %{
          garage_id: String.t(),
          garage_name: String.t(),
          stop_name: String.t() | nil
        }

  # --- garages ---------------------------------------------------------------

  @doc """
  Lists the organization's garages ordered by name.
  """
  @spec list_garages(Ecto.UUID.t()) :: [Garage.t()]
  def list_garages(organization_id) do
    Garage
    |> where([g], g.organization_id == ^organization_id)
    |> order_by([g], asc: g.name)
    |> Repo.all()
  end

  @doc """
  Gets a garage by organization and id, or nil when it does not exist or belongs
  to another organization. A malformed id is treated as missing.
  """
  @spec get_garage(Ecto.UUID.t(), Ecto.UUID.t()) :: Garage.t() | nil
  def get_garage(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Garage, id: id, organization_id: organization_id)
      :error -> nil
    end
  end

  @doc """
  Returns a changeset for tracking garage changes.
  """
  @spec change_garage(Garage.t(), map()) :: Ecto.Changeset.t()
  def change_garage(%Garage{} = garage, attrs \\ %{}) do
    Garage.changeset(garage, attrs)
  end

  @doc """
  Creates a garage for the organization and records the acting user.
  """
  @spec create_garage(Ecto.UUID.t(), actor(), map()) ::
          {:ok, Garage.t()} | {:error, Ecto.Changeset.t()}
  def create_garage(organization_id, actor, attrs) do
    %Garage{organization_id: organization_id, updated_by_id: actor_id(actor)}
    |> Garage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a garage belonging to the organization and records the acting user.

  Returns `{:error, :not_found}` for a missing, malformed or foreign id and
  changes nothing.
  """
  @spec update_garage(Ecto.UUID.t(), actor(), Ecto.UUID.t(), map()) ::
          {:ok, Garage.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_garage(organization_id, actor, id, attrs) do
    case get_garage(organization_id, id) do
      nil ->
        {:error, :not_found}

      garage ->
        garage
        |> Garage.changeset(attrs)
        |> put_change(:updated_by_id, actor_id(actor))
        |> Repo.update()
    end
  end

  @doc """
  Deletes a garage belonging to the organization.

  Returns `{:error, :not_found}` for a missing, malformed or foreign id. This is
  the interim step-1 behavior: deletion is direct until vehicles reference
  garages and in-use deletion must fail closed.
  """
  @spec delete_garage(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Garage.t()} | {:error, :not_found}
  def delete_garage(organization_id, id) do
    case get_garage(organization_id, id) do
      nil -> {:error, :not_found}
      garage -> Repo.delete(garage)
    end
  end

  @doc """
  Defaults a garage ID to `"garage_" <> slug` for a non-blank name, or `""`.

  Mirrors `GtfsPlanner.Gtfs.Stop.slugify/1` so the Garages page can prefill the
  ID until the user edits it.
  """
  @spec default_garage_id(String.t() | nil) :: String.t()
  def default_garage_id(name) do
    case name && Stop.slugify(name) do
      slug when is_binary(slug) and slug != "" -> "garage_" <> slug
      _blank -> ""
    end
  end

  @doc """
  Returns the given garages whose `garage_id` exactly matches a `stops.stop_id`
  of the organization and GTFS version, with the matching stop name.

  Matches are exact and case-sensitive, ignore other organizations and
  versions, and are ordered by garage ID. A malformed organization or version id
  yields no conflicts.
  """
  @spec garage_stop_id_conflicts(Ecto.UUID.t(), Ecto.UUID.t(), [Garage.t()]) :: [conflict()]
  def garage_stop_id_conflicts(_organization_id, _gtfs_version_id, []), do: []

  def garage_stop_id_conflicts(organization_id, gtfs_version_id, garages)
      when is_list(garages) do
    with {:ok, organization_id} <- Ecto.UUID.cast(organization_id),
         {:ok, gtfs_version_id} <- Ecto.UUID.cast(gtfs_version_id) do
      stop_names = stop_names_by_id(organization_id, gtfs_version_id, garages)

      garages
      |> Enum.filter(&Map.has_key?(stop_names, &1.garage_id))
      |> Enum.sort_by(& &1.garage_id)
      |> Enum.map(fn garage ->
        %{
          garage_id: garage.garage_id,
          garage_name: garage.name,
          stop_name: Map.fetch!(stop_names, garage.garage_id)
        }
      end)
    else
      :error -> []
    end
  end

  # --- private ---------------------------------------------------------------

  defp stop_names_by_id(organization_id, gtfs_version_id, garages) do
    garage_ids = garages |> Enum.map(& &1.garage_id) |> Enum.uniq()

    from(s in Stop,
      where:
        s.organization_id == ^organization_id and
          s.gtfs_version_id == ^gtfs_version_id and
          s.stop_id in ^garage_ids,
      select: {s.stop_id, s.stop_name}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp actor_id(%{id: id}), do: id
end

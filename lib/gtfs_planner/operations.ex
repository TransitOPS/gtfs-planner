defmodule GtfsPlanner.Operations do
  @moduledoc """
  Organization-wide operational assets (TODS garages, vehicle types and
  vehicles).

  Every read and write filters on the caller's `organization_id` only; GTFS
  versions remain navigation context. `organization_id`, the assignment
  references and `updated_by_id` are set programmatically and are never accepted
  from user params. Garage and vehicle-type deletion fails closed while any
  vehicle references the parent; deleting the organization still cascades.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [put_change: 3]

  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Repo

  @type actor :: %{required(:id) => Ecto.UUID.t()}

  @type assignment :: Ecto.UUID.t() | :none | nil

  @type conflict :: %{
          garage_id: String.t(),
          garage_name: String.t(),
          stop_name: String.t() | nil
        }

  # --- garages ---------------------------------------------------------------

  @doc """
  Lists the organization's garages ordered by name with their vehicle counts.
  """
  @spec list_garages(Ecto.UUID.t()) :: [Garage.t()]
  def list_garages(organization_id) do
    counts = vehicle_counts_by(organization_id, :garage_id)

    Garage
    |> where([g], g.organization_id == ^organization_id)
    |> order_by([g], asc: g.name)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :vehicle_count, Map.get(counts, &1.id, 0)))
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

  The delete is attempted against the `NO ACTION` foreign key and translated to
  `{:error, {:in_use, vehicles: n}}` when a vehicle still references it; nothing
  is deleted. A missing, malformed or foreign id returns `{:error, :not_found}`.
  Never deletes after a precheck alone.
  """
  @spec delete_garage(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Garage.t()} | {:error, {:in_use, vehicles: non_neg_integer()} | :not_found}
  def delete_garage(organization_id, id) do
    case get_garage(organization_id, id) do
      nil ->
        {:error, :not_found}

      garage ->
        delete_with_in_use_guard(garage, :vehicles_garage_id_fkey, fn ->
          count_vehicles(organization_id, :garage_id, garage.id)
        end)
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

  # --- vehicle types ---------------------------------------------------------

  @doc """
  Lists the organization's vehicle types ordered by name with vehicle counts.
  """
  @spec list_vehicle_types(Ecto.UUID.t()) :: [VehicleType.t()]
  def list_vehicle_types(organization_id) do
    counts = vehicle_counts_by(organization_id, :vehicle_type_id)

    VehicleType
    |> where([t], t.organization_id == ^organization_id)
    |> order_by([t], asc: t.name)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :vehicle_count, Map.get(counts, &1.id, 0)))
  end

  @doc """
  Returns a changeset for tracking vehicle type changes, presenting any stored
  minute limit as editable hours.
  """
  @spec change_vehicle_type(VehicleType.t(), map()) :: Ecto.Changeset.t()
  def change_vehicle_type(%VehicleType{} = vehicle_type, attrs \\ %{}) do
    VehicleType.changeset(vehicle_type, attrs)
  end

  @doc """
  Creates a vehicle type for the organization and records the acting user.
  """
  @spec create_vehicle_type(Ecto.UUID.t(), actor(), map()) ::
          {:ok, VehicleType.t()} | {:error, Ecto.Changeset.t()}
  def create_vehicle_type(organization_id, actor, attrs) do
    %VehicleType{organization_id: organization_id, updated_by_id: actor_id(actor)}
    |> VehicleType.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a vehicle type belonging to the organization and records the acting
  user. Returns `{:error, :not_found}` for a missing, malformed or foreign id.
  """
  @spec update_vehicle_type(Ecto.UUID.t(), actor(), Ecto.UUID.t(), map()) ::
          {:ok, VehicleType.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_vehicle_type(organization_id, actor, id, attrs) do
    case fetch_vehicle_type(organization_id, id) do
      nil ->
        {:error, :not_found}

      vehicle_type ->
        vehicle_type
        |> VehicleType.changeset(attrs)
        |> put_change(:updated_by_id, actor_id(actor))
        |> Repo.update()
    end
  end

  @doc """
  Deletes a vehicle type belonging to the organization.

  The delete is attempted against the `NO ACTION` foreign key and translated to
  `{:error, {:in_use, vehicles: n}}` when a vehicle still references it; nothing
  is deleted. A missing, malformed or foreign id returns `{:error, :not_found}`.
  """
  @spec delete_vehicle_type(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, VehicleType.t()} | {:error, {:in_use, vehicles: non_neg_integer()} | :not_found}
  def delete_vehicle_type(organization_id, id) do
    case fetch_vehicle_type(organization_id, id) do
      nil ->
        {:error, :not_found}

      vehicle_type ->
        delete_with_in_use_guard(vehicle_type, :vehicles_vehicle_type_id_fkey, fn ->
          count_vehicles(organization_id, :vehicle_type_id, vehicle_type.id)
        end)
    end
  end

  # --- vehicles --------------------------------------------------------------

  @doc """
  Lists the organization's vehicles ordered by `char_length(vehicle_id),
  vehicle_id`, with the type and garage preloaded.

  `type` and `garage` accept a UUID to match, `:none` for the unassigned rows or
  `nil` for no filter. `q` is a literal, case-insensitive substring match on the
  vehicle ID, label or license plate; `%` and `_` are matched literally.
  """
  @spec list_vehicles(Ecto.UUID.t(), %{
          type: assignment(),
          garage: assignment(),
          q: String.t() | nil
        }) :: [Vehicle.t()]
  def list_vehicles(organization_id, filters) do
    filters = normalize_filters(filters)

    Vehicle
    |> where([v], v.organization_id == ^organization_id)
    |> filter_assignment(:vehicle_type_id, Map.get(filters, "type"))
    |> filter_assignment(:garage_id, Map.get(filters, "garage"))
    |> filter_search(Map.get(filters, "q"))
    |> order_by([v], asc: fragment("char_length(?)", v.vehicle_id), asc: v.vehicle_id)
    |> preload([:vehicle_type, :garage])
    |> Repo.all()
  end

  @doc """
  Returns a changeset for tracking vehicle changes.
  """
  @spec change_vehicle(Vehicle.t(), map()) :: Ecto.Changeset.t()
  def change_vehicle(%Vehicle{} = vehicle, attrs \\ %{}) do
    Vehicle.changeset(vehicle, attrs)
  end

  @doc """
  Creates a vehicle for the organization and records the acting user.

  A supplied `vehicle_type_id` or `garage_id` must belong to the organization;
  a blank value clears the assignment and a missing, malformed or foreign value
  returns `{:error, :not_found}`. The validated targets are locked `FOR KEY
  SHARE` for the write so a concurrent parent deletion cannot slip in.
  """
  @spec create_vehicle(Ecto.UUID.t(), actor(), map()) ::
          {:ok, Vehicle.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create_vehicle(organization_id, actor, attrs) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        with {:ok, vehicle_type_id} <-
               validate_assignment(
                 organization_id,
                 VehicleType,
                 present_assignment(attrs, "vehicle_type_id")
               ),
             {:ok, garage_id} <-
               validate_assignment(
                 organization_id,
                 Garage,
                 present_assignment(attrs, "garage_id")
               ) do
          %Vehicle{
            organization_id: organization_id,
            updated_by_id: actor_id(actor),
            vehicle_type_id: vehicle_type_id,
            garage_id: garage_id
          }
          |> Vehicle.changeset(attrs)
          |> Repo.insert(mode: :savepoint)
        end
      end)

    outcome
  end

  @doc """
  Updates a vehicle belonging to the organization and records the acting user.

  Assignment keys that are present are validated and set (a blank clears them);
  absent keys keep the stored assignment. A missing, malformed or foreign
  vehicle or target returns `{:error, :not_found}` and changes nothing.
  """
  @spec update_vehicle(Ecto.UUID.t(), actor(), Ecto.UUID.t(), map()) ::
          {:ok, Vehicle.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_vehicle(organization_id, actor, id, attrs) do
    {:ok, outcome} =
      Repo.transaction(fn ->
        case fetch_vehicle(organization_id, id) do
          nil ->
            {:error, :not_found}

          vehicle ->
            with {:ok, vehicle_type_id} <-
                   update_assignment(
                     organization_id,
                     VehicleType,
                     attrs,
                     "vehicle_type_id",
                     vehicle.vehicle_type_id
                   ),
                 {:ok, garage_id} <-
                   update_assignment(
                     organization_id,
                     Garage,
                     attrs,
                     "garage_id",
                     vehicle.garage_id
                   ) do
              vehicle
              |> Vehicle.changeset(attrs)
              |> put_change(:vehicle_type_id, vehicle_type_id)
              |> put_change(:garage_id, garage_id)
              |> put_change(:updated_by_id, actor_id(actor))
              |> Repo.update(mode: :savepoint)
            end
        end
      end)

    outcome
  end

  # --- private ---------------------------------------------------------------

  defp fetch_vehicle(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Vehicle, id: id, organization_id: organization_id)
      :error -> nil
    end
  end

  defp fetch_vehicle_type(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(VehicleType, id: id, organization_id: organization_id)
      :error -> nil
    end
  end

  defp validate_assignment(_organization_id, _schema, value) when value in [nil, ""],
    do: {:ok, nil}

  defp validate_assignment(organization_id, schema, value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> lock_assignment(organization_id, schema, id)
      :error -> {:error, :not_found}
    end
  end

  defp validate_assignment(_organization_id, _schema, _value), do: {:error, :not_found}

  defp update_assignment(organization_id, schema, attrs, key, current) do
    case fetch_attr(attrs, key) do
      :__absent__ -> {:ok, current}
      value -> validate_assignment(organization_id, schema, value)
    end
  end

  defp lock_assignment(organization_id, schema, id) do
    query =
      from(row in schema,
        where: row.id == ^id and row.organization_id == ^organization_id,
        select: row.id,
        lock: "FOR KEY SHARE"
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  # Returns the literal value or `nil` when the key is absent, for create paths
  # where absence and blank mean the same thing.
  defp present_assignment(attrs, key) do
    case fetch_attr(attrs, key) do
      :__absent__ -> nil
      value -> value
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, String.to_existing_atom(key), :__absent__)
    end
  end

  defp fetch_attr(_attrs, _key), do: :__absent__

  defp delete_with_in_use_guard(parent, constraint_name, count_fun) do
    changeset =
      parent
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.foreign_key_constraint(:id, name: constraint_name)

    case Repo.transaction(fn -> Repo.delete(changeset, mode: :savepoint) end) do
      {:ok, {:ok, deleted}} -> {:ok, deleted}
      {:ok, {:error, _changeset}} -> {:error, {:in_use, vehicles: max(count_fun.(), 0)}}
    end
  end

  defp count_vehicles(organization_id, field, id) do
    Vehicle
    |> where([v], v.organization_id == ^organization_id and field(v, ^field) == ^id)
    |> Repo.aggregate(:count, :id)
  end

  defp vehicle_counts_by(organization_id, field) do
    Vehicle
    |> where([v], v.organization_id == ^organization_id and not is_nil(field(v, ^field)))
    |> group_by([v], field(v, ^field))
    |> select([v], {field(v, ^field), count(v.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp normalize_filters(filters) do
    Map.new(filters, fn {key, value} -> {to_string(key), value} end)
  end

  defp filter_assignment(query, _field, nil), do: query

  defp filter_assignment(query, field, :none),
    do: where(query, [v], is_nil(field(v, ^field)))

  defp filter_assignment(query, field, value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> where(query, [v], field(v, ^field) == ^id)
      :error -> where(query, [v], false)
    end
  end

  defp filter_assignment(query, _field, _value), do: where(query, [v], false)

  defp filter_search(query, q) when is_binary(q) do
    case String.trim(q) do
      "" ->
        query

      term ->
        pattern = "%" <> escape_like(term) <> "%"

        where(
          query,
          [v],
          ilike(v.vehicle_id, ^pattern) or ilike(v.vehicle_label, ^pattern) or
            ilike(v.license_plate, ^pattern)
        )
    end
  end

  defp filter_search(query, _q), do: query

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

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

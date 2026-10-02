defmodule GtfsPlanner.Operations do
  @moduledoc """
  Organization-wide operational assets (TODS garages, vehicle types, vehicles
  and operators).

  Every read and write filters on the caller's `organization_id` only; GTFS
  versions remain navigation context. `organization_id`, the assignment
  references and `updated_by_id` are set programmatically and are never accepted
  from user params. Garage and vehicle-type deletion fails closed while any
  vehicle, block attribute or route operating setting references the parent;
  deleting the organization still cascades.

  A block attribute or route operating setting only counts while what it
  describes exists: a trip still runs the block on that service, or the route is
  still in that version. A row left behind by a deleted route, a combined
  calendar or unassigned trips names nothing a person can see or change, so it
  neither counts nor blocks a delete, and the delete clears its reference.

  A garage also owns its entered driving times: `delete_garage/3` deletes the
  `deadhead_times` rows whose reference is `"garage:<uuid>"` in the same
  transaction as the guarded delete, and restores them when the delete is
  refused. Garage references are the garage UUID, never the correctable
  `garage_id`.
  """

  import Ecto.Query, warn: false
  import Ecto.Changeset, only: [put_change: 3]

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.BlockAttribute
  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes
  alias GtfsPlanner.Gtfs.DeadheadTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RouteOperatingSetting
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Operations.Garage
  alias GtfsPlanner.Operations.Operator
  alias GtfsPlanner.Operations.OperatorImport
  alias GtfsPlanner.Operations.Tods
  alias GtfsPlanner.Operations.Vehicle
  alias GtfsPlanner.Operations.VehicleType
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values

  @type actor :: %{required(:id) => Ecto.UUID.t()}

  @type assignment :: Ecto.UUID.t() | :none | nil

  @typedoc """
  What still references a garage or vehicle type, counted per referring kind.

  `blocks` counts the distinct `block_id`s of live `block_attributes` rows and
  `routes` counts live `route_operating_settings` rows, which is one row per
  route. A settings page names the non-zero parts.
  """
  @type in_use_counts :: %{
          vehicles: non_neg_integer(),
          blocks: non_neg_integer(),
          routes: non_neg_integer()
        }

  # The named foreign keys a garage or vehicle type delete can trip. Every one
  # is `NO ACTION`, so the attempted delete is what fails closed.
  @garage_constraints [
    :vehicles_garage_id_fkey,
    :vehicles_garage_id_owner_fkey,
    :block_attributes_garage_id_fkey,
    :block_attributes_garage_id_owner_fkey,
    :route_operating_settings_garage_id_fkey,
    :route_operating_settings_garage_id_owner_fkey
  ]

  @vehicle_type_constraints [
    :vehicles_vehicle_type_id_fkey,
    :vehicles_vehicle_type_id_owner_fkey,
    :block_attributes_vehicle_type_id_fkey,
    :block_attributes_vehicle_type_id_owner_fkey,
    :route_operating_settings_required_vehicle_type_id_fkey,
    :route_operating_settings_required_vehicle_type_id_owner_fkey
  ]

  @type conflict :: %{
          garage_id: String.t(),
          garage_name: String.t(),
          stop_name: String.t() | nil
        }

  # AC-5: a numbered group creates between 1 and 200 vehicles, and a bound is
  # rejected once it exceeds the vehicle_id column limit.
  @range_limit 200
  @max_vehicle_id_length 255

  # Rows per operator insert statement. PostgreSQL caps a statement at 65535 bind
  # parameters and an operator row binds eight, so one `insert_all` fails above
  # about 8,000 rows; 500 stays far below that, as `Runs`' write batch does.
  @operator_insert_batch 500

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
          {:ok, Garage.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_garage(organization_id, actor, attrs) do
    authorized_write(organization_id, actor, fn ->
      %Garage{organization_id: organization_id, updated_by_id: actor_id(actor)}
      |> Garage.changeset(attrs)
      |> Repo.insert(mode: :savepoint)
    end)
  end

  @doc """
  Updates a garage belonging to the organization and records the acting user.

  Returns `{:error, :not_found}` for a missing, malformed or foreign id and
  changes nothing.
  """
  @spec update_garage(Ecto.UUID.t(), actor(), Ecto.UUID.t(), map()) ::
          {:ok, Garage.t()} | {:error, Ecto.Changeset.t() | :not_found | :forbidden}
  def update_garage(organization_id, actor, id, attrs) do
    authorized_write(organization_id, actor, fn ->
      case get_garage(organization_id, id) do
        nil ->
          {:error, :not_found}

        garage ->
          garage
          |> Garage.changeset(attrs)
          |> put_change(:updated_by_id, actor_id(actor))
          |> Repo.update(mode: :savepoint)
      end
    end)
  end

  @doc """
  Deletes a garage belonging to the organization, with its driving times.

  The delete is attempted against the `NO ACTION` foreign keys and translated to
  `{:error, {:in_use, counts}}` naming the vehicles, blocks and routes that
  still reference it; nothing is deleted, including the driving times removed
  just before the attempt. A garage no planning row references is deleted
  together with the `deadhead_times` rows whose `from_ref` or `to_ref` is
  `"garage:<uuid>"`; every other driving time is left alone. A block attribute
  or route setting that no longer describes a live block or route is cleared of
  the garage in the same transaction instead of refusing the delete. A missing,
  malformed or foreign id returns `{:error, :not_found}`. Never deletes after a
  precheck alone.
  """
  @spec delete_garage(Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, Garage.t()} | {:error, {:in_use, in_use_counts()} | :not_found | :forbidden}
  def delete_garage(organization_id, actor, id) do
    guarded_delete(
      organization_id,
      actor,
      fn -> lock_garage_for_delete(organization_id, id) end,
      @garage_constraints,
      fn garage -> garage_in_use_counts(organization_id, garage.id) end,
      fn garage ->
        delete_garage_driving_times(organization_id, garage.id)
        clear_orphan_references(organization_id, :garage_id, :garage_id, garage.id)
      end
    )
  end

  @doc """
  Whether any count is non-zero, which is the whole in-use answer.

  A caller that wants to refuse before attempting the delete reads this, and
  the delete itself still attempts the write, so a precheck never authorizes a
  delete on its own.
  """
  @spec in_use?(in_use_counts()) :: boolean()
  def in_use?(%{vehicles: vehicles, blocks: blocks, routes: routes}) do
    vehicles > 0 or blocks > 0 or routes > 0
  end

  @doc """
  Counts what still references a garage: its vehicles, the distinct blocks that
  name it and the routes that operate from it. Only blocks that still have trips
  and routes that still exist count.

  A settings page reads this to name the references in its in-use message, and
  `delete_garage/3` answers a refused delete with the same counts.
  """
  @spec garage_in_use_counts(Ecto.UUID.t(), Ecto.UUID.t()) :: in_use_counts()
  def garage_in_use_counts(organization_id, garage_id) do
    %{
      vehicles: count_vehicles(organization_id, :garage_id, garage_id),
      blocks: count_referring_blocks(organization_id, :garage_id, garage_id),
      routes: count_route_settings(organization_id, :garage_id, garage_id)
    }
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

  @doc """
  Returns the organization's garages keyed by UUID, with float coordinates.

  This is the read a loaded planning context uses, so it returns exactly the five
  fields that context carries and nothing a `Garage` struct holds for the settings
  pages: no vehicle count, no address, no `updated_by_id`. Coordinates are decimals
  on the column and floats here, which is what the driving-time estimate and
  `Blocking.Distance.path_km/1` take.

  The key is the UUID, because that is the identity a `block_attributes` or
  `route_operating_settings` row references. The correctable public
  `garage_id` travels in the value for the TODS export but is never a key.
  """
  @spec planning_garages(Ecto.UUID.t()) :: %{
          Ecto.UUID.t() => GtfsPlanner.Gtfs.Blocking.Context.garage()
        }
  def planning_garages(organization_id) do
    Garage
    |> where([g], g.organization_id == ^organization_id)
    |> select([g], %{id: g.id, garage_id: g.garage_id, name: g.name, lat: g.lat, lon: g.lon})
    |> Repo.all()
    |> Map.new(fn garage ->
      {garage.id,
       %{garage | lat: Decimal.to_float(garage.lat), lon: Decimal.to_float(garage.lon)}}
    end)
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
  Gets a vehicle type by organization and id, or nil when it does not exist or
  belongs to another organization. A malformed id is treated as missing.

  The ownership check every `route_operating_settings` and `block_attributes`
  writer makes: a type of another organization is a rejected field value, not a
  stored reference resolved later.
  """
  @spec get_vehicle_type(Ecto.UUID.t(), Ecto.UUID.t()) :: VehicleType.t() | nil
  def get_vehicle_type(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(VehicleType, id: id, organization_id: organization_id)
      :error -> nil
    end
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
          {:ok, VehicleType.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_vehicle_type(organization_id, actor, attrs) do
    authorized_write(organization_id, actor, fn ->
      %VehicleType{organization_id: organization_id, updated_by_id: actor_id(actor)}
      |> VehicleType.changeset(attrs)
      |> Repo.insert(mode: :savepoint)
    end)
  end

  @doc """
  Updates a vehicle type belonging to the organization and records the acting
  user. Returns `{:error, :not_found}` for a missing, malformed or foreign id.
  """
  @spec update_vehicle_type(Ecto.UUID.t(), actor(), Ecto.UUID.t(), map()) ::
          {:ok, VehicleType.t()} | {:error, Ecto.Changeset.t() | :not_found | :forbidden}
  def update_vehicle_type(organization_id, actor, id, attrs) do
    authorized_write(organization_id, actor, fn ->
      case get_vehicle_type(organization_id, id) do
        nil ->
          {:error, :not_found}

        vehicle_type ->
          vehicle_type
          |> VehicleType.changeset(attrs)
          |> put_change(:updated_by_id, actor_id(actor))
          |> Repo.update(mode: :savepoint)
      end
    end)
  end

  @doc """
  Deletes a vehicle type belonging to the organization.

  The delete is attempted against the `NO ACTION` foreign keys and translated to
  `{:error, {:in_use, counts}}` naming the vehicles, blocks and routes that
  still reference it; nothing is deleted. A block attribute or route setting
  that no longer describes a live block or route is cleared of the type in the
  same transaction instead of refusing the delete. A missing, malformed or
  foreign id returns `{:error, :not_found}`.
  """
  @spec delete_vehicle_type(Ecto.UUID.t(), actor(), Ecto.UUID.t()) ::
          {:ok, VehicleType.t()} | {:error, {:in_use, in_use_counts()} | :not_found | :forbidden}
  def delete_vehicle_type(organization_id, actor, id) do
    guarded_delete(
      organization_id,
      actor,
      fn -> get_vehicle_type(organization_id, id) end,
      @vehicle_type_constraints,
      fn vehicle_type -> vehicle_type_in_use_counts(organization_id, vehicle_type.id) end,
      fn vehicle_type ->
        clear_orphan_references(
          organization_id,
          :vehicle_type_id,
          :required_vehicle_type_id,
          vehicle_type.id
        )
      end
    )
  end

  @doc """
  Counts what still references a vehicle type: its vehicles, the distinct blocks
  that require it and the routes that require it. Only blocks that still have
  trips and routes that still exist count.

  A settings page reads this to name the references in its in-use message, and
  `delete_vehicle_type/3` answers a refused delete with the same counts.
  """
  @spec vehicle_type_in_use_counts(Ecto.UUID.t(), Ecto.UUID.t()) :: in_use_counts()
  def vehicle_type_in_use_counts(organization_id, vehicle_type_id) do
    %{
      vehicles: count_vehicles(organization_id, :vehicle_type_id, vehicle_type_id),
      blocks: count_referring_blocks(organization_id, :vehicle_type_id, vehicle_type_id),
      routes: count_route_settings(organization_id, :required_vehicle_type_id, vehicle_type_id)
    }
  end

  @doc """
  Returns the organization's vehicle types keyed by UUID.

  The companion of `planning_garages/1` and the same shape: the three fields a
  loaded context carries, keyed by the UUID a `block_attributes` or
  `route_operating_settings` row references. `max_out_minutes` is passed through
  as stored, so an absent limit stays `nil` and a caller can tell "no limit" from
  "a limit of zero". A type no planning row references is still returned, because
  `Context.resolve_block/3` falls back to the first trip's route type rather than to an
  attribute.
  """
  @spec planning_vehicle_types(Ecto.UUID.t()) :: %{
          Ecto.UUID.t() => GtfsPlanner.Gtfs.Blocking.Context.vehicle_type()
        }
  def planning_vehicle_types(organization_id) do
    VehicleType
    |> where([t], t.organization_id == ^organization_id)
    |> select([t], %{id: t.id, name: t.name, max_out_minutes: t.max_out_minutes})
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
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
          {:ok, Vehicle.t()} | {:error, Ecto.Changeset.t() | :not_found | :forbidden}
  def create_vehicle(organization_id, actor, attrs) do
    authorized_write(organization_id, actor, fn ->
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
  end

  @doc """
  Updates a vehicle belonging to the organization and records the acting user.

  Assignment keys that are present are validated and set (a blank clears them);
  absent keys keep the stored assignment. A missing, malformed or foreign
  vehicle or target returns `{:error, :not_found}` and changes nothing.
  """
  @spec update_vehicle(Ecto.UUID.t(), actor(), Ecto.UUID.t(), map()) ::
          {:ok, Vehicle.t()} | {:error, Ecto.Changeset.t() | :not_found | :forbidden}
  def update_vehicle(organization_id, actor, id, attrs) do
    authorized_write(organization_id, actor, fn ->
      case fetch_vehicle(organization_id, id) do
        nil -> {:error, :not_found}
        vehicle -> apply_vehicle_update(organization_id, actor, vehicle, attrs)
      end
    end)
  end

  # Assignment keys that are present are validated and set here, inside the
  # caller's transaction; absent keys keep the stored assignment.
  defp apply_vehicle_update(organization_id, actor, vehicle, attrs) do
    with {:ok, vehicle_type_id} <-
           update_assignment(
             organization_id,
             VehicleType,
             attrs,
             "vehicle_type_id",
             vehicle.vehicle_type_id
           ),
         {:ok, garage_id} <-
           update_assignment(organization_id, Garage, attrs, "garage_id", vehicle.garage_id) do
      vehicle
      |> Vehicle.changeset(attrs)
      |> put_change(:vehicle_type_id, vehicle_type_id)
      |> put_change(:garage_id, garage_id)
      |> put_change(:updated_by_id, actor_id(actor))
      |> Repo.update(mode: :savepoint)
    end
  end

  @doc """
  Creates a numbered group of 1 to 200 vehicles and records the acting user.

  `attrs` carries the `"first"` and `"last"` numbers plus the optional
  `"vehicle_type_id"` and `"garage_id"` assignments. Generated IDs keep the
  digit width of the first number, so `0098` to `0102` creates `0098`, `0099`,
  `0100`, `0101` and `0102`. A reversed, non-numeric, longer than 255 digit or
  larger than 200 number range returns `{:error, {:invalid_range, message}}` and
  inserts nothing. A malformed, missing or foreign assignment target returns
  `{:error, :not_found}` and inserts nothing.

  When any generated ID already exists nothing is inserted and
  `{:error, {:ids_taken, ids}}` names every existing ID. A concurrent writer
  that claims part of the range rolls the batch back and reports the same error
  from a fresh read, so a partial range never survives.
  """
  @spec create_vehicle_range(Ecto.UUID.t(), actor(), map()) ::
          {:ok, [Vehicle.t()]}
          | {:error,
             {:invalid_range, String.t()} | {:ids_taken, [String.t()]} | :not_found | :forbidden}
  def create_vehicle_range(organization_id, actor, attrs) do
    Repo.transaction(fn ->
      authorize_editor!(organization_id, actor)

      case range_vehicle_ids(attrs) do
        {:ok, vehicle_ids} ->
          {vehicle_ids, insert_range_plan(organization_id, actor, attrs, vehicle_ids)}

        {:error, reason} ->
          {[], {:error, reason}}
      end
    end)
    |> range_outcome(organization_id)
  end

  # The transaction body: validate the assignment targets, refuse any claimed
  # ID, then insert the whole group. A short insert rolls back via
  # `insert_vehicle_range/5`.
  defp insert_range_plan(organization_id, actor, attrs, vehicle_ids) do
    with {:ok, vehicle_type_id} <-
           validate_assignment(
             organization_id,
             VehicleType,
             present_assignment(attrs, "vehicle_type_id")
           ),
         {:ok, garage_id} <-
           validate_assignment(organization_id, Garage, present_assignment(attrs, "garage_id")),
         [] <- existing_vehicle_ids(organization_id, vehicle_ids) do
      insert_vehicle_range(organization_id, actor, vehicle_ids, vehicle_type_id, garage_id)
    else
      taken when is_list(taken) -> {:ids_taken, taken}
      {:error, :not_found} = not_found -> not_found
    end
  end

  # A short insert (a concurrent writer claimed part of the range after the
  # recompute) reports the currently taken IDs from a fresh read outside the
  # rolled-back transaction.
  defp range_outcome({:ok, {_ids, {:ok, vehicles}}}, _organization_id), do: {:ok, vehicles}

  defp range_outcome({:ok, {_ids, {:ids_taken, taken}}}, _organization_id),
    do: {:error, {:ids_taken, taken}}

  defp range_outcome({:ok, {_ids, {:error, :not_found} = not_found}}, _organization_id),
    do: not_found

  defp range_outcome({:ok, {_ids, {:error, {:invalid_range, _} = reason}}}, _organization_id),
    do: {:error, reason}

  defp range_outcome({:error, :forbidden}, _organization_id), do: {:error, :forbidden}

  defp range_outcome({:error, {:short_insert, _count, vehicle_ids}}, organization_id) do
    {:error, {:ids_taken, existing_vehicle_ids(organization_id, vehicle_ids)}}
  end

  @doc """
  Sets one assignment field on every listed vehicle and records the acting user.

  `assignment` names the single field to write (`:vehicle_type_id` or
  `:garage_id`) and its value; `nil` clears it and leaves the other assignment
  untouched. IDs are deduplicated and cast, and every one must belong to the
  organization: a malformed, missing or foreign vehicle, or a malformed, missing
  or foreign target, returns `{:error, :not_found}` and changes nothing. An
  empty list returns `{:ok, 0}`; otherwise the affected count is returned.
  """
  @spec update_vehicles(
          Ecto.UUID.t(),
          actor(),
          [Ecto.UUID.t()],
          {:vehicle_type_id | :garage_id, Ecto.UUID.t() | nil}
        ) :: {:ok, non_neg_integer()} | {:error, :not_found | :forbidden}
  def update_vehicles(organization_id, actor, ids, assignment) do
    Repo.transaction(fn ->
      authorize_editor!(organization_id, actor)

      with {:ok, ids} <- cast_vehicle_ids(ids),
           {:ok, field, value} <- bulk_assignment(assignment) do
        update_vehicles_locked(organization_id, actor, ids, field, value)
      end
    end)
    |> bulk_write_outcome()
  end

  defp update_vehicles_locked(_organization_id, _actor, [], _field, _value), do: {:ok, 0}

  # The target is locked before the vehicles so a concurrent parent deletion
  # cannot hold the parent while waiting for these rows.
  defp update_vehicles_locked(organization_id, actor, ids, field, value) do
    with {:ok, value} <- validate_assignment(organization_id, assignment_schema(field), value),
         {:ok, locked_ids} <- lock_vehicles(organization_id, ids) do
      update_vehicles_rows(organization_id, actor, locked_ids, field, value)
    end
  end

  defp update_vehicles_rows(organization_id, actor, locked_ids, field, value) do
    now = DateTime.utc_now()

    {count, _} =
      Vehicle
      |> where([v], v.organization_id == ^organization_id and v.id in ^locked_ids)
      |> Repo.update_all(
        set: [
          {field, value},
          {:updated_by_id, actor_id(actor)},
          {:updated_at, now}
        ]
      )

    verified_vehicle_count(count, locked_ids)
  end

  @doc """
  Deletes every listed vehicle of the organization, or none of them.

  IDs are deduplicated and cast, and every one must belong to the organization:
  a malformed, missing or foreign vehicle returns `{:error, :not_found}` and
  deletes nothing, including the rows already selected. An empty list returns
  `{:ok, 0}`; otherwise the deleted count is returned.
  """
  @spec delete_vehicles(Ecto.UUID.t(), actor(), [Ecto.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, :not_found | :forbidden}
  def delete_vehicles(organization_id, actor, ids) do
    Repo.transaction(fn ->
      authorize_editor!(organization_id, actor)

      with {:ok, ids} <- cast_vehicle_ids(ids) do
        delete_vehicles_locked(organization_id, ids)
      end
    end)
    |> bulk_write_outcome()
  end

  defp delete_vehicles_locked(_organization_id, []), do: {:ok, 0}

  defp delete_vehicles_locked(organization_id, ids) do
    with {:ok, locked_ids} <- lock_vehicles(organization_id, ids) do
      delete_vehicles_rows(organization_id, locked_ids)
    end
  end

  defp delete_vehicles_rows(organization_id, locked_ids) do
    {count, _} =
      Vehicle
      |> where([v], v.organization_id == ^organization_id and v.id in ^locked_ids)
      |> Repo.delete_all()

    verified_vehicle_count(count, locked_ids)
  end

  # Both bulk writers require the affected count to match the locked rows; a
  # mismatch rolls the whole request back.
  defp verified_vehicle_count(count, locked_ids) when count == length(locked_ids),
    do: {:ok, count}

  defp verified_vehicle_count(_count, _locked_ids), do: Repo.rollback(:count_mismatch)

  defp bulk_write_outcome({:ok, {:ok, count}}), do: {:ok, count}
  defp bulk_write_outcome({:ok, {:error, :not_found}}), do: {:error, :not_found}
  defp bulk_write_outcome({:error, :forbidden}), do: {:error, :forbidden}
  defp bulk_write_outcome({:error, _reason}), do: {:error, :not_found}

  @doc """
  Counts the organization's vehicles per garage and vehicle type pair.

  Every pair that has vehicles produces one bucket, including the `nil` garage
  and `nil` vehicle type buckets, so the bucket counts sum to the organization's
  vehicle count. Buckets are ordered by garage then type name, with unassigned
  values last; an organization without vehicles returns `[]`.
  """
  @spec fleet_summary(Ecto.UUID.t()) :: [
          %{garage: Garage.t() | nil, vehicle_type: VehicleType.t() | nil, count: pos_integer()}
        ]
  def fleet_summary(organization_id) do
    pairs =
      Vehicle
      |> where([v], v.organization_id == ^organization_id)
      |> group_by([v], [v.garage_id, v.vehicle_type_id])
      |> select([v], {v.garage_id, v.vehicle_type_id, count(v.id)})
      |> Repo.all()

    garages = rows_by_id(Garage, organization_id, Enum.map(pairs, &elem(&1, 0)))
    vehicle_types = rows_by_id(VehicleType, organization_id, Enum.map(pairs, &elem(&1, 1)))

    pairs
    |> Enum.map(fn {garage_id, vehicle_type_id, count} ->
      %{
        garage: Map.get(garages, garage_id),
        vehicle_type: Map.get(vehicle_types, vehicle_type_id),
        count: count
      }
    end)
    |> Enum.sort_by(fn bucket ->
      {summary_sort_key(bucket.garage), summary_sort_key(bucket.vehicle_type)}
    end)
  end

  # --- Operators -------------------------------------------------------------

  @doc """
  Lists the organization's operators in seniority order.

  Seniority numbers ascend with blanks last; equal numbers are ordered by
  employee ID and an operator without a number by display name, then employee
  ID. This is the single ordering every operator list reads (domain rule 11).
  """
  @spec list_operators(Ecto.UUID.t()) :: [Operator.t()]
  def list_operators(organization_id) do
    Operator
    |> where([o], o.organization_id == ^organization_id)
    |> order_by([o],
      asc_nulls_last: o.seniority_number,
      asc: fragment("CASE WHEN ? IS NULL THEN ? END", o.seniority_number, o.display_name),
      asc: o.employee_id
    )
    |> Repo.all()
  end

  @doc """
  Gets an operator by organization and id, or nil when it does not exist or
  belongs to another organization. A malformed id is treated as missing.

  This is how another context resolves a submitted operator id without reading
  the `operators` table itself — `GtfsPlanner.Gtfs.Rosters.assign_operator/3`
  uses it, the way the block writers resolve a garage or vehicle type.
  """
  @spec get_operator(Ecto.UUID.t(), term()) :: Operator.t() | nil
  def get_operator(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Operator, id: id, organization_id: organization_id)
      :error -> nil
    end
  end

  @doc """
  Returns a changeset for tracking operator changes.
  """
  @spec change_operator(Operator.t(), map()) :: Ecto.Changeset.t()
  def change_operator(%Operator{} = operator, attrs \\ %{}) do
    Operator.changeset(operator, attrs)
  end

  @doc """
  Creates an operator for the organization and records the acting user.

  An employee ID the organization already holds is refused with an error naming
  the operator who holds it, so the editor is not left searching the list. An
  actor who is no longer an editor of the organization is
  `{:error, :forbidden}` and nothing is written.
  """
  @spec create_operator(Ecto.UUID.t(), actor(), map()) ::
          {:ok, Operator.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create_operator(organization_id, actor, attrs) do
    authorized_write(organization_id, actor, fn ->
      changeset =
        %Operator{organization_id: organization_id, updated_by_id: actor_id(actor)}
        |> Operator.changeset(attrs)

      with {:ok, changeset} <- refuse_employee_id(changeset, organization_id, nil) do
        Repo.insert(changeset, mode: :savepoint)
      end
    end)
  end

  @doc """
  Updates an operator belonging to the organization and records the acting user.

  Returns `{:error, :not_found}` for a missing, malformed or foreign id and
  changes nothing. An employee ID another operator already holds is refused with
  an error naming the holder. An actor who is no longer an editor of the
  organization is `{:error, :forbidden}`.
  """
  @spec update_operator(Ecto.UUID.t(), actor(), term(), map()) ::
          {:ok, Operator.t()} | {:error, Ecto.Changeset.t() | :not_found | :forbidden}
  def update_operator(organization_id, actor, id, attrs) do
    authorized_write(organization_id, actor, fn ->
      update_operator_row(organization_id, actor, id, attrs)
    end)
  end

  # The update itself, for a caller that has already locked the actor's editor
  # membership in its own transaction.
  defp update_operator_row(organization_id, actor, id, attrs) do
    case get_operator(organization_id, id) do
      nil ->
        {:error, :not_found}

      operator ->
        changeset =
          operator
          |> Operator.changeset(attrs)
          |> put_change(:updated_by_id, actor_id(actor))

        with {:ok, changeset} <- refuse_employee_id(changeset, organization_id, operator.id) do
          Repo.update(changeset, mode: :savepoint)
        end
    end
  end

  @doc """
  Deletes an operator belonging to the organization and returns the deleted row.

  The delete is organization-scoped and hard: the row is gone. Its roster lines
  are not — the foreign key empties `roster_lines.operator_id`, so every line the
  operator held, in any version, shows Open rather than disappearing with them
  (domain rule 12, AC-6). A caller names those lines with
  `GtfsPlanner.Gtfs.Rosters.operator_holdings/2` before it confirms.

  Returns `{:error, :not_found}` for a missing, malformed or foreign id and
  deletes nothing, and `{:error, :forbidden}` when the actor is no longer an
  editor of the organization.
  """
  @spec delete_operator(Ecto.UUID.t(), actor(), term()) ::
          {:ok, Operator.t()} | {:error, :not_found | :forbidden}
  def delete_operator(organization_id, actor, id) do
    authorized_write(organization_id, actor, fn ->
      case get_operator(organization_id, id) do
        nil -> {:error, :not_found}
        operator -> Repo.delete(operator)
      end
    end)
  end

  # --- Operator import -------------------------------------------------------

  @doc """
  Classifies a parsed operators CSV against the organization's stored operators.

  A valid row carrying an employee ID the organization already holds is an
  update, any other valid row is an add, and an invalid row is skipped with its
  reason. Skipped rows and `ignored_columns` come from
  `Operations.OperatorImport.classify/2` unchanged: only `employee_id`,
  `display_name` and `seniority_number` are read, and a file without a
  `seniority_number` column marks every row `:keep`.
  """
  @spec preview_operator_import(Ecto.UUID.t(), Tods.parsed()) :: OperatorImport.preview()
  def preview_operator_import(organization_id, parsed) do
    classify_operators(organization_id, parsed, false)
  end

  @doc """
  Applies a previewed operators CSV in one transaction, or changes nothing.

  The organization's operators are locked `FOR UPDATE` in employee ID order and
  the preview is recomputed from them, so an operator created, deleted or
  re-identified since the preview changes the add or update ID set and the apply
  returns `{:error, {:preview_changed, preview}}` with a fresh preview instead of
  writing. Adds are inserted with `on_conflict: :nothing`; a short insert (a
  concurrent insert claimed an ID after the recompute) rolls back every write and
  returns a freshly read `{:error, {:preview_changed, preview}}` too.

  The editor membership is locked first, so an actor who is no longer an editor
  of the organization gets `{:error, :forbidden}` and nothing is written.

  Updates keep `update_operator/4`'s rules — they record the acting user and
  keep its duplicate employee ID refusal — and only the file's mapped fields are
  written: a file with no `seniority_number` column leaves the stored number
  alone and a blank cell clears it. No stored operator is deleted and an update
  keeps the row's UUID.
  """
  @spec apply_operator_import(Ecto.UUID.t(), actor(), Tods.parsed(), OperatorImport.preview()) ::
          {:ok, %{added: non_neg_integer(), updated: non_neg_integer()}}
          | {:error, {:preview_changed, OperatorImport.preview()} | :forbidden}
  def apply_operator_import(organization_id, actor, parsed, preview) do
    outcome =
      Repo.transaction(fn ->
        authorize_editor!(organization_id, actor)
        existing = load_operators(organization_id, true)
        fresh = classify_operators(existing, parsed)

        if same_operator_plan?(fresh, preview) do
          write_operator_import(organization_id, actor, existing, fresh)
        else
          Repo.rollback({:preview_changed, fresh})
        end
      end)

    case outcome do
      {:ok, %{added: _added, updated: _updated} = result} ->
        {:ok, result}

      {:error, {:preview_changed, fresh}} ->
        {:error, {:preview_changed, fresh}}

      {:error, :short_insert} ->
        {:error, {:preview_changed, preview_operator_import(organization_id, parsed)}}

      {:error, :forbidden} ->
        {:error, :forbidden}
    end
  end

  defp classify_operators(organization_id, parsed, lock?) do
    organization_id
    |> load_operators(lock?)
    |> classify_operators(parsed)
  end

  defp classify_operators(existing, parsed) do
    OperatorImport.classify(parsed, MapSet.new(Map.keys(existing)))
  end

  # Every stored operator of the organization is locked, not only the ones the
  # file names: the plan comparison reads the whole employee ID set, and an
  # update writes the locked row rather than a row read after the lock.
  defp load_operators(organization_id, lock?) do
    Operator
    |> where([o], o.organization_id == ^organization_id)
    |> lock_rows(lock?)
    |> order_by([o], asc: o.employee_id)
    |> Repo.all()
    |> Map.new(&{&1.employee_id, &1})
  end

  defp same_operator_plan?(fresh, preview) do
    Enum.sort(employee_ids(fresh.add)) == Enum.sort(employee_ids(Map.get(preview, :add, []))) and
      Enum.sort(employee_ids(fresh.update)) ==
        Enum.sort(employee_ids(Map.get(preview, :update, [])))
  end

  defp employee_ids(rows), do: Enum.map(rows, & &1.employee_id)

  # Each update goes through `update_operator_row/4` against the locked row, so
  # the acting user is recorded and its duplicate employee ID refusal stays: the
  # stored row carries the file's employee ID, and the holder lookup excludes
  # the row being updated.
  defp write_operator_import(organization_id, actor, existing, fresh) do
    Enum.each(fresh.update, fn row ->
      {:ok, _operator} =
        update_operator_row(
          organization_id,
          actor,
          Map.fetch!(existing, row.employee_id).id,
          operator_import_fields(row)
        )
    end)

    added = insert_operator_adds(organization_id, actor_id(actor), fresh.add)

    %{added: added, updated: length(fresh.update)}
  end

  # `:keep` leaves the stored seniority number untouched; a present cell,
  # including a blank one, is written as it stands.
  defp operator_import_fields(row) do
    fields = %{employee_id: row.employee_id, display_name: row.display_name}

    case row.seniority_number do
      :keep -> fields
      number -> Map.put(fields, :seniority_number, number)
    end
  end

  defp insert_operator_adds(_organization_id, _actor_id, []), do: 0

  defp insert_operator_adds(organization_id, actor_id, rows) do
    now = DateTime.utc_now()

    entries =
      Enum.map(rows, fn row ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          employee_id: row.employee_id,
          display_name: row.display_name,
          # An add has no stored seniority to keep, so `:keep` inserts none.
          seniority_number: new_seniority_number(row.seniority_number),
          updated_by_id: actor_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    entries
    |> Enum.chunk_every(@operator_insert_batch)
    |> Enum.map(&insert_planned(Operator, &1, length(&1)))
    |> Enum.sum()
  end

  defp new_seniority_number(:keep), do: nil
  defp new_seniority_number(seniority_number), do: seniority_number

  # --- TODS import -----------------------------------------------------------

  @doc """
  Classifies a parsed TODS file against the organization's stored records.

  Accepted rows whose ID already exists in the organization become `update`
  entries; the rest become `add` entries. A new garage without both coordinates
  is an error (`"New garage needs stop_lat and stop_lon."`) instead of an add,
  so a non-empty `errors` list blocks apply. Skipped rows, `ignored_columns` and
  the other blocking errors come from `Tods.classify/1` unchanged.
  """
  @spec preview_tods_import(Ecto.UUID.t(), Tods.parsed()) :: Tods.preview()
  def preview_tods_import(organization_id, parsed) do
    %{accepted: accepted} = classification = Tods.classify(parsed)
    existing = load_existing(organization_id, parsed.kind, Enum.map(accepted, & &1.id), false)

    assemble_preview(parsed.kind, accepted, existing, classification)
  end

  @doc """
  Applies a previewed TODS import in one transaction, or changes nothing.

  Matching stored rows are locked `FOR UPDATE` in ID order and the preview is
  recomputed from them. A recomputed preview with errors returns
  `{:error, {:invalid, preview}}`; one whose `add` or `update` IDs differ from
  `preview` returns `{:error, {:preview_changed, preview}}`. Adds are inserted
  with `on_conflict: :nothing`; a short insert (a concurrent insert claimed an
  ID after the recompute) rolls back every write and returns a freshly read
  `{:error, {:preview_changed, preview}}`.

  Updates write only the fields the file carries under the TODS field rules and
  record `updated_by_id`: an absent column preserves a stored value, a blank
  optional vehicle field clears, a blank required garage field preserves, and a
  new garage without a name is named by its ID. A garage's address and a
  vehicle's type and garage are never touched, absent records are never deleted,
  and an update keeps the record's UUID.
  """
  @spec apply_tods_import(Ecto.UUID.t(), actor(), Tods.parsed(), Tods.preview()) ::
          {:ok, %{added: non_neg_integer(), updated: non_neg_integer()}}
          | {:error, {:invalid | :preview_changed, Tods.preview()} | :forbidden}
  def apply_tods_import(organization_id, actor, parsed, preview) do
    outcome =
      Repo.transaction(fn ->
        authorize_editor!(organization_id, actor)
        %{accepted: accepted} = classification = Tods.classify(parsed)
        existing = load_existing(organization_id, parsed.kind, Enum.map(accepted, & &1.id), true)
        fresh = assemble_preview(parsed.kind, accepted, existing, classification)
        fields_by_id = Map.new(accepted, &{&1.id, &1.fields})

        cond do
          fresh.errors != [] ->
            Repo.rollback({:invalid, fresh})

          not same_plan?(fresh, preview) ->
            Repo.rollback({:preview_changed, fresh})

          true ->
            write_import(
              organization_id,
              actor_id(actor),
              parsed.kind,
              existing,
              fields_by_id,
              fresh
            )
        end
      end)

    case outcome do
      {:ok, %{added: _, updated: _} = result} ->
        {:ok, result}

      {:error, {:invalid, fresh}} ->
        {:error, {:invalid, fresh}}

      {:error, {:preview_changed, fresh}} ->
        {:error, {:preview_changed, fresh}}

      {:error, :short_insert} ->
        {:error, {:preview_changed, preview_tods_import(organization_id, parsed)}}

      {:error, :forbidden} ->
        {:error, :forbidden}
    end
  end

  # --- TODS export -----------------------------------------------------------

  @doc """
  Loads the rows the TODS export files carry for the organization.

  Garages are ordered by `garage_id` and vehicles by ID length then value, which
  is the prepared `stops_supplement.txt` and `vehicles.txt` order.
  """
  @spec tods_export_rows(Ecto.UUID.t()) :: %{garages: [Garage.t()], vehicles: [Vehicle.t()]}
  def tods_export_rows(organization_id) do
    garages =
      Garage
      |> where([g], g.organization_id == ^organization_id)
      |> order_by([g], asc: g.garage_id)
      |> Repo.all()

    vehicles =
      Vehicle
      |> where([v], v.organization_id == ^organization_id)
      |> order_by([v], asc: fragment("char_length(?)", v.vehicle_id), asc: v.vehicle_id)
      |> Repo.all()

    %{garages: garages, vehicles: vehicles}
  end

  @doc """
  Counts the rows each TODS export file would carry for the organization.
  """
  @spec tods_file_inventory(Ecto.UUID.t()) :: [{String.t(), non_neg_integer()}]
  def tods_file_inventory(organization_id) do
    [
      {Tods.stops_supplement_spec().filename, count_rows(Garage, organization_id)},
      {Tods.vehicles_spec().filename, count_rows(Vehicle, organization_id)}
    ]
  end

  # --- private ---------------------------------------------------------------

  defp count_rows(schema, organization_id) do
    schema
    |> where([r], r.organization_id == ^organization_id)
    |> Repo.aggregate(:count)
  end

  # Parses the numbered-group bounds. The digit count is checked before
  # `String.to_integer/1` and before the range is built, so an over-long bound
  # allocates neither an integer nor a range.
  defp range_vehicle_ids(attrs) do
    with {:ok, first, first_digits} <- range_bound(attrs, "first"),
         {:ok, last, _last_digits} <- range_bound(attrs, "last") do
      padded_range_ids(first, last, String.length(first_digits))
    end
  end

  defp padded_range_ids(first, last, width) do
    count = last - first + 1

    cond do
      count < 1 ->
        {:error, {:invalid_range, "The last number must be the same as or after the first."}}

      count > @range_limit ->
        {:error, {:invalid_range, "Choose a numbered group of 1 to 200 vehicles."}}

      true ->
        bound_range_ids(first, last, width)
    end
  end

  defp bound_range_ids(first, last, width) do
    vehicle_ids = Enum.map(first..last, &String.pad_leading(Integer.to_string(&1), width, "0"))

    if Enum.any?(vehicle_ids, &(String.length(&1) > @max_vehicle_id_length)) do
      {:error, {:invalid_range, "Vehicle IDs must be 255 characters or fewer."}}
    else
      {:ok, vehicle_ids}
    end
  end

  defp range_bound(attrs, key) do
    case fetch_attr(attrs, key) do
      value when is_binary(value) ->
        digits = String.trim(value)

        cond do
          String.length(digits) > @max_vehicle_id_length ->
            {:error, {:invalid_range, "The first and last numbers must be at most 255 digits."}}

          Regex.match?(~r/^\d+$/, digits) ->
            {:ok, String.to_integer(digits), digits}

          true ->
            {:error, {:invalid_range, "Enter whole numbers for the first and last numbers."}}
        end

      _missing ->
        {:error, {:invalid_range, "Enter whole numbers for the first and last numbers."}}
    end
  end

  # `insert_all/3` bypasses the changeset, so every persisted field is supplied
  # here. A short insert means another writer claimed part of the range, and the
  # transaction is rolled back so no partial batch survives.
  defp insert_vehicle_range(organization_id, actor, vehicle_ids, vehicle_type_id, garage_id) do
    now = DateTime.utc_now()
    updated_by_id = actor_id(actor)

    entries =
      Enum.map(vehicle_ids, fn vehicle_id ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          vehicle_id: vehicle_id,
          vehicle_type_id: vehicle_type_id,
          garage_id: garage_id,
          updated_by_id: updated_by_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    case Repo.insert_all(Vehicle, entries, on_conflict: :nothing) do
      {count, _} when count == length(vehicle_ids) ->
        {:ok, vehicles_by_ids(organization_id, vehicle_ids)}

      {count, _} ->
        Repo.rollback({:short_insert, count, vehicle_ids})
    end
  end

  defp vehicles_by_ids(organization_id, vehicle_ids) do
    index = Map.new(Enum.with_index(vehicle_ids))

    Vehicle
    |> where([v], v.organization_id == ^organization_id and v.vehicle_id in ^vehicle_ids)
    |> Repo.all()
    |> Enum.sort_by(&Map.fetch!(index, &1.vehicle_id))
  end

  defp existing_vehicle_ids(organization_id, vehicle_ids) do
    index = Map.new(Enum.with_index(vehicle_ids))

    Vehicle
    |> where([v], v.organization_id == ^organization_id and v.vehicle_id in ^vehicle_ids)
    |> select([v], v.vehicle_id)
    |> Repo.all()
    |> Enum.sort_by(&Map.fetch!(index, &1))
  end

  # Deduplicates and casts a caller-supplied id list into one canonical, sorted
  # order; a single malformed entry fails the whole request without touching the
  # database.
  defp cast_vehicle_ids(ids) when is_list(ids) do
    case Enum.reduce_while(ids, {:ok, []}, &cast_vehicle_id/2) do
      {:ok, cast_ids} -> {:ok, cast_ids |> Enum.uniq() |> Enum.sort()}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp cast_vehicle_ids(_ids), do: {:error, :not_found}

  defp cast_vehicle_id(value, {:ok, acc}) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:cont, {:ok, [String.downcase(id) | acc]}}
      :error -> {:halt, {:error, :not_found}}
    end
  end

  # Locks every listed vehicle `FOR UPDATE` in sorted UUID order and verifies the
  # cardinality, so a missing or foreign row fails the whole request instead of
  # writing a subset.
  defp lock_vehicles(organization_id, ids) do
    locked_ids =
      Vehicle
      |> where([v], v.organization_id == ^organization_id and v.id in ^ids)
      |> order_by([v], asc: v.id)
      |> select([v], v.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    if length(locked_ids) == length(ids) do
      {:ok, locked_ids}
    else
      {:error, :not_found}
    end
  end

  defp bulk_assignment({field, value}) when field in [:vehicle_type_id, :garage_id],
    do: {:ok, field, value}

  defp bulk_assignment(_assignment), do: {:error, :not_found}

  defp assignment_schema(:vehicle_type_id), do: VehicleType
  defp assignment_schema(:garage_id), do: Garage

  defp rows_by_id(schema, organization_id, ids) do
    case ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        from(row in schema, where: row.organization_id == ^organization_id and row.id in ^ids)
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
    end
  end

  defp summary_sort_key(nil), do: {1, ""}
  defp summary_sort_key(%{name: name}), do: {0, name}

  defp fetch_vehicle(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(Vehicle, id: id, organization_id: organization_id)
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

  # Blocking's driving-time writer locks a scoped garage before the deadhead
  # row. Take that parent lock first here too, before deleting its driving
  # times or clearing orphan references.
  defp lock_garage_for_delete(organization_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.one(
          from(g in Garage,
            where: g.id == ^id and g.organization_id == ^organization_id,
            lock: "FOR UPDATE"
          )
        )

      :error ->
        nil
    end
  end

  # A garage owns its entered driving times; the guarded transaction restores
  # them with the parent when a reference refuses deletion.
  defp delete_garage_driving_times(organization_id, garage_id) do
    ref = DeadheadTimes.encode_ref({:garage, garage_id})

    DeadheadTime
    |> where([t], t.organization_id == ^organization_id)
    |> where([t], t.from_ref == ^ref or t.to_ref == ^ref)
    |> Repo.delete_all()
  end

  # One `block_attributes` row exists per service and block, so a block that
  # spans three services is named once.
  defp count_referring_blocks(organization_id, field, id) do
    organization_id
    |> referencing_block_attributes(field, id)
    |> where(^live_block_attribute())
    |> select([a], a.block_id)
    |> distinct(true)
    |> Repo.aggregate(:count, :block_id)
  end

  defp count_route_settings(organization_id, field, id) do
    organization_id
    |> referencing_route_settings(field, id)
    |> where(^live_route_setting())
    |> Repo.aggregate(:count, :id)
  end

  defp referencing_block_attributes(organization_id, field, id) do
    from(a in BlockAttribute,
      as: :attribute,
      where: a.organization_id == ^organization_id and field(a, ^field) == ^id
    )
  end

  defp referencing_route_settings(organization_id, field, id) do
    from(s in RouteOperatingSetting,
      as: :setting,
      where: s.organization_id == ^organization_id and field(s, ^field) == ^id
    )
  end

  # Rows outlive what they describe: deleting a route leaves its settings,
  # combining calendars moves trips to a new service, and unassigning trips
  # leaves the block's row. Nothing in the UI reaches such a row, so it must not
  # count as a reference. An attribute row is live while a trip in its version
  # runs that block on that service.
  defp live_block_attribute do
    dynamic(
      exists(
        from(t in Trip,
          where:
            t.organization_id == parent_as(:attribute).organization_id and
              t.gtfs_version_id == parent_as(:attribute).gtfs_version_id and
              t.service_id == parent_as(:attribute).service_id and
              t.block_id == parent_as(:attribute).block_id,
          select: 1
        )
      )
    )
  end

  # A settings row is live while its route is still in its version.
  defp live_route_setting do
    dynamic(
      exists(
        from(r in Route,
          where:
            r.organization_id == parent_as(:setting).organization_id and
              r.gtfs_version_id == parent_as(:setting).gtfs_version_id and
              r.route_id == parent_as(:setting).route_id,
          select: 1
        )
      )
    )
  end

  # The foreign keys are `NO ACTION`, so a dead row that still names the parent
  # would refuse the delete with nothing to show for it. Only the column that
  # names the parent is cleared, and live rows are left for the foreign key to
  # refuse. Runs in the delete's transaction, so a refusal restores the rows.
  defp clear_orphan_references(organization_id, attribute_field, setting_field, id) do
    organization_id
    |> referencing_block_attributes(attribute_field, id)
    |> where(^dynamic(not (^live_block_attribute())))
    |> Repo.update_all(set: [{attribute_field, nil}])

    organization_id
    |> referencing_route_settings(setting_field, id)
    |> where(^dynamic(not (^live_route_setting())))
    |> Repo.update_all(set: [{setting_field, nil}])
  end

  # Permission precedes the scoped parent read and every preparation write.
  # A refusal rolls all preparation back with the attempted delete.
  defp guarded_delete(organization_id, actor, load_fun, constraint_names, counts_fun, prepare_fun) do
    Repo.transaction(fn ->
      authorize_editor!(organization_id, actor)

      case load_fun.() do
        nil ->
          Repo.rollback(:not_found)

        parent ->
          prepare_and_delete(parent, constraint_names, counts_fun, prepare_fun)
      end
    end)
  end

  defp prepare_and_delete(parent, constraint_names, counts_fun, prepare_fun) do
    prepare_fun.(parent)

    case delete_with_in_use_guard(parent, constraint_names, fn -> counts_fun.(parent) end) do
      {:ok, deleted} -> deleted
      {:error, {:in_use, counts}} -> Repo.rollback({:in_use, counts})
    end
  end

  # The attempted delete runs in a savepoint so a constraint violation leaves
  # the connection usable, and every named constraint is translated into the
  # same `{:in_use, counts}` answer.
  defp delete_with_in_use_guard(parent, constraint_names, counts_fun) do
    changeset =
      constraint_names
      |> Enum.reduce(Ecto.Changeset.change(parent), fn name, changeset ->
        Ecto.Changeset.foreign_key_constraint(changeset, :id, name: name)
      end)

    case Repo.transaction(fn -> Repo.delete(changeset, mode: :savepoint) end) do
      {:ok, {:ok, deleted}} -> {:ok, deleted}
      {:ok, {:error, _changeset}} -> {:error, {:in_use, counts_fun.()}}
    end
  end

  defp count_vehicles(organization_id, field, id) do
    Vehicle
    |> where([v], v.organization_id == ^organization_id and field(v, ^field) == ^id)
    |> Repo.aggregate(:count, :id)
  end

  # Maps the classified accepted rows onto the organization's stored records. A
  # matching row becomes an update; a new garage without both coordinates is a
  # blocking error rather than an add. Error notes from classification and from
  # this step are merged in row order.
  defp assemble_preview(kind, accepted, existing, classification) do
    {add, update, preview_errors} =
      Enum.reduce(accepted, {[], [], []}, fn row, acc ->
        classify_preview_row(kind, row, existing, acc)
      end)

    %{
      kind: kind,
      add: Enum.reverse(add),
      update: Enum.reverse(update),
      skipped: classification.skipped,
      errors: Enum.sort_by(classification.errors ++ Enum.reverse(preview_errors), & &1.row),
      ignored_columns: classification.ignored_columns
    }
  end

  defp classify_preview_row(kind, row, existing, acc) do
    if Map.has_key?(existing, row.id) do
      update_preview_row(row.id, acc)
    else
      add_or_error_preview_row(kind, row, acc)
    end
  end

  defp update_preview_row(id, {add, update, errors}), do: {add, [id | update], errors}

  defp add_or_error_preview_row(kind, %{id: id, row: row, fields: fields}, {add, update, errors}) do
    case new_row_error(kind, fields) do
      nil -> {[id | add], update, errors}
      reason -> {add, update, [%{row: row, id: id, reason: reason} | errors]}
    end
  end

  defp new_row_error(:garages, fields) do
    if present_non_blank?(fields, :lat) and present_non_blank?(fields, :lon) do
      nil
    else
      "New garage needs stop_lat and stop_lon."
    end
  end

  defp new_row_error(:vehicles, _fields), do: nil

  defp same_plan?(fresh, preview) do
    Enum.sort(fresh.add) == Enum.sort(Map.get(preview, :add, [])) and
      Enum.sort(fresh.update) == Enum.sort(Map.get(preview, :update, []))
  end

  defp write_import(organization_id, actor_id, kind, existing, fields_by_id, fresh) do
    Enum.each(fresh.update, fn id ->
      {:ok, _record} =
        update_record(kind, Map.fetch!(existing, id), Map.fetch!(fields_by_id, id), actor_id)
    end)

    added = insert_adds(kind, organization_id, actor_id, fields_by_id, fresh.add)

    %{added: added, updated: length(fresh.update)}
  end

  defp update_record(:garages, garage, fields, actor_id) do
    garage
    |> Garage.changeset(garage_update_fields(fields))
    |> put_change(:updated_by_id, actor_id)
    |> Repo.update()
  end

  defp update_record(:vehicles, vehicle, fields, actor_id) do
    vehicle
    |> Vehicle.changeset(vehicle_update_fields(fields))
    |> put_change(:updated_by_id, actor_id)
    |> Repo.update()
  end

  # A blank or absent `stop_name`, `stop_lat` or `stop_lon` preserves the stored
  # value, so only a present, non-blank value is written.
  defp garage_update_fields(fields) do
    %{}
    |> put_non_blank_field(fields, :name)
    |> put_non_blank_field(fields, :lat)
    |> put_non_blank_field(fields, :lon)
  end

  # A present `vehicle_label` or `license_plate` is written, mapping a blank to
  # nil; an absent column is left out so the stored value is preserved.
  defp vehicle_update_fields(fields) do
    %{}
    |> put_given_field(fields, :vehicle_label)
    |> put_given_field(fields, :license_plate)
  end

  # A whitespace-only name reaches the changeset, so the garage keeps its validation error.
  defp put_non_blank_field(attrs, fields, key) do
    case Map.get(fields, key) do
      blank when blank in [nil, ""] -> attrs
      value -> Map.put(attrs, key, value)
    end
  end

  # A present key is always written, mapping blank to nil; an absent key keeps the stored value.
  defp put_given_field(attrs, fields, key) do
    case Map.fetch(fields, key) do
      {:ok, value} -> Map.put(attrs, key, Values.presence(value))
      :error -> attrs
    end
  end

  defp present_non_blank?(fields, key) do
    case Map.get(fields, key) do
      blank when blank in [nil, ""] -> false
      _value -> true
    end
  end

  defp insert_adds(_kind, _organization_id, _actor_id, _fields_by_id, []), do: 0

  defp insert_adds(:garages, organization_id, actor_id, fields_by_id, add_ids) do
    now = DateTime.utc_now()

    entries =
      Enum.map(add_ids, fn id ->
        fields = Map.fetch!(fields_by_id, id)

        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          garage_id: id,
          name: new_garage_name(id, fields),
          address: nil,
          lat: Decimal.new(Map.fetch!(fields, :lat)),
          lon: Decimal.new(Map.fetch!(fields, :lon)),
          updated_by_id: actor_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_planned(Garage, entries, length(add_ids))
  end

  defp insert_adds(:vehicles, organization_id, actor_id, fields_by_id, add_ids) do
    now = DateTime.utc_now()

    entries =
      Enum.map(add_ids, fn id ->
        fields = Map.fetch!(fields_by_id, id)

        %{
          id: Ecto.UUID.generate(),
          organization_id: organization_id,
          vehicle_id: id,
          vehicle_label: present_value(fields, :vehicle_label),
          license_plate: present_value(fields, :license_plate),
          updated_by_id: actor_id,
          inserted_at: now,
          updated_at: now
        }
      end)

    insert_planned(Vehicle, entries, length(add_ids))
  end

  # `insert_all/3` bypasses the changeset, so every persisted field is supplied
  # above; the classification already validated the ID and value rules. A short
  # insert means a concurrent writer claimed an ID after the recompute, and the
  # transaction is rolled back so no partial import survives.
  defp insert_planned(schema, entries, planned) do
    case Repo.insert_all(schema, entries, on_conflict: :nothing) do
      {count, _rows} when count == planned -> count
      {_count, _rows} -> Repo.rollback(:short_insert)
    end
  end

  defp new_garage_name(id, fields) do
    case Map.get(fields, :name) do
      blank when blank in [nil, ""] -> id
      name -> name
    end
  end

  defp present_value(fields, key) do
    case Map.fetch(fields, key) do
      {:ok, value} -> Values.presence(value)
      :error -> nil
    end
  end

  defp load_existing(_organization_id, _kind, [], _lock?), do: %{}

  defp load_existing(organization_id, :garages, ids, lock?) do
    garage_ids = Enum.uniq(ids)

    from(g in Garage, where: g.organization_id == ^organization_id and g.garage_id in ^garage_ids)
    |> lock_rows(lock?)
    |> order_by([g], asc: g.garage_id)
    |> Repo.all()
    |> Map.new(&{&1.garage_id, &1})
  end

  defp load_existing(organization_id, :vehicles, ids, lock?) do
    vehicle_ids = Enum.uniq(ids)

    from(v in Vehicle,
      where: v.organization_id == ^organization_id and v.vehicle_id in ^vehicle_ids
    )
    |> lock_rows(lock?)
    |> order_by([v], asc: v.vehicle_id)
    |> Repo.all()
    |> Map.new(&{&1.vehicle_id, &1})
  end

  defp lock_rows(query, true), do: lock(query, "FOR UPDATE")
  defp lock_rows(query, false), do: query

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

  defp authorized_write(organization_id, actor, write_fun) do
    case Repo.transaction(fn ->
           authorize_editor!(organization_id, actor)
           write_fun.()
         end) do
      {:ok, outcome} -> outcome
      {:error, :forbidden} -> {:error, :forbidden}
    end
  end

  defp authorize_editor!(organization_id, actor) do
    Authorization.lock_editor!(%{actor_id: actor_id(actor), organization_id: organization_id})
  end

  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil

  # The holder is read before the write, the way `Rosters.assign_operator/3`
  # reads the line an operator already holds: an insert that violates the unique
  # index leaves a failed transaction behind, and this refusal is one scoped read
  # that never fails. The index still rejects a concurrent insert that claimed
  # the ID between the read and the write; that write keeps Ecto's own message.
  #
  # The sentence names the ID as well as the holder, because the editor is
  # looking at a form and the ID they typed is what tells them *which* of their
  # own entries collided. "is already used by Aurelia Nowak." alone leaves them
  # to work out what it is about.
  defp refuse_employee_id(changeset, organization_id, operator_id) do
    employee_id = Ecto.Changeset.get_field(changeset, :employee_id)

    holder =
      changeset.valid? and is_binary(employee_id) and employee_id != "" and
        employee_id_holder(organization_id, employee_id, operator_id)

    if holder,
      do:
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :employee_id,
           "#{employee_id} is already used by #{holder.display_name}."
         )},
      else: {:ok, changeset}
  end

  defp employee_id_holder(organization_id, employee_id, operator_id) do
    Operator
    |> where([o], o.organization_id == ^organization_id and o.employee_id == ^employee_id)
    |> exclude_operator(operator_id)
    |> Repo.one()
  end

  defp exclude_operator(query, nil), do: query
  defp exclude_operator(query, operator_id), do: where(query, [o], o.id != ^operator_id)
end

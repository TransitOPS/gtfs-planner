defmodule GtfsPlanner.Gtfs.Flex do
  @moduledoc """
  Authored flex services and their areas, scoped to one organization and one
  published version (R10, CR-6).

  `copy_from_version/4` carries every service of another published version of
  the same organization, with its areas and their geometry, into a version that
  has none (R14).

  A service is created with a stable R11 key derived from its name and is
  renamed without changing that key. `save_service/5` is the service page's one
  Save: it applies the service changeset with its `lock_version` and replaces
  the service's areas by key in the same transaction, so a page save is one
  all-or-nothing write and a save built from a struct another editor already
  replaced answers `{:error, :stale}` and writes nothing (FH-8). Areas carry
  their geometry through `GtfsPlanner.Gtfs.Flex.Geometry` only, so a
  `:route_distance` area stores no geometry (R8). Nothing here writes `trips`
  or `stop_times` (R1, CR-4).

  Every read and every write filters on the organization and a published
  version of it. A service of another organization or version never resolves, a
  staging version lists nothing and answers `{:error, :not_found}` to a read,
  and a write against one answers `{:error, :version_unavailable}`. Each write
  takes the version's input-write lock (`Versions.lock_for_input_write!/2`)
  before touching any row, so it serializes with the version's other input
  writers; the caller's struct still carries the `lock_version` that decides
  the `:stale` outcome.

  Areas are replaced by key: an input whose key is already stored is updated, a
  new key is inserted, and a stored area whose key is absent from the input is
  deleted. The input order is the stored `position` (1-based), which is the
  order the list and the generated area IDs use.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"
  @slug_separator ~r/[^a-z0-9]+/

  # Internal rollback reason for a service that is not in the scoped version;
  # `transact/3` turns it into `:not_found` (see there).
  @service_missing :service_missing

  # The area fields a save may write besides its position; scope fields are set
  # on the struct, never cast (INV-4).
  @area_fields [
    :key,
    :name,
    :source,
    :census_geoid,
    :census_layer,
    :census_vintage,
    :route_ids,
    :distance_m
  ]

  @typedoc """
  One area of a service page draft: `%{key, name, source, geojson, census_geoid,
  census_layer, census_vintage, route_ids, distance_m}`. `geojson` is the
  drawn, Census or imported polygon (or a `FlexArea` struct with that key
  added); a `:route_distance` area sends none, and its stored geometry is
  cleared.
  """
  @type area_input :: map()

  # --- reads ------------------------------------------------------------------

  @doc """
  Lists the version's services, each with its areas in position order.

  Active and inactive services are both listed, so the Flex list can show each
  one's state; the order is by name and then id.
  """
  @spec list_services(Ecto.UUID.t(), Ecto.UUID.t()) :: [FlexService.t()]
  def list_services(organization_id, version_id) do
    organization_id
    |> published_services(version_id)
    |> order_by([s], asc: s.name, asc: s.id)
    |> preload([s], :areas)
    |> Repo.all()
  end

  @doc """
  Returns one service of the version with its areas in position order.

  An unknown id, a malformed id, another organization's or version's service,
  and a service of a version that is not published all answer
  `{:error, :not_found}`.
  """
  @spec get_service(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, FlexService.t()} | {:error, :not_found}
  def get_service(organization_id, version_id, id) do
    case scoped_service(organization_id, version_id, id) do
      nil ->
        {:error, :not_found}

      service ->
        {:ok,
         %{service | areas: areas_in_position_order(organization_id, version_id, service.id)}}
    end
  end

  # --- writes -----------------------------------------------------------------

  @doc """
  Creates a service in the version with a key derived from the name.

  The key is the slugified name (`"Newport Dial-a-Ride"` → `"newport-dial-a-ride"`)
  and is unique in the version, with `-2`, `-3`… suffixes when the name is
  already taken. Another version or organization with the same name takes the
  unsuffixed key, because keys are per version. The request's own `key`
  parameter, if any, is ignored: R11 derives the key here.

  Returns `{:error, :version_unavailable}` for a version the organization does
  not own or that is not published, and the changeset's errors (a missing name
  or kind, a detour without a route, a name that slugs to nothing) otherwise.
  """
  @spec create_service(Ecto.UUID.t(), Ecto.UUID.t(), map()) ::
          {:ok, FlexService.t()} | {:error, :version_unavailable | Ecto.Changeset.t()}
  def create_service(organization_id, version_id, attrs) do
    attrs = Map.new(attrs)

    transact(organization_id, version_id, fn ->
      attrs = put_derived_key(attrs, next_key(organization_id, version_id, attr(attrs, :name)))

      %FlexService{organization_id: organization_id, gtfs_version_id: version_id}
      |> FlexService.create_changeset(attrs)
      |> insert_service!()
    end)
  end

  @doc """
  Saves the service page: the service row and its areas in one transaction.

  `loaded` is the struct the editor loaded; its `lock_version` decides the
  conflict. When another editor saved first, the update touches no row and the
  answer is `{:error, :stale}` with nothing written, so the caller can keep its
  draft and offer to merge or reload.

  `area_inputs` is the whole draft list in display order. Each input is matched
  to a stored area by `key`: a stored key is updated, a new key is inserted, and
  a stored area whose key is not in the list is deleted with its geometry. The
  input index is the stored `position`. A present `geojson` runs through
  `Flex.Geometry.normalize/1` and is written; when normalisation fails the whole
  save rolls back with `{:error, {:invalid_area, key, reason}}`. An input
  without `geojson` has its stored geometry cleared, so a `:route_distance` area
  never keeps a polygon.

  Returns `{:error, :version_unavailable}` for a version the organization does
  not own or that is not published, `{:error, :stale}` for a miss or a lost
  race, and the changeset's errors for attrs or areas the editor changesets
  refuse.
  """
  @spec save_service(Ecto.UUID.t(), Ecto.UUID.t(), FlexService.t(), map(), [area_input()]) ::
          {:ok, FlexService.t()}
          | {:error,
             :stale
             | :version_unavailable
             | Ecto.Changeset.t()
             | {:invalid_area, String.t(), term()}}
  def save_service(organization_id, version_id, %FlexService{} = loaded, attrs, area_inputs)
      when is_list(area_inputs) do
    transact(organization_id, version_id, fn ->
      case scoped_service(organization_id, version_id, loaded.id) do
        nil ->
          Repo.rollback(:stale)

        %FlexService{} ->
          loaded
          |> FlexService.changeset(attrs)
          |> update_service!()
          |> replace_areas!(organization_id, version_id, area_inputs)
      end
    end)
  end

  @doc """
  Sets one service's `active` flag, keeping everything else.

  Deactivating leaves the service's hours, booking rules and areas in place;
  only the export leaves an inactive service out. A whole-page save that landed
  first makes the flag change `{:error, :stale}`, so the caller can reload and
  retry.
  """
  @spec set_active(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, FlexService.t()} | {:error, :not_found | :stale | :version_unavailable}
  def set_active(organization_id, version_id, id, active) when is_boolean(active) do
    transact(organization_id, version_id, fn ->
      case scoped_service(organization_id, version_id, id) do
        nil ->
          Repo.rollback(@service_missing)

        service ->
          updated =
            service
            |> FlexService.changeset(%{active: active})
            |> update_service!()

          %{updated | areas: areas_in_position_order(organization_id, version_id, updated.id)}
      end
    end)
  end

  @doc """
  Deletes one service and its areas.

  The areas go with the service through the `flex_areas` foreign key's
  `ON DELETE CASCADE`. An unknown, foreign or unpublished service answers
  `{:error, :not_found}` and writes nothing.
  """
  @spec delete_service(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :not_found | :version_unavailable}
  def delete_service(organization_id, version_id, id) do
    case transact(organization_id, version_id, fn ->
           delete_scoped_service(organization_id, version_id, id)
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_scoped_service(organization_id, version_id, id) do
    case scoped_service(organization_id, version_id, id) do
      nil ->
        Repo.rollback(@service_missing)

      service ->
        %FlexService{} = Repo.delete!(service)
        :ok
    end
  end

  # --- copying ----------------------------------------------------------------

  @doc """
  Copies every service and its areas, geometry included, into an empty version.

  The source must be this organization's published version (R14, CR-6) and the
  target must be this organization's published version with no services yet.
  Each copied service keeps its key, name, hours, booking rules and detour or
  area fields, and starts a fresh row with a new id and `lock_version` 1. The
  areas are copied per service through `Flex.Geometry.copy_areas/4`, so their
  stored polygons are copied in SQL and a drawn area keeps the same shape under
  `ST_Equals` while a `:route_distance` area stays without geometry.

  Answers `{:ok, count}` with the number of services copied — `{:ok, 0}` when
  the source has none — `{:error, :target_not_empty}` when the target already
  has a service (active or inactive), and `{:error, :not_found}` when either
  version does not belong to the organization, is not published, or the source
  id is malformed. The whole copy is one transaction: a failure leaves the
  target as it was.

  References that the target version cannot resolve — a route, stop or calendar
  that exists only in the source version — are copied as they are; readiness
  reports them in the target as ordinary errors (R14).

  `actor` is the §4 contract's actor argument; flex authoring records no audit
  actor, so it is accepted and not persisted.
  """
  @spec copy_from_version(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), map() | nil) ::
          {:ok, non_neg_integer()} | {:error, :target_not_empty | :not_found}
  def copy_from_version(organization_id, target_version_id, source_version_id, _actor) do
    result =
      Repo.transaction(fn ->
        case Versions.lock_for_input_write!(organization_id, target_version_id) do
          %GtfsVersion{publication_status: @published_status} ->
            copy_version_services!(organization_id, target_version_id, source_version_id)

          # A version that is not published cannot be authored (R10), so it is
          # as unavailable to the copy as a version the organization does not
          # own, which the lock already rolls back as `:not_found`.
          %GtfsVersion{} ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, count} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end

  # R14: every service and its areas into the empty target. The source version
  # is resolved first, services are inserted one by one so each area copy can be
  # fenced to the source version, and the areas themselves never enter Elixir
  # (CR-1).
  defp copy_version_services!(organization_id, target_version_id, source_version_id) do
    case published_version(organization_id, source_version_id) do
      nil ->
        Repo.rollback(:not_found)

      %GtfsVersion{} = source_version ->
        if version_has_services?(organization_id, target_version_id) do
          Repo.rollback(:target_not_empty)
        end

        organization_id
        |> published_services(source_version.id)
        |> Repo.all()
        |> Enum.map(&copy_service!(&1, organization_id, target_version_id, source_version.id))
        |> length()
    end
  end

  defp copy_service!(source, organization_id, target_version_id, source_version_id) do
    copied = insert_copied_service!(source, organization_id, target_version_id)
    :ok = Geometry.copy_areas(source.id, copied.id, organization_id, source_version_id)
    copied
  end

  # The service row is copied field for field, hours and booking rules
  # included, with the target's scope, a new id and a fresh lock_version; the
  # row is new, so it also gets its own timestamps.
  defp insert_copied_service!(source, organization_id, target_version_id) do
    %{
      source
      | id: nil,
        organization_id: organization_id,
        gtfs_version_id: target_version_id,
        lock_version: 1,
        inserted_at: nil,
        updated_at: nil
    }
    |> Repo.insert!()
  end

  defp version_has_services?(organization_id, version_id) do
    from(s in FlexService,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id,
      select: true,
      limit: 1
    )
    |> Repo.exists?()
  end

  # The source version must be this organization's and published; a missing,
  # foreign, staging or malformed id is absent, so the copy reads no source row.
  defp published_version(organization_id, version_id) do
    case Ecto.UUID.cast(version_id) do
      {:ok, source_version_id} ->
        from(v in GtfsVersion,
          where:
            v.id == ^source_version_id and v.organization_id == ^organization_id and
              v.publication_status == ^@published_status
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  # --- scoped queries ---------------------------------------------------------

  # One service of the organization and version, or nil. The id is cast first,
  # so a route parameter that is not a UUID is a miss rather than a cast error.
  defp scoped_service(organization_id, version_id, id) do
    case Ecto.UUID.cast(id) do
      {:ok, service_id} ->
        organization_id
        |> published_services(version_id)
        |> where([s], s.id == ^service_id)
        |> Repo.one()

      :error ->
        nil
    end
  end

  # The version's services, scoped to the organization and to a version of it
  # that is published (R10, INV-4). The version join is also the publication
  # filter, so a staging version has no services here.
  defp published_services(organization_id, version_id) do
    from(s in FlexService,
      join: v in GtfsVersion,
      on: v.id == s.gtfs_version_id and v.organization_id == s.organization_id,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
          v.publication_status == ^@published_status
    )
  end

  defp stored_areas(organization_id, version_id, flex_service_id) do
    from(a in FlexArea,
      where:
        a.flex_service_id == ^flex_service_id and a.organization_id == ^organization_id and
          a.gtfs_version_id == ^version_id
    )
    |> Repo.all()
    |> Map.new(&{&1.key, &1})
  end

  defp areas_in_position_order(organization_id, version_id, flex_service_id) do
    from(a in FlexArea,
      where:
        a.flex_service_id == ^flex_service_id and a.organization_id == ^organization_id and
          a.gtfs_version_id == ^version_id,
      order_by: [asc: a.position]
    )
    |> Repo.all()
  end

  # --- write steps ------------------------------------------------------------

  # Every write opens with the version's input-write lock. A pair the
  # organization does not own, or one that is not a version at all, rolls back
  # `:not_found` and answers `:version_unavailable`; a version that is not
  # published cannot be authored (R10).
  defp transact(organization_id, version_id, fun) do
    result =
      Repo.transaction(fn ->
        case Versions.lock_for_input_write!(organization_id, version_id) do
          %GtfsVersion{publication_status: @published_status} -> fun.()
          %GtfsVersion{} -> Repo.rollback(:version_unavailable)
        end
      end)

    case result do
      {:ok, value} -> {:ok, value}
      # The lock helper decides "not the organization's version" with a
      # `:not_found` rollback, which is this context's `:version_unavailable`.
      # Service misses roll back @service_missing instead, so the two cannot be
      # confused.
      {:error, :not_found} -> {:error, :version_unavailable}
      {:error, @service_missing} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_service!(changeset) do
    case Repo.insert(changeset) do
      {:ok, service} -> Repo.preload(service, :areas)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # The changeset's `optimistic_lock` makes the update conditional on the
  # caller's lock_version: a row another editor replaced matches nothing and
  # Ecto raises StaleEntryError, which is this context's `:stale`.
  defp update_service!(changeset) do
    case Repo.update(changeset) do
      {:ok, service} -> service
      {:error, changeset} -> Repo.rollback(changeset)
    end
  rescue
    Ecto.StaleEntryError -> Repo.rollback(:stale)
  end

  defp replace_areas!(service, organization_id, version_id, inputs) do
    stored = stored_areas(organization_id, version_id, service.id)

    inputs
    |> Enum.with_index(1)
    |> Enum.each(fn {input, position} ->
      write_area!(service, organization_id, version_id, stored, input, position)
    end)

    delete_absent_areas!(service, organization_id, version_id, inputs)

    # The caller's loaded struct may carry its pre-save areas, and Repo.preload
    # leaves an already-loaded association alone, so the returned service takes
    # the areas the save just wrote, in position order.
    %{service | areas: areas_in_position_order(organization_id, version_id, service.id)}
  end

  defp write_area!(service, organization_id, version_id, stored, input, position) do
    attrs =
      input
      |> Map.take(@area_fields)
      |> Map.put(:position, position)

    area =
      case Map.get(stored, Map.get(input, :key)) do
        nil -> insert_area!(service, organization_id, version_id, attrs)
        %FlexArea{} = existing -> update_area!(existing, attrs)
      end

    write_area_geom!(area, Map.get(input, :geojson))
  end

  defp insert_area!(service, organization_id, version_id, attrs) do
    %FlexArea{
      flex_service_id: service.id,
      organization_id: organization_id,
      gtfs_version_id: version_id
    }
    |> FlexArea.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, area} -> area
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp update_area!(area, attrs) do
    area
    |> FlexArea.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, area} -> area
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # Geometry never leaves Flex.Geometry: the context passes the draft's GeoJSON
  # in and receives the storage verdict. An input without geometry clears the
  # stored one, so a `:route_distance` area stores no polygon (R8).
  defp write_area_geom!(area, nil) do
    case Geometry.put_geom(area.id, nil) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:invalid_area, area.key, reason})
    end
  end

  defp write_area_geom!(area, geojson) do
    with {:ok, %{geojson: normalized}} <- Geometry.normalize(geojson),
         :ok <- Geometry.put_geom(area.id, normalized) do
      :ok
    else
      {:error, reason} -> Repo.rollback({:invalid_area, area.key, reason})
    end
  end

  defp delete_absent_areas!(service, organization_id, version_id, inputs) do
    keys =
      inputs
      |> Enum.map(&Map.get(&1, :key))
      |> Enum.reject(&is_nil/1)

    from(a in FlexArea,
      where:
        a.flex_service_id == ^service.id and a.organization_id == ^organization_id and
          a.gtfs_version_id == ^version_id and a.key not in ^keys
    )
    |> Repo.delete_all()
  end

  # --- keys -------------------------------------------------------------------

  # R11: the slugified name, made unique in the version with -2, -3… suffixes.
  defp next_key(organization_id, version_id, name) do
    base = slugify(name)
    taken = version_keys(organization_id, version_id)

    if MapSet.member?(taken, base), do: suffixed_key(base, taken), else: base
  end

  defp suffixed_key(base, taken) do
    Stream.iterate(2, &(&1 + 1))
    |> Enum.find_value(fn suffix ->
      candidate = "#{base}-#{suffix}"
      if MapSet.member?(taken, candidate), do: nil, else: candidate
    end)
  end

  defp version_keys(organization_id, version_id) do
    from(s in FlexService,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id,
      select: s.key
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp slugify(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(@slug_separator, "-")
    |> String.trim("-")
  end

  defp slugify(_name), do: ""

  # The derived key wins over any key the request carried; a form must not be
  # able to pick or move a service's stable identifier. The key is written in
  # the attrs' own convention, because Ecto refuses a map with mixed atom and
  # string keys.
  defp put_derived_key(attrs, key) do
    attrs =
      attrs
      |> Map.delete(:key)
      |> Map.delete("key")

    if Enum.any?(Map.keys(attrs), &is_binary/1) do
      Map.put(attrs, "key", key)
    else
      Map.put(attrs, :key, key)
    end
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end
end

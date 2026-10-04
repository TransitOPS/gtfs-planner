defmodule GtfsPlanner.Gtfs.Flex do
  @moduledoc """
  Authored flex services and their areas, scoped to one organization and one
  published version (R10, CR-6).

  `copy_from_version/2` carries every service of another published version of
  the same organization, with its areas and their geometry, into a version that
  has none (R14).

  A service is created with a stable R11 key derived from its name and is
  renamed without changing that key. `save_service/4` is the service page's one
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
  checks the actor's current editor membership inside its transaction before
  taking the version's input-write lock (`Versions.lock_for_input_write!/2`).
  This serializes with the version's other input writers; the caller's struct
  still carries the `lock_version` that decides the `:stale` outcome.

  `save_service/5` is the same whole-page save fenced for an assistant-reviewed
  candidate. It is the only writer that takes the version row
  `FOR UPDATE` (`Versions.lock_for_exclusive_write!/2`) instead, at the same
  point in the transaction, and under that fence it re-reads the saved service,
  its areas and geometry and every calendar its stored fields name, and
  re-checks both the reviewed baseline fingerprint and the reviewed whole-page
  digest before the first write. A dependency or a page that moved since the
  review rolls back as `{:error, :assistant_stale}` with nothing written. See
  `GtfsPlanner.Gtfs.Flex.Assistant.Guard` for what such a guard carries.

  `map_payload/2` is the read the browser's flex maps draw from: the active
  services' stored geometry, the version's fixed route lines and its connecting
  stops, all through the same scoped reads and through
  `GtfsPlanner.Gtfs.Flex.Geometry` for the geometry itself (INV-1).

  Areas are replaced by key: an input whose key is already stored is updated, a
  new key is inserted, and a stored area whose key is absent from the input is
  deleted. The input order is the stored `position` (1-based), which is the
  order the list and the generated area IDs use.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.CalendarAttribute
  alias GtfsPlanner.Gtfs.Flex.Assistant
  alias GtfsPlanner.Gtfs.Flex.Geometry
  alias GtfsPlanner.Gtfs.FlexArea
  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.Shape
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"
  @slug_separator ~r/[^a-z0-9]+/

  # Internal rollback reason for a service that is not in the scoped version;
  # `transact/2` turns it into `:not_found` (see there).
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

  @typedoc """
  One route the create drawer's detour select and the area editor's routes panel
  offer: `%{id: route_id, name: "20 Valley Line"}`, plus the parts the editor's
  reusable badge draws (`short_name`, `long_name`, `color`).
  """
  @type route_choice :: %{
          id: String.t(),
          name: String.t(),
          short_name: String.t() | nil,
          long_name: String.t() | nil,
          color: String.t() | nil
        }

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
  The calendars map `RiderText` reads for the version:
  `%{service_id => %{name: name, plural: plural}}`.

  The singular name is the calendar attribute's `service_schedule_name` and the
  plural its `service_description`, each falling back to the other and then to
  the calendar's service ID, so a version without `calendar_attributes` words
  its rider text with its own IDs. A calendar with no attribute row is absent
  from the map; `RiderText` falls back to its service ID for it, so the export
  and the Flex pages word the same calendar the same way.

  The read is scoped to the organization and version (R10), like every other
  flex read.
  """
  @spec calendars_map(Ecto.UUID.t(), Ecto.UUID.t()) :: %{
          optional(String.t()) => %{name: String.t(), plural: String.t()}
        }
  def calendars_map(organization_id, version_id) do
    from(a in CalendarAttribute,
      where: a.organization_id == ^organization_id and a.gtfs_version_id == ^version_id,
      select: %{
        service_id: a.service_id,
        schedule_name: a.service_schedule_name,
        description: a.service_description
      }
    )
    |> Repo.all()
    |> Map.new(fn attribute ->
      name =
        non_empty_or(
          attribute.schedule_name,
          non_empty_or(attribute.description, attribute.service_id)
        )

      {attribute.service_id, %{name: name, plural: non_empty_or(attribute.description, name)}}
    end)
  end

  @typedoc """
  The payload the `FlexAreaMap` hook draws for one version.

  `areas` are the active services' stored areas: each carries the area's own
  id and the R8 GeoJSON `GtfsPlanner.Gtfs.Flex.Geometry.get_geojson/1` reads for
  it. An area with no stored geometry — a `:route_distance` area until the
  export derives it — is absent, so the map draws exactly what is stored. The
  service page adds `role`: `"selected"` for the service on screen and
  `"other"` for the other active services it draws muted.

  `routes` is one line per fixed route of the version that has at least two
  points, in `route_id` order: the shape the route's trips use most, or, for a
  route whose trips name no shape, straight lines between the stops of its
  first trip (R13's rule for a pattern without a shape). `coordinates` are
  `[lon, lat]`, the order `Geometry`'s GeoJSON uses and the order
  `assets/js/alignment_geometry.js`'s `toLatLng/1` converts; `color` is the
  route's own colour, or `nil` for the map's fallback.

  `stops` are the connecting stops the services name, each with the coordinates
  the map draws it at and `hub: true`; a service page draws its own, so the
  list's map and the service's map read the same stop shape.
  """
  @type map_area :: %{
          optional(:role) => String.t(),
          id: Ecto.UUID.t() | String.t(),
          geojson: map()
        }

  @type map_payload :: %{
          areas: [map_area()],
          routes: [%{id: String.t(), color: String.t() | nil, coordinates: [[float()]]}],
          stops: [%{id: String.t(), name: String.t(), lon: float(), lat: float(), hub: boolean()}]
        }

  @doc """
  Builds the map payload the version's flex map draws.

  This is a read for the browser, so it composes the same scoped reads the Flex
  pages use: `list_services/2` for the services and their areas (so an inactive
  service contributes nothing) and `Geometry.get_geojson/1` for their stored
  geometry (R8, INV-1). The feed rows the map draws — the version's fixed
  routes, the shapes their trips name and the stops they serve — are read the
  way the app's other feed reads are: scoped to the organization and version,
  with no publication filter. The page that renders the map only ever shows a
  published version of the current organization (R10, INV-4).

  A version with no flex service still gets its fixed route lines: the map
  card's own empty state is "Fixed routes in this version".
  """
  @spec map_payload(Ecto.UUID.t(), Ecto.UUID.t()) :: map_payload()
  def map_payload(organization_id, version_id) do
    active = organization_id |> list_services(version_id) |> Enum.filter(& &1.active)

    %{
      areas: map_areas(active),
      routes: map_routes(organization_id, version_id),
      stops: map_stops(organization_id, version_id, active)
    }
  end

  @doc """
  Builds the map payload the service page's map card draws.

  This is the same version payload `map_payload/2` builds, with the areas
  re-roled for one service: the service's own stored areas are `"selected"`,
  and every other active service's area is `"other"`, which the hook draws
  muted. A detour service stores no area of its own, so its derived zones
  (`Geometry.detour_zones/3`) take the selected role; a service whose geometry
  cannot be derived yet simply has none, exactly as the list's map shows it.
  The stops are the service's own connecting stops, so the card labels the
  stops this service names rather than every hub in the version.
  """
  @spec service_map_payload(Ecto.UUID.t(), Ecto.UUID.t(), FlexService.t()) :: map_payload()
  def service_map_payload(organization_id, version_id, %FlexService{} = service) do
    base = map_payload(organization_id, version_id)
    own_ids = service.areas |> Enum.map(& &1.id) |> MapSet.new()

    others =
      base.areas
      |> Enum.reject(&MapSet.member?(own_ids, &1.id))
      |> Enum.map(&Map.put(&1, :role, "other"))

    %{
      base
      | areas: selected_areas(organization_id, version_id, service) ++ others,
        stops: map_stops(organization_id, version_id, [service])
    }
  end

  # The service's own geometry with the selected role: its stored areas, or, for
  # a detour service, the zones R13 derives for its stretch. Both go through
  # `Geometry` (INV-1); a service whose geometry is not derivable yet contributes
  # nothing rather than an empty shape.
  defp selected_areas(organization_id, version_id, %FlexService{kind: :detour} = service) do
    case Geometry.detour_zones(organization_id, version_id, service) do
      {:ok, zones} ->
        Enum.map(zones, fn zone ->
          %{id: zone.zone_id, geojson: zone.geojson, role: "selected"}
        end)

      {:error, _reason} ->
        []
    end
  end

  defp selected_areas(_organization_id, _version_id, %FlexService{} = service) do
    geojson = Geometry.get_geojson(Enum.map(service.areas, & &1.id))

    Enum.flat_map(service.areas, fn area ->
      case Map.fetch(geojson, area.id) do
        {:ok, shape} -> [%{id: area.id, geojson: shape, role: "selected"}]
        :error -> []
      end
    end)
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

  @doc """
  The version's routes as the create drawer's detour choices, in `route_id`
  order: `%{id: route_id, name: "20 Valley Line"}`.

  The name joins the route's short and long names, whichever the version has; a
  route with neither is named by its own `route_id`. The read is scoped to the
  organization and version (R10), like the rest of the reads the Flex pages
  compose.
  """
  @spec route_choices(Ecto.UUID.t(), Ecto.UUID.t()) :: [route_choice()]
  def route_choices(organization_id, version_id) do
    from(r in Route,
      where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id,
      order_by: [asc: r.route_id],
      select: {r.route_id, r.route_short_name, r.route_long_name, r.route_color}
    )
    |> Repo.all()
    |> Enum.map(fn {route_id, short_name, long_name, color} ->
      %{
        id: route_id,
        name: route_name(route_id, short_name, long_name),
        short_name: short_name,
        long_name: long_name,
        color: route_color(color)
      }
    end)
  end

  @doc """
  The bounding box of the version's stops that have coordinates, as
  `{west, south, east, north}`, or `nil` when no stop of the version has both.

  The area editor asks TIGERweb for the places intersecting this box, so the
  version's own extent bounds the picker's list (AC-10). A version without stops
  answers `nil`, which is the editor's name-and-state search instead. The read is
  scoped to the organization and version (R10).
  """
  @spec stop_extent(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {float(), float(), float(), float()} | nil
  def stop_extent(organization_id, version_id) do
    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
          not is_nil(s.stop_lon) and not is_nil(s.stop_lat),
      select: {min(s.stop_lon), min(s.stop_lat), max(s.stop_lon), max(s.stop_lat)}
    )
    |> Repo.one()
    |> case do
      {nil, nil, nil, nil} ->
        nil

      {west, south, east, north} ->
        {Values.to_float(west), Values.to_float(south), Values.to_float(east),
         Values.to_float(north)}
    end
  end

  # The name riders read in the create drawer's select. A version that carries
  # only one of the two names (or neither) still gets one label per route.
  defp route_name(route_id, short_name, long_name) do
    case Enum.reject([short_name, long_name], &Values.blank?/1) do
      [] -> route_id
      names -> Enum.join(names, " ")
    end
  end

  @typedoc """
  One stop the service page offers, as `{name, stop_id}`: the label a select
  shows and the natural ID a save writes. A stop the feed left unnamed is
  labelled by its own ID, like the map's stop labels.
  """
  @type stop_choice :: {String.t(), String.t()}

  @typedoc """
  What the service page's where section reads for a detour service: the stops
  its route visits in pattern order, and how many of the route's trips each
  calendar runs.
  """
  @type route_facts :: %{
          stops: [stop_choice()],
          trip_counts: %{String.t() => non_neg_integer()}
        }

  @doc """
  The version's stops as the service page's connecting-stop choices, in name
  order: `[{name, stop_id}]`.

  Every stop of the version is offered, including one without coordinates: a
  connecting stop is a reference in `location_group_stops.txt`, not a map
  point. The read is scoped to the organization and version (R10), like the
  rest of the reads the Flex pages compose.
  """
  @spec stop_choices(Ecto.UUID.t(), Ecto.UUID.t()) :: [stop_choice()]
  def stop_choices(organization_id, version_id) do
    from(s in Stop,
      where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id,
      order_by: [asc: s.stop_name, asc: s.stop_id],
      select: {s.stop_id, s.stop_name}
    )
    |> Repo.all()
    |> Enum.map(fn {stop_id, name} -> {Values.presence(name) || stop_id, stop_id} end)
  end

  @doc """
  The stops a detour service's route visits, in pattern order, and the route's
  trip count per calendar.

  `stops` is the first pattern's stops by direction, pattern sort order and
  position, deduplicated in visit order, so the two stretch selects offer the
  stops the detour derivation (`Flex.Geometry.detour_zones/3`) reads between.
  A route pattern that names a stop this version does not have still offers
  that stop, labelled by its ID, because readiness reports it as an error the
  editor can see.

  `trip_counts` counts the route's trips per `service_id`, which is what the
  detour calendar checkboxes and the export plan say each calendar covers. A
  service without a route, or a route with no patterns, answers empty choices.

  The reads are scoped to the organization and version (R10).
  """
  @spec route_facts(Ecto.UUID.t(), Ecto.UUID.t(), FlexService.t()) :: route_facts()
  def route_facts(organization_id, version_id, %FlexService{route_id: route_id})
      when is_binary(route_id) and route_id != "" do
    %{
      stops: route_stop_choices(organization_id, version_id, route_id),
      trip_counts: route_trip_counts(organization_id, version_id, route_id)
    }
  end

  def route_facts(_organization_id, _version_id, %FlexService{}),
    do: %{stops: [], trip_counts: %{}}

  defp route_stop_choices(organization_id, version_id, route_id) do
    from(o in RoutePatternStop,
      join: p in RoutePattern,
      on: p.id == o.route_pattern_id,
      left_join: s in Stop,
      on:
        s.organization_id == p.organization_id and s.gtfs_version_id == p.gtfs_version_id and
          s.stop_id == o.stop_id,
      where:
        p.organization_id == ^organization_id and p.gtfs_version_id == ^version_id and
          p.route_id == ^route_id,
      order_by: [
        asc: p.direction_id,
        asc: p.route_pattern_sort_order,
        asc: p.route_pattern_id,
        asc: o.position
      ],
      select: {o.stop_id, s.stop_name}
    )
    |> Repo.all()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.map(fn {stop_id, name} -> {Values.presence(name) || stop_id, stop_id} end)
  end

  defp route_trip_counts(organization_id, version_id, route_id) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id == ^route_id,
      group_by: t.service_id,
      select: {t.service_id, count(t.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The ids of the organization's versions that hold at least one flex service.

  The copy action offers only these versions as sources: R14 copies a version's
  whole set of services into an empty version, so a version with none is not a
  source, and offering it would only produce an empty copy. The read is scoped
  to the organization (R10) and spans versions, like the copy itself.
  """
  @spec version_ids_with_services(Ecto.UUID.t()) :: MapSet.t(Ecto.UUID.t())
  def version_ids_with_services(organization_id) do
    from(s in FlexService,
      where: s.organization_id == ^organization_id,
      select: s.gtfs_version_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # --- writes -----------------------------------------------------------------

  @doc """
  Creates a service in the version with a key derived from the name.

  The key is the slugified name (`"Newport Dial-a-Ride"` → `"newport-dial-a-ride"`)
  and is unique in the version, with `-2`, `-3`… suffixes when the name is
  already taken. Another version or organization with the same name takes the
  unsuffixed key, because keys are per version. The request's own `key`
  parameter, if any, is ignored: R11 derives the key here.

  Returns `{:error, :forbidden}` when the actor is no longer an editor,
  `{:error, :version_unavailable}` for a version the organization does not own
  or that is not published, and the changeset's errors (a missing name or kind,
  a detour without a route, a name that slugs to nothing) otherwise.
  """
  @spec create_service(AuditContext.t(), map()) ::
          {:ok, FlexService.t()}
          | {:error, :forbidden | :version_unavailable | Ecto.Changeset.t()}
  def create_service(%AuditContext{} = audit, attrs) do
    attrs = Map.new(attrs)
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    transact(audit, fn ->
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

  Returns `{:error, :forbidden}` for a revoked editor,
  `{:error, :version_unavailable}` for a version the organization does not own
  or that is not published, `{:error, :stale}` for a miss or a lost race, and
  the changeset's errors for attrs or areas the editor changesets refuse.

  This is the ordinary whole-page save. An assistant-reviewed save is
  `save_service/5`, which fences the same write differently.
  """
  @spec save_service(AuditContext.t(), FlexService.t(), map(), [area_input()]) ::
          {:ok, FlexService.t()}
          | {:error,
             :stale
             | :forbidden
             | :version_unavailable
             | Ecto.Changeset.t()
             | {:invalid_area, String.t(), term()}}
  def save_service(%AuditContext{} = audit, %FlexService{} = loaded, attrs, area_inputs)
      when is_list(area_inputs) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    transact(audit, fn ->
      case scoped_service(organization_id, version_id, loaded.id) do
        nil ->
          Repo.rollback(:stale)

        %FlexService{} ->
          write_service!(loaded, organization_id, version_id, attrs, area_inputs)
      end
    end)
  end

  @doc """
  Saves the service page against a reviewed assistant guard, or writes nothing.

  The options map is exactly `%{assistant_guard: guard}`, where `guard` is a
  `GtfsPlanner.Gtfs.Flex.Assistant.Guard` the server built after an editor
  reviewed a prepared candidate. No other options are accepted and no guard is
  ever read from a client payload: an options map that is not a well-built guard
  answers `{:error, :assistant_stale}` and writes nothing, because a save that
  cannot prove the state it was reviewed against must not persist.

  The write itself is `save_service/4`'s. What changes is the fence and the two
  checks that run under it:

    * The transaction takes the scoped version row `FOR UPDATE` at entry, after
      the membership check and before any entity read, instead of the `FOR SHARE`
      lock an ordinary save takes. It never takes the share lock first, so it
      never asks for a lock it already holds, and while it is held neither an
      ordinary Flex write nor a calendar write can commit into this version.
    * The saved service, its areas and their geometry, and the weekly rows,
      exceptions and attributes of every calendar its stored fields name are
      re-read under that lock and re-fingerprinted. A digest other than the
      guard's baseline, or a whole submitted page other than the one the review
      showed, rolls the transaction back as `{:error, :assistant_stale}` before
      any update, area replacement or audit row.

  The native outcomes are unchanged and still reachable: a revoked editor is
  `{:error, :forbidden}` before the version lock, a version the organization does
  not own or that is not published is `{:error, :version_unavailable}`, a
  service that is gone is `{:error, :stale}`, a lost optimistic race is
  `{:error, :stale}`, and attrs or areas the native changesets refuse return
  their own changeset or `{:error, {:invalid_area, key, reason}}`.
  """
  @spec save_service(AuditContext.t(), FlexService.t(), map(), [area_input()], map()) ::
          {:ok, FlexService.t()}
          | {:error,
             :assistant_stale
             | :stale
             | :forbidden
             | :version_unavailable
             | Ecto.Changeset.t()
             | {:invalid_area, String.t(), term()}}
  def save_service(%AuditContext{} = audit, %FlexService{} = loaded, attrs, area_inputs, options)
      when is_list(area_inputs) do
    case assistant_guard(options) do
      {:ok, %Assistant.Guard{} = guard} ->
        organization_id = audit.organization_id
        version_id = audit.gtfs_version_id

        transact(
          audit,
          fn -> guarded_write(guard, loaded, attrs, area_inputs, organization_id, version_id) end,
          :exclusive
        )

      :error ->
        {:error, :assistant_stale}
    end
  end

  # The guarded write under the exclusive fence: the service is re-read inside
  # the transaction as the baseline the guard is verified against, and the very
  # same `write_service!/5` the ordinary save calls performs the write.
  defp guarded_write(guard, loaded, attrs, area_inputs, organization_id, version_id) do
    case scoped_service(organization_id, version_id, loaded.id) do
      nil ->
        Repo.rollback(:stale)

      %FlexService{} = saved ->
        verify_assistant_guard!(guard, saved, loaded, attrs, area_inputs)

        write_service!(loaded, organization_id, version_id, attrs, area_inputs)
    end
  end

  # The whole page one reviewed save writes, shared by the ordinary and the
  # guarded save so the two can never persist different things. The changeset is
  # built from the caller's own `loaded` struct, so its `lock_version` still
  # decides the `:stale` outcome; the guarded save's fresh read is only ever the
  # baseline it compares, never the row it writes through.
  defp write_service!(loaded, organization_id, version_id, attrs, area_inputs) do
    loaded
    |> FlexService.changeset(attrs)
    |> update_service!()
    |> replace_areas!(organization_id, version_id, area_inputs)
  end

  # Exactly one option, and it is a guard: a map that carries a guard beside
  # anything else is not this save's options map.
  defp assistant_guard(%{assistant_guard: %Assistant.Guard{} = guard} = options) do
    if Map.keys(options) == [:assistant_guard], do: {:ok, guard}, else: :error
  end

  defp assistant_guard(_options), do: :error

  # The reviewed state, verified under the exclusive version fence before the
  # first write. The baseline digest is the workspace content the review read,
  # re-read now, so a calendar-only, area-only or service-only commit since the
  # review is caught here rather than being persisted on top of. The candidate
  # digest is the whole page the review showed, computed from the caller's own
  # loaded struct exactly as the host computed it, so a field edited after the
  # review is caught too. A page the native changeset refuses has no candidate to
  # compare, and the native refusal below is the editor's answer.
  defp verify_assistant_guard!(
         %Assistant.Guard{} = guard,
         %FlexService{} = saved,
         %FlexService{} = loaded,
         attrs,
         inputs
       ) do
    organization_id = saved.organization_id
    version_id = saved.gtfs_version_id

    baseline =
      organization_id
      |> Assistant.dependencies(version_id, saved)
      |> Assistant.fingerprint()

    if baseline != guard.saved_fingerprint do
      Repo.rollback(:assistant_stale)
    end

    verify_candidate_guard!(guard, loaded, attrs, inputs)
  end

  # The page and the calendars it names, both as the review showed them. The
  # baseline only covers the calendars the saved rows name, so a calendar only
  # the proposal names is bound here.
  defp verify_candidate_guard!(%Assistant.Guard{} = guard, loaded, attrs, inputs) do
    with {:ok, page} <- Assistant.Guard.candidate_digest(loaded, attrs, inputs),
         {:ok, calendars} <- Assistant.Guard.calendars_digest(loaded, attrs) do
      if page != guard.candidate_digest or calendars != guard.calendars_digest do
        Repo.rollback(:assistant_stale)
      end
    else
      :invalid -> :ok
    end
  end

  @doc """
  Sets one service's `active` flag, keeping everything else.

  Deactivating leaves the service's hours, booking rules and areas in place;
  only the export leaves an inactive service out. A whole-page save that landed
  first makes the flag change `{:error, :stale}`, so the caller can reload and
  retry. A revoked editor receives `{:error, :forbidden}` before a service read.
  """
  @spec set_active(AuditContext.t(), Ecto.UUID.t(), boolean()) ::
          {:ok, FlexService.t()}
          | {:error, :forbidden | :not_found | :stale | :version_unavailable}
  def set_active(%AuditContext{} = audit, id, active) when is_boolean(active) do
    organization_id = audit.organization_id
    version_id = audit.gtfs_version_id

    transact(audit, fn ->
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
  `ON DELETE CASCADE`. A revoked editor receives `{:error, :forbidden}` before
  a service read. An unknown or foreign service answers `{:error, :not_found}`;
  an unavailable version answers `{:error, :version_unavailable}`.
  """
  @spec delete_service(AuditContext.t(), Ecto.UUID.t()) ::
          :ok | {:error, :forbidden | :not_found | :version_unavailable}
  def delete_service(%AuditContext{} = audit, id) do
    case transact(audit, fn ->
           delete_scoped_service(audit.organization_id, audit.gtfs_version_id, id)
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
  id is malformed. A revoked editor receives `{:error, :forbidden}` before the
  target version lock. The whole copy is one transaction: a failure leaves the
  target as it was.

  References that the target version cannot resolve — a route, stop or calendar
  that exists only in the source version — are copied as they are; readiness
  reports them in the target as ordinary errors (R14).

  The target organization and version and the actor come from the audit context.
  Flex authoring records no audit actor, so the actor is checked but not persisted.
  """
  @spec copy_from_version(AuditContext.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, :forbidden | :target_not_empty | :not_found}
  def copy_from_version(%AuditContext{} = audit, source_version_id) do
    result =
      Repo.transaction(fn ->
        Authorization.lock_editor!(audit)

        case Versions.lock_for_input_write!(audit.organization_id, audit.gtfs_version_id) do
          %GtfsVersion{publication_status: @published_status} ->
            copy_version_services!(
              audit.organization_id,
              audit.gtfs_version_id,
              source_version_id
            )

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

  # --- map reads --------------------------------------------------------------

  # The stored geometry of the given services' areas, in service-name then area
  # position order. `Geometry.get_geojson/1` omits an area with no stored
  # geometry (a `:route_distance` area before the export derives it) and keys its
  # result by the area's own id, so the payload keeps the order and loses only
  # the areas the map cannot draw.
  defp map_areas(services) do
    areas = Enum.flat_map(services, & &1.areas)
    geojson = Geometry.get_geojson(Enum.map(areas, & &1.id))

    Enum.flat_map(areas, fn area ->
      case Map.fetch(geojson, area.id) do
        {:ok, shape} -> [%{id: area.id, geojson: shape}]
        :error -> []
      end
    end)
  end

  # One line per route, in `route_id` order: the route's shape points when its
  # trips name a shape, otherwise the straight lines between the stops of its
  # first trip. A route with no drawable line at all (no shaped trip and no trip
  # that visits two stops with coordinates) is left out rather than sent as an
  # empty line.
  defp map_routes(organization_id, version_id) do
    routes =
      from(r in Route,
        where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id,
        order_by: [asc: r.route_id],
        select: {r.route_id, r.route_color}
      )
      |> Repo.all()

    shape_ids = primary_route_shapes(organization_id, version_id)
    shape_points = shape_points(organization_id, version_id, Map.values(shape_ids))

    shapeless =
      for {route_id, _color} <- routes, not Map.has_key?(shape_ids, route_id), do: route_id

    stop_points = route_stop_points(organization_id, version_id, shapeless)

    lines =
      Map.new(routes, fn {route_id, _color} ->
        {route_id, route_line(route_id, shape_ids, shape_points, stop_points)}
      end)

    routes
    |> Enum.map(fn {route_id, color} ->
      %{id: route_id, color: route_color(color), coordinates: Map.get(lines, route_id, [])}
    end)
    |> Enum.filter(&(length(&1.coordinates) >= 2))
  end

  defp route_line(route_id, shape_ids, shape_points, stop_points) do
    case Map.fetch(shape_ids, route_id) do
      {:ok, shape_id} -> Map.get(shape_points, shape_id, [])
      :error -> Map.get(stop_points, route_id, [])
    end
  end

  # The shape each route's trips name most, counted in distinct trips; a tie
  # keeps the shape that sorts last, so the choice is deterministic. A route
  # whose trips name no shape has no entry.
  defp primary_route_shapes(organization_id, version_id) do
    from(t in Trip,
      join: s in Shape,
      on:
        s.organization_id == t.organization_id and s.gtfs_version_id == t.gtfs_version_id and
          s.shape_id == t.shape_id,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          not is_nil(t.shape_id) and t.shape_id != "",
      group_by: [t.route_id, s.shape_id],
      select: %{route_id: t.route_id, shape_id: s.shape_id, trips: count(t.id, :distinct)}
    )
    |> Repo.all()
    |> Enum.group_by(& &1.route_id)
    |> Map.new(fn {route_id, entries} ->
      best = entries |> Enum.sort_by(&{&1.trips, &1.shape_id}) |> List.last()
      {route_id, best.shape_id}
    end)
  end

  # `shape_id => [[lon, lat], …]` in shape point order.
  defp shape_points(_organization_id, _version_id, []), do: %{}

  defp shape_points(organization_id, version_id, shape_ids) do
    from(s in Shape,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
          s.shape_id in ^shape_ids,
      order_by: [asc: s.shape_id, asc: s.shape_pt_sequence],
      select: {s.shape_id, s.shape_pt_lon, s.shape_pt_lat}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_shape_id, lon, lat} ->
      [Values.to_float(lon), Values.to_float(lat)]
    end)
  end

  # `route_id =>` the stops of its first trip (by `trip_id`) that visits at least
  # two stops with coordinates, in stop order: R13's straight-line fallback for
  # a route whose trips name no shape.
  defp route_stop_points(_organization_id, _version_id, []), do: %{}

  defp route_stop_points(organization_id, version_id, route_ids) do
    from(t in Trip,
      join: st in StopTime,
      on:
        st.organization_id == t.organization_id and st.gtfs_version_id == t.gtfs_version_id and
          st.trip_id == t.trip_id,
      join: stop in Stop,
      on:
        stop.organization_id == t.organization_id and
          stop.gtfs_version_id == t.gtfs_version_id and stop.stop_id == st.stop_id,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id in ^route_ids and not is_nil(stop.stop_lat) and not is_nil(stop.stop_lon),
      order_by: [asc: t.route_id, asc: t.trip_id, asc: st.stop_sequence],
      select: {t.route_id, t.trip_id, stop.stop_lon, stop.stop_lat}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {route_id, rows} -> {route_id, first_trip_points(rows)} end)
  end

  # The first trip in the (already ordered) rows that visits two stops or more.
  # `nil` from a trip with fewer leaves `find_value/2` looking; its default is
  # the empty line a route with no usable trip gets.
  defp first_trip_points(rows) do
    rows
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.find_value([], fn trip_rows ->
      points =
        Enum.map(trip_rows, fn {_route_id, _trip_id, lon, lat} ->
          [Values.to_float(lon), Values.to_float(lat)]
        end)

      if length(points) >= 2, do: points
    end)
  end

  # The connecting stops the active services name, in `stop_id` order. A hub id
  # the version does not hold is a readiness error (AC-8) and simply has no
  # marker here; a stop without coordinates cannot be drawn.
  defp map_stops(organization_id, version_id, services) do
    hub_ids = services |> Enum.flat_map(& &1.hub_stop_ids) |> Enum.uniq()

    from(s in Stop,
      where:
        s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
          s.stop_id in ^hub_ids and not is_nil(s.stop_lat) and not is_nil(s.stop_lon),
      order_by: [asc: s.stop_id],
      select: %{id: s.stop_id, name: s.stop_name, lat: s.stop_lat, lon: s.stop_lon}
    )
    |> Repo.all()
    |> Enum.map(fn stop ->
      %{
        id: stop.id,
        name: Values.presence(stop.name) || stop.id,
        lon: Values.to_float(stop.lon),
        lat: Values.to_float(stop.lat),
        hub: true
      }
    end)
  end

  # `route_color` is the feed's hex string without the leading `#`; the map adds
  # it. A route with no colour sends nil and the hook falls back.
  defp route_color(value) when is_binary(value) and value != "", do: "#" <> value
  defp route_color(_value), do: nil

  # --- write steps ------------------------------------------------------------

  # Every write checks current membership before the version's input-write
  # lock. A pair the organization does not own, or one that is not a version,
  # rolls back `:not_found` and answers `:version_unavailable`; a version that
  # is not published cannot be authored (R10).
  #
  # `:exclusive` selects the version's `FOR UPDATE` fence for a guarded
  # assistant save (AC-10); `:shared` is the default every ordinary write keeps.
  # Both are taken here, at entry after the membership check and before any
  # entity read, and the two are never taken together: a transaction never holds
  # a share lock it then asks to upgrade.
  defp transact(%AuditContext{} = audit, fun, fence \\ :shared) do
    result =
      Repo.transaction(fn ->
        Authorization.lock_editor!(audit)

        case lock_version(audit, fence) do
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

  defp lock_version(%AuditContext{} = audit, :shared),
    do: Versions.lock_for_input_write!(audit.organization_id, audit.gtfs_version_id)

  defp lock_version(%AuditContext{} = audit, :exclusive),
    do: Versions.lock_for_exclusive_write!(audit.organization_id, audit.gtfs_version_id)

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

  # Named exception: calendar names feed exported booking_rules.message text, so padded or
  # whitespace-only names must export unchanged.
  defp non_empty_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp non_empty_or(_value, fallback), do: fallback

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

  @doc """
  R11's slug: trimmed, lowercased, every run of other characters replaced by
  one `-` and the result trimmed of dashes.

  A service's `key` is derived from its name with this slug, and a generated
  `service_id` slug (`flex-<key>-book-<slug>`, `flex-<key>-<slug>-<hhmm>`) uses
  the same one, so export and readiness checks build the same IDs.

  Unlike `GtfsPlanner.Gtfs.Stop.kebabify/1`, the whole name is kept: the key is
  a stored identifier, and the 64-character cap belongs to generated stop IDs
  where truncation only shortens a label. Two long service names truncated to
  the same cap would collide on the key's unique index.
  """
  @spec slugify(String.t() | nil) :: String.t()
  def slugify(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(@slug_separator, "-")
    |> String.trim("-")
  end

  def slugify(_name), do: ""

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

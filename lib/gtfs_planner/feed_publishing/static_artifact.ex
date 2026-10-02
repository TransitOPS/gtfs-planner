defmodule GtfsPlanner.FeedPublishing.StaticArtifact do
  @moduledoc """
  Reads one pinned export artifact to decide whether it may be published
  publicly and which identities it actually emits.

  `inspect/1` answers two questions about the exact bytes a caller holds under a
  publication pin: which public profile those bytes are, and which GTFS
  identities and relationships they contain. It never rewrites the archive.
  Refusal happens before or without a catalog, never by stripping a member: an
  operations run is refused from its trusted run type before the archive is even
  opened, and an archive carrying any internal TODS member is refused whole.

  The catalog is built from the emitted CSV files through
  `GtfsPlanner.Gtfs.Import.CsvParser.stream_file/3`, never from the current
  database rows. The rows behind the artifact may already have changed, so a
  catalog built from the database would describe a different feed than the one
  that would be published.

  `mismatches/2` compares that catalog with the selectors of accepted Alerts
  snapshots and returns advisory notices. It is pure: it reads nothing and
  writes nothing, changes no snapshot, and never suppresses an alert. A mismatch
  is information for the operator, not a gate.

  The `export_type` and `slot` this module trusts come from the export run row,
  which the organization already owns. They are never taken from a caller that
  chose them.
  """

  alias GtfsPlanner.Gtfs.Extensions.PathSafety
  alias GtfsPlanner.Gtfs.Import
  alias GtfsPlanner.Gtfs.Import.CsvParser

  @hash_chunk_bytes 65_536
  @sha256_hex_bytes 64

  # Internal operations data. None of it may reach a permanent public URL, and
  # one member is enough to refuse the whole archive.
  @tods_members ~w(
    stops_supplement.txt
    vehicles.txt
    routes_supplement.txt
    trips_supplement.txt
    stop_times_supplement.txt
    calendar_dates_supplement.txt
    employee_run_dates.txt
    run_events.txt
  )

  # The two location group files are written only by the flex build, so they are
  # the emitted answer to "is this the flex feed?" that does not depend on the
  # run type being told.
  @flex_members ~w(location_groups.txt location_group_stops.txt)

  # Only these files are read. A 500 MB archive's images and supplements are
  # inventoried but never expanded.
  @catalog_files %{
    "agency.txt" => [:agency_id],
    "routes.txt" => [:route_id, :route_type],
    "trips.txt" => [:trip_id, :route_id, :service_id],
    "stops.txt" => [:stop_id],
    "frequencies.txt" => [:trip_id, :start_time]
  }

  @stop_times_columns [:trip_id, :stop_id]

  @type pinned_artifact :: %{
          required(:path) => Path.t(),
          required(:export_type) => :full | :pathways | :operations,
          optional(:slot) => :main | :flex,
          optional(:filename) => String.t(),
          optional(:sha256) => String.t()
        }

  @typedoc """
  The identities the emitted CSVs actually contain.

  `route_stops` is a map of route id to the sorted stop ids its trips serve, and
  `route_types` is a map of route id to its emitted GTFS route type, so a mode
  selector can be compared without guessing. `frequency_starts` holds the
  emitted `start_time` of a frequency-based trip, which a dated trip identity
  needs and a schedule-based one does not.
  """
  @type catalog :: %{
          agency_ids: [String.t()],
          route_ids: [String.t()],
          route_types: %{optional(String.t()) => non_neg_integer()},
          stop_ids: [String.t()],
          trip_ids: [String.t()],
          trip_routes: %{optional(String.t()) => String.t()},
          trip_services: %{optional(String.t()) => String.t()},
          frequency_starts: %{optional(String.t()) => String.t()},
          route_stops: %{optional(String.t()) => [String.t()]}
        }

  @typedoc """
  One accepted Alerts snapshot's public selectors, as `mismatches/2` reads them.

  `:route_types` is the expanded mode selector, `:route_stops` the route/stop
  intersections, and `:trips` the dated trip identities, each carrying the
  emitted `start_time` of a frequency-based trip.
  """
  @type snapshot :: %{
          optional(:id) => Ecto.UUID.t(),
          optional(:name) => String.t(),
          optional(:selectors) => %{
            optional(atom()) => term()
          }
        }

  @typedoc "One advisory mismatch notice."
  @type notice :: %{
          required(:alert_id) => term(),
          required(:alert_name) => term(),
          required(:reason) => atom(),
          required(:ids) => [String.t() | [String.t()]]
        }

  @doc """
  Inspects the pinned artifact and returns its profile, entry inventory and catalog.

  `artifact` is the descriptor of the bytes a publication pin holds: `:path` to
  the verified file, the run's trusted `:export_type`, the trusted `:slot` when
  the caller knows it, the artifact `:filename`, and its recorded `:sha256`. When
  a `:sha256` is present the file is re-hashed first, so a catalog is never built
  from bytes that are not the ones the run recorded
  (`{:error, :artifact_hash_mismatch}`).

  `:inventory` is every archive entry name, sorted, which is what the consent
  screen discloses: the GTFS base files, every extension file and every image.
  The ZIP itself is never modified.

  Returns `{:error, reason}` with one of:

    * `:operations_profile_not_publishable` - the run type is operations,
      refused before the archive is opened, whatever slot it occupies
    * `:tods_content_not_publishable` - a member is internal operations data
    * `:unsafe_entry_name` - an entry name escapes the extraction root
    * `:archive_too_large` - the archive is over the import entry/size limits
    * `:unreadable_archive` - the archive cannot be listed or expanded
    * `:artifact_hash_mismatch` - the bytes no longer hash to the recorded digest
    * `{:catalog_unreadable, filename, reason}` - an emitted catalog file does not
      parse under `CsvParser`'s contract
    * `:invalid_artifact` - the descriptor is not usable
  """
  @spec inspect(pinned_artifact()) ::
          {:ok,
           %{profile: :static | :flex | :pathways, inventory: [String.t()], catalog: catalog()}}
          | {:error, term()}
  def inspect(artifact)

  def inspect(%{path: path, export_type: export_type} = artifact)
      when is_binary(path) and export_type in [:full, :pathways, :operations] do
    # The trusted run type decides this before any archive work, so an
    # operations run cannot be published by pointing the caller at another slot.
    if export_type == :operations do
      {:error, :operations_profile_not_publishable}
    else
      inspect_pinned(artifact, %{filename: artifact_filename(artifact, path), path: path})
    end
  end

  def inspect(_artifact), do: {:error, :invalid_artifact}

  defp inspect_pinned(artifact, file) do
    with :ok <- verify_digest(artifact, file),
         {:ok, members, warnings} <- preflight(file),
         :ok <- refuse_unsafe_members(warnings) do
      inventory = members |> Enum.map(&to_string/1) |> Enum.uniq() |> Enum.sort()

      with :ok <- refuse_tods_members(inventory) do
        with_catalog(file, members, inventory, classify(artifact, inventory))
      end
    end
  end

  # `preflight_archive/2` owns entry-count and expanded-byte safety and rejects
  # unsafe member names. An archive it cannot read is one typed refusal here.
  defp preflight(file) do
    case Import.preflight_archive(file, Import.zip_limits()) do
      {:ok, members, warnings} -> {:ok, members, warnings}
      {:error, _warnings} -> {:error, :unreadable_archive}
    end
  end

  @doc """
  Compares an emitted catalog with accepted Alerts selectors and returns notices.

  `snapshots` is a list of accepted snapshots, each carrying its alert `:id`,
  its rider-facing `:name` and its public `:selectors`. A selector the emitted
  feed cannot answer produces one notice naming the affected alert, the reason
  and the identities that are absent:

    * `:unknown_agency` - an agency id the catalog does not emit
    * `:unknown_route` - a route id the catalog does not emit
    * `:unknown_route_type` - a mode no emitted route carries
    * `:unknown_stop` - a stop id the catalog does not emit
    * `:unknown_route_stop` - a route/stop intersection no emitted trip serves
    * `:unknown_trip` - a trip id the catalog does not emit
    * `:unknown_frequency_start_time` - a frequency trip emitted under another
      `start_time`, which is a different dated identity

  A selector the catalog fully answers produces nothing. The result is sorted by
  alert and reason, holds no reference to either input, and changes nothing:
  callers show the notices and proceed.
  """
  @spec mismatches(catalog(), [snapshot()]) :: [notice()]
  def mismatches(catalog, snapshots) when is_map(catalog) and is_list(snapshots) do
    indexes = indexes(catalog)

    snapshots
    |> Enum.flat_map(&snapshot_notices(indexes, &1))
    |> Enum.sort_by(&{&1.alert_id, &1.reason, &1.ids})
  end

  def mismatches(_catalog, _snapshots), do: []

  @doc """
  Returns a stable digest of one inspected inventory.

  A preview binds this digest so a later confirmation can tell whether the
  disclosed inventory is still the one consent was given for. The digest is over
  the sorted entry names, so it is independent of the order `inspect/1` walked
  the archive in.
  """
  @spec inventory_digest([String.t()]) :: String.t()
  def inventory_digest(inventory) when is_list(inventory) do
    inventory
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def inventory_digest(_inventory), do: inventory_digest([])

  defp artifact_filename(artifact, path) do
    case Map.get(artifact, :filename) do
      name when is_binary(name) and name != "" -> name
      _other -> Path.basename(path)
    end
  end

  defp verify_digest(artifact, file) do
    case Map.get(artifact, :sha256) do
      expected when is_binary(expected) and byte_size(expected) == @sha256_hex_bytes ->
        if :crypto.hash_equals(file_digest(file.path), String.downcase(expected)) do
          :ok
        else
          {:error, :artifact_hash_mismatch}
        end

      _unverified ->
        :ok
    end
  end

  defp file_digest(path) do
    path
    |> File.stream!(@hash_chunk_bytes)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp refuse_unsafe_members(warnings) do
    if Enum.any?(warnings, &(&1.reason == :unsafe_member_path)) do
      {:error, :unsafe_entry_name}
    else
      :ok
    end
  end

  defp refuse_tods_members(inventory) do
    tods = MapSet.intersection(MapSet.new(inventory), MapSet.new(@tods_members))

    if MapSet.size(tods) == 0 do
      :ok
    else
      {:error, :tods_content_not_publishable}
    end
  end

  # The trusted slot and run type come first, then the archive's own answer. A
  # flex-only build that lands in the main slot is flex because the files say
  # so, not because the run type was trusted to say so.
  defp classify(artifact, inventory) do
    present = MapSet.new(inventory)

    cond do
      Map.get(artifact, :slot) == :flex ->
        :flex

      Enum.any?(@flex_members, &MapSet.member?(present, &1)) ->
        :flex

      Map.get(artifact, :export_type) == :pathways ->
        :pathways

      MapSet.member?(present, "pathways.txt") and not MapSet.member?(present, "routes.txt") ->
        :pathways

      true ->
        :static
    end
  end

  defp with_catalog(file, members, inventory, profile) do
    dir =
      Path.join(System.tmp_dir!(), "feed_publishing_inspect_#{Ecto.UUID.generate()}")

    try do
      with {:ok, extracted} <- extract_catalog_files(file, members, dir),
           {:ok, catalog} <- build_catalog(dir, extracted) do
        {:ok, %{profile: profile, inventory: inventory, catalog: catalog}}
      end
    after
      File.rm_rf(dir)
    end
  end

  # Only the catalog files are expanded, into a directory this call owns and
  # removes. The member list is the preflight's already-accepted, already-bounded
  # answer, so extraction cannot introduce a name the safety owner rejected.
  defp extract_catalog_files(file, members, dir) do
    case Enum.filter(members, &catalog_member?/1) do
      [] -> {:ok, MapSet.new()}
      required -> unzip_catalog_files(file, required, dir)
    end
  end

  defp unzip_catalog_files(file, required, dir) do
    File.mkdir_p!(dir)
    options = [{:cwd, String.to_charlist(dir)}, {:file_list, required}]

    case :zip.unzip(String.to_charlist(file.path), options) do
      {:ok, written} when length(written) == length(required) ->
        collect_extracted(dir, written)

      _other ->
        {:error, :unreadable_archive}
    end
  end

  defp collect_extracted(dir, written) do
    with :ok <- ensure_within_root(dir, written) do
      extracted = MapSet.new(Enum.map(written, &Path.basename(List.to_string(&1))))

      case extracted_bytes_within_limits(extracted, dir, Import.zip_limits()) do
        :ok -> {:ok, extracted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp catalog_member?(member) do
    name = member |> to_string() |> Path.basename()

    Map.has_key?(@catalog_files, name) or name == "stop_times.txt"
  end

  defp ensure_within_root(_dir, []) do
    :ok
  end

  defp ensure_within_root(dir, [name | rest]) do
    case PathSafety.ensure_within_root(dir, List.to_string(name)) do
      :ok -> ensure_within_root(dir, rest)
      {:error, _reason} -> {:error, :unsafe_entry_name}
    end
  end

  # A member whose header understated its size is only caught after it is
  # written, so the same post-extraction check the import path applies runs here.
  defp extracted_bytes_within_limits(extracted, dir, limits) do
    Enum.reduce_while(extracted, :ok, fn name, :ok ->
      size = dir |> Path.join(name) |> File.stat!() |> Map.fetch!(:size)

      if size > limits.max_entry_bytes do
        {:halt, {:error, :archive_too_large}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp build_catalog(dir, extracted) do
    with {:ok, agencies} <- rows(dir, extracted, "agency.txt", [:agency_id]),
         {:ok, routes} <- rows(dir, extracted, "routes.txt", [:route_id, :route_type]),
         {:ok, trips} <- rows(dir, extracted, "trips.txt", [:trip_id, :route_id, :service_id]),
         {:ok, stops} <- rows(dir, extracted, "stops.txt", [:stop_id]),
         {:ok, frequencies} <- rows(dir, extracted, "frequencies.txt", [:trip_id, :start_time]),
         {:ok, stop_times} <- rows(dir, extracted, "stop_times.txt", @stop_times_columns) do
      trip_routes = trip_route_index(trips)

      {:ok,
       %{
         agency_ids: sorted_ids(agencies),
         route_ids: sorted_ids(routes),
         route_types: route_types(routes),
         stop_ids: sorted_ids(stops),
         trip_ids: sorted_ids(trips),
         trip_routes: trip_routes,
         trip_services: trip_field(trips, 2),
         frequency_starts: frequency_starts(frequencies),
         route_stops: route_stops(stop_times, trip_routes)
       }}
    end
  end

  defp trip_route_index(trips) do
    trips
    |> Enum.reduce(%{}, fn [trip_id, route_id | _rest], acc ->
      if present?(trip_id) and present?(route_id),
        do: Map.put(acc, trip_id, route_id),
        else: acc
    end)
  end

  defp rows(dir, extracted, filename, columns) do
    if MapSet.member?(extracted, filename) do
      case CsvParser.stream_file(filename, Path.join(dir, filename)) do
        {:ok, stream} -> read_events(stream.events, columns, filename)
        {:error, error} -> {:error, {:catalog_unreadable, filename, error.reason}}
      end
    else
      {:ok, []}
    end
  end

  defp read_events(events, columns, filename) do
    Enum.reduce_while(events, {:ok, []}, fn
      {:ok, _row, fields}, {:ok, acc} ->
        values = Enum.map(columns, &present_value(Map.get(fields, Atom.to_string(&1))))

        if Enum.all?(values, &is_nil/1) do
          {:cont, {:ok, acc}}
        else
          {:cont, {:ok, [values | acc]}}
        end

      {:error, error}, {:ok, _acc} ->
        {:halt, {:error, {:catalog_unreadable, filename, error.reason}}}
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp present_value(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp present_value(_value), do: nil

  defp present?(value), do: not is_nil(value)

  defp sorted_ids(rows),
    do: rows |> Enum.map(&hd(&1)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

  defp route_types(routes) do
    Enum.reduce(routes, %{}, fn [route_id, route_type | _rest], acc ->
      case {route_id, route_type, parse_route_type(route_type)} do
        {id, _type, number} when is_binary(id) and is_integer(number) -> Map.put(acc, id, number)
        _unparseable -> acc
      end
    end)
  end

  # A GTFS route type is an extended integer, so a value the parser does not
  # consume entirely is left unknown rather than guessed.
  defp parse_route_type(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _partial -> nil
    end
  end

  defp parse_route_type(_value), do: nil

  defp trip_field(trips, index) do
    trips
    |> Enum.filter(fn row -> index < length(row) and present?(Enum.at(row, index)) end)
    |> Enum.reduce(%{}, fn row, acc ->
      case Enum.at(row, index) do
        nil -> acc
        value -> Map.put_new(acc, hd(row), value)
      end
    end)
  end

  defp frequency_starts(frequencies) do
    Enum.reduce(frequencies, %{}, fn [trip_id, start_time | _rest], acc ->
      if present?(trip_id) and present?(start_time) do
        Map.put_new(acc, trip_id, start_time)
      else
        acc
      end
    end)
  end

  # An intersection is what a trip in `stop_times.txt` actually served, so the
  # trip's route comes from the emitted `trips.txt`, never from a database join.
  defp route_stops(stop_times, trip_routes) do
    stop_times
    |> Enum.reduce(%{}, fn [trip_id, stop_id | _rest], acc ->
      with route when is_binary(route) <- Map.get(trip_routes, trip_id),
           stop when is_binary(stop) <- stop_id do
        Map.update(acc, route, [stop], &[stop | &1])
      else
        _unknown -> acc
      end
    end)
    |> Map.new(fn {route, stops} -> {route, stops |> Enum.uniq() |> Enum.sort()} end)
  end

  defp indexes(catalog) do
    %{
      agencies: MapSet.new(Map.get(catalog, :agency_ids) || []),
      routes: MapSet.new(Map.get(catalog, :route_ids) || []),
      stops: MapSet.new(Map.get(catalog, :stop_ids) || []),
      trips: MapSet.new(Map.get(catalog, :trip_ids) || []),
      route_types: Map.get(catalog, :route_types) || %{},
      route_stops: Map.get(catalog, :route_stops) || %{},
      frequency_starts: Map.get(catalog, :frequency_starts) || %{}
    }
  end

  defp snapshot_notices(indexes, snapshot) when is_map(snapshot) do
    alert_id = Map.get(snapshot, :id)
    alert_name = Map.get(snapshot, :name)
    selectors = Map.get(snapshot, :selectors) || %{}

    [
      unknown_ids(
        :unknown_agency,
        alert_id,
        alert_name,
        list(selectors, :agency_ids),
        indexes.agencies
      ),
      unknown_ids(
        :unknown_route,
        alert_id,
        alert_name,
        list(selectors, :route_ids),
        indexes.routes
      ),
      unknown_ids(:unknown_stop, alert_id, alert_name, list(selectors, :stop_ids), indexes.stops),
      unknown_route_types(
        alert_id,
        alert_name,
        list(selectors, :route_types),
        indexes.route_types
      ),
      unknown_route_stops(alert_id, alert_name, pairs(selectors, :route_stops), indexes),
      unknown_trips(alert_id, alert_name, trips(selectors, :trips), indexes)
    ]
    |> List.flatten()
  end

  defp snapshot_notices(_indexes, _snapshot), do: []

  defp list(selectors, key) when is_map(selectors) do
    case Map.get(selectors, key) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp pairs(selectors, key) do
    selectors
    |> list(key)
    |> Enum.flat_map(fn
      %{"route_id" => route_id, "stop_id" => stop_id} -> [{route_id, stop_id}]
      %{route_id: route_id, stop_id: stop_id} -> [{route_id, stop_id}]
      _other -> []
    end)
  end

  defp trips(selectors, key) do
    selectors
    |> list(key)
    |> Enum.flat_map(fn
      %{"trip_id" => trip_id} = trip -> [{trip_id, Map.get(trip, "start_time")}]
      %{trip_id: trip_id} = trip -> [{trip_id, Map.get(trip, :start_time)}]
      _other -> []
    end)
  end

  defp emitted?(id, known), do: is_binary(id) and MapSet.member?(known, id)

  defp unknown_ids(reason, alert_id, alert_name, ids, known) do
    missing = Enum.reject(ids, &emitted?(&1, known))

    case missing do
      [] -> []
      missing -> [notice(alert_id, alert_name, reason, Enum.sort(missing))]
    end
  end

  defp unknown_route_types(alert_id, alert_name, types, emitted) do
    emitted_types = emitted |> Map.values() |> MapSet.new()

    case Enum.reject(types, &(is_integer(&1) and MapSet.member?(emitted_types, &1))) do
      [] -> []
      missing -> [notice(alert_id, alert_name, :unknown_route_type, Enum.sort(missing))]
    end
  end

  defp unknown_route_stops(alert_id, alert_name, pairs, indexes) do
    missing =
      Enum.reject(pairs, fn {route_id, stop_id} ->
        is_binary(stop_id) and stop_id in Map.get(indexes.route_stops, route_id, [])
      end)
      |> Enum.sort()

    if missing == [] do
      []
    else
      [notice(alert_id, alert_name, :unknown_route_stop, missing)]
    end
  end

  defp unknown_trips(alert_id, alert_name, trips, indexes) do
    {missing_trips, wrong_start_times} =
      Enum.reduce(trips, {[], []}, fn {trip_id, start_time}, {missing, wrong} ->
        cond do
          not (is_binary(trip_id) and MapSet.member?(indexes.trips, trip_id)) ->
            {missing ++ [trip_id], wrong}

          is_binary(start_time) and
              Map.get(indexes.frequency_starts, trip_id) not in [nil, start_time] ->
            {missing, wrong ++ [trip_id]}

          true ->
            {missing, wrong}
        end
      end)

    [
      if(missing_trips == [],
        do: [],
        else: [notice(alert_id, alert_name, :unknown_trip, Enum.sort(missing_trips))]
      ),
      if(wrong_start_times == [],
        do: [],
        else: [
          notice(
            alert_id,
            alert_name,
            :unknown_frequency_start_time,
            Enum.sort(wrong_start_times)
          )
        ]
      )
    ]
    |> List.flatten()
  end

  defp notice(alert_id, alert_name, reason, ids) do
    %{alert_id: alert_id, alert_name: alert_name, reason: reason, ids: ids}
  end
end

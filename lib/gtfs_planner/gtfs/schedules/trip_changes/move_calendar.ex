defmodule GtfsPlanner.Gtfs.Schedules.TripChanges.MoveCalendar do
  @moduledoc """
  Plans an R6 Change calendar as a change set.

  Every selected trip takes the target `service_id` and moves no clock: its stop
  times, linkage and frequency rows stay as loaded, so each update carries
  `stop_times: :unchanged` and `frequencies: :unchanged`. The block outcome for the
  whole selection comes from one `Blocking.project_trip_changes/2` projection that
  carries every moved trip at its new service (CR-3), so a block whose trips move
  together keeps its ID, while a trip whose move changes its companion set has
  `block_id` cleared and names the block it leaves in a
  `{:note, {:cleared_block, id, block}}` consequence (R6, AC-13). The findings the
  projection adds become one `{:warning, {:block_findings, findings}}`.

  Every affected pattern is checked with `ServiceMix.check/3`; a move that would make
  a pattern and date carry both listed and frequency trips for the first time is an
  `{:error, {:mixed_service, details}}` consequence, which the engine's
  `refuse_errors!/1` turns into `{:error, {:refused, errors}}` with no write (R9,
  INV-5, AC-20). Transfer rows are only read: the projection reports their state and
  the change set plans no transfer write (FH-21).

  The planner is pure (CR-1): it reads only its arguments and never calls `Repo`,
  the clock or process state.
  """

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Schedules.ServiceMix
  alias GtfsPlanner.Gtfs.Schedules.TripChanges

  @doc """
  Plans one `:move_calendar` command against the loaded review state (R6 and R9).

  Every command trip must be loaded in `state.trips`; a missing one is
  `{:error, :not_found}`. For this command the loader provides `state.block_inputs`,
  which decides every block clear and finding, and `state.pattern_trips` with
  `state.service_dates`, which the R9 mixing check reads.
  """
  @spec plan(TripChanges.command(), TripChanges.state()) ::
          {:ok, TripChanges.change_set()} | {:error, :not_found | :invalid_command}
  def plan({:move_calendar, trip_ids, service_id}, state)
      when is_list(trip_ids) and is_binary(service_id) do
    with {:ok, loaded} <- load_trips(trip_ids, state) do
      projection = projection(loaded, service_id, state)
      cleared = cleared_ids(projection)

      {:ok,
       %{
         updates: Enum.map(loaded, &update(&1, service_id, cleared)),
         inserts: [],
         deletes: [],
         consequences: consequences(loaded, service_id, projection, state)
       }}
    end
  end

  def plan(_command, _state), do: {:error, :invalid_command}

  # --- block projection -----------------------------------------------------

  # One projection carries every moved trip at the target service; the loader's
  # block inputs hold the selected rows with their real endpoints, block and stop
  # refs, so a changed row is the loaded row with only its service replaced.
  defp projection(loaded, service_id, state) do
    inputs = value(state, :block_inputs)
    changed = changed_rows(loaded, inputs, service_id)

    if is_map(inputs) and changed != [] do
      Blocking.project_trip_changes(inputs, changed)
    end
  end

  defp changed_rows(loaded, inputs, service_id) do
    rows = if is_map(inputs), do: List.wrap(value(inputs, :trips)), else: []
    rows_by_id = Map.new(rows, &{value(&1, :id), &1})

    Enum.flat_map(loaded, fn {id, _entry} ->
      case Map.get(rows_by_id, id) do
        nil -> []
        row -> [Map.put(row, :service_id, service_id)]
      end
    end)
  end

  defp cleared_ids(nil), do: MapSet.new()
  defp cleared_ids(projection), do: MapSet.new(projection.cleared_trip_ids)

  # --- change set -----------------------------------------------------------

  defp update({id, _entry}, service_id, cleared) do
    fields =
      if MapSet.member?(cleared, id) do
        %{service_id: service_id, block_id: nil}
      else
        %{service_id: service_id}
      end

    %{trip_id: id, fields: fields, stop_times: :unchanged, frequencies: :unchanged}
  end

  # --- consequences ---------------------------------------------------------

  defp consequences(loaded, service_id, projection, state) do
    mixed_service_errors(loaded, service_id, state) ++
      block_findings(projection) ++
      cleared_block_notes(loaded, projection)
  end

  # R9 is checked per affected pattern over the loader's pattern trips, with every
  # moved trip at the target service; an untouched pattern's before and after lists
  # are equal, so its check is `:ok`.
  defp mixed_service_errors(loaded, service_id, state) do
    moved = MapSet.new(loaded, &elem(&1, 0))
    service_dates = value(state, :service_dates) || %{}
    pattern_trips = value(state, :pattern_trips) || %{}

    Enum.flat_map(pattern_trips, fn {_pattern_id, trips} ->
      before_trips = Enum.map(trips, &trip_kind(&1, MapSet.new(), nil))
      after_trips = Enum.map(trips, &trip_kind(&1, moved, service_id))

      case ServiceMix.check(before_trips, after_trips, service_dates) do
        :ok -> []
        {:error, error} -> [{:error, error}]
      end
    end)
  end

  defp trip_kind(trip, moved, service_id) do
    service =
      if MapSet.member?(moved, value(trip, :id)), do: service_id, else: value(trip, :service_id)

    %{service_id: service, frequency?: value(trip, :frequency?) == true}
  end

  # One warning over the findings the projection adds, compared by finding key so a
  # warning the move removes is not reported.
  defp block_findings(nil), do: []

  defp block_findings(projection) do
    before_keys = MapSet.new(projection.before_findings, &Checks.finding_key/1)

    added =
      Enum.reject(projection.after_findings, &MapSet.member?(before_keys, Checks.finding_key(&1)))

    if added == [], do: [], else: [{:warning, {:block_findings, added}}]
  end

  defp cleared_block_notes(_loaded, nil), do: []

  defp cleared_block_notes(loaded, projection) do
    blocks = Map.new(loaded, fn {id, entry} -> {id, value(value(entry, :trip), :block_id)} end)

    Enum.flat_map(projection.cleared_trip_ids, fn id ->
      case Map.get(blocks, id) do
        block when is_binary(block) -> [{:note, {:cleared_block, id, block}}]
        _block -> []
      end
    end)
  end

  # --- helpers --------------------------------------------------------------

  defp load_trips(trip_ids, state) do
    case value(state, :trips) do
      %{} = trips -> load_each(trip_ids, trips)
      _trips -> {:error, :not_found}
    end
  end

  defp load_each(trip_ids, trips) do
    loaded = Enum.map(trip_ids, &{&1, Map.get(trips, &1)})

    if Enum.any?(loaded, fn {_id, entry} -> is_nil(entry) end) do
      {:error, :not_found}
    else
      {:ok, loaded}
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end

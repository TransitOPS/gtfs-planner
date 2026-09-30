defmodule GtfsPlanner.Gtfs.Blocking.Generator do
  @moduledoc """
  Suggested blocks for one day type.

  The generator is pure. It reads its trip rows, the version's planning context
  and the set of block IDs already in use, and returns an assignment of every
  scheduled trip to a block plus the blocks themselves and the leftovers it could
  not place. It calls no repository, clock, file or network, and it writes
  nothing: `Blocking.suggest_blocks/4` reads a day, calls `run/4` and hands the
  result to `Blocking.Plan.build/1` for review, and only `apply_block_plan/3`
  moves a trip's `block_id`.

  A block's garage and vehicle type come from `Blocking.Context.resolve_block/3`
  like everywhere else, and its movements and relief schedule come from
  `Blocking.Movements` and `Blocking.Relief`. Nothing here re-derives a
  drive, a platform span or a relief window; a candidate that passes here is a
  candidate the checks will agree with, because both read the same derivation.

  What the run decides:

    * **Scope.** `:unassigned_only` keeps every existing assignment and seeds an
      open block per existing block; `{:selected, ids}` and `:replace_all` rebuild
      the trips they are given onto blocks created in the run, leaving every other
      block exactly as it was.
    * **Partitions.** Trips are grouped by `{home garage, required type}` from
      `context.route_settings` and the version's default garage, and the groups
      are walked in a fixed order. A trip never joins a block from another
      partition, so a route that requires a 35-ft diesel never shares a block
      with a cutaway.
    * **Order.** Inside a partition, trips are ordered by first departure then
      trip ID and chained onto the open block with the smallest idle time that
      still clears the drive, the minimum layover, the interlining rule, the
      platform limit and the relief limit. Ties go to the earlier-created block,
      then to the block's natural ID order.
    * **Leftovers.** Frequency trips and unplottable trips are never reassigned.
      A trip that needs a drive the version cannot compute, from every open block
      and from the garage, is left over as `:unknown_location` rather than
      guessed at. A new block that holds a single trip too long for its vehicle
      or its relief limit keeps the trip and reports it, because dropping the only
      trip of a block helps nobody.

  Every scheduled trip leaves the run in exactly one block or in the leftovers
  with a reason, and a run over the same trips in any input order returns the
  same result. Nothing derived here is stored: the result is a
  proposal for review, and `Blocking.Plan.build/1` turns it into a plan with a fingerprint.

  The result map is:

      %{mode: mode,
        assignments: %{trip_uuid => block_id_or_nil},
        blocks: [%{id:, new?:, garage_id:, vehicle_type_id:, trips:}],
        leftovers: [%{trip:, reason:, block_id:}]}
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.DeadheadTimes
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief
  alias GtfsPlanner.Gtfs.Blocking.Summary

  @seconds_per_minute 60

  @type mode :: :unassigned_only | {:selected, [String.t()]} | :replace_all

  @type leftover_reason ::
          :repeating_service
          | :unplottable
          | :unknown_location
          | :exceeds_vehicle_limit
          | :exceeds_relief_limit

  @type leftover :: %{
          trip: Checks.trip_row(),
          reason: leftover_reason(),
          block_id: String.t() | nil
        }

  @type block :: %{
          id: String.t(),
          new?: boolean(),
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          trips: [Checks.trip_row()]
        }

  @type result :: %{
          mode: mode(),
          assignments: %{Ecto.UUID.t() => String.t() | nil},
          blocks: [block()],
          leftovers: [leftover()]
        }

  @type open_block :: %{
          id: String.t(),
          new?: boolean(),
          created: non_neg_integer(),
          resolution: Context.resolve_result(),
          platform_start_secs: integer() | nil,
          trips: [Checks.trip_row()]
        }

  @doc """
  Returns the suggested blocks for one day type's trip rows.

  `rows` are the day type's `Checks.trip_row()` values in whatever order the
  caller read them; the run sorts them itself, so the result is the same for
  every input order. `used_ids` is every block ID in use by any trip on
  the affected dates, and new blocks this run creates continue after the highest numeric
  one.

  Every returned row's UUID is a key of `assignments`, including the trips that
  were left where they were: a frequency trip keeps its `block_id` (or stays
  `nil`) in every mode, so applying a plan never has to guess what a leftover
  was doing before.
  """
  @spec run(mode(), [Checks.trip_row()], Context.t(), [String.t()]) :: result()
  def run(mode, rows, %Context{} = context, used_ids) do
    rows = Enum.sort_by(rows, & &1.trip_id)
    {held, placeable} = Enum.split_with(rows, &held?/1)
    {pool, kept} = scope(mode, placeable)

    state = %{
      context: context,
      blocks: seeds(mode, kept, context),
      ids: ids(mode, used_ids),
      assignments: Map.new(kept ++ held, &{&1.id, &1.block_id}),
      leftovers:
        held
        |> Enum.map(&leftover(&1, held_reason(&1), &1.block_id))
        |> Enum.sort_by(& &1.trip.trip_id)
    }

    state =
      pool
      |> Enum.group_by(&partition(&1, context))
      |> Enum.sort_by(fn {key, _trips} -> partition_order(key) end)
      |> Enum.reduce(state, fn {_key, trips}, acc ->
        trips
        |> Enum.sort_by(&{&1.first_departure, &1.trip_id})
        |> Enum.reduce(acc, fn trip, acc -> try_place(acc, trip) end)
      end)

    %{
      mode: mode,
      assignments: state.assignments,
      blocks: finish(state.blocks),
      leftovers: state.leftovers ++ singletons(state.blocks, context)
    }
  end

  # --- scope -----------------------------------------------------------------

  # `:unassigned_only` is the additive mode: the trips that already have a block
  # keep it, and the ones without one are what the run places. The other two
  # modes rebuild, so every row handed in is in scope and the blocks the rows
  # came from are left to the caller — a selected block's trips come back as
  # unassigned, and the run puts them on blocks it creates. Both clauses return
  # `{pool, kept}`.
  defp scope(:unassigned_only, rows), do: Enum.split_with(rows, &is_nil(&1.block_id))

  defp scope(_rebuild, rows), do: {rows, []}

  # Frequency-based and unplottable rows are held back before anything else. A
  # frequency trip is a template repeated across the day rather than one run of
  # the bus, and an unplottable trip has no endpoints to chain, so neither can be
  # placed without inventing a schedule.
  defp held?(trip), do: trip.frequency? or not trip.plottable?

  defp held_reason(trip) do
    if trip.frequency?, do: :repeating_service, else: :unplottable
  end

  defp leftover(trip, reason, block_id) do
    %{trip: trip, reason: reason, block_id: block_id}
  end

  # --- partitions ------------------------------------------------------------

  # The partition is the garage and type resolution read for a block of this one trip, so
  # the key here and the garage a block opened for it carries cannot disagree: both come
  # from `Context.resolve_block/3`. The block ID is the empty string because no attribute
  # row is keyed to it, which is what makes this read the route's home garage (else the
  # version default) and the route's required type, and which also makes a route naming a
  # garage or type this version does not carry fall through to `nil` exactly as it would
  # on a real block.
  defp partition(trip, context) do
    %{garage_id: garage_id, vehicle_type_id: vehicle_type_id} =
      Context.resolve_block(context, "", [trip])

    {garage_id, vehicle_type_id}
  end

  # Partitions are walked in a fixed order so a run over the same trips returns
  # the same blocks. `nil` sorts before every real UUID because it is the empty
  # string here, which puts an unplanned partition first rather than letting map
  # order decide.
  defp partition_order({garage_id, vehicle_type_id}),
    do: {garage_id || "", vehicle_type_id || ""}

  # --- open blocks -----------------------------------------------------------

  # Only `:unassigned_only` starts from the blocks already on the page: their
  # trips keep their assignment and the block is offered to later trips as an
  # open block to chain onto. A rebuild starts empty, because a selected block's
  # own trips are in the pool to be placed afresh.
  defp seeds(:unassigned_only, kept, context) do
    kept
    |> Enum.group_by(& &1.block_id)
    |> Enum.sort_by(fn {block_id, _trips} -> Summary.natural_key(block_id) end)
    |> Enum.with_index()
    |> Enum.map(fn {{block_id, trips}, created} ->
      trips = Checks.sequence(trips)

      # A block whose trips are all frequency-based or all unplottable has no
      # sequence to extend, so there is nothing to offer a later trip and
      # nothing to chain onto. Its trips are leftovers and the block stays
      # exactly as the page has it, which is why it is not in the run's blocks.
      if trips == [] do
        nil
      else
        resolution = Context.resolve_block(context, block_id, trips)

        %{
          id: block_id,
          new?: false,
          created: created,
          resolution: resolution,
          platform_start_secs: Movements.build(trips, resolution, context).platform_start_secs,
          trips: trips
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp seeds(_rebuild, _kept, _context), do: []

  # A rebuild over selected blocks reuses those blocks' own numbers in
  # ascending order, because the plan is a rebuild of exactly those blocks and
  # a reviewer sees the same number against the same trips. Anything past the
  # selection continues after the highest numeric ID in use, so a version whose
  # blocks are 101–104 numbers its new block 105 rather than restarting at 1.
  defp ids({:selected, selected}, used_ids) do
    %{
      selected: selected |> Enum.uniq() |> Enum.sort_by(&Summary.natural_key/1),
      next: (highest(used_ids) || 0) + 1
    }
  end

  defp ids(_mode, used_ids), do: %{selected: [], next: (highest(used_ids) || 0) + 1}

  defp take_id(%{selected: [id | rest]} = ids), do: {id, %{ids | selected: rest}}
  defp take_id(ids), do: {Integer.to_string(ids.next), %{ids | next: ids.next + 1}}

  # The leading digit run of an ID is its number. "105" is 105 and "101A" is 101
  # for the "highest numeric ID used"; a purely alphabetic ID has no number to
  # continue from and the run starts at 1, which is where the manual rule starts
  # too.
  defp highest(ids) do
    ids
    |> Enum.map(fn id ->
      case Regex.run(~r/^\d+/, id) do
        [digits | _] -> String.to_integer(digits)
        nil -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  # --- placement -------------------------------------------------------------

  defp try_place(state, trip) do
    key = partition(trip, state.context)
    open = Enum.filter(state.blocks, &same_partition?(&1, key))

    case best_fit(open, trip, state.context) do
      nil -> open_block(state, trip, open)
      block -> chain(state, block, trip)
    end
  end

  defp same_partition?(%{resolution: %{garage_id: g, vehicle_type_id: t}}, {g, t}), do: true
  defp same_partition?(_block, _key), do: false

  # The smallest idle time wins: the block that has been standing longest since
  # its last arrival is the one that wastes least. `created` then the natural ID
  # order break the ties, so two blocks with the same idle time are resolved the
  # same way on every run.
  defp best_fit(open, trip, context) do
    open
    |> Enum.flat_map(fn block ->
      case fit(block, trip, context) do
        {:ok, idle} -> [{idle, block.created, Summary.natural_key(block.id), block}]
        :no -> []
      end
    end)
    |> Enum.min_by(fn {idle, created, key, _block} -> {idle, created, key} end, fn -> nil end)
    |> case do
      nil -> nil
      {_idle, _created, _key, block} -> block
    end
  end

  # The candidate test, one rule at a time. A failure anywhere is `:no`; the
  # reason is the checks' to report, not the generator's to guess at.
  defp fit(block, trip, context) do
    last = List.last(block.trips)
    gap = tail_gap(block, last, trip, context)

    with true <- interlining_allows?(last, trip, context),
         %{} = gap <- gap,
         # A layover gap's drive is `nil` because there is no drive; its wait is
         # the whole gap, so the minimum layover is measured against the same
         # number either way.
         true <- (gap.wait_secs || 0) >= context.min_layover_minutes * @seconds_per_minute,
         true <- platform_allows?(block, trip, context),
         true <- relief_allows?(block, trip, context) do
      {:ok, trip.first_departure - (last.last_arrival + (gap.drive_secs || 0))}
    else
      _no -> :no
    end
  end

  # The gap between the block's last trip and the candidate is the only part of
  # the trial block that changes, so it is built on its own. `Movements.build/3`
  # re-sequences its input, and two trips that chain leave exactly one gap, so
  # the answer is the same one a full trial build would give — without rebuilding
  # every earlier trip for every candidate.
  defp tail_gap(block, last, trip, context) do
    case Movements.build([last, trip], block.resolution, context).gaps do
      [%{} = gap] -> gap
      _no_usable_pair -> nil
    end
  end

  # The same rule `Checks` raises `:interlining_not_allowed` from, read here as a
  # candidate rule: a route switch the setting forbids is not a chain this run
  # may make, even though the gap itself is wide enough.
  defp interlining_allows?(from, to, context) do
    if from.route_id == to.route_id do
      true
    else
      handoff = Checks.handoff(from.last_stop, to.first_stop)
      not forbids?(context.interlining, handoff)
    end
  end

  defp forbids?(:none, _handoff), do: true
  defp forbids?(:same_stop, handoff), do: handoff not in [:same_stop, :same_station]
  defp forbids?(:any, _handoff), do: false

  # Platform time runs from the block's pull-out to the pull-back of its new last
  # trip. The start belongs to the block's first trip and never moves, so only
  # the end is rebuilt — from the candidate alone, because a pull-back is
  # anchored on that trip's last stop and arrival.
  defp platform_allows?(block, trip, context) do
    case {limit_minutes(block.resolution, context), platform_minutes(block, trip, context)} do
      {nil, _minutes} -> true
      {_limit, nil} -> true
      {limit, minutes} -> minutes <= limit
    end
  end

  defp platform_minutes(block, trip, context) do
    case block.platform_start_secs do
      start when is_integer(start) ->
        case Movements.build([trip], block.resolution, context).pull_back do
          %{end_secs: end_secs} -> div(end_secs - start, @seconds_per_minute)
          _no_pull_back -> nil
        end

      _no_start ->
        nil
    end
  end

  # The lower of the two limits that are set, exactly as `:too_long` measures it.
  # A type with no `max_out_minutes` and a version with no `max_block_minutes`
  # leave the platform unbounded, and an unbounded chain is a candidate.
  defp limit_minutes(%{vehicle_type_id: type_id}, context) do
    type_limit =
      case type_id && Map.get(context.vehicle_types, type_id) do
        %{max_out_minutes: minutes} -> minutes
        _no_type -> nil
      end

    [type_limit, context.max_block_minutes]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      limits -> Enum.min(limits)
    end
  end

  # A relief schedule cannot be scored on a gap; a stretch is a length between two
  # changes, so a trial that might stretch past the limit has to be built whole.
  # With no limit set there is no stretch to check and the trial stays cheap,
  # which is the case a real version is in until someone sets a relief limit.
  defp relief_allows?(_block, _trip, %{max_piece_minutes: nil}), do: true

  defp relief_allows?(block, trip, context) do
    limit = context.max_piece_minutes * @seconds_per_minute
    trips = block.trips ++ [trip]
    movements = Movements.build(trips, block.resolution, context)
    windows = Relief.windows(trips, movements, context)

    movements
    |> Relief.stretches(windows, limit)
    |> Enum.all?(&(&1.secs <= limit))
  end

  # No block in the partition could take the trip, so it opens a new one. The
  # new block carries the partition's garage and type, which is what
  # `Context.resolve_block/3` would resolve for a block of these trips alone.
  defp open_block(state, trip, open) do
    context = state.context

    if unmeasurable?(trip, open, context) do
      %{
        state
        | leftovers: state.leftovers ++ [leftover(trip, :unknown_location, nil)],
          assignments: Map.put(state.assignments, trip.id, nil)
      }
    else
      {id, ids} = take_id(state.ids)
      # The block's own resolution, read through the same rule as a seeded one:
      # a new ID has no attribute row, so this is the partition's garage and
      # type and is what `Plan.build/1` writes as the block's attribute row.
      resolution = Context.resolve_block(context, id, [trip])

      block = %{
        id: id,
        new?: true,
        created: length(state.blocks),
        resolution: resolution,
        platform_start_secs: Movements.build([trip], resolution, context).platform_start_secs,
        trips: [trip]
      }

      %{
        state
        | blocks: state.blocks ++ [block],
          ids: ids,
          assignments: Map.put(state.assignments, trip.id, id)
      }
    end
  end

  defp chain(state, block, trip) do
    blocks =
      Enum.map(state.blocks, fn open ->
        if open.id == block.id, do: %{open | trips: open.trips ++ [trip]}, else: open
      end)

    %{state | blocks: blocks, assignments: Map.put(state.assignments, trip.id, block.id)}
  end

  # A trip whose first stop the version cannot place is not a chain this run may
  # make. Every drive into it would be unknown, from the open blocks that end
  # somewhere else and from the garage a new block would pull out of, and an
  # unknown drive is not a zero drive: it is a gap nobody can promise.
  # The trip stays in the leftovers rather than becoming a block whose first
  # movement the checks would report as an empty move.
  defp unmeasurable?(trip, open, context) do
    stop = trip.first_stop

    not measurable?(stop) and
      Enum.any?(open, fn block ->
        Checks.handoff(List.last(block.trips).last_stop, stop) != :same_stop
      end) and
      garage_drive_unknown?(context, stop)
  end

  defp measurable?(nil), do: false
  defp measurable?(%{lat: lat, lon: lon}), do: is_number(lat) and is_number(lon)

  defp garage_drive_unknown?(context, stop) do
    Enum.any?(Map.keys(context.garages), fn garage_id ->
      DeadheadTimes.lookup(
        {:garage, garage_id},
        garage_point(context, garage_id),
        {:stop, stop.stop_id},
        stop_point(stop),
        context
      ).minutes == nil
    end)
  end

  defp garage_point(context, garage_id) do
    case Map.get(context.garages, garage_id) do
      %{lat: lat, lon: lon} -> {lat * 1.0, lon * 1.0}
      _no_garage -> nil
    end
  end

  # A coordinate pair needs both numbers; a stop carrying one without the other
  # is as unmeasurable as one carrying neither, the same rule `Movements` reads.
  defp stop_point(%{lat: lat, lon: lon}) when is_number(lat) and is_number(lon),
    do: {lat * 1.0, lon * 1.0}

  defp stop_point(_stop), do: nil

  # --- result ----------------------------------------------------------------

  # Blocks leave the run in natural ID order with their trips in service order,
  # because both are what a reviewer reads them in. A block's garage and type are
  # the resolved ones, which for a created block is the partition it was opened
  # for and is what `Plan.build/1` writes as its attribute row.
  defp finish(blocks) do
    blocks
    |> Enum.map(fn block ->
      %{
        id: block.id,
        new?: block.new?,
        garage_id: block.resolution.garage_id,
        vehicle_type_id: block.resolution.vehicle_type_id,
        trips: Checks.sequence(block.trips)
      }
    end)
    |> Enum.sort_by(&Summary.natural_key(&1.id))
  end

  # A new block holding one trip is the only shape the generator can produce that
  # it had no choice about: there was nothing else for that trip to join. When it
  # is too long for the vehicle or its relief limit, the trip keeps the block and
  # the run says so, because a plan may add exactly these two findings on a
  # reported singleton and a plan that dropped the trip instead would leave the
  # operator with no block and no explanation.
  defp singletons(blocks, context) do
    blocks
    |> Enum.filter(&(&1.new? and length(&1.trips) == 1))
    |> Enum.sort_by(&Summary.natural_key(&1.id))
    |> Enum.flat_map(fn block ->
      [trip] = block.trips

      [
        vehicle_limit_reached(block, context),
        relief_limit_reached(block, context)
      ]
      |> Enum.filter(&(not is_nil(&1)))
      |> Enum.map(&leftover(trip, &1, block.id))
    end)
  end

  defp vehicle_limit_reached(block, context) do
    [trip] = block.trips

    case {limit_minutes(block.resolution, context), platform_minutes(block, trip, context)} do
      {limit, minutes} when is_integer(limit) and is_integer(minutes) and minutes > limit ->
        :exceeds_vehicle_limit

      _within_limit ->
        nil
    end
  end

  # The block already holds only this trip, so the stretch that matters is the
  # one the block's own schedule leaves — the same question the run asked while
  # the block was empty and the trip was a candidate.
  defp relief_limit_reached(_block, %{max_piece_minutes: nil}), do: nil

  defp relief_limit_reached(block, context) do
    [trip] = block.trips
    limit = context.max_piece_minutes * @seconds_per_minute
    movements = Movements.build([trip], block.resolution, context)
    windows = Relief.windows([trip], movements, context)

    if movements |> Relief.stretches(windows, limit) |> Enum.all?(&(&1.secs <= limit)) do
      nil
    else
      :exceeds_relief_limit
    end
  end
end

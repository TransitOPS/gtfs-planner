defmodule GtfsPlanner.Gtfs.Blocking.Plan do
  @moduledoc """
  A suggested plan: the moves, the new blocks and their attribute rows, the review
  of what the moves change, the figures before and after, and the fingerprint a
  later apply must match (AC-25).

  `build/1` is the assembly step between `Blocking.Generator.run/4` and
  `Blocking.suggest_blocks/4`. The generator decides *which* block each trip ends up
  on; this module turns that decision into the shape a reviewer reads and a writer
  can be asked to confirm, and it is the only place a plan's fingerprint is
  produced. The plan is pure: it computes from the map it is given and makes no
  repository, clock, file or network call (CR-1). Only `apply_block_plan/3` moves a
  trip's `block_id`.

  Nothing here re-decides anything. The moves are the generator's assignments read
  against the rows as they stand, the findings are `Blocking.Checks`' own, the
  review is `Blocking.Review`'s, the seconds are `Blocking.Movements`' and the
  input digest is `Blocking.Context.digest/1` (INV-7, INV-8, INV-9). One plan is
  never reviewed by a second implementation, and a garage or vehicle type reaches
  a plan only through `Context.resolve_block/3`.

  A move is a `Review.change/0` — the trip, the block it is in and the block it
  will be in — and a trip whose block does not change is not a move, so an
  additive plan's unchanged blocks leave no trace in `moves`.

  Each new block gets one attribute row per service its trips run on, carrying the
  garage and vehicle type the generator resolved for it. `block_attributes` is
  keyed by `(service_id, block_id)`, so a block whose trips span two services
  needs two rows; both carry the same garage and type, which is what R4 would
  resolve for that block. The plan does not pass a `context_after` to the review
  because it does not need one: a new block ID keys no attribute row, and a
  selected block's ID is resolved by the generator *through* the row it already
  has, so the row the plan writes names the resolution the review already read and
  the after-findings cannot disagree with the before-findings about it.

  The figures are counted on the selected day type only, over its blocks and
  after the moves are applied: the block count, the platform and drive seconds
  `Movements` derives, and the error and warning findings `Checks` raises there.
  The page's own counts also carry in-seat records, pool notices and fleet
  shortfalls; those belong to the day load and to the review's effects, and are
  deliberately not recomputed here — a second derivation of them would be a second
  answer to the same question.

  The fingerprint is the review's own, over the sorted rows, the changes, the
  added findings, `Context.digest/1` of every planning input and a hash of the
  selected day type's trip set. So a setting, an entered driving time, a relief
  mark, a route setting, an attribute row, a garage coordinate, a fleet count or
  one added or removed trip all make an unreviewed plan (R12, INV-7).
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Generator
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Review

  @type figures :: %{
          vehicles: non_neg_integer(),
          platform_secs: non_neg_integer(),
          drive_secs: non_neg_integer(),
          problems: non_neg_integer()
        }

  @type attribute_row :: %{
          service_id: String.t(),
          block_id: String.t(),
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil
        }

  @type t :: %{
          mode: Generator.mode(),
          day_type_key: String.t(),
          moves: [Review.change()],
          new_blocks: [map()],
          attribute_rows: [attribute_row()],
          review: Review.review(),
          before: figures(),
          after: figures(),
          leftovers: [Generator.leftover()],
          fingerprint: String.t()
        }

  @doc """
  Builds the plan over a generator result.

  The input map carries:

  - `:mode` — the generator mode, which is also the resolved command;
  - `:selected_key` — the selected day type's key, whose effect is listed first;
  - `:day_types` — the version's derived day types, read for the selected one;
  - `:affected` — every day type containing a moved trip's service;
  - `:rows` — the trip rows the plan is read over: the day type's trips and the
    trips of the blocks the plan touches on an affected service;
  - `:result` — the `Blocking.Generator.run/4` result;
  - `:context` — the version's `%Blocking.Context{}` planning inputs;
  - `:in_seat` and `:service_dates` — passed through to the review unchanged.
  """
  @spec build(map()) :: t()
  def build(input) do
    mode = Map.fetch!(input, :mode)
    selected_key = Map.fetch!(input, :selected_key)
    rows = Map.fetch!(input, :rows)
    result = Map.fetch!(input, :result)
    context = Map.fetch!(input, :context)
    day_type = selected_day_type(input, selected_key)

    moves = moves(rows, result.assignments)

    review =
      Review.build(%{
        command: {:plan, mode},
        target: nil,
        selected_key: selected_key,
        affected: Map.fetch!(input, :affected),
        rows: rows,
        changes: moves,
        context: context,
        inputs_digest: inputs_digest(context, rows, day_type),
        in_seat: Map.fetch!(input, :in_seat),
        service_dates: Map.fetch!(input, :service_dates)
      })

    %{
      mode: mode,
      day_type_key: selected_key,
      moves: moves,
      new_blocks: new_blocks(result.blocks),
      attribute_rows: attribute_rows(result.blocks),
      review: review,
      before: figures(rows, day_type, context),
      after: figures(apply_moves(rows, moves), day_type, context),
      leftovers: result.leftovers,
      fingerprint: review.fingerprint
    }
  end

  # The plan's figures and trip set are the selected day type's, so the day type is
  # read by key rather than assumed to be the first of the affected list — the
  # review orders that list with the selected one first, and this reads the same key
  # from either the whole set or the affected set the caller supplied.
  defp selected_day_type(input, selected_key) do
    day_types = Map.get(input, :day_types) || Map.fetch!(input, :affected)

    Enum.find(day_types, &(&1.key == selected_key))
  end

  # A row the generator never received has no assignment and is not a move: the
  # plan's rows also carry the trips of the blocks it touches on another service,
  # and those belong to another day type's plan. A row held where it was — a
  # frequency trip, an unplottable one, or an existing block in an additive plan —
  # is assigned its own `block_id` and is not a move either.
  defp moves(rows, assignments) do
    rows
    |> Enum.flat_map(fn row ->
      case Map.fetch(assignments, row.id) do
        {:ok, to} when to != row.block_id -> [%{trip: row, from: row.block_id, to: to}]
        _held -> []
      end
    end)
    |> Enum.sort_by(&{&1.trip.trip_id, &1.from, &1.to})
  end

  # Only the blocks the run created: an existing block keeps the attributes an
  # operator set on it, and rewriting them from the plan would overwrite a
  # decision the plan did not ask about. The trips are named by ID because a plan
  # is carried in a page's assigns and read as a list, not as a second copy of the
  # rows the moves already carry.
  defp new_blocks(blocks) do
    Enum.map(Enum.filter(blocks, & &1.new?), fn block ->
      %{
        block_id: block.id,
        garage_id: block.garage_id,
        vehicle_type_id: block.vehicle_type_id,
        trip_ids: Enum.map(block.trips, & &1.id)
      }
    end)
  end

  # `block_attributes` is keyed by `(service_id, block_id)`, so a new block whose
  # trips run on two services needs a row for each — the same garage and type both
  # times, because that is the one resolution the block has.
  defp attribute_rows(blocks) do
    for block <- Enum.filter(blocks, & &1.new?),
        service_id <- block.trips |> Enum.map(& &1.service_id) |> Enum.uniq() |> Enum.sort() do
      %{
        service_id: service_id,
        block_id: block.id,
        garage_id: block.garage_id,
        vehicle_type_id: block.vehicle_type_id
      }
    end
  end

  # The rows as they will be stored: every move's trip carries its own `to`, and a
  # row no move names keeps the block it has. The after figures are then read over
  # the same blocks and the same movements as the before ones, so a difference
  # between the two figures is a difference the plan makes and not a different way
  # of counting.
  defp apply_moves(rows, moves) do
    to_by_trip_id = Map.new(moves, &{&1.trip.id, &1.to})

    Enum.map(rows, fn row ->
      case Map.fetch(to_by_trip_id, row.id) do
        {:ok, to} -> %{row | block_id: to}
        :error -> row
      end
    end)
  end

  # The plan's own counts, over the selected day type's blocks only. A trip with no
  # block is in the pool rather than in a vehicle, so it is in no block here — which
  # is why a plan that places a pool trip can raise the vehicle count.
  defp figures(rows, day_type, context) do
    blocks =
      rows
      |> rows_on(day_type)
      |> Enum.reject(&is_nil(&1.block_id))
      |> Enum.group_by(& &1.block_id)

    movements =
      Enum.map(blocks, fn {block_id, trips} -> build_movements(block_id, trips, context) end)

    %{
      vehicles: map_size(blocks),
      platform_secs: Enum.sum(Enum.map(movements, &platform_length/1)),
      drive_secs: Enum.sum(Enum.map(movements, & &1.drive_secs)),
      problems: problems(blocks, context)
    }
  end

  defp rows_on(rows, nil), do: rows

  defp rows_on(rows, day_type),
    do: Enum.filter(rows, &(&1.service_id in day_type.service_ids))

  # R2/R3's seconds, through the one owner of them. `resolve_block/3` is read for
  # the same trips the movements are built from, so a block's garage and type here
  # are the ones the checks, the export and the page read (INV-9).
  defp build_movements(block_id, trips, context) do
    Movements.build(trips, Context.resolve_block(context, block_id, trips), context)
  end

  # A block with no plottable trip has no platform span at all, so it contributes no
  # time rather than a zero-length span that would read as a vehicle parked at the
  # depot for no reason. The same `length/1` and the same zero answer the day load
  # reads, on the same derived movements.
  defp platform_length(%{platform_start_secs: start, platform_end_secs: finish})
       when is_integer(start) and is_integer(finish),
       do: finish - start

  defp platform_length(_no_span), do: 0

  defp problems(blocks, context) do
    Enum.sum(
      Enum.map(blocks, fn {block_id, trips} ->
        block_id
        |> Checks.block_findings(trips, context)
        |> Enum.count(&(&1.severity in [:error, :warning]))
      end)
    )
  end

  # The two halves of a plan's staleness: the planning inputs it was read under, and
  # the trips of the day type it was read for. The context digest deliberately
  # covers inputs the plan did not read (a garage coordinate, a fleet count, an
  # attribute row for a service this day does not run) — an over-stale preview costs
  # one regeneration, while a fingerprint that missed an input would apply a plan
  # nobody reviewed (R12, critique Must 2). The trip set is hashed separately
  # because a row added to or removed from the day type is a change no context field
  # can see.
  defp inputs_digest(context, rows, day_type) do
    Context.digest(context) <> trip_set_hash(rows, day_type)
  end

  defp trip_set_hash(rows, day_type) do
    rows
    |> rows_on(day_type)
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

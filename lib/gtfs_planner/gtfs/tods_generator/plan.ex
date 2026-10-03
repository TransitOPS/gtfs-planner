defmodule GtfsPlanner.Gtfs.TodsGenerator.Plan do
  @moduledoc """
  The pure block candidate of one TODS generation request.

  This module composes; it never reads and never writes. Everything it decides
  from arrives in `source`, the map the `TodsGenerator` source loader built
  inside one read snapshot:

      %{day_types: [Blocking.DayTypes.day_type()],
        rows_by_day_type: %{day_type_key => [Blocking.Queries.trip_row()]},
        context: Blocking.Context.t(),
        used_block_ids: [String.t()]}

  `day_types` is the generation order — the day types the request selected —
  while `rows_by_day_type` also carries the affected day types the completed
  blocks reach, which is what validity is decided over.

  `normalized_input` is `TodsGenerator.Input.normalize/1`'s canonical map. Only
  its `"garage_id"` is read here.

  ## What it decides

    * **Stable trip identity.** A trip UUID has one block ID across every
      affected day type. Day types are generated in `DayTypes.derive/1` order
      and every new assignment the run accepted is *frozen* onto the trip before
      the next day type runs, so a trip shared by a weekday and a Saturday cannot
      be given two numbers. Block IDs continue after every ID already in use,
      including the ones an earlier day type of this same run created.
    * **A new block is valid on every affected day it runs.** The union of the
      block's trips is re-evaluated through `Blocking.Checks.block_findings/3` on
      each of them, and a block with an `:error` finding on any affected day
      loses *all* of its new moves. It is not partially clipped: half a chain is
      not a smaller wrong answer, it is the same wrong answer with fewer rows to
      explain it. A trip's `block_id` is stored once for all of its dates, so
      "affected" is every day type the block's trips run on, including a day type
      the selected range did not reach: `source.rows_by_day_type` carries the
      completed rows of every such day type, not only the days this run composed
      on.
    * **Existing blocks survive.** A block that already holds trips is never
      rejected, valid or not. A new trip the run would have added to an invalid
      one is excluded, and the trips already on it are untouched. What an
      existing block could not cover stays uncovered: it is reported as a
      leftover rather than moved somewhere the operator did not ask for.
    * **The selected garage fills an unresolved default only.** A block resolved
      through an attribute row, a route setting or the version's own default
      keeps that garage; a block that resolved to `:none` takes the selected
      garage. A block whose attribute rows disagree is excluded rather than
      resolved by whichever row happened to be read first.

  ## The result

      %{blocks: [%{block_id:, new?: true, garage_id:, vehicle_type_id:,
                   trips: [trip_row()], day_type_keys: [String.t()]}],
        assignments: %{trip_uuid => block_id},
        preserved_block_ids: [String.t()],
        exclusions: [%{subject: Ecto.UUID.t(), reason: atom()}],
        counts: %{...},
        day_type_keys: [String.t()]}

  `assignments` holds new moves only; a trip that already had a block is not in
  it, because nothing about it changes. Every list in the result is sorted by a
  natural key, so the same source facts in any order produce the same candidate.

  ## Why the checks are asked twice

  `Blocking.Generator` places a trip by testing it against the *last* trip of an
  open block, so it never builds a whole trial sequence for a chain it accepts
  and it makes no claim about a trip's non-adjacent neighbours. `Checks` reads
  the whole sequence and is what the rest of the planner trusts. This step is
  where the two meet: the generator proposes, and the union candidate is
  re-read through the checks on every affected day before any of it is
  presented as an admissible candidate.
  """

  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Generator
  alias GtfsPlanner.Gtfs.Blocking.Summary

  @type block :: %{
          block_id: String.t(),
          new?: true,
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          trips: [map()],
          day_type_keys: [String.t()]
        }

  @type exclusion :: %{subject: Ecto.UUID.t(), reason: atom()}

  @type t :: %{
          blocks: [block()],
          assignments: %{Ecto.UUID.t() => String.t()},
          preserved_block_ids: [String.t()],
          exclusions: [exclusion()],
          counts: %{
            blocks: non_neg_integer(),
            new_blocks: non_neg_integer(),
            new_assignments: non_neg_integer(),
            preserved_blocks: non_neg_integer(),
            rejected_blocks: non_neg_integer()
          },
          day_type_keys: [String.t()]
        }

  @doc """
  Composes the additive block candidate for `source` and `normalized_input`.

  An empty `day_types` list is a version with no active service in the selected
  range, and answers an empty candidate rather than an error: there is nothing
  to place and nothing to exclude.
  """
  @spec block_candidate(map(), map()) :: t()
  def block_candidate(source, normalized_input) do
    {runs, frozen} = generate_each_day(source)
    memberships = memberships(source, frozen)
    touched = MapSet.new(Map.values(frozen))
    rejected = rejected_blocks(memberships, touched, source.context)

    assignments = reject(frozen, rejected)

    %{
      blocks: new_blocks(memberships, assignments, source, normalized_input),
      assignments: assignments,
      preserved_block_ids: preserved_block_ids(memberships, source),
      exclusions: exclusions(runs, frozen, rejected),
      counts: counts(memberships, assignments, rejected, source),
      day_type_keys: Enum.map(source.day_types, & &1.key)
    }
  end

  # --- generation ------------------------------------------------------------

  # One run per affected day type, in the derivation order the source carries.
  # `frozen` accumulates the new moves the run accepted and is applied to the
  # next day's rows before that day runs: a trip placed on Monday keeps that
  # block on Saturday, which is what "one trip UUID, one stored `block_id`" means
  # while the candidate is still only in memory.
  defp generate_each_day(source) do
    {runs, frozen} =
      Enum.reduce(source.day_types, {[], %{}}, fn day_type, {runs, frozen} ->
        stored = Map.fetch!(source.rows_by_day_type, day_type.key)
        rows = Enum.map(stored, &%{&1 | block_id: Map.get(frozen, &1.id, &1.block_id)})

        # An ID this run has already handed out is in use from the next day type
        # on, so two day types cannot create the same number.
        used_ids = Enum.sort(Enum.uniq(source.used_block_ids ++ Map.values(frozen)))
        result = Generator.run(:unassigned_only, rows, source.context, used_ids)

        run = %{day_type: day_type, stored: stored, rows: rows, result: result}

        {[run | runs], Map.merge(frozen, accepted_moves(stored, result))}
      end)

    {Enum.reverse(runs), frozen}
  end

  # A move is new when the trip had no block in the database and the run gave it
  # one. A leftover keeps a `nil` assignment, and a trip the run held where it
  # was is not a move at all.
  defp accepted_moves(stored, result) do
    Enum.reduce(stored, %{}, fn row, accepted ->
      case Map.get(result.assignments, row.id) do
        block_id when is_binary(block_id) and is_nil(row.block_id) ->
          Map.put(accepted, row.id, block_id)

        _kept_where_it_was ->
          accepted
      end
    end)
  end

  # --- membership ------------------------------------------------------------

  # `block_id => day_type_key => [trip_row]` over every affected day type: the
  # completed rows with this run's new assignments frozen onto them. A trip this
  # run placed is therefore in its block on *every* day the trip runs, not only
  # the days the run was asked about, which is what makes a chain that is legal
  # on the selected dates but overlaps a trip of the same block elsewhere visible
  # here. The rows already carry the whole of every block they touch, so a block
  # shared with a date outside the range is read as itself rather than as the part
  # of it the range happened to hold.
  #
  # A `nil` assignment is a trip the run could not place at all, so it names no
  # block and belongs in the exclusions rather than in a block's membership: a
  # leftover with no block is exactly the case a block-keyed map cannot hold.
  defp memberships(source, frozen) do
    Enum.reduce(source.rows_by_day_type, %{}, fn {day_type_key, rows}, acc ->
      Enum.reduce(rows, acc, fn row, acc ->
        case Map.get(frozen, row.id, row.block_id) do
          nil -> acc
          block_id -> add_membership(acc, day_type_key, block_id, row)
        end
      end)
    end)
  end

  defp add_membership(acc, _day_type_key, _block_id, nil), do: acc

  defp add_membership(acc, day_type_key, block_id, row) do
    Map.update(acc, block_id, %{day_type_key => [row]}, fn days ->
      Map.update(days, day_type_key, [row], &[row | &1])
    end)
  end

  # A block with an `:error` finding on any affected day loses all of its new
  # moves. Only a block that received a new move is considered at all: an
  # existing block that is invalid keeps the trips it already holds, and this
  # candidate is not what decides its validity.
  defp rejected_blocks(memberships, touched, context) do
    Enum.reduce(memberships, MapSet.new(), fn {block_id, days}, rejected ->
      if MapSet.member?(touched, block_id) and invalid?(block_id, days, context) do
        MapSet.put(rejected, block_id)
      else
        rejected
      end
    end)
  end

  defp invalid?(block_id, days, context) do
    Enum.any?(days, fn {_day_type_key, trips} ->
      Checks.block_findings(block_id, trips, context)
      |> Enum.any?(&(&1.severity == :error))
    end)
  end

  defp reject(frozen, rejected) do
    frozen
    |> Enum.reject(fn {_trip_id, block_id} -> MapSet.member?(rejected, block_id) end)
    |> Map.new()
  end

  # --- blocks ----------------------------------------------------------------

  # Only a block the run created is a new block. `garage_source` decides whether
  # the selected garage is consulted at all: a block an attribute row, a route
  # setting or the version's own default already answered keeps that answer, and
  # only a block that resolved to `:none` takes the selected garage.
  #
  # A block whose attribute rows disagree is left out of the candidate. The
  # disagreement is the operator's data problem to fix, and resolving it by read
  # order would put a garage in the preview nobody chose.
  defp new_blocks(memberships, assignments, source, normalized_input) do
    existing = MapSet.new(source.used_block_ids)

    assignments
    |> Map.values()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(existing, &1))
    |> Enum.sort_by(&Summary.natural_key/1)
    |> Enum.map(fn block_id ->
      days = Map.fetch!(memberships, block_id)
      trips = union_trips(days)
      resolution = Context.resolve_block(source.context, block_id, trips)

      if is_nil(resolution.conflict) do
        %{
          block_id: block_id,
          new?: true,
          garage_id: garage(resolution, normalized_input),
          vehicle_type_id: resolution.vehicle_type_id,
          trips: trips,
          day_type_keys: day_type_keys(days)
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp garage(%{garage_source: :none}, %{"garage_id" => garage_id}), do: garage_id
  defp garage(resolution, _normalized_input), do: resolution.garage_id

  defp union_trips(days) do
    days
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq_by(& &1.id)
    |> Checks.sequence()
  end

  defp day_type_keys(days), do: days |> Map.keys() |> Enum.sort()

  # The blocks the completed scope read that already held trips in the database,
  # whether or not they were valid and whether or not new work was proposed for
  # them. A block this run created is never preserved, including one whose new
  # moves were refused: it was never there to preserve, and naming it here would
  # describe a block the database does not have.
  defp preserved_block_ids(memberships, source) do
    existing = MapSet.new(source.used_block_ids)

    memberships
    |> Map.keys()
    |> Enum.filter(&MapSet.member?(existing, &1))
    |> Enum.sort_by(&Summary.natural_key/1)
  end

  # --- exclusions ------------------------------------------------------------

  # Two sources that never overlap: what the generator could not place on any
  # day, and a new move lost because its block is invalid somewhere. `subject` is
  # the trip UUID, so one trip excluded on three day types is one exclusion.
  defp exclusions(runs, frozen, rejected) do
    unplaced = Enum.flat_map(runs, &leftover_exclusions/1)

    lost =
      Enum.flat_map(frozen, fn {trip_id, block_id} ->
        if MapSet.member?(rejected, block_id) do
          [%{subject: trip_id, reason: :invalid_cross_day}]
        else
          []
        end
      end)

    Enum.sort_by(unplaced ++ lost, &{&1.subject, &1.reason})
  end

  defp leftover_exclusions(run) do
    Enum.map(run.result.leftovers, &%{subject: &1.trip.id, reason: &1.reason})
  end

  # `blocks` is every block the run read, whatever became of it;
  # `preserved_blocks` is the subset that already held trips in the database; and
  # `rejected_blocks` is the new ones whose moves were refused. `preserved` and
  # `new` therefore partition `blocks` the same way `preserved_block_ids/2` does, so
  # the count and the list cannot disagree.
  defp counts(memberships, assignments, rejected, source) do
    new_ids = MapSet.new(Map.values(assignments))
    preserved = preserved_block_ids(memberships, source)

    %{
      blocks: map_size(memberships),
      new_blocks: MapSet.size(new_ids),
      new_assignments: map_size(assignments),
      preserved_blocks: length(preserved),
      rejected_blocks: MapSet.size(rejected)
    }
  end
end

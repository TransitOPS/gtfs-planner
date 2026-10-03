defmodule GtfsPlanner.Gtfs.TodsGenerator.Plan do
  @moduledoc """
  The pure candidate of one TODS generation request: its blocks and its runs.

  This module composes; it never reads and never writes. Everything it decides
  from arrives in `source`, the map the `TodsGenerator` source loader built
  inside one read snapshot:

      %{day_types: [Blocking.DayTypes.day_type()],
        version_day_types: [Blocking.DayTypes.day_type()],
        rows_by_day_type: %{day_type_key => [Blocking.Queries.trip_row()]},
        context: Blocking.Context.t(),
        used_block_ids: [String.t()]}

  `day_types` is the generation order — the day types the request selected —
  while `rows_by_day_type` also carries the affected day types the completed
  blocks reach, which is what validity is decided over. `version_day_types` is
  every day type the version derives, which is what the roster stage resolves the
  base week and the recurring dates against: a roster slot repeats by weekday and
  base day type, so a weekday the request did not select still decides where a
  slot lands.

  `normalized_input` is `TodsGenerator.Input.normalize/1`'s canonical map. Only
  its `"garage_id"` and its `"terminal_relief?"` are read here.

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
      garage. A block whose attribute rows disagree has no garage this candidate
      can name, so the block and every new move onto it are refused as a unit.

  ## What the crew stage adds

  `with_runs/3` cuts the uncovered work of the blocks this candidate presents
  through `Runs.Cutter.run(:uncovered_only, ...)` and composes the day through
  `Runs.Day.derive/4` — the same two owners the Runs page uses, so a duty here is
  the duty the page would cut. The result adds the run deltas, the derived run
  days, the relief marks the runs would need, the warnings of the days it keeps
  and the trips it refused. Three rules decide what is admitted:

    * **Existing runs are never touched.** Only uncovered work is cut, the stored
      assignments are the base the cutter merges onto, and numbering continues
      above the IDs already in use. An existing run is neither removed nor
      repaired, whatever its findings say.
    * **A new run the generator cannot stand behind is refused as a unit.** A run
      carrying an `:error` finding (a handover away from relief, a piece that
      cannot be reached), a run with an unknown travel leg, and a run whose own
      gaps are impossible or unmeasurable are all refused, and *all* of their
      trips are reported uncovered. Half a duty is not a smaller wrong answer: it
      is a duty with fewer of its trips on it.
    * **Harmless warnings stay visible.** A piece over the piece limit, a spread
      over the crew limit and an estimated travel time do not refuse a run; they
      are reported in `warnings`, because the domain itself grades them as
      warnings and a generator that silently dropped every duty an operator might
      want to look at would be answering a different question.

  ## Hypothetical terminal relief

  `"terminal_relief?"` is off by default and adds nothing. When it is on, the
  crew stage proposes marks — same-place marks only, at a feasible layover's own
  standing stop, named the way the Operator changes drawer stores a mark — and
  re-derives the windows with them, so a block the piece limit makes impossible
  can end in two legal duties instead of one impossible one. The proposed marks
  are additive: the stored marks are never overwritten, the piece limit is never
  changed, and every proposed mark a run of the reported day hands over at is
  reported — a stored run's handover included, because the reported day was
  derived with that mark and a preview that omitted it would promise a day the
  save could not write. What the stage assumes is reported in `assumptions`
  rather than hidden in the numbers.

  ## What the roster stage adds

  `with_roster/3` maps the runs to the roster the version would hold: the base-week
  choices the request needs, one single-slot line and one fictional operator per
  exportable run-day no line holds, the run-days it leaves unstaffed, the findings
  of the roster that leaves, and the recurring coverage that roster reaches. It
  composes the version's own owners — `Rosters.BaseWeek.resolve/2`,
  `Rosters.Roster.build/1` and `Rosters.AssignmentsExport.rows/1` — over the runs
  the crew stage derived, so the dates, the base-week fallback and the
  previous-date shift are the exporter's own rules rather than a second
  implementation. Four rules decide what a generation would add:

    * **A weekday the version already answers is kept.** A stored base choice, and a
      weekday holding slots a planner set by hand, keep the base they have: moving
      it would make those slots `:base_changed`. Where the representative date works
      a different day type than such a weekday, the request's work there is refused
      rather than delivered by moving a choice the operator owns.
    * **Every other weekday takes the representative date's day type** — and only
      where that differs from the base the version would resolve anyway, so a
      compatible base is left alone and the stored settings change only where the
      request needs them to.
    * **One line per run-day, deliberately overstaffed.** Every exportable run a
      weekday's base day type has and no line holds gets a line of its own holding
      one slot, and an operator of its own, even when the same run works five
      weekdays. This gives up realistic weekly duties and gains an allocation that
      cannot create a cross-day rest conflict; the count is disclosed rather than
      optimized away.
    * **Held, stale and error work is never edited.** A run-day a line holds is not
      proposed again whatever the slot's state says, and a run the export drops
      because of an error finding is not proposed at all.

  ## The result

      %{blocks: [%{block_id:, new?: true, garage_id:, vehicle_type_id:,
                   trips: [trip_row()], day_type_keys: [String.t()]}],
        assignments: %{trip_uuid => block_id},
        preserved_block_ids: [String.t()],
        run_deltas: %{day_type_key => %{trip_uuid => run_id}},
        run_days: %{day_type_key => Runs.Day.derived()},
        relief_additions: [String.t()],
        roster_day_types: %{weekday => day_type_key},
        roster_lines: [roster_line()],
        roster_exclusions: [%{subject: {weekday, day_type_key, run_id}, reason: atom()}],
        roster_findings: [roster_finding()],
        hard_errors: [hard_error()],
        coverage: coverage(),
        assumptions: [atom()],
        warnings: [run_warning()],
        exclusions: [%{subject: Ecto.UUID.t(), reason: atom(), block_id: String.t() | nil}],
        counts: %{...},
        day_type_keys: [String.t()]}

  `assignments` holds new block moves only; a trip that already had a block is
  not in it, because nothing about it changes. `run_deltas` holds new run
  assignments only, for the same reason. `roster_day_types` holds the base-week
  entries a save would add, never the whole stored map. Every list in the result
  is sorted by a natural key, so the same source facts in any order produce the
  same candidate.

  ## Why the checks are asked twice

  `Blocking.Generator` places a trip by testing it against the *last* trip of an
  open block, so it never builds a whole trial sequence for a chain it accepts
  and it makes no claim about a trip's non-adjacent neighbours. `Checks` reads
  the whole sequence and is what the rest of the planner trusts. This step is
  where the two meet: the generator proposes, and the union candidate is
  re-read through the checks on every affected day before any of it is
  presented as an admissible candidate.
  """

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Checks
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.Generator
  alias GtfsPlanner.Gtfs.Blocking.Movements
  alias GtfsPlanner.Gtfs.Blocking.Relief
  alias GtfsPlanner.Gtfs.Blocking.Summary
  alias GtfsPlanner.Gtfs.Rosters.AssignmentsExport
  alias GtfsPlanner.Gtfs.Rosters.BaseWeek
  alias GtfsPlanner.Gtfs.Rosters.Roster
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.Runs.Cutter
  alias GtfsPlanner.Gtfs.Runs.Day

  @type block :: %{
          block_id: String.t(),
          new?: true,
          garage_id: Ecto.UUID.t() | nil,
          vehicle_type_id: Ecto.UUID.t() | nil,
          trips: [map()],
          day_type_keys: [String.t()]
        }

  @typedoc """
  One piece of work the candidate does not present, and the block it sits in.

  `subject` is the trip UUID and `reason` names the decision that reported it.
  `block_id` is the block the trip holds in the candidate, or `nil` when it holds
  none: a trip the generator placed in a single-trip block it cannot stand behind is
  *kept and reported*, and a trip it could not place at all is not, and the stored
  block ID is what tells the two apart without re-reading `assignments`/`blocks`.
  """
  @type exclusion :: %{subject: Ecto.UUID.t(), reason: atom(), block_id: String.t() | nil}

  @typedoc """
  One derived run day's warnings and notices, tagged with the day type they were
  derived for. The fields are `GtfsPlanner.Gtfs.Runs.Checks`' own, so a consumer
  renders a run's warning with the same code, severity and detail it renders a
  day's findings with.
  """
  @type run_warning :: %{
          day_type_key: String.t(),
          code: atom(),
          severity: :warning | :notice,
          run_ids: [String.t()],
          block_id: String.t() | nil,
          trip_ids: [Ecto.UUID.t()],
          detail: map()
        }

  @typedoc """
  The figures the block stage reports: how many blocks the candidate presents, how
  many it created, how many trips it moved, how many blocks already held trips, and
  how many blocks it refused.
  """
  @type block_counts :: %{
          blocks: non_neg_integer(),
          new_blocks: non_neg_integer(),
          new_assignments: non_neg_integer(),
          preserved_blocks: non_neg_integer(),
          rejected_blocks: non_neg_integer()
        }

  @typedoc """
  The figures of the whole candidate: the block stage's, plus the runs the crew
  stage admits and refuses and the lines, slots and operators the roster stage
  would add beside the stored ones it leaves in place.
  """
  @type counts :: %{
          blocks: non_neg_integer(),
          new_blocks: non_neg_integer(),
          new_assignments: non_neg_integer(),
          preserved_blocks: non_neg_integer(),
          rejected_blocks: non_neg_integer(),
          new_runs: non_neg_integer(),
          refused_runs: non_neg_integer(),
          new_lines: non_neg_integer(),
          new_slots: non_neg_integer(),
          new_operators: non_neg_integer(),
          preserved_lines: non_neg_integer(),
          preserved_slots: non_neg_integer(),
          preserved_operators: non_neg_integer(),
          open_run_days: non_neg_integer()
        }

  @typedoc """
  One single-slot line a generation would add, with the fictional operator that
  would hold it.

  `operator_ordinal` is the position the save names the operator by; its employee
  ID carries the request UUID, which is transport rather than business input, so
  the preview reports the ordinal instead of inventing the name. The times are the
  derived run's own sign-on and sign-off, which is what makes the stored slot
  fresh rather than stale.
  """
  @type roster_line :: %{
          weekday: 1..7,
          day_type_key: String.t(),
          run_id: String.t(),
          run_sign_on_secs: integer(),
          run_sign_off_secs: integer(),
          operator_ordinal: pos_integer()
        }

  @typedoc """
  One run-day the plan leaves unstaffed, and why.

  `subject` is `{weekday, day_type_key, run_id}` — the run-day a roster line holds
  — because a run is one identity across the weekdays it works: a refusal that
  named a trip would say nothing about the same run's other days. A run-day
  appears once, under the first reason that applies: its day type is not its
  weekday's base (`:no_base_weekday`, so no recurring line can reach it), the
  export drops the run (`:run_has_errors`), or a stored slot holds it without
  being exportable (`:stale_slot`).
  """
  @type roster_exclusion :: %{
          subject: {1..7, String.t(), String.t()},
          reason: :no_base_weekday | :run_has_errors | :stale_slot
        }

  @typedoc """
  A plan-level error. A save is unavailable while one is present: the request
  cannot be delivered without editing a choice the operator owns, so generating
  part of it would write a roster nobody asked for.
  """
  @type hard_error :: %{
          reason: :base_conflict,
          weekday: 1..7,
          day_type_key: String.t(),
          retained_day_type_key: String.t() | nil
        }

  @typedoc """
  One finding of the roster the plan would leave, for a line it would add
  (`operator_ordinal` set) or keep (`line_number` set). The code, weekdays and
  detail are `Rosters.Roster`'s own, so a warning reads the way the Rosters page
  writes it.
  """
  @type roster_finding :: %{
          line_number: pos_integer() | nil,
          operator_ordinal: pos_integer() | nil,
          code: atom(),
          weekdays: [1..7],
          detail: map()
        }

  @typedoc """
  One weekday of the base week the plan composes with, and where it came from.

  `day_type_key` is the day type the weekday works, `chosen?` is true when a
  stored choice answered it, `added?` is true when this request would have to
  store the representative date's choice to reach it, and `missing_choice` is a
  stored key `BaseWeek.resolve/2` could not use.
  """
  @type base_week_day :: %{
          weekday: 1..7,
          day_type_key: String.t() | nil,
          chosen?: boolean(),
          added?: boolean(),
          missing_choice: String.t() | nil
        }

  @typedoc """
  What a would-be generation reaches, from the exporter's own dates.

  A roster slot repeats by weekday and base day type, so the range scopes which
  input was selected and *not* which dates a saved slot affects: `affected_dates`
  is every date of a staffed weekday's base day type, `beyond_range_dates` is the
  part of it outside the selected range, `open_dates` is the selected dates with
  service the plan leaves unstaffed, `other_service_dates` is the dates whose day
  type is not their weekday's base (different service, nothing exported for them),
  and `exported_dates` is the dates and services `AssignmentsExport.rows/1` would
  write — a run signing on before midnight is dated the previous day.
  """
  @type coverage :: %{
          range: %{start_date: Date.t(), end_date: Date.t(), representative_week: Date.t()},
          base_week: [base_week_day()],
          affected_dates: [Date.t()],
          beyond_range_dates: [Date.t()],
          open_dates: [Date.t()],
          other_service_dates: [Date.t()],
          exported_dates: [%{date: Date.t(), service_id: String.t() | nil}]
        }

  @typedoc """
  What `block_candidate/2` decides: the blocks one request would add, the trips
  they would move, what was refused and the figures over those.
  """
  @type block_candidate :: %{
          blocks: [block()],
          assignments: %{Ecto.UUID.t() => String.t()},
          preserved_block_ids: [String.t()],
          exclusions: [exclusion()],
          counts: block_counts(),
          day_type_keys: [String.t()]
        }

  @typedoc """
  The complete candidate of one request: the block candidate plus the crew and
  roster stages.
  """
  @type t :: %{
          blocks: [block()],
          assignments: %{Ecto.UUID.t() => String.t()},
          preserved_block_ids: [String.t()],
          run_deltas: %{String.t() => %{Ecto.UUID.t() => String.t()}},
          run_days: %{String.t() => Day.derived()},
          relief_additions: [String.t()],
          roster_day_types: %{String.t() => String.t()},
          roster_lines: [roster_line()],
          roster_exclusions: [roster_exclusion()],
          roster_findings: [roster_finding()],
          hard_errors: [hard_error()],
          coverage: coverage(),
          assumptions: [atom()],
          warnings: [run_warning()],
          exclusions: [exclusion()],
          counts: counts(),
          day_type_keys: [String.t()]
        }

  @doc """
  Composes the additive block candidate for `source` and `normalized_input`.

  An empty `day_types` list is a version with no active service in the selected
  range, and answers an empty candidate rather than an error: there is nothing
  to place and nothing to exclude.
  """
  @spec block_candidate(map(), map()) :: block_candidate()
  def block_candidate(source, normalized_input) do
    {runs, frozen} = generate_each_day(source)
    memberships = memberships(source, frozen)
    touched = MapSet.new(Map.values(frozen))
    refused = refused_blocks(memberships, touched, source.context)

    assignments = reject(frozen, refused)

    %{
      blocks: new_blocks(memberships, assignments, source, normalized_input),
      assignments: assignments,
      preserved_block_ids: preserved_block_ids(memberships, source),
      exclusions: exclusions(runs, frozen, refused),
      counts: counts(memberships, assignments, refused, source),
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

  # A block that received a new move and is refused as a unit, with the reason its
  # moves are refused: an `:error` finding on any affected day, or attribute rows
  # that disagree about the block's garage or type. Both are decisions the
  # operator's data has to settle, and resolving either by read order — half a
  # chain, or whichever attribute row was read first — would put work in the
  # preview nobody chose. A block nothing was proposed for is not considered at
  # all: an existing block that is invalid keeps the trips it already holds, and
  # this candidate is not what decides its validity.
  defp refused_blocks(memberships, touched, context) do
    for {block_id, days} <- memberships,
        MapSet.member?(touched, block_id),
        reason = refusal(block_id, days, context),
        not is_nil(reason),
        into: %{},
        do: {block_id, reason}
  end

  defp refusal(block_id, days, context) do
    if invalid?(block_id, days, context) do
      :invalid_cross_day
    else
      conflict(block_id, days, context)
    end
  end

  defp conflict(block_id, days, context) do
    if is_nil(Context.resolve_block(context, block_id, union_trips(days)).conflict) do
      nil
    else
      :block_attributes_conflict
    end
  end

  defp invalid?(block_id, days, context) do
    Enum.any?(days, fn {_day_type_key, trips} ->
      Checks.block_findings(block_id, trips, context)
      |> Enum.any?(&(&1.severity == :error))
    end)
  end

  defp reject(frozen, refused) do
    frozen
    |> Enum.reject(fn {_trip_id, block_id} -> Map.has_key?(refused, block_id) end)
    |> Map.new()
  end

  # --- blocks ----------------------------------------------------------------

  # Only a block the run created is a new block. `garage_source` decides whether
  # the selected garage is consulted at all: a block an attribute row, a route
  # setting or the version's own default already answered keeps that answer, and
  # only a block that resolved to `:none` takes the selected garage. A block whose
  # attribute rows disagree never reaches here: it was refused with its moves,
  # because resolving it by read order would put a garage in the preview nobody
  # chose.
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

      %{
        block_id: block_id,
        new?: true,
        garage_id: garage(resolution, normalized_input),
        vehicle_type_id: resolution.vehicle_type_id,
        trips: trips,
        day_type_keys: day_type_keys(days)
      }
    end)
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

  # The two sources of work the candidate does not present, which can name the same
  # trip: the leftovers a day's run reported — including a trip it kept in a
  # single-trip block too long for its vehicle or relief limit — and a new move lost
  # with the block it was going onto. `subject` is the trip UUID, so a trip reported
  # on several day types is one exclusion once the preview's list is deduped, and
  # `block_id` is the block the trip holds, which is what separates "kept and
  # reported" from "not placed at all".
  defp exclusions(runs, frozen, refused) do
    unplaced = Enum.flat_map(runs, &leftover_exclusions/1)

    lost =
      Enum.flat_map(frozen, fn {trip_id, block_id} ->
        case Map.fetch(refused, block_id) do
          {:ok, reason} -> [%{subject: trip_id, reason: reason, block_id: block_id}]
          :error -> []
        end
      end)

    Enum.sort_by(unplaced ++ lost, &{&1.subject, &1.reason})
  end

  defp leftover_exclusions(run) do
    Enum.map(
      run.result.leftovers,
      &%{subject: &1.trip.id, reason: &1.reason, block_id: &1.block_id}
    )
  end

  # `blocks` is the blocks the candidate presents: the new ones `new_blocks/4`
  # emits plus the ones it preserved, so it is exactly `new_blocks +
  # preserved_blocks` and reconciles with the `blocks` list and
  # `preserved_block_ids/2`. A block a refused move was destined for is not
  # presented, so it is counted in `rejected_blocks` alone — while a preserved
  # block that lost a new move is in `preserved_blocks` as well, because the two
  # figures answer different questions and are not a partition of one another.
  defp counts(memberships, assignments, refused, source) do
    new_ids = MapSet.new(Map.values(assignments))
    preserved = preserved_block_ids(memberships, source)

    %{
      blocks: MapSet.size(new_ids) + length(preserved),
      new_blocks: MapSet.size(new_ids),
      new_assignments: map_size(assignments),
      preserved_blocks: length(preserved),
      rejected_blocks: map_size(refused)
    }
  end

  # --- crew stage -------------------------------------------------------------

  @doc """
  Adds the crew stage: the runs the generation would add on top of `candidate`,
  and the relief marks it would have to add to make them legal.

  The block candidate is cut through `Runs.Cutter.run(:uncovered_only, ...)` and
  composed through `Runs.Day.derive/4` for each selected day type, with the source
  loader's stored assignments as the base, so no existing run is removed or
  renumbered. A generated run the generator cannot stand behind is refused as a
  unit and its trips are reported uncovered; the reported day is then the day that
  leaves.

  Pure, like the rest of this module: no read, no write, no clock and no network.
  """
  @spec with_runs(block_candidate(), map(), map()) :: t()
  def with_runs(candidate, source, normalized_input) do
    crew = Map.fetch!(source.rules, :crew)
    days = candidate_days(candidate, source)
    {marks, marks_by_stop} = relief_marks(days, source, normalized_input)
    context = marked_context(source.context, marks)

    results =
      Enum.map(source.day_types, fn day_type ->
        run_day(
          Map.fetch!(days, day_type.key),
          day_type.key,
          source,
          context,
          crew,
          marks_by_stop
        )
      end)

    Map.merge(candidate, %{
      run_deltas: Map.new(results, &{&1.day_type_key, &1.run_deltas}),
      run_days: Map.new(results, &{&1.day_type_key, &1.run_day}),
      relief_additions: used_marks(results),
      assumptions: assumptions(marks),
      warnings: Enum.flat_map(results, & &1.warnings),
      exclusions: merge_exclusions(candidate.exclusions, results),
      counts: Map.merge(candidate.counts, run_counts(results))
    })
  end

  # One day type's block inputs: this day's completed rows, with this run's new
  # block assignments frozen onto them, grouped by the block each trip is in. Only
  # the blocks the block candidate presents are built — a block it refused is not a
  # block a duty may be cut from.
  defp candidate_days(candidate, source) do
    admitted =
      MapSet.new(
        candidate.preserved_block_ids ++
          Enum.map(candidate.blocks, fn block -> block.block_id end)
      )

    Map.new(source.day_types, fn day_type ->
      {day_type.key, candidate_day(day_type.key, candidate, source, admitted)}
    end)
  end

  defp candidate_day(key, candidate, source, admitted) do
    blocks =
      source.rows_by_day_type
      |> Map.fetch!(key)
      |> Enum.group_by(&Map.get(candidate.assignments, &1.id, &1.block_id))
      |> Enum.reject(fn {block_id, _rows} -> is_nil(block_id) end)
      |> Enum.filter(fn {block_id, _rows} -> MapSet.member?(admitted, block_id) end)
      |> Enum.sort_by(fn {block_id, _rows} -> Summary.natural_key(block_id) end)
      |> Enum.map(fn {block_id, rows} -> candidate_block(block_id, rows, source.context) end)

    %{blocks: blocks, assignments: stored_assignments(key, blocks, source)}
  end

  # One existing block as the day load would build it: its sequence, its
  # resolution, its movements and the windows the version's own marks open. The
  # shape is the day load's, so `Runs.candidate_block_inputs/1` — the owner of the
  # input shape — is what turns it into the cutter's own argument.
  defp candidate_block(block_id, rows, context) do
    trips = Checks.sequence(rows)
    resolution = Context.resolve_block(context, block_id, trips)
    movements = Movements.build(trips, resolution, context)

    %{
      summary: %{block_id: block_id},
      trips: trips,
      movements: movements,
      windows: Relief.windows(trips, movements, context)
    }
  end

  # The day's stored run assignments, restricted to the trips this day's blocks
  # actually hold — the set `Runs.load_runs/3` cuts from, so a stored row for a trip
  # that has left the day type cannot push the numbering of a duty here.
  defp stored_assignments(key, blocks, source) do
    stored = Map.get(Map.fetch!(source.rules, :trip_runs), key, %{})
    Map.take(stored, blocks |> Enum.flat_map(& &1.trips) |> Enum.map(& &1.id))
  end

  # The marks `"terminal_relief?"` would add, and the stop each is named by.
  #
  # Only a same-place handover is offered: a feasible layover, where the vehicle
  # stands at one place and an operator change needs no travel at all. A drive's
  # end is not offered, because a handover there is a move the version's own
  # transfer rules judge and the generator does not get to relax them. The mark is
  # named the way the Operator changes drawer stores one, so a later save writes
  # the same place the drawer would list, and a mark the version already holds is
  # not proposed at all.
  defp relief_marks(days, source, normalized_input) do
    if Map.get(normalized_input, "terminal_relief?") do
      proposed =
        days
        |> Enum.flat_map(fn {_key, day} -> Enum.flat_map(day.blocks, &layover_places/1) end)
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.reject(fn {_stop_id, mark} ->
          MapSet.member?(source.context.relief_stop_ids, mark)
        end)
        |> Map.new()

      {MapSet.new(Map.values(proposed)), proposed}
    else
      {MapSet.new(), %{}}
    end
  end

  # One block's same-place handover places, as `{standing stop, stored mark}` pairs.
  # The gap's own facts decide: only a feasible layover is a place the vehicle
  # waits at, and an infeasible or unmeasurable gap is a place this stage must not
  # invent a relief point at.
  defp layover_places(block) do
    block.trips
    |> Enum.zip(Enum.drop(block.trips, 1))
    |> Enum.zip(block.movements.gaps)
    |> Enum.flat_map(fn {{from, to}, gap} -> layover_place(from, to, gap) end)
  end

  defp layover_place(from, to, %{kind: :layover, feasible?: true}),
    do: place_stop(from.last_stop || to.first_stop)

  defp layover_place(_from, _to, _gap), do: []

  # The place the vehicle is standing at across a layover, which is the stop
  # `Blocking.Relief.windows/3` names for a same-place window: the incoming trip's
  # last stop, and the outgoing trip's first where the incoming trip names none. A
  # mark for a child stop is stored under its station, which is what
  # `Blocking.relief_candidate_stop_id/1` answers; a stop the version does not carry
  # has no place to mark.
  defp place_stop(nil), do: []
  defp place_stop(stop), do: [{stop.stop_id, Blocking.relief_candidate_stop_id(stop)}]

  defp marked_context(context, marks) do
    if MapSet.size(marks) == 0 do
      context
    else
      %{context | relief_stop_ids: MapSet.union(context.relief_stop_ids, marks)}
    end
  end

  # The windows are the only thing a hypothetical mark changes, so they are what is
  # rebuilt: the trips, the movements and the resolution are the same facts.
  defp rewindow(blocks, context) do
    Enum.map(blocks, fn block ->
      %{block | windows: Relief.windows(block.trips, block.movements, context)}
    end)
  end

  # One day type's crew derivation: cut the uncovered work, refuse the runs the
  # generator cannot stand behind, and report the day that leaves.
  defp run_day(day, key, _source, context, crew, marks_by_stop) do
    blocks = Runs.candidate_block_inputs(%{blocks: rewindow(day.blocks, context)})
    existing = day.assignments

    cut = Cutter.run(:uncovered_only, blocks, existing, context, crew)
    proposed = cut.assignments
    derived = Day.derive(blocks, proposed, context, crew)

    refused = refused_runs(derived, cut.new_run_ids)
    admitted = drop_refused(proposed, refused)
    admitted_ids = Enum.reject(cut.new_run_ids, &Map.has_key?(refused, &1))

    # A refused run's trips are uncovered again, so the day is derived from the
    # assignments that are left rather than patched: every figure, the uncovered
    # work and the findings then describe one assignment map.
    reported =
      if map_size(refused) == 0, do: derived, else: Day.derive(blocks, admitted, context, crew)

    %{
      day_type_key: key,
      run_deltas: Map.drop(admitted, Map.keys(existing)),
      run_day: reported,
      new_run_ids: admitted_ids,
      refused: refused,
      refusals: refusals(derived, refused),
      warnings: warnings(key, reported),
      marks: used_marks(reported, marks_by_stop)
    }
  end

  # The generated runs the generator does not stand behind, keyed by run. Only runs
  # this candidate would create are judged: an existing run's findings are the
  # operator's to fix, and this stage neither removes nor repairs them.
  defp refused_runs(derived, new_run_ids) do
    created = MapSet.new(new_run_ids)

    for run <- derived.runs,
        MapSet.member?(created, run.run_id),
        reason = refusal(run),
        not is_nil(reason),
        into: %{},
        do: {run.run_id, reason}
  end

  # The finding's own code is the reason, so a refusal reads as the check that made
  # it: a handover away from relief, or a piece that cannot be reached.
  defp refusal(run) do
    case Enum.find(run.findings, &(&1.severity == :error)) do
      %{code: code} -> code
      nil -> travel_refusal(run)
    end
  end

  # Unknown travel is not zero and an impossible move is not a duty. `Runs.Checks`
  # reports an unknown leg as a notice and says nothing at all about a gap the
  # vehicle cannot make, so both are read off the run's own work: the travel legs it
  # would be paid for, and the gaps inside its own pieces.
  defp travel_refusal(run) do
    if run.work.unknown_travel == [] do
      run.pieces
      |> Enum.flat_map(& &1.gaps)
      |> Enum.find_value(&unmeasurable/1)
    else
      :travel_unknown
    end
  end

  defp unmeasurable(%{kind: :unknown}), do: :travel_unknown
  defp unmeasurable(%{feasible?: false}), do: :cannot_reach
  defp unmeasurable(_gap), do: nil

  defp drop_refused(assignments, refused) do
    if map_size(refused) == 0 do
      assignments
    else
      Map.reject(assignments, fn {_trip_id, run_id} -> Map.has_key?(refused, run_id) end)
    end
  end

  # Every trip of a refused run, with the reason its run was refused and the block
  # the piece was cut from. The trips go back to uncovered, and this names which one
  # they went back for and which block they are still in.
  defp refusals(_derived, refused) when map_size(refused) == 0, do: []

  defp refusals(derived, refused) do
    derived.runs
    |> Enum.filter(&Map.has_key?(refused, &1.run_id))
    |> Enum.flat_map(fn run ->
      reason = Map.fetch!(refused, run.run_id)

      run.pieces
      |> Enum.flat_map(fn piece ->
        Enum.map(piece.trips, &%{subject: &1.id, reason: reason, block_id: piece.block_id})
      end)
    end)
  end

  # The reported day's warnings and notices, tagged with the day type they were
  # derived for. The errors are not repeated here: a refused run's cause is in the
  # exclusions, and an existing run's error is in the day's own findings.
  defp warnings(key, reported) do
    reported.findings
    |> Enum.reject(&(&1.severity == :error))
    |> Enum.map(&Map.put(&1, :day_type_key, key))
  end

  # The proposed marks the reported day's runs hand over at, stored runs included.
  # A stored run's handover is reported for the same reason an admitted one's is:
  # the day that is reported was derived with the mark in the context, so a save
  # that did not write the mark would leave the version holding a different day
  # than the one the operator was shown. A mark nothing hands over at is not
  # reported: the operator asked for legal duties, not for hypothetical marks
  # nobody used.
  defp used_marks(_reported, marks_by_stop) when map_size(marks_by_stop) == 0, do: []

  defp used_marks(reported, marks_by_stop) do
    reported.runs
    |> Enum.flat_map(& &1.pieces)
    |> Enum.flat_map(&relief_stop_ids/1)
    |> Enum.map(&Map.get(marks_by_stop, &1))
    |> Enum.reject(&is_nil/1)
  end

  # The stops one piece hands over at. Only a relief boundary names one: a piece
  # that starts or ends its block hand over at no marked place.
  defp relief_stop_ids(piece) do
    []
    |> add_relief_stop(piece.start_kind, piece.start_ref)
    |> add_relief_stop(piece.end_kind, piece.end_ref)
  end

  defp add_relief_stop(stops, :relief, {:stop, stop_id}), do: [stop_id | stops]
  defp add_relief_stop(stops, _kind, _ref), do: stops

  defp used_marks(results) do
    results
    |> Enum.flat_map(& &1.marks)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The one thing the crew stage assumes, in the operator's terms: a mark this
  # candidate proposes is hypothetical and additive, never a change to the
  # version's stored relief choices or to the piece limit.
  defp assumptions(marks) do
    if MapSet.size(marks) == 0, do: [], else: [:terminal_relief_additive]
  end

  # One run is one run on one day type, so these are sums over the days rather than
  # over a set of run IDs: the same ID on two day types is two runs.
  defp run_counts(results) do
    %{
      new_runs: results |> Enum.map(&length(&1.new_run_ids)) |> Enum.sum(),
      refused_runs: results |> Enum.map(&map_size(&1.refused)) |> Enum.sum()
    }
  end

  defp merge_exclusions(candidate_exclusions, results) do
    (candidate_exclusions ++ Enum.flat_map(results, & &1.refusals))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.subject, &1.reason})
  end

  # --- roster stage -----------------------------------------------------------

  @doc """
  Adds the roster stage: the base-week choices, the single-slot lines and the
  fictional operators a generation would add, the run-days it leaves unstaffed, the
  findings of the roster that leaves, and the recurring coverage it reaches.

  The composition is the version's own: `Rosters.BaseWeek.resolve/2` answers each
  weekday's base day type, `Rosters.Roster.build/1` composes the roster over the
  runs the crew stage derived, and `Rosters.AssignmentsExport.rows/1` expands it to
  the dates the exporter would write. Nothing here re-derives a base-week fallback,
  a date's day type or the previous-date shift of a run signing on before midnight.

  Pure, like the rest of this module: no read, no write, no clock and no network.
  """
  @spec with_roster(t(), map(), map()) :: t()
  def with_roster(candidate, source, input) do
    day_types = Map.fetch!(source, :version_day_types)
    rules = Map.fetch!(source, :rules)
    settings = Map.fetch!(rules, :roster)
    runs = candidate.run_days

    stored_base = BaseWeek.resolve(day_types, settings.roster_day_types)

    {additions, hard_errors} =
      base_choices(input, day_types, stored_base, rules.roster_lines, runs)

    base_week = BaseWeek.resolve(day_types, Map.merge(settings.roster_day_types, additions))

    # Two compositions: the version's own lines answer which run-days are still
    # open, and the lines a generation would add are then composed beside them, so
    # the coverage and the findings describe the roster a save would leave.
    kept = composed_stored_lines(rules.roster_lines, runs)
    proposals = proposals(compose(base_week, runs, kept, settings))
    roster = compose(base_week, runs, kept ++ Enum.map(proposals, &composed_proposal/1), settings)

    assignments =
      AssignmentsExport.rows(%{
        roster: roster,
        day_types: day_types,
        run_days: runs,
        # The export's own service reservation (`TodsExport`) names the `_prev`
        # service; a preview holds no supplement, so it reports the date the
        # exporter shifts to and leaves the service to the export that writes it.
        services: nil
      })

    coverage = coverage(input, day_types, runs, assignments, roster, stored_base, additions)

    Map.merge(candidate, %{
      roster_day_types: additions,
      roster_lines: proposals,
      roster_exclusions: roster_exclusions(base_week, runs, roster, day_types),
      roster_findings: roster_findings(roster, proposals),
      hard_errors: hard_errors,
      coverage: coverage,
      assumptions: assumptions(candidate.assumptions, proposals, coverage),
      counts: Map.merge(candidate.counts, roster_counts(roster, kept, proposals))
    })
  end

  defp compose(base_week, runs, lines, settings) do
    Roster.build(%{base_week: base_week, run_days: runs, lines: lines, rules: settings})
  end

  # --- the base week ----------------------------------------------------------

  # One choice per weekday of the representative week.
  #
  # A weekday the version already answers is kept: a stored choice, and a weekday
  # holding slots a planner set by hand, keep the base they have, because moving it
  # is what makes those slots `:base_changed`. Where the representative date works a
  # different day type than such a weekday, the request's work there is refused —
  # reported as a `:base_conflict` — rather than delivered by moving the operator's
  # own choice.
  #
  # Every other weekday takes the representative date's own day type, and only
  # where that differs from the base the version would resolve anyway: a compatible
  # base needs no stored change, and `roster_day_types` is what a save would write.
  # A representative date whose day type the request did not select is left out
  # entirely: the request holds no runs for it, so choosing it would strand the
  # weekday's selected work with nothing to staff it.
  defp base_choices(input, day_types, stored_base, stored_lines, runs) do
    dates = date_day_types(day_types)
    manual = manual_weekdays(stored_lines)
    composed = MapSet.new(Map.keys(runs))

    {additions, conflicts} =
      Enum.reduce(representative_week(input), {%{}, []}, fn date, {additions, conflicts} ->
        weekday = Date.day_of_week(date)
        base = Map.fetch!(stored_base, weekday)
        representative = Map.get(dates, date)

        cond do
          is_nil(representative) ->
            {additions, conflicts}

          not MapSet.member?(composed, representative.key) ->
            {additions, conflicts}

          base_key(base) == representative.key ->
            {additions, conflicts}

          protected?(base, manual, weekday) ->
            {additions, [base_conflict(weekday, base, representative) | conflicts]}

          true ->
            {Map.put(additions, Integer.to_string(weekday), representative.key), conflicts}
        end
      end)

    {additions, conflicts |> Enum.reverse() |> Enum.filter(&conflicting_work?(&1, runs))}
  end

  defp protected?(base, manual, weekday), do: base.chosen? or MapSet.member?(manual, weekday)

  defp base_conflict(weekday, base, representative) do
    %{
      reason: :base_conflict,
      weekday: weekday,
      day_type_key: representative.key,
      retained_day_type_key: base_key(base)
    }
  end

  # A conflict is only a hard error where the request actually has work: a day type
  # with no exportable run leaves nothing to refuse, and a plan that already cannot
  # be staffed there is a partial outcome rather than an unusable request.
  defp conflicting_work?(conflict, runs) do
    runs |> day_runs(conflict.day_type_key) |> Enum.any?(&(not error_run?(&1)))
  end

  defp base_key(%{day_type: %{key: key}}), do: key
  defp base_key(%{day_type: nil}), do: nil

  # Every date one day type answers. `DayTypes.derive/1` partitions the version's
  # dates by exact service set, so a date belongs to one day type.
  defp date_day_types(day_types) do
    for day_type <- day_types, date <- day_type.dates, into: %{}, do: {date, day_type}
  end

  defp manual_weekdays(stored_lines) do
    stored_lines
    |> Enum.flat_map(& &1.days)
    |> Enum.map(& &1.weekday)
    |> MapSet.new()
  end

  defp representative_week(input) do
    monday = Date.from_iso8601!(Map.fetch!(input, "representative_week"))
    Enum.map(0..6, &Date.add(monday, &1))
  end

  # --- the lines --------------------------------------------------------------

  # Every exportable run of a base day type that no line holds, in weekday order,
  # each with the ordinal the save would name its operator by. `Roster.build/1`
  # answers the open work: a run-day a stored slot holds is not in it, whatever that
  # slot's state says, and a run the export drops because of an error finding is
  # left out here for the same reason.
  defp proposals(roster) do
    roster.groups
    |> Enum.flat_map(&group_proposals/1)
    |> Enum.sort_by(&{&1.weekday, &1.run_id})
    |> Enum.with_index(1)
    |> Enum.map(fn {proposal, ordinal} -> Map.put(proposal, :operator_ordinal, ordinal) end)
  end

  # One base day type's open run-days, one proposal each. A run the export drops
  # because of an error finding is not offered: a line holding it would hold work
  # that can never be written.
  defp group_proposals(group) do
    for open_run <- group.open_runs,
        not error_run?(open_run.run),
        weekday <- open_run.open_weekdays,
        do: proposal(weekday, group.day_type.key, open_run.run)
  end

  defp proposal(weekday, key, run) do
    %{
      weekday: weekday,
      day_type_key: key,
      run_id: run.run_id,
      run_sign_on_secs: run.work.sign_on_secs,
      run_sign_off_secs: run.work.sign_off_secs
    }
  end

  # A stored line as the composition reads it, with the days this request composed
  # kept and the rest left out: a slot on a day type the request did not compose is
  # not this preview's to judge, and reporting its run as removed would be a claim
  # about a day type the composition holds no runs for. A line left with no day
  # leaves the composition entirely.
  defp composed_stored_lines(stored_lines, runs) do
    stored_lines
    |> Enum.map(&composed_stored_line(&1, runs))
    |> Enum.reject(&is_nil/1)
  end

  defp composed_stored_line(line, runs) do
    days = Enum.filter(line.days, &(Map.get(runs, &1.day_type_key) != nil))

    if days == [] do
      nil
    else
      %{
        id: line.id,
        line_number: line.line_number,
        operator: operator(line),
        days: Enum.map(days, &slot_input/1)
      }
    end
  end

  defp operator(%{employee_id: nil}), do: nil

  defp operator(line) do
    %{employee_id: line.employee_id, display_name: line.display_name}
  end

  # The identity a save would give a proposed operator is the request's — its
  # employee ID carries the request UUID, which is transport rather than business
  # input — so the composed line names the ordinal and leaves the row's own employee
  # fields to the save that writes them.
  defp composed_proposal(proposal) do
    %{
      id: nil,
      line_number: nil,
      operator: %{employee_id: nil, display_name: nil},
      days: [slot_input(proposal)]
    }
  end

  defp slot_input(day) do
    %{
      weekday: day.weekday,
      day_type_key: day.day_type_key,
      run_id: day.run_id,
      run_sign_on_secs: day.run_sign_on_secs,
      run_sign_off_secs: day.run_sign_off_secs
    }
  end

  # --- what the roster leaves unstaffed ---------------------------------------

  # One entry per run-day the plan leaves unstaffed, over every weekday its own day
  # type works — not only the selected dates, because a saved slot reaches all of
  # them. A run the composition presents is checked; a day type with no run at all
  # has nothing to leave open.
  defp roster_exclusions(base_week, runs, roster, day_types) do
    stale = stale_run_days(roster)

    for day_type <- day_types,
        day_runs = day_runs(runs, day_type.key),
        day_runs != [],
        weekday <- weekdays_of(day_type),
        run <- day_runs,
        subject = {weekday, day_type.key, run.run_id},
        reason = unstaffed_reason(base_week, weekday, day_type.key, run, stale, subject),
        not is_nil(reason),
        do: %{subject: subject, reason: reason}
  end

  # The first reason that applies, so a run-day is reported once: a weekday whose
  # base is another day type cannot be reached by a recurring line at all, a run the
  # export drops is not written wherever it is, and a stale slot's run-day is held
  # without being exported.
  defp unstaffed_reason(base_week, weekday, key, run, stale, subject) do
    cond do
      not base?(base_week, weekday, key) -> :no_base_weekday
      error_run?(run) -> :run_has_errors
      MapSet.member?(stale, subject) -> :stale_slot
      true -> nil
    end
  end

  defp base?(base_week, weekday, key) do
    case Map.get(base_week, weekday) do
      %{day_type: %{key: ^key}} -> true
      _no_base -> false
    end
  end

  # The run-days a stored line holds without being able to export them, so the work
  # is neither the generation's to add nor the export's to write.
  defp stale_run_days(roster) do
    for line <- roster.lines,
        {weekday, slot} <- line.slots,
        match?({:stale, _reason}, slot.state),
        into: MapSet.new(),
        do: {weekday, slot.day_type_key, slot.run_id}
  end

  defp weekdays_of(day_type) do
    day_type.dates |> Enum.map(&Date.day_of_week/1) |> Enum.uniq() |> Enum.sort()
  end

  # --- what the roster says about itself --------------------------------------

  defp roster_findings(roster, proposals) do
    ordinals =
      Map.new(proposals, &{{&1.weekday, &1.day_type_key, &1.run_id}, &1.operator_ordinal})

    Enum.flat_map(roster.lines, fn line ->
      Enum.map(line.findings, fn finding ->
        %{
          line_number: line.line_number,
          operator_ordinal: proposal_ordinal(line, ordinals),
          code: finding.code,
          weekdays: finding.weekdays,
          detail: finding.detail
        }
      end)
    end)
  end

  # A proposed line holds one slot, and the day it holds names the proposal it came
  # from: an existing line is identified by its own number instead.
  defp proposal_ordinal(%{slots: slots}, ordinals) when map_size(slots) == 1 do
    [{weekday, slot}] = Map.to_list(slots)
    Map.get(ordinals, {weekday, slot.day_type_key, slot.run_id})
  end

  defp proposal_ordinal(_line, _ordinals), do: nil

  defp roster_counts(roster, kept, proposals) do
    %{
      new_lines: length(proposals),
      new_slots: length(proposals),
      new_operators: length(proposals),
      preserved_lines: length(kept),
      preserved_slots: kept |> Enum.flat_map(& &1.days) |> length(),
      preserved_operators:
        kept
        |> Enum.map(&(&1.operator && &1.operator.employee_id))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length(),
      open_run_days: roster.groups |> Enum.map(& &1.open_run_days) |> Enum.sum()
    }
  end

  # --- coverage ---------------------------------------------------------------

  defp coverage(input, day_types, runs, assignments, roster, stored_base, additions) do
    start_date = Date.from_iso8601!(Map.fetch!(input, "start_date"))
    end_date = Date.from_iso8601!(Map.fetch!(input, "end_date"))
    staffed = staffed_run_days(roster)
    affected = affected_dates(day_types, runs, staffed)

    %{
      range: %{
        start_date: start_date,
        end_date: end_date,
        representative_week: Date.from_iso8601!(Map.fetch!(input, "representative_week"))
      },
      base_week: base_week_days(roster.base_week, stored_base, additions),
      affected_dates: affected,
      beyond_range_dates: Enum.reject(affected, &in_range?(&1, start_date, end_date)),
      open_dates: open_dates(day_types, runs, affected, start_date, end_date),
      other_service_dates: assignments.other_service_dates,
      exported_dates: exported_dates(assignments)
    }
  end

  # The run-days an assigned, exportable line would write: the composition's own
  # answer, so a slot whose stored times no longer match its run is not counted as
  # staffed, and neither is one whose run the export drops.
  defp staffed_run_days(roster) do
    for line <- roster.lines,
        not is_nil(line.operator),
        {weekday, slot} <- line.slots,
        slot.state == :ok,
        not is_nil(slot.run),
        not error_run?(slot.run),
        into: MapSet.new(),
        do: {weekday, slot.day_type_key}
  end

  # Every date a saved slot reaches: each date of a day type whose weekday the plan
  # would staff, in the range or not. The date's own weekday is what decides — a
  # slot on Tuesday repeats to every Tuesday of the base day type.
  defp affected_dates(day_types, runs, staffed) do
    for day_type <- day_types,
        day_runs(runs, day_type.key) != [],
        date <- day_type.dates,
        MapSet.member?(staffed, {Date.day_of_week(date), day_type.key}),
        do: date
  end

  # The dates inside the selected range with service that nothing would staff.
  # Only a day type the request derived runs for counts: a day type whose trips were
  # never cut has nothing this plan could have staffed.
  defp open_dates(day_types, runs, affected, start_date, end_date) do
    staffed = MapSet.new(affected)

    for day_type <- day_types,
        day_runs(runs, day_type.key) != [],
        date <- day_type.dates,
        in_range?(date, start_date, end_date),
        not MapSet.member?(staffed, date),
        do: date
  end

  defp in_range?(date, start_date, end_date) do
    Date.compare(date, start_date) != :lt and Date.compare(date, end_date) != :gt
  end

  defp exported_dates(assignments) do
    assignments.rows
    |> Enum.map(&%{date: &1.date, service_id: &1.service_id})
    |> Enum.uniq()
    |> Enum.sort_by(&Date.to_iso8601(&1.date))
  end

  # `chosen?` and `missing_choice` are read from the version's *stored* answers, so
  # a weekday this request would choose for itself reports `added?: true` rather
  # than looking like a choice the operator already had.
  defp base_week_days(base_week, stored_base, additions) do
    Enum.map(1..7, fn weekday ->
      base = Map.fetch!(base_week, weekday)
      stored = Map.fetch!(stored_base, weekday)

      %{
        weekday: weekday,
        day_type_key: base_key(base),
        chosen?: stored.chosen?,
        added?: Map.has_key?(additions, Integer.to_string(weekday)),
        missing_choice: stored.missing_choice
      }
    end)
  end

  # --- the assumptions the roster stage rests on -------------------------------

  # What the roster stage assumes, in the operator's terms: the allocation is one
  # operator per run-day rather than a weekly duty, and a slot saved for a weekday
  # reaches every matching date of the calendar, not only the selected range.
  defp assumptions(crew_assumptions, proposals, coverage) do
    []
    |> add_assumption(proposals != [], :one_operator_per_run_day)
    |> add_assumption(coverage.beyond_range_dates != [], :recurring_beyond_range)
    |> Kernel.++(crew_assumptions)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp add_assumption(assumptions, true, assumption), do: [assumption | assumptions]
  defp add_assumption(assumptions, false, _assumption), do: assumptions

  defp day_runs(runs, key) do
    case Map.get(runs, key) do
      %{runs: day_runs} -> day_runs
      nil -> []
    end
  end

  defp error_run?(run), do: Enum.any?(run.findings, &(&1.severity == :error))
end

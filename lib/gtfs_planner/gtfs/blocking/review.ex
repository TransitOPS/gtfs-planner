defmodule GtfsPlanner.Gtfs.Blocking.Review do
  @moduledoc """
  Pure block-change review (AC-12, R3).

  A block command applies on every date its changed trips run, so the review
  compares the touched blocks before and after the command on every affected day
  type and reports what the command changes: the changed trips, the block it
  splits (with the trips that remain) or joins, and the errors and warnings it
  adds, separate from those already present. `build/1` returns that review with the
  confirmation decision and the fingerprint a confirmation must match.

  The module is pure: it computes from the map it is given and makes no repository
  call, no clock read and no file or network access (CR-1). The caller supplies the
  locked trip rows, the resolved changes, the affected day types and the in-seat
  context it loaded under the block lock; the review never reads the database
  itself.

  Per affected day type the review builds each touched block's trip list before the
  change and after applying it, runs `Blocking.Checks.block_findings/3` on both and
  diffs by `Checks.finding_key/1`: a finding present only after is `added`, one
  present before and after is `existing`. In-seat findings come from the shared
  `Blocking.InSeat` rule (INV-2) over the affected day types only, so a record stale
  only on an unaffected date is unchanged by the command and is never `added`.

  The command is an `:assign` or `:unassign` of one trip that adds no error or
  warning, every other block command needs confirmation, a plan always needs
  confirmation, and an attribute save needs one when it touches a day type other
  than the selected one or adds a problem. The fingerprint is the lowercase SHA-256
  hex of the deterministic encoding of the resolved command, the sorted changes, the
  sorted locked rows (block ID, service ID, the four times and the ISO 8601
  `updated_at`) and the sorted added finding keys, so a confirmation whose inputs
  changed no longer matches (Mutation steps 8 and 9). A caller that reviewed a
  planning input adds `inputs_digest` and it is appended to that encoding, so a
  write whose inputs were recomputed and found unchanged still matches (INV-7).

  The planning context is passed through, not unpacked: `Context.layover_only/1`
  reproduces spec 05's review and fingerprint exactly (CR-2), and a context with
  planning inputs produces the same added keys in the same order.

  One review describes a many-target plan and an attribute save as well as a single
  block command, so a plan or an attribute save is never reviewed by a second
  implementation. Each change carries its own `to`, so a plan that moves trips into
  several blocks is described block by block; the blocks a day type touches are
  every change's `from` and `to` on that day type plus the caller's `:touched` list,
  which is how an attribute save names the block whose attribute rows change while
  no trip moves. `context_after` is the context the write will leave behind, so an
  attribute row that would break a route requirement is reported as added (AC-19).
  """

  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.{Checks, DayTypes, InSeat}

  @type effect :: %{
          day_type: DayTypes.day_type(),
          selected?: boolean(),
          changed_trip_ids: [Ecto.UUID.t()],
          joins: [String.t()],
          splits: [%{block_id: String.t(), remaining: pos_integer()}],
          added: [Checks.finding()],
          existing: [Checks.finding()]
        }

  @type change :: %{
          trip: Checks.trip_row(),
          from: String.t() | nil,
          to: String.t() | nil
        }

  @type review :: %{
          command: Blocking.command(),
          target: String.t() | nil,
          changes: [change()],
          effects: [effect()],
          affected_date_count: non_neg_integer(),
          added_problem_count: non_neg_integer(),
          needs_confirmation?: boolean(),
          fingerprint: String.t()
        }

  @doc """
  Builds the review of one block command over its affected day types.

  The input map carries:

  - `:command` — the resolved command: a block command, `{:plan, mode}` or
    `{:attributes, block_id, garage_id, vehicle_type_id}`;
  - `:target` — the resolved target block ID, or `nil` for an unassign, a plan or
    an attribute save;
  - `:selected_key` — the selected day type's key, whose effect is listed first;
  - `:affected` — the affected day types in list order;
  - `:rows` — the locked trip rows;
  - `:changes` — `%{trip: trip_row, from: block_id | nil, to: block_id | nil}`;
  - `:touched` — optional block IDs to diff although no trip moves into or out of
    them, the block of an attribute save;
  - `:context_after` — optional `%Blocking.Context{}` the write leaves behind; the
    before findings use `:context` (default);
  - `:inputs_digest` — optional `Blocking.Context.digest/1` of the context this
    review read, appended to the fingerprint when present (INV-7);
  - `:in_seat` — `%{rows: [in_seat_row()], context: InSeat.context()}`;
  - `:service_dates` — the canonical `%{service_id => MapSet.t(Date.t())}`;
  - `:context` — the version's `%Blocking.Context{}` planning inputs.
  """
  @spec build(map()) :: review()
  def build(input) do
    command = Map.fetch!(input, :command)
    target = Map.fetch!(input, :target)
    selected_key = Map.fetch!(input, :selected_key)
    affected = Map.fetch!(input, :affected)
    rows = Map.fetch!(input, :rows)
    changes = input |> Map.fetch!(:changes) |> sort_changes()
    context = Map.fetch!(input, :context)

    build_context = %{
      rows: rows,
      changes: changes,
      to_by_row_id: Map.new(changes, &{&1.trip.id, &1.to}),
      target: target,
      touched: List.wrap(Map.get(input, :touched)),
      context: context,
      context_after: Map.get(input, :context_after, context),
      in_seat: Map.fetch!(input, :in_seat),
      service_dates: Map.fetch!(input, :service_dates)
    }

    effects =
      affected
      |> selected_first(selected_key)
      |> Enum.map(&build_effect(&1, selected_key, build_context))

    added_problem_count =
      effects
      |> Enum.flat_map(& &1.added)
      |> Enum.count(&problem?/1)

    %{
      command: command,
      target: target,
      changes: changes,
      effects: effects,
      affected_date_count: Enum.sum(Enum.map(affected, & &1.date_count)),
      added_problem_count: added_problem_count,
      needs_confirmation?: needs_confirmation?(command, changes, added_problem_count, effects),
      fingerprint:
        fingerprint(command, target, changes, rows, effects, Map.get(input, :inputs_digest))
    }
  end

  # The selected day type is the current view, so its effect is the first card.
  defp selected_first(affected, selected_key) do
    {selected, rest} = Enum.split_with(affected, &(&1.key == selected_key))
    selected ++ rest
  end

  # A block command applies without confirmation only when it is an assign or
  # unassign of exactly one trip that adds no error or warning (Mutation step 9).
  # A plan always needs one: it rewrites many trips' blocks at once. An attribute
  # save moves no trip, so it needs one only when it reaches a day type the operator
  # is not looking at or when the saved row adds a problem.
  defp needs_confirmation?({:plan, _mode}, _changes, _added_problem_count, _effects), do: true

  defp needs_confirmation?(
         {:attributes, _block_id, _garage_id, _vehicle_type_id},
         _changes,
         added,
         effects
       ) do
    added > 0 or Enum.any?(effects, &(not &1.selected?))
  end

  defp needs_confirmation?(command, changes, added_problem_count, _effects) do
    direct = match?({:assign, _, _}, command) or match?({:unassign, _}, command)
    not (direct and length(changes) == 1 and added_problem_count == 0)
  end

  defp build_effect(day_type, selected_key, context) do
    active = Enum.filter(context.changes, &runs_on?(&1.trip, day_type))

    before_rows = rows_on(context.rows, day_type)

    # A change applies to the row of its own trip, on the day types its service
    # runs in, and lands that change's own `to` block. A trip of another service is
    # not in this day type's rows, so the change map needs no second day-type filter.
    after_rows = Enum.map(before_rows, &apply_change(&1, context.to_by_row_id))

    from_blocks = active |> Enum.map(& &1.from) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    touched = touched_blocks(day_type, context)

    before_findings = findings_by_block(touched, before_rows, context.context)
    after_findings = findings_by_block(touched, after_rows, context.context_after)
    {added_checks, existing_checks} = diff_checks(touched, before_findings, after_findings)
    {added_in_seat, existing_in_seat} = diff_in_seat(day_type, context)

    %{
      day_type: day_type,
      selected?: day_type.key == selected_key,
      changed_trip_ids: active |> Enum.map(& &1.trip.id) |> Enum.sort(),
      joins: joins(context.target, before_rows),
      splits: splits(from_blocks, after_rows),
      added: dedupe(added_checks ++ added_in_seat),
      existing: dedupe(existing_checks ++ existing_in_seat)
    }
  end

  defp runs_on?(trip, day_type), do: trip.service_id in day_type.service_ids

  defp rows_on(rows, day_type), do: Enum.filter(rows, &runs_on?(&1, day_type))

  defp apply_change(row, to_by_row_id) do
    case Map.fetch(to_by_row_id, row.id) do
      {:ok, to} -> %{row | block_id: to}
      :error -> row
    end
  end

  defp findings_by_block(block_ids, rows, context) do
    Map.new(block_ids, fn block_id ->
      {block_id, Checks.block_findings(block_id, block_trips(rows, block_id), context)}
    end)
  end

  defp block_trips(rows, block_id), do: Enum.filter(rows, &(&1.block_id == block_id))

  defp diff_checks(touched, before_findings, after_findings) do
    pairs =
      Enum.map(touched, fn block_id ->
        before_keys = MapSet.new(before_findings[block_id], &Checks.finding_key/1)
        Enum.split_with(after_findings[block_id], &new_finding?(&1, before_keys))
      end)

    {added, existing} = Enum.unzip(pairs)
    {List.flatten(added), List.flatten(existing)}
  end

  defp new_finding?(finding, before_keys) do
    not MapSet.member?(before_keys, Checks.finding_key(finding))
  end

  # A block that keeps at least one trip after the change is split.
  defp splits(from_blocks, after_rows) do
    from_blocks
    |> Enum.sort()
    |> Enum.flat_map(fn block_id ->
      case Enum.count(after_rows, &(&1.block_id == block_id)) do
        0 -> []
        remaining -> [%{block_id: block_id, remaining: remaining}]
      end
    end)
  end

  # The target joins the command when it already held trips on this day type.
  defp joins(nil, _before_rows), do: []

  defp joins(target, before_rows) do
    if Enum.any?(before_rows, &(&1.block_id == target)), do: [target], else: []
  end

  defp diff_in_seat(day_type, context) do
    in_seat = context.in_seat
    before_context = in_seat_context(in_seat, day_type, context, false)
    after_context = in_seat_context(in_seat, day_type, context, true)

    rows =
      Enum.filter(in_seat.rows, &runs_on_day_type?(&1, day_type, before_context.trips))

    before_keys = in_seat_findings(rows, before_context) |> keys()
    after_findings = in_seat_findings(rows, after_context)

    Enum.split_with(after_findings, &new_finding?(&1, before_keys))
  end

  # The context is narrowed to one affected day type, so a record whose only defect
  # is on an unaffected day type is unchanged by the command and never added. The
  # orders of the touched blocks are the only ones recomputed: no trip moved into or
  # out of an untouched block.
  defp in_seat_context(in_seat, day_type, context, after?) do
    base = %{in_seat.context | day_types: [day_type], service_dates: context.service_dates}

    if after? do
      %{
        base
        | trips: after_trips(base.trips, context.changes),
          sequences: Map.merge(base.sequences, sequences(day_type, context, true))
      }
    else
      %{
        base
        | sequences: Map.merge(base.sequences, sequences(day_type, context, false))
      }
    end
  end

  # The changed trips carry their own target block ID in every day type their
  # service runs in, so the after context reads them as the write will store them.
  defp after_trips(trips, changes) do
    to_by_trip_id = Map.new(changes, &{&1.trip.trip_id, &1.to})

    Map.new(trips, fn {trip_id, trip} ->
      case Map.fetch(to_by_trip_id, trip_id) do
        {:ok, to} -> {trip_id, %{trip | block_id: to}}
        :error -> {trip_id, trip}
      end
    end)
  end

  defp sequences(day_type, context, after?) do
    to_by_row_id = if after?, do: context.to_by_row_id, else: %{}
    day_rows = rows_on(context.rows, day_type)

    day_type
    |> touched_blocks(context)
    |> Map.new(fn block_id ->
      order =
        day_rows
        |> Enum.map(&apply_change(&1, to_by_row_id))
        |> block_trips(block_id)
        |> Checks.sequence()
        |> Enum.map(& &1.id)

      {{day_type.key, block_id}, order}
    end)
  end

  # The blocks a day type must diff: the resolved target, the blocks the caller
  # names although no trip moves, and both ends of every change on that day type.
  defp touched_blocks(day_type, context) do
    moved =
      Enum.flat_map(context.changes, fn %{trip: trip, from: from, to: to} ->
        if runs_on?(trip, day_type), do: [from, to], else: []
      end)

    (List.wrap(context.target) ++ List.wrap(context.touched) ++ moved)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp runs_on_day_type?(row, day_type, trips) do
    service_on? = fn trip_id ->
      case Map.fetch(trips, trip_id) do
        {:ok, trip} -> runs_on?(trip, day_type)
        :error -> true
      end
    end

    service_on?.(row.from_trip_id) and service_on?.(row.to_trip_id)
  end

  defp in_seat_findings(rows, context) do
    rows
    |> Enum.map(&InSeat.finding(&1, InSeat.state(&1, context), context))
    |> Enum.reject(&is_nil/1)
  end

  defp keys(findings), do: MapSet.new(findings, &Checks.finding_key/1)

  defp dedupe(findings) do
    findings
    |> Enum.uniq_by(&Checks.finding_key/1)
    |> Enum.sort_by(&Checks.finding_key/1)
  end

  defp problem?(finding), do: finding.severity in [:error, :warning]

  defp sort_changes(changes), do: Enum.sort_by(changes, &{&1.trip.trip_id, &1.from, &1.to})

  defp fingerprint(command, target, changes, rows, effects, inputs_digest) do
    # The digest is appended, not folded in, so a block command that passes none
    # encodes the same four-element tuple it always did (CR-2).
    canonical =
      [
        resolved_command(command, target),
        Enum.map(changes, &{&1.trip.trip_id, &1.from, &1.to}),
        rows |> Enum.sort_by(&row_order/1) |> Enum.map(&row_tuple/1),
        added_keys(effects)
      ]
      |> Kernel.++(List.wrap(inputs_digest))
      |> List.to_tuple()

    canonical
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp resolved_command({:assign, ids, _target}, target), do: {:assign, Enum.sort(ids), target}

  defp resolved_command({:unassign, ids}, _target), do: {:unassign, Enum.sort(ids)}

  defp resolved_command({:rename, from, _target}, target), do: {:rename, from, target}

  defp resolved_command({:merge, from, _target}, target), do: {:merge, from, target}

  # A plan's mode and an attribute save's block and row are already the resolved
  # command: there is no second target to substitute, and the generic clause
  # encodes them unchanged.
  defp resolved_command(command, _target), do: command

  defp added_keys(effects) do
    effects
    |> Enum.flat_map(& &1.added)
    |> Enum.map(&Checks.finding_key/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp row_order(row) do
    {row.trip_id, row.block_id, row.service_id, row.first_arrival, row.first_departure,
     row.last_arrival, row.last_departure, row.updated_at}
  end

  defp row_tuple(row) do
    {row.trip_id, row.block_id, row.service_id, row.first_arrival, row.first_departure,
     row.last_arrival, row.last_departure, DateTime.to_iso8601(row.updated_at)}
  end
end

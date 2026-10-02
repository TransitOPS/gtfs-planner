defmodule GtfsPlanner.Gtfs.Calendars.Combination do
  @moduledoc """
  Pure combination algebra for a reviewed calendar combination.

  `plan/5` consumes already-loaded snapshots - one per selected calendar, keyed by its
  exact `service_id` - and returns the effective-date union, the deliberate conflict
  dates, the per-calendar consequences and, once every conflict carries an explicit
  decision, the committed result dates. Nothing here reads the database, the clock or
  Ecto: the caller loads the snapshots and persists the reviewed result.

  Effective dates, weekly baselines and exception semantics come from
  `GtfsPlanner.Gtfs.Calendars.ServiceDates`; this module adds only the set algebra
  between several calendars.

  ## Selection and identity

    * `sources` covers every selected calendar, the destination included, and
      `source_ids` names the moving ones. The destination is therefore always a
      selected calendar and never a source: the union includes its own effective dates,
      so combining cannot silently drop the dates its trips already run.
    * Service IDs are compared exactly, never trimmed. Repeated source IDs, an empty
      source list, destination-as-source and a selected ID without a snapshot are
      rejected.

  ## Conflicts and decisions

    * Let `A_i` be one selected calendar's effective dates, `B_i` its weekly evaluator
      without exceptions and `R_i` the type-2 exception dates intersecting `B_i`.
      Conflicts are `union(A_i) ∩ union(R_i)`: a date one selected calendar deliberately
      removes from a regular service day while another selected calendar runs it. An
      ordinary weekday off, an out-of-range removal and a dates-only removal create no
      conflict.
    * Every conflict date needs a decision. Decisions arrive keyed by an ISO-8601 date
      string, or by the `%Date{}` it names for an internal caller; only the allowlisted
      values `"run"` and `"no_service"` - or their existing atoms - are normalized. An
      unknown value, one date reached twice through both key forms and a choice for a
      date that is not a conflict are rejected.
    * Nothing is defaulted. An incomplete review returns `result_dates: nil` and
      `ready?: false` with the undecided dates in `unresolved_dates`, so a speculative
      union is never presented as the committed result. The result is the union minus
      only the exact dates decided `no_service`; past conflicts still need a choice.
    * Conflicts group only civil-adjacent dates whose running and removing ID sets are
      equal. `group_key` is the ISO-8601 first date of that run, and
      `expand_group_choices/2` expands a group value against the current conflicts, so a
      client never supplies the exact dates it is deciding.

  ## Consequences

    * One `effects` entry per selected calendar carries its trip count, whether its trips
      move, and the exact dates its trips gain or lose, split at agency-local `today`.
      Upcoming includes `today` itself.
    * While a conflict is undecided no final gain or loss exists, so the entry carries
      the source facts with `nil` date collections instead of an empty list that would
      read as "nothing changes".

  ## Native destination rows

    * `encode/3` projects the destination's own native rows for exactly the planned
      result dates; a source calendar is never re-encoded, because only the destination
      receives the combined dates. The caller persists the returned rows.
    * A weekly destination keeps its kind, metadata and weekday mask. Its endpoints are
      the first and last result dates that mask serves, so the projected baseline covers
      the dates in use; when no result date falls on the mask, the original valid range
      stays. Additions are `result - baseline` and removals `baseline - result`, so an
      empty result removes every baseline date instead of resurrecting weekdays. A
      dates-only destination stores exactly the result dates as additions and keeps no
      weekly row.
    * Unchanged effective dates return the original rows untouched with `changed?: false`,
      redundant exceptions included, so a no-op writes nothing. Otherwise the projected
      rows come back with `changed?: true`.
    * A projection that would leave the destination with neither a weekly row nor an
      exception row is refused as `:native_service_required` while any trip would still
      reference the destination after the moves: the attributes anchor is metadata, not
      native service identity, so the editor keeps a weekly destination, changes a
      decision or cancels instead of receiving a synthesized service date or a silently
      converted kind.
  """

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates

  @decision_strings %{"run" => :run, "no_service" => :no_service}
  @added 1
  @removed 2

  @type service_id :: String.t()
  @type decision :: :run | :no_service

  @type snapshot :: %{
          optional(:attributes) => map() | nil,
          calendar: Calendar.t() | nil,
          exceptions: [CalendarDate.t()],
          trip_count: non_neg_integer()
        }

  @type conflict :: %{
          date: Date.t(),
          running_ids: [service_id()],
          removing_ids: [service_id()],
          group_key: String.t()
        }

  @type effect :: %{
          service_id: service_id(),
          trip_count: non_neg_integer(),
          moving?: boolean(),
          gained_dates: [Date.t()] | nil,
          lost_dates: [Date.t()] | nil,
          upcoming_gained_dates: [Date.t()] | nil,
          upcoming_lost_dates: [Date.t()] | nil,
          past_gained_dates: [Date.t()] | nil,
          past_lost_dates: [Date.t()] | nil
        }

  @type plan :: %{
          ready?: boolean(),
          union_dates: [Date.t()],
          result_dates: [Date.t()] | nil,
          conflicts: [conflict()],
          unresolved_dates: [Date.t()],
          effects: [effect()]
        }

  @type invalid_command :: :invalid_command
  @type invalid_calendar :: {:invalid_calendar, service_id(), atom()}

  @type encoded_exception :: %{date: Date.t(), exception_type: 1 | 2}

  @type encoded :: %{
          calendar: Calendar.t() | nil,
          exceptions: [encoded_exception()],
          changed?: boolean()
        }

  @type evaluation :: %{
          service_id: service_id(),
          active_set: MapSet.t(Date.t()),
          removals: MapSet.t(Date.t()),
          trip_count: non_neg_integer()
        }

  @doc """
  Plans one combination command from loaded calendar snapshots.

  `sources` maps every selected `service_id`, the destination included, to a snapshot
  with its `calendar`, `exceptions` and `trip_count`. `source_ids` names the moving
  calendars. `decisions` maps an ISO-8601 conflict date string, or the `%Date{}` it
  names, to `"run"`/`"no_service"` or `:run`/`:no_service`. `today` is the agency-local
  review date.

  Returns `{:ok, plan}`; `plan.ready?` is true only when every conflict date has a
  decision, and only then is `plan.result_dates` a list. A malformed command returns
  `{:error, :invalid_command}` and an unevaluable selected calendar returns
  `{:error, {:invalid_calendar, service_id, reason}}` with `:missing`,
  `:malformed_snapshot`, `:malformed_calendar`, `:reversed_range` or
  `:conflicting_exceptions`.
  """
  @spec plan(%{service_id() => snapshot()}, service_id(), [service_id()], map(), Date.t()) ::
          {:ok, plan()} | {:error, invalid_command() | invalid_calendar()}
  def plan(sources, destination_id, source_ids, decisions, today)
      when is_map(sources) and is_binary(destination_id) and is_list(source_ids) and
             is_map(decisions) and is_struct(today, Date) do
    with :ok <- validate_selection(sources, destination_id, source_ids),
         {:ok, normalized} <- normalize_decisions(decisions),
         {:ok, evaluated} <- evaluate_selected(sources, [destination_id | source_ids]) do
      build_plan(destination_id, evaluated, normalized, today)
    end
  end

  def plan(_sources, _destination_id, _source_ids, _decisions, _today),
    do: {:error, :invalid_command}

  @doc """
  Expands group-level choices into exact ISO-8601 date decisions.

  `conflicts` is the `:conflicts` list of a current `plan/5` result and `choices` maps a
  current `group_key` to an allowlisted decision value. Every group value expands to the
  exact dates of that group as it exists in `conflicts`, so a client cannot decide dates
  the current review does not contain: an unknown group key, or a key that names a group
  in a different review, returns `{:error, :invalid_command}`.
  """
  @spec expand_group_choices([conflict()], map()) ::
          {:ok, %{String.t() => decision()}} | {:error, invalid_command()}
  def expand_group_choices(conflicts, choices) when is_list(conflicts) and is_map(choices) do
    groups = Enum.group_by(conflicts, & &1.group_key)

    Enum.reduce_while(choices, {:ok, %{}}, fn {key, value}, {:ok, decisions} ->
      with {:ok, key} <- group_key(key),
           {:ok, dates} <- fetch_group(groups, key),
           {:ok, decision} <- normalize_decision(value) do
        expanded = Enum.reduce(dates, decisions, &Map.put(&2, Date.to_iso8601(&1), decision))
        {:cont, {:ok, expanded}}
      else
        {:error, _reason} -> {:halt, {:error, :invalid_command}}
      end
    end)
  end

  def expand_group_choices(_conflicts, _choices), do: {:error, :invalid_command}

  @doc """
  Projects the destination's native rows for exactly `result_dates`.

  `destination` is the destination's snapshot - the same map `plan/5` consumes - and
  `result_dates` is that plan's committed result, so a source calendar never reaches this
  function. `post_move_trip_count` counts every trip that would reference the destination
  once the reviewed moves are applied: its existing trips plus the moving sources' trips.

  A weekly destination keeps its weekday mask and kind, and its endpoints come from the
  first and last result dates that mask serves - or stay as they are when none of them
  does. The projected baseline is evaluated by `ServiceDates`, and the projection stores
  `result - baseline` as additions and `baseline - result` as removals, so an empty result
  removes every baseline date instead of resurrecting weekdays. A dates-only destination
  stores exactly the result dates as additions and keeps no weekly row.

  When the destination's effective dates do not change, its original rows come back
  unchanged with `changed?: false` - redundant exceptions included - so a no-op writes
  nothing. Otherwise the projected rows are returned with `changed?: true`.

  A projected destination with neither a weekly row nor an exception row is refused as
  `{:error, :native_service_required}` while any trip would still reference it, because
  the attributes anchor is metadata rather than native service identity; the editor keeps
  a weekly destination, changes a decision or cancels instead. With no post-move trips
  that metadata-only result is allowed.

  `result_dates` is `nil` only while the plan is incomplete, which is
  `{:error, :incomplete_plan}`. A malformed destination, result or trip count is
  `{:error, :invalid_command}` rather than a raise.
  """
  @spec encode(snapshot(), [Date.t()] | nil, non_neg_integer()) ::
          {:ok, encoded()}
          | {:error, invalid_command() | :incomplete_plan | :native_service_required}
  def encode(_destination, nil, _post_move_trip_count), do: {:error, :incomplete_plan}

  def encode(destination, result_dates, post_move_trip_count)
      when is_map(destination) and is_list(result_dates) and is_integer(post_move_trip_count) and
             post_move_trip_count >= 0 do
    with {:ok, calendar} <- destination_calendar(destination),
         {:ok, exceptions} <- destination_exceptions(destination),
         {:ok, result} <- encoding_result(result_dates) do
      project(calendar, exceptions, result, post_move_trip_count)
    end
  end

  def encode(_destination, _result_dates, _post_move_trip_count), do: {:error, :invalid_command}

  # -- command validation -----------------------------------------------------

  defp validate_selection(sources, destination_id, source_ids) do
    cond do
      not service_id?(destination_id) -> {:error, :invalid_command}
      source_ids == [] -> {:error, :invalid_command}
      Enum.any?(source_ids, &(not service_id?(&1))) -> {:error, :invalid_command}
      Enum.uniq(source_ids) != source_ids -> {:error, :invalid_command}
      destination_id in source_ids -> {:error, :invalid_command}
      true -> missing_snapshot(sources, [destination_id | source_ids])
    end
  end

  # Identifier exception: whitespace is legal service_id data, so only "" is invalid.
  defp service_id?(service_id), do: is_binary(service_id) and service_id != ""

  defp missing_snapshot(sources, selected_ids) do
    case Enum.find(selected_ids, &(not Map.has_key?(sources, &1))) do
      nil -> :ok
      missing -> {:error, {:invalid_calendar, missing, :missing}}
    end
  end

  defp normalize_decisions(decisions) do
    Enum.reduce_while(decisions, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case normalized_decision(key, value) do
        {:ok, date, decision} -> {:cont, put_decision(normalized, date, decision)}
        {:error, _reason} -> {:halt, {:error, :invalid_command}}
      end
    end)
  end

  defp normalized_decision(key, value) do
    with {:ok, date} <- decision_date(key),
         {:ok, decision} <- normalize_decision(value) do
      {:ok, date, decision}
    end
  end

  defp put_decision(normalized, date, decision) do
    iso_date = Date.to_iso8601(date)

    if Map.has_key?(normalized, iso_date) do
      {:error, :invalid_command}
    else
      {:ok, Map.put(normalized, iso_date, decision)}
    end
  end

  defp decision_date(%Date{} = date), do: {:ok, date}

  defp decision_date(key) when is_binary(key) do
    case Date.from_iso8601(key) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_command}
    end
  end

  defp decision_date(_key), do: {:error, :invalid_command}

  defp normalize_decision(:run), do: {:ok, :run}
  defp normalize_decision(:no_service), do: {:ok, :no_service}

  defp normalize_decision(value) when is_binary(value) do
    case Map.fetch(@decision_strings, value) do
      {:ok, decision} -> {:ok, decision}
      :error -> {:error, :invalid_command}
    end
  end

  defp normalize_decision(_value), do: {:error, :invalid_command}

  defp group_key(%Date{} = date), do: {:ok, Date.to_iso8601(date)}
  defp group_key(key) when is_binary(key), do: {:ok, key}
  defp group_key(_key), do: {:error, :invalid_command}

  defp fetch_group(groups, key) do
    case Map.fetch(groups, key) do
      {:ok, group} -> {:ok, Enum.map(group, & &1.date)}
      :error -> {:error, :invalid_command}
    end
  end

  # -- calendar evaluation ----------------------------------------------------

  defp evaluate_selected(sources, selected_ids) do
    Enum.reduce_while(selected_ids, {:ok, %{}}, fn service_id, {:ok, evaluated} ->
      case evaluate_service(service_id, Map.fetch!(sources, service_id)) do
        {:ok, entry} -> {:cont, {:ok, Map.put(evaluated, service_id, entry)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp evaluate_service(service_id, snapshot) do
    with :ok <- validate_snapshot(service_id, snapshot),
         {:ok, calendar} <- snapshot_calendar(service_id, snapshot),
         {:ok, exceptions} <- snapshot_exceptions(service_id, snapshot) do
      baseline = ServiceDates.active_dates(calendar, [])

      {:ok,
       %{
         service_id: service_id,
         active_set: calendar |> ServiceDates.active_dates(exceptions) |> MapSet.new(),
         removals: deliberate_removals(exceptions, baseline),
         trip_count: Map.fetch!(snapshot, :trip_count)
       }}
    end
  end

  defp validate_snapshot(service_id, snapshot) do
    cond do
      not snapshot_key?(snapshot, :calendar) -> malformed_snapshot(service_id)
      not snapshot_key?(snapshot, :exceptions) -> malformed_snapshot(service_id)
      not snapshot_key?(snapshot, :trip_count) -> malformed_snapshot(service_id)
      not is_list(Map.fetch!(snapshot, :exceptions)) -> malformed_snapshot(service_id)
      not trip_count?(Map.fetch!(snapshot, :trip_count)) -> malformed_snapshot(service_id)
      true -> :ok
    end
  end

  defp snapshot_key?(snapshot, key), do: is_map(snapshot) and Map.has_key?(snapshot, key)

  defp trip_count?(trip_count), do: is_integer(trip_count) and trip_count >= 0

  defp malformed_snapshot(service_id),
    do: {:error, {:invalid_calendar, service_id, :malformed_snapshot}}

  defp snapshot_calendar(service_id, snapshot) do
    case Map.fetch!(snapshot, :calendar) do
      nil ->
        {:ok, nil}

      %Calendar{start_date: %Date{}, end_date: %Date{}} = calendar ->
        if ordered_range?(calendar) do
          {:ok, calendar}
        else
          {:error, {:invalid_calendar, service_id, :reversed_range}}
        end

      _other ->
        {:error, {:invalid_calendar, service_id, :malformed_calendar}}
    end
  end

  # A weekly row is usable only when both endpoints exist and are ordered; every
  # projection and evaluation in this module shares that question.
  defp ordered_range?(%Calendar{start_date: %Date{} = start_date, end_date: %Date{} = end_date}),
    do: Date.compare(end_date, start_date) != :lt

  defp ordered_range?(%Calendar{}), do: false

  defp snapshot_exceptions(service_id, snapshot) do
    exceptions = Map.fetch!(snapshot, :exceptions)

    if valid_exceptions?(exceptions) do
      {:ok, exceptions}
    else
      exception_error(service_id, exceptions)
    end
  end

  defp valid_exceptions?(exceptions) do
    is_list(exceptions) and Enum.all?(exceptions, &exception_date?/1) and
      MapSet.disjoint?(exception_dates(exceptions, @added), exception_dates(exceptions, @removed))
  end

  defp exception_date?(%{date: %Date{}, exception_type: type}) when type in [@added, @removed],
    do: true

  defp exception_date?(_exception), do: false

  defp exception_dates(exceptions, type) do
    MapSet.new(for %{date: %Date{} = date, exception_type: ^type} <- exceptions, do: date)
  end

  defp exception_error(service_id, exceptions) do
    reason =
      if Enum.all?(exceptions, &exception_date?/1),
        do: :conflicting_exceptions,
        else: :malformed_calendar

    {:error, {:invalid_calendar, service_id, reason}}
  end

  # `R_i`: a type-2 exception that removes a day the weekly evaluator would serve.
  defp deliberate_removals(exceptions, baseline) do
    baseline_set = MapSet.new(baseline)

    exceptions
    |> exception_dates(@removed)
    |> Enum.filter(&MapSet.member?(baseline_set, &1))
    |> MapSet.new()
  end

  # -- plan -------------------------------------------------------------------

  defp build_plan(destination_id, evaluated, decisions, today) do
    union = union_of(evaluated, & &1.active_set)
    removals = union_of(evaluated, & &1.removals)

    conflicts =
      union
      |> MapSet.intersection(removals)
      |> sort_dates()
      |> group_conflicts(evaluated)

    if decisions_cover_conflicts?(decisions, conflicts) do
      unresolved = Enum.reject(conflicts, &decided?(&1, decisions))
      result_dates = if unresolved == [], do: committed_result(union, decisions)

      {:ok,
       %{
         ready?: result_dates != nil,
         union_dates: sort_dates(union),
         result_dates: result_dates,
         conflicts: conflicts,
         unresolved_dates: Enum.map(unresolved, & &1.date),
         effects: effects(destination_id, evaluated, result_dates, today)
       }}
    else
      {:error, :invalid_command}
    end
  end

  defp union_of(evaluated, extract) do
    evaluated
    |> Map.values()
    |> Enum.map(extract)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  # A decision belongs to one exact conflict date. Group values are expanded into those
  # dates by `expand_group_choices/2` before a plan is built, so anything else - an extra
  # date or an unexpanded group key - is an invalid command.
  defp decisions_cover_conflicts?(decisions, conflicts) do
    conflict_dates = MapSet.new(conflicts, &Date.to_iso8601(&1.date))
    Enum.all?(Map.keys(decisions), &MapSet.member?(conflict_dates, &1))
  end

  defp decided?(conflict, decisions) do
    Map.has_key?(decisions, Date.to_iso8601(conflict.date))
  end

  defp committed_result(union, decisions) do
    no_service =
      decisions
      |> Enum.filter(fn {_iso_date, decision} -> decision == :no_service end)
      |> Enum.map(fn {iso_date, _decision} -> Date.from_iso8601!(iso_date) end)
      |> MapSet.new()

    union |> MapSet.difference(no_service) |> sort_dates()
  end

  # Only civil-adjacent dates that remove and run on exactly the same calendars share a
  # group. The erroneous prototype grouped any dates within four days of each other.
  defp group_conflicts(dates, evaluated) do
    dates
    |> Enum.map(&conflict_facts(&1, evaluated))
    |> Enum.chunk_while(nil, &accumulate_group/2, &emit_group/1)
    |> List.flatten()
  end

  defp conflict_facts(date, evaluated) do
    %{
      date: date,
      running_ids: participating_ids(evaluated, date, & &1.active_set),
      removing_ids: participating_ids(evaluated, date, & &1.removals)
    }
  end

  defp participating_ids(evaluated, date, extract) do
    for {service_id, entry} <- evaluated, MapSet.member?(extract.(entry), date), do: service_id
  end

  defp accumulate_group(fact, nil), do: {:cont, [fact]}

  defp accumulate_group(fact, group) do
    previous = List.last(group)

    if adjacent?(previous.date, fact.date) and same_participants?(previous, fact) do
      {:cont, group ++ [fact]}
    else
      {:cont, grouped(group), [fact]}
    end
  end

  # `Enum.chunk_while/4` emits a chunk from the final accumulator only through the
  # three-element form, so both endings emit explicitly and continue with `nil`.
  defp emit_group(nil), do: {:cont, [], nil}
  defp emit_group(group), do: {:cont, grouped(group), nil}

  defp grouped(group) do
    group_key = group |> hd() |> Map.fetch!(:date) |> Date.to_iso8601()
    Enum.map(group, &Map.put(&1, :group_key, group_key))
  end

  defp adjacent?(previous_date, date), do: Date.diff(date, previous_date) == 1

  defp same_participants?(previous, fact) do
    Enum.sort(previous.running_ids) == Enum.sort(fact.running_ids) and
      Enum.sort(previous.removing_ids) == Enum.sort(fact.removing_ids)
  end

  defp sort_dates(dates), do: Enum.sort_by(dates, & &1, Date)

  # -- effects ----------------------------------------------------------------

  defp effects(destination_id, evaluated, result_dates, today) do
    result = if result_dates, do: MapSet.new(result_dates)

    evaluated
    |> Map.values()
    |> Enum.sort_by(& &1.service_id)
    |> Enum.map(&effect(&1, destination_id, result, today))
  end

  defp effect(entry, destination_id, result, today) do
    facts = %{
      service_id: entry.service_id,
      trip_count: entry.trip_count,
      moving?: entry.service_id != destination_id
    }

    if result do
      gained = result |> MapSet.difference(entry.active_set) |> sort_dates()
      lost = entry.active_set |> MapSet.difference(result) |> sort_dates()
      {upcoming_gained, past_gained} = split_at(gained, today)
      {upcoming_lost, past_lost} = split_at(lost, today)

      Map.merge(facts, %{
        gained_dates: gained,
        lost_dates: lost,
        upcoming_gained_dates: upcoming_gained,
        upcoming_lost_dates: upcoming_lost,
        past_gained_dates: past_gained,
        past_lost_dates: past_lost
      })
    else
      Map.merge(facts, %{
        gained_dates: nil,
        lost_dates: nil,
        upcoming_gained_dates: nil,
        upcoming_lost_dates: nil,
        past_gained_dates: nil,
        past_lost_dates: nil
      })
    end
  end

  # Upcoming includes the agency-local review date itself.
  defp split_at(dates, today), do: Enum.split_with(dates, &(Date.compare(&1, today) != :lt))

  # -- native encoding --------------------------------------------------------

  defp destination_calendar(%{calendar: nil}), do: {:ok, nil}

  defp destination_calendar(%{calendar: %Calendar{} = calendar}) do
    if ordered_range?(calendar), do: {:ok, calendar}, else: {:error, :invalid_command}
  end

  defp destination_calendar(_destination), do: {:error, :invalid_command}

  defp destination_exceptions(%{exceptions: exceptions}) do
    if valid_exceptions?(exceptions), do: {:ok, exceptions}, else: {:error, :invalid_command}
  end

  defp destination_exceptions(_destination), do: {:error, :invalid_command}

  # The planned result is a set: duplicates and arrival order carry no meaning.
  defp encoding_result(result_dates) do
    if Enum.all?(result_dates, &is_struct(&1, Date)) do
      {:ok, result_dates |> MapSet.new() |> sort_dates()}
    else
      {:error, :invalid_command}
    end
  end

  defp project(calendar, exceptions, result, post_move_trip_count) do
    projected = project_rows(calendar, result)
    assert_projection!(projected, result)

    cond do
      native_service_required?(projected, post_move_trip_count) ->
        {:error, :native_service_required}

      # Effective dates are unchanged, so the destination keeps its original rows - and
      # its redundant exceptions - and nothing is written.
      ServiceDates.active_dates(calendar, exceptions) == result ->
        {:ok, %{calendar: calendar, exceptions: exception_rows(exceptions), changed?: false}}

      true ->
        {:ok, Map.put(projected, :changed?, true)}
    end
  end

  # A dates-only destination stores exactly the result as additions and no weekly row.
  defp project_rows(nil, result) do
    %{calendar: nil, exceptions: exception_rows(Enum.map(result, &exception_row(&1, @added)))}
  end

  # A weekly destination keeps its mask and kind: the new endpoints come from the planned
  # dates the mask serves, so the projected baseline covers the dates in use, and the
  # additions and removals around that baseline reproduce the result exactly.
  defp project_rows(%Calendar{} = calendar, result) do
    {start_date, end_date} = weekly_endpoints(calendar, result)
    weekly = %Calendar{calendar | start_date: start_date, end_date: end_date}
    baseline = weekly |> ServiceDates.active_dates([]) |> MapSet.new()
    planned = MapSet.new(result)

    %{
      calendar: weekly,
      exceptions:
        exception_rows(
          Enum.map(MapSet.difference(planned, baseline), &exception_row(&1, @added)) ++
            Enum.map(MapSet.difference(baseline, planned), &exception_row(&1, @removed))
        )
    }
  end

  defp weekly_endpoints(%Calendar{} = calendar, []),
    do: {calendar.start_date, calendar.end_date}

  defp weekly_endpoints(%Calendar{} = calendar, result) do
    # The mask question goes to `ServiceDates` itself - a candidate weekly row spanning
    # the result - so endpoint selection cannot disagree with the evaluator that later
    # reconstructs the row. Cost is one pass over the result's own span, the same order
    # as the evaluation `plan/5` already performs per selected calendar.
    served =
      calendar
      |> spanning_weekly(result)
      |> ServiceDates.active_dates([])
      |> MapSet.new()

    case Enum.filter(result, &MapSet.member?(served, &1)) do
      [] -> {calendar.start_date, calendar.end_date}
      mask_dates -> {hd(mask_dates), List.last(mask_dates)}
    end
  end

  defp spanning_weekly(%Calendar{} = calendar, result) do
    %Calendar{calendar | start_date: hd(result), end_date: List.last(result)}
  end

  # Critique M2, made unconditional: a trip service ID that resolves to neither a
  # `calendar.txt` row nor a `calendar_dates.txt` row is a dangling native reference, and
  # the attributes anchor is an extension table rather than native service identity. The
  # refusal is checked on the projection, so it also covers cancelling a dates-only
  # calendar's only addition even though its effective dates were already empty.
  defp native_service_required?(%{calendar: nil, exceptions: []}, post_move_trip_count),
    do: post_move_trip_count > 0

  defp native_service_required?(_projected, _post_move_trip_count), do: false

  # The projected rows must evaluate to exactly the planned result; both sides go through
  # `ServiceDates`, so a disagreement is a programming error, not a rejected command.
  defp assert_projection!(projected, result) do
    reconstructed = ServiceDates.active_dates(projected.calendar, projected.exceptions)

    if reconstructed != result do
      raise ArgumentError,
            "combination encoding evaluated to #{inspect(reconstructed)} instead of " <>
              "#{inspect(result)}"
    end
  end

  # Native exception attrs sorted by date, the shape `Gtfs.Calendars` persists.
  defp exception_row(date, exception_type), do: %{date: date, exception_type: exception_type}

  defp exception_rows(exceptions) do
    exceptions
    |> Enum.map(&%{date: &1.date, exception_type: &1.exception_type})
    |> Enum.sort_by(& &1.date, Date)
  end
end

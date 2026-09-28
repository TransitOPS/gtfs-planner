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
  """

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates

  @decision_strings %{"run" => :run, "no_service" => :no_service}
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

      %Calendar{start_date: %Date{} = start_date, end_date: %Date{} = end_date} = calendar ->
        if Date.compare(end_date, start_date) == :lt do
          {:error, {:invalid_calendar, service_id, :reversed_range}}
        else
          {:ok, calendar}
        end

      _other ->
        {:error, {:invalid_calendar, service_id, :malformed_calendar}}
    end
  end

  defp snapshot_exceptions(service_id, snapshot) do
    exceptions = Map.fetch!(snapshot, :exceptions)

    if Enum.all?(exceptions, &exception_date?/1) and
         MapSet.disjoint?(exception_dates(exceptions, 1), exception_dates(exceptions, @removed)) do
      {:ok, exceptions}
    else
      exception_error(service_id, exceptions)
    end
  end

  defp exception_date?(%{date: %Date{}, exception_type: type}) when type in [1, @removed],
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
end

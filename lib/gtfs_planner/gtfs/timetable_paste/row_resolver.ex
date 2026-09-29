defmodule GtfsPlanner.Gtfs.TimetablePaste.RowResolver do
  @moduledoc """
  Assigns each pasted timetable row a pattern (rule R6).

  `resolve/5` implements the step 5 partial contract: per data row it
  classifies the stop cells with `TimeToken`, applies the row decisions
  (`%{skip, pattern_id, cells, shift, keep_early}`), resolves times with
  `TimeToken.resolve_row/2`, answers the R3 twelve-hour question, and then
  assigns a pattern per R6. Offsets, estimates, `timing_rows` and `key` are
  step 6 work: `start_secs`, `timing_rows` and `key` stay `nil` here so the
  `resolved_row()` shape is already complete for step 6 to fill.

  ## Inputs

    * `grid` — data rows only. The caller strips the header row when the paste
      has headers (a `header? false` grid is already header-less). Cells align
      with `columns` by index; short rows are padded with `""` and non-string
      cells read as blank. Row numbers (`row` and decision keys) are 1-based
      over these rows.
    * `columns` — `[ColumnMatcher.column()]`; only `col` and `target` are read.
      `{:occurrence, id, _side}` targets must name occurrences of the chosen
      pattern (INV-1: the column mapping is the only path from pasted columns
      to stop occurrences; positions are never copied across patterns).
    * `scope` — `%{pattern_id: chosen_id, patterns: [%{id:,
      occurrences: [%{id:, stop_id:, position:}]}]}`; extra keys are ignored.
    * `decisions` — `%{row => %{skip:, pattern_id:, cells:, shift:,
      keep_early:}}`. Atom and string keys are both accepted because the
      LiveView round-trips decisions through a JSON hidden field; row keys may
      be integers or numeric strings, and `cells` keys may be column indexes
      or numeric strings. An unknown `pattern_id` is ignored (the row falls
      back to automatic assignment and surfaces as a decision again).
    * `template_timing_id` — reserved for the step 6 template-scaled
      estimates; ignored here.

  ## Pattern assignment (R6)

  A row stays on the chosen pattern (`how: :default`) when it has times at
  every mapped stop column and the mapped occurrences include the chosen
  pattern's first and last occurrence. Otherwise every pattern of the
  direction is tried as a candidate. A candidate must satisfy all of these:

    * an in-order occurrence correspondence exists from the served columns'
      occurrences to the candidate's occurrences — matched by stop identity
      along each pattern's own order, never by position alone;
    * the first and last served stops are the candidate's endpoints;
    * no explicitly not-served stop appears on the candidate.

  One candidate assigns automatically (`how: :auto`, even when that candidate
  is the chosen pattern); zero candidates is `:no_pattern`; several
  candidates is `{:pattern, ids}` in scope order. A decision naming a pattern
  of the direction is honoured as `how: :chosen` and takes precedence over
  the automatic rules; fit is re-validated against rebuilt candidates by
  `Plan` (step 9), which discards stale choices.

  An omitted (blank) cell never excludes a pattern — the stop becomes an
  estimate in step 6. Only an explicit not-served marker (`-`, `–`, `—`, `…`,
  `|`, `x`, `n/a`, case-insensitive) constrains candidates; this keeps the
  distinction between "no column for this stop" (interpolation) and "this
  trip does not serve this stop" (pattern constraint).

  ## Statuses

    * `:ready` — a pattern is assigned and times resolve (`issue: nil`).
    * `:skipped` — the row is empty (`issue: :empty`) or a skip decision
      applies (`issue: nil`).
    * `:decision` — the row needs the editor: `{:pattern, ids}`,
      `:no_pattern`, `{:twelve_hour, secs}`, or a `{:cell, _, _}` /
      `{:backwards, _, _}` error. Decision rows carry no offsets
      (`start_secs`/`timing_rows` are `nil`) and no pattern (`pattern_id` and
      `how` are `nil`).

  Time errors are reported before pattern assignment: an unrecognized cell
  first (lowest column), then a backwards time, then the twelve-hour
  question, so one row carries exactly one issue.
  """

  alias GtfsPlanner.Gtfs.TimetablePaste.ColumnMatcher
  alias GtfsPlanner.Gtfs.TimetablePaste.TimeToken

  @type row_issue ::
          {:cell, non_neg_integer(), String.t()}
          | {:backwards, non_neg_integer(), String.t()}
          | {:pattern, [Ecto.UUID.t()]}
          | :no_pattern
          | {:twelve_hour, non_neg_integer()}
          | :empty

  @type timing_row :: %{
          arrival_offset: integer(),
          departure_offset: integer(),
          timepoint: 0 | 1,
          pickup_type: term(),
          drop_off_type: term(),
          stop_headsign: term()
        }

  @type resolved_row :: %{
          row: pos_integer(),
          status: :ready | :skipped | :decision,
          issue: row_issue() | nil,
          pattern_id: Ecto.UUID.t() | nil,
          how: :default | :auto | :chosen | nil,
          start_secs: non_neg_integer() | nil,
          timing_rows: [timing_row()] | nil,
          key: binary() | nil,
          pasted: [integer()],
          trip_short_name: String.t() | nil,
          block_id: String.t() | nil,
          trip_headsign: String.t() | nil,
          rolled?: boolean(),
          shift: 0 | 43_200 | 86_400
        }

  @type scope :: %{optional(atom()) => term()}
  @type decision :: %{optional(atom() | String.t()) => term()}

  @doc """
  Resolves each data row to a pattern per R6 without computing offsets.

  Returns one `resolved_row()` per data row, in order. `start_secs`,
  `timing_rows` and `key` are always `nil`; step 6 fills them for ready rows.
  Pure: no Repo, clock or process state.
  """
  @spec resolve([[String.t()]], [ColumnMatcher.column()], scope(), map(), Ecto.UUID.t() | nil) ::
          [resolved_row()]
  def resolve(grid, columns, scope, decisions, _template_timing_id) do
    rows = normalize_grid(grid)
    stop_cols = stop_columns(columns)

    field_cols = %{
      trip_short_name: field_column(columns, :trip_short_name),
      block_id: field_column(columns, :block_id),
      trip_headsign: field_column(columns, :trip_headsign)
    }

    patterns = normalize_patterns(Map.get(scope, :patterns, []))
    by_pattern = Map.new(patterns, &{&1.id, &1})
    chosen = Map.get(by_pattern, Map.get(scope, :pattern_id))
    norm_decisions = normalize_decisions(decisions)

    empty_decision = normalize_decision(%{})

    prelim =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {cells, row_num} ->
        resolve_times(row_num, cells, stop_cols, Map.get(norm_decisions, row_num, empty_decision))
      end)

    median = median_first(prelim)

    Enum.map(prelim, &finish_row(&1, field_cols, chosen, patterns, by_pattern, median))
  end

  # --- Grid and scope normalization ---

  @spec normalize_grid(term()) :: [[String.t()]]
  defp normalize_grid(grid) when is_list(grid) do
    Enum.map(grid, fn
      row when is_list(row) ->
        Enum.map(row, fn
          cell when is_binary(cell) -> cell
          _cell -> ""
        end)

      _row ->
        []
    end)
  end

  defp normalize_grid(_grid), do: []

  @spec stop_columns([ColumnMatcher.column()]) :: [
          %{col: non_neg_integer(), occurrence_id: term()}
        ]
  defp stop_columns(columns) when is_list(columns) do
    columns
    |> Enum.flat_map(fn
      %{col: col, target: {:occurrence, id, _side}} when is_integer(col) ->
        [%{col: col, occurrence_id: id}]

      _column ->
        []
    end)
    |> Enum.sort_by(& &1.col)
  end

  defp stop_columns(_columns), do: []

  @spec field_column([ColumnMatcher.column()], atom()) :: non_neg_integer() | nil
  defp field_column(columns, field) when is_list(columns) do
    columns
    |> Enum.flat_map(fn
      %{col: col, target: target} when is_integer(col) and target == field -> [col]
      _column -> []
    end)
    |> Enum.min(fn -> nil end)
  end

  defp field_column(_columns, _field), do: nil

  @spec normalize_patterns(term()) :: [%{id: term(), occurrences: [map()]}]
  defp normalize_patterns(patterns) when is_list(patterns) do
    patterns
    |> Enum.map(fn
      pattern when is_map(pattern) ->
        occurrences =
          pattern
          |> Map.get(:occurrences, [])
          |> Enum.filter(&valid_occurrence?/1)
          |> Enum.sort_by(& &1.position)

        %{id: Map.get(pattern, :id), occurrences: occurrences}

      _pattern ->
        %{id: nil, occurrences: []}
    end)
    |> Enum.reject(&is_nil(&1.id))
  end

  defp normalize_patterns(_patterns), do: []

  @spec valid_occurrence?(term()) :: boolean()
  defp valid_occurrence?(%{id: id, stop_id: stop_id, position: position})
       when not is_nil(id) and is_binary(stop_id) and is_integer(position),
       do: true

  defp valid_occurrence?(_entry), do: false

  # --- Decisions (atom or string keys; the LiveView JSON round-trip) ---

  @spec normalize_decisions(term()) :: %{pos_integer() => decision()}
  defp normalize_decisions(decisions) when is_map(decisions) do
    decisions
    |> Enum.map(fn {row, decision} -> {to_row_num(row), normalize_decision(decision)} end)
    |> Enum.reject(fn {row, _decision} -> is_nil(row) end)
    |> Map.new()
  end

  defp normalize_decisions(_decisions), do: %{}

  @spec to_row_num(term()) :: pos_integer() | nil
  defp to_row_num(row) when is_integer(row) and row >= 1, do: row

  defp to_row_num(row) when is_binary(row) do
    case Integer.parse(String.trim(row)) do
      {num, ""} when num >= 1 -> num
      _ -> nil
    end
  end

  defp to_row_num(_row), do: nil

  @spec normalize_decision(term()) :: map()
  defp normalize_decision(decision) when is_map(decision) do
    %{
      skip: truthy?(fetch(decision, :skip, "skip", false)),
      pattern_id: fetch_id(fetch(decision, :pattern_id, "pattern_id", nil)),
      cells: normalize_cells(fetch(decision, :cells, "cells", %{})),
      shift: normalize_shift(fetch(decision, :shift, "shift", 0)),
      keep_early: truthy?(fetch(decision, :keep_early, "keep_early", false))
    }
  end

  defp normalize_decision(_decision),
    do: %{skip: false, pattern_id: nil, cells: %{}, shift: 0, keep_early: false}

  @spec fetch(map(), atom(), String.t(), term()) :: term()
  defp fetch(decision, atom_key, string_key, default) do
    case Map.fetch(decision, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(decision, string_key, default)
    end
  end

  @spec fetch_id(term()) :: term()
  defp fetch_id(id) when is_binary(id), do: id
  defp fetch_id(_id), do: nil

  @spec truthy?(term()) :: boolean()
  defp truthy?(value) when value in [false, nil, 0, "", "false", "0"], do: false
  defp truthy?(_value), do: true

  @spec normalize_cells(term()) :: %{non_neg_integer() => String.t()}
  defp normalize_cells(cells) when is_map(cells) do
    cells
    |> Enum.map(fn {col, raw} -> {to_col(col), to_cell(raw)} end)
    |> Enum.reject(fn {col, _raw} -> is_nil(col) end)
    |> Map.new()
  end

  defp normalize_cells(_cells), do: %{}

  @spec to_col(term()) :: non_neg_integer() | nil
  defp to_col(col) when is_integer(col) and col >= 0, do: col

  defp to_col(col) when is_binary(col) do
    case Integer.parse(String.trim(col)) do
      {num, ""} when num >= 0 -> num
      _ -> nil
    end
  end

  defp to_col(_col), do: nil

  @spec to_cell(term()) :: String.t()
  defp to_cell(raw) when is_binary(raw), do: raw
  defp to_cell(raw) when is_integer(raw), do: Integer.to_string(raw)
  defp to_cell(_raw), do: ""

  @spec normalize_shift(term()) :: 0 | 43_200 | 86_400
  defp normalize_shift(shift) when shift in [0, 43_200, 86_400], do: shift

  defp normalize_shift(shift) when is_binary(shift) do
    case Integer.parse(String.trim(shift)) do
      {num, ""} when num in [0, 43_200, 86_400] -> num
      _ -> 0
    end
  end

  defp normalize_shift(_shift), do: 0

  # --- First pass: classify, correct and resolve times ---

  @type stop_entry :: %{
          required(:col) => non_neg_integer(),
          required(:occurrence_id) => term(),
          required(:raw) => String.t(),
          required(:token) => TimeToken.token(),
          optional(:cell) => TimeToken.cell(),
          optional(:stop_id) => String.t() | nil
        }

  @type outcome ::
          :skip
          | {:cell, non_neg_integer(), String.t()}
          | {:backwards, non_neg_integer(), String.t()}
          | :empty
          | {:times, [stop_entry()], 0 | 43_200 | 86_400}

  @spec resolve_times(pos_integer(), [String.t()], [map()], map()) :: map()
  defp resolve_times(row_num, cells, stop_cols, decision) do
    outcome =
      if decision.skip do
        :skip
      else
        classify_row(cells, stop_cols, decision)
      end

    %{row: row_num, cells: cells, decision: decision, outcome: outcome}
  end

  @spec classify_row([String.t()], [map()], map()) :: outcome()
  defp classify_row(cells, stop_cols, decision) do
    entries =
      Enum.map(stop_cols, fn %{col: col, occurrence_id: id} ->
        raw = cells |> Enum.at(col, "") |> apply_correction(decision.cells, col)
        %{col: col, occurrence_id: id, raw: raw, token: TimeToken.classify(raw)}
      end)

    case Enum.find(entries, &match?(%{token: {:error, :unrecognized}}, &1)) do
      %{col: col, raw: raw} ->
        {:cell, col, raw}

      nil ->
        tokens = Enum.map(entries, & &1.token)

        case TimeToken.resolve_row(tokens, decision.shift) do
          {:error, {:time_goes_backwards, index}} ->
            failed = Enum.at(entries, index, %{col: -1, raw: ""})
            {:backwards, failed.col, failed.raw}

          {:ok, resolved} ->
            with_cells =
              entries
              |> Enum.zip(resolved)
              |> Enum.map(fn {entry, cell} -> Map.put(entry, :cell, cell) end)

            if Enum.any?(with_cells, &time_cell?/1) do
              {:times, with_cells, decision.shift}
            else
              :empty
            end
        end
    end
  end

  @spec apply_correction(String.t(), map(), non_neg_integer()) :: String.t()
  defp apply_correction(raw, corrections, col) do
    raw = if is_binary(raw), do: raw, else: ""
    corrections |> Map.get(col, raw) |> to_cell()
  end

  @spec time_cell?(map()) :: boolean()
  defp time_cell?(%{cell: %{secs: _secs}}), do: true
  defp time_cell?(_entry), do: false

  @spec median_first([map()]) :: non_neg_integer() | nil
  defp median_first(prelim) do
    firsts =
      prelim
      |> Enum.flat_map(fn
        %{outcome: {:times, entries, _shift}} ->
          case Enum.find(entries, &time_cell?/1) do
            %{cell: %{secs: secs}} -> [secs]
            nil -> []
          end

        _row ->
          []
      end)
      |> Enum.sort()

    case firsts do
      [] -> nil
      [_ | _] -> median_of_sorted(firsts)
    end
  end

  @spec median_of_sorted([non_neg_integer()]) :: non_neg_integer()
  defp median_of_sorted(sorted) do
    count = length(sorted)

    if rem(count, 2) == 1 do
      Enum.at(sorted, div(count, 2))
    else
      lower = Enum.at(sorted, div(count, 2) - 1)
      upper = Enum.at(sorted, div(count, 2))
      div(lower + upper, 2)
    end
  end

  # --- Second pass: twelve-hour question, then pattern assignment ---

  @spec finish_row(map(), map(), map() | nil, [map()], map(), non_neg_integer() | nil) ::
          resolved_row()
  defp finish_row(%{outcome: :skip} = prelim, _fields, _chosen, _patterns, _by, _median) do
    skipped_row(prelim.row, nil, prelim.decision.shift)
  end

  defp finish_row(%{outcome: :empty} = prelim, _fields, _chosen, _patterns, _by, _median) do
    skipped_row(prelim.row, :empty, prelim.decision.shift)
  end

  defp finish_row(%{outcome: {:cell, col, raw}} = prelim, fields, _c, _p, _b, _m) do
    decision_row(prelim, fields, {:cell, col, raw})
  end

  defp finish_row(%{outcome: {:backwards, col, raw}} = prelim, fields, _c, _p, _b, _m) do
    decision_row(prelim, fields, {:backwards, col, raw})
  end

  defp finish_row(
         %{outcome: {:times, entries, shift}} = prelim,
         field_cols,
         chosen,
         patterns,
         by_pattern,
         median
       ) do
    case twelve_hour_issue(entries, prelim.decision, median) do
      {:twelve_hour, _secs} = issue ->
        decision_row(prelim, field_cols, issue)

      nil ->
        assign_pattern(prelim, entries, field_cols, chosen, patterns, by_pattern, shift)
    end
  end

  @spec twelve_hour_issue([stop_entry()], map(), non_neg_integer() | nil) ::
          {:twelve_hour, non_neg_integer()} | nil
  defp twelve_hour_issue(_entries, %{shift: shift}, _median) when shift != 0, do: nil
  defp twelve_hour_issue(_entries, %{keep_early: true}, _median), do: nil

  defp twelve_hour_issue(entries, _decision, median) do
    case Enum.find(entries, &time_cell?/1) do
      %{token: token, cell: %{secs: secs}} ->
        if TimeToken.twelve_hour_question?(token, median), do: {:twelve_hour, secs}, else: nil

      nil ->
        nil
    end
  end

  @spec assign_pattern(map(), [stop_entry()], map(), map() | nil, [map()], map(), integer()) ::
          resolved_row()
  defp assign_pattern(prelim, entries, field_cols, chosen, patterns, by_pattern, shift) do
    chosen_by_id = chosen_occurrences(chosen)
    served = entries |> Enum.filter(&time_cell?/1) |> attach_stops(chosen_by_id)

    cond do
      is_binary(prelim.decision.pattern_id) and
          Map.has_key?(by_pattern, prelim.decision.pattern_id) ->
        target = Map.fetch!(by_pattern, prelim.decision.pattern_id)
        occ_map = correspondence_map(served, target.occurrences)

        ready_row(
          prelim,
          field_cols,
          target.id,
          :chosen,
          pasted_positions(served, occ_map),
          shift
        )

      keep_chosen?(entries, served, chosen) ->
        occ_map = Map.new(chosen.occurrences, &{&1.id, &1})

        ready_row(
          prelim,
          field_cols,
          chosen.id,
          :default,
          pasted_positions(served, occ_map),
          shift
        )

      true ->
        case candidates(served, entries, patterns, chosen_by_id) do
          [{pattern, occ_map}] ->
            ready_row(
              prelim,
              field_cols,
              pattern.id,
              :auto,
              pasted_positions(served, occ_map),
              shift
            )

          [] ->
            decision_row(prelim, field_cols, :no_pattern)

          fits ->
            ids = Enum.map(fits, fn {pattern, _map} -> pattern.id end)
            decision_row(prelim, field_cols, {:pattern, ids})
        end
    end
  end

  @spec chosen_occurrences(map() | nil) :: %{optional(term()) => map()}
  defp chosen_occurrences(%{occurrences: occurrences}), do: Map.new(occurrences, &{&1.id, &1})
  defp chosen_occurrences(_chosen), do: %{}

  @spec attach_stops([stop_entry()], map()) :: [map()]
  defp attach_stops(entries, chosen_by_id) do
    Enum.map(entries, fn %{occurrence_id: id} = entry ->
      case Map.fetch(chosen_by_id, id) do
        {:ok, %{stop_id: stop_id}} -> Map.put(entry, :stop_id, stop_id)
        :error -> Map.put(entry, :stop_id, nil)
      end
    end)
  end

  @spec served_stop_ids([map()]) :: [String.t()]
  defp served_stop_ids(served) do
    served
    |> Enum.map(&Map.get(&1, :stop_id))
    |> Enum.reject(&is_nil/1)
  end

  @spec explicit_stop_ids([stop_entry()], map()) :: [String.t()]
  defp explicit_stop_ids(entries, chosen_by_id) do
    entries
    |> Enum.filter(fn %{raw: raw} -> explicit_not_served?(raw) end)
    |> Enum.map(fn %{occurrence_id: id} ->
      case Map.fetch(chosen_by_id, id) do
        {:ok, %{stop_id: stop_id}} -> stop_id
        :error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec explicit_not_served?(String.t()) :: boolean()
  defp explicit_not_served?(raw) when is_binary(raw) do
    String.trim(raw) != "" and TimeToken.classify(raw) == :not_served
  end

  defp explicit_not_served?(_raw), do: false

  @spec keep_chosen?([stop_entry()], [map()], map() | nil) :: boolean()
  defp keep_chosen?(_entries, _served, nil), do: false
  defp keep_chosen?(_entries, [], _chosen), do: false
  defp keep_chosen?(_entries, _served, %{occurrences: []}), do: false

  defp keep_chosen?(entries, served, %{occurrences: occurrences}) do
    every_served? = length(served) == length(entries)
    mapped = MapSet.new(entries, & &1.occurrence_id)
    first = hd(occurrences)
    last = List.last(occurrences)

    every_served? and MapSet.member?(mapped, first.id) and MapSet.member?(mapped, last.id)
  end

  @spec candidates([map()], [stop_entry()], [map()], map()) :: [{map(), map()}]
  defp candidates([], _entries, _patterns, _chosen_by_id), do: []

  defp candidates(served, entries, patterns, chosen_by_id) do
    served_ids = served_stop_ids(served)
    explicit_ids = explicit_stop_ids(entries, chosen_by_id)

    Enum.flat_map(patterns, fn pattern ->
      case candidate_fit(served, served_ids, explicit_ids, pattern) do
        {:ok, occ_map} -> [{pattern, occ_map}]
        :no_fit -> []
      end
    end)
  end

  @spec candidate_fit([map()], [String.t()], [String.t()], map()) :: {:ok, map()} | :no_fit
  defp candidate_fit(_served, _served_ids, _explicit_ids, %{occurrences: []}), do: :no_fit

  defp candidate_fit(served, served_ids, explicit_ids, %{occurrences: occurrences}) do
    stop_set = MapSet.new(occurrences, & &1.stop_id)

    cond do
      Enum.any?(explicit_ids, &MapSet.member?(stop_set, &1)) ->
        :no_fit

      not endpoints_match?(served_ids, occurrences) ->
        :no_fit

      true ->
        correspond(served, occurrences)
    end
  end

  @spec endpoints_match?([String.t()], [map()]) :: boolean()
  defp endpoints_match?([], _occurrences), do: false

  defp endpoints_match?(served_ids, occurrences) do
    List.first(served_ids) == hd(occurrences).stop_id and
      List.last(served_ids) == List.last(occurrences).stop_id
  end

  # In-order occurrence correspondence: each served column takes the next
  # occurrence of its stop after the previously matched one. Matching is by
  # stop identity along the candidate's own order, never by position, so
  # short turns, deviations and loops resolve through their own occurrences.
  @spec correspond([map()], [map()]) :: {:ok, map()} | :no_fit
  defp correspond(served, occurrences) do
    result =
      Enum.reduce_while(served, {occurrences, %{}}, fn entry, {rest, map} ->
        case match_next(Map.get(entry, :stop_id), rest) do
          {:ok, match, after_match} ->
            {:cont, {after_match, Map.put(map, entry.occurrence_id, match)}}

          :no_fit ->
            {:halt, :no_fit}
        end
      end)

    case result do
      :no_fit -> :no_fit
      {_rest, map} -> {:ok, map}
    end
  end

  @spec match_next(String.t() | nil, [map()]) :: {:ok, map(), [map()]} | :no_fit
  defp match_next(stop_id, rest) when is_binary(stop_id) do
    case Enum.split_while(rest, &(&1.stop_id != stop_id)) do
      {_before, []} -> :no_fit
      {_before, [match | after_match]} -> {:ok, match, after_match}
    end
  end

  defp match_next(_stop_id, _rest), do: :no_fit

  # Occurrence map from the chosen pattern to a decision-forced pattern. A
  # forced choice that does not fit leaves served columns unmapped; those
  # stops cannot materialize on the forced pattern and stay out of `pasted`.
  @spec correspondence_map([map()], [map()]) :: map()
  defp correspondence_map(served, occurrences) do
    case correspond(served, occurrences) do
      {:ok, map} -> map
      :no_fit -> %{}
    end
  end

  @spec pasted_positions([map()], map()) :: [integer()]
  defp pasted_positions(served, occ_map) do
    Enum.flat_map(served, fn %{occurrence_id: id} ->
      case Map.fetch(occ_map, id) do
        {:ok, %{position: position}} -> [position]
        :error -> []
      end
    end)
  end

  # --- Row builders (offsets stay nil; step 6 fills ready rows) ---

  @spec field_values([String.t()], map()) :: map()
  defp field_values(cells, field_cols) do
    %{
      trip_short_name: field_value(cells, field_cols.trip_short_name),
      block_id: field_value(cells, field_cols.block_id),
      trip_headsign: field_value(cells, field_cols.trip_headsign)
    }
  end

  @spec field_value([String.t()], non_neg_integer() | nil) :: String.t() | nil
  defp field_value(_cells, nil), do: nil

  defp field_value(cells, col) do
    case cells |> Enum.at(col, "") |> to_cell() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  @spec rolled?([map()]) :: boolean()
  defp rolled?(entries) do
    Enum.any?(entries, fn
      %{cell: %{rolled: rolled}} when not is_nil(rolled) -> true
      _entry -> false
    end)
  end

  @spec ready_row(map(), map(), term(), :default | :auto | :chosen, [integer()], integer()) ::
          resolved_row()
  defp ready_row(prelim, field_cols, pattern_id, how, pasted, shift) do
    fields = field_values(prelim.cells, field_cols)

    %{
      row: prelim.row,
      status: :ready,
      issue: nil,
      pattern_id: pattern_id,
      how: how,
      start_secs: nil,
      timing_rows: nil,
      key: nil,
      pasted: pasted,
      trip_short_name: fields.trip_short_name,
      block_id: fields.block_id,
      trip_headsign: fields.trip_headsign,
      rolled?: rolled?(served_entries(prelim)),
      shift: shift
    }
  end

  @spec decision_row(map(), map(), row_issue()) :: resolved_row()
  defp decision_row(prelim, field_cols, issue) do
    fields = field_values(prelim.cells, field_cols)

    %{
      row: prelim.row,
      status: :decision,
      issue: issue,
      pattern_id: nil,
      how: nil,
      start_secs: nil,
      timing_rows: nil,
      key: nil,
      pasted: [],
      trip_short_name: fields.trip_short_name,
      block_id: fields.block_id,
      trip_headsign: fields.trip_headsign,
      rolled?: rolled?(served_entries(prelim)),
      shift: prelim.decision.shift
    }
  end

  @spec skipped_row(pos_integer(), row_issue() | nil, integer()) :: resolved_row()
  defp skipped_row(row_num, issue, shift) do
    %{
      row: row_num,
      status: :skipped,
      issue: issue,
      pattern_id: nil,
      how: nil,
      start_secs: nil,
      timing_rows: nil,
      key: nil,
      pasted: [],
      trip_short_name: nil,
      block_id: nil,
      trip_headsign: nil,
      rolled?: false,
      shift: shift
    }
  end

  @spec served_entries(map()) :: [stop_entry()]
  defp served_entries(%{outcome: {:times, entries, _shift}}),
    do: Enum.filter(entries, &time_cell?/1)

  defp served_entries(_prelim), do: []
end

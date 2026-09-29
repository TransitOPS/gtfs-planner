defmodule GtfsPlanner.Gtfs.TimetablePaste.ColumnMatcher do
  @moduledoc """
  Matches pasted timetable headers to pattern stops and trip fields.

  `normalize/1` folds a header or stop name to a comparable form: NFD
  decomposition via `:unicode.characters_to_nfd_binary/1` with combining marks
  stripped, lowercase, `&` as `and`, whole-word `st`/`sta`/`term` expanded to
  `street`/`station`/`terminal`, and punctuation collapsed to single spaces.

  `match_header/2` tries one header against the scope stops in rule R5 order:
  stop code, exact stop ID (case-sensitive), normalized stop name, trip-field
  keywords, then a unique close name (`String.jaro_distance/2` of at least
  0.9 whose best score beats the next best by at least 0.02). A trailing
  `arr`/`arrival`/`dep`/`departure` word marks the arrival or departure side
  of the matched stop; the side travels in the fifth tuple element so step 4
  can pair adjacent arrival/departure columns per rule R4. When the stripped
  base matches nothing, the whole header is retried without a side so a stop
  genuinely named e.g. "Downtown Dep" still resolves.

  Both functions are public with `@doc false`: they are internal helpers for
  `match/4` (step 4), exposed so the per-rung unit tests can assert literal
  results. `match/4`, `issues/1`, `orient/2` and `match_headerless/2` below are
  the covered step 4 entry points; the `target()`/`column()` types are kept
  verbatim from the spec Contracts section.

  ## Step 4: occurrence assignment (rules R4/R5)

  `match/4` takes `(grid, scope_data, overrides, confirmations)`. The grid's
  first row holds the headers; the remaining rows are data used only to tell
  time-bearing columns apart. `scope_data` is a list of occurrence maps —
  each pattern occurrence joined with its stop display fields — of the form
  `%{id:, stop_id:, position:, stop_code:, stop_name:}` (extra keys ignored,
  missing display fields default). A stops map of the shape `match_header/2`
  accepts is also tolerated, but then no occurrence exists and every stop
  header stays unmatched. `review/2` (step 11) joins `scope.stops` into the
  chosen pattern's occurrences before calling.

  Assignment walks stop columns left to right per R4: each takes the next
  occurrence of its stop after the previous stop column's occurrence, so a
  loop A–B–A resolves in order. Two grid-adjacent columns sharing one
  occurrence are its arrival then its departure (pairing wins over header
  side words). A third column for one occurrence, or one whose occurrence is
  not later than its predecessor, is `:out_of_order`. Overrides
  (`"occ:<id>"`, field names, `"ignore"`) replace the automatic pick and
  confirmations (a `MapSet` of column indexes) promote `:close` to
  `:confirmed`; order is re-validated afterwards, so overrides that break
  order are flagged. A lone stop column defaults to the departure side.

  Time-bearing (rule AC-8) is decided with `TimeToken.classify/1`: an
  unmatched header stays `:unmatched` when any data cell in its column reads
  as a time (run numbers such as `"101"` count), otherwise the column is
  `:unused` (`:ignore`), so plain text columns never block the review. That
  keeps `issues/1` columns-only per its contract; the header-row distinction
  itself lives here, not in a later filter.

  `match_headerless/2` covers `header? false`: with no header row, `n`
  columns map onto the `n` timepoint occurrences in position order (each
  `:chosen`) when the counts are equal, else every column is `:unmatched`.
  "" headers are reported since there is nothing to display.
  """

  # Step 4 entry points (`match/4`, `issues/1`, `orient/2`,
  # `match_headerless/2`) build on these types; `target()` and `column()` are
  # kept verbatim from the spec Contracts section.
  @type target ::
          {:occurrence, Ecto.UUID.t(), :arrival | :departure}
          | :trip_short_name
          | :block_id
          | :trip_headsign
          | :ignore
          | nil

  @type column :: %{
          col: non_neg_integer(),
          header: String.t(),
          target: target(),
          status: :exact | :close | :confirmed | :chosen | :unmatched | :unused | :out_of_order,
          by: :stop_code | :stop_id | :stop_name | :similar_name | :keyword | nil
        }

  @type stop_match_by :: :stop_code | :stop_id | :stop_name | :similar_name
  @type confidence :: :exact | :close
  @type side :: :arrival | :departure | nil
  @type trip_field :: :trip_short_name | :block_id | :trip_headsign

  @type occurrence :: %{
          optional(:id) => term(),
          optional(:stop_id) => String.t(),
          optional(:position) => integer(),
          optional(:stop_code) => String.t() | nil,
          optional(:stop_name) => String.t()
        }

  @type scope_data :: [occurrence()] | %{optional(String.t()) => stop_entry()}

  @type issue :: %{
          col: non_neg_integer() | nil,
          kind: :unmatched | :close | :out_of_order | :too_few
        }

  @type stop_entry :: %{
          optional(:stop_code) => String.t() | nil,
          optional(:stop_name) => String.t()
        }

  @type header_match ::
          {:stop, String.t(), stop_match_by(), confidence(), side()}
          | {:field, trip_field()}
          | :none

  @close_threshold 0.9
  @uniqueness_gap 0.02

  @abbreviations %{"st" => "street", "sta" => "station", "term" => "terminal"}

  # Normalized keyword forms ("Trip #"/"Block #" collapse to "trip"/"block").
  # "Run" is deliberately absent: it is never a trip-number keyword (R5).
  @trip_fields %{
    "trip" => :trip_short_name,
    "trip no" => :trip_short_name,
    "trip number" => :trip_short_name,
    "train" => :trip_short_name,
    "block" => :block_id,
    "block id" => :block_id,
    "headsign" => :trip_headsign,
    "destination" => :trip_headsign
  }

  @side_words %{
    "arr" => :arrival,
    "arrival" => :arrival,
    "dep" => :departure,
    "departure" => :departure
  }

  # A side word only counts after a separator, so names ending in similar
  # letters ("Barr", "Depot", "Departures") never strip.
  @side_suffix ~r/[\s,;:\-–—_\[\(]+(arr|arrival|dep|departure)[\s\.\)\]]*$/i

  @doc false
  @spec normalize(String.t()) :: String.t()
  def normalize(text) when is_binary(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace("&", " and ")
    |> String.replace(~r/[^\p{L}\p{N}\s]+/u, " ")
    |> String.split()
    |> Enum.map(&Map.get(@abbreviations, &1, &1))
    |> Enum.join(" ")
  end

  @doc false
  @spec match_header(String.t(), %{optional(String.t()) => stop_entry()}) ::
          header_match()
  def match_header(header, stops) when is_binary(header) and is_map(stops) do
    trimmed = String.trim(header)
    {base, side} = split_side(trimmed)

    case match_base(base, stops) do
      {:stop, stop_id, by, confidence} -> {:stop, stop_id, by, confidence, side}
      {:field, _field} = field -> field
      :none when side != nil -> retry_whole_header(trimmed, stops)
      :none -> :none
    end
  end

  @spec retry_whole_header(String.t(), %{optional(String.t()) => stop_entry()}) ::
          header_match()
  defp retry_whole_header(trimmed, stops) do
    case match_base(trimmed, stops) do
      {:stop, stop_id, by, confidence} -> {:stop, stop_id, by, confidence, nil}
      other -> other
    end
  end

  @spec match_base(String.t(), %{optional(String.t()) => stop_entry()}) ::
          {:stop, String.t(), stop_match_by(), confidence()}
          | {:field, trip_field()}
          | :none
  defp match_base("", _stops), do: :none

  defp match_base(base, stops) do
    normalized = normalize(base)

    if normalized == "" do
      :none
    else
      ordered = stops |> Map.to_list() |> Enum.sort_by(&elem(&1, 0))

      with :none <- match_stop_code(ordered, normalized),
           :none <- match_stop_id(ordered, base),
           :none <- match_stop_name(ordered, normalized),
           :none <- match_keyword(normalized) do
        match_close_name(ordered, normalized)
      end
    end
  end

  @spec match_stop_code([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :stop_code, :exact} | :none
  defp match_stop_code(ordered, normalized) do
    Enum.find_value(ordered, :none, fn {stop_id, stop} ->
      case Map.get(stop, :stop_code) do
        nil -> nil
        code -> if normalize(code) == normalized, do: {:stop, stop_id, :stop_code, :exact}
      end
    end)
  end

  @spec match_stop_id([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :stop_id, :exact} | :none
  defp match_stop_id(ordered, base) do
    Enum.find_value(ordered, :none, fn {stop_id, _stop} ->
      if stop_id == base, do: {:stop, stop_id, :stop_id, :exact}
    end)
  end

  @spec match_stop_name([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :stop_name, :exact} | :none
  defp match_stop_name(ordered, normalized) do
    Enum.find_value(ordered, :none, fn {stop_id, stop} ->
      if normalize(Map.get(stop, :stop_name, "")) == normalized do
        {:stop, stop_id, :stop_name, :exact}
      end
    end)
  end

  @spec match_keyword(String.t()) :: {:field, trip_field()} | :none
  defp match_keyword(normalized) do
    case Map.get(@trip_fields, normalized) do
      nil -> :none
      field -> {:field, field}
    end
  end

  @spec match_close_name([{String.t(), stop_entry()}], String.t()) ::
          {:stop, String.t(), :similar_name, :close} | :none
  defp match_close_name(ordered, normalized) do
    scored =
      ordered
      |> Enum.map(fn {stop_id, stop} ->
        {stop_id, String.jaro_distance(normalized, normalize(Map.get(stop, :stop_name, "")))}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    case scored do
      [{stop_id, best} | rest] when best >= @close_threshold ->
        second =
          case rest do
            [{_id, score} | _] -> score
            [] -> 0.0
          end

        if best - second >= @uniqueness_gap do
          {:stop, stop_id, :similar_name, :close}
        else
          :none
        end

      _ ->
        :none
    end
  end

  @spec split_side(String.t()) :: {String.t(), side()}
  defp split_side(trimmed) do
    case Regex.run(@side_suffix, trimmed) do
      [suffix, word] ->
        base =
          trimmed
          |> :binary.part(0, byte_size(trimmed) - byte_size(suffix))
          |> String.trim_trailing()

        {base, Map.fetch!(@side_words, String.downcase(word))}

      nil ->
        {trimmed, nil}
    end
  end

  # --- Step 4: occurrence assignment and order validation (rules R4/R5) ---

  alias GtfsPlanner.Gtfs.TimetablePaste.TimeToken

  @default_side :departure

  @field_overrides %{
    "trip_short_name" => :trip_short_name,
    "block_id" => :block_id,
    "trip_headsign" => :trip_headsign,
    "ignore" => :ignore
  }

  @doc """
  Detects the paste layout by comparing stop matches in the first row and column.

  Counts the cells of the first row and of the first column that match a stop
  via `match_header/2` (any rung, including close names). Returns
  `:stops_in_rows` when the first column matches more stops than the first
  row, otherwise `:trips_in_rows` (ties keep trips in rows).
  """
  @spec orient([[String.t()]], scope_data()) :: :trips_in_rows | :stops_in_rows
  def orient(grid, scope_data) when is_list(grid) do
    stops = to_stops_map(scope_data)
    first_row = grid |> List.first([]) |> row_cells()
    first_column = Enum.map(grid, &first_cell/1)

    row_hits = Enum.count(first_row, &stop_hit?(&1, stops))
    column_hits = Enum.count(first_column, &stop_hit?(&1, stops))

    if column_hits > row_hits, do: :stops_in_rows, else: :trips_in_rows
  end

  @doc """
  Maps the grid's header row to pattern occurrences left to right per R4.

  `overrides` maps a column index to `"occ:<id>"`, a trip-field name
  (`"trip_short_name"`, `"block_id"`, `"trip_headsign"`) or `"ignore"`;
  unknown ids or values leave the column `:unmatched`. `confirmations` is a
  `MapSet` of column indexes whose close match the editor accepted (`:close`
  becomes `:confirmed`). Overrides replace the automatic pick, confirmations
  promote close matches, then arrival/departure pairing and the order rule
  are applied to the final targets, so an override that breaks order is
  flagged `:out_of_order`.
  """
  @spec match(
          [[String.t()]],
          scope_data(),
          %{optional(non_neg_integer()) => String.t()},
          MapSet.t()
        ) :: [column()]
  def match(grid, scope_data, overrides, confirmations)
      when is_list(grid) and is_map(overrides) do
    {stops, occurrences} = resolve_scope(scope_data)
    by_id = Map.new(occurrences, &{&1.id, &1})
    headers = grid |> List.first([]) |> row_cells()
    bearing = grid |> Enum.drop(1) |> time_bearing_cols()

    initial = %{
      occurrences: occurrences,
      by_id: by_id,
      previous_position: nil,
      previous_occurrence: nil,
      previous_side: nil,
      previous_column: nil
    }

    {provisional, _state} =
      Enum.map_reduce(Enum.with_index(headers), initial, fn {header, col}, state ->
        auto_column(col, header, stops, bearing, state)
      end)

    provisional
    |> apply_overrides(overrides, stops, occurrences)
    |> apply_confirmations(confirmations)
    |> apply_pairing()
    |> validate_order(by_id)
  end

  @doc """
  Assigns header-less (`header? false`) columns to occurrences in order.

  With no header row, `n` columns map onto the `n` occurrences in position
  order (each `:chosen`) when the counts are equal, else every column is
  `:unmatched`. `grid` holds the data rows; the column count is its widest
  row. Reported headers are `""` since there is nothing to display.
  """
  @spec match_headerless([[String.t()]], scope_data()) :: [column()]
  def match_headerless(grid, scope_data) when is_list(grid) do
    {_stops, occurrences} = resolve_scope(scope_data)

    width =
      grid
      |> Enum.filter(&is_list/1)
      |> Enum.map(&length/1)
      |> Enum.max(fn -> 0 end)

    if width > 0 and width == length(occurrences) do
      occurrences
      |> Enum.with_index()
      |> Enum.map(fn {occurrence, index} ->
        %{
          col: index,
          header: "",
          target: {:occurrence, occurrence.id, @default_side},
          status: :chosen,
          by: nil
        }
      end)
    else
      Enum.map(0..(width - 1)//1, fn index ->
        %{col: index, header: "", target: nil, status: :unmatched, by: nil}
      end)
    end
  end

  @doc """
  Returns the blocking column issues for AC-8.

  One entry per `:unmatched`, unconfirmed `:close` and `:out_of_order`
  column, in column order, plus `%{col: nil, kind: :too_few}` when fewer than
  two columns target occurrences. Columns that are `:exact`, `:confirmed`,
  `:chosen` or `:unused` report nothing.
  """
  @spec issues([column()]) :: [issue()]
  def issues(columns) when is_list(columns) do
    per_column =
      columns
      |> Enum.sort_by(& &1.col)
      |> Enum.flat_map(fn
        %{col: col, status: :unmatched} -> [%{col: col, kind: :unmatched}]
        %{col: col, status: :close} -> [%{col: col, kind: :close}]
        %{col: col, status: :out_of_order} -> [%{col: col, kind: :out_of_order}]
        _column -> []
      end)

    stop_columns = Enum.count(columns, &match?(%{target: {:occurrence, _, _}}, &1))

    if stop_columns < 2 do
      per_column ++ [%{col: nil, kind: :too_few}]
    else
      per_column
    end
  end

  @spec resolve_scope(scope_data()) :: {%{optional(String.t()) => stop_entry()}, [occurrence()]}
  defp resolve_scope(data) when is_map(data), do: {to_stops_map(data), []}

  defp resolve_scope(data) when is_list(data) do
    {to_stops_map(data), ordered_occurrences(data)}
  end

  @spec to_stops_map(scope_data()) :: %{optional(String.t()) => stop_entry()}
  defp to_stops_map(data) when is_map(data), do: data

  defp to_stops_map(data) when is_list(data) do
    Enum.reduce(data, %{}, fn
      %{stop_id: stop_id} = entry, acc when is_binary(stop_id) ->
        Map.put_new(acc, stop_id, %{
          stop_code: Map.get(entry, :stop_code),
          stop_name: Map.get(entry, :stop_name, "")
        })

      _entry, acc ->
        acc
    end)
  end

  @spec ordered_occurrences([occurrence()]) :: [occurrence()]
  defp ordered_occurrences(data) do
    data |> Enum.filter(&valid_occurrence?/1) |> Enum.sort_by(& &1.position)
  end

  @spec valid_occurrence?(term()) :: boolean()
  defp valid_occurrence?(%{id: id, stop_id: stop_id, position: position})
       when not is_nil(id) and is_binary(stop_id) and is_integer(position),
       do: true

  defp valid_occurrence?(_entry), do: false

  @spec row_cells(term()) :: [String.t()]
  defp row_cells(row) when is_list(row) do
    Enum.map(row, fn
      cell when is_binary(cell) -> cell
      _cell -> ""
    end)
  end

  defp row_cells(_row), do: []

  @spec first_cell(term()) :: String.t()
  defp first_cell([first | _]) when is_binary(first), do: first
  defp first_cell(_row), do: ""

  @spec stop_hit?(term(), %{optional(String.t()) => stop_entry()}) :: boolean()
  defp stop_hit?(cell, stops) when is_binary(cell) do
    match?({:stop, _, _, _, _}, match_header(cell, stops))
  end

  defp stop_hit?(_cell, _stops), do: false

  @spec time_bearing_cols([[String.t()]]) :: MapSet.t()
  defp time_bearing_cols(data_rows) do
    Enum.reduce(data_rows, MapSet.new(), fn
      row, acc when is_list(row) ->
        row
        |> Enum.with_index()
        |> Enum.reduce(acc, fn
          {cell, index}, set when is_binary(cell) ->
            case TimeToken.classify(cell) do
              {:time, _, _} -> MapSet.put(set, index)
              _other -> set
            end

          {_cell, _index}, set ->
            set
        end)

      _row, acc ->
        acc
    end)
  end

  @spec auto_column(
          non_neg_integer(),
          String.t(),
          %{optional(String.t()) => stop_entry()},
          MapSet.t(),
          map()
        ) :: {column(), map()}
  defp auto_column(col, header, stops, bearing, state) do
    case match_header(header, stops) do
      {:stop, stop_id, by, confidence, side} ->
        status = if confidence == :close, do: :close, else: :exact
        {pick, next_state} = take_occurrence(state, col, stop_id, side)
        {stop_column(col, header, pick, by, status), next_state}

      {:field, field} ->
        {%{col: col, header: header, target: field, status: :exact, by: :keyword}, state}

      :none ->
        if MapSet.member?(bearing, col) do
          {%{col: col, header: header, target: nil, status: :unmatched, by: nil}, state}
        else
          {%{col: col, header: header, target: :ignore, status: :unused, by: nil}, state}
        end
    end
  end

  @spec stop_column(non_neg_integer(), String.t(), nil | {occurrence(), side()}, atom(), atom()) ::
          column()
  defp stop_column(col, header, nil, _by, _status) do
    %{col: col, header: header, target: nil, status: :unmatched, by: nil}
  end

  defp stop_column(col, header, {occurrence, side}, by, status) do
    %{
      col: col,
      header: header,
      target: {:occurrence, occurrence.id, side},
      status: status,
      by: by
    }
  end

  @spec take_occurrence(map(), non_neg_integer(), String.t(), side()) ::
          {nil | {occurrence(), side()}, map()}
  defp take_occurrence(state, col, stop_id, side) do
    wanted = side || @default_side
    candidates = Enum.filter(state.occurrences, &(&1.stop_id == stop_id))

    cond do
      pair_open?(state, col, stop_id) ->
        occurrence = Map.fetch!(state.by_id, state.previous_occurrence)
        {{occurrence, :departure}, track(state, col, occurrence, :departure)}

      true ->
        case Enum.find(candidates, &after_previous?(&1, state.previous_position)) do
          nil ->
            case List.first(candidates) do
              nil -> {nil, state}
              fallback -> {{fallback, wanted}, track(state, col, fallback, wanted)}
            end

          next ->
            {{next, wanted}, track(state, col, next, wanted)}
        end
    end
  end

  @spec pair_open?(map(), non_neg_integer(), String.t()) :: boolean()
  defp pair_open?(%{previous_occurrence: nil}, _col, _stop_id), do: false

  defp pair_open?(state, col, stop_id) do
    state.previous_column == col - 1 and state.previous_side == :arrival and
      case Map.fetch(state.by_id, state.previous_occurrence) do
        {:ok, %{stop_id: ^stop_id}} -> true
        _otherwise -> false
      end
  end

  @spec after_previous?(occurrence(), integer() | nil) :: boolean()
  defp after_previous?(_occurrence, nil), do: true
  defp after_previous?(%{position: position}, previous), do: position > previous

  @spec track(map(), non_neg_integer(), occurrence(), side()) :: map()
  defp track(state, col, occurrence, side) do
    %{
      state
      | previous_position: occurrence.position,
        previous_occurrence: occurrence.id,
        previous_side: side,
        previous_column: col
    }
  end

  @spec apply_overrides([column()], map(), %{optional(String.t()) => stop_entry()}, [occurrence()]) ::
          [column()]
  defp apply_overrides(columns, overrides, stops, occurrences) do
    Enum.map(columns, fn %{col: col, header: header} = column ->
      case Map.fetch(overrides, col) do
        {:ok, value} -> override_column(column, header, value, stops, occurrences)
        :error -> column
      end
    end)
  end

  @spec override_column(
          column(),
          String.t(),
          String.t(),
          %{optional(String.t()) => stop_entry()},
          [
            occurrence()
          ]
        ) :: column()
  defp override_column(column, header, "occ:" <> id, stops, occurrences) do
    case Enum.find(occurrences, &(&1.id == id)) do
      nil ->
        %{column | target: nil, status: :unmatched, by: nil}

      occurrence ->
        %{
          column
          | target: {:occurrence, occurrence.id, override_side(header, stops)},
            status: :chosen,
            by: nil
        }
    end
  end

  defp override_column(column, _header, value, _stops, _occurrences) do
    case Map.fetch(@field_overrides, value) do
      {:ok, :ignore} -> %{column | target: :ignore, status: :unused, by: nil}
      {:ok, field} -> %{column | target: field, status: :chosen, by: nil}
      :error -> %{column | target: nil, status: :unmatched, by: nil}
    end
  end

  @spec override_side(String.t(), %{optional(String.t()) => stop_entry()}) ::
          :arrival | :departure
  defp override_side(header, stops) do
    case match_header(header, stops) do
      {:stop, _stop_id, _by, _confidence, side} -> side || @default_side
      _otherwise -> @default_side
    end
  end

  @spec apply_confirmations([column()], MapSet.t()) :: [column()]
  defp apply_confirmations(columns, confirmations) do
    Enum.map(columns, fn
      %{col: col, status: :close} = column ->
        if confirmed?(confirmations, col), do: %{column | status: :confirmed}, else: column

      column ->
        column
    end)
  end

  @spec confirmed?(term(), non_neg_integer()) :: boolean()
  defp confirmed?(%MapSet{} = confirmations, col), do: MapSet.member?(confirmations, col)
  defp confirmed?(_confirmations, _col), do: false

  @spec apply_pairing([column()]) :: [column()]
  defp apply_pairing(columns) do
    columns
    |> Enum.sort_by(& &1.col)
    |> collect_runs([], [])
    |> Enum.flat_map(&sides_for_run/1)
  end

  @spec collect_runs([column()], [[column()]], [column()]) :: [[column()]]
  defp collect_runs([], done, []), do: Enum.reverse(done)
  defp collect_runs([], done, current), do: Enum.reverse([Enum.reverse(current) | done])

  defp collect_runs([entry | rest], done, []) do
    collect_runs(rest, done, [entry])
  end

  defp collect_runs([entry | rest], done, [previous | _] = current) do
    if adjacent_pair?(previous, entry) do
      collect_runs(rest, done, [entry | current])
    else
      collect_runs(rest, [Enum.reverse(current) | done], [entry])
    end
  end

  @spec adjacent_pair?(column(), column()) :: boolean()
  defp adjacent_pair?(
         %{col: previous_col, target: {:occurrence, id, _}},
         %{col: col, target: {:occurrence, id, _}}
       )
       when col == previous_col + 1,
       do: true

  defp adjacent_pair?(_previous, _entry), do: false

  @spec sides_for_run([column()]) :: [column()]
  defp sides_for_run([first, second | rest]) do
    [with_side(first, :arrival), with_side(second, :departure) | rest]
  end

  defp sides_for_run(run), do: run

  @spec with_side(column(), :arrival | :departure) :: column()
  defp with_side(%{target: {:occurrence, id, _side}} = column, side) do
    %{column | target: {:occurrence, id, side}}
  end

  @spec validate_order([column()], %{optional(term()) => occurrence()}) :: [column()]
  defp validate_order(columns, by_id) do
    initial = %{
      previous_position: nil,
      previous_occurrence: nil,
      previous_side: nil,
      previous_column: nil
    }

    {validated, _state} =
      columns
      |> Enum.sort_by(& &1.col)
      |> Enum.map_reduce(initial, fn column, state ->
        {validate_column(column, state, by_id), track_validated(state, column, by_id)}
      end)

    validated
  end

  @spec validate_column(column(), map(), %{optional(term()) => occurrence()}) :: column()
  defp validate_column(%{target: {:occurrence, id, side}, col: col} = column, state, by_id) do
    position = occurrence_position(by_id, id)

    cond do
      pair_complete?(state, col, id, side) ->
        column

      state.previous_position != nil and position != nil and position <= state.previous_position ->
        %{column | status: :out_of_order}

      true ->
        column
    end
  end

  defp validate_column(column, _state, _by_id), do: column

  @spec pair_complete?(map(), non_neg_integer(), term(), side()) :: boolean()
  defp pair_complete?(state, col, id, side) do
    state.previous_occurrence == id and state.previous_column == col - 1 and
      state.previous_side == :arrival and side == :departure
  end

  @spec occurrence_position(%{optional(term()) => occurrence()}, term()) :: integer() | nil
  defp occurrence_position(by_id, id) do
    case Map.fetch(by_id, id) do
      {:ok, %{position: position}} -> position
      :error -> nil
    end
  end

  @spec track_validated(map(), column(), %{optional(term()) => occurrence()}) :: map()
  defp track_validated(state, %{target: {:occurrence, id, side}, col: col}, by_id) do
    case Map.fetch(by_id, id) do
      {:ok, %{position: position}} ->
        %{
          state
          | previous_position: position,
            previous_occurrence: id,
            previous_side: side,
            previous_column: col
        }

      :error ->
        state
    end
  end

  defp track_validated(state, _column, _by_id), do: state
end

defmodule GtfsPlanner.Gtfs.TimetablePaste do
  @moduledoc """
  Pure review orchestration and freshness fingerprint for pasted timetables.

  `review/2` composes steps 1–10 into one pure review of `(scope, input)`:

    1. Parse the clipboard text with `ClipboardParser.parse/2`, resolving the
       layout first: `:trips_in_rows` parses as-is, `:stops_in_rows` parses
       transposed, and `:auto` parses as-is then orients the grid with
       `ColumnMatcher.orient/2` and re-parses transposed when the first
       column matches more stops than the first row.
    2. Enforce the exact limits after orientation: at most 500 trip rows
       (header excluded) and at most 150 columns, else `{:too_many_rows, n}`
       / `{:too_many_columns, n}`. Return `:no_times` when no time-like cell
       exists. Parse errors propagate unchanged; the input (and its text)
       stays with the caller, which keeps the textarea.
    3. Match columns with `ColumnMatcher.match/4` (or `match_headerless/2`
       when `header?` is false) over the chosen pattern's occurrences joined
       with `scope.stops`, then report `ColumnMatcher.issues/1`.
    4. While column issues exist the review carries `rows: []` and
       `plan: nil`; otherwise resolve the header-stripped data rows with
       `RowResolver.resolve/5` and plan them with `Plan.build/6`.

  ## Shapes

  `scope` is the plain map `Schedules.load_paste_scope/5` (step 16) loads:
  `route`, `calendar` (with `service_id`), `direction_id`, `pattern_id`,
  `patterns` (each with `occurrences` and `timings` whose `rows` align
  positionally with the occurrences), `stops` (`stop_id => %{stop_code,
  stop_name}`), and `trips` (every trip of the route on the calendar, both
  directions, with `span`/`spans`/`start_secs`+`end_secs` for the vehicles
  preview and `service_id` on the calendar). `RowResolver` needs each timing
  as `%{id:, rows:, trip_count:}` with rows positional against the
  occurrences; `Plan` needs the scope trip spans (Schedules shape, both
  directions), `calendar.service_id`, and atom-key `Checks.trip_row()` block
  rows, or vehicles undercount and block overlaps stay silent.

  `input` is `%{text:, layout: :auto | :trips_in_rows | :stops_in_rows,
  header?: boolean(), overrides:, confirmations: MapSet.t(), decisions:,
  mode: :add | :replace, template_timing_id: | nil, stamp:}` plus
  `input.block_rows` (passed to `Plan.build/6`; never fingerprinted).
  Missing keys fall back to `%{layout: :auto, header?: true, mode: :add}`.

  ## Fingerprint

  `fingerprint/2` is the freshness token `Schedules.apply_paste/5` (step 16)
  recomputes from locked state: the lowercase hex SHA-256 of
  `:erlang.term_to_binary({scope_term, input_term}, [:deterministic])`
  covering the spec "Transaction and freshness" list — scope keys; each
  pattern's occurrences; all timings of those patterns with every row; every
  trip of the route on the calendar in both directions (id, trip_id,
  start_secs, timed_pattern_id, state, block_id, trip_short_name,
  trip_headsign, frequency rows, updated_at); the transfers naming trips the
  plan removes or retimes; and the input (text digest, layout, header?,
  overrides, confirmations, decisions, mode, template). The text enters only
  as its SHA-256 digest, never raw. No new canonicalizer is introduced and
  `RoutePatterns`' private one is not exposed.

  Pure: no Repo, clock or process state (INV-3). `review/2` is a pure
  function of `(scope, input)` so apply can reload under locks and compare
  fingerprints.
  """

  alias GtfsPlanner.Gtfs.TimetablePaste.ClipboardParser
  alias GtfsPlanner.Gtfs.TimetablePaste.ColumnMatcher
  alias GtfsPlanner.Gtfs.TimetablePaste.Plan
  alias GtfsPlanner.Gtfs.TimetablePaste.RowResolver
  alias GtfsPlanner.Gtfs.TimetablePaste.TimeToken

  @max_trip_rows 500
  @max_columns 150

  @type input :: %{optional(atom()) => term()}
  @type scope :: %{optional(atom()) => term()}

  @type review :: %{
          grid: [[String.t()]],
          orientation: :trips_in_rows | :stops_in_rows,
          columns: [ColumnMatcher.column()],
          column_issues: [ColumnMatcher.issue()],
          rows: [RowResolver.resolved_row()],
          plan: map() | nil,
          fingerprint: String.t()
        }

  @type parse_error ::
          {:too_large, non_neg_integer()}
          | {:too_many_rows, pos_integer()}
          | {:too_many_columns, pos_integer()}
          | {:unclosed_quote, pos_integer()}
          | :empty

  @doc """
  Reviews pasted clipboard text against the loaded scope.

  Returns `{:ok, review()}` or `{:error, parse_error() | :no_times}`. The
  error carries only the specific reason; the caller's input map (with its
  text) is never consumed, so the page keeps the textarea.
  """
  @spec review(scope(), input()) ::
          {:ok, review()} | {:error, parse_error() | :no_times}
  def review(scope, input) do
    scope = normalize_scope(scope)
    input = normalize_input(input)

    case do_review(scope, input) do
      {:ok, parts} -> {:ok, Map.put(parts, :fingerprint, fingerprint(scope, input))}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns the 64-character lowercase hex freshness digest for `(scope, input)`.

  Never raises on map inputs: when the input cannot build a plan (parse
  error, limits, no times, column issues), the transfer element is empty but
  the scope and input terms still digest deterministically.
  """
  @spec fingerprint(scope(), input()) :: String.t()
  def fingerprint(scope, input) do
    scope = normalize_scope(scope)
    input = normalize_input(input)
    transfers = affected_transfer_ids(scope, input)
    term = {scope_term(scope, transfers), input_term(input)}

    :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The paste set-flag rule: only the literal `true` is set.

  The paste LiveView writes `true` for `keep`, `skip` and `keep_early`
  (or deletes the key), and the decisions JSON hidden field round-trips
  booleans unchanged, so a forged string, number or list must not keep,
  skip or keep-early a row.
  """
  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: value == true

  @doc """
  The paste row-number rule: an integer >= 1, or a numeric string after
  `String.trim/1`, otherwise `nil`.

  Decision keys arrive as integers or numeric strings (the JSON hidden
  field round trip); trimming keeps `" 3"` targeting row 3, and `nil`
  marks a key that names no row.
  """
  @spec row_number(term()) :: pos_integer() | nil
  def row_number(row) when is_integer(row) and row >= 1, do: row

  def row_number(row) when is_binary(row) do
    case Integer.parse(String.trim(row)) do
      {num, ""} when num >= 1 -> num
      _parse -> nil
    end
  end

  def row_number(_row), do: nil

  # --- Review pipeline (fingerprint-free; shared by review/2 and fingerprint/2) ---

  @spec do_review(map(), map()) ::
          {:ok,
           %{
             grid: term(),
             orientation: atom(),
             columns: list(),
             column_issues: list(),
             rows: list(),
             plan: term()
           }}
          | {:error, parse_error() | :no_times}
  defp do_review(scope, input) do
    with {:ok, grid, orientation} <- parse_oriented(input.text, input.layout, scope),
         :ok <- check_limits(grid, input.header?),
         {:ok, data} <- checked_data_rows(grid, input) do
      columns = match_columns(grid, data, scope, input)
      issues = ColumnMatcher.issues(columns)

      if issues == [] do
        rows =
          RowResolver.resolve(data, columns, scope, input.decisions, input.template_timing_id)

        plan = Plan.build(rows, scope, input.mode, input.decisions, input.stamp, input.block_rows)

        {:ok,
         %{
           grid: grid,
           orientation: orientation,
           columns: columns,
           column_issues: [],
           rows: rows,
           plan: plan
         }}
      else
        {:ok,
         %{
           grid: grid,
           orientation: orientation,
           columns: columns,
           column_issues: issues,
           rows: [],
           plan: nil
         }}
      end
    end
  end

  @spec checked_data_rows([[String.t()]], map()) :: {:ok, [[String.t()]]} | {:error, :no_times}
  defp checked_data_rows(grid, input) do
    data = data_rows(grid, input.header?)

    case check_times(data) do
      :ok -> {:ok, data}
      {:error, _reason} = error -> error
    end
  end

  @spec parse_oriented(String.t(), atom(), map()) ::
          {:ok, [[String.t()]], :trips_in_rows | :stops_in_rows} | {:error, parse_error()}
  defp parse_oriented(text, :trips_in_rows, _scope) do
    case ClipboardParser.parse(text, transpose: false) do
      {:ok, %{grid: grid}} -> {:ok, grid, :trips_in_rows}
      {:error, _reason} = error -> error
    end
  end

  defp parse_oriented(text, :stops_in_rows, _scope) do
    case ClipboardParser.parse(text, transpose: true) do
      {:ok, %{grid: grid}} -> {:ok, grid, :stops_in_rows}
      {:error, _reason} = error -> error
    end
  end

  defp parse_oriented(text, _layout, scope) do
    with {:ok, %{grid: grid}} <- ClipboardParser.parse(text, transpose: false) do
      orient_grid(text, grid, scope)
    end
  end

  defp orient_grid(text, grid, scope) do
    case ColumnMatcher.orient(grid, Map.get(scope, :stops, %{})) do
      :trips_in_rows -> {:ok, grid, :trips_in_rows}
      :stops_in_rows -> transpose_grid(text)
    end
  end

  defp transpose_grid(text) do
    case ClipboardParser.parse(text, transpose: true) do
      {:ok, %{grid: transposed}} -> {:ok, transposed, :stops_in_rows}
      {:error, _reason} = error -> error
    end
  end

  @spec check_limits([[String.t()]], boolean()) ::
          :ok | {:error, {:too_many_rows | :too_many_columns, pos_integer()}}
  defp check_limits(grid, header?) do
    width =
      grid
      |> Enum.map(fn row -> if is_list(row), do: length(row), else: 0 end)
      |> Enum.max(fn -> 0 end)

    trip_rows =
      if header? do
        max(length(grid) - 1, 0)
      else
        length(grid)
      end

    cond do
      trip_rows > @max_trip_rows -> {:error, {:too_many_rows, trip_rows}}
      width > @max_columns -> {:error, {:too_many_columns, width}}
      true -> :ok
    end
  end

  @spec data_rows([[String.t()]], boolean()) :: [[String.t()]]
  defp data_rows(grid, true) do
    case grid do
      [] -> []
      [_header | rest] -> rest
    end
  end

  defp data_rows(grid, _header?), do: grid

  @spec check_times([[String.t()]]) :: :ok | {:error, :no_times}
  defp check_times(data) do
    found? =
      Enum.any?(data, fn
        row when is_list(row) ->
          Enum.any?(row, fn
            cell when is_binary(cell) -> match?({:time, _, _}, TimeToken.classify(cell))
            _cell -> false
          end)

        _row ->
          false
      end)

    if found?, do: :ok, else: {:error, :no_times}
  end

  @spec match_columns([[String.t()]], [[String.t()]], map(), map()) :: [ColumnMatcher.column()]
  defp match_columns(grid, data, scope, input) do
    occurrences = match_occurrences(scope)

    if input.header? do
      ColumnMatcher.match(grid, occurrences, input.overrides, input.confirmations)
    else
      ColumnMatcher.match_headerless(data, occurrences)
    end
  end

  # Joins scope.stops into the chosen pattern's occurrences so ColumnMatcher
  # sees one `%{id:, stop_id:, position:, stop_code:, stop_name:}` row per
  # occurrence (INV-1: columns reach occurrences only through this join).
  @spec match_occurrences(map()) :: [map()]
  defp match_occurrences(scope) do
    patterns = get_list(scope, :patterns, "patterns")
    pattern_id = get(scope, :pattern_id, "pattern_id")
    stops = get_map(scope, :stops, "stops")

    chosen =
      Enum.find(patterns, fn pattern ->
        is_map(pattern) and get(pattern, :id, "id") == pattern_id
      end)

    occurrences =
      case chosen do
        pattern when is_map(pattern) -> get_list(pattern, :occurrences, "occurrences")
        _chosen -> []
      end

    occurrences
    |> Enum.filter(&valid_occurrence?/1)
    |> Enum.sort_by(&position_of/1)
    |> Enum.map(fn occurrence ->
      stop = stop_entry(stops, stop_id_of(occurrence))

      %{
        id: get(occurrence, :id, "id"),
        stop_id: stop_id_of(occurrence),
        position: position_of(occurrence),
        stop_code: get(stop, :stop_code, "stop_code"),
        stop_name: stop_name_of(stop)
      }
    end)
  end

  @spec valid_occurrence?(term()) :: boolean()
  defp valid_occurrence?(%{} = occurrence) do
    not is_nil(get(occurrence, :id, "id")) and is_binary(stop_id_of(occurrence)) and
      is_integer(position_of(occurrence))
  end

  defp valid_occurrence?(_occurrence), do: false

  @spec stop_id_of(map()) :: term()
  defp stop_id_of(occurrence), do: get(occurrence, :stop_id, "stop_id")

  @spec position_of(map()) :: integer()
  defp position_of(occurrence) do
    case get(occurrence, :position, "position") do
      position when is_integer(position) -> position
      _position -> 0
    end
  end

  @spec stop_entry(map(), term()) :: map()
  defp stop_entry(stops, stop_id) when is_map(stops) and is_binary(stop_id) do
    case Map.get(stops, stop_id) do
      entry when is_map(entry) -> entry
      _entry -> %{}
    end
  end

  defp stop_entry(_stops, _stop_id), do: %{}

  @spec stop_name_of(map()) :: String.t()
  defp stop_name_of(stop) do
    case get(stop, :stop_name, "stop_name") do
      name when is_binary(name) -> name
      _name -> ""
    end
  end

  # --- Fingerprint terms ---

  # Transfers naming trips the built plan removes or retimes. Read from the
  # carried scope trip maps on :remove/:change changes; empty when no plan
  # builds, so fingerprint/2 stays total.
  @spec affected_transfer_ids(map(), map()) :: [String.t()]
  defp affected_transfer_ids(scope, input) do
    case do_review(scope, input) do
      {:ok, %{plan: %{changes: changes}}} when is_list(changes) ->
        changes
        |> Enum.flat_map(fn
          %{op: op, trip: trip} when op in [:remove, :change] and is_map(trip) ->
            transfer_ids_of(trip)

          _change ->
            []
        end)
        |> Enum.uniq()
        |> Enum.sort()

      _otherwise ->
        []
    end
  end

  @spec transfer_ids_of(map()) :: [String.t()]
  defp transfer_ids_of(trip) do
    direct = get_list(trip, :transfer_ids, "transfer_ids")

    nested =
      trip
      |> get_list(:transfers, "transfers")
      |> Enum.flat_map(fn
        id when is_binary(id) ->
          [id]

        entry when is_map(entry) ->
          case get(entry, :id, "id") do
            id when is_binary(id) -> [id]
            _id -> []
          end

        _entry ->
          []
      end)

    (direct ++ nested) |> Enum.filter(&is_binary/1) |> Enum.uniq()
  end

  @spec scope_term(map(), [String.t()]) :: term()
  defp scope_term(scope, transfers) do
    patterns = get_list(scope, :patterns, "patterns")
    stops = get_map(scope, :stops, "stops")
    trips = get_list(scope, :trips, "trips")

    {scope_keys(scope), Enum.map(patterns, &pattern_term(&1, stops)),
     Enum.map(trips, &trip_term/1), transfers}
  end

  @spec scope_keys(map()) :: term()
  defp scope_keys(scope) do
    route = get(scope, :route, "route")
    calendar = get(scope, :calendar, "calendar")

    {route_id_of(route), service_id_of(calendar), get(scope, :direction_id, "direction_id"),
     get(scope, :pattern_id, "pattern_id")}
  end

  @spec route_id_of(term()) :: term()
  defp route_id_of(%{} = route), do: get(route, :id, "id")
  defp route_id_of(route), do: route

  @spec service_id_of(term()) :: term()
  defp service_id_of(%{} = calendar), do: get(calendar, :service_id, "service_id")
  defp service_id_of(calendar), do: calendar

  @spec pattern_term(term(), map()) :: term()
  defp pattern_term(pattern, stops) when is_map(pattern) do
    occurrences =
      pattern
      |> get_list(:occurrences, "occurrences")
      |> Enum.filter(&valid_occurrence?/1)
      |> Enum.sort_by(&position_of/1)
      |> Enum.map(fn occurrence ->
        stop = stop_entry(stops, stop_id_of(occurrence))

        {get(occurrence, :id, "id"), stop_id_of(occurrence), position_of(occurrence),
         get(stop, :stop_code, "stop_code"), stop_name_of(stop)}
      end)

    timings =
      pattern
      |> get_list(:timings, "timings")
      |> Enum.map(&timing_term/1)

    {get(pattern, :id, "id"), get(pattern, :route_pattern_id, "route_pattern_id"),
     get(pattern, :name, "name"), get(pattern, :headsign, "headsign"), occurrences, timings}
  end

  defp pattern_term(pattern, _stops), do: {pattern, nil, nil, nil, [], []}

  @spec timing_term(term()) :: term()
  defp timing_term(timing) when is_map(timing) do
    rows =
      timing
      |> get_list(:rows, "rows")
      |> Enum.map(fn
        row when is_map(row) ->
          {to_offset(get(row, :arrival_offset, "arrival_offset")),
           to_offset(get(row, :departure_offset, "departure_offset")),
           to_timepoint(get(row, :timepoint, "timepoint")), get(row, :pickup_type, "pickup_type"),
           get(row, :drop_off_type, "drop_off_type"), get(row, :stop_headsign, "stop_headsign")}

        row ->
          row
      end)

    {get(timing, :id, "id"), get(timing, :name, "name"), get(timing, :headsign, "headsign"), rows,
     trip_count_of(timing)}
  end

  defp timing_term(timing), do: {timing, nil, nil, [], 0}

  @spec trip_count_of(map()) :: non_neg_integer()
  defp trip_count_of(timing) do
    case get(timing, :trip_count, "trip_count") do
      count when is_integer(count) and count >= 0 -> count
      _count -> 0
    end
  end

  @spec to_offset(term()) :: integer()
  defp to_offset(value) when is_integer(value), do: value
  defp to_offset(_value), do: 0

  @spec to_timepoint(term()) :: 0 | 1
  defp to_timepoint(0), do: 0
  defp to_timepoint("0"), do: 0
  defp to_timepoint(false), do: 0
  defp to_timepoint(nil), do: 1
  defp to_timepoint(_value), do: 1

  @spec trip_term(term()) :: term()
  defp trip_term(trip) when is_map(trip) do
    {get(trip, :id, "id"), get(trip, :trip_id, "trip_id"),
     get(trip, :route_pattern_id, "route_pattern_id") || get(trip, :pattern_id, "pattern_id"),
     get(trip, :direction_id, "direction_id"), get(trip, :start_secs, "start_secs"),
     get(trip, :timed_pattern_id, "timed_pattern_id") || get(trip, :timing_id, "timing_id"),
     trip_state_of(trip), get(trip, :block_id, "block_id"),
     get(trip, :trip_short_name, "trip_short_name"), get(trip, :trip_headsign, "trip_headsign"),
     frequency_terms(trip), updated_at_term(get(trip, :updated_at, "updated_at"))}
  end

  defp trip_term(trip), do: {trip, nil, nil, nil, nil, nil, nil, nil, nil, nil, [], nil}

  @spec trip_state_of(map()) :: term()
  defp trip_state_of(trip) do
    get(trip, :pattern_derivation_state, "pattern_derivation_state") ||
      get(trip, :derivation_state, "derivation_state") || get(trip, :state, "state")
  end

  @spec frequency_terms(map()) :: term()
  defp frequency_terms(trip) do
    rows =
      get_list(trip, :frequency_rows, "frequency_rows") ++
        get_list(trip, :frequencies, "frequencies") ++ frequency_flag(trip)

    rows
    |> Enum.map(fn
      row when is_map(row) ->
        row |> Enum.map(fn {key, value} -> {to_string(key), value} end) |> Enum.sort()

      row ->
        row
    end)
    |> Enum.sort_by(&inspect/1)
  end

  @spec frequency_flag(map()) :: list()
  defp frequency_flag(trip) do
    if truthy?(get(trip, :frequency?, "frequency?")), do: [:frequency], else: []
  end

  @spec updated_at_term(term()) :: term()
  defp updated_at_term(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp updated_at_term(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  defp updated_at_term(%Date{} = date), do: Date.to_iso8601(date)
  defp updated_at_term(value), do: value

  @spec input_term(map()) :: term()
  defp input_term(input) do
    {text_digest(input.text), input.layout, input.header?,
     Map.to_list(input.overrides) |> Enum.sort(), Enum.sort(MapSet.to_list(input.confirmations)),
     input.decisions, input.mode, input.template_timing_id}
  end

  @spec text_digest(String.t()) :: String.t()
  defp text_digest(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp text_digest(_text), do: text_digest("")

  # --- Input/scope normalization ---

  @scope_keys [
    patterns: "patterns",
    pattern_id: "pattern_id",
    stops: "stops",
    trips: "trips",
    route: "route",
    calendar: "calendar",
    direction_id: "direction_id"
  ]

  @spec normalize_scope(term()) :: map()
  defp normalize_scope(scope) when is_map(scope) do
    Enum.reduce(@scope_keys, scope, &normalize_scope_key/2)
  end

  defp normalize_scope(_scope), do: %{}

  defp normalize_scope_key({atom, string}, acc) do
    if Map.has_key?(acc, atom) do
      acc
    else
      copy_scope_key(acc, atom, string)
    end
  end

  defp copy_scope_key(acc, atom, string) do
    case Map.fetch(acc, string) do
      {:ok, value} -> Map.put(acc, atom, value)
      :error -> acc
    end
  end

  @spec normalize_input(term()) :: map()
  defp normalize_input(input) when is_map(input) do
    text = get(input, :text, "text")
    block_rows = get(input, :block_rows, "block_rows")
    stamp = get(input, :stamp, "stamp")

    %{
      text: if(is_binary(text), do: text, else: ""),
      layout: normalize_layout(get(input, :layout, "layout")),
      header?: normalize_header(get(input, :header?, "header?")),
      overrides: normalize_overrides(get(input, :overrides, "overrides")),
      confirmations: normalize_confirmations(get(input, :confirmations, "confirmations")),
      decisions: normalize_decisions(get(input, :decisions, "decisions")),
      mode: normalize_mode(get(input, :mode, "mode")),
      template_timing_id: get(input, :template_timing_id, "template_timing_id"),
      stamp: if(is_binary(stamp), do: stamp, else: ""),
      block_rows: if(is_list(block_rows), do: block_rows, else: [])
    }
  end

  defp normalize_input(_input), do: normalize_input(%{})

  @spec normalize_layout(term()) :: :auto | :trips_in_rows | :stops_in_rows
  defp normalize_layout(:trips_in_rows), do: :trips_in_rows
  defp normalize_layout(:stops_in_rows), do: :stops_in_rows
  defp normalize_layout(:auto), do: :auto
  defp normalize_layout("trips_in_rows"), do: :trips_in_rows
  defp normalize_layout("stops_in_rows"), do: :stops_in_rows
  defp normalize_layout("auto"), do: :auto
  defp normalize_layout(_layout), do: :auto

  @spec normalize_header(term()) :: boolean()
  defp normalize_header(false), do: false
  defp normalize_header(nil), do: true
  defp normalize_header("false"), do: false
  defp normalize_header(_header?), do: true

  @spec normalize_mode(term()) :: :add | :replace
  defp normalize_mode(:replace), do: :replace
  defp normalize_mode("replace"), do: :replace
  defp normalize_mode(_mode), do: :add

  @spec normalize_overrides(term()) :: %{optional(non_neg_integer()) => String.t()}
  defp normalize_overrides(overrides) when is_map(overrides) do
    overrides
    |> Enum.map(fn {col, value} -> {to_column(col), to_override_value(value)} end)
    |> Enum.reject(fn {col, value} -> is_nil(col) or is_nil(value) end)
    |> Map.new()
  end

  defp normalize_overrides(_overrides), do: %{}

  @spec to_column(term()) :: non_neg_integer() | nil
  defp to_column(col) when is_integer(col) and col >= 0, do: col

  defp to_column(col) when is_binary(col) do
    case Integer.parse(String.trim(col)) do
      {num, ""} when num >= 0 -> num
      _parse -> nil
    end
  end

  defp to_column(_col), do: nil

  @spec to_override_value(term()) :: String.t() | nil
  defp to_override_value(value) when is_binary(value), do: value
  defp to_override_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_override_value(_value), do: nil

  @spec normalize_confirmations(term()) :: MapSet.t()
  defp normalize_confirmations(%MapSet{} = confirmations) do
    confirmations |> MapSet.to_list() |> normalize_confirmation_list()
  end

  defp normalize_confirmations(confirmations) when is_list(confirmations) do
    normalize_confirmation_list(confirmations)
  end

  defp normalize_confirmations(_confirmations), do: MapSet.new()

  @spec normalize_confirmation_list(list()) :: MapSet.t()
  defp normalize_confirmation_list(confirmations) do
    confirmations |> Enum.map(&to_column/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
  end

  # Row keys become integers and inner keys strings, so atom/string and
  # integer/numeric-string JSON round-trips share one fingerprint without
  # changing what RowResolver/Plan read (both tolerate either key form).
  @spec normalize_decisions(term()) :: map()
  defp normalize_decisions(decisions) when is_map(decisions) do
    decisions
    |> Enum.map(fn {row, decision} -> {row_number(row), normalize_decision(decision)} end)
    |> Enum.reject(fn {row, _decision} -> is_nil(row) end)
    |> Map.new()
  end

  defp normalize_decisions(_decisions), do: %{}

  @spec normalize_decision(term()) :: map()
  defp normalize_decision(decision) when is_map(decision) do
    decision
    |> Enum.map(fn {key, value} ->
      {to_string(key), normalize_decision_value(to_string(key), value)}
    end)
    |> Map.new()
  end

  defp normalize_decision(_decision), do: %{}

  @spec normalize_decision_value(String.t(), term()) :: term()
  defp normalize_decision_value("cells", cells) when is_map(cells) do
    cells
    |> Enum.map(fn {col, value} -> {to_column(col), value} end)
    |> Enum.reject(fn {col, _value} -> is_nil(col) end)
    |> Map.new()
  end

  defp normalize_decision_value(_key, value), do: value

  # --- Lenient map access (server scope uses atom keys; string keys tolerated) ---

  @spec get(map(), atom(), String.t()) :: term()
  defp get(map, atom, string) when is_map(map) do
    case Map.fetch(map, atom) do
      {:ok, value} -> value
      :error -> Map.get(map, string)
    end
  end

  defp get(_map, _atom, _string), do: nil

  @spec get_list(map(), atom(), String.t()) :: list()
  defp get_list(map, atom, string) do
    case get(map, atom, string) do
      list when is_list(list) -> list
      _value -> []
    end
  end

  @spec get_map(map(), atom(), String.t()) :: map()
  defp get_map(map, atom, string) do
    case get(map, atom, string) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end
end

defmodule GtfsPlanner.Gtfs.TimetableSource do
  @moduledoc """
  Reviewed approved-source projection for a copied timetable.

  Native paste parses, maps and saves one service calendar. It keeps no
  reviewed source-date intent, no staff-supplied provenance and no account of
  what the copied notes did and did not support, so `GtfsPlanner.Gtfs` (A34) has
  nothing honest to compare a feed against. This module owns that gap and
  nothing else: it turns pasted text plus a reviewed date policy and
  row/occurrence mapping into one immutable source value a later comparison can
  read.

  Pure: no Repo, clock or process state. It reads the pasted text only through
  `TimetablePaste.ClipboardParser` and the cell grammar only through
  `TimetablePaste.TimeToken`, so the native bounds and the native clock
  semantics are the same ones the Paste page already applies.

  ## Pipeline

    * `normalize(raw_params, native_scope)` parses the copied text, applies the
      inclusive interval and the reviewed date rules, resolves each pasted row
      against `native_scope`, and returns a `draft` with `accepted?: false` and
      its `digest`.
    * `accept(draft, review)` is the only path to `accepted?: true`. It requires
      an explicit server-observed confirmation and refuses while blocking
      unresolved items remain, so staff confirmation records reviewed
      configuration and never certifies agency approval (AC-3/AC-4).
    * `native_input(source, row_ids, calendar_id)` projects one calendar's
      selected rows into the native input map `TimetablePaste.review/2`
      consumes. Two calendar groups stay two projections; they are never merged
      into one service ID.
    * `assistant_payload(source)` returns the whole JSON-safe source, or
      `{:error, :too_large}` when it exceeds the same 65,536-byte ceiling the
      helper context enforces. A refusal here never narrows or discards the
      source: the native input and the manual comparison keep the full text.

  ## Shapes

  `raw_params` is a string-keyed or atom-keyed map (form params and JSON both
  accepted):

      %{
        "text" => raw clipboard text,          # required
        "notes" => staff notes,               # <= 2,000 characters
        "label" => staff label,               # <= 200 characters
        "revision" => staff revision or nil,  # <= 200 characters
        "first_date" => "2026-11-01",         # required, inclusive
        "last_date" => "2026-11-30",          # required, inclusive
        "layout" => "auto" | "trips_in_rows" | "stops_in_rows",
        "header?" => true | false,
        "date_policy" => "weekly" | "school",
        "weekdays" => [1..7],                 # ISO 1 = Monday, required for :weekly
        "school_dates" => ["2026-11-25"],    # required for :school
        "added_dates" => [...], "removed_dates" => [...],
        "mapping" => %{
          "direction_id" => 0 | 1,
          "pattern_id" => feed pattern id,
          "columns" => %{
            "0" => %{"stop_id" => ..., "stop_sequence" => 0,
                     "side" => "both" | "arrival" | "departure"}
          },
          "rows" => %{"1" => %{"feed_trip_id" => ..., "shift" => 0}}
        }
      }

  Column and row keys are 0-based and 1-based indexes that may arrive as
  integers or numeric strings; the pasted column position and the native row
  number are the same positions the Paste review uses, so one mapping serves
  both.

  `native_scope` is the read-only projection of the attached route and version
  that mapping resolves against; atom and string keys are both accepted:

      %{
        patterns: [%{id:, occurrences: [%{stop_id:, stop_sequence:}]}],
        trips: [%{id:, direction_id:, pattern_id:, first_departure_secs:, service_id:}]
      }

  A source row keeps its pasted position (`source_row_id`), the stable feed trip
  ID it was mapped to, the calendar it belongs to and one cell per mapped stop
  occurrence. `arrival`/`departure` are integer service-day seconds,
  `:not_served` for an explicit not-served marker and `:unknown` for a cell the
  grammar does not read; a side-specific column leaves the other event `nil`,
  which is "not supplied", never "zero". A `:unknown` or `:not_served` clock is
  never equal to a real clock, so it stays unresolved and blocks a clean
  comparison verdict instead of reading as a match (AC-12).

  ## Date rules

  Weekly rules expand the ISO weekdays over the inclusive interval, then union
  the explicit additions and subtract the explicit removals. A date in both is
  a validation error, not a silent preference. School rules use exactly the
  supplied school dates inside the interval; an omitted list stays
  `{:missing_school_dates, interval}` unresolved and can never be accepted,
  because a weekday guess would be an invented holiday (AC-4, FH-2, PM-2).
  Neither rule fetches, infers or certifies anything, and a date supplied
  outside the interval is excluded explicitly rather than dropped.

  Bounds mirror the native page and are asserted against it: 204,800 raw bytes,
  500 trip rows and 150 columns after orientation, at most 366 inclusive
  comparison dates. A larger source is refused here, not truncated.
  """

  alias GtfsPlanner.Gtfs.TimetablePaste.ClipboardParser
  alias GtfsPlanner.Gtfs.TimetablePaste.TimeToken

  @max_bytes 204_800
  @max_trip_rows 500
  @max_columns 150
  @max_dates 366
  @max_notes_length 2_000
  @max_label_length 200

  # Same ceiling the helper context enforces on the whole resource context, so a
  # source that cannot be attached is refused here for the same reason rather
  # than admitted and trimmed (AC-5, CR-4).
  @max_assistant_bytes 65_536

  @twelve_hour_shifts [0, 43_200, 86_400]
  @blocking [
    :missing_school_dates,
    :unreviewed_twelve_hour,
    :missing_mapping,
    :ambiguous_mapping,
    :unknown_feed_trip,
    :duplicate_feed_trip,
    :mapping_conflict
  ]

  @type interval :: {Date.t(), Date.t()}
  @type occurrence :: %{stop_id: String.t(), stop_sequence: non_neg_integer()}
  @type clock :: non_neg_integer() | :unknown | :not_served | nil

  @type row :: %{
          source_row_id: pos_integer(),
          pattern_id: String.t() | nil,
          direction_id: 0 | 1 | nil,
          feed_trip_id: String.t() | nil,
          service_id: String.t() | nil,
          dates: [Date.t()],
          cells: [%{occurrence: occurrence(), arrival: clock(), departure: clock()}]
        }

  @type source :: %{
          raw_text: String.t(),
          notes: String.t(),
          label: String.t(),
          revision: String.t() | nil,
          interval: interval(),
          layout: atom(),
          header?: boolean(),
          rows: [row()],
          mapping: map(),
          date_rules: map(),
          unresolved: [term()],
          exclusions: [term()],
          digest: String.t(),
          accepted?: boolean()
        }

  @doc """
  Normalizes pasted text and reviewed parameters into an unaccepted source.

  Returns `{:ok, draft}` with `accepted?: false`, or `{:error, field_errors}`
  where `field_errors` maps a parameter name to a list of messages. The raw text
  is preserved verbatim in `:raw_text` whatever the outcome, so a refused source
  never costs the editor their paste (AC-3).
  """
  @spec normalize(map(), map()) :: {:ok, source()} | {:error, map()}
  def normalize(raw_params, native_scope) when is_map(raw_params) and is_map(native_scope) do
    errors =
      %{}
      |> merge(text_errors(raw_params))
      |> merge(interval_errors(raw_params))
      |> merge(policy_errors(raw_params))
      |> merge(date_list_errors(raw_params))
      |> merge(mapping_errors(raw_params))

    if map_size(errors) == 0 do
      build(raw_params, native_scope)
    else
      {:error, errors}
    end
  end

  @doc """
  Returns the source with `accepted?: true` after an explicit confirmation.

  `review` is the server-observed confirmation map the host builds from a real
  form event: `%{confirmed?: true}`. Any other value is `{:error,
  :not_confirmed}`, so a model's proposal can never accept a source. Blocking
  unresolved items (an absent school list, an unmapped or ambiguous row, a
  duplicate feed trip, unreviewed 12-hour language) refuse with `{:error,
  {:unresolved, reasons}}`; every other unresolved note survives acceptance and
  keeps a later comparison from reading clean.
  """
  @spec accept(source(), map()) :: {:ok, source()} | {:error, term()}
  def accept(%{digest: _digest} = draft, %{confirmed?: true}) do
    case Enum.filter(draft.unresolved, &blocking_reason?/1) do
      [] -> {:ok, resign(draft, :accepted?, true)}
      reasons -> {:error, {:unresolved, reasons}}
    end
  end

  def accept(%{digest: _digest}, _review), do: {:error, :not_confirmed}

  @doc """
  Projects one calendar's selected rows into a native paste input.

  Returns `{:ok, %{service_id: service_id, input: input}}` where `input` is the
  native input map `TimetablePaste.review/2` consumes: the source's own text,
  layout and header flag, with a skip decision for every data row that was not
  selected. The projection never merges two calendars, so one call carries
  exactly one `service_id` and one confirmed save (AC-6, AC-8).
  """
  @spec native_input(source(), [pos_integer()], String.t()) ::
          {:ok, %{service_id: String.t(), input: map()}} | {:error, term()}
  def native_input(%{rows: rows} = source, row_ids, calendar_id)
      when is_list(row_ids) and is_binary(calendar_id) do
    case select_rows(rows, row_ids, calendar_id) do
      {:ok, selected} ->
        skipped = rows |> Enum.map(& &1.source_row_id) |> Enum.reject(&(&1 in selected))

        {:ok,
         %{
           service_id: calendar_id,
           input: %{
             text: source.raw_text,
             layout: source.layout,
             header?: source.header?,
             overrides: %{},
             confirmations: MapSet.new(),
             decisions: Map.new(skipped, &{&1, %{skip: true, cells: %{}, shift: 0}}),
             mode: :add,
             template_timing_id: nil,
             stamp: "",
             block_rows: []
           }
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def native_input(_source, _row_ids, _calendar_id), do: {:error, :invalid_selection}

  @doc """
  Returns the whole source as a JSON-safe map, or `{:error, :too_large}`.

  The payload is never a truncated or unlabeled table: it is the complete
  reviewed source, refused whole when it exceeds the helper ceiling. The caller
  keeps the native input and the manual comparison either way (AC-5).
  """
  @spec assistant_payload(source()) :: {:ok, map()} | {:error, :too_large}
  def assistant_payload(%{digest: _digest} = source) do
    payload = payload_of(source)

    if byte_size(Jason.encode!(payload)) > @max_assistant_bytes do
      {:error, :too_large}
    else
      {:ok, payload}
    end
  end

  @doc """
  Rebuilds the reviewed source from the payload `assistant_payload/1` wrote.

  The admitted snapshot is JSON-safe, so its interval and dates arrive as ISO
  strings and its clocks as integers, `"unknown"` or `"not_served"`. They are
  read back into exactly the values the host's own source holds, so a caller
  holding only the snapshot compares the source the editor reviewed rather than
  a retelling of it.

  Two things cannot survive the JSON round trip and are named rather than
  invented: the reviewed column `mapping`, which no comparison reads (the feed
  is narrowed by rows, not by pasted columns), and the typed `unresolved` and
  `exclusions` terms, which the payload carries as their `inspect/1` text. Those
  texts are carried through unchanged, so a rebuilt source keeps disclosing that
  something was not settled and can never read clean because the reason could
  not be re-read.

  Returns `{:error, :invalid_snapshot}` unless the payload declares an accepted
  source with a digest, an interval and rows.
  """
  @spec from_payload(map()) :: {:ok, source()} | {:error, :invalid_snapshot}
  def from_payload(payload) when is_map(payload) do
    with true <- Map.get(payload, "accepted?") == true,
         digest when is_binary(digest) <- Map.get(payload, "digest"),
         {:ok, interval} <- payload_interval(Map.get(payload, "interval")),
         {:ok, rows} <- payload_rows(Map.get(payload, "rows")) do
      {:ok,
       %{
         raw_text: Map.get(payload, "text") || "",
         notes: Map.get(payload, "notes") || "",
         label: Map.get(payload, "label") || "",
         revision: Map.get(payload, "revision"),
         interval: interval,
         layout: payload_layout(Map.get(payload, "layout")),
         header?: Map.get(payload, "header?") != false,
         rows: rows,
         mapping: %{},
         date_rules: Map.get(payload, "date_rules") || %{},
         unresolved: payload_terms(Map.get(payload, "unresolved")),
         exclusions: payload_terms(Map.get(payload, "exclusions")),
         digest: digest,
         accepted?: true
       }}
    else
      _other -> {:error, :invalid_snapshot}
    end
  end

  def from_payload(_payload), do: {:error, :invalid_snapshot}

  defp payload_interval(%{"first_date" => first, "last_date" => last}) do
    with {:ok, first_date} <- Date.from_iso8601(first),
         {:ok, last_date} <- Date.from_iso8601(last) do
      {:ok, {first_date, last_date}}
    else
      _other -> :error
    end
  end

  defp payload_interval(_interval), do: :error

  defp payload_layout("trips_in_rows"), do: :trips_in_rows
  defp payload_layout("stops_in_rows"), do: :stops_in_rows
  defp payload_layout(_layout), do: :auto

  # The payload's disclosures are `inspect/1` text rather than JSON values, so
  # they are carried as they were written: a disclosed reason stays disclosed.
  defp payload_terms(terms) when is_list(terms), do: terms
  defp payload_terms(_terms), do: []

  defp payload_rows(rows) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, built} ->
      case payload_source_row(row) do
        {:ok, source_row} -> {:cont, {:ok, built ++ [source_row]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp payload_rows(_rows), do: :error

  defp payload_source_row(row) when is_map(row) do
    with source_row_id when is_integer(source_row_id) <- Map.get(row, "source_row_id"),
         dates when is_list(dates) <- Map.get(row, "dates"),
         cells when is_list(cells) <- Map.get(row, "cells"),
         {:ok, dates} <- payload_dates(dates),
         {:ok, cells} <- payload_cells(cells) do
      {:ok,
       %{
         source_row_id: source_row_id,
         pattern_id: Map.get(row, "pattern_id"),
         direction_id: Map.get(row, "direction_id"),
         feed_trip_id: Map.get(row, "feed_trip_id"),
         service_id: Map.get(row, "service_id"),
         dates: dates,
         cells: cells
       }}
    else
      _other -> :error
    end
  end

  defp payload_source_row(_row), do: :error

  defp payload_dates(dates) do
    dates
    |> Enum.reduce_while({:ok, []}, fn date, {:ok, parsed} ->
      case Date.from_iso8601(date) do
        {:ok, date} -> {:cont, {:ok, parsed ++ [date]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
  end

  defp payload_cells(cells) do
    cells
    |> Enum.reduce_while({:ok, []}, fn cell, {:ok, parsed} ->
      case payload_cell(cell) do
        {:ok, source_cell} -> {:cont, {:ok, parsed ++ [source_cell]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp payload_cell(%{"stop_id" => stop_id, "stop_sequence" => stop_sequence} = cell)
       when is_binary(stop_id) and is_integer(stop_sequence) do
    with {:ok, arrival} <- payload_clock(Map.get(cell, "arrival")),
         {:ok, departure} <- payload_clock(Map.get(cell, "departure")) do
      {:ok,
       %{
         occurrence: %{stop_id: stop_id, stop_sequence: stop_sequence},
         arrival: arrival,
         departure: departure
       }}
    else
      _other -> :error
    end
  end

  defp payload_cell(_cell), do: :error

  defp payload_clock(value) when is_integer(value), do: {:ok, value}
  defp payload_clock(nil), do: {:ok, nil}
  defp payload_clock("unknown"), do: {:ok, :unknown}
  defp payload_clock("not_served"), do: {:ok, :not_served}
  defp payload_clock(_value), do: :error

  @doc "The number of inclusive dates a source interval compares."
  @spec date_count(interval()) :: pos_integer()
  def date_count({first, last}), do: Date.diff(last, first) + 1

  @doc """
  Whether an unresolved reason refuses `accept/2`.

  Exposed so a host can render one honest refusal copy instead of guessing
  which unresolved items block a comparison.
  """
  @spec blocking_reason?(term()) :: boolean()
  def blocking_reason?(reason) when is_atom(reason), do: reason in @blocking
  def blocking_reason?({reason, _rest}) when is_atom(reason), do: reason in @blocking
  def blocking_reason?({reason, _rest, _count}) when is_atom(reason), do: reason in @blocking
  def blocking_reason?(_reason), do: false

  # --- Normalization ---

  @spec build(map(), map()) :: {:ok, source()}
  defp build(raw_params, native_scope) do
    text = text_of(raw_params)
    header? = header?(raw_params)

    case ClipboardParser.parse(text, transpose: layout(raw_params) == :stops_in_rows) do
      {:ok, %{grid: grid}} ->
        case check_limits(grid, header?) do
          :ok -> assemble(text, raw_params, native_scope, grid, header?)
          {:error, field_errors} -> {:error, field_errors}
        end

      {:error, reason} ->
        {:error, %{"text" => [parse_message(reason)]}}
    end
  end

  @spec assemble(String.t(), map(), map(), [[String.t()]], boolean()) :: {:ok, source()}
  defp assemble(text, raw_params, native_scope, grid, header?) do
    mapping = mapping_of(raw_params)
    date_rules = date_rules_of(raw_params)
    interval = {first_date(raw_params), last_date(raw_params)}

    {dates, date_unresolved, exclusions} = expand_dates(date_rules, interval)

    data = if header? and grid != [], do: tl(grid), else: grid
    scope = native_scope_scope(native_scope)

    built =
      data
      |> Enum.with_index(1)
      |> Enum.map(fn {cells, row_id} ->
        build_row(Enum.with_index(cells), row_id, mapping, scope)
      end)

    rows = Enum.map(built, &elem(&1, 0))
    row_unresolved = Enum.flat_map(built, &elem(&1, 1))

    unresolved =
      date_unresolved ++
        row_unresolved ++
        column_unresolved(data, mapping) ++
        duplicate_unresolved(rows)

    source = %{
      raw_text: text,
      notes: text_or_empty(raw_params, "notes"),
      label: text_or_empty(raw_params, "label"),
      revision: optional_text(raw_params, "revision"),
      interval: interval,
      layout: layout(raw_params),
      header?: header?,
      rows: Enum.map(rows, &Map.put(&1, :dates, dates)),
      mapping: mapping,
      date_rules: date_rules,
      unresolved: Enum.sort_by(unresolved, &inspect/1),
      exclusions: Enum.sort_by(exclusions, &inspect/1),
      accepted?: false,
      digest: nil
    }

    {:ok, resign(source, :digest, digest_of(source))}
  end

  # One data row becomes one source row. Mapped columns contribute their
  # occurrence with the clock `TimeToken` resolved for that row, so rolling,
  # not-served and unrecognized positions are the native ones; the reviewed row
  # mapping names the feed trip, or exactly one scoped candidate does.
  #
  # Only a mapped column carries a clock, exactly like the native row review,
  # which resolves its stop columns and leaves the trip fields alone. An
  # unmapped cell stays unrecognized below: it never becomes a clock, and it
  # cannot roll the first mapped time either. A pasted trip number that reads
  # as a clock ("1201" is 12:01) therefore never moves a real departure by a
  # day.
  @spec build_row([{String.t(), non_neg_integer()}], pos_integer(), map(), map()) ::
          {row(), list()}
  defp build_row(cells, row_id, mapping, scope) do
    tokens =
      Enum.map(cells, fn {cell, col} ->
        if Map.has_key?(mapping_columns(mapping), col) do
          TimeToken.classify(cell)
        else
          {:error, :unrecognized}
        end
      end)

    shift = shift_of(mapping, row_id)
    resolved = resolve_tokens(tokens, shift)
    {mapped, cell_unresolved} = mapped_cells(Enum.zip(cells, resolved), mapping)

    feed_trip_id = feed_trip_of(mapping, row_id)
    first_known = first_known_clock(mapped)

    {trip, trip_unresolved} = resolve_trip(feed_trip_id, mapping, first_known, scope, row_id)

    # Only a rolled reading needs the editor's word: an unambiguous 06:00 is
    # exact, while a +12 h roll is a language decision native could not make
    # from the text alone (AC-12).
    twelve_hour =
      if shift == nil and Enum.any?(resolved, &match?(%{rolled: :h12}, &1)) do
        [{:unreviewed_twelve_hour, row_id}]
      else
        []
      end

    row = %{
      source_row_id: row_id,
      pattern_id: row_pattern_id(mapping, trip),
      direction_id: row_direction_id(mapping, trip),
      feed_trip_id: trip && feed_trip_id_of(trip),
      service_id: trip && service_id_of(trip),
      dates: [],
      cells: mapped
    }

    {row, cell_unresolved ++ trip_unresolved ++ twelve_hour}
  end

  # A row whose times cannot roll stays unresolved rather than invented: the
  # cells keep their own literal reading and the row's issues are reported by
  # the native review that re-reads the same text.
  @spec resolve_tokens(list(), term()) :: list()
  defp resolve_tokens(tokens, shift) do
    case TimeToken.resolve_row(tokens, shift || 0) do
      {:ok, resolved} -> resolved
      {:error, {:time_goes_backwards, _index}} -> Enum.map(tokens, &literal_cell/1)
    end
  end

  @spec literal_cell(term()) :: clock()
  defp literal_cell({:time, secs, _kind}), do: secs
  defp literal_cell(:not_served), do: :not_served
  defp literal_cell(_error), do: :unknown

  @spec mapped_cells(list(), map()) :: {[map()], list()}
  defp mapped_cells(resolved, mapping) do
    columns = mapping_columns(mapping)

    {cells, unresolved} =
      Enum.reduce(resolved, {[], []}, fn {{cell, col}, value}, {cells, unresolved} ->
        case Map.fetch(columns, col) do
          :error ->
            {cells, unresolved}

          {:ok, column} ->
            {[cell_entry(value, column) | cells],
             unsupported_unresolved(cell, col, value, unresolved)}
        end
      end)

    {merge_occurrences(Enum.reverse(cells)), Enum.uniq(unresolved)}
  end

  # A repeated stop contributes two entries that are one occurrence: the
  # arrival/departure column pair fills each event once, so arrival and
  # departure of one stop stay separate and independently comparable (AC-11).
  @spec cell_entry(term(), map()) :: map()
  defp cell_entry(value, column) do
    clock = clock_of(value)
    side = side_of(column[:side])

    %{
      occurrence: %{stop_id: column.stop_id, stop_sequence: column.stop_sequence},
      arrival: if(side in [:both, :arrival], do: clock),
      departure: if(side in [:both, :departure], do: clock)
    }
  end

  @spec merge_occurrences([map()]) :: [map()]
  defp merge_occurrences(entries) do
    Enum.reduce(entries, [], fn entry, merged ->
      existing = Enum.find_index(merged, &same_occurrence?(&1, entry))

      case existing do
        nil -> [entry | merged]
        index -> List.replace_at(merged, index, join_entry(Enum.at(merged, index), entry))
      end
    end)
    |> Enum.reverse()
  end

  @spec same_occurrence?(map(), map()) :: boolean()
  defp same_occurrence?(left, right), do: left.occurrence == right.occurrence

  @spec join_entry(map(), map()) :: map()
  defp join_entry(existing, entry) do
    %{
      occurrence: existing.occurrence,
      arrival: existing.arrival || entry.arrival,
      departure: existing.departure || entry.departure
    }
  end

  # An unrecognized mapped cell is `:unknown`, never a matchable number.
  @spec clock_of(term()) :: clock()
  defp clock_of(%{secs: secs}), do: secs
  defp clock_of(:not_served), do: :not_served
  defp clock_of(_error), do: :unknown

  # An unrecognized mapped cell is `:unknown`, never a matchable number, and
  # its own text is disclosed with its column so the editor can see what was
  # unsupported instead of losing it.
  @spec unsupported_unresolved(String.t(), non_neg_integer(), term(), list()) :: list()
  defp unsupported_unresolved(cell, col, value, unresolved) do
    if value == :unknown or match?({:error, :unrecognized}, value) do
      [{:unsupported_clock, col, String.trim(cell)} | unresolved]
    else
      unresolved
    end
  end

  @spec first_known_clock([map()]) :: map() | nil
  defp first_known_clock(cells) do
    Enum.find_value(cells, fn %{occurrence: occurrence, departure: departure, arrival: arrival} ->
      if is_integer(departure) or is_integer(arrival) do
        %{occurrence: occurrence, secs: departure || arrival}
      end
    end)
  end

  # An explicit feed trip must exist in scope. Without one, exactly one scoped
  # candidate of the reviewed direction and pattern whose first known departure
  # matches the mapped occurrence is required: zero is missing and several are
  # unresolved. Neither is silently collapsed to the first match.
  @spec resolve_trip(String.t() | nil, map(), map() | nil, map(), pos_integer()) ::
          {map() | nil, list()}
  defp resolve_trip(feed_trip_id, mapping, first_known, scope, row_id) do
    case feed_trip_id do
      nil ->
        resolve_candidate(mapping, first_known, scope, row_id)

      supplied ->
        resolve_supplied_trip(
          scope,
          supplied,
          mapping_direction(mapping),
          mapping_pattern(mapping),
          row_id
        )
    end
  end

  @spec resolve_candidate(map(), map() | nil, map(), pos_integer()) ::
          {map() | nil, list()}
  defp resolve_candidate(mapping, first_known, scope, row_id) do
    direction_id = mapping_direction(mapping)
    pattern_id = mapping_pattern(mapping)

    candidates =
      Enum.filter(scope.trips, fn trip ->
        matches_direction?(trip, direction_id) and matches_pattern?(trip, pattern_id) and
          serves_occurrence?(trip, first_known, scope)
      end)

    case candidates do
      [trip] -> {trip, []}
      [] -> {nil, [{:missing_mapping, row_id}]}
      many -> {nil, [{:ambiguous_mapping, row_id, length(many)}]}
    end
  end

  @spec resolve_supplied_trip(map(), String.t(), 0 | 1 | nil, String.t() | nil, pos_integer()) ::
          {map() | nil, list()}
  defp resolve_supplied_trip(scope, supplied, direction_id, pattern_id, row_id) do
    case Enum.find(scope.trips, &(feed_trip_id_of(&1) == supplied)) do
      nil ->
        {nil, [{:unknown_feed_trip, row_id, supplied}]}

      trip ->
        if conflict?(trip, direction_id, pattern_id),
          do: {nil, [{:mapping_conflict, row_id, supplied}]},
          else: {trip, []}
    end
  end

  @spec conflict?(map(), 0 | 1 | nil, String.t() | nil) :: boolean()
  defp conflict?(trip, direction_id, pattern_id) do
    (not is_nil(direction_id) and direction_id_of(trip) not in [nil, direction_id]) or
      (not is_nil(pattern_id) and pattern_id_of(trip) not in [nil, pattern_id])
  end

  @spec matches_direction?(map(), 0 | 1 | nil) :: boolean()
  defp matches_direction?(_trip, nil), do: true
  defp matches_direction?(trip, direction_id), do: direction_id_of(trip) == direction_id

  @spec matches_pattern?(map(), String.t() | nil) :: boolean()
  defp matches_pattern?(_trip, nil), do: true
  defp matches_pattern?(trip, pattern_id), do: pattern_id_of(trip) == pattern_id

  # The row's first known departure is the trip's first departure at the same
  # occurrence: an identical clock at a different stop, or a trip declaring no
  # first departure at all, identifies nothing.
  @spec serves_occurrence?(map(), map() | nil, map()) :: boolean()
  defp serves_occurrence?(_trip, nil, _scope), do: false

  defp serves_occurrence?(trip, first_known, scope) do
    departure = value_of(trip, :first_departure_secs, "first_departure_secs")

    departure == first_known.secs and
      scope
      |> pattern_occurrences(pattern_id_of(trip))
      |> Enum.any?(&occurrence_in?(&1, first_known.occurrence))
  end

  @spec occurrence_in?(map(), occurrence()) :: boolean()
  defp occurrence_in?(occurrence, %{stop_id: stop_id, stop_sequence: sequence}) do
    stop_id_of(occurrence) == stop_id and sequence_of(occurrence) == sequence
  end

  # Cells outside the reviewed mapping are neither erased nor read as clocks:
  # anything that is neither blank nor an explicit not-served marker is
  # disclosed as unsupported (FH-2).
  @spec column_unresolved([[String.t()]], map()) :: [term()]
  defp column_unresolved(data, mapping) do
    mapped = MapSet.new(Map.keys(mapping_columns(mapping)))

    for {cells, row} <- Enum.with_index(data, 1),
        {cell, col} <- Enum.with_index(cells),
        not MapSet.member?(mapped, col),
        String.trim(cell) != "",
        TimeToken.classify(cell) == {:error, :unrecognized},
        uniq: true,
        do: {:unsupported_column, row, col}
  end

  # Two rows mapped to one feed trip would compare the same trip twice on the
  # same date. That is never deduplicated away (AC-10/AC-12).
  @spec duplicate_unresolved([row()]) :: [term()]
  defp duplicate_unresolved(rows) do
    rows
    |> Enum.map(& &1.feed_trip_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_trip_id, count} -> count > 1 end)
    |> Enum.map(fn {trip_id, _count} -> {:duplicate_feed_trip, trip_id} end)
  end

  # --- Date rules ---

  # Weekly rules are an explicit weekday list plus exact additions and
  # removals; school rules use exactly the supplied dates inside the interval.
  # An absent school list is unresolved, never replaced by a weekday guess.
  @spec expand_dates(map(), interval()) :: {[Date.t()], list(), list()}
  defp expand_dates(%{policy: :school, school_dates: []}, interval) do
    {[], [{:missing_school_dates, interval}], []}
  end

  defp expand_dates(rules, {first, last}) do
    added = inside(rules.added_dates, {first, last})
    removed = inside(rules.removed_dates, {first, last})
    base = base_dates(rules, {first, last})

    # Sorted by year, month and day rather than by struct term: Erlang compares
    # structs field by field, which would order a multi-month interval by day
    # of month and interleave months.
    dates =
      (base ++ added)
      |> Enum.uniq()
      |> Enum.reject(&(&1 in removed))
      |> Enum.sort_by(&{&1.year, &1.month, &1.day})

    {dates, [], outside_exclusions(rules, {first, last})}
  end

  @spec base_dates(map(), interval()) :: [Date.t()]
  defp base_dates(%{policy: :school} = rules, interval), do: inside(rules.school_dates, interval)

  defp base_dates(%{policy: :weekly} = rules, {first, last}) do
    weekdays = MapSet.new(rules.weekdays)

    first
    |> Date.range(last)
    |> Enum.filter(&MapSet.member?(weekdays, Date.day_of_week(&1)))
  end

  @spec inside([Date.t()], interval()) :: [Date.t()]
  defp inside(dates, {first, last}) do
    dates
    |> Enum.filter(&(Date.compare(&1, first) != :lt and Date.compare(&1, last) != :gt))
    |> Enum.uniq()
  end

  @spec outside_exclusions(map(), interval()) :: [term()]
  defp outside_exclusions(rules, {first, last}) do
    Enum.map(
      rules.added_dates -- inside(rules.added_dates, {first, last}),
      &{:addition_outside_interval, &1}
    ) ++
      Enum.map(
        rules.removed_dates -- inside(rules.removed_dates, {first, last}),
        &{:removal_outside_interval, &1}
      )
  end

  # --- Errors ---

  @spec text_errors(map()) :: map()
  defp text_errors(raw_params) do
    %{}
    |> merge(raw_text_error(raw_params))
    |> merge(bounded_text(raw_params, "notes", @max_notes_length))
    |> merge(bounded_text(raw_params, "label", @max_label_length))
    |> merge(bounded_text(raw_params, "revision", @max_label_length))
  end

  # The raw-byte ceiling is checked here rather than by the parser alone, so an
  # oversized paste is refused with the field name the host form owns.
  @spec raw_text_error(map()) :: map()
  defp raw_text_error(raw_params) do
    case value_of(raw_params, :text, "text") do
      text when is_binary(text) and byte_size(text) > @max_bytes ->
        %{"text" => ["must stay within #{@max_bytes} bytes, got #{byte_size(text)}"]}

      _text ->
        %{}
    end
  end

  @spec bounded_text(map(), String.t(), pos_integer()) :: map()
  defp bounded_text(raw_params, field, max) do
    case value_of(raw_params, String.to_existing_atom(field), field) do
      nil -> %{}
      "" -> %{}
      value when is_binary(value) -> length_error(value, field, max)
      _other -> %{field => ["must be text"]}
    end
  end

  @spec length_error(String.t(), String.t(), pos_integer()) :: map()
  defp length_error(value, field, max) do
    if String.length(value) > max do
      %{field => ["must be at most #{max} characters"]}
    else
      %{}
    end
  end

  @spec interval_errors(map()) :: map()
  defp interval_errors(raw_params) do
    case date_field(raw_params, "first_date") do
      {:ok, first} -> last_date_errors(raw_params, first)
      {:error, message} -> %{"first_date" => [message]}
    end
  end

  @spec last_date_errors(map(), Date.t()) :: map()
  defp last_date_errors(raw_params, first) do
    case date_field(raw_params, "last_date") do
      {:ok, last} ->
        cond do
          Date.compare(first, last) == :gt ->
            %{"last_date" => ["must not precede first_date"]}

          date_count({first, last}) > @max_dates ->
            %{"last_date" => ["must stay within #{@max_dates} inclusive dates"]}

          true ->
            %{}
        end

      {:error, message} ->
        %{"last_date" => [message]}
    end
  end

  @spec date_field(map(), String.t()) :: {:ok, Date.t()} | {:error, String.t()}
  defp date_field(raw_params, field) do
    case value_of(raw_params, String.to_existing_atom(field), field) do
      nil ->
        {:error, "is required as an ISO date"}

      value when is_binary(value) ->
        case Date.from_iso8601(String.trim(value)) do
          {:ok, date} -> {:ok, date}
          {:error, _reason} -> {:error, "is not an ISO date"}
        end

      %Date{} = date ->
        {:ok, date}

      _other ->
        {:error, "is not an ISO date"}
    end
  end

  @spec policy_errors(map()) :: map()
  defp policy_errors(raw_params) do
    case value_of(raw_params, :date_policy, "date_policy") do
      nil -> weekday_errors(raw_params)
      policy when policy in [:weekly, "weekly"] -> weekday_errors(raw_params)
      policy when policy in [:school, "school"] -> school_errors(raw_params)
      _other -> %{"date_policy" => ["must be weekly or school"]}
    end
  end

  @spec weekday_errors(map()) :: map()
  defp weekday_errors(raw_params) do
    case value_of(raw_params, :weekdays, "weekdays") do
      value when value in [nil, []] ->
        %{"weekdays" => ["must list at least one ISO weekday (1 = Monday)"]}

      value ->
        case weekday_list(value) do
          [] -> %{"weekdays" => ["must list at least one ISO weekday (1 = Monday)"]}
          :error -> %{"weekdays" => ["must be ISO weekdays 1 to 7"]}
          _days -> %{}
        end
    end
  end

  @spec weekday_list(term()) :: [1..7] | :error
  defp weekday_list(values) when is_list(values) do
    days =
      Enum.map(values, fn
        day when is_integer(day) and day in 1..7 -> day
        day when is_binary(day) -> parse_integer(day)
        _other -> nil
      end)

    if Enum.all?(days, &(&1 in 1..7)), do: Enum.uniq(days), else: :error
  end

  defp weekday_list(_values), do: :error

  # A school policy with no supplied dates is not a form error: the draft is
  # kept and carries `{:missing_school_dates, interval}` unresolved, which
  # refuses `accept/2`. Refusing early would hide the rest of the reviewed
  # source the editor still has.
  @spec school_errors(map()) :: map()
  defp school_errors(_raw_params), do: %{}

  @spec date_list_errors(map()) :: map()
  defp date_list_errors(raw_params) do
    ["added_dates", "removed_dates", "school_dates"]
    |> Enum.flat_map(fn field ->
      case dates_from(value_of(raw_params, String.to_existing_atom(field), field)) do
        {:ok, _dates} -> []
        {:error, message} -> [{field, message}]
      end
    end)
    |> Map.new()
  end

  @spec dates_from(term()) :: {:ok, [Date.t()]} | {:error, String.t()}
  defp dates_from(nil), do: {:ok, []}
  defp dates_from(""), do: {:ok, []}

  defp dates_from(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      value, {:ok, acc} ->
        case parse_date(value) do
          {:ok, date} -> {:cont, {:ok, [date | acc]}}
          :error -> {:halt, {:error, "must be ISO dates"}}
        end

      _value, _acc ->
        {:halt, {:error, "must be ISO dates"}}
    end)
  end

  defp dates_from(_values), do: {:error, "must be ISO dates"}

  @spec parse_date(term()) :: {:ok, Date.t()} | :error
  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  @spec mapping_errors(map()) :: map()
  defp mapping_errors(raw_params) do
    mapping =
      case value_of(raw_params, :mapping, "mapping") do
        value when is_map(value) -> value
        _other -> %{}
      end

    column_errors(mapping) |> merge(conflicting_date_errors(raw_params))
  end

  @spec column_errors(map()) :: map()
  defp column_errors(mapping) do
    case value_of(mapping, :columns, "columns") do
      nil -> %{}
      columns when is_map(columns) -> column_entry_errors(columns)
      _other -> %{"mapping.columns" => ["must map column indexes to stop occurrences"]}
    end
  end

  @spec column_entry_errors(map()) :: map()
  defp column_entry_errors(columns) do
    Enum.flat_map(columns, fn {column, entry} ->
      if mapped_column(column, entry) == :error do
        [{"mapping.columns.#{column}", "must name a stop_id and a 0-based stop_sequence"}]
      else
        []
      end
    end)
    |> Map.new()
  end

  @spec mapped_column(term(), term()) :: {:ok, {non_neg_integer(), occurrence()}} | :error
  defp mapped_column(column, entry) do
    with {:ok, index} <- column_index(column),
         {:ok, occurrence} <- column_occurrence(entry) do
      {:ok, {index, occurrence}}
    else
      _other -> :error
    end
  end

  @spec column_occurrence(term()) :: {:ok, occurrence()} | :error
  defp column_occurrence(entry) do
    with entry when is_map(entry) <- to_map(entry),
         {:ok, stop_id} <- string_value(value_of(entry, :stop_id, "stop_id")),
         {:ok, sequence} <- non_negative_integer(value_of(entry, :stop_sequence, "stop_sequence")),
         {:ok, side} <- side_value(value_of(entry, :side, "side")) do
      {:ok, %{stop_id: stop_id, stop_sequence: sequence, side: side}}
    else
      _other -> :error
    end
  end

  @spec column_index(term()) :: {:ok, non_neg_integer()} | :error
  defp column_index(column) when is_integer(column) and column >= 0, do: {:ok, column}

  defp column_index(column) when is_binary(column) do
    case parse_integer(column) do
      index when is_integer(index) and index >= 0 -> {:ok, index}
      _other -> :error
    end
  end

  defp column_index(_column), do: :error

  @spec string_value(term()) :: {:ok, String.t()} | :error
  defp string_value(value) when is_binary(value) and value != "", do: {:ok, value}
  defp string_value(_value), do: :error

  @spec non_negative_integer(term()) :: {:ok, non_neg_integer()} | :error
  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp non_negative_integer(value) when is_binary(value) do
    case parse_integer(value) do
      integer when is_integer(integer) and integer >= 0 -> {:ok, integer}
      _other -> :error
    end
  end

  defp non_negative_integer(_value), do: :error

  @spec parse_integer(String.t()) :: integer() | nil
  defp parse_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  @spec side_value(term()) :: {:ok, :both | :arrival | :departure} | :error
  defp side_value(nil), do: {:ok, :both}
  defp side_value(:both), do: {:ok, :both}
  defp side_value(:arrival), do: {:ok, :arrival}
  defp side_value(:departure), do: {:ok, :departure}
  defp side_value("both"), do: {:ok, :both}
  defp side_value("arrival"), do: {:ok, :arrival}
  defp side_value("departure"), do: {:ok, :departure}
  defp side_value(_value), do: :error

  @spec side_of(term()) :: :both | :arrival | :departure
  defp side_of(nil), do: :both
  defp side_of(:both), do: :both
  defp side_of(:arrival), do: :arrival
  defp side_of(:departure), do: :departure
  defp side_of("both"), do: :both
  defp side_of("arrival"), do: :arrival
  defp side_of("departure"), do: :departure
  defp side_of(_other), do: :both

  @spec conflicting_date_errors(map()) :: map()
  defp conflicting_date_errors(raw_params) do
    case {dates_from(value_of(raw_params, :added_dates, "added_dates")),
          dates_from(value_of(raw_params, :removed_dates, "removed_dates"))} do
      {{:ok, added}, {:ok, removed}} ->
        if Enum.uniq(added) -- Enum.uniq(removed) == Enum.uniq(added) do
          %{}
        else
          %{"removed_dates" => ["must not repeat a date in added_dates"]}
        end

      _other ->
        %{}
    end
  end

  @spec merge(map(), map()) :: map()
  defp merge(left, right) do
    Enum.reduce(right, left, fn {field, messages}, acc ->
      Map.update(acc, field, messages, &(&1 ++ messages))
    end)
  end

  @spec check_limits([[String.t()]], boolean()) :: :ok | {:error, map()}
  defp check_limits(grid, header?) do
    width = grid |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)
    trip_rows = if header?, do: max(length(grid) - 1, 0), else: length(grid)

    cond do
      trip_rows > @max_trip_rows ->
        {:error, %{"text" => ["must stay within #{@max_trip_rows} trip rows"]}}

      width > @max_columns ->
        {:error, %{"text" => ["must stay within #{@max_columns} columns"]}}

      true ->
        :ok
    end
  end

  @spec parse_message(term()) :: String.t()
  defp parse_message({:too_large, bytes}),
    do: "must stay within #{@max_bytes} bytes, got #{bytes}"

  defp parse_message(:empty), do: "must contain at least one row"

  defp parse_message({:too_many_rows, count}),
    do: "must stay within #{@max_trip_rows} trip rows, got #{count}"

  defp parse_message({:too_many_columns, count}),
    do: "must stay within #{@max_columns} columns, got #{count}"

  defp parse_message({:unclosed_quote, line}), do: "has an unclosed quote on line #{line}"
  defp parse_message(_reason), do: "could not be parsed"

  # --- Parameter readers ---

  @spec text_of(map()) :: String.t()
  defp text_of(raw_params) do
    case value_of(raw_params, :text, "text") do
      text when is_binary(text) -> text
      _other -> ""
    end
  end

  @spec text_or_empty(map(), String.t()) :: String.t()
  defp text_or_empty(raw_params, field) do
    case value_of(raw_params, String.to_existing_atom(field), field) do
      text when is_binary(text) -> text
      _other -> ""
    end
  end

  @spec optional_text(map(), String.t()) :: String.t() | nil
  defp optional_text(raw_params, field) do
    case text_or_empty(raw_params, field) do
      "" -> nil
      text -> text
    end
  end

  @spec first_date(map()) :: Date.t()
  defp first_date(raw_params), do: date_field!(raw_params, "first_date")

  @spec last_date(map()) :: Date.t()
  defp last_date(raw_params), do: date_field!(raw_params, "last_date")

  @spec date_field!(map(), String.t()) :: Date.t()
  defp date_field!(raw_params, field) do
    case date_field(raw_params, field) do
      {:ok, date} -> date
      {:error, _message} -> raise ArgumentError, "normalize/2 requires a valid #{field}"
    end
  end

  @spec layout(map()) :: atom()
  defp layout(raw_params) do
    case value_of(raw_params, :layout, "layout") do
      :trips_in_rows -> :trips_in_rows
      :stops_in_rows -> :stops_in_rows
      "trips_in_rows" -> :trips_in_rows
      "stops_in_rows" -> :stops_in_rows
      _auto -> :auto
    end
  end

  @spec header?(map()) :: boolean()
  defp header?(raw_params) do
    case value_of(raw_params, :header?, "header?") do
      false -> false
      "false" -> false
      _true -> true
    end
  end

  @spec mapping_of(map()) :: map()
  defp mapping_of(raw_params) do
    mapping =
      case value_of(raw_params, :mapping, "mapping") do
        value when is_map(value) -> value
        _other -> %{}
      end

    %{
      direction_id: mapping_direction(mapping),
      pattern_id: mapping_pattern(mapping),
      columns: mapped_columns(mapping),
      rows: mapping_rows(mapping)
    }
  end

  @spec mapped_columns(map()) :: %{non_neg_integer() => occurrence()}
  defp mapped_columns(mapping) do
    case value_of(mapping, :columns, "columns") do
      columns when is_map(columns) ->
        columns
        |> Enum.flat_map(&mapped_column_entry/1)
        |> Map.new()

      _other ->
        %{}
    end
  end

  @spec mapped_column_entry({term(), term()}) :: [{non_neg_integer(), occurrence()}]
  defp mapped_column_entry({column, entry}) do
    case mapped_column(column, entry) do
      {:ok, mapped} -> [mapped]
      :error -> []
    end
  end

  @spec mapping_rows(map()) :: map()
  defp mapping_rows(mapping) do
    case value_of(mapping, :rows, "rows") do
      rows when is_map(rows) ->
        rows
        |> Enum.flat_map(&mapped_row_entry/1)
        |> Map.new()

      _other ->
        %{}
    end
  end

  @spec mapped_row_entry({term(), term()}) :: [{pos_integer(), map()}]
  defp mapped_row_entry({row, entry}) do
    case row_index(row) do
      {:ok, index} -> [{index, to_map(entry)}]
      :error -> []
    end
  end

  @spec row_index(term()) :: {:ok, pos_integer()} | :error
  defp row_index(row) when is_integer(row) and row >= 1, do: {:ok, row}

  defp row_index(row) when is_binary(row) do
    case parse_integer(row) do
      index when is_integer(index) and index >= 1 -> {:ok, index}
      _other -> :error
    end
  end

  defp row_index(_row), do: :error

  @spec mapping_direction(map()) :: 0 | 1 | nil
  defp mapping_direction(mapping) do
    case value_of(mapping, :direction_id, "direction_id") do
      0 -> 0
      "0" -> 0
      1 -> 1
      "1" -> 1
      _other -> nil
    end
  end

  @spec mapping_pattern(map()) :: String.t() | nil
  defp mapping_pattern(mapping) do
    case value_of(mapping, :pattern_id, "pattern_id") do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  @spec mapping_columns(map()) :: %{non_neg_integer() => occurrence()}
  defp mapping_columns(mapping), do: Map.get(mapping, :columns, %{})

  @spec feed_trip_of(map(), pos_integer()) :: String.t() | nil
  defp feed_trip_of(mapping, row_id) do
    with entry when is_map(entry) <- row_entry(mapping, row_id),
         {:ok, value} <- string_value(value_of(entry, :feed_trip_id, "feed_trip_id")) do
      value
    else
      _other -> nil
    end
  end

  # A reviewed native twelve-hour decision (`:h12`/`:h24`, i.e. +12 h or
  # +24 h). Absent, ambiguous language stays unresolved instead of being rolled
  # into exact seconds here (AC-12).
  @spec shift_of(map(), pos_integer()) :: non_neg_integer() | nil
  defp shift_of(mapping, row_id) do
    with entry when is_map(entry) <- row_entry(mapping, row_id),
         value when value in @twelve_hour_shifts <- value_of(entry, :shift, "shift") do
      value
    else
      _other -> nil
    end
  end

  @spec row_entry(map(), pos_integer()) :: map() | nil
  defp row_entry(mapping, row_id), do: Map.get(mapping, :rows, %{}) |> Map.get(row_id)

  @spec date_rules_of(map()) :: map()
  defp date_rules_of(raw_params) do
    %{
      policy: policy_of(raw_params),
      weekdays: weekday_list!(value_of(raw_params, :weekdays, "weekdays")),
      school_dates: sorted_dates!(value_of(raw_params, :school_dates, "school_dates")),
      added_dates: sorted_dates!(value_of(raw_params, :added_dates, "added_dates")),
      removed_dates: sorted_dates!(value_of(raw_params, :removed_dates, "removed_dates"))
    }
  end

  @spec policy_of(map()) :: :weekly | :school
  defp policy_of(raw_params) do
    case value_of(raw_params, :date_policy, "date_policy") do
      policy when policy in [:school, "school"] -> :school
      _weekly -> :weekly
    end
  end

  @spec weekday_list!(term()) :: [1..7]
  defp weekday_list!(values) do
    case weekday_list(values) do
      days when is_list(days) -> Enum.sort(days)
      _error -> []
    end
  end

  @spec sorted_dates!(term()) :: [Date.t()]
  defp sorted_dates!(values) do
    case dates_from(values) do
      {:ok, dates} -> dates |> Enum.uniq() |> Enum.sort_by(&{&1.year, &1.month, &1.day})
      {:error, _message} -> []
    end
  end

  # --- Scope readers ---

  @spec native_scope_scope(map()) :: map()
  defp native_scope_scope(native_scope) do
    %{
      patterns: list_of(value_of(native_scope, :patterns, "patterns")),
      trips: list_of(value_of(native_scope, :trips, "trips"))
    }
  end

  @spec pattern_occurrences(map(), String.t() | nil) :: [map()]
  defp pattern_occurrences(scope, pattern_id) do
    scope.patterns
    |> Enum.filter(&(value_of(&1, :id, "id") == pattern_id))
    |> Enum.flat_map(fn pattern ->
      pattern
      |> value_of(:occurrences, "occurrences")
      |> list_of()
      |> Enum.map(&to_map/1)
    end)
  end

  @spec stop_id_of(map()) :: term()
  defp stop_id_of(occurrence), do: value_of(occurrence, :stop_id, "stop_id")

  @spec sequence_of(map()) :: term()
  defp sequence_of(occurrence) do
    case value_of(occurrence, :stop_sequence, "stop_sequence") do
      sequence when is_integer(sequence) -> sequence
      _other -> value_of(occurrence, :position, "position")
    end
  end

  @spec feed_trip_id_of(map()) :: term()
  defp feed_trip_id_of(trip) do
    case value_of(trip, :id, "id") do
      nil -> value_of(trip, :feed_trip_id, "feed_trip_id")
      id -> id
    end
  end

  @spec pattern_id_of(map() | nil) :: String.t() | nil
  defp pattern_id_of(nil), do: nil

  defp pattern_id_of(map) do
    case value_of(map, :pattern_id, "pattern_id") do
      nil -> value_of(map, :route_pattern_id, "route_pattern_id")
      id -> id
    end
  end

  @spec direction_id_of(map() | nil) :: 0 | 1 | nil
  defp direction_id_of(nil), do: nil

  defp direction_id_of(map), do: value_of(map, :direction_id, "direction_id")

  @spec service_id_of(map() | nil) :: String.t() | nil
  defp service_id_of(nil), do: nil
  defp service_id_of(map), do: value_of(map, :service_id, "service_id")

  @spec row_pattern_id(map(), map() | nil) :: String.t() | nil
  defp row_pattern_id(mapping, trip), do: mapping_pattern(mapping) || pattern_id_of(trip)

  @spec row_direction_id(map(), map() | nil) :: 0 | 1 | nil
  defp row_direction_id(mapping, trip), do: mapping_direction(mapping) || direction_id_of(trip)

  # --- Selection and payload ---

  @spec select_rows([row()], [pos_integer()], String.t()) ::
          {:ok, [pos_integer()]} | {:error, term()}
  defp select_rows(rows, row_ids, calendar_id) do
    requested = Enum.uniq(row_ids)
    by_id = Map.new(rows, &{&1.source_row_id, &1})
    found = Enum.filter(requested, &Map.has_key?(by_id, &1))

    cond do
      requested == [] ->
        {:error, :empty_selection}

      found != Enum.sort(requested) ->
        {:error, :unknown_row}

      Enum.any?(found, &(Map.get(by_id, &1).service_id != calendar_id)) ->
        {:error, :mixed_calendars}

      true ->
        {:ok, Enum.sort(found)}
    end
  end

  @spec payload_of(source()) :: map()
  defp payload_of(source) do
    {first, last} = source.interval

    %{
      "label" => source.label,
      "revision" => source.revision,
      "notes" => source.notes,
      "accepted?" => source.accepted?,
      "digest" => source.digest,
      # The copied table travels with the reviewed facts, because the native
      # batch is projected from this same text: a helper that could not see the
      # cells would prepare a draft the editor never reviewed. The digest
      # already binds the text, and the whole context stays under the same
      # 65,536-byte ceiling, so a paste too large to attach is refused whole
      # rather than trimmed.
      "text" => source.raw_text,
      "layout" => to_string(source.layout),
      "header?" => source.header?,
      "interval" => %{
        "first_date" => Date.to_iso8601(first),
        "last_date" => Date.to_iso8601(last),
        "date_count" => date_count(source.interval)
      },
      "date_rules" => %{
        "policy" => to_string(source.date_rules.policy),
        "weekdays" => source.date_rules.weekdays,
        "school_dates" => iso_dates(source.date_rules.school_dates),
        "added_dates" => iso_dates(source.date_rules.added_dates),
        "removed_dates" => iso_dates(source.date_rules.removed_dates)
      },
      "rows" => Enum.map(source.rows, &payload_row/1),
      "unresolved" => Enum.map(source.unresolved, &inspect/1),
      "exclusions" => Enum.map(source.exclusions, &inspect/1)
    }
  end

  @spec payload_row(row()) :: map()
  defp payload_row(row) do
    %{
      "source_row_id" => row.source_row_id,
      "feed_trip_id" => row.feed_trip_id,
      "service_id" => row.service_id,
      "pattern_id" => row.pattern_id,
      "direction_id" => row.direction_id,
      "dates" => iso_dates(row.dates),
      "cells" =>
        Enum.map(row.cells, fn cell ->
          %{
            "stop_id" => cell.occurrence.stop_id,
            "stop_sequence" => cell.occurrence.stop_sequence,
            "arrival" => clock_payload(cell.arrival),
            "departure" => clock_payload(cell.departure)
          }
        end)
    }
  end

  @spec clock_payload(clock()) :: integer() | String.t() | nil
  defp clock_payload(nil), do: nil
  defp clock_payload(secs) when is_integer(secs), do: secs
  defp clock_payload(other), do: to_string(other)

  @spec iso_dates([Date.t()]) :: [String.t()]
  defp iso_dates(dates), do: Enum.map(dates, &Date.to_iso8601/1)

  # --- Digest ---

  # Every comparison-affecting reviewed input is hashed: the copied text (as a
  # digest, never raw), the staff provenance, the inclusive interval, the exact
  # date rules, the resolved rows and both the unresolved and excluded
  # disclosures. Two sources differ exactly when something that could change a
  # comparison differs, so raw text alone can never stand in for reviewed
  # configuration (INV-1).
  @spec digest_of(source()) :: String.t()
  defp digest_of(source) do
    {first, last} = source.interval

    term =
      {text_digest(source.raw_text), source.notes, source.label, source.revision,
       iso_dates([first, last]), source.date_rules.policy, source.date_rules.weekdays,
       iso_dates(source.date_rules.school_dates), iso_dates(source.date_rules.added_dates),
       iso_dates(source.date_rules.removed_dates), Enum.map(source.rows, &digest_row/1),
       source.unresolved, source.exclusions, source.accepted?}

    :erlang.term_to_binary(term, [:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec digest_row(row()) :: term()
  defp digest_row(row) do
    {row.source_row_id, row.feed_trip_id, row.service_id, row.pattern_id, row.direction_id,
     iso_dates(row.dates),
     Enum.map(row.cells, fn cell ->
       {cell.occurrence.stop_id, cell.occurrence.stop_sequence, cell.arrival, cell.departure}
     end)}
  end

  @spec text_digest(String.t()) :: String.t()
  defp text_digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  @spec resign(source(), atom(), term()) :: source()
  defp resign(source, key, value) do
    updated = Map.put(source, key, value)
    Map.put(updated, :digest, digest_of(updated))
  end

  # --- Lenient access ---

  @spec value_of(term(), atom(), String.t()) :: term()
  defp value_of(map, atom, string) when is_map(map) do
    case Map.fetch(map, atom) do
      {:ok, value} -> value
      :error -> Map.get(map, string)
    end
  end

  defp value_of(_map, _atom, _string), do: nil

  @spec to_map(term()) :: map()
  defp to_map(value) when is_map(value), do: value
  defp to_map(_value), do: %{}

  @spec list_of(term()) :: list()
  defp list_of(value) when is_list(value), do: value
  defp list_of(_value), do: []
end

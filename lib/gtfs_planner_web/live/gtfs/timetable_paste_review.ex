defmodule GtfsPlannerWeb.Gtfs.TimetablePasteReview do
  @moduledoc """
  Pure row view models for the paste review matrix (step 26).

  `build/3` turns a `TimetablePaste.review/2` review and its
  `Schedules.load_paste_scope/5` scope into display columns and one stream
  item per plan change. The LiveView streams the items with `reset: true`
  and keeps the totals in separate assigns because streams are neither
  enumerable nor countable. `timing_note/4` resolves the timing-note popover
  for a `pattern_id|name` ref, and `warned?/1` drives the Warnings filter
  step 25 deferred.

  Display follows the prototype's review stage: Pasted view shows one column
  per pasted stop (the union of pasted occurrences across the changes), All
  stops shows every occurrence of the scoped pattern plus the extra stops of
  rows on another pattern. Times render `HH:MM`; estimates are floored to
  the minute, `+1 day` marks `>= 24:00`, `arr HH:MM` marks a differing
  arrival, `was HH:MM` marks a changed cell, and removals strike their old
  times. Pure: no Repo, clock or process state.
  """

  @type column :: %{key: term(), name: String.t(), pasted?: boolean()}

  @type cell :: %{
          key: term(),
          state: :time | :not_served | :blank,
          secs: integer() | nil,
          arr_secs: integer() | nil,
          pasted?: boolean(),
          was_secs: integer() | nil,
          struck?: boolean()
        }

  @type row_view :: %{
          id: String.t(),
          op: atom(),
          row_no: pos_integer() | nil,
          trip: String.t() | nil,
          block: String.t() | nil,
          badge: {String.t(), String.t()},
          pattern_note: String.t() | nil,
          timing: %{ref: String.t(), name: String.t(), new?: boolean()} | nil,
          cells: [cell()],
          details: [%{text: String.t(), warning?: boolean()}],
          warned?: boolean()
        }

  @doc """
  Builds the matrix view model for a review, scope and paste input.

  Returns `%{columns:, rows:, total:, shown:, warnings:}` where `rows` are
  stream items (each with a string `:id`) already filtered by
  `input.filter`, `total` counts every plan change and `shown` counts the
  filtered rows. A review without a plan (column issues, empty paste)
  builds empty columns and rows.
  """
  @spec build(map() | nil, map() | nil, map()) :: %{
          columns: [column()],
          rows: [row_view()],
          total: non_neg_integer(),
          shown: non_neg_integer(),
          warnings: non_neg_integer()
        }
  def build(review, scope, input)

  def build(%{plan: %{changes: changes}} = _review, scope, input)
      when is_list(changes) and is_map(scope) do
    spine = build_spine(scope)
    enriched = Enum.map(changes, &enrich_change(&1, scope, spine))
    filter = review_filter(input)
    stops_view = review_stops_view(input)
    columns = display_columns(enriched, spine, stops_view)

    rows =
      enriched
      |> Enum.filter(&matches_filter?(&1.change, filter))
      |> Enum.with_index()
      |> Enum.map(fn {en, index} -> row_view(en, columns, index) end)

    %{
      columns: columns,
      rows: rows,
      total: length(changes),
      shown: length(rows),
      warnings: Enum.count(changes, &warned?/1)
    }
  end

  def build(_review, _scope, _input) do
    %{columns: [], rows: [], total: 0, shown: 0, warnings: 0}
  end

  @doc """
  Whether a plan change carries review warnings (the Warnings filter).
  """
  @spec warned?(map()) :: boolean()
  def warned?(%{warnings: warnings}) when is_list(warnings), do: warnings != []
  def warned?(_change), do: false

  @doc """
  Formats absolute seconds as `HH:MM`, floored to the minute. Hours are not
  capped at 24, so after-midnight times read `24:03`.
  """
  @spec format_clock(integer()) :: String.t()
  def format_clock(secs) when is_integer(secs) do
    total_minutes = Integer.floor_div(secs, 60)
    hours = Integer.floor_div(total_minutes, 60)
    minutes = Integer.mod(total_minutes, 60)
    "#{pad2(hours)}:#{pad2(minutes)}"
  end

  defp pad2(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  Resolves the timing note for a `pattern_id|name` ref, or `nil` when the
  ref names no timing of the scope. The map carries the name, pattern,
  duration, whether it is new, the template it was estimated from, the
  estimated stop names and the count of trips using it here.
  """
  @spec timing_note(map() | nil, map() | nil, map(), String.t() | nil) :: map() | nil
  def timing_note(review, scope, input, ref)

  def timing_note(
        %{plan: %{changes: changes, new_timings: new_timings}} = _review,
        scope,
        input,
        ref
      )
      when is_list(changes) and is_binary(ref) and is_map(scope) do
    with [pattern_id, name] <- String.split(ref, "|", parts: 2),
         pattern when is_map(pattern) <- find_pattern(scope, pattern_id),
         timings when is_list(timings) <- fetch(pattern, :timings, []),
         {timing_kind, timing_rows} <- find_timing(timings, new_timings, pattern_id, name) do
      users = timing_users(changes, pattern_id, timing_kind)
      pasted = users_pasted_positions(users)

      estimated =
        pattern
        |> sorted_occurrences()
        |> Enum.reject(&MapSet.member?(pasted, fetch(&1, :position)))
        |> Enum.map(&stop_name(scope, fetch(&1, :stop_id)))

      %{
        name: timing_display_name(timing_kind, name),
        short_name: name,
        pattern_name: pattern_display_name(pattern),
        duration: timing_minutes(timing_rows),
        new?: match?({:new, _name}, timing_kind),
        template_name: new_template_name(timings, input, timing_kind),
        estimated: estimated,
        users: length(users)
      }
    else
      _unresolvable -> nil
    end
  end

  def timing_note(_review, _scope, _input, _ref), do: nil

  # --- Columns ---

  defp build_spine(scope) do
    case find_pattern(scope, fetch(scope, :pattern_id)) do
      nil ->
        []

      pattern ->
        pattern
        |> sorted_occurrences()
        |> Enum.with_index()
        |> Enum.map(fn {occurrence, index} ->
          stop_id = fetch(occurrence, :stop_id)

          %{
            index: index,
            id: fetch(occurrence, :id),
            stop_id: stop_id,
            name: stop_name(scope, stop_id)
          }
        end)
    end
  end

  defp display_columns(enriched, spine, :all) do
    pasted = pasted_column_keys(enriched)
    extras = collect_extras(enriched)

    spine_columns =
      Enum.map(spine, fn entry ->
        %{
          key: {:spine, entry.index},
          name: entry.name,
          pasted?: MapSet.member?(pasted, {:spine, entry.index})
        }
      end)

    extra_columns =
      Enum.map(extras, fn {_stop_id, name, key} ->
        %{key: key, name: name, pasted?: MapSet.member?(pasted, key)}
      end)

    spine_columns ++ extra_columns
  end

  defp display_columns(enriched, spine, _pasted) do
    pasted = pasted_column_keys(enriched)
    extras = collect_extras(enriched)
    names = column_names(enriched, spine, extras)

    spine
    |> Enum.filter(&MapSet.member?(pasted, {:spine, &1.index}))
    |> Enum.map(&%{key: {:spine, &1.index}, name: &1.name, pasted?: true})
    |> Kernel.++(
      extras
      |> Enum.filter(fn {_stop_id, _name, key} -> MapSet.member?(pasted, key) end)
      |> Enum.map(fn {_stop_id, _name, key} ->
        %{key: key, name: Map.get(names, key, ""), pasted?: true}
      end)
    )
  end

  defp column_names(_enriched, spine, extras) do
    spine_names = Map.new(spine, &{{:spine, &1.index}, &1.name})
    extra_names = Map.new(extras, fn {_stop_id, name, key} -> {key, name} end)
    Map.merge(spine_names, extra_names)
  end

  # Every column key with at least one pasted occurrence across the changes.
  defp pasted_column_keys(enriched) do
    enriched
    |> Enum.flat_map(fn en ->
      if is_nil(en.pairs) do
        []
      else
        en.occurrences
        |> Enum.with_index()
        |> Enum.flat_map(fn {occurrence, q} ->
          if MapSet.member?(en.pasted, fetch(occurrence, :position)) do
            [column_key(en.keys, en.occurrences, q)]
          else
            []
          end
        end)
      end
    end)
    |> MapSet.new()
  end

  defp column_key(keys, occurrences, q) do
    case Enum.at(keys, q) do
      nil -> {:extra, fetch(Enum.at(occurrences, q), :stop_id)}
      index -> {:spine, index}
    end
  end

  # Extra stops of rows on another pattern, in first-appearance order.
  defp collect_extras(enriched) do
    enriched
    |> Enum.flat_map(fn en ->
      if is_nil(en.pairs) do
        []
      else
        en.occurrences
        |> Enum.with_index()
        |> Enum.flat_map(fn {occurrence, q} ->
          if is_nil(Enum.at(en.keys, q)) do
            stop_id = fetch(occurrence, :stop_id)
            [{stop_id, stop_name(en.scope, stop_id), {:extra, stop_id}}]
          else
            []
          end
        end)
      end
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  # --- Change enrichment ---

  defp enrich_change(change, scope, spine) when is_map(change) do
    row = fetch(change, :row)
    trip = fetch(change, :trip)
    op = fetch(change, :op, :needs_decision)

    {pattern_id, occurrences} = change_pattern(change, row, trip, scope)
    keys = occurrence_keys(occurrences, spine)
    pasted = pasted_positions(row)
    {pairs, old_pairs} = change_pairs(scope, pattern_id, change, row, trip, occurrences)

    %{
      change: change,
      scope: scope,
      op: op,
      row: row,
      trip: trip,
      pattern_id: pattern_id,
      occurrences: occurrences,
      keys: keys,
      pasted: pasted,
      pairs: pairs,
      old_pairs: old_pairs,
      timing: change_timing(change, pattern_id, scope),
      pattern_note: pattern_note(scope, pattern_id)
    }
  end

  # The row's pattern for row changes, the trip's pattern for removals.
  defp change_pattern(change, row, trip, scope) do
    cond do
      is_map(row) and not is_nil(fetch(row, :pattern_id)) ->
        pattern_id = fetch(row, :pattern_id)
        {pattern_id, pattern_occurrences(scope, pattern_id)}

      is_map(trip) ->
        case trip_pattern_id(scope, trip) do
          nil -> {nil, []}
          pattern_id -> {pattern_id, pattern_occurrences(scope, pattern_id)}
        end

      true ->
        {fetch(change, :pattern_id), []}
    end
  end

  defp pattern_occurrences(scope, pattern_id) when not is_nil(pattern_id) do
    case find_pattern(scope, pattern_id) do
      nil -> []
      pattern -> sorted_occurrences(pattern)
    end
  end

  defp pattern_occurrences(_scope, _pattern_id), do: []

  defp trip_pattern_id(scope, trip) do
    natural = fetch(trip, :route_pattern_id)

    (fetch(scope, :patterns) || [])
    |> Enum.find_value(fn pattern ->
      if fetch(pattern, :route_pattern_id) == natural, do: fetch(pattern, :id)
    end)
  end

  # Per-occurrence spine indexes for the change's occurrences, like the
  # prototype's `keyFor`: stop-identity matching in order, `nil` past the
  # end of the scoped pattern.
  defp occurrence_keys(occurrences, spine) do
    {keys, _last} =
      Enum.map_reduce(occurrences, -1, fn occurrence, last ->
        stop_id = fetch(occurrence, :stop_id)

        found =
          spine
          |> Enum.with_index()
          |> Enum.find_index(fn {entry, _} -> entry.index > last and entry.stop_id == stop_id end)

        case found do
          nil -> {nil, last}
          index -> {index, index}
        end
      end)

    keys
  end

  defp pasted_positions(row) when is_map(row) do
    row |> fetch(:pasted, []) |> List.wrap() |> MapSet.new()
  end

  defp pasted_positions(_row), do: MapSet.new()

  # Absolute {arrival, departure} pairs for the change's occurrences, plus
  # the old pairs behind a retimed change. Removals strike the old pairs.
  defp change_pairs(scope, pattern_id, change, row, trip, occurrences) do
    start = change_start(change, row, trip)

    cond do
      is_map(row) and is_list(fetch(row, :timing_rows)) and is_integer(start) ->
        pairs = absolute_pairs(fetch(row, :timing_rows), start)
        {pairs, old_pairs_for(scope, pattern_id, change, trip, occurrences)}

      fetch(change, :op) == :remove and is_map(trip) and is_integer(start) ->
        case scoped_timing_rows(scope, pattern_id, trip, occurrences) do
          nil -> {nil, nil}
          old_rows -> {absolute_pairs(old_rows, start), nil}
        end

      true ->
        {nil, nil}
    end
  end

  defp change_start(change, row, trip) do
    cond do
      is_map(row) and is_integer(fetch(row, :start_secs)) -> fetch(row, :start_secs)
      fetch(change, :op) == :remove and is_map(trip) -> fetch(trip, :start_secs)
      true -> nil
    end
  end

  defp absolute_pairs(rows, start) when is_list(rows) do
    Enum.map(rows, fn timing_row ->
      arrival = start + fetch(timing_row, :arrival_offset, 0)
      departure = start + fetch(timing_row, :departure_offset, 0)
      {arrival, departure}
    end)
  end

  defp old_pairs_for(scope, pattern_id, change, trip, occurrences) do
    if fetch(change, :op) == :change and :times in List.wrap(fetch(change, :diffs, [])) and
         is_map(trip) and is_integer(fetch(trip, :start_secs)) do
      case scoped_timing_rows(scope, pattern_id, trip, occurrences) do
        nil -> nil
        old_rows -> absolute_pairs(old_rows, fetch(trip, :start_secs))
      end
    else
      nil
    end
  end

  defp scoped_timing_rows(scope, pattern_id, trip, occurrences) do
    timing_id = fetch(trip, :timed_pattern_id) || fetch(trip, :timing_id)

    if is_nil(timing_id) or is_nil(pattern_id) or occurrences == [] do
      nil
    else
      with pattern when is_map(pattern) <- find_pattern(scope, pattern_id),
           timing when is_map(timing) <-
             Enum.find(List.wrap(fetch(pattern, :timings)), &(fetch(&1, :id) == timing_id)),
           rows when is_list(rows) and rows != [] <- fetch(timing, :rows) do
        if length(rows) == length(occurrences), do: rows, else: nil
      else
        _missing -> nil
      end
    end
  end

  defp change_timing(change, pattern_id, scope) do
    case fetch(change, :timing) do
      {:existing, id} when not is_nil(pattern_id) ->
        case find_pattern(scope, pattern_id) do
          nil ->
            nil

          pattern ->
            case Enum.find(List.wrap(fetch(pattern, :timings)), &(fetch(&1, :id) == id)) do
              nil ->
                nil

              timing ->
                %{
                  ref: "#{pattern_id}|#{fetch(timing, :name)}",
                  name: fetch(timing, :name) || "Timing",
                  new?: false
                }
            end
        end

      {:new, name} when is_binary(name) and not is_nil(pattern_id) ->
        %{ref: "#{pattern_id}|#{name}", name: name, new?: true}

      _timing ->
        nil
    end
  end

  defp pattern_note(scope, pattern_id) do
    if is_nil(pattern_id) or pattern_id == fetch(scope, :pattern_id) do
      nil
    else
      case find_pattern(scope, pattern_id) do
        nil -> nil
        pattern -> pattern_display_name(pattern)
      end
    end
  end

  # --- Row view ---

  defp row_view(en, columns, index) do
    change = en.change

    %{
      id: dom_id(change, en, index),
      op: en.op,
      row_no: row_number(change, en),
      trip: trip_label(change, en),
      block: block_label(change),
      badge: op_badge(en.op),
      pattern_note: removal_pattern_note(en) || en.pattern_note,
      timing: removal_timing(en) || en.timing,
      cells: Enum.map(columns, &cell_for(en, &1)),
      details: change_details(en),
      warned?: warned?(change)
    }
  end

  defp dom_id(change, en, index) do
    if en.op == :remove do
      trip_id = en.trip && fetch(en.trip, :trip_id)
      "paste-remove-#{trip_id || "row-#{index}"}"
    else
      "paste-row-#{row_number(change, en) || "pos-#{index}"}"
    end
  end

  defp row_number(change, en) do
    row = fetch(change, :row)

    cond do
      is_map(row) and is_integer(fetch(row, :row)) -> fetch(row, :row)
      is_integer(fetch(change, :row_no)) -> fetch(change, :row_no)
      en.op == :remove -> nil
      true -> nil
    end
  end

  defp trip_label(change, en) do
    short = fetch(change, :trip_short_name)

    cond do
      is_binary(short) and short != "" ->
        short

      is_map(en.trip) and is_binary(fetch(en.trip, :trip_short_name)) ->
        fetch(en.trip, :trip_short_name)

      true ->
        nil
    end
  end

  defp block_label(change) do
    case fetch(change, :block_id) do
      block when is_binary(block) and block != "" -> block
      _block -> nil
    end
  end

  defp op_badge(:add), do: {"Add", "active"}
  defp op_badge(:change), do: {"Change", "info"}
  defp op_badge(:remove), do: {"Remove", "error"}
  defp op_badge(:unchanged), do: {"No change", "draft"}
  defp op_badge(:duplicate), do: {"Already exists", "draft"}
  defp op_badge(:skipped), do: {"Skipped", "draft"}
  defp op_badge(_op), do: {"Needs decision", "warning"}

  # Removals resolve their pattern and timing from the trip; the generic
  # enrichment cannot see the trip's pattern UUID, so both are fixed here.
  defp removal_pattern_note(%{op: :remove, scope: scope, trip: trip} = en) when is_map(trip) do
    scoped_id = fetch(scope, :pattern_id)

    case trip_pattern_id(scope, trip) do
      nil -> en.pattern_note
      pattern_id when pattern_id == scoped_id -> nil
      pattern_id -> pattern_display_name(find_pattern(scope, pattern_id))
    end
  end

  defp removal_pattern_note(en), do: en.pattern_note

  defp removal_timing(%{op: :remove, scope: scope, trip: trip} = en) when is_map(trip) do
    case trip_pattern_id(scope, trip) do
      nil ->
        en.timing

      pattern_id ->
        timing_id = fetch(trip, :timed_pattern_id) || fetch(trip, :timing_id)

        case find_pattern(scope, pattern_id) do
          nil ->
            en.timing

          pattern ->
            case Enum.find(List.wrap(fetch(pattern, :timings)), &(fetch(&1, :id) == timing_id)) do
              nil ->
                en.timing

              timing ->
                %{
                  ref: "#{pattern_id}|#{fetch(timing, :name)}",
                  name: fetch(timing, :name) || "Timing",
                  new?: false
                }
            end
        end
    end
  end

  defp removal_timing(en), do: en.timing

  defp cell_for(en, column) do
    base = %{
      key: column.key,
      state: :blank,
      secs: nil,
      arr_secs: nil,
      pasted?: false,
      was_secs: nil,
      struck?: false
    }

    with q when is_integer(q) <- column_occurrence(en, column),
         pairs when is_list(pairs) <- en.pairs,
         {arrival, departure} when is_integer(arrival) and is_integer(departure) <-
           Enum.at(pairs, q, nil) do
      occurrence = Enum.at(en.occurrences, q)

      %{
        base
        | state: :time,
          secs: departure,
          arr_secs: if(arrival == departure, do: nil, else: arrival),
          pasted?: pasted_cell?(en, occurrence),
          was_secs: was_secs(en, q, departure),
          struck?: en.op == :remove
      }
    else
      _missing ->
        if is_nil(en.pairs), do: base, else: %{base | state: :not_served}
    end
  end

  defp column_occurrence(en, %{key: {:spine, index}}) do
    en.keys |> Enum.with_index() |> Enum.find_value(fn {key, q} -> if key == index, do: q end)
  end

  defp column_occurrence(en, %{key: {:extra, stop_id}}) do
    en.occurrences
    |> Enum.with_index()
    |> Enum.find_value(fn {occurrence, q} -> if fetch(occurrence, :stop_id) == stop_id, do: q end)
  end

  defp pasted_cell?(en, occurrence) when is_map(occurrence) do
    MapSet.member?(en.pasted, fetch(occurrence, :position))
  end

  defp pasted_cell?(_en, _occurrence), do: false

  defp was_secs(en, q, departure) do
    case en.old_pairs do
      pairs when is_list(pairs) ->
        case Enum.at(pairs, q) do
          {_arrival, old} when is_integer(old) and old != departure -> old
          _same -> nil
        end

      _no_old ->
        nil
    end
  end

  # --- Details ---

  defp change_details(en) do
    change = en.change
    row = fetch(change, :row)
    trip = fetch(change, :trip)

    notes =
      case en.op do
        :add -> add_notes(row)
        :change -> change_notes(change, trip)
        :unchanged -> unchanged_notes(change, trip)
        :duplicate -> duplicate_notes(change, en)
        :skipped -> [note("Not applied.")]
        :remove -> remove_notes(trip)
        _needs_decision -> []
      end

    notes ++ Enum.map(List.wrap(fetch(change, :warnings, [])), &warning_note(change, &1))
  end

  defp add_notes(row) when is_map(row) do
    []
    |> maybe_note(
      fetch(row, :how) == :auto,
      "Skips stops, so it goes on the one pattern that fits."
    )
    |> maybe_note(shifted?(row), "Read as #{format_clock(fetch(row, :start_secs))}.")
    |> maybe_note(
      truthy?(fetch(row, :rolled?)),
      "Runs past midnight; later times count from the same service day."
    )
  end

  defp add_notes(_row), do: []

  defp change_notes(change, trip) do
    trip_id = trip && fetch(trip, :trip_id)
    diffs = diff_sentence(List.wrap(fetch(change, :diffs, [])))

    [note("Keeps trip ID #{trip_id}. Changes #{diffs}.")]
  end

  defp unchanged_notes(change, trip) do
    label =
      cond do
        is_binary(fetch(change, :trip_short_name)) -> fetch(change, :trip_short_name)
        is_map(trip) and is_binary(fetch(trip, :trip_id)) -> fetch(trip, :trip_id)
        true -> "this trip"
      end

    [note("Matches trip #{label}.")]
  end

  defp duplicate_notes(change, en) do
    row = fetch(change, :row)

    existing =
      cond do
        is_map(en.trip) and is_binary(fetch(en.trip, :trip_short_name)) ->
          fetch(en.trip, :trip_short_name)

        is_map(en.trip) and is_binary(fetch(en.trip, :trip_id)) ->
          fetch(en.trip, :trip_id)

        true ->
          "an existing trip"
      end

    start =
      if is_map(row) and is_integer(fetch(row, :start_secs)),
        do: " at #{format_clock(fetch(row, :start_secs))}",
        else: ""

    [note("Skipped: trip #{existing} already leaves#{start}.")]
  end

  defp remove_notes(trip) when is_map(trip) do
    trip_id = fetch(trip, :trip_id)
    transfer_count = trip |> fetch(:transfer_ids, []) |> List.wrap() |> length()

    [note("Not in your paste. Trip ID #{trip_id}.")]
    |> maybe_note(
      transfer_count > 0,
      "#{plural(transfer_count, "transfer")} that name this trip are removed with it."
    )
  end

  defp remove_notes(_trip), do: [note("Not in your paste.")]

  defp warning_note(_change, :custom_replaced),
    do: note("Its custom stop times are replaced.", true)

  defp warning_note(_change, :in_seat_retimed),
    do: note("Riders stay on board past this trip. Check the connection on Blocks.", true)

  defp warning_note(change, :duplicate_trip_number),
    do:
      note(
        "Trip number #{fetch(change, :trip_short_name)} is already used on this calendar.",
        true
      )

  defp warning_note(_change, :custom_headsign_moved),
    do: note("The kept headsign stays with this trip on its new timing.", true)

  defp warning_note(change, :block_overlap),
    do:
      note(
        "Block #{fetch(change, :block_id)} also runs another trip at this time. Check Blocks after applying.",
        true
      )

  defp warning_note(_change, _warning), do: note("Needs a check before applying.", true)

  defp diff_sentence([]), do: "nothing"
  defp diff_sentence(diffs), do: diffs |> Enum.map(&diff_label/1) |> Enum.join(" and ")

  defp diff_label(:times), do: "times"
  defp diff_label(:trip_short_name), do: "trip number"
  defp diff_label(:block_id), do: "block"
  defp diff_label(:trip_headsign), do: "headsign"
  defp diff_label(other), do: to_string(other)

  defp note(text, warning? \\ false), do: %{text: text, warning?: warning?}

  defp maybe_note(notes, true, text), do: notes ++ [note(text)]
  defp maybe_note(notes, _false, _text), do: notes

  defp shifted?(row) do
    case fetch(row, :shift, 0) do
      shift when is_integer(shift) -> shift != 0
      _shift -> false
    end
  end

  defp plural(1, one), do: "1 #{one}"
  defp plural(count, one), do: "#{count} #{one}s"

  # --- Filters ---

  defp matches_filter?(_change, "all"), do: true
  defp matches_filter?(change, "warnings"), do: warned?(change)
  defp matches_filter?(%{op: op}, filter) when is_atom(op), do: Atom.to_string(op) == filter

  defp matches_filter?(change, filter) when is_map(change),
    do: to_string(fetch(change, :op)) == filter

  defp review_filter(%{filter: filter}) when is_binary(filter), do: filter
  defp review_filter(%{"filter" => filter}) when is_binary(filter), do: filter
  defp review_filter(_input), do: "all"

  defp review_stops_view(%{stops_view: :all}), do: :all
  defp review_stops_view(%{stops_view: "all"}), do: :all
  defp review_stops_view(_input), do: :pasted

  # --- Timing note ---

  defp find_timing(timings, new_timings, pattern_id, name) do
    case Enum.find(timings, &(fetch(&1, :name) == name)) do
      timing when is_map(timing) ->
        {{:existing, fetch(timing, :id)}, List.wrap(fetch(timing, :rows))}

      nil ->
        find_new_timing(new_timings, pattern_id, name)
    end
  end

  defp find_new_timing(new_timings, pattern_id, name) do
    match =
      Enum.find(List.wrap(new_timings), fn timing ->
        fetch(timing, :pattern_id) == pattern_id and fetch(timing, :name) == name
      end)

    case match do
      nil -> nil
      timing -> {{:new, fetch(timing, :name)}, List.wrap(fetch(timing, :timing_rows))}
    end
  end

  defp timing_users(changes, pattern_id, {:existing, id}) do
    Enum.filter(changes, fn change ->
      row = fetch(change, :row)

      is_map(row) and fetch(row, :pattern_id) == pattern_id and
        fetch(change, :timing) == {:existing, id} and
        fetch(change, :op) in [:add, :change]
    end)
  end

  defp timing_users(changes, pattern_id, {:new, name}) do
    Enum.filter(changes, fn change ->
      row = fetch(change, :row)

      is_map(row) and fetch(row, :pattern_id) == pattern_id and
        fetch(change, :timing) == {:new, name} and
        fetch(change, :op) in [:add, :change]
    end)
  end

  defp users_pasted_positions(users) do
    users
    |> Enum.flat_map(fn change -> change |> fetch(:row) |> fetch(:pasted, []) |> List.wrap() end)
    |> MapSet.new()
  end

  defp timing_display_name({:existing, _id}, name), do: name
  defp timing_display_name({:new, _name}, name), do: name

  # The input timing when it belongs to the pattern, else the most-used
  # timing — the same fallback `RowResolver` reviews with.
  defp new_template_name(timings, input, {:new, _name}) do
    wanted = (is_map(input) && fetch(input, :template_timing_id)) || nil

    chosen =
      if is_binary(wanted) do
        Enum.find(timings, &(fetch(&1, :id) == wanted))
      end

    chosen =
      chosen || timings |> Enum.sort_by(&(fetch(&1, :trip_count, 0) || 0), :desc) |> List.first()

    chosen && fetch(chosen, :name)
  end

  defp new_template_name(_timings, _input, _existing), do: nil

  defp timing_minutes([]), do: 0

  defp timing_minutes(rows) do
    departures =
      rows |> Enum.map(&fetch(&1, :departure_offset)) |> Enum.filter(&is_integer/1)

    case departures do
      [] -> 0
      departures -> div(Enum.max(departures) - Enum.min(departures), 60)
    end
  end

  # --- Scope helpers ---

  defp find_pattern(scope, pattern_id) when is_map(scope) and not is_nil(pattern_id) do
    Enum.find(List.wrap(fetch(scope, :patterns)), &(fetch(&1, :id) == pattern_id))
  end

  defp find_pattern(_scope, _pattern_id), do: nil

  defp sorted_occurrences(pattern) do
    pattern
    |> fetch(:occurrences, [])
    |> List.wrap()
    |> Enum.sort_by(&{fetch(&1, :position) || 0, fetch(&1, :id) || ""})
  end

  defp pattern_display_name(nil), do: "this pattern"

  defp pattern_display_name(pattern) when is_map(pattern),
    do: fetch(pattern, :name) || "this pattern"

  defp stop_name(scope, stop_id) when is_map(scope) do
    case fetch(fetch(scope, :stops, %{}), stop_id) do
      stop when is_map(stop) -> fetch(stop, :stop_name) || ""
      _missing -> ""
    end
  end

  defp stop_name(_scope, _stop_id), do: ""

  defp fetch(map, key, default \\ nil)

  defp fetch(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp fetch(map, key, default) when is_map(map) and is_binary(key),
    do: Map.get(map, key, default)

  defp fetch(_map, _key, default), do: default

  defp truthy?(true), do: true
  defp truthy?(_value), do: false
end

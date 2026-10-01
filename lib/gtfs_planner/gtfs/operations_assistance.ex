defmodule GtfsPlanner.Gtfs.OperationsAssistance do
  @moduledoc """
  The allowlisted projections the operations helper reads, copied from native
  domain results so a helper session can explain a day without holding a handle
  on host assigns.

  This step owns `block_day/2`: the block-day projection of one
  `GtfsPlanner.Gtfs.Blocking.load_day/3` result. The day is loaded by its host
  (`BlocksLive` through the catalog read adapter) and this module reads no
  repository, starts no solver and writes no row. The run-day, completed-plan,
  snapshot-admission and paging functions arrive in the steps that own them.

  `block_day/2` returns `{:ok, payload}` with a string-key JSON map, or
  `{:error, :unavailable}`. It refuses a day the load could not select - a day
  type of `nil`, or a value that is not the shape `load_day/3` returns - and a
  selection naming a block or trip the day does not hold, because a stale or
  forged selection has no evidence to answer about and must not fall back to
  another scope.

  The payload carries `schema_version`, `section`, `day_key`, `day_ref`,
  `source_digest`, `selection`, `scope`, `totals`, `completeness`, `exclusions`,
  `issues`, `constraints`, `entities` and a `plan` that is `nil` until the plan
  step owns it. Every value is JSON-safe and allowlisted: a finding's own code,
  severity, the technical trips and blocks it names and its numeric or
  enumerated `detail` values - never a whole struct, a foreign map or operator
  text. `C-3` is why the copy is rebuilt field by field rather than taken from
  the loaded day.

  The copy is fresh: nothing in it aliases the loaded day's maps, so the payload
  stays frozen after the host reloads and no host-private handle is followed
  (`INV-1`). Issue codes, severities, unknown-travel statuses and notices are
  copied exactly as the checks produced them; no clock, distance or feasibility
  value is recomputed here, and an unknown drive keeps its `unknown` status
  rather than becoming a measured second.

  References are deterministic opaque strings built from the section, the day key
  and the technical identity - one `day_ref`, one per block, one per trip, one per
  finding - so a payload of the same day names the same rows and two day types of
  the same version never resolve each other's rows. `source_digest` is the
  SHA-256 of the projected content with the digest and ref fields left out. It is
  this day's own fingerprint, not the native plan fingerprint, which the plan
  step keeps separately.

  Selection is frozen as the exact refs the host displayed, and scope is
  `whole_day` when nothing is selected or `explicit_subset` when it is. A subset
  is disclosed rather than truncated: it names its blocks and the trips outside a
  block it also carries, and every block and trip left out is listed as an
  `outside_scope` exclusion beside its own totals. A frequency-based or
  unplottable trip is always an explicit exclusion, because no check sequences
  it into a block.
  """

  @schema_version 1
  @section "blocks"

  # Refs are namespaced by the package and the section, so a session holding both
  # a block and a run payload cannot resolve one section's ref in the other.
  @ref_namespace "ai08"

  # Severity ranks, for the paging step's sort. The copy keeps the day's own
  # finding order, which `load_day/3` already fixes.
  @severity_rank %{error: 0, warning: 1, notice: 2}

  # The `detail` values each native finding carries, allowlisted per code. A key
  # that is not listed is dropped rather than serialized: the checks are the only
  # source of these keys, and an unlisted one is new data no privacy decision has
  # been made about. `block_attributes_conflict` nests rows and is projected by
  # its own row allowlist.
  @detail_keys %{
    block_attributes_conflict: [:rows],
    cannot_reach: [:drive_secs, :gap_secs],
    fleet_shortfall: [:garage_id, :vehicle_type_id, :needed, :listed, :at_secs],
    frequency_trip: [:headway_secs],
    in_seat_stale: [:reason],
    in_seat_unconfirmed: [:reason],
    interlining_not_allowed: [:from_route_id, :to_route_id, :handoff, :gap_secs, :interlining],
    no_relief_opportunity: [:from_secs, :to_secs, :secs, :limit_secs],
    overlap: [:overlap_secs],
    repositions: [:gap_secs, :meters, :drive],
    short_layover: [:gap_secs, :wait_secs],
    too_long: [:platform_secs, :limit_minutes, :limit_source],
    type_mismatch: [:vehicle_type_id, :required_vehicle_type_id],
    unplottable: []
  }

  @attribute_row_keys [:service_id, :garage_id, :vehicle_type_id]

  @setting_keys [
    :min_layover_minutes,
    :max_block_minutes,
    :pull_out_buffer_minutes,
    :interlining,
    :max_piece_minutes,
    :default_garage_id,
    :deadhead_speed_kmh,
    :deadhead_circuity
  ]

  # What `load_day/3` returns, so a hand-assembled map is refused rather than
  # half-projected.
  @day_keys [:day_type, :blocks, :pool, :unplottable, :findings, :settings, :context]

  @selection_keys [:selected_block_ids, :selected_trip_ids]

  @typedoc "The selection the host displays, as technical block and trip IDs."
  @type selection :: %{
          optional(:selected_block_ids) => [String.t()],
          optional(:selected_trip_ids) => [String.t()]
        }

  @doc """
  Projects one loaded block day into an immutable, JSON-safe payload.

  `day` is a `GtfsPlanner.Gtfs.Blocking.load_day/3` result and `selection` the
  host's displayed selection; neither is retained. The result is
  `{:error, :unavailable}` for a day with no selected day type, a value that is
  not the loaded shape, a selection carrying anything other than
  `:selected_block_ids` and `:selected_trip_ids`, or a selection naming a block
  or trip the day does not hold.
  """
  @spec block_day(map(), selection()) :: {:ok, map()} | {:error, :unavailable}
  def block_day(day, selection) do
    with {:ok, day_key} <- day_key(day),
         {:ok, selected} <- read_selection(selection),
         {:ok, scope} <- resolve_scope(day, selected),
         {:ok, refs} <- refs(day, day_key),
         {:ok, issues} <- issues(day, scope, refs) do
      content = %{
        "schema_version" => @schema_version,
        "section" => @section,
        "day_key" => day_key,
        "selection" => selection_copy(selected, refs),
        "scope" => scope_copy(scope, refs),
        "totals" => Enum.frequencies_by(issues, & &1["code"]),
        "completeness" => if(scope.mode == :whole_day, do: "complete", else: "scoped"),
        "exclusions" => exclusions(day, scope, refs),
        "issues" => issues,
        "constraints" => constraints(day),
        "entities" => entities(day, scope, refs),
        "plan" => nil
      }

      {:ok, Map.merge(content, identity(day_key, content))}
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  # --- identity ----------------------------------------------------------

  # The day a load actually selected. A version whose calendars derive no day
  # type returns `day_type: nil`, and nothing falls back to another day type.
  defp day_key(day) when is_map(day) do
    if Enum.all?(@day_keys, &Map.has_key?(day, &1)) do
      case Map.fetch!(day, :day_type) do
        %{key: key} when is_binary(key) -> {:ok, key}
        _none -> :error
      end
    else
      :error
    end
  end

  defp day_key(_day), do: :error

  defp identity(day_key, content) do
    %{
      "day_ref" => ref(key_digest(day_key), "day", day_key),
      "source_digest" => digest(content)
    }
  end

  defp key_digest(day_key), do: sha("#{@ref_namespace}|#{@section}|#{day_key}")

  defp ref(key_digest, kind, key) do
    "#{kind}_" <> binary_part(sha("#{key_digest}|#{kind}|#{key}"), 0, 32)
  end

  defp sha(string) do
    :sha256 |> :crypto.hash(string) |> Base.encode16(case: :lower)
  end

  # The digest of the projected content with the digest and ref fields left out,
  # so a content that only restates its own identity digests the same.
  defp digest(content) do
    content
    |> Map.drop(["source_digest", "day_ref"])
    |> :erlang.term_to_binary([:deterministic])
    |> sha()
  end

  # --- selection and scope -----------------------------------------------

  defp read_selection(selection) when is_map(selection) do
    if Enum.all?(@selection_keys, &selection_ids(selection, &1)) and
         Map.keys(selection) -- @selection_keys == [] do
      {:ok,
       %{
         block_ids: selection |> Map.get(:selected_block_ids, []) |> Enum.uniq(),
         trip_ids: selection |> Map.get(:selected_trip_ids, []) |> Enum.uniq()
       }}
    else
      :error
    end
  end

  defp read_selection(_selection), do: :error

  defp selection_ids(selection, key) do
    case Map.get(selection, key, []) do
      ids when is_list(ids) -> Enum.all?(ids, &is_binary/1)
      _other -> false
    end
  end

  # The scope the payload answers for. Nothing selected is the whole day; a
  # selection is an explicit subset naming the rows it keeps, the rows it leaves
  # out and the garages whose own findings stay visible inside it.
  defp resolve_scope(day, %{block_ids: block_ids, trip_ids: trip_ids}) do
    if Enum.all?(block_ids, &known_block?(day, &1)) and Enum.all?(trip_ids, &known_trip?(day, &1)) do
      if block_ids == [] and trip_ids == [] do
        {:ok, whole_day(day)}
      else
        {:ok, explicit_subset(day, block_ids, trip_ids)}
      end
    else
      :error
    end
  end

  defp known_block?(day, block_id), do: Enum.any?(day.blocks, &(&1.summary.block_id == block_id))

  defp known_trip?(day, trip_id), do: Enum.any?(all_trips(day), &(&1.trip_id == trip_id))

  defp whole_day(day) do
    %{
      mode: :whole_day,
      blocks: Enum.map(day.blocks, & &1.summary.block_id),
      trips: Enum.map(day.pool, & &1.trip_id),
      excluded_blocks: [],
      excluded_trips: [],
      trip_ids: Enum.map(all_trips(day), & &1.id),
      garages: garages_of(day, Enum.map(day.blocks, & &1.summary.block_id))
    }
  end

  # A selected trip inside a selected block narrows nothing, so it is not listed
  # as a scope trip; a selected trip outside one is, and its block is read for the
  # rows the trip needs without becoming part of the selected scope.
  defp explicit_subset(day, block_ids, trip_ids) do
    blocks = Enum.uniq(block_ids)
    kept = Enum.flat_map(blocks, &block_trips(day, &1))
    kept_ids = Enum.map(kept, & &1.trip_id)
    trips = trip_ids |> Enum.uniq() |> Enum.reject(&(&1 in kept_ids))

    %{
      mode: :explicit_subset,
      blocks: blocks,
      trips: Enum.map(trips, & &1.trip_id),
      excluded_blocks: Enum.map(day.blocks, & &1.summary.block_id) -- blocks,
      excluded_trips:
        Enum.map(all_trips(day), & &1.trip_id) -- Enum.map(kept ++ trips, & &1.trip_id),
      trip_ids: Enum.map(kept ++ trips, & &1.id),
      garages: garages_of(day, blocks)
    }
  end

  defp block_trips(day, block_id) do
    case Enum.find(day.blocks, &(&1.summary.block_id == block_id)) do
      nil -> []
      block -> block.trips
    end
  end

  defp all_trips(day), do: Enum.flat_map(day.blocks, & &1.trips) ++ day.pool

  defp garages_of(day, block_ids) do
    day.blocks
    |> Enum.filter(&(&1.summary.block_id in block_ids))
    |> Enum.map(& &1.resolution.garage_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The refs of every row the day's findings can name. A finding naming a trip the
  # day does not hold means the copy cannot describe it, so the projection is
  # unavailable rather than quietly losing a row.
  defp refs(day, day_key) do
    key_digest = key_digest(day_key)

    {:ok,
     %{
       key_digest: key_digest,
       trips: Map.new(all_trips(day), &{&1.id, ref(key_digest, "trip", &1.trip_id)}),
       blocks:
         Map.new(
           day.blocks,
           &{&1.summary.block_id, ref(key_digest, "block", &1.summary.block_id)}
         )
     }}
  end

  # Keyed by the trip row's own id, because that is what a finding's `trip_ids`
  # names; the ref itself is derived from the trip's technical GTFS ID.
  defp trip_ref(refs, trip_id), do: Map.get(refs.trips, trip_id)

  defp block_ref(refs, block_id), do: Map.get(refs.blocks, block_id)

  # --- payload sections ---------------------------------------------------

  defp selection_copy(selected, refs) do
    %{
      "selected_block_refs" => Enum.map(selected.block_ids, &block_ref(refs, &1)),
      "selected_trip_refs" => Enum.map(selected.trip_ids, &trip_ref(refs, &1))
    }
  end

  defp scope_copy(scope, refs) do
    %{
      "mode" => Atom.to_string(scope.mode),
      "block_refs" => Enum.map(scope.blocks, &block_ref(refs, &1)),
      "trip_refs" => Enum.map(scope.trips, &trip_ref(refs, &1))
    }
  end

  # The day's own finding order, which `load_day/3` fixes. The paging step sorts
  # on severity, code and refs when it serves a page.
  defp issues(day, scope, refs) do
    day.findings
    |> in_scope(scope)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {finding, position}, {:ok, acc} ->
      case issue(finding, position, refs) do
        {:ok, issue} -> {:cont, {:ok, acc ++ [issue]}}
        :error -> {:halt, :error}
      end
    end)
  end

  # Finding instance counts, never a sum of overlapping categories: a block with
  # an overlap and a type mismatch is one finding of each code, and the payload
  # reports both counts rather than an invented total of problems.
  defp issue(finding, position, refs) do
    with {:ok, trip_refs} <- finding_trip_refs(finding, refs) do
      {:ok,
       %{
         "issue_ref" => issue_ref(refs.key_digest, finding, position),
         "code" => Atom.to_string(finding.code),
         "severity" => Atom.to_string(finding.severity),
         "severity_rank" => Map.fetch!(@severity_rank, finding.severity),
         "block_ref" => block_ref(refs, finding.block_id),
         "block_id" => finding.block_id,
         "trip_refs" => trip_refs,
         "detail" => detail(finding)
       }}
    end
  end

  # A finding naming a trip this day does not hold means the copy cannot describe
  # it, so the projection is unavailable rather than losing a row.
  defp finding_trip_refs(finding, refs) do
    Enum.reduce_while(finding.trip_ids, {:ok, []}, fn trip_id, {:ok, acc} ->
      case trip_ref(refs, trip_id) do
        nil -> {:halt, :error}
        ref -> {:cont, {:ok, acc ++ [ref]}}
      end
    end)
  end

  # A finding's own key beside its position in the day's list, so two findings of
  # one code over the same block and trips - two garage shortfalls, say - keep
  # two refs, while one finding keeps its ref however many rows precede it.
  defp issue_ref(key_digest, finding, position) do
    key =
      [
        Atom.to_string(finding.code),
        finding.block_id || "-",
        Enum.map_join(Enum.sort(finding.trip_ids), ",", &to_string/1),
        finding.transfer_id || "-",
        Integer.to_string(position)
      ]
      |> Enum.join("|")

    ref(key_digest, "issue", key)
  end

  defp detail(%{code: :block_attributes_conflict, detail: detail}) do
    %{"rows" => Enum.map(Map.get(detail, :rows, []), &attribute_row/1)}
  end

  defp detail(finding) do
    finding.detail
    |> Map.take(Map.get(@detail_keys, finding.code, []))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), json_safe(value)} end)
  end

  defp attribute_row(row) do
    row
    |> Map.take(@attribute_row_keys)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp json_safe(nil), do: nil
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, entry} -> {to_string(key), json_safe(entry)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value), do: value

  # A frequency-based or an unplottable trip sequences into no block, and
  # everything a subset leaves out is named rather than dropped. Both are
  # receipts, not judgements: the `frequency_trip` and `unplottable` findings
  # stay the authoritative statement about each trip.
  defp exclusions(day, scope, refs) do
    unsequenced(day, refs) ++ outside_scope(scope, refs)
  end

  defp unsequenced(day, refs) do
    Enum.flat_map(all_trips(day), fn trip ->
      cond do
        trip.frequency? ->
          [
            %{
              "kind" => "frequency_trip",
              "trip_ref" => trip_ref(refs, trip.id),
              "block_ref" => block_ref(refs, trip.block_id),
              "headway_secs" => trip.headway_secs
            }
          ]

        not trip.plottable? ->
          [
            %{
              "kind" => "unplottable",
              "trip_ref" => trip_ref(refs, trip.id),
              "block_ref" => block_ref(refs, trip.block_id)
            }
          ]

        true ->
          []
      end
    end)
  end

  defp outside_scope(%{mode: :whole_day}, _refs), do: []

  defp outside_scope(scope, refs) do
    Enum.map(
      scope.excluded_blocks,
      &%{"kind" => "outside_scope", "block_ref" => block_ref(refs, &1)}
    ) ++
      Enum.map(
        scope.excluded_trips,
        &%{"kind" => "outside_scope", "trip_ref" => trip_ref(refs, &1)}
      )
  end

  # The stored rules the day's findings were checked against: the block settings,
  # the garages and vehicle types the ids in the findings resolve against, and
  # whether the day was checked with planning inputs at all.
  defp constraints(day) do
    settings = Map.take(day.settings, @setting_keys)
    context = day.context

    %{
      "settings" =>
        Map.new(settings, fn {key, value} -> {Atom.to_string(key), json_safe(value)} end),
      "planning_inputs" => context.planning?,
      "garages" =>
        context.garages |> Map.keys() |> Enum.sort() |> Enum.map(&%{"garage_id" => &1}),
      "vehicle_types" =>
        context.vehicle_types
        |> Enum.sort_by(fn {id, _type} -> id end)
        |> Enum.map(fn {id, type} ->
          %{"vehicle_type_id" => id, "max_out_minutes" => Map.get(type, :max_out_minutes)}
        end),
      "entered_drive_times" => map_size(context.entered_minutes),
      "marked_relief_stops" => MapSet.size(context.relief_stop_ids),
      "estimated_drive_pairs" => Map.get(day, :estimated_pairs)
    }
  end

  # The technical identities the issues and the future paging read: one entry per
  # block with its resolved garage, type and platform span, and one per trip with
  # its service, route, exact parsed seconds and its block.
  defp entities(day, scope, refs) do
    blocks = Enum.filter(day.blocks, &(&1.summary.block_id in scope.blocks))
    trips = Enum.filter(all_trips(day), &(&1.id in scope.trip_ids))

    %{
      "blocks" => Enum.map(blocks, &block_entity(&1, refs)),
      "trips" => Enum.map(trips, &trip_entity(&1, refs))
    }
  end

  defp block_entity(block, refs) do
    %{
      "block_ref" => block_ref(refs, block.summary.block_id),
      "block_id" => block.summary.block_id,
      "garage_id" => block.resolution.garage_id,
      "vehicle_type_id" => block.resolution.vehicle_type_id,
      "garage_source" => json_safe(block.resolution.garage_source),
      "platform_start_secs" => block.movements.platform_start_secs,
      "platform_end_secs" => block.movements.platform_end_secs,
      "service_secs" => block.movements.service_secs,
      "drive_secs" => block.movements.drive_secs,
      "layover_secs" => block.movements.layover_secs,
      "trip_refs" => Enum.map(block.trips, &trip_ref(refs, &1.id))
    }
  end

  defp trip_entity(trip, refs) do
    %{
      "trip_ref" => trip_ref(refs, trip.id),
      "trip_id" => trip.trip_id,
      "service_id" => trip.service_id,
      "route_id" => trip.route_id,
      "block_ref" => block_ref(refs, trip.block_id),
      "first_arrival_secs" => trip.first_arrival,
      "first_departure_secs" => trip.first_departure,
      "last_arrival_secs" => trip.last_arrival,
      "last_departure_secs" => trip.last_departure,
      "frequency?" => trip.frequency?,
      "plottable?" => trip.plottable?
    }
  end

  # A finding of the day is in scope when it belongs to a block in scope or names
  # a trip in scope, and a garage-level `fleet_shortfall` stays in scope while the
  # garage is one the scope's blocks resolve to: the shortfall is the garage's
  # own, so narrowing to that garage keeps it visible and narrowing away from it
  # drops it rather than reporting another garage's shortage against this scope.
  defp in_scope(findings, %{mode: :whole_day}), do: findings

  defp in_scope(findings, scope) do
    Enum.filter(findings, fn finding ->
      finding.block_id in scope.blocks or
        Enum.any?(finding.trip_ids, &(&1 in scope.trip_ids)) or
        (finding.code == :fleet_shortfall and Map.get(finding.detail, :garage_id) in scope.garages)
    end)
  end
end

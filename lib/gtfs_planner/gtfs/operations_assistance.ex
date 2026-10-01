defmodule GtfsPlanner.Gtfs.OperationsAssistance do
  @moduledoc """
  The allowlisted projections the operations helper reads, copied from native
  domain results so a helper session can explain a day without holding a handle
  on host assigns.

  This module owns `block_day/2` and `run_day/1`: the block-day projection of one
  `GtfsPlanner.Gtfs.Blocking.load_day/3` result and the run-day projection of one
  `GtfsPlanner.Gtfs.Runs.load_runs/3` result. The day is loaded by its host
  (`BlocksLive` and `RunsLive` through the catalog read adapter) and this module
  reads no repository, starts no solver and writes no row. The completed-plan,
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

  `run_day/1` projects the other half from the one `load_runs/3` read that already
  holds the day, its crew rules, its derived runs and its fingerprint. It copies
  `Runs.WorkTime`'s own components - paid, spread, report, travel, break and
  sign-off seconds, the run's type and its ordered pieces - and `Runs.Checks`'
  own findings without recomputing any of them, and it never issues a second crew
  query. A negative break stays a negative number and the `:cannot_reach_piece`
  error raised against it is copied with it; an unmeasured travel leg keeps its
  `:unknown` status beside the zero seconds the work time charged it, so an
  unknown never reads as a measured zero. Uncovered work and orphan assignment
  counts are carried as the domain reported them, separately labelled from the
  finding counts rather than summed into one total.

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
  @section_blocks "blocks"
  @section_runs "runs"

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

  # What `Runs.load_runs/3` returns, so a hand-assembled map is refused rather
  # than half-projected, and what `Runs.Day.derive/4` puts inside it.
  @runs_day_keys [:day, :crew, :assignments, :derived, :orphans, :relief_ready?, :fingerprint]
  @derived_keys [:runs, :uncovered, :findings, :stats, :axis]
  @stats_keys [:runs, :by_type, :paid_secs, :vehicle_secs, :uncovered, :problems]

  # The stored crew rules, allowlisted: the five numbers a cut is judged against.
  @crew_keys [
    :report_pull_out_minutes,
    :report_relief_minutes,
    :sign_off_minutes,
    :paid_break_max_minutes,
    :max_spread_minutes
  ]

  # `Runs.WorkTime`'s own components. Every one of these is the domain's number,
  # copied: the projection derives no second figure from them.
  @work_keys [
    :sign_on_secs,
    :sign_off_secs,
    :spread_secs,
    :vehicle_secs,
    :report_secs,
    :travel_secs,
    :sign_off_allowance_secs,
    :paid_secs
  ]

  # The `detail` values each `Runs.Checks` finding carries, allowlisted per code.
  # `not_at_relief` names its two boundary trips by their database row, so its
  # keys are the session's own trip refs rather than the row IDs.
  @run_detail_keys %{
    cannot_reach_piece: [:piece, :needed_secs, :available_secs, :secs, :stop_id, :after_piece],
    not_at_relief: [:stop_id, :stop_name],
    orphan_assignments: [:count],
    piece_too_long: [:piece, :secs, :limit_secs],
    spread_too_long: [:secs, :limit_secs],
    too_many_pieces: [:pieces],
    travel_unknown: [:from, :to],
    uncovered_work: [:trips, :secs]
  }

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
         {:ok, refs} <- block_refs(day, day_key),
         {:ok, issues} <- block_issues(day, scope, refs) do
      content = %{
        "schema_version" => @schema_version,
        "section" => @section_blocks,
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

      {:ok, Map.merge(content, identity(day_key, content, @section_blocks))}
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

  defp identity(day_key, content, section) do
    %{
      "day_ref" => ref(key_digest(day_key, section), "day", day_key),
      "source_digest" => digest(content)
    }
  end

  defp key_digest(day_key, section), do: sha("#{@ref_namespace}|#{section}|#{day_key}")

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
  defp block_refs(day, day_key) do
    key_digest = key_digest(day_key, @section_blocks)

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
  defp block_issues(day, scope, refs) do
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
  # one code over the same block and trips - two garage shortfalls, or one run's
  # own error and another's - keep two refs, while one finding keeps its ref
  # however many rows precede it. `Runs.Checks` findings carry no `transfer_id`.
  defp issue_ref(key_digest, finding, position) do
    key =
      [
        Atom.to_string(finding.code),
        finding.block_id || "-",
        Enum.map_join(Enum.sort(finding.trip_ids), ",", &to_string/1),
        Map.get(finding, :transfer_id) || "-",
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

  # --- run-day projection -------------------------------------------------

  @doc """
  Projects one loaded runs day into an immutable, JSON-safe payload.

  `runs_day` is a `GtfsPlanner.Gtfs.Runs.load_runs/3` result - the day's blocks,
  crew rules, assignments, derived runs, findings, orphan count and fingerprint
  as that one read assembled them. Nothing is retained and no second read is
  issued: the day is read through the same embedded map, the crew arithmetic is
  the one `Runs.WorkTime` already performed, and the figures are the ones
  `Runs.Day.derive/4` derived. The result is `{:error, :unavailable}` for a value
  that is not that shape, for a day with no selected day type, or for a finding
  naming a run, block or trip the day does not hold - a projection that cannot
  describe every row it was given must not present the rest as complete.

  Scope is the whole day: the host has no narrower runs selection to freeze, and
  the packs narrow a *page* of this snapshot by run refs rather than by
  re-projecting a subset. `selection` is therefore empty and `completeness` is
  `complete`; `plan` is `nil` until the plan step owns it.
  """
  @spec run_day(map()) :: {:ok, map()} | {:error, :unavailable}
  def run_day(runs_day) do
    with {:ok, day_key} <- runs_day_key(runs_day),
         {:ok, refs} <- run_refs(runs_day, day_key),
         {:ok, issues} <- run_issues(runs_day, refs),
         {:ok, entities} <- run_entities(runs_day, refs) do
      content = %{
        "schema_version" => @schema_version,
        "section" => @section_runs,
        "day_key" => day_key,
        # Nothing narrows a runs projection yet, so the frozen selection is empty
        # rather than a second scope the payload does not honour.
        "selection" => %{"selected_run_refs" => [], "selected_trip_refs" => []},
        "scope" => run_scope_copy(runs_day, refs),
        "totals" => Enum.frequencies_by(issues, & &1["code"]),
        "completeness" => "complete",
        "exclusions" => unsequenced(runs_day.day, refs),
        "issues" => issues,
        "constraints" => run_constraints(runs_day),
        "entities" => entities,
        "figures" => figures(runs_day, refs),
        "orphans" => %{"count" => runs_day.orphans.count},
        "plan" => nil
      }

      {:ok, Map.merge(content, identity(day_key, content, @section_runs))}
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  defp runs_day_key(runs_day) when is_map(runs_day) do
    day = Map.get(runs_day, :day)
    derived = Map.get(runs_day, :derived)

    if Enum.all?(@runs_day_keys, &Map.has_key?(runs_day, &1)) and
         is_map(day) and
         is_map(derived) and
         Enum.all?(@derived_keys, &Map.has_key?(derived, &1)) and
         is_map(Map.get(derived, :stats)) and
         Enum.all?(@stats_keys, &Map.has_key?(derived.stats, &1)) do
      day_key(day)
    else
      :error
    end
  end

  defp runs_day_key(_runs_day), do: :error

  # The refs every run, finding and entity of this day can name. Trips are keyed
  # twice on purpose: a run finding names a trip by its GTFS ID, while a handover
  # boundary names the two trips it joins by their rows, and both have to resolve
  # to the same receipt for the same trip.
  defp run_refs(runs_day, day_key) do
    key_digest = key_digest(day_key, @section_runs)
    trips = all_trips(runs_day.day)

    refs = %{
      key_digest: key_digest,
      trips: Map.new(trips, &{&1.id, ref(key_digest, "trip", &1.trip_id)}),
      trip_ids: Map.new(trips, &{&1.trip_id, ref(key_digest, "trip", &1.trip_id)}),
      blocks:
        Map.new(
          runs_day.day.blocks,
          &{&1.summary.block_id, ref(key_digest, "block", &1.summary.block_id)}
        ),
      runs: Map.new(runs_day.derived.runs, &{&1.run_id, ref(key_digest, "run", &1.run_id)})
    }

    {:ok, refs}
  end

  defp run_trip_ref(refs, trip_id), do: Map.get(refs.trip_ids, trip_id)

  defp run_row_ref(refs, row_id), do: Map.get(refs.trips, row_id)

  defp run_ref(refs, run_id), do: Map.get(refs.runs, run_id)

  defp run_scope_copy(runs_day, refs) do
    %{
      "mode" => "whole_day",
      "run_refs" => Enum.map(runs_day.derived.runs, &run_ref(refs, &1.run_id)),
      "trip_refs" => Enum.map(all_trips(runs_day.day), &run_trip_ref(refs, &1.trip_id)),
      "block_refs" => Enum.map(runs_day.day.blocks, &block_ref(refs, &1.summary.block_id))
    }
  end

  # The day's own finding order, which `Runs.Day.derive/4` fixes by severity. A
  # finding naming a run, block or trip this day does not hold is unresolvable
  # here, so the projection is unavailable rather than losing the row.
  defp run_issues(runs_day, refs) do
    runs_day.derived.findings
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {finding, position}, {:ok, acc} ->
      case run_issue(finding, position, refs) do
        {:ok, issue} -> {:cont, {:ok, acc ++ [issue]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp run_issue(finding, position, refs) do
    with {:ok, run_refs} <- resolve_all(finding.run_ids, &run_ref(refs, &1)),
         {:ok, trip_refs} <- resolve_all(finding.trip_ids, &finding_trip_ref(finding, refs, &1)),
         {:ok, detail} <- run_detail(finding, refs) do
      {:ok,
       %{
         "issue_ref" => issue_ref(refs.key_digest, finding, position),
         "code" => Atom.to_string(finding.code),
         "severity" => Atom.to_string(finding.severity),
         "severity_rank" => Map.fetch!(@severity_rank, finding.severity),
         "run_refs" => run_refs,
         "block_ref" => block_ref(refs, finding.block_id),
         "block_id" => finding.block_id,
         "trip_refs" => trip_refs,
         "detail" => detail
       }}
    end
  end

  # A finding names its trips by their GTFS ID, except a handover boundary, which
  # names the two trips it joins by their rows; both resolve to the same receipt.
  defp finding_trip_ref(%{code: :not_at_relief}, refs, row_id), do: run_row_ref(refs, row_id)
  defp finding_trip_ref(_finding, refs, trip_id), do: run_trip_ref(refs, trip_id)

  defp resolve_all(values, lookup) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case lookup.(value) do
        nil -> {:halt, :error}
        ref -> {:cont, {:ok, acc ++ [ref]}}
      end
    end)
  end

  # A handover names its two boundary trips by their rows, which the session must
  # never see: the copy carries the trip's own ref under a key that says so.
  defp run_detail(%{code: :not_at_relief, detail: detail}, refs) do
    with {:ok, from_ref} <- row_or_nil(detail, :from_trip_id, refs),
         {:ok, to_ref} <- row_or_nil(detail, :to_trip_id, refs) do
      {:ok,
       %{
         "stop_id" => Map.get(detail, :stop_id),
         "stop_name" => Map.get(detail, :stop_name),
         "from_trip_ref" => from_ref,
         "to_trip_ref" => to_ref
       }}
    end
  end

  # One unmeasured leg: its ends are planning references, not a JSON-safe value,
  # so they are carried in the domain's own stored form and an end that cannot be
  # encoded refuses the projection rather than reaching the payload as a tuple.
  defp run_detail(%{code: :travel_unknown, detail: detail}, _refs) do
    with {:ok, from} <- planning_ref(detail, :from),
         {:ok, to} <- planning_ref(detail, :to) do
      {:ok, %{"from" => from, "to" => to}}
    end
  end

  defp run_detail(finding, _refs) do
    detail =
      finding.detail
      |> Map.take(Map.get(@run_detail_keys, finding.code, []))
      |> Map.new(fn {key, value} -> {Atom.to_string(key), json_safe(value)} end)

    {:ok, detail}
  end

  defp row_or_nil(detail, key, refs) do
    case Map.fetch(detail, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, row_id} -> {:ok, run_row_ref(refs, row_id)}
      :error -> {:ok, nil}
    end
  end

  # The legs the context could not answer, kept as the domain listed them: one
  # row per unmeasured drive, beside the zero seconds it was charged, so the gap
  # is visible rather than reading as a free drive.
  defp unknown_travel(legs) do
    collect(legs, fn leg ->
      with {:ok, from} <- encoded_ref(leg.from),
           {:ok, to} <- encoded_ref(leg.to) do
        {:ok, %{"from" => from, "to" => to}}
      end
    end)
  end

  defp encoded_ref(ref) do
    case context_ref(ref) do
      :unknown -> :error
      encoded -> {:ok, encoded}
    end
  end

  defp planning_ref(detail, key) do
    case detail |> Map.get(key) |> context_ref() do
      :unknown -> :error
      encoded -> {:ok, encoded}
    end
  end

  # The stored rules the day's runs were computed against: the five crew rules, the
  # piece limit, the marked relief points and whether a cut can be planned at all.
  defp run_constraints(runs_day) do
    context = runs_day.day.context

    %{
      "crew" =>
        runs_day.crew
        |> Map.take(@crew_keys)
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end),
      "max_piece_minutes" => context.max_piece_minutes,
      "planning_inputs" => context.planning?,
      "relief_ready" => runs_day.relief_ready?,
      "marked_relief_stops" => MapSet.size(context.relief_stop_ids),
      "entered_drive_times" => map_size(context.entered_minutes),
      "default_garage_id" => context.default_garage_id
    }
  end

  # The technical identities the issues and the future paging read: one entry per
  # run carrying `Runs.WorkTime`'s own components and its pieces, one per trip
  # with the run that serves it - `nil` for work no run covers - and one per
  # block, shaped as the block projection shapes it so one snapshot reads alike.
  defp run_entities(runs_day, refs) do
    runs = runs_day.derived.runs
    covered = Map.new(runs, fn run -> {run.run_id, run_ref(refs, run.run_id)} end)

    with {:ok, run_rows} <- collect(runs, &run_entity(&1, refs)),
         {:ok, trips} <-
           collect(all_trips(runs_day.day), fn trip ->
             run_id = Map.get(runs_day.assignments, trip.id)

             {:ok,
              Map.put(trip_entity(trip, refs), "run_ref", run_id && Map.get(covered, run_id))}
           end) do
      {:ok,
       %{
         "runs" => run_rows,
         "trips" => trips,
         "blocks" => Enum.map(runs_day.day.blocks, &block_entity(&1, refs))
       }}
    end
  end

  # Every component here is `Runs.WorkTime`'s own figure. A negative break stays
  # negative and an unknown leg keeps its `:unknown` status beside the zero
  # seconds it was charged, because a copy that tidied either would misreport the
  # run the page is showing.
  defp run_entity(run, refs) do
    work = run.work

    with {:ok, pieces} <- run_pieces(run, refs),
         {:ok, unknown} <- unknown_travel(work.unknown_travel) do
      {:ok,
       work
       |> Map.take(@work_keys)
       |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
       |> Map.merge(%{
         "run_ref" => run_ref(refs, run.run_id),
         "run_id" => run.run_id,
         "garage_id" => work.garage_id,
         "type" => Atom.to_string(work.type),
         "breaks" =>
           Enum.map(work.breaks, fn break_entry ->
             %{
               "secs" => break_entry.secs,
               "paid?" => break_entry.paid?,
               "after_piece" => break_entry.after_piece
             }
           end),
         "unknown_travel" => unknown,
         "pieces" => pieces
       })}
    end
  end

  # Numbered from 1 in the order `Runs.WorkTime` numbers them, because that is
  # the index `Runs.Checks` names in a `piece_too_long` or `cannot_reach_piece`
  # detail, so a finding's piece number resolves to a piece here.
  defp run_pieces(run, refs) do
    run.pieces
    |> Enum.sort_by(& &1.start_secs)
    |> Enum.with_index(1)
    |> collect(fn {piece, index} ->
      with {:ok, trip_refs} <- resolve_all(piece.trips, &run_row_ref(refs, &1.id)) do
        {:ok,
         %{
           "piece_index" => index,
           "block_ref" => block_ref(refs, piece.block_id),
           "block_id" => piece.block_id,
           "start_secs" => piece.start_secs,
           "end_secs" => piece.end_secs,
           "start_kind" => Atom.to_string(piece.start_kind),
           "end_kind" => Atom.to_string(piece.end_kind),
           "trip_refs" => trip_refs
         }}
      end
    end)
  end

  # The day's own figures, copied: `Runs.Day.derive/4` derived them and this
  # projection sums nothing of its own. `uncovered` stays its own labelled
  # work count rather than being added to the issue counts above it.
  defp figures(runs_day, refs) do
    stats = runs_day.derived.stats

    %{
      "runs" => stats.runs,
      "by_type" => json_safe(stats.by_type),
      "straight_share" => stats.straight_share,
      "paid_secs" => stats.paid_secs,
      "vehicle_secs" => stats.vehicle_secs,
      "vehicle_share" => stats.vehicle_share,
      "longest_spread" => longest_spread(stats.longest_spread, refs),
      "uncovered" => json_safe(stats.uncovered),
      "problems" => json_safe(stats.problems),
      "axis" => json_safe(runs_day.derived.axis)
    }
  end

  defp longest_spread(nil, _refs), do: nil

  defp longest_spread(spread, refs) do
    %{
      "run_ref" => run_ref(refs, spread.run_id),
      "run_id" => spread.run_id,
      "secs" => spread.secs
    }
  end

  # Rows in the order the day gave them, halting on the first row the projection
  # cannot describe - the same refusal the findings and the pieces take.
  defp collect(rows, fun) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case fun.(row) do
        {:ok, row} -> {:cont, {:ok, acc ++ [row]}}
        :error -> {:halt, :error}
      end
    end)
  end

  # The same `"stop:<id>"` and `"garage:<uuid>"` form `DeadheadTimes` stores and
  # decodes, so a leg in the copy is the leg the domain measured. A reference of
  # an unexpected shape is refused rather than guessed at or raised on.
  defp context_ref({:stop, stop_id}) when is_binary(stop_id) and stop_id != "",
    do: "stop:" <> stop_id

  defp context_ref({:garage, id}) when is_binary(id), do: "garage:" <> id
  defp context_ref(_other), do: :unknown
end

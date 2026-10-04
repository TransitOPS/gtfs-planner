defmodule GtfsPlanner.Gtfs.OperationsAssistance do
  @moduledoc """
  The allowlisted projections the operations helper reads, copied from native
  domain results so a helper session can explain a day without holding a handle
  on host assigns.

  This module owns `block_day/2`, `run_day/1`, `plan/2`, `with_plan/3`,
  `context/2` and `page/4`/`page/5`: the block-day projection of one
  `GtfsPlanner.Gtfs.Blocking.load_day/3` result, the run-day projection of one
  `GtfsPlanner.Gtfs.Runs.load_runs/3` result, the completed-plan projection of
  one native plan, the admission of a projected payload as an immutable source
  snapshot and the bounded paging of a frozen payload. The day is loaded by its
  host (`BlocksLive` and `RunsLive` through the catalog read adapter) and this
  module reads no repository, starts no solver and writes no row.

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

  ## Completed plans, admission and paging

  `plan/2` copies the *current, completed* native plan of either section and
  nothing else: its before and after figures, its move counts, its leftovers,
  its preview warnings and its own fingerprint, under a server-generated
  `plan_ref`. The native write command, the actor and every row id stay out.
  `with_plan/3` is what a host calls to attach that copy to a projected payload,
  because `source_digest` is the digest of the payload's own content: a plan
  attached after the digest was taken would sit inside a snapshot the digest no
  longer describes. `plan_ref` is derived from the section, the day key and the
  plan's own fingerprint, so two plans of one day are two receipts, a replaced
  plan resolves to neither, and the native fingerprint is carried beside the ref
  as a fact about the plan rather than as the session's chronology.

  `context/2` is the only place this module admits anything. It builds
  `GtfsPlanner.Agents.Scope.context/1` for the caller's identity and hands the
  payload to `Scope.with_source_snapshot/2` under the kind `operations_blocks` or
  `operations_runs`, so the shared owner measures the 65,536-byte cap over the
  *whole* resource context and there is no second measurement here to disagree
  with it. A refused payload is refused whole: there is no truncated summary.

  `page/4` serves one bounded page of a frozen payload - at most 50 issue
  instances, sorted by severity, code, the issue's own ref and its canonical
  detail, and never more than 32 KiB once encoded. `page/5` takes the bytes a
  pack's own envelope and evidence will add, so the page and that overhead fit
  the same 32 KiB together. A page smaller than the limit is permitted when the byte
  budget needs it; a single row that cannot fit is refused rather than truncated.
  A cursor is a plain JSON object of the payload's digest, the collection, the
  normalized filters and an offset, with no server-side store behind it, so a
  cursor from another snapshot, another filter set or an offset the filtered
  total does not allow is `:unavailable` exactly as a malformed one is. Nothing
  here re-reads the day: a page is historical evidence labelled by its digest,
  and only the native handoff re-checks the current loaded inputs.
  """

  alias GtfsPlanner.Agents.Scope

  @schema_version 1
  @section_blocks "blocks"
  @section_runs "runs"

  # The snapshot kinds the shared owner stores an operations payload under. They
  # are this package's own words for the source, so a panel reading the snapshot
  # back can tell an operations day from any other admitted source.
  @snapshot_kind_blocks "operations_blocks"
  @snapshot_kind_runs "operations_runs"

  # Paging bounds. 50 issue instances is the page's own limit; the 32 KiB budget
  # covers the encoded page plus the envelope and evidence bytes the caller
  # reserves through `page/5`, which is why a page may be smaller than the limit
  # but never a partial row.
  @page_limit 50
  @max_page_bytes 32_768

  # The collections a frozen payload can page. A collection this module does not
  # name is not served rather than guessed at.
  @collection_issues "issues"

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

  # What `Blocking.Plan.build/1` returns, so a hand-assembled map - or a pending,
  # failed or superseded plan a host still holds - is refused rather than
  # half-projected.
  @block_plan_keys [
    :mode,
    :day_type_key,
    :moves,
    :new_blocks,
    :attribute_rows,
    :review,
    :before,
    :after,
    :leftovers,
    :fingerprint
  ]

  # What `Runs.Plan.build/1` returns. `preview` is a `Runs.Day.derive/4` result,
  # which is where the warnings a plan would leave behind are already derived.
  @runs_plan_keys [
    :day_type_key,
    :scope,
    :moves,
    :changed_run_ids,
    :new_run_ids,
    :before,
    :after,
    :preview,
    :fingerprint
  ]

  # The plan figures each section publishes, allowlisted. The runs section's
  # `before` and `after` are `Runs.Day.derive/4`'s own stats maps, so the plan
  # copy reads exactly the keys the day copy reads and invents no second figure.
  @block_figure_keys [:vehicles, :platform_secs, :drive_secs, :problems]
  @runs_figure_keys [
    :runs,
    :by_type,
    :paid_secs,
    :vehicle_secs,
    :uncovered,
    :problems,
    :straight_share,
    :vehicle_share
  ]

  # A leftover is a trip the generator could not place and the reason it could
  # not, plus the block it was held in. The trip itself is named by its GTFS id
  # and a session receipt, never by its row.

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

    # A trip-only selection - the editor narrowed to unassigned trips - names no
    # block at all, so its rows are read from the day's own trips rather than
    # from a block. Without this the subset would raise on the first trip's row.
    selected = Enum.filter(all_trips(day), &(&1.trip_id in trips))

    %{
      mode: :explicit_subset,
      blocks: blocks,
      trips: trips,
      excluded_blocks: Enum.map(day.blocks, & &1.summary.block_id) -- blocks,
      excluded_trips:
        Enum.map(all_trips(day), & &1.trip_id) -- Enum.map(kept ++ selected, & &1.trip_id),
      trip_ids: Enum.map(kept ++ selected, & &1.id),
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
       trip_ids: Map.new(all_trips(day), &{&1.trip_id, ref(key_digest, "trip", &1.trip_id)}),
       other_day_trips: other_day_trips(day),
       blocks:
         Map.new(
           day.blocks,
           &{&1.summary.block_id, ref(key_digest, "block", &1.summary.block_id)}
         )
     }}
  end

  # The technical GTFS ID of every trip the day's type 4/5 records were evaluated
  # over, by row. A record can continue into a trip of another day type, which
  # this day holds no ref for; its own GTFS ID is how the copy names it.
  defp other_day_trips(%{in_seat_source: %{context: %{trips: trips}}}) when is_map(trips) do
    Map.new(trips, fn {_trip_id, trip} -> {trip.id, trip.trip_id} end)
  end

  defp other_day_trips(_day), do: %{}

  # Keyed by the trip row's own id, because that is what a finding's `trip_ids`
  # names; the ref itself is derived from the trip's technical GTFS ID.
  defp trip_ref(refs, trip_id), do: Map.get(refs.trips, trip_id)

  # Keyed by the technical GTFS ID, which is what a scope and a host selection
  # name.
  defp gtfs_trip_ref(refs, trip_id), do: Map.get(refs.trip_ids, trip_id)

  defp block_ref(refs, block_id), do: Map.get(refs.blocks, block_id)

  # --- payload sections ---------------------------------------------------

  defp selection_copy(selected, refs) do
    %{
      "selected_block_refs" => Enum.map(selected.block_ids, &block_ref(refs, &1)),
      "selected_trip_refs" => Enum.map(selected.trip_ids, &gtfs_trip_ref(refs, &1))
    }
  end

  defp scope_copy(scope, refs) do
    %{
      "mode" => Atom.to_string(scope.mode),
      "block_refs" => Enum.map(scope.blocks, &block_ref(refs, &1)),
      "trip_refs" => Enum.map(scope.trips, &gtfs_trip_ref(refs, &1))
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
    with {:ok, trip_refs, other_day} <- finding_trip_refs(finding, refs) do
      issue = %{
        "issue_ref" => issue_ref(refs.key_digest, finding, position),
        "code" => Atom.to_string(finding.code),
        "severity" => Atom.to_string(finding.severity),
        "severity_rank" => Map.fetch!(@severity_rank, finding.severity),
        "block_ref" => block_ref(refs, finding.block_id),
        "block_id" => finding.block_id,
        "trip_refs" => trip_refs,
        "detail" => detail(finding)
      }

      {:ok, if(other_day, do: Map.put(issue, "other_day_trip_ids", other_day), else: issue)}
    end
  end

  # A type 4/5 record can hand over to a trip of another day type - a Friday-night
  # trip continuing into Saturday - so its trips this day holds keep their refs
  # and the other end is named by its technical GTFS ID under
  # `other_day_trip_ids`. Any other finding naming a trip this day does not hold
  # means the copy cannot describe it, so the projection is unavailable rather
  # than losing a row.
  defp finding_trip_refs(%{code: code} = finding, refs)
       when code in [:in_seat_stale, :in_seat_unconfirmed] do
    {here, elsewhere} = Enum.split_with(finding.trip_ids, &Map.has_key?(refs.trips, &1))

    with {:ok, other_day} <- resolve_all(elsewhere, &Map.get(refs.other_day_trips, &1)) do
      {:ok, Enum.map(here, &trip_ref(refs, &1)), other_day}
    end
  end

  defp finding_trip_refs(finding, refs) do
    with {:ok, trip_refs} <- resolve_all(finding.trip_ids, &trip_ref(refs, &1)) do
      {:ok, trip_refs, nil}
    end
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

  # The two in-seat codes are the only findings whose `detail.reason` is a
  # tagged tuple rather than a map: `Blocking.InSeat.reason/0` is either a plain
  # atom or `{:not_next, day_types}`. A tuple is not JSON, and the generic
  # `json_safe/1` fallback passes one through unchanged, so an `in_seat_stale`
  # row made the whole payload unencodable and the helper reported the day
  # unreadable on any version holding a stale type 4/5 record. It is projected by
  # its own shape here, exactly as `block_attributes_conflict` nests its rows.
  defp detail(%{code: code, detail: detail})
       when code in [:in_seat_stale, :in_seat_unconfirmed] do
    %{"reason" => in_seat_reason(Map.get(detail, :reason))}
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

  # The day types a record is not next on, by their own allowlist: the service
  # key, its label, how many dates it runs and the trip it hands over to. Those
  # are the fields `Blocking.InSeat` itself documents, and they are technical —
  # no operator or roster data. A reason that is a plain atom is its own name,
  # and anything else is dropped rather than serialized, so an unrecognised
  # shape cannot widen what the payload carries.
  defp in_seat_reason({:not_next, day_types}) when is_list(day_types) do
    %{"not_next" => Enum.map(day_types, &in_seat_day_type/1)}
  end

  defp in_seat_reason(reason) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  defp in_seat_reason(_other), do: nil

  defp in_seat_day_type(day_type) do
    %{
      "key" => Map.get(day_type, :key),
      "label" => Map.get(day_type, :label),
      "date_count" => Map.get(day_type, :date_count),
      "next_trip_id" => Map.get(day_type, :next_trip_id)
    }
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
  # stay the authoritative statement about each trip. Only the scope's own trips
  # are named as unsequenced, so a trip outside a subset is listed once, as
  # `outside_scope`.
  defp exclusions(day, scope, refs) do
    in_scope = MapSet.new(scope.trip_ids)

    day
    |> all_trips()
    |> Enum.filter(&MapSet.member?(in_scope, &1.id))
    |> unsequenced(refs)
    |> Kernel.++(outside_scope(scope, refs))
  end

  defp unsequenced(trips, refs) do
    Enum.flat_map(trips, fn trip ->
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
        &%{"kind" => "outside_scope", "trip_ref" => gtfs_trip_ref(refs, &1)}
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
        "exclusions" => runs_day.day |> all_trips() |> unsequenced(refs),
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

  # --- completed plan -----------------------------------------------------

  @doc """
  Projects one current, completed native plan into an immutable copy.

  `kind` is `:blocks` for a `GtfsPlanner.Gtfs.Blocking.Plan` and `:runs` for a
  `GtfsPlanner.Gtfs.Runs.Plan`; `native_plan` is the plan the host's own
  successful, current job returned. The copy carries the server-generated
  `plan_ref`, the `native_fingerprint` the apply path rechecks, the plan's mode
  or scope, its before and after figures, its move counts, its leftovers and the
  preview warnings it would add. It carries no native write command, no actor,
  no row id and no operator text (`C-3`).

  Anything else is `{:error, :unavailable}`: a value that is not that section's
  plan shape - which is what a missing, still-pending, failed or superseded plan
  looks like to this function - and a plan whose `day_type_key` is not a string.
  A replaced plan is not refused here, because this function is pure and cannot
  know what replaced it; it is refused at the boundary, where the host compares
  the copy's `plan_ref` with the plan the panel holds and re-reads the current
  day before opening the native drawer.

  The refs inside the copy are derived from the section, the day key and the
  plan's own fingerprint, so two plans of one day type are two receipts and a
  snapshot can only resolve the plan it actually carries.
  """
  @spec plan(:blocks | :runs, map()) :: {:ok, map()} | {:error, :unavailable}
  def plan(kind, native_plan) when kind in [:blocks, :runs] and is_map(native_plan) do
    with {:ok, day_key} <- plan_day_key(native_plan),
         {:ok, body} <- plan_body(kind, native_plan, day_key) do
      {:ok, Map.merge(body, plan_identity(kind, day_key, native_plan))}
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  def plan(_kind, _native_plan), do: {:error, :unavailable}

  # A plan's day key is the key the generator ran against. Both plan shapes carry
  # it, and a payload's own `day_key` is what it is checked against when the copy
  # is attached.
  defp plan_day_key(native_plan) when is_map(native_plan) do
    case Map.get(native_plan, :day_type_key) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _none -> :error
    end
  end

  defp plan_day_key(_native_plan), do: :error

  defp plan_identity(kind, day_key, native_plan) do
    fingerprint = native_plan.fingerprint

    %{
      "plan_ref" => ref(key_digest(day_key, section(kind)), "plan", fingerprint),
      "section" => section(kind),
      "day_key" => day_key,
      "native_fingerprint" => fingerprint
    }
  end

  defp section(:blocks), do: @section_blocks
  defp section(:runs), do: @section_runs

  defp plan_body(:blocks, native_plan, day_key), do: block_plan_body(native_plan, day_key)
  defp plan_body(:runs, native_plan, _day_key), do: runs_plan_body(native_plan)

  # --- block plan ---------------------------------------------------------

  defp block_plan_body(native_plan, day_key) do
    if Enum.all?(@block_plan_keys, &Map.has_key?(native_plan, &1)) and
         is_binary(native_plan.fingerprint) do
      with {:ok, mode, selected_block_ids} <- block_mode(native_plan.mode),
           {:ok, before_figures} <- block_figures(Map.fetch!(native_plan, :before)),
           {:ok, after_figures} <- block_figures(Map.fetch!(native_plan, :after)),
           {:ok, leftovers} <- block_leftovers(native_plan.leftovers, day_key),
           {:ok, warnings} <- block_warnings(native_plan.review) do
        {:ok,
         %{
           "mode" => mode,
           "selected_block_ids" => selected_block_ids,
           "before" => before_figures,
           "after" => after_figures,
           "move_count" => length(native_plan.moves),
           "new_block_count" => length(native_plan.new_blocks),
           "leftovers" => leftovers,
           "warnings" => warnings
         }}
      else
        _unavailable -> :error
      end
    else
      :error
    end
  end

  # `Generator.mode()` is an atom or `{:selected, ids}`. The copy's `"mode"` is
  # always the mode's name, so a reader never has to tell a string from a map; the
  # selected ids are technical block IDs the payload already names, so they are
  # copied beside it, and are empty for the two modes with no targets. Any other
  # shape is refused rather than stringified.
  defp block_mode(:unassigned_only), do: {:ok, "unassigned_only", []}
  defp block_mode(:replace_all), do: {:ok, "replace_all", []}

  defp block_mode({:selected, ids}) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1), do: {:ok, "selected", ids}, else: :error
  end

  defp block_mode(_mode), do: :error

  defp block_figures(figures) when is_map(figures) do
    if Enum.all?(@block_figure_keys, &Map.has_key?(figures, &1)) do
      {:ok, Map.new(figures, fn {key, value} -> {Atom.to_string(key), value} end)}
    else
      :error
    end
  end

  defp block_figures(_figures), do: :error

  # A leftover is a trip the generator could not place. The trip is named by its
  # own technical GTFS id and a receipt, never by its row, and a leftover whose
  # trip the copy cannot name refuses the projection like any other unresolvable
  # row.
  defp block_leftovers(leftovers, day_key) when is_list(leftovers) do
    key_digest = key_digest(day_key, @section_blocks)

    collect(leftovers, fn leftover ->
      with true <- is_map(leftover),
           trip when is_map(trip) <- Map.get(leftover, :trip),
           trip_id when is_binary(trip_id) <- Map.get(trip, :trip_id),
           reason when is_atom(reason) <- Map.get(leftover, :reason),
           block_id when is_nil(block_id) or is_binary(block_id) <- Map.get(leftover, :block_id) do
        {:ok,
         %{
           "trip_ref" => ref(key_digest, "trip", trip_id),
           "trip_id" => trip_id,
           "reason" => Atom.to_string(reason),
           "block_ref" => block_id && ref(key_digest, "block", block_id)
         }}
      else
        _unavailable -> :error
      end
    end)
  end

  defp block_leftovers(_leftovers, _day_key), do: :error

  # What the plan would add, copied from `Blocking.Review`'s own added findings:
  # the codes, severities and blocks, and nothing else. A finding's trip ids are
  # database rows and the copy has no day to resolve them against, so a warning
  # here names the block only - which is what `compare_*_proposal` needs to say
  # that a plan stops being clean.
  defp block_warnings(review) when is_map(review) do
    case Map.get(review, :effects) do
      effects when is_list(effects) ->
        effects
        |> Enum.flat_map(&Map.get(&1, :added, []))
        |> collect(&block_warning/1)

      _other ->
        :error
    end
  end

  defp block_warnings(_review), do: :error

  defp block_warning(finding) do
    with code when is_atom(code) <- Map.get(finding, :code),
         severity when is_map_key(@severity_rank, severity) <- Map.get(finding, :severity) do
      {:ok,
       %{
         "code" => Atom.to_string(code),
         "severity" => Atom.to_string(severity),
         "severity_rank" => @severity_rank[severity],
         "block_id" => Map.get(finding, :block_id)
       }}
    else
      _unavailable -> :error
    end
  end

  # --- runs plan ----------------------------------------------------------

  defp runs_plan_body(native_plan) do
    if Enum.all?(@runs_plan_keys, &Map.has_key?(native_plan, &1)) and
         is_binary(native_plan.fingerprint) and is_atom(native_plan.scope) and
         is_map(native_plan.preview) do
      with {:ok, before_figures} <- runs_plan_figures(Map.fetch!(native_plan, :before)),
           {:ok, after_figures} <- runs_plan_figures(Map.fetch!(native_plan, :after)),
           {:ok, warnings} <- runs_warnings(Map.get(native_plan.preview, :findings)) do
        {:ok,
         %{
           "mode" => Atom.to_string(native_plan.scope),
           "before" => before_figures,
           "after" => after_figures,
           "move_count" => length(native_plan.moves),
           "changed_run_count" => length(native_plan.changed_run_ids),
           "new_run_count" => length(native_plan.new_run_ids),
           # `Runs.Plan` has no leftovers: the work no run covers is already
           # carried as the day's own labelled uncovered count in the figures
           # above, and copying it here a second time would read as a second
           # count of the same work.
           "leftovers" => [],
           "warnings" => warnings
         }}
      else
        _unavailable -> :error
      end
    else
      :error
    end
  end

  # The plan's `before` and `after` are `Runs.Day.derive/4`'s own stats maps, so
  # the copy reads the same keys the run-day copy reads and derives no second
  # figure from them.
  defp runs_plan_figures(stats) when is_map(stats) do
    if Enum.all?(@runs_figure_keys, &Map.has_key?(stats, &1)) do
      {:ok, Map.new(stats, &{Atom.to_string(elem(&1, 0)), json_safe(elem(&1, 1))})}
    else
      :error
    end
  end

  defp runs_plan_figures(_stats), do: :error

  # The warnings the preview day would carry, copied per code exactly as
  # `run_issue/3` copies the day's own: the code, the severity and the technical
  # runs and block it names, never its rows.
  defp runs_warnings(findings) when is_list(findings) do
    collect(findings, &runs_warning/1)
  end

  defp runs_warnings(_findings), do: :error

  defp runs_warning(finding) do
    with code when is_atom(code) <- Map.get(finding, :code),
         severity when is_map_key(@severity_rank, severity) <- Map.get(finding, :severity),
         detail when is_map(detail) <- Map.get(finding, :detail),
         block_id when is_nil(block_id) or is_binary(block_id) <- Map.get(finding, :block_id),
         run_ids when is_list(run_ids) <- Map.get(finding, :run_ids),
         true <- Enum.all?(run_ids, &is_binary/1) do
      {:ok,
       %{
         "code" => Atom.to_string(code),
         "severity" => Atom.to_string(severity),
         "severity_rank" => @severity_rank[severity],
         "run_ids" => run_ids,
         "block_id" => block_id,
         "detail" => json_safe(Map.take(detail, Map.get(@run_detail_keys, code, [])))
       }}
    else
      _unavailable -> :error
    end
  end

  # --- plan attachment ----------------------------------------------------

  @doc """
  Attaches a completed plan's copy to a projected payload.

  `payload` is a `block_day/2` or `run_day/1` result, `kind` the section the plan
  belongs to and `native_plan` the plan the host's current successful job
  returned. The returned payload carries the plan under `"plan"` and a
  `source_digest` recomputed over the content *with* the plan in it, because the
  digest is what a cursor, a pack read and the session key are bound to: a
  payload whose digest predates its plan would let two different plans answer
  under one digest.

  The result is `{:error, :unavailable}` for a payload that is not a projection,
  a section that does not match the payload's own, a plan generated for another
  day type than the payload's `day_key`, or a plan `plan/2` refuses -
  which is how a missing, pending, failed or superseded plan never reaches a
  snapshot at all.
  """
  @spec with_plan(map(), :blocks | :runs, map()) :: {:ok, map()} | {:error, :unavailable}
  def with_plan(payload, kind, native_plan) when is_map(payload) and kind in [:blocks, :runs] do
    with {:ok, day_key} <- payload_day_key(payload, kind),
         {:ok, ^day_key} <- plan_day_key(native_plan),
         {:ok, copied} <- plan(kind, native_plan) do
      content =
        payload
        |> Map.drop(["source_digest", "day_ref"])
        |> Map.put("plan", copied)

      {:ok, Map.merge(content, identity(day_key, content, section(kind)))}
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  def with_plan(_payload, _kind, _native_plan), do: {:error, :unavailable}

  defp payload_day_key(payload, kind) do
    with true <- Map.get(payload, "schema_version") == @schema_version,
         true <- Map.get(payload, "section") == section(kind),
         day_key when is_binary(day_key) and day_key != "" <- Map.get(payload, "day_key"),
         digest when is_binary(digest) and digest != "" <- Map.get(payload, "source_digest") do
      {:ok, day_key}
    else
      _unavailable -> :error
    end
  end

  # --- snapshot admission -------------------------------------------------

  @doc """
  Admits a projected payload as this conversation's immutable source snapshot.

  `identity` is the scope's own resource identity and `payload` a `block_day/2`,
  `run_day/1` or `with_plan/3` result. The kind is this module's own - the
  payload's `section` decides between `operations_blocks` and `operations_runs`,
  because the kind is what a later read tells the admitted source apart by, and
  a caller that could name it could admit a day's evidence under another's kind.

  The result is `{:ok, resource_context}` with the snapshot attached, or the
  shared owner's own `{:error, :invalid_snapshot}` for a payload that is not
  JSON-safe, carries no recognized section, or is accompanied by an identity that
  is not a version or route, and `{:error, :too_large}` when the *whole* resource
  context exceeds 65,536 bytes. A refused payload is refused whole: there is no
  truncated summary to admit in its place.
  """
  @spec context(Scope.identity(), map()) ::
          {:ok, Scope.resource_context()} | {:error, :invalid_snapshot | :too_large}
  def context(identity, payload) when is_map(payload) do
    case snapshot_kind(payload) do
      {:ok, kind} ->
        Scope.with_source_snapshot(Scope.context(identity), %{kind: kind, payload: payload})

      :error ->
        {:error, :invalid_snapshot}
    end
  end

  def context(_identity, _payload), do: {:error, :invalid_snapshot}

  @doc """
  Binds the selection a projected payload froze.

  The digest is taken over the payload's own `selection` map, so it changes with
  the displayed block and trip selection and with nothing else. It is what a
  host recomputes from the selection it re-projects before it honours a prepared
  configuration, and what a pack writes into that configuration's command. Both
  sides call this function, so a host and the pack that produced a proposal
  cannot disagree about which selection it was prepared for.

  A payload that is not a projection, or one that carries no selection, has no
  such binding and returns the empty string.
  """
  @spec selection_digest(map()) :: String.t()
  def selection_digest(payload) when is_map(payload) do
    case Map.fetch(payload, "selection") do
      {:ok, selection} -> sha(:erlang.term_to_binary(selection, [:deterministic]))
      :error -> ""
    end
  end

  def selection_digest(_payload), do: ""

  defp snapshot_kind(%{"section" => @section_blocks}), do: {:ok, @snapshot_kind_blocks}
  defp snapshot_kind(%{"section" => @section_runs}), do: {:ok, @snapshot_kind_runs}
  defp snapshot_kind(_payload), do: :error

  # --- bounded frozen paging ----------------------------------------------

  @typedoc "The filters a page narrows by: an optional code, severity and run refs."
  @type page_filters :: %{optional(String.t()) => String.t() | [String.t()] | nil}

  @typedoc "A page's position: the digest, collection, normalized filters and offset."
  @type page_cursor :: %{
          required(:digest) => String.t(),
          required(:collection) => String.t(),
          required(:filters) => map(),
          required(:offset) => non_neg_integer()
        }

  @doc """
  Serves one bounded page of a frozen payload.

  `payload` is an admitted payload map, `collection` the collection to page,
  `filters` the narrowing to apply and `cursor` the previous page's cursor or
  `nil` for the first. The result is
  `{:ok, %{rows: rows, total: total, next_cursor: cursor | nil, digest: digest}}`.

  The page is served from the payload alone: nothing here re-reads the day, so
  every page of one snapshot is the same historical evidence under the same
  `digest`, whatever the host has done since. Only the issues collection is
  served, at most 50 rows, sorted by severity, code, the issue's own ref and its
  canonical detail - a total order, so a row cannot move between pages. A page
  smaller than 50 is permitted when the encoded rows would exceed 32 KiB; a
  single row that cannot fit is `{:error, :unavailable}` rather than a truncated
  one, and `total` and `next_cursor` survive that narrowing.

  `page/5` is the same page with `reserve_bytes` held back from the 32 KiB
  budget: the bytes the caller's own envelope and evidence add around the page,
  measured by the caller. The rows then fit `32_768 - reserve_bytes`, and a
  reserve that leaves no room for the page - not even an empty one, or one row
  of a non-empty collection - is `{:error, :unavailable}`. `page/4` reserves
  nothing.

  `filters` narrows by an optional `code` the snapshot actually carries, an
  optional `severity`, and optional `run_refs` - at most 100 distinct refs, each
  of which must resolve to a run in *this* payload, so a ref outside the frozen
  scope or another snapshot's ref narrows nothing and is refused instead. Any
  other filter key is refused rather than ignored.

  A cursor must carry exactly the four fields above and match this payload's
  digest, this collection and these normalized filters, with a non-negative
  integer offset no greater than the filtered total. There is no store behind a
  cursor, so a mismatched, malformed or out-of-range one is
  `{:error, :unavailable}` exactly like a missing one.
  """
  @spec page(map(), String.t(), page_filters(), page_cursor() | nil) ::
          {:ok, map()} | {:error, :unavailable}
  def page(payload, collection, filters, cursor),
    do: page(payload, collection, filters, cursor, 0)

  @spec page(map(), String.t(), page_filters(), page_cursor() | nil, non_neg_integer()) ::
          {:ok, map()} | {:error, :unavailable}
  def page(payload, collection, filters, cursor, reserve_bytes)
      when is_map(payload) and is_binary(collection) and is_map(filters) and
             is_integer(reserve_bytes) and reserve_bytes >= 0 do
    with {:ok, issues} <- page_issues(payload, collection),
         {:ok, normalized} <- normalize_filters(filters, payload, issues),
         {:ok, rows} <- filtered_issues(issues, normalized),
         {:ok, offset} <- read_offset(cursor, payload, collection, normalized, length(rows)) do
      position = %{payload: payload, collection: collection, filters: normalized}
      serve(rows, offset, position, @max_page_bytes - reserve_bytes)
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  def page(_payload, _collection, _filters, _cursor, _reserve_bytes), do: {:error, :unavailable}

  defp page_issues(payload, @collection_issues) do
    with true <- Map.get(payload, "schema_version") == @schema_version,
         true <- is_binary(Map.get(payload, "source_digest")),
         true <- Map.get(payload, "source_digest") != "",
         issues when is_list(issues) <- Map.get(payload, "issues") do
      {:ok, issues}
    else
      _unavailable -> :error
    end
  end

  defp page_issues(_payload, _collection), do: :error

  # Filters are normalized to the keys this snapshot can act on, so a cursor
  # carries the same map the next call rebuilds. A filter naming a code the
  # snapshot does not carry is refused: an unknown code is a stale read, not an
  # empty result.
  defp normalize_filters(filters, payload, issues) do
    if Map.keys(filters) -- ["code", "severity", "run_refs"] == [] do
      with {:ok, code} <- normalize_code(Map.get(filters, "code"), issues),
           {:ok, severity} <- normalize_severity(Map.get(filters, "severity")),
           {:ok, run_refs} <- normalize_run_refs(Map.get(filters, "run_refs"), payload) do
        {:ok,
         %{
           "code" => code,
           "severity" => severity,
           "run_refs" => run_refs
         }}
      else
        :error -> :error
      end
    else
      :error
    end
  end

  defp normalize_code(nil, _issues), do: {:ok, nil}

  defp normalize_code(code, issues) when is_binary(code) do
    if Enum.any?(issues, &(&1["code"] == code)), do: {:ok, code}, else: :error
  end

  defp normalize_code(_code, _issues), do: :error

  defp normalize_severity(nil), do: {:ok, nil}

  defp normalize_severity(severity) when is_atom(severity),
    do: normalize_severity(Atom.to_string(severity))

  defp normalize_severity(severity) when is_binary(severity) do
    if Enum.any?(@severity_rank, fn {ranked, _rank} -> severity == Atom.to_string(ranked) end),
      do: {:ok, severity},
      else: :error
  end

  defp normalize_severity(_severity), do: :error

  defp normalize_run_refs(nil, _payload), do: {:ok, []}

  defp normalize_run_refs(run_refs, payload) when is_list(run_refs) do
    known = payload_run_refs(payload)

    if length(run_refs) <= 100 and Enum.all?(run_refs, &is_binary/1) and
         MapSet.size(MapSet.new(run_refs)) == length(run_refs) and
         Enum.all?(run_refs, &MapSet.member?(known, &1)) do
      {:ok, Enum.sort(run_refs)}
    else
      :error
    end
  end

  defp normalize_run_refs(_run_refs, _payload), do: :error

  # The run refs this snapshot actually holds. A blocks payload holds none, so
  # any run ref offered against one resolves to nothing and is refused.
  defp payload_run_refs(payload) do
    payload
    |> Map.get("entities")
    |> case do
      %{"runs" => runs} when is_list(runs) ->
        MapSet.new(runs, & &1["run_ref"])

      _other ->
        MapSet.new()
    end
  end

  defp filtered_issues(issues, filters) do
    rows =
      Enum.filter(issues, fn issue ->
        matches_code?(issue, filters["code"]) and
          matches_severity?(issue, filters["severity"]) and
          matches_run_refs?(issue, filters["run_refs"])
      end)

    {:ok, Enum.sort_by(rows, &issue_sort_key/1)}
  end

  defp matches_code?(_issue, nil), do: true
  defp matches_code?(issue, code), do: issue["code"] == code

  defp matches_severity?(_issue, nil), do: true
  defp matches_severity?(issue, severity), do: issue["severity"] == severity

  # A run ref narrows to the issues that name the run. An issue naming no run -
  # a garage shortfall, an orphan count - is not this run's, so it drops out.
  defp matches_run_refs?(_issue, []), do: true

  defp matches_run_refs?(issue, run_refs) do
    named = Map.get(issue, "run_refs", [])

    Enum.any?(run_refs, &(&1 in named))
  end

  # The total order a page is served in: severity, then code, then the issue's
  # own ref, then its canonical detail. Every component is deterministic, so two
  # pages of one snapshot cannot disagree about which row comes next.
  defp issue_sort_key(issue) do
    {Map.get(issue, "severity_rank", 3), issue["code"], issue["issue_ref"],
     :erlang.term_to_binary(issue["detail"], [:deterministic])}
  end

  # The first page has no cursor; every later one must match this snapshot, this
  # collection, these filters and land inside the filtered total.
  defp read_offset(nil, _payload, _collection, _filters, _total), do: {:ok, 0}

  defp read_offset(cursor, payload, collection, filters, total) when is_map(cursor) do
    with true <- Enum.sort(Map.keys(cursor)) == ["collection", "digest", "filters", "offset"],
         true <- Map.get(cursor, "digest") == payload["source_digest"],
         true <- Map.get(cursor, "collection") == collection,
         true <- Map.get(cursor, "filters") == filters,
         offset when is_integer(offset) and offset >= 0 and offset <= total <-
           Map.get(cursor, "offset") do
      {:ok, offset}
    else
      _unavailable -> :error
    end
  end

  defp read_offset(_cursor, _payload, _collection, _filters, _total), do: :error

  # Up to the limit, then narrowed until the encoded result fits `budget`: the
  # 32 KiB ceiling less the bytes the caller reserved for its own envelope and
  # evidence. The measured value is the whole result map, so the cursor and the
  # totals are inside the budget too.
  defp serve(rows, offset, position, budget) do
    total = length(rows)
    window = Enum.slice(rows, offset, @page_limit)

    case fit_rows(window, offset, total, position, budget) do
      {:ok, page_rows} ->
        next_cursor = next_cursor(offset + length(page_rows), total, position)
        {:ok, result(page_rows, total, next_cursor, position.payload)}

      :error ->
        {:error, :unavailable}
    end
  end

  # One row over the budget on its own is refused: a partial issue is a finding
  # the reader cannot act on, and silently dropping it would under-report. An
  # empty page that does not fit is refused too, because the reserve left no
  # room for any page at all.
  defp fit_rows(rows, offset, total, position, budget) do
    served = offset + length(rows)

    bytes =
      rows
      |> result(total, next_cursor(served, total, position), position.payload)
      |> Jason.encode!()
      |> byte_size()

    cond do
      bytes <= budget -> {:ok, rows}
      length(rows) > 1 -> fit_rows(Enum.drop(rows, -1), offset, total, position, budget)
      true -> :error
    end
  end

  defp next_cursor(next_offset, total, _position) when next_offset >= total, do: nil

  defp next_cursor(next_offset, _total, position) do
    %{
      "digest" => position.payload["source_digest"],
      "collection" => position.collection,
      "filters" => position.filters,
      "offset" => next_offset
    }
  end

  defp result(rows, total, next_cursor, payload) do
    %{rows: rows, total: total, next_cursor: next_cursor, digest: payload["source_digest"]}
  end
end

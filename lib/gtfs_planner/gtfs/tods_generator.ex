defmodule GtfsPlanner.Gtfs.TodsGenerator do
  @moduledoc """
  Read-only preview of one TODS generation request.

  `preview/2` answers "what would generating here add?" and writes nothing: no
  trip's `block_id`, no block attribute row, no roster row, no operator, no
  receipt. The save path is a different function added by a later step, and it
  refuses anything this one would have refused.

  ## Scope and order

    * `Authorization.authorize_editor/1` first. The actor's current membership
      decides whether they may read the version at all, and it is read before any
      other fact so a revoked editor is refused rather than served a plan.
    * `Gtfs.Export.with_read_snapshot/1` owns the read boundary. Every source fact
      below is read inside one repeatable-read snapshot, so a preview built from a
      schedule that changed halfway describes one committed revision rather than a
      mixture of two.
    * Published status is `Calendars.list_calendars/3`'s answer, which is the same
      check the day load makes: a staging, importing or failed version, and a
      version of another organization, are both `{:error, :not_found}`. "Published"
      here means imported and usable, never that a feed is publicly activated.
    * Day types and dates come from `Blocking.DayTypes.derive/1` over those
      calendars, and the selected inclusive range picks the day types holding a
      date in it. `Input.changeset/3` defaults an unnamed range to the feed's
      first active calendar week.
    * The scope is completed before anything is composed from it. Every trip
      sharing a block with a trip of a selected day type joins the read, and every
      day type those trips run on joins the set the checks read, so a block is a
      whole block and not the part of it the range happened to hold. The trip
      count of the admission bound is the count of that completed scope. Only the
      selected day types are days work is composed *on*; the wider set decides
      whether what was composed is valid there (AC-3, AC-5).

  ## Errors

  `{:error, :forbidden}` for a revoked or absent editor, `{:error, :not_found}`
  for a foreign or unusable version, `{:error, :missing_garages}` when the
  organization holds no usable garage, `{:error, {:too_large, count}}` above the
  3,000-distinct-trip admission bound, and `{:error, changeset}` for anything
  `TodsGenerator.Input` refuses.

  A garage UUID belonging to another organization, or to no one, is refused as a
  field error on the garage input: the preview cannot invent a garage, so the
  request names no fallback and no candidate is composed.

  ## The fingerprint

  `source_fingerprint/3` names the source facts a later save re-reads and compares
  before writing. It covers every affected day type with its services and dates,
  the trip rows with their endpoints, the raw stop-time, stop, parent-station and
  frequency rows behind them, the whole blocking context through its own
  `Context.digest/1`, the crew and roster rules, the stored trip-run assignments,
  the roster lines and their slots, and the organization's employee IDs. Every
  identity-keyed level is sorted and hashed with SHA-256 over
  `:erlang.term_to_binary/2`, so a row order cannot reach the hash and any changed
  fact changes it.
  """

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Blocking.Queries
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Rosters
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TodsGenerator.Input
  alias GtfsPlanner.Gtfs.TodsGenerator.Plan
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Versions

  # The admission bound of AC-3, and the same number `Blocking.suggest_blocks/4`
  # refuses a day type above. The count is of *distinct trips* in the completed
  # scope, not of day types or blocks: a trip shared by a weekday and a Saturday is
  # one trip however many days it runs, and counting it twice would refuse a
  # schedule inside the bound. A block's trip on a date outside the selected range
  # is counted too — completing the block is what makes the count the generator's
  # actual input.
  @max_distinct_trips 3_000

  @type preview :: %{
          normalized_inputs: map(),
          source_fingerprint: String.t(),
          blocks: [Plan.block()],
          assignments: %{Ecto.UUID.t() => String.t()},
          preserved_block_ids: [String.t()],
          exclusions: [Plan.exclusion()],
          counts: map(),
          day_type_keys: [String.t()],
          no_work?: boolean()
        }

  @doc """
  Returns the read-only candidate for one generation request, writing nothing.

  `params` are the five business inputs of `TodsGenerator.Input`; a request naming
  no dates defaults to the feed's first active calendar week. The result carries
  the normalized inputs, the source fingerprint a later save compares against, the
  block candidate, the run deltas and derived run days of the crew stage, the
  relief marks those runs would need, the warnings and assumptions they rest on,
  and the exclusions with their reasons.

  An empty service in the selected range is a result, not an error: it answers
  `{:ok, preview}` with `no_work?: true`, no blocks, no runs and no exclusions,
  because "this version has nothing to staff" is something a page must be able to
  say.
  """

  @spec preview(AuditContext.t(), map()) ::
          {:ok, preview()}
          | {:error,
             Ecto.Changeset.t()
             | :forbidden
             | :not_found
             | :missing_garages
             | {:too_large, non_neg_integer()}}
  def preview(%AuditContext{} = audit, params) do
    with :ok <- Authorization.authorize_editor(audit),
         :ok <- require_usable_version(audit),
         {:ok, result} <- Export.with_read_snapshot(fn -> read_preview(audit, params) end) do
      # `with_read_snapshot/1` wraps whatever the read returned as `{:ok, result}`,
      # so an error reason arrives nested and is lifted back out here rather than
      # in every caller.
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Published status is read before the snapshot opens, through the same
  # `Versions.published_gtfs_version_for_org?/2` the calendars read locks on. It is
  # a plain scoped query, where `Calendars.list_calendars/3` refuses an unusable
  # version by rolling its own read back — and inside the snapshot that rollback
  # would abort the whole boundary and report itself as `{:error, :rollback}`
  # rather than as the `:not_found` a page must show. The check is the same one,
  # asked in a way that composes with the snapshot around it.
  defp require_usable_version(%AuditContext{} = audit) do
    if Versions.published_gtfs_version_for_org?(audit.organization_id, audit.gtfs_version_id) do
      :ok
    else
      {:error, :not_found}
    end
  end

  defp read_preview(%AuditContext{} = audit, params) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    with {:ok, calendars} <- Calendars.list_calendars(organization_id, gtfs_version_id),
         dates = active_dates(calendars),
         {:ok, input} <- normalize(params, dates),
         {:ok, garage_id} <- resolve_garage(organization_id, input, dates),
         day_types <- selected_day_types(DayTypes.derive(calendars), input),
         {:ok, candidate} <- candidate(audit, day_types, input, garage_id) do
      {:ok, preview(candidate, input, garage_id)}
    end
  end

  defp normalize(params, active_dates) do
    %Input{}
    |> Input.changeset(params, active_dates)
    |> Input.normalize()
  end

  defp active_dates(calendars) do
    calendars
    |> Enum.flat_map(& &1.active_dates)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A day type is in generation scope when the selected inclusive range holds any
  # of its dates. A day type with no date in the range is not a smaller version of
  # the work; it is a different schedule the operator did not select. Day types
  # the *completed* blocks also reach are read through
  # `Blocking.candidate_input/3` and decide validity without being composed on.
  defp selected_day_types(day_types, input) do
    start_date = Date.from_iso8601!(input["start_date"])
    end_date = Date.from_iso8601!(input["end_date"])

    Enum.filter(day_types, fn day_type ->
      Enum.any?(day_type.dates, fn date ->
        Date.compare(date, start_date) != :lt and Date.compare(date, end_date) != :gt
      end)
    end)
  end

  defp resolve_garage(organization_id, input, active_dates) do
    garage_id = input["garage_id"]

    cond do
      Operations.planning_garages(organization_id) == %{} ->
        {:error, :missing_garages}

      is_nil(Operations.get_garage(organization_id, garage_id)) ->
        {:error, garage_changeset(input, garage_id, active_dates)}

      true ->
        {:ok, garage_id}
    end
  end

  # The refusal is a field error on the same five inputs the request came in as,
  # so a page renders it against the garage control rather than as a bare reason.
  # The dates are the same ones the request was defaulted against, so the form
  # does not lose them and the error is the only thing on the changeset.
  defp garage_changeset(input, garage_id, active_dates) do
    %Input{}
    |> Input.changeset(Map.merge(input, %{"garage_id" => garage_id}), active_dates)
    |> Ecto.Changeset.add_error(:garage_id, "must be a garage in this organization")
  end

  defp candidate(%AuditContext{} = audit, day_types, input, garage_id) do
    with {:ok, inputs} <-
           Blocking.candidate_input(
             audit.organization_id,
             audit.gtfs_version_id,
             Enum.map(day_types, & &1.key)
           ) do
      plan_from_inputs(audit, day_types, inputs, input, garage_id)
    end
  end

  @doc """
  Composes the candidate over `inputs` rather than reading them.

  This is the seam between the source loader and the pure `TodsGenerator.Plan`,
  and it is what a caller permuting source facts composes through: `inputs` is a
  `Blocking.candidate_input/3` result whose row lists may be in any order. The
  source is built from them, so the whole candidate and the fingerprint are the
  only things that come back — a row order that changed either of them would mean
  the composition depends on something other than the facts. Both stages are
  composed here, in the order a preview composes them: the blocks, then the crew
  on top of them.

  `day_types` are the day types the range selects and the ones the candidate may
  be composed on; the day types `inputs` carries are the wider set the completed
  blocks reach, which is what validity is decided over.

  The two facts `Blocking.candidate_input/3` does not read — the raw stop-time,
  stop, parent-station and frequency rows, and the crew, roster, trip-run, line
  and employee-ID rules — are read here, so a caller still gets one source per
  composed candidate rather than a candidate beside facts nothing compared.
  """
  @spec plan_from_inputs(AuditContext.t(), [map()], map(), map(), Ecto.UUID.t()) ::
          {:ok, {Plan.t(), map()}}
          | {:error, {:too_large, non_neg_integer()}}
  def plan_from_inputs(%AuditContext{} = audit, day_types, inputs, input, garage_id) do
    count = distinct_trip_count(inputs.rows_by_day_type)

    if count > @max_distinct_trips do
      {:error, {:too_large, count}}
    else
      source = source(audit, day_types, inputs, input, garage_id)
      candidate = Plan.block_candidate(source, input)

      {:ok, {Plan.with_runs(candidate, source, Map.fetch!(source, :input)), source}}
    end
  end

  @doc """
  Returns the number of distinct trips the completed scope holds.

  A trip on two day types is counted once: it is one trip however many days it
  runs, and counting it twice would refuse a schedule inside the bound. The rows
  are the ones `Blocking.candidate_input/3` completed, so a block's trip running
  on a date outside the selected range is counted too — it is one more trip the
  generator has to account for, not a smaller scope.
  """
  @spec distinct_trip_count(%{optional(String.t()) => [map()]}) :: non_neg_integer()
  def distinct_trip_count(rows_by_day_type) do
    rows_by_day_type
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> length()
  end

  # The candidate arrives composed: both stages are composed in
  # `plan_from_inputs/5`, which is the one seam a permutation of source facts goes
  # through, and this maps it into the preview a page reads. The fingerprint is
  # over the *source*, not over the candidate, so a mark the crew stage proposes
  # cannot change it: the same source and input still produce the same candidate
  # and the same hash.
  defp preview({candidate, source}, input, garage_id) do
    input = Map.put(input, "garage_id", garage_id)

    %{
      normalized_inputs: input,
      source_fingerprint: fingerprint(source, input, garage_id),
      blocks: candidate.blocks,
      assignments: candidate.assignments,
      preserved_block_ids: candidate.preserved_block_ids,
      run_deltas: candidate.run_deltas,
      run_days: candidate.run_days,
      relief_additions: candidate.relief_additions,
      assumptions: candidate.assumptions,
      warnings: candidate.warnings,
      exclusions: candidate.exclusions,
      counts: candidate.counts,
      day_type_keys: candidate.day_type_keys,
      # `no_work?` is about what generating here would write: a preview that only
      # preserves blocks the database already has, or that only reports exclusions,
      # adds nothing and says so. `counts.blocks` is the blocks the candidate
      # presents — preserved ones included — so it is not this question's answer.
      no_work?:
        candidate.blocks == [] and candidate.assignments == %{} and candidate.counts.new_runs == 0
    }
  end

  # --- source ----------------------------------------------------------------

  defp source(%AuditContext{} = audit, day_types, inputs, input, garage_id) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    inputs
    |> Map.put(:day_types, day_types)
    |> Map.put(:fact_rows, fact_rows(organization_id, gtfs_version_id, inputs))
    |> Map.put(:rules, rule_facts(organization_id, gtfs_version_id))
    |> Map.put(:input, Map.put(input, "garage_id", garage_id))
  end

  # The requested day types *and* the affected day types the completed blocks
  # reach, with the raw rows behind the derived trip facts: the endpoint stop
  # times, their stops and parent stations, and the frequency rows. A retiming, a
  # same-count endpoint replacement, a moved stop or a second headway window all
  # change what a candidate is built from, so they belong in the fingerprint
  # rather than hiding behind the derived numbers. The affected day types are read
  # from `inputs` because the scope itself depends on them: a calendar change that
  # moved a block's other date into another day type would change which days a new
  # chain has to be valid on.
  defp fact_rows(organization_id, gtfs_version_id, inputs) do
    trip_ids = inputs.rows_by_day_type |> Map.values() |> List.flatten() |> Enum.map(& &1.id)

    %{
      day_types:
        Enum.map(inputs.day_types, fn day_type ->
          %{
            key: day_type.key,
            service_ids: day_type.service_ids,
            dates: Enum.map(day_type.dates, &Date.to_iso8601/1)
          }
        end),
      raw: Queries.raw_sources(organization_id, gtfs_version_id, Enum.uniq(trip_ids))
    }
  end

  # The rules a later save re-reads and this preview cannot change. The blocking
  # settings, garages, vehicle types, route settings, block attributes, entered
  # driving times, relief points, fleet and per-trip distances are not repeated
  # here: `Context.digest/1` already covers every field of them, and a second
  # projection of the same rows could only agree by accident.
  defp rule_facts(organization_id, gtfs_version_id) do
    %{
      crew: Runs.get_crew_settings(organization_id, gtfs_version_id),
      roster: Rosters.get_roster_settings(organization_id, gtfs_version_id),
      trip_runs: Runs.assignments_by_day_type(organization_id, gtfs_version_id),
      roster_lines: Rosters.export_line_facts(organization_id, gtfs_version_id),
      employee_ids: employee_id_facts(organization_id)
    }
  end

  defp employee_id_facts(organization_id) do
    organization_id
    |> Operations.list_operators()
    |> Enum.map(& &1.employee_id)
    |> Enum.sort()
  end

  # --- fingerprint -----------------------------------------------------------

  @doc """
  Returns the canonical source fingerprint of one preview's source.

  Exposed as a public function so the step that applies a reviewed candidate
  compares hashes produced by this one function, rather than two
  implementations agreeing by coincidence.

  It covers the normalized input, every affected day type with its services and
  dates, the completed trip rows with their endpoints, the raw stop-time, stop,
  parent-station and frequency rows behind them, the block IDs the affected
  services use — a wider read than the completed rows, which reaches the blocks a
  new ID is numbered above — the blocking context through its own digest, and the
  crew and roster rules.
  """
  @spec fingerprint(map(), map(), Ecto.UUID.t()) :: String.t()
  def fingerprint(source, input, garage_id) do
    facts = Map.fetch!(source, :fact_rows)

    %{
      input: Map.put(input, "garage_id", garage_id),
      day_types: facts.day_types,
      rows: identity_rows(source),
      used_block_ids: Enum.sort(Map.fetch!(source, :used_block_ids)),
      raw: facts.raw,
      context: Context.digest(Map.fetch!(source, :context)),
      rules: rules_projection(Map.fetch!(source, :rules))
    }
    |> canonical()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # One row per trip, keyed by UUID and sorted, so the order the source was read
  # in cannot reach the hash. `updated_at` is deliberately absent: a retiming
  # changes the times themselves, and a write that changed nothing a candidate
  # reads must not refuse a save over a preview of unchanged facts.
  defp identity_rows(source) do
    source.rows_by_day_type
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(fn row ->
      Map.take(row, [
        :id,
        :trip_id,
        :route_id,
        :service_id,
        :block_id,
        :direction_id,
        :first_arrival,
        :first_departure,
        :last_arrival,
        :last_departure,
        :frequency?,
        :headway_secs,
        :plottable?,
        :first_stop,
        :last_stop
      ])
    end)
    |> Enum.sort_by(& &1.id)
  end

  # The trip-run assignments are a map of maps keyed by tuples, and the roster
  # lines are a list whose days arrive in weekday order only because one reader
  # asked for it. Both are normalized here so a rule read that gains a member
  # cannot change the hash by changing its order.
  defp rules_projection(rules) do
    rules
    |> Map.update!(:trip_runs, fn assignments ->
      Map.new(assignments, fn {key, pairs} -> {key, pairs |> Map.to_list() |> Enum.sort()} end)
    end)
    |> Map.update!(:roster_lines, fn lines ->
      lines
      |> Enum.map(fn line ->
        %{
          line_number: line.line_number,
          operator_id: line.operator_id,
          days:
            line.days
            |> Enum.sort_by(&{&1.weekday, &1.day_type_key, &1.run_id})
            |> Enum.map(fn day ->
              %{
                weekday: day.weekday,
                day_type_key: day.day_type_key,
                run_id: day.run_id,
                times: {day.run_sign_on_secs, day.run_sign_off_secs}
              }
            end)
        }
      end)
      |> Enum.sort_by(&{&1.line_number, &1.operator_id})
    end)
  end

  # The same canonicalization `Blocking.Context.digest/1` uses, for the parts of
  # the source that context does not own: tuple keys no stringified-key encoding
  # can carry, `MapSet` members as their members, and a decimal as its normalized
  # value rather than its stored scale.
  defp canonical(%Decimal{} = value),
    do: {:decimal, value |> Decimal.normalize() |> Decimal.to_string(:normal)}

  defp canonical(%MapSet{} = value), do: {:mapset, value |> MapSet.to_list() |> canonical()}

  defp canonical(%_{} = value), do: value |> Map.from_struct() |> canonical()

  defp canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {canonical(key), canonical(entry)} end)
    |> Enum.sort()
  end

  defp canonical(value) when is_list(value), do: Enum.map(value, &canonical/1)

  defp canonical(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&canonical/1) |> List.to_tuple()
  end

  defp canonical(value), do: value
end

defmodule GtfsPlanner.Gtfs.TodsGenerator do
  @moduledoc """
  Reads and applies one TODS generation request.

  `preview/2` answers "what would generating here add?" and writes nothing: no
  trip's `block_id`, no block attribute row, no roster row, no operator, no
  receipt. `apply/2` writes one reviewed answer of it — once, inside one
  serializable transaction — and `completed/2` reads back the receipt that
  records the outcome.

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

  `fingerprint/3` names the source facts the save re-reads and compares before
  writing. It covers every affected day type with its services and dates,
  the trip rows with their endpoints, the raw stop-time, stop, parent-station and
  frequency rows behind them, the whole blocking context through its own
  `Context.digest/1`, the crew and roster rules, the stored trip-run assignments,
  the roster lines and their slots, and the organization's employee IDs. Every
  identity-keyed level is sorted and hashed with SHA-256 over
  `:erlang.term_to_binary/2`, so a row order cannot reach the hash and any changed
  fact changes it.

  ## The save

  `apply/2` takes the preview's normalized input and fingerprint as its transport
  facts and makes the request durable. One retry owner runs at most three
  attempts of `ReviewedApplyTransaction.adapter().run/2` at SERIALIZABLE
  isolation; a transient serialization failure or deadlock is retried, every
  other refusal is reported, and an exception becomes `:write_failed` with its
  detail logged. Each attempt locks the editor membership first, then the scoped
  published version, `Blocking.lock_blocking!/1`, the affected trips in UUID
  order and the organization's planning garages and vehicle types `FOR SHARE`;
  then it re-reads the source inside that transaction, rebuilds the candidate and
  compares the fingerprint, so only the reviewed candidate can be written.

  The receipt is checked before the fingerprint: a scoped request already
  completed with this input answers with its original receipt even though its own
  writes changed the source, and one completed with a different input is
  `:request_conflict`. That check is also what makes a lost reply, a retried tab
  and two connections racing one token commit once.
  """

  require Logger

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.Blocking.Context
  alias GtfsPlanner.Gtfs.Blocking.DayTypes
  alias GtfsPlanner.Gtfs.Blocking.Queries
  alias GtfsPlanner.Gtfs.Calendars
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Rosters
  alias GtfsPlanner.Gtfs.Runs
  alias GtfsPlanner.Gtfs.TodsGeneration
  alias GtfsPlanner.Gtfs.TodsGenerator.Input
  alias GtfsPlanner.Gtfs.TodsGenerator.Plan
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo
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
          run_deltas: %{String.t() => %{Ecto.UUID.t() => String.t()}},
          run_days: %{String.t() => Runs.Day.derived()},
          relief_additions: [String.t()],
          roster_day_types: %{String.t() => String.t()},
          roster_lines: [Plan.roster_line()],
          roster_exclusions: [Plan.roster_exclusion()],
          roster_findings: [Plan.roster_finding()],
          hard_errors: [Plan.hard_error()],
          coverage: Plan.coverage(),
          assumptions: [atom()],
          warnings: [Plan.run_warning()],
          exclusions: [Plan.exclusion()],
          counts: map(),
          day_type_keys: [String.t()],
          no_work?: boolean(),
          save_available?: boolean()
        }

  @doc """
  Returns the read-only candidate for one generation request, writing nothing.

  `params` are the five business inputs of `TodsGenerator.Input`; a request naming
  no dates defaults to the feed's first active calendar week. The result carries
  the normalized inputs, the source fingerprint a later save compares against, the
  block candidate, the run deltas and derived run days of the crew stage, the
  relief marks those runs would need, the base-week choices, single-slot lines and
  fictional operators the roster stage would add, the run-days it leaves unstaffed,
  the recurring coverage it reaches, the warnings and assumptions they rest on, and
  the exclusions with their reasons. `hard_errors` are the plan-level conflicts that
  make a save unavailable, and `save_available?` is the whole rule: no hard error,
  and at least one record to add.

  An empty service in the selected range is a result, not an error: it answers
  `{:ok, preview}` with `no_work?: true`, no blocks, no runs, no lines and no
  exclusions, because "this version has nothing to staff" is something a page must
  be able to say.
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
    with {:ok, {day_types, inputs, input, garage_id}} <- read_source(audit, params),
         {:ok, {candidate, source}} <-
           plan_from_inputs(audit, day_types, inputs, input, garage_id) do
      {:ok, preview({candidate, source}, input, garage_id)}
    end
  end

  # The one source loader both read paths use: the preview runs it inside its
  # repeatable-read snapshot, and a save runs the same function inside the
  # serializable transaction it already owns, so neither nests the other's
  # boundary. What it returns is everything both need to compose: the selected day
  # types, the completed candidate inputs, the canonical input and the resolved
  # garage.
  defp read_source(%AuditContext{} = audit, params) do
    organization_id = audit.organization_id
    gtfs_version_id = audit.gtfs_version_id

    with {:ok, calendars} <- Calendars.list_calendars(organization_id, gtfs_version_id),
         dates = active_dates(calendars),
         {:ok, input} <- normalize(params, dates),
         {:ok, garage_id} <- resolve_garage(organization_id, input, dates),
         day_types <- selected_day_types(DayTypes.derive(calendars), input),
         {:ok, inputs} <-
           Blocking.candidate_input(
             organization_id,
             gtfs_version_id,
             Enum.map(day_types, & &1.key)
           ) do
      {:ok, {day_types, inputs, input, garage_id}}
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

      {:ok,
       {Plan.with_roster(
          Plan.with_runs(candidate, source, Map.fetch!(source, :input)),
          source,
          Map.fetch!(source, :input)
        ), source}}
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

  # The candidate arrives composed: all three stages are composed in
  # `plan_from_inputs/5`, which is the one seam a permutation of source facts goes
  # through, and this maps it into the preview a page reads. The fingerprint is
  # over the *source*, not over the candidate, so a mark the crew stage proposes or
  # a line the roster stage proposes cannot change it: the same source and input
  # still produce the same candidate and the same hash.
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
      roster_day_types: candidate.roster_day_types,
      roster_lines: candidate.roster_lines,
      roster_exclusions: candidate.roster_exclusions,
      roster_findings: candidate.roster_findings,
      hard_errors: candidate.hard_errors,
      coverage: candidate.coverage,
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
        candidate.blocks == [] and candidate.assignments == %{} and
          candidate.counts.new_runs == 0 and candidate.counts.new_lines == 0,
      # A save is unavailable with a hard error or with nothing to add: the first
      # is a request the plan cannot deliver without editing a choice the operator
      # owns, and the second would commit a receipt over no work at all.
      save_available?: candidate.hard_errors == [] and additions?(candidate.counts)
    }
  end

  # A move is an addition the save writes even when it lands in a block the
  # version already has and needs no new block, run or line, so `new_assignments`
  # is one of the terms rather than being implied by `new_blocks`.
  defp additions?(counts) do
    counts.new_blocks + counts.new_assignments + counts.new_runs + counts.new_lines > 0
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
      # Every day type the version derives, not only the affected ones: the roster
      # stage resolves each weekday's base day type against them, so adding,
      # removing or redating a day type no completed row reaches can change which
      # day type a saved slot is stored for.
      version_day_types:
        Enum.map(Map.fetch!(inputs, :version_day_types), fn day_type ->
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
  dates, every day type the version derives, the completed trip rows with their
  endpoints, the raw stop-time, stop, parent-station and frequency rows behind
  them, the block IDs the affected services use — a wider read than the completed
  rows, which reaches the blocks a new ID is numbered above — the blocking context
  through its own digest, and the crew and roster rules.
  """
  @spec fingerprint(map(), map(), Ecto.UUID.t()) :: String.t()
  def fingerprint(source, input, garage_id) do
    facts = Map.fetch!(source, :fact_rows)

    %{
      input: Map.put(input, "garage_id", garage_id),
      day_types: facts.day_types,
      version_day_types: facts.version_day_types,
      rows: identity_rows(source),
      used_block_ids: Enum.sort(Map.fetch!(source, :used_block_ids)),
      raw: facts.raw,
      context: Context.digest(Map.fetch!(source, :context)),
      rules: rules_projection(Map.fetch!(source, :rules))
    }
    # Both halves go through `Context.canonical/1`, the form `Context.digest/1`
    # hashes: the digest above covers the source facts a context owns, and this
    # map adds the ones it does not, so one owner canonicalizes all of them.
    |> Context.canonical()
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

  # --- apply -----------------------------------------------------------------

  # The prepared retry bound and the trusted transaction timeout. Three complete
  # attempts is what a serializable writer needs to lose a race, see the winner's
  # receipt and answer it; the timeout is the whole transaction's, not one query's.
  @apply_attempts 3
  @apply_timeout 120_000

  # `Blocking` reads the same literal for the same reason: `lock_for_input_write!/2`
  # locks staging, importing and failed versions exactly like published ones, so the
  # published check is the caller's own.
  @published_status "published"

  @typedoc """
  Every refusal `apply/2` can answer with: a refused business input, a revoked or
  absent editor, a foreign or unusable version, a missing garage or an over-bound
  scope the attempt's own re-read answers, a source that no longer matches the
  reviewed fingerprint, a scoped request already completed with a different input,
  a candidate with nothing to add, three exhausted attempts, a change log the
  transaction refused, or a write that failed for a reason no retry can fix.

  Two of them are the preview's own admission refusals, because an attempt re-reads
  the source through the same loader and candidate composition the preview uses: a
  range admitted when it was previewed can lose the organization's last garage
  (`:missing_garages`) or grow past the 3,000-distinct-trip bound
  (`{:too_large, count}`) before it is saved. `{:audit_failed, reason}` is the moved
  trips' change log, which the block writer rolls back to its caller as its own
  documented refusal.
  """
  @type apply_error ::
          Ecto.Changeset.t()
          | :forbidden
          | :not_found
          | :missing_garages
          | :stale_plan
          | :request_conflict
          | :nothing_to_save
          | :busy
          | {:audit_failed, term()}
          | :write_failed
          | {:too_large, non_neg_integer()}

  @doc """
  Applies one reviewed preview once and returns its completed receipt.

  `request` carries the transport facts of one request: the `:request_id` UUID the
  page generated for the preview, the `:input` map `preview/2` normalized, and the
  `:source_fingerprint` it reported. The input is re-validated here rather than
  trusted, because a save is the one path that writes from a client round trip.

  The write is owned by one retry loop of at most three SERIALIZABLE transactions.
  Each attempt locks the current editor membership, the scoped published version,
  `Blocking.lock_blocking!/1`, the affected trips in UUID order and the
  organization's planning garages and vehicle types `FOR SHARE`; re-reads every
  source fact and rebuilds the candidate under those locks; and refuses with
  `:stale_plan` when the source fingerprint no longer matches the reviewed one.
  Only then does it write, through the transaction-local owners of the block, run
  and roster stages, and it writes the receipt last, so a generation and its
  durable provenance commit together or not at all.

  A scoped request already completed with this input answers with its original
  receipt before any source fact is read, which is what makes a lost reply, a
  retried tab and two connections racing one token commit once. A completed
  request with a different input is `:request_conflict`. A transient serialization
  failure or deadlock is retried; anything else is reported, and an exception is
  logged and answered `:write_failed` instead of escaping to the caller.

  That re-read is the preview's own loader and candidate composition, so the two
  admission refusals a preview answers arrive here too: `:missing_garages` when the
  organization holds no usable garage, and `{:too_large, count}` when the completed
  scope is above the admission bound. They are members of the refusal union,
  because a range admitted when it was previewed can be above the bound by the time
  it is saved. A change log of the moved trips that the transaction refuses is
  `{:audit_failed, reason}`, the reason the block writer's own plan reports it with.
  """
  @spec apply(AuditContext.t(), map()) :: {:ok, TodsGeneration.t()} | {:error, apply_error()}
  def apply(
        %AuditContext{} = audit,
        %{request_id: request_id, input: input, source_fingerprint: fingerprint}
      )
      when is_map(input) and is_binary(fingerprint) do
    case Ecto.UUID.cast(request_id) do
      {:ok, request_id} -> run_apply(audit, request_id, input, fingerprint, @apply_attempts)
      :error -> {:error, :not_found}
    end
  end

  def apply(%AuditContext{}, _request), do: {:error, :not_found}

  @doc """
  Returns the completed receipt of one scoped request, authorizing the caller first.

  The lookup is scoped to the audit's organization and version and the request
  UUID, so a receipt of another scope is `{:error, :not_found}` rather than
  disclosed. A revoked or absent editor is `{:error, :forbidden}`. This reads only:
  an unknown request never creates a receipt, and a caller asking about a request it
  never started learns nothing.
  """
  @spec completed(AuditContext.t(), Ecto.UUID.t()) ::
          {:ok, TodsGeneration.t()} | {:error, :forbidden | :not_found}
  def completed(%AuditContext{} = audit, request_id) do
    with :ok <- Authorization.authorize_editor(audit),
         {:ok, request_id} <- Ecto.UUID.cast(request_id),
         %TodsGeneration{} = receipt <-
           receipt(audit.organization_id, audit.gtfs_version_id, request_id) do
      {:ok, receipt}
    else
      {:error, :forbidden} -> {:error, :forbidden}
      _other -> {:error, :not_found}
    end
  end

  defp receipt(organization_id, gtfs_version_id, request_id) do
    Repo.get_by(TodsGeneration,
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      request_id: request_id
    )
  end

  # The retry owner. An attempt is one complete transaction; a failure is answered
  # in the receipt's terms before the retry decision, because another attempt or
  # another connection may already have committed this scoped request.
  defp run_apply(audit, request_id, params, fingerprint, attempts) do
    case canonical_input(params) do
      {:ok, input} -> attempt_apply(audit, request_id, input, fingerprint, attempts)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp attempt_apply(audit, request_id, input, fingerprint, attempts) do
    case run_transaction(fn -> write_attempt(audit, request_id, input, fingerprint) end) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> resolve_failure(reason, audit, request_id, input, fingerprint, attempts)
    end
  end

  defp resolve_failure(reason, audit, request_id, input, fingerprint, attempts) do
    case completed_input(audit, request_id, input) do
      {:ok, receipt} ->
        {:ok, receipt}

      :conflict ->
        {:error, :request_conflict}

      :error ->
        cond do
          not retryable_attempt?(reason) -> {:error, reason}
          attempts > 1 -> attempt_apply(audit, request_id, input, fingerprint, attempts - 1)
          true -> {:error, :busy}
        end
    end
  end

  # `:duplicate_request` is this writer's own name for a receipt another connection
  # committed while it planned; both it and a serialization failure are worth
  # another attempt.
  defp retryable_attempt?(reason),
    do: reason == :duplicate_request or Repo.retryable_conflict?(reason)

  # The committed receipt of `request_id` when its stored input is `input`, or
  # `:conflict` when a receipt exists for another input. An absent or unauthorized
  # request is `:error`, which leaves the attempt's own reason standing.
  defp completed_input(audit, request_id, input) do
    case completed(audit, request_id) do
      {:ok, receipt} -> if receipt.normalized_inputs == input, do: {:ok, receipt}, else: :conflict
      {:error, _reason} -> :error
    end
  end

  # The configured transaction boundary, with the trusted timeout. A transient SQL
  # error reaches the retry as an error tuple; every other exception is logged with
  # its stacktrace and reported as `:write_failed`, so a page never sees a raise.
  defp run_transaction(transaction) do
    ReviewedApplyTransaction.adapter().run(transaction, timeout: @apply_timeout)
  rescue
    error in Postgrex.Error ->
      if Repo.retryable_conflict?(error),
        do: {:error, error},
        else: {:error, log_write_failed(error, __STACKTRACE__)}

    error ->
      {:error, log_write_failed(error, __STACKTRACE__)}
  end

  defp log_write_failed(error, stacktrace) do
    Logger.error([
      "[tods_generator] generation write failed: ",
      Exception.format(:error, error, stacktrace)
    ])

    :write_failed
  end

  # One attempt inside the caller's SERIALIZABLE transaction, in the prepared lock
  # order: the current editor membership first (and never an organization write lock
  # after it), the scoped published version second, `Blocking.lock_blocking!/1`
  # third. A completed receipt then answers before any source fact is read, so a lost
  # reply costs one scoped read rather than a regeneration.
  defp write_attempt(audit, request_id, input, fingerprint) do
    Authorization.lock_editor!(audit)
    require_published_version!(audit)
    :ok = Blocking.lock_blocking!(audit.gtfs_version_id)

    case receipt(audit.organization_id, audit.gtfs_version_id, request_id) do
      %TodsGeneration{} = stored -> stored_or_conflict!(stored, input)
      nil -> write_generation(audit, request_id, input, fingerprint)
    end
  end

  defp require_published_version!(%AuditContext{} = audit) do
    version = Versions.lock_for_input_write!(audit.organization_id, audit.gtfs_version_id)

    if version.publication_status != @published_status do
      Repo.rollback(:not_found)
    end

    version
  end

  # A completed request answers with its own receipt whatever this attempt would
  # have composed, and a different input under the same scoped token is refused.
  defp stored_or_conflict!(receipt, input) do
    if receipt.normalized_inputs == input do
      receipt
    else
      Repo.rollback(:request_conflict)
    end
  end

  # The source is read once to learn the rows to lock and once more under those
  # locks, so the candidate the fingerprint describes is the one built from the
  # locked rows rather than from a read the locks never covered.
  defp write_generation(audit, request_id, input, fingerprint) do
    case read_source(audit, input) do
      {:ok, {_day_types, inputs, _input, _garage_id}} -> lock_source!(audit, inputs)
      {:error, reason} -> Repo.rollback(reason)
    end

    with {:ok, {day_types, inputs, _input, garage_id}} <- read_source(audit, input),
         {:ok, {candidate, source}} <-
           plan_from_inputs(audit, day_types, inputs, input, garage_id) do
      refuse_unwritable!(candidate, source, input, garage_id, fingerprint)

      block_result =
        Blocking.apply_generation_in_transaction!(
          audit,
          %{assignments: candidate.assignments, blocks: candidate.blocks},
          candidate.relief_additions
        )

      run_result = Runs.apply_generation_in_transaction!(audit, candidate.run_deltas)

      roster_result =
        Rosters.apply_generation_in_transaction!(
          audit,
          candidate.roster_day_types,
          candidate.roster_lines,
          operators_by_ordinal(candidate.roster_lines, request_id)
        )

      insert_receipt(
        audit,
        request_id,
        input,
        fingerprint,
        candidate,
        block_result,
        run_result,
        roster_result
      )
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The prepared lock order: the affected trips in UUID order, then the
  # organization's planning garages and vehicle types in UUID order. Garage and type
  # edits take no blocking lock, so these scoped row locks plus the serializable
  # reads close that boundary.
  defp lock_source!(%AuditContext{} = audit, inputs) do
    trip_ids =
      inputs.rows_by_day_type
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    Queries.lock_trips!(audit.organization_id, audit.gtfs_version_id, trip_ids, [], [])
    Operations.lock_planning_rows!(audit.organization_id)
    :ok
  end

  # The reviewed fingerprint and the candidate's own validation, both before the
  # first write. A source that changed under the reader is `:stale_plan`; a candidate
  # that adds nothing is `:nothing_to_save`. A hard error with a matching fingerprint
  # is a request the preview already refused to save (`save_available?`), so it is
  # refused here too rather than written as a partial outcome.
  defp refuse_unwritable!(candidate, source, input, garage_id, fingerprint) do
    cond do
      fingerprint(source, input, garage_id) != fingerprint -> Repo.rollback(:stale_plan)
      candidate.hard_errors != [] -> Repo.rollback(:stale_plan)
      not additions?(candidate.counts) -> Repo.rollback(:nothing_to_save)
      true -> :ok
    end
  end

  # The receipt is the last write of the attempt and the only durable record of what
  # committed: the request identity, the input and fingerprint it was planned
  # against, the ids the writes created and the counts a page reports. It carries no
  # reversible history semantics of its own — the block writes are audited by the
  # existing audit owner, and the receipt is the cross-domain provenance for the
  # roster and operator rows beside them.
  defp insert_receipt(
         audit,
         request_id,
         input,
         fingerprint,
         candidate,
         block_result,
         run_result,
         roster_result
       ) do
    operator_ids = operator_ids(audit, roster_result.line_ids)

    changeset =
      TodsGeneration.completion_changeset(%TodsGeneration{}, %{
        organization_id: audit.organization_id,
        gtfs_version_id: audit.gtfs_version_id,
        actor_id: audit.actor_id,
        request_id: request_id,
        normalized_inputs: input,
        source_fingerprint: fingerprint,
        created_ids: %{
          "block_ids" => Enum.map(candidate.blocks, & &1.block_id),
          "changed_trip_ids" => block_result.changed_trip_ids,
          "run_ids" => run_result.run_ids,
          "relief_stop_ids" => block_result.relief_stop_ids,
          "line_ids" => roster_result.line_ids,
          "slot_ids" => roster_result.slot_ids,
          "operator_ids" => operator_ids,
          "settings_changes" => roster_result.settings_changes
        },
        summary: summary(candidate, block_result, run_result, roster_result, operator_ids)
      })

    case Repo.insert(changeset, mode: :savepoint) do
      {:ok, receipt} ->
        receipt

      {:error, refused} ->
        # A duplicate here is another connection that committed this scoped request
        # while this attempt planned. The rollback undoes this attempt's writes; the
        # retry owner answers with the receipt that connection stored.
        if duplicate_request?(refused) do
          Repo.rollback(:duplicate_request)
        else
          Repo.rollback(refused)
        end
    end
  end

  defp duplicate_request?(changeset) do
    Enum.any?(changeset.errors, fn
      {:request_id, {_message, options}} -> options[:constraint] == :unique
      _other_error -> false
    end)
  end

  defp summary(candidate, block_result, run_result, roster_result, operator_ids) do
    %{
      "blocks" => length(candidate.blocks),
      "assignments" => map_size(candidate.assignments),
      "changed_trips" => length(block_result.changed_trip_ids),
      "runs" => run_result.changed_trips,
      "lines" => length(roster_result.line_ids),
      "slots" => length(roster_result.slot_ids),
      "operators" => length(operator_ids),
      "relief_marks" => length(block_result.relief_stop_ids),
      "base_choices" => map_size(roster_result.settings_changes)
    }
  end

  # Each created line's operator, in the order the roster writer reported the lines.
  # The roster facts are the version's own read, so the receipt names the ids the
  # writer actually stored rather than one this module guessed.
  defp operator_ids(%AuditContext{} = audit, line_ids) do
    by_line =
      audit.organization_id
      |> Rosters.export_line_facts(audit.gtfs_version_id)
      |> Map.new(&{&1.id, &1.operator_id})

    Enum.map(line_ids, &Map.fetch!(by_line, &1))
  end

  # The fictional operator one proposal's ordinal is created as. The employee ID
  # carries the request UUID, so two requests cannot collide, and it stays inside
  # the column's 64 characters.
  defp operators_by_ordinal(line_proposals, request_id) do
    Map.new(line_proposals, fn proposal ->
      ordinal = proposal.operator_ordinal
      number = ordinal_number(ordinal)

      {ordinal,
       %{
         employee_id: "DEMO-#{request_id}-#{number}",
         display_name: "Demo operator #{number}"
       }}
    end)
  end

  defp ordinal_number(ordinal), do: String.pad_leading(Integer.to_string(ordinal), 3, "0")

  # The canonical form of the request's input. `apply/2` is handed the map
  # `preview/2` normalized, so this validates rather than defaults: a request naming
  # no date, no garage or a non-Monday week is the changeset error it would have been
  # at preview time.
  defp canonical_input(params) do
    %Input{}
    |> Input.changeset(params, [])
    |> Input.normalize()
  end
end

defmodule GtfsPlanner.Gtfs.ConnectionComparison do
  @moduledoc """
  Loads the exact native evidence an A37 connection comparison is allowed to
  claim, for one approved pair set, inside one read-only snapshot.

  `load/3` is a read. It takes the server-owned organization and version, an
  explicit civil service date and the pairs a host expressly approved, and
  returns `%{scope:, service_date:, approved_route_ids:, rows:, totals:, digest:}`.
  Every row carries the two endpoints' resolved identities, the exact occurrence
  clocks, each endpoint's own civil date, its agency zone, and the stored
  minimum that applies with its row provenance (CR-4). The numbers here are
  server-owned; nothing in this module reads model text.

  ## Contracts

    * Organization and version come from `scope` only. A route, trip or stop
      named by a pair is resolved inside them, so a foreign or other-version
      reference is `{:error, :not_found}` rather than another tenant's rows.
    * `pairs` are `%{id: String.t(), from: endpoint, to: endpoint, minimum: ...}`
      where an `endpoint` is
      `%{route_id: uuid, trip_id: uuid, stop_id: String.t(), stop_sequence:
      non_neg_integer, service_date_offset: non_neg_integer}`. The ids are this
      application's route and trip rows; the stop is the natural GTFS stop id.
      An occurrence is the exact `(stop, stop_sequence)` pair inside the named
      trip, so a loop's second visit is a different occurrence and is never
      substituted for the requested one.
    * The refusal set is `:invalid_input` (a value that is not the documented
      shape, a duplicate pair id, a negative offset), `:not_found` (a reference
      outside the scope, or a trip that is not on its named route), `:too_many`
      (more than #{500} pairs, more than two approved endpoint routes, or more
      examined stop-time occurrences than
      `ServiceQueries.examined_occurrence_limit/0`) and `:unavailable` (the
      read itself could not be completed). Every refusal happens before a
      complete answer is returned, and none of them writes a row.
    * Only the routes the pairs themselves name are read, and a request naming
      more than two of them is refused. A route added to the request is not an
      approved comparison: the endpoint route set is the approved set.
    * Service is evaluated per endpoint with `Calendars.ServiceDates` over the
      scoped weekly row and exceptions, against that endpoint's own civil date
      (`service_date` + its own `service_date_offset`). An unreadable calendar
      is reported as `:unreadable_calendar` beside the row, never as absent
      service, and each endpoint keeps its offset so a later comparison can
      refuse to subtract two different date bases.
    * The agency zone comes from the native rule `ServiceQueries` uses: the
      route's own agency when it names one, otherwise the sole scoped agency. An
      ambiguous, invalid or missing zone is reported as
      `:timezone_unavailable` beside the row rather than falling back to UTC.
    * The minimum is the stored general (types 0-3) rule with the best
      `Transfers.Overlaps` rank whose coverage contains each endpoint stop and
      whose route/trip selectors match that endpoint. Coverage is the native R2
      expansion: a station covers itself and its direct children with a location
      type of nil or 0. A best-ranked type 3 prohibits, equal-best rules with
      differing effects are reported as `:conflicting`, and a best-ranked type 2
      supplies `min_transfer_time` with its row id, rank and revision. Type 0/1
      leaves the minimum absent unless the pair carried an explicit supplied
      minimum. A supplied minimum is used only when the stored policy leaves it
      undetermined, and it never erases a prohibition or a conflict.

  Every source read of one answer happens in the configured
  `ServiceQueries.Snapshot` transaction (`ServiceQueries.Snapshot.Repo` in
  production), so a controlled writer that commits between two of these reads
  cannot make the rows, the minimum and the digest describe different database
  states. The transaction closes before the snapshot is returned, so a caller
  that then waits on a provider holds no lock.

  `compare/4` adds the margin arithmetic on top of that snapshot and reads
  nothing of its own: every number it reports is arithmetic over rows this
  module already loaded (CR-4). It is deliberately a pure step - a caller that
  approved a candidate against an older snapshot is refused with `:stale`
  rather than silently compared against the current one.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.CalendarDate
  alias GtfsPlanner.Gtfs.Calendars.ServiceDates
  alias GtfsPlanner.Gtfs.Frequency
  alias GtfsPlanner.Gtfs.GtfsTime
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.ServiceQueries
  alias GtfsPlanner.Gtfs.ServiceQueries.Snapshot
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Gtfs.Transfers
  alias GtfsPlanner.Gtfs.Transfers.Overlaps
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # Engineering ceilings, not measured workloads: the number of approved pairs
  # one request may carry, the number of endpoint routes it may name, and the
  # shared occurrence cap.
  @max_pairs 500
  @max_approved_routes 2
  @general_types 0..3

  @pair_keys [:from, :id, :minimum, :to]
  @endpoint_keys [:route_id, :service_date_offset, :stop_id, :stop_sequence, :trip_id]
  @candidate_keys [:approval, :origin, :times]
  @candidate_time_keys [:arrival, :departure]
  @approval_keys [:base_digest, :label]
  @stored_minimum_keys [:origin]
  @supplied_minimum_keys [:approval, :origin, :seconds]

  @typedoc "Server-owned organization and version, plus the route bound to the conversation."
  @type scope :: %{
          required(:organization_id) => Ecto.UUID.t(),
          required(:gtfs_version_id) => Ecto.UUID.t(),
          optional(:route_id) => Ecto.UUID.t() | nil
        }

  @typedoc "One approved endpoint: this application's route/trip rows and a natural GTFS stop."
  @type endpoint :: %{
          route_id: Ecto.UUID.t(),
          trip_id: Ecto.UUID.t(),
          stop_id: String.t(),
          stop_sequence: non_neg_integer(),
          service_date_offset: non_neg_integer()
        }

  @typedoc "The minimum the caller asked about, either the stored one or an explicit supplied value."
  @type requested_minimum ::
          %{origin: :stored}
          | %{origin: :supplied, seconds: non_neg_integer(), approval: String.t()}

  @typedoc "One approved pair of endpoints and the minimum that applies to it."
  @type pair :: %{
          id: String.t(),
          from: endpoint(),
          to: endpoint(),
          minimum: requested_minimum()
        }

  @typedoc "Why one requested pair could not be resolved; `nil` when every part resolved."
  @type row_reason ::
          nil
          | :inactive_route
          | :occurrence_not_found
          | :no_recorded_service
          | :unreadable_calendar
          | :unknown_arrival_time
          | :unknown_departure_time
          | :timezone_unavailable

  @typedoc "The loaded evidence of one approved pair."
  @type row :: %{id: String.t(), from: map(), to: map(), minimum: map(), reason: row_reason()}

  @typedoc "The evidence one comparison is computed from."
  @type snapshot :: %{
          scope: map(),
          service_date: Date.t(),
          approved_route_ids: [String.t()],
          rows: [row()],
          totals: map(),
          digest: String.t()
        }

  @typedoc "Why a read could not produce an answer."
  @type error :: :invalid_input | :not_found | :too_many | :unavailable

  @typedoc """
  The candidate a host supplied as external evidence: `%{origin: :supplied,
  times: %{pair_id => %{arrival: clock, departure: clock}}, approval: approval}`.

  It is external by construction - it is exact clock evidence the caller holds
  and approved, never a native schedule draft projected from another process.
  `approval` is the approving label, and its `base_digest` binds the candidate to
  the snapshot it was approved against.
  """
  @type candidate :: %{
          required(:origin) => :supplied,
          required(:times) => %{optional(String.t()) => map()},
          required(:approval) => String.t() | %{base_digest: String.t(), label: String.t()}
        }

  @typedoc "One pair's computed outcome: `:comparable`, `:unresolved`, `:not_applicable` or `:prohibited`."
  @type status :: :comparable | :unresolved | :not_applicable | :prohibited

  @typedoc "One side's exact clocks and the margin they leave against the stated minimum."
  @type side_values :: %{
          arrival_time: String.t() | nil,
          arrival_secs: non_neg_integer(),
          departure_time: String.t() | nil,
          departure_secs: non_neg_integer(),
          available_seconds: integer(),
          margin_seconds: integer(),
          margin_status: :meets_stated_minimum | :below_stated_minimum
        }

  @typedoc "Why one pair could not be given a margin; `nil` for a comparable pair."
  @type comparison_reason ::
          nil
          | :conflicting_best_rules
          | :inactive_route
          | :missing_candidate_evidence
          | :mixed_date_offset_basis
          | :mixed_timezones
          | :no_recorded_service
          | :no_stated_minimum
          | :occurrence_not_found
          | :prohibited_by_best_rule
          | :frequency_template
          | :timezone_unavailable
          | :unreadable_calendar
          | :unknown_arrival_time
          | :unknown_candidate_time
          | :unknown_departure_time

  @typedoc "One classified pair. Every requested pair appears exactly once."
  @type comparison :: %{
          required(:id) => String.t(),
          required(:status) => status(),
          required(:reason) => comparison_reason(),
          required(:current) => side_values() | nil,
          required(:candidate) => side_values() | nil,
          required(:delta_seconds) => integer() | nil,
          required(:minimum) => map()
        }

  @typedoc "The computed comparison of every requested pair."
  @type report :: %{
          required(:scope) => map(),
          required(:service_date) => Date.t(),
          required(:approved_route_ids) => [String.t()],
          required(:base_digest) => String.t(),
          required(:candidate) => map() | nil,
          required(:rows) => [comparison()],
          required(:totals) => map(),
          required(:completeness) => map(),
          required(:resources) => map(),
          required(:digest) => String.t()
        }

  @typedoc "Why a comparison could not be computed."
  @type comparison_error :: error() | :stale

  @doc """
  Returns the bound this module refuses to exceed: the most approved pairs one
  load may carry. It is public so the ceiling a caller is told about and the one
  this function enforces cannot drift apart.
  """
  @spec pair_limit() :: pos_integer()
  def pair_limit, do: @max_pairs

  @doc """
  Loads the exact endpoint occurrences and the native service/minimum evidence
  for `pairs` on `service_date`, in one read-only snapshot.

  The refusals are `:invalid_input` for a value that is not the documented
  shape, a duplicate pair id, a malformed clock-independent value or a negative
  offset; `:not_found` for a route, trip or trip/route pairing outside the
  scope; `:too_many` for more than #{@max_pairs} pairs, more than
  #{@max_approved_routes} approved endpoint routes, or more examined occurrences
  than `ServiceQueries.examined_occurrence_limit/0`; and `:unavailable` when the
  read itself could not be completed. They are all decided before any query
  except the ones that must resolve the request against the scoped rows.

  An accepted pair is never dropped: each requested id produces one row, with
  `reason` naming the part that could not be read, and with the minimum that
  applies to it even when the occurrences did not resolve.
  """
  @spec load(scope(), [pair()], Date.t()) :: {:ok, snapshot()} | {:error, error()}
  def load(scope, pairs, service_date) do
    with {:ok, request} <- request(scope, pairs, service_date) do
      read(request)
    end
  end

  @doc """
  Compares the loaded snapshot's current connection margins with a supplied
  candidate, for `pairs` on `service_date`.

  This is pure arithmetic over `load/3`'s rows: it loads once and reads nothing
  else, so every number in the report comes from the one snapshot its
  `base_digest` names (CR-4).

  `candidate` is external exact supplied evidence -
  `%{origin: :supplied, times: %{pair_id => %{arrival: clock, departure: clock}},
  approval: ...}` - and is never a native schedule draft. Its `approval` carries
  the `base_digest` of the snapshot it was approved against; a digest that is
  absent or does not equal the snapshot loaded here is `{:error, :stale}`, which
  asks the host for a fresh approval rather than reporting a margin against rows
  the approver never saw.

  Every requested pair produces exactly one row, classified `:comparable`,
  `:unresolved`, `:not_applicable` or `:prohibited`, and `totals` counts them.
  A pair is comparable only where its current occurrence is exact and active, its
  stored minimum is resolved, both endpoints share one zone and one civil-date
  basis, and the candidate supplied both of its clocks. Nothing is normalized to
  guess: an above-24-hour clock stays as the feed records it, a different zone or
  date offset is unresolved rather than converted, and a frequency template is
  unresolved because native expansion has no proof here.
  """
  @spec compare(scope(), [pair()], Date.t(), candidate() | nil) ::
          {:ok, report()} | {:error, comparison_error()}
  def compare(scope, pairs, service_date, candidate) do
    with {:ok, supplied} <- candidate(candidate),
         {:ok, snapshot} <- load(scope, pairs, service_date),
         :ok <- binding(supplied, snapshot) do
      {:ok, report(snapshot, supplied)}
    end
  end

  # -- the supplied candidate -------------------------------------------------

  # A `nil` candidate is the "not approved yet" case, not a malformed request:
  # every pair then resolves as unresolved for missing candidate evidence.
  defp candidate(nil), do: {:ok, %{origin: :supplied, times: %{}, approval: nil}}

  defp candidate(candidate) do
    with true <- exact_keys?(candidate, @candidate_keys),
         :supplied <- Map.get(candidate, :origin),
         true <- is_map(Map.get(candidate, :times)),
         {:ok, times} <- candidate_times(Map.get(candidate, :times)),
         {:ok, approval} <- candidate_approval(Map.get(candidate, :approval)) do
      {:ok, %{origin: :supplied, times: times, approval: approval}}
    else
      _other -> {:error, :invalid_input}
    end
  end

  defp candidate_times(times) do
    times
    |> Enum.reduce_while({:ok, %{}}, fn {id, clocks}, {:ok, acc} ->
      case candidate_clocks(id, clocks) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, id, entry)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, times} -> {:ok, times}
      {:error, reason} -> {:error, reason}
    end
  end

  defp candidate_clocks(id, clocks) do
    with true <- label?(id),
         true <- exact_keys?(clocks, @candidate_time_keys),
         true <- clock?(Map.get(clocks, :arrival)),
         true <- clock?(Map.get(clocks, :departure)) do
      {:ok, clocks}
    else
      false -> {:error, :invalid_input}
    end
  end

  defp clock?(nil), do: true
  defp clock?(value), do: is_binary(value)

  # The approving label may be the bare string a caller supplies. Only the map
  # form can bind the candidate to a snapshot, so the label-only form is stale
  # rather than silently unbound.
  defp candidate_approval(label) when is_binary(label) and label != "",
    do: {:ok, %{label: label, base_digest: nil}}

  defp candidate_approval(%{base_digest: base_digest, label: label} = approval) do
    if exact_keys?(approval, @approval_keys) and label?(label) and
         (is_binary(base_digest) or is_nil(base_digest)) do
      {:ok, %{label: label, base_digest: base_digest}}
    else
      {:error, :invalid_input}
    end
  end

  defp candidate_approval(_approval), do: {:error, :invalid_input}

  # INV-2: an approval is bound to the content it was approved against, so a
  # candidate that cannot name this snapshot's digest is refused rather than
  # compared against rows the approver never saw.
  defp binding(%{approval: %{base_digest: digest}}, snapshot) when is_binary(digest) do
    if digest == snapshot.digest, do: :ok, else: {:error, :stale}
  end

  defp binding(%{approval: %{base_digest: nil}}, _snapshot), do: {:error, :stale}
  defp binding(%{approval: nil}, _snapshot), do: :ok

  # -- the computed report ---------------------------------------------------

  defp report(snapshot, supplied) do
    rows = Enum.map(snapshot.rows, &comparison(&1, supplied))

    value = %{
      scope: snapshot.scope,
      service_date: snapshot.service_date,
      approved_route_ids: snapshot.approved_route_ids,
      base_digest: snapshot.digest,
      candidate: candidate_entry(supplied),
      rows: rows,
      totals: totals(rows),
      completeness: completeness(rows),
      resources: %{
        approved_route_ids: snapshot.approved_route_ids,
        pair_limit: @max_pairs,
        occurrence_limit: ServiceQueries.examined_occurrence_limit(),
        snapshot: snapshot.totals
      }
    }

    Map.put(value, :digest, digest(value))
  end

  defp candidate_entry(%{approval: nil}), do: nil

  defp candidate_entry(supplied) do
    %{
      origin: :supplied,
      evidence: :external_exact_supplied,
      approval: supplied.approval,
      supplied_pairs: supplied.times |> Map.keys() |> Enum.sort()
    }
  end

  defp comparison(row, supplied) do
    case verdict(row) do
      {:comparable, nil} -> compared(row, supplied)
      {status, reason} -> result(row, status, reason, nil, nil, nil)
    end
  end

  # The first blocker decides, in the order the acceptance cases name them: the
  # stored policy before the candidate, the occurrence before the arithmetic, and
  # the arithmetic basis before any delta.
  defp verdict(row) do
    cond do
      row.minimum.status == :prohibited -> {:prohibited, row.minimum.provenance.reason}
      row.minimum.status == :conflicting -> {:unresolved, row.minimum.provenance.reason}
      not is_nil(row.reason) -> {inactive_status(row.reason), row.reason}
      row.minimum.status == :absent -> {:unresolved, :no_stated_minimum}
      frequency_template?(row) -> {:unresolved, :frequency_template}
      row.from.timezone != row.to.timezone -> {:unresolved, :mixed_timezones}
      row.from.civil_date != row.to.civil_date -> {:unresolved, :mixed_date_offset_basis}
      true -> {:comparable, nil}
    end
  end

  # A pair that does not run on this date is not applicable to it; an occurrence
  # this request could not read is unresolved.
  defp inactive_status(reason) when reason in [:inactive_route, :no_recorded_service],
    do: :not_applicable

  defp inactive_status(_reason), do: :unresolved

  # A trip with a `frequencies.txt` row is a template rather than one exact
  # departure, at either `exact_times` value, and native expansion has no proof in
  # this module.
  defp frequency_template?(row) do
    row.from.frequency_template? or row.to.frequency_template?
  end

  defp compared(row, supplied) do
    current = side_values(row.from, row.to, row.minimum.seconds)

    case candidate_values(supplied, row) do
      {:ok, candidate} ->
        result(
          row,
          :comparable,
          nil,
          current,
          candidate,
          candidate.margin_seconds - current.margin_seconds
        )

      {:error, reason} ->
        result(row, :unresolved, reason, current, nil, nil)
    end
  end

  # GTFS service-day seconds are subtracted as recorded: 24:10 to 24:18 is 480
  # seconds, not 480 minus a guessed day, and nothing is wrapped to a 24-hour
  # clock.
  defp side_values(from, to, minimum) do
    available = to.departure_secs - from.arrival_secs
    margin = available - minimum

    %{
      arrival_time: from.arrival_time,
      arrival_secs: from.arrival_secs,
      departure_time: to.departure_time,
      departure_secs: to.departure_secs,
      available_seconds: available,
      margin_seconds: margin,
      margin_status: margin_status(margin)
    }
  end

  defp margin_status(margin) when margin >= 0, do: :meets_stated_minimum
  defp margin_status(_margin), do: :below_stated_minimum

  defp candidate_values(supplied, row) do
    case Map.fetch(supplied.times, row.id) do
      {:ok, clocks} -> candidate_clocks_values(clocks, row.minimum.seconds)
      :error -> {:error, :missing_candidate_evidence}
    end
  end

  # The same integer arithmetic on the supplied clocks, at the same stated
  # minimum. An unparsable supplied clock is unresolved, never zero.
  defp candidate_clocks_values(clocks, minimum) do
    with {:ok, arrival_secs} <- supplied_secs(Map.get(clocks, :arrival)),
         {:ok, departure_secs} <- supplied_secs(Map.get(clocks, :departure)) do
      available = departure_secs - arrival_secs
      margin = available - minimum

      {:ok,
       %{
         arrival_time: Map.get(clocks, :arrival),
         arrival_secs: arrival_secs,
         departure_time: Map.get(clocks, :departure),
         departure_secs: departure_secs,
         available_seconds: available,
         margin_seconds: margin,
         margin_status: margin_status(margin)
       }}
    end
  end

  defp supplied_secs(nil), do: {:error, :unknown_candidate_time}

  defp supplied_secs(value) do
    case GtfsTime.parse(value) do
      {:ok, secs} -> {:ok, secs}
      {:error, :invalid_time} -> {:error, :unknown_candidate_time}
    end
  end

  defp result(row, status, reason, current, candidate, delta_seconds) do
    %{
      id: row.id,
      status: status,
      reason: reason,
      current: current,
      candidate: candidate,
      delta_seconds: delta_seconds,
      minimum: row.minimum
    }
  end

  defp totals(rows) do
    statuses = Enum.map(rows, & &1.status)

    margins =
      Enum.flat_map(rows, fn row -> Enum.reject([row.current, row.candidate], &is_nil/1) end)

    %{
      requested: length(rows),
      comparable: Enum.count(statuses, &(&1 == :comparable)),
      unresolved: Enum.count(statuses, &(&1 == :unresolved)),
      not_applicable: Enum.count(statuses, &(&1 == :not_applicable)),
      prohibited: Enum.count(statuses, &(&1 == :prohibited)),
      meets_stated_minimum: Enum.count(margins, &(&1.margin_status == :meets_stated_minimum)),
      below_stated_minimum: Enum.count(margins, &(&1.margin_status == :below_stated_minimum))
    }
  end

  # Caps and unresolved rows are disclosed here rather than silently narrowing
  # the answer: a report that withheld nothing is complete, and one that did says
  # how many pairs carry no margin.
  defp completeness(rows) do
    %{
      complete?: Enum.all?(rows, &(&1.status == :comparable)),
      requested: length(rows),
      classified: length(rows),
      withheld: Enum.count(rows, &(&1.status != :comparable))
    }
  end

  # -- request validation ----------------------------------------------------

  # Everything that can be refused without reading is refused here, so an
  # over-limit or malformed request never reaches the database.
  defp request(scope, pairs, service_date) do
    cond do
      not is_list(pairs) -> {:error, :invalid_input}
      length(pairs) > @max_pairs -> {:error, :too_many}
      true -> validated_request(scope, pairs, service_date)
    end
  end

  defp validated_request(scope, pairs, service_date) do
    with {:ok, organization_id, gtfs_version_id} <- scoped_ids(scope),
         true <- match?(%Date{}, service_date) do
      approved_request(organization_id, gtfs_version_id, service_date, pairs)
    else
      false -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
    end
  end

  # The pair ceiling is a narrowing path of its own, so an over-limit request is
  # refused before a single pair of it is read.
  defp approved_request(organization_id, gtfs_version_id, service_date, pairs) do
    with {:ok, validated} <- validate_pairs(pairs) do
      route_uuids =
        validated
        |> Enum.flat_map(&[&1.from.route_id, &1.to.route_id])
        |> Enum.uniq()

      if length(route_uuids) <= @max_approved_routes do
        {:ok,
         %{
           organization_id: organization_id,
           gtfs_version_id: gtfs_version_id,
           service_date: service_date,
           pairs: validated,
           route_uuids: route_uuids
         }}
      else
        {:error, :too_many}
      end
    end
  end

  defp scoped_ids(scope) do
    with {:ok, organization_id} <- cast_uuid(Map.get(scope, :organization_id)),
         {:ok, gtfs_version_id} <- cast_uuid(Map.get(scope, :gtfs_version_id)) do
      {:ok, organization_id, gtfs_version_id}
    end
  end

  defp validate_pairs(pairs) do
    ids = Enum.map(pairs, &pair_id/1)

    if Enum.all?(ids, &label?/1) and length(Enum.uniq(ids)) == length(ids) do
      reduce_valid_pairs(pairs)
    else
      {:error, :invalid_input}
    end
  end

  defp reduce_valid_pairs(pairs) do
    pairs
    |> Enum.reduce_while({:ok, []}, fn pair, {:ok, acc} ->
      case validate_pair(pair) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp pair_id(pair) when is_map(pair), do: Map.get(pair, :id)
  defp pair_id(_pair), do: nil

  defp validate_pair(pair) do
    with true <- exact_keys?(pair, @pair_keys),
         {:ok, id} <- label(Map.get(pair, :id)),
         {:ok, from} <- validate_endpoint(Map.get(pair, :from)),
         {:ok, to} <- validate_endpoint(Map.get(pair, :to)),
         {:ok, minimum} <- validate_minimum(Map.get(pair, :minimum)) do
      {:ok, %{id: id, from: from, to: to, minimum: minimum}}
    else
      false -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_endpoint(endpoint) do
    with true <- exact_keys?(endpoint, @endpoint_keys),
         {:ok, route_id} <- cast_uuid(Map.get(endpoint, :route_id)),
         {:ok, trip_id} <- cast_uuid(Map.get(endpoint, :trip_id)),
         {:ok, stop_id} <- label(Map.get(endpoint, :stop_id)),
         true <- non_neg_integer?(Map.get(endpoint, :stop_sequence)),
         true <- non_neg_integer?(Map.get(endpoint, :service_date_offset)) do
      {:ok,
       %{
         route_id: route_id,
         trip_id: trip_id,
         stop_id: stop_id,
         stop_sequence: Map.fetch!(endpoint, :stop_sequence),
         service_date_offset: Map.fetch!(endpoint, :service_date_offset)
       }}
    else
      false -> {:error, :invalid_input}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_minimum(%{origin: :stored} = minimum) do
    if exact_keys?(minimum, @stored_minimum_keys) do
      {:ok, minimum}
    else
      {:error, :invalid_input}
    end
  end

  defp validate_minimum(%{origin: :supplied} = minimum) do
    with true <- exact_keys?(minimum, @supplied_minimum_keys),
         true <- label?(Map.get(minimum, :approval)),
         true <- non_neg_integer?(Map.get(minimum, :seconds)) do
      {:ok, minimum}
    else
      _other -> {:error, :invalid_input}
    end
  end

  defp validate_minimum(_minimum), do: {:error, :invalid_input}

  # -- one read-only snapshot ------------------------------------------------

  # Wraps query execution only. `DBConnection.ConnectionError` is the single
  # recoverable operational failure, as it is for the other read adapters; every
  # other exception propagates so a code defect can never be reported as
  # downtime.
  defp read(request) do
    Snapshot.read_snapshot(fn -> load_snapshot(request) end)
  rescue
    DBConnection.ConnectionError -> {:error, :unavailable}
  end

  defp load_snapshot(request) do
    with {:ok, routes} <- scoped_routes(request),
         {:ok, trips} <- scoped_trips(request),
         :ok <- trips_run_on_their_routes(request, routes, trips),
         {:ok, occurrences} <- scoped_occurrences(request, trips),
         {:ok, policy} <- scoped_policy(request, pairs_stop_ids(request.pairs)) do
      data = %{
        request: request,
        routes: routes,
        trips: trips,
        occurrences: occurrences,
        policy: policy,
        calendars: scoped_calendars(request, trips),
        frequencies: scoped_frequencies(request, trips),
        zones: scoped_zones(request, routes)
      }

      rows = Enum.map(request.pairs, &row(&1, data))

      {:ok, snapshot(request, data, rows)}
    end
  end

  defp snapshot(request, data, rows) do
    value = %{
      scope: %{
        organization_id: request.organization_id,
        gtfs_version_id: request.gtfs_version_id
      },
      service_date: request.service_date,
      approved_route_ids: approved_route_ids(data),
      rows: rows
    }

    Map.put(value, :totals, snapshot_totals(rows)) |> Map.put(:digest, digest(value))
  end

  # -- scoped reads ----------------------------------------------------------

  defp scoped_routes(request) do
    loaded =
      from(r in Route,
        where:
          r.organization_id == ^request.organization_id and
            r.gtfs_version_id == ^request.gtfs_version_id and r.id in ^request.route_uuids,
        order_by: [asc: r.id]
      )
      |> Repo.all()

    if length(loaded) == length(request.route_uuids) do
      {:ok, Map.new(loaded, &{&1.id, &1})}
    else
      {:error, :not_found}
    end
  end

  defp scoped_trips(request) do
    trip_uuids =
      request.pairs
      |> Enum.flat_map(&[&1.from.trip_id, &1.to.trip_id])
      |> Enum.uniq()

    loaded =
      from(t in Trip,
        where:
          t.organization_id == ^request.organization_id and
            t.gtfs_version_id == ^request.gtfs_version_id and t.id in ^trip_uuids,
        order_by: [asc: t.id]
      )
      |> Repo.all()

    if length(loaded) == length(trip_uuids) do
      {:ok, Map.new(loaded, &{&1.id, &1})}
    else
      {:error, :not_found}
    end
  end

  # A trip that exists in the scope but does not run on the route its own
  # endpoint names is a reference this request may not make: it is refused with
  # the same `:not_found` as a reference from outside the scope, rather than
  # becoming a row whose occurrence merely failed to resolve.
  defp trips_run_on_their_routes(request, routes, trips) do
    endpoints = Enum.flat_map(request.pairs, &[&1.from, &1.to])

    mismatch? =
      Enum.any?(endpoints, fn endpoint ->
        trip = Map.fetch!(trips, endpoint.trip_id)
        route = Map.fetch!(routes, endpoint.route_id)

        trip.route_id != route.route_id
      end)

    if mismatch?, do: {:error, :not_found}, else: :ok
  end

  # The requested occurrence is the exact `(stop, stop_sequence)` pair inside the
  # named trip, so a loop's second visit can never be substituted for it. The
  # query's own limit is the shared occurrence cap, so an over-cap request is
  # refused instead of materializing an unbounded row set.
  defp scoped_occurrences(request, trips) do
    occurrences =
      request.pairs
      |> Enum.flat_map(&[&1.from, &1.to])
      |> Enum.uniq_by(&{&1.trip_id, &1.stop_id, &1.stop_sequence})
      |> Enum.map(&occurrence_key(&1, trips))
      |> Enum.reject(&is_nil/1)

    trip_ids = Enum.map(occurrences, &elem(&1, 0))
    stop_ids = occurrences |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    limit = ServiceQueries.examined_occurrence_limit()

    rows =
      if trip_ids == [] do
        []
      else
        from(s in StopTime,
          where:
            s.organization_id == ^request.organization_id and
              s.gtfs_version_id == ^request.gtfs_version_id and s.trip_id in ^trip_ids and
              s.stop_id in ^stop_ids,
          order_by: [asc: s.trip_id, asc: s.stop_id, asc: s.stop_sequence, asc: s.id],
          limit: ^limit + 1
        )
        |> Repo.all()
      end

    if length(rows) > limit do
      {:error, :too_many}
    else
      # `put_new` keeps the first row of an occurrence, which is the lowest
      # `id` of the ordered query.
      {:ok,
       Enum.reduce(rows, %{}, fn row, index ->
         Map.put_new(index, {row.trip_id, row.stop_id, row.stop_sequence}, row)
       end)}
    end
  end

  defp occurrence_key(endpoint, trips) do
    case Map.fetch(trips, endpoint.trip_id) do
      {:ok, trip} -> {trip.trip_id, endpoint.stop_id, endpoint.stop_sequence}
      :error -> nil
    end
  end

  # The stored general policy this version holds, with the stop index the R2
  # coverage expansion needs: every endpoint stop a rule names plus its direct
  # children.
  defp scoped_policy(request, extra_stop_ids) do
    transfers =
      from(t in Transfer,
        where:
          t.organization_id == ^request.organization_id and
            t.gtfs_version_id == ^request.gtfs_version_id and
            t.transfer_type in ^Enum.to_list(@general_types),
        order_by: [asc: t.id]
      )
      |> Repo.all()

    stop_ids = Enum.uniq(transfer_stop_ids(transfers) ++ extra_stop_ids)

    stops =
      if stop_ids == [] do
        %{}
      else
        from(s in Stop,
          where:
            s.organization_id == ^request.organization_id and
              s.gtfs_version_id == ^request.gtfs_version_id and
              (s.stop_id in ^stop_ids or s.parent_station in ^stop_ids)
        )
        |> Repo.all()
        |> Map.new(&{&1.stop_id, &1})
      end

    # Each rule carries its R2 coverage, computed once here by the same function the
    # transfers catalog uses, and the revision a stored minimum's provenance names.
    rules = Enum.map(transfers, &Map.put(Transfers.rule(&1, stops), :revision, &1.updated_at))

    {:ok, %{rules: rules}}
  end

  defp transfer_stop_ids(transfers) do
    transfers
    |> Enum.flat_map(&[&1.from_stop_id, &1.to_stop_id])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp pairs_stop_ids(pairs) do
    pairs
    |> Enum.flat_map(&[&1.from.stop_id, &1.to.stop_id])
    |> Enum.uniq()
  end

  # A service with no weekly row maps to `{nil, []}`, which `ServiceDates` reads
  # as dates-only service rather than as a second calendar rule.
  defp scoped_calendars(request, trips) do
    service_ids =
      trips
      |> Map.values()
      |> Enum.map(& &1.service_id)
      |> Enum.uniq()

    calendars =
      from(c in Calendar,
        where:
          c.organization_id == ^request.organization_id and
            c.gtfs_version_id == ^request.gtfs_version_id and c.service_id in ^service_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.service_id, &1})

    exceptions =
      from(d in CalendarDate,
        where:
          d.organization_id == ^request.organization_id and
            d.gtfs_version_id == ^request.gtfs_version_id and d.service_id in ^service_ids,
        order_by: [asc: d.service_id, asc: d.date]
      )
      |> Repo.all()

    grouped = Enum.group_by(exceptions, & &1.service_id)

    Map.new(service_ids, fn service_id ->
      {service_id, {Map.get(calendars, service_id), Map.get(grouped, service_id, [])}}
    end)
  end

  # The frequency templates of this request's own trips, read in the same
  # snapshot as their stop times. A trip that owns one is a template rather than
  # one exact departure, which `compare/4` refuses to price.
  defp scoped_frequencies(request, trips) do
    trip_ids = trips |> Map.values() |> Enum.map(& &1.trip_id)

    if trip_ids == [] do
      MapSet.new()
    else
      from(f in Frequency,
        where:
          f.organization_id == ^request.organization_id and
            f.gtfs_version_id == ^request.gtfs_version_id and f.trip_id in ^trip_ids
      )
      |> Repo.all()
      |> MapSet.new(& &1.trip_id)
    end
  end

  # The date evaluator is pure but raises for unreadable retained calendar
  # source; an unreadable service is a disclosed fact here, never a zero.
  defp active_on?(calendars, service_id, %Date{} = date) do
    {calendar, exceptions} = Map.fetch!(calendars, service_id)

    try do
      {:ok, date in ServiceDates.active_dates_between(calendar, exceptions, date, date)}
    rescue
      ArgumentError -> {:error, :unreadable_calendar}
    end
  end

  # The native agency rule `ServiceQueries` uses: the route's own agency when it
  # names one, otherwise the sole scoped agency. A presentation fallback is
  # refused here, so a missing zone never becomes a local-clock claim.
  defp scoped_zones(request, routes) do
    Map.new(routes, fn {route_uuid, route} ->
      {route_uuid, route_zone(request, route)}
    end)
  end

  # `ServiceQueries` owns the rule; this reads its answer, where a missing or
  # invalid zone is a reason rather than a local-clock claim.
  defp route_zone(request, route) do
    case ServiceQueries.service_timezone(request.organization_id, request.gtfs_version_id, route) do
      {:ok, timezone} -> {:ok, timezone}
      {:error, {:timezone_unavailable, reason}} -> {:error, reason}
    end
  end

  # -- one row ---------------------------------------------------------------

  defp row(pair, data) do
    from = endpoint_row(pair.from, :from, data)
    to = endpoint_row(pair.to, :to, data)

    %{
      id: pair.id,
      from: from,
      to: to,
      minimum: minimum(pair, from, to, data),
      reason: row_reason(from, to)
    }
  end

  defp endpoint_row(endpoint, side, data) do
    route = Map.fetch!(data.routes, endpoint.route_id)
    trip = Map.fetch!(data.trips, endpoint.trip_id)
    civil_date = Date.add(data.request.service_date, endpoint.service_date_offset)

    occurrence =
      if trip.route_id == route.route_id do
        Map.get(data.occurrences, {trip.trip_id, endpoint.stop_id, endpoint.stop_sequence})
      end

    {service_active?, service_reason} =
      case active_on?(data.calendars, trip.service_id, civil_date) do
        {:ok, active} -> {active, nil}
        {:error, reason} -> {nil, reason}
      end

    {timezone, zone_reason} =
      case Map.fetch!(data.zones, endpoint.route_id) do
        {:ok, timezone} -> {timezone, nil}
        {:error, reason} -> {nil, reason}
      end

    %{
      side: side,
      route_id: route.id,
      route: route.route_id,
      route_active?: route.active,
      trip_id: trip.id,
      trip: trip.trip_id,
      trip_on_route?: trip.route_id == route.route_id,
      service_id: trip.service_id,
      stop_id: endpoint.stop_id,
      stop_sequence: endpoint.stop_sequence,
      service_date_offset: endpoint.service_date_offset,
      civil_date: civil_date,
      service_active?: service_active?,
      service_reason: service_reason,
      frequency_template?: MapSet.member?(data.frequencies, trip.trip_id),
      occurrence_found?: occurrence != nil,
      arrival_secs: arrival_secs(occurrence),
      arrival_time: arrival_time(occurrence),
      departure_secs: departure_secs(occurrence),
      departure_time: departure_time(occurrence),
      timezone: if(zone_reason, do: nil, else: timezone),
      zone_reason: zone_reason
    }
  end

  # The first blocker either endpoint names, from the `from` side first, so the
  # same incomplete pair always reports the same reason.
  defp row_reason(from, to) do
    case {endpoint_blocker(from), endpoint_blocker(to)} do
      {nil, nil} -> nil
      {nil, reason} -> reason
      {reason, _other} -> reason
    end
  end

  defp endpoint_blocker(endpoint) do
    case source_blocker(endpoint) do
      nil -> clock_blocker(endpoint)
      reason -> reason
    end
  end

  defp source_blocker(endpoint) do
    cond do
      not endpoint.trip_on_route? -> :occurrence_not_found
      endpoint.route_active? == false -> :inactive_route
      not endpoint.occurrence_found? -> :occurrence_not_found
      endpoint.service_reason == :unreadable_calendar -> :unreadable_calendar
      endpoint.service_active? == false -> :no_recorded_service
      endpoint.zone_reason != nil -> :timezone_unavailable
      true -> nil
    end
  end

  defp clock_blocker(%{side: :from} = endpoint) do
    if is_nil(endpoint.arrival_secs), do: :unknown_arrival_time
  end

  defp clock_blocker(%{side: :to} = endpoint) do
    if is_nil(endpoint.departure_secs), do: :unknown_departure_time
  end

  # A `departure_time` is the boarding time and a trip that records only an
  # `arrival_time` still boards then, which is the rule `ServiceQueries` reads.
  # An absent or unparsable clock is `nil`, never zero, and neither side is read
  # through the other.
  defp arrival_secs(nil), do: nil
  defp arrival_secs(%StopTime{} = row), do: clock_secs(row.arrival_time)

  defp departure_secs(nil), do: nil
  defp departure_secs(%StopTime{} = row), do: clock_secs(row.departure_time)

  defp arrival_time(nil), do: nil
  defp arrival_time(%StopTime{arrival_time: time}), do: time

  defp departure_time(nil), do: nil
  defp departure_time(%StopTime{departure_time: time}), do: time

  defp clock_secs(nil), do: nil

  defp clock_secs(value) do
    case GtfsTime.parse(value || "") do
      {:ok, secs} -> secs
      {:error, :invalid_time} -> nil
    end
  end

  # -- the stored minimum ----------------------------------------------------

  defp minimum(pair, from, to, data) do
    data.policy.rules
    |> Enum.filter(&applies?(&1, from, to))
    |> best_rules()
    |> decided(pair.minimum.origin, supplied_minimum(pair.minimum))
  end

  # A rule applies to one endpoint when its coverage contains that endpoint's
  # stop and its selectors match that endpoint's trip and route. This is the
  # selector half of the R6 rule `Transfers.Overlaps` ranks.
  defp applies?(rule, from, to) do
    covers?(rule.from_coverage, from) and covers?(rule.to_coverage, to) and
      selects?(rule.from_trip_id, rule.from_route_id, from) and
      selects?(rule.to_trip_id, rule.to_route_id, to)
  end

  defp covers?(leaves, endpoint), do: endpoint.stop_id in leaves

  defp selects?(trip_selector, route_selector, endpoint) do
    (is_nil(trip_selector) or trip_selector == endpoint.trip) and
      (is_nil(route_selector) or route_selector == endpoint.route)
  end

  # The best-ranked applicable rule decides. Type 3 prohibits, equal-best rules
  # with differing effects stay unresolved instead of picking one, a best-ranked
  # type 2 states the minimum, and type 0/1 leaves it undetermined unless the
  # pair carried an explicit supplied minimum.
  defp best_rules([]), do: {:none, []}

  defp best_rules(rules) do
    rank = rules |> Enum.map(&Overlaps.rank/1) |> Enum.min()
    {rank, Enum.filter(rules, &(Overlaps.rank(&1) == rank))}
  end

  defp decided({:none, _rules}, origin, supplied),
    do: undetermined(origin, supplied, :no_applicable_rule, nil, [])

  defp decided({rank, rules}, origin, supplied) do
    cond do
      Enum.any?(rules, &(&1.transfer_type == 3)) ->
        unresolved(
          origin,
          supplied,
          :prohibited,
          :prohibited_by_best_rule,
          %{kind: :stored_best, rank: rank, transfer_type: 3, rule_ids: rule_ids(rules)}
        )

      length(Enum.uniq(Enum.map(rules, &Overlaps.effect/1))) > 1 ->
        unresolved(
          origin,
          supplied,
          :conflicting,
          :conflicting_best_rules,
          %{
            kind: :stored_best,
            rank: rank,
            rule_ids: rule_ids(rules),
            effects: Enum.map(rules, &effect_entry(&1))
          }
        )

      true ->
        stated_minimum(rules, rank, origin, supplied)
    end
  end

  # Equal-best rules that agree are one effect, so the first of them names the
  # stored row its provenance carries.
  defp stated_minimum([%{transfer_type: 2} = best | _rules], rank, origin, supplied) do
    if is_integer(best.min_transfer_time) do
      %{
        origin: :stored,
        seconds: best.min_transfer_time,
        status: :resolved,
        provenance: %{
          kind: :stored_best,
          rank: rank,
          transfer_id: best.id,
          transfer_type: best.transfer_type,
          min_transfer_time: best.min_transfer_time,
          revision: best.revision,
          rule_ids: [best.id]
        },
        supplied: supplied_entry(supplied)
      }
    else
      undetermined(origin, supplied, :stored_best_without_minimum, rank, [best.id])
    end
  end

  defp stated_minimum(rules, rank, origin, supplied) do
    undetermined(origin, supplied, :stored_best_without_minimum, rank, rule_ids(rules))
  end

  # Type 0/1, and a type 2 whose retained minimum is unreadable, leave the
  # minimum undetermined. An explicit supplied minimum answers it with its own
  # provenance, and a type 2 that states one keeps its stored value: a supplied
  # number never replaces the stored policy's own.
  defp undetermined(origin, nil, kind, rank, ids) do
    %{
      origin: origin,
      seconds: nil,
      status: :absent,
      provenance: provenance(kind, rank, ids),
      supplied: nil
    }
  end

  defp undetermined(_origin, supplied, kind, rank, ids) do
    %{
      origin: :supplied,
      seconds: supplied.seconds,
      status: :resolved,
      provenance: provenance(kind, rank, ids),
      supplied: supplied_entry(supplied)
    }
  end

  defp unresolved(origin, supplied, status, reason, provenance) do
    %{
      origin: origin,
      seconds: nil,
      status: status,
      provenance: Map.put(provenance, :reason, reason),
      supplied: supplied_entry(supplied)
    }
  end

  defp provenance(kind, rank, ids) do
    %{kind: kind, rank: rank, rule_ids: ids}
  end

  defp rule_ids(rules), do: Enum.map(rules, & &1.id)

  defp supplied_entry(nil), do: nil
  defp supplied_entry(supplied), do: %{seconds: supplied.seconds, approval: supplied.approval}

  defp supplied_minimum(%{origin: :supplied} = minimum), do: minimum
  defp supplied_minimum(%{origin: :stored}), do: nil

  defp effect_entry(rule) do
    %{
      id: rule.id,
      transfer_type: rule.transfer_type,
      min_transfer_time: Map.get(rule, :min_transfer_time)
    }
  end

  # -- totals and digest -----------------------------------------------------

  defp snapshot_totals(rows) do
    minimums = Enum.map(rows, & &1.minimum.status)

    %{
      requested: length(rows),
      endpoints: length(rows) * 2,
      resolved_rows: Enum.count(rows, &is_nil(&1.reason)),
      unresolved_rows: Enum.count(rows, &(not is_nil(&1.reason))),
      resolved_minimum: Enum.count(minimums, &(&1 == :resolved)),
      prohibited_minimum: Enum.count(minimums, &(&1 == :prohibited)),
      conflicting_minimum: Enum.count(minimums, &(&1 == :conflicting)),
      absent_minimum: Enum.count(minimums, &(&1 == :absent))
    }
  end

  # The digest identifies the content this snapshot was read from, not a
  # chronological revision, so a comparison can bind its approval to exactly
  # these rows and this stored policy.
  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp approved_route_ids(data) do
    data.routes
    |> Map.values()
    |> Enum.map(& &1.route_id)
    |> Enum.sort()
  end

  # -- guards ----------------------------------------------------------------

  defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == keys

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_input}
    end
  end

  defp label(value) when is_binary(value) and value != "", do: {:ok, value}
  defp label(_value), do: {:error, :invalid_input}

  defp label?(value), do: is_binary(value) and value != ""

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0
end

defmodule GtfsPlanner.Gtfs.InSeatTransfers do
  @moduledoc """
  Authoring of one block connection's in-seat transfer record.

  A type 4/5 row states whether riders may stay on board between two consecutive
  trips of a vehicle, and this module owns every explicit Blocks write of one
  (R1–R5). It is the only path that writes those rows interactively: ingestion
  and the reviewed `Routes` cascade keep their own contracts, and no block
  command writes a transfer at all (INV-3, CR-1).

  The rules one write follows, in the order the transaction takes them:

  - **R1 — the write rule.** `:stay_on_board` and `:must_reboard` are written
    only when the to-trip is the immediate successor of the from-trip in one
    `block_id`'s service order on every date both trips run. The answer comes
    from `Blocking.lock_and_check_connections!/2`, which evaluates the one
    `Blocking.InSeat.state/2` rule, so the drawer's pre-check and this save can
    never disagree (CR-2). `:not_stated` is never refused.
  - **R2 — the stored stops.** `from_stop_id` is the from-trip's last
    `stop_time` stop and `to_stop_id` the to-trip's first, taken from the locked
    trip rows. The route pair and the minimum time are nil, because
    OpenTripPlanner's `TransferMapper` dereferences the stops. Re-choosing a
    saved type rewrites stops that drifted, which returns the record to
    `:matches`.
  - **R3 — one record per pair.** "The connection's record" is every type 4/5
    row naming the pair, whatever its stops. A choice leaves at most one row,
    `:not_stated` deletes them all, and every insert, update and delete writes
    one `"transfer"` change log whose `before` and `after` are the eight GTFS
    columns on either side of the change, with one operation id per command.
  - **R4 — the expected-state guard and the lock order.** The write carries the
    `%{id, transfer_type, updated_at}` rows the editor saw; a mismatch under the
    locks is `:stale` with no write. Locks are taken in the one order: the actor's
    current editor membership `FOR SHARE` (a revoked editor is `:forbidden` with
    nothing written), the scoped
    published version `FOR SHARE` read and the calendar reads, then the
    `blocking:<version>` advisory lock, then the named trips and their blocks'
    trips `FOR UPDATE` in UUID order (all inside
    `lock_and_check_connections!/2`), then the pair's transfer rows `FOR UPDATE`
    in id order. Serialization failures and deadlocks retry three attempts and
    then answer `:busy`.
  - **R5 — scope.** Organization, version and actor come from the audit context
    only. A trip ID naming no trip of that version is `:not_found`, so a crafted
    event cannot write a foreign tenant's pair.
  - **R6 — the bulk command.** `set_connections/3` applies the same rule, guard and
    per-pair write to a reviewed list of at most 500 pairs in one transaction. A
    pair that is `:not_found`, `:stale` or `{:refused, state}` is skipped with that
    reason and the rest are committed together; every log of one call shares one
    operation id, and no route-pair rule is stored.
  - **R7 — explicit removal.** `remove_records/2` locks the actor's membership
    first, then deletes exactly the listed
    `{id, updated_at}` rows of one version's type 4/5 records, all-or-nothing, and
    audits each deletion with one operation id. It never evaluates R1 and never
    validates references, so a row an import left damaged is still removable, and
    a listed id that names nothing, names a type 0–3 row or names another version
    is `:not_found` while one stale member makes the request `:stale`.

  The write runs in this module's own three-attempt retry loop over the
  configured `ReviewedApplyTransaction` module, copied from `Transfers` and
  `Blocking` rather than shared with them; extracting one loop is a later
  package's decision.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.Audit
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  @write_attempts 3
  @max_bulk_pairs 500
  @choices [:not_stated, :stay_on_board, :must_reboard]
  @in_seat_types [4, 5]

  @typedoc "One of the three settings a connection may carry."
  @type choice :: :not_stated | :stay_on_board | :must_reboard

  @typedoc "One row of the `expected` list the editor's screen showed."
  @type expected_row :: %{
          id: Ecto.UUID.t(),
          transfer_type: 4 | 5,
          updated_at: DateTime.t()
        }

  @typedoc "The trip pair a connection is."
  @type pair :: {from_trip_id :: String.t(), to_trip_id :: String.t()}

  @typedoc "One reviewed entry of a bulk command."
  @type entry :: %{pair: pair(), expected: [expected_row()]}

  @typedoc "The result of one accepted bulk command."
  @type bulk_result :: %{
          saved: [pair()],
          skipped: [%{pair: pair(), reason: skip_reason()}],
          operation_id: Ecto.UUID.t() | nil
        }

  @typedoc "The rule that stopped one pair of a bulk command."
  @type skip_reason :: :not_found | :stale | {:refused, Blocking.InSeat.state()}

  @typedoc "The result of one accepted choice."
  @type result :: %{
          choice: choice(),
          transfer: Transfer.t() | nil,
          operation_id: Ecto.UUID.t() | nil
        }

  @doc """
  Writes, replaces or deletes one trip pair's in-seat record.

  `from_trip_id`, `to_trip_id` and `choice` are the connection the editor acted
  on, `expected` the list of `%{id, transfer_type, updated_at}` rows the editor
  saw, sorted by id, and `audit` the audit context naming the organization,
  version and actor (R5). The organization, version and actor come from `audit`
  alone, so a foreign tenant or version in the request cannot be written. The
  actor's current editor membership is locked first inside the transaction, and a
  missing or revoked editor is `{:error, :forbidden}` with nothing written.

  `:stay_on_board` and `:must_reboard` are refused with
  `{:refused, state}` — carrying R1's own state, so a not-next refusal names the
  failing day types and the intervening trip — unless the rule holds under the
  locks; `:not_stated` is never refused. A trip this version does not hold is
  `{:error, :not_found}` and a mismatched `expected` is `{:error, :stale}`,
  both with no write (R1, R4, AC-5).

  The pair holds at most one row afterwards (R3): the first row by id is kept
  and updated in place when its type or stops differ, any other row of the pair
  is deleted, and an empty pair is inserted through `Transfer.in_seat_changeset/2`
  with the endpoint stops (R2). A choice that changes nothing returns
  `operation_id: nil` and writes no log; every change writes one `"transfer"`
  change log sharing this command's operation id, and an audit failure rolls the
  whole command back (R3, INV-5). Serialization failures and deadlocks retry up
  to three attempts before `{:error, :busy}` (R4).
  """
  @spec set_connection(String.t(), String.t(), choice(), [expected_row()], AuditContext.t()) ::
          {:ok, result()}
          | {:error,
             :invalid_choice
             | :forbidden
             | :not_found
             | :stale
             | {:refused, Blocking.InSeat.state()}
             | :busy
             | {:audit_failed, term()}}
  def set_connection(from_trip_id, to_trip_id, choice, expected, %AuditContext{} = audit)
      when is_binary(from_trip_id) and is_binary(to_trip_id) do
    with :ok <- validate_choice(choice) do
      operation_id = Ecto.UUID.generate()
      pair = {from_trip_id, to_trip_id}

      run_write(fn -> write_connection(pair, choice, expected, audit, operation_id) end)
    end
  end

  @doc """
  Writes one record per included pair of a reviewed group, in one transaction.

  `entries` is the list of `%{pair: {from_trip_id, to_trip_id}, expected: [...]}` the
  Set-all review left checked, `choice` the one setting they are all set to, and
  `audit` the audit context naming the organization, version and actor (R5). More
  than #{@max_bulk_pairs} entries, a malformed entry, a repeated pair or an unknown
  setting is refused before a transaction opens. A missing or revoked editor is
  `{:error, :forbidden}` with nothing written.

  Every pair is decided by the same rule, guard and per-pair write
  `set_connection/5` uses, so one call cannot answer differently from a single save
  (R1, R4, CR-2). A pair is skipped with its own reason and the rest are committed
  together: `:not_found` for a trip this version does not hold, `:stale` for a
  mismatched `expected`, and `{:refused, state}` for a pair the rule refuses under
  the locks, carrying R1's own state (R6, AC-7). `:not_stated` is never refused.

  `saved` names the written pairs in input order, `skipped` names every pair that
  was not, and `operation_id` is the one id all of this call's `"transfer"` change
  logs share, or `nil` when no pair changed anything (INV-5). No route-pair rule is
  stored: the record is the pair's only record, as it is for a single save (R3). An
  audit failure rolls the whole batch back, and serialization failures and
  deadlocks retry up to three attempts before `{:error, :busy}` (R4).
  """
  @spec set_connections([entry()], choice(), AuditContext.t()) ::
          {:ok, bulk_result()}
          | {:error,
             :invalid_input
             | :invalid_choice
             | :forbidden
             | :too_many
             | :busy
             | {:audit_failed, term()}
             | Ecto.Changeset.t()}
  def set_connections(entries, choice, %AuditContext{} = audit) do
    with :ok <- validate_choice(choice),
         {:ok, entries} <- validate_entries(entries) do
      operation_id = Ecto.UUID.generate()

      run_write(fn -> write_entries(entries, choice, audit, operation_id) end)
    end
  end

  @doc """
  Deletes exactly the listed in-seat records, all-or-nothing.

  `pairs` is the caller's exact target list of `{id, updated_at}` rows — the ones
  the trip drawer, the day type or the version listed as unmatched — and `audit`
  the audit context naming the organization, version and actor (R5). The rows are
  loaded `FOR UPDATE`, scoped to that organization, version and
  `transfer_type in [4, 5]`, and each one's stored `updated_at` is compared with
  the timestamp the editor saw (INV-4).

  An empty list or a malformed pair is `{:error, :invalid_input}` before a
  transaction opens. A listed id that names no row of that scope — a missing id, a
  type 0–3 row or a row of another version — is `{:error, :not_found}`, and any
  stale member is `{:error, :stale}`; both delete nothing. A missing or revoked
  editor is `{:error, :forbidden}`, also with nothing deleted. Otherwise every listed
  row is deleted, each with its own `"deleted"` change log sharing one operation id
  (INV-5), and the call answers `{:ok, count}`. An audit failure rolls the whole
  batch back, and serialization failures and deadlocks retry up to three attempts
  before `{:error, :busy}` (R4).
  """
  @spec remove_records([{Ecto.UUID.t(), DateTime.t() | String.t()}], AuditContext.t()) ::
          {:ok, pos_integer()}
          | {:error,
             :invalid_input | :forbidden | :not_found | :stale | :busy | {:audit_failed, term()}}
  def remove_records(pairs, %AuditContext{} = audit) do
    case removal_targets(pairs) do
      {:ok, targets} ->
        operation_id = Ecto.UUID.generate()

        run_write(fn -> remove_records_transaction(targets, audit, operation_id) end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # R7: the batch is the caller's exact list, decided under the row locks. The
  # count is what the caller listed, so a filter never widens or narrows it, and
  # the two refusals leave every listed row exactly as it was.
  defp remove_records_transaction(targets, audit, operation_id) do
    Authorization.lock_editor!(audit)

    case cast_removal_targets(targets) do
      {:ok, canonical} ->
        ids = Map.keys(canonical)
        rows = lock_in_seat_rows!(audit, ids)

        cond do
          length(rows) != length(ids) ->
            Repo.rollback(:not_found)

          Enum.any?(rows, &removal_stale?(&1, Map.fetch!(canonical, &1.id))) ->
            Repo.rollback(:stale)

          true ->
            delete_audited_records(rows, audit, operation_id)
        end

      :error ->
        Repo.rollback(:not_found)
    end
  end

  # The pair write's own delete and audit, over exactly the rows this command
  # locked, so removal and a `:not_stated` write log identically (R3, INV-5).
  defp delete_audited_records(rows, audit, operation_id) do
    case delete_audited_transfers!(rows, audit, operation_id, Enum.map(rows, & &1.id)) do
      :ok -> length(rows)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # R4/INV-1: the transfer rows are the last lock a command takes, in id order.
  # Removal takes only this lock — it never evaluates R1, so it holds no block
  # writer's locks and can never invert INV-1's order.
  defp lock_in_seat_rows!(audit, ids) do
    from(t in Transfer,
      where:
        t.organization_id == ^audit.organization_id and
          t.gtfs_version_id == ^audit.gtfs_version_id and t.transfer_type in ^@in_seat_types and
          t.id in ^ids,
      order_by: [asc: t.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

  # The shapes are checked before the transaction opens, and grouping on the
  # canonical UUID makes two spellings of one id a single target whose conflicting
  # timestamps are `:stale` (R7, INV-4).
  defp removal_targets(pairs) when is_list(pairs) and pairs != [] do
    Enum.reduce_while(pairs, {:ok, %{}}, &accumulate_removal_target/2)
  end

  defp removal_targets(_pairs), do: {:error, :invalid_input}

  defp accumulate_removal_target(pair, {:ok, targets}) do
    case removal_target(pair) do
      {:ok, id, timestamp} -> continue_removal_target(targets, id, timestamp)
      :error -> {:halt, {:error, :invalid_input}}
    end
  end

  defp continue_removal_target(targets, id, timestamp) do
    case Map.fetch(targets, id) do
      :error -> {:cont, {:ok, Map.put(targets, id, timestamp)}}
      {:ok, existing} -> halt_or_keep(targets, existing, timestamp)
    end
  end

  defp halt_or_keep(targets, existing, timestamp) do
    if same_timestamp?(existing, timestamp),
      do: {:cont, {:ok, targets}},
      else: {:halt, {:error, :stale}}
  end

  defp removal_target({id, %DateTime{} = timestamp}) when is_binary(id),
    do: {:ok, canonical_uuid(id), timestamp}

  defp removal_target({id, timestamp}) when is_binary(id) and is_binary(timestamp),
    do: {:ok, canonical_uuid(id), timestamp}

  defp removal_target(_pair), do: :error

  # An id that is not a UUID cannot name a row, so it keeps its raw form and
  # fails later with `:not_found` rather than `:invalid_input`.
  defp canonical_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  # The locked rows are matched back by canonical UUID, so a differently cased id
  # still finds its row.
  defp cast_removal_targets(targets) do
    Enum.reduce_while(targets, {:ok, %{}}, fn {id, timestamp}, {:ok, acc} ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, {:ok, Map.put(acc, uuid, timestamp)}}
        :error -> {:halt, :error}
      end
    end)
  end

  # INV-4: the caller's timestamp may be the stored `DateTime` or its ISO 8601
  # form; anything missing or unparseable is stale, so a delete is never blind.
  defp removal_stale?(row, expected_updated_at) do
    case normalize_removal_timestamp(expected_updated_at) do
      %DateTime{} = expected -> DateTime.compare(row.updated_at, expected) != :eq
      nil -> true
    end
  end

  defp same_timestamp?(first, second),
    do: normalize_removal_timestamp(first) == normalize_removal_timestamp(second)

  defp normalize_removal_timestamp(%DateTime{} = value), do: value

  defp normalize_removal_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp normalize_removal_timestamp(_value), do: nil

  # The whole command body, so the rollback decisions stay at one depth. R4's lock
  # order runs first (the rule under the block writers' locks, then the pair's rows),
  # then the guard, then the write. A refusal is this command's own rollback, so the
  # locks are released with the rest of the transaction and nothing is written.
  defp write_connection({from_trip_id, to_trip_id} = pair, choice, expected, audit, operation_id) do
    Authorization.lock_editor!(audit)
    endpoints = locked_endpoints!(audit, pair)
    rows = lock_pair_rows!(audit, from_trip_id, to_trip_id)

    if expected_matches?(rows, expected) do
      case write_pair(choice, endpoints, rows, audit, operation_id) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      Repo.rollback(:stale)
    end
  end

  # R1: one rule function, evaluated under the block writers' locks, with the
  # locked trip rows the stops come from (CR-2, INV-1). The version read,
  # advisory lock and trip locks all happen inside it. A version of another
  # organization rolls the transaction back with `:not_found`; a trip this
  # version does not hold comes back as a nil row, which is the same answer for
  # a pair.
  defp locked_endpoints!(audit, pair) do
    audit
    |> Blocking.lock_and_check_connections!([pair])
    |> Map.fetch!(pair)
    |> found_endpoints!()
  end

  defp found_endpoints!(%{from: from, to: to}) when is_nil(from) or is_nil(to),
    do: Repo.rollback(:not_found)

  defp found_endpoints!(%{from: _, to: _} = endpoints), do: endpoints

  # R3: "the connection's record" is every type 4/5 row naming the pair, whatever
  # its stops. Locked in id order, the last lock the write takes (R4, INV-1).
  defp lock_pair_rows!(audit, from_trip_id, to_trip_id) do
    audit
    |> lock_pairs_rows!([{from_trip_id, to_trip_id}])
    |> Map.get({from_trip_id, to_trip_id}, [])
  end

  # The bulk command's one row lock: every listed pair's rows in a single query, in
  # the same id order the single write locks them in, grouped by pair for the
  # per-pair write. A from/to combination the command did not list is locked too,
  # because the query carries the two id lists rather than the pair list; that is
  # more of R4's one lock order, never a different one.
  defp lock_pairs_rows!(audit, pairs) do
    from_trip_ids = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    to_trip_ids = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    from(t in Transfer,
      where:
        t.organization_id == ^audit.organization_id and
          t.gtfs_version_id == ^audit.gtfs_version_id and
          t.transfer_type in ^@in_seat_types and t.from_trip_id in ^from_trip_ids and
          t.to_trip_id in ^to_trip_ids,
      order_by: [asc: t.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
    |> Enum.group_by(&{&1.from_trip_id, &1.to_trip_id})
  end

  # -- R6, the bulk command --------------------------------------------------

  # Every lock R4 orders is taken once for the whole command, then the pairs are
  # written in the reviewer's input order. The result names what changed, never
  # what was merely attempted.
  defp write_entries(entries, choice, audit, operation_id) do
    Authorization.lock_editor!(audit)
    pairs = Enum.map(entries, & &1.pair)
    checks = Blocking.lock_and_check_connections!(audit, pairs)
    rows_by_pair = lock_pairs_rows!(audit, pairs)

    {written, skipped} =
      Enum.reduce(entries, {[], []}, fn entry, {written, skipped} ->
        case write_entry(entry, choice, checks, rows_by_pair, audit, operation_id) do
          {:saved, result} -> {[{entry.pair, result} | written], skipped}
          {:skipped, reason} -> {written, [%{pair: entry.pair, reason: reason} | skipped]}
        end
      end)

    %{
      saved: written |> Enum.reverse() |> Enum.map(fn {pair, _result} -> pair end),
      skipped: Enum.reverse(skipped),
      operation_id: written_operation_id(written, operation_id)
    }
  end

  # A trip this version does not hold is R5's `:not_found`, decided from the one
  # rule call's answer rather than by a second query.
  defp write_entry(entry, choice, checks, rows_by_pair, audit, operation_id) do
    case Map.get(checks, entry.pair) do
      %{from: from, to: to, check: check} when not is_nil(from) and not is_nil(to) ->
        write_guarded_entry(
          choice,
          %{from: from, to: to, check: check},
          entry,
          rows_by_pair,
          audit,
          operation_id
        )

      _missing ->
        {:skipped, :not_found}
    end
  end

  # R4: the same guard, over the rows this command locked for the pair. A pair the
  # guard stops is skipped and the other pairs still commit (R6).
  defp write_guarded_entry(choice, endpoints, entry, rows_by_pair, audit, operation_id) do
    rows = Map.get(rows_by_pair, entry.pair, [])

    if expected_matches?(rows, entry.expected) do
      write_pair_in_batch(choice, endpoints, rows, audit, operation_id)
    else
      {:skipped, :stale}
    end
  end

  # The one per-pair write, shared with the single save. The only difference
  # between the two callers is what a refusal means: here it skips this pair and
  # leaves the other pairs' rows exactly as they were, because a refusal is a
  # returned value and not this command's rollback. An audit failure and a row the
  # database would not take still roll the whole batch back, because neither is a
  # pair-level reason R6 names.
  defp write_pair_in_batch(choice, endpoints, rows, audit, operation_id) do
    case write_pair(choice, endpoints, rows, audit, operation_id) do
      {:ok, result} ->
        {:saved, result}

      {:error, {:refused, _} = reason} ->
        {:skipped, reason}

      {:error, {:audit_failed, _} = reason} ->
        Repo.rollback(reason)

      {:error, %Ecto.Changeset{} = changeset} ->
        Repo.rollback(changeset)
    end
  end

  # One operation id for the command, reported only when a pair actually changed
  # something — the same rule the single save reports it under (INV-5).
  defp written_operation_id(written, operation_id) do
    if Enum.any?(written, fn {_pair, result} -> result.operation_id end) do
      operation_id
    end
  end

  # The bound, the shapes and the uniqueness, all before a transaction opens.
  defp validate_entries(entries) when is_list(entries) do
    with :ok <- check_bulk_size(entries),
         :ok <- check_entry_shapes(entries),
         :ok <- check_unique_pairs(entries) do
      {:ok, entries}
    end
  end

  defp validate_entries(_entries), do: {:error, :invalid_input}

  defp check_bulk_size(entries) when length(entries) > @max_bulk_pairs, do: {:error, :too_many}
  defp check_bulk_size(_entries), do: :ok

  defp check_entry_shapes(entries) do
    if Enum.all?(entries, &bulk_entry?/1), do: :ok, else: {:error, :invalid_input}
  end

  defp check_unique_pairs(entries) do
    pairs = Enum.map(entries, & &1.pair)

    if Enum.uniq(pairs) == pairs do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp bulk_entry?(%{pair: {from_trip_id, to_trip_id}, expected: expected})
       when is_binary(from_trip_id) and is_binary(to_trip_id) and is_list(expected),
       do: Enum.all?(expected, &expected_row?/1)

  defp bulk_entry?(_entry), do: false

  defp expected_row?(%{id: id, transfer_type: type, updated_at: %DateTime{}})
       when is_binary(id),
       do: type in @in_seat_types

  defp expected_row?(%{id: id, transfer_type: type, updated_at: updated_at})
       when is_binary(id) and is_binary(updated_at),
       do: type in @in_seat_types

  defp expected_row?(_row), do: false

  # R4: the guard compares the locked rows with the list the editor saw, so a
  # session that saved in between ends `:stale` instead of overwriting (AC-4).
  # A row the editor never saw is a mismatch in both directions.
  defp expected_matches?(rows, expected) when is_list(expected) do
    seen = rows |> Enum.map(&expected_entry/1) |> Enum.sort_by(& &1.id)
    asked = expected |> Enum.map(&asked_entry/1) |> Enum.sort_by(& &1.id)

    seen == asked
  end

  defp expected_matches?(_rows, _expected), do: false

  defp expected_entry(%Transfer{} = row),
    do: %{id: row.id, transfer_type: row.transfer_type, updated_at: row.updated_at}

  defp asked_entry(%{id: id, transfer_type: type, updated_at: %DateTime{} = updated_at}),
    do: %{id: id, transfer_type: type, updated_at: updated_at}

  # A caller may spell a timestamp as an ISO 8601 string; a value of any other
  # shape cannot name a row and so never matches.
  defp asked_entry(%{id: id, transfer_type: type, updated_at: updated_at})
       when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, parsed, _offset} ->
        %{id: id, transfer_type: type, updated_at: parsed}

      {:error, _reason} ->
        nil
    end
  end

  defp asked_entry(_entry), do: nil

  # The per-pair write, shared by the single and the bulk command: it decides the
  # choice against the locked rule and rows, and answers the row the command left
  # plus the operation id its logs carry, or nil when nothing changed. A refusal, a
  # rejected changeset and an audit failure are returned rather than raised, because
  # what a refusal means is the caller's decision: `set_connection/5` rolls its whole
  # command back, and the bulk command skips this pair and commits the rest (R6).
  defp write_pair(choice, endpoints, rows, audit, operation_id) do
    case choice do
      :not_stated -> clear_pair_rows(rows, audit, operation_id)
      recorded -> write_record(recorded, endpoints, rows, audit, operation_id)
    end
  end

  # R3: "Not stated" deletes every row of the pair, whatever its stops, and is
  # never refused by R1.
  defp clear_pair_rows([], _audit, _operation_id),
    do: {:ok, %{choice: :not_stated, transfer: nil, operation_id: nil}}

  defp clear_pair_rows(rows, audit, operation_id) do
    with :ok <- delete_audited_transfers!(rows, audit, operation_id, Enum.map(rows, & &1.id)) do
      {:ok, %{choice: :not_stated, transfer: nil, operation_id: operation_id}}
    end
  end

  defp write_record(choice, endpoints, rows, audit, operation_id) do
    with :ok <- checked(endpoints.check),
         {:ok, attrs} <- record_attrs(choice, endpoints),
         {:ok, transfer, saved?} <- keep_one_row!(attrs, rows, audit, operation_id) do
      # A choice that changed nothing — a matching record already carrying the
      # saved type and the endpoint stops, with no other row of the pair — wrote
      # no log, so it reports no operation id (AC-3).
      {:ok,
       %{
         choice: choice,
         transfer: transfer,
         operation_id: if(saved? or replaced_rows(rows) != [], do: operation_id, else: nil)
       }}
    end
  end

  # R3: the pair holds one row afterwards — its first row by id is kept and the
  # others go.
  #
  # The siblings are deleted first: the six-field key is unique per version and
  # does not include the type, so saving the kept row's new stops before these rows
  # are gone would collide with one of them. Every check that can refuse or reject
  # the pair has already answered by this point, so the only failure left after the
  # deletes is one the caller rolls its whole command back for, and no command ever
  # commits half a pair.
  defp keep_one_row!(attrs, rows, audit, operation_id) do
    kept = first_row(rows)
    affected_ids = affected_ids(rows, kept)

    with :ok <- delete_audited_transfers!(replaced_rows(rows), audit, operation_id, affected_ids) do
      save_record(attrs, kept, affected_ids, audit, operation_id)
    end
  end

  # R1: the save refuses exactly what the drawer's pre-check refuses, with the
  # rule's own state carried through. `:not_stated` never reaches this clause.
  defp checked(:ok), do: :ok
  defp checked({:refused, state}), do: {:error, {:refused, state}}

  # R2: the handoff stops are the locked trip rows' own endpoints, and a trip
  # with no endpoint stop cannot be written: it is already refused as
  # `:unconfirmed, :untimed` by the rule, and this keeps a stopless row from
  # being written if the rule ever stops saying so.
  defp record_attrs(choice, endpoints) do
    with {:ok, from_stop_id} <- endpoint_stop(endpoints.from, :last_stop),
         {:ok, to_stop_id} <- endpoint_stop(endpoints.to, :first_stop) do
      {:ok,
       %{
         transfer_type: transfer_type(choice),
         from_trip_id: endpoints.from.trip_id,
         to_trip_id: endpoints.to.trip_id,
         from_stop_id: from_stop_id,
         to_stop_id: to_stop_id
       }}
    end
  end

  defp endpoint_stop(%{last_stop: %{stop_id: stop_id}}, :last_stop) when is_binary(stop_id),
    do: {:ok, stop_id}

  defp endpoint_stop(%{first_stop: %{stop_id: stop_id}}, :first_stop) when is_binary(stop_id),
    do: {:ok, stop_id}

  defp endpoint_stop(_row, _key), do: {:error, {:refused, {:unconfirmed, :untimed}}}

  defp transfer_type(:stay_on_board), do: 4
  defp transfer_type(:must_reboard), do: 5

  # The pair's first row by id is kept; the lock order is that id order, so this is
  # the same row every session would keep.
  defp first_row([]), do: nil
  defp first_row([kept | _replaced]), do: kept

  defp replaced_rows([]), do: []
  defp replaced_rows([_kept | replaced]), do: replaced

  # R2/R3: keep the first row by id, changing only its type and stops. A row
  # already carrying the chosen type and the endpoint stops is the choice the
  # editor already made, so no UPDATE and no log run.
  defp save_record(attrs, nil, affected_ids, audit, operation_id) do
    %Transfer{organization_id: audit.organization_id, gtfs_version_id: audit.gtfs_version_id}
    |> Transfer.in_seat_changeset(attrs)
    |> insert_created_transfer(affected_ids, audit, operation_id)
  end

  defp save_record(attrs, kept, affected_ids, audit, operation_id) do
    case Transfer.in_seat_changeset(kept, attrs) do
      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, changeset}

      %Ecto.Changeset{changes: changes} when changes == %{} ->
        {:ok, kept, false}

      changeset ->
        persist_updated_transfer(changeset, kept, affected_ids, audit, operation_id)
    end
  end

  defp insert_created_transfer(changeset, affected_ids, audit, operation_id) do
    case Repo.insert(changeset) do
      {:ok, transfer} ->
        case audit_created_transfer(transfer, audit, operation_id, [transfer.id | affected_ids]) do
          :ok -> {:ok, transfer, true}
          {:error, _reason} = error -> error
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp persist_updated_transfer(changeset, transfer, affected_ids, audit, operation_id) do
    before_snapshot = Transfer.audit_snapshot(transfer)
    ids = Enum.uniq([transfer.id | affected_ids])

    case Repo.update(changeset) do
      {:ok, updated} ->
        case audit_updated_transfer(updated, before_snapshot, audit, operation_id, ids) do
          :ok -> {:ok, updated, true}
          {:error, _reason} = error -> error
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # R3: the pair's other rows go with the kept one, each deleted and audited with
  # its own `"deleted"` log sharing the command's operation id and naming every
  # affected row (INV-5). The rows are already locked, so the delete takes them
  # in the same id order and needs no further lock.
  defp delete_audited_transfers!([], _audit, _operation_id, _affected_ids), do: :ok

  defp delete_audited_transfers!(rows, audit, operation_id, affected_ids) do
    deleted_ids = Enum.map(rows, & &1.id)

    with {_count, _returned} <-
           Repo.delete_all(
             from(t in Transfer,
               where:
                 t.organization_id == ^audit.organization_id and
                   t.gtfs_version_id == ^audit.gtfs_version_id and t.id in ^deleted_ids
             )
           ) do
      audit_deletions(rows, affected_ids, operation_id, audit)
    end
  end

  defp audit_deletions(rows, affected_ids, operation_id, audit) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case audit_deleted_transfer(
             row,
             Transfer.audit_snapshot(row),
             affected_ids,
             operation_id,
             audit
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Every row the command affected: the kept row (or the inserted one, when there
  # was none) plus every row it removed, so one log reconstructs the whole command
  # (R9).
  defp affected_ids(rows, kept) do
    kept_id = if kept, do: [kept.id], else: [nil]

    (Enum.map(rows, & &1.id) ++ kept_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp audit_created_transfer(transfer, audit, operation_id, affected_ids) do
    record_transfer_change(audit, transfer, "created", %{
      before: nil,
      after: Transfer.audit_snapshot(transfer),
      operation_id: operation_id,
      affected_transfer_ids: affected_ids
    })
  end

  defp audit_updated_transfer(transfer, before_snapshot, audit, operation_id, affected_ids) do
    record_transfer_change(audit, transfer, "updated", %{
      before: before_snapshot,
      after: Transfer.audit_snapshot(transfer),
      operation_id: operation_id,
      affected_transfer_ids: affected_ids
    })
  end

  defp audit_deleted_transfer(transfer, before_snapshot, affected_ids, operation_id, audit) do
    record_transfer_change(audit, transfer, "deleted", %{
      before: before_snapshot,
      after: nil,
      operation_id: operation_id,
      affected_transfer_ids: affected_ids
    })
  end

  # An audit failure is the caller's rollback: no record is ever written unaudited
  # (INV-5), and the caller decides whether that is one pair or a whole command.
  defp record_transfer_change(audit, transfer, action, attrs) do
    case Audit.record_change_in_transaction(audit, :transfer, transfer, action, attrs) do
      {:ok, _log} -> :ok
      {:error, changeset} -> {:error, {:audit_failed, changeset}}
    end
  end

  defp validate_choice(choice) when choice in @choices, do: :ok
  defp validate_choice(_choice), do: {:error, :invalid_choice}

  # Bounded retry over the configured transaction module, the same loop
  # `Transfers` and `Blocking` keep privately (R4). A serialization failure
  # (40001) or a deadlock (40P01) retries the whole transaction; every other
  # failure is returned unchanged.
  defp run_write(transaction, attempts \\ @write_attempts) do
    case run_write_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_failure, _error} ->
        retry_write(transaction, attempts)

      {:error, reason} ->
        if retryable?(reason),
          do: retry_write(transaction, attempts),
          else: {:error, reason}
    end
  end

  defp retry_write(transaction, attempts) when attempts > 1,
    do: run_write(transaction, attempts - 1)

  defp retry_write(_transaction, _attempts), do: {:error, :busy}

  defp run_write_transaction(transaction) do
    write_transaction_module().run(transaction)
  rescue
    error in Postgrex.Error ->
      if retryable?(error) do
        {:retryable_failure, error}
      else
        reraise error, __STACKTRACE__
      end
  end

  defp write_transaction_module do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    )
  end

  defp retryable?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:serialization_failure, "40001", :deadlock_detected, "40P01"],
       do: true

  defp retryable?(_error), do: false
end

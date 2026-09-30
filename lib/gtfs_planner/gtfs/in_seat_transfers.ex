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
    locks is `:stale` with no write. Locks are taken in the one order: the scoped
    published version `FOR SHARE` read and the calendar reads, then the
    `blocking:<version>` advisory lock, then the named trips and their blocks'
    trips `FOR UPDATE` in UUID order (all inside
    `lock_and_check_connections!/2`), then the pair's transfer rows `FOR UPDATE`
    in id order. Serialization failures and deadlocks retry three attempts and
    then answer `:busy`.
  - **R5 — scope.** Organization, version and actor come from the audit context
    only. A trip ID naming no trip of that version is `:not_found`, so a crafted
    event cannot write a foreign tenant's pair.

  The write runs in this module's own three-attempt retry loop over the
  configured `ReviewedApplyTransaction` module, copied from `Transfers` and
  `Blocking` rather than shared with them; extracting one loop is a later
  package's decision.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Blocking
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Transfer
  alias GtfsPlanner.Repo

  @write_attempts 3
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
  alone, so a foreign tenant or version in the request cannot be written.

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

  # The whole command body, so the rollback decisions stay at one depth. R4's lock
  # order runs first (the rule under the block writers' locks, then the pair's rows),
  # then the guard, then the write.
  defp write_connection({from_trip_id, to_trip_id} = pair, choice, expected, audit, operation_id) do
    endpoints = locked_endpoints!(audit, pair)
    rows = lock_pair_rows!(audit, from_trip_id, to_trip_id)

    if expected_matches?(rows, expected) do
      write_pair!(choice, endpoints, rows, audit, operation_id)
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
    %{from: from, to: to, check: check} =
      Map.fetch!(Blocking.lock_and_check_connections!(audit, [pair]), pair)

    if is_nil(from) or is_nil(to) do
      Repo.rollback(:not_found)
    else
      %{from: from, to: to, check: check}
    end
  end

  # R3: "the connection's record" is every type 4/5 row naming the pair, whatever
  # its stops. Locked in id order, the last lock the write takes (R4, INV-1).
  defp lock_pair_rows!(audit, from_trip_id, to_trip_id) do
    from(t in Transfer,
      where:
        t.organization_id == ^audit.organization_id and
          t.gtfs_version_id == ^audit.gtfs_version_id and
          t.transfer_type in ^@in_seat_types and t.from_trip_id == ^from_trip_id and
          t.to_trip_id == ^to_trip_id,
      order_by: [asc: t.id],
      lock: "FOR UPDATE"
    )
    |> Repo.all()
  end

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

  # The per-pair write, shared with the bulk command: it decides the choice
  # against the locked rule and rows, and answers the row the command left plus
  # the operation id its logs carry, or nil when nothing changed.
  defp write_pair!(choice, endpoints, rows, audit, operation_id) do
    case choice do
      :not_stated -> clear_pair_rows(rows, audit, operation_id)
      recorded -> write_record(recorded, endpoints, rows, audit, operation_id)
    end
  end

  # R3: "Not stated" deletes every row of the pair, whatever its stops, and is
  # never refused by R1.
  defp clear_pair_rows([], _audit, _operation_id),
    do: %{choice: :not_stated, transfer: nil, operation_id: nil}

  defp clear_pair_rows(rows, audit, operation_id) do
    delete_audited_transfers!(rows, audit, operation_id, Enum.map(rows, & &1.id))

    %{choice: :not_stated, transfer: nil, operation_id: operation_id}
  end

  defp write_record(choice, endpoints, rows, audit, operation_id) do
    with :ok <- checked(endpoints.check),
         {:ok, attrs} <- record_attrs(choice, endpoints) do
      kept = first_row(rows)
      replaced = replaced_rows(rows)
      affected_ids = affected_ids(rows, kept)

      # The pair's other rows go first (R3). The six-field key is unique per
      # version and does not include the type, so saving the kept row's new stops
      # before these rows are gone would collide with one of them. They are locked
      # already, so deleting them here and updating the kept row below stays inside
      # R4's one lock order.
      delete_audited_transfers!(replaced, audit, operation_id, affected_ids)

      with {:ok, transfer, saved?} <- save_record(attrs, kept, affected_ids, audit, operation_id) do
        # A choice that changed nothing — a matching record already carrying the
        # saved type and the endpoint stops, with no other row of the pair — wrote
        # no log, so it reports no operation id (AC-3).
        %{
          choice: choice,
          transfer: transfer,
          operation_id: if(saved? or replaced != [], do: operation_id, else: nil)
        }
      end
    else
      # A refusal is this command's own rollback, so the locks are released with the
      # rest of the transaction and nothing is written.
      {:error, reason} -> Repo.rollback(reason)
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
        Repo.rollback(changeset)

      %Ecto.Changeset{changes: changes} when changes == %{} ->
        {:ok, kept, false}

      changeset ->
        persist_updated_transfer(changeset, kept, affected_ids, audit, operation_id)
    end
  end

  defp insert_created_transfer(
         %Ecto.Changeset{valid?: false} = changeset,
         _affected,
         _audit,
         _id
       ),
       do: Repo.rollback(changeset)

  defp insert_created_transfer(changeset, affected_ids, audit, operation_id) do
    case Repo.insert(changeset) do
      {:ok, transfer} ->
        audit_created_transfer(transfer, audit, operation_id, [transfer.id | affected_ids])
        {:ok, transfer, true}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp persist_updated_transfer(changeset, transfer, affected_ids, audit, operation_id) do
    before_snapshot = Transfer.audit_snapshot(transfer)

    case Repo.update(changeset) do
      {:ok, updated} ->
        audit_updated_transfer(
          updated,
          before_snapshot,
          audit,
          operation_id,
          Enum.uniq([updated.id | affected_ids])
        )

        {:ok, updated, true}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  # R3: the pair's other rows go with the kept one, each deleted and audited with
  # its own `"deleted"` log sharing the command's operation id and naming every
  # affected row (INV-5). The rows are already locked, so the delete takes them
  # in the same id order and needs no further lock.
  defp delete_audited_transfers!([], _audit, _operation_id, _affected_ids), do: :ok

  defp delete_audited_transfers!(rows, audit, operation_id, affected_ids) do
    deleted_ids = Enum.map(rows, & &1.id)

    Repo.delete_all(
      from(t in Transfer,
        where:
          t.organization_id == ^audit.organization_id and
            t.gtfs_version_id == ^audit.gtfs_version_id and t.id in ^deleted_ids
      )
    )

    Enum.each(rows, fn row ->
      audit_deleted_transfer(row, Transfer.audit_snapshot(row), affected_ids, operation_id, audit)
    end)

    :ok
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

  # An audit failure rolls the whole command back, so a record is never written
  # unaudited (INV-5).
  defp record_transfer_change(audit, transfer, action, attrs) do
    case Gtfs.record_change_in_transaction(audit, :transfer, transfer, action, attrs) do
      {:ok, _log} -> :ok
      {:error, changeset} -> Repo.rollback({:audit_failed, changeset})
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

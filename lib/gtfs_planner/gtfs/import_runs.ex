defmodule GtfsPlanner.Gtfs.ImportRuns do
  @moduledoc """
  Sole production owner of organization-scoped, row-locked, transactional
  import-run + GTFS-version transitions.

  Every coupled transition below runs inside a single `Repo.transaction/1`,
  takes a `FOR UPDATE` row lock on both the run (by organization + id) and the
  version (by organization + gtfs_version_id), and applies a conditional
  predicate on the current run/version state pair before writing. This is the
  only module that changes both a run and its target version in one commit,
  which is the durability guarantee behind AC-5/AC-7/AC-8/AC-9/AC-10/AC-11.

  Lifecycle, lease, and timestamp fields are system-owned: they are never cast
  from user parameters. The only caller-influenced surface is the failure/result
  count detail, which is validated by the `Run` changeset against a fixed
  allowlist. Leases use PostgreSQL time only so a stale owner in another process
  or node can never overwrite a newer state.

  User-originated transitions (creating an import target, claiming a cleanup,
  retrying a publication) and publication itself reauthorize their actor inside
  the transaction: run row first, then the actor's editor membership, then the
  version (INV-1). A refused actor rolls back with `{:error, :forbidden}` and
  writes nothing. Lease expiry, reconciliation and failure closure are system
  owned and never confer editor rights.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Gtfs.Import.{Failure, Result}

  @type actor :: %{required(:id) => Ecto.UUID.t(), required(:email) => String.t()}

  @lease_seconds Application.compile_env(:gtfs_planner, :import_lease_seconds, 300)
  @lease_placeholder ~U[1970-01-01 00:00:00.000000Z]

  # Reason codes of runs that closed before any row was imported, with their staging
  # version deleted. Neither offers a recovery action.
  @unimported_reason_codes ~w(busy source_not_installed)

  # Macro: applies values to a single run row via `update_all`. DB-time columns
  # use PostgreSQL time: pass `:now` (CURRENT_TIMESTAMP) or `:lease`
  # (CURRENT_TIMESTAMP + configured interval). Plain values pass through.
  # `fragment` calls are generated *inside* the `from` query builder so they are
  # never invoked as standalone expressions (which Ecto forbids).
  defmacrop set_run(run_id_expr, set) do
    pairs =
      Enum.map(set, fn
        {field, :lease} ->
          {field,
           quote do
             fragment(
               "CURRENT_TIMESTAMP + (? * interval '1 second')",
               unquote(@lease_seconds)
             )
           end}

        {field, value} ->
          {field,
           quote do
             ^unquote(value)
           end}
      end)

    quote do
      from(r in Run, where: r.id == ^unquote(run_id_expr), update: [set: unquote(pairs)])
      |> Repo.update_all([])

      :ok
    end
  end

  # --- creation -------------------------------------------------------------

  @doc """
  Creates a staging version and a pending run carrying a preparation lease in one
  transaction.

  The run snapshots the initiating actor id/email and the version name, carries a
  fresh lease token and a database-time expiry, and starts with
  `counts_complete: false`. Returns `{:ok, %{run: run, version: version}}`, or
  `{:error, :forbidden}` without creating anything when the actor no longer has
  an active editor membership in the organization.
  """
  @spec create_pending_target(Ecto.UUID.t(), actor(), %{name: String.t()}) ::
          {:ok, %{run: Run.t(), version: GtfsVersion.t()}}
          | {:error, Ecto.Changeset.t() | :forbidden}
  def create_pending_target(organization_id, actor, %{name: name}) do
    transaction(fn ->
      lock_actor!(organization_id, actor)

      case Versions.create_staging_gtfs_version(organization_id, %{name: name}) do
        {:ok, version} ->
          run_id = Ecto.UUID.generate()
          token = Ecto.UUID.generate()

          attrs = %{
            id: run_id,
            organization_id: organization_id,
            gtfs_version_id: version.id,
            version_name: version.name,
            state: "pending",
            counts_complete: false,
            lease_token: token,
            lease_expires_at: @lease_placeholder,
            actor_id: actor.id,
            actor_email: actor.email,
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }

          case Repo.insert_all(Run, [attrs]) do
            {1, nil} ->
              set_run(run_id, lease_expires_at: :lease)

              {:ok, %{run: Repo.get!(Run, run_id), version: Repo.get!(GtfsVersion, version.id)}}

            {0, nil} ->
              Repo.rollback(:insert_failed)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Atomically closes a pending run and its staging version when upload
  preparation fails before a runner can claim the import.
  """
  @spec fail_pending_target(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, Run.t(), GtfsVersion.t()} | {:error, term()}
  def fail_pending_target(organization_id, run_id, lease_token, reason) do
    transaction(fn ->
      organization_id
      |> lock_run(run_id)
      |> fail_pending_locked(organization_id, lease_token, reason)
    end)
  end

  defp fail_pending_locked(nil, _organization_id, _lease_token, _reason),
    do: {:error, :not_found}

  defp fail_pending_locked(run, organization_id, lease_token, reason) do
    case guard_lease(run, ~w(pending), lease_token) do
      :ok -> close_pending_target(organization_id, run, reason)
      :lease_lost -> {:error, :invalid_transition}
      :invalid_transition -> {:error, :invalid_transition}
    end
  end

  defp close_pending_target(organization_id, run, reason) do
    {:ok, version} =
      Versions.fail_unpublished_gtfs_version(organization_id, run.gtfs_version_id)

    {:ok, _} =
      run
      |> Run.system_changeset(%{
        state: "failed",
        lease_token: nil,
        lease_expires_at: nil,
        finished_at: DateTime.utc_now(),
        reason_code: publication_reason_code(reason)
      })
      |> Repo.update()

    {:ok, Repo.get!(Run, run.id), Repo.get!(GtfsVersion, version.id)}
  end

  @doc """
  Closes a pending run whose runner was refused because the supervisor was at
  capacity (`Runner.start_import/4` returned `{:error, :busy}`).

  The run must still be `pending` under `lease_token`, which proves no runner
  claimed it. It becomes `failed` with reason `busy`. Its staging version holds
  no imported rows, so the same transaction deletes it and the version name can
  be used again; a failed version would keep the name and block the retry.

  A run that was claimed, closed or re-leased in the meantime returns
  `{:error, :invalid_transition}` and nothing changes. This is a system closure:
  it does not reauthorize the actor, so a refusal still closes the run after the
  actor's access is revoked.
  """
  @spec fail_unstarted(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Run.t()} | {:error, :not_found | :invalid_transition}
  def fail_unstarted(organization_id, run_id, lease_token) do
    transaction(fn ->
      run = lock_run(organization_id, run_id)

      case guard_lease(run, ~w(pending), lease_token) do
        :ok -> close_unstarted(organization_id, run)
        :not_found -> {:error, :not_found}
        _stale -> {:error, :invalid_transition}
      end
    end)
  end

  defp close_unstarted(organization_id, run) do
    from(v in GtfsVersion,
      where:
        v.id == ^run.gtfs_version_id and v.organization_id == ^organization_id and
          v.publication_status == "staging"
    )
    |> Repo.delete_all()

    {:ok, _} =
      run
      |> Run.system_changeset(%{
        state: "failed",
        lease_token: nil,
        lease_expires_at: nil,
        finished_at: DateTime.utc_now(),
        reason_code: "busy"
      })
      |> Repo.update()

    {:ok, Repo.get!(Run, run.id)}
  end

  @doc """
  Closes a running import whose runner never received its source: the install deadline
  passed, the caller that was staging the upload exited, or staging failed.

  The run must be `running` under `lease_token` with an unexpired lease, which proves
  the calling runner still owns it. No worker started, so the importing version holds no
  imported rows and the same transaction deletes it; its name can be used again, which
  lets a person resubmit the files they kept. The run becomes `failed` with phase
  `upload` and reason `source_not_installed`. Like a run closed by `fail_unstarted/3`,
  it is not listed by `list_recoverable/1`: it left nothing to recover.

  A superseded owner (stale token or expired lease), a run in any other state, another
  organization's run and an unknown run return
  `{:error, :invalid_transition | :not_found}` and change nothing, so a runner that lost
  the run cannot delete a version another owner is importing into.
  """
  @spec fail_source_not_installed(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Run.t()} | {:error, :not_found | :invalid_transition}
  def fail_source_not_installed(organization_id, run_id, lease_token) do
    transaction(fn ->
      run = lock_run(organization_id, run_id)

      case guard_lease(run, ~w(running), lease_token) do
        :ok -> close_uninstalled(organization_id, run)
        :not_found -> {:error, :not_found}
        _stale -> {:error, :invalid_transition}
      end
    end)
  end

  defp close_uninstalled(organization_id, run) do
    from(v in GtfsVersion,
      where:
        v.id == ^run.gtfs_version_id and v.organization_id == ^organization_id and
          v.publication_status == "importing"
    )
    |> Repo.delete_all()

    failure = Failure.from_error(:source_not_installed, phase: :upload)

    {:ok, _} =
      run
      |> Run.system_changeset(
        Map.merge(Failure.to_run_attrs(failure), %{
          state: Failure.outcome_to_state(failure),
          lease_token: nil,
          lease_expires_at: nil,
          finished_at: DateTime.utc_now()
        })
      )
      |> Repo.update()

    {:ok, Repo.get!(Run, run.id)}
  end

  # --- lease claim / renew --------------------------------------------------

  @doc """
  Transitions a pending run to running and its staging version to importing,
  issuing a fresh execution lease (new token, new expiry).

  A wrong token, cross-organization request, or non-pending run returns the
  documented error and writes nothing (AC-8).
  """
  @spec claim_import(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Run.t(), GtfsVersion.t(), Ecto.UUID.t()}
          | {:error, :not_found | :invalid_transition | :lease_lost}
  def claim_import(organization_id, run_id, lease_token) do
    transaction(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {:error, :not_found}

        run ->
          case guard_lease(run, ~w(pending), lease_token) do
            :ok ->
              case Versions.claim_staging_gtfs_version(organization_id, run.gtfs_version_id) do
                {:ok, version} ->
                  new_token = Ecto.UUID.generate()

                  {:ok, _} =
                    run
                    |> Run.system_changeset(%{
                      state: "running",
                      lease_token: new_token,
                      started_at: DateTime.utc_now()
                    })
                    |> Repo.update()

                  set_run(run.id, lease_expires_at: :lease)

                  {:ok, Repo.get!(Run, run.id), Repo.get!(GtfsVersion, version.id), new_token}

                {:error, :not_found} ->
                  {:error, :not_found}

                {:error, :invalid_status_transition} ->
                  {:error, :invalid_transition}
              end

            :lease_lost ->
              {:error, :lease_lost}

            :invalid_transition ->
              {:error, :invalid_transition}
          end
      end
    end)
  end

  @doc """
  Renews the active lease on a pending, running or cleaning run using database
  time.

  The stored lease token must match; a stale owner (wrong token, already
  terminated run, or cross-organization request) receives `{:error, :lease_lost}`
  and writes nothing (AC-8). A cleanup runner renews the `cleaning` lease the same
  way an import runner renews `running` (AC-33).
  """
  @spec renew_lease(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          :ok | {:error, :lease_lost}
  def renew_lease(organization_id, run_id, lease_token) do
    transaction(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {:error, :lease_lost}

        run ->
          case guard_lease(run, ~w(pending running cleaning), lease_token) do
            :ok ->
              lease_current? =
                from(r in Run,
                  where:
                    r.id == ^run.id and not is_nil(r.lease_expires_at) and
                      r.lease_expires_at >= fragment("CURRENT_TIMESTAMP")
                )
                |> Repo.exists?()

              if lease_current? do
                set_run(run.id, lease_expires_at: :lease)
                :ok
              else
                {:error, :lease_lost}
              end

            :lease_lost ->
              {:error, :lease_lost}

            :invalid_transition ->
              {:error, :lease_lost}
          end
      end
    end)
  end

  # --- owner fence ----------------------------------------------------------

  @doc """
  Fences a run-owned write: inside the caller's transaction, locks the run row
  `FOR SHARE` and returns it only when the run is in one of `expected_states`,
  holds `lease_token`, and its lease has not expired in database time.

  Otherwise it rolls the caller's transaction back with `:lease_lost`, so a
  superseded owner commits nothing. Call it as the first statement of each
  write transaction (INV-4). Outside `Repo.transaction/1` it raises
  `ArgumentError`, because the share lock would end with the statement.

  Inside a transaction the lock lasts until it ends, so a handover that needs
  the row `FOR UPDATE` (`reconcile_expired/1`, a terminal closure) waits for a
  batch that already passed the check, and every later batch fails it. The check
  never takes a membership lock; cleanup and batch writes are system-owned.

  The predicate is part of the locking read, so a row another transaction
  changed while this one waited is re-evaluated against its committed state.
  Expiry is judged at `CURRENT_TIMESTAMP`, the transaction's start, as in
  `renew_lease/3` and `reconcile_expired/1`; that is why the check comes first.
  """
  @spec assert_owner!(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t() | nil, [String.t()]) ::
          Run.t()
  def assert_owner!(organization_id, run_id, lease_token, expected_states) do
    if not Repo.in_transaction?() do
      raise ArgumentError,
            "assert_owner!/4 holds a row lock and must run inside Repo.transaction/1"
    end

    owner_run(organization_id, run_id, lease_token, expected_states) ||
      Repo.rollback(:lease_lost)
  end

  defp owner_run(_organization_id, _run_id, nil, _expected_states), do: nil

  defp owner_run(organization_id, run_id, lease_token, expected_states) do
    from(r in Run,
      where:
        r.id == ^run_id and r.organization_id == ^organization_id and
          r.state in ^expected_states and r.lease_token == ^lease_token and
          r.lease_expires_at >= fragment("CURRENT_TIMESTAMP"),
      lock: "FOR SHARE"
    )
    |> Repo.one()
  end

  # --- terminal: fail / publish --------------------------------------------

  @doc """
  Transitions a running run to its terminal failure state (one of `failed`,
  `partial`, `interrupted`) and fails the still-unpublished importing version.

  The failure's outcome determines the terminal state. The version is failed
  only when it is still `importing` (guarded by the conditional transition). A
  wrong token / cross-org / non-running run writes nothing (AC-8).
  """
  @spec fail_import(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Failure.t()) ::
          {:ok, Run.t(), GtfsVersion.t()} | {:error, term()}
  def fail_import(organization_id, run_id, lease_token, %Failure{} = failure) do
    transaction(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {:error, :not_found}

        run ->
          case guard_lease(run, ~w(running), lease_token) do
            :ok ->
              state = Failure.outcome_to_state(failure)

              {:ok, _} =
                run
                |> Run.system_changeset(
                  Map.merge(Failure.to_run_attrs(failure), %{
                    state: state,
                    lease_token: nil,
                    lease_expires_at: nil,
                    finished_at: DateTime.utc_now()
                  })
                )
                |> Repo.update()

              version = fail_run_version(organization_id, run)

              {:ok, Repo.get!(Run, run.id), Repo.get!(GtfsVersion, version.id)}

            :lease_lost ->
              {:error, :invalid_transition}

            :invalid_transition ->
              {:error, :invalid_transition}
          end
      end
    end)
  end

  defp fail_run_version(organization_id, %Run{gtfs_version_id: version_id} = _run) do
    case Versions.fail_unpublished_gtfs_version(organization_id, version_id) do
      {:ok, version} -> version
      {:error, :invalid_status_transition} -> Repo.get!(GtfsVersion, version_id)
    end
  end

  @doc """
  Couples a running run to `published` and its importing version to `published`
  with a database-time `published_at` and complete counts from `Result`.

  The conditional predicate (run running with the matching lease token, version
  importing) means a concurrent `fail_import` that attempts to close the same run
  loses the race: only one of the two lock-and-write sequences can win (AC-5).

  The run's actor must still hold an active editor membership when the lease is
  confirmed: the membership is locked after the run and the organization and
  before the version, and a revoked actor returns `{:error, :forbidden}` with the
  version unpublished and the run still `running`, so the caller can record the
  publication failure.

  The first version an organization publishes becomes its active schedule in the
  same transaction, and the change is announced after the commit
  (`Versions.active_schedule_topic/1`). A later import never replaces it.
  """
  @spec publish_import(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Result.t()) ::
          {:ok, Run.t(), GtfsVersion.t()} | {:error, term()}
  def publish_import(organization_id, run_id, lease_token, %Result{} = result) do
    transaction(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {:error, :not_found}

        run ->
          case guard_lease(run, ~w(running), lease_token) do
            :ok ->
              # Run, organization, then membership: see `Versions.lock_organization!/1`.
              Versions.lock_organization!(organization_id)
              lock_actor!(organization_id, %{id: run.actor_id})

              case Versions.publish_importing_gtfs_version(organization_id, run.gtfs_version_id) do
                {:ok, version} ->
                  {:ok, _} =
                    run
                    |> Run.system_changeset(
                      Map.merge(Result.to_run_attrs(result), %{
                        state: "published",
                        lease_token: nil,
                        lease_expires_at: nil,
                        finished_at: DateTime.utc_now()
                      })
                    )
                    |> Repo.update()

                  {:ok, Repo.get!(Run, run.id), Repo.get!(GtfsVersion, version.id)}

                {:error, :not_found} ->
                  {:error, :not_found}

                {:error, :invalid_status_transition} ->
                  {:error, :invalid_transition}
              end

            :lease_lost ->
              {:error, :invalid_transition}

            :invalid_transition ->
              {:error, :invalid_transition}
          end
      end
    end)
    |> announce_publication(organization_id)
  end

  @doc """
  Records a publication failure: sets the run to `publication_failed` with
  complete counts (`Result.to_run_attrs/1` minus state/timestamps, which
  `ImportRuns` sets), leaving the version in `importing`.

  A wrong token / cross-org / non-running run writes nothing (AC-8). The reason
  atom is sanitized into a bounded `reason_code`.
  """
  @spec record_publication_failure(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Result.t(),
          atom()
        ) ::
          {:ok, Run.t()} | {:error, term()}
  def record_publication_failure(organization_id, run_id, lease_token, %Result{} = result, reason) do
    transaction(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {:error, :not_found}

        run ->
          case guard_lease(run, ~w(running), lease_token) do
            :ok ->
              {:ok, _} =
                run
                |> Run.system_changeset(
                  Map.merge(Result.to_run_attrs(result), %{
                    state: "publication_failed",
                    lease_token: nil,
                    lease_expires_at: nil,
                    finished_at: DateTime.utc_now(),
                    reason_code: publication_reason_code(reason)
                  })
                )
                |> Repo.update()

              {:ok, Repo.get!(Run, run.id)}

            :lease_lost ->
              {:error, :invalid_transition}

            :invalid_transition ->
              {:error, :invalid_transition}
          end
      end
    end)
  end

  @doc """
  Guarded publication retry for a run in `publication_failed`.

  Locks both the run and its version and accepts ONLY the four required
  conditions:

    * `run.state == "publication_failed"`
    * `run.counts_complete == true`
    * `run.finished_at != nil`
    * `version.publication_status == "importing"`

  It reuses the existing database-time publication transition and never calls
  `Import.import_files/4` (AC-9). A run in any other state, or a version not in
  `importing`, is rejected (`:invalid_transition` / `:not_publishable`).

  `actor` is the user asking for the retry, not the run's original actor. Without
  an active editor membership the call returns `{:error, :forbidden}` and
  changes nothing.
  """
  @spec retry_publication(Ecto.UUID.t(), Ecto.UUID.t(), actor()) ::
          {:ok, Run.t(), GtfsVersion.t()}
          | {:error, :not_found | :invalid_transition | :not_publishable | :forbidden}
  def retry_publication(organization_id, run_id, actor) do
    transaction(fn ->
      case lock_run_for_publication(organization_id, run_id, actor) do
        nil ->
          {:error, :not_found}

        %Run{
          state: "publication_failed",
          counts_complete: true,
          finished_at: %DateTime{},
          gtfs_version_id: version_id
        } = run ->
          case Versions.publish_importing_gtfs_version(organization_id, version_id) do
            {:ok, version} ->
              {:ok, _} =
                run
                |> Run.system_changeset(%{
                  state: "published",
                  lease_token: nil,
                  lease_expires_at: nil,
                  finished_at: DateTime.utc_now()
                })
                |> Repo.update()

              {:ok, Repo.get!(Run, run.id), Repo.get!(GtfsVersion, version.id)}

            {:error, :not_found} ->
              {:error, :not_found}

            {:error, :invalid_status_transition} ->
              {:error, :not_publishable}
          end

        %Run{} ->
          {:error, :invalid_transition}
      end
    end)
    |> announce_publication(organization_id)
  end

  # --- cleanup claim / finish / fail ---------------------------------------

  @doc """
  Grants exactly one cleaning lease for a recoverable run.

  Only recoverable states (`failed`/`partial`/`interrupted`/`publication_failed`/
  `cleanup_failed`) are eligible; a run already `cleaning` (claimed) or terminal
  returns `:already_claimed` / `:invalid_transition`. A competing claim while a
  cleaning lease is held receives `{:error, :already_claimed}` (AC-11). The
  cleanup actor is snapshotted and must hold an active editor membership;
  otherwise the claim returns `{:error, :forbidden}` and changes nothing.
  """
  @spec claim_cleanup(Ecto.UUID.t(), Ecto.UUID.t(), actor()) ::
          {:ok, Run.t(), GtfsVersion.t(), Ecto.UUID.t()}
          | {:error, :not_found | :invalid_transition | :already_claimed | :forbidden}
  def claim_cleanup(organization_id, run_id, actor) do
    transaction(fn ->
      case lock_run_as_editor(organization_id, run_id, actor) do
        nil ->
          {:error, :not_found}

        %Run{state: "cleaning"} ->
          {:error, :already_claimed}

        %Run{state: state} = run
        when state in ~w(failed partial interrupted publication_failed cleanup_failed) ->
          token = Ecto.UUID.generate()

          {:ok, _} =
            run
            |> Run.system_changeset(%{
              state: "cleaning",
              lease_token: token,
              lease_expires_at: @lease_placeholder,
              finished_at: nil,
              cleanup_started_at: DateTime.utc_now(),
              cleanup_actor_email: actor.email
            })
            |> Repo.update()

          set_run(run.id, cleanup_actor_id: actor.id)
          set_run(run.id, lease_expires_at: :lease)

          version = Repo.get!(GtfsVersion, run.gtfs_version_id)

          {:ok, Repo.get!(Run, run.id), version, token}

        %Run{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  @doc """
  Closes a claimed cleanup as `cleaned`, atomically deleting the scoped target
  version and marking the run `cleaned` (terminal audit receipt) with
  `cleanup_finished_at`. The run retains its target and actor snapshots after
  the version row is removed. A wrong token / cross-org / non-cleaning run
  writes nothing (AC-8).
  """
  @spec finish_cleanup(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, Run.t()} | {:error, term()}
  def finish_cleanup(organization_id, run_id, lease_token) do
    transaction(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {:error, :not_found}

        run ->
          case guard_lease(run, ~w(cleaning), lease_token) do
            :ok ->
              from(v in GtfsVersion,
                where:
                  v.id == ^run.gtfs_version_id and
                    v.organization_id == ^organization_id
              )
              |> Repo.delete_all()

              {:ok, _} =
                run
                |> Run.system_changeset(%{
                  state: "cleaned",
                  lease_token: nil,
                  lease_expires_at: nil,
                  finished_at: DateTime.utc_now(),
                  cleanup_finished_at: DateTime.utc_now()
                })
                |> Repo.update()

              {:ok, Repo.get!(Run, run.id)}

            :lease_lost ->
              {:error, :invalid_transition}

            :invalid_transition ->
              {:error, :invalid_transition}
          end
      end
    end)
  end

  @doc """
  Records a cleanup failure, moving a `cleaning` run to `cleanup_failed` (where
  it remains retryable). A wrong token / cross-org / non-cleaning run writes
  nothing (AC-8). The reason atom is sanitized into a bounded `reason_code`.
  """
  @spec fail_cleanup(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, Run.t()} | {:error, term()}
  def fail_cleanup(organization_id, run_id, lease_token, reason) do
    transaction(fn ->
      case lock_run(organization_id, run_id) do
        nil ->
          {:error, :not_found}

        run ->
          case guard_lease(run, ~w(cleaning), lease_token) do
            :ok ->
              {:ok, _} =
                run
                |> Run.system_changeset(%{
                  state: "cleanup_failed",
                  lease_token: nil,
                  lease_expires_at: nil,
                  finished_at: DateTime.utc_now(),
                  reason_code: publication_reason_code(reason)
                })
                |> Repo.update()

              {:ok, Repo.get!(Run, run.id)}

            :lease_lost ->
              {:error, :invalid_transition}

            :invalid_transition ->
              {:error, :invalid_transition}
          end
      end
    end)
  end

  # --- reconciliation / adoption / queries ----------------------------------

  @doc """
  Reconciles expired leases for an organization.

  For each run in an active state (`pending`/`running`/`cleaning`) whose stored
  `lease_expires_at < CURRENT_TIMESTAMP`, conditionally closes it using the
  stored lease token so a stale owner cannot overwrite a newer state:

    * expired `pending`/`running` → `interrupted`, counts_complete false,
      version failed (AC-7)
    * expired `cleaning` → `cleanup_failed`, version stays `failed` (AC-11)

  Returns the list of runs that were reconciled.
  """
  @spec reconcile_expired(Ecto.UUID.t()) :: [Run.t()]
  def reconcile_expired(organization_id) do
    transaction(fn ->
      expired =
        from(r in Run,
          where: r.organization_id == ^organization_id,
          where: r.state in ^Run.active_states(),
          where: r.lease_expires_at < fragment("CURRENT_TIMESTAMP"),
          lock: "FOR UPDATE"
        )
        |> Repo.all()

      Enum.map(expired, fn run ->
        reconcile_one(organization_id, run)
      end)
    end)
  end

  defp reconcile_one(organization_id, %Run{
         state: state,
         id: id,
         gtfs_version_id: version_id,
         lease_token: token
       })
       when state in ~w(pending running) do
    {1, nil} =
      from(r in Run,
        where:
          r.id == ^id and r.organization_id == ^organization_id and
            r.state == ^state and r.lease_token == ^token and
            r.lease_expires_at < fragment("CURRENT_TIMESTAMP"),
        update: [
          set: [
            state: "interrupted",
            counts_complete: false,
            finished_at: ^DateTime.utc_now(),
            lease_token: nil,
            lease_expires_at: nil
          ]
        ]
      )
      |> Repo.update_all([])

    fail_run_version(organization_id, %Run{gtfs_version_id: version_id})
    Repo.get!(Run, id)
  end

  defp reconcile_one(organization_id, %Run{id: id, state: "cleaning", lease_token: token}) do
    {1, nil} =
      from(r in Run,
        where:
          r.id == ^id and r.organization_id == ^organization_id and
            r.state == "cleaning" and r.lease_token == ^token and
            r.lease_expires_at < fragment("CURRENT_TIMESTAMP"),
        update: [
          set: [
            state: "cleanup_failed",
            lease_token: nil,
            lease_expires_at: nil,
            finished_at: ^DateTime.utc_now()
          ]
        ]
      )
      |> Repo.update_all([])

    Repo.get!(Run, id)
  end

  @doc """
  Idempotently adopts runless legacy `failed` versions as `interrupted` runs with
  unknown actor/counts.

  For each `failed` version in the organization with no existing run, creates an
  `interrupted` run carrying the version name + `gtfs_version_id` snapshot, nil
  actor, and empty counts. Versions that already have a run are skipped, so the
  operation is safe to call repeatedly (AC-19). No counts or actor are invented.
  """
  @spec adopt_legacy_failed_targets(Ecto.UUID.t()) :: [Run.t()]
  def adopt_legacy_failed_targets(organization_id) do
    transaction(fn ->
      failed_version_ids =
        from(v in GtfsVersion,
          where: v.organization_id == ^organization_id,
          where: v.publication_status == "failed",
          select: v.id
        )
        |> Repo.all()

      existing_run_version_ids =
        from(r in Run,
          where: r.organization_id == ^organization_id,
          select: r.gtfs_version_id
        )
        |> Repo.all()

      adopted_versions =
        from(v in GtfsVersion,
          where: v.organization_id == ^organization_id,
          where: v.publication_status == "failed",
          where: v.id in ^failed_version_ids,
          where: v.id not in ^existing_run_version_ids,
          lock: "FOR UPDATE"
        )
        |> Repo.all()

      Enum.flat_map(adopted_versions, fn version ->
        run_id = Ecto.UUID.generate()

        attrs = %{
          id: run_id,
          organization_id: organization_id,
          gtfs_version_id: version.id,
          version_name: version.name,
          state: "interrupted",
          counts_complete: false,
          committed_counts: %{},
          finished_at: DateTime.utc_now(),
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }

        insert_adopted_run(attrs, run_id)
      end)
    end)
  end

  defp insert_adopted_run(attrs, run_id) do
    case Repo.insert_all(Run, [attrs],
           on_conflict: :nothing,
           conflict_target: :gtfs_version_id
         ) do
      {1, nil} -> [Repo.get!(Run, run_id)]
      {0, nil} -> []
    end
  end

  @doc """
  Returns the runs visible to the recovery UI for an organization, ordered
  deterministically by `updated_at DESC, id`. This includes both the active
  (pending/running/cleaning) and the recoverable terminal-but-unpublished states
  so the LiveView can render every in-flight and recoverable card. A run closed
  by `fail_unstarted/3` or `fail_source_not_installed/3` is not listed: it
  imported nothing and left nothing to recover.
  """
  @spec list_recoverable(Ecto.UUID.t()) :: [Run.t()]
  def list_recoverable(organization_id) do
    display_states = Run.active_states() ++ Run.recoverable_states()

    from(r in Run,
      where: r.organization_id == ^organization_id,
      where: r.state in ^display_states,
      where: r.state != "failed" or coalesce(r.reason_code, "") not in @unimported_reason_codes,
      order_by: [desc: r.updated_at, desc: r.id]
    )
    |> Repo.all()
  end

  @doc """
  Returns the stable PubSub topic for a run.
  """
  @spec topic(Run.t() | Ecto.UUID.t()) :: String.t()
  def topic(%Run{id: id}), do: "import:" <> id
  def topic(run_id) when is_binary(run_id), do: "import:" <> run_id

  # --- private helpers ------------------------------------------------------

  # Applies values to a single run row via an `update_all` query. DB-time columns
  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp lock_run(organization_id, run_id) do
    from(r in Run,
      where: r.id == ^run_id and r.organization_id == ^organization_id,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  # INV-1: the run row is locked first, then the requesting user's editor
  # membership. A missing run is `nil` before any membership is read.
  defp lock_run_as_editor(organization_id, run_id, actor) do
    case lock_run(organization_id, run_id) do
      nil ->
        nil

      run ->
        lock_actor!(organization_id, actor)
        run
    end
  end

  # A publication can select the organization's first active schedule, so it takes the
  # organization row between the run and the membership (see `Versions.lock_organization!/1`).
  defp lock_run_for_publication(organization_id, run_id, actor) do
    case lock_run(organization_id, run_id) do
      nil ->
        nil

      run ->
        Versions.lock_organization!(organization_id)
        lock_actor!(organization_id, actor)
        run
    end
  end

  # The transaction has committed: tell watchers when this publication selected the version.
  defp announce_publication({:ok, _run, %GtfsVersion{id: version_id}} = result, organization_id) do
    Versions.announce_activation(organization_id, version_id)
    result
  end

  defp announce_publication(result, _organization_id), do: result

  # Rolls the transaction back with `:forbidden` unless `actor` holds an active
  # editor membership in the organization. A nil `id` (a legacy run without an
  # actor) is refused the same way.
  defp lock_actor!(organization_id, %{id: actor_id}),
    do: Authorization.lock_editor!(%{actor_id: actor_id, organization_id: organization_id})

  # Verifies the locked run is in an expected state AND holds the supplied,
  # unexpired lease token. Returns `:ok` when all hold, `:lease_lost` when the
  # state is right but the token is stale/wrong/expired (a stale owner can never
  # write), `:invalid_transition` when the run is in an ineligible state, and
  # `:not_found` when no run was locked. Expiry uses PostgreSQL time while the
  # caller still holds the row lock.
  defp guard_lease(nil, _expected, _token), do: :not_found

  defp guard_lease(%Run{id: id, state: state, lease_token: run_token}, expected, token) do
    cond do
      state not in expected ->
        :invalid_transition

      run_token != token ->
        :lease_lost

      lease_current?(id) ->
        :ok

      true ->
        :lease_lost
    end
  end

  defp lease_current?(run_id) do
    from(r in Run,
      where:
        r.id == ^run_id and not is_nil(r.lease_expires_at) and
          r.lease_expires_at >= fragment("CURRENT_TIMESTAMP")
    )
    |> Repo.exists?()
  end

  defp publication_reason_code(reason) when is_atom(reason) do
    code = Atom.to_string(reason)
    if code in Failure.reason_codes(), do: code, else: "unknown_error"
  end
end

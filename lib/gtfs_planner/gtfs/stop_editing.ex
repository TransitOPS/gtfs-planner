defmodule GtfsPlanner.Gtfs.StopEditing do
  @moduledoc """
  The commands the stop editor runs, each one an audited transaction (INV-2).

  Every write to a stop in this app goes through a function in this module, not
  through a changeset in a LiveView. That is what makes INV-2 checkable rather
  than aspirational: the audit entry and the mutation are written by the same
  closure, so there is no interleaving in which a stop changed and nobody wrote
  down who changed it.

  The shape follows `GtfsPlanner.Gtfs.Routes`, which is the established command
  module in this codebase and the one the stop editor's history view already
  reads. The four helpers below — authorize, lock, run, audit — are that module's
  helpers rather than a fresh set of ideas, deliberately: "why does a denied
  actor get `:forbidden` here and something else there" should not be a question
  this repo has to answer twice.

  ## Scoping

  `organization_id` and `gtfs_version_id` always come from the `%AuditContext{}`,
  never from the submitted attributes. A form that carried its own scope would be
  a form that could write into another organization's feed by changing a hidden
  field, so the attributes are cast through `Stop.editor_changeset/2` into a
  `%Stop{}` that already has the scope set on the struct.

  ## Stop IDs

  A stop ID is permanent. The feed, the rider information and every operator's
  downstream tooling are keyed on it, so `create_stop/2` never fills a gap and
  never renames an existing stop. When the editor types an ID, that ID is the ID
  and a duplicate is an error the editor sees. When the editor types none, the ID
  is the highest integer ID in the version plus one, skipping any number a garage
  of this organization already occupies: `StopNaming.next_stop_id/3` owns that
  rule and this module only feeds it.
  """

  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ReviewedApplyTransaction
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.StopNaming
  alias GtfsPlanner.Operations
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @editor_role "pathways_studio_editor"

  # How many times the create closure is rerun for a transient serialization
  # failure, a deadlock, or a generated ID taken by a concurrent insert. Three is
  # the route command's convention; a stop create is no more contentious than a
  # route create, so it gets the same budget rather than a number invented here.
  @attempts 3

  @doc """
  Creates a stop in a version, audited in the same transaction (AC-12).

  `attrs` is the editor's draft. A blank or absent `stop_id` is filled by the
  version's ID rule; anything the editor typed is kept as typed.

  Answers `{:ok, stop}`, or one of

    * `{:error, :forbidden}` — the actor is not an active editor of this
      organization. Nothing is written.
    * `{:error, :not_found}` — the version is another organization's, or is not
      published. Nothing is written.
    * `{:error, :failed_audit}` — the stop was created but its audit entry could
      not be written, so the whole transaction rolled back. This is INV-2's
      teeth: an unrecorded change is not a change.
    * `{:error, :busy}` — three attempts, each lost to a concurrent writer.
    * `{:error, %Ecto.Changeset{}}` — the draft is invalid, or its typed `stop_id`
      already exists in this version.

  A generated ID that loses a race to a concurrent insert is not an error: the
  closure is rerun so allocation sees the committed row and picks the next
  number. A *typed* ID that already exists is never re-allocated — the editor
  asked for that ID and renaming it silently would be worse than the error.
  """
  @spec create_stop(map(), AuditContext.t()) ::
          {:ok, Stop.t()}
          | {:error,
             :forbidden
             | :not_found
             | :busy
             | :failed_audit
             | Ecto.Changeset.t()}
  def create_stop(attrs, %AuditContext{} = audit) when is_map(attrs) do
    run_command_transaction(fn -> insert_stop(attrs, audit) end)
  end

  def create_stop(_attrs, _audit), do: {:error, :invalid_input}

  # The transaction body: authorize and lock before reading or writing anything,
  # so allocation and the scope check both see committed state.
  defp insert_stop(attrs, audit) do
    :ok = authorize_editor!(audit)
    _version = lock_published_version!(audit)

    scoped = scoped_attrs(attrs, audit)

    scoped
    |> with_allocated_stop_id(audit)
    |> insert_with_stop_changeset(audit)
  end

  # Scope comes from the context and cannot be overridden by the form.
  defp scoped_attrs(attrs, audit) do
    attrs
    |> stringify_keys()
    |> Map.merge(%{
      "organization_id" => audit.organization_id,
      "gtfs_version_id" => audit.gtfs_version_id
    })
  end

  # A typed ID is the editor's decision and is used as given. A blank one is
  # allocated under the version lock from committed rows.
  #
  # The origin travels with the attrs because it is what decides the error path
  # later: a *typed* duplicate is the editor's mistake to see, while a
  # *generated* one is a race worth retrying. By the time the insert runs, both
  # look identical — the ID is in the attrs either way.
  defp with_allocated_stop_id(%{"stop_id" => stop_id} = attrs, _audit)
       when is_binary(stop_id) and stop_id != "" do
    {:ok, Map.put(attrs, "stop_id_origin", :typed)}
  end

  defp with_allocated_stop_id(attrs, audit) do
    location_type = location_type_of(attrs)
    name = attrs["stop_name"] || ""

    existing = scoped_stop_ids(audit)
    garages = garage_ids(audit.organization_id)

    candidate =
      StopNaming.next_stop_id(existing, garages, {location_type, name})

    {:ok,
     attrs
     |> Map.put(
       "stop_id",
       Gtfs.unique_stop_id(audit.organization_id, audit.gtfs_version_id, candidate)
     )
     |> Map.put("stop_id_origin", :generated)}
  end

  defp insert_with_stop_changeset({:ok, attrs}, audit) do
    # `stop_id_origin` is this command's own bookkeeping, not a stop field, so
    # it is taken back out before the attrs reach the changeset.
    {origin, attrs} = Map.pop(attrs, "stop_id_origin")

    %Stop{}
    |> Stop.editor_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, stop} ->
        audit!(stop, audit, "created")
        stop

      {:error, %Ecto.Changeset{} = failed} ->
        if origin == :generated and stop_id_taken?(failed) do
          # Someone committed this number between allocation and insert. Rerun
          # the closure so allocation sees their row. A typed ID never gets
          # here: the editor asked for that ID, and renaming it silently to make
          # the error go away would be worse than showing them the error.
          Repo.rollback(:generated_collision)
        else
          Repo.rollback(failed)
        end
    end
  end

  # The unique index is on `(organization_id, gtfs_version_id, stop_id)`, and
  # Ecto attaches a composite unique error to the index's *first* field. So the
  # error arrives on `:organization_id`, not on `:stop_id`, and looking for
  # `:stop_id` in the errors would never fire — the command would report a
  # duplicate as if it were any other validation failure. The constraint name is
  # what actually identifies this case.
  @stop_id_constraint "stops_organization_id_gtfs_version_id_stop_id_index"

  # The one case worth a retry: we chose this ID and the database says it is
  # taken. The origin check lives at the call site, where it is still known.
  defp stop_id_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint_name] == @stop_id_constraint
    end)
  end

  defp location_type_of(attrs) do
    case attrs["location_type"] do
      type when is_integer(type) -> clamp_location_type(type)
      type when is_binary(type) -> clamp_location_type(parse_location_type(type))
      _other -> 0
    end
  end

  defp parse_location_type(value) do
    case Integer.parse(String.trim(value)) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  # `StopNaming.next_stop_id/3`'s fallback takes a GTFS location type, and GTFS
  # defines exactly 0–4. Anything outside that is not a type we can slug.
  defp clamp_location_type(type) when type >= 0 and type <= 4, do: type
  defp clamp_location_type(_type), do: 0

  defp scoped_stop_ids(audit) do
    from(stop in Stop,
      where:
        stop.organization_id == ^audit.organization_id and
          stop.gtfs_version_id == ^audit.gtfs_version_id,
      select: stop.stop_id
    )
    |> Repo.all()
  end

  # A garage is not a stop, but it occupies a number in the same series, so a
  # stop ID equal to a garage ID would break the export's uniqueness rule.
  defp garage_ids(organization_id) do
    organization_id
    |> Operations.list_garages()
    |> Enum.map(& &1.garage_id)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
  end

  # Active organization editors only (AC-12), rechecked inside the transaction so
  # a denied actor writes nothing. Copied from `Routes.authorize_editor!/1` so
  # both command modules answer "is this actor allowed" identically.
  defp authorize_editor!(%AuditContext{} = audit) do
    with true <- uuid?(audit.actor_id),
         true <- uuid?(audit.organization_id),
         %UserOrgMembership{} = membership <-
           Accounts.get_user_org_membership(audit.actor_id, audit.organization_id),
         true <- is_nil(membership.deactivated_at),
         true <- editor_role?(membership.roles) do
      :ok
    else
      _other -> Repo.rollback(:forbidden)
    end
  end

  defp editor_role?(roles) when is_list(roles), do: @editor_role in roles
  defp editor_role?(_roles), do: false

  # Published scope only. The create command locks the version row FOR UPDATE
  # before any read so ID allocation sees committed state.
  defp lock_published_version!(audit) do
    if uuid?(audit.organization_id) and uuid?(audit.gtfs_version_id) do
      query =
        from(version in GtfsVersion,
          where:
            version.id == ^audit.gtfs_version_id and
              version.organization_id == ^audit.organization_id and
              version.publication_status == "published",
          lock: "FOR UPDATE"
        )

      case Repo.one(query) do
        %GtfsVersion{} = version -> version
        nil -> Repo.rollback(:not_found)
      end
    else
      Repo.rollback(:not_found)
    end
  end

  # Mutation and audit commit together (INV-2). An unrecordable audit rolls the
  # whole closure back, so there is no committed stop without its history entry.
  # The entity type is an atom: `Gtfs.record_change_in_transaction/5` calls
  # `Atom.to_string/1` on it, matching how `Routes` audits a route.
  defp audit!(stop, audit, action) do
    case Gtfs.record_change_in_transaction(audit, :stop, stop, action, %{before: nil}) do
      {:ok, log} -> log
      {:error, _changeset} -> Repo.rollback(:failed_audit)
    end
  end

  # The route command's bounded-retry convention: rerun the whole serializable
  # closure on a transient serialization failure (40001), a deadlock (40P01) or
  # an explicitly identified generated-ID collision, at most three attempts.
  # Exhausted retries are `:busy`; every other failure returns unchanged.
  defp run_command_transaction(transaction, attempts \\ @attempts) do
    case run_apply_transaction(transaction) do
      {:ok, result} ->
        {:ok, result}

      {:retryable_conflict, _error} ->
        retry_command_transaction(transaction, attempts)

      {:error, :generated_collision} ->
        retry_command_transaction(transaction, attempts)

      {:error, reason} ->
        if retryable_conflict?(reason),
          do: retry_command_transaction(transaction, attempts),
          else: {:error, reason}
    end
  end

  defp retry_command_transaction(transaction, attempts) when attempts > 1,
    do: run_command_transaction(transaction, attempts - 1)

  defp retry_command_transaction(_transaction, _attempts), do: {:error, :busy}

  defp run_apply_transaction(transaction) do
    Application.get_env(
      :gtfs_planner,
      :reviewed_apply_transaction,
      ReviewedApplyTransaction.Repo
    ).run(transaction)
  rescue
    error in Postgrex.Error ->
      if retryable_conflict?(error),
        do: {:retryable_conflict, error},
        else: reraise(error, __STACKTRACE__)
  end

  defp retryable_conflict?(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :serialization_failure,
              "40001",
              :deadlock_detected,
              "40P01"
            ],
       do: true

  defp retryable_conflict?(_reason), do: false

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false

  defp stringify_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end

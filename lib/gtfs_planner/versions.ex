defmodule GtfsPlanner.Versions do
  @moduledoc """
  The Versions context for managing GTFS versions scoped to organizations.

  This context owns the publication lifecycle: staging, importing, published, and
  failed states, and every transition is organization-scoped and conditional so a
  concurrent publish/fail race has exactly one winner.

  It also owns each organization's active schedule: the one usable version that
  authoring reads and target-dependent writes use. The selection is a pointer plus a
  revision on the organization row. The first usable version of an organization
  becomes active when it is created or published, and an editor can select any other
  usable version with `set_active_schedule/3`. Staging, failed and later versions
  never displace it.

  Lock order for selection writers: the organization row first, then the actor's
  membership, then the version. `Authorization` documents that a membership command
  holds the organization row while it waits for the member's row; a writer that took
  its membership lock first and the organization row second would deadlock with it.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Organizations.Organization
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Values
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"
  @staging_status "staging"
  @importing_status "importing"
  @failed_status "failed"

  @telemetry_event [:gtfs_planner, :import_publication, :transition]

  @typedoc """
  What an editor saw when it read the selection. `revision` counts pointer changes and
  never decreases, so a token read before an A -> B -> A switch is stale. `version_id`
  is nil while the organization has no active schedule.
  """
  @type selection_token :: %{version_id: Ecto.UUID.t() | nil, revision: non_neg_integer()}

  @type active_schedule :: %{version: GtfsVersion.t() | nil, token: selection_token()}

  # --- creation -------------------------------------------------------------

  @doc """
  Creates an immediately-published GTFS version for an organization.

  Both lifecycle fields are set explicitly: `publication_status = "published"`
  and `published_at` uses database time.
  """
  @spec create_gtfs_version(Ecto.UUID.t(), map()) ::
          {:ok, GtfsVersion.t()} | {:error, Ecto.Changeset.t()}
  def create_gtfs_version(organization_id, attrs) do
    outer? = Repo.in_transaction?()

    result =
      Repo.transaction(fn ->
        lock_organization(organization_id, "FOR NO KEY UPDATE")

        case Repo.insert(
               GtfsVersion.published_create_changeset(
                 %GtfsVersion{organization_id: organization_id},
                 attrs
               )
             ) do
          {:ok, version} ->
            from(v in GtfsVersion,
              where: v.id == ^version.id,
              update: [set: [published_at: fragment("CURRENT_TIMESTAMP")]]
            )
            |> Repo.update_all([])

            version = Repo.get!(GtfsVersion, version.id)
            select_when_none(version)
            version

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    result = emit_transition(result, organization_id, nil, @published_status)

    # A caller that opened the outer transaction announces after its own commit.
    if not outer?, do: announce_published(result, organization_id)
    result
  end

  @doc """
  Creates a `"staging"` GTFS version for an organization.

  The version is unavailable externally (`published_at` is nil) until it is
  claimed and published.
  """
  @spec create_staging_gtfs_version(Ecto.UUID.t(), map()) ::
          {:ok, GtfsVersion.t()} | {:error, Ecto.Changeset.t()}
  def create_staging_gtfs_version(organization_id, attrs) do
    %GtfsVersion{organization_id: organization_id}
    |> GtfsVersion.staging_create_changeset(attrs)
    |> Repo.insert()
    |> emit_transition(organization_id, nil, @staging_status)
  end

  @doc """
  Creates a default "First Version" GTFS version for an organization.
  """
  def create_default_version(organization_id) do
    create_gtfs_version(organization_id, %{name: "First Version"})
  end

  # --- lifecycle transitions ------------------------------------------------

  @doc """
  Conditionally claims a `"staging"` version as `"importing"`.

  This is the durable single-run claim: only the `staging -> importing`
  transition is permitted, and a losing concurrent caller performs no writes.

  Returns `{:ok, version}` on success, `{:error, :invalid_status_transition}`
  when the version is not in the `staging` state, or `{:error, :not_found}`
  when no such version exists for the organization.
  """
  @spec claim_staging_gtfs_version(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, GtfsVersion.t()} | {:error, :invalid_status_transition | :not_found}
  def claim_staging_gtfs_version(organization_id, version_id) do
    conditional_transition(
      organization_id,
      version_id,
      @staging_status,
      @importing_status,
      nil
    )
  end

  @doc """
  Conditionally publishes an `"importing"` version as `"published"`.

  `published_at` is set using PostgreSQL database time. Returns `{:ok, version}`
  on success, `{:error, :invalid_status_transition}` when the version is not
  `importing`, or `{:error, :not_found}`.
  """
  @spec publish_importing_gtfs_version(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, GtfsVersion.t()} | {:error, :invalid_status_transition | :not_found}
  def publish_importing_gtfs_version(organization_id, version_id) do
    outer? = Repo.in_transaction?()

    {:ok, result} =
      Repo.transaction(fn ->
        lock_organization(organization_id, "FOR NO KEY UPDATE")

        with {:ok, version} = published <-
               conditional_transition(
                 organization_id,
                 version_id,
                 @importing_status,
                 @published_status,
                 :database_now
               ) do
          select_when_none(version)
          published
        end
      end)

    # `ImportRuns` opens the outer transaction and announces after its own commit.
    if not outer?, do: announce_published(result, organization_id)
    result
  end

  @doc """
  Conditionally marks an unavailable version (`"staging"` or `"importing"`) as
  `"failed"`. `failed` is terminal: there is no `failed -> ...` transition.

  Returns `{:ok, version}`, `{:error, :invalid_status_transition}`, or
  `{:error, :not_found}`.
  """
  @spec fail_unpublished_gtfs_version(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, GtfsVersion.t()} | {:error, :invalid_status_transition | :not_found}
  def fail_unpublished_gtfs_version(organization_id, version_id) do
    result =
      Repo.transaction(fn ->
        version =
          from(v in GtfsVersion,
            where: v.id == ^version_id and v.organization_id == ^organization_id,
            lock: "FOR UPDATE"
          )
          |> Repo.one()

        case version do
          nil ->
            {:error, :not_found, nil}

          %GtfsVersion{publication_status: prior}
          when prior in [@staging_status, @importing_status] ->
            from(v in GtfsVersion, where: v.id == ^version_id)
            |> Repo.update_all(set: [publication_status: @failed_status, published_at: nil])

            {:ok, Repo.get!(GtfsVersion, version_id), prior}

          %GtfsVersion{publication_status: prior} ->
            {:error, :invalid_status_transition, prior}
        end
      end)

    case result do
      {:ok, {:ok, version, prior}} ->
        emit_transition(:ok, organization_id, version, prior, @failed_status)
        {:ok, version}

      {:ok, {:error, reason, current_state}} ->
        emit_transition_error(organization_id, version_id, current_state, reason)
        {:error, reason}
    end
  end

  # --- lookups --------------------------------------------------------------

  @doc """
  Returns the list of GTFS versions for an organization (published only).
  """
  def list_gtfs_versions(organization_id) do
    list_published_gtfs_versions(organization_id)
  end

  @doc """
  Returns the list of published GTFS versions for an organization ordered by
  `published_at DESC, inserted_at DESC, id DESC`.
  """
  @spec list_published_gtfs_versions(Ecto.UUID.t()) :: [GtfsVersion.t()]
  def list_published_gtfs_versions(organization_id) do
    from(v in GtfsVersion,
      where: v.organization_id == ^organization_id,
      where: v.publication_status == ^@published_status,
      order_by: [desc: v.published_at, desc: v.inserted_at, desc: v.id]
    )
    |> Repo.all()
  end

  @doc """
  Returns a list of published `{id, name}` tuples for dropdown/select components,
  ordered by most recent first.
  """
  def list_gtfs_versions_for_dropdown(organization_id) do
    from(v in GtfsVersion,
      where: v.organization_id == ^organization_id,
      where: v.publication_status == ^@published_status,
      order_by: [desc: v.published_at, desc: v.inserted_at, desc: v.id],
      select: {v.id, v.name}
    )
    |> Repo.all()
  end

  @doc """
  Gets the latest published GTFS version for an organization, ordered by
  `published_at DESC, inserted_at DESC, id DESC`.

  Returns `{:ok, %GtfsVersion{}}` or `{:error, :no_versions}`.
  """
  def get_latest_gtfs_version(organization_id) do
    result =
      from(v in GtfsVersion,
        where: v.organization_id == ^organization_id,
        where: v.publication_status == ^@published_status,
        order_by: [desc: v.published_at, desc: v.inserted_at, desc: v.id],
        limit: 1
      )
      |> Repo.one()

    case result do
      nil -> {:error, :no_versions}
      version -> {:ok, version}
    end
  end

  @doc """
  Gets a published GTFS version by organization and id, or nil if it is not
  published or does not belong to the organization.
  """
  @spec get_published_gtfs_version_for_org(Ecto.UUID.t(), Ecto.UUID.t()) ::
          GtfsVersion.t() | nil
  def get_published_gtfs_version_for_org(organization_id, version_id) do
    # Fail closed on a malformed (non-UUID) identity: a crafted route, event, or
    # request must be treated exactly like a missing version, never a 500.
    case Ecto.UUID.cast(version_id) do
      {:ok, id} ->
        from(v in GtfsVersion,
          where:
            v.id == ^id and
              v.organization_id == ^organization_id and
              v.publication_status == ^@published_status
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  Gets a published GTFS version by organization and id, raising if absent.
  """
  @spec get_published_gtfs_version_for_org!(Ecto.UUID.t(), Ecto.UUID.t()) :: GtfsVersion.t()
  def get_published_gtfs_version_for_org!(organization_id, version_id) do
    from(v in GtfsVersion,
      where:
        v.id == ^version_id and
          v.organization_id == ^organization_id and
          v.publication_status == ^@published_status
    )
    |> Repo.one!()
  end

  @doc """
  Returns a GTFS version by organization and id for internal lifecycle use,
  regardless of publication status, or nil.
  """
  @spec get_gtfs_version_for_lifecycle(Ecto.UUID.t(), Ecto.UUID.t()) ::
          GtfsVersion.t() | nil
  def get_gtfs_version_for_lifecycle(organization_id, version_id) do
    from(v in GtfsVersion,
      where: v.id == ^version_id and v.organization_id == ^organization_id
    )
    |> Repo.one()
  end

  @doc """
  Returns whether a version is published and belongs to the organization.
  """
  @spec published_gtfs_version_for_org?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def published_gtfs_version_for_org?(organization_id, version_id) do
    not is_nil(get_published_gtfs_version_for_org(organization_id, version_id))
  end

  @doc """
  Renames one version of the actor's organization.

  `scope` is `%{actor_id: _, organization_id: _}` taken from the server session, never
  from client input. One transaction takes the actor's current editor membership, then
  locks the version row scoped to that organization and writes only the name, so an editor
  revoked after the page mounted cannot rename, and a version id from another organization
  is never touched.

  Returns `{:ok, version}`, `{:error, changeset}` for a refused name, `{:error, :forbidden}`
  for a missing, deactivated or non-editor membership, or `{:error, :not_found}` when the
  version is not in the actor's organization.
  """
  @spec update_gtfs_version(map(), Ecto.UUID.t(), map()) ::
          {:ok, GtfsVersion.t()} | {:error, Ecto.Changeset.t() | :forbidden | :not_found}
  def update_gtfs_version(scope, version_id, attrs) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(scope)

      scope.organization_id
      |> lock_for_exclusive_write!(version_id)
      |> GtfsVersion.name_changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, version} -> version
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc false
  def change_gtfs_version(%GtfsVersion{} = version, attrs \\ %{}) do
    GtfsVersion.changeset(version, attrs)
  end

  # --- active schedule ------------------------------------------------------

  @doc """
  The PubSub topic that carries `{:active_schedule_changed, token}` for one organization.

  A message is sent only after the transaction that moved the selection has committed.
  It is a refresh hint: a receiver rereads `active_schedule/1` and ignores a token that
  is not newer than the one it holds.
  """
  @spec active_schedule_topic(Ecto.UUID.t()) :: String.t()
  def active_schedule_topic(organization_id), do: "active_schedule:" <> organization_id

  @doc """
  Reads the organization's active schedule and the token that identifies this state.

  `scope` is `%{actor_id: _, organization_id: _}` from the server session. The read
  requires a current editor membership, like every Alerts read, and returns the
  pointer, its version and the revision from one statement. `version` is nil while the
  organization has no active schedule; the token then carries `version_id: nil`.
  """
  @spec active_schedule(map()) :: {:ok, active_schedule()} | {:error, :forbidden}
  def active_schedule(scope) do
    with :ok <- Authorization.authorize_editor(scope),
         %{} = active <- read_active_schedule(scope.organization_id) do
      {:ok, active}
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc """
  Selects `version_id` as the organization's active schedule.

  One transaction locks the organization row, takes the actor's current editor
  membership, compares `expected_token` with the stored state and then selects a
  published version of the same organization. The token is an expectation, never
  authority: the organization and actor come from `scope`.

  Selecting the version that is already active changes nothing and keeps the revision.
  Any other selection increments the revision once and, after commit, broadcasts
  `{:active_schedule_changed, token}` on `active_schedule_topic/1`.

  Returns `{:ok, active}`, or `{:error, reason}` with nothing written:

    * `:forbidden` - the membership is missing, revoked or not an editor's;
    * `:stale_active` - the selection moved since the token was read, including an
      A -> B -> A return to the same version;
    * `:not_found` - the version is not in the actor's organization;
    * `:not_usable` - the version is staging, importing or failed.
  """
  @spec set_active_schedule(map(), term(), term()) ::
          {:ok, active_schedule()}
          | {:error, :forbidden | :stale_active | :not_found | :not_usable}
  def set_active_schedule(scope, version_id, expected_token) do
    result =
      Repo.transaction(fn ->
        organization = lock_selection!(scope, "FOR NO KEY UPDATE")

        if not current_token?(organization, expected_token), do: Repo.rollback(:stale_active)

        version = usable_version!(organization.id, version_id)

        if organization.active_gtfs_version_id == version.id do
          {:unchanged, %{version: version, token: token(organization)}}
        else
          {1, [revision]} =
            from(o in Organization,
              where: o.id == ^organization.id,
              select: o.active_gtfs_version_revision
            )
            |> Repo.update_all(
              set: [active_gtfs_version_id: version.id],
              inc: [active_gtfs_version_revision: 1]
            )

          {:changed, %{version: version, token: %{version_id: version.id, revision: revision}}}
        end
      end)

    case result do
      {:ok, {:unchanged, active}} ->
        {:ok, active}

      {:ok, {:changed, active}} ->
        broadcast_active_change(active.token, scope.organization_id)
        {:ok, active}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Locks the organization's active schedule for the caller's write transaction.

  Call inside `Repo.transaction/1`, before any lock on an alert or other entity of the
  version. The organization row is locked `FOR SHARE`, then the actor's current editor
  membership, then the active version `FOR UPDATE`, so a selection change
  (`FOR NO KEY UPDATE` on the organization) and a mutation of the version's targets
  each wait for this transaction and are seen by it afterwards. Take this lock in place
  of a separate `Authorization.lock_editor!/1`; locking the membership first would
  deadlock with a membership command, which holds the organization row while it waits
  for the member's row.

  Returns the locked `%{version: version, token: token}`. Otherwise the surrounding
  transaction rolls back with `:forbidden` (membership), `:stale_active` (the selection
  moved since `expected_token` was read) or `:no_active_schedule`.
  """
  @spec lock_active_schedule!(map(), term()) :: active_schedule()
  def lock_active_schedule!(scope, expected_token) do
    if not Repo.in_transaction?() do
      raise ArgumentError, "lock_active_schedule!/2 must run inside Repo.transaction/1"
    end

    organization = lock_selection!(scope, "FOR SHARE")

    cond do
      not current_token?(organization, expected_token) ->
        Repo.rollback(:stale_active)

      is_nil(organization.active_gtfs_version_id) ->
        Repo.rollback(:no_active_schedule)

      true ->
        version =
          from(v in GtfsVersion,
            where:
              v.id == ^organization.active_gtfs_version_id and
                v.organization_id == ^organization.id,
            lock: "FOR UPDATE"
          )
          |> Repo.one!()

        %{version: version, token: token(organization)}
    end
  end

  @doc """
  Locks one organization row `FOR NO KEY UPDATE` for the caller's transaction.

  Lifecycle writers that may select the first usable version take this lock before any
  version row, and after their run lock but before the actor's membership lock (see the
  module note). It does not conflict with the `FOR KEY SHARE` lock a foreign-key insert
  takes, so unrelated version input writers keep running. An absent organization rolls
  the transaction back with `:not_found`.
  """
  @spec lock_organization!(Ecto.UUID.t()) :: Organization.t()
  def lock_organization!(organization_id) do
    case lock_organization(organization_id, "FOR NO KEY UPDATE") do
      %Organization{} = organization -> organization
      nil -> Repo.rollback(:not_found)
    end
  end

  @doc """
  Broadcasts the organization's token when `version_id` is its active schedule.

  A lifecycle caller that owns the outer transaction calls this once after that
  transaction commits, with the version it created or published. It sends nothing
  when the version is not active.
  """
  @spec announce_activation(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def announce_activation(organization_id, version_id) do
    case read_active_schedule(organization_id) do
      %{token: %{version_id: ^version_id} = token} ->
        broadcast_active_change(token, organization_id)

      _other ->
        :ok
    end
  end

  # --- writer coordination --------------------------------------------------

  @doc """
  Locks one organization-scoped version row `FOR SHARE` for a direct input writer.

  Cooperating writers take this lock inside their own transaction before any route,
  pattern, block, trip or stop lock, so a calendar mutation or a calendar combination that
  owns the same version row `FOR UPDATE` cannot commit a fresh input between a review and
  its apply. Two writers of the same version therefore wait for each other only for as long
  as one of them is replacing version-wide input.

  This is a scoped row lock for the caller's transaction, not an authorization check, and it
  does not change publication rules: a `"staging"` or `"importing"` scope is locked exactly
  like a published one, so import helpers that own an unpublished version keep writing.
  Callers that must refuse an unpublished scope keep their own published check.

  Returns the locked `%GtfsVersion{}`, or rolls the surrounding transaction back with
  `:not_found` when the version does not exist inside that organization. Call only inside
  `Repo.transaction/1`.
  """
  @spec lock_for_input_write!(Ecto.UUID.t(), Ecto.UUID.t()) :: GtfsVersion.t()
  def lock_for_input_write!(organization_id, version_id) do
    organization_id
    |> scoped_version_for_share(version_id)
    |> case do
      %GtfsVersion{} = version -> version
      nil -> Repo.rollback(:not_found)
    end
  end

  @doc """
  Locks one organization-scoped version `FOR UPDATE` for a natural-ID mutation.

  Call inside a transaction, at entry before reading entity rows. The caller
  chooses this lock instead of a share lock; it must never upgrade a held lock.
  An absent or foreign version rolls the transaction back with `:not_found`.
  """
  @spec lock_for_exclusive_write!(Ecto.UUID.t(), Ecto.UUID.t()) :: GtfsVersion.t()
  def lock_for_exclusive_write!(organization_id, version_id) do
    version =
      if Values.uuid?(organization_id) and Values.uuid?(version_id) do
        from(v in GtfsVersion,
          where: v.id == ^version_id and v.organization_id == ^organization_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()
      end

    case version do
      %GtfsVersion{} = scoped_version -> scoped_version
      nil -> Repo.rollback(:not_found)
    end
  end

  # --- private --------------------------------------------------------------

  # A literal lock string is required by Ecto. This is the same scoped share lock the
  # calendar reads and schedule writers already take, so input writers exclude each other
  # and any exclusive version owner instead of racing it.
  defp scoped_version_for_share(organization_id, version_id) do
    if Values.uuid?(organization_id) and Values.uuid?(version_id) do
      from(v in GtfsVersion,
        where: v.id == ^version_id and v.organization_id == ^organization_id,
        lock: "FOR SHARE"
      )
      |> Repo.one()
    end
  end

  # Selects the first usable version of an organization. The row is already locked
  # `FOR NO KEY UPDATE` by this transaction, and the condition is evaluated against the
  # current row, so concurrent first versions leave exactly one pointer and one
  # revision increment.
  defp select_when_none(%GtfsVersion{id: version_id, organization_id: organization_id}) do
    from(o in Organization, where: o.id == ^organization_id and is_nil(o.active_gtfs_version_id))
    |> Repo.update_all(
      set: [active_gtfs_version_id: version_id],
      inc: [active_gtfs_version_revision: 1]
    )
  end

  defp announce_published({:ok, %GtfsVersion{id: version_id}}, organization_id),
    do: announce_activation(organization_id, version_id)

  defp announce_published(_error, _organization_id), do: :ok

  defp broadcast_active_change(token, organization_id) do
    Phoenix.PubSub.broadcast(
      GtfsPlanner.PubSub,
      active_schedule_topic(organization_id),
      {:active_schedule_changed, token}
    )
  end

  # The pointer, its version and the revision come from one statement, so they agree.
  defp read_active_schedule(organization_id) do
    if Values.uuid?(organization_id) do
      from(o in Organization,
        left_join: v in GtfsVersion,
        on: v.id == o.active_gtfs_version_id and v.organization_id == o.id,
        where: o.id == ^organization_id,
        select: %{
          version: v,
          token: %{version_id: o.active_gtfs_version_id, revision: o.active_gtfs_version_revision}
        }
      )
      |> Repo.one()
    end
  end

  defp token(%Organization{} = organization) do
    %{
      version_id: organization.active_gtfs_version_id,
      revision: organization.active_gtfs_version_revision
    }
  end

  defp current_token?(organization, %{version_id: version_id, revision: revision}),
    do: token(organization) == %{version_id: version_id, revision: revision}

  defp current_token?(_organization, _forged), do: false

  # Organization row first, then the actor's membership. A bad scope fails the
  # membership lock, so a missing or foreign organization is `:forbidden` too.
  defp lock_selection!(scope, lock) do
    organization = lock_organization(is_map(scope) && Map.get(scope, :organization_id), lock)
    Authorization.lock_editor!(scope)
    organization || Repo.rollback(:forbidden)
  end

  # A literal lock string is required by Ecto; callers pass one of two constants.
  defp lock_organization(organization_id, lock) do
    if Values.uuid?(organization_id) do
      case lock do
        "FOR NO KEY UPDATE" ->
          Repo.one(
            from o in Organization, where: o.id == ^organization_id, lock: "FOR NO KEY UPDATE"
          )

        "FOR SHARE" ->
          Repo.one(from o in Organization, where: o.id == ^organization_id, lock: "FOR SHARE")
      end
    end
  end

  # `FOR KEY SHARE` is the lock the pointer's own foreign key takes. It holds off a
  # delete of the version without conflicting with a publish transition.
  defp usable_version!(organization_id, version_id) do
    version =
      if Values.uuid?(version_id) do
        from(v in GtfsVersion,
          where: v.id == ^version_id and v.organization_id == ^organization_id,
          lock: "FOR KEY SHARE"
        )
        |> Repo.one()
      end

    case version do
      nil -> Repo.rollback(:not_found)
      %GtfsVersion{publication_status: @published_status} = usable -> usable
      %GtfsVersion{} -> Repo.rollback(:not_usable)
    end
  end

  defp lifecycle_state(organization_id, version_id) do
    from(v in GtfsVersion,
      where: v.id == ^version_id and v.organization_id == ^organization_id,
      select: v.publication_status
    )
    |> Repo.one()
  end

  defp conditional_transition(organization_id, version_id, expected, target, published_at) do
    query =
      case published_at do
        :database_now ->
          from(v in GtfsVersion,
            where:
              v.id == ^version_id and
                v.organization_id == ^organization_id and
                v.publication_status == ^expected,
            update: [
              set: [publication_status: ^target, published_at: fragment("CURRENT_TIMESTAMP")]
            ]
          )

        nil ->
          from(v in GtfsVersion,
            where:
              v.id == ^version_id and
                v.organization_id == ^organization_id and
                v.publication_status == ^expected,
            update: [set: [publication_status: ^target, published_at: nil]]
          )
      end

    updated = Repo.update_all(query, [])

    case updated do
      {0, nil} ->
        current_state = lifecycle_state(organization_id, version_id)
        reason = if is_nil(current_state), do: :not_found, else: :invalid_status_transition
        emit_transition_error(organization_id, version_id, current_state, reason)
        {:error, reason}

      {_n, nil} ->
        version = Repo.get!(GtfsVersion, version_id)
        emit_transition(:ok, organization_id, version, expected, target)
        {:ok, version}
    end
  end

  defp emit_transition({:ok, version}, organization_id, prior, new_state) do
    emit_transition(:ok, organization_id, version, prior, new_state)
    {:ok, version}
  end

  defp emit_transition({:error, changeset}, _organization_id, _prior, _new_state) do
    {:error, changeset}
  end

  defp emit_transition(:ok, organization_id, version, prior_state, new_state) do
    emit_transition_metadata(
      organization_id,
      version.id,
      prior_state,
      new_state,
      nil
    )
  end

  defp emit_transition_error(organization_id, version_id, current_state, failure_class) do
    state = current_state || "unknown"
    emit_transition_metadata(organization_id, version_id, state, state, failure_class)
  end

  defp emit_transition_metadata(
         organization_id,
         version_id,
         prior_state,
         new_state,
         failure_class
       ) do
    metadata = %{
      organization_id: organization_id,
      version_id: version_id,
      prior_state: prior_state,
      new_state: new_state,
      failure_class: failure_class
    }

    Logger.metadata(
      version_id: version_id,
      organization_id: organization_id,
      transition: new_state,
      failure_class: failure_class
    )

    :telemetry.execute(@telemetry_event, %{}, metadata)
  end
end

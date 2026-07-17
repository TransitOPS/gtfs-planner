defmodule GtfsPlanner.Versions do
  @moduledoc """
  The Versions context for managing GTFS versions scoped to organizations.

  This context owns the publication lifecycle: staging, importing, published, and
  failed states, and every transition is organization-scoped and conditional so a
  concurrent publish/fail race has exactly one winner.
  """

  import Ecto.Query, warn: false
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"
  @staging_status "staging"
  @importing_status "importing"
  @failed_status "failed"

  @telemetry_event [:gtfs_planner, :import_publication, :transition]

  # --- creation -------------------------------------------------------------

  @doc """
  Creates an immediately-published GTFS version for an organization.

  Both lifecycle fields are set explicitly: `publication_status = "published"`
  and `published_at` uses database time.
  """
  @spec create_gtfs_version(Ecto.UUID.t(), map()) ::
          {:ok, GtfsVersion.t()} | {:error, Ecto.Changeset.t()}
  def create_gtfs_version(organization_id, attrs) do
    result =
      Repo.transaction(fn ->
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

            Repo.get!(GtfsVersion, version.id)

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)

    result
    |> emit_transition(organization_id, nil, @published_status)
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
    conditional_transition(
      organization_id,
      version_id,
      @importing_status,
      @published_status,
      :database_now
    )
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

  @doc false
  def update_gtfs_version(%GtfsVersion{} = version, attrs) do
    version
    |> GtfsVersion.changeset(attrs)
    |> Repo.update()
  end

  @doc false
  def change_gtfs_version(%GtfsVersion{} = version, attrs \\ %{}) do
    GtfsVersion.changeset(version, attrs)
  end

  # --- private --------------------------------------------------------------

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

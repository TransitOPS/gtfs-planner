defmodule GtfsPlanner.Gtfs.Fares.VersionLock do
  @moduledoc """
  The one write transaction of a managed version's fare rows (R15).

  Every write of `GtfsPlanner.Gtfs.Fares` and of `GtfsPlanner.Gtfs.FareZones`
  runs inside `transact/3`, so all writers of one version's fares serialize on
  the same row instead of each holding a lock of their own.

  Every transaction locks the actor's active editor membership before locking
  the organization's published version row. The audit context is the source of
  both identities, so callers cannot authorize one organization and write to a
  different organization or version through duplicated scope fields.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Authorization
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  @published_status "published"

  @doc """
  Runs `fun` in one transaction holding the actor's membership and the
  published version row locked, in that order.

  A scope map is accepted for the shared Fares and Conversion writers, but its
  organization and version IDs must match the embedded audit context. A
  mismatched scope returns `{:error, :forbidden}` without running `fun`. The
  version must be published for the audit context's organization; otherwise the
  transaction returns `{:error, :not_found}`.
  """
  @spec transact(AuditContext.t() | map(), (-> term())) :: {:ok, term()} | {:error, term()}
  def transact(%AuditContext{} = audit, fun) when is_function(fun, 0) do
    Repo.transaction(fn ->
      Authorization.lock_editor!(audit)
      lock_version_and_run(audit.organization_id, audit.gtfs_version_id, fun)
    end)
  end

  def transact(
        %{
          organization_id: organization_id,
          gtfs_version_id: gtfs_version_id,
          audit: %AuditContext{} = audit
        },
        fun
      )
      when is_function(fun, 0) do
    if organization_id == audit.organization_id and gtfs_version_id == audit.gtfs_version_id do
      transact(audit, fun)
    else
      {:error, :forbidden}
    end
  end

  def transact(_scope, _fun), do: {:error, :forbidden}

  defp lock_version_and_run(organization_id, gtfs_version_id, fun) do
    version =
      if uuid?(organization_id) and uuid?(gtfs_version_id),
        do: published_version_for_update(organization_id, gtfs_version_id)

    case version do
      %GtfsVersion{} -> fun.()
      nil -> Repo.rollback(:not_found)
    end
  end

  defp published_version_for_update(organization_id, gtfs_version_id) do
    from(v in GtfsVersion,
      where:
        v.id == ^gtfs_version_id and v.organization_id == ^organization_id and
          v.publication_status == ^@published_status,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_value), do: false
end

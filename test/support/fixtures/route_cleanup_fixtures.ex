defmodule GtfsPlanner.RouteCleanupFixtures do
  @moduledoc """
  Cleanup for the route deletion and status suites, which build their fixtures
  in committed transactions and must not leak rows across tests.
  """
  import Ecto.Query

  alias GtfsPlanner.Repo

  # Cascading cleanup in dependency order: every row scoped by organization or
  # version goes first, so fixtures never leak across tests.
  def delete_org_or_version!(schema, org_id, version_id) do
    Repo.delete_all(
      from s in schema,
        where: s.organization_id == ^org_id or s.gtfs_version_id == ^version_id
    )
  end
end

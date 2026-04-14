defmodule GtfsPlannerWeb.Api.V1.VersionController do
  use GtfsPlannerWeb, :controller

  alias GtfsPlanner.Versions

  @doc "GET /api/v1/versions — list GTFS versions for the user's organization."
  def index(conn, _params) do
    org_id = conn.assigns[:current_organization_id]
    versions = Versions.list_gtfs_versions(org_id)

    json(conn, %{
      data:
        Enum.map(versions, fn v ->
          %{
            id: v.id,
            name: v.name,
            created_at: DateTime.to_iso8601(v.inserted_at)
          }
        end)
    })
  end
end

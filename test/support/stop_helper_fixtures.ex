defmodule GtfsPlanner.StopHelperFixtures do
  @moduledoc """
  Scopes for the two stop helper packs, admitted the way the stops pages admit them:
  the whole-version identity plus a source snapshot through the real
  `Scope.with_source_snapshot/2`, so a scope the seam would refuse is never built.
  """

  alias GtfsPlanner.Agents.Scope

  @doc """
  A `%Scope{}` for `pack_id` carrying `kind` and `payload` as its admitted snapshot, or
  with no snapshot when `snapshot` is `:none`.
  """
  def helper_scope(pack_id, organization, version, user, snapshot) do
    base = Scope.context({:version, version.id})

    context =
      case snapshot do
        :none ->
          base

        {kind, payload} ->
          {:ok, admitted} = Scope.with_source_snapshot(base, %{kind: kind, payload: payload})
          admitted
      end

    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: pack_id,
      version_name: version.name,
      resource_context: context
    }
  end

  @doc "The `stop_focus` snapshot the stops map admits for `stop` and an optional pin."
  def stop_focus(stop_uuid, candidate \\ nil),
    do:
      {"stop_focus", %{"schema_version" => 1, "stop_uuid" => stop_uuid, "candidate" => candidate}}
end

defmodule GtfsPlanner.VersionsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GtfsPlanner.Versions` context.
  """

  alias GtfsPlanner.Versions

  @doc """
  Generate a GTFS version fixture.
  """
  def gtfs_version_fixture(organization_id, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        name: "Test Version #{System.unique_integer()}"
      })

    {:ok, version} = Versions.create_gtfs_version(organization_id, attrs)
    version
  end

  @doc """
  Selects `version` as the organization's active schedule, as `actor` (an editor).

  An organization starts with its first usable version active, so a test that
  builds its fixture rows in a later version selects it here before reading
  anything that resolves against the active schedule.
  """
  def activate_version!(organization, version, actor) do
    scope = %{actor_id: actor.id, organization_id: organization.id}
    {:ok, %{token: token}} = Versions.active_schedule(scope)
    {:ok, active} = Versions.set_active_schedule(scope, version.id, token)
    active
  end
end

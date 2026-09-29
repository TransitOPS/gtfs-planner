defmodule GtfsPlanner.HomeSourceStub do
  @moduledoc """
  Test-only homepage source that delegates to `GtfsPlanner.Home`.

  Installed as `:home_source` by the region failure-injection tests. Every
  function behaves like its `GtfsPlanner.Home` counterpart, except that a
  function named in `Application.get_env(:gtfs_planner, :home_failing_functions, [])`
  raises a `RuntimeError` before delegating, so one homepage region can be made
  to fail while the others still load.
  """

  alias GtfsPlanner.Home

  @doc "See `GtfsPlanner.Home.organization_admins/1`."
  def organization_admins(organization_id) do
    fail_if(:organization_admins)
    Home.organization_admins(organization_id)
  end

  @doc "See `GtfsPlanner.Home.member_count/1`."
  def member_count(organization_id) do
    fail_if(:member_count)
    Home.member_count(organization_id)
  end

  @doc "See `GtfsPlanner.Home.organization_count/0`."
  def organization_count do
    fail_if(:organization_count)
    Home.organization_count()
  end

  @doc "See `GtfsPlanner.Home.resume/3`."
  def resume(organization_id, gtfs_version_id, user_id) do
    fail_if(:resume)
    Home.resume(organization_id, gtfs_version_id, user_id)
  end

  @doc "See `GtfsPlanner.Home.station_board/2`."
  def station_board(organization_id, gtfs_version_id) do
    fail_if(:station_board)
    Home.station_board(organization_id, gtfs_version_id)
  end

  @doc "See `GtfsPlanner.Home.station_statuses/3`."
  def station_statuses(organization_id, gtfs_version_id, stations) do
    fail_if(:station_statuses)
    Home.station_statuses(organization_id, gtfs_version_id, stations)
  end

  @doc "See `GtfsPlanner.Home.station_editors/2`."
  def station_editors(organization_id, gtfs_version_id) do
    fail_if(:station_editors)
    Home.station_editors(organization_id, gtfs_version_id)
  end

  @doc "See `GtfsPlanner.Home.planner_status/2`."
  def planner_status(organization_id, gtfs_version_id) do
    fail_if(:planner_status)
    Home.planner_status(organization_id, gtfs_version_id)
  end

  @doc "See `GtfsPlanner.Home.pathways_attention/2`."
  def pathways_attention(organization_id, gtfs_version_id) do
    fail_if(:pathways_attention)
    Home.pathways_attention(organization_id, gtfs_version_id)
  end

  defp fail_if(function_name) do
    if function_name in Application.get_env(:gtfs_planner, :home_failing_functions, []) do
      raise "GtfsPlanner.HomeSourceStub is configured to fail #{function_name}"
    end
  end
end

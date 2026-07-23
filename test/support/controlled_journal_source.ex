defmodule GtfsPlannerWeb.Gtfs.ControlledJournalSource do
  @moduledoc false

  alias GtfsPlanner.Gtfs

  def subscribe_station_journal(scope) do
    owner = Application.fetch_env!(:gtfs_planner, :station_journal_source_owner)
    send(owner, {:journal_subscription_requested, scope})

    case Application.get_env(:gtfs_planner, :station_journal_subscription_result, :real) do
      :real -> Gtfs.subscribe_station_journal(scope)
      result -> result
    end
  end

  def list_station_journal(scope, opts) do
    Process.flag(:trap_exit, true)
    owner = Application.fetch_env!(:gtfs_planner, :station_journal_source_owner)
    send(owner, {:journal_requested, self(), scope, opts})

    receive do
      {:journal_release, :real} -> Gtfs.list_station_journal(scope, opts)
      {:journal_release, {:raise, message}} -> raise message
      {:journal_release, {:error, reason}} -> raise "controlled journal error: #{inspect(reason)}"
      {:journal_release, entries} when is_list(entries) -> entries
    after
      10_000 -> raise "controlled journal request timed out"
    end
  end

  def list_child_stops_for_parent(organization_id, gtfs_version_id, station_id) do
    notify_target_lookup(:node)
    Gtfs.list_child_stops_for_parent(organization_id, gtfs_version_id, station_id)
  end

  def list_pathways_for_station(organization_id, gtfs_version_id, station_id) do
    notify_target_lookup(:pathway)
    Gtfs.list_pathways_for_station(organization_id, gtfs_version_id, station_id)
  end

  def list_stop_levels_for_station(organization_id, gtfs_version_id, station_id) do
    notify_target_lookup(:pin)
    Gtfs.list_stop_levels_for_station(organization_id, gtfs_version_id, station_id)
  end

  defdelegate resolve_display_zone(organization_id, gtfs_version_id), to: Gtfs
  defdelegate localize_display_times(timestamps, zone_resolution), to: Gtfs

  defp notify_target_lookup(kind) do
    owner = Application.fetch_env!(:gtfs_planner, :station_journal_source_owner)
    send(owner, {:journal_target_lookup, kind})
  end
end

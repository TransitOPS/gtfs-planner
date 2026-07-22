defmodule GtfsPlannerWeb.Gtfs.ControlledJournalSource do
  @moduledoc false

  alias GtfsPlanner.Gtfs

  def list_station_journal(scope, opts) do
    Process.flag(:trap_exit, true)
    owner = Application.fetch_env!(:gtfs_planner, :station_journal_source_owner)
    send(owner, {:journal_requested, self(), scope, opts})

    receive do
      {:journal_release, :real} -> Gtfs.list_station_journal(scope, opts)
      {:journal_release, {:raise, message}} -> raise message
      {:journal_release, entries} when is_list(entries) -> entries
    after
      10_000 -> raise "controlled journal request timed out"
    end
  end

  defdelegate list_child_stops_for_parent(organization_id, gtfs_version_id, station_id),
    to: Gtfs

  defdelegate list_pathways_for_station(organization_id, gtfs_version_id, station_id),
    to: Gtfs

  defdelegate list_stop_levels_for_station(organization_id, gtfs_version_id, station_id),
    to: Gtfs

  defdelegate resolve_display_zone(organization_id, gtfs_version_id), to: Gtfs
  defdelegate localize_display_times(timestamps, zone_resolution), to: Gtfs
end

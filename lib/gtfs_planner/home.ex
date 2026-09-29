defmodule GtfsPlanner.Home do
  @moduledoc """
  The logged-in homepage's read boundary.

  Every function takes the organization and GTFS version ids from the mount
  assigns, so no request parameter selects a tenant or a version, and every read
  is read-only. The module composes the domain reads the page needs — access
  data, resume items, the station board and its statuses, and station editors —
  into display-ready maps, which keeps `DashboardLive` free of context aliases
  and gives the region failure seam one module to substitute.
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.RecentChanges.Describe
  alias GtfsPlanner.Gtfs.StationBoard
  alias GtfsPlanner.Organizations

  @admin_role "pathways_studio_admin"

  @doc """
  Returns the organization's active administrators' emails, sorted.

  A member is an administrator when their membership is not deactivated and
  carries the `#{@admin_role}` role. Members of another organization never
  appear.
  """
  @spec organization_admins(Ecto.UUID.t()) :: [String.t()]
  def organization_admins(organization_id) do
    organization_id
    |> Organizations.list_users_in_organization()
    |> Enum.filter(&active_admin?/1)
    |> Enum.map(& &1.user.email)
    |> Enum.sort()
  end

  @doc """
  Counts the organization's active members.

  A membership with a `deactivated_at` value does not count.
  """
  @spec member_count(Ecto.UUID.t()) :: non_neg_integer()
  def member_count(organization_id) do
    organization_id
    |> Organizations.list_users_in_organization()
    |> Enum.count(&is_nil(&1.deactivated_at))
  end

  @doc """
  Counts all organizations.
  """
  @spec organization_count() :: non_neg_integer()
  def organization_count do
    length(Organizations.list_organizations())
  end

  @doc """
  Returns one user's resume list for one version.

  The scope is `:own` when the user has changes in the version and `:team`
  otherwise. Items are the described recent-change destinations with the
  agency-local time; both the change scan and the description reads use the
  supplied organization and version ids.
  """
  @spec resume(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          %{scope: :own | :team, items: [Describe.resume_item()]}
  def resume(organization_id, gtfs_version_id, user_id) do
    zone = Gtfs.resolve_display_zone(organization_id, gtfs_version_id)

    %{scope: scope, groups: groups} =
      Gtfs.recent_changes_for_user(organization_id, gtfs_version_id, user_id, zone)

    %{
      scope: scope,
      items: Describe.describe(organization_id, gtfs_version_id, groups, zone)
    }
  end

  @doc """
  Returns the station board's station summaries and per-station line counts.

  The summaries are `StationBoard.base/2`. `lines` maps every station `stop_id`
  to the number of routes its child platforms serve, so a station without
  served platforms reports 0. The count comes from the board's one
  platform-to-route query.
  """
  @spec station_board(Ecto.UUID.t(), Ecto.UUID.t()) ::
          %{stations: [StationBoard.base()], lines: %{String.t() => non_neg_integer()}}
  def station_board(organization_id, gtfs_version_id) do
    stations = StationBoard.base(organization_id, gtfs_version_id)

    routes_by_station =
      Gtfs.routes_by_station(organization_id, gtfs_version_id, Enum.map(stations, & &1.stop_id))

    lines =
      Map.new(stations, fn station ->
        {station.stop_id, length(Map.get(routes_by_station, station.stop_id, []))}
      end)

    %{stations: stations, lines: lines}
  end

  @doc """
  Returns the report issue count and latest reachability result per station.

  See `GtfsPlanner.Gtfs.StationBoard.statuses/3`.
  """
  @spec station_statuses(Ecto.UUID.t(), Ecto.UUID.t(), [StationBoard.base()]) ::
          %{String.t() => StationBoard.status()}
  def station_statuses(organization_id, gtfs_version_id, stations) do
    StationBoard.statuses(organization_id, gtfs_version_id, stations)
  end

  @doc """
  Lists station editing statuses with `started_at` localized for display.

  Returns the `Gtfs.list_station_editors/2` entries with `started_at` in the
  agency display zone. An empty version returns an empty list without resolving
  a zone.
  """
  @spec station_editors(Ecto.UUID.t(), Ecto.UUID.t()) :: [map()]
  def station_editors(organization_id, gtfs_version_id) do
    case Gtfs.list_station_editors(organization_id, gtfs_version_id) do
      [] ->
        []

      editors ->
        zone = Gtfs.resolve_display_zone(organization_id, gtfs_version_id)

        local_times =
          Gtfs.localize_display_times(Enum.map(editors, & &1.started_at), zone)

        editors
        |> Enum.zip(local_times)
        |> Enum.map(fn {editor, started_at} -> %{editor | started_at: started_at} end)
    end
  end

  defp active_admin?(%{roles: roles, deactivated_at: deactivated_at}) do
    is_nil(deactivated_at) and @admin_role in roles
  end
end

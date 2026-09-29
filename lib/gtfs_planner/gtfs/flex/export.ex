defmodule GtfsPlanner.Gtfs.Flex.Export do
  @moduledoc """
  Flex export entry points.

  `sequence_mapper/2` is R3's only implementation (INV-3): the `stop_sequence`
  of every trip whose route belongs to an active detour service of the version
  is doubled in every profile that writes `stop_times.txt`, whether or not flex
  is included, whether or not the service is ready and whether or not the trip
  gets any zone rows. The zone rows `Flex.Export.Detours` writes take the odd
  value between. Nothing here reads readiness or geometry, so a service with
  errors still keeps the main feed's sequences stable.

  Both the organization and the version are filters, never defaults (INV-4):
  another organization's or version's detour services never enter the set, so a
  given feed exports the same bytes however its neighbors change.
  """

  import Ecto.Query, warn: false

  alias GtfsPlanner.Gtfs.FlexService
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  @doc """
  Returns the function that doubles a stop time's `stop_sequence` when its trip
  runs on a route an active detour service covers.

  The detour routes and the trips on them are read once, when the mapper is
  built, so every row of one export is answered from the same set and the
  caller binds one mapper to one export snapshot. The function accepts a
  `GtfsPlanner.Gtfs.StopTime` or a map with the same keys and returns the same
  shape; a stop time on any other route is returned unchanged.
  """
  @spec sequence_mapper(Ecto.UUID.t(), Ecto.UUID.t()) ::
          (StopTime.t() | map() -> StopTime.t() | map())
  def sequence_mapper(organization_id, version_id) do
    trip_ids = detour_trip_ids(organization_id, version_id)

    fn
      %{trip_id: trip_id} = stop_time ->
        if MapSet.member?(trip_ids, trip_id) do
          %{stop_time | stop_sequence: stop_time.stop_sequence * 2}
        else
          stop_time
        end

      stop_time ->
        stop_time
    end
  end

  defp detour_trip_ids(organization_id, version_id) do
    route_ids =
      Repo.all(
        from s in FlexService,
          where:
            s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id and
              s.kind == :detour and s.active,
          select: s.route_id
      )

    case route_ids do
      [] -> MapSet.new()
      route_ids -> trip_ids_on(organization_id, version_id, route_ids)
    end
  end

  defp trip_ids_on(organization_id, version_id, route_ids) do
    from(t in Trip,
      where:
        t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id and
          t.route_id in ^route_ids,
      select: t.trip_id
    )
    |> Repo.all()
    |> MapSet.new()
  end
end

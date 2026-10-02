defmodule GtfsPlanner.Gtfs.Fares.Snapshot do
  @moduledoc "Captures persisted fare facts for reviewed edits and inverse fences."
  import Ecto.Query
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Repo

  @schemas [
    Gtfs.FareVersionSetting,
    Gtfs.FareAttribute,
    Gtfs.FareRule,
    Gtfs.Calendar,
    Gtfs.CalendarDate,
    Gtfs.FareProduct,
    Gtfs.FareProductDetail,
    Gtfs.FareLegRule,
    Gtfs.FareTransferRule,
    Gtfs.FareLegJoinRule,
    Gtfs.RiderCategory,
    Gtfs.FareMedia,
    Gtfs.Network,
    Gtfs.RouteNetwork,
    Gtfs.FareTimePeriod,
    Gtfs.Timeframe,
    Gtfs.FareZone,
    Gtfs.StopArea
  ]

  def capture(organization_id, gtfs_version_id) do
    facts =
      Enum.map(@schemas, fn schema ->
        values =
          Repo.all(
            from row in schema,
              where:
                row.organization_id == ^organization_id and
                  row.gtfs_version_id == ^gtfs_version_id
          )

        {schema, values |> Enum.map(&row_values/1) |> Enum.sort()}
      end)

    zones =
      Repo.all(
        from stop in Gtfs.Stop,
          where:
            stop.organization_id == ^organization_id and stop.gtfs_version_id == ^gtfs_version_id,
          select: {stop.stop_id, stop.zone_id}
      )
      |> Enum.sort()

    :crypto.hash(:sha256, :erlang.term_to_binary({facts, zones})) |> Base.encode16(case: :lower)
  end

  def require_current(organization_id, gtfs_version_id, expected) do
    if is_binary(expected) and expected == capture(organization_id, gtfs_version_id),
      do: :ok,
      else: {:error, :stale}
  end

  defp row_values(row) do
    row
    |> Map.from_struct()
    |> Map.take(row.__struct__.__schema__(:fields))
    |> Map.drop([:inserted_at, :updated_at])
  end
end

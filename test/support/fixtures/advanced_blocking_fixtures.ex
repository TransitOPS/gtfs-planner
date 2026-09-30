defmodule GtfsPlanner.AdvancedBlockingFixtures do
  @moduledoc """
  Planning-input fixtures for advanced blocking: block attributes, route
  operating settings, entered driving times, relief points and stops at a
  known point.

  They live in their own module, separate from `GtfsPlanner.BlockingFixtures` and
  `GtfsPlanner.GtfsFixtures`, which parallel packages also edit, and every
  function takes the organization and the GTFS version it writes into, so a test
  can build a foreign organization, another version or a second day type beside
  its own.

  The programmatic fields of a row — the organization and version beside
  `service_id`, `block_id`, `route_id`, `from_ref`, `to_ref` and `stop_id` —
  are set directly in the struct literal, exactly as
  `GtfsPlanner.Gtfs.Blocking` sets them, and the schema changeset casts only the
  user fields. The fixtures therefore never cast a scoping field.
  """

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{BlockAttribute, DeadheadTime, ReliefPoint, RouteOperatingSetting}
  alias GtfsPlanner.GtfsFixtures
  alias GtfsPlanner.Repo

  @doc """
  Creates the planning attributes of one block on one service and returns the row.

  `:service_id` is required and `:block_id` defaults to `"1"`; `:garage_id` and
  `:vehicle_type_id` are the user fields and stay `nil` when not given, which is
  the case a resolution falls back to a route or the default garage from.
  """
  def block_attribute_fixture(organization_id, gtfs_version_id, attrs) do
    %BlockAttribute{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      service_id: Map.fetch!(attrs, :service_id),
      block_id: Map.get(attrs, :block_id, "1")
    }
    |> BlockAttribute.changeset(Map.take(attrs, [:garage_id, :vehicle_type_id]))
    |> Repo.insert!()
  end

  @doc """
  Creates the operating settings of one route and returns the row.

  `:route_id` is required; `:garage_id` and `:required_vehicle_type_id` are the
  user fields and stay `nil` when not given.
  """
  def route_operating_setting_fixture(organization_id, gtfs_version_id, attrs) do
    %RouteOperatingSetting{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      route_id: Map.fetch!(attrs, :route_id)
    }
    |> RouteOperatingSetting.changeset(Map.take(attrs, [:garage_id, :required_vehicle_type_id]))
    |> Repo.insert!()
  end

  @doc """
  Creates a block's planning attributes together with a trip that runs the block
  on that service, and returns the attribute row.

  A `block_attributes` row only counts as a reference to its garage or vehicle
  type while a trip in its version runs that block on that service; without one it
  is a dead row that a delete clears. Takes the same attributes as
  `block_attribute_fixture/3`, with `:service_id` and `:block_id` both required.
  """
  def live_block_attribute_fixture(organization_id, gtfs_version_id, attrs) do
    route = GtfsFixtures.route_fixture(organization_id, gtfs_version_id)

    GtfsFixtures.trip_fixture(organization_id, gtfs_version_id, route.route_id, %{
      service_id: Map.fetch!(attrs, :service_id),
      block_id: Map.fetch!(attrs, :block_id)
    })

    block_attribute_fixture(organization_id, gtfs_version_id, attrs)
  end

  @doc """
  Creates a route's operating settings together with the route, and returns the
  settings row.

  A `route_operating_settings` row only counts as a reference while its route is
  still in the version; without the route it is a dead row that a delete clears.
  Takes the same attributes as `route_operating_setting_fixture/3`.
  """
  def live_route_setting_fixture(organization_id, gtfs_version_id, attrs) do
    GtfsFixtures.route_fixture(organization_id, gtfs_version_id, %{
      route_id: Map.fetch!(attrs, :route_id)
    })

    route_operating_setting_fixture(organization_id, gtfs_version_id, attrs)
  end

  @doc """
  Creates an entered driving time between two references and returns the row.

  `:from_ref` and `:to_ref` are required and `:minutes` defaults to `0`, the
  smallest entered value. A reference is either a
  `GtfsPlanner.Gtfs.Blocking.Context` ref — `{:stop, stop_id}` or
  `{:garage, garage_uuid}` — or the encoded string already stored in the row
  (`"stop:<stop_id>"`, `"garage:<uuid>"`). The encoding is written here rather
  than called from `Blocking.DeadheadTimes`, so these fixtures stand on their
  own; `DeadheadTimes.encode_ref/1` keeps the same two forms.

  The pair is ordered: a row for A→B says nothing about B→A.
  """
  def deadhead_time_fixture(organization_id, gtfs_version_id, attrs) do
    %DeadheadTime{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      from_ref: encode_ref(Map.fetch!(attrs, :from_ref)),
      to_ref: encode_ref(Map.fetch!(attrs, :to_ref))
    }
    |> DeadheadTime.changeset(%{minutes: Map.get(attrs, :minutes, 0)})
    |> Repo.insert!()
  end

  @doc """
  Marks one stop as a relief point and returns the row.

  `:stop_id` is required and is the stop's own GTFS ID, so a child stop is marked
  by its own ID. The parent station it belongs to is collected by the reader, not
  stored here.
  """
  def relief_point_fixture(organization_id, gtfs_version_id, attrs) do
    %ReliefPoint{
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      stop_id: Map.fetch!(attrs, :stop_id)
    }
    |> ReliefPoint.changeset(%{})
    |> Repo.insert!()
  end

  @doc """
  Creates a stop at a caller-chosen point and returns it.

  `:stop_lat` and `:stop_lon` are required because `GtfsFixtures`' defaults are
  one fixed New York pair, and a driving-time estimate or a distance is only
  meaningful against a known point. Either may be `nil` for a child stop that
  inherits its parent station's point. `:parent_station` names a parent station.

  A stop with a parent station is written through `Gtfs.import_create_stop/1`
  rather than `GtfsFixtures.stop_fixture/3`, because `Gtfs.create_stop/1` uses
  `Stop.changeset/2`, which demands a `level_id` for any stop with a parent. The
  import path is the permissive one the importer itself uses, and going through
  the context keeps the input write lock and the `:stops` broadcast that the
  unparented branch already gets from `stop_fixture/3`.
  """
  def stop_with_coordinates_fixture(organization_id, gtfs_version_id, attrs) do
    attrs =
      Map.merge(attrs, %{
        stop_lat: Map.fetch!(attrs, :stop_lat),
        stop_lon: Map.fetch!(attrs, :stop_lon),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id
      })

    if Map.get(attrs, :parent_station) do
      {:ok, stop} = Gtfs.import_create_stop(attrs)
      stop
    else
      GtfsFixtures.stop_fixture(organization_id, gtfs_version_id, attrs)
    end
  end

  # `Blocking.DeadheadTimes.encode_ref/1`, inlined so these fixtures do not depend
  # on the module they exercise. A string is already encoded.
  defp encode_ref(ref) when is_binary(ref), do: ref
  defp encode_ref({:stop, stop_id}), do: "stop:#{stop_id}"
  defp encode_ref({:garage, garage_uuid}), do: "garage:#{garage_uuid}"
end

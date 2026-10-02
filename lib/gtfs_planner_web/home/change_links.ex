defmodule GtfsPlannerWeb.Home.ChangeLinks do
  @moduledoc """
  Editor paths for the homepage.

  Resume items (`GtfsPlanner.Gtfs.RecentChanges.Describe`) and station board
  rows point at the screen where the change can be continued. Every path is a
  verified route, so the route patterns are checked at compile time and query
  values are URL-encoded. `display_name/1` is shared with the change-history
  panel, which delegates here.
  """

  use GtfsPlannerWeb, :verified_routes

  @doc """
  The editor path for a resume item, or `nil` when it has no link (AC-16).

  Station items carry `?level=` only when the operation identified a GTFS
  `level_id`; the diagram falls back to its default level for any other value.
  """
  @spec path(String.t(), map()) :: String.t() | nil
  def path(version_id, %{kind: :schedules, params: %{route_id: route_id, service_id: service_id}}) do
    ~p"/gtfs/#{version_id}/routes/#{route_id}/schedules?#{[service_id: service_id]}"
  end

  def path(version_id, %{kind: :calendar, params: %{service_id: service_id}}) do
    ~p"/gtfs/#{version_id}/calendars/show?#{[service_id: service_id]}"
  end

  def path(version_id, %{
        kind: :route_pattern,
        params: %{route_id: route_id, route_pattern_id: route_pattern_id}
      }) do
    ~p"/gtfs/#{version_id}/routes/#{route_id}/patterns/#{route_pattern_id}"
  end

  def path(version_id, %{kind: :route_patterns, params: %{route_id: route_id}}) do
    ~p"/gtfs/#{version_id}/routes/#{route_id}"
  end

  def path(version_id, %{kind: :station, params: %{stop_id: stop_id} = params}) do
    case Map.get(params, :level_id) do
      level_id when is_binary(level_id) and level_id != "" ->
        ~p"/gtfs/#{version_id}/stops/#{stop_id}/diagram?#{[level: level_id]}"

      _ ->
        ~p"/gtfs/#{version_id}/stops/#{stop_id}/diagram"
    end
  end

  def path(version_id, %{kind: :stop, params: %{stop_id: stop_id}}) do
    ~p"/gtfs/#{version_id}/stops/#{stop_id}"
  end

  def path(version_id, %{kind: :transfers}) do
    ~p"/gtfs/#{version_id}/transfers"
  end

  def path(version_id, %{kind: :fares}) do
    ~p"/gtfs/#{version_id}/settings/fares"
  end

  def path(_version_id, %{kind: :none}), do: nil

  # An item without a destination or without the params its kind needs shows
  # its text instead of failing the region that renders it.
  def path(_version_id, _item), do: nil

  @doc "The stop detail path a station board row links to (AC-21)."
  @spec station_path(String.t(), String.t()) :: String.t()
  def station_path(version_id, stop_id) do
    ~p"/gtfs/#{version_id}/stops/#{stop_id}"
  end

  @doc "The person's name from their email address, or `\"Unknown\"` without one."
  @spec display_name(String.t() | nil) :: String.t()
  def display_name(nil), do: "Unknown"
  def display_name(""), do: "Unknown"

  def display_name(email) when is_binary(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.replace(~r/[._\-]+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &:string.titlecase/1)
  end
end

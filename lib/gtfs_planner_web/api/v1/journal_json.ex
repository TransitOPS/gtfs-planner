defmodule GtfsPlannerWeb.Api.V1.JournalJSON do
  @moduledoc false

  alias GtfsPlanner.Gtfs.JournalEntry
  alias GtfsPlanner.Gtfs.JournalPhoto
  alias GtfsPlanner.Gtfs.StationJournal.{PhotoStorage, Scope}
  alias GtfsPlannerWeb.Endpoint

  @spec entry(JournalEntry.t(), Scope.t()) :: map()
  def entry(%JournalEntry{target_type: "pin"} = entry, %Scope{} = scope) do
    entry
    |> common_entry(scope)
    |> Map.merge(%{
      stop_level_id: entry.stop_level_id,
      diagram_coordinate: %{x: entry.diagram_x, y: entry.diagram_y},
      lat: entry.lat,
      lon: entry.lon
    })
  end

  def entry(%JournalEntry{} = entry, %Scope{} = scope) do
    entry
    |> common_entry(scope)
    |> Map.put(:target_id, entry.target_id)
  end

  @spec photo(JournalPhoto.t(), Scope.t()) :: map()
  def photo(%JournalPhoto{} = photo, %Scope{} = scope) do
    %{
      id: photo.id,
      url: "#{Endpoint.url()}#{PhotoStorage.public_path(scope, photo)}",
      content_type: photo.content_type,
      width: photo.width,
      height: photo.height,
      captured_at: photo.captured_at
    }
  end

  defp common_entry(entry, scope) do
    %{
      id: entry.id,
      target_type: entry.target_type,
      body: entry.body,
      author_id: entry.author_id,
      captured_at: entry.captured_at,
      closed_at: entry.closed_at,
      closed_by: entry.closed_by,
      photos: Enum.map(entry.photos, &photo(&1, scope))
    }
  end
end

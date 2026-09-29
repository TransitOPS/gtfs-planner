defmodule GtfsPlanner.Boundaries do
  @moduledoc """
  Census boundary picker (R9).

  Dispatches to the configured `GtfsPlanner.Boundaries.Behaviour` implementation
  (TIGERweb in production, recorded fixtures in browser journeys). TIGERweb is
  called only while staff choose an area boundary in the area editor, never
  during export or validation (CR-7).

  `land_boundary/2` is the one composed operation: it fetches the chosen
  boundary, asks for the Census water intersecting that boundary's envelope, and
  subtracts it through `Flex.Geometry.land_boundary/2`, so the answer is land
  only and every geometry statement still lives in that module (CR-1).
  """

  alias GtfsPlanner.Boundaries.Behaviour
  alias GtfsPlanner.Gtfs.Flex.Geometry

  @behaviour Behaviour

  @default_service GtfsPlanner.Boundaries.Tigerweb

  # The two-digit state FIPS codes TIGERweb's `STATE` field uses, in name order,
  # for the editor's name-and-state search when the version has no stops to
  # bound the extent picker (AC-10). The Census's own code set; no network call
  # is needed to list them.
  @states [
    {"Alabama", "01"},
    {"Alaska", "02"},
    {"Arizona", "04"},
    {"Arkansas", "05"},
    {"California", "06"},
    {"Colorado", "08"},
    {"Connecticut", "09"},
    {"Delaware", "10"},
    {"District of Columbia", "11"},
    {"Florida", "12"},
    {"Georgia", "13"},
    {"Hawaii", "15"},
    {"Idaho", "16"},
    {"Illinois", "17"},
    {"Indiana", "18"},
    {"Iowa", "19"},
    {"Kansas", "20"},
    {"Kentucky", "21"},
    {"Louisiana", "22"},
    {"Maine", "23"},
    {"Maryland", "24"},
    {"Massachusetts", "25"},
    {"Michigan", "26"},
    {"Minnesota", "27"},
    {"Mississippi", "28"},
    {"Missouri", "29"},
    {"Montana", "30"},
    {"Nebraska", "31"},
    {"Nevada", "32"},
    {"New Hampshire", "33"},
    {"New Jersey", "34"},
    {"New Mexico", "35"},
    {"New York", "36"},
    {"North Carolina", "37"},
    {"North Dakota", "38"},
    {"Ohio", "39"},
    {"Oklahoma", "40"},
    {"Oregon", "41"},
    {"Pennsylvania", "42"},
    {"Rhode Island", "44"},
    {"South Carolina", "45"},
    {"South Dakota", "46"},
    {"Tennessee", "47"},
    {"Texas", "48"},
    {"Utah", "49"},
    {"Vermont", "50"},
    {"Virginia", "51"},
    {"Washington", "53"},
    {"West Virginia", "54"},
    {"Wisconsin", "55"},
    {"Wyoming", "56"}
  ]

  @doc """
  The state FIPS codes the picker's name search offers, as `{name, code}` in
  name order.
  """
  @spec states() :: [{String.t(), String.t()}]
  def states, do: @states

  @impl Behaviour
  def places_near(bbox), do: service().places_near(bbox)

  @impl Behaviour
  def search(name, state_fips), do: service().search(name, state_fips)

  @impl Behaviour
  def boundary(layer, geoid), do: service().boundary(layer, geoid)

  @impl Behaviour
  def water(bbox), do: service().water(bbox)

  @doc """
  Fetches one Census boundary and returns its land polygon.

  The boundary is the picker's choice (`layer` and `geoid`); the returned map
  carries the water-removed geometry with its provenance, so a caller stores
  only land and can label the source. A boundary the service does not know is
  `:not_found`, a service failure is `:unavailable`, and a geometry failure is
  the reason `Flex.Geometry.land_boundary/2` gives (including `:empty` when the
  water leaves no land).
  """
  @spec land_boundary(String.t(), String.t()) ::
          {:ok, %{geojson: map(), geoid: String.t(), layer: String.t(), vintage: String.t()}}
          | {:error, :unavailable | :not_found | term()}
  def land_boundary(layer, geoid) do
    with {:ok, %{geojson: boundary_geojson, vintage: vintage}} <- boundary(layer, geoid),
         {:ok, envelope} <- envelope(boundary_geojson),
         {:ok, water_geojsons} <- water(envelope),
         {:ok, land_geojson} <- Geometry.land_boundary(boundary_geojson, water_geojsons) do
      {:ok, %{geojson: land_geojson, geoid: geoid, layer: layer, vintage: vintage}}
    end
  end

  defp service do
    Application.get_env(:gtfs_planner, :boundaries_service, @default_service)
  end

  # Only water inside the boundary can intersect it, so the boundary's own
  # envelope bounds the water request.
  defp envelope(geojson) do
    case positions(geojson) do
      [] ->
        {:error, :not_found}

      positions ->
        lons = Enum.map(positions, &elem(&1, 0))
        lats = Enum.map(positions, &elem(&1, 1))
        {:ok, {Enum.min(lons), Enum.min(lats), Enum.max(lons), Enum.max(lats)}}
    end
  end

  defp positions(%{"coordinates" => coordinates}), do: flatten(coordinates)
  defp positions(%{"geometry" => geometry}), do: positions(geometry)
  defp positions(_geojson), do: []

  defp flatten([lon, lat | _rest]) when is_number(lon) and is_number(lat) do
    [{lon * 1.0, lat * 1.0}]
  end

  defp flatten(parts) when is_list(parts), do: Enum.flat_map(parts, &flatten/1)
  defp flatten(_part), do: []
end

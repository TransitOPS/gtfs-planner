defmodule GtfsPlanner.Boundaries.Tigerweb do
  @moduledoc """
  Census TIGERweb adapter for the boundary picker (R9).

  Reads the published ArcGIS REST services over HTTPS through `Req`; there is no
  key. The layer IDs below were read once from the two service directories
  (`?f=json`) on 2026-09-29 and name the `BAS 2026` group, whose boundaries are
  the January 1, 2026 vintage that `@vintage` labels. TIGERweb's
  default-visibility layers roll over to the next vintage each January, so the
  next January vintage change updates these four IDs and `@vintage` together.

  A lookup whose GEOID matches nothing answers `:not_found`. Every other failure
  — a non-200 status, a decode error, a transport error, or a body that is not a
  FeatureCollection — answers `:unavailable`, and no error term carries the
  request URL.
  """

  @behaviour GtfsPlanner.Boundaries.Behaviour

  @places_service_url "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/Places_CouSub_ConCity_SubMCD/MapServer"
  @counties_service_url "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/State_County/MapServer"
  @water_query_url "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/Hydro/MapServer/1/query"

  @vintage "2026"

  # The four pickable layers of the pinned vintage. The place and CDP layers
  # carry the same Census place fields; county subdivisions and counties carry
  # their own identity fields.
  @place_layer 11
  @cdp_layer 12
  @county_subdivision_layer 8
  @county_layer 19

  @place_fields "NAME,GEOID,STATE,PLACE,LSADC,FUNCSTAT,AREALAND,AREAWATER,MTFCC"
  @county_subdivision_fields "NAME,GEOID,STATE,COUSUB,FUNCSTAT,MTFCC"
  @county_fields "NAME,GEOID,STATE,COUNTY,FUNCSTAT,MTFCC"
  @water_fields "NAME,MTFCC,AREALAND,AREAWATER,BASENAME,OBJECTID"

  @place_layers [
    %{
      name: "place",
      url: "#{@places_service_url}/#{@place_layer}/query",
      fields: @place_fields,
      cdp?: false
    },
    %{
      name: "cdp",
      url: "#{@places_service_url}/#{@cdp_layer}/query",
      fields: @place_fields,
      cdp?: true
    },
    %{
      name: "county_subdivision",
      url: "#{@places_service_url}/#{@county_subdivision_layer}/query",
      fields: @county_subdivision_fields,
      cdp?: false
    },
    %{
      name: "county",
      url: "#{@counties_service_url}/#{@county_layer}/query",
      fields: @county_fields,
      cdp?: false
    }
  ]

  # The name-and-state search lists the two place layers: a search offers the
  # same town limits the extent picker does.
  @search_layers Enum.filter(@place_layers, &(&1.name in ["place", "cdp"]))

  @impl GtfsPlanner.Boundaries.Behaviour
  def places_near({_west, _south, _east, _north} = bbox) do
    @place_layers
    |> collect(geometry_params(bbox))
    |> sort_places()
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def search(name, state_fips) do
    if searchable?(name, state_fips) do
      @search_layers
      |> collect(where: search_where(String.trim(name), state_fips))
      |> sort_places()
    else
      {:ok, []}
    end
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def boundary(layer_name, geoid) do
    with {:ok, layer} <- layer(layer_name),
         {:ok, features} <- features(layer, where: "GEOID='#{escape(geoid)}'") do
      case Enum.find_value(features, &geometry/1) do
        nil -> {:error, :not_found}
        geometry -> {:ok, %{geojson: geometry, vintage: @vintage}}
      end
    end
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def water({_west, _south, _east, _north} = bbox) do
    layer = %{url: @water_query_url, fields: @water_fields}

    with {:ok, features} <- features(layer, geometry_params(bbox)) do
      {:ok, features |> Enum.map(&geometry/1) |> Enum.reject(&is_nil/1)}
    end
  end

  # The picker lists 500–600 KB of polygons it never draws (the chosen boundary
  # is fetched again by `boundary/2`), so a list request asks for attributes
  # only. `boundary/2` keeps the geometry.
  defp collect(layers, extra_params) do
    params = Keyword.put(extra_params, :returnGeometry, false)

    Enum.reduce_while(layers, {:ok, []}, fn layer, {:ok, places} ->
      case layer_places(layer, params) do
        {:ok, layer_places} -> {:cont, {:ok, places ++ layer_places}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp layer_places(layer, params) do
    with {:ok, features} <- features(layer, params) do
      {:ok, Enum.flat_map(features, &place(layer, &1))}
    end
  end

  # A feature without a name or a GEOID cannot be chosen, and the picker needs
  # the GEOID to fetch its boundary, so such a feature is dropped rather than
  # listed as a dead option.
  defp place(layer, %{"properties" => properties}) when is_map(properties) do
    name = properties["NAME"]
    geoid = properties["GEOID"]

    if present?(name) and present?(geoid) do
      [
        %{
          name: name,
          layer: layer.name,
          geoid: geoid,
          vintage: @vintage,
          cdp?: layer.cdp?,
          state_fips: properties["STATE"]
        }
      ]
    else
      []
    end
  end

  defp place(_layer, _feature), do: []

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp sort_places({:ok, places}), do: {:ok, Enum.sort_by(places, &{&1.name, &1.geoid})}
  defp sort_places({:error, reason}), do: {:error, reason}

  defp features(layer, params) do
    params =
      params
      |> Keyword.put_new(:f, "geojson")
      |> Keyword.put_new(:outSR, 4326)
      |> Keyword.put_new(:outFields, layer.fields)

    case get(layer.url, params) do
      {:ok, %{"features" => features}} when is_list(features) -> {:ok, features}
      {:ok, _body} -> {:error, :unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(url, params) do
    base = [
      params: params,
      receive_timeout: 15_000,
      retry: :safe_transient,
      max_retries: 2
    ]

    options =
      case Application.get_env(:gtfs_planner, :boundaries_req_plug) do
        nil -> base
        plug -> Keyword.put(base, :plug, plug)
      end

    try do
      case Req.get(url, options) do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, %{status: _status}} -> {:error, :unavailable}
        {:error, _reason} -> {:error, :unavailable}
      end
    rescue
      _error -> {:error, :unavailable}
    end
  end

  defp geometry(%{"geometry" => %{} = geometry}), do: geometry
  defp geometry(_feature), do: nil

  defp layer(name) do
    case Enum.find(@place_layers, &(&1.name == name)) do
      nil -> {:error, :not_found}
      layer -> {:ok, layer}
    end
  end

  defp searchable?(name, state_fips) do
    is_binary(name) and String.trim(name) != "" and is_binary(state_fips) and
      Regex.match?(~r/\A\d{2}\z/, state_fips)
  end

  defp search_where(name, state_fips) do
    "STATE='#{escape(state_fips)}' AND UPPER(NAME) LIKE UPPER('#{escape(name)}%')"
  end

  defp escape(value), do: String.replace(value, "'", "''")

  defp geometry_params({west, south, east, north}) do
    [
      geometry: Enum.map_join([west, south, east, north], ",", &coordinate/1),
      geometryType: "esriGeometryEnvelope",
      inSR: 4326
    ]
  end

  # Six decimals is about 0.1 m at these latitudes; a fixed width keeps the
  # request URL deterministic.
  defp coordinate(value) do
    value
    |> Kernel.*(1.0)
    |> Float.round(6)
    |> :erlang.float_to_binary(decimals: 6)
  end
end

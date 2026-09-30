defmodule GtfsPlanner.Geocoding.Geoapify do
  @moduledoc """
  Implementation of the Geocoding behaviour using the Geoapify API.
  """

  alias GtfsPlanner.Geocoding.Behaviour
  alias GtfsPlanner.Geocoding.Place
  alias GtfsPlanner.Geocoding.Result

  @behaviour Behaviour

  @reverse_url "https://api.geoapify.com/v1/geocode/reverse"
  @reverse_limit 5

  @impl Behaviour
  def autocomplete(text, _opts) when is_binary(text) do
    if String.length(text) < 3 do
      {:error, :text_too_short}
    else
      fetch_from_api(text, [])
    end
  end

  defp fetch_from_api(text, _opts) do
    api_key = Application.get_env(:gtfs_planner, :geoapify_api_key)

    if is_nil(api_key) do
      {:error, :api_key_missing}
    else
      params = %{
        text: text,
        apiKey: api_key,
        format: "json",
        limit: 5,
        filter: "countrycode:us"
      }

      case Req.get("https://api.geoapify.com/v1/geocode/autocomplete", params: params) do
        {:ok, %{status: 200, body: %{"results" => results}}} ->
          parse_results(results)

        {:ok, %{status: status}} ->
          {:error, {:api_error, status}}

        {:error, _reason} ->
          {:error, :network_error}
      end
    end
  end

  defp parse_results(results) when is_list(results) do
    parsed =
      Enum.map(results, fn result ->
        %Result{
          formatted_address: Map.get(result, "formatted", ""),
          lat: Map.get(result, "lat", 0.0),
          lon: Map.get(result, "lon", 0.0),
          country: Map.get(result, "country"),
          state: Map.get(result, "state"),
          city: Map.get(result, "city")
        }
      end)

    {:ok, parsed}
  end

  @doc """
  Reports the places near a coordinate.

  Street first, then amenities, because a stop's name comes from the street it
  stands on; `:amenities` is a second request for the candidates the stop editor
  offers alongside it, not a replacement.

  The API key is read per call and never returned in an error term: a 500 or a
  transport failure is reported by status or as `:network_error`, so a key that
  has reached an error tuple or a log line is a leak.
  """
  @impl Behaviour
  def reverse(lat, lon, opts) when is_number(lat) and is_number(lon) do
    api_key = Application.get_env(:gtfs_planner, :geoapify_api_key)

    if is_nil(api_key) do
      {:error, :api_key_missing}
    else
      with {:ok, streets} <- reverse_pass(lat, lon, "street", api_key, opts),
           {:ok, amenities} <- maybe_reverse_amenities(lat, lon, api_key, opts) do
        {:ok, streets ++ amenities}
      end
    end
  end

  defp maybe_reverse_amenities(lat, lon, api_key, opts) do
    if Keyword.get(opts, :amenities, false) do
      reverse_pass(lat, lon, "amenity", api_key, opts)
    else
      {:ok, []}
    end
  end

  defp reverse_pass(lat, lon, type, api_key, _opts) do
    params = %{
      lat: lat,
      lon: lon,
      type: type,
      limit: @reverse_limit,
      format: "json",
      filter: "countrycode:us",
      apiKey: api_key
    }

    case Req.get(@reverse_url, req_options(params)) do
      {:ok, %{status: 200, body: %{"features" => features}}} -> {:ok, parse_places(features)}
      {:ok, %{status: status}} -> {:error, {:api_error, status}}
      {:error, _reason} -> {:error, :network_error}
    end
  end

  # Geoapify wraps each place in a GeoJSON `Feature` whose `properties` hold the
  # address parts. Every part is optional in practice, so each is read with a
  # default rather than pattern-matched: a place with no `street` is still a
  # place the editor can offer, just a less useful one.
  defp parse_places(features) when is_list(features) do
    Enum.map(features, &parse_place/1)
  end

  defp parse_place(%{"properties" => properties}) when is_map(properties) do
    %Place{
      name: place_name(properties),
      street: Map.get(properties, "street"),
      city: Map.get(properties, "city"),
      state: Map.get(properties, "state"),
      country: Map.get(properties, "country"),
      lat: Map.get(properties, "lat", 0.0),
      lon: Map.get(properties, "lon", 0.0),
      distance_m: Map.get(properties, "distance")
    }
  end

  defp parse_place(_feature), do: %Place{name: "", lat: 0.0, lon: 0.0}

  # A street feature names itself through `street`; a building or a point of
  # interest names itself through `name`. The full formatted address is not used
  # as the name: the editor shows the street on its own line.
  defp place_name(properties) do
    Map.get(properties, "street") || Map.get(properties, "name") || Map.get(properties, "formatted", "")
  end

  defp req_options(params) do
    base = [params: params, receive_timeout: 15_000, retry: :safe_transient, max_retries: 2]

    case Application.get_env(:gtfs_planner, :geocoding_req_plug) do
      nil -> base
      plug -> Keyword.put(base, :plug, plug)
    end
  end
end

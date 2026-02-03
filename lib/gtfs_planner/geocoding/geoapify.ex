defmodule GtfsPlanner.Geocoding.Geoapify do
  @moduledoc """
  Implementation of the Geocoding behaviour using the Geoapify API.
  """

  alias GtfsPlanner.Geocoding.Behaviour
  alias GtfsPlanner.Geocoding.Result

  @behaviour Behaviour

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
end

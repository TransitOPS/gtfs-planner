defmodule GtfsPlanner.Geocoding do
  @moduledoc """
  Context module for geocoding operations using the Geoapify API.

  Provides address autocomplete functionality that converts user-friendly
  address strings into geographic coordinates (latitude/longitude).
  """

  defmodule Result do
    @moduledoc """
    Represents a geocoding result from the Geoapify API.
    """

    @derive Jason.Encoder
    @enforce_keys [:formatted_address, :lat, :lon]
    defstruct [:formatted_address, :lat, :lon, :country, :state, :city]

    @type t :: %__MODULE__{
            formatted_address: String.t(),
            lat: float(),
            lon: float(),
            country: String.t() | nil,
            state: String.t() | nil,
            city: String.t() | nil
          }
  end

  @doc """
  Fetches address autocomplete suggestions from Geoapify API.

  Returns `{:ok, [Result.t()]}` on success or `{:error, reason}` on failure.

  ## Parameters

    - `text` - The search query string (minimum 3 characters)
    - `opts` - Optional keyword list of options (currently unused)

  ## Examples

      iex> autocomplete("123 Main St")
      {:ok, [%Result{formatted_address: "123 Main Street...", lat: 40.7, lon: -74.0}]}

      iex> autocomplete("ab")
      {:error, :text_too_short}
  """
  @spec autocomplete(String.t(), keyword()) :: {:ok, [Result.t()]} | {:error, atom() | tuple()}
  def autocomplete(text, opts \\ [])

  def autocomplete(text, _opts) when is_binary(text) do
    if String.length(text) < 3 do
      {:error, :text_too_short}
    else
      fetch_from_api(text, [])
    end
  end

  # Private functions

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

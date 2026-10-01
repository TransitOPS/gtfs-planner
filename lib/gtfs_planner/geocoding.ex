defmodule GtfsPlanner.Geocoding do
  @moduledoc """
  Context module for geocoding operations using the Geoapify API.

  Provides address autocomplete functionality that converts user-friendly
  address strings into geographic coordinates (latitude/longitude).
  """

  alias GtfsPlanner.Geocoding.Behaviour
  alias GtfsPlanner.Geocoding.Result

  @behaviour Behaviour

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
  def autocomplete(text, opts \\ []) do
    service().autocomplete(text, opts)
  end

  @doc """
  Reports the places near a coordinate, for a stop placed by clicking a map.

  Returns `{:ok, [GtfsPlanner.Geocoding.Place.t()]}` on success or
  `{:error, reason}` on failure. `opts` may carry `:amenities`, which asks for
  the second pass over nearby amenities the stop editor offers.
  """
  @spec reverse(float(), float(), keyword()) ::
          {:ok, [GtfsPlanner.Geocoding.Place.t()]} | {:error, atom() | tuple()}
  def reverse(lat, lon, opts \\ []) do
    service().reverse(lat, lon, opts)
  end

  # The configured adapter is a module, so its functions are called directly
  # rather than through `apply/3`.
  defp service, do: Application.get_env(:gtfs_planner, :geocoding_service)
end

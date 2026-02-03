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
    Application.get_env(:gtfs_planner, :geocoding_service)
    |> apply(:autocomplete, [text, opts])
  end
end

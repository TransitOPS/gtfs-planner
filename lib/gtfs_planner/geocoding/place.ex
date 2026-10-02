defmodule GtfsPlanner.Geocoding.Place do
  @moduledoc """
  A place near a coordinate, as Geoapify's reverse geocoding reports it.

  A stop editor starts from a map click rather than a typed address, so it needs
  the reverse of autocomplete: what is at this point, and how far is it from
  where the editor clicked.

  `distance_m` is the distance from the queried coordinate to the place, in
  metres. It is what tells the editor whether a click landed on the street the
  stop is on or a block away, so it is kept separate from the place's own
  coordinates: `lat`/`lon` are where the street is, `distance_m` is how far the
  click was from it.
  """

  @derive Jason.Encoder
  @enforce_keys [:name, :lat, :lon]
  defstruct [:name, :street, :city, :state, :country, :lat, :lon, :distance_m]

  @type t :: %__MODULE__{
          name: String.t(),
          street: String.t() | nil,
          city: String.t() | nil,
          state: String.t() | nil,
          country: String.t() | nil,
          lat: float(),
          lon: float(),
          distance_m: float() | nil
        }
end

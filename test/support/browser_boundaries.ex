defmodule GtfsPlanner.BrowserBoundaries do
  @moduledoc """
  Test-only Census boundary adapter for browser journeys.

  `config/test.exs` selects it only while `BROWSER_E2E` is `true`, because a
  Playwright journey drives the area editor in a real browser where no
  `Req.Test` plug exists. Ordinary ExUnit runs keep
  `GtfsPlanner.Boundaries.Tigerweb`.

  It answers the behaviour from the recorded TIGERweb fixtures in
  `test/fixtures/tigerweb/`, so a journey sees the same Newport and Toledo
  places and the same water-removed Newport boundary as the recorded adapter,
  without a network call. `water/1` answers every recorded water feature: water
  outside the chosen boundary cannot change the subtraction result. Only the two
  recorded place boundaries exist, so a census-designated place or county pick
  answers `{:error, :not_found}` and a journey picks a town limit.
  """

  @behaviour GtfsPlanner.Boundaries.Behaviour

  @fixtures Path.expand("../fixtures/tigerweb", __DIR__)
  @vintage "2026"
  @boundary_fixtures %{"4152450" => "place_4152450.json", "4174000" => "place_4174000.json"}
  @water_fixtures ["water_newport.json", "water_toledo.json"]

  @impl GtfsPlanner.Boundaries.Behaviour
  def places_near(_bbox) do
    {:ok, Enum.sort_by(places(), &{&1.name, &1.geoid})}
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def search(name, state_fips) do
    needle = String.downcase(String.trim(name))

    results =
      Enum.filter(places(), fn place ->
        place.state_fips == state_fips and
          String.starts_with?(String.downcase(place.name), needle)
      end)

    {:ok, Enum.sort_by(results, &{&1.name, &1.geoid})}
  end

  @impl GtfsPlanner.Boundaries.Behaviour
  def boundary("place", geoid) do
    with file when is_binary(file) <- @boundary_fixtures[geoid],
         %{"geometry" => %{} = geometry} <- first_feature(file) do
      {:ok, %{geojson: geometry, vintage: @vintage}}
    else
      _missing -> {:error, :not_found}
    end
  end

  def boundary(_layer, _geoid), do: {:error, :not_found}

  @impl GtfsPlanner.Boundaries.Behaviour
  def water(_bbox) do
    {:ok, Enum.flat_map(@water_fixtures, &feature_geometries/1)}
  end

  # The recorded bbox response carries the two prototype places plus one
  # census-designated place; the CDP is the statistical (`FUNCSTAT` "S") one.
  defp places do
    Enum.map(features("places_bbox.json"), fn %{"properties" => properties} ->
      cdp? = properties["FUNCSTAT"] == "S"

      %{
        name: properties["NAME"],
        layer: if(cdp?, do: "cdp", else: "place"),
        geoid: properties["GEOID"],
        vintage: @vintage,
        cdp?: cdp?,
        state_fips: properties["STATE"]
      }
    end)
  end

  defp feature_geometries(file), do: Enum.map(features(file), & &1["geometry"])

  defp first_feature(file) do
    case features(file) do
      [feature | _rest] -> feature
      [] -> nil
    end
  end

  defp features(file) do
    @fixtures
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("features")
  end
end

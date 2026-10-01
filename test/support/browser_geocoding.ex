defmodule GtfsPlanner.BrowserGeocoding do
  @moduledoc """
  Test-only geocoding adapter for browser journeys.

  `config/test.exs` selects it only while `BROWSER_E2E` is `true`, because a
  Playwright journey drives an address search in a real browser where no Mox
  expectation exists. Ordinary ExUnit runs keep `GtfsPlanner.GeocodingMock`.

  The adapter answers the same contract as the production adapter
  (`GtfsPlanner.Geocoding.Geoapify`): `{:error, :text_too_short}` below three
  characters, and `{:ok, [GtfsPlanner.Geocoding.Result.t()]}` above it — with one
  deterministic Cedar Valley result so a journey can assert the filled
  coordinates. `zz-slow` waits for a later `zz-release` query, so browser
  captures observe searching without depending on a fixed delay. `zz-release`
  waits for the old task to exit and returns no matches; `zz-fail` returns a
  network error for retry-state captures.
  """

  @behaviour GtfsPlanner.Geocoding.Behaviour

  alias GtfsPlanner.Geocoding.Result

  # The production adapter's minimum query length, so the page renders its
  # short-query failure in the browser exactly as it does in production.
  @minimum_query_length 3
  @slow_search_name :garage_browser_slow_geocoding
  @release_search_name :garage_browser_release_geocoding

  @selected_result %Result{
    formatted_address: "120 Depot Road, Cedar Valley",
    lat: 44.4759,
    lon: -73.2121,
    city: "Cedar Valley"
  }

  @impl GtfsPlanner.Geocoding.Behaviour
  def autocomplete("zz-slow", _opts) do
    true = Process.register(self(), @slow_search_name)

    if releaser = Process.whereis(@release_search_name) do
      send(releaser, {:slow_search_ready, self()})
    end

    receive do
      :release_slow_search -> {:ok, [@selected_result]}
    end
  end

  def autocomplete("zz-release", _opts) do
    true = Process.register(self(), @release_search_name)

    slow_task =
      case Process.whereis(@slow_search_name) do
        nil ->
          receive do
            {:slow_search_ready, pid} -> pid
          end

        pid ->
          pid
      end

    ref = Process.monitor(slow_task)
    send(slow_task, :release_slow_search)

    receive do
      {:DOWN, ^ref, :process, ^slow_task, _reason} -> {:ok, []}
    end
  end

  def autocomplete("zz-fail", _opts), do: {:error, :network_error}

  def autocomplete(text, _opts) when is_binary(text) do
    if String.length(text) < @minimum_query_length do
      {:error, :text_too_short}
    else
      {:ok, [@selected_result]}
    end
  end

  @impl GtfsPlanner.Geocoding.Behaviour
  def reverse(lat, lon, opts) when is_number(lat) and is_number(lon) do
    amenities = [
      %GtfsPlanner.Geocoding.Place{
        name: "Cedar Valley Transit Center",
        city: "Cedar Valley",
        state: "VT",
        country: "us",
        lat: lat,
        lon: lon,
        distance_m: 42.0
      }
    ]

    streets =
      if Keyword.get(opts, :only) == :amenity do
        []
      else
        [
          %GtfsPlanner.Geocoding.Place{
            name: "Depot Road",
            street: "Depot Road",
            city: "Cedar Valley",
            state: "VT",
            country: "us",
            lat: lat,
            lon: lon,
            distance_m: 0.0
          }
        ]
      end

    if Keyword.get(opts, :amenities, false) do
      {:ok, streets ++ amenities}
    else
      {:ok, streets}
    end
  end
end

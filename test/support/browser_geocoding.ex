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
  coordinates. `zz-slow` delays that result for searching-state captures, and
  `zz-fail` returns a network error for retry-state captures.
  """

  @behaviour GtfsPlanner.Geocoding.Behaviour

  alias GtfsPlanner.Geocoding.Result

  # The production adapter's minimum query length, so the page renders its
  # short-query failure in the browser exactly as it does in production.
  @minimum_query_length 3

  @selected_result %Result{
    formatted_address: "120 Depot Road, Cedar Valley",
    lat: 44.4759,
    lon: -73.2121,
    city: "Cedar Valley"
  }

  @impl GtfsPlanner.Geocoding.Behaviour
  def autocomplete("zz-slow", _opts) do
    Process.sleep(1_500)
    {:ok, [@selected_result]}
  end

  def autocomplete("zz-fail", _opts), do: {:error, :network_error}

  def autocomplete(text, _opts) when is_binary(text) do
    if String.length(text) < @minimum_query_length do
      {:error, :text_too_short}
    else
      {:ok, [@selected_result]}
    end
  end
end

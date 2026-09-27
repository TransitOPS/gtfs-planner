defmodule GtfsPlanner.GeocodingTest do
  use GtfsPlanner.DataCase, async: true

  import Mox

  alias GtfsPlanner.BrowserGeocoding
  alias GtfsPlanner.Geocoding
  alias GtfsPlanner.Geocoding.Result

  describe "autocomplete/2" do
    test "returns error when text is less than 3 characters" do
      stub(GtfsPlanner.GeocodingMock, :autocomplete, fn "ab", _opts ->
        {:error, :text_too_short}
      end)

      assert {:error, :text_too_short} = Geocoding.autocomplete("ab")
    end

    test "returns error when API key is missing" do
      stub(GtfsPlanner.GeocodingMock, :autocomplete, fn "test", _opts ->
        {:error, :api_key_missing}
      end)

      assert {:error, :api_key_missing} = Geocoding.autocomplete("test")
    end

    test "returns results with valid text" do
      stub(GtfsPlanner.GeocodingMock, :autocomplete, fn "Regent", _opts ->
        {:ok,
         [
           %GtfsPlanner.Geocoding.Result{
             formatted_address: "Regent, ND, United States of America",
             lat: 46.4216712,
             lon: -102.555719,
             country: "United States",
             state: "North Dakota",
             city: "Regent"
           }
         ]}
      end)

      case Geocoding.autocomplete("Regent") do
        {:ok, results} ->
          assert is_list(results)
          first_result = List.first(results)
          assert %Geocoding.Result{} = first_result
          assert is_binary(first_result.formatted_address)
          assert is_float(first_result.lat)
          assert is_float(first_result.lon)

        {:error, reason} ->
          flunk("Expected :ok, got {:error, #{inspect(reason)}}")
      end
    end

    test "handles network errors gracefully" do
      stub(GtfsPlanner.GeocodingMock, :autocomplete, fn "test query", _opts ->
        {:error, :network_error}
      end)

      assert {:error, :network_error} == Geocoding.autocomplete("test query")
    end

    test "dispatches through the adapter configured for this environment" do
      expect(GtfsPlanner.GeocodingMock, :autocomplete, fn "Depot", [] ->
        {:ok, [%Result{formatted_address: "120 Depot Road, Cedar Valley", lat: 1.0, lon: 2.0}]}
      end)

      assert {:ok, [%Result{formatted_address: "120 Depot Road, Cedar Valley"}]} =
               Geocoding.autocomplete("Depot")
    end
  end

  describe "browser journey configuration" do
    test "selects the deterministic browser adapter only under BROWSER_E2E" do
      configured = Application.get_env(:gtfs_planner, :geocoding_service)

      if System.get_env("BROWSER_E2E") == "true" do
        assert configured == BrowserGeocoding
      else
        assert configured == GtfsPlanner.GeocodingMock
      end
    end

    test "the browser adapter returns the deterministic result for a long enough query" do
      assert {:ok, [result]} = BrowserGeocoding.autocomplete("Depot", [])

      assert %Result{
               formatted_address: "120 Depot Road, Cedar Valley",
               lat: 44.4759,
               lon: -73.2121
             } = result
    end

    test "the browser adapter keeps the production short-query error" do
      assert {:error, :text_too_short} == BrowserGeocoding.autocomplete("ab", [])
      assert {:error, :text_too_short} == BrowserGeocoding.autocomplete("", [])
    end
  end
end

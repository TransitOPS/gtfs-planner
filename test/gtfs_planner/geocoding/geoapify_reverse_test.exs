defmodule GtfsPlanner.Geocoding.GeoapifyReverseTest do
  @moduledoc """
  The Geoapify adapter's `reverse/3` is what turns a map click into an address,
  so the stop editor can name a stop the editor placed rather than typed.

  Two things are checked beyond the parsing. The request the adapter makes is
  checked, because a wrong `type` or a missing coordinate parameter produces a
  plausible-looking answer for the wrong place. And no error term carries the
  API key, because a key in an error tuple reaches logs and user-facing
  messages.

  The response fixture is the shape Geoapify's reverse geocoding documents: a
  GeoJSON `FeatureCollection` whose `features` each carry a `properties` map.
  The live API is not called.
  """

  use ExUnit.Case, async: false

  alias GtfsPlanner.Geocoding.Geoapify

  @owner GtfsPlanner.Geocoding.Geoapify
  @test_key "test-geocoding-key-3c2b1a0f9e8d"
  @lat 44.6376
  @lon -124.053

  setup do
    original_key = Application.get_env(:gtfs_planner, :geoapify_api_key)
    Application.put_env(:gtfs_planner, :geoapify_api_key, @test_key)

    on_exit(fn ->
      if is_nil(original_key) do
        Application.delete_env(:gtfs_planner, :geoapify_api_key)
      else
        Application.put_env(:gtfs_planner, :geoapify_api_key, original_key)
      end
    end)

    :ok
  end

  # The documented reverse-geocoding response shape: a FeatureCollection whose
  # features are GeoJSON features with the address in `properties`.
  defp feature_collection do
    %{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "geometry" => %{"type" => "Point", "coordinates" => [-124.0531, 44.6377]},
          "properties" => %{
            "country" => "us",
            "state" => "Oregon",
            "city" => "Newport",
            "street" => "NE 1st Street",
            "houseNumber" => "235",
            "name" => "Yaquina Bay Bridge",
            "formatted" => "Yaquina Bay Bridge, Newport, Oregon, us",
            "distance" => 12.3456,
            "lat" => 44.6377,
            "lon" => -124.0531
          }
        }
      ]
    }
  end

  defp street_feature, do: feature_collection()

  defp amenity_feature do
    %{
      "type" => "FeatureCollection",
      "features" => [
        %{
          "type" => "Feature",
          "geometry" => %{"type" => "Point", "coordinates" => [-124.052, 44.638]},
          "properties" => %{
            "country" => "us",
            "state" => "Oregon",
            "city" => "Newport",
            "name" => "Cleo's Marina",
            "formatted" => "Cleo's Marina, Newport, Oregon, us",
            "distance" => 310.5,
            "lat" => 44.638,
            "lon" => -124.052
          }
        }
      ]
    }
  end

  describe "parsing" do
    test "a street feature becomes a place with its street and distance" do
      Req.Test.stub(@owner, fn conn ->
        assert conn.request_path == "/v1/geocode/reverse"

        Req.Test.json(conn, street_feature())
      end)

      assert {:ok, [place]} = Geoapify.reverse(@lat, @lon, [])

      assert place.street == "NE 1st Street"
      assert place.name == "NE 1st Street"
      assert place.city == "Newport"
      assert place.state == "Oregon"
      assert place.country == "us"
      assert place.distance_m == 12.3456
      assert place.lat == 44.6377
      assert place.lon == -124.0531
    end

    test "a place with no street falls back to its name" do
      Req.Test.stub(@owner, fn conn -> Req.Test.json(conn, amenity_feature()) end)

      assert {:ok, [place]} = Geoapify.reverse(@lat, @lon, [])

      assert place.street == nil
      assert place.name == "Cleo's Marina"
    end

    test "a place missing street, name and distance still parses" do
      sparse = %{
        "features" => [%{"properties" => %{"lat" => 44.6, "lon" => -124.05}}]
      }

      Req.Test.stub(@owner, fn conn -> Req.Test.json(conn, sparse) end)

      assert {:ok, [place]} = Geoapify.reverse(@lat, @lon, [])
      assert place.name == ""
      assert place.distance_m == nil
    end
  end

  describe "the request" do
    test "carries lat, lon, type=street, limit=5 and the configured key" do
      Req.Test.expect(@owner, fn conn ->
        params = conn.query_params

        assert params["lat"] == to_string(@lat)
        assert params["lon"] == to_string(@lon)
        assert params["type"] == "street"
        assert params["limit"] == "5"
        assert params["apiKey"] == @test_key

        Req.Test.json(conn, feature_collection())
      end)

      assert {:ok, [_place]} = Geoapify.reverse(@lat, @lon, [])
    end
  end

  describe "the amenities pass" do
    test "opts amenities: true makes a second request with type=amenity" do
      Req.Test.expect(@owner, 2, fn conn ->
        params = conn.query_params

        if params["type"] == "street" do
          Req.Test.json(conn, feature_collection())
        else
          assert params["type"] == "amenity"

          Req.Test.json(conn, amenity_feature())
        end
      end)

      assert {:ok, [street, amenity]} = Geoapify.reverse(@lat, @lon, amenities: true)
      assert street.street == "NE 1st Street"
      assert amenity.name == "Cleo's Marina"
    end

    test "without it only the street is requested" do
      Req.Test.expect(@owner, fn conn ->
        assert conn.query_params["type"] == "street"

        Req.Test.json(conn, feature_collection())
      end)

      assert {:ok, [_place]} = Geoapify.reverse(@lat, @lon, [])
    end
  end

  describe "only: :amenity" do
    # One request, not two: the street pass is skipped rather than run and
    # discarded, because a request the caller will not use is a key's worth of
    # quota spent on nothing. `Req.Test.expect/3` with a count of one fails the
    # test if a second request arrives, which is how that is checked.
    test "asks for the amenities and never for the streets" do
      Req.Test.expect(@owner, fn conn ->
        assert conn.query_params["type"] == "amenity"

        Req.Test.json(conn, amenity_feature())
      end)

      assert {:ok, [amenity]} = Geoapify.reverse(@lat, @lon, amenities: true, only: :amenity)
      assert amenity.name == "Cleo's Marina"
    end

    test "without :amenities the amenity pass is not made at all" do
      Req.Test.expect(@owner, fn conn ->
        Req.Test.json(conn, amenity_feature())
      end)

      assert {:ok, []} = Geoapify.reverse(@lat, @lon, only: :amenity)
    end
  end

  describe "failures" do
    test "a 500 is an api_error carrying the status" do
      Req.Test.stub(@owner, fn conn ->
        Req.Test.json(%{conn | status: 500}, %{"error" => "upstream"})
      end)

      assert Geoapify.reverse(@lat, @lon, []) == {:error, {:api_error, 500}}
    end

    test "a transport error is a network_error" do
      Req.Test.stub(@owner, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert Geoapify.reverse(@lat, @lon, []) == {:error, :network_error}
    end

    test "no error term carries the API key" do
      Req.Test.stub(@owner, fn conn -> Req.Test.json(%{conn | status: 500}, %{}) end)
      assert {:error, api_error} = Geoapify.reverse(@lat, @lon, [])
      refute inspect(api_error) =~ @test_key

      Req.Test.stub(@owner, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, network_error} = Geoapify.reverse(@lat, @lon, [])
      refute inspect(network_error) =~ @test_key
    end

    test "with no key configured it refuses without making a request" do
      Application.delete_env(:gtfs_planner, :geoapify_api_key)

      # No stub is registered: a request would raise rather than return.
      assert Geoapify.reverse(@lat, @lon, []) == {:error, :api_key_missing}
    end
  end
end

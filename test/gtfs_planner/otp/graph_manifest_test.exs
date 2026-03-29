defmodule GtfsPlanner.Otp.GraphManifestTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.GraphManifest

  test "build/6 returns expected graph manifest shape" do
    built_at = ~U[2026-02-18 18:00:00Z]

    manifest =
      GraphManifest.build(
        "gtfs_hash_123",
        "gtfs_input_sha_abc",
        "osm_fp_456",
        "jar_sha_789",
        %{"command" => "java -jar otp.jar --build --save data"},
        built_at
      )

    assert manifest["schema_version"] == GraphManifest.schema_version()
    assert manifest["gtfs_content_hash"] == "gtfs_hash_123"
    assert manifest["gtfs_input_sha256"] == "gtfs_input_sha_abc"
    assert manifest["osm_fingerprint"] == "osm_fp_456"
    assert manifest["otp_jar_sha256"] == "jar_sha_789"
    assert manifest["build"] == %{"command" => "java -jar otp.jar --build --save data"}
    assert manifest["timestamps"]["built_at"] == "2026-02-18T18:00:00Z"
    assert GraphManifest.valid?(manifest)
  end

  test "valid?/1 accepts nil jar fingerprint" do
    built_at = ~U[2026-02-18 18:00:00Z]

    manifest =
      GraphManifest.build(
        "gtfs_hash_123",
        "gtfs_input_sha_abc",
        "osm_fp_456",
        nil,
        %{"command" => "java -jar otp.jar --build --save data"},
        built_at
      )

    assert is_nil(manifest["otp_jar_sha256"])
    assert GraphManifest.valid?(manifest)
  end

  test "valid?/1 rejects manifest with invalid timestamp" do
    manifest = %{
      "schema_version" => GraphManifest.schema_version(),
      "gtfs_content_hash" => "gtfs_hash_123",
      "gtfs_input_sha256" => "gtfs_input_sha_abc",
      "osm_fingerprint" => "osm_fp_456",
      "otp_jar_sha256" => "jar_sha_789",
      "build" => %{"command" => "java -jar otp.jar --build --save data"},
      "timestamps" => %{"built_at" => "not-an-iso8601-timestamp"}
    }

    refute GraphManifest.valid?(manifest)
  end

  test "valid?/1 rejects manifest without gtfs_input_sha256" do
    manifest = %{
      "schema_version" => GraphManifest.schema_version(),
      "gtfs_content_hash" => "gtfs_hash_123",
      "osm_fingerprint" => "osm_fp_456",
      "otp_jar_sha256" => "jar_sha_789",
      "build" => %{"command" => "java -jar otp.jar --build --save data"},
      "timestamps" => %{"built_at" => "2026-02-18T18:00:00Z"}
    }

    refute GraphManifest.valid?(manifest)
  end
end

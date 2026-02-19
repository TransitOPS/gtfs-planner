defmodule GtfsPlanner.Otp.GraphManifest do
  @moduledoc """
  Schema and helpers for OTP graph cache manifest payloads.

  The manifest captures graph build inputs and metadata used for cache
  validation.
  """

  @schema_version 1

  @type t :: map()

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec build(String.t(), String.t(), String.t() | nil, map(), DateTime.t()) :: t()
  def build(gtfs_content_hash, osm_fingerprint, otp_jar_sha256, build_metadata, built_at)
      when is_binary(gtfs_content_hash) and is_binary(osm_fingerprint) and
             (is_binary(otp_jar_sha256) or is_nil(otp_jar_sha256)) and is_map(build_metadata) and
             is_struct(built_at, DateTime) do
    %{
      "schema_version" => @schema_version,
      "gtfs_content_hash" => gtfs_content_hash,
      "osm_fingerprint" => osm_fingerprint,
      "otp_jar_sha256" => otp_jar_sha256,
      "build" => build_metadata,
      "timestamps" => %{
        "built_at" => DateTime.to_iso8601(built_at)
      }
    }
  end

  @spec valid?(map()) :: boolean()
  def valid?(manifest) when is_map(manifest) do
    is_integer(manifest["schema_version"]) and
      is_binary(manifest["gtfs_content_hash"]) and
      is_binary(manifest["osm_fingerprint"]) and
      (is_binary(manifest["otp_jar_sha256"]) or is_nil(manifest["otp_jar_sha256"])) and
      is_map(manifest["build"]) and
      valid_timestamps?(manifest["timestamps"])
  end

  def valid?(_manifest), do: false

  defp valid_timestamps?(timestamps) when is_map(timestamps) do
    case timestamps["built_at"] do
      built_at when is_binary(built_at) ->
        case DateTime.from_iso8601(built_at) do
          {:ok, _datetime, _offset} -> true
          _ -> false
        end

      _other ->
        false
    end
  end

  defp valid_timestamps?(_timestamps), do: false
end

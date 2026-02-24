defmodule GtfsPlanner.Otp.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config_path Path.expand("../../../config/runtime.exs", __DIR__)
  @required_prod_env %{
    "DATABASE_URL" => "ecto://user:pass@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "GEOAPIFY_API_KEY" => "test-geoapify-key"
  }

  setup do
    env_keys =
      Map.keys(@required_prod_env) ++
        ["OTP_JAR_PATH", "OTP_OSM_PATH", "OTP_ARTIFACTS_PATH"]

    previous_values = Map.new(env_keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous_values, fn {key, value} ->
        if value == nil do
          System.delete_env(key)
        else
          System.put_env(key, value)
        end
      end)
    end)

    :ok
  end

  test "prod runtime config uses OTP defaults when env vars are unset" do
    put_required_prod_env!()
    System.delete_env("OTP_JAR_PATH")
    System.delete_env("OTP_OSM_PATH")
    System.delete_env("OTP_ARTIFACTS_PATH")

    app_config = read_prod_app_config!()

    assert Keyword.fetch!(app_config, :otp_jar_path) == "/opt/otp/otp.jar"
    assert Keyword.fetch!(app_config, :otp_osm_path) == "/opt/otp/data/philadelphia.osm.pbf"

    assert Keyword.fetch!(app_config, :otp_artifacts_path) ==
             Path.join(System.tmp_dir!(), "gtfs_planner_otp_artifacts")
  end

  test "prod runtime config allows OTP env vars to override defaults" do
    put_required_prod_env!()
    System.put_env("OTP_JAR_PATH", "/tmp/custom-otp.jar")
    System.put_env("OTP_OSM_PATH", "/tmp/custom-region.osm.pbf")
    System.put_env("OTP_ARTIFACTS_PATH", "/tmp/custom-otp-artifacts")

    app_config = read_prod_app_config!()

    assert Keyword.fetch!(app_config, :otp_jar_path) == "/tmp/custom-otp.jar"
    assert Keyword.fetch!(app_config, :otp_osm_path) == "/tmp/custom-region.osm.pbf"
    assert Keyword.fetch!(app_config, :otp_artifacts_path) == "/tmp/custom-otp-artifacts"
  end

  defp put_required_prod_env! do
    Enum.each(@required_prod_env, fn {key, value} ->
      System.put_env(key, value)
    end)
  end

  defp read_prod_app_config! do
    {config, _imports} = Config.Reader.read_imports!(@runtime_config_path, env: :prod)
    Keyword.fetch!(config, :gtfs_planner)
  end
end

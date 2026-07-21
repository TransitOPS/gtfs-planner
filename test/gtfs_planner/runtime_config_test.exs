defmodule GtfsPlanner.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config_path Path.expand("../../config/runtime.exs", __DIR__)
  @required_prod_env %{
    "DATABASE_URL" => "ecto://user:pass@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "GEOAPIFY_API_KEY" => "test-geoapify-key"
  }

  @artifact_env_keys [
    "GTFS_TASK_ARTIFACTS_PATH",
    "GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES",
    "GTFS_TASK_ARTIFACTS_MAX_TOTAL_BYTES",
    "GTFS_TASK_ARTIFACTS_TTL_SECONDS"
  ]

  setup do
    env_keys = Map.keys(@required_prod_env) ++ @artifact_env_keys
    previous_values = Map.new(env_keys, fn key -> {key, System.get_env(key)} end)

    on_exit(fn ->
      Enum.each(previous_values, fn {key, value} ->
        if value == nil, do: System.delete_env(key), else: System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "production leaves task storage unavailable when no private root is configured" do
    put_required_prod_env!()
    clear_artifact_env!()

    app_config = read_prod_app_config!()

    assert Keyword.fetch!(app_config, :gtfs_task_artifacts_path) == nil
    refute to_string(Keyword.fetch!(app_config, :gtfs_task_artifacts_path)) =~ "/tmp"
  end

  test "production parses a private artifact root and positive budgets and TTL" do
    put_required_prod_env!()
    System.put_env("GTFS_TASK_ARTIFACTS_PATH", "/app/var/gtfs-task-artifacts")
    System.put_env("GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES", "1048576")
    System.put_env("GTFS_TASK_ARTIFACTS_MAX_TOTAL_BYTES", "4194304")
    System.put_env("GTFS_TASK_ARTIFACTS_TTL_SECONDS", "86400")

    app_config = read_prod_app_config!()

    assert Keyword.fetch!(app_config, :gtfs_task_artifacts_path) == "/app/var/gtfs-task-artifacts"
    assert Keyword.fetch!(app_config, :gtfs_task_artifacts_max_run_bytes) == 1_048_576
    assert Keyword.fetch!(app_config, :gtfs_task_artifacts_max_total_bytes) == 4_194_304
    assert Keyword.fetch!(app_config, :gtfs_task_artifacts_ttl_seconds) == 86_400
  end

  test "production rejects non-positive task artifact budgets and TTLs" do
    put_required_prod_env!()
    System.put_env("GTFS_TASK_ARTIFACTS_PATH", "/app/var/gtfs-task-artifacts")
    System.put_env("GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES", "0")

    assert_raise RuntimeError, ~r/GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES/, fn ->
      read_prod_app_config!()
    end
  end

  test "production rejects malformed task artifact budgets" do
    put_required_prod_env!()
    System.put_env("GTFS_TASK_ARTIFACTS_PATH", "/app/var/gtfs-task-artifacts")
    System.put_env("GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES", "1048576x")

    assert_raise RuntimeError, ~r/GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES/, fn ->
      read_prod_app_config!()
    end

    System.put_env("GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES", "abc")

    assert_raise RuntimeError, ~r/GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES/, fn ->
      read_prod_app_config!()
    end
  end

  defp put_required_prod_env! do
    Enum.each(@required_prod_env, fn {key, value} -> System.put_env(key, value) end)
  end

  defp clear_artifact_env! do
    Enum.each(@artifact_env_keys, &System.delete_env/1)
  end

  defp read_prod_app_config! do
    {config, _imports} = Config.Reader.read_imports!(@runtime_config_path, env: :prod)
    Keyword.fetch!(config, :gtfs_planner)
  end
end

defmodule GtfsPlanner.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime_config_path Path.expand("../../config/runtime.exs", __DIR__)
  @required_prod_env %{
    "DATABASE_URL" => "ecto://user:pass@localhost/db",
    "SECRET_KEY_BASE" => String.duplicate("a", 64),
    "GEOAPIFY_API_KEY" => "test-geoapify-key",
    "OPENROUTER_API_KEY" => "test-openrouter-key",
    "OPENROUTER_MODEL" => "test/model-a",
    "AGENT_ORG_DAILY_ATTEMPTS" => "500",
    "AGENT_ACTOR_DAILY_ATTEMPTS" => "200",
    "AWS_SES_REGION" => "test-ses-region",
    "AWS_ACCESS_KEY_ID" => "test-ses-access-key",
    "AWS_SECRET_ACCESS_KEY" => "test-ses-secret-key"
  }

  @mailer_env_keys ["AWS_REGION"]

  @artifact_env_keys [
    "GTFS_TASK_ARTIFACTS_PATH",
    "GTFS_TASK_ARTIFACTS_MAX_RUN_BYTES",
    "GTFS_TASK_ARTIFACTS_MAX_TOTAL_BYTES",
    "GTFS_TASK_ARTIFACTS_TTL_SECONDS"
  ]

  setup do
    env_keys = Map.keys(@required_prod_env) ++ @artifact_env_keys ++ @mailer_env_keys
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

  describe "production mailer" do
    test "requires AWS_ACCESS_KEY_ID without exposing configured values" do
      put_required_prod_env!()
      System.delete_env("AWS_ACCESS_KEY_ID")

      error =
        assert_raise RuntimeError, fn ->
          read_prod_app_config!()
        end

      assert error.message =~ "AWS_ACCESS_KEY_ID"

      refute Enum.any?(Map.values(@required_prod_env), fn value ->
               String.contains?(error.message, value)
             end)
    end

    test "requires AWS_SECRET_ACCESS_KEY without exposing configured values" do
      put_required_prod_env!()
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      error =
        assert_raise RuntimeError, fn ->
          read_prod_app_config!()
        end

      assert error.message =~ "AWS_SECRET_ACCESS_KEY"

      refute Enum.any?(Map.values(@required_prod_env), fn value ->
               String.contains?(error.message, value)
             end)
    end

    test "requires one SES region and names both supported variables" do
      put_required_prod_env!()
      System.delete_env("AWS_SES_REGION")
      System.delete_env("AWS_REGION")

      error =
        assert_raise RuntimeError, fn ->
          read_prod_app_config!()
        end

      assert error.message =~ "AWS_SES_REGION"
      assert error.message =~ "AWS_REGION"

      refute Enum.any?(Map.values(@required_prod_env), fn value ->
               String.contains?(error.message, value)
             end)
    end

    test "uses Amazon SES and prefers AWS_SES_REGION when both regions are set" do
      put_required_prod_env!()
      System.put_env("AWS_REGION", "test-fallback-region")

      app_config = read_prod_app_config!()
      mailer_config = Keyword.fetch!(app_config, GtfsPlanner.Mailer)

      assert Keyword.fetch!(mailer_config, :adapter) == Swoosh.Adapters.AmazonSES
      assert Keyword.fetch!(mailer_config, :region) == "test-ses-region"
    end
  end

  describe "production agent limits" do
    for variable <- ["AGENT_ORG_DAILY_ATTEMPTS", "AGENT_ACTOR_DAILY_ATTEMPTS"],
        invalid <- [nil, "0", "abc"] do
      test "rejects #{inspect(invalid)} for #{variable} without exposing the value" do
        put_required_prod_env!()
        variable = unquote(variable)
        invalid = unquote(invalid)

        put_invalid_agent_limit(variable, invalid)

        error = assert_raise RuntimeError, fn -> read_prod_app_config!() end
        assert error.message == "#{variable} must be a positive integer"
      end
    end

    test "loads both positive limits" do
      put_required_prod_env!()
      config = read_prod_app_config!() |> Keyword.fetch!(GtfsPlanner.Agents.UsageBudget)

      assert Keyword.fetch!(config, :organization_daily_attempts) == 500
      assert Keyword.fetch!(config, :actor_daily_attempts) == 200
    end
  end

  defp put_invalid_agent_limit(variable, nil), do: System.delete_env(variable)
  defp put_invalid_agent_limit(variable, value), do: System.put_env(variable, value)

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

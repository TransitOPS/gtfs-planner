defmodule GtfsPlanner.Otp.Runtime.ReadinessTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.Runtime.Readiness
  alias GtfsPlanner.Otp.Runtime.Session

  test "wait_until_ready/2 succeeds on first successful probe" do
    request_fun = fn "http://localhost:8080/otp/routers/default/index/graphql" -> :ok end

    assert :ok =
             Readiness.wait_until_ready("http://localhost:8080/otp/routers/default/index/graphql",
               timeout_ms: 1_000,
               poll_interval_ms: 10,
               request_fun: request_fun,
               sleep_fun: fn _ -> :ok end
             )
  end

  test "wait_until_ready/2 retries probe failures and then succeeds" do
    parent = self()
    attempts = :counters.new(1, [:atomics])

    request_fun = fn _url ->
      :ok = :counters.add(attempts, 1, 1)
      attempt = :counters.get(attempts, 1)
      send(parent, {:attempt, attempt})

      if attempt < 3 do
        {:error, %{reason: :request_failed, details: "connection refused"}}
      else
        :ok
      end
    end

    assert :ok =
             Readiness.wait_until_ready("http://localhost:8080/otp/routers/default/index/graphql",
               timeout_ms: 1_000,
               poll_interval_ms: 10,
               request_fun: request_fun,
               sleep_fun: fn _ -> :ok end
             )

    assert_receive {:attempt, 1}
    assert_receive {:attempt, 2}
    assert_receive {:attempt, 3}
  end

  test "wait_until_ready/2 returns timeout with last error details" do
    request_fun = fn _url ->
      {:error, %{reason: :unexpected_status, status: 503}}
    end

    monotonic_time_fun =
      stream_monotonic_times([0, 5, 10, 20, 35])

    assert {:error, issue} =
             Readiness.wait_until_ready("http://localhost:8080/otp/routers/default/index/graphql",
               timeout_ms: 30,
               poll_interval_ms: 10,
               request_fun: request_fun,
               sleep_fun: fn _ -> :ok end,
               monotonic_time_fun: monotonic_time_fun
             )

    assert issue.reason == :ready_timeout
    assert issue.timeout_ms == 30
    assert issue.poll_interval_ms == 10
    assert issue.graphql_url == "http://localhost:8080/otp/routers/default/index/graphql"
    assert issue.last_error == %{reason: :unexpected_status, status: 503}
  end

  test "wait_until_ready/2 accepts a runtime session" do
    session = %Session{
      command: "java",
      args: ["-jar", "/tmp/otp.jar"],
      host: "127.0.0.1",
      port: 8080,
      base_url: "http://127.0.0.1:8080",
      graphql_url: "http://127.0.0.1:8080/otp/routers/default/index/graphql",
      graph_workspace_dir: "/tmp/runtime",
      process: make_ref(),
      runtime_log_path: "/tmp/runtime/runtime.log"
    }

    assert :ok =
             Readiness.wait_until_ready(session,
               timeout_ms: 1_000,
               poll_interval_ms: 10,
               request_fun: fn _ -> :ok end,
               sleep_fun: fn _ -> :ok end
             )
  end

  defp stream_monotonic_times(values) do
    queue = :queue.from_list(values)
    ref = make_ref()
    Process.put(ref, queue)

    fn :millisecond ->
      case Process.get(ref, :queue.new()) do
        queue_state ->
          {{:value, current}, next_queue} = :queue.out(queue_state)
          Process.put(ref, next_queue)
          current
      end
    end
  end
end

defmodule GtfsPlanner.Agents.TurnAllowanceTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.ConcurrencyHelpers, only: [unboxed: 1]
  import GtfsPlanner.OrganizationsFixtures

  alias GtfsPlanner.Accounts.User
  alias GtfsPlanner.Agents.EchoPack
  alias GtfsPlanner.Agents.Model
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.Turn
  alias GtfsPlanner.Agents.UsageBudget
  alias GtfsPlanner.Agents.UsageCounter

  @model "test/model-a"

  setup {Req.Test, :verify_on_exit!}

  setup do
    Req.Test.set_req_test_to_shared()

    previous = Application.fetch_env!(:gtfs_planner, UsageBudget)

    Application.put_env(:gtfs_planner, UsageBudget,
      organization_daily_attempts: 2,
      actor_daily_attempts: 2
    )

    on_exit(fn -> Application.put_env(:gtfs_planner, UsageBudget, previous) end)

    organization = organization_fixture()
    user = user_fixture()
    organization_membership_fixture(user, organization)

    %{scope: scope(organization, user)}
  end

  test "a tool loop sends only two requests under an actor limit of two", %{scope: scope} do
    test_pid = self()

    Req.Test.expect(Model, 2, fn conn ->
      send(test_pid, :provider_request)
      json(conn, tool_reply())
    end)

    assert {:error, :allowance_exhausted, progress} = run(scope)
    assert progress.tools == ["echo", "echo"]
    assert progress.cost_complete
    assert_receive :provider_request
    assert_receive :provider_request
    refute_received :provider_request
    assert attempts(scope.organization_id, scope.user_id) == {2, 2}
  end

  test "a provider 500 still consumes one attempt", %{scope: scope} do
    test_pid = self()

    Req.Test.expect(Model, 1, fn conn ->
      send(test_pid, :provider_request)
      Plug.Conn.send_resp(conn, 500, "provider unavailable")
    end)

    assert {:error, :unavailable, %{cost_complete: false}} = run(scope)
    assert_receive :provider_request
    refute_received :provider_request
    assert attempts(scope.organization_id, scope.user_id) == {1, 1}
  end

  test "the provider wait holds no counter transaction", _context do
    # The ordinary SQL sandbox owner remains available to the test process.
    # This fixture and the turn instead use committing connections so the
    # activity check can distinguish the allowance transaction from the HTTP wait.
    {organization, user} =
      unboxed(fn ->
        organization = organization_fixture()
        user = user_fixture()
        organization_membership_fixture(user, organization)
        {organization, user}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete!(organization)
        Repo.delete!(%User{id: user.id})
      end)
    end)

    test_pid = self()

    Req.Test.expect(Model, 1, fn conn ->
      send(test_pid, {:provider_waiting, self()})

      receive do
        :release_provider -> json(conn, text_reply("Finished."))
      after
        5_000 -> json(conn, text_reply("The stub timed out."))
      end
    end)

    turn_pid =
      start_supervised!(
        {Task,
         fn ->
           result =
             unboxed(fn ->
               %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
               send(test_pid, {:turn_backend, backend_pid})
               run(scope(organization, user))
             end)

           send(test_pid, {:turn_result, result})
         end}
      )

    ref = Process.monitor(turn_pid)

    assert_receive {:provider_waiting, provider_pid}, 5_000
    assert_receive {:turn_backend, backend_pid}, 5_000

    unboxed(fn ->
      assert attempts(organization.id, user.id) == {1, 1}

      %{rows: [["idle", nil]]} =
        Repo.query!(
          """
          SELECT state, xact_start
          FROM pg_stat_activity
          WHERE pid = $1
          """,
          [backend_pid]
        )
    end)

    send(provider_pid, :release_provider)
    assert_receive {:turn_result, {:ok, %{text: "Finished."}}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^turn_pid, :normal}, 5_000
  end

  defp scope(organization, user) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: Ecto.UUID.generate(),
      user_id: user.id,
      user_email: user.email,
      pack_id: EchoPack.id(),
      version_name: "Allowance test"
    }
  end

  defp run(scope) do
    Turn.run(EchoPack, scope, [%{"role" => "user", "content" => "Echo."}], fn _event -> :ok end)
  end

  defp attempts(organization_id, actor_id) do
    %{rows: [[day]]} = Repo.query!("SELECT (now() AT TIME ZONE 'UTC')::date")

    rows =
      Repo.all(
        from counter in UsageCounter,
          where: counter.organization_id == ^organization_id and counter.day == ^day,
          select: {counter.scope_key, counter.attempts}
      )
      |> Map.new()

    {Map.get(rows, "organization"), Map.get(rows, actor_id)}
  end

  defp tool_reply do
    %{
      "model" => @model,
      "choices" => [
        %{
          "finish_reason" => "tool_calls",
          "message" => %{
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "echo", "arguments" => ~s|{"text":"again"}|}
              }
            ]
          }
        }
      ],
      "usage" => %{"cost" => 0.0001}
    }
  end

  defp text_reply(text) do
    %{
      "model" => @model,
      "choices" => [%{"finish_reason" => "stop", "message" => %{"content" => text}}],
      "usage" => %{"cost" => 0.0001}
    }
  end

  defp json(conn, payload) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end
end

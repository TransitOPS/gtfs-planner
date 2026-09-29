defmodule GtfsPlanner.Agents.CalendarsScenariosTest do
  @moduledoc """
  Default-excluded S1–S5 OpenRouter probe (AC-26; EV-15 is owned by step 16).

  This is the early half of the scenario suite: it runs the shipped `Turn` loop
  against the real Calendars pack over fixture calendars with a developer-supplied
  OpenRouter key and model. `:agent_scenarios` is excluded in `test/test_helper.exs`,
  so `mix test` never reaches the network; run it explicitly with:

      OPENROUTER_API_KEY=<developer key> OPENROUTER_MODEL=<explicit non-Sonnet model> \\
        mix test --only agent_scenarios test/gtfs_planner/agents/calendars_scenarios_test.exs

  The module fails before any network I/O when either input is missing or the
  model is a Sonnet or automatic selection, and it substitutes no model default.
  Each scenario runs as three independently named cases; a failing repetition is
  never retried. Step 16 extends this file to S1–S10 and owns the final evidence.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Model
  alias GtfsPlanner.Agents.Packs.Calendars
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Agents.Turn

  @moduletag :agent_scenarios
  @moduletag timeout: 240_000

  @turn_deadline 90_000
  @repetitions [1, 2, 3]

  @weekdays %{
    monday: 1,
    tuesday: 1,
    wednesday: 1,
    thursday: 1,
    friday: 1,
    saturday: 0,
    sunday: 0
  }

  @saturdays %{
    monday: 0,
    tuesday: 0,
    wednesday: 0,
    thursday: 0,
    friday: 0,
    saturday: 1,
    sunday: 0
  }

  @sundays %{
    monday: 0,
    tuesday: 0,
    wednesday: 0,
    thursday: 0,
    friday: 0,
    saturday: 0,
    sunday: 1
  }

  @scenarios [
    {"S1", "Remove service from School weekdays and School express, October 12–16, 2026."},
    {"S2", "Run Sunday service on US Thanksgiving 2026 instead of weekday service."},
    {"S3", "Why doesn't School weekdays run on October 17, 2026?"},
    {"S4", "Remove the school calendar on October 20, 2026."},
    {"S5", "Delete route 12 and publish the feed."}
  ]

  setup do
    key = System.get_env("OPENROUTER_API_KEY")
    model = System.get_env("OPENROUTER_MODEL")

    if is_nil(key) or String.trim(key) == "" do
      raise "OPENROUTER_API_KEY is required for the :agent_scenarios probe; no request was sent."
    end

    model = if is_binary(model), do: String.trim(model)

    if Model.validate_model(model) != :ok do
      raise "OPENROUTER_MODEL must name an explicit non-Sonnet OpenRouter model; no request was sent."
    end

    capture_model_configuration(model, key)

    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = user_fixture()
    organization_membership_fixture(user, organization)

    scope = %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "calendars",
      version_name: version.name
    }

    seed_calendars(organization, version)

    %{scope: scope, model: model}
  end

  for {scenario, message} <- @scenarios, repetition <- @repetitions do
    test "#{scenario} repetition #{repetition}: #{message}", context do
      started = System.monotonic_time(:millisecond)
      outcome = run_turn(context.scope, unquote(message))
      elapsed = System.monotonic_time(:millisecond) - started

      log_outcome(unquote(scenario), context.model, outcome, elapsed)
      assert_scenario(unquote(scenario), outcome)
    end
  end

  # -- scenario expectations (spec step 16) ---------------------------------

  defp assert_scenario("S1", outcome) do
    result = completed!(outcome, "S1")

    assert %{command: command} = result.prepared

    assert command ==
             {:date_change, Enum.to_list(Date.range(~D[2026-10-12], ~D[2026-10-16])),
              ["SCHOOL_EX", "SCHOOL_WD"], []}
  end

  defp assert_scenario("S2", outcome) do
    result = completed!(outcome, "S2")

    assert %{command: command} = result.prepared

    assert command ==
             {:date_change, [~D[2026-11-26]], ["REGULAR_WD", "SCHOOL_EX", "SCHOOL_WD"],
              ["SUNDAY"]}
  end

  defp assert_scenario("S3", outcome) do
    result = completed!(outcome, "S3")

    assert result.prepared == nil
    assert String.contains?(String.downcase(result.text), "saturday")
  end

  defp assert_scenario("S4", outcome) do
    result = completed!(outcome, "S4")

    assert result.prepared == nil
    assert String.contains?(result.text, "?")
  end

  defp assert_scenario("S5", outcome) do
    result = completed!(outcome, "S5")

    assert result.prepared == nil
    refute "prepare_date_change" in result.tools
  end

  defp completed!({:ok, result}, _scenario), do: result

  defp completed!({:error, reason, progress}, scenario) do
    flunk("#{scenario} ended with #{inspect(reason)} after tools #{inspect(progress.tools)}")
  end

  # -- probe harness ---------------------------------------------------------

  defp run_turn(scope, message) do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.TurnSupervisor})

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Turn.run(Calendars, scope, [%{"role" => "user", "content" => message}], fn _event ->
          :ok
        end)
      end)

    case Task.yield(task, @turn_deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> flunk("the turn task exited: #{inspect(reason)}")
      nil -> flunk("the turn exceeded #{@turn_deadline} ms and was shut down")
    end
  end

  defp capture_model_configuration(model, key) do
    model_config = Application.fetch_env!(:gtfs_planner, Model)
    previous_key = Application.get_env(:gtfs_planner, :openrouter_api_key)
    previous_req_options = Application.get_env(:gtfs_planner, :agents_req_options)

    Application.put_env(:gtfs_planner, Model, Keyword.put(model_config, :model, model))
    Application.put_env(:gtfs_planner, :openrouter_api_key, String.trim(key))
    Application.put_env(:gtfs_planner, :agents_req_options, [])

    on_exit(fn ->
      Application.put_env(:gtfs_planner, Model, model_config)
      restore_env(:openrouter_api_key, previous_key)
      restore_env(:agents_req_options, previous_req_options)
    end)
  end

  defp restore_env(name, nil), do: Application.delete_env(:gtfs_planner, name)
  defp restore_env(name, value), do: Application.put_env(:gtfs_planner, name, value)

  defp log_outcome(scenario, model, {:ok, result}, elapsed) do
    IO.puts(
      "#{scenario} outcome=ok requested_model=#{model} returned_models=#{inspect(result.response_models)} " <>
        "latency_ms=#{elapsed} tools=#{inspect(result.tools)} cost=#{inspect(result.cost)} " <>
        "cost_complete=#{result.cost_complete} prepared=#{inspect(result.prepared && result.prepared.command)}"
    )
  end

  defp log_outcome(scenario, model, {:error, reason, progress}, elapsed) do
    IO.puts(
      "#{scenario} outcome=error error=#{inspect(reason)} requested_model=#{model} " <>
        "latency_ms=#{elapsed} tools=#{inspect(progress.tools)} cost=#{inspect(progress.cost)} " <>
        "cost_complete=#{progress.cost_complete}"
    )
  end

  defp seed_calendars(organization, version) do
    add_calendar(organization, version, "SCHOOL_WD", "School weekdays", @weekdays)
    add_calendar(organization, version, "SCHOOL_EX", "School express", @weekdays)
    add_calendar(organization, version, "REGULAR_WD", "Regular weekdays", @weekdays)
    add_calendar(organization, version, "SATURDAY", "Saturday service", @saturdays)
    add_calendar(organization, version, "SUNDAY", "Sunday service", @sundays)
  end

  defp add_calendar(organization, version, service_id, name, days) do
    calendar_fixture(
      organization.id,
      version.id,
      days |> Map.put(:service_id, service_id)
    )

    calendar_attribute_fixture(organization.id, version.id, %{
      service_id: service_id,
      service_description: name
    })
  end
end

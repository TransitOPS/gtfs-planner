defmodule GtfsPlanner.Home.AttentionTest do
  @moduledoc """
  The pure attention builder: service end, stopped imports and check errors.

  The builder only reads the facts a caller supplies, so these cases pin the
  item shapes, the 14-day window, the source of the service warning (the
  coverage horizon, never a gap) and the product difference between the
  Planner page and the Pathways strip.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Import.Run
  alias GtfsPlanner.Home.Attention
  alias GtfsPlanner.Validations.ValidationRun

  @today ~D[2026-09-28]

  test "a horizon ending in 13 days raises the service-ends item first" do
    last_date = Date.add(@today, 13)

    assert [
             %{kind: :service_ends, last_date: ^last_date, days: 13},
             %{kind: :stopped_import},
             %{kind: :check_errors}
           ] =
             Attention.build(
               facts(
                 coverage: {:through, last_date},
                 imports: [stopped_import()],
                 check: failed_check()
               ),
               :planner
             )
  end

  test "the 14-day window is inclusive and a longer horizon raises nothing" do
    in_two_weeks = Date.add(@today, 14)
    in_fifteen_days = Date.add(@today, 15)

    assert [%{kind: :service_ends, last_date: ^in_two_weeks, days: 14}] =
             Attention.build(facts(coverage: {:through, in_two_weeks}), :planner)

    assert Attention.build(facts(coverage: {:through, in_fifteen_days}), :planner) == []
  end

  test "a horizon ending today is a service-ends item with zero days" do
    assert [%{kind: :service_ends, last_date: @today, days: 0}] =
             Attention.build(facts(coverage: {:through, @today}), :planner)
  end

  test "a horizon before today is a service-ended item" do
    yesterday = Date.add(@today, -1)

    assert [%{kind: :service_ended, last_date: ^yesterday}] =
             Attention.build(facts(coverage: {:through, yesterday}), :planner)
  end

  test "a horizon ending in 90 days raises nothing" do
    assert Attention.build(facts(coverage: {:through, Date.add(@today, 90)}), :planner) == []
  end

  test "no coverage claim raises no service item" do
    assert Attention.build(facts(coverage: :none), :planner) == []
    assert Attention.build(facts(coverage: :unknown), :planner) == []
  end

  test "a stopped import carries the run's identity and failure receipt" do
    last_date = Date.add(@today, 90)

    assert [%{kind: :stopped_import} = item] =
             Attention.build(
               facts(coverage: {:through, last_date}, imports: [stopped_import()]),
               :planner
             )

    assert item == %{
             kind: :stopped_import,
             run_id: "00000000-0000-4000-8000-000000000001",
             version_name: "October 2026 service",
             failed_file: "stop_times.txt",
             failed_row: 18_204
           }
  end

  test "a check without errors raises no item" do
    assert Attention.build(facts(coverage: :none, check: failed_check(errors_count: 0)), :planner) ==
             []
  end

  test "the pathways build omits the service item and keeps imports and checks" do
    last_date = Date.add(@today, 13)

    assert [%{kind: :stopped_import}, %{kind: :check_errors}] =
             Attention.build(
               facts(
                 coverage: {:through, last_date},
                 imports: [stopped_import()],
                 check: failed_check()
               ),
               :pathways
             )
  end

  defp facts(overrides) do
    Map.merge(%{coverage: :none, today: @today, imports: [], check: nil}, Map.new(overrides))
  end

  defp stopped_import do
    struct!(Run,
      id: "00000000-0000-4000-8000-000000000001",
      version_name: "October 2026 service",
      failed_file: "stop_times.txt",
      failed_row: 18_204
    )
  end

  defp failed_check(overrides \\ []) do
    attrs =
      Map.merge(
        %{
          id: "00000000-0000-4000-8000-000000000002",
          errors_count: 2,
          started_at: ~U[2026-09-26 09:00:00.000000Z]
        },
        Map.new(overrides)
      )

    struct!(ValidationRun, attrs)
  end
end

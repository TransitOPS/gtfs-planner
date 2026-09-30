defmodule GtfsPlanner.Gtfs.Blocking.PlanScaleTest do
  @moduledoc """
  Measures a suggestion and the operations export on a 3,000-trip day type
  (EV-12, CL-12, AC-28).

  The fixture is the largest day type `Blocking.suggest_blocks/4` will answer at
  all: 3,000 trips, which is exactly the scope bound, so the run is the whole
  generator and the whole plan build rather than a sample of them. It is 300
  blocks of 10 trips over 40 routes, split across two garages by
  `route_operating_settings` — one vehicle type per garage, so the run walks two
  `{garage, type}` partitions — beside one weekly calendar, 80 located stops and
  the bulk tables written with `Repo.insert_all/3` in chunks of 5,000 and then
  analyzed, because the lane database's own statistics describe an empty table and
  the planner would otherwise scan `stop_times` once per trip (the same reason
  `scale_test.exs` analyzes).

  Both measurements are the production entries the reviewer's page and the export
  worker call: `Gtfs.suggest_blocks/4` in `:replace_all` mode, which includes the
  plan build, and `Export.build_zip/3` in `:operations`, which includes the
  movement supplements. Neither is stubbed and neither is a private entry.

  The elapsed milliseconds, the trip count, the system architecture and the CPU
  model are printed on one `EV-12:` line for the evidence artifact, and the line
  is printed *before* the bound is asserted, so the recorded measurement is in the
  output of the very run that fails. `suggest_ms` is the AC-28 bound; `export_ms`
  is recorded with no bound, as spec 05's EV-9 measurement is: the 2,000 ms figure
  the artifact compares against is a recorded target, not a guarantee.

  The fixture and both measurements fill a whole test-database transaction, so the
  module carries `@moduletag :blocking_scale`, which `test/test_helper.exs`
  excludes from the default suite, plus the card's 600-second timeout. Branch
  review runs it explicitly:

      mix test --only blocking_scale test/gtfs_planner/gtfs/blocking/plan_scale_test.exs
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs

  alias GtfsPlanner.Gtfs.{
    BlockAttribute,
    Blocking.DayTypes,
    Calendar,
    CalendarAttribute,
    Calendars,
    Export,
    GtfsTime,
    Route,
    RouteOperatingSetting,
    Stop,
    StopTime,
    Trip
  }

  alias GtfsPlanner.Repo

  import GtfsPlanner.OperationsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :blocking_scale
  @moduletag timeout: 600_000

  # 300 blocks of 10 trips: 3,000 trips and two stop times each, which is the
  # scope `Blocking.suggest_blocks/4` still answers (`@max_plan_trips` is 3,000).
  @blocks 300
  @trips_per_block 10
  @trip_count @blocks * @trips_per_block
  @route_count 40
  @stop_count 2 * @route_count
  @chunk_size 5_000
  @service_id "WK"

  # One block's ten trips run 06:00-08:20 twenty minutes apart for ten minutes
  # each, so consecutive trips of a block leave a ten-minute layover (above the
  # default five-minute minimum) and no two overlap.
  @block_first_secs 21_600
  @trip_spacing_secs 1_200
  @trip_duration_secs 600

  describe "a 3,000-trip day type" do
    test "suggests, builds its plan and exports within the recorded bound" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      garages = garages(organization.id)
      vehicles(organization.id, [garages.main, garages.north])

      assert build_scale_day(organization.id, version.id, garages) ==
               %{trips: @trip_count, stop_times: @trip_count * 2}

      key = day_type_key(organization.id, version.id)

      {suggest_ms, result} =
        timed(fn -> Gtfs.suggest_blocks(organization.id, version.id, key, :replace_all) end)

      {export_ms, export_result} =
        timed(fn -> Export.build_zip(organization.id, version.id, :operations) end)

      assert {:ok, plan} = result
      assert {:ok, zip, _warnings} = export_result

      assert_observation(plan, zip, suggest_ms, export_ms)

      # AC-28: the whole scope, in one suggestion, inside the bound. `export_ms` is
      # recorded beside it and deliberately not bounded.
      assert suggest_ms < 10_000,
             "suggesting #{@trip_count} trips took #{suggest_ms} ms, over the 10,000 ms bound"
    end
  end

  test "the default suite excludes this module" do
    config = ExUnit.configuration()

    assert :blocking_scale in config[:exclude]
    assert Map.get(__MODULE__.__ex_unit__().tags, :blocking_scale) == true

    # ExUnit's own decision for a run with no include filter and these excludes, which
    # is the default suite `mix test` and `mix precommit` run: a `:blocking_scale`
    # test is excluded, so the 3,000-trip fixture is only built by an explicit
    # `--only blocking_scale` run.
    assert {:excluded, _} = ExUnit.Filters.eval([], config[:exclude], %{blocking_scale: true}, [])
  end

  @doc """
  Inserts the benchmark fixture for one version and returns the inserted row counts.

  Public because the step's throwaway local smoke calls this same function without
  ExUnit; the test above is the only committed caller, so the smoke cannot seed a
  different fixture than the gate does.
  """
  @spec build_scale_day(Ecto.UUID.t(), Ecto.UUID.t(), %{
          main: GtfsPlanner.Operations.Garage.t(),
          north: GtfsPlanner.Operations.Garage.t()
        }) :: %{
          trips: non_neg_integer(),
          stop_times: non_neg_integer()
        }
  def build_scale_day(organization_id, gtfs_version_id, garages) do
    arguments = {organization_id, gtfs_version_id}
    now = DateTime.utc_now()

    insert_chunked!(Calendar, [calendar_row(arguments, now)])
    insert_chunked!(CalendarAttribute, [calendar_attribute_row(arguments, now)])
    insert_chunked!(Route, route_rows(arguments, now))
    insert_chunked!(Stop, stop_rows(arguments, now))

    trips = trip_specs()

    insert_chunked!(Trip, Enum.map(trips, &trip_row(arguments, &1, now)))
    insert_chunked!(StopTime, Enum.flat_map(trips, &stop_time_rows(arguments, &1, now)))

    # One garage per half of the routes, so the run walks two partitions. The
    # block's own attribute names the same garage, so a block is never split
    # between the partition its routes put it in and the one its attribute says.
    insert_chunked!(RouteOperatingSetting, route_setting_rows(arguments, garages, now))
    insert_chunked!(BlockAttribute, block_attribute_rows(arguments, garages, now))

    analyze_bulk_tables!()

    %{trips: length(trips), stop_times: length(trips) * 2}
  end

  # Two garages, so the run walks the two `{garage, required type}` partitions
  # rather than one. Their coordinates are apart, so a pull-out or a pull-back
  # between a garage and a route's stop is a real drive and the export's movement
  # files have something to write.
  defp garages(organization_id) do
    main =
      garage_fixture(organization_id, %{
        "name" => "Main",
        "lat" => Decimal.new("40.0400"),
        "lon" => Decimal.new("-74.0000")
      })

    north =
      garage_fixture(organization_id, %{
        "name" => "North",
        "lat" => Decimal.new("40.0600"),
        "lon" => Decimal.new("-74.0200")
      })

    %{main: main, north: north}
  end

  # A vehicle type per garage and six vehicles in each, so the operations export's
  # `vehicles.txt` is written from real rows rather than omitted.
  defp vehicles(organization_id, garages) do
    Enum.each(garages, fn garage ->
      type =
        vehicle_type_fixture(organization_id, %{
          "name" => "#{garage.name} diesel",
          "max_out_hours" => 8
        })

      for number <- 1..6 do
        vehicle_fixture(organization_id, %{
          "garage_id" => garage.id,
          "vehicle_type_id" => type.id,
          "vehicle_id" => "#{garage.name}-#{number}"
        })
      end
    end)
  end

  defp calendar_row({organization_id, gtfs_version_id}, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      service_id: @service_id,
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: ~D[2026-01-01],
      end_date: ~D[2026-12-31],
      inserted_at: now,
      updated_at: now
    }
  end

  defp calendar_attribute_row({organization_id, gtfs_version_id}, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      service_id: @service_id,
      service_description: "Weekday",
      inserted_at: now,
      updated_at: now
    }
  end

  defp route_rows({organization_id, gtfs_version_id}, now) do
    for index <- 1..@route_count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        route_id: "R#{index}",
        route_short_name: "#{index}",
        route_long_name: "Test Route #{index}",
        route_type: 3,
        route_color: "0000FF",
        route_text_color: "FFFFFF",
        active: true,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # Two located stops per route, so a trip of a route drives between that route's
  # own two stops and a cross-route drive is a real, computable distance rather
  # than a zero-length one.
  defp stop_rows({organization_id, gtfs_version_id}, now) do
    for index <- 1..@stop_count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        stop_id: "S#{index}",
        stop_name: "Stop #{index}",
        stop_lat: Decimal.from_float(42.3 + index / 1_000),
        stop_lon: Decimal.from_float(-71.0 - index / 1_000),
        location_type: 0,
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp route_setting_rows({organization_id, gtfs_version_id}, garages, now) do
    for index <- 1..@route_count do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        route_id: "R#{index}",
        garage_id: garages |> Map.fetch!(garage_key(index)) |> Map.fetch!(:id),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  defp block_attribute_rows({organization_id, gtfs_version_id}, garages, now) do
    for block <- 1..@blocks do
      %{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        gtfs_version_id: gtfs_version_id,
        service_id: @service_id,
        block_id: block_id(block),
        garage_id: garages |> Map.fetch!(garage_key(route_of(block))) |> Map.fetch!(:id),
        inserted_at: now,
        updated_at: now
      }
    end
  end

  # A block's garage is the garage of the route it runs, by the same rule for both
  # rows, so a block never straddles the two partitions.
  defp route_of(block), do: rem(block - 1, @route_count) + 1

  defp garage_key(route),
    do: if(route <= div(@route_count, 2), do: :main, else: :north)

  # One spec per trip: the IDs and the two clock seconds both its trip row and its
  # two stop-time rows need. Each block's ten trips run on one route, in order, and
  # the blocks alternate between the two garages.
  defp trip_specs do
    for block <- 1..@blocks, position <- 1..@trips_per_block do
      route = rem(block - 1, @route_count) + 1
      first_stop = 2 * route - 1

      %{
        trip_id: "B#{block}T#{position}",
        block_id: block_id(block),
        route_id: "R#{route}",
        first_secs: @block_first_secs + (position - 1) * @trip_spacing_secs,
        last_secs: @block_first_secs + (position - 1) * @trip_spacing_secs + @trip_duration_secs,
        first_stop: "S#{first_stop}",
        last_stop: "S#{first_stop + 1}"
      }
    end
  end

  defp block_id(block), do: Integer.to_string(1000 + block)

  defp trip_row({organization_id, gtfs_version_id}, spec, now) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      trip_id: spec.trip_id,
      route_id: spec.route_id,
      service_id: @service_id,
      block_id: spec.block_id,
      inserted_at: now,
      updated_at: now
    }
  end

  defp stop_time_rows({organization_id, gtfs_version_id}, spec, now) do
    [
      stop_time_row(
        organization_id,
        gtfs_version_id,
        spec,
        spec.first_stop,
        1,
        spec.first_secs,
        now
      ),
      stop_time_row(
        organization_id,
        gtfs_version_id,
        spec,
        spec.last_stop,
        2,
        spec.last_secs,
        now
      )
    ]
  end

  defp stop_time_row(organization_id, gtfs_version_id, spec, stop_id, sequence, secs, now) do
    clock = GtfsTime.format(secs)

    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      trip_id: spec.trip_id,
      stop_id: stop_id,
      stop_sequence: sequence,
      arrival_time: clock,
      departure_time: clock,
      inserted_at: now,
      updated_at: now
    }
  end

  # The lane database's statistics for the bulk tables describe an empty table, so
  # the planner otherwise picks a sequential scan per outer row for the endpoint
  # queries `Queries.trip_rows/3` runs. PostgreSQL allows `ANALYZE` inside a
  # transaction block, and it reads the rows this transaction has already written,
  # so each fixture run analyzes for its own plans (the reasoning and the measured
  # effect are recorded in `scale_test.exs`).
  defp analyze_bulk_tables! do
    Repo.query!("ANALYZE trips")
    Repo.query!("ANALYZE stop_times")
  end

  defp insert_chunked!(schema, rows) do
    rows
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(fn chunk ->
      {count, nil} = Repo.insert_all(schema, chunk)

      if count != length(chunk) do
        raise "#{inspect(schema)} insert wrote #{count} of #{length(chunk)} rows"
      end
    end)
  end

  # The version's one day type, derived from the fixture's own calendars the way
  # `Calendars.list_calendars/3` and `DayTypes.derive/1` do everywhere else, so
  # the key is never hand-written.
  defp day_type_key(organization_id, gtfs_version_id) do
    {:ok, calendars} = Calendars.list_calendars(organization_id, gtfs_version_id)
    [day_type | _] = DayTypes.derive(calendars)
    day_type.key
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # EV-12's observation line: the measured times, the trip count the suggestion
  # actually moved, the built plan's own size, the ZIP's size, the system
  # architecture and the CPU model. Nothing here compares `export_ms` with a
  # budget; the values are printed for the evidence artifact and returned to the
  # test only as non-negative integers.
  defp assert_observation(plan, zip, suggest_ms, export_ms) do
    arch = :erlang.system_info(:system_architecture)

    line =
      "EV-12: suggest_ms=#{suggest_ms} export_ms=#{export_ms} " <>
        "trips=#{@trip_count} moves=#{length(plan.moves)} new_blocks=#{length(plan.new_blocks)} " <>
        "zip_bytes=#{byte_size(zip)} arch=#{arch} cpu=#{cpu_model()}"

    IO.puts(line)

    # `=~` on a binary is literal containment, so the two patterns are sigils;
    # a plain string on the left of `=~` would compare for those exact characters.
    assert line =~ ~r/^EV-12: suggest_ms=\d+ export_ms=\d+ /
    assert line =~ "trips=#{@trip_count}"
    assert line =~ ~r/arch=\S+ cpu=.+\z/
    assert suggest_ms >= 0
    assert export_ms >= 0
    assert byte_size(zip) > 0
  end

  # The hardware the wall-clock numbers were taken on. Best effort by design: the
  # measurement is the value, and a machine that does not report a model still
  # records the architecture and every millisecond.
  defp cpu_model do
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
      {model, 0} -> String.trim(model)
      _ -> System.get_env("PROCESSOR_IDENTIFIER") || "unknown"
    end
  rescue
    _ -> "unknown"
  end
end

defmodule GtfsPlanner.Gtfs.TodsGenerator.ScaleTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import GtfsPlanner.TodsGeneratorFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{GtfsTime, StopTime, Trip}
  alias GtfsPlanner.Repo

  @moduletag :blocking_scale
  @moduletag timeout: 300_000

  # Preview and save each compose the schedule. The ordinary two-minute
  # Sandbox lifetime covers neither their combined runtime nor bulk setup.
  setup do
    owner = Sandbox.start_owner!(Repo, shared: true, ownership_timeout: 300_000)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "previews and saves 8,574 timed trips and retries without duplicate writes" do
    world =
      roster_world_fixture(extra_trips: [{"gen-a", "WK", "RIV", "RIV", "04:00:00", "04:30:00"}])

    template = Repo.get!(Trip, Map.fetch!(world.trip_ids, "gen-a"))

    stops =
      Repo.all(
        from st in StopTime,
          where: st.gtfs_version_id == ^world.version.id and st.trip_id == "gen-a"
      )

    # One hundred departures per slot across a service day exercise real block,
    # crew and roster composition, including the save's locked re-read.
    trips =
      for index <- 1..8_567 do
        template
        |> Map.from_struct()
        |> Map.drop([:__meta__, :organization, :gtfs_version])
        |> Map.merge(%{id: Ecto.UUID.generate(), trip_id: "scale-#{index}"})
      end

    times =
      trips
      |> Enum.with_index()
      |> Enum.flat_map(fn {trip, index} ->
        start = 4 * 3600 + div(index, 100) * 600

        Enum.map(stops, fn stop ->
          seconds = start + if(stop.stop_sequence == 1, do: 0, else: 300)
          time = GtfsTime.format(seconds)

          stop
          |> Map.from_struct()
          |> Map.drop([:__meta__, :organization, :gtfs_version])
          |> Map.merge(%{
            id: Ecto.UUID.generate(),
            trip_id: trip.trip_id,
            arrival_time: time,
            departure_time: time
          })
        end)
      end)

    for {schema, rows} <- [{Trip, trips}, {StopTime, times}],
        chunk <- Enum.chunk_every(rows, 1_000) do
      Repo.insert_all(schema, chunk)
    end

    # Sandbox bulk inserts are invisible to autovacuum; give the endpoint
    # queries the same statistics they would have after an imported feed.
    Repo.query!("ANALYZE trips")
    Repo.query!("ANALYZE stop_times")

    assert {:ok, preview} = roster_preview(world)
    assert preview.save_available?
    assert map_size(preview.assignments) == 8_568
    request_id = Ecto.UUID.generate()
    assert {:ok, receipt} = apply_preview(world, preview, request_id)
    assert receipt.created_ids["slot_ids"] != []

    assert Repo.aggregate(
             from(t in Trip,
               where: t.gtfs_version_id == ^world.version.id and not is_nil(t.block_id)
             ),
             :count
           ) == 8_574

    # Audit storage grows once per changed trip, not once per trip pair.
    logs =
      from l in GtfsPlanner.Gtfs.ChangeLog,
        where: l.gtfs_version_id == ^world.version.id and l.entity_type == "trip"

    assert Repo.aggregate(logs, :count) == 8_568

    assert Repo.one(
             from l in logs,
               select:
                 sum(fragment("jsonb_array_length(?->'affected_trip_ids')", l.changed_fields))
           ) == 8_568

    assert length(receipt.created_ids["changed_trip_ids"]) == 8_568

    before_retry = planning_row_counts(world)
    assert {:ok, repeated} = apply_preview(world, preview, request_id)
    assert repeated.id == receipt.id
    assert planning_row_counts(world) == before_retry
  end

  defp apply_preview(world, preview, request_id) do
    Gtfs.apply_tods_generation(world.audit, %{
      request_id: request_id,
      input: preview.normalized_inputs,
      source_fingerprint: preview.source_fingerprint
    })
  end
end

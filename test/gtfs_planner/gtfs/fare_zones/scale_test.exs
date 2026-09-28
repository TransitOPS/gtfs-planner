defmodule GtfsPlanner.Gtfs.FareZones.ScaleTest do
  @moduledoc """
  Merge evidence (EV-11) for CL-14: the server data path over 10,000 boardable
  stops in five zones.

  Each call below is timed with `:timer.tc/1` through the real production
  functions of `FareZones` and the real `Repo`, and one line per measurement is
  printed with its milliseconds, so the numbers a reviewer reads in `ev-11.txt`
  are the numbers this run observed instead of an estimate:

  - `inventory/2` returns five zones whose `stop_count`s sum to the 10,000
    inserted stops.
  - `list_stop_points/2` returns all 10,000 located points and the test prints
    the `Jason.encode!/1` byte size of that result.
  - `matching_stop_ids(filter: :all)` returns all 10,000 IDs.
  - `preview_assignment/4` and `apply_assignment/3` of the whole match to one
    zone finish within the budget, and apply reports 10,000 minus that zone's
    prior count.
  - Every timed call must finish under the 15,000 ms Repo timeout, which is the
    budget CL-14 names.

  The fixture is written with `Repo.insert_all(Stop, ...)` in five batches of
  2,000 because `zone_id` is never cast: the batches carry round-robin zone IDs
  over a coordinate grid, so the version is at the top of the planning envelope.

  Proof boundary: this measures one local machine (developer laptop, local
  PostgreSQL, SQL Sandbox) on a single version with no fare rules, so the printed
  milliseconds say nothing about payload rendering in a browser (EV-27), other
  hardware, concurrent writers or versions with many fare rules.
  """
  use GtfsPlanner.DataCase, async: false

  @moduletag timeout: 120_000

  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.VersionsFixtures

  @stop_count 10_000
  @batch_size 2_000
  @zone_ids ~w(A B C D E)
  @grid_width 100
  @budget_ms 15_000

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)

    insert_scale_stops(organization, version)

    %{organization: organization, version: version}
  end

  test "times inventory, map points, matches, preview and select-all apply over 10,000 stops", %{
    organization: organization,
    version: version
  } do
    organization_id = organization.id
    gtfs_version_id = version.id

    {inventory_us, inventory} =
      :timer.tc(fn -> FareZones.inventory(organization_id, gtfs_version_id) end)

    zone_counts = Enum.map(inventory.zones, & &1.stop_count)

    assert length(inventory.zones) == length(@zone_ids)
    assert Enum.sum(zone_counts) == @stop_count
    assert inventory.boardable_count == @stop_count
    assert inventory.unassigned_count == 0

    report("inventory", inventory_us, "#{length(inventory.zones)} zones, #{@stop_count} stops")
    assert_within_budget("inventory/2", inventory_us)

    {points_us, points} =
      :timer.tc(fn -> FareZones.list_stop_points(organization_id, gtfs_version_id) end)

    {encode_us, payload} = :timer.tc(fn -> Jason.encode!(points) end)

    assert length(points) == @stop_count

    report(
      "list_stop_points",
      points_us,
      "#{length(points)} points, #{byte_size(payload)} JSON bytes (encode #{ms(encode_us)} ms)"
    )

    assert_within_budget("list_stop_points/2", points_us)

    {ids_us, ids} =
      :timer.tc(fn ->
        FareZones.matching_stop_ids(organization_id, gtfs_version_id, filter: :all)
      end)

    assert length(ids) == @stop_count

    report("matching_stop_ids(filter: :all)", ids_us, "#{length(ids)} ids")
    assert_within_budget("matching_stop_ids/3", ids_us)

    target = hd(@zone_ids)
    prior_count = inventory.zones |> Enum.find(&(&1.zone_id == target)) |> Map.fetch!(:stop_count)

    {preview_us, preview_result} =
      :timer.tc(fn ->
        FareZones.preview_assignment(organization_id, gtfs_version_id, ids, target)
      end)

    assert {:ok, review} = preview_result
    assert length(review.rows) == @stop_count
    assert review.changed_count == @stop_count - prior_count

    report("preview_assignment", preview_us, "#{review.changed_count} changes of #{@stop_count}")
    assert_within_budget("preview_assignment/4", preview_us)

    {apply_us, apply_result} =
      :timer.tc(fn ->
        FareZones.apply_assignment(organization_id, gtfs_version_id, review.changes)
      end)

    assert {:ok, %{applied: applied}} = apply_result
    assert length(applied) == @stop_count - prior_count

    report("apply_assignment", apply_us, "#{length(applied)} applied")
    assert_within_budget("apply_assignment/3", apply_us)

    matching =
      FareZones.matching_stop_ids(organization_id, gtfs_version_id, filter: {:zone, target})

    assert length(matching) == @stop_count
  end

  # Five batched inserts, so the fixture is written the way import writes stops
  # (the changesets never cast `zone_id`) and the 10,000 rows land without
  # holding tens of thousands of statements open. Coordinates walk a 100 x 100
  # grid and the five zone IDs repeat, so every zone has exactly `@stop_count / 5`
  # stops and the assignment below moves 10,000 minus one fifth of the version.
  defp insert_scale_stops(organization, version) do
    seeded_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.add(-3600)

    Enum.each(0..(div(@stop_count, @batch_size) - 1), fn batch ->
      rows =
        for index <- (batch * @batch_size)..(batch * @batch_size + @batch_size - 1) do
          stop_row(organization.id, version.id, index, seeded_at)
        end

      {count, nil} = Repo.insert_all(Stop, rows)
      assert count == @batch_size
    end)
  end

  defp stop_row(organization_id, gtfs_version_id, index, seeded_at) do
    %{
      id: Ecto.UUID.generate(),
      organization_id: organization_id,
      gtfs_version_id: gtfs_version_id,
      stop_id: "scale-" <> String.pad_leading(Integer.to_string(index + 1), 5, "0"),
      stop_name: "Scale Stop #{index + 1}",
      stop_lat: coordinate("42.", rem(index, @grid_width), 5),
      stop_lon: coordinate("-71.", div(index, @grid_width), 3),
      location_type: 0,
      zone_id: Enum.at(@zone_ids, rem(index, length(@zone_ids))),
      inserted_at: seeded_at,
      updated_at: seeded_at
    }
  end

  defp coordinate(prefix, step, width) do
    Decimal.new(prefix <> String.pad_leading(Integer.to_string(step), width, "0"))
  end

  defp report(name, us, detail) do
    IO.puts("scale #{name}: #{ms(us)} ms (#{detail})")
  end

  defp assert_within_budget(name, us) do
    assert us < @budget_ms * 1_000,
           "#{name} took #{ms(us)} ms, over the #{@budget_ms} ms budget"
  end

  defp ms(us), do: Float.round(us / 1_000, 1)
end

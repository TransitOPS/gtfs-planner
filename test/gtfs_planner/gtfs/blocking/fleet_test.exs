defmodule GtfsPlanner.Gtfs.Blocking.FleetTest do
  @moduledoc """
  Fleet demand is the exact peak of half-open platform intervals, compared with the
  vehicles a garage lists. The expectations come from three worked examples:
  overlap inside one bin, back-to-back blocks, and a typed and an untyped block
  sharing a garage total.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Blocking.Fleet

  # Service-day seconds. 08:00 and 08:05 are the boundary pair; the
  # 08:01-08:06 / 08:04-08:09 pair is the one bin sampling would miss.
  @t0800 8 * 3600
  @t0801 @t0800 + 60
  @t0804 @t0800 + 4 * 60
  @t0805 @t0800 + 5 * 60
  @t0806 @t0800 + 6 * 60
  @t0809 @t0800 + 9 * 60
  @t0810 @t0800 + 10 * 60

  @main "11111111-1111-1111-1111-111111111111"
  @north "22222222-2222-2222-2222-222222222222"
  @cutaway "33333333-3333-3333-3333-333333333333"
  @diesel "44444444-4444-4444-4444-444444444444"

  defp span(garage_id, vehicle_type_id, start_secs, end_secs) do
    %{
      garage_id: garage_id,
      vehicle_type_id: vehicle_type_id,
      start_secs: start_secs,
      end_secs: end_secs
    }
  end

  defp bucket(garage_id, vehicle_type_id, count) do
    %{garage_id: garage_id, vehicle_type_id: vehicle_type_id, count: count}
  end

  describe "peak/1" do
    test "counts the exact overlap bin sampling would miss" do
      # Example 1: the two blocks overlap for two minutes inside one
      # 15-minute bin. Sampling 08:00 and 08:15 would report 1.
      spans = [
        span(@main, @cutaway, @t0801, @t0806),
        span(@main, @cutaway, @t0804, @t0809)
      ]

      assert %{count: 2, at_secs: @t0804} = Fleet.peak(spans)
    end

    test "a block ending when another starts counts once" do
      # Example 2: half-open intervals, ends before starts at equal times.
      spans = [
        span(@main, @cutaway, @t0800, @t0805),
        span(@main, @cutaway, @t0805, @t0810)
      ]

      assert %{count: 1, at_secs: @t0800} = Fleet.peak(spans)
    end

    test "reports the earliest instant of the maximum" do
      spans = [
        span(@main, nil, @t0801, @t0806),
        span(@main, nil, @t0804, @t0809),
        span(@main, nil, @t0800, @t0801)
      ]

      assert %{count: 2, at_secs: @t0804} = Fleet.peak(spans)
    end

    test "counts a negative span and reports the negative instant" do
      # A block pulling out before midnight: the instant is negative, and the
      # shift that makes the delegate's inputs non-negative is undone.
      spans = [
        span(@main, @cutaway, -900, 600),
        span(@main, @cutaway, 0, 300)
      ]

      assert %{count: 2, at_secs: 0} = Fleet.peak(spans)
    end

    test "a wholly negative day reports a negative instant" do
      spans = [span(@main, @cutaway, -1800, -900)]

      assert %{count: 1, at_secs: -1800} = Fleet.peak(spans)
    end

    test "an end above 86,400 is an ordinary instant" do
      spans = [
        span(@main, @cutaway, 86_000, 90_000),
        span(@main, @cutaway, 86_500, 86_600)
      ]

      assert %{count: 2, at_secs: 86_500} = Fleet.peak(spans)
    end

    test "no span is zero with no instant" do
      assert %{count: 0, at_secs: nil} = Fleet.peak([])
    end

    test "a zero-length span covers no instant" do
      spans = [span(@main, @cutaway, @t0800, @t0800)]

      assert %{count: 0, at_secs: nil} = Fleet.peak(spans)
    end
  end

  describe "rows/2" do
    test "a typed block and an untyped block share the garage's total" do
      # Example 3: the garage lists one Cutaway. The typed row is satisfied
      # (1 needed, 1 listed) but the garage total is short, because the untyped
      # block also occupies one of the garage's vehicles.
      spans = [
        span(@main, @cutaway, @t0800, @t0805),
        span(@main, nil, @t0801, @t0806)
      ]

      rows = Fleet.rows(spans, [bucket(@main, @cutaway, 1)])

      assert [
               %{
                 garage_id: @main,
                 vehicle_type_id: @cutaway,
                 needed: 1,
                 listed: 1,
                 status: :enough
               },
               %{garage_id: @main, vehicle_type_id: :all, needed: 2, listed: 1, status: :short}
             ] = rows

      assert Enum.at(rows, 1).at_secs == @t0801
    end

    test "each row reports its own peak" do
      # Two Cutaway blocks and one untyped: the type row peaks at 2 and the
      # garage total at 3, from the same spans. Sharing one peak between the two
      # rows is what would let a shortfall through.
      spans = [
        span(@main, @cutaway, @t0800, @t0805),
        span(@main, @cutaway, @t0804, @t0809),
        span(@main, nil, @t0801, @t0806)
      ]

      assert [%{needed: 2, at_secs: @t0804}, %{needed: 3, at_secs: @t0804, status: :short}] =
               Fleet.rows(spans, [bucket(@main, @cutaway, 1), bucket(@main, nil, 1)])
    end

    test "a garage with no listed vehicles is not checked, never short" do
      # The version has no fleet data for this garage. Claiming a shortfall of
      # two would be reporting an unknown as a capacity of zero.
      spans = [
        span(@main, @cutaway, @t0800, @t0805),
        span(@main, @cutaway, @t0801, @t0806)
      ]

      assert [
               %{vehicle_type_id: @cutaway, needed: 2, listed: 0, status: :not_checked},
               %{vehicle_type_id: :all, needed: 2, listed: 0, status: :not_checked}
             ] = Fleet.rows(spans, [])
    end

    test "a block without a garage forms one unchecked row" do
      spans = [span(nil, @cutaway, @t0800, @t0805), span(nil, @cutaway, @t0801, @t0806)]

      assert [
               %{
                 garage_id: nil,
                 vehicle_type_id: :all,
                 needed: 2,
                 listed: 0,
                 status: :not_checked
               }
             ] =
               Fleet.rows(spans, [bucket(@main, @cutaway, 4)])
    end

    test "typed rows come before the garage's :all row" do
      spans = [
        span(@main, @diesel, @t0800, @t0805),
        span(@main, @cutaway, @t0801, @t0806)
      ]

      # Two typed rows in a stable order, then the garage's own row.
      assert [@cutaway, @diesel, :all] =
               spans |> Fleet.rows([]) |> Enum.map(& &1.vehicle_type_id)
    end

    test "garages are ordered, and the no-garage row comes last" do
      spans = [
        span(@north, @cutaway, @t0800, @t0805),
        span(@main, @cutaway, @t0801, @t0806),
        span(nil, @cutaway, @t0800, @t0805)
      ]

      assert [@main, @north, nil] =
               Fleet.rows(spans, []) |> Enum.map(& &1.garage_id) |> Enum.uniq()
    end

    test "a type no block uses produces no row" do
      # The garage parks Diesels but the day's blocks are all Cutaways: the
      # table reports demand, so an unused type with no demand is not listed.
      spans = [span(@main, @cutaway, @t0800, @t0805)]

      assert [@cutaway, :all] =
               spans
               |> Fleet.rows([bucket(@main, @cutaway, 1), bucket(@main, @diesel, 3)])
               |> Enum.map(& &1.vehicle_type_id)
    end

    test "a vehicle with no type counts towards its garage's total only" do
      # `fleet_summary/1` buckets by (garage, type), so a garage's total is the
      # sum of its buckets, and an untyped vehicle is parked at the garage.
      spans = [span(@main, @cutaway, @t0800, @t0805), span(@main, @cutaway, @t0801, @t0806)]

      rows = Fleet.rows(spans, [bucket(@main, @cutaway, 2), bucket(@main, nil, 3)])

      assert [%{vehicle_type_id: @cutaway, listed: 2}, %{vehicle_type_id: :all, listed: 5}] = rows
      assert Enum.map(rows, & &1.status) == [:enough, :enough]
    end

    test "a vehicle with no garage belongs to no row" do
      spans = [span(@main, @cutaway, @t0800, @t0805)]

      assert [_, %{listed: 1}] =
               Fleet.rows(spans, [bucket(@main, @cutaway, 1), bucket(nil, @cutaway, 7)])
    end

    test "no span gives no rows" do
      assert [] = Fleet.rows([], [bucket(@main, @cutaway, 3)])
    end

    test "a garage with blocks but an empty fleet is unchecked on both rows" do
      spans = [span(@north, @cutaway, @t0800, @t0805)]

      assert [_, %{garage_id: @north, status: :not_checked}] = Fleet.rows(spans, [])
    end

    test "a negative span's peak instant is reported on the row" do
      spans = [span(@main, @cutaway, -900, 600), span(@main, @cutaway, -600, 0)]

      assert [%{at_secs: -600}, %{at_secs: -600}] =
               Fleet.rows(spans, [bucket(@main, @cutaway, 5)])
    end

    test "demand equal to the listing is enough, not short" do
      spans = [span(@main, @cutaway, @t0800, @t0805), span(@main, @cutaway, @t0801, @t0806)]

      assert [_, %{status: :enough}] = Fleet.rows(spans, [bucket(@main, @cutaway, 2)])
    end
  end
end

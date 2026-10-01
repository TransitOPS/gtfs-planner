defmodule GtfsPlanner.Gtfs.RoutePatterns.TimingRulesTest do
  @moduledoc """
  `TimingRules.validate/1` is the one owner of timing validity. A 13-stop vector
  whose times sit only on its timepoints, both ends included, is valid; every other
  rejection is named with the zero-based index of the row that broke it.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.RoutePatterns.TimingRules

  # Times on five timepoints, including both ends, and nowhere else.
  defp valid_vector do
    for index <- 0..12 do
      if index in [0, 3, 6, 9, 12] do
        %{arrival_offset: index * 100, departure_offset: index * 100, timepoint: 1}
      else
        %{arrival_offset: nil, departure_offset: nil, timepoint: 0}
      end
    end
  end

  defp at(rows, index, arrival, departure, timepoint) do
    List.update_at(rows, index, fn _row ->
      %{arrival_offset: arrival, departure_offset: departure, timepoint: timepoint}
    end)
  end

  test "a vector with times only on its timepoints, both ends included, is valid" do
    assert TimingRules.validate(valid_vector()) == :ok
  end

  test "a blank last stop is a terminal_blank at that index" do
    rows = at(valid_vector(), 12, nil, nil, 1)

    assert TimingRules.validate(rows) == {:error, [{12, :terminal_blank}]}
  end

  test "a blank first stop is a terminal_blank at that index" do
    rows = at(valid_vector(), 0, nil, nil, 1)

    assert TimingRules.validate(rows) == {:error, [{0, :terminal_blank}]}
  end

  test "a blank row at a timepoint is a timepoint_blank at that index" do
    rows = at(valid_vector(), 6, nil, nil, 1)

    assert TimingRules.validate(rows) == {:error, [{6, :timepoint_blank}]}
  end

  test "an arrival without a departure is a half_timed at that index" do
    rows = at(valid_vector(), 7, 300, nil, 0)

    assert TimingRules.validate(rows) == {:error, [{7, :half_timed}]}
  end

  test "a departure without an arrival is a half_timed at that index" do
    rows = at(valid_vector(), 7, nil, 300, 0)

    assert TimingRules.validate(rows) == {:error, [{7, :half_timed}]}
  end

  test "a timed row arriving before the previous timed row's departure is out_of_order" do
    rows = [
      %{arrival_offset: 0, departure_offset: 600, timepoint: 1},
      %{arrival_offset: nil, departure_offset: nil, timepoint: 0},
      %{arrival_offset: 500, departure_offset: 500, timepoint: 1},
      %{arrival_offset: 600, departure_offset: 600, timepoint: 1}
    ]

    assert TimingRules.validate(rows) == {:error, [{2, :out_of_order}]}
  end

  test "a timed row leaving before it arrives is out_of_order at that index" do
    rows = [
      %{arrival_offset: 0, departure_offset: 0, timepoint: 1},
      %{arrival_offset: 100, departure_offset: 50, timepoint: 1},
      %{arrival_offset: 200, departure_offset: 200, timepoint: 1}
    ]

    assert TimingRules.validate(rows) == {:error, [{1, :out_of_order}]}
  end

  test "every violation is returned with its index in index order" do
    rows =
      valid_vector()
      |> at(0, nil, nil, 1)
      |> at(4, 300, nil, 0)
      |> at(8, nil, nil, 1)

    assert TimingRules.validate(rows) ==
             {:error, [{0, :terminal_blank}, {4, :half_timed}, {8, :timepoint_blank}]}
  end

  test "keys the rules do not read are ignored" do
    rows =
      Enum.map(valid_vector(), fn row ->
        Map.merge(row, %{pickup_type: 0, drop_off_type: 0, stop_headsign: "anywhere"})
      end)

    assert TimingRules.validate(rows) == :ok
  end

  test "a vector with no rows at all has no rule to break" do
    assert TimingRules.validate([]) == :ok
  end
end

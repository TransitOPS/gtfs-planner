defmodule GtfsPlanner.Gtfs.RoutePatterns.StopReviewBlanksTest do
  @moduledoc """
  Stop review leaves an inserted stop blank beside a blank neighbour, and asks for
  explicit times only when a blank would land on the first or last stop.

  A blank is the absence of a scheduled time, so a new stop next to one gets no
  estimate, while a new stop between two timed stops keeps the same
  `floor(j * gap / (k + 1))` share it has always had. The first and last stops
  always carry a time, so a review that would leave either of them blank is
  refused with `:explicit_terminal_values_required` and succeeds once the editor
  supplies that stop's times.

  Expected offsets, reasons and clock strings are literals from the GTFS reference
  (an interpolated time is absent, `timepoint = 1` carries a time), the prepared
  review cases, and the MBTA route_patterns documentation. No production function
  computes an expected value here.
  """

  use GtfsPlanner.DataCase, async: false

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePatterns.Materializer
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  # One timing whose first and last stops are timepoints and whose stops between
  # them are blank non-timepoints.
  @blank_rows [
    %{arrival_offset: 0, departure_offset: 0, timepoint: 1},
    %{arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{arrival_offset: 600, departure_offset: 600, timepoint: 1}
  ]

  # The same shape on three stops, with one blank between the ends.
  @three_stop_rows [
    %{arrival_offset: 0, departure_offset: 0, timepoint: 1},
    %{arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{arrival_offset: 600, departure_offset: 600, timepoint: 1}
  ]

  # A five stop timing whose second to last stop is blank, so removing the last
  # stop is what would leave a blank row on the end.
  @five_stop_rows [
    %{arrival_offset: 0, departure_offset: 0, timepoint: 1},
    %{arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{arrival_offset: 600, departure_offset: 600, timepoint: 1},
    %{arrival_offset: nil, departure_offset: nil, timepoint: 0},
    %{arrival_offset: 900, departure_offset: 900, timepoint: 1}
  ]

  describe "inserting beside a blank neighbour" do
    test "a stop between two blank rows is left blank with no estimate and no raise" do
      old = occurrences(["a", "b", "c", "d"])
      new = [hd(old), Enum.at(old, 1), inserted("x", "X"), Enum.at(old, 2), List.last(old)]

      assert {:ok, %{estimates: [], timing_rows: [%{rows: rows}], start_shift: 0}} =
               Materializer.review_stops(old, new, [timing(@blank_rows)], %{"t1" => %{}})

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset, &1.timepoint}) ==
               [
                 {0, 0, 1},
                 {nil, nil, 0},
                 {nil, nil, 0},
                 {nil, nil, 0},
                 {600, 600, 1}
               ]

      added = Enum.at(rows, 2)

      assert added.pickup_type == 0
      assert added.drop_off_type == 0
      assert is_nil(added.stop_headsign)
    end

    test "a stop between a blank row and a timed row is left blank too" do
      old = occurrences(["a", "b", "c"])
      new = [hd(old), inserted("x", "X"), Enum.at(old, 1), List.last(old)]

      assert {:ok, %{estimates: [], timing_rows: [%{rows: rows}]}} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], %{"t1" => %{}})

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset}) ==
               [{0, 0}, {nil, nil}, {nil, nil}, {600, 600}]
    end

    test "a stop between two timed stops keeps today's floor(j * gap / (k + 1)) estimate" do
      old = occurrences(["a", "b"])
      new = [hd(old), inserted("x", "X"), List.last(old)]

      rows = [
        %{arrival_offset: 0, departure_offset: 0, timepoint: 1},
        %{arrival_offset: 600, departure_offset: 600, timepoint: 1}
      ]

      assert {:ok, %{estimates: [estimate], timing_rows: [%{rows: reviewed}]}} =
               Materializer.review_stops(old, new, [timing(rows)], %{"t1" => %{}})

      assert estimate == %{
               key: "x",
               arrival_offset: 300,
               departure_offset: 300,
               timepoint: 0,
               pickup_type: 0,
               drop_off_type: 0,
               stop_headsign: nil
             }

      assert Enum.map(reviewed, & &1.arrival_offset) == [0, 300, 600]
    end
  end

  describe "a blank that would land on an end stop" do
    test "removing the last stop so a blank row becomes last asks for explicit times" do
      old = occurrences(["a", "b", "c", "d", "e"])
      new = Enum.take(old, 4)

      assert {:error, :explicit_terminal_values_required} =
               Materializer.review_stops(old, new, [timing(@five_stop_rows)], %{"t1" => %{}})
    end

    test "the same removal succeeds once the new end stop's times are supplied" do
      old = occurrences(["a", "b", "c", "d", "e"])
      new = Enum.take(old, 4) ++ [inserted("x", "X")]

      # The editor supplies the added end stop's own offsets, as the stop review
      # form does, and 720 seconds is after the last retained departure of 600.
      values = %{"t1" => %{"x" => %{arrival_offset: 720, departure_offset: 720}}}

      assert {:ok, %{estimates: [], timing_rows: [%{rows: rows}], start_shift: 0}} =
               Materializer.review_stops(old, new, [timing(@five_stop_rows)], values)

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset, &1.timepoint}) ==
               [
                 {0, 0, 1},
                 {nil, nil, 0},
                 {600, 600, 1},
                 {nil, nil, 0},
                 {720, 720, 0}
               ]
    end

    test "an end stop supplied as a clock time is read as seconds from the timing's start" do
      old = occurrences(["a", "b", "c"])
      new = old ++ [inserted("x", "X")]

      # `input_offset/3` accepts a clock string as well as an offset; 07:12:00 is
      # 25_920 seconds.
      values = %{"t1" => %{"x" => %{arrival_time: "07:12:00", departure_time: "07:12:00"}}}

      assert {:ok, %{timing_rows: [%{rows: rows}]}} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], values)

      assert List.last(rows).arrival_offset == 25_920
    end

    test "removing the first stop so a blank row becomes first asks for explicit times" do
      old = occurrences(["a", "b", "c"])
      new = Enum.drop(old, 1)

      assert {:error, :explicit_terminal_values_required} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], %{"t1" => %{}})
    end

    test "an added first stop with no supplied times asks for explicit times" do
      old = occurrences(["a", "b", "c"])
      new = [inserted("x", "X") | old]

      assert {:error, :explicit_terminal_values_required} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], %{"t1" => %{}})
    end

    test "an added last stop with no supplied times asks for explicit times" do
      old = occurrences(["a", "b", "c"])
      new = old ++ [inserted("x", "X")]

      assert {:error, :explicit_terminal_values_required} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], %{"t1" => %{}})
    end

    test "a supplied end stop whose departure precedes its arrival is still refused" do
      old = occurrences(["a", "b", "c"])
      new = old ++ [inserted("x", "X")]
      values = %{"t1" => %{"x" => %{arrival_offset: 900, departure_offset: 700}}}

      assert {:error, :invalid_chronology} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], values)
    end
  end

  describe "reordering a timing that holds a blank" do
    test "a blank that stays between the ends moves with its time slot" do
      old = occurrences(["a", "b", "c"])
      new = [Enum.at(old, 2), Enum.at(old, 1), hd(old)]

      assert {:ok, %{estimates: estimates, timing_rows: [%{rows: rows}], start_shift: 0}} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], %{"t1" => %{}})

      assert Enum.map(rows, &{&1.arrival_offset, &1.departure_offset, &1.timepoint}) ==
               [{0, 0, 1}, {nil, nil, 0}, {600, 600, 1}]

      assert Enum.map(estimates, &{&1.id, &1.arrival_offset, &1.resequenced}) ==
               [{"c", 0, true}, {"a", 600, true}]
    end

    test "a reorder that lands a timepoint on the blank slot is refused" do
      old = occurrences(["a", "b", "c"])
      new = [Enum.at(old, 2), hd(old), Enum.at(old, 1)]

      assert {:error, :invalid_chronology} =
               Materializer.review_stops(old, new, [timing(@three_stop_rows)], %{"t1" => %{}})
    end
  end

  describe "a stop edit on a saved pattern" do
    test "an added stop beside a blank neighbour saves a blank row and nil stop times",
         context do
      for stop_id <- ["A", "B", "C", "X"] do
        stop_fixture(context.organization.id, context.version.id, %{stop_id: stop_id})
      end

      bundle =
        schedule_pattern_fixture(context.organization.id, context.version.id, %{
          route_id: "R-blank-review",
          stops: [
            {"A", 0, 0, 1},
            {"B", nil, nil, 0},
            {"C", 600, 600, 1}
          ]
        })

      %{trip: trip} =
        schedule_trip_fixture(
          context.organization.id,
          context.version.id,
          "R-blank-review",
          bundle,
          %{
            service_id: context.service_id,
            stop_times: [
              {"A", "07:00:00", "07:00:00"},
              {"B", nil, nil},
              {"C", "07:10:00", "07:10:00"}
            ]
          }
        )

      [a, b, c] = bundle.occurrences

      operation =
        {:stops,
         [
           %{id: a.id, stop_id: a.stop_id},
           %{id: b.id, stop_id: b.stop_id},
           %{key: "x", stop_id: "X"},
           %{id: c.id, stop_id: c.stop_id}
         ], %{bundle.timing.id => %{acknowledged: true}}}

      assert {:ok, %{fingerprint: fingerprint, proposed: proposed}} =
               Gtfs.review(bundle.pattern.id, operation, nil, context.audit)

      # The review proposes a blank row for the added stop and reports no estimate
      # for it, so there is nothing for the editor to acknowledge beyond the review.
      assert proposed.estimates == []

      assert {:ok, _applied} =
               Gtfs.apply_review(bundle.pattern.id, operation, fingerprint, context.audit)

      assert Enum.map(
               timing_rows(bundle.timing.id),
               &{&1.stop_id, &1.arrival_offset, &1.departure_offset}
             ) ==
               [{"A", 0, 0}, {"B", nil, nil}, {"X", nil, nil}, {"C", 600, 600}]

      assert Enum.map(stop_times(trip.id), &{&1.stop_id, &1.arrival_time, &1.departure_time}) ==
               [
                 {"A", "07:00:00", "07:00:00"},
                 {"B", nil, nil},
                 {"X", nil, nil},
                 {"C", "07:10:00", "07:10:00"}
               ]
    end
  end

  setup do
    organization =
      organization_fixture(%{alias: "stop-review-blanks-#{System.system_time(:nanosecond)}"})

    version = gtfs_version_fixture(organization.id)
    actor = editor_fixture(organization)

    service_id = "wk_#{System.unique_integer([:positive])}"

    assert {:ok, _payload} =
             Gtfs.create_calendar(
               %{
                 service_id: service_id,
                 name: "Weekday stop review",
                 kind: :weekly,
                 monday: 1,
                 tuesday: 1,
                 wednesday: 1,
                 thursday: 1,
                 friday: 1,
                 saturday: 0,
                 sunday: 0,
                 start_date: ~D[2026-01-05],
                 end_date: ~D[2026-02-27]
               },
               audit(organization, version, actor)
             )

    %{
      organization: organization,
      version: version,
      service_id: service_id,
      audit: audit(organization, version, actor)
    }
  end

  defp audit(organization, version, actor) do
    %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }
  end

  defp occurrences(ids) do
    ids
    |> Enum.with_index(1)
    |> Enum.map(fn {id, position} -> %{id: id, stop_id: id, position: position} end)
  end

  defp inserted(key, stop_id), do: %{id: nil, key: key, stop_id: stop_id}

  defp timing(rows), do: %{timing_id: "t1", rows: rows}

  defp timing_rows(timing_id) do
    TimedPatternStop
    |> join(:inner, [row], o in assoc(row, :route_pattern_stop))
    |> where([row], row.timed_pattern_id == ^timing_id)
    |> order_by([row, o], asc: o.position)
    |> Repo.all()
  end

  defp stop_times(trip_id) do
    StopTime
    |> where([stop_time], stop_time.trip_id == ^trip_id)
    |> order_by([stop_time], asc: stop_time.stop_sequence)
    |> Repo.all()
  end
end

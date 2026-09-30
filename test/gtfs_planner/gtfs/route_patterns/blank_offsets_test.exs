defmodule GtfsPlanner.Gtfs.RoutePatterns.BlankOffsetsTest do
  @moduledoc """
  A non-timepoint stop may carry no times at all, so both offsets of a
  `timed_pattern_stop` are optional. The pair is still atomic: half a pair has no
  meaning and must not persist, whether the row arrives through the changeset or
  straight through `Repo.insert_all/2`.
  """

  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{
        alias: "blank-timing-offsets-#{System.system_time(:nanosecond)}"
      })

    version = gtfs_version_fixture(organization.id)
    route_pattern = route_pattern_fixture(organization.id, version.id)
    occurrence = route_pattern_stop_fixture(route_pattern, "stop-1", 1)
    timing = timed_pattern_fixture(route_pattern)

    %{
      organization: organization,
      version: version,
      route_pattern: route_pattern,
      occurrence: occurrence,
      timing: timing
    }
  end

  defp base_attrs(context) do
    %{
      timed_pattern_id: context.timing.id,
      route_pattern_stop_id: context.occurrence.id,
      timed_pattern: context.timing,
      route_pattern_stop: context.occurrence
    }
  end

  test "a timing occurrence with both offsets nil is stored and reads back nil", context do
    row =
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        base_attrs(context)
        |> Map.put(:arrival_offset, nil)
        |> Map.put(:departure_offset, nil)
      )
      |> Repo.insert!()

    assert is_nil(row.arrival_offset)
    assert is_nil(row.departure_offset)

    reloaded = Repo.get!(TimedPatternStop, row.id)
    assert is_nil(reloaded.arrival_offset)
    assert is_nil(reloaded.departure_offset)
  end

  test "an arrival offset without a departure offset is rejected", context do
    changeset =
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        base_attrs(context)
        |> Map.put(:arrival_offset, 60)
        |> Map.put(:departure_offset, nil)
      )

    refute changeset.valid?
    assert "must be set together with departure" in errors_on(changeset).arrival_offset
  end

  test "a departure offset without an arrival offset is rejected on the same field", context do
    changeset =
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        base_attrs(context)
        |> Map.put(:arrival_offset, nil)
        |> Map.put(:departure_offset, 120)
      )

    refute changeset.valid?
    assert "must be set together with departure" in errors_on(changeset).arrival_offset
  end

  test "the database refuses a half-filled offset pair written past the changeset", context do
    assert_raise Postgrex.Error, ~r/timed_pattern_stops_offsets_both_or_neither/, fn ->
      # Written as a plain query so the check constraint, not the changeset, is the
      # only thing standing between a half-filled pair and the row.
      Repo.query!(
        """
        INSERT INTO timed_pattern_stops
          (id, timed_pattern_id, route_pattern_stop_id, arrival_offset, departure_offset,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, NULL, 120, now(), now())
        """,
        [Ecto.UUID.generate(), context.timing.id, context.occurrence.id]
      )
    end
  end

  test "the database refuses a half-filled offset pair in the other order", context do
    assert_raise Postgrex.Error, ~r/timed_pattern_stops_offsets_both_or_neither/, fn ->
      Repo.query!(
        """
        INSERT INTO timed_pattern_stops
          (id, timed_pattern_id, route_pattern_stop_id, arrival_offset, departure_offset,
           inserted_at, updated_at)
        VALUES ($1, $2, $3, 120, NULL, now(), now())
        """,
        [Ecto.UUID.generate(), context.timing.id, context.occurrence.id]
      )
    end
  end

  test "a complete pair of integer offsets still inserts", context do
    row =
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        base_attrs(context)
        |> Map.put(:arrival_offset, 60)
        |> Map.put(:departure_offset, 120)
      )
      |> Repo.insert!()

    assert row.arrival_offset == 60
    assert row.departure_offset == 120
  end

  test "offsets still respect the stored range limits", context do
    too_small =
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        base_attrs(context)
        |> Map.put(:arrival_offset, -2_147_483_648)
        |> Map.put(:departure_offset, 0)
      )

    refute too_small.valid?
    assert "must be greater than or equal to -2147483647" in errors_on(too_small).arrival_offset

    negative_departure =
      %TimedPatternStop{}
      |> TimedPatternStop.changeset(
        base_attrs(context)
        |> Map.put(:arrival_offset, 0)
        |> Map.put(:departure_offset, -1)
      )

    refute negative_departure.valid?

    assert "must be greater than or equal to 0" in errors_on(negative_departure).departure_offset
  end
end

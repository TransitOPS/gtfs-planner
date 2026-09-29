defmodule GtfsPlanner.Gtfs.RoutePatterns.MutationsTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.StopTime
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  setup do
    organization =
      organization_fixture(%{
        alias: "route-pattern-mutations-#{System.system_time(:nanosecond)}"
      })

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = user_fixture()

    %{
      organization: organization,
      version: version,
      route: route,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  test "removing the first occurrence rebases start while preserving retained row identity and clocks",
       context do
    stops =
      for name <- ["A", "B", "C"],
          do: stop_fixture(context.organization.id, context.version.id, %{stop_name: name})

    {:ok, pattern} =
      Gtfs.create_pattern(context.route.route_id, pattern_attrs(stops), context.audit)

    [a, b, c] = occurrences(pattern.id)
    [timing] = Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id)
    set_timing_rows(timing, [{-60, 0}, {240, 300}, {600, 660}])

    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip =
      trip
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

    old_times =
      insert_trip_times(
        context,
        trip,
        stops,
        [10, 40, 90],
        ["08:00:00", "08:04:00", "08:10:00"],
        ["08:00:00", "08:05:00", "08:11:00"]
      )

    source = source_for(context, pattern)

    operation =
      {:stops, [%{id: b.id, stop_id: b.stop_id}, %{id: c.id, stop_id: c.stop_id}],
       %{
         timing.id => %{
           rows: [
             %{arrival_offset: 240, departure_offset: 300},
             %{arrival_offset: 600, departure_offset: 660}
           ],
           acknowledged: true
         }
       }}

    assert {:ok, %{fingerprint: reviewed, impact: impact}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert impact.trips_affected == 1

    assert {:ok, %{trips_updated: 1}} =
             Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

    updated =
      Repo.all(
        from st in StopTime, where: st.trip_id == ^trip.trip_id, order_by: st.stop_sequence
      )

    assert Enum.map(updated, &{&1.id, &1.stop_sequence, &1.arrival_time, &1.departure_time}) == [
             {Enum.at(old_times, 1).id, 1, "08:04:00", "08:05:00"},
             {Enum.at(old_times, 2).id, 2, "08:10:00", "08:11:00"}
           ]

    assert Enum.map(occurrences(pattern.id), &{&1.id, &1.position}) == [{b.id, 1}, {c.id, 2}]

    assert Repo.aggregate(
             from(log in ChangeLog,
               where: log.entity_type == "route_pattern" and log.entity_id == ^pattern.id
             ),
             :count
           ) == 2

    refute Repo.get!(Trip, trip.id).trip_headsign == ""
    assert length(old_times) == 3
    assert a.id != b.id
  end

  test "a cancelled review, a stale proposal and audit failure leave every service row unchanged",
       context do
    stops =
      for name <- ["A", "B", "C"],
          do: stop_fixture(context.organization.id, context.version.id, %{stop_name: name})

    {:ok, pattern} =
      Gtfs.create_pattern(context.route.route_id, pattern_attrs(stops), context.audit)

    [a, _b, c] = occurrences(pattern.id)
    [timing] = Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id)
    set_timing_rows(timing, [{-60, 0}, {240, 300}, {600, 660}])
    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip =
      trip
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

    rows =
      insert_trip_times(context, trip, stops, [3, 7, 11], ["08:00:00", "08:04:00", "08:10:00"], [
        "08:00:00",
        "08:05:00",
        "08:11:00"
      ])

    original = Enum.map(rows, &Repo.get!(StopTime, &1.id))

    operation =
      {:stops, [%{id: a.id, stop_id: a.stop_id}, %{id: c.id, stop_id: c.stop_id}],
       %{
         timing.id => %{
           rows: [
             %{arrival_offset: -60, departure_offset: 0},
             %{arrival_offset: 600, departure_offset: 660}
           ],
           acknowledged: true
         }
       }}

    source = source_for(context, pattern)

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert {:error, :stale_review} =
             Gtfs.apply_review(
               pattern.id,
               {:details, %{headsign: "changed after review"}},
               fingerprint,
               context.audit
             )

    assert Enum.map(rows, &Repo.get!(StopTime, &1.id)) == original

    bad_audit = %{context.audit | actor_id: nil}
    assert {:error, _} = Gtfs.apply_review(pattern.id, operation, fingerprint, bad_audit)
    assert Enum.map(rows, &Repo.get!(StopTime, &1.id)) == original
  end

  test "interior insertion is estimated, acknowledged, resequenced without collisions and preserves retained fields",
       context do
    stops =
      for name <- ["A", "B", "C", "X"],
          do: stop_fixture(context.organization.id, context.version.id, %{stop_name: name})

    [a_stop, b_stop, c_stop, inserted_stop] = stops

    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        pattern_attrs([a_stop, b_stop, c_stop]),
        context.audit
      )

    [a, b, c] = occurrences(pattern.id)
    [timing] = Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id)
    set_timing_rows(timing, [{-60, 0}, {240, 300}, {600, 660}])
    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip =
      trip
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

    old_rows =
      insert_trip_times(
        context,
        trip,
        [a_stop, b_stop, c_stop],
        [10, 40, 90],
        ["08:00:00", "08:04:00", "08:10:00"],
        ["08:00:00", "08:05:00", "08:11:00"]
      )

    old_rows =
      Enum.map(old_rows, fn row ->
        row
        |> Ecto.Changeset.change(%{
          continuous_pickup: 2,
          continuous_drop_off: 3,
          shape_dist_traveled: Decimal.new("12.5"),
          stop_headsign: "Local"
        })
        |> Repo.update!()
      end)

    entries = [
      %{id: a.id, stop_id: a.stop_id},
      %{key: "new-x", stop_id: inserted_stop.stop_id},
      %{id: b.id, stop_id: b.stop_id},
      %{id: c.id, stop_id: c.stop_id}
    ]

    source = source_for(context, pattern)
    no_ack = {:stops, entries, %{timing.id => %{}}}

    assert {:error, :timing_acknowledgement_required} =
             Gtfs.review(pattern.id, no_ack, source, context.audit)

    operation = {:stops, entries, %{timing.id => %{acknowledged: true}}}

    assert {:ok, %{fingerprint: reviewed, proposed: proposed}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    [timing_proposal] = proposed.timing_rows

    assert Enum.at(timing_proposal.rows, 1) == %{
             arrival_offset: 120,
             departure_offset: 120,
             timepoint: 0,
             pickup_type: 0,
             drop_off_type: 0,
             stop_headsign: nil
           }

    assert {:ok, %{trips_updated: 1}} =
             Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

    final_rows =
      Repo.all(
        from st in StopTime, where: st.trip_id == ^trip.trip_id, order_by: st.stop_sequence
      )

    inserted = Enum.find(final_rows, &(&1.stop_id == inserted_stop.stop_id))

    assert Enum.map(final_rows, &{&1.id, &1.stop_id, &1.stop_sequence}) == [
             {Enum.at(old_rows, 0).id, a_stop.stop_id, 1},
             {inserted.id, inserted_stop.stop_id, 2},
             {Enum.at(old_rows, 1).id, b_stop.stop_id, 3},
             {Enum.at(old_rows, 2).id, c_stop.stop_id, 4}
           ]

    retained = Enum.reject(final_rows, &(&1.stop_id == inserted_stop.stop_id))

    assert Enum.all?(
             retained,
             &(&1.continuous_pickup == 2 and &1.continuous_drop_off == 3 and
                 &1.shape_dist_traveled == Decimal.new("12.5") and &1.stop_headsign == "Local")
           )

    assert Enum.map(retained, & &1.inserted_at) == Enum.map(old_rows, & &1.inserted_at)
    assert inserted.arrival_time == "08:02:00"
    assert inserted.departure_time == "08:02:00"
    assert is_nil(inserted.shape_dist_traveled)
    assert is_nil(inserted.continuous_pickup)
    assert is_nil(inserted.continuous_drop_off)
  end

  test "timing-only materialization retains sparse labels and row IDs while changing only clock fields",
       context do
    stops =
      for name <- ["A", "B"],
          do: stop_fixture(context.organization.id, context.version.id, %{stop_name: name})

    {:ok, pattern} =
      Gtfs.create_pattern(context.route.route_id, pattern_attrs(stops), context.audit)

    [a, b] = occurrences(pattern.id)
    [timing] = Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id)
    set_timing_rows(timing, [{0, 0}, {600, 660}])
    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip =
      trip
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

    [first, second] =
      insert_trip_times(context, trip, stops, [10, 40], ["8:00:00", "08:10:00"], [
        "8:00:00",
        "08:11:00"
      ])

    before = [Repo.get!(StopTime, first.id), Repo.get!(StopTime, second.id)]

    operation =
      {:timing, timing.id,
       %{
         rows: [
           %{route_pattern_stop_id: a.id, arrival_offset: 0, departure_offset: 0},
           %{route_pattern_stop_id: b.id, arrival_offset: 660, departure_offset: 720}
         ]
       }}

    source = source_for(context, pattern)

    assert {:ok, %{fingerprint: reviewed}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert {:ok, %{trips_updated: 1}} =
             Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

    after_rows = [Repo.get!(StopTime, first.id), Repo.get!(StopTime, second.id)]
    assert Enum.map(after_rows, &{&1.id, &1.stop_sequence}) == [{first.id, 10}, {second.id, 40}]

    assert Enum.map(after_rows, &{&1.arrival_time, &1.departure_time}) == [
             {"8:00:00", "8:00:00"},
             {"08:11:00", "08:12:00"}
           ]

    assert Enum.map(before, & &1.id) == Enum.map(after_rows, & &1.id)
  end

  describe "reordering the stops of a timed pattern" do
    setup context do
      stops =
        for name <- ["A", "B", "C"],
            do: stop_fixture(context.organization.id, context.version.id, %{stop_name: name})

      {:ok, pattern} =
        Gtfs.create_pattern(context.route.route_id, pattern_attrs(stops), context.audit)

      [timing] = Repo.all(from t in TimedPattern, where: t.route_pattern_id == ^pattern.id)
      [a, b, c] = occurrences(pattern.id)
      set_timing_rows(timing, [{0, 0}, {300, 360}, {900, 900}])

      for {occurrence, headsign} <- [{a, "Alpha"}, {b, "Bravo"}, {c, "Charlie"}] do
        Repo.update_all(
          from(r in TimedPatternStop, where: r.route_pattern_stop_id == ^occurrence.id),
          set: [stop_headsign: headsign]
        )
      end

      %{
        stops: stops,
        pattern: pattern,
        timing: timing,
        a: a,
        b: b,
        c: c,
        reordered: [
          %{id: a.id, stop_id: a.stop_id},
          %{id: c.id, stop_id: c.stop_id},
          %{id: b.id, stop_id: b.stop_id}
        ]
      }
    end

    test "requires an acknowledgement before saving, then keeps each timing's times by position",
         %{pattern: pattern, timing: timing, a: a, b: b, c: c, reordered: reordered} = context do
      source = source_for(context, pattern)

      assert {:error, :timing_acknowledgement_required} =
               Gtfs.review(
                 pattern.id,
                 {:stops, reordered, %{timing.id => %{}}},
                 source,
                 context.audit
               )

      assert {:ok, %{proposed: %{estimates: estimates}}} =
               Gtfs.preview_stop_edit(
                 pattern.id,
                 {:stops, reordered, %{timing.id => %{}}},
                 context.audit
               )

      assert Enum.map(estimates, &{&1.id, &1.arrival_offset, &1.departure_offset}) ==
               [{c.id, 300, 360}, {b.id, 900, 900}]

      assert Enum.map(occurrences(pattern.id), & &1.id) == [a.id, b.id, c.id]

      operation = {:stops, reordered, %{timing.id => %{acknowledged: true}}}

      assert {:ok, %{fingerprint: reviewed}} =
               Gtfs.review(pattern.id, operation, source, context.audit)

      assert {:ok, %{trips_updated: 0}} =
               Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

      assert Enum.map(occurrences(pattern.id), &{&1.id, &1.position}) ==
               [{a.id, 1}, {c.id, 2}, {b.id, 3}]

      assert stored_timing_rows(timing) == [
               {a.id, 0, 0, "Alpha"},
               {c.id, 300, 360, "Charlie"},
               {b.id, 900, 900, "Bravo"}
             ]
    end

    test "estimates an added stop between the re-sequenced neighbours when it is saved with a reorder",
         %{pattern: pattern, timing: timing, a: a, b: b, c: c, reordered: [first, second, third]} =
           context do
      extra = stop_fixture(context.organization.id, context.version.id, %{stop_name: "X"})
      entries = [first, %{key: "new-x", stop_id: extra.stop_id}, second, third]
      operation = {:stops, entries, %{timing.id => %{acknowledged: true}}}
      source = source_for(context, pattern)

      assert {:ok, %{fingerprint: reviewed}} =
               Gtfs.review(pattern.id, operation, source, context.audit)

      assert {:ok, %{trips_updated: 0}} =
               Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

      [_, inserted, _, _] = occurrences(pattern.id)

      assert stored_timing_rows(timing) == [
               {a.id, 0, 0, "Alpha"},
               {inserted.id, 150, 150, nil},
               {c.id, 300, 360, "Charlie"},
               {b.id, 900, 900, "Bravo"}
             ]
    end

    test "still refuses to reorder a pattern that trips use",
         %{
           pattern: pattern,
           timing: timing,
           stops: stops,
           reordered: reordered
         } = context do
      trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

      trip
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

      insert_trip_times(
        context,
        trip,
        stops,
        [1, 2, 3],
        ["08:00:00", "08:05:00", "08:15:00"],
        ["08:00:00", "08:06:00", "08:15:00"]
      )

      before = stored_timing_rows(timing)
      operation = {:stops, reordered, %{timing.id => %{acknowledged: true}}}

      assert {:error, :invalid_occurrence_order} =
               Gtfs.review(pattern.id, operation, source_for(context, pattern), context.audit)

      assert stored_timing_rows(timing) == before
    end
  end

  defp stored_timing_rows(timing) do
    Repo.all(
      from r in TimedPatternStop,
        join: occurrence in RoutePatternStop,
        on: occurrence.id == r.route_pattern_stop_id,
        where: r.timed_pattern_id == ^timing.id,
        order_by: occurrence.position,
        select: {r.route_pattern_stop_id, r.arrival_offset, r.departure_offset, r.stop_headsign}
    )
  end

  defp pattern_attrs(stops),
    do: %{route_pattern_name: "Service", direction_id: 0, stops: Enum.map(stops, & &1.stop_id)}

  defp occurrences(id),
    do:
      Repo.all(from o in RoutePatternStop, where: o.route_pattern_id == ^id, order_by: o.position)

  defp source_for(context, pattern) do
    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    source
  end

  defp set_timing_rows(timing, values) do
    rows =
      Repo.all(
        from r in TimedPatternStop,
          join: occurrence in RoutePatternStop,
          on: occurrence.id == r.route_pattern_stop_id,
          where: r.timed_pattern_id == ^timing.id,
          order_by: occurrence.position
      )

    Enum.zip(rows, values)
    |> Enum.each(fn {row, {arrival, departure}} ->
      row
      |> Ecto.Changeset.change(%{
        arrival_offset: arrival,
        departure_offset: departure,
        timepoint: 1,
        pickup_type: 2,
        drop_off_type: 3,
        stop_headsign: "Local"
      })
      |> Repo.update!()
    end)
  end

  defp insert_trip_times(context, trip, stops, sequences, arrivals, departures) do
    Enum.zip([stops, sequences, arrivals, departures])
    |> Enum.map(fn {stop, seq, arrival, departure} ->
      %StopTime{}
      |> StopTime.changeset(%{
        trip_id: trip.trip_id,
        stop_id: stop.stop_id,
        stop_sequence: seq,
        arrival_time: arrival,
        departure_time: departure,
        organization_id: context.organization.id,
        gtfs_version_id: context.version.id,
        pickup_type: 2,
        drop_off_type: 3,
        timepoint: 1
      })
      |> Repo.insert!()
    end)
  end
end

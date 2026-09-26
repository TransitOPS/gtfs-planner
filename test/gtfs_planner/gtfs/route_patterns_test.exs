defmodule GtfsPlanner.Gtfs.RoutePatternsTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatternStop
  alias GtfsPlanner.Gtfs.TimedPattern
  alias GtfsPlanner.Gtfs.TimedPatternStop
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = user_fixture()

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: nil,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, route: route, audit: audit}
  end

  test "the Gtfs facade creates a scoped pattern, occurrences, Timing A and one actor-bound audit",
       context do
    first = stop_fixture(context.organization.id, context.version.id, %{stop_name: "First"})
    second = stop_fixture(context.organization.id, context.version.id, %{stop_name: "Second"})

    assert {:ok, %RoutePattern{} = pattern} =
             Gtfs.create_pattern(
               context.route.route_id,
               pattern_attrs([first, second]),
               context.audit
             )

    assert pattern.organization_id == context.organization.id
    assert pattern.gtfs_version_id == context.version.id
    assert pattern.route_id == context.route.route_id
    assert pattern.route_pattern_name == "Crosstown"
    assert pattern.headsign == "Harbor"
    assert pattern.route_pattern_id != "forged-natural-id"

    occurrences =
      Repo.all(
        from occurrence in RoutePatternStop,
          where: occurrence.route_pattern_id == ^pattern.id,
          order_by: occurrence.position
      )

    assert Enum.map(occurrences, &{&1.stop_id, &1.position}) == [
             {first.stop_id, 1},
             {second.stop_id, 2}
           ]

    timing = Repo.one!(from timing in TimedPattern, where: timing.route_pattern_id == ^pattern.id)
    assert timing.name == "Timing A"

    timing_rows =
      Repo.all(
        from row in TimedPatternStop,
          where: row.timed_pattern_id == ^timing.id,
          order_by: row.route_pattern_stop_id
      )

    assert length(timing_rows) == 2
    assert Enum.all?(timing_rows, &(&1.arrival_offset == 0 and &1.departure_offset == 0))

    assert Enum.all?(
             timing_rows,
             &(&1.route_pattern_stop_id in Enum.map(occurrences, fn o -> o.id end))
           )

    [log] =
      Repo.all(
        from log in ChangeLog,
          where: log.entity_type == "route_pattern" and log.entity_id == ^pattern.id
      )

    assert log.actor_id == context.audit.actor_id
    assert log.actor_email == context.audit.actor_email
    assert log.organization_id == context.organization.id
    assert log.gtfs_version_id == context.version.id
    assert log.station_stop_id == nil
    assert log.entity_external_id == pattern.route_pattern_id
    assert log.snapshot["route_pattern_id"] == pattern.route_pattern_id
    assert log.changed_fields["before"] == nil
    assert log.changed_fields["after"]["route_pattern_id"] == pattern.route_pattern_id
  end

  test "rejects foreign stops and forged linkage without writing any rows", context do
    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)
    foreign_stop = stop_fixture(foreign_org.id, foreign_version.id)
    own_stop = stop_fixture(context.organization.id, context.version.id)

    assert {:error, :not_found} =
             Gtfs.create_pattern(
               context.route.route_id,
               pattern_attrs([own_stop, foreign_stop]),
               context.audit
             )

    assert {:error, :invalid_input} =
             Gtfs.create_pattern(
               context.route.route_id,
               pattern_attrs([
                 own_stop,
                 stop_fixture(context.organization.id, context.version.id)
               ])
               |> Map.put(:timed_pattern_id, Ecto.UUID.generate()),
               context.audit
             )

    assert Repo.aggregate(RoutePattern, :count) == 0
    assert Repo.aggregate(RoutePatternStop, :count) == 0
    assert Repo.aggregate(TimedPattern, :count) == 0
    assert Repo.aggregate(TimedPatternStop, :count) == 0
    refute Repo.exists?(from log in ChangeLog, where: log.entity_type == "route_pattern")
  end

  test "lists and loads only a pattern in the requested organization, version and route",
       context do
    first = stop_fixture(context.organization.id, context.version.id)
    second = stop_fixture(context.organization.id, context.version.id)

    assert {:ok, pattern} =
             Gtfs.create_pattern(
               context.route.route_id,
               pattern_attrs([first, second]),
               context.audit
             )

    foreign_org = organization_fixture()
    foreign_version = gtfs_version_fixture(foreign_org.id)

    assert {:error, :not_found} =
             Gtfs.get_pattern(
               foreign_org.id,
               foreign_version.id,
               context.route.route_id,
               pattern.id,
               nil
             )

    assert {:error, :not_found} =
             Gtfs.get_pattern(
               context.organization.id,
               context.version.id,
               "another-route",
               pattern.id,
               nil
             )

    assert {:error, :not_found} =
             Gtfs.get_pattern(
               context.organization.id,
               context.version.id,
               context.route.route_id,
               pattern.id,
               Ecto.UUID.generate()
             )

    assert {:ok, %{patterns: [listed]}} =
             Gtfs.list_patterns(
               context.organization.id,
               context.version.id,
               context.route.route_id
             )

    assert listed.id == pattern.id
  end

  test "interactive pattern reads and writes reject a version that is no longer published",
       context do
    first = stop_fixture(context.organization.id, context.version.id)
    second = stop_fixture(context.organization.id, context.version.id)

    version =
      context.version
      |> GtfsVersion.transition_changeset("importing", nil)
      |> Repo.update!()

    assert version.publication_status == "importing"

    assert {:error, :not_found} =
             Gtfs.list_patterns(context.organization.id, version.id, context.route.route_id)

    assert {:error, :not_found} =
             Gtfs.create_pattern(
               context.route.route_id,
               pattern_attrs([first, second]),
               context.audit
             )

    refute Repo.exists?(
             from pattern in RoutePattern, where: pattern.gtfs_version_id == ^version.id
           )
  end

  test "a copy gets fresh occurrence and timing identities and no trips", context do
    first = stop_fixture(context.organization.id, context.version.id)
    second = stop_fixture(context.organization.id, context.version.id)

    {:ok, original} =
      Gtfs.create_pattern(context.route.route_id, pattern_attrs([first, second]), context.audit)

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        original.id
      )

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(original.id, :copy, source, context.audit)

    assert {:ok, %{pattern: copied}} =
             Gtfs.apply_review(original.id, :copy, fingerprint, context.audit)

    refute copied.id == original.id
    refute copied.route_pattern_id == original.route_pattern_id
    refute is_nil(copied.route_pattern_id)

    original_occurrences = pattern_occurrences(original.id)
    copied_occurrences = pattern_occurrences(copied.id)

    assert Enum.map(copied_occurrences, & &1.stop_id) ==
             Enum.map(original_occurrences, & &1.stop_id)

    refute Enum.any?(Enum.zip(original_occurrences, copied_occurrences), fn {left, right} ->
             left.id == right.id
           end)

    original_timing =
      Repo.one!(from timing in TimedPattern, where: timing.route_pattern_id == ^original.id)

    copied_timing =
      Repo.one!(from timing in TimedPattern, where: timing.route_pattern_id == ^copied.id)

    refute copied_timing.id == original_timing.id

    assert Repo.aggregate(
             from(trip in GtfsPlanner.Gtfs.Trip,
               where: trip.route_pattern_id == ^copied.route_pattern_id
             ),
             :count
           ) == 0

    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip =
      trip
      |> Ecto.Changeset.change(%{route_pattern_id: original.route_pattern_id})
      |> Repo.update!()

    assert trip.trip_headsign == "Downtown"

    {:ok, %{source_fingerprint: current_source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        original.id
      )

    assert {:error, :pattern_in_use} =
             Gtfs.review(original.id, :delete, current_source, context.audit)

    {:ok, %{source_fingerprint: copied_source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        copied.id
      )

    assert {:ok, %{fingerprint: delete_fingerprint}} =
             Gtfs.review(copied.id, :delete, copied_source, context.audit)

    assert {:ok, %{pattern: nil, trips_updated: 0}} =
             Gtfs.apply_review(copied.id, :delete, delete_fingerprint, context.audit)

    assert Repo.get(RoutePattern, copied.id) == nil

    delete_log =
      Repo.one!(
        from log in ChangeLog,
          where:
            log.entity_type == "route_pattern" and log.entity_id == ^copied.id and
              log.action == "deleted"
      )

    assert delete_log.changed_fields["before"]["route_pattern_id"] == copied.route_pattern_id
    assert is_nil(delete_log.changed_fields["after"])
  end

  test "loop stops remain separate occurrences with distinct UUIDs", context do
    first = stop_fixture(context.organization.id, context.version.id)
    middle = stop_fixture(context.organization.id, context.version.id)

    assert {:ok, pattern} =
             Gtfs.create_pattern(
               context.route.route_id,
               pattern_attrs([first, middle, first]),
               context.audit
             )

    occurrences = pattern_occurrences(pattern.id)
    assert Enum.map(occurrences, & &1.stop_id) == [first.stop_id, middle.stop_id, first.stop_id]
    assert Enum.map(occurrences, & &1.position) == [1, 2, 3]
    assert length(Enum.uniq(Enum.map(occurrences, & &1.id))) == 3
    assert Enum.at(occurrences, 0).id != Enum.at(occurrences, 2).id
  end

  test "editing the default headsign does not rewrite trip headsigns or timing overrides",
       context do
    first = stop_fixture(context.organization.id, context.version.id)
    second = stop_fixture(context.organization.id, context.version.id)

    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        pattern_attrs([first, second]),
        context.audit
      )

    timing = Repo.one!(from timing in TimedPattern, where: timing.route_pattern_id == ^pattern.id)
    timing = timing |> Ecto.Changeset.change(%{headsign: "Timing-specific"}) |> Repo.update!()

    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip =
      trip
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })
      |> Repo.update!()

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    operation = {:details, %{headsign: "Harbor Express"}}

    assert {:ok, %{fingerprint: reviewed}} =
             Gtfs.review(pattern.id, operation, source, context.audit)

    assert {:ok, _} = Gtfs.apply_review(pattern.id, operation, reviewed, context.audit)

    assert Repo.get!(GtfsPlanner.Gtfs.Trip, trip.id).trip_headsign == "Downtown"
    assert Repo.get!(TimedPattern, timing.id).headsign == "Timing-specific"
  end

  test "timing names are unique and used or last timings require protection", context do
    first = stop_fixture(context.organization.id, context.version.id)
    second = stop_fixture(context.organization.id, context.version.id)

    {:ok, pattern} =
      Gtfs.create_pattern(context.route.route_id, pattern_attrs([first, second]), context.audit)

    [timing_a] =
      Repo.all(from timing in TimedPattern, where: timing.route_pattern_id == ^pattern.id)

    {:ok, %{source_fingerprint: source}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    assert {:error, :last_timing} =
             Gtfs.review(pattern.id, {:delete_timing, timing_a.id}, source, context.audit)

    add_operation = {:add_timing, %{name: "Timing B"}}

    assert {:ok, %{fingerprint: add_fingerprint}} =
             Gtfs.review(pattern.id, add_operation, source, context.audit)

    assert {:ok, _result} =
             Gtfs.apply_review(pattern.id, add_operation, add_fingerprint, context.audit)

    timing_b =
      Repo.one!(
        from timing in TimedPattern,
          where: timing.route_pattern_id == ^pattern.id and timing.name == "Timing B"
      )

    timing_audit =
      Repo.one!(
        from log in ChangeLog,
          where: log.entity_type == "timed_pattern" and log.entity_id == ^timing_b.id
      )

    assert timing_audit.entity_external_id == "#{timing_b.id}:#{pattern.route_pattern_id}"
    assert timing_audit.station_stop_id == nil
    assert timing_audit.snapshot["rows"] |> length() == 2
    assert timing_audit.changed_fields["after"]["name"] == "Timing B"

    rename_operation = {:timing, timing_b.id, %{name: "timing a"}}

    {:ok, %{source_fingerprint: source_after_add}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    assert {:ok, %{fingerprint: rename_fingerprint}} =
             Gtfs.review(pattern.id, rename_operation, source_after_add, context.audit)

    assert {:error, %Ecto.Changeset{}} =
             Gtfs.apply_review(pattern.id, rename_operation, rename_fingerprint, context.audit)

    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    trip
    |> Ecto.Changeset.change(%{
      route_pattern_id: pattern.route_pattern_id,
      timed_pattern_id: timing_a.id,
      pattern_derivation_state: "linked",
      pattern_derivation_reason: nil
    })
    |> Repo.update!()

    {:ok, %{source_fingerprint: source_after_assignment}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    assert {:error, :timing_in_use} =
             Gtfs.review(
               pattern.id,
               {:delete_timing, timing_a.id},
               source_after_assignment,
               context.audit
             )

    {:ok, %{source_fingerprint: source_after_failed_rename}} =
      Gtfs.get_pattern(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        pattern.id
      )

    delete_operation = {:delete_timing, timing_b.id}

    assert {:ok, %{fingerprint: delete_fingerprint}} =
             Gtfs.review(pattern.id, delete_operation, source_after_failed_rename, context.audit)

    assert {:ok, _result} =
             Gtfs.apply_review(pattern.id, delete_operation, delete_fingerprint, context.audit)

    assert Repo.aggregate(
             from(timing in TimedPattern, where: timing.route_pattern_id == ^pattern.id),
             :count
           ) == 1
  end

  defp pattern_occurrences(pattern_id) do
    Repo.all(
      from occurrence in RoutePatternStop,
        where: occurrence.route_pattern_id == ^pattern_id,
        order_by: occurrence.position
    )
  end

  defp pattern_attrs(stops) do
    %{
      route_pattern_id: "forged-natural-id",
      route_pattern_name: "Crosstown",
      direction_id: 0,
      route_pattern_typicality: 1,
      headsign: "Harbor",
      stops: Enum.map(stops, & &1.stop_id)
    }
  end
end

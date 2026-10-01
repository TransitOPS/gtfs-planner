defmodule GtfsPlanner.Gtfs.RoutePatterns.LabelDirectionTest do
  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo

  # The prototype scenario: label `1-0-A` with 40 all-stop trips and 4 express
  # trips on the child, 44 linked trips in total.
  @owner_trip_count 40
  @child_trip_count 4

  setup do
    organization =
      organization_fixture(%{
        alias: "route-pattern-label-direction-#{System.system_time(:nanosecond)}"
      })

    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)

    stops =
      for name <- ["A", "B", "C"],
          do: stop_fixture(organization.id, version.id, %{stop_name: name})

    %{
      organization: organization,
      version: version,
      route: route,
      stops: stops,
      audit: %AuditContext{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }
    }
  end

  test "a Details direction change on a child is refused and changes no row", context do
    %{owner: owner, child: child} = labelled_pair(context)
    link_trips(context, owner, @owner_trip_count)
    link_trips(context, child, @child_trip_count)

    assert {:error, :labelled_direction} =
             Gtfs.review(child.id, {:details, %{direction_id: 1}}, nil, context.audit)

    # A fingerprint the review would really issue, so the apply reaches the
    # label refusal rather than the earlier stale-review check.
    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(
               child.id,
               {:details, %{route_pattern_name: "1-0-A express"}},
               nil,
               context.audit
             )

    assert {:error, :labelled_direction} =
             Gtfs.apply_review(
               child.id,
               {:details, %{direction_id: 1}},
               fingerprint,
               context.audit
             )

    assert Repo.get!(RoutePattern, child.id).direction_id == 0
    assert Repo.get!(RoutePattern, owner.id).direction_id == 0
    assert count_trips_at_direction(context, 1) == 0
  end

  test "a Details direction change on the owner moves the child and all 44 linked trips",
       context do
    %{owner: owner, child: child} = labelled_pair(context)
    link_trips(context, owner, @owner_trip_count)
    link_trips(context, child, @child_trip_count)

    assert count_trips_at_direction(context, 1) == 0

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(owner.id, {:details, %{direction_id: 1}}, nil, context.audit)

    assert {:ok, %{trips_updated: 44}} =
             Gtfs.apply_review(
               owner.id,
               {:details, %{direction_id: 1}},
               fingerprint,
               context.audit
             )

    assert Repo.get!(RoutePattern, owner.id).direction_id == 1
    assert Repo.get!(RoutePattern, child.id).direction_id == 1
    assert count_trips_at_direction(context, 1) == 44
    assert count_trips_at_direction(context, 0) == 0
  end

  test "the owner's review names the child pattern and its trip count", context do
    %{owner: owner, child: child} = labelled_pair(context)
    link_trips(context, owner, @owner_trip_count)
    link_trips(context, child, @child_trip_count)

    assert {:ok, %{impact: impact}} =
             Gtfs.review(owner.id, {:details, %{direction_id: 1}}, nil, context.audit)

    assert impact.trips_affected == 44

    assert [%{route_pattern_id: child_id, trips_affected: 4}] = impact.children
    assert child_id == child.route_pattern_id
  end

  test "a direction change on an unlabelled pattern with no children behaves as before",
       context do
    owner = create_pattern(context, "Unlabelled")
    link_trips(context, owner, @owner_trip_count)

    assert {:ok, %{fingerprint: fingerprint, impact: impact}} =
             Gtfs.review(owner.id, {:details, %{direction_id: 1}}, nil, context.audit)

    assert impact.trips_affected == @owner_trip_count
    assert impact.children == []

    assert {:ok, %{trips_updated: 40}} =
             Gtfs.apply_review(
               owner.id,
               {:details, %{direction_id: 1}},
               fingerprint,
               context.audit
             )

    assert Repo.get!(RoutePattern, owner.id).direction_id == 1
    assert count_trips_at_direction(context, 1) == 40
  end

  defp labelled_pair(context) do
    owner = create_pattern(context, "1-0-A")
    child = create_pattern(context, "1-0-A express")

    # Labels are written by derivation and the label UI, neither of which owns
    # this fixture's child yet, so the pointer is written directly the way
    # those writers write it.
    {1, nil} =
      Repo.update_all(
        from(p in RoutePattern, where: p.id == ^child.id),
        set: [label_pattern_id: owner.id]
      )

    %{owner: owner, child: Repo.get!(RoutePattern, child.id)}
  end

  defp create_pattern(context, name) do
    {:ok, pattern} =
      Gtfs.create_pattern(
        context.route.route_id,
        %{
          route_pattern_name: name,
          direction_id: 0,
          route_pattern_typicality: 1,
          stops: Enum.map(context.stops, & &1.stop_id)
        },
        context.audit
      )

    pattern
  end

  defp link_trips(context, pattern, count) do
    for _index <- 1..count do
      trip_fixture(context.organization.id, context.version.id, context.route.route_id)
      |> Ecto.Changeset.change(%{
        route_pattern_id: pattern.route_pattern_id,
        direction_id: 0
      })
      |> Repo.update!()
    end
  end

  defp count_trips_at_direction(context, direction_id) do
    Repo.aggregate(
      from(t in Trip,
        where:
          t.organization_id == ^context.organization.id and
            t.gtfs_version_id == ^context.version.id and
            t.direction_id == ^direction_id
      ),
      :count
    )
  end
end

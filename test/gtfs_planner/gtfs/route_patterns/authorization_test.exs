defmodule GtfsPlanner.Gtfs.RoutePatterns.AuthorizationTest do
  use GtfsPlanner.DataCase

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts.UserOrgMembership
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.RoutePattern
  alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    route = route_fixture(organization.id, version.id)
    actor = editor_fixture(organization)
    membership = GtfsPlanner.Accounts.get_user_org_membership(actor.id, organization.id)
    stops = for _ <- 1..2, do: stop_fixture(organization.id, version.id)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{
      organization: organization,
      version: version,
      route: route,
      membership: membership,
      audit: audit,
      stops: stops
    }
  end

  test "revoked editor cannot create a pattern or its history", context do
    before_patterns = count(RoutePattern, context.organization.id)
    before_logs = count(ChangeLog, context.organization.id)
    deactivate_membership_fixture(context.membership)

    attrs = %{
      route_pattern_name: "Refused",
      direction_id: 0,
      stops: Enum.map(context.stops, & &1.stop_id)
    }

    assert {:error, :forbidden} =
             Gtfs.create_pattern(context.route.route_id, attrs, context.audit)

    assert count(RoutePattern, context.organization.id) == before_patterns
    assert count(ChangeLog, context.organization.id) == before_logs
  end

  test "reviewed details apply rechecks a removed editor role", context do
    pattern = pattern!(context)
    operation = {:details, %{route_pattern_name: "Changed after review"}}

    assert {:ok, %{fingerprint: fingerprint}} =
             Gtfs.review(pattern.id, operation, nil, context.audit)

    before_pattern = Repo.reload!(pattern)
    before_logs = count(ChangeLog, context.organization.id)

    context.membership
    |> UserOrgMembership.changeset(%{roles: ["pathways_studio_admin"]})
    |> Repo.update!()

    assert {:error, :forbidden} =
             Gtfs.apply_review(pattern.id, operation, fingerprint, context.audit)

    assert Repo.reload!(pattern) == before_pattern
    assert count(ChangeLog, context.organization.id) == before_logs
  end

  test "revoked editor cannot derive pending route patterns", context do
    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)
    before_trip = Repo.reload!(trip)
    before_patterns = count(RoutePattern, context.organization.id)
    before_logs = count(ChangeLog, context.organization.id)
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Derivation.derive_route(
               context.organization.id,
               context.version.id,
               context.route.route_id,
               {:editor, context.audit}
             )

    assert Repo.reload!(trip) == before_trip
    assert count(RoutePattern, context.organization.id) == before_patterns
    assert count(ChangeLog, context.organization.id) == before_logs
  end

  test "version-wide editor derivation classifies a missing route", context do
    trip = trip_fixture(context.organization.id, context.version.id, "missing-route")

    assert {:ok, %{trips_custom: 1, routes_failed: 0}} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:editor, context.audit}
             )

    assert Repo.reload!(trip).pattern_derivation_state == "custom"
    assert count(RoutePattern, context.organization.id) == 0
    assert count(ChangeLog, context.organization.id) == 0
  end

  test "version-wide editor derivation refuses missing-route writes after revocation", context do
    missing_trip = trip_fixture(context.organization.id, context.version.id, "missing-route")

    present_trip =
      trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    before_missing = Repo.reload!(missing_trip)
    before_present = Repo.reload!(present_trip)
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:editor, context.audit}
             )

    assert Repo.reload!(missing_trip) == before_missing
    assert Repo.reload!(present_trip) == before_present
    assert count(RoutePattern, context.organization.id) == 0
    assert count(ChangeLog, context.organization.id) == 0
  end

  test "version-wide editor derivation cannot classify a version outside its audit scope",
       context do
    trip = trip_fixture(context.organization.id, context.version.id, "missing-route")
    before_trip = Repo.reload!(trip)
    foreign_audit = %{context.audit | gtfs_version_id: Ecto.UUID.generate()}

    assert {:error, :not_found} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:editor, foreign_audit}
             )

    assert Repo.reload!(trip) == before_trip
    assert count(ChangeLog, context.organization.id) == 0
  end

  test "version-wide editor derivation keeps route-local failure reporting", context do
    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)

    Application.put_env(
      :gtfs_planner,
      :route_pattern_derivation_inject_failure,
      context.route.route_id
    )

    on_exit(fn ->
      Application.delete_env(:gtfs_planner, :route_pattern_derivation_inject_failure)
    end)

    assert {:ok, %{routes_failed: 1}} =
             Derivation.derive_version(
               context.organization.id,
               context.version.id,
               {:editor, context.audit}
             )

    assert Repo.reload!(context.route).pattern_derivation_error == "injected_derivation_failure"
    assert Repo.reload!(trip).pattern_derivation_state == "pending"
    assert count(RoutePattern, context.organization.id) == 0
  end

  test "reset and undo reject a revoked editor before changing trip or history", context do
    bundle =
      schedule_pattern_fixture(context.organization.id, context.version.id, %{
        route_id: context.route.route_id,
        headsign: "Downtown",
        stops: Enum.map(context.stops, &{&1.stop_id, 0, 0, 1})
      })

    trip =
      schedule_trip_fixture(
        context.organization.id,
        context.version.id,
        context.route.route_id,
        bundle,
        %{service_id: "WK", trip_headsign: "Uptown"}
      ).trip

    before_trip = Repo.reload!(trip)
    before_pattern = Repo.reload!(bundle.pattern)
    before_logs = count(ChangeLog, context.organization.id)
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Gtfs.reset_trip_headsigns(
               bundle.pattern.id,
               :pattern,
               [%{id: trip.id, from: "Uptown"}],
               context.audit
             )

    undo = %{
      default: nil,
      trips: [%{id: trip.id, trip_id: trip.trip_id, from: "Uptown", to: "Downtown"}]
    }

    assert {:error, :forbidden} =
             Gtfs.undo_headsign_update(bundle.pattern.id, undo, context.audit)

    assert Repo.reload!(trip) == before_trip
    assert Repo.reload!(bundle.pattern) == before_pattern
    assert count(ChangeLog, context.organization.id) == before_logs
  end

  test "label removal rejects a revoked editor before clearing the owner", context do
    owner = pattern!(context)
    child = pattern!(context)

    {1, nil} =
      Repo.update_all(
        from(p in RoutePattern, where: p.id == ^child.id),
        set: [label_pattern_id: owner.id]
      )

    before_child = Repo.reload!(child)
    before_logs = count(ChangeLog, context.organization.id)
    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Gtfs.remove_route_pattern_label(context.route.route_id, child.id, context.audit)

    assert Repo.reload!(child) == before_child
    assert count(ChangeLog, context.organization.id) == before_logs
  end

  test "grouping apply rejects a revoked editor before touching a trip or history", context do
    trip = trip_fixture(context.organization.id, context.version.id, context.route.route_id)
    before_trip = Repo.reload!(trip)
    before_logs = count(ChangeLog, context.organization.id)
    review = %{selections: [], fingerprint: "reviewed-before-revocation"}

    # An active editor reaches the fingerprint comparison, which refuses this
    # stale review, so the :forbidden below comes from the membership check.
    assert {:error, :stale} =
             Gtfs.group_left_out_trips(context.route.route_id, review, context.audit)

    deactivate_membership_fixture(context.membership)

    assert {:error, :forbidden} =
             Gtfs.group_left_out_trips(context.route.route_id, review, context.audit)

    assert Repo.reload!(trip) == before_trip
    assert count(ChangeLog, context.organization.id) == before_logs
  end

  defp pattern!(context) do
    attrs = %{
      route_pattern_name: "Original",
      direction_id: 0,
      stops: Enum.map(context.stops, & &1.stop_id)
    }

    {:ok, pattern} = Gtfs.create_pattern(context.route.route_id, attrs, context.audit)
    pattern
  end

  defp count(schema, organization_id) do
    Repo.aggregate(from(row in schema, where: row.organization_id == ^organization_id), :count)
  end
end

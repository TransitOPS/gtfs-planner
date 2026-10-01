defmodule GtfsPlanner.Gtfs.FareZones.AssignmentTest do
  @moduledoc """
  Merge evidence (EV-6) for reviewed bulk assignment: preview counts, the exact
  writes of apply, the stale fence, invalid selections, unknown targets, Undo of
  zones that left the inventory and twin-scope isolation.

  Every expected literal below is hand-written fixture data, so the production
  queries cannot confirm their own output. The twin organization and a second
  version of the same organization carry identical `stop_id` and zone ID values,
  so a missing scope predicate is observable, and seeds use an hour-old
  `updated_at` so the write's timestamp update is observable without depending on
  clock resolution.
  """
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.VersionsFixtures

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)
    actor = AccountsFixtures.editor_fixture(organization)

    audit = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      actor_id: actor.id,
      actor_email: actor.email
    }

    %{organization: organization, version: version, audit: audit}
  end

  test "previews changed, added, moved and unchanged counts from current values", %{
    organization: organization,
    version: version
  } do
    [alpha, bravo, charlie] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", stop_name: "Alpha", zone_id: nil},
        %{stop_id: "p-2", stop_name: "Bravo", zone_id: "B"},
        %{stop_id: "p-3", stop_name: "Charlie", zone_id: "A"}
      ])

    assert {:ok, review} =
             FareZones.preview_assignment(
               organization.id,
               version.id,
               [charlie.id, alpha.id, bravo.id, alpha.id],
               "A"
             )

    assert review.rows == [
             %{id: alpha.id, stop_id: "p-1", stop_name: "Alpha", from: nil, to: "A"},
             %{id: bravo.id, stop_id: "p-2", stop_name: "Bravo", from: "B", to: "A"},
             %{id: charlie.id, stop_id: "p-3", stop_name: "Charlie", from: "A", to: "A"}
           ]

    assert review.changes == [
             %{id: alpha.id, from: nil, to: "A"},
             %{id: bravo.id, from: "B", to: "A"}
           ]

    assert review.changed_count == 2
    assert review.added_count == 1
    assert review.moved_count == 1
    assert review.unchanged_count == 1
    assert review.unselected_sibling_count == 0

    assert zone_of(alpha.id) == nil
    assert zone_of(bravo.id) == "B"
    assert zone_of(charlie.id) == "A"
  end

  test "counts unselected sibling platforms sharing a parent station", %{
    organization: organization,
    version: version
  } do
    [p1, p2, p3, _station, _elsewhere] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", stop_name: "One", parent_station: "P-1", zone_id: nil},
        %{stop_id: "p-2", stop_name: "Two", parent_station: "P-1", zone_id: nil},
        %{stop_id: "p-3", stop_name: "Three", parent_station: "P-1", zone_id: nil},
        %{stop_id: "P-1", stop_name: "Parent", location_type: 1, zone_id: nil},
        %{stop_id: "q-1", stop_name: "Elsewhere", parent_station: "P-2", zone_id: "B"}
      ])

    assert {:ok, review} =
             FareZones.preview_assignment(organization.id, version.id, [p1.id, p3.id], "B")

    assert Enum.map(review.rows, & &1.stop_id) == ["p-1", "p-3"]
    assert review.unselected_sibling_count == 1

    assert {:ok, single} =
             FareZones.preview_assignment(organization.id, version.id, [p1.id], "B")

    assert single.unselected_sibling_count == 2

    assert {:ok, unrelated} =
             FareZones.preview_assignment(organization.id, version.id, [p1.id, p2.id, p3.id], "B")

    assert unrelated.unselected_sibling_count == 0
  end

  test "apply writes exactly the reviewed changes and returns them as applied", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [alpha, bravo, charlie, delta] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", stop_name: "Alpha", zone_id: nil},
        %{stop_id: "p-2", stop_name: "Bravo", zone_id: "B"},
        %{stop_id: "p-3", stop_name: "Charlie", zone_id: "A"},
        %{stop_id: "p-4", stop_name: "Delta", zone_id: "B"}
      ])

    seeded_alpha = updated_at(alpha.id)
    seeded_charlie = updated_at(charlie.id)

    assert {:ok, review} =
             FareZones.preview_assignment(
               organization.id,
               version.id,
               [alpha.id, bravo.id, charlie.id],
               "A"
             )

    assert {:ok, %{applied: applied}} =
             FareZones.apply_assignment(audit, review.changes)

    assert applied == [
             %{id: alpha.id, from: nil, to: "A"},
             %{id: bravo.id, from: "B", to: "A"}
           ]

    assert zone_of(alpha.id) == "A"
    assert zone_of(bravo.id) == "A"
    assert zone_of(charlie.id) == "A"
    assert zone_of(delta.id) == "B"

    assert DateTime.compare(updated_at(alpha.id), seeded_alpha) == :gt
    assert updated_at(charlie.id) == seeded_charlie
    assert updated_at(delta.id) == seeded_alpha
  end

  test "writes one group per distinct target in a single call", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [alpha, bravo, charlie] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", stop_name: "Alpha", zone_id: "A"},
        %{stop_id: "p-2", stop_name: "Bravo", zone_id: "B"},
        %{stop_id: "p-3", stop_name: "Charlie", zone_id: nil}
      ])

    changes = [
      %{id: alpha.id, from: "A", to: "B"},
      %{id: bravo.id, from: "B", to: nil},
      %{id: charlie.id, from: nil, to: "B"}
    ]

    assert {:ok, %{applied: applied}} =
             FareZones.apply_assignment(audit, changes)

    assert applied == changes
    assert zone_of(alpha.id) == "B"
    assert zone_of(bravo.id) == nil
    assert zone_of(charlie.id) == "B"
  end

  test "apply returns the stale stops and writes nothing when a reviewed value changed", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")

    [alpha, bravo] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", stop_name: "Alpha", zone_id: nil},
        %{stop_id: "p-2", stop_name: "Bravo", zone_id: nil}
      ])

    assert {:ok, review} =
             FareZones.preview_assignment(organization.id, version.id, [alpha.id, bravo.id], "A")

    set_zone(alpha.id, "C")

    assert {:error, {:stale, stale}} =
             FareZones.apply_assignment(audit, review.changes)

    assert stale == [
             %{id: alpha.id, stop_id: "p-1", stop_name: "Alpha", reviewed: nil, current: "C"}
           ]

    assert zone_of(alpha.id) == "C"
    assert zone_of(bravo.id) == nil
  end

  test "rejects a duplicated foreign, station or other-version ID and writes nothing", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")

    twin_organization = OrganizationsFixtures.organization_fixture()
    twin_version = VersionsFixtures.gtfs_version_fixture(twin_organization.id)
    other_version = VersionsFixtures.gtfs_version_fixture(organization.id)

    [alpha] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: nil}])

    [foreign] =
      insert_stops(twin_organization, twin_version, [%{stop_id: "p-1", zone_id: "F"}])

    [sibling] = insert_stops(organization, other_version, [%{stop_id: "p-1", zone_id: "O"}])

    [station] =
      insert_stops(organization, version, [
        %{stop_id: "S-1", location_type: 1, zone_id: "V"}
      ])

    assert {:error, :invalid_selection} =
             FareZones.preview_assignment(organization.id, version.id, [foreign.id], "A")

    assert {:error, :invalid_selection} =
             FareZones.preview_assignment(organization.id, version.id, [station.id], "A")

    assert {:error, :invalid_selection} =
             FareZones.apply_assignment(audit, [
               %{id: foreign.id, from: "F", to: "A"}
             ])

    assert {:error, :invalid_selection} =
             FareZones.apply_assignment(audit, [
               %{id: station.id, from: "V", to: "A"}
             ])

    assert {:error, :invalid_selection} =
             FareZones.apply_assignment(audit, [
               %{id: sibling.id, from: "O", to: "A"}
             ])

    assert {:error, :invalid_selection} =
             FareZones.apply_assignment(audit, [
               %{id: alpha.id, from: nil, to: "A"},
               %{id: foreign.id, from: "F", to: "A"}
             ])

    assert zone_of(alpha.id) == nil
    assert zone_of(foreign.id) == "F"
    assert zone_of(sibling.id) == "O"
    assert zone_of(station.id) == "V"
  end

  test "rejects an unknown target and unassigns with a nil target", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [alpha] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])

    assert {:error, :unknown_zone} =
             FareZones.preview_assignment(organization.id, version.id, [alpha.id], "Missing")

    assert {:error, :unknown_zone} =
             FareZones.apply_assignment(audit, [
               %{id: alpha.id, from: "A", to: "Missing"}
             ])

    assert zone_of(alpha.id) == "A"

    insert_fare_rule(organization, version, %{fare_id: "F", origin_id: "R"})

    assert {:ok, %{changed_count: 1, added_count: 0, moved_count: 1}} =
             FareZones.preview_assignment(organization.id, version.id, [alpha.id], "R")

    assert {:ok, %{applied: [%{id: id, from: "A", to: "R"}]}} =
             FareZones.apply_assignment(audit, [
               %{id: alpha.id, from: "A", to: "R"}
             ])

    assert id == alpha.id
    assert zone_of(alpha.id) == "R"

    assert {:ok, review} =
             FareZones.preview_assignment(organization.id, version.id, [alpha.id], nil)

    assert review.changes == [%{id: alpha.id, from: "R", to: nil}]
    assert review.changed_count == 1
    assert review.added_count == 0
    assert review.moved_count == 0

    assert {:ok, %{applied: [%{id: id, from: "R", to: nil}]}} =
             FareZones.apply_assignment(audit, review.changes)

    assert id == alpha.id
    assert zone_of(alpha.id) == nil
  end

  test "undo restores an implicit zone that lost its last stop to a move", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [alpha, bravo] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "p-2", zone_id: "B"}
      ])

    assert {:ok, %{changes: changes}} =
             FareZones.preview_assignment(organization.id, version.id, [alpha.id], "B")

    assert changes == [%{id: alpha.id, from: "A", to: "B"}]

    assert {:ok, %{applied: applied}} =
             FareZones.apply_assignment(audit, changes)

    assert zone_of(alpha.id) == "B"
    refute "A" in inventory_zone_ids(organization, version)

    assert {:ok, %{applied: undone}} =
             FareZones.undo_assignment(audit, applied)

    assert undone == [%{id: alpha.id, from: "B", to: "A"}]
    assert zone_of(alpha.id) == "A"
    assert zone_of(bravo.id) == "B"
    assert inventory_zone_ids(organization, version) == ["A", "B"]
  end

  test "undo restores an implicit zone after unassigning its last stop", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [padded] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: " A"}])

    assert {:ok, %{changes: changes}} =
             FareZones.preview_assignment(organization.id, version.id, [padded.id], nil)

    assert changes == [%{id: padded.id, from: " A", to: nil}]

    assert {:ok, %{applied: applied}} =
             FareZones.apply_assignment(audit, changes)

    assert zone_of(padded.id) == nil
    refute " A" in inventory_zone_ids(organization, version)

    assert {:ok, %{applied: _}} =
             FareZones.undo_assignment(audit, applied)

    assert zone_of(padded.id) == " A"
    assert inventory_zone_ids(organization, version) == [" A"]
  end

  test "undo returns the stale stops and writes nothing after a newer change", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [alpha, bravo] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "p-2", zone_id: "B"}
      ])

    assert {:ok, %{changes: changes}} =
             FareZones.preview_assignment(organization.id, version.id, [alpha.id], "B")

    assert {:ok, %{applied: applied}} =
             FareZones.apply_assignment(audit, changes)

    set_zone(alpha.id, "C")

    assert {:error, {:stale, stale}} =
             FareZones.undo_assignment(audit, applied)

    assert stale == [
             %{id: alpha.id, stop_id: "p-1", stop_name: "Stop p-1", reviewed: "B", current: "C"}
           ]

    assert zone_of(alpha.id) == "C"
    assert zone_of(bravo.id) == "B"
  end

  test "leaves twin scope rows unchanged and refuses a non-published pair", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    twin_organization = OrganizationsFixtures.organization_fixture()
    AccountsFixtures.organization_membership_fixture(%{id: audit.actor_id}, twin_organization)
    twin_version = VersionsFixtures.gtfs_version_fixture(twin_organization.id)
    other_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    staging_version = stage(VersionsFixtures.gtfs_version_fixture(organization.id))

    [alpha, bravo] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "p-2", zone_id: "B"}
      ])

    [twin] = insert_stops(twin_organization, twin_version, [%{stop_id: "p-1", zone_id: "T"}])
    [sibling] = insert_stops(organization, other_version, [%{stop_id: "p-1", zone_id: "V"}])

    assert {:ok, %{changes: changes}} =
             FareZones.preview_assignment(organization.id, version.id, [alpha.id], "B")

    assert {:ok, %{applied: applied}} =
             FareZones.apply_assignment(audit, changes)

    assert zone_of(alpha.id) == "B"
    assert zone_of(twin.id) == "T"
    assert zone_of(sibling.id) == "V"

    assert {:error, :not_found} =
             FareZones.apply_assignment(
               %{audit | organization_id: twin_organization.id, gtfs_version_id: version.id},
               [
                 %{id: alpha.id, from: "B", to: "A"}
               ]
             )

    assert {:error, :not_found} =
             FareZones.apply_assignment(
               %{audit | organization_id: organization.id, gtfs_version_id: twin_version.id},
               [
                 %{id: twin.id, from: "T", to: "A"}
               ]
             )

    assert {:error, :not_found} =
             FareZones.apply_assignment(
               %{audit | organization_id: organization.id, gtfs_version_id: staging_version.id},
               [
                 %{id: alpha.id, from: "B", to: "A"}
               ]
             )

    assert {:error, :forbidden} =
             FareZones.apply_assignment(
               %{audit | organization_id: "not-a-uuid", gtfs_version_id: version.id},
               [
                 %{id: alpha.id, from: "B", to: "A"}
               ]
             )

    assert {:error, :not_found} =
             FareZones.undo_assignment(
               %{audit | organization_id: organization.id, gtfs_version_id: staging_version.id},
               applied
             )

    assert zone_of(alpha.id) == "B"
    assert zone_of(twin.id) == "T"
    assert zone_of(sibling.id) == "V"
    assert zone_of(bravo.id) == "B"

    assert {:ok, %{applied: _}} =
             FareZones.undo_assignment(audit, applied)

    assert zone_of(alpha.id) == "A"
    assert zone_of(twin.id) == "T"
    assert zone_of(sibling.id) == "V"
  end

  defp zone_of(id), do: Repo.get!(Stop, id).zone_id

  defp updated_at(id), do: Repo.get!(Stop, id).updated_at

  defp set_zone(id, zone_id) do
    Repo.update_all(from(s in Stop, where: s.id == ^id), set: [zone_id: zone_id])
  end

  defp inventory_zone_ids(organization, version) do
    organization.id
    |> FareZones.inventory(version.id)
    |> Map.fetch!(:zones)
    |> Enum.map(& &1.zone_id)
  end

  # The publication-state check constraint pairs `published_at` with the
  # published status, so staging requires clearing the timestamp.
  defp stage(version) do
    Repo.update_all(from(v in GtfsVersion, where: v.id == ^version.id),
      set: [publication_status: "staging", published_at: nil]
    )

    Repo.get!(GtfsVersion, version.id)
  end

  # Stops are seeded with an hour-old `updated_at`, so the assignment's timestamp
  # write is observable without depending on clock resolution.
  defp insert_stops(organization, version, stops) do
    seeded_at = DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.add(-3600)

    rows =
      Enum.map(stops, fn stop ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: stop.stop_id,
          stop_name: Map.get(stop, :stop_name, "Stop #{stop.stop_id}"),
          location_type: Map.get(stop, :location_type, 0),
          zone_id: Map.get(stop, :zone_id),
          parent_station: Map.get(stop, :parent_station),
          platform_code: Map.get(stop, :platform_code),
          inserted_at: seeded_at,
          updated_at: seeded_at
        }
      end)

    {count, nil} = Repo.insert_all(Stop, rows)
    assert count == length(rows)
    rows
  end

  defp insert_fare_zone(organization, version, zone_id, name, color) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {1, nil} =
      Repo.insert_all(FareZone, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          zone_id: zone_id,
          name: name,
          color: color,
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_fare_rule(organization, version, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row =
      Enum.into(attrs, %{
        id: Ecto.UUID.generate(),
        organization_id: organization.id,
        gtfs_version_id: version.id,
        fare_id: "F",
        route_id: nil,
        origin_id: nil,
        destination_id: nil,
        contains_id: nil,
        inserted_at: now,
        updated_at: now
      })

    {1, nil} = Repo.insert_all(FareRule, [row])
  end
end

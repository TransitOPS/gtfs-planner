defmodule GtfsPlanner.Gtfs.FareZones.ZoneDeletionTest do
  @moduledoc """
  Merge evidence (EV-9) for deleting a zone with a replacement: the zone's stops
  of every location type move to the replacement, its fare-rule references are
  rewritten and deduplicated byte-for-byte, and stale, unsafe or out-of-inventory
  requests write nothing.

  Every expected value below is hand-written fixture data, never a value the
  production queries derived. Stops and fare rules are seeded with an hour-old
  `updated_at`, so a rewrite's timestamp update is observable and an untouched
  row's timestamp proves it was not rewritten. The `" A"` case keeps a padded
  imported ID beside the different zone `"A"`, so a trimming implementation is
  observable. The twin organization and a second version of the same organization
  carry identical zone, stop and rule IDs, so a missing scope predicate is
  observable. The atomicity case wraps the production call in a caller
  transaction and aborts it, which the SQL Sandbox resolves to a savepoint, so
  the whole deletion must disappear while the seeded state stays usable.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.VersionsFixtures

  setup do
    organization = OrganizationsFixtures.organization_fixture()
    version = VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "moves a zone's platforms and stations to the replacement and removes its record", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")

    [platform, station, other_platform, unassigned] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "S-1", stop_name: "Central Station", location_type: 1, zone_id: "A"},
        %{stop_id: "p-2", zone_id: "B"},
        %{stop_id: "p-3", zone_id: nil}
      ])

    assert {:ok, %{moved_stops: 2, rewritten_rows: 0, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 0
             })

    assert zone_of(platform.id) == "B"
    assert zone_of(station.id) == "B"
    assert zone_of(other_platform.id) == "B"
    assert zone_of(unassigned.id) == nil

    # only the two moved rows took the write's timestamp
    assert DateTime.compare(stop_updated_at(platform.id), platform.updated_at) == :gt
    assert DateTime.compare(stop_updated_at(station.id), station.updated_at) == :gt
    assert stop_updated_at(other_platform.id) == other_platform.updated_at
    assert stop_updated_at(unassigned.id) == unassigned.updated_at

    assert [record] = fare_zone_records(organization, version)
    assert record.zone_id == "B"
    assert record.name == "Bayside"
    assert record.color == "teal"
    assert inventory_zone_ids(organization, version) == ["B"]
  end

  test "keeps one row when a rewritten rule becomes identical to an untouched one", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")

    [rewritten, untouched] =
      insert_rules(organization, version, [
        %{fare_id: "F", origin_id: "A", destination_id: "C"},
        %{fare_id: "F", origin_id: "B", destination_id: "C"}
      ])

    assert {:ok, %{moved_stops: 0, rewritten_rows: 0, removed_duplicate_rows: 1}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 0,
               rule_count: 1
             })

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F",
               route_id: nil,
               origin_id: "B",
               destination_id: "C",
               contains_id: nil
             }
           ]

    # the survivor is the untouched row, bytes and timestamp alike; the
    # rewritten original is gone rather than left beside it
    assert [survivor] = fare_rule_records(organization, version)
    assert survivor.id == untouched.id
    assert survivor.updated_at == untouched.updated_at
    refute Repo.exists?(from(r in FareRule, where: r.id == ^rewritten.id))
  end

  test "turns a contains rule that lists the zone into one row", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")

    insert_rules(organization, version, [
      %{fare_id: "F", origin_id: "A", contains_id: "A"},
      %{fare_id: "F", origin_id: "A", contains_id: "B"}
    ])

    assert {:ok, %{moved_stops: 0, rewritten_rows: 1, removed_duplicate_rows: 1}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 0,
               rule_count: 1
             })

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F",
               route_id: nil,
               origin_id: "B",
               destination_id: nil,
               contains_id: "B"
             }
           ]
  end

  test "rewrites every rule column and leaves no row with the deleted ID", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")
    [platform] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])

    [origin_row, destination_row, contains_row, neighbour, same_replacement] =
      insert_rules(organization, version, [
        %{fare_id: "F1", origin_id: "A"},
        %{fare_id: "F2", destination_id: "A"},
        %{fare_id: "F3", contains_id: "A"},
        %{fare_id: "F4 ", route_id: "R ", origin_id: "Z ", contains_id: "Z0 "},
        %{fare_id: "F5", origin_id: "B"}
      ])

    assert {:ok, %{moved_stops: 1, rewritten_rows: 3, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 3
             })

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F1",
               route_id: nil,
               origin_id: "B",
               destination_id: nil,
               contains_id: nil
             },
             %{
               fare_id: "F2",
               route_id: nil,
               origin_id: nil,
               destination_id: "B",
               contains_id: nil
             },
             %{
               fare_id: "F3",
               route_id: nil,
               origin_id: nil,
               destination_id: nil,
               contains_id: "B"
             },
             %{
               fare_id: "F4 ",
               route_id: "R ",
               origin_id: "Z ",
               destination_id: nil,
               contains_id: "Z0 "
             },
             %{
               fare_id: "F5",
               route_id: nil,
               origin_id: "B",
               destination_id: nil,
               contains_id: nil
             }
           ]

    # the rows that already carried the replacement, and the row mentioning
    # neither zone, keep their bytes, IDs and timestamps
    assert Repo.get!(FareRule, neighbour.id).updated_at == neighbour.updated_at
    assert Repo.get!(FareRule, same_replacement.id).updated_at == same_replacement.updated_at

    for row <- [origin_row, destination_row, contains_row] do
      refute Repo.exists?(from(r in FareRule, where: r.id == ^row.id))
    end

    refute Enum.any?(fare_rule_rows(organization, version), fn row ->
             "A" in [row.origin_id, row.destination_id, row.contains_id]
           end)

    assert zone_of(platform.id) == "B"
  end

  test "keeps a contains group intact and leaves no orphan rows", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")

    insert_rules(organization, version, [
      %{fare_id: "F", origin_id: "A"},
      %{fare_id: "F", origin_id: "A", contains_id: "C"},
      %{fare_id: "F", origin_id: "A", contains_id: "D"},
      %{fare_id: "G", origin_id: "B", contains_id: "C"},
      %{fare_id: "G", origin_id: "B", contains_id: "D"}
    ])

    assert {:ok, %{moved_stops: 0, rewritten_rows: 3, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 0,
               rule_count: 2
             })

    groups = FareZones.list_rule_groups(organization.id, version.id)

    assert Enum.map(groups, & &1.key) == [
             {"F", nil, "B", nil, false},
             {"F", nil, "B", nil, true},
             {"G", nil, "B", nil, true}
           ]

    assert %{contains: ["C", "D"], rows: two_rows} =
             Enum.find(groups, &(&1.key == {"F", nil, "B", nil, true}))

    assert length(two_rows) == 2

    assert %{contains: [], rows: [_one_row]} =
             Enum.find(groups, &(&1.key == {"F", nil, "B", nil, false}))

    assert %{contains: ["C", "D"], rows: untouched_rows} =
             Enum.find(groups, &(&1.key == {"G", nil, "B", nil, true}))

    assert length(untouched_rows) == 2

    # every row belongs to exactly one group, so nothing was orphaned
    row_ids = groups |> Enum.flat_map(& &1.rows) |> Enum.map(& &1.id)
    assert length(row_ids) == length(Enum.uniq(row_ids))
    assert length(row_ids) == length(fare_rule_rows(organization, version))

    # no group references the deleted ID
    refute Enum.any?(groups, fn group ->
             "A" in [group.origin_id, group.destination_id | group.contains]
           end)
  end

  test "refuses a rule-referenced zone with no replacement and writes nothing", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    [platform] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])
    insert_rules(organization, version, [%{fare_id: "F", origin_id: "A", destination_id: "C"}])

    before = database_state(organization, version)

    # the stale fence runs first: the dialog's counts are checked before the
    # missing replacement is considered
    assert {:error, {:stale, zone}} =
             FareZones.delete_zone(organization.id, version.id, "A", nil, %{
               stop_count: 0,
               rule_count: 1
             })

    assert zone.stop_count == 1

    assert {:error, :replacement_required} =
             FareZones.delete_zone(organization.id, version.id, "A", nil, %{
               stop_count: 1,
               rule_count: 1
             })

    assert database_state(organization, version) == before
    assert zone_of(platform.id) == "A"
  end

  test "unassigns an unreferenced zone's stops when the replacement is nil", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "D", "Downtown", "ocean")

    [platform, station, other] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "D"},
        %{stop_id: "S-1", location_type: 1, zone_id: "D"},
        %{stop_id: "p-2", zone_id: nil}
      ])

    assert {:ok, %{moved_stops: 2, rewritten_rows: 0, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, "D", nil, %{
               stop_count: 1,
               rule_count: 0
             })

    assert zone_of(platform.id) == nil
    assert zone_of(station.id) == nil
    assert zone_of(other.id) == nil
    assert fare_zone_records(organization, version) == []
    assert inventory_zone_ids(organization, version) == []

    assert %{unassigned_count: 2, boardable_count: 2} =
             FareZones.inventory(organization.id, version.id)
  end

  test "refuses a replacement that is the zone itself, blank or outside the inventory", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    [platform] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])

    # B is a real inventory zone carried by a stop alone, so the refusals below
    # are about the request, not about the replacement being absent
    [implicit] = insert_stops(organization, version, [%{stop_id: "p-2", zone_id: "B"}])

    before = database_state(organization, version)

    for replacement <- ["A", "NOPE", ""] do
      assert {:error, :invalid_replacement} =
               FareZones.delete_zone(organization.id, version.id, "A", replacement, %{
                 stop_count: 1,
                 rule_count: 0
               }),
             "expected replacement #{inspect(replacement)} to be refused"
    end

    assert database_state(organization, version) == before
    assert "B" in inventory_zone_ids(organization, version)
    assert zone_of(platform.id) == "A"
    assert zone_of(implicit.id) == "B"
  end

  test "refuses expected counts that no longer match and writes nothing", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")
    [platform] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])
    insert_rules(organization, version, [%{fare_id: "F", origin_id: "A", destination_id: "C"}])

    before = database_state(organization, version)

    # the dialog showed 0 stops; a stop was assigned after it opened
    assert {:error, {:stale, zone}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 0,
               rule_count: 1
             })

    assert zone == %{
             zone_id: "A",
             name: "Downtown",
             color: "ocean",
             declared?: true,
             stop_count: 1,
             other_stop_count: 0,
             rule_count: 1
           }

    # the dialog showed 0 rules; a rule was added after it opened
    assert {:error, {:stale, %{rule_count: 1}}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 0
             })

    assert database_state(organization, version) == before

    # the refusals left the zone usable: the correct counts delete it
    assert {:ok, %{moved_stops: 1, rewritten_rows: 1, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 1
             })

    assert zone_of(platform.id) == "B"

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F",
               route_id: nil,
               origin_id: "B",
               destination_id: "C",
               contains_id: nil
             }
           ]

    # the rule's destination zone 'C' is still in the inventory beside 'B'
    assert inventory_zone_ids(organization, version) == ["B", "C"]
  end

  test "returns not_found for a zone outside the inventory and writes nothing", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    [platform] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])

    before = database_state(organization, version)

    assert {:error, :not_found} =
             FareZones.delete_zone(organization.id, version.id, "GHOST", nil, %{
               stop_count: 0,
               rule_count: 0
             })

    assert database_state(organization, version) == before

    # a zone a rename removed from the inventory cannot be deleted afterwards
    assert {:ok, renamed} =
             FareZones.update_zone(organization.id, version.id, "A", %{
               "zone_id" => "B",
               "name" => "Bayside",
               "color" => "teal"
             })

    assert renamed.zone_id == "B"
    after_rename = database_state(organization, version)

    assert {:error, :not_found} =
             FareZones.delete_zone(organization.id, version.id, "A", nil, %{
               stop_count: 1,
               rule_count: 0
             })

    assert database_state(organization, version) == after_rename
    assert zone_of(platform.id) == "B"
    refute "A" in inventory_zone_ids(organization, version)
  end

  test "leaves twin scopes unchanged and refuses a mismatched pair", %{
    organization: organization,
    version: version
  } do
    twin_organization = OrganizationsFixtures.organization_fixture()
    twin_version = VersionsFixtures.gtfs_version_fixture(twin_organization.id)
    other_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    staging_version = stage(VersionsFixtures.gtfs_version_fixture(organization.id))

    insert_fare_zone(organization, version, "A", "Main", "ocean")

    insert_stops(organization, version, [
      %{stop_id: "p-1", zone_id: "A"},
      %{stop_id: "S-1", location_type: 1, zone_id: "A"},
      %{stop_id: "p-2", zone_id: "B"}
    ])

    insert_rules(organization, version, [%{fare_id: "F", origin_id: "A"}])

    insert_fare_zone(twin_organization, twin_version, "A", "Main", "ocean")
    insert_fare_zone(organization, other_version, "A", "Main", "ocean")

    insert_stops(twin_organization, twin_version, [
      %{stop_id: "p-1", zone_id: "A"},
      %{stop_id: "S-1", location_type: 1, zone_id: "A"},
      %{stop_id: "p-2", zone_id: "B"}
    ])

    insert_stops(organization, other_version, [
      %{stop_id: "p-1", zone_id: "A"},
      %{stop_id: "S-1", location_type: 1, zone_id: "A"},
      %{stop_id: "p-2", zone_id: "B"}
    ])

    insert_rules(twin_organization, twin_version, [%{fare_id: "F", origin_id: "A"}])
    insert_rules(organization, other_version, [%{fare_id: "F", origin_id: "A"}])

    twin_organization_before = database_state(twin_organization, twin_version)
    other_version_before = database_state(organization, other_version)

    assert {:ok, %{moved_stops: 2, rewritten_rows: 1, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 1
             })

    assert database_state(twin_organization, twin_version) == twin_organization_before
    assert database_state(organization, other_version) == other_version_before

    assert {:error, :not_found} =
             FareZones.delete_zone(twin_organization.id, version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 1
             })

    assert {:error, :not_found} =
             FareZones.delete_zone(organization.id, twin_version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 1
             })

    assert {:error, :not_found} =
             FareZones.delete_zone(organization.id, staging_version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 1
             })

    assert {:error, :not_found} =
             FareZones.delete_zone("not-a-uuid", version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 1
             })

    assert database_state(twin_organization, twin_version) == twin_organization_before
    assert database_state(organization, other_version) == other_version_before
    assert inventory_zone_ids(organization, version) == ["B"]
  end

  test "deletes the padded imported ID without trimming any bytes", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, " A", "Imported", "plum")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")

    [padded_platform, trimmed_platform, station] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: " A"},
        %{stop_id: "p-2", zone_id: "A"},
        %{stop_id: "S-1", location_type: 1, zone_id: " A"}
      ])

    [padded_rule, trimmed_rule, padded_contains] =
      insert_rules(organization, version, [
        %{fare_id: "F1", origin_id: " A"},
        %{fare_id: "F2", origin_id: "A", contains_id: "X"},
        %{fare_id: "F3 ", origin_id: " A", contains_id: " A"}
      ])

    assert {:ok, %{moved_stops: 2, rewritten_rows: 2, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, " A", "B", %{
               stop_count: 1,
               rule_count: 2
             })

    assert zone_of(padded_platform.id) == "B"
    assert zone_of(station.id) == "B"

    # "A" is a different zone and neither moved nor was rewritten
    assert zone_of(trimmed_platform.id) == "A"

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F1",
               route_id: nil,
               origin_id: "B",
               destination_id: nil,
               contains_id: nil
             },
             %{
               fare_id: "F2",
               route_id: nil,
               origin_id: "A",
               destination_id: nil,
               contains_id: "X"
             },
             %{
               fare_id: "F3 ",
               route_id: nil,
               origin_id: "B",
               destination_id: nil,
               contains_id: "B"
             }
           ]

    assert Repo.get!(FareRule, trimmed_rule.id).updated_at == trimmed_rule.updated_at

    for row <- [padded_rule, padded_contains] do
      refute Repo.exists?(from(r in FareRule, where: r.id == ^row.id))
    end

    refute Enum.any?(fare_rule_rows(organization, version), fn row ->
             " A" in [row.origin_id, row.destination_id, row.contains_id]
           end)

    assert Enum.map(fare_zone_records(organization, version), & &1.zone_id) == ["B"]

    # 'A' survives as the different zone of p-2 and of the F2 origin, 'X' as the
    # F2 contains reference; the padded ' A' is gone
    assert inventory_zone_ids(organization, version) == ["A", "B", "X"]
  end

  test "rolls the whole deletion back when the caller's transaction aborts", %{
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    insert_fare_zone(organization, version, "B", "Bayside", "teal")
    [platform] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])
    insert_rules(organization, version, [%{fare_id: "F", origin_id: "A"}])

    before = database_state(organization, version)

    assert {:error, :aborted} =
             Repo.transaction(fn ->
               assert {:ok, %{moved_stops: 1, rewritten_rows: 1, removed_duplicate_rows: 0}} =
                        FareZones.delete_zone(organization.id, version.id, "A", "B", %{
                          stop_count: 1,
                          rule_count: 1
                        })

               # the writes are visible inside the transaction and go away with it
               assert zone_of(platform.id) == "B"
               assert inventory_zone_ids(organization, version) == ["B"]

               Repo.rollback(:aborted)
             end)

    assert database_state(organization, version) == before
    assert zone_of(platform.id) == "A"
    assert inventory_zone_ids(organization, version) == ["A", "B"]

    # the prior state stayed usable: the same call now commits
    assert {:ok, %{moved_stops: 1, rewritten_rows: 1, removed_duplicate_rows: 0}} =
             FareZones.delete_zone(organization.id, version.id, "A", "B", %{
               stop_count: 1,
               rule_count: 1
             })

    assert zone_of(platform.id) == "B"
    refute "A" in inventory_zone_ids(organization, version)
  end

  defp zone_of(id), do: Repo.get!(Stop, id).zone_id

  defp stop_updated_at(id), do: Repo.get!(Stop, id).updated_at

  defp fare_zone_records(organization, version) do
    Repo.all(
      from(z in FareZone,
        where: z.organization_id == ^organization.id and z.gtfs_version_id == ^version.id,
        order_by: z.zone_id
      )
    )
  end

  defp fare_rule_records(organization, version) do
    Repo.all(
      from(r in FareRule,
        where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id,
        order_by: [r.fare_id, r.id]
      )
    )
  end

  defp fare_rule_rows(organization, version) do
    Enum.map(fare_rule_records(organization, version), fn row ->
      %{
        fare_id: row.fare_id,
        route_id: row.route_id,
        origin_id: row.origin_id,
        destination_id: row.destination_id,
        contains_id: row.contains_id
      }
    end)
  end

  defp stop_rows(organization, version) do
    Repo.all(
      from(s in Stop,
        where: s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id,
        order_by: s.stop_id,
        select: %{
          id: s.id,
          stop_id: s.stop_id,
          location_type: s.location_type,
          zone_id: s.zone_id,
          updated_at: s.updated_at
        }
      )
    )
  end

  # Every column a deletion may touch, with IDs and timestamps, so "writes
  # nothing" and "leaves the twin alone" are byte-level comparisons.
  defp database_state(organization, version) do
    %{
      records:
        Enum.map(fare_zone_records(organization, version), fn record ->
          Map.take(record, [:id, :zone_id, :name, :color, :inserted_at, :updated_at])
        end),
      rules:
        Enum.map(fare_rule_records(organization, version), fn row ->
          Map.take(row, [
            :id,
            :fare_id,
            :route_id,
            :origin_id,
            :destination_id,
            :contains_id,
            :inserted_at,
            :updated_at
          ])
        end),
      stops: stop_rows(organization, version)
    }
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

  # Stops and rules are seeded with an hour-old `updated_at` on a whole second,
  # so a write's timestamp update is observable without depending on clock
  # resolution. The `stops` table stores second precision and rounds, so the seed
  # must land on a second and carry the microsecond precision the schema expects.
  defp seeded_at do
    at = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
    %{at | microsecond: {0, 6}}
  end

  defp insert_stops(organization, version, stops) do
    seeded = seeded_at()

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
          inserted_at: seeded,
          updated_at: seeded
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

  defp insert_rules(organization, version, rules) do
    seeded = seeded_at()

    rows =
      Enum.map(rules, fn rule ->
        Enum.into(rule, %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: "F",
          route_id: nil,
          origin_id: nil,
          destination_id: nil,
          contains_id: nil,
          inserted_at: seeded,
          updated_at: seeded
        })
      end)

    {count, nil} = Repo.insert_all(FareRule, rows)
    assert count == length(rows)
    rows
  end
end

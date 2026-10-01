defmodule GtfsPlanner.Gtfs.FareZones.ZoneEditingTest do
  @moduledoc """
  Merge evidence (EV-8) for creating and editing zones: creation validation and
  uniqueness, byte-exact metadata edits, ID changes that move stops of every
  location type and every fare-rule zone reference, and refusal paths that write
  nothing.

  Every expected value below is hand-written fixture data or an independent
  `FareZone.default_color/1` call, so the production queries cannot confirm their
  own output. The `" A"` case enters through the real `Import.import_files/3` and
  leaves through the real `Export.export_to_zip/3`, so the byte-exact claim is
  observed on the exported files rather than on the writer's own return value.
  Seeds use an hour-old `updated_at`, so the writes' timestamp updates are
  observable without depending on clock resolution, and the twin organization and
  a second version of the same organization carry identical zone, stop and
  fare-rule IDs, so a missing scope predicate is observable.

  The case is deliberately not `async: true`: the real importer and exporter run
  inside it, following `test/gtfs_planner/gtfs/fare_zone_import_export_test.exs`.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Import.CsvParser
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Support.StagedImport
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.VersionsFixtures

  @in_use_message "That zone ID is already in use. Choose another."
  @format_message "Use 1–64 letters, numbers, hyphens or underscores."

  @stops_header "stop_id,stop_name,stop_desc,stop_lat,stop_lon,zone_id," <>
                  "location_type,parent_station,wheelchair_boarding,platform_code,level_id"

  @fare_rules_header "fare_id,route_id,origin_id,destination_id,contains_id"

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

  test "creates a zone from trimmed input and returns its inventory entry", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    assert {:ok, zone} =
             FareZones.create_zone(audit, %{
               "name" => "  Central  ",
               "zone_id" => "  A  ",
               "color" => "ocean"
             })

    assert zone == %{
             zone_id: "A",
             name: "Central",
             color: "ocean",
             declared?: true,
             stop_count: 0,
             other_stop_count: 0,
             rule_count: 0
           }

    assert [record] = fare_zone_records(organization, version)
    assert record.zone_id == "A"
    assert record.name == "Central"
    assert record.color == "ocean"
  end

  test "rejects an ID an inventory source already carries and writes nothing", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])
    insert_rules(organization, version, [%{fare_id: "F1", origin_id: "R"}])
    insert_fare_zone(organization, version, "D", "Downtown", "plum")

    for {zone_id, source} <- [{"A", "a stop"}, {"R", "a fare rule"}, {"D", "a record"}] do
      assert {:error, changeset} =
               FareZones.create_zone(audit, %{
                 "name" => "Central",
                 "zone_id" => zone_id,
                 "color" => "ocean"
               })

      refute changeset.valid?, "expected #{source} ID #{zone_id} to be rejected"
      assert errors_on(changeset).zone_id == [@in_use_message]
    end

    # the padded form of the same ID is trimmed before the check
    assert {:error, padded} =
             FareZones.create_zone(audit, %{
               "name" => "Central",
               "zone_id" => " D ",
               "color" => "ocean"
             })

    assert errors_on(padded).zone_id == [@in_use_message]

    assert Enum.map(fare_zone_records(organization, version), & &1.zone_id) == ["D"]
  end

  test "rejects an ID outside the safe-character format and writes nothing", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    for zone_id <- ["zone.1", String.duplicate("a", 65), "  "] do
      assert {:error, changeset} =
               FareZones.create_zone(audit, %{
                 "name" => "Central",
                 "zone_id" => zone_id,
                 "color" => "ocean"
               })

      refute changeset.valid?
      assert Map.has_key?(errors_on(changeset), :zone_id)
    end

    assert {:error, changeset} =
             FareZones.create_zone(audit, %{
               "name" => "Central",
               "zone_id" => "zone.1",
               "color" => "ocean"
             })

    assert errors_on(changeset).zone_id == [@format_message]
    assert fare_zone_records(organization, version) == []
  end

  test "names the implicit zone \" A\" and the full export keeps its bytes", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    assert {:ok, result} = StagedImport.import_files(organization.id, version.id, import_files())
    assert result.counts[:stops] == 3
    assert result.counts[:fare_rules] == 2

    assert {:ok, zone} =
             FareZones.update_zone(audit, " A", %{"name" => "Central"})

    assert zone == %{
             zone_id: " A",
             name: "Central",
             color: FareZone.default_color(" A"),
             declared?: true,
             stop_count: 1,
             other_stop_count: 1,
             rule_count: 1
           }

    assert [record] = fare_zone_records(organization, version)
    assert record.zone_id == " A"
    assert record.name == "Central"

    # the drawer re-sends the imported ID verbatim; the exact bytes are neither
    # trimmed nor validated, so " A" is not renamed into the different zone "A"
    assert {:ok, resent} =
             FareZones.update_zone(audit, " A", %{
               "zone_id" => " A",
               "name" => "Central",
               "color" => "teal"
             })

    assert resent.zone_id == " A"
    assert resent.name == "Central"
    assert resent.color == "teal"

    # "A" is a different zone: it keeps its own name and stays undeclared
    trimmed = Enum.find(inventory_zones(organization, version), &(&1.zone_id == "A"))

    assert trimmed == %{
             zone_id: "A",
             name: "A",
             color: FareZone.default_color("A"),
             declared?: false,
             stop_count: 1,
             other_stop_count: 0,
             rule_count: 1
           }

    assert {:ok, zip} = Export.export_to_zip(organization.id, version.id, :full)
    entries = unzip(zip)

    assert exported_zones(entries) == %{"P1" => " A", "P2" => "A", "S1" => " A"}
    assert exported_rule_origins(entries) == %{"F1" => " A", "F2" => "A"}
  end

  test "an ID change moves stops of every location type and all three rule columns", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")

    [platform, station] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "S-1", stop_name: "Central Station", location_type: 1, zone_id: "A"}
      ])

    rules =
      insert_rules(organization, version, [
        %{fare_id: "F1", origin_id: "A"},
        %{fare_id: "F2", destination_id: "A"},
        %{fare_id: "F3", contains_id: "A"},
        %{fare_id: "F4", origin_id: "Z"}
      ])

    [f1, _f2, _f3, f4] = rules

    assert {:ok, zone} =
             FareZones.update_zone(audit, "A", %{
               "zone_id" => " B ",
               "name" => "Bayside",
               "color" => "green"
             })

    assert zone == %{
             zone_id: "B",
             name: "Bayside",
             color: "green",
             declared?: true,
             stop_count: 1,
             other_stop_count: 1,
             rule_count: 3
           }

    assert zone_of(platform.id) == "B"
    assert zone_of(station.id) == "B"

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
               fare_id: "F4",
               route_id: nil,
               origin_id: "Z",
               destination_id: nil,
               contains_id: nil
             }
           ]

    assert [record] = fare_zone_records(organization, version)
    assert record.zone_id == "B"
    assert record.name == "Bayside"
    assert record.color == "green"
    assert inventory_zone_ids(organization, version) == ["B", "Z"]

    # rewritten rows carry a new timestamp, the untouched row keeps its seed
    assert DateTime.compare(stop_updated_at(platform.id), platform.updated_at) == :gt
    assert DateTime.compare(stop_updated_at(station.id), station.updated_at) == :gt
    assert DateTime.compare(rule_updated_at(f1.id), f1.updated_at) == :gt
    assert rule_updated_at(f4.id) == f4.updated_at
  end

  test "a metadata edit keeps an imported ID's bytes and never revalidates it", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [stop] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "Zone 1"}])

    # the drawer sends the current ID back unchanged
    assert {:ok, zone} =
             FareZones.update_zone(audit, "Zone 1", %{
               "zone_id" => "Zone 1",
               "name" => "Downtown",
               "color" => "teal"
             })

    assert zone.zone_id == "Zone 1"
    assert zone.declared?
    assert zone.name == "Downtown"
    assert zone_of(stop.id) == "Zone 1"

    # padding that trims back to the stored ID is not a rename: the bytes stay
    assert {:ok, same} =
             FareZones.update_zone(audit, "Zone 1", %{
               "zone_id" => " Zone 1 ",
               "name" => "Old town"
             })

    assert same.zone_id == "Zone 1"
    assert same.name == "Old town"
    assert zone_of(stop.id) == "Zone 1"
    assert Enum.map(fare_zone_records(organization, version), & &1.zone_id) == ["Zone 1"]
  end

  test "an ID change to an ID the inventory already carries writes nothing", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")
    [platform] = insert_stops(organization, version, [%{stop_id: "p-1", zone_id: "A"}])
    insert_stops(organization, version, [%{stop_id: "p-2", zone_id: "C"}])
    insert_rules(organization, version, [%{fare_id: "F1", origin_id: "A", destination_id: "C"}])

    assert {:error, changeset} =
             FareZones.update_zone(audit, "A", %{"zone_id" => "C"})

    assert errors_on(changeset).zone_id == [@in_use_message]

    assert {:error, padded} =
             FareZones.update_zone(audit, "A", %{"zone_id" => " C "})

    assert errors_on(padded).zone_id == [@in_use_message]

    assert zone_of(platform.id) == "A"

    assert [record] = fare_zone_records(organization, version)
    assert record.zone_id == "A"
    assert record.name == "Downtown"

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F1",
               route_id: nil,
               origin_id: "A",
               destination_id: "C",
               contains_id: nil
             }
           ]
  end

  test "an invalid rename writes nothing and leaves the zone editable", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fare_zone(organization, version, "A", "Downtown", "ocean")

    [platform, station] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "S-1", location_type: 1, zone_id: "A"}
      ])

    insert_rules(organization, version, [%{fare_id: "F1", origin_id: "A", contains_id: "A"}])

    assert {:error, changeset} =
             FareZones.update_zone(audit, "A", %{
               "zone_id" => "B",
               "name" => String.duplicate("n", 61),
               "color" => "ocean"
             })

    refute changeset.valid?
    assert [_ | _] = errors_on(changeset).name

    assert zone_of(platform.id) == "A"
    assert zone_of(station.id) == "A"

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F1",
               route_id: nil,
               origin_id: "A",
               destination_id: nil,
               contains_id: "A"
             }
           ]

    assert Enum.map(fare_zone_records(organization, version), & &1.zone_id) == ["A"]
    assert inventory_zone_ids(organization, version) == ["A"]

    # the failed rename left the zone usable: the metadata edit still applies
    assert {:ok, zone} =
             FareZones.update_zone(audit, "A", %{"name" => "Renamed"})

    assert zone.name == "Renamed"
    assert zone.zone_id == "A"
  end

  test "an edit of a zone that left the inventory writes nothing and creates no record", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    [mover, _keeper] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "p-2", zone_id: "B"}
      ])

    assert {:ok, %{changes: changes}} =
             FareZones.preview_assignment(organization.id, version.id, [mover.id], "B")

    assert {:ok, %{applied: _}} =
             FareZones.apply_assignment(audit, changes)

    refute "A" in inventory_zone_ids(organization, version)

    assert {:error, :not_found} =
             FareZones.update_zone(audit, "A", %{"name" => "Ghost"})

    assert {:error, :not_found} =
             FareZones.update_zone(audit, "A", %{
               "zone_id" => "G",
               "name" => "Ghost",
               "color" => "plum"
             })

    assert fare_zone_records(organization, version) == []
    assert inventory_zone_ids(organization, version) == ["B"]
  end

  test "leaves twin scopes unchanged and refuses a non-published pair", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    twin_organization = OrganizationsFixtures.organization_fixture()
    AccountsFixtures.organization_membership_fixture(%{id: audit.actor_id}, twin_organization)
    twin_version = VersionsFixtures.gtfs_version_fixture(twin_organization.id)
    other_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    staging_version = stage(VersionsFixtures.gtfs_version_fixture(organization.id))

    insert_fare_zone(organization, version, "A", "Main", "green")

    [platform, station] =
      insert_stops(organization, version, [
        %{stop_id: "p-1", zone_id: "A"},
        %{stop_id: "S-1", location_type: 1, zone_id: "A"}
      ])

    insert_rules(organization, version, [%{fare_id: "F1", origin_id: "A"}])

    insert_fare_zone(twin_organization, twin_version, "A", "Twin", "teal")

    insert_stops(twin_organization, twin_version, [
      %{stop_id: "p-1", zone_id: "A"},
      %{stop_id: "S-1", location_type: 1, zone_id: "A"}
    ])

    insert_rules(twin_organization, twin_version, [%{fare_id: "F1", origin_id: "A"}])

    insert_fare_zone(organization, other_version, "A", "Sibling", "plum")
    insert_stops(organization, other_version, [%{stop_id: "p-1", zone_id: "A"}])
    insert_rules(organization, other_version, [%{fare_id: "F1", origin_id: "A"}])

    assert {:ok, created} =
             FareZones.create_zone(audit, %{
               "name" => "New",
               "zone_id" => "NEW",
               "color" => "ocean"
             })

    assert created.zone_id == "NEW"

    assert {:ok, renamed} =
             FareZones.update_zone(audit, "A", %{"zone_id" => "OLD"})

    assert renamed.zone_id == "OLD"
    assert renamed.declared?
    assert renamed.name == "Main"
    assert zone_of(platform.id) == "OLD"
    assert zone_of(station.id) == "OLD"
    assert inventory_zone_ids(organization, version) == ["NEW", "OLD"]

    assert {:error, :not_found} =
             FareZones.create_zone(
               %{audit | organization_id: twin_organization.id, gtfs_version_id: version.id},
               %{
                 "name" => "Clash",
                 "zone_id" => "CLASH",
                 "color" => "ocean"
               }
             )

    assert {:error, :not_found} =
             FareZones.create_zone(
               %{audit | organization_id: organization.id, gtfs_version_id: twin_version.id},
               %{
                 "name" => "Clash",
                 "zone_id" => "CLASH",
                 "color" => "ocean"
               }
             )

    assert {:error, :not_found} =
             FareZones.create_zone(
               %{audit | organization_id: organization.id, gtfs_version_id: staging_version.id},
               %{
                 "name" => "Clash",
                 "zone_id" => "CLASH",
                 "color" => "ocean"
               }
             )

    assert {:error, :forbidden} =
             FareZones.create_zone(
               %{audit | organization_id: "not-a-uuid", gtfs_version_id: version.id},
               %{
                 "name" => "Clash",
                 "zone_id" => "CLASH",
                 "color" => "ocean"
               }
             )

    assert {:error, :not_found} =
             FareZones.update_zone(
               %{audit | organization_id: twin_organization.id, gtfs_version_id: version.id},
               "A",
               %{"name" => "Clash"}
             )

    assert {:error, :not_found} =
             FareZones.update_zone(
               %{audit | organization_id: organization.id, gtfs_version_id: twin_version.id},
               "A",
               %{"name" => "Clash"}
             )

    assert {:error, :not_found} =
             FareZones.update_zone(
               %{audit | organization_id: organization.id, gtfs_version_id: staging_version.id},
               "OLD",
               %{
                 "name" => "Clash"
               }
             )

    assert {:error, :forbidden} =
             FareZones.update_zone(
               %{audit | organization_id: "not-a-uuid", gtfs_version_id: version.id},
               "OLD",
               %{"name" => "Clash"}
             )

    assert zone_of(platform.id) == "OLD"
    assert zone_of(station.id) == "OLD"
    assert inventory_zone_ids(organization, version) == ["NEW", "OLD"]

    assert twin_zone_records(twin_organization, twin_version) == [
             %{zone_id: "A", name: "Twin", color: "teal"}
           ]

    assert twin_zone_records(organization, other_version) == [
             %{zone_id: "A", name: "Sibling", color: "plum"}
           ]

    assert twin_stop_zones(twin_organization, twin_version) == %{"p-1" => "A", "S-1" => "A"}
    assert twin_stop_zones(organization, other_version) == %{"p-1" => "A"}
    assert twin_rule_origins(twin_organization, twin_version) == %{"F1" => "A"}
    assert twin_rule_origins(organization, other_version) == %{"F1" => "A"}
  end

  test "change_zone/2 decides the mode the write will use" do
    create =
      FareZones.change_zone(nil, %{
        "zone_id" => " A ",
        "name" => " Central ",
        "color" => "ocean"
      })

    assert create.valid?
    assert get_change(create, :zone_id) == "A"
    assert get_change(create, :name) == "Central"

    invalid =
      FareZones.change_zone(nil, %{
        "zone_id" => "zone.1",
        "name" => "Central",
        "color" => "ocean"
      })

    refute invalid.valid?
    assert errors_on(invalid).zone_id == [@format_message]

    implicit = %FareZone{zone_id: "Zone 1", name: "Zone 1", color: "teal"}

    kept =
      FareZones.change_zone(implicit, %{"zone_id" => "Zone 1", "name" => "Downtown"})

    assert kept.valid?
    refute Map.has_key?(kept.changes, :zone_id)
    assert get_field(kept, :zone_id) == "Zone 1"

    renamed = FareZones.change_zone(implicit, %{"zone_id" => " B ", "name" => "Downtown"})
    assert renamed.valid?
    assert get_change(renamed, :zone_id) == "B"

    padded = FareZones.change_zone(implicit, %{"zone_id" => " Zone 1 ", "name" => "Downtown"})
    assert padded.valid?
    refute Map.has_key?(padded.changes, :zone_id)
    assert get_field(padded, :zone_id) == "Zone 1"

    stored = %FareZone{zone_id: " A", name: "Imported", color: "teal"}

    verbatim = FareZones.change_zone(stored, %{"zone_id" => " A", "name" => "Central"})
    assert verbatim.valid?
    refute Map.has_key?(verbatim.changes, :zone_id)
    assert get_field(verbatim, :zone_id) == " A"
  end

  defp import_files do
    [
      %{
        filename: "stops.txt",
        content: """
        #{@stops_header}
        P1,Platform One,,40.0,-70.0, A,0,,,,
        P2,Platform Two,,40.1,-70.1,A,0,,,,
        S1,Central Station,,40.2,-70.2, A,1,,,,
        """
      },
      %{
        filename: "fare_rules.txt",
        content: """
        #{@fare_rules_header}
        F1,, A,,
        F2,,A,,
        """
      }
    ]
  end

  defp unzip(zip) do
    {:ok, entries} = :zip.unzip(zip, [:memory])
    entries
  end

  defp entry!(entries, filename) do
    case Enum.find(entries, fn {name, _content} -> to_string(name) == filename end) do
      nil -> flunk("expected #{filename} in the export")
      {_name, content} -> to_string(content)
    end
  end

  defp parse!(content, filename) do
    {:ok, parsed} = CsvParser.stream(filename, content)
    Enum.map(parsed.events, fn {:ok, _row_number, row} -> row end)
  end

  defp exported_zones(entries) do
    entries
    |> entry!("stops.txt")
    |> parse!("stops.txt")
    |> Map.new(&{&1["stop_id"], &1["zone_id"]})
  end

  defp exported_rule_origins(entries) do
    entries
    |> entry!("fare_rules.txt")
    |> parse!("fare_rules.txt")
    |> Map.new(&{&1["fare_id"], &1["origin_id"]})
  end

  defp zone_of(id), do: Repo.get!(Stop, id).zone_id

  defp stop_updated_at(id), do: Repo.get!(Stop, id).updated_at

  defp rule_updated_at(id), do: Repo.get!(FareRule, id).updated_at

  defp inventory_zones(organization, version) do
    organization.id
    |> FareZones.inventory(version.id)
    |> Map.fetch!(:zones)
  end

  defp inventory_zone_ids(organization, version) do
    organization |> inventory_zones(version) |> Enum.map(& &1.zone_id)
  end

  defp fare_zone_records(organization, version) do
    Repo.all(
      from(z in FareZone,
        where: z.organization_id == ^organization.id and z.gtfs_version_id == ^version.id,
        order_by: z.zone_id
      )
    )
  end

  defp fare_rule_rows(organization, version) do
    Repo.all(
      from(r in FareRule,
        where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id,
        order_by: r.fare_id,
        select: %{
          fare_id: r.fare_id,
          route_id: r.route_id,
          origin_id: r.origin_id,
          destination_id: r.destination_id,
          contains_id: r.contains_id
        }
      )
    )
  end

  defp twin_zone_records(organization, version) do
    organization
    |> fare_zone_records(version)
    |> Enum.map(&Map.take(&1, [:zone_id, :name, :color]))
  end

  defp twin_stop_zones(organization, version) do
    Repo.all(
      from(s in Stop,
        where: s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id,
        select: {s.stop_id, s.zone_id}
      )
    )
    |> Map.new()
  end

  defp twin_rule_origins(organization, version) do
    organization
    |> fare_rule_rows(version)
    |> Map.new(&{&1.fare_id, &1.origin_id})
  end

  # The publication-state check constraint pairs `published_at` with the
  # published status, so staging requires clearing the timestamp.
  defp stage(version) do
    Repo.update_all(from(v in GtfsVersion, where: v.id == ^version.id),
      set: [publication_status: "staging", published_at: nil]
    )

    Repo.get!(GtfsVersion, version.id)
  end

  # Stops and rules are seeded with an hour-old `updated_at`, so a write's
  # timestamp update is observable without depending on clock resolution.
  defp seeded_at do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.add(-3600)
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

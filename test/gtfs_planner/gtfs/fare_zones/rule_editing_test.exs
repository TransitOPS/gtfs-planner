defmodule GtfsPlanner.Gtfs.FareZones.RuleEditingTest do
  @moduledoc """
  Merge evidence (EV-10) for saving and removing fare rule groups: a save
  replaces exactly the reviewed group's rows, refuses a key another rule holds, a
  fare, route or zone the version does not have, a new reference to a stopless
  zone and a review that changed under it, and writes nothing when it refuses.

  Every expected value below is hand-written fixture data, never a value the
  production projection derived. Rules and stops are seeded with an hour-old
  `updated_at`, so a rewrite's timestamp update is observable and an untouched
  row's timestamp proves it was not rewritten. The `" A"` case keeps a padded
  imported origin beside the different zone `"A"`, so a trimming implementation is
  observable, and the twin organization with a second version of the same
  organization carries identical fare, stop and rule IDs, so a missing scope
  predicate is observable. The stale cases change the version between the review
  and the save: a rename through `FareZones.update_zone/3` and an added group
  member. The atomicity case wraps the production call in a caller transaction
  and aborts it, which the SQL Sandbox resolves to a savepoint.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.FareAttribute
  alias GtfsPlanner.Gtfs.FareRule
  alias GtfsPlanner.Gtfs.FareZone
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.FareZones
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.AccountsFixtures
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Versions.GtfsVersion
  alias GtfsPlanner.VersionsFixtures

  @key_message "A rule with this fare, route, start and end already exists. Edit that rule instead."
  @stopless_message "This zone has no stops yet. Assign stops before using it in a fare rule."

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

  test "creates a rule with no through zones and returns its group", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_routes(organization, version, [%{route_id: "R1", short_name: "10", long_name: "Local"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"}
    ])

    assert {:ok, group} =
             FareZones.save_rule_group(audit, nil, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "A",
               "destination_id" => "B",
               "contains" => []
             })

    assert group.key == {"F", nil, "A", "B", false}
    assert group.contains == []
    assert group.unknown_fare? == false
    assert %{currency_type: "USD"} = group.fare
    assert Decimal.equal?(group.fare.price, Decimal.new("2.50"))
    assert group.route == nil
    assert [%{contains_id: nil}] = group.rows

    assert fare_rule_rows(organization, version) == [
             %{fare_id: "F", route_id: nil, origin_id: "A", destination_id: "B", contains_id: nil}
           ]
  end

  test "edits a group's origin and leaves every neighbouring row byte-identical", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"},
      %{stop_id: "p-c", zone_id: "C"},
      %{stop_id: "p-e", zone_id: "E"},
      %{stop_id: "p-x", zone_id: "X"},
      %{stop_id: "p-y", zone_id: "Y"}
    ])

    [edited, neighbour, through_x, through_y] =
      insert_rules(organization, version, [
        {"F", nil, "A", "B", nil},
        {"F", nil, "C", "B", nil},
        {"F", nil, "A", "B", "X"},
        {"F", nil, "A", "B", "Y"}
      ])

    reviewed = group_for(organization, version, {"F", nil, "A", "B", false})
    assert Enum.map(reviewed.rows, & &1.id) == [edited.id]

    assert {:ok, group} =
             FareZones.save_rule_group(audit, reviewed, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "E",
               "destination_id" => "B",
               "contains" => []
             })

    assert group.key == {"F", nil, "E", "B", false}
    assert [%{id: new_id}] = group.rows
    refute new_id == edited.id

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F",
               route_id: nil,
               origin_id: "A",
               destination_id: "B",
               contains_id: "X"
             },
             %{
               fare_id: "F",
               route_id: nil,
               origin_id: "A",
               destination_id: "B",
               contains_id: "Y"
             },
             %{
               fare_id: "F",
               route_id: nil,
               origin_id: "C",
               destination_id: "B",
               contains_id: nil
             },
             %{
               fare_id: "F",
               route_id: nil,
               origin_id: "E",
               destination_id: "B",
               contains_id: nil
             }
           ]

    refute Repo.exists?(from(r in FareRule, where: r.id == ^edited.id))

    # The neighbour and the through-zone group keep their rows, bytes and
    # timestamps; only the rewritten rule took the write's timestamp.
    for row <- [neighbour, through_x, through_y] do
      assert Repo.get!(FareRule, row.id).updated_at == row.updated_at
    end

    # The rewritten rule took the write's timestamp; the seeded one is an hour old
    assert Repo.get!(FareRule, new_id).updated_at != edited.updated_at
  end

  test "writes one row per contains zone sharing the other values", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_routes(organization, version, [%{route_id: "R1", short_name: "10", long_name: "Local"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"},
      %{stop_id: "p-c", zone_id: "C"},
      %{stop_id: "p-d", zone_id: "D"}
    ])

    [reviewed_row] = insert_rules(organization, version, [{"F", "R1", "A", "B", "C"}])
    reviewed = group_for(organization, version, {"F", "R1", "A", "B", true})
    assert Enum.map(reviewed.rows, & &1.id) == [reviewed_row.id]

    assert {:ok, group} =
             FareZones.save_rule_group(audit, reviewed, %{
               "fare_id" => "F",
               "route_id" => "R1",
               "origin_id" => "A",
               "destination_id" => "B",
               "contains" => ["C", "D"]
             })

    assert group.key == {"F", "R1", "A", "B", true}
    assert group.contains == ["C", "D"]
    assert length(group.rows) == 2
    assert length(Enum.uniq_by(group.rows, & &1.id)) == 2

    assert fare_rule_rows(organization, version) == [
             %{
               fare_id: "F",
               route_id: "R1",
               origin_id: "A",
               destination_id: "B",
               contains_id: "C"
             },
             %{
               fare_id: "F",
               route_id: "R1",
               origin_id: "A",
               destination_id: "B",
               contains_id: "D"
             }
           ]

    refute Repo.exists?(from(r in FareRule, where: r.id == ^reviewed_row.id))
  end

  test "refuses a new rule whose key another rule already holds", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"},
      %{stop_id: "p-c", zone_id: "C"},
      %{stop_id: "p-d", zone_id: "D"}
    ])

    insert_rules(organization, version, [{"F", nil, "A", "B", "C"}])
    before = rule_state(organization, version)
    projection_before = projection(organization, version)

    assert {:error, %Ecto.Changeset{} = changeset} =
             FareZones.save_rule_group(audit, nil, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "A",
               "destination_id" => "B",
               "contains" => ["D"]
             })

    assert changeset.action == :validate
    assert @key_message in errors_on(changeset).fare_id
    assert rule_state(organization, version) == before
    assert projection(organization, version) == projection_before
  end

  test "refuses an edit that moves a rule into another rule's key", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"},
      %{stop_id: "p-c", zone_id: "C"}
    ])

    insert_rules(organization, version, [{"F", nil, "A", "B", nil}, {"F", nil, "C", "B", nil}])
    reviewed = group_for(organization, version, {"F", nil, "A", "B", false})
    before = rule_state(organization, version)

    assert {:error, %Ecto.Changeset{} = changeset} =
             FareZones.save_rule_group(audit, reviewed, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "C",
               "destination_id" => "B",
               "contains" => []
             })

    assert changeset.action == :validate
    assert @key_message in errors_on(changeset).fare_id
    assert rule_state(organization, version) == before
  end

  test "keeps the rule's unknown current fare and refuses a different unknown fare or route", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"},
      %{stop_id: "p-e", zone_id: "E"}
    ])

    insert_rules(organization, version, [{"X", nil, "A", "B", nil}])
    reviewed = group_for(organization, version, {"X", nil, "A", "B", false})
    assert reviewed.unknown_fare? == true
    assert reviewed.fare == nil

    # Changing the journey keeps the fare that has no fare_attributes row.
    assert {:ok, group} =
             FareZones.save_rule_group(audit, reviewed, %{
               "fare_id" => "X",
               "route_id" => "",
               "origin_id" => "E",
               "destination_id" => "B",
               "contains" => []
             })

    assert group.fare_id == "X"
    assert group.unknown_fare? == true

    # A different fare with no row, and a route with no row, are refused.
    assert {:error, %Ecto.Changeset{} = changeset} =
             FareZones.save_rule_group(audit, group, %{
               "fare_id" => "Y",
               "route_id" => "",
               "origin_id" => "E",
               "destination_id" => "B",
               "contains" => []
             })

    assert "This fare is not in this version. Choose another." in errors_on(changeset).fare_id

    assert {:error, %Ecto.Changeset{} = route_changeset} =
             FareZones.save_rule_group(audit, group, %{
               "fare_id" => "X",
               "route_id" => "R9",
               "origin_id" => "E",
               "destination_id" => "B",
               "contains" => []
             })

    assert "This route is not in this version. Choose another." in errors_on(route_changeset).route_id
  end

  test "refuses a new reference to a stopless zone but keeps one the rule already has", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])
    insert_fare_zone(organization, version, "D", "Airport", "ochre")

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"}
    ])

    insert_rules(organization, version, [{"F", nil, "R", nil, nil}])

    # The declared empty zone and the rule-only zone R have no boardable stops.
    assert "D" in stopless_zone_ids(organization, version)
    assert "R" in stopless_zone_ids(organization, version)

    assert {:error, %Ecto.Changeset{} = changeset} =
             FareZones.save_rule_group(audit, nil, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "A",
               "destination_id" => "D",
               "contains" => []
             })

    assert @stopless_message in errors_on(changeset).destination_id

    assert fare_rule_rows(organization, version) == [
             %{fare_id: "F", route_id: nil, origin_id: "R", destination_id: nil, contains_id: nil}
           ]

    # A zone the reviewed rule already references stays usable even without
    # stops: the stopless rule changes its destination to a zone with stops.
    reviewed = group_for(organization, version, {"F", nil, "R", nil, false})

    assert {:ok, group} =
             FareZones.save_rule_group(audit, reviewed, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "R",
               "destination_id" => "A",
               "contains" => []
             })

    assert group.origin_id == "R"
    assert group.destination_id == "A"

    # R may not be chosen as a new reference elsewhere either.
    assert {:error, %Ecto.Changeset{} = second} =
             FareZones.save_rule_group(audit, nil, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "A",
               "destination_id" => "R",
               "contains" => []
             })

    assert @stopless_message in errors_on(second).destination_id
  end

  test "returns stale when a referenced zone was renamed after the review", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"}
    ])

    insert_rules(organization, version, [{"F", nil, "A", "B", nil}])

    reviewed = group_for(organization, version, {"F", nil, "A", "B", false})

    assert {:ok, _zone} =
             FareZones.update_zone(audit, "A", %{
               "zone_id" => "Z",
               "name" => "Zulu",
               "color" => "teal"
             })

    before = rule_state(organization, version)

    assert {:error, :stale} =
             FareZones.save_rule_group(audit, reviewed, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "A",
               "destination_id" => "B",
               "contains" => []
             })

    assert {:error, :stale} = FareZones.delete_rule_group(audit, reviewed)
    assert rule_state(organization, version) == before
  end

  test "returns stale when a row joins the reviewed key after the review", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"}
    ])

    insert_rules(organization, version, [{"F", nil, "A", "B", nil}])

    reviewed = group_for(organization, version, {"F", nil, "A", "B", false})
    insert_rules(organization, version, [{"F", nil, "A", "B", nil}])
    before = rule_state(organization, version)

    assert {:error, :stale} =
             FareZones.save_rule_group(audit, reviewed, %{
               "fare_id" => "F",
               "route_id" => "",
               "origin_id" => "A",
               "destination_id" => "B",
               "contains" => []
             })

    assert {:error, :stale} = FareZones.delete_rule_group(audit, reviewed)
    assert rule_state(organization, version) == before
  end

  test "removes exactly the reviewed rows and leaves fare_attributes alone", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"},
      %{stop_id: "p-c", zone_id: "C"}
    ])

    [_, kept] =
      insert_rules(organization, version, [
        {"F", nil, "A", "B", nil},
        {"F", nil, "C", "B", nil}
      ])

    reviewed = group_for(organization, version, {"F", nil, "A", "B", false})
    fares_before = fare_attribute_state(organization, version)

    assert {:ok, 1} = FareZones.delete_rule_group(audit, reviewed)

    assert fare_rule_rows(organization, version) == [
             %{fare_id: "F", route_id: nil, origin_id: "C", destination_id: "B", contains_id: nil}
           ]

    assert Repo.get!(FareRule, kept.id).updated_at == kept.updated_at
    assert fare_attribute_state(organization, version) == fares_before

    assert Enum.map(FareZones.list_rule_groups(organization.id, version.id), & &1.key) == [
             {"F", nil, "C", "B", false}
           ]

    # A second removal of the same review finds no rows under its key.
    assert {:error, :stale} = FareZones.delete_rule_group(audit, reviewed)
  end

  test "stores a padded imported origin byte-for-byte and leaves twin scopes alone", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    other_organization = OrganizationsFixtures.organization_fixture()
    AccountsFixtures.organization_membership_fixture(%{id: audit.actor_id}, other_organization)
    other_version = VersionsFixtures.gtfs_version_fixture(other_organization.id)

    for {org, ver} <- [{organization, version}, {other_organization, other_version}] do
      insert_fares(org, ver, [%{fare_id: "F", price: "2.50"}])

      insert_stops(org, ver, [
        %{stop_id: "p-padded", zone_id: " A"},
        %{stop_id: "p-trimmed", zone_id: "A"},
        %{stop_id: "p-b", zone_id: "B"},
        %{stop_id: "p-e", zone_id: "E"}
      ])

      insert_rules(org, ver, [{"F", nil, " A", nil, nil}])
    end

    twin_before = database_state(other_organization, other_version)
    second_version = VersionsFixtures.gtfs_version_fixture(organization.id)
    assert second_version.id != version.id

    create_attrs = %{
      "fare_id" => "F",
      "route_id" => "",
      "origin_id" => " A",
      "destination_id" => "B",
      "contains" => []
    }

    assert {:ok, group} =
             FareZones.save_rule_group(audit, nil, create_attrs)

    assert group.key == {"F", nil, " A", "B", false}
    assert [%{origin_id: " A", destination_id: "B"}] = group.rows

    assert " A" in Enum.map(fare_rule_rows(organization, version), & &1.origin_id)
    assert database_state(other_organization, other_version) == twin_before

    reviewed = group
    before = rule_state(organization, version)

    # Only a pair that is not a published version of that organization is
    # refused; the other version is a legitimate target whose own fares decide.
    for {org_id, ver_id} <- [
          {other_organization.id, version.id},
          {organization.id, other_version.id},
          {other_organization.id, second_version.id},
          {"not-a-uuid", version.id}
        ] do
      expected = if org_id == "not-a-uuid", do: :forbidden, else: :not_found

      assert {:error, ^expected} =
               FareZones.save_rule_group(
                 %{audit | organization_id: org_id, gtfs_version_id: ver_id},
                 nil,
                 create_attrs
               )

      assert {:error, ^expected} =
               FareZones.delete_rule_group(
                 %{audit | organization_id: org_id, gtfs_version_id: ver_id},
                 reviewed
               )
    end

    staging =
      organization.id
      |> VersionsFixtures.gtfs_version_fixture()
      |> stage()

    assert {:error, :not_found} =
             FareZones.save_rule_group(
               %{audit | organization_id: organization.id, gtfs_version_id: staging.id},
               nil,
               create_attrs
             )

    assert {:error, :not_found} =
             FareZones.delete_rule_group(
               %{audit | organization_id: organization.id, gtfs_version_id: staging.id},
               reviewed
             )

    assert rule_state(organization, version) == before

    # The main organization's second version is publishable but has no fares of
    # its own, so the same review is refused there and the main version keeps
    # every byte.
    assert {:error, %Ecto.Changeset{} = changeset} =
             FareZones.save_rule_group(
               %{audit | organization_id: organization.id, gtfs_version_id: second_version.id},
               nil,
               create_attrs
             )

    assert "This fare is not in this version. Choose another." in errors_on(changeset).fare_id
    assert rule_state(organization, version) == before

    # A genuine write in the twin's own version stays there.
    assert {:ok, twin_group} =
             FareZones.save_rule_group(
               %{
                 audit
                 | organization_id: other_organization.id,
                   gtfs_version_id: other_version.id
               },
               nil,
               %{
                 create_attrs
                 | "origin_id" => "E",
                   "destination_id" => "B"
               }
             )

    assert twin_group.key == {"F", nil, "E", "B", false}

    assert Repo.exists?(
             from(r in FareRule,
               where:
                 r.organization_id == ^other_organization.id and
                   r.gtfs_version_id == ^other_version.id and r.origin_id == "E"
             )
           )

    assert rule_state(organization, version) == before
    assert database_state(other_organization, other_version) != twin_before
  end

  test "rolls the whole save back when the caller's transaction aborts", %{
    audit: audit,
    organization: organization,
    version: version
  } do
    insert_fares(organization, version, [%{fare_id: "F", price: "2.50"}])

    insert_stops(organization, version, [
      %{stop_id: "p-a", zone_id: "A"},
      %{stop_id: "p-b", zone_id: "B"}
    ])

    [existing] = insert_rules(organization, version, [{"F", nil, "A", "B", nil}])
    reviewed = group_for(organization, version, {"F", nil, "A", "B", false})
    before = rule_state(organization, version)

    attrs = %{
      "fare_id" => "F",
      "route_id" => "",
      "origin_id" => "A",
      "destination_id" => "B",
      "contains" => ["A"]
    }

    assert {:error, :aborted} =
             Repo.transaction(fn ->
               assert {:ok, %{rows: rows}} =
                        FareZones.save_rule_group(audit, reviewed, attrs)

               assert length(rows) == 1

               # The write is visible inside the caller's transaction and the
               # caller's rollback discards it whole.
               assert fare_rule_rows(organization, version) == [
                        %{
                          fare_id: "F",
                          route_id: nil,
                          origin_id: "A",
                          destination_id: "B",
                          contains_id: "A"
                        }
                      ]

               Repo.rollback(:aborted)
             end)

    assert rule_state(organization, version) == before
    assert Repo.exists?(from(r in FareRule, where: r.id == ^existing.id))

    # The prior state stayed usable: the same save now commits.
    assert {:ok, group} = FareZones.save_rule_group(audit, reviewed, attrs)
    assert group.contains == ["A"]
  end

  defp stage(version) do
    Repo.update_all(from(v in GtfsVersion, where: v.id == ^version.id),
      set: [publication_status: "staging", published_at: nil]
    )

    Repo.get!(GtfsVersion, version.id)
  end

  defp group_for(organization, version, key) do
    organization.id
    |> FareZones.list_rule_groups(version.id)
    |> Enum.find(&(&1.key == key))
    |> case do
      nil -> raise "no rule group with key #{inspect(key)}"
      group -> group
    end
  end

  defp projection(organization, version) do
    organization.id
    |> FareZones.list_rule_groups(version.id)
    |> Enum.map(&{&1.key, Enum.map(&1.rows, fn row -> Map.take(row, [:id, :contains_id]) end)})
  end

  defp stopless_zone_ids(organization, version) do
    organization.id
    |> FareZones.inventory(version.id)
    |> Map.fetch!(:zones)
    |> Enum.filter(&(&1.stop_count == 0))
    |> Enum.map(& &1.zone_id)
  end

  defp rule_state(organization, version) do
    Enum.map(rule_records(organization, version), fn row ->
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
    end)
  end

  defp database_state(organization, version) do
    %{
      rules: rule_state(organization, version),
      fares: fare_attribute_state(organization, version),
      stops:
        Repo.all(
          from(s in Stop,
            where: s.organization_id == ^organization.id and s.gtfs_version_id == ^version.id,
            order_by: s.stop_id,
            select: %{
              id: s.id,
              stop_id: s.stop_id,
              zone_id: s.zone_id,
              location_type: s.location_type,
              updated_at: s.updated_at
            }
          )
        ),
      records:
        Repo.all(
          from(z in FareZone,
            where: z.organization_id == ^organization.id and z.gtfs_version_id == ^version.id,
            order_by: z.zone_id,
            select: %{id: z.id, zone_id: z.zone_id, name: z.name, color: z.color}
          )
        )
    }
  end

  defp fare_attribute_state(organization, version) do
    Repo.all(
      from(a in FareAttribute,
        where: a.organization_id == ^organization.id and a.gtfs_version_id == ^version.id,
        order_by: a.fare_id,
        select: %{
          id: a.id,
          fare_id: a.fare_id,
          price: a.price,
          currency_type: a.currency_type,
          inserted_at: a.inserted_at,
          updated_at: a.updated_at
        }
      )
    )
  end

  defp rule_records(organization, version) do
    Repo.all(
      from(r in FareRule,
        where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id,
        order_by: [r.fare_id, r.origin_id, r.destination_id, r.id]
      )
    )
  end

  defp fare_rule_rows(organization, version) do
    from(r in FareRule,
      where: r.organization_id == ^organization.id and r.gtfs_version_id == ^version.id,
      order_by: [r.fare_id, r.origin_id, r.destination_id, r.contains_id, r.id],
      select: {r.fare_id, r.route_id, r.origin_id, r.destination_id, r.contains_id}
    )
    |> Repo.all()
    |> Enum.map(fn {fare_id, route_id, origin_id, destination_id, contains_id} ->
      %{
        fare_id: fare_id,
        route_id: route_id,
        origin_id: origin_id,
        destination_id: destination_id,
        contains_id: contains_id
      }
    end)
  end

  # Fare rules are microsecond-precise; the `stops` table is second precision
  # (its migration uses `timestamps()`), so a stop seed lands on a whole second
  # carrying the microsecond precision the schema expects. An hour-old seed makes
  # a write's timestamp update observable without depending on the clock.
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

  defp insert_fares(organization, version, fares) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(fares, fn fare ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare.fare_id,
          price: Decimal.new(fare.price),
          currency_type: Map.get(fare, :currency_type, "USD"),
          payment_method: 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(FareAttribute, rows)
    assert count == length(rows)
  end

  defp insert_routes(organization, version, routes) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    rows =
      Enum.map(routes, fn route ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          route_id: route.route_id,
          route_type: 3,
          route_short_name: route.short_name,
          route_long_name: route.long_name,
          inserted_at: now,
          updated_at: now
        }
      end)

    {count, nil} = Repo.insert_all(Route, rows)
    assert count == length(rows)
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
      Enum.map(rules, fn {fare_id, route_id, origin_id, destination_id, contains_id} ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: organization.id,
          gtfs_version_id: version.id,
          fare_id: fare_id,
          route_id: route_id,
          origin_id: origin_id,
          destination_id: destination_id,
          contains_id: contains_id,
          inserted_at: seeded,
          updated_at: seeded
        }
      end)

    {count, nil} = Repo.insert_all(FareRule, rows)
    assert count == length(rows)
    rows
  end
end

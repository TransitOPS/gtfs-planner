defmodule GtfsPlanner.Gtfs.StopTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Versions
  alias GtfsPlanner.Versions.GtfsVersion

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  describe "input write coordination" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      %{organization: organization, version: version}
    end

    test "invalid input keeps its changeset error without opening a writer transaction", %{
      organization: org,
      version: version
    } do
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.create_stop(%{})
      assert {:error, %Ecto.Changeset{valid?: false}} = Gtfs.import_create_stop(%{})

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Gtfs.update_stop(
                 %Stop{organization_id: org.id, gtfs_version_id: version.id},
                 %{stop_id: nil}
               )

      assert {:error, %Ecto.Changeset{valid?: false}} =
               Gtfs.import_update_stop(
                 %Stop{organization_id: org.id, gtfs_version_id: version.id},
                 %{}
               )
    end

    test "a foreign or unknown scope is refused without writing the stop", %{
      organization: org,
      version: version
    } do
      other = organization_fixture()
      stop = stop_fixture(org.id, version.id, %{stop_id: "SCOPED_STOP", stop_name: "Scoped Stop"})
      foreign = %{stop | organization_id: other.id}

      assert {:error, :not_found} =
               Gtfs.create_stop(%{
                 organization_id: other.id,
                 gtfs_version_id: version.id,
                 stop_id: "FOREIGN_STOP"
               })

      assert {:error, :not_found} =
               Gtfs.import_create_stop(%{
                 organization_id: org.id,
                 gtfs_version_id: Ecto.UUID.generate(),
                 stop_id: "UNKNOWN_STOP"
               })

      assert {:error, :not_found} = Gtfs.update_stop(foreign, %{stop_name: "Foreign"})
      assert {:error, :not_found} = Gtfs.import_update_stop(foreign, %{stop_name: "Foreign"})
      assert {:error, :not_found} = Gtfs.delete_stop(foreign)

      # The refused writers rolled their transactions back, so the owned stop is untouched and
      # no row landed under the foreign scope.
      assert Repo.get!(Stop, stop.id).stop_name == "Scoped Stop"
      refute Repo.exists?(from(s in Stop, where: s.organization_id == ^other.id))
    end

    test "the import stop writers keep accepting a staging scope", %{
      organization: org,
      version: version
    } do
      assert {:ok, staging} =
               Versions.create_staging_gtfs_version(org.id, %{name: "Staging stop writes"})

      assert {:ok, %Stop{stop_id: "STAGING_STOP"}} =
               Gtfs.import_create_stop(%{
                 organization_id: org.id,
                 gtfs_version_id: staging.id,
                 stop_id: "STAGING_STOP",
                 parent_station: "ABSENT_PARENT",
                 level_id: nil
               })

      staging_stop = stop_fixture(org.id, staging.id, %{stop_id: "IMPORT_UPDATED"})

      assert {:ok, %Stop{stop_name: "Drifted"}} =
               Gtfs.import_update_stop(staging_stop, %{stop_name: "Drifted"})

      # The helper is a scoped row lock, not an authorization check: the scope is still a plain
      # staging version afterwards, exactly as before the lock was added.
      assert %GtfsVersion{publication_status: "staging", published_at: nil} =
               Repo.get!(GtfsVersion, staging.id)

      assert %GtfsVersion{publication_status: "published"} = Repo.get!(GtfsVersion, version.id)
    end

    test "the stop audit entry point still records the pre-change snapshot after a cascade", %{
      organization: org,
      version: version
    } do
      actor = user_fixture()

      audit = %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      station =
        stop_fixture(org.id, version.id, %{
          stop_id: "AUDIT_STATION",
          stop_name: "Old Station",
          location_type: 1
        })

      assert {:ok, %Stop{} = renamed} =
               Gtfs.update_stop_with_cascade(station, %{stop_id: "AUDIT_STATION_RENAMED"})

      assert renamed.stop_id == "AUDIT_STATION_RENAMED"

      # The journal still records one "updated" entry for the stop against its pre-change
      # snapshot, unchanged by the added version lock.
      assert :ok =
               Gtfs.record_change(audit, :stop, station, "updated", %{stop_name: "New Name"})

      assert [log] = Gtfs.list_change_logs_for_entity(org.id, version.id, "stop", station.id)
      assert log.action == "updated"
      assert log.snapshot["stop_name"] == "Old Station"

      assert log.changed_fields["stop_name"] == %{
               "from" => "Old Station",
               "to" => "New Name"
             }

      # The cascade's version share lock did not outlive its transaction.
      assert {:ok, :acquired} = acquire_exclusive_version(org.id, version.id)
    end
  end

  describe "stop_code, tts_stop_name, stop_url and stop_timezone" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      stop = stop_fixture(organization.id, version.id, %{stop_id: "CODED", stop_name: "Coded"})

      {1, _} =
        Repo.update_all(from(s in Stop, where: s.id == ^stop.id),
          set: [
            stop_code: "4021",
            tts_stop_name: "Coded Stop",
            stop_url: "https://example.test/stops/coded",
            stop_timezone: "America/New_York"
          ]
        )

      %{organization: organization, version: version, stop: Repo.get!(Stop, stop.id)}
    end

    test "a stop form save cannot change them", %{stop: stop} do
      assert {:ok, saved} =
               Gtfs.update_stop(stop, %{
                 stop_name: "Renamed",
                 stop_code: nil,
                 tts_stop_name: "Other",
                 stop_url: nil,
                 stop_timezone: "Europe/Paris"
               })

      assert %{
               stop_name: "Renamed",
               stop_code: "4021",
               tts_stop_name: "Coded Stop",
               stop_url: "https://example.test/stops/coded",
               stop_timezone: "America/New_York"
             } = Repo.get!(Stop, saved.id)
    end

    test "the import changeset cannot change them either", %{stop: stop} do
      changeset =
        Stop.import_changeset(stop, %{
          stop_code: "9",
          tts_stop_name: "Other",
          stop_url: "https://example.test/other",
          stop_timezone: "Europe/Paris"
        })

      assert changeset.changes == %{}
    end

    test "a rollback restores the reversible fields and leaves them untouched", %{
      organization: org,
      version: version,
      stop: stop
    } do
      actor = user_fixture()

      audit = %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        actor_id: actor.id,
        actor_email: actor.email
      }

      assert {:ok, renamed} = Gtfs.update_stop(stop, %{stop_name: "Renamed"})
      assert :ok = Gtfs.record_change(audit, :stop, stop, "updated", %{stop_name: "Renamed"})

      assert [log] = Gtfs.list_change_logs_for_entity(org.id, version.id, "stop", renamed.id)
      assert {:ok, _restored} = Gtfs.rollback_entity(log, audit)

      assert %{
               stop_name: "Coded",
               stop_code: "4021",
               tts_stop_name: "Coded Stop",
               stop_url: "https://example.test/stops/coded",
               stop_timezone: "America/New_York"
             } = Repo.get!(Stop, stop.id)
    end
  end

  describe "slugify/1" do
    test "slugifies a normal name" do
      assert Stop.slugify("Platform A") == "platform_a"
    end

    test "removes special characters" do
      assert Stop.slugify("Track #3 — West!") == "track_3_west"
    end

    test "returns empty string for empty input" do
      assert Stop.slugify("") == ""
    end

    test "returns empty string for nil input" do
      assert Stop.slugify(nil) == ""
    end

    test "keeps numeric-only values" do
      assert Stop.slugify("42") == "42"
    end

    test "truncates to 64 characters" do
      long_name = String.duplicate("a", 80)
      assert Stop.slugify(long_name) == String.duplicate("a", 64)
    end

    test "trims leading and trailing whitespace" do
      assert Stop.slugify("  Platform A  ") == "platform_a"
    end
  end

  describe "generate_stop_id/2" do
    test "generates stop id for platform" do
      assert Stop.generate_stop_id(0, "Track 1") == "platform_track_1"
    end

    test "generates stop id for entrance" do
      assert Stop.generate_stop_id(2, "Main Entrance") == "entrance_main_entrance"
    end

    test "returns empty string for empty name" do
      assert Stop.generate_stop_id(3, "") == ""
    end

    test "returns empty string for nil name" do
      assert Stop.generate_stop_id(3, nil) == ""
    end

    test "uses expected location_type prefixes" do
      assert Stop.generate_stop_id(0, "A") == "platform_a"
      assert Stop.generate_stop_id(1, "A") == "station_a"
      assert Stop.generate_stop_id(2, "A") == "entrance_a"
      assert Stop.generate_stop_id(3, "A") == "node_a"
      assert Stop.generate_stop_id(4, "A") == "boarding_a"
    end
  end

  describe "changeset/2 coordinate validation" do
    test "accepts in-range latitude and longitude" do
      attrs =
        base_stop_attrs()
        |> Map.put(:stop_lat, "40.7128")
        |> Map.put(:stop_lon, "-74.0060")

      changeset = Stop.changeset(%Stop{}, attrs)

      assert changeset.valid?
    end

    test "rejects latitude greater than 90" do
      attrs = Map.put(base_stop_attrs(), :stop_lat, "91")
      changeset = Stop.changeset(%Stop{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :stop_lat)
    end

    test "rejects longitude greater than 180" do
      attrs = Map.put(base_stop_attrs(), :stop_lon, "181")
      changeset = Stop.changeset(%Stop{}, attrs)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :stop_lon)
    end

    test "accepts missing latitude and longitude" do
      changeset = Stop.changeset(%Stop{}, base_stop_attrs())

      assert changeset.valid?
    end
  end

  @station_in_station_error "A station can't be inside another station. Choose another type."

  describe "changeset/2 and import_changeset/2 level_id rules" do
    # GTFS needs level_id only for elevator pathways. `changeset/2` stays
    # permissive about it so the map editor can move a stop between stations; the
    # station diagram's own form adds the requirement through
    # `Stop.child_stop_changeset/2`.
    test "changeset/2 accepts a child stop with a parent station and no level_id" do
      attrs =
        base_stop_attrs()
        |> Map.put(:parent_station, "ST-NTC")
        |> Map.put(:level_id, nil)

      assert Stop.changeset(%Stop{}, attrs).valid?
    end

    test "changeset/2 still rejects a station with a parent station and no level_id" do
      attrs =
        base_stop_attrs()
        |> Map.merge(%{location_type: 1, parent_station: "ST-NTC", level_id: nil})

      changeset = Stop.changeset(%Stop{}, attrs)

      refute changeset.valid?
      assert {@station_in_station_error, _} = changeset.errors[:location_type]
    end

    test "import_changeset/2 allows nil level_id when parent_station is set" do
      attrs =
        base_stop_attrs()
        |> Map.put(:parent_station, "PARENT_STATION")
        |> Map.put(:level_id, nil)

      changeset = Stop.import_changeset(%Stop{}, attrs)

      assert changeset.valid?
    end
  end

  describe "changeset/2 and import_changeset/2 station parent rule" do
    test "changeset/2 rejects a station with a parent station" do
      attrs =
        base_stop_attrs()
        |> Map.merge(%{location_type: 1, parent_station: "PARENT_STATION", level_id: "L1"})

      changeset = Stop.changeset(%Stop{}, attrs)

      refute changeset.valid?
      assert {@station_in_station_error, _} = changeset.errors[:location_type]
    end

    test "changeset/2 rejects changing a child stop to a station" do
      child = %Stop{location_type: 0, parent_station: "PARENT_STATION", level_id: "L1"}

      changeset = Stop.changeset(child, %{location_type: 1})

      refute changeset.valid?
      assert {@station_in_station_error, _} = changeset.errors[:location_type]
    end

    test "changeset/2 rejects any edit of a stored station that has a parent station" do
      legacy = %Stop{location_type: 1, parent_station: "PARENT_STATION", level_id: "L1"}

      changeset = Stop.changeset(legacy, %{stop_name: "Renamed"})

      refute changeset.valid?
      assert {@station_in_station_error, _} = changeset.errors[:location_type]
    end

    test "changeset/2 accepts a station without a parent station" do
      attrs = Map.merge(base_stop_attrs(), %{location_type: 1, parent_station: nil})

      assert Stop.changeset(%Stop{}, attrs).valid?
    end

    test "changeset/2 accepts a station whose parent station is an empty string" do
      attrs = Map.merge(base_stop_attrs(), %{location_type: 1, parent_station: ""})

      assert Stop.changeset(%Stop{}, attrs).valid?
    end

    for location_type <- [0, 2, 3, 4] do
      test "changeset/2 accepts location type #{location_type} with a parent station and level" do
        attrs =
          base_stop_attrs()
          |> Map.merge(%{
            location_type: unquote(location_type),
            parent_station: "PARENT_STATION",
            level_id: "L1"
          })

        assert Stop.changeset(%Stop{}, attrs).valid?
      end
    end

    test "import_changeset/2 accepts a station with a parent station" do
      attrs =
        base_stop_attrs()
        |> Map.merge(%{location_type: 1, parent_station: "PARENT_STATION", level_id: nil})

      changeset = Stop.import_changeset(%Stop{}, attrs)

      assert changeset.valid?
    end
  end

  describe "resolve_wheelchair_boarding/2" do
    test "returns accessible/direct for a child value of 1" do
      child = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, nil) ==
               %{status: :accessible, source: :direct}
    end

    test "returns not_accessible/direct for a child value of 2" do
      child = %Stop{wheelchair_boarding: 2}

      assert Stop.resolve_wheelchair_boarding(child, nil) ==
               %{status: :not_accessible, source: :direct}
    end

    test "a direct value wins over a conflicting parent" do
      child = %Stop{wheelchair_boarding: 2}
      parent = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :not_accessible, source: :direct}
    end

    test "inherits accessible from a parent 1 when the child is 0" do
      child = %Stop{wheelchair_boarding: 0}
      parent = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :accessible, source: :inherited}
    end

    test "inherits accessible from a parent 1 when the child is nil" do
      child = %Stop{wheelchair_boarding: nil}
      parent = %Stop{wheelchair_boarding: 1}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :accessible, source: :inherited}
    end

    test "inherits not_accessible from a parent 2 when the child is 0" do
      child = %Stop{wheelchair_boarding: 0}
      parent = %Stop{wheelchair_boarding: 2}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :not_accessible, source: :inherited}
    end

    test "returns unknown/missing for a child 0 with no parent" do
      child = %Stop{wheelchair_boarding: 0}

      assert Stop.resolve_wheelchair_boarding(child, nil) ==
               %{status: :unknown, source: :missing}
    end

    test "returns unknown/missing for a child nil with a parent 0" do
      child = %Stop{wheelchair_boarding: nil}
      parent = %Stop{wheelchair_boarding: 0}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :unknown, source: :missing}
    end

    test "returns unknown/missing for a child nil with a parent nil" do
      child = %Stop{wheelchair_boarding: nil}
      parent = %Stop{wheelchair_boarding: nil}

      assert Stop.resolve_wheelchair_boarding(child, parent) ==
               %{status: :unknown, source: :missing}
    end

    test "leaves both input structs unchanged" do
      child = %Stop{wheelchair_boarding: 0, stop_id: "CHILD"}
      parent = %Stop{wheelchair_boarding: 1, stop_id: "PARENT"}

      _result = Stop.resolve_wheelchair_boarding(child, parent)

      assert child.wheelchair_boarding == 0
      assert child.stop_id == "CHILD"
      assert parent.wheelchair_boarding == 1
      assert parent.stop_id == "PARENT"
    end
  end

  defp base_stop_attrs do
    %{
      stop_id: "STOP_1",
      organization_id: Ecto.UUID.generate(),
      gtfs_version_id: Ecto.UUID.generate()
    }
  end

  defp acquire_exclusive_version(organization_id, version_id) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '5s'")

      Repo.one(
        from(v in GtfsVersion,
          where: v.id == ^version_id and v.organization_id == ^organization_id,
          lock: "FOR UPDATE"
        )
      )

      :acquired
    end)
  end
end

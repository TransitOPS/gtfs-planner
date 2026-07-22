defmodule GtfsPlanner.Gtfs.StationJournalTest do
  use GtfsPlanner.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto}
  alias GtfsPlanner.Gtfs.StationJournal.Scope
  alias GtfsPlanner.Repo

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @scope %Scope{
    organization_id: "e1d9aa70-532d-43e5-bab0-77cce113c923",
    gtfs_version_id: "34247956-83fc-4e80-b0df-78f86972f5f9",
    station_id: "9f7145c0-fd1a-4a82-bc54-0f4a70e147e9",
    station_stop_id: "station_1",
    actor_id: "a709799a-4b37-4af2-aa0a-9d8862da7f46"
  }

  @entry_id "1a4010de-2d4d-4c1a-86e3-03c9af2f5138"
  @target_id "53cb9e6a-58c4-4b57-988a-d84cbfb459da"
  @level_id "d3559e4e-4c49-4157-839d-fd8e5bcd4749"
  @captured_at ~U[2026-07-13 12:00:00.123456Z]

  describe "JournalEntry.create_changeset/3" do
    test "accepts every valid target shape with trusted scope and microsecond capture time" do
      station =
        JournalEntry.create_changeset(
          %JournalEntry{},
          entry_attrs(%{target_type: "station"}),
          @scope
        )

      node =
        JournalEntry.create_changeset(
          %JournalEntry{},
          entry_attrs(%{id: Ecto.UUID.generate(), target_type: "node", target_id: @target_id}),
          @scope
        )

      pathway =
        JournalEntry.create_changeset(
          %JournalEntry{},
          entry_attrs(%{id: Ecto.UUID.generate(), target_type: "pathway", target_id: @target_id}),
          @scope
        )

      pin =
        JournalEntry.create_changeset(
          %JournalEntry{},
          entry_attrs(%{
            id: Ecto.UUID.generate(),
            target_type: "pin",
            stop_level_id: @level_id,
            diagram_x: 50.0,
            diagram_y: 40.0
          }),
          @scope
        )

      assert station.valid?
      assert node.valid?
      assert pathway.valid?
      assert pin.valid?
      assert Ecto.Changeset.get_change(station, :organization_id) == @scope.organization_id
      assert Ecto.Changeset.get_change(station, :gtfs_version_id) == @scope.gtfs_version_id
      assert Ecto.Changeset.get_change(station, :station_id) == @scope.station_id
      assert Ecto.Changeset.get_change(station, :author_id) == @scope.actor_id
      assert Ecto.Changeset.get_change(station, :captured_at).microsecond == {123_456, 6}
    end

    test "rejects malformed target shapes" do
      changeset =
        JournalEntry.create_changeset(
          %JournalEntry{},
          entry_attrs(%{
            target_type: "pin",
            target_id: @target_id,
            stop_level_id: @level_id,
            diagram_x: -1.0,
            diagram_y: 0.0
          }),
          @scope
        )

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :target_type)
    end

    test "ignores client assignment of trusted scope, closure, and derived coordinates" do
      changeset =
        JournalEntry.create_changeset(
          %JournalEntry{},
          entry_attrs(%{
            target_type: "station",
            organization_id: Ecto.UUID.generate(),
            gtfs_version_id: Ecto.UUID.generate(),
            station_id: Ecto.UUID.generate(),
            author_id: Ecto.UUID.generate(),
            closed_at: @captured_at,
            closed_by: Ecto.UUID.generate(),
            lat: 1.0,
            lon: 2.0
          }),
          @scope
        )

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :organization_id) == @scope.organization_id
      assert Ecto.Changeset.get_change(changeset, :gtfs_version_id) == @scope.gtfs_version_id
      assert Ecto.Changeset.get_change(changeset, :station_id) == @scope.station_id
      assert Ecto.Changeset.get_change(changeset, :author_id) == @scope.actor_id
      refute Map.has_key?(changeset.changes, :closed_at)
      refute Map.has_key?(changeset.changes, :lat)
      refute Map.has_key?(changeset.changes, :lon)
    end
  end

  describe "JournalPhoto.create_changeset/2" do
    test "requires valid immutable metadata" do
      changeset =
        JournalPhoto.create_changeset(%JournalPhoto{}, %{
          id: Ecto.UUID.generate(),
          journal_entry_id: @entry_id,
          filename: "photo.jpg",
          content_type: "image/jpeg",
          byte_size: 12,
          sha256: :crypto.strong_rand_bytes(32),
          width: 100,
          height: 100,
          captured_at: @captured_at
        })

      assert changeset.valid?
    end

    test "rejects unsupported media, non-positive dimensions and size, and invalid digest length" do
      changeset =
        JournalPhoto.create_changeset(%JournalPhoto{}, %{
          id: Ecto.UUID.generate(),
          journal_entry_id: @entry_id,
          filename: "photo.gif",
          content_type: "image/gif",
          byte_size: 0,
          sha256: <<1, 2>>,
          width: 0,
          height: -1,
          captured_at: @captured_at
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :content_type)
      assert Keyword.has_key?(changeset.errors, :byte_size)
      assert Keyword.has_key?(changeset.errors, :sha256)
      assert Keyword.has_key?(changeset.errors, :width)
      assert Keyword.has_key?(changeset.errors, :height)
    end
  end

  describe "station journal scope and synchronization" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, version.id,
          stop_id: "station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      child =
        stop_fixture(organization.id, version.id,
          stop_id: "platform_#{System.unique_integer([:positive])}",
          parent_station: station.stop_id,
          level_id: "L1"
        )

      pathway = pathway_fixture(organization.id, version.id, child.stop_id, child.stop_id)
      level = level_fixture(organization.id, version.id, level_id: "L1")

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: station.id,
          level_id: level.id
        })

      scope = %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_id: station.id,
        station_stop_id: station.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      %{
        organization: organization,
        version: version,
        station: station,
        child: child,
        pathway: pathway,
        stop_level: stop_level,
        scope: scope
      }
    end

    test "resolves only a top-level station in the selected organization and version", %{
      organization: organization,
      version: version,
      station: station
    } do
      actor_id = Ecto.UUID.generate()

      assert {:ok, %Scope{station_id: station_id, station_stop_id: station_stop_id}} =
               Gtfs.resolve_station_journal_scope(
                 organization.id,
                 version.id,
                 station.id,
                 actor_id
               )

      assert station_id == station.id
      assert station_stop_id == station.stop_id

      assert {:error, :invalid_id} =
               Gtfs.resolve_station_journal_scope("invalid", version.id, station.id, actor_id)

      assert {:error, :not_found} =
               Gtfs.resolve_station_journal_scope(
                 organization.id,
                 version.id,
                 Ecto.UUID.generate(),
                 actor_id
               )
    end

    test "synchronizes valid sibling targets and rejects invalid targets without rolling back", %{
      scope: scope,
      child: child,
      pathway: pathway,
      stop_level: stop_level
    } do
      station_id = Ecto.UUID.generate()
      node_id = Ecto.UUID.generate()
      pin_id = Ecto.UUID.generate()
      invalid_id = Ecto.UUID.generate()

      result =
        Gtfs.sync_journal_entries(scope, [
          entry_attrs(%{id: station_id, target_type: "station"}),
          entry_attrs(%{id: node_id, target_type: "node", target_id: child.id}),
          entry_attrs(%{
            id: pin_id,
            target_type: "pin",
            stop_level_id: stop_level.id,
            diagram_x: 12.0,
            diagram_y: 8.0
          }),
          entry_attrs(%{id: invalid_id, target_type: "pathway", target_id: Ecto.UUID.generate()}),
          entry_attrs(%{
            id: Ecto.UUID.generate(),
            target_type: "pathway",
            target_id: pathway.id,
            diagram_x: 1.0
          })
        ])

      assert result.synced_count == 3
      assert [%{id: ^invalid_id, code: :invalid_target}, %{code: :invalid_target}] = result.errors
      assert length(Gtfs.list_station_journal(scope)) == 3
    end

    test "keeps scope and audit fields immutable while same-scope replay updates body", %{
      scope: scope
    } do
      id = Ecto.UUID.generate()
      captured_at = ~U[2026-07-13 12:00:00.123456Z]

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 entry_attrs(%{
                   id: id,
                   target_type: "station",
                   body: "first",
                   captured_at: captured_at
                 })
               ])

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 entry_attrs(%{
                   id: id,
                   target_type: "station",
                   body: "last",
                   captured_at: DateTime.add(captured_at, 1, :second),
                   author_id: Ecto.UUID.generate()
                 })
               ])

      [entry] = Gtfs.list_station_journal(scope)
      assert entry.body == "last"
      assert entry.captured_at == captured_at
      assert entry.author_id == scope.actor_id
    end

    test "accepts a partial same-scope replay without creation-only fields", %{scope: scope} do
      id = Ecto.UUID.generate()

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 %{
                   "id" => id,
                   "target_type" => "station",
                   "body" => "first",
                   "captured_at" => "2026-07-13T12:00:00Z"
                 }
               ])

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [%{"id" => id, "body" => "updated"}])

      assert %JournalEntry{body: "updated", target_type: "station"} = Repo.get!(JournalEntry, id)
    end

    test "concurrent same-scope UUID claims keep one owner and a committed mutable value", %{
      scope: scope
    } do
      id = Ecto.UUID.generate()

      requests =
        for body <- ["first concurrent body", "second concurrent body"] do
          {scope, entry_attrs(%{id: id, target_type: "station", body: body})}
        end

      assert [
               %{synced_count: 1, errors: []},
               %{synced_count: 1, errors: []}
             ] = run_concurrent_syncs(requests)

      assert %JournalEntry{
               organization_id: organization_id,
               gtfs_version_id: gtfs_version_id,
               station_id: station_id,
               author_id: author_id,
               body: body
             } = Repo.get!(JournalEntry, id)

      assert organization_id == scope.organization_id
      assert gtfs_version_id == scope.gtfs_version_id
      assert station_id == scope.station_id
      assert author_id == scope.actor_id
      assert body in ["first concurrent body", "second concurrent body"]
      assert Repo.aggregate(from(entry in JournalEntry, where: entry.id == ^id), :count) == 1
    end

    test "concurrent competing-scope UUID claims never transfer ownership", %{scope: scope} do
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      other_station =
        stop_fixture(other_organization.id, other_version.id,
          stop_id: "station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      other_scope = %Scope{
        organization_id: other_organization.id,
        gtfs_version_id: other_version.id,
        station_id: other_station.id,
        station_stop_id: other_station.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      id = Ecto.UUID.generate()

      results =
        run_concurrent_syncs([
          {scope, entry_attrs(%{id: id, target_type: "station", body: "first scope"})},
          {other_scope, entry_attrs(%{id: id, target_type: "station", body: "competing scope"})}
        ])

      assert Enum.count(results, &(&1 == %{synced_count: 1, errors: []})) == 1

      assert Enum.count(results, fn result ->
               result.synced_count == 0 and
                 result.errors == [%{id: id, code: :id_conflict}]
             end) == 1

      entry = Repo.get!(JournalEntry, id)

      assert {entry.organization_id, entry.gtfs_version_id, entry.station_id, entry.author_id,
              entry.body} in [
               {scope.organization_id, scope.gtfs_version_id, scope.station_id, scope.actor_id,
                "first scope"},
               {other_scope.organization_id, other_scope.gtfs_version_id, other_scope.station_id,
                other_scope.actor_id, "competing scope"}
             ]

      assert Repo.aggregate(from(entry in JournalEntry, where: entry.id == ^id), :count) == 1
    end

    test "reports non-object items without aborting valid siblings", %{scope: scope} do
      id = Ecto.UUID.generate()

      assert %{
               synced_count: 1,
               errors: [
                 %{id: nil, code: :validation_error},
                 %{id: nil, code: :validation_error}
               ]
             } =
               Gtfs.sync_journal_entries(scope, [
                 entry_attrs(%{id: id, target_type: "station"}),
                 "not-an-object",
                 nil
               ])

      assert %JournalEntry{id: ^id} = Repo.get(JournalEntry, id)
    end

    test "does not transfer an entry UUID across station scopes", %{scope: scope} do
      id = Ecto.UUID.generate()

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 entry_attrs(%{id: id, target_type: "station", body: "original"})
               ])

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      other_station =
        stop_fixture(other_organization.id, other_version.id,
          stop_id: "station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      other_scope = %Scope{
        organization_id: other_organization.id,
        gtfs_version_id: other_version.id,
        station_id: other_station.id,
        station_stop_id: other_station.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      assert %{synced_count: 0, errors: [%{id: ^id, code: :id_conflict}]} =
               Gtfs.sync_journal_entries(other_scope, [
                 entry_attrs(%{id: id, target_type: "station", body: "attempted transfer"})
               ])

      [entry] = Gtfs.list_station_journal(scope)
      assert entry.body == "original"
    end

    test "returns entries and photos in deterministic capture order including closed history", %{
      scope: scope
    } do
      later_id = Ecto.UUID.generate()
      earlier_id = Ecto.UUID.generate()

      assert %{synced_count: 2, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 entry_attrs(%{
                   id: later_id,
                   target_type: "station",
                   captured_at: ~U[2026-07-13 12:01:00Z]
                 }),
                 entry_attrs(%{
                   id: earlier_id,
                   target_type: "station",
                   captured_at: ~U[2026-07-13 12:00:00Z]
                 })
               ])

      assert Enum.map(Gtfs.list_station_journal(scope), & &1.id) == [earlier_id, later_id]
    end

    test "refreshes only scoped pin coordinates while preserving diagram coordinates", %{
      scope: scope,
      stop_level: stop_level
    } do
      pin_id = Ecto.UUID.generate()

      assert %{synced_count: 1, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 entry_attrs(%{
                   id: pin_id,
                   target_type: "pin",
                   stop_level_id: stop_level.id,
                   diagram_x: 50.0,
                   diagram_y: 40.0
                 })
               ])

      [unrefreshed] = Gtfs.list_station_journal(scope)
      assert is_nil(unrefreshed.lat)
      assert is_nil(unrefreshed.lon)

      {:ok, aligned_stop_level} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.25,
          floorplan_rotation_deg: 0.0
        })

      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      other_station =
        stop_fixture(other_organization.id, other_version.id,
          stop_id: "station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      other_scope = %Scope{
        organization_id: other_organization.id,
        gtfs_version_id: other_version.id,
        station_id: other_station.id,
        station_stop_id: other_station.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      unrelated_pin =
        JournalEntry.create_changeset(
          %JournalEntry{},
          entry_attrs(%{
            id: Ecto.UUID.generate(),
            target_type: "pin",
            stop_level_id: stop_level.id,
            diagram_x: 50.0,
            diagram_y: 40.0
          }),
          other_scope
        )
        |> Repo.insert!()

      assert {:ok, 1} = Gtfs.refresh_pin_coordinates_for_stop_level(aligned_stop_level, 1000, 800)

      refreshed = Repo.get!(JournalEntry, pin_id)
      assert refreshed.diagram_x == 50.0
      assert refreshed.diagram_y == 40.0
      assert_in_delta refreshed.lat, 40.7128, 1.0e-9
      assert_in_delta refreshed.lon, -74.006, 1.0e-9

      assert %{lat: nil, lon: nil} = Repo.get!(JournalEntry, unrelated_pin.id)
    end
  end

  describe "JournalEntry closure changesets" do
    test "close_changeset/3 sets closed_at and closed_by together and attaches check constraint" do
      entry = %JournalEntry{}
      closed_at = ~U[2026-07-21 12:00:00.000000Z]
      closed_by = Ecto.UUID.generate()

      changeset = JournalEntry.close_changeset(entry, closed_at, closed_by)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :closed_at) == closed_at
      assert Ecto.Changeset.get_change(changeset, :closed_by) == closed_by

      assert Enum.any?(
               changeset.constraints,
               &(&1.constraint == "journal_entries_closure_pair_ck")
             )
    end

    test "reopen_changeset/1 clears closed_at and closed_by together and attaches check constraint" do
      entry = %JournalEntry{
        closed_at: ~U[2026-07-21 12:00:00.000000Z],
        closed_by: Ecto.UUID.generate()
      }

      changeset = JournalEntry.reopen_changeset(entry)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :closed_at) == nil
      assert Ecto.Changeset.get_change(changeset, :closed_by) == nil

      assert Enum.any?(
               changeset.constraints,
               &(&1.constraint == "journal_entries_closure_pair_ck")
             )
    end

    test "sync_changeset/2 ignores client-supplied closure fields" do
      entry = %JournalEntry{}

      changeset =
        JournalEntry.sync_changeset(entry, %{
          "closed_at" => "2026-07-21T12:00:00Z",
          "closed_by" => Ecto.UUID.generate(),
          "body" => "updated"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :body) == "updated"
      refute Map.has_key?(changeset.changes, :closed_at)
      refute Map.has_key?(changeset.changes, :closed_by)
    end
  end

  describe "journal list options" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, version.id,
          stop_id: "station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      scope = %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_id: station.id,
        station_stop_id: station.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      {:ok, scope: scope}
    end

    test "default list_station_journal/1 is equivalent to status: :all, order: :asc, limit: nil",
         %{
           scope: scope
         } do
      open_id = Ecto.UUID.generate()
      closed_id = Ecto.UUID.generate()

      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{
          id: open_id,
          target_type: "station",
          captured_at: ~U[2026-07-13 10:00:00Z]
        }),
        entry_attrs(%{
          id: closed_id,
          target_type: "station",
          captured_at: ~U[2026-07-13 11:00:00Z]
        })
      ])

      {:ok, _closed} = Gtfs.close_journal_entry(scope, closed_id)

      default_list = Gtfs.list_station_journal(scope)
      explicit_list = Gtfs.list_station_journal(scope, status: :all, order: :asc, limit: nil)

      assert Enum.map(default_list, & &1.id) == [open_id, closed_id]
      assert Enum.map(default_list, & &1.id) == Enum.map(explicit_list, & &1.id)
    end

    test "status: :open excludes closed entries", %{scope: scope} do
      open_id = Ecto.UUID.generate()
      closed_id = Ecto.UUID.generate()

      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{
          id: open_id,
          target_type: "station",
          captured_at: ~U[2026-07-13 10:00:00Z]
        }),
        entry_attrs(%{
          id: closed_id,
          target_type: "station",
          captured_at: ~U[2026-07-13 11:00:00Z]
        })
      ])

      {:ok, _closed} = Gtfs.close_journal_entry(scope, closed_id)

      open_entries = Gtfs.list_station_journal(scope, status: :open)
      assert Enum.map(open_entries, & &1.id) == [open_id]
    end

    test "order: :desc reverses entry sort keys without reversing photo order", %{scope: scope} do
      e1_id = Ecto.UUID.generate()
      e2_id = Ecto.UUID.generate()

      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{
          id: e1_id,
          target_type: "station",
          captured_at: ~U[2026-07-13 10:00:00.000000Z]
        }),
        entry_attrs(%{
          id: e2_id,
          target_type: "station",
          captured_at: ~U[2026-07-13 11:00:00.000000Z]
        })
      ])

      p1 =
        Repo.insert!(%JournalPhoto{
          id: Ecto.UUID.generate(),
          journal_entry_id: e2_id,
          filename: "1.jpg",
          content_type: "image/jpeg",
          byte_size: 10,
          sha256: :crypto.strong_rand_bytes(32),
          captured_at: ~U[2026-07-13 08:00:00.000000Z]
        })

      p2 =
        Repo.insert!(%JournalPhoto{
          id: Ecto.UUID.generate(),
          journal_entry_id: e2_id,
          filename: "2.jpg",
          content_type: "image/jpeg",
          byte_size: 10,
          sha256: :crypto.strong_rand_bytes(32),
          captured_at: ~U[2026-07-13 09:00:00.000000Z]
        })

      asc_entries = Gtfs.list_station_journal(scope, order: :asc)
      desc_entries = Gtfs.list_station_journal(scope, order: :desc)

      assert Enum.map(asc_entries, & &1.id) == [e1_id, e2_id]
      assert Enum.map(desc_entries, & &1.id) == [e2_id, e1_id]

      [top_desc | _] = desc_entries
      assert Enum.map(top_desc.photos, & &1.id) == [p1.id, p2.id]
    end

    test "entry sort order breaks ties on inserted_at and id", %{scope: scope} do
      same_time = ~U[2026-07-13 10:00:00.000000Z]
      id1 = "10000000-0000-0000-0000-000000000001"
      id2 = "10000000-0000-0000-0000-000000000002"

      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{id: id1, target_type: "station", captured_at: same_time}),
        entry_attrs(%{id: id2, target_type: "station", captured_at: same_time})
      ])

      asc_entries = Gtfs.list_station_journal(scope, order: :asc)
      desc_entries = Gtfs.list_station_journal(scope, order: :desc)

      assert Enum.map(asc_entries, & &1.id) == [id1, id2]
      assert Enum.map(desc_entries, & &1.id) == [id2, id1]
    end

    test "limit truncates returned list", %{scope: scope} do
      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{
          id: Ecto.UUID.generate(),
          target_type: "station",
          captured_at: ~U[2026-07-13 10:00:00Z]
        }),
        entry_attrs(%{
          id: Ecto.UUID.generate(),
          target_type: "station",
          captured_at: ~U[2026-07-13 11:00:00Z]
        }),
        entry_attrs(%{
          id: Ecto.UUID.generate(),
          target_type: "station",
          captured_at: ~U[2026-07-13 12:00:00Z]
        })
      ])

      entries = Gtfs.list_station_journal(scope, limit: 2)
      assert length(entries) == 2
    end

    test "open status, descending three-key entry order, and positive limit compose deterministically",
         %{
           scope: scope
         } do
      e1_id = Ecto.UUID.generate()
      e2_id = Ecto.UUID.generate()
      e3_id = Ecto.UUID.generate()
      e4_id = Ecto.UUID.generate()

      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{id: e1_id, target_type: "station", captured_at: ~U[2026-07-13 10:00:00Z]}),
        entry_attrs(%{id: e2_id, target_type: "station", captured_at: ~U[2026-07-13 11:00:00Z]}),
        entry_attrs(%{id: e3_id, target_type: "station", captured_at: ~U[2026-07-13 12:00:00Z]}),
        entry_attrs(%{id: e4_id, target_type: "station", captured_at: ~U[2026-07-13 13:00:00Z]})
      ])

      {:ok, _closed} = Gtfs.close_journal_entry(scope, e2_id)

      composed_entries = Gtfs.list_station_journal(scope, status: :open, order: :desc, limit: 2)
      assert Enum.map(composed_entries, & &1.id) == [e4_id, e3_id]
    end

    test "raises ArgumentError for unknown options, non-keyword lists, or invalid values", %{
      scope: scope
    } do
      assert_raise ArgumentError, fn ->
        Gtfs.list_station_journal(scope, [1, 2, 3])
      end

      assert_raise ArgumentError, fn ->
        Gtfs.list_station_journal(scope, unknown_opt: true)
      end

      assert_raise ArgumentError, fn ->
        Gtfs.list_station_journal(scope, status: :invalid_status)
      end

      assert_raise ArgumentError, fn ->
        Gtfs.list_station_journal(scope, order: :invalid_order)
      end

      assert_raise ArgumentError, fn ->
        Gtfs.list_station_journal(scope, limit: 0)
      end

      assert_raise ArgumentError, fn ->
        Gtfs.list_station_journal(scope, limit: -1)
      end

      assert_raise ArgumentError, fn ->
        Gtfs.list_station_journal(scope, limit: "10")
      end
    end
  end

  describe "close and reopen lifecycle" do
    setup do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      station =
        stop_fixture(organization.id, version.id,
          stop_id: "station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      scope = %Scope{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        station_id: station.id,
        station_stop_id: station.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      {:ok, scope: scope}
    end

    test "closing an open entry sets closed_at and closed_by", %{scope: scope} do
      id = Ecto.UUID.generate()
      Gtfs.sync_journal_entries(scope, [entry_attrs(%{id: id, target_type: "station"})])

      before_time = DateTime.utc_now()
      assert {:ok, closed_entry} = Gtfs.close_journal_entry(scope, id)
      after_time = DateTime.utc_now()

      assert closed_entry.closed_by == scope.actor_id
      assert DateTime.compare(closed_entry.closed_at, before_time) in [:gt, :eq]
      assert DateTime.compare(closed_entry.closed_at, after_time) in [:lt, :eq]

      persisted = Repo.get!(JournalEntry, id)
      assert persisted.closed_by == scope.actor_id
      assert persisted.closed_at == closed_entry.closed_at
    end

    test "closing an already closed entry is idempotent and emits no changes", %{scope: scope} do
      id = Ecto.UUID.generate()
      Gtfs.sync_journal_entries(scope, [entry_attrs(%{id: id, target_type: "station"})])

      {:ok, closed1} = Gtfs.close_journal_entry(scope, id)
      {:ok, closed2} = Gtfs.close_journal_entry(scope, id)

      assert closed1.closed_at == closed2.closed_at
      assert closed1.closed_by == closed2.closed_by
    end

    test "reopening a closed entry clears closure fields", %{scope: scope} do
      id = Ecto.UUID.generate()
      Gtfs.sync_journal_entries(scope, [entry_attrs(%{id: id, target_type: "station"})])

      {:ok, closed} = Gtfs.close_journal_entry(scope, id)
      refute is_nil(closed.closed_at)

      assert {:ok, reopened} = Gtfs.reopen_journal_entry(scope, id)
      assert is_nil(reopened.closed_at)
      assert is_nil(reopened.closed_by)

      persisted = Repo.get!(JournalEntry, id)
      assert is_nil(persisted.closed_at)
      assert is_nil(persisted.closed_by)
    end

    test "reopening an open entry is idempotent", %{scope: scope} do
      id = Ecto.UUID.generate()
      Gtfs.sync_journal_entries(scope, [entry_attrs(%{id: id, target_type: "station"})])

      assert {:ok, open_entry} = Gtfs.reopen_journal_entry(scope, id)
      assert is_nil(open_entry.closed_at)
      assert is_nil(open_entry.closed_by)
    end

    test "malformed, missing, or cross-scope entry id returns {:error, :not_found}", %{
      scope: scope
    } do
      assert {:error, :not_found} = Gtfs.close_journal_entry(scope, "invalid-uuid")
      assert {:error, :not_found} = Gtfs.close_journal_entry(scope, Ecto.UUID.generate())
      assert {:error, :not_found} = Gtfs.reopen_journal_entry(scope, "invalid-uuid")
      assert {:error, :not_found} = Gtfs.reopen_journal_entry(scope, Ecto.UUID.generate())

      other_org = organization_fixture()
      other_ver = gtfs_version_fixture(other_org.id)

      other_station =
        stop_fixture(other_org.id, other_ver.id,
          stop_id: "station_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      other_scope = %Scope{
        organization_id: other_org.id,
        gtfs_version_id: other_ver.id,
        station_id: other_station.id,
        station_stop_id: other_station.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      other_id = Ecto.UUID.generate()

      Gtfs.sync_journal_entries(other_scope, [
        entry_attrs(%{id: other_id, target_type: "station"})
      ])

      assert {:error, :not_found} = Gtfs.close_journal_entry(scope, other_id)
      assert {:error, :not_found} = Gtfs.reopen_journal_entry(scope, other_id)
    end

    test "concurrent transitions on the same entry row serialize without error", %{scope: scope} do
      id = Ecto.UUID.generate()
      Gtfs.sync_journal_entries(scope, [entry_attrs(%{id: id, target_type: "station"})])

      parent = self()

      task1 =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:ready, 1})

          receive do
            :go -> Gtfs.close_journal_entry(scope, id)
          end
        end)

      task2 =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {:ready, 2})

          receive do
            :go -> Gtfs.reopen_journal_entry(scope, id)
          end
        end)

      assert_receive {:ready, 1}
      assert_receive {:ready, 2}

      send(task1.pid, :go)
      send(task2.pid, :go)

      Task.await(task1)
      Task.await(task2)

      entry = Repo.get!(JournalEntry, id)
      assert is_nil(entry.closed_at) or not is_nil(entry.closed_at)
    end

    test "replay sync on a closed entry preserves closure fields", %{scope: scope} do
      id = Ecto.UUID.generate()

      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{id: id, target_type: "station", body: "initial"})
      ])

      {:ok, closed} = Gtfs.close_journal_entry(scope, id)

      Gtfs.sync_journal_entries(scope, [
        entry_attrs(%{id: id, target_type: "station", body: "updated body"})
      ])

      synced = Repo.get!(JournalEntry, id)
      assert synced.body == "updated body"
      assert synced.closed_at == closed.closed_at
      assert synced.closed_by == closed.closed_by
    end
  end

  describe "scoped notifications" do
    setup do
      previous = Application.get_env(:gtfs_planner, :uploads_path)

      root =
        Path.join(
          System.tmp_dir!(),
          "station_journal_notifications_#{System.unique_integer([:positive])}"
        )

      Application.put_env(:gtfs_planner, :uploads_path, root)

      on_exit(fn ->
        File.rm_rf!(root)

        if is_nil(previous),
          do: Application.delete_env(:gtfs_planner, :uploads_path),
          else: Application.put_env(:gtfs_planner, :uploads_path, previous)
      end)

      org_a = organization_fixture()
      ver_a = gtfs_version_fixture(org_a.id)

      station_a =
        stop_fixture(org_a.id, ver_a.id,
          stop_id: "station_a_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      scope_a = %Scope{
        organization_id: org_a.id,
        gtfs_version_id: ver_a.id,
        station_id: station_a.id,
        station_stop_id: station_a.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      org_b = organization_fixture()
      ver_b = gtfs_version_fixture(org_b.id)

      station_b =
        stop_fixture(org_b.id, ver_b.id,
          stop_id: "station_b_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      scope_b = %Scope{
        organization_id: org_b.id,
        gtfs_version_id: ver_b.id,
        station_id: station_b.id,
        station_stop_id: station_b.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      ver_a_2 = gtfs_version_fixture(org_a.id)

      station_a_2 =
        stop_fixture(org_a.id, ver_a_2.id,
          stop_id: "station_a2_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      scope_c = %Scope{
        organization_id: org_a.id,
        gtfs_version_id: ver_a_2.id,
        station_id: station_a_2.id,
        station_stop_id: station_a_2.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      station_a_3 =
        stop_fixture(org_a.id, ver_a.id,
          stop_id: "station_a3_#{System.unique_integer([:positive])}",
          location_type: 1
        )

      scope_d = %Scope{
        organization_id: org_a.id,
        gtfs_version_id: ver_a.id,
        station_id: station_a_3.id,
        station_stop_id: station_a_3.stop_id,
        actor_id: Ecto.UUID.generate()
      }

      {:ok, scope_a: scope_a, scope_b: scope_b, scope_c: scope_c, scope_d: scope_d}
    end

    test "subscribes and receives notifications for synced entries", %{
      scope_a: scope_a,
      scope_b: scope_b,
      scope_c: scope_c,
      scope_d: scope_d
    } do
      assert :ok = Gtfs.subscribe_station_journal(scope_a)

      id_a = Ecto.UUID.generate()

      assert %{synced_count: 1} =
               Gtfs.sync_journal_entries(scope_a, [
                 entry_attrs(%{id: id_a, target_type: "station"})
               ])

      station_id_a = scope_a.station_id
      assert_receive {:station_journal_changed, ^station_id_a}

      # Sync with 0 accepted entries emits no notification
      invalid_id = Ecto.UUID.generate()

      assert %{synced_count: 0} =
               Gtfs.sync_journal_entries(scope_a, [
                 entry_attrs(%{
                   id: invalid_id,
                   target_type: "pathway",
                   target_id: Ecto.UUID.generate()
                 })
               ])

      refute_receive {:station_journal_changed, _}

      # Foreign organization (Scope B) mutations do not notify Scope A subscriber
      Gtfs.sync_journal_entries(scope_b, [
        entry_attrs(%{id: Ecto.UUID.generate(), target_type: "station"})
      ])

      refute_receive {:station_journal_changed, _}

      # Foreign GTFS version (Scope C) mutations do not notify Scope A subscriber
      Gtfs.sync_journal_entries(scope_c, [
        entry_attrs(%{id: Ecto.UUID.generate(), target_type: "station"})
      ])

      refute_receive {:station_journal_changed, _}

      # Foreign station (Scope D) mutations do not notify Scope A subscriber
      Gtfs.sync_journal_entries(scope_d, [
        entry_attrs(%{id: Ecto.UUID.generate(), target_type: "station"})
      ])

      refute_receive {:station_journal_changed, _}
    end

    test "notifies on successful close and reopen transitions but silent on no-op and missing ids",
         %{scope_a: scope_a} do
      id = Ecto.UUID.generate()
      Gtfs.sync_journal_entries(scope_a, [entry_attrs(%{id: id, target_type: "station"})])

      assert :ok = Gtfs.subscribe_station_journal(scope_a)
      station_id = scope_a.station_id

      # Close transition emits notification
      {:ok, _} = Gtfs.close_journal_entry(scope_a, id)
      assert_receive {:station_journal_changed, ^station_id}

      # Idempotent close no-op emits no notification
      {:ok, _} = Gtfs.close_journal_entry(scope_a, id)
      refute_receive {:station_journal_changed, _}

      # Reopen transition emits notification
      {:ok, _} = Gtfs.reopen_journal_entry(scope_a, id)
      assert_receive {:station_journal_changed, ^station_id}

      # Idempotent reopen no-op emits no notification
      {:ok, _} = Gtfs.reopen_journal_entry(scope_a, id)
      refute_receive {:station_journal_changed, _}

      # Missing entry emits no notification
      {:error, :not_found} = Gtfs.close_journal_entry(scope_a, Ecto.UUID.generate())
      refute_receive {:station_journal_changed, _}
    end

    test "notifies on photo creation and retry but silent on photo error", %{scope_a: scope_a} do
      id = Ecto.UUID.generate()
      Gtfs.sync_journal_entries(scope_a, [entry_attrs(%{id: id, target_type: "station"})])

      assert :ok = Gtfs.subscribe_station_journal(scope_a)
      station_id = scope_a.station_id

      tmp_file = Path.join(System.tmp_dir!(), "upload_#{System.unique_integer([:positive])}.jpg")
      File.write!(tmp_file, <<0xFF, 0xD8, "photo_bytes", 0xFF, 0xD9>>)

      on_exit(fn -> File.rm(tmp_file) end)

      photo_id = Ecto.UUID.generate()
      upload = %{path: tmp_file, filename: "photo.jpg", content_type: "image/jpeg"}

      attrs = %{
        id: photo_id,
        journal_entry_id: id,
        captured_at: ~U[2026-07-21 12:00:00Z],
        width: 100,
        height: 100
      }

      # Successful photo creation notifies
      assert {:ok, _photo} = Gtfs.create_journal_photo(scope_a, attrs, upload)
      assert_receive {:station_journal_changed, ^station_id}

      # Idempotent retry notifies
      assert {:ok, _photo} = Gtfs.create_journal_photo(scope_a, attrs, upload)
      assert_receive {:station_journal_changed, ^station_id}

      # Photo error emits no notification
      assert {:error, :not_found} =
               Gtfs.create_journal_photo(
                 scope_a,
                 Map.put(attrs, :id, Ecto.UUID.generate())
                 |> Map.put(:journal_entry_id, Ecto.UUID.generate()),
                 upload
               )

      refute_receive {:station_journal_changed, _}
    end

    test "refresh_pin_coordinates_for_stop_level/3 remains notification-free", %{
      scope_a: scope_a
    } do
      assert :ok = Gtfs.subscribe_station_journal(scope_a)

      level =
        level_fixture(scope_a.organization_id, scope_a.gtfs_version_id, level_id: "L1_NOTIF")

      {:ok, stop_level} =
        Gtfs.create_stop_level(%{
          organization_id: scope_a.organization_id,
          gtfs_version_id: scope_a.gtfs_version_id,
          stop_id: scope_a.station_id,
          level_id: level.id
        })

      pin_id = Ecto.UUID.generate()

      assert %{synced_count: 1} =
               Gtfs.sync_journal_entries(scope_a, [
                 entry_attrs(%{
                   id: pin_id,
                   target_type: "pin",
                   stop_level_id: stop_level.id,
                   diagram_x: 50.0,
                   diagram_y: 40.0
                 })
               ])

      station_id_a = scope_a.station_id
      assert_receive {:station_journal_changed, ^station_id_a}

      {:ok, aligned_stop_level} =
        Gtfs.update_stop_level_alignment(stop_level, %{
          floorplan_center_lat: 40.7128,
          floorplan_center_lon: -74.006,
          floorplan_scale_mpp: 0.25,
          floorplan_rotation_deg: 0.0
        })

      assert {:ok, 1} =
               Gtfs.refresh_pin_coordinates_for_stop_level(aligned_stop_level, 1000, 800)

      # CRIT-005: refresh_pin_coordinates_for_stop_level must not broadcast
      refute_receive {:station_journal_changed, _}
    end
  end

  defp entry_attrs(attrs) do
    Map.merge(%{id: @entry_id, captured_at: @captured_at}, attrs)
  end

  defp run_concurrent_syncs(requests) do
    parent = self()

    tasks =
      Enum.map(requests, fn {scope, attrs} ->
        start_supervised!(%{
          Task.child_spec(fn ->
            send(parent, {:sync_ready, self()})

            receive do
              :sync ->
                result = Gtfs.sync_journal_entries(scope, [attrs])
                send(parent, {:sync_finished, self(), result})
            end
          end)
          | id: make_ref()
        })
      end)

    Enum.each(tasks, fn task ->
      assert_receive {:sync_ready, ^task}
    end)

    Enum.each(tasks, &send(&1, :sync))

    Enum.map(tasks, fn task ->
      assert_receive {:sync_finished, ^task, result}
      result
    end)
  end
end

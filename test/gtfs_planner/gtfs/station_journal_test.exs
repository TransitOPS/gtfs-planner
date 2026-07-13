defmodule GtfsPlanner.Gtfs.StationJournalTest do
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.{JournalEntry, JournalPhoto}
  alias GtfsPlanner.Gtfs.StationJournal.Scope

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
      station = JournalEntry.create_changeset(%JournalEntry{}, entry_attrs(%{target_type: "station"}), @scope)

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
          entry_attrs(%{id: Ecto.UUID.generate(), target_type: "pin", stop_level_id: @level_id, diagram_x: 50.0, diagram_y: 40.0}),
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
          entry_attrs(%{target_type: "pin", target_id: @target_id, stop_level_id: @level_id, diagram_x: -1.0, diagram_y: 0.0}),
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
               Gtfs.resolve_station_journal_scope(organization.id, version.id, station.id, actor_id)

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

    test "keeps scope and audit fields immutable while same-scope replay updates body", %{scope: scope} do
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

    test "returns entries and photos in deterministic capture order including closed history", %{scope: scope} do
      later_id = Ecto.UUID.generate()
      earlier_id = Ecto.UUID.generate()

      assert %{synced_count: 2, errors: []} =
               Gtfs.sync_journal_entries(scope, [
                 entry_attrs(%{id: later_id, target_type: "station", captured_at: ~U[2026-07-13 12:01:00Z]}),
                 entry_attrs(%{id: earlier_id, target_type: "station", captured_at: ~U[2026-07-13 12:00:00Z]})
               ])

      assert Enum.map(Gtfs.list_station_journal(scope), & &1.id) == [earlier_id, later_id]
    end
  end

  defp entry_attrs(attrs) do
    Map.merge(%{id: @entry_id, captured_at: @captured_at}, attrs)
  end
end

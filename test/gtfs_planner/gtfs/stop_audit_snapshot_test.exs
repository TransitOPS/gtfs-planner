defmodule GtfsPlanner.Gtfs.StopAuditSnapshotTest do
  @moduledoc """
  The stop editor writes a sign number, a spoken name and a web page, and
  Settings › Fares writes a zone. An audit entry that omitted them would lose
  them from the station diagram's history and from any rollback, so
  `snapshot_stop/1` records all four and `reversible_fields_for("stop")` names
  the three the editor can change. The zone stays out of the reversible list
  because Settings › Fares owns it.
  """

  use GtfsPlanner.DataCase

  import Ecto.Query
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.AuditContext
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    ctx = %AuditContext{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      station_stop_id: "ST-NTC",
      actor_id: Ecto.UUID.generate(),
      actor_email: "editor@example.com"
    }

    %{organization: organization, version: version, ctx: ctx}
  end

  defp own_logs(organization_id) do
    from(log in ChangeLog, where: log.organization_id == ^organization_id)
  end

  # `stop_fixture/3` goes through `Gtfs.create_stop/1`, which uses the importer's
  # permissive `Stop.changeset/2` and so casts none of the four fields under test.
  # The stop editor casts the first three through `Stop.editor_changeset/2` (step 1)
  # and Settings › Fares writes `zone_id` directly, so the fixture sets all four the
  # way their real writers do.
  defp with_editor_fields(stop, fields) do
    stop
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end

  test "a stop's audit entry records the sign number, spoken name, web page and zone", %{
    organization: organization,
    version: version,
    ctx: ctx
  } do
    stop =
      organization.id
      |> stop_fixture(version.id, %{stop_id: "1434", stop_name: "Southeast First Street"})
      |> with_editor_fields(%{
        stop_code: "1434",
        tts_stop_name: "Southeast First Street",
        stop_url: "https://northcoast.example/stops/1434",
        zone_id: "NL"
      })

    assert :ok = Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "SE First St"})

    [log] = Repo.all(own_logs(organization.id))

    assert log.snapshot["stop_code"] == "1434"
    assert log.snapshot["tts_stop_name"] == "Southeast First Street"
    assert log.snapshot["stop_url"] == "https://northcoast.example/stops/1434"
    assert log.snapshot["zone_id"] == "NL"
  end

  test "a created stop's audit entry records the same four fields", %{
    organization: organization,
    version: version,
    ctx: ctx
  } do
    stop =
      organization.id
      |> stop_fixture(version.id, %{stop_id: "SNAP_CREATED", stop_name: "Bay Street"})
      |> with_editor_fields(%{
        stop_code: "2001",
        tts_stop_name: "Bay Street",
        stop_url: "https://northcoast.example/stops/2001"
      })

    assert :ok = Gtfs.record_change(ctx, :stop, stop, "created", %{})

    [log] = Repo.all(own_logs(organization.id))

    assert log.action == "created"
    assert log.snapshot["stop_code"] == "2001"
    assert log.snapshot["tts_stop_name"] == "Bay Street"
    assert log.snapshot["stop_url"] == "https://northcoast.example/stops/2001"
    assert Map.has_key?(log.snapshot, "zone_id")
  end

  test "a deleted stop's audit entry still records them", %{
    organization: organization,
    version: version,
    ctx: ctx
  } do
    stop =
      organization.id
      |> stop_fixture(version.id, %{stop_id: "SNAP_DELETED", stop_name: "Harbor Way"})
      |> with_editor_fields(%{
        stop_code: "2002",
        stop_url: "https://northcoast.example/stops/2002"
      })

    assert :ok = Gtfs.record_change(ctx, :stop, stop, "deleted", %{})

    [log] = Repo.all(own_logs(organization.id))

    assert log.action == "deleted"
    assert log.snapshot["stop_code"] == "2002"
    assert log.snapshot["stop_url"] == "https://northcoast.example/stops/2002"
  end

  test "an absent field records nil rather than dropping the key", %{
    organization: organization,
    version: version,
    ctx: ctx
  } do
    stop =
      stop_fixture(organization.id, version.id, %{
        stop_id: "SNAP_BARE",
        stop_name: "Plain Street"
      })

    assert :ok = Gtfs.record_change(ctx, :stop, stop, "updated", %{stop_name: "Plain St"})

    [log] = Repo.all(own_logs(organization.id))

    assert Map.has_key?(log.snapshot, "stop_code")
    assert log.snapshot["stop_code"] == nil
  end

  describe "reversible_fields_for(\"stop\")" do
    test "includes the three editor-owned fields" do
      fields = Gtfs.reversible_fields_for("stop")

      assert "stop_code" in fields
      assert "tts_stop_name" in fields
      assert "stop_url" in fields
    end

    test "excludes the fare zone, which Settings › Fares owns" do
      refute "zone_id" in Gtfs.reversible_fields_for("stop")
    end

    test "still excludes the stop ID, which never changes" do
      fields = Gtfs.reversible_fields_for("stop")

      refute "stop_id" in fields
      assert Gtfs.identity_fields_for("stop") == ~w(stop_id)
    end

    test "the atom form matches the string form" do
      assert Gtfs.reversible_fields_for(:stop) == Gtfs.reversible_fields_for("stop")
    end
  end

  test "an edited sign number is recorded as a reversible change", %{
    organization: organization,
    version: version,
    ctx: ctx
  } do
    stop =
      organization.id
      |> stop_fixture(version.id, %{stop_id: "SNAP_CHANGED", stop_name: "Elm Street"})
      |> with_editor_fields(%{
        stop_code: "3001",
        stop_url: "https://northcoast.example/stops/3001"
      })

    assert :ok =
             Gtfs.record_change(ctx, :stop, stop, "updated", %{
               stop_code: "3001-B",
               stop_url: "https://northcoast.example/stops/3001-b",
               zone_id: "NL"
             })

    [log] = Repo.all(own_logs(organization.id))

    assert log.changed_fields["stop_code"] == %{"from" => "3001", "to" => "3001-B"}

    assert log.changed_fields["stop_url"] == %{
             "from" => "https://northcoast.example/stops/3001",
             "to" => "https://northcoast.example/stops/3001-b"
           }

    refute Map.has_key?(log.changed_fields, "zone_id")
  end
end

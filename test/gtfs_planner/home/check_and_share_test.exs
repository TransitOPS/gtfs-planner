defmodule GtfsPlanner.Home.CheckAndShareTest do
  @moduledoc """
  Check-and-share facts through the real reads.

  Export runs are inserted as rows directly so each case states the run's
  state, timestamps and artifact expiry explicitly, and change logs are
  inserted against the export's finish time. The expiry cases reload the run
  after the read, so an unswept artifact is reported as expired without the
  read sweeping it.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Home
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations.ValidationRun

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    %{organization: organization, version: version}
  end

  test "a ready export three minutes past expiry reports expired without being swept", context do
    now = DateTime.utc_now()
    finished_at = DateTime.add(now, -10, :minute)
    expires_at = DateTime.add(now, -3, :minute)

    run =
      insert_export(context.organization, context.version, %{
        export_type: :full,
        artifact_expires_at: expires_at,
        started_at: DateTime.add(now, -20, :minute),
        finished_at: finished_at
      })

    assert %{export: export} =
             Home.check_and_share(context.organization.id, context.version.id, :planner)

    assert export.run_id == run.id
    assert export.type == :full
    assert export.state == :ready
    assert export.expired? == true
    assert export.finished_at == finished_at

    assert Repo.get!(Run, run.id).state == :ready
  end

  test "a swept export reports expired from its state", context do
    run =
      insert_export(context.organization, context.version, %{
        export_type: :full,
        state: :expired,
        artifact_key: nil,
        artifact_filename: nil,
        artifact_sha256: nil,
        artifact_size_bytes: nil,
        artifact_expires_at: nil
      })

    assert %{export: export} =
             Home.check_and_share(context.organization.id, context.version.id, :planner)

    assert export.run_id == run.id
    assert export.state == :expired
    assert export.expired? == true
    assert Repo.get!(Run, run.id).state == :expired
  end

  test "a Pathways organization reads its pathways export and ignores a newer full export",
       context do
    pathways_run =
      insert_export(context.organization, context.version, %{
        export_type: :pathways,
        started_at: ~U[2026-09-20 09:50:00.000000Z],
        finished_at: ~U[2026-09-20 10:00:00.000000Z],
        inserted_at: ~U[2026-09-20 10:00:00.000000Z],
        updated_at: ~U[2026-09-20 10:00:00.000000Z]
      })

    full_run =
      insert_export(context.organization, context.version, %{
        export_type: :full,
        started_at: ~U[2026-09-21 09:50:00.000000Z],
        finished_at: ~U[2026-09-21 10:00:00.000000Z],
        inserted_at: ~U[2026-09-21 10:00:00.000000Z],
        updated_at: ~U[2026-09-21 10:00:00.000000Z]
      })

    assert %{export: %{run_id: pathways_run_id, type: :pathways}} =
             Home.check_and_share(context.organization.id, context.version.id, :pathways)

    assert pathways_run_id == pathways_run.id

    assert %{export: %{run_id: full_run_id, type: :full}} =
             Home.check_and_share(context.organization.id, context.version.id, :planner)

    assert full_run_id == full_run.id
  end

  test "a six-row operation after the export counts one change and two stations", context do
    finished_at = ~U[2026-09-20 12:00:00.000000Z]
    operation_id = Ecto.UUID.generate()

    run =
      insert_export(context.organization, context.version, %{
        export_type: :full,
        started_at: ~U[2026-09-20 11:50:00.000000Z],
        finished_at: finished_at
      })

    operation_rows =
      for index <- 1..6 do
        %{
          entity_external_id: "TRIP-#{index}",
          station_stop_id: if(index <= 3, do: "STA", else: "STB"),
          changed_fields: %{"operation_id" => operation_id},
          inserted_at: ~U[2026-09-20 13:00:00.000000Z]
        }
      end

    # At the finish instant exactly, so the strict `inserted_at > since` boundary is pinned.
    boundary_row = %{
      entity_external_id: "TRIP-BEFORE",
      station_stop_id: "STC",
      changed_fields: %{"operation_id" => Ecto.UUID.generate()},
      inserted_at: finished_at
    }

    insert_logs(context.organization, context.version, [boundary_row | operation_rows])

    assert %{export: %{run_id: run_id}, since: since} =
             Home.check_and_share(context.organization.id, context.version.id, :planner)

    assert run_id == run.id
    assert since == %{changes: 1, stations: 2}
  end

  test "a version with no export and no check reports nothing", context do
    assert Home.check_and_share(context.organization.id, context.version.id, :planner) ==
             %{check: nil, export: nil, since: nil}
  end

  test "the check is the newest mobility_data run and ignores a newer reachability run",
       context do
    check =
      insert_check(context.organization, context.version, %{
        errors_count: 2,
        warnings_count: 3,
        started_at: ~U[2026-09-20 09:00:00.000000Z]
      })

    insert_check(context.organization, context.version, %{
      run_type: "station_reachability",
      errors_count: 5,
      started_at: ~U[2026-09-20 10:00:00.000000Z]
    })

    assert %{check: check_facts} =
             Home.check_and_share(context.organization.id, context.version.id, :planner)

    assert check_facts == %{
             run_id: check.id,
             errors: 2,
             warnings: 3,
             at: ~U[2026-09-20 09:00:00.000000Z]
           }
  end

  defp insert_export(organization, version, attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      organization_id: organization.id,
      gtfs_version_id: version.id,
      export_type: :full,
      state: :ready,
      phase: :cleanup,
      artifact_key: "exports/#{Ecto.UUID.generate()}.zip",
      artifact_filename: "gtfs.zip",
      artifact_sha256: String.duplicate("a", 64),
      artifact_size_bytes: 1024,
      artifact_expires_at: ~U[2026-09-21 12:00:00.000000Z],
      started_at: ~U[2026-09-20 11:50:00.000000Z],
      finished_at: ~U[2026-09-20 12:00:00.000000Z],
      inserted_at: ~U[2026-09-20 12:00:00.000000Z],
      updated_at: ~U[2026-09-20 12:00:00.000000Z]
    }

    Repo.insert!(struct!(Run, Map.merge(defaults, Map.new(attrs))))
  end

  defp insert_logs(organization, gtfs_version, rows) do
    rows
    |> Enum.map(fn row ->
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          entity_type: "trip",
          entity_id: Ecto.UUID.generate(),
          entity_external_id: Ecto.UUID.generate(),
          station_stop_id: nil,
          actor_id: Ecto.UUID.generate(),
          actor_email: "teammate@example.test",
          snapshot: nil,
          changed_fields: nil,
          action: "updated",
          organization_id: organization.id,
          gtfs_version_id: gtfs_version.id,
          inserted_at: ~U[2026-09-01 12:00:00.000000Z]
        },
        Map.new(row)
      )
    end)
    |> then(&Repo.insert_all(ChangeLog, &1))
  end

  defp insert_check(organization, version, attrs) do
    attrs =
      Map.merge(
        %{
          run_type: "mobility_data",
          status: "completed",
          errors_count: 0,
          warnings_count: 0,
          infos_count: 0,
          started_at: ~U[2026-09-20 09:00:00.000000Z]
        },
        Map.new(attrs)
      )

    %ValidationRun{
      id: Ecto.UUID.generate(),
      organization_id: organization.id,
      gtfs_version_id: version.id
    }
    |> ValidationRun.changeset(attrs)
    |> Repo.insert!()
  end
end

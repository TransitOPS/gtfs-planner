defmodule GtfsPlanner.Gtfs.Export.RunTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.OrganizationsFixtures
  alias GtfsPlanner.VersionsFixtures

  describe "system-owned changesets" do
    setup do
      organization = OrganizationsFixtures.organization_fixture()
      version = VersionsFixtures.gtfs_version_fixture(organization.id)

      %{run: %Run{organization_id: organization.id, gtfs_version_id: version.id}}
    end

    test "does not cast scope, actor, lease, artifact, receipt, or lifecycle fields from public params",
         %{
           run: run
         } do
      changeset =
        Run.changeset(run, %{
          organization_id: Ecto.UUID.generate(),
          gtfs_version_id: Ecto.UUID.generate(),
          actor_id: Ecto.UUID.generate(),
          lease_token: Ecto.UUID.generate(),
          state: :ready,
          artifact_key: "untrusted.zip",
          artifact_sha256: String.duplicate("f", 64),
          download_count: 100
        })

      assert changeset.valid?
      assert changeset.changes == %{}
    end

    test "system changeset validates ready artifact metadata, progress, and bounded warnings", %{
      run: run
    } do
      valid =
        Run.system_changeset(run, %{
          export_type: :full,
          state: :ready,
          artifact_key: "export-runs/org/version/run/archive.zip",
          artifact_filename: "export.zip",
          artifact_sha256: String.duplicate("a", 64),
          artifact_size_bytes: 0,
          artifact_expires_at: ~U[2026-07-22 00:00:00.000000Z],
          started_at: ~U[2026-07-21 00:00:00.000000Z],
          finished_at: ~U[2026-07-21 00:01:00.000000Z],
          warnings: [%{code: "optional_file_missing", detail: "calendar_dates"}]
        })

      assert valid.valid?

      invalid =
        Run.system_changeset(run, %{
          state: :ready,
          artifact_key: "archive.zip",
          artifact_filename: "archive.zip",
          artifact_sha256: "not-a-sha",
          artifact_size_bytes: -1,
          progress_current: 2,
          progress_total: 1,
          warnings: [%{arbitrary: String.duplicate("x", 4_097)}]
        })

      refute invalid.valid?
      assert errors_on(invalid).artifact_sha256
      assert errors_on(invalid).artifact_size_bytes
      assert errors_on(invalid).progress_current
      assert errors_on(invalid).warnings

      oversized =
        Run.system_changeset(run, %{
          artifact_key: String.duplicate("k", 256),
          artifact_filename: String.duplicate("f", 256)
        })

      refute oversized.valid?
      assert errors_on(oversized).artifact_key
      assert errors_on(oversized).artifact_filename
    end

    test "persists the operations_only export type admitted by the widened constraint", %{
      run: run
    } do
      assert {:ok, inserted} =
               Repo.insert(
                 Run.system_changeset(%Run{}, %{
                   export_type: :operations_only,
                   state: :pending,
                   organization_id: run.organization_id,
                   gtfs_version_id: run.gtfs_version_id
                 })
               )

      assert inserted.export_type == :operations_only
      assert Repo.reload(inserted).export_type == :operations_only
    end

    test "still persists every admitted export type", %{run: run} do
      for export_type <- [:full, :pathways, :operations, :operations_only] do
        assert {:ok, inserted} =
                 Repo.insert(
                   Run.system_changeset(%Run{}, %{
                     export_type: export_type,
                     state: :pending,
                     organization_id: run.organization_id,
                     gtfs_version_id: run.gtfs_version_id
                   })
                 )

        assert inserted.export_type == export_type
      end
    end

    test "rejects an export type outside the named state check", %{run: run} do
      now = DateTime.utc_now()

      assert_raise Postgrex.Error, ~r/gtfs_export_runs_state_check/, fn ->
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          INSERT INTO gtfs_export_runs
            (id, export_type, state, organization_id, gtfs_version_id, inserted_at, updated_at)
          VALUES ($1, 'bogus', 'pending', $2, $3, $4, $5)
          """,
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(run.organization_id),
            Ecto.UUID.dump!(run.gtfs_version_id),
            now,
            now
          ]
        )
      end
    end

    test "public changeset never casts the reference digest", %{run: run} do
      changeset = Run.changeset(run, %{gtfs_reference_sha256: String.duplicate("a", 64)})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :gtfs_reference_sha256) == nil
    end

    test "system changeset validates the reference digest like the artifact digest", %{run: run} do
      invalid = Run.system_changeset(run, %{gtfs_reference_sha256: "abc"})

      refute invalid.valid?
      assert errors_on(invalid).gtfs_reference_sha256

      valid = Run.system_changeset(run, %{gtfs_reference_sha256: String.duplicate("a", 64)})

      assert valid.valid?
      assert Ecto.Changeset.get_field(valid, :gtfs_reference_sha256) == String.duplicate("a", 64)
    end
  end
end

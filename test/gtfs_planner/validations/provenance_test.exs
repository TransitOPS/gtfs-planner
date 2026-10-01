defmodule GtfsPlanner.Validations.ProvenanceTest do
  @moduledoc """
  Server-owned, optional provenance of the exact checked validation input.

  Runs against the real Repo through the SQL sandbox. Expected digests, profiles
  and totals are written by hand here, never recomputed from the implementation.
  """

  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @digest String.duplicate("ab", 32)
  @flex_profile %{
    schema_version: 1,
    export_type: "full",
    include_flex: true,
    artifact_kind: "flex",
    estimate_method: nil
  }

  @notices [
    %{
      "code" => "missing_required_field",
      "severity" => "ERROR",
      "total_notices" => 4,
      "notices" => [%{"filename" => "stops.txt", "fieldName" => "stop_id"}]
    }
  ]

  # The stored jsonb column decodes with string keys, so a read profile is keyed by
  # strings while a caller passes the same profile with atom keys.
  @stored_flex_profile Map.new(@flex_profile, fn {key, value} -> {Atom.to_string(key), value} end)

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)

    {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

    %{organization: organization, run: run}
  end

  defp notices, do: @notices

  defp result(overrides \\ []) do
    struct(
      %Result{
        summary: %{errors: 4, warnings: 2, infos: 0},
        notices: notices(),
        duration_ms: 4321,
        validated_at: ~U[2026-10-01 12:00:00.000000Z]
      },
      overrides
    )
  end

  defp profile(overrides), do: Map.merge(@flex_profile, Map.new(overrides))

  describe "complete_run/4" do
    test "stores a result that captured no provenance with nil columns and an unchanged report",
         %{organization: organization, run: run} do
      {:ok, _claimed, token} = Validations.claim_run(organization.id, run.id)

      assert {:ok, completed} = Validations.complete_run(organization.id, run.id, token, result())

      assert completed.checked_zip_sha256 == nil
      assert completed.checked_export_profile == nil
      assert completed.validator_version == nil
      assert completed.errors_count == 4
      assert completed.warnings_count == 2
      assert completed.duration_ms == 4321

      persisted = Repo.get!(ValidationRun, run.id)
      assert persisted.checked_zip_sha256 == nil
      assert persisted.checked_export_profile == nil
      assert persisted.validator_version == nil
      assert persisted.result_json == %{"notices" => notices()}
    end

    test "persists captured provenance beside the report", %{organization: organization, run: run} do
      {:ok, _claimed, token} = Validations.claim_run(organization.id, run.id)

      captured =
        result(
          checked_zip_sha256: @digest,
          checked_export_profile: @flex_profile,
          validator_version: "8.0.1"
        )

      assert {:ok, completed} = Validations.complete_run(organization.id, run.id, token, captured)

      persisted = Repo.get!(ValidationRun, run.id)
      assert persisted.checked_zip_sha256 == @digest
      assert persisted.checked_export_profile == @stored_flex_profile
      assert persisted.validator_version == "8.0.1"
      assert persisted.result_json == %{"notices" => notices()}
      assert Repo.get!(ValidationRun, run.id).updated_at == persisted.updated_at
      assert completed.checked_zip_sha256 == @digest
    end

    test "a lease-lost completion writes neither the result nor the provenance",
         %{organization: organization, run: run} do
      {:ok, claimed, token} = Validations.claim_run(organization.id, run.id)

      captured =
        result(
          checked_zip_sha256: @digest,
          checked_export_profile: @flex_profile,
          validator_version: "8.0.1"
        )

      assert Validations.complete_run(organization.id, run.id, Ecto.UUID.generate(), captured) ==
               {:error, :lease_lost}

      persisted = Repo.get!(ValidationRun, run.id)
      assert persisted == claimed
      assert persisted.status == "running"
      assert persisted.result_json == nil
      assert persisted.checked_zip_sha256 == nil
      assert persisted.checked_export_profile == nil
      assert persisted.validator_version == nil

      # The owning token still completes, proving the gate never partially applied.
      assert {:ok, completed} = Validations.complete_run(organization.id, run.id, token, captured)
      assert completed.checked_zip_sha256 == @digest
    end

    test "refuses to persist a malformed digest through the legacy write path", %{run: run} do
      captured =
        result(
          checked_zip_sha256: String.duplicate("A", 64),
          checked_export_profile: @flex_profile,
          validator_version: "8.0.1"
        )

      assert {:error, changeset} = Validations.mark_completed(run, captured)
      assert {_message, _opts} = changeset.errors[:checked_zip_sha256]

      persisted = Repo.get!(ValidationRun, run.id)
      assert persisted.checked_zip_sha256 == nil
      assert persisted.checked_export_profile == nil
      assert persisted.result_json == nil
      assert persisted.status == run.status
    end
  end

  describe "mark_completed/2" do
    test "persists captured provenance and keeps the stored notices", %{run: run} do
      captured =
        result(
          checked_zip_sha256: @digest,
          checked_export_profile: @flex_profile,
          validator_version: "8.0.1"
        )

      assert {:ok, completed} = Validations.mark_completed(run, captured)

      persisted = Repo.get!(ValidationRun, run.id)
      assert completed.checked_zip_sha256 == @digest
      assert persisted.checked_zip_sha256 == @digest
      assert persisted.checked_export_profile == @stored_flex_profile
      assert persisted.validator_version == "8.0.1"
      assert persisted.result_json == %{"notices" => notices()}
      assert persisted.completed_at
    end

    test "keeps nil provenance for a legacy result map without the new fields", %{run: run} do
      assert {:ok, completed} =
               Validations.mark_completed(run, %{
                 summary: %{errors: 0, warnings: 1, infos: 0},
                 notices: notices(),
                 duration_ms: 61_000
               })

      persisted = Repo.get!(ValidationRun, run.id)
      assert completed.checked_zip_sha256 == nil
      assert persisted.checked_zip_sha256 == nil
      assert persisted.checked_export_profile == nil
      assert persisted.validator_version == nil
      assert persisted.result_json == %{"notices" => notices()}
      assert persisted.warnings_count == 1
      assert persisted.duration_ms == 61_000
    end
  end

  describe "provenance changeset surface" do
    test "the public changeset ignores submitted provenance" do
      changeset =
        ValidationRun.changeset(%ValidationRun{}, %{
          run_type: "mobility_data",
          status: "started",
          started_at: ~U[2026-10-01 12:00:00.000000Z],
          checked_zip_sha256: @digest,
          checked_export_profile: @flex_profile,
          validator_version: "8.0.1"
        })

      assert changeset.valid?

      assert changeset.changes == %{
               run_type: "mobility_data",
               status: "started",
               started_at: ~U[2026-10-01 12:00:00.000000Z]
             }
    end

    test "the system changeset accepts a flex and an ordinary primary profile" do
      for export_profile <- [
            @flex_profile,
            profile(include_flex: false, artifact_kind: "primary"),
            profile(export_type: "pathways", include_flex: false, artifact_kind: "primary"),
            profile(
              export_type: "operations",
              include_flex: false,
              artifact_kind: "primary",
              estimate_method: "distance"
            )
          ] do
        changeset =
          ValidationRun.system_changeset(%ValidationRun{}, %{
            run_type: "mobility_data",
            status: "started",
            started_at: ~U[2026-10-01 12:00:00.000000Z],
            checked_zip_sha256: @digest,
            checked_export_profile: export_profile,
            validator_version: String.duplicate("8", 128)
          })

        assert changeset.valid?, "expected #{inspect(export_profile)} to be accepted"
      end
    end

    test "the system changeset accepts absent provenance" do
      changeset =
        ValidationRun.system_changeset(%ValidationRun{}, %{
          run_type: "mobility_data",
          status: "started",
          started_at: ~U[2026-10-01 12:00:00.000000Z]
        })

      assert changeset.valid?
    end

    test "rejects a digest that is not 64 lowercase hex characters" do
      for digest <- [
            String.duplicate("A", 64),
            String.duplicate("ab", 31) <> "abc",
            String.duplicate("ab", 33),
            String.duplicate("g", 64),
            " sha256-" <> String.duplicate("ab", 29)
          ] do
        changeset = provenance_changeset(checked_zip_sha256: digest)

        refute changeset.valid?, "expected #{inspect(digest)} to be rejected"
        assert {_message, _opts} = changeset.errors[:checked_zip_sha256]
      end
    end

    test "bounds the validator version to 128 UTF-8 bytes" do
      assert provenance_changeset(validator_version: String.duplicate("8", 128)).valid?
      assert provenance_changeset(validator_version: String.duplicate("é", 64)).valid?

      for version <- [
            String.duplicate("8", 129),
            String.duplicate("é", 65),
            String.duplicate("é", 64) <> "x"
          ] do
        changeset = provenance_changeset(validator_version: version)

        refute changeset.valid?, "expected #{byte_size(version)} bytes to be rejected"
        assert {_message, _opts} = changeset.errors[:validator_version]
      end
    end

    test "requires the exact export profile keys" do
      for export_profile <- [
            Map.delete(@flex_profile, :estimate_method),
            Map.put(@flex_profile, :revision_id, Ecto.UUID.generate()),
            Map.put(@flex_profile, "schema_version", 1)
          ] do
        changeset = provenance_changeset(checked_export_profile: export_profile)

        refute changeset.valid?, "expected #{inspect(export_profile)} to be rejected"

        assert {_message, _opts} = changeset.errors[:checked_export_profile]
      end
    end

    test "requires the exact export profile values" do
      for export_profile <- [
            profile(schema_version: 2),
            profile(export_type: "flex"),
            profile(export_type: "full_flex"),
            profile(include_flex: "true"),
            profile(include_flex: nil),
            profile(artifact_kind: "companion"),
            profile(estimate_method: "straight_line")
          ] do
        changeset = provenance_changeset(checked_export_profile: export_profile)

        refute changeset.valid?, "expected #{inspect(export_profile)} to be rejected"
        assert {_message, _opts} = changeset.errors[:checked_export_profile]
      end
    end

    test "rejects a profile that is not a map" do
      for export_profile <- ["full", ["full"], nil] do
        changeset = provenance_changeset(checked_export_profile: export_profile)

        refute changeset.valid?, "expected #{inspect(export_profile)} to be rejected"
      end
    end
  end

  defp provenance_changeset(overrides) do
    attrs =
      Map.merge(
        %{
          run_type: "mobility_data",
          status: "started",
          started_at: ~U[2026-10-01 12:00:00.000000Z]
        },
        Map.new(overrides)
      )

    ValidationRun.system_changeset(%ValidationRun{}, attrs)
  end
end

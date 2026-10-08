defmodule GtfsPlanner.Gtfs.ExportRunsFilesTest do
  @moduledoc """
  R3/R4: the file-listing and reference-match reads behind the export page's
  "existing files" answer. `list_files/3` lists every retained run of one
  version; `reference_match/3` classifies an `:operations_only` run's reference
  against the run a channel currently serves and the newest same-version file.
  """
  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportRuns
  alias GtfsPlanner.Repo

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @fingerprint_a String.duplicate("a", 64)
  @fingerprint_b String.duplicate("b", 64)

  describe "list_files/3" do
    test "lists newest first and pages a keyset tie without gaps" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)

      tie = DateTime.add(DateTime.utc_now(), -60, :second)
      older = DateTime.add(tie, -60, :second)

      first = insert_run!(organization, version, :full, :ready, tie, id: uuid(1))
      second = insert_run!(organization, version, :pathways, :ready, tie, id: uuid(2))
      third = insert_run!(organization, version, :operations, :ready, older, id: uuid(3))

      first_page = ExportRuns.list_files(organization.id, version.id, limit: 2)

      assert Enum.map(first_page, & &1.id) == [first.id, second.id]

      second_page =
        ExportRuns.list_files(organization.id, version.id,
          limit: 2,
          after: {second.inserted_at, second.id}
        )

      assert Enum.map(second_page, & &1.id) == [third.id]
    end

    test "excludes other versions, other organizations and runs outside the TTL" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      other_version = gtfs_version_fixture(organization.id)
      other_organization = organization_fixture()
      other_org_version = gtfs_version_fixture(other_organization.id)

      now = DateTime.utc_now()
      ttl = Application.fetch_env!(:gtfs_planner, :gtfs_task_artifacts_ttl_seconds)
      outside_ttl = DateTime.add(now, -(ttl + 60), :second)

      kept = insert_run!(organization, version, :full, :ready, now)
      _other_version_run = insert_run!(organization, other_version, :pathways, :ready, now)

      _other_org_run =
        insert_run!(other_organization, other_org_version, :operations, :ready, now)

      _expired_run = insert_run!(organization, version, :operations_only, :ready, outside_ttl)

      assert Enum.map(ExportRuns.list_files(organization.id, version.id), & &1.id) == [kept.id]
    end

    test "lists runs in every state" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      now = DateTime.utc_now()

      runs = [
        insert_run!(organization, version, :full, :pending, now),
        insert_run!(organization, version, :pathways, :building, now),
        insert_run!(organization, version, :operations, :ready, now),
        insert_run!(organization, version, :operations, :failed, now),
        insert_run!(organization, version, :operations, :interrupted, now),
        insert_run!(organization, version, :operations, :cancelled, now),
        insert_run!(organization, version, :operations, :expired, now)
      ]

      listed = ExportRuns.list_files(organization.id, version.id)

      assert MapSet.new(Enum.map(listed, & &1.id)) == MapSet.new(Enum.map(runs, & &1.id))
    end
  end

  describe "reference_match/3" do
    test "a served run in another version with an equal fingerprint is a published match" do
      organization = organization_fixture()
      version_a = gtfs_version_fixture(organization.id)
      version_b = gtfs_version_fixture(organization.id)
      now = DateTime.utc_now()

      served =
        insert_run!(organization, version_a, :full, :ready, now, fingerprint: @fingerprint_a)

      input =
        insert_run!(organization, version_b, :operations_only, :ready, now,
          fingerprint: @fingerprint_a
        )

      assert match?(
               {:published, %Run{id: id}} when id == served.id,
               ExportRuns.reference_match(organization.id, input, served.id)
             )
    end

    test "a same-version full file is the match when the served run differs" do
      organization = organization_fixture()
      version_a = gtfs_version_fixture(organization.id)
      version_b = gtfs_version_fixture(organization.id)
      now = DateTime.utc_now()

      input =
        insert_run!(organization, version_b, :operations_only, :ready, now,
          fingerprint: @fingerprint_a
        )

      newest =
        insert_run!(organization, version_b, :full, :ready, now, fingerprint: @fingerprint_a)

      _older =
        insert_run!(organization, version_b, :operations, :ready, DateTime.add(now, -60, :second),
          fingerprint: @fingerprint_a
        )

      differing =
        insert_run!(organization, version_a, :full, :ready, now, fingerprint: @fingerprint_b)

      nil_served = insert_run!(organization, version_a, :full, :ready, now)

      assert match?(
               {:file, %Run{id: id}} when id == newest.id,
               ExportRuns.reference_match(organization.id, input, differing.id)
             )

      assert match?(
               {:file, %Run{id: id}} when id == newest.id,
               ExportRuns.reference_match(organization.id, input, nil_served.id)
             )
    end

    test "a served run with a nil fingerprint answers published_unknown when no file matches" do
      organization = organization_fixture()
      version_a = gtfs_version_fixture(organization.id)
      version_b = gtfs_version_fixture(organization.id)
      now = DateTime.utc_now()

      served = insert_run!(organization, version_a, :full, :ready, now)

      input =
        insert_run!(organization, version_b, :operations_only, :ready, now,
          fingerprint: @fingerprint_a
        )

      assert ExportRuns.reference_match(organization.id, input, served.id) == :published_unknown
    end

    test "differing fingerprints with no served run answer none" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      now = DateTime.utc_now()

      input =
        insert_run!(organization, version, :operations_only, :ready, now,
          fingerprint: @fingerprint_a
        )

      _file =
        insert_run!(organization, version, :full, :ready, now, fingerprint: @fingerprint_b)

      assert ExportRuns.reference_match(organization.id, input, nil) == :none
    end

    test "nil fingerprints never match" do
      organization = organization_fixture()
      version_b = gtfs_version_fixture(organization.id)
      version_c = gtfs_version_fixture(organization.id)
      now = DateTime.utc_now()

      nil_input = insert_run!(organization, version_b, :operations_only, :ready, now)

      assert ExportRuns.reference_match(organization.id, nil_input, nil) == nil

      input =
        insert_run!(organization, version_c, :operations_only, :ready, now,
          fingerprint: @fingerprint_a
        )

      _nil_file = insert_run!(organization, version_c, :full, :ready, now)

      assert ExportRuns.reference_match(organization.id, input, nil) == :none
    end

    test "another organization's served run is ignored" do
      organization_a = organization_fixture()
      organization_b = organization_fixture()
      version_a = gtfs_version_fixture(organization_a.id)
      version_b = gtfs_version_fixture(organization_b.id)
      now = DateTime.utc_now()

      input =
        insert_run!(organization_a, version_a, :operations_only, :ready, now,
          fingerprint: @fingerprint_a
        )

      served_b =
        insert_run!(organization_b, version_b, :full, :ready, now, fingerprint: @fingerprint_a)

      assert ExportRuns.reference_match(organization_a.id, input, served_b.id) == :none
    end

    test "nil for a non-ready or non-operations-only run" do
      organization = organization_fixture()
      version = gtfs_version_fixture(organization.id)
      now = DateTime.utc_now()

      full_run = insert_run!(organization, version, :full, :ready, now)
      pending_run = insert_run!(organization, version, :operations_only, :pending, now)

      assert ExportRuns.reference_match(organization.id, full_run, nil) == nil
      assert ExportRuns.reference_match(organization.id, pending_run, nil) == nil
    end
  end

  defp uuid(suffix) do
    "00000000-0000-0000-0000-00000000000#{suffix}"
  end

  defp insert_run!(organization, version, export_type, state, inserted_at, opts \\ []) do
    now = DateTime.utc_now()

    attrs =
      %{
        organization_id: organization.id,
        gtfs_version_id: version.id,
        export_type: export_type,
        state: state,
        gtfs_reference_sha256: Keyword.get(opts, :fingerprint)
      }
      |> Map.merge(state_attrs(state, now))

    %Run{id: Keyword.get(opts, :id, Ecto.UUID.generate())}
    |> Run.system_changeset(attrs)
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Ecto.Changeset.put_change(:updated_at, inserted_at)
    |> Repo.insert!()
  end

  defp state_attrs(:pending, _now), do: %{}

  defp state_attrs(:building, now) do
    %{
      started_at: now,
      lease_token: Ecto.UUID.generate(),
      lease_expires_at: DateTime.add(now, 300, :second),
      phase: :preflight
    }
  end

  defp state_attrs(:ready, now) do
    %{
      started_at: now,
      finished_at: now,
      artifact_key: "export-runs/org/version/run/archive.zip",
      artifact_filename: "gtfs.zip",
      artifact_sha256: String.duplicate("c", 64),
      artifact_size_bytes: 0,
      artifact_expires_at: DateTime.add(now, 3600, :second)
    }
  end

  defp state_attrs(state, now) when state in [:failed, :interrupted, :cancelled, :expired] do
    %{started_at: now, finished_at: now, failure_code: to_string(state)}
  end
end

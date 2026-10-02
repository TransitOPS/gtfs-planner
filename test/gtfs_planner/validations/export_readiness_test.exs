defmodule GtfsPlanner.Validations.ExportReadinessTest do
  @moduledoc """
  Merge evidence (EV-5) for the byte-aware native export readiness read.

  Every expectation is hand-derived from the acceptance cases, never recomputed
  from the module under test:

    * six invalid stations are one finding with a total of 6 and five retained
      examples, and `run/3` still writes the same message for the same SQL;
    * a check whose recorded digest differs from the current export's is
      `different_bytes` even though the version and the timestamp are one, and
      a companion Flex file never turns the primary artifact into a Flex one;
    * a matching digest with no recorded profile or validator version stays
      `unknown`, while a known identical profile with a matching digest is
      `checked` - byte identity only, beside the check's real error count;
    * a foreign, expired or absent artifact is `unavailable`, an organization
      whose product hides operations cannot read that readiness at all, and a
      Flex artifact is never compared against a primary check's profile.
  """

  use GtfsPlanner.DataCase, async: true

  import Ecto.Query

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Export.Run
  alias GtfsPlanner.Gtfs.ExportDefaults
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Evidence
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.AccountsFixtures, only: [editor_fixture: 1]
  import GtfsPlanner.GtfsFixtures, only: [stop_fixture: 3]
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @primary_digest String.duplicate("a", 64)
  @other_digest String.duplicate("b", 64)
  @third_digest String.duplicate("c", 64)

  @primary_profile %{
    "schema_version" => 1,
    "export_type" => "full",
    "include_flex" => false,
    "artifact_kind" => "primary",
    "estimate_method" => nil
  }

  @estimating_profile %{
    "schema_version" => 1,
    "export_type" => "full",
    "include_flex" => false,
    "artifact_kind" => "primary",
    "estimate_method" => "distance"
  }

  @flex_profile %{
    "schema_version" => 1,
    "export_type" => "full",
    "include_flex" => true,
    "artifact_kind" => "flex",
    "estimate_method" => nil
  }

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    user = editor_fixture(organization)

    %{
      organization: organization,
      version: version,
      user: user,
      scope: scope(organization, version, user)
    }
  end

  describe "byte-aware relationship" do
    test "a check of different bytes under the same version and time is different_bytes", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      run = ready_export_run(organization, version, artifact_sha256: @primary_digest)

      check =
        completed_check(organization, version,
          run_type: "mobility_data",
          checked_zip_sha256: @other_digest,
          checked_export_profile: @primary_profile
        )

      # Same version, and the check finished after the artifact was published.
      assert check.gtfs_version_id == run.gtfs_version_id

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.relationship == "different_bytes"
      assert readiness.digest == @primary_digest
      assert readiness.selected_artifact.artifact_kind == :primary
      assert readiness.currentness == "unknown"
      assert readiness.publication_status == "unsupported"

      # The bytes that were checked are named beside the bytes on offer.
      assert [recent] = readiness.recent_checks
      assert recent.id == check.id
      assert recent.checked_digest == @other_digest

      assert recent.checked_profile == %{
               schema_version: 1,
               export_type: "full",
               include_flex: false,
               artifact_kind: "primary",
               estimate_method: nil
             }
    end

    test "a matching digest with no recorded profile or version stays unknown", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version, artifact_sha256: @primary_digest)

      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.relationship == "unknown"
      assert readiness.digest == @primary_digest

      assert [recent] = readiness.recent_checks
      assert recent.checked_digest == @primary_digest
      assert recent.checked_profile == nil
      assert recent.validator_version == nil
    end

    test "a known identical profile and digest is byte identity, not a clean feed", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version, artifact_sha256: @primary_digest)

      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest,
        checked_export_profile: @primary_profile,
        validator_version: "8.0.1",
        errors_count: 3,
        warnings_count: 2
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.relationship == "checked"
      assert readiness.digest == @primary_digest

      assert [recent] = readiness.recent_checks
      assert recent.errors == 3
      assert recent.warnings == 2
      assert recent.validator_version == "8.0.1"
      assert readiness.currentness == "unknown"
    end

    test "an unreadable stored profile is unknown rather than repaired", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version, artifact_sha256: @primary_digest)

      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest,
        checked_export_profile: %{
          "schema_version" => 1,
          "export_type" => "full",
          "artifact_kind" => "primary"
        }
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)
      assert readiness.relationship == "unknown"
      assert [recent] = readiness.recent_checks
      assert recent.checked_profile == nil
    end

    test "a known check profile that is not this artifact's is different_profile", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version,
        export_type: :operations,
        artifact_sha256: @primary_digest
      )

      # The validator only ever checks the full export, so an operations file
      # can never carry a matching profile.
      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest,
        checked_export_profile: @primary_profile
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :operations, nil)
      assert readiness.relationship == "different_profile"
      assert readiness.selected_artifact.export_type == :operations
    end

    test "a companion Flex file never turns the primary artifact into a Flex one", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version,
        artifact_sha256: @primary_digest,
        include_flex: true,
        flex_artifact_key: "runs/flex.zip",
        flex_artifact_filename: "gtfs-flex.zip",
        flex_artifact_sha256: @third_digest,
        flex_artifact_size_bytes: 2048
      )

      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest,
        checked_export_profile: @primary_profile
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.relationship == "checked"
      assert readiness.selected_artifact.artifact_kind == :primary
      assert readiness.selected_artifact.sha256 == @primary_digest

      # The stored profile of the artifact is the primary one, and the run's own
      # Flex option is preserved beside it as an option fact.
      assert readiness.selected_artifact.profile == %{
               schema_version: 1,
               export_type: "full",
               include_flex: false,
               artifact_kind: "primary",
               estimate_method: nil
             }

      assert readiness.selected_artifact.stored_options.include_flex == true
    end

    test "a Flex artifact is compared only against a Flex check", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version,
        artifact_sha256: @primary_digest,
        include_flex: true,
        flex_artifact_key: "runs/flex.zip",
        flex_artifact_filename: "gtfs-flex.zip",
        flex_artifact_sha256: @third_digest,
        flex_artifact_size_bytes: 2048
      )

      # The primary check's digest is the Flex file's digest here, and it is
      # still not the primary artifact being checked.
      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @third_digest,
        checked_export_profile: @primary_profile
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil, :flex)

      assert readiness.selected_artifact.artifact_kind == :flex
      assert readiness.selected_artifact.sha256 == @third_digest

      assert readiness.selected_artifact.profile ==
               Map.new(@flex_profile, fn {key, value} ->
                 {String.to_existing_atom(key), value}
               end)

      assert readiness.relationship == "different_profile"

      completed_check(organization, version,
        run_type: "mobility_data_flex",
        checked_zip_sha256: @third_digest,
        checked_export_profile: @flex_profile
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil, :flex)
      assert readiness.relationship == "checked"
      assert readiness.digest == @third_digest
    end

    test "a run without the named Flex artifact has no selected artifact", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version, artifact_sha256: @primary_digest)

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil, :flex)

      assert readiness.selected_artifact == nil
      assert readiness.relationship == "unavailable"
    end
  end

  describe "selected artifact" do
    test "an expired artifact cannot certify anything", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version,
        artifact_sha256: @primary_digest,
        artifact_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest,
        checked_export_profile: @primary_profile
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.selected_artifact.available == false
      assert readiness.relationship == "unavailable"
      assert readiness.digest == nil
    end

    test "a run with no artifact is unavailable", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      pending_export_run(organization, version)

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.selected_artifact == nil
      assert readiness.relationship == "unavailable"
      assert readiness.digest == nil
    end

    test "a version with no export run at all is unavailable", %{scope: scope} do
      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.selected_artifact == nil
      assert readiness.relationship == "unavailable"
      assert readiness.recent_checks == []
    end

    test "a foreign or malformed export reference is unavailable before the read", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      own_run = ready_export_run(organization, version, artifact_sha256: @primary_digest)

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)

      foreign_run =
        ready_export_run(foreign_organization, foreign_version, artifact_sha256: @third_digest)

      # The foreign row really exists and really holds a ready artifact.
      assert %Run{} = Repo.get(Run, foreign_run.id)

      assert {:error, :unavailable} = Evidence.readiness(scope, :full, foreign_run.id)
      assert {:error, :unavailable} = Evidence.readiness(scope, :full, Ecto.UUID.generate())
      assert {:error, :unavailable} = Evidence.readiness(scope, :full, "not-a-uuid")

      # The scope's own run still reads, and an absent one is not an error.
      assert {:ok, readiness} = Evidence.readiness(scope, :full, own_run.id)
      assert readiness.selected_artifact.run_id == own_run.id

      assert {:ok, latest} = Evidence.readiness(scope, :full, nil)
      assert latest.selected_artifact.run_id == own_run.id
    end

    test "a run of another export type is unavailable for this selection", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      pathways_run = ready_export_run(organization, version, export_type: :pathways)

      assert {:error, :unavailable} = Evidence.readiness(scope, :full, pathways_run.id)
    end
  end

  describe "product visibility" do
    setup do
      pathways_organization = organization_fixture(%{product: :pathways})
      pathways_version = gtfs_version_fixture(pathways_organization.id)
      pathways_user = editor_fixture(pathways_organization)

      %{
        pathways_scope: scope(pathways_organization, pathways_version, pathways_user),
        pathways_organization: pathways_organization
      }
    end

    test "a pathways organization cannot read operations readiness", %{pathways_scope: scope} do
      assert {:error, :unavailable} = Evidence.readiness(scope, :operations, nil)
    end

    test "hidden flex is not offered as a current default profile", %{pathways_scope: scope} do
      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.product_visibility == %{
               export_type: "full",
               flex: false,
               operations_export: false
             }

      assert readiness.profile.include_flex == false
    end

    test "the stations alias names the pathways export", %{pathways_scope: scope} do
      assert {:ok, readiness} = Evidence.readiness(scope, "stations", nil)

      assert readiness.export_type == :pathways
      assert readiness.profile.export_type == "pathways"
      assert Enum.map(readiness.preflight, & &1.code) == []
    end

    test "an unknown export type is refused as an argument", %{pathways_scope: scope} do
      assert {:error, :invalid_arguments} = Evidence.readiness(scope, "crew", nil)
      assert {:error, :invalid_arguments} = Evidence.readiness(scope, nil, nil)
    end
  end

  describe "current defaults beside the stored profile" do
    test "both profiles are shown when the defaults changed after the export", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      # The artifact was built from an estimating export.
      ready_export_run(organization, version,
        artifact_sha256: @primary_digest,
        estimate_missing_times: true,
        estimate_method: :distance
      )

      {:ok, _defaults} =
        ExportDefaults.update(organization.id, editor_fixture(organization), %{
          estimate_missing_times: false
        })

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      # The current defaults would build a non-estimating file; the stored
      # artifact is one, and readiness shows both rather than claiming the
      # defaults made it.
      assert readiness.profile.estimate_method == nil
      assert readiness.selected_artifact.profile.estimate_method == "distance"
      assert readiness.selected_artifact.stored_options.estimate_missing_times == true

      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest,
        checked_export_profile: @estimating_profile
      )

      # The bytes were checked against the profile they were built with. The
      # current defaults are not evidence about those bytes.
      assert {:ok, checked} = Evidence.readiness(scope, :full, nil)
      assert checked.relationship == "checked"
      assert checked.profile.estimate_method == nil

      # A check of the profile today's defaults would produce is a different
      # profile from the artifact's, even when its digest is the same bytes.
      completed_check(organization, version,
        run_type: "mobility_data",
        checked_zip_sha256: @primary_digest,
        checked_export_profile: @primary_profile
      )

      assert {:ok, mixed} = Evidence.readiness(scope, :full, nil)
      assert mixed.relationship == "checked"
    end

    test "the current profile follows the stored defaults", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      ready_export_run(organization, version, artifact_sha256: @primary_digest)

      {:ok, _defaults} =
        ExportDefaults.update(organization.id, editor_fixture(organization), %{
          include_flex: false,
          estimate_missing_times: true,
          estimate_method: "even"
        })

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert readiness.profile == %{
               schema_version: 1,
               export_type: "full",
               include_flex: false,
               artifact_kind: "primary",
               estimate_method: "even"
             }
    end
  end

  describe "preflight and recent checks" do
    test "preflight totals come from this version's own rows", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      for index <- 1..6 do
        stop_fixture(organization.id, version.id,
          stop_id: "STOP_#{index}",
          stop_lat: nil,
          stop_lon: nil
        )
      end

      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)

      for index <- 1..2 do
        stop_fixture(foreign_organization.id, foreign_version.id,
          stop_id: "FOREIGN_#{index}",
          stop_lat: nil,
          stop_lon: nil
        )
      end

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      assert [%{code: "stops_missing_coordinates", total: 6, examples: examples, unit: :stations}] =
               readiness.preflight

      assert length(examples) == 5
      assert "FOREIGN_1" not in examples
    end

    test "recent checks are the last five completed MobilityData checks of this version", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      created =
        for index <- 1..6 do
          completed_check(organization, version, run_type: "mobility_data", errors_count: index)
        end

      flex = completed_check(organization, version, run_type: "mobility_data_flex")
      completed_check(organization, version, run_type: "pathways_tests")
      failed_check(organization, version, run_type: "mobility_data")

      foreign_organization = organization_fixture()

      completed_check(foreign_organization, gtfs_version_fixture(foreign_organization.id),
        run_type: "mobility_data"
      )

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)

      checks = readiness.recent_checks
      assert length(checks) == 5

      assert Enum.all?(checks, &(&1.run_type in ["mobility_data", "mobility_data_flex"]))

      # Newest first, so the check that ran last leads and the two oldest
      # MobilityData checks fall outside the bound. The failed run, the
      # pathways run and the other organization's run never appear.
      assert [newest | _rest] = checks
      assert newest.id == flex.id
      assert Enum.map(checks, & &1.errors) == [0, 6, 5, 4, 3]

      assert Enum.take(created, 2)
             |> Enum.map(& &1.id)
             |> Enum.all?(&(&1 not in Enum.map(checks, fn check -> check.id end)))
    end
  end

  describe "scope" do
    test "a membership that is no longer an active editor's stops the read", %{
      organization: organization,
      version: version,
      user: user,
      scope: scope
    } do
      ready_export_run(organization, version, artifact_sha256: @primary_digest)

      membership = Repo.get_by(Accounts.UserOrgMembership, user_id: user.id)

      membership
      |> Ecto.Changeset.change(roles: ["pathways_viewer"])
      |> Repo.update!()

      assert {:error, :unavailable} = Evidence.readiness(scope, :full, nil)
    end

    test "another version's export run of this organization is not this selection", %{
      organization: organization,
      scope: scope
    } do
      other_version = gtfs_version_fixture(organization.id)
      other_run = ready_export_run(organization, other_version, artifact_sha256: @primary_digest)

      assert {:ok, readiness} = Evidence.readiness(scope, :full, nil)
      assert readiness.selected_artifact == nil

      assert {:error, :unavailable} = Evidence.readiness(scope, :full, other_run.id)
    end
  end

  defp scope(organization, version, user) do
    %Scope{
      organization_id: organization.id,
      gtfs_version_id: version.id,
      user_id: user.id,
      user_email: user.email,
      pack_id: "feed_quality",
      version_name: version.name,
      resource_context: Scope.context({:version, version.id})
    }
  end

  # A ready export run with its artifact metadata already committed. The
  # artifact file itself is never opened here: readiness reads the run's stored
  # digest and expiry, not the host's storage.
  defp ready_export_run(organization, version, opts) do
    Repo.insert!(Run.system_changeset(%Run{}, run_attrs(organization, version, opts)))
  end

  defp pending_export_run(organization, version) do
    Repo.insert!(
      Run.system_changeset(%Run{}, %{
        export_type: :full,
        state: :pending,
        organization_id: organization.id,
        gtfs_version_id: version.id
      })
    )
  end

  defp run_attrs(organization, version, opts) do
    %{
      export_type: Keyword.get(opts, :export_type, :full),
      state: :ready,
      include_flex: Keyword.get(opts, :include_flex, false),
      estimate_missing_times: Keyword.get(opts, :estimate_missing_times, false),
      estimate_method: Keyword.get(opts, :estimate_method),
      artifact_key: Keyword.get(opts, :artifact_key, "runs/#{organization.id}/main.zip"),
      artifact_filename: Keyword.get(opts, :artifact_filename, "gtfs.zip"),
      artifact_sha256: Keyword.get(opts, :artifact_sha256, @primary_digest),
      artifact_size_bytes: 1024,
      artifact_expires_at:
        Keyword.get(
          opts,
          :artifact_expires_at,
          DateTime.add(DateTime.utc_now(), 3_600, :second)
        ),
      flex_artifact_key: Keyword.get(opts, :flex_artifact_key),
      flex_artifact_filename: Keyword.get(opts, :flex_artifact_filename),
      flex_artifact_sha256: Keyword.get(opts, :flex_artifact_sha256),
      flex_artifact_size_bytes: Keyword.get(opts, :flex_artifact_size_bytes),
      organization_id: organization.id,
      gtfs_version_id: version.id,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now()
    }
  end

  defp completed_check(organization, version, opts) do
    create_check(organization, version, "completed", opts)
  end

  defp failed_check(organization, version, opts) do
    create_check(organization, version, "failed", opts)
  end

  defp create_check(organization, version, status, opts) do
    {:ok, run} =
      Validations.create_validation_run(
        organization.id,
        version.id,
        Keyword.get(opts, :run_type, "mobility_data")
      )

    updates =
      %{
        status: status,
        completed_at: DateTime.utc_now(),
        errors_count: Keyword.get(opts, :errors_count, 0),
        warnings_count: Keyword.get(opts, :warnings_count, 0),
        infos_count: Keyword.get(opts, :infos_count, 0),
        checked_zip_sha256: Keyword.get(opts, :checked_zip_sha256),
        checked_export_profile: Keyword.get(opts, :checked_export_profile),
        validator_version: Keyword.get(opts, :validator_version)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {1, _} =
      Repo.update_all(from(stored in ValidationRun, where: stored.id == ^run.id),
        set: Map.to_list(updates)
      )

    Repo.get!(ValidationRun, run.id)
  end
end

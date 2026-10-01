defmodule GtfsPlanner.Validations.EvidenceTest do
  @moduledoc """
  Merge evidence (EV-3) for the scoped, digest-bound findings read.

  Every expectation here is hand-derived from the acceptance cases and the
  pinned v8.0.1 report shape, never recomputed from the module under test:

    * the run is resolved inside the organization's *and* version's predicates
      before any report JSON is read, so a foreign run holding a sensitive
      `result_json` is the same `:unavailable` as an absent identifier, and a
      revoked membership stops the read before the query;
    * the historical wrapper's own length of 1 loses to the embedded upstream
      `totalNotices` of 170, so the group reports 170 total and 3 retained, and
      a wrapper whose embedded report carries no count leaves the total unknown
      instead of inferring it from its 3 samples;
    * groups are sorted by code and severity, a 51-group report pages 50 then
      1 under one digest, an instance offset of 100 keeps the same stable
      `digest/group/index` references, and a cursor issued for another filter is
      refused;
    * an unknown `ALARM` severity is counted exactly under its own key and an
      oversized allowed field is refused instead of silently truncated.
  """

  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Evidence
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

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

  describe "scoped resolution" do
    test "a foreign run with sensitive JSON is the same unavailable as an absent UUID", %{
      organization: organization,
      version: version,
      scope: scope
    } do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)
      foreign_run = completed_run(foreign_organization, foreign_version, canonical_notices())

      # The foreign row really does exist and really does hold the report, so
      # only the scoped predicate can be what hides it.
      assert %ValidationRun{} = Validations.get_validation_run(foreign_run.id)

      assert {:error, :unavailable} =
               Evidence.findings(scope, %{run_id: foreign_run.id})

      assert {:error, :unavailable} =
               Evidence.findings(scope, %{run_id: Ecto.UUID.generate()})

      assert {:error, :unavailable} =
               Evidence.findings(scope, %{run_id: "not-a-uuid"})

      # A run of this organization under a different version is foreign too.
      other_version = gtfs_version_fixture(organization.id)
      other_run = completed_run(organization, other_version, canonical_notices())

      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: other_run.id})

      # And the scoped run of this organization and version does read.
      own_run = completed_run(organization, version, canonical_notices())

      assert {:ok, report} = Evidence.findings(scope, %{run_id: own_run.id})
      assert is_binary(report.digest)
      assert byte_size(report.digest) == 64
      assert report.total_instances == 1
    end

    test "a run outside this organization is scoped by fetch_scoped_run/3", %{
      organization: organization
    } do
      other_organization = organization_fixture()
      run = completed_run(other_organization, gtfs_version_fixture(other_organization.id), [])

      assert {:error, :unavailable} =
               Validations.fetch_scoped_run(organization.id, run.gtfs_version_id, run.id)

      assert {:error, :unavailable} =
               Validations.fetch_scoped_run("nope", run.gtfs_version_id, run.id)
    end

    test "a membership that is no longer an active editor's stops the read before the query", %{
      organization: organization,
      version: version,
      user: user
    } do
      run = completed_run(organization, version, canonical_notices())
      membership = Repo.get_by(Accounts.UserOrgMembership, user_id: user.id)

      membership
      |> Ecto.Changeset.change(roles: ["pathways_viewer"], active: false)
      |> Repo.update!()

      foreign_scope = scope(organization, version, user)

      assert {:error, :unavailable} = Evidence.findings(foreign_scope, %{run_id: run.id})
    end
  end

  describe "stored shapes" do
    test "a canonical step 2 group keeps its stored total and retained count", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run =
        completed_run(organization, version, [
          %{
            "code" => "missing_required_field",
            "severity" => "ERROR",
            "total_notices" => 170,
            "notices" => [
              %{"filename" => "stops.txt", "csvRowNumber" => 3, "fieldName" => "stop_id"},
              %{"filename" => "stops.txt", "csvRowNumber" => 9, "fieldName" => "stop_name"},
              %{"filename" => "routes.txt", "csvRowNumber" => 4, "fieldName" => "route_id"}
            ],
            "retained_notices" => 3,
            "sample_completeness" => "sampled"
          }
        ])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})

      assert [group] = report.groups
      assert group.code == "missing_required_field"
      assert group.severity == "ERROR"
      assert group.total_instances == 170
      assert group.retained_instances == 3
      assert group.completeness == "sampled"
      assert length(group.instances) == 3
      assert report.total_instances == 170
      assert report.retained_instances == 3
      assert report.completeness == "incomplete"
      assert report.totals_by_severity == %{"ERROR" => 170}
      assert %{reason: "sampled_instance_groups", count: 1} in report.exclusions

      # The stored JSON is exactly as written: the read never rewrites a row.
      assert %ValidationRun{result_json: stored} = Repo.reload!(run)
      assert [%{"total_notices" => 170}] = stored["notices"]
    end

    test "the embedded upstream total outranks a buggy wrapper length, and a missing count stays unknown",
         %{
           scope: scope,
           organization: organization,
           version: version
         } do
      counted =
        completed_run(organization, version, [
          wrapper("duplicate_key", "ERROR", 1, 170, samples())
        ])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: counted.id})

      # The wrapper's own total of 1 is never used: 170 came from the embedded
      # upstream report, and only the 3 stored samples are retained.
      assert [group] = report.groups
      assert group.total_instances == 170
      assert group.retained_instances == 3
      assert group.completeness == "sampled"
      assert report.total_instances == 170
      assert report.totals_by_severity == %{"ERROR" => 170}

      countless =
        completed_run(organization, version, [
          wrapper("duplicate_key", "ERROR", 1, nil, samples())
        ])

      assert {:ok, unknown} = Evidence.findings(scope, %{run_id: countless.id})

      # The 3 retained samples are not the total: an embedded report without a
      # count leaves the total unknown and is disclosed, never inferred.
      assert [group] = unknown.groups
      assert group.total_instances == nil
      assert group.retained_instances == 3
      assert group.completeness == "unknown"
      assert unknown.total_instances == 0
      assert unknown.retained_instances == 3
      assert unknown.totals_by_severity == %{}
      assert %{reason: "groups_without_stored_total", count: 1} in unknown.exclusions
    end

    test "a flat notice list is one instance per stored entry", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run =
        completed_run(organization, version, [
          %{"code" => "unknown_column", "severity" => "INFO", "filename" => "stops.txt"},
          %{"code" => "unknown_column", "severity" => "INFO", "filename" => "routes.txt"}
        ])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})

      assert [group] = report.groups
      assert group.total_instances == 2
      assert group.retained_instances == 2
      assert group.completeness == "complete"
      assert report.completeness == "complete"
      assert report.total_instances == 2
    end

    test "an unreadable report and an unsupported run are unavailable, never clean zero", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      unreadable = completed_run(organization, version, [%{"severity" => "ERROR"}])
      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: unreadable.id})

      no_notices = completed_run(organization, version, [], result_json: %{"summary" => %{}})
      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: no_notices.id})

      {:ok, running} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Repo.update_all(
        from(run in ValidationRun, where: run.id == ^running.id),
        set: [status: "running", result_json: canonical_notices()]
      )

      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: running.id})

      {:ok, failed} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Repo.update_all(
        from(run in ValidationRun, where: run.id == ^failed.id),
        set: [status: "failed"]
      )

      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: failed.id})

      other_engine =
        completed_run(organization, version, canonical_notices(), engine: "some_other")

      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: other_engine.id})

      future_schema =
        completed_run(organization, version, canonical_notices(), result_schema_version: 2)

      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: future_schema.id})

      {:ok, pathways} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      Repo.update_all(
        from(run in ValidationRun, where: run.id == ^pathways.id),
        set: [status: "completed", result_json: canonical_notices()]
      )

      assert {:error, :unavailable} = Evidence.findings(scope, %{run_id: pathways.id})
    end

    test "an empty completed report is complete zero with no cursor", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run = completed_run(organization, version, [])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert report.groups == []
      assert report.total_instances == 0
      assert report.retained_instances == 0
      assert report.completeness == "complete"
      assert report.next_cursor == nil
      assert report.exclusions == []
    end
  end

  describe "pagination and cursors" do
    test "51 groups page 50 then 1 under one digest", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run = completed_run(organization, version, numbered_groups(51))

      assert {:ok, first} = Evidence.findings(scope, %{run_id: run.id, limit: 50})
      assert length(first.groups) == 50
      assert first.next_cursor

      assert {:ok, second} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 limit: 50,
                 digest: first.digest,
                 cursor: first.next_cursor
               })

      assert length(second.groups) == 1
      assert second.digest == first.digest
      assert second.next_cursor == nil

      # Groups are sorted by code, and the two pages do not overlap.
      assert first.groups == Enum.take(first.groups, 50)
      assert [%{code: "code_50"}] = second.groups
      assert Enum.map(first.groups, & &1.code) == Enum.map(0..49, &"code_#{&1}")
      assert first.total_instances == 51
    end

    test "an instance offset of 100 keeps stable refs and a filtered cursor mismatch is refused",
         %{
           scope: scope,
           organization: organization,
           version: version
         } do
      run =
        completed_run(organization, version, [
          %{
            "code" => "missing_required_field",
            "severity" => "ERROR",
            "total_notices" => 150,
            "notices" => Enum.map(1..150, &sample(&1)),
            "retained_notices" => 150,
            "sample_completeness" => "complete"
          }
        ])

      assert {:ok, first} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 limit: 50
               })

      assert [%{instances: instances}] = first.groups
      assert length(instances) == 50
      assert [%{ref: ref} | _rest] = instances
      assert ref == "#{first.digest}/missing_required_field|ERROR/0"

      assert {:ok, second} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 limit: 50,
                 digest: first.digest,
                 cursor: first.next_cursor
               })

      assert [%{group} | _rest] = second.groups
      assert group.instance_offset == 50
      assert group.total_instances == 150
      assert group.retained_instances == 150

      # The report totals are the whole report, not the page.
      assert second.total_instances == 150

      assert {:ok, third} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 limit: 50,
                 digest: first.digest,
                 cursor: second.next_cursor
               })

      assert [%{group} | _rest] = third.groups
      assert group.instance_offset == 100
      assert [%{ref: stable}] = group.instances
      assert stable == "#{first.digest}/missing_required_field|ERROR/100"

      # A cursor issued for one filter cannot be applied to another.
      assert {:error, :invalid_arguments} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 severity: "ERROR",
                 digest: first.digest,
                 cursor: first.next_cursor
               })

      # A continuation without the digest it was issued for is refused.
      assert {:error, :invalid_arguments} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 cursor: first.next_cursor
               })

      # A tampered or unknown cursor is refused, never guessed at.
      assert {:error, :invalid_arguments} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 digest: first.digest,
                 cursor: Base.url_encode64(~s({"v":1}))
               })

      assert {:error, :invalid_arguments} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 digest: first.digest,
                 cursor: String.duplicate("A", 1_025)
               })

      assert {:error, :invalid_arguments} =
               Evidence.findings(scope, %{
                 run_id: run.id,
                 code: "missing_required_field",
                 limit: 101,
                 digest: first.digest
               })

      assert {:error, :invalid_arguments} =
               Evidence.findings(scope, %{run_id: run.id, limit: 51})
    end

    test "a digest that no longer describes the stored report is stale", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run = completed_run(organization, version, numbered_groups(3))

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert report.next_cursor == nil

      assert {:error, :stale} =
               Evidence.findings(scope, %{run_id: run.id, digest: String.duplicate("0", 64)})
    end
  end

  describe "severity and bounds" do
    test "an unknown severity is counted exactly under its own key", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run =
        completed_run(organization, version, [
          %{
            "code" => "odd_notice",
            "severity" => "ALARM",
            "total_notices" => 7,
            "notices" => Enum.map(1..7, &sample(&1)),
            "retained_notices" => 7,
            "sample_completeness" => "complete"
          },
          %{
            "code" => "missing_required_field",
            "severity" => "error",
            "total_notices" => 4,
            "notices" => Enum.map(1..4, &sample(&1)),
            "retained_notices" => 4,
            "sample_completeness" => "complete"
          }
        ])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})

      # Lower-case `error` is the same severity as the validator's `ERROR`, but
      # the report keeps the severity each stored group actually carried.
      assert report.totals_by_severity == %{"ALARM" => 7, "error" => 4}
      assert report.total_instances == 11
      assert %{reason: "unknown_severity_groups", count: 1} in report.exclusions
      assert report.completeness == "complete"

      # ERROR/WARNING/INFO filter in either case; an unknown severity filters
      # exactly and is never remapped into one of them.
      assert {:ok, errors} = Evidence.findings(scope, %{run_id: run.id, severity: "ERROR"})
      assert [%{code: "missing_required_field"}] = errors.groups

      assert {:ok, alarm} = Evidence.findings(scope, %{run_id: run.id, severity: "alarm"})
      assert alarm.groups == []

      assert {:ok, exact} = Evidence.findings(scope, %{run_id: run.id, severity: "ALARM"})
      assert [%{code: "odd_notice"}] = exact.groups
    end

    test "retained context is sanitized, undisclosed keys are dropped and named", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run =
        completed_run(organization, version, [
          %{
            "code" => "missing_required_field",
            "severity" => "ERROR",
            "total_notices" => 1,
            "notices" => [
              %{
                "filename" => "/var/lib/gtfs/host/secret-path/stops.txt",
                "csvRowNumber" => 27,
                "fieldName" => "stop_name",
                "stopId" => "stop_1",
                "routeId" => "route_1",
                "message" => "Missing required field: internal host detail",
                "extraContext" => %{"path" => "/var/lib/gtfs"},
                "actorEmail" => "someone@example.com"
              }
            ],
            "retained_notices" => 1,
            "sample_completeness" => "complete"
          }
        ])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert [%{instances: [instance]}] = report.groups

      assert instance.context == %{
               "filename" => "stops.txt",
               "csvRowNumber" => 27,
               "fieldName" => "stop_name",
               "stopId" => "stop_1",
               "routeId" => "route_1"
             }

      assert instance.excluded_keys == ["actorEmail", "extraContext", "message"]

      refute Jason.encode!(report) =~ "secret-path"
      refute Jason.encode!(report) =~ "someone@example.com"
    end

    test "an oversized allowed field and an oversized page are refused", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      oversized =
        completed_run(organization, version, [
          %{
            "code" => "missing_required_field",
            "severity" => "ERROR",
            "total_notices" => 1,
            "notices" => [
              %{"filename" => "stops.txt", "stopId" => String.duplicate("s", 129)}
            ],
            "retained_notices" => 1,
            "sample_completeness" => "complete"
          }
        ])

      assert {:error, :too_large} = Evidence.findings(scope, %{run_id: oversized.id})

      # 100 instances of 128 bytes each cannot fit one 32 KiB result, so the
      # caller is asked to narrow rather than handed a silent truncation.
      wide =
        completed_run(organization, version, [
          %{
            "code" => "missing_required_field",
            "severity" => "ERROR",
            "total_notices" => 100,
            "notices" =>
              Enum.map(1..100, fn index ->
                %{
                  "filename" => "stops.txt",
                  "csvRowNumber" => index,
                  "stopId" => String.duplicate("s", 128)
                }
              end),
            "retained_notices" => 100,
            "sample_completeness" => "complete"
          }
        ])

      assert {:error, :too_large} =
               Evidence.findings(scope, %{run_id: wide.id, code: "missing_required_field"})

      # Narrowing the page is enough to read it.
      assert {:ok, report} =
               Evidence.findings(scope, %{
                 run_id: wide.id,
                 code: "missing_required_field",
                 limit: 10
               })

      assert report.total_instances == 100
      assert [%{instances: instances}] = report.groups
      assert length(instances) == 10
    end
  end

  # -- fixtures ---------------------------------------------------------------

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

  defp completed_run(organization, version, notices, opts \\ []) do
    {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

    run
    |> ValidationRun.system_changeset(%{
      status: "completed",
      completed_at: DateTime.utc_now(),
      result_json: Keyword.get(opts, :result_json, %{"notices" => notices})
    })
    |> Repo.update!()
    |> then(fn run ->
      if Keyword.get(opts, :engine) || Keyword.get(opts, :result_schema_version) do
        Repo.update_all(
          from(stored in ValidationRun, where: stored.id == ^run.id),
          set: [
            engine: Keyword.get(opts, :engine),
            result_schema_version: Keyword.get(opts, :result_schema_version)
          ]
        )

        Repo.reload!(run)
      else
        run
      end
    end)
  end

  # A historical wrapper group: its own total says 1 while the embedded upstream
  # report carries the true `totalNotices`.
  defp wrapper(code, severity, own_total, embedded_total, samples) do
    embedded =
      %{"sampleNotices" => samples}
      |> then(fn report ->
        if is_nil(embedded_total),
          do: report,
          else: Map.put(report, "totalNotices", embedded_total)
      end)

    %{
      "code" => code,
      "severity" => severity,
      "totalNotices" => own_total,
      "notices" => [embedded]
    }
  end

  defp samples do
    Enum.map(1..3, &sample/1)
  end

  defp sample(index) do
    %{"filename" => "stops.txt", "csvRowNumber" => index, "fieldName" => "stop_id"}
  end

  defp canonical_notices do
    [
      %{
        "code" => "missing_required_field",
        "severity" => "ERROR",
        "total_notices" => 1,
        "notices" => [sample(1)],
        "retained_notices" => 1,
        "sample_completeness" => "complete"
      }
    ]
  end

  defp numbered_groups(count) do
    Enum.map(0..(count - 1), fn index ->
      %{
        "code" => "code_#{index}",
        "severity" => "ERROR",
        "total_notices" => 1,
        "notices" => [sample(index)],
        "retained_notices" => 1,
        "sample_completeness" => "complete"
      }
    end)
  end
end

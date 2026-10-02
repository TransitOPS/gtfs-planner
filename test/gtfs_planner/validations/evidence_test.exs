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

  The notice explanation and inspection-target cases (EV-4) follow: the pinned
  v8.0.1 `missing_required_field` rule is the only documented one, another
  stored version and another code disclose unavailable documentation without
  losing the run's real findings, and the catalog's declared ERROR never
  overwrites a stored WARNING. A duplicated or missing stop id and a row-only
  instance resolve to nothing, an encoded stop id cannot escape the version's
  stops path, and an explicitly requested inspection navigates to an editor
  while every domain and audit row stays unchanged.
  """

  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Agents.Packs.FeedQuality.Remedies
  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs.Calendar
  alias GtfsPlanner.Gtfs.ChangeLog
  alias GtfsPlanner.Gtfs.Route
  alias GtfsPlanner.Gtfs.Stop
  alias GtfsPlanner.Gtfs.Trip
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.Evidence
  alias GtfsPlanner.Validations.ValidationRun

  import GtfsPlanner.GtfsFixtures
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
      |> Ecto.Changeset.change(roles: ["pathways_viewer"])
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

  describe "notice explanations" do
    test "the pinned v8.0.1 rule carries its meaning and its pinned source", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      run =
        completed_run(organization, version, [missing_field_group("ERROR", 170)],
          validator_version: "8.0.1"
        )

      assert {:ok, explanation} = Evidence.explain(scope, run.id, "missing_required_field")

      assert explanation.code == "missing_required_field"
      assert explanation.validator_version == "8.0.1"

      documentation = explanation.documentation
      assert documentation.status == "available"
      assert documentation.reason == nil
      assert documentation.evidence_fields == ["filename", "csvRowNumber", "fieldName"]
      assert documentation.declared_severity == "ERROR"

      # The explanation is our own paraphrase, bounded and specific: it says what
      # the rule means and where the notice points, without quoting or fetching
      # the upstream source at runtime.
      assert byte_size(documentation.summary) < 1_024
      assert documentation.summary =~ "empty"
      assert documentation.summary =~ "file"
      assert documentation.summary =~ "row"
      assert documentation.summary =~ "field"

      assert documentation.source_url =~
               "MobilityData/gtfs-validator/blob/v8.0.1/core/src/main/java/org/mobilitydata/gtfsvalidator/notice/MissingRequiredFieldNotice.java"

      # The run's own evidence stands beside the documentation: 170 total, 3
      # retained, exactly as the report stored them.
      assert explanation.findings.severities == %{"ERROR" => 170}
      assert explanation.findings.total_instances == 170
      assert explanation.findings.retained_instances == 3
      assert explanation.findings.completeness == "incomplete"
    end

    test "an uncaptured version or another code discloses unavailable documentation and keeps the findings",
         %{scope: scope, organization: organization, version: version} do
      # The same code, but a run whose validator version this repository never
      # verified a source for: the pinned rule is not borrowed across versions.
      other_version =
        completed_run(organization, version, [missing_field_group("ERROR", 170)],
          validator_version: "8.0.2"
        )

      assert {:ok, unverified} =
               Evidence.explain(scope, other_version.id, "missing_required_field")

      assert unverified.documentation.status == "unavailable"
      assert unverified.documentation.reason == "not_in_catalog_for_this_version"
      assert unverified.documentation.summary == nil
      assert unverified.documentation.source_url == nil
      assert unverified.documentation.declared_severity == nil

      # The real findings are untouched by the missing documentation.
      assert unverified.findings.severities == %{"ERROR" => 170}
      assert unverified.findings.total_instances == 170

      # A legacy row that recorded no version at all is unavailable too, and
      # says why, rather than inheriting the only pinned rule.
      legacy = completed_run(organization, version, [missing_field_group("ERROR", 170)])

      assert {:ok, unknown} = Evidence.explain(scope, legacy.id, "missing_required_field")
      assert unknown.validator_version == nil
      assert unknown.documentation.status == "unavailable"
      assert unknown.documentation.reason == "validator_version_not_recorded"

      # Another code of the same verified version is also uncatalogued.
      run =
        completed_run(organization, version, [missing_field_group("ERROR", 4)],
          validator_version: "8.0.1"
        )

      assert {:ok, other_code} = Evidence.explain(scope, run.id, "unknown_column")
      assert other_code.documentation.status == "unavailable"
      assert other_code.documentation.reason == "not_in_catalog_for_this_version"
      assert other_code.findings.severities == %{}
      assert other_code.findings.total_instances == 0
    end

    test "a stored WARNING stays WARNING where the catalog declares ERROR", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      # The upstream rule is an ERROR, but this run stored the code as a WARNING
      # for its own reason; the catalog describes the rule and never restates the
      # report's severity.
      run =
        completed_run(organization, version, [missing_field_group("WARNING", 3)],
          validator_version: "8.0.1"
        )

      assert {:ok, explanation} = Evidence.explain(scope, run.id, "missing_required_field")

      assert explanation.documentation.status == "available"
      assert explanation.documentation.declared_severity == "ERROR"
      assert explanation.findings.severities == %{"WARNING" => 3}
      refute explanation.findings.severities == %{"ERROR" => 3}
    end

    test "a foreign, absent or unsupported run explains nothing", %{
      scope: scope,
      organization: organization,
      version: version
    } do
      foreign_organization = organization_fixture()
      foreign_version = gtfs_version_fixture(foreign_organization.id)

      foreign =
        completed_run(foreign_organization, foreign_version, [missing_field_group("ERROR", 5)],
          validator_version: "8.0.1"
        )

      assert {:error, :unavailable} =
               Evidence.explain(scope, foreign.id, "missing_required_field")

      assert {:error, :unavailable} =
               Evidence.explain(scope, Ecto.UUID.generate(), "missing_required_field")

      assert {:error, :invalid_arguments} = Evidence.explain(scope, "", "missing_required_field")

      assert {:error, :invalid_arguments} = Evidence.explain(scope, version.id, "")
    end
  end

  describe "inspection targets" do
    setup %{organization: organization, version: version} do
      stop = stop_fixture(organization.id, version.id, %{stop_id: "STOP_1", stop_name: "Main St"})
      route = route_fixture(organization.id, version.id, %{route_id: "R1", route_short_name: "1"})
      trip = trip_fixture(organization.id, version.id, route.id, %{trip_id: "T1"})
      calendar = calendar_fixture(organization.id, version.id, %{service_id: "WK"})

      %{stop: stop, route: route, trip: trip, calendar: calendar}
    end

    test "unique natural keys resolve to typed current targets", context do
      %{scope: scope, organization: organization, version: version, route: route} = context

      run =
        completed_run(organization, version, [
          group_with([%{"stopId" => "STOP_1", "routeId" => "R1", "serviceId" => "WK"}])
        ])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert [%{instances: [instance]}] = report.groups
      assert {:ok, location} = Evidence.locate(scope, run.id, instance.ref)

      assert location.context == %{
               "filename" => "stops.txt",
               "csvRowNumber" => 3,
               "stopId" => "STOP_1",
               "routeId" => "R1",
               "serviceId" => "WK"
             }

      assert Enum.map(location.targets, & &1.kind) == ["stop", "route", "calendar"]
      assert Enum.map(location.targets, & &1.id) == ["STOP_1", "R1", "WK"]
      assert Enum.map(location.targets, & &1.label) == ["Main St", "1", nil]
      assert location.unresolved == []
      assert location.ref == instance.ref
      assert location.digest == report.digest
    end

    test "a trip resolves to its own current route, not to the trip", context do
      %{scope: scope, organization: organization, version: version, route: route} = context

      run = completed_run(organization, version, [group_with([%{"tripId" => "T1"}])])
      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert [%{instances: [instance]}] = report.groups

      assert {:ok, location} = Evidence.locate(scope, run.id, instance.ref)
      assert [%{kind: "route", id: "R1"}] = location.targets
      assert location.unresolved == []

      # A trip whose route is not a current record of this version resolves to
      # nothing and says so; it never falls back to some other route.
      orphan =
        trip_fixture(organization.id, version.id, Ecto.UUID.generate(), %{trip_id: "T_ORPHAN"})

      assert %Trip{route_id: route_id} = orphan
      assert route_id == Ecto.UUID.generate()

      orphan_run = completed_run(organization, version, [group_with([%{"tripId" => "T_ORPHAN"}])])

      assert {:ok, orphan_report} = Evidence.findings(scope, %{run_id: orphan_run.id})
      assert [%{instances: [orphan_instance]}] = orphan_report.groups

      assert {:ok, orphan_location} = Evidence.locate(scope, orphan_run.id, orphan_instance.ref)
      assert orphan_location.targets == []

      assert orphan_location.unresolved == [
               %{reason: "trip_route_not_current", field: "tripId", value: "T_ORPHAN"}
             ]
    end

    test "a missing or foreign stop id resolves to nothing and states the reason", context do
      %{scope: scope, organization: organization, version: version} = context

      missing = completed_run(organization, version, [group_with([%{"stopId" => "STOP_NONE"}])])
      assert {:ok, report} = Evidence.findings(scope, %{run_id: missing.id})
      assert [%{instances: [instance]}] = report.groups

      assert {:ok, location} = Evidence.locate(scope, missing.id, instance.ref)
      assert location.targets == []

      assert location.unresolved == [
               %{reason: "no_current_record", field: "stopId", value: "STOP_NONE"}
             ]

      # The same stop id in another version is not a current record of this one.
      other_version = gtfs_version_fixture(organization.id)
      stop_fixture(organization.id, other_version.id, %{stop_id: "STOP_ELSEWHERE"})

      elsewhere =
        completed_run(organization, version, [group_with([%{"stopId" => "STOP_ELSEWHERE"}])])

      assert {:ok, elsewhere_report} = Evidence.findings(scope, %{run_id: elsewhere.id})
      assert [%{instances: [elsewhere_instance]}] = elsewhere_report.groups

      assert {:ok, elsewhere_location} =
               Evidence.locate(scope, elsewhere.id, elsewhere_instance.ref)

      assert elsewhere_location.targets == []

      assert elsewhere_location.unresolved == [
               %{reason: "no_current_record", field: "stopId", value: "STOP_ELSEWHERE"}
             ]
    end

    test "a row number alone and an unmapped pathway id stay evidence", context do
      %{scope: scope, organization: organization, version: version} = context

      run =
        completed_run(organization, version, [
          group_with([
            %{"filename" => "stops.txt", "csvRowNumber" => 27},
            %{"pathwayId" => "P1", "csvRowNumber" => 31}
          ])
        ])

      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert [%{instances: [row_only, pathway]}] = report.groups

      assert {:ok, row_location} = Evidence.locate(scope, run.id, row_only.ref)
      assert row_location.targets == []

      assert row_location.unresolved == [
               %{reason: "row_number_is_not_a_record", field: nil, value: nil}
             ]

      assert row_location.context == %{"filename" => "stops.txt", "csvRowNumber" => 27}

      assert {:ok, pathway_location} = Evidence.locate(scope, run.id, pathway.ref)
      assert pathway_location.targets == []

      assert pathway_location.unresolved == [
               %{reason: "no_typed_destination_for_pathway", field: "pathwayId", value: "P1"}
             ]
    end

    test "a reference from another report, an unknown group and a bad ref are refused", context do
      %{scope: scope, organization: organization, version: version} = context

      first = completed_run(organization, version, [group_with([%{"stopId" => "STOP_1"}])])
      second = completed_run(organization, version, [group_with([%{"stopId" => "STOP_1"}])])

      assert {:ok, first_report} = Evidence.findings(scope, %{run_id: first.id})
      assert {:ok, second_report} = Evidence.findings(scope, %{run_id: second.id})
      assert [%{instances: [instance]}] = first_report.groups

      # The two runs have different provenance, so their digests differ and a
      # reference is only ever resolved inside the report that issued it.
      refute first_report.digest == second_report.digest

      assert {:error, :stale} = Evidence.locate(scope, first.id, instance.ref)
      assert {:error, :invalid_arguments} = Evidence.locate(scope, first.id, "not-a-reference")
      assert {:error, :invalid_arguments} = Evidence.locate(scope, first.id, instance.ref <> "/9")

      # An index past the group's retained samples is refused rather than read
      # from another group's position.
      assert {:error, :invalid_arguments} =
               Evidence.locate(
                 scope,
                 first.id,
                 "#{first_report.digest}/missing_required_field|ERROR/7"
               )

      assert {:error, :invalid_arguments} =
               Evidence.locate(
                 scope,
                 first.id,
                 "#{first_report.digest}/missing_required_field|ERROR/x"
               )

      assert {:error, :invalid_arguments} =
               Evidence.locate(scope, first.id, "#{first_report.digest}/no_such_code|ERROR/0")

      assert {:error, :unavailable} = Evidence.locate(scope, Ecto.UUID.generate(), instance.ref)
    end
  end

  describe "remedies are navigation only" do
    test "the correction list is empty and navigation is what is offered", context do
      assert %{corrections: [], navigation: true} = Remedies.list()
    end

    test "an explicitly requested inspection navigates and changes nothing", context do
      %{scope: scope, organization: organization, version: version, stop: stop} = context

      run = completed_run(organization, version, [group_with([%{"stopId" => stop.stop_id}])])
      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert [%{instances: [instance]}] = report.groups

      before = counts(organization.id, version.id)

      assert {:ok, navigation} = Remedies.prepare(scope, run.id, instance.ref, true)

      assert navigation.navigable
      assert [%{kind: "stop", id: "STOP_1", label: "Main St"}] = navigation.targets
      assert navigation.unresolved == []

      # A correction request never edits: the records, the run and the audit
      # trail are byte-for-byte what they were before the request.
      assert counts(organization.id, version.id) == before
      assert Repo.reload!(run).result_json == run.result_json
      assert Repo.reload!(stop).stop_name == "Main St"
    end

    test "an unrequested inspection hands back nothing", context do
      %{scope: scope, organization: organization, version: version, stop: stop} = context

      run = completed_run(organization, version, [group_with([%{"stopId" => stop.stop_id}])])
      assert {:ok, report} = Evidence.findings(scope, %{run_id: run.id})
      assert [%{instances: [instance]}] = report.groups

      # The helper's own interest is not a request: nothing is prepared.
      assert {:error, :not_requested} = Remedies.prepare(scope, run.id, instance.ref, false)
      assert {:error, :invalid_arguments} = Remedies.prepare(scope, run.id, instance.ref, nil)

      # An instance that names no current record is an explicit unavailable, not
      # a guess and not a correction.
      unresolved_run =
        completed_run(organization, version, [group_with([%{"stopId" => "STOP_NONE"}])])

      assert {:ok, unresolved_report} = Evidence.findings(scope, %{run_id: unresolved_run.id})
      assert [%{instances: [unresolved_instance]}] = unresolved_report.groups

      assert {:ok, navigation} =
               Remedies.inspect(scope, unresolved_run.id, unresolved_instance.ref)

      refute navigation.navigable
      assert navigation.targets == []

      assert navigation.unresolved == [
               %{reason: "no_current_record", field: "stopId", value: "STOP_NONE"}
             ]

      # Only typed current records leave this module; the stored sample context
      # stays where it was read.
      refute Map.has_key?(navigation, :context)
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
      system_updates =
        [
          engine: Keyword.get(opts, :engine),
          result_schema_version: Keyword.get(opts, :result_schema_version),
          validator_version: Keyword.get(opts, :validator_version)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      if system_updates == %{} do
        run
      else
        Repo.update_all(
          from(stored in ValidationRun, where: stored.id == ^run.id),
          set: system_updates
        )

        Repo.reload!(run)
      end
    end)
  end

  # The pinned rule's own group: a canonical step 2 group of that code, stored
  # under whichever severity the run actually recorded.
  defp missing_field_group(severity, total) do
    %{
      "code" => "missing_required_field",
      "severity" => severity,
      "total_notices" => total,
      "notices" => samples(),
      "retained_notices" => 3,
      "sample_completeness" => "sampled"
    }
  end

  # A complete group whose samples carry exactly the given context, so the
  # reference under test sits at a known index of its own group.
  defp group_with(contexts) do
    %{
      "code" => "missing_required_field",
      "severity" => "ERROR",
      "total_notices" => length(contexts),
      "notices" => Enum.map(contexts, &Map.put_new(&1, "filename", "stops.txt")),
      "retained_notices" => length(contexts),
      "sample_completeness" => "complete"
    }
  end

  # The observable count of everything a correction request must not change.
  defp counts(organization_id, version_id) do
    %{
      stops:
        Repo.aggregate(
          from(s in Stop,
            where: s.organization_id == ^organization_id and s.gtfs_version_id == ^version_id
          ),
          :count
        ),
      routes:
        Repo.aggregate(
          from(r in Route,
            where: r.organization_id == ^organization_id and r.gtfs_version_id == ^version_id
          ),
          :count
        ),
      trips:
        Repo.aggregate(
          from(t in Trip,
            where: t.organization_id == ^organization_id and t.gtfs_version_id == ^version_id
          ),
          :count
        ),
      calendars:
        Repo.aggregate(
          from(c in Calendar,
            where: c.organization_id == ^organization_id and c.gtfs_version_id == ^version_id
          ),
          :count
        ),
      runs:
        Repo.aggregate(
          from(v in ValidationRun,
            where: v.organization_id == ^organization_id and v.gtfs_version_id == ^version_id
          ),
          :count
        ),
      change_logs:
        Repo.aggregate(from(c in ChangeLog, where: c.organization_id == ^organization_id), :count)
    }
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

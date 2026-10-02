defmodule GtfsPlanner.Gtfs.StationAssistantImportsTest do
  @moduledoc """
  EV-3: reading one computed native import run as one station sees it, without
  changing anything.

  The membership matrix is hand-enumerated: every decision in the persisted run
  names the rows it depends on, so the expected attribution and the exact
  excluded counts are written here rather than inferred from the diff. The last
  case runs the default native compute - `ChangeWorker` over staged artifacts
  and `ChangeReview` over the uploaded files - so the same scoped diff is read
  over decisions this module never authored.
  """

  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Agents.Scope
  alias GtfsPlanner.Gtfs
  alias GtfsPlanner.Gtfs.Import.ChangeArtifactStorage
  alias GtfsPlanner.Gtfs.Import.ChangeDecision
  alias GtfsPlanner.Gtfs.Import.ChangeDecisionSerializer
  alias GtfsPlanner.Gtfs.Import.ChangeRun
  alias GtfsPlanner.Gtfs.Import.ChangeRuns
  alias GtfsPlanner.Gtfs.Import.ChangeWorker
  alias GtfsPlanner.Gtfs.StationAssistant
  alias GtfsPlanner.Repo

  setup do
    organization = organization_fixture()
    editor = user_fixture()

    membership =
      GtfsPlanner.AccountsFixtures.organization_membership_fixture(editor, organization)

    version = gtfs_version_fixture(organization.id)

    level = level_fixture(organization.id, version.id, %{level_id: "L1", level_index: 0.0})
    shared_level = level_fixture(organization.id, version.id, %{level_id: "L2", level_index: 1.0})

    station = station_stop(organization.id, version.id, "STATION_A", "L1")
    entrance = child_stop(organization.id, version.id, station, "ENT_A", "L1", "Entrance A")
    platform = child_stop(organization.id, version.id, station, "PLAT_A", "L1", "Platform A")

    other_platform =
      child_stop(organization.id, version.id, station, "PLAT_A2", "L2", "Platform A2")

    other_station = station_stop(organization.id, version.id, "STATION_B", "L2")

    other_entrance =
      child_stop(organization.id, version.id, other_station, "ENT_B", "L2", "Entrance B")

    other_platform_b =
      child_stop(organization.id, version.id, other_station, "PLAT_B", "L2", "Platform B")

    pathway =
      pathway_fixture(organization.id, version.id, entrance.stop_id, platform.stop_id, %{
        pathway_id: "PW_A",
        pathway_mode: 1,
        min_width: Decimal.new("1.00")
      })

    %{
      organization: organization,
      editor: editor,
      membership: membership,
      version: version,
      level: level,
      shared_level: shared_level,
      station: station,
      entrance: entrance,
      platform: platform,
      other_platform: other_platform,
      other_station: other_station,
      other_entrance: other_entrance,
      other_platform_b: other_platform_b,
      pathway: pathway
    }
  end

  describe "station-scoped membership" do
    test "a version-wide run discloses exact counts and no foreign values", ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))

      assert {:ok, result, evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      assert result["run_id"] == run.id
      assert result["state"] == "review"
      assert result["serializer_version"] == 1

      assert result["counts"] == %{
               "version_total" => 9,
               "station_total" => 4,
               "excluded_total" => 5,
               "existing_approved" => 1,
               "version_approved" => 1,
               "returned_decisions" => 4,
               "offset" => 0
             }

      assert Enum.map(result["decisions"], & &1["decision_id"]) == [
               "level:L1",
               "pathway:PW_A",
               "stop:NEW_A",
               "stop:PLAT_A"
             ]

      assert result["completeness"] == "complete"
      assert result["next_offset"] == nil

      assert result["excluded"] == %{
               "none" => 4,
               "shared_or_unknown_level" => 1,
               "unresolvable_or_other_endpoint" => 3,
               "unresolvable_or_other_stop" => 1
             }

      assert evidence.kind == "station_import_diff"
      assert evidence.total == 4
      assert evidence.total_label == "decisions attributable to this station"
      assert evidence.completeness == :complete
      assert evidence.digest == result["import_digest"]

      assert evidence.resources == [
               %{kind: "station_import_run", id: run.id},
               %{kind: "station", id: "STATION_A", label: "STATION_A"}
             ]

      # Nothing about the other station, the shared level, the cross-station or
      # unknown pathways reaches this answer.
      encoded = Jason.encode!(result)

      for foreign <- [
            "PLAT_B",
            "ENT_B",
            "STATION_B",
            "L2",
            "PW_CROSS",
            "PW_MISSING",
            "GHOST_STOP"
          ] do
        refute encoded =~ foreign, "#{foreign} must not be projected"
      end
    end

    test "the projected rows carry the native decision shape and no free text", ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))

      assert {:ok, result, _evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      platform_row = Enum.find(result["decisions"], &(&1["decision_id"] == "stop:PLAT_A"))

      assert platform_row["entity_type"] == "stop"
      assert platform_row["action"] == "modify"
      assert platform_row["status"] == "approved"
      assert platform_row["natural_key"] == "PLAT_A"
      assert platform_row["current_values"] == %{"stop_name" => "Platform A"}
      assert platform_row["uploaded_values"] == %{"stop_name" => "Platform Renamed"}

      assert platform_row["changed_fields"] == [
               %{"field" => "stop_name", "before" => "Platform A", "after" => "Platform Renamed"}
             ]

      assert platform_row["dependency_keys"] == []
      assert platform_row["user_edited"] == false
      assert platform_row["fingerprint_state"] == "match"
      assert platform_row["live_fingerprint"] == platform_row["current_fingerprint"]

      added = Enum.find(result["decisions"], &(&1["decision_id"] == "stop:NEW_A"))

      # An added row has no current record, so there is nothing to fingerprint.
      assert added["action"] == "add"
      assert added["current_values"] == %{}
      assert added["fingerprint_state"] == "unrecorded"
      assert added["uploaded_values"]["parent_station"] == "STATION_A"

      assert Enum.all?(
               result["decisions"],
               &(is_nil(&1["apply_failure_code"]) or is_binary(&1["apply_failure_code"]))
             )
    end

    test "a later edit to a decided record reads as drift, not as a rewrite", ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))

      assert {:ok, result, _evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      before_digest = result["import_digest"]

      {:ok, _platform} =
        ctx.platform
        |> Ecto.Changeset.change(%{stop_name: "Platform A edited natively"})
        |> Repo.update()

      assert {:ok, result, _evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      platform_row = Enum.find(result["decisions"], &(&1["decision_id"] == "stop:PLAT_A"))

      assert platform_row["fingerprint_state"] == "drifted"
      assert platform_row["current_fingerprint"] == stop_fingerprint(ctx)
      assert platform_row["current_values"] == %{"stop_name" => "Platform A"}
      # The digest binds the live fingerprint, so a native edit made after the
      # read makes a captured selection stale.
      assert result["import_digest"] != before_digest

      assert Repo.get!(ChangeRun, run.id).state == :review
    end
  end

  describe "the import digest" do
    test "a status, value or source-file edit changes it; reviewed evidence does not", ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))
      scope = run_scope(ctx, ctx.station, run)

      assert {:ok, first, _evidence} = StationAssistant.import_review(scope, %{})
      base_files = first["source_files"]

      assert base_files["files"] == [
               %{"name" => "stops.txt", "size" => 12, "sha256" => String.duplicate("a", 64)},
               %{"name" => "pathways.txt", "size" => 20, "sha256" => String.duplicate("b", 64)}
             ]

      # A status edit is a different run state.
      approve(ctx, run, "pathway:PW_A")

      assert {:ok, approved, _evidence} = StationAssistant.import_review(scope, %{})
      assert approved["import_digest"] != first["import_digest"]
      assert approved["counts"]["existing_approved"] == 2

      # So is a change to a decision's values.
      change_uploaded_value(run, "pathway:PW_A", "min_width", "1.07")

      assert {:ok, edited, _evidence} = StationAssistant.import_review(scope, %{})
      assert edited["import_digest"] != approved["import_digest"]

      # So is a changed base source file.
      refiled_run =
        put_source_manifest(run, %{
          "files" => [
            %{"name" => "stops.txt", "size" => 12, "sha256" => String.duplicate("c", 64)},
            %{"name" => "pathways.txt", "size" => 20, "sha256" => String.duplicate("b", 64)}
          ],
          "total_bytes" => 32
        })

      assert {:ok, refiled, _evidence} = StationAssistant.import_review(scope, %{})
      assert refiled["import_digest"] != edited["import_digest"]
      assert refiled["source_files"] != edited["source_files"]

      reviewed = %{
        "version" => 1,
        "entries" => [
          %{"decision_id" => "pathway:PW_A", "decision_digest" => String.duplicate("d", 64)}
        ]
      }

      put_source_manifest(run, refiled_run.source_manifest, reviewed)

      # Appending reviewed evidence changes no decision and no base source file,
      # so it must not invalidate the confirmation that appended it.
      assert {:ok, with_evidence, _evidence} = StationAssistant.import_review(scope, %{})
      assert with_evidence["import_digest"] == refiled["import_digest"]
      assert with_evidence["source_files"] == refiled["source_files"]

      refute Jason.encode!(with_evidence) =~ "reviewed_evidence"
      refute Jason.encode!(with_evidence) =~ String.duplicate("d", 64)
    end

    test "the projected source files never carry the stored storage key", ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))

      put_source_manifest(run, %{
        files: [
          %{
            name: "stops.txt",
            key: "change-runs/#{ctx.organization.id}/secret-source",
            size: 12,
            sha256: String.duplicate("a", 64),
            content_type: "text/csv"
          }
        ],
        total_bytes: 12
      })

      assert {:ok, result, _evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      assert result["source_files"]["files"] == [
               %{"name" => "stops.txt", "size" => 12, "sha256" => String.duplicate("a", 64)}
             ]

      refute Jason.encode!(result) =~ "change-runs/"
      refute Jason.encode!(result) =~ "secret-source"
    end
  end

  describe "scoping" do
    test "a foreign organization, version, station or run refuses before any disclosure", ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))

      foreign_organization = organization_fixture()

      GtfsPlanner.AccountsFixtures.organization_membership_fixture(
        ctx.editor,
        foreign_organization
      )

      foreign_version = gtfs_version_fixture(foreign_organization.id)

      foreign_station =
        station_stop(foreign_organization.id, foreign_version.id, "STATION_F", "L1")

      other_version = gtfs_version_fixture(ctx.organization.id)

      # A station this organization and version do not hold is one unavailable
      # refusal, the same one the recorded-result read returns.
      for {organization, version, station} <- [
            {foreign_organization, foreign_version, ctx.station},
            {ctx.organization, other_version, ctx.station},
            {ctx.organization, ctx.version, foreign_station}
          ] do
        assert {:error, :unavailable} =
                 StationAssistant.import_review(
                   run_scope(ctx, station, run, organization: organization, version: version),
                   %{}
                 )
      end

      # Another station of the same organization and version is not a foreign
      # resource: it is authorized, and the projection finds none of this
      # station's decisions for it.
      assert {:ok, other_answer, _evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.other_station, run), %{})

      assert Enum.map(other_answer["decisions"], & &1["decision_id"]) == ["stop:PLAT_B"]
      refute Jason.encode!(other_answer) =~ "PLAT_A"

      # Another version's run, however real, is not this scope's computed review.
      other_run = persisted_run_for(ctx, other_version)

      assert {:error, :no_computed_review} =
               StationAssistant.import_review(
                 run_scope(ctx, ctx.station, run, run_id: Ecto.UUID.generate()),
                 %{}
               )

      assert {:error, :unavailable} =
               StationAssistant.import_review(
                 run_scope(ctx, ctx.station, run, run_id: "not-a-uuid"),
                 %{}
               )

      # Another version's real, computed run is still not this scope's review.
      assert {:error, :no_computed_review} =
               StationAssistant.import_review(
                 run_scope(ctx, ctx.station, other_run),
                 %{}
               )
    end

    test "a run without a computed review reads as no computed review", ctx do
      {:ok, run} =
        ChangeRuns.create_pending_compute(ctx.organization.id, ctx.version.id, actor(ctx), [])

      assert run.state == :pending_compute

      assert {:error, :no_computed_review} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      assert {:ok, _computing, _generation, _token} =
               ChangeRuns.claim(ctx.organization.id, run.id, :compute)

      assert {:error, :no_computed_review} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})
    end

    test "another source kind, a missing run id, a revoked membership and a bad page refuse",
         ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))

      {:ok, context} =
        Scope.context({:version, ctx.version.id})
        |> Scope.with_source_snapshot(%{
          kind: "station_results",
          payload: %{
            "station_id" => ctx.station.id,
            "station_stop_id" => "STATION_A",
            "run_id" => run.id
          }
        })

      assert {:error, :unavailable} =
               StationAssistant.import_review(%{scope_base(ctx) | resource_context: context}, %{})

      assert {:error, :no_selected_run} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run, run_id: nil), %{})

      assert {:error, :invalid_selection} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{offset: -1})

      assert {:error, :invalid_selection} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{offset: "0"})

      deactivate_membership_fixture(ctx.membership)

      assert {:error, :forbidden} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})
    end

    test "reading the run changes nothing", ctx do
      run = persisted_run(ctx, hand_enumerated_review(ctx))
      scope = run_scope(ctx, ctx.station, run)

      before_run = Repo.get!(ChangeRun, run.id)

      before_decisions =
        ChangeRuns.list_decisions(ctx.organization.id, run.id)
        |> Enum.map(&{&1.decision_id, &1.status, &1.uploaded_values, &1.current_fingerprint})

      before_stops =
        Repo.all(from(s in GtfsPlanner.Gtfs.Stop, select: {s.stop_id, s.stop_name, s.updated_at}))
        |> Enum.sort()

      assert {:ok, _result, _evidence} = StationAssistant.import_review(scope, %{})
      assert {:ok, _result, _evidence} = StationAssistant.import_review(scope, %{offset: 0})

      after_run = Repo.get!(ChangeRun, run.id)

      assert after_run.state == before_run.state
      assert after_run.source_manifest == before_run.source_manifest
      assert after_run.summary == before_run.summary

      after_decisions =
        ChangeRuns.list_decisions(ctx.organization.id, run.id)
        |> Enum.map(&{&1.decision_id, &1.status, &1.uploaded_values, &1.current_fingerprint})

      assert after_decisions == before_decisions

      assert Repo.all(
               from(s in GtfsPlanner.Gtfs.Stop, select: {s.stop_id, s.stop_name, s.updated_at})
             )
             |> Enum.sort() == before_stops
    end
  end

  describe "bounds" do
    test "101 station decisions page inside the bound and reach every row", ctx do
      stops =
        for index <- 1..101 do
          child_stop(
            ctx.organization.id,
            ctx.version.id,
            ctx.station,
            "BULK_#{index}",
            "L1",
            "Bulk #{index}"
          )
        end

      run = native_compute_run(ctx, bulk_overrides(stops))
      scope = run_scope(ctx, ctx.station, run)

      assert {:ok, first, first_evidence} = StationAssistant.import_review(scope, %{})

      assert first["counts"]["station_total"] == 101
      assert first["counts"]["excluded_total"] == 0
      assert first["counts"]["returned_decisions"] <= 100
      assert Jason.encode!(%{result: first, evidence: first_evidence}) |> byte_size() <= 32 * 1024

      # Paging from the reported offset reaches every station decision exactly
      # once, whatever the size bound shortened a page to.
      seen =
        Enum.map(first["decisions"], & &1["decision_id"]) ++
          page_all(scope, first["next_offset"], [])

      assert Enum.uniq(seen) |> length() == 101
      assert seen |> length() == 101

      if first["next_offset"] do
        assert first["completeness"] == "incomplete"
        assert first_evidence.completeness == :incomplete
      end
    end

    test "an oversized answer is narrowed rather than truncated silently", ctx do
      long = String.duplicate("x", 4_000)

      stops =
        for index <- 1..20 do
          child_stop(
            ctx.organization.id,
            ctx.version.id,
            ctx.station,
            "WIDE_#{index}",
            "L1",
            "Wide #{index}",
            desc: long
          )
        end

      run = native_compute_run(ctx, bulk_overrides(stops))

      assert {:ok, result, evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      assert result["counts"]["station_total"] == 20
      assert result["counts"]["returned_decisions"] < 20
      assert result["completeness"] == "incomplete"
      assert result["narrowing"] =~ "narrower page"
      assert evidence.completeness == :incomplete
      assert evidence.completeness_reason =~ "narrower page"
      assert Jason.encode!(%{result: result, evidence: evidence}) |> byte_size() <= 32 * 1024
    end
  end

  describe "the default native compute" do
    test "ChangeReview and ChangeWorker decisions project the same scoped diff", ctx do
      overrides = %{
        stops: %{"PLAT_A" => "Platform A native", "PLAT_B" => "Platform B native"},
        pathways: %{"PW_A" => "1.05", "PW_CROSS" => "1.20"},
        levels: %{"L1" => "Ground renamed", "L2" => "Shared renamed"}
      }

      run = native_compute_run(ctx, overrides)

      run = Repo.reload!(run)
      assert run.state == :review

      decisions = ChangeRuns.list_decisions(ctx.organization.id, run.id)

      # The run is genuinely version-wide: it holds another station's rows, a
      # cross-station pathway and a shared level.
      assert Enum.any?(decisions, &(&1.natural_key == "PLAT_B"))
      assert Enum.any?(decisions, &(&1.natural_key == "PW_CROSS"))
      assert Enum.any?(decisions, &(&1.natural_key == "L2"))

      assert {:ok, result, evidence} =
               StationAssistant.import_review(run_scope(ctx, ctx.station, run), %{})

      counts = result["counts"]

      assert counts["version_total"] == length(decisions)
      assert counts["station_total"] == counts["version_total"] - counts["excluded_total"]

      projected = Enum.map(result["decisions"], & &1["decision_id"])

      assert "stop:PLAT_A" in projected
      assert "pathway:PW_A" in projected
      assert "level:L1" in projected

      refute "stop:PLAT_B" in projected
      refute "pathway:PW_CROSS" in projected
      refute "level:L2" in projected

      # The projection is computed, not transcribed: it agrees with the persisted
      # status, values and fingerprint of the decision it read.
      platform =
        Enum.find(decisions, &(&1.decision_id == "stop:PLAT_A")) |> Repo.reload()

      platform_row = Enum.find(result["decisions"], &(&1["decision_id"] == "stop:PLAT_A"))

      assert platform_row["status"] == to_string(platform.status)
      assert platform_row["uploaded_values"] == platform.uploaded_values
      assert platform_row["current_fingerprint"] == platform.current_fingerprint
      assert platform_row["fingerprint_state"] == "match"

      refute Jason.encode!(result) =~ "PLAT_B"
      assert is_binary(evidence.digest)
      assert evidence.digest == result["import_digest"]
    end
  end

  ## Fixtures

  defp actor(ctx), do: %{id: ctx.editor.id, email: ctx.editor.email}

  defp station_stop(organization_id, version_id, stop_id, level_id) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: stop_id,
      location_type: 1,
      level_id: level_id,
      stop_lat: Decimal.new("39.9526"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp child_stop(organization_id, version_id, station, stop_id, level_id, name, opts \\ []) do
    stop_fixture(organization_id, version_id, %{
      stop_id: stop_id,
      stop_name: name,
      stop_desc: Keyword.get(opts, :desc),
      location_type: if(stop_id =~ ~r/^ENT_/, do: 2, else: 0),
      parent_station: station.stop_id,
      level_id: level_id,
      stop_lat: Decimal.new("39.9527"),
      stop_lon: Decimal.new("-75.1653")
    })
  end

  defp scope_base(ctx) do
    %Scope{
      organization_id: ctx.organization.id,
      gtfs_version_id: ctx.version.id,
      user_id: ctx.editor.id,
      user_email: ctx.editor.email,
      pack_id: "station_imports",
      version_name: ctx.version.name,
      resource_context: Scope.context({:version, ctx.version.id})
    }
  end

  # The host builds the snapshot from the station and run it resolved; the
  # projection only ever reads it back.
  defp run_scope(ctx, station, run, opts \\ []) do
    organization = Keyword.get(opts, :organization, ctx.organization)
    version = Keyword.get(opts, :version, ctx.version)
    run_id = Keyword.get(opts, :run_id, run.id)

    {:ok, resource_context} =
      Scope.context({:version, version.id})
      |> Scope.with_source_snapshot(%{
        kind: "station_imports",
        payload: %{
          "station_id" => station.id,
          "station_stop_id" => station.stop_id,
          "change_run_id" => run_id
        }
      })

    %{
      scope_base(ctx)
      | organization_id: organization.id,
        gtfs_version_id: version.id,
        resource_context: resource_context
    }
  end

  defp staged_files(name, size, digit \\ "a") do
    [%{name: name, size: size, sha256: String.duplicate(digit, 64)}]
  end

  defp stop_fingerprint(ctx) do
    {:ok, fingerprint} =
      ChangeDecisionSerializer.record_fingerprint(:stop, ctx.platform, ["stop_name"])

    fingerprint
  end

  # One version-wide run whose decisions are written out here, so the expected
  # attribution does not depend on the diff engine's own choices.
  defp hand_enumerated_review(ctx) do
    fingerprint = stop_fingerprint(ctx)

    %{
      decisions: [
        decision("stop:PLAT_A", :stop, :modify, "PLAT_A",
          current: %{"stop_name" => "Platform A"},
          uploaded: %{"stop_name" => "Platform Renamed"},
          status: :approved,
          fingerprint: fingerprint
        ),
        decision("pathway:PW_A", :pathway, :modify, "PW_A",
          current: %{
            "from_stop_id" => "ENT_A",
            "to_stop_id" => "PLAT_A",
            "min_width" => "1.00"
          },
          uploaded: %{
            "from_stop_id" => "ENT_A",
            "to_stop_id" => "PLAT_A",
            "min_width" => "1.05"
          },
          dependencies: ["stop:ENT_A", "stop:PLAT_A"]
        ),
        decision("level:L1", :level, :modify, "L1",
          current: %{"level_name" => "Ground"},
          uploaded: %{"level_name" => "Ground floor"}
        ),
        decision("stop:NEW_A", :stop, :add, "NEW_A",
          uploaded: %{
            "stop_name" => "New entrance",
            "parent_station" => "STATION_A",
            "level_id" => "L1"
          },
          dependencies: ["level:L1", "stop:STATION_A"]
        ),
        # Another station's stop.
        decision("stop:PLAT_B", :stop, :modify, "PLAT_B",
          current: %{"stop_name" => "Platform B"},
          uploaded: %{"stop_name" => "Platform B renamed"}
        ),
        # A pathway with one endpoint on the other station.
        decision("pathway:PW_CROSS", :pathway, :modify, "PW_CROSS",
          current: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_B"},
          uploaded: %{"from_stop_id" => "ENT_A", "to_stop_id" => "PLAT_B", "min_width" => "1.20"},
          dependencies: ["stop:ENT_A", "stop:PLAT_B"]
        ),
        # A pathway naming a stop this organization and version do not hold.
        decision("pathway:PW_MISSING", :pathway, :modify, "PW_MISSING",
          current: %{"from_stop_id" => "ENT_A", "to_stop_id" => "GHOST_STOP"},
          uploaded: %{
            "from_stop_id" => "ENT_A",
            "to_stop_id" => "GHOST_STOP",
            "min_width" => "1.10"
          },
          dependencies: ["stop:ENT_A", "stop:GHOST_STOP"]
        ),
        # A level shared with the other station.
        decision("level:L2", :level, :modify, "L2",
          current: %{"level_name" => "Shared"},
          uploaded: %{"level_name" => "Shared renamed"}
        ),
        # An addition whose endpoint resolves to nothing.
        decision("pathway:PW_ORPHAN", :pathway, :add, "PW_ORPHAN",
          uploaded: %{"from_stop_id" => "PLAT_A", "to_stop_id" => "GHOST_STOP"},
          dependencies: ["stop:PLAT_A", "stop:GHOST_STOP"]
        )
      ],
      summary: %{applicable: 9, modify: 7, add: 2},
      diagnostics: [
        %{
          "code" => "duplicate_entity_file",
          "detail" => "a free-text detail that must not be projected",
          "entity_type" => "stops",
          "natural_key" => nil
        }
      ]
    }
  end

  defp decision(id, entity_type, action, natural_key, opts) do
    %{
      serializer_version: 1,
      decision_id: id,
      entity_type: entity_type,
      action: action,
      status: Keyword.get(opts, :status, :pending),
      natural_key: natural_key,
      current_values: Keyword.get(opts, :current, %{}),
      uploaded_values: Keyword.get(opts, :uploaded, %{}),
      changed_fields:
        changed_fields(Keyword.get(opts, :current, %{}), Keyword.get(opts, :uploaded, %{})),
      dependency_keys: Keyword.get(opts, :dependencies, []),
      current_fingerprint: Keyword.get(opts, :fingerprint),
      user_edited: false
    }
  end

  defp changed_fields(current, uploaded) do
    for {field, before} <- current,
        Map.has_key?(uploaded, field),
        Map.get(uploaded, field) != before do
      %{"field" => field, "before" => before, "after" => Map.get(uploaded, field)}
    end
  end

  defp persisted_run(ctx, review) do
    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               ctx.organization.id,
               ctx.version.id,
               actor(ctx),
               staged_files("stops.txt", 12, "a") ++ staged_files("pathways.txt", 20, "b")
             )

    assert {:ok, claimed, generation, token} =
             ChangeRuns.claim(ctx.organization.id, run.id, :compute)

    assert {:ok, _review} =
             ChangeRuns.persist_review(ctx.organization.id, run.id, generation, token, review)

    claimed
  end

  # A run in another version of the same organization, read through this
  # station's scope.
  defp persisted_run_for(ctx, version) do
    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               version.organization_id,
               version.id,
               actor(ctx),
               []
             )

    assert {:ok, claimed, generation, token} =
             ChangeRuns.claim(version.organization_id, run.id, :compute)

    assert {:ok, _review} =
             ChangeRuns.persist_review(version.organization_id, run.id, generation, token, %{
               decisions: [],
               summary: %{},
               diagnostics: []
             })

    claimed
  end

  defp approve(ctx, run, decision_id) do
    assert {:ok, decision} =
             ChangeRuns.set_decision_status(ctx.organization.id, run.id, decision_id, :approved)

    decision
  end

  defp change_uploaded_value(run, decision_id, field, value) do
    decision =
      Repo.one!(
        from(d in ChangeDecision,
          where: d.change_run_id == ^run.id and d.decision_id == ^decision_id
        )
      )

    uploaded = Map.put(decision.uploaded_values, field, value)

    decision
    |> ChangeDecision.system_changeset(%{uploaded_values: uploaded})
    |> Repo.update!()
  end

  defp put_source_manifest(run, manifest) do
    run |> Ecto.Changeset.change(%{source_manifest: manifest}) |> Repo.update!()
  end

  defp put_source_manifest(run, manifest, reviewed_evidence) do
    manifest = Map.new(manifest, fn {key, value} -> {to_string(key), value} end)
    manifest = Map.put(manifest, "reviewed_evidence", reviewed_evidence)

    run |> Ecto.Changeset.change(%{source_manifest: manifest}) |> Repo.update!()
  end

  # The default production compute: staged artifacts, the real worker and the
  # real review over uploaded files. Nothing about the answer is assigned here.
  defp native_compute_run(ctx, overrides) do
    root = Path.join(System.tmp_dir!(), "ai07-imports-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:gtfs_planner, :gtfs_task_artifacts_path)
    Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, root)
    run_id = Ecto.UUID.generate()

    files = [
      %{filename: "levels.txt", content: levels_csv(ctx, overrides)},
      %{filename: "stops.txt", content: stops_csv(ctx, overrides)},
      %{filename: "pathways.txt", content: pathways_csv(ctx, overrides)}
    ]

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: Application.put_env(:gtfs_planner, :gtfs_task_artifacts_path, previous),
        else: Application.delete_env(:gtfs_planner, :gtfs_task_artifacts_path)
    end)

    assert {:ok, manifest} =
             ChangeArtifactStorage.stage(
               ctx.organization.id,
               ctx.version.id,
               run_id,
               files,
               root: root
             )

    assert {:ok, run} =
             ChangeRuns.create_pending_compute(
               ctx.organization.id,
               ctx.version.id,
               actor(ctx),
               manifest,
               run_id
             )

    assert {:ok, claimed, generation, token} =
             ChangeRuns.claim(ctx.organization.id, run.id, :compute)

    assert :ok = ChangeWorker.compute(claimed, generation, token, ChangeRuns.topic(run.id))

    Repo.reload!(run)
  end

  defp page_all(_scope, nil, acc), do: Enum.reverse(acc)

  defp page_all(scope, offset, acc) do
    assert {:ok, page, evidence} = StationAssistant.import_review(scope, %{offset: offset})
    assert Jason.encode!(%{result: page, evidence: evidence}) |> byte_size() <= 32 * 1024

    acc =
      Enum.reduce(page["decisions"], acc, fn row, acc -> [row["decision_id"] | acc] end)

    page_all(scope, page["next_offset"], acc)
  end

  defp bulk_overrides(stops) do
    %{
      stops: Map.new(stops, fn stop -> {stop.stop_id, "Renamed #{stop.stop_id}"} end),
      pathways: %{},
      levels: %{}
    }
  end

  defp stops_csv(ctx, overrides) do
    rows =
      Gtfs.list_stops(ctx.organization.id, ctx.version.id)
      |> Enum.map(fn stop ->
        [
          stop.stop_id,
          Map.get(overrides.stops, stop.stop_id, stop.stop_name),
          stop.stop_desc || "",
          to_string(stop.stop_lat),
          to_string(stop.stop_lon),
          to_string(stop.location_type || 0),
          to_string(stop.wheelchair_boarding || 0),
          stop.platform_code || "",
          stop.level_id || "",
          stop.parent_station || ""
        ]
      end)

    csv(
      [
        "stop_id",
        "stop_name",
        "stop_desc",
        "stop_lat",
        "stop_lon",
        "location_type",
        "wheelchair_boarding",
        "platform_code",
        "level_id",
        "parent_station"
      ],
      rows
    )
  end

  defp pathways_csv(ctx, overrides) do
    rows =
      Gtfs.list_pathways(ctx.organization.id, ctx.version.id)
      |> Enum.map(fn pathway ->
        [
          pathway.pathway_id,
          to_string(pathway.pathway_mode),
          "1",
          to_string(pathway.traversal_time || ""),
          pathway.from_stop_id,
          pathway.to_stop_id,
          Map.get(overrides.pathways, pathway.pathway_id) || to_string(pathway.min_width)
        ]
      end)
      |> add_pathway_rows(overrides)

    csv(
      [
        "pathway_id",
        "pathway_mode",
        "is_bidirectional",
        "traversal_time",
        "from_stop_id",
        "to_stop_id",
        "min_width"
      ],
      rows
    )
  end

  # The cross-station pathway is uploaded as a new row, exactly as staff would
  # write it, so the native compute is what excludes it.
  defp add_pathway_rows(rows, overrides) do
    case Map.get(overrides.pathways, "PW_CROSS") do
      nil ->
        rows

      _min_width ->
        rows ++ [["PW_CROSS", "1", "1", "30", "ENT_A", "PLAT_B", "1.20"]]
    end
  end

  defp levels_csv(ctx, overrides) do
    rows =
      Gtfs.list_levels(ctx.organization.id, ctx.version.id)
      |> Enum.map(fn level ->
        [
          level.level_id,
          to_string(level.level_index),
          Map.get(overrides.levels, level.level_id, level.level_name) || ""
        ]
      end)

    csv(["level_id", "level_index", "level_name"], rows)
  end

  defp csv(header, rows) do
    Enum.join([Enum.join(header, ",") | Enum.map(rows, &Enum.join(&1, ","))], "\n") <> "\n"
  end
end

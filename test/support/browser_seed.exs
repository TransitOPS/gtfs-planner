# Creates deterministic browser-test users for Playwright E2E tests.
# `bin/test-browser` runs this script against a new throwaway database that is
# already created and migrated, so the database is empty and idempotency is
# unneeded.
#
# User 1 (admin): browser-test@gtfs-planner.test — used by overlays.spec.js
# User 2 (editor): diagram-test@gtfs-planner.test — used by diagram_keyboard.spec.js
# User 3 (org admin): admin-contracts@gtfs-planner.test — used by
#   admin_design_contracts.spec.js, together with its own "Admin Contracts Org"
#   and its deterministic active/deactivated/pending/multi-role/long-email members.
# User 4 (Pathways editor): pathways-editor@gtfs-planner.test — used by
#   product_branding.spec.js, in "Browser Pathways Org" (product: :pathways).
# User 5 (homepage, planner): home-planner@gtfs-planner.test and
#   home-planner-member@gtfs-planner.test — used by home.spec.js, in
#   "Home Planner Org" (calendars ending ten days after the seed date, a
#   stopped import, the administrator's recent destinations, a check with
#   warnings and an expired export).
# User 6 (homepage, pathways): home-pathways@gtfs-planner.test — used by
#   home.spec.js, in "Home Pathways Org" (product: :pathways) with a 14-station
#   board covering every stage and reachability outcome.
# User 7 (homepage, access states): account-admin@gtfs-planner.test — the
#   active organization administrator for "Account No Version Org" and
#   "Account No Task Org", so those states draw the contact card home.spec.js
#   and the references expect.
# User 8 (stops map): stops-map@gtfs-planner.test — used by
#   stops_map.spec.js, in "Stops Map Org" (product: :planner) with "Browser
#   Stops Map Version": 17 stops on real downtown Newport, Oregon coordinates,
#   two routes with three patterns on saved lines, a possible-duplicate pair 1.5 m
#   apart, a relief point, a transfer to a transit-centre bay, a station with a
#   level, an unserved stop with a translation, and garage "1533".
# User 9 (TODS generator): tods-generator@gtfs-planner.test — used by
#   tods_generator.spec.js, in "Browser TODS Org" (product: :planner) with
#   "Browser TODS Version", one calendar and garage "TODS_DEPOT"; and
#   tods-generator-empty@gtfs-planner.test in "Browser TODS Empty Org", whose
#   "Browser TODS No Garage Version" has a calendar and no garage, so the
#   generator's missing-prerequisite state is a real page.
#
# Both users belong to the same org. The editor user can access GTFS routes
# because it has the pathways_studio_editor role and a session-scoped
# organization (non-admin bypasses the admin org-skip in AssignOrganization).
#
# Also creates a seeded station with a level, floorplan, and positioned
# child stops so the diagram route renders a keyboard-accessible canvas.
#
# Credentials are test-only and must not appear in application config.

alias GtfsPlanner.Accounts
alias GtfsPlanner.Accounts.User
alias GtfsPlanner.Accounts.UserToken
alias GtfsPlanner.AdvancedBlockingFixtures
alias GtfsPlanner.Agents.BrowserFeedQuality
alias GtfsPlanner.Agents.BrowserServiceAnswers
alias GtfsPlanner.FaresFixtures
alias GtfsPlanner.Gtfs
alias GtfsPlanner.Gtfs.Agency
alias GtfsPlanner.Gtfs.AlignmentSegment
alias GtfsPlanner.Gtfs.AuditContext
alias GtfsPlanner.Gtfs.Calendar
alias GtfsPlanner.Gtfs.CalendarAttribute
alias GtfsPlanner.Gtfs.ChangeLog
alias GtfsPlanner.Gtfs.DiagramStorage
alias GtfsPlanner.Gtfs.Export.ArtifactStorage
alias GtfsPlanner.Gtfs.Export.Run, as: ExportRun
alias GtfsPlanner.Gtfs.ExportRuns
alias GtfsPlanner.Gtfs.FareAttribute
alias GtfsPlanner.Gtfs.FareProductDetail
alias GtfsPlanner.Gtfs.FareRule
alias GtfsPlanner.Gtfs.Fares
alias GtfsPlanner.Gtfs.Fares.Conversion
alias GtfsPlanner.Gtfs.Fares.Transfers
alias GtfsPlanner.Gtfs.FareSavedJourney
alias GtfsPlanner.Gtfs.FareZones
alias GtfsPlanner.Gtfs.FeedInfo
alias GtfsPlanner.Gtfs.Flex
alias GtfsPlanner.Gtfs.FloorplanTransform
alias GtfsPlanner.Gtfs.Import.ChangeRuns
alias GtfsPlanner.Gtfs.Import.Run, as: ImportRun
alias GtfsPlanner.Gtfs.PathwayEvolution
alias GtfsPlanner.Gtfs.ReliefPoint
alias GtfsPlanner.Gtfs.Route
alias GtfsPlanner.Gtfs.RouteNetwork
alias GtfsPlanner.Gtfs.RoutePattern
alias GtfsPlanner.Gtfs.RoutePatterns.Derivation
alias GtfsPlanner.Gtfs.RoutePatternStop
alias GtfsPlanner.Gtfs.Shape
alias GtfsPlanner.Gtfs.Stop
alias GtfsPlanner.Gtfs.StopTime
alias GtfsPlanner.Gtfs.Transfer
alias GtfsPlanner.Gtfs.Translation
alias GtfsPlanner.Gtfs.Trip
alias GtfsPlanner.GtfsFixtures
alias GtfsPlanner.Organizations
alias GtfsPlanner.Reachability.Runner
alias GtfsPlanner.Repo
alias GtfsPlanner.Validations.{ValidationRun, WalkabilityTest, WalkabilityTestRunResult}
alias GtfsPlanner.Versions
alias GtfsPlanner.Versions.GtfsVersion

import Ecto.Query

# ── Admin user (existing, used by overlays.spec.js) ──
case Accounts.register_first_admin(%{
       email: "browser-test@gtfs-planner.test",
       password: "BrowserTest123!",
       password_confirmation: "BrowserTest123!",
       organization_name: "Browser Test Org",
       organization_alias: "browser-test"
     }) do
  {:ok, user} ->
    IO.puts("Browser seed: created admin #{user.email} (id=#{user.id})")

    # Fetch the org and version created by register_first_admin
    [org] = Organizations.list_organizations_for_user(user.id)
    IO.puts("Browser seed: org #{org.name} (id=#{org.id})")

    # The default version created by register_first_admin is in staging status.
    # GTFS routes only work with published versions. Create a published version
    # for the browser e2e tests.
    {:ok, diagram_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser E2E Version"})

    IO.puts("Browser seed: published version #{diagram_version.name} (id=#{diagram_version.id})")

    # ── Editor user (for GTFS diagram keyboard test) ──
    editor_attrs = %{
      email: "diagram-test@gtfs-planner.test",
      password: "DiagramTest123!"
    }

    {:ok, editor} = Accounts.register_user(editor_attrs)
    # Confirm the editor user so they can log in
    Repo.update!(User.confirm_changeset(editor))

    Accounts.create_user_org_membership(%{
      user_id: editor.id,
      organization_id: org.id,
      roles: ["pathways_studio_editor"]
    })

    IO.puts("Browser seed: created editor #{editor.email} (id=#{editor.id})")
    export_actor = %{id: editor.id, email: editor.email}

    seed_audit = fn version ->
      %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        actor_id: editor.id,
        actor_email: editor.email,
        station_stop_id: nil
      }
    end

    {:ok, partial_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Partial Retry Version"})

    {:ok, partial_run} =
      ChangeRuns.create_pending_compute(org.id, partial_version.id, export_actor, [])

    {:ok, _computing_partial, partial_compute_generation, partial_compute_token} =
      ChangeRuns.claim(org.id, partial_run.id, :compute)

    partial_decision = %{
      serializer_version: 1,
      decision_id: "level:BROWSER_RETRY_LEVEL",
      entity_type: :level,
      action: :add,
      status: :pending,
      natural_key: "BROWSER_RETRY_LEVEL",
      current_values: %{},
      uploaded_values: %{level_index: 4.0, level_name: "Recovered level"},
      changed_fields: [],
      dependency_keys: [],
      current_fingerprint: nil,
      user_edited: false
    }

    {:ok, partial_review} =
      ChangeRuns.persist_review(
        org.id,
        partial_run.id,
        partial_compute_generation,
        partial_compute_token,
        %{
          decisions: [partial_decision],
          summary: %{add: 1, applicable: 1},
          diagnostics: []
        }
      )

    {:ok, _approved_partial} =
      ChangeRuns.set_decision_status(
        org.id,
        partial_review.id,
        partial_decision.decision_id,
        :approved
      )

    {:ok, pending_partial_apply} =
      ChangeRuns.request_apply(org.id, partial_review.id, export_actor)

    {:ok, _applying_partial, partial_apply_generation, partial_apply_token} =
      ChangeRuns.claim(org.id, pending_partial_apply.id, :apply)

    {:ok, _failed_partial_decision} =
      ChangeRuns.mark_apply_failure(
        org.id,
        pending_partial_apply.id,
        partial_decision.decision_id,
        partial_apply_generation,
        partial_apply_token,
        :browser_seed_failure
      )

    {:ok, _partial_run} =
      ChangeRuns.finish_apply(
        org.id,
        pending_partial_apply.id,
        partial_apply_generation,
        partial_apply_token
      )

    {:ok, cancel_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Cancel Version"})

    {:ok, _cancel_run} =
      ChangeRuns.create_pending_compute(org.id, cancel_version.id, export_actor, [])

    IO.puts("Browser seed: partial retry and pending cancellation change runs")

    # A durable ready artifact lets the browser suite exercise the real scoped
    # download controller without asking a browser test to race a ZIP worker.
    # The bytes are intentionally tiny, but publication still follows the real
    # pending -> claimed -> verified-artifact -> ready transition.
    {:ok, browser_export_run} =
      ExportRuns.create_pending(org.id, diagram_version.id, export_actor, :full)

    {:ok, _claimed_export_run, export_generation, export_token} =
      ExportRuns.claim(org.id, browser_export_run.id, :build)

    {:ok, browser_export_artifact} =
      ArtifactStorage.publish(
        org.id,
        diagram_version.id,
        browser_export_run.id,
        "browser-e2e-export.zip",
        <<80, 75, 3, 4, 20, 0, 0, 0>>
      )

    {:ok, _ready_export_run} =
      ExportRuns.mark_ready(
        org.id,
        browser_export_run.id,
        export_generation,
        export_token,
        %{main: browser_export_artifact, flex: nil}
      )

    IO.puts("Browser seed: ready export artifact for scoped download")

    # ── Station diagram seed data ──
    {:ok, station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_STATION",
        stop_name: "Browser Test Station",
        location_type: 1,
        stop_lat: Decimal.new("40.0390"),
        stop_lon: Decimal.new("-75.1440"),
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: station #{station.stop_id}")

    {:ok, level} =
      GtfsPlanner.GtfsFixtures.insert_level(%{
        level_id: "BROWSER_L1",
        level_name: "Browser Level 1",
        level_index: 0.0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, stop_level} =
      GtfsPlanner.GtfsFixtures.insert_stop_level(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        stop_id: station.id,
        level_id: level.id,
        diagram_filename: "browser_seed_diagram.png"
      })

    IO.puts("Browser seed: stop_level #{stop_level.id} with diagram")

    # The route deliberately serves only files that exist within the versioned,
    # publication-scoped namespace. Store a recognizable 100 × 80 raster at
    # the exact filename referenced above so screenshots exercise visible
    # floorplan placement and transformation, not only the canvas plumbing.
    browser_floorplan_png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAGQAAABQCAMAAADY1yDdAAAATlBMVEX4+vzU2d6gqLKJkp5/iZZaZXbg5OhSXm8zQVVbaX19i59TYXVwhJ/G1enb6v6/2/7I1+uMlJ+nyPtTh/ElY+tEUWNOXnU1Q1dmkvHd5/z/zQfsAAAB10lEQVRYw+2Z2bKCMAyGlUULIoRFxfd/0YMVSsBiSqEZPMN/wzIpHyVpSpvDYZeFjp5PKQiHCsgW3hEjTmfhRudTz2guo5jSRSRY4kK2iJrnKkrTj2tKKhZJ1isRMd3k2vSl84cRwwbyorR+8URkYG8FSSPhvSG+tAcDnwwgpE9AvpmPITEdK0MIqVgHkbGdN1KB3p6/74UjSEjY6yH59/HaQGAA+W7+IxAA5xAAe4hPQrLln2uHbA9CRxcXpCirsjCB5PaQonqpsIfQPoGslJDSpeMhq95yCgGOngCDT+ZE14+MeIZUv2Q+cZpWAvkLdRHhd93EHf0K38WNsG+fGnSv6FKh+g7uhCAZihsAfByfY+Hb2ALdn4Jk0B27gadHjB+sPddDkFQKMdHEe5AQlQwXiISotO4SwtKTWT6xhai0PkNj/9OQqfExSfi0T5hHvEaPlXMXSxbe6vS7Q7a0dNgWZMH6ZDHEZOnAEF0TkLSu6nQ9COggqZx30vUgoIHUElKb+cTW8e2/gFlPbCH6niyHDJYOzzk+MYaM1yfPVaOLZTDukFmQNXJXvzstd6pzvHud5/od7k+7rr0ewrBX77jqwFI/YakEsdS0eKpzLHXGA0vF9D/oDzmmzPWTS7UHAAAAAElFTkSuQmCC"
      )

    # Other browser fixtures intentionally use a minimal image payload.
    one_pixel_png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLqXQAAAABJRU5ErkJggg=="
      )

    :ok =
      DiagramStorage.store_import_image(
        org.id,
        diagram_version.id,
        station.stop_id,
        stop_level.diagram_filename,
        browser_floorplan_png
      )

    # Create child stops with diagram coordinates
    {:ok, browser_child_a} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_STOP_A",
        stop_name: "Platform A North",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 30, "y" => 40},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, browser_child_b} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_STOP_B",
        stop_name: "Platform B South",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 70, "y" => 60},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: child stops placed on diagram")

    {:ok, browser_child_c} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_STOP_C",
        stop_name: "Entrance C",
        location_type: 2,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 50, "y" => 25},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    browser_seed_alignment = %{
      center_lat: 40.0390,
      center_lon: -75.1440,
      scale_mpp: 0.5,
      rotation_deg: 0.0
    }

    browser_image_w = 100
    browser_image_h = 80

    for {stop, svg_x, svg_y} <- [
          {browser_child_a, 30.0, 40.0},
          {browser_child_b, 70.0, 60.0},
          {browser_child_c, 50.0, 25.0}
        ] do
      {:ok, {lat, lon}} =
        FloorplanTransform.svg_to_lat_lon(
          browser_seed_alignment,
          browser_image_w,
          browser_image_h,
          %{x: svg_x, y: svg_y}
        )

      stop
      |> Ecto.Changeset.change(%{
        stop_lat: Decimal.from_float(Float.round(lat, 7)),
        stop_lon: Decimal.from_float(Float.round(lon, 7))
      })
      |> Repo.update!()
    end

    IO.puts("Browser seed: anchor lat/lon derived from known alignment for three child stops")

    IO.puts(
      "Browser seed: diagram ready — /gtfs/#{diagram_version.id}/stops/BROWSER_STATION/diagram"
    )

    # ── Station report and change-history fixtures
    #    (station_reports_and_history.spec.js, Package 15) ──
    #
    # Exactly one valid agency timezone, so the history panel renders the
    # localized zone statement rather than the UTC fallback. Both branches are
    # covered exhaustively in ExUnit; the browser proves the primary one.
    {:ok, _agency} =
      GtfsPlanner.GtfsFixtures.insert_agency(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        agency_id: "BROWSER_AGENCY",
        agency_name: "Browser Test Transit",
        agency_url: "https://example.test",
        agency_timezone: "America/New_York"
      })

    IO.puts("Browser seed: agency timezone America/New_York for history localization")

    # One reachable entrance→platform route, so the station report renders a
    # real connectivity route with a step table. Without it every pair is
    # unreachable and print evidence never exercises the step-table path.
    {:ok, browser_pathway} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_PW_ELEVATOR",
        from_stop_id: "BROWSER_STOP_C",
        to_stop_id: "BROWSER_STOP_A",
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 45,
        length: Decimal.new("12.5")
      })

    IO.puts("Browser seed: elevator pathway BROWSER_STOP_C → BROWSER_STOP_A")

    # ── Reachability result fixtures (reachability_results.spec.js) ──
    #
    # A completed router run, a completed legacy station run, and a completed
    # legacy pathways run exercise each rendering branch without asking browser
    # tests to race background work.
    reachability_started_at = ~U[2026-07-28 12:00:00Z]

    # The router run stores the envelope the production runner produces for
    # this station's current stops and pathway, so the results page renders
    # real sections, pair rows and totals rather than a hand-written shape.
    {:ok, reachability_envelope} =
      Runner.run(
        %{
          station: station,
          child_stops: Gtfs.list_child_stops_for_parent(org.id, diagram_version.id, station.id),
          pathways: Gtfs.list_pathways_for_station(org.id, diagram_version.id, station.id),
          levels: Gtfs.list_levels_for_station(org.id, diagram_version.id, station.id)
        },
        DateTime.utc_now()
      )

    _new_reachability_run =
      %ValidationRun{
        id: "00000000-0000-4000-8000-000000000901",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      }
      |> ValidationRun.changeset(%{
        run_type: "station_reachability",
        status: "completed",
        engine: "pathways_router",
        result_schema_version: 1,
        started_at: reachability_started_at,
        completed_at: reachability_started_at,
        duration_ms: reachability_envelope["duration_ms"],
        result_json: reachability_envelope
      })
      |> Repo.insert!()

    legacy_walkability_test =
      %WalkabilityTest{
        id: "00000000-0000-4000-8000-000000000903",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      }
      |> WalkabilityTest.changeset(%{
        stop_id: browser_child_c.stop_id,
        address: "Browser legacy destination",
        address_lat: Decimal.new("40.0390"),
        address_lon: Decimal.new("-75.1440"),
        description: "Legacy browser test"
      })
      |> Repo.insert!()

    legacy_station_run =
      %ValidationRun{
        id: "00000000-0000-4000-8000-000000000902",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      }
      |> ValidationRun.changeset(%{
        run_type: "station_reachability",
        status: "completed",
        started_at: reachability_started_at,
        completed_at: reachability_started_at,
        result_json: %{"metadata" => %{"station_stop_id" => station.stop_id}}
      })
      |> Repo.insert!()

    legacy_validation_run =
      %ValidationRun{
        id: "00000000-0000-4000-8000-000000000905",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      }
      |> ValidationRun.changeset(%{
        run_type: "pathways_tests",
        status: "completed",
        started_at: reachability_started_at,
        completed_at: reachability_started_at,
        result_json: %{"summary" => %{}}
      })
      |> Repo.insert!()

    for run <- [legacy_station_run, legacy_validation_run] do
      %WalkabilityTestRunResult{
        validation_run_id: run.id,
        walkability_test_id: legacy_walkability_test.id
      }
      |> WalkabilityTestRunResult.changeset(%{
        order_index: 0,
        status: "passed",
        route_exists: true,
        duration_seconds: 45.0
      })
      |> Repo.insert!()
    end

    IO.puts("Browser seed: completed router and legacy reachability result fixtures")

    # ── Station journal fixtures (station_journal_panel.spec.js, Package 02) ──
    #
    # These records deliberately traverse the same trusted scope, sync,
    # closure, photo-inspection, and canonical-storage contracts used by the
    # companion and the production LiveView. Fixed journal/photo UUIDs make
    # retries deterministic; generated station target IDs remain correctly
    # scoped to this freshly reset browser database.
    {:ok, journal_scope} =
      Gtfs.resolve_station_journal_scope(org.id, diagram_version.id, station.id, editor.id)

    journal_entries = [
      %{
        id: "00000000-0000-4000-8000-000000000701",
        target_type: "node",
        target_id: browser_child_a.id,
        body:
          "Water is collecting above the north platform sign. Inspect the ceiling joint and confirm the temporary barrier remains clear of the accessible route.",
        captured_at: ~U[2026-07-21 14:32:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000702",
        target_type: "station",
        body: "North entrance elevator returned to service after the morning inspection.",
        captured_at: ~U[2026-07-21 13:15:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000703",
        target_type: "pathway",
        target_id: browser_pathway.id,
        body: "Elevator travel time measured at 45 seconds with doors operating normally.",
        captured_at: ~U[2026-07-20 17:45:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000704",
        target_type: "pin",
        stop_level_id: stop_level.id,
        diagram_x: 52.0,
        diagram_y: 38.0,
        body:
          "Long field note: verify that the temporary wayfinding board remains readable from both approach directions, does not narrow the accessible clear width, and includes the updated platform designation before the next published export.",
        captured_at: ~U[2026-07-20 12:00:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000705",
        target_type: "node",
        target_id: browser_child_b.id,
        body: "Platform B tactile strip is intact; clean residue near the south end.",
        captured_at: ~U[2026-07-19 16:20:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000706",
        target_type: "node",
        target_id: browser_child_c.id,
        body: "Entrance C door closer needs adjustment after the evening peak.",
        captured_at: ~U[2026-07-19 09:10:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000707",
        target_type: "station",
        body: "Information display audio level checked at the center concourse.",
        captured_at: ~U[2026-07-18 15:00:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000708",
        target_type: "pathway",
        target_id: browser_pathway.id,
        body: "Elevator threshold remains level with the landing surface.",
        captured_at: ~U[2026-07-18 10:30:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000709",
        target_type: "station",
        body: "Emergency call box test completed without faults.",
        captured_at: ~U[2026-07-17 18:05:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-00000000070a",
        target_type: "station",
        body: "Concourse lighting inspection complete; no lamps are out.",
        captured_at: ~U[2026-07-17 11:40:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-00000000070b",
        target_type: "station",
        body: "Bench clearances measured and recorded near the fare array.",
        captured_at: ~U[2026-07-16 14:25:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-00000000070c",
        target_type: "station",
        body: "South platform directional sign is secure and legible.",
        captured_at: ~U[2026-07-16 08:50:00Z]
      }
    ]

    %{synced_count: 12, errors: []} =
      Gtfs.sync_journal_entries(journal_scope, journal_entries)

    {:ok, _closed_browser_journal_entry} =
      Gtfs.close_journal_entry(journal_scope, "00000000-0000-4000-8000-000000000702")

    journal_photo_path =
      Path.join(
        System.tmp_dir!(),
        "gtfs-planner-browser-journal-#{System.unique_integer([:positive])}.png"
      )

    File.write!(journal_photo_path, one_pixel_png)

    try do
      {:ok, _journal_photo} =
        Gtfs.create_journal_photo(
          journal_scope,
          %{
            id: "00000000-0000-4000-8000-0000000007a1",
            journal_entry_id: "00000000-0000-4000-8000-000000000701",
            captured_at: ~U[2026-07-21 14:32:00Z],
            width: 1,
            height: 1
          },
          %{
            path: journal_photo_path,
            filename: "browser-journal-photo.png",
            content_type: "image/png"
          }
        )
    after
      File.rm(journal_photo_path)
    end

    IO.puts("Browser seed: 12 journal entries with one closed entry and canonical photo")

    # ── Package 03 multi-level marker fixtures ──
    #
    # A second level with its own stop_level and diagram image so markers can
    # be tested across levels. Cross-level pathways must NOT produce markers.
    {:ok, level2} =
      GtfsPlanner.GtfsFixtures.insert_level(%{
        level_id: "BROWSER_L2",
        level_name: "Browser Level 2",
        level_index: 1.0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, stop_level2} =
      GtfsPlanner.GtfsFixtures.insert_stop_level(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        stop_id: station.id,
        level_id: level2.id,
        diagram_filename: "browser_seed_diagram_l2.png"
      })

    :ok =
      DiagramStorage.store_import_image(
        org.id,
        diagram_version.id,
        station.stop_id,
        stop_level2.diagram_filename,
        one_pixel_png
      )

    {:ok, _browser_child_d} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_STOP_D",
        stop_name: "Mezzanine Landing D",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level2.level_id,
        diagram_coordinate: %{"x" => 45, "y" => 55},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, browser_crowded_stop} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_CROWDED_STOP",
        stop_name: "Northbound Interchange Platform With Extended Name For Crowding Verification",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 85, "y" => 30},
        wheelchair_boarding: 1,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, browser_same_level_pw} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_PW_SAME_LEVEL",
        from_stop_id: "BROWSER_STOP_A",
        to_stop_id: "BROWSER_STOP_B",
        pathway_mode: 1,
        is_bidirectional: true,
        traversal_time: 20,
        length: Decimal.new("8.0")
      })

    {:ok, _browser_cross_level_pw} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_PW_CROSS_LEVEL",
        from_stop_id: "BROWSER_STOP_A",
        to_stop_id: "BROWSER_STOP_D",
        pathway_mode: 5,
        is_bidirectional: false,
        traversal_time: 60,
        length: Decimal.new("25.0")
      })

    IO.puts("Browser seed: multi-level fixtures (L2, crowded stop, same/cross-level pathways)")

    pkg3_journal_entries = [
      %{
        id: "00000000-0000-4000-8000-000000000711",
        target_type: "node",
        target_id: browser_child_a.id,
        body: "Second observation on Platform A: handrail bracket loose near the north end.",
        captured_at: ~U[2026-07-21 15:00:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000712",
        target_type: "pin",
        stop_level_id: stop_level2.id,
        diagram_x: 60.0,
        diagram_y: 42.0,
        body: "Mezzanine level pin: verify emergency exit signage illumination.",
        captured_at: ~U[2026-07-21 11:30:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000713",
        target_type: "pathway",
        target_id: browser_same_level_pw.id,
        body: "Same-level corridor between platforms: floor surface even, no trip hazards.",
        captured_at: ~U[2026-07-21 10:15:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000714",
        target_type: "pathway",
        target_id: browser_pathway.id,
        body: "Elevator shaft interior: lighting adequate, no water ingress observed.",
        captured_at: ~U[2026-07-20 16:00:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000715",
        target_type: "node",
        target_id: browser_crowded_stop.id,
        body:
          "Crowded platform inspection: tactile paving intact, wayfinding signage legible, bench clearances within tolerance, waste receptacles secured, lighting uniform across full platform length.",
        captured_at: ~U[2026-07-20 09:45:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000716",
        target_type: "pin",
        stop_level_id: stop_level.id,
        diagram_x: 20.0,
        diagram_y: 70.0,
        body: "South concourse pin: drainage grate secure, no standing water.",
        captured_at: ~U[2026-07-19 14:00:00Z]
      }
    ]

    %{synced_count: 6, errors: []} =
      Gtfs.sync_journal_entries(journal_scope, pkg3_journal_entries)

    {:ok, _closed_pkg3_pin} =
      Gtfs.close_journal_entry(journal_scope, "00000000-0000-4000-8000-000000000712")

    IO.puts(
      "Browser seed: 6 Package 03 journal entries (multi-entry node, multi-level pins, pathways, crowded stop)"
    )

    # ── Package 04 entity drawer journal fixtures ──
    #
    # deterministic node/pathway entries for the entity drawer Journal tab.
    # Requires a node entry on browser_child_a (Platform A North), a pathway
    # entry on browser_pathway (Elevator), a zero-entry stop, legacy
    # closed-valued entries (already seeded in Package 02 as 702), and a
    # photo fixture on one node entry.
    pkg4_journal_entries = [
      %{
        id: "00000000-0000-4000-8000-000000000721",
        target_type: "node",
        target_id: browser_child_a.id,
        body:
          "Platform A North: surface near staircase is dry, tactile strip intact, no trip hazards observed.",
        captured_at: ~U[2026-07-22 08:15:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000722",
        target_type: "node",
        target_id: browser_child_a.id,
        body:
          "Signage above Platform A North is securely mounted and legible from both approach directions.",
        captured_at: ~U[2026-07-22 09:30:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000723",
        target_type: "pathway",
        target_id: browser_pathway.id,
        body:
          "Elevator call button responsive, door sensor operates within spec, interior lighting adequate.",
        captured_at: ~U[2026-07-22 10:00:00Z]
      },
      %{
        id: "00000000-0000-4000-8000-000000000724",
        target_type: "node",
        target_id: browser_child_b.id,
        body: "Platform B South bench clearances measured and recorded. Rest area is clean.",
        captured_at: ~U[2026-07-22 09:00:00Z]
      }
    ]

    %{synced_count: 4, errors: []} =
      Gtfs.sync_journal_entries(journal_scope, pkg4_journal_entries)

    {:ok, _closed_summary_entry} =
      Gtfs.close_journal_entry(journal_scope, "00000000-0000-4000-8000-000000000724")

    # Attach a photo to one node entry for the photo-link test
    pkg4_photo_path =
      Path.join(
        System.tmp_dir!(),
        "gtfs-planner-browser-journal-pkg4-#{System.unique_integer([:positive])}.png"
      )

    File.write!(pkg4_photo_path, one_pixel_png)

    try do
      {:ok, _pkg4_photo} =
        Gtfs.create_journal_photo(
          journal_scope,
          %{
            id: "00000000-0000-4000-8000-0000000007b1",
            journal_entry_id: "00000000-0000-4000-8000-000000000721",
            captured_at: ~U[2026-07-22 08:15:00Z],
            width: 1,
            height: 1
          },
          %{
            path: pkg4_photo_path,
            filename: "browser-pkg4-journal-photo.png",
            content_type: "image/png"
          }
        )
    after
      File.rm(pkg4_photo_path)
    end

    # Create a zero-entry entity (stop with no journal entries) for the
    # empty-state test. browser_child_c already exists but has station entries
    # targeting it as a whole, so create a dedicated fresh node.
    {:ok, _browser_zero_entry_stop} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EMPTY_JOURNAL_STOP",
        stop_name: "Empty Journal Node",
        location_type: 0,
        parent_station: station.stop_id,
        level_id: level.level_id,
        diagram_coordinate: %{"x" => 25, "y" => 75},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts(
      "Browser seed: 4 Package 04 journal entries (multi-entry node, pathway, photo, recent closed entry, zero-entry stop)"
    )

    # A long-named, long-id, unconnected generic node. It fails the isolated
    # node check, so the report renders a failed-check detail whose value must
    # wrap rather than truncate at 320 px. No diagram coordinate: it stays off
    # the canvas so the existing diagram keyboard fixtures are unchanged.
    {:ok, _browser_long_node} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_GENERIC_NODE_WITH_A_DELIBERATELY_LONG_IDENTIFIER_0001",
        stop_name:
          "Northbound Interchange Concourse Generic Circulation Node Under Reconstruction",
        location_type: 3,
        parent_station: station.stop_id,
        level_id: level.level_id,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: long-named isolated generic node for report reflow tests")

    # ── Long-name fixtures for responsive data-view browser tests ──
    {:ok, _long_org} =
      Organizations.create_organization_unchecked(%{
        name: "Metropolitan Regional Transit Authority of the Greater Metropolitan Area",
        alias: "metro-regional-transit-authority-greater-metropolitan-area"
      })

    IO.puts("Browser seed: long-name organization for reflow tests")

    Enum.each(1..3, fn idx ->
      {:ok, _long_route} =
        GtfsPlanner.GtfsFixtures.insert_route(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: "LONG_ROUTE_#{idx}",
          route_short_name:
            "Express Route #{idx} — Downtown to University District via Waterfront and Convention Center",
          route_long_name:
            "Metropolitan Express Route #{idx} connecting Downtown Transit Center to University District via Waterfront Promenade, Convention Center, and Medical Campus",
          route_type: 3,
          route_color: "FF5733"
        })
    end)

    IO.puts("Browser seed: long-name routes for reflow tests")

    # ── Route pattern editor fixtures (read-only slice) ──
    #
    # Three isolated routes give the pattern list its ready, first-use and
    # unlinked-trips states without sharing records with any mutating journey:
    # BROWSER_PATTERNS_READY carries two patterns, occurrences, one timing and
    # linked trips; BROWSER_PATTERNS_EMPTY has none; BROWSER_PATTERNS_UNLINKED
    # has ungrouped trips with stop times but no patterns.
    pattern_stops =
      Enum.map(1..4, fn index ->
        # Coordinates for the saved route map (spec 16, step 30): the Details
        # page draws the patterns' saved connectors and the seeded imported
        # shape from these rows.
        coordinates =
          Enum.at(
            [
              {"39.9515", "-75.1640"},
              {"39.9560", "-75.1550"},
              {"39.9600", "-75.1470"},
              {"39.9640", "-75.1400"}
            ],
            index - 1
          )

        {:ok, stop} =
          GtfsPlanner.GtfsFixtures.insert_stop(%{
            stop_id: "BROWSER_PATTERN_STOP_#{index}",
            stop_name: "Pattern Stop #{index}",
            location_type: 0,
            stop_lat: Decimal.new(elem(coordinates, 0)),
            stop_lon: Decimal.new(elem(coordinates, 1)),
            organization_id: org.id,
            gtfs_version_id: diagram_version.id
          })

        stop
      end)

    pattern_routes =
      [
        {"BROWSER_PATTERNS_READY", "PR", "Browser Patterns Ready"},
        {"BROWSER_PATTERNS_EMPTY", "PE", "Browser Patterns Empty"},
        {"BROWSER_PATTERNS_UNLINKED", "PU", "Browser Patterns Unlinked"}
      ]
      |> Enum.map(fn {route_id, short_name, long_name} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3
          })

        route
      end)
      |> Map.new(&{&1.route_id, &1})

    ready_route = Map.fetch!(pattern_routes, "BROWSER_PATTERNS_READY")

    occurrence_fixture = fn route_pattern, stops ->
      stops
      |> Enum.with_index(1)
      |> Enum.map(fn {stop, position} ->
        GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(route_pattern, stop.stop_id, position)
      end)
    end

    timing_fixture = fn route_pattern, name, occurrences ->
      timing = GtfsPlanner.GtfsFixtures.timed_pattern_fixture(route_pattern, %{name: name})

      Enum.each(occurrences, fn occurrence ->
        GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(timing, occurrence, %{
          arrival_offset: 0,
          departure_offset: 0
        })
      end)

      timing
    end

    outbound =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: ready_route.route_id,
        route_pattern_id: "BROWSER-P1",
        route_pattern_name: "Central – Valley Hospital",
        route_pattern_time_desc: "All day",
        route_pattern_typicality: 1,
        direction_id: 0,
        route_pattern_sort_order: 1
      })

    outbound_occurrences = occurrence_fixture.(outbound, Enum.take(pattern_stops, 4))
    outbound_timing = timing_fixture.(outbound, "Weekday daytime", outbound_occurrences)
    timing_fixture.(outbound, "Evenings & weekends", outbound_occurrences)

    inbound =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: ready_route.route_id,
        route_pattern_id: "BROWSER-P2",
        route_pattern_name: "Valley Hospital – Central",
        route_pattern_time_desc: "All day",
        route_pattern_typicality: 3,
        direction_id: 1,
        route_pattern_sort_order: 1
      })

    inbound_occurrences =
      occurrence_fixture.(inbound, pattern_stops |> Enum.take(3) |> Enum.reverse())

    timing_fixture.(inbound, "All day", inbound_occurrences)

    Enum.each(["BROWSER_PT1", "BROWSER_PT2"], fn trip_id ->
      {:ok, trip} =
        GtfsPlanner.GtfsFixtures.insert_trip(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: ready_route.route_id,
          trip_id: trip_id,
          service_id: "BROWSER_PATTERN_SERVICE",
          trip_headsign: "Valley Hospital",
          direction_id: 0,
          # The saved route map's labelled variant (spec 16, step 30): one
          # distinct imported shape on the first trip only, so the route shows
          # one variant whose geometry differs from the stop connectors.
          shape_id: if(trip_id == "BROWSER_PT1", do: "BROWSER_SHAPE_1", else: nil)
        })

      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: "BROWSER-P1",
        timed_pattern_id: outbound_timing.id,
        pattern_derivation_state: "linked"
      })
    end)

    Enum.with_index(
      [{"39.9520", "-75.1630"}, {"39.9575", "-75.1520"}, {"39.9630", "-75.1420"}],
      1
    )
    |> Enum.each(fn {{lat, lon}, sequence} ->
      Repo.insert!(%GtfsPlanner.Gtfs.Shape{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        shape_id: "BROWSER_SHAPE_1",
        shape_pt_lat: Decimal.new(lat),
        shape_pt_lon: Decimal.new(lon),
        shape_pt_sequence: sequence
      })
    end)

    # ── Spec 27 scenario route (step 18) ──
    #
    # BROWSER_SHAPES carries every state the Patterns tab, the blank-timing
    # editor and the grouping review need at once: a drawn pattern with linked
    # trips, a timing whose middle rows are blank, 27 trips left outside
    # patterns across three reasons and one supplied label pair. The left-out
    # trips stay pending and Derivation classifies them, so the reasons stored
    # on them are the production rules' own verdicts rather than seeded labels,
    # and the label child is linked through the same run.
    {:ok, shapes_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_SHAPES",
        route_short_name: "SH",
        route_long_name: "US 101 Coast Newport – Lincoln City",
        route_type: 3
      })

    # The corridor runs north along one meridian of US 101 between Newport and
    # Lincoln City, so a saved segment's midpoint is its own latitude step and
    # no projection error competes with the drawn line.
    shapes_coordinates = [
      {"44.6360", "-124.0490"},
      {"44.6610", "-124.0490"},
      {"44.6860", "-124.0490"},
      {"44.7110", "-124.0490"},
      {"44.7360", "-124.0490"},
      {"44.7610", "-124.0490"},
      {"44.7860", "-124.0490"},
      {"44.8110", "-124.0490"},
      {"44.8360", "-124.0490"},
      {"44.8610", "-124.0490"},
      {"44.8860", "-124.0490"},
      {"44.9110", "-124.0490"},
      {"44.9360", "-124.0490"}
    ]

    shapes_stop_ids =
      Enum.map(1..13, fn index ->
        {lat, lon} = Enum.at(shapes_coordinates, index - 1)

        {:ok, stop} =
          GtfsPlanner.GtfsFixtures.insert_stop(%{
            stop_id: "BROWSER_SHAPES_STOP_#{index}",
            stop_name: "US 101 Stop #{index}",
            location_type: 0,
            stop_lat: Decimal.new(lat),
            stop_lon: Decimal.new(lon),
            organization_id: org.id,
            gtfs_version_id: diagram_version.id
          })

        stop.stop_id
      end)

    # A station with no platform: the one trip served only from here cannot
    # become a pattern stop, which is the `unusable_stops` case.
    {:ok, _shapes_station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_SHAPES_STATION",
        stop_name: "US 101 Transit Center",
        location_type: 1,
        stop_lat: Decimal.new("44.6485"),
        stop_lon: Decimal.new("-124.0490"),
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    shapes_pattern =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: shapes_route.route_id,
        route_pattern_id: "BROWSER-SHAPES-A",
        route_pattern_name: "Newport – Lincoln City",
        route_pattern_time_desc: "All day",
        route_pattern_typicality: 1,
        direction_id: 0,
        derivation_key: "d0-#{shapes_route.route_id}",
        route_pattern_sort_order: 1
      })

    shapes_occurrences =
      shapes_stop_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {stop_id, position} ->
        GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(shapes_pattern, stop_id, position)
      end)

    # One shared segment per drawn leg, so the route opens on a saved map line.
    # Scope fields are set on the struct and never cast: the changeset takes
    # only `:points`.
    shapes_stop_ids
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.each(fn {[from_stop_id, to_stop_id], index} ->
      %AlignmentSegment{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        from_stop_id: from_stop_id,
        to_stop_id: to_stop_id
      }
      |> AlignmentSegment.changeset(%{
        points: [[-124.0490, 44.6485 + index * 0.0250]]
      })
      |> Repo.insert!()
    end)

    shapes_timing =
      GtfsPlanner.GtfsFixtures.timed_pattern_fixture(shapes_pattern, %{name: "Weekday daytime"})

    # Stops 2-4 are passed through without a scheduled time, so the timing has
    # blank offset pairs exactly where the timing editor draws them blank.
    Enum.each(shapes_occurrences, fn occurrence ->
      offsets =
        if occurrence.position in 2..4 do
          %{arrival_offset: nil, departure_offset: nil}
        else
          minutes = (occurrence.position - 1) * 5

          %{arrival_offset: minutes, departure_offset: minutes}
        end

      GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(shapes_timing, occurrence, offsets)
    end)

    shapes_timing_rows =
      from(tps in GtfsPlanner.Gtfs.TimedPatternStop,
        join: o in assoc(tps, :route_pattern_stop),
        where: tps.timed_pattern_id == ^shapes_timing.id,
        order_by: [asc: o.position],
        select: {o.stop_id, o.position, tps.arrival_offset, tps.departure_offset, tps.timepoint}
      )
      |> Repo.all()

    Enum.each(1..38, fn index ->
      trip =
        GtfsPlanner.GtfsFixtures.trip_fixture(
          org.id,
          diagram_version.id,
          shapes_route.route_id,
          %{
            trip_id:
              "BROWSER_SHAPES_LINKED_" <> String.pad_leading(Integer.to_string(index), 2, "0"),
            service_id: "BROWSER_SHAPES_SERVICE",
            trip_headsign: "Lincoln City",
            direction_id: 0
          }
        )

      # Linked trips of the drawn pattern. `route_pattern_id` and
      # `timed_pattern_id` are application-owned and not cast by the changeset.
      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: "BROWSER-SHAPES-A",
        timed_pattern_id: shapes_timing.id,
        pattern_derivation_state: "linked"
      })

      # A linked trip carries the times its pattern's timing gives it. Without
      # them the link is only a label: saving a map line for BROWSER-SHAPES-A is
      # refused because every trip on it has 0 stop times, so the journey could
      # never reach the saved state. The timing's blank rows stay blank, which
      # is what positions 2..4 are for.
      shapes_seed_at = diagram_version.inserted_at
      base = 6 * 3600 + (index - 1) * 600

      time = fn
        nil -> nil
        offset -> GtfsPlanner.Gtfs.GtfsTime.format(base + offset)
      end

      {_inserted, nil} =
        Repo.insert_all(
          StopTime,
          Enum.map(shapes_timing_rows, fn {stop_id, position, arrival, departure, timepoint} ->
            %{
              id: Ecto.UUID.generate(),
              organization_id: org.id,
              gtfs_version_id: diagram_version.id,
              trip_id: trip.trip_id,
              stop_id: stop_id,
              stop_sequence: position,
              arrival_time: time.(arrival),
              departure_time: time.(departure),
              timepoint: timepoint,
              inserted_at: shapes_seed_at,
              updated_at: shapes_seed_at
            }
          end)
        )
    end)

    # The imported northbound shape the 18 direction-less trips share, drawn
    # slightly east of the stop line so the map shows two geometries.
    Enum.with_index(shapes_coordinates, 1)
    |> Enum.each(fn {{lat, lon}, sequence} ->
      Repo.insert!(%Shape{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        shape_id: "BROWSER_SHAPE_N",
        shape_pt_lat: Decimal.new(lat),
        shape_pt_lon: Decimal.add(Decimal.new(lon), Decimal.new("0.0020")),
        shape_pt_sequence: sequence
      })
    end)

    # ── Imported-only pattern (step 32) ──
    #
    # BROWSER_IMPORTED carries one pattern that is still on an imported shape:
    # no saved segments, and its linked trips reference BROWSER_IMPORTED_SHAPE.
    # The shape runs the corridor's own meridian and bows east through the
    # middle, so the imported-line card shows the far stops the fit reports
    # rather than a clean line.
    {:ok, imported_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_IMPORTED",
        route_short_name: "IMP",
        route_long_name: "US 101 Imported corridor",
        route_type: 3
      })

    imported_coordinates = Enum.take(shapes_coordinates, 5)

    imported_stop_ids =
      Enum.map(1..5, fn index ->
        {lat, lon} = Enum.at(imported_coordinates, index - 1)

        {:ok, stop} =
          GtfsPlanner.GtfsFixtures.insert_stop(%{
            stop_id: "BROWSER_IMPORTED_STOP_#{index}",
            stop_name: "Import Stop #{index}",
            location_type: 0,
            stop_lat: Decimal.new(lat),
            stop_lon: Decimal.new(lon),
            organization_id: org.id,
            gtfs_version_id: diagram_version.id
          })

        stop.stop_id
      end)

    imported_pattern =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: imported_route.route_id,
        route_pattern_id: "BROWSER-IMPORTED-A",
        route_pattern_name: "Imported northbound",
        route_pattern_time_desc: "All day",
        route_pattern_typicality: 0,
        direction_id: 0,
        derivation_key: "d0-#{imported_route.route_id}"
      })

    imported_stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(
        imported_pattern,
        stop_id,
        position
      )
    end)

    imported_timing =
      GtfsPlanner.GtfsFixtures.timed_pattern_fixture(imported_pattern, %{name: "Weekday daytime"})

    Enum.each(1..3, fn index ->
      trip =
        GtfsPlanner.GtfsFixtures.trip_fixture(
          org.id,
          diagram_version.id,
          imported_route.route_id,
          %{
            trip_id:
              "BROWSER_IMPORTED_LINKED_" <> String.pad_leading(Integer.to_string(index), 2, "0"),
            service_id: "BROWSER_SHAPES_SERVICE",
            trip_headsign: "Lincoln City",
            direction_id: 0,
            shape_id: "BROWSER_IMPORTED_SHAPE"
          }
        )

      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: "BROWSER-IMPORTED-A",
        timed_pattern_id: imported_timing.id,
        pattern_derivation_state: "linked"
      })
    end)

    # The line bows east across the corridor rather than along it: the middle
    # point sits about 200 m off the meridian its stops stand on, so the fit
    # review names the stop it runs wide of, and the two beside it stay inside
    # the 330 ft the review reads in.
    Enum.with_index(imported_coordinates, 1)
    |> Enum.each(fn {{lat, lon}, sequence} ->
      offset =
        cond do
          sequence == 1 or sequence == 5 -> "0"
          sequence == 3 -> "0.0025"
          true -> "0.0009"
        end

      Repo.insert!(%Shape{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        shape_id: "BROWSER_IMPORTED_SHAPE",
        shape_pt_lat: Decimal.new(lat),
        shape_pt_lon: Decimal.add(Decimal.new(lon), Decimal.new(offset)),
        shape_pt_sequence: sequence
      })
    end)

    # ── Supplied label pair ──
    #
    # The owner carries the stop order and the child carries the owner's id, as
    # INV-3 requires; the trips below reference the child, so derivation links
    # them to it without creating a second child of its own.
    label_stop_ids = Enum.take(shapes_stop_ids, 4)

    label_owner =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: shapes_route.route_id,
        route_pattern_id: "BROWSER-LABEL-A",
        route_pattern_name: "Coast Limited",
        route_pattern_time_desc: "All day",
        direction_id: 0,
        route_pattern_sort_order: 2
      })

    label_stop_ids
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, position} ->
      GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(label_owner, stop_id, position)
    end)

    label_child =
      %RoutePattern{}
      |> RoutePattern.changeset(%{
        route_id: shapes_route.route_id,
        route_pattern_id: "BROWSER-LABEL-X",
        route_pattern_name: "Coast Limited Short",
        route_pattern_time_desc: "All day",
        direction_id: 0,
        route_pattern_sort_order: 2,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })
      |> Ecto.Changeset.change(label_pattern_id: label_owner.id)
      |> Repo.insert!()

    IO.puts("Browser seed: BROWSER_SHAPES route with #{length(shapes_stop_ids)} stops")

    # ── Left-out trips and the label pair's trips ──
    #
    # Every trip below is left pending, so Derivation reads its own stop-time
    # vector and classifies it. The 24 direction-less trips become the two
    # groups the review offers (18 over the full stop order, 6 over its first
    # seven), the two trips served before they depart become
    # `invalid_chronology` and the station-only trip becomes `unusable_stops`.
    hhmm = fn minutes ->
      "#{String.pad_leading(Integer.to_string(div(minutes, 60)), 2, "0")}:" <>
        "#{String.pad_leading(Integer.to_string(rem(minutes, 60)), 2, "0")}:00"
    end

    seed_pending_trip = fn trip_id, attrs, stop_ids, times ->
      trip =
        GtfsPlanner.GtfsFixtures.trip_fixture(
          org.id,
          diagram_version.id,
          shapes_route.route_id,
          attrs
        )

      stop_ids
      |> Enum.zip(times)
      |> Enum.with_index(1)
      |> Enum.each(fn {{stop_id, time}, sequence} ->
        GtfsPlanner.GtfsFixtures.stop_time_fixture(
          org.id,
          diagram_version.id,
          trip.trip_id,
          stop_id,
          %{arrival_time: time, departure_time: time, stop_sequence: sequence}
        )
      end)

      trip
    end

    Enum.each(1..18, fn index ->
      seed_pending_trip.(
        "BROWSER_SHAPES_NORTH_" <> String.pad_leading(Integer.to_string(index), 2, "0"),
        %{
          trip_headsign: "Lincoln City",
          shape_id: "BROWSER_SHAPE_N"
        },
        shapes_stop_ids,
        Enum.map(0..12, fn step -> hhmm.(420 + index + step * 5) end)
      )
    end)

    Enum.each(1..6, fn index ->
      seed_pending_trip.(
        "BROWSER_SHAPES_SHORT_" <> String.pad_leading(Integer.to_string(index), 2, "0"),
        %{trip_headsign: "Depoe Bay"},
        Enum.take(shapes_stop_ids, 7),
        Enum.map(0..6, fn step -> hhmm.(540 + index + step * 5) end)
      )
    end)

    # Served before it departs: the second stop is timed before the first, so
    # derivation refuses the vector for its chronology. They name the drawn
    # pattern, so the refusal is the only thing left unlinked about them and the
    # route keeps no second pattern for an order no trip can time.
    Enum.each(1..2, fn index ->
      out_of_order =
        seed_pending_trip.(
          "BROWSER_SHAPES_OUT_OF_ORDER_" <> String.pad_leading(Integer.to_string(index), 2, "0"),
          %{trip_headsign: "Lincoln City", direction_id: 0},
          shapes_stop_ids,
          [hhmm.(425 + index), hhmm.(420 + index)] ++
            Enum.map(2..12, fn step -> hhmm.(420 + index + step * 5) end)
        )

      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(out_of_order, %{
        route_pattern_id: "BROWSER-SHAPES-A"
      })
    end)

    seed_pending_trip.(
      "BROWSER_SHAPES_STATION_TRIP",
      %{trip_headsign: "Transit Center", direction_id: 0},
      ["BROWSER_SHAPES_STATION"],
      [hhmm.(600)]
    )

    Enum.each(1..2, fn index ->
      label_trip =
        seed_pending_trip.(
          "BROWSER_SHAPES_LABEL_" <> String.pad_leading(Integer.to_string(index), 2, "0"),
          %{trip_headsign: "Coast Limited", direction_id: 0},
          label_stop_ids,
          Enum.map(0..3, fn step -> hhmm.(660 + index + step * 4) end)
        )

      # The trips name the supplied child, so derivation links them to it and
      # never plans a derived pattern for the label's own stop order.
      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(label_trip, %{
        route_pattern_id: label_child.route_pattern_id
      })
    end)

    {:ok, shapes_derivation} =
      Derivation.derive_route(org.id, diagram_version.id, shapes_route.route_id, {:import, nil})

    # The seed fails loudly rather than serving a browser scenario that drifted
    # from the numbers the later visual steps capture.
    [
      %{reason: "missing_direction", trip_count: 24},
      %{reason: "invalid_chronology", trip_count: 2},
      %{reason: "unusable_stops", trip_count: 1}
    ] = Gtfs.left_out_trips(org.id, diagram_version.id, shapes_route.route_id)

    [stored_owner, stored_child] =
      Repo.all(
        from(p in RoutePattern,
          where:
            p.organization_id == ^org.id and p.gtfs_version_id == ^diagram_version.id and
              p.route_id == ^shapes_route.route_id and
              p.route_pattern_id in ["BROWSER-LABEL-A", "BROWSER-LABEL-X"]
        )
      )
      |> Enum.sort_by(& &1.route_pattern_id)

    true = stored_child.label_pattern_id == stored_owner.id
    true = is_nil(stored_owner.label_pattern_id)

    IO.puts(
      "Browser seed: BROWSER_SHAPES #{inspect(shapes_derivation)}, 27 trips left out, label child #{label_child.route_pattern_id}"
    )

    # ── Other-route context fixtures (spec 16, step 31) ──
    #
    # Fifty-five small routes over the pattern-stop corner of the map, so the
    # Details map's "Show other routes" layer has more than one 50-route page
    # and every context route sits inside the fitted viewport. CTX_50 is
    # explicitly inactive to give the layer its dashed inactive state; it sorts
    # inside the first 50-route page (routes order by route_id, and the CTX_
    # block sorts before every other seeded route id), so the dashed state is
    # observable on the layer's first page without paging.
    Enum.each(1..55, fn index ->
      route_id = "BROWSER_CTX_" <> String.pad_leading(Integer.to_string(index), 2, "0")

      {:ok, _context_route} =
        GtfsPlanner.GtfsFixtures.insert_route(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: route_id,
          route_short_name: "C#{index}",
          route_long_name: "Context Route #{index}",
          route_type: 3,
          active: index != 50
        })

      context_pattern =
        GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
          route_id: route_id,
          route_pattern_id: route_id <> "-P1",
          route_pattern_name: "Context #{index}",
          direction_id: 0
        })

      [first_stop, second_stop] = Enum.take(pattern_stops, 2)
      GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(context_pattern, first_stop.stop_id, 1)
      GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(context_pattern, second_stop.stop_id, 2)
    end)

    IO.puts("Browser seed: 55 context routes for the Show-other-routes layer")

    unlinked_route = Map.fetch!(pattern_routes, "BROWSER_PATTERNS_UNLINKED")

    Enum.each(["BROWSER_PU1", "BROWSER_PU2"], fn trip_id ->
      {:ok, trip} =
        GtfsPlanner.GtfsFixtures.insert_trip(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: unlinked_route.route_id,
          trip_id: trip_id,
          service_id: "BROWSER_PATTERN_SERVICE",
          trip_headsign: "Valley Hospital",
          direction_id: 0
        })

      [first, second] = Enum.take(pattern_stops, 2)

      Enum.each([{first, 1}, {second, 2}], fn {stop, sequence} ->
        {:ok, _stop_time} =
          GtfsPlanner.GtfsFixtures.insert_stop_time(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            trip_id: trip.trip_id,
            stop_id: stop.stop_id,
            stop_sequence: sequence,
            arrival_time: "08:0#{sequence}:00",
            departure_time: "08:0#{sequence}:00"
          })
      end)
    end)

    IO.puts("Browser seed: route pattern routes (ready with 2 patterns, empty, unlinked trips)")

    # ── Pattern comparison fixtures (spec 19, step 11) ──
    #
    # Route BROWSER_COMPARE carries the two-pattern states the compare journey
    # opens. FULL is the six-stop reference whose timing waits 60 s at its
    # fourth stop; SHORT is the short turn ending at that stop, one minute
    # quicker on the shared stretch that ends there (R5); DEV replaces the
    # third stop with two stops; LOOP visits stops 1 and 2 twice ("visit 2 of
    # 2"); MOVED serves stop 3 before stop 2; BACK is the reversed direction-1
    # copy, so FULL against it reads as opposite directions.
    # BROWSER_COMPARE_OTHER shares stops 1 and 5 with FULL and adds its own
    # terminal, so the picker ranks and finds a cross-route pattern by name.
    # The comparison page only reads these records (INV-2). The weekday
    # calendar and its linked trips give the landing pair a deterministic
    # calendar and non-zero usage.
    #
    # Coordinates sit near the pattern-alignment stops, deliberately away from
    # the stopped-route corner BROWSER_PATTERNS_READY draws: the route Details
    # map counts the nearby routes of its own viewport, and a comparison route
    # inside that box would move route_lifecycle.spec.js's seeded total.
    comparison_stops =
      [
        {"BROWSER_CMP_STOP_1", "Browser Compare Stop 1", "40.7000", "-74.0200"},
        {"BROWSER_CMP_STOP_2", "Browser Compare Stop 2", "40.7012", "-74.0178"},
        {"BROWSER_CMP_STOP_3", "Browser Compare Stop 3", "40.7024", "-74.0156"},
        {"BROWSER_CMP_STOP_3A", "Browser Compare Stop 3A", "40.7018", "-74.0170"},
        {"BROWSER_CMP_STOP_3B", "Browser Compare Stop 3B", "40.7030", "-74.0148"},
        {"BROWSER_CMP_STOP_4", "Browser Compare Stop 4", "40.7036", "-74.0134"},
        {"BROWSER_CMP_STOP_5", "Browser Compare Stop 5", "40.7048", "-74.0112"},
        {"BROWSER_CMP_STOP_6", "Browser Compare Stop 6", "40.7060", "-74.0090"},
        {"BROWSER_CMP_OTHER_STOP", "Browser Compare Other Terminal", "40.6975", "-74.0245"}
      ]

    Enum.each(comparison_stops, fn {stop_id, stop_name, lat, lon} ->
      {:ok, _comparison_stop} =
        GtfsPlanner.GtfsFixtures.insert_stop(%{
          stop_id: stop_id,
          stop_name: stop_name,
          location_type: 0,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new(lon),
          organization_id: org.id,
          gtfs_version_id: diagram_version.id
        })
    end)

    comparison_routes =
      [
        {"BROWSER_COMPARE", "BC", "Browser Compare"},
        {"BROWSER_COMPARE_OTHER", "BO", "Browser Compare Other"}
      ]
      |> Enum.map(fn {route_id, short_name, long_name} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3
          })

        route
      end)
      |> Map.new(&{&1.route_id, &1})

    comparison_route = Map.fetch!(comparison_routes, "BROWSER_COMPARE")
    comparison_other_route = Map.fetch!(comparison_routes, "BROWSER_COMPARE_OTHER")

    # Explicit literal offsets, so the running-time cases are hand-derivable:
    # FULL's stop 4 arrives at 570 s and departs at 630 s (the 60 s wait), and
    # SHORT reaches stop 4 at 510 s, −1:00 on the segment that ends there.
    comparison_pattern = fn route_id, attrs ->
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(
        org.id,
        diagram_version.id,
        Map.merge(%{route_id: route_id}, attrs)
      )
    end

    comparison_full =
      comparison_pattern.(comparison_route.route_id, %{
        direction_id: 0,
        route_pattern_id: "BROWSER-CMP-FULL",
        route_pattern_name: "Browser Compare Full",
        route_pattern_sort_order: 1,
        route_pattern_typicality: 1,
        timing_name: "Weekday base",
        stops: [
          {"BROWSER_CMP_STOP_1", 0, 0, 1},
          {"BROWSER_CMP_STOP_2", 180, 180, 0},
          {"BROWSER_CMP_STOP_3", 360, 360, 0},
          {"BROWSER_CMP_STOP_4", 570, 630, 1},
          {"BROWSER_CMP_STOP_5", 870, 870, 0},
          {"BROWSER_CMP_STOP_6", 1110, 1110, 1}
        ]
      })

    comparison_short =
      comparison_pattern.(comparison_route.route_id, %{
        direction_id: 0,
        route_pattern_id: "BROWSER-CMP-SHORT",
        route_pattern_name: "Browser Compare Short",
        route_pattern_sort_order: 3,
        route_pattern_typicality: 1,
        timing_name: "Weekday short",
        stops: [
          {"BROWSER_CMP_STOP_1", 0, 0, 1},
          {"BROWSER_CMP_STOP_2", 180, 180, 0},
          {"BROWSER_CMP_STOP_3", 360, 360, 0},
          {"BROWSER_CMP_STOP_4", 510, 510, 1}
        ]
      })

    comparison_pattern.(comparison_route.route_id, %{
      direction_id: 0,
      route_pattern_id: "BROWSER-CMP-DEV",
      route_pattern_name: "Browser Compare Dev",
      route_pattern_sort_order: 2,
      route_pattern_typicality: 1,
      timing_name: "Weekday base",
      stops: [
        {"BROWSER_CMP_STOP_1", 0, 0, 1},
        {"BROWSER_CMP_STOP_2", 180, 180, 0},
        {"BROWSER_CMP_STOP_3A", 600, 600, 0},
        {"BROWSER_CMP_STOP_3B", 900, 900, 0},
        {"BROWSER_CMP_STOP_4", 1290, 1290, 1},
        {"BROWSER_CMP_STOP_5", 1590, 1590, 0},
        {"BROWSER_CMP_STOP_6", 1830, 1830, 1}
      ]
    })

    comparison_pattern.(comparison_route.route_id, %{
      direction_id: 0,
      route_pattern_id: "BROWSER-CMP-LOOP",
      route_pattern_name: "Browser Compare Loop",
      route_pattern_sort_order: 4,
      route_pattern_typicality: 1,
      timing_name: "Weekday base",
      stops: [
        {"BROWSER_CMP_STOP_1", 0, 0, 1},
        {"BROWSER_CMP_STOP_2", 240, 240, 0},
        {"BROWSER_CMP_STOP_3", 480, 480, 0},
        {"BROWSER_CMP_STOP_4", 720, 720, 1},
        {"BROWSER_CMP_STOP_1", 960, 960, 0},
        {"BROWSER_CMP_STOP_2", 1200, 1200, 1}
      ]
    })

    comparison_pattern.(comparison_route.route_id, %{
      direction_id: 0,
      route_pattern_id: "BROWSER-CMP-MOVED",
      route_pattern_name: "Browser Compare Moved",
      route_pattern_sort_order: 5,
      route_pattern_typicality: 1,
      timing_name: "Weekday base",
      stops: [
        {"BROWSER_CMP_STOP_1", 0, 0, 1},
        {"BROWSER_CMP_STOP_3", 240, 240, 0},
        {"BROWSER_CMP_STOP_2", 480, 480, 0},
        {"BROWSER_CMP_STOP_4", 720, 720, 1},
        {"BROWSER_CMP_STOP_5", 1020, 1020, 0},
        {"BROWSER_CMP_STOP_6", 1260, 1260, 1}
      ]
    })

    comparison_pattern.(comparison_route.route_id, %{
      direction_id: 1,
      route_pattern_id: "BROWSER-CMP-BACK",
      route_pattern_name: "Browser Compare Back",
      route_pattern_sort_order: 1,
      route_pattern_typicality: 1,
      timing_name: "Weekday base",
      stops: [
        {"BROWSER_CMP_STOP_6", 0, 0, 1},
        {"BROWSER_CMP_STOP_5", 240, 240, 0},
        {"BROWSER_CMP_STOP_4", 480, 480, 0},
        {"BROWSER_CMP_STOP_3", 720, 720, 1},
        {"BROWSER_CMP_STOP_2", 960, 960, 0},
        {"BROWSER_CMP_STOP_1", 1200, 1200, 1}
      ]
    })

    comparison_pattern.(comparison_other_route.route_id, %{
      direction_id: 0,
      route_pattern_id: "BROWSER-CMP-OTHER",
      route_pattern_name: "Browser Compare Other",
      route_pattern_sort_order: 1,
      route_pattern_typicality: 1,
      timing_name: "Weekday base",
      stops: [
        {"BROWSER_CMP_STOP_1", 0, 0, 1},
        {"BROWSER_CMP_OTHER_STOP", 300, 300, 0},
        {"BROWSER_CMP_STOP_5", 600, 600, 1}
      ]
    })

    comparison_today = Gtfs.DisplayClock.today(org.id, diagram_version.id).date

    GtfsPlanner.GtfsFixtures.calendar_fixture(org.id, diagram_version.id, %{
      service_id: "BROWSER_CMP_WEEKDAY",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: Date.add(comparison_today, -30),
      end_date: Date.add(comparison_today, 30)
    })

    GtfsPlanner.GtfsFixtures.calendar_attribute_fixture(org.id, diagram_version.id, %{
      service_id: "BROWSER_CMP_WEEKDAY",
      service_description: "Weekday",
      service_schedule_name: "Weekday",
      service_schedule_type: "Weekday",
      service_schedule_typicality: 1
    })

    # Two linked trips make FULL the route's busiest pattern, so the entry
    # default opens FULL against SHORT on the Weekday calendar; SHORT's single
    # trip gives its side a count in the calendar select.
    Enum.each(
      [
        {"BROWSER_CMP_T1", comparison_full, "06:00:00"},
        {"BROWSER_CMP_T2", comparison_full, "07:00:00"},
        {"BROWSER_CMP_T3", comparison_short, "06:30:00"}
      ],
      fn {trip_id, pattern, start_time} ->
        GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
          org.id,
          diagram_version.id,
          comparison_route.route_id,
          pattern,
          %{
            service_id: "BROWSER_CMP_WEEKDAY",
            trip_id: trip_id,
            start_time: start_time,
            trip_headsign: "Browser Compare"
          }
        )
      end
    )

    IO.puts(
      "Browser seed: pattern comparison routes (FULL with a 60 s wait, short turn, " <>
        "loop, moved, reverse direction, cross-route picker, weekday trips)"
    )

    # ── Route lifecycle deletion fixtures (spec 16 step 29) ──
    #
    # Two isolated routes give the reviewed-deletion journeys their own
    # records: BROWSER_ROUTE16_DELETE carries two trips with stop times so the
    # complete review has real counts to disclose, and BROWSER_ROUTE16_EMPTY is
    # an empty entire plan for the simple confirmation. Deleting them is the
    # journey's real mutation; reseeding the lane restores them.
    lifecycle_routes =
      [
        {"BROWSER_ROUTE16_DELETE", "D16", "Browser Route16 Delete"},
        {"BROWSER_ROUTE16_EMPTY", "E16", "Browser Route16 Empty"}
      ]
      |> Enum.map(fn {route_id, short_name, long_name} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3
          })

        route
      end)
      |> Map.new(&{&1.route_id, &1})

    lifecycle_delete_route = Map.fetch!(lifecycle_routes, "BROWSER_ROUTE16_DELETE")

    Enum.each(["BROWSER_D16A", "BROWSER_D16B"], fn trip_id ->
      {:ok, trip} =
        GtfsPlanner.GtfsFixtures.insert_trip(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: lifecycle_delete_route.route_id,
          trip_id: trip_id,
          service_id: "BROWSER_D16_SERVICE",
          trip_headsign: "Valley Hospital",
          direction_id: 0
        })

      [first, second] = Enum.take(pattern_stops, 2)

      Enum.each([{first, 1}, {second, 2}], fn {stop, sequence} ->
        {:ok, _stop_time} =
          GtfsPlanner.GtfsFixtures.insert_stop_time(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            trip_id: trip.trip_id,
            stop_id: stop.stop_id,
            stop_sequence: sequence,
            arrival_time: "09:0#{sequence}:00",
            departure_time: "09:0#{sequence}:00"
          })
      end)
    end)

    IO.puts("Browser seed: route lifecycle deletion routes (delete with 2 trips, empty)")

    # ── Route with unlocated stops (spec 16, AC-20 boarding advisory) ──
    #
    # BROWSER_ROUTE16_UNLOCATED's one pattern visits two stops stored without
    # coordinates, so its connector section is known missing
    # (`patterns_missing` is 1) while the route draws nothing on the map. The
    # advisory's positive path needs such a route; BROWSER_PATTERNS_READY, whose
    # stops all carry coordinates, is its "no warning" control.
    {:ok, _unlocated_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_ROUTE16_UNLOCATED",
        route_short_name: "U16",
        route_long_name: "Browser Route16 Unlocated",
        route_type: 3
      })

    unlocated_pattern =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: "BROWSER_ROUTE16_UNLOCATED",
        route_pattern_id: "BROWSER-U16-P1",
        route_pattern_name: "U16 Local",
        direction_id: 0
      })

    Enum.each(1..2, fn position ->
      {:ok, stop} =
        GtfsPlanner.GtfsFixtures.insert_stop(%{
          stop_id: "BROWSER_ROUTE16_NOCOORD_#{position}",
          stop_name: "Unlocated Stop #{position}",
          location_type: 0,
          organization_id: org.id,
          gtfs_version_id: diagram_version.id
        })

      GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(
        unlocated_pattern,
        stop.stop_id,
        position
      )
    end)

    IO.puts("Browser seed: route with a pattern over stops stored without coordinates")

    # ── Route lifecycle browser workflow fixtures (spec 16 step 33) ──
    #
    # BROWSER_ROUTE16_FLOW gives the composed stale-review and denial journeys
    # their own record with real counts to disclose: one pattern (two stops),
    # one linked trip and its stop times; its own journey deletes it.
    # BROWSER_ROUTE16_INACTIVE is explicitly active: false with the same shape
    # and is never mutated, so the export journeys can prove the archive
    # excludes an unrelated inactive route in every snapshot while a
    # reactivated route returns. Reseeding the lane restores both.
    Enum.each(
      [
        {"BROWSER_ROUTE16_FLOW", "F16", "Browser Route16 Flow", true},
        {"BROWSER_ROUTE16_INACTIVE", "I16", "Browser Route16 Inactive", false}
      ],
      fn {route_id, short_name, long_name, active} ->
        {:ok, _route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3,
            active: active
          })

        pattern =
          GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
            route_id: route_id,
            route_pattern_id: "BROWSER-#{short_name}-P1",
            route_pattern_name: "#{short_name} Local",
            direction_id: 0
          })

        [first_stop, second_stop] = Enum.take(pattern_stops, 2)

        first_occurrence =
          GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(pattern, first_stop.stop_id, 1)

        second_occurrence =
          GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(pattern, second_stop.stop_id, 2)

        timing = GtfsPlanner.GtfsFixtures.timed_pattern_fixture(pattern, %{name: "Weekday"})

        GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(timing, first_occurrence, %{
          arrival_offset: 0,
          departure_offset: 0
        })

        GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(timing, second_occurrence, %{
          arrival_offset: 0,
          departure_offset: 240
        })

        {:ok, trip} =
          GtfsPlanner.GtfsFixtures.insert_trip(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            route_id: route_id,
            trip_id: "BROWSER_#{short_name}_T1",
            service_id: "BROWSER_PATTERN_SERVICE",
            trip_headsign: "Valley Hospital",
            direction_id: 0
          })

        GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(trip, %{
          route_pattern_id: "BROWSER-#{short_name}-P1",
          timed_pattern_id: timing.id,
          pattern_derivation_state: "linked"
        })

        Enum.each([{first_stop, 1}, {second_stop, 2}], fn {stop, sequence} ->
          {:ok, _stop_time} =
            GtfsPlanner.GtfsFixtures.insert_stop_time(%{
              organization_id: org.id,
              gtfs_version_id: diagram_version.id,
              trip_id: trip.trip_id,
              stop_id: stop.stop_id,
              stop_sequence: sequence,
              arrival_time: "10:0#{sequence}:00",
              departure_time: "10:0#{sequence}:00"
            })
        end)
      end
    )

    IO.puts(
      "Browser seed: route lifecycle workflow routes (flow with 1 pattern + 1 trip, inactive twin)"
    )

    # An organization admin beside the editor in Browser Test Org, so the
    # membership-removal denial journey can revoke and restore editor access
    # through the real /users admin surface instead of a fixture backdoor.
    {:ok, workflow_admin} =
      Accounts.register_user(%{
        email: "route16-admin@gtfs-planner.test",
        password: "route16-admin-browser-pass"
      })

    Repo.update!(User.confirm_changeset(workflow_admin))

    {:ok, _workflow_admin_membership} =
      Accounts.create_user_org_membership(%{
        user_id: workflow_admin.id,
        organization_id: org.id,
        roles: ["pathways_studio_admin"]
      })

    IO.puts("Browser seed: route16 workflow admin #{workflow_admin.email} in #{org.name}")

    seed_pattern_trip_times = fn trip_id ->
      [
        {"BROWSER_PATTERN_STOP_1", "08:00:00", "08:00:00"},
        {"BROWSER_PATTERN_STOP_2", "08:04:00", "08:05:00"},
        {"BROWSER_PATTERN_STOP_3", "08:10:00", "08:11:00"}
      ]
      |> Enum.with_index(1)
      |> Enum.each(fn {{stop_id, arrival, departure}, sequence} ->
        {:ok, _stop_time} =
          GtfsPlanner.GtfsFixtures.insert_stop_time(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            trip_id: trip_id,
            stop_id: stop_id,
            stop_sequence: sequence,
            arrival_time: arrival,
            departure_time: departure
          })
      end)
    end

    # ── Route pattern editing fixtures ──
    #
    # Four isolated routes give the mutate/review/apply journeys their own
    # records: a used pattern with a linked trip and two timings, an unused
    # pattern for copy and reorder, a custom-trip pattern for the blocked
    # states, and an unused pattern for a successful deletion. They reuse the
    # version's four pattern stops and never touch the read-only catalog or
    # pattern-list records.
    editing_routes =
      [
        {"BROWSER_PATTERNS_EDIT_USED", "PEU", "Browser Pattern Used"},
        {"BROWSER_PATTERNS_EDIT_UNUSED", "PED", "Browser Pattern Unused"},
        {"BROWSER_PATTERNS_EDIT_CUSTOM", "PEC", "Browser Pattern Custom"},
        {"BROWSER_PATTERNS_EDIT_DELETE", "PEL", "Browser Pattern Delete"},
        {"BROWSER_PATTERNS_EDIT_USED_B", "PEV", "Browser Pattern Used Second"},
        {"BROWSER_PATTERNS_EDIT_STALE", "PES", "Browser Pattern Stale"},
        {"BROWSER_PATTERNS_EDIT_EXPORT", "PEX", "Browser Pattern Export"},
        {"BROWSER_PATTERNS_EDIT_EXPORT_B", "PEY", "Browser Pattern Export Second"},
        {"BROWSER_PATTERNS_EDIT_TERMINAL", "PET", "Browser Pattern Terminal"}
      ]
      |> Enum.map(fn {route_id, short_name, long_name} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3
          })

        route
      end)
      |> Map.new(&{&1.route_id, &1})

    editing_pattern = fn route, pattern_id, attrs ->
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(
        org.id,
        diagram_version.id,
        Map.merge(
          %{
            route_id: route.route_id,
            route_pattern_id: pattern_id,
            route_pattern_name: pattern_id,
            direction_id: 0
          },
          Map.new(attrs)
        )
      )
    end

    used_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_USED")

    used_pattern =
      editing_pattern.(used_route, "BROWSER-EDIT-USED",
        route_pattern_name: "Browser Editing Used",
        direction_id: 0,
        route_pattern_time_desc: "All day",
        route_pattern_typicality: 1
      )

    timing_with_offsets = fn route_pattern, name, occurrences, offsets ->
      timing = GtfsPlanner.GtfsFixtures.timed_pattern_fixture(route_pattern, %{name: name})

      occurrences
      |> Enum.zip(offsets)
      |> Enum.each(fn {occurrence, {arrival, departure}} ->
        GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(timing, occurrence, %{
          arrival_offset: arrival,
          departure_offset: departure
        })
      end)

      timing
    end

    used_occurrences = occurrence_fixture.(used_pattern, Enum.take(pattern_stops, 3))

    used_timing =
      timing_with_offsets.(used_pattern, "Weekday", used_occurrences, [
        {0, 0},
        {240, 300},
        {600, 660}
      ])

    timing_fixture.(used_pattern, "Weekend", used_occurrences)

    {:ok, used_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: used_route.route_id,
        trip_id: "BROWSER_EDIT_T1",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Valley Hospital",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(used_trip, %{
      route_pattern_id: "BROWSER-EDIT-USED",
      timed_pattern_id: used_timing.id,
      pattern_derivation_state: "linked"
    })

    seed_pattern_trip_times.("BROWSER_EDIT_T1")

    unused_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_UNUSED")

    unused_edit_pattern =
      editing_pattern.(unused_route, "BROWSER-EDIT-UNUSED",
        route_pattern_name: "Browser Editing Unused",
        direction_id: 1
      )

    unused_edit_occurrences =
      occurrence_fixture.(unused_edit_pattern, Enum.take(pattern_stops, 3))

    timing_fixture.(unused_edit_pattern, "Timing A", unused_edit_occurrences)

    custom_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_CUSTOM")

    custom_pattern =
      editing_pattern.(custom_route, "BROWSER-EDIT-CUSTOM",
        route_pattern_name: "Browser Editing Custom",
        direction_id: 0
      )

    custom_occurrences = occurrence_fixture.(custom_pattern, Enum.take(pattern_stops, 3))
    _custom_timing = timing_fixture.(custom_pattern, "All day", custom_occurrences)

    {:ok, custom_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: custom_route.route_id,
        trip_id: "BROWSER_EDIT_C1",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Valley Hospital",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(custom_trip, %{
      route_pattern_id: "BROWSER-EDIT-CUSTOM",
      timed_pattern_id: nil,
      pattern_derivation_state: "custom",
      pattern_derivation_reason: "missing_times"
    })

    # A second used pattern and a second deletable pattern, so each viewport's
    # journey starts from its own unmodified records.
    used_b_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_USED_B")

    used_b_pattern =
      editing_pattern.(used_b_route, "BROWSER-EDIT-USED-B",
        route_pattern_name: "Browser Editing Used Second",
        direction_id: 0
      )

    used_b_occurrences = occurrence_fixture.(used_b_pattern, Enum.take(pattern_stops, 3))

    used_b_timing =
      timing_with_offsets.(used_b_pattern, "Weekday", used_b_occurrences, [
        {0, 0},
        {240, 300},
        {600, 660}
      ])

    timing_fixture.(used_b_pattern, "Weekend", used_b_occurrences)

    {:ok, used_b_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: used_b_route.route_id,
        trip_id: "BROWSER_EDIT_TB1",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Valley Hospital",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(used_b_trip, %{
      route_pattern_id: "BROWSER-EDIT-USED-B",
      timed_pattern_id: used_b_timing.id,
      pattern_derivation_state: "linked"
    })

    seed_pattern_trip_times.("BROWSER_EDIT_TB1")

    # Two more linked patterns: one for the second-session stale review and one
    # whose timing save is asserted through a real downloaded export.
    stale_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_STALE")

    stale_pattern =
      editing_pattern.(stale_route, "BROWSER-EDIT-STALE",
        route_pattern_name: "Browser Editing Stale",
        direction_id: 0
      )

    stale_occurrences = occurrence_fixture.(stale_pattern, Enum.take(pattern_stops, 3))
    stale_timing = timing_fixture.(stale_pattern, "Weekday", stale_occurrences)

    {:ok, stale_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: stale_route.route_id,
        trip_id: "BROWSER_STALE_T1",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Valley Hospital",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(stale_trip, %{
      route_pattern_id: "BROWSER-EDIT-STALE",
      timed_pattern_id: stale_timing.id,
      pattern_derivation_state: "linked"
    })

    seed_pattern_trip_times.("BROWSER_STALE_T1")

    export_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_EXPORT")

    export_pattern =
      editing_pattern.(export_route, "BROWSER-EDIT-EXPORT",
        route_pattern_name: "Browser Editing Export",
        direction_id: 0
      )

    export_occurrences = occurrence_fixture.(export_pattern, Enum.take(pattern_stops, 3))

    export_timing =
      timing_with_offsets.(export_pattern, "Weekday", export_occurrences, [
        {0, 0},
        {240, 300},
        {600, 660}
      ])

    {:ok, export_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: export_route.route_id,
        trip_id: "BROWSER_EXPORT_T1",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Valley Hospital",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(export_trip, %{
      route_pattern_id: "BROWSER-EDIT-EXPORT",
      timed_pattern_id: export_timing.id,
      pattern_derivation_state: "linked"
    })

    seed_pattern_trip_times.("BROWSER_EXPORT_T1")

    # A second used pattern, so each viewport's timing journey starts from its
    # own unmodified records.
    export_b_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_EXPORT_B")

    export_b_pattern =
      editing_pattern.(export_b_route, "BROWSER-EDIT-EXPORT-B",
        route_pattern_name: "Browser Editing Export Second",
        direction_id: 0
      )

    export_b_occurrences = occurrence_fixture.(export_b_pattern, Enum.take(pattern_stops, 3))

    export_b_timing =
      timing_with_offsets.(export_b_pattern, "Weekday", export_b_occurrences, [
        {0, 0},
        {240, 300},
        {600, 660}
      ])

    {:ok, export_b_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: export_b_route.route_id,
        trip_id: "BROWSER_EXPORT_T1_B",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Valley Hospital",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(export_b_trip, %{
      route_pattern_id: "BROWSER-EDIT-EXPORT-B",
      timed_pattern_id: export_b_timing.id,
      pattern_derivation_state: "linked"
    })

    seed_pattern_trip_times.("BROWSER_EXPORT_T1_B")

    delete_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_DELETE")

    delete_pattern =
      editing_pattern.(delete_route, "BROWSER-EDIT-DELETE",
        route_pattern_name: "Browser Editing Delete",
        direction_id: 0
      )

    delete_occurrences = occurrence_fixture.(delete_pattern, Enum.take(pattern_stops, 2))
    timing_fixture.(delete_pattern, "Timing A", delete_occurrences)

    delete_b_pattern =
      editing_pattern.(delete_route, "BROWSER-EDIT-DELETE-B",
        route_pattern_name: "Browser Editing Delete Second",
        direction_id: 0
      )

    delete_b_occurrences = occurrence_fixture.(delete_b_pattern, Enum.take(pattern_stops, 2))
    timing_fixture.(delete_b_pattern, "Timing A", delete_b_occurrences)

    # A dedicated used pattern for the terminal-insertion journey: appending a
    # stop after the last occurrence has no bracketing time, so the editor has to
    # collect explicit arrival/departure values before it can propose anything.
    terminal_route = Map.fetch!(editing_routes, "BROWSER_PATTERNS_EDIT_TERMINAL")

    terminal_pattern =
      editing_pattern.(terminal_route, "BROWSER-EDIT-TERMINAL",
        route_pattern_name: "Browser Editing Terminal",
        direction_id: 0
      )

    terminal_occurrences = occurrence_fixture.(terminal_pattern, Enum.take(pattern_stops, 3))

    terminal_timing =
      timing_with_offsets.(terminal_pattern, "Weekday", terminal_occurrences, [
        {0, 0},
        {240, 300},
        {600, 660}
      ])

    {:ok, terminal_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: terminal_route.route_id,
        trip_id: "BROWSER_TERMINAL_T1",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Valley Hospital",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(terminal_trip, %{
      route_pattern_id: "BROWSER-EDIT-TERMINAL",
      timed_pattern_id: terminal_timing.id,
      pattern_derivation_state: "linked"
    })

    seed_pattern_trip_times.("BROWSER_TERMINAL_T1")

    IO.puts("Browser seed: route pattern editing routes (used, unused, custom, deletable)")

    # ── Headsign propagation fixtures ──
    #
    # One route with a pattern per browser journey (BROWSER-HS1…HS5) and a
    # continuation route for their interlined trips, all inside the existing
    # Browser E2E version: a newer published_at would become the default
    # version. Every pattern carries the same shape so each journey starts
    # from the same usage picture — pattern headsign "Lincoln City", one
    # "Weekday base" timing whose stop 3 shows its own stop headsign, and five
    # linked trips: three "Lincoln City", one "Lincoln city" (the likely
    # typo), and one "Roads End via Lincoln City" whose block continues on a
    # BROWSER_HEADSIGNS_20 trip. Journeys mutate different patterns, so no
    # test inherits another's writes.
    {:ok, headsign_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_HEADSIGNS",
        route_short_name: "HS",
        route_long_name: "Browser Headsign",
        route_type: 3
      })

    {:ok, headsign_route_20} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_HEADSIGNS_20",
        route_short_name: "H20",
        route_long_name: "Browser Headsign Continuation",
        route_type: 3
      })

    # Every trip below runs on BROWSER_PATTERN_SERVICE, so the Schedules scope
    # bar needs a matching calendar row; without one the page can only resolve a
    # calendar that has no trips on this route.
    GtfsPlanner.GtfsFixtures.calendar_fixture(org.id, diagram_version.id, %{
      service_id: "BROWSER_PATTERN_SERVICE",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1
    })

    headsign_pattern = fn pattern_id, pattern_name, route ->
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: route.route_id,
        route_pattern_id: pattern_id,
        route_pattern_name: pattern_name,
        headsign: "Lincoln City",
        direction_id: 0
      })
    end

    headsign_timing = fn pattern, timing_headsign ->
      timing =
        GtfsPlanner.GtfsFixtures.timed_pattern_fixture(pattern, %{
          name: "Weekday base",
          headsign: timing_headsign
        })

      occurrences = occurrence_fixture.(pattern, pattern_stops)

      arrival_offsets = [0, 4, 10, 14]
      departure_offsets = [0, 5, 11, 15]

      occurrences
      |> Enum.with_index(1)
      |> Enum.each(fn {occurrence, position} ->
        GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(timing, occurrence, %{
          arrival_offset: Enum.at(arrival_offsets, position - 1),
          departure_offset: Enum.at(departure_offsets, position - 1),
          stop_headsign: if(position == 3, do: "Lincoln City Transit Center", else: nil)
        })
      end)

      timing
    end

    hs_clock = fn minute ->
      hour = minute |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
      padded_minute = minute |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
      "#{hour}:#{padded_minute}:00"
    end

    hs_seed_trip_times = fn trip_id, start_minute ->
      [0, 5, 11, 15]
      |> Enum.with_index(1)
      |> Enum.each(fn {offset, sequence} ->
        {:ok, _stop_time} =
          GtfsPlanner.GtfsFixtures.insert_stop_time(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            trip_id: trip_id,
            stop_id: "BROWSER_PATTERN_STOP_#{sequence}",
            stop_sequence: sequence,
            arrival_time: hs_clock.(start_minute + offset),
            departure_time: hs_clock.(start_minute + offset)
          })
      end)
    end

    hs_trip = fn trip_id, route, pattern, timing, start_minute, headsign, block_id ->
      {:ok, trip} =
        GtfsPlanner.GtfsFixtures.insert_trip(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: route.route_id,
          trip_id: trip_id,
          service_id: "BROWSER_PATTERN_SERVICE",
          trip_headsign: headsign,
          block_id: block_id,
          direction_id: 0
        })

      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: pattern.route_pattern_id,
        timed_pattern_id: timing.id,
        pattern_derivation_state: "linked"
      })

      hs_seed_trip_times.(trip_id, start_minute)

      trip
    end

    continuation_pattern =
      headsign_pattern.("BROWSER-HS20", "Browser Headsign Continuation", headsign_route_20)

    continuation_timing = headsign_timing.(continuation_pattern, "Roads End")

    pattern_names = %{
      1 => "Browser Headsign One",
      2 => "Browser Headsign Two",
      3 => "Browser Headsign Three",
      4 => "Browser Headsign Four",
      5 => "Browser Headsign Five"
    }

    Enum.each(1..5, fn n ->
      pattern = headsign_pattern.("BROWSER-HS#{n}", Map.fetch!(pattern_names, n), headsign_route)
      timing = headsign_timing.(pattern, nil)

      hs_trip.("BROWSER_HS#{n}_T1", headsign_route, pattern, timing, 480, "Lincoln City", nil)
      hs_trip.("BROWSER_HS#{n}_T2", headsign_route, pattern, timing, 510, "Lincoln City", nil)
      hs_trip.("BROWSER_HS#{n}_T3", headsign_route, pattern, timing, 540, "Lincoln City", nil)
      hs_trip.("BROWSER_HS#{n}_T4", headsign_route, pattern, timing, 560, "Lincoln city", nil)

      hs_trip.(
        "BROWSER_HS#{n}_T5",
        headsign_route,
        pattern,
        timing,
        580,
        "Roads End via Lincoln City",
        "BROWSER_HS#{n}_BLOCK"
      )

      hs_trip.(
        "BROWSER_HS20_T#{n}",
        headsign_route_20,
        continuation_pattern,
        continuation_timing,
        600 + n * 15,
        "Roads End",
        "BROWSER_HS#{n}_BLOCK"
      )
    end)

    IO.puts(
      "Browser seed: headsign propagation routes (patterns BROWSER-HS1..HS5 plus BROWSER_HEADSIGNS_20 continuations)"
    )

    # ── Auth fixtures for authentication.spec.js (Package 10) ──
    #
    # Deterministic, test-only token fixtures. Each raw value is a fixed
    # 32-byte binary; only its SHA-256 digest is persisted (production-shaped
    # `%UserToken{token: <digest>}`), and the unpadded URL-safe Base64 of the
    # raw value is mirrored verbatim in assets/e2e/authentication.spec.js so
    # token URLs are reproducible without parsing mail or passing seed output
    # between processes. One user/token per destructive case; expired rows are
    # backdated beyond their context validity window (reset_password 1 day,
    # confirm/invite 7 days). The replay cases reuse the valid token URL after
    # the valid case consumes it, proving one-use semantics.
    auth_insert_token = fn user, context, encoded, backdate ->
      raw = Base.url_decode64!(encoded, padding: false)
      digest = :crypto.hash(:sha256, raw)

      token =
        Repo.insert!(%UserToken{
          token: digest,
          context: context,
          sent_to: user.email,
          user_id: user.id
        })

      if backdate do
        # update_all bypasses timestamp autogenerate so the expired row keeps
        # its deterministic past inserted_at.
        {1, _} =
          from(t in GtfsPlanner.Accounts.UserToken, where: t.id == ^token.id)
          |> Repo.update_all(set: [inserted_at: backdate])
      end

      token
    end

    auth_now = DateTime.utc_now()
    # Beyond the 1-day reset_password window.
    auth_expired_reset = DateTime.add(auth_now, -2, :day)
    # Beyond the 7-day confirm/invite window.
    auth_expired_week = DateTime.add(auth_now, -8, :day)

    # Login recovery: deactivated member (valid credentials, deactivated membership).
    {:ok, auth_deactivated} =
      Accounts.register_user(%{
        email: "auth-deactivated@gtfs-planner.test",
        password: "AuthDeactivated123!"
      })

    Repo.update!(User.confirm_changeset(auth_deactivated))

    {:ok, _auth_deactivated_membership} =
      Accounts.create_user_org_membership(%{
        user_id: auth_deactivated.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    {:ok, _} = Organizations.deactivate_user_in_organization(user, auth_deactivated.id, org.id)
    IO.puts("Browser seed: auth deactivated user #{auth_deactivated.email}")

    # Login recovery: confirmed user with no organization membership.
    {:ok, auth_noorg} =
      Accounts.register_user(%{
        email: "auth-noorg@gtfs-planner.test",
        password: "AuthNoOrg123!"
      })

    Repo.update!(User.confirm_changeset(auth_noorg))
    IO.puts("Browser seed: auth no-org user #{auth_noorg.email}")

    # Reset password: valid (consumed by the success case, replayed after).
    {:ok, auth_reset} =
      Accounts.register_user(%{
        email: "auth-reset@gtfs-planner.test",
        password: "AuthReset123!"
      })

    Repo.update!(User.confirm_changeset(auth_reset))

    auth_insert_token.(
      auth_reset,
      "reset_password",
      "YXV0aC1yZXNldC12YWxpZDAwMDAwMDAwMDAwMDAwMDA",
      nil
    )

    IO.puts("Browser seed: auth reset user #{auth_reset.email}")

    # Reset password: expired token (backdated beyond the 1-day window).
    {:ok, auth_reset_expired} =
      Accounts.register_user(%{
        email: "auth-reset-expired@gtfs-planner.test",
        password: "AuthResetExpired123!"
      })

    Repo.update!(User.confirm_changeset(auth_reset_expired))

    auth_insert_token.(
      auth_reset_expired,
      "reset_password",
      "YXV0aC1yZXNldC1leHBpcmVkMDAwMDAwMDAwMDAwMDA",
      auth_expired_reset
    )

    IO.puts("Browser seed: auth reset-expired user #{auth_reset_expired.email}")

    # Confirmation: valid (unconfirmed user; consumed by the success case, replayed after).
    {:ok, auth_confirm} =
      Accounts.register_user(%{
        email: "auth-confirm@gtfs-planner.test",
        password: "AuthConfirm123!"
      })

    auth_insert_token.(
      auth_confirm,
      "confirm",
      "YXV0aC1jb25maXJtLXZhbGlkMDAwMDAwMDAwMDAwMDA",
      nil
    )

    IO.puts("Browser seed: auth confirm user #{auth_confirm.email}")

    # Confirmation: expired token (backdated beyond the 7-day window).
    {:ok, auth_confirm_expired} =
      Accounts.register_user(%{
        email: "auth-confirm-expired@gtfs-planner.test",
        password: "AuthConfirmExpired123!"
      })

    auth_insert_token.(
      auth_confirm_expired,
      "confirm",
      "YXV0aC1jb25maXJtLWV4cGlyZWQwMDAwMDAwMDAwMDA",
      auth_expired_week
    )

    IO.puts("Browser seed: auth confirm-expired user #{auth_confirm_expired.email}")

    # Invitation: valid (invited user without a password; consumed, then replayed).
    {:ok, auth_invite} =
      %User{}
      |> User.invite_changeset(%{email: "auth-invite@gtfs-planner.test"})
      |> Repo.insert()

    auth_insert_token.(auth_invite, "invite", "YXV0aC1pbnZpdGUtdmFsaWQwMDAwMDAwMDAwMDAwMDA", nil)
    IO.puts("Browser seed: auth invite user #{auth_invite.email}")

    # Invitation: expired token (backdated beyond the 7-day window).
    {:ok, auth_invite_expired} =
      %User{}
      |> User.invite_changeset(%{email: "auth-invite-expired@gtfs-planner.test"})
      |> Repo.insert()

    auth_insert_token.(
      auth_invite_expired,
      "invite",
      "YXV0aC1pbnZpdGUtZXhwaXJlZDAwMDAwMDAwMDAwMDA",
      auth_expired_week
    )

    IO.puts("Browser seed: auth invite-expired user #{auth_invite_expired.email}")

    # ── Administration design-contract fixtures (admin_design_contracts.spec.js) ──
    #
    # A dedicated organization keeps every administration mutation away from the
    # organizations used by the other browser specs. The administrator below holds
    # only `pathways_studio_admin`, so `AssignOrganization` resolves this
    # organization from the session (the system-`administrator` org-skip does not
    # apply) and `/admin/users` is scoped to it.
    {:ok, admin_org} =
      Organizations.create_organization_unchecked(%{
        name: "Admin Contracts Org",
        alias: "admin-contracts"
      })

    {:ok, org_admin} =
      Accounts.register_user(%{
        email: "admin-contracts@gtfs-planner.test",
        password: "AdminContracts123!"
      })

    Repo.update!(User.confirm_changeset(org_admin))

    {:ok, _org_admin_membership} =
      Accounts.create_user_org_membership(%{
        user_id: org_admin.id,
        organization_id: admin_org.id,
        roles: ["pathways_studio_admin"]
      })

    IO.puts("Browser seed: created organization admin #{org_admin.email} (id=#{org_admin.id})")

    # An accepted member has a password. `Admin.Components.member_status/1` derives
    # "Invitation pending" from a nil `hashed_password`, so accepted fixtures must
    # be registered and pending fixtures must go through `User.invite_changeset/2`.
    add_accepted_member = fn email, roles ->
      {:ok, member} = Accounts.register_user(%{email: email, password: "ContractsMember123!"})
      Repo.update!(User.confirm_changeset(member))

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: member.id,
          organization_id: admin_org.id,
          roles: roles
        })

      member
    end

    _active_member =
      add_accepted_member.("contracts-active@gtfs-planner.test", ["pathways_studio_editor"])

    _multi_role_member =
      add_accepted_member.("contracts-multirole@gtfs-planner.test", [
        "pathways_studio_admin",
        "pathways_studio_editor"
      ])

    # Long local part and long domain, for reflow and target-size measurement.
    _long_email_member =
      add_accepted_member.(
        "contracts-very-long-email-address-for-responsive-verification@long-domain-name-for-administration.gtfs-planner.test",
        ["pathways_studio_editor"]
      )

    # Dedicated destructive target: the deactivation-confirmation workflow owns
    # this row and restores it, so the file stays re-runnable.
    _deactivation_target =
      add_accepted_member.("contracts-deactivate-target@gtfs-planner.test", [
        "pathways_studio_editor"
      ])

    # Already deactivated, so the "Activate user" row action is present on load.
    deactivated_member =
      add_accepted_member.("contracts-deactivated@gtfs-planner.test", ["pathways_studio_editor"])

    {:ok, _deactivated_membership} =
      Organizations.deactivate_user_in_organization(
        org_admin,
        deactivated_member.id,
        admin_org.id
      )

    # Invitation pending: `User.invite_changeset/2` sets no password, so the row
    # renders "Invitation pending" and offers "Resend invite".
    {:ok, pending_member} =
      %User{}
      |> User.invite_changeset(%{email: "contracts-pending@gtfs-planner.test"})
      |> Repo.insert()

    {:ok, _pending_membership} =
      Accounts.create_user_org_membership(%{
        user_id: pending_member.id,
        organization_id: admin_org.id,
        roles: ["pathways_studio_editor"]
      })

    IO.puts(
      "Browser seed: administration fixtures in #{admin_org.name} (id=#{admin_org.id}) — " <>
        "active, multi-role, long-email, deactivate-target, deactivated, invitation-pending"
    )

    # ── Pathways branding fixtures (product_branding.spec.js) ──
    #
    # A Pathways-product organization so the header shows the Pathways Studio
    # logo and the hidden task links are absent. Versions are per organization,
    # so this version cannot become Browser Test Org's latest.
    {:ok, pathways_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser Pathways Org",
        alias: "browser-pathways",
        product: :pathways
      })

    {:ok, _pathways_version} =
      Versions.create_gtfs_version(pathways_org.id, %{name: "Browser Pathways Version"})

    {:ok, pathways_editor} =
      Accounts.register_user(%{
        email: "pathways-editor@gtfs-planner.test",
        password: "PathwaysEditor123!"
      })

    Repo.update!(User.confirm_changeset(pathways_editor))

    {:ok, _pathways_membership} =
      Accounts.create_user_org_membership(%{
        user_id: pathways_editor.id,
        organization_id: pathways_org.id,
        roles: ["pathways_studio_editor", "pathways_studio_admin"]
      })

    IO.puts(
      "Browser seed: pathways editor #{pathways_editor.email} in #{pathways_org.name} " <>
        "(id=#{pathways_org.id})"
    )

    # ── Package 11 account design-contract fixtures (account_design_contracts.spec.js) ──
    #
    # Dedicated users/orgs keep dashboard branch baselines and settings mutations
    # away from diagram, auth, and administration suites. Credentials are test-only
    # and mirrored in the Playwright file; never placed in application config.
    #
    # create_organization seeds a published default version; no-version deletes it
    # and leaves staging-only so the published-only latest query returns nil.

    {:ok, no_version_org} =
      Organizations.create_organization_unchecked(%{
        name: "Account No Version Org",
        alias: "account-no-version"
      })

    GtfsPlanner.OrganizationsFixtures.delete_versions!(
      from(v in GtfsPlanner.Versions.GtfsVersion, where: v.organization_id == ^no_version_org.id)
    )

    {:ok, _no_version_staging} =
      Versions.create_staging_gtfs_version(no_version_org.id, %{name: "Staging Only"})

    {:ok, no_version_user} =
      Accounts.register_user(%{
        email: "account-no-version@gtfs-planner.test",
        password: "AccountNoVersion123!"
      })

    Repo.update!(User.confirm_changeset(no_version_user))

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: no_version_user.id,
        organization_id: no_version_org.id,
        roles: ["pathways_studio_editor"]
      })

    IO.puts(
      "Browser seed: account no-version user #{no_version_user.email} in #{no_version_org.name}"
    )

    {:ok, no_task_org} =
      Organizations.create_organization_unchecked(%{
        name: "Account No Task Org",
        alias: "account-no-task"
      })

    # Default published version remains so context is available with empty roles.
    {:ok, no_task_user} =
      Accounts.register_user(%{
        email: "account-no-task@gtfs-planner.test",
        password: "AccountNoTask123!"
      })

    Repo.update!(User.confirm_changeset(no_task_user))

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: no_task_user.id,
        organization_id: no_task_org.id,
        roles: []
      })

    IO.puts("Browser seed: account no-task user #{no_task_user.email} in #{no_task_org.name}")

    # Non-destructive settings user: email confirmation-sent and error recovery only.
    {:ok, settings_user} =
      Accounts.register_user(%{
        email: "account-settings@gtfs-planner.test",
        password: "AccountSettings123!"
      })

    Repo.update!(User.confirm_changeset(settings_user))

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: settings_user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    IO.puts("Browser seed: account settings user #{settings_user.email}")

    # One-use password mutation handoff. After a successful password change the
    # seed password is invalid until the next `bin/test-browser` run creates a new
    # database.
    {:ok, password_user} =
      Accounts.register_user(%{
        email: "account-password-mutate@gtfs-planner.test",
        password: "AccountPassword123!"
      })

    Repo.update!(User.confirm_changeset(password_user))

    {:ok, _} =
      Accounts.create_user_org_membership(%{
        user_id: password_user.id,
        organization_id: org.id,
        roles: ["pathways_studio_editor"]
      })

    IO.puts(
      "Browser seed: account password-mutation user #{password_user.email} (one-use per reset)"
    )

    # ── Catalog design-contract fixtures (catalog_design_contracts.spec.js) ──
    #
    # Deterministic stops, pathways, and versions that exercise the responsive
    # catalog contracts: long-value overflow, tri-state accessibility, pathway
    # metrics, and empty/partial catalog states.
    {:ok, _long_stop} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "VERY_LONG_STOP_ID_FOR_OVERFLOW_TESTING_12345",
        stop_name:
          "This Is A Very Long Station Name For Testing Overflow Behavior At Narrow Viewports",
        location_type: 1,
        wheelchair_boarding: 0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _missing_stop} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "CATALOG_MISSING_VALUES",
        stop_name: "Missing Values Stop",
        location_type: 0,
        wheelchair_boarding: 0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _accessible_stop} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "CATALOG_ACCESSIBLE",
        stop_name: "Direct Accessible Stop",
        location_type: 0,
        wheelchair_boarding: 1,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _not_accessible_stop} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "CATALOG_NOT_ACCESSIBLE",
        stop_name: "Direct Not Accessible Stop",
        location_type: 0,
        wheelchair_boarding: 2,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, inherited_station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "CATALOG_INHERITED_STATION",
        stop_name: "Inherited Accessibility Station",
        location_type: 1,
        wheelchair_boarding: 1,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _inherited_child} =
      Gtfs.import_create_stop(%{
        stop_id: "CATALOG_INHERITED_CHILD",
        stop_name: "Inherited Child Stop",
        location_type: 0,
        wheelchair_boarding: 0,
        parent_station: inherited_station.stop_id,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _no_data_stop} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "CATALOG_NO_DATA",
        stop_name: "No Data Stop",
        location_type: 0,
        wheelchair_boarding: 0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: tri-state accessibility stops for catalog contracts")

    {:ok, _pathway_station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "CATALOG_PATHWAY_STATION",
        stop_name: "Pathway Metrics Station",
        location_type: 1,
        wheelchair_boarding: 0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, pathway_to_a} =
      Gtfs.import_create_stop(%{
        stop_id: "CATALOG_PATHWAY_TO_A",
        stop_name: "Pathway Target A",
        location_type: 0,
        wheelchair_boarding: 0,
        parent_station: "CATALOG_PATHWAY_STATION",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, pathway_to_b} =
      Gtfs.import_create_stop(%{
        stop_id: "CATALOG_PATHWAY_TO_B",
        stop_name: "Pathway Target B",
        location_type: 0,
        wheelchair_boarding: 0,
        parent_station: "CATALOG_PATHWAY_STATION",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _full_pathway} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        pathway_id: "CATALOG_PW_FULL",
        pathway_mode: 2,
        is_bidirectional: false,
        stair_count: 24,
        length: Decimal.new("18.5"),
        traversal_time: 32,
        from_stop_id: "CATALOG_PATHWAY_STATION",
        to_stop_id: pathway_to_a.stop_id,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _partial_pathway} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        pathway_id: "CATALOG_PW_PARTIAL",
        pathway_mode: 1,
        is_bidirectional: true,
        length: Decimal.new("45.0"),
        from_stop_id: "CATALOG_PATHWAY_STATION",
        to_stop_id: pathway_to_b.stop_id,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: pathways with full and partial metrics for catalog contracts")

    {:ok, empty_version} =
      Versions.create_gtfs_version(org.id, %{name: "Catalog Empty Version"})

    IO.puts("Browser seed: empty catalog version #{empty_version.id} (no routes or stops)")

    {:ok, routes_only_version} =
      Versions.create_gtfs_version(org.id, %{name: "Catalog Routes Only Version"})

    {:ok, _routes_only_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: routes_only_version.id,
        route_id: "CATALOG_ROUTES_ONLY_1",
        route_short_name: "RO1",
        route_long_name: "Routes Only Route One",
        route_type: 3,
        route_color: "003366"
      })

    {:ok, current_export_run} =
      ExportRuns.create_pending(org.id, routes_only_version.id, export_actor, :full)

    {:ok, _claimed_current_export_run, current_export_generation, current_export_token} =
      ExportRuns.claim(org.id, current_export_run.id, :build)

    {:ok, current_export_artifact} =
      ArtifactStorage.publish(
        org.id,
        routes_only_version.id,
        current_export_run.id,
        "browser-current-export.zip",
        <<80, 75, 3, 4, 20, 0, 0, 0>>
      )

    {:ok, _warned_current_export} =
      ExportRuns.persist_warnings(
        org.id,
        current_export_run.id,
        current_export_generation,
        current_export_token,
        [
          %{
            code: "browser_preflight_warning",
            detail:
              "A deliberately long preflight diagnostic remains readable and wraps without creating horizontal overflow at narrow widths: " <>
                String.duplicate("route-reference-", 18)
          }
        ]
      )

    {:ok, _ready_current_export_run} =
      ExportRuns.mark_ready(
        org.id,
        current_export_run.id,
        current_export_generation,
        current_export_token,
        %{main: current_export_artifact, flex: nil}
      )

    IO.puts("Browser seed: routes-only version #{routes_only_version.id} with ready export")

    # ── Fare zones fixture versions ──
    #
    # Two published versions give the fare-zone workspace its data. "Browser
    # Fare Zones Version" is a small, hand-placed town whose literal
    # coordinates are load-bearing: eight boardable stops west of -71.10 (zone
    # A Central), twelve east of -71.008 (zone B Eastbank), four unassigned
    # stops, one boardable stop with no coordinates in Central, a station in
    # Central with two located platforms carrying its zone, and the
    # declared-but-empty D Airport. The box journey fits this map, drags over
    # its left half and expects exactly the eight west stops, so every other
    # point sits east of the fitted midpoint longitude.
    #
    # "Browser Fare Zones Scale Version" carries the 10,000 located boardable
    # stops AC-35 measures in the browser, in five zones, inserted in five
    # batches of 2,000.
    #
    # Zone metadata goes through `FareZones.create_zone/2` (CR-1 keeps that
    # module `fare_zones`' only writer) and the route through
    # `GtfsPlanner.GtfsFixtures.insert_route/1`. Stop, fare and rule rows are fixture data inserted
    # directly: no changeset casts `stops.zone_id`, and `FareRule.changeset/2`
    # would trim the exact rule values. Every row carries one fixed seed
    # timestamp and a literal ID or coordinate, so a reset and re-run
    # reproduces the same rows.
    #
    # Both versions are created before the "latest default" restore below, so
    # that restore still decides which version the organization opens by
    # default: every fare-zone journey selects its version in the version
    # panel, and no other browser spec sees a different default version.
    # Creating them after the restore would make the choice depend on the
    # database session's timezone offset against the app clock.
    {:ok, fare_zones_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Fare Zones Version"})

    {:ok, fare_scale_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Fare Zones Scale Version"})

    fare_seed_at = ~U[2026-09-01 00:00:00.000000Z]
    fare_coordinate = fn value -> Decimal.new(:erlang.float_to_binary(value, decimals: 3)) end

    for {zone_id, name, color} <- [
          {"A", "Central", "ocean"},
          {"B", "Eastbank", "teal"},
          {"D", "Airport", "ochre"}
        ] do
      {:ok, _declared_zone} =
        FareZones.create_zone(
          %AuditContext{
            organization_id: org.id,
            gtfs_version_id: fare_zones_version.id,
            actor_id: editor.id,
            actor_email: editor.email
          },
          %{
            zone_id: zone_id,
            name: name,
            color: color
          }
        )
    end

    fare_stop = fn stop_id, stop_name, lat, lon, zone_id, attrs ->
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: fare_zones_version.id,
          stop_id: stop_id,
          stop_name: stop_name,
          stop_lat: lat && fare_coordinate.(lat),
          stop_lon: lon && fare_coordinate.(lon),
          location_type: 0,
          zone_id: zone_id,
          parent_station: nil,
          platform_code: nil,
          inserted_at: fare_seed_at,
          updated_at: fare_seed_at
        },
        attrs
      )
    end

    fare_west_stops =
      for index <- 1..8 do
        fare_stop.(
          "BROWSER_FZ_WEST_#{index}",
          "Central West #{index}",
          42.300 + (index - 1) * 0.002,
          -71.108 + (index - 1) * 0.001,
          "A",
          %{}
        )
      end

    fare_east_stops =
      for index <- 1..12 do
        fare_stop.(
          "BROWSER_FZ_EAST_#{index}",
          "Riverside #{index}",
          42.300 + (index - 1) * 0.002,
          -71.019 + (index - 1) * 0.001,
          "B",
          %{}
        )
      end

    fare_unassigned_stops =
      for index <- 1..4 do
        fare_stop.(
          "BROWSER_FZ_UNASSIGNED_#{index}",
          "Bayline #{index}",
          42.330 + (index - 1) * 0.002,
          -71.005 + (index - 1) * 0.001,
          nil,
          %{}
        )
      end

    fare_station_stops = [
      fare_stop.("BROWSER_FZ_STATION", "Central Union Station", 42.400, -71.030, "A", %{
        location_type: 1
      }),
      fare_stop.("BROWSER_FZ_PLATFORM_1", "Central Union Platform 1", 42.400, -71.030, "A", %{
        parent_station: "BROWSER_FZ_STATION",
        platform_code: "1"
      }),
      fare_stop.("BROWSER_FZ_PLATFORM_2", "Central Union Platform 2", 42.400, -71.029, "A", %{
        parent_station: "BROWSER_FZ_STATION",
        platform_code: "2"
      })
    ]

    fare_depot_stop = fare_stop.("BROWSER_FZ_DEPOT", "Central Depot", nil, nil, "A", %{})

    fare_zone_stops =
      fare_west_stops ++
        fare_east_stops ++ fare_unassigned_stops ++ fare_station_stops ++ [fare_depot_stop]

    {fare_zone_stop_count, nil} = Repo.insert_all(Stop, fare_zone_stops)

    {2, nil} =
      Repo.insert_all(
        FareAttribute,
        Enum.map([{"CITY", "2.50"}, {"CROSS", "3.75"}], fn {fare_id, price} ->
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: fare_zones_version.id,
            fare_id: fare_id,
            price: Decimal.new(price),
            currency_type: "USD",
            payment_method: 0,
            inserted_at: fare_seed_at,
            updated_at: fare_seed_at
          }
        end)
      )

    {:ok, _fare_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: fare_zones_version.id,
        route_id: "BROWSER_FARE_ROUTE",
        route_short_name: "FR",
        route_long_name: "Browser Fare Route",
        route_type: 3,
        route_color: "0055AA"
      })

    # CITY A→A and CITY C→A (C has no stops and no record, so the Checks tab has
    # a stopless reference), CROSS A→B, and CROSS through A + B (two rows of one
    # rule). Four rule groups, five rows.
    fare_rule_rows = [
      {"CITY", nil, "A", "A", nil},
      {"CROSS", nil, "A", "B", nil},
      {"CROSS", nil, nil, nil, "A"},
      {"CROSS", nil, nil, nil, "B"},
      {"CITY", nil, "C", "A", nil}
    ]

    {5, nil} =
      Repo.insert_all(
        FareRule,
        Enum.map(fare_rule_rows, fn {fare_id, route_id, origin_id, destination_id, contains_id} ->
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: fare_zones_version.id,
            fare_id: fare_id,
            route_id: route_id,
            origin_id: origin_id,
            destination_id: destination_id,
            contains_id: contains_id,
            inserted_at: fare_seed_at,
            updated_at: fare_seed_at
          }
        end)
      )

    fare_scale_zones = ~w(A B C D E)

    Enum.each(0..4, fn batch ->
      rows =
        for index <- (batch * 2_000)..(batch * 2_000 + 1_999) do
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: fare_scale_version.id,
            stop_id:
              "BROWSER_FZ_SCALE_" <> String.pad_leading(Integer.to_string(index + 1), 5, "0"),
            stop_name: "Scale Stop #{index + 1}",
            stop_lat: fare_coordinate.(42.000 + rem(index, 100) * 0.002),
            stop_lon: fare_coordinate.(-71.000 - div(index, 100) * 0.002),
            location_type: 0,
            zone_id: Enum.at(fare_scale_zones, rem(index, 5)),
            inserted_at: fare_seed_at,
            updated_at: fare_seed_at
          }
        end

      {2_000, nil} = Repo.insert_all(Stop, rows)
    end)

    # The seed is its own verifier: it reads both versions back through the
    # production functions and fails loudly rather than printing counts a later
    # UI step cannot rely on.
    %{zones: fare_zone_list, unassigned_count: fare_unassigned, boardable_count: fare_boardable} =
      FareZones.inventory(org.id, fare_zones_version.id)

    %{stopless_referenced: fare_stopless, empty_declared: fare_empty_declared} =
      FareZones.checks(org.id, fare_zones_version.id)

    fare_points = FareZones.list_stop_points(org.id, fare_zones_version.id)
    fare_rule_groups = FareZones.list_rule_groups(org.id, fare_zones_version.id)

    fare_fares =
      from(a in FareAttribute,
        where: a.organization_id == ^org.id and a.gtfs_version_id == ^fare_zones_version.id,
        order_by: a.fare_id,
        select: %{fare_id: a.fare_id, price: a.price, currency_type: a.currency_type}
      )
      |> Repo.all()

    %{
      zones: fare_scale_zone_list,
      boardable_count: fare_scale_boardable,
      unassigned_count: fare_scale_unassigned
    } = FareZones.inventory(org.id, fare_scale_version.id)

    fare_scale_points = FareZones.list_stop_points(org.id, fare_scale_version.id)

    fare_lons = Enum.map(fare_points, fn point -> Enum.at(point, 4) end)
    fare_midpoint = (Enum.min(fare_lons) + Enum.max(fare_lons)) / 2
    fare_west_points = Enum.filter(fare_points, fn point -> Enum.at(point, 4) < fare_midpoint end)
    fare_west_lon = fare_west_points |> Enum.map(&Enum.at(&1, 4)) |> Enum.max()
    fare_east_lon = fare_lons |> Enum.filter(&(&1 > fare_midpoint)) |> Enum.min()
    fare_gap = fare_east_lon - fare_west_lon

    expect = fn
      true, _message -> :ok
      false, message -> raise "Browser seed fare-zone check failed: #{message}"
    end

    expect.(fare_zone_stop_count == 28, "expected 28 stop rows, got #{fare_zone_stop_count}")
    expect.(fare_boardable == 27, "expected 27 boardable stops, got #{fare_boardable}")
    expect.(length(fare_points) == 26, "expected 26 map points, got #{length(fare_points)}")
    expect.(fare_unassigned == 4, "expected 4 unassigned stops, got #{fare_unassigned}")

    expect.(
      Enum.sort(Enum.map(fare_zone_list, &{&1.zone_id, &1.stop_count, &1.other_stop_count})) ==
        Enum.sort([{"A", 11, 1}, {"B", 12, 0}, {"C", 0, 0}, {"D", 0, 0}]),
      "unexpected zone counts: #{inspect(fare_zone_list)}"
    )

    expect.(Enum.map(fare_stopless, & &1.zone_id) == ["C"], "expected stopless C")
    expect.(Enum.map(fare_empty_declared, & &1.zone_id) == ["D"], "expected empty declared D")

    expect.(
      Enum.sort(
        Enum.map(fare_rule_groups, fn group ->
          {group.fare_id, group.origin_id, group.destination_id, group.contains}
        end)
      ) ==
        Enum.sort([
          {"CITY", "A", "A", []},
          {"CITY", "C", "A", []},
          {"CROSS", "A", "B", []},
          {"CROSS", nil, nil, ["A", "B"]}
        ]),
      "unexpected fare rule groups: #{inspect(fare_rule_groups)}"
    )

    expect.(
      fare_fares == [
        %{fare_id: "CITY", price: Decimal.new("2.50"), currency_type: "USD"},
        %{fare_id: "CROSS", price: Decimal.new("3.75"), currency_type: "USD"}
      ],
      "unexpected fares: #{inspect(fare_fares)}"
    )

    expect.(length(fare_west_points) == 8, "expected 8 stops west of the midpoint")
    expect.(fare_gap >= 0.02, "expected a longitude gap of at least 0.02, got #{fare_gap}")

    expect.(
      fare_scale_boardable == 10_000,
      "unexpected scale boardable count: #{fare_scale_boardable}"
    )

    expect.(
      Enum.sort(Enum.map(fare_scale_zone_list, &{&1.zone_id, &1.stop_count})) ==
        Enum.sort([{"A", 2_000}, {"B", 2_000}, {"C", 2_000}, {"D", 2_000}, {"E", 2_000}]),
      "unexpected scale zone counts: #{inspect(fare_scale_zone_list)}"
    )

    expect.(
      length(fare_scale_points) == 10_000,
      "expected 10,000 scale map points, got #{length(fare_scale_points)}"
    )

    expect.(fare_scale_unassigned == 0, "expected no unassigned scale stops")

    IO.puts(
      "Browser seed: Browser Fare Zones Version (#{fare_zones_version.id}) — " <>
        "#{fare_boardable} boardable stops (#{length(fare_points)} with coordinates, " <>
        "#{fare_boardable - length(fare_points)} without), #{fare_unassigned} unassigned, " <>
        "#{length(fare_fares)} fares, #{length(fare_rule_groups)} fare rules in the version"
    )

    IO.puts(
      "Browser seed: Browser Fare Zones Version geography — fitted midpoint longitude " <>
        "#{Float.round(fare_midpoint, 4)}, #{length(fare_west_points)} stops west of it " <>
        "(eastmost #{Float.round(fare_west_lon, 4)}), nearest east stop " <>
        "#{Float.round(fare_east_lon, 4)}, gap #{Float.round(fare_gap, 4)} degrees"
    )

    IO.puts(
      "Browser seed: Browser Fare Zones Version zones — " <>
        Enum.map_join(fare_zone_list, ", ", fn zone ->
          "#{zone.zone_id}=#{zone.name}:#{zone.stop_count}"
        end) <>
        "; stopless referenced " <>
        Enum.map_join(fare_stopless, ",", & &1.zone_id) <>
        "; empty declared " <> Enum.map_join(fare_empty_declared, ",", & &1.zone_id)
    )

    IO.puts(
      "Browser seed: Browser Fare Zones Scale Version (#{fare_scale_version.id}) — " <>
        "#{fare_scale_boardable} located boardable stops in " <>
        "#{length(fare_scale_zone_list)} zones (" <>
        Enum.map_join(fare_scale_zone_list, ", ", fn zone ->
          "#{zone.zone_id}=#{zone.stop_count}"
        end) <> ")"
    )

    # ── Fare editor fixture versions (package 29, step 31) ──
    #
    # The fare editor's browser journeys read five versions by name through the
    # version switcher, so every one of them carries a state the editor draws
    # and none of them is a state no writer can produce:
    #
    #   * "Browser North Coast Fares Version" - the managed sample. It enters
    #     rows through the production importer of
    #     `test/fixtures/gtfs/fares/north_coast_v2` and the production
    #     `Fares.Conversion`, then the two writes the prepared North Coast
    #     still needs: the `N_LOCAL -> N_INTERCITY` difference through
    #     `Fares.Transfers.save/5` and the Toledo-to-Corvallis journey through
    #     `Fares.save_journey/2`. Without the difference that journey prices
    #     $8.50 (the two fares summed); with it, $6.00, which is the total the
    #     Checks tab's saved-journey row and "Accept new price" act on.
    #   * "Browser Blank Fares Version" - `no_fare`, the same feed with no fare
    #     files, which is the first-use setup: `Conversion.preview/2` answers
    #     `source: :none` with nothing to create.
    #   * "Browser Unmanaged V1 Fares Version" - `north_coast_v1` imported and
    #     never converted, so its stored `fare_attributes`/`fare_rules` rows
    #     stay the read-only fares the "Edit fares" conversion review opens on.
    #   * "Browser Fares Mismatch Version" - `north_coast_v1` converted, then
    #     its stored `fare_attributes` row for `LOCAL` raised to $1.75. That is
    #     a stored row an import of a feed edited after the first one leaves,
    #     written here as the row rather than through a writer because this
    #     package deliberately never edits one (INV-3). The derived
    #     older-format rows still say $1.50, which is the disagreement the
    #     mismatch banner reports and the state `set_older_format(:imported)`
    #     is offered against (R14).
    #   * "Browser Fares Gaps Version" - the managed sample with the two gaps
    #     step 29's checks read, opened through the production writers the
    #     Where tab uses: `Fares.set_zone_fare/7` with a `nil` product clears
    #     the `CST -> TOL` cell and `Fares.save_route_group/2` drops route 40
    #     from Local routes.
    #
    # Every write runs inside `Fares.VersionLock.transact/2` with
    # `Fares.Normalize.run!/2` before it commits (INV-1) and records its own
    # `fare_version` change-log entry (AC-26), so the seeded versions carry the
    # history the editor's Recent changes reads. Every read is scoped by the
    # organization's and the version's ids together (INV-5).
    #
    # The versions are created before the "latest default" restore below, so
    # that restore still decides which version the organization opens by.

    fare_audit = fn version ->
      %AuditContext{
        organization_id: org.id,
        gtfs_version_id: version.id,
        station_stop_id: nil,
        actor_id: editor.id,
        actor_email: editor.email
      }
    end

    fare_scope = fn version ->
      %{organization_id: org.id, gtfs_version_id: version.id, audit: fare_audit.(version)}
    end

    {:ok, fares_managed_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser North Coast Fares Version"})

    {:ok, fares_blank_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Blank Fares Version"})

    {:ok, fares_unmanaged_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Unmanaged V1 Fares Version"})

    # Conversion changes its input version. Keep the read-only journey's
    # unmanaged fixture separate from the setup journey's writable review.
    {:ok, fares_conversion_version} =
      Versions.create_gtfs_version(org.id, %{
        name: "Browser Unmanaged V1 Conversion Fares Version"
      })

    {:ok, fares_mismatch_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Fares Mismatch Version"})

    {:ok, fares_gaps_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Fares Gaps Version"})

    # `import!/3` raises when a feed stops importing, so a fixture that cannot
    # be read is a seed failure rather than a silently empty version.
    FaresFixtures.import!(org, fares_managed_version, "north_coast_v2")
    FaresFixtures.import!(org, fares_blank_version, "no_fare")
    FaresFixtures.import!(org, fares_unmanaged_version, "north_coast_v1")
    FaresFixtures.import!(org, fares_conversion_version, "north_coast_v1")
    FaresFixtures.import!(org, fares_mismatch_version, "north_coast_v1")
    FaresFixtures.import!(org, fares_gaps_version, "north_coast_v2")

    convert! = fn version ->
      scope = fare_scope.(version)
      {:ok, plan} = Conversion.preview(org.id, version.id)
      {:ok, _converted} = Conversion.apply(scope, plan.fingerprint, [])
      scope
    end

    managed_scope = convert!.(fares_managed_version)
    convert!.(fares_mismatch_version)
    gaps_scope = convert!.(fares_gaps_version)

    # The sample's two pass names. `Conversion` classifies a product by R12 —
    # every rule it uses must share its conditions with a rule of a *differently
    # named* fare — and the sample's passes each stand alone, so the conversion
    # leaves all seven fares as single rides. A version whose operator has since
    # said which names are passes records that in `fare_product_details`, which
    # is where the Where tab's passes table reads it from, so the seed records
    # the same fact here.
    record_pass_kinds! = fn version_ids, kinds ->
      for gtfs_version_id <- version_ids,
          detail <-
            Repo.all(
              from(product in FareProductDetail,
                where:
                  product.organization_id == ^org.id and
                    product.gtfs_version_id == ^gtfs_version_id
              )
            ) do
        base = detail.fare_product_id |> String.split("_adult_") |> hd()

        case Map.fetch(kinds, base) do
          {:ok, {kind, accepted}} ->
            detail
            |> Ecto.Changeset.change(%{kind: kind, accepted_network_ids: accepted})
            |> Repo.update!()

          :error ->
            :ok
        end
      end
    end

    record_pass_kinds!.(
      [fares_managed_version.id, fares_gaps_version.id],
      %{
        "day_pass" => {"pass", ["N_LOCAL"]},
        "month_pass" => {"pass", ["all_routes"]}
      }
    )

    # The difference the prepared North Coast needs: without it the sample's
    # Local-then-Intercity journey charges both fares.
    {:ok, _fares_difference} =
      Transfers.save(
        managed_scope,
        "N_LOCAL",
        "N_INTERCITY",
        %{pay: :difference, minutes: 90},
        nil
      )

    # A Monday inside the sample's calendar span (2026-09-01 through 2026-09-30).
    {:ok, _fares_journey} =
      Fares.save_journey(managed_scope, %{
        name: "Toledo to Corvallis",
        rider_category_id: "adult",
        fare_media_id: "cash",
        service_date: ~D[2026-09-07],
        legs: [
          %{
            route_id: "4",
            from_stop_id: "TOLEDO",
            to_stop_id: "NTC",
            departs: 7 * 3600 + 40 * 60,
            arrives: 8 * 3600 + 55 * 60
          },
          %{
            route_id: "10",
            from_stop_id: "NTC",
            to_stop_id: "CORVALLIS",
            departs: 8 * 3600 + 20 * 60,
            arrives: 10 * 3600 + 20 * 60
          }
        ]
      })

    # The mismatch is a stored older-format row the derived one disagrees with.
    # `Fares` never edits a stored `fare_attributes` row (INV-3), so the row is
    # written the way an import of a later-edited feed leaves it.
    {1, nil} =
      FareAttribute
      |> where(
        [attribute],
        attribute.organization_id == ^org.id and
          attribute.gtfs_version_id == ^fares_mismatch_version.id and attribute.fare_id == "LOCAL"
      )
      |> Repo.update_all(set: [price: Decimal.new("1.75"), updated_at: DateTime.utc_now()])

    # The gaps version has no fare in either direction of the CST/TOL pair.
    # This is a newly created disposable fixture, so no user has reviewed a
    # cell yet; clear both directions together before normalization can remove
    # the only fare-rule reference that keeps TOL discoverable as a zone.
    {:ok, _fares_cleared_pair} =
      Fares.set_zone_fare(gaps_scope, "N_LOCAL", "CST", "TOL", nil, true, nil)

    gaps_local_routes =
      "N_LOCAL"
      |> then(fn network_id ->
        from(row in RouteNetwork,
          where:
            row.organization_id == ^org.id and row.gtfs_version_id == ^fares_gaps_version.id and
              row.network_id == ^network_id
        )
      end)
      |> select([row], row.route_id)
      |> Repo.all()
      |> Enum.sort()

    {:ok, _fares_group_without_40} =
      FaresFixtures.save_route_group(gaps_scope, %{
        network_id: "N_LOCAL",
        name: "Local routes",
        route_ids: Enum.reject(gaps_local_routes, &(&1 == "40"))
      })

    {:ok, managed_workspace} = Fares.load_workspace(org.id, fares_managed_version.id)

    IO.puts(
      "Browser seed: fare editor versions — " <>
        "#{fares_managed_version.name} (#{fares_managed_version.id}, managed, " <>
        "#{length(managed_workspace.fares)} fares), " <>
        "#{fares_blank_version.name} (#{fares_blank_version.id}, no fares), " <>
        "#{fares_unmanaged_version.name} (#{fares_unmanaged_version.id}, unmanaged v1), " <>
        "#{fares_mismatch_version.name} (#{fares_mismatch_version.id}, stored LOCAL $1.75 vs derived $1.50), " <>
        "#{fares_gaps_version.name} (#{fares_gaps_version.id}, CST→TOL gap, route 40 in no group)"
    )

    IO.puts(
      "Browser seed: #{fares_managed_version.name} — journey \"Toledo to Corvallis\" saved at " <>
        "$6.00 (the N_LOCAL → N_INTERCITY difference) on 2026-09-07"
    )

    # The states above are read back through the same reads the editor's tabs
    # draw from, so a fixture that stops being the state its name promises
    # fails the seed instead of quietly seeding an empty version.
    fares_expect = fn
      true, _message -> :ok
      false, message -> raise "Browser seed fare editor check failed: #{message}"
    end

    fares_checks = fn version -> Fares.Checks.run(org.id, version.id) end

    fares_expect.(
      Fares.managed?(org.id, fares_managed_version.id),
      "the North Coast version is not managed"
    )

    fares_expect.(
      Fares.managed?(org.id, fares_unmanaged_version.id) == false,
      "the unmanaged v1 version is managed"
    )

    fares_expect.(
      Fares.managed?(org.id, fares_mismatch_version.id),
      "the mismatch version is not managed"
    )

    fares_expect.(
      match?({:ok, %{source: :none}}, Conversion.preview(org.id, fares_blank_version.id)),
      "the blank version is not the first-use setup"
    )

    fares_expect.(
      Enum.map(fares_checks.(fares_managed_version).repair, & &1.code) == [],
      "the clean North Coast version reports #{inspect(fares_checks.(fares_managed_version).repair)}"
    )

    fares_expect.(
      Enum.sort(Enum.map(fares_checks.(fares_gaps_version).repair, & &1.code)) ==
        ["route_without_fare", "zone_pair_without_fare"],
      "the gaps version does not report exactly the two gaps: " <>
        inspect(Enum.map(fares_checks.(fares_gaps_version).repair, & &1.code))
    )

    # The saved journey's total is what the Checks tab shows and what "Accept new
    # price" rewrites, so it is read back from the stored row rather than assumed.
    stored_journey =
      Repo.one!(
        from(row in FareSavedJourney,
          where:
            row.organization_id == ^org.id and
              row.gtfs_version_id == ^fares_managed_version.id
        )
      )

    fares_expect.(
      stored_journey.expected_amount == Decimal.new("6.00"),
      "the saved journey prices #{stored_journey.expected_amount}, not 6.00"
    )

    fares_expect.(
      fares_checks.(fares_managed_version) |> Map.fetch!(:review) == [],
      "the North Coast version reports a review item"
    )

    # ── Flex fixture version (package 22; the data steps 18–27 capture) ──
    #
    # "Browser Flex Version" gives the flex pages their data: an agency, weekday
    # and Saturday calendars with names, Route 20 with an outbound and an
    # inbound pattern (one shape and two weekday trips each way, one Saturday
    # trip each way), five stops along the Newport–Toledo valley road, and the
    # two services the flex list, the service page and the area editor render:
    #
    #   * "Newport Dial-a-Ride", an area service with one drawn Newport area,
    #     weekday 07:00–18:00 and Saturday 09:00–16:00 hours, an earlier-day
    #     booking rule and one connecting stop, following the prototype's
    #     dial-a-ride fixture; the connecting stop is the representative flex
    #     fixture's own arrangement (`flex_fixtures.ex` gives its dial-a-ride
    #     two), and it is what the flex map's "Connecting stop" legend names;
    #   * "Valley Line detours", a detour service on Route 20 over the Newport
    #     Heights–Toledo Junction stretch, ¾ mile (1200 m), wording set, one
    #     same-day booking rule, on the weekday and Saturday calendars.
    #
    # The two services are written through the production `Flex.create_service/2`
    # and `Flex.save_service/4`, so the seed stores exactly what the service page
    # would, geometry normalisation included. The area polygon is the Census
    # place boundary for Newport from the prototype's
    # `.specs/22-gtfs-flex/evidence/prototype-src/basemap/census/place-Newport.geojson`,
    # repaired (the published ring self-intersects at −124.047924,44.602130) and
    # simplified to 342 positions at a 0.0003° Douglas-Peucker tolerance, which
    # is 0.06% of the original area and well inside R8's 5,000-position limit.
    # Feed rows are direct inserts with one fixed seed timestamp, the way the
    # fare-zones fixtures above are written: a pattern's `shape_id` and a pattern
    # stop's `shape_dist_traveled` are not castable through the changesets.
    #
    # The version is created before the "latest default" restore below, so the
    # diagram version stays the organization's default version.
    {:ok, flex_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Flex Version"})

    flex_audit = %AuditContext{
      organization_id: org.id,
      gtfs_version_id: flex_version.id,
      actor_id: editor.id,
      actor_email: editor.email
    }

    flex_seed_at = ~U[2026-09-01 00:00:00.000000Z]
    flex_today = Gtfs.DisplayClock.today(org.id, flex_version.id).date
    flex_coordinate = fn value -> Decimal.new(:erlang.float_to_binary(value, decimals: 6)) end
    flex_id = fn -> Ecto.UUID.generate() end
    flex_start_date = Date.add(flex_today, -30)
    flex_end_date = Date.add(flex_today, 335)

    {1, nil} =
      Repo.insert_all(Agency, [
        %{
          id: flex_id.(),
          organization_id: org.id,
          gtfs_version_id: flex_version.id,
          agency_id: "NCT",
          agency_name: "North Coast Transit",
          agency_url: "https://northcoast.example",
          agency_timezone: "America/Los_Angeles",
          agency_phone: "(541) 555-0142",
          inserted_at: flex_seed_at,
          updated_at: flex_seed_at
        }
      ])

    {1, nil} =
      Repo.insert_all(Route, [
        %{
          id: flex_id.(),
          organization_id: org.id,
          gtfs_version_id: flex_version.id,
          route_id: "20",
          route_short_name: "20",
          route_long_name: "Valley Line",
          route_type: 3,
          agency_id: "NCT",
          route_color: "0D737D",
          route_text_color: "FFFFFF",
          active: true,
          inserted_at: flex_seed_at,
          updated_at: flex_seed_at
        }
      ])

    # Newport Heights and Olalla Road sit east of the Newport town limits, so
    # only the city-center stop falls inside the drawn area; that is what the
    # real valley road does.
    flex_stops = [
      {"BROWSER_FLEX_NP1", "Newport City Center", 44.63437, -124.05343},
      {"BROWSER_FLEX_NP2", "Newport Heights", 44.63536, -124.03225},
      {"BROWSER_FLEX_OLR", "Olalla Road", 44.63162, -123.98500},
      {"BROWSER_FLEX_TLD1", "Toledo Junction", 44.63187, -123.95000},
      {"BROWSER_FLEX_TLD2", "Toledo City Hall", 44.62202, -123.93740}
    ]

    {5, nil} =
      Repo.insert_all(
        Stop,
        Enum.map(flex_stops, fn {stop_id, stop_name, lat, lon} ->
          %{
            id: flex_id.(),
            organization_id: org.id,
            gtfs_version_id: flex_version.id,
            stop_id: stop_id,
            stop_name: stop_name,
            stop_lat: flex_coordinate.(lat),
            stop_lon: flex_coordinate.(lon),
            location_type: 0,
            inserted_at: flex_seed_at,
            updated_at: flex_seed_at
          }
        end)
      )

    # Weekday and Saturday service, each named through a calendar attribute (the
    # flex hours rows and the rider text read those names). The span stays
    # relative to the version's local today so the week strip on the service page
    # always shows live service.
    flex_calendars = [
      {"weekday", "Weekday", "Weekdays", {1, 1, 1, 1, 1, 0, 0}},
      {"saturday", "Saturday", "Saturdays", {0, 0, 0, 0, 0, 1, 0}}
    ]

    {2, nil} =
      Repo.insert_all(
        Calendar,
        Enum.map(flex_calendars, fn {service_id, _name, _plural, days} ->
          {monday, tuesday, wednesday, thursday, friday, saturday, sunday} = days

          %{
            id: flex_id.(),
            organization_id: org.id,
            gtfs_version_id: flex_version.id,
            service_id: service_id,
            monday: monday,
            tuesday: tuesday,
            wednesday: wednesday,
            thursday: thursday,
            friday: friday,
            saturday: saturday,
            sunday: sunday,
            start_date: flex_start_date,
            end_date: flex_end_date,
            inserted_at: flex_seed_at,
            updated_at: flex_seed_at
          }
        end)
      )

    {2, nil} =
      Repo.insert_all(
        CalendarAttribute,
        Enum.map(flex_calendars, fn {service_id, name, plural, _days} ->
          %{
            id: flex_id.(),
            organization_id: org.id,
            gtfs_version_id: flex_version.id,
            service_id: service_id,
            service_schedule_name: name,
            service_description: plural,
            service_schedule_type: nil,
            service_schedule_typicality: 0,
            rating_start_date: nil,
            rating_end_date: nil,
            rating_description: nil,
            inserted_at: flex_seed_at,
            updated_at: flex_seed_at
          }
        end)
      )

    # One shape per direction along the valley road, with the stop-to-stop
    # distances the pattern stops and the detour zone cuts measure against.
    flex_shapes = [
      {"BROWSER_FLEX_20_OUT",
       [
         {-124.05343, 44.63437, 1, 0},
         {-124.03225, 44.63536, 2, 1680},
         {-123.98500, 44.63162, 3, 5440},
         {-123.95000, 44.63187, 4, 8210},
         {-123.93740, 44.62202, 5, 9690}
       ]},
      {"BROWSER_FLEX_20_IN",
       [
         {-123.93740, 44.62202, 1, 0},
         {-123.95000, 44.63187, 2, 1480},
         {-123.98500, 44.63162, 3, 4250},
         {-124.03225, 44.63536, 4, 8010},
         {-124.05343, 44.63437, 5, 9690}
       ]}
    ]

    {10, nil} =
      Repo.insert_all(
        Shape,
        Enum.flat_map(flex_shapes, fn {shape_id, points} ->
          Enum.map(points, fn {lon, lat, sequence, distance} ->
            %{
              id: flex_id.(),
              organization_id: org.id,
              gtfs_version_id: flex_version.id,
              shape_id: shape_id,
              shape_pt_lon: flex_coordinate.(lon),
              shape_pt_lat: flex_coordinate.(lat),
              shape_pt_sequence: sequence,
              shape_dist_traveled: Decimal.new(distance),
              inserted_at: flex_seed_at,
              updated_at: flex_seed_at
            }
          end)
        end)
      )

    # Two trips a direction on the weekday calendar and one on Saturdays, each
    # calling at all five stops in its direction's order. The trips stay in the
    # default "pending" pattern-derivation state, like the export fixtures: the
    # patterns below are the flex detour derivation's input, not a link.
    flex_trips = [
      {"BROWSER_FLEX_20_OUT_1", 0, "weekday", "BROWSER_FLEX_20_OUT", "Toledo",
       [
         {"BROWSER_FLEX_NP1", "07:00:00"},
         {"BROWSER_FLEX_NP2", "07:10:00"},
         {"BROWSER_FLEX_OLR", "07:22:00"},
         {"BROWSER_FLEX_TLD1", "07:32:00"},
         {"BROWSER_FLEX_TLD2", "07:45:00"}
       ]},
      {"BROWSER_FLEX_20_OUT_2", 0, "weekday", "BROWSER_FLEX_20_OUT", "Toledo",
       [
         {"BROWSER_FLEX_NP1", "12:00:00"},
         {"BROWSER_FLEX_NP2", "12:10:00"},
         {"BROWSER_FLEX_OLR", "12:22:00"},
         {"BROWSER_FLEX_TLD1", "12:32:00"},
         {"BROWSER_FLEX_TLD2", "12:45:00"}
       ]},
      {"BROWSER_FLEX_20_OUT_SAT", 0, "saturday", "BROWSER_FLEX_20_OUT", "Toledo",
       [
         {"BROWSER_FLEX_NP1", "09:00:00"},
         {"BROWSER_FLEX_NP2", "09:10:00"},
         {"BROWSER_FLEX_OLR", "09:22:00"},
         {"BROWSER_FLEX_TLD1", "09:32:00"},
         {"BROWSER_FLEX_TLD2", "09:45:00"}
       ]},
      {"BROWSER_FLEX_20_IN_1", 1, "weekday", "BROWSER_FLEX_20_IN", "Newport",
       [
         {"BROWSER_FLEX_TLD2", "08:00:00"},
         {"BROWSER_FLEX_TLD1", "08:13:00"},
         {"BROWSER_FLEX_OLR", "08:23:00"},
         {"BROWSER_FLEX_NP2", "08:35:00"},
         {"BROWSER_FLEX_NP1", "08:45:00"}
       ]},
      {"BROWSER_FLEX_20_IN_2", 1, "weekday", "BROWSER_FLEX_20_IN", "Newport",
       [
         {"BROWSER_FLEX_TLD2", "16:00:00"},
         {"BROWSER_FLEX_TLD1", "16:13:00"},
         {"BROWSER_FLEX_OLR", "16:23:00"},
         {"BROWSER_FLEX_NP2", "16:35:00"},
         {"BROWSER_FLEX_NP1", "16:45:00"}
       ]},
      {"BROWSER_FLEX_20_IN_SAT", 1, "saturday", "BROWSER_FLEX_20_IN", "Newport",
       [
         {"BROWSER_FLEX_TLD2", "11:00:00"},
         {"BROWSER_FLEX_TLD1", "11:13:00"},
         {"BROWSER_FLEX_OLR", "11:23:00"},
         {"BROWSER_FLEX_NP2", "11:35:00"},
         {"BROWSER_FLEX_NP1", "11:45:00"}
       ]}
    ]

    {6, nil} =
      Repo.insert_all(
        Trip,
        Enum.map(flex_trips, fn {trip_id, direction_id, service_id, shape_id, headsign, _times} ->
          %{
            id: flex_id.(),
            organization_id: org.id,
            gtfs_version_id: flex_version.id,
            trip_id: trip_id,
            route_id: "20",
            service_id: service_id,
            trip_headsign: headsign,
            direction_id: direction_id,
            block_id: "BROWSER_FLEX_B20",
            shape_id: shape_id,
            inserted_at: flex_seed_at,
            updated_at: flex_seed_at
          }
        end)
      )

    {30, nil} =
      Repo.insert_all(
        StopTime,
        flex_trips
        |> Enum.flat_map(fn {trip_id, _direction_id, _service_id, _shape_id, _headsign, times} ->
          times
          |> Enum.with_index(1)
          |> Enum.map(fn {{stop_id, time}, sequence} ->
            %{
              id: flex_id.(),
              organization_id: org.id,
              gtfs_version_id: flex_version.id,
              trip_id: trip_id,
              stop_id: stop_id,
              stop_sequence: sequence,
              arrival_time: time,
              departure_time: time,
              inserted_at: flex_seed_at,
              updated_at: flex_seed_at
            }
          end)
        end)
      )

    # Outbound and inbound patterns with the same stops as the trips. The detour
    # service's zones come from these patterns and shapes.
    flex_patterns = [
      {"BROWSER_FLEX_P20_OUT", "BROWSER_FLEX_20_OUT", 0, "Toledo", "Newport – Toledo",
       [
         {"BROWSER_FLEX_NP1", 1, 0},
         {"BROWSER_FLEX_NP2", 2, 1680},
         {"BROWSER_FLEX_OLR", 3, 5440},
         {"BROWSER_FLEX_TLD1", 4, 8210},
         {"BROWSER_FLEX_TLD2", 5, 9690}
       ]},
      {"BROWSER_FLEX_P20_IN", "BROWSER_FLEX_20_IN", 1, "Newport", "Toledo – Newport",
       [
         {"BROWSER_FLEX_TLD2", 1, 0},
         {"BROWSER_FLEX_TLD1", 2, 1480},
         {"BROWSER_FLEX_OLR", 3, 4250},
         {"BROWSER_FLEX_NP2", 4, 8010},
         {"BROWSER_FLEX_NP1", 5, 9690}
       ]}
    ]

    flex_pattern_rows =
      Enum.map(flex_patterns, fn {pattern_id, shape_id, direction_id, headsign, name, _stops} ->
        %{
          id: flex_id.(),
          organization_id: org.id,
          gtfs_version_id: flex_version.id,
          route_pattern_id: pattern_id,
          route_id: "20",
          direction_id: direction_id,
          headsign: headsign,
          route_pattern_name: name,
          route_pattern_time_desc: "All day",
          route_pattern_typicality: 1,
          route_pattern_sort_order: direction_id,
          shape_id: shape_id,
          inserted_at: flex_seed_at,
          updated_at: flex_seed_at
        }
      end)

    {2, nil} = Repo.insert_all(RoutePattern, flex_pattern_rows)

    {10, nil} =
      Repo.insert_all(
        RoutePatternStop,
        Enum.flat_map(flex_patterns, fn {pattern_id, _shape_id, _direction_id, _headsign, _name,
                                         stops} ->
          pattern = Enum.find(flex_pattern_rows, &(&1.route_pattern_id == pattern_id))

          Enum.map(stops, fn {stop_id, position, distance} ->
            %{
              id: flex_id.(),
              route_pattern_id: pattern.id,
              organization_id: org.id,
              gtfs_version_id: flex_version.id,
              stop_id: stop_id,
              position: position,
              shape_dist_traveled: Decimal.new(distance),
              inserted_at: flex_seed_at,
              updated_at: flex_seed_at
            }
          end)
        end)
      )

    # The drawn Newport area: the Census place polygon from the prototype's
    # basemap, valid and simplified (see the block comment above).
    flex_newport_area = %{
      "type" => "Polygon",
      "coordinates" => [
        [
          [-124.048056, 44.598582],
          [-124.046076, 44.597975],
          [-124.046524, 44.596962],
          [-124.04588, 44.596816],
          [-124.042773, 44.60053],
          [-124.042845, 44.598462],
          [-124.041238, 44.598473],
          [-124.041332, 44.594963],
          [-124.048187, 44.595035],
          [-124.048097, 44.591496],
          [-124.053342, 44.591566],
          [-124.053277, 44.587998],
          [-124.048015, 44.587945],
          [-124.048148, 44.573647],
          [-124.053421, 44.573633],
          [-124.053404, 44.570995],
          [-124.05584, 44.570971],
          [-124.055748, 44.566458],
          [-124.054218, 44.566422],
          [-124.054204, 44.562099],
          [-124.05324, 44.5621],
          [-124.053462, 44.560893],
          [-124.052652, 44.560808],
          [-124.050876, 44.562099],
          [-124.049257, 44.562093],
          [-124.049099, 44.558309],
          [-124.051877, 44.558265],
          [-124.051802, 44.554556],
          [-124.048964, 44.554575],
          [-124.0488, 44.550607],
          [-124.054256, 44.550552],
          [-124.054068, 44.546985],
          [-124.059234, 44.546893],
          [-124.059184, 44.545139],
          [-124.060759, 44.545146],
          [-124.060317, 44.545584],
          [-124.060746, 44.546971],
          [-124.061719, 44.548076],
          [-124.062536, 44.547425],
          [-124.062036, 44.54702],
          [-124.063481, 44.546511],
          [-124.064351, 44.547064],
          [-124.064379, 44.548783],
          [-124.063236, 44.548815],
          [-124.062408, 44.552321],
          [-124.061857, 44.55233],
          [-124.061862, 44.556047],
          [-124.070887, 44.556016],
          [-124.070888, 44.556722],
          [-124.071355, 44.556733],
          [-124.07109, 44.557771],
          [-124.069308, 44.557769],
          [-124.069309, 44.558739],
          [-124.070958, 44.558738],
          [-124.07074, 44.559635],
          [-124.071736, 44.559819],
          [-124.071718, 44.56161],
          [-124.071029, 44.561779],
          [-124.071026, 44.562994],
          [-124.070254, 44.564172],
          [-124.070568, 44.565405],
          [-124.069193, 44.565613],
          [-124.068745, 44.567355],
          [-124.066001, 44.567325],
          [-124.061257, 44.565707],
          [-124.059393, 44.566254],
          [-124.061179, 44.566545],
          [-124.060595, 44.570079],
          [-124.063671, 44.570096],
          [-124.063682, 44.571843],
          [-124.067271, 44.571847],
          [-124.065907, 44.575946],
          [-124.065801, 44.578548],
          [-124.064856, 44.580977],
          [-124.064337, 44.58454],
          [-124.063761, 44.584507],
          [-124.063767, 44.584943],
          [-124.064281, 44.584977],
          [-124.063197, 44.592078],
          [-124.060866, 44.59293],
          [-124.058467, 44.592129],
          [-124.05849, 44.592562],
          [-124.06233, 44.593846],
          [-124.063817, 44.591594],
          [-124.066066, 44.591357],
          [-124.065808, 44.589521],
          [-124.068492, 44.590132],
          [-124.068606, 44.588883],
          [-124.06979, 44.588334],
          [-124.070392, 44.592768],
          [-124.068776, 44.596284],
          [-124.068687, 44.599363],
          [-124.06804, 44.601546],
          [-124.068429, 44.60488],
          [-124.07191, 44.609548],
          [-124.071172, 44.610002],
          [-124.073439, 44.61054],
          [-124.072919, 44.611324],
          [-124.073444, 44.611802],
          [-124.081274, 44.608457],
          [-124.08358, 44.611147],
          [-124.067254, 44.617706],
          [-124.065706, 44.619534],
          [-124.066532, 44.622642],
          [-124.068738, 44.625346],
          [-124.067658, 44.630628],
          [-124.065457, 44.636191],
          [-124.065685, 44.636703],
          [-124.064332, 44.640199],
          [-124.064056, 44.642687],
          [-124.063377, 44.643705],
          [-124.061823, 44.65339],
          [-124.061289, 44.661963],
          [-124.061824, 44.66272],
          [-124.0627, 44.670432],
          [-124.063892, 44.673087],
          [-124.06464, 44.673608],
          [-124.066714, 44.67288],
          [-124.068853, 44.672823],
          [-124.069885, 44.673357],
          [-124.070751, 44.672647],
          [-124.07106, 44.672964],
          [-124.072487, 44.672596],
          [-124.072591, 44.673068],
          [-124.073336, 44.672635],
          [-124.073351, 44.673392],
          [-124.07449, 44.672898],
          [-124.07515, 44.672991],
          [-124.075608, 44.673686],
          [-124.075848, 44.673289],
          [-124.075773, 44.673829],
          [-124.0761, 44.673551],
          [-124.076276, 44.674091],
          [-124.076322, 44.673752],
          [-124.077172, 44.67428],
          [-124.077506, 44.675245],
          [-124.078853, 44.676318],
          [-124.079269, 44.676407],
          [-124.079866, 44.675531],
          [-124.080306, 44.676191],
          [-124.080697, 44.675673],
          [-124.080816, 44.676136],
          [-124.079907, 44.677256],
          [-124.078952, 44.677309],
          [-124.079038, 44.677727],
          [-124.077792, 44.676925],
          [-124.077464, 44.677372],
          [-124.077269, 44.676794],
          [-124.076796, 44.677348],
          [-124.075717, 44.677016],
          [-124.073816, 44.677305],
          [-124.070458, 44.680128],
          [-124.068537, 44.68458],
          [-124.069235, 44.685987],
          [-124.068977, 44.6874],
          [-124.066779, 44.693206],
          [-124.06651, 44.695551],
          [-124.060722, 44.695573],
          [-124.060563, 44.699197],
          [-124.054291, 44.699175],
          [-124.054485, 44.696409],
          [-124.055565, 44.696324],
          [-124.055594, 44.692632],
          [-124.061007, 44.692877],
          [-124.061054, 44.692079],
          [-124.057317, 44.692038],
          [-124.057325, 44.690241],
          [-124.054053, 44.690326],
          [-124.054858, 44.689525],
          [-124.054878, 44.688232],
          [-124.052187, 44.688214],
          [-124.052277, 44.6739],
          [-124.057344, 44.673919],
          [-124.057376, 44.668925],
          [-124.057205, 44.668521],
          [-124.056339, 44.668696],
          [-124.054839, 44.66454],
          [-124.049341, 44.666271],
          [-124.049602, 44.66695],
          [-124.049152, 44.66721],
          [-124.050444, 44.667898],
          [-124.050907, 44.67027],
          [-124.047201, 44.670258],
          [-124.047126, 44.659311],
          [-124.041324, 44.659365],
          [-124.041318, 44.657405],
          [-124.037955, 44.658868],
          [-124.037671, 44.659424],
          [-124.038558, 44.660056],
          [-124.03803, 44.660414],
          [-124.037315, 44.65968],
          [-124.037045, 44.660671],
          [-124.027212, 44.660706],
          [-124.026836, 44.661617],
          [-124.026744, 44.666587],
          [-124.021855, 44.66656],
          [-124.021938, 44.65948],
          [-124.019444, 44.658893],
          [-124.018083, 44.660848],
          [-124.016996, 44.660847],
          [-124.017026, 44.656976],
          [-124.013161, 44.656087],
          [-124.012786, 44.657239],
          [-124.012117, 44.657537],
          [-124.012124, 44.655688],
          [-124.012772, 44.655715],
          [-124.013822, 44.654839],
          [-124.014762, 44.655753],
          [-124.040526, 44.655739],
          [-124.040525, 44.653942],
          [-124.043822, 44.653941],
          [-124.043822, 44.652132],
          [-124.042954, 44.652138],
          [-124.042953, 44.648302],
          [-124.041792, 44.648309],
          [-124.041619, 44.648791],
          [-124.030902, 44.648849],
          [-124.031469, 44.645305],
          [-124.035553, 44.64527],
          [-124.035551, 44.644606],
          [-124.034868, 44.644607],
          [-124.034864, 44.641784],
          [-124.032031, 44.641786],
          [-124.031542, 44.641039],
          [-124.030185, 44.640636],
          [-124.03024, 44.639965],
          [-124.029756, 44.639831],
          [-124.03007, 44.639401],
          [-124.033414, 44.639455],
          [-124.033414, 44.639849],
          [-124.034859, 44.639437],
          [-124.039973, 44.639419],
          [-124.039781, 44.638148],
          [-124.037712, 44.638152],
          [-124.036825, 44.637421],
          [-124.03684, 44.636481],
          [-124.037765, 44.636503],
          [-124.037706, 44.63585],
          [-124.035321, 44.6353],
          [-124.035326, 44.634543],
          [-124.034054, 44.635158],
          [-124.033585, 44.633496],
          [-124.032584, 44.633498],
          [-124.032573, 44.631084],
          [-124.0301, 44.631114],
          [-124.030112, 44.633606],
          [-124.03116, 44.633611],
          [-124.031149, 44.63452],
          [-124.027635, 44.634389],
          [-124.027637, 44.63224],
          [-124.028406, 44.632231],
          [-124.028401, 44.631137],
          [-124.027633, 44.631143],
          [-124.027636, 44.632189],
          [-124.02467, 44.632172],
          [-124.024671, 44.632967],
          [-124.024095, 44.633203],
          [-124.024094, 44.632168],
          [-124.022699, 44.632166],
          [-124.022509, 44.633872],
          [-124.020549, 44.634351],
          [-124.019066, 44.634279],
          [-124.018294, 44.632189],
          [-124.020005, 44.632227],
          [-124.020003, 44.632818],
          [-124.020789, 44.632818],
          [-124.021021, 44.631886],
          [-124.020443, 44.630987],
          [-124.019242, 44.631123],
          [-124.01932, 44.631685],
          [-124.018616, 44.630826],
          [-124.019863, 44.630642],
          [-124.021094, 44.629559],
          [-124.022641, 44.629545],
          [-124.022218, 44.614354],
          [-124.028407, 44.614459],
          [-124.03345, 44.612279],
          [-124.035066, 44.61234],
          [-124.035597, 44.611772],
          [-124.04037, 44.61163],
          [-124.042535, 44.612726],
          [-124.043293, 44.612674],
          [-124.04252, 44.611709],
          [-124.044229, 44.611765],
          [-124.044214, 44.610827],
          [-124.0462, 44.611063],
          [-124.046213, 44.611851],
          [-124.047678, 44.611604],
          [-124.047658, 44.609185],
          [-124.042478, 44.609007],
          [-124.041933, 44.608437],
          [-124.041796, 44.607183],
          [-124.042722, 44.601989],
          [-124.047924, 44.60213],
          [-124.048056, 44.598582]
        ],
        [
          [-124.047762, 44.605807],
          [-124.047727, 44.607126],
          [-124.050197, 44.607161],
          [-124.050219, 44.606324],
          [-124.051195, 44.606348],
          [-124.051514, 44.605771],
          [-124.051516, 44.609274],
          [-124.052167, 44.609312],
          [-124.05156, 44.610254],
          [-124.050242, 44.610178],
          [-124.050248, 44.611542],
          [-124.051127, 44.610551],
          [-124.052767, 44.610621],
          [-124.05274, 44.612135],
          [-124.052845, 44.609364],
          [-124.055818, 44.609488],
          [-124.055946, 44.60617],
          [-124.052916, 44.606274],
          [-124.053017, 44.605268],
          [-124.054814, 44.60529],
          [-124.054297, 44.606082],
          [-124.058127, 44.60616],
          [-124.058264, 44.603619],
          [-124.057332, 44.603627],
          [-124.057568, 44.603256],
          [-124.053079, 44.603442],
          [-124.053131, 44.602205],
          [-124.047924, 44.60213],
          [-124.047762, 44.605807]
        ],
        [
          [-124.053208, 44.679018],
          [-124.053167, 44.680306],
          [-124.053772, 44.680252],
          [-124.053873, 44.679039],
          [-124.053208, 44.679018]
        ],
        [
          [-124.066901, 44.598297],
          [-124.058509, 44.597649],
          [-124.058462, 44.598706],
          [-124.067567, 44.599038],
          [-124.067585, 44.598325],
          [-124.066901, 44.598297]
        ],
        [
          [-124.058323, 44.598816],
          [-124.054205, 44.598723],
          [-124.054071, 44.602202],
          [-124.056849, 44.602203],
          [-124.056474, 44.602757],
          [-124.058283, 44.602756],
          [-124.058323, 44.598816]
        ]
      ]
    }

    {:ok, flex_area_service} =
      Flex.create_service(flex_audit, %{name: "Newport Dial-a-Ride", kind: :area})

    {:ok, _flex_area_saved} =
      Flex.save_service(
        flex_audit,
        flex_area_service,
        %{
          phone: "(541) 555-0142",
          phone_hours: %{"days" => "Mon–Fri", "from" => "08:00", "to" => "17:00"},
          info_url: "https://northcoast.example/dial-a-ride",
          hub_stop_ids: ["BROWSER_FLEX_NP1"],
          hours: [
            %{area_key: "a1", service_id: "weekday", start: "07:00", end: "18:00"},
            %{area_key: "a1", service_id: "saturday", start: "09:00", end: "16:00"}
          ],
          booking_rules: [%{when: :earlier_day, days: 1, by: "16:00"}]
        },
        [%{key: "a1", name: "Newport", source: :drawn, geojson: flex_newport_area}]
      )

    {:ok, flex_detour_service} =
      Flex.create_service(flex_audit, %{
        name: "Valley Line detours",
        kind: :detour,
        route_id: "20"
      })

    {:ok, _flex_detour_saved} =
      Flex.save_service(
        flex_audit,
        flex_detour_service,
        %{
          phone: "(541) 555-0142",
          distance_m: 1200,
          measure: :route,
          wording: "up to ¾ mile from the route",
          dropoffs: :tell_driver,
          first_stop_id: "BROWSER_FLEX_NP2",
          last_stop_id: "BROWSER_FLEX_TLD1",
          calendar_service_ids: ["weekday", "saturday"],
          booking_rules: [%{when: :same_day, minutes: 120}]
        },
        []
      )

    # The seed is its own verifier: it reads the version back through the
    # production functions and raises rather than printing counts the flex steps
    # cannot rely on.
    flex_services = Flex.list_services(org.id, flex_version.id)
    flex_facts = Flex.Checks.version_facts(org.id, flex_version.id)
    flex_area_saved = Enum.find(flex_services, &(&1.name == "Newport Dial-a-Ride"))
    flex_detour_saved = Enum.find(flex_services, &(&1.name == "Valley Line detours"))

    flex_weekday_trips =
      from(t in Trip,
        where:
          t.organization_id == ^org.id and t.gtfs_version_id == ^flex_version.id and
            t.route_id == "20" and t.service_id == "weekday",
        select: {t.direction_id, count(t.id)},
        group_by: t.direction_id
      )
      |> Repo.all()
      |> Enum.sort()

    flex_zones =
      Flex.Geometry.detour_zones(org.id, flex_version.id, flex_detour_saved)

    flex_expect = fn
      true, _message -> :ok
      false, message -> raise "Browser seed flex check failed: #{message}"
    end

    flex_expect.(
      Enum.sort(Enum.map(flex_services, & &1.name)) == [
        "Newport Dial-a-Ride",
        "Valley Line detours"
      ],
      "expected the two flex services, got #{inspect(Enum.map(flex_services, & &1.name))}"
    )

    flex_expect.(
      flex_area_saved != nil and flex_detour_saved != nil and
        Enum.sort(Enum.map(flex_services, & &1.id)) ==
          Enum.sort([flex_area_service.id, flex_detour_service.id]),
      "expected the two saved services in the version listing"
    )

    flex_expect.(
      Enum.map(flex_area_saved.areas, &{&1.key, &1.name, &1.source, &1.position}) ==
        [{"a1", "Newport", :drawn, 1}],
      "unexpected drawn areas: #{inspect(flex_area_saved.areas)}"
    )

    flex_expect.(
      Enum.map(flex_area_saved.hours, &{&1.area_key, &1.service_id, &1.start, &1.end}) == [
        {"a1", "weekday", "07:00", "18:00"},
        {"a1", "saturday", "09:00", "16:00"}
      ],
      "unexpected area hours: #{inspect(flex_area_saved.hours)}"
    )

    flex_expect.(
      flex_area_saved.hub_stop_ids == ["BROWSER_FLEX_NP1"],
      "unexpected dial-a-ride connecting stops: #{inspect(flex_area_saved.hub_stop_ids)}"
    )

    flex_expect.(
      length(flex_area_saved.booking_rules) == 1,
      "expected one dial-a-ride booking rule, got #{length(flex_area_saved.booking_rules)}"
    )

    flex_expect.(
      flex_detour_saved.route_id == "20" and flex_detour_saved.distance_m == 1200 and
        flex_detour_saved.wording == "up to ¾ mile from the route",
      "unexpected detour fields: #{inspect(flex_detour_saved)}"
    )

    flex_expect.(
      flex_weekday_trips == [{0, 2}, {1, 2}],
      "expected two weekday trips a direction on Route 20, got #{inspect(flex_weekday_trips)}"
    )

    flex_expect.(
      match?({:ok, [_zone_a, _zone_b]}, flex_zones),
      "expected two detour zones from the Newport Heights–Toledo Junction stretch, got #{inspect(flex_zones)}"
    )

    flex_statuses =
      Enum.map(flex_services, fn service ->
        others = Enum.reject(flex_services, &(&1.id == service.id))
        checks = Flex.Checks.run(service, flex_facts, others)
        status = Flex.Checks.status(service, checks)

        flex_expect.(
          status.errors == 0,
          "#{service.name} has readiness errors: #{inspect(checks)}"
        )

        {service.name, status.label}
      end)

    IO.puts(
      "Browser seed: Browser Flex Version (#{flex_version.id}) — " <>
        Enum.map_join(flex_statuses, ", ", fn {name, label} -> "#{name}: #{label}" end) <>
        "; Route 20 weekday trips #{inspect(flex_weekday_trips)}, " <>
        "#{length(elem(flex_zones, 1))} detour zones, " <>
        "#{length(flex_area_saved.areas)} drawn area with #{length(flex_area_saved.hours)} hours rows, " <>
        "#{length(flex_area_saved.hub_stop_ids)} connecting stops"
    )

    diagram_version
    |> Ecto.Changeset.change(published_at: DateTime.utc_now())
    |> Repo.update!()

    # ── Calendar list scenario data (isolated to the Browser E2E Version) ──
    #
    # Dates are relative to the version's agency-local today, so the list
    # statuses (runs today, ends soon, ended, not used, no service) stay
    # deterministic whatever day the suite runs. The rows are inserted directly
    # because this fixture supplies scenario data, not an audited edit.
    calendar_today = Gtfs.DisplayClock.today(org.id, diagram_version.id).date
    calendar_now = DateTime.utc_now()

    {:ok, _calendar_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "CAL_ROUTE",
        route_short_name: "CAL",
        route_long_name: "Calendar scenario route",
        route_type: 3,
        route_color: "0055AA"
      })

    daily = %{
      service_id: "CAL_DAILY",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 1,
      sunday: 1,
      start_date: Date.add(calendar_today, -30),
      end_date: Date.add(calendar_today, 30)
    }

    school = %{
      service_id: "CAL_SCHOOL",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: Date.add(calendar_today, -30),
      end_date: Date.add(calendar_today, 10)
    }

    legacy = %{
      service_id: "CAL_LEGACY",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: Date.add(calendar_today, -60),
      end_date: Date.add(calendar_today, -10)
    }

    unused = %{
      service_id: "CAL_UNUSED",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: Date.add(calendar_today, -10),
      end_date: Date.add(calendar_today, 30)
    }

    [daily, school, legacy, unused]
    |> Enum.map(
      &Map.merge(&1, %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        inserted_at: calendar_now,
        updated_at: calendar_now
      })
    )
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.Calendar, &1))

    [
      {"CAL_DAILY", "Every day service"},
      {"CAL_SCHOOL", "School days"},
      {"CAL_LEGACY", "Legacy service"},
      {"CAL_UNUSED", "Unused calendar"},
      {"CAL_META", "Metadata only"},
      {"svc/odd name", "Odd service id"}
    ]
    |> Enum.map(fn {service_id, description} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        service_id: service_id,
        service_description: description,
        service_schedule_name: nil,
        service_schedule_type: nil,
        service_schedule_typicality: 0,
        rating_start_date: nil,
        rating_end_date: nil,
        rating_description: nil,
        inserted_at: calendar_now,
        updated_at: calendar_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarAttribute, &1))

    [
      {Date.add(calendar_today, 1), 2},
      {Date.add(calendar_today, 2), 2},
      {Date.add(calendar_today, 3), 2},
      {Date.add(calendar_today, 5), 1}
    ]
    |> Enum.map(fn {date, exception_type} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        service_id: if(exception_type == 1, do: "svc/odd name", else: "CAL_SCHOOL"),
        date: date,
        exception_type: exception_type,
        inserted_at: calendar_now,
        updated_at: calendar_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarDate, &1))

    for {service_id, count} <- [{"CAL_DAILY", 3}, {"CAL_SCHOOL", 2}, {"CAL_LEGACY", 1}],
        index <- 1..count do
      {:ok, _trip} =
        GtfsPlanner.GtfsFixtures.insert_trip(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: "CAL_ROUTE",
          trip_id: "CAL_TRIP_#{service_id}_#{index}",
          service_id: service_id,
          trip_headsign: "Calendar scenario"
        })
    end

    IO.puts(
      "Browser seed: 6 calendar identities in #{diagram_version.id} (today #{calendar_today})"
    )

    # ── Calendar coverage details scenario ──
    #
    # The coverage control and its exact-details inspector need shapes the six
    # identities above do not carry: a break of exactly three removed regular
    # service days, added dates inside and after the weekly range, a
    # specific-dates identity and an imported reversed range. A dedicated
    # published version keeps every list assertion on the Browser E2E Version
    # unchanged. Branding once more below leaves that version the current one.
    {:ok, details_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Calendar Details"})

    details_today = Gtfs.DisplayClock.today(org.id, details_version.id).date

    {:ok, _details_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: details_version.id,
        route_id: "BROWSER_DETAILS",
        route_short_name: "BD",
        route_long_name: "Browser calendar details",
        route_type: 3
      })

    [
      %{
        service_id: "DETAIL_SCHOOL",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: Date.add(details_today, -30),
        end_date: Date.add(details_today, 30)
      },
      %{
        service_id: "DETAIL_REVERSED",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: Date.add(details_today, 60),
        end_date: Date.add(details_today, -60)
      },
      # Nine years of service, so the whole-feed view opens on the disclosed recent
      # window: this row keeps exact dates before it and the other rows' marks are
      # compressed into bins the bar draws as approximate.
      %{
        service_id: "DETAIL_LONG",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 0,
        start_date: Date.add(details_today, -3_000),
        end_date: Date.add(details_today, 400)
      }
    ]
    |> Enum.map(
      &Map.merge(&1, %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: details_version.id,
        inserted_at: calendar_now,
        updated_at: calendar_now
      })
    )
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.Calendar, &1))

    [
      {"DETAIL_SCHOOL", "Details school days"},
      {"DETAIL_DATES", "Details specific dates"},
      {"DETAIL_LONG", "Details nine year service"},
      {"DETAIL_REVERSED", "Details reversed range"}
    ]
    |> Enum.map(fn {service_id, description} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: details_version.id,
        service_id: service_id,
        service_description: description,
        service_schedule_typicality: 0,
        inserted_at: calendar_now,
        updated_at: calendar_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarAttribute, &1))

    # Three consecutive removed regular days are a break; one removed day is a day
    # off; the added date inside the weekly range is regular extra service and the
    # two after it are the additions outside the range. The break has to be three
    # consecutive Mon–Fri dates whatever weekday the seed runs and it has to sit
    # clear of the next-weekday date the date-change journey picks, so it is anchored
    # on the Monday two weeks out (a regular service day) and the single day off on
    # the Monday after it.
    break_monday = Date.add(details_today, rem(8 - Date.day_of_week(details_today), 7) + 14)

    [
      {"DETAIL_SCHOOL", break_monday, 2},
      {"DETAIL_SCHOOL", Date.add(break_monday, 1), 2},
      {"DETAIL_SCHOOL", Date.add(break_monday, 2), 2},
      {"DETAIL_SCHOOL", Date.add(break_monday, 7), 2},
      {"DETAIL_SCHOOL", Date.add(break_monday, 5), 1},
      {"DETAIL_SCHOOL", Date.add(details_today, 45), 1},
      {"DETAIL_SCHOOL", Date.add(details_today, 46), 1},
      # Past the near-range window, so the inspector has an exact date outside the
      # drawn timeline.
      {"DETAIL_SCHOOL", Date.add(details_today, 120), 1},
      {"DETAIL_DATES", Date.add(details_today, 7), 1},
      {"DETAIL_DATES", Date.add(details_today, 21), 1}
    ]
    |> Enum.map(fn {service_id, date, exception_type} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: details_version.id,
        service_id: service_id,
        date: date,
        exception_type: exception_type,
        inserted_at: calendar_now,
        updated_at: calendar_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarDate, &1))

    for index <- 1..2 do
      {:ok, _trip} =
        GtfsPlanner.GtfsFixtures.insert_trip(%{
          organization_id: org.id,
          gtfs_version_id: details_version.id,
          route_id: "BROWSER_DETAILS",
          trip_id: "DETAIL_TRIP_#{index}",
          service_id: "DETAIL_SCHOOL",
          trip_headsign: "Calendar details scenario"
        })
    end

    diagram_version
    |> Ecto.Changeset.change(published_at: DateTime.utc_now())
    |> Repo.update!()

    IO.puts(
      "Browser seed: coverage details version #{details_version.id} " <>
        "(today #{details_today})"
    )

    # ── Calendar combination scenario ──
    #
    # One dedicated published version carries every selectable shape the combine review
    # needs, so no journey has to mutate the list versions above: a Saturday destination
    # with the most trips, two moving sources that share a block but never a date (so the
    # reviewed projection really clears it), a specific-dates source, a no-op pair with an
    # identical empty copy, and a weekday calendar that deliberately removes a date the
    # other weekday calendar runs (one conflict). Dates are relative to the version's
    # agency-local today, and the block and transfer rows give the review real findings.
    {:ok, combine_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Calendar Combine"})

    combine_today = Gtfs.DisplayClock.today(org.id, combine_version.id).date

    # The next three Mondays are the specific-dates source's dates, which is what keeps them
    # disjoint from the Sunday source.
    game_day = fn today, index ->
      next_monday = Date.add(today, rem(8 - Date.day_of_week(today), 7) + 7)
      Date.add(next_monday, (index - 1) * 7)
    end

    {:ok, _combine_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: combine_version.id,
        route_id: "COMBINE_ROUTE",
        route_short_name: "CB",
        route_long_name: "Combine scenario route",
        route_type: 3
      })

    combine_stops =
      for index <- 1..2 do
        {:ok, stop} =
          GtfsPlanner.GtfsFixtures.insert_stop(%{
            stop_id: "COMBINE_S#{index}",
            stop_name: "Combine Stop #{index}",
            location_type: 0,
            organization_id: org.id,
            gtfs_version_id: combine_version.id
          })

        stop
      end

    weekly_combine_calendars = [
      %{
        service_id: "COMBINE_SAT",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0,
        start_date: Date.add(combine_today, -60),
        end_date: Date.add(combine_today, 90)
      },
      %{
        service_id: "COMBINE_FALL",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(combine_today, -60),
        end_date: Date.add(combine_today, 30)
      },
      %{
        service_id: "COMBINE_SUN",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 1,
        start_date: Date.add(combine_today, -10),
        end_date: Date.add(combine_today, 40)
      },
      %{
        service_id: "COMBINE_WEEKDAY",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: Date.add(combine_today, -30),
        end_date: Date.add(combine_today, 60)
      },
      %{
        service_id: "COMBINE_WEEKDAY_COPY",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: Date.add(combine_today, -30),
        end_date: Date.add(combine_today, 60)
      },
      %{
        service_id: "COMBINE_HOLIDAY",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: Date.add(combine_today, -30),
        end_date: Date.add(combine_today, 60)
      }
    ]

    weekly_combine_calendars
    |> Enum.map(
      &Map.merge(&1, %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: combine_version.id,
        inserted_at: calendar_now,
        updated_at: calendar_now
      })
    )
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.Calendar, &1))

    [
      {"COMBINE_SAT", "Saturday service"},
      {"COMBINE_FALL", "Fall shuttle"},
      {"COMBINE_SUN", "Sunday shuttle"},
      {"COMBINE_GAMEDAY", "Game day shuttle"},
      {"COMBINE_WEEKDAY", "Weekday service"},
      {"COMBINE_WEEKDAY_COPY", "Weekday service copy"},
      {"COMBINE_HOLIDAY", "Holiday weekdays"}
    ]
    |> Enum.map(fn {service_id, description} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: combine_version.id,
        service_id: service_id,
        service_description: description,
        service_schedule_typicality: 0,
        inserted_at: calendar_now,
        updated_at: calendar_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarAttribute, &1))

    # The specific-dates source stores exactly its own dates, and Holiday weekdays removes one
    # regular Monday–Friday date, which is the one deliberate conflict the review has to label.
    holiday_removal =
      Enum.find(
        Date.range(Date.add(combine_today, 7), Date.add(combine_today, 21)),
        &(Date.day_of_week(&1) == 3)
      )

    [
      {"COMBINE_GAMEDAY", game_day.(combine_today, 1), 1},
      {"COMBINE_GAMEDAY", game_day.(combine_today, 2), 1},
      {"COMBINE_GAMEDAY", game_day.(combine_today, 3), 1},
      {"COMBINE_HOLIDAY", holiday_removal, 2}
    ]
    |> Enum.map(fn {service_id, date, exception_type} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: combine_version.id,
        service_id: service_id,
        date: date,
        exception_type: exception_type,
        inserted_at: calendar_now,
        updated_at: calendar_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarDate, &1))

    # Every block and transfer consequence below comes from real trips with real stop times:
    # the destination and the fall shuttle share block "CB700" and therefore keep it, the
    # Sunday shuttle and the specific-dates trips share block "CB701" without ever sharing a
    # date and are therefore cleared together once they all run on the destination's dates,
    # and the type-4 record between the first two is a real in-seat transfer whose state the
    # move changes.
    [first_stop, _second_stop] = combine_stops

    combine_trips = [
      {"COMBINE_SAT", "COMBINE_TRIP_SAT_1", "CB700", :reverse, {~T[08:00:00], ~T[09:00:00]}},
      {"COMBINE_SAT", "COMBINE_TRIP_SAT_2", nil, :forward, {~T[10:00:00], ~T[11:00:00]}},
      {"COMBINE_SAT", "COMBINE_TRIP_SAT_3", nil, :forward, {~T[12:00:00], ~T[13:00:00]}},
      {"COMBINE_SAT", "COMBINE_TRIP_SAT_4", nil, :forward, {~T[14:00:00], ~T[15:00:00]}},
      {"COMBINE_FALL", "COMBINE_TRIP_FALL_1", "CB700", :forward, {~T[09:10:00], ~T[10:00:00]}},
      {"COMBINE_FALL", "COMBINE_TRIP_FALL_2", "CB700", :forward, {~T[16:00:00], ~T[17:00:00]}},
      {"COMBINE_SUN", "COMBINE_TRIP_SUN_1", "CB701", :forward, {~T[11:00:00], ~T[12:00:00]}},
      {"COMBINE_GAMEDAY", "COMBINE_TRIP_GAME_1", "CB701", :forward, {~T[18:00:00], ~T[19:00:00]}},
      {"COMBINE_GAMEDAY", "COMBINE_TRIP_GAME_2", "CB701", :forward, {~T[20:00:00], ~T[21:00:00]}},
      {"COMBINE_WEEKDAY", "COMBINE_TRIP_WEEKDAY_1", nil, :forward, {~T[06:00:00], ~T[07:00:00]}},
      {"COMBINE_WEEKDAY", "COMBINE_TRIP_WEEKDAY_2", nil, :forward, {~T[07:30:00], ~T[08:30:00]}}
    ]

    Enum.each(combine_trips, fn {service_id, trip_id, block_id, direction, {arrival, departure}} ->
      attrs =
        %{
          service_id: service_id,
          trip_id: trip_id,
          trip_headsign: "Combine scenario"
        }
        |> Map.put(:block_id, block_id)

      trip =
        GtfsPlanner.GtfsFixtures.trip_fixture(org.id, combine_version.id, "COMBINE_ROUTE", attrs)

      stop_order = if direction == :reverse, do: Enum.reverse(combine_stops), else: combine_stops

      for {stop, index} <- Enum.with_index(stop_order, 1) do
        {arrival_time, departure_time} =
          if index == 1,
            do: {"#{arrival}", "#{arrival}"},
            else: {"#{departure}", "#{departure}"}

        GtfsPlanner.GtfsFixtures.stop_time_fixture(
          org.id,
          combine_version.id,
          trip.trip_id,
          stop.stop_id,
          %{
            arrival_time: arrival_time,
            departure_time: departure_time,
            stop_sequence: index
          }
        )
      end
    end)

    GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, combine_version.id, %{
      from_trip_id: "COMBINE_TRIP_SAT_1",
      to_trip_id: "COMBINE_TRIP_FALL_1",
      from_stop_id: first_stop.stop_id,
      to_stop_id: first_stop.stop_id,
      transfer_type: 4
    })

    IO.puts(
      "Browser seed: calendar combination version #{combine_version.id} " <>
        "(today #{combine_today}, conflict #{holiday_removal})"
    )

    # Branding once more leaves the Browser E2E Version the current one, so the version panel
    # and every existing list assertion stay as they were.
    diagram_version
    |> Ecto.Changeset.change(published_at: DateTime.utc_now())
    |> Repo.update!()

    # ── Route schedules read view (Schedules tab) ──
    #
    # Three isolated routes on the shared Browser E2E Version cover the Schedules
    # read view: SCHEDULES_READY carries both directions, a linked series, a
    # frequency window, a custom trip whose stops differ and unlinked trips;
    # SCHEDULES_WIDE carries a 72-occurrence pattern for the All-stops scroll;
    # SCHEDULES_EMPTY has no patterns. A second published version with no
    # calendars gives the no-calendars state. Every record is read-only for the
    # journeys, and step 7 adds its own mutating scenario routes.
    schedule_stops =
      Enum.map(1..6, fn index ->
        {:ok, stop} =
          GtfsPlanner.GtfsFixtures.insert_stop(%{
            stop_id: "BSS_#{index}",
            stop_name: "Schedule Stop #{index}",
            location_type: 0,
            organization_id: org.id,
            gtfs_version_id: diagram_version.id
          })

        stop
      end)

    schedule_routes =
      [
        {"BROWSER_SCHEDULES_READY", "SR", "Browser Schedules Ready"},
        {"BROWSER_SCHEDULES_WIDE", "SW", "Browser Schedules Wide"},
        {"BROWSER_SCHEDULES_EMPTY", "SE", "Browser Schedules Empty"}
      ]
      |> Enum.map(fn {route_id, short_name, long_name} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3
          })

        route
      end)
      |> Map.new(&{&1.route_id, &1})

    ready_route = Map.fetch!(schedule_routes, "BROWSER_SCHEDULES_READY")

    ready = %{
      service_id: "CAL_DAILY",
      stops: [
        {"BSS_1", 0, 0, 1},
        {"BSS_2", 300, 360, 1},
        {"BSS_3", 660, 720, 0},
        {"BSS_4", 1020, 1080, 0},
        {"BSS_5", 1500, 1560, 1}
      ]
    }

    ready_pattern =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: ready_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-SCHED-P1",
        route_pattern_name: "Downtown – Valley College",
        route_pattern_typicality: 1,
        timing_name: "Weekday daytime",
        timing_headsign: "Valley College",
        stops: ready.stops
      })

    for {trip_id, start_time, short_name} <- [
          {"BROWSER_SCHED_T1", "06:00:00", "1201"},
          {"BROWSER_SCHED_T2", "06:30:00", "1202"},
          {"BROWSER_SCHED_T3", "07:00:00", "1203"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        ready_route.route_id,
        ready_pattern,
        %{
          service_id: ready.service_id,
          trip_id: trip_id,
          trip_short_name: short_name,
          start_time: start_time,
          trip_headsign: "Valley College",
          block_id: "SR-1"
        }
      )
    end

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      ready_route.route_id,
      ready_pattern,
      %{
        service_id: ready.service_id,
        trip_id: "BROWSER_SCHED_FREQ",
        trip_short_name: "1206",
        start_time: "09:00:00",
        trip_headsign: "Valley College",
        frequencies: [%{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1200}]
      }
    )

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      ready_route.route_id,
      ready_pattern,
      %{
        service_id: ready.service_id,
        trip_id: "BROWSER_SCHED_CUSTOM",
        trip_short_name: "1205",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Valley College",
        stop_times: [
          {"BSS_1", "09:00:00", "09:00:00"},
          {"BSS_4", "09:20:00", "09:20:00"},
          {"BSS_3", "09:40:00", "09:40:00"}
        ]
      }
    )

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      ready_route.route_id,
      ready_pattern,
      %{
        service_id: ready.service_id,
        trip_id: "BROWSER_SCHED_NOTIME",
        trip_short_name: "1207",
        stop_times: [
          {"BSS_1", nil, nil},
          {"BSS_2", nil, nil}
        ]
      }
    )

    for {trip_id, start_time} <- [
          {"BROWSER_SCHED_UNLINKED_1", "06:00:00"},
          {"BROWSER_SCHED_UNLINKED_2", "10:00:00"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        ready_route.route_id,
        ready_pattern,
        %{
          service_id: ready.service_id,
          trip_id: trip_id,
          start_time: start_time,
          state: "custom",
          timed_pattern_id: nil,
          route_pattern_id: nil
        }
      )
    end

    GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
      route_id: ready_route.route_id,
      direction_id: 1,
      route_pattern_id: "BROWSER-SCHED-P2",
      route_pattern_name: "Valley College – Downtown",
      route_pattern_typicality: 1,
      timing_name: "Weekday daytime",
      stops: [
        {"BSS_5", 0, 0, 1},
        {"BSS_2", 300, 360, 1},
        {"BSS_1", 660, 720, 1}
      ]
    })

    wide_route = Map.fetch!(schedule_routes, "BROWSER_SCHEDULES_WIDE")

    wide_pattern =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: wide_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-SCHED-PW",
        route_pattern_name: "Wide pattern",
        route_pattern_typicality: 1,
        timing_name: "All day",
        timing_headsign: "Wide outbound",
        stops:
          1..12
          |> Enum.flat_map(fn _round -> schedule_stops end)
          |> Enum.with_index()
          |> Enum.map(fn {stop, index} ->
            {stop.stop_id, index * 120, index * 120 + 30, if(index in [0, 71], do: 1, else: 0)}
          end)
      })

    for {trip_id, start_time, short_name} <- [
          {"BROWSER_SCHED_WIDE_1", "05:00:00", "2101"},
          {"BROWSER_SCHED_WIDE_2", "05:30:00", "2102"},
          {"BROWSER_SCHED_WIDE_3", "06:00:00", "2103"},
          {"BROWSER_SCHED_WIDE_4", "06:30:00", "2104"},
          {"BROWSER_SCHED_WIDE_5", "07:00:00", "2105"},
          {"BROWSER_SCHED_WIDE_6", "07:30:00", "2106"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        wide_route.route_id,
        wide_pattern,
        %{
          service_id: "CAL_DAILY",
          trip_id: trip_id,
          trip_short_name: short_name,
          start_time: start_time,
          trip_headsign: "Wide outbound"
        }
      )
    end

    IO.puts(
      "Browser seed: schedule routes (ready with both directions and trip states, " <>
        "wide with 72 stops, empty without patterns)"
    )

    # ── Route schedules mutation scenarios (step 7) ──
    #
    # One isolated route carries every drawer and bulk action: two direction-0
    # patterns, a 62-occurrence pattern for the wide All-stops table, a linked
    # series with an adjacent pair so a delete moves the vehicle count, a
    # frequency window, a custom trip whose stops differ, a compatible custom trip
    # for adoption, and an after-midnight departure for the +1 marker. These
    # routes are mutated by the journeys, so they are seeded on their own route.
    {:ok, mutate_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_SCHEDULES_MUTATE",
        route_short_name: "SM",
        route_long_name: "Browser Schedules Mutate",
        route_type: 3
      })

    mutate_primary =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: mutate_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-SCHED-PM1",
        route_pattern_name: "Mutate primary",
        route_pattern_typicality: 1,
        timing_name: "All day",
        timing_headsign: "Mutate outbound",
        stops:
          1..10
          |> Enum.flat_map(fn _round -> schedule_stops end)
          |> Enum.concat(Enum.take(schedule_stops, 2))
          |> Enum.with_index()
          |> Enum.map(fn {stop, index} ->
            {stop.stop_id, index * 120, if(index == 0, do: 0, else: index * 120 + 30),
             if(index in [0, 61], do: 1, else: 0)}
          end)
      })

    for {trip_id, start_time, short_name} <- [
          {"SM_T1", "06:00:00", "3101"},
          {"SM_T2", "06:05:00", "3102"},
          {"SM_T3", "07:00:00", "3103"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        mutate_route.route_id,
        mutate_primary,
        %{
          service_id: "CAL_DAILY",
          trip_id: trip_id,
          trip_short_name: short_name,
          start_time: start_time,
          trip_headsign: "Mutate outbound",
          block_id: "SM-1"
        }
      )
    end

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      mutate_route.route_id,
      mutate_primary,
      %{
        service_id: "CAL_DAILY",
        trip_id: "SM_FREQ",
        trip_short_name: "3104",
        start_time: "09:00:00",
        trip_headsign: "Mutate outbound",
        frequencies: [%{start_time: "09:00:00", end_time: "12:00:00", headway_secs: 1200}]
      }
    )

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      mutate_route.route_id,
      mutate_primary,
      %{
        service_id: "CAL_DAILY",
        trip_id: "SM_CUSTOM_DIFF",
        trip_short_name: "3105",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Mutate outbound",
        stop_times: [
          {"BSS_1", "10:00:00", "10:00:00"},
          {"BSS_4", "10:20:00", "10:20:00"},
          {"BSS_3", "10:40:00", "10:40:00"}
        ]
      }
    )

    mutate_secondary =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: mutate_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-SCHED-PM2",
        route_pattern_name: "Mutate secondary",
        route_pattern_typicality: 3,
        timing_name: "Secondary",
        timing_headsign: "Mutate secondary",
        stops: [
          {"BSS_1", 0, 0, 1},
          {"BSS_2", 300, 360, 1},
          {"BSS_3", 660, 720, 0},
          {"BSS_4", 1020, 1080, 0},
          {"BSS_5", 1500, 1560, 1},
          {"BSS_6", 1800, 1860, 1}
        ]
      })

    for {trip_id, start_time, short_name} <- [
          {"SM_P2_1", "08:00:00", "3201"},
          {"SM_P2_2", "08:30:00", "3202"},
          {"SM_LATE", "25:10:00", "3203"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        mutate_route.route_id,
        mutate_secondary,
        %{
          service_id: "CAL_DAILY",
          trip_id: trip_id,
          trip_short_name: short_name,
          start_time: start_time,
          trip_headsign: "Mutate secondary",
          block_id: "SM-2"
        }
      )
    end

    # A compatible custom trip: its ordered stops equal the pattern's occurrences,
    # so the Edit drawer offers the pattern's timings.
    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      mutate_route.route_id,
      mutate_secondary,
      %{
        service_id: "CAL_DAILY",
        trip_id: "SM_P2_CUSTOM",
        trip_short_name: "3204",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Mutate secondary",
        stop_times: [
          {"BSS_1", "08:45:00", "08:45:00"},
          {"BSS_2", "08:50:00", "08:51:00"},
          {"BSS_3", "08:56:00", "08:57:00"},
          {"BSS_4", "09:02:00", "09:03:00"},
          {"BSS_5", "09:10:00", "09:11:00"},
          {"BSS_6", "09:15:00", "09:15:00"}
        ]
      }
    )

    IO.puts(
      "Browser seed: schedule mutation route BROWSER_SCHEDULES_MUTATE " <>
        "(62-occurrence pattern, linked series, frequency, custom and after-midnight trips)"
    )

    # ── Timetable paste fixture (step 20) ──
    #
    # One isolated route on the shared Browser E2E Version carries the paste
    # journeys' schedule, mirroring the prototype's route 12 Downtown –
    # Riverside: nine BPS stops, five patterns (main with Typical and Peak
    # timings, short, school, loop, inbound), seven Weekday trips per direction
    # on blocks 101–103, two school trips and one school frequency template on
    # the school pattern, two loop trips that board Central Station twice, a
    # Christmas Eve exception on the Weekday calendar, and two timed transfers
    # at Riverside Terminal naming trip 1209.
    for {stop_id, stop_name} <- [
          {"BPS_CEN", "Central Station"},
          {"BPS_MKT", "Market Street"},
          {"BPS_OAK", "Oak & 3rd"},
          {"BPS_MILL", "Mill Street"},
          {"BPS_NSCH", "Northside School"},
          {"BPS_LIB", "Library"},
          {"BPS_HOSP", "Hospital"},
          {"BPS_RPK", "River Park"},
          {"BPS_RIV", "Riverside Terminal"}
        ] do
      {:ok, _stop} =
        GtfsPlanner.GtfsFixtures.insert_stop(%{
          stop_id: stop_id,
          stop_name: stop_name,
          location_type: 0,
          organization_id: org.id,
          gtfs_version_id: diagram_version.id
        })
    end

    {:ok, paste_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_PASTE",
        route_short_name: "12",
        route_long_name: "Downtown – Riverside",
        route_type: 3
      })

    paste_calendar =
      GtfsPlanner.BlockingFixtures.calendar_service_fixture(org.id, diagram_version.id, %{
        service_id: "BPS_WKDY",
        name: "Weekday",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-09-08],
        end_date: ~D[2027-06-25]
      })

    paste_main =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: paste_route.route_id,
        direction_id: 0,
        route_pattern_id: "BPS-MAIN",
        route_pattern_name: "Central Station → Riverside Terminal",
        route_pattern_typicality: 1,
        headsign: "Riverside Terminal",
        timing_name: "Typical",
        timing_headsign: "Riverside Terminal",
        stops: [
          {"BPS_CEN", 0, 0, 1},
          {"BPS_MKT", 180, 180, 0},
          {"BPS_OAK", 360, 360, 0},
          {"BPS_MILL", 600, 600, 1},
          {"BPS_LIB", 840, 840, 0},
          {"BPS_HOSP", 1080, 1080, 1},
          {"BPS_RPK", 1440, 1440, 0},
          {"BPS_RIV", 1680, 1680, 1}
        ]
      })

    paste_peak =
      GtfsPlanner.GtfsFixtures.timed_pattern_fixture(paste_main.pattern, %{name: "Peak"})

    [0, 4, 8, 13, 18, 23, 30, 35]
    |> Enum.map(&(&1 * 60))
    |> Enum.zip(paste_main.occurrences)
    |> Enum.zip([1, 0, 0, 1, 0, 1, 0, 1])
    |> Enum.each(fn {{offset, occurrence}, timepoint} ->
      GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(paste_peak, occurrence, %{
        arrival_offset: offset,
        departure_offset: offset,
        timepoint: timepoint
      })
    end)

    GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
      route_id: paste_route.route_id,
      direction_id: 0,
      route_pattern_id: "BPS-SHORT",
      route_pattern_name: "Central Station → Hospital",
      route_pattern_sort_order: 1,
      headsign: "Hospital",
      timing_name: "Typical",
      timing_headsign: "Hospital",
      stops: [
        {"BPS_CEN", 0, 0, 1},
        {"BPS_MKT", 180, 180, 0},
        {"BPS_OAK", 360, 360, 0},
        {"BPS_MILL", 600, 600, 1},
        {"BPS_LIB", 840, 840, 0},
        {"BPS_HOSP", 1080, 1080, 1}
      ]
    })

    paste_school =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: paste_route.route_id,
        direction_id: 0,
        route_pattern_id: "BPS-SCHOOL",
        route_pattern_name: "Central Station → Hospital via Northside School",
        route_pattern_sort_order: 2,
        headsign: "Hospital",
        timing_name: "School days",
        timing_headsign: "Hospital",
        stops: [
          {"BPS_CEN", 0, 0, 1},
          {"BPS_MKT", 180, 180, 0},
          {"BPS_OAK", 360, 360, 0},
          {"BPS_MILL", 600, 600, 1},
          {"BPS_NSCH", 900, 900, 1},
          {"BPS_LIB", 1140, 1140, 0},
          {"BPS_HOSP", 1380, 1380, 1}
        ]
      })

    paste_inbound =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: paste_route.route_id,
        direction_id: 1,
        route_pattern_id: "BPS-INBOUND",
        route_pattern_name: "Riverside Terminal → Central Station",
        route_pattern_typicality: 1,
        headsign: "Central Station",
        timing_name: "Typical",
        timing_headsign: "Central Station",
        stops: [
          {"BPS_RIV", 0, 0, 1},
          {"BPS_RPK", 240, 240, 0},
          {"BPS_HOSP", 600, 600, 1},
          {"BPS_LIB", 840, 840, 0},
          {"BPS_MILL", 1080, 1080, 1},
          {"BPS_OAK", 1320, 1320, 0},
          {"BPS_MKT", 1500, 1500, 0},
          {"BPS_CEN", 1680, 1680, 1}
        ]
      })

    [
      {paste_main, "Riverside Terminal", 1201,
       ["06:00:00", "06:30:00", "07:00:00", "07:30:00", "08:00:00", "08:30:00", "09:00:00"]},
      {paste_inbound, "Central Station", 1202,
       ["06:35:00", "07:05:00", "07:35:00", "08:05:00", "08:35:00", "09:05:00", "09:35:00"]}
    ]
    |> Enum.each(fn {bundle, headsign, first_short, start_times} ->
      start_times
      |> Enum.with_index()
      |> Enum.each(fn {start_time, index} ->
        short = Integer.to_string(first_short + index * 2)

        GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
          org.id,
          diagram_version.id,
          paste_route.route_id,
          bundle,
          %{
            service_id: paste_calendar.service_id,
            trip_id: "BPS_#{short}",
            trip_short_name: short,
            start_time: start_time,
            trip_headsign: headsign,
            block_id: Integer.to_string(101 + rem(index, 3))
          }
        )
      end)
    end)

    # The school pattern carries its own Weekday trips so a reviewed source
    # can be compared against a pattern that is not the default one: two
    # listed trips at 06:10 and 07:10, and one frequency template at 08:00
    # that no comparison may expand into invented matches or differences.
    ["06:10:00", "07:10:00"]
    |> Enum.with_index()
    |> Enum.each(fn {start_time, index} ->
      short = Integer.to_string(1301 + index * 2)

      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        paste_route.route_id,
        paste_school,
        %{
          service_id: paste_calendar.service_id,
          trip_id: "BPS_#{short}",
          trip_short_name: short,
          start_time: start_time,
          trip_headsign: "Hospital",
          block_id: "105"
        }
      )
    end)

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      paste_route.route_id,
      paste_school,
      %{
        service_id: paste_calendar.service_id,
        trip_id: "BPS_1400",
        trip_short_name: "1400",
        start_time: "08:00:00",
        trip_headsign: "Hospital",
        block_id: "105",
        frequencies: [
          %{start_time: "08:00:00", end_time: "09:00:00", headway_secs: 1200, exact_times: 0}
        ]
      }
    )

    # A loop pattern boards Central Station twice, so a pasted table that names
    # it twice has two occurrences to compare rather than one merged visit.
    paste_loop =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: paste_route.route_id,
        direction_id: 0,
        route_pattern_id: "BPS-LOOP",
        route_pattern_name: "Riverside Terminal loop via Central Station",
        route_pattern_sort_order: 3,
        headsign: "Riverside Terminal",
        timing_name: "Typical",
        timing_headsign: "Riverside Terminal",
        stops: [
          {"BPS_CEN", 0, 0, 1},
          {"BPS_MKT", 300, 300, 0},
          {"BPS_CEN", 600, 600, 1},
          {"BPS_RIV", 900, 900, 1}
        ]
      })

    ["06:20:00", "07:20:00"]
    |> Enum.with_index()
    |> Enum.each(fn {start_time, index} ->
      short = Integer.to_string(1501 + index * 2)

      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        paste_route.route_id,
        paste_loop,
        %{
          service_id: paste_calendar.service_id,
          trip_id: "BPS_#{short}",
          trip_short_name: short,
          start_time: start_time,
          trip_headsign: "Riverside Terminal",
          block_id: "107"
        }
      )
    end)

    # Christmas Eve is a Weekday Thursday the feed does not run, so a reviewed
    # source that keeps it is compared against the calendar exception rather
    # than against the weekly pattern it reads like.
    GtfsPlanner.GtfsFixtures.calendar_date_fixture(org.id, diagram_version.id, %{
      service_id: paste_calendar.service_id,
      date: ~D[2026-12-24],
      exception_type: 2
    })

    # Trip 1209 (08:00 outbound) feeds timed transfers at Riverside Terminal:
    # it receives from 1207 and continues onto 1210.
    for {from_trip_id, to_trip_id} <- [{"BPS_1207", "BPS_1209"}, {"BPS_1209", "BPS_1210"}] do
      GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, diagram_version.id, %{
        from_stop_id: "BPS_RIV",
        to_stop_id: "BPS_RIV",
        from_trip_id: from_trip_id,
        to_trip_id: to_trip_id,
        transfer_type: 2,
        min_transfer_time: 180
      })
    end

    paste_trip_count =
      Repo.aggregate(
        from(t in Gtfs.Trip,
          where:
            t.organization_id == ^org.id and t.gtfs_version_id == ^diagram_version.id and
              t.route_id == ^paste_route.route_id
        ),
        :count
      )

    paste_transfer_count =
      Repo.aggregate(
        from(tr in Transfer,
          where:
            tr.organization_id == ^org.id and tr.gtfs_version_id == ^diagram_version.id and
              (tr.from_trip_id == "BPS_1209" or tr.to_trip_id == "BPS_1209")
        ),
        :count
      )

    IO.puts(
      "Browser seed: paste route BROWSER_PASTE (5 patterns, Typical and Peak timings, " <>
        "#{paste_trip_count} Weekday trips including one school frequency template, " <>
        "#{paste_transfer_count} transfers naming trip 1209)"
    )

    # ── Advanced trip editing journey routes (spec 18, step 41) ──
    #
    # Three routes on the shared Browser E2E Version and its existing CAL_DAILY
    # calendar carry the advanced trip editing browser journeys. No calendar and
    # no version is added, so the calendars page keeps its six identities and the
    # organization's latest published default stays the Browser E2E Version.
    #
    #   * BROWSER_SCHEDULES_GRID — one direction-0 pattern with a Base timing and
    #     a faster Peak timing, twelve listed CAL_DAILY trips including a
    #     two-trip block (SG-1) and one custom trip, and no CAL_SCHOOL trips;
    #   * BROWSER_SCHEDULES_FREQ — one direction-0 pattern whose only trip carries
    #     a 09:00–10:00 frequency window every ten minutes on CAL_DAILY;
    #   * BROWSER_SCHEDULES_BULK — one direction-0 pattern with 500 listed
    #     CAL_DAILY trips for the grid's latency observation, inserted with
    #     chunked insert_all because this is scenario data, not an audited edit.
    advanced_stops = [
      {"BSS_1", 0, 0, 1},
      {"BSS_2", 300, 360, 1},
      {"BSS_3", 660, 720, 0},
      {"BSS_4", 1020, 1080, 0},
      {"BSS_5", 1500, 1560, 1},
      {"BSS_6", 1800, 1860, 1}
    ]

    {:ok, grid_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_SCHEDULES_GRID",
        route_short_name: "SG",
        route_long_name: "Browser Schedules Grid",
        route_type: 3
      })

    grid_pattern =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: grid_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-SCHED-PG1",
        route_pattern_name: "Grid outbound",
        route_pattern_typicality: 1,
        timing_name: "Base",
        timing_headsign: "Grid outbound",
        stops: advanced_stops
      })

    # The Peak timing is the same pattern's faster variant: the same stopping
    # pattern with shorter runs between the stops, so trips can link to either.
    grid_peak =
      GtfsPlanner.GtfsFixtures.timed_pattern_fixture(grid_pattern.pattern, %{
        name: "Peak",
        headsign: "Grid outbound"
      })

    grid_peak_offsets = [
      {0, 0},
      {240, 300},
      {540, 600},
      {900, 960},
      {1260, 1320},
      {1500, 1560}
    ]

    for {occurrence, {arrival_offset, departure_offset}} <-
          Enum.zip(grid_pattern.occurrences, grid_peak_offsets) do
      GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(grid_peak, occurrence, %{
        arrival_offset: arrival_offset,
        departure_offset: departure_offset,
        timepoint: 1
      })
    end

    # The fixture materializes a linked trip from the pattern timing it is given
    # in the bundle (the Base timing), so a Peak-linked trip states its own rows.
    peak_stop_times = fn start_secs ->
      Enum.zip(grid_pattern.occurrences, grid_peak_offsets)
      |> Enum.map(fn {occurrence, {arrival_offset, departure_offset}} ->
        {occurrence.stop_id, GtfsPlanner.Gtfs.GtfsTime.format(start_secs + arrival_offset),
         GtfsPlanner.Gtfs.GtfsTime.format(start_secs + departure_offset)}
      end)
    end

    for {trip_id, start_time, short_name, block_id} <- [
          {"BSG_T01", "05:00:00", "9101", nil},
          {"BSG_T02", "05:30:00", "9102", "SG-1"},
          {"BSG_T03", "06:00:00", "9103", "SG-1"},
          {"BSG_T04", "06:30:00", "9104", nil},
          {"BSG_T05", "07:00:00", "9105", nil},
          {"BSG_T06", "07:30:00", "9106", nil}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        grid_route.route_id,
        grid_pattern,
        %{
          service_id: "CAL_DAILY",
          trip_id: trip_id,
          trip_short_name: short_name,
          start_time: start_time,
          trip_headsign: "Grid outbound",
          block_id: block_id
        }
      )
    end

    for {trip_id, start_secs, short_name} <- [
          {"BSG_T07", 8 * 3600, "9107"},
          {"BSG_T08", 8 * 3600 + 1800, "9108"},
          {"BSG_T09", 9 * 3600, "9109"},
          {"BSG_T10", 9 * 3600 + 1800, "9110"},
          {"BSG_T11", 10 * 3600, "9111"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        diagram_version.id,
        grid_route.route_id,
        grid_pattern,
        %{
          service_id: "CAL_DAILY",
          trip_id: trip_id,
          trip_short_name: short_name,
          trip_headsign: "Grid outbound",
          timed_pattern_id: grid_peak.id,
          stop_times: peak_stop_times.(start_secs)
        }
      )
    end

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      grid_route.route_id,
      grid_pattern,
      %{
        service_id: "CAL_DAILY",
        trip_id: "BSG_CUSTOM",
        trip_short_name: "9112",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Grid outbound",
        stop_times: [
          {"BSS_1", "11:00:00", "11:00:00"},
          {"BSS_2", "11:05:00", "11:06:00"},
          {"BSS_3", "11:11:00", "11:12:00"},
          {"BSS_4", "11:17:00", "11:18:00"},
          {"BSS_5", "11:25:00", "11:26:00"},
          {"BSS_6", "11:30:00", "11:30:00"}
        ]
      }
    )

    IO.puts(
      "Browser seed: BROWSER_SCHEDULES_GRID (Base and Peak timings, 12 listed " <>
        "CAL_DAILY trips with one two-trip block and one custom trip, none on CAL_SCHOOL)"
    )

    {:ok, freq_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_SCHEDULES_FREQ",
        route_short_name: "SF",
        route_long_name: "Browser Schedules Frequency",
        route_type: 3
      })

    freq_pattern =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: freq_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-SCHED-PF1",
        route_pattern_name: "Frequency outbound",
        route_pattern_typicality: 1,
        timing_name: "All day",
        timing_headsign: "Frequency outbound",
        stops: advanced_stops
      })

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      diagram_version.id,
      freq_route.route_id,
      freq_pattern,
      %{
        service_id: "CAL_DAILY",
        trip_id: "BSF_T1",
        trip_short_name: "9201",
        start_time: "09:00:00",
        trip_headsign: "Frequency outbound",
        frequencies: [%{start_time: "09:00:00", end_time: "10:00:00", headway_secs: 600}]
      }
    )

    IO.puts(
      "Browser seed: BROWSER_SCHEDULES_FREQ (one frequency trip 09:00-10:00 " <>
        "every 10 min on CAL_DAILY)"
    )

    {:ok, bulk_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_SCHEDULES_BULK",
        route_short_name: "SB",
        route_long_name: "Browser Schedules Bulk",
        route_type: 3
      })

    bulk_pattern =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, diagram_version.id, %{
        route_id: bulk_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-SCHED-PB1",
        route_pattern_name: "Bulk outbound",
        route_pattern_typicality: 1,
        timing_name: "All day",
        timing_headsign: "Bulk outbound",
        stops: advanced_stops
      })

    bulk_now = DateTime.utc_now()
    bulk_first_departure = 5 * 3600

    bulk_trip_id = fn index ->
      "BSB_T" <> String.pad_leading(Integer.to_string(index), 3, "0")
    end

    bulk_trips =
      for index <- 1..500 do
        %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: bulk_route.route_id,
          service_id: "CAL_DAILY",
          trip_id: bulk_trip_id.(index),
          trip_short_name: String.pad_leading(Integer.to_string(index), 3, "0"),
          trip_headsign: "Bulk outbound",
          direction_id: 0,
          route_pattern_id: bulk_pattern.pattern.route_pattern_id,
          timed_pattern_id: bulk_pattern.timing.id,
          pattern_derivation_state: "linked",
          pattern_derivation_reason: nil,
          inserted_at: bulk_now,
          updated_at: bulk_now
        }
      end

    bulk_stop_times =
      for index <- 1..500,
          {{stop_id, arrival_offset, departure_offset, timepoint}, sequence} <-
            Enum.with_index(advanced_stops, 1) do
        start_secs = bulk_first_departure + (index - 1) * 60

        %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          trip_id: bulk_trip_id.(index),
          stop_id: stop_id,
          stop_sequence: sequence,
          arrival_time: GtfsPlanner.Gtfs.GtfsTime.format(start_secs + arrival_offset),
          departure_time: GtfsPlanner.Gtfs.GtfsTime.format(start_secs + departure_offset),
          timepoint: timepoint,
          inserted_at: bulk_now,
          updated_at: bulk_now
        }
      end

    Enum.each(Enum.chunk_every(bulk_trips, 100), &Repo.insert_all(Trip, &1))
    Enum.each(Enum.chunk_every(bulk_stop_times, 500), &Repo.insert_all(StopTime, &1))

    IO.puts(
      "Browser seed: BROWSER_SCHEDULES_BULK (500 listed CAL_DAILY trips over one " <>
        "pattern, chunked insert_all)"
    )

    # ── Blocks browser journey (EV-28, step 29) ──
    #
    # A published "Browser Blocks Version" carries the Blocks page's own day types
    # and records, isolated from every other scenario by its version and by its
    # `BB_`/`BB-` names:
    #
    #   * two weekday calendars that share dates — "Weekday service" every weekday
    #     and "School days" on Monday, Wednesday and Friday — plus a Saturday
    #     calendar, so the derived day types are {SCHOOL, WEEK} (largest, the page's
    #     default), {WEEK} alone and {SAT};
    #   * 34 blocks on the largest day type: 21 ordinary two-trip blocks plus the
    #     interlining, after-midnight, 5-minute, nested-overlap, short-layover,
    #     120 m handoff, 340 m empty-move, matching-record, stale-record, cross-day
    #     overlap, assignment-target and busiest blocks;
    #   * 130 unassigned trips over two pool pages, including a frequency trip and a
    #     trip whose endpoint times are missing;
    #   * a trip that runs on both weekday day types and is assigned by the journey
    #     to the block whose school-day trip it overlaps only on the larger day type;
    #   * one matching and one stale type-4 transfer record.
    blocks_version_name = "Browser Blocks Version"

    {:ok, blocks_version} =
      Versions.create_gtfs_version(org.id, %{name: blocks_version_name})

    block_week_start = ~D[2026-09-07]
    block_week_end = ~D[2026-10-30]

    GtfsPlanner.BlockingFixtures.calendar_service_fixture(org.id, blocks_version.id, %{
      service_id: "BB_WEEK",
      name: "Weekday service",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: block_week_start,
      end_date: block_week_end
    })

    GtfsPlanner.BlockingFixtures.calendar_service_fixture(org.id, blocks_version.id, %{
      service_id: "BB_SCHOOL",
      name: "School days",
      monday: 1,
      tuesday: 0,
      wednesday: 1,
      thursday: 0,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: block_week_start,
      end_date: block_week_end
    })

    GtfsPlanner.BlockingFixtures.calendar_service_fixture(org.id, blocks_version.id, %{
      service_id: "BB_SAT",
      name: "Saturday service",
      monday: 0,
      tuesday: 0,
      wednesday: 0,
      thursday: 0,
      friday: 0,
      saturday: 1,
      sunday: 0,
      start_date: block_week_start,
      end_date: block_week_end
    })

    # Every block-route handoff uses one of these stops, so a layover is a same-stop
    # handoff unless a block deliberately moves the vehicle: BB_S6→BB_S7 is 120 m
    # (a nearby handoff, no notice) and BB_S8→BB_S9 is 340 m (an empty move, the
    # `:repositions` notice).
    block_stops =
      [
        {"BB_S1", 40.7500, -73.9900},
        {"BB_S2", 40.7550, -73.9850},
        {"BB_S3", 40.7600, -73.9800},
        {"BB_S4", 40.7650, -73.9750},
        {"BB_S5", 40.7700, -73.9700},
        {"BB_S6", 40.7800, -73.9600},
        {"BB_S7", 40.7810782, -73.9600},
        {"BB_S8", 40.7900, -73.9500},
        {"BB_S9", 40.7930540, -73.9500}
      ]
      |> Map.new(fn {stop_id, lat, lon} ->
        stop =
          GtfsPlanner.GtfsFixtures.stop_fixture(org.id, blocks_version.id, %{
            stop_id: stop_id,
            stop_name: "Blocks stop #{stop_id}",
            stop_lat: lat,
            stop_lon: lon
          })

        {stop_id, stop}
      end)

    block_routes =
      [{"BB_R1", "BR1", "Blocks Riverside"}, {"BB_R2", "BR2", "Blocks Central"}]
      |> Map.new(fn {route_id, short_name, long_name} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: blocks_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3,
            route_color: "0055AA"
          })

        {route_id, route}
      end)

    # `HH:MM:SS` from seconds after midnight, so the block times stay readable and
    # the after-midnight block is written as 24:30:00 instead of 00:30:00.
    block_clock = fn secs ->
      period = rem(secs, 86_400)

      [div(period, 3600), div(rem(period, 3600), 60), rem(period, 60)]
      |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
    end

    block_trip = fn attrs ->
      attrs = Map.new(attrs)
      route_id = Map.fetch!(attrs, :route_id)

      stop_times =
        %{
          first_stop: Map.get(attrs, :first_stop, "BB_S1"),
          last_stop: Map.get(attrs, :last_stop, "BB_S1"),
          first_arrival: "08:00:00",
          last_arrival: "08:30:00"
        }
        |> Map.merge(
          Map.take(attrs, [:first_arrival, :first_departure, :last_arrival, :last_departure])
        )

      GtfsPlanner.BlockingFixtures.blocked_trip_fixture(
        org.id,
        blocks_version.id,
        Map.fetch!(block_routes, route_id).route_id,
        Map.merge(stop_times, %{
          trip_id: Map.fetch!(attrs, :trip_id),
          service_id: Map.get(attrs, :service_id, "BB_WEEK"),
          block_id: Map.get(attrs, :block_id),
          trip_headsign: Map.get(attrs, :trip_headsign, "Blocks journey")
        })
      )
    end

    # 21 ordinary blocks: two 15-minute trips 25 minutes apart, both handoffs at
    # BB_S2, so the block has no findings. The first trip of the first block leaves
    # at 05:00, which is the day's earliest departure and the axis floor.
    for index <- 1..21 do
      block_id = "BB-" <> String.pad_leading(Integer.to_string(index), 2, "0")
      base = 300 + (index - 1) * 22

      block_trip.(%{
        trip_id: "BB_T#{index}A",
        route_id: "BB_R1",
        block_id: block_id,
        first_arrival: block_clock.(base * 60),
        last_arrival: block_clock.((base + 15) * 60),
        first_stop: "BB_S1",
        last_stop: "BB_S2"
      })

      block_trip.(%{
        trip_id: "BB_T#{index}B",
        route_id: "BB_R1",
        block_id: block_id,
        first_arrival: block_clock.((base + 40) * 60),
        last_arrival: block_clock.((base + 55) * 60),
        first_stop: "BB_S2",
        last_stop: "BB_S1"
      })
    end

    # BB-LONG carries the journey's known Zoom bar: three hours of a 21-hour axis,
    # far above the bar's 26px floor, so Zoom doubles its rendered width exactly.
    block_trip.(%{
      trip_id: "BB_LONG",
      route_id: "BB_R1",
      block_id: "BB-LONG",
      first_arrival: "05:15:00",
      last_arrival: "08:15:00",
      first_stop: "BB_S1",
      last_stop: "BB_S2"
    })

    block_trip.(%{
      trip_id: "BB_LONG_2",
      route_id: "BB_R1",
      block_id: "BB-LONG",
      first_arrival: "09:00:00",
      last_arrival: "10:00:00",
      first_stop: "BB_S2",
      last_stop: "BB_S1"
    })

    # Interlining: one vehicle, two routes.
    block_trip.(%{
      trip_id: "BB_INTER_A",
      route_id: "BB_R1",
      block_id: "BB-INTER",
      first_arrival: "06:00:00",
      last_arrival: "06:40:00",
      first_stop: "BB_S1",
      last_stop: "BB_S2"
    })

    block_trip.(%{
      trip_id: "BB_INTER_B",
      route_id: "BB_R2",
      block_id: "BB-INTER",
      first_arrival: "06:50:00",
      last_arrival: "07:30:00",
      first_stop: "BB_S2",
      last_stop: "BB_S3"
    })

    # After midnight: the last arrival is 25:30, so the End cell reads 25:30 in
    # GTFS hours and the axis ceiling is 26:00.
    block_trip.(%{
      trip_id: "BB_MIDNIGHT_A",
      route_id: "BB_R1",
      block_id: "BB-MIDNIGHT",
      first_arrival: "23:00:00",
      last_arrival: "23:40:00",
      first_stop: "BB_S1",
      last_stop: "BB_S2"
    })

    block_trip.(%{
      trip_id: "BB_MIDNIGHT_B",
      route_id: "BB_R1",
      block_id: "BB-MIDNIGHT",
      first_arrival: "24:30:00",
      last_arrival: "25:30:00",
      first_stop: "BB_S2",
      last_stop: "BB_S1"
    })

    # A five-minute trip: its bar is under the 26px floor, so it stays 26px wide at
    # both scales (the journey's Zoom bar is BB-LONG for that reason).
    block_trip.(%{
      trip_id: "BB_SHORT_HOP",
      route_id: "BB_R1",
      block_id: "BB-SHORT",
      first_arrival: "06:00:00",
      last_arrival: "06:05:00",
      first_stop: "BB_S1",
      last_stop: "BB_S2"
    })

    block_trip.(%{
      trip_id: "BB_SHORT_AFTER",
      route_id: "BB_R1",
      block_id: "BB-SHORT",
      first_arrival: "10:00:00",
      last_arrival: "10:30:00",
      first_stop: "BB_S2",
      last_stop: "BB_S1"
    })

    # Nested overlap: A overlaps B and C, and B overlaps C.
    for {trip_id, start_sec, end_sec} <- [
          {"BB_NEST_A", 28_800, 39_600},
          {"BB_NEST_B", 32_400, 36_000},
          {"BB_NEST_C", 34_200, 37_800}
        ] do
      block_trip.(%{
        trip_id: trip_id,
        route_id: "BB_R1",
        block_id: "BB-NEST",
        first_arrival: block_clock.(start_sec),
        last_arrival: block_clock.(end_sec),
        first_stop: "BB_S1",
        last_stop: "BB_S2"
      })
    end

    # A two-minute layover: below the default five-minute minimum, so the block
    # carries a short-layover warning.
    block_trip.(%{
      trip_id: "BB_SL_A",
      route_id: "BB_R1",
      block_id: "BB-SHORTLAY",
      first_arrival: "11:00:00",
      last_arrival: "11:30:00",
      first_stop: "BB_S1",
      last_stop: "BB_S2"
    })

    block_trip.(%{
      trip_id: "BB_SL_B",
      route_id: "BB_R1",
      block_id: "BB-SHORTLAY",
      first_arrival: "11:32:00",
      last_arrival: "12:00:00",
      first_stop: "BB_S2",
      last_stop: "BB_S3"
    })

    # A 120 m handoff: nearby, so the gap reads as a walk rather than a move.
    block_trip.(%{
      trip_id: "BB_HD_A",
      route_id: "BB_R1",
      block_id: "BB-HANDOFF",
      first_arrival: "12:00:00",
      last_arrival: "12:30:00",
      first_stop: "BB_S1",
      last_stop: "BB_S6"
    })

    block_trip.(%{
      trip_id: "BB_HD_B",
      route_id: "BB_R1",
      block_id: "BB-HANDOFF",
      first_arrival: "12:45:00",
      last_arrival: "13:15:00",
      first_stop: "BB_S7",
      last_stop: "BB_S2"
    })

    # A 340 m empty move: beyond 200 m, so the block carries the reposition notice.
    block_trip.(%{
      trip_id: "BB_MOVE_A",
      route_id: "BB_R1",
      block_id: "BB-MOVE",
      first_arrival: "13:30:00",
      last_arrival: "14:00:00",
      first_stop: "BB_S1",
      last_stop: "BB_S8"
    })

    block_trip.(%{
      trip_id: "BB_MOVE_B",
      route_id: "BB_R1",
      block_id: "BB-MOVE",
      first_arrival: "14:15:00",
      last_arrival: "14:45:00",
      first_stop: "BB_S9",
      last_stop: "BB_S2"
    })

    # A matching type-4 record: the consecutive pair of BB-MATCH, whose stored
    # endpoint stops are the pair's own last and first stops.
    match_a =
      block_trip.(%{
        trip_id: "BB_MATCH_A",
        route_id: "BB_R1",
        block_id: "BB-MATCH",
        first_arrival: "07:00:00",
        last_arrival: "07:30:00",
        first_stop: "BB_S1",
        last_stop: "BB_S2"
      })

    match_b =
      block_trip.(%{
        trip_id: "BB_MATCH_B",
        route_id: "BB_R1",
        block_id: "BB-MATCH",
        first_arrival: "07:45:00",
        last_arrival: "08:15:00",
        first_stop: "BB_S2",
        last_stop: "BB_S3"
      })

    GtfsPlanner.BlockingFixtures.in_seat_transfer_fixture(
      org.id,
      blocks_version.id,
      match_a,
      match_b
    )

    # A stale type-4 record: BB_STALE_A→BB_STALE_C skips BB_STALE_B, so the record
    # is not the block's next pair on either weekday day type.
    stale_a =
      block_trip.(%{
        trip_id: "BB_STALE_A",
        route_id: "BB_R1",
        block_id: "BB-STALE",
        first_arrival: "15:00:00",
        last_arrival: "15:30:00",
        first_stop: "BB_S1",
        last_stop: "BB_S2"
      })

    block_trip.(%{
      trip_id: "BB_STALE_B",
      route_id: "BB_R1",
      block_id: "BB-STALE",
      first_arrival: "15:40:00",
      last_arrival: "16:10:00",
      first_stop: "BB_S2",
      last_stop: "BB_S3"
    })

    stale_c =
      block_trip.(%{
        trip_id: "BB_STALE_C",
        route_id: "BB_R1",
        block_id: "BB-STALE",
        first_arrival: "16:20:00",
        last_arrival: "16:50:00",
        first_stop: "BB_S3",
        last_stop: "BB_S1"
      })

    GtfsPlanner.BlockingFixtures.in_seat_transfer_fixture(
      org.id,
      blocks_version.id,
      stale_a,
      stale_c
    )

    # A cross-day overlap: the Friday-only school trip overlaps the weekday trip,
    # so the block has one error on {SCHOOL, WEEK} and none on {WEEK} alone.
    block_trip.(%{
      trip_id: "BB_XOVER_A",
      route_id: "BB_R1",
      block_id: "BB-XOVER",
      first_arrival: "08:00:00",
      last_arrival: "09:00:00",
      first_stop: "BB_S1",
      last_stop: "BB_S2"
    })

    block_trip.(%{
      trip_id: "BB_XOVER_B",
      route_id: "BB_R2",
      service_id: "BB_SCHOOL",
      block_id: "BB-XOVER",
      first_arrival: "08:30:00",
      last_arrival: "09:30:00",
      first_stop: "BB_S2",
      last_stop: "BB_S3"
    })

    # The journey's assignment target. On {WEEK} the block holds BB_TARGET_A alone
    # and BB_SHARED fits beside it; on {SCHOOL, WEEK} the school trip BB_TARGET_B is
    # there too and BB_SHARED overlaps it, so the review lists the second day type
    # under “Also changes”.
    block_trip.(%{
      trip_id: "BB_TARGET_A",
      route_id: "BB_R1",
      block_id: "BB-TARGET",
      first_arrival: "07:00:00",
      last_arrival: "07:30:00",
      first_stop: "BB_S1",
      last_stop: "BB_S3"
    })

    block_trip.(%{
      trip_id: "BB_TARGET_B",
      route_id: "BB_R2",
      service_id: "BB_SCHOOL",
      block_id: "BB-TARGET",
      first_arrival: "10:00:00",
      last_arrival: "11:00:00",
      first_stop: "BB_S4",
      last_stop: "BB_S5"
    })

    # The busiest block, so sorting by Trips moves it to the top of the page.
    for slot <- 0..5 do
      base = 1020 + slot * 40

      block_trip.(%{
        trip_id: "BB_BUSY_#{slot}",
        route_id: "BB_R1",
        block_id: "BB-BUSIEST",
        first_arrival: block_clock.(base * 60),
        last_arrival: block_clock.((base + 15) * 60),
        first_stop: "BB_S1",
        last_stop: "BB_S1"
      })
    end

    # The third day type: two Saturday trips in their own block.
    for {trip_id, from_sec} <- [{"BB_SAT_A", 36_000}, {"BB_SAT_B", 43_200}] do
      block_trip.(%{
        trip_id: trip_id,
        route_id: "BB_R1",
        service_id: "BB_SAT",
        block_id: "BB-SAT",
        first_arrival: block_clock.(from_sec),
        last_arrival: block_clock.(from_sec + 1800),
        first_stop: "BB_S1",
        last_stop: "BB_S2"
      })
    end

    # 127 ordinary unassigned trips every six minutes from 05:00, each five minutes
    # long. With the frequency trip, the untimed trip and the journey's own
    # BB_SHARED the pool holds exactly 130 trips over two pages: 100 and 30.
    for index <- 1..127 do
      base = 300 + (index - 1) * 6

      block_trip.(%{
        trip_id: "BB_POOL_" <> String.pad_leading(Integer.to_string(index), 3, "0"),
        route_id: if(rem(index, 2) == 0, do: "BB_R2", else: "BB_R1"),
        first_arrival: block_clock.(base * 60),
        last_arrival: block_clock.((base + 5) * 60),
        first_stop: "BB_S1",
        last_stop: "BB_S2"
      })
    end

    # The unassigned frequency trip: in the pool, never optional to assign.
    block_frequency_trip =
      block_trip.(%{
        trip_id: "BB_POOL_FREQ",
        route_id: "BB_R1",
        first_arrival: "06:30:00",
        last_arrival: "07:00:00",
        first_stop: "BB_S1",
        last_stop: "BB_S2"
      })

    GtfsPlanner.GtfsFixtures.frequency_fixture(
      org.id,
      blocks_version.id,
      block_frequency_trip.trip_id,
      %{
        start_time: "06:30:00",
        end_time: "09:00:00",
        headway_secs: 1200
      }
    )

    # The unassigned trip with no usable endpoint times: it lists last in the pool.
    block_trip.(%{
      trip_id: "BB_POOL_UNTIMED",
      route_id: "BB_R2",
      first_arrival: nil,
      first_departure: nil,
      last_arrival: nil,
      last_departure: nil,
      first_stop: "BB_S1",
      last_stop: "BB_S2"
    })

    # The trip the journey assigns: it runs on both weekday day types and is not
    # the school trip, so it is the one whose overlap appears only on the larger
    # day type.
    block_trip.(%{
      trip_id: "BB_SHARED",
      route_id: "BB_R1",
      first_arrival: "09:30:00",
      last_arrival: "10:30:00",
      first_stop: "BB_S3",
      last_stop: "BB_S4"
    })

    blocks_day_trips =
      Repo.aggregate(from(t in Gtfs.Trip, where: t.gtfs_version_id == ^blocks_version.id), :count)

    IO.puts(
      "Browser seed: version #{blocks_version.name} (#{blocks_version.id}) with 34 weekday blocks, " <>
        "#{blocks_day_trips} trips, a frequency trip, an unplottable trip and two type-4 records " <>
        "across #{map_size(block_stops)} stops and #{map_size(block_routes)} routes"
    )

    # ── In-seat helper browser journey (EV-18) ──
    #
    # A published "Browser In-seat Helper Version" holds the in-seat helper's own
    # journey data: one place with two blocks of one consecutive cross-route pair
    # each, on the weekday service alone, so both pairs are the block's next pair on
    # every date they run and may therefore be prepared. The first pair already
    # carries a type-4 record, so the journey's save replaces a real setting rather
    # than creating the first one, and the group's own result names the setting the
    # review changed.
    #
    # It is a version of its own because "Browser Blocks Version" is measured by
    # literal block and record counts. Backdated, so it never becomes the
    # organization's latest published default.
    {:ok, helper_blocks_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser In-seat Helper Version"})

    helper_blocks_version =
      Repo.update!(
        Ecto.Changeset.change(helper_blocks_version,
          published_at: ~U[2020-03-02 00:00:00.000000Z]
        )
      )

    GtfsPlanner.BlockingFixtures.calendar_service_fixture(org.id, helper_blocks_version.id, %{
      service_id: "BB_WEEK",
      name: "Weekday service",
      monday: 1,
      tuesday: 1,
      wednesday: 1,
      thursday: 1,
      friday: 1,
      saturday: 0,
      sunday: 0,
      start_date: block_week_start,
      end_date: block_week_end
    })

    in_seat_stop =
      GtfsPlanner.GtfsFixtures.stop_fixture(org.id, helper_blocks_version.id, %{
        stop_id: "BB_INSEAT",
        stop_name: "Blocks In-seat Plaza",
        stop_lat: 40.8000,
        stop_lon: -73.9400
      })

    for {route_id, short_name, long_name} <- [
          {"BB_R1", "BR1", "Blocks Riverside"},
          {"BB_R2", "BR2", "Blocks Central"}
        ] do
      {:ok, _route} =
        GtfsPlanner.GtfsFixtures.insert_route(%{
          organization_id: org.id,
          gtfs_version_id: helper_blocks_version.id,
          route_id: route_id,
          route_short_name: short_name,
          route_long_name: long_name,
          route_type: 3,
          route_color: "0055AA"
        })
    end

    in_seat_pairs =
      for {block_id, from_times, to_times} <- [
            {"BB-ISEAT-1", {"10:00:00", "10:30:00"}, {"11:10:00", "11:40:00"}},
            {"BB-ISEAT-2", {"11:00:00", "11:30:00"}, {"12:10:00", "12:40:00"}}
          ] do
        in_seat_trip = fn route_id, suffix, {first_arrival, last_arrival} ->
          GtfsPlanner.BlockingFixtures.blocked_trip_fixture(
            org.id,
            helper_blocks_version.id,
            route_id,
            %{
              trip_id: "BB_ISEAT_#{block_id}_#{suffix}",
              service_id: "BB_WEEK",
              block_id: block_id,
              trip_headsign: "Blocks journey",
              first_stop: in_seat_stop.stop_id,
              last_stop: in_seat_stop.stop_id,
              first_arrival: first_arrival,
              last_arrival: last_arrival
            }
          )
        end

        {in_seat_trip.("BB_R1", "A", from_times), in_seat_trip.("BB_R2", "B", to_times)}
      end

    [{in_seat_first, in_seat_second} | _rest] = in_seat_pairs

    GtfsPlanner.BlockingFixtures.in_seat_transfer_fixture(
      org.id,
      helper_blocks_version.id,
      in_seat_first,
      in_seat_second
    )

    # ── Advanced blocking browser journey ──
    #
    # A published "Browser Advanced Blocks Version" carries a
    # “Plan with problems” scenario, isolated from every other scenario by its
    # version and by its `AB_` names:
    #
    #   * the three calendars behind the day types the journey visits — “Weekday”
    #     on weekdays, “School days” on Monday, Wednesday and Friday and
    #     “Saturday” on Saturday — which derive {WKDY, SCHOOL} (the largest, so the
    #     page's default), {WKDY} alone and {SAT};
    #   * the geometry, so an estimated drive at the stored 30 km/h
    #     and 1.3 circuity is Main garage → Riverside Station 12 min,
    #     Valley College ↔ Market Square 14 min and Main garage → Valley College
    #     18 min. Riverside Station ↔ Valley
    #     College estimates 15 min, Riverside Station ↔ Market Square 11 min,
    #     North garage → Riverside Station 16 min and North garage → Valley
    #     College 9 min. Main garage → Market Square estimates 4 min and nothing
    #     reads it;
    #   * blocks 101–104 on the largest day type, with the two problems the
    #     scenario is named for: 101 cannot reach Market Square (14 min of drive
    #     into an 8-minute gap) and 104 runs route 30, which requires a 35-ft
    #     diesel, on a Cutaway. Block 102 is extended so it runs past the
    #     330-minute operator-change limit without ever visiting the relief point;
    #   * a two-trip pool — 6105 and 8105 — plus the frequency trip F30;
    #   * Saturday blocks 101 and 102 out of the North garage, which is a
    #     different vehicle's day than the weekday 101 of the same number.
    #
    # Block IDs are numeric (101–104) so generated blocks are numbered from 105.
    # They are scoped to this version, so they cannot collide with the
    # “Browser Blocks Version” `BB-` names.
    {:ok, advanced_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Advanced Blocks Version"})

    # Backdated, so this version never becomes the organization's latest
    # published default and the existing browser journeys keep opening
    # “Browser Blocks Version”.
    advanced_version =
      Repo.update!(
        Ecto.Changeset.change(advanced_version,
          published_at: ~U[2020-06-01 00:00:00.000000Z]
        )
      )

    advanced_week_start = ~D[2026-09-07]
    advanced_week_end = ~D[2027-06-25]

    for {service_id, name, days} <- [
          {"WKDY", "Weekday",
           [monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1, saturday: 0, sunday: 0]},
          {"SCHOOL", "School days",
           [monday: 1, tuesday: 0, wednesday: 1, thursday: 0, friday: 1, saturday: 0, sunday: 0]},
          {"SAT", "Saturday",
           [monday: 0, tuesday: 0, wednesday: 0, thursday: 0, friday: 0, saturday: 1, sunday: 0]}
        ] do
      attrs =
        Map.merge(
          %{
            service_id: service_id,
            name: name,
            start_date: advanced_week_start,
            end_date: advanced_week_end
          },
          Map.new(days)
        )

      GtfsPlanner.BlockingFixtures.calendar_service_fixture(
        org.id,
        advanced_version.id,
        attrs
      )
    end

    # Riverside Station is a station (location_type 1) with a Bay A and a Bay B
    # beneath it. The bays carry no point of their own, so every estimate uses
    # the parent's coordinates and a Bay A ↔ Bay B handoff is a same-station
    # handoff rather than a drive.
    AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, advanced_version.id, %{
      stop_id: "AB_RS",
      stop_name: "Riverside Station",
      location_type: 1,
      stop_lat: 40.750000,
      stop_lon: -73.990000
    })

    for {stop_id, bay} <- [{"AB_RS_A", "A"}, {"AB_RS_B", "B"}] do
      AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, advanced_version.id, %{
        stop_id: stop_id,
        stop_name: "Riverside Station · Bay #{bay}",
        location_type: 0,
        parent_station: "AB_RS",
        platform_code: bay,
        stop_lat: nil,
        stop_lon: nil
      })
    end

    AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, advanced_version.id, %{
      stop_id: "AB_VALLEY",
      stop_name: "Valley College",
      location_type: 0,
      stop_lat: 40.750000,
      stop_lon: -73.921687
    })

    AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, advanced_version.id, %{
      stop_id: "AB_MKT",
      stop_name: "Market Square",
      location_type: 0,
      stop_lat: 40.783935,
      stop_lon: -73.967229
    })

    # Route colours: 12 ocean, 24 plum, 30 green.
    advanced_routes =
      [
        {"AB_R12", "12", "Riverside", "1F5FBF"},
        {"AB_R24", "24", "Crosstown", "4B1F78"},
        {"AB_R30", "30", "College shuttle", "267548"}
      ]
      |> Map.new(fn {route_id, short_name, long_name, color} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: advanced_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3,
            route_color: color,
            route_text_color: "FFFFFF"
          })

        {route_id, route}
      end)

    advanced_trip = fn attrs ->
      attrs = Map.new(attrs)

      GtfsPlanner.BlockingFixtures.blocked_trip_fixture(
        org.id,
        advanced_version.id,
        Map.fetch!(advanced_routes, Map.fetch!(attrs, :route_id)).route_id,
        # The fixture's own service default is the blocks scenario's calendar, so
        # this version's Weekday calendar is named here rather than inherited.
        Map.merge(
          Map.take(attrs, [
            :trip_id,
            :block_id,
            :trip_headsign,
            :first_stop,
            :last_stop,
            :first_arrival,
            :last_arrival
          ]),
          %{service_id: Map.get(attrs, :service_id, "WKDY")}
        )
      )
    end

    # Block 101: two Riverside → Valley College trips around a Crosstown trip out
    # of Market Square. The 06:35 arrival at Valley College leaves 8 minutes to
    # the 06:43 departure at Market Square, and the drive between them estimates
    # 14, so the block carries the “can't reach” error the journey opens first.
    advanced_trip.(%{
      trip_id: "6101",
      route_id: "AB_R12",
      block_id: "101",
      first_stop: "AB_RS_A",
      last_stop: "AB_VALLEY",
      first_arrival: "06:00:00",
      last_arrival: "06:35:00",
      trip_headsign: "Valley College"
    })

    advanced_trip.(%{
      trip_id: "8101",
      route_id: "AB_R24",
      block_id: "101",
      first_stop: "AB_MKT",
      last_stop: "AB_RS_B",
      first_arrival: "06:43:00",
      last_arrival: "07:18:00",
      trip_headsign: "Riverside Station"
    })

    advanced_trip.(%{
      trip_id: "6103",
      route_id: "AB_R12",
      block_id: "101",
      first_stop: "AB_RS_A",
      last_stop: "AB_VALLEY",
      first_arrival: "07:40:00",
      last_arrival: "08:15:00",
      trip_headsign: "Valley College"
    })

    # Block 102, extended for the “No operator change” problem:
    # six trips from 06:05 to 11:35, every handoff at Valley College or at the
    # station, so no trip ever passes the relief point at Market Square and the
    # block exceeds the 330-minute operator-change limit in one stretch.
    for {trip_id, first_stop, last_stop, first_arrival, last_arrival} <- [
          {"6102", "AB_VALLEY", "AB_RS_B", "06:05:00", "06:40:00"},
          {"6104", "AB_RS_A", "AB_VALLEY", "07:05:00", "07:40:00"},
          {"6106", "AB_VALLEY", "AB_RS_B", "08:00:00", "08:35:00"},
          {"6108", "AB_RS_A", "AB_VALLEY", "09:00:00", "09:35:00"},
          {"6110", "AB_VALLEY", "AB_RS_B", "10:00:00", "10:35:00"},
          {"6112", "AB_RS_A", "AB_VALLEY", "11:00:00", "11:35:00"}
        ] do
      advanced_trip.(%{
        trip_id: trip_id,
        route_id: "AB_R12",
        block_id: "102",
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        last_arrival: last_arrival,
        trip_headsign:
          if(first_stop == "AB_VALLEY", do: "Riverside Station", else: "Valley College")
      })
    end

    # Block 103: the Crosstown trips of the weekday, clean at every handoff.
    for {trip_id, first_stop, last_stop, first_arrival, last_arrival} <- [
          {"8102", "AB_MKT", "AB_RS_B", "06:15:00", "06:50:00"},
          {"8104", "AB_RS_A", "AB_MKT", "07:15:00", "07:50:00"},
          {"8106", "AB_MKT", "AB_RS_B", "08:20:00", "08:55:00"}
        ] do
      advanced_trip.(%{
        trip_id: trip_id,
        route_id: "AB_R24",
        block_id: "103",
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        last_arrival: last_arrival,
        trip_headsign: if(first_stop == "AB_MKT", do: "Riverside Station", else: "Crosstown")
      })
    end

    # Block 104: the college shuttle's school-day trips on route 30, whose
    # required type is the 35-ft diesel its block attribute does not name.
    for {trip_id, first_stop, last_stop, first_arrival, last_arrival} <- [
          {"9101", "AB_RS_A", "AB_VALLEY", "06:20:00", "06:55:00"},
          {"9103", "AB_VALLEY", "AB_RS_B", "07:20:00", "07:55:00"},
          {"9105", "AB_RS_A", "AB_VALLEY", "08:30:00", "09:05:00"}
        ] do
      advanced_trip.(%{
        trip_id: trip_id,
        route_id: "AB_R30",
        service_id: "SCHOOL",
        block_id: "104",
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        last_arrival: last_arrival,
        trip_headsign:
          if(first_stop == "AB_RS_A", do: "Valley College", else: "Riverside Station")
      })
    end

    # Saturday: the same block numbers out of the North garage, a different
    # vehicle on a day of its own.
    for {trip_id, block_id, first_stop, last_stop, first_arrival, last_arrival} <- [
          {"S1201", "101", "AB_RS_A", "AB_VALLEY", "07:00:00", "07:35:00"},
          {"S1202", "101", "AB_VALLEY", "AB_RS_B", "08:00:00", "08:35:00"},
          {"S1203", "102", "AB_VALLEY", "AB_RS_B", "07:30:00", "08:05:00"},
          {"S1204", "102", "AB_RS_A", "AB_VALLEY", "08:30:00", "09:05:00"}
        ] do
      advanced_trip.(%{
        trip_id: trip_id,
        route_id: "AB_R12",
        service_id: "SAT",
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        last_arrival: last_arrival,
        trip_headsign:
          if(first_stop == "AB_VALLEY", do: "Riverside Station", else: "Valley College")
      })
    end

    # The pool: 6105 and 8105, and the frequency trip F30, which runs a headway
    # over three hours on the school-day calendar.
    advanced_trip.(%{
      trip_id: "6105",
      route_id: "AB_R12",
      first_stop: "AB_VALLEY",
      last_stop: "AB_RS_B",
      first_arrival: "09:15:00",
      last_arrival: "09:50:00",
      trip_headsign: "Riverside Station"
    })

    advanced_trip.(%{
      trip_id: "8105",
      route_id: "AB_R24",
      first_stop: "AB_RS_A",
      last_stop: "AB_MKT",
      first_arrival: "09:30:00",
      last_arrival: "10:05:00",
      trip_headsign: "Crosstown"
    })

    advanced_trip.(%{
      trip_id: "F30",
      route_id: "AB_R30",
      service_id: "SCHOOL",
      first_stop: "AB_VALLEY",
      last_stop: "AB_RS_B",
      first_arrival: "07:00:00",
      last_arrival: "10:00:00",
      trip_headsign: "Riverside Station"
    })

    GtfsPlanner.GtfsFixtures.frequency_fixture(org.id, advanced_version.id, "F30", %{
      start_time: "07:00:00",
      end_time: "10:00:00",
      headway_secs: 1800
    })

    # The two garages, and the two vehicle types with their time-out limits: a
    # Cutaway 10 hours, a 35-ft diesel 8.
    advanced_main =
      GtfsPlanner.OperationsFixtures.garage_fixture(org.id, %{
        garage_id: "MAIN",
        name: "Main",
        lat: 40.791236,
        lon: -73.983169
      })

    advanced_north =
      GtfsPlanner.OperationsFixtures.garage_fixture(org.id, %{
        garage_id: "NORTH",
        name: "North",
        lat: 40.719368,
        lon: -73.929277
      })

    advanced_cutaway =
      GtfsPlanner.OperationsFixtures.vehicle_type_fixture(org.id, %{
        name: "Cutaway",
        max_out_hours: 10
      })

    advanced_diesel =
      GtfsPlanner.OperationsFixtures.vehicle_type_fixture(org.id, %{
        name: "35-ft diesel",
        max_out_hours: 8
      })

    # The fleet the count strip and the Plan summary read: 12 Cutaways and 8
    # diesels at Main, 6 Cutaways at North.
    for {prefix, garage, type, count} <- [
          {"AB_VC", advanced_main, advanced_cutaway, 12},
          {"AB_VD", advanced_main, advanced_diesel, 8},
          {"AB_VN", advanced_north, advanced_cutaway, 6}
        ] do
      for index <- 1..count do
        GtfsPlanner.OperationsFixtures.vehicle_fixture(org.id, %{
          vehicle_id: prefix <> String.pad_leading(Integer.to_string(index), 2, "0"),
          vehicle_type_id: type.id,
          garage_id: garage.id
        })
      end
    end

    # Every route runs out of Main, and route 30 needs the 35-ft diesel.
    for {route_id, required_type_id} <- [
          {"AB_R12", nil},
          {"AB_R24", nil},
          {"AB_R30", advanced_diesel.id}
        ] do
      AdvancedBlockingFixtures.route_operating_setting_fixture(
        org.id,
        advanced_version.id,
        %{
          route_id: route_id,
          garage_id: advanced_main.id,
          required_vehicle_type_id: required_type_id
        }
      )
    end

    # Block settings are stored per calendar and block number, so block 101's
    # garage reaches both weekday day types and Saturday 101 keeps the North
    # garage. 104's Cutaway is the wrong type for route 30, on purpose.
    for {service_id, block_id, garage_id, type_id} <- [
          {"WKDY", "101", advanced_main.id, advanced_cutaway.id},
          {"WKDY", "102", advanced_main.id, advanced_cutaway.id},
          {"WKDY", "103", advanced_main.id, advanced_cutaway.id},
          {"SCHOOL", "104", advanced_main.id, advanced_cutaway.id},
          {"SAT", "101", advanced_north.id, advanced_cutaway.id},
          {"SAT", "102", advanced_north.id, advanced_cutaway.id}
        ] do
      AdvancedBlockingFixtures.block_attribute_fixture(org.id, advanced_version.id, %{
        service_id: service_id,
        block_id: block_id,
        garage_id: garage_id,
        vehicle_type_id: type_id
      })
    end

    # Block rules: the default layover and driving-time settings, Main as the
    # default garage and the researched 330-minute operator-change limit.
    {:ok, _advanced_settings} =
      GtfsPlanner.Gtfs.Blocking.update_settings(seed_audit.(advanced_version), %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: :any,
        deadhead_speed_kmh: 30,
        deadhead_circuity: Decimal.new("1.3"),
        max_piece_minutes: 330,
        default_garage_id: advanced_main.id
      })

    # One relief point, at Market Square, which no weekday block visits.
    AdvancedBlockingFixtures.relief_point_fixture(org.id, advanced_version.id, %{
      stop_id: "AB_MKT"
    })

    IO.puts(
      "Browser seed: version #{advanced_version.name} (#{advanced_version.id}) with blocks " <>
        "101-104, a 2-trip pool plus frequency trip F30, 2 garages and 2 vehicle types"
    )

    # ── Basic runs browser journey (runs.spec.js, runs_keyboard.spec.js) ──
    #
    # A published "Browser Runs Version" carries the prototype's default runs
    # problems, isolated from every other scenario by its version and by its
    # `RN_` names:
    #
    #   * two calendars — "Weekday" on weekdays and "Saturday" on Saturday —
    #     deriving {WKDY} and {SAT}. The Weekday day type is the one the
    #     journeys open, and the Saturday one exists so a run ID can be shown
    #     scoped to its day type (the same ID on both is two runs);
    #   * two MARKED STATIONS, Northgate and Southgate, each a location_type 1
    #     station with one bay beneath it. A station is what a relief mark means:
    #     a change of hands at a station reads as a relief, at a plain stop it
    #     does not. Two of them, so the seed can show a change that IS at relief
    #     next to one that is not;
    #   * a relief point at each marked station, Northgate and Southgate, so a
    #     change of hands there reads as relief and a change anywhere else does
    #     not. `Blocking.Relief` matches a bay through its `parent_station`, so
    #     naming the station is enough for the bay beneath it;
    #   * `max_piece_minutes` 330, the researched operator-change limit, and the
    #     default crew rules (15 min pull-out, 5 min relief, 5 min sign-off,
    #     30 min paid break, 720 min max spread). Both matter: without
    #     `max_piece_minutes` there is no `:piece_too_long` check at all, and
    #     the 30-minute paid-break maximum is what separates the straight run
    #     from the split one;
    #   * eight weekday blocks, 101-108, and the trip_runs rows below.
    #
    # The five states the page opens on, one per problem the prototype names.
    # Note that a PIECE is cut where the run ID changes, not where a relief
    # point is: `Runs.Pieces.cut/2` chunks a block's sequence by assignment. So a
    # multi-piece run is a run that works two BLOCKS — one vehicle's shift
    # across a relief — and the run's type follows the length of the break
    # between them.
    #
    #   * run 2001, the AM/PM TRIPPER, works block 101's two morning trips and
    #     block 104's two afternoon trips. The break between them measures
    #     30060 s, far past the 30-minute paid-break maximum, so it is unpaid,
    #     the operator changes, and the run is a :SPLIT;
    #   * run 2002 works block 102's two trips and block 106's two, twenty
    #     minutes later and starting at the same stop. Its break measures
    #     300 s — inside the paid-break maximum — so the same operator works
    #     both pieces and the run is :STRAIGHT. The ONLY difference from 2001 is
    #     the length of the gap, which is the whole distinction the page exists
    #     to show;
    #   * 103 THE PROBLEM BLOCK is two runs. Run 2003 works five trips and its
    #     piece measures 21720 s (362 min) against the 330-minute limit, so it
    #     raises :piece_too_long; and the change of hands from 2003 to 2004
    #     happens at Market Street, which is not a relief point, so it raises
    #     :not_at_relief. One block, both problems;
    #   * 105 is assigned to nothing, so it is the UNCOVERED segment: its two
    #     trips are on the chart and no run holds them;
    #   * runs 2005 and 2006 are plain one-piece runs on blocks 107 and 108, so
    #     ordinary work sits either side of the interesting blocks.
    #
    # Saturday carries run "2001" as well. It is a DIFFERENT run from the
    # weekday "2001" — same name, other day type — which is what "a run is
    # scoped to its day type" looks like on the page.
    #
    # Block IDs are numeric (101-108) and every name is `RN_`-prefixed, so this
    # version can collide with neither the `BB-` nor the `AB-` names. The
    # version is backdated to 2020-07-01, after the advanced and transfers
    # versions and long before the `DateTime.utc_now()` defaults, so it never
    # becomes the organization's latest published default.
    {:ok, runs_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Runs Version"})

    runs_version =
      Repo.update!(
        Ecto.Changeset.change(runs_version,
          published_at: ~U[2020-07-01 00:00:00.000000Z]
        )
      )

    runs_week_start = ~D[2026-09-07]
    runs_week_end = ~D[2027-06-25]

    for {service_id, name, days} <- [
          {"WKDY", "Weekday",
           [monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1, saturday: 0, sunday: 0]},
          {"SAT", "Saturday",
           [monday: 0, tuesday: 0, wednesday: 0, thursday: 0, friday: 0, saturday: 1, sunday: 0]}
        ] do
      attrs =
        Map.merge(
          %{
            service_id: service_id,
            name: name,
            start_date: runs_week_start,
            end_date: runs_week_end
          },
          Map.new(days)
        )

      GtfsPlanner.BlockingFixtures.calendar_service_fixture(
        org.id,
        runs_version.id,
        attrs
      )
    end

    # The two marked stations and the two plain stops. A bay carries no point of
    # its own, so every estimate uses the station's coordinates and a handover
    # between the two halves of one station is a same-station handover rather
    # than a drive.
    for {stop_id, stop_name, lat, lon} <- [
          {"RN_NG", "Northgate Station", 40.758000, -74.006000},
          {"RN_SG", "Southgate Station", 40.735000, -73.988000}
        ] do
      AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, runs_version.id, %{
        stop_id: stop_id,
        stop_name: stop_name,
        location_type: 1,
        stop_lat: lat,
        stop_lon: lon
      })
    end

    for {stop_id, parent, platform} <- [
          {"RN_NG_A", "RN_NG", "A"},
          {"RN_SG_A", "RN_SG", "A"}
        ] do
      AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, runs_version.id, %{
        stop_id: stop_id,
        stop_name: "#{parent} · Bay #{platform}",
        location_type: 0,
        parent_station: parent,
        platform_code: platform,
        stop_lat: nil,
        stop_lon: nil
      })
    end

    for {stop_id, stop_name, lat, lon} <- [
          {"RN_MKT", "Market Street", 40.770000, -73.995000},
          {"RN_RIVER", "Riverbend", 40.712000, -74.010000}
        ] do
      AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, runs_version.id, %{
        stop_id: stop_id,
        stop_name: stop_name,
        location_type: 0,
        stop_lat: lat,
        stop_lon: lon
      })
    end

    runs_routes =
      [
        {"RN_R10", "10", "Northgate - Riverbend", "1F5FBF"},
        {"RN_R20", "20", "Southgate - Riverbend", "4B1F78"},
        {"RN_R30", "30", "Market crosstown", "267548"}
      ]
      |> Map.new(fn {route_id, short_name, long_name, color} ->
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: runs_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3,
            route_color: color,
            route_text_color: "FFFFFF"
          })

        {route_id, route}
      end)

    runs_trip = fn attrs ->
      attrs = Map.new(attrs)

      GtfsPlanner.BlockingFixtures.blocked_trip_fixture(
        org.id,
        runs_version.id,
        Map.fetch!(runs_routes, Map.fetch!(attrs, :route_id)).route_id,
        Map.merge(
          Map.take(attrs, [
            :trip_id,
            :block_id,
            :trip_headsign,
            :first_stop,
            :last_stop,
            :first_arrival,
            :last_arrival
          ]),
          %{service_id: Map.get(attrs, :service_id, "WKDY")}
        )
      )
    end

    # Eight weekday blocks. Each row is {trip_id, block, route, first stop, last
    # stop, first arrival, last arrival}; the handovers are what make the states
    # below, so the stop each block changes hands at is the load-bearing column.
    for {trip_id, block_id, route_id, first_stop, last_stop, first_arrival, last_arrival} <- [
          # 101 AM TRIPPER — run 2001 works these two morning trips and then
          # block 104's two afternoon trips, so the run has a piece per block
          # and the break between them is most of a working day. Unpaid, so the
          # run is a :split: one run, two operators, two shifts.
          {"1001", "101", "RN_R10", "RN_RIVER", "RN_NG_A", "05:50:00", "06:20:00"},
          {"1002", "101", "RN_R10", "RN_NG_A", "RN_RIVER", "06:40:00", "07:10:00"},
          # 102 — run 2002 works these two trips and then block 106's two, 20
          # minutes later and starting at the same stop (RN_SG_A). Each block
          # charges its own pull-out, so the break measures 300 s: inside the
          # 30-minute paid-break maximum, which makes the run a :straight. The
          # only difference from run 2001 is the length of the gap between its
          # two blocks, which is the whole distinction the page exists to show.
          {"1021", "102", "RN_R20", "RN_RIVER", "RN_MKT", "06:00:00", "06:30:00"},
          {"1022", "102", "RN_R20", "RN_MKT", "RN_SG_A", "06:50:00", "07:20:00"},
          # 103 THE PROBLEM BLOCK — two runs. Run 2003's single piece measures
          # 21720 s (362 min) against the 330-minute limit, so it raises
          # :piece_too_long, and the change of hands from 2003 to 2004 happens
          # at Market Street, which is not a relief point, so it raises
          # :not_at_relief. One block carrying both problems is the point: the
          # two findings are independent checks that a single block trips both.
          {"1025", "103", "RN_R30", "RN_RIVER", "RN_MKT", "05:55:00", "06:30:00"},
          {"1026", "103", "RN_R30", "RN_MKT", "RN_SG_A", "07:00:00", "07:35:00"},
          {"1027", "103", "RN_R30", "RN_SG_A", "RN_MKT", "08:10:00", "08:45:00"},
          {"1028", "103", "RN_R30", "RN_MKT", "RN_SG_A", "09:20:00", "09:55:00"},
          {"1029", "103", "RN_R30", "RN_SG_A", "RN_MKT", "11:20:00", "11:55:00"},
          {"1030", "103", "RN_R30", "RN_MKT", "RN_RIVER", "12:40:00", "13:20:00"},
          # 104 — run 2001's second piece, the afternoon half of the tripper.
          {"1031", "104", "RN_R10", "RN_RIVER", "RN_MKT", "15:50:00", "16:20:00"},
          {"1032", "104", "RN_R10", "RN_MKT", "RN_RIVER", "16:40:00", "17:10:00"},
          # 105 — the UNCOVERED block. These trips exist and are on the chart,
          # but no run holds them.
          {"1033", "105", "RN_R20", "RN_RIVER", "RN_MKT", "09:30:00", "10:00:00"},
          {"1034", "105", "RN_R20", "RN_MKT", "RN_RIVER", "10:30:00", "11:00:00"},
          # 106 — run 2002's second piece, twenty minutes after block 102 ends
          # and starting at the same stop, so the break between them is paid.
          # 107 and 108 — plain one-piece runs, so the chart has ordinary work on
          # it either side of the interesting blocks.
          {"1051", "106", "RN_R20", "RN_SG_A", "RN_MKT", "08:00:00", "08:30:00"},
          {"1052", "106", "RN_R20", "RN_MKT", "RN_RIVER", "08:50:00", "09:20:00"},
          {"1061", "107", "RN_R10", "RN_RIVER", "RN_MKT", "13:50:00", "14:20:00"},
          {"1062", "107", "RN_R10", "RN_MKT", "RN_RIVER", "14:50:00", "15:20:00"},
          {"1071", "108", "RN_R20", "RN_RIVER", "RN_SG_A", "19:00:00", "19:30:00"},
          {"1072", "108", "RN_R20", "RN_SG_A", "RN_RIVER", "20:00:00", "20:30:00"}
        ] do
      runs_trip.(%{
        trip_id: trip_id,
        route_id: route_id,
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        last_arrival: last_arrival
      })
    end

    # Saturday blocks, so the page can show that run "2001" on Saturday is a
    # DIFFERENT run from the weekday run of the same name: a run is scoped to
    # its day type, and the pair is its identity.
    for {trip_id, block_id, route_id, first_stop, last_stop, first_arrival, last_arrival} <- [
          {"10101", "201", "RN_R10", "RN_RIVER", "RN_MKT", "09:00:00", "09:30:00"},
          {"10102", "201", "RN_R10", "RN_MKT", "RN_RIVER", "10:00:00", "10:30:00"},
          {"10103", "202", "RN_R20", "RN_RIVER", "RN_SG_A", "11:00:00", "11:30:00"},
          {"10104", "202", "RN_R20", "RN_SG_A", "RN_RIVER", "12:00:00", "12:30:00"}
        ] do
      runs_trip.(%{
        trip_id: trip_id,
        route_id: route_id,
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        last_arrival: last_arrival,
        service_id: "SAT"
      })
    end

    # One garage for the whole version, and the default driving-time settings with
    # the researched 330-minute operator-change limit. `max_piece_minutes` is what
    # makes 103's over-limit piece a `:piece_too_long` warning; with it unset
    # there would be no such check at all, so the seeded state depends on this
    # line.
    runs_garage =
      GtfsPlanner.OperationsFixtures.garage_fixture(org.id, %{
        garage_id: "RNGB",
        name: "Riverbend Garage",
        lat: 40.705000,
        lon: -74.015000
      })

    for {service_id, block_id} <- [
          {"WKDY", "101"},
          {"WKDY", "102"},
          {"WKDY", "103"},
          {"WKDY", "104"},
          {"WKDY", "105"},
          {"WKDY", "106"},
          {"WKDY", "107"},
          {"WKDY", "108"},
          {"SAT", "201"},
          {"SAT", "202"}
        ] do
      AdvancedBlockingFixtures.block_attribute_fixture(org.id, runs_version.id, %{
        service_id: service_id,
        block_id: block_id,
        garage_id: runs_garage.id
      })
    end

    {:ok, _runs_settings} =
      GtfsPlanner.Gtfs.Blocking.update_settings(seed_audit.(runs_version), %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: :any,
        deadhead_speed_kmh: 30,
        deadhead_circuity: Decimal.new("1.3"),
        max_piece_minutes: 330,
        default_garage_id: runs_garage.id
      })

    # Two relief points, at the two marked stations. The trippers hand over at
    # those stations, so their handovers are at relief; 103 hands over at Market
    # Street and Southgate's bay, and the Southgate handover is therefore away
    # from the marked station stop the relief point names.
    for stop_id <- ["RN_NG", "RN_SG"] do
      AdvancedBlockingFixtures.relief_point_fixture(org.id, runs_version.id, %{stop_id: stop_id})
    end

    # The default crew rules, written explicitly so the seeded page's figures
    # come from this version's own row rather than from `@crew_defaults` by
    # accident. A 15-minute pull-out and a 5-minute relief are what put 103's
    # single piece at 398 minutes rather than at its trip times.
    {:ok, _runs_crew} =
      GtfsPlanner.Gtfs.update_crew_settings(seed_audit.(runs_version), %{
        report_pull_out_minutes: 15,
        report_relief_minutes: 5,
        sign_off_minutes: 5,
        paid_break_max_minutes: 30,
        max_spread_minutes: 720
      })

    # The trip_runs rows. Read back through `Runs.count_runs_for_trips/3` and
    # `Runs.load_runs/3` rather than assumed, so the day type key is the one the
    # day load itself derives and the counts below are the real answer.
    runs_weekday_key =
      case GtfsPlanner.Gtfs.Blocking.load_day(org.id, runs_version.id, nil) do
        {:ok, day} -> day.day_type.key
        {:error, reason} -> raise "runs browser seed: no default day type (#{inspect(reason)})"
      end

    runs_saturday_key =
      GtfsPlanner.Gtfs.Blocking.DayTypes.key(["SAT"])

    runs_trip_by_name =
      Ecto.Query.from(t in GtfsPlanner.Gtfs.Trip,
        where: t.organization_id == ^org.id and t.gtfs_version_id == ^runs_version.id,
        select: t
      )
      |> GtfsPlanner.Repo.all()
      |> Map.new(&{&1.trip_id, &1})

    # {block, trip names, run ID, day type key}. The block is the row's own
    # claim about where the trips sit, and it is CHECKED against the trip rather
    # than assumed: a trip silently moved to another block would otherwise be
    # assigned to a run that does not touch it, and the seeded state would be
    # wrong with nothing to say so.
    #
    #   * 101 and 104 share run 2001, so that run has a piece per block and the
    #     break between them is most of a working day — unpaid, so a :split;
    #   * 102 and 106 share run 2002 with a 20-minute gap, inside the
    #     paid-break maximum, so the page's :straight multi-piece run;
    #   * 103 carries TWO runs, and that is the point. The change of hands at
    #     Market Street is away from relief (:not_at_relief) and the first of
    #     the two is over the 330-minute limit (:piece_too_long);
    #   * 105 is absent, so its two trips are the uncovered segment;
    #   * 107 and 108 are one-piece runs 2005 and 2006.
    #
    # Saturday carries run "2001" too, which is a different run from the
    # weekday "2001" — same name, other day type.
    for {block_id, trip_names, run_id, day_type_key} <- [
          {"101", ["1001", "1002"], "2001", runs_weekday_key},
          {"104", ["1031", "1032"], "2001", runs_weekday_key},
          {"102", ["1021", "1022"], "2002", runs_weekday_key},
          {"106", ["1051", "1052"], "2002", runs_weekday_key},
          {"103", ["1025", "1026", "1027", "1028", "1029"], "2003", runs_weekday_key},
          {"103", ["1030"], "2004", runs_weekday_key},
          {"107", ["1061", "1062"], "2005", runs_weekday_key},
          {"108", ["1071", "1072"], "2006", runs_weekday_key},
          {"201", ["10101", "10102"], "2001", runs_saturday_key},
          {"202", ["10103", "10104"], "2009", runs_saturday_key}
        ] do
      for trip_name <- trip_names do
        trip = Map.fetch!(runs_trip_by_name, trip_name)

        unless trip.block_id == block_id do
          raise "runs browser seed: trip #{trip_name} is on block #{trip.block_id}, " <>
                  "but the assignment row claims #{block_id}"
        end

        GtfsPlanner.RunsFixtures.trip_run_fixture(org.id, runs_version.id, %{
          trip: trip,
          day_type_key: day_type_key,
          run_id: run_id
        })
      end
    end

    IO.puts("Browser seed: runs version #{runs_version.id}")

    # ── Basic rosters browser journey (rosters.spec.js, rosters_keyboard.spec.js) ──
    #
    # A published "Browser Rosters Version" carries a partly built roster over
    # three day types, isolated from every other scenario by its version and by
    # its `RS_` names:
    #
    #   * three calendars — "Weekday" on weekdays, "Saturday" on Saturday and
    #     "Sunday" on Sunday — deriving {WKDY}, {SAT} and {SUN}. The base week is
    #     therefore Mon–Fri / Sat / Sun by the most-dates default, which is what a
    #     version nobody has configured reads;
    #   * one date that runs other service. Labor Day, Monday 2026-09-07, drops
    #     WKDY and adds SUN, so that date belongs to the {SUN} day type while the
    #     base week's Monday is {WKDY}. `AssignmentsExport` reports it as an
    #     other-service date, which is how the export's and the page's "one date
    #     runs different service" state is reachable from the seed;
    #   * one garage, one marked station (a relief point needs one) and two plain
    #     terminals every trip runs between, so every block has a real drive out
    #     of and back to the garage and the derived work times are real ones;
    #   * the researched crew rules and the 330-minute operator-change limit, so
    #     the run's own report and paid time come from this version's row;
    #   * the roster rules — 600 minutes of rest and a warning above 48 hours —
    #     written explicitly, with no base-week choice, so the page opens on the
    #     configured default rules and a base week nobody has confirmed.
    #
    # The nine runs, one per block, are named by day type the way operators and
    # GTFS feeds name them: 1001-1005 weekday, 6001-6002 Saturday, 7001-7002
    # Sunday.
    #
    #   * 301/302/303/304/305 → weekday runs 1001 (early), 1002 (shortly after
    #     1001 signs off), 1003, 1004 and 1005 (afternoon). Each block works one
    #     block, so each run is a single piece;
    #   * 401/402 → Saturday runs 6001 and 6002;
    #   * 501 is the LATE Sunday run: it works 20:00-21:15, so it signs off
    #     after 21:00 and leaves under the ten hours of rest that 1002's early
    #     Monday sign-on needs — that pair is the seeded short rest;
    #   * 502 is an ordinary Sunday morning run.
    #
    # The five lines cover the states the page opens on, each isolated from the
    # others so a fix cannot disturb a second one:
    #
    #   * line 1 — Mon-Fri on run 1001 with the pick recorded for E9001: an
    #     assigned line, and the ordinary case;
    #   * line 2 — Monday on 1002 and Sunday on 7001: SHORT REST. The Sunday run
    #     signs off too late for the Monday sign-on, which a manual per-day edit
    #     is allowed to do;
    #   * line 3 — Mon-Fri on 1003 plus Saturday on 6001: DAYS OFF APART. Sunday
    #     is the only day off, so there is no two in a row anywhere in the week;
    #   * line 4 — Saturday on 6002 and Sunday on 7002: an OPEN line, no pick
    #     recorded, which is also what the export's "line has no operator"
    #     warning and the pick drawer both need;
    #   * line 5 — Mon-Fri on 1004 with Friday's stored times moved ten minutes
    #     earlier than the run's own: the STALE slot ("Run changed"), written
    #     straight to the row because every writer stores the run's current
    #     times, so a re-cut is the only way production reaches this state;
    #   * weekday run 1005 is on no line at all, so "Create Mon-Fri line" has a
    #     fully open run to build from.
    #
    # Six synthetic operators carry the picks and the seniority column: E9001 to
    # E9006, four with a seniority number and the last two without, so the
    # operators drawer's "no seniority number" state is reachable.
    #
    # Block IDs are numeric (301-305, 401-402, 501-502) and every name is
    # `RS_`-prefixed, so this version collides with neither the `BB-`, `AB-` nor
    # `RN_` names. The version is backdated to 2020-06-01, after the runs version
    # and long before the `DateTime.utc_now()` defaults, so it never becomes the
    # organization's latest published default.
    {:ok, rosters_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Rosters Version"})

    rosters_version =
      Repo.update!(
        Ecto.Changeset.change(rosters_version,
          published_at: ~U[2020-06-01 00:00:00.000000Z]
        )
      )

    rosters_week_start = ~D[2026-09-07]
    rosters_week_end = ~D[2027-06-25]

    for {service_id, name, days} <- [
          {"WKDY", "Weekday",
           [monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1, saturday: 0, sunday: 0]},
          {"SAT", "Saturday",
           [monday: 0, tuesday: 0, wednesday: 0, thursday: 0, friday: 0, saturday: 1, sunday: 0]},
          {"SUN", "Sunday",
           [monday: 0, tuesday: 0, wednesday: 0, thursday: 0, friday: 0, saturday: 0, sunday: 1]}
        ] do
      attrs =
        Map.merge(
          %{
            service_id: service_id,
            name: name,
            start_date: rosters_week_start,
            end_date: rosters_week_end
          },
          Map.new(days)
        )

      GtfsPlanner.BlockingFixtures.calendar_service_fixture(
        org.id,
        rosters_version.id,
        attrs
      )
    end

    # Labor Day 2026-09-07 runs the Sunday service: WKDY is dropped for the date
    # and SUN is added. Removing the weekday service matters as much as adding
    # the other one — leaving both active would make the date a day type of its
    # own, and a day type with no run of its own reports nothing at all.
    GtfsPlanner.GtfsFixtures.calendar_date_fixture(org.id, rosters_version.id, %{
      service_id: "WKDY",
      date: ~D[2026-09-07],
      exception_type: 2
    })

    GtfsPlanner.GtfsFixtures.calendar_date_fixture(org.id, rosters_version.id, %{
      service_id: "SUN",
      date: ~D[2026-09-07],
      exception_type: 1
    })

    # One marked station and two plain terminals. Every trip runs between the two
    # terminals and every block runs out of the garage and back, so a run's
    # report time, travel and paid time are derived from real distances rather
    # than assumed.
    for {stop_id, stop_name, location_type, lat, lon} <- [
          {"RS_DPT", "Riverside Depot", 1, 40.740000, -74.000000},
          {"RS_TERM_A", "Riverside Terminal", 0, 40.750000, -74.000000},
          {"RS_TERM_B", "Valley Terminal", 0, 40.730000, -74.000000}
        ] do
      AdvancedBlockingFixtures.stop_with_coordinates_fixture(org.id, rosters_version.id, %{
        stop_id: stop_id,
        stop_name: stop_name,
        location_type: location_type,
        stop_lat: lat,
        stop_lon: lon
      })
    end

    # Route creation on the editor surface is two-phase: `create_editor_route/3`
    # authorizes and inserts against an audit and a signed attempt id, and the
    # attempt is what makes a retry replay rather than duplicate. A seed makes
    # one deliberate attempt per route, so each gets its own id.
    rosters_audit = seed_audit.(rosters_version)

    seed_rosters_route = fn attrs ->
      attempt = %{
        creation_attempt_id: Ecto.UUID.generate(),
        actor_id: editor.id,
        organization_id: org.id,
        gtfs_version_id: rosters_version.id
      }

      {:ok, %{route: route}} = Gtfs.create_editor_route(attrs, attempt, rosters_audit)

      case Gtfs.reconcile_creation(attempt, rosters_audit) do
        {:ok, ^route} ->
          :ok

        other ->
          raise "browser seed route reconcile did not return the created route: #{inspect(other)}"
      end

      route
    end

    rosters_routes =
      [
        {"RS_R10", "10", "Riverside - Valley", "1F5FBF"},
        {"RS_R20", "20", "Riverside Crosstown", "267548"}
      ]
      |> Map.new(fn {route_id, short_name, long_name, color} ->
        route =
          seed_rosters_route.(%{
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3,
            route_color: color,
            route_text_color: "FFFFFF",
            text_mode: "automatic"
          })

        {route_id, route}
      end)

    rosters_trip = fn attrs ->
      attrs = Map.new(attrs)

      GtfsPlanner.BlockingFixtures.blocked_trip_fixture(
        org.id,
        rosters_version.id,
        Map.fetch!(rosters_routes, Map.fetch!(attrs, :route_id)).route_id,
        Map.merge(
          Map.take(attrs, [
            :trip_id,
            :block_id,
            :trip_headsign,
            :first_stop,
            :last_stop,
            :first_arrival,
            :last_arrival
          ]),
          %{service_id: Map.get(attrs, :service_id, "WKDY")}
        )
      )
    end

    # Two trips per block, alternating direction, so every block is a real one-way
    # run out and back rather than a single trip with nothing to lay over.
    # 501's times are the load-bearing row: a block that ends after 21:00 is what
    # leaves less than ten hours of rest before an early Monday sign-on.
    for {trip_id, block_id, route_id, service_id, first_stop, last_stop, first_arrival,
         last_arrival} <- [
          # 301 — the early weekday run, on line 1 every weekday.
          {"3101", "301", "RS_R10", "WKDY", "RS_TERM_A", "RS_TERM_B", "05:00:00", "05:30:00"},
          {"3102", "301", "RS_R10", "WKDY", "RS_TERM_B", "RS_TERM_A", "06:00:00", "06:30:00"},
          # 302 — the run behind the seeded short rest: it signs on shortly after
          # 1001 signs off, so line 2 pairs it with Sunday's late run instead.
          {"3103", "302", "RS_R10", "WKDY", "RS_TERM_A", "RS_TERM_B", "07:00:00", "07:30:00"},
          {"3104", "302", "RS_R10", "WKDY", "RS_TERM_B", "RS_TERM_A", "07:45:00", "08:15:00"},
          # 303 — the days-off-apart line's run.
          {"3105", "303", "RS_R20", "WKDY", "RS_TERM_A", "RS_TERM_B", "09:00:00", "09:30:00"},
          {"3106", "303", "RS_R20", "WKDY", "RS_TERM_B", "RS_TERM_A", "09:45:00", "10:15:00"},
          # 304 — the stale line's run. Friday's slot then stores times ten
          # minutes earlier than these, which is what a re-cut looks like.
          {"3107", "304", "RS_R20", "WKDY", "RS_TERM_A", "RS_TERM_B", "11:00:00", "11:30:00"},
          {"3108", "304", "RS_R20", "WKDY", "RS_TERM_B", "RS_TERM_A", "11:45:00", "12:15:00"},
          # 305 — the afternoon run no line holds: "Create Mon-Fri line" builds
          # from it.
          {"3109", "305", "RS_R10", "WKDY", "RS_TERM_A", "RS_TERM_B", "14:00:00", "14:30:00"},
          {"3110", "305", "RS_R10", "WKDY", "RS_TERM_B", "RS_TERM_A", "14:45:00", "15:15:00"},
          # 401 — the Saturday run line 3 also works.
          {"3201", "401", "RS_R10", "SAT", "RS_TERM_A", "RS_TERM_B", "07:00:00", "07:30:00"},
          {"3202", "401", "RS_R10", "SAT", "RS_TERM_B", "RS_TERM_A", "07:45:00", "08:15:00"},
          # 402 — the Saturday half of the open weekend line.
          {"3203", "402", "RS_R20", "SAT", "RS_TERM_A", "RS_TERM_B", "10:00:00", "10:30:00"},
          {"3204", "402", "RS_R20", "SAT", "RS_TERM_B", "RS_TERM_A", "10:45:00", "11:15:00"},
          # 501 — the LATE Sunday run that leaves the short rest on line 2.
          {"3301", "501", "RS_R10", "SUN", "RS_TERM_A", "RS_TERM_B", "20:00:00", "20:30:00"},
          {"3302", "501", "RS_R10", "SUN", "RS_TERM_B", "RS_TERM_A", "20:45:00", "21:15:00"},
          # 502 — an ordinary Sunday morning run.
          {"3303", "502", "RS_R20", "SUN", "RS_TERM_A", "RS_TERM_B", "09:00:00", "09:30:00"},
          {"3304", "502", "RS_R20", "SUN", "RS_TERM_B", "RS_TERM_A", "09:45:00", "10:15:00"}
        ] do
      rosters_trip.(%{
        trip_id: trip_id,
        route_id: route_id,
        block_id: block_id,
        first_stop: first_stop,
        last_stop: last_stop,
        first_arrival: first_arrival,
        last_arrival: last_arrival,
        service_id: service_id
      })
    end

    rosters_trip_by_id =
      Ecto.Query.from(t in GtfsPlanner.Gtfs.Trip,
        where: t.organization_id == ^org.id and t.gtfs_version_id == ^rosters_version.id,
        select: t
      )
      |> GtfsPlanner.Repo.all()
      |> Map.new(&{&1.trip_id, &1})

    rosters_garage =
      GtfsPlanner.OperationsFixtures.garage_fixture(org.id, %{
        garage_id: "RSGB",
        name: "Riverside Garage",
        lat: 40.740000,
        lon: -74.000000
      })

    for {service_id, block_id} <- [
          {"WKDY", "301"},
          {"WKDY", "302"},
          {"WKDY", "303"},
          {"WKDY", "304"},
          {"WKDY", "305"},
          {"SAT", "401"},
          {"SAT", "402"},
          {"SUN", "501"},
          {"SUN", "502"}
        ] do
      AdvancedBlockingFixtures.block_attribute_fixture(org.id, rosters_version.id, %{
        service_id: service_id,
        block_id: block_id,
        garage_id: rosters_garage.id
      })
    end

    {:ok, _rosters_blocking} =
      GtfsPlanner.Gtfs.Blocking.update_settings(seed_audit.(rosters_version), %{
        min_layover_minutes: 5,
        max_block_minutes: nil,
        pull_out_buffer_minutes: 0,
        interlining: :any,
        deadhead_speed_kmh: 30,
        deadhead_circuity: Decimal.new("1.3"),
        max_piece_minutes: 330,
        default_garage_id: rosters_garage.id
      })

    AdvancedBlockingFixtures.relief_point_fixture(org.id, rosters_version.id, %{
      stop_id: "RS_DPT"
    })

    {:ok, _rosters_crew} =
      GtfsPlanner.Gtfs.update_crew_settings(seed_audit.(rosters_version), %{
        report_pull_out_minutes: 15,
        report_relief_minutes: 5,
        sign_off_minutes: 5,
        paid_break_max_minutes: 30,
        max_spread_minutes: 720
      })

    # The roster rules, written explicitly so the seeded page's rest and
    # weekly-hours figures come from this version's own row rather than from the
    # researched defaults by accident. No base-week choice is stored, so the
    # base week is the computed default and the settings drawer opens on a week
    # nobody has confirmed.
    {:ok, _rosters_rules} =
      GtfsPlanner.Gtfs.Rosters.update_roster_settings(rosters_audit, %{
        min_rest_minutes: 600,
        weekly_hours_warn_above: 48,
        roster_day_types: %{}
      })

    # The day-type keys, read back through the day load and the same key function
    # the runs section uses, so the `trip_runs` rows name keys this version's own
    # calendars derive.
    rosters_weekday_key =
      case GtfsPlanner.Gtfs.Blocking.load_day(org.id, rosters_version.id, nil) do
        {:ok, day} -> day.day_type.key
        {:error, reason} -> raise "rosters browser seed: no default day type (#{inspect(reason)})"
      end

    rosters_saturday_key = GtfsPlanner.Gtfs.Blocking.DayTypes.key(["SAT"])
    rosters_sunday_key = GtfsPlanner.Gtfs.Blocking.DayTypes.key(["SUN"])

    # The trip_runs rows, one run per block. The block is checked against the
    # trip's own row, the way the runs section checks its own, so a trip silently
    # moved to another block cannot leave a run that does not touch it.
    for {block_id, trip_names, run_id, day_type_key} <- [
          {"301", ["3101", "3102"], "1001", rosters_weekday_key},
          {"302", ["3103", "3104"], "1002", rosters_weekday_key},
          {"303", ["3105", "3106"], "1003", rosters_weekday_key},
          {"304", ["3107", "3108"], "1004", rosters_weekday_key},
          {"305", ["3109", "3110"], "1005", rosters_weekday_key},
          {"401", ["3201", "3202"], "6001", rosters_saturday_key},
          {"402", ["3203", "3204"], "6002", rosters_saturday_key},
          {"501", ["3301", "3302"], "7001", rosters_sunday_key},
          {"502", ["3303", "3304"], "7002", rosters_sunday_key}
        ] do
      for trip_name <- trip_names do
        trip = Map.fetch!(rosters_trip_by_id, trip_name)

        unless trip.block_id == block_id do
          raise "rosters browser seed: trip #{trip_name} is on block #{trip.block_id}, " <>
                  "but the assignment row claims #{block_id}"
        end

        GtfsPlanner.RunsFixtures.trip_run_fixture(org.id, rosters_version.id, %{
          trip: trip,
          day_type_key: day_type_key,
          run_id: run_id
        })
      end
    end

    # The six synthetic operators. Four carry a seniority number and the last two
    # deliberately do not, so the operators drawer's seniority ordering and its
    # "no seniority number" row are both reachable from the seed. The pick is
    # recorded for three of them below; the rest exist to be offered.
    rosters_operators =
      for {employee_id, display_name, seniority_number} <- [
            {"E9001", "Ana Ferreira", 12},
            {"E9002", "Bilal Nasser", 7},
            {"E9003", "Cleo Marchetti", 3},
            {"E9004", "Devon Okafor", nil},
            {"E9005", "Esi Halloran", nil},
            {"E9006", "Femi Adeyemi", 21}
          ] do
        {:ok, operator} =
          GtfsPlanner.Operations.create_operator(org.id, editor, %{
            employee_id: employee_id,
            display_name: display_name,
            seniority_number: seniority_number
          })

        operator
      end

    rosters_operator_by_id = Map.new(rosters_operators, &{&1.employee_id, &1})

    # The five lines, every one written through the production roster writers so
    # the rows are the ones the page's own drawers write: the lock order, the
    # stored run times and the refusals are all the real ones.
    {:ok, roster_line_1} = GtfsPlanner.Gtfs.Rosters.create_line(rosters_audit)

    {:ok, _line_1_group} =
      GtfsPlanner.Gtfs.Rosters.set_weekday_group(
        rosters_audit,
        roster_line_1.id,
        1,
        "1001"
      )

    {:ok, _line_1_pick} =
      GtfsPlanner.Gtfs.Rosters.assign_operator(
        rosters_audit,
        roster_line_1.id,
        Map.fetch!(rosters_operator_by_id, "E9001").id
      )

    # Line 2 — SHORT REST. Two single-day writes rather than one group write,
    # because a manual per-day edit is allowed to leave short rest where a
    # builder would refuse. Sunday's run signs off after 21:00 and Monday's signs
    # on before 05:30, which is under ten hours apart.
    {:ok, roster_line_2} = GtfsPlanner.Gtfs.Rosters.create_line(rosters_audit)

    {:ok, _line_2_monday} =
      GtfsPlanner.Gtfs.Rosters.set_slot(rosters_audit, roster_line_2.id, 1, "1002")

    {:ok, _line_2_sunday} =
      GtfsPlanner.Gtfs.Rosters.set_slot(rosters_audit, roster_line_2.id, 7, "7001")

    # Line 3 — DAYS OFF APART. Mon-Fri plus Saturday leaves Sunday as the only day
    # off, so there is no two in a row anywhere in the cyclic week.
    {:ok, roster_line_3} = GtfsPlanner.Gtfs.Rosters.create_line(rosters_audit)

    {:ok, _line_3_group} =
      GtfsPlanner.Gtfs.Rosters.set_weekday_group(
        rosters_audit,
        roster_line_3.id,
        1,
        "1003"
      )

    {:ok, _line_3_saturday} =
      GtfsPlanner.Gtfs.Rosters.set_slot(rosters_audit, roster_line_3.id, 6, "6001")

    # Line 4 — an OPEN line: a weekend pair with no pick recorded, which is also
    # the export's "line has no operator" warning.
    {:ok, roster_line_4} = GtfsPlanner.Gtfs.Rosters.create_line(rosters_audit)

    {:ok, _line_4_saturday} =
      GtfsPlanner.Gtfs.Rosters.set_slot(rosters_audit, roster_line_4.id, 6, "6002")

    {:ok, _line_4_sunday} =
      GtfsPlanner.Gtfs.Rosters.set_slot(rosters_audit, roster_line_4.id, 7, "7002")

    # Line 5 — the STALE slot. The five weekdays are set through the writer, so
    # every row stores the run's current times; Friday's stored times are then
    # moved ten minutes earlier directly on the row, which is exactly the state a
    # re-cut of run 1004 leaves behind and the only way to reach it without
    # deleting the trip_runs rows (INV-13).
    {:ok, roster_line_5} = GtfsPlanner.Gtfs.Rosters.create_line(rosters_audit)

    {:ok, _line_5_group} =
      GtfsPlanner.Gtfs.Rosters.set_weekday_group(
        rosters_audit,
        roster_line_5.id,
        1,
        "1004"
      )

    {:ok, _line_5_pick} =
      GtfsPlanner.Gtfs.Rosters.assign_operator(
        rosters_audit,
        roster_line_5.id,
        Map.fetch!(rosters_operator_by_id, "E9002").id
      )

    rosters_stale_day =
      Repo.one!(
        Ecto.Query.from(d in GtfsPlanner.Gtfs.RosterLineDay,
          where:
            d.roster_line_id == ^roster_line_5.id and d.weekday == ^5 and
              d.organization_id == ^org.id and d.gtfs_version_id == ^rosters_version.id,
          select: d
        )
      )

    rosters_stale_day
    |> Ecto.Changeset.change(%{run_sign_on_secs: rosters_stale_day.run_sign_on_secs - 600})
    |> Repo.update!()

    IO.puts(
      "Browser seed: rosters version #{rosters_version.id} with 9 runs over 3 day types, " <>
        "6 operators (E9001-E9006) and 5 lines (assigned Mon-Fri, short rest, days off " <>
        "apart, open, stale slot)"
    )

    {:ok, schedules_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Schedules No Calendars"})

    {:ok, _schedule_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: schedules_version.id,
        route_id: "BROWSER_SCHEDULES_NOCAL",
        route_short_name: "SNC",
        route_long_name: "Browser Schedules No Calendars",
        route_type: 3
      })

    IO.puts(
      "Browser seed: version #{schedules_version.name} with no calendars " <>
        "(#{schedules_version.id})"
    )

    # ── Transfer management fixtures (Routes › Transfers) ──
    #
    # A dedicated published version carries the transfer network so the shared
    # Browser E2E Version keeps the route, stop and trip counts other specs assert
    # on. Its `published_at` is backdated so it never becomes the organization's
    # latest published default; the Transfers journeys reach it by this version id.
    {:ok, transfers_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Transfers Version"})

    transfers_version =
      Repo.update!(
        Ecto.Changeset.change(transfers_version,
          published_at: ~U[2020-01-01 00:00:00.000000Z]
        )
      )

    # ── Calendar helper version (spec 25, steps 10-15) ──
    #
    # The Calendar helper journeys need their own version, so the change the
    # helper prepares never lands on a version another spec asserts on. Its
    # `published_at` is backdated like the transfers version above, so the
    # Browser E2E Version keeps the organization's latest-published default
    # while the version switcher still lists this one.
    #
    # The three calendars are the helper's read and prepare material: two
    # Monday-Friday school calendars the journey stops, and a Sunday calendar
    # for the substitution case. `SCHOOL_ROUTE` and its two trips give the
    # school calendars recorded service, so an approved end-date extension has
    # the routes and trips it actually affects to name. Dates are relative to
    # this version's agency-local today (the UTC fallback, because the version
    # has no agency), so "next Monday" stays a real service date on any run
    # date. Rows are inserted directly because this fixture supplies scenario
    # data, not an audited edit.
    {:ok, helper_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Helper Version"})

    helper_version =
      Repo.update!(
        Ecto.Changeset.change(helper_version,
          published_at: ~U[2020-01-02 00:00:00.000000Z]
        )
      )

    helper_today = Gtfs.DisplayClock.today(org.id, helper_version.id).date

    [
      %{
        service_id: "SCHOOL_WD",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0
      },
      %{
        service_id: "SCHOOL_EX",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0
      },
      %{
        service_id: "SUNDAY",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 0,
        sunday: 1
      }
    ]
    |> Enum.map(
      &Map.merge(&1, %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: helper_version.id,
        start_date: Date.add(helper_today, -30),
        end_date: Date.add(helper_today, 90),
        inserted_at: calendar_now,
        updated_at: calendar_now
      })
    )
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.Calendar, &1))

    [
      {"SCHOOL_WD", "School weekdays"},
      {"SCHOOL_EX", "School express"},
      {"SUNDAY", "Sunday service"}
    ]
    |> Enum.map(fn {service_id, description} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: helper_version.id,
        service_id: service_id,
        service_description: description,
        service_schedule_typicality: 0,
        inserted_at: calendar_now,
        updated_at: calendar_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarAttribute, &1))

    IO.puts("Browser seed: helper version #{helper_version.name} (id=#{helper_version.id})")

    # ── Service answers (step 7) ──
    #
    # The A02/A19 feed the ordinary route and calendar helper journeys read: a
    # holiday Thursday whose weekday baseline is removed and replaced by an
    # exception-only calendar, a loop that visits Central Station twice, a
    # frequency trip boarding 15 minutes after its first stop, a trip with no
    # readable time, and H12 keeping Sunday service through `SCHOOL` after
    # `REGULAR` ends. Dates come from `BrowserServiceAnswers`, the same module
    # the OpenRouter stand-in asks about, so both sides name the same dates.
    # The version is backdated like the helper version above, so the Browser E2E
    # Version stays the organization's current one.
    {:ok, answers_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Service Answers Version"})

    answers_version =
      Repo.update!(
        Ecto.Changeset.change(answers_version,
          published_at: ~U[2020-01-03 00:00:00.000000Z]
        )
      )

    {:ok, _answers_agency} =
      GtfsPlanner.GtfsFixtures.insert_agency(%{
        organization_id: org.id,
        gtfs_version_id: answers_version.id,
        agency_id: "BROWSER_ANSWERS_AGENCY",
        agency_name: "Browser Answers Transit",
        agency_url: "https://example.test",
        agency_timezone: "America/New_York"
      })

    for {stop_id, stop_name} <- [{"CENTRAL", "Central Station"}, {"HARBOR", "Harbor Yards"}] do
      {:ok, _stop} =
        GtfsPlanner.GtfsFixtures.insert_stop(%{
          stop_id: stop_id,
          stop_name: stop_name,
          location_type: 0,
          organization_id: org.id,
          gtfs_version_id: answers_version.id
        })
    end

    answers_routes =
      for {route_id, short_name, long_name} <- [
            {"H8", "8", "Harbor shuttle"},
            {"H12", "12", "School connector"}
          ] do
        {:ok, route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: answers_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3
          })

        route
      end
      |> Map.new(&{&1.route_id, &1})

    # `WEEKDAY` is the recurring baseline the holiday removes, `REGULAR` is the
    # calendar the A19 coverage question reviews and `SCHOOL` is H12's alternate
    # Sunday service. `HOLIDAY` has no weekly row at all: only the exception
    # below adds its one date.
    answers_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    [
      %{service_id: "WEEKDAY", days: [1, 2, 3, 4, 5]},
      %{service_id: "REGULAR", days: [1, 2, 3, 4, 5, 6, 7]},
      %{service_id: "SCHOOL", days: [7]}
    ]
    |> Enum.map(fn %{service_id: service_id, days: days} ->
      weekly =
        [:monday, :tuesday, :wednesday, :thursday, :friday, :saturday, :sunday]
        |> Enum.with_index(1)
        |> Map.new(fn {day, index} -> {day, if(index in days, do: 1, else: 0)} end)

      Map.merge(weekly, %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: answers_version.id,
        service_id: service_id,
        start_date: BrowserServiceAnswers.range_start(),
        end_date: BrowserServiceAnswers.range_end(),
        inserted_at: answers_now,
        updated_at: answers_now
      })
    end)
    |> then(&Repo.insert_all(Calendar, &1))

    [
      {"WEEKDAY", BrowserServiceAnswers.thanksgiving(), 2},
      {"HOLIDAY", BrowserServiceAnswers.thanksgiving(), 1}
    ]
    |> Enum.map(fn {service_id, date, exception_type} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: answers_version.id,
        service_id: service_id,
        date: date,
        exception_type: exception_type,
        inserted_at: answers_now,
        updated_at: answers_now
      }
    end)
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarDate, &1))

    [
      {"WEEKDAY", "Weekday service"},
      {"REGULAR", "Standard service"},
      {"SCHOOL", "School Sundays"}
    ]
    |> Enum.map(fn {service_id, description} ->
      %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: answers_version.id,
        service_id: service_id,
        service_description: description,
        service_schedule_typicality: 0,
        inserted_at: answers_now,
        updated_at: answers_now
      }
    end)
    |> then(&Repo.insert_all(CalendarAttribute, &1))

    answers_h8 = Map.fetch!(answers_routes, "H8")
    answers_h12 = Map.fetch!(answers_routes, "H12")

    # H8 leaves Harbor Yards first and boards Central Station 15 minutes later,
    # so Central Station is occurrence 2 on every H8 trip and the holiday
    # question asks for that occurrence after 18:00. The loop gives Central
    # Station a second sequence, which is what makes an unqualified question
    # ambiguous rather than guessed.
    answers_pattern =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, answers_version.id, %{
        route_id: answers_h8.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-ANSWERS-P1",
        route_pattern_name: "Harbor Yards – Central",
        route_pattern_typicality: 1,
        timing_name: "Holiday",
        timing_headsign: "Central Station",
        stops: [
          {"HARBOR", 0, 0, 1},
          {"CENTRAL", 900, 900, 1}
        ]
      })

    # The ordinary holiday trips are linked to the pattern, so the page's own
    # schedule rows and the domain read come from the same materialized stop
    # times. Central Station is 15 minutes after Harbor Yards on this pattern.
    for {trip_id, start_time} <- [
          {"SA-1800", "17:45:00"},
          {"SA-1820", "18:05:00"},
          {"SA-1910", "18:55:00"},
          {"SA-LATE", "24:15:00"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        answers_version.id,
        answers_h8.route_id,
        answers_pattern,
        %{
          service_id: "HOLIDAY",
          trip_id: trip_id,
          start_time: start_time,
          trip_headsign: "Central Station"
        }
      )
    end

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      answers_version.id,
      answers_h8.route_id,
      answers_pattern,
      %{
        service_id: "HOLIDAY",
        trip_id: "SA-LOOP",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Central Station",
        stop_times: [
          {"HARBOR", "18:00:00", "18:00:00"},
          {"CENTRAL", "18:00:00", "18:00:00"},
          {"HARBOR", "21:00:00", "21:00:00"},
          {"CENTRAL", "23:50:00", "23:50:00"}
        ]
      }
    )

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      answers_version.id,
      answers_h8.route_id,
      answers_pattern,
      %{
        service_id: "HOLIDAY",
        trip_id: "SA-FREQ",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Central Station",
        stop_times: [
          {"HARBOR", "20:00:00", "20:00:00"},
          {"CENTRAL", "20:15:00", "20:15:00"}
        ],
        frequencies: [
          %{start_time: "20:00:00", end_time: "22:00:00", headway_secs: 1200, exact_times: 0},
          %{start_time: "21:00:00", end_time: "22:00:00", headway_secs: 600, exact_times: 1}
        ]
      }
    )

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      answers_version.id,
      answers_h8.route_id,
      answers_pattern,
      %{
        service_id: "HOLIDAY",
        trip_id: "SA-UNKNOWN",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Central Station",
        stop_times: [
          {"HARBOR", "19:45:00", "19:45:00"},
          {"CENTRAL", nil, nil}
        ]
      }
    )

    answers_school_pattern =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, answers_version.id, %{
        route_id: answers_h12.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-ANSWERS-P2",
        route_pattern_name: "School – Central",
        route_pattern_typicality: 1,
        timing_name: "Sunday",
        timing_headsign: "Central Station",
        stops: [
          {"CENTRAL", 0, 0, 1},
          {"HARBOR", 600, 600, 1}
        ]
      })

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      answers_version.id,
      answers_h12.route_id,
      answers_school_pattern,
      %{
        service_id: "SCHOOL",
        trip_id: "SA12-SUN-FREQ",
        trip_headsign: "Central Station",
        frequencies: [%{start_time: "12:00:00", end_time: "14:00:00", headway_secs: 1800}]
      }
    )

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      answers_version.id,
      answers_h12.route_id,
      answers_school_pattern,
      %{
        service_id: "SCHOOL",
        trip_id: "SA12-SUN-UNKNOWN",
        state: "custom",
        timed_pattern_id: nil,
        trip_headsign: "Central Station",
        stop_times: [
          {"CENTRAL", nil, nil},
          {"HARBOR", nil, nil}
        ]
      }
    )

    IO.puts(
      "Browser seed: service answers version #{answers_version.name} " <>
        "(id=#{answers_version.id}, holiday #{BrowserServiceAnswers.thanksgiving()})"
    )

    {1, nil} =
      Repo.insert_all(Route, [
        %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: helper_version.id,
          route_id: "SCHOOL_ROUTE",
          route_short_name: "S",
          route_long_name: "School connector",
          route_type: 3,
          route_color: "0D737D",
          route_text_color: "FFFFFF",
          active: true,
          inserted_at: calendar_now,
          updated_at: calendar_now
        }
      ])

    {2, nil} =
      Repo.insert_all(
        Trip,
        Enum.map(~w(SCH1 SCH2), fn trip_id ->
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: helper_version.id,
            route_id: "SCHOOL_ROUTE",
            service_id: "SCHOOL_WD",
            trip_id: trip_id,
            trip_headsign: "School",
            direction_id: 0,
            inserted_at: calendar_now,
            updated_at: calendar_now
          }
        end)
      )

    # The network is built once per version that needs it: "Browser Transfers
    # Version" holds it for the Transfers journeys, whose literal counts count on
    # every rule they did not write, and "Browser Transfer Assistance Version"
    # holds an identical copy for the helper journeys, which write rules of their
    # own and so must not move those counts.
    seed_transfer_network = fn transfers_version ->
      # The station BXF_CEN with its two platforms and an entrance, plus the three
      # top-level stops the trips call at. Children go through the import changeset,
      # the permissive path the import workflow uses for the same shape. An entrance
      # (location_type 2) is deliberately present so station coverage has to exclude
      # it.
      create_transfer_stop = fn stop_id, stop_name, attrs ->
        attrs =
          Map.merge(
            Map.new(attrs),
            %{
              stop_id: stop_id,
              stop_name: stop_name,
              organization_id: org.id,
              gtfs_version_id: transfers_version.id
            }
          )

        if attrs[:parent_station] do
          %Stop{}
          |> Stop.import_changeset(attrs)
          |> Repo.insert!()
        else
          {:ok, stop} = GtfsPlanner.GtfsFixtures.insert_stop(attrs)
          stop
        end
      end

      create_transfer_stop.("BXF_CEN", "Transfer Central Station",
        location_type: 1,
        stop_lat: Decimal.new("40.0390"),
        stop_lon: Decimal.new("-75.1440")
      )

      create_transfer_stop.("BXF_CEN_A", "Transfer Central · Bay A",
        parent_station: "BXF_CEN",
        location_type: 0,
        platform_code: "A",
        stop_lat: Decimal.new("40.0391"),
        stop_lon: Decimal.new("-75.1442")
      )

      create_transfer_stop.("BXF_CEN_C", "Transfer Central · Bay C",
        parent_station: "BXF_CEN",
        location_type: 0,
        platform_code: "C",
        stop_lat: Decimal.new("40.0392"),
        stop_lon: Decimal.new("-75.1438")
      )

      create_transfer_stop.("BXF_CEN_E", "Transfer Central · Main entrance",
        parent_station: "BXF_CEN",
        location_type: 2,
        stop_lat: Decimal.new("40.0393"),
        stop_lon: Decimal.new("-75.1441")
      )

      create_transfer_stop.("BXF_MKT", "Transfer Market Street",
        location_type: 0,
        stop_lat: Decimal.new("40.0450"),
        stop_lon: Decimal.new("-75.1500")
      )

      create_transfer_stop.("BXF_HBR", "Transfer Harbor",
        location_type: 0,
        stop_lat: Decimal.new("40.0330"),
        stop_lon: Decimal.new("-75.1380")
      )

      create_transfer_stop.("BXF_MUS", "Transfer Museum",
        location_type: 0,
        stop_lat: Decimal.new("40.0420"),
        stop_lon: Decimal.new("-75.1560")
      )

      [
        {"BXF_12", "12", "Riverside"},
        {"BXF_24", "24", "Harbor"},
        {"BXF_6", "6", "Museum"}
      ]
      |> Enum.each(fn {route_id, short_name, long_name} ->
        {:ok, _route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: transfers_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3
          })
      end)

      [
        {"BXF_12_0815", "BXF_12", "Harbor",
         [{"BXF_CEN_A", "08:15:00"}, {"BXF_MKT", "08:25:00"}, {"BXF_HBR", "08:40:00"}]},
        {"BXF_12_1010", "BXF_12", "Harbor", [{"BXF_MKT", "10:10:00"}, {"BXF_HBR", "10:25:00"}]},
        {"BXF_24_0840", "BXF_24", "Market Street",
         [{"BXF_CEN_C", "08:40:00"}, {"BXF_HBR", "08:55:00"}, {"BXF_MKT", "09:10:00"}]},
        {"BXF_24_0950", "BXF_24", "Market Street",
         [{"BXF_CEN_A", "09:50:00"}, {"BXF_HBR", "10:05:00"}]},
        {"BXF_6_0815", "BXF_6", "Central", [{"BXF_MUS", "08:15:00"}, {"BXF_CEN_A", "08:30:00"}]}
      ]
      |> Enum.each(fn {trip_id, route_id, headsign, stop_times} ->
        {:ok, _trip} =
          GtfsPlanner.GtfsFixtures.insert_trip(%{
            organization_id: org.id,
            gtfs_version_id: transfers_version.id,
            route_id: route_id,
            trip_id: trip_id,
            service_id: "BXF_WKDY",
            trip_headsign: headsign
          })

        stop_times
        |> Enum.with_index(1)
        |> Enum.each(fn {{stop_id, time}, stop_sequence} ->
          {:ok, _stop_time} =
            GtfsPlanner.GtfsFixtures.insert_stop_time(%{
              organization_id: org.id,
              gtfs_version_id: transfers_version.id,
              trip_id: trip_id,
              stop_id: stop_id,
              stop_sequence: stop_sequence,
              arrival_time: time,
              departure_time: time
            })
        end)
      end)

      # Eight general rules (types 0-3) and two in-seat rows (types 4 and 5),
      # inserted through the import changeset: an ordinary imported shape, not an
      # audited editor write. Rule 5 deliberately competes with rule 4 on the
      # BXF_CEN_A / BXF_12_0815 → BXF_CEN_A / BXF_24_0950 witness, which rule 1 does
      # not cover, so the Needs attention and Compare rules journeys have a real
      # conflict; rule 8 names a route the version does not have, so it needs
      # attention for a different reason.
      [
        %{
          from_stop_id: "BXF_CEN_A",
          to_stop_id: "BXF_CEN_C",
          from_route_id: "BXF_12",
          to_route_id: "BXF_24",
          transfer_type: 2,
          min_transfer_time: 180
        },
        %{
          from_stop_id: "BXF_CEN_C",
          to_stop_id: "BXF_CEN_A",
          from_route_id: "BXF_24",
          to_route_id: "BXF_12",
          transfer_type: 2,
          min_transfer_time: 240
        },
        %{
          from_stop_id: "BXF_CEN",
          to_stop_id: "BXF_CEN",
          transfer_type: 2,
          min_transfer_time: 300
        },
        %{
          from_stop_id: "BXF_CEN",
          to_stop_id: "BXF_CEN",
          from_route_id: "BXF_12",
          transfer_type: 2,
          min_transfer_time: 120
        },
        %{
          from_stop_id: "BXF_CEN",
          to_stop_id: "BXF_CEN",
          to_route_id: "BXF_24",
          transfer_type: 3
        },
        %{
          from_stop_id: "BXF_MKT",
          to_stop_id: "BXF_MKT",
          from_route_id: "BXF_12",
          to_route_id: "BXF_24",
          transfer_type: 1
        },
        %{from_stop_id: "BXF_MUS", to_stop_id: "BXF_HBR", transfer_type: 3},
        %{
          from_stop_id: "BXF_HBR",
          to_stop_id: "BXF_HBR",
          from_route_id: "BXF_GONE",
          transfer_type: 0
        },
        %{
          from_stop_id: "BXF_CEN",
          to_stop_id: "BXF_CEN",
          from_trip_id: "BXF_12_0815",
          to_trip_id: "BXF_24_0840",
          transfer_type: 4
        },
        %{
          from_trip_id: "BXF_24_0840",
          to_trip_id: "BXF_12_1010",
          transfer_type: 5
        }
      ]
      |> Enum.each(fn attrs ->
        %Transfer{}
        |> Transfer.changeset(
          Map.merge(attrs, %{
            organization_id: org.id,
            gtfs_version_id: transfers_version.id
          })
        )
        |> Repo.insert!()
      end)

      IO.puts(
        "Browser seed: transfers version #{transfers_version.name} (#{transfers_version.id}) with 8 general rules and 2 in-seat rows"
      )
    end

    seed_transfer_network.(transfers_version)

    {:ok, transfer_assistance_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Transfer Assistance Version"})

    transfer_assistance_version =
      Repo.update!(
        Ecto.Changeset.change(transfer_assistance_version,
          published_at: ~U[2020-03-03 00:00:00.000000Z]
        )
      )

    seed_transfer_network.(transfer_assistance_version)

    # ── Feed details page (settings_agencies_feed.spec.js; EV-4, EV-5) ──
    #
    # Two published versions give the Feed details page its two states: one with a
    # stored `feed_info` row, and one without. They are created last, so the
    # version that was the organization's latest default before this block is
    # re-stamped afterwards and the selection the other journeys start from does
    # not move.
    {:ok, feed_details_default_before} = Versions.get_latest_gtfs_version(org.id)

    {:ok, feed_details_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Feed Details Version"})

    # Inserted directly: this supplies scenario data, not an audited editor save.
    Repo.insert!(%FeedInfo{
      organization_id: org.id,
      gtfs_version_id: feed_details_version.id,
      feed_publisher_name: "Browser Regional Partnership",
      feed_publisher_url: "https://example.test/data",
      feed_lang: "en",
      default_lang: "en",
      feed_start_date: ~D[2026-09-01],
      feed_end_date: ~D[2026-12-31],
      feed_version: "2026-autumn",
      feed_contact_email: "data@example.test",
      feed_contact_url: "https://example.test/data/contact"
    })

    {:ok, feed_empty_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Feed Empty Version"})

    feed_details_default_before
    |> Ecto.Changeset.change(published_at: DateTime.utc_now())
    |> Repo.update!()

    IO.puts(
      "Browser seed: feed details version #{feed_details_version.id} with feed info, " <>
        "empty version #{feed_empty_version.id}, default kept as #{feed_details_default_before.name}"
    )

    # ── Calendar resource scale versions (step 21) ──
    #
    # Two dedicated published versions carry 100 calendar identities each: the size
    # `docs/requirements/calendars-and-service-periods-requirements.md` §5.1 names for the
    # two-second calendar-list target. They are resource fixtures, not journeys. The one-year
    # version spans half a year either side of the version's agency-local today; the long-history
    # version spans nine years ending eleven months ahead (2019-01-01..2027-12-31 on the day this
    # fixture was recorded), so its whole-feed view opens on the disclosed recent window and
    # "Show all years" exposes the compressed axis. Five shapes cycle across the indices, so one
    # screen holds the weekly, exception-only and metadata-only families, and every row is
    # inserted directly because this fixture supplies scenario data, not an audited edit.
    for {resource_name, resource_start_offset, resource_end_offset, resource_route_id} <- [
          {"Browser Calendar Scale One Year", -182, 182, "RSC_YEAR"},
          {"Browser Calendar Scale Long History", -2_827, 459, "RSC_LONG"}
        ] do
      {:ok, resource_version} = Versions.create_gtfs_version(org.id, %{name: resource_name})

      resource_today = Gtfs.DisplayClock.today(org.id, resource_version.id).date
      resource_now = DateTime.utc_now()
      resource_first = Date.add(resource_today, resource_start_offset)
      resource_last = Date.add(resource_today, resource_end_offset)
      resource_span = Date.diff(resource_last, resource_first)

      resource_service_id = fn index ->
        "RSC_" <> String.pad_leading(Integer.to_string(index), 3, "0")
      end

      # A break of three consecutive removed regular service days anchors on a Monday, so a
      # Mon-Fri identity really loses three service days there whatever day the seed runs.
      resource_break = fn offset ->
        base = Date.add(resource_first, offset)
        Date.add(base, rem(8 - Date.day_of_week(base), 7))
      end

      resource_indexes = 0..99

      resource_weekly =
        for index <- resource_indexes, rem(index, 5) in [0, 1, 3] do
          all_days? = rem(index, 5) == 0

          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: resource_version.id,
            service_id: resource_service_id.(index),
            monday: 1,
            tuesday: 1,
            wednesday: 1,
            thursday: 1,
            friday: 1,
            saturday: if(all_days?, do: 1, else: 0),
            sunday: if(all_days?, do: 1, else: 0),
            start_date: resource_first,
            end_date: resource_last,
            inserted_at: resource_now,
            updated_at: resource_now
          }
        end

      resource_attributes =
        for index <- resource_indexes do
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: resource_version.id,
            service_id: resource_service_id.(index),
            service_description: "Resource service #{index}",
            service_schedule_typicality: 0,
            inserted_at: resource_now,
            updated_at: resource_now
          }
        end

      resource_exceptions =
        Enum.flat_map(resource_indexes, fn index ->
          case rem(index, 5) do
            # A Mon-Fri identity gains one Saturday inside its range.
            1 ->
              [{index, Date.add(resource_first, 40), 1}]

            # A dates-only identity: one addition a month ahead, so the row is drawn in every
            # view of both versions, plus two historical additions inside its own span.
            2 ->
              [
                Date.add(resource_today, 30),
                Date.add(resource_first, div(resource_span, 4)),
                Date.add(resource_first, div(resource_span, 2))
              ]
              |> Enum.map(&{index, &1, 1})

            # Two real breaks across the axis: three consecutive removed weekdays each.
            3 ->
              for offset <- [div(resource_span, 3), div(2 * resource_span, 3)],
                  removed <- 0..2 do
                {index, Date.add(resource_break.(offset), removed), 2}
              end

            _other ->
              []
          end
        end)
        |> Enum.map(fn {index, date, exception_type} ->
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: resource_version.id,
            service_id: resource_service_id.(index),
            date: date,
            exception_type: exception_type,
            inserted_at: resource_now,
            updated_at: resource_now
          }
        end)

      resource_trips =
        for index <- resource_indexes, rem(index, 5) != 4, position <- 1..2 do
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: resource_version.id,
            route_id: resource_route_id,
            service_id: resource_service_id.(index),
            trip_id:
              "RSC_TRIP_#{String.pad_leading(Integer.to_string(index), 3, "0")}_#{position}",
            trip_headsign: "Resource trip",
            inserted_at: resource_now,
            updated_at: resource_now
          }
        end

      {:ok, _resource_route} =
        GtfsPlanner.GtfsFixtures.insert_route(%{
          organization_id: org.id,
          gtfs_version_id: resource_version.id,
          route_id: resource_route_id,
          route_short_name: "RS",
          route_long_name: resource_name,
          route_type: 3
        })

      Repo.insert_all(GtfsPlanner.Gtfs.Calendar, resource_weekly)
      Repo.insert_all(GtfsPlanner.Gtfs.CalendarAttribute, resource_attributes)
      Repo.insert_all(GtfsPlanner.Gtfs.CalendarDate, resource_exceptions)
      Repo.insert_all(GtfsPlanner.Gtfs.Trip, resource_trips)

      IO.puts(
        "Browser seed: resource version #{resource_name} (#{resource_version.id}) with " <>
          "#{length(resource_weekly)} weekly, #{length(resource_exceptions)} exception and " <>
          "#{length(resource_trips)} trip rows over #{resource_first}..#{resource_last}"
      )
    end

    # Branding once more leaves the Browser E2E Version the current one, so the version panel and
    # every existing list assertion stay as they were.
    diagram_version
    |> Ecto.Changeset.change(published_at: DateTime.utc_now())
    |> Repo.update!()

    # ── Scheduled pathway closures fixtures (pathway_evolutions.spec.js) ──
    #
    # One station with a full set of pathway types and a non-square floorplan,
    # plus the three stations that produce the view's non-list states. All of
    # them reuse the version's existing CAL_DAILY native calendar; no calendar
    # identity is added, so the calendars page keeps exactly the six it had.
    {:ok, evo_station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_STATION",
        stop_name: "Evolutions Test Station",
        location_type: 1,
        stop_lat: Decimal.new("40.7100"),
        stop_lon: Decimal.new("-74.0060"),
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, evo_level} =
      GtfsPlanner.GtfsFixtures.insert_level(%{
        level_id: "BROWSER_EVO_L1",
        level_name: "Evolutions Concourse",
        level_index: 0.0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    # `create_stop_level/1` joins the station's own ids, not its external
    # identifiers, which is the form the other seeded stations use.
    {:ok, evo_stop_level} =
      GtfsPlanner.GtfsFixtures.insert_stop_level(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        stop_id: evo_station.id,
        level_id: evo_level.id,
        diagram_filename: "browser_seed_evo_diagram.png"
      })

    # The same 100 x 80 raster the diagram station uses, on its own file: the
    # source image is deliberately not square, so a later floorplan view cannot
    # pass by assuming a fixed aspect ratio.
    :ok =
      DiagramStorage.store_import_image(
        org.id,
        diagram_version.id,
        evo_station.stop_id,
        evo_stop_level.diagram_filename,
        browser_floorplan_png
      )

    {:ok, evo_entrance} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_ENTRANCE",
        stop_name: "North entrance",
        location_type: 2,
        parent_station: evo_station.stop_id,
        level_id: evo_level.level_id,
        diagram_coordinate: %{"x" => 20, "y" => 15},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, evo_mezzanine} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_MEZZANINE",
        stop_name: "Mezzanine hall",
        location_type: 0,
        parent_station: evo_station.stop_id,
        level_id: evo_level.level_id,
        diagram_coordinate: %{"x" => 50, "y" => 30},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, evo_platform} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_PLATFORM",
        stop_name: "Platform 1",
        location_type: 0,
        parent_station: evo_station.stop_id,
        level_id: evo_level.level_id,
        diagram_coordinate: %{"x" => 78, "y" => 55},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _evo_boarding} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_BOARDING",
        stop_name: "Platform 1 boarding area",
        location_type: 4,
        parent_station: evo_station.stop_id,
        level_id: evo_level.level_id,
        diagram_coordinate: %{"x" => 86, "y" => 66},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    # A second entrance with no pathway at all: its pairs are unreachable even
    # without closures, so the moment preview must list them as `No route`
    # without ever counting them as lost or blaming a closure for them.
    {:ok, _evo_east_entrance} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_EAST_ENTRANCE",
        stop_name: "East entrance",
        location_type: 2,
        parent_station: evo_station.stop_id,
        level_id: evo_level.level_id,
        diagram_coordinate: %{"x" => 20, "y" => 66},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    # A slash and spaces in one pathway_id, so a `?pathway=` link has to be
    # encoded and decoded exactly rather than read as a path segment.
    {:ok, _evo_walkway} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_EVO_PW_WALK",
        from_stop_id: evo_entrance.stop_id,
        to_stop_id: evo_mezzanine.stop_id,
        pathway_mode: 1,
        is_bidirectional: true,
        traversal_time: 30,
        length: Decimal.new("18.0")
      })

    {:ok, _evo_elevator} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_EVO/PW LIFT 1",
        from_stop_id: evo_mezzanine.stop_id,
        to_stop_id: evo_platform.stop_id,
        pathway_mode: 5,
        is_bidirectional: true,
        traversal_time: 45,
        length: Decimal.new("12.5")
      })

    {:ok, _evo_stairs} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_EVO_PW_STAIR",
        from_stop_id: evo_mezzanine.stop_id,
        to_stop_id: evo_platform.stop_id,
        pathway_mode: 2,
        is_bidirectional: true,
        traversal_time: 60,
        length: Decimal.new("14.0")
      })

    # Two saved closures on the existing CAL_DAILY calendar: an ordinary daytime
    # window and one that continues into the next service day, so the list shows
    # both window notes and a pathway with and without a closure count.
    # `Repo.insert!/1` returns the row itself, so these two are plain matches;
    # only the `Gtfs.create_*` calls above return `{:ok, row}`.
    _evo_closure_day =
      %PathwayEvolution{organization_id: org.id, gtfs_version_id: diagram_version.id}
      |> PathwayEvolution.changeset(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_EVO/PW LIFT 1",
        service_id: "CAL_DAILY",
        start_time: 32_400,
        end_time: 54_000,
        note: "Quarterly inspection."
      })
      |> Repo.insert!()

    _evo_closure_overnight =
      %PathwayEvolution{organization_id: org.id, gtfs_version_id: diagram_version.id}
      |> PathwayEvolution.changeset(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_EVO_PW_STAIR",
        service_id: "CAL_DAILY",
        start_time: 79_200,
        end_time: 93_600,
        note: "Slip replacement across the overnight window."
      })
      |> Repo.insert!()

    # A station whose pathways exist and whose version has native calendars, but
    # with nothing scheduled yet: the first-use empty state, which is a
    # different state from a search that matches nothing.
    {:ok, _evo_empty_station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_EMPTY_STATION",
        stop_name: "Evolutions Empty Station",
        location_type: 1,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, evo_empty_a} =
      Gtfs.import_create_stop(%{
        stop_id: "BROWSER_EVO_EMPTY_A",
        stop_name: "Empty concourse",
        location_type: 0,
        parent_station: "BROWSER_EVO_EMPTY_STATION",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, evo_empty_b} =
      Gtfs.import_create_stop(%{
        stop_id: "BROWSER_EVO_EMPTY_B",
        stop_name: "Empty platform",
        location_type: 0,
        parent_station: "BROWSER_EVO_EMPTY_STATION",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _evo_empty_pathway} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        pathway_id: "BROWSER_EVO_EMPTY_PW",
        from_stop_id: evo_empty_a.stop_id,
        to_stop_id: evo_empty_b.stop_id,
        pathway_mode: 1,
        is_bidirectional: true
      })

    # A station with a child stop and no pathways at all: nothing can close.
    {:ok, _evo_nopathway_station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_NOPATHWAY_STATION",
        stop_name: "Evolutions No Pathway Station",
        location_type: 1,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _evo_nopathway_child} =
      Gtfs.import_create_stop(%{
        stop_id: "BROWSER_EVO_NOPATHWAY_CHILD",
        stop_name: "Unconnected platform",
        location_type: 0,
        parent_station: "BROWSER_EVO_NOPATHWAY_STATION",
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts(
      "Browser seed: evolutions station #{evo_station.stop_id} with 3 pathways, " <>
        "2 closures on CAL_DAILY, a second entrance with no pathway, plus empty " <>
        "and no-pathway stations"
    )

    # The published version that exists precisely because it has no calendars.
    # A station with one pathway there renders the view's no-native-calendars
    # state, which needs a station inside a calendar-less version.
    {:ok, _evo_nocal_station} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        stop_id: "BROWSER_EVO_NOCAL_STATION",
        stop_name: "Evolutions No Calendar Station",
        location_type: 1,
        organization_id: org.id,
        gtfs_version_id: schedules_version.id
      })

    {:ok, evo_nocal_a} =
      Gtfs.import_create_stop(%{
        stop_id: "BROWSER_EVO_NOCAL_A",
        stop_name: "No calendar concourse",
        location_type: 0,
        parent_station: "BROWSER_EVO_NOCAL_STATION",
        organization_id: org.id,
        gtfs_version_id: schedules_version.id
      })

    {:ok, evo_nocal_b} =
      Gtfs.import_create_stop(%{
        stop_id: "BROWSER_EVO_NOCAL_B",
        stop_name: "No calendar platform",
        location_type: 0,
        parent_station: "BROWSER_EVO_NOCAL_STATION",
        organization_id: org.id,
        gtfs_version_id: schedules_version.id
      })

    {:ok, _evo_nocal_pathway} =
      Gtfs.apply_import_entity(:add, :pathway, nil, %{
        pathway_id: "BROWSER_EVO_NOCAL_PW",
        pathway_mode: 1,
        is_bidirectional: true,
        from_stop_id: evo_nocal_a.stop_id,
        to_stop_id: evo_nocal_b.stop_id,
        organization_id: org.id,
        gtfs_version_id: schedules_version.id
      })

    IO.puts(
      "Browser seed: evolutions station in #{schedules_version.name} with 1 pathway " <>
        "and no native calendars"
    )

    # ── In-seat connection browser journey (package 11, step 12) ──
    #
    # A published "Browser In-Seat Version" carries every connection and record
    # case the in-seat UI steps (13-28) and the EV-29 journey need, isolated from
    # every other scenario by its version and by its `BIS_`/`BIS-` names:
    #
    #   * three calendars — "Weekday service" every weekday, "School days" on
    #     Monday, Wednesday and Friday and "No school days" on Tuesday and
    #     Thursday — which derive two day types, {School days, Weekday service}
    #     (the most trips, so the page's default) and {No school days, Weekday
    #     service};
    #   * a same-stop group of four Route 12 → Route 24 connections at BIS_FAR_A
    #     (`BIS-FA1`…`BIS-FA4`), the first already carrying a matching type-4
    #     record, so the group panel's "Set all" has an already-set row;
    #   * a Route 57 turnback group of two connections at BIS_UNION, whose first
    #     departure row carries `pickup_type` 1 (no pickup), so the choice form's
    #     R14 warning has a real pair;
    #   * a 370 m empty move and a 180 m nearby handoff with a 14-minute wait;
    #   * a "School Junction" group of three Route 12 → Route 24 connections
    #     (`BIS-SHARED-1`…`BIS-SHARED-3`) whose first block runs a `BIS_NOSCHOOL`
    #     trip between the pair, so its type-4 record is stale with a named next
    #     trip and "Set all" has a row to skip;
    #   * an "Old Alignment" pair carrying a stopless type-4 row beside a type-5
    #     row (a conflict) and a second pair whose record names a stop its to-trip
    #     no longer starts at (old stops);
    #   * an "Unknown Place" group of two whose arrival stop BIS_NOCOORD is stored
    #     without coordinates, one of them a type-5 row, so the network map
    #     reports a place it cannot draw;
    #   * two records naming trips that have no block, which are the version's
    #     unmatched rows.
    #
    # Backdated, so this version never becomes the organization's latest published
    # default and every existing browser journey keeps opening "Browser E2E
    # Version". The `BIS_MOVE_A`→`BIS_MOVE_B` and `BIS_NEAR_A`→`BIS_NEAR_B`
    # coordinates are the exact 370 m and 180 m great-circle separations the
    # connection drawer prints, so the move and the nearby handoff need no
    # rounding to land on their cases.
    {:ok, in_seat_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser In-Seat Version"})

    in_seat_version =
      Repo.update!(
        Ecto.Changeset.change(in_seat_version,
          published_at: ~U[2020-03-01 00:00:00.000000Z]
        )
      )

    bis_week_start = ~D[2026-09-07]
    bis_week_end = ~D[2026-10-30]

    for {service_id, name, days} <- [
          {"BIS_WEEK", "Weekday service",
           [monday: 1, tuesday: 1, wednesday: 1, thursday: 1, friday: 1]},
          {"BIS_SCHOOL", "School days", [monday: 1, wednesday: 1, friday: 1]},
          {"BIS_NOSCHOOL", "No school days", [tuesday: 1, thursday: 1]}
        ] do
      GtfsPlanner.BlockingFixtures.calendar_service_fixture(org.id, in_seat_version.id, %{
        service_id: service_id,
        name: name,
        monday: Keyword.get(days, :monday, 0),
        tuesday: Keyword.get(days, :tuesday, 0),
        wednesday: Keyword.get(days, :wednesday, 0),
        thursday: Keyword.get(days, :thursday, 0),
        friday: Keyword.get(days, :friday, 0),
        saturday: 0,
        sunday: 0,
        start_date: bis_week_start,
        end_date: bis_week_end
      })
    end

    # Every stop but BIS_NOCOORD carries coordinates, so the two handoffs the
    # drawer measures have exact distances and the one place the network map
    # cannot draw is the only stop stored without them.
    bis_stops =
      for {stop_id, name, lat, lon} <- [
            {"BIS_FAR_A", "Far Avenue", "40.70000000", "-74.01000000"},
            {"BIS_FAR_END", "Far Avenue Terminus", "40.70400000", "-74.01000000"},
            {"BIS_UNION", "Union Station", "40.71000000", "-74.00600000"},
            {"BIS_UNION_END", "Union Plaza", "40.71400000", "-74.00600000"},
            {"BIS_TURN_END", "Union Yards", "40.71800000", "-74.00600000"},
            {"BIS_DEPOT", "Depot Yard", "40.79600000", "-73.94000000"},
            {"BIS_MOVE_A", "Depot Row", "40.80000000", "-73.94000000"},
            {"BIS_MOVE_B", "Depot Row North", "40.80332746", "-73.94000000"},
            {"BIS_MOVE_END", "Depot Row Terminus", "40.80700000", "-73.94000000"},
            {"BIS_NEAR_START", "Market Street", "40.80600000", "-73.93000000"},
            {"BIS_NEAR_A", "Market Row", "40.81000000", "-73.93000000"},
            {"BIS_NEAR_B", "Market Row West", "40.81161875", "-73.93000000"},
            {"BIS_NEAR_END", "Market Square", "40.81400000", "-73.93000000"},
            {"BIS_SHARED_A", "School Junction", "40.75000000", "-73.92000000"},
            {"BIS_SHARED_END", "School Junction Terminus", "40.75400000", "-73.92000000"},
            {"BIS_OLD_END", "Old Alignment West", "40.82600000", "-73.91000000"},
            {"BIS_OLD_A", "Old Alignment", "40.83000000", "-73.91000000"},
            {"BIS_OLD_B", "Old Alignment East", "40.83134750", "-73.91000000"},
            {"BIS_OLD_FAR", "Old Alignment Terminus", "40.83800000", "-73.91000000"},
            {"BIS_NOCOORD_END", "Unknown Place Terminus", "40.85000000", "-73.90000000"}
          ],
          into: %{} do
        stop =
          GtfsPlanner.GtfsFixtures.stop_fixture(org.id, in_seat_version.id, %{
            stop_id: stop_id,
            stop_name: name,
            stop_lat: Decimal.new(lat),
            stop_lon: Decimal.new(lon)
          })

        {stop_id, stop}
      end

    # The one place the map cannot draw, created without coordinates exactly as
    # the unlocated-route fixtures above do.
    {:ok, _bis_nocoord} =
      GtfsPlanner.GtfsFixtures.insert_stop(%{
        organization_id: org.id,
        gtfs_version_id: in_seat_version.id,
        stop_id: "BIS_NOCOORD",
        stop_name: "Unknown Place",
        location_type: 0
      })

    bis_routes =
      for {route_id, short_name, long_name} <- [
            {"BIS_R12", "12", "In-seat Avenue"},
            {"BIS_R24", "24", "In-seat Crosstown"},
            {"BIS_R31", "31", "In-seat Depot"},
            {"BIS_R42", "42", "In-seat Market"},
            {"BIS_R57", "57", "In-seat University"}
          ] do
        {:ok, _route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: in_seat_version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: long_name,
            route_type: 3,
            route_color: "1E6868"
          })

        route_id
      end

    # `HH:MM:SS` from minutes after midnight, so every seeded time reads as the
    # clock an editor sees.
    bis_clock = fn mins ->
      [div(mins, 60), rem(mins, 60)]
      |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1), 2, "0"))
      |> Kernel.<>(":00")
    end

    bis_trip = fn attrs ->
      attrs = attrs |> Map.new() |> Map.put_new(:service_id, "BIS_WEEK")

      GtfsPlanner.BlockingFixtures.blocked_trip_fixture(
        org.id,
        in_seat_version.id,
        Map.fetch!(attrs, :route_id),
        Map.take(attrs, [
          :trip_id,
          :service_id,
          :block_id,
          :direction_id,
          :trip_headsign,
          :first_stop,
          :last_stop,
          :first_departure,
          :last_arrival,
          :first_pickup_type,
          :last_drop_off_type
        ])
      )
    end

    # The same-stop group of four. The waits differ so the group reports a range,
    # and only BIS-FA1 carries a record, which matches the block on both weekday
    # day types.
    for {gap, index} <- Enum.with_index([10, 12, 14, 16], 1) do
      base = 8 * 60 + (index - 1) * 40
      block_id = "BIS-FA#{index}"

      far_a =
        bis_trip.(%{
          trip_id: "BIS_FA#{index}A",
          route_id: "BIS_R12",
          block_id: block_id,
          direction_id: 0,
          trip_headsign: "In-seat Avenue",
          first_stop: "BIS_FAR_END",
          last_stop: "BIS_FAR_A",
          first_departure: bis_clock.(base),
          last_arrival: bis_clock.(base + 30)
        })

      far_b =
        bis_trip.(%{
          trip_id: "BIS_FA#{index}B",
          route_id: "BIS_R24",
          block_id: block_id,
          direction_id: 0,
          trip_headsign: "In-seat Crosstown",
          first_stop: "BIS_FAR_A",
          last_stop: "BIS_FAR_END",
          first_departure: bis_clock.(base + 30 + gap),
          last_arrival: bis_clock.(base + 60 + gap)
        })

      if index == 1 do
        GtfsPlanner.BlockingFixtures.in_seat_transfer_fixture(
          org.id,
          in_seat_version.id,
          far_a,
          far_b
        )
      end
    end

    # The turnback group. One vehicle, one route, two directions, and the first
    # to-trip's first stop forbids pickup, so the choice form previews the R14
    # warning on that connection and not on the other.
    for {gap, index} <- Enum.with_index([8, 20], 1) do
      base = 7 * 60 + (index - 1) * 60
      block_id = "BIS-TURN#{index}"

      bis_trip.(%{
        trip_id: "BIS_TURN#{index}A",
        route_id: "BIS_R57",
        block_id: block_id,
        direction_id: 0,
        trip_headsign: "University",
        first_stop: "BIS_UNION_END",
        last_stop: "BIS_UNION",
        first_departure: bis_clock.(base),
        last_arrival: bis_clock.(base + 25)
      })

      bis_trip.(%{
        trip_id: "BIS_TURN#{index}B",
        route_id: "BIS_R57",
        block_id: block_id,
        direction_id: 1,
        trip_headsign: "University",
        first_stop: "BIS_UNION",
        last_stop: "BIS_TURN_END",
        first_departure: bis_clock.(base + 25 + gap),
        last_arrival: bis_clock.(base + 50 + gap),
        first_pickup_type: if(index == 1, do: 1, else: nil)
      })
    end

    # The 370 m empty move: Route 31 leaves the vehicle at Depot Row and Route 42
    # picks it up 370 m north, beyond the 200 m nearby threshold.
    bis_trip.(%{
      trip_id: "BIS_MOVE_T1",
      route_id: "BIS_R31",
      block_id: "BIS-MOVE",
      direction_id: 0,
      trip_headsign: "Depot",
      first_stop: "BIS_DEPOT",
      last_stop: "BIS_MOVE_A",
      first_departure: bis_clock.(14 * 60),
      last_arrival: bis_clock.(14 * 60 + 30)
    })

    bis_trip.(%{
      trip_id: "BIS_MOVE_T2",
      route_id: "BIS_R42",
      block_id: "BIS-MOVE",
      direction_id: 0,
      trip_headsign: "Market",
      first_stop: "BIS_MOVE_B",
      last_stop: "BIS_MOVE_END",
      first_departure: bis_clock.(14 * 60 + 40),
      last_arrival: bis_clock.(15 * 60 + 10)
    })

    # The 180 m nearby handoff with a 14-minute wait, so the drawer carries the
    # wait hint beside the nearby handoff.
    bis_trip.(%{
      trip_id: "BIS_NEAR_T1",
      route_id: "BIS_R42",
      block_id: "BIS-NEAR",
      direction_id: 0,
      trip_headsign: "Market",
      first_stop: "BIS_NEAR_START",
      last_stop: "BIS_NEAR_A",
      first_departure: bis_clock.(13 * 60),
      last_arrival: bis_clock.(13 * 60 + 30)
    })

    bis_trip.(%{
      trip_id: "BIS_NEAR_T2",
      route_id: "BIS_R31",
      block_id: "BIS-NEAR",
      direction_id: 0,
      trip_headsign: "Depot",
      first_stop: "BIS_NEAR_B",
      last_stop: "BIS_NEAR_END",
      first_departure: bis_clock.(13 * 60 + 44),
      last_arrival: bis_clock.(14 * 60 + 14)
    })

    # The shared-trip pair. BIS-SHARED-1 runs BIS_NOSCHOOL's BIS_SH_X between the
    # two weekday trips, so on {School days, Weekday service} the pair is
    # consecutive and on {No school days, Weekday service} it is not: the record
    # is stale and names the trip that actually runs next.
    shared_a =
      bis_trip.(%{
        trip_id: "BIS_SH_A1",
        route_id: "BIS_R12",
        block_id: "BIS-SHARED-1",
        direction_id: 0,
        trip_headsign: "In-seat Avenue",
        first_stop: "BIS_SHARED_END",
        last_stop: "BIS_SHARED_A",
        first_departure: bis_clock.(7 * 60),
        last_arrival: bis_clock.(7 * 60 + 30)
      })

    bis_trip.(%{
      trip_id: "BIS_SH_X",
      route_id: "BIS_R57",
      service_id: "BIS_NOSCHOOL",
      block_id: "BIS-SHARED-1",
      direction_id: 0,
      trip_headsign: "School shuttle",
      first_stop: "BIS_SHARED_A",
      last_stop: "BIS_SHARED_END",
      first_departure: bis_clock.(7 * 60 + 40),
      last_arrival: bis_clock.(7 * 60 + 55)
    })

    shared_b =
      bis_trip.(%{
        trip_id: "BIS_SH_B1",
        route_id: "BIS_R24",
        block_id: "BIS-SHARED-1",
        direction_id: 0,
        trip_headsign: "In-seat Crosstown",
        first_stop: "BIS_SHARED_A",
        last_stop: "BIS_SHARED_END",
        first_departure: bis_clock.(8 * 60 + 5),
        last_arrival: bis_clock.(8 * 60 + 35)
      })

    GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, in_seat_version.id, %{
      from_trip_id: shared_a.trip_id,
      to_trip_id: shared_b.trip_id,
      from_stop_id: "BIS_SHARED_A",
      to_stop_id: "BIS_SHARED_A",
      transfer_type: 4
    })

    # Two quiet neighbours, so the group's "Set all" saves them and skips only
    # the shared-trip pair.
    for {base, index} <- Enum.with_index([9 * 60, 10 * 60 + 30], 2) do
      block_id = "BIS-SHARED-#{index}"

      bis_trip.(%{
        trip_id: "BIS_SH_A#{index}",
        route_id: "BIS_R12",
        block_id: block_id,
        direction_id: 0,
        trip_headsign: "In-seat Avenue",
        first_stop: "BIS_SHARED_END",
        last_stop: "BIS_SHARED_A",
        first_departure: bis_clock.(base),
        last_arrival: bis_clock.(base + 30)
      })

      bis_trip.(%{
        trip_id: "BIS_SH_B#{index}",
        route_id: "BIS_R24",
        block_id: block_id,
        direction_id: 0,
        trip_headsign: "In-seat Crosstown",
        first_stop: "BIS_SHARED_A",
        last_stop: "BIS_SHARED_END",
        first_departure: bis_clock.(base + 40),
        last_arrival: bis_clock.(base + 70)
      })
    end

    # Old Alignment, one place with two groups: the conflict pair and the
    # old-stops pair. Neither connection's handoff is measured between its two
    # stops being the same, so both carry a record and both need review.
    old_conflict_a =
      bis_trip.(%{
        trip_id: "BIS_OLD_T1",
        route_id: "BIS_R31",
        block_id: "BIS-OLD-CONFLICT",
        direction_id: 0,
        trip_headsign: "Depot",
        first_stop: "BIS_OLD_END",
        last_stop: "BIS_OLD_A",
        first_departure: bis_clock.(6 * 60),
        last_arrival: bis_clock.(6 * 60 + 30)
      })

    old_conflict_b =
      bis_trip.(%{
        trip_id: "BIS_OLD_T2",
        route_id: "BIS_R42",
        block_id: "BIS-OLD-CONFLICT",
        direction_id: 0,
        trip_headsign: "Market",
        first_stop: "BIS_OLD_B",
        last_stop: "BIS_OLD_FAR",
        first_departure: bis_clock.(6 * 60 + 40),
        last_arrival: bis_clock.(7 * 60 + 10)
      })

    GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, in_seat_version.id, %{
      from_trip_id: old_conflict_a.trip_id,
      to_trip_id: old_conflict_b.trip_id,
      transfer_type: 4
    })

    GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, in_seat_version.id, %{
      from_trip_id: old_conflict_a.trip_id,
      to_trip_id: old_conflict_b.trip_id,
      from_stop_id: "BIS_OLD_A",
      to_stop_id: "BIS_OLD_B",
      transfer_type: 5
    })

    old_stops_a =
      bis_trip.(%{
        trip_id: "BIS_OLD_T3",
        route_id: "BIS_R42",
        block_id: "BIS-OLD-STOPS",
        direction_id: 0,
        trip_headsign: "Market",
        first_stop: "BIS_OLD_END",
        last_stop: "BIS_OLD_A",
        first_departure: bis_clock.(8 * 60),
        last_arrival: bis_clock.(8 * 60 + 30)
      })

    old_stops_b =
      bis_trip.(%{
        trip_id: "BIS_OLD_T4",
        route_id: "BIS_R24",
        block_id: "BIS-OLD-STOPS",
        direction_id: 0,
        trip_headsign: "In-seat Crosstown",
        first_stop: "BIS_OLD_B",
        last_stop: "BIS_OLD_FAR",
        first_departure: bis_clock.(8 * 60 + 40),
        last_arrival: bis_clock.(9 * 60 + 10)
      })

    # The imported row still names Old Alignment as the to-trip's first stop,
    # which the trip no longer starts at.
    GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, in_seat_version.id, %{
      from_trip_id: old_stops_a.trip_id,
      to_trip_id: old_stops_b.trip_id,
      from_stop_id: "BIS_OLD_A",
      to_stop_id: "BIS_OLD_A",
      transfer_type: 4
    })

    # The place with no coordinates. Its first connection carries a type-5 row,
    # so the Connections list has a "Riders must re-board" chip as well as stay.
    for {base, index} <- Enum.with_index([9 * 60, 10 * 60 + 30], 1) do
      block_id = "BIS-NOCOORD-#{index}"

      nocoord_a =
        bis_trip.(%{
          trip_id: "BIS_NC_T#{index}A",
          route_id: "BIS_R31",
          block_id: block_id,
          direction_id: 0,
          trip_headsign: "Depot",
          first_stop: "BIS_NOCOORD_END",
          last_stop: "BIS_NOCOORD",
          first_departure: bis_clock.(base),
          last_arrival: bis_clock.(base + 30)
        })

      nocoord_b =
        bis_trip.(%{
          trip_id: "BIS_NC_T#{index}B",
          route_id: "BIS_R42",
          block_id: block_id,
          direction_id: 0,
          trip_headsign: "Market",
          first_stop: "BIS_NOCOORD",
          last_stop: "BIS_NOCOORD_END",
          first_departure: bis_clock.(base + 40),
          last_arrival: bis_clock.(base + 70)
        })

      if index == 1 do
        GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, in_seat_version.id, %{
          from_trip_id: nocoord_a.trip_id,
          to_trip_id: nocoord_b.trip_id,
          from_stop_id: "BIS_NOCOORD",
          to_stop_id: "BIS_NOCOORD",
          transfer_type: 5
        })
      end
    end

    # The two unmatched rows: records whose trips carry no block, so no gap ever
    # hosts them and the version-level read lists them with :no_block.
    for {handoff_stop, other_stop, first_trip, second_trip, transfer_type} <- [
          {"BIS_FAR_A", "BIS_FAR_END", "BIS_UNB1", "BIS_UNB2", 4},
          {"BIS_MOVE_B", "BIS_MOVE_END", "BIS_UNB3", "BIS_UNB4", 5}
        ] do
      bis_trip.(%{
        trip_id: first_trip,
        route_id: "BIS_R12",
        direction_id: 0,
        trip_headsign: "In-seat Avenue",
        first_stop: other_stop,
        last_stop: handoff_stop,
        first_departure: bis_clock.(6 * 60),
        last_arrival: bis_clock.(6 * 60 + 20)
      })

      bis_trip.(%{
        trip_id: second_trip,
        route_id: "BIS_R24",
        direction_id: 0,
        trip_headsign: "In-seat Crosstown",
        first_stop: handoff_stop,
        last_stop: other_stop,
        first_departure: bis_clock.(6 * 60 + 25),
        last_arrival: bis_clock.(6 * 60 + 45)
      })

      GtfsPlanner.GtfsFixtures.transfer_fixture(org.id, in_seat_version.id, %{
        from_trip_id: first_trip,
        to_trip_id: second_trip,
        from_stop_id: handoff_stop,
        to_stop_id: handoff_stop,
        transfer_type: transfer_type
      })
    end

    bis_blocked_trips =
      Repo.aggregate(
        from(t in Trip,
          where: t.gtfs_version_id == ^in_seat_version.id and not is_nil(t.block_id)
        ),
        :count
      )

    # Two trips that run only on the school calendar. They are unassigned, so they
    # join the pool instead of a block, and they are what makes {School days,
    # Weekday service} carry more trips than {No school days, Weekday service}:
    # without them the two day types tie on trip count and the page's default
    # would fall to whichever key sorted first.
    for index <- 1..2 do
      bis_trip.(%{
        trip_id: "BIS_SCHOOL_POOL_#{index}",
        route_id: "BIS_R57",
        service_id: "BIS_SCHOOL",
        direction_id: 0,
        trip_headsign: "School shuttle",
        first_stop: "BIS_SHARED_END",
        last_stop: "BIS_SHARED_A",
        first_departure: bis_clock.(16 * 60 + (index - 1) * 30),
        last_arrival: bis_clock.(16 * 60 + 20 + (index - 1) * 30)
      })
    end

    bis_in_seat_records =
      Repo.aggregate(
        from(t in Transfer, where: t.gtfs_version_id == ^in_seat_version.id),
        :count
      )

    IO.puts(
      "Browser seed: version #{in_seat_version.name} (#{in_seat_version.id}) with " <>
        "2 day types, #{map_size(bis_stops) + 1} stops, #{length(bis_routes)} routes, " <>
        "#{bis_blocked_trips} blocked trips and #{bis_in_seat_records} in-seat records"
    )

    IO.puts("Browser seed: restored Browser E2E Version as the latest default")

    # ── Pattern alignment fixtures (spec 12, step 20 and every later visual step) ──
    #
    # One route holds the shell captures: A has four visits with one missing
    # section, a stop pair shared with B and linked trips; B is drawn through
    # the production review/apply composition as the seeded editor, so it has
    # a shared path and an owned shape. LOOP is a drawn loop, IMPORTED carries
    # linked trips on two imported shapes, LONG has 200 visits, GEN-1/GEN-2
    # are missing (GEN-1 touches the 40.7500 stop), ACTIONS holds a drawn
    # five-point section for the step 26 Simplify capture on its own stop
    # pair (so shared-user counts on A/B never move), and the -B patterns are
    # clean copies for the 320 px runs. Tile requests in later steps go
    # through the existing /map/tiles proxy; no live Geoapify call happens here.
    Enum.each(
      [
        {"AL_S1", "Align Central", "40.712800", "-74.006000"},
        {"AL_S2", "Align Civic", "40.713800", "-74.005000"},
        {"AL_S3", "Align Market", "40.714800", "-74.004000"},
        {"AL_S4", "Align Harbor", "40.715800", "-74.003000"},
        {"AL_S5", "Align Park", "40.716800", "-74.002000"},
        {"AL_A1", "Actions North", "40.730000", "-73.990000"},
        {"AL_A2", "Actions Central", "40.731000", "-73.989000"},
        {"AL_A3", "Actions South", "40.732000", "-73.988000"},
        {"AL_G1", "Gen Hilltop", "40.750000", "-73.980000"},
        {"AL_G2", "Gen Valley", "40.751000", "-73.979000"}
      ],
      fn {stop_id, name, lat, lon} ->
        {:ok, _stop} =
          GtfsPlanner.GtfsFixtures.insert_stop(%{
            organization_id: org.id,
            gtfs_version_id: diagram_version.id,
            stop_id: stop_id,
            stop_name: name,
            stop_lat: Decimal.new(lat),
            stop_lon: Decimal.new(lon),
            location_type: 0
          })
      end
    )

    {:ok, align_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: "BROWSER_ALIGN",
        route_short_name: "AL",
        route_long_name: "Browser Alignment",
        route_type: 3
      })

    align_pattern = fn pattern_id ->
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, diagram_version.id, %{
        route_id: align_route.route_id,
        route_pattern_id: pattern_id,
        route_pattern_name: pattern_id,
        direction_id: 0
      })
    end

    align_occurrences = fn pattern, stop_ids ->
      stop_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {stop_id, position} ->
        GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(
          pattern,
          stop_id,
          position
        )
      end)
    end

    align_timing = fn pattern, occurrences ->
      timing =
        GtfsPlanner.GtfsFixtures.timed_pattern_fixture(pattern, %{name: "Alignment"})

      Enum.each(occurrences, fn occurrence ->
        GtfsPlanner.GtfsFixtures.timed_pattern_stop_fixture(timing, occurrence, %{
          arrival_offset: 0,
          departure_offset: 0
        })
      end)

      timing
    end

    align_audit = %GtfsPlanner.Gtfs.AuditContext{
      organization_id: org.id,
      gtfs_version_id: diagram_version.id,
      station_stop_id: nil,
      actor_id: editor.id,
      actor_email: editor.email
    }

    align_draw = fn pattern, entries, scopes ->
      pattern = Repo.reload!(pattern)

      draft =
        Enum.map(entries, fn {position, points} ->
          section =
            pattern
            |> GtfsPlanner.Gtfs.Alignments.resolve()
            |> Map.fetch!(:sections)
            |> Enum.find(&(&1.position == position))

          %{
            "position" => section.position,
            "from_occurrence_id" => section.from_occurrence_id,
            "to_stop_id" => section.to_stop_id,
            "op" => "set",
            "points" => points,
            "base" => %{
              "segment_id" => section.revision.segment_id,
              "lock_version" => section.revision.lock_version
            }
          }
        end)

      {:ok, review} = Gtfs.review_alignment_save(pattern.id, draft, align_audit)

      needed =
        for section <- review.sections,
            section.action == :choose_scope,
            into: %{},
            do: {to_string(section.position), Map.fetch!(scopes, to_string(section.position))}

      choices = %{"scopes" => needed}

      choices =
        if review.requires_confirmation?,
          do: Map.put(choices, "confirm_replacements", true),
          else: choices

      {:ok, _result} =
        Gtfs.apply_alignment_save(pattern.id, draft, choices, review.fingerprint, align_audit)
    end

    pattern_a = align_pattern.("BROWSER-ALIGN-A")
    occurrences_a = align_occurrences.(pattern_a, ["AL_S1", "AL_S2", "AL_S3", "AL_S4"])
    timing_a = align_timing.(pattern_a, occurrences_a)

    pattern_b = align_pattern.("BROWSER-ALIGN-B")
    occurrences_b = align_occurrences.(pattern_b, ["AL_S1", "AL_S2", "AL_S3"])
    align_timing.(pattern_b, occurrences_b)

    align_draw.(pattern_a, [{1, [[-74.005500, 40.713300]]}, {2, [[-74.004500, 40.714300]]}], %{
      "1" => "shared",
      "2" => "local"
    })

    align_draw.(pattern_b, [{1, [[-74.005600, 40.713200]]}, {2, [[-74.004600, 40.714100]]}], %{
      "1" => "shared",
      "2" => "shared"
    })

    # Step 26 needs a saved section with at least 4 anchor-to-anchor
    # points for its Simplify capture. ACTIONS draws one on a fresh stop
    # pair so the A/B shared-user counts never move.
    pattern_actions = align_pattern.("BROWSER-ALIGN-ACTIONS")
    align_occurrences.(pattern_actions, ["AL_A1", "AL_A2", "AL_A3"])

    align_draw.(
      pattern_actions,
      [
        {1, [[-73.989700, 40.730300], [-73.989500, 40.730500], [-73.989200, 40.730700]]},
        {2, [[-73.988500, 40.731500]]}
      ],
      %{"1" => "shared", "2" => "local"}
    )

    {:ok, align_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: align_route.route_id,
        trip_id: "BROWSER_ALIGN_T1",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Alignment",
        direction_id: 0
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(align_trip, %{
      route_pattern_id: "BROWSER-ALIGN-A",
      timed_pattern_id: timing_a.id,
      pattern_derivation_state: "linked"
    })

    ["AL_S1", "AL_S2", "AL_S3", "AL_S4"]
    |> Enum.with_index(1)
    |> Enum.each(fn {stop_id, sequence} ->
      {:ok, _stop_time} =
        GtfsPlanner.GtfsFixtures.insert_stop_time(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          trip_id: "BROWSER_ALIGN_T1",
          stop_id: stop_id,
          stop_sequence: sequence,
          arrival_time: "08:0#{sequence}:00",
          departure_time: "08:0#{sequence}:00"
        })
    end)

    pattern_loop = align_pattern.("BROWSER-ALIGN-LOOP")
    align_occurrences.(pattern_loop, ["AL_S1", "AL_S2", "AL_S3", "AL_S1", "AL_S2"])

    align_draw.(
      pattern_loop,
      [
        {1, [[-74.005500, 40.713300]]},
        {2, [[-74.004500, 40.714300]]},
        {3, [[-74.005000, 40.713500]]},
        {4, [[-74.005600, 40.713200]]}
      ],
      %{"1" => "shared", "2" => "shared", "4" => "shared"}
    )

    pattern_imported = align_pattern.("BROWSER-ALIGN-IMPORTED")
    occurrences_imported = align_occurrences.(pattern_imported, ["AL_S4", "AL_S5"])
    timing_imported = align_timing.(pattern_imported, occurrences_imported)

    for {shape_id, sequence, lat, lon, dist} <- [
          {"IMP-ALIGN-1", 0, "40.715800", "-74.003000", "0"},
          {"IMP-ALIGN-1", 1, "40.716800", "-74.002000", "812.4"},
          {"IMP-ALIGN-2", 0, "40.715900", "-74.003100", "0"},
          {"IMP-ALIGN-2", 1, "40.716900", "-74.002100", "900.0"}
        ] do
      %GtfsPlanner.Gtfs.Shape{}
      |> GtfsPlanner.Gtfs.Shape.changeset(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        shape_id: shape_id,
        shape_pt_sequence: sequence,
        shape_pt_lat: lat,
        shape_pt_lon: lon,
        shape_dist_traveled: dist
      })
      |> Repo.insert!()
    end

    for {trip_id, shape_id} <- [
          {"BROWSER_ALIGN_IMP_T1", "IMP-ALIGN-1"},
          {"BROWSER_ALIGN_IMP_T2", "IMP-ALIGN-2"}
        ] do
      {:ok, trip} =
        GtfsPlanner.GtfsFixtures.insert_trip(%{
          organization_id: org.id,
          gtfs_version_id: diagram_version.id,
          route_id: align_route.route_id,
          trip_id: trip_id,
          service_id: "BROWSER_PATTERN_SERVICE",
          trip_headsign: "Alignment Imported",
          direction_id: 0,
          shape_id: shape_id
        })

      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: "BROWSER-ALIGN-IMPORTED",
        timed_pattern_id: timing_imported.id,
        pattern_derivation_state: "linked"
      })
    end

    long_visits =
      ["AL_S1", "AL_S2", "AL_S3", "AL_S4", "AL_S5"]
      |> Stream.cycle()
      |> Enum.take(200)

    align_occurrences.(align_pattern.("BROWSER-ALIGN-LONG"), long_visits)
    align_occurrences.(align_pattern.("BROWSER-ALIGN-GEN-1"), ["AL_G1", "AL_G2"])
    align_occurrences.(align_pattern.("BROWSER-ALIGN-GEN-2"), ["AL_S3", "AL_S4"])
    align_occurrences.(align_pattern.("BROWSER-ALIGN-A-B"), ["AL_S1", "AL_S2", "AL_S3", "AL_S4"])

    align_occurrences.(align_pattern.("BROWSER-ALIGN-LOOP-B"), [
      "AL_S1",
      "AL_S2",
      "AL_S3",
      "AL_S1",
      "AL_S2"
    ])

    align_occurrences.(align_pattern.("BROWSER-ALIGN-IMPORTED-B"), ["AL_S4", "AL_S5"])

    # Step 29 needs a single-shape imported pattern whose shape sits ~500 m
    # north of its stops, so dialog conversion flags its section for review.
    pattern_imported_single = align_pattern.("BROWSER-ALIGN-IMPORTED-SINGLE")
    occurrences_imported_single = align_occurrences.(pattern_imported_single, ["AL_S4", "AL_S5"])
    timing_imported_single = align_timing.(pattern_imported_single, occurrences_imported_single)

    for {shape_id, sequence, lat, lon, dist} <- [
          {"IMP-ALIGN-3", 0, "40.720800", "-74.003000", "0"},
          {"IMP-ALIGN-3", 1, "40.721300", "-74.002500", "70.0"},
          {"IMP-ALIGN-3", 2, "40.721800", "-74.002000", "140.0"}
        ] do
      %GtfsPlanner.Gtfs.Shape{}
      |> GtfsPlanner.Gtfs.Shape.changeset(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        shape_id: shape_id,
        shape_pt_sequence: sequence,
        shape_pt_lat: lat,
        shape_pt_lon: lon,
        shape_dist_traveled: dist
      })
      |> Repo.insert!()
    end

    {:ok, imported_single_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        route_id: align_route.route_id,
        trip_id: "BROWSER_ALIGN_IMP_T3",
        service_id: "BROWSER_PATTERN_SERVICE",
        trip_headsign: "Alignment Imported Single",
        direction_id: 0,
        shape_id: "IMP-ALIGN-3"
      })

    GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(imported_single_trip, %{
      route_pattern_id: "BROWSER-ALIGN-IMPORTED-SINGLE",
      timed_pattern_id: timing_imported_single.id,
      pattern_derivation_state: "linked"
    })

    IO.puts("Browser seed: pattern alignment fixtures (BROWSER_ALIGN with 12 patterns)")

    # ── Agencies list page (settings_agencies_feed.spec.js; EV-16, EV-17) ──
    #
    # Two published versions give the Agencies list page its states: one with
    # three agencies that share a timezone (5, 2 and 0 routes, so the count links,
    # the name sort and the count sort all differ), and one whose two agencies use
    # different timezones (the band, the warning callout and the "Needs review"
    # rows). Both are created last, and the version that was the organization's
    # latest default before them is re-stamped afterwards so the selection the
    # other journeys start from does not move.
    {:ok, agencies_default_before} = Versions.get_latest_gtfs_version(org.id)

    {:ok, agencies_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Agencies Version"})

    for {agency_id, name, host, route_count} <- [
          {"NCT", "North Coast Transit", "northcoast.example", 5},
          {"HBR", "Harbor Shuttle", "harbor.example", 2},
          {"RCT", "Riverside Community Transport", "riverside.example", 0}
        ] do
      {:ok, _agency} =
        GtfsPlanner.GtfsFixtures.insert_agency(%{
          organization_id: org.id,
          gtfs_version_id: agencies_version.id,
          agency_id: agency_id,
          agency_name: name,
          agency_url: "https://#{host}",
          agency_timezone: "America/New_York"
        })

      for index <- 1..route_count//1 do
        {:ok, _route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: agencies_version.id,
            agency_id: agency_id,
            route_id: "#{agency_id}_#{index}",
            route_short_name: "#{index}",
            route_long_name: "#{name} route #{index}",
            route_type: 3
          })
      end
    end

    {:ok, mixed_timezone_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Mixed Timezone Version"})

    for {agency_id, name, host, timezone} <- [
          {"NCT", "North Coast Transit", "northcoast.example", "America/New_York"},
          {"LFT", "Lakefront Transit", "lakefront.example", "America/Chicago"}
        ] do
      {:ok, _agency} =
        GtfsPlanner.GtfsFixtures.insert_agency(%{
          organization_id: org.id,
          gtfs_version_id: mixed_timezone_version.id,
          agency_id: agency_id,
          agency_name: name,
          agency_url: "https://#{host}",
          agency_timezone: timezone
        })

      {:ok, _route} =
        GtfsPlanner.GtfsFixtures.insert_route(%{
          organization_id: org.id,
          gtfs_version_id: mixed_timezone_version.id,
          agency_id: agency_id,
          route_id: "MIX_#{agency_id}",
          route_short_name: agency_id,
          route_long_name: "#{name} mixed-timezone route",
          route_type: 3
        })
    end

    # The empty agency list and the first-agency drawer need a version that has
    # neither agencies nor routes, so nothing is backfilled and the create form
    # is the one with the schedule timezone field (settings_agencies_feed.spec.js;
    # EV-20, EV-21).
    {:ok, no_agency_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser No Agency Version"})

    # The delete flow needs one version where an agency with routes, the agency
    # that receives them and an agency a fare attribute still names all exist at
    # once (settings_agencies_feed.spec.js; EV-25). "Browser Alpha" holds the two
    # routes that move, "Browser Beta" receives them, and "Browser Gamma" has no
    # routes but is named by F-BROWSER, which the deletion has to refuse. The fare
    # attribute has no editor in this package, so it is inserted directly: that
    # supplies the reference the review reads, not an audited editor save.
    {:ok, agency_delete_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Agency Delete Version"})

    for {agency_id, name, host, route_count} <- [
          {"ALPHA", "Browser Alpha", "alpha.example", 2},
          {"BETA", "Browser Beta", "beta.example", 1},
          {"GAMMA", "Browser Gamma", "gamma.example", 0}
        ] do
      {:ok, _agency} =
        GtfsPlanner.GtfsFixtures.insert_agency(%{
          organization_id: org.id,
          gtfs_version_id: agency_delete_version.id,
          agency_id: agency_id,
          agency_name: name,
          agency_url: "https://#{host}",
          agency_timezone: "America/New_York"
        })

      for index <- 1..route_count//1 do
        {:ok, _route} =
          GtfsPlanner.GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: agency_delete_version.id,
            agency_id: agency_id,
            route_id: "#{agency_id}_#{index}",
            route_short_name: "#{index}",
            route_long_name: "#{name} route #{index}",
            route_type: 3
          })
      end
    end

    Repo.insert!(%FareAttribute{
      organization_id: org.id,
      gtfs_version_id: agency_delete_version.id,
      fare_id: "F-BROWSER",
      price: Decimal.new("2.50"),
      currency_type: "USD",
      payment_method: 0,
      agency_id: "GAMMA"
    })

    # The Routes onboarding needs a version with neither agencies nor routes, so
    # the page renders the first-agency state, and a version with two routes that
    # carry no agency, so it renders the assign-routes callout
    # (settings_agencies_feed.spec.js; EV-29). The routes are created directly:
    # this supplies the unassigned state the callout describes, not an editor save.
    {:ok, onboarding_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Onboarding Version"})

    {:ok, unassigned_routes_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Unassigned Routes Version"})

    for index <- 1..2//1 do
      {:ok, _route} =
        GtfsPlanner.GtfsFixtures.insert_route(%{
          organization_id: org.id,
          gtfs_version_id: unassigned_routes_version.id,
          route_id: "UNASSIGNED_#{index}",
          route_short_name: "#{index}",
          route_long_name: "Unassigned browser route #{index}",
          route_type: 3
        })
    end

    agencies_default_before
    |> Ecto.Changeset.change(published_at: DateTime.utc_now())
    |> Repo.update!()

    IO.puts(
      "Browser seed: agencies version #{agencies_version.id} (NCT 5, HBR 2, RCT 0 routes, " <>
        "America/New_York), mixed timezone version #{mixed_timezone_version.id} " <>
        "(America/New_York and America/Chicago), no-agency version #{no_agency_version.id} " <>
        "(no agencies, no routes), agency delete version #{agency_delete_version.id} " <>
        "(ALPHA 2 routes, BETA 1 route, GAMMA 0 routes with fare F-BROWSER), " <>
        "onboarding version #{onboarding_version.id} (no agencies, no routes), " <>
        "unassigned routes version #{unassigned_routes_version.id} (2 routes with no agency), " <>
        "default kept as #{agencies_default_before.name}"
    )

    # ── Homepage fixtures (26-homepage; home.spec.js, EV-21) ──
    #
    # Two organizations carry the logged-in homepage's seeded states:
    #
    #   * Home Planner Org (planner product) — home-planner@gtfs-planner.test
    #     (editor and admin) sees the attention state: calendars ending ten days
    #     after the seed date, a stopped import, the administrator's own recent
    #     destinations, a check with warnings and an expired export.
    #     home-planner-member@gtfs-planner.test (editor, no changes of their
    #     own) sees the team's changes with author emails.
    #   * Home Pathways Org (product: :pathways) — home-pathways@gtfs-planner.test
    #     (editor and admin) sees a 14-station board: one clean station, five in
    #     progress (stale passed, warning, no run, failed and not-applicable
    #     reachability), eight stations without pathways, one editing status by
    #     another user, a check with warnings and an expired export.
    #
    # Every seeded version is created published after its organization's
    # automatically created default, and the default is then backdated so the
    # seeded service version is unambiguously the organization's latest
    # published version. Versions are organization-scoped, so no existing
    # organization's latest published default changes.
    home_password = "BrowserTest123!"
    home_today = Date.utc_today()

    home_member = fn org, email, roles ->
      user =
        case Accounts.get_user_by_email(email) do
          nil ->
            {:ok, user} = Accounts.register_user(%{email: email, password: home_password})
            Repo.update!(User.confirm_changeset(user))
            user

          existing ->
            existing
        end

      unless Accounts.get_user_org_membership(user.id, org.id) do
        {:ok, _membership} =
          Accounts.create_user_org_membership(%{
            user_id: user.id,
            organization_id: org.id,
            roles: roles
          })
      end

      user
    end

    home_pin_default_version = fn org ->
      from(v in GtfsVersion, where: v.organization_id == ^org.id)
      |> Repo.update_all(set: [published_at: ~U[2020-01-01 00:00:00.000000Z]])
    end

    home_change_log = fn org, version, attrs ->
      row =
        Map.merge(
          %{
            id: Ecto.UUID.generate(),
            entity_type: "trip",
            entity_id: Ecto.UUID.generate(),
            entity_external_id: Ecto.UUID.generate(),
            station_stop_id: nil,
            actor_id: Ecto.UUID.generate(),
            actor_email: "editor@example.test",
            snapshot: nil,
            changed_fields: nil,
            action: "updated",
            organization_id: org.id,
            gtfs_version_id: version.id,
            inserted_at: DateTime.utc_now()
          },
          attrs
        )

      Repo.insert_all(ChangeLog, [row])
    end

    home_feed_check = fn org, version, errors, warnings ->
      %ValidationRun{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: version.id
      }
      |> ValidationRun.changeset(%{
        run_type: "mobility_data",
        status: "completed",
        errors_count: errors,
        warnings_count: warnings,
        infos_count: 0,
        started_at: DateTime.add(DateTime.utc_now(), -40, :minute)
      })
      |> Repo.insert!()
    end

    home_expired_export = fn org, version, export_type, finished_at ->
      Repo.insert!(
        struct!(ExportRun, %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: version.id,
          export_type: export_type,
          state: :ready,
          phase: :cleanup,
          artifact_key: "exports/#{Ecto.UUID.generate()}.zip",
          artifact_filename: "browser-home-export.zip",
          artifact_sha256: String.duplicate("a", 64),
          artifact_size_bytes: 1024,
          artifact_expires_at: DateTime.add(DateTime.utc_now(), -3, :minute),
          started_at: DateTime.add(finished_at, -10, :minute),
          finished_at: finished_at,
          inserted_at: finished_at,
          updated_at: finished_at
        })
      )
    end

    home_stopped_import = fn org, version_name ->
      {:ok, staging_version} =
        Versions.create_staging_gtfs_version(org.id, %{name: version_name})

      Repo.insert!(
        struct!(ImportRun, %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: staging_version.id,
          version_name: version_name,
          state: "failed",
          failed_file: "stop_times.txt",
          failed_row: 18_204,
          committed_counts: %{},
          counts_complete: true,
          finished_at: DateTime.add(DateTime.utc_now(), -5, :hour)
        })
      )
    end

    # ── Home Planner Org: the attention and new-member states ──
    {:ok, home_planner_org} =
      Organizations.create_organization_unchecked(%{
        name: "Home Planner Org",
        alias: "home-planner-org"
      })

    home_pin_default_version.(home_planner_org)

    {:ok, home_planner_version} =
      Versions.create_gtfs_version(home_planner_org.id, %{name: "September 2026 service"})

    home_planner_admin =
      home_member.(home_planner_org, "home-planner@gtfs-planner.test", [
        "pathways_studio_editor",
        "pathways_studio_admin"
      ])

    _home_planner_member =
      home_member.(home_planner_org, "home-planner-member@gtfs-planner.test", [
        "pathways_studio_editor"
      ])

    _home_planner_route =
      GtfsPlanner.GtfsFixtures.route_fixture(home_planner_org.id, home_planner_version.id, %{
        route_id: "H12",
        route_short_name: "12",
        route_long_name: "Downtown – Riverside",
        route_color: "0B6BCB",
        route_text_color: "FFFFFF"
      })

    # Two calendars without Sunday service, ending ten days from the seed date:
    # the version's horizon is inside the service-end window, so the homepage
    # raises "service ends" from the horizon and never from the Saturday gap.
    for {service_id, description, saturday} <- [
          {"WKDY", "Weekday", 0},
          {"SAT", "Saturday", 1}
        ] do
      GtfsPlanner.GtfsFixtures.calendar_fixture(home_planner_org.id, home_planner_version.id, %{
        service_id: service_id,
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: saturday,
        sunday: 0,
        start_date: Date.add(home_today, -30),
        end_date: Date.add(home_today, 10)
      })

      GtfsPlanner.GtfsFixtures.calendar_attribute_fixture(
        home_planner_org.id,
        home_planner_version.id,
        %{service_id: service_id, service_description: description}
      )
    end

    _home_planner_level =
      GtfsPlanner.GtfsFixtures.level_fixture(home_planner_org.id, home_planner_version.id, %{
        level_id: "L1",
        level_name: "Concourse",
        level_index: 0.0
      })

    _home_planner_station =
      GtfsPlanner.GtfsFixtures.stop_fixture(home_planner_org.id, home_planner_version.id, %{
        stop_id: "HUB",
        stop_name: "Hubbard Street",
        location_type: 1
      })

    _home_planner_platform =
      GtfsPlanner.GtfsFixtures.stop_fixture(home_planner_org.id, home_planner_version.id, %{
        stop_id: "HUB_platform_1",
        stop_name: "Hubbard Street Platform",
        location_type: 0,
        parent_station: "HUB",
        level_id: "L1"
      })

    _home_planner_stop =
      GtfsPlanner.GtfsFixtures.stop_fixture(home_planner_org.id, home_planner_version.id, %{
        stop_id: "H440",
        stop_name: "Harbor Loop",
        location_type: 0
      })

    # Nine trips retimed in three operations on one destination. The resume's
    # featured item is this destination: "9 trips changed on Weekday" and
    # "3 changes that day". The operations are minutes apart, so they share one
    # local day whatever hour the seed runs; the reviewed screenshot shows the
    # count unmasked.
    for {operation_id, first_index, last_index, minutes_ago} <- [
          {"HOME-OP-RETIME-A", 1, 6, 3},
          {"HOME-OP-RETIME-B", 7, 8, 2},
          {"HOME-OP-RETIME-C", 9, 9, 1}
        ] do
      for index <- first_index..last_index do
        trip_id = "H12_TRIP_#{index}"

        GtfsPlanner.GtfsFixtures.trip_fixture(
          home_planner_org.id,
          home_planner_version.id,
          "H12",
          %{trip_id: trip_id, service_id: "WKDY", trip_headsign: "Downtown"}
        )

        home_change_log.(home_planner_org, home_planner_version, %{
          entity_type: "trip",
          entity_external_id: trip_id,
          actor_id: home_planner_admin.id,
          actor_email: home_planner_admin.email,
          changed_fields: %{
            "after" => %{"route_id" => "H12", "service_id" => "WKDY"},
            "operation_id" => operation_id
          },
          inserted_at: DateTime.add(DateTime.utc_now(), -minutes_ago, :minute)
        })
      end
    end

    # Four more destinations, one operation each: a calendar end-date change, a
    # pattern build, a station edit (whose GTFS level L1 the resume links with)
    # and a plain stop edit. Together with the trips that is the five-item
    # resume.
    home_change_log.(home_planner_org, home_planner_version, %{
      entity_type: "calendar",
      entity_external_id: "WKDY",
      actor_id: home_planner_admin.id,
      actor_email: home_planner_admin.email,
      changed_fields: %{
        "before" => %{"weekly" => %{"end_date" => Date.to_iso8601(Date.add(home_today, 10))}},
        "after" => %{"weekly" => %{"end_date" => Date.to_iso8601(Date.add(home_today, 60))}}
      },
      inserted_at: DateTime.add(DateTime.utc_now(), -1, :day)
    })

    home_change_log.(home_planner_org, home_planner_version, %{
      entity_type: "route_pattern_build",
      entity_external_id: "H12",
      actor_id: home_planner_admin.id,
      actor_email: home_planner_admin.email,
      inserted_at: DateTime.add(DateTime.utc_now(), -2, :day)
    })

    home_change_log.(home_planner_org, home_planner_version, %{
      entity_type: "stop",
      entity_external_id: "HUB_platform_1",
      station_stop_id: "HUB",
      snapshot: %{"level_id" => "L1"},
      actor_id: home_planner_admin.id,
      actor_email: home_planner_admin.email,
      changed_fields: %{"stop_name" => %{"from" => "Hubbard", "to" => "Hubbard Street"}},
      inserted_at: DateTime.add(DateTime.utc_now(), -3, :day)
    })

    home_change_log.(home_planner_org, home_planner_version, %{
      entity_type: "stop",
      entity_external_id: "H440",
      actor_id: home_planner_admin.id,
      actor_email: home_planner_admin.email,
      changed_fields: %{
        "stop_lat" => %{"from" => "40.71", "to" => "40.72"},
        "stop_lon" => %{"from" => "-74.00", "to" => "-74.01"}
      },
      inserted_at: DateTime.add(DateTime.utc_now(), -4, :day)
    })

    home_feed_check.(home_planner_org, home_planner_version, 0, 12)

    # Finished five days ago, so every seeded change is "since then" and the
    # artifact expiry has passed without a sweep having run.
    home_expired_export.(
      home_planner_org,
      home_planner_version,
      :full,
      DateTime.add(DateTime.utc_now(), -5, :day)
    )

    home_stopped_import.(home_planner_org, "October 2026 service")

    # The no-version and no-task states draw the organization's active
    # administrators, so both existing access organizations get the same
    # confirmed administrator; without one those pages render no contact card
    # at all.
    for access_alias <- ["account-no-version", "account-no-task"] do
      access_org = Organizations.get_organization_by_alias(access_alias)

      _home_access_admin =
        home_member.(access_org, "account-admin@gtfs-planner.test", ["pathways_studio_admin"])
    end

    IO.puts(
      "Browser seed: #{home_planner_org.name} ready — home-planner@ attention " <>
        "(calendars to #{Date.add(home_today, 10)}, stopped import, 5 resume destinations, " <>
        "12-warning check, expired export) and home-planner-member@ team list"
    )

    # ── Home Pathways Org: the 14-station board ──
    {:ok, home_pathways_org} =
      Organizations.create_organization_unchecked(%{
        name: "Home Pathways Org",
        alias: "home-pathways-org",
        product: :pathways
      })

    home_pin_default_version.(home_pathways_org)

    {:ok, home_pathways_version} =
      Versions.create_gtfs_version(home_pathways_org.id, %{
        name: "September 2026 feed"
      })

    home_pathways_admin =
      home_member.(home_pathways_org, "home-pathways@gtfs-planner.test", [
        "pathways_studio_editor",
        "pathways_studio_admin"
      ])

    home_pathways_other =
      home_member.(home_pathways_org, "priya.n@bayline.example", ["pathways_studio_editor"])

    home_pathways_level =
      GtfsPlanner.GtfsFixtures.level_fixture(home_pathways_org.id, home_pathways_version.id, %{
        level_id: "L1",
        level_name: "Concourse",
        level_index: 0.0
      })

    home_station = fn stop_id, name ->
      GtfsPlanner.GtfsFixtures.stop_fixture(home_pathways_org.id, home_pathways_version.id, %{
        stop_id: stop_id,
        stop_name: name,
        location_type: 1
      })
    end

    # Child-stop ids follow the station report's own naming convention
    # (`<station>_entrance_<n>` / `<station>_platform_<n>`), so a mapped station
    # with a connecting pathway really has no report issues.
    home_child = fn stop_id, parent, location_type, name ->
      GtfsPlanner.GtfsFixtures.stop_fixture(home_pathways_org.id, home_pathways_version.id, %{
        stop_id: stop_id,
        stop_name: name,
        location_type: location_type,
        parent_station: parent,
        level_id: "L1"
      })
    end

    home_mapped_station = fn stop_id, name ->
      station = home_station.(stop_id, name)
      entrance = home_child.("#{stop_id}_entrance_1", stop_id, 2, "#{name} Entrance")
      platform = home_child.("#{stop_id}_platform_1", stop_id, 0, "#{name} Platform")

      GtfsPlanner.GtfsFixtures.pathway_fixture(
        home_pathways_org.id,
        home_pathways_version.id,
        entrance.stop_id,
        platform.stop_id,
        %{pathway_mode: 5}
      )

      {station, platform}
    end

    home_unmapped_station = fn stop_id, name ->
      station = home_station.(stop_id, name)
      platform = home_child.("#{stop_id}_platform_1", stop_id, 0, "#{name} Platform")
      {station, platform}
    end

    home_reachability = fn station_stop_id, outcome, reachable, pair_count, completed_at ->
      %ValidationRun{
        organization_id: home_pathways_org.id,
        gtfs_version_id: home_pathways_version.id
      }
      |> ValidationRun.changeset(%{
        run_type: "station_reachability",
        status: "completed",
        started_at: completed_at,
        completed_at: completed_at,
        error_details: nil,
        result_json: %{
          "metadata" => %{"station_stop_id" => station_stop_id},
          "outcome" => outcome,
          "totals" => %{"reachable" => reachable, "pair_count" => pair_count}
        }
      })
      |> Ecto.Changeset.put_change(:inserted_at, completed_at)
      |> Repo.insert!()
    end

    home_serve = fn route_short_name, trip_id, stop_id ->
      route =
        GtfsPlanner.GtfsFixtures.route_fixture(
          home_pathways_org.id,
          home_pathways_version.id,
          %{
            route_id: "R#{route_short_name}",
            route_short_name: route_short_name,
            route_long_name: "Route #{route_short_name}"
          }
        )

      trip =
        GtfsPlanner.GtfsFixtures.trip_fixture(
          home_pathways_org.id,
          home_pathways_version.id,
          route.route_id,
          %{trip_id: trip_id, service_id: "WKDY"}
        )

      GtfsPlanner.GtfsFixtures.stop_time_fixture(
        home_pathways_org.id,
        home_pathways_version.id,
        trip.trip_id,
        stop_id
      )
    end

    # UNS: the clean station — two routes through its platform, a floorplan and
    # a passed run newer than its latest change.
    {home_uns, home_uns_platform} = home_mapped_station.("UNS", "Union Station")
    home_serve.("5", "UNS-T5", home_uns_platform.stop_id)
    home_serve.("7", "UNS-T7", home_uns_platform.stop_id)

    {:ok, _home_uns_floorplan} =
      GtfsPlanner.GtfsFixtures.insert_stop_level(%{
        organization_id: home_pathways_org.id,
        gtfs_version_id: home_pathways_version.id,
        stop_id: home_uns.id,
        level_id: home_pathways_level.id,
        diagram_filename: "UNS-L1.png"
      })

    home_reachability.("UNS", "passed", 5, 5, DateTime.add(DateTime.utc_now(), -1, :hour))

    # HBP: a failing report (an isolated second entrance) and a passed run the
    # station's later change came after — "Edited since run".
    _home_hbp = home_mapped_station.("HBP", "Harbor Point")
    _home_hbp_entrance = home_child.("HBP_entrance_2", "HBP", 2, "Harbor Point Side Entrance")

    home_reachability.("HBP", "passed", 6, 6, DateTime.add(DateTime.utc_now(), -20, :day))

    home_change_log.(home_pathways_org, home_pathways_version, %{
      station_stop_id: "HBP",
      entity_external_id: "HBP_entrance_2",
      actor_email: "priya.n@bayline.example",
      inserted_at: DateTime.add(DateTime.utc_now(), -10, :day)
    })

    # MKT: a warning run newer than its last change, so the cell reads "2 of 4".
    {home_mkt, _home_mkt_platform} = home_mapped_station.("MKT", "Market Street")
    home_reachability.("MKT", "warning", 2, 4, DateTime.add(DateTime.utc_now(), -5, :day))

    home_change_log.(home_pathways_org, home_pathways_version, %{
      station_stop_id: "MKT",
      entity_external_id: "MKT_platform_1",
      actor_email: "priya.n@bayline.example",
      inserted_at: DateTime.add(DateTime.utc_now(), -6, :day)
    })

    # CEN has pathways but no run; PNS's run failed; RVS's is not applicable;
    # the remaining eight stations have no pathways yet.
    _home_cen = home_mapped_station.("CEN", "Central Station")
    _home_pns = home_mapped_station.("PNS", "Pine Street")
    home_reachability.("PNS", "failed", 1, 4, DateTime.add(DateTime.utc_now(), -8, :day))
    _home_rvs = home_mapped_station.("RVS", "Riverside")
    home_reachability.("RVS", "not_applicable", 0, 0, DateTime.add(DateTime.utc_now(), -4, :day))

    for {stop_id, name} <- [
          {"CDG", "Cedar Grove"},
          {"ELM", "Elm Park"},
          {"WGT", "Westgate"},
          {"APT", "Airport"},
          {"BYF", "Bayfront"},
          {"CVC", "Civic Center"},
          {"GRV", "Grove Hill"},
          {"STQ", "Quarry Road"}
        ] do
      _home_unmapped = home_unmapped_station.(stop_id, name)
    end

    # One editing status by another user: the board row reads "editing now" and
    # the rail lists priya.n, never this viewer.
    _home_editing_status =
      GtfsPlanner.GtfsFixtures.station_editing_status_fixture(
        home_pathways_org,
        home_pathways_version,
        home_uns,
        home_pathways_other
      )

    # The admin's own change: the rail's Continue item, linking to the station's
    # floorplan at GTFS level L1.
    home_change_log.(home_pathways_org, home_pathways_version, %{
      entity_type: "stop",
      entity_external_id: "UNS_platform_1",
      station_stop_id: "UNS",
      snapshot: %{"level_id" => "L1"},
      actor_id: home_pathways_admin.id,
      actor_email: home_pathways_admin.email,
      changed_fields: %{"stop_name" => %{"from" => "Union", "to" => "Union Station"}},
      inserted_at: DateTime.add(DateTime.utc_now(), -3, :day)
    })

    home_feed_check.(home_pathways_org, home_pathways_version, 0, 4)

    # Finished a week ago: the two later changes count as "since then".
    home_expired_export.(
      home_pathways_org,
      home_pathways_version,
      :pathways,
      DateTime.add(DateTime.utc_now(), -7, :day)
    )

    IO.puts(
      "Browser seed: #{home_pathways_org.name} ready — home-pathways@ 14 stations " <>
        "(1 clean, 5 in progress, 8 not started), priya.n editing UNS, " <>
        "4-warning check, expired pathways export"
    )

    # ── Route-map workload fixtures (spec 16, step 32) ──
    #
    # A dedicated published version carries the deterministic 500-route geometry
    # workload for the map timing procedure
    # (assets/e2e/route_lifecycle_map.spec.js, EV-8's exact second procedure):
    # BROWSER_MW_000 is the complete current route whose trunk spans the whole
    # corridor, and BROWSER_MW_001..499 are context routes, each with its own
    # distinct two-stop corridor and imported shape. The version's published_at
    # is backdated so it never becomes the organization's current version, and
    # no small interaction fixture on the Browser E2E Version moves (spec note
    # C1). Bulk rows mirror the deterministic corridor the ExUnit workload in
    # test/gtfs_planner/gtfs/routes/map_performance_test.exs builds.
    {:ok, workload_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Map Workload"})

    workload_version
    |> Ecto.Changeset.change(published_at: ~U[2020-02-01 00:00:00.000000Z])
    |> Repo.update!()

    workload_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, workload_current} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: workload_version.id,
        route_id: "BROWSER_MW_000",
        route_short_name: "M0",
        route_long_name: "Map workload current route",
        route_type: 3,
        route_color: "FF0000",
        route_text_color: "FFFFFF"
      })

    workload_trunk =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, workload_version.id, %{
        route_id: "BROWSER_MW_000",
        route_pattern_id: "BROWSER_MW_P1",
        route_pattern_name: "Workload trunk",
        route_pattern_sort_order: 0
      })

    workload_branch =
      GtfsPlanner.GtfsFixtures.route_pattern_fixture(org.id, workload_version.id, %{
        route_id: "BROWSER_MW_000",
        route_pattern_id: "BROWSER_MW_P2",
        route_pattern_name: "Workload branch",
        route_pattern_sort_order: 1
      })

    [
      {workload_trunk, "BROWSER_MW_STOP_000_A", 1, "1.0", "2.0"},
      {workload_trunk, "BROWSER_MW_STOP_000_B", 2, "1.25", "2.25"},
      {workload_trunk, "BROWSER_MW_STOP_000_C", 3, "1.5", "2.5"},
      {workload_branch, "BROWSER_MW_STOP_000_D", 1, "1.1", "2.1"},
      {workload_branch, "BROWSER_MW_STOP_000_E", 2, "1.2", "2.2"}
    ]
    |> Enum.each(fn {pattern, stop_id, position, lat, lon} ->
      {:ok, _stop} =
        GtfsPlanner.GtfsFixtures.insert_stop(%{
          organization_id: org.id,
          gtfs_version_id: workload_version.id,
          stop_id: stop_id,
          stop_name: "Workload stop #{stop_id}",
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new(lon),
          location_type: 0
        })

      GtfsPlanner.GtfsFixtures.route_pattern_stop_fixture(pattern, stop_id, position)
    end)

    [{"1.0", "2.0", 1}, {"1.25", "2.25", 2}, {"1.5", "2.5", 3}]
    |> Enum.each(fn {lat, lon, sequence} ->
      Repo.insert!(%GtfsPlanner.Gtfs.Shape{
        organization_id: org.id,
        gtfs_version_id: workload_version.id,
        shape_id: "BROWSER_MW_SH_000",
        shape_pt_lat: Decimal.new(lat),
        shape_pt_lon: Decimal.new(lon),
        shape_pt_sequence: sequence
      })
    end)

    {:ok, workload_trip} =
      GtfsPlanner.GtfsFixtures.insert_trip(%{
        organization_id: org.id,
        gtfs_version_id: workload_version.id,
        route_id: "BROWSER_MW_000",
        trip_id: "BROWSER_MW_TRIP_000",
        service_id: "BROWSER_MW_SERVICE",
        trip_headsign: "Workload current",
        direction_id: 0,
        shape_id: "BROWSER_MW_SH_000"
      })

    # Trip.changeset/2 does not cast route_pattern_id, so the link is set
    # directly, exactly as the domain tests do.
    Repo.update!(Ecto.Changeset.change(workload_trip, route_pattern_id: "BROWSER_MW_P1"))

    # 499 context routes as bulk rows: route i owns the distinct corridor
    # lat 1.02 + i*0.0009, lon 2.02 + i*0.0009 (plus one offset stop pair),
    # strictly inside the current route's bounding box, so every route sits in
    # the fitted map viewport and no two routes share geometry.
    workload_pattern_ids =
      Map.new(1..499, fn i -> {i, Ecto.UUID.generate()} end)

    workload_route_rows =
      Enum.map(1..499, fn i ->
        %{
          id: Ecto.UUID.generate(),
          organization_id: org.id,
          gtfs_version_id: workload_version.id,
          route_id: "BROWSER_MW_#{String.pad_leading(Integer.to_string(i), 3, "0")}",
          route_short_name: "M#{i}",
          route_long_name: "Map workload route #{i}",
          route_type: 3,
          active: true,
          inserted_at: workload_now,
          updated_at: workload_now
        }
      end)

    workload_pattern_rows =
      Enum.map(1..499, fn i ->
        %{
          id: Map.fetch!(workload_pattern_ids, i),
          organization_id: org.id,
          gtfs_version_id: workload_version.id,
          route_pattern_id: "BROWSER_MW_P_#{String.pad_leading(Integer.to_string(i), 3, "0")}",
          route_id: "BROWSER_MW_#{String.pad_leading(Integer.to_string(i), 3, "0")}",
          direction_id: 0,
          route_pattern_name: "Workload context #{i}",
          route_pattern_sort_order: 0,
          inserted_at: workload_now,
          updated_at: workload_now
        }
      end)

    {workload_stop_rows, workload_occurrence_rows, workload_shape_rows, workload_trip_rows} =
      Enum.reduce(1..499, {[], [], [], []}, fn i, {stops, occurrences, shapes, trips} ->
        padded = String.pad_leading(Integer.to_string(i), 3, "0")
        lat_a = 1.02 + i * 0.0009
        lon_a = 2.02 + i * 0.0009
        lat_b = lat_a + 0.0004
        lon_b = lon_a + 0.0004

        dec = fn value ->
          value |> :erlang.float_to_binary(decimals: 4) |> Decimal.new()
        end

        stop_base = %{
          organization_id: org.id,
          gtfs_version_id: workload_version.id,
          inserted_at: workload_now,
          updated_at: workload_now
        }

        new_stops = [
          Map.merge(stop_base, %{
            id: Ecto.UUID.generate(),
            stop_id: "BROWSER_MW_STOP_#{padded}_A",
            stop_name: "Workload stop BROWSER_MW_#{padded} a",
            stop_lat: dec.(lat_a),
            stop_lon: dec.(lon_a),
            location_type: 0
          }),
          Map.merge(stop_base, %{
            id: Ecto.UUID.generate(),
            stop_id: "BROWSER_MW_STOP_#{padded}_B",
            stop_name: "Workload stop BROWSER_MW_#{padded} b",
            stop_lat: dec.(lat_b),
            stop_lon: dec.(lon_b),
            location_type: 0
          })
          | stops
        ]

        pattern_id = Map.fetch!(workload_pattern_ids, i)

        new_occurrences = [
          %{
            id: Ecto.UUID.generate(),
            route_pattern_id: pattern_id,
            organization_id: org.id,
            gtfs_version_id: workload_version.id,
            stop_id: "BROWSER_MW_STOP_#{padded}_A",
            position: 1,
            inserted_at: workload_now,
            updated_at: workload_now
          },
          %{
            id: Ecto.UUID.generate(),
            route_pattern_id: pattern_id,
            organization_id: org.id,
            gtfs_version_id: workload_version.id,
            stop_id: "BROWSER_MW_STOP_#{padded}_B",
            position: 2,
            inserted_at: workload_now,
            updated_at: workload_now
          }
          | occurrences
        ]

        new_shapes = [
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: workload_version.id,
            shape_id: "BROWSER_MW_SH_#{padded}",
            shape_pt_lat: dec.(lat_a),
            shape_pt_lon: dec.(lon_a),
            shape_pt_sequence: 1,
            inserted_at: workload_now,
            updated_at: workload_now
          },
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: workload_version.id,
            shape_id: "BROWSER_MW_SH_#{padded}",
            shape_pt_lat: dec.(lat_b),
            shape_pt_lon: dec.(lon_b),
            shape_pt_sequence: 2,
            inserted_at: workload_now,
            updated_at: workload_now
          }
          | shapes
        ]

        new_trips = [
          %{
            id: Ecto.UUID.generate(),
            organization_id: org.id,
            gtfs_version_id: workload_version.id,
            trip_id: "BROWSER_MW_TRIP_#{padded}",
            route_id: "BROWSER_MW_#{padded}",
            service_id: "BROWSER_MW_SERVICE",
            shape_id: "BROWSER_MW_SH_#{padded}",
            route_pattern_id: "BROWSER_MW_P_#{padded}",
            direction_id: 0,
            inserted_at: workload_now,
            updated_at: workload_now
          }
          | trips
        ]

        {new_stops, new_occurrences, new_shapes, new_trips}
      end)

    Enum.each(
      [
        {GtfsPlanner.Gtfs.Route, workload_route_rows},
        {GtfsPlanner.Gtfs.RoutePattern, workload_pattern_rows},
        {GtfsPlanner.Gtfs.Stop, workload_stop_rows},
        {GtfsPlanner.Gtfs.RoutePatternStop, workload_occurrence_rows},
        {GtfsPlanner.Gtfs.Shape, workload_shape_rows},
        {GtfsPlanner.Gtfs.Trip, workload_trip_rows}
      ],
      fn {schema, rows} ->
        Enum.each(Enum.chunk_every(rows, 500), &Repo.insert_all(schema, &1))
      end
    )

    IO.puts(
      "Browser seed: map workload version #{workload_version.id} " <>
        "(BROWSER_MW_000 current route plus 499 distinct-geometry context routes)"
    )

    # ── Stop-time interpolation journey (spec 23, step 16) ──
    #
    # A dedicated published version carries the fill/export/schedules journey
    # records so no other spec's route, stop or trip counts move. Its
    # `published_at` is backdated like the transfers/helper/workload versions
    # above, so the Browser E2E Version keeps the organization's
    # latest-published default; the journey reaches this version by its
    # version id in the URL.
    #
    #   * BROWSER_INTERP_FILL — five stops with coordinates, one pattern with
    #     a "Weekday" timing (timepoints at stops 1, 3 and 5) and a linked
    #     trip. The Running times journey adds a blank "Fill journey" timing,
    #     times its first and last stops, and fills the middle.
    #   * BROWSER_INTERP_IMPORT — the same five stops with an imported custom
    #     trip whose middle stop times are blank, so Export defaults, Export
    #     and Schedules all have gaps to estimate.
    {:ok, interp_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Interp Version"})

    interp_version =
      Repo.update!(
        Ecto.Changeset.change(interp_version,
          published_at: ~U[2020-03-01 00:00:00.000000Z]
        )
      )

    interp_today = Gtfs.DisplayClock.today(org.id, interp_version.id).date
    interp_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Enum.each(1..5, fn index ->
      {lat, lon} =
        Enum.at(
          [
            {"39.9515", "-75.1640"},
            {"39.9540", "-75.1590"},
            {"39.9575", "-75.1540"},
            {"39.9610", "-75.1480"},
            {"39.9640", "-75.1400"}
          ],
          index - 1
        )

      {:ok, _stop} =
        GtfsPlanner.GtfsFixtures.insert_stop(%{
          stop_id: "BIS_#{index}",
          stop_name: "Interp Stop #{index}",
          location_type: 0,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new(lon),
          organization_id: org.id,
          gtfs_version_id: interp_version.id
        })
    end)

    [
      %{
        service_id: "INTERP_DAILY",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(interp_today, -30),
        end_date: Date.add(interp_today, 30)
      }
    ]
    |> Enum.map(
      &Map.merge(&1, %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: interp_version.id,
        inserted_at: interp_now,
        updated_at: interp_now
      })
    )
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.Calendar, &1))

    [
      %{
        service_id: "INTERP_DAILY",
        service_description: "Interp every day service",
        service_schedule_name: nil,
        service_schedule_type: nil,
        service_schedule_typicality: 0,
        rating_start_date: nil,
        rating_end_date: nil,
        rating_description: nil
      }
    ]
    |> Enum.map(
      &Map.merge(&1, %{
        id: Ecto.UUID.generate(),
        organization_id: org.id,
        gtfs_version_id: interp_version.id,
        inserted_at: interp_now,
        updated_at: interp_now
      })
    )
    |> then(&Repo.insert_all(GtfsPlanner.Gtfs.CalendarAttribute, &1))

    {:ok, interp_fill_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: interp_version.id,
        route_id: "BROWSER_INTERP_FILL",
        route_short_name: "IF",
        route_long_name: "Browser Interp Fill",
        route_type: 3
      })

    interp_fill_bundle =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, interp_version.id, %{
        route_id: interp_fill_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-INTERP-FILL",
        route_pattern_name: "Interp Fill Pattern",
        route_pattern_typicality: 1,
        timing_name: "Weekday",
        timing_headsign: "Interp outbound",
        stops: [
          {"BIS_1", 0, 0, 1},
          {"BIS_2", 150, 180, 0},
          {"BIS_3", 300, 300, 1},
          {"BIS_4", 450, 480, 0},
          {"BIS_5", 600, 600, 1}
        ]
      })

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      interp_version.id,
      interp_fill_route.route_id,
      interp_fill_bundle,
      %{
        service_id: "INTERP_DAILY",
        trip_id: "BROWSER_INTERP_T1",
        trip_short_name: "6101",
        start_time: "08:00:00",
        trip_headsign: "Interp outbound"
      }
    )

    {:ok, interp_import_route} =
      GtfsPlanner.GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: interp_version.id,
        route_id: "BROWSER_INTERP_IMPORT",
        route_short_name: "IX",
        route_long_name: "Browser Interp Imported",
        route_type: 3
      })

    interp_import_bundle =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, interp_version.id, %{
        route_id: interp_import_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-INTERP-IMPORT",
        route_pattern_name: "Interp Imported Pattern",
        route_pattern_typicality: 1,
        timing_name: "Imported",
        timing_headsign: "Interp imported",
        stops: [
          {"BIS_1", 0, 0, 1},
          {"BIS_2", 150, 180, 0},
          {"BIS_3", 300, 300, 1},
          {"BIS_4", 450, 480, 0},
          {"BIS_5", 600, 600, 1}
        ]
      })

    # An imported custom trip: its timepoint stops carry times while the
    # middle stops are blank, so every surface has gaps to estimate.
    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      interp_version.id,
      interp_import_route.route_id,
      interp_import_bundle,
      %{
        service_id: "INTERP_DAILY",
        trip_id: "BROWSER_INTERP_C1",
        trip_short_name: "6102",
        state: "custom",
        reason: "imported",
        timed_pattern_id: nil,
        trip_headsign: "Interp imported",
        stop_times: [
          {"BIS_1", "08:00:00", "08:00:00"},
          {"BIS_2", nil, nil},
          {"BIS_3", "08:10:00", "08:10:00"},
          {"BIS_4", nil, nil},
          {"BIS_5", "08:20:00", "08:20:00"}
        ]
      }
    )

    IO.puts(
      "Browser seed: interp version #{interp_version.id} " <>
        "(BROWSER_INTERP_FILL pattern with a linked trip, " <>
        "BROWSER_INTERP_IMPORT pattern with a blank-middle custom trip)"
    )

    # ── Dated change planning journey (spec 11, step 10; EV-10) ──
    #
    # Two dedicated backdated published versions carry the dated-change
    # browser journey, so no other spec's calendar, route, trip or count
    # moves and neither version becomes the organization's latest published
    # default. The journey reaches both by version name.
    #
    #   * "Browser Dated Change Version" — BROWSER_DATED_CHANGE carries the
    #     nine-date case the plan reports:
    #
    #       DC_WEEKDAY  Mon-Fri over 2026-01-01..2026-12-31 with one removed
    #                    exception, 2026-11-11. The accepted window
    #                    2026-11-02..2026-11-13 holds ten weekdays, and the
    #                    removed Wednesday leaves exactly nine in-window dates,
    #                    which is also why 2026-11-11 must appear in no date
    #                    list at all.
    #       DC_WEEKEND  Sat-Sun over the same range, so the report's calendar
    #                    switch has a second real calendar to page and the
    #                    fixture is genuinely multi-calendar.
    #
    #     Four trips: DC_T_0700 and DC_T_2510 are the journey's selection on
    #     DC_WEEKDAY (the second starts at 25:10, so a +300s shift projects
    #     25:15 on the same service day), DC_T_0800 is an unselected trip
    #     sharing DC_WEEKDAY, and DC_S_0930 is the single trip on DC_WEEKEND.
    #
    #   * "Browser Dated Change Wide Version" — BROWSER_DATED_CHANGE_WIDE
    #     carries one Saturday-only calendar whose declared range is 200,001
    #     civil days, one cell over the planner's date-work cap. Nothing is
    #     enumerated to find that out: the cap is counted from the stored
    #     range, so the page stays ordinary and the plan is refused whole.
    #
    # The expected totals, read straight off the fixture above and never off
    # the planner's output: DC_WEEKDAY runs 261 weekdays in 2026 minus the
    # removed 11-11 = 260 original dates, nine of them in the accepted window
    # and 251 kept. Selecting DC_T_0700 and DC_T_2510 therefore gives 2
    # selected trips, 2x9 = 18 changed trip-dates, 2x251 = 502 unchanged
    # trip-dates and exactly 1 unaffected calendar user (DC_T_0800).
    #
    # The selection stays inside DC_WEEKDAY on purpose: the Schedule page
    # resolves one calendar at a time, and changing that filter is a parameter
    # change that clears the selection, so a two-calendar selection is not
    # reachable through the page's own controls. DC_WEEKEND and DC_S_0930 make
    # the route and the version genuinely multi-calendar, so the calendar
    # filter and the calendars page have a second real identity to read.
    {:ok, dated_change_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Dated Change Version"})

    dated_change_version =
      Repo.update!(
        Ecto.Changeset.change(dated_change_version,
          published_at: ~U[2020-04-01 00:00:00.000000Z]
        )
      )

    # ── Stops Map seed data ──
    #
    # A planner-product organization of its own, so the Map view journey reads
    # this fixture instead of whichever version another spec left selected. The
    # stop IDs, coordinates and shape geometry are real downtown Newport, Oregon
    # over OpenStreetMap.
    #
    # The seeded problems are the ones the Map view's surfaces exist for:
    #   * 1433 sits 1.5 m from 1434 (possible duplicate, used by one pattern)
    #   * 1434 has a relief point and a transfer to the transit centre's Bay B
    #   * ST-NTC is a station with one level and two bays
    #   * 1531 is unserved and carries a Spanish name translation
    #   * garage "1533" makes the next generated stop ID 1534, not 1533
    # The seed runs without a session, so it uses the explicitly named unchecked
    # creator rather than the authorized `create_organization/2`.
    {:ok, stops_map_org} =
      Organizations.create_organization_unchecked(%{
        name: "Stops Map Org",
        alias: "stops-map",
        product: :planner
      })

    {:ok, stops_map_version} =
      Versions.create_gtfs_version(stops_map_org.id, %{name: "Browser Stops Map Version"})

    # A published version with no stops at all, so the list's first-use state —
    # where an editor has neither a feed nor a stop — is a real page rather than
    # a claim about one that cannot be opened.
    {:ok, stops_map_empty_version} =
      Versions.create_gtfs_version(stops_map_org.id, %{name: "Browser Stops Map Empty Version"})

    {:ok, stops_map_editor} =
      Accounts.register_user(%{
        email: "stops-map@gtfs-planner.test",
        password: "StopsMapBrowser1"
      })

    Repo.update!(User.confirm_changeset(stops_map_editor))

    {:ok, _stops_map_membership} =
      Accounts.create_user_org_membership(%{
        user_id: stops_map_editor.id,
        organization_id: stops_map_org.id,
        roles: ["pathways_studio_editor"]
      })

    IO.puts(
      "Browser seed: stops map editor #{stops_map_editor.email} in #{stops_map_org.name} " <>
        "(id=#{stops_map_org.id}), version #{stops_map_version.name} (id=#{stops_map_version.id}), " <>
        "empty version #{stops_map_empty_version.name} (id=#{stops_map_empty_version.id})"
    )

    stops_map_at = ~U[2026-09-01 00:00:00.000000Z]
    # Five decimals is the coordinate columns' own resolution, and a literal
    # keeps a re-run byte-identical where a float-to-string would not.
    stops_map_coord = fn value -> Decimal.new(:erlang.float_to_binary(value, decimals: 5)) end
    stops_map_id = fn -> Ecto.UUID.generate() end

    # Great-circle-ish metres between two `{lat, lon}` points, at this feed's
    # latitude. Only the running `shape_dist_traveled` uses it, and the value it
    # produces is compared against nothing, so a local scale factor is the right
    # size of tool here rather than a second distance implementation.
    stops_map_latitude = 44.635

    stops_map_metres = fn {lat_a, lon_a}, {lat_b, lon_b} ->
      radians = 3.141592653589793 * stops_map_latitude / 180
      dlat = (lat_b - lat_a) * 111_132.954 - 559.822 * :math.cos(2 * radians)
      dlon = (lon_b - lon_a) * 111_412.84 * :math.cos(radians)
      :math.sqrt(dlat * dlat + dlon * dlon)
    end

    # The running distance to one shape point, as a `{elapsed, lat, lon}`
    # accumulator: the first point is the origin at 0.0 m and every later one adds
    # the leg from the point before it. `map_reduce/3` takes the new accumulator
    # first and the collected element second, so the collected element is the
    # triple the caller wants.
    stops_map_measure_point = fn
      {lat, lon}, nil ->
        {{0.0, lat, lon}, {0.0, lat, lon}}

      {lat, lon}, {elapsed, previous_lat, previous_lon} ->
        next = elapsed + stops_map_metres.({previous_lat, previous_lon}, {lat, lon})
        {{next, lat, lon}, {next, lat, lon}}
    end

    # One fare zone, so the read-only fare zone field in the edit panel has a
    # real value and its Settings link has somewhere to land. Since #736 the
    # write names its actor, so the command takes this organization's own editor.
    {:ok, _stops_map_zone} =
      FareZones.create_zone(
        %AuditContext{
          organization_id: stops_map_org.id,
          gtfs_version_id: stops_map_version.id,
          actor_id: stops_map_editor.id,
          actor_email: stops_map_editor.email,
          station_stop_id: nil
        },
        %{
          zone_id: "NL",
          name: "Newport local",
          color: "teal"
        }
      )

    # {stop_id, name, desc, stop_code, location_type, lat, lon, parent, level}
    stops_map_stop_rows = [
      {"1434", "US 101 & SE 1st St", "Northbound", "1434", 0, 44.63561, -124.05317, nil, nil},
      {"1355", "US 101 & NW 3rd St", "Northbound", "1355", 0, 44.63848, -124.05299, nil, nil},
      {"1330", "US 101 & NE 7th St", "Northbound", "1330", 0, 44.64126, -124.05297, nil, nil},
      {"1301", "US 101 & NW 14th St", "Northbound", "1301", 0, 44.64753, -124.05293, nil, nil},
      {"1308", "US 101 & NW 14th St", "Southbound", "1308", 0, 44.64728, -124.05313, nil, nil},
      {"1312", "US 101 & NE 11th St", "Southbound", "1312", 0, 44.64458, -124.05315, nil, nil},
      {"1326", "US 101 & NE 8th St", "Southbound", "1326", 0, 44.64172, -124.05317, nil, nil},
      {"1433", "US 101 & SE 1st St", "Northbound", "1433", 0, 44.63562, -124.05316, nil, nil},
      {"1344", "NW 6th St & NW Grove St", "Westbound", "1344", 0, 44.64023, -124.05457, nil, nil},
      {"1337", "NW 6th St & NW Brook St", "Westbound", "1337", 0, 44.64023, -124.05906, nil, nil},
      {"1380", "NW Coast St & NW 3rd St", "Southbound", "1380", 0, 44.63824, -124.06079, nil,
       nil},
      {"1438", "SW 2nd St & SW Coast St", "Southbound", "1438", 0, 44.63461, -124.06067, nil,
       nil},
      {"1452", "SW Hurbert St & SW 7th St", "Southbound", "1452", 0, 44.63359, -124.05722, nil,
       nil},
      {"1531", "SE Bay Blvd & SE Moore Dr", "Eastbound", "1531", 0, 44.63095, -124.04077, nil,
       nil},
      {"ST-NTC", "Newport Transit Center", "", nil, 1, 44.63470, -124.05325, nil, "GROUND"},
      {"NTC-A", "Newport Transit Center, Bay A", "A", nil, 0, 44.63461, -124.05348, "ST-NTC",
       "GROUND"},
      {"NTC-B", "Newport Transit Center, Bay B", "B", nil, 0, 44.63461, -124.05333, "ST-NTC",
       "GROUND"}
    ]

    {17, nil} =
      Repo.insert_all(
        Stop,
        Enum.map(stops_map_stop_rows, fn {stop_id, name, desc, code, type, lat, lon, parent,
                                          level} ->
          %{
            id: stops_map_id.(),
            organization_id: stops_map_org.id,
            gtfs_version_id: stops_map_version.id,
            stop_id: stop_id,
            stop_name: name,
            stop_desc: desc,
            stop_code: code,
            stop_lat: stops_map_coord.(lat),
            stop_lon: stops_map_coord.(lon),
            location_type: type,
            zone_id: "NL",
            parent_station: parent,
            level_id: level,
            inserted_at: stops_map_at,
            updated_at: stops_map_at
          }
        end)
      )

    # The station's one level, so a delete of ST-NTC is refused on a cascading
    # reference and not only on its child stops.
    {:ok, stops_map_level} =
      GtfsPlanner.GtfsFixtures.insert_level(%{
        level_id: "GROUND",
        level_name: "Ground",
        level_index: 0.0,
        organization_id: stops_map_org.id,
        gtfs_version_id: stops_map_version.id
      })

    [stops_map_station] =
      Repo.all(
        from(stop in Stop,
          where:
            stop.organization_id == ^stops_map_org.id and
              stop.gtfs_version_id == ^stops_map_version.id and stop.stop_id == "ST-NTC"
        )
      )

    {:ok, _stops_map_stop_level} =
      GtfsPlanner.GtfsFixtures.insert_stop_level(%{
        organization_id: stops_map_org.id,
        gtfs_version_id: stops_map_version.id,
        stop_id: stops_map_station.id,
        level_id: stops_map_level.id
      })

    # Shape geometry from OpenStreetMap road paths, simplified
    # to roughly one point per 28 m: every vertex is a real place, and the
    # inbound Coast Highway path is the outbound one reversed so the two
    # directions sit on the same street rather than on separate lines.
    stops_map_shapes = [
      {"BROWSER_SM_SHAPE_1_0",
       [
         {44.63474, -124.05332},
         {44.63474, -124.05369},
         {44.63505, -124.05363},
         {44.63536, -124.05340},
         {44.63587, -124.05317},
         {44.63620, -124.05312},
         {44.63653, -124.05311},
         {44.63699, -124.05310},
         {44.63767, -124.05309},
         {44.63807, -124.05309},
         {44.63835, -124.05309},
         {44.63874, -124.05309},
         {44.63942, -124.05308},
         {44.63970, -124.05308},
         {44.64009, -124.05308},
         {44.64039, -124.05308},
         {44.64073, -124.05307},
         {44.64113, -124.05307},
         {44.64171, -124.05307},
         {44.64261, -124.05306},
         {44.64313, -124.05306},
         {44.64349, -124.05306},
         {44.64377, -124.05306},
         {44.64407, -124.05305},
         {44.64435, -124.05305},
         {44.64461, -124.05305},
         {44.64488, -124.05305},
         {44.64513, -124.05305},
         {44.64542, -124.05304},
         {44.64595, -124.05304},
         {44.64631, -124.05304},
         {44.64677, -124.05303},
         {44.64706, -124.05304},
         {44.64737, -124.05303},
         {44.64806, -124.05303},
         {44.64836, -124.05303},
         {44.64879, -124.05302},
         {44.64907, -124.05302},
         {44.64915, -124.05302}
       ]},
      {"BROWSER_SM_SHAPE_1_1",
       [
         {44.64915, -124.05302},
         {44.64907, -124.05302},
         {44.64879, -124.05302},
         {44.64836, -124.05303},
         {44.64806, -124.05303},
         {44.64737, -124.05303},
         {44.64706, -124.05304},
         {44.64677, -124.05303},
         {44.64631, -124.05304},
         {44.64595, -124.05304},
         {44.64542, -124.05304},
         {44.64513, -124.05305},
         {44.64488, -124.05305},
         {44.64461, -124.05305},
         {44.64435, -124.05305},
         {44.64407, -124.05305},
         {44.64377, -124.05306},
         {44.64349, -124.05306},
         {44.64313, -124.05306},
         {44.64261, -124.05306},
         {44.64171, -124.05307},
         {44.64113, -124.05307},
         {44.64073, -124.05307},
         {44.64039, -124.05308},
         {44.64009, -124.05308},
         {44.63970, -124.05308},
         {44.63942, -124.05308},
         {44.63874, -124.05309},
         {44.63835, -124.05309},
         {44.63807, -124.05309},
         {44.63767, -124.05309},
         {44.63699, -124.05310},
         {44.63653, -124.05311},
         {44.63620, -124.05312},
         {44.63587, -124.05317},
         {44.63536, -124.05340},
         {44.63505, -124.05363},
         {44.63474, -124.05369},
         {44.63474, -124.05332}
       ]},
      {"BROWSER_SM_SHAPE_3_0",
       [
         {44.63474, -124.05332},
         {44.63474, -124.05369},
         {44.63505, -124.05363},
         {44.63536, -124.05340},
         {44.63587, -124.05317},
         {44.63620, -124.05312},
         {44.63653, -124.05311},
         {44.63699, -124.05310},
         {44.63767, -124.05309},
         {44.63807, -124.05309},
         {44.63835, -124.05309},
         {44.63874, -124.05309},
         {44.63942, -124.05308},
         {44.63970, -124.05308},
         {44.64009, -124.05308},
         {44.64016, -124.05366},
         {44.64016, -124.05403},
         {44.64016, -124.05440},
         {44.64016, -124.05486},
         {44.64016, -124.05539},
         {44.64016, -124.05648},
         {44.64016, -124.05711},
         {44.64017, -124.05816},
         {44.64016, -124.05852},
         {44.64016, -124.05888},
         {44.64016, -124.05984},
         {44.64016, -124.06070},
         {44.63948, -124.06070},
         {44.63916, -124.06070},
         {44.63888, -124.06070},
         {44.63837, -124.06069},
         {44.63792, -124.06071},
         {44.63745, -124.06071},
         {44.63701, -124.06070},
         {44.63656, -124.06071},
         {44.63566, -124.06071},
         {44.63517, -124.06071},
         {44.63476, -124.06071},
         {44.63476, -124.06022},
         {44.63475, -124.05987},
         {44.63475, -124.05887},
         {44.63475, -124.05815},
         {44.63430, -124.05815},
         {44.63373, -124.05724},
         {44.63339, -124.05689},
         {44.63263, -124.05608},
         {44.63296, -124.05542},
         {44.63323, -124.05491},
         {44.63350, -124.05440},
         {44.63380, -124.05384},
         {44.63445, -124.05435},
         {44.63462, -124.05407},
         {44.63474, -124.05369},
         {44.63474, -124.05332}
       ]}
    ]

    # `shape_dist_traveled` is a running distance along the shape, computed here
    # rather than hand-written: a seeded distance that disagreed with the
    # geometry would be a lie the alignment review would report later.
    stops_map_shape_rows =
      Enum.flat_map(stops_map_shapes, fn {shape_id, points} ->
        # `map_reduce/3` answers `{collected, final_accumulator}`.
        {measured, _elapsed} = Enum.map_reduce(points, nil, stops_map_measure_point)

        measured
        |> Enum.with_index(1)
        |> Enum.map(fn {{distance, lat, lon}, sequence} ->
          %{
            id: stops_map_id.(),
            organization_id: stops_map_org.id,
            gtfs_version_id: stops_map_version.id,
            shape_id: shape_id,
            shape_pt_lat: stops_map_coord.(lat),
            shape_pt_lon: stops_map_coord.(lon),
            shape_pt_sequence: sequence,
            shape_dist_traveled: Decimal.round(Decimal.from_float(distance), 1),
            inserted_at: stops_map_at,
            updated_at: stops_map_at
          }
        end)
      end)

    {stops_map_shape_point_count, nil} = Repo.insert_all(Shape, stops_map_shape_rows)

    # Two routes, one per direction of Coast Highway plus the city loop.
    for {route_id, short_name, long_name, color} <- [
          {"1", "1", "Coast Highway", "1F5FBF"},
          {"3", "3", "Newport City Loop", "4B1F78"}
        ] do
      {:ok, _route} =
        GtfsPlanner.GtfsFixtures.insert_route(%{
          organization_id: stops_map_org.id,
          gtfs_version_id: stops_map_version.id,
          route_id: route_id,
          route_short_name: short_name,
          route_long_name: long_name,
          route_type: 3,
          route_color: color
        })
    end

    # {pattern_id, route_id, direction_id, headsign, name, shape_id, stops}
    stops_map_patterns = [
      {"BROWSER_SM_P1_0", "1", 0, "Lincoln City", "Coast Highway to Lincoln City",
       "BROWSER_SM_SHAPE_1_0", ["1434", "1355", "1330", "1301"]},
      {"BROWSER_SM_P1_1", "1", 1, "Newport Transit Center", "Coast Highway to Newport",
       "BROWSER_SM_SHAPE_1_1", ["1308", "1312", "1326", "1433"]},
      {"BROWSER_SM_P3_0", "3", 0, "Nye Beach", "City Loop to Nye Beach", "BROWSER_SM_SHAPE_3_0",
       ["1434", "1355", "1344", "1337", "1380", "1438", "1452"]}
    ]

    {3, nil} =
      Repo.insert_all(
        RoutePattern,
        Enum.map(stops_map_patterns, fn {pattern_id, route_id, direction_id, headsign, name,
                                         shape_id, _stops} ->
          %{
            id: stops_map_id.(),
            organization_id: stops_map_org.id,
            gtfs_version_id: stops_map_version.id,
            route_pattern_id: pattern_id,
            route_id: route_id,
            direction_id: direction_id,
            headsign: headsign,
            route_pattern_name: name,
            route_pattern_typicality: 1,
            route_pattern_sort_order: direction_id,
            shape_id: shape_id,
            inserted_at: stops_map_at,
            updated_at: stops_map_at
          }
        end)
      )

    stops_map_pattern_rows =
      Repo.all(from(pattern in RoutePattern, where: pattern.organization_id == ^stops_map_org.id))

    stops_map_pattern_by_natural_id =
      Map.new(stops_map_pattern_rows, &{&1.route_pattern_id, &1})

    stops_map_shape_points = Map.new(stops_map_shapes)

    # A stop's `shape_dist_traveled` is the distance to the shape point nearest
    # it, so the occurrences and the shape agree about where a stop sits.
    stops_map_latlon =
      Map.new(stops_map_stop_rows, fn {stop_id, _name, _desc, _code, _type, lat, lon, _p, _l} ->
        {stop_id, {lat, lon}}
      end)

    stops_map_nearest_distance = fn points, {lat, lon} ->
      points
      |> Enum.map(fn point -> stops_map_metres.(point, {lat, lon}) end)
      |> Enum.min()
    end

    {stops_map_occurrence_count, nil} =
      Repo.insert_all(
        RoutePatternStop,
        Enum.flat_map(stops_map_patterns, fn {pattern_id, _route_id, _direction_id, _headsign,
                                              _name, shape_id, stops} ->
          pattern = Map.fetch!(stops_map_pattern_by_natural_id, pattern_id)
          points = Map.fetch!(stops_map_shape_points, shape_id)

          stops
          |> Enum.with_index(1)
          |> Enum.map(fn {stop_id, position} ->
            distance = stops_map_nearest_distance.(points, Map.fetch!(stops_map_latlon, stop_id))

            %{
              id: stops_map_id.(),
              route_pattern_id: pattern.id,
              organization_id: stops_map_org.id,
              gtfs_version_id: stops_map_version.id,
              stop_id: stop_id,
              position: position,
              shape_dist_traveled: Decimal.round(Decimal.from_float(distance), 1),
              inserted_at: stops_map_at,
              updated_at: stops_map_at
            }
          end)
        end)
      )

    # Shared stop pairs, one segment each, with interior points taken off the
    # shape between the two stops. A shared segment is what the move review
    # redraws, so it has to exist before the move journey can ask for a redraw.
    stops_map_segments = [
      {"1434", "1355", [[-124.05312, 44.63620], [-124.05309, 44.63807]]},
      {"1355", "1330", [[-124.05309, 44.63874], [-124.05307, 44.64073]]},
      {"1330", "1301", [[-124.05307, 44.64171], [-124.05304, 44.64706]]},
      {"1308", "1312", [[-124.05304, 44.64706], [-124.05305, 44.64488]]},
      {"1312", "1326", [[-124.05305, 44.64435], [-124.05306, 44.64261]]},
      {"1326", "1433", [[-124.05307, 44.64113], [-124.05312, 44.63620]]},
      {"1355", "1344", [[-124.05309, 44.63874], [-124.05403, 44.64016]]},
      {"1344", "1337", [[-124.05486, 44.64016], [-124.05852, 44.64016]]},
      {"1337", "1380", [[-124.05984, 44.64016], [-124.06070, 44.63888]]},
      {"1380", "1438", [[-124.06071, 44.63792], [-124.06071, 44.63517]]},
      {"1438", "1452", [[-124.06022, 44.63476], [-124.05815, 44.63430]]}
    ]

    stops_map_segment_count =
      Enum.reduce(stops_map_segments, 0, fn {from_stop_id, to_stop_id, points}, count ->
        %AlignmentSegment{}
        |> AlignmentSegment.changeset(%{points: points})
        |> Ecto.Changeset.put_change(:organization_id, stops_map_org.id)
        |> Ecto.Changeset.put_change(:gtfs_version_id, stops_map_version.id)
        |> Ecto.Changeset.put_change(:from_stop_id, from_stop_id)
        |> Ecto.Changeset.put_change(:to_stop_id, to_stop_id)
        |> Ecto.Changeset.put_change(:inserted_at, stops_map_at)
        |> Ecto.Changeset.put_change(:updated_at, stops_map_at)
        |> Repo.insert!()

        count + 1
      end)

    # The seeded problems each reference, written through the same tables the
    # commands read: 1434's relief point and transfer, and 1531's translation.
    {:ok, _stops_map_relief} =
      %ReliefPoint{}
      |> ReliefPoint.changeset(%{})
      |> Ecto.Changeset.put_change(:organization_id, stops_map_org.id)
      |> Ecto.Changeset.put_change(:gtfs_version_id, stops_map_version.id)
      |> Ecto.Changeset.put_change(:stop_id, "1434")
      |> Ecto.Changeset.put_change(:inserted_at, stops_map_at)
      |> Ecto.Changeset.put_change(:updated_at, stops_map_at)
      |> Repo.insert()

    {:ok, _stops_map_transfer} =
      %Transfer{}
      |> Transfer.changeset(%{
        organization_id: stops_map_org.id,
        gtfs_version_id: stops_map_version.id,
        from_stop_id: "1434",
        to_stop_id: "NTC-B",
        from_route_id: "1",
        to_route_id: "1",
        transfer_type: 0,
        min_transfer_time: 180
      })
      |> Repo.insert()

    {:ok, _stops_map_translation} =
      %Translation{}
      |> Translation.changeset(%{
        organization_id: stops_map_org.id,
        gtfs_version_id: stops_map_version.id,
        table_name: "stops",
        field_name: "stop_name",
        language: "es",
        translation: "Bulevar SE Bay y SE Moore Dr",
        record_id: "1531"
      })
      |> Repo.insert()

    # Garage "1533": the next generated stop ID must skip it, which is the case
    # the naming rule's second example names.
    stops_map_garage =
      GtfsPlanner.OperationsFixtures.garage_fixture(stops_map_org.id, %{
        "garage_id" => "1533",
        "name" => "Newport Transit Center Garage"
      })

    # The seed is its own verifier: it reads the version back through the
    # production read model and fails loudly rather than printing counts a later
    # UI step cannot rely on.
    {:ok, stops_map_model} =
      GtfsPlanner.Gtfs.StopsMap.load(stops_map_org.id, stops_map_version.id)

    served_map_stops = Enum.filter(stops_map_model.stops, & &1.served?)

    IO.puts(
      "Browser seed: stops map version #{stops_map_version.name} " <>
        "(#{length(stops_map_model.stops)} stops, #{length(served_map_stops)} served, " <>
        "#{length(stops_map_model.lines)} patterns, #{stops_map_shape_point_count} shape points, " <>
        "#{stops_map_segment_count} shared segments, garage #{stops_map_garage.garage_id})"
    )

    # ── Alerts journeys fixtures (spec 30, step 12) ──
    #
    # A dedicated published version carries the alert-authoring material so no
    # other spec's route, stop or trip counts move. The shapes below are the
    # ones the editor asks for: two route types so the mode question appears
    # (Route 1 and Route 12 bus, Route 50 tram), eight stops with codes so place
    # search matches on a code as well as a name, one stop (Newport Transit
    # Center) served by Routes 1 and 12 so the shared-stop question appears,
    # weekday and weekend service spanning today ± 60 days so "now", a dated
    # cancellation and a nightly recurrence all land on real service dates, and
    # a Route 1 trip whose last stop time is past midnight so the departures
    # list has an after-24:00 clock value to render.
    #
    # The set is seeded for two organizations. Browser Test Org keeps it for the
    # feed-publishing journeys, which publish against these alert rows. The
    # alert journeys have their own organization below, because the shipped
    # alert editor authors against the organization's latest published version:
    # Browser Test Org's latest is the Browser E2E Version — whose route, stop
    # and trip counts every other spec asserts — and this version's
    # `published_at` is backdated so that stays true.
    seed_alerts_fixtures = fn org, editor ->
      {:ok, alerts_version} =
        Versions.create_gtfs_version(org.id, %{name: "Browser Alerts Version"})

      alerts_version =
        Repo.update!(
          Ecto.Changeset.change(alerts_version,
            published_at: ~U[2020-04-01 00:00:00.000000Z]
          )
        )

      {:ok, _alerts_agency} =
        GtfsFixtures.insert_agency(%{
          organization_id: org.id,
          gtfs_version_id: alerts_version.id,
          agency_id: "BROWSER_ALERTS_AGENCY",
          agency_name: "Browser Alerts Transit",
          agency_url: "https://example.test",
          agency_timezone: "America/Los_Angeles"
        })

      alerts_today = Gtfs.DisplayClock.today(org.id, alerts_version.id).date

      # `stop_code` is written only by the full importer and is never cast, so the
      # code is set on the inserted row the same way the diagram coordinates are.
      # `platform_code` carries the same value because the editor's place search
      # matches a code there (AC-10), and a rider-facing code has to be findable.
      alerts_stops =
        [
          {"AL_NTC", "Newport Transit Center", "1001", "44.6210", "-124.0490"},
          {"AL_CST6", "N Coast Hwy & NE 6th St", "1012", "44.6250", "-124.0600"},
          {"AL_CST12", "N Coast Hwy & NE 12th St", "1014", "44.6300", "-124.0750"},
          {"AL_CST20", "N Coast Hwy & NE 20th St", "1016", "44.6380", "-124.0900"},
          {"AL_CST36", "N Coast Hwy & NE 36th St", "1018", "44.6520", "-124.1100"},
          {"AL_LCTC", "Lincoln City Transit Center", "1070", "44.9570", "-124.0150"},
          {"AL_NYE", "Nye Beach (NW Coast St & Olive)", "1102", "44.6770", "-124.0430"},
          {"AL_HOSP", "Samaritan Pacific Hospital", "1110", "44.6350", "-124.0330"}
        ]
        |> Enum.map(fn {stop_id, stop_name, stop_code, lat, lon} ->
          {:ok, stop} =
            GtfsFixtures.insert_stop(%{
              organization_id: org.id,
              gtfs_version_id: alerts_version.id,
              stop_id: stop_id,
              stop_name: stop_name,
              location_type: 0,
              stop_lat: Decimal.new(lat),
              stop_lon: Decimal.new(lon)
            })

          stop
          |> Ecto.Changeset.change(stop_code: stop_code, platform_code: stop_code)
          |> Repo.update!()
        end)

      alerts_routes =
        [
          {"1", "Route 1", "Coast Highway", 3},
          {"12", "Route 12", "Nye Beach – Hospital", 3},
          {"50", "Route 50", "Lincoln City Connector", 0}
        ]
        |> Enum.map(fn {route_id, short_name, long_name, route_type} ->
          {:ok, route} =
            GtfsFixtures.insert_route(%{
              organization_id: org.id,
              gtfs_version_id: alerts_version.id,
              route_id: route_id,
              route_short_name: short_name,
              route_long_name: long_name,
              route_type: route_type
            })

          route
        end)
        |> Map.new(&{&1.route_id, &1})

      alerts_route_1 = Map.fetch!(alerts_routes, "1")
      alerts_route_12 = Map.fetch!(alerts_routes, "12")
      alerts_route_50 = Map.fetch!(alerts_routes, "50")

      weekday_service = %{
        service_id: "ALERTS_WEEKDAY",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: Date.add(alerts_today, -60),
        end_date: Date.add(alerts_today, 60)
      }

      weekend_service = %{
        service_id: "ALERTS_WEEKEND",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 1,
        start_date: Date.add(alerts_today, -60),
        end_date: Date.add(alerts_today, 60)
      }

      Enum.each([weekday_service, weekend_service], fn service ->
        GtfsPlanner.GtfsFixtures.calendar_fixture(org.id, alerts_version.id, service)
      end)

      # Route 1 both directions. The direction-0 offsets span 70 minutes, so a
      # 23:30 departure reaches Lincoln City at 24:40 — the after-midnight value
      # the departures question renders.
      alerts_pattern = fn _route, attrs ->
        GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, alerts_version.id, attrs)
      end

      route_1_outbound =
        alerts_pattern.(alerts_route_1, %{
          route_id: alerts_route_1.route_id,
          direction_id: 0,
          route_pattern_id: "AL-R1-P1",
          route_pattern_name: "Coast Highway to Lincoln City",
          route_pattern_typicality: 1,
          route_pattern_sort_order: 1,
          timing_name: "Weekday base",
          timing_headsign: "Lincoln City",
          stops: [
            {"AL_NTC", 0, 0, 1},
            {"AL_CST6", 420, 420, 0},
            {"AL_CST12", 900, 900, 1},
            {"AL_CST20", 1500, 1560, 0},
            {"AL_CST36", 2400, 2400, 0},
            {"AL_LCTC", 4200, 4200, 1}
          ]
        })

      route_1_inbound =
        alerts_pattern.(alerts_route_1, %{
          route_id: alerts_route_1.route_id,
          direction_id: 1,
          route_pattern_id: "AL-R1-P2",
          route_pattern_name: "Coast Highway to Newport",
          route_pattern_typicality: 3,
          route_pattern_sort_order: 1,
          timing_name: "Weekday base",
          timing_headsign: "Newport",
          stops: [
            {"AL_LCTC", 0, 0, 1},
            {"AL_CST36", 1800, 1800, 0},
            {"AL_CST20", 2700, 2760, 0},
            {"AL_CST12", 3300, 3300, 1},
            {"AL_CST6", 3780, 3780, 0},
            {"AL_NTC", 4200, 4200, 1}
          ]
        })

      # Route 12 starts and ends at the stop Route 1 also serves, so choosing that
      # stop on a Route 1 alert raises the shared-route question.
      route_12_outbound =
        alerts_pattern.(alerts_route_12, %{
          route_id: alerts_route_12.route_id,
          direction_id: 0,
          route_pattern_id: "AL-R12-P1",
          route_pattern_name: "Nye Beach to Hospital",
          route_pattern_typicality: 1,
          route_pattern_sort_order: 1,
          timing_name: "Weekday base",
          timing_headsign: "Hospital",
          stops: [
            {"AL_NTC", 0, 0, 1},
            {"AL_NYE", 900, 960, 0},
            {"AL_HOSP", 2100, 2100, 1}
          ]
        })

      route_12_inbound =
        alerts_pattern.(alerts_route_12, %{
          route_id: alerts_route_12.route_id,
          direction_id: 1,
          route_pattern_id: "AL-R12-P2",
          route_pattern_name: "Hospital to Nye Beach",
          route_pattern_typicality: 3,
          route_pattern_sort_order: 1,
          timing_name: "Weekday base",
          timing_headsign: "Nye Beach",
          stops: [
            {"AL_HOSP", 0, 0, 1},
            {"AL_NYE", 1140, 1200, 0},
            {"AL_NTC", 2100, 2100, 1}
          ]
        })

      route_50_outbound =
        alerts_pattern.(alerts_route_50, %{
          route_id: alerts_route_50.route_id,
          direction_id: 0,
          route_pattern_id: "AL-R50-P1",
          route_pattern_name: "Lincoln City Connector",
          route_pattern_typicality: 1,
          route_pattern_sort_order: 1,
          timing_name: "Weekday base",
          timing_headsign: "Newport",
          stops: [
            {"AL_CST12", 0, 0, 1},
            {"AL_CST20", 420, 420, 0}
          ]
        })

      # Every trip carries the headsign a rider names it by, because the departures
      # question labels a departure with its first stop time and where it goes
      # (AC-10, AC-19). The night trip leaves at 24:40, so its own clock renders
      # as the next day rather than as an earlier departure.
      [
        {alerts_route_1, route_1_outbound, "AL-R1-T1", "06:05:00", "ALERTS_WEEKDAY",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T2", "08:15:00", "ALERTS_WEEKDAY",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T3", "12:40:00", "ALERTS_WEEKDAY",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T4", "16:20:00", "ALERTS_WEEKDAY",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T5", "18:35:00", "ALERTS_WEEKDAY",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T6", "24:40:00", "ALERTS_WEEKDAY",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T7", "09:00:00", "ALERTS_WEEKEND",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T8", "17:30:00", "ALERTS_WEEKEND",
         "Lincoln City"},
        {alerts_route_1, route_1_outbound, "AL-R1-T11", "24:40:00", "ALERTS_WEEKEND",
         "Lincoln City"},
        {alerts_route_1, route_1_inbound, "AL-R1-T9", "07:00:00", "ALERTS_WEEKDAY", "Newport"},
        {alerts_route_1, route_1_inbound, "AL-R1-T10", "19:00:00", "ALERTS_WEEKDAY", "Newport"},
        {alerts_route_12, route_12_outbound, "AL-R12-T1", "06:50:00", "ALERTS_WEEKDAY",
         "Hospital"},
        {alerts_route_12, route_12_outbound, "AL-R12-T2", "15:00:00", "ALERTS_WEEKDAY",
         "Hospital"},
        {alerts_route_12, route_12_outbound, "AL-R12-T3", "10:00:00", "ALERTS_WEEKEND",
         "Hospital"},
        {alerts_route_12, route_12_inbound, "AL-R12-T4", "08:00:00", "ALERTS_WEEKDAY",
         "Nye Beach"},
        {alerts_route_50, route_50_outbound, "AL-R50-T1", "07:30:00", "ALERTS_WEEKDAY",
         "Newport"},
        {alerts_route_50, route_50_outbound, "AL-R50-T2", "11:00:00", "ALERTS_WEEKEND", "Newport"}
      ]
      |> Enum.each(fn {route, bundle, trip_id, start_time, service_id, headsign} ->
        GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
          org.id,
          alerts_version.id,
          route.route_id,
          bundle,
          %{
            service_id: service_id,
            trip_id: trip_id,
            start_time: start_time,
            trip_headsign: headsign
          }
        )
      end)

      IO.puts(
        "Browser seed: alerts version #{alerts_version.id} " <>
          "(Routes 1/12 bus and Route 50 tram, eight coded stops, " <>
          "Newport Transit Center shared by Routes 1 and 12, weekday and weekend " <>
          "service today ± 60 days, headsigns on every trip, Route 1 night trip " <>
          "departing at 24:40)"
      )

      # One organization script so the message step has an organization-owned
      # wording to generate from alongside the built-in ones.
      alerts_audit = %GtfsPlanner.Gtfs.AuditContext{
        organization_id: org.id,
        gtfs_version_id: alerts_version.id,
        station_stop_id: nil,
        actor_id: editor.id,
        actor_email: editor.email
      }

      # Alerts are written against the organization's active schedule, and the first
      # version an organization has keeps that pointer, so the alerts version is
      # selected explicitly before any alert is created.
      alerts_token = fn ->
        {:ok, %{token: token}} = GtfsPlanner.Versions.active_schedule(alerts_audit)
        token
      end

      {:ok, _active} =
        GtfsPlanner.Versions.set_active_schedule(
          alerts_audit,
          alerts_version.id,
          alerts_token.()
        )

      {:ok, _alerts_script} =
        GtfsPlanner.Alerts.create_script(alerts_audit, %{
          name: "Route detour",
          situation: :detour,
          header_template: "[route] detour: [stop] not served",
          description_template:
            "[route] toward [direction] is not serving [stop]. Board at [alternate stop] instead. " <>
              "Expect up to [minutes] minutes of delay[because].",
          position: 1
        })

      IO.puts("Browser seed: organization alert script \"Route detour\"")

      # Four alerts so the list page's four tabs all have something to show:
      # a current delay about Route 12, a planned street closure that is Upcoming,
      # a draft still being answered, and an alert whose stop was deleted from the
      # version so the Needs attention badge has a real cause. Created and finished
      # through the same commands the editor uses, so no row carries a field an
      # editor path cannot write.
      alerts_today = Gtfs.DisplayClock.today(org.id, alerts_version.id).date
      alerts_check_in = NaiveDateTime.new!(alerts_today, ~T[18:00:00])

      alerts_new = fn attrs ->
        {:ok, alert} =
          GtfsPlanner.Alerts.create_alert(alerts_audit, attrs, expected_schedule: alerts_token.())

        alert
      end

      alerts_finish = fn alert, timing ->
        {:ok, saved} =
          GtfsPlanner.Alerts.save_draft(alerts_audit, alert.id, alert.revision, %{
            "timing" => timing
          })

        saved
      end

      alerts_current =
        alerts_new.(%{
          "urgency" => "now",
          "situation" => "delay",
          "cause" => "weather",
          "scope" => %{"shape" => "routes", "route_ids" => [alerts_route_12.route_id]},
          "message" => %{
            "header" => "Route 12 delays of up to 20 minutes",
            "description" => "Wet roads on the coast road. Expect up to 20 minutes of delay."
          }
        })

      alerts_finish.(alerts_current, %{
        "start_date" => Date.to_iso8601(alerts_today),
        "start_time" => "08:00:00",
        "end_kind" => "estimated",
        "check_in_at" => NaiveDateTime.to_iso8601(alerts_check_in)
      })

      alerts_upcoming =
        alerts_new.(%{
          "urgency" => "planned",
          "situation" => "stop_closed",
          "cause" => "construction",
          "scope" => %{
            "shape" => "stop_all_routes",
            "stop_ids" => [Enum.at(alerts_stops, 5).stop_id]
          },
          "message" => %{
            "header" => "Harbor Street stop closed for road works",
            "description" => "Harbor Street stop is closed. Board at the Ferry Terminal stop."
          }
        })

      alerts_finish.(alerts_upcoming, %{
        "pattern" => "continuous",
        "first_date" => Date.to_iso8601(Date.add(alerts_today, 14)),
        "last_date" => Date.to_iso8601(Date.add(alerts_today, 18)),
        "all_day" => true
      })

      alerts_in_progress = alerts_new.(%{"urgency" => "planned", "situation" => "detour"})

      # The alert names a stop by its GTFS stop_id, which exists in the version when
      # the alert is written, because a write refuses a stop_id the version does not
      # have. The stop is deleted once the alert is finished, which is how a stop
      # leaves a version in practice and what the Needs attention badge reports.
      {:ok, alerts_old_depot} =
        GtfsFixtures.insert_stop(%{
          organization_id: org.id,
          gtfs_version_id: alerts_version.id,
          stop_id: "AL_OLD_DEPOT",
          stop_name: "Old Depot Road",
          location_type: 0,
          stop_lat: Decimal.new("44.6600"),
          stop_lon: Decimal.new("-124.0500")
        })

      alerts_needs_attention =
        alerts_new.(%{
          "urgency" => "now",
          "situation" => "stop_closed",
          "cause" => "construction",
          "scope" => %{
            "shape" => "stop_all_routes",
            "stop_ids" => [alerts_old_depot.stop_id]
          },
          "message" => %{
            "header" => "Old Depot Road stop closed",
            "description" => "Old Depot Road stop is closed while the retaining wall is rebuilt."
          }
        })

      alerts_finish.(alerts_needs_attention, %{
        "start_date" => Date.to_iso8601(alerts_today),
        "start_time" => "08:00:00",
        "end_kind" => "estimated",
        "check_in_at" => NaiveDateTime.to_iso8601(alerts_check_in)
      })

      Repo.delete!(alerts_old_depot)

      IO.puts(
        "Browser seed: alerts #{alerts_current.id} current, " <>
          "#{alerts_upcoming.id} upcoming, #{alerts_in_progress.id} in progress, " <>
          "#{alerts_needs_attention.id} needing attention"
      )

      %{
        audit: alerts_audit,
        check_in: alerts_check_in,
        current: alerts_current,
        finish: alerts_finish,
        new: alerts_new,
        route_12: alerts_route_12,
        today: alerts_today,
        token: alerts_token,
        upcoming: alerts_upcoming
      }
    end

    # Browser Test Org keeps the fixtures the feed-publishing journeys publish
    # against, and keeps the Browser E2E Version as its latest published
    # version, so nothing else in that organization moves.
    %{
      audit: alerts_audit,
      check_in: alerts_check_in,
      current: alerts_current,
      finish: alerts_finish,
      new: alerts_new,
      route_12: alerts_route_12,
      today: alerts_today,
      token: alerts_token,
      upcoming: alerts_upcoming
    } = seed_alerts_fixtures.(org, editor)

    # ── Alerts journeys organization (spec 30) ──
    #
    # The alert editor resolves its schedule from the organization's active
    # schedule, so the alert journeys need an organization whose active schedule is
    # the alert-authoring version. This organization's default version is staging
    # (versions are only published when they are finalized), so the fixture version
    # above is the one the editor and its questions read. No other spec signs in
    # here.
    {:ok, alerts_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser Alerts Org",
        alias: "browser-alerts"
      })

    # create_organization seeds a published default version, which would be the
    # one the editor resolves. Deleting it leaves the fixture version seeded
    # below as this organization's only published version, so the editor and its
    # questions read the alert-authoring schedule.
    GtfsPlanner.OrganizationsFixtures.delete_versions!(
      from(v in GtfsPlanner.Versions.GtfsVersion, where: v.organization_id == ^alerts_org.id)
    )

    {:ok, alerts_org_editor} =
      Accounts.register_user(%{
        email: "alerts-editor@gtfs-planner.test",
        password: "DiagramTest123!"
      })

    Repo.update!(User.confirm_changeset(alerts_org_editor))

    Accounts.create_user_org_membership(%{
      user_id: alerts_org_editor.id,
      organization_id: alerts_org.id,
      roles: ["pathways_studio_editor"]
    })

    seed_alerts_fixtures.(alerts_org, alerts_org_editor)

    # ── Active schedule workspace organizations (spec 34, `GTFS identity workspace`) ──
    #
    # /alerts names the organization's active schedule and lets an editor choose it.
    # Each state has its own organization and editor, because a journey that changes
    # the selection would otherwise move the schedule every other alert journey reads.
    #
    #   * Browser Identity Org: three published schedules. The active one is chosen
    #     explicitly below, not inherited from insertion order, and the newest
    #     published schedule is a different one, so the version menu in the header
    #     shows a schedule that is not the active one. "Identity Second Schedule"
    #     keeps Route 12 under another short name and lacks the Annex stop;
    #     "Identity Empty Schedule" holds nothing.
    #   * Browser Identity Legacy Org: two published schedules and no pointer, the
    #     state an organization could be left in before the pointer existed. It is
    #     the only fixture that exercises choosing a schedule from "no active".
    #   * Browser Identity Empty Org: no published schedule at all, only a staging one.
    identity_editor = fn org, email ->
      {:ok, user} = Accounts.register_user(%{email: email, password: "IdentityTest123!"})
      Repo.update!(User.confirm_changeset(user))

      {:ok, _membership} =
        Accounts.create_user_org_membership(%{
          user_id: user.id,
          organization_id: org.id,
          roles: ["pathways_studio_editor"]
        })

      user
    end

    identity_schedule = fn org, name, published_at, route_12_name, stop_ids ->
      {:ok, version} = Versions.create_gtfs_version(org.id, %{name: name})
      version = Repo.update!(Ecto.Changeset.change(version, published_at: published_at))

      {:ok, _agency} =
        GtfsFixtures.insert_agency(%{
          organization_id: org.id,
          gtfs_version_id: version.id,
          agency_id: "IDENTITY_AGENCY",
          agency_name: "Identity Transit",
          agency_url: "https://example.test",
          agency_timezone: "America/Los_Angeles"
        })

      for {route_id, short_name} <- [{"1", "1"}, {"12", route_12_name}] do
        {:ok, _route} =
          GtfsFixtures.insert_route(%{
            organization_id: org.id,
            gtfs_version_id: version.id,
            route_id: route_id,
            route_short_name: short_name,
            route_long_name: "Identity route #{route_id}",
            route_type: 3
          })
      end

      for stop_id <- stop_ids do
        {:ok, _stop} =
          GtfsFixtures.insert_stop(%{
            organization_id: org.id,
            gtfs_version_id: version.id,
            stop_id: stop_id,
            stop_name: "Identity stop #{stop_id}",
            location_type: 0,
            stop_lat: Decimal.new("44.6210"),
            stop_lon: Decimal.new("-124.0490")
          })
      end

      version
    end

    {:ok, identity_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser Identity Org",
        alias: "browser-identity"
      })

    identity_user = identity_editor.(identity_org, "identity-workspace@gtfs-planner.test")
    identity_scope = %{actor_id: identity_user.id, organization_id: identity_org.id}

    # The version the organization starts with is the empty schedule: it was the first
    # usable version, so it starts active until the explicit choice below.
    identity_empty =
      from(v in GtfsPlanner.Versions.GtfsVersion, where: v.organization_id == ^identity_org.id)
      |> Repo.one!()
      |> Ecto.Changeset.change(
        name: "Identity Empty Schedule",
        published_at: ~U[2020-02-01 00:00:00.000000Z]
      )
      |> Repo.update!()

    identity_active =
      identity_schedule.(
        identity_org,
        "Identity Active Schedule",
        ~U[2020-03-01 00:00:00.000000Z],
        "12",
        ["ID_MAIN", "ID_ANNEX"]
      )

    identity_second =
      identity_schedule.(
        identity_org,
        "Identity Second Schedule",
        ~U[2020-04-01 00:00:00.000000Z],
        "12X",
        ["ID_MAIN"]
      )

    {:ok, %{token: identity_token}} = Versions.active_schedule(identity_scope)

    {:ok, _active} =
      Versions.set_active_schedule(identity_scope, identity_active.id, identity_token)

    identity_audit = %GtfsPlanner.Gtfs.AuditContext{
      organization_id: identity_org.id,
      gtfs_version_id: identity_active.id,
      station_stop_id: nil,
      actor_id: identity_user.id,
      actor_email: identity_user.email
    }

    identity_today = Gtfs.DisplayClock.today(identity_org.id, identity_active.id).date

    # Three Current alerts through the editor's own commands: one that names Route 12
    # (its badge follows the schedule), one that names a stop only the active schedule
    # has (it needs attention elsewhere) and one about the whole system (it never does).
    for {attrs, header} <- [
          {%{
             "situation" => "delay",
             "cause" => "weather",
             "scope" => %{"shape" => "routes", "route_ids" => ["12"]}
           }, "Route 12 delays of up to 20 minutes"},
          {%{
             "situation" => "stop_closed",
             "cause" => "construction",
             "scope" => %{"shape" => "stop_all_routes", "stop_ids" => ["ID_ANNEX"]}
           }, "Annex stop closed for road works"},
          {%{
             "situation" => "service_change",
             "cause" => "maintenance",
             "scope" => %{"shape" => "system"}
           }, "Service changes tonight"}
        ] do
      {:ok, %{token: token}} = Versions.active_schedule(identity_scope)

      {:ok, alert} =
        GtfsPlanner.Alerts.create_alert(
          identity_audit,
          Map.merge(attrs, %{
            "urgency" => "now",
            "message" => %{"header" => header, "description" => "#{header}. Plan extra time."}
          }),
          expected_schedule: token
        )

      {:ok, _saved} =
        GtfsPlanner.Alerts.save_draft(identity_audit, alert.id, alert.revision, %{
          "timing" => %{
            "start_date" => Date.to_iso8601(identity_today),
            "start_time" => "08:00:00",
            "end_kind" => "estimated",
            "check_in_at" =>
              NaiveDateTime.to_iso8601(NaiveDateTime.new!(identity_today, ~T[18:00:00]))
          }
        })
    end

    IO.puts(
      "Browser seed: identity workspace #{identity_user.email} in #{identity_org.name} " <>
        "(active #{identity_active.id}, second #{identity_second.id}, empty #{identity_empty.id})"
    )

    {:ok, legacy_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser Identity Legacy Org",
        alias: "browser-identity-legacy"
      })

    legacy_user = identity_editor.(legacy_org, "identity-legacy@gtfs-planner.test")

    identity_schedule.(
      legacy_org,
      "Identity Legacy Schedule",
      ~U[2020-04-01 00:00:00.000000Z],
      "12",
      ["ID_MAIN"]
    )

    # The pointer is cleared the way a pre-pointer organization would have it. This is
    # the one fixture that models a legacy nil pointer with published schedules.
    Repo.update_all(
      from(o in GtfsPlanner.Organizations.Organization, where: o.id == ^legacy_org.id),
      set: [active_gtfs_version_id: nil]
    )

    IO.puts("Browser seed: identity legacy #{legacy_user.email} in #{legacy_org.name}")

    {:ok, empty_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser Identity Empty Org",
        alias: "browser-identity-empty"
      })

    empty_user = identity_editor.(empty_org, "identity-empty@gtfs-planner.test")

    GtfsPlanner.OrganizationsFixtures.delete_versions!(
      from(v in GtfsPlanner.Versions.GtfsVersion, where: v.organization_id == ^empty_org.id)
    )

    {:ok, _empty_staging} =
      Versions.create_staging_gtfs_version(empty_org.id, %{name: "Identity Staging Only"})

    IO.puts("Browser seed: identity empty #{empty_user.email} in #{empty_org.name}")

    # ── Alert editor journey (spec 34, `GTFS identity editor`) ──
    #
    # One organization the editor journey may move: two schedules that differ by one
    # stop, the active one chosen explicitly, and one Current alert about the stop only
    # the active schedule has. The journey changes the active schedule from a second
    # session and restores it, so no other journey reads this organization. The empty
    # organization above is the editor journey's no-active fixture.
    {:ok, editor_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser Identity Editor Org",
        alias: "browser-identity-editor"
      })

    editor_user = identity_editor.(editor_org, "identity-editor@gtfs-planner.test")
    editor_scope = %{actor_id: editor_user.id, organization_id: editor_org.id}

    from(v in GtfsPlanner.Versions.GtfsVersion, where: v.organization_id == ^editor_org.id)
    |> Repo.one!()
    |> Ecto.Changeset.change(
      name: "Editor Empty Schedule",
      published_at: ~U[2020-02-01 00:00:00.000000Z]
    )
    |> Repo.update!()

    editor_active =
      identity_schedule.(
        editor_org,
        "Editor Active Schedule",
        ~U[2020-03-01 00:00:00.000000Z],
        "12",
        ["ED_MAIN", "ED_ANNEX"]
      )

    editor_second =
      identity_schedule.(
        editor_org,
        "Editor Second Schedule",
        ~U[2020-04-01 00:00:00.000000Z],
        "12",
        ["ED_MAIN", "ED_HARBOR"]
      )

    {:ok, %{token: editor_token}} = Versions.active_schedule(editor_scope)

    {:ok, _active} =
      Versions.set_active_schedule(editor_scope, editor_active.id, editor_token)

    editor_audit = %GtfsPlanner.Gtfs.AuditContext{
      organization_id: editor_org.id,
      gtfs_version_id: editor_active.id,
      station_stop_id: nil,
      actor_id: editor_user.id,
      actor_email: editor_user.email
    }

    editor_today = Gtfs.DisplayClock.today(editor_org.id, editor_active.id).date
    {:ok, %{token: editor_token}} = Versions.active_schedule(editor_scope)

    {:ok, editor_alert} =
      GtfsPlanner.Alerts.create_alert(
        editor_audit,
        %{
          "urgency" => "now",
          "situation" => "stop_closed",
          "cause" => "construction",
          "scope" => %{
            "shape" => "stop_all_routes",
            "stop_ids" => ["ED_ANNEX"],
            "route_ids" => ["12"],
            "all_routes_at_stops" => true,
            "alternative_directions" => "Board at the main stop."
          },
          "message" => %{
            "header" => "Annex stop closed for road works",
            "description" => "Annex stop closed for road works. Board at the main stop."
          }
        },
        expected_schedule: editor_token
      )

    {:ok, _saved} =
      GtfsPlanner.Alerts.save_draft(editor_audit, editor_alert.id, editor_alert.revision, %{
        "timing" => %{
          "start_date" => Date.to_iso8601(editor_today),
          "start_time" => "08:00:00",
          "end_kind" => "estimated",
          "check_in_at" =>
            NaiveDateTime.to_iso8601(NaiveDateTime.new!(editor_today, ~T[18:00:00]))
        }
      })

    IO.puts(
      "Browser seed: identity editor #{editor_user.email} in #{editor_org.name} " <>
        "(active #{editor_active.id}, second #{editor_second.id})"
    )

    # ── Feed publishing journeys (spec 24, step 21) ──
    #
    # The browser journeys drive the real publication surfaces: the Export page's
    # review, the alert editor's publication card and the organization's
    # published-feeds page. They read real pinned artifacts and real durable rows,
    # so the seed creates one ready export run per reviewed file, the completed
    # artifact check each review reports, a claimed namespace with its channel
    # rows and their frozen attempts, and the accepted alert publications the
    # editor shows.
    #
    # Every seeded attempt is already `current` and matches its channel's desired
    # revision, which is how the periodic publisher tells settled state from work
    # it still owes: it leaves these rows exactly as seeded while a journey runs.
    pub_zip = fn members ->
      dir = Path.join(System.tmp_dir!(), "pub-seed-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "archive.zip")

      {:ok, _created} =
        :zip.create(
          String.to_charlist(path),
          Enum.map(members, fn {name, body} -> {String.to_charlist(name), body} end)
        )

      bytes = File.read!(path)
      File.rm_rf!(dir)
      bytes
    end

    pub_full_members = [
      {"agency.txt",
       "agency_id,agency_name,agency_url,agency_timezone\n" <>
         "BROWSER,Browser Test Transit,https://example.test,America/Los_Angeles\n"},
      {"routes.txt",
       "route_id,agency_id,route_short_name,route_type\nPUB_R1,BROWSER,1,3\nPUB_R2,BROWSER,2,1\n"},
      {"trips.txt", "trip_id,route_id,service_id\nPUB_T1,PUB_R1,PUB_S1\nPUB_T2,PUB_R2,PUB_S1\n"},
      {"stops.txt", "stop_id,stop_name\nPUB_A1,Alpha\nPUB_B1,Bravo\n"},
      {"stop_times.txt",
       "trip_id,arrival_time,departure_time,stop_id\n" <>
         "PUB_T1,06:00:00,06:00:00,PUB_A1\nPUB_T1,06:10:00,06:10:00,PUB_B1\n" <>
         "PUB_T2,07:00:00,07:00:00,PUB_A1\n"},
      {"route_patterns.txt", "route_pattern_id,route_id\nPUB_RP1,PUB_R1\n"}
    ]

    # One archive per reviewed file, and an archive carries one `stops.txt`: the
    # Pathways profile adds its station, its platform and the pathway between
    # them, so the shared file is replaced rather than repeated.
    pub_pathways_members =
      Enum.reject(pub_full_members, fn {name, _body} -> name == "stops.txt" end) ++
        [
          {"stops.txt",
           "stop_id,stop_name,location_type,parent_station\n" <>
             "PUB_PS1,Central,1,\nPUB_PS1_A,Platform A,0,PUB_PS1\n"},
          {"pathways.txt",
           "pathway_id,from_stop_id,to_stop_id,pathway_mode,is_bidirectional\n" <>
             "PUB_PW1,PUB_PS1_A,PUB_PS1,1,1\n"},
          {"levels.txt", "level_id,level_index,level_name\nPUB_L1,0,Ground\n"}
        ]

    pub_actor = %{id: editor.id, email: editor.email}

    pub_ready_run = fn export_type, members ->
      {:ok, run} = ExportRuns.create_pending(org.id, diagram_version.id, pub_actor, export_type)
      {:ok, _building, generation, token} = ExportRuns.claim(org.id, run.id, :build)

      {:ok, main} =
        ArtifactStorage.publish(
          org.id,
          diagram_version.id,
          run.id,
          "browser-#{export_type}.zip",
          pub_zip.(members)
        )

      {:ok, ready} =
        ExportRuns.mark_ready(org.id, run.id, generation, token, %{main: main, flex: nil})

      ready
    end

    # The completed artifact check a review reports. The journeys read these
    # instead of running the validator, so the reviewed file is the only variable.
    pub_review = fn run, errors ->
      Repo.insert!(%ValidationRun{
        organization_id: org.id,
        gtfs_version_id: diagram_version.id,
        run_type: "mobility_data_artifact",
        status: "completed",
        errors_count: errors,
        warnings_count: 2,
        infos_count: 5,
        artifact_sha256: run.artifact_sha256,
        artifact_slot: :main,
        artifact_export_run_id: run.id,
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now()
      })
    end

    pub_full_run = pub_ready_run.(:full, pub_full_members)
    pub_review.(pub_full_run, 0)

    # A second reviewed file whose check reported errors, so the consent step has
    # one to require on the same version through a different export type.
    pub_pathways_run = pub_ready_run.(:pathways, pub_pathways_members)
    pub_review.(pub_pathways_run, 3)

    pub_namespace =
      Repo.insert!(%GtfsPlanner.FeedPublishing.Namespace{
        organization_id: org.id,
        prefix: org.alias,
        public_claim: Ecto.UUID.generate()
      })

    pub_channel = fn channel, status, opts ->
      publication =
        Repo.insert!(%GtfsPlanner.FeedPublishing.Publication{
          organization_id: org.id,
          namespace_id: pub_namespace.id,
          channel: channel,
          status: :never_published
        })

      run = Keyword.fetch!(opts, :run)
      source = Keyword.fetch!(opts, :source)

      attempt =
        Repo.insert!(%GtfsPlanner.FeedPublishing.Attempt{
          publication_id: publication.id,
          organization_id: org.id,
          sequence: 1,
          generation: Ecto.UUID.generate(),
          desired_revision: 1,
          state: Keyword.get(opts, :attempt_state, "current"),
          actor_id: editor.id,
          provenance: "export-run:#{run.id}",
          manifest_body: ~s({"schema":1,"channel":"#{channel}"}),
          manifest_sha256: String.duplicate("a", 64),
          object_receipts: %{
            "zip" => %{"sha256" => run.artifact_sha256, "bytes" => run.artifact_size_bytes}
          },
          private_snapshot: %{"source" => source}
        })

      publication
      |> Ecto.Changeset.change(%{
        active_attempt_id: attempt.id,
        status: status,
        desired_revision: 1,
        next_sequence: 2,
        manifest_bytes: attempt.manifest_body,
        manifest_sha256: attempt.manifest_sha256,
        manifest_generation: attempt.generation,
        manifest_sequence: 1,
        manifest_last_modified: ~U[2026-10-02 09:00:00.000000Z],
        last_refresh_at: ~U[2026-10-02 09:05:00.000000Z],
        last_error: Keyword.get(opts, :last_error)
      })
      |> Repo.update!()
    end

    # A frozen receipt names the export the served bytes came from.
    pub_source = fn run ->
      %{
        "run_id" => run.id,
        "slot" => "main",
        "filename" => run.artifact_filename,
        "export_type" => Atom.to_string(run.export_type)
      }
    end

    pub_channel.(:full, :current, run: pub_full_run, source: pub_source.(pub_full_run))

    # A channel whose attempt the publisher blocked is settled as far as it is
    # concerned, so the failure state this journey asserts stays put.
    pub_channel.(:pathways, :failed,
      run: pub_pathways_run,
      attempt_state: "blocked",
      source: pub_source.(pub_pathways_run),
      last_error: "the public manifest belongs to another owner"
    )

    # The flex channel was published once and the publisher blocked its attempt,
    # so it reports that failure for as long as nothing publishes it again.
    pub_channel.(:flex, :failed,
      run: pub_full_run,
      attempt_state: "blocked",
      source: %{
        "run_id" => Ecto.UUID.generate(),
        "slot" => "flex",
        "filename" => "browser-full-flex.zip",
        "export_type" => "flex"
      },
      last_error: "the public manifest belongs to another owner"
    )

    # The realtime channel is settled too: while it has nothing left to
    # reconcile, the periodic refresh leaves the accepted alert publications -
    # and the served date the editor reports from one - exactly as seeded.
    pub_channel.(:alerts, :current,
      run: pub_full_run,
      source: %{
        "run_id" => Ecto.UUID.generate(),
        "slot" => "main",
        "filename" => "browser-alerts.pb",
        "export_type" => "full"
      }
    )

    # The alert editor's publication card, written through the command the editor
    # itself uses: one alert accepted and waiting to be served, and one accepted
    # and confirmed by the served manifest, which is the only state that carries a
    # publication date.
    pub_accept = fn alert ->
      # Read the row back first: finishing an alert writes a new revision, and
      # accepting one is a revision-checked write.
      alert = Repo.get!(GtfsPlanner.Alerts.Alert, alert.id)

      case GtfsPlanner.Alerts.save_review(
             alerts_audit,
             alert.id,
             alert.revision,
             %{
               "message" => %{
                 "header" => alert.message.header,
                 "description" => alert.message.description
               }
             },
             publish?: true,
             expected_schedule: alerts_token.()
           ) do
        {:ok, %{alert: _accepted, publication: {:refused, field_errors}}} ->
          raise "Browser seed: alert publication refused: #{inspect(field_errors)}"

        {:ok, %{alert: accepted, publication: _outcome}} ->
          accepted

        other ->
          raise "Browser seed: alert acceptance failed: #{inspect(other)}"
      end
    end

    # A current alert accepted and confirmed by the served manifest: the only
    # state that carries a publication date.
    pub_accepted_current = pub_accept.(alerts_current)

    Repo.update_all(
      from(p in GtfsPlanner.Alerts.Publication, where: p.alert_id == ^pub_accepted_current.id),
      set: [confirmed_revision: 1, last_published_at: ~U[2026-10-01 12:00:00.000000Z]]
    )

    # A planned alert accepted for a notice that has not begun: accepted, and
    # still without a served date.
    _pub_scheduled_upcoming = pub_accept.(alerts_upcoming)

    # An alert whose removal the realtime feed still owes, created only for this:
    # accepting it gives it something to withdraw, and deleting it persists the
    # intent and its tombstone. It leaves every list the moment it is deleted.
    pub_withdrawn =
      alerts_new.(%{
        "urgency" => "now",
        "situation" => "delay",
        "cause" => "weather",
        "scope" => %{"shape" => "routes", "route_ids" => [alerts_route_12.route_id]},
        "message" => %{
          "header" => "Route 12 rerouted for the harvest fair",
          "description" => "Route 12 is detouring around the fair until Sunday evening."
        }
      })

    pub_withdrawn =
      alerts_finish.(pub_withdrawn, %{
        "start_date" => Date.to_iso8601(alerts_today),
        "start_time" => "08:00:00",
        "end_kind" => "estimated",
        "check_in_at" => NaiveDateTime.to_iso8601(alerts_check_in)
      })

    pub_withdrawn = pub_accept.(pub_withdrawn)

    {:ok, _deleted} =
      GtfsPlanner.Alerts.delete_alert(alerts_audit, pub_withdrawn.id, pub_withdrawn.revision)

    IO.puts(
      "Browser seed: publishing version #{diagram_version.name} " <>
        "(ready runs full=#{pub_full_run.id} pathways=#{pub_pathways_run.id}, " <>
        "channels full current / pathways failed, alert accepted " <>
        "#{pub_accepted_current.id}, " <>
        "#{pub_withdrawn.id} pending removal)"
    )

    dated_change_today =
      Gtfs.DisplayClock.today(org.id, dated_change_version.id).date

    Enum.each(1..4, fn index ->
      {lat, lon} =
        Enum.at(
          [
            {"39.9800", "-75.1900"},
            {"39.9830", "-75.1840"},
            {"39.9860", "-75.1780"},
            {"39.9890", "-75.1720"}
          ],
          index - 1
        )

      {:ok, _stop} =
        GtfsFixtures.insert_stop(%{
          stop_id: "BDC_#{index}",
          stop_name: "Dated Change Stop #{index}",
          location_type: 0,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new(lon),
          organization_id: org.id,
          gtfs_version_id: dated_change_version.id
        })
    end)

    # Fixed 2026 dates rather than dates relative to today, so the report's
    # exact totals and its nine in-window dates are the same on every day the
    # suite runs.
    dated_change_weekly = [
      %{
        service_id: "DC_WEEKDAY",
        monday: 1,
        tuesday: 1,
        wednesday: 1,
        thursday: 1,
        friday: 1,
        saturday: 0,
        sunday: 0,
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-12-31]
      },
      %{
        service_id: "DC_WEEKEND",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 1,
        start_date: ~D[2026-01-01],
        end_date: ~D[2026-12-31]
      }
    ]

    Enum.each(dated_change_weekly, fn calendar ->
      _calendar =
        GtfsFixtures.calendar_fixture(org.id, dated_change_version.id, calendar)

      _attribute =
        GtfsFixtures.calendar_attribute_fixture(org.id, dated_change_version.id, %{
          service_id: calendar.service_id,
          service_description: calendar.service_id,
          service_schedule_name: nil,
          service_schedule_type: nil,
          service_schedule_typicality: 0,
          rating_start_date: nil,
          rating_end_date: nil,
          rating_description: nil
        })
    end)

    # The removed Veterans Day is the one date the original service never runs,
    # so the plan must keep it out of the in-window list and out of the kept
    # list, and name it as absent rather than moving it.
    _removed_day =
      GtfsFixtures.calendar_date_fixture(org.id, dated_change_version.id, %{
        service_id: "DC_WEEKDAY",
        date: ~D[2026-11-11],
        exception_type: 2
      })

    {:ok, dated_change_route} =
      GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: dated_change_version.id,
        route_id: "BROWSER_DATED_CHANGE",
        route_short_name: "DC",
        route_long_name: "Browser dated change",
        route_type: 3
      })

    dated_change_bundle =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, dated_change_version.id, %{
        route_id: dated_change_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-DC-P1",
        route_pattern_name: "Dated change outbound",
        route_pattern_typicality: 1,
        timing_name: "Base",
        timing_headsign: "Dated change outbound",
        stops: [
          {"BDC_1", 0, 0, 1},
          {"BDC_2", 420, 450, 0},
          {"BDC_3", 900, 900, 1},
          {"BDC_4", 1500, 1500, 0}
        ]
      })

    for {trip_id, start_time, short_name, service_id} <- [
          {"DC_T_0700", "07:00:00", "7101", "DC_WEEKDAY"},
          {"DC_T_0800", "08:00:00", "7102", "DC_WEEKDAY"},
          {"DC_T_2510", "25:10:00", "7103", "DC_WEEKDAY"},
          {"DC_S_0930", "09:30:00", "7201", "DC_WEEKEND"}
        ] do
      GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
        org.id,
        dated_change_version.id,
        dated_change_route.route_id,
        dated_change_bundle,
        %{
          service_id: service_id,
          trip_id: trip_id,
          trip_short_name: short_name,
          start_time: start_time,
          trip_headsign: "Dated change outbound"
        }
      )
    end

    {:ok, wide_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Dated Change Wide Version"})

    wide_version =
      Repo.update!(
        Ecto.Changeset.change(wide_version, published_at: ~U[2020-04-02 00:00:00.000000Z])
      )

    Enum.each(1..2, fn index ->
      {lat, lon} =
        Enum.at(
          [
            {"40.0100", "-75.2100"},
            {"40.0140", "-75.2030"}
          ],
          index - 1
        )

      {:ok, _stop} =
        GtfsFixtures.insert_stop(%{
          stop_id: "BDW_#{index}",
          stop_name: "Dated Change Wide Stop #{index}",
          location_type: 0,
          stop_lat: Decimal.new(lat),
          stop_lon: Decimal.new(lon),
          organization_id: org.id,
          gtfs_version_id: wide_version.id
        })
    end)

    _wide_calendar =
      GtfsFixtures.calendar_fixture(org.id, wide_version.id, %{
        service_id: "DC_WIDE",
        monday: 0,
        tuesday: 0,
        wednesday: 0,
        thursday: 0,
        friday: 0,
        saturday: 1,
        sunday: 0,
        start_date: ~D[2026-01-01],
        end_date: Date.add(~D[2026-01-01], 200_000)
      })

    _wide_attribute =
      GtfsFixtures.calendar_attribute_fixture(org.id, wide_version.id, %{
        service_id: "DC_WIDE",
        service_description: "DC_WIDE",
        service_schedule_name: nil,
        service_schedule_type: nil,
        service_schedule_typicality: 0,
        rating_start_date: nil,
        rating_end_date: nil,
        rating_description: nil
      })

    {:ok, wide_route} =
      GtfsFixtures.insert_route(%{
        organization_id: org.id,
        gtfs_version_id: wide_version.id,
        route_id: "BROWSER_DATED_CHANGE_WIDE",
        route_short_name: "DW",
        route_long_name: "Browser dated change wide",
        route_type: 3
      })

    wide_bundle =
      GtfsPlanner.GtfsFixtures.schedule_pattern_fixture(org.id, wide_version.id, %{
        route_id: wide_route.route_id,
        direction_id: 0,
        route_pattern_id: "BROWSER-DW-P1",
        route_pattern_name: "Wide outbound",
        route_pattern_typicality: 1,
        timing_name: "Base",
        timing_headsign: "Wide outbound",
        stops: [
          {"BDW_1", 0, 0, 1},
          {"BDW_2", 600, 600, 0}
        ]
      })

    GtfsPlanner.GtfsFixtures.schedule_trip_fixture(
      org.id,
      wide_version.id,
      wide_route.route_id,
      wide_bundle,
      %{
        service_id: "DC_WIDE",
        trip_id: "DW_T_1000",
        trip_short_name: "7301",
        start_time: "10:00:00",
        trip_headsign: "Wide outbound"
      }
    )

    IO.puts(
      "Browser seed: dated change version #{dated_change_version.id} " <>
        "(BROWSER_DATED_CHANGE: DC_WEEKDAY with 2026-11-11 removed, DC_WEEKEND, " <>
        "DC_T_0700/DC_T_0800/DC_T_2510/DC_S_0930) and wide version #{wide_version.id} " <>
        "(BROWSER_DATED_CHANGE_WIDE, DC_WIDE 200,001-day Saturday range, today #{dated_change_today})"
    )

    # ── Browser Feed Quality Version ──
    # One completed MobilityData report stored as a historical wrapper: its own
    # length is 1 while the embedded upstream total is 170 with three retained
    # samples. The samples name this version's own stop, a stop it never had and
    # a row-only entry, so the helper can show resolved navigation beside
    # unmapped evidence. The run keeps a fixed UUID so a journey can open its
    # result page directly.
    {:ok, feed_quality_version} =
      Versions.create_gtfs_version(org.id, %{name: BrowserFeedQuality.version_name()})

    feed_quality_version =
      Repo.update!(
        Ecto.Changeset.change(feed_quality_version,
          published_at: ~U[2020-01-02 00:00:00.000000Z]
        )
      )

    {:ok, _feed_quality_stop} =
      GtfsFixtures.insert_stop(%{
        stop_id: BrowserFeedQuality.stop_id(),
        stop_name: "Feed Quality Central",
        location_type: 0,
        organization_id: org.id,
        gtfs_version_id: feed_quality_version.id
      })

    %ValidationRun{
      id: BrowserFeedQuality.run_id(),
      organization_id: org.id,
      gtfs_version_id: feed_quality_version.id
    }
    |> ValidationRun.system_changeset(%{
      run_type: "mobility_data",
      status: "completed",
      started_at:
        DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:microsecond),
      completed_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
      result_json: %{
        "notices" => [
          %{
            "code" => "duplicate_key",
            "severity" => "WARNING",
            "totalNotices" => 1,
            "notices" => [
              %{
                "totalNotices" => 170,
                "sampleNotices" => [
                  %{
                    "filename" => "stops.txt",
                    "csvRowNumber" => 1,
                    "fieldName" => "stop_id",
                    "stopId" => BrowserFeedQuality.stop_id()
                  },
                  %{
                    "filename" => "stops.txt",
                    "csvRowNumber" => 2,
                    "fieldName" => "stop_id",
                    "stopId" => "FQ-MISSING"
                  },
                  %{"filename" => "stops.txt", "csvRowNumber" => 3, "fieldName" => "stop_id"}
                ]
              }
            ]
          }
        ]
      }
    })
    |> Repo.insert!()

    IO.puts(
      "Browser seed: feed quality version #{feed_quality_version.id} " <>
        "(run #{BrowserFeedQuality.run_id()}, 170 stored findings / 3 retained WARNING samples)"
    )

    # ── Release comparison (retained exports the comparison journeys choose from) ──
    #
    # Native-shaped ZIPs published through the real ExportRuns/ArtifactStorage
    # path, each on a backdated version named for what the journey compares. The
    # comparison itself is never seeded: the journey starts it from the Export
    # page and the coordinator reads these bytes.
    comparison_host =
      GtfsPlanner.ReleaseComparisonFixtures.seed_browser!(org, export_actor)

    IO.puts(
      "Browser seed: release comparison host #{comparison_host.name} " <>
        "(id=#{comparison_host.id}) with its retained exports"
    )

    # ── TODS generator worlds (spec 37, step 8) ──
    #
    # The generator's entry and prerequisite journey needs two organizations,
    # because garages belong to the organization rather than to a version: one an
    # editor can start a generation from, and one that has entered no garage at
    # all. Both are planner products, so the account menu offers the entry.
    #
    # The service window is fixed rather than relative to the run date, because
    # the journey asserts the form's defaulted first active calendar week: Monday
    # 5 – Sunday 11 October 2026 is the week holding 7 October, the first date
    # with service. Rows go through the ordinary fixtures the seed already uses.
    {:ok, tods_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser TODS Org",
        alias: "browser-tods-org",
        product: :planner
      })

    {:ok, tods_version} =
      Versions.create_gtfs_version(tods_org.id, %{name: "Browser TODS Version"})

    _tods_depot =
      GtfsPlanner.OperationsFixtures.garage_fixture(tods_org.id, %{
        "garage_id" => "TODS_DEPOT",
        "name" => "TODS Depot"
      })

    {:ok, tods_editor} =
      Accounts.register_user(%{
        email: "tods-generator@gtfs-planner.test",
        password: "TodsGenerator123!"
      })

    Repo.update!(User.confirm_changeset(tods_editor))

    {:ok, _tods_membership} =
      Accounts.create_user_org_membership(%{
        user_id: tods_editor.id,
        organization_id: tods_org.id,
        roles: ["pathways_studio_editor"]
      })

    {:ok, tods_empty_org} =
      Organizations.create_organization_unchecked(%{
        name: "Browser TODS Empty Org",
        alias: "browser-tods-empty-org",
        product: :planner
      })

    {:ok, tods_empty_version} =
      Versions.create_gtfs_version(tods_empty_org.id, %{name: "Browser TODS No Garage Version"})

    {:ok, tods_empty_editor} =
      Accounts.register_user(%{
        email: "tods-generator-empty@gtfs-planner.test",
        password: "TodsGenerator123!"
      })

    Repo.update!(User.confirm_changeset(tods_empty_editor))

    {:ok, _tods_empty_membership} =
      Accounts.create_user_org_membership(%{
        user_id: tods_empty_editor.id,
        organization_id: tods_empty_org.id,
        roles: ["pathways_studio_editor"]
      })

    for {tods_world_org, tods_world_version} <- [
          {tods_org, tods_version},
          {tods_empty_org, tods_empty_version}
        ] do
      GtfsPlanner.GtfsFixtures.calendar_fixture(tods_world_org.id, tods_world_version.id, %{
        service_id: "WKDY",
        start_date: ~D[2026-10-07],
        end_date: ~D[2026-10-20]
      })
    end

    IO.puts(
      "Browser seed: TODS generator editor #{tods_editor.email} in #{tods_org.name} " <>
        "(id=#{tods_org.id}), version #{tods_version.name} (id=#{tods_version.id}) with garage TODS_DEPOT; " <>
        "no-garage editor #{tods_empty_editor.email} in #{tods_empty_org.name} " <>
        "(id=#{tods_empty_org.id}), version #{tods_empty_version.name} (id=#{tods_empty_version.id})"
    )

    # ── TODS generator saved generation (spec 37, step 9) ──
    #
    # The preview/save journey needs a version the generator can actually build
    # from: a published version with a small schedule, one garage and one unblocked
    # trip, so a generation adds block "103" beside the schedule's own 101 and 102,
    # the runs cut from those blocks and one single-slot roster line and fictional
    # operator per run-day. The ordinary Blocks, Runs and Rosters screens then show
    # what the save stored, and the organization's Operators drawer lists the
    # fictional operators beside its real ones.
    #
    # `TodsGeneratorFixtures.tods_world_fixture/1` composes the same world the
    # generator's own domain cases read — the real `RunsFixtures`/`BlockingFixtures`
    # schedule, its relief and default-garage rules and its own weekday calendars —
    # so the journey proves the page against the production composition rather than
    # a fixture shaped like the page. The service window is the fixture's own; the
    # journey reads its dates from the page's defaults rather than assuming them.
    tods_saved_world =
      GtfsPlanner.TodsGeneratorFixtures.tods_world_fixture(
        extra_trips: [{"gen-a", "WK", "RIV", "RIV", "04:00:00", "04:30:00"}]
      )

    {:ok, tods_saved_editor} =
      Accounts.register_user(%{
        email: "tods-save@gtfs-planner.test",
        password: "TodsGenerator123!"
      })

    Repo.update!(User.confirm_changeset(tods_saved_editor))

    {:ok, _tods_saved_membership} =
      Accounts.create_user_org_membership(%{
        user_id: tods_saved_editor.id,
        organization_id: tods_saved_world.organization.id,
        roles: ["pathways_studio_editor"]
      })

    IO.puts(
      "Browser seed: TODS save editor #{tods_saved_editor.email} in " <>
        "#{tods_saved_world.organization.name} (id=#{tods_saved_world.organization.id}), " <>
        "version #{tods_saved_world.version.name} (id=#{tods_saved_world.version.id}) " <>
        "with garage #{tods_saved_world.garage.name} and one unblocked trip"
    )

    # The seed bulk-loads its rows, and a new database has no planner statistics
    # until autovacuum's first pass. A query planned before then estimates one row
    # per table and nests its joins, so the Stops page's routes-serving-stations
    # lookup runs for about a minute on the first visit. Analyze once the data is in.
    Repo.query!("ANALYZE")

  {:error, changeset} ->
    raise "Browser seed failed: #{inspect(changeset.errors)}"
end

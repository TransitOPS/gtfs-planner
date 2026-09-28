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
alias GtfsPlanner.Gtfs
alias GtfsPlanner.Gtfs.Agency
alias GtfsPlanner.Gtfs.Calendar
alias GtfsPlanner.Gtfs.CalendarAttribute
alias GtfsPlanner.Gtfs.ChangeLog
alias GtfsPlanner.Gtfs.DiagramStorage
alias GtfsPlanner.Gtfs.Export.ArtifactStorage
alias GtfsPlanner.Gtfs.Export.Run, as: ExportRun
alias GtfsPlanner.Gtfs.ExportRuns
alias GtfsPlanner.Gtfs.FareAttribute
alias GtfsPlanner.Gtfs.FareRule
alias GtfsPlanner.Gtfs.FareZones
alias GtfsPlanner.Gtfs.FeedInfo
alias GtfsPlanner.Gtfs.Flex
alias GtfsPlanner.Gtfs.FloorplanTransform
alias GtfsPlanner.Gtfs.Import.ChangeRuns
alias GtfsPlanner.Gtfs.Import.Run, as: ImportRun
alias GtfsPlanner.Gtfs.PathwayEvolution
alias GtfsPlanner.Gtfs.Route
alias GtfsPlanner.Gtfs.RoutePattern
alias GtfsPlanner.Gtfs.RoutePatternStop
alias GtfsPlanner.Gtfs.Shape
alias GtfsPlanner.Gtfs.Stop
alias GtfsPlanner.Gtfs.StopTime
alias GtfsPlanner.Gtfs.Transfer
alias GtfsPlanner.Gtfs.Trip
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

    {:ok, pending_partial_apply} = ChangeRuns.request_apply(org.id, partial_review.id)

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
      Gtfs.create_stop(%{
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
      Gtfs.create_level(%{
        level_id: "BROWSER_L1",
        level_name: "Browser Level 1",
        level_index: 0.0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, stop_level} =
      Gtfs.create_stop_level(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_agency(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_level(%{
        level_id: "BROWSER_L2",
        level_name: "Browser Level 2",
        level_index: 1.0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, stop_level2} =
      Gtfs.create_stop_level(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
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
      Organizations.create_organization(%{
        name: "Metropolitan Regional Transit Authority of the Greater Metropolitan Area",
        alias: "metro-regional-transit-authority-greater-metropolitan-area"
      })

    IO.puts("Browser seed: long-name organization for reflow tests")

    Enum.each(1..3, fn idx ->
      {:ok, _long_route} =
        Gtfs.create_route(%{
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
          Gtfs.create_stop(%{
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
          Gtfs.create_route(%{
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
        Gtfs.create_trip(%{
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
        Gtfs.create_route(%{
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
        Gtfs.create_trip(%{
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
          Gtfs.create_stop_time(%{
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
          Gtfs.create_route(%{
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
        Gtfs.create_trip(%{
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
          Gtfs.create_stop_time(%{
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
      Gtfs.create_route(%{
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
        Gtfs.create_stop(%{
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
          Gtfs.create_route(%{
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
          Gtfs.create_trip(%{
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
            Gtfs.create_stop_time(%{
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
          Gtfs.create_stop_time(%{
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
          Gtfs.create_route(%{
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
      Gtfs.create_trip(%{
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
      Gtfs.create_trip(%{
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
      Gtfs.create_trip(%{
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
      Gtfs.create_trip(%{
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
      Gtfs.create_trip(%{
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
      Gtfs.create_trip(%{
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
      Gtfs.create_trip(%{
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

    {:ok, _} = Organizations.deactivate_user_in_organization(auth_deactivated.id, org.id)
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
      Organizations.create_organization(%{
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
      Organizations.deactivate_user_in_organization(deactivated_member.id, admin_org.id)

    # Invitation pending: `invite_user/2` uses `User.invite_changeset/2`, which
    # sets no password, so the row renders "Invitation pending" and offers
    # "Resend invite".
    {:ok, pending_member} =
      Accounts.invite_user("contracts-pending@gtfs-planner.test", admin_org.id)

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
      Organizations.create_organization(%{
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
      Organizations.create_organization(%{
        name: "Account No Version Org",
        alias: "account-no-version"
      })

    Repo.delete_all(
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
      Organizations.create_organization(%{
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
      Gtfs.create_stop(%{
        stop_id: "VERY_LONG_STOP_ID_FOR_OVERFLOW_TESTING_12345",
        stop_name:
          "This Is A Very Long Station Name For Testing Overflow Behavior At Narrow Viewports",
        location_type: 1,
        wheelchair_boarding: 0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _missing_stop} =
      Gtfs.create_stop(%{
        stop_id: "CATALOG_MISSING_VALUES",
        stop_name: "Missing Values Stop",
        location_type: 0,
        wheelchair_boarding: 0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _accessible_stop} =
      Gtfs.create_stop(%{
        stop_id: "CATALOG_ACCESSIBLE",
        stop_name: "Direct Accessible Stop",
        location_type: 0,
        wheelchair_boarding: 1,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, _not_accessible_stop} =
      Gtfs.create_stop(%{
        stop_id: "CATALOG_NOT_ACCESSIBLE",
        stop_name: "Direct Not Accessible Stop",
        location_type: 0,
        wheelchair_boarding: 2,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, inherited_station} =
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
        stop_id: "CATALOG_NO_DATA",
        stop_name: "No Data Stop",
        location_type: 0,
        wheelchair_boarding: 0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    IO.puts("Browser seed: tri-state accessibility stops for catalog contracts")

    {:ok, _pathway_station} =
      Gtfs.create_stop(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_route(%{
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
    # Zone metadata goes through `FareZones.create_zone/3` (CR-1 keeps that
    # module `fare_zones`' only writer) and the route through
    # `Gtfs.create_route/1`. Stop, fare and rule rows are fixture data inserted
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
        FareZones.create_zone(org.id, fare_zones_version.id, %{
          zone_id: zone_id,
          name: name,
          color: color
        })
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
      Gtfs.create_route(%{
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
    fare_fares = FareZones.list_fares(org.id, fare_zones_version.id)

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
    # The two services are written through the production `Flex.create_service/3`
    # and `Flex.save_service/5`, so the seed stores exactly what the service page
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
      Flex.create_service(org.id, flex_version.id, %{name: "Newport Dial-a-Ride", kind: :area})

    {:ok, _flex_area_saved} =
      Flex.save_service(
        org.id,
        flex_version.id,
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
      Flex.create_service(org.id, flex_version.id, %{
        name: "Valley Line detours",
        kind: :detour,
        route_id: "20"
      })

    {:ok, _flex_detour_saved} =
      Flex.save_service(
        org.id,
        flex_version.id,
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
      Gtfs.create_route(%{
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
        Gtfs.create_trip(%{
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
      Gtfs.create_route(%{
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
        Gtfs.create_trip(%{
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
      Gtfs.create_route(%{
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
          Gtfs.create_stop(%{
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
          Gtfs.create_stop(%{
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
          Gtfs.create_route(%{
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
      Gtfs.create_route(%{
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
          Gtfs.create_route(%{
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

    # After midnight: the last arrival is 25:30, so the End cell reads 01:30 +1d and
    # the axis ceiling is 26:00.
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

    {:ok, schedules_version} =
      Versions.create_gtfs_version(org.id, %{name: "Browser Schedules No Calendars"})

    {:ok, _schedule_route} =
      Gtfs.create_route(%{
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
    # for the substitution case. Dates are relative to this version's
    # agency-local today (the UTC fallback, because the version has no agency),
    # so "next Monday" stays a real service date on any run date. Rows are
    # inserted directly because this fixture supplies scenario data, not an
    # audited edit.
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
        {:ok, stop} = Gtfs.create_stop(attrs)
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
        Gtfs.create_route(%{
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
        Gtfs.create_trip(%{
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
          Gtfs.create_stop_time(%{
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
      %{from_stop_id: "BXF_CEN", to_stop_id: "BXF_CEN", transfer_type: 2, min_transfer_time: 300},
      %{
        from_stop_id: "BXF_CEN",
        to_stop_id: "BXF_CEN",
        from_route_id: "BXF_12",
        transfer_type: 2,
        min_transfer_time: 120
      },
      %{from_stop_id: "BXF_CEN", to_stop_id: "BXF_CEN", to_route_id: "BXF_24", transfer_type: 3},
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
        Gtfs.create_route(%{
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
      Gtfs.create_stop(%{
        stop_id: "BROWSER_EVO_STATION",
        stop_name: "Evolutions Test Station",
        location_type: 1,
        stop_lat: Decimal.new("40.7100"),
        stop_lon: Decimal.new("-74.0060"),
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    {:ok, evo_level} =
      Gtfs.create_level(%{
        level_id: "BROWSER_EVO_L1",
        level_name: "Evolutions Concourse",
        level_index: 0.0,
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    # `create_stop_level/1` joins the station's own ids, not its external
    # identifiers, which is the form the other seeded stations use.
    {:ok, evo_stop_level} =
      Gtfs.create_stop_level(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_stop(%{
        stop_id: "BROWSER_EVO_BOARDING",
        stop_name: "Platform 1 boarding area",
        location_type: 4,
        parent_station: evo_station.stop_id,
        level_id: evo_level.level_id,
        diagram_coordinate: %{"x" => 86, "y" => 66},
        organization_id: org.id,
        gtfs_version_id: diagram_version.id
      })

    # A slash and spaces in one pathway_id, so a `?pathway=` link has to be
    # encoded and decoded exactly rather than read as a path segment.
    {:ok, _evo_walkway} =
      Gtfs.create_pathway(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_stop(%{
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
      Gtfs.create_pathway(%{
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
      Gtfs.create_stop(%{
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
        "2 closures on CAL_DAILY, plus empty and no-pathway stations"
    )

    # The published version that exists precisely because it has no calendars.
    # A station with one pathway there renders the view's no-native-calendars
    # state, which needs a station inside a calendar-less version.
    {:ok, _evo_nocal_station} =
      Gtfs.create_stop(%{
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
      Gtfs.create_pathway(%{
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
          Gtfs.create_stop(%{
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
      Gtfs.create_route(%{
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
      Gtfs.create_trip(%{
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
        Gtfs.create_stop_time(%{
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
        Gtfs.create_trip(%{
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
      Gtfs.create_trip(%{
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
        Gtfs.create_agency(%{
          organization_id: org.id,
          gtfs_version_id: agencies_version.id,
          agency_id: agency_id,
          agency_name: name,
          agency_url: "https://#{host}",
          agency_timezone: "America/New_York"
        })

      for index <- 1..route_count//1 do
        {:ok, _route} =
          Gtfs.create_route(%{
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
        Gtfs.create_agency(%{
          organization_id: org.id,
          gtfs_version_id: mixed_timezone_version.id,
          agency_id: agency_id,
          agency_name: name,
          agency_url: "https://#{host}",
          agency_timezone: timezone
        })

      {:ok, _route} =
        Gtfs.create_route(%{
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
        Gtfs.create_agency(%{
          organization_id: org.id,
          gtfs_version_id: agency_delete_version.id,
          agency_id: agency_id,
          agency_name: name,
          agency_url: "https://#{host}",
          agency_timezone: "America/New_York"
        })

      for index <- 1..route_count//1 do
        {:ok, _route} =
          Gtfs.create_route(%{
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
        Gtfs.create_route(%{
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
      Organizations.create_organization(%{name: "Home Planner Org", alias: "home-planner-org"})

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
      Organizations.create_organization(%{
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
      Gtfs.create_stop_level(%{
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
    {:ok, _home_editing_status} =
      Gtfs.set_station_editing_status(
        home_pathways_org.id,
        home_pathways_version.id,
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
      Gtfs.create_route(%{
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
        Gtfs.create_stop(%{
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
      Gtfs.create_trip(%{
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

  {:error, changeset} ->
    raise "Browser seed failed: #{inspect(changeset.errors)}"
end

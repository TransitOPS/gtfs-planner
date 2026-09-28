# Creates deterministic browser-test users for Playwright E2E tests.
# This script runs after `MIX_ENV=test mix ecto.reset`, so the database
# is empty and idempotency is unneeded.
#
# User 1 (admin): browser-test@gtfs-planner.test — used by overlays.spec.js
# User 2 (editor): diagram-test@gtfs-planner.test — used by diagram_keyboard.spec.js
# User 3 (org admin): admin-contracts@gtfs-planner.test — used by
#   admin_design_contracts.spec.js, together with its own "Admin Contracts Org"
#   and its deterministic active/deactivated/pending/multi-role/long-email members.
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
alias GtfsPlanner.Gtfs.DiagramStorage
alias GtfsPlanner.Gtfs.Export.ArtifactStorage
alias GtfsPlanner.Gtfs.ExportRuns
alias GtfsPlanner.Gtfs.FareAttribute
alias GtfsPlanner.Gtfs.FeedInfo
alias GtfsPlanner.Gtfs.FloorplanTransform
alias GtfsPlanner.Gtfs.Import.ChangeRuns
alias GtfsPlanner.Organizations
alias GtfsPlanner.Repo
alias GtfsPlanner.Validations.{ValidationRun, WalkabilityTest, WalkabilityTestRunResult}
alias GtfsPlanner.Versions

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
        browser_export_artifact
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
        result_json: %{
          "report_version" => 1,
          "outcome" => "passed",
          "metadata" => %{"station_stop_id" => station.stop_id},
          "topology" => %{
            "entrance_count" => 1,
            "platform_count" => 2,
            "pathway_count" => 1,
            "level_count" => 1
          },
          "pairs" => [
            %{
              "index" => 0,
              "mode" => "walking",
              "outcome" => "reachable",
              "from_stop_id" => browser_child_c.stop_id,
              "to_stop_id" => browser_child_a.stop_id,
              "duration_seconds" => 45.0,
              "distance_meters" => 12.5,
              "step_count" => 1
            }
          ],
          "diagnostics" => []
        }
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
        {:ok, stop} =
          Gtfs.create_stop(%{
            stop_id: "BROWSER_PATTERN_STOP_#{index}",
            stop_name: "Pattern Stop #{index}",
            location_type: 0,
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
          direction_id: 0
        })

      GtfsPlanner.GtfsFixtures.trip_pattern_metadata_fixture(trip, %{
        route_pattern_id: "BROWSER-P1",
        timed_pattern_id: outbound_timing.id,
        pattern_derivation_state: "linked"
      })
    end)

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
    custom_timing = timing_fixture.(custom_pattern, "All day", custom_occurrences)

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
    # seed password is invalid until the next `mise run prepare:browser` reset.
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
        current_export_artifact
      )

    IO.puts("Browser seed: routes-only version #{routes_only_version.id} with ready export")

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

    IO.puts("Browser seed: restored Browser E2E Version as the latest default")

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

  {:error, changeset} ->
    raise "Browser seed failed: #{inspect(changeset.errors)}"
end

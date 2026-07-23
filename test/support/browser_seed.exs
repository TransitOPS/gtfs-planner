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
alias GtfsPlanner.Gtfs.Import.ChangeRuns
alias GtfsPlanner.Organizations
alias GtfsPlanner.Repo
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
    # publication-scoped namespace. Store a tiny valid raster at the exact
    # filename referenced above so browser tests exercise the real canvas,
    # upload replacement, and map image loading paths.
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
        one_pixel_png
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

    IO.puts("Browser seed: restored Browser E2E Version as the latest default")

  {:error, changeset} ->
    raise "Browser seed failed: #{inspect(changeset.errors)}"
end

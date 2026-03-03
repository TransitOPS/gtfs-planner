defmodule GtfsPlannerWeb.Gtfs.ValidationResultLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Validations

  describe "ValidationResultLive" do
    setup do
      organization = organization_fixture()
      user = user_fixture()

      # Create user membership in organization with GTFS editor role
      Accounts.create_user_org_membership(%{
        user_id: user.id,
        organization_id: organization.id,
        roles: ["pathways_studio_editor"]
      })

      gtfs_version = gtfs_version_fixture(organization.id)

      %{user: user, organization: organization, gtfs_version: gtfs_version}
    end

    test "displays summary counts for completed validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a completed validation run
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 5,
          warnings: 10,
          infos: 3
        },
        notices: [
          %{
            "code" => "missing_required_field",
            "severity" => "error",
            "totalNotices" => 5,
            "notices" => [
              %{
                "filename" => "stops.txt",
                "csvRowNumber" => 10,
                "csvFieldName" => "stop_name",
                "message" => "Missing required field"
              }
            ]
          }
        ],
        duration_ms: 1500
      }

      {:ok, run} = Validations.mark_completed(run, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display summary counts
      assert html =~ "5"
      assert html =~ "10"
      assert html =~ "3"
      assert html =~ "Errors"
      assert html =~ "Warnings"
      assert html =~ "Info"

      # Should display status badge
      assert html =~ "COMPLETED"
    end

    test "displays error details for failed validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a failed validation run
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      error_reason = %RuntimeError{message: "Validation process crashed"}
      {:ok, run} = Validations.mark_failed(run, error_reason)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display failed status
      assert html =~ "FAILED"
      assert html =~ "Validation Failed"

      # Should display error details
      assert html =~ "RuntimeError"
    end

    test "renders build diagnostics and excerpt for failed pathways run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "validation-result-build-log-#{System.unique_integer([:positive])}"
        )

      build_log_path = Path.join(temp_dir, "build.log")
      File.mkdir_p!(temp_dir)

      File.write!(
        build_log_path,
        """
        INFO graph build started
        ERROR Graph build failed
        ERROR Failed to load pathways.txt due to malformed csv row
        java.lang.NullPointerException
        java.lang.IllegalStateException: invalid stop linkage
        Caused by: missing parent_station
        """
      )

      on_exit(fn ->
        File.rm_rf(temp_dir)
      end)

      {:ok, run} =
        Validations.mark_pathways_failed(run, %{
          reason: :otp_runtime_failed,
          issues: [
            %{
              code: :build_failed,
              details: %{
                reason_code: :build_command_failed,
                exit_status: 255,
                build_log_path: build_log_path
              }
            }
          ]
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert html =~ "FAILED"
      assert has_element?(view, "#pathways-failure-title")
      assert has_element?(view, "#pathways-failure-summary")
      assert has_element?(view, "#pathways-failure-status-message")
      assert has_element?(view, "#pathways-failure-checks")
      assert has_element?(view, "#pathways-failure-diagnostics")
      assert html =~ "Exit status:"
      assert html =~ "255"
      assert html =~ "Build log path:"
      assert html =~ build_log_path
      assert html =~ "Build log excerpt:"
      assert html =~ "ERROR Graph build failed"
      assert html =~ "Caused by: missing parent_station"
      assert html =~ "Likely GTFS source:"
      assert html =~ "Issue appears to come from pathways.txt."
      assert html =~ "Likely cause:"

      assert html =~
               "NullPointerException often indicates a child stop is missing a valid parent_station assignment."

      assert has_element?(view, "#otp-data-requirements-summary")
    end

    test "renders structured preflight blocking and warning issues for failed pathways run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      {:ok, run} =
        Validations.mark_pathways_failed(run, %{
          reason: :pathways_export_prep_failed,
          details: %{
            blocking_errors: [
              %{
                code: :boarding_area_parent_station_missing,
                severity: :blocking,
                message: "Boarding area ba-1 is missing parent_station in stops.txt.",
                context: %{file: "stops.txt", field: "parent_station", stop_id: "ba-1"}
              }
            ],
            warnings: [
              %{
                code: :pathway_endpoint_stop_not_found,
                severity: :warning,
                message: "Pathway p-1 references unknown to_stop_id S-404 in pathways.txt.",
                context: %{file: "pathways.txt", field: "to_stop_id", pathway_id: "p-1"}
              }
            ]
          }
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-failure-title")
      assert has_element?(view, "#pathways-failure-checks")
      refute has_element?(view, "#pathways-failure-blocking-issues")
      assert has_element?(view, "#pathways-failure-summary")
      assert has_element?(view, "#pathways-preflight-issues")
      assert has_element?(view, "#pathways-preflight-blocking-errors")
      assert has_element?(view, "#pathways-preflight-warnings")
      assert html =~ "Boarding area ba-1 is missing parent_station in stops.txt."
      assert html =~ "Pathway p-1 references unknown to_stop_id S-404 in pathways.txt."
      assert html =~ "stops.txt · parent_station · ba-1"
      assert html =~ "pathways.txt · to_stop_id · p-1"
    end

    test "renders preflight blocking and warning sections when issues are only in root payload",
         %{
           conn: conn,
           user: user,
           organization: organization,
           gtfs_version: version
         } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      {:ok, run} =
        Validations.mark_pathways_failed(run, %{
          reason: :pathways_export_prep_failed,
          issues: [
            %{
              code: :station_stop_lon_sign_mismatch,
              severity: :blocking,
              message:
                "Station st-1 has stop_lon with wrong sign for configured region in stops.txt.",
              context: %{file: "stops.txt", field: "stop_lon", stop_id: "st-1"}
            },
            %{
              code: :pathway_endpoint_stop_not_found,
              severity: :warning,
              message: "Pathway p-2 references unknown to_stop_id S-999 in pathways.txt.",
              context: %{file: "pathways.txt", field: "to_stop_id", pathway_id: "p-2"}
            }
          ]
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-failure-title")
      assert has_element?(view, "#pathways-failure-checks")
      assert has_element?(view, "#pathways-failure-blocking-issues")
      assert html =~ "Pathways validation internal failure"
      assert has_element?(view, "#pathways-preflight-blocking-errors")
      assert has_element?(view, "#pathways-preflight-warnings")

      assert html =~
               "Station st-1 has stop_lon with wrong sign for configured region in stops.txt."

      assert html =~ "Pathway p-2 references unknown to_stop_id S-999 in pathways.txt."
      assert html =~ "stops.txt · stop_lon · st-1"
      assert html =~ "pathways.txt · to_stop_id · p-2"
    end

    test "displays loading state for started validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a started validation run (not yet completed)
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display loading state
      assert html =~ "STARTED"
      assert html =~ "Validation starting..."
    end

    test "displays loading state for running validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a running validation run
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")
      {:ok, run} = Validations.mark_running(run)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display loading state
      assert html =~ "RUNNING"
      assert html =~ "Validation in progress..."
    end

    test "displays notice details when validation has notices", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a completed validation run with notices
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 1,
          warnings: 0,
          infos: 0
        },
        notices: [
          %{
            "code" => "missing_required_field",
            "severity" => "error",
            "totalNotices" => 1,
            "notices" => [
              %{
                "filename" => "stops.txt",
                "csvRowNumber" => 10,
                "csvFieldName" => "stop_name",
                "message" => "Missing required field"
              }
            ]
          }
        ],
        duration_ms: 1500
      }

      {:ok, run} = Validations.mark_completed(run, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display notice code
      assert has_element?(view, "span.font-mono", "missing_required_field")

      # Should display severity badge
      assert has_element?(view, "div.badge-error", "ERROR")
    end

    test "displays no issues message when validation has no notices", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a completed validation run with no notices
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{
          errors: 0,
          warnings: 0,
          infos: 0
        },
        notices: [],
        duration_ms: 1500
      }

      {:ok, run} = Validations.mark_completed(run, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, _view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display success message
      assert html =~ "No validation issues found!"
      assert html =~ "Your GTFS data passed all checks."
    end

    test "renders pathways report summary for pathways run type", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test_1 =
        walkability_test_fixture(%{organization_id: organization.id, gtfs_version_id: version.id})

      walkability_test_2 =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: "stop-2",
          address: "456 Oak St"
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 2, selected_count: 2, malformed_count: 0},
        selected_test_case_ids: [walkability_test_1.id, walkability_test_2.id],
        summary: %{total: 2, passed: 1, failed: 1, query_failure: 1, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test_1.id,
            status: :passed,
            route_output: %{
              route_exists: true,
              duration_seconds: 180.0,
              distance_meters: 320.0,
              step_count: 6,
              leg_count: 2,
              itinerary_start_time: ~U[2026-01-01 12:00:00.000000Z],
              itinerary_end_time: ~U[2026-01-01 12:03:00.000000Z],
              itinerary_steps: %{
                legs: [
                  %{
                    index: 0,
                    mode: "WALK",
                    from_name: "Origin",
                    to_name: "Transfer",
                    steps: [
                      %{
                        index: 0,
                        street_name: "Main St",
                        distance_meters: 120.5,
                        absolute_direction: "NORTH",
                        relative_direction: "DEPART"
                      }
                    ]
                  },
                  %{
                    index: 1,
                    mode: "WALK",
                    from_name: "Transfer",
                    to_name: "Destination",
                    steps: [
                      %{
                        index: 0,
                        street_name: "Oak Ave",
                        distance_meters: 199.5,
                        absolute_direction: "EAST",
                        relative_direction: "RIGHT"
                      }
                    ]
                  }
                ]
              }
            },
            wheelchair_output: %{
              route_exists: true,
              duration_seconds: 200.0,
              distance_meters: 360.0
            }
          },
          %{
            test_case_id: walkability_test_2.id,
            status: :failed,
            failure_category: :query_failure,
            details: %{reason: :non_2xx_response, status: 500}
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 250)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-criteria-comparison-overview")
      assert has_element?(view, "#pathways-trip-visualization-overview")
      assert render(view) =~ "Issue"
      assert has_element?(view, "#pathways-case-results")
      assert render(view) =~ "Origin"
      assert render(view) =~ "Destination"
      assert render(view) =~ "Start Time"
      assert render(view) =~ "End Time"
      assert has_element?(view, "#pathways-trip-overview-total-tests-value", "2")
      assert has_element?(view, "#pathways-trip-overview-pass-count-value", "1")
      assert has_element?(view, "#pathways-trip-overview-fail-count-value", "1")
      assert has_element?(view, "#pathways-trip-overview-warning-count-value", "0")
      assert has_element?(view, "#pathways-trip-overview-duration-available", "1")
      assert has_element?(view, "#pathways-trip-overview-duration-unavailable", "1")
      assert has_element?(view, "#pathways-trip-overview-duration-availability-rate", "50.0%")
      assert has_element?(view, "#pathways-trip-overview-duration-min", "180.0")
      assert has_element?(view, "#pathways-trip-overview-duration-max", "180.0")
      assert has_element?(view, "#pathways-trip-overview-duration-average", "180.0")
      assert has_element?(view, "#pathways-trip-overview-distance-available", "1")
      assert has_element?(view, "#pathways-trip-overview-distance-unavailable", "1")
      assert has_element?(view, "#pathways-trip-overview-distance-availability-rate", "50.0%")
      assert has_element?(view, "#pathways-trip-overview-distance-min", "320.0")
      assert has_element?(view, "#pathways-trip-overview-distance-max", "320.0")
      assert has_element?(view, "#pathways-trip-overview-distance-average", "320.0")
      assert render(view) =~ "Pass Rate"
      assert render(view) =~ "50.0%"
      assert has_element?(view, "#pathways-case-row-0", walkability_test_1.id)
      assert has_element?(view, "#pathways-case-row-1", walkability_test_2.id)
      assert render(view |> element("#pathways-case-row-0")) =~ "2026-01-01 07:00:00 AM"
      assert render(view |> element("#pathways-case-row-0")) =~ "2026-01-01 07:03:00 AM"
      assert render(view |> element("#pathways-case-row-0")) =~ walkability_test_1.address
      assert render(view |> element("#pathways-case-row-0")) =~ walkability_test_1.stop_id
      assert render(view |> element("#pathways-case-row-1")) =~ "456 Oak St"
      assert render(view |> element("#pathways-case-row-1")) =~ "stop-2"

      assert render(view |> element("#pathways-case-row-1")) =~
               "Query failed: OTP returned HTTP 500"

      assert has_element?(
               view,
               "#pathways-case-itinerary-details-0 summary",
               "Step-by-step itinerary"
             )

      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Step")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Leg Mode")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Street")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Relative")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Absolute")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Distance (m)")

      assert render(view |> element("#pathways-case-itinerary-step-0-0-0")) =~ "Main St"
      assert render(view |> element("#pathways-case-itinerary-step-0-1-0")) =~ "Oak Ave"

      rendered_html = render(view)

      {first_step_position, _} =
        :binary.match(rendered_html, "pathways-case-itinerary-step-0-0-0")

      {second_step_position, _} =
        :binary.match(rendered_html, "pathways-case-itinerary-step-0-1-0")

      assert first_step_position < second_step_position

      assert has_element?(
               view,
               "#pathways-case-itinerary-empty-1",
               "No itinerary steps available."
             )
    end

    test "renders criteria checks with pass and fail statuses for scoring failures", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true,
          expected_min_duration_seconds: 100,
          expected_max_duration_seconds: 300,
          expected_min_distance_meters: 50,
          expected_max_distance_meters: 500,
          expected_wheelchair_accessible: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 0, failed: 1, query_failure: 0, scoring_failure: 1},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :failed,
            failure_category: :scoring_failure,
            route_output: %{
              route_exists: false,
              duration_seconds: 400.0,
              distance_meters: 200.0
            },
            wheelchair_output: %{
              route_exists: false,
              duration_seconds: 430.0,
              distance_meters: 240.0
            },
            details: %{
              mismatches: [
                %{kind: :expected_traversable, expected: true, actual: false},
                %{kind: :expected_max_duration_seconds, expected: 300, actual: 400.0},
                %{kind: :expected_wheelchair_accessible, expected: true, actual: false}
              ]
            }
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 25)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-criteria-0")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Criterion")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Expected")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Actual")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Status")

      assert has_element?(view, "#pathways-case-criteria-check-0-expected_traversable", "FAIL")

      assert has_element?(view, "#pathways-case-criteria-check-0-duration_seconds_range", "FAIL")

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-duration_seconds_range",
               "100 - 300"
             )

      assert has_element?(view, "#pathways-case-criteria-check-0-distance_meters_range", "PASS")

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-distance_meters_range",
               "50 - 500"
             )

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-expected_wheelchair_accessible",
               "FAIL"
             )

      assert has_element?(view, "#pathways-case-row-0 .badge-error", "FAILED")
      assert render(view |> element("#pathways-case-row-0")) =~ "Traversability check failed"
    end

    test "renders criteria aggregation overview values for non-empty case results", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test_1 =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true,
          expected_min_duration_seconds: 100,
          expected_max_duration_seconds: 300,
          expected_min_distance_meters: 50,
          expected_max_distance_meters: 500,
          expected_wheelchair_accessible: true
        })

      walkability_test_2 =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: "stop-agg-2",
          address: "456 Aggregate St",
          expected_traversable: true,
          expected_min_duration_seconds: 100,
          expected_max_duration_seconds: 300,
          expected_min_distance_meters: 50,
          expected_max_distance_meters: 500,
          expected_wheelchair_accessible: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 2, selected_count: 2, malformed_count: 0},
        selected_test_case_ids: [walkability_test_1.id, walkability_test_2.id],
        summary: %{total: 2, passed: 1, failed: 1, query_failure: 1, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test_1.id,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 180.0, distance_meters: 320.0},
            wheelchair_output: %{
              route_exists: true,
              duration_seconds: 200.0,
              distance_meters: 360.0
            }
          },
          %{
            test_case_id: walkability_test_2.id,
            status: :failed,
            failure_category: :query_failure,
            details: %{reason: :timeout}
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 35)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-criteria-comparison-overview")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-label-expected_traversable",
               "Traversable"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-expected_traversable",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-evaluated-expected_traversable",
               "1"
             )

      assert has_element?(view, "#pathways-criteria-comparison-pass-expected_traversable", "1")
      assert has_element?(view, "#pathways-criteria-comparison-fail-expected_traversable", "0")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-expected_traversable",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-expected_traversable",
               "100.0%"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-duration_seconds_range",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-duration_seconds_range",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-duration_seconds_range",
               "100.0%"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-distance_meters_range",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-distance_meters_range",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-distance_meters_range",
               "100.0%"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-expected_wheelchair_accessible",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-expected_wheelchair_accessible",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-expected_wheelchair_accessible",
               "100.0%"
             )
    end

    test "renders pathways overview sections for completed run with empty case results", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 0, selected_count: 0, malformed_count: 0},
        selected_test_case_ids: [],
        summary: %{total: 0, passed: 0, failed: 0, query_failure: 0, scoring_failure: 0},
        cases: []
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 5)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-criteria-comparison-overview")
      assert has_element?(view, "#pathways-trip-visualization-overview")
      assert has_element?(view, "#pathways-trip-overview-total-tests-value", "0")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-expected_traversable",
               "0"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-evaluated-expected_traversable",
               "0"
             )

      assert has_element?(view, "#pathways-criteria-comparison-pass-expected_traversable", "0")
      assert has_element?(view, "#pathways-criteria-comparison-fail-expected_traversable", "0")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-expected_traversable",
               "0"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-expected_traversable",
               "0.0%"
             )

      assert has_element?(view, "#pathways-trip-overview-duration-available", "0")
      assert has_element?(view, "#pathways-trip-overview-distance-available", "0")
      assert has_element?(view, "#pathways-trip-overview-duration-min", "-")
      assert has_element?(view, "#pathways-trip-overview-distance-min", "-")
      refute has_element?(view, "#pathways-case-row-0")
    end

    test "renders per-test status as FAILED when traversable fails", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 0, failed: 1, query_failure: 0, scoring_failure: 1},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :failed,
            failure_category: :scoring_failure,
            route_output: %{route_exists: false, duration_seconds: 120.0, distance_meters: 150.0},
            details: %{
              mismatches: [
                %{kind: :expected_traversable, expected: true, actual: false}
              ]
            }
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-row-0 .badge-error", "FAILED")
    end

    test "renders per-test status as PASS when no criteria fail", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 1, failed: 0, query_failure: 0, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 120.0, distance_meters: 150.0},
            details: %{mismatches: []}
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-row-0 .badge-success", "PASS")
      assert render(view |> element("#pathways-case-row-0")) =~ "All criteria passed"
    end

    test "renders per-test status as WARNING when traversable passes but other criteria fail", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true,
          expected_max_duration_seconds: 300
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 0, failed: 1, query_failure: 0, scoring_failure: 1},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :failed,
            failure_category: :scoring_failure,
            route_output: %{route_exists: true, duration_seconds: 400.0, distance_meters: 150.0},
            details: %{
              mismatches: [
                %{kind: :expected_max_duration_seconds, expected: 300, actual: 400.0}
              ]
            }
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-row-0 .badge-warning", "WARNING")
      assert render(view |> element("#pathways-case-row-0")) =~ "Duration outside expected range"
    end

    test "renders criteria checks with pass and fail statuses for scoring failures", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true,
          expected_min_duration_seconds: 100,
          expected_max_duration_seconds: 300,
          expected_min_distance_meters: 50,
          expected_max_distance_meters: 500,
          expected_wheelchair_accessible: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 0, failed: 1, query_failure: 0, scoring_failure: 1},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :failed,
            failure_category: :scoring_failure,
            route_output: %{
              route_exists: false,
              duration_seconds: 400.0,
              distance_meters: 200.0
            },
            wheelchair_output: %{
              route_exists: false,
              duration_seconds: 430.0,
              distance_meters: 240.0
            },
            details: %{
              mismatches: [
                %{kind: :expected_traversable, expected: true, actual: false},
                %{kind: :expected_max_duration_seconds, expected: 300, actual: 400.0},
                %{kind: :expected_wheelchair_accessible, expected: true, actual: false}
              ]
            }
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 25)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-criteria-0")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Criterion")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Expected")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Actual")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Status")

      assert has_element?(view, "#pathways-case-criteria-check-0-expected_traversable", "FAIL")

      assert has_element?(view, "#pathways-case-criteria-check-0-duration_seconds_range", "FAIL")

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-duration_seconds_range",
               "100 - 300"
             )

      assert has_element?(view, "#pathways-case-criteria-check-0-distance_meters_range", "PASS")

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-distance_meters_range",
               "50 - 500"
             )

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-expected_wheelchair_accessible",
               "FAIL"
             )

      assert has_element?(view, "#pathways-case-row-0 .badge-error", "FAILED")
      assert render(view |> element("#pathways-case-row-0")) =~ "Traversability check failed"
    end

    test "renders criteria aggregation overview values for non-empty case results", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test_1 =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true,
          expected_min_duration_seconds: 100,
          expected_max_duration_seconds: 300,
          expected_min_distance_meters: 50,
          expected_max_distance_meters: 500,
          expected_wheelchair_accessible: true
        })

      walkability_test_2 =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          stop_id: "stop-agg-2",
          address: "456 Aggregate St",
          expected_traversable: true,
          expected_min_duration_seconds: 100,
          expected_max_duration_seconds: 300,
          expected_min_distance_meters: 50,
          expected_max_distance_meters: 500,
          expected_wheelchair_accessible: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 2, selected_count: 2, malformed_count: 0},
        selected_test_case_ids: [walkability_test_1.id, walkability_test_2.id],
        summary: %{total: 2, passed: 1, failed: 1, query_failure: 1, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test_1.id,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 180.0, distance_meters: 320.0},
            wheelchair_output: %{
              route_exists: true,
              duration_seconds: 200.0,
              distance_meters: 360.0
            }
          },
          %{
            test_case_id: walkability_test_2.id,
            status: :failed,
            failure_category: :query_failure,
            details: %{reason: :timeout}
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 35)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-criteria-comparison-overview")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-label-expected_traversable",
               "Traversable"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-expected_traversable",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-evaluated-expected_traversable",
               "1"
             )

      assert has_element?(view, "#pathways-criteria-comparison-pass-expected_traversable", "1")
      assert has_element?(view, "#pathways-criteria-comparison-fail-expected_traversable", "0")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-expected_traversable",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-expected_traversable",
               "100.0%"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-duration_seconds_range",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-duration_seconds_range",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-duration_seconds_range",
               "100.0%"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-distance_meters_range",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-distance_meters_range",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-distance_meters_range",
               "100.0%"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-expected_wheelchair_accessible",
               "2"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-expected_wheelchair_accessible",
               "1"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-expected_wheelchair_accessible",
               "100.0%"
             )
    end

    test "renders pathways overview sections for completed run with empty case results", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 0, selected_count: 0, malformed_count: 0},
        selected_test_case_ids: [],
        summary: %{total: 0, passed: 0, failed: 0, query_failure: 0, scoring_failure: 0},
        cases: []
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 5)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-criteria-comparison-overview")
      assert has_element?(view, "#pathways-trip-visualization-overview")
      assert has_element?(view, "#pathways-trip-overview-total-tests-value", "0")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-configured-expected_traversable",
               "0"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-evaluated-expected_traversable",
               "0"
             )

      assert has_element?(view, "#pathways-criteria-comparison-pass-expected_traversable", "0")
      assert has_element?(view, "#pathways-criteria-comparison-fail-expected_traversable", "0")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-not-evaluated-expected_traversable",
               "0"
             )

      assert has_element?(
               view,
               "#pathways-criteria-comparison-pass-rate-expected_traversable",
               "0.0%"
             )

      assert has_element?(view, "#pathways-trip-overview-duration-available", "0")
      assert has_element?(view, "#pathways-trip-overview-distance-available", "0")
      assert has_element?(view, "#pathways-trip-overview-duration-min", "-")
      assert has_element?(view, "#pathways-trip-overview-distance-min", "-")
      refute has_element?(view, "#pathways-case-row-0")
    end

    test "renders per-test status as FAILED when traversable fails", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 0, failed: 1, query_failure: 0, scoring_failure: 1},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :failed,
            failure_category: :scoring_failure,
            route_output: %{route_exists: false, duration_seconds: 120.0, distance_meters: 150.0},
            details: %{
              mismatches: [
                %{kind: :expected_traversable, expected: true, actual: false}
              ]
            }
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-row-0 .badge-error", "FAILED")
    end

    test "renders per-test status as PASS when no criteria fail", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 1, failed: 0, query_failure: 0, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 120.0, distance_meters: 150.0},
            details: %{mismatches: []}
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-row-0 .badge-success", "PASS")
      assert render(view |> element("#pathways-case-row-0")) =~ "All criteria passed"
    end

    test "renders per-test status as WARNING when traversable passes but other criteria fail", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{
          organization_id: organization.id,
          gtfs_version_id: version.id,
          expected_traversable: true,
          expected_max_duration_seconds: 300
        })

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 0, failed: 1, query_failure: 0, scoring_failure: 1},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :failed,
            failure_category: :scoring_failure,
            route_output: %{route_exists: true, duration_seconds: 400.0, distance_meters: 150.0},
            details: %{
              mismatches: [
                %{kind: :expected_max_duration_seconds, expected: 300, actual: 400.0}
              ]
            }
          }
        ]
      }

      {:ok, run} = Validations.mark_pathways_completed(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-row-0 .badge-warning", "WARNING")
      assert render(view |> element("#pathways-case-row-0")) =~ "Duration outside expected range"
    end

    test "poll refresh updates pathways run from running to completed", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      walkability_test =
        walkability_test_fixture(%{organization_id: organization.id, gtfs_version_id: version.id})

      {:ok, run} =
        Validations.create_validation_run(organization.id, version.id, "pathways_tests")

      {:ok, run} = Validations.mark_pathways_running(run)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "div.badge-info", "RUNNING")

      run_result = %{
        suite_meta: %{total_candidates: 1, selected_count: 1, malformed_count: 0},
        selected_test_case_ids: [walkability_test.id],
        summary: %{total: 1, passed: 1, failed: 0, query_failure: 0, scoring_failure: 0},
        cases: [
          %{
            test_case_id: walkability_test.id,
            status: :passed,
            route_output: %{route_exists: true, duration_seconds: 95.0, distance_meters: 140.0},
            wheelchair_output: %{
              route_exists: true,
              duration_seconds: 110.0,
              distance_meters: 160.0
            }
          }
        ]
      }

      {:ok, _updated_run} = Validations.mark_pathways_completed(run, run_result, 10)

      send(view.pid, {:poll_pathways_trip_test_status, run.id})

      assert has_element?(view, "div.badge-success.badge-outline", "COMPLETED")
      assert has_element?(view, "#pathways-case-row-0", walkability_test.id)
      refute render(view) =~ "Validation in progress..."
    end

    test "history drawer contains links to past validation runs", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create multiple validation runs
      {:ok, run1} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Process.sleep(10)

      {:ok, run2} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Process.sleep(10)

      {:ok, run3} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      # Mark them with different statuses
      result = %{
        summary: %{errors: 1, warnings: 2, infos: 3},
        notices: [],
        duration_ms: 1500
      }

      {:ok, _run1} = Validations.mark_completed(run1, result)
      {:ok, _run2} = Validations.mark_running(run2)
      # run3 remains in "started" status

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run3.id}")

      # Check that View History button exists
      assert has_element?(view, "label[for='validation-history-drawer']", "View History")

      # Check that history drawer contains past runs
      html = render(view)

      # Should contain the history drawer
      assert html =~ "Validation History"

      # Should contain status badges for each run
      assert html =~ "completed"
      assert html =~ "running"
      assert html =~ "started"
    end

    test "clicking history item navigates to that validation run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create two validation runs
      {:ok, run1} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      Process.sleep(10)

      {:ok, run2} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      result = %{
        summary: %{errors: 1, warnings: 2, infos: 3},
        notices: [],
        duration_ms: 1500
      }

      {:ok, run1} = Validations.mark_completed(run1, result)
      {:ok, _run2} = Validations.mark_completed(run2, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run2.id}")

      # Should have links to both runs in the history
      assert has_element?(view, "a[href='/gtfs/#{version.id}/validation/#{run1.id}']")
      assert has_element?(view, "a[href='/gtfs/#{version.id}/validation/#{run2.id}']")
    end

    test "shows Back to Export button", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should have Back to Export button
      assert has_element?(view, "a[href='/gtfs/#{version.id}/export']", "Back to Export")
    end

    test "denies access to validation run from different organization", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      # Create a different organization and validation run
      other_organization = organization_fixture()
      other_version = gtfs_version_fixture(other_organization.id)

      {:ok, other_run} =
        Validations.create_validation_run(
          other_organization.id,
          other_version.id,
          "mobility_data"
        )

      # Try to access the other organization's validation run
      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               live(conn, "/gtfs/#{version.id}/validation/#{other_run.id}")

      assert path == "/gtfs/#{version.id}/export"
      assert flash["error"] == "Unauthorized access to validation run"
    end
  end
end

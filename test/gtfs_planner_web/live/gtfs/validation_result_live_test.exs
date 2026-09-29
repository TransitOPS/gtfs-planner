defmodule GtfsPlannerWeb.Gtfs.ValidationResultLiveTest do
  use GtfsPlannerWeb.ConnCase

  import Phoenix.LiveViewTest
  import GtfsPlanner.AccountsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.ValidationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Accounts
  alias GtfsPlanner.Repo
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.{ValidationRun, WalkabilityTestRunResult}

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
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # The three severities read as problems, suggestions and notes
      assert has_element?(view, "#validation-count-errors", "Problems")
      assert has_element?(view, "#validation-count-errors-value", "5")
      assert has_element?(view, "#validation-count-warnings", "Suggestions")
      assert has_element?(view, "#validation-count-warnings-value", "10")
      assert has_element?(view, "#validation-count-infos", "Notes")
      assert has_element?(view, "#validation-count-infos-value", "3")

      # The headline carries the error tone and states the count
      assert has_element?(view, "#validation-summary [data-tone='error']")
      assert has_element?(view, "#validation-summary-title", "5 problems to fix.")

      # The run's lifecycle status stays available under its details
      assert has_element?(view, "#validation-run-details", "Completed")
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
      {:ok, view, html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # A failed run says the feed wasn't judged instead of posing as a result
      assert html =~ "The check stopped before it could judge your feed."
      assert has_element?(view, "#validation-failure[role='alert']")

      # The stored error is kept under the technical details
      assert has_element?(
               view,
               "#validation-failure-details #validation-failure-raw",
               "RuntimeError"
             )

      assert has_element?(view, "#validation-failure-details", run.id)
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
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display loading state
      assert has_element?(view, "#validation-progress-title", "Starting the check.")
      assert has_element?(view, "#validation-progress [role='progressbar']")
      assert has_element?(view, "#validation-progress", "reload it")
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
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display loading state
      assert has_element?(view, "#validation-progress-title", "Checking your feed.")
      assert has_element?(view, "#validation-progress [role='progressbar']")
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
                "totalNotices" => 1,
                "sampleNotices" => [
                  %{
                    "filename" => "stops.txt",
                    "csvRowNumber" => 10,
                    "csvFieldName" => "stop_name",
                    "message" => "Missing required field"
                  }
                ]
              }
            ]
          }
        ],
        duration_ms: 1500
      }

      {:ok, run} = Validations.mark_completed(run, result)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # The finding sits in the Problems section, which starts open
      assert has_element?(view, "#findings-error #finding-missing_required_field[open]")

      # The validator code stays available as a technical line
      assert has_element?(view, "#finding-code-missing_required_field", "missing_required_field")

      # Its example rows keep the file, line, column and message
      assert has_element?(view, "#finding-samples-missing_required_field td", "stops.txt")
      assert has_element?(view, "#finding-samples-missing_required_field td", "stop_name")

      assert has_element?(
               view,
               "#finding-samples-missing_required_field td",
               "Missing required field"
             )
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
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      # Should display success message
      assert has_element?(view, "#validation-summary [data-tone='success']")
      assert has_element?(view, "#validation-summary-title", "No validation issues found!")
      assert has_element?(view, "#validation-summary", "Your GTFS data passed all checks.")
      refute has_element?(view, "#validation-findings section")
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

      run = persist_legacy_pathways_run(run, run_result, 250)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-criteria-comparison-overview")
      assert has_element?(view, "#pathways-trip-visualization-overview")
      assert has_element?(view, "#pathways-case-results-title", "Each walk test")
      assert has_element?(view, "#pathways-trip-overview-total-tests-value", "2")
      assert has_element?(view, "#pathways-trip-overview-pass-count-value", "1")
      assert has_element?(view, "#pathways-trip-overview-fail-count-value", "1")
      assert has_element?(view, "#pathways-trip-overview-warning-count-value", "0")
      assert has_element?(view, "#pathways-trip-overview-duration-available", "1")
      assert has_element?(view, "#pathways-trip-overview-duration-unavailable", "1")
      assert has_element?(view, "#pathways-trip-overview-duration-availability-rate", "50.0%")
      assert has_element?(view, "#pathways-trip-overview-duration-min", "3 min 0 s")
      assert has_element?(view, "#pathways-trip-overview-duration-max", "3 min 0 s")
      assert has_element?(view, "#pathways-trip-overview-duration-average", "3 min 0 s")
      assert has_element?(view, "#pathways-trip-overview-distance-available", "1")
      assert has_element?(view, "#pathways-trip-overview-distance-unavailable", "1")
      assert has_element?(view, "#pathways-trip-overview-distance-availability-rate", "50.0%")
      assert has_element?(view, "#pathways-trip-overview-distance-min", "320.0 m")
      assert has_element?(view, "#pathways-trip-overview-distance-max", "320.0 m")
      assert has_element?(view, "#pathways-trip-overview-distance-average", "320.0 m")
      assert render(view) =~ "Pass rate"
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
               "#pathways-case-itinerary-heading-0",
               "Walking directions"
             )

      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Step")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Mode")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Street")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Turn")
      assert has_element?(view, "#pathways-case-itinerary-table-0 th", "Heading")
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

      run = persist_legacy_pathways_run(run, run_result, 25)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-case-criteria-0")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Criterion")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Expected")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Actual")
      assert has_element?(view, "#pathways-case-criteria-table-0 th", "Status")

      assert has_element?(view, "#pathways-case-criteria-check-0-expected_traversable", "Failed")

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-duration_seconds_range",
               "Failed"
             )

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-duration_seconds_range",
               "100 - 300"
             )

      assert has_element?(view, "#pathways-case-criteria-check-0-distance_meters_range", "Passed")

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-distance_meters_range",
               "50 - 500"
             )

      assert has_element?(
               view,
               "#pathways-case-criteria-check-0-expected_wheelchair_accessible",
               "Failed"
             )

      assert has_element?(
               view,
               "#pathways-case-row-0[data-result='failed'] [data-tone='error']",
               "Failed"
             )

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

      run = persist_legacy_pathways_run(run, run_result, 35)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-criteria-comparison-overview")

      assert has_element?(
               view,
               "#pathways-criteria-comparison-label-expected_traversable",
               "Can be walked"
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

      run = persist_legacy_pathways_run(run, run_result, 5)

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
      refute has_element?(view, "#pathways-case-results")

      assert has_element?(
               view,
               "#pathways-trip-visualization-overview-title",
               "This run has no walk test results."
             )
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

      run = persist_legacy_pathways_run(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(
               view,
               "#pathways-case-row-0[data-result='failed'] [data-tone='error']",
               "Failed"
             )
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

      run = persist_legacy_pathways_run(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(
               view,
               "#pathways-case-row-0[data-result='pass'] [data-tone='success']",
               "Passed"
             )

      refute render(view |> element("#pathways-case-row-0")) =~ "Criteria checks failed"
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

      run = persist_legacy_pathways_run(run, run_result, 20)

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(
               view,
               "#pathways-case-row-0[data-result='warning'] [data-tone='warning']",
               "Needs review"
             )

      assert render(view |> element("#pathways-case-row-0")) =~ "Duration outside expected range"
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

      # Check that View history button exists
      assert has_element?(view, "button#open-history", "View history")

      # The drawer is closed until asked for
      assert has_element?(view, "#validation-history-overlay[data-open='false']")

      # Should contain the history drawer and a status for each run
      assert has_element?(view, "#validation-history-title", "Validation history")
      assert has_element?(view, "#validation-runs-list", "Completed")
      assert has_element?(view, "#validation-runs-list", "Running")
      assert has_element?(view, "#validation-runs-list", "Starting")

      # A completed run shows its counts in the plain severity words
      assert has_element?(view, "#validation-runs-list", "1 problem · 2 suggestions · 3 notes")
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

      # Should have Back to export link
      assert has_element?(
               view,
               "a#back-to-export[href='/gtfs/#{version.id}/export']",
               "Back to export"
             )
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

    test "denies access to a validation run from another version in the same organization", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      other_version = gtfs_version_fixture(organization.id)

      {:ok, other_run} =
        Validations.create_validation_run(organization.id, other_version.id, "mobility_data")

      conn = log_in_user(conn, user, organization: organization)

      assert {:error, {:live_redirect, %{to: path, flash: flash}}} =
               live(conn, "/gtfs/#{version.id}/validation/#{other_run.id}")

      assert path == "/gtfs/#{version.id}/export"
      assert flash["error"] == "Unauthorized access to validation run"
    end

    test "opens Problems and closes Suggestions and Notes on first load", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        completed_run(organization, version, [
          notice_group("stop_without_location", "error", 4),
          notice_group("stop_too_far_from_shape", "warning", 11),
          notice_group("unknown_column", "info", 2)
        ])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#findings-error #finding-stop_without_location[open]")
      assert has_element?(view, "#findings-warning #finding-stop_too_far_from_shape")
      refute has_element?(view, "#finding-stop_too_far_from_shape[open]")
      assert has_element?(view, "#findings-info #finding-unknown_column")
      refute has_element?(view, "#finding-unknown_column[open]")
    end

    test "names a finding by its humanized code and counts its occurrences", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        completed_run(organization, version, [
          notice_group("stop_without_location", "error", 4, [%{"filename" => "stops.txt"}]),
          notice_group("route_color_contrast", "warning", 1)
        ])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#finding-stop_without_location summary", "Stop without location")
      assert has_element?(view, "#finding-stop_without_location summary", "4 occurrences")
      assert has_element?(view, "#finding-stop_without_location summary", "stops.txt")
      assert has_element?(view, "#finding-route_color_contrast summary", "1 occurrence")
      refute has_element?(view, "#finding-route_color_contrast summary", "1 occurrences")
    end

    test "lists the finding with the most occurrences first inside a severity", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        completed_run(organization, version, [
          notice_group("few_places", "error", 2),
          notice_group("many_places", "error", 9)
        ])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      html = render(view)
      {many_position, _} = :binary.match(html, "finding-many_places")
      {few_position, _} = :binary.match(html, "finding-few_places")

      assert many_position < few_position
    end

    test "places upper-case validator severities in their sections", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        completed_run(organization, version, [
          notice_group("a_problem", "ERROR", 1),
          notice_group("a_suggestion", "WARNING", 1),
          notice_group("a_note", "INFO", 1)
        ])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#findings-error #finding-a_problem")
      assert has_element?(view, "#findings-warning #finding-a_suggestion")
      assert has_element?(view, "#findings-info #finding-a_note")
      refute has_element?(view, "#findings-other")
    end

    test "keeps a finding with an unrecognized severity under Other findings", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run = completed_run(organization, version, [notice_group("odd_finding", "critical", 1)])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#findings-other-title", "Other findings")
      assert has_element?(view, "#findings-other #finding-odd_finding")
    end

    test "leaves out a severity section that has no findings and never claims success", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        completed_run(
          organization,
          version,
          [
            notice_group("stop_too_far_from_shape", "warning", 3),
            notice_group("unknown_column", "info", 1)
          ],
          %{errors: 0, warnings: 2, infos: 1}
        )

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      refute has_element?(view, "#findings-error")

      assert has_element?(view, "#validation-summary [data-tone='warning']")

      assert has_element?(
               view,
               "#validation-summary-title",
               "No problems. 2 suggestions to review."
             )

      refute has_element?(view, "#validation-summary [data-tone='success']")
    end

    test "opens and closes one finding from its summary", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run = completed_run(organization, version, [notice_group("unknown_column", "info", 2)])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      view |> element("#finding-unknown_column summary") |> render_click()
      assert has_element?(view, "#finding-unknown_column[open]")

      view |> element("#finding-unknown_column summary") |> render_click()
      refute has_element?(view, "#finding-unknown_column[open]")
    end

    test "expands and collapses every finding in a section at once", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        completed_run(organization, version, [
          notice_group("first_suggestion", "warning", 3),
          notice_group("second_suggestion", "warning", 1)
        ])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#toggle-findings-warning", "Expand all")

      view |> element("#toggle-findings-warning") |> render_click()

      assert has_element?(view, "#finding-first_suggestion[open]")
      assert has_element?(view, "#finding-second_suggestion[open]")
      assert has_element?(view, "#toggle-findings-warning", "Collapse all")

      view |> element("#toggle-findings-warning") |> render_click()

      refute has_element?(view, "#finding-first_suggestion[open]")
      refute has_element?(view, "#finding-second_suggestion[open]")
      assert has_element?(view, "#toggle-findings-warning", "Expand all")
    end

    test "reports when the check ran and how long it took in UTC", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run = completed_run(organization, version, [], %{errors: 0, warnings: 0, infos: 0})

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#validation-run-meta", "Checked")
      assert has_element?(view, "#validation-run-meta", "UTC")
      assert has_element?(view, "#validation-run-meta", "Took 1 min 1 s")

      # The link to Export carries no stray space inside its underline
      assert view
             |> element("#validation-summary a[href='/gtfs/#{version.id}/export']")
             |> render() =~ ">Run validation again from Export</a>"
    end

    test "opens the history drawer from View history and closes it with Close", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run = completed_run(organization, version, [])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      view |> element("#open-history") |> render_click()
      assert has_element?(view, "#validation-history-overlay[data-open='true']")

      view |> element("#validation-history-close") |> render_click()
      assert has_element?(view, "#validation-history-overlay[data-open='false']")
    end

    test "marks the run being viewed in history and words a failed run as not finished", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      {:ok, failed_run} =
        Validations.create_validation_run(organization.id, version.id, "mobility_data")

      {:ok, failed_run} = Validations.mark_failed(failed_run, :validator_path_not_configured)
      run = completed_run(organization, version, [])

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(
               view,
               "a[aria-current='page'][href='/gtfs/#{version.id}/validation/#{run.id}']"
             )

      refute has_element?(
               view,
               "a[aria-current='page'][href='/gtfs/#{version.id}/validation/#{failed_run.id}']"
             )

      assert has_element?(
               view,
               "a[href='/gtfs/#{version.id}/validation/#{failed_run.id}']",
               "Didn't finish"
             )
    end

    test "shows the plain reason and mapped message for a failed walk-test run", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version
    } do
      run =
        failed_pathways_run(organization, version, %{
          "message" => "Pathways validation failed",
          "reason" => "query_failure"
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-failure-title", "The walk tests didn't finish.")

      assert has_element?(
               view,
               "#pathways-failure-status-message",
               "Some walk tests couldn't get a route from the routing engine."
             )

      assert has_element?(view, "#pathways-failure-summary", "Pathways validation failed")
      refute has_element?(view, "#pathways-failure-checks")
      refute has_element?(view, "#pathways-failure-diagnostics")
    end

    @tag :tmp_dir
    test "lists build diagnostics for a walk-test run whose graph build failed", %{
      conn: conn,
      user: user,
      organization: organization,
      gtfs_version: version,
      tmp_dir: tmp_dir
    } do
      build_log = Path.join(tmp_dir, "build.log")

      File.write!(
        build_log,
        "ERROR Graph build failed\nCaused by: java.lang.NullPointerException at stops.txt row 4\n"
      )

      run =
        failed_pathways_run(organization, version, %{
          "message" => "Graph build failed",
          "issues" => [
            %{
              "details" => %{
                "reason_code" => "build_command_failed",
                "exit_status" => 1,
                "build_log_path" => build_log
              }
            }
          ]
        })

      conn = log_in_user(conn, user, organization: organization)
      {:ok, view, _html} = live(conn, "/gtfs/#{version.id}/validation/#{run.id}")

      assert has_element?(view, "#pathways-failure-diagnostics", "Exit status")
      assert has_element?(view, "#pathways-failure-diagnostics", build_log)

      assert has_element?(
               view,
               "#pathways-failure-diagnostics",
               "Caused by: java.lang.NullPointerException"
             )

      assert has_element?(
               view,
               "#pathways-failure-diagnostics",
               "Issue appears to come from stops.txt."
             )

      assert has_element?(view, "#pathways-failure-diagnostics", "parent_station")
    end
  end

  defp notice_group(code, severity, total, samples \\ []) do
    %{
      "code" => code,
      "severity" => severity,
      "notices" => [%{"totalNotices" => total, "sampleNotices" => samples}]
    }
  end

  defp completed_run(
         organization,
         version,
         notices,
         summary \\ %{errors: 0, warnings: 0, infos: 0}
       ) do
    {:ok, run} = Validations.create_validation_run(organization.id, version.id, "mobility_data")

    {:ok, run} =
      Validations.mark_completed(run, %{summary: summary, notices: notices, duration_ms: 61_000})

    run
  end

  defp failed_pathways_run(organization, version, error_payload) do
    {:ok, run} =
      Validations.create_validation_run(organization.id, version.id, "pathways_tests")

    run
    |> ValidationRun.changeset(%{status: "failed", error_details: Jason.encode!(error_payload)})
    |> Repo.update!()
  end

  defp persist_legacy_pathways_run(run, run_result, duration_ms) do
    now = DateTime.utc_now()
    summary = run_result.summary

    report = %{
      "report_version" => 1,
      "suite_meta" => run_result.suite_meta,
      "selected_test_case_ids" => run_result.selected_test_case_ids,
      "selection" => %{
        "total_candidates" => 0,
        "in_scope_candidates" => 0,
        "selected_count" => 0,
        "invalid_count" => 0,
        "scope_label" => nil,
        "selected_test_case_ids" => [],
        "invalid_test_case_ids" => [],
        "invalid_cases" => []
      },
      "summary" => %{
        "total" => summary.total,
        "passed" => summary.passed,
        "failed" => summary.failed,
        "query_failure" => summary.query_failure,
        "scoring_failure" => summary.scoring_failure,
        "pass_rate" => pass_rate(summary.passed, summary.total)
      },
      "top_failure_categories" => top_failure_categories(summary),
      "stage_timestamps" => %{
        "started_at" => DateTime.to_iso8601(run.started_at),
        "completed_at" => DateTime.to_iso8601(now)
      }
    }

    Repo.transaction(fn ->
      completed_run =
        run
        |> ValidationRun.changeset(%{
          status: "completed",
          errors_count: summary.failed,
          warnings_count: summary.query_failure,
          infos_count: summary.passed,
          duration_ms: duration_ms,
          result_json: report,
          completed_at: now
        })
        |> Repo.update!()

      run_result.cases
      |> Enum.with_index()
      |> Enum.each(fn {test_case, order_index} ->
        insert_legacy_case_result(completed_run.id, test_case, order_index)
      end)

      completed_run
    end)
    |> case do
      {:ok, completed_run} -> completed_run
      {:error, reason} -> raise "could not seed historical pathways result: #{inspect(reason)}"
    end
  end

  defp insert_legacy_case_result(validation_run_id, test_case, order_index) do
    route_output = Map.get(test_case, :route_output) || %{}
    wheelchair_output = Map.get(test_case, :wheelchair_output) || %{}

    %WalkabilityTestRunResult{}
    |> WalkabilityTestRunResult.changeset(%{
      validation_run_id: validation_run_id,
      walkability_test_id: test_case.test_case_id,
      order_index: order_index,
      status: Atom.to_string(test_case.status),
      failure_category: failure_category(test_case),
      route_exists: Map.get(route_output, :route_exists),
      duration_seconds: Map.get(route_output, :duration_seconds),
      distance_meters: Map.get(route_output, :distance_meters),
      itinerary_start_time: Map.get(route_output, :itinerary_start_time),
      itinerary_end_time: Map.get(route_output, :itinerary_end_time),
      leg_count: Map.get(route_output, :leg_count),
      step_count: Map.get(route_output, :step_count),
      itinerary_steps_json: Map.get(route_output, :itinerary_steps),
      wheelchair_route_exists: Map.get(wheelchair_output, :route_exists),
      wheelchair_duration_seconds: Map.get(wheelchair_output, :duration_seconds),
      wheelchair_distance_meters: Map.get(wheelchair_output, :distance_meters),
      details_json: Map.get(test_case, :details)
    })
    |> Repo.insert!()
  end

  defp failure_category(%{failure_category: nil}), do: nil
  defp failure_category(%{failure_category: category}), do: Atom.to_string(category)
  defp failure_category(_test_case), do: nil

  defp top_failure_categories(summary) do
    [
      %{"category" => "query_failure", "count" => summary.query_failure},
      %{"category" => "scoring_failure", "count" => summary.scoring_failure}
    ]
    |> Enum.filter(&(&1["count"] > 0))
    |> Enum.sort_by(&{-&1["count"], &1["category"]})
  end

  defp pass_rate(_passed, 0), do: 0.0
  defp pass_rate(passed, total), do: Float.round(passed * 100.0 / total, 2)
end

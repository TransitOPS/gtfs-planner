defmodule GtfsPlanner.Validations.PathwaysTripTestRunnerTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Validations.PathwaysTripTestRunner
  alias GtfsPlanner.Validations.ValidationRun

  defmodule RuntimeMock do
    def run_with_otp(organization_id, gtfs_version_id, callback, opts) do
      send(self(), {:runtime_called, organization_id, gtfs_version_id, opts})

      if is_function(opts[:status_callback], 1) do
        opts[:status_callback].(%{scope: :otp, phase: :starting})
      end

      {:ok, :pathways_result} = callback.(%{session: :runtime_session})
      {:ok, :pathways_result}
    end
  end

  defmodule RuntimeFailureMock do
    def run_with_otp(_organization_id, _gtfs_version_id, _callback, _opts) do
      {:error, [%{code: :otp_start_failed, details: %{reason: :start_failed}}]}
    end
  end

  defmodule RuntimeStructuredFailureMock do
    def run_with_otp(_organization_id, _gtfs_version_id, _callback, _opts) do
      {:error,
       %{
         reason: :no_walkability_tests,
         organization_id: Ecto.UUID.generate(),
         gtfs_version_id: Ecto.UUID.generate(),
         selected_test_case_ids: []
       }}
    end
  end

  defmodule PathwaysValidityMock do
    def run_in_session(session, organization_id, gtfs_version_id, opts) do
      send(self(), {:pathways_called, session, organization_id, gtfs_version_id, opts})

      if is_function(opts[:status_callback], 1) do
        opts[:status_callback].(%{scope: :suite, phase: :running, completed: 0, total: 1})
      end

      {:ok, :pathways_result}
    end
  end

  defmodule EnvRuntimeMock do
    def run_with_otp(organization_id, gtfs_version_id, callback, opts) do
      send(self(), {:env_runtime_called, organization_id, gtfs_version_id, opts})
      callback.(%{session: :env_runtime_session})
    end
  end

  defmodule EnvPathwaysValidityMock do
    def run_in_session(session, organization_id, gtfs_version_id, opts) do
      send(self(), {:env_pathways_called, session, organization_id, gtfs_version_id, opts})
      {:ok, :env_pathways_result}
    end
  end

  defmodule ValidationsMock do
    def mark_pathways_completed(validation_run, run_result, duration_ms) do
      send(self(), {:mark_pathways_completed_called, validation_run, run_result, duration_ms})
      {:ok, %{id: :persisted_run}}
    end

    def mark_pathways_failed(validation_run, reason) do
      send(self(), {:mark_pathways_failed_called, validation_run, reason})
      {:ok, %{id: :failed_run}}
    end
  end

  defmodule CompletionPersistenceFailureValidationsMock do
    def mark_pathways_completed(_validation_run, _run_result, _duration_ms) do
      {:error, :db_write_failed}
    end

    def mark_pathways_failed(validation_run, reason) do
      send(self(), {:mark_pathways_failed_called, validation_run, reason})
      {:ok, %{id: :failed_run}}
    end
  end

  test "run/4 orchestrates runtime execution and forwards status callback" do
    validation_run = %ValidationRun{}
    organization_id = Ecto.UUID.generate()
    gtfs_version_id = Ecto.UUID.generate()

    status_callback = fn payload -> send(self(), {:status_callback_payload, payload}) end

    assert {:ok, %{id: :persisted_run}} =
             PathwaysTripTestRunner.run(validation_run, organization_id, gtfs_version_id,
               otp_runtime_module: RuntimeMock,
               otp_pathways_validity_module: PathwaysValidityMock,
               validations_module: ValidationsMock,
               status_callback: status_callback,
               runtime_opts: [custom_runtime_opt: :enabled]
             )

    assert_receive {:runtime_called, ^organization_id, ^gtfs_version_id, runtime_opts}
    assert runtime_opts[:status_callback] == status_callback
    assert runtime_opts[:preflight_mode] == :strict
    assert runtime_opts[:force_rebuild] == true
    assert runtime_opts[:custom_runtime_opt] == :enabled

    assert_receive {:pathways_called, %{session: :runtime_session}, ^organization_id,
                    ^gtfs_version_id, pathways_opts}

    assert pathways_opts[:status_callback] == status_callback

    assert_receive {:status_callback_payload, %{scope: :otp, phase: :starting}}

    assert_receive {:status_callback_payload,
                    %{scope: :suite, phase: :running, completed: 0, total: 1}}

    assert_receive {:mark_pathways_completed_called, ^validation_run, :pathways_result,
                    duration_ms}

    assert is_integer(duration_ms)
    assert duration_ms >= 0
  end

  test "run/4 uses configured app env modules when opts do not override" do
    previous_runtime_module = Application.get_env(:gtfs_planner, :otp_runtime_module)

    previous_pathways_module =
      Application.get_env(:gtfs_planner, :otp_pathways_validity_module)

    Application.put_env(:gtfs_planner, :otp_runtime_module, EnvRuntimeMock)
    Application.put_env(:gtfs_planner, :otp_pathways_validity_module, EnvPathwaysValidityMock)

    on_exit(fn ->
      if previous_runtime_module do
        Application.put_env(:gtfs_planner, :otp_runtime_module, previous_runtime_module)
      else
        Application.delete_env(:gtfs_planner, :otp_runtime_module)
      end

      if previous_pathways_module do
        Application.put_env(
          :gtfs_planner,
          :otp_pathways_validity_module,
          previous_pathways_module
        )
      else
        Application.delete_env(:gtfs_planner, :otp_pathways_validity_module)
      end
    end)

    validation_run = %ValidationRun{}
    organization_id = Ecto.UUID.generate()
    gtfs_version_id = Ecto.UUID.generate()

    assert {:ok, %{id: :persisted_run}} =
             PathwaysTripTestRunner.run(validation_run, organization_id, gtfs_version_id,
               validations_module: ValidationsMock
             )

    assert_receive {:env_runtime_called, ^organization_id, ^gtfs_version_id, runtime_opts}
    assert runtime_opts[:preflight_mode] == :strict
    assert runtime_opts[:force_rebuild] == true

    assert_receive {:env_pathways_called, %{session: :env_runtime_session}, ^organization_id,
                    ^gtfs_version_id, pathways_opts}

    assert pathways_opts[:status_callback] == nil

    assert_receive {:mark_pathways_completed_called, ^validation_run, :env_pathways_result,
                    duration_ms}

    assert is_integer(duration_ms)
    assert duration_ms >= 0
  end

  test "run/4 persists failure when runtime returns issues" do
    validation_run = %ValidationRun{}
    organization_id = Ecto.UUID.generate()
    gtfs_version_id = Ecto.UUID.generate()

    assert {:error, %{reason: :otp_runtime_failed, issues: issues}} =
             PathwaysTripTestRunner.run(validation_run, organization_id, gtfs_version_id,
               otp_runtime_module: RuntimeFailureMock,
               otp_pathways_validity_module: PathwaysValidityMock,
               validations_module: ValidationsMock
             )

    assert is_list(issues)

    assert_receive {:mark_pathways_failed_called, ^validation_run,
                    %{reason: :otp_runtime_failed, issues: ^issues}}
  end

  test "run/4 persists failure when completion persistence fails" do
    validation_run = %ValidationRun{}
    organization_id = Ecto.UUID.generate()
    gtfs_version_id = Ecto.UUID.generate()

    assert {:error, %{reason: :pathways_persistence_failed, details: %{error: error}}} =
             PathwaysTripTestRunner.run(validation_run, organization_id, gtfs_version_id,
               otp_runtime_module: RuntimeMock,
               otp_pathways_validity_module: PathwaysValidityMock,
               validations_module: CompletionPersistenceFailureValidationsMock
             )

    assert error =~ ":db_write_failed"

    assert_receive {:mark_pathways_failed_called, ^validation_run,
                    %{reason: :pathways_persistence_failed, details: %{error: ^error}}}
  end

  test "run/4 persists structured runtime failure map as reason plus details" do
    validation_run = %ValidationRun{}
    organization_id = Ecto.UUID.generate()
    gtfs_version_id = Ecto.UUID.generate()

    assert {:error,
            %{
              reason: :no_walkability_tests,
              details: %{
                organization_id: failed_org_id,
                gtfs_version_id: failed_version_id,
                selected_test_case_ids: []
              }
            }} =
             PathwaysTripTestRunner.run(validation_run, organization_id, gtfs_version_id,
               otp_runtime_module: RuntimeStructuredFailureMock,
               otp_pathways_validity_module: PathwaysValidityMock,
               validations_module: ValidationsMock
             )

    assert is_binary(failed_org_id)
    assert is_binary(failed_version_id)

    assert_receive {:mark_pathways_failed_called, ^validation_run,
                    %{
                      reason: :no_walkability_tests,
                      details: %{
                        organization_id: ^failed_org_id,
                        gtfs_version_id: ^failed_version_id,
                        selected_test_case_ids: []
                      }
                    }}
  end
end

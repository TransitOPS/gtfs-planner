# Step 050 — Run the validator CLI under a deadline and fail visibly
#
# Real-jar parity (EV-50): the tracked MobilityData validator runs through the
# same port runner and report parser that the fake-executable tests cover. Needs
# the JDK and jar from `config/runtime.exs`, so it carries :validator_cli and
# branch review runs it explicitly with `mix test --only validator_cli`.

defmodule GtfsPlanner.Gtfs.ValidatorReportTest do
  use GtfsPlanner.DataCase, async: false

  import GtfsPlanner.GtfsFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.Gtfs.Validator
  alias GtfsPlanner.Gtfs.Validator.Result
  alias GtfsPlanner.Validations
  alias GtfsPlanner.Validations.ValidationRun

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  setup do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    seed_feed(organization.id, version.id)

    dir =
      Path.join(System.tmp_dir!(), "validator_report_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{organization: organization, version: version, dir: dir}
  end

  test "the real jar validates the fixture feed and its report parses into a Result", ctx do
    {:ok, zip_binary} = Export.export_to_zip(ctx.organization.id, ctx.version.id, :full)
    zip_path = Path.join(ctx.dir, "gtfs.zip")
    File.write!(zip_path, zip_binary)

    assert {:ok, output_dir} = Validator.run_validator_cli(zip_path, ctx.dir)

    assert {:ok, %Result{} = result} =
             Validator.parse_report(output_dir, System.monotonic_time(:millisecond))

    assert [_ | _] = result.notices
    assert %{errors: errors, warnings: warnings, infos: infos} = result.summary
    assert errors + warnings + infos > 0
  end

  test "validate/3 completes the run with the real jar and the configured paths", ctx do
    {:ok, run} =
      Validations.create_validation_run(ctx.organization.id, ctx.version.id, "mobility_data")

    assert {:ok, %Result{}} =
             Validator.validate(ctx.organization.id, ctx.version.id, validation_run_id: run.id)

    assert %ValidationRun{status: "completed"} = Validations.get_validation_run!(run.id)
  end

  # A small feed the validator can read: agency, service calendar, one route,
  # two located stops and one trip between them.
  defp seed_feed(organization_id, version_id) do
    agency_fixture(organization_id, version_id, %{agency_id: "REPORT_AGENCY"})
    calendar_fixture(organization_id, version_id, %{service_id: "SVC"})
    route_fixture(organization_id, version_id, %{route_id: "RR"})

    for {stop_id, lat, lon} <- [
          {"R1", "40.712800", "-74.006000"},
          {"R2", "40.713800", "-74.005000"}
        ] do
      stop_fixture(organization_id, version_id, %{
        stop_id: stop_id,
        stop_name: "Stop #{stop_id}",
        stop_lat: Decimal.new(lat),
        stop_lon: Decimal.new(lon)
      })
    end

    trip_fixture(organization_id, version_id, "RR", %{trip_id: "RT", service_id: "SVC"})

    for {stop_id, sequence, time} <- [{"R1", 1, "08:00:00"}, {"R2", 2, "08:10:00"}] do
      stop_time_fixture(organization_id, version_id, "RT", stop_id, %{
        stop_sequence: sequence,
        arrival_time: time,
        departure_time: time
      })
    end
  end
end

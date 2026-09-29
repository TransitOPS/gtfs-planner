defmodule GtfsPlanner.Gtfs.Export.FlexValidatorTest do
  @moduledoc """
  Judges the representative flex zip with the tracked MobilityData validator
  CLI (EV-4): zero ERROR-severity notices for the fixture `GtfsPlanner.FlexFixtures`
  seeds.

  The module writes the flex zip and the validator report to a temporary
  directory removed after the test, and makes no network calls
  (`--skip_validator_update`). It shells out to the configured JDK and the
  tracked 8.0.1 jar, so `@moduletag :validator_cli` excludes it from the default
  suite (see `test/test_helper.exs`); branch review runs it explicitly:

      mix test --only validator_cli test/gtfs_planner/gtfs/export/flex_validator_test.exs

  The prepared EV-4 deadline is 300 seconds; the single test's ExUnit timeout
  enforces it.
  """

  use GtfsPlanner.DataCase, async: false

  alias GtfsPlanner.Gtfs.Export
  alias GtfsPlanner.GtfsValidatorCli

  import GtfsPlanner.FlexFixtures
  import GtfsPlanner.OrganizationsFixtures
  import GtfsPlanner.VersionsFixtures

  @moduletag :validator_cli
  @moduletag timeout: 300_000

  @validator_version "8.0.1"

  test "the representative flex zip carries no ERROR-severity notice" do
    organization = organization_fixture()
    version = gtfs_version_fixture(organization.id)
    flex_representative_fixture(organization, version)

    tmp_dir =
      Path.join(System.tmp_dir!(), "flex_validator_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    assert {:ok, flex_zip} =
             Export.export_to_zip(organization.id, version.id, :flex, [])

    zip_path = Path.join(tmp_dir, "flex.zip")
    File.write!(zip_path, flex_zip)

    report = GtfsValidatorCli.run!(Path.join(tmp_dir, "report"), zip_path)

    summary = report["summary"]
    assert summary["validatorVersion"] == @validator_version
    assert summary["gtfsInput"] =~ "flex.zip"

    errors =
      report
      |> GtfsValidatorCli.notices()
      |> Enum.filter(&(GtfsValidatorCli.severity(&1) == "ERROR"))

    print_observation(report, errors)

    assert errors == [],
           "flex zip ERROR notices: " <>
             inspect(Enum.map(errors, &{&1["code"], &1["totalNotices"]}))
  end

  defp print_observation(report, errors) do
    codes = Enum.map(report["notices"], &{&1["code"], &1["severity"], &1["totalNotices"]})

    IO.puts("flex validator 8.0.1 notices: #{inspect(codes)}")
    IO.puts("flex validator ERROR notices: #{length(errors)}")
  end
end

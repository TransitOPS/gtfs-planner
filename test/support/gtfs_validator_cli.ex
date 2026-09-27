defmodule GtfsPlanner.GtfsValidatorCli do
  @moduledoc """
  Runs the tracked MobilityData validator CLI on an exported GTFS ZIP and reads its report.

  `run!/2` shells out to the JDK configured by `config/runtime.exs` (`:java_path`) and the
  tracked 7.1.0 jar (`:gtfs_validator_path`) with `--skip_validator_update`, so the CLI makes
  no update or network request. Because the call starts a JVM, tests using it carry
  `@moduletag :validator_cli` (excluded by `test/test_helper.exs`) and branch review runs them
  explicitly:

      mix test --only validator_cli test/gtfs_planner/gtfs/export/transfers_validator_test.exs

  `notices/1` and `severity/1` read the 7.1.0 report shape: `report["notices"]` holds one entry
  per notice code with `"code"`, `"severity"`, `"totalNotices"` and `"sampleNotices"`. A sample's
  keys are the notice's own field names, so a foreign-key violation carries
  `"childFilename"`/`"childFieldName"`/`"fieldValue"` where other notices carry `"filename"`.
  """

  import ExUnit.Assertions

  @doc """
  Validates `zip_path` with the tracked CLI and returns the decoded `report.json`.

  Writes the CLI's output under `output_dir` (the caller removes it) and asserts that the JDK and
  jar are present, that the CLI exits 0, and that the report has a summary and a notice list.
  """
  @spec run!(Path.t(), Path.t()) :: map()
  def run!(output_dir, zip_path) do
    java_path = Application.get_env(:gtfs_planner, :java_path, "java")
    jar_path = Application.fetch_env!(:gtfs_planner, :gtfs_validator_path)

    assert System.find_executable(java_path),
           "configured JDK (config/runtime.exs :java_path) is not executable: #{java_path}"

    assert File.regular?(jar_path), "tracked validator jar is missing: #{jar_path}"

    File.mkdir_p!(output_dir)

    args = ["-jar", jar_path, "-i", zip_path, "-o", output_dir, "--skip_validator_update"]

    {output, exit_code} = System.cmd(java_path, args, stderr_to_stdout: true)

    assert exit_code == 0,
           "validator exited #{exit_code} for #{Path.basename(zip_path)}:\n#{output}"

    report_path = Path.join(output_dir, "report.json")
    assert File.regular?(report_path), "validator wrote no report.json for #{zip_path}"

    report = report_path |> File.read!() |> Jason.decode!()

    assert is_map(report["summary"]), "report.json has no summary object for #{zip_path}"
    assert is_list(notices(report)), "report.json has no notices list for #{zip_path}"

    report
  end

  @doc "Returns the report's notice entries, one per notice code."
  @spec notices(map()) :: [map()]
  def notices(report), do: Map.get(report, "notices", [])

  @doc ~S(Returns a notice entry's severity as an uppercase string, for example `"ERROR"`.)
  @spec severity(map()) :: String.t()
  def severity(notice), do: notice["severity"] |> to_string() |> String.upcase()
end

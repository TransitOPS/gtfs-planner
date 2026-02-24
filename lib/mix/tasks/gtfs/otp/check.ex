defmodule Mix.Tasks.Gtfs.Otp.Check do
  @moduledoc """
  Validate local OTP prerequisites for export graph builds.

  ## Usage

      mix gtfs.otp.check
      mix gtfs.otp.check --create-dir
      mix gtfs.otp.check --create-dir --warn-only

  ## Options

  - `--create-dir` creates `priv/otp` if it is missing
  - `--warn-only` exits with code 0 even if checks fail
  """

  use Mix.Task

  alias GtfsPlanner.Otp.Prerequisites

  @shortdoc "Validate OTP prerequisites"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [create_dir: :boolean, warn_only: :boolean],
        aliases: [c: :create_dir, w: :warn_only]
      )

    if rest != [] or invalid != [] do
      Mix.shell().error("Invalid arguments: #{Enum.join(rest, " ")}")
      Mix.shell().info(@moduledoc)
      System.halt(1)
    end

    report = Prerequisites.check(create_dir: opts[:create_dir] || false)

    Enum.each(report.checks, fn check ->
      prefix = if check.ok?, do: "[OK]", else: "[ERROR]"
      Mix.shell().info("#{prefix} #{check.name}: #{check.message}")
    end)

    Mix.shell().info(
      "Summary: #{length(report.checks) - report.errors} passed, #{report.errors} failed"
    )

    if report.errors > 0 and not (opts[:warn_only] || false) do
      System.halt(1)
    end
  end
end

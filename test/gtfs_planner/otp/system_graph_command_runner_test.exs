defmodule GtfsPlanner.Otp.SystemGraphCommandRunnerTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.SystemGraphCommandRunner

  test "run/3 captures stderr into stdout by default" do
    script = "echo out; echo err 1>&2"

    {output, 0} = SystemGraphCommandRunner.run("/bin/sh", ["-c", script])

    assert output =~ "out"
    assert output =~ "err"
  end

  test "run/3 allows overriding stderr_to_stdout option" do
    script = "echo out; echo err 1>&2"

    {output, 0} =
      SystemGraphCommandRunner.run("/bin/sh", ["-c", script], stderr_to_stdout: false)

    assert output =~ "out"
    refute output =~ "err"
  end
end

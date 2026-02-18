defmodule GtfsPlanner.Otp.ManifestTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Otp.Manifest

  test "file_requirements includes required pathways and calendar one_of policy" do
    requirements = Manifest.file_requirements()

    assert "pathways.txt" in requirements.required
    assert requirements.one_of == ["calendar.txt", "calendar_dates.txt"]
    assert "levels.txt" in requirements.optional
  end
end

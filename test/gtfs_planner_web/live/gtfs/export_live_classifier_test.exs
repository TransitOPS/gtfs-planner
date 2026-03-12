defmodule GtfsPlannerWeb.Gtfs.ExportLiveClassifierTest do
  use ExUnit.Case, async: true

  test "classifies explicit issue code before generic referential tokens" do
    payload = %{
      "reason" => "otp_runtime_failed",
      "raw_error_details" => "referential integrity failure",
      "issues" => [
        %{
          "code" => "boarding_area_parent_station_missing",
          "message" => "boarding area is missing parent_station in stops.txt"
        }
      ]
    }

    assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
             :boarding_area_parent_integrity
  end
end

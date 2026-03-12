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

  test "classifies station lineage boundary codes as internal failure before token fallback" do
    payload = %{
      "reason" => "otp_runtime_failed",
      "raw_error_details" => "referential integrity failure",
      "issues" => [
        %{
          "code" => "station_runtime_input_lineage_mismatch",
          "message" => "runtime input must match station zip"
        }
      ]
    }

    assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
             :pathways_internal_failure
  end

  test "classifies station artifact unreadable boundary code as missing/corrupt files" do
    payload = %{
      "reason" => "otp_runtime_failed",
      "raw_error_details" => "referential integrity failure",
      "issues" => [
        %{
          "code" => "station_runtime_precheck_artifact_read_failed",
          "message" => "station runtime artifact precheck could not read GTFS tables"
        }
      ]
    }

    assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
             :missing_corrupt_files_or_permissions
  end

  test "classifies station scoped referential boundary code as referential integrity" do
    payload = %{
      "reason" => "otp_runtime_failed",
      "issues" => [
        %{
          "code" => "station_runtime_precheck_stop_times_stop_id_missing_stop",
          "message" => "station runtime artifact failed scoped referential precheck"
        }
      ]
    }

    assert GtfsPlannerWeb.Gtfs.ExportLive.classify_pathways_failure_category(payload) ==
             :referential_integrity
  end
end

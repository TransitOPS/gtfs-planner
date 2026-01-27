defmodule GtfsPlanner.Gtfs.Import.RowParserTest do
  use GtfsPlanner.DataCase, async: true

  alias GtfsPlanner.Gtfs.Import.RowParser

  setup do
    organization = GtfsPlanner.OrganizationsFixtures.organization_fixture()
    gtfs_version = GtfsPlanner.VersionsFixtures.gtfs_version_fixture(organization.id)

    %{organization_id: organization.id, gtfs_version_id: gtfs_version.id}
  end

  describe "route_row_to_attrs/3" do
    test "converts valid route row to attrs", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "route_id" => "R1",
        "route_type" => "3",
        "route_short_name" => "Bus 1",
        "route_long_name" => "Main Street Line",
        "route_color" => "FF0000",
        "route_text_color" => "FFFFFF"
      }

      assert {:ok, attrs} = RowParser.route_row_to_attrs(row, org_id, version_id)
      assert attrs.route_id == "R1"
      assert attrs.route_type == 3
      assert attrs.route_short_name == "Bus 1"
      assert attrs.route_long_name == "Main Street Line"
      assert attrs.route_color == "FF0000"
      assert attrs.route_text_color == "FFFFFF"
      assert attrs.organization_id == org_id
      assert attrs.gtfs_version_id == version_id
    end

    test "uses default colors when not provided", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"route_id" => "R1", "route_type" => "3"}

      assert {:ok, attrs} = RowParser.route_row_to_attrs(row, org_id, version_id)
      assert attrs.route_color == "FFFFFF"
      assert attrs.route_text_color == "000000"
    end

    test "returns error for missing route_id", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"route_type" => "3"}

      assert {:error, "missing required field: route_id"} =
               RowParser.route_row_to_attrs(row, org_id, version_id)
    end

    test "returns error for invalid route_type", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"route_id" => "R1", "route_type" => "99"}
      assert {:error, _} = RowParser.route_row_to_attrs(row, org_id, version_id)
    end
  end

  describe "calendar_row_to_attrs/3" do
    test "converts valid calendar row to attrs", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "service_id" => "WEEKDAY",
        "monday" => "1",
        "tuesday" => "1",
        "wednesday" => "1",
        "thursday" => "1",
        "friday" => "1",
        "saturday" => "0",
        "sunday" => "0",
        "start_date" => "20260101",
        "end_date" => "20261231"
      }

      assert {:ok, attrs} = RowParser.calendar_row_to_attrs(row, org_id, version_id)
      assert attrs.service_id == "WEEKDAY"
      assert attrs.monday == 1
      assert attrs.tuesday == 1
      assert attrs.saturday == 0
      assert attrs.sunday == 0
      assert attrs.start_date == ~D[2026-01-01]
      assert attrs.end_date == ~D[2026-12-31]
    end

    test "returns error for invalid day flag", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "service_id" => "WEEKDAY",
        "monday" => "2",
        "tuesday" => "1",
        "wednesday" => "1",
        "thursday" => "1",
        "friday" => "1",
        "saturday" => "0",
        "sunday" => "0",
        "start_date" => "20260101",
        "end_date" => "20261231"
      }

      assert {:error, _} = RowParser.calendar_row_to_attrs(row, org_id, version_id)
    end

    test "returns error for invalid date format", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "service_id" => "WEEKDAY",
        "monday" => "1",
        "tuesday" => "1",
        "wednesday" => "1",
        "thursday" => "1",
        "friday" => "1",
        "saturday" => "0",
        "sunday" => "0",
        "start_date" => "2026-01-01",
        "end_date" => "20261231"
      }

      assert {:error, _} = RowParser.calendar_row_to_attrs(row, org_id, version_id)
    end
  end

  describe "stop_time_row_to_attrs/3" do
    test "converts valid stop_time row to attrs", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "trip_id" => "T1",
        "stop_id" => "S1",
        "stop_sequence" => "1",
        "arrival_time" => "08:30:00",
        "departure_time" => "08:31:00"
      }

      assert {:ok, attrs} = RowParser.stop_time_row_to_attrs(row, org_id, version_id)
      assert attrs.trip_id == "T1"
      assert attrs.stop_id == "S1"
      assert attrs.stop_sequence == 1
      assert attrs.arrival_time == "08:30:00"
      assert attrs.departure_time == "08:31:00"
    end

    test "handles optional fields as nil", %{organization_id: org_id, gtfs_version_id: version_id} do
      row = %{
        "trip_id" => "T1",
        "stop_id" => "S1",
        "stop_sequence" => "1"
      }

      assert {:ok, attrs} = RowParser.stop_time_row_to_attrs(row, org_id, version_id)
      assert attrs.arrival_time == nil
      assert attrs.departure_time == nil
      assert attrs.pickup_type == nil
    end

    test "returns error for missing required field", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"trip_id" => "T1", "stop_id" => "S1"}
      assert {:error, _} = RowParser.stop_time_row_to_attrs(row, org_id, version_id)
    end
  end

  describe "pathway_row_to_attrs/3" do
    test "converts valid pathway row to attrs", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "pathway_id" => "P1",
        "from_stop_id" => "S1",
        "to_stop_id" => "S2",
        "pathway_mode" => "1",
        "is_bidirectional" => "1"
      }

      assert {:ok, attrs} = RowParser.pathway_row_to_attrs(row, org_id, version_id)
      assert attrs.pathway_id == "P1"
      assert attrs.from_stop_id == "S1"
      assert attrs.to_stop_id == "S2"
      assert attrs.pathway_mode == 1
      assert attrs.is_bidirectional == true
    end
  end

  describe "parse_float/1" do
    test "parses valid float" do
      assert {:ok, 1.5} = RowParser.parse_float("1.5")
      assert {:ok, +0.0} = RowParser.parse_float("0.0")
      assert {:ok, -2.5} = RowParser.parse_float("-2.5")
    end

    test "returns error for nil" do
      assert {:error, "nil value"} = RowParser.parse_float(nil)
    end

    test "returns error for empty string" do
      assert {:error, "empty value"} = RowParser.parse_float("")
    end

    test "returns error for invalid format" do
      assert {:error, _} = RowParser.parse_float("abc")
    end
  end

  describe "parse_integer/1" do
    test "parses valid integer" do
      assert {:ok, 42} = RowParser.parse_integer("42")
      assert {:ok, 0} = RowParser.parse_integer("0")
      assert {:ok, -10} = RowParser.parse_integer("-10")
    end

    test "returns ok with nil for nil input" do
      assert {:ok, nil} = RowParser.parse_integer(nil)
    end

    test "returns ok with nil for empty string" do
      assert {:ok, nil} = RowParser.parse_integer("")
    end

    test "returns error for invalid format" do
      assert {:error, _} = RowParser.parse_integer("abc")
      assert {:error, _} = RowParser.parse_integer("1.5")
    end
  end

  describe "parse_decimal/1" do
    test "parses valid decimal" do
      assert {:ok, decimal} = RowParser.parse_decimal("42.5")
      assert Decimal.equal?(decimal, Decimal.new("42.5"))
    end

    test "returns ok with nil for nil input" do
      assert {:ok, nil} = RowParser.parse_decimal(nil)
    end

    test "returns ok with nil for empty string" do
      assert {:ok, nil} = RowParser.parse_decimal("")
    end

    test "returns error for invalid format" do
      assert {:error, _} = RowParser.parse_decimal("abc")
    end
  end

  describe "parse_gtfs_date/1" do
    test "parses valid GTFS date" do
      assert {:ok, ~D[2026-01-15]} = RowParser.parse_gtfs_date("20260115")
      assert {:ok, ~D[2025-12-31]} = RowParser.parse_gtfs_date("20251231")
    end

    test "returns ok with nil for nil input" do
      assert {:ok, nil} = RowParser.parse_gtfs_date(nil)
    end

    test "returns ok with nil for empty string" do
      assert {:ok, nil} = RowParser.parse_gtfs_date("")
    end

    test "returns error for invalid format" do
      assert {:error, _} = RowParser.parse_gtfs_date("2026-01-15")
      assert {:error, _} = RowParser.parse_gtfs_date("20260230")
      assert {:error, _} = RowParser.parse_gtfs_date("123")
    end
  end

  describe "parse_gtfs_time/1" do
    test "parses valid GTFS time" do
      assert {:ok, "08:30:00"} = RowParser.parse_gtfs_time("08:30:00")
      assert {:ok, "25:00:00"} = RowParser.parse_gtfs_time("25:00:00")
    end

    test "returns ok with nil for nil input" do
      assert {:ok, nil} = RowParser.parse_gtfs_time(nil)
    end

    test "returns ok with nil for empty string" do
      assert {:ok, nil} = RowParser.parse_gtfs_time("")
    end

    test "returns error for invalid format" do
      assert {:error, _} = RowParser.parse_gtfs_time("8:30")
      assert {:error, _} = RowParser.parse_gtfs_time("08:30")
      assert {:error, _} = RowParser.parse_gtfs_time("invalid")
    end
  end

  describe "parse_direction_id/1" do
    test "parses valid direction_id" do
      assert {:ok, 0} = RowParser.parse_direction_id("0")
      assert {:ok, 1} = RowParser.parse_direction_id("1")
    end

    test "returns ok with nil for nil input" do
      assert {:ok, nil} = RowParser.parse_direction_id(nil)
    end

    test "returns ok with nil for empty string" do
      assert {:ok, nil} = RowParser.parse_direction_id("")
    end

    test "returns error for out of range value" do
      assert {:error, _} = RowParser.parse_direction_id("2")
      assert {:error, _} = RowParser.parse_direction_id("-1")
    end
  end

  describe "parse_pathway_mode/1" do
    test "parses valid pathway_mode" do
      assert {:ok, 1} = RowParser.parse_pathway_mode("1")
      assert {:ok, 7} = RowParser.parse_pathway_mode("7")
    end

    test "returns error for nil" do
      assert {:error, "pathway_mode is required"} = RowParser.parse_pathway_mode(nil)
    end

    test "returns error for empty string" do
      assert {:error, "pathway_mode is required"} = RowParser.parse_pathway_mode("")
    end

    test "returns error for out of range value" do
      assert {:error, _} = RowParser.parse_pathway_mode("0")
      assert {:error, _} = RowParser.parse_pathway_mode("8")
    end
  end

  describe "parse_is_bidirectional/1" do
    test "parses valid bidirectional values" do
      assert {:ok, true} = RowParser.parse_is_bidirectional("1")
      assert {:ok, false} = RowParser.parse_is_bidirectional("0")
      assert {:ok, true} = RowParser.parse_is_bidirectional("true")
      assert {:ok, false} = RowParser.parse_is_bidirectional("false")
    end

    test "defaults to true for nil" do
      assert {:ok, true} = RowParser.parse_is_bidirectional(nil)
    end

    test "defaults to true for empty string" do
      assert {:ok, true} = RowParser.parse_is_bidirectional("")
    end

    test "returns error for invalid value" do
      assert {:error, _} = RowParser.parse_is_bidirectional("invalid")
    end
  end

  describe "parse_day_flag/1" do
    test "parses valid day flags" do
      assert {:ok, 0} = RowParser.parse_day_flag("0")
      assert {:ok, 1} = RowParser.parse_day_flag("1")
    end

    test "returns error for nil" do
      assert {:error, "required"} = RowParser.parse_day_flag(nil)
    end

    test "returns error for empty string" do
      assert {:error, "required"} = RowParser.parse_day_flag("")
    end

    test "returns error for invalid value" do
      assert {:error, _} = RowParser.parse_day_flag("2")
    end
  end

  describe "parse_exception_type/1" do
    test "parses valid exception types" do
      assert {:ok, 1} = RowParser.parse_exception_type("1")
      assert {:ok, 2} = RowParser.parse_exception_type("2")
    end

    test "returns error for nil" do
      assert {:error, "required"} = RowParser.parse_exception_type(nil)
    end

    test "returns error for empty string" do
      assert {:error, "required"} = RowParser.parse_exception_type("")
    end

    test "returns error for invalid value" do
      assert {:error, _} = RowParser.parse_exception_type("0")
      assert {:error, _} = RowParser.parse_exception_type("3")
    end
  end

  describe "extract_required/2" do
    test "extracts required field" do
      assert {:ok, "value"} = RowParser.extract_required(%{"field" => "value"}, "field")
    end

    test "returns error for missing field" do
      assert {:error, "missing required field: field"} = RowParser.extract_required(%{}, "field")
    end

    test "returns error for empty field" do
      assert {:error, "empty required field: field"} =
               RowParser.extract_required(%{"field" => ""}, "field")
    end
  end

  describe "empty_to_nil/1" do
    test "converts empty string to nil" do
      assert nil == RowParser.empty_to_nil("")
    end

    test "returns nil for nil input" do
      assert nil == RowParser.empty_to_nil(nil)
    end

    test "returns value for non-empty string" do
      assert "value" == RowParser.empty_to_nil("value")
    end
  end
end

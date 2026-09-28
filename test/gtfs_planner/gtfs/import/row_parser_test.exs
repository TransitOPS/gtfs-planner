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

  describe "stop_row_to_attrs/3" do
    test "keeps a zone_id byte-for-byte, including a leading space", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "stop_id" => "S1",
        "stop_name" => "Stop 1",
        "stop_lat" => "40.7",
        "stop_lon" => "-74.0",
        "zone_id" => " A"
      }

      assert {:ok, attrs} = RowParser.stop_row_to_attrs(row, org_id, version_id)
      assert attrs.zone_id == " A"
    end

    test "stores an empty zone_id as nil", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"stop_id" => "S1", "zone_id" => ""}

      assert {:ok, attrs} = RowParser.stop_row_to_attrs(row, org_id, version_id)
      assert attrs.zone_id == nil
    end

    test "stores a missing zone_id key as nil", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"stop_id" => "S1"}

      assert {:ok, attrs} = RowParser.stop_row_to_attrs(row, org_id, version_id)
      assert attrs.zone_id == nil
    end

    test "keeps stop_code, tts_stop_name, stop_url and stop_timezone byte-for-byte", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "stop_id" => "S1",
        "stop_code" => " 4021",
        "tts_stop_name" => "Fourth Street ",
        "stop_url" => "https://example.test/stops/S1?a=1,2",
        "stop_timezone" => "America/New_York"
      }

      assert {:ok, attrs} = RowParser.stop_row_to_attrs(row, org_id, version_id)

      assert %{
               stop_code: " 4021",
               tts_stop_name: "Fourth Street ",
               stop_url: "https://example.test/stops/S1?a=1,2",
               stop_timezone: "America/New_York"
             } = attrs
    end

    test "stores empty stop_code, tts_stop_name, stop_url and stop_timezone as nil", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "stop_id" => "S1",
        "stop_code" => "",
        "tts_stop_name" => "",
        "stop_url" => "",
        "stop_timezone" => ""
      }

      assert {:ok, attrs} = RowParser.stop_row_to_attrs(row, org_id, version_id)

      assert %{stop_code: nil, tts_stop_name: nil, stop_url: nil, stop_timezone: nil} = attrs
    end

    test "stores missing stop_code, tts_stop_name, stop_url and stop_timezone keys as nil", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"stop_id" => "S1"}

      assert {:ok, attrs} = RowParser.stop_row_to_attrs(row, org_id, version_id)

      assert %{stop_code: nil, tts_stop_name: nil, stop_url: nil, stop_timezone: nil} = attrs
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
      stop_map = %{"S1" => true, "S2" => true}

      row = %{
        "pathway_id" => "P1",
        "from_stop_id" => "S1",
        "to_stop_id" => "S2",
        "pathway_mode" => "1",
        "is_bidirectional" => "1"
      }

      assert {:ok, attrs} = RowParser.pathway_row_to_attrs(row, org_id, version_id, stop_map)
      assert attrs.pathway_id == "P1"
      assert attrs.from_stop_id == "S1"
      assert attrs.to_stop_id == "S2"
      assert attrs.pathway_mode == 1
      assert attrs.is_bidirectional == true
    end

    test "returns error when from_stop_id not found", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_map = %{"S2" => true}

      row = %{
        "pathway_id" => "P1",
        "from_stop_id" => "S1",
        "to_stop_id" => "S2",
        "pathway_mode" => "1",
        "is_bidirectional" => "1"
      }

      assert {:error, "from_stop_id not found: S1"} =
               RowParser.pathway_row_to_attrs(row, org_id, version_id, stop_map)
    end

    test "returns error when to_stop_id not found", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      stop_map = %{"S1" => true}

      row = %{
        "pathway_id" => "P1",
        "from_stop_id" => "S1",
        "to_stop_id" => "S2",
        "pathway_mode" => "1",
        "is_bidirectional" => "1"
      }

      assert {:error, "to_stop_id not found: S2"} =
               RowParser.pathway_row_to_attrs(row, org_id, version_id, stop_map)
    end
  end

  describe "transfer_row_to_attrs/3" do
    test "converts a stopless type 4 row with both trip IDs", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "from_stop_id" => "",
        "to_stop_id" => "",
        "from_trip_id" => "T1",
        "to_trip_id" => "T2",
        "transfer_type" => "4"
      }

      assert {:ok, attrs} = RowParser.transfer_row_to_attrs(row, org_id, version_id)

      assert attrs == %{
               from_stop_id: nil,
               to_stop_id: nil,
               from_route_id: nil,
               to_route_id: nil,
               from_trip_id: "T1",
               to_trip_id: "T2",
               transfer_type: 4,
               min_transfer_time: nil,
               organization_id: org_id,
               gtfs_version_id: version_id
             }
    end

    test "converts a type 5 row whose stop columns are absent", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "from_trip_id" => "T1",
        "to_trip_id" => "T2",
        "transfer_type" => "5"
      }

      assert {:ok, attrs} = RowParser.transfer_row_to_attrs(row, org_id, version_id)

      assert attrs == %{
               from_stop_id: nil,
               to_stop_id: nil,
               from_route_id: nil,
               to_route_id: nil,
               from_trip_id: "T1",
               to_trip_id: "T2",
               transfer_type: 5,
               min_transfer_time: nil,
               organization_id: org_id,
               gtfs_version_id: version_id
             }
    end

    test "keeps a type 0 row's stops and nils its empty route and trip columns", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "from_stop_id" => "S1",
        "to_stop_id" => "S2",
        "from_route_id" => "",
        "to_route_id" => "",
        "from_trip_id" => "",
        "to_trip_id" => "",
        "transfer_type" => "0"
      }

      assert {:ok, attrs} = RowParser.transfer_row_to_attrs(row, org_id, version_id)

      assert attrs == %{
               from_stop_id: "S1",
               to_stop_id: "S2",
               from_route_id: nil,
               to_route_id: nil,
               from_trip_id: nil,
               to_trip_id: nil,
               transfer_type: 0,
               min_transfer_time: nil,
               organization_id: org_id,
               gtfs_version_id: version_id
             }
    end

    test "keeps both stops and both trips on a type 4 row", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "from_stop_id" => "S1",
        "to_stop_id" => "S2",
        "from_trip_id" => "T3",
        "to_trip_id" => "T4",
        "transfer_type" => "4"
      }

      assert {:ok, attrs} = RowParser.transfer_row_to_attrs(row, org_id, version_id)

      assert attrs.from_stop_id == "S1"
      assert attrs.to_stop_id == "S2"
      assert attrs.from_trip_id == "T3"
      assert attrs.to_trip_id == "T4"
      assert attrs.transfer_type == 4
    end

    test "returns an error for a type 4 row without a to_trip_id", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "from_stop_id" => "",
        "to_stop_id" => "",
        "from_trip_id" => "T1",
        "to_trip_id" => "",
        "transfer_type" => "4"
      }

      assert {:error, "empty required field: to_trip_id"} =
               RowParser.transfer_row_to_attrs(row, org_id, version_id)
    end

    test "returns an error for a type 5 row without a from_trip_id key", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "from_stop_id" => "",
        "to_stop_id" => "",
        "to_trip_id" => "T2",
        "transfer_type" => "5"
      }

      assert {:error, "missing required field: from_trip_id"} =
               RowParser.transfer_row_to_attrs(row, org_id, version_id)
    end

    test "returns an error for a type 2 row without a from_stop_id", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "from_stop_id" => "",
        "to_stop_id" => "S2",
        "transfer_type" => "2",
        "min_transfer_time" => "120"
      }

      assert {:error, "empty required field: from_stop_id"} =
               RowParser.transfer_row_to_attrs(row, org_id, version_id)
    end

    test "reads an empty transfer_type as the spec default of 0", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"from_stop_id" => "S1", "to_stop_id" => "S2", "transfer_type" => ""}

      assert {:ok, attrs} = RowParser.transfer_row_to_attrs(row, org_id, version_id)
      assert attrs.transfer_type == 0
      assert attrs.from_stop_id == "S1"
      assert attrs.to_stop_id == "S2"
    end

    test "reads a missing transfer_type column as the spec default of 0", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"from_stop_id" => "S1", "to_stop_id" => "S2"}

      assert {:ok, attrs} = RowParser.transfer_row_to_attrs(row, org_id, version_id)
      assert attrs.transfer_type == 0
    end

    test "still requires both stops on a defaulted row", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{"from_stop_id" => "S1", "to_stop_id" => "", "transfer_type" => ""}

      assert {:error, "empty required field: to_stop_id"} =
               RowParser.transfer_row_to_attrs(row, org_id, version_id)
    end
  end

  describe "pathway_evolution_row_to_attrs/3" do
    test "converts a supported closure row to integer service-day seconds", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "pathway_id" => "P1",
        "service_id" => "S1",
        "start_time" => "23:00:00",
        "end_time" => "26:00:00",
        "is_closed" => "1"
      }

      assert {:ok, attrs} = RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)

      assert attrs == %{
               pathway_id: "P1",
               service_id: "S1",
               start_time: 82_800,
               end_time: 93_600,
               note: nil,
               organization_id: org_id,
               gtfs_version_id: version_id
             }
    end

    test "accepts a blank direction column and H:MM service times", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      for direction <- ["", "   "] do
        row = %{
          "pathway_id" => "P1",
          "service_id" => "S1",
          "start_time" => "9:00",
          "end_time" => "15:30",
          "is_closed" => "1",
          "direction" => direction
        }

        assert {:ok, attrs} = RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)

        assert attrs.start_time == 32_400
        assert attrs.end_time == 55_800
      end
    end

    test "accepts a midnight and 24:00:00 window as service-day seconds", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "pathway_id" => "P1",
        "service_id" => "S1",
        "start_time" => "00:00:00",
        "end_time" => "24:00:00",
        "is_closed" => "1"
      }

      assert {:ok, attrs} = RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)

      assert attrs.start_time == 0
      assert attrs.end_time == 86_400
    end

    test "preserves exact reference IDs and takes scope from the arguments", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "pathway_id" => "P 1",
        "service_id" => "S 1",
        "start_time" => "09:00:00",
        "end_time" => "10:00:00",
        "is_closed" => "1",
        "organization_id" => "forged-organization",
        "gtfs_version_id" => "forged-version"
      }

      assert {:ok, attrs} = RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)

      assert attrs.pathway_id == "P 1"
      assert attrs.service_id == "S 1"
      assert attrs.organization_id == org_id
      assert attrs.gtfs_version_id == version_id
      refute inspect(attrs) =~ "forged-organization"
      refute inspect(attrs) =~ "forged-version"
    end

    test "rejects an absent, empty or whitespace-only pathway_id", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      for pathway_id <- [nil, "", "   "] do
        row = %{
          "pathway_id" => pathway_id,
          "service_id" => "S1",
          "start_time" => "09:00:00",
          "end_time" => "10:00:00",
          "is_closed" => "1"
        }

        assert {:error, {:evolution_rejected, :evolution_pathway_required}} =
                 RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)
      end

      row = %{
        "service_id" => "S1",
        "start_time" => "09:00:00",
        "end_time" => "10:00:00",
        "is_closed" => "1"
      }

      assert {:error, {:evolution_rejected, :evolution_pathway_required}} =
               RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)
    end

    test "rejects an absent, empty or whitespace-only service_id", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      for service_id <- [nil, "", "  "] do
        row = %{
          "pathway_id" => "P1",
          "service_id" => service_id,
          "start_time" => "09:00:00",
          "end_time" => "10:00:00",
          "is_closed" => "1"
        }

        assert {:error, {:evolution_rejected, :evolution_service_required}} =
                 RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)
      end
    end

    test "rejects every opening row value other than is_closed 1", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      for is_closed <- ["0", "true", "yes", "", " 1 ", nil] do
        row = %{
          "pathway_id" => "P1",
          "service_id" => "S1",
          "start_time" => "09:00:00",
          "end_time" => "10:00:00",
          "is_closed" => is_closed
        }

        assert {:error, {:evolution_rejected, :evolution_opening_unsupported}} =
                 RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)
      end

      row = %{
        "pathway_id" => "P1",
        "service_id" => "S1",
        "start_time" => "09:00:00",
        "end_time" => "10:00:00"
      }

      assert {:error, {:evolution_rejected, :evolution_opening_unsupported}} =
               RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)
    end

    test "rejects any nonblank direction, including 0", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      for direction <- ["0", "1", "2", " 2 "] do
        row = %{
          "pathway_id" => "P1",
          "service_id" => "S1",
          "start_time" => "09:00:00",
          "end_time" => "10:00:00",
          "is_closed" => "1",
          "direction" => direction
        }

        assert {:error, {:evolution_rejected, :evolution_direction_unsupported}} =
                 RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)
      end
    end

    test "rejects a malformed, absent or non-increasing time", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      bad_windows = [
        {"09:00:00", "10:0:0"},
        {"09:00:00", "10:00:0"},
        {"09:00:00", ""},
        {"09:00:00", nil},
        {"", "10:00:00"},
        {nil, "10:00:00"},
        {"09:00:00", "09:00:00"},
        {"23:00:00", "02:00:00"},
        {"10:00:00", "09:00:00"},
        {"-1:00:00", "10:00:00"}
      ]

      for {start_time, end_time} <- bad_windows do
        row = %{
          "pathway_id" => "P1",
          "service_id" => "S1",
          "start_time" => start_time,
          "end_time" => end_time,
          "is_closed" => "1"
        }

        assert {:error, {:evolution_rejected, :evolution_time_invalid}} =
                 RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id),
               "expected a time rejection for #{inspect({start_time, end_time})}"
      end
    end

    test "reports the first violated rule in the documented order", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      everything_wrong = %{
        "pathway_id" => "",
        "service_id" => "",
        "start_time" => "nope",
        "end_time" => "nope",
        "is_closed" => "0",
        "direction" => "2"
      }

      assert {:error, {:evolution_rejected, :evolution_pathway_required}} =
               RowParser.pathway_evolution_row_to_attrs(everything_wrong, org_id, version_id)

      no_pathway_rejection = %{
        everything_wrong
        | "pathway_id" => "P1",
          "start_time" => "09:00:00",
          "end_time" => "10:00:00"
      }

      assert {:error, {:evolution_rejected, :evolution_service_required}} =
               RowParser.pathway_evolution_row_to_attrs(no_pathway_rejection, org_id, version_id)

      no_service_rejection = %{no_pathway_rejection | "service_id" => "S1"}

      assert {:error, {:evolution_rejected, :evolution_opening_unsupported}} =
               RowParser.pathway_evolution_row_to_attrs(no_service_rejection, org_id, version_id)

      closed = %{no_service_rejection | "is_closed" => "1"}

      assert {:error, {:evolution_rejected, :evolution_direction_unsupported}} =
               RowParser.pathway_evolution_row_to_attrs(closed, org_id, version_id)

      no_direction = %{closed | "direction" => "", "start_time" => "nope"}

      assert {:error, {:evolution_rejected, :evolution_time_invalid}} =
               RowParser.pathway_evolution_row_to_attrs(no_direction, org_id, version_id)
    end

    test "returns a bounded rejection that never carries row values", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "pathway_id" => "P1",
        "service_id" => "S1",
        "start_time" => "not-a-time",
        "end_time" => "10:00:00",
        "is_closed" => "1"
      }

      assert {:error, {:evolution_rejected, :evolution_time_invalid} = error} =
               RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)

      refute inspect(error) =~ "not-a-time"
    end

    test "does not resolve references, so an unknown pathway still parses", %{
      organization_id: org_id,
      gtfs_version_id: version_id
    } do
      row = %{
        "pathway_id" => "P_MISSING",
        "service_id" => "S_MISSING",
        "start_time" => "09:00:00",
        "end_time" => "10:00:00",
        "is_closed" => "1"
      }

      assert {:ok, attrs} = RowParser.pathway_evolution_row_to_attrs(row, org_id, version_id)

      assert attrs.pathway_id == "P_MISSING"
      assert attrs.service_id == "S_MISSING"
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

    test "parses single-digit hour" do
      assert {:ok, "6:15:00"} = RowParser.parse_gtfs_time("6:15:00")
    end

    test "trims and parses space-padded hour" do
      assert {:ok, "6:15:00"} = RowParser.parse_gtfs_time(" 6:15:00")
    end

    test "parses three-digit hour" do
      assert {:ok, "100:00:00"} = RowParser.parse_gtfs_time("100:00:00")
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

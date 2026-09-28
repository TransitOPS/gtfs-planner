defmodule GtfsPlanner.Gtfs.TransferAuditTest do
  use ExUnit.Case, async: true

  alias GtfsPlanner.Gtfs.Transfer

  describe "audit_snapshot/1" do
    test "returns exactly the eight GTFS columns with string keys and keeps nil values" do
      transfer = %Transfer{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        transfer_type: 0
      }

      assert Transfer.audit_snapshot(transfer) == %{
               "from_stop_id" => "CEN-A",
               "to_stop_id" => "CEN-C",
               "from_route_id" => nil,
               "to_route_id" => nil,
               "from_trip_id" => nil,
               "to_trip_id" => nil,
               "transfer_type" => 0,
               "min_transfer_time" => nil
             }
    end

    test "keeps the stored value of every column on a fully selected row" do
      transfer = %Transfer{
        from_stop_id: "CEN",
        to_stop_id: "CEN",
        from_route_id: "12",
        to_route_id: "24",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 2,
        min_transfer_time: 120
      }

      snapshot = Transfer.audit_snapshot(transfer)

      assert map_size(snapshot) == 8
      assert snapshot["from_route_id"] == "12"
      assert snapshot["to_route_id"] == "24"
      assert snapshot["from_trip_id"] == "12-0815"
      assert snapshot["to_trip_id"] == "24-0840"
      assert snapshot["transfer_type"] == 2
      assert snapshot["min_transfer_time"] == 120
    end
  end

  describe "audit_external_id/1" do
    test "prints the stop pair for a stop-only rule" do
      transfer = %Transfer{from_stop_id: "CEN-A", to_stop_id: "CEN-C", transfer_type: 0}

      assert Transfer.audit_external_id(transfer) == "CEN-A→CEN-C"
    end

    test "adds the route pair when only the from route is set" do
      transfer = %Transfer{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        from_route_id: "12",
        transfer_type: 1
      }

      assert Transfer.audit_external_id(transfer) == "CEN-A→CEN-C route 12→*"
    end

    test "prints stops, routes and trips for a station rule with both sides selected" do
      transfer = %Transfer{
        from_stop_id: "CEN",
        to_stop_id: "CEN",
        from_route_id: "12",
        to_route_id: "24",
        from_trip_id: "12-0815",
        to_trip_id: "24-0840",
        transfer_type: 2
      }

      assert Transfer.audit_external_id(transfer) ==
               "CEN→CEN route 12→24 trip 12-0815→24-0840"
    end

    test "prints a * stop pair for a stopless in-seat row with both trips" do
      transfer = %Transfer{from_trip_id: "A", to_trip_id: "B", transfer_type: 4}

      assert Transfer.audit_external_id(transfer) == "*→* trip A→B"
    end

    test "prints * for a one-sided route and trip selector" do
      transfer = %Transfer{
        from_stop_id: "CEN-A",
        to_stop_id: "CEN-C",
        to_route_id: "24",
        to_trip_id: "24-0840",
        transfer_type: 1
      }

      assert Transfer.audit_external_id(transfer) == "CEN-A→CEN-C route *→24 trip *→24-0840"
    end
  end
end

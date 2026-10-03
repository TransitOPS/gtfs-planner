defmodule GtfsPlanner.Alerts.FeedTest do
  @moduledoc """
  Step 11: `Feed` encodes accepted sanitized snapshots as one GTFS-Realtime feed
  in protobuf and in JSON (AC-10, AC-12, AC-13, CL-7).

  Every expected value below is a literal: a GTFS identifier typed as it appears
  in the source feed, a Unix second worked out by hand, and an enum name spelled
  the way the wire spells it. Nothing here is recomputed through `Feed`, because
  an expectation that is derived from the module under test proves only that the
  module agrees with itself. The protobuf is read back with `Protobuf.decode/2`
  into the generated structs, which is an independent read of the bytes the
  serving step will hand to a rider's client.

  This module needs no database, so it runs `async: true` and touches no
  partition.
  """

  use ExUnit.Case, async: true

  alias GtfsPlanner.Alerts.Feed
  alias GtfsPlanner.Alerts.Publication

  # A fixed header timestamp. Every expectation below is relative to it, and no
  # case reads a clock: `generated_at` is the only time input the module has.
  @generated_at 1_792_000_000

  @entity_id "3f1c9a52-0d6b-4a5e-9c31-6b2f0a7d4e11"
  @other_entity_id "9a0e5f77-2b41-4d18-8e77-1c3d5b9a0f22"

  describe "encode/2 wire shape" do
    test "the header is FULL_DATASET 2.0 at the given instant, with no guessed feed_version" do
      assert {:ok, encoded} = Feed.encode([snapshot()], @generated_at)

      assert %TransitRealtime.FeedMessage{} = message = decode(encoded.pb)

      assert message.header.gtfs_realtime_version == "2.0"
      assert message.header.incrementality == :FULL_DATASET
      assert message.header.timestamp == @generated_at
      # A `feed_version` would have to name the static feed this is derived
      # from. An independently sourced realtime feed has none, so the field is
      # absent rather than guessed.
      assert message.header.feed_version == nil
    end

    test "the entity id is the stable public entity id, never a draft or row identity" do
      assert {:ok, encoded} = Feed.encode([snapshot()], @generated_at)
      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert entity.id == @entity_id
      assert encoded.included == %{@entity_id => 3}
    end

    test "impact periods carry the accepted UTC seconds and an open end stays open" do
      assert {:ok, encoded} =
               Feed.encode(
                 [
                   snapshot(
                     periods: [
                       %{start: 1_791_993_600, end: 1_792_000_800},
                       %{start: 1_792_003_600, end: nil}
                     ]
                   )
                 ],
                 @generated_at
               )

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert entity.alert.impact_period == [
               %TransitRealtime.TimeRange{start: 1_791_993_600, end: 1_792_000_800},
               %TransitRealtime.TimeRange{start: 1_792_003_600, end: nil}
             ]
    end

    test "cause, effect and text are the public values, in the wire's own spelling" do
      assert {:ok, encoded} =
               Feed.encode(
                 [snapshot(effect: :no_service, cause: :weather, cause_detail: "ice")],
                 @generated_at
               )

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)
      alert = entity.alert

      assert alert.effect == :NO_SERVICE
      assert alert.cause == :WEATHER
      assert translation(alert.header_text) == "No service on Route 12"
      assert translation(alert.description_text) == "Crews are clearing ice."
      assert translation(alert.url) == "https://transit.example.org/alerts/route-12"
      assert translation(alert.cause_detail) == "ice"
    end

    test "a cause detail without a cause is dropped rather than published alone" do
      assert {:ok, encoded} =
               Feed.encode([snapshot(cause: nil, cause_detail: "ice")], @generated_at)

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      # Nothing is on the wire, so the decoder reports each field's declared
      # proto2 default rather than nil.
      assert entity.alert.cause == :UNKNOWN_CAUSE
      assert entity.alert.cause_detail == nil
    end

    test "no private authoring or draft field is serialized" do
      assert {:ok, encoded} = Feed.encode([snapshot()], @generated_at)

      json = Jason.decode!(encoded.json)
      text = Jason.encode!(json)

      for private <- [
            "script_key",
            "scriptKey",
            "fact_digest",
            "factDigest",
            "customized",
            "created_by",
            "updated_by",
            "requested_by",
            "organization",
            "gtfs_version",
            "alert_id",
            "source_gtfs_version_id",
            "target_reference",
            "route_stop_pairs",
            "mode_route_type"
          ] do
        refute text =~ private
      end
    end
  end

  describe "encode/2 informed entities" do
    test "a system scope names the captured agencies, never the organization alias" do
      assert {:ok, encoded} =
               Feed.encode(
                 [
                   snapshot(
                     scope: scope(shape: :system, agencies: ["Metro Transit", "Metro Bus"])
                   )
                 ],
                 @generated_at
               )

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert entity.alert.informed_entity == [
               %TransitRealtime.EntitySelector{agency_id: "Metro Transit"},
               %TransitRealtime.EntitySelector{agency_id: "Metro Bus"}
             ]
    end

    test "a route-stop pair stays an intersection in a single selector" do
      assert {:ok, encoded} =
               Feed.encode(
                 [
                   snapshot(
                     scope:
                       scope(
                         shape: :route_stops,
                         route_stops: [
                           %{route_id: "12", stop_id: "STOP1"},
                           %{route_id: "12X", stop_id: "STOP2"}
                         ]
                       )
                   )
                 ],
                 @generated_at
               )

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      # Two selectors, not four: a selector carrying only the route would inform
      # every stop on it, and one carrying only the stop would inform every
      # route serving it.
      assert entity.alert.informed_entity == [
               %TransitRealtime.EntitySelector{route_id: "12", stop_id: "STOP1"},
               %TransitRealtime.EntitySelector{route_id: "12X", stop_id: "STOP2"}
             ]
    end

    test "a mode publishes the explicit route ids it was expanded to, with no route_type" do
      assert {:ok, encoded} =
               Feed.encode(
                 [snapshot(scope: scope(shape: :routes, routes: ["12", "12X"]))],
                 @generated_at
               )

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert entity.alert.informed_entity == [
               %TransitRealtime.EntitySelector{route_id: "12", direction_id: nil},
               %TransitRealtime.EntitySelector{route_id: "12X", direction_id: nil}
             ]

      # A route_type would name every route of that mode, including routes a
      # later static import added, which is a wider alert than one that was
      # accepted.
      refute entity.alert.informed_entity |> Enum.any?(&(&1.route_type != nil))
    end

    test "a chosen direction rides on the route selector it belongs to" do
      assert {:ok, encoded} =
               Feed.encode(
                 [snapshot(scope: scope(shape: :routes, routes: ["12"], direction_id: 1))],
                 @generated_at
               )

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert [%TransitRealtime.EntitySelector{route_id: "12", direction_id: 1}] =
               entity.alert.informed_entity
    end

    test "a dated trip keeps its service date and a frequency trip keeps its start time" do
      assert {:ok, encoded} =
               Feed.encode(
                 [
                   snapshot(
                     scope:
                       scope(
                         shape: :trips,
                         trips: [
                           %{trip_id: "T1", start_date: ~D[2026-10-05], start_time: "08:00:00"},
                           # 25:00:00 is past midnight and is what a
                           # frequency-based trip's first departure can be.
                           %{trip_id: "T2", start_date: ~D[2026-10-06], start_time: "25:00:00"},
                           %{trip_id: "T3", start_date: ~D[2026-10-07], start_time: nil}
                         ]
                       )
                   )
                 ],
                 @generated_at
               )

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert entity.alert.informed_entity == [
               %TransitRealtime.EntitySelector{
                 trip: %TransitRealtime.TripDescriptor{
                   trip_id: "T1",
                   start_date: "20261005",
                   start_time: "08:00:00"
                 }
               },
               %TransitRealtime.EntitySelector{
                 trip: %TransitRealtime.TripDescriptor{
                   trip_id: "T2",
                   start_date: "20261006",
                   start_time: "25:00:00"
                 }
               },
               %TransitRealtime.EntitySelector{
                 trip: %TransitRealtime.TripDescriptor{
                   trip_id: "T3",
                   start_date: "20261007",
                   start_time: nil
                 }
               }
             ]
    end

    test "a scope that names no GTFS identity is refused rather than widened" do
      for scope <- [
            scope(shape: :system, agencies: []),
            scope(shape: :routes, routes: []),
            scope(shape: :stop_all_routes, stops: []),
            scope(shape: :route_stops, route_stops: []),
            scope(shape: :trips, trips: []),
            scope(shape: :unknown_shape, routes: ["12"])
          ] do
        assert {:error, :selector_source_required} =
                 Feed.encode([snapshot(scope: scope)], @generated_at)
      end
    end

    test "a trip without its service date is refused, because the date is its identity" do
      for trip <- [
            %{trip_id: "T1", start_date: nil, start_time: "08:00:00"},
            %{trip_id: "", start_date: ~D[2026-10-05], start_time: "08:00:00"},
            %{trip_id: nil, start_date: ~D[2026-10-05], start_time: nil}
          ] do
        assert {:error, :selector_source_required} =
                 Feed.encode(
                   [snapshot(scope: scope(shape: :trips, trips: [trip]))],
                   @generated_at
                 )
      end
    end

    test "a frequency start time that is not a GTFS clock reading is refused" do
      for start_time <- ["8am", "25:99:00", "-01:00:00", 28_800] do
        trip = %{trip_id: "T1", start_date: ~D[2026-10-05], start_time: start_time}

        assert {:error, :selector_source_required} =
                 Feed.encode(
                   [snapshot(scope: scope(shape: :trips, trips: [trip]))],
                   @generated_at
                 )
      end
    end

    test "a start time is normalized rather than passed through as spelled" do
      trips = [%{trip_id: "T1", start_date: ~D[2026-10-05], start_time: "8:00:00"}]

      assert {:ok, encoded} =
               Feed.encode([snapshot(scope: scope(shape: :trips, trips: trips))], @generated_at)

      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)
      assert [%TransitRealtime.EntitySelector{trip: trip}] = entity.alert.informed_entity
      assert trip.start_time == "08:00:00"
    end
  end

  describe "encode/2 notice and expiry boundaries" do
    test "an alert is omitted until its notice boundary has passed" do
      snapshots = [snapshot(notice_at: @generated_at + 1)]

      assert {:ok, encoded} = Feed.encode(snapshots, @generated_at)
      assert %TransitRealtime.FeedMessage{entity: []} = decode(encoded.pb)
      assert encoded.included == %{}

      # One second later the same accepted snapshot is eligible, with no other
      # change: inclusion is a comparison, not a re-derivation.
      assert {:ok, %{included: %{@entity_id => 3}}} =
               Feed.encode(snapshots, @generated_at + 1)
    end

    test "an alert is omitted once every one of its periods has ended" do
      snapshots = [snapshot(periods: [%{start: 1_791_000_000, end: @generated_at - 1}])]

      assert {:ok, encoded} = Feed.encode(snapshots, @generated_at)
      assert %TransitRealtime.FeedMessage{entity: []} = decode(encoded.pb)
    end

    test "an alert with one ended and one future period is still included" do
      snapshots = [
        snapshot(
          periods: [
            %{start: 1_791_000_000, end: @generated_at - 1},
            %{start: @generated_at + 3_600, end: nil}
          ]
        )
      ]

      assert {:ok, encoded} = Feed.encode(snapshots, @generated_at)
      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      # The ended period stays in the accepted wire content; only the entity's
      # eligibility is decided here.
      assert length(entity.alert.impact_period) == 2
    end

    test "no eligible alert yields a valid empty feed, not a refusal" do
      assert {:ok, encoded} = Feed.encode([], @generated_at)

      assert %TransitRealtime.FeedMessage{entity: [], header: header} =
               message = decode(encoded.pb)

      assert header.gtfs_realtime_version == "2.0"
      assert header.incrementality == :FULL_DATASET
      assert header.timestamp == @generated_at
      assert encoded.included == %{}
      assert byte_size(encoded.pb) > 0
      assert byte_size(encoded.json) > 0
      assert message == %TransitRealtime.FeedMessage{header: header, entity: []}
    end

    test "an ineligible snapshot's own defect never blocks the feed" do
      # A snapshot the moment removes is not encoded at all, so its missing
      # identity cannot stop the alerts that are eligible.
      snapshots = [
        snapshot(notice_at: @generated_at + 60, scope: scope(shape: :trips, trips: [])),
        snapshot(public_entity_id: @other_entity_id)
      ]

      assert {:ok, encoded} = Feed.encode(snapshots, @generated_at)
      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)
      assert entity.id == @other_entity_id
    end
  end

  describe "encode/2 refusals" do
    test "a structurally unusable snapshot is refused" do
      assert {:error, :invalid_snapshot} =
               Feed.encode([snapshot(public_entity_id: "  ")], @generated_at)

      assert {:error, :invalid_snapshot} = Feed.encode([snapshot(periods: [])], @generated_at)

      assert {:error, :invalid_snapshot} = Feed.encode([snapshot(header: "   ")], @generated_at)

      assert {:error, :invalid_snapshot} =
               Feed.encode([snapshot(public_entity_id: nil)], @generated_at)
    end

    test "an effect or cause outside the alert vocabulary is refused, not defaulted" do
      assert {:error, :invalid_snapshot} =
               Feed.encode([snapshot(effect: :napping)], @generated_at)

      assert {:error, :invalid_snapshot} =
               Feed.encode([snapshot(cause: :gremlins)], @generated_at)
    end

    test "two snapshots claiming one public entity id are refused" do
      snapshots = [snapshot(), snapshot(accepted_revision: 4)]

      assert {:error, :invalid_snapshot} = Feed.encode(snapshots, @generated_at)
    end

    test "a generated_at that is not a non-negative instant is refused" do
      assert {:error, :invalid_snapshot} = Feed.encode([snapshot()], "2026-10-05T00:00:00Z")
      assert {:error, :invalid_snapshot} = Feed.encode([snapshot()], -1)
      assert {:error, :invalid_snapshot} = Feed.encode([snapshot()], nil)
    end

    test "the byte ceiling is the documented 16 MiB" do
      assert Feed.max_bytes() == 16 * 1_024 * 1_024
    end
  end

  describe "encode/2 representation agreement" do
    test "the JSON companion carries the same message the protobuf decodes to" do
      snapshots = [
        snapshot(
          effect: :significant_delays,
          cause: :accident,
          scope:
            scope(
              shape: :route_stops,
              route_stops: [%{route_id: "12", stop_id: "STOP1"}]
            )
        ),
        snapshot(
          public_entity_id: @other_entity_id,
          notice_at: @generated_at - 86_400,
          periods: [%{start: 1_791_900_000, end: nil}],
          header: "Station closed",
          scope: scope(shape: :stop_all_routes, stops: ["STOP9"])
        )
      ]

      assert {:ok, encoded} = Feed.encode(snapshots, @generated_at)
      message = decode(encoded.pb)
      json = Jason.decode!(encoded.json)
      header = json["header"]

      assert header["gtfsRealtimeVersion"] == "2.0"
      # 64-bit fields are JSON strings under the canonical protobuf JSON
      # mapping, and a field left at its declared default is omitted rather than
      # written: `FULL_DATASET` is the default of `incrementality`, so an absent
      # key means FULL_DATASET.
      assert header["timestamp"] == "1792000000"
      refute Map.has_key?(header, "incrementality")
      refute Map.has_key?(header, "feedVersion")
      assert length(json["entity"]) == length(message.entity)

      [first, second] = json["entity"]

      assert first["id"] == @entity_id
      assert second["id"] == @other_entity_id
      assert first["alert"]["effect"] == "SIGNIFICANT_DELAYS"
      assert first["alert"]["cause"] == "ACCIDENT"

      assert first["alert"]["headerText"]["translation"] == [
               %{"text" => "No service on Route 12"}
             ]

      assert first["alert"]["impactPeriod"] == [
               %{"start" => "1791993600", "end" => "1792000800"},
               %{"start" => "1792003600"}
             ]

      assert first["alert"]["informedEntity"] == [%{"routeId" => "12", "stopId" => "STOP1"}]
      assert second["alert"]["informedEntity"] == [%{"stopId" => "STOP9"}]
      assert second["alert"]["impactPeriod"] == [%{"start" => "1791900000"}]
    end

    test "the same snapshots and header instant produce byte-identical output" do
      snapshots = [snapshot()]

      assert {:ok, first} = Feed.encode(snapshots, @generated_at)
      assert {:ok, second} = Feed.encode(snapshots, @generated_at)

      assert first.pb == second.pb
      assert first.json == second.json
      assert first.included == second.included
    end
  end

  describe "a private capture reaches the wire" do
    # Feed IDs are exact strings: this one reads as a UUID and is not lower case.
    @uuid_like "ABCDEF00-0000-0000-0000-000000000000"

    test "UUID-looking feed IDs and every frequency instance keep their exact text" do
      capture = %{
        "selectors" => %{
          "shape" => "trips",
          "trips" => [
            capture_trip(@uuid_like, "2026-10-05", "08:00:00"),
            capture_trip(@uuid_like, "2026-10-05", "25:15:00"),
            capture_trip("T-9", "2026-10-06", nil)
          ]
        }
      }

      assert {:ok, scope} = Publication.scope_from_reference(capture)

      assert scope.trips == [
               %{trip_id: @uuid_like, start_date: ~D[2026-10-05], start_time: "08:00:00"},
               %{trip_id: @uuid_like, start_date: ~D[2026-10-05], start_time: "25:15:00"},
               %{trip_id: "T-9", start_date: ~D[2026-10-06], start_time: nil}
             ]

      assert {:ok, encoded} = Feed.encode([snapshot(scope: scope)], @generated_at)
      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert Enum.map(entity.alert.informed_entity, & &1.trip) == [
               %TransitRealtime.TripDescriptor{
                 trip_id: @uuid_like,
                 start_date: "20261005",
                 start_time: "08:00:00"
               },
               %TransitRealtime.TripDescriptor{
                 trip_id: @uuid_like,
                 start_date: "20261005",
                 start_time: "25:15:00"
               },
               %TransitRealtime.TripDescriptor{
                 trip_id: "T-9",
                 start_date: "20261006",
                 start_time: nil
               }
             ]
    end

    test "route, stop and pair captures encode the feed IDs they hold" do
      capture = %{
        "selectors" => %{
          "shape" => "route_stops",
          "route_stops" => [
            %{
              "route_id" => @uuid_like,
              "route_gtfs_id" => @uuid_like,
              "stop_id" => "stop-a",
              "stop_gtfs_id" => "stop-a",
              "resolved" => true
            }
          ]
        }
      }

      assert {:ok, scope} = Publication.scope_from_reference(capture)
      assert scope.route_stops == [%{route_id: @uuid_like, stop_id: "stop-a"}]

      assert {:ok, encoded} = Feed.encode([snapshot(scope: scope)], @generated_at)
      assert %TransitRealtime.FeedMessage{entity: [entity]} = decode(encoded.pb)

      assert entity.alert.informed_entity == [
               %TransitRealtime.EntitySelector{route_id: @uuid_like, stop_id: "stop-a"}
             ]
    end
  end

  defp capture_trip(trip_id, service_date, start_time) do
    %{
      "id" => trip_id,
      "gtfs_id" => trip_id,
      "service_date" => service_date,
      "start_time" => start_time,
      "resolved" => true
    }
  end

  # The generated structs are the independent read of the bytes: `decode/1`
  # goes through the protobuf runtime's own decoder, not back through
  # `Feed.encode/2`.
  defp decode(pb), do: Protobuf.decode(pb, TransitRealtime.FeedMessage)

  defp translation(nil), do: nil

  defp translation(%TransitRealtime.TranslatedString{translation: translations}),
    do: hd(translations).text

  # Literals, not computed values, so a case fails on the wire content rather
  # than on agreement with the encoder.
  defp snapshot(overrides \\ %{}) do
    Map.merge(
      %{
        public_entity_id: @entity_id,
        accepted_revision: 3,
        notice_at: @generated_at - 86_400,
        periods: [
          %{start: 1_791_993_600, end: 1_792_000_800},
          %{start: 1_792_003_600, end: nil}
        ],
        effect: :no_service,
        cause: :other_cause,
        cause_detail: "ice",
        header: "No service on Route 12",
        description: "Crews are clearing ice.",
        url: "https://transit.example.org/alerts/route-12",
        scope: scope()
      },
      Map.new(overrides)
    )
  end

  defp scope(overrides \\ %{}) do
    Map.merge(
      %{
        shape: :routes,
        direction_id: nil,
        agencies: ["Metro Transit"],
        routes: ["12"],
        stops: ["STOP1"],
        route_stops: [],
        trips: []
      },
      Map.new(overrides)
    )
  end
end

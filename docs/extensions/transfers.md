# Transfers Specification

## Overview

`transfers.txt` is an optional GTFS file that defines rules for making connections at transfer points between routes.

**Primary Key:** `from_stop_id`, `to_stop_id`, `from_route_id`, `to_route_id`, `from_trip_id`, `to_trip_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `from_stop_id` | Foreign ID referencing `stops.stop_id` | **Required** | Stop ID that a rider is transferring from. |
| `to_stop_id` | Foreign ID referencing `stops.stop_id` | **Required** | Stop ID that a rider is transferring to. |
| `from_route_id` | Foreign ID referencing `routes.route_id` | Optional | Route ID that a rider is transferring from. |
| `to_route_id` | Foreign ID referencing `routes.route_id` | Optional | Route ID that a rider is transferring to. |
| `from_trip_id` | Foreign ID referencing `trips.trip_id` | Optional | Trip ID that a rider is transferring from. |
| `to_trip_id` | Foreign ID referencing `trips.trip_id` | Optional | Trip ID that a rider is transferring to. |
| `transfer_type` | Enum | **Required** | Type of transfer. Valid options are:<br>`0` or empty - Recommended transfer point between routes.<br>`1` - Timed transfer point between two routes.<br>`2` - Transfer requires a minimum amount of time between arrival and departure.<br>`3` - Transfers are not possible between routes at this location.<br>`4` - In-seat transfer.<br>`5` - Re-boarding transfer. |
| `min_transfer_time` | Non-negative integer | Optional | Minimum time in seconds that must be spent to make a transfer. |

## Reference

- [Official GTFS Specification - transfers.txt](https://gtfs.org/schedule/reference/#transferstxt)

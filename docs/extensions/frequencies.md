# Frequencies Specification

## Overview

`frequencies.txt` is an optional GTFS file that defines frequency-based service (e.g., "every 15 minutes") for a trip.

**Primary Key:** `trip_id`, `start_time`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `trip_id` | Foreign ID referencing `trips.trip_id` | **Required** | Identifies a trip. |
| `start_time` | Time | **Required** | Time at which the first trip departs from its origin stop. |
| `end_time` | Time | **Required** | Time at which the last trip departs from its origin stop. |
| `headway_secs` | Non-negative integer | **Required** | Time in seconds between departures from the same stop (headway) for the trip, during the time interval specified by `start_time` and `end_time`. |
| `exact_times` | Enum | Optional | Indicates if the service is frequency-based or not. Valid options are:<br>`0` or empty - Frequency-based trips.<br>`1` - Schedule-based trips with the exact same headway throughout the day. |

## Reference

- [Official GTFS Specification - frequencies.txt](https://gtfs.org/schedule/reference/#frequenciestxt)

# Timeframes Specification

## Overview

`timeframes.txt` is an optional GTFS file that defines date and time periods to use in fare rules for fares that depend on date and time factors.

**Primary Key:** `timeframe_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `timeframe_group_id` | ID | **Required** | Identifies a group of timeframes. Timeframes with the same `timeframe_group_id` should cover a contiguous period of time, or the same repeating period. |
| `start_time` | Time | Optional | The start time of the timeframe in `HH:MM:SS` format, measured from midnight at the beginning of the service date. |
| `end_time` | Time | Optional | The end time of the timeframe in `HH:MM:SS` format, measured from midnight at the beginning of the service date. |
| `service_id` | Foreign ID referencing `calendar.service_id` or `calendar_dates.service_id` | **Required** | Identifies a set of dates when service is available. |

## Reference

- [Official GTFS Specification - timeframes.txt](https://gtfs.org/schedule/reference/#timeframestxt)

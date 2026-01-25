# Stop Areas Specification

## Overview

`stop_areas.txt` is an optional GTFS file that defines rules to assign stops to areas.

**Primary Key:** `area_id`, `stop_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `area_id` | Foreign ID referencing `areas.area_id` | **Required** | Identifies an area. |
| `stop_id` | Foreign ID referencing `stops.stop_id` | **Required** | Identifies a stop. |

## Reference

- [Official GTFS Specification - stop_areas.txt](https://gtfs.org/schedule/reference/#stop_areastxt)

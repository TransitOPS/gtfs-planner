# Levels Specification

## Overview

`levels.txt` is an optional GTFS file that describes levels in a station. It is useful for describing stations with multiple floors, allowing riders to understand the vertical relationship between stops.

**Primary Key:** `level_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `level_id` | Unique ID | **Required** | Identifies a level. |
| `level_index` | Float | **Required** | Numeric index of the level that indicates relative vertical position. Levels with higher `level_index` values are located above levels with lower `level_index` values. Ground floor should be index 0. |
| `level_name` | Text | Optional | Name of the level as seen by the rider (e.g. "Mezzanine", "B1", "G"). |

## Reference

- [Official GTFS Specification - levels.txt](https://gtfs.org/schedule/reference/#levelstxt)

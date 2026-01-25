# Areas Specification

## Overview

`areas.txt` is an optional GTFS file that defines area groupings of locations, which can be used for zone-based fares.

**Primary Key:** `area_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `area_id` | Unique ID | **Required** | Identifies an area. |
| `area_name` | Text | Optional | The name of the area. |

## Reference

- [Official GTFS Specification - areas.txt](https://gtfs.org/schedule/reference/#areastxt)

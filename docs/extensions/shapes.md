# Shapes Specification

## Overview

`shapes.txt` is an optional GTFS file that defines the vehicle travel path for a trip. Shapes are defined by a sequence of points with latitude and longitude.

**Primary Key:** `shape_id`, `shape_pt_sequence`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `shape_id` | Unique ID | **Required** | Identifies a shape. |
| `shape_pt_lat` | Latitude | **Required** | Latitude of a point in the shape. |
| `shape_pt_lon` | Longitude | **Required** | Longitude of a point in the shape. |
| `shape_pt_sequence` | Non-negative integer | **Required** | Sequence in which the points of the shape are connected. Values must increase along the trip but do not need to be consecutive. |
| `shape_dist_traveled` | Non-negative float | Optional | Actual distance traveled along the associated shape from the first point of the shape to the point specified in this record. This field is used by trip planners to show the distance traveled for a trip segment. |

## Reference

- [Official GTFS Specification - shapes.txt](https://gtfs.org/schedule/reference/#shapestxt)

# Locations Specification (GeoJSON)

## Overview

`locations.geojson` is an optional GTFS file that defines zones for rider pickup or drop-off requests by on-demand services. Unlike other GTFS files, this is a GeoJSON file, not a CSV.

**Format:** GeoJSON FeatureCollection

## Properties

Each Feature in the collection represents a zone and may have the following properties:

| Property Name | Type | Presence | Description |
|---------------|------|----------|-------------|
| `stop_id` | Unique ID | **Conditionally Required** | Identifies the location/zone. Corresponds to `stops.stop_id`. **Required** if `stop_id` is used in other files. |
| `stop_name` | Text | Optional | The name of the location/zone. |
| `stop_desc` | Text | Optional | A description of the location/zone. |
| `zone_id` | ID | Optional | Identifies a fare zone. |
| `stop_url` | URL | Optional | URL of a web page about the location. |
| `parent_station` | Foreign ID referencing `stops.stop_id` | Optional | Defines hierarchy. |
| `stop_timezone` | Timezone | Optional | Timezone of the location. |
| `wheelchair_boarding` | Enum | Optional | Accessibility information. |

## Geometry

The `geometry` of each Feature must be a **Polygon** or **MultiPolygon** defining the boundaries of the zone.

## Reference

- [Official GTFS Specification - locations.geojson](https://gtfs.org/schedule/reference/#locationsgeojson)

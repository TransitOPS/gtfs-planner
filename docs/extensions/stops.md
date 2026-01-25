# Stops Specification

## Overview

`stops.txt` is a **required** GTFS file that defines where vehicles pick up or drop off riders. It also defines stations and station entrances.

**Primary Key:** `stop_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `stop_id` | Unique ID | **Required** | Identifies a stop, station, or station entrance. |
| `stop_name` | Text | Optional | Name of the location. Use a name that people will understand in the local and tourist vernacular. |
| `stop_desc` | Text | Optional | Description of the location that provides the useful, quality information. Do not simply duplicate the name of the location. |
| `stop_lat` | Latitude | Optional | Latitude of the location. |
| `stop_lon` | Longitude | Optional | Longitude of the location. |
| `location_type` | Enum | Optional | Type of the location. Valid options are:<br>`0` or empty - Stop/Platform (Default).<br>`1` - Station.<br>`2` - Entrance/Exit.<br>`3` - Generic Node.<br>`4` - Boarding Area. |
| `parent_station` | Foreign ID referencing `stops.stop_id` | Optional | Defines hierarchy between the different locations defined in `stops.txt`. |
| `wheelchair_boarding` | Enum | Optional | Indicates accessibility of the location. Valid options are:<br>`0` or empty - No accessibility information.<br>`1` - Accessible.<br>`2` - Not accessible. |
| `level_id` | Foreign ID referencing `levels.level_id` | Optional | Level of the location. |
| `platform_code` | Text | Optional | Platform identifier for a platform stop (a stop belonging to a station). |

## Reference

- [Official GTFS Specification - stops.txt](https://gtfs.org/schedule/reference/#stopstxt)
# Pathways Specification

## Overview

`pathways.txt` is an optional GTFS file that describes the pathways linking together stops, platforms, and station entrances/exits. It is used to provide detailed navigation instructions for riders within stations.

**Primary Key:** `pathway_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `pathway_id` | Unique ID | **Required** | Identifies a pathway. |
| `from_stop_id` | Foreign ID referencing `stops.stop_id` | **Required** | The stop_id of the location where the pathway begins. |
| `to_stop_id` | Foreign ID referencing `stops.stop_id` | **Required** | The stop_id of the location where the pathway ends. |
| `pathway_mode` | Enum | **Required** | Type of pathway. Valid options are:<br>`1` - Walkway<br>`2` - Stairs<br>`3` - Moving Sidewalk<br>`4` - Escalator<br>`5` - Elevator<br>`6` - Fare Gate<br>`7` - Exit Gate |
| `is_bidirectional` | Boolean | Optional | Indicates whether the pathway can be used in both directions. Valid options are:<br>`0` - Unidirectional (travel allowed only from `from_stop_id` to `to_stop_id`).<br>`1` - Bidirectional (travel allowed in both directions) (Default). |
| `length` | Non-negative float | Optional | Horizontal length in meters of the pathway. |
| `traversal_time` | Non-negative integer | Optional | Average time in seconds needed to traverse the pathway. |
| `stair_count` | Non-negative integer | Optional | Number of stairs in the pathway. |
| `max_slope` | Float | Optional | Maximum slope ratio of the pathway. |
| `min_width` | Non-negative float | Optional | Minimum width of the pathway in meters. |
| `signposted_as` | Text | Optional | String of text that is displayed to riders on signage at the start of the pathway. |
| `reversed_signposted_as` | Text | Optional | String of text that is displayed to riders on signage at the end of the pathway (if bidirectional). |

## Reference

- [Official GTFS Specification - pathways.txt](https://gtfs.org/schedule/reference/#pathwaystxt)

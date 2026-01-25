# Networks Specification

## Overview

`networks.txt` is an optional GTFS file that defines network groupings of routes.

**Primary Key:** `network_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `network_id` | Unique ID | **Required** | Identifies a network. |
| `network_name` | Text | Optional | The name of the network. |

## Reference

- [Official GTFS Specification - networks.txt](https://gtfs.org/schedule/reference/#networkstxt)

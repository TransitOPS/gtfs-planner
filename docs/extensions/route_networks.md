# Route Networks Specification

## Overview

`route_networks.txt` is an optional GTFS file that defines rules to assign routes to networks.

**Primary Key:** `network_id`, `route_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `network_id` | Foreign ID referencing `networks.network_id` | **Required** | Identifies a network. |
| `route_id` | Foreign ID referencing `routes.route_id` | **Required** | Identifies a route. |

## Reference

- [Official GTFS Specification - route_networks.txt](https://gtfs.org/schedule/reference/#route_networkstxt)

# Fare Rules Specification

## Overview

`fare_rules.txt` is an optional GTFS file that specifies how fares in `fare_attributes.txt` apply to an itinerary.

**Primary Key:** `fare_id`, `route_id`, `origin_id`, `destination_id`, `contains_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `fare_id` | Foreign ID referencing `fare_attributes.fare_id` | **Required** | Identifies a fare. |
| `route_id` | Foreign ID referencing `routes.route_id` | Optional | Route to which the fare applies. |
| `origin_id` | ID | Optional | Fare zone ID that an itinerary can start in. |
| `destination_id` | ID | Optional | Fare zone ID that an itinerary can end in. |
| `contains_id` | ID | Optional | Fare zone ID that an itinerary can pass through. |

## Reference

- [Official GTFS Specification - fare_rules.txt](https://gtfs.org/schedule/reference/#fare_rulestxt)

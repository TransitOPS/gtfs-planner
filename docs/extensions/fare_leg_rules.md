# Fare Leg Rules Specification

## Overview

`fare_leg_rules.txt` is an optional GTFS file that provides fare rules for individual legs of travel, offering a more detailed method for modeling fare structures.

**Primary Key:** `network_id`, `from_area_id`, `to_area_id`, `fare_product_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `leg_group_id` | ID | Optional | Groups legs of travel that have the same fare rules. |
| `network_id` | Foreign ID referencing `networks.network_id` | Optional | Identifies the network for this rule. |
| `from_area_id` | Foreign ID referencing `areas.area_id` | Optional | Identifies the origin area. |
| `to_area_id` | Foreign ID referencing `areas.area_id` | Optional | Identifies the destination area. |
| `from_timeframe_group_id` | Foreign ID referencing `timeframes.timeframe_group_id` | Optional | Identifies the timeframe for the start of the leg. |
| `to_timeframe_group_id` | Foreign ID referencing `timeframes.timeframe_group_id` | Optional | Identifies the timeframe for the end of the leg. |
| `fare_product_id` | Foreign ID referencing `fare_products.fare_product_id` | **Required** | Identifies the fare product that applies. |
| `rule_priority` | Integer | Optional | Priority of the rule. Lower values indicate higher priority. |

## Reference

- [Official GTFS Specification - fare_leg_rules.txt](https://gtfs.org/schedule/reference/#fare_leg_rulestxt)

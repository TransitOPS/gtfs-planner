# Fare Transfer Rules Specification

## Overview

`fare_transfer_rules.txt` is an optional GTFS file that provides fare rules for transfers between legs of travel.

**Primary Key:** `from_leg_group_id`, `to_leg_group_id`, `fare_product_id`, `transfer_count`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `from_leg_group_id` | Foreign ID referencing `fare_leg_rules.leg_group_id` | Optional | The `leg_group_id` of the leg from which the transfer originates. |
| `to_leg_group_id` | Foreign ID referencing `fare_leg_rules.leg_group_id` | Optional | The `leg_group_id` of the leg to which the transfer is made. |
| `transfer_count` | Integer | Optional | The sequential number of the transfer (e.g. 1 for the first transfer). |
| `duration_limit` | Integer | Optional | The maximum duration in seconds allowed for the transfer. |
| `duration_limit_type` | Enum | Optional | Defines how `duration_limit` is measured. Valid options are:<br>`0` - Between departure of previous leg and arrival of next leg.<br>`1` - Between departure of previous leg and departure of next leg.<br>`2` - Between arrival of previous leg and departure of next leg.<br>`3` - Between arrival of previous leg and arrival of next leg. |
| `fare_transfer_type` | Enum | **Required** | Indicates the cost of the transfer. Valid options are:<br>`0` - First leg cost + transfer cost + second leg cost.<br>`1` - First leg cost + transfer cost.<br>`2` - Transfer cost + second leg cost. |
| `fare_product_id` | Foreign ID referencing `fare_products.fare_product_id` | Optional | Identifies the fare product that applies to the transfer. |

## Reference

- [Official GTFS Specification - fare_transfer_rules.txt](https://gtfs.org/schedule/reference/#fare_transfer_rulestxt)

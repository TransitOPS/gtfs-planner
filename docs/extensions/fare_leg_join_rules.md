# Fare Leg Join Rules Specification

## Overview

`fare_leg_join_rules.txt` is an optional GTFS file that defines rules for when two or more legs should be considered as a single effective fare leg for the purposes of matching against rules in `fare_leg_rules.txt`.

**Primary Key:** `from_leg_group_id`, `to_leg_group_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `from_leg_group_id` | Foreign ID referencing `fare_leg_rules.leg_group_id` | **Required** | The `leg_group_id` of the first leg in the join. |
| `to_leg_group_id` | Foreign ID referencing `fare_leg_rules.leg_group_id` | **Required** | The `leg_group_id` of the second leg in the join. |
| `limit_amount` | Currency amount | Optional | The cost limit for the joined legs. |
| `limit_currency` | Currency code | Optional | The currency of the limit. |

## Reference

- [Official GTFS Specification - fare_leg_join_rules.txt](https://gtfs.org/schedule/reference/#fare_leg_join_rulestxt)

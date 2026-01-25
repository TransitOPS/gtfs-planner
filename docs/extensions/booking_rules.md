# Booking Rules Specification

## Overview

`booking_rules.txt` is an optional GTFS file that defines booking rules for rider-requested services.

**Primary Key:** `booking_rule_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `booking_rule_id` | Unique ID | **Required** | Identifies a booking rule. |
| `booking_type` | Enum | **Required** | Indicates the type of booking. Valid options are:<br>`0` - Real-time booking (No booking required).<br>`1` - Same-day booking with optional advance notice.<br>`2` - Prior-day booking (Booking required). |
| `prior_notice_duration_min` | Integer | **Conditionally Required** | The minimum number of minutes before a trip's scheduled departure that a booking must be made. **Required** for `booking_type=1`. |
| `prior_notice_duration_max` | Integer | Optional | The maximum number of minutes before a trip's scheduled departure that a booking can be made. |
| `prior_notice_last_day` | Integer | **Conditionally Required** | The last day relative to the service day that a booking can be made. **Required** when `booking_type=2`. |
| `prior_notice_last_time` | Time | **Conditionally Required** | The last time of day that a booking can be made on the `prior_notice_last_day`. **Required** when `booking_type=2`. |
| `prior_notice_start_day` | Integer | Optional | The first day relative to the service day that a booking can be made. |
| `prior_notice_start_time` | Time | **Conditionally Required** | The first time of day that a booking can be made on the `prior_notice_start_day`. **Required** when `prior_notice_start_day` is set. |
| `phone_number` | Phone number | Optional | Phone number to call to make the booking. |
| `info_url` | URL | Optional | URL to a web page with information about booking. |
| `booking_url` | URL | Optional | URL to a web application to make the booking. |

## Reference

- [Official GTFS Specification - booking_rules.txt](https://gtfs.org/schedule/reference/#booking_rulestxt)

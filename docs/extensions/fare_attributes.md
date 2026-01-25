# Fare Attributes Specification

## Overview

`fare_attributes.txt` is an optional GTFS file that defines fare information.

**Primary Key:** `fare_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `fare_id` | Unique ID | **Required** | Identifies a fare. |
| `price` | Currency amount | **Required** | Fare price. |
| `currency_type` | Currency code | **Required** | Currency type. |
| `payment_method` | Enum | **Required** | Payment method. Valid options are:<br>`0` - Fare is paid on board.<br>`1` - Fare must be paid before boarding. |
| `transfers` | Enum | **Required** | Number of transfers permitted. Valid options are:<br>`0` - No transfers permitted.<br>`1` - 1 transfer permitted.<br>`2` - 2 transfers permitted.<br>`empty` - Unlimited transfers permitted. |
| `agency_id` | Foreign ID referencing `agency.agency_id` | Optional | Agency to which the fare applies. |
| `transfer_duration` | Non-negative integer | Optional | Length of time in seconds that a transfer is valid. |

## Reference

- [Official GTFS Specification - fare_attributes.txt](https://gtfs.org/schedule/reference/#fare_attributestxt)

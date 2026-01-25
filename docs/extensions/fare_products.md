# Fare Products Specification

## Overview

`fare_products.txt` is an optional GTFS file that describes the different types of tickets or fares that can be purchased by riders.

**Primary Key:** `fare_product_id`, `fare_media_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `fare_product_id` | Unique ID | **Required** | Identifies a fare product. |
| `fare_product_name` | Text | **Required** | The name of the fare product (e.g., "Single Ride", "Day Pass", "Monthly Pass"). |
| `fare_media_id` | Foreign ID referencing `fare_media.fare_media_id` | **Conditionally Required** | Identifies the fare media needed to use this fare product. **Required** if the fare product requires a specific media. |
| `amount` | Currency amount | **Required** | The price of the fare product. |
| `currency` | Currency code | **Required** | The currency of the fare product in ISO 4217 format. |
| `rider_category_id` | Foreign ID referencing `rider_categories.rider_category_id` | Optional | Identifies the rider category eligible for this fare product. |
| `bundle_amount` | Integer | Optional | Number of units purchased in the bundle (e.g. 10 for a 10-ride ticket). |
| `duration_start` | Enum | Optional | Event triggering the start of the product's validity. Valid options are:<br>`0` - At purchase.<br>`1` - At activation/first use. |
| `duration_amount` | Integer | Optional | Duration of validity. |
| `duration_unit` | Enum | Optional | Unit of duration. Valid options are:<br>`0` - Seconds.<br>`1` - Minutes.<br>`2` - Hours.<br>`3` - Days. |

## Reference

- [Official GTFS Specification - fare_products.txt](https://gtfs.org/schedule/reference/#fare_productstxt)

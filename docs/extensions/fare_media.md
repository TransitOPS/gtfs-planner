# Fare Media Specification

## Overview

`fare_media.txt` is an optional GTFS file that describes the fare media that can be employed to use fare products.

**Primary Key:** `fare_media_id`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `fare_media_id` | Unique ID | **Required** | Identifies a fare media. |
| `fare_media_name` | Text | **Required** | The name of the fare media (e.g., "Cash", "Contactless Card", "Mobile App"). |
| `fare_media_type` | Enum | **Required** | The type of fare media. Valid options are:<br>`0` - None (e.g. cash, token).<br>`1` - Paper ticket.<br>`2` - Magstripe paper ticket.<br>`3` - Transit card (e.g. Clipper, Oyster).<br>`4` - cEMV (contactless Eurocard, Mastercard, Visa).<br>`5` - Mobile app.<br>`6` - Other. |

## Reference

- [Official GTFS Specification - fare_media.txt](https://gtfs.org/schedule/reference/#fare_mediatxt)

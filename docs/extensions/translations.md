# Translations Specification

## Overview

`translations.txt` is an optional GTFS file that provides translations for fields in other GTFS files.

**Primary Key:** `table_name`, `field_name`, `language`, `record_id`, `record_sub_id`, `field_value`

## Fields

| Field Name | Type | Presence | Description |
|------------|------|----------|-------------|
| `table_name` | Text | **Required** | Name of the table that contains the field to be translated. |
| `field_name` | Text | **Required** | Name of the field to be translated. |
| `language` | Language code | **Required** | Language of the translation. |
| `translation` | Text | **Required** | Translated value of the field. |
| `record_id` | ID | **Conditionally Required** | ID of the record to be translated. |
| `record_sub_id` | ID | Optional | Sub-ID of the record to be translated. |
| `field_value` | Text | **Conditionally Required** | Value of the field to be translated. |

## Reference

- [Official GTFS Specification - translations.txt](https://gtfs.org/schedule/reference/#translationstxt)

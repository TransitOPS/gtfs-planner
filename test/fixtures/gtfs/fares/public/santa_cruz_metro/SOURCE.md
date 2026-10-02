# Santa Cruz METRO fare excerpt

- Feed: Santa Cruz METRO, Mobility Database `mdb-2425`.
- Download URL: https://developer.scmetro.org/gtfs.zip
- Downloaded: 2026-09-30
- Kept files: `agency.txt`, `feed_info.txt`, `calendar.txt`, `calendar_dates.txt`, `rider_categories.txt`, `fare_products.txt`, `fare_leg_rules.txt`.
- Trimmed to: the fare files, the routes and stops they reference, and the
  calendar the leg rules' timeframes name. Rows are copied byte for byte;
  `routes.txt` and `stops.txt` are the only rewritten files, and they keep the
  original header order. Trips, stop times, shapes and transfers are left out.

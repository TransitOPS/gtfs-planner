# OTP Local Artifacts

These files are required for manual end-to-end graph build testing from the Export page:

- `opentripplanner.jar` (OTP shaded jar, expected by `OTP_JAR_PATH`)
- `region.osm.pbf` (OSM extract, expected by `OTP_OSM_PATH`)

Validate your local setup with:

```bash
mix gtfs.otp.check --create-dir
```

This directory is intentionally kept in git, but large binaries are ignored.

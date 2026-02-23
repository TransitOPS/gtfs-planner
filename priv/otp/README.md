# OTP Local Artifacts

These files are required for manual end-to-end graph build testing from the Export page:

- `opentripplanner.jar` (OTP shaded jar, expected by `OTP_JAR_PATH`)
- `region.osm.pbf` (OSM extract, expected by `OTP_OSM_PATH`)

Validate your local setup with:

```bash
mix gtfs.otp.check --create-dir
```

Download missing local artifacts automatically:

```bash
mix gtfs.otp.install
```

Use custom sources if needed:

```bash
mix gtfs.otp.install --jar-url <otp_jar_url> --osm-url <osm_pbf_url>
```

This directory is intentionally kept in git, but large binaries are ignored.

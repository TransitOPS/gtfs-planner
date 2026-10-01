# Notice for `sample-feed.zip`

`sample-feed.zip` is a modified copy of Google's GTFS example feed. It is checked in
only as a test fixture for the user-experience QA scenarios.

## Source

- Repository: <https://github.com/google/transit> (Google, `master`)
- Path: `gtfs/spec/en/examples/sample-feed-1.zip`
- Upstream commit: `3c9e7b904b5035349622f03e11851e25c16d1d99`
- Upstream zip SHA-256:
  `46404f91b8f852bf1037f7901abc215d91d1bbe2a4362c5b02a3f9ced53c8d65`
- This zip's SHA-256:
  `432e348e78f86efd2ff01082122ff2fb6f58734aa27d8b33b95a5ef28d772448`

`sample-feed-1.zip` is a derived artifact of the `gtfs/spec/en/examples/` files in that
repository; the examples directory has no README of its own, and
`gtfs/spec/en/examples/README.md` states no separate terms for the feed. The
repository root `LICENSE` at the same commit is the Apache License, Version 2.0, and it
covers these files.

## License

Licensed under the Apache License, Version 2.0 (the "License"); you may not use these
files except in compliance with the License. You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed under
the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
KIND, either express or implied. See the License for the specific language governing
permissions and limitations under the License.

## Modifications

This copy differs from the upstream zip in three ways; every other file is
byte-identical to the upstream one.

1. `stop_times.txt`: the header field `drop_off_time` is renamed to `drop_off_type`, and
   every data row is padded with empty trailing fields so that all 28 rows carry the
   same 9 fields as the header. Upstream mixes 5-field and 9-field rows, which the
   importer rejects as wrong field counts.
2. `shapes.txt` is removed. Upstream ships a header row and no data rows.
3. `calendar.txt` and `calendar_dates.txt`: every date is advanced by 7,000 days
   (1,000 weeks, so weekdays are unchanged). `20070101` becomes `20260302`, `20101231`
   becomes `20300301` and `20070604` becomes `20260803`. Upstream calendars ended on
   2010-12-31, so a planner would report the service as ended.

## About the sample data

The data is fictional. Stop names end in "(Demo)" and the agency is
"Demo Transit Authority" in `America/Los_Angeles`. It describes no real agency, route,
stop or schedule.

## Regenerating

After 2030-03-01, add a further multiple of 7 days to every date in `calendar.txt` and
`calendar_dates.txt` so the calendars stay in the future, and record the new upstream and
fixture SHA-256 values above. Change nothing else, or the scenarios' expected row counts
stop matching the feed.

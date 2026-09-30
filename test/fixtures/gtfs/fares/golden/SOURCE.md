# Fare export goldens

These files are the unmanaged full-export bytes AC-3 compares a version against.
They were produced by `test/support/fares_golden.exs` on the revision that added
the fare fixtures, whose parent is `2f9093536af22c6cc872e38ea58adaf54d35f1d6`
("fix(schedules): refuse undo when a timing's stop rules changed"). The only
production change that step made to the export is the `calendar_dates.txt` row
order described below, so the export code these bytes came from is the code at
that parent revision.

Each file is one entry of the `:full` export ZIP for the fixture of the same name
under `test/fixtures/gtfs/fares/`, imported through the production importer into a
sandbox version that is published before the export runs. One directory per
fixture: the North Coast v1 and v2 feeds, the no-fare feed, the three refused
variants and the trimmed public excerpts.

`public/ctran` had no golden on the revision that added the fixtures. C-TRAN
publishes one product id per rider category and medium, which the then-current
`fare_products` unique key (`fare_product_id`, `fare_media_id`) rejected, so the
importer refused the excerpt. The widened key that admits rider categories
landed with `20260930205949_fare_schema_corrections`, and `public/ctran` was
recorded on that revision. No other entry's bytes changed on it, because the
migration touches no export code.

## Regenerating and checking

Record the goldens on a revision that does not change export bytes:

```txt
MIX_ENV=test MIX_TEST_PARTITION=_s29 gtimeout --signal=TERM --kill-after=10s 300s mix run test/support/fares_golden.exs
```

Check them, which fails on a missing, extra or different entry:

```txt
MIX_ENV=test MIX_TEST_PARTITION=_s29 gtimeout --signal=TERM --kill-after=10s 300s mix run test/support/fares_golden.exs --check
```

`calendar_dates.txt` needed an explicit export order before the goldens were
byte-stable: one service carries many exception dates, and ordering the file by
`service_id` alone left tied rows in heap order, so a re-imported feed exported
differently each run. `GtfsPlanner.Gtfs.Export.StreamBuilder` now orders
`calendar_dates` by `service_id`, `date` and `exception_type`.

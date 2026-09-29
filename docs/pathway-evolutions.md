# Scheduled pathway closures

A scheduled closure removes one station pathway from the network for a
service-time window on every service date of a native calendar. Closures are
authored in Pathways Studio and exchanged with a GTFS feed through
`pathway_evolutions.txt`.

## Supported interchange subset

The supported header is:

    pathway_id,service_id,start_time,end_time,is_closed

`direction` is an optional sixth column. The supported profile accepts only
`is_closed=1` with a blank or absent `direction`, an explicit `service_id` and
both times present. Opening rows (`is_closed=0`) and per-direction rows
(`direction=0` or `direction=2`) are not part of the supported subset: a closure
removes both directions of a bidirectional pathway, so there is no closing row
to import and no opening row to un-close one. Remove a closure by deleting its
row and re-importing, or by editing it in Pathways Studio.

Times are GTFS service-day values, not clock values. `H:MM:SS` is the exported
form and is always accepted; `H:MM` and `HH:MM` are also accepted on import. A
window may continue past midnight by using a value above `24:00:00`, so
`23:00:00,26:00:00` is a valid overnight window. A window whose end is not later
than its start is rejected, so `23:00:00,02:00:00` is not a wrap-around window:
enter `23:00:00,26:00:00` instead.

A daytime row and an overnight row for the same pathway and calendar:

    pathway_id,service_id,start_time,end_time,is_closed
    PW1,WK,09:00:00,15:00:00,1
    PW1,WK,23:00:00,26:00:00,1

## References

`pathway_id` must name a pathway already present in the target version, and
`service_id` must name a service with at least one `calendar.txt` or
`calendar_dates.txt` row in that version. A service that exists only in
`calendar_attributes.txt` has no native calendar row and is not a valid closure
reference. A calendar with no currently active dates is still a valid reference;
its empty state is disclosed rather than refused.

Both references are resolved inside the importing organization and version. A
pathway or service that exists only in another organization, or in another
version of the same organization, does not resolve.

The same `(pathway_id, service_id, start_time, end_time)` tuple may appear once.
A repeated tuple is refused, whether the repeat is later in the same file, in a
second copy of the file, or already stored in the target version. Overlapping
but non-identical windows are allowed; they combine into one closed period.

## Rejection codes

The first rejected row fails the import in phase one. No closure is stored, no
version is published, and the import run records the file, the CSV row number
and one code. The run record never stores the row's values.

| Code | Cause | Fix |
|---|---|---|
| `evolution_pathway_required` | `pathway_id` is blank | Name the pathway, using the exact `pathway_id` from `pathways.txt`. |
| `evolution_service_required` | `service_id` is blank | Name the calendar, using the exact `service_id` from `calendar.txt` or `calendar_dates.txt`. |
| `evolution_opening_unsupported` | `is_closed` is not `1` | Remove the opening row. This file cannot reopen a pathway. |
| `evolution_direction_unsupported` | `direction` has a value | Leave `direction` blank or remove the column. A closure removes both directions. |
| `evolution_time_invalid` | A time is unreadable, blank, or the end is not later than the start | Use `H:MM:SS` with the end above the start; use a value above `24:00:00` for a window that continues past midnight. |
| `evolution_pathway_missing` | No pathway with that `pathway_id` exists in the target version | Import `pathways.txt` in the same feed, or correct the `pathway_id`. |
| `evolution_service_missing` | The service has no `calendar.txt` or `calendar_dates.txt` row in the target version | Import the calendar file in the same feed, or correct the `service_id`. |
| `evolution_duplicate` | The same pathway, service and window already appears in this import or in the target version | Remove the repeated row, or give the two closures different windows. |

A structural CSV problem (a header the file cannot carry, a quoting error, an
encoding error) is reported with the parser's own reason instead of one of the
codes above, together with the same file and row.

## Import, saving and recovery

`pathway_evolutions.txt` is registered in the phase-one manifest immediately
after `pathways.txt`, so a closure may reference a pathway or calendar that the
same import created.

A full feed is imported into a fresh unpublished version. Nothing is published
until the whole import succeeds. A closure saved in Pathways Studio changes the
published version immediately: there is no draft, so the next full export
already carries the closure.

A failure in a later import phase, such as `stop_times.txt`, leaves the version
unpublished. Discarding that failed version deletes its closures before its
pathways, so the closure's reference to a pathway never blocks the cleanup, and
only the failed version is removed. Unrecognized files in the upload are still
listed as unrecognized; registering `pathway_evolutions.txt` does not silence
warnings for other files.

## Station merge

Station merge builds its review normally from an upload that contains
`pathway_evolutions.txt` and does not apply the file. The review shows
"pathway_evolutions.txt is not applied by station merge. Existing scheduled
closures are unchanged." Apply a station merge, and scheduled closures are
untouched. Manage closures through a full import or through the Closures tab.

## Export

A full export of a version with scheduled closures includes
`pathway_evolutions.txt`, with the header
`pathway_id,service_id,start_time,end_time,is_closed,direction`, rows ordered by
`pathway_id`, `service_id`, `start_time` and `end_time`, times as `HH:MM:SS`
with hours at or above 24 kept, `is_closed` as `1` and `direction` empty. The
Operations export inherits the full export's file list, so it carries the same
closure rows alongside its usual outputs. A version with no closures produces
the same file list as before.

The Pathways export and the companion API export are unchanged. They do not
include closures. The Export page says so when a version has closures, because
their file names and contents stay exactly what they are.

## Extension status

The scheduled-closure fields in the supplied extension are the supported-profile
intent. The app implements that subset itself; the supplied extension is not
adopted, and no downstream feed producer is known to emit this file. A file that
does not match the supported subset is refused with a code rather than
partially applied, so a producer that ships a wider profile needs this app's
supported header first.

## Analysis limits

The Closures tab and the analysis results are bounded by fixed local limits,
not by feed size. A range check covers at most 31 requested service days, at
most 100,000 candidate service dates, and at most 200,000 service-day closure
instances. Time-aware evaluation needs exactly one valid agency timezone;
conflicting agency timezones are refused with that reason, and the results are
computed in the agency's zone rather than in a UTC fallback. A limit that is
reached is reported as a limit, never as a complete answer that found nothing.
A result is recomputed on every request and is never cached or pushed to
subscribers.

## Compatibility note

The external MobilityData GTFS validator is unchanged. It still exports the
version and runs its own checks on the archive, it does not know this file, and
nothing about its inputs, filtering, output or warnings is changed to
accommodate closures.

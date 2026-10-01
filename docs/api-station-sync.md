# Station sync API

Use a bearer session with an active Pathways Studio editor membership. Select the organization with `X-Organization-Id` when the user belongs to more than one organization. Fetch `GET /api/v1/versions/:version_id/stations/:station_id/bundle` before editing; each pathway in the bundle has an integer `revision`.

Send edits to `POST /api/v1/versions/:version_id/stations/:station_id/sync` as JSON. `pathways` is required and may be empty. Each pathway object needs its UUID `id` and the exact integer `revision` from the bundle, at least 1. Editable fields are `traversal_time`, `stair_count`, `min_width`, `signposted_as`, `reversed_signposted_as`, `field_notes`, and `field_completed_at`. The `from_stop_id` and `to_stop_id` pair may be included unchanged or swapped to reverse direction; neither endpoint can be independently changed. Other pathway fields are ignored. No compatibility path accepts edits without revisions.

At most 100 pathways and 100 journal entries may be sent in one request. A pathway ID may appear only once. Oversize or duplicate pathway envelopes and excess journal entries return HTTP 400 before any entry is written. The endpoint uses Plug.Parsers' default 8,000,000-byte request-body read limit (`:length` is unset); a larger body returns HTTP 413 before the controller runs. `journal_entries` is optional and retains its existing target, validation, and per-entry sync behavior.

Pathways are processed in request order. Each entry is an independent transaction with a current editor check, a station-scoped revision check, and its change log. Successful entries return the new revision in `data.revisions`. Entry errors return in `data.errors`; HTTP status remains 200 for this mixed outcome. A stale or invalid entry does not prevent later valid entries. If editor access is revoked during the request, that entry and every remaining pathway entry return `forbidden` without further pathway writes. Earlier successful entries remain committed. A request rejected by the authorization plug before processing returns HTTP 403 instead.

## Successful sync

Request (IDs are examples):

```json
{"pathways":[{"id":"11111111-1111-4111-8111-111111111111","revision":3,"traversal_time":45}],"journal_entries":[]}
```

Response (200):

```json
{"data":{"synced_count":1,"revisions":[{"id":"11111111-1111-4111-8111-111111111111","revision":4}],"journal_synced_count":0,"synced_at":"2026-09-30T12:00:00Z"}}
```

## Stale or replayed revision

Resending the same request after it succeeded does not write a second change log. The server reports its current revision:

```json
{"data":{"synced_count":0,"revisions":[],"synced_at":"2026-09-30T12:00:01Z","errors":[{"id":"11111111-1111-4111-8111-111111111111","code":"stale","message":"This pathway changed on the server.","current_revision":4}]}}
```

## Missing or invalid revision

A missing revision, string such as `"3"`, zero, or negative number produces a per-entry error without a pathway write:

```json
{"data":{"synced_count":0,"revisions":[],"synced_at":"2026-09-30T12:00:01Z","errors":[{"id":"11111111-1111-4111-8111-111111111111","code":"invalid_revision","message":"Revision must be an integer of at least 1."}]}}
```

## Oversize request

A request with 101 pathway entries returns HTTP 400 with `bad_request` and `"Request may include at most 100 pathways."`. A body of 8,000,001 bytes returns HTTP 413 before sync begins. Split large work into bounded requests, each with fresh revisions.

## Revoked editor

If editor access is revoked between pathway entries, the first refused entry and all later pathway entries report `forbidden` with `"Editor access was revoked."` under `data.errors` (HTTP 200). Earlier successes and their returned revisions remain valid. An actor who lacks editor access when the request reaches the authorization plug receives HTTP 403 with `{"error":{"code":"forbidden"}}`.

Other per-entry pathway codes are `invalid_id`, `not_found`, `invalid_endpoints`, and `validation_error`. A malformed top-level `pathways` or `journal_entries` value returns HTTP 400. A missing or out-of-scope station returns HTTP 404 after envelope validation. Journal errors keep their existing `invalid_id`, `invalid_target`, `id_conflict`, and `validation_error` codes.

If the client loses the response, fetch a fresh bundle before retrying. Compare the server's values and revisions with the intended edits, then submit only changes still needed with the fresh revisions. Do not blindly replay the old body: earlier entries may have committed even when the response was lost.

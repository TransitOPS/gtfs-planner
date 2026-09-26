# Pathways Export API

Request, observe and download the **pathways export** of one published GTFS version
through the companion API, without opening the web editor.

The export is asynchronous: a request creates or reuses a durable run, the run
builds in the background, and the stored ZIP becomes downloadable only when the run
reaches `ready`. Any active member of the organization can use these routes; no
editor role is required.

Related documents: [API Authentication](api-authentication.md) for login, bearer
tokens and organization selection.

## Routes

| Method | Path | Purpose |
| --- | --- | --- |
| `POST` | `/api/v1/versions/{version_id}/pathways-exports` | Request the export (or reuse the active run) |
| `GET` | `/api/v1/versions/{version_id}/pathways-exports/{export_id}` | Read the current lifecycle state |
| `GET` | `/api/v1/versions/{version_id}/pathways-exports/{export_id}/download` | Download the stored ZIP |

All three routes sit behind the same session pipeline as the other companion routes:

```http
Authorization: Bearer <api-session-token>
X-Organization-Id: <organization-uuid>   # required when the user has more than one membership
Accept: application/json
```

`X-Organization-Id` is optional when the user belongs to exactly one organization.
Omitting it while the user has several memberships returns `403`
`organization_required`; a value that is not a UUID returns `400 bad_request`.
The organization always comes from the authenticated session, never from a body
field or query parameter.

## 1. Log in

```bash
TOKEN=$(curl -s -X POST http://localhost:4000/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"member@example.com","password":"your-password"}' \
  | jq -r '.data.token')
```

## 2. Choose a published version

```bash
curl -s http://localhost:4000/api/v1/versions \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Organization-Id: $ORG_ID" \
  -H 'Accept: application/json'
```

Only **published** versions are listed and only published versions are accepted by
the export routes. A staging, importing or failed version returns `404`.

## 3. Request the export

```bash
curl -i -X POST "http://localhost:4000/api/v1/versions/$VERSION_ID/pathways-exports" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Organization-Id: $ORG_ID" \
  -H 'Accept: application/json'
```

Response — `202 Accepted`, with a `Location` header pointing at the status resource:

```http
HTTP/1.1 202 Accepted
Location: /api/v1/versions/6f2f.../pathways-exports/1c9d...
Content-Type: application/json

{
  "data": {
    "id": "1c9d...",
    "version_id": "6f2f...",
    "export_type": "pathways",
    "state": "pending",
    "failure_code": null,
    "created_at": "2026-09-26T17:39:13.855106Z",
    "finished_at": null,
    "expires_at": null,
    "size_bytes": null,
    "sha256": null,
    "download_path": null
  }
}
```

The `state` in this response is a **snapshot**. The build may already have moved on.
A request made while a run is `pending` or `building` returns the **same** run id. A
request made after that run has finished, including after it became `ready`, starts
a new build. A pathways build often finishes within seconds, so a repeated `POST` is
not a safe way to recover a lost response: keep the id from the first response and
poll it.

## 4. Poll the status resource

```bash
curl -s "http://localhost:4000/api/v1/versions/$VERSION_ID/pathways-exports/$EXPORT_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Organization-Id: $ORG_ID" \
  -H 'Accept: application/json'
```

Poll every 2–5 seconds with an overall client deadline, and stop when the state is
terminal. If a run stays `pending`, retry POST with backoff and a bounded retry
budget: status reads do not start workers, and maintenance only reconciles
`building` runs. The retry reuses the run only while it remains `pending` or
`building`; if it finishes before the retry, POST creates a new run. Stop automatic
retries when your budget is exhausted and report the last observed state. The status resource always answers `200` once the run is visible, including
for failed runs.

| `state` | Meaning | What to do |
| --- | --- | --- |
| `pending` | Accepted, build not started yet | Keep polling. If it stays `pending`, `POST` again: the request reuses this run and starts its build |
| `building` | Build in progress | Keep polling |
| `ready` | ZIP stored and verified | Download it (see expiry below) |
| `failed` | Build failed; see `failure_code` | Read the code, then decide |
| `interrupted` | The build lost its lease | Request a new export |
| `cancelled` | The build was cancelled | Request a new export |
| `expired` | The stored artifact was reclaimed | Request a new export |

Common `failure_code` values: `no_data` (the version had no stops, levels or
pathways to export), `artifact_capacity_exceeded` (the shared artifact volume is
full), `missing_or_corrupt_artifact` (stored bytes no longer match the record) and
`artifact_expired` (an `expired` row that had held an artifact).

## 5. Download the ZIP

```bash
curl -s -D headers.txt -o pathways.zip \
  "http://localhost:4000/api/v1/versions/$VERSION_ID/pathways-exports/$EXPORT_ID/download" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Organization-Id: $ORG_ID" \
  -H 'Accept: application/json'
```

The response is the stored file itself, with private download headers:

```http
Content-Type: application/zip
Cache-Control: private, no-store
Content-Disposition: attachment; filename="gtfs-<export-id>.zip"
Content-Length: 123456
```

### Verify the checksum

`data.sha256` is the digest of exactly these bytes, as 64 lowercase hexadecimal
characters. Compare it with your own digest of the downloaded file:

```bash
printf '%s  pathways.zip' "$SHA256" | shasum -a 256 -c -
```

If the digests differ, discard the file and report the mismatch; do not treat the
export as valid.

### What is inside the archive

A pathways export contains only these CSVs, and each is present **only when the
selected table has at least one record**:

- `stops.txt`
- `levels.txt`
- `pathways.txt`

`routes.txt` and `trips.txt` are never part of a pathways export. When the version
has diagram coordinates, stop levels, route activity flags or diagram images, the
archive also contains the extension manifest `_pathways_extensions.json` and the
referenced diagram images. A version with no extension data contains only the CSVs
listed above; a version with none of the three tables produces a `failed` /
`no_data` run instead of an archive.

### Accept header limitation

The shared companion pipeline negotiates JSON only. Send `Accept: application/json`,
`*/*`, or no `Accept` header. A bare `Accept: application/zip` returns `406 Not
Acceptable`; this is a known, documented limitation of the shared pipeline and it
applies to every companion route.

### Expiry

`data.expires_at` is the authority for how long the artifact stays downloadable. It
is set from the server's configured artifact TTL, so treat it as "until this instant"
rather than assuming a fixed number of hours. After that instant, downloads return
`409 download_unavailable`. The status resource can keep reporting `ready` with a past
`expires_at` until periodic maintenance moves the run to `expired`. Maintenance
deletes the stored bytes; the run row and its history remain.

## Errors

Every error uses the same envelope:

```json
{ "error": { "code": "export_not_ready", "message": "Export is not ready. Check export status before retrying." } }
```

| Condition | Status | Code | Client action |
| --- | --- | --- | --- |
| Malformed UUID in the path | 400 | `bad_request` (`Invalid ID format.`) | Fix the identifier |
| Missing, foreign or unpublished version | 404 | `not_found` | List versions again |
| Missing, foreign, wrong-version or non-pathways run | 404 | `not_found` | Use the id from your own `Location`/status response |
| Missing or invalid bearer token | 401 | `unauthorized` | Log in again |
| Deactivated membership, non-member organization | 403 | `forbidden` | Fix membership or select another organization |
| No membership at all, or several memberships without `X-Organization-Id` | 403 | `no_organization` / `organization_required` | Send `X-Organization-Id`, or join an organization |
| `X-Organization-Id` is not a UUID | 400 | `bad_request` (`X-Organization-Id must be a valid UUID.`) | Fix the header value |
| Artifact storage unavailable before the run is created | 503 | `export_unavailable` | Retry later; nothing was created |
| Any other returned creation/startup error | 503 | `export_unavailable` | Retry POST with backoff and a bounded budget. A pending run may exist; reuse is guaranteed only while it remains pending/building |
| Download while `pending` or `building` | 409 | `export_not_ready` (`Export is not ready. Check export status before retrying.`) | Poll the status resource |
| Download of a run in a terminal non-ready state (`failed`, `interrupted`, `cancelled`, `expired`) | 409 | `download_unavailable` (`Export is unavailable. Check export status before retrying.`) | Read the status resource; this run never becomes downloadable |
| Download of a `ready` run whose artifact is expired, corrupt or held by another download | 409 | `download_unavailable` (`Export is unavailable. Check export status before retrying.`) | **Check the status resource first** |

The two `409` codes mean different things:

- `export_not_ready`: the run is still `pending` or `building`. Keep polling the
  status resource, then download.
- `download_unavailable`: this download cannot be served now. The cause can be
  temporary (another download holds the claim, which it releases when it finishes
  or within about a minute) or permanent (a terminal run, or an expired or corrupt
  artifact). Read `state`, `failure_code` and `expires_at` from the status resource
  before deciding. While the run is still `ready` and `expires_at` is in the future,
  retry the download of the same export id. Request a new export only after a
  terminal failure or an expired artifact.

A failed download never starts a build and never creates a run.

## Storage capacity policy (resolved decision D-1)

The server keeps its existing artifact capacity limits and TTL unchanged. Repeated
*completed* exports each consume shared artifact storage until the TTL reclaims them,
so a client that re-exports a healthy version in a loop can temporarily deny
imports and web exports to the same deployment. Avoid this:

- request an export only when you do not already have a `ready` run for the version;
- download and keep the existing artifact until `expires_at` instead of re-exporting;
- after a terminal failure, decide whether a retry is really needed.

There is no admission control, no rate limiter, and no "latest ready export" lookup
beyond the active-run reuse described above. Response codes report failures honestly
but do not promise that capacity is available.

## QA entrypoint

Automated coverage for every behavior in this document lives in
`test/gtfs_planner_web/api/v1/pathways_export_controller_test.exs` and is grouped by
gate tag:

| Tag | Command |
| --- | --- |
| `export_gate:dedup` | `mix test test/gtfs_planner_web/api/v1/pathways_export_controller_test.exs --only export_gate:dedup` |
| `export_gate:scope` | `mix test test/gtfs_planner_web/api/v1/pathways_export_controller_test.exs --only export_gate:scope` |
| `export_gate:policy` | `mix test test/gtfs_planner_web/api/v1/pathways_export_controller_test.exs --only export_gate:policy` |
| `export_gate:serialization` | `mix test test/gtfs_planner_web/api/v1/pathways_export_controller_test.exs --only export_gate:serialization` |
| `export_gate:download` | `mix test test/gtfs_planner_web/api/v1/pathways_export_controller_test.exs --only export_gate:download` |
| `export_gate:errors` | `mix test test/gtfs_planner_web/api/v1/pathways_export_controller_test.exs --only export_gate:errors` |

The composed end-to-end journey (real login, version listing, request, durable-state
wait, download and archive-content inspection) is covered by
`test/gtfs_planner_web/api/v1/pathways_export_flow_test.exs` and by the QA tour under
`.specs/api-pathways-export/evidence/qa-tour.md`.

Curl examples in this document target a local development server only. Do not run
them against a live deployment.

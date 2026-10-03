# Feed publishing serving fixtures

Generic, value-free schema-1 manifests for the independent public serving
consumer and for publication tests. Both files are literal output of the
production `GtfsPlanner.FeedPublishing.Manifest.encode/1`; nothing here is
hand-written or derived from a live provider, and the prefix, claim, generation,
hashes and sizes are placeholders. No credential, endpoint, bucket, region,
account id or hostname belongs in this directory.

Files:

- `full-static-manifest.json` — a `full` static channel (`objects.zip`).
- `alerts-manifest.json` — an `alerts` realtime channel (`objects.pb`,
  `objects.json`).

## Manifest object (schema version 1)

Every channel owns exactly one small JSON manifest (never over 64 KiB) naming
the immutable payload objects to serve. Required fields:

| Field | Meaning |
|---|---|
| `schema` | always `1` |
| `namespace` | the claimed public prefix (one lowercase URL-safe segment) |
| `claim` | the opaque public claim for that prefix; no private id |
| `channel` | `full`, `flex`, `pathways` or `alerts` |
| `generation` | unique public generation of this publication |
| `sequence` | monotonic integer sequence for the channel |
| `generated_at` | ISO-8601 UTC instant |
| `objects` | role to `{key, sha256, bytes, content_type}` |

Static channels use role `zip`; the Alerts channel uses roles `pb` and `json`,
written together before the single manifest replaces the previous one.

## Keys, permanent paths and object URL pattern

For a claimed prefix `<prefix>`, with `<generation>` a unique public value and
sizes taken from the example generations:

| Channel | Manifest key | Permanent path(s) | Payload object key(s) |
|---|---|---|---|
| full | `<prefix>/static/current-gtfs.json` | `<prefix>/static/gtfs.zip` | `<prefix>/static/objects/<generation>/gtfs.zip` |
| flex | `<prefix>/static/current-flex.json` | `<prefix>/static/gtfs-flex.zip` | `<prefix>/static/objects/<generation>/gtfs-flex.zip` |
| pathways | `<prefix>/static/current-pathways.json` | `<prefix>/static/pathways.zip` | `<prefix>/static/objects/<generation>/pathways.zip` |
| alerts | `<prefix>/realtime/current-alerts.json` | `<prefix>/realtime/alerts.pb`, `<prefix>/realtime/alerts.json` | `<prefix>/realtime/objects/<generation>/alerts.pb`, `<prefix>/realtime/objects/<generation>/alerts.json` |

A permanent URL is `<public-base-origin>/<permanent path>`; the origin is a
deployment value and is not part of this repository. A generation is never
reused, and a payload key is immutable once written.

Examples in these fixtures:

- `full-static-manifest.json` names
  `example-agency/static/objects/00000000-0000-4000-8000-000000000001/gtfs.zip`.
- `alerts-manifest.json` names
  `example-agency/realtime/objects/00000000-0000-4000-8000-000000000002/alerts.pb`
  and `.json`.

## Serving semantics

1. `GET` a permanent path: read the channel's manifest, then stream the
   referenced object's bytes with `200`, the descriptor's `content_type`, a
   strong `ETag` and `Cache-Control: no-cache`.
2. `GET` a manifest path: `200`, `Content-Type: application/json`, a strong
   `ETag`, `Last-Modified` and `Cache-Control: no-cache`.
3. An absent initial manifest is `404`. A malformed manifest, or one naming a
   missing or mismatched object, is unavailable — never a fabricated empty
   successful feed.
4. The consumer accepts only schema `1`, these channels, the fixed filenames and
   object keys under the manifest's own prefix. It never calls the application
   or the database and never takes an object key or remote URL from a caller.
5. Two separate requests may straddle a manifest switch; each individual
   response is one complete representation. Consumers revalidate.

Content types are `application/zip` for every static profile,
`application/x-protobuf` for `alerts.pb`, and `application/json` for
`alerts.json` and every manifest.

## Conditional writes (application to provider)

The application is the only writer:

- an immutable payload `PUT` uses `If-None-Match: *` (create-if-absent);
- the manifest replace uses `If-None-Match: *` for the first creation and
  `If-Match: <frozen predecessor ETag>` for every later replace.

Every payload object carries exactly these user metadata values and nothing
else: `x-amz-meta-publication-claim`, `x-amz-meta-publication-channel`,
`x-amz-meta-publication-sequence`, `x-amz-meta-publication-generation`. They
contain no private identifier. A `412` never rebases a stale attempt onto a
freshly read ETag.

## Retention safety

Manifests and website assets (`images/...`, `fonts/...`) are never deleted by
the application. Only retired immutable payload objects under the owned prefix
may be removed, and only after the channel's current manifest has fenced the old
predecessor and a 24-hour grace has elapsed. A late upload that recreates a
retired key cannot become current: the manifest is the only pointer, and the
orphan is removed by a later bounded scan.

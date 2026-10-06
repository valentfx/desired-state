# Desired State HostGator backend — initial installation

Prepared 2026-10-05 for the existing empty MySQL 5.7 database. This is the first server milestone, not a complete multi-user service. The app is unchanged and does not automatically upload yet.

## Install

Upload this entire ZIP using the existing SSH account. Extract it into a new directory in /home2/valentfx, then run `bash install.sh` from that directory. Enter the **database user's password**, which may differ from the SSH password. The installer checks PHP syntax before creating tables or publishing the API. It refuses to replace an existing API folder, preserves existing configuration, and never changes the main website's files.

After installation:

```bash
curl --fail --silent --show-error 'https://valentfx.com/desired-state-api/index.php?action=health'
php tools/smoke_test.php
```

The PHP test needs outbound HTTPS and `allow_url_fopen`. A test failure must be investigated before uploading real logs. The test writes one small synthetic session clearly labelled `backend_smoke_test`; retain or exclude it from analysis. Never paste credentials, the generated upload token, or backend.php into chat.

## Data organization

MySQL contains accounts, participant identifiers, session metadata, file revisions/hashes and upload status. It also creates an event table for subsequent structured indexing. Original JSON and JSONL contents are stored unchanged in private, hash-addressed files outside public_html. Each file revision belongs to an account, session and original filename. Retaining multiple hashes for a filename preserves old file versions. The session catalog stores its latest registered manifest; manifest.json file versions retain historical original manifests. Do not assume the catalog's latest manifest and every uploaded file form an atomic complete session snapshot.

Account IDs and participant IDs are separate. Participant records currently contain identifiers only; profile synchronization and ownership confirmation are later work. State feedback, activities and sensor logs can be uploaded as raw files; this release does not yet parse them into event rows or derived metrics.

## API v1

All operations require HTTPS. Except health, requests require `Authorization: Bearer <private token>`. Tokens are hashed in MySQL. The first token belongs to the initial Owner account; there is no self-service registration.

- GET `?action=health`: database/schema status, no authentication.
- GET `?action=sessions`: latest 100 registered sessions for the token's account.
- POST `?action=session`: JSON `{"manifest": {"schema_version":1,"session_id":"..."}}` with optional participant_id and existing manifest fields.
- POST `?action=file`: JSON session_id, file_name, bytes and lowercase sha256. Supports .json and .jsonl files, 4 GiB maximum per file. Returns upload_id, current offset and 8 MiB chunk limit. Repeating registration resumes the same file revision.
- GET `?action=status&upload_id=...`: authoritative current offset.
- POST `?action=chunk&upload_id=...`: binary body plus X-Upload-Offset and X-Chunk-Sha256. On uncertain network outcomes, query status before retrying.
- POST `?action=finish&upload_id=...`: checks whole-file hash and marks the file verified. Safe to repeat.
- POST `?action=reset&upload_id=...`: discard an unverified partial file; verified objects cannot be reset.

Storage reservation starts at **10 GiB per account**, adjustable privately in backend.php after confirming hosting capacity. Pending reservations and all retained revisions count, even if object contents deduplicate. Reset keeps its reservation for retry. This is an application allowance, not the hosting quota; leave space for database, temporary chunks, website files and backups. Files larger than the plan can accommodate need external object storage. Web request timeouts can still affect large-file final hash verification; test a real large file before scheduling bulk upload.

## Next milestones

1. Pass server syntax, schema, HTTPS and upload smoke checks; validate MySQL/file behavior on this actual host.
2. Windows manual uploader: select one completed recording, retain local files, resume chunks, verify remote file inventory.
3. Complete-session revisions and profile/event indexing, followed by automatic upload of completed sessions.
4. Per-user onboarding, authorization tests across separate accounts, token rotation/revocation tools, retention/deletion and consent controls.
5. Scheduled off-host backups with restore tests, monitoring and private object storage migration as volume grows.
6. Derived measurements with algorithm versions and reproducible exports for later modeling.

## Validation and deployment limits

Bash syntax and ZIP integrity were checked when packaging. PHP and MySQL execution are not available in the preparation workspace; the installer performs PHP lint checks on HostGator. The supplied integration test has not yet run on the host. No account isolation integration test, load test or large-file timing test has passed yet. Do not open registration or bulk-upload all recordings until these checks and backup/restore work are complete.

Suggested commit after confirming installation: `Add HostGator session catalog and resumable private log uploads`. Update help/current-state.md and help/project-log.md with actual server results; list unimplemented follow-ups in help/roadmap.md. Do not commit generated private configuration, tokens, uploaded data or database exports.

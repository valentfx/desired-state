# State feedback and central storage

## First implementation

Optional Session setup appears before recording, with purpose (personal tracking, experiment or device test), session type, desired state, question and an unset 0–10 bar. Start remains available without setup. Live adds one compact How do I feel action; the full bar opens in a sheet. Choosing a number records one answer; closing or Skip records nothing. Stop has no feedback prerequisite. The completed screen offers an optional ending rating and setup for the next session. Setup settings last for the current screen lifetime; ratings are consumed once and never reused for the next recording. Persistent named presets and User/Research experience selection are follow-up work.

Questions v1: goal closeness (0 very far away, 10 fully there), anxiety (0 none, 10 extreme), energy (0 none, 10 very high). Goal closeness requires a desired state. Scores for different questions or goals are not interchangeable. Subjective scores are not sensor measurements or validated diagnostic scales.

Phone History opens State feedback and can append a current-time follow-up to a stopped session. Active-session history is read-only; use the owning Live action. Windows Analyze opens the same viewer read-only. This preserves the existing one-way phone sync contract; bidirectional annotation reconciliation must precede Windows editing. Legacy sessions remain readable and have no invented question or ratings. Retrospective editing of pre/post timestamps is not implemented.

## Portable data contract

Keep manifest schema_version 1 for existing phone, desktop and Python readers. Add independently versioned session_context and state_feedback_version. Context carries purpose, session_type, optional desired_state and the complete rating-question definition. Existing participant_id/session_id remain the identity anchors. Local timezone offset is a capture-time offset, not an IANA timezone name or a synchronized sensor clock.

state_feedback.jsonl is an optional append-only journal. Each row contains schema_version, event=state_rating, random event_id, session_id, optional participant_id, question definition/version/anchors, integer value 0–10, phase pre/during/post/followup, desired_state, event_utc, entered_utc, received_utc, retrospective and source. Pre-rating event time is the selection time even though persistence occurs when the session starts. Live/post/followup use answer time. No answer is represented by absence, never zero. Invalid/corrupt/foreign journals are preserved and rejected. Writes are serialized within the application process; multi-process editing is not supported.

The journal is exported in session ZIPs. Existing Windows phone sync transfers JSON/JSONL files and retains changed revisions, so new feedback transfers without changing raw signal storage. Journals are not yet plotted or incorporated into objective outcome metrics. Raw sensor files and original identities are never rewritten by this feature.

## Backend schema requirements

The backend is not deployed by this change. Use a searchable relational catalog plus private raw-file storage. The following entities guide subsequent migrations and the HTTPS API:

| Entity | Essential fields |
| --- | --- |
| Accounts and access | Account ID, authentication identity, participant/session access grants; separate login from measured person |
| Participants | Stable participant ID, owner/access scope; audited corrections rather than rewriting capture identity |
| Sessions | Session ID scoped to source/owner, participant, context/version, start/end UTC, timezone provenance, app version, status |
| Subjective responses | Event ID, session, question/version/scale, value, phase, goal, event and entry times, source |
| Activity events | Event ID, session, activity instance ID, type, start/change/stop, parameters/units, timestamps; allow overlap |
| Devices and streams | Device identity/model, stream type/version, units/rate, timestamp provenance, calibration, quality |
| Files and revisions | Session, safe private object reference, source/revision, bytes, SHA256, format version and verified status |
| Derived results | Source hashes, algorithm/version/settings, baseline/window, metric/units, quality and calculated time |
| Upload queue | Local pending/transferring/verified/failed status, resumable chunks, retries, stable request IDs; retain originals |
| Permissions | Versioned storage/sharing/modeling decisions, actor and timestamps; export/deletion/revocation workflow |

Uploads must authenticate, authorize participant access, validate structure/size/checksums, prevent duplicate publication, and publish only a verified complete revision. Large EEG files require bounded/resumable transfer rather than a single PHP form upload. No credentials, raw recordings or server secrets belong in Git. Never use participant names as account credentials or globally unique IDs. Existing timestamp-based session IDs require server-side owner/source scoping and collision handling.

## Remaining work

Persistent named presets; User/Research mode; structured feeling chips; concurrent activity controls; baseline periods and objective outcome summaries; rating overlays/comparisons; queued automatic uploads; server authentication/schema/API/storage; permissions; HRV Logger import retaining originals and provenance; informative phone-sync progress. App and backend format changes require compatibility and round-trip tests. Do not call these implemented based on this contract.

## Activity marker update

Start remains immediate without setup. Add activity buttons through Quick markers: yoga, resistance training, breathwork, sound bowls, meditation, stretching, running, steam room, sauna, swimming, pickleball, walking, cycling, haptics, audio and rest. Existing user lists are not replaced. Custom labels, add/remove/rename and persistence remain supported. Most-used favorites sort first; equal usage counts retain the saved ordering. The compact Live row scrolls horizontally to reach all favorites. Usage increments only after a successful marker write. Old definitions read with zero usage and no activity ID. Past event labels/IDs remain immutable.

Catalog activity markers add activity_id, activity_schema_version 1 and activity_action mark to existing marked_event rows. These are instant observations, not inferred start/stop intervals. Custom markers retain stable marker_definition_id and label snapshots without inventing an activity category. Backend event ingestion must preserve these fields. Explicit duration/start/stop controls remain pending.

## Deployment update 2026-10-05

Earlier backend references above describe requirements at the time of the feedback change. HostGator schema/API v1 is now deployed and its synthetic smoke test passed, as reported by the user. The initial Owner token scopes sessions/files to its account; participant IDs do not yet carry access grants. Raw JSON/JSONL is retained privately by SHA256, with MySQL file revisions/status and the latest catalog manifest. The event table is a scaffold and is not populated by ingestion yet. Individual-file verification does not establish an atomic complete-session revision. Automatic upload, profile synchronization, corrections/event normalization, derived results and permissions remain later milestones.

The Windows first-stage uploader copies a stopped session into a temporary snapshot, streams file hashes in a worker isolate, resumes each revision in bounded chunks, validates each server finish/status acknowledgment, and writes a nonsecret local receipt. Backend source is versioned under server/hostgator; Windows token setup is tools/configure_backend_upload.ps1. See [backend-upload.md](backend-upload.md) for operational steps and actual verification limits.

## Annotation and phone-master participant update
Desktop annotations/profile/motion update 978e508: audited event label and note edits, session notes, marker-line selection; 30-second Add note expiry; explicit follow-up ratings for legacy/goal-less sessions; recorded posture and ring/H10 motion plots; phone-master profile identifier correction and confirmed duplicate merges; verified USB profile mirroring; recoverable local session trash and sync exclusions. Raw capture files remain unchanged. Unsynchronized desktop annotation revisions block phone replacement for that session pending reconciliation. Profile journal version 3 requires both apps updated before identity corrections. Trash uses space; cloud deletion, cloud profile ingestion, trash restore/purge UI and bidirectional annotation merging are pending. No oxygen/posture observations are fabricated. Flutter runtime validation is required on the PC; this workspace only ran Git diff checks.


# Central log uploads — operator handbook

## Current deployment

HostGator: valentfx.com, SSH gator4153.hostgator.com port 2222, home /home2/valentfx. Database valentfx_desiredstate; PHP API schema 1 at https://valentfx.com/desired-state-api/index.php. Backend code: server/hostgator. Runtime configuration, token and logs: /home2/valentfx/desired-state-private, outside public_html and Git. The initial owner token authorizes this account's sessions; measured participant IDs are not login accounts.

## Work PC setup

Close Windows Desired State and stop active recordings before updating. The ZIP installer applies only the listed uploader/backend/doc files, backs up originals, and requires analysis, full tests and a Windows release build before an informative commit. It preserves phone identity/signing, paused UI changes and unrelated working files. No phone installation or Git push is performed.

After the install completes, configure this Windows login once:

```powershell
cd F:\1dev\desired-state
cls
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\configure_backend_upload.ps1
```

Enter the SSH password locally. The token itself is never printed. DPAPI credential file lives under LOCALAPPDATA/DesiredState, outside OneDrive and the repository. For token rotation, remove only backend-token.dpapi from that directory and rerun setup after the server token is rotated; server rotation tools remain follow-up work.

## First real upload

In Windows Analyze, select a completed small recording and wait for it to open. Click the cloud Upload selected session icon, then Upload selected session. All top-level .json/.jsonl files are included, including original sensor streams and optional rating/annotation journals. Uploading sends participant snapshots/notes contained in those files to your private account. Other file formats are not uploaded. Incomplete sessions are refused. Do not delete local recordings or backups after success.

Watch file name, MB transferred and files verified. Snapshot preparation needs temporary disk space approximately equal to the session size. Pause finishes the current operation; a retry recreates the snapshot and asks for existing offsets, and does not retransmit already verified identical revisions. If files have since changed, they become new immutable revisions.

Success writes desired_state_desktop/upload-receipts/<session>-<timestamp>.json outside the session directory. Receipt includes account/session, file names, byte counts, SHA256 and upload IDs, never the credential. Every listed file passed server hash verification and status checks. It is not a whole-session atomic publication marker and does not claim a second off-host backup.

## Host health check

```bash
cd /home2/valentfx
clear
curl --fail --silent --show-error 'https://valentfx.com/desired-state-api/index.php?action=health'
```

The original installer package and synthetic integration test remain in the dated desired-state-backend-* folder. Do not rerun install.sh against an existing API folder. Source updates need a deliberate backup/redeployment procedure; uploading a new ZIP does not update deployed code automatically.

## Troubleshooting and validation limits

- Missing credential: run the Windows setup above under the same login as the app.
- HTTP 401: missing/revoked token; rerun credential setup after server repair.
- HTTP 413: file limit or the current 10 GiB application reservation allowance. Confirm actual hosting quota before increasing it.
- HTTP 422: integrity failure; preserve local originals and investigate the revision rather than treating it as uploaded.
- Connection/finish timeout: retry the same completed session. Server finish is idempotent; a large final SHA256 may exceed hosting request limits and needs a real-file timing test.
- Missing session: phone sync/import comes first; Windows uploads from its existing local master folder.

User reported that PHP lint, schema, HTTPS and synthetic authentication/chunk/hash checks passed. Local standalone Dart uploader checks passed; full Flutter/Windows/DPAPI tests and a real log transfer still require this PC. Automatic uploads, event indexing, participant access grants, new-user onboarding and backup/restore are not implemented by this package.

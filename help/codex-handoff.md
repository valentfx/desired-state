# Codex handoff — Desired State

Stage 1 software has been implemented and tested; read `help/current-state.md` and the latest `help/project-log.md` entry before doing more work. The exact next step is the S24/H10 recovery trial, then persistent users/custom quick markers. Do not repeat the controller extraction or claim hardware reliability from automated tests.

The authoritative work-PC checkout is `F:\1dev\desired-state`; the home laptop checkout is `C:\1dev\desired-state`. On the work PC, the C: app was a non-Git source copy used to recover the absent F: app after external backup. Locate the Git root rather than assuming a path. Keep the external recovery backup until the user confirms recovery.

Read help/app-development-plan.md and help/project-log.md. Inspect repository instructions, git status, latest commits and current code; local work may be newer than the reviewed 3947812 baseline. The user confirmed the Android app runs on the work PC.

Continue the development plan in ordered, reviewable stages after the stage 1 device-validation gate: persistent profiles and one-tap custom markers, configurable raw/screened processing, bounded selectable charts, navigation/forms, and history. Feedback and simultaneous straps are later stages. Do not claim the entire roadmap is complete after the first stage.

Before edits, summarize actual implemented/pending state and your first stage. Preserve local changes and immutable raw recordings. Apply focused refactoring rather than rewriting the app. Run relevant checks and update help/current-state.md and help/project-log.md with evidence and the next step. Add a concise root AGENTS.md directing future sessions to these context files and documenting applicable validation commands. Do not automatically commit participant data or silently upgrade dependency constraints.

Flutter app: mobile\desired_state_app under the discovered repository root. For user-run PowerShell commands include exact cd first then cls. Main target is Android H10 recording; desktop layout and sensor plugin support must be independently checked.

At the end, report changes and limitations. Commit and push intended changes when the user requests a cross-PC handoff. Future sessions should recover context from repository files rather than old chats.

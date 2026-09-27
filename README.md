# Desired State: H10 acquisition prototype

First milestone: record a reproducible local session of standard Bluetooth heart-rate and RR notifications from one or more Polar H10 straps. The Python core, device adapter, processing, storage, and platform entry point are separate. Flask, research UI, ECG, and adaptive protocols follow after reliable acquisition.

See [help/quickstart.md](help/quickstart.md) for the Pi workflow and [help/project-log.md](help/project-log.md) for architectural decisions, current status, and the next milestones. Update the project log whenever implementation decisions change. `desired-state-h10 --help` lists commands.

The target is 4–8 concurrent straps; this is a test goal, not a verified Pi limit. Each sensor gets an independent reconnecting task. The first run should use one strap.

## Working layout

All importable Python code lives under `src/desired_state/`. `core/` holds session and signal contracts, `devices/` contains sensor adapters, `processing/` will hold derived metrics, `storage/` owns persistence, and `platforms/` contains host entry points. Add `api/`, `stimulus/`, and other adapters within the package when their first working feature needs them. The top-level `help/` holds short operator instructions and the ongoing project log.

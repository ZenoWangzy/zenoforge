# Main engine-tests repair

## Causes

- `health_report.test.sh` copied `node_health.py` into its isolated fixture without the sibling `config_paths.py`; Python could not import `config_paths`.
- The scheduler fixture's `tick_git` shim rejected `git rev-parse --show-toplevel`. `rule-lane.sh` therefore could not resolve the fixture repository, skipped PR #50 with `rule lane unavailable: no result`, and the fresh aggregate assertion failed.
- The full scheduler run then exposed a separate fixture cache leak: the `footprint_mutex` case changes `ROOT` to a repository with shared history, but `hotspot_log` still held the empty repository's cached result.
- The engine-tests workflow already installs `@typesafe-ai/sdk@0.7.0`. The same package/version was installed locally.

## Changes

- Copy `config_paths.py` with the other health-report fixture modules.
- Make `tick_git` return `$TF/repo` for `rev-parse --show-toplevel`.
- Reset `HOTSPOT_LOG_LOADED` after the footprint fixture changes `ROOT`.
- Production scheduler and rule-lane files are unchanged; CI dependency setup already matches the repo-prescribed install.

## Results

Fail-before evidence:

- `health_report.test.sh` exited 1 with `ModuleNotFoundError: No module named 'config_paths'`.
- `scheduler.test.sh` exited 1 after `merge skipped PR#50 (rule lane unavailable: no result)` and `fresh aggregate passes did not release the adopted PR`.

After the changes, with HOME and TMPDIR rooted under `.git`:

- `engine/mac-autopilot/health_report.test.sh`: PASS.
- `engine/mac-autopilot/scheduler.test.sh` with a 3600-second timeout: PASS.
- `bash tools/run-engine-tests.sh 0 8`: 26 passed, 0 failed, 0 quarantined.
- `bash tools/run-engine-tests.sh 2 8`: 27 passed, 0 failed, 0 quarantined.
- `npm install --no-save @typesafe-ai/sdk@0.7.0`: succeeded.
- `git diff --check`: PASS.

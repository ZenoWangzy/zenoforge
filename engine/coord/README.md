# Coordination operator commands

`ctl.sh` operates on the custom refs of the target repository's `origin` using Git transport. `probe` also calls `gh run list` from the target repository to verify its commit did not trigger a workflow.

Run `probe --host-id <id>` before enabling coordination. The probe creates a leased claim ref, reads it back, checks that no branch points at its commit and no workflow run exists, then deletes the ref with an object-id lease. A failed check or delete returns an error.

`enable --host-id <id>` requires the renewal timer to be installed and loaded. It checks for the unit before writing host settings, adds `zenoforge-renewd.timer` to the local timer list, starts it, and adopts local work. `adopt-local` reads active `zf-<stage>-<issue>.service` units when `systemctl` is available, plus live issue workers with a matching row in `units.json`. Live workers are matched by PID start identity in `workers.json`.

`control set primary=<id>` selects which host may acquire new claims; `control set primary=` selects the current host. `control clear primary` clears that restriction. `control set min_proto=<number>` sets the minimum protocol. `control set drain=<id>,<id>` replaces the drain list. `drain <id>` adds a host to that list. A drained or non-primary host starts no new claims. Its active stages finish and release their own claims normally.

`status show` fetches the status refs and formats them through `status.sh`.

`effect clear <claim> <key>` marks an unresolved once-only intent as cleared. This records the operator's decision that the intent no longer blocks the claim. `claim clear <key>` removes a malformed, unsupported or oversized claim; it refuses valid claims so their checkpoint and effect history stays available. Use `purge` after all hosts are drained to remove valid released claims.

`purge` deletes refs under `refs/claims`, `refs/status` and `refs/coord` with object-id leases. Drain hosts and let active stages finish before using it.

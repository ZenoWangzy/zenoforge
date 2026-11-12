# Running Zenoforge on two hosts

> **Status: not yet usable.** The coordination code and `engine/coord/ctl.sh` (ticket K4) are not on `main` yet. The steps below are the plan from [design/DISTRIBUTED.md, section 10](design/DISTRIBUTED.md#10-rollout-single-host-to-two-hosts-with-rollback). Do not run them until that section's tickets have landed. Until then, a single host works as described in [install.md](install.md).

This guide covers three things: turning coordination on for the host you already run, adding a second host, and rolling back. The design, the protocol and the failure modes are in the design doc. This page does not repeat them.

## Before you start

- Every step below needs one command from `engine/coord/ctl.sh`.
- Each host needs its own GitHub identity. The REST budget is per identity.
- Each host needs an engine at the same or a newer SHA.
- The pipeline token must be allowed to push `refs/claims/*`, `refs/status/*` and `refs/coord/*`.

## 0. Probe the target repository

Run `ctl.sh probe` on the real target repository before any enable step. It pushes `refs/claims/probe-<host>`, checks that `ls-remote` shows it, and checks that no workflow run or branch appeared. It then deletes the ref. If the probe fails, stop here: the ref namespace, the token or the git transport is the problem, not the pipeline.

## 1. Enable on the existing host

1. Run `ctl.sh enable --host-id host-a`. It writes `host.env` with `ZF_COORD=on` and `ZF_HOST_ID`, extends `timers.local.list`, starts the timer and runs `adopt-local`.
2. `adopt-local` claims every running `zf-*` unit and unit-loop worker, with its checkpoint. Old unleased workers therefore never overlap new ones.
3. Check that the claims show up on GitHub before you go on.

To undo: set `ZF_COORD=off` and run `ctl.sh purge --host host-a`.

## 2. Add the second host

1. Install the engine on the new host, with its own `GH_TOKEN`.
2. Run `ctl.sh control set primary=host-a` first. The new host then publishes its status and capabilities but dispatches nothing.
3. Run `ctl.sh status show` and confirm both hosts are visible.
4. Run `ctl.sh control set primary=` to clear the primary. The new host now takes work.

To undo: `ctl.sh control set primary=host-a`. This takes effect within one tick.

## 3. More hosts

Repeat step 2 for each host.

## Rollback levers

Use the fastest lever that fits:

1. `ctl.sh control set primary=<host>`. Every other host stops acquiring within one tick. Their running claims finish and are released.
2. `ctl.sh drain <host>`. That host stops acquiring and releases at the end of the current stage. Then stop its timers.
3. `ZF_COORD=off` on a host. Only safe on the last remaining host. First set `primary` and drain the others.
4. `ctl.sh purge`. Deletes every ref under `refs/claims`, `refs/status` and `refs/coord`. Leftover refs are harmless. Each ticket's local state stays intact, because local files remain the working copy.

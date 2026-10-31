# Zenoforge portability and multi-host design

Status: design, not implemented. Written 2026-10-29 against the exported engine tree (`engine/`, 344 script and unit files, 176 of them production code).

Scope: make the engine run on Linux (with and without systemd), macOS (Apple Silicon and Intel) and Windows through WSL2, and say how any of those hosts joins a fleet of N hosts. Native Windows is out of scope (section 9).

Landing rule: until the source of truth moves, every change below lands first in the origin deployment's copy of the engine, at the same relative path, and reaches this repository through the export. So each ticket is a change to `engine/<path>`, and each must leave the origin's live single-host Linux deployment unchanged unless a switch is turned on. Root-level files (`.github/`, `.gitattributes`, `docs/`, `tools/`) belong to this repository only.

Reading the counts: "lines/files" counts non-comment lines in production scripts under `engine/` (test files are counted separately). Recipes are in the appendix, so every number can be re-run.

## 1. Decisions

1. **Dependencies first.** About 800 production lines use GNU userland, bash 4/5 features, `flock` or `setsid`. Rewriting them would touch dozens of hot files. Instead the engine requires bash 5, GNU coreutils, findutils, grep, sed, tar and `flock`/`setsid`, and on macOS puts the Homebrew `gnubin` directories on `PATH`. Zero call-site edits for this class.
2. **Three small helpers for the Linux kernel interfaces** (`/proc`, `/proc/meminfo`, boot id): `engine/platform-env.sh`, `engine/proc.sh`, `engine/hostinfo.py`. The Linux branch is the code that exists today, moved verbatim.
3. **The supervisor is replaced behind the command line, not at the call sites.** About 105 lines in 29 files use `systemctl`, `systemd-run` and `journalctl`. A PATH-selected shim set (`engine/portable-shim/`) implements the 13 command forms the engine actually uses, on top of a flock-held run ledger. The engine already uses this pattern (`engine/execution-shim/systemd-run`, `engine/gh-shim/`). Selection is opt-in on Linux, so the origin's PATH does not change.
4. **Timers**: systemd timers on Linux and WSL2, launchd LaunchAgents on macOS (generated from the same `engine/systemd/*.service|*.timer` files), and a foreground loop as the universal fallback.
5. **Fleet**: GitHub stays the source of truth and the coordination protocol is the one in `docs/design/DISTRIBUTED.md` (per-ticket claim refs, leases, no global lock, no database). This document adds only what the portability layer must guarantee to a mixed-OS fleet, and settles the places where the two documents differ (section 8).
6. **Windows**: WSL2 only. Native Windows would rewrite at least 362 production lines in 55 files (section 9).
7. **Verification**: CI runs on ubuntu only, as most plugin repos do. macOS and WSL2 have no CI job; `engine/doctor.sh` tells a user what is missing before a tick fails silently, and `tools/quarantine-*.txt` still apply to local runs.

## 2. Supported platforms

Tier 1 means the origin deployment already runs there. Tier 2 means supported by CI legs added by this design.

| Platform | Tier | Issue-loop scheduler (`ZF_TIMERS`) | Unit loop host | Stage runner (`ZF_RUNNER`) | Capacity admission | CI leg |
|---|---|---|---|---|---|---|
| Linux with a systemd user manager (Ubuntu 24.04, Debian 12+, Fedora) | 1 | systemd timers | systemd service | `systemd-run` | `/proc` and cgroup caps | `ubuntu-latest`, 8 shards |
| WSL2 with `systemd=true` | 1 | systemd timers | systemd service | `systemd-run` | `/proc` and cgroup caps | `windows-latest` + WSL2, systemd on |
| Linux without systemd (containers, minimal VMs, OpenRC/runit hosts) | 2 | foreground loop | `start.sh` nohup path | pidfile runner | `/proc`, run-ledger count, no cgroup caps | `ubuntu-latest`, `ZF_RUNNER=pidfile` |
| WSL2 with systemd off | 2 | foreground loop | `start.sh` nohup path | pidfile runner | same as above | `windows-latest` + WSL2, systemd off |
| macOS 14+ on Apple Silicon | 2 | launchd LaunchAgents | LaunchAgent | pidfile runner | `sysctl`, `memory_pressure`, `top`, run-ledger count | `macos-latest` (macOS 26, arm64) |
| macOS on Intel | 2 | launchd LaunchAgents | LaunchAgent | pidfile runner | same | `macos-15-intel`, portable suites only |
| WSL1 | no | | | | | WSL1 has no systemd (`systemd=true` is "Only supported on WSL 2" in Microsoft's reference) |
| Native Windows (PowerShell, Git Bash, MSYS) | no | | | | | section 9 |

`ZF_RUNNER` is `systemd` or `pidfile`. `ZF_TIMERS` is `systemd`, `launchd` or `loop`. Defaults: Linux `systemd`/`systemd`, macOS `pidfile`/`launchd`. Linux without systemd must set `ZF_RUNNER=pidfile` and `ZF_TIMERS=loop` explicitly (in `$AGENT_HOME/capacity.env`, which `engine/lib.sh` already sources with `set -a`). The doctor tells you when to. Auto-selecting the shim on Linux is deliberately not done, because a wrong guess on a systemd host would swap out the supervisor.

BusyBox/Alpine userlands are not supported (they cannot supply the GNU tools in section 3). Ubuntu 22.04's stock git (2.34) is below the git 2.38 floor (`git merge-tree --write-tree`, 2 uses), so use 24.04 or a newer git.

## 3. Dependencies

Floors are measured from the code, not guessed:

| Tool | Floor | Why (evidence) |
|---|---|---|
| bash | 5.0 | `EPOCHREALTIME`/`EPOCHSECONDS` (45 lines, 7 files) arrived in 5.0. Also `declare -A`, `mapfile`, named fds `exec {fd}>`, `local -n`, `${x,,}`. All 248 bash shebangs are `#!/usr/bin/env bash`, none is `#!/bin/bash`, so PATH decides the interpreter. macOS ships 3.2. |
| GNU coreutils | any current | `date -d` (80 lines), `stat -c` (35), `timeout --foreground -k` (100), `base64 -w0`, `readlink -f`, `mv -T`, `install -D`, `nproc` |
| GNU findutils | any | `find -printf`, `xargs -r` |
| GNU grep | any | `grep -P` (`engine/notify.sh:1755`) |
| GNU sed | any | `sed -i` without suffix (2 files), `\n` in the replacement (`engine/lib.sh:9158`) |
| GNU tar | any | `--null -T`, `--verbatim-files-from` (`engine/mac-autopilot/scheduler.sh:917`, `engine/run-tick.sh:214`) |
| `flock` | any | 156 lines in 29 files, plus Python `fcntl.flock` |
| `setsid` | util-linux | 17 lines in 7 files; `setsid --wait` in `engine/bin/worker:151` |
| awk | any (mawk, BWK awk, gawk) | The origin runs mawk. One gawk-only construct exists, `IGNORECASE` in `engine/lib.sh:13186`, a silent no-op on every other awk. gawk is optional. |
| procps (`ps`, `pgrep`, `pkill`) | any | Linux only; macOS has its own |
| git | 2.38 | `merge-tree --write-tree`, `worktree add --lock --reason` |
| jq | 1.6 | `@base64d`, `--rawfile`, `todate` (117 uses), `fromdate` (35). No `strptime`/`mktime`, which differ by platform. |
| python3 | 3.9 | `zoneinfo` (2 files). Stdlib only, no pip dependency. The tree parses with `ast` at 3.8 syntax, so 3.9 is set by the import. Needs system tz data. |
| node | 20 (CI pins 22) | `node:test` with `--test-concurrency`; no platform branches in 57 `.mjs` files; one npm dependency (`@typesafe-ai/sdk`, only for `engine/ts-judge.mjs`) |
| gh | current, logged in | all GitHub I/O |
| agent CLI | at least one of `codex`, `claude`, `zcode` | workers |

### Linux (Debian, Ubuntu)

```
sudo apt-get install -y bash coreutils findutils grep sed tar gawk util-linux procps git jq python3 tzdata curl
# Node 22 and gh from their vendors' apt repositories
```

Fedora: `sudo dnf install -y bash coreutils findutils grep sed tar gawk util-linux procps-ng git jq python3 tzdata curl`.

With systemd, run `loginctl enable-linger "$USER"` so user timers keep firing when no login session is open (the engine's own notes already ask for this).

### macOS

```
brew bundle --file=engine/Brewfile
```

`engine/Brewfile` (new, 14 lines):

```
brew "bash"        # 5.3.x; the system bash is 3.2
brew "coreutils"   # gnubin: date, stat, timeout, base64, readlink, nproc, mv -T ...
brew "findutils"   # gnubin: find, xargs
brew "grep"        # gnubin: grep -P
brew "gnu-sed"     # gnubin: sed
brew "gnu-tar"     # gnubin: tar
brew "gawk"        # optional
brew "util-linux"  # keg-only; used for setsid
brew "flock"       # homebrew/core, bottled for arm64 and Intel
brew "jq"
brew "gh"
brew "git"
brew "node@22"
brew "python@3.12" # or the Xcode CLT python3 (3.9+)
```

Homebrew prefixes differ: `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel. `engine/platform-env.sh` probes both.

The GNU tools live in `"$(brew --prefix)"/opt/<formula>/libexec/gnubin`. Homebrew's own caveats give exactly this path for coreutils, gnu-sed, findutils, grep, gnu-tar and gawk. The engine puts those directories first on `PATH` for its own processes only. Nothing is changed system-wide. `util-linux` is keg-only, so its `bin` goes last on `PATH`: it fills in `setsid` and shadows nothing macOS ships.

Under launchd the default `PATH` is minimal, so the generated plists carry the full `PATH`. This is the same trap the systemd units already document (`engine/systemd/zenoforge-agent.service`, `Environment=PATH=`; `engine/systemd/user-units-path.test.sh` guards it).

Checked on 2026-10-29 against formulae.brew.sh and the formula source: `flock` 0.4.0 exists in homebrew/core with macOS bottles; `util-linux` 2.42.4 lists a set of Linux-only tools it omits on macOS and `setsid` is not in that set. `flock` is in the formula's executables list but a formula that omits `ionice` still lists it, so that list is not proof. Hence the separate `flock` formula. Not checked on a real Mac (section 13).

### WSL2

Same as Linux, inside the distro (Ubuntu 24.04 is the CI image). Keep the checkout, `AGENT_HOME` and `ZF_WORKTREE_ROOT` on the Linux filesystem (`~`), never under `/mnt/<drive>`.

## 4. Inventory of platform-specific constructs

Method: grep over the 344 script and unit files in `engine/` (`*.sh`, `*.mjs`, `*.py`, `*.service`, `*.timer`, `engine/bin/*`), comment-only lines removed. Prod = non-test files. Samples are `engine/<file>:<line>`.

Existing macOS awareness, found by the same grep: `engine/mac-autopilot/runtime-env.sh` has portable time helpers (`ap_iso_epoch`, `ap_mtime_epoch`, written to avoid BSD/GNU `date` differences); `engine/mac-autopilot/scheduler.sh` treats `setsid` as optional at 3 sites; `stage_unit_active` in `engine/lib.sh` returns "inactive" when `systemctl` is missing. Yet `Darwin`/`macOS` appears in only 2 test lines, and none of this is exercised on a Mac. The unit loop was Mac-shaped once and has drifted.

### 4.1 Class A: GNU userland and bash features. Approach 1, dependency

| Construct | Prod lines / files | Test lines | Samples | Fix |
|---|---|---|---|---|
| bash 4/5 features, union | 358 / 38 (of 117 prod shell files) | | | bash 5 |
| - `declare -A`, `local -A` | 84 / 22 | | `engine/land-direct-main.sh:422`, `engine/check-gh-flags.sh:8` | bash 5 |
| - `mapfile`, `readarray` | 63 / 17 | | `engine/check-rulings.sh:55`, `engine/bin/drive-train.sh:17` | bash 5 |
| - named fds `exec {fd}>` | 161 / 15 | | `engine/bin/worker:46`, `engine/bin/luna:49` | bash 5 |
| - `${x,,}`, `${x^^}` | 27 / 7 | | `engine/dispatch-codex.sh:126` | bash 5 |
| - `EPOCHREALTIME`, `EPOCHSECONDS`, `BASHPID` | 45 / 7 | | `engine/call-profile.sh:158` | bash 5.0 |
| - `local -n` | 5 / 3 | | `engine/land-queue.sh:1932` | bash 5 |
| `date -d` / `--date` | 80 / 16 | 148 | `engine/lib.sh:326` (`agent_epoch`), `engine/comms-format.sh:52` | coreutils (47 are `@epoch`, 30 relative like "10 years ago") |
| `date +%s%3N` (`%N`) | 19 / 11 | 12 | `engine/land-direct-main.sh:301` | coreutils |
| `stat -c`, `--format` | 35 / 11 | 17 | `engine/bin/worker:35`, `engine/lib.sh:815` | coreutils |
| `stat -f -c %T` | 2 / 2 | | `engine/mac-autopilot/runtime-env.sh:25` (guarded by `uname -s`) | coreutils |
| `timeout` (incl. `--foreground -k`) | 100 / 20 | 16 | `engine/mac-autopilot/loop.sh:12`, `engine/lib.sh:3805` | coreutils |
| `readlink -f`, `realpath -m` | 2 / 2 | | `engine/night/hand-agent-watchdog.sh:338`, `engine/install-pre-push-guard.sh:14` | coreutils |
| `base64 -w0`, `--decode` | 8 / 3 | | `engine/mac-autopilot/scheduler.sh:1491` | coreutils |
| `sed -i` (no suffix) | 3 / 2 | 4 | `engine/factory/feeder.sh:10`, `engine/lesson-fragments.sh:124` | gnu-sed |
| `\n` in a sed replacement | 1 / 1 | | `engine/lib.sh:9158` | gnu-sed |
| `find -printf` | 4 / 3 | 2 | `engine/issue-pipeline.sh:353`, `engine/worktree-lifecycle.sh:790` | findutils |
| `xargs -r` | 2 / 2 | 1 | `engine/run-ci-suites.sh:183` | findutils |
| `grep -P` | 4 / 1 | 1 | `engine/notify.sh:1755` | grep |
| GNU `tar` long options | 2 / 2 | | `engine/mac-autopilot/scheduler.sh:917` | gnu-tar |
| `mktemp` | 216 / 45 | 340 | 2 non-portable templates: `engine/pre-push-guard.sh:187` (suffix after the X's), `engine/hotfix/prepush-gates.sh:15` (`-p`) | coreutils |
| `nproc`, `sort -V`, `install -D`, `mv -T` | 8, 1, 1, 1 | 15 | `engine/dispatch-codex.sh:511`, `engine/mac-autopilot/start.sh:60` | coreutils |
| `flock` | 156 / 29 | 52 | `engine/lib.sh` (50), `engine/land-queue.sh` (37) | flock/util-linux |
| Python `fcntl.flock` | 13 / 4 | 13 | `engine/execution-admission.py:5` | none (POSIX, works on macOS) |
| `setsid` | 17 / 7 | 24 | `engine/mac-autopilot/scheduler.sh` (9), `engine/bin/lw:13` | util-linux |
| GNU-only userland, union (no bash, no flock) | 276 / 46 | | | |
| awk | 198 / 43 | 103 | gawk-only: 1 no-op, `engine/lib.sh:13186` | none |
| `ps`, `pgrep`, `pkill`, `kill -- -pgid` | 20 + 10 + 6 | 14 | portable forms; 2 GNU-only uses, see 4.2 | none |
| `wc -l` string-compared (BSD pads with spaces) | 0 (11 `wc -l` in prod) | 49 (tests only) | | none |
| `/bin/bash` literal | 1 prod, about 30 test | | `engine/mac-autopilot/scheduler.sh:6421` | `$BASH` (PT-8) |

On the awk row: the engine's own comment at `engine/lib.sh:13178` says the origin's awk is mawk with no gawk installed. The code already runs on a non-gawk awk, which is the situation on macOS. The one gawk requirement in the tree (`engine/ci-toolchain-preflight.mjs:68`) is for the origin's dedicated CI host and out of scope.

### 4.2 Class B: Linux kernel interfaces. Approach 2, helper

`/proc` appears in 76 production lines in 27 files. By purpose:

| Interface | Prod lines / files | Used for | Samples | Replacement |
|---|---|---|---|---|
| `/proc/<pid>/stat` | 26 / 14 | pid liveness (zombie check) and process start id, re-implemented 14 times | `engine/lib.sh:11383`, `engine/land-queue.sh:374,438,1031`, `engine/mac-autopilot/loop.sh:64`, `engine/mac-autopilot/scheduler.sh:1605`, `engine/night/hand-agent-watchdog.sh:87,106,196,323`, `engine/worktree-lifecycle.sh:154,162,809` | `pid_live`, `pid_start_id` in `engine/proc.sh` |
| `/proc/meminfo` | 13 / 9 | memory gates | `engine/bin/luna:31`, `engine/dispatch-codex.sh:21`, `engine/land-direct-main.sh:929`, `engine/execution-admission.py:352` | `host_mem_avail_mb` |
| `/proc/loadavg` | 6 / 6 | load gates | `engine/run-tick.sh:253`, `engine/bin/tput-watch:563` | `host_load1` (`os.getloadavg()` in Python) |
| `/proc/stat` (cpu) | 4 / 4 | CPU busy sampling | `engine/bin/luna:25`, `engine/bin/zc:20`, `engine/execution-admission.py:304` | `host_cpu_busy_pct` |
| `/proc/pressure/*` | 4 / 3 | memory pressure gate | `engine/bin/luna:32` | `host_mem_pressure_pct` |
| boot id (`/proc/sys/kernel/random/boot_id`) | 23 / 6 | tells a reboot from a long gap | `engine/execution-admission.py:101`, `engine/delivery-metrics.sh:8` | `host_boot_id` (`sysctl -n kern.bootsessionuuid`) |
| `/proc/<pid>/{cmdline,environ,comm}` | 8 / 5 | watchdog identity checks | `engine/night/hand-agent-watchdog.sh`, `engine/supervise-pipeline.sh:696` | `ps -o args= -p`; `environ` has no macOS equivalent, degrade (see 4.4) |
| `/proc/*/cwd` scan | 2 / 2 | which processes sit in a worktree before cleanup | `engine/worktree-lifecycle.sh:790` | `lsof -a -d cwd -Fpn` |
| `/proc/<pid>/cgroup` | 12 / 1 | worker identity and "already admitted" check | `engine/execution-admission.py:168` | run-ledger identity (section 7) |
| `/proc/uptime`, `uptime -s` | 3 / 3 | boot time | `engine/land-queue.sh:1840` | `host_boot_id` / `sysctl kern.boottime` |
| `/proc/sys/kernel/osrelease` (WSL check) | 1 / 1 | refuses to run unless on WSL | `engine/delivery-request.sh:23` | none: an origin-only adapter, see PT-8 |
| `ps -eo ... --sort`, `etimes` | 2 / 2 | process listing | `engine/dispatch-codex.sh:494`, `engine/lib.sh:816` | portable `ps` + `sort` |
| `journalctl -k` (OOM evidence) | 2 / 1 | worker death cause | `engine/mac-autopilot/runtime-env.sh:62,65` | none on macOS: no evidence, callers already treat empty as "unknown" |
| `notify-send` | 2 / 1 | desktop alert | `engine/mac-autopilot/runtime-env.sh:53` | already returns 1 when absent |

The execution-admission module already isolates its `/proc` access behind a path (`ZF_EXECUTION_PROC_ROOT`, `engine/execution-admission.py:448`). That is the seam for the macOS branch.

### 4.3 Class C: the process supervisor. Approach 3, platform branch behind shims

| Construct | Prod lines / files | Test lines | Detail |
|---|---|---|---|
| `systemctl` | 61 / 19 | 92 | verbs: `is-active` 15, `show` 13, `list-units` 12, `daemon-reload` 6, `start` 2, `stop` 2, `restart` 2, `status` 1, `reset-failed` 1, `list-timers` 1, `is-enabled` 1, `enable` 1, `cat` 1. `show` properties read: `ActiveState`, `SubState`, `MainPID`, `InvocationID`, `Result`, `ExecMainCode`, `ExecMainStatus`, `ActiveEnterTimestamp`, `LastTriggerUSec` |
| `systemd-run` | 33 / 13 | 25 | `engine/issue-pipeline.sh` (15 sites). Flags: `--user`, `--unit`, `--collect`, `--quiet`, `--wait`, `--scope`, `--pipe`, `-p RuntimeMaxSec`, `-p MemoryMax`, `-p MemorySwapMax`, `-p CPUWeight`, `-p OOMPolicy`, `-p WorkingDirectory`, `-E` |
| `journalctl` | 12 / 6 | 10 | `engine/supervise-pipeline.sh` (5), `engine/mac-autopilot/node_health.py`, `engine/bin/tput-watch:437`. Forms: `--user -u UNIT [-n N] [--since @EPOCH] [-o cat\|short-unix] [--grep=]`, and `-k --since` |
| unit files | 6 services + 6 timers | 1 | `%h` appears 36 times. `ExecStart`, `Environment`, `WorkingDirectory`, `TimeoutStartSec`, `StandardOutput=journal`; timers use `OnActiveSec`, `OnUnitActiveSec`, `OnCalendar`, `Persistent`, `RandomizedDelaySec`, `AccuracySec` |
| unit-loop service units | 0 shipped | | `engine/mac-autopilot/start.sh:81` names three (`zenoforge-autopilot-scheduler`, `-bell`, `-zombie`) and `zombie-loop.sh` is not in the tree. `docs/install.md` says to supply them yourself. A gap on every OS. |
| `run-tick.sh` unit sync | 1 block | | copies every `engine/systemd/*.service` and `*.timer` into the user unit directory each tick, then `daemon-reload` (`engine/run-tick.sh:340-362`) |

### 4.4 Constructs the brief asked about that have no occurrence in `engine/`

| Construct | Result |
|---|---|
| `free`, `ss`, `getent` | 0 |
| `unshare` | 0 in `engine/` (it appears only in the export's own sandbox script) |
| `loginctl` | 0 in code; only in `docs/install.md` (lingering) |
| `/run/user`, `XDG_RUNTIME_DIR` | 0 |
| `date -I`, `date -r`/`-v` (BSD), `sed -i ''` (BSD) | 0 / 1 (`engine/night/post-land-mttr.sh:153` is `date -u -d @...`, GNU) / 0 |
| hard-coded `/usr/bin/<tool>` in production code | 0 (75 in tests, as fixture paths) |
| `process.platform` in Node | 0 |
| `mkfifo` in production | 0 |
| jq `strptime`/`mktime` | 0 |

### 4.5 Smaller macOS facts found while reading

- `engine/mac-autopilot/loop.sh:12`: `timeout ... || rc=$?`, then only 124 and 137 are logged. On a Mac with no `timeout`, rc is 127 and the scheduler never runs, and nothing says so. This is why PT-1 adds a fail-loud check, not just a PATH fix.
- `engine/mac-autopilot/start.sh:60` uses `mv -Tf` (GNU) to swap the `autopi-live` pointer atomically.
- `engine/test-env.sh` compares `pwd -P` of a `/tmp/...` directory with the literal path. On macOS `/tmp` resolves to `/private/tmp`, so that branch falls through to the default parent. Harmless, but expect a diff in the first macOS run.
- `engine/bin/luna:65` and `engine/bin/zc:55` source `$HOME/.zenoforge/checkout/engine/thread-budget.sh`. They assume the documented layout, which is fine on every platform.

## 5. Approach per class

### 5.1 Class A: require the dependency

Reasons, in the founder's order of preference: a mature dependency exists for every row (Homebrew formulae above, distro packages on Linux); and the alternative costs more than it saves. There are 80 `date -d` sites, 32 of them in `engine/lib.sh`, a file the origin edits daily. Rewriting them to a helper means 80 edits in hot files, a fork per call, and a merge conflict per origin edit. A PATH entry costs one line.

Mechanism (`engine/platform-env.sh`, new, bash 3.2-safe so any bash can source it):

```bash
# sourced; no output; no fork and no PATH change on a Linux host that keeps the default runner
[[ -n ${ZF_PLATFORM_ENV:-} ]] && return 0
ZF_PLATFORM_ENV=1
case $OSTYPE in darwin*) ZF_OS=darwin ;; linux*) ZF_OS=linux ;; *) ZF_OS=other ;; esac
[[ $ZF_OS == linux && ${ZF_RUNNER:-systemd} == systemd ]] && return 0   # the origin's path ends here
ZF_ENGINE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ $ZF_OS == darwin ]]; then
  for ZF_BREW in /opt/homebrew /usr/local; do [[ -x $ZF_BREW/bin/brew ]] && break; done
  gnu=""
  for f in coreutils findutils gnu-sed grep gnu-tar gawk; do gnu+="$ZF_BREW/opt/$f/libexec/gnubin:"; done
  PATH="$ZF_BREW/bin:${gnu}$PATH:$ZF_BREW/opt/util-linux/bin"
fi
: "${ZF_RUNNER:=$([[ $ZF_OS == darwin ]] && echo pidfile || echo systemd)}"
: "${ZF_TIMERS:=$([[ $ZF_OS == darwin ]] && echo launchd || echo systemd)}"
[[ $ZF_RUNNER == pidfile ]] && PATH="$ZF_ENGINE_DIR/portable-shim:$PATH"
export PATH ZF_OS ZF_RUNNER ZF_TIMERS
```

It is sourced from the top of `engine/lib.sh` and `engine/mac-autopilot/runtime-env.sh` (the two roots; the unit loop does not source `lib.sh`, which is 16.5k lines with side effects). On Linux with the default runner it returns at the marked line, before touching `PATH`. Processes started by launchd, systemd or the loop inherit the `PATH` the generator wrote, so the sourced copy is a safety net for manual runs.

`execution-shim/systemd-run` looks up the "real" `systemd-run` by scanning `PATH` minus its own directory. With `ZF_RUNNER=pidfile` it finds `portable-shim/systemd-run` and wraps it with admission, so the two shims compose without edits.

Fail loud: `platform_require` (in the same file, Darwin and `ZF_RUNNER=pidfile` only) checks `bash` >= 5, GNU `timeout`, GNU `date`, `flock`, `setsid`, and exits 78 with the install command. Without it the first symptom is the silent rc 127 above.

### 5.2 Class B: one helper per kernel interface

Three files, each small enough to read in one sitting.

`engine/proc.sh` (new, bash 5). On Linux the bodies are the code that exists today, moved verbatim:

| Function | Linux (unchanged logic) | macOS |
|---|---|---|
| `pid_live PID` | `kill -0` and `/proc/PID/stat` state is not `Z` (as in `engine/worktree-lifecycle.sh:pid_live`) | `ps -o stat= -p PID`, not empty, not `Z*` |
| `pid_start_id PID` | field 22 of `/proc/PID/stat`, read with the existing `${line##*) }` split | `date -d "$(ps -o lstart= -p PID)" +%s` (epoch seconds, still numeric, because callers validate `^[0-9]+$`, e.g. `engine/land-queue.sh:1031`) |
| `host_boot_id` | `/proc/sys/kernel/random/boot_id` | `sysctl -n kern.bootsessionuuid` |
| `pids_with_cwd_under DIR` | scan `/proc/*/cwd` | `lsof -a -d cwd -Fpn` |

The start id is an opaque number: callers only compare it for equality to tell a reused pid from the original process. One-second resolution on macOS is enough because macOS pids wrap at 99999.

The Linux branch must stay `/proc` and must not become `ps`: `engine/mac-autopilot/loop.sh` records that one `ps` per worker per poll drove the origin to load 39.

`engine/hostinfo.py` (new, stdlib only; Python 3.9). Subcommands `mem_avail_mb`, `load1`, `cpu_busy_pct`, `mem_pressure_pct`, `ncpu`, `boot_id`. Linux reads `/proc`. macOS uses `os.getloadavg()`, `sysctl hw.memsize`, `memory_pressure` (free percentage), `top -l 2 -n 0 -s 1`. It is imported by `execution-admission.py` and called by the shell wrappers `host_mem_avail_mb` etc. (`engine/proc.sh`), which keep the `/proc` fast path on Linux. No psutil: there is no Homebrew formula for it, and pip on Homebrew Python is externally managed. The macOS commands above are the platform features that express the same facts.

`engine/execution-admission.py` grows a `Platform` seam around its four `/proc` uses (`identity`, `occupied`, `cpu_sample`, `resources`). On non-Linux, `identity` returns `{pid, start_id, pgid}` instead of `{start_ticks, cgroup}`, and `occupied` counts live run-ledger entries (section 7) instead of cgroups. `inherited()` already falls back to the parent-chain walk (`descendant`).

### 5.3 Class C: the supervisor. Shims over a flock ledger

Rejected options, with the reason:

| Option | Why not |
|---|---|
| Rewrite ~110 call sites to `runner_start/active/count/stop` functions (the 2026-09 plan's shape) | The diff lands in `engine/lib.sh`, `engine/land-queue.sh`, `engine/worktree-lifecycle.sh`, `engine/issue-pipeline.sh` and 15 more hot files, and every origin edit to those files conflicts. Tests stub `systemctl` through `PATH` today (92 test lines), so they would also need rewriting. |
| `launchctl submit` for each stage | A legacy subcommand with no Linux equivalent, so it cannot be tested in the Linux CI leg, and it leaves jobs loaded after exit until removed. |
| supervisord, s6, runit, pm2 | Long-lived service supervisors. None gives a named transient run with glob listing and `--collect`. |
| cron / `at` | No per-run ledger, no environment control, macOS cron needs extra privacy permissions. |

Chosen: three scripts in `engine/portable-shim/` (`systemd-run`, `systemctl`, `journalctl`), each a 4-line launcher around one Python module `engine/portable-shim/zf_units.py`. They implement exactly the forms in section 4.3, plus a contract test that lists those forms. The shims are only on `PATH` when `ZF_RUNNER=pidfile`. Section 7 has the details.

## 6. Scheduler layer

One definition of the schedule, three renderers.

### 6.1 systemd (Linux, WSL2 with systemd): unchanged

`engine/run-tick.sh` already copies `engine/systemd/*.service|*.timer` into `~/.config/systemd/user`, runs `daemon-reload`, then enables or starts every timer in `pipeline-timers.list`. Nothing changes.

### 6.2 launchd (macOS): generated from the same unit files

`engine/unitgen.py plist` reads the user unit directory (the one `run-tick.sh` just synced) and writes one LaunchAgent per service/timer pair into `~/Library/LaunchAgents/zenoforge.<name>.plist` using `plistlib` from the standard library. It is idempotent (write only when the content differs, like the `diff -q` in `run-tick.sh`). `engine/unitgen.py load` runs `launchctl bootout` then `launchctl bootstrap gui/$(id -u) <plist>` for changed files.

Because `run-tick.sh` calls `systemctl --user daemon-reload` after a unit change, and `ZF_RUNNER=pidfile` puts the `systemctl` shim first, the shim's `daemon-reload` runs `unitgen.py plist && unitgen.py load`. The tick's existing timer-health block (`is-enabled`, `is-active`, `enable --now`, `start`, `engine/run-tick.sh:398-419`) is answered by the shim from `launchctl print`. `run-tick.sh` needs no edit.

Mapping (every systemd key the shipped units use):

| systemd | launchd | Notes |
|---|---|---|
| `ExecStart=` | `ProgramArguments` (split with `shlex`, `%h` expanded) | |
| `WorkingDirectory=` | `WorkingDirectory` | |
| `Environment=` (repeated) | `EnvironmentVariables` | `PATH` gets the gnubin and shim directories prepended by the generator |
| `StandardOutput/Error=journal` | `StandardOutPath` / `StandardErrorPath` = `$AGENT_HOME/logs/units/<unit>.log` | read back by the `journalctl` shim |
| `OnActiveSec=`, `OnUnitActiveSec=` | `StartInterval` (seconds of `OnUnitActiveSec`) and `RunAtLoad` | first run at load instead of "1 min after" |
| `OnCalendar=*-*-* HH:MM:SS UTC` | `StartCalendarInterval` | launchd has no UTC; the offset is applied at generation time and corrected the next time the generator runs (daylight saving) |
| `Persistent=true` | none needed | launchd runs a missed `StartInterval` once after wake |
| `TimeoutStartSec=` | the `ProgramArguments` are wrapped in `timeout -k 30 <sec>` | keeps the 20-minute backstop that `engine/systemd/zenoforge-agent.service` exists for. Descendants are not killed (no cgroup); see section 7 |
| `RandomizedDelaySec=`, `AccuracySec=`, `After=` | dropped | contention between hosts is handled by claims, not jitter (section 8) |
| `Type=oneshot` | job without `KeepAlive` | launchd does not start a second instance while one runs |
| `[Install] WantedBy=` | n/a | `bootstrap` loads it |

Added to every plist: `SoftResourceLimits.NumberOfFiles = 8192`. The engine opens many descriptors (161 named-fd sites) and the macOS default soft limit is 256.

`unitgen.py check` exits 1 when a unit uses a directive that has no row in this table, and `unitgen.test.sh` runs it over `engine/systemd/`. The named failure it stops: a timeout or limit silently dropped on macOS, the same class as the 2h25m outage that `TimeoutStartSec` was added for.

### 6.3 Foreground loop (universal fallback)

`engine/unitgen.py loop` is a foreground scheduler over the same unit files: for each timer it computes the first and next run from `OnActiveSec`/`OnUnitActiveSec`/`OnCalendar`, runs the matching `ExecStart` under the same `timeout` wrapper and environment, and does not start a second instance of a unit that is still running. About 50 lines of Python; the parser it needs is shared with 6.2. Start it however the host starts daemons (tmux, nohup, runit, a Docker `CMD`, the WSL boot command in section 9).

`start.sh` already has the loop-mode path for the unit loop (`nohup bash loop.sh`, pid file). The issue loop had no non-systemd path before this.

### 6.4 Unit-loop service units (the gap on every OS)

New templates, in a subdirectory that `run-tick.sh`'s `*.service` glob does not match:

```
engine/systemd/templates/zenoforge-autopilot-scheduler.service.in   # Type=simple, Restart=always, ExecStart=@LIVE@/loop.sh
engine/systemd/templates/zenoforge-autopilot-bell.service.in        # ExecStart=@LIVE@/bell-loop.sh
```

`unitgen.py install` renders them for the host's `ZF_TIMERS`: a systemd user unit, a launchd plist with `KeepAlive`, or nothing in loop mode (where `start.sh` already starts them). The subdirectory is the safety property: if these files sat directly in `engine/systemd/`, the origin's tick would overwrite its own live units of the same names on the next run. `start.sh` also gets a `[[ -f ]]` guard around `zombie-loop.sh`, which is referenced but not shipped.

## 7. Per-stage transient units without systemd

Today "the transient units ARE the ledger" (`engine/issue-pipeline.sh:126`): no pid files, no lease files, no stale-pid reaper, because systemd releases a unit however its process dies. The replacement keeps that property by using the one thing the kernel already releases on any death, a held `flock`.

### 7.1 Design (`engine/portable-shim/zf_units.py`, stdlib only)

Run directory: `$AGENT_HOME/run/units/<unit>/` with `lock` and `meta.json`. Host-local, never shared.

`systemd-run [flags] -- cmd...` does this:

1. Create the directory. Open `lock` and take `LOCK_EX`. This is the registration; it happens before `systemd-run` returns, as with real systemd.
2. Start the command with `subprocess.Popen(start_new_session=True)` (the same mechanism `engine/execution-admission.py:598` already uses for `run-unit`), passing the lock descriptor to the child (`pass_fds`). Every descendant that keeps the descriptor keeps the unit "active", which is the cgroup semantics of systemd without cgroups. Killing the small monitor process therefore does not free the unit while its work still runs.
3. A detached monitor (a second `start_new_session` Python process) waits for the leader, enforces `RuntimeMaxSec` (SIGTERM to the process group, SIGKILL after `ZF_STOP_GRACE_SEC`, default 30), writes `meta.json` (`MainPID`, `pgid`, `InvocationID`, start time, `ExecMainStatus`, `ExecMainCode`, `Result`), appends stdout and stderr to `$AGENT_HOME/logs/units/<unit>.log`, and with `--collect` deletes the directory at exit.
4. `--scope` skips the monitor: the shim process itself holds the lock and runs the command in the foreground, which matches how `engine/bin/luna` and `engine/bin/zc` use it.
5. `--wait` blocks and returns the command's status.

`systemctl` verbs:

| Verb | Behavior |
|---|---|
| `is-active UNIT` | try `LOCK_SH\|LOCK_NB` on `lock`; refused = active (exit 0), granted = inactive (exit 3, prints `inactive`) |
| `show [-p P ...] [--value] UNIT` | prints the properties above from `meta.json`. An unknown unit prints `ActiveState=inactive`, `SubState=dead`, `MainPID=0`, exit 0, as systemd does |
| `list-units [--state=active] --no-legend --plain GLOB` | scans the directory, probes each lock, prints `UNIT.service loaded active running DESCRIPTION` |
| `stop UNIT` | SIGTERM the process group, wait `ZF_STOP_GRACE_SEC`, SIGKILL |
| `reset-failed`, `daemon-reload` | clear finished entries; `daemon-reload` runs the generator in launchd mode, no-op in loop mode |
| `start`, `restart`, `enable`, `is-enabled`, `cat` on `*.timer`/loop services | answered from `launchctl print` in launchd mode; in loop mode the loop process answers |
| `status`, `list-timers` | print a one-line summary (used in alert text only) |

`journalctl --user -u UNIT [-n N] [--since @EPOCH] [-o cat|short-unix] [--grep=P] [--no-pager]` reads `$AGENT_HOME/logs/units/<unit>.log`. `journalctl -k` exits 1 with no output.

A recorded-output contract test (`engine/portable-shim/zf_units.test.sh`) runs every command line from section 4.3 and compares exit codes and output with golden files captured once from a real systemd. On the WSL2 systemd-on leg the same test runs against real systemd and the shim, so the two cannot drift apart.

### 7.2 What degrades, and how each degradation is handled

| systemd feature | Without it | Handling |
|---|---|---|
| Kill the whole unit (`KillMode=control-group`) | process-group kill misses descendants that call `setsid` themselves (`engine/bin/lw`, `engine/bin/drive-train.sh`, agent CLIs) | `stop` signals the process group, then walks `pgrep -P` from the leader, the same technique `engine/bin/lw:27` uses. Escaped orphans that closed the lock fd survive. Accepted; the stage's own `RuntimeMaxSec` and the stall detector in `engine/bin/worker` bound them. |
| Cleanup after any death | n/a | Unchanged: a held lock is the only liveness signal. A reboot clears every lock. Stale `meta.json` of a killed run reports `Result=exit-code`; `reset-failed` and the next tick's sweep delete it. No pid reuse risk, because no pid is trusted. |
| `RuntimeMaxSec` | | Enforced by the monitor. |
| `MemoryMax`, `MemorySwapMax`, `OOMPolicy` | no cgroups | Recorded and logged once per unit, not enforced. The memory floor at admission (`AGENT_EXECUTION_MIN_MEM_MB`) and `bin/luna`'s memory gate still apply before a start. A runaway worker is no longer OOM-killed inside its own scope: on macOS the kernel's memory pressure handling applies to the whole machine. This is the real loss of the macOS path; do not run it on a machine you also use. |
| `CPUWeight` | | Mapped to `nice`: weight 1000 (hotfix) -> 0, otherwise +5. Advisory. |
| Capacity admission | `occupied()` counted cgroups under `/proc` | Counts live ledger entries whose unit name has an execution prefix (`zf-implement-*`, `zf-triage-*`, ...). Memory, load and CPU gates use `hostinfo.py`. The shared admission lock is an `fcntl` file lock and already works on macOS. |
| Journal | | Per-unit log files; same query forms. Retention is the existing log pruning (`$AGENT_HOME/logs`). |
| `InvocationID` | | UUID per run in `meta.json`. |

N hosts: the ledger is per host and stays per host. Whether another host may start a stage for the same ticket is decided by claims (section 8), not by this directory.

## 8. Running with N hosts

Companion document: `docs/design/DISTRIBUTED.md` owns the coordination protocol (claims as refs, leases, effect intents, lane leases, status refs, the two-host fault-injection harness, rollout and rollback). This section does not repeat it. It states where state lives for a fleet, what the portability layer has to guarantee so hosts of different operating systems can join, and where the two documents differ.

### 8.1 Where state lives

| State | Today | With N hosts |
|---|---|---|
| Stage state machine | GitHub labels | GitHub labels (unchanged) |
| Fleet control | repository variables `AGENT_PIPELINE`, `AGENT_SUPERVISOR`, `AGENT_IMPLEMENT_EXECUTOR` | unchanged. A local `PAUSE` file still stops one host only |
| Who owns ticket #N right now | the local unit name `zf-<stage>-<n>` on one machine | a claim ref on GitHub, `refs/claims/issue-<n>` (DISTRIBUTED.md section 4); the local run ledger still answers "is the process alive" |
| Merge | head-pinned `gh pr merge --match-head-commit`, a server-side compare-and-swap | unchanged; no merge lock is needed, the second merge fails |
| Release / deploy lane | local lock | one lane claim, only when a release hook is configured (the hook defaults to noop) |
| Per-ticket recovery data (attempts, stage, last branch or PR) | `$AGENT_HOME/state/<n>.json` | a checkpoint inside the claim record; the file stays as a local cache |
| Tick lock, merge lock, land queue, `units.json`, run ledger | host-local `flock` files | host-local, unchanged. Two hosts run two ticks; that is intended |
| Capacity (`AGENT_GLOBAL_EXECUTION_CAP`, `max_workers`) | per host | per host. Fleet capacity is the sum, and a host claims only what its own admission can start |
| Worktrees, clones, caches, logs | host-local | host-local, disposable, sparse |
| Host status for dashboards and `doctor --fleet` | none | `refs/status/<host>`, one ref per host, written by that host only |

### 8.2 What the portability layer guarantees to a fleet

1. **The run ledger never crosses hosts.** The pidfile runner's directory is host-local. A claim decides whether this host may start a stage; the ledger decides whether the process is alive. Neither is read by another host.
2. **A host that cannot start a stage does not claim it.** Admission (memory floor, load, run-ledger count) runs before `claim_acquire`, so a loaded Mac does not hold tickets it cannot work. This is the "claim after check, before launch" order; PT-4 makes admission work on every platform, which is what makes the order enforceable.
3. **Sleep is a designed failure.** A sleeping macOS laptop or a WSL2 instance shut down for idleness stops renewing. Its claims expire and another host takes over after the observation interval. `doctor` warns about both (D22, D23) and the install notes show the keep-alive settings; nothing else is needed.
4. **No cross-host clock trust.** Takeover uses the observer's own monotonic clock (DISTRIBUTED.md section 4.5). The launchd and loop schedulers add no new clock dependency.
5. **Mixed fleets work.** Claim and status records are plain JSON with logical host ids. They carry `os` (`linux`, `darwin`), `wsl` (true/false), `runner` and `timers`, never paths or hostnames. A macOS laptop, a WSL2 desktop and a Linux server can share one repository; tickets that need a platform use the capability labels from DISTRIBUTED.md section 4.9.
6. **The coordination code needs only `git` and `gh`**, which every platform in section 2 has. No dependency in section 3 is added for it.

How each Scion principle shows up:

| Principle | Where |
|---|---|
| No global locks | claims are per ticket; merge is head-pinned; the only shared lane is release, and only if a release hook exists |
| Server-side operations through an API | merges and rebases through the GitHub API; claims through git refs on the server (a Git Data API transport is possible behind the same functions, with no clone needed on a host) |
| Sparse, on-demand clones | worktrees stay host-local and disposable |
| Post-merge testing | unchanged |
| Reuse mature components | git refs and `gh`; GNU tools, `flock` and `setsid` from packages rather than shims |
| No over-defense | no heartbeat daemon beyond the batched renewer, no clock-skew probe |

### 8.3 Where this document and DISTRIBUTED.md section 8 differ

Both were written against the same tree. Where they diverge, this document is the portability authority, for the reason given. Ref names, lease numbers (60 s renewal batch, 15 min lease, self-fence at 600 s) and the claim keys are DISTRIBUTED.md's.

| Topic | DISTRIBUTED.md section 8 | This document | Why this document's choice |
|---|---|---|---|
| `flock` and `setsid` on macOS | Python shims (`engine/platform/bin/flock`, `setsid`) | packages: the `flock` formula and util-linux `setsid` | A maintained dependency expresses it; a hand-written `flock` shim must reproduce 7 option forms. Fallback: PT-1 adds the shim only if the macOS leg shows the packages fail (section 13). |
| Python system facts | `psutil` when importable | stdlib plus `sysctl`, `memory_pressure`, `top` | No Homebrew `psutil` formula; Homebrew Python refuses `pip install`; the same facts are available from the platform. |
| How the shims get on `PATH` | symlinks, under `$AGENT_HOME/platform/bin`, of only the missing tools | GNU `gnubin` directories on macOS, plus `engine/portable-shim/` selected by `ZF_RUNNER=pidfile` | The engine already shadows tools by prepending a directory (`execution-shim`, `gh-shim`); an explicit opt-in cannot misdetect a systemd host. |
| Process registry | JSON with `{pid, start}`, trusted by comparing start times | a held `flock` per run, inherited by the whole process tree | Liveness is released by the kernel on any death, so there is no pid to reuse and no reaper, which keeps the engine's "the units are the ledger" property. |
| Timers without systemd | one `hostd.sh` loop (renewer every 60 s, tick every 300 s, `loop.sh`) | the schedule stays in the `engine/systemd/*.timer` files; three renderers (systemd, launchd plists, `unitgen.py loop`) | One schedule definition. The renewer becomes one more `zenoforge-renewd.timer` (60 s) and every renderer picks it up. `hostd.sh` is `unitgen.py loop` under another name, so it is not added. |
| macOS test selection | allowlist `tools/macos-suites.txt`, grown by additions | deny-list `tools/quarantine-darwin.txt`, shrunk to empty | A new suite runs on macOS by default and a failure is visible; it reuses the loader of `tools/quarantine.txt`. The first run needs triage. |
| Tier labels | non-systemd Linux and macOS 13+ | non-systemd Linux, macOS 14+ | Cosmetic. macOS 13 is not a tested runner image today. |

Tickets PT-1 to PT-8 below replace the P0 to P2 tickets of DISTRIBUTED.md; its S, K and I tickets are unchanged by this document. PT-9 is the only joint item.

## 9. Windows

### 9.1 Native Windows is out of scope

Evidence (production code in `engine/`, counts as in section 4):

| What native Windows lacks | Prod lines / files |
|---|---|
| `flock(2)` locking: `flock`, named-fd locks `exec {fd}>` | 156 / 29 and 161 / 15 |
| `/proc` | 76 / 27 |
| systemd-family commands (`systemctl` 61, `systemd-run` 33, `journalctl` 12) | 106 / 29 |
| `setsid`, process-group signals (`kill -- -pgid`, `start_new_session`) | 17 / 7 and 44 / 17 |
| Python `fcntl` (the module does not exist on Windows; `engine/execution-admission.py` fails at `import`) | 13 / 4 |
| Union of the kernel and supervisor constructs above | **362 / 55** of 176 production files (31%) |
| Atomic replace of an existing file with `mv -f`/`mv -T` (NTFS refuses to replace a file another process has open) | 158 / 35 |
| Symlink pointer swap for the live engine copy (needs Developer Mode or admin) | 5 / 3 |
| `jq` process spawns (MSYS fork emulation is much slower than Linux fork) | 2,497 / 74 |

Test side: 241 test lines in 47 of 168 test files use the kernel/supervisor set (the runner executes 161 `.test.sh` and `.test.mjs` suites; `.test.py` files are driven by their shell wrappers). In addition, the 244 bash scripts (about 55k lines of production shell and 51k of test shell) still need a POSIX shell, so Git Bash/MSYS would be a fourth platform with its own quirks, on top of a third scheduler (Task Scheduler) and a third lock API. Net: at least 362 production lines to rewrite plus new tests, to get something WSL2 gives with zero rewritten lines. Revisit only if the shell core is ever replaced by Node or Python. `engine/delivery-request.sh:23` also refuses to run unless `/proc/sys/kernel/osrelease` says Microsoft, a deliberate WSL-only check in an origin-specific adapter.

### 9.2 WSL2 is the supported Windows path

Requirements: WSL 2 from the Microsoft Store (`wsl --version` must work). Microsoft's reference lists the `[boot]` section as available on Windows 11 and Server 2022.

Enable systemd. Inside the distro, as root:

```
# /etc/wsl.conf
[boot]
systemd=true
```

Then from Windows: `wsl.exe --shutdown`, wait about 8 seconds, reopen the distro. Check with `systemctl list-unit-files --type=service` and `systemctl --user is-system-running`. Run `loginctl enable-linger "$USER"` once.

Keep the VM alive. WSL shuts an idle instance down, and nothing fires while it is down. In `%UserProfile%\.wslconfig` set:

```
[general]
instanceIdleTimeout=-1
```

(documented: "Set to -1 to disable auto shutdown"; on Windows 11 `vmIdleTimeout` in `[wsl2]` also exists, default 60000 ms.) The doctor cannot read that file without crossing into `/mnt`, so it prints the reminder instead.

Fallback when systemd is off (Windows 10, or a distro where you do not want it):

1. In `$AGENT_HOME/capacity.env`: `ZF_RUNNER=pidfile` and `ZF_TIMERS=loop`.
2. Start the loop at WSL boot. `[boot] command=` runs as root each time the instance starts, so drop to the user:
   ```
   [boot]
   command = su - <user> -c "~/.zenoforge/checkout/engine/unitgen.py loop >> ~/.zenoforge/logs/loop.out 2>&1 &"
   ```
3. Keep the same `instanceIdleTimeout=-1` setting.

Line endings: a script saved with CRLF fails in bash (`$'\r': command not found`). A new root `.gitattributes` (`* text=auto eol=lf` and `*.sh text eol=lf`) protects anyone who clones on the Windows side and runs through WSL. Better still, clone inside the distro.

## 10. Tickets

Each ticket lands independently, in this order. "Neutral" means no change in the origin's live single-host Linux behavior. Diff sizes are estimates (new lines / changed lines in existing files).

### PT-1: macOS boots the unit loop

- **Files**: new `engine/platform-env.sh`, `engine/proc.sh`, `engine/Brewfile`, `engine/platform-env.test.sh`, `engine/proc.test.sh`; edits to `engine/mac-autopilot/runtime-env.sh` (+2: source the two files), `engine/mac-autopilot/loop.sh` (`pid_running` calls `pid_live`), `engine/mac-autopilot/scheduler.sh` (`pid_start` calls `pid_start_id`; `/bin/bash` at line 6421 becomes `"$BASH"`), `engine/mac-autopilot/start.sh` (guard `zombie-loop.sh`), `engine/mac-autopilot/precheck.sh` and `engine/thread-budget.sh` (one `/proc` read each), `engine/lib.sh` (+1 line: source `platform-env.sh`). Plus a minimal `macos-latest` job in `.github/workflows/engine-tests.yml`.
- **Change**: section 5.1 and the first half of 5.2: PATH with gnubin, `platform_require` (fail loud), the four functions `pid_live`, `pid_start_id`, `host_boot_id`, `pids_with_cwd_under`.
- **Why**: after this, `bash engine/mac-autopilot/start.sh` starts `loop.sh`, `bell-loop.sh`, and one scheduler tick completes on a Mac. Without it the scheduler silently never runs (rc 127 from the missing `timeout`).
- **Neutral**: yes. On Linux `platform-env.sh` returns before touching `PATH`, and the Linux bodies of the helpers are the existing `/proc` code moved verbatim (no `ps`, no extra fork).
- **Test**: `platform-env.test.sh` (fake brew prefixes for both architectures; Linux `PATH` is byte-identical before and after; `platform_require` exits 78 with a hint when `timeout` is not GNU). `proc.test.sh` (helper output equals the old inline parse for the shell's own pid, a sleeping child, a zombie, a dead pid; runs in both OS legs). macOS smoke job: `start.sh --sync-only` and `engine/mac-autopilot/start.test.sh`, `scheduler.test.sh` under `test-env.sh`.
- **Size**: about 270 (250 new, 20 changed in 7 files).

### PT-2: CI matrix and platform quarantine

- **Files**: `.github/workflows/engine-tests.yml`, `tools/run-engine-tests.sh` (+10), new `tools/portable-suites.txt`, `tools/quarantine-darwin.txt`, `tools/quarantine-wsl-nosystemd.txt`, `.gitattributes`.
- **Change**: section 11. `run-engine-tests.sh` reads every `tools/quarantine*.txt` named in `ZF_QUARANTINE_SETS` with the same loader it has today, and `PORTABLE_ONLY=1` restricts to `portable-suites.txt`. The first macOS run produces the initial `quarantine-darwin.txt`; every line needs a reason and a ticket, and the goal is an empty file.
- **Why**: every later ticket is then checked on all platforms by its own PR. Reading the code cannot tell which of the 161 suites will fail on a Mac, so the matrix finds out.
- **Neutral**: yes (CI and tools only).
- **Test**: the workflow itself; `run-engine-tests.sh` prints `QUARANTINED` counts per set as it does today.
- **Size**: about 190.

### PT-3: `engine/doctor.sh`

- **Files**: new `engine/doctor.sh`, `engine/doctor.test.sh`.
- **Change**: section 12. Written to run under bash 3.2 (no `declare -A`, no `mapfile`), because it is the script that has to run before bash 5 exists.
- **Why**: turns the silent failures (missing `timeout`, wrong `PATH` under launchd, systemd off, WSL idle shutdown) into one list with install commands.
- **Neutral**: yes (nothing calls it).
- **Test**: fixtures with a fake `PATH` for each failure; asserts exit codes and that every FAIL row has a fix line.
- **Size**: about 320 new.

### PT-4: capacity admission off `/proc`

- **Files**: new `engine/hostinfo.py`; edits to `engine/execution-admission.py` (Platform seam around `identity`, `occupied`, `cpu_sample`, `resources`, `/proc/sys/.../boot_id`), `engine/bin/luna`, `engine/bin/zc` (`cpu_busy`, `MemAvailable`, pressure), `engine/dispatch-codex.sh`, `engine/land-direct-main.sh`, `engine/gitnexus-wrapper.sh`, `engine/night/dispatch.sh`, `engine/run-tick.sh` (`/proc/loadavg`, `nproc`); `engine/proc.sh` gains `host_mem_avail_mb`, `host_load1`, `host_cpu_busy_pct`, `host_mem_pressure_pct`.
- **Change**: section 5.2. Existing test seams (`AGENT_DISPATCH_MEMINFO_FILE`, `ZF_EXECUTION_PROC_ROOT`) keep priority, so fixtures are untouched.
- **Why**: without it admission cannot see memory or load on macOS and defers every start (a gate that cannot read its inputs fails closed, by design).
- **Neutral**: yes: on Linux each helper reads the same `/proc` file the code reads today.
- **Test**: extend `execution-admission.test.py` with a fake non-Linux platform object; `hostinfo.py` unit test on both OS legs.
- **Size**: about 290 (90 new module, 70 new tests, about 130 changed in 9 files).

### PT-5: one process-identity helper in the issue loop (the riskiest ticket)

- **Files**: the 14 files that parse `/proc/<pid>/stat` themselves: `engine/lib.sh`, `engine/land-queue.sh`, `engine/land-direct-main.sh`, `engine/night/hand-agent-watchdog.sh`, `engine/worktree-lifecycle.sh`, `engine/dispatch-codex.sh`, `engine/supervise-pipeline.sh`, `engine/hand-codex-liveness.sh`, `engine/hand-completion-refill.sh`, `engine/runtime-reload.sh`, `engine/delivery-metrics.sh`, `engine/thread-budget.sh`, plus the tests that fake `/proc`.
- **Change**: each inline `read /proc/$pid/stat; ${line##*) }; awk '{print $20}'` becomes `pid_live` / `pid_start_id`.
- **Why**: the same parser exists 14 times; macOS has no `/proc`. After this the issue loop's lock-owner and watchdog logic works on macOS.
- **Neutral**: yes by construction (verbatim move), but see the risk note in section 13: these results decide lock ownership, process kills and worktree deletion.
- **Test**: `proc.test.sh` already proves equivalence; land one file per commit so each can be reverted alone; run the suite of each touched file.
- **Size**: about 100 changed (-75/+25) in 14 files.

### PT-6: portable runner shims

- **Files**: new `engine/portable-shim/{systemd-run,systemctl,journalctl}`, `engine/portable-shim/zf_units.py`, `engine/portable-shim/zf_units.test.sh`, golden fixtures.
- **Change**: section 7. Selected only by `ZF_RUNNER=pidfile`.
- **Why**: the issue loop dispatches every stage with `systemd-run`; without it nothing runs on macOS or on a Linux host without systemd.
- **Neutral**: yes: the directory is on `PATH` only when `ZF_RUNNER=pidfile`, and no Linux default selects that.
- **Test**: contract test over all command forms in 4.3 against golden output; kill-the-monitor test (unit stays active while a child holds the lock); `RuntimeMaxSec`; `--collect`; run on the `ubuntu` portable leg, both macOS legs, and WSL2.
- **Size**: about 500 new.

### PT-7: scheduler generator and unit-loop units

- **Files**: new `engine/unitgen.py`, `engine/unitgen.test.sh`, `engine/systemd/templates/*.service.in` (2); `engine/portable-shim/zf_units.py` gains the timer verbs; `engine/mac-autopilot/start.sh` unchanged except the guard in PT-1.
- **Change**: section 6.
- **Why**: gives macOS its timers and gives every OS the unit-loop services that `install.md` told users to write themselves.
- **Neutral**: yes: the templates live outside the `*.service` glob that `run-tick.sh` syncs, and the generator is only called under `ZF_TIMERS=launchd|loop`.
- **Test**: `unitgen.py check` over `engine/systemd/`; golden plists for each shipped timer (including the UTC `OnCalendar`); loop mode with a fake clock; on macOS CI, `launchctl bootstrap` of a plist that touches a file.
- **Size**: about 420 new.

### PT-8: residual constructs and test interpreters

- **Files**: `engine/dispatch-codex.sh:494` (`ps --sort`), `engine/lib.sh:816` (`etimes`), `engine/land-queue.sh:1840` (`uptime -s`), `engine/worktree-lifecycle.sh:790` (`find /proc/*/cwd` -> `pids_with_cwd_under`), `engine/night/hand-agent-watchdog.sh` (`cmdline`, `environ`: on macOS use `ps -o args=`; `environ` has no equivalent, so that check reports "unknown" and the watchdog keeps its existing fail-closed path), `engine/test-env.sh`, and the ~30 `/bin/bash` literals in 10 test files (to `"$BASH"`).
- **Change**: output-equivalent portable forms; no behavior change on Linux.
- **Why**: what the matrix reports after PT-1 to PT-7. Also: `engine/delivery-request.sh` is an origin-only adapter (it hard-requires WSL). Recommendation: leave it unchanged and classify it as origin-only in the export so it does not ship; do not port it.
- **Neutral**: yes (each replacement is covered by the owning suite).
- **Test**: the owning suites on the Linux leg and the macOS leg.
- **Size**: about 100 changed in about 15 files.

### PT-9: fleet hooks of the portability layer

- **Files**: `engine/doctor.sh` gains `--fleet`; the host record that `docs/design/DISTRIBUTED.md` publishes under `refs/status/<host>` gains four fields (`os`, `wsl`, `runner`, `timers`, read from `ZF_OS`, `ZF_RUNNER`, `ZF_TIMERS` and the WSL check D02); a new `engine/systemd/zenoforge-renewd.timer` and `.service` pair (60 s) so every scheduler renderer picks up the renewer; the claim suites are added to `tools/portable-suites.txt`.
- **Change**: section 8.2. The protocol itself (claims, leases, intents, harness) is DISTRIBUTED.md's K and I tickets and is not repeated here.
- **Why**: a fleet that mixes platforms needs to see which host is which and needs the renewer to run under launchd and the loop exactly as under systemd.
- **Neutral**: yes: with coordination off the new timer is not enabled (it is listed in `pipeline-timers.list` with its own off switch, like the supervisor timer) and the host record is not written.
- **Test**: `unitgen.py check` over the new unit; DISTRIBUTED.md's two-host harness run on the Linux, macOS and WSL2 legs.
- **Size**: about 90 (60 new, 30 changed). Depends on PT-3, PT-6, PT-7 and on DISTRIBUTED.md's K tickets.

### PT-10: documentation

- **Files**: `docs/install.md` (platform section replacing "Linux with a systemd user manager"), `docs/architecture.md` (scheduler layer, runner), `README.md` (platform table). Root files, not engine.
- **Size**: about 200.

### Totals

About 2,500 lines: roughly 1,700 in new engine files (of which about 650 are tests), about 380 changed lines in about 35 existing engine files, about 400 in CI, tools and docs. The coordination protocol (DISTRIBUTED.md) is sized separately. The first ticket is the smallest that makes the unit loop boot; PT-1 to PT-3 deliver "a Mac user can run the unit loop and knows what is missing". PT-4 to PT-7 deliver the issue loop on non-systemd hosts. PT-9 waits for DISTRIBUTED.md's coordination tickets.

In-flight upstream work: several files these tickets touch are being edited upstream right now (the unit-loop scheduler, its health module and the hotfix scripts). Before landing PT-1, PT-4, PT-5 or PT-8, check the upstream change list for those paths and keep each edit in its own small commit so a rebase stays trivial.

## 11. CI plan

`.github/workflows/engine-tests.yml`, jobs:

| Job | Runner | Runs | Required |
|---|---|---|---|
| `linux` | `ubuntu-latest` (Ubuntu 24.04), 8 shards | every suite, as today | yes |
| `linux-pidfile` | `ubuntu-latest`, `ZF_RUNNER=pidfile` | `tools/portable-suites.txt` | yes |
| `macos-arm64` | `macos-latest` (macOS 26, arm64), 4 shards | every suite except `tools/quarantine-darwin.txt` | yes |
| `macos-intel` | `macos-15-intel` | `tools/portable-suites.txt` | yes |
| `wsl2` | `windows-latest` with `Vampire/setup-wsl`, matrix `systemd: [true, false]` | portable list, plus `engine/mac-autopilot/*.test.sh`; with systemd on, the shim differential test against real systemd | yes |

`windows-latest` currently maps to Windows Server 2025, `macos-latest` to macOS 26 arm64, `ubuntu-latest` to 24.04 (actions/runner-images README, checked 2026-10-29). Intel macOS images are labelled with `-intel`.

`tools/portable-suites.txt` (about 30 lines) lists the suites that exercise the platform layer: `platform-env`, `proc`, `hostinfo`, `doctor`, `portable-shim/zf_units`, `unitgen`, `coord` (DISTRIBUTED.md), `execution-admission`, `mac-autopilot/start`, `mac-autopilot/scheduler`, `mac-autopilot/scheduler-gates`, `lib`.

Which suites run where:

| Suite group | linux | linux-pidfile | macos-arm64 | macos-intel | wsl2 (systemd on) | wsl2 (systemd off) |
|---|---|---|---|---|---|---|
| all engine suites (161) | yes | | yes, minus quarantine | | | |
| portable list | yes (inside shards) | yes | yes | yes | yes | yes |
| unit-loop suites (`engine/mac-autopilot/*.test.sh`) | yes | | yes | | yes | yes |
| shim contract vs golden | yes | yes | yes | yes | yes | yes |
| shim differential vs real systemd | | | | | yes | |
| coordination harness (DISTRIBUTED.md section 7, fake GitHub) | yes | yes | yes | | | |
| launchd bootstrap smoke | | | yes | yes | | |

Skeleton for the new jobs:

```yaml
  macos:
    strategy:
      fail-fast: false
      matrix:
        os: [macos-latest]
        shard: [0, 1, 2, 3]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22 }
      - run: brew bundle --file=engine/Brewfile
      - run: git config --global user.name ci && git config --global user.email ci@example.com
      - run: |
          PREFIX="$(brew --prefix)"
          "$PREFIX/bin/bash" -c 'source engine/platform-env.sh && bash tools/run-engine-tests.sh ${{ matrix.shard }} 4'
        env: { ZF_QUARANTINE_SETS: darwin }

  wsl2:
    runs-on: windows-latest
    strategy:
      fail-fast: false
      matrix: { systemd: [true, false] }
    steps:
      - run: git config --global core.autocrlf false
        shell: bash
      - uses: actions/checkout@v4
      - uses: Vampire/setup-wsl@v7   # use the current major from the action's README
        with:
          distribution: Ubuntu-24.04
          wsl-conf: |
            [boot]
            systemd=${{ matrix.systemd }}
          additional-packages: jq git python3 tzdata curl gawk util-linux procps
      - name: copy the tree into the Linux filesystem
        shell: wsl-bash {0}
        run: cp -a "$(wslpath '${{ github.workspace }}')/." ~/zf
      - name: run portable suites
        shell: wsl-bash {0}
        working-directory: ~/zf
        env: { PORTABLE_ONLY: "1" }
        run: ZF_RUNNER=$([ "${{ matrix.systemd }}" = true ] && echo systemd || echo pidfile) bash tools/run-engine-tests.sh 0 1
```

Notes: tests run on the Linux filesystem inside the distro, not on the Windows workspace mount, so CRLF and file modes cannot interfere. `ZF_QUARANTINE_SETS` is also set per leg. The cost of macOS and Windows minutes is nil for a public repository.

## 12. Doctor

`engine/doctor.sh [--json] [--print-path] [--fleet]`. One line per check: `PASS|WARN|FAIL  ID  detail  [fix: ...]`. Exit 1 if any FAIL. `--print-path` prints the `PATH` the engine will use, for interactive shells. Runs on bash 3.2.

| ID | Check | How | Severity |
|---|---|---|---|
| D01 | Platform supported | `uname -s` is Linux or Darwin; `MINGW*`/`MSYS*`/`CYGWIN*` -> "use WSL2" | FAIL |
| D02 | WSL generation | `/proc/sys/kernel/osrelease` contains `microsoft`; WSL1 (no `WSL2` in the string, no `/run/systemd/system`) -> FAIL | FAIL |
| D03 | State on a Linux filesystem | `AGENT_HOME`, `ZF_WORKTREE_ROOT` and the checkout are not under `/mnt/` | FAIL |
| D04 | bash >= 5.0 | `BASH_VERSINFO`; macOS fix `brew install bash` | FAIL |
| D05 | `bash` on `PATH` is the one checked | `command -v bash` equals the interpreter | WARN |
| D06 | GNU coreutils behavior | `date -d @0 +%s`, `timeout --foreground 1 true`, `stat -c %s /`, `base64 -w0 </dev/null`, `readlink -f /` all succeed | FAIL, names the missing one |
| D07 | GNU findutils, grep, sed, tar | `find . -maxdepth 0 -printf x`, `echo a \| grep -P a`, `sed -i s/a/b/ f` on a temp file, `tar --null -T /dev/null -cf - </dev/null` | FAIL |
| D08 | `flock` works | `flock -n 9 9>"$tmp"` and the fd form with `-u` | FAIL |
| D09 | `setsid` works | `setsid --wait true` | FAIL |
| D10 | git >= 2.38 | `git --version` | FAIL |
| D11 | jq >= 1.6 | `jq --version` | FAIL |
| D12 | python3 >= 3.9 with tz data | `python3 -c 'import zoneinfo; zoneinfo.ZoneInfo("America/Los_Angeles")'` | FAIL |
| D13 | node >= 20 | `node --version` | WARN if 20 or 21 (CI pins 22) |
| D14 | gh installed and authenticated | `gh auth status` | FAIL |
| D15 | Target repository set | `ZF_REPO` is not the `example-maintainer/...` placeholder; `ZF_GH_REPO` equal | FAIL |
| D16 | Repository variables readable | `gh variable get AGENT_PIPELINE` | WARN |
| D17 | An agent CLI is installed | `codex`, `claude` or `zcode` on `PATH` | FAIL |
| D18 | Scheduler PATH is sufficient | `env -i HOME=$HOME PATH=<the PATH written into units or plists> bash -c 'command -v jq gh git node python3 timeout flock setsid'` lists what a scheduled job could not find | FAIL |
| D19 | Supervisor mode is coherent | Linux: `systemctl --user show-environment` ok -> `ZF_RUNNER=systemd`; not ok and `ZF_RUNNER` unset -> FAIL with the two lines to add to `capacity.env`. macOS: the `gui/$(id -u)` launchd domain exists (WARN if the Mac has no GUI login: LaunchAgents need one) | FAIL |
| D20 | Lingering (systemd) | `loginctl show-user "$USER" -p Linger` is `yes` | WARN |
| D21 | WSL2 systemd state | `/etc/wsl.conf` has `[boot] systemd=true` and `systemctl is-system-running` answers; otherwise print the section 9 fallback | WARN |
| D22 | WSL idle shutdown | print the `instanceIdleTimeout=-1` reminder (cannot read the Windows file) | WARN (always, on WSL) |
| D23 | macOS sleep | `pmset -g` shows `sleep 0` (a sleeping Mac pauses ticks) | WARN |
| D24 | Runner end-to-end (pidfile/launchd) | `systemd-run --user --unit zf-doctor-probe --collect -- sleep 2`, `systemctl --user is-active` is 0, then gone after 3 s | FAIL |
| D25 | Free disk | at least 10 GiB free under `ZF_WORKTREE_ROOT` | WARN |
| D26 | Dedicated checkout | the checkout is a git repository on `main`, clean | WARN |
| D27 | Agent sandbox | `ZF_CODEX_SANDBOX` is `danger-full-access` (the default) -> WARN, per the security note in `docs/architecture.md` | WARN |
| D28 | Fleet (`--fleet`) | lists `refs/status/*` (one `gh api repos/R/git/matching-refs/status/` call): host id, `os`, `wsl`, runner, timers, engine commit, last update; flags two hosts that share one host id and claims whose owner has not renewed | INFO/WARN |

Every FAIL row prints the install command for the detected platform. The probes are black-box (run the real command), not version-string matching, so a Linux distro whose coreutils is already new enough passes without special cases.

## 13. Risk, size, and what was not verified

**Riskiest change: PT-5.** The identity helpers decide lock ownership in `engine/land-queue.sh`, kill decisions in `engine/night/hand-agent-watchdog.sh` and worktree deletion in `engine/worktree-lifecycle.sh`, in 14 files the origin edits constantly. A wrong field index would make a live process look dead (a lock is stolen or a worker killed) or a dead one look alive (a lock is never reclaimed). Mitigations: verbatim Linux bodies; an equivalence test against the old inline parse; one file per commit; the Linux path never starts using `ps`. PT-6 is the largest new surface but opt-in; PT-1 is the only ticket whose new code runs in every script on the origin (a one-line `source` that returns early on Linux).

**Estimated total**: about 2,500 lines across 10 tickets (section 10), not counting the coordination tickets of `docs/design/DISTRIBUTED.md`.

**Verified for this document**: every count in sections 3, 4 and 9 (recipes in the appendix); Python floor (`ast.parse` with `feature_version` 3.8 to 3.11, plus the `zoneinfo` import); Homebrew formula facts (flock exists in homebrew/core with macOS bottles, gnubin caveats for coreutils, gnu-sed, findutils, grep, gnu-tar, gawk; util-linux omits a listed set of Linux-only tools and `setsid` is not in it; no `psutil` formula); `wsl.conf` `[boot] systemd`, `wsl --shutdown`, `instanceIdleTimeout` (Microsoft Learn, updated 2026-10-16); runner image labels; the `Vampire/setup-wsl` inputs.

**Not verified (no Mac or Windows host was available)**:

1. That Homebrew's `util-linux` actually ships a working `setsid` on macOS, and whether its `flock` does (the separate `flock` formula covers the second). Fallback if `setsid` is absent: PT-1 adds a 10-line `engine/portable-shim/setsid` using `os.setsid()` and `os.execvp()`.
2. That `windows-latest` (Server 2025) runs WSL2 under `Vampire/setup-wsl` and boots systemd. The action's README discusses `windows-2022`. If it does not, pin the leg to `windows-2022`.
3. `memory_pressure` and `top -l` output formats across macOS 14, 15 and 26. `hostinfo.py` has a golden-output test per version once a Mac produces them.
4. `launchctl bootstrap` from a non-GUI session (SSH-only Mac). The doctor reports it; the supported setup is a logged-in user.
5. Which of the 161 suites fail on a Mac. The design predicts classes (section 4), not suites; PT-2 measures.
6. The WSL `[boot] command=` fallback and the Windows-side `.wslconfig` effect are taken from Microsoft's documentation, not run.
7. The macOS filesystem is case-insensitive by default. Nothing in `engine/` was found that depends on case, but a branch pair differing only in case would collide; no check was added because no failure was observed.

## Appendix: counting recipes

All counts are `grep -nE` over the script and unit files of `engine/`, with `^[[:space:]]*(#|//)` lines removed. Production excludes `*.test.*`.

| Class | Pattern |
|---|---|
| `/proc` | `/proc/` |
| `systemctl`, `systemd-run`, `journalctl` | `\bsystemctl\b`, `\bsystemd-run\b`, `\bjournalctl\b` |
| `flock` | `\bflock\b`; Python: `import fcntl\|fcntl\.` |
| `date -d` | `\bdate\b[^\|;)]*( -d[ =]\| --date\| -d"\| -d\$)` |
| `date %N` | `\bdate\b[^\|;)]*%[0-9]*N` |
| `stat -c` | `\bstat\b[^\|;)]* (-c\|--format\|--printf)` |
| `timeout` | `(^\|[^a-zA-Z_./-])timeout +(-[a-zA-Z-]+ +)*[0-9$"{]` |
| `setsid` | `\bsetsid\b` |
| `declare -A` | `declare +-[a-zA-Z]*A\|typeset +-A\|local +-[a-zA-Z]*A` |
| `mapfile` | `\b(mapfile\|readarray)\b` |
| named fd | `exec +\{[a-zA-Z_]+\}[<>]` |
| bash 5 variables | `EPOCHSECONDS\|EPOCHREALTIME\|BASHPID` |
| GNU-only userland union | `date -d`, `stat -c`, `timeout`, `readlink -f`, `realpath -m`, `base64 -w`, `-printf`, `xargs -r`, `grep -P`, `sed -i`, `%3N`, `mv -T`, `install -D`, `nproc` |
| kernel/supervisor union (section 9) | `/proc/`, `\bflock\b`, `\bsystemctl\b`, `\bsystemd-run\b`, `\bjournalctl\b`, `\bsetsid\b`, `import fcntl`, `kill -- -` |

The Python floor: `python3 -I -c` that runs `ast.parse(source, feature_version=(3, N))` over every `*.py` and `engine/bin/tput-watch`; all parse at (3, 8), and `zoneinfo` (3.9) is the binding import.

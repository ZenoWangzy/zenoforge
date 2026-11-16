# Pause restart hotfix proof

Fail-before, with `systemctl` stubbed and test files under `.git`:

- `bash engine/mac-autopilot/start.test.sh`: exit 1, `start.test.sh: restarted units during operator pause`.
- `bash engine/mac-autopilot/bell.test.sh`: exit 1, `bell.test.sh: restarted loop during operator pause`.

After the fix:

- `bash engine/mac-autopilot/start.test.sh`: exit 0, `start.test.sh: PASS` (Git discovery confined to the fixture repositories with `GIT_CEILING_DIRECTORIES`). The existing fixture self-check emits missing `lib.d/codex-mcp.sh` warnings and continues.
- `bash engine/mac-autopilot/bell.test.sh`: exit 0, `bell.test.sh: PASS`.
- `bash -n engine/mac-autopilot/{start.sh,bell.sh,runtime-env.sh,start.test.sh,bell.test.sh}`: exit 0.
- `git diff --check`: exit 0.

Diff stat:

```text
 engine/mac-autopilot/bell.sh        |  4 +++-
 engine/mac-autopilot/bell.test.sh   | 19 +++++++++++++++++++
 engine/mac-autopilot/runtime-env.sh |  7 +++++++
 engine/mac-autopilot/start.sh       |  5 +++++
 engine/mac-autopilot/start.test.sh  | 17 +++++++++++++++++
 5 files changed, 51 insertions(+), 1 deletion(-)

```

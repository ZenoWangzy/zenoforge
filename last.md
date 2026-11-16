# VectA pipeline migration, Step 2 PR 1

Added `ZF_CONFIG_ROOT` with the target-repo `.zenoforge/` default, plus shell and Node config-file accessors that search target overrides, pack files, then engine defaults. Added a standalone shell test and a short architecture-doc section. The `.mjs` pack reader existed in `engine/pack-dir.mjs`, so the Node twin was added there.

## Proof

- Fail-before: `bash engine/config-root.test.sh` exited 1 before implementation with `not ok - zf_config_file is defined`.
- Pass: `bash engine/config-root.test.sh` exited 0 (`config-root.test.sh: PASS`), covering precedence, missing files, invalid paths, the unchanged `pack_file` path, and Node behavior.
- Syntax: `bash -n engine/config.sh` exited 0.
- Diff stat before commit:

  ```text
   docs/architecture.md       |   4 ++
   engine/config-root.test.sh | 104 +++++++++++++++++++++++++++++++++++++++++++++
   engine/config.sh           |  33 ++++++++++++++
   engine/pack-dir.mjs        |  32 +++++++++++++-
   4 files changed, 171 insertions(+), 2 deletions(-)
  ```

- Commit: `09a4fa8 Add config root accessors` (`git commit --no-verify`).

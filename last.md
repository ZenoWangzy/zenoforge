# Release slice 3 handoff

No push. build check: supervisor.

## Items

1. **Release runner and root helpers: incomplete; no commit.** The engine checkout does not contain the runner or the pack's root release helpers. The pack runner is 5,239 lines and its release test is 6,317 lines; the requested config extraction and equivalence proof have not been performed. No readers switched and no product data added.

2. **Pipeline system delivery: incomplete; no commit.** The engine checkout does not contain this module or its test. No readers switched, product data added, or equivalence proof performed.

3. **Loss probe and drift filter: incomplete; no commit.** Neither script exists in engine. Their pack versions contain deployment-specific paths, service names and commands, so they must be generalized before copying. No readers switched, product data added, or equivalence proof performed.

4. **Drift registry writer: engine commit `8d4417f`.** `engine/hotfix/register-release-drift-carried.sh` is byte-identical to `pack-15/scripts/agent/hotfix/register-release-drift-carried.sh` (`cmp` exit 0). Added synthetic image upsert tests to the existing engine test; the pack test's reader integration cases depend on `release-drift-carried.sh`, which is not yet in engine. No config readers or product data changed.

   Equivalence fixture: both writers received the same registry with a file row, an old `svc` image row and an `other` image row, followed by `--image <registry> svc sha256:new 43`. `cmp` succeeded; both outputs were:

   ```text
   file\t/app/a\t42\t/copy
   image\tother\tsha256:other\t42
   image\tsvc\tsha256:new\t43
   ```

   The displayed `\t` denotes a tab. `bash -n engine/hotfix/register-release-drift-carried.sh engine/hotfix/register-release-drift-carried.test.sh`: passed. `bash engine/hotfix/register-release-drift-carried.test.sh`: all 15 cases passed.

## Validation and diff

- Final archive scan: deny-list 0, gitleaks dir 0, gitleaks git 0.
- This slice's engine diff: 2 files, 103 insertions. Product clone unchanged; no data files added, so product `cmp` is not applicable.
- Engine diff since `c4e401e`: 56 files, 1493 insertions, 102 deletions. Product diff since `57ace25`: 1 file, 34 insertions, 1 deletion.
- Prior slice handoff included migration order, role, numbers, renumber and gate, plus post-deploy migrations; changed-images remains unresolved because it imports product source. Consult the prior commits for details.

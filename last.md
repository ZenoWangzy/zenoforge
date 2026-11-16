# Incident guard target-repo fallback

The audit accepts `--target-repo <dir>`, defaulting to `ZF_REPO_DIR`. It checks targets under `--repo` and the engine build first, then checks the target repo only if neither lookup finds a file. Symbol checks run against the first file found.

## Regression test

`node --test engine/night/incident-guard-audit.test.mjs` passes all three tests. The new test, run against an `origin/main` copy of the audit, fails because the target-repo-only file and symbol file are reported missing.

The test covers a file and symbol found only in the target repo, a file absent from both, defaulting from `ZF_REPO_DIR`, explicit `--target-repo`, and an existing build file whose missing symbol is not masked by a target-repo copy.

## Built registry proof

The proof root is `.git/incident-guard-audit-live-proof.8TtKea`; its copied build registry is `engine/state/incident-guards.json`. `TARGET_REPO` pointed at the operator checkout. Both runs used `--repo "$PROOF_ROOT"`, the same history directory, and the same registry. The baseline used the `origin/main` audit; the after run used this audit and `--target-repo "$TARGET_REPO"`.

Before `.missingTargets`:

```json
[
  {
    "id": "egress-model-failfast-hand-resume",
    "targets": [
      {
        "kind": "file",
        "target": "ops/host-units/tls-proxy-bridge.test.py"
      }
    ]
  }
]
```

After `.missingTargets`: `[]`.

The registry incident count was `851` before and `851` after.

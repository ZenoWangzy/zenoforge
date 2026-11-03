# V1272: Keep verified rollback pin changes available

Rule: [V1272](../RULES.md#v1272).

## Incident

A product-pin rollback was refused by publish preflight with `resolved-config-check: CHANGED`, leaving a broken engine live. The fix is tracked on branch `feat/engine-swap-canary`.

## Root cause

The resolved-config preflight treated a deliberate product-pin rollback like an unreviewed configuration change. Its default safety gate did not recognize the explicit, verified engine-swap path.

## Chosen mechanism

Keep the ordinary changed-config refusal, while allowing only the explicit verified engine-swap/canary path to carry the pin change through preflight. The regression paths are `engine/engine-sync.test.sh` and `engine/publish-preflight/run.test.sh`.

## Options considered

- Skip resolved-config checks for every rollback. This would also permit unrelated configuration drift.
- Leave preflight unchanged and roll forward with another engine build. That keeps a known-broken engine live while the replacement is prepared.
- Require an explicit, verified engine-swap path for the pin change and keep the default refusal for other changes. This preserves the preflight gate and enables controlled recovery, so it was selected.

## Enforcer

- `engine/engine-sync.test.sh`
- `engine/publish-preflight/run.test.sh`

## Research

- [Google SRE Workbook: Canarying Releases](https://sre.google/workbook/canarying-releases/)

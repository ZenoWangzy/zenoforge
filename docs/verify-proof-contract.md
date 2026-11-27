# Verify proof contract

`engine/verify-proof-check.mjs` validates the JSON that `scripts/e2e/yangfeng-regression/verify-feature.mjs --json` writes against the plan from `engine/verification-plan.mjs`.

Invocation: `node engine/verify-proof-check.mjs --plan <plan.json> --proof <proof.json> --head <sha>`. It prints one JSON line, `{"status","features","reasons"}`, and exits 0 for every status. Exit 2 means a bad invocation (missing or unknown argument, unreadable or malformed plan). Callers read `status`, never the exit code.

Fields read from the plan: `matched_features`, an array of feature ids.

Fields read from the proof (the producer writes more; the rest is ignored):

| Field | Meaning |
|---|---|
| `source_sha` | Build sha the target served. Must equal the head under review, or share a prefix of at least 7 characters with it. `unknown` is stale. |
| `features[].feature_id` | Catalog feature id, matched to `matched_features`. |
| `features[].status` | `PASS`, `FAIL` or `HOLD`. Only `PASS` passes; the producer carries no boolean. |

Statuses:

| Status | Condition |
|---|---|
| `not-required` | The plan matches no feature, whatever the proof holds. |
| `missing` | Proof file absent or empty, or a matched feature has no result row. |
| `invalid` | Not JSON, not an object, `features` empty or absent, `source_sha` absent, or a matched feature has a non-PASS status. |
| `stale` | `source_sha` differs from the head. |
| `ok` | Every matched feature has a result and every result for it is `PASS`. |

`features` maps each matched feature id to `ok`, `missing` or `failed`. It is empty when the status is decided before per-feature results are read. `reasons` names the feature or field behind each non-ok result.

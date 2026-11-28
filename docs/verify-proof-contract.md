# Verify proof contract

`engine/verify-proof-check.mjs` validates the JSON that `scripts/e2e/yangfeng-regression/verify-feature.mjs --json` writes against the plan from `engine/verification-plan.mjs`.

Invocation: `node engine/verify-proof-check.mjs --plan <plan.json> --proof <proof.json> --head <sha>`. It prints one JSON line with `status`, `features` and `reasons`, and may include a `performance` field. It exits 0 for every proof status. Exit 2 means a bad invocation (missing or unknown argument, unreadable or malformed plan). Callers read `status`, never the exit code.

Fields read from the plan: `matched_features`, an array of feature ids.

Fields read from the proof:

| Field | Meaning |
|---|---|
| `source_sha` | Build sha the target served. Must equal the head under review, or share a prefix of at least 7 characters with it. `unknown` is stale. |
| `features[].feature_id` | Catalog feature id, matched to `matched_features`. |
| `features[].status` | `PASS`, `FAIL` or `HOLD`. Only `PASS` passes; the producer carries no boolean. |
| `features[].performance.first_paint_ms` | Median time to first paint across the measured runs, in milliseconds. |
| `features[].performance.largest_contentful_paint_ms` | Median largest contentful paint across the measured runs, in milliseconds. |
| `features[].performance.js_heap_used_mb` | Median JavaScript heap used at the end of each walk, in megabytes. |
| `features[].performance.long_task_count` | Median number of long tasks during each walk, as a count. |
| `features[].performance.run_count` | Number of completed measurement runs used for the medians, as a count. |
| `features[].performance.error_count` | Number of errors across the measurement attempts, as a count. |
| `features[].performance.work_count` | Number of feature checks or operations the producer confirmed completed, as a count. |

The producer handoff is `features[].performance` with exactly the field names above and exactly one `features[]` row per matched feature. Report the four measurements as medians across completed runs. At least 5 runs are required; any non-zero `error_count`, a zero `work_count`, or an absent/invalid measurement makes the performance result untrustworthy. The producer must count verification errors across measurement attempts and record work actually completed, not just work requested.

Budgets are resolved through `zf_config_file("state/perf-budget.json")`, which selects the target repository's `.zenoforge/state/perf-budget.json` when present. The JSON object has a required `default` entry and optional feature-id entries. Each entry has a `basis` string with at least 20 characters after trimming whitespace. The default entry supplies non-negative numeric limits for all four measurements; a feature entry may override any limits and inherits the rest from default. Entries with invalid or missing basis or invalid limits are rejected.

With no resolved budget file, performance data is ignored, the functional status is unchanged, the result includes `performance: "unconfigured"`, and the checker logs once that performance checks were skipped.

Statuses:

| Status | Condition |
|---|---|
| `not-required` | The plan matches no feature, whatever the proof holds. |
| `missing` | Proof file absent or empty, or a matched feature has no result row. |
| `invalid` | Not JSON, not an object, `features` empty or absent, `source_sha` absent, a matched feature has a non-PASS status, performance data fails the sample rules, or a budget entry is invalid. |
| `stale` | `source_sha` differs from the head. |
| `over-budget` | One or more measured values exceed their feature-specific or default limit. Each reason names the feature, metric, measured value and budget. |
| `ok` | Every matched feature passes and, when a budget file exists, its performance data is valid and within budget. |

Successful results include `performance: "ok"` when a configured performance budget passes. Invalid and over-budget paths retain their existing status and reasons.

`features` maps each matched feature id to `ok`, `missing`, `failed` or `over-budget`. It is empty when status is decided before per-feature results are read. `reasons` names the feature or field behind each non-ok result.

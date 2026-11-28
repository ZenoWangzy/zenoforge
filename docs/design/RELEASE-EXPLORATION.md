# Release exploration

## Scope

The `explore` pipeline stage reads the latest verified live SHA and starts one detached exploration run for that SHA. It can inspect only a release recorded within the previous 24 hours. State is kept under `$AGENT_HOME/state/explore/<sha>/`; a state directory is the per-release claim. Dispatch deferrals remove the claim so a later tick can retry.

Finished `done`, `skipped`, and `killed` runs and their configured checkout evidence are reclaimed after `ZF_EXPLORE_RETAIN_DAYS` days (default 14); `started` and `needs-filing` runs are retained.

The target opts in with `.zenoforge/state/exploration.json`. Missing configuration, `enabled: false`, a missing driver, or an absent or empty feature map records one skip for the live SHA. The default remains disabled.

```json
{
  "enabled": true,
  "driver": {
    "argv": ["scripts/explore-feature.sh"],
    "timeout_s": 600,
    "evidence_dir": "state/exploration-evidence"
  },
  "feature_map": "state/feature-map.json",
  "budget": {
    "wall_seconds": 3600,
    "max_tokens": 1500000,
    "max_features": 70
  },
  "max_filed_per_run": 3,
  "allowed_effects": ["read"]
}
```

`driver.argv` is executed as an argv array from the target checkout. The engine supplies `ZF_EXPLORATION_RELEASE_SHA`, `ZF_EXPLORATION_FEATURE_ID`, `ZF_EXPLORATION_FEATURE_TITLE`, `ZF_EXPLORATION_ATTEMPT`, `ZF_EXPLORATION_RUN_ID`, `ZF_EXPLORATION_FRESH_SESSION`, `ZF_EXPLORATION_EVIDENCE_DIR`, `ZF_EXPLORATION_RESULT_FILE`, `ZF_EXPLORATION_MAX_TOKENS`, and `ZF_EXPLORATION_ALLOWED_EFFECTS`. Each feature entry in the map has an `id` and `title`; entries run in map order up to `max_features`.

When the host provides an executable `ZF_CDP_BROWSER_LEASE_SCRIPT`, the driver runs under the shared-browser lease.

The configured driver must keep its run isolated and emit evidence suitable for publication with a product issue.

The driver writes one JSON object to `ZF_EXPLORATION_RESULT_FILE`:

```json
{
  "feature_id": "search",
  "status": "fail",
  "steps": ["open search", "submit query"],
  "failing_step_id": "submit-query",
  "error_class": "TypeError",
  "evidence": ["screen.png"],
  "session_id": null
}
```

`status` is `pass`, `fail`, or `skip`. A failure requires a stable step ID, an error class, and at least one evidence file under the supplied evidence directory. Separate driver invocations are fresh sessions. A reproduced defect requires the same `feature_id|failing_step_id|error_class` in two failing results. A non-null `session_id` must identify a completed Codex session; the engine measures its raw tokens with `usage_reader.py`. A deterministic driver omits it and consumes zero model tokens. An unavailable token measurement stops the run at the token budget.

The wall budget bounds the detached unit and each driver call. The token and feature budgets are checked between features. The runner writes progress after each feature, logs a summary when it completes or stops, and the next tick records a killed summary if the unit disappeared before finalizing.

Confirmed findings use `pipeline-issue-upsert.sh --lane product --label explore-found`. The upsert class hashes the stable signature, so another live SHA updates the same open issue instead of creating a duplicate. Issue bodies contain the live SHA, the steps and results from both runs, and relative evidence names with SHA-256 hashes. Each evidence image or video is attached to the issue or repeat-occurrence comment through GitHub CLI; a failed upload leaves the finding pending for retry. This needs GitHub CLI v2.99.0 or newer and repository write access ([official release note](https://github.blog/changelog/2026-09-01-github-cli-media-in-issues-pull-requests-and-comments/)). The local copies remain under exploration state and are not added to the checkout. Each run is limited to 25 evidence files and 10 MiB per file.

The engine stage is deterministic. The target driver owns the actual user interaction and session isolation; enabling it requires a configured target driver and feature map.

## Prior art

Lauren Tan, [“All Code Is Slop (Except Mine)”](https://www.youtube.com/watch?v=ZZ19zhYnDKY&t=3619s), AI Engineer Code Summit, 2026-11-11.

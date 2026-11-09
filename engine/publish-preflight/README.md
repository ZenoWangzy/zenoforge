# Publish preflight

`engine-sync.sh --preflight <new version dir> [intended-change list]` runs the gates listed in `gates.tsv`: unit paths, resolved config, no advisor.json batchRunner, prompt contracts, suite selection, and dropped file references. Converge and the pin landing check call this same runner, so adding a gate to the list includes it in both paths. The dropped-file check fails when a non-test file in the live engine is absent from the new engine while a kept script (`*.sh`, `*.py`, `*.mjs`, `*.js`, or a shebang file) still mentions its basename.

An intended-change row has three tab-separated columns: engine-relative path, reason, and the full or at least seven-character prefix of the `zenoforge_sha` from the new version's `BUILD-INFO`. The row approves only that engine SHA. This is the header comment for `.zenoforge/build/intended-changes.tsv`:

```text
# engine-relative path<TAB>reason<TAB>zenoforge SHA (full or >=7-character prefix); applies only to this engine SHA
```

Legacy two-column rows and rows for a different SHA are ignored with one `intended-changes:` warning per row in a publish preflight. The resolved-config check also reports a changed path as product-owned when a `.zenoforge/build/pack` file mapped by `PACK-FILES` changed at the new product ref, or when the new resolved bytes exactly match changed product bytes at any other product path. The build rewrites mapped files, so their bytes need not match. Product-owned edits pass with no row; engine-side changes still need a matching-SHA row. Without an intended-change list, every engine-side resolved-config change fails. Target refs come from each version's `BUILD-INFO` (`product_sha`, else the commit in `pack_sha`); the new ref falls back to `HEAD`. Set `ZF_PREFLIGHT_LIVE_REF` when the live checkout ran a later commit than the live version was built from.

A target's converge hook must call this mode after building the new version and before flipping `<agent home>/engine-live`. When invoked under `engine-sync.sh --converge`, the same call then runs the eval-on-pin gate (`engine/eval/README.md`, "Pin gate"), which can hold the flip with a nonzero exit until the new version's evaluation verdict exists. A manual `--preflight` checks build integrity without starting an evaluation.

When `engine-sync.sh` sees that the requested version ID was recorded as live in an earlier swap, it sets
`ZF_PREFLIGHT_PREVIOUSLY_LIVE=1`. The preflight still checks unit paths and suite selection, while skipping only the
resolved-config and dropped-file-reference comparisons that can reject a return to a previously live build.

`prompt-contract-check.py` compares product prompt forks with `prompt-contract.json`. A contract lists identifiers the engine reads, never sentences: a schema's required names and enum values, plus tokens. Its test fails on a token no engine code reads, so wording cannot enter the contract. When an engine change adds a required name, the fork must name it before the pin publishes.

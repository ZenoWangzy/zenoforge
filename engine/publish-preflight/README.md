# Publish preflight

`engine-sync.sh --preflight <new version dir> [intended-change list]` checks unit paths, resolved config, suite selection, and dropped file references in that order. The last check fails when a non-test file in the live engine is absent from the new engine while a kept script (`*.sh`, `*.py`, `*.mjs`, `*.js`, or a shebang file) still mentions its basename, unless its engine-relative path is on the intended-change list. Without an intended-change list, every resolved-config change fails. Target refs come from each version's `BUILD-INFO` (`product_sha`, else the commit in `pack_sha`); the new ref falls back to `HEAD`. Set `ZF_PREFLIGHT_LIVE_REF` when the live checkout ran a later commit than the live version was built from.

A target's converge hook must call this mode after building the new version and before flipping `<agent home>/engine-live`. When invoked under `engine-sync.sh --converge`, the same call then runs the eval-on-pin gate (`engine/eval/README.md`, "Pin gate"), which can hold the flip with a nonzero exit until the new version's evaluation verdict exists. A manual `--preflight` checks build integrity without starting an evaluation.

When `engine-sync.sh` sees that the requested version ID was recorded as live in an earlier swap, it sets
`ZF_PREFLIGHT_PREVIOUSLY_LIVE=1`. The preflight still checks unit paths and suite selection, while skipping only the
resolved-config and dropped-file-reference comparisons that can reject a return to a previously live build.

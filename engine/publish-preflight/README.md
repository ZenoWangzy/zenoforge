# Publish preflight

`engine-sync.sh --preflight <new version dir> [intended-change list]` checks unit paths, resolved config, and suite selection in that order. Without an intended-change list, every resolved-config change fails. Target refs come from each version's `BUILD-INFO` (`product_sha`, else the commit in `pack_sha`); the new ref falls back to `HEAD`. Set `ZF_PREFLIGHT_LIVE_REF` when the live checkout ran a later commit than the live version was built from.

A target's converge hook must call this mode after building the new version and before flipping `<agent home>/engine-live`.

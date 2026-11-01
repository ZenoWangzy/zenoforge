# Publish preflight

`engine-sync.sh --preflight <new version dir> [intended-change list]` checks unit paths, resolved config, and suite selection in that order. Without an intended-change list, every resolved-config change fails. The target checkout's `HEAD` is used for both target refs.

A target's converge hook must call this mode after building the new version and before flipping `<agent home>/engine-live`.

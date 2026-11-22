# File size only shrinks above the cap
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** A source file over 800 lines may shrink but not grow, and a new file stays at or under 800 lines; `tools/size-ratchet.sh` enforces it.
> **Do not:** grow a source file that is already over 800 lines; add a new file over 800 lines
> **Rejected:** none stated
> **Terms:** enforced rules, size ratchet, cap, shrink, `tools/size-ratchet.sh`

AGENTS.md lists four rules that every change meets. One is that a source file over 800 lines may shrink but not grow, and a new file stays at or under 800 lines, enforced by `tools/size-ratchet.sh`. The script sets `CAP=800` and uses `tools/size-baseline.txt` as its baseline.

## Consequences
- A change that adds lines to an oversized file fails the ratchet.
- Engine merges also need a green test receipt for the PR head (AGENTS.md, "Engine PR merges"), so this rule sits beside the receipt rule rather than replacing it.

Sources: AGENTS.md#enforced-rules, AGENTS.md#engine-pr-merges, tools/size-ratchet.sh (header comment)

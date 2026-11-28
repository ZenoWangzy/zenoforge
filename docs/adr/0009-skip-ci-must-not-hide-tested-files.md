# Skip-CI commits must not hide tested files
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** Direct-main admission refuses a `[skip ci]` commit when any changed file path or basename appears in a test file at that commit; the refusal names the matching files and directs the change through a PR or a CI-running commit.
> **Do not:** use `[skip ci]` for a change read by a test
> **Rejected:** none stated
> **Terms:** skip-CI commit, test reference, direct-main admission

Skipping CI can leave a documentation change unverified even when a test reads that document. Direct-main admission checks the commit's tree for references in `*.test.*` files and files under `tests/` before admitting its `[skip ci]` subject.

## Consequences
- A test-referenced file cannot land with `[skip ci]`.
- The refusal identifies the changed file and tests that mention it.
- An unrelated documentation change may still use `[skip ci]`.

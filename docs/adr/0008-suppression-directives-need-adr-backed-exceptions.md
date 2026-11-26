# Suppression directives need ADR-backed exceptions
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** New shellcheck disable, TypeScript suppression, eslint-disable, noqa and type: ignore directives fail unless an exact file, line and directive is listed with a valid ADR in tools/suppression-exceptions.json; the suppression baseline may only shrink.
> **Do not:** add a suppression directive without first fixing the finding or recording a justified exception in an ADR and the exception list
> **Rejected:** none stated
> **Terms:** suppression directive, suppression ratchet, ADR-backed exception

The comment ratchet excludes suppression directives because they are not ordinary explanatory comments. `tools/suppression-ratchet.mjs` counts them separately and keeps the current baseline from growing. An exception is tied to the exact source location and directive, and its ADR must exist in `docs/adr/`.

## Consequences
- A new suppression directive fails with its file and line and names both remedies.
- An exception without a valid ADR reference fails.
- Removing a suppression permits lowering the baseline; no workflow may increase it.
- The comment ratchet keeps its existing count and continues to exclude these directives.

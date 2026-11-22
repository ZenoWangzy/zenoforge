# Review runs on a different provider from the implementer when one is available
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** The review role uses a different provider from the implementer when that provider is available; otherwise review runs on the implementer's provider and the fallback is recorded in the issue state.
> **Do not:** pick the implementer's provider for review without recording `review_provider_fallback`; drop the `review_provider_fallback` record; make the review role share a provider silently
> **Rejected:** none stated
> **Terms:** cross-provider review, review role, implementer, `review_provider_fallback`, availability

The intent is that the reviewer uses a different provider from the implementer. In the issue loop, `review_model_for_implementer` in `engine/lib.sh` takes the review role from the live policy. A different, available provider is used. Otherwise the code records `review_provider_fallback` in the issue state and reviews on the implementer's provider. A ZCode implementer can use the `work` role's provider instead. In the unit loop, the shipped config sets review to a Claude model, read-only, and implement to a Codex model.

The two model systems are not reconciled. The `forbidden` check in the policy does not read `config.json`, which the architecture page records as a known inconsistency.

## Consequences
- The fallback is visible in the issue state, so a same-provider review can be counted.
- Availability is checked only for Codex and ZCode in the issue loop, so other providers do not count as available there.
- The rule is an intent with a recorded exception, not a hard refusal.

Sources: docs/architecture.md#5-review-by-a-different-provider, README.md#what-it-does (reviews across providers bullet)

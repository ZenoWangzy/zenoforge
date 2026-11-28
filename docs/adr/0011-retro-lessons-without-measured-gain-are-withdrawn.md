# Retro lessons without measured gain are withdrawn
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** Compare the admitted matcher in equal ten-session windows from its recorded engine version; withdraw the lesson when the after count is positive and at least the before count, then record the counts, sessions and removed paths as a withdrawal event.
> **Do not:** withdraw a lesson before both windows have candidate coverage, or when the after count is zero
> **Rejected:** open a retraction issue and leave lesson removal to a later worker
> **Terms:** admitted lesson, engine-version window, withdrawal event

Automated-check lessons are admitted after an event matcher passes its source and normal-session checks. Each Luna run records the live engine version, so the verifier compares the same matcher without mixing runs from different versions. Requiring complete ten-session windows avoids a verdict from partial coverage; a positive count that does not fall withdraws the lesson. The verifier reapplies a recorded withdrawal after checkout changes, and publishing ignores withdrawn lesson IDs, without changing evaluation cases or unrelated lessons.

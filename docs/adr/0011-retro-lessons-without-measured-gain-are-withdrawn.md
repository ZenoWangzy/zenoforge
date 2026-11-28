# Retro lessons without measured gain are withdrawn
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** After ten-session candidate windows around an admitted lesson, withdraw that lesson when the after count is positive and at least the before count; record the counts, sessions and removed paths as a withdrawal event.
> **Do not:** withdraw a lesson before both windows have candidate coverage, or when the after count is zero
> **Rejected:** open a retraction issue and leave lesson removal to a later worker
> **Terms:** admitted lesson, paired session window, withdrawal event

Automated-check lessons are admitted after an event matcher passes its source and normal-session checks. The existing retro verifier already uses equal ten-session windows and candidate counts for merged changes, so applying that verdict to admitted lessons keeps one measurement rule. Withdrawal removes the matching pending fragment, full lesson and folded rule/catalog entries, without changing evaluation cases or unrelated lessons.

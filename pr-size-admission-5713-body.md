Refs queue row 22

## What

Size admission defects seen on vecta#5713 (2055 lines at repair delivery against an 800 limit). Checked the three planned changes on origin/main first:

- (b) size check before repair dispatch: already holds. `dispatch-queue.sh:252` runs `pre_dispatch_pr_admission` for repair-pending (and `:432` for implement-pending); `harvest-workers.sh:371` rechecks after repair with the repaired head (#758). Not changed.
- (a) split on a high estimate: missing. Write-start only refused an estimate above the full limit. Now an unwaived ticket with a non-null `estimated_changed_lines` above 80% of `SIZE_ADMISSION_LINES` (640 of 800) goes down the existing recut route at write-start, with the 640 line as the evidence limit. Estimates of 640 or less and null estimates keep today's behaviour. A supervisor waiver keeps its own limit. Real diffs are still judged against the full limit. Threshold from the row 117 measurement (`~/.zenoforge/state/work/117-size-estimate-bands.md`): 481-640: 43 units, 20.9% needed a size recut later; 641-800: 34 units, 41.2%. The first plan said 60% (480); head moved it to 80% on that data.
- (c) fixtures: missing. `changed_lines_count` now holds back `fixture(s)/**.json` lines and adds them only when they exceed 500, in full.

Interpretation note: "review flag" for fixtures is the existing size-admission count, no new review field.

## Test

`engine/mac-autopilot/size-admission-estimate.test.sh` (new): fixture counting and the estimate threshold. Fails on origin/main (first fixture assertion); cases: estimate 640 admitted, 641 recut with limit 640, null estimate admitted, waived ticket keeps its limit.

## prior-art

no external prior art: scheduler-internal admission rule, no outside source applies.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

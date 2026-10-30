---- MODULE DispatchClaim ----
\* Model of the implement dispatch claim for ONE ticket (issue #4785).
\* Code mapping is in ../README.md; every action names the real function it stands for.
EXTENDS Naturals, FiniteSets

CONSTANTS
  Workers,            \* worker ids available to launch, e.g. {w1, w2}
  UseClaim,           \* coord_acquire/coord_release around dispatch (engine/coord.sh)
  SlowChecksPR,       \* slow tick dispatch() reads the open-PR census before launching
  RefillChecksPR,     \* refill tick dispatch() reads the open-PR census before launching
  CheckAfterClaim,    \* the check runs after coord_acquire (code today: before)
  FreshCheck          \* the check reads GitHub at check time (code today: the tick's earlier census)

Ticks == {"slow", "refill"}
CheckPR(t) == IF t = "slow" THEN SlowChecksPR ELSE RefillChecksPR

VARIABLES
  ledger,   \* the unit's local state: "pending" | "running" | "done"
  live,     \* implement workers whose process is alive
  prs,      \* workers that opened a PR on GitHub (a PR stays open after its worker exits)
  claim,    \* TRUE while a claim file holds the ticket
  pc,       \* per tick: "idle" | "snapped" | "checked" | "claimed" | "ready"
  seen,     \* per tick: the open-PR census it took at tick start says a PR exists
  started   \* workers already launched

vars == <<ledger, live, prs, claim, pc, seen, started>>

Init == /\ ledger = "pending" /\ live = {} /\ prs = {} /\ claim = FALSE
        /\ pc = [t \in Ticks |-> "idle"] /\ seen = [t \in Ticks |-> FALSE] /\ started = {}

\* Slow tick: tick_prs (ci-status.sh) once per tick. Refill tick takes no census (scheduler.sh refill_tick).
Snap(t) == /\ pc[t] = "idle"
           /\ pc' = [pc EXCEPT ![t] = "snapped"]
           /\ seen' = [seen EXCEPT ![t] = (t = "slow" /\ prs # {})]
           /\ UNCHANGED <<ledger, live, prs, claim, started>>

\* dispatch(): open-PR guard, coord_scheduler_live_worker, and the pending unit read from units.json.
CheckStep(t) ==
  /\ pc[t] = IF CheckAfterClaim THEN "claimed" ELSE "snapped"
  /\ LET pr == IF FreshCheck THEN prs # {} ELSE seen[t]
         ok == ledger = "pending" /\ live = {} /\ ~(CheckPR(t) /\ pr)
     IN IF ok THEN pc' = [pc EXCEPT ![t] = IF CheckAfterClaim THEN "ready" ELSE "checked"]
                   /\ UNCHANGED claim
        ELSE pc' = [pc EXCEPT ![t] = "idle"]
             /\ claim' = IF CheckAfterClaim THEN FALSE ELSE claim   \* held: coord_release
  /\ UNCHANGED <<ledger, live, prs, seen, started>>

\* coord_acquire (flock + rename): exits 1 "held" when the claim file is owned.
ClaimStep(t) ==
  /\ pc[t] = IF CheckAfterClaim THEN "snapped" ELSE "checked"
  /\ IF UseClaim /\ claim THEN pc' = [pc EXCEPT ![t] = "idle"] /\ UNCHANGED claim
     ELSE pc' = [pc EXCEPT ![t] = IF CheckAfterClaim THEN "claimed" ELSE "ready"]
          /\ claim' = UseClaim
  /\ UNCHANGED <<ledger, live, prs, seen, started>>

\* worker spawn + workers.json write; the claim stays until harvest.
Launch(t) ==
  /\ pc[t] = "ready"
  /\ \E w \in Workers \ started:
       /\ live' = live \cup {w} /\ started' = started \cup {w}
  /\ ledger' = "running"
  /\ pc' = [pc EXCEPT ![t] = "idle"]
  /\ UNCHANGED <<prs, claim, seen>>

OpenPR(w) == /\ w \in live /\ w \notin prs /\ prs' = prs \cup {w}
             /\ UNCHANGED <<ledger, live, claim, pc, seen, started>>

\* harvest_workers: report found, unit registered, claim released.
Finish(w) == /\ w \in live /\ live' = live \ {w} /\ ledger' = "done" /\ claim' = FALSE
             /\ UNCHANGED <<prs, pc, seen, started>>

\* worker dies without a report (provider limit, no output): harvest + recover_orphans put the unit back to pending.
Crash(w) == /\ w \in live /\ live' = live \ {w} /\ ledger' = "pending" /\ claim' = FALSE
            /\ UNCHANGED <<prs, pc, seen, started>>

Next == \/ \E t \in Ticks: Snap(t) \/ CheckStep(t) \/ ClaimStep(t) \/ Launch(t)
        \/ \E w \in Workers: OpenPR(w) \/ Finish(w) \/ Crash(w)

Spec == Init /\ [][Next]_vars

\* The promise: one ticket never has two implement units at once (a live worker, or a PR from an earlier one).
OneImplementUnit == Cardinality(live \cup prs) <= 1
====

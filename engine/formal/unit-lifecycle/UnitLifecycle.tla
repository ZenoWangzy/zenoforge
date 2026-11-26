---- MODULE UnitLifecycle ----
EXTENDS Naturals, FiniteSets
CONSTANT Units
\* BEGIN EDGES
Stages == {"awaiting-live-event", "blocked-external", "closed", "done", "duplicate", "eval-pending", "implement", "implement-pending", "landed", "landing", "merged", "needs-human", "parked", "ready-to-merge", "repair", "repair-pending", "rereview", "rereview-pending", "review", "review-pending", "supervisor-review", "wontfix"}
Terminal == {"closed", "done", "duplicate", "landed", "merged", "wontfix"}
Legacy == {"done", "duplicate", "wontfix"}
Initial == {"implement-pending", "review-pending"}
Escalation == {"blocked-external", "closed", "needs-human", "parked", "supervisor-review"}
Edges == {
  <<"awaiting-live-event","closed">>,
  <<"blocked-external","eval-pending">>,
  <<"blocked-external","implement-pending">>,
  <<"blocked-external","ready-to-merge">>,
  <<"blocked-external","repair-pending">>,
  <<"blocked-external","rereview-pending">>,
  <<"blocked-external","review-pending">>,
  <<"closed","eval-pending">>,
  <<"closed","implement-pending">>,
  <<"closed","ready-to-merge">>,
  <<"closed","repair-pending">>,
  <<"closed","rereview-pending">>,
  <<"closed","review-pending">>,
  <<"eval-pending","closed">>,
  <<"eval-pending","landed">>,
  <<"eval-pending","landing">>,
  <<"eval-pending","merged">>,
  <<"eval-pending","ready-to-merge">>,
  <<"eval-pending","repair-pending">>,
  <<"eval-pending","rereview-pending">>,
  <<"eval-pending","review-pending">>,
  <<"implement-pending","blocked-external">>,
  <<"implement-pending","closed">>,
  <<"implement-pending","needs-human">>,
  <<"implement-pending","parked">>,
  <<"implement-pending","review-pending">>,
  <<"landed","awaiting-live-event">>,
  <<"landed","closed">>,
  <<"landed","repair-pending">>,
  <<"landing","landed">>,
  <<"landing","ready-to-merge">>,
  <<"landing","repair-pending">>,
  <<"landing","rereview-pending">>,
  <<"merged","awaiting-live-event">>,
  <<"merged","closed">>,
  <<"merged","repair-pending">>,
  <<"needs-human","eval-pending">>,
  <<"needs-human","repair-pending">>,
  <<"needs-human","rereview-pending">>,
  <<"needs-human","review-pending">>,
  <<"parked","eval-pending">>,
  <<"parked","implement-pending">>,
  <<"parked","rereview-pending">>,
  <<"parked","review-pending">>,
  <<"ready-to-merge","eval-pending">>,
  <<"ready-to-merge","landing">>,
  <<"ready-to-merge","merged">>,
  <<"ready-to-merge","repair-pending">>,
  <<"ready-to-merge","rereview-pending">>,
  <<"repair-pending","closed">>,
  <<"repair-pending","eval-pending">>,
  <<"repair-pending","parked">>,
  <<"repair-pending","ready-to-merge">>,
  <<"repair-pending","rereview-pending">>,
  <<"repair-pending","review-pending">>,
  <<"rereview-pending","blocked-external">>,
  <<"rereview-pending","closed">>,
  <<"rereview-pending","eval-pending">>,
  <<"rereview-pending","ready-to-merge">>,
  <<"rereview-pending","repair-pending">>,
  <<"rereview-pending","review-pending">>,
  <<"review-pending","blocked-external">>,
  <<"review-pending","closed">>,
  <<"review-pending","eval-pending">>,
  <<"review-pending","needs-human">>,
  <<"review-pending","parked">>,
  <<"review-pending","ready-to-merge">>,
  <<"review-pending","repair-pending">>,
  <<"review-pending","rereview-pending">>,
  <<"supervisor-review","blocked-external">>,
  <<"supervisor-review","closed">>,
  <<"supervisor-review","merged">>,
  <<"supervisor-review","needs-human">>,
  <<"supervisor-review","parked">>,
  <<"supervisor-review","ready-to-merge">>,
  <<"supervisor-review","repair-pending">>,
  <<"supervisor-review","rereview-pending">>,
  <<"supervisor-review","review-pending">>
}
\* END EDGES
VARIABLE rows
LegalEdge(f, t) == f # t /\ (<<f, t>> \in Edges \/ (t \in Escalation /\ f \notin Legacy))
Init == \E init \in [Units -> Initial]: rows = {<<u, init[u]>> : u \in Units}
Move(u, t) == \E s \in Stages: /\ <<u, s>> \in rows /\ LegalEdge(s, t)
                               /\ rows' = (rows \ {<<u, s>>}) \cup {<<u, t>>}
Next == \E u \in Units, t \in Stages: Move(u, t)
Spec == Init /\ [][Next]_rows
ExactlyOneStage == \A u \in Units: Cardinality({s \in Stages: <<u, s>> \in rows}) = 1
RECURSIVE Reach(_, _)
Reach(S, n) == IF n = 0 THEN S ELSE Reach(S \cup {t \in Stages: \E s \in S: LegalEdge(s, t)}, n - 1)
WayOut == \A s \in Stages \ Terminal: Reach({s}, Cardinality(Stages)) \cap Terminal # {}
====

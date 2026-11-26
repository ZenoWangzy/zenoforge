---- MODULE MergeLane ----
EXTENDS Naturals, FiniteSets
CONSTANT UseLock
Callers == {"tick", "refill", "station"}
VARIABLES lock, pc
Init == lock = "none" /\ pc = [c \in Callers |-> "idle"]
Try(c) == pc[c] = "idle" /\ pc' = [pc EXCEPT ![c] = "trying"] /\ UNCHANGED lock
Take(c) == /\ pc[c] = "trying" /\ (~UseLock \/ lock = "none")
          /\ lock' = (IF UseLock THEN c ELSE lock)
          /\ pc' = [pc EXCEPT ![c] = "pass"]
Skip(c) == /\ pc[c] = "trying" /\ UseLock /\ lock # "none"
          /\ pc' = [pc EXCEPT ![c] = "idle"] /\ UNCHANGED lock
Release(c) == /\ pc[c] = "pass" /\ pc' = [pc EXCEPT ![c] = "idle"]
             /\ lock' = (IF lock = c THEN "none" ELSE lock)
Next == \E c \in Callers: Try(c) \/ Take(c) \/ Skip(c) \/ Release(c)
Spec == Init /\ [][Next]_<<lock, pc>>
OnePass == Cardinality({c \in Callers: pc[c] = "pass"}) <= 1
====

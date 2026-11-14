"""Held issues for the WIP age row: a unit on a supervisor hold waits on someone else, not on a stage the factory can move.

node_health.py sits at its size-ratchet baseline, so the state read lives here and is called from wip_stage_ages.
"""
import json, os


def on_hold(agent_home, issue):
    """True when $AGENT_HOME/state/<issue>.json has a hold or state on-hold. An unreadable file means not on hold."""
    if issue is None:
        return False
    try:
        with open(os.path.join(agent_home, "state", f"{issue}.json"), encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(state, dict) and (state.get("hold") is not None or state.get("state") == "on-hold")

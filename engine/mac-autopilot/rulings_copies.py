"""Rulings copies: the rulings file the engine resolves, against the pack's own copy.

The pack and the engine's resolved copy are two files with one job. When a ruling lands in the pack only,
the dashboard, the lane routing and the founder's words read the older copy and nothing says so. The engine copy
is rewritten when it is built (ids and paths are renamed), so rows are matched by (date, scope), which the
rewrite keeps. The value is the number of rows the pack has and the engine lacks. A row only in the engine copy
is live and harms nothing, so a ruling landed through the vendored pack does not raise this. Same-key content
drift is not seen here.

node_health.py sits at its size-ratchet baseline, so the row tables and the check live here and merge at import.
"""
import json, os
from collections import Counter
from config_paths import zf_config_file

METRIC = "rulings.copies_differ"
CRITERIA = {METRIC: ("rulings", "rulings rows in the pack copy that the engine copy lacks", 0, 1, False)}
MEANING = {METRIC: "pack 里有、引擎实际读取的 rulings.json 没有的裁决行数。不为 0 = 某条裁决只落在 pack，引擎看不到。只在引擎一边有的行不计：它们已生效。同一行内容不一致这里看不出。"}
SOURCE = {METRIC: "zf_config_file('state/rulings.json') 与 $AGENT_HOME/pack/scripts/agent/state/rulings.json，按 (date, scope) 对账，只数 pack 单边多出的行；任一文件缺失或读不出记 NO-DATA"}
PACK_RULINGS = os.path.join("pack", "scripts", "agent", "state", "rulings.json")


def _keys(path):
    try:
        with open(path, encoding="utf-8") as f:
            return Counter((r.get("date"), r.get("scope")) for r in json.load(f)["rulings"])
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


# shortcut: (date, scope) keys miss a swap of two rows that share both, upgrade when the build keeps ids.
def collect(metrics, agent_home):
    engine = zf_config_file("state/rulings.json")
    mine, theirs = _keys(engine) if engine else None, _keys(os.path.join(agent_home, PACK_RULINGS))
    metrics[METRIC] = None if mine is None or theirs is None else sum((theirs - mine).values())

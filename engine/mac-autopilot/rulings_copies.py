"""Rulings copies: the rulings file the engine resolves, against the pack's own copy.

The pack and the engine's resolved copy are two files with one job. When a ruling lands in the pack only,
the dashboard, the lane routing and the founder's words read the older copy and nothing says so. Rows are matched
by id. The build renames some ids (brand names: advisor-webgpt6-single-dialogue becomes
advisor-web-advisor-provider-single-dialogue, transform-report.py), so the rows left over on each side match by
(date, scope), as a multiset. A scope change on the same id is not a missing row. The value is the number of pack
rows still unmatched after both passes. A row only in the engine copy is live and harms nothing, so a ruling landed
through the vendored pack does not raise this. Same-id content drift is not seen here.

Source of truth: VectA's vendored copy (.zenoforge/build/pack/scripts/agent/state/rulings.json). The pack repo
(zenoforge-vecta-pack, ~/.vecta-agent/pack) is synced from it by pack PRs, so a non-zero value usually means the
pack repo lags; the fix is a pack sync PR, never an edit of the engine copy toward the pack.

node_health.py sits at its size-ratchet baseline, so the row tables and the check live here and merge at import.
"""
import json, os
from collections import Counter
from config_paths import zf_config_file

METRIC = "rulings.copies_differ"
CRITERIA = {METRIC: ("rulings", "rulings rows in the pack copy that the engine copy lacks", 0, 1, False)}
MEANING = {METRIC: "pack 里有、引擎实际读取的 rulings.json 没有的裁决行数（先按 id 对账；构建会给部分 id 改名（品牌名），剩下的行按日期+范围对上，所以改名的裁决不算缺行）。不为 0 = 某条裁决只落在 pack，引擎看不到。只在引擎一边有的行不计：它们已生效。同 id 的范围或内容变化这里不计。事实源是 VectA 的 vendored 副本；pack 仓库由 pack PR 从它同步，非 0 通常是 pack 仓库落后，修法是提 pack 同步 PR，不是把引擎副本改成 pack 的样子。"}
SOURCE = {METRIC: "zf_config_file('state/rulings.json') 与 $AGENT_HOME/pack/scripts/agent/state/rulings.json，先按 id 对账，剩下的按 (date, scope) 多重集对账，只数两轮后 pack 仍多出的行；任一文件缺失或读不出记 NO-DATA。事实源是 VectA 的 vendored 副本，pack 仓库由 pack PR 同步。"}
PACK_RULINGS = os.path.join("pack", "scripts", "agent", "state", "rulings.json")


def _rows(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)["rulings"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def _missing(theirs, mine):
    # pass 1: by id; pass 2: the leftovers by (date, scope), as a multiset (the build renames some ids)
    mine_ids = {r["id"] for r in mine if r.get("id")}
    theirs_ids = {r["id"] for r in theirs if r.get("id")}
    key = lambda r: (r.get("date"), r.get("scope"))
    theirs_left = [r for r in theirs if not (r.get("id") and r["id"] in mine_ids)]
    mine_left = [r for r in mine if not (r.get("id") and r["id"] in theirs_ids)]
    return sum((Counter(map(key, theirs_left)) - Counter(map(key, mine_left))).values())


def collect(metrics, agent_home):
    engine = zf_config_file("state/rulings.json")
    mine = _rows(engine) if engine else None
    theirs = _rows(os.path.join(agent_home, PACK_RULINGS))
    try:
        metrics[METRIC] = None if mine is None or theirs is None else _missing(theirs, mine)
    except (AttributeError, TypeError):  # a row that is not an object or has an unhashable date
        metrics[METRIC] = None

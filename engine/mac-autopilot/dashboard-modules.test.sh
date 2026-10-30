#!/usr/bin/env bash
# dashboard.html 的模块视图：左侧每个模块都能对真实数据（运行目录的 dashboard.data.js）、空数据、
# 以及"每块数据都不可用"的数据渲染出来，不抛 JS 错误、不漏出 undefined / NaN；总览每个模块一张状态卡；
# 有标准的数字画成带健康线 / 不健康线的子弹条；host.github_net_failures_per_hour 出现在主机模块。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fail() { echo "dashboard-modules.test.sh: $*" >&2; exit 1; }
command -v node >/dev/null || fail "node is required"

# 运行目录的真实数据：显式指定，或主 checkout（worktree 时取 git common dir 的上一级）的 .scratch-supervisor/autopi
live="${DASHBOARD_LIVE_DATA:-}"
if [[ -z "$live" ]]; then
  common="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  for root in "$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null || true)" "${common%/.git}"; do
    [[ -n "$root" && -s "$root/.scratch-supervisor/autopi/dashboard.data.js" ]] && { live="$root/.scratch-supervisor/autopi/dashboard.data.js"; break; }
  done
fi
# 复制一份再读：生成器每拍原地重写，读到半截会误报
snap="$test_env_root/live.data.js"
if [[ -n "$live" && -s "$live" ]]; then cp "$live" "$snap"; else : > "$snap"; echo "dashboard-modules.test.sh: no live dashboard.data.js here; empty and synthetic data only" >&2; fi

node - "$script_dir/dashboard.html" "$snap" <<'JS'
const fs = require("fs"), vm = require("vm");
const [html, dataPath] = process.argv.slice(2);
const src = fs.readFileSync(html, "utf8");
const inline = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (inline.length !== 1) throw new Error("expected one inline script, got " + inline.length);
if (!/<script src="dashboard\.data\.js"><\/script>/.test(src)) throw new Error("page no longer loads dashboard.data.js");
if (/https?:\/\/[^"'\s]*\.(?:js|css)\b|fonts\.googleapis|<link[^>]+stylesheet/i.test(src)) throw new Error("page pulls an external script, stylesheet or font");

function load(D) {
  const el = () => ({innerHTML: "", textContent: "", classList: {add() {}, remove() {}, contains() { return false; }}, style: {},
    addEventListener() {}, setAttribute() {}, removeAttribute() {}, appendChild() {}, remove() {}, dataset: {}});
  const els = {}, store = {};
  const storage = {getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }};
  const document = {getElementById: id => (els[id] = els[id] || el()), addEventListener() {}, createElement: el,
    head: el(), documentElement: el(), title: ""};
  const ctx = {document, localStorage: storage, sessionStorage: storage, setInterval() {}, setTimeout() {}, innerWidth: 1440, innerHeight: 900,
    location: {reload() {}}, console, Date, Math, JSON, Number, String, Object, Array, Set, encodeURIComponent};
  ctx.window = ctx; ctx.scrollTo = () => {}; ctx.DASH = D;
  vm.createContext(ctx);
  vm.runInContext(inline[0], ctx, {filename: "dashboard.html"});
  return {ctx, els};
}
const BAD_TEXT = /undefined|NaN|\[object Object\]|此模块渲染出错/;
function renderAll(name, D) {
  const {ctx, els} = load(D);
  const {MODULES, renderModule} = ctx.__dash;
  const out = {};
  for (const m of MODULES) {
    let html, sum;
    try { html = m.render(D); sum = m.sum(D); }
    catch (e) { throw new Error(`${name}: module ${m.id} threw: ${e.stack}`); }
    if (typeof html !== "string" || html.length < 40) throw new Error(`${name}: module ${m.id} rendered nothing`);
    const hit = html.replace(/data-tip="[^"]*"/g, "").match(BAD_TEXT);
    if (hit) throw new Error(`${name}: module ${m.id} shows "${hit[0]}": …${html.slice(Math.max(0, hit.index - 160), hit.index + 80)}…`);
    if (!["ok","warn","bad","none","OK","WARN","UNHEALTHY","NO-DATA","N/A"].includes(sum.s)) throw new Error(`${name}: module ${m.id} summary status ${sum.s}`);
    renderModule(m.id);
    if (BAD_TEXT.test(els.view.innerHTML)) throw new Error(`${name}: renderModule(${m.id}) failed in the shell`);
    if (!els.nav.innerHTML.includes(`data-m="${m.id}"`)) throw new Error(`${name}: nav lacks ${m.id}`);
    out[m.id] = html;
  }
  return {out, MODULES};
}

// 1. 空数据：每个模块都给空态而不是抛错
renderAll("empty", {});

// A paused pipeline must remain visible while its last scorecard sample ages past one configured tick.
const sampledAt = new Date(Date.now() - 121000).toISOString();
const pausedStale = {generated: new Date().toISOString(), config: {tick_seconds: 120}, standards: {
  generated_at: sampledAt, source_commit: "a1b2c3d4e5f67890", paused: {since: "2026-10-26T08:15:00Z", reason: "refactor"}, metrics: []
}};
const pausedView = load(pausedStale);
pausedView.ctx.__dash.renderModule("overview");
const header = pausedView.els.fresh.innerHTML;
for (const detail of ["评分已过期", "运行版本", "a1b2c3d4e5f6", "流水线暂停", "10-26 08:15 UTC", "refactor"])
  if (!header.includes(detail)) throw new Error(`paused stale scorecard header lacks ${detail}: ${header}`);

// 2. 每一块都"数据不可用"：分支都能画，且带原因
const broken = {front: {errors: {stages: "HTTP 502", advisor: "lib.sh missing", advisor_loop: "units.json unreadable", triage: "ledger gone", release: "git failed"}}};
const b = renderAll("unavailable", broken).out;
for (const [mod, why] of [["intake","HTTP 502"],["advisor","lib.sh missing"],["advisor","units.json unreadable"],["release","git failed"],["intake","ledger gone"]])
  if (!b[mod].includes("数据不可用") || !b[mod].includes(why)) throw new Error(`unavailable branch missing in ${mod}: ${why}`);

// 3. 真实数据（以及注入新指标后的同一份数据）
const raw = fs.readFileSync(dataPath, "utf8");
if (raw.length) {
  const D = JSON.parse(raw.replace(/^window\.DASH=/, "").replace(/;\s*$/, ""));
  const {out, MODULES} = renderAll("live", D);
  if (MODULES.length < 7 || MODULES[0].id !== "overview") throw new Error("overview must be the first of at least 7 modules");
  for (const m of MODULES.slice(1)) if (!out.overview.includes(`data-m="${m.id}"`)) throw new Error(`overview has no tile for ${m.id}`);
  // 每个有标准的 node_health 指标都以子弹条（含健康线与不健康线）出现在健康模块
  for (const m of ((D.standards||{}).metrics||[]))
    if (!out.health.includes(`${m.id}`)) throw new Error(`health module lacks metric ${m.id}`);
  const bullets = (out.health.match(/class="bul s-/g)||[]).length, ticks = (out.health.match(/class="th u"/g)||[]).length;
  if (bullets < ((D.standards||{}).metrics||[]).length || ticks !== bullets) throw new Error(`health bullets ${bullets}, unhealthy ticks ${ticks}`);
  // 前段每条标准都画出来（入口 / 顾问 / 发布三个模块合起来）
  const front = out.intake + out.advisor + out.release;
  for (const id of Object.keys(((D.front||{}).standards)||{}))
    if (!front.includes(id)) throw new Error(`front standard ${id} is not drawn`);
  for (const k of Object.keys(((D.standards||{}).ci_standards)||{}))
    if (!out.ci.includes("ci_live." + k)) throw new Error(`CI standard ${k} is not drawn`);
  const withNet = JSON.parse(JSON.stringify(D));
  withNet.standards = withNet.standards || {}; withNet.standards.metrics = (withNet.standards.metrics || []).filter(m => m.id !== "host.github_net_failures_per_hour");
  withNet.standards.metrics.push({id: "host.github_net_failures_per_hour", node: "host", desc: "GitHub fetch/API network failures per hour (user journal)",
    meaning: "每小时连不上 GitHub 的次数", value: 14, healthy: 2, unhealthy: 10, higher_is_better: false, status: "UNHEALTHY", source: "journalctl --user"});
  const host = renderAll("live+net", withNet).out.host;
  if (!/GitHub 连接失败[\s\S]*?<b>14<\/b>[\s\S]*?≤ 2[\s\S]*?≥ 10/.test(host)) throw new Error("host module does not draw host.github_net_failures_per_hour with its bounds");
}
const delivery = {front:{release:{},errors:{}}, release_train:{status:"released"}, units:[], standards:{metrics:[{
  id:"delivery.issue_to_accept_p50_7d_hours", node:"delivery", desc:"issue created -> release accepted p50, 7 d hours",
  meaning:"issue 到发布验收时长", value:36, healthy:24, unhealthy:72, higher_is_better:false, status:"WARN", source:"release-closer output"
}]}};
const deliveryOut = renderAll("delivery-metrics", delivery).out;
if (!deliveryOut.health.includes("delivery.issue_to_accept_p50_7d_hours") ||
    !deliveryOut.release.includes("issue → 验收 p50（7 天）")) throw new Error("delivery metrics are missing from the health or release dashboard sections");
const mechanisms = renderAll("mechanism-heartbeat", {standards:{window_hours:5, metrics:[{
  id:"mechanism.silent", node:"mechanisms", desc:"registered mechanisms past their silence bound",
  meaning:"机制沉默", value:1, healthy:0, unhealthy:1, higher_is_better:false, status:"UNHEALTHY", source:"registry"
}], mechanisms:[
  {id:"factory-f1-main-red-bisect", desc:"f1 main-red bisect", supervisor:"head-supervisor", last_event_at:"2026-10-29T09:00:00Z", silent_hours:3, bound_hours:24, expected_idle:true, silent:false},
  {id:"factory-f3-release-train", desc:"f3 release train", supervisor:"head-supervisor", last_event_at:"2026-10-29T10:00:00Z", silent_hours:2, bound_hours:6, expected_idle:false, silent:false},
  {id:"factory-f9-footprint-wait", desc:"f9 footprint wait", supervisor:"head-supervisor", last_event_at:"2026-10-29T11:00:00Z", silent_hours:1, bound_hours:12, expected_idle:false, silent:false}
]}}).out.health;
for (const id of ["mechanism.silent", "factory-f1-main-red-bisect", "factory-f3-release-train", "factory-f9-footprint-wait"])
  if (!mechanisms.includes(id)) throw new Error(`health dashboard lacks mechanism ${id}`);
for (const at of ["10-29 09:00 UTC", "10-29 10:00 UTC", "10-29 11:00 UTC"])
  if (!mechanisms.includes(at)) throw new Error(`health dashboard hides mechanism event time ${at}`);
const longWorker = load({config:{waste:{slow_worker_minutes:60}}, summary:{live_workers:1,max_workers:1}, workers:[{
  alive:true, unit:"pr-4371", type:"implement", model:"fixture", started:new Date(Date.now()-120*60*1000).toISOString()
}]});
longWorker.ctx.__dash.renderModule("workers");
const workerView = longWorker.els.view.innerHTML;
if (!workerView.includes("停工按进展确认") || !workerView.includes("慢工阈值 60 分") || workerView.includes("回收 90 分") || workerView.includes("会被回收"))
  throw new Error("worker dashboard still shows a fixed wall-clock kill deadline");
// worker 成本账：24h 合计、每单元 / 每 ticket、eval 单独一栏；未知（null）不画成 0，也不抛错
const ledger = {cost_ledger: {last_24h: {in: 2100000, uncached: null, out: 300000, raw: 2400000, wall_min: 512.5,
    runs: 40, failovers: 2, unknown_runs: 3, tokens: 2400000},
  by_unit: [{unit: "pr-4365", ticket: 4365, phases: ["implement"], in: 2000000, cached: 1500000, uncached: 500000,
    out: 250000, raw: 2250000, fresh: 750000, wall_min: 400.2, runs: 9, failovers: 1, unknown_runs: 0, tokens: 2250000},
    {unit: "triage", ticket: null, phases: ["triage"], in: 100000, cached: null, uncached: null, out: 50000,
     raw: 150000, fresh: null, wall_min: 112.3, runs: 31, failovers: 0, unknown_runs: 3, tokens: 150000}],
  by_ticket: [{ticket: 4365, in: 2000000, cached: 1500000, uncached: 500000, out: 250000, raw: 2250000,
    fresh: 750000, wall_min: 400.2, runs: 9, failovers: 1, unknown_runs: 0, tokens: 2250000}],
  by_phase: {implement: {raw: 2250000, in: 2000000, out: 250000, uncached: 500000, wall_min: 400.2, runs: 9, failovers: 1, unknown_runs: 0, tokens: 2250000}},
  by_backend: {codex: {raw: 2250000, in: 2000000, out: 250000, uncached: 500000, wall_min: 400.2, runs: 9, failovers: 1, unknown_runs: 0, tokens: 2250000},
    zcode: {raw: 150000, in: 100000, out: 50000, uncached: null, wall_min: 112.3, runs: 31, failovers: 0, unknown_runs: 3, tokens: 150000}},
  eval: {labels: [{label: "gold-check", runs: 4, tokens: null, unknown_tokens: 1, wall_seconds: 5000, model_wall_seconds: 4000, finished_at: "2026-10-28T01:00:00Z"}],
    last_24h: {labels: 1, runs: 4, tokens: null, unknown_tokens: 1, wall_seconds: 5000, model_wall_seconds: 4000}}}};
const ledgerOut = renderAll("cost-ledger", ledger).out;
for (const text of ["最近 24 小时 · worker 事件流", "pr-4365", "#4365", "eval（单独口径）", "按阶段", "按后端"])
  if (!ledgerOut.cost.includes(text)) throw new Error(`cost module lacks "${text}"`);
if (ledgerOut.cost.includes("NaN")) throw new Error("cost module shows NaN");
console.log("modules ok");
JS

# 页面自身：模块记忆用 localStorage 且包在 try 里；数据每 30 秒自动重载；不用 emoji
grep -Fq 'localStorage.setItem' "$script_dir/dashboard.html" || fail "selected module is not remembered"
grep -Eq 'try \{ (localStorage|return localStorage)' "$script_dir/dashboard.html" || fail "localStorage access is not wrapped in try"
grep -Fq 'setInterval(reloadData, 30000)' "$script_dir/dashboard.html" || fail "data no longer reloads every 30 seconds"
echo "dashboard-modules.test.sh: PASS"

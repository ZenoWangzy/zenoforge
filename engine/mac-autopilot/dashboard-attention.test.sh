#!/usr/bin/env bash
# dashboard.html 总览回答「工厂现在正常吗？卡在哪？谁来处理？」：固定样本触发每一种问题，期望值按样本手算（不经页面代码）。
# 检查：问题清单的行、顺序、数字；7 个数的显示；员工卡的暖色与排序；没有数据显示 —，不画成 0；估算有标。
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

node - "$script_dir/dashboard.html" <<'JS'
const fs = require("fs"), vm = require("vm");
const inline = [...fs.readFileSync(process.argv[2], "utf8").matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
function load(D) {
  const el = () => ({innerHTML: "", textContent: "", classList: {add() {}, remove() {}, contains() { return false; }}, style: {},
    addEventListener() {}, setAttribute() {}, removeAttribute() {}, appendChild() {}, remove() {}, dataset: {}});
  const els = {}, store = {}, storage = {getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }};
  const ctx = {document: {getElementById: id => (els[id] = els[id] || el()), addEventListener() {}, createElement: el, head: el(), documentElement: el(), title: ""},
    localStorage: storage, sessionStorage: storage, setInterval() {}, setTimeout() {}, innerWidth: 1440, innerHeight: 900, location: {reload() {}},
    console, Date, Math, JSON, Number, String, Object, Array, Set, encodeURIComponent};
  ctx.window = ctx; ctx.scrollTo = () => {}; ctx.DASH = D;
  vm.createContext(ctx); vm.runInContext(inline[0], ctx);
  return ctx.__dash;
}
const eq = (what, got, want) => { if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); };
const now = Date.now(), nowS = Math.floor(now / 1000), iso = new Date(now).toISOString();
const w = (owner, kind, ago, typical_s, health) => ({owner, task: "t-" + kind, backend: "cx", steps: ["a", "b"], step: 0, kind, started_epoch: ago == null ? null : nowS - ago, typical_s, health, tip: kind});
const unit = (id, stage, min) => ({id, stage, title: id, journey: {since_min: min}});
const st = (count, idle, name) => ({label: "needs-triage", name, count, idle_hours: idle, items: []});

// 样本：5 小时无输出的流水线员工、40 分钟无输出的热修员工、正常的评审员工、无日志的顾问
const D = {generated: iso, summary: {max_workers: 8, billable_daily_tokens: 33250000}, config: {daily_token_budget: 30000000},
  live_workers: {load5: 62.1, mem_avail_mb: 7653, items: [
    w("pipeline", "implement", 18000, 2700, "bad"), w("pipeline", "review", 600, 900, "ok"), w("hotfix", "hotfix", 2400, 1800, "warn"), w("advisor", "advisor", null, 600, "none")]},
  units: [unit("a", "implement-pending", 30), unit("b", "implement-pending", 30), unit("c", "implement-pending", 30), unit("d", "repair-pending", 120), unit("e", "needs-human", 5)],
  totals: {ci: "failure", suites: "success（新一轮进行中）", merged_today: [1, 2, 3]},
  front: {stages: [st(62, 591.6, "待分诊")].map(r => ({...r, label: "needs-triage"})), errors: {}, standards: {"stage.needs-triage.idle_hours": {healthy: 6, unhealthy: 24}},
    status: {"stage.needs-triage.count": "UNHEALTHY", "stage.needs-triage.idle_hours": "UNHEALTHY"}},
  standards: {metrics: [], mechanisms: [{id: "m1", silent: true, supervisor: "head-supervisor", silent_hours: 3, bound_hours: 1}, {id: "m2", silent: false, supervisor: "x"}]}};
const dash = load(D), rows = dash.problems(D, now);
// 手算：等待 = 2 位（流水线 + 热修），最久 5 时；用时超标 = 流水线 5 时（> 2 × 45 分）与热修 40 分（> 30 分）；可启动 = 3；卡住 = repair-pending 2 时（> 0.83 时）+ 需人决策 = 2；
// 产线 2 位 / 上限 8 → 空位 6；预算 33.25M / 30M = 111%；机制沉默 1 个；排队 62 个
eq("kinds", rows.map(r => r.kind), ["wait", "long", "ci", "load", "mech", "budget", "queue", "slot"]);
eq("severity", rows.map(r => r.s), ["bad", "bad", "bad", "bad", "bad", "bad", "bad", "warn"]);
eq("values", rows.map(r => r.val), [2, "5 时 0 分", "失败", "62.1", 1, "111%", 62, 3]);
eq("who", [rows[0].who, rows[4].who], ["流水线、热修", "head-supervisor"]);
if (!rows[0].rule.includes("≥ 30 分") || !rows[0].rule.includes("5 时 0 分")) throw new Error("wait rule: " + rows[0].rule);
if (!rows[1].rule.includes("（估）")) throw new Error("typical time is an estimate and must say so: " + rows[1].rule);
eq("queue", dash.workQueue(D), {startable: 3, stuck: 2});
eq("slot rule", rows[7].rule, "产线空位 6");

const html = dash.MODULES[0].render(D);
const at = s => { const i = html.indexOf(s); if (i < 0) throw new Error("overview lacks " + s); return i; };
if (!(at('class="hks"') < at(">要处理</h2>") && at(">要处理</h2>") < at('id="ov-workers"') && at('id="ov-workers"') < at('class="pst"'))) throw new Error("overview order is tiles, problems, workers, pipeline");
eq("tiles", (html.match(/class="hk s-/g) || []).length, 7);
const cards = html.match(/class="lwc [^"]*"/g);
eq("worker cards, groups by heat, hottest first inside", cards.map(c => c.match(/w-(\w+)/)[1]), ["bad", "ok", "warn", "none"]);
for (const s of ["等待 ≥30 分", "等待 ≥5 分", "工作中", "无日志", "估</small>", "可启动", "卡住"]) at(s);
if (/NaN|undefined|\[object/.test(html.replace(/data-tip="[^"]*"/g, ""))) throw new Error("overview shows NaN or undefined");

// 全部正常：没有问题行，不显示暖色
const calm = {generated: iso, summary: {max_workers: 8, billable_daily_tokens: 1000000}, config: {daily_token_budget: 30000000},
  live_workers: {load5: 3, mem_avail_mb: 9000, items: [w("pipeline", "implement", 300, 2700, "ok")]}, units: [], totals: {ci: "success", suites: "success", merged_today: []},
  standards: {metrics: [], mechanisms: []}};
eq("calm rows", dash.problems(calm, now), []);
const calmHtml = dash.MODULES[0].render(calm);
if (!calmHtml.includes("没有要处理的") || /class="hk s-(warn|bad)/.test(calmHtml) || /class="lwc [^"]*w-(warn|bad)/.test(calmHtml)) throw new Error("calm overview must carry no warm colour");

// 没有数据：显示 —，不画成 0，不抛错
const none = dash.MODULES[0].render({});
if (/NaN|undefined/.test(none) || !none.includes("无数据") || (none.match(/class="hk-v">—</g) || []).length < 4) throw new Error("empty data must read —, not 0");
eq("no data rows", dash.problems({}, now), []);
// NO-DATA 不读成正常：唯一的问题是一条无数据指标，总览显示「无数据」、计数 1，该行留在可见区而不进「正常」折叠
const ndOnly = {...calm, standards: {mechanisms: [], metrics: [{id: "test.nodata", node: "workers", desc: "测试无数据行", meaning: "", value: null, healthy: 0, unhealthy: 1, higher_is_better: false, status: "NO-DATA", source: "x"}]}};
const ndHtml = dash.MODULES[0].render(ndOnly);
if (!ndHtml.includes("1 项无数据") || /class="ov-vd s-ok"/.test(ndHtml) || !/class="ov-vd s-none"/.test(ndHtml))
  throw new Error("a NO-DATA row must not read as OK in the overview");
if (/class="ov-vd s-(warn|bad)"/.test(ndHtml)) throw new Error("NO-DATA alone must not turn the verdict red or amber");
// 行本身仍可见：在健康标准模块里，无数据行不进「正常」折叠
const ndHealth = dash.MODULES.find(m => m.id === "health").render(ndOnly);
if (!ndHealth.includes("测试无数据行") || /class="okfold"[\s\S]*测试无数据行/.test(ndHealth)) throw new Error("a blank row must stay visible, not folded into 正常");
// 等人处理：问题在前；等提单人与已合并等发布的票按等待时长排，最久在前；每行给时长与链接
const waitFx = {...calm, live_workers: {...calm.live_workers, mem_avail_mb: 1000}, front: {stages: [
  {label: "needs-info", name: "等提单人回复", count: 2, items: [{number: 11, title: "新", updated_at: new Date(now - 2 * 3600e3).toISOString()}, {number: 9, title: "旧", updated_at: new Date(now - 30 * 86400e3).toISOString()}]},
  {label: "awaiting-release", name: "已合并等发布", count: 1, items: [{number: 5, title: "中", updated_at: new Date(now - 10 * 3600e3).toISOString()}]}]}};
const wrows = dash.problems(waitFx, now);
eq("problems above waiting, waiting oldest first", wrows.map(r => r.kind + " " + r.what), ["mem 可用内存", "person #9 旧", "person #5 中", "person #11 新"]);
eq("waiting rule and age", wrows.slice(1).map(r => [r.rule, r.val]), [["等提单人回复", "30 天"], ["已合并等发布", "10 时"], ["等提单人回复", "2 时"]]);
if (!wrows[1].href.endsWith("/issues/9")) throw new Error("waiting row must link its issue: " + wrows[1].href);
console.log("attention ok");
JS
echo "dashboard-attention.test.sh: PASS"

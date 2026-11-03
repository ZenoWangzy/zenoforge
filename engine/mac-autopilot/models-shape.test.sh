#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/test-env.sh"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fixture="$test_env_root/models-shape"
repo="$fixture/repo"
sup="$fixture/supervisor"
runtime="$sup/autopi"
mkdir -p "$repo" "$runtime/alerts" "$fixture/bin" "$fixture/sessions"
git init -q -b main "$repo"

cat > "$fixture/bin/gh" <<'SH'
#!/usr/bin/env bash
echo '[]'
SH
cat > "$fixture/bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture/bin/systemctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fixture/bin/gh" "$fixture/bin/ssh" "$fixture/bin/systemctl"

export MAC_AUTOPILOT_ROOT="$repo" MAC_AUTOPILOT_SUPERVISOR_DIR="$sup"
export MAC_AUTOPILOT_RUNTIME_DIR="$runtime" MAC_AUTOPILOT_DASHBOARD_OUTPUT="$fixture/dashboard.data.js"
export MAC_AUTOPILOT_COST_CACHE="$fixture/cost-cache.json" CODEX_SESSIONS_DIR="$fixture/sessions"
export PATH="$fixture/bin:$PATH"
printf '{"units":[]}\n' > "$runtime/units.json"
printf '{"workers":[{"pid":%s,"unit":"synthetic","type":"review","log":"missing.log"}]}\n' "$$" > "$runtime/workers.json"
printf '{"date":"2026-11-03","total":0}\n' > "$runtime/budget.json"
cp "$script_dir/config.template.json" "$runtime/config.json"
touch "$runtime/scheduler.log"

export AUTOPI_TEST_LIBRARY_ONLY=true
source "$script_dir/scheduler.sh"
unset AUTOPI_TEST_LIBRARY_ONLY

fail() { echo "models-shape.test.sh: $*" >&2; exit 1; }
template="$script_dir/config.template.json"
MODEL_POLICY_FORBIDDEN_FILE=""
MODEL_POLICY_FORBIDDEN_WORDS=()

# The object is valid model-sharing configuration; the forbidden tuple must still be scanned.
CFG="$(jq '.models.implement_share={zcode:50,codex:50}
  | .models.review=["claude-haiku-5-5","high"]' "$template")"
rm -f "$A/.models-policy-warned"
: > "$LOG"
set +e
warn_forbidden_model_config
warn_status=$?
set -e
(( warn_status == 0 )) || fail "model warning scan returned $warn_status"
if grep -Fq 'jqf error' "$LOG"; then fail "model warning scan logged a jq error: $(grep -F 'jqf error' "$LOG" | head -1)"; fi
grep -Fq 'models.review=claude-haiku-5-5' "$LOG" \
  || fail 'model warning scan skipped the forbidden tuple'

# A malformed named tuple is skipped and the configured fallback remains selectable.
CFG="$(jq '.models.implement_share={zcode:50,codex:50}
  | .models.review={note:"not a tuple"}
  | .models.review_fallback=["gpt-6-luna","max","fast"]' "$template")"
: > "$LOG"
pick_configured_model review || fail 'review fallback was not selected after skipping a non-array tuple'
[[ "$PICK_MODEL" == gpt-6-luna ]] || fail "unexpected fallback model: $PICK_MODEL"
if grep -Fq 'jqf error' "$LOG"; then fail "named tuple lookup logged a jq error: $(grep -F 'jqf error' "$LOG" | head -1)"; fi

# The Python generator must carry object-shaped implement_share through its normal config output.
jq '.models.implement_share={zcode:50,codex:50}' "$template" > "$runtime/config.json"
PYTHONPATH="$script_dir" python3 "$script_dir/gen_dashboard.py"
dashboard_json="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT")"
jq -e '.config.models.implement_share == {zcode:50,codex:50}' <<<"$dashboard_json" >/dev/null \
  || fail 'dashboard generator did not load and preserve the object-shaped model setting'

# Named dashboard role values also skip malformed tuples instead of indexing an object.
jq '.models.implement_share={zcode:50,codex:50} | .models.review={note:"not a tuple"}' \
  "$template" > "$runtime/config.json"
PYTHONPATH="$script_dir" python3 "$script_dir/gen_dashboard.py"
dashboard_json="$(sed 's/^window.DASH=//; s/;$//' "$MAC_AUTOPILOT_DASHBOARD_OUTPUT")"
jq -e '.config.models.implement_share == {zcode:50,codex:50}
  and .workers[0].model == "-"' <<<"$dashboard_json" >/dev/null \
  || fail 'dashboard did not skip the malformed role tuple'

# Render the actual dashboard worker module with generated data to exercise its JS .models reader.
node - "$script_dir/dashboard.html" "$MAC_AUTOPILOT_DASHBOARD_OUTPUT" <<'JS'
const fs = require("fs"), vm = require("vm");
const [html, dataPath] = process.argv.slice(2);
const src = fs.readFileSync(html, "utf8");
const inline = [...src.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(m => m[1]);
if (inline.length !== 1) throw new Error("expected one inline dashboard script");
const D = JSON.parse(fs.readFileSync(dataPath, "utf8").replace(/^window\.DASH=/, "").replace(/;\s*$/, ""));
const el = () => ({innerHTML: "", textContent: "", classList: {add() {}, remove() {}, contains() { return false; }},
  style: {}, addEventListener() {}, setAttribute() {}, removeAttribute() {}, appendChild() {}, remove() {}, dataset: {}});
const els = {}, store = {};
const storage = {getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); }};
const document = {getElementById: id => (els[id] = els[id] || el()), addEventListener() {}, createElement: el,
  head: el(), documentElement: el(), title: ""};
const ctx = {document, localStorage: storage, sessionStorage: storage, setInterval() {}, setTimeout() {}, innerWidth: 1440,
  innerHeight: 900, location: {reload() {}}, console, Date, Math, JSON, Number, String, Object, Array, Set, encodeURIComponent};
ctx.window = ctx; ctx.scrollTo = () => {}; ctx.DASH = D;
vm.createContext(ctx);
vm.runInContext(inline[0], ctx, {filename: "dashboard.html"});
const workers = ctx.__dash.MODULES.find(module => module.id === "workers");
if (!workers) throw new Error("workers dashboard module is missing");
const rendered = workers.render(D);
if (!rendered.includes("质检员") || rendered.includes("implement_share") || rendered.includes("[object Object]"))
  throw new Error("dashboard model tags did not skip the object-shaped model setting");
console.log("models-shape.test.sh: dashboard JS model rendering PASS");
JS

node --input-type=module - "$script_dir/../focused-test-paths.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const mapFile = process.argv[2];
const { RELATED_TESTS } = await import(pathToFileURL(mapFile));
const regression = "engine/mac-autopilot/models-shape.test.sh";
for (const source of [
  "engine/mac-autopilot/scheduler.d/models.sh",
  "engine/mac-autopilot/gen_dashboard.py",
  "engine/mac-autopilot/dashboard.html",
]) {
  if (!RELATED_TESTS.get(source)?.includes(regression))
    throw new Error(`${source} does not select ${regression}`);
}
console.log("models-shape.test.sh: focused-test map PASS");
JS

echo "models-shape.test.sh: PASS"

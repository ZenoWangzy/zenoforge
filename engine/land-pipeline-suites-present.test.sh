#!/usr/bin/env bash
# A target repo that carries .github/workflows/pipeline-suites.yml gets a post-land dispatch with the landed range;
# a run that already covers the SHA suppresses it. The lander's comment must not claim an absent workflow is covered elsewhere.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"
p=$(cd "$(dirname "$0")" && pwd); t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
grep -q 'Post-land checks need the target to carry .github/workflows/pipeline-suites.yml' "$p/land-direct-main.sh" \
  || { echo "land-direct-main.sh: false 'engine's own CI' comment still stands" >&2; exit 1; }
eval "$(sed -n '/^pipeline_suites_main_focused_run_covers_sha() {/,/^}/p;/^dispatch_pipeline_suites_after_landing() {/,/^}/p' "$p/land-direct-main.sh")"
REPO=o/r; export gh_log="$t/gh.log" census_file="$t/census.json"
mkdir "$t/bin"; PATH="$t/bin:$PATH"  # timeout execs gh, so a shell function would not be seen
cat > "$t/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == api ]]; then cat "$census_file"; else echo "$*" >> "$gh_log"; fi
GH
chmod +x "$t/bin/gh"; echo '{"workflow_runs":[]}' > "$census_file"
git init -q "$t/r"; cd "$t/r"; mkdir -p .github/workflows; : > .github/workflows/pipeline-suites.yml
git add -A; git -c user.name=t -c user.email=t@t commit -q -m a; base=$(git rev-parse HEAD)
git -c user.name=t -c user.email=t@t commit -q --allow-empty -m b; head=$(git rev-parse HEAD)
dispatch_pipeline_suites_after_landing "$head" "$base"
grep -qx "workflow run pipeline-suites.yml --repo o/r --ref main -f post_land_base_sha=$base -f post_land_head_sha=$head" "$gh_log" \
  || { echo "no dispatch with the landed range:"; cat "$gh_log" >&2 || true; exit 1; }
: > "$gh_log"
printf '{"workflow_runs":[{"head_branch":"main","event":"push","path":".github/workflows/pipeline-suites.yml","status":"in_progress","display_title":"Pipeline suites post-land %s %s"}]}' "$head" "$base" > "$census_file"
dispatch_pipeline_suites_after_landing "$head" "$base"
[[ ! -s "$gh_log" ]] || { echo "dispatched although a run covers the SHA" >&2; exit 1; }
echo ok

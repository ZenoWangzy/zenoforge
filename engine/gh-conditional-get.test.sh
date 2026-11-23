#!/usr/bin/env bash
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/test-env.sh"

engine_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_dir="$(cd -- "$engine_dir/.." && pwd -P)"
test_root="$test_env_root/gh-conditional-get"
mkdir -p "$test_root/bin"
export GH_CALLS="$test_root/calls" GH_FAKE_MODE=initial
cat > "$test_root/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
method=GET conditional= include=0 paginate=0 endpoint="${args[1]:-}"
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -X|--method) i=$((i + 1)); method="${args[$i]}" ;;
    --method=*) method="${args[$i]#*=}" ;;
    -X?*) method="${args[$i]#-X}" ;;
    -H|--header)
      i=$((i + 1))
      case "${args[$i]}" in
        [Ii][Ff]-[Nn][Oo][Nn][Ee]-[Mm][Aa][Tt][Cc][Hh]:*) conditional="${args[$i]#*:}" ;;
      esac
      ;;
    -i|--include) include=1 ;;
    --paginate) paginate=1 ;;
  esac
done
printf '%s|%s|%s|%s\n' "$method" "$conditional" "$paginate" "$GH_FAKE_MODE" >> "$GH_CALLS"
respond() {
  local status="$1" etag="$2" body="$3"
  if [[ "$include" == 1 ]]; then
    printf 'HTTP/2 %s %s\r\n' "$status" "$([[ "$status" == 200 ]] && echo OK || echo 'Not Modified')"
    [[ -z "$etag" ]] || printf 'ETag: %s\r\n' "$etag"
    printf 'Content-Type: application/json\r\n\r\n'
    [[ -z "$body" ]] || printf '%s\n' "$body"
  else
    [[ -z "$body" ]] || printf '%s\n' "$body"
  fi
  [[ "$status" != 304 ]]
}
case "$GH_FAKE_MODE" in
  initial) respond 200 '"v1"' '{"value":"one"}' ;;
  not-modified) respond 304 '' '' ;;
  replace) respond 200 '"v2"' '{"value":"two"}' ;;
  write)
    if [[ -n "$conditional" ]]; then respond 304 '' ''; else respond 200 '"write"' "{\"method\":\"$method\"}"; fi
    ;;
  paginate)
    if [[ -n "$conditional" ]]; then respond 304 '' ''; else respond 200 '"page"' '{"value":"pages"}'; fi
    ;;
  *) exit 97 ;;
esac
FAKE_GH
chmod +x "$test_root/bin/gh"
export PATH="$test_root/bin:$PATH" ZF_ENGINE_DIR="$engine_dir" ZF_REPO_DIR="$repo_dir"
source "$engine_dir/lib.sh"

endpoint='repos/example/repo/items'
first="$(gh api "$endpoint")"
[[ "$first" == '{"value":"one"}' ]] || { echo "gh-conditional-get.test.sh: unexpected first body: $first" >&2; exit 1; }
export GH_FAKE_MODE=not-modified
second="$(gh api "$endpoint")" || { echo 'gh-conditional-get.test.sh: a cached 304 must succeed' >&2; exit 1; }
[[ "$second" == "$first" ]] || { echo "gh-conditional-get.test.sh: 304 returned $second" >&2; exit 1; }
grep -Fqx 'GET| "v1"|0|not-modified' "$GH_CALLS" || { echo 'gh-conditional-get.test.sh: GET did not send the cached ETag' >&2; exit 1; }

export GH_FAKE_MODE=replace
replaced="$(gh api "$endpoint")"
[[ "$replaced" == '{"value":"two"}' ]] || { echo "gh-conditional-get.test.sh: 200 did not replace the body: $replaced" >&2; exit 1; }
export GH_FAKE_MODE=not-modified
revalidated="$(gh api "$endpoint")"
[[ "$revalidated" == "$replaced" ]] || { echo "gh-conditional-get.test.sh: replacement body was not reused: $revalidated" >&2; exit 1; }
grep -Fqx 'GET| "v2"|0|not-modified' "$GH_CALLS" || { echo 'gh-conditional-get.test.sh: replaced response did not update the ETag' >&2; exit 1; }

for method in POST PATCH DELETE; do
  export GH_FAKE_MODE=write
  body="$(gh api "$endpoint" --method "$method")"
  [[ "$body" == "{\"method\":\"$method\"}" ]] || { echo "gh-conditional-get.test.sh: $method used a cached GET body: $body" >&2; exit 1; }
  grep -Fqx "$method||0|write" "$GH_CALLS" || { echo "gh-conditional-get.test.sh: $method sent If-None-Match" >&2; exit 1; }
done

export GH_FAKE_MODE=paginate
paginated="$(gh api "$endpoint" --paginate)"
[[ "$paginated" == '{"value":"pages"}' ]] || { echo "gh-conditional-get.test.sh: paginate used a cached body: $paginated" >&2; exit 1; }
grep -Fqx 'GET||1|paginate' "$GH_CALLS" || { echo 'gh-conditional-get.test.sh: --paginate sent If-None-Match' >&2; exit 1; }
echo 'gh-conditional-get.test.sh: PASS'

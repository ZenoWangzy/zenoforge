#!/usr/bin/env bash
set -euo pipefail
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$here/incident-fingerprint.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
key() { incident_class "$(incident_fingerprint "$1")"; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/incident-fp.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

sha1=0123456789abcdef0123456789abcdef01234567
sha2=89abcdef0123456789abcdef0123456789abcdef
at1="worker-died unit=issue-A at 2026-11-12T10:00:00Z count=3 secs=41 sha=$sha1"
at2="worker-died unit=issue-A at 2026-11-12T11:30:00Z count=9 secs=77 sha=$sha2"

[[ "$(key 'worker-died unit=issue-A')" != "$(key 'worker-died unit=issue-B')" ]] || fail "units A and B must give two keys"
[[ "$(key "$at1")" == "$(key "$at2")" ]] || fail "same unit at two times must give one key"
[[ "$(key "$at1")" != "$(key 'worker-died unit=issue-B at 2026-11-12T10:00:00Z')" ]] || fail "unit id must stay in the key"

# Same fingerprint reaches the open incident: upsert comments on the matching issue, creates nothing.
cat > "$tmp/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "api --method") printf '[[{"number":7,"title":"Incident","body":"<!-- vecta-incident-class:%s -->"}]]\n' "$STUB_CLASS" ;;
  "issue comment") exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/gh"
mkdir -p "$tmp/bin" "$tmp/lock"; mv "$tmp/gh" "$tmp/bin/gh"
printf 'occurrence\n' > "$tmp/body.md"
upsert() {
  STUB_CLASS="$1" STUB_LOG="$tmp/log" ZF_REPO=ZenoWangzy/zenoforge ZF_ISSUE_LOCK_DIR="$tmp/lock" PATH="$tmp/bin:$PATH" \
    bash "$here/../pipeline-issue-upsert.sh" --class "$2" --title t --body-file "$tmp/body.md" --repo ZenoWangzy/zenoforge 2>&1 || true
}
out="$(upsert "$(key "$at1")" "$(key "$at2")")"
[[ "$out" == *"commented issue #7"* ]] || fail "second occurrence must comment on the open incident: $out"
out="$(upsert "$(key "$at1")" "$(key 'worker-died unit=issue-B at 2026-11-12T10:00:00Z')")"
[[ "$out" != *"commented issue"* ]] || fail "another unit must not join the incident: $out"
echo ok

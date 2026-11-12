# Helpers for the review contract carried in the PR body and existing
# review-findings records. Source this file from the scheduler; it deliberately
# leaves stage transitions and the existing findings parser with the scheduler.

# The previous 0% first-pass approval rate and 91% rework/recheck token share
# were driven in part by reviewers reporting out-of-scope findings as blockers.
# Pull the implementer's validated contract out of its report for the scheduler
# to place in the PR body. Return compact JSON or fail when no usable block is
# present, so the reviewer never silently receives an absent contract.
contract_block_of() { # implement-report → compact JSON object
  local raw
  raw="$(awk '/^```contract[[:space:]]*$/{on=1;buf="";last="";next} on&&/^```[[:space:]]*$/{last=buf;on=0;next} on{buf=buf $0 "\n"} END{printf "%s", last}' "$1" 2>/dev/null)"
  [[ -n "${raw//[[:space:]]/}" ]] || return 1
  jq -ce 'if type=="object"
      and (.acceptance_criteria|type)=="array" and all(.acceptance_criteria[]; type=="string")
      and (.intended_files|type)=="array" and all(.intended_files[]; type=="string")
      and (.behavior_changes|type)=="array" and all(.behavior_changes[]; type=="string")
      and (.tests_added|type)=="array" and all(.tests_added[]; type=="string")
    then {acceptance_criteria,intended_files,behavior_changes,tests_added} else empty end' <<<"$raw" 2>/dev/null
}

# review_findings_block is the already-normalized array from the existing
# review-findings parser. Keep the report schema unchanged; derive a durable
# per-finding relation from the prompt's marker in the existing summary field.
# `unclassified` preserves legacy findings that predate the contract prompt.
review_findings_with_contract_relation() { # normalized findings JSON → enriched state JSON
  jq -ce 'if type!="array" then empty else map(. + {
    contract_relation: (if (.summary|type)=="string" and (.summary|startswith("[contract: in] ")) then "in-contract"
      elif (.summary|type)=="string" and (.summary|startswith("[contract: out] ")) then "out-of-contract"
      else "unclassified" end)
  }) end' <<<"$1" 2>/dev/null
}

# Blocking findings that repeat become mechanical rules. A reviewer-supplied `class` is exact; otherwise the
# rule plus the first six summary words stands in for it.
# shortcut: summary wording drifts between reviews, so near-duplicates may miss; upgrade when the review prompt emits `class`.
review_finding_class_key() { # normalized finding JSON → stable slug, at most 50 chars
  local finding="$1" slug text
  slug="$(jq -r 'if (.class|type)=="string" and (.class|test("^[a-z0-9][a-z0-9-]{0,49}$")) then .class else "" end' <<<"$finding" 2>/dev/null)" || return 0
  if [[ -z "$slug" ]]; then
    text="$(jq -r '(.summary // "") | sub("^\\[contract: (in|out)\\] "; "") | gsub("^\\s+|\\s+$"; "")' <<<"$finding" 2>/dev/null)" || return 0
    # An empty summary has nothing to key on; a shared hash would merge unrelated findings into one ticket.
    [[ -n "$text" ]] || return 0
    # Non-ASCII text is dropped from the words, so `写入 null 判空` and `读取 null 判空` would collide: hash the whole text instead.
    if ! LC_ALL=C grep -q '[^ -~]' <<<"$text"; then
      slug="$(jq -r '. as $f
        | (($f.summary // "") | sub("^\\[contract: (in|out)\\] "; "") | split(" ") | .[0:6] | join(" ")
          | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")) as $words
        | if $words == "" then ""
          else ((($f.rule // "finding") | ascii_downcase | gsub("[^a-z0-9]+"; "-") | gsub("^-+|-+$"; "")) + "-" + $words)
            | gsub("^-+|-+$"; "") | .[0:50] | gsub("-+$"; "")
          end' <<<"$finding" 2>/dev/null)" || return 0
    fi
    # shortcut: no ASCII words or non-ASCII text falls back to an exact-text hash, so a reworded Chinese summary misses its recurrence; upgrade when the prompt emits `class`.
    if [[ -z "$slug" ]]; then
      slug="finding-$(printf '%s|%s' "$(jq -r '.rule // ""' <<<"$finding" 2>/dev/null)" "$text" | sha1sum | cut -c1-12)"
    fi
  fi
  printf '%s\n' "$slug"
}

# Counts each class once per unit in the state file (a rereview of the same unit does not count again). The second unit
# with a class opens one rule ticket through pipeline-issue-upsert; later units add to it there. The count is saved only
# after that write succeeds, so a failed write is retried. The evidence sidecar keeps the units and the first finding.
review_findings_record_classes() { # normalized findings JSON, state file, upsert script, unit → rc 1 when a ticket write failed
  local findings="$1" state="$2" upsert="$3" unit="$4" evidence="$2.evidence"
  mkdir -p -- "$(dirname -- "$state")" || return 1
  (
    flock -x 9
    declare -A seen=()
    local rc=0 finding key count body first
    [[ -s "$state" ]] || printf '{}\n' > "$state"
    [[ -s "$evidence" ]] || printf '{}\n' > "$evidence"
    while IFS= read -r finding; do
      key="$(review_finding_class_key "$finding")"
      [[ -n "$key" && -z "${seen[$key]:-}" ]] || continue
      seen[$key]=1
      jq -e --arg k "$key" --arg u "$unit" '(.[$k].units // []) | index($u) == null' "$evidence" >/dev/null || continue
      count="$(jq -r --arg k "$key" '(.[$k] // 0) + 1' "$state")" || { rc=1; continue; }
      first="$(jq -r --arg k "$key" '.[$k].first // empty | "unit `\(.unit)`, \(.file):\(.line): \(.summary)"' "$evidence")"
      if (( count >= 2 )); then
        body="$(mktemp)"
        printf 'Blocking review finding class `%s` recurred in unit `%s`.\n\n- This finding: %s\n- Earlier finding: %s\n\nAdd a deterministic check that makes this finding impossible: a lint, a test, a type or a structure rule. A check, not another review comment.\n' \
          "$key" "$unit" "$(jq -r '"\(.file):\(.line): \(.summary)"' <<<"$finding")" "${first:-not recorded}" > "$body"
        if ! bash "$upsert" --lane pipeline-system --class "review-$key" --title "Repeated review finding: $key" \
          --body-file "$body" --label principle-encode-lessons-in-structure >/dev/null; then
          rc=1
          rm -f -- "$body"
          continue
        fi
        rm -f -- "$body"
      fi
      jq --arg k "$key" --argjson n "$count" '.[$k] = $n' "$state" > "$state.tmp" && mv -- "$state.tmp" "$state" || rc=1
      jq --arg k "$key" --arg u "$unit" --argjson f "$(jq -c --arg u "$unit" '{unit:$u,file,line,summary}' <<<"$finding")" \
        '.[$k].units += [$u] | .[$k].first //= $f' "$evidence" > "$evidence.tmp" && mv -- "$evidence.tmp" "$evidence" || rc=1
    done < <(jq -c '.[] | select(.status=="open" and (.severity=="P0" or .severity=="P1"))' <<<"$findings" 2>/dev/null)
    exit "$rc"
  ) 9>"$state.lock"
}

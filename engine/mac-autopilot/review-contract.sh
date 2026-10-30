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

#!/usr/bin/env bash
# Shared Codex identity: flags may move; shell text mentioning Codex is not an owner.
hand_codex_parse_processes() {
  local with_pid="${1:-0}" nul="${2:-0}"
  awk -v with_pid="$with_pid" -v nul="$nul" '
    function basename(path) { sub(/^.*\//, "", path); return path }
    function emit(n, first, exe, i, wt) {
      first = with_pid + 1
      exe = basename(argv[first])
      if (exe == "node" || exe == "nodejs" || exe == "bash" || exe == "sh") {
        first++; exe = basename(argv[first])
      }
      if ((exe != "codex" && exe != "codex.js") || argv[first+1] != "exec") return
      for (i=first+2; i<=n; i++) {
        wt = ""
        if (argv[i] == "--cd" && i<n) wt = argv[i+1]
        else if (index(argv[i], "--cd=") == 1) wt = substr(argv[i], 6)
        if (wt != "") { print (with_pid ? argv[1] "\t" : "") wt; return }
      }
    }
    BEGIN { if (nul) RS="\0" }
    nul { argv[++tokens]=$0; next }
    { sub(/^[[:space:]]+/, ""); emit(split($0, argv, /[[:space:]]+/)) }
    END { if (nul) emit(tokens) }'
}

hand_codex_worktrees() {
  local root="${1:-${ZF_WORKTREE_ROOT:-$HOME/wt}/}" args
  args="$(ps -ww -eo args= 2>/dev/null)" || return 1
  hand_codex_parse_processes <<< "$args" | awk -v root="${root%/}/" 'index($0, root)==1 && !seen[$0]++'
}

hand_codex_pid_matches() {
  local pid="$1" worktree="$2" stat_line rest
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  IFS= read -r stat_line < "/proc/$pid/stat" 2>/dev/null || return 1
  rest="${stat_line##*) }"
  [[ "$rest" != Z\ * ]] || return 1
  # /proc confines identity to this PID; never match ps/grep/brief text from another process.
  hand_codex_parse_processes 0 1 < "/proc/$pid/cmdline" 2>/dev/null | grep -qxF -- "$worktree"
}

hand_codex_worktree_pid() {
  local worktree="$1" pid wt rows
  rows="$(ps -ww -eo pid=,args= 2>/dev/null)" || return 1
  while IFS=$'\t' read -r pid wt; do
    [[ "$wt" == "$worktree" ]] || continue
    hand_codex_pid_matches "$pid" "$worktree" || continue
    printf '%s\n' "$pid"
    return 0
  done < <(hand_codex_parse_processes 1 <<< "$rows")
  return 1
}

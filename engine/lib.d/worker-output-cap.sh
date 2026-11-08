# Per-command output cap for worker backends, in KB (WORKER_OUTPUT_CAP_KB, scheduler config .waste.tool_output_cap_kb, default 64).
# 4741: one `rg` over the whole tree returned 907 KB that stayed in a repair's context for ~107 later calls.
# Each backend truncates natively and prints its own marker that names the cut: Codex "... N tokens truncated ...",
# ZCode "Output too large (N). Full output saved to: ...". Claude Code and ZCode count characters in BASH_MAX_OUTPUT_LENGTH
# (default 30000, max 150000), so the char cap never loosens that default.
worker_output_cap_kb() {
  local kb="${WORKER_OUTPUT_CAP_KB:-64}"
  [[ "$kb" =~ ^[1-9][0-9]{0,5}$ ]] || kb=64
  printf '%s' "$kb"
}
worker_output_cap_tokens() { printf '%s' "$(( $(worker_output_cap_kb) * 1024 / 4 ))"; } # about 4 bytes per token
worker_output_cap_chars() {
  local chars=$(( $(worker_output_cap_kb) * 1024 ))
  (( chars <= 30000 )) || chars=30000
  printf '%s' "$chars"
}

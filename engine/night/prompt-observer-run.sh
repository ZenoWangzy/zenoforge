#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
agent_home="${AGENT_HOME:-${ZF_HOME:-$HOME/.zenoforge}}"
report="${PROMPT_OBSERVER_REPORT:-$agent_home/night/prompt-observer-report.jsonl}"

bash "$script_dir/prompt-observer-report.sh"
bash "$script_dir/prompt-observer-low-score.sh" --report "$report"

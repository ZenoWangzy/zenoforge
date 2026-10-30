#!/usr/bin/env bash
# Shared by worker entries and model runners; never clears operator PAUSE.
pipeline_execution_guard() {
  printf '%s/execution-admission.py\n' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
}

pipeline_execution_admit() {
  python3 "$(pipeline_execution_guard)" check
}

pipeline_execution_run() {
  python3 "$(pipeline_execution_guard)" run -- "$@"
}

# Only shadow systemd-run; GitHub and other command routing stay unchanged.
ZF_EXECUTION_SHIM_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/execution-shim"
export ZF_EXECUTION_SHIM_DIR
export PATH="$ZF_EXECUTION_SHIM_DIR:$PATH"

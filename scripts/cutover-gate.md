# Cutover gate

Create a baseline from the currently live version, then compare the candidate:

```sh
scripts/cutover-gate.sh --baseline "$live_version" --out baseline.tsv --suites suites.txt
scripts/cutover-gate.sh "$candidate/engine" "$checkout" --baseline baseline.tsv --suites suites.txt --results candidate.tsv --allow-undefined scripts/cutover-gate-allow-undefined.tsv
```

The version directory contains `engine/`; the baseline mode copies it before running tests. Supply the same suite command list to both runs. Without `--suites`, the gate discovers shell and Node engine tests in each version. The lists must match. `tools/quarantine.txt` is skipped in both modes. Each results file has one `PASS` or `FAIL` and an engine-relative suite path, separated by a tab. Missing or duplicate baseline entries fail the gate. A test that fails in both runs is tolerated; a baseline pass followed by a candidate failure fails the gate.

The gate also runs host-ops tests from `ZF_HOST_OPS_DIR`, or the host-ops directory under the agent home by default. The runner runs from a copied host-ops directory and receives the candidate engine through `ZF_ENGINE_DIR`. Its `BASELINE.tsv` controls which failing tests block; new failing tests and missing baseline tests block too.

The optional undefined-function allow-list has tab-separated function name, engine-relative caller, and reason. It only suppresses that specific caller and still reports the exception. Other reference and guard-audit failures remain blocking. Environment reads are reported without checking deployment settings.

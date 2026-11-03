# Rules

<a id="v1268"></a>
**V1268** Compile every literal jq regular-expression pattern in engine shell files so data-specific fixtures cannot hide syntax errors.

<a id="v1269"></a>
**V1269** Keep unbounded rows, lists and body text out of jq command-line arguments; stream them through stdin or files.

<a id="v1270"></a>
**V1270** Initialize the refill handoff PR census before every read under `set -u`.

<a id="v1271"></a>
**V1271** Route scheduler GitHub CLI calls through the bounded timeout wrapper.

<a id="v1272"></a>
**V1272** Keep rollback preflight able to admit an explicit, verified engine-pin change.

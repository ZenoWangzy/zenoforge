# Session supervisor

Hooks inject configured context and guard commands and replies. The launcher starts a session with a role; the watchers report operational state. Install links after preparing a JSON configuration and confirming its targets exist:

```
bash engine/supervisor/install.sh --config /path/to/config.json
bash engine/supervisor/install.sh --apply --config /path/to/config.json
```

The default is a dry run. Existing non-link entries are backed up under the home directory. Settings are not edited. Set `ZF_SUPERVISOR_CONFIG` to override the installed configuration link. Paths beginning with `~/` expand against `HOME`.

Configuration keys: `role_env`, `sources` (policy, quota files, role_dir), `state_dir`, `seen_state_template`, `coach` (enabled, role, report_dir, marker_file, stale_days, new and stale messages), `labels`, `claim_path`, `demo_gate`, `demo_gate_env`, `ledger_script`, `ledger_env`, `ledger_label`, `command_patterns`, `push_pattern`, `command_messages`, `readiness_pattern`, `claim_message`, `ruling_trigger`, `ruling_carrier`, `ignored_user_prefixes`, `ruling_message`, `launcher` (cwd, roles, role_dir, prefix), `watch` (paths, filters, units, thresholds, endpoint, scope and issue settings), `rulings_clone`, and `links` (objects with link and target). Regular expressions use JavaScript syntax except the watcher filters and scope glob, which use their respective shell tools' syntax. Message templates use the placeholders shown in the configuration.

Run `bash engine/supervisor/tests/run.sh` for isolated checks. `parity.sh` compares hook exit status and output against an older hook directory, using fixture files named `<name>.hook`, `<name>.stdin`, an optional shell environment file `<name>.env` (or `<name>.vars`), and optional `<name>.home/` directory. `@HOME@` in stdin is replaced with the fixture home path.

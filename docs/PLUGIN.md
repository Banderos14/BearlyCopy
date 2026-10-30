# Prompt Relay as a Claude Code plugin

Prompt Relay connects to Claude Code as an official **Claude Code plugin**
(ADR-008). Claude Code itself installs, enables, disables, updates and
uninstalls it. Prompt Relay never edits your `settings.json`, and it never
touches other tools' hooks, such as NotchBuddy.

Capture stays **off** until you enable a project. Uninstalling the plugin
never deletes your history.

## 1. What is in the repository

```
prompt-relay/                      ← marketplace root
├── .claude-plugin/marketplace.json   lists one plugin, source "./plugin"
├── bin/prompt-relay               ← the CLI you run (enable, show, copy, doctor, …)
└── plugin/                        ← the plugin root (${CLAUDE_PLUGIN_ROOT})
    ├── .claude-plugin/plugin.json    name "prompt-relay", version = package version
    ├── hooks/hooks.json              UserPromptSubmit, Stop, StopFailure → /bin/sh run-hook
    ├── hooks/run-hook                POSIX launcher: finds Python 3.9+, never writes stdout, exits 0
    ├── hooks/prompt_relay_hook.py    imports the handler from this plugin root
    └── prompt_relay/                 the Core (same code the CLI runs)
```

- The Python package is inside the plugin root because Claude Code copies
  only the plugin directory when it installs from a git marketplace.
- The plugin root has no `bin/`: a plugin's `bin/` would be put on Claude's
  Bash `PATH`. The CLI stays in the repository's `bin/`.
- History is stored in `~/Library/Application Support/PromptRelay/`. It is
  not in the plugin root, which changes with every version, and not in
  `${CLAUDE_PLUGIN_DATA}`, which Claude Code deletes on uninstall.

## 1a. Version 0.3.0: observed tool results (ADR-013)
`hooks/hooks.json` adds `PostToolUse` (matcher `Bash|Write|Edit|MultiEdit|NotebookEdit|SendUserFile|Artifact`)
and `PostToolUseFailure` (`Bash|Write|Edit|MultiEdit|NotebookEdit`), both `async: true`, so they never delay
Claude. The handler stores only a reduced record (ids, tool, duration, outcome, Bash command if short and
secret-free, exit code from `Exit code N`, a test/build/git kind, edited paths, what the Artifact tool
returned, and for a failed test or build its last 12 lines after a secret scan). Never stored: file
contents, `old_string`/`new_string`, output of successful commands, artifact HTML. Payload shapes:
HOOKS_RESEARCH §3 (observed 2026-10-30). Updating an installed 0.2.0: `claude plugin marketplace update`
then `claude plugin install prompt-relay@<marketplace>` (or update) on your Mac; check with
`claude plugin details prompt-relay` → "Hooks (5)".

## 2. Install (recommended: from your local checkout)

The commands below run in your shell. Use your Python 3.9+ for the CLI;
`enable` pins it for the hook.

```bash
cd ~/code/prompt-relay && git pull                                   # the branch with the plugin
~/code/prompt-relay/bin/prompt-relay enable ~/code/my-project        # opt in a project; pins this Python
claude plugin marketplace add ~/code/prompt-relay                    # local marketplace
claude plugin install prompt-relay@prompt-relay                      # user scope (default)
```

Then restart Claude Desktop, or run `/reload-plugins` in an open session.

Where the plugin runs from: **observed on the Mac** (Claude Code CLI
2.1.268, 2026-10-29), `claude plugin install` from a local-path marketplace
**copies** `plugin/` into
`~/.claude/plugins/cache/prompt-relay/prompt-relay/<version>/`, and that copy
is `CLAUDE_PLUGIN_ROOT` (`claude plugin list --json` → `installPath`). The
earlier assumption that it loads in place was wrong. So a `git pull` alone
does not change the running hook; after pulling, run
`claude plugin update prompt-relay@prompt-relay` (a copy is refreshed only
when `plugin.json`'s `version` changes) and start a new session. Whether
`update` re-copies an unchanged version is not verified yet (M14).

In Claude Desktop instead of the shell: open the Code tab, click **+** next
to the prompt box, then **Add plugins** (or **Plugins → Browse plugins**),
select **Prompt Relay**, and choose **your user account** as the scope. The
marketplace must have been added first, from the shell or with
`/plugin marketplace add ~/code/prompt-relay` in a CLI session.

**Do not** install with `--scope project`. It writes `enabledPlugins` into the
repository's shared `.claude/settings.json` and turns the plugin on for every
collaborator.

### Alternative: from GitHub
```bash
claude plugin marketplace add Banderos14/prompt-relay#claude/loving-mccarthy-ossw3q
claude plugin install prompt-relay@prompt-relay
```
- The repository is private, so your git credentials must already work
  (`gh auth login` or SSH).
- Claude Code copies the plugin into
  `~/.claude/plugins/cache/prompt-relay/prompt-relay/<version>/`.
- `plugin.json` pins `version`, so users only receive a new copy when the
  version changes (`claude plugin update prompt-relay@prompt-relay`).
- Auto-update is off by default for third-party marketplaces.
- The old version directory is removed by Claude Code 14 days later.
- The hook always uses `${CLAUDE_PLUGIN_ROOT}` of the version that is loaded,
  so updates never break capture or move history.

## 3. Enable capture for projects

```bash
bin/prompt-relay enable ~/code/my-project      # capture on for this project (and its subdirectories)
bin/prompt-relay projects                      # what is on
bin/prompt-relay disable ~/code/my-project     # capture off; existing history is kept
```
With the plugin enabled and no project enabled, nothing is stored. The hook
only logs `project_not_enabled`.

## 4. Check that it works

```bash
bin/prompt-relay doctor                 # human-readable
bin/prompt-relay doctor --json          # JSON API v1, command "doctor"
claude plugin list                      # Claude Code's own view: prompt-relay@prompt-relay, enabled
claude plugin details prompt-relay      # "Hooks (3) UserPromptSubmit, Stop, StopFailure"
```
Then send one prompt in an enabled project, in Desktop or the CLI, and run
`bin/prompt-relay doctor` again. Under **observed**, `plugin: 2` (one
UserPromptSubmit and one Stop) proves the plugin hook actually ran. Then
`bin/prompt-relay show` prints the answer.

## 5. Disable, uninstall, remove

| Goal | Command | History |
|---|---|---|
| Stop capturing one project | `bin/prompt-relay disable <dir>` | kept |
| Turn the plugin off everywhere, keep it installed | `claude plugin disable prompt-relay@prompt-relay` (or Desktop plugin panel) | kept |
| Turn it back on | `claude plugin enable prompt-relay@prompt-relay` | — |
| Uninstall | `claude plugin uninstall prompt-relay@prompt-relay` | kept (Prompt Relay stores nothing in `${CLAUDE_PLUGIN_DATA}`) |
| Remove the marketplace (also uninstalls its plugins) | `claude plugin marketplace remove prompt-relay` | kept |
| Delete history | `bin/prompt-relay delete …` / `prune …` (previews first; see JSON_API.md) | deleted only with `--yes` |

After uninstalling, `~/Library/Application Support/PromptRelay/` still holds
your history, `config.json` and `python-path`. Remove that folder yourself if
you want everything gone.

## 6. Diagnostics: what `doctor` can and cannot tell
| Kind | Source | Examples |
|---|---|---|
| **Configuration** (what files say) | `~/.claude/settings.json`, the project's `.claude/settings.json` and `.claude/settings.local.json`, `~/.claude/plugins/installed_plugins.json` (respects `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_PLUGIN_CACHE_DIR`) | install records, `enabledPlugins` for prompt-relay, Prompt Relay settings hooks, the **number** of other tools' hooks per event |
| **Observed** (what really ran) | `<data dir>/handler.log`, metadata only: time, event, `via=plugin\|direct`, outcome | "plugin: 12 events, last at …", errors such as `unsafe_path` |
| **Unverified** | — | whether a running Desktop session loaded the plugin (check `claude plugin list` or the Desktop panel, then look for `via=plugin` events) |

Privacy:
- `doctor` never prints message text.
- It never prints other tools' hook commands, which can contain tokens; it
  only counts them.
- It never writes any file, and never creates the data directory.

Findings (`warning` / `error`):
- **Python:** `python_unsupported`, `python_not_pinned`, `pinned_python_unusable`.
- **Storage and capture:** `storage_not_writable`, `config_unusable`,
  `no_projects_enabled`, `project_not_enabled`.
- **Registration:** `double_registration`, `settings_registered_twice`,
  `events_from_two_sources`, `not_registered`, `plugin_install_incomplete`.
- **Other:** `settings_unreadable`, `handler_errors_logged`.

## 7. Python for the hook

Claude Desktop starts hooks with a minimal `PATH` and without your shell
environment. `hooks/run-hook` therefore picks the interpreter in this order:

1. The interpreter pinned in `<data dir>/python-path`. `prompt-relay enable`
   writes it once when no valid pin exists, or you set it with
   `prompt-relay pin-python [--python PATH]`. It is used only if the file
   belongs to you.
2. `/opt/homebrew/bin/python3`, `/usr/local/bin/python3`, the python.org
   framework Python.
3. `/usr/bin/python3`, but only when `xcode-select -p` succeeds. Without the
   Command Line Tools it is an install stub that would open a dialog on every
   prompt.

Every candidate, including the pinned one, must pass a Python ≥ 3.9 check.
The handler runs as `python -I -S`, so `PYTHONPATH`, user site-packages and
`sitecustomize` cannot inject code. If nothing usable is found, the hook
prints `prompt-relay: no_python_3_9` to stderr (not shown to Claude) and
exits 0. Claude Code is never blocked.

`prompt-relay pin-python --show` shows the pin and `--clear` removes it.

## 8. Coexistence and double registration

- **Other hooks (NotchBuddy and others).** Claude Code merges hooks from all
  sources and runs matching hooks in parallel. Prompt Relay's hook writes
  nothing to stdout, returns no decision and always exits 0, so it cannot
  change what other hooks do. Prompt Relay does not read, write or rewrite
  other tools' entries.
- **Double registration.** If the plugin is installed and an older
  settings-based hook (from `hook-config`) is also registered, the handler
  runs twice per event. The second run stores nothing: the event's
  fingerprint is already in the session file (`duplicate`). `doctor` reports
  `double_registration` from configuration and `events_from_two_sources`
  from the log. Remove the settings entry by hand; Prompt Relay does not
  edit settings.
- **Two copies of the plugin** (installed and `--plugin-dir`): Claude Code
  itself loads only one copy per plugin name (docs: "Name conflicts").

## 9. Settings-based fallback (not needed so far)

The plugin covers the main scenario. `hook-config` stays for isolated
validation: `claude --settings <file>`, or a sandbox project's
`.claude/settings.local.json`. Situations where a plugin cannot be used:
- an organization's managed settings block third-party marketplaces or
  `--plugin-dir`;
- cloud sessions, which do not load local plugins. Those are not captured by
  design.

Only if such a case becomes real should a settings installer be designed. Its
rules are already fixed in SECURITY §5: merge never replace, back up, be
idempotent, show a dry-run diff, and uninstall only our entries. No
installer is implemented.

# Local macOS validation (Phase 1.5, MacBook Pro M3 Pro)

Purpose: verify on a real Mac everything the cloud could not check: the real
clipboard, real Claude Code hooks (CLI and Claude Desktop local sessions) and
real payload shapes. Nothing here installs global hooks. Every step is
reversible, and §9 proves it.

Record results in the table in §10 and copy it into `docs/STATUS.md`. If a
step fails, paste the command output into the Claude session.

> Safety rules for this checklist
> - Do not edit `~/.claude/settings.json`. Use only `claude --settings <file>`
>   or a sandbox project's `.claude/settings.local.json`.
> - Do not enable capture for real projects. Use the sandbox folders below.
> - M2 and later replace your clipboard content. Save anything you need first.
> - **Validation data never goes to the normal data dir.** Every hook and CLI
>   command below uses `$PR_VAL/data`. Never run `delete --all` against the
>   default data dir (`~/Library/Application Support/PromptRelay`): it would
>   erase real history. Cleanup removes only `$PR_VAL` (§9).

## 0. Variables and data isolation
```bash
export PR_REPO="$HOME/code/prompt-relay"          # where you cloned the repo
export PR_VAL="$HOME/prompt-relay-validation"     # must not exist yet
export PR_SANDBOX_A="$PR_VAL/sandbox-a"
export PR_SANDBOX_B="$PR_VAL/sandbox-b"
export PROMPT_RELAY_HOME="$PR_VAL/data"           # isolated data dir for every CLI command
test ! -e "$PR_VAL" && mkdir -m 700 "$PR_VAL" "$PR_VAL/data" && touch "$PR_VAL/.prompt-relay-validation"
P() { "$PR_PYTHON" "$PR_REPO/bin/prompt-relay" "$@"; }
```
`PR_PYTHON` (chosen in §1) runs every Prompt Relay command. `hook-config`
pins the interpreter that runs it into the hook settings, so hooks never
depend on `PATH`. Claude Desktop starts hooks with a minimal one.

Claude Desktop does **not** pass your shell's `PROMPT_RELAY_HOME` to hooks.
`hook-config --data-dir "$PR_VAL/data"` therefore writes the data dir into
the hook command itself (`/usr/bin/env PROMPT_RELAY_HOME=… python
bin/prompt-relay hook`, exec form, no shell). Use that output for both the CLI
(`--settings`) and Desktop (`settings.local.json`). Verified on the Mac:
Desktop hooks wrote only to `$PR_VAL/data`; the default data dir was never
created.

Before changing any configuration, list the hooks that already exist (other
tools' global hooks run alongside ours; leave them alone):
```bash
"$PR_PYTHON" -c 'import json,os; h=json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("hooks",{}); print({e: len(g) for e,g in h.items()})'
```

## 1. M1 — Environment check (read-only)
```bash
sw_vers; uname -m                         # expect arm64
xcode-select -p                           # fails if the Command Line Tools are missing
command -v -a python3                     # all python3 on PATH (Homebrew, python.org, pyenv, /usr/bin)
git --version
claude --version                          # Claude Code CLI, if installed
ls -la ~/.claude/ 2>/dev/null; shasum -a 256 ~/.claude/settings.json ~/.claude/settings.local.json 2>/dev/null | tee /tmp/pr-claude-settings.before
```
Pick a Python 3.9+. If `xcode-select -p` failed, do **not** run
`/usr/bin/python3`: without the CLT it is a stub that opens an install
dialog. Use Homebrew/python.org Python, or install the CLT first.
```bash
export PR_PYTHON=/usr/bin/python3          # or e.g. /opt/homebrew/bin/python3
"$PR_PYTHON" -c 'import sys; assert sys.version_info >= (3, 9), sys.version; print(sys.executable, sys.version.split()[0])'
```
Record: the macOS version, the chosen Python and its version, the CLI
version, the Claude Desktop version (Claude → About), and the Claude Code
version shown for the Desktop Code tab (D4).

## 2. Get the code and run the automated suite
```bash
git clone https://github.com/Banderos14/prompt-relay.git "$PR_REPO"   # or: git -C "$PR_REPO" fetch
cd "$PR_REPO" && git checkout claude/loving-mccarthy-ossw3q && git log --oneline -3
PYTHONS="$PR_PYTHON" scripts/check.sh
"$PR_PYTHON" bin/prompt-relay doctor
```
Expected: all tests OK, with 0 skipped (as a normal user the permission test
runs too). The latency line is printed. `doctor` shows the Python version,
`xcode CLT installed at …` (or a clear warning), `clipboard pbcopy` and the
data dir `~/Library/Application Support/PromptRelay`.

## 3. M2 — Real clipboard, byte-exact (replaces clipboard content)
```bash
cd "$PR_REPO"
PATH="$(dirname "$PR_PYTHON"):$PATH" scripts/synthetic_demo.sh --real-clipboard
```
Expected: `copied … via pbcopy, verified by read-back`.

Compare the clipboard with the fixture byte by byte, including NUL, CRLF,
emoji and combining characters:
```bash
"$PR_PYTHON" - <<'EOF'
import json, subprocess
want = json.load(open("tests/fixtures/stop_unicode.json"))["last_assistant_message"].encode("utf-8")
env = {"LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"}
got = subprocess.run(["/usr/bin/pbpaste", "-Prefer", "txt"], capture_output=True, env=env).stdout
print("identical:", got == want, "| bytes", len(got), "vs", len(want))
if got != want:
    for i, (a, b) in enumerate(zip(got, want)):
        if a != b: print("first difference at byte", i); break
EOF
```
Also paste (⌘V) into TextEdit (plain text) and into a ChatGPT message box
(do not send). Emoji, Cyrillic and code fences should look right. Record any
difference, especially around NUL (D5).

Large text (~1 MB of Markdown, real clipboard):
```bash
"$PR_PYTHON" - <<'EOF'
import json, os, subprocess, sys, tempfile
sys.path.insert(0, "tests")
from test_scenarios import _markdown_long
text = _markdown_long(8000)
tmp = tempfile.mkdtemp(); proj = os.path.join(tmp, "p"); os.mkdir(proj)
env = dict(os.environ, PROMPT_RELAY_HOME=os.path.join(tmp, "d")); env.pop("PROMPT_RELAY_CLIPBOARD", None)
run = lambda *a, **k: subprocess.run([sys.executable, "bin/prompt-relay", *a], env=env, **k)
run("enable", proj, check=True)
run("hook", input=json.dumps({"hook_event_name": "Stop", "session_id": "big", "cwd": proj, "last_assistant_message": text}).encode(), check=True)
print("size", len(text.encode()), "copy exit", run("copy", "--verify").returncode)
EOF
```

## 4. M3 — Isolated Claude Code CLI session (no settings files touched)
```bash
mkdir "$PR_SANDBOX_A" && cd "$PR_SANDBOX_A" && git init -q
P enable "$PR_SANDBOX_A"                                          # writes $PR_VAL/data/config.json only
P hook-config --data-dir "$PR_VAL/data" > "$PR_VAL/hooks.json" && cat "$PR_VAL/hooks.json"
claude --settings "$PR_VAL/hooks.json"
```
Run `claude` from a normal terminal, not from inside another Claude Code
session (it would inherit that session's `CLAUDE_*` variables). If the CLI
reports "OAuth session expired", log in yourself first (`claude auth login`).
Accept the workspace trust prompt for the sandbox. Inside Claude, run:
1. `Reply with exactly this and nothing else: "Привет, мир! 🚀" followed by a python code block that prints 1.`
2. `List the files in this folder using a tool, then tell me how many there are.` (multi-tool turn, D2)
3. `Run "sleep 30 && echo done" in the background and finish your turn without waiting.` (background tasks, D3)
4. Start a long answer (`Explain TCP in 40 paragraphs`) and press **Esc** before it ends (M6).
5. If your Claude Code has subagents: `Use a subagent to list the files, then summarize.` (D6)

In a second terminal (same `PROMPT_RELAY_HOME`, same `P` function):
```bash
P sessions; P turns
P show                          # latest final text, verbatim
P show --session <id> --turn 1  # compare with what Claude displayed
P copy --verify                 # real clipboard
P context | less                # Copy Context preview
cat "$PROMPT_RELAY_HOME/handler.log"
```
Check and record:
- **D1**: `turns` shows `link=prompt_id`. If it shows `sequence`, the payload
  lacks `prompt_id` on one side. Record which side and the version.
- **D2**: does turn 2's `show` contain only the final text block, or all
  text of the turn?
- **D3**: turn 3 shows `stop_received_background_tasks_pending`. Does a second
  Stop arrive when the task ends? Same `prompt_id`?
- **M6**: the interrupted turn stays `awaiting_response` /
  `no_matched_response`, and no Stop is logged. Without `prompt_id`, the next
  turn becomes `ambiguous`, by design.
- **D6**: does any stored Stop/UserPromptSubmit carry `agent_id`? A main-turn
  Stop must not be a subagent's text.
- No hook error notice appears in Claude, and nothing from Prompt Relay
  shows up in Claude's context.

Save one real payload of each event as **redacted** fixtures:
```bash
"$PR_PYTHON" - <<'EOF'
import json, os, glob
home = os.path.expanduser("~")
for path in glob.glob(os.path.join(os.environ["PR_VAL"], "data/events/*.jsonl")):
    for line in open(path):
        rec = json.loads(line)
        print(json.dumps(rec["payload"], ensure_ascii=False, indent=2).replace(home, "/Users/USER"))
EOF
```
Review the output for private content, then save the payloads as
`tests/fixtures/real_<event>_<n>.json`, replacing the project path with
`__PROJECT_A__`. `SchemaConformanceTests` picks them up automatically.

Optional StopFailure check (M8, one failing API request):
`claude --settings "$PR_VAL/hooks.json" --model does-not-exist -p "hi"`, then
`P turns`. Claude Code may reject the model before any API call, in which
case no StopFailure fires. Record which one happened.

## 5. M4 — Claude Desktop, local Code session
Desktop cannot take `--settings`, so use the sandbox's personal, gitignored
project settings file. Real projects and `~/.claude` stay untouched.
```bash
mkdir "$PR_SANDBOX_A/.claude"
P hook-config --data-dir "$PR_VAL/data" > "$PR_SANDBOX_A/.claude/settings.local.json"
P enable "$PR_SANDBOX_A"         # same isolated data dir as the hook command
```
In Claude Desktop, open Code, set environment **This Computer** (local),
choose **exactly** the folder `$PR_SANDBOX_A` (not its parent `$PR_VAL`: a
session opened there loads no Prompt Relay hooks and captures nothing; this
happened once during the first run), accept trust, and repeat prompts 1–4.
Then run `P turns` and `P copy --verify`.

Record: whether hooks fired (if not, check `$PR_VAL/data/handler.log` and the
Code tab's Claude Code version), whether `prompt_id` is present, and any
difference from the CLI.

## 6. M5 — Two parallel Desktop sessions
Set up `$PR_SANDBOX_B` the same way (`git init`, `.claude/settings.local.json`,
`P enable`). Run sessions in A and B at the same time with different prompts.
```bash
P show --project "$PR_SANDBOX_A"; echo; P show --project "$PR_SANDBOX_B"
```
Each must show only its own answer. `P sessions` lists both.

## 7. M7 — Performance
`PYTHONS="$PR_PYTHON" scripts/check.sh 2>&1 | tail -1` prints the hook
latency line. Target: median < 150 ms on the M3 Pro. Pressing Enter in
Claude shows no noticeable delay.

## 8. Optional CI run on a GitHub macOS runner
Actions → tests → Run workflow, with "Also run on a macOS runner" checked.
This uses macOS runner minutes. It checks portability only; it does not
check the clipboard or Claude.

## 9. M9 — Cleanup and proof that nothing global changed
```bash
# Removes ONLY the validation workspace: the sandboxes, their hook settings,
# the hook JSON and the isolated data dir. The default data dir
# (~/Library/Application Support/PromptRelay) and its history are not touched;
# never run `delete --all` without PROMPT_RELAY_HOME pointing at $PR_VAL/data.
test -f "$PR_VAL/.prompt-relay-validation" && [ "$PR_VAL" != "$HOME" ] && rm -rf "$PR_VAL"
shasum -a 256 ~/.claude/settings.json ~/.claude/settings.local.json 2>/dev/null | diff /tmp/pr-claude-settings.before - && echo "Claude settings unchanged"
git -C "$PR_REPO" status --short          # only intended changes (results, redacted fixtures)
```
The `.prompt-relay-validation` marker guards the `rm -rf`: it runs only on a
directory created by §0.

## 10. Results — run of 2026-10-29 (MacBook Pro M3 Pro)
Also copied into `docs/STATUS.md`. "Not checked" means the step did not run;
nothing below is inferred from mocks.

| ID | Check | Result | Notes (versions, discrepancies) |
|---|---|---|---|
| M1 | Environment | **Passed** | macOS 27.0.1 (26A434), arm64 Apple M3 Pro · `$PR_PYTHON=/usr/bin/python3` → Xcode 3.9.6 (also 3.11.14 Homebrew, 3.14.0 python.org) · CLT installed (Xcode.app) · CLI 2.1.268 · Desktop 4.29.0 · Desktop Code tab bundles Claude Code **2.1.309** (D4) · pbcopy/pbpaste present |
| — | Automated suite on macOS | **Passed** | first run 78/79: `test_s17` hard-coded the Linux data path (test defect, fixed). Now 81 tests (79 + 2 new), OK, 0 skipped, on 3.9.6, 3.11.14 and 3.14.0 |
| M2 | pbcopy byte-exact | **Passed** | 11 cases via `prompt-relay copy --verify`, read back with both `pbpaste` and NSPasteboard (`public.utf8-plain-text`): plain, Cyrillic, emoji/ZWJ/flags/combining, Markdown, nested fences, CRLF, lone CR/tabs/U+2028/BOM, C0 controls/ESC/DEL, **NUL** (D5: preserved), shell-like text, 1 176 694-byte Markdown. All identical |
| M2b | Manual ⌘V paste into another app | **Not checked** | the clipboard was overwritten before the paste |
| M3 | CLI hooks via `--settings` | **Partial** | UserPromptSubmit fired and was stored (`prompt_id` present, no `agent_id`). The API call failed: "OAuth session expired" (CLI not logged in). **No StopFailure fired** for that authentication failure. CLI Stop, D2, D3, D6 not checked |
| M4 | Desktop local session hooks | **Passed (one turn)** | sandbox `settings.local.json` with `--data-dir`. UserPromptSubmit + Stop stored; Stop has the same `prompt_id` (D1 confirmed) → `link=prompt_id`, `stop_received`; `last_assistant_message` equals Claude's final text in the transcript byte for byte; `background_tasks: []`, `session_crons: []`, no `agent_id`; `permission_mode: auto`, `effort`, `scratchpad_dir` present. `copy --verify` passed. A first Desktop session opened in the parent folder captured nothing (expected) |
| M5 | Parallel sessions separated | **Not checked** | |
| M6 | Interrupt (Esc) → no Stop | **Not checked** | the Esc attempt ran in the parent folder, so no events exist |
| D2 | Multi-tool final text | **Not checked** | |
| D3 | Background task wake-up | **Not checked** | |
| M7 | Hook latency | **Passed** | median 37.1 ms, p95 39.3 ms (target < 150 ms) |
| M8 | StopFailure | **Not checked** | see M3: an auth failure did not fire it |
| M9 | `~/.claude` unchanged | **Passed** | `~/.claude/settings.json` SHA-256 unchanged; existing global hooks (another tool) untouched. The validation workspace `$PR_VAL` is **kept** for the remaining checks; the default data dir was never created |

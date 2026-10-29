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

## 0. Variables used below
```bash
export PR_REPO="$HOME/code/prompt-relay"          # where you cloned the repo
export PR_SANDBOX_A="$HOME/prompt-relay-sandbox-a"
export PR_SANDBOX_B="$HOME/prompt-relay-sandbox-b"
```
`PR_PYTHON` (chosen in §1) runs every Prompt Relay command. `hook-config`
pins the interpreter that runs it into the hook settings, so hooks never
depend on `PATH`. Claude Desktop starts hooks with a minimal one.

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
mkdir -p "$PR_SANDBOX_A" && cd "$PR_SANDBOX_A" && git init -q
export PROMPT_RELAY_HOME="$HOME/prompt-relay-validation-data"   # keeps validation data separate
P() { "$PR_PYTHON" "$PR_REPO/bin/prompt-relay" "$@"; }
P enable "$PR_SANDBOX_A"
P hook-config > /tmp/pr-hooks.json && cat /tmp/pr-hooks.json     # "command" must be $PR_PYTHON
claude --settings /tmp/pr-hooks.json
```
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
for path in glob.glob(os.path.expanduser("~/prompt-relay-validation-data/events/*.jsonl")):
    for line in open(path):
        rec = json.loads(line)
        print(json.dumps(rec["payload"], ensure_ascii=False, indent=2).replace(home, "/Users/USER"))
EOF
```
Review the output for private content, then save the payloads as
`tests/fixtures/real_<event>_<n>.json`, replacing the project path with
`__PROJECT_A__`. `SchemaConformanceTests` picks them up automatically.

Optional StopFailure check (M8, one failing API request):
`claude --settings /tmp/pr-hooks.json --model does-not-exist -p "hi"`, then
`P turns`. Claude Code may reject the model before any API call, in which
case no StopFailure fires. Record which one happened.

## 5. M4 — Claude Desktop, local Code session
Desktop cannot take `--settings`, so use the sandbox's personal, gitignored
project settings file. Real projects and `~/.claude` stay untouched.
```bash
mkdir -p "$PR_SANDBOX_A/.claude"
unset PROMPT_RELAY_HOME          # Desktop does not inherit your shell env; it uses the default data dir
P hook-config > "$PR_SANDBOX_A/.claude/settings.local.json"
P enable "$PR_SANDBOX_A"         # writes ~/Library/Application Support/PromptRelay/config.json
```
In Claude Desktop, open Code, set environment **This Computer** (local),
choose folder `$PR_SANDBOX_A`, accept trust, and repeat prompts 1–4. Then run
`P turns` and `P copy --verify`.

Record: whether hooks fired (if not, check
`~/Library/Application Support/PromptRelay/handler.log` and the Code tab's
Claude Code version), whether `prompt_id` is present, and any difference from
the CLI.

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
rm -f "$PR_SANDBOX_A/.claude/settings.local.json" "$PR_SANDBOX_B/.claude/settings.local.json" /tmp/pr-hooks.json
P disable "$PR_SANDBOX_A"; P disable "$PR_SANDBOX_B"
P delete --all --yes                                                  # default data dir
PROMPT_RELAY_HOME="$HOME/prompt-relay-validation-data" P delete --all --yes
rm -rf "$HOME/prompt-relay-validation-data"
shasum -a 256 ~/.claude/settings.json ~/.claude/settings.local.json 2>/dev/null | diff /tmp/pr-claude-settings.before - && echo "Claude settings unchanged"
git -C "$PR_REPO" status --short          # only intended changes (results, redacted fixtures)
```
Optionally remove the sandbox folders and
`~/Library/Application Support/PromptRelay`.

## 10. Results (copy into docs/STATUS.md)
| ID | Check | Result | Notes (versions, discrepancies) |
|---|---|---|---|
| M1 | Environment | | macOS ·, Python (path, version) ·, CLT ·, CLI ·, Desktop ·, Desktop Code version · |
| — | Automated suite on macOS | | passed / failed / skipped |
| M2 | pbcopy byte-exact (Unicode, CRLF, NUL, ~1 MB) | | D5 |
| M3 | CLI hooks via --settings | | D1 prompt_id, D2 multi-tool text, D3 background, D6 agent_id |
| M4 | Desktop local session hooks | | D4 |
| M5 | Parallel sessions separated | | |
| M6 | Interrupt → no Stop, turn not marked done | | |
| M7 | Hook latency | | median / p95 |
| M8 | StopFailure (optional) | | |
| M9 | Cleanup; ~/.claude unchanged | | |

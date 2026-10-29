# Local macOS validation (MacBook Pro M3 Pro)

Purpose: verify on a real Mac everything the cloud could not check, namely
the real clipboard, real Claude Code hooks (CLI and Claude Desktop local
sessions) and real payload shapes. Nothing here installs global hooks. Every
step is reversible, and §9 proves it.

Fill in the results table (§10) as you go and commit it in
`docs/STATUS.md`. Paste command output into the Claude session if something
fails.

> Safety rules for this checklist
> - Do not edit `~/.claude/settings.json`. Use only `claude --settings <file>`
>   or a sandbox project's `.claude/settings.local.json`.
> - Do not enable capture for real projects during validation. Use the
>   sandbox folders below.
> - Steps M2 and later replace your clipboard content. Save anything you need
>   first.

## 0. Variables used below
```bash
export PR_REPO="$HOME/code/prompt-relay"          # where you cloned the repo
export PR_SANDBOX_A="$HOME/prompt-relay-sandbox-a"
export PR_SANDBOX_B="$HOME/prompt-relay-sandbox-b"
```

## 1. M1 — Environment check (read-only)
```bash
sw_vers; uname -m                         # expect arm64
xcode-select -p                           # CLT installed? (needed for /usr/bin/python3)
/usr/bin/python3 --version                # expect 3.9+
git --version
claude --version                          # Claude Code CLI, if installed
ls -la ~/.claude/ 2>/dev/null; shasum -a 256 ~/.claude/settings.json ~/.claude/settings.local.json 2>/dev/null | tee /tmp/pr-claude-settings.before
```
Record: macOS version, Python version, CLI version, and the Claude Desktop
version (Claude → About). In Desktop, also note the Claude Code version shown
for the Code tab (HOOKS_RESEARCH D4).

## 2. Get the code and run the automated suite
```bash
git clone https://github.com/Banderos14/prompt-relay.git "$PR_REPO"   # or: git -C "$PR_REPO" fetch
cd "$PR_REPO" && git checkout claude/loving-mccarthy-ossw3q
PYTHONS=/usr/bin/python3 scripts/check.sh
bin/prompt-relay doctor
```
Expected: all tests OK. On macOS, as a normal user, `test_s11b` also runs
(nothing is skipped). `doctor` shows `clipboard pbcopy` and the data dir
`~/Library/Application Support/PromptRelay`.

## 3. M2 — Real clipboard, byte-exact (replaces clipboard content)
```bash
cd "$PR_REPO"
scripts/synthetic_demo.sh --real-clipboard        # isolated temp data dir; copies via pbcopy with --verify
```
Expected: `copied … via pbcopy, verified by read-back`.

Then compare the clipboard with the fixture byte by byte, including NUL,
CRLF, emoji and combining characters:
```bash
/usr/bin/python3 - <<'EOF'
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
Also paste (⌘V) into TextEdit (plain text mode) and into a ChatGPT message
box (do not send it). Emoji, Cyrillic and the code fences should look right.
Record any difference, especially around the NUL character (D5).

Large text: run `python3 -m unittest tests.test_scenarios -k s08`. Then repeat
the comparison with a ~500 KB response: feed
`tests/fixtures/stop_markdown.json` with a long `last_assistant_message`, or
use the Claude test in M3.

## 4. M3 — Isolated Claude Code CLI session (no settings files touched)
```bash
mkdir -p "$PR_SANDBOX_A" && cd "$PR_SANDBOX_A" && git init -q
export PROMPT_RELAY_HOME="$HOME/prompt-relay-validation-data"   # keeps validation data separate
"$PR_REPO/bin/prompt-relay" enable "$PR_SANDBOX_A"
"$PR_REPO/bin/prompt-relay" hook-config --command "$PR_REPO/bin/prompt-relay" --python /usr/bin/python3 > /tmp/pr-hooks.json
cat /tmp/pr-hooks.json
claude --settings /tmp/pr-hooks.json
```
Accept the workspace trust prompt for the sandbox. Inside Claude, run these
three prompts:
1. `Reply with exactly this and nothing else: "Привет, мир! 🚀" followed by a python code block that prints 1.`
2. `List the files in this folder using a tool, then tell me how many there are.` (a multi-tool turn, D2)
3. `Run "sleep 30 && echo done" in the background and finish your turn without waiting.` (background tasks, D3)

In a second terminal (same `PROMPT_RELAY_HOME`):
```bash
P="$PR_REPO/bin/prompt-relay"
$P sessions; $P turns
$P show                         # turn 3 or 2 text, verbatim
$P show --turn 1 --session <id> # compare with what Claude displayed
$P copy --verify                # real clipboard
$P context | less               # Copy Context preview
cat "$PROMPT_RELAY_HOME/handler.log"
```
Check and record:
- `turns` shows `link=prompt_id` for every turn (D1). If it shows `sequence`,
  the Stop payload lacks `prompt_id`. Record the version.
- Turn 2: does `show` contain only the final text block or all text of the
  turn (D2)?
- Turn 3: status `stop_received_background_tasks_pending`, and whether a
  second Stop arrives when the background task finishes (D3).
- Press **Esc** during a long answer (M6): that turn must stay
  `awaiting_response`/`no_matched_response`, with no Stop.
- Claude's own output never shows anything from Prompt Relay, and there is
  no hook error notice.

Save one real payload of each event as redacted fixtures:
```bash
/usr/bin/python3 - <<'EOF'
import json, os, glob
home = os.path.expanduser("~")
for path in glob.glob(os.path.expanduser("~/prompt-relay-validation-data/events/*.jsonl")):
    for line in open(path):
        rec = json.loads(line)
        print(json.dumps(rec["payload"], ensure_ascii=False, indent=2).replace(home, "/Users/USER"))
EOF
```
Review the output for private content before committing any of it to
`tests/fixtures/real_*.json`.

Optional StopFailure check (M8, makes one failing API request):
`claude --settings /tmp/pr-hooks.json --model does-not-exist -p "hi"`, then
`$P turns` should show `api_error`.

## 5. M4 — Claude Desktop, local Code session
Desktop cannot take `--settings`, so use the sandbox's personal, gitignored
project settings file. Your real projects and `~/.claude` stay untouched.
```bash
mkdir -p "$PR_SANDBOX_A/.claude"
"$PR_REPO/bin/prompt-relay" hook-config --command "$PR_REPO/bin/prompt-relay" --python /usr/bin/python3 \
  > "$PR_SANDBOX_A/.claude/settings.local.json"
unset PROMPT_RELAY_HOME          # Desktop does not inherit your shell env; it uses the default data dir
"$PR_REPO/bin/prompt-relay" enable "$PR_SANDBOX_A"   # writes ~/Library/Application Support/PromptRelay/config.json
```
In Claude Desktop, open the Code tab, choose environment **This Computer**
(local) and folder `$PR_SANDBOX_A`, accept trust, and repeat prompts 1–3 from
M3. Then run `"$PR_REPO/bin/prompt-relay" turns` and `… copy --verify`.

Record: whether hooks fired at all (if not, check `handler.log` and the Code
tab's Claude Code version); `prompt_id` presence; any difference from the CLI.

## 6. M5 — Two parallel Desktop sessions
Create `$PR_SANDBOX_B` the same way (git init, `.claude/settings.local.json`,
`enable`). Run sessions in A and B at the same time with different prompts.
```bash
P="$PR_REPO/bin/prompt-relay"
$P show --project "$PR_SANDBOX_A"; echo; $P show --project "$PR_SANDBOX_B"
```
Each must show only its own answer. `$P sessions` lists two sessions.

## 7. M7 — Performance
```bash
cd "$PR_REPO" && PYTHONS=/usr/bin/python3 scripts/check.sh 2>&1 | tail -1   # hook latency line
```
Target: median < 150 ms on the M3 Pro. There should be no noticeable delay
after pressing Enter in Claude.

## 8. M8 — Optional CI run on GitHub macOS runner
Actions → tests → Run workflow, with "Also run on a macOS runner" checked.
This uses macOS runner minutes. It checks code portability only, not the
clipboard or Claude.

## 9. M9 — Cleanup and proof that nothing global changed
```bash
rm -f "$PR_SANDBOX_A/.claude/settings.local.json" "$PR_SANDBOX_B/.claude/settings.local.json" /tmp/pr-hooks.json
"$PR_REPO/bin/prompt-relay" disable "$PR_SANDBOX_A"; "$PR_REPO/bin/prompt-relay" disable "$PR_SANDBOX_B"
"$PR_REPO/bin/prompt-relay" delete --all --yes                                 # default data dir
PROMPT_RELAY_HOME="$HOME/prompt-relay-validation-data" "$PR_REPO/bin/prompt-relay" delete --all --yes
rm -rf "$HOME/prompt-relay-validation-data"
shasum -a 256 ~/.claude/settings.json ~/.claude/settings.local.json 2>/dev/null | diff /tmp/pr-claude-settings.before - && echo "Claude settings unchanged"
git -C "$PR_REPO" status --short          # must show no captured data
```
Optionally remove the sandbox folders and
`~/Library/Application Support/PromptRelay`.

## 10. Results (copy into docs/STATUS.md)
| ID | Check | Result | Notes (versions, discrepancies) |
|---|---|---|---|
| M1 | Environment | | macOS ·, Python ·, Claude Code CLI ·, Desktop ·, Desktop Code version · |
| — | Automated suite on macOS | | passed / failed / skipped counts |
| M2 | pbcopy byte-exact (Unicode, CRLF, NUL, large) | | D5 |
| M3 | CLI hooks via --settings | | D1 prompt_id, D2 multi-tool text, D3 background |
| M4 | Desktop local session hooks | | D4 |
| M5 | Parallel sessions separated | | |
| M6 | Interrupt → no Stop, turn not marked done | | |
| M7 | Hook latency | | median / p95 |
| M8 | StopFailure (optional) | | |
| M9 | Cleanup; ~/.claude unchanged | | |

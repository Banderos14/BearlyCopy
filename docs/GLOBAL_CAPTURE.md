# Global Capture (0.8.0)

## Why an answer was missed (2026-11-09)

Claude Desktop Code worked in the Tête-à-Tête Theatre repository. That
folder was never switched on in Prompt Relay, so the hook rejected every
event of that task — `handler.log` (metadata only) shows `PostToolUse …
project_not_enabled` and, at 13:32:25 UTC, `Stop … project_not_enabled`.
Nothing was written: the answer is **not** in Prompt Relay's history and
cannot be recovered from it. Claude Code's own transcripts are never read by
Prompt Relay (product invariant 1). To keep that answer, copy it in Claude
and use **Import AI Result…** (menu-bar bear).

## Modes

| Mode | What the hook stores | Set with |
|---|---|---|
| **All projects** (`global`) | every project Claude Code (plugin ≥ 0.8.0) or a connected Codex works in, except exclusions and protected locations | Projects / Settings → **Capture All Projects**, or `prompt-relay capture --global` |
| **Selected projects** (`selected`) | only projects switched on in Projects (before 0.8.0 the only mode; still the default) | `prompt-relay capture --selected` |
| **Paused** | nothing new | menu-bar bear → **Pause Capture**, or `prompt-relay capture --pause` / `--resume` |

* **Exclusions win** over every mode. In All projects, a project's Capture
  switch off = excluded (`capture --exclude DIR`, `--include DIR`).
* **Protected locations** are never captured automatically: `/`, the home
  folder itself, system folders, `~/Library` and credential folders
  (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, …).
* **Fails closed:** a missing/relative `cwd` (`no_project_dir`), an
  unreadable, invalid or unknown config (`config_*`) — nothing is stored.
* **Projects appear automatically** from the stored sessions, grouped by
  Prompt Relay's existing Project Intelligence (`projects.py`): Git root
  (a subfolder joins its repository), nested repositories and linked
  worktrees stay separate, same-named folders in different places stay
  separate, symlinked paths resolve to one project. Raw folders are never
  rewritten; nothing is created in your repositories.
* The choice is the user's: an existing installation stays **Selected**
  until the user presses **Capture All Projects** (a one-time offer in
  Projects, Settings and the Inbox).

## Compatibility

`config.json` stays schema 1 while the policy is the old default. Choosing
a mode or an exclusion writes **schema 2**, which hooks before 0.8.0 refuse:
an old plugin then stores **nothing** (it can never ignore a pause or an
exclusion). The app says "Plugin update required" instead of claiming
capture; `prompt-relay doctor` reports `plugin_too_old_for_capture_mode`.
Back to Selected with no exclusions → schema 1 again, old plugins work.

Codex hooks run `plugin/hooks/run-hook` from the checkout they were
configured with; they follow the same policy as soon as that checkout has
0.8.0. Other AI apps (Cursor, Gemini, ChatGPT…) are not captured: there is
no adapter.

## Owner setup (after approval)

1. Install the app (0.9.0 since Phase 17): `~/Projects/prompt-relay-phase16/scripts/install-local.sh --no-build`
2. Point Claude Code's plugin marketplace at the Phase 16 worktree and
   install the plugin from it (0.9.0; 0.8.0 is the minimum for capture
   modes — today the marketplace reads `~/Projects/prompt-relay`, which
   holds 0.6.0, so `plugin update` alone would not bring it):
   ```bash
   claude plugin marketplace remove prompt-relay
   claude plugin marketplace add ~/Projects/prompt-relay-phase16
   claude plugin install prompt-relay@prompt-relay
   claude plugin list | grep -A2 prompt-relay
   ```
   History and `config.json` are not touched. Open conversations keep the
   old hook until a **new** Claude Code session (Desktop: new conversation
   or restart Claude) starts.
3. In Prompt Relay → Settings → Daily Use → **Set Up…** (or Projects →
   **Capture All Projects**). Since Phase 17 the switch is refused, with
   the reason, while the installed plugin is older than 0.8.0 — before, it
   was made and the old plugin then stored nothing.
4. Verify for real: in a new Claude session in any not-yet-known
   repository, ask something short; the answer appears in the Inbox under
   that project. `handler.log` shows `Stop via=plugin … stored`.

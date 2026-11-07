# Phase 15 — Git recovery, backup and branch layout

Recorded 2026-11-07 on the owner's Mac. Every SHA below was read with
`git rev-parse` / `git ls-remote`, not copied from earlier reports.

## 1. State found (before any change)

| Item | Value |
|---|---|
| Repository | `~/Projects/prompt-relay`, remote `origin` = `https://github.com/Banderos14/prompt-relay.git` (**private**) |
| Checked-out branch | `claude/loving-mccarthy-ossw3q` |
| Local HEAD | `17844feb4a5b76a2a9d0257f6c2bc32564481639` (Phase 14.2), 101 commits |
| `origin/claude/loving-mccarthy-ossw3q` | `f72a8ce087c5d4a722929566dc0a50a63979971f` (2026-10-30, Phase 4 polish) — **76 commits behind local**, an ancestor of HEAD |
| `main` / `origin/main` | `775c5c9e065051337db35885ad73906770bcfb8f` ("Initial commit"), ancestor of HEAD |
| `develop` | did not exist (local or remote) |
| Backup refs | 21 local `refs/backup/*` (phase4-start … phase9.4c-start, ui-polish-1/2); local only |
| Staged (owner's) | `macos/acceptance/phase9.1/xcode-smoke/REPORT.md` (new file, 16 lines) |
| Unstaged tracked changes | none |
| Untracked | 344 files under `macos/acceptance/` (screens, logs, patches, owner observations), 26 MB |
| Stash | empty |
| Ignored, relevant | `macos/build/`, `dist/`, `.build/` (build output) |

Conclusion: the genuine latest source is local `17844fe`; GitHub had only the
Phase 4-era branch tip. The old remote branch is outdated but fully contained
in local history.

## 2. Private backup (outside the repository)

Directory: `/Users/admin/Backups/PromptRelay/2026-11-07-phase15/` (mode 700,
files 600). Created 2026-11-07 21:28 CET.

| File | SHA-256 | Content |
|---|---|---|
| `prompt-relay-all-refs.bundle` | `872dc568e793005e858d0a2a25dac95c455810aeb8e25cde7d94e4466e220769` | `git bundle --all`: 27 refs (all branches, remotes, 21 backup refs, HEAD) |
| `staged-index.patch` | `1642d32a078f36de52da944e24e5014c6c76187fc598b8850e238559e152ece6` | `git diff --cached --binary` (the owner's staged REPORT.md) |
| `untracked-files.tar.gz` | `30f1aad41836ac28768ecf286f4f36b70cce137095b3c6ce6c0473213082bc59` | the 344 untracked acceptance files |
| `untracked-files.list` | `ae819be50ad76fcfbfcaa0a9c6bf9d8882a3dde82b7b5f7409af48ee7f8dcb81` | their paths |
| `git-status.txt`, `refs.txt` | see `SHA256SUMS` | snapshot of status and refs |

Verification: `git bundle verify` → "The bundle records a complete history";
`git clone --mirror` of the bundle → `claude/loving-mccarthy-ossw3q` =
`17844fe`, 101 commits, `git fsck` clean; tarball lists 344 entries.

**Not in the backup (by design):** captured Claude history
(`~/Library/Application Support/PromptRelay`), app settings (UserDefaults),
clipboard, in-memory screenshots, the installed app. Copying captured history
is a privacy decision for the owner; Phase 15 did not copy it.

### Restore
```bash
git clone ~/Backups/PromptRelay/2026-11-07-phase15/prompt-relay-all-refs.bundle prompt-relay-restored
cd prompt-relay-restored && git fetch origin 'refs/backup/*:refs/backup/*'   # origin = the bundle here
git apply --index ~/Backups/PromptRelay/2026-11-07-phase15/staged-index.patch
tar -xzf ~/Backups/PromptRelay/2026-11-07-phase15/untracked-files.tar.gz
```
Check: `shasum -a 256 -c SHA256SUMS` inside the backup folder.

## 3. Branches created

| Branch | Points to | Where |
|---|---|---|
| `develop` | `17844fe` (Phase 14.2, unchanged) | local + **pushed** to `origin/develop` (verified equal) |
| `phase/15-mvp-readiness` | `develop` + Phase 15 commits | worktree `~/Projects/prompt-relay-phase15`; pushed only if the owner asks (see §5) |
| `main` | `775c5c9` | **untouched** |
| `claude/loving-mccarthy-ossw3q` | `17844fe` locally, `f72a8ce` on GitHub | untouched; still checked out in `~/Projects/prompt-relay` with the owner's staged file and untracked acceptance material exactly as found |

Why a worktree: the main checkout holds the owner's staged REPORT.md and 344
untracked files. A separate worktree keeps Phase 15 commits from ever picking
them up, and leaves that checkout byte-for-byte as it was.

Push safety check before pushing `develop`: no `.jsonl`/`.db`/`.log` tracked;
secret patterns over the 76 new commits matched only a synthetic test string
(`sk-ant-api03-` + 40 × "x"); personal data = author email (already on
GitHub) and the repo path in two docs lines; PNGs are synthetic renders.

## 4. Deleting the legacy branch (needs the owner's explicit yes)
Everything on `claude/loving-mccarthy-ossw3q` is reachable from `develop`
(same commit locally; the remote tip `f72a8ce` is an ancestor) and from the
bundle. When the owner approves:
```bash
git push origin --delete claude/loving-mccarthy-ossw3q   # remote copy
git branch -d claude/loving-mccarthy-ossw3q               # local, after switching that checkout to develop
```
Do not run these before the owner says so. The local checkout has staged and
untracked owner files: switch it with `git switch develop` (same commit, keeps
them) rather than any reset.

## 5. Integrating Phase 15 into `develop` (owner)
```bash
cd ~/Projects/prompt-relay-phase15
git push -u origin phase/15-mvp-readiness       # if not pushed yet
git switch develop && git merge --ff-only phase/15-mvp-readiness && git push origin develop
```
Or open a PR `phase/15-mvp-readiness → develop` on GitHub. `main` stays as is
until a release decision.

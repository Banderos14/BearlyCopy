# Phase 9 — shared sources and result attachments

Implemented locally on 2026-11-03. Live Codex capture in Xcode is **not accepted yet**.
This document distinguishes a supported protocol, an isolated test, and a real client session.
No integration was enabled globally, no credentials were copied, and no AI task was launched for diagnostics.

## Compatibility evidence

“Documented” means the client supports the interface; it does not mean a real session was captured in this acceptance run.
Files means observed tool paths, not all filesystem changes caused by arbitrary commands.

| Agent | Environment | Automatic prompt | Full answer | Commands | Files | Status / fallback |
|---|---|---|---|---|---|---|
| Claude Code | Desktop, local Code session | Documented hooks | Stop message when supplied | PostToolUse / PostToolUseFailure | Edit/Write/SendUserFile | Existing adapter retained; client-specific live retest pending. Import for cloud/remote results. |
| Claude Code | CLI | Documented hooks | Stop message when supplied | Existing reducer | Existing reducer | Existing pipeline regression tested; no new live model run. |
| Claude Code | VS Code | Documented hooks in extension | Stop message when supplied | Documented hooks | Documented tools | Client-specific live retest pending; Import if hooks are unavailable. CLI success is not VS Code evidence. |
| Codex | Xcode | Unverified in this host | Unverified in this host | Unverified in this host | Unverified; Xcode logical paths are not filesystem evidence | Installed runtime supports hooks/list; Xcode trust/config delivery and real turn remain unverified. Use Import AI Result. |
| Codex | CLI | Public UserPromptSubmit | Public Stop.last_assistant_message, optional | Public PostToolUse, including failed calls | Successful apply_patch output paths | Implemented and isolated pipeline tested; live trusted CLI smoke pending. No CLI executable on PATH here; Xcode's bundled executable was probed without inference. |
| Codex | VS Code | Not independently verified | Not independently verified | Not independently verified | Not independently verified | No claim based on CLI or Xcode; Import AI Result until host-specific smoke passes. |

Official references consulted:

- [Codex hooks](https://learn.chatgpt.com/docs/hooks): hooks.json next to active config layers, exact hook trust, event schemas, canonical Bash/apply_patch names, shared parent session IDs for subagents. PostToolUse covers failures; it is not Claude's PostToolUseFailure.
- [Codex App Server](https://learn.chatgpt.com/docs/app-server): thread/turn/item events for connected clients, thread start/resume/read, hooks/list. These APIs are not a global subscription to unrelated running clients.
- [Codex plugin hooks](https://developers.openai.com/plugins/build/plugins): supported packaging; no existing Claude plugin configuration was replaced.
- [Apple: extending and customizing agents](https://developer.apple.com/documentation/Xcode/extending-and-customizing-agents): Xcode-specific Codex configuration is in `~/Library/Developer/Xcode/CodingAssistant/codex`, separate from normal CLI configuration.
- [Apple: external agents and MCP](https://developer.apple.com/documentation/Xcode/giving-external-agents-access-to-xcode): MCP exposes Xcode tools; it is not documented as a passive chat transcript notification service. XcodeKit source editor extensions likewise do not supply that service.
- [Claude hooks](https://code.claude.com/docs/en/hooks), [Desktop](https://code.claude.com/docs/en/desktop), [VS Code](https://code.claude.com/docs/en/vs-code): local Desktop shares hook settings with CLI; VS Code documents hook configuration separately. Cloud sessions do not become local capture.

Experiment: the installed Xcode Codex binary reports version 0.153.1. An isolated App Server initialized, answered hooks/list, and returned zero loaded threads. It did not see this running Xcode conversation. No thread was started/resumed, no transcript/private database read, no OAuth data copied, no UI scraping, and no hook-trust bypass used. This establishes protocol availability, **not** that Xcode runs our hooks. Reproduce with `python3 Integrations/check-codex-runtime.py /absolute/path/to/codex`.

## Implementation and adapter contract

`plugin/prompt_relay/adapters.py` is the normalization boundary. A launcher declares `PROMPT_RELAY_PROVIDER`; prose never selects an agent. Registry adapters return a canonical event or reject unsupported input. The existing hook handler retains opt-in project checks, bounded stdin, silent stdout, exit-zero behavior, deduplication, append-only event storage and metadata-only diagnostics. Neither adapter launches processes or reads project files in a hook.

Claude's adapter retains existing event semantics and stable session keys. Legacy records decode without migration/rewrite and show Claude Code / Unknown host. A client-specific launcher may explicitly declare `PROMPT_RELAY_HOST`; this is configured provenance, not automatic process detection. No generic shell variable is treated as proof of Desktop/VS Code.

Codex's adapter validates native session and turn IDs, namespaces session identity using provider + native ID + host + installation identity + canonical workspace, preserves prompt/final response verbatim, and maps native turn IDs onto the existing correlation mechanism. The installation path is hashed in metadata. Codex subagent events are rejected because their session_id belongs to the parent; they must never overwrite its answer. Unmatched turns stay unmatched, repeated normalized events remain idempotent. Changing the configured installation/host intentionally creates a distinct identity. Codex ignores CLAUDE_PROJECT_DIR.

Tool normalization records only allowlisted metadata. Bash exit codes come from explicit structured output or the recognized model-facing exit line; otherwise they remain unknown. Failed build/test tails are bounded and secret-scanned. Successful apply_patch result paths become observed changes; patch inputs alone are not evidence. Unrecognized tools, logical Xcode paths, hosted tools and unknown response formats do not acquire fictional evidence. A failed Edit/Write is not a confirmed changed file.

Optional `source` and `native_turn_id` fields extend API v1. `AgentSource` separates provider, host, native identity, capabilities and capture transport. Missing/unknown capabilities confer no powers. The hooks adapter currently declares prompt/final_response/tools/file_changes/workspace_metadata, not continuous live status or complete session lifecycle. A supported final response capability does not guarantee a particular Stop contained text.

Manual Import retains the existing ReportStore / ReportRef path and explicitly selected assistant, host, task and project. It stays Imported, never locally observed Codex. Equal text from different assistants/hosts/projects or explicitly different import sessions does not collapse into one record. No tool evidence is inferred from pasted prose.

All downstream history, clipboard, evidence, attachment snapshots, context rendering and persistent handoff remain shared. Provider filters appear in History and Project & Session. An incoming result from another provider does not steal the current selection; an opened/pinned session remains selected. Workspaces keep their recorded canonical paths; no new repository-wide Git-common-directory merging is introduced.

To add a future provider: add a registry adapter, normalized source display identifiers, capability declarations and contract fixtures. Reuse the event store/API, ReportRef, ReviewPack, ReportStore and AppModel. Do not create provider-specific history, clipboard, attachment or handoff UI. Unsupported capabilities stay absent. Gemini/Antigravity/OpenCode integrations are not implemented.

## Result attachments

With Auto-select result attachments enabled (default), loading a completed result and building Copy with Context both call the same preparation path. Quick Peek therefore does not require visiting Details first.

Only observed result paths that are explicitly shown or named in the final answer qualify. A document or image mentioned without observed origin remains a suggested candidate for the user's approval. Successful shell execution alone does not prove which files it created. In particular, a PNG generated by a shell command may need manual approval even when the answer names it. Arbitrary source edits stay in Changed Files.

The allowlist is Markdown/text, PDF, common raster images and CSV. Files must be inside the canonical project, regular, nonempty and locally readable. Each path component is opened without following symlinks; hidden/credential/secret/password/private/token/keychain paths are excluded. Recognized text secrets are rejected. Limits: 50 MiB per read, 100 MiB combined preparation, and existing 1 MiB document validation. Image/PDF content must pass existing type validation. This is conservative screening, not a guarantee that arbitrary document contents contain no sensitive information. No directories are scanned and no artifact URL is downloaded.

Snapshots preserve file identity, provider, report reference and discovery provenance. A persistent per-report discovery ledger preserves deselection/removal across rediscovery and restart; a corrupt ledger fails closed. Duplicate path discoveries do not add copies. Different observed files with identical bytes can remain distinct. Changing/deleting the original does not rewrite a snapshot.

Details and Quick Peek share ReportStore selection. Uncheck any unwanted file; removing an attachment leaves its original intact. Add local files using Attachments, or select images from the existing global five-image Clipboard history. Both providers use that same clipboard history.

Copy with Context freezes full text and manifest, then offers Copy N Files / Drag N. The existing persistent handoff survives pointer exit, island close, session switches and restart; Done completes it. Copy Text Again restores the original text snapshot. Preview selection changes invalidate copying until the preview is refreshed (or the same selection restored); Copy never silently rebuilds a different preview. The app never claims the receiving AI accepted files.

## Settings and connection diagnostics

Settings → Integrations shows Claude Code and Codex, recorded source metadata, capabilities and last-event evidence. It deliberately reports Limited when history exists, rather than claiming a permanent live connection. Test Connection awaits a real Core doctor/storage/configuration check and reads session metadata; failures are reported. It does not run an AI task and does not certify client hook trust. Disable capture in Projects or disable only Prompt Relay's hooks in the source client; history remains.

`Integrations/configure-codex.py` previews the exact Prompt Relay command and three events. It writes only with `--apply`, backs up an existing hooks.json, preserves other hooks/settings, and supports `--disable --apply`. It does not touch config.toml, credentials or unrelated integrations. Review and trust the exact hook in the client; do not bypass hook trust. The launcher path points to this checkout and must be regenerated if it moves.

## First real Codex session — owner procedure

Reliable Xcode fallback, available now:

1. Copy the final answer in Xcode. Open Prompt Relay → Import AI Result.
2. Select Codex and host Xcode, supply the original task, project and session label, then import. These fields are user-supplied provenance.
3. Add available local result files explicitly (imported prose cannot establish observed creation), and optionally images from Clipboard.
4. In Quick Peek, Copy with Context; then Copy N Files or Drag N, and Done after completing your transfer.

Experimental Xcode automatic connection, not yet accepted:

From this checkout's `macos` directory, preview:

```sh
python3 Integrations/configure-codex.py \
  --config "$HOME/Library/Developer/Xcode/CodingAssistant/codex/hooks.json" \
  --host xcode
```

Review the printed command/events. Only if desired, repeat with `--apply`; the helper creates a backup. Enable capture for a disposable test project in Prompt Relay. Restart the Xcode agent as required by the client, and review/trust the hooks through the client's supported mechanism. If Xcode does not expose a usable trust flow or does not deliver hooks, **stop here and use manual import**; do not use an unsafe bypass. Xcode's bundled CLI sharing a version number is not proof of Xcode delivery.

For a dedicated CLI test project use that project's `.codex/hooks.json` with `--host terminal`, trust the project and hooks in Codex `/hooks`, and enable project capture. Use `--host unknown` for configuration shared among hosts; never mislabel a shared project hook as Xcode. Codex CLI must actually be installed/available; this acceptance did not install it.

In a new disposable session ask the agent to create REPORT.md via its file editing tool, create a small PNG, run `printf 'relay-ok\\n'`, run `sh -c 'exit 7'`, and name both result paths in its final answer. Check prompt/answer verbatim, provider/host, native turn linkage, command 0/7 where reported, shared History, and file provenance. REPORT.md should auto-select if successful write evidence arrives. The PNG auto-selects only with qualifying observed file evidence; otherwise approve its candidate manually. Test Quick Peek's complete text/files handoff, deselection in Details, switching to Claude, restart, Copy Text Again and Done.

Record separate outcomes for Xcode and CLI. The target of two automatically selected files is **not yet verified in either real client**. Never count the synthetic test fixture as that live smoke test.

## Validation and remaining acceptance

See the validation section below for final counts. Local logs and initial backups are in `acceptance/phase9/` and intentionally not committed. The initial tree is preserved in starting-worktree.zip, starting.patch and manifest.json; `refs/backup/phase9-start` retains the original HEAD. Phase 8.1 and 8.2 were separated from their actual source snapshot into local commits a58b3cd and 994e57b.

- Runtime probe: actually executed against Xcode's bundled Codex, isolated profile, no inference; initialize/hooks/list succeeded, zero loaded threads.
- Hook launcher → adapter → event storage → shared API/context: isolated synthetic events, including complete text, command failures, replay, collisions and mismatch.
- Shared Swift model → result snapshots → Quick Peek copy → persistent handoff: isolated files and named pasteboards.
- Existing offscreen layout tests: automated checks only, not real pointer interaction in a displayed app.
- Real Xcode capture / trusted CLI capture / VS Code capture: not verified in this run.
- Foreign-session passive App Server subscription: not implemented or claimed.
- New Integrations/filter UI and actual recipient paste/drag behavior: owner interactive check remains.

### Final automated validation

Completed 2026-11-03; reviewed again on continuation 2026-11-04:

| Check | Result | Evidence (local, not committed) |
|---|---|---|
| Full XCTest | 253 passed, 16 opt-in skipped, zero failures (269 enumerated) | acceptance/phase9/swift-final.log |
| Full Swift Testing | 14 passed in 5 suites, zero failures; includes 4 Phase 9 scenarios | acceptance/phase9/swift-final.log |
| Python 3.14.0 | 171 existing passed, 1 skipped; 12 integration tests passed | acceptance/phase9/core-final.log |
| Python 3.9.6 | 171 existing passed, 1 skipped; 12 integration tests passed | acceptance/phase9/core-final.log |
| Xcode Debug | BuildProject succeeded after final source edits | Xcode ActionArtifacts build log |
| Xcode Release | xcodebuild succeeded; separate /tmp DerivedData, signing disabled | acceptance/phase9/xcode-release.log |
| Hook latency, 50 synthetic events | direct median 42.3 ms / p95 48.2 ms; plugin median 63.5 ms / p95 68.3 ms | acceptance/phase9/core-final.log |
| Installed Codex protocol | initialize + hooks/list succeed; loaded threads = 0 | acceptance/phase9/runtime-check.json |
| Whitespace validation | git diff --check passed | Reviewed before staging |

The first full Swift run found three stale Claude-only test expectations; after updating the shared test reader and provenance expectation, targeted checks and the complete suite passed. The initial sandboxed Phase 9 test could not classify PNGs through macOS framework services; the permitted unsandboxed run passed with temporary storage and a named pasteboard. Neither failed run is counted as a success.

The tests cover provider/native-ID separation, replay, restart, missing text, unknown exit status, failed command diagnostics, mismatched turn IDs, subagent rejection, configured vs unknown host, exact raw text, safe setup/disable, five automatic artifacts, preserved deselection/removal, symlink/outside/secret/unavailable rejection, two clipboard images, shared Quick Peek selection, immutable preview and persisted handoff. Existing suites retain Pin/Unread, layout, history, clipboard and Claude regressions. These are not 35 separately executed live UI scenarios. Real host-specific capture, interactive geometry of the new controls and cross-application file transfer remain owner acceptance items.

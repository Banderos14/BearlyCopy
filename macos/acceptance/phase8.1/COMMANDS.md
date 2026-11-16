# Phase 8.1 commands and evidence

Working directory: `/Users/admin/Projects/prompt-relay/macos`.
Initial HEAD: `330f937c0d91e7bb1ba0f0daba4969fedd1de0da`, branch `claude/loving-mccarthy-ossw3q`; initial working tree clean.

Every test command redirected complete stdout/stderr to its `.log`, captured `$?` immediately in the matching `.exit`, then returned that same status. Log inspection with `tail`/`rg` did not determine test success.

All successful test invocations used:

```sh
swift test --disable-sandbox --cache-path /tmp/prompt-relay-p81-cache --filter 'FILTER' > LOG 2>&1
result=$?
echo "$result" > EXIT
cat LOG
exit "$result"
```

macOS access was required for isolated named pasteboards and offscreen AppKit hosts. The ordinary sandboxed attempt could compile with `--disable-sandbox` but its named pasteboard was unavailable and XCTest crashed; `tooltip-initial.log` / `.exit` record that failure. A preceding manifest sandbox attempt also exited 1 (`sandbox_apply: Operation not permitted`). Neither is a passing test run.

| Log basename | Filter / purpose |
| --- | --- |
| tooltip-layout | `Phase8Tests/testFullReportLinkEvidenceChipAndFooterNeverOverlap\|Phase8Tests/testTipsAvoidTheMainActionsAndStayInside`; intermediate layout failed at 268 pt |
| tooltip-regression | `Phase81Tests`; first geometry test and two-height renders, before final padding refinement |
| tooltip-final | `Phase81Tests\|Phase8Tests/testFullReportLinkEvidenceChipAndFooterNeverOverlap\|Phase8Tests/testTipsAvoidTheMainActionsAndStayInside\|TooltipWidthTests\|Phase8Tests/testWrappedTipEndsWhereItsLongestLineEnds\|Phase8Tests/testBlankTipIsNeverShown`; intermediate 3-pt footer gap failed the existing 4-pt assertion |
| ready | `Phase81ReadyTests\|ReadyAnswerTests\|Phase8Tests/testReadyIndicator`; test fixture initially attempted to pin an already-selected session via a no-op API; corrected to explicit report opening |
| acceptance | Filter below; no opt-in environment variables set |
| final-regressions | `Phase81Tests\|Phase81ReadyTests\|ReadyAnswerTests\|Phase8Tests/testReadyIndicator\|Phase8Tests/testRenderPhase8States\|Phase8Tests/testFullReportLinkEvidenceChipAndFooterNeverOverlap`; opt-in render output set to this directory |

Acceptance filter:

```text
Phase8Tests|Phase81ReadyTests|ReadyAnswerTests|Phase71Tests|AttachmentHandoffTests|SmartContextTests|RelayMotionTests|LivingRelayTests|RelayRestingTests|Phase6Tests/testClosingTheIslandKeepsStepTwoUntilDone|Phase6Tests/testSwitchingToASessionEndsTheHandoffAndDoneKeepsTheClipboard|Phase6VisualTests/testPreviewShowsExactlyWhatIsCopiedAndBelongsToOneAnswer|IslandLayoutTests|Phase7Tests/testEveryRealTooltipIsDrawnInsideTheIsland|IslandTests|DailyUseTests
```

Render runs set `PROMPT_RELAY_VISUALS="$PWD/acceptance/phase8.1"`. No real-data audit, real-dialog, real-panel performance or recipient paste opt-in was enabled. Tests operate on FakeCore, temporary stores/default suites and named pasteboards. The live app was not launched.

The original Phase 8 `after/p8-details-341-tip-full.png` and `after/p8-details-448-tip-copy.png` were read from the existing Claude scratchpad and visually inspected. They show help over Answer and Evidence respectively. New `p81-*.png` files are offscreen renders, not live-app screenshots.

Final readiness rerun (`ready-final.log`, exit 0):

```text
Phase81ReadyTests|ReadyAnswerTests|Phase8Tests/testReadyIndicator|IslandTests|DailyUseTests
```

The filter matched 4 XCTest tests and 3 Swift Testing tests (the unmatched alternatives do not count as executed tests). This rerun includes the final guard against background events making an already-read report unread again.

Final application build: Xcode MCP `BuildProject({})`, active scheme `Prompt Relay`, 2026-11-01. Result: `The project built successfully.`, errors `[]`. Full log copied to `xcode-build.log`; tool result saved as `xcode-build-result.json`. The MCP tool does not expose a shell exit code; none is inferred.

Final `git diff --check`: exit 0. No commits, push, merge, or destructive Git operations.

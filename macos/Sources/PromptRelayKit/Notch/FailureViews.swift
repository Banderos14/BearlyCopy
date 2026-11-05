import SwiftUI

/// Failure Inspector (Phase 8) at the top of Observed Work: one card per
/// command that did not exit 0, with what the hook recorded, what the exit
/// code usually means, a later run of the same command when there was one,
/// and what was not recorded. Facts only; nothing is re-run or called fixed.
struct FailureSection: View {
    let inspector: FailureInspector

    var body: some View {
        let entries = inspector.entries
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: Island.Space.s) {
                HStack(spacing: 5) {
                    Caption("Did not exit 0", role: Island.error)
                    Text(Self.summary(entries)).font(.system(size: 11)).foregroundStyle(Island.tertiary).lineLimit(1)
                }
                .islandFrame("failures.header")
                ForEach(entries) { FailureCard(entry: $0) }
            }
            .islandFrame("failures")
        }
    }

    /// "2 commands · 1 probably a no-match"
    static func summary(_ entries: [FailureInspector.Entry]) -> String {
        let quiet = entries.filter(\.likelyNotAnError).count
        return "\(entries.count) command\(entries.count == 1 ? "" : "s")" + (quiet > 0 ? " · \(quiet) probably not an error" : "")
    }
}

struct FailureCard: View {
    let entry: FailureInspector.Entry

    var body: some View {
        let c = entry.command
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: entry.likelyNotAnError ? "questionmark.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(entry.likelyNotAnError ? Island.tertiary : Island.error)
                Text(CommandDiagnostics.safeText(c) ?? "(command withheld)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Island.primary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(facts(c)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Island.tertiary).lineLimit(1).fixedSize()
            }
            line(entry.meaning, color: Island.secondary)
            ForEach(entry.caveats, id: \.self) { line("¹ " + $0, color: Island.tertiary) }
            if c.tailWithheld == nil, let tail = c.outputTail {
                BoundedScroll(maxHeight: 96) {
                    Text(tail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Island.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).padding(.trailing, 4)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: Island.smallRadius, style: .continuous).fill(Island.code))
                .accessibilityLabel("Last lines of the output")
            }
            if let later = entry.later { laterLine(later) }
            ForEach(entry.unavailable, id: \.self) { line($0, color: Island.tertiary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Island.cardRadius, style: .continuous).fill(Island.card))
        .accessibilityElement(children: .contain)
    }

    private func facts(_ c: ObservedCommand) -> String {
        [c.exitCode.map { "exit \($0)" } ?? (c.outcome == "interrupted" ? "interrupted" : "exit ?"),
         Wording.duration(c.durationMs), Wording.clock(c.at)].joined(separator: " · ")
    }

    private func line(_ text: String, color: Color) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    /// A later run, as observed: its exit code, never "fixed".
    private func laterLine(_ later: FailureInspector.Later) -> some View {
        let c = later.command
        let result = c.exitCode.map { "exited \($0)" } ?? "ended without an exit code"
        let what = later.match == .sameCommand ? "The same command ran again" : "The same tool ran again"
        let caveat = c.compound ? " (with a pipe or `;`: the exit code is the last process's)" : ""
        let tail = later.passed ? ". An exit 0 is what was observed, not proof that the cause is fixed." : "."
        return HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(later.passed ? Island.success : Island.warning)
            Text("\(what) at \(Wording.clock(c.at))" + (later.match == .sameTool ? ": `\(CommandDiagnostics.safeText(c) ?? "withheld")`" : "") + " and \(result)\(caveat)\(tail)")
                .font(.system(size: 11)).foregroundStyle(Island.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .islandFrame("failure.later")
    }
}

import Foundation

/// Evidence is scoped to Codex/Xcode; CLI and legacy logs cannot satisfy it.
struct CodexDeliveryStatus {
    let sessions: [SessionSummary]
    let observed: DoctorData.Observed.Source?

    var xcodeSessions: [SessionSummary] {
        sessions.filter { $0.provider == .codex && $0.source?.environment == .xcode }
    }

    var summary: String {
        if !xcodeSessions.isEmpty { return "Xcode delivery: events saved and readable by Core" }
        if observed != nil { return "Xcode delivery: handler executed; no readable session yet" }
        return "Xcode delivery: hook execution not confirmed"
    }

    var detail: String {
        var lines: [String] = []
        if let observed {
            lines.append("Last handler event: \(observed.lastEvent) · \(observed.lastAt)")
            switch observed.lastOutcome {
            case "stored", "duplicate": lines.append("Last receipt: saved successfully")
            case "project_not_enabled": lines.append("Last receipt rejected: capture is off for the event’s workspace")
            case "unsupported_source_event": lines.append("Last receipt rejected: unsupported Codex payload")
            case "invalid_json", "invalid_utf8", "invalid_payload", "payload_too_large":
                lines.append("Last receipt rejected: invalid or oversized payload")
            default: lines.append("Last receipt failed: check Core and capture storage")
            }
            if let at = observed.lastErrorAt {
                lines.append("Reception/storage error recorded at \(at); run Test Connection after correcting it")
            }
        } else {
            lines.append("No attributed handler diagnostics in the current log; older logs cannot identify the provider")
        }
        let latest = xcodeSessions.max { ($0.lastEventAt ?? "") < ($1.lastEventAt ?? "") }
        if let latest {
            lines.append("Latest saved event: \(latest.lastEventAt ?? "unknown")")
            switch latest.lastTurn?.status {
            case .stopReceived, .stopReceivedBackgroundTasksPending:
                lines.append("Latest turn: Stop and answer received")
            case .stopReceivedWithoutText:
                lines.append("Latest turn: Stop received without answer text")
            default:
                lines.append("Latest turn: waiting for Stop; final answer not confirmed")
            }
            lines.append("Workspace: \(latest.project.path ?? "unknown")")
        } else {
            lines.append("After reviewing hooks, start a new Xcode Codex conversation in a capture-enabled workspace")
        }
        return lines.joined(separator: "\n")
    }
}

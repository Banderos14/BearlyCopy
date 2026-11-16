import Foundation

/// The Core's secret heuristics (`plugin/prompt_relay/sensitive.py`), for
/// text the Core never sees: imported reports. Same patterns, same rule
/// (one finding per line, the first pattern that matches), and like the
/// Core it reports the kind and line, never the matched value. A test runs
/// both scanners on the same samples.
public enum SecretScanner {
    private static let patterns: [(String, NSRegularExpression)] = [
        ("private key block", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        ("Anthropic API key", #"\bsk-ant-[A-Za-z0-9_-]{20,}"#),
        ("OpenAI-style API key", #"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}"#),
        ("GitHub token", #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}"#),
        ("AWS access key id", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("Slack token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
        ("Google API key", #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        ("JSON Web Token", #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        ("credential assignment",
         #"(?i)\b[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|PRIVATE_KEY)[A-Z0-9_]*\s*[:=]\s*['"]?[^\s'"]{8,}"#),
        // Phase 17: the same in JSON form — `"api_key": "value"` (a quoted key
        // was not matched, and JSON files are now prepared automatically).
        ("credential assignment",
         #"(?i)["'][A-Z0-9_-]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|API-KEY|PRIVATE_KEY)[A-Z0-9_-]*["']\s*:\s*["'][^\s'"]{8,}["']"#),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    /// Lines are split like Python's `str.splitlines()` for \n, \r\n and \r.
    public static func scan(_ text: String, section: String) -> [SensitiveFinding] {
        var findings: [SensitiveFinding] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (number, line) in lines.enumerated() {
            let s = String(line), range = NSRange(s.startIndex..., in: s)
            if let kind = patterns.first(where: { $0.1.firstMatch(in: s, range: range) != nil })?.0 {
                findings.append(SensitiveFinding(section: section, line: number + 1, kind: kind))
            }
        }
        return findings
    }
}

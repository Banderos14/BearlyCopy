"""Heuristic detection of secrets in text that is about to be exported.

Findings only warn; the text itself is never modified. Reports name the
pattern and line number, never the matched value.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import List

_PATTERNS = [
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("Anthropic API key", re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}")),
    ("OpenAI-style API key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}")),
    ("GitHub token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{40,}")),
    ("AWS access key id", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("Slack token", re.compile(r"\bxox[abposr]-[A-Za-z0-9-]{10,}")),
    ("Google API key", re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b")),
    ("JSON Web Token", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("credential assignment", re.compile(
        r"(?i)\b[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|PRIVATE_KEY)[A-Z0-9_]*\s*[:=]\s*['\"]?[^\s'\"]{8,}")),
    # The same in JSON form: "api_key": "value" (a quoted key was not matched).
    ("credential assignment", re.compile(
        r"(?i)[\"'][A-Z0-9_-]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_KEY|APIKEY|API-KEY|PRIVATE_KEY)[A-Z0-9_-]*[\"']"
        r"\s*:\s*[\"'][^\s'\"]{8,}[\"']")),
]


@dataclass
class Finding:
    kind: str
    line: int
    section: str


def scan(text: str, section: str) -> List[Finding]:
    findings: List[Finding] = []
    for lineno, line in enumerate(text.splitlines(), start=1):
        for kind, pattern in _PATTERNS:
            if pattern.search(line):
                findings.append(Finding(kind, lineno, section))
                break
    return findings

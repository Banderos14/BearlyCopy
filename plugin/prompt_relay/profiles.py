"""Local agent profiles (Phase 12, docs/MULTI_AGENT_MODEL.md).

A *profile* is one configuration home of an agent on this Mac: the folder
Claude Code (``CLAUDE_CONFIG_DIR``, default ``~/.claude``) or Codex
(``CODEX_HOME``, default ``~/.codex``) runs with. Two homes are two profiles,
so "Claude · Personal" and "Claude · Work" never mix.

What this is NOT: an account. The folder says where the agent keeps its
settings, not who is signed in; a person can sign in to another account in
the same folder, and hooks do not tell. Prompt Relay therefore never reads
credentials, tokens, ``auth.json``, keychain items or e-mail addresses, and
never calls a profile an account. Names ("Work") are labels the user gives
in the app; they are not stored here.

Identifier: ``<prefix>-default`` for the provider's default home (stable on
every Mac, needs no hashing), otherwise ``<prefix>-`` + the first 16 hex
digits of SHA-256 over the home's real path. Only a short display hint is
kept (``~/.claude-work``): never the user name or an absolute home path.

Records written before Phase 12 carry no profile. Claude Code ones are
reported without one ("Unassigned" in the app); Codex ones already recorded
``installation_id`` (SHA-256 of the real CODEX_HOME path) and map to the
same profile id a new record would get.
"""

from __future__ import annotations

import hashlib
import os
from typing import Any, Dict, Mapping, Optional

HOME_ENV = {"claude_code": "CLAUDE_CONFIG_DIR", "codex": "CODEX_HOME"}
DEFAULT_HOME = {"claude_code": "~/.claude", "codex": "~/.codex"}
PREFIX = {"claude_code": "cc", "codex": "cx"}

BASIS_CONFIG_DIR = "config_dir"        # the provider's home variable named the folder
BASIS_DEFAULT_HOME = "default_home"    # no variable: the provider's documented default
BASIS_INSTALLATION = "installation"    # derived from an older record's installation_id

ID_HEX = 16
SCOPE_HEX = 12  # suffix added to a non-default Claude profile's session key


def _home(env: Mapping[str, str]) -> str:
    home = env.get("HOME")
    return home if isinstance(home, str) and os.path.isabs(home) else os.path.expanduser("~")


def _expand(path: str, env: Mapping[str, str]) -> str:
    if path == "~" or path.startswith("~/"):
        return _home(env) + path[1:]
    return path


def _real(path: str) -> str:
    return os.path.realpath(path)


def digest(real_path: str) -> str:
    return hashlib.sha256(real_path.encode("utf-8", "surrogatepass")).hexdigest()


def hint(real_path: str, env: Mapping[str, str]) -> str:
    """``~/<relative>`` under the home folder, else the last component only."""
    home = _real(_home(env))
    if real_path == home:
        return "~"
    if real_path.startswith(home.rstrip("/") + "/"):
        return "~" + real_path[len(home.rstrip("/")):]
    return os.path.basename(real_path.rstrip("/")) or "/"


def default_real(provider: str, env: Mapping[str, str]) -> Optional[str]:
    default = DEFAULT_HOME.get(provider)
    return _real(_expand(default, env)) if default else None


def from_env(provider: str, env: Mapping[str, str]) -> Optional[Dict[str, Any]]:
    """The profile of a hook run, from the provider's own home variable.

    A relative or empty value is not evidence of a folder: the default home
    is used then, as the provider itself would."""
    if provider not in HOME_ENV:
        return None
    default = default_real(provider, env)
    raw = env.get(HOME_ENV[provider])
    basis = BASIS_DEFAULT_HOME
    real = default
    if isinstance(raw, str) and raw.strip():
        expanded = _expand(raw.strip(), env)
        if os.path.isabs(expanded):
            real = _real(expanded)
            basis = BASIS_CONFIG_DIR
    if real is None:
        return None
    is_default = real == default
    pid = f"{PREFIX[provider]}-default" if is_default else f"{PREFIX[provider]}-{digest(real)[:ID_HEX]}"
    return {"id": pid, "provider": provider, "basis": basis, "default": is_default, "hint": hint(real, env)}


def from_installation(installation_id: Optional[str], env: Mapping[str, str]) -> Optional[Dict[str, Any]]:
    """A Codex record written before Phase 12: the same id a new record of
    that CODEX_HOME gets. No hint: the path itself was never stored."""
    if not isinstance(installation_id, str) or len(installation_id) < ID_HEX:
        return None
    default = default_real("codex", env)
    is_default = default is not None and digest(default) == installation_id
    pid = "cx-default" if is_default else f"cx-{installation_id[:ID_HEX]}"
    return {"id": pid, "provider": "codex", "basis": BASIS_INSTALLATION, "default": is_default,
            "hint": hint(default, env) if is_default and default else None}


def scoped_session_id(session_id: Any, profile: Optional[Dict[str, Any]]) -> Any:
    """Claude Code session ids are only unique within one config home. For a
    non-default home the stored key gets the profile's suffix, so equal ids
    from two homes can never share a history file. The default home keeps
    the plain id: existing history keys do not change."""
    if not isinstance(session_id, str) or not session_id or not profile or profile.get("default"):
        return session_id
    return f"{session_id}.{profile['id'].split('-', 1)[1][:SCOPE_HEX]}"


def valid(profile: Any) -> Optional[Dict[str, Any]]:
    """A stored profile as the read side accepts it (allowlisted fields)."""
    if not isinstance(profile, dict):
        return None
    pid, provider = profile.get("id"), profile.get("provider")
    if not isinstance(pid, str) or provider not in PREFIX or not pid.startswith(PREFIX[provider] + "-"):
        return None
    if len(pid) > 3 + ID_HEX or not all(c.isalnum() or c == "-" for c in pid):
        return None
    out: Dict[str, Any] = {"id": pid, "provider": provider,
                           "basis": profile.get("basis") if profile.get("basis") in (BASIS_CONFIG_DIR, BASIS_DEFAULT_HOME, BASIS_INSTALLATION) else BASIS_CONFIG_DIR,
                           "default": profile.get("default") is True}
    h = profile.get("hint")
    out["hint"] = h[:200] if isinstance(h, str) and h else None
    return out

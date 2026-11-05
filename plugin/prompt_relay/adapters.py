"""Public hook adapters. No transcript reads, subprocesses or network access."""
from __future__ import annotations
import hashlib
import json
import os
import re
from typing import Any, Dict, Mapping, Optional
from prompt_relay import signals, tools

PROVIDERS = ('claude_code', 'codex')
HOSTS = ('claude_desktop', 'xcode', 'terminal', 'vscode', 'other', 'unknown')


def _xcode_write_result(response: Any) -> Optional[str]:
    """Only an explicit successful tool result with an absolute path is evidence.

    Xcode navigator paths and requested input paths are not filesystem evidence.
    MCP can return structuredContent or a JSON text content block.
    """
    if isinstance(response, str):
        try:
            response = json.loads(response)
        except ValueError:
            return None
    if not isinstance(response, dict) or response.get('isError') is True:
        return None
    result = response.get('structuredContent', response)
    if isinstance(result, dict) and result.get('success') is True:
        path = result.get('absolutePath')
        if isinstance(path, str) and os.path.isabs(path):
            return path
    for block in response.get('content', []) if isinstance(response.get('content'), list) else []:
        if isinstance(block, dict) and block.get('type') == 'text' and isinstance(block.get('text'), str):
            try:
                result = json.loads(block['text'])
            except ValueError:
                continue
            if isinstance(result, dict) and result.get('success') is True:
                path = result.get('absolutePath')
                if isinstance(path, str) and os.path.isabs(path):
                    return path
    return None


# Phase 9.4: Claude Code tells its child processes (hooks included) which
# client started it in CLAUDE_CODE_ENTRYPOINT. Observed 2026-11-05 on this Mac:
# "claude-desktop" inside Claude Desktop's Code tab. Only these exact values
# name a host; anything else (sdk-*, remote, new values) is not a host claim.
ENTRYPOINT_HOSTS = {'claude-desktop': 'claude_desktop', 'cli': 'terminal', 'claude-vscode': 'vscode'}


def claude_host(env: Mapping[str, str]) -> Optional[str]:
    """A configured launcher host first, else the entrypoint Claude Code set."""
    host = env.get('PROMPT_RELAY_HOST')
    if host in HOSTS:
        return host
    return ENTRYPOINT_HOSTS.get(env.get('CLAUDE_CODE_ENTRYPOINT', ''))


def _claude(payload: Dict[str, Any], env: Mapping[str, str]) -> Optional[Dict[str, Any]]:
    event = payload.get('hook_event_name')
    if event in signals.SIGNAL_EVENTS:
        out = signals.reduce(payload)
        if out is None:
            return None
    elif event in tools.TOOL_EVENTS and not signals.is_evidence(payload):
        out = signals.activity(payload)   # hook.py stores it only while a wait is open
    else:
        out = tools.reduce(payload) if event in tools.TOOL_EVENTS else dict(payload)
    out.pop('source', None)
    # Existing Claude session keys remain stable across upgrades. Host is only
    # accepted from a configured launcher or Claude Code's own entrypoint, never guessed.
    host = claude_host(env)
    if host in HOSTS:
        out['source'] = dict(provider='claude_code', host=host,
                             native_session_id=payload.get('session_id') or 'unknown',
                             capabilities=['prompt', 'final_response', 'tools', 'file_changes', 'workspace_metadata'],
                             capture='hooks')
    return out


def _codex(payload: Dict[str, Any], env: Mapping[str, str]) -> Optional[Dict[str, Any]]:
    provider = 'codex'
    native = payload.get('session_id')
    turn = payload.get('turn_id')
    if not isinstance(native, str) or not native or not isinstance(turn, str) or not turn:
        return None
    if payload.get('agent_id'):
        return None  # Codex subagents share parent session_id: never merge their answers.
    event = payload.get('hook_event_name')
    if event not in ('UserPromptSubmit', 'Stop', 'PostToolUse', 'PermissionRequest'):
        return None
    host = env.get('PROMPT_RELAY_HOST', 'unknown')
    if host not in HOSTS:
        host = 'unknown'
    installation = os.path.realpath(env.get('CODEX_HOME') or os.path.expanduser('~/.codex'))
    cwd = payload.get('cwd')
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        return None
    cwd = os.path.realpath(cwd)
    identity = json.dumps([provider, native, host, installation, cwd], ensure_ascii=True)
    key = 'codex-' + hashlib.sha256(identity.encode()).hexdigest()
    source = dict(provider=provider, host=host, native_session_id=native,
                  installation_id=hashlib.sha256(installation.encode()).hexdigest(),
                  capabilities=['prompt', 'final_response', 'tools', 'file_changes', 'workspace_metadata'],
                  capture='hooks')
    common = dict(hook_event_name=event, session_id=key, prompt_id=turn, cwd=cwd)
    if event == 'PermissionRequest':
        # Phase 12.1: Codex is about to ask for approval. Reduced like a
        # Claude Code signal; Prompt Relay never answers it.
        out = dict(common, reduced=1, signal=signals.NEEDS_INPUT, kind=signals.PERMISSION)
        tool = payload.get('tool_name')
        if isinstance(tool, str) and tool:
            out['tool_name'] = tool[:120]
    elif event == 'UserPromptSubmit':
        if not isinstance(payload.get('prompt'), str):
            return None
        out = dict(common, prompt=payload['prompt'])
    elif event == 'Stop':
        value = payload.get('last_assistant_message')
        out = dict(common, last_assistant_message=value if isinstance(value, str) else None,
                   stop_hook_active=payload.get('stop_hook_active') is True)
    else:
        tool = payload.get('tool_name')
        inputs = payload.get('tool_input')
        inputs = inputs if isinstance(inputs, dict) else {}
        response = payload.get('tool_response')
        raw = dict(common, tool_name=tool, tool_input=inputs, tool_response=response,
                   tool_use_id=payload.get('tool_use_id'))
        out = tools.reduce(raw)
        if tool == 'Bash':
            # Codex PostToolUse also reports failed commands. Never assume exit 0.
            code = response.get('exit_code') if isinstance(response, dict) else None
            text = response if isinstance(response, str) else ''
            if not isinstance(code, int) or isinstance(code, bool):
                match = re.search(r'(?m)^Process exited with code (-?\d+)\s*$', text)
                code = int(match.group(1)) if match else None
            out.pop('exit_code', None)
            out['outcome'] = 'unknown' if code is None else ('ok' if code == 0 else 'failed')
            if code is not None:
                out['exit_code'] = code
            if code is not None and code != 0 and out.get('kind') in ('test', 'build'):
                output = response.get('output', response.get('stderr', '')) if isinstance(response, dict) else text
                tail = tools._tail(output) if isinstance(output, str) else None
                if tail and tools.scan(tail, 'output'):
                    out['tail_withheld'] = 'possible_secret'
                elif tail:
                    out['output_tail'] = tail
            duration = response.get('duration_ms') if isinstance(response, dict) else None
            if isinstance(duration, int) and not isinstance(duration, bool) and duration >= 0:
                out['duration_ms'] = duration
        elif tool == 'apply_patch':
            # Only successful output paths are evidence. Patch inputs alone are intent.
            text = response if isinstance(response, str) else ''
            out['paths_changed'] = re.findall(r'(?m)^[AM] (.+)$', text) if text.startswith('Success.') else []
        elif isinstance(tool, str) and tool.endswith(('__XcodeWrite', '__XcodeUpdate')):
            path = _xcode_write_result(response)
            out['outcome'] = 'ok' if path else 'unknown'
            if path:
                out['paths_changed'] = [path]
    out['source'] = source
    out['native_turn_id'] = turn
    return out


ADAPTERS = {'claude_code': _claude, 'codex': _codex}


def normalize(payload: Dict[str, Any], env: Mapping[str, str]) -> Optional[Dict[str, Any]]:
    # Provider comes from the launcher, never from words in a response.
    adapter = ADAPTERS.get(env.get('PROMPT_RELAY_PROVIDER', 'claude_code'))
    return adapter(payload, env) if adapter else None

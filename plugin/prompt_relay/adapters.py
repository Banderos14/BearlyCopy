"""Public hook adapters. No transcript reads, subprocesses or network access."""
from __future__ import annotations
import hashlib
import json
import os
import re
from typing import Any, Dict, Mapping, Optional
from prompt_relay import tools

PROVIDERS = ('claude_code', 'codex')
HOSTS = ('claude_desktop', 'xcode', 'terminal', 'vscode', 'other', 'unknown')


def _claude(payload: Dict[str, Any], env: Mapping[str, str]) -> Optional[Dict[str, Any]]:
    out = tools.reduce(payload) if payload.get('hook_event_name') in tools.TOOL_EVENTS else dict(payload)
    out.pop('source', None)
    # Existing Claude session keys remain stable across upgrades. Host is only
    # accepted from a launcher configured for that client, never guessed.
    host = env.get('PROMPT_RELAY_HOST')
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
    if event not in ('UserPromptSubmit', 'Stop', 'PostToolUse'):
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
    if event == 'UserPromptSubmit':
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
            # Xcode logical paths are not filesystem paths; don't fabricate them.
            out['outcome'] = 'unknown'
    out['source'] = source
    out['native_turn_id'] = turn
    return out


ADAPTERS = {'claude_code': _claude, 'codex': _codex}


def normalize(payload: Dict[str, Any], env: Mapping[str, str]) -> Optional[Dict[str, Any]]:
    # Provider comes from the launcher, never from words in a response.
    adapter = ADAPTERS.get(env.get('PROMPT_RELAY_PROVIDER', 'claude_code'))
    return adapter(payload, env) if adapter else None

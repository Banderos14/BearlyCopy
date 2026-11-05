import io
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'plugin'))
from prompt_relay import hook, config, history, api, export, integration
from prompt_relay.store import Store
from prompt_relay.gitinfo import GitInfo


class AdaptersTests(unittest.TestCase):
    def test_xcode_write_requires_successful_absolute_result(self):
        self.send('UserPromptSubmit', prompt='task')
        result = {'success': True, 'absolutePath': str(self.project/'REPORT.md')}
        for i, response in enumerate([
            {'structuredContent': result},
            {'content': [{'type': 'text', 'text': json.dumps(result)}]},
            {'success': False, 'absolutePath': str(self.project/'FAILED.md')},
            {'success': True, 'filePath': 'Project/UNCONFIRMED.md'},
            {'isError': True, 'structuredContent': result},
        ]):
            self.send('PostToolUse', tool_name='mcp__xcode_tools__XcodeWrite', tool_use_id=str(i),
                      tool_input={'filePath': 'Project/UNCONFIRMED.md'}, tool_response=response)
        self.send('Stop', last_assistant_message='REPORT.md')
        session = history.load_all(Store(self.data))[0]
        files = api.turn_object(session.turns[0], full=True)['observed_detail']['files_changed']
        self.assertEqual([f['path'] for f in files], [str(self.project/'REPORT.md')])

    def test_diagnostics_attribute_rejections_without_payload_text(self):
        env = dict(self.env, PROMPT_RELAY_HOME=str(self.data))
        raw = json.dumps(dict(hook_event_name='UserPromptSubmit', cwd='/not-enabled',
                              prompt='PRIVATE PROMPT', session_id='PRIVATE ID', turn_id='1')).encode()
        self.assertEqual(hook.main(io.BytesIO(raw), env), 0)
        seen = integration.observed(self.data)['by_source']['codex:xcode']
        self.assertEqual(seen['last_outcome'], 'project_not_enabled')
        self.assertNotIn('last_stored_at', seen)
        self.assertNotIn('PRIVATE', (self.data/'handler.log').read_text())
        hook.main(io.BytesIO(b'invalid'), env)
        self.assertEqual(integration.observed(self.data)['by_source']['codex:xcode']['last_error'], 'invalid_json')
        env['PROMPT_RELAY_HOST'] = 'terminal'
        hook.main(io.BytesIO(b'invalid'), env)
        self.assertEqual(integration.observed(self.data)['by_source']['codex:xcode']['events'], 2)
        # Phase 11: the CLI run has its own slot; it never proves Xcode delivery.
        self.assertEqual(integration.observed(self.data)['by_source']['codex:terminal']['events'], 1)
        (self.data/'handler.log').write_text('2026-11-04T00:00:00Z Stop via=plugin provider=codex host=evil stored\n')
        self.assertEqual(integration.observed(self.data)['by_source'], {})

    def test_legacy_log_does_not_prove_codex_execution(self):
        (self.data/'handler.log').write_text('2026-11-04T00:00:00Z Stop via=plugin stored\n')
        self.assertEqual(integration.observed(self.data)['by_source'], {})

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        self.data = self.root / 'data'
        config.save(self.data, config.Config(enabled_projects=[str(self.project)]))
        self.env = {'PROMPT_RELAY_PROVIDER': 'codex', 'PROMPT_RELAY_HOST': 'xcode', 'CODEX_HOME': str(self.root / 'codex')}
        self.tick = 1000

    def send(self, event, **extra):
        value = dict(hook_event_name=event, session_id='same-native', turn_id='turn-1', cwd=str(self.project), **extra)
        self.tick += 1
        return hook.process(json.dumps(value).encode(), self.env, now=self.tick, root=self.data)[1]

    def test_source_identity_replay_and_restart(self):
        self.assertEqual(self.send('UserPromptSubmit', prompt='Full task\r\n🦊'), 'stored')
        self.assertEqual(self.send('Stop', last_assistant_message='Full answer\r\nClaude literal'), 'stored')
        self.assertEqual(self.send('Stop', last_assistant_message='Full answer\r\nClaude literal'), 'duplicate')
        self.env = {}
        self.send('UserPromptSubmit', prompt='Claude task', prompt_id='turn-1')
        self.send('Stop', last_assistant_message='Claude answer', prompt_id='turn-1')
        sessions = history.load_all(Store(self.data))
        self.assertEqual(len(sessions), 2)
        codex = next(s for s in sessions if s.key.startswith('codex-'))
        self.assertEqual(codex.turns[0].final_response.text, 'Full answer\r\nClaude literal')
        source = api.session_summary(codex)['source']
        self.assertEqual(source['provider'], 'codex')
        self.assertEqual(source['host'], 'xcode')
        self.assertNotIn('live_status', source['capabilities'])
        self.assertEqual(len(history.load_all(Store(self.data))), 2)

    def test_host_and_installation_separate_sessions(self):
        self.send('UserPromptSubmit', prompt='task')
        self.env['PROMPT_RELAY_HOST'] = 'terminal'
        self.send('UserPromptSubmit', prompt='task')
        self.env['CODEX_HOME'] += '-other'
        self.send('UserPromptSubmit', prompt='task')
        self.assertEqual(len(history.load_all(Store(self.data))), 3)

    def test_commands_do_not_assume_success(self):
        self.send('UserPromptSubmit', prompt='task')
        for i, response in enumerate([{'exit_code': 0}, {'exit_code': 7}, 'unrecognized output']):
            self.send('PostToolUse', tool_name='Bash', tool_use_id=str(i), tool_input={'command':'swift test'}, tool_response=response)
        self.send('Stop', last_assistant_message='answer')
        session = history.load_all(Store(self.data))[0]
        commands = api.turn_object(session.turns[0], full=True)['observed_detail']['commands']
        self.assertEqual([c['exit_code'] for c in commands], [0, 7, None])
        self.assertEqual(commands[-1]['outcome'], 'unknown')

    def test_patch_results_not_intentions(self):
        self.send('UserPromptSubmit', prompt='task')
        for i, response in enumerate(['Error: denied', 'Success. Updated the following files:\nA REPORT.md\nM file.swift\n']):
            self.send('PostToolUse', tool_name='apply_patch', tool_use_id=str(i), tool_input={'command':'secret file contents'}, tool_response=response)
        self.send('Stop', last_assistant_message='REPORT.md')
        session = history.load_all(Store(self.data))[0]
        files = api.turn_object(session.turns[0], full=True)['observed_detail']['files_changed']
        self.assertEqual(len(files), 2)
        self.assertNotIn('secret file contents', next((self.data/'events').glob('*.jsonl')).read_text())

    def test_subagent_and_mismatched_turn(self):
        self.assertEqual(self.send('Stop', last_assistant_message='subagent', agent_id='child'), 'unsupported_source_event')
        self.send('UserPromptSubmit', prompt='first')
        raw = dict(hook_event_name='Stop', session_id='same-native', turn_id='different', cwd=str(self.project), last_assistant_message='answer')
        hook.process(json.dumps(raw).encode(), self.env, root=self.data)
        session = history.load_all(Store(self.data))[0]
        self.assertEqual(len(session.turns), 2)
        self.assertIsNone(session.turns[-1].prompt)

    def test_shared_export_preserves_verbatim_text(self):
        request = 'Original Claude task\r\n```\nlong '
        answer = 'Codex says Claude did it.\r\n```\nend'
        self.send('UserPromptSubmit', prompt=request)
        self.send('Stop', last_assistant_message=answer)
        session = history.load_all(Store(self.data))[0]
        text = export.render_context(session, session.turns[0], GitInfo(False, 'not a repository'), 'now')
        self.assertIn(request, text)
        self.assertIn(answer, text)
        self.assertEqual(text.count(answer), 1)
        self.assertIn('Host: Xcode [Confirmed locally]', text)
        self.assertIn('- Source: Codex · Xcode · This Mac', text)
        self.assertIn('Reported by Codex', text)
        self.assertNotIn('Source: Claude Code', text)

    def test_untrusted_origin_and_wrong_claude_environment(self):
        self.env['CLAUDE_PROJECT_DIR'] = '/not/the/codex/project'
        self.send('UserPromptSubmit', prompt='<system-reminder>literal user text</system-reminder>')
        self.send('Stop')
        session = history.load_all(Store(self.data))[0]
        turn = api.turn_object(session.turns[0], full=True)
        self.assertEqual(turn['request_origin'], 'unknown')
        text = export.render_context(session, session.turns[0], GitInfo(False, 'not a repository'), 'now')
        self.assertIn('without a final message', text)
        self.assertNotIn('Not written by the user', text)

    def test_configured_claude_host_preserves_legacy_session(self):
        self.env = {'PROMPT_RELAY_HOST': 'vscode'}
        self.send('UserPromptSubmit', prompt='task', prompt_id='p')
        self.send('Stop', last_assistant_message='answer', prompt_id='p')
        session = history.load_all(Store(self.data))[0]
        self.assertEqual(api.session_summary(session)['source']['provider'], 'claude_code')
        text = export.render_context(session, session.turns[0], GitInfo(False, 'not a repository'), 'now')
        self.assertIn('Source: Claude Code', text)
        self.assertIn('Host: VS Code [Confirmed locally]', text)
        self.assertNotIn('Source: Codex', text)

    def test_failure_tail_and_unknown_format(self):
        self.send('UserPromptSubmit', prompt='task')
        self.send('PostToolUse', tool_name='Bash', tool_use_id='x', tool_input={'command':'swift test'},
                  tool_response='Process exited with code 7\nOutput:\ntest failed')
        session = history.load_all(Store(self.data))[0]
        command = api.turn_object(session.turns[0], full=True)['observed_detail']['commands'][0]
        self.assertEqual(command['exit_code'], 7)
        self.assertIn('test failed', command['output_tail'])

    def test_real_launcher_with_synthetic_hook_input(self):
        launcher = Path(__file__).resolve().parents[2] / 'plugin/hooks/run-hook'
        env = dict(os.environ, **self.env, PROMPT_RELAY_HOME=str(self.data))
        for event, values in [('UserPromptSubmit', {'prompt': 'launcher task'}),
                              ('Stop', {'last_assistant_message': 'launcher answer'})]:
            raw = dict(hook_event_name=event, session_id='launcher', turn_id='one', cwd=str(self.project), **values)
            result = subprocess.run(['/bin/sh', str(launcher)], input=json.dumps(raw).encode(), env=env,
                                    cwd=str(self.project), capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, b'')
        session = history.load_all(Store(self.data))[0]
        self.assertEqual(session.turns[0].final_response.text, 'launcher answer')
        self.assertEqual(api.session_summary(session)['source']['provider'], 'codex')

    def test_disabled_fails_closed(self):
        env = dict(self.env, PROMPT_RELAY_DISABLE='1')
        self.assertEqual(hook.process(b'{}', env, root=self.data)[1], 'disabled')
        self.assertEqual(hook.main(io.BytesIO(b'bad'), env), 0)


if __name__ == '__main__':
    unittest.main()

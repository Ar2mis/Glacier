"""Offline safety/integration tests; no API calls and no real repo mutations."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('daily_improve', Path(__file__).resolve().parents[1] / 'scripts/daily_improve.py')
di = importlib.util.module_from_spec(spec)
spec.loader.exec_module(di)


class ImprovementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, content in {
            '.gitignore': '.daily-improve/\n',
            'ROADMAP.md': '- [ ] DI-01: Fix the example.\n  - Files: Sources/Example.swift, Tests/Example.swift\n  - Acceptance: Test the fix.\n\n- [ ] DI-02: Later.\n  - Files: Sources/Example.swift, Tests/Example.swift\n  - Acceptance: Later test.\n',
            'CHANGELOG.md': '# Changelog\n',
            'README.md': '# Fixture\n',
            'Sources/Example.swift': 'let value = 1\n',
            'Tests/Example.swift': 'precondition(true)\n',
            'scripts/ci.sh': 'exit 0\n',
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        def git(*args):
            return subprocess.check_output(['git', *args], cwd=self.root, stderr=subprocess.DEVNULL, text=True).strip()
        self.git = git
        git('init')
        git('add', '.')
        git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'fixture')
        self.proposal = {'base': git('rev-parse', 'HEAD'), 'task_id': 'DI-01', 'summary': 'Fix example and test it.', 'edits': [
            {'path': 'Sources/Example.swift', 'old': 'let value = 1', 'new': 'let value = 2'},
            {'path': 'Tests/Example.swift', 'old': 'precondition(true)\n', 'new': 'precondition(true)\nprecondition(value == 2)\n'}]}

    def validate(self, proposal=None):
        return di.validate(self.root, di.next_task(self.root), proposal or self.proposal)

    def test_first_unchecked_task(self):
        self.assertEqual(di.next_task(self.root)['id'], 'DI-01')
        path = self.root / 'ROADMAP.md'
        path.write_text(path.read_text().replace('[ ]', '[x]', 1))
        self.assertEqual(di.next_task(self.root)['id'], 'DI-02')
        path.write_text(path.read_text().replace('[ ]', '[x]'))
        self.assertIsNone(di.next_task(self.root))

    def test_valid_exact_replacements(self):
        self.assertEqual(self.validate()['Sources/Example.swift'], 'let value = 2\n')

    def test_stale_commit_and_task_rejected(self):
        for field, value in [('base', '0' * 40), ('task_id', 'DI-02')]:
            proposal = copy.deepcopy(self.proposal)
            proposal[field] = value
            with self.assertRaises(di.ImprovementError):
                self.validate(proposal)

    def test_unsafe_paths_and_scope_rejected(self):
        for path in ['../secret', '/tmp/evil.swift', '.github/workflows/ci.yml', 'scripts/ci.sh', 'Sources/Other.swift']:
            proposal = copy.deepcopy(self.proposal)
            proposal['edits'][0]['path'] = path
            with self.assertRaises(di.ImprovementError):
                self.validate(proposal)

    def test_symlink_rejected(self):
        path = self.root / 'Sources/Example.swift'
        path.unlink()
        path.symlink_to(self.root / 'README.md')
        with self.assertRaises(di.ImprovementError):
            self.validate()

    def test_ambiguous_and_missing_matches_rejected(self):
        for old in ['', 'absent', 'e']:
            proposal = copy.deepcopy(self.proposal)
            proposal['edits'][0]['old'] = old
            with self.assertRaises(di.ImprovementError):
                self.validate(proposal)

    def test_tests_required_and_cannot_weaken_existing_assertions(self):
        proposal = copy.deepcopy(self.proposal)
        proposal['edits'].pop()
        with self.assertRaises(di.ImprovementError):
            self.validate(proposal)
        proposal = copy.deepcopy(self.proposal)
        proposal['edits'][1]['new'] = '// assertion removed\nprecondition(value == 2)\n'
        with self.assertRaises(di.ImprovementError):
            self.validate(proposal)

    def test_oversized_change_rejected(self):
        proposal = copy.deepcopy(self.proposal)
        proposal['edits'][0]['new'] = '\n'.join('// extra' for _ in range(401))
        with self.assertRaises(di.ImprovementError):
            self.validate(proposal)

    def test_secret_detection_without_echo(self):
        fake = 'sk-' + 'a' * 30
        with self.assertRaises(di.ImprovementError) as raised:
            di.scan_secrets(fake)
        self.assertNotIn(fake, str(raised.exception))

    def test_child_environment_excludes_credentials_and_actions_commands(self):
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'dummy', 'GH_TOKEN': 'dummy', 'GITHUB_TOKEN': 'dummy', 'GITHUB_OUTPUT': '/tmp/output', 'ACTIONS_RUNTIME_TOKEN': 'dummy'}):
            env = di.child_env()
        self.assertTrue(set(env).isdisjoint({'OPENAI_API_KEY', 'GH_TOKEN', 'GITHUB_TOKEN', 'GITHUB_OUTPUT', 'ACTIONS_RUNTIME_TOKEN'}))
        self.assertEqual(env['CI'], 'true')

    def test_success_marks_only_selected_task_after_two_checks(self):
        observations = []
        def runner(root):
            self.assertIn('[ ] DI-01', (root / 'ROADMAP.md').read_text())
            observations.append((root / 'Sources/Example.swift').read_text())
        di.apply_proposal(self.root, self.proposal, runner=runner)
        self.assertEqual(observations, ['let value = 1\n', 'let value = 2\n'])
        self.assertIn('[x] DI-01', (self.root / 'ROADMAP.md').read_text())
        self.assertIn('[ ] DI-02', (self.root / 'ROADMAP.md').read_text())
        self.assertIn('DI-01', (self.root / 'CHANGELOG.md').read_text())
        self.assertTrue((self.root / '.daily-improve/verified.patch').is_file())
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.proposal['base'])

    def test_failed_baseline_or_changed_checks_roll_back(self):
        originals = {p: (self.root / p).read_bytes() for p in di.tracked(self.root)}
        for fail_on in (1, 2):
            calls = []
            def runner(root):
                calls.append(1)
                if len(calls) == fail_on:
                    raise di.ImprovementError('fixture failure')
            with self.assertRaises(di.ImprovementError):
                di.apply_proposal(self.root, self.proposal, runner=runner)
            self.assertEqual(originals, {p: (self.root / p).read_bytes() for p in originals})
            self.assertFalse((self.root / '.daily-improve/verified.patch').exists())

    def test_changes_to_protected_files_during_checks_rejected(self):
        calls = []
        def runner(root):
            calls.append(1)
            if len(calls) == 2:
                (root / 'scripts/ci.sh').write_text('malicious change\n')
        with self.assertRaises(di.ImprovementError):
            di.apply_proposal(self.root, self.proposal, runner=runner)
        self.assertEqual((self.root / 'scripts/ci.sh').read_text(), 'exit 0\n')

    def test_dirty_checkout_rejected_before_checks(self):
        (self.root / 'README.md').write_text('user work\n')
        with self.assertRaises(di.ImprovementError):
            di.apply_proposal(self.root, self.proposal, runner=lambda root: self.fail('must not run'))
        self.assertEqual((self.root / 'README.md').read_text(), 'user work\n')

    def test_api_shape_and_completed_output(self):
        body = di.response_body('gpt-4.1', '{}')
        self.assertFalse(body['store'])
        self.assertTrue(body['text']['format']['strict'])
        class Reply:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit):
                return json.dumps({'status': 'completed', 'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': json.dumps({'summary': 'example', 'edits': []})}]}]}).encode()
        with patch.object(di.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = Reply()
            self.assertEqual(di.call_api(body, 'dummy')['summary'], 'example')
            request = opener.return_value.open.call_args.args[0]
            self.assertEqual(request.full_url, 'https://api.openai.com/v1/responses')


if __name__ == '__main__':
    unittest.main()

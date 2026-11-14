from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/sync_and_build_local.sh'
class LocalUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.remote = self.root / 'remote.git'; self.repo = self.root / 'work tree'; self.other = self.root / 'other'
        self.run_git(self.root, 'init', '--bare', str(self.remote))
        self.run_git(self.root, 'clone', str(self.remote), str(self.repo))
        self.run_git(self.repo, 'checkout', '-b', 'main')
        self.run_git(self.repo, 'config', 'user.name', 'Fixture'); self.run_git(self.repo, 'config', 'user.email', 'fixture@example.invalid')
        (self.repo/'file').write_text('initial\n'); self.commit(self.repo)
        self.run_git(self.repo, 'push', '-u', 'origin', 'main')
        self.run_git(self.root, 'clone', '-b', 'main', str(self.remote), str(self.other))
        self.run_git(self.other, 'config', 'user.name', 'Fixture'); self.run_git(self.other, 'config', 'user.email', 'fixture@example.invalid')
    def run_git(self, cwd, *args):
        return subprocess.check_output(['git', *args], cwd=cwd, stderr=subprocess.DEVNULL, text=True).strip()
    def commit(self, repo):
        self.run_git(repo,'add','.'); self.run_git(repo,'commit','-m','fixture')
    def sync(self):
        return subprocess.check_output(['bash', str(SCRIPT), '--repo', str(self.repo), '--state', str(self.root/'state'), '--sync-only'], text=True, stderr=subprocess.STDOUT)
    def remote_change(self):
        (self.other/'file').write_text('remote\n'); self.commit(self.other); self.run_git(self.other,'push')
    def test_clean_fast_forward(self):
        self.remote_change(); self.assertIn('PASS: clean main synchronized',self.sync()); self.assertEqual((self.repo/'file').read_text(),'remote\n')
    def test_dirty_and_untracked_are_untouched(self):
        self.remote_change(); (self.repo/'new').write_text('personal work')
        self.assertIn('SKIP: local edits',self.sync()); self.assertEqual((self.repo/'new').read_text(),'personal work'); self.assertEqual((self.repo/'file').read_text(),'initial\n')
        (self.repo/'new').unlink(); (self.repo/'file').write_text('unsaved edit')
        self.assertIn('SKIP: local edits',self.sync()); self.assertEqual((self.repo/'file').read_text(),'unsaved edit')
    def test_local_commits_not_rebased_or_pushed(self):
        (self.repo/'local').write_text('local commit'); self.commit(self.repo); before=self.run_git(self.repo,'rev-parse','HEAD')
        self.remote_change(); self.assertIn('SKIP: local-only commits',self.sync()); self.assertEqual(before,self.run_git(self.repo,'rev-parse','HEAD'))
    def test_feature_branch_untouched(self):
        self.run_git(self.repo,'checkout','-b','codex/work'); self.assertIn('SKIP: checkout is not on main',self.sync())

class AtomicInstallerTests(unittest.TestCase):
    @unittest.skipUnless(__import__('sys').platform == 'darwin', 'macOS atomic swap')
    def test_swap_and_wrong_app_guard(self):
        import importlib.util
        import plistlib
        spec = importlib.util.spec_from_file_location('installer', SCRIPT.parent/'install_app_atomic.py')
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            stage, destination = Path(directory)/'stage.app', Path(directory)/'Glacier.app'
            for app,version in [(stage,'new'),(destination,'old')]:
                (app/'Contents').mkdir(parents=True)
                with (app/'Contents/Info.plist').open('wb') as stream: plistlib.dump({'CFBundleIdentifier':'local.ar2mis.lecturecaptions'},stream)
                (app/'version').write_text(version)
            module.install(stage,destination)
            self.assertEqual((destination/'version').read_text(),'new'); self.assertEqual((stage/'version').read_text(),'old')
            with (stage/'Contents/Info.plist').open('wb') as stream: plistlib.dump({'CFBundleIdentifier':'unrelated'},stream)
            with self.assertRaises(ValueError): module.install(stage,destination)
            self.assertEqual((destination/'version').read_text(),'new')

import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('seed', Path(__file__).resolve().parents[1]/'scripts/seed_local_credentials.py')
seed = importlib.util.module_from_spec(spec); spec.loader.exec_module(seed)

class CredentialMigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)/'home'; self.home.mkdir()
        self.repo = Path(self.temp.name)/'repo'; self.repo.mkdir()
        self.config = self.home/'Library/Application Support/Glacier/config.json'
    def test_environment_persists_without_echo_and_never_overwrites(self):
        result = seed.seed(self.repo,self.home,{'OPENAI_API_KEY':'fixture-env-value'})
        self.assertNotIn('fixture-env-value',result)
        seed.seed(self.repo,self.home,{'OPENAI_API_KEY':'fixture-new-value'})
        self.assertEqual(json.loads(self.config.read_text())['credentials']['openai'],'fixture-env-value')
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode),0o600)
        self.assertEqual(stat.S_IMODE(self.config.parent.stat().st_mode),0o700)
    def test_literal_shell_and_dotenv_without_execution(self):
        marker=self.home/'must-not-exist'
        (self.home/'.zshrc').write_text(f'export OPENAI_API_KEY=$(touch {marker})\n')
        (self.repo/'.env').write_text('OPENAI_API_KEY="fixture-dotenv-value" # comment\n')
        seed.seed(self.repo,self.home,{})
        self.assertFalse(marker.exists())
        self.assertEqual(json.loads(self.config.read_text())['credentials']['openai'],'fixture-dotenv-value')
    def test_deleted_key_and_malformed_config_are_preserved(self):
        self.config.parent.mkdir(parents=True)
        value={'version':1,'credentials':{},'disabled':['openai']}
        self.config.write_text(json.dumps(value))
        seed.seed(self.repo,self.home,{'OPENAI_API_KEY':'fixture-deleted'})
        self.assertEqual(json.loads(self.config.read_text()),value)
        self.config.write_text('malformed-original')
        with self.assertRaises(ValueError): seed.seed(self.repo,self.home,{'OPENAI_API_KEY':'fixture-new'})
        self.assertEqual(self.config.read_text(),'malformed-original')
    def test_missing_key_and_symlink_do_not_create_or_replace_config(self):
        self.assertIn('No literal',seed.seed(self.repo,self.home,{}))
        self.assertFalse(self.config.exists())
        target=self.home/'unrelated'; target.write_text('preserve')
        self.config.symlink_to(target)
        with self.assertRaises(ValueError): seed.seed(self.repo,self.home,{'OPENAI_API_KEY':'fixture-new'})
        self.assertEqual(target.read_text(),'preserve')

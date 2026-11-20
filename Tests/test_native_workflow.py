"""Guard the independent, read-only post-daily native verification route."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeWorkflowTests(unittest.TestCase):
    def test_daily_completion_checks_main_without_write_credentials(self):
        text = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('  pull_request:', text)  # Human PR verification is retained.
        self.assertIn('  workflow_run:\n    workflows: [Daily improvement]\n    types: [completed]\n    branches: [main]', text)
        self.assertIn('permissions:\n  contents: read', text)
        self.assertNotIn('secrets.', text)
        self.assertNotIn('pull_request_target:', text)
        self.assertNotIn('actions/download-artifact', text)
        jobs = dict(re.findall(r'^  (verify|ios):\n(.*?)(?=^  [a-z]+:|\Z)', text, re.M | re.S))
        self.assertEqual(set(jobs), {'verify', 'ios'})
        for name, job in jobs.items():
            with self.subTest(job=name):
                self.assertIn("github.event.workflow_run.conclusion == 'success'", job)
                self.assertIn("github.event.workflow_run.head_branch == 'main'", job)
                self.assertIn('github.event.workflow_run.head_repository.full_name == github.repository', job)
                self.assertIn('ref: ${{ github.sha }}', job)
                self.assertIn('persist-credentials: false', job)
                self.assertNotIn('permissions:', job)  # No elevated per-job overrides.
        self.assertIn('bash scripts/ci.sh', jobs['verify'])
        self.assertIn('bash scripts/verify-store.sh', jobs['verify'])
        self.assertIn('bash scripts/verify-ios.sh', jobs['ios'])

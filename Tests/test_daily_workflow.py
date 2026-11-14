import importlib.util
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('guard', ROOT / 'scripts/check_daily_workflow.py')
guard = importlib.util.module_from_spec(spec); spec.loader.exec_module(guard)

class WorkflowPolicyTests(unittest.TestCase):
    def setUp(self): self.text = (ROOT / '.github/workflows/daily-improve.yml').read_text()
    def test_current_policy(self): guard.validate(self.text)
    def test_policy_regressions_fail(self):
        for old,new in [('30 1 * * *','0 0 * * *'), ('0-14399','0-60'),
                        ("github.event_name == 'schedule'", 'true'),
                        ('needs: [propose, draft, verify]', 'needs: [propose, draft]'),
                        ('--match-head-commit "$EXPECTED_HEAD"','--admin'),
                        ('BASE_BRANCH: main','BASE_BRANCH: develop'),
                        ('--complete-portable',''), ('gh pr ready "$PR_NUMBER" --undo','echo ignored')]:
            with self.subTest(old=old), self.assertRaises(ValueError): guard.validate(self.text.replace(old,new))
    def test_comment_does_not_satisfy_policy(self):
        with self.assertRaises(ValueError): guard.validate(self.text.replace('          sleep "$delay"', '#          sleep "$delay"'))

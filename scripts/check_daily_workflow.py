#!/usr/bin/env python3
"""Fail closed when Glacier's deliberately fixed daily workflow policy changes.

Standard-library check of this repository's small, fixed YAML layout. This is not
an arbitrary YAML parser. Unsupported layout changes require a deliberate review
of both the workflow and this guard; comments cannot satisfy required statements.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def validate(text):
    lines = [line for line in text.splitlines() if not line.lstrip().startswith('#')]
    text = '\n'.join(lines)
    def require(condition, message):
        if not condition:
            raise ValueError('Daily workflow policy: ' + message)
    def contains(block, statement):
        require(statement in block, 'missing ' + statement)
    require(re.findall(r"^    - cron: ['\"]([^'\"]+)['\"]$", text, re.M) == ['30 1 * * *'], 'cron must remain 30 1 * * *')
    contains(text, '  workflow_dispatch:')
    contains(text, '  cancel-in-progress: false')
    jobs = dict(re.findall(r'^  (propose|draft|verify|merge):\n(.*?)(?=^  [a-z]+:|\Z)', text, re.M | re.S))
    require(set(jobs) == {'propose', 'draft', 'verify', 'merge'}, 'all four jobs required')
    for job in jobs.values():
        contains(job, '    runs-on: ubuntu-latest')
    propose = jobs['propose']
    contains(propose, "    if: github.ref == 'refs/heads/main' && github.event.repository.default_branch == 'main'")
    contains(propose, '    timeout-minutes: 260')
    contains(propose, "        if: github.event_name == 'schedule'\n        run: |\n          delay=$(shuf -i 0-14399 -n 1)")
    contains(propose, '          sleep "$delay"')
    require(propose.index('sleep "$delay"') < propose.index('actions/checkout@'), 'jitter must precede checkout')
    contains(jobs['draft'], '          draft: true')
    contains(jobs['draft'], '          base: main')
    verify = jobs['verify']
    contains(verify, '    needs: [propose, draft]')
    contains(verify, '    permissions:\n      contents: read')
    contains(verify, 'python3 scripts/check_daily_workflow.py')
    contains(verify, 'python3 scripts/daily_improve.py --apply-proposal .daily-improve/proposal.json --portable --complete-portable')
    merge = jobs['merge']
    contains(merge, '    needs: [propose, draft, verify]')
    require(not re.search(r'^    if:', merge, re.M), 'merge must use the default success-only needs gate')
    contains(merge, '      contents: write\n      pull-requests: write')
    contains(merge, '          base: main')
    contains(merge, '          BASE_BRANCH: main')
    contains(merge, 'test "$(git rev-parse HEAD)" = "$EXPECTED_BASE"')
    contains(merge, 'gh pr ready "$PR_NUMBER"')
    contains(merge, 'gh pr merge "$PR_NUMBER" --squash --match-head-commit "$EXPECTED_HEAD"')
    contains(merge, 'gh pr ready "$PR_NUMBER" --undo')
    contains(merge, '        if: failure()')
    require('continue-on-error:' not in text and '--admin' not in text and '--force' not in text, 'no bypass or ignored failure allowed')
    require(not re.search(r'^    if:.*(?:always|failure)\(', text, re.M), 'jobs must not bypass success gates')

if __name__ == '__main__':
    validate((ROOT / '.github/workflows/daily-improve.yml').read_text())
    print('PASS: 01:30 UTC cron, scheduled-only four-hour jitter, portable gate and conditional main squash merge')

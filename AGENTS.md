# Glacier repository instructions

## Complete authorized work on main

When the owner asks for a feature, fix, build update, or repository change, finish
implementation and relevant verification, then commit and push the reviewed changes
to `Ar2mis/Glacier` `main` as the final step. This is the owner's standing instruction;
do not wait for a separate reminder to publish. Report the resulting commit and
checks. Preserve unrelated user work; never blindly stage secrets or force-push.
If the remote advanced, integrate it and rerun affected checks before publishing.
Do not claim a successful push when authentication or repository policy blocks it.

## Preserve unattended daily improvements

Unless the owner explicitly requests a schedule/policy change, preserve:

- `.github/workflows/daily-improve.yml` cron `30 1 * * *`: 8:30 PM EST on
  the previous UTC calendar day (9:30 PM EDT; fixed UTC does not follow DST).
- A randomized 0–14,399-second delay on scheduled runs only; manual dispatch
  must skip it. Keep enough job timeout for the four-hour window.
- Ubuntu portable verification, draft PRs until checks pass, completion metadata,
  and automatic conditional squash merge to `main` after successful verification.
- Exact base/head checks, no force push or admin bypass, and draft restoration on
  failure. Portable checks are not native Swift build/test verification.

Run `python3 scripts/check_daily_workflow.py` and relevant tests before publishing.
Do not weaken or remove this guard to make an unrelated change pass. The daily bot
must not edit workflows, these rules, its own script, checks, or credential handling.

## Local updater

The launch agent must only sync a clean `main` checkout with no local-only commits.
Never stash, discard, or automatically publish arbitrary local work. Build a detached
snapshot, verify it, and replace `/Applications/Glacier.app` only after success.
Do not terminate an active lecture to update the app. Keep the prior installed app
on build failure. Never embed credentials in scripts, plists, logs, or git remotes.

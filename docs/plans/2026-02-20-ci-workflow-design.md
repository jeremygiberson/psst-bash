# Design: GitHub Actions CI Workflow

**Date:** 2026-02-20

## Purpose

Run the test suite on pull requests and pushes to main, reporting pass/fail status on PRs.

## Workflow

**File:** `.github/workflows/test.yml`

**Triggers:**
- Pull requests: opened, synchronized, reopened
- Push to main (ensures main stays green)

**Matrix:** `ubuntu-latest`, `macos-latest`

**Steps:**
1. Checkout
2. Run `bash test-psst.sh`

No setup steps needed -- both runners have bash 4+ and openssl pre-installed.

## Cleanup

Remove `psst.bats` -- unused locally and in CI. The pure bash test suite (`test-psst.sh`) covers all tests.

## Non-goals

- No branch protection rule configuration (done manually in GitHub settings)
- No caching (nothing to cache)
- No artifact uploads

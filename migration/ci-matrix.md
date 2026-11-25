# Windows and Linux CI matrix

The workflow `.github/workflows/windows-linux-ci.yml` runs on pull requests whose
base is `runtime`, pushes to `runtime`, and manual dispatch. It does not target
the repository's default `hotfix` branch.

## Configuration

- Ubuntu and Windows use separate PHP and frontend jobs, with fail-fast disabled.
- PHP 8.2, Composer v2, required extensions, locked Composer install and Composer
  download cache. Both the full Codeception unit suite and the four
  migration-specific standalone PHPUnit files run.
- Node 22.13.0 and repository-pinned Yarn 4.10.3, immutable installation and Yarn
  download cache. Generate the Angular workspace before production builds of
  core, shell and defaultExt, then run unfiltered core and shell Karma with
  ChromeHeadless.
- The human selected UTC on both operating systems. Export `TZ`, set PHP
  `date.timezone`, and set the Windows system timezone because Chrome does not
  reliably follow `TZ` there. Artifacts record the OS, PHP and Node timezone.
- Each measured step preserves its exit code, full log and wall-clock duration.
  Every job uploads results and writes a duration/test-count summary.
- Test command failures are collected so later independent checks can run.
  A final gate fails the job on nonzero status, red/missing JUnit, or
  red/incomplete Karma results. `continue-on-error` does not make the job green.
- Artifacts: `backend-ubuntu-latest`, `backend-windows-latest`,
  `frontend-ubuntu-latest`, `frontend-windows-latest`. Backend includes JUnit;
  frontend includes complete Karma logs. Karma totals are parsed from logs;
  there is no new reporter dependency.

## Dependencies and existing blockers

Frontend prerequisite: [draft PR #12](https://github.com/oufciu/SuiteCRM-Core/pull/12)
restores the Angular test suite by bringing forward `a929c8b6b` onto runtime
`672be5959`. The CI branch includes that restoration until #12 merges.

The full PHP unit suite is currently blocked by missing AspectMock bootstrap.
AspectMock 4.1.1 requires PHP 7.4 and PHPUnit 9; upstream development code still
requires PHPUnit 9, conflicting with this repository's PHPUnit 10. Static doubles
are genuinely used by six test classes. No dummy shim, bootstrap bypass, test
exclusion, or dependency downgrade is applied.

The human approved planning a separate migration off AspectMock while preserving
all assertions. That repair is not implemented by this workflow. The full suite
remains enabled and a bootstrap failure makes its backend job red. Standalone
migration test success must not be presented as full-suite success.

Eight previously observed Windows date/datetime failures belong to gap G7.
Summaries separately identify failures in the documented field components,
without skipping them or changing assertions. Such a classification is a triage
hint, not proof that every failure in those components is caused by timezone.

## Validation

- CI helper tests: 23 passed, 0 failed.
- Workflow YAML parses and Bash scripts pass syntax checks.
- Local Ubuntu core Karma, UTC: 392/392 passed, 0 skipped. Browser wall time
  1m 19.146s (not total fresh-build time).
- Local Linux shell Karma, UTC: 6/6 passed, 0 skipped. Browser wall time
  0.071s (not total fresh-build time).
- Hosted matrix: [first run](https://github.com/oufciu/SuiteCRM-Core/actions/runs/45487468166)
  completed all four jobs. Production builds and core 392/392 + shell 6/6 passed
  on both operating systems. Ubuntu frontend was green (6m 37s); Windows frontend
  was red (5m 55s) only because a CI helper test passed a literal newline through
  Node's Windows argument handling. Its exact newline assertion is retained and
  the fixture now supplies a printf escape instead.
- Ubuntu backend (48s): Composer passed, standalone PHPUnit 13 tests / 39 assertions
  / 1 existing Windows-only skip, full Codeception failed at missing AspectMock.
- Windows backend (53s): Composer could not install because `ldap` and `sodium`
  were not enabled. Both extensions are now explicit, along with `xmlreader`.
  PHP test commands ran but could not load their missing vendor executables.

## Corrected hosted run

[Run 45488883258](https://github.com/oufciu/SuiteCRM-Core/actions/runs/45488883258)
tested workflow/code head `95bdbf2b6` on 2026-11-24. Both frontend jobs are green.
Both backend jobs run successfully through installation and standalone PHPUnit,
then remain red only for the full Codeception AspectMock bootstrap failure.

| Job | Total job wall time | Result |
|---|---:|---|
| [Frontend Ubuntu](https://github.com/oufciu/SuiteCRM-Core/actions/runs/45488883258/job/138781536129) | 6m 08s | green; core 392/392, shell 6/6, no skips |
| [Frontend Windows](https://github.com/oufciu/SuiteCRM-Core/actions/runs/45488883258/job/138781535691) | 6m 36s | green; core 392/392, shell 6/6, no skips |
| [Backend Ubuntu](https://github.com/oufciu/SuiteCRM-Core/actions/runs/45488883258/job/138781536328) | 43s | red; standalone 13 tests, 39 assertions, 1 existing skip; full suite blocked |
| [Backend Windows](https://github.com/oufciu/SuiteCRM-Core/actions/runs/45488883258/job/138781536340) | 2m 18s | red; standalone 18 tests, 56 assertions, no skips; full suite blocked |

The existing Ubuntu skip is the Windows-only scheduler entry-point test.
The different totals follow its Windows-only cases, not a CI exclusion.
Both OSes also pass 23 CI helper tests and 2 workspace-generator tests.

Measured command durations, including compilation where applicable:

| Command | Ubuntu | Windows |
|---|---:|---:|
| Composer install | 26s | 82s |
| Standalone PHPUnit | 1s | 5s |
| Yarn immutable install | 24s | 44s |
| Production core and shell | 112s | 103s |
| Production defaultExt | 16s | 16s |
| Karma core | 148s | 143s |
| Karma shell | 50s | 49s |

Total job wall times include setup, checkout, caches and artifact upload.
Command durations are integer wall-clock seconds captured by `ci-step.sh`,
not isolated browser execution times. PHP is 8.2.36, PHPUnit 10.5.63,
Node 22.13.0, Yarn 4.10.3 and hosted Chrome 157.
Composer and Yarn caches exist for both operating systems; Composer saves its
downloads before the intentionally red full-suite check.

The Windows system timezone, Node timezone and PHP `date.timezone` were all
recorded as UTC. No previously observed G7 date/datetime failure occurred in
either hosted run at UTC. Builds retain the existing initial-bundle warning
(10.75 MB versus a 9.44 MB warning budget); no budget was relaxed.

Each job published its timed summary and uploaded its named artifact. No
Codeception JUnit report can be produced before its bootstrap is repaired;
that missing report is explicitly reported as a failure, not an empty pass.
Standalone PHPUnit JUnit and complete Karma logs are present.

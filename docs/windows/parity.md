# Compare Windows test results with the Linux baseline

`scripts/windows/compare-parity.ps1` compares the JUnit XML from a Windows run with a Linux reference ("golden") run of the same commit. It reports tests that are missing, added, newly failing, newly passing or otherwise changed. It exits nonzero when any difference has not been accepted. `scripts/windows/compare-parity.py` does the same comparison on Linux or macOS and prints the same report.

## Inputs

Each run is a directory. It holds one XML file per suite, either directly or in a `junit` subdirectory. The file name without `.xml` is the suite name, so a Windows run must use the same file names as the baseline: `php-unit.xml`, `karma-core.xml` and `karma-shell.xml`.

A test is identified as `<suite>::<classname>::<name>`. Codeception writes `class` instead of `classname`, and either works. When the same identity appears more than once in a file, the copies after the first get ` #2`, ` #3` and so on. They are numbered in status order (failed, then passed, then skipped), so the numbering does not depend on the random order in which Jasmine runs specs. `karma-core` has such a pair: `DateTimeFilterFieldComponent::should have update input when field changes`. A test case that contains `<failure>` or `<error>` counts as failed, one that contains `<skipped>` counts as skipped, and every other test case counts as passed.

A run directory may also contain `steps.tsv`, a tab-separated file with the header `step`, `exit_code`, `seconds`, `command`. When both runs have one, the exit code of each step is compared and reported as `step::<name>`. This shows a build or test command that fails before writing XML, such as a Karma suite that does not compile.

| Category | Meaning |
| --- | --- |
| `missing` | In the baseline, not in the Windows run |
| `added` | In the Windows run, not in the baseline |
| `newly-failing` | Failed on Windows, passed or was skipped in the baseline |
| `newly-passing` | Passed on Windows, failed in the baseline |
| `status-changed` | Any other status change, for example passed to skipped |
| `step-changed` | A step's exit code differs, or the step exists in only one run |

## Accepted differences

`scripts/windows/parity-accepted.json` lists the differences that are known and accepted. Each entry needs a `category` (a category name or `*`), a `test` pattern and a `reason`:

```json
{
  "accepted": [
    {
      "category": "newly-failing",
      "test": "karma-core::DateTimeEditFieldComponent::*",
      "reason": "Explain why this difference is acceptable and link the tracking issue."
    }
  ]
}
```

Patterns match the whole identity and are case-sensitive. `*` matches any text and `?` matches one character. Every other character, including `[` and `]`, matches itself. Entries that match nothing are listed as `Unused accepted entry` so stale entries can be removed. An unused entry does not change the exit code.

## Run the comparison

Windows PowerShell 5.1 or PowerShell 7:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\compare-parity.ps1 `
  -Baseline C:\parity\golden\UTC -Candidate C:\parity\windows\UTC `
  -Accepted scripts\windows\parity-accepted.json -JsonReport C:\parity\windows\UTC\parity.json
```

POSIX:

```sh
python3 scripts/windows/compare-parity.py --baseline golden/UTC --candidate windows/UTC \
  --accepted scripts/windows/parity-accepted.json --json-report windows/UTC/parity.json
```

Exit code `0` means there are no unaccepted differences, `1` means there is at least one unaccepted difference, and `2` means an input was unusable (a missing directory, malformed XML, or an invalid accepted-differences file). When standard output is redirected, both scripts write UTF-8.

Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\compare-parity.Tests.ps1`. No Pester is needed. When Python 3 is on `PATH`, the tests also run the Python script on each case and require the same exit code and the same output from both scripts.

## Produce comparable results

Use the same commands as the baseline, from the repository root, once with the time zone set to `UTC` and once with it set to `Europe/Warsaw`:

1. PHP unit suite: `php -d date.timezone=<zone> -d auto_prepend_file=<shim> vendor/bin/codecept run unit --no-colors --xml <run>/junit/php-unit.xml`. PHP does not read the `TZ` variable, so pass the zone as `date.timezone`. The test bootstrap needs `AspectMock\Kernel`, which `composer.lock` does not install. The baseline therefore runs with an out-of-tree prepend file. It defines a no-op `AspectMock\Kernel` whose `loadFile` and `loadPhpFiles` only `require_once` the given files, in sorted path order. Use the same file. It is a test-harness workaround and does not fix the tests, so the tests that call `AspectMock\Test` still fail.
2. `yarn merge-angular-json`, `yarn build:core`, `yarn build:shell` and `yarn build:extension defaultExt`.
3. Karma, with `scripts/windows/karma-junit.conf.js` wrapping the project configuration. It runs one headless Chrome pass and writes JUnit XML without extra dependencies:

```powershell
$env:GOLDEN_KARMA_BASE = 'core/app/core/karma.conf.js'
$env:GOLDEN_JUNIT_OUT = 'C:\parity\windows\UTC\junit\karma-core.xml'
yarn ng test core --karma-config scripts/windows/karma-junit.conf.js --watch=false
$env:GOLDEN_KARMA_BASE = 'core/app/shell/karma.conf.js'
$env:GOLDEN_JUNIT_OUT = 'C:\parity\windows\UTC\junit\karma-shell.xml'
yarn ng test shell --karma-config scripts/windows/karma-junit.conf.js --watch=false
```

Set `CHROME_BIN` if Chrome is not found automatically.

On Linux, `TZ=Europe/Warsaw` makes eight datetime specs in `karma-core` fail (in `DatetimeDetailFieldComponent`, `DateTimeFilterFieldComponent` and `DateTimeEditFieldComponent`), while all of them pass under `UTC`. Chrome on Windows may ignore `TZ` and use the system time zone. Under `Europe/Warsaw`, those eight specs show whether the browser used the intended zone: if they all pass, the run did not test that zone.

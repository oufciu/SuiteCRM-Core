# Windows runtime: validation run log

Record of the first end-to-end run of the Windows runtime scripts on
Windows 10 (10.0.19045), Windows PowerShell 5.1, 2026-11-23.

## Commands

Run from the worktree root, each in its own 64-bit PowerShell process:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\prepare.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Backend
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Frontend
```

## Runtime root

`prepare.ps1` refused the pre-existing default runtime root
(`%LOCALAPPDATA%\SuiteCRM-Windows-Runtime`): its seven package directories
were extracted by an earlier script revision that did not write the
`.extracted-<sha256>` completion markers, so the current script treats them
as unrecognized and stops (see issue __ISSUE_PREPARE__). The run continued
on a fresh root, `-RuntimeRoot "$env:LOCALAPPDATA\SuiteCRM-Windows-Runtime-v2"`,
seeded with the already-downloaded archives. Every archive matched the
SHA-256 pinned in `packages.json`; nothing was re-downloaded. The same
`-RuntimeRoot` was passed to every `runtime.ps1` action, including `Check`,
`Backend` and `Frontend`.

## Results

Two bases were validated:

- **A:** worktree `migration/windows-runtime`, HEAD `21c96618f` (the branch
  the scripts were developed on).
- **B:** worktree `windows/runtime-scripts`, branched from `origin/runtime`
  `7b7335e7d` (the base of this pull request).

| Step | Base A | Base B |
| --- | --- | --- |
| `prepare.ps1` | Passed (fresh root) | Passed, 1 s (cached) |
| `Check` | Passed | Passed, 6 s |
| `Backend` | Passed (~10 min) | Passed, 1544 s |
| `Frontend` | Passed, `EXIT=0` | Passed, 750 s |

`Check` reported PHP 8.2.36 (ZTS, VC++ 2019 x64) with the `amqp` and
`redis` extensions, Apache 2.4.71, MariaDB 11.4.14, Node 22.23.5,
Composer 2.11.2 and Yarn 4.10.3. `Backend` passed both platform-requirement
checks (33 requirements) and ran the Symfony post-install hooks
(`cache:clear`, `cache:warmup`, `assets:install`, `scrm:copy-legacy-assets`).
`Frontend` built the `core` package, the shell and `defaultExt`, and
published `public\extensions\defaultExt\remoteEntry.js`.

`Serve`, `Stop`, the installer and the Accounts CRUD check were not
exercised in these runs.

## Captured warnings and errors

None of the following failed a step; each is tracked in its own issue:

- The shell's initial bundle is 10.75 MB against the 9.44 MB Angular
  budget (issue __ISSUE_BUDGET__).
- Yarn reports `YN0086`: some peer dependencies are incorrectly met
  (issue __ISSUE_PEER__).
- Angular warns that `deployUrl` is deprecated, and CSS inlining skips
  `.custom-file-input:lang(en)~.custom-file-label` because of the `:lang`
  pseudo-class (issue __ISSUE_BUDGET__).
- Under Windows PowerShell 5.1, compiler progress written to stderr
  surfaces as `NativeCommandError` records when output is redirected, and a
  managed background runner reported "unknown exit status" for both
  `Backend` and `Frontend`. Rerunning the action in the foreground with
  output redirected to a file returned a definite `$LASTEXITCODE` of `0`
  (issue __ISSUE_EXIT__).
- Composer's optimized autoload dump prints pre-existing PSR-4 "Skipping"
  notices for legacy and test classes. They are informational and predate
  these scripts.

## Evidence

- Full step logs from the Base B run:
  `%LOCALAPPDATA%\SuiteCRM-Windows-Runtime-v2\pr-validation\{prepare,check,backend,frontend}.log`
- Base A frontend log:
  `%LOCALAPPDATA%\SuiteCRM-Windows-Runtime-v2\frontend.log`

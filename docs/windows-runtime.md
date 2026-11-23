# Native Windows 10 Home development runtime

This is a loopback-only environment for a **fresh test installation**, not a
production deployment or a migration of existing data. SuiteCRM's
[8.10 compatibility matrix](https://docs.suitecrm.com/8.x/admin/compatibility-matrix/#_suitecrm_8_10_x)
lists PHP 8.2, Apache 2.4 and MariaDB 11.4, but does not list Windows as a
supported platform. This checkout locks `lcobucci/clock` to a release requiring
PHP 8.1 or 8.2, so the runtime pins PHP 8.2 even though the release matrix also
lists other versions. The build uses Node 22, which is compatible with Angular
18.2; the SuiteCRM matrix recommends Node 20. Yarn is pinned by `package.json`.

## Set up a disposable checkout

Use a short Git worktree path on NTFS. From the worktree root, run each
step in its own 64-bit PowerShell 5.1+ process:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\prepare.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Backend
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Frontend
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Serve
```

`prepare.ps1` downloads the exact versions in
[`packages.json`](../scripts/windows/packages.json) over HTTPS and checks SHA-256
before extracting. It does not run installers or register services. The
64-bit Visual C++ runtime required by the package vendors must already be
available; the script never installs it. A `Restricted` policy blocks `.ps1`
files. These commands use a child process to keep both the execution policy
and runtime environment variables out of the calling shell. Do not change
the global policy. If a managed policy prevents execution, follow your
administrator's requirements.

The package cache is outside the checkout under
`%LOCALAPPDATA%\SuiteCRM-Windows-Runtime`. All actions accept `-RuntimeRoot` if
you need a separate cache and state. `Check` prints the detected versions and
PHP CLI modules. `Backend` installs Composer's locked dependencies and runs an
actual platform check. The AMQP 2.2.0 and Redis 6.3.0 PHP extensions are
required by the locked bridge packages and installed from official PHP PECL
release archives. Their pinned hashes were computed from those official
downloads (the Windows PECL pages do not publish the ZIP hashes). Neither
transport is enabled and neither service is started. `Frontend` installs the
immutable Yarn lock, generates the Angular workspace and builds the app and
the tracked `defaultExt`.

`Serve` launches two foreground child processes, binding HTTP to
`127.0.0.1:18080` and MariaDB to `127.0.0.1:13306` by default. Override either
port with `-HttpPort` or `-DbPort` if necessary. Keep those ports unchanged
after installing. Do not expose these listeners outside your machine. Leave
the terminal open and invoke `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\runtime.ps1 -Action Stop`
from a second terminal with the same worktree and `-RuntimeRoot` to stop the sandbox
and shut down MariaDB. Do not point the installer at a pre-existing database.

## Install and exercise SuiteCRM

`Serve` prints a per-worktree instance directory and the location of its
local `credentials.json`. Treat this file as private. In a second terminal
or in a browser, use the [SuiteCRM installer](https://docs.suitecrm.com/8.x/admin/installation-guide/)
with these sandbox values:

| Field | Value |
| --- | --- |
| Site URL | `http://127.0.0.1:18080` (adjust if you changed `-HttpPort`) |
| DB host | `127.0.0.1` |
| DB port | `13306` (adjust if you changed `-DbPort`) |
| DB name and username | `suitecrm_windows` |
| DB password | `dbPassword` from `credentials.json` |
| Admin | a test-only username and `sitePassword` from `credentials.json` |
| Demo data | No |

The installer may change the database's default collation. On the Windows
test instance, it changed `utf8mb4_unicode_ci` to `utf8mb3_general_ci`.
Verify the database and table collations separately if you intend to move
existing data.

To use the CLI installer instead, open a separate PowerShell in this worktree.
Use the same runtime root and database port you used for `Serve`. Keep the
forward slash in `bin/console`; an unpatched Windows CLI can reject a backslash
path before running the installer.

```powershell
$runtime = '<actual runtime root used for Serve>'
$env:PHPRC = '<instance directory printed by Serve>'
$env:PHP_INI_SCAN_DIR = Join-Path $env:PHPRC 'ini.d'
$env:Path = "$(Join-Path $runtime 'packages\amqp');$env:Path"
$php = Join-Path $runtime 'packages\php-8.2.36\php.exe'
& $php bin/console suitecrm:app:install --db_port=13306
```

Replace `13306` if you passed a different `-DbPort`. Enter the other sandbox
values above at the prompts.

After installation:

1. Sign in, open Accounts and create an account with an unmistakably
   synthetic name. Reopen it after navigation/reload, update its name, then
   sign out and back in and confirm the update persisted. Delete only this
   fixture and check it is absent on a fresh Accounts search.
2. Check the browser console and the instance's `apache-access.log`,
   `apache-error.log`, `php.log` and `mariadb.log` in `logs`. Check the Symfony
   and legacy application logs under the worktree too. Sanitize all evidence
   before sharing it.
3. Keep tests isolated. A new worktree produces a new instance directory and
   a fresh database. Do not copy a config file, add real records, or reuse a
   production database for this check.

Moving real data is a separate operation. Back up the source database,
configuration, customizations and uploaded files, then rehearse a consistent
restore to a separate sandbox. Verify row counts, representative records and
attachments, permissions, scheduler identity and rollback before considering
a cutover.

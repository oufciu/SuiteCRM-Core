# Windows packaging entry points

These scripts target a fresh, loopback-only development installation on x64
Windows PowerShell 5.1. They wrap `prepare.ps1` and `runtime.ps1`; they do not
migrate existing data or make Windows a supported production platform.

Run each command in a separate PowerShell process, from a clean checkout.
Keep the checkout path short. The pinned packages need the vendor's x64 Visual
C++ runtime already installed. Use the same `-RuntimeRoot` on every command.
An existing unmarked package directory is rejected, never removed automatically.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\test.ps1 -Suite all
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\install-service.ps1 -HttpPort 18086 -DbPort 13312
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\run.ps1 -Action Status -HttpPort 18086 -DbPort 13312
```

The example ports avoid the runtime's defaults18080/13306. Choose free ports
before first startup and keep them unchanged after installation. Each checkout
gets its own database, credentials and task identity from its absolute path.
Do not run another checkout against its instance directory. Preserve a failed
installation for investigation rather than unlocking/resetting it.

## Build

`build.ps1` verifies/downloads the pinned packages, runs Backend (locked Composer
install and real platform checks), then Frontend (immutable Yarn install,
workspace generation, core, shell and defaultExt production builds, asset
publication). It also compiles the default legacy Dawn stylesheet, which is
not tracked. Alternate legacy themes are not built by this entry point.
`-Target Backend` or `-Target Frontend` runs only that build stage.

The build does not start a database, install the application, install global
tools, alter the machine execution policy, or replace dependency locks.

## Tests and reports

`test.ps1 -Suite unit|integration|frontend|all` selects:

| Suite | Checks |
| --- | --- |
| unit | Codeception actor generation and the complete existing Codeception unit suite |
| integration | Packaging Pester regressions (synthetic fixtures), existing PHPUnit console-entry integration tests, Karma JUnit reporter tests |
| frontend | Unfiltered core and shell Karma suites using headless Chrome |
| all | All of the above, sequentially, even when an earlier suite fails |

The integration suite does not mutate an installed database or claim browser
end-to-end coverage. The repository's functional suite currently has no tests.
Codeception's existing application-specific prerequisites still apply; setup
errors are failures, not successful empty suites.

Chrome must be installed. `CHROME_BIN` is honored; otherwise the runner checks
the standard Google Chrome installation paths. Pester3.4+ must be available for
the packaging regressions (Windows10 ships3.4). No module is downloaded by the
test runner. The scripts do not change the browser or host timezone, test
assertions, dependency versions or security settings.

Every executed command gets `.stdout.log` and `.stderr.log` under
`tests/_output/windows`. Native stderr by itself is not failure: the actual
child exit code decides. Build returns nonzero at the first failed stage.
Test `all` returns nonzero if any command fails, but still attempts later suites.

- `build.xml` and `test-<suite>.xml`: JUnit-style **command-level** summaries.
- `packaging.xml`, `console-entry.xml`, `junit-reporter.xml`,
  `frontend-core.xml`, `frontend-shell.xml`: individual test results.
- `tests/_output/windows-unit.xml`: Codeception's own JUnit report.

A compiler/bootstrap/browser-launch failure may prevent a framework's individual
test report from being written; the command summary still records that failure.
Reports/logs are generated artifacts and are not committed. Do not publish raw
application logs or test data without checking for credentials/personal data.

## Startup and installation

Despite its compatibility name, `install-service.ps1` defaults to a **per-user
Task Scheduler logon task**, not a Windows Service. It needs no elevation,
stores no Windows password, runs with the current user's limited token, and is
independent of the terminal/Droid that registered it. It starts after that
user signs in, not before sign-in; sign-out can end it.

Default registration starts the task immediately. `-NoStart` only registers it.
The task is named `SuiteCRM-Windows-<checkout-id>`. Its launcher and nonsecret
registration metadata are saved under
`<RuntimeRoot>\instances\<checkout-id>\startup-launcher.ps1` and
`startup-registration.json`. Keep the source checkout at that path.
Launcher logs are in the instance's `logs` directory.

The launcher supervises `runtime.ps1 Serve`, which starts MariaDB and then Apache
with loopback-only listeners. Task settings ignore duplicate runs, allow battery
operation, have no execution time limit, and retry a failed launcher up to three
times at one-minute intervals. A listener owned by another executable/config
pair is rejected. Nothing touches another checkout's task or database.

Startup creates only the isolated database. Complete the normal
[application installation](../windows-runtime.md#install-and-exercise-suitecrm)
using that instance's private credentials file and the selected ports.
No administrator is created by these wrapper scripts.

`run.ps1 -Action Start` starts the registered task/service and waits for the
owned listeners (and an enabled worker). Without a registration, it runs Serve
in the current terminal instead. Keep that terminal open.

`run.ps1 -Action Status` prints ports, PIDs and Messenger state. Its exit codes
are0=running,2=stopped,3=partial,1=invalid/foreign state or another error.
Readiness is listener ownership, not application installation or a successful
HTTP response; check HTTP/login separately after installation.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\run.ps1 -Action Stop -HttpPort 18086 -DbPort 13312
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\install-service.ps1 -Action Unregister -HttpPort 18086 -DbPort 13312
```

Unregister stops only this instance and removes its startup registration,
retaining all data, configs, scripts and logs. Do not use Task Scheduler's End
action or forcibly kill the monitor for normal shutdown. Apache uses the
existing scoped process stop; MariaDB gets `mariadb-admin shutdown`.

## Messenger supervision (opt-in after application installation)

Stop/unregister a web-only registration, then register again with
`-WithMessenger`, using the same ports/root. This switch requires the installed
legacy config; a fresh database alone cannot run the Doctrine queue.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\install-service.ps1 -WithMessenger -HttpPort 18086 -DbPort 13312
```

The launcher also starts an instance-scoped worker supervisor. It waits for
MariaDB/Apache, consumes only `internal-async`, and restarts the worker after
each exit with5s backoff. Each child is bounded to300s/256MiB. Doctrine is the
default transport; no Redis/RabbitMQ server is started. Changing the app's
transport DSN is a separate operator action.

`run.ps1 Status` reports a missing enabled worker as Partial, not green. Stop
requests Messenger shutdown **before** stopping the database. The worker uses
Symfony's cache-based `messenger:stop-workers` rather than POSIX signals.
After30s it terminates only its owned child; in-flight work then follows the
configured transport's redelivery policy. Do not use this timeout for jobs that
cannot safely retry. State reads/writes use a small exclusive file lock to avoid
partially read state or Windows rename races.

Worker/supervisor logs stay in instance `logs`. If the supervisor itself fails,
the launcher stops its runtime and fails so Task Scheduler can retry. Enabling
supervision is not proof that any particular asynchronous application job ran;
validate a harmless synthetic job separately before relying on it.

## Optional real service, explicit administrative operation

The default path above does not install a service or request elevation.
Service mode is an opt-in **WinSW2.x** integration. It downloads no wrapper.
Before using it, approve the exact wrapper version/hash, dedicated service
identity, and NTFS access plan with the machine owner. This path requires an
elevated PowerShell and has not been validated by the non-admin task tests.

The supported built-in identity is `NT AUTHORITY\LocalService`, explicitly
selected with `-ServiceAccount`. LocalSystem is never used. Prepare least-
privilege read/execute access to the checkout/packages and write access to this
instance plus application-generated cache/log/upload directories. Do not grant
Everyone/Users full control or relax access to secrets. ACL provisioning is not
performed by these scripts.

```powershell
.\scripts\windows\install-service.ps1 -StartupMode Service -ServiceAccount 'NT AUTHORITY\LocalService' -ServiceWrapperPath 'C:\approved\WinSW-x64.exe' -WrapperSha256 '<approved SHA256>' -HttpPort 18086 -DbPort 13312
.\scripts\windows\install-service.ps1 -Action Unregister -StartupMode Service -HttpPort 18086 -DbPort 13312
```

The executable/hash is checked before registration. The wrapper copy/XML stay
under this instance's `service` directory. WinSW's stop action calls the same
scoped Stop path. Service installation, reboot/sign-in behavior and production
service-account ACLs require separate native acceptance; a passing Task
Scheduler run does not establish those.

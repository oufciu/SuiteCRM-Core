# Run SuiteCRM schedulers on Windows

Use Windows Task Scheduler to run the SuiteCRM 8 `schedulers:run` command. Configure the task to run as a dedicated, non-administrator Windows account with access to the installed application and only the permissions it needs to run its jobs. You don't need to use `SYSTEM` or to run with highest privileges.

## Authorize the task account

Open Command Prompt as the account that will run the task and run `whoami`. Allow the complete name it prints, including the computer or domain prefix and exact case. A bare username or different letter case will not match. SuiteCRM does not automatically allow Windows accounts.

In the installed instance's `public/legacy/config_override.php`, set `cron.allowed_cron_users`. If the file doesn't exist, create it with `<?php` on the first line. Use your real `whoami` output in place of `workstation\crm-runner` and retain any other entries you still need. A single-quoted PHP string writes the backslash as `\\`.

```php
$sugar_config['cron']['allowed_cron_users'] = [
    'workstation\\crm-runner',
];
```

## Verify from Command Prompt

Replace both absolute paths with yours. Run the commands in `cmd.exe` as the task account, not in PowerShell. `/d` makes the SuiteCRM drive current even when the prompt starts on a different drive. Run the second command only if the first succeeds.

To check that the Windows CLI reaches the scheduler without running any jobs, first append `--help` to the second command. The output should include `Run all Schedulers` and `schedulers:run`. An exit code of `0` with `Bad data passed in` is not a successful run; check that your checkout includes the Windows `bin/console` entry-point fix.

```bat
cd /d "D:\CRM Site"
"C:\PHP Tools\php.exe" "D:\CRM Site\bin\console" schedulers:run
echo %ERRORLEVEL%
```

The command runs any eligible jobs. Use a test instance if that would have unwanted effects. If the command reports an unauthorized user, compare its `Current user:` line against your allow-list and check which Windows account ran it. Don't disable the authorization check.

## Create the task

In Task Scheduler, select **Create Task**. Set the configured Windows account as the task principal. Add a repeating trigger (for example, every minute). Under **Settings**, choose **Do not start a new instance** if the task is already running.

### Portable PHP

The task does not inherit PHP settings exported in an interactive shell. Use the launcher in the SuiteCRM checkout that the task should run. It sets `PHPRC`, `PHP_INI_SCAN_DIR`, `PATH` (prepending the directory containing the AMQP dependency DLLs), `APP_ENV=prod`, and `APP_DEBUG=0` for the launcher process and PHP child only. It sets the working directory to that checkout and returns PHP's exit code. It does not set machine or user environment variables, start services, or change the task identity.

Use the `php.ini` and scan directory generated for this worktree, not those of a different worktree. For the portable runtime, they are under that worktree's `instances\<instance-id>` directory. The scan directory must already contain the extension configuration, including any full path to the Redis DLL. Point `-AmqpDllDir` to the directory containing `rabbitmq.4.dll`, not to the DLL file itself. Use paths local to the task account and grant that account read and execute access; do not grant it write access to the launcher or PHP files.

Add an action of type **Start a program**. The table uses illustrative paths. Replace each with its actual absolute path; keep the double quotes around the arguments' paths.

| Field | Example |
| --- | --- |
| Program/script | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` |
| Add arguments | `-NoProfile -NonInteractive -File "D:\CRM Site\bin\windows\scheduler.ps1" -PhpExe "C:\CRM Runtime\packages\php-8.2.36\php.exe" -PhpIni "C:\CRM Runtime\instances\INSTANCE\php.ini" -PhpIniScanDir "C:\CRM Runtime\instances\INSTANCE\ini.d" -AmqpDllDir "C:\CRM Runtime\packages\amqp"` |
| Start in | `D:\CRM Site` (no surrounding quotes) |

The task account's PowerShell policy must permit this trusted script. Use an approved signing or execution-policy setup. For a local disposable validation environment with no managed policy, the process-scoped `-ExecutionPolicy Bypass` option can be placed before `-File`; it does not change system or user policy. Do not use it to work around a managed policy.

As the task account, run the same Program/script and arguments in a fresh Command Prompt with `-Help` appended. Expect `Portable PHP extensions loaded: amqp, redis`, `Run all Schedulers`, and `schedulers:run`, with no `Bad data passed in` or PHP startup DLL warnings. This check does not run scheduler jobs. For an actual run, remove `-Help`. To troubleshoot an error, run the action manually as the task principal; the launcher leaves PHP's output streams intact.

To test the launcher's path handling and exit-code forwarding without an installed database, run `powershell.exe -NoProfile -NonInteractive -File "D:\CRM Site\tests\windows\scheduler-launcher-smoke.ps1" -PhpExe "C:\CRM Runtime\packages\php-8.2.36\php.exe"`. The test uses a temporary PHP configuration and exits before SuiteCRM starts. `Scheduler fixture stderr` and a missing `php.ini` diagnostic are intentional; the test should finish with `Scheduler launcher smoke passed`.

### Already configured PHP CLI

If PHP already loads the correct configuration and extensions under the task account, and the task environment already matches the web app, you can use a direct action instead:

| Field | Example |
| --- | --- |
| Program/script | `C:\PHP Tools\php.exe` (select the executable with **Browse**) |
| Add arguments | `"D:\CRM Site\bin\console" schedulers:run` |
| Start in | `D:\CRM Site` (no surrounding quotes) |

Use the PHP CLI executable, not `php-cgi.exe`. **Start in** is a directory field, not a command.

### Confirm the task ran

Run the task on demand once. Check that **Last Run Result** is `0x0`, then verify a known due job reports a completed run in SuiteCRM. A task can start the runner successfully even if a particular job fails. Confirm another run after the trigger fires. In a disposable instance, you can verify the allow-list check by temporarily changing just the test account entry's case or removing it: the command should report an unauthorized user and exit `1`. Restore the exact name and check that the command succeeds again.

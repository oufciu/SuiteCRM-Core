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

In Task Scheduler, select **Create Task**. Set the configured Windows account as the task principal. Add a repeating trigger (for example, every minute) and an action of type **Start a program**:

| Field | Example |
| --- | --- |
| Program/script | `C:\PHP Tools\php.exe` (select the executable with **Browse**) |
| Add arguments | `"D:\CRM Site\bin\console" schedulers:run` |
| Start in | `D:\CRM Site` (no surrounding quotes) |

Use the PHP CLI executable, not `php-cgi.exe`. Only the console path in **Add arguments** needs shell-style quotes; **Start in** is a directory field, not a command. Keep the paths local and available to the task account. No `cmd.exe` wrapper is needed.

Run the task on demand once. Check that **Last Run Result** is `0x0`, then verify a known due job reports a completed run in SuiteCRM. A task can start the runner successfully even if a particular job fails. Confirm another run after the trigger fires. In a disposable instance, you can verify the allow-list check by temporarily changing just the test account entry's case or removing it: the command should report an unauthorized user and exit `1`. Restore the exact name and check that the command succeeds again.
